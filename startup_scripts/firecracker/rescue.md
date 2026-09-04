# Rescue Guide — Firecracker Base Build

## The Problem

When `init_base.sh` crashes mid-build (e.g. due to `set -e` hitting a failing command),
three virtual filesystems remain mounted inside `base/debian-trixie-rootfs/`:

| Mount point | Type | Purpose |
|---|---|---|
| `base/debian-trixie-rootfs/proc` | `proc` | Process filesystem for chroot |
| `base/debian-trixie-rootfs/sys` | `sysfs` | Kernel/sysfs for chroot |
| `base/debian-trixie-rootfs/dev` | `devtmpfs` | Device nodes for chroot |

These are the mounts created at lines 56–58 of `init_base.sh`. The unmount (line 540)
only runs if the script survives to the very end — with `set -e` and no cleanup trap,
any earlier failure leaves them behind.

### Why `sudo rm -rf` appears to "stop working"

The kernel **refuses to delete an active mount point**. When you run:

```bash
sudo rm -rf base/debian-trixie-rootfs
```

the `rm` command hits directories that are still serving as mount points and either:

- Fails with **"Device or resource busy"** errors (and may leave partial debris), or
- Silently skips the mount-point directories, leaving the directory tree intact

This looks like "sudo isn't working" but `sudo` itself is fine — it's `rm` that's
blocked by the kernel.

> **The script does NOT change your user identity.**  No `chown` is ever performed
> on user-owned directories outside the build tree, and the `sudo chown -R root:root`
> on line 547 only applies to `$ROOTFS_DIR` (the debootstrap target) — and only
> after the unmount step, so if the script crashes, that chown never runs either.

---

## Manual Recovery

If you have leftover mounts right now (or they appear again in the future):

```bash
# Unmount the three virtual filesystems
sudo umount base/debian-trixie-rootfs/proc \
             base/debian-trixie-rootfs/sys \
             base/debian-trixie-rootfs/dev

# If the above fails with "target is busy", use lazy unmounts:
sudo umount -l base/debian-trixie-rootfs/proc
sudo umount -l base/debian-trixie-rootfs/sys
sudo umount -l base/debian-trixie-rootfs/dev

# Now the recursive delete works
sudo rm -rf base/debian-trixie-rootfs
```

### Verify mounts are gone

```bash
mount | grep debian-trixie-rootfs
```

Should return nothing. If it still shows entries, use `sudo umount -l` for each.

---

## The Fix (applied to `init_base.sh`)

A cleanup trap is now registered on `EXIT` **after** `ROOTFS_DIR` is defined:

```bash
cleanup_mounts() {
    local rc=$?
    if [ -n "${ROOTFS_DIR}" ]; then
        sudo umount "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys" "${ROOTFS_DIR}/dev" 2>/dev/null || true
    fi
    exit $rc
}
trap cleanup_mounts EXIT
```

Key design decisions:

| Detail | Why |
|---|---|
| **Placed after `ROOTFS_DIR=`** | If the script fails before `ROOTFS_DIR` is set (e.g. missing `.env`), the trap does nothing safe |
| **`if [ -n "${ROOTFS_DIR}" ]` guard** | Prevents accidentally trying to unmount the **host's** `/proc`, `/sys`, `/dev` on an empty variable |
| **`local rc=$?`** | Captures the script's real exit code before the trap runs; the trap exits with that same code |
| **`2>/dev/null \|\| true`** | If the mounts are already gone (normal exit after line 540), the trap silently skips |
| **`EXIT` trap (not `ERR`)** | Runs on *any* exit — success, failure, SIGINT, etc. — so mounts are always cleaned up |

---

## Prevention Tips

1. **If developing the script in a loop**, keep a shell alias handy for quick cleanup:

   ```bash
   alias fc-cleanup='sudo umount -l base/debian-trixie-rootfs/proc base/debian-trixie-rootfs/sys base/debian-trixie-rootfs/dev 2>/dev/null; sudo rm -rf base/debian-trixie-rootfs'
   ```

2. **Run the script with `bash -x`** when debugging to see exactly where it fails:

   ```bash
   sudo bash -x ./init_base.sh 2>&1 | tee build.log
   ```

3. **If you use `set -e` in any script that creates mounts, always pair it with a cleanup trap.** The pattern is:

   ```bash
   cleanup() { local rc=$?; umount ...; exit $rc; }
   trap cleanup EXIT
   ```

4. **Check for straggler mounts** if a build feels stuck:

   ```bash
   mount | grep "$(pwd)/base"
   ```
