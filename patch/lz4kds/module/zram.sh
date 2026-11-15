#!/system/bin/sh
# zram 容量 + 压缩算法配置
# 改完立即尝试热切换；内存不足或设备已满时自动退化为“重启生效”
#
# 用法：
#   sh zram.sh 8192              改容量并尝试立即生效（内存不足时等重启）
#   sh zram.sh 8G                同上，单位 GB
#   sh zram.sh 8192 lz4kds       容量 + 算法
#   sh zram.sh algo zstd         只改算法，容量不变
#   sh zram.sh show              查看配置与运行状态
#   sh zram.sh off               恢复厂商默认（不干预容量和算法）
#   sh zram.sh 8192 --reboot     只写配置，不做热切换
#   sh zram.sh stock             下次开机不写 comp_algorithm
#   sh zram.sh ours              下次开机照 driver.conf 的 algo 写
#   sh zram.sh mode algo|replace 下次开机用哪种接管方式
#
# 可选算法：lz4kds lz4kd lz4 zstd lzo lzo-rle lz4hc 842 lz4k zstdn zstdn_o

MOD=${MODPATH:-/data/adb/modules/lz4kds}
CONF=$MOD/payload/driver.conf
FLAG=$MOD/stock_driver
DEV=/dev/block/zram0
PRIO=32758
MEMINFO=/proc/meminfo
ALGO_SYS=/sys/block/zram0/comp_algorithm

# 读配置里的一个 key。driver.conf 同时有 algo= 与 insmod 行，
# 前者是接管算法，后者是 replace 模式的 insmod 参数，两者互不干扰。
conf_get() {
	awk -v k="$1" '
		{
			sub(/#.*/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			if ($0 ~ "^" k "=") {
				sub("^" k "=", "")
				gsub(/^[ \t]+|[ \t]+$/, "")
				print
				exit
			}
		}
	' "$CONF" 2>/dev/null | head -1
}

# insmod 行里的 zram_size_mb / zram_algo，只给 replace 模式用
SIZE=$(sed -n 's/.*zram_size_mb=\([0-9][0-9]*\).*/\1/p' "$CONF" 2>/dev/null | head -1)
ALGO=$(conf_get algo)
MODE=$(conf_get mode | tr '[:upper:]' '[:lower:]')
[ -n "$SIZE" ] || SIZE=0
[ -n "$ALGO" ] || ALGO=lz4kd
[ -n "$MODE" ] || MODE=algo

show() {
	echo "== 配置"
	cat "$CONF" 2>/dev/null

	echo "== 驱动"
	if [ -f "$FLAG" ]; then
		echo "下次开机 : 不动 zram（$FLAG 存在）"
	elif [ "$MODE" = "replace" ]; then
		echo "下次开机 : 换成模块自带的驱动"
	else
		echo "下次开机 : 厂商驱动 + $ALGO"
	fi
	if [ -e /sys/module/oplus_bsp_hybridswap_zram/parameters/selftest_codec ]; then
		echo "当前     : 模块自带的驱动"
	else
		echo "当前     : 厂商驱动"
	fi

	DS=$(cat /sys/block/zram0/disksize 2>/dev/null)
	echo "== 运行状态"
	if [ -n "$DS" ]; then
		# mksh 的 $(( )) 是 32 位，容量字节数会溢出，必须用 awk
		DS_MB=$(awk -v d="$DS" 'BEGIN{printf "%d", d/1048576}')
		echo "disksize : $DS ($DS_MB MiB)"
	fi
	echo "comp     : $(cat "$ALGO_SYS" 2>/dev/null)"
	echo "swap     : $(grep zram0 /proc/swaps 2>/dev/null | awk '{print $4" kB used / "$3" kB total"}')"
	echo "自检     : codec=$(cat /sys/module/oplus_bsp_hybridswap_zram/parameters/selftest_codec 2>/dev/null) io=$(cat /sys/module/oplus_bsp_hybridswap_zram/parameters/selftest_io 2>/dev/null)"

	# 容量只在 replace 模式下由本模块决定；algo 模式下容量是厂商脚本设的
	if [ "$MODE" = "replace" ] && [ -n "$DS_MB" ] && [ "$SIZE" != 0 ] &&
		[ "$DS_MB" != "$SIZE" ]; then
		echo "!! 运行容量 $DS_MB MiB 与配置 $SIZE MiB 不一致：需重启"
	fi
	if [ -n "$DS" ] && [ "$ALGO" != off ] && [ ! -f "$FLAG" ]; then
		case "$(cat "$ALGO_SYS" 2>/dev/null)" in
		*"[$ALGO]"*) : ;;
		*) echo "!! 运行算法与配置 $ALGO 不一致：需重启" ;;
		esac
	fi
}

# 名字要在驱动报出来的列表里。该列表由驱动按 crypto 实际注册的算法生成，
# 读不到时才只看静态名单。
valid_algo() {
	case "$1" in
	lz4kds|lz4kd|lz4|zstd|lzo|lzo-rle|lz4hc|842|lz4k|zstdn|zstdn_o) : ;;
	*) return 1 ;;
	esac
	AVAIL=$(cat "$ALGO_SYS" 2>/dev/null | tr -d "[]\n")
	[ -n "$AVAIL" ] || return 0
	case " $AVAIL " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

save() {
	TMP=$CONF.tmp
	{
		if [ "$MODE" = "replace" ]; then
			echo "# 由 zram.sh 写入"
			echo "algo=$ALGO"
			echo "mode=replace"
			if [ "$SIZE" = 0 ]; then
				echo "insmod oplus_bsp_hybridswap_zram.ko zram_algo=$ALGO"
			else
				echo "insmod oplus_bsp_hybridswap_zram.ko zram_size_mb=$SIZE zram_algo=$ALGO"
			fi
		else
			echo "# 由 zram.sh 写入"
			echo "algo=$ALGO"
			echo "mode=algo"
			# insmod 行只在 replace 模式生效，留着是为了切过去时容量还在
			if [ "$SIZE" != 0 ]; then
				echo "insmod oplus_bsp_hybridswap_zram.ko zram_size_mb=$SIZE zram_algo=$ALGO"
			fi
		fi
	} >"$TMP"
	if ! mv "$TMP" "$CONF" 2>/dev/null; then
		rm -f "$TMP" 2>/dev/null
		echo "!! 写不进 $CONF，配置未保存"
		return 1
	fi
	chmod 644 "$CONF" 2>/dev/null
	if [ "$QUIET" = "1" ]; then
		echo "配置已写入"
	else
		echo "已保存（重启后生效）："
		cat "$CONF"
	fi
	return 0
}

REBOOT_ONLY=0
QUIET=0
for a in "$@"; do
	case "$a" in
	--reboot) REBOOT_ONLY=1 ;;
	--quiet) QUIET=1 ;;
	esac
done

KEEP_SIZE=0
TGT_MB=

case "$1" in
"" | show)
	show
	exit 0
	;;
stock)
	: >"$FLAG"
	echo "下次开机不动 zram（标志文件 $FLAG）"
	exit 0
	;;
ours)
	rm -f "$FLAG"
	echo "下次开机照 driver.conf 写 comp_algorithm"
	exit 0
	;;
mode)
	case "$2" in
	algo | replace)
		MODE=$2
		save || exit 1
		exit 0
		;;
	*)
		echo "用法: sh zram.sh mode algo|replace"
		exit 1
		;;
	esac
	;;
off)
	SIZE=0
	ALGO=off
	save || exit 1
	exit 0
	;;
algo)
	[ -n "$2" ] || { echo "用法: sh zram.sh algo <算法名>"; exit 1; }
	valid_algo "$2" || { echo "不支持的算法: $2"; exit 1; }
	ALGO=$2
	# 只换算法：热切换沿用当前运行容量，持久配置里的容量保持不变。
	# conf 里没有容量（跑过 off）时按厂商默认处理，别把 0 写回去。
	KEEP_SIZE=1
	CUR_BYTES=$(cat /sys/block/zram0/disksize 2>/dev/null)
	case "$CUR_BYTES" in
	'' | *[!0-9]*) : ;;
	*) TGT_MB=$(awk -v d="$CUR_BYTES" 'BEGIN{printf "%d", d/1048576}') ;;
	esac
	;;
esac

# 第一个参数是容量（algo 子命令只换算法，跳过容量解析）
if [ "$KEEP_SIZE" != "1" ]; then
case "$1" in
*[Gg])
	N=${1%[Gg]}
	case "$N" in *[!0-9]*|"") echo "容量格式错误，例如 8192 或 8G"; exit 1 ;; esac
	# mksh 的 $(( )) 是 32 位，4194305G 会溢出成 1024 并通过范围校验
	SIZE=$(awk -v n="$N" 'BEGIN{printf "%.0f", n * 1024}')
	;;
*)
	case "$1" in *[!0-9]*) echo "容量格式错误，例如 8192 或 8G"; exit 1 ;; esac
	SIZE=$1
	;;
esac
# 比较也走 awk：mksh 的 test 是 32 位，4294968320 会被截成 1024 放行
if ! command -v awk >/dev/null 2>&1; then
	echo "!! 缺少 awk，无法校验容量"
	exit 1
fi
IN_RANGE=$(awk -v s="$SIZE" 'BEGIN{print (s >= 512 && s <= 65536) ? 1 : 0}')
[ "$IN_RANGE" = "1" ] || { echo "容量范围 512-65536 MB"; exit 1; }

# --reboot / --quiet 这类开关不是算法名
if [ -n "$2" ] && [ "${2#--}" = "$2" ]; then
	valid_algo "$2" || { echo "不支持的算法: $2"; exit 1; }
	ALGO=$2
fi

# 超过 2×物理内存的值在驱动里会被钳制，这里先调整并写回，避免配置与运行不一致
# meminfo 读不到时不做钳制，免得把空值写进配置
MAX_MB=$(awk '/MemTotal/ {printf "%d", $2 * 2 / 1024}' "$MEMINFO" 2>/dev/null)
case "$MAX_MB" in
'' | *[!0-9]*) MAX_MB=0 ;;
esac
if [ "$MAX_MB" -gt 0 ] && [ "$SIZE" -gt "$MAX_MB" ]; then
	echo "!! 容量 ${SIZE} MiB 超过 2×物理内存上限，已调整为 ${MAX_MB} MiB"
	SIZE=$MAX_MB
fi
TGT_MB=$SIZE
fi

# 配置写不进盘时不要继续热切换：本次会话改了、重启又回退，比不改更糟
if ! save; then
	exit 1
fi

if [ -z "$TGT_MB" ] || [ "$TGT_MB" -eq 0 ]; then
	echo "配置已保存；zram0 未初始化或容量为厂商默认，重启后生效。"
	exit 0
fi

if [ "$REBOOT_ONLY" = "1" ]; then
	echo "配置已保存，重启后生效。"
	exit 0
fi

TGT_BYTES=$(awk -v m="$TGT_MB" 'BEGIN{printf "%.0f", m*1048576}')
CUR=$(cat /sys/block/zram0/disksize 2>/dev/null)

# 热切换前提：可用内存要装得下当前 swap 已用量，否则 swapoff 会失败
SWAP_USED=$(grep zram0 /proc/swaps 2>/dev/null | awk '{print $4}')
MEM_AVAIL=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
if [ -n "$SWAP_USED" ] && [ "$SWAP_USED" != "0" ]; then
	CAN=$(awk -v u="$SWAP_USED" -v a="$MEM_AVAIL" \
		'BEGIN{print (a > u + 262144) ? 1 : 0}')
	if [ "$CAN" != "1" ]; then
		echo "!! swap 已用 $((SWAP_USED / 1024)) MiB，可用内存 $((MEM_AVAIL / 1024)) MiB"
		echo "!! 内存不足，跳过热切换；配置已保存，重启后生效"
		exit 0
	fi
fi

case "$CUR" in
'' | *[!0-9]*) CUR_MB=0 ;;
*) CUR_MB=$(awk -v c="$CUR" 'BEGIN{printf "%d", c/1048576}') ;;
esac
PRE_ALGO=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null)
echo "正在切换：$CUR_MB MiB -> $TGT_MB MiB，算法 $ALGO"
# zram_size_mb 只在模块自带的驱动里有。它会让 disksize_store 忽略写入值、
# 改用参数值，所以热切换前要先同步，swapoff 失败再改回去。
PARAM=/sys/module/oplus_bsp_hybridswap_zram/parameters/zram_size_mb
OLD_PARAM=
if [ -e "$PARAM" ]; then
	OLD_PARAM=$(cat "$PARAM" 2>/dev/null)
	echo "$TGT_MB" >"$PARAM" 2>/dev/null
fi
if ! swapoff $DEV; then
	[ -n "$OLD_PARAM" ] && echo "$OLD_PARAM" >"$PARAM" 2>/dev/null
	echo "!! swapoff 失败；配置已保存，重启后生效"
	exit 0
fi

echo 1 >/sys/block/zram0/reset
if ! echo "$ALGO" >"$ALGO_SYS" 2>/dev/null; then
	echo "算法 $ALGO 写不进去，保留 $(cat "$ALGO_SYS" 2>/dev/null)"
fi
if ! echo "$TGT_BYTES" >/sys/block/zram0/disksize 2>/dev/null; then
	echo "!! 写 disksize 失败，回滚原容量"
	echo 1 >/sys/block/zram0/reset
	[ -n "$PRE_ALGO" ] && echo "$PRE_ALGO" >"$ALGO_SYS"
	[ -n "$CUR" ] && echo "$CUR" >/sys/block/zram0/disksize
	mkswap $DEV >/dev/null 2>&1
	swapon -p $PRIO $DEV
	echo "已回滚：disksize=$(cat /sys/block/zram0/disksize)"
	exit 1
fi
mkswap $DEV >/dev/null 2>&1
if swapon -p $PRIO $DEV 2>/dev/null; then
	NOW_ALGO=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null)
	echo "已生效：容量 $(awk -v d="$(cat /sys/block/zram0/disksize)" 'BEGIN{printf "%d", d/1048576}') MiB，算法 $NOW_ALGO"
else
	echo "swapon 失败，回滚原容量"
	# 设备此时已 init，直接写 comp_algorithm / disksize 会 EBUSY，必须先 reset
	echo 1 >/sys/block/zram0/reset
	if [ -n "$PRE_ALGO" ]; then
		echo "$PRE_ALGO" >"$ALGO_SYS"
	fi
	if [ -n "$CUR" ]; then
		echo "$CUR" >/sys/block/zram0/disksize
	fi
	mkswap $DEV >/dev/null 2>&1
	swapon -p $PRIO $DEV
	echo "已回滚：disksize=$(cat /sys/block/zram0/disksize)"
fi
