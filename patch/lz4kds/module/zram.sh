#!/system/bin/sh
# zram 容量与压缩算法配置。
#
# 用法：
#   sh zram.sh                  查看配置与运行状态
#   sh zram.sh 8192             把容量改成 8192 MiB，立即生效
#   sh zram.sh 16G              同上，单位 GB
#   sh zram.sh 8192 lz4kd       容量 + 算法一起改
#   sh zram.sh algo zstd        只改算法，容量不动
#   sh zram.sh auto             容量恢复厂商策略
#   sh zram.sh off              不干预 zram（等价于 stock）
#   sh zram.sh stock            下次开机不碰 zram
#   sh zram.sh ours             下次开机照 driver.conf 改
#   sh zram.sh 8192 --reboot    只写配置，不做热切换
#
# 可选算法：lz4kd lz4k lz4 zstd lzo lzo-rle zstdn zstdn_o

MOD=${MODPATH:-/data/adb/modules/lz4kds}
CONF=$MOD/payload/driver.conf
FLAG=$MOD/stock_driver
SRC=/odm/etc/oplus_mm_config.xml
DEV=/dev/block/zram0
ZRAM=/sys/block/zram0
PRIO=32758
MEMINFO=/proc/meminfo
CRYPTO=/proc/crypto
SWAPS=/proc/swaps
ALGO_SYS=$ZRAM/comp_algorithm
DISKSIZE=$ZRAM/disksize
RESET=$ZRAM/reset

QUIET=0
REBOOT_ONLY=0

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
	' "$CONF" 2>/dev/null | head -1
}

cur_algo() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null | head -1
}

cur_mb() {
	awk -v d="$(cat "$DISKSIZE" 2>/dev/null)" \
		'BEGIN{print (d > 0) ? int(d / 1048576) : 0}'
}

say() {
	[ "$QUIET" = "1" ] || echo "$*"
}

# 名字得是内核里真有的算法：/proc/crypto 里有，或者驱动把它列在
# comp_algorithm 里。驱动只列编译期写死的那几个加上当前在用的那个，
# 所以 lz4kd 只能靠 /proc/crypto 认。
valid_algo() {
	case "$1" in
	lz4kd|lz4k|lz4|zstd|lzo|lzo-rle|zstdn|zstdn_o) : ;;
	*) return 1 ;;
	esac
	if awk -v a="$1" '
		$1 == "name" && $3 == a { found = 1; exit }
		END { exit found ? 0 : 1 }
	' "$CRYPTO" 2>/dev/null; then
		return 0
	fi
	AVAIL=$(cat "$ALGO_SYS" 2>/dev/null | tr -d '[]\n')
	[ -n "$AVAIL" ] || return 0
	case " $AVAIL " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

# 写 driver.conf。$1 算法，$2 容量（空表示沿用厂商策略）。
save() {
	_tmp=$CONF.tmp
	{
		echo "# zram0 用哪个压缩算法，以及开机时的容量（MiB）。"
		echo "# algo=auto 或 size=auto 表示那一项沿用厂商策略。"
		echo "algo=$1"
		echo "size=$2"
	} >"$_tmp" 2>/dev/null || {
		say "!! 写不进 $_tmp"
		return 1
	}
	if ! mv "$_tmp" "$CONF" 2>/dev/null; then
		rm -f "$_tmp" 2>/dev/null
		say "!! 写不进 $CONF，配置未保存"
		return 1
	fi
	chmod 644 "$CONF" 2>/dev/null
	say "已保存：algo=$1 size=${2:-auto}"
	return 0
}

# 让 XML 跟上配置。下次开机厂商脚本读到的就是新值。
sync_xml() {
	[ -x "$MOD/post-fs-data.sh" ] || return 0
	sh "$MOD/post-fs-data.sh" >/dev/null 2>&1
}

# 把 /odm 上那份换回原始文件。
drop_xml() {
	if grep -q " $SRC " /proc/self/mountinfo 2>/dev/null; then
		umount "$SRC" 2>/dev/null
	fi
}

show() {
	echo "== 配置"
	cat "$CONF" 2>/dev/null

	echo "== 下次开机"
	if [ -f "$FLAG" ]; then
		echo "不动 zram（$FLAG 存在）"
	else
		echo "算法 $(conf_get algo)，容量 $(conf_get size)"
	fi
	if grep -q " $SRC " /proc/self/mountinfo 2>/dev/null; then
		echo "XML 已接管：$SRC"
	else
		echo "XML 未接管，厂商读的是分区上的原文件"
	fi

	echo "== 运行状态"
	echo "容量 : $(cur_mb) MiB"
	echo "算法 : $(cur_algo)"
	echo "swap : $(grep zram0 "$SWAPS" 2>/dev/null | awk '{print $4" kB used / "$3" kB total"}')"
}

# PATH 里的 swapon 可能是 busybox 的，它不认 -p，用它会把优先级丢掉。
# 挑一个帮助里写了 -p 的，挑不到就退回裸 swapon。
pick_swapon() {
	for _c in /system/bin/swapon /vendor/bin/swapon; do
		[ -x "$_c" ] || continue
		case "$("$_c" --help 2>&1)" in
		*"-p"*)
			echo "$_c"
			return 0
			;;
		esac
	done
	echo ""
}

do_swapon() {
	if [ -n "$SWAPON" ]; then
		"$SWAPON" -p "$PRIO" "$DEV"
		return $?
	fi
	# 找不到带 -p 的那个时先试 -p，壳里的 swapon 不认就去掉 -p 再挂一次
	swapon -p "$PRIO" "$DEV" 2>/dev/null && return 0
	swapon "$DEV"
}

# 热切换：swapoff -> reset -> 写算法 -> 写 disksize -> mkswap -> swapon。
# 失败时把 zram0 放回原来的算法与容量，不能占着内存却没有 swap。
reset_swap() {
	_r_algo=$1
	_r_mb=$2

	echo 1 >"$RESET" 2>/dev/null
	[ -n "$_r_algo" ] && echo "$_r_algo" >"$ALGO_SYS" 2>/dev/null
	if [ -n "$_r_mb" ] && [ "$_r_mb" -gt 0 ]; then
		awk -v m="$_r_mb" 'BEGIN{printf "%.0f", m * 1048576}' >"$DISKSIZE" 2>/dev/null
		mkswap "$DEV" >/dev/null 2>&1
		do_swapon >/dev/null 2>&1
	fi
}

hot_switch() {
	_t_algo=$1
	_t_mb=$2

	PRE_ALGO=$(cur_algo)
	PRE_MB=$(cur_mb)

	# 已经是目标状态时不要白走一遍 swapoff/swapon：那会把 swap 里的页搬回内存。
	if [ "$_t_algo" = "$PRE_ALGO" ] && [ "$_t_mb" = "$PRE_MB" ]; then
		say "已经是 $_t_algo / $_t_mb MiB，不用切换"
		return 0
	fi

	SWAP_USED=$(awk '/zram0/ {print $4}' "$SWAPS" 2>/dev/null | head -1)
	case "$SWAP_USED" in
	"" | *[!0-9]*) SWAP_USED=0 ;;
	esac
	if [ "$SWAP_USED" -gt 0 ]; then
		MEM_AVAIL=$(awk '/MemAvailable/{print $2}' "$MEMINFO" 2>/dev/null)
		case "$MEM_AVAIL" in
		"" | *[!0-9]*) MEM_AVAIL=0 ;;
		esac
		CAN=$(awk -v u="$SWAP_USED" -v a="$MEM_AVAIL" 'BEGIN{print (a > u + 262144) ? 1 : 0}')
		if [ "$CAN" != "1" ]; then
			say "!! swap 已用 $((SWAP_USED / 1024)) MiB，可用内存 $((MEM_AVAIL / 1024)) MiB"
			say "!! 内存不足，跳过热切换；配置已保存，重启后生效"
			return 0
		fi
	fi

	say "正在切换：$PRE_MB MiB / $PRE_ALGO -> $_t_mb MiB / $_t_algo"
	if ! swapoff "$DEV" 2>/dev/null; then
		say "!! swapoff 失败；配置已保存，重启后生效"
		return 0
	fi

	echo 1 >"$RESET" 2>/dev/null
	if ! echo "$_t_algo" >"$ALGO_SYS" 2>/dev/null; then
		say "!! 写算法 $_t_algo 失败，当前 $(cur_algo)"
		reset_swap "$PRE_ALGO" "$PRE_MB"
		return 1
	fi
	if ! awk -v m="$_t_mb" 'BEGIN{printf "%.0f", m * 1048576}' >"$DISKSIZE" 2>/dev/null; then
		say "!! 写容量失败，回滚"
		reset_swap "$PRE_ALGO" "$PRE_MB"
		return 1
	fi
	mkswap "$DEV" >/dev/null 2>&1
	if do_swapon >/dev/null 2>&1; then
		say "已生效：$(cur_mb) MiB / $(cur_algo)"
		return 0
	fi
	say "!! swapon 失败，回滚"
	reset_swap "$PRE_ALGO" "$PRE_MB"
	return 1
}

for a in "$@"; do
	case "$a" in
	--reboot) REBOOT_ONLY=1 ;;
	--quiet) QUIET=1 ;;
	esac
done

SWAPON=$(pick_swapon)

CMD=$1
case "$CMD" in
'' | show | status)
	show
	exit 0
	;;
stock | off)
	: >"$FLAG"
	drop_xml
	say "下次开机不动 zram（$FLAG）"
	exit 0
	;;
ours)
	rm -f "$FLAG"
	sync_xml
	say "下次开机照 $CONF 改 zram"
	exit 0
	;;
esac

OLD_ALGO=$(conf_get algo)
[ -n "$OLD_ALGO" ] || OLD_ALGO=lz4kd
OLD_SIZE=$(conf_get size)
case "$OLD_SIZE" in
	auto | '') OLD_SIZE="" ;;
esac
NEW_ALGO=$OLD_ALGO
NEW_SIZE=$OLD_SIZE

case "$CMD" in
algo)
	[ -n "$2" ] || { echo "用法: sh zram.sh algo <算法名>"; exit 1; }
	valid_algo "$2" || { echo "不支持的算法: $2"; exit 1; }
	NEW_ALGO=$2
	;;
auto)
	NEW_SIZE=""
	;;
*)
	case "$CMD" in
	*[Gg])
		N=${CMD%[Gg]}
		case "$N" in *[!0-9]*|'') echo "容量格式错误，例如 8192 或 16G"; exit 1 ;; esac
		# mksh 的 $(( )) 是 32 位，4194305G 会溢出成 1024 并通过范围校验
		NEW_SIZE=$(awk -v n="$N" 'BEGIN{printf "%.0f", n * 1024}')
		;;
	*)
		case "$CMD" in *[!0-9]*) echo "容量格式错误，例如 8192 或 16G"; exit 1 ;; esac
		NEW_SIZE=$CMD
		;;
	esac
	if ! command -v awk >/dev/null 2>&1; then
		echo "!! 缺少 awk，无法校验容量"
		exit 1
	fi
	IN_RANGE=$(awk -v s="$NEW_SIZE" 'BEGIN{print (s >= 512 && s <= 65536) ? 1 : 0}')
	[ "$IN_RANGE" = "1" ] || { echo "容量范围 512-65536 MiB"; exit 1; }

	# 超过 2×物理内存的值厂商会钳制，这里先调整，避免配置与运行不一致。
	# 比较走 awk：mksh 的 test 是 32 位，大数会被截断后放行。
	MAX_MB=$(awk '/MemTotal/ {printf "%d", $2 * 2 / 1024}' "$MEMINFO" 2>/dev/null)
	case "$MAX_MB" in
	'' | *[!0-9]*) MAX_MB=0 ;;
	esac
	if [ "$MAX_MB" -gt 0 ]; then
		OVER=$(awk -v s="$NEW_SIZE" -v m="$MAX_MB" 'BEGIN{print (s > m) ? 1 : 0}')
		if [ "$OVER" = "1" ]; then
			echo "!! 容量 ${NEW_SIZE} MiB 超过 2×物理内存上限，已调整为 ${MAX_MB} MiB"
			NEW_SIZE=$MAX_MB
		fi
	fi

	# 第二个参数是算法名时一并改
	if [ -n "$2" ] && [ "${2#--}" = "$2" ]; then
		valid_algo "$2" || { echo "不支持的算法: $2"; exit 1; }
		NEW_ALGO=$2
	fi
	;;
esac

if ! save "$NEW_ALGO" "$NEW_SIZE"; then
	exit 1
fi
rm -f "$FLAG" 2>/dev/null
sync_xml

if [ "$REBOOT_ONLY" = "1" ]; then
	say "重启后生效。"
	exit 0
	fi

if [ "$(cur_mb)" -le 0 ]; then
	say "zram0 还没设容量，重启后生效。"
	exit 0
	fi

hot_switch "$NEW_ALGO" "${NEW_SIZE:-$(cur_mb)}"
exit 0