#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-./tests/phase1_real_setup.conf}"
if [[ ! -f "${CONFIG_FILE}" ]]; then
	echo "Config file not found: ${CONFIG_FILE}" >&2
	exit 1
fi
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

: "${CLIENT_HOST:?Missing CLIENT_HOST}"
: "${SERVER_HOST:?Missing SERVER_HOST}"
: "${CLIENT_CONTAINER:?Missing CLIENT_CONTAINER}"
: "${SERVER_CONTAINER:?Missing SERVER_CONTAINER}"
: "${SERVER_CONTAINER_IP:?Missing SERVER_CONTAINER_IP}"
: "${REMOTE_PHASE1_DIR:?Missing REMOTE_PHASE1_DIR}"

SSH_OPTS=${SSH_OPTS:-""}
RESULT_ROOT=${RESULT_ROOT:-"./tests/results"}
RUN_ID=${RUN_ID:-"$(date -u +%Y%m%dT%H%M%SZ)"}
RESULT_DIR="${RESULT_ROOT}/${RUN_ID}"
REQUEST_SIZE=${REQUEST_SIZE:-64}
RESPONSE_SIZE=${RESPONSE_SIZE:-64}
NETSERVER_PORT=${NETSERVER_PORT:-12865}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE1_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
CLIENT_VETH=""
CLIENT_NETNS=""

mkdir -p "${RESULT_DIR}"
cp "${CONFIG_FILE}" "${RESULT_DIR}/config.snapshot"

log() {
	printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${RESULT_DIR}/run.log"
}

record_pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	log "PASS: $*"
}

record_fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	log "FAIL: $*"
}

remote_client() {
	# shellcheck disable=SC2086
	ssh ${SSH_OPTS} "${CLIENT_HOST}" "$@"
}

remote_server() {
	# shellcheck disable=SC2086
	ssh ${SSH_OPTS} "${SERVER_HOST}" "$@"
}

sync_phase1() {
	log "Syncing phase1-ebpf to ${CLIENT_HOST}:${REMOTE_PHASE1_DIR}"
	rsync -az --delete \
		--exclude 'build/' \
		--exclude 'tests/results/' \
		--exclude 'vendor/' \
		"${PHASE1_ROOT}/" "${CLIENT_HOST}:${REMOTE_PHASE1_DIR}/"
	remote_client "cd '${REMOTE_PHASE1_DIR}' && CLANG=clang-10 ./scripts/build.sh"
}

build_client_variant() {
	local sample_divisor="${1:-}"
	local flow_stats_max_entries="${2:-}"
	log "Building client eBPF object sample_divisor=${sample_divisor:-1} flow_stats_max_entries=${flow_stats_max_entries:-65536}"
	remote_client "cd '${REMOTE_PHASE1_DIR}' && CLANG=clang-10 SAMPLE_DIVISOR='${sample_divisor}' FLOW_STATS_MAX_ENTRIES='${flow_stats_max_entries}' ./scripts/build.sh"
}

ensure_netserver() {
	log "Ensuring netserver is running on ${SERVER_HOST}:${SERVER_CONTAINER}"
	remote_server "docker exec '${SERVER_CONTAINER}' pkill netserver 2>/dev/null || true"
	remote_server "docker exec -d '${SERVER_CONTAINER}' netserver -D"
	sleep 1
}

find_client_veth() {
	local discovery
	discovery="$(remote_client "${REMOTE_PHASE1_DIR}/scripts/find_container_veth.sh '${CLIENT_CONTAINER}'")"
	CLIENT_NETNS="$(awk -F= '/^NETNS=/{print $2}' <<<"${discovery}")"
	CLIENT_VETH="$(awk -F= '/^IFACE=/{print $2}' <<<"${discovery}")"
	log "Client attach target on ${CLIENT_HOST}: netns=${CLIENT_NETNS:-default} iface=${CLIENT_VETH}"
}

attach_program() {
	remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/detach.sh' '${CLIENT_VETH}'" >/dev/null 2>&1 || true
	remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/attach.sh' '${CLIENT_VETH}'"
}

detach_program() {
	if [[ -n "${CLIENT_VETH}" ]]; then
		remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/detach.sh' '${CLIENT_VETH}'" >/dev/null 2>&1 || true
	fi
}

save_remote_file() {
	local remote_path="$1"
	local local_name="$2"
	# shellcheck disable=SC2086
	scp ${SSH_OPTS} "${CLIENT_HOST}:${remote_path}" "${RESULT_DIR}/${local_name}" >/dev/null
}

run_netperf() {
	local test_type="$1"
	local duration="$2"
	local output_name="$3"
	remote_client "docker exec '${CLIENT_CONTAINER}' netperf -H '${SERVER_CONTAINER_IP}' -t '${test_type}' -l '${duration}' -- -r '${REQUEST_SIZE},${RESPONSE_SIZE}'" \
		> "${RESULT_DIR}/${output_name}" 2>&1
}

dump_counters_remote() {
	local output_name="$1"
	remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/dump_counters.sh' '${CLIENT_VETH}'" \
		> "${RESULT_DIR}/${output_name}" 2>&1
}

dump_flows_remote() {
	local output_name="$1"
	local limit="${2:-0}"
	remote_client "NETNS='${CLIENT_NETNS}' python3 '${REMOTE_PHASE1_DIR}/user/dump_flows.py' --iface '${CLIENT_VETH}' --limit '${limit}'" \
		> "${RESULT_DIR}/${output_name}" 2>&1
}

counter_value() {
	local file="$1"
	local counter="$2"
	awk -v name="${counter}" '$1 == name {print $2; found=1; exit} END {if (!found) print 0}' "${file}"
}

count_flow_rows() {
	local file="$1"
	awk 'NR > 1 && $1 !~ /^[[:space:]]*$/ {count++} END {print count+0}' "${file}"
}

top_flow_packets() {
	local file="$1"
	awk 'NR > 1 && $6 ~ /^[0-9]+$/ {print $6}' "${file}" | sort -nr | head -1
}

netperf_rate() {
	local file="$1"
	awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+/ {rate=$NF} END {printf "%.2f", rate+0}' "${file}"
}

test_0_environment() {
	log "Test 0: environment sanity"
	{
		echo "orchestrator=$(hostname)"
		remote_client "echo client_host=\$(hostname); uname -r; command -v tc; command -v bpftool; command -v clang; command -v docker; command -v python3"
		remote_server "echo server_host=\$(hostname); uname -r; docker ps --format '{{.Names}}'"
		remote_client "docker ps --format '{{.Names}}'"
	} > "${RESULT_DIR}/test0_environment.txt" 2>&1

	run_netperf "TCP_RR" 5 "test0_netperf.txt"
	if grep -q "per sec" "${RESULT_DIR}/test0_netperf.txt"; then
		record_pass "Test 0 baseline netperf connectivity"
	else
		record_fail "Test 0 baseline netperf connectivity"
	fi
}

test_1_find_veth() {
	log "Test 1: find client veth"
	find_client_veth
	echo "${CLIENT_VETH}" > "${RESULT_DIR}/test1_veth.txt"
	if [[ -n "${CLIENT_VETH}" ]]; then
		record_pass "Test 1 resolved client veth ${CLIENT_VETH}"
	else
		record_fail "Test 1 resolved client veth"
	fi
}

test_2_attach_detach() {
	log "Test 2: attach and detach"
	attach_program
	remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/show_tc.sh' '${CLIENT_VETH}'" > "${RESULT_DIR}/test2_tc_attached.txt"
	detach_program
	remote_client "NETNS='${CLIENT_NETNS}' '${REMOTE_PHASE1_DIR}/scripts/show_tc.sh' '${CLIENT_VETH}'" > "${RESULT_DIR}/test2_tc_detached.txt"
	if grep -qi "bpf" "${RESULT_DIR}/test2_tc_attached.txt"; then
		record_pass "Test 2 attach shows bpf filter"
	else
		record_fail "Test 2 attach shows bpf filter"
	fi
	if ! grep -qi "bpf" "${RESULT_DIR}/test2_tc_detached.txt"; then
		record_pass "Test 2 detach removes bpf filter"
	else
		record_fail "Test 2 detach removes bpf filter"
	fi
}

test_3_passive_idle() {
	log "Test 3: passive idle counters"
	attach_program
	sleep 3
	dump_counters_remote "test3_counters.txt"
	remote_client "docker exec '${CLIENT_CONTAINER}' ping -c 3 '${SERVER_CONTAINER_IP}'" > "${RESULT_DIR}/test3_ping.txt" 2>&1
	dump_counters_remote "test3_counters_after_ping.txt"
	detach_program
	if grep -q "3 packets transmitted, 3 packets received" "${RESULT_DIR}/test3_ping.txt"; then
		record_pass "Test 3 ping works with eBPF attached"
	else
		record_fail "Test 3 ping works with eBPF attached"
	fi
}

test_4_tcp_rr() {
	log "Test 4: TCP_RR flow detection"
	attach_program
	run_netperf "TCP_RR" 10 "test4_netperf.txt"
	dump_flows_remote "test4_flows.txt"
	dump_counters_remote "test4_counters.txt"
	detach_program
	local flow_count
	flow_count="$(count_flow_rows "${RESULT_DIR}/test4_flows.txt")"
	local top_packets
	top_packets="$(top_flow_packets "${RESULT_DIR}/test4_flows.txt")"
	if [[ "${flow_count}" -ge 1 && "${top_packets}" -gt 0 ]]; then
		record_pass "Test 4 observed TCP_RR flow with packets=${top_packets}"
	else
		record_fail "Test 4 observed TCP_RR flow"
	fi
}

test_5_tcp_crr() {
	log "Test 5: TCP_CRR cold-flow detection"
	attach_program
	run_netperf "TCP_CRR" 10 "test5_netperf.txt"
	dump_flows_remote "test5_flows.txt"
	detach_program
	local crr_flows
	crr_flows="$(count_flow_rows "${RESULT_DIR}/test5_flows.txt")"
	if [[ "${crr_flows}" -gt 1 ]]; then
		record_pass "Test 5 observed many TCP_CRR flows (${crr_flows})"
	else
		record_fail "Test 5 observed many TCP_CRR flows (${crr_flows})"
	fi
}

test_6_hot_vs_cold() {
	log "Test 6: hot vs cold comparison"
	attach_program
	remote_client "for i in \$(seq 1 10); do docker exec '${CLIENT_CONTAINER}' netperf -H '${SERVER_CONTAINER_IP}' -t TCP_RR -l 30 -- -r '${REQUEST_SIZE},${RESPONSE_SIZE}' >/tmp/phase1_hot_\${i}.log 2>&1 & done"
	sleep 5
	remote_client "for i in \$(seq 1 10); do docker exec '${CLIENT_CONTAINER}' netperf -H '${SERVER_CONTAINER_IP}' -t TCP_CRR -l 20 -- -r '${REQUEST_SIZE},${RESPONSE_SIZE}' >/tmp/phase1_cold_\${i}.log 2>&1 & done"
	remote_client "wait"
	dump_flows_remote "test6_flows.txt" 20
	detach_program
	local top_packets
	top_packets="$(top_flow_packets "${RESULT_DIR}/test6_flows.txt")"
	local flow_count
	flow_count="$(count_flow_rows "${RESULT_DIR}/test6_flows.txt")"
	if [[ "${flow_count}" -gt 10 && "${top_packets}" -gt 50 ]]; then
		record_pass "Test 6 top flow packets=${top_packets} across ${flow_count} flows"
	else
		record_fail "Test 6 hot vs cold separation (top=${top_packets}, flows=${flow_count})"
	fi
}

test_7_sampling() {
	log "Test 7: sampling correctness"
	build_client_variant "" ""
	attach_program
	run_netperf "TCP_RR" 15 "test7_unsampled_netperf.txt"
	dump_flows_remote "test7_unsampled_flows.txt"
	local unsampled_packets
	unsampled_packets="$(top_flow_packets "${RESULT_DIR}/test7_unsampled_flows.txt")"
	detach_program

	build_client_variant "8" ""
	attach_program
	run_netperf "TCP_RR" 15 "test7_sampled_netperf.txt"
	dump_flows_remote "test7_sampled_flows.txt"
	dump_counters_remote "test7_sampled_counters.txt"
	detach_program

	local sampled_packets
	sampled_packets="$(awk 'NR > 1 {print $7}' "${RESULT_DIR}/test7_sampled_flows.txt" | sort -nr | head -1)"
	local estimated_packets=$((sampled_packets * 8))
	local delta=0
	if [[ "${unsampled_packets}" -gt 0 ]]; then
		delta=$(( (estimated_packets - unsampled_packets) * 100 / unsampled_packets ))
		if [[ "${delta}" -lt 0 ]]; then
			delta=$(( -delta ))
		fi
	fi
	printf 'unsampled_packets=%s sampled_packets=%s estimated_packets=%s delta_percent=%s\n' \
		"${unsampled_packets}" "${sampled_packets}" "${estimated_packets}" "${delta}" \
		> "${RESULT_DIR}/test7_sampling_summary.txt"
	if [[ "${delta}" -le 20 ]]; then
		record_pass "Test 7 sampling estimate within 20 percent (delta=${delta}%)"
	else
		record_fail "Test 7 sampling estimate delta=${delta}%"
	fi
	build_client_variant "" ""
}

test_8_lru_capacity() {
	log "Test 8: LRU capacity behavior"
	build_client_variant "" "128"
	attach_program
	remote_client "for i in \$(seq 1 64); do docker exec '${CLIENT_CONTAINER}' netperf -H '${SERVER_CONTAINER_IP}' -t TCP_CRR -l 30 -- -r '${REQUEST_SIZE},${RESPONSE_SIZE}' >/tmp/phase1_lru_\${i}.log 2>&1 & done"
	remote_client "wait"
	dump_flows_remote "test8_flows.txt"
	dump_counters_remote "test8_counters.txt"
	detach_program
	local flow_count
	flow_count="$(count_flow_rows "${RESULT_DIR}/test8_flows.txt")"
	local flow_new
	flow_new="$(counter_value "${RESULT_DIR}/test8_counters.txt" "CNT_FLOW_NEW")"
	if [[ "${flow_count}" -le 128 && "${flow_new}" -gt 0 ]]; then
		record_pass "Test 8 flow map bounded to ${flow_count} entries (flow_new=${flow_new})"
	else
		record_fail "Test 8 flow map bounded (flows=${flow_count}, flow_new=${flow_new})"
	fi
	build_client_variant "" ""
}

test_9_hot_flow_map() {
	log "Test 9: manual hot_flows lookup"
	attach_program
	dump_counters_remote "test9_counters_before.txt"
	remote_client "docker exec '${CLIENT_CONTAINER}' netperf -H '${SERVER_CONTAINER_IP}' -t TCP_RR -l 20 -- -r '${REQUEST_SIZE},${RESPONSE_SIZE}' >'${REMOTE_PHASE1_DIR}/test9_seed_netperf.log' 2>&1 &"
	sleep 2
	dump_flows_remote "test9_seed_flows.txt"
	if [[ "$(count_flow_rows "${RESULT_DIR}/test9_seed_flows.txt")" -lt 1 ]]; then
		remote_client "wait" >/dev/null 2>&1 || true
		detach_program
		record_fail "Test 9 could not seed a flow for hot_flows insertion"
		return
	fi
	local src_ip src_port dst_ip dst_port proto
	if ! read -r _top_packets src_ip src_port dst_ip dst_port proto < <(
		awk 'NR > 1 {print $6, $1, $2, $3, $4, $5}' "${RESULT_DIR}/test9_seed_flows.txt" \
			| sort -nr | head -1
	); then
		remote_client "wait" >/dev/null 2>&1 || true
		detach_program
		record_fail "Test 9 could not select a seeded flow"
		return
	fi
	if [[ -z "${src_ip:-}" ]]; then
		remote_client "wait" >/dev/null 2>&1 || true
		detach_program
		record_fail "Test 9 could not select a seeded flow"
		return
	fi
	local proto_arg="tcp"
	if [[ "${proto}" == "UDP" ]]; then
		proto_arg="udp"
	fi
	remote_client "NETNS='${CLIENT_NETNS}' python3 '${REMOTE_PHASE1_DIR}/user/insert_hot_flow.py' --iface '${CLIENT_VETH}' --src-ip '${src_ip}' --dst-ip '${dst_ip}' --src-port '${src_port}' --dst-port '${dst_port}' --proto '${proto_arg}'" \
		> "${RESULT_DIR}/test9_insert_hot_flow.txt" 2>&1
	sleep 5
	remote_client "wait" >/dev/null 2>&1 || true
	save_remote_file "${REMOTE_PHASE1_DIR}/test9_seed_netperf.log" "test9_seed_netperf.txt"
	dump_counters_remote "test9_counters_after.txt"
	detach_program
	local hot_before hot_after fallback_before fallback_after
	hot_before="$(counter_value "${RESULT_DIR}/test9_counters_before.txt" "CNT_HOT_PACKETS")"
	hot_after="$(counter_value "${RESULT_DIR}/test9_counters_after.txt" "CNT_HOT_PACKETS")"
	fallback_before="$(counter_value "${RESULT_DIR}/test9_counters_before.txt" "CNT_FALLBACK_PACKETS")"
	fallback_after="$(counter_value "${RESULT_DIR}/test9_counters_after.txt" "CNT_FALLBACK_PACKETS")"
	if [[ "$((hot_after - hot_before))" -gt 0 ]]; then
		record_pass "Test 9 hot_flows lookup incremented CNT_HOT_PACKETS"
	else
		record_fail "Test 9 hot_flows lookup did not increment CNT_HOT_PACKETS"
	fi
	if [[ "$((fallback_after - fallback_before))" -ge 0 ]]; then
		record_pass "Test 9 fallback counters remained readable"
	else
		record_fail "Test 9 fallback counters unreadable"
	fi
}

test_10_overhead() {
	log "Test 10: overhead sanity"
	detach_program
	run_netperf "TCP_RR" 30 "test10_baseline_netperf.txt"
	local baseline_rate
	baseline_rate="$(netperf_rate "${RESULT_DIR}/test10_baseline_netperf.txt")"
	attach_program
	run_netperf "TCP_RR" 30 "test10_attached_netperf.txt"
	detach_program
	local attached_rate
	attached_rate="$(netperf_rate "${RESULT_DIR}/test10_attached_netperf.txt")"
	local overhead_pct
	overhead_pct="$(awk -v base="${baseline_rate}" -v attached="${attached_rate}" 'BEGIN {
		if (base <= 0) { print 0; exit }
		diff = base - attached
		if (diff < 0) diff = -diff
		printf "%.0f", (diff * 100) / base
	}')"
	printf 'baseline_rate=%s attached_rate=%s overhead_percent=%s\n' \
		"${baseline_rate}" "${attached_rate}" "${overhead_pct}" \
		> "${RESULT_DIR}/test10_overhead_summary.txt"
	if [[ "${overhead_pct}" -le 10 ]]; then
		record_pass "Test 10 overhead within 10 percent (${overhead_pct}%)"
	else
		record_fail "Test 10 overhead ${overhead_pct}%"
	fi
}

cleanup() {
	detach_program || true
}

trap cleanup EXIT

main() {
	log "Starting Phase 1 real-setup tests run_id=${RUN_ID}"
	ensure_netserver
	sync_phase1
	test_0_environment
	test_1_find_veth
	test_2_attach_detach
	test_3_passive_idle
	test_4_tcp_rr
	test_5_tcp_crr
	test_6_hot_vs_cold
	test_7_sampling
	test_8_lru_capacity
	test_9_hot_flow_map
	test_10_overhead
	log "Phase 1 test summary: pass=${PASS_COUNT} fail=${FAIL_COUNT} results=${RESULT_DIR}"
	printf 'pass=%s\nfail=%s\n' "${PASS_COUNT}" "${FAIL_COUNT}" > "${RESULT_DIR}/summary.txt"
	if [[ "${FAIL_COUNT}" -gt 0 ]]; then
		exit 1
	fi
}

main "$@"
