#!/system/bin/sh
# 开机完成后核对 zram0 是否真的跑在我们自己的驱动上。
#
# 正常路径是 early-init 把 KO 覆盖进 /vendor_dlkm/lib/modules 再 insmod，
# 厂商 modprobe 随后跳过。这里只做核对与失败善后，不碰 zram 的算法或容量。

MOD=${MODPATH:-/data/adb/modules/lz4kds}
STAGE=/metadata/watchdog/ksu/lz4kds
LOG=$MOD/selftest.log
if ! ( : >>"$LOG" ) 2>/dev/null; then
	LOG=/dev/null
fi
ALGO_SYS=/sys/block/zram0/comp_algorithm
SWAPS=/proc/swaps
DISKSIZE=/sys/block/zram0/disksize

log() {
	echo "$*" >>"$LOG" 2>/dev/null
}

cur_algo() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null | head -1
}

# 等 sys.boot_completed
i=0
while [ $i -lt 60 ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 2
	i=$((i + 1))
done

# 厂商脚本在开机 22 秒设容量并 swapon，等它做完再看。
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

NOW_ALGO=$(cur_algo)
NOW_DS=$(cat "$DISKSIZE" 2>/dev/null)
NOW_MB=$(awk -v d="$NOW_DS" 'BEGIN{print (d > 0) ? int(d / 1048576) : 0}')
VER=$(cat /sys/module/oplus_bsp_hybridswap_zram/version 2>/dev/null)

{
	echo "=== uptime=$(cut -d' ' -f1 /proc/uptime) build=$(getprop ro.build.version.incremental)"
	echo "驱动 : ${VER:-未加载}"
	echo "运行 : disksize=${NOW_DS:-0} (${NOW_MB} MiB) comp=${NOW_ALGO:-无}"
	echo "swap : $(grep zram0 "$SWAPS" 2>/dev/null)"
} >>"$LOG" 2>/dev/null

# KO 没接管成功时 early.sh 会留下这个标记，模块就此停用，走厂商流程。
if [ -f "$STAGE/disable_pending" ]; then
	log "=== early-init 接管失败，停用模块"
	if /data/adb/ksud module disable lz4kds 2>/dev/null && /data/adb/ksud initrc refresh 2>/dev/null; then
		rm -f "$STAGE/disable_pending" 2>/dev/null
		log "=== 模块已停用，修正后在管理器里重新启用并重启"
	else
		log "=== 停用失败，保留标记"
	fi
	tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
	exit 0
fi

if [ -f "$MOD/stock_driver" ]; then
	exit 0
fi

if ! grep -q '^oplus_bsp_hybridswap_zram ' /proc/modules; then
	log "=== 驱动没加载"
	tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
	exit 0
fi

if [ "$NOW_MB" -gt 0 ] && [ "$NOW_ALGO" != "lz4kds" ]; then
	log "=== 算法是 $NOW_ALGO，不是 lz4kds；看 early.log"
fi

tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exit 0
