#!/bin/bash
# 把构建出来的 KO 打进一个可直接刷入的 KernelSU 模块 zip。
#
# 用法：package_ksu_module.sh <产物目录> <输出目录>
#
# <产物目录> 需要包含：
#   oplus_bsp_hybridswap_zram.ko   本次构建的 LZ4KDS 驱动
set -euo pipefail

ART="${1:?用法: package_ksu_module.sh <产物目录> <输出目录>}"
OUT="${2:?用法: package_ksu_module.sh <产物目录> <输出目录>}"
MODSRC="$(cd "$(dirname "$0")/.." && pwd)/module"

fail() {
	echo "::error::$*"
	exit 1
}

[ -d "$MODSRC" ] || fail "缺少模块模板 ${MODSRC}"
KO="$ART/oplus_bsp_hybridswap_zram.ko"
[ -f "$KO" ] || fail "缺少驱动产物 ${KO}"

STAGE="$OUT/lz4kds"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -r "$MODSRC"/. "$STAGE"/

# 驱动
cp "$KO" "$STAGE/payload/oplus_bsp_hybridswap_zram.ko"
echo "  + payload/oplus_bsp_hybridswap_zram.ko ($(stat -c%s "$KO") bytes)"

# zsmalloc 由厂商模块提供，本模块不携带也不替换它。
rm -f "$STAGE/payload/oplus_bsp_zsmalloc.ko"

# 清掉构建残留
find "$STAGE" -name '*.o' -o -name '*.cmd' -o -name 'Module.symvers*' | xargs -r rm -f

chmod 0755 "$STAGE"/customize.sh "$STAGE"/service.sh "$STAGE"/zram.sh "$STAGE"/post-fs-data.sh "$STAGE"/uninstall.sh 2>/dev/null || true
chmod 0644 "$STAGE"/module.prop "$STAGE"/payload/driver.conf 2>/dev/null || true

ZIP="$OUT/lz4kds-ksu-6.6.118.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -qr "$ZIP" .)
echo "已打包：${ZIP} ($(stat -c%s "$ZIP") bytes)"
unzip -l "$ZIP" | tail -20
