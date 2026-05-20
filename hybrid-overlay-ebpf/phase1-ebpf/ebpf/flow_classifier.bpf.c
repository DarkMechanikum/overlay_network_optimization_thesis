/* SPDX-License-Identifier: GPL-2.0 */
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/pkt_cls.h>

#include "bpf_helpers.h"
#include "bpf_endian.h"

#include "common.h"

#ifndef SAMPLE_DIVISOR
#define SAMPLE_DIVISOR 1
#endif

struct bpf_map_def SEC("maps") flow_stats = {
	.type = BPF_MAP_TYPE_LRU_HASH,
	.key_size = sizeof(struct flow_key),
	.value_size = sizeof(struct flow_stats),
	.max_entries = FLOW_STATS_MAX_ENTRIES,
};

struct bpf_map_def SEC("maps") hot_flows = {
	.type = BPF_MAP_TYPE_LRU_HASH,
	.key_size = sizeof(struct flow_key),
	.value_size = sizeof(struct hot_flow_value),
	.max_entries = HOT_FLOWS_MAX_ENTRIES,
};

struct bpf_map_def SEC("maps") global_counters = {
	.type = BPF_MAP_TYPE_ARRAY,
	.key_size = sizeof(__u32),
	.value_size = sizeof(__u64),
	.max_entries = CNT_MAX,
};

static __always_inline void inc_counter(__u32 id)
{
	__u64 *val = bpf_map_lookup_elem(&global_counters, &id);

	if (val)
		*val += 1;
}

static __always_inline int parse_packet(struct __sk_buff *skb, struct flow_key *key)
{
	void *data = (void *)(long)skb->data;
	void *data_end = (void *)(long)skb->data_end;
	struct ethhdr *eth = data;

	if ((void *)(eth + 1) > data_end) {
		inc_counter(CNT_PARSE_ERROR);
		return -1;
	}

	if (eth->h_proto != bpf_htons(ETH_P_IP)) {
		inc_counter(CNT_UNSUPPORTED_ETH);
		return -1;
	}

	struct iphdr *ip = (void *)(eth + 1);

	if ((void *)(ip + 1) > data_end) {
		inc_counter(CNT_PARSE_ERROR);
		return -1;
	}

	if (ip->version != 4) {
		inc_counter(CNT_UNSUPPORTED_IP);
		return -1;
	}

	if (ip->frag_off & bpf_htons(0x2000 | 0x1fff)) {
		inc_counter(CNT_FRAGMENTED_IP);
		return -1;
	}

	__u8 ihl = ip->ihl * 4;

	if (ihl < sizeof(struct iphdr)) {
		inc_counter(CNT_PARSE_ERROR);
		return -1;
	}

	void *l4 = (void *)ip + ihl;

	if (l4 > data_end) {
		inc_counter(CNT_PARSE_ERROR);
		return -1;
	}

	key->src_ip = ip->saddr;
	key->dst_ip = ip->daddr;
	key->proto = ip->protocol;
	key->pad1 = 0;
	key->pad2 = 0;
	key->src_port = 0;
	key->dst_port = 0;

	inc_counter(CNT_PARSED_IPV4);

	if (ip->protocol == IPPROTO_TCP) {
		struct tcphdr *tcp = l4;

		if ((void *)(tcp + 1) > data_end) {
			inc_counter(CNT_PARSE_ERROR);
			return -1;
		}

		key->src_port = tcp->source;
		key->dst_port = tcp->dest;
		inc_counter(CNT_PARSED_TCP);
	} else if (ip->protocol == IPPROTO_UDP) {
		struct udphdr *udp = l4;

		if ((void *)(udp + 1) > data_end) {
			inc_counter(CNT_PARSE_ERROR);
			return -1;
		}

		key->src_port = udp->source;
		key->dst_port = udp->dest;
		inc_counter(CNT_PARSED_UDP);
	} else {
		inc_counter(CNT_UNSUPPORTED_IP);
		return -1;
	}

	return 0;
}

static __always_inline int should_skip_sample(void)
{
#if SAMPLE_DIVISOR > 1
	if ((bpf_get_prandom_u32() % SAMPLE_DIVISOR) != 0)
		return 1;
#endif
	return 0;
}

static __always_inline void update_flow_stats(const struct flow_key *key, __u64 bytes)
{
	struct flow_stats *stats = bpf_map_lookup_elem(&flow_stats, key);
	__u64 now = bpf_ktime_get_ns();
	struct flow_stats updated;

	if (!stats) {
		__builtin_memset(&updated, 0, sizeof(updated));
		updated.first_seen_ns = now;
		updated.last_seen_ns = now;
		updated.packets = 1;
		updated.sampled_packets = 1;
		updated.bytes = bytes;
		bpf_map_update_elem(&flow_stats, key, &updated, BPF_ANY);
		inc_counter(CNT_FLOW_NEW);
		return;
	}

	updated = *stats;
	updated.last_seen_ns = now;
	updated.packets += 1;
	updated.sampled_packets += 1;
	updated.bytes += bytes;
	bpf_map_update_elem(&flow_stats, key, &updated, BPF_EXIST);
	inc_counter(CNT_FLOW_SEEN);
}

SEC("tc")
int flow_classifier(struct __sk_buff *skb)
{
	inc_counter(CNT_TOTAL_PACKETS);

	struct flow_key key = {};
	__u64 bytes = skb->len;

	if (parse_packet(skb, &key) < 0)
		return TC_ACT_OK;

	if (should_skip_sample()) {
		inc_counter(CNT_SAMPLE_SKIPPED);
		return TC_ACT_OK;
	}

	update_flow_stats(&key, bytes);

	if (bpf_map_lookup_elem(&hot_flows, &key))
		inc_counter(CNT_HOT_PACKETS);
	else
		inc_counter(CNT_FALLBACK_PACKETS);

	return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
