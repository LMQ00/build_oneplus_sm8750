#!/system/bin/sh
# KernelSU 模块安装脚本。只做权限设置与「从设备自身取 zsmalloc」，
# 不写任何分区。
ui_print "- LZ4KDS 内存压缩（RMX5010 / 6.6.118 专用）"
ui_print "- 算法来源: Crystal HybridSwap (SDDC) / HiSilicon (LZ4KD)"
ui_print "- 驱动骨架: OPPO/realme oplus_bsp_hybridswap_zram"
ui_print "- CRC 已按设备 6.6.118 原厂 ko 对齐"
ui_print "- 修改配置: sh /data/adb/modules/lz4kds/zram.sh 16384 lz4kds"

# preinit 需要与设备完全同版本的 zsmalloc。本模块不携带该厂商二进制，
# 安装时直接从当前系统里复制，保证与设备内核版本严格一致。
ZSM_SRC=""
for p in /vendor/lib/modules/oplus_bsp_zsmalloc.ko \
         /vendor_dlkm/lib/modules/oplus_bsp_zsmalloc.ko \
         /system/lib/modules/oplus_bsp_zsmalloc.ko; do
	if [ -f "$p" ]; then
		ZSM_SRC="$p"
		break
	fi
done

if [ -n "$ZSM_SRC" ]; then
	cp -f "$ZSM_SRC" "$MODPATH/preinit/oplus_bsp_zsmalloc.ko"
	ui_print "- 已复制设备原厂 zsmalloc: $ZSM_SRC"
else
	ui_print "!! 未在系统中找到 oplus_bsp_zsmalloc.ko"
	ui_print "!! 请手动把它放到 $MODPATH/preinit/ 后再重启"
fi

# 驱动必须存在，否则模块无意义
if [ ! -f "$MODPATH/preinit/oplus_bsp_hybridswap_zram.ko" ]; then
	ui_print "!! 缺少 oplus_bsp_hybridswap_zram.ko，模块不完整"
fi

set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/zram.sh 0 0 0755
set_perm $MODPATH/webroot/webui.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755

ui_print "- 安装完成，重启后生效"
