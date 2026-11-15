#!/system/bin/sh
# KernelSU 模块安装脚本。只设置权限，不写任何分区。

ui_print "- LZ4KDS 内存压缩（RMX5010 / 6.6.118 专用）"
ui_print "- 算法来源: Crystal HybridSwap (SDDC) / HiSilicon (LZ4KD)"
ui_print "- 驱动骨架: OPPO/realme oplus_bsp_hybridswap_zram"
ui_print "- 改容量与算法: sh /data/adb/modules/lz4kds/zram.sh 16384 lz4kd"
ui_print "- 查看当前状态: sh /data/adb/modules/lz4kds/zram.sh show"

if [ ! -f "$MODPATH/payload/oplus_bsp_hybridswap_zram.ko" ]; then
	ui_print "!! 缺少 oplus_bsp_hybridswap_zram.ko，模块不完整"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/zram.sh" 0 0 0755
set_perm "$MODPATH/webroot/webui.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

ui_print "- 安装完成，重启后生效"
