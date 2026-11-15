#!/system/bin/sh
# 让 zram0 用 driver.conf 里配的算法压缩。
#
# 开机时把 /odm/etc/oplus_mm_config.xml 里每个 <zram0> 段补上 comp_algorithm，
# 再把补好的文件 bind mount 回 /odm/etc/oplus_mm_config.xml。
#
# 厂商 /product/bin/init.oplus.nandswap.sh 在 boot_completed 阶段读这个 XML，
# 把 comp_algorithm 和 disk_size_mb 写进 /sys/block/zram0，然后 mkswap + swapon。
# 它先写 comp_algorithm 再写 disksize，那时候 zram0 还没初始化，写什么就是
# 什么。让 XML 直接给出目标算法，开机后就不用再 reset 一遍 zram。
#
# 不改分区：分区上的原文件复制到 payload/oplus_mm_config.orig.xml，补好的写到
# payload/oplus_mm_config.xml。换过 OTA 时原始文件跟着更新。
#
# 子命令：
#   无      开机流程，KernelSU 在 post-fs-data 阶段调用
#   regen   按当前 driver.conf 重新生成并挂载（zram.sh 改完配置后调用）
#
# 想临时不干预：sh zram.sh stock；改回来：sh zram.sh ours。

MOD=${MODPATH:-/data/adb/modules/lz4kds}
CONF=$MOD/payload/driver.conf
FLAG=$MOD/stock_driver
SRC=/odm/etc/oplus_mm_config.xml
DST=$MOD/payload/oplus_mm_config.xml
ORIG=$MOD/payload/oplus_mm_config.orig.xml

# 日志写不进去时退到 /dev/null。日志路径打不开会让整条命令不执行
# （mksh 里重定向先于 fork）。
LOG=$MOD/driver.log
if ! ( : >>"$LOG" ) 2>/dev/null; then
	LOG=/dev/null
fi

log() {
	echo "$(date +%H:%M:%S) $*" >>"$LOG" 2>/dev/null
}

# driver.conf 里 key=value 的值，取第一个匹配。
conf_get() {
	awk -v k="$1" '
		{
			sub(/#.*/, "")
			sub(/\r$/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			if ($0 ~ "^" k "[ \t]*=") {
				sub("^" k "[ \t]*=", "")
				gsub(/^[ \t]+|[ \t]+$/, "")
				print
				exit
			}
		}
	' "$CONF" 2>/dev/null | head -1
}

# /odm/etc/oplus_mm_config.xml 现在是不是我们自己挂上去的那份
is_bound() {
	grep -q " $SRC " /proc/self/mountinfo 2>/dev/null
}

# 生成 $DST。$1 算法；$2 容量 MiB（空表示沿用原文件里的值）。
#
# 厂商写进 disksize 的是 disk_size_mb + increase_limit，所以每个段要用
# 目标容量减掉它自己的 increase_limit，这样每段算出来都等于目标容量。
gen_xml() {
	awk -v TAG="<comp_algorithm>$1</comp_algorithm>" -v SIZE="$2" '
		BEGIN { n = 0; inz = 0 }
		index($0, "<zram0>") > 0 {
			inz = 1
			n = 0
			buf[++n] = $0
			next
		}
		inz && index($0, "</zram0>") > 0 {
			buf[++n] = $0
			emit()
			inz = 0
			n = 0
			next
		}
		inz {
			buf[++n] = $0
			next
		}
		{ print }
		function emit(   i, v, inc) {
			inc = 0
			for (i = 1; i <= n; i++) {
				if (index(buf[i], "<increase_limit>") == 0) continue
				v = buf[i]
				sub(/.*<increase_limit>/, "", v)
				sub(/<.*/, "", v)
				gsub(/[ \t]/, "", v)
				if (v ~ /^[0-9]+$/) inc = v + 0
			}
			print buf[1]
			print "            " TAG
			if (SIZE != "" && SIZE - inc > 0) {
				print "            <disk_size_mb>" (SIZE - inc) "</disk_size_mb>"
			}
			for (i = 2; i <= n; i++) {
				if (index(buf[i], "</zram0>") > 0) {
					print buf[i]
					continue
				}
				if (index(buf[i], "<comp_algorithm>") > 0) continue
				if (SIZE != "" && index(buf[i], "<disk_size_mb>") > 0) continue
				print buf[i]
			}
		}
	' "$ORIG" >"$DST" 2>/dev/null

	# 每段的 comp_algorithm 都换成了目标算法，容量要时每段都有 disk_size_mb
	awk -v ALGO="$1" -v NEED="${2:+1}" '
		index($0, "<zram0>") > 0 { n++; a[n] = 0; d[n] = 0 }
		index($0, "<comp_algorithm>" ALGO "</comp_algorithm>") > 0 { a[n] = 1 }
		index($0, "<disk_size_mb>") > 0 { d[n] = 1 }
		END {
			if (n == 0) exit 1
			for (i = 1; i <= n; i++) {
				if (!a[i]) exit 1
				if (NEED != "" && !d[i]) exit 1
			}
			exit 0
		}
	' "$DST" 2>/dev/null
}

# 生成并挂载。$1 算法；$2 容量 MiB（空表示不改容量）。
apply_xml() {
	_a_algo=$1
	_a_size=$2

	if [ ! -f "$SRC" ]; then
		log "没有 $SRC，跳过"
		return 1
	fi

	# 挂着自己那份时先卸掉，否则复制到的原文件其实是改过的那份
	if is_bound; then
		umount "$SRC" 2>/dev/null
	fi

	if ! cp -f "$SRC" "$ORIG" 2>/dev/null; then
		log "存 $ORIG 失败，跳过"
		return 1
	fi

	if ! gen_xml "$_a_algo" "$_a_size"; then
		log "生成 $DST 失败，跳过"
		return 1
	fi

	# 厂商读的是 vendor 分区的文件，标签要对上，不然读不到。
	chcon u:object_r:vendor_configs_file:s0 "$DST" 2>/dev/null
	chmod 644 "$DST" 2>/dev/null

	if ! mount --bind "$DST" "$SRC" 2>/dev/null; then
		log "bind mount 到 $SRC 失败，留给 service.sh 兜底"
		return 1
	fi

	if ! grep -q "<comp_algorithm>$_a_algo</comp_algorithm>" "$SRC" 2>/dev/null; then
		log "挂上去之后再读不是 $_a_algo，留给 service.sh 兜底"
		return 1
	fi

	log "XML 的 zram0 段已改成 $_a_algo${_a_size:+，容量 $_a_size MiB}"
	return 0
}

main() {
	log "=== 开始"

	if [ -f "$FLAG" ]; then
		log "存在 $FLAG，不干预"
		return 0
	fi

	ALGO=$(conf_get algo)
	[ -n "$ALGO" ] || ALGO=lz4kd

	if [ "$ALGO" = "off" ]; then
		log "algo=off，不干预"
		return 0
	fi

	SIZE=$(conf_get size)
	case "$SIZE" in
	'' | *[!0-9]*) SIZE="" ;;
	esac

	apply_xml "$ALGO" "$SIZE"
	return $?
}

main
RET=$?
log "=== 结束（rc=$RET）"

if [ "$LOG" != /dev/null ]; then
	tail -200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
fi
exit $RET
