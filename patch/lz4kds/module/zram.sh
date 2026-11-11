#!/system/bin/sh
# zram 容量 + 压缩算法配置
# 改完立即尝试热切换；内存不足或设备已满时自动退化为“重启生效”
#
# 用法：
#   sh zram.sh 8192              改容量并尝试立即生效（内存不足时等重启）
#   sh zram.sh 8G                同上，单位 GB
#   sh zram.sh 8192 lz4kds       容量 + 算法
#   sh zram.sh algo zstd         只改算法，容量不变
#   sh zram.sh show              查看配置与运行状态
#   sh zram.sh off               恢复厂商默认（不干预容量和算法）
#   sh zram.sh 8192 --reboot     只写配置，不做热切换
#
# 可选算法：lz4kds lz4kd lz4 zstd lzo lzo-rle lz4hc 842 lz4k zstdn zstdn_o

MOD=/data/adb/modules/lz4kds
CONF=$MOD/preinit/preinit.conf
META=/metadata/vold/ksu/preinit/lz4kds/preinit.conf
KS=/data/adb/ksu/bin/ksud
DEV=/dev/block/zram0
PRIO=32758

# 源文件与 metadata 副本不一致时自动 refresh，不再只提示
sync_meta() {
	cmp -s "$CONF" "$META" 2>/dev/null && return 0
	echo "检测到源文件与 metadata 不一致，自动执行 refresh ..."
	$KS initrc refresh >/dev/null 2>&1
	cmp -s "$CONF" "$META" 2>/dev/null && {
		echo "已同步到 metadata。"
		return 0
	}
	echo "!! 自动同步失败，请手动执行: ksud initrc refresh"
	return 1
}

# 读取现有配置
SIZE=$(sed -n 's/.*zram_size_mb=\([0-9][0-9]*\).*/\1/p' "$CONF" 2>/dev/null | head -1)
ALGO=$(sed -n 's/.*zram_algo=\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p' "$CONF" 2>/dev/null | head -1)
[ -n "$SIZE" ] || SIZE=0
[ -n "$ALGO" ] || ALGO=lz4kds

show() {
	sync_meta
	echo "== 配置（源文件）"
	cat "$CONF" 2>/dev/null
	echo "== 配置（metadata 副本，preinit 实际读取）"
	cat "$META" 2>/dev/null

	DS=$(cat /sys/block/zram0/disksize 2>/dev/null)
	echo "== 运行状态"
	if [ -n "$DS" ]; then
		# mksh 的 $(( )) 是 32 位，容量字节数会溢出，必须用 awk
		DS_MB=$(awk -v d="$DS" 'BEGIN{printf "%d", d/1048576}')
		echo "disksize : $DS ($DS_MB MiB)"
	fi
	echo "comp     : $(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
	echo "swap     : $(grep zram0 /proc/swaps 2>/dev/null | awk '{print $4" kB used / "$3" kB total"}')"
	echo "自检     : codec=$(cat /sys/module/oplus_bsp_hybridswap_zram/parameters/selftest_codec 2>/dev/null) io=$(cat /sys/module/oplus_bsp_hybridswap_zram/parameters/selftest_io 2>/dev/null)"

	if [ -n "$DS_MB" ] && [ "$SIZE" != 0 ] && [ "$DS_MB" != "$SIZE" ]; then
		echo "!! 运行容量 $DS_MB MiB 与配置 $SIZE MiB 不一致：需重启"
	fi
	if [ -n "$DS" ] && [ "$ALGO" != off ]; then
		case "$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)" in
		*"[$ALGO]"*) : ;;
		*) echo "!! 运行算法与配置 $ALGO 不一致：需重启" ;;
		esac
	fi
}

valid_algo() {
	case "$1" in
	lz4kds|lz4kd|lz4|zstd|lzo|lzo-rle|lz4hc|842|lz4k|zstdn|zstdn_o) return 0 ;;
	esac
	return 1
}

save() {
	TMP=$CONF.tmp
	{
		echo "insmod oplus_bsp_zsmalloc.ko"
		if [ "$SIZE" = 0 ]; then
			echo "insmod oplus_bsp_hybridswap_zram.ko zram_algo=$ALGO"
		else
			echo "insmod oplus_bsp_hybridswap_zram.ko zram_size_mb=$SIZE zram_algo=$ALGO"
		fi
	} >"$TMP" && mv "$TMP" "$CONF"
	chmod 644 "$CONF" 2>/dev/null
	$KS initrc refresh >/dev/null 2>&1
	if cmp -s "$CONF" "$META" 2>/dev/null; then
		if [ "$QUIET" = "1" ]; then
			echo "配置已写入"
		else
			echo "已保存并同步到 metadata（重启后生效）："
			cat "$CONF"
		fi
	else
		echo "!! 保存成功但同步失败，请手动执行: ksud initrc refresh"
	fi
}

REBOOT_ONLY=0
QUIET=0
for a in "$@"; do
	case "$a" in
	--reboot) REBOOT_ONLY=1 ;;
	--quiet) QUIET=1 ;;
	esac
done

KEEP_SIZE=0
TGT_MB=

case "$1" in
"" | show)
	show
	exit 0
	;;
off)
	SIZE=0
	ALGO=off
	save
	exit 0
	;;
algo)
	[ -n "$2" ] || { echo "用法: sh zram.sh algo <算法名>"; exit 1; }
	valid_algo "$2" || { echo "不支持的算法: $2"; exit 1; }
	ALGO=$2
	# 只换算法：热切换沿用当前运行容量，持久配置里的容量保持不变
	KEEP_SIZE=1
	if [ -s /sys/block/zram0/disksize ]; then
		TGT_MB=$(awk -v d="$(cat /sys/block/zram0/disksize)" \
			'BEGIN{printf "%d", d/1048576}')
	fi
	;;
esac

# 第一个参数是容量（algo 子命令只换算法，跳过容量解析）
if [ "$KEEP_SIZE" != "1" ]; then
case "$1" in
*[Gg])
	N=${1%[Gg]}
	case "$N" in *[!0-9]*|"") echo "容量格式错误，例如 8192 或 8G"; exit 1 ;; esac
	SIZE=$((N * 1024))
	;;
*)
	case "$1" in *[!0-9]*) echo "容量格式错误，例如 8192 或 8G"; exit 1 ;; esac
	SIZE=$1
	;;
esac
[ "$SIZE" -ge 512 ] && [ "$SIZE" -le 65536 ] || { echo "容量范围 512-65536 MB"; exit 1; }

# --reboot / --quiet 这类开关不是算法名
if [ -n "$2" ] && [ "${2#--}" = "$2" ]; then
	valid_algo "$2" || { echo "不支持的算法: $2"; exit 1; }
	ALGO=$2
fi

# 超过 2×物理内存的值在驱动里会被钳制，这里先调整并写回，避免配置与运行不一致
MAX_MB=$(awk '/MemTotal/ {printf "%d", $2 * 2 / 1024}' /proc/meminfo)
if [ "$SIZE" -gt "$MAX_MB" ]; then
	echo "!! 容量 ${SIZE} MiB 超过 2×物理内存上限，已调整为 ${MAX_MB} MiB"
	SIZE=$MAX_MB
fi
TGT_MB=$SIZE
fi

save

if [ -z "$TGT_MB" ] || [ "$TGT_MB" -eq 0 ]; then
	echo "配置已保存；zram0 未初始化或容量为厂商默认，重启后生效。"
	exit 0
fi

if [ "$REBOOT_ONLY" = "1" ]; then
	echo "配置已保存，重启后生效。"
	exit 0
fi

TGT_BYTES=$(awk -v m="$TGT_MB" 'BEGIN{printf "%.0f", m*1048576}')
CUR=$(cat /sys/block/zram0/disksize 2>/dev/null)

# 热切换前提：可用内存要装得下当前 swap 已用量，否则 swapoff 会失败
SWAP_USED=$(grep zram0 /proc/swaps 2>/dev/null | awk '{print $4}')
MEM_AVAIL=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
if [ -n "$SWAP_USED" ] && [ "$SWAP_USED" != "0" ]; then
	CAN=$(awk -v u="$SWAP_USED" -v a="$MEM_AVAIL" \
		'BEGIN{print (a > u + 262144) ? 1 : 0}')
	if [ "$CAN" != "1" ]; then
		echo "!! swap 已用 $((SWAP_USED / 1024)) MiB，可用内存 $((MEM_AVAIL / 1024)) MiB"
		echo "!! 内存不足，跳过热切换；配置已保存，重启后生效"
		exit 0
	fi
fi

CUR_MB=$(awk -v c="$CUR" 'BEGIN{printf "%d", c/1048576}')
PRE_ALGO=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null)
echo "正在切换：$CUR_MB MiB -> $TGT_MB MiB，算法 $ALGO"
# 先同步驱动参数，否则 disksize_store 会拿旧的 zram_size_mb 覆盖本次容量
echo "$TGT_MB" >/sys/module/oplus_bsp_hybridswap_zram/parameters/zram_size_mb 2>/dev/null
swapoff $DEV || {
	echo "!! swapoff 失败；配置已保存，重启后生效"
	exit 0
}

echo 1 >/sys/block/zram0/reset
# nodegrade 只用于挡 vendor 开机脚本的 lz4 降级；手动切换时先放开，避免选了 lz4 又被忽略
echo 0 >/sys/module/oplus_bsp_hybridswap_zram/parameters/lz4kds_nodegrade 2>/dev/null
echo "$ALGO" >/sys/block/zram0/comp_algorithm || echo "算法写入失败（可能未编译进模块）"
echo 1 >/sys/module/oplus_bsp_hybridswap_zram/parameters/lz4kds_nodegrade 2>/dev/null
echo "$TGT_BYTES" >/sys/block/zram0/disksize
mkswap $DEV >/dev/null 2>&1
if swapon -p $PRIO $DEV 2>/dev/null; then
	NOW_ALGO=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null)
	echo "已生效：容量 $TGT_MB MiB，算法 $NOW_ALGO"
else
	echo "swapon 失败，回滚原容量"
	# 设备此时已 init，直接写 comp_algorithm / disksize 会 EBUSY，必须先 reset
	echo 1 >/sys/block/zram0/reset
	if [ -n "$PRE_ALGO" ]; then
		echo "$PRE_ALGO" >/sys/block/zram0/comp_algorithm
	fi
	if [ -n "$CUR" ]; then
		echo "$CUR" >/sys/block/zram0/disksize
	fi
	mkswap $DEV >/dev/null 2>&1
	swapon -p $PRIO $DEV
	echo "已回滚：disksize=$(cat /sys/block/zram0/disksize)"
fi
