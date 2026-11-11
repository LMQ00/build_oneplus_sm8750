/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Compatibility shim that lets the vendor hybridswap_zram driver reuse the
 * Crystal SDDC manager without pulling in Crystal's private zram core.
 *
 * The vendor tree only exports the _oplus zsmalloc entry points and has no
 * per-memcg zram accounting, so the SDDC call sites are mapped onto the
 * vendor equivalents and the accounting hooks are inert.  Making SDDC depend
 * on partially-ported accounting would risk corrupting the OPPO/realme
 * memcg policy, which is why the resident delta layer stays self-contained.
 */
#ifndef _CRYSTAL_SDDC_COMPAT_H_
#define _CRYSTAL_SDDC_COMPAT_H_

#include <linux/atomic.h>
#include <linux/types.h>
/*
 * The vendor allocator header shares the upstream include guard name, so it
 * must be included directly instead of <linux/zsmalloc.h>.
 */
#include "../thp_zsmalloc/zsmalloc.h"

struct zram;

/* Minimal logging facade: the vendor driver has no hybridswap log level. */
enum {
	CHS_LOG_ERR = 0,
	CHS_LOG_WARN,
	CHS_LOG_INFO,
	CHS_LOG_DEBUG,
};

#define chs_log(level, fmt, ...)		pr_info(fmt, ##__VA_ARGS__)
#define chs_log_ratelimited(level, fmt, ...)	\
	pr_info_ratelimited(fmt, ##__VA_ARGS__)

/* Trade-union of vendor zsmalloc API names. */
#define zs_create_pool(name)		zs_create_pool_oplus((name))
#define zs_destroy_pool(pool)		zs_destroy_pool_oplus((pool))
#define zs_malloc(pool, size, gfp)	zs_malloc_oplus((pool), (size), (gfp))
#define zs_free(pool, handle)		zs_free_oplus((pool), (handle))
#define zs_map_object(pool, handle, mm)	\
	zs_map_object_oplus((pool), (handle), (mm))
#define zs_unmap_object(pool, handle)	zs_unmap_object_oplus((pool), (handle))
#define zs_get_total_pages(pool)	zs_get_total_pages_oplus((pool))
#define zs_huge_class_size(pool)	zs_huge_class_size_oplus((pool))

/*
 * The device zsmalloc module does not export a size-class lookup helper.
 * Falling back to the raw byte size keeps the "must be strictly smaller"
 * admission rule; it only loses the coarse class rounding, which can let an
 * occasional same-class delta through.
 */
static inline unsigned int zs_lookup_class_index(struct zs_pool *pool,
						 unsigned int size)
{
	return size;
}

/* No per-memcg accounting in the vendor driver; hooks stay inert. */
struct zram_memcg_stats_entry {
	atomic64_t zram_compressed_size;
};

static inline void zram_memcg_stats_update(atomic64_t *counter, s64 size,
					   bool add)
{
	if (add)
		atomic64_add(size, counter);
	else
		atomic64_sub(size, counter);
}

static inline void zram_memcg_stats_sub_current(struct zram *zram, u32 index)
{
}

static inline void zram_memcg_stats_add_current(struct zram *zram, u32 index)
{
}

static inline struct zram_memcg_stats_entry *
zram_memcg_stats_find_locked(struct zram *zram, u64 memcg_id)
{
	return NULL;
}

#endif /* _CRYSTAL_SDDC_COMPAT_H_ */
