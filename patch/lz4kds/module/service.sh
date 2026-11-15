#!/system/bin/sh
# 开机完成后核对 zram0 是否真的跑在我们自己的驱动上。
#
# 正常路径是 early-init 先装 oplus_bsp_zsmalloc、再 insmod 模块自带的 KO，
# 厂商 modprobe 随后跳过同名模块。这里只做核对与失败善后，不碰 zram 参数。

MOD=${MODPATH:-/data/adb/modules/lz4kds}

# ksud 的 early-init 目录随 uapi 版本变：uapi 6 起用 /metadata/vold/ksu。
stage_dir() {
	for _d in /metadata/vold/ksu /metadata/watchdog/ksu /metadata/ksu; do
		[ -d "$_d/lz4kds" ] && { echo "$_d/lz4kds"; return 0; }
	done
	for _d in /metadata/vold/ksu /metadata/watchdog/ksu /metadata/ksu; do
		[ -d "$_d" ] && { echo "$_d/lz4kds"; return 0; }
	done
	echo /metadata/vold/ksu/lz4kds
}

STAGE=$(stage_dir)
NULL_LOG=/dev/null
LOG=$MOD/selftest.log
if ! ( : >>"$LOG" ) 2>/dev/null; then
	LOG=$NULL_LOG
fi
ALGO_SYS=/sys/block/zram0/comp_algorithm
SWAPS=/proc/swaps
DISKSIZE=/sys/block/zram0/disksize

log() {
	echo "$*" >>"$LOG" 2>/dev/null
}

# 日志只留最近 60 行。LOG 落到 /dev/null 时不能截断，那会在 /dev 里留下 null.tmp。
trim() {
	[ "$LOG" = "$NULL_LOG" ] && return 0
	tail -60 "$LOG" >"$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
}

cur_algo() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null | head -1
}

param_get() {
	awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$STAGE/ko_params" 2>/dev/null
}

# 等 sys.boot_completed
i=0
while [ $i -lt 60 ]; do
	[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
	sleep 2
	i=$((i + 1))
done

# 厂商脚本在开机 22 秒设容量并 swapon，33 秒还会再设一次。等两轮都过去再看。
i=0
while [ $i -lt 60 ]; do
	UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	case "$UP" in
	"" | *[!0-9]*) UP=0 ;;
	esac
	[ "$UP" -ge 40 ] && break
	sleep 1
	i=$((i + 1))
done

NOW_ALGO=$(cur_algo)
NOW_DS=$(cat "$DISKSIZE" 2>/dev/null)
NOW_MB=$(awk -v d="$NOW_DS" 'BEGIN{print (d > 0) ? int(d / 1048576) : 0}')
ALGO_CFG=$(param_get ALGO)
STOCK_CFG=$(param_get STOCK)

{
	echo "=== uptime=$(cut -d' ' -f1 /proc/uptime) build=$(getprop ro.build.version.incremental)"
	echo "早期 : $(grep -c . "$STAGE/early.log" 2>/dev/null) 行日志，见 $STAGE/early.log"
	echo "运行 : disksize=${NOW_DS:-0} (${NOW_MB} MiB) comp=${NOW_ALGO:-无} 配置=${ALGO_CFG:-无} STOCK=${STOCK_CFG:-0}"
	echo "swap : $(grep zram0 "$SWAPS" 2>/dev/null)"
} >>"$LOG" 2>/dev/null

# early.sh 失败时会留下这个标记，模块就此停用，走厂商流程。
if [ -f "$STAGE/disable_pending" ]; then
	log "=== early-init 接管失败：$(cat "$STAGE/disable_pending" 2>/dev/null)"
	if /data/adb/ksud module disable lz4kds 2>/dev/null && /data/adb/ksud initrc refresh 2>/dev/null; then
		rm -f "$STAGE/disable_pending" 2>/dev/null
		log "=== 模块已停用，修正后在管理器里重新启用并重启"
	else
		log "=== 停用失败，保留标记"
	fi
	trim
	exit 0
fi

if [ "$STOCK_CFG" = "1" ]; then
	log "=== STOCK=1，按配置不接管"
	trim
	exit 0
fi

if ! grep -q '^oplus_bsp_hybridswap_zram ' /proc/modules; then
	log "=== 驱动没加载"
	trim
	exit 0
fi

# off 表示算法交给厂商脚本，实际值不参与比对。
case "$ALGO_CFG" in
'' | off) : ;;
*)
	if [ "$NOW_MB" -gt 0 ] && [ "$NOW_ALGO" != "$ALGO_CFG" ]; then
		log "=== 算法是 $NOW_ALGO，配置是 $ALGO_CFG；看 early.log"
	fi
	;;
esac

trim
exit 0
