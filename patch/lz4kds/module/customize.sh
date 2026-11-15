#!/system/bin/sh
# KernelSU 模块安装脚本。只设置权限，不写任何分区。

ui_print "- LZ4KD 内存压缩（RMX5010 / 6.6.118 专用）"
ui_print "- 算法来源: HiSilicon LZ4KD，由本仓库编译的 Image 提供"
ui_print "- 查看状态: sh /data/adb/modules/lz4kds/zram.sh"
ui_print "- 改容量与算法: sh /data/adb/modules/lz4kds/zram.sh 16384 lz4kd"

if [ ! -e /sys/module/oplus_bsp_hybridswap_zram ]; then
	ui_print "!! 没有 zram 驱动，模块不会生效"
fi

if [ ! -f /odm/etc/oplus_mm_config.xml ]; then
	ui_print "!! 没有 /odm/etc/oplus_mm_config.xml，模块不会生效"
fi

if ! grep -q '^name *: *lz4kd$' /proc/crypto 2>/dev/null; then
	ui_print "!! 内核里没有 lz4kd，需要刷本仓库编译的 Image"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/zram.sh" 0 0 0755
set_perm "$MODPATH/webroot/webui.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

ui_print "- 安装完成，重启后生效"
