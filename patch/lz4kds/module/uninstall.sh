#!/system/bin/sh
# 卸载时清掉 preinit 的 metadata 同步副本，避免下次开机仍加载侧载 KO。
rm -rf /metadata/vold/ksu/preinit/lz4kds
