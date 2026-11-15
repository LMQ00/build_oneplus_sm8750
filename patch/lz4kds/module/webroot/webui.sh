#!/system/bin/sh
# LZ4KDS WebUI 后端：供 webroot/index.html 调用
MOD=${MODPATH:-/data/adb/modules/lz4kds}
STAGE=/metadata/watchdog/ksu/lz4kds
PARAMS=$STAGE/ko_params

param_get() {
	awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$PARAMS" 2>/dev/null
}

# 自带驱动才有 zram_algo 这个参数，厂商那版没有。
driver_name() {
	if [ -e /sys/module/oplus_bsp_hybridswap_zram/parameters/zram_algo ]; then
		echo "LZ4KDS + SDDC"
	elif [ -e /sys/module/oplus_bsp_hybridswap_zram ]; then
		echo "厂商"
	fi
}

case "$1" in
status)
	echo "disksize=$(cat /sys/block/zram0/disksize 2>/dev/null)"
	echo "comp=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null)"
	echo "cfg_algo=$(param_get ALGO)"
	echo "cfg_size=$(param_get SIZE_MB)"
	echo "avail=lz4kds lz4kd off"
	echo "swap_used=$(awk '/zram0/ {print $4}' /proc/swaps 2>/dev/null)"
	echo "swap_total=$(awk '/zram0/ {print $3}' /proc/swaps 2>/dev/null)"
	echo "stock=$([ -f "$MOD/stock_driver" ] && echo 1 || echo 0)"
	echo "driver=$(driver_name)"
	;;
apply)
	MB=$2
	ALGO=$3
	case "$MB" in
	"" | *[!0-9]*)
		echo "容量必须是数字"
		exit 1
		;;
	esac
	if ! awk -v s="$MB" 'BEGIN{exit !(s >= 512 && s <= 65536)}'; then
		echo "容量范围 512-65536 MiB"
		exit 1
	fi
	case "$ALGO" in
	lz4kds | lz4kd | off) : ;;
	*)
		echo "不支持的算法: $ALGO"
		exit 1
		;;
	esac
	sh "$MOD/zram.sh" algo "$ALGO" || exit 1
	sh "$MOD/zram.sh" size "$MB" || exit 1
	echo "已保存，重启后生效"
	;;
*)
	echo "用法: webui.sh status | apply <MiB> <algo>"
	exit 1
	;;
esac
