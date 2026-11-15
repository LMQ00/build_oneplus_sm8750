#!/system/bin/sh
# early-init 阶段接管 zram 驱动。
#
# 厂商的 oplus_bsp_hybridswap_zram 由 modprobe 在开机后加载。这里抢在它之前：
# 把模块自带的 KO bind mount 到 /vendor_dlkm/lib/modules/ 上的同名文件，
# 再 insmod。厂商 modprobe 之后看到同名模块已在运行，直接跳过。
#
# 厂商那版驱动从头到尾没有加载过，所以不需要 rmmod，也不会留下它的
# android_vh 探针与 cgroup cftype。
#
# 这个脚本由 init 在 early-init 阶段执行，那时 /data 还没挂载，脚本和 KO 都在
# /metadata/watchdog/ksu/lz4kds/ 下。
set -eu

STAGE=${0%/*}
VENDOR_KO=/vendor_dlkm/lib/modules/oplus_bsp_hybridswap_zram.ko

say() {
	printf '<6>LZ4KDS %s\n' "$*" >/dev/kmsg 2>/dev/null || true
	echo "$*"
}

BOUND=""

fail() {
	say "接管失败：$*"
	printf '%s\n' "$*" >"$STAGE/disable_pending" 2>/dev/null || true
	for p in $BOUND; do umount "$p" 2>/dev/null || true; done
	exit 1
}

say "early-init 开始，uptime=$(cut -d' ' -f1 /proc/uptime)"

[ -f "$STAGE/oplus_bsp_hybridswap_zram.ko" ] || fail "缺少 KO"

if grep -q '^oplus_bsp_hybridswap_zram ' /proc/modules; then
	fail "驱动已被加载，无法接管"
fi

[ -f "$VENDOR_KO" ] || fail "找不到 $VENDOR_KO"

mount -o bind "$STAGE/oplus_bsp_hybridswap_zram.ko" "$VENDOR_KO" || fail "bind mount 失败"
BOUND="$VENDOR_KO"
say "已覆盖 $VENDOR_KO"

# 参数由 ko_params 决定，改完重启生效。
ALGO=lz4kds
SIZE_MB=12288
if [ -r "$STAGE/ko_params" ]; then
	# shellcheck disable=SC1091
	. "$STAGE/ko_params"
fi

if ! insmod "$STAGE/oplus_bsp_hybridswap_zram.ko" \
	num_devices=1 zram_size_mb="$SIZE_MB" zram_algo="$ALGO"; then
	fail "insmod 失败"
fi

grep -q '^oplus_bsp_hybridswap_zram ' /proc/modules || fail "insmod 之后 /proc/modules 里没有它"

# 驱动自检结果：codec 失败会让 insmod 直接失败；IO 失败只关 SDDC。
ST_CODEC=$(cat /sys/module/oplus_bsp_hybridswap_zram/parameters/selftest_codec 2>/dev/null || echo '?')
ST_IO=$(cat /sys/module/oplus_bsp_hybridswap_zram/parameters/selftest_io 2>/dev/null || echo '?')
say "自检 codec=$ST_CODEC io=$ST_IO"

mkdir -p "$STAGE"
cat /proc/sys/kernel/random/boot_id >"$STAGE/active_boot" 2>/dev/null || true
rm -f "$STAGE/disable_pending"

say "接管完成，版本 $(cat /sys/module/oplus_bsp_hybridswap_zram/version 2>/dev/null || echo 未知)"
trap - EXIT 2>/dev/null || true
exit 0
