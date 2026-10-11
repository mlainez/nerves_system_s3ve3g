################################################################################
#
# s3ve3g-firmware
#
################################################################################

S3VE3G_FIRMWARE_VERSION = 1.0
S3VE3G_FIRMWARE_SITE = $(NERVES_DEFCONFIG_DIR)/packages/s3ve3g-firmware
S3VE3G_FIRMWARE_SITE_METHOD = local
S3VE3G_FIRMWARE_LICENSE = Apache-2.0

define S3VE3G_FIRMWARE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/s3ve3g-bringup \
		$(TARGET_DIR)/usr/sbin/s3ve3g-bringup
endef

$(eval $(generic-package))
