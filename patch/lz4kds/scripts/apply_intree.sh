#!/bin/bash
# 把 LZ4K / LZ4KD 压缩算法接进内核树（in-tree），并生成 zram 后端。
#
# 用法：apply_intree.sh <内核源码目录>
#
# 设计要点：
#   * 新增文件一律整份覆盖拷贝（crypto/lz4k.c、lib/lz4k/ 等），不做 patch，
#     因此不受前面 SUSFS / lz4 / zstd 补丁造成的上下文漂移影响。
#   * 已有文件的改动全部走「锚点定位 + 幂等判断」，
#     已存在则跳过、锚点缺失则 exit 1，绝不静默跳过。
set -euo pipefail

COMMON="${1:?用法: apply_intree.sh <内核源码目录>}"
PATCH_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$COMMON/kernel/sched" ]; then
	echo "::error::${COMMON} 不像内核源码目录"
	exit 1
fi
cd "$COMMON"

fail() {
	echo "::error::$*"
	exit 1
}

# insert_before <文件> <锚点行(精确匹配)> <要插入的多行内容>
insert_before() {
	local file="$1" anchor="$2" body="$3"
	grep -qxF "$anchor" "$file" || fail "${file} 里找不到锚点：${anchor}"
	local first
	first="$(printf '%s\n' "$body" | head -n1)"
	if grep -qxF "$first" "$file"; then
		echo "  - ${file} 已包含插入内容，跳过"
		return 0
	fi
	awk -v anchor="$anchor" -v body="$body" '
		$0 == anchor && !done {
			n = split(body, lines, "\n")
			# body 末尾的换行会在 split 后产生一个空元素，丢掉它，
			# 否则每次插入都会多插一个空行。
			if (n > 0 && lines[n] == "")
				n--
			for (i = 1; i <= n; i++) print lines[i]
			done = 1
		}
		{ print }
	' "$file" > "$file.lz4kds.tmp"
	mv "$file.lz4kds.tmp" "$file"
	echo "  + ${file} 已插入"
}

# append_after <文件> <锚点行(精确匹配)> <要追加的多行内容>
append_after() {
	local file="$1" anchor="$2" body="$3"
	grep -qxF "$anchor" "$file" || fail "${file} 里找不到锚点：${anchor}"
	local first
	first="$(printf '%s\n' "$body" | head -n1)"
	if grep -qxF "$first" "$file"; then
		echo "  - ${file} 已包含追加内容，跳过"
		return 0
	fi
	awk -v anchor="$anchor" -v body="$body" '
		{ print }
		$0 == anchor && !done {
			n = split(body, lines, "\n")
			# body 末尾的换行会在 split 后产生一个空元素，丢掉它，
			# 否则每次插入都会多插一个空行。
			if (n > 0 && lines[n] == "")
				n--
			for (i = 1; i <= n; i++) print lines[i]
			done = 1
		}
	' "$file" > "$file.lz4kds.tmp"
	mv "$file.lz4kds.tmp" "$file"
	echo "  + ${file} 已追加"
}

echo "== [1/6] 拷贝新增源码文件 =="
mkdir -p lib/lz4k lib/lz4kd
cp "$PATCH_DIR/intree/crypto/lz4k.c"  crypto/lz4k.c
cp "$PATCH_DIR/intree/crypto/lz4kd.c" crypto/lz4kd.c
cp "$PATCH_DIR/intree/include/linux/lz4k.h"  include/linux/lz4k.h
cp "$PATCH_DIR/intree/include/linux/lz4kd.h" include/linux/lz4kd.h
cp "$PATCH_DIR"/intree/lib/lz4k/*  lib/lz4k/
cp "$PATCH_DIR"/intree/lib/lz4kd/* lib/lz4kd/
echo "  crypto/lz4k.c crypto/lz4kd.c include/linux/lz4{k,kd}.h lib/lz4{k,kd}/"

echo "== [2/6] crypto/Kconfig：注册 CRYPTO_LZ4K / CRYPTO_LZ4KD =="
insert_before crypto/Kconfig "config CRYPTO_LZ4HC" 'config CRYPTO_LZ4K
	tristate "LZ4K"
	select CRYPTO_ALGAPI
	select LZ4K_COMPRESS
	select LZ4K_DECOMPRESS
	help
	  LZ4K compression algorithm (HiSilicon).

config CRYPTO_LZ4KD
	tristate "LZ4KD"
	select CRYPTO_ALGAPI
	select LZ4KD_COMPRESS
	select LZ4KD_DECOMPRESS
	help
	  LZ4KD compression algorithm (HiSilicon).

'

echo "== [3/6] lib/Kconfig：注册 LZ4K/LZ4KD 编解码实现选项 =="
insert_before lib/Kconfig "config ZSTD_COMMON" 'config LZ4K_COMPRESS
	tristate

config LZ4K_DECOMPRESS
	tristate

config LZ4KD_COMPRESS
	tristate

config LZ4KD_DECOMPRESS
	tristate

'

echo "== [4/6] crypto/Makefile + lib/Makefile =="
append_after crypto/Makefile "obj-\$(CONFIG_CRYPTO_LZ4HC) += lz4hc.o" 'obj-$(CONFIG_CRYPTO_LZ4K) += lz4k.o
obj-$(CONFIG_CRYPTO_LZ4KD) += lz4kd.o
'
append_after lib/Makefile "obj-\$(CONFIG_LZ4_DECOMPRESS) += lz4/" 'obj-$(CONFIG_LZ4K_COMPRESS) += lz4k/
obj-$(CONFIG_LZ4K_DECOMPRESS) += lz4k/
obj-$(CONFIG_LZ4KD_COMPRESS) += lz4kd/
obj-$(CONFIG_LZ4KD_DECOMPRESS) += lz4kd/
'

echo "== [5/6] zram：Kconfig 依赖/默认算法 + zcomp 后端 =="
ZK=drivers/block/zram/Kconfig
if grep -q 'CRYPTO_LZ4K' "$ZK"; then
	echo "  - ${ZK} 已包含 lz4k，跳过"
else
	sed -i 's/^\tdepends on CRYPTO_LZO || CRYPTO_ZSTD || CRYPTO_LZ4 || CRYPTO_LZ4HC || CRYPTO_842$/\tdepends on CRYPTO_LZO || CRYPTO_ZSTD || CRYPTO_LZ4 || CRYPTO_LZ4HC || CRYPTO_LZ4K || CRYPTO_LZ4KD || CRYPTO_842/' "$ZK"
	grep -q 'CRYPTO_LZ4K || CRYPTO_LZ4KD' "$ZK" || fail "${ZK} 的 depends 行没改成"
	insert_before "$ZK" "config ZRAM_DEF_COMP_842" 'config ZRAM_DEF_COMP_LZ4K
	bool "lz4k"
	depends on CRYPTO_LZ4K

config ZRAM_DEF_COMP_LZ4KD
	bool "lz4kd"
	depends on CRYPTO_LZ4KD

'
	insert_before "$ZK" '	default "842" if ZRAM_DEF_COMP_842' '	default "lz4k" if ZRAM_DEF_COMP_LZ4K
	default "lz4kd" if ZRAM_DEF_COMP_LZ4KD
'
fi

ZC=drivers/block/zram/zcomp.c
if grep -qxF '#if IS_ENABLED(CONFIG_CRYPTO_LZ4K)' "$ZC"; then
	echo "  - ${ZC} 已包含 lz4k 后端，跳过"
else
	insert_before "$ZC" '#if IS_ENABLED(CONFIG_CRYPTO_842)' '#if IS_ENABLED(CONFIG_CRYPTO_LZ4K)
	"lz4k",
#endif
#if IS_ENABLED(CONFIG_CRYPTO_LZ4KD)
	"lz4kd",
#endif'
fi

echo "== [6/6] gki_defconfig：内置 LZ4K / LZ4KD =="
DEFCONFIG=arch/arm64/configs/gki_defconfig
for opt in CONFIG_CRYPTO_LZ4K=y CONFIG_CRYPTO_LZ4KD=y; do
	if grep -qxF "$opt" "$DEFCONFIG"; then
		echo "  - ${DEFCONFIG} 已有 ${opt}"
	else
		echo "$opt" >> "$DEFCONFIG"
		echo "  + ${DEFCONFIG} 追加 ${opt}"
	fi
done

echo "== 自检 =="
grep -q '^config CRYPTO_LZ4K$'   crypto/Kconfig || fail "crypto/Kconfig 未包含 CRYPTO_LZ4K"
grep -q '^config CRYPTO_LZ4KD$'  crypto/Kconfig || fail "crypto/Kconfig 未包含 CRYPTO_LZ4KD"
grep -q '^config LZ4KD_COMPRESS$' lib/Kconfig   || fail "lib/Kconfig 未包含 LZ4KD_COMPRESS"
grep -q 'lz4k.o'  crypto/Makefile || fail "crypto/Makefile 未包含 lz4k.o"
grep -q 'lz4kd/'  lib/Makefile    || fail "lib/Makefile 未包含 lz4kd/"
grep -q '"lz4kd",' drivers/block/zram/zcomp.c || fail "zcomp.c 未包含 lz4kd 后端"
grep -q 'ZRAM_DEF_COMP_LZ4KD' drivers/block/zram/Kconfig || fail "zram Kconfig 未包含 ZRAM_DEF_COMP_LZ4KD"
echo "LZ4K/LZ4KD 已接入内核树"
