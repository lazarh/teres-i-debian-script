# Teres-I — Standalone Debian Build System

Build ARM Trusted Firmware, U-Boot, Linux kernel, and a Debian 13 (trixie) arm64
root filesystem for the [Olimex Teres-I](https://github.com/OLIMEX/DIY-LAPTOP)
DIY laptop (Allwinner A64 / sun50i-a64, ARM Cortex-A53 AArch64).

No Yocto required — everything is built via direct cross-compilation and `debootstrap`.

## Quick Start

### 1. Install build dependencies (once, as root)
```bash
sudo scripts/install-deps.sh
```

### 2. Build ARM Trusted Firmware + U-Boot
```bash
scripts/build-uboot.sh
```
Downloads and compiles TF-A BL31 for `sun50i_a64`, then builds U-Boot with
`teres_i_defconfig`.  Produces:
- `build/uboot/u-boot-sunxi-with-spl.bin`
- `build/uboot/boot.scr`

To build the closest thing to a vanilla U-Boot tree on this host, skipping the
Teres/runtime repo patches while still keeping the required host-build
compatibility fix:
```bash
UBOOT_PATCH_MODE=none scripts/build-uboot.sh
```

### 3. Build the kernel
```bash
scripts/build-kernel.sh
```
Produces:
- `build/kernel/Image`
- `build/kernel/sun50i-a64-teres-i.dtb`
- `build/kernel/modules/`

### 4. Build the Debian rootfs (as root)
```bash
sudo scripts/build-rootfs.sh
```
Produces `debian-rootfs/`.

To include the experimental fixed-time reboot workaround:
```bash
sudo BOOT_RETRY_TIMEOUT=90 BOOT_RETRY_MAX_REBOOTS=3 scripts/build-rootfs.sh
```
This enables `boot-retry-reboot.service`, which waits the configured number of
seconds after boot, checks whether Linux sees a connected DRM display with
available modes, and only then reboots if no display was detected. It also
stops retrying after the configured maximum reboot count. You can still stop
the service manually or create `/run/boot-retry-reboot.cancel`.

To pre-configure the hostname or WiFi:
```bash
# Set hostname at image build time (defaults to 'teres-i')
sudo HOSTNAME="mylaptop" scripts/build-rootfs.sh

# Pre-configure WiFi (requires WIFI_PASSWORD)
sudo WIFI_SSID="MyNetwork" WIFI_PASSWORD="secret" scripts/build-rootfs.sh
```

### 5. Assemble the SD card image (as root)
```bash
# Default output image under repo root
sudo scripts/assemble-sd-image.sh

# Or specify an explicit output image path:
sudo scripts/assemble-sd-image.sh /path/to/output.img
```
Produces `teres-i-debian13.img.gz` (and `.bmap`).

### 6. Flash to SD card
```bash
# Preferred (fast, sparse-aware):
bmaptool copy teres-i-debian13.img.gz /dev/sdX

# Alternative:
zcat teres-i-debian13.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

### 7. First boot — install to internal eMMC

Insert the SD card into the Teres-I and power on. After it boots, log in as root
and run:
```bash
install-to-nand.sh
```
This partitions the internal eMMC (`/dev/mmcblk2`), writes U-Boot at the 8 KiB
offset, copies boot files to a FAT32 partition, and copies the rootfs to an ext4
partition. Remove the SD card and reboot; the board will boot from eMMC.

## Default credentials

| | |
|---|---|
| User | `root` |
| Password | `root` |
| Serial console | `ttyS0 @ 115200` |

**Change the root password on first boot.**

## SD card partition layout

| Region | Content |
|---|---|
| Raw offset 8 KiB | U-Boot SPL + TF-A BL31 + U-Boot proper |
| Partition 1 (FAT32, 80 MiB) | `/boot` — Image, DTB, boot.scr, u-boot-sunxi-with-spl.bin |
| Partition 2 (ext4, rest) | `/` — Debian rootfs |

## eMMC layout (after `install-to-nand.sh`)

| Region | Content |
|---|---|
| Raw offset 8 KiB | U-Boot SPL + TF-A BL31 + U-Boot proper |
| Partition 1 (FAT32, 80 MiB) | `/boot` — Image, DTB, boot.scr |
| Partition 2 (ext4, rest) | `/` — Debian rootfs |

Linux names the internal eMMC as `/dev/mmcblk2`, but U-Boot sees it as `mmc 1`
on the Teres-I (`mmc 2` is the SDIO WiFi device, not storage). The generated
eMMC `boot.scr` therefore loads the kernel from `mmc 1:1` and boots with
`root=/dev/mmcblk2p2 rootfstype=ext4`.

## Build configuration

| Item | Value |
|---|---|
| ARM Trusted Firmware | v2.10.0, `sun50i_a64` platform |
| U-Boot | 2024.01, `teres_i_defconfig` |
| U-Boot flash offset | 8 KiB (same as all sunxi boards) |
| Kernel | 6.6.85, arm64 `defconfig` + `configs/kernel/teres-i.config` |
| Kernel image | `Image` (uncompressed AArch64) |
| Kernel boot command | `booti` |
| DTB | `sun50i-a64-teres-i.dtb` |
| Cross-compiler | `aarch64-linux-gnu-` (override via `CROSS_COMPILE=`) |
| Parallel jobs | `$(nproc)` (override via `JOBS=N`) |
| Debian suite | trixie (13), arm64 |
| WiFi | AP6212 (BCM43438, `brcmfmac`) or RTL8723BS (`rtl8723bs`) |
| Hostname pre-config | Optional — `HOSTNAME=mylaptop` |
| WiFi pre-config | Optional — `WIFI_SSID=... WIFI_PASSWORD=...` |

## Patches

Place `.patch` files in:
- `patches/uboot/` — applied to U-Boot before building
- `patches/kernel/` — applied to the kernel before building

Patches are applied in filename order with `patch -p1`.

## Cross-compiler override

```bash
# Use a custom toolchain
CROSS_COMPILE=aarch64-unknown-linux-gnu- scripts/build-uboot.sh
```

## Notes on the Allwinner A64 boot process

Unlike 32-bit sunxi SoCs (A20, A80, etc.), the A64 requires ARM Trusted Firmware
(TF-A) BL31 as the secure-world monitor.  `build-uboot.sh` compiles TF-A
automatically and passes `BL31=` to the U-Boot build.  The resulting
`u-boot-sunxi-with-spl.bin` embeds SPL, BL31, and U-Boot proper in a single
binary that is written to offset 8 KiB — identical to all other sunxi boards.
