#!/bin/bash
# 把构建出来的 KO 打进一个可直接刷入的 KernelSU 模块 zip。
#
# 用法：package_ksu_module.sh <产物目录> <输出目录>
#
# <产物目录> 需要包含：
#   oplus_bsp_hybridswap_zram.ko   本次构建的 LZ4KDS 驱动
#   oplus_bsp_zsmalloc.ko          从设备原厂取的同版本 zsmalloc（或留空则跳过）
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
cp "$KO" "$STAGE/preinit/oplus_bsp_hybridswap_zram.ko"
echo "  + preinit/oplus_bsp_hybridswap_zram.ko ($(stat -c%s "$KO") bytes)"

# zsmalloc：**不打进 zip**。它是厂商二进制，许可证与版本都不该由本仓库分发；
# 由 customize.sh 在设备上从 /vendor/lib/modules/ 直接复制，天然与设备内核一致。
ZSM="$ART/oplus_bsp_zsmalloc.ko"
if [ -f "$ZSM" ]; then
	echo "  检测到 oplus_bsp_zsmalloc.ko（不打包，安装时从设备复制）"
else
	echo "  未提供 oplus_bsp_zsmalloc.ko（预期如此，安装时从设备复制）"
fi
rm -f "$STAGE/preinit/oplus_bsp_zsmalloc.ko"

# 清掉构建残留
find "$STAGE" -name '*.o' -o -name '*.cmd' -o -name 'Module.symvers*' | xargs -r rm -f

chmod 0755 "$STAGE"/customize.sh "$STAGE"/service.sh "$STAGE"/zram.sh 2>/dev/null || true
chmod 0644 "$STAGE"/module.prop "$STAGE"/preinit/preinit.conf 2>/dev/null || true

ZIP="$OUT/lz4kds-ksu-6.6.118.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -qr "$ZIP" .)
echo "已打包：${ZIP} ($(stat -c%s "$ZIP") bytes)"
unzip -l "$ZIP" | tail -20
