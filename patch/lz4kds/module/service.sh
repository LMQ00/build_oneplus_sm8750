#!/system/bin/sh
# boot 完成后核对算法是否真的生效；没生效就按 zram.sh 的顺序改回来。
MOD=${MODPATH:-/data/adb/modules/lz4kds}
LOG=$MOD/selftest.log
P=/sys/module/oplus_bsp_hybridswap_zram/parameters
ALGO_SYS=/sys/block/zram0/comp_algorithm
SWAPS=/proc/swaps

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
	' "$MOD/payload/driver.conf" 2>/dev/null | head -1
}

# comp_algorithm 里带方括号的那个
cur_algo() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null | head -1
}

# 当前容量，单位 MiB
cur_mb() {
	awk -v d="$(cat /sys/block/zram0/disksize 2>/dev/null)" \
		'BEGIN{print (d > 0) ? int(d / 1048576) : 0}'
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
	echo "运行: disksize=$(cat /sys/block/zram0/disksize 2>/dev/null) comp=$NOW_ALGO"
	echo "swap: $(grep zram0 /proc/swaps 2>/dev/null)"
	if [ -e "$P/selftest_codec" ]; then
		echo "selftest: codec=$(cat "$P/selftest_codec" 2>/dev/null) io=$(cat "$P/selftest_io" 2>/dev/null)"
		grep -E "^(enabled|aliases|deltas|saved_bytes|decode_failures|conversion_failures):" \
			/sys/block/zram0/sddc_stat 2>/dev/null
	fi
} >>"$LOG" 2>/dev/null

# swap 已用量超过 64 MiB 时不做重设：swapoff 要把这些页全读回内存，有 OOM 风险。
SWAP_USED=$(awk '/zram0/ {print $4}' "$SWAPS" 2>/dev/null | head -1)
case "$SWAP_USED" in
"" | *[!0-9]*) SWAP_USED=0 ;;
esac

# 只在 algo 模式、没开 stock 标志、算法确实不一致时动手。
# 按 reset -> 写算法 -> 写 disksize -> mkswap -> swapon 的顺序，容量沿用当前值，
# 不改 driver.conf。
if [ "$MODE" = "algo" ] && [ ! -f "$MOD/stock_driver" ] &&
	[ "$ALGO" != "off" ] && [ -n "$NOW_MB" ] && [ "$NOW_MB" -gt 0 ] &&
	[ "$NOW_ALGO" != "$ALGO" ] && [ "$SWAP_USED" -le 65536 ]; then
	{
		echo "=== 算法是 $NOW_ALGO，改回 $ALGO（容量 $NOW_MB MiB）"
		BYTES=$(awk -v m="$NOW_MB" 'BEGIN{printf "%.0f", m * 1048576}')
		# 沿用当前的 swap 优先级，别把 zram0 的优先级改掉
		PRIO=$(awk '/zram0/ {print $5}' "$SWAPS" 2>/dev/null | head -1)
		case "$PRIO" in
		"" | *[!0-9-]*) PRIO=-2 ;;
		esac
		swapoff /dev/block/zram0 2>&1
		echo 1 >/sys/block/zram0/reset 2>&1
		echo "$ALGO" >"$ALGO_SYS" 2>&1
		echo "$BYTES" >/sys/block/zram0/disksize 2>&1
		mkswap /dev/block/zram0 2>&1
		swapon -p "$PRIO" /dev/block/zram0 2>&1
		echo "=== 改完是 $(cur_algo)，disksize=$(cat /sys/block/zram0/disksize 2>/dev/null)，swapon 优先级 $PRIO"
	} >>"$LOG" 2>/dev/null
elif [ "$MODE" = "algo" ] && [ "$NOW_ALGO" != "$ALGO" ] && [ "$SWAP_USED" -gt 65536 ]; then
	echo "=== 算法是 $NOW_ALGO，swap 已用 $SWAP_USED kB，不做重设" >>"$LOG" 2>/dev/null
fi

# 日志只保留最近 200 行
tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
