#!/system/bin/sh
# KernelSU 模块安装脚本。只设置权限，不写任何分区。

ui_print "- LZ4KDS 内存压缩（RMX5010 / 6.6.118 专用）"
ui_print "- 算法来源: HiSilicon LZ4KDS + Crystal SDDC，由本模块自带的 KO 提供"

if [ ! -f "$MODPATH/payload/oplus_bsp_hybridswap_zram.ko" ]; then
	abort "模块包里没有 KO"
fi

if [ ! -f /vendor_dlkm/lib/modules/oplus_bsp_zsmalloc.ko ]; then
	abort "找不到 /vendor_dlkm/lib/modules/oplus_bsp_zsmalloc.ko，驱动装不上"
fi

# early-init 阶段 /data 还没挂载，脚本与 KO 要放一份到 /metadata。
# ksud 从 uapi 6 起用 /metadata/vold/ksu，更早的版本用 /metadata/watchdog/ksu，
# 内核按同样的顺序找 modules.rc，这里照抄。
BASE=""
for d in /metadata/vold/ksu /metadata/watchdog/ksu /metadata/ksu; do
	[ -d "$d" ] && { BASE=$d; break; }
done
if [ -z "$BASE" ]; then
	abort "找不到 KernelSU 的 early-init 目录，模块无法接管驱动"
fi

STAGE=$BASE/lz4kds
rm -rf "$STAGE"
mkdir -p "$STAGE" || abort "无法创建 $STAGE"
cp -f "$MODPATH/early.sh" "$STAGE/early.sh" || abort "无法复制 early.sh"
cp -f "$MODPATH/payload/oplus_bsp_hybridswap_zram.ko" "$STAGE/oplus_bsp_hybridswap_zram.ko" || abort "无法复制 KO"
cp -f "$MODPATH/payload/ko_params" "$STAGE/ko_params" || abort "无法复制 ko_params"

chmod 0700 "$STAGE" "$STAGE/early.sh"
chmod 0600 "$STAGE/oplus_bsp_hybridswap_zram.ko" "$STAGE/ko_params"
chcon u:object_r:system_file:s0 "$STAGE" "$STAGE/early.sh" \
	"$STAGE/oplus_bsp_hybridswap_zram.ko" "$STAGE/ko_params" 2>/dev/null || true

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in customize.sh post-fs-data.sh service.sh early.sh zram.sh uninstall.sh webroot/webui.sh; do
	[ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done

# init 只认绝对路径，把实际用到的那个目录写进 early.rc。
RC=$MODPATH/initrc/early.rc
if [ -f "$RC" ]; then
	printf 'on early-init\n    exec u:r:ksu:s0 root -- /system/bin/sh %s/early.sh\n' \
		"$STAGE" >"$RC" || ui_print "!! 无法写入 $RC"
	set_perm "$RC" 0 0 0644
fi

ui_print "- 脚本与 KO 已放到 $STAGE"
ui_print "- 查看日志: sh /data/adb/modules/lz4kds/zram.sh log"

# initrc 由 ksud 汇总成 modules.rc，装完要重新生成一次。
if ! /data/adb/ksud initrc refresh 2>/dev/null; then
	ui_print "!! initrc refresh 失败，重启前请手动执行 /data/adb/ksud initrc refresh"
fi

ui_print "- 安装完成，重启后生效"
