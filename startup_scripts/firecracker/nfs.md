# Serving files to the VM over NFS (read-only library + rw scratch)

How to share host directories with the Firecracker VM over the network:
a **read-only** media library (`dharmabob_rag` transcriptions and references)
and a **read-write** scratch directory for scrape downloads (the guest
overlay is only 8G, so large downloads must land on host storage).

Everything here is enforced **on the host side** by the NFS server, so the
agent inside the VM has no protocol-level way to write to the read-only
export — read-only is a real boundary, not a mount option on an untrusted
guest.

The companion script `nfs-share.sh` automates all of it (nfsd runs on
demand, since the media lives on an external volume that is not always
mounted).

---

## Why NFSv4, and why port 2049 only

- NFSv3 used `rpcbind` (111) plus several dynamic ports (`mountd`,
  `statd`, `lockd`) — a firewall nightmare, and the `firewall-cmd` loop in
  `start.sh` only opens TCP, so UDP services would be missed.
- NFSv4 was deliberately designed as firewall-friendly: file access,
  locking, and mounting all run on the IANA-assigned port **2049** (Linux
  `nfsd` hardcodes it). One port, one rich-rule, fits `HOST_SERVICE_PORTS`
  exactly.
- We force **v4-only** in `/etc/nfs.conf` (`vers3=n`) so rpcbind/mountd
  never listen and 2049 is genuinely the whole attack surface.

## Network path (why the export client list is `192.168.100.0/24`)

```
VM (172.16.0.2, netns fc-vm1)
  → netns MASQUERADE → source becomes 192.168.100.2 (veth)
  → host NFS server sees connections from 192.168.100.2
  → NFS reachable at 192.168.100.1 (VETH_HOST_IP)
```

**Gotcha:** exports must allow `192.168.100.0/24` (the MASQUERADEd source),
*not* `172.16.0.2`. Using the VM's own IP fails with a silent
"access denied by server".

---

## One-time host setup

```bash
cd /root/lab/startup_scripts/firecracker
sudo ./nfs-share.sh setup
```

What it does (all idempotent):

1. Creates the squash user `rag-scraper` (uid 1005, no login shell) and
   `chown`s `/srv/rag-scrape` to it.
2. Appends a managed block to `/etc/nfs.conf` forcing NFSv4-only. If an
   `[nfsd]` section already exists, it warns you to add `vers3=n` manually
   instead of writing a duplicate section.
3. Appends two lines to `/etc/exports`:

   ```
   /root/bob/dharmabob_rag  192.168.100.0/24(ro,no_subtree_check,all_squash,anonuid=1005,anongid=1005)
   /srv/rag-scrape          192.168.100.0/24(rw,no_subtree_check,all_squash,anonuid=1005,anongid=1005)
   ```

Edit the `RO_EXPORT` / `RW_EXPORT` variables at the top of `nfs-share.sh`
if your layout differs.

### Export-path choice matters

An export exposes **everything** under the path, including `.git/` history
and any `.env`/credential files that `.gitignore` protects but exports do
not. Prefer exporting a data subdirectory (e.g. `.../dharmabob_rag/data`)
over the repo root, and keep the rw scratch **outside** the repo entirely —
`dharmabob_rag` is the curated data deliverable and commits straight to
`main`; scrape output doesn't belong in it until an ingestion step promotes
it. Also note the ro and rw exports must be disjoint — one directory
cannot be both.

### Exporting an exFAT/NTFS volume

External media volumes are often formatted exFAT or NTFS. These can't
provide POSIX filehandles and don't honor `chown`, which is why they were
historically not NFS-exportable. `require_exportable_fs` in `nfs-share.sh`
enforces this with two rules:

- **Read-only export on exFAT/ntfs3: allowed with a warning.** Kernels
  >= 6.2 can export exFAT read-only. No ownership semantics — fine for
  the ro export, since all requests are squashed to one uid and exFAT
  mounts are world-readable (`fmask=0022/dmask=0022`). This is the
  zero-copy option: export the volume directly.
- **Read-write export on exFAT/NTFS/FAT: hard failure.** Ownership
  semantics are required for the rw scratch export — use an ext4 target
  (like `/srv/rag-scrape` on the host rootfs).

If your kernel is older than 6.2 (or the volume is vfat/fuseblk), the
fallback is an ext4 loopback image *on* the volume:

```bash
# one-time: sparse ext4 image on the exFAT/NTFS volume (size = what you need)
truncate -s 500G /mnt/media/library.ext4
sudo mkfs.ext4 -F /mnt/media/library.ext4
sudo mkdir -p /mnt/media/library-fs
sudo mount -o loop /mnt/media/library.ext4 /mnt/media/library-fs
sudo chown rag-scraper:rag-scraper /mnt/media/library-fs

# /etc/fstab on the host so it remounts with the volume:
# /mnt/media/library.ext4  /mnt/media/library-fs  ext4  loop  0  0
```

Then point `RO_EXPORT` / `RW_EXPORT` in `nfs-share.sh` at the loop mount
points (e.g. `/mnt/media/library-fs`). `findmnt` reports the export path as
ext4 and the guard passes. Small performance cost (one extra fs layer), but
full POSIX semantics.

### Hotplug volumes: bind at start time, not boot time

If the read-only export is a removable volume that comes and goes (mounted
by udisks under `/run/media/...`), do **not** create the bind mount in
`/etc/fstab` — at boot the volume usually isn't there, and a failed local
mount can stall the boot or drop it into emergency mode.

Instead, let `nfs-share.sh` own the bind: set `RO_BIND_SRC` to the
volume's path and `RO_EXPORT` to a stable, shallow target:

```bash
# in nfs-share.sh
RO_BIND_SRC="/run/media/corey/SHREE_01/DHARMA_BOB"
RO_EXPORT="/srv/library"
```

`start` then bind-mounts the volume onto `/srv/library` (after checking the
volume is present, and rebinding if the volume remounted as a new
filesystem while sharing was stopped) before exporting, and `stop` unbinds
it. Exports a clean single-level path, avoids the deep `/run/media` path
entirely, and the bind only ever exists while the volume is attached.
Workflow when swapping volumes: plug in → `sudo ./nfs-share.sh start` →
done; unplug after `stop`.

## Starting/stopping sharing (on demand)

```bash
sudo ./nfs-share.sh stop
sudo ./nfs-share.sh start   # requires the external media volume to be mounted first
./nfs-share.sh status
```

`start` verifies the export paths exist (so you can't export a mountpoint
hole), applies `exportfs -ra`, starts nfsd, and confirms it is listening
on 2049. `stop` closes port 2049 completely.

### Ordering with the VM lifecycle

- `start.sh` opens port 2049 (from `HOST_SERVICE_PORTS` in `config.sh`);
  `cleanup.sh` removes the rule. The firewall rule is harmless while nfsd
  is stopped (nothing listens → connections refused).
- Recommended sequence: run `nfs-share.sh setup` and a local test mount
  **before** ever opening the port, so the port only ever opens onto a
  proven-working server:

  ```bash
  sudo ./nfs-share.sh setup && sudo ./nfs-share.sh start
  sudo mkdir -p /mnt/nfs-selftest
  sudo mount -t nfs4 localhost:/srv/rag-scrape /mnt/nfs-selftest
  ls /mnt/nfs-selftest && sudo umount /mnt/nfs-selftest
  # only now: sudo ./cleanup.sh && sudo ./start.sh
  ```

  Note the localhost self-test does not exercise the firewall path — the
  VM mount below is the real end-to-end test.

## VM side

`nfs-common` is preinstalled in base images, so just mount:

```bash
sudo mkdir -p /mnt/library /mnt/scrape
sudo mount -t nfs4 192.168.100.1:/root/bob/dharmabob_rag /mnt/library
sudo mount -t nfs4 192.168.100.1:/srv/rag-scrape        /mnt/scrape
```

For automatic mounting, add to `/etc/fstab` in the guest:

```
192.168.100.1:/root/bob/dharmabob_rag  /mnt/library  nfs4  ro,_netdev,noatime  0  0
192.168.100.1:/srv/rag-scrape          /mnt/scrape   nfs4  rw,_netdev,noatime  0  0
```

`noatime` avoids write-back traffic on the read-only share. Also worth
mounting the ro share `-o ro` on the guest for defense in depth.

## Troubleshooting

1. Mount says "access denied by server" → exports use the wrong client
   address. Must be `192.168.100.0/24` (MASQUERADE gotcha above).
2. Connection refused/timed out → port not open. Check
   `HOST_SERVICE_PORTS` in `config.sh`, then `cleanup.sh && start.sh`.
   Also check `sudo ss -tln | grep 2049` on the host.
3. Server offers only v3 mounts → `vers3=n` not applied; check
   `/etc/nfs.conf` and `sudo exportfs -v`.
4. `start` fails with "export path does not exist" → the external media
   volume is not mounted. Mount it, then re-run.
5. VM mount of the read-only export says "No such file or directory"
   while `sudo exportfs -v` lists it → the export path is deep and/or
   crosses mount boundaries (e.g. under `/run/media`), which breaks
   NFSv4 path resolution. Use the `RO_BIND_SRC` bind setup
   (see "Hotplug volumes" above).
6. Host services reachable from the VM must bind `0.0.0.0` — kernel nfsd
   does this by default, but keep it in mind if fronting NFS with anything
   else.

## Security notes

- **AUTH_SYS trusts client UID claims.** A hostile agent that is root in
  the guest can claim any UID. `all_squash` on **both** exports
  neutralizes this: every request, claimed or not, runs as
  `rag-scraper` (uid 1005), so it can only touch what that user can touch.
  Plain `root_squash` is *not* sufficient (it only maps UID 0).
- **Scope of compromise with all_squash:** the ro export is a hard
  read-only boundary over one directory tree; the rw export's residual
  risk is the agent filling host disk. Contain that by putting
  `/srv/rag-scrape` on its own volume or XFS project quota.
- **No encryption.** Traffic is plaintext over a local netns/veth pair —
  fine here, not fine on a shared network (that's Kerberos territory,
  `sec=krb5`, almost certainly overkill for this setup).
- **Exposure is already narrow:** the `firewall-cmd` rule only admits the
  veth subnet, and the netns MASQUERADE means the only live source on it
  is the VM. Port 2049 is reachable by exactly one party: your agent.
- `config.sh`'s `JAILER_UID=1000` (user Firecracker runs as) is unrelated
  to the squash UID — don't reuse it.

## Efficiency notes (duplicate / excerpt detection)

NFS itself won't be the bottleneck — Firecracker's virtio-net does
multi-gigabit, and NFS gives the guest real random access (seek,
range reads), so `ffmpeg -ss ...` keyframe extraction works directly over
the mount without downloading whole files.

Match on what's cheap first:

1. **Transcript pass (reads only text, effectively cached after first
   use):** excerpts contain a contiguous run of the source video's
   transcript. N-gram containment or embedding alignment between short and
   long transcripts produces candidate pairs covering the whole library in
   minutes.
2. **Media confirmation (candidates only):** audio fingerprinting
   (Shazam-style, e.g. `dejavu`/`chromaprint`) returns a *time offset* —
   directly answering "this excerpt starts at 00:41:23 of that video".
   Keyframe pHash (`ffmpeg` + `phash`) also works over NFS via seeks.
3. **Avoid O(n²):** cluster by shared fingerprint bucket first, then align
   within clusters. Or precompute fingerprints on the host and drop the
   CSV next to the transcriptions — then the agent only ever reads small
   files.
