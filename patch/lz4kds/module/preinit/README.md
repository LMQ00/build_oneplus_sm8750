# preinit 目录

构建时由 Actions 把两个 `.ko` 放进本目录，KernelSU 的 preinit 会在
SELinux 策略加载之前依次 `insmod`：

1. `oplus_bsp_zsmalloc.ko` —— 取自设备原厂（`/vendor/lib/modules/`）。
   RMX5010 的这份在各机型间字节一致（md5 `89a25c48a1d44c0b0859ca986c573d93`），
   提供驱动需要的 `zs_*_oplus` 导出。
2. `oplus_bsp_hybridswap_zram.ko` —— 本仓库 Actions 用 6.6.118 源码编出的
   LZ4KDS 版本，`depends: oplus_bsp_zsmalloc`。

**顺序不能反**：驱动在 modprobe 阶段就要解析 `zs_*_oplus`。

`preinit.conf` 会被 `zram.sh` 改写，改完要 `ksud initrc refresh` 才会同步到
`/metadata/vold/ksu/preinit/lz4kds/preinit.conf`（preinit 实际读的是后者）。
