#!/system/bin/sh
# LZ4KDS WebUI 后端：供 webroot/index.html 调用
MOD=/data/adb/modules/lz4kds
S=/sys/block/zram0/sddc_stat
P=/sys/module/oplus_bsp_hybridswap_zram/parameters

getstat() {
	grep "^$1:" "$S" 2>/dev/null | awk '{print $2}'
}

case "$1" in
status)
	echo "disksize=$(cat /sys/block/zram0/disksize 2>/dev/null)"
	echo "comp=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null)"
	echo "cfg_size=$(sed -n 's/.*zram_size_mb=\([0-9][0-9]*\).*/\1/p' "$MOD/preinit/preinit.conf" 2>/dev/null | head -1)"
	echo "cfg_algo=$(sed -n 's/.*zram_algo=\([A-Za-z0-9_-]*\).*/\1/p' "$MOD/preinit/preinit.conf" 2>/dev/null | head -1)"
	echo "swap_used=$(awk '/zram0/ {print $4}' /proc/swaps 2>/dev/null)"
	echo "swap_total=$(awk '/zram0/ {print $3}' /proc/swaps 2>/dev/null)"
	echo "enabled=$(getstat enabled)"
	echo "aliases=$(getstat aliases)"
	echo "deltas=$(getstat deltas)"
	echo "saved=$(getstat saved_bytes)"
	echo "saved_total=$(getstat saved_bytes_total)"
	echo "decode_fail=$(getstat decode_failures)"
	echo "conv_fail=$(getstat conversion_failures)"
	echo "codec=$(cat "$P/selftest_codec" 2>/dev/null)"
	echo "io=$(cat "$P/selftest_io" 2>/dev/null)"
	;;
apply)
	MB=$2
	ALGO=$3
	HOT=$4
	case "$MB" in
	"" | *[!0-9]*)
		echo "容量必须是数字"
		exit 1
		;;
	esac
	if [ "$MB" -lt 512 ] || [ "$MB" -gt 65536 ]; then
		echo "容量范围 512-65536 MiB"
		exit 1
	fi
	case "$ALGO" in
	lz4kds|lz4kd|lz4|zstd|lzo|lzo-rle|lz4hc|842|lz4k|zstdn|zstdn_o) : ;;
	*)
		echo "不支持的算法: $ALGO"
		exit 1
		;;
	esac
	if [ "$HOT" = "1" ]; then
		sh "$MOD/zram.sh" "$MB" "$ALGO" --quiet
	else
		sh "$MOD/zram.sh" "$MB" "$ALGO" --reboot --quiet
	fi
	;;
*)
	echo "用法: webui.sh status | apply <MiB> <algo> <0|1>"
	exit 1
	;;
esac
