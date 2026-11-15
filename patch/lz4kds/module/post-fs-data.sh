#!/system/bin/sh
# 开机把 /sys/block/zram0/comp_algorithm 写成 driver.conf 里的 algo。
#
# KernelSU 在 post-fs-data 阶段调用本脚本（dl.log 里 ksud 在开机 6.4 秒起执行，
# 6.7 秒退出）。此时厂商驱动已经加载、zram0 已存在，但 disksize 与 swapon 还没做
# （这两步在开机 22 秒左右），comp_algorithm 在这个窗口里可写。厂商驱动在设
# disksize 时按 comp_algs[0] 建 zcomp，所以这里写的值一直留到那时才生效。
#
# 算法由内核自带（CONFIG_CRYPTO_LZ4KD / CONFIG_CRYPTO_LZ4K），本脚本不装卸
# 任何模块。
#
# 想临时不干预：sh zram.sh stock；改回来：sh zram.sh ours。

MOD=${MODPATH:-/data/adb/modules/lz4kds}
CONF=$MOD/payload/driver.conf
FLAG=$MOD/stock_driver
ALGO_SYS=/sys/block/zram0/comp_algorithm

# 日志写不进去时退到 /dev/null。日志路径打不开会让整条命令不执行
# （mksh 里重定向先于 fork）。
LOG=$MOD/driver.log
if ! ( : >>"$LOG" ) 2>/dev/null; then
	LOG=/dev/null
fi

log() {
	echo "$(date +%H:%M:%S) $*" >>"$LOG" 2>/dev/null
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
			sub(/\r$/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			if ($0 ~ "^" k "[ \t]*=") {
				sub("^" k "[ \t]*=", "")
				gsub(/^[ \t]+|[ \t]+$/, "")
				print
				exit
			}
		}
	' "$CONF" 2>/dev/null | head -1
}

# 只写 comp_algorithm，不碰任何模块。
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

main() {
	log "=== 开始"

	if [ -f "$FLAG" ]; then
		log "存在 $FLAG，不干预"
		return 0
	fi

	ALGO=$(conf_get algo)
	[ -n "$ALGO" ] || ALGO=lz4kd

	if [ "$ALGO" = "off" ]; then
		log "algo=off，不干预"
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
