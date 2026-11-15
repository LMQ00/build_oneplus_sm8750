#!/system/bin/sh
# zram 运行状态与 early-init 接管结果。
#
# 用法：
#   sh zram.sh            看状态
#   sh zram.sh log        看 early-init 日志
#   sh zram.sh algo <名>  改下次开机用的算法（写 ko_params）
#   sh zram.sh size <MiB> 改下次开机用的容量（写 ko_params）
#   sh zram.sh stock      下次开机不接管，走厂商驱动
#   sh zram.sh ours       下次开机接管
#
# 算法可选：lz4kds（带 SDDC）lz4kd（不带 SDDC）off（厂商默认）

MOD=${MODPATH:-/data/adb/modules/lz4kds}
STAGE=/metadata/watchdog/ksu/lz4kds
PARAMS=$STAGE/ko_params
FLAG=$MOD/stock_driver
MODULE=/sys/module/oplus_bsp_hybridswap_zram
ALGO_SYS=/sys/block/zram0/comp_algorithm
SWAPS=/proc/swaps
DISKSIZE=/sys/block/zram0/disksize

cur_algo() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null | head -1
}

cur_mb() {
	awk -v d="$(cat "$DISKSIZE" 2>/dev/null)" \
		'BEGIN{print (d > 0) ? int(d / 1048576) : 0}'
}

param_get() {
	awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$PARAMS" 2>/dev/null
}

# 自带驱动才有 zram_algo 这个参数，厂商那版没有。
driver_name() {
	if [ -e "$MODULE/parameters/zram_algo" ]; then
		echo "LZ4KDS + SDDC"
	elif [ -e "$MODULE" ]; then
		echo "厂商"
	else
		echo "未加载"
	fi
}

show() {
	echo "== 驱动"
	echo "当前 : $(driver_name)"
	if [ -f "$FLAG" ]; then
		echo "下次开机 : 不接管（$FLAG 存在）"
	else
		echo "下次开机 : 接管，算法 $(param_get ALGO)，容量 $(param_get SIZE_MB) MiB"
	fi

	echo "== 运行状态"
	echo "容量 : $(cur_mb) MiB"
	echo "算法 : $(cur_algo)"
	echo "swap : $(grep zram0 "$SWAPS" 2>/dev/null | awk '{print $4" kB used / "$3" kB total"}')"
	for p in selftest_codec selftest_io; do
		v=$(cat "$MODULE/parameters/$p" 2>/dev/null)
		[ -n "$v" ] && echo "$p : $v"
	done
	if [ -f /sys/block/zram0/sddc_stat ]; then
		echo "== SDDC"
		head -12 /sys/block/zram0/sddc_stat 2>/dev/null
	fi
}

write_param() {
	_key=$1
	_val=$2
	[ -f "$PARAMS" ] || { echo "!! 没有 $PARAMS"; return 1; }
	awk -v k="$_key" -v v="$_val" '
		$0 ~ "^" k "=" { print k "=" v; done = 1; next }
		{ print }
		END { if (!done) print k "=" v }
	' "$PARAMS" >"$PARAMS.tmp" && mv "$PARAMS.tmp" "$PARAMS" || return 1
	chmod 0600 "$PARAMS" 2>/dev/null
	echo "已写入：$1=$2（下次开机生效）"
}

case "$1" in
'' | show | status)
	show
	;;
log)
	if [ -f "$STAGE/early.log" ]; then
		cat "$STAGE/early.log"
	else
		cat "$MOD/early.log" 2>/dev/null || echo "没有日志"
	fi
	;;
algo)
	[ -n "$2" ] || { echo "用法: sh zram.sh algo <lz4kds|lz4kd|off>"; exit 1; }
	case "$2" in
	lz4kds | lz4kd | off) : ;;
	*) echo "可选：lz4kds lz4kd off"; exit 1 ;;
	esac
	write_param ALGO "$2"
	;;
size)
	[ -n "$2" ] || { echo "用法: sh zram.sh size <MiB>"; exit 1; }
	case "$2" in *[!0-9]*) echo "容量必须是数字"; exit 1 ;; esac
	IN_RANGE=$(awk -v s="$2" 'BEGIN{print (s >= 512 && s <= 65536) ? 1 : 0}')
	[ "$IN_RANGE" = "1" ] || { echo "容量范围 512-65536 MiB"; exit 1; }
	write_param SIZE_MB "$2"
	;;
stock)
	: >"$FLAG"
	echo "下次开机不接管，驱动与参数都走厂商"
	;;
ours)
	rm -f "$FLAG"
	echo "下次开机接管"
	;;
*)
	echo "用法: sh zram.sh [show|log|algo <名>|size <MiB>|stock|ours]"
	exit 1
	;;
esac
