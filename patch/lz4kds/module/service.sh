#!/system/bin/sh
# boot 完成后记录本次开机的实际状态，便于跨版本/换机型后核对
MOD=${MODPATH:-/data/adb/modules/lz4kds}
LOG=$MOD/selftest.log
P=/sys/module/oplus_bsp_hybridswap_zram/parameters

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

i=0
while [ $i -lt 30 ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 2
	i=$((i + 1))
done

MODE=$(conf_get mode)
ALGO=$(conf_get algo)

# 开机期间别的脚本可能 reset zram0，reset 会把算法换回驱动默认值。boot 完成后
# 核对一次，不一致就记进日志，由人决定要不要用 zram.sh 换回来。
ALGO_SYS=/sys/block/zram0/comp_algorithm
cur_algo() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null | head -1
}

if [ "${MODE:-algo}" = "algo" ] && [ -n "${ALGO:-}" ] && [ "${ALGO:-}" != "off" ] &&
	[ ! -f "$MOD/stock_driver" ]; then
	NOW=$(cur_algo)
	if [ "$NOW" != "$ALGO" ]; then
		echo "=== 算法被改回 $NOW，配置要的是 $ALGO" >>"$LOG" 2>/dev/null
		echo "=== 恢复: sh $MOD/zram.sh <MiB> $ALGO" >>"$LOG" 2>/dev/null
	fi
fi

{
	echo "=== uptime=$(cut -d' ' -f1 /proc/uptime) build=$(getprop ro.build.version.incremental)"
	echo "配置: mode=${MODE:-algo} algo=${ALGO:-lz4kd}"
	echo "运行: disksize=$(cat /sys/block/zram0/disksize 2>/dev/null) comp=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null)"
	echo "swap: $(grep zram0 /proc/swaps 2>/dev/null)"
	if [ -e "$P/selftest_codec" ]; then
		echo "selftest: codec=$(cat "$P/selftest_codec" 2>/dev/null) io=$(cat "$P/selftest_io" 2>/dev/null)"
		grep -E "^(enabled|aliases|deltas|saved_bytes|decode_failures|conversion_failures):" \
			/sys/block/zram0/sddc_stat 2>/dev/null
	fi
} >>"$LOG" 2>/dev/null

# 日志只保留最近 200 行
tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
