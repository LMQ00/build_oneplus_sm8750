// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (C) 2014 Sergey Senozhatsky.
 */

#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/err.h>
#include <linux/slab.h>
#include <linux/wait.h>
#include <linux/sched.h>
#include <linux/cpu.h>
#include <linux/crypto.h>

#include "zcomp.h"
#include "lz4kd/lz4kd.h"
#include "sddc/crystal_sddc_codec.h"

/*
 * The list must not depend on the build-time crypto config: the vendor kernel
 * registers lz4k/zstdn/zstdn_o at runtime, and availability is decided by
 * zcomp_available_algorithm()/crypto_has_comp() instead.
 */
static const char * const backends[] = {
	"lz4kd",
	"lz4kds",
	"lzo",
	"lzo-rle",
	"lz4",
	"lz4hc",
	"842",
	"zstd",
	"lz4k",
	"zstdn",
	"zstdn_o",
};

static void zcomp_strm_free(struct zcomp_strm *zstrm)
{
	if (!IS_ERR_OR_NULL(zstrm->tfm))
		crypto_free_comp(zstrm->tfm);
	if (zstrm->backend_data) {
		if (zstrm->is_lz4kds)
			crystal_sddc_codec_destroy(zstrm->backend_data);
		else
			kvfree(zstrm->backend_data);
	}
	free_pages((unsigned long)zstrm->buffer, 1);

	zstrm->tfm = NULL;
	zstrm->backend_data = NULL;
	zstrm->is_lz4kd = false;
	zstrm->is_lz4kds = false;
	zstrm->buffer = NULL;
}

/*
 * Initialize zcomp_strm structure with ->tfm initialized by backend, and
 * ->buffer. Return a negative value on error.
 */
static int zcomp_strm_init(struct zcomp_strm *zstrm, struct zcomp *comp)
{
	/*
	 * allocate 2 pages. 1 for compressed data, plus 1 extra for the
	 * case when compressed size is larger than the original one
	 */
	zstrm->buffer = (void *)__get_free_pages(GFP_KERNEL | __GFP_ZERO, 1);
	if (!zstrm->buffer)
		return -ENOMEM;

	if (!strcmp(comp->name, "lz4kd")) {
		zstrm->backend_data = kvzalloc(
			crystal_lz4kd_encode_state_bytes_min(), GFP_KERNEL);
		if (!zstrm->backend_data) {
			free_pages((unsigned long)zstrm->buffer, 1);
			zstrm->buffer = NULL;
			return -ENOMEM;
		}
		zstrm->is_lz4kd = true;
		return 0;
	}

	if (!strcmp(comp->name, "lz4kds")) {
		struct crystal_sddc_codec *codec = crystal_sddc_codec_create();

		if (IS_ERR(codec)) {
			free_pages((unsigned long)zstrm->buffer, 1);
			zstrm->buffer = NULL;
			return PTR_ERR(codec);
		}
		zstrm->backend_data = codec;
		zstrm->is_lz4kds = true;
		return 0;
	}

	zstrm->tfm = crypto_alloc_comp(comp->name, 0, 0);
	if (IS_ERR_OR_NULL(zstrm->tfm)) {
		zcomp_strm_free(zstrm);
		return -ENOMEM;
	}
	return 0;
}

bool zcomp_available_algorithm(const char *comp)
{
	/*
	 * Crypto does not ignore a trailing new line symbol,
	 * so make sure you don't supply a string containing
	 * one.
	 * This also means that we permit zcomp initialisation
	 * with any compressing algorithm known to crypto api.
	 */
	if (!strcmp(comp, "lz4kd") || !strcmp(comp, "lz4kds"))
		return true;

	return crypto_has_comp(comp, 0, 0) == 1;
}

/* show available compressors */
ssize_t zcomp_available_show(const char *comp, char *buf)
{
	bool known_algorithm = false;
	ssize_t sz = 0;
	int i;

	for (i = 0; i < ARRAY_SIZE(backends); i++) {
		/* Skip backends this kernel/device does not register at runtime. */
		if (strcmp(backends[i], "lz4kd") && strcmp(backends[i], "lz4kds") &&
		    crypto_has_comp(backends[i], 0, 0) != 1)
			continue;
		if (!strcmp(comp, backends[i])) {
			known_algorithm = true;
			sz += scnprintf(buf + sz, PAGE_SIZE - sz - 2,
					"[%s] ", backends[i]);
		} else {
			sz += scnprintf(buf + sz, PAGE_SIZE - sz - 2,
					"%s ", backends[i]);
		}
	}

	/*
	 * Out-of-tree module known to crypto api or a missing
	 * entry in `backends'.
	 */
	if (!known_algorithm && crypto_has_comp(comp, 0, 0) == 1)
		sz += scnprintf(buf + sz, PAGE_SIZE - sz - 2,
				"[%s] ", comp);

	sz += scnprintf(buf + sz, PAGE_SIZE - sz, "\n");
	return sz;
}

struct zcomp_strm *zcomp_stream_get(struct zcomp *comp)
{
	local_lock(&comp->stream->lock);
	return this_cpu_ptr(comp->stream);
}

void zcomp_stream_put(struct zcomp *comp)
{
	local_unlock(&comp->stream->lock);
}

int zcomp_compress(struct zcomp_strm *zstrm,
		const void *src, unsigned int *dst_len)
{
	/*
	 * Our dst memory (zstrm->buffer) is always `2 * PAGE_SIZE' sized
	 * because sometimes we can endup having a bigger compressed data
	 * due to various reasons: for example compression algorithms tend
	 * to add some padding to the compressed buffer. Speaking of padding,
	 * comp algorithm `842' pads the compressed length to multiple of 8
	 * and returns -ENOSP when the dst memory is not big enough, which
	 * is not something that ZRAM wants to see. We can handle the
	 * `compressed_size > PAGE_SIZE' case easily in ZRAM, but when we
	 * receive -ERRNO from the compressing backend we can't help it
	 * anymore. To make `842' happy we need to tell the exact size of
	 * the dst buffer, zram_drv will take care of the fact that
	 * compressed buffer is too big.
	 */
	*dst_len = PAGE_SIZE * 2;

	if (zstrm->is_lz4kd) {
		int ret = crystal_lz4kd_encode(zstrm->backend_data, src,
				zstrm->buffer, PAGE_SIZE, *dst_len, 0);

		if (ret < 0)
			return -EINVAL;
		if (ret > 0)
			*dst_len = ret;
		return 0;
	}

	if (zstrm->is_lz4kds)
		return crystal_sddc_codec_compress(zstrm->backend_data, src,
				PAGE_SIZE, zstrm->buffer, dst_len);

	return crypto_comp_compress(zstrm->tfm,
			src, PAGE_SIZE,
			zstrm->buffer, dst_len);
}

int zcomp_decompress(struct zcomp_strm *zstrm,
		const void *src, unsigned int src_len, void *dst)
{
	unsigned int dst_len = PAGE_SIZE;

	if (zstrm->is_lz4kd || zstrm->is_lz4kds) {
		int ret = crystal_lz4kd_decode(src, dst, src_len, PAGE_SIZE);

		if (ret != PAGE_SIZE)
			return -EINVAL;
		return 0;
	}

	return crypto_comp_decompress(zstrm->tfm,
			src, src_len,
			dst, &dst_len);
}

bool zcomp_supports_delta(const struct zcomp *comp)
{
	return comp && comp->name && !strcmp(comp->name, "lz4kds");
}

int zcomp_compress_delta(struct zcomp_strm *zstrm, const void *ref,
		unsigned int ref_len, const void *src, unsigned int src_len,
		unsigned int *dst_len, unsigned int out_limit)
{
	if (!zstrm->is_lz4kds)
		return -EOPNOTSUPP;

	*dst_len = PAGE_SIZE * 2;
	return crystal_sddc_codec_compress_delta(zstrm->backend_data, ref,
			ref_len, src, src_len, zstrm->buffer, dst_len, out_limit);
}

int zcomp_decompress_delta(struct zcomp_strm *zstrm, const void *src,
		unsigned int src_len, const void *ref, unsigned int ref_len,
		void *dst, unsigned int *dst_len)
{
	if (!zstrm->is_lz4kds)
		return -EOPNOTSUPP;

	*dst_len = PAGE_SIZE;
	return crystal_sddc_codec_decompress_delta(zstrm->backend_data, src,
			src_len, ref, ref_len, dst, dst_len);
}

int zcomp_decompress_delta_borrowed(struct zcomp_strm *zstrm, const void *src,
		unsigned int src_len, const void *ref, unsigned int ref_len,
		const void **restored, unsigned int *restored_len)
{
	if (!restored || !restored_len)
		return -EINVAL;

	*restored = NULL;
	*restored_len = PAGE_SIZE;
	if (!zstrm->is_lz4kds)
		return -EOPNOTSUPP;

	return crystal_sddc_codec_decompress_delta_borrowed(zstrm->backend_data,
			src, src_len, ref, ref_len, restored, restored_len);
}

int zcomp_cpu_up_prepare(unsigned int cpu, struct hlist_node *node)
{
	struct zcomp *comp = hlist_entry(node, struct zcomp, node);
	struct zcomp_strm *zstrm;
	int ret;

	zstrm = per_cpu_ptr(comp->stream, cpu);
	local_lock_init(&zstrm->lock);

	ret = zcomp_strm_init(zstrm, comp);
	if (ret)
		pr_err("Can't allocate a compression stream\n");
	return ret;
}

int zcomp_cpu_dead(unsigned int cpu, struct hlist_node *node)
{
	struct zcomp *comp = hlist_entry(node, struct zcomp, node);
	struct zcomp_strm *zstrm;

	zstrm = per_cpu_ptr(comp->stream, cpu);
	zcomp_strm_free(zstrm);
	return 0;
}

static int zcomp_init(struct zcomp *comp)
{
	int ret;

	comp->stream = alloc_percpu(struct zcomp_strm);
	if (!comp->stream)
		return -ENOMEM;

	ret = cpuhp_state_add_instance(CPUHP_ZCOMP_PREPARE, &comp->node);
	if (ret < 0)
		goto cleanup;
	return 0;

cleanup:
	free_percpu(comp->stream);
	return ret;
}

void zcomp_destroy(struct zcomp *comp)
{
	cpuhp_state_remove_instance(CPUHP_ZCOMP_PREPARE, &comp->node);
	free_percpu(comp->stream);
	kfree(comp);
}

/*
 * search available compressors for requested algorithm.
 * allocate new zcomp and initialize it. return compressing
 * backend pointer or ERR_PTR if things went bad. ERR_PTR(-EINVAL)
 * if requested algorithm is not supported, ERR_PTR(-ENOMEM) in
 * case of allocation error, or any other error potentially
 * returned by zcomp_init().
 */
struct zcomp *zcomp_create(const char *compress)
{
	struct zcomp *comp;
	int error;

	/*
	 * Crypto API will execute /sbin/modprobe if the compression module
	 * is not loaded yet. We must do it here, otherwise we are about to
	 * call /sbin/modprobe under CPU hot-plug lock.
	 */
	if (!zcomp_available_algorithm(compress))
		return ERR_PTR(-EINVAL);

	comp = kzalloc(sizeof(struct zcomp), GFP_KERNEL);
	if (!comp)
		return ERR_PTR(-ENOMEM);

	comp->name = compress;
	error = zcomp_init(comp);
	if (error) {
		kfree(comp);
		return ERR_PTR(error);
	}
	return comp;
}
