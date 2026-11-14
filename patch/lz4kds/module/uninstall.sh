#!/system/bin/sh
# 卸载后厂商驱动会在下次开机由 init 正常加载，这里只需要清掉跨版本残留的
# KernelSU preinit 副本与日志。
rm -rf /metadata/vold/ksu/preinit/lz4kds
rm -f /data/adb/modules/lz4kds/hotswap.log /data/adb/modules/lz4kds/selftest.log
