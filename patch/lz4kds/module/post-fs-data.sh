#!/system/bin/sh
# 开机时把 zram 驱动换成 LZ4KDS 版，不改任何分区。
#
# KernelSU 在 post-fs-data 阶段调用本脚本（实测约开机 3.6 秒）。此时厂商驱动已经
# 加载、zram0 已存在，但 disksize 与 swapon 还没做（这两步在开机 22 秒左右），
# 换驱动不会丢任何已换出的页。
#
# 流程：
#   1. 卸三个依赖模块，让 oplus_bsp_hybridswap_zram 的引用计数归零。
#   2. 卸厂商驱动，它 destroy_devices() 删掉 zram0。
#   3. 按 driver.conf 里的参数装我们的驱动，它重建 zram0。
#   4. 装回三个依赖模块。
#   任何一步失败都把厂商模块装回去。
#
# 想临时用回厂商驱动：sh zram.sh stock；改回来：sh zram.sh ours。

MOD=${MODPATH:-/data/adb/modules/lz4kds}
KO=$MOD/payload/oplus_bsp_hybridswap_zram.ko
CONF=$MOD/payload/driver.conf
FLAG=$MOD/stock_driver
VENDOR=/vendor_dlkm/lib/modules
SYS=/sys/module/oplus_bsp_hybridswap_zram/parameters
ZRAM=/dev/block/zram0

# 日志写不进去时退到 /dev/null。日志路径打不开会让整条命令不执行
# （mksh 里重定向先于 fork），那样卸模块这一步会被静默跳过。
LOG=$MOD/driver.log
if ! ( : >>"$LOG" ) 2>/dev/null; then
	LOG=/dev/null
fi

DEPS="oplus_bsp_fg_protect oplus_bsp_zram_opt oplus_exit_mm_optimize"

log() {
	echo "$(date +%H:%M:%S) $*" >>"$LOG" 2>/dev/null
}

loaded() {
	grep -qE "^$1 " /proc/modules
}

# 我们的驱动带 selftest_codec、zram_algo 这些参数，厂商的只有 num_devices、
# nr_kcompressd、queue_size_per_kcompressd。
ours_active() {
	[ -d "$SYS" ] || return 1
	[ -e "$SYS/selftest_codec" ]
}

# driver.conf 里 insmod 那一行的参数，原样交给 insmod。
# 行首空格、多个空格、行尾注释都能处理；取不到就是空串。
conf_args() {
	awk '
		{
			sub(/#.*/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			n = split($0, a, /[ \t]+/)
			if (n >= 2 && a[1] == "insmod" && a[2] ~ /oplus_bsp_hybridswap_zram\.ko$/) {
				out = ""
				for (i = 3; i <= n; i++) out = out (out == "" ? "" : " ") a[i]
				print out
				exit
			}
		}
	' "$CONF" 2>/dev/null | head -1
}

unload_deps() {
	for m in $DEPS; do
		loaded "$m" || continue
		if rmmod "$m" 2>>"$LOG"; then
			log "卸下 $m"
		else
			log "ERROR: 卸不下 $m"
		fi
	done
}

load_deps() {
	for m in $DEPS; do
		loaded "$m" && continue
		if [ ! -f "$VENDOR/$m.ko" ]; then
			log "ERROR: 找不到 $VENDOR/$m.ko"
			continue
		fi
		if insmod "$VENDOR/$m.ko" 2>>"$LOG"; then
			log "装回 $m"
		else
			log "ERROR: 装不回 $m"
		fi
	done
}

# 只剩厂商驱动在跑。我们的驱动卸不掉时明确记一笔，别让日志只剩裸 stderr。
restore_vendor() {
	if loaded oplus_bsp_hybridswap_zram; then
		if rmmod oplus_bsp_hybridswap_zram 2>>"$LOG"; then
			log "卸下失效的驱动"
		else
			log "ERROR: 卸不下 oplus_bsp_hybridswap_zram，厂商驱动装不回来"
			return 1
		fi
	fi

	if ! loaded oplus_bsp_zsmalloc && [ -f "$VENDOR/oplus_bsp_zsmalloc.ko" ]; then
		insmod "$VENDOR/oplus_bsp_zsmalloc.ko" 2>>"$LOG" || log "ERROR: 装不回 zsmalloc"
	fi
	if ! loaded oplus_bsp_hybridswap_zram && [ -f "$VENDOR/oplus_bsp_hybridswap_zram.ko" ]; then
		if insmod "$VENDOR/oplus_bsp_hybridswap_zram.ko" 2>>"$LOG"; then
			log "已装回厂商驱动"
		else
			log "ERROR: 厂商驱动装不回"
		fi
	fi
	return 0
}

rollback() {
	log "回退到厂商驱动"
	restore_vendor
	load_deps
}

main() {
	log "=== 开始"

	if [ -f "$FLAG" ]; then
		log "存在 $FLAG，保持厂商驱动"
		return 0
	fi

	if [ ! -f "$KO" ]; then
		log "ERROR: 缺 $KO"
		return 1
	fi

	if ours_active; then
		log "已经是我们的驱动"
		return 0
	fi

	if [ ! -f "$CONF" ]; then
		log "ERROR: 缺 $CONF"
		return 1
	fi
	ARGS=$(conf_args)
	if [ -z "$ARGS" ]; then
		log "WARN: $CONF 里没有可用的 insmod 参数，用驱动默认值"
	fi

	if loaded oplus_bsp_hybridswap_zram; then
		unload_deps
		if ! rmmod oplus_bsp_hybridswap_zram 2>>"$LOG"; then
			log "ERROR: 厂商驱动 rmmod 失败，放弃替换"
			load_deps
			return 1
		fi
		log "卸下厂商驱动"
	fi

	log "insmod 参数: ${ARGS:-(无)}"
	# 参数里有 * ? [ 时不让 shell 展开成文件名
	set -f
	# shellcheck disable=SC2086
	insmod "$KO" $ARGS 2>>"$LOG"
	RET=$?
	set +f
	if [ $RET -ne 0 ]; then
		log "ERROR: 我们的驱动加载失败（insmod rc=$RET）"
		rollback
		return 1
	fi

	if ! ours_active || [ ! -b "$ZRAM" ]; then
		log "ERROR: 装上了但没有 $ZRAM"
		rollback
		return 1
	fi

	log "接管成功 comp=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
	log "codec=$(cat "$SYS/selftest_codec" 2>/dev/null)"
	load_deps
	return 0
}

main
RET=$?
log "=== 结束（rc=$RET）"

if [ "$LOG" != /dev/null ]; then
	tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
fi
exit $RET
