# Out-of-tree build of the LZ4KDS-capable fork of the vendor hybridswap zram
# driver (oplus_bsp_hybridswap_zram) for the RMX5010 6.6.118 GKI kernel.
#
# Object list follows jkHXQ/RMX5010-lz4kds-zram: driver core + HiSilicon LZ4KD
# codec + Crystal SDDC.  Vendor-only parts (hybridswap core/swapd, kcompressd,
# mm_osvelte mtrack, display notifier) stay compiled out, matching the author's
# own release whose modinfo shows an empty "depends" list.
#
# The directory has to keep the vendor layout (../thp_zsmalloc next to this
# directory) because the driver headers use ../ relative includes.

KSRC ?= ../kernel
KOUT ?= $(KSRC)/out
ZSMALLOC_SYMVERS ?= $(CURDIR)/Module.symvers.zsmalloc

ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC=1 -O2
ccflags-y += -I$(src) -I$(KSRC)/include

obj-m += oplus_bsp_hybridswap_zram.o
oplus_bsp_hybridswap_zram-y := zcomp.o zram_drv.o \
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
