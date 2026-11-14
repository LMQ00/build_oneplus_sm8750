# 刷机前 ABI 预检

目的：在把内核 / 模块刷进设备之前，用一个不依赖设备的离线检查，确认
**这次构建出来的内核与设备原厂内核在 ABI 上是否等价**。不等价就说明模块会在
`insmod` 时被 modpost 校验拒绝（`disagrees about version of symbol`），
连内核本身都可能起不来。

## 涉及两组符号

| 方向 | 谁导出 | 谁校验 | 参考表 |
|---|---|---|---|
| 内核 → 驱动 | 自建内核 vmlinux | 我们的 KO 与厂商 KO | `device_crc_reference.tsv` |
| 驱动 → 厂商模块 | 我们的 KO | `oplus_bsp_fg_protect` 等三个厂商模块 | `exported_symbol_crc.tsv` |

`CONFIG_MODVERSIONS=y` 时，每个被 import 的符号都带一个 4 字节 CRC，存放在
模块的 `__versions` 段里。内核在 `check_version()` 里逐条比对：
- CRC 不一致 → 拒绝加载；
- 符号在 `__versions` 里没有条目 → 只警告（`no symbol version for %s`）。

## 数据来源

| 文件 | 来源 | 作用 |
|---|---|---|
| `device_crc_reference.tsv` | 设备 `/vendor_dlkm/lib/modules/oplus_bsp_hybridswap_zram.ko` 与 `oplus_bsp_zsmalloc.ko` 的 `__versions` 段 | 设备内核导出的 CRC |
| `exported_symbol_crc.tsv` | 设备 `oplus_bsp_hybridswap_zram.ko` 的 `__kcrctab_gpl` 段 | 我们的 KO 要导出的 5 个符号的 CRC |
| `Module.symvers.zsmalloc` | 设备原厂 `oplus_bsp_zsmalloc.ko` 的 `__versions` 里、由该模块导出的 11 个 `zs_*_oplus` | out-of-tree 驱动的 modpost 输入 |
| 本次构建的 `out/vmlinux.symvers` | `make Image` 产出 | 我们的内核导出的 CRC |

`device_crc_reference.tsv` 共 304 条，是「设备原厂 KO 引用了、且由 vmlinux 提供」
的全部符号。

## 驱动导出的符号为什么需要对齐

原厂 `oplus_bsp_hybridswap_zram.ko` 出自 realme 的 OEM 变体树（vermagic
`6.6.118-android15-8-o-4k`），本仓库用 GKI 树（`6.6.118-android15-8-g...-4k`）。
genksyms 递归展开签名里的每个类型定义来算 CRC，两棵树在 `struct mem_cgroup`
的嵌套类型上不同，同一个函数签名就会算出不同的值。

两边生成的代码是等价的：`get_mem_cgroup_app_uid` 与 `get_mem_cgroup_app_name`
的机器码逐条指令相同，都按 `[x0 + 0x8f0]` 取 `MEMCGRP_ITEM_DATA`。所以差异只在
CRC 数值，不在 ABI。

`fix_export_crc.py` 在 `build_driver.sh` 里把 `exported_symbol_crc.tsv` 的值写回
KO 的 `__kcrctab_gpl` 段，让三个引用方通过 `check_version()`。

## 怎么跑

```sh
# 1) 构建内核（产出 out/vmlinux.symvers）
# 2) 内核侧比对
python3 patch/lz4kds/abi/check_abi.py \
    --our-symvers out/vmlinux.symvers \
    --reference   patch/lz4kds/abi/device_crc_reference.tsv

# 3) 驱动侧对齐（build_driver.sh 会自动调用）
python3 patch/lz4kds/scripts/fix_export_crc.py \
    <ko> patch/lz4kds/abi/exported_symbol_crc.tsv
```

`check_abi.py` 退出码 0 = 全部一致；非 0 = 有差异，脚本会逐条打印
`symbol device=0x... ours=0x...`。

`fix_export_crc.py` 退出码 0 = 全部一致；加 `--check` 只检查不写回。

## vermagic

设备是 `6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k`，自建内核同前缀。
`kernel/module/version.c` 的 `same_magic()` 在 `CONFIG_MODVERSIONS=y` 时跳过第一个
空格分隔的 token，release 段因此不参与比较。
