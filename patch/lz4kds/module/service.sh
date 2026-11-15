#!/system/bin/sh
# boot 完成后核对算法是否真的生效；没生效就按 zram.sh 的顺序改回来。
MOD=${MODPATH:-/data/adb/modules/lz4kds}
LOG=$MOD/selftest.log
# 打不开就退到 /dev/null：块重定向失败会让整块一条命令都不执行。
if ! ( : >>"$LOG" ) 2>/dev/null; then
	LOG=/dev/null
fi
P=/sys/module/oplus_bsp_hybridswap_zram/parameters
ALGO_SYS=/sys/block/zram0/comp_algorithm
SWAPS=/proc/swaps
DISKSIZE=/sys/block/zram0/disksize
RESET=/sys/block/zram0/reset
ZRAM=/dev/block/zram0

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
	if step swapon -p "$PRIO" "$ZRAM"; then
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
	if ! step swapon -p "$PRIO" "$ZRAM"; then
		log "=== swapon 失败，回滚"
		reset_swap "$NOW_ALGO" "$NOW_MB"
		return 1
	fi
	log "=== 改完是 $(cur_algo)，disksize=$(cat "$DISKSIZE" 2>/dev/null)，优先级 $PRIO"
	return 0
}

# 等 sys.boot_completed
i=0
while [ $i -lt 60 ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 2
	i=$((i + 1))
done

MODE=$(conf_get mode)
ALGO=$(conf_get algo)
[ -n "$MODE" ] || MODE=algo
[ -n "$ALGO" ] || ALGO=lz4kd

# 厂商的 init 脚本在 22 秒设容量并 swapon，另有脚本在 33 秒前后 reset 一次。
# 等到开机 36 秒，reset 刚过去、swap 里还没多少页，这时改的代价最小。
i=0
while [ $i -lt 30 ]; do
	UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	case "$UP" in
	"" | *[!0-9]*) UP=0 ;;
	esac
	[ "$UP" -ge 36 ] && break
	sleep 1
	i=$((i + 1))
done

NOW_ALGO=$(cur_algo)
NOW_MB=$(cur_mb)

{
	echo "=== uptime=$(cut -d' ' -f1 /proc/uptime) build=$(getprop ro.build.version.incremental)"
	echo "配置: mode=$MODE algo=$ALGO"
	echo "运行: disksize=$(cat "$DISKSIZE" 2>/dev/null) comp=$NOW_ALGO"
	echo "swap: $(grep zram0 "$SWAPS" 2>/dev/null)"
	if [ -e "$P/selftest_codec" ]; then
		echo "selftest: codec=$(cat "$P/selftest_codec" 2>/dev/null) io=$(cat "$P/selftest_io" 2>/dev/null)"
		grep -E "^(enabled|aliases|deltas|saved_bytes|decode_failures|conversion_failures):" \
			/sys/block/zram0/sddc_stat 2>/dev/null
	fi
} >>"$LOG" 2>/dev/null

# swap 已用量超过 64 MiB 时不动手：swapoff 要把那些页全读回内存，有 OOM 风险。
SWAP_USED=$(awk '/zram0/ {print $4}' "$SWAPS" 2>/dev/null | head -1)
case "$SWAP_USED" in
"" | *[!0-9]*) SWAP_USED=0 ;;
esac

if [ "$MODE" != "algo" ] || [ -f "$MOD/stock_driver" ] || [ "$ALGO" = "off" ] ||
	[ "$NOW_ALGO" = "$ALGO" ]; then
	exit 0
fi

if [ "$NOW_MB" -le 0 ]; then
	log "=== 算法是 $NOW_ALGO，zram0 还没设容量，重启后由 post-fs-data 处理"
	exit 0
fi

if [ "$SWAP_USED" -gt 65536 ]; then
	log "=== 算法是 $NOW_ALGO，swap 已用 $SWAP_USED kB，不做重设"
	exit 0
fi

log "=== 算法是 $NOW_ALGO，改回 $ALGO（容量 $NOW_MB MiB）"
BYTES=$(awk -v m="$NOW_MB" 'BEGIN{printf "%.0f", m * 1048576}')
# 沿用当前的 swap 优先级，别把 zram0 的优先级改掉
PRIO=$(awk '/zram0/ {print $5}' "$SWAPS" 2>/dev/null | head -1)
case "$PRIO" in
"" | *[!0-9-]*) PRIO=-2 ;;
esac

apply_algo

# 日志只保留最近 200 行
tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exit 0
