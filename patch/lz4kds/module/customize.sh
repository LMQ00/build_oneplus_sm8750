#!/system/bin/sh
# KernelSU 模块安装脚本。只设置权限，不写任何分区。

ui_print "- LZ4KDS 内存压缩（RMX5010 / 6.6.118 专用）"
ui_print "- 算法来源: HiSilicon LZ4KDS + Crystal SDDC，由本模块自带的 KO 提供"
ui_print "- 查看状态: cat /metadata/watchdog/ksu/lz4kds/early.log"

if [ ! -d /metadata/watchdog/ksu ]; then
	abort "KernelSU 的 early-init 目录不存在，模块无法接管驱动"
fi

if [ ! -f "$MODPATH/payload/oplus_bsp_hybridswap_zram.ko" ]; then
	abort "模块包里没有 KO"
fi

# early-init 阶段 /data 还没挂载，脚本与 KO 要放一份到 /metadata。
STAGE=/metadata/watchdog/ksu/lz4kds
rm -rf "$STAGE"
mkdir -p "$STAGE" || abort "无法创建 $STAGE"
cp -f "$MODPATH/early.sh" "$STAGE/early.sh" || abort "无法复制 early.sh"
cp -f "$MODPATH/payload/oplus_bsp_hybridswap_zram.ko" "$STAGE/oplus_bsp_hybridswap_zram.ko" || abort "无法复制 KO"
cp -f "$MODPATH/payload/ko_params" "$STAGE/ko_params" || abort "无法复制 ko_params"

chmod 0700 "$STAGE" "$STAGE/early.sh"
chmod 0600 "$STAGE/oplus_bsp_hybridswap_zram.ko" "$STAGE/ko_params"
chcon u:object_r:system_file:s0 "$STAGE" "$STAGE/early.sh" \
	"$STAGE/oplus_bsp_hybridswap_zram.ko" "$STAGE/ko_params" 2>/dev/null || true

# KO 的标签要跟被覆盖的那个文件一致，厂商 modprobe 才读得到。
LABEL=$(stat -c %C /vendor_dlkm/lib/modules/oplus_bsp_hybridswap_zram.ko 2>/dev/null)
if [ -n "$LABEL" ]; then
	chcon "$LABEL" "$STAGE/oplus_bsp_hybridswap_zram.ko" 2>/dev/null || true
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in customize.sh post-fs-data.sh service.sh early.sh zram.sh uninstall.sh webroot/webui.sh; do
	[ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done

# initrc 是新加的，装完之后要让 ksud 重新生成 modules.rc。
/data/adb/ksud initrc refresh 2>/dev/null || ui_print "!! initrc refresh 失败，重启前请手动执行"

ui_print "- 安装完成，重启后生效"
