#!/bin/bash
# 把模块模板打成可直接刷入的 KernelSU 模块 zip。
#
# 用法：package_ksu_module.sh <输出目录> <KO 目录>
#
# KO 目录里需要有 oplus_bsp_hybridswap_zram.ko（带 LZ4KDS + SDDC 的驱动）。
set -euo pipefail

OUT="${1:?用法: package_ksu_module.sh <输出目录> <KO 目录>}"
KODIR="${2:?用法: package_ksu_module.sh <输出目录> <KO 目录>}"
MODSRC="$(cd "$(dirname "$0")/.." && pwd)/module"

fail() {
	echo "::error::$*"
	exit 1
}

[ -d "$MODSRC" ] || fail "缺少模块模板 ${MODSRC}"
[ -f "$KODIR/oplus_bsp_hybridswap_zram.ko" ] || fail "${KODIR} 里没有 oplus_bsp_hybridswap_zram.ko"

STAGE="$OUT/lz4kds"
rm -rf "$STAGE"
mkdir -p "$STAGE/payload"
cp -r "$MODSRC"/. "$STAGE"/

# 清掉构建残留与上机留下的文件
find "$STAGE" \( -name '*.o' -o -name '*.cmd' -o -name 'Module.symvers*' -o -name '*.ko' \) \
	-print0 2>/dev/null | xargs -0 -r rm -f
rm -f "$STAGE"/selftest.log "$STAGE"/early.log "$STAGE"/early.previous.log

cp "$KODIR/oplus_bsp_hybridswap_zram.ko" "$STAGE/payload/oplus_bsp_hybridswap_zram.ko"

chmod 0755 "$STAGE"/customize.sh "$STAGE"/service.sh "$STAGE"/zram.sh \
	"$STAGE"/post-fs-data.sh "$STAGE"/early.sh "$STAGE"/uninstall.sh \
	"$STAGE"/webroot/webui.sh 2>/dev/null || true
chmod 0644 "$STAGE"/module.prop "$STAGE"/payload/ko_params \
	"$STAGE"/payload/oplus_bsp_hybridswap_zram.ko "$STAGE"/payload/README.md \
	"$STAGE"/initrc/early.rc "$STAGE"/webroot/index.html 2>/dev/null || true

ZIP="$OUT/lz4kds-ksu-6.6.118.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -qr "$ZIP" .)
echo "已打包：${ZIP} ($(stat -c%s "$ZIP") bytes)"
unzip -l "$ZIP" | tail -20
