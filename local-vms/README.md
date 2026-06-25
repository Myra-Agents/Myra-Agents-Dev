# local-vms — Windows 11 + Ubuntu via QEMU (Docker)

Local throwaway VMs through [dockur](https://github.com/dockur/windows)
(QEMU-in-Docker) with a clientless web viewer. Driven by `./dev.sh env`.

```bash
./dev.sh env start win        # Windows 11  → http://localhost:8006
./dev.sh env start ubuntu     # Ubuntu      → http://localhost:8007
./dev.sh env start all        # both
./dev.sh env status           # docker compose ps
./dev.sh env stop win         # stop when idle (VMs are heavy)
```

`env start` creates `.env` from `.env.example` on first run (set `WIN_PASSWORD`).

| VM       | viewer                 | RDP/SSH              | creds                       |
|----------|------------------------|----------------------|-----------------------------|
| Windows  | http://localhost:8006  | RDP `localhost:3389` | `admin` / `$WIN_PASSWORD`   |
| Ubuntu   | http://localhost:8007  | SSH `localhost:2222` | set in guest                |

---

## ⚠️ Read this first — Apple Silicon Mac has no KVM

These images are **x86 QEMU and need `/dev/kvm`** to be usable. On an Apple
Silicon Mac:

- Docker Desktop runs containers inside its **own Linux VM**, which has **no
  nested virtualization** — `/dev/kvm` does not exist (`ls /dev/kvm` → not found).
- So QEMU falls back to **TCG software emulation**: boots are **very slow**, and
  **Windows 11 is often unusable** this way. Ubuntu is slow-but-tolerable.

This compose is provided for completeness / for running on a **Linux x86 host
with KVM** (uncomment the `/dev/kvm` device lines — then it's fast). On the Mac,
prefer a native hypervisor below.

### Fast native alternatives on this Mac (recommended)

All use Apple's Hypervisor.framework (HVF) → near-native speed. They run **ARM**
guests (Win11 ARM, Ubuntu ARM), not x86.

| Tool | Best for | One-liner |
|------|----------|-----------|
| [**Tart**](https://tart.run) | scriptable Win/Linux VMs (CLI, CI-friendly) | `brew install cirruslabs/cli/tart` |
| [**UTM**](https://mac.getutm.app) | GUI, point-and-click VMs | `brew install --cask utm` |
| [**Lima**](https://lima-vm.io) | headless Linux dev VMs | `brew install lima && limactl start` |
| [**Multipass**](https://multipass.run) | quick Ubuntu instances | `brew install --cask multipass` |

> The remote lab on **cergy-server** (Linux x86 + KVM) already serves fully
> accelerated Windows / Ubuntu / macOS over Guacamole — use that when you need
> real speed and don't want to tie up the Mac.

---

## Notes

- First Windows boot downloads the ISO + auto-installs (watch on `:8006`).
- Disks persist under `./storage/` (gitignored).
- Ubuntu SSH: install `openssh-server` in the guest, then `ssh -p 2222 user@localhost`.
- Change `BOOT` (Ubuntu) / `VERSION` (Windows) in `docker-compose.yml` for other releases.
