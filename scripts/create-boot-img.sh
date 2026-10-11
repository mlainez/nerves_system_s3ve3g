#!/bin/sh
#
# create-boot-img.sh
#
# Builds the ext2 "boot" image that lk2nd reads from the active boot
# subpartition. Layout inside the image:
#
#   /zImage                               kernel
#   /qcom-msm8226-samsung-s3ve3g.dtb      device tree
#   /initramfs.gz                         citronics initramfs (cpio.gz)
#   /extlinux/extlinux.conf               bootloader configuration
#
# Inputs (env, from Buildroot's post-image stage):
#   $BINARIES_DIR         buildroot output/images/
#   $NERVES_DEFCONFIG_DIR this nerves_system_s3ve3g source tree
#
# Output:
#   $BINARIES_DIR/boot.img                referenced from fwup.conf

set -e

DTB=qcom-msm8226-samsung-s3ve3g.dtb
STAGING="$BINARIES_DIR/boot"
rm -rf "$STAGING"
mkdir -p "$STAGING/extlinux"

fail() { echo "create-boot-img.sh: $*" >&2; exit 1; }

cp "$NERVES_DEFCONFIG_DIR/extlinux/extlinux.conf" "$STAGING/extlinux/extlinux.conf"

[ -f "$BINARIES_DIR/zImage" ] || fail "no zImage in $BINARIES_DIR"
cp "$BINARIES_DIR/zImage" "$STAGING/zImage"

[ -f "$BINARIES_DIR/$DTB" ] || fail "no $DTB in $BINARIES_DIR"
cp "$BINARIES_DIR/$DTB" "$STAGING/$DTB"

# Without the initramfs nothing maps the nested partitions and the kernel
# waits forever for a root device.
[ -f "$BINARIES_DIR/initramfs.gz" ] || fail "no initramfs.gz in $BINARIES_DIR"
cp "$BINARIES_DIR/initramfs.gz" "$STAGING/initramfs.gz"

# lk2nd loads the kernel, initramfs and DTB into a 50 MiB window
# (LK2ND_BOOT_MEM_SIZE). Past that the phone stops in the lk2nd menu.
BOOT_BYTES=$(du -sb "$STAGING" | cut -f1)
BOOT_LIMIT=$((47 * 1024 * 1024))
if [ "$BOOT_BYTES" -gt "$BOOT_LIMIT" ]; then
    fail "boot payload is $((BOOT_BYTES / 1024 / 1024)) MiB; lk2nd gives kernel + initramfs + DTB 50 MiB"
fi

# 1024-byte blocks * 65536 = 64 MiB; must stay <= BOOT_A_PART_COUNT
# (131072 blocks of 512 B) in fwup-common.conf.
#
# genext2fs writes plain ext2 with no read-only-compatible features, which
# is what lk2nd's ext2 driver (lib/fs/ext2) can read: it refuses any
# ro_compat feature beyond sparse_super and large_file, and maps file blocks
# through indirect blocks only.
genext2fs -B 1024 -b 65536 -d "$STAGING" "$BINARIES_DIR/boot.img"
