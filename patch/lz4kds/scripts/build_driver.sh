#!/bin/bash
# 用已 prepare 好的内核树编译 LZ4KDS 版 oplus_bsp_hybridswap_zram.ko（out-of-tree）。
#
# 用法：build_driver.sh <内核源码目录> <产物输出目录>
#
# 前置：内核树必须已经跑过 `make Image`，因此 out/.config、out/Module.symvers
# 都已存在 —— out-of-tree 模块依赖它们做 modpost。
#
# 为什么是 out-of-tree 而不是把驱动放进内核树：
#   设备上 zram 由厂商模块 oplus_bsp_hybridswap_zram.ko 提供，把驱动编进
#   Image 并不会替换掉它；只有编成独立 .ko 才能在侧载后真正接管 zram。
set -euo pipefail

KSRC="${1:?用法: build_driver.sh <内核源码目录> <产物输出目录>}"
OUTDIR="${2:?用法: build_driver.sh <内核源码目录> <产物输出目录>}"
PAYLOAD_DIR="$(cd "$(dirname "$0")/.." && pwd)/driver"

fail() {
	echo "::error::$*"
	exit 1
}

[ -f "$KSRC/out/.config" ] || fail "${KSRC}/out/.config 不存在，内核还没构建过"
# `make Image` 正常会同时产出 out/Module.symvers（内容与 vmlinux.symvers 相同）。
# 万一只产出了 vmlinux.symvers，这里补一份，modpost 只认 Module.symvers。
if [ ! -f "$KSRC/out/Module.symvers" ]; then
	[ -f "$KSRC/out/vmlinux.symvers" ] || fail "${KSRC}/out 下既没有 Module.symvers 也没有 vmlinux.symvers，内核还没构建过"
	cp "$KSRC/out/vmlinux.symvers" "$KSRC/out/Module.symvers"
	echo "  已用 vmlinux.symvers 生成 Module.symvers"
fi

echo "== 准备 out-of-tree 构建目录 =="
# 目录必须保持厂商布局：驱动头文件用 ../thp_zsmalloc/ 这种相对路径引用。
WORK="${OUTDIR%/}/build"
rm -rf "$WORK"
mkdir -p "$WORK"
cp -r "$PAYLOAD_DIR/hybridswap_zram" "$WORK/hybridswap_zram"
cp -r "$PAYLOAD_DIR/thp_zsmalloc" "$WORK/thp_zsmalloc"

# 驱动 import 的 zs_*_oplus 由设备上的 oplus_bsp_zsmalloc.ko 导出，不在 vmlinux 里，
# 所以 modpost 需要额外喂一份符号表；CRC 取自设备原厂 KO 的 __versions。
SYMVERS="$WORK/hybridswap_zram/Module.symvers.zsmalloc"
[ -f "$SYMVERS" ] || fail "缺少 ${SYMVERS}"

echo "== 编译 LZ4KDS 驱动 =="
make -C "$WORK/hybridswap_zram" \
	KSRC="$KSRC" KOUT="$KSRC/out" ZSMALLOC_SYMVERS="$SYMVERS" \
	-j"$(nproc --all)" 2>&1 | tail -40
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "驱动编译失败"

KO="$WORK/hybridswap_zram/oplus_bsp_hybridswap_zram.ko"
[ -f "$KO" ] || fail "没有产出 ${KO}"

echo "== 产物校验 =="
for algo in lz4k lz4kd lz4kds; do
	strings "$KO" | grep -qx "$algo" || fail "产物里找不到压缩后端 ${algo}"
done
echo "  后端齐全：lz4k / lz4kd / lz4kds"
echo "  vermagic: $(modinfo -F vermagic "$KO" 2>/dev/null || echo '(modinfo 不可用)')"
echo "  size    : $(stat -c%s "$KO") bytes"
if grep -q '^depends:' "$KO.mod.c" 2>/dev/null; then :; fi
modinfo -F depends "$KO" 2>/dev/null || true

mkdir -p "$OUTDIR"
cp "$KO" "$OUTDIR/oplus_bsp_hybridswap_zram.ko"
echo "已输出：${OUTDIR}/oplus_bsp_hybridswap_zram.ko"
