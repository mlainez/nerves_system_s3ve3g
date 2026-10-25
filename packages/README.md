# Buildroot packages

Every package's `Config.in` title carries a scope tag indicating how
hardware-specific it is.

| Tag | Meaning |
|---|---|
| `[Galaxy S III Neo]` | Bound to this phone: its partition names, its firmware locations. |

| Package | Tag | Notes |
|---|---|---|
| `citronics-initramfs` | `[Galaxy S III Neo]` | Early-boot initramfs: finds `userdata` by GPT name, maps the nested Nerves partitions with kpartx, pivots into the squashfs; USB telnet recovery on failure. |
| `s3ve3g-firmware` | `[Galaxy S III Neo]` | `s3ve3g-bringup`: links the WCNSS firmware from the stock `apnhlos`/`system` partitions into `/run/firmware`, copies the MAC addresses off `efs`, loads the Wi-Fi/Bluetooth drivers. Ships no firmware. |

`citronics-initramfs` follows
[`nerves_system_tickwatch_pro3`](https://github.com/mlainez/nerves_system_tickwatch_pro3);
the patches are rebased for this phone (partition aliases, a 30 s wait for
the USB gadget, which needs the SM5502 MUIC to probe first, busybox udhcpd
for the recovery address).

Rebooting into a bootloader mode needs no package: erlinit passes the
contents of `/run/reboot-param` to `reboot(2)` (see the README, *Rebooting
into Odin*).
