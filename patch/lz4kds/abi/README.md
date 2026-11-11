# 刷机前 ABI 预检

目的：在把内核 / 模块刷进设备之前，用一个不依赖设备的离线检查，确认
**这次构建出来的内核与设备原厂内核在 ABI 上是否等价**。不等价就说明模块会在
`insmod` 时被 modpost 校验拒绝（`disagrees about version of symbol`），
连内核本身都可能起不来。

## 检查什么

`CONFIG_MODVERSIONS=y` 时，每个被 import 的符号都带一个 8 字节 CRC，存放在
模块的 `__versions` 段里。内核在 `check_version()` 里逐条比对：
- CRC 不一致 → 拒绝加载；
- 符号在 `__versions` 里没有条目 → 只警告（`no symbol version for %s`）。

所以判定只用一句话：**我们的内核导出的 CRC，必须与设备内核导出的 CRC 逐条相同。**

## 数据来源

| 文件 | 来源 | 作用 |
|---|---|---|
| `device_crc_reference.tsv` | 设备 `/vendor/lib/modules/oplus_bsp_hybridswap_zram.ko` 与 `oplus_bsp_zsmalloc.ko` 的 `__versions` 段 | 设备内核导出的 CRC 的**直接证据** |
| `Module.symvers.zsmalloc` | 设备原厂 `oplus_bsp_zsmalloc.ko` 的 `__versions` 里、由该模块导出的 11 个 `zs_*_oplus` | out-of-tree 驱动的 modpost 输入 |
| 本次构建的 `out/vmlinux.symvers` | `make Image` 产出 | 我们的内核导出的 CRC |

`device_crc_reference.tsv` 共 304 条，是「设备原厂 KO 引用了、且由 vmlinux 提供」
的全部符号；这 304 条覆盖了 zram / zsmalloc 相关的整片 ABI 面。

## 怎么跑

```sh
# 1) 构建内核（产出 out/vmlinux.symvers）
# 2) 比对
python3 patch/lz4kds/abi/check_abi.py \
    --our-symvers out/vmlinux.symvers \
    --reference   patch/lz4kds/abi/device_crc_reference.tsv
```

退出码 0 = 全部一致；非 0 = 有差异，脚本会逐条打印
`symbol device=0x... ours=0x...`。

## 已知的、不影响加载的差异

- **vermagic 的 release 段**：设备是 `6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k`，
  自建内核是 `6.6.118-...`。`kernel/module/version.c:79` 的 `same_magic()` 在
  `CONFIG_MODVERSIONS=y` 时会跳过第一个空格分隔的 token，因此这不影响加载。
- **`CONFIG_TRIM_UNUSED_KSYMS`**：设备 `=y`、自建 `=n`。已实测它不影响任何导出 CRC
  （304/304 全等即为证据），只影响 vmlinux 里保留多少个 ksymtab 条目。
- **设备专有导出**：`CONFIG_TRIM_UNUSED_KSYMS` + 厂商模块导出的符号（如
  `panel_event_notifier_register`、`test_task_ux`）不在纯 GKI 构建里。
  它们只影响**引用它们的模块**，不影响内核能否启动；本仓库的驱动不引用它们。
