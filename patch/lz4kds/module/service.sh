#!/system/bin/sh
# 开机核对 zram0 的算法与容量；与 driver.conf 不一致就换过来。
#
# 正常路径是 post-fs-data.sh 改掉 /odm/etc/oplus_mm_config.xml，厂商脚本在
# boot_completed 阶段读它，自己把算法和容量写进 zram0。这里核对一下。
#
# 厂商脚本读到的还是原文件时（挂载失败、换过 OTA 等），算法会是 lz4，
# 容量是厂商默认，这里做一次热切换：
#   swapoff -> reset -> 写算法 -> 写 disksize -> mkswap -> swapon

MOD=${MODPATH:-/data/adb/modules/lz4kds}
LOG=$MOD/selftest.log
# 打不开就退到 /dev/null：块重定向失败会让整块一条命令都不执行。
if ! ( : >>"$LOG" ) 2>/dev/null; then
	LOG=/dev/null
fi
ALGO_SYS=/sys/block/zram0/comp_algorithm
SWAPS=/proc/swaps
DISKSIZE=/sys/block/zram0/disksize
RESET=/sys/block/zram0/reset
ZRAM=/dev/block/zram0
LOCK=$MOD/.service.lock

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

log() {
	echo "$*" >>"$LOG" 2>/dev/null
}

# 跑一条命令，输出写进日志，返回码留在 STEP_RC
step() {
	_step_out=$("$@" 2>&1)
	STEP_RC=$?
	[ -n "$_step_out" ] && log "  $_step_out"
	return $STEP_RC
}

# 同上，但这条命令是把值写进某个文件
step_write() {
	_step_out=$({ echo "$2" >"$1"; } 2>&1)
	STEP_RC=$?
	[ -n "$_step_out" ] && log "  $_step_out"
	return $STEP_RC
}

# comp_algorithm 里带方括号的那个
cur_algo() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null | head -1
}

# 当前容量，单位 MiB
cur_mb() {
	awk -v d="$(cat "$DISKSIZE" 2>/dev/null)" \
		'BEGIN{print (d > 0) ? int(d / 1048576) : 0}'
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
		"$SWAPON" -p "$PRIO" "$ZRAM"
		return $?
	fi
	# 找不到带 -p 的那个时先试 -p，壳里的 swapon 不认就去掉 -p 再挂一次
	swapon -p "$PRIO" "$ZRAM" 2>/dev/null && return 0
	swapon "$ZRAM"
}

# 回滚：把 zram0 放回给定算法与容量，再挂上 swap。挂不上就归零，
# 不能让它占着内存却没有 swap。
reset_swap() {
	_r_algo=$1
	_r_mb=$2

	step_write "$RESET" 1
	if [ -n "$_r_algo" ]; then
		step_write "$ALGO_SYS" "$_r_algo"
	fi
	if [ -n "$_r_mb" ]; then
		step_write "$DISKSIZE" "$(awk -v m="$_r_mb" 'BEGIN{printf "%.0f", m * 1048576}')"
	fi
	step mkswap "$ZRAM"
	if step do_swapon; then
		log "=== 已回到 $(cur_algo)，容量 $(cur_mb) MiB"
		return 0
	fi
	step_write "$RESET" 1
	log "=== 回滚也失败，zram0 已重置为 0，重启后恢复"
	return 1
}

# reset -> 写算法 -> 写 disksize -> mkswap -> swapon，任何一步失败都落日志
apply_algo() {
	step swapoff "$ZRAM" || {
		log "=== swapoff 失败，放弃重设"
		return 1
	}
	step_write "$RESET" 1 || {
		log "=== reset 失败，放弃重设"
		return 1
	}
	step_write "$ALGO_SYS" "$ALGO" || {
		log "=== 写算法失败，放弃重设"
		return 1
	}
	if ! step_write "$DISKSIZE" "$BYTES"; then
		log "=== 写 disksize 失败，回滚"
		reset_swap "$NOW_ALGO" "$NOW_MB"
		return 1
	fi
	if ! step mkswap "$ZRAM"; then
		log "=== mkswap 失败，回滚"
		reset_swap "$NOW_ALGO" "$NOW_MB"
		return 1
	fi
	if ! step do_swapon; then
		log "=== swapon 失败，回滚"
		reset_swap "$NOW_ALGO" "$NOW_MB"
		return 1
	fi
	log "=== 改完是 $(cur_algo)，disksize=$(cat "$DISKSIZE" 2>/dev/null)，优先级 $PRIO"
	return 0
}

# 两个实例各 reset 一次会互相踩掉对方的 disksize，写算法就会撞上 EBUSY。
# 用目录做锁，mkdir 是原子的。锁里记下本次开机的 boot_id：上一次开机留下的锁
# 在下次开机时不算数，否则一次中断就会让后面每次开机都跳过核对。
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
if ! mkdir "$LOCK" 2>/dev/null; then
	if [ -n "$BOOT_ID" ] && [ "$(cat "$LOCK/boot_id" 2>/dev/null)" = "$BOOT_ID" ]; then
		log "=== 已有一个实例在跑，本次退出"
		exit 0
	fi
	rm -rf "$LOCK" 2>/dev/null
	if ! mkdir "$LOCK" 2>/dev/null; then
		log "=== 拿不到锁，本次退出"
		exit 0
	fi
fi
echo "$BOOT_ID" >"$LOCK/boot_id" 2>/dev/null
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

# 等 sys.boot_completed
i=0
while [ $i -lt 60 ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 2
	i=$((i + 1))
done

ALGO=$(conf_get algo)
[ -n "$ALGO" ] || ALGO=lz4kd
WANT_MB=$(conf_get size)
case "$WANT_MB" in
	'' | *[!0-9]*) WANT_MB="" ;;
esac

# 厂商脚本在开机 22 秒设容量并 swapon，等它做完再动手。
i=0
while [ $i -lt 40 ]; do
	UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	case "$UP" in
	"" | *[!0-9]*) UP=0 ;;
	esac
	[ "$UP" -ge 30 ] && break
	sleep 1
	i=$((i + 1))
done

SWAPON=$(pick_swapon)

NOW_ALGO=$(cur_algo)
NOW_MB=$(cur_mb)

{
	echo "=== uptime=$(cut -d' ' -f1 /proc/uptime) build=$(getprop ro.build.version.incremental)"
	echo "配置: algo=$ALGO size=${WANT_MB:--}"
	echo "运行: disksize=$(cat "$DISKSIZE" 2>/dev/null) comp=$NOW_ALGO"
	echo "swap: $(grep zram0 "$SWAPS" 2>/dev/null)"
	echo "swapon: ${SWAPON:-系统默认}"
} >>"$LOG" 2>/dev/null

if [ -f "$MOD/stock_driver" ] || [ "$ALGO" = "off" ]; then
	exit 0
fi

if [ "$NOW_MB" -le 0 ]; then
	log "=== zram0 还没设容量，等下次开机再看"
	exit 0
fi

NEED=0
[ "$NOW_ALGO" = "$ALGO" ] || NEED=1
if [ -n "$WANT_MB" ] && [ "$WANT_MB" != "$NOW_MB" ]; then
	NEED=1
fi
[ "$NEED" = "1" ] || exit 0

# swap 已用量超过 64 MiB 时不动手：swapoff 要把那些页全读回内存，有 OOM 风险。
SWAP_USED=$(awk '/zram0/ {print $4}' "$SWAPS" 2>/dev/null | head -1)
case "$SWAP_USED" in
"" | *[!0-9]*) SWAP_USED=0 ;;
esac
if [ "$SWAP_USED" -gt 65536 ]; then
	log "=== 现在是 $NOW_ALGO / $NOW_MB MiB，swap 已用 $SWAP_USED kB，不做重设"
	exit 0
fi

TGT_MB=${WANT_MB:-$NOW_MB}
log "=== 现在是 $NOW_ALGO / $NOW_MB MiB，改成 $ALGO / $TGT_MB MiB"
BYTES=$(awk -v m="$TGT_MB" 'BEGIN{printf "%.0f", m * 1048576}')
# 沿用当前的 swap 优先级，别把 zram0 的优先级改掉
PRIO=$(awk '/zram0/ {print $5}' "$SWAPS" 2>/dev/null | head -1)
case "$PRIO" in
"" | *[!0-9-]*) PRIO=-2 ;;
esac

apply_algo

# 日志只保留最近 200 行
tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exit 0
