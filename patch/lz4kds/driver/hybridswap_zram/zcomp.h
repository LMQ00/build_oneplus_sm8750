/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Copyright (C) 2014 Sergey Senozhatsky.
 */

#ifndef _ZCOMP_H_
#define _ZCOMP_H_
#include <linux/local_lock.h>
#include <linux/types.h>

struct zcomp_strm {
	/* The members ->buffer and ->tfm are protected by ->lock. */
	local_lock_t lock;
	/* compression/decompression buffer */
	void *buffer;
	struct crypto_comp *tfm;
	/* private lz4kd codec state, NULL for crypto backends */
	void *backend_data;
	bool is_lz4kd;
	/* lz4kds backend: backend_data is struct crystal_sddc_codec */
	bool is_lz4kds;
};

/* dynamic per-device compression frontend */
struct zcomp {
	struct zcomp_strm __percpu *stream;
	const char *name;
	struct hlist_node node;
};

int zcomp_cpu_up_prepare(unsigned int cpu, struct hlist_node *node);
int zcomp_cpu_dead(unsigned int cpu, struct hlist_node *node);
ssize_t zcomp_available_show(const char *comp, char *buf);
bool zcomp_available_algorithm(const char *comp);
struct zcomp *zcomp_create(const char *comp);
void zcomp_destroy(struct zcomp *comp);

struct zcomp_strm *zcomp_stream_get(struct zcomp *comp);
void zcomp_stream_put(struct zcomp *comp);

int zcomp_compress(struct zcomp_strm *zstrm,
		const void *src, unsigned int *dst_len);

int zcomp_decompress(struct zcomp_strm *zstrm,
		const void *src, unsigned int src_len, void *dst);

bool zcomp_set_max_streams(struct zcomp *comp, int num_strm);

/* SDDC delta operations; only the lz4kds backend implements them. */
bool zcomp_supports_delta(const struct zcomp *comp);
int zcomp_compress_delta(struct zcomp_strm *zstrm, const void *ref,
		unsigned int ref_len, const void *src, unsigned int src_len,
		unsigned int *dst_len, unsigned int out_limit);
int zcomp_decompress_delta(struct zcomp_strm *zstrm, const void *src,
		unsigned int src_len, const void *ref, unsigned int ref_len,
		void *dst, unsigned int *dst_len);
int zcomp_decompress_delta_borrowed(struct zcomp_strm *zstrm, const void *src,
		unsigned int src_len, const void *ref, unsigned int ref_len,
		const void **restored, unsigned int *restored_len);
#endif /* _ZCOMP_H_ */
