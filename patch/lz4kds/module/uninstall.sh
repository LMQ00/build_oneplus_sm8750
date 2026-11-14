#!/system/bin/sh
# 卸载后厂商驱动在下次开机由 init 正常加载，这里清掉本模块留下的日志。
rm -f /data/adb/modules/lz4kds/driver.log /data/adb/modules/lz4kds/selftest.log
