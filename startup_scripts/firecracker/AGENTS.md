# AGENTS.md — Firecracker VM manager

Bash-only project: builds a Debian Trixie rootfs, then boots Firecracker microVMs
with a read-only base + writable overlay. No tests, no linter, no CI, no package
manager. Verification means booting a VM from this directory.

Run every command from this directory. Every script except `show_disk_usage.sh`
sources `config.sh`, the single source of truth for paths, IPs, VM resources and
`HOST_SERVICE_PORTS`.

## Lifecycle (order matters)

```bash
cp .env.example .env          # required first; init_base.sh `source`s it under `set -e`
sudo ./init_base.sh           # ~minutes, network-heavy; writes base/rootfs.ext4,
                              # images/vmlinux-6.1.155, keys/debian-trixie.id_rsa
./create_overlay.sh <name>    # 8G sparse ext4 + overlays/<name>.base_checksum
sudo ./start.sh <name>        # aborts if netns fc-vm1 exists; else runs cleanup.sh first
ssh -i keys/debian-trixie.id_rsa root@172.16.0.2
sudo ./cleanup.sh             # VM, netns, firewall, bind mounts (overlay, rootfs, chroot)
```

Scripts call `sudo` internally, so the `sudo` prefixes are optional; run them as
your normal user if you want `cleanup.sh` to hand overlay ownership back to you
instead of root. Only **one VM at a time**: `NETNS`, `VM_ID` and the IPs are fixed
in `config.sh`; additional overlays are just extra disk images, not concurrent VMs.

## Host prerequisites

- `/dev/kvm` readable/writable; host needs `debootstrap`, `jq`, `iptables`,
  `firewall-cmd` (firewalld), `e2fsprogs`.
- `release-v1.15.1-x86_64/{firecracker,jailer}-v1.15.1-x86_64` must be placed by
  hand. No script downloads them and the directory is gitignored; `start.sh`
  fails its binary check if missing. Only the kernel is downloaded (`init_base.sh`).

## Artifacts and where they land

| Path | What |
| --- | --- |
| `base/rootfs.ext4` | 8G base image, built by `init_base.sh`; bind-mounted read-only at boot |
| `base/debian-trixie-rootfs/` | debootstrap working tree (intermediate; reused to skip debootstrap on rebuild) |
| `images/vmlinux-6.1.155` | kernel; the name is fixed in `config.sh` even though the downloader fetches the latest 6.1.x |
| `keys/debian-trixie.id_rsa` | guest root SSH key, generated once, gitignored |
| `overlays/<name>.ext4` + `.base_checksum` | writable layers; md5 of the base they were built against |
| `extracted-<name>/` | default output dir of `extract.sh` |
| `/srv/jailer/firecracker-v1.15.1-x86_64/vm1/root/` | jailer chroot: `vmlinux`, bind-mounted `rootfs.ext4`, `overlay.ext4`, `config.json` |
| `firecracker-vm1.log` | Firecracker output; deleted by `cleanup.sh` |

`base/`, `images/`, `overlays/`, `keys/`, `release*/`, `extracted-*/` and `.env` are
gitignored — never commit built images or the SSH key.

## Guest image: what gets installed

`init_base.sh` bakes all of this into the base image: none of it reaches an
existing overlay, and changing any of it means a rebuild. `inject.sh` can push
files into an overlay, but `/etc/profile.d/99-vm-env.sh` still comes from the base.

- openssh-server, curl/wget/git, build-essential, locales, e2fsprogs,
  `libgtk-3-0`; root login by key only (`PermitRootLogin prohibit-password`).
- **herdr** terminal multiplexer as the default terminal: `/root/.bashrc`
  `exec`s it on any interactive shell. Expect herdr, not a bare bash prompt, when
  SSHing in; it does not trigger for non-interactive commands.
- Python 3 + pip/venv, `uv` in `/usr/local/bin`, nvm + Node LTS
  (`config/chroot-scripts/install-nvm-node.sh`). **OpenCode is not installed** —
  Pi Coding Agent is the only agent in the image.
- Pi Coding Agent + five packages via `pi install npm:` (pi-subagents,
  `@juicesharp/rpiv-ask-user-question`, `@juicesharp/rpiv-todo`, pi-llama-cpp,
  pi-lean-dimension), then Playwright Chromium + Firefox
  (`npx playwright install --with-deps`).
- SearXNG as a systemd service on `127.0.0.1:8888` (granian; settings from
  `config/searxng/`).
- Every `KEY=value` line of `.env` exported via `/etc/profile.d/99-vm-env.sh`, plus
  git identity from `GIT_NAME`/`GIT_EMAIL`.

## Guest configuration (`config/`)

- `config/pi/` → `~/.pi/agent/` in the guest. `auth.json` (venice via
  `$VENICE_API_KEY`, llama.cpp at `192.168.100.1:8001`), `settings.json`
  (default `venice/z-ai-glm-5-3-flash`, thinking `high`, searxng at
  `127.0.0.1:8888`), `models.json` (custom `gondola-ai`, `openrouter`, `venice`
  providers), `extensions/` (`venice-ai`, `pi-init-plan`, `subagent`), `prompts/`.
- `config/searxng/` — unit file + `settings.yml` (JSON format enabled). The unit
  is shipped with `SEARXNG_HOST_PLACEHOLDER` / `SEARXNG_PORT_PLACEHOLDER`.
- `config/chroot-scripts/install-nvm-node.sh` — run only by `init_base.sh`.
- `config/opencode/` — leftover OpenCode vision tools, skills and `search.ts`;
  nothing installs or copies them, and no doc references them anymore.

`.env.example` defines only `VENICE_API_KEY`, `OPENROUTER_API_KEY`, `GIT_NAME`,
`GIT_EMAIL`, `SEARXNG_HOST`, `SEARXNG_PORT`, but `config/pi` also references
`$GONDOLA_API_KEY`, `$OPENROUTER_API_KEY1` (sic), `$SIYUAN_API_TOKEN`, and
host-only paths (`/root/pi-browser/...`, `../../knowledge-base`). So the
`gondola-ai`/`openrouter` providers, `gnubrain`, and the `*-py` browser backends are
non-functional in a fresh guest until you add the vars/files.

## Hard constraints

- **Rebuilding the base invalidates every overlay.** Each overlay stores the md5
  of the base it was created against and `start.sh` refuses to boot a mismatch.
  The only exits are recreating the overlay (data loss) or rewriting the checksum
  file (corruption risk). Treat `init_base.sh` as destructive.
- `init_base.sh` rewrites `config/searxng/searxng.service` in place, replacing the
  host/port placeholders. After one run the placeholders are gone, so later `.env`
  changes never reach the unit; restore the placeholders with git before committing.
- A crashed `init_base.sh` leaves `proc`/`sys`/`dev` mounted under
  `base/debian-trixie-rootfs/`, so `rm -rf` fails with EBUSY. See `rescue.md`
  (`umount -l` then delete). Note `rescue.md` is stale on one point: the EXIT
  cleanup trap it says is missing now exists in `init_base.sh`.

## Overlay files: reading and writing without a VM

`extract.sh` and `inject.sh` loop-mount the ext4 and operate on its `root/`
subdirectory (the OverlayFS upper dir, not the VM root). Consequences:

- VM must be stopped; both refuse if the jailer chroot is still mounted.
- `inject.sh` fails if the overlay was never booted, because overlay-init has not
  created `root/` and `work/` yet.
- `extract.sh` only sees files that exist in the overlay layer. Unmodified base
  files are absent and extraction reports "not found". `--list` shows changes and
  whiteouts.
- A dirty journal (force-killed VM) makes `extract.sh` stop and ask before it will
  read; `-y` skips that prompt, `inject.sh` repairs without asking.

Overlays are 8G sparse; `bash show_disk_usage.sh` shows apparent vs real size.
Guest disk is small by design — bulk data belongs on the host NFS shares.

## Networking and host services

- Guest `172.16.0.2` (netns `fc-vm1`) → host reachable at `192.168.100.1`, **not**
  localhost. Host services must bind `0.0.0.0` and be listed in
  `HOST_SERVICE_PORTS` (`8001 12315 6806 2049 2022` today); the `firewall-cmd` rich
  rules are only (re)applied by `start.sh`, so add a port then
  `cleanup.sh && start.sh`.
- Guest IP/routes/DNS come from kernel boot args (`start.sh` builds them), parsed
  by the `fcnet-setup` service in the base image — there is no DHCP.
- Sharing (`nfs-share.sh setup|start|stop|status|vm`, details in `nfs.md`): the
  read-only media library is served by `rclone serve sftp --read-only`
  (port 2022, bound to the veth IP, key auth via `keys/` — gitignored) and
  works on any filesystem — including the exFAT hotplug volume. The rw
  scratch is NFSv4 (port 2049 only, forced via `vers3=n`); exports must
  allow `192.168.100.0/24` because VM traffic is MASQUERADEd to the veth
  subnet — `172.16.0.2` silently gets "access denied" — and `all_squash` to
  uid 1005 is mandatory (AUTH_SYS trusts client UID claims). Paths live at
  the top of `nfs-share.sh` (`RO_PATH` for the library, rw scratch
  `/srv/rag-scrape`). Port 22 (host sshd) is deliberately NOT opened to the
  VM.

## Resource / config knobs

`config.sh` changes (`VM_VCPUS`, `VM_MEM_MIB`, ports, IPs) need no rebuild — just
`cleanup.sh && start.sh`. The kernel and base paths are hardcoded there and in
`init_base.sh`, including the fixed `vmlinux-6.1.155` name.

## Where reality differs from the docs

`create_overlay.sh`'s closing hint mentions a `bake_overlay.sh` that does not
exist, and `README.md`'s directory tree is approximate. Trust the scripts and
`config.sh` over prose.
