#!/system/bin/sh
# boot 完成后核对算法是否真的生效；没生效就按 zram.sh 的顺序改回来。
MOD=${MODPATH:-/data/adb/modules/lz4kds}
LOG=$MOD/selftest.log
P=/sys/module/oplus_bsp_hybridswap_zram/parameters
ALGO_SYS=/sys/block/zram0/comp_algorithm

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

# 厂商的 init 脚本在 22 秒设容量并 swapon；厂商驱动收到 reset 会把算法换回
# lzo-rle。等容量落实之后再核对，看到的才是最终状态。
i=0
while [ $i -lt 60 ]; do
	[ "$(cur_mb)" -gt 0 ] && break
	sleep 2
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

# 只在 algo 模式、没开 stock 标志、算法确实不一致时动手
if [ "$MODE" = "algo" ] && [ ! -f "$MOD/stock_driver" ] &&
	[ "$ALGO" != "off" ] && [ -n "$NOW_MB" ] && [ "$NOW_MB" -gt 0 ] &&
	[ "$NOW_ALGO" != "$ALGO" ]; then
	{
		echo "=== 算法是 $NOW_ALGO，改回 $ALGO（容量 $NOW_MB MiB）"
		sh "$MOD/zram.sh" "$NOW_MB" "$ALGO" --quiet 2>&1
		echo "=== 改完是 $(cur_algo)"
	} >>"$LOG" 2>/dev/null
fi

# 日志只保留最近 200 行
tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
