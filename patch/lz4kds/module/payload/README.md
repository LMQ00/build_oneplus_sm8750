# 模块的文件构成

| 文件 | 说明 |
|---|---|
| `initrc/early.rc` | 让 init 在 early-init 阶段执行 `early.sh`，路径由 `customize.sh` 按实际目录写入 |
| `early.sh` | 覆盖 `/vendor_dlkm/lib/modules/` 上的厂商 KO，先装 `oplus_bsp_zsmalloc`，再 `insmod` 自带 KO |
| `post-fs-data.sh` | 把 early-init 日志从 `/metadata` 复制到模块目录 |
| `service.sh` | 开机 40 秒后核对驱动、算法、容量；接管失败就停用模块 |
| `zram.sh` | 看状态、改下次开机的算法与容量 |
| `payload/oplus_bsp_hybridswap_zram.ko` | 带 LZ4KDS + SDDC 的 zram 驱动 |
| `payload/ko_params` | `insmod` 参数，`zram.sh` 改的就是它 |

## ko_params

| 键 | 取值 | 说明 |
|---|---|---|
| `ALGO` | `lz4kds` / `lz4kd` / `off` | `lz4kds` 带 SDDC 相似页压缩，`lz4kd` 不带，`off` 用厂商默认 |
| `SIZE_MB` | MiB | zram0 容量，512 - 65536 |
| `STOCK` | `0` / `1` | `1` 时开机不接管，`zram.sh stock` 写它、`zram.sh ours` 清零 |

early-init 阶段 `/data` 还没挂载，所以这份文件在 ksud 的 early-init 目录下，
路径随 uapi 版本变：uapi 6 起是 `/metadata/vold/ksu/lz4kds/`，更早是
`/metadata/watchdog/ksu/lz4kds/`。`sh zram.sh algo` / `size` / `stock` 找的就是它。

## 依赖

`payload/oplus_bsp_hybridswap_zram.ko` 的 `depends` 是 `oplus_bsp_zsmalloc`，
用它导出的 11 个 `zs_*_oplus` 符号。`insmod` 不解析依赖，所以 `early.sh` 在装
驱动之前先把 `/vendor_dlkm/lib/modules/oplus_bsp_zsmalloc.ko` 装上。

## 接管顺序

`early.sh` 先把自带 KO bind mount 到
`/vendor_dlkm/lib/modules/oplus_bsp_hybridswap_zram.ko`，再自己 `insmod` 并传入
`zram_size_mb` / `zram_algo`。

厂商 `vendor.modprobe` 在同一个 `on early-init` 里异步启动，三种先后都有对应处理：

| 谁先 | 结果 |
|---|---|
| 我们 insmod 成功 | 参数随模块加载生效 |
| 厂商先跑，读的是覆盖过的文件 | 装起来的是自带 KO；`early.sh` 写 `zram_size_mb` 与 `comp_algorithm` 补参数 |
| 厂商先跑，用的是原厂驱动 | 判据 `parameters/zram_algo` 不存在，写 `disable_pending`，`service.sh` 停用模块 |

判断当前跑的是哪一份，看 `/sys/module/oplus_bsp_hybridswap_zram/parameters/zram_algo`
在不在——只有自带 KO 有这个参数。

## 日志

`early.sh` 把全过程写到 early-init 目录下的 `early.log`，上一次的留在
`early.previous.log`。`sh zram.sh log` 直接读它。
