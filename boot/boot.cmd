# Boot from SD card on Olimex Teres-I.
#
# Linux MMC enumeration on the Teres-I (A64):
#   mmc@1c0f000 → mmc0 / mmcblk0  : SD card slot
#   mmc@1c10000 → mmc1             : SDIO WiFi (BCM43438/RTL8723BS) — no block device
#   mmc@1c11000 → mmc2 / mmcblk2  : internal eMMC/NAND
#
# U-Boot MMC enumeration on the same board:
#   mmc 0 : SD card slot
#   mmc 1 : internal eMMC
#   mmc 2 : SDIO WiFi (non-storage)
#
# The SDIO WiFi chip does NOT create a mmcblk device, so the SD card is
# always mmcblk0 regardless of WiFi chip presence.
#
# Uses booti (not bootz) because the kernel image is arm64 Image.
# The DTB is sun50i-a64-teres-i.dtb from the boot partition.

setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/mmcblk0p2 rootwait panic=10 ${extra}
load mmc 0:1 ${fdt_addr_r} sun50i-a64-teres-i.dtb
load mmc 0:1 ${kernel_addr_r} Image
booti ${kernel_addr_r} - ${fdt_addr_r}
