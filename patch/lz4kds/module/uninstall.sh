#!/system/bin/sh
# 卸载时清掉 early-init 用的副本与日志。
MOD=${MODPATH:-/data/adb/modules/lz4kds}
for d in /metadata/vold/ksu/lz4kds /metadata/watchdog/ksu/lz4kds /metadata/ksu/lz4kds; do
	rm -rf "$d"
done
rm -f "$MOD/selftest.log" "$MOD/early.log" "$MOD/early.previous.log"
/data/adb/ksud initrc refresh 2>/dev/null || true
