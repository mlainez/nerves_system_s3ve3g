# Nerves System: Samsung Galaxy S III Neo

Nerves system for the **Samsung Galaxy S III Neo (GT-I9301I, `s3ve3g`)**:
Qualcomm MSM8228 (msm8226 family), armv7.

| Feature | Description |
| --- | --- |
| CPU | 4x Cortex-A7 @ 1.2 GHz (MSM8228), armv7 |
| Memory | 1.5 GB |
| Storage | 16 GB eMMC; firmware lives inside the stock `userdata` partition |
| Display | 720x1280 AMOLED, via the bootloader's framebuffer and simpledrm |
| Linux | [`msm8226-mainline/linux`](https://github.com/msm8226-mainline/linux) `v6.16.12-msm8226-u2` + board device tree patches |
| Bootloader | Samsung aboot -> lk2nd (on `boot`) -> `extlinux/extlinux.conf` on the boot subpartition |
| Console | On-device display (`tty1`); ssh over USB (`usb0`, g_ether) |
| Wi-Fi / BT | WCNSS Pronto + WCN3660 (`wcn36xx`, `btqcomsmd`); firmware read from the phone's own partitions |
| Charging | PM8226 SMBB charger, 500 mA input limit |

## Status

The layout and the fwup tasks are checked on the host
(`scripts/host-check-fwup.sh`, see [Host checks](#host-checks)). Nothing in
this system has booted on a phone yet. It is built from the port's
Buildroot board (`buildroot-android`, board `s3ve3g`), which boots from
`userdata` through lk2nd with the same kernel, device tree and command
line, and charges. Wi-Fi is being brought up there; the device tree patch
for it is included here.

## Using

In your Nerves application's `mix.exs`, add the system under a target name
of your choice (here `:s3ve3g`):

```elixir
@all_targets [:s3ve3g]

defp deps do
  [
    {:nerves_system_s3ve3g,
     path: "../nerves_system_s3ve3g", runtime: false, targets: :s3ve3g,
     nerves: [compile: true]},
    {:nerves_pack, "~> 0.7.1", targets: @all_targets},
    # Images flashed raw keep their build-time application partition size.
    {:nerves_data_resize, github: "mlainez/nerves_data_resize", targets: @all_targets}
  ]
end
```

Then set `MIX_TARGET=s3ve3g`. USB networking is `usb0` with
`VintageNetDirect`; Wi-Fi is `wlan0` with `VintageNetWiFi`. The MAC
addresses from the phone's `efs` partition are copied to
`/run/s3ve3g/wlan0.mac` and `/run/s3ve3g/bt.mac` at boot, for a
`mac_address` callback.

## Building

You need the Nerves toolchain prerequisites (Erlang/OTP 29, Elixir 1.20,
`fwup`, `squashfs-tools`, `cmake`, `autoconf`, `bc`, `libssl-dev`), and about
15 GB of free disk for the Buildroot build.

```bash
mix archive.install hex nerves_bootstrap
cd your_app
export MIX_TARGET=s3ve3g
mix deps.get          # toolchain (~250 MB), Buildroot, kernel tarball
mix firmware          # first build 30-60 min
mix firmware.image    # raw image of the whole userdata layout
```

Useful side channels:

- `mix nerves.system.shell`: a shell in the Buildroot build directory, for
  `make menuconfig` / `make linux-menuconfig`
- `MIX_DEBUG=1 mix compile`: every Buildroot command
- `rm -rf _build/s3ve3g_* && mix deps.compile nerves_system_s3ve3g --force`:
  rebuild the system after a defconfig change

`nerves_defconfig` pins the kernel to a commit tarball. To build from a local
checkout instead, copy `local.mk.example` to `local.mk`.

## Partition layout

The Samsung bootloader chain cannot be repartitioned, so the whole Nerves
layout is nested *inside* the stock `userdata` partition (`mmcblk0p26`,
24536415 blocks, 11.70 GiB).

```
userdata (mmcblk0p26)  ── heimdall flash --USERDATA <app>.img ──
├─ MBR             block 0
├─ uboot env       block 2048     (8 KiB, firmware metadata)
├─ Boot A          block 2064     (ext2, 64 MiB: zImage, DTB, initramfs, extlinux)
├─ Boot B          block 133136   (ext2, 64 MiB)
├─ Rootfs A        block 264208   (squashfs, 384 MiB)
├─ Rootfs B        block 1050640  (squashfs, 384 MiB)
└─ Application     block 1837072  (f2fs, 256 MiB as flashed; grow-app extends it
                                   to block 24536415, mounted at /root)
```

The nested MBR always lists the slot that boots next as partitions 1 and 2;
the other slot is not in the table. Switching slots is one MBR write.

| Alias (made by the initramfs) | What |
| --- | --- |
| `/dev/rootdisk0`, `/dev/nerves-userdata` | the stock `userdata` partition, found by GPT name |
| `/dev/nerves-boot` | partition 1: the active boot slot, mounted read-only at `/boot` |
| `/dev/nerves-rootfs` | partition 2: the active squashfs rootfs |
| `/dev/nerves-app` | partition 3: application data, f2fs, `/root` |
| `/dev/nerves-apnhlos`, `-system`, `-modem`, `-efs`, `-persist` | stock partitions; `apnhlos` and `system` are mounted read-only for firmware |

## Boot chain

```
Samsung aboot ── keys, restart reason ──▶ lk2nd (first 512 KiB of `boot`)
lk2nd ── every GPT partition, then the MBR inside each one; ext2 leaves >= 16 MiB
      ──▶ /extlinux/extlinux.conf on userdata's nested partition 1 (the active boot slot)
kernel + initramfs ── nerves_base=userdata: GPT name lookup, kpartx, mount p2, switch_root
      ──▶ erlinit ──▶ s3ve3g-bringup ──▶ your OTP release
```

lk2nd publishes each GPT partition as a block device and runs its MBR
parser over each one (`lk2nd/hw/bdev/wrapper.c`), so the nested layout
appears as another level of block devices. It mounts each leaf of 16 MiB or
more as ext2 and boots the first `/extlinux/extlinux.conf` it finds. Its
ext2 driver reads plain ext2 only, which is what `genext2fs` writes. Kernel,
initramfs and DTB share 50 MiB of boot memory; `scripts/create-boot-img.sh`
refuses a payload over 47 MiB.

lk2nd has no boot menu, no boot counter and no way to receive a slot choice
from Linux (Samsung aboot consumes the restart reason). So:

- an upgrade marks the new slot valid as soon as fwup finishes, as in the
  official Nerves systems without automatic fallback;
- going back is an explicit `Nerves.Runtime.revert()`, or one of the escape
  routes below.

## Updating

Over the network (USB or Wi-Fi), as on any Nerves device:

```bash
mix firmware && mix upload nerves-XXXX.local   # or the usb0 address
```

`fwup` writes the inactive slot, then flips `nerves_fw_active` and the
nested MBR; the next reboot runs the new slot. `Nerves.Runtime.revert()`
flips them back and reboots.

Do not upload twice without rebooting in between: the second upload would
write over the slot that is running (`require-path-at-offset` cannot see
through the kpartx mapping, so fwup cannot tell which slot is running).

### Rebooting into Odin (download mode) from Nerves

```elixir
File.write!("/run/reboot-param", "download")
Nerves.Runtime.reboot()
```

erlinit passes the contents of `/run/reboot-param` to `reboot(2)`; the
kernel's syscon-reboot-mode writes the Samsung magic to IMEM, and
`reboot=warm` keeps IMEM across the reset, so aboot enters download mode.

### Re-imaging everything

In download mode (`Vol Down + Home + Power`, then `Vol Up`, or the reboot
above):

```bash
heimdall flash --USERDATA your_app.img
```

heimdall writes the raw file from the start of `userdata` (it does not
unpack Android sparse images). Application data is lost.

## Escape routes

1. **The new firmware boots but misbehaves:** `Nerves.Runtime.revert()`.
2. **The new firmware does not come up:** release Power at the Samsung logo
   and hold Vol Down: lk2nd's fastboot menu. RAM-boot the port's rescue
   image (`fastboot boot output/rescue/images/boot.img`), ssh to
   `10.0.42.1`, and run the *old* slot's own fwup from inside its squashfs
   (the commands are in the port's `dossier/nerves-design.md`).
3. **The initramfs cannot mount the rootfs:** it brings up `usb0` at
   `10.0.42.1` and a telnet shell (`telnet 10.0.42.1`).
4. **Anything else:** download mode and `heimdall flash --USERDATA` with a
   known-good image (a Nerves `.img`, or the Buildroot `rootfs.ext2`).
   `boot` (lk2nd) is never written by this system.

## Driver bring-up

erlinit is PID 1 and there is no init system. `/usr/sbin/s3ve3g-bringup`
runs through erlinit's `--pre-run-exec`, after the mounts and before Erlang:

1. link `wcnss.mdt` and its segments from `/mnt/apnhlos/image` (vfat,
   read-only) and `WCNSS_qcom_wlan_nv.bin` from `/mnt/system`
   (stock ext4, read-only, `noload`) into `/run/firmware`;
2. point `firmware_class.path` at it;
3. copy the Wi-Fi and Bluetooth MAC addresses from `efs` (mounted read-only
   with `noload` for the copy, then unmounted) to `/run/s3ve3g`;
4. `modprobe qcom_wcnss_pil wcn36xx btqcomsmd`.

It always exits 0; `dmesg | grep s3ve3g-bringup` shows what it found.
nerves_uevent loads other modules by alias as devices appear;
`/etc/modprobe.d/s3ve3g-display.conf` keeps `msm` and the panel drivers
from taking the display over from simpledrm.

## Host checks

```bash
scripts/host-check-fwup.sh [work-dir]
```

Builds `.fw` files from stand-in images (or from `BINARIES_DIR` after a
real build), runs `complete` into a file, copies it into a sparse file the
size of `userdata` the way heimdall would, and checks the nested MBR, the
U-Boot environment, lk2nd's partition rules, upgrade, status, revert,
validate, prevent-revert, grow-app and factory-reset.

## Known gaps

- Not yet booted on a phone.
- No automatic fallback to the previous slot (lk2nd has no boot counter).
- Charging stays at a 500 mA input limit for every cable; the temperature
  policy Samsung enforced in software is not implemented.
- No fuel gauge, modem, audio, sensors, touchscreen or GPU.
- `status` reports the slot that boots next, not the running one, between
  an upgrade and the reboot after it.

## License

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
