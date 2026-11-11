#!/system/bin/sh
# boot 完成后记录自检结果与运行状态，便于跨版本/换机型后核对
MOD=/data/adb/modules/lz4kds
LOG=$MOD/selftest.log
P=/sys/module/oplus_bsp_hybridswap_zram/parameters

i=0
while [ $i -lt 30 ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 2
	i=$((i + 1))
done

{
	echo "=== uptime=$(cut -d' ' -f1 /proc/uptime) build=$(getprop ro.build.version.incremental)"
	echo "selftest: codec=$(cat $P/selftest_codec 2>/dev/null) io=$(cat $P/selftest_io 2>/dev/null)"
	echo "disksize=$(cat /sys/block/zram0/disksize 2>/dev/null) comp=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
	grep -E "^(enabled|aliases|deltas|saved_bytes|decode_failures|conversion_failures):" \
		/sys/block/zram0/sddc_stat 2>/dev/null
} >>"$LOG" 2>/dev/null

# 日志只保留最近 200 行
tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
