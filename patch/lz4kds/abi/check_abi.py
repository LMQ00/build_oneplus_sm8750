#!/usr/bin/env python3
"""刷机前 ABI 预检：把本次构建的导出 CRC 与设备原厂 KO 记录的 CRC 逐条比对。

用法：
    python3 check_abi.py --our-symvers out/vmlinux.symvers \
                         --reference   device_crc_reference.tsv

退出码：
    0  全部一致
    1  存在差异（逐条打印）
    2  输入文件缺失 / 格式错误
"""
import argparse
import sys


def parse_symvers(path):
    """解析 vmlinux.symvers：<crc>\\t<symbol>\\t<module>\\t<export type>"""
    out = {}
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                raise ValueError(f"{path}:{lineno} 不是 4 段 TSV：{line!r}")
            try:
                crc = int(parts[0], 16)
            except ValueError:
                raise ValueError(f"{path}:{lineno} CRC 不是十六进制：{parts[0]!r}")
            out[parts[1]] = crc
    return out


def parse_reference(path):
    """解析参考表：<crc(hex)>\\t<symbol>"""
    out = {}
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                raise ValueError(f"{path}:{lineno} 不是 2 段 TSV：{line!r}")
            out[parts[1]] = int(parts[0], 16)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--our-symvers", required=True, help="本次构建的 out/vmlinux.symvers")
    ap.add_argument("--reference", required=True, help="device_crc_reference.tsv")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    try:
        ours = parse_symvers(args.our_symvers)
        ref = parse_reference(args.reference)
    except (OSError, ValueError) as exc:
        print(f"::error::{exc}")
        return 2

    # 参考表只列「设备原厂 KO 引用过」的符号；我们的构建里必须每一条都在，且 CRC 相同。
    missing = [s for s in ref if s not in ours]
    mismatch = [(s, ref[s], ours[s]) for s in ref if s in ours and ours[s] != ref[s]]

    print(f"参考符号数 : {len(ref)}")
    print(f"本次导出数 : {len(ours)}")
    print(f"缺失       : {len(missing)}")
    print(f"CRC 不一致 : {len(mismatch)}")

    if missing:
        # 缺符号不一定是错误：CONFIG_TRIM_UNUSED_KSYMS / 不同的裁剪策略会去掉未引用的导出。
        # 但对「设备原厂 KO 真的引用过」的符号来说，缺失就意味着该模块加载不了。
        for s in missing:
            print(f"  MISSING   {s}")

    for s, dev_crc, our_crc in mismatch:
        print(f"  MISMATCH  {s}  device=0x{dev_crc:08x}  ours=0x{our_crc:08x}")

    if args.verbose:
        for s in sorted(ref):
            if s in ours and ours[s] == ref[s]:
                print(f"  OK        {s}  0x{ours[s]:08x}")

    if mismatch:
        print("::error::存在 CRC 不一致，构建产物与设备 ABI 不等价，不得刷入")
        return 1

    if missing:
        print("::warning::有参考符号缺失（可能来自 ksym 裁剪策略差异）")

    print("ABI 预检通过：所有参考符号 CRC 逐条一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
