#!/system/bin/sh
# early-init 已经在 /data 挂载前完成了 KO 接管，这里不再改任何 zram 参数。
# 保留这个入口只为把 early.log 从 /metadata 复制一份到模块目录，方便查看。
MOD=${MODPATH:-/data/adb/modules/lz4kds}

for d in /metadata/vold/ksu/lz4kds /metadata/watchdog/ksu/lz4kds /metadata/ksu/lz4kds; do
	[ -d "$d" ] || continue
	for f in early.log early.previous.log; do
		[ -f "$d/$f" ] && cp -f "$d/$f" "$MOD/$f" 2>/dev/null
	done
	break
done
exit 0
