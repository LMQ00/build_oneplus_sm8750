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
#   4. 任何一步失败，把厂商模块装回去。
#
# 想临时用回厂商驱动：sh zram.sh stock；改回来：sh zram.sh ours。

MOD=${MODPATH:-/data/adb/modules/lz4kds}
LOG=$MOD/hotswap.log
KO=$MOD/payload/oplus_bsp_hybridswap_zram.ko
CONF=$MOD/payload/driver.conf
FLAG=$MOD/stock_driver
VENDOR=/vendor_dlkm/lib/modules
SYS=/sys/module/oplus_bsp_hybridswap_zram/parameters

DEPS="oplus_bsp_fg_protect oplus_bsp_zram_opt oplus_exit_mm_optimize"

log() {
	echo "$(date +%H:%M:%S) $*" >>"$LOG"
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
conf_args() {
	sed -n 's/^insmod[ 	][^ 	]*oplus_bsp_hybridswap_zram\.ko[ 	]*//p' "$CONF" 2>/dev/null | head -1
}

unload_deps() {
	for m in $DEPS; do
		loaded "$m" && { rmmod "$m" 2>>"$LOG" && log "卸下 $m"; }
	done
}

load_deps() {
	for m in $DEPS; do
		if ! loaded "$m" && [ -f "$VENDOR/$m.ko" ]; then
			insmod "$VENDOR/$m.ko" 2>>"$LOG" && log "装回 $m" || log "ERROR: 装不回 $m"
		fi
	done
}

rollback() {
	log "回退到厂商驱动"
	loaded oplus_bsp_hybridswap_zram && rmmod oplus_bsp_hybridswap_zram 2>>"$LOG"
	if ! loaded oplus_bsp_zsmalloc && [ -f "$VENDOR/oplus_bsp_zsmalloc.ko" ]; then
		insmod "$VENDOR/oplus_bsp_zsmalloc.ko" 2>>"$LOG"
	fi
	if ! loaded oplus_bsp_hybridswap_zram && [ -f "$VENDOR/oplus_bsp_hybridswap_zram.ko" ]; then
		insmod "$VENDOR/oplus_bsp_hybridswap_zram.ko" 2>>"$LOG" \
			&& log "已装回厂商驱动" || log "ERROR: 厂商驱动装不回"
	fi
	load_deps
}

main() {
	log "=== 开始"

	if [ -f "$FLAG" ]; then
		log "存在 $FLAG，保持厂商驱动"
		log "=== 结束"
		return 0
	fi

	if [ ! -f "$KO" ]; then
		log "ERROR: 缺 $KO"
		return 0
	fi

	if ours_active; then
		log "已经是我们的驱动"
		return 0
	fi

	if loaded oplus_bsp_hybridswap_zram; then
		unload_deps
		if ! rmmod oplus_bsp_hybridswap_zram 2>>"$LOG"; then
			log "ERROR: 厂商驱动 rmmod 失败，放弃替换"
			load_deps
			return 0
		fi
		log "卸下厂商驱动"
	fi

	ARGS=$(conf_args)
	log "insmod 参数: ${ARGS:-(无)}"
	# shellcheck disable=SC2086
	if ! insmod "$KO" $ARGS 2>>"$LOG"; then
		log "ERROR: 我们的驱动加载失败"
		rollback
		return 0
	fi

	if ! ours_active || [ ! -b /dev/zram0 ]; then
		log "ERROR: 装上了但没有 zram0"
		rollback
		return 0
	fi

	log "接管成功 comp=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
	log "codec=$(cat "$SYS/selftest_codec" 2>/dev/null)"
	load_deps
	log "=== 结束"
}

main

tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
