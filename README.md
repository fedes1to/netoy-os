# netoy-os

**The netoy-tui appliance.** An Alpine Linux-based bootable ISO that
turns a plain Ventoy stick into a self-contained USB ISO manager — boot
it, and the TUI (built from the [netoy-tui](https://forgejo.fedesito.me/fedesito/netoy-tui)
submodule in `for-bootable` mode) is right there on the serial console
*and* the VGA console, with your Ventoy data partition already mounted
and writable at `/mnt/netoy`.

## What you get

- A minimal Alpine environment that boots **straight into netoy-tui** —
  on both the serial console and VGA.
- All the networking tools preinstalled: `iwd` (D-Bus) + `impala` for
  Wi-Fi, `dhcpcd` for Ethernet, `iproute2` for manual/static config.
- The whole netoy ISO copied into RAM and Ventoy's boot hook
  neutralized — so the USB stick (or CD) can be **unplugged after boot**.
- The real Ventoy data partition mounted read-write at `/mnt/netoy`,
  so netoy-tui manages ISOs on it with zero runtime trickery.

## Why this exists

Booted through Ventoy, an ISO lives as a file on the USB data
partition, and Ventoy injects a userspace hook that creates a
`device-mapper` node over that partition. That node pins the partition
read-only, breaks the Alpine boot for this image, and blocks netoy-tui
from mounting it later.

This image sidesteps the whole mess in two small, explicit steps:

1. **An initramfs wrapper** copies the netoy ISO from the Ventoy data
   partition into RAM, attaches it to a loop device, then
   **neutralizes Ventoy** — drops `/ventoy/ventoy_os_param` and
   Ventoy's udev rules — so no competing `device-mapper` node is ever
   created and Alpine's modloop-extraction hook never runs. Alpine's
   `nlplug-findfs` then sees the RAM-backed loop as the only boot
   media. Because boot media is now a file in RAM, the physical stick
   can go.

2. **The OpenRC `netoy-ram` service** copies the compressed `modloop`
   squashfs into RAM, switches `/.modloop` to the RAM copy, unmounts
   the boot media, removes any leftover Ventoy `device-mapper` nodes,
   and finally mounts the real Ventoy data partition at `/mnt/netoy`.

Result: `/lib/modules`, firmware, and boot media all live in RAM, with
the Ventoy data partition already mounted for netoy-tui — no runtime
"undo trick" needed in the TUI.

> **Why not archiso?** Arch's `archiso` has a single `copytoram=y`
> parameter that copies the whole live rootfs to RAM. Alpine has no
> equivalent one-liner, so this image uses a small custom initramfs
> wrapper + OpenRC service to do the same job while staying inside
> Alpine's official `mkimage.sh` tooling.

## Build

```sh
./build.sh
```

Requirements on the host:

- `podman`
- The `netoy-tui` git submodule initialized: `git submodule update --init`

The script builds entirely inside an `alpine:3.24` container: compiles
`netoy-tui` with `--features for-bootable`, clones and compiles
`impala`, then runs Alpine's official `mkimage.sh` to produce the ISO
in `out/`. Newer builds are dated `YYMMDD`, e.g. `netoy-260724-x86_64.iso`.

## Try it in QEMU

```sh
./scripts/qemu-serial.sh
```

The ISO runs both a serial console (`console=ttyS0,115200`) and VGA
(`console=tty1`) — headless in QEMU or on a real monitor. Both auto-login
root and launch `netoy-tui`. **Note:** two independent TUI processes
run at the same time; use only one console for USB operations.

The script boots the latest ISO with `-nographic` and attaches the
serial port to your terminal. Press **Ctrl+A then C** to switch to the
QEMU monitor, then type `q` to quit.

What to expect:

- The bootloader (ISOLINUX) and kernel messages on the serial line.
- The initramfs wrapper copying the netoy ISO out of the Ventoy data
  partition into RAM (progress bar shown), neutralizing Ventoy's hook,
  and attaching the RAM copy as a loop device; `nlplug-findfs` then
  discovers it as the boot media.
- OpenRC's `netoy-ram` service copying the modloop into RAM, switching
  the loop to the RAM copy, unmounting boot media, removing Ventoy
  `device-mapper` nodes, and mounting the real data partition at
  `/mnt/netoy`.
- Auto-login on `ttyS0` and `tty1` (a tiny `getty -n -l` wrapper);
  `/root/.profile` starts netoy-tui. Press **Q** to drop to a shell;
  `inittab` respawns the login shell.
- Root login without a password on the local console by default.

## After boot

Auto-login root on every configured console via
`agetty --autologin root --login-program /usr/local/bin/netoy-autologin`
(`/bin/login -f root`); netoy-tui starts from `/root/.profile` on
`tty1` (VGA) and `ttyS0` (serial). `tty2`–`tty6` are auto-login root
shells.

- `<W>` on the Network screen starts `impala` to configure Wi-Fi.
- `<E>` auto-configures the first Ethernet interface with `dhcpcd` and
  reports a short status. Re-check with `<R>` to see the negotiated
  address.
- `<A>` opens the **manual Ethernet** form — DHCP or static, interface,
  IP, CIDR prefix, gateway, two DNS servers, MTU. **Enter** applies.
- `<M>` on the Manage ISOs screen remounts the Ventoy data partition at
  `/mnt/netoy` if needed (normally `netoy-ram` already did it at boot).

## Files

| File | Purpose |
|------|---------|
| `build.sh` | Host entry point that launches the container build. |
| `scripts/build-in-container.sh` | Runs inside the Alpine container; installs tools, builds Rust binaries, invokes `mkimage.sh`. |
| `scripts/qemu-serial.sh` | Boots the latest ISO under QEMU with a serial console for headless testing. |
| `vendor/mkimg.netoy.sh` | Alpine image profile for `mkimage.sh`. |
| `genapkovl-netoy.sh` | Generates the `netoy.apkovl.tar.gz` overlay: services, inittab, package world. |
| `overlay/usr/local/bin/netoy-autologin` | Tiny wrapper used by `agetty --autologin` for passwordless root. |
| `overlay/root/.profile` | Auto-starts `netoy-tui` on `tty1` / `ttyS0` root login. |
| `overlay/initramfs-files/netoy-copy-iso.sh` | Copies the ISO into RAM, neutralizes Ventoy, attaches the RAM copy as a loop device. |
| `overlay/` | Static files that go into the apkovl. |
| `vendor/` | Vendored Alpine `mkimage.sh` + `mkimg.base.sh` from aports 3.24-stable. |

## Notes / limitations

- The image is intentionally minimal: `iwd` for Wi-Fi link layer,
  `dhcpcd` for DHCP, `iproute2` for manual/static config.
- Want an even simpler (but more RAM-hungry) approach? Replace the
  compressed modloop copy in `netoy-ram` with Alpine's official
  `copy-modloop` tool, which copies the uncompressed `/lib/modules`
  tree to RAM.
