/* SPDX-License-Identifier: GPL-2.0 */
#ifndef PHASE1_COMMON_H
#define PHASE1_COMMON_H

#include <linux/types.h>

/* IPv4 addresses and ports are stored in network byte order. */
struct flow_key {
	__u32 src_ip;
	__u32 dst_ip;
	__u16 src_port;
	__u16 dst_port;
	__u8 proto;
	__u8 pad1;
	__u16 pad2;
};

struct flow_stats {
	__u64 first_seen_ns;
	__u64 last_seen_ns;
	__u64 packets;
	__u64 sampled_packets;
	__u64 bytes;
};

struct hot_flow_value {
	__u64 estimated_pps;
	__u64 updated_ns;
};

enum counter_id {
	CNT_TOTAL_PACKETS = 0,
	CNT_PARSED_IPV4,
	CNT_PARSED_TCP,
	CNT_PARSED_UDP,
	CNT_UNSUPPORTED_ETH,
	CNT_UNSUPPORTED_IP,
	CNT_FRAGMENTED_IP,
	CNT_FLOW_NEW,
	CNT_FLOW_SEEN,
	CNT_HOT_PACKETS,
	CNT_FALLBACK_PACKETS,
	CNT_SAMPLE_SKIPPED,
	CNT_PARSE_ERROR,
	CNT_MAX,
};

#ifndef FLOW_STATS_MAX_ENTRIES
#define FLOW_STATS_MAX_ENTRIES 65536
#endif

#ifndef HOT_FLOWS_MAX_ENTRIES
#define HOT_FLOWS_MAX_ENTRIES 4096
#endif

struct bpf_map_def {
	__u32 type;
	__u32 key_size;
	__u32 value_size;
	__u32 max_entries;
	__u32 map_flags;
	__u32 inner_map_idx;
	__u32 numa_node;
};

#endif /* PHASE1_COMMON_H */
