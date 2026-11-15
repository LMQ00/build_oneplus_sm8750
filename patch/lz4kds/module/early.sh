#!/system/bin/sh
# early-init 阶段接管 zram 驱动。
#
# 厂商的 oplus_bsp_hybridswap_zram 由 vendor.modprobe 在同一个 early-init 里拉起。
# 这里保证最终跑的是模块自带的 KO：
#
#   1. 把自带 KO bind mount 到 /vendor_dlkm/lib/modules/ 上的同名文件。
#      厂商 modprobe 就算抢先，读到的也是这份。
#   2. 先装依赖 oplus_bsp_zsmalloc —— 自带 KO 要用它导出的 11 个 zs_*_oplus 符号，
#      而 insmod 不像 modprobe 那样自动装依赖。
#   3. 自己 insmod 自带 KO，带上容量与算法参数。抢输了就改成写 sysfs，
#      在厂商脚本写 disksize 之前落定。
#
# 厂商那版驱动从头到尾没有加载过，也就不需要 rmmod。
#
# 这个脚本由 init 在 early-init 阶段执行，那时 /data 还没挂载，脚本与 KO 都在
# /metadata/watchdog/ksu/lz4kds/ 下。

set -u

STAGE=/metadata/watchdog/ksu/lz4kds
VENDOR_DIR=/vendor_dlkm/lib/modules
MOD_NAME=oplus_bsp_hybridswap_zram
ZS_NAME=oplus_bsp_zsmalloc
VENDOR_KO=$VENDOR_DIR/$MOD_NAME.ko
PARAM_DIR=/sys/module/$MOD_NAME/parameters
COMP_ALGO=/sys/block/zram0/comp_algorithm

# mksh 写 here-document 要临时文件，此时 /data 还没挂载。
export TMPDIR="$STAGE"

LOG=$STAGE/early.log
[ -f "$LOG" ] && mv -f "$LOG" "$STAGE/early.previous.log" 2>/dev/null
if ! ( : >>"$LOG" ) 2>/dev/null; then
	LOG=/dev/null
fi
exec >>"$LOG" 2>&1

say() {
	printf '%s %s\n' "$(cut -d' ' -f1 /proc/uptime)" "$*"
	printf '<6>LZ4KDS %s\n' "$*" >/dev/kmsg 2>/dev/null || true
}

BOUND=""

# 非零退出时拆掉 bind mount，让厂商 modprobe 还能装回原厂那份。
rollback() {
	_result=$?
	if [ "$_result" -ne 0 ]; then
		for _p in $BOUND; do umount "$_p" 2>/dev/null || true; done
		if [ ! -f "$STAGE/disable_pending" ]; then
			say "接管中止，退出码 $_result"
			printf '退出码 %s\n' "$_result" >"$STAGE/disable_pending" 2>/dev/null || true
		fi
	fi
	exit "$_result"
}
trap rollback EXIT

fail() {
	say "接管失败：$*"
	printf '%s\n' "$*" >"$STAGE/disable_pending" 2>/dev/null || true
	exit 1
}

loaded() {
	grep -q "^$1 " /proc/modules
}

# 只有自带 KO 才有 zram_algo 这个参数。
ours_running() {
	[ -e "$PARAM_DIR/zram_algo" ]
}

# 没赶上 insmod 的那一路：驱动已经用自带 KO 起来了，但参数还是默认值。
# zram_size_mb 每次写 disksize 都会重新读，comp_algorithm 在 disksize 之前可写，
# 所以这两项在这里落定，效果与 insmod 时传参一致。
apply_params() {
	if [ "${SIZE_MB:-0}" != "0" ]; then
		if printf '%s\n' "$SIZE_MB" >"$PARAM_DIR/zram_size_mb" 2>/dev/null; then
			say "容量写进 zram_size_mb=$SIZE_MB"
		else
			say "容量写入失败，用厂商值"
		fi
	fi
	if [ "$ALGO" = "off" ]; then
		# 与 insmod 时传 zram_algo=off 等价：放开降级，算法回到内核默认。
		printf '0\n' >"$PARAM_DIR/lz4kds_nodegrade" 2>/dev/null || true
		say "算法交给驱动默认值"
		return 0
	fi
	if [ -w "$COMP_ALGO" ]; then
		if printf '%s\n' "$ALGO" >"$COMP_ALGO" 2>/dev/null; then
			say "算法写进 comp_algorithm=$ALGO"
		else
			say "算法写入失败，用驱动默认值"
		fi
	fi
}

# 上次的失败记录只对上次开机有效。
rm -f "$STAGE/disable_pending"

say "early-init 开始"

[ -f "$STAGE/$MOD_NAME.ko" ] || fail "缺少 $STAGE/$MOD_NAME.ko"

# 参数由 ko_params 决定，改完重启生效。
ALGO=lz4kds
SIZE_MB=12288
if [ -r "$STAGE/ko_params" ]; then
	# shellcheck disable=SC1091
	. "$STAGE/ko_params"
fi

if loaded "$MOD_NAME"; then
	ours_running || fail "厂商驱动已加载，无法接管"
	say "厂商 modprobe 已用自带 KO 抢先加载"
	apply_params
	trap - EXIT
	exit 0
fi

# 先覆盖：厂商 modprobe 只要在这之后跑，读到的就是自带 KO。
# 覆盖不成不算致命，下面的 insmod 仍可能抢在它前面。
if mount -o bind "$STAGE/$MOD_NAME.ko" "$VENDOR_KO"; then
	BOUND="$VENDOR_KO"
	say "已覆盖 $VENDOR_KO"
else
	say "覆盖 $VENDOR_KO 失败，继续尝试直接 insmod"
fi

# 自带 KO 的 depends 是 oplus_bsp_zsmalloc，insmod 不解析依赖，这里自己装。
if ! loaded "$ZS_NAME"; then
	[ -f "$VENDOR_DIR/$ZS_NAME.ko" ] || fail "缺少 $VENDOR_DIR/$ZS_NAME.ko"
	insmod "$VENDOR_DIR/$ZS_NAME.ko" || fail "insmod $ZS_NAME 失败"
	loaded "$ZS_NAME" || fail "insmod 之后没有 $ZS_NAME"
	say "已加载 $ZS_NAME"
fi

# 厂商 modprobe 可能在这一瞬间插进来，它装的是我们覆盖过的那份，也算成功。
if ! loaded "$MOD_NAME"; then
	if insmod "$STAGE/$MOD_NAME.ko" \
		num_devices=1 zram_size_mb="$SIZE_MB" zram_algo="$ALGO"; then
		say "insmod 成功，参数随模块加载生效"
	else
		loaded "$MOD_NAME" || fail "insmod 失败且驱动没加载"
		say "insmod 抢输，厂商 modprobe 已用自带 KO 装好"
		apply_params
	fi
fi

loaded "$MOD_NAME" || fail "insmod 之后没有 $MOD_NAME"

ours_running || fail "加载起来的是厂商驱动，不是自带的"

# 驱动自检结果：codec 失败会让 insmod 直接失败；IO 失败只关 SDDC。
C=$(cat "$PARAM_DIR/selftest_codec" 2>/dev/null || echo "?")
I=$(cat "$PARAM_DIR/selftest_io" 2>/dev/null || echo "?")
say "自检 codec=$C io=$I"

say "接管完成，算法 $ALGO，容量 $SIZE_MB MiB"
trap - EXIT
exit 0
