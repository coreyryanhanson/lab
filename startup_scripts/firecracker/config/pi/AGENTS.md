# Environment

This dev environment runs inside a **Firecracker microVM**.

## Toolchains

- **Python:** use `uv` for dependencies and virtualenvs (not pip/venv directly).
- **Node:** use `nvm` to manage Node versions.

## Constraints

- **No nested Docker.** The VM's rootfs is overlayfs, which cannot be stacked on itself — so `docker`/containerd cannot run containers inside this environment. Prefer native installs, `uv`, and `nvm` over container-based workflows.

## Test runs: tee to a log

Any test run: append `2>&1 | tee /tmp/<name>-test-$$.log | tail -15`.
On failure, grep the log — never rerun the suite to see the error.

## Code comments

Avoid references to plans, tickets, or the development process in code comments and test names. Comments should describe what the code does.
