# Out-of-tree build of the LZ4KDS-capable fork of the vendor hybridswap zram
# driver (oplus_bsp_hybridswap_zram) for the RMX5010 6.6.118 GKI kernel.
#
# 编译内容：驱动核心 + HiSilicon LZ4KD 编解码 + Crystal SDDC + hybridswap
# （内存 cgroup 扩展、swapd 回收器、zram 换出核心、面板通知）。
#
# hybridswap 三个开关都需要打开：厂商的 oplus_bsp_fg_protect、
# oplus_bsp_zram_opt、oplus_exit_mm_optimize 依赖本模块导出的
# get_mem_cgroup_app_uid / get_mem_cgroup_app_name / get_next_memcg /
# get_next_memcg_break / free_zram_is_ok。前四个在 hybridmain.c（
# CONFIG_HYBRIDSWAP 控制），最后一个在 hybridswapd.c（CONFIG_HYBRIDSWAP_SWAPD
# 控制），hybridswap_track/batch_out 等在 hybridswap.c（CONFIG_HYBRIDSWAP_CORE）。
#
# 目录必须保持厂商布局（../thp_zsmalloc 与本目录平级），因为驱动头文件里
# 用的是 ../ 相对包含。

KSRC ?= ../kernel
KOUT ?= $(KSRC)/out
ZSMALLOC_SYMVERS ?= $(CURDIR)/Module.symvers.zsmalloc

ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC=1 -O2
ccflags-y += -DCONFIG_HYBRIDSWAP=1 -DCONFIG_HYBRIDSWAP_SWAPD=1 -DCONFIG_HYBRIDSWAP_CORE=1
ccflags-y += -I$(src) -I$(src)/.. -I$(KSRC)/include

obj-m += oplus_bsp_hybridswap_zram.o
oplus_bsp_hybridswap_zram-y := zcomp.o zram_drv.o \
	hybridswap/hybridmain.o hybridswap/hybridswapd.o \
	hybridswap/hybridswap.o hybridswap/display.o \
	sddc/crystal_sddc.o sddc/crystal_sddc_codec.o \
	lz4kd/lz4kd_encode.o lz4kd/lz4kd_decode.o \
	lz4kd/lz4kd_encode_delta.o lz4kd/lz4kd_neon.o

CFLAGS_REMOVE_lz4kd/lz4kd_neon.o += -mgeneral-regs-only
CFLAGS_lz4kd/lz4kd_neon.o += -ffreestanding -isystem $(shell $(CC) -print-file-name=include)

# 不传 LOCALVERSION：模块 vermagic 由内核树自己的 include/config/kernel.release 决定，
# 与所编译的内核完全一致，避免手写后缀跟工作流动态后缀不一致。
all:
	$(MAKE) -C $(KSRC) O=$(KOUT) M=$(CURDIR) \
		KBUILD_EXTRA_SYMBOLS=$(ZSMALLOC_SYMVERS) \
		LLVM=1 ARCH=arm64 modules

clean:
	$(MAKE) -C $(KSRC) O=$(KOUT) M=$(CURDIR) clean
