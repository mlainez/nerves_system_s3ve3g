################################################################################
#
# citronics-initramfs (Nerves-flavoured: source paths live under
# $(NERVES_DEFCONFIG_DIR); deviceinfo and the modules list ship inside this
# package rather than under a $(BR2_EXTERNAL)/board/<name>/overlay directory)
#
################################################################################

CITRONICS_INITRAMFS_VERSION = 6e058d7
CITRONICS_INITRAMFS_SITE = https://github.com/Citronics/initramfs.git
CITRONICS_INITRAMFS_SITE_METHOD = git
CITRONICS_INITRAMFS_LICENSE_FILES = LICENSE

CITRONICS_INITRAMFS_DEPENDENCIES = busybox unudhcpd multipath-tools

CITRONICS_INITRAMFS_STAGING = $(@D)/initramfs-root
CITRONICS_INITRAMFS_SRC_DIR = initramfs/usr/share/citronics-initramfs
CITRONICS_INITRAMFS_PKG_DIR = $(NERVES_DEFCONFIG_DIR)/packages/citronics-initramfs
# Only the non-busybox programs the patched init/functions.sh invokes:
# kpartx (subpartition mapping) and unudhcpd (USB-recovery DHCP). The
# upstream resize path (parted, resize2fs) is never reached with
# nerves_base=; everything else is busybox, and would only inflate the
# cpio.gz against lk2nd's 50 MiB boot-memory window.
CITRONICS_BINARIES = busybox kpartx unudhcpd

KERNEL_VERSION = $(shell find $(TARGET_DIR)/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)

# The kernel modules tree must exist before the version can be read.
CITRONICS_INITRAMFS_DEPENDENCIES += linux

define CITRONICS_INITRAMFS_BUILD_CMDS
	true
endef

define CITRONICS_INITRAMFS_INSTALL_TARGET_CMDS
	rm -rf $(CITRONICS_INITRAMFS_STAGING)
	mkdir -p $(CITRONICS_INITRAMFS_STAGING)
	mkdir -p $(CITRONICS_INITRAMFS_STAGING)/{bin,sbin,usr/bin,usr/sbin,lib,etc,proc,sys,dev,tmp,var,run,mnt,root,sysroot}
	chmod 1777 $(CITRONICS_INITRAMFS_STAGING)/tmp
	chmod 1777 $(CITRONICS_INITRAMFS_STAGING)/run

	# On armv7 the dynamic loader (ld-linux-armhf.so.3) lives in /lib and
	# searches /lib and /usr/lib, so unlike the aarch64 systems no lib64
	# links are needed. copy_libs_for_binary.sh copies it via PT_INTERP.

	cp -aL $(@D)/$(CITRONICS_INITRAMFS_SRC_DIR)/* $(CITRONICS_INITRAMFS_STAGING)/
	mkdir -p $(CITRONICS_INITRAMFS_STAGING)/usr/share/deviceinfo
	cp -RaL $(CITRONICS_INITRAMFS_STAGING)/misc $(CITRONICS_INITRAMFS_STAGING)/usr/share/misc
	$(INSTALL) -D -m 0644 $(CITRONICS_INITRAMFS_PKG_DIR)/deviceinfo \
		$(CITRONICS_INITRAMFS_STAGING)/usr/share/deviceinfo/deviceinfo

	# The upstream initramfs.load lists Fairphone 2 modules that do not
	# exist on this kernel; everything this initramfs needs is built in.
	: > $(CITRONICS_INITRAMFS_STAGING)/lib/modules/initramfs.load

	mkdir -p $(CITRONICS_INITRAMFS_STAGING)/lib/modules/$(KERNEL_VERSION)
	@echo "Detected kernel version: $(KERNEL_VERSION)"
	while read -r modpath; do \
		case "$$modpath" in ""|\#*) continue;; esac; \
		src="$(TARGET_DIR)/lib/modules/$(KERNEL_VERSION)/$$modpath"; \
		dest="$(CITRONICS_INITRAMFS_STAGING)/lib/modules/$(KERNEL_VERSION)/$$modpath"; \
		if [ -f "$$src" ]; then \
			mkdir -p "$$(dirname "$$dest")"; \
			cp -aL "$$src" "$$dest"; \
		else \
			echo "  warn: module $$modpath not present in target, skipping"; \
		fi; \
	done < $(CITRONICS_INITRAMFS_PKG_DIR)/modules

	for bin in $(CITRONICS_BINARIES); do \
		src=""; \
		for dir in usr/sbin sbin usr/bin bin; do \
			candidate="$(TARGET_DIR)/$$dir/$$bin"; \
			if [ -x "$$candidate" ]; then \
				src="$$candidate"; \
				break; \
			fi; \
		done; \
		if [ -z "$$src" ]; then \
			echo "  warn: binary $$bin not found in target"; \
		else \
			relpath=$$(realpath --relative-to=$(TARGET_DIR) $$src); \
			dest="$(CITRONICS_INITRAMFS_STAGING)/$$relpath"; \
			mkdir -p "$$(dirname $$dest)"; \
			cp -aL "$$src" "$$dest"; \
			$(CITRONICS_INITRAMFS_PKG_DIR)/scripts/copy_libs_for_binary.sh \
				$$src $(TARGET_DIR) $(CITRONICS_INITRAMFS_STAGING) $(TARGET_READELF) ; \
		fi; \
	done

	cd $(CITRONICS_INITRAMFS_STAGING)/bin && \
		ln -sf busybox sh && \
		ln -sf busybox telnetd && \
		ln -sf busybox getty

	# No firmware is baked in. lk2nd leaves the panel lit and the kernel
	# binds it with simpledrm, so nothing requests firmware before
	# switch_root; the WCNSS images are staged from the phone's own
	# partitions after the rootfs is up (s3ve3g-bringup).

	# The init relies on devtmpfs for device nodes: /usr/lib/udev and its
	# libcrypto dependency chain stay out of the cpio.

	(cd $(CITRONICS_INITRAMFS_STAGING) && \
		find . | cpio -o -H newc --owner root:root > ../initramfs.cpio)
	gzip -f -n $(@D)/initramfs.cpio
	cp $(@D)/initramfs.cpio.gz $(BINARIES_DIR)/initramfs.gz
endef

$(eval $(generic-package))
