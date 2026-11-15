# 模块的文件构成

| 文件 | 说明 |
|---|---|
| `post-fs-data.sh` | KernelSU 在 post-fs-data 阶段调用，把 `/sys/block/zram0/comp_algorithm` 写成 `algo` |
| `service.sh` | 开机完成后核对算法；被别的脚本改掉就改回来 |
| `zram.sh` | 手动改容量、算法，查看状态 |
| `driver.conf` | 本目录下的配置，见下表 |
| `driver.log` / `selftest.log` | 运行日志 |
| `stock_driver` | 存在时开机不干预，`zram.sh stock` 建它、`zram.sh ours` 删它 |

## driver.conf

| 键 | 取值 | 说明 |
|---|---|---|
| `algo` | 算法名 / `off` | 写进 `comp_algorithm` 的值；`off` 表示不干预 |

`algo` 必须在 `cat /sys/block/zram0/comp_algorithm` 报出来的列表里。
`lz4kd` 与 `lz4k` 由内核编译时决定，需要刷本仓库的 Image。
