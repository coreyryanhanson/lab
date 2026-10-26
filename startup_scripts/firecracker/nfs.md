# Serving files to the VM: rclone SFTP (ro) + NFSv4 (rw)

How to share host data with the Firecracker VM. Two paths, each with
**server-side** enforcement:

| Path | Mechanism | Port | Enforcement |
|---|---|---|---|
| Read-only media library | `rclone serve sftp --read-only` | 2022 TCP | server rejects all write ops |
| Read-write scratch space | NFSv4 export | 2049 TCP | `all_squash` to one unprivileged uid |

Deliberately **not** exposed: port 22. The host's OpenSSH daemon — which
also handles your own logins — is unreachable from the VM. rclone replaces
it for file serving with a small, purpose-built daemon bound to the veth IP
only.

Why this design, after NFS-for-both failed in practice: NFS's AUTH_SYS
trusts client UID claims, and the exFAT hotplug media volume can't provide
the POSIX filehandles NFS export wants (v4 mounts fail `ENOENT` even when
the export registers; explicit `fsid=` did not resolve it; an ext4 loopback
image needs 2× peak disk for a 4 TB library). rclone's SFTP server speaks
to any filesystem and has no filesystem quirks. The rw scratch stays on NFS
because it works and needs POSIX ownership.

Companion script: `nfs-share.sh` (name kept for history) — nfsd and rclone
both run on demand, since the media volume is not always mounted.

---

## Ports

- **2022 TCP** — rclone SFTP, bound to `192.168.100.1` (the veth IP) in the
  systemd unit itself, so even without firewall rules it is not reachable on
  the LAN. `HOST_SERVICE_PORTS` opens it for the veth subnet.
- **2049 TCP** — NFSv4. Forced v4-only (`vers3=n` in `/etc/nfs.conf`), so
  rpcbind (111) and mountd (20048) never listen and 2049 is the whole story.

Network path reminder: VM traffic leaves the netns MASQUERADEd, so the host
sees connections from `192.168.100.0/24` (the veth subnet), **not**
`172.16.0.2`. Export client lists use the veth subnet; the VM reaches host
services at `192.168.100.1` (VETH_HOST_IP). Host services must bind an
address the VM can reach — rclone binds the veth IP explicitly; kernel nfsd
binds everything by construction.

## One-time host setup

```bash
sudo apt install nfs-kernel-server rclone
cd /root/lab/startup_scripts/firecracker
sudo ./nfs-share.sh setup
```

What `setup` does (all idempotent):

1. **rw scratch:** creates the squash user `rag-scraper` with uid
   `NFS_SQUASH_UID` from `.env` (no login), creates `/srv/rag-scrape` owned by it,
   refuses if the path is on a
   non-POSIX filesystem (exFAT can't serve a rw export), writes the
   NFSv4-only block into `/etc/nfs.conf`, appends to `/etc/exports`:

   ```
   /srv/rag-scrape  192.168.100.0/24(rw,no_subtree_check,all_squash,anonuid=<NFS_SQUASH_UID>,anongid=<NFS_SQUASH_UID>)
   ```

2. **ro library:** generates an ed25519 keypair at
   `keys/rclone_sftp_ed25519` (`keys/` is gitignored), installs the public
   key to `/etc/rclone-vm-share/authorized_keys` (public keys aren't
   secrets; the rclone service runs unprivileged and can't read `/root`),
   and writes a hardened systemd unit `rclone-ro.service`:

   ```
   ExecStart=/usr/bin/rclone serve sftp --read-only --addr 192.168.100.1:2022 \
     --user rag-reader --authorized-keys /etc/rclone-vm-share/authorized_keys \
     <NFS_RO_PATH>
   ```

   The service runs as the media-volume owner (`NFS_SERVE_USER` from
   `.env`), not root, with `NoNewPrivileges`/`ProtectSystem=strict`
   hardening. The served path appears as `/` to the client.

3. Removes the legacy sshd drop-in from the previous design if present.

Host-specific paths are environment variables in `.env` (`NFS_RO_PATH`,
`NFS_SERVE_USER`, `NFS_SQUASH_UID` — see `.env.example`); ports and the rw
export come from `config.sh` (`RO_PORT`, `RW_EXPORT`). Set your values, then
re-run `setup` (the unit file is regenerated; `/etc/exports` lines are only
added, never removed — clean stale ones by hand).

## Starting/stopping sharing (on demand)

```bash
sudo ./cleanup.sh && sudo ./start.sh   # VM up: netns, veth, firewall (2022+2049)
sudo ./nfs-share.sh start              # plug in + mount the media volume first
sudo ./nfs-share.sh stop               # closes both ports
./nfs-share.sh status
./nfs-share.sh vm                      # prints the VM-side commands
```

Order matters: `start` must run **after** `start.sh` — rclone binds to the
veth IP, which only exists while the VM networking is up. If it fails, run
it again after the VM is up; `Restart=on-failure` also retries it. When the
volume is unplugged, `stop` first, then unplug; replug + `start` brings
everything back.

## VM side

The read-only library mount is sshfs, which needs FUSE in the guest kernel.
The kernel is a prebuilt Firecracker CI download; `init_base.sh` verifies it
includes `CONFIG_FUSE_FS=y` and NFSv4 on every run, including re-runs against
an existing `images/vmlinux-*`. If you still see `fuse: device not found` in
the VM, the running VM is using a stale or different kernel — check the
`vmlinux` in the jailer chroot matches `images/vmlinux-6.1.188`, and if
necessary delete it and re-run `sudo ./init_base.sh` to re-download.

Both clients (`sshfs`, `nfs-common`) and the SFTP private key
(`/root/.ssh/rclone_sftp_ed25519`) are preinstalled/baked into the base
image by `init_base.sh`, so the VM side is just the two mounts:

```bash
sshfs -p 2022 -o ro,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,kernel_cache,cache=yes,entry_timeout=120,attr_timeout=120,compression=no,IdentityFile=/root/.ssh/rclone_sftp_ed25519,StrictHostKeyChecking=no rag-reader@192.168.100.1:/ /mnt/library

mount -t nfs4 192.168.100.1:/srv/rag-scrape /mnt/scrape
```

(Kept on one line deliberately — line-continuation backslashes in copied
commands are a paste-fragility trap: a single trailing space after `\`
splits the command.)

The caching flags matter: `kernel_cache` + long `entry_timeout`/`attr_timeout`
are safe on a read-only mount and make directory walks (`ls` on 200-entry
dirs, `find` over the tree, globs) effectively local after the first pass.
`compression=no` saves CPU on video/text payloads.

## Troubleshooting

1. sshfs "Connection refused" → rclone not running (`nfs-share.sh status`,
   `journalctl -u rclone-ro`) or port not open (`HOST_SERVICE_PORTS`, then
   `cleanup.sh && start.sh`).
2. sshfs "Permission denied (publickey)" → wrong `IdentityFile` path, or
   `/etc/rclone-vm-share/authorized_keys` doesn't match the key (re-run
   `setup`).
3. sshfs connects but directory is empty → the media volume isn't mounted
   on the host; unplug/replug the volume and re-run `start`.
4. NFS mount "access denied by server" → export client list wrong; must be
   `192.168.100.0/24` (MASQUERADE gotcha above).
5. NFS mount "No such file or directory" / port dead → `sudo ss -tln |
   grep 2049`, then `journalctl -u nfs-server`; check `vers3=n` applied.
6. rclone fails at boot of the unit → usually the veth IP not up yet; run
   `nfs-share.sh start` after `start.sh`, or `systemctl restart rclone-ro`.
7. `stop` "target is busy" → something on the host holds `/srv/rag-scrape`;
   nfsd is already down, sharing is off regardless.

## Security notes

- **ro side:** `--read-only` is enforced by the rclone server — the client
  `-o ro` flag is convenience, not the boundary. Auth is a single public
  key; there is no UID spoofing (unlike NFS AUTH_SYS, which trusts client
  UID claims). The service runs unprivileged with systemd hardening, bound
  to an IP reachable only from the VM's netns.
- **rw side:** AUTH_SYS trusts client UID claims, so `all_squash` is
  mandatory (every request rewritten to the `NFS_SQUASH_UID` user). Plain
  `root_squash` is *not* sufficient (it only maps UID 0). Residual risk:
  the agent filling host disk — put `/srv/rag-scrape` on its own volume or
  use an XFS project quota.
- **No encryption on NFS; SFTP is encrypted.** Over a local veth pair this
  doesn't matter; if either side ever moves off-host, revisit.
- **Exposure is narrow:** ports 2022/2049 only admit the veth subnet, and
  the netns MASQUERADE means the only live source is the VM. Host sshd
  (port 22) is not reachable from the VM at all.
- `config.sh`'s `JAILER_UID=1000` (user Firecracker runs as) is unrelated
  to the squash uid — don't reuse it.

## Efficiency notes (duplicate / excerpt detection)

Neither transport is the bottleneck on the veth link (multi-gigabit, ~0.1 ms
RTT). Match on what's cheap first:

1. **Transcript pass (reads only text, cached after first use):** excerpts
   contain a contiguous run of the source video's transcript. N-gram
   containment or embedding alignment between short and long transcripts
   produces candidate pairs covering the whole library in minutes.
2. **Media confirmation (candidates only):** audio fingerprinting
   (Shazam-style, e.g. `dejavu`/`chromaprint`) returns a *time offset* —
   directly answering "this excerpt starts at 00:41:23 of that video".
   Keyframe pHash (`ffmpeg` + `phash`) also works — seek-heavy access is
   fine over both sshfs and NFS.
3. **Avoid O(n²):** cluster by shared fingerprint bucket first, then align
   within clusters. Or precompute fingerprints on the host and drop the CSV
   next to the transcriptions — then the agent only ever reads small files.
