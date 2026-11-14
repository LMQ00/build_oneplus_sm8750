#!/usr/bin/env python3
"""把构建出的 KO 里 __kcrctab 段的 CRC 对齐到设备原厂 KO 的值。

用法：
    python3 fix_export_crc.py <ko> <reference.tsv>
    python3 fix_export_crc.py <ko> <reference.tsv> --check

reference.tsv 每行：<crc(hex)>\t<symbol>。

modpost 用 genksyms 递归展开签名算 CRC，展开结果取决于签名里出现的每个类型的
完整定义。原厂 oplus_bsp_hybridswap_zram.ko 出自 realme 的 OEM 变体内核树，与本
仓库使用的 GKI 树在这些嵌套类型上不同，同一个函数签名就会算出不同的值，即使双
方生成的机器码逐条指令一致。这里把原厂值写回 __kcrctab，让引用这些符号的厂商
模块能通过 check_version()。

退出码：
    0  全部一致
    1  有符号缺失或对齐后仍不一致
    2  输入文件缺失 / 格式错误
"""
import argparse
import struct
import sys

SHT_SYMTAB = 2


def read_sections(data):
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ, _flags, _addr, offset, size, link, _info, _align, _ent = (
            struct.unpack_from("<IIQQQQIIQQ", data, off)
        )
        sections.append(
            dict(idx=i, name_off=name, typ=typ, offset=offset, size=size, link=link)
        )

    strtab = sections[e_shstrndx]
    for sec in sections:
        start = strtab["offset"] + sec["name_off"]
        end = data.index(b"\0", start)
        sec["name"] = data[start:end].decode()

    return sections


def read_symbols(data, sections):
    out = []
    for sec in sections:
        if sec["typ"] != SHT_SYMTAB:
            continue
        strtab = sections[sec["link"]]
        for i in range(sec["size"] // 24):
            off = sec["offset"] + i * 24
            name_off, _info, _other, shndx, value, _size = struct.unpack_from(
                "<IBBHQQ", data, off
            )
            start = strtab["offset"] + name_off
            end = data.index(b"\0", start)
            out.append(dict(name=data[start:end].decode(), shndx=shndx, value=value))
    return out


def parse_reference(path):
    ref = {}
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                raise ValueError("%s:%d 不是 2 段 TSV：%r" % (path, lineno, line))
            try:
                ref[parts[1]] = int(parts[0], 16)
            except ValueError:
                raise ValueError("%s:%d CRC 不是十六进制：%r" % (path, lineno, parts[0]))
    return ref


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ko", help="构建出的 .ko")
    ap.add_argument("reference", help="原厂 CRC 参考表")
    ap.add_argument("--check", action="store_true", help="只检查，不写回")
    args = ap.parse_args()

    try:
        ref = parse_reference(args.reference)
        with open(args.ko, "rb") as handle:
            data = bytearray(handle.read())
    except (OSError, ValueError) as exc:
        print("::error::%s" % exc)
        return 2

    sections = read_sections(data)
    symbols = read_symbols(data, sections)

    crc_sections = {s["idx"]: s for s in sections if s["name"].startswith("__kcrctab")}
    if not crc_sections:
        print("::error::%s 里没有 __kcrctab 段" % args.ko)
        return 2

    exported = {s["name"] for s in symbols}
    fixed = 0
    already = 0
    problems = []

    for sym in symbols:
        if not sym["name"].startswith("__crc_"):
            continue
        name = sym["name"][len("__crc_"):]
        if name not in ref:
            continue
        sec = crc_sections.get(sym["shndx"])
        if sec is None:
            problems.append("%s 不在 __kcrctab 段里" % name)
            continue
        off = sec["offset"] + sym["value"]
        current = struct.unpack_from("<I", data, off)[0]
        want = ref[name]
        if current == want:
            already += 1
            continue
        if args.check:
            problems.append("%s 0x%08x != 原厂 0x%08x" % (name, current, want))
            continue
        struct.pack_into("<I", data, off, want)
        fixed += 1
        print("  %-30s 0x%08x -> 0x%08x" % (name, current, want))

    for name in ref:
        if "__crc_" + name not in exported:
            problems.append("%s 没有导出" % name)

    if fixed and not args.check:
        with open(args.ko, "wb") as handle:
            handle.write(bytes(data))
        print("写回 %s：%d 项" % (args.ko, fixed))

    print("参考符号 %d，本来就一致 %d，本次对齐 %d" % (len(ref), already, fixed))

    if problems:
        for item in problems:
            print("  %s" % item)
        print("::error::导出的符号 CRC 与设备原厂不一致")
        return 1

    print("导出的符号 CRC 与设备原厂逐条一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
