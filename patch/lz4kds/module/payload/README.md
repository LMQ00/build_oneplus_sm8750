# payload 目录

| 文件 | 说明 |
|---|---|
| `oplus_bsp_hybridswap_zram.ko` | 本仓库 `build_driver.sh` 的产物，`mode=replace` 时装它 |
| `driver.conf` | 算法、模式与 insmod 参数，由 `zram.sh` 改写 |

`driver.conf` 的三个键：

| 键 | 取值 | 作用 |
|---|---|---|
| `algo` | `lz4kd` `lz4kds` `lzo-rle` 等 | `post-fs-data.sh` 写进 `/sys/block/zram0/comp_algorithm` |
| `mode` | `algo` / `replace` | `algo` 不装卸模块；`replace` 换成上面那个 KO |
| `insmod ...` | 驱动参数 | 只在 `replace` 模式下生效 |

zsmalloc 由厂商模块 `/vendor_dlkm/lib/modules/oplus_bsp_zsmalloc.ko` 提供，本模块不携带也不替换它。
