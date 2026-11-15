#!/system/bin/sh
# early-init 已经在 /data 挂载前完成了 KO 接管，这里不再改任何 zram 参数。
# 保留这个入口只为把 early.log 从 /metadata 复制一份到模块目录，方便查看。
STAGE=/metadata/watchdog/ksu/lz4kds
MOD=${MODPATH:-/data/adb/modules/lz4kds}
for f in early.log early.previous.log; do
	[ -f "$STAGE/$f" ] && cp -f "$STAGE/$f" "$MOD/$f" 2>/dev/null
done
exit 0
