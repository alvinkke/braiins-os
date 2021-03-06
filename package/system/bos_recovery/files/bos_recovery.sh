#!/bin/sh

# redirect STDOUT and STDERR to /dev/kmsg
exec 1<&- 2<&- 1>/dev/kmsg 2>&1

RECOVERY_MTD=/dev/mtd6
FIMRWARE1_MTD=/dev/mtd7
FIMRWARE2_MTD=/dev/mtd8

FACTORY_OFFSET=0x800000
FACTORY_SIZE=0xC00000

FPGA_OFFSET=0x1400000
FPGA_SIZE=0x100000

BOOT_OFFSET=0x1500000
BOOT_SIZE=0x80000

SD_DIR=/mnt

SD_FACTORY_BIN_PATH=$SD_DIR/factory.bin
SD_SYSTEM_BIT_PATH=$SD_DIR/system.bit
SD_BOOT_BIN_PATH=$SD_DIR/boot.bin

FACTORY_BIN_PATH=/tmp/factory.bin
SYSTEM_BIT_PATH=/tmp/system.bit
BOOT_BIN_PATH=/tmp/boot.bin

mtd_write() {
	mtd -e "$2" write "$1" "$2"
}

echo "System is in the recovery mode!"

# fix U-Boot environment configuration with correct MTD partiton
cp /tmp/fw_env.config /etc/

# try to set LEDs to signal recovery mode
green_led="/sys/class/leds/Green LED"
red_led="/sys/class/leds/Red LED"
echo timer > "$green_led/trigger"
echo 70 > "$green_led/delay_on"
echo 600 > "$green_led/delay_off"
echo nand-disk > "$red_led/trigger"

# prevent NAND corruption when U-Boot env cannot be read
if [ -n "$(fw_printenv 2>&1 >/dev/null)" ]; then
	echo "Do not use 'fw_setenv' to prevent NAND corruption!"
	exit 1
fi

FACTORY_RESET=$(fw_printenv -n factory_reset 2>/dev/null)
SD_IMAGES=$(fw_printenv -n sd_images 2>/dev/null)

# immediately exit when error occurs
set -e

if [ x${FACTORY_RESET} == x"yes" ]; then
	echo "Resetting to factory settings..."

	if [ x${SD_IMAGES} == x"yes" ]; then
		echo "recovery: using SD images for factory reset"

		# mount SD
		mount /dev/mmcblk0p1 ${SD_DIR}

		# copy factory image to temp
		cp "$SD_FACTORY_BIN_PATH" "$FACTORY_BIN_PATH"

		# compress bitstream for FPGA
		gzip -c "$SD_SYSTEM_BIT_PATH" > "$SYSTEM_BIT_PATH"

		# copy SPL bootloader to temp
		cp "$SD_BOOT_BIN_PATH" "$BOOT_BIN_PATH"

		umount ${SD_DIR}
	else
		# get uncompressed factory image
		nanddump -s ${FACTORY_OFFSET} -l ${FACTORY_SIZE} ${RECOVERY_MTD} \
		| gunzip \
		> "$FACTORY_BIN_PATH"

		# get bitstream for FPGA
		nanddump -s ${FPGA_OFFSET} -l ${FPGA_SIZE} ${RECOVERY_MTD} \
		> "$SYSTEM_BIT_PATH"

		# get uncompressed SPL bootloader
		nanddump -s ${BOOT_OFFSET} -l ${BOOT_SIZE} ${RECOVERY_MTD} \
		| gunzip \
		> "$BOOT_BIN_PATH"
	fi

	# write the same FPGA bitstream to both MTD partitions
	mtd_write "$SYSTEM_BIT_PATH" fpga1
	mtd_write "$SYSTEM_BIT_PATH" fpga2

	firmware2_magic=$(nanddump -ql 4 ${FIMRWARE2_MTD} | hexdump -v -n 4 -e '1/1 "%02x"')

	# erase firmware partitions
	mtd erase firmware1
	# firmware2 partition may contain stage3 tarball (erase only partition with UBI# magic)
	[ "$firmware2_magic" == "55424923" ] && mtd erase firmware2

	ubiformat ${FIMRWARE1_MTD} -f "$FACTORY_BIN_PATH"

	# remove factory reset mode from U-Boot env
	fw_setenv factory_reset

	# the SPL is restored as last one
	mtd_write "$BOOT_BIN_PATH" boot

	sync
	echo "recovery: factory reset has been successful!"

	# reboot system
	echo "Restarting system..."
	reboot
fi

# remove network settings passed from standard mode
fw_setenv --script - <<-EOF
	recovery_net_ip
	recovery_net_mask
	recovery_net_gateway
	recovery_net_dns_servers
	recovery_net_hostname
	# after successful recovery boot delete environment
	# variable 'first_boot' to allow standard boot process
	first_boot
EOF
