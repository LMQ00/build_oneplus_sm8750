#!/system/bin/sh
# LZ4KDS WebUI 后端：供 webroot/index.html 调用
MOD=${MODPATH:-/data/adb/modules/lz4kds}

# driver.conf 里 key=value 的值，取第一个匹配
conf_get() {
	awk -v k="$1" '
		{
			sub(/#.*/, "")
			sub(/\r$/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			if ($0 ~ "^" k "[ \t]*=") {
				sub("^" k "[ \t]*=", "")
				gsub(/^[ \t]+|[ \t]+$/, "")
				print
				exit
			}
		}
	' "$MOD/payload/driver.conf" 2>/dev/null | head -1
}

case "$1" in
status)
	echo "disksize=$(cat /sys/block/zram0/disksize 2>/dev/null)"
	echo "comp=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null)"
	echo "cfg_algo=$(conf_get algo)"
	echo "avail=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '[]\n')"
	echo "swap_used=$(awk '/zram0/ {print $4}' /proc/swaps 2>/dev/null)"
	echo "swap_total=$(awk '/zram0/ {print $3}' /proc/swaps 2>/dev/null)"
	echo "stock=$([ -f "$MOD/stock_driver" ] && echo 1 || echo 0)"
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
	# mksh 的 test 是 32 位，大数会被截断后放行；用 awk 比
	if ! awk -v s="$MB" 'BEGIN{exit !(s >= 512 && s <= 65536)}'; then
		echo "容量范围 512-65536 MiB"
		exit 1
	fi
	case "$ALGO" in
	lz4kd|lz4k|lz4|zstd|lzo|lzo-rle|zstdn|zstdn_o) : ;;
	*)
		echo "不支持的算法: $ALGO"
		exit 1
		;;
	esac
	case "$HOT" in
	0 | 1) : ;;
	*)
		echo "HOT 必须是 0 或 1"
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
