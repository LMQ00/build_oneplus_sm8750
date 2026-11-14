# payload 目录

| 文件 | 来源 |
|---|---|
| `oplus_bsp_hybridswap_zram.ko` | 本仓库 `build_driver.sh` 的产物 |
| `driver.conf` | 驱动参数，由 `zram.sh` 改写 |

`post-fs-data.sh` 读 `driver.conf` 里 insmod 那一行，把后面的参数原样传给 insmod。
zsmalloc 由厂商模块 `/vendor_dlkm/lib/modules/oplus_bsp_zsmalloc.ko` 提供，本模块不携带也不替换它。
