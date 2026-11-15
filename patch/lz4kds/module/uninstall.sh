#!/system/bin/sh
# 卸载时清掉 early-init 用的副本与日志。
STAGE=/metadata/watchdog/ksu/lz4kds
MOD=${MODPATH:-/data/adb/modules/lz4kds}
rm -rf "$STAGE"
rm -f "$MOD/driver.log" "$MOD/selftest.log" "$MOD/early.log" "$MOD/early.previous.log"
/data/adb/ksud initrc refresh 2>/dev/null || true
