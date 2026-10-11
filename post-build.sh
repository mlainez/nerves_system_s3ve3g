#!/bin/sh

set -e

# Build the fwup operations archive (status / factory-reset / revert /
# validate / grow-app). Ends up on target at /usr/share/fwup/ops.fw.
mkdir -p $TARGET_DIR/usr/share/fwup
$HOST_DIR/usr/bin/fwup -c \
    -f $NERVES_DEFCONFIG_DIR/fwup-ops.conf \
    -o $TARGET_DIR/usr/share/fwup/ops.fw
ln -sf ops.fw $TARGET_DIR/usr/share/fwup/revert.fw

# Make the fwup includes resolvable next to the rootfs image.
cp -rf $NERVES_DEFCONFIG_DIR/fwup_include $BINARIES_DIR
