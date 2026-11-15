#!/system/bin/sh
# 卸载时清掉 early-init 用的副本与日志。
STAGE=/metadata/watchdog/ksu/lz4kds
rm -rf "$STAGE"
rm -f /data/adb/modules/lz4kds/driver.log /data/adb/modules/lz4kds/selftest.log
/data/adb/ksud initrc refresh 2>/dev/null || true
