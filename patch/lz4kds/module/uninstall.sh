#!/system/bin/sh
# 卸载时把挂到 /odm 上的那份 XML 摘掉，省得留到下次重启。
SRC=/odm/etc/oplus_mm_config.xml
if grep -q " $SRC " /proc/self/mountinfo 2>/dev/null; then
	umount "$SRC" 2>/dev/null
fi
rm -f /data/adb/modules/lz4kds/driver.log /data/adb/modules/lz4kds/selftest.log
