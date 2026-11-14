#!/usr/bin/env python3
"""把构建出的 KO 里 __kcrctab 段的 CRC 对齐到设备原厂 KO 的值。

用法：
    python3 fix_export_crc.py <ko> <reference.tsv>
    python3 fix_export_crc.py <ko> <reference.tsv> --check

reference.tsv 每行：<crc(hex)>\t<symbol>。

modpost 用 genksyms 递归展开签名算 CRC，展开结果取决于签名里出现的每个类型的
完整定义。原厂 oplus_bsp_hybridswap_zram.ko 出自 realme 的 OEM 变体内核树，与本
仓库使用的 GKI 树在这些嵌套类型上不同，同一个函数签名就会算出不同的值，即使双方
生成的机器码逐条指令一致。这里把原厂值写回 __kcrctab，让引用这些符号的厂商模块
能通过 check_version()。

退出码：
    0  全部一致
    1  有符号缺失或对齐后仍不一致
    2  输入文件缺失 / 格式错误
"""
import argparse
import os
import stat
import struct
import sys
import tempfile

SHT_SYMTAB = 2
ELF_HEADER_SIZE = 64


class BadInput(Exception):
    """输入不是可用的 ELF / TSV。"""


def parse_reference(path):
    ref = {}
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                raise BadInput("%s:%d 不是 2 段 TSV：%r" % (path, lineno, line))
            try:
                crc = int(parts[0], 16)
            except ValueError:
                raise BadInput("%s:%d CRC 不是十六进制：%r" % (path, lineno, parts[0]))
            if not 0 <= crc <= 0xFFFFFFFF:
                raise BadInput("%s:%d CRC 超出 32 位：%r" % (path, lineno, parts[0]))
            name = parts[1]
            if name in ref and ref[name] != crc:
                raise BadInput(
                    "%s:%d %s 重复且值不同：0x%08x 与 0x%08x"
                    % (path, lineno, name, ref[name], crc)
                )
            ref[name] = crc
    if not ref:
        raise BadInput("%s 里没有任何符号" % path)
    return ref


def check_range(data, sec, what):
    if sec["offset"] + sec["size"] > len(data):
        raise BadInput("%s 越过文件尾（offset=0x%x size=0x%x）"
                       % (what, sec["offset"], sec["size"]))


def read_sections(data):
    if data[:4] != b"\x7fELF":
        raise BadInput("不是 ELF 文件")
    if len(data) < ELF_HEADER_SIZE:
        raise BadInput("文件短于 ELF 头")

    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    if e_shentsize < 64:
        raise BadInput("节表项大小异常：%d" % e_shentsize)
    if e_shnum == 0:
        raise BadInput("节表项数为 0（扩展编号未支持）")
    if e_shoff + e_shnum * e_shentsize > len(data):
        raise BadInput("节表越过文件尾")
    if e_shstrndx >= e_shnum:
        raise BadInput("节名字符串表索引越界：%d" % e_shstrndx)

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
    check_range(data, strtab, "节名字符串表")

    for sec in sections:
        start = strtab["offset"] + sec["name_off"]
        if start >= len(data):
            raise BadInput("节名偏移越界：0x%x" % start)
        end = data.find(b"\0", start)
        if end < 0:
            raise BadInput("节名没有终止符：0x%x" % start)
        sec["name"] = data[start:end].decode("utf-8", "replace")

    return sections


def read_symbols(data, sections):
    out = []
    for sec in sections:
        if sec["typ"] != SHT_SYMTAB:
            continue
        check_range(data, sec, ".symtab")
        if sec["link"] >= len(sections):
            raise BadInput(".symtab 的字符串表索引越界：%d" % sec["link"])
        strtab = sections[sec["link"]]
        check_range(data, strtab, ".symtab 的字符串表")
        for i in range(sec["size"] // 24):
            off = sec["offset"] + i * 24
            name_off, _info, _other, shndx, value, _size = struct.unpack_from(
                "<IBBHQQ", data, off
            )
            start = strtab["offset"] + name_off
            if start >= len(data):
                raise BadInput("符号名偏移越界：0x%x" % start)
            end = data.find(b"\0", start)
            if end < 0:
                raise BadInput("符号名没有终止符：0x%x" % start)
            out.append(dict(name=data[start:end].decode("utf-8", "replace"),
                            shndx=shndx, value=value))
    return out


def read_export_names(data, sections):
    """__ksymtab_strings 里的符号名。

    __ksymtab* 的条目在文件里是全 0，name_offset 由 .rela___ksymtab_* 在加载时回填，
    所以只能看字符串表。名字在里面说明这个符号确实以该名字导出。
    """
    for sec in sections:
        if sec["name"] != "__ksymtab_strings":
            continue
        check_range(data, sec, "__ksymtab_strings")
        blob = data[sec["offset"]:sec["offset"] + sec["size"]]
        return {part.decode("utf-8", "replace") for part in blob.split(b"\0") if part}
    return set()


def write_back(path, data, mode):
    """先写同目录的临时文件再替换，保留原文件的权限位。

    path 可能是指向真实 KO 的符号链接，直接 os.replace 会把链接本身换成普通文件、
    真正那个文件一个字节都不动，所以先解到真实路径。
    """
    target = os.path.realpath(path)
    handle, tmp = tempfile.mkstemp(dir=os.path.dirname(target) or ".",
                                  prefix=os.path.basename(target) + ".",
                                  suffix=".crc.tmp")
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(bytes(data))
        os.chmod(tmp, stat.S_IMODE(mode))
        os.replace(tmp, target)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


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
        mode = os.stat(args.ko).st_mode
        sections = read_sections(data)
        symbols = read_symbols(data, sections)
        export_names = read_export_names(data, sections)
    except (OSError, ValueError, struct.error, IndexError, BadInput) as exc:
        print("::error::%s：%s" % (args.ko, exc))
        return 2

    if not symbols:
        # modpost 打出的 KO 一定带 .symtab，__crc_ 条目的位置只能从它取。
        print("::error::%s 里没有 .symtab，定位不到 __crc_ 条目" % args.ko)
        return 2

    crc_sections = {s["idx"]: s for s in sections if s["name"].startswith("__kcrctab")}
    if not crc_sections:
        print("::error::%s 里没有 __kcrctab 段" % args.ko)
        return 2

    have_crc = {s["name"][len("__crc_"):] for s in symbols
                if s["name"].startswith("__crc_")}
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
        if sym["value"] % 4 or sym["value"] + 4 > sec["size"]:
            problems.append("%s 的 __crc_ 偏移 0x%x 越出 %s"
                            % (name, sym["value"], sec["name"]))
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
        if name not in have_crc:
            problems.append("%s 没有导出（.symtab 里没有 __crc_ 条目）" % name)
        elif export_names and name not in export_names:
            problems.append("%s 的 __crc_ 在，但 __ksymtab 里没有这个导出名" % name)

    print("参考符号 %d，本来就一致 %d，本次对齐 %d" % (len(ref), already, fixed))

    if problems:
        for item in problems:
            print("  %s" % item)
        print("::error::导出的符号 CRC 与设备原厂不一致")
        return 1

    if fixed and not args.check:
        try:
            write_back(args.ko, data, mode)
        except OSError as exc:
            print("::error::写回 %s 失败：%s" % (args.ko, exc))
            return 2
        print("写回 %s：%d 项" % (args.ko, fixed))

    print("导出的符号 CRC 与设备原厂逐条一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
