# 模块的文件构成

| 文件 | 说明 |
|---|---|
| `post-fs-data.sh` | KernelSU 在 post-fs-data 阶段调用。把 `/odm/etc/oplus_mm_config.xml` 里每个 `<zram0>` 段补上 `comp_algorithm`，再 bind mount 回原路径 |
| `service.sh` | 开机 30 秒后核对算法与容量；厂商没按配置设就热切换过来 |
| `zram.sh` | 改容量、算法，查看状态 |
| `driver.conf` | 本目录下的配置，见下表 |
| `oplus_mm_config.orig.xml` | 开机时从 `/odm/etc/oplus_mm_config.xml` 复制来的原文件 |
| `oplus_mm_config.xml` | 补上 `comp_algorithm` 的版本，挂到 `/odm/etc/oplus_mm_config.xml` |
| `driver.log` / `selftest.log` | 运行日志 |
| `stock_driver` | 存在时开机不干预，`zram.sh stock` 建它、`zram.sh ours` 删它 |

## driver.conf

| 键 | 取值 | 说明 |
|---|---|---|
| `algo` | 算法名 / `off` | 厂商脚本写进 `comp_algorithm` 的值；`off` 表示不干预 |
| `size` | MiB / `auto` | 开机时的 zram0 容量；`auto` 表示沿用厂商策略 |

`algo` 要在 `/proc/crypto` 里有对应条目。`lz4kd` 与 `lz4k` 由内核编译时决定，
需要刷本仓库编译的 Image。