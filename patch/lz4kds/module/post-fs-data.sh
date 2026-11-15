#!/system/bin/sh
# 开机时让 zram0 用上 LZ4KD 压缩。
#
# KernelSU 在 post-fs-data 阶段调用本脚本（dl.log 里 ksud 在开机 6.4 秒起执行，
# 6.7 秒退出）。此时厂商驱动已经加载、zram0 已存在，但 disksize 与 swapon 还没做
# （这两步在开机 22 秒左右），comp_algorithm 在这个窗口里可写。
#
# 两种模式，由 driver.conf 里的 mode 决定：
#
#   algo（默认）  不装卸任何模块，只往 /sys/block/zram0/comp_algorithm 写
#                lz4kd。算法由内核自带（CONFIG_CRYPTO_LZ4KD），厂商驱动自己
#                就会用它压缩。
#
#   replace       卸三个依赖模块 → 卸厂商驱动 → 装本模块的驱动 → 装回依赖。
#                这个模式能拿到 SDDC 与 lz4kds。厂商驱动的 module_exit 只
#                删 zram 设备，它注册的七个 android_vh 探针留在内核里，回调
#                地址指向它已被释放的代码段。
#
# 想临时用回厂商驱动：sh zram.sh stock；改回来：sh zram.sh ours。

MOD=${MODPATH:-/data/adb/modules/lz4kds}
KO=$MOD/payload/oplus_bsp_hybridswap_zram.ko
CONF=$MOD/payload/driver.conf
FLAG=$MOD/stock_driver
VENDOR=/vendor_dlkm/lib/modules
SYS=/sys/module/oplus_bsp_hybridswap_zram/parameters
ZRAM=/dev/block/zram0
ALGO_SYS=/sys/block/zram0/comp_algorithm

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

# 跑 insmod / rmmod 并把它们的 stderr 记进日志。
# 不直接写 2>>"$LOG"：mksh 里重定向失败会让命令根本不执行，
# 那样 rmmod 会静默跳过、insmod 也会静默跳过。
run() {
	_run_out=$("$@" 2>&1)
	_run_rc=$?
	[ -n "$_run_out" ] && log "  $_run_out"
	return $_run_rc
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

# 当前生效的压缩算法，从 comp_algorithm 里带方括号的那个取。
cur_algo() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ALGO_SYS" 2>/dev/null | head -1
}

# driver.conf 里 key=value 的值，取第一个匹配。
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
	' "$CONF" 2>/dev/null | head -1
}

# driver.conf 里 insmod 那一行的参数，原样交给 insmod。
# 行首空格、多个空格、行尾注释都能处理；取不到就是空串。
conf_args() {
	awk '
		{
			sub(/#.*/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			n = split($0, a, /[ \t]+/)
			# a[2] 可能带目录前缀，只看最后一段是不是这个 KO
			k = split(a[2], p, "/")
			if (n >= 2 && a[1] == "insmod" && p[k] == "oplus_bsp_hybridswap_zram.ko") {
				out = ""
				for (i = 3; i <= n; i++) out = out (out == "" ? "" : " ") a[i]
				print out
				exit
			}
		}
	' "$CONF" 2>/dev/null | head -1
}

# 只写 comp_algorithm，不碰任何模块。
# 厂商驱动在 disksize 时用 zram->comp_algs[0] 建 zcomp，所以这里写的值一直
# 留到 22 秒设容量时才生效。
apply_algo() {
	_want=$1

	if [ ! -e "$ALGO_SYS" ]; then
		log "ERROR: 没有 $ALGO_SYS"
		return 1
	fi

	_now=$(cur_algo)
	if [ "$_now" = "$_want" ]; then
		log "已经是 $_want，不写"
		return 0
	fi

	# 设备已初始化时驱动返回 EBUSY，写入必然失败，先记下现状。
	if ! echo "$_want" >"$ALGO_SYS" 2>/dev/null; then
		log "ERROR: 写 $ALGO_SYS 失败，当前 $(cur_algo)"
		return 1
	fi

	_after=$(cur_algo)
	if [ "$_after" != "$_want" ]; then
		log "ERROR: 写完再读是 $_after，不是 $_want"
		return 1
	fi

	log "算法 $_now -> $_want"
	return 0
}

unload_deps() {
	for m in $DEPS; do
		loaded "$m" || continue
		if run rmmod "$m"; then
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
		if run insmod "$VENDOR/$m.ko"; then
			log "装回 $m"
		else
			log "ERROR: 装不回 $m"
		fi
	done
}

restore_vendor() {
	if loaded oplus_bsp_hybridswap_zram; then
		if run rmmod oplus_bsp_hybridswap_zram; then
			log "卸下失效的驱动"
		else
			log "ERROR: 卸不下 oplus_bsp_hybridswap_zram，厂商驱动装不回来"
			return 1
		fi
	fi

	if ! loaded oplus_bsp_zsmalloc && [ -f "$VENDOR/oplus_bsp_zsmalloc.ko" ]; then
		run insmod "$VENDOR/oplus_bsp_zsmalloc.ko" || log "ERROR: 装不回 zsmalloc"
	fi
	if ! loaded oplus_bsp_hybridswap_zram && [ -f "$VENDOR/oplus_bsp_hybridswap_zram.ko" ]; then
		if run insmod "$VENDOR/oplus_bsp_hybridswap_zram.ko"; then
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

# 替换驱动。只在 driver.conf 里 mode=replace 时走到这里。
replace_driver() {
	if [ ! -f "$KO" ]; then
		log "ERROR: 缺 $KO"
		return 1
	fi

	if ours_active; then
		log "已经是我们的驱动"
		return 0
	fi

	ARGS=$(conf_args)
	if [ -z "$ARGS" ]; then
		log "WARN: $CONF 里没有可用的 insmod 参数，用驱动默认值"
	fi

	if loaded oplus_bsp_hybridswap_zram; then
		unload_deps
		if ! run rmmod oplus_bsp_hybridswap_zram; then
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
	run insmod "$KO" $ARGS
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

	log "接管成功 comp=$(cat $ALGO_SYS 2>/dev/null)"
	log "codec=$(cat "$SYS/selftest_codec" 2>/dev/null)"
	load_deps
	return 0
}

main() {
	log "=== 开始"

	if [ -f "$FLAG" ]; then
		log "存在 $FLAG，保持厂商驱动"
		return 0
	fi

	MODE=$(conf_get mode | tr '[:upper:]' '[:lower:]')
	[ -n "$MODE" ] || MODE=algo
	ALGO=$(conf_get algo)
	[ -n "$ALGO" ] || ALGO=lz4kd

	log "模式 $MODE 算法 $ALGO"

	if [ "$MODE" = "replace" ]; then
		replace_driver
		return $?
	fi

	if ours_active; then
		log "已经是我们的驱动，跳过写算法"
		return 0
	fi

	apply_algo "$ALGO"
}

main
RET=$?
log "=== 结束（rc=$RET）"

if [ "$LOG" != /dev/null ]; then
	tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
fi
exit $RET
