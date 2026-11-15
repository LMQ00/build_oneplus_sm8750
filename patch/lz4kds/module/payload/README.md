# 模块的文件构成

| 文件 | 说明 |
|---|---|
| `initrc/early.rc` | 让 init 在 early-init 阶段执行 `early.sh` |
| `early.sh` | 把 KO bind mount 到 `/vendor_dlkm/lib/modules/`，`insmod` 它，抢在厂商 modprobe 之前 |
| `post-fs-data.sh` | 把 early-init 日志从 `/metadata` 复制到模块目录 |
| `service.sh` | 开机 30 秒后核对驱动、算法、容量；接管失败就停用模块 |
| `zram.sh` | 看状态、改下次开机的算法与容量 |
| `payload/oplus_bsp_hybridswap_zram.ko` | 带 LZ4KDS + SDDC 的 zram 驱动 |
| `payload/ko_params` | `insmod` 参数，`zram.sh` 改的就是它 |
| `payload/driver.conf` | 安装时的初始参数，装机后以 `/metadata` 上的 `ko_params` 为准 |
| `stock_driver` | 存在时开机不接管，`zram.sh stock` 建它、`zram.sh ours` 删它 |

## ko_params

| 键 | 取值 | 说明 |
|---|---|---|
| `ALGO` | `lz4kds` / `lz4kd` / `off` | `lz4kds` 带 SDDC 相似页压缩，`lz4kd` 不带，`off` 用厂商默认 |
| `SIZE_MB` | MiB | zram0 容量 |

实际生效的位置是 `/metadata/watchdog/ksu/lz4kds/ko_params`——early-init 阶段
`/data` 还没挂载，只能读那里。`sh zram.sh algo` / `size` 改的就是这个文件。

## 为什么要在 early-init 接管

厂商的 `oplus_bsp_hybridswap_zram` 由 modprobe 在开机后加载。如果它先加载了，
再 `rmmod` 换我们的驱动，它的 `cleanup_module` 不会注销自己注册的 27 个
`android_vh` 探针与 16 个 `cgroup cftype`，回调地址会指向已释放的代码段，
开机过程中一触发 `mem_cgroup_alloc` 就跳进野指针，卡第一屏。

在 early-init 阶段用 bind mount 换掉 KO 文件再 `insmod`，厂商那版从头到尾没有
加载过，也就不存在这个问题。厂商 modprobe 随后看到同名模块已在运行，跳过。
