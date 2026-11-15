#!/bin/bash
# 把模块模板打成可直接刷入的 KernelSU 模块 zip。
#
# 用法：package_ksu_module.sh <输出目录>
#
# 模块不携带任何 .ko：zram 由厂商模块提供，本模块只改 comp_algorithm。
set -euo pipefail

OUT="${1:?用法: package_ksu_module.sh <输出目录>}"
MODSRC="$(cd "$(dirname "$0")/.." && pwd)/module"

fail() {
	echo "::error::$*"
	exit 1
}

[ -d "$MODSRC" ] || fail "缺少模块模板 ${MODSRC}"

STAGE="$OUT/lz4kds"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -r "$MODSRC"/. "$STAGE"/

# 清掉构建残留
find "$STAGE" \( -name '*.o' -o -name '*.cmd' -o -name 'Module.symvers*' -o -name '*.ko' \) \
	-print0 2>/dev/null | xargs -0 -r rm -f

chmod 0755 "$STAGE"/customize.sh "$STAGE"/service.sh "$STAGE"/zram.sh \
	"$STAGE"/post-fs-data.sh "$STAGE"/uninstall.sh "$STAGE"/webroot/webui.sh 2>/dev/null || true
chmod 0644 "$STAGE"/module.prop "$STAGE"/payload/driver.conf 2>/dev/null || true

ZIP="$OUT/lz4kds-ksu-6.6.118.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -qr "$ZIP" .)
echo "已打包：${ZIP} ($(stat -c%s "$ZIP") bytes)"
unzip -l "$ZIP" | tail -20
