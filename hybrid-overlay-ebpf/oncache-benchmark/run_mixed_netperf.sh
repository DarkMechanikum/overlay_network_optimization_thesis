#!/usr/bin/env bash
# Unified Docker mixed netperf: baseline vs full ONCache (ipvlan + ONCACHE_OVERLAY_FLAGS='').
#
# Usage:
#   ./run_mixed_netperf.sh /path/to/benchmark.conf
#   ./run_mixed_netperf.sh --reparse-results /path/to/run_dir /path/to/benchmark.conf
#
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${BENCH_ROOT}/.." && pwd)"
ONCACHE_DOCKER="${REPO_ROOT}/oncache-docker"

REPARSE_ONLY=0
CONFIG_FILE=""
if [[ "${1:-}" == "--reparse-results" ]]; then
	REPARSE_ONLY=1
	RESULT_DIR="${2:?Usage: $0 --reparse-results <result-dir> [benchmark.conf]}"
	CONFIG_FILE="${3:-${BENCH_ROOT}/benchmark.conf}"
else
	CONFIG_FILE="${1:?Usage: $0 <benchmark.conf>}"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
	echo "Config not found: $CONFIG_FILE" >&2
	exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${ONCACHE_CONF:?Set ONCACHE_CONF in benchmark.conf}"

case "${RUN_MODE:-}" in
baseline | oncache) ;;
*)
	echo "RUN_MODE must be 'baseline' or 'oncache' (got '${RUN_MODE:-}')" >&2
	exit 1
	;;
esac

if [[ "${IPVLAN_PREPARE_EACH_RUN:-1}" == "1" ]]; then
	if [[ -z "${SERVER_UNDERLAY:-}" || -z "${CLIENT_UNDERLAY:-}" ]]; then
		echo "Set SERVER_UNDERLAY and CLIENT_UNDERLAY in benchmark.conf for ipvlan prepare." >&2
		exit 1
	fi
fi

SSH_OPTS=${SSH_OPTS:-""}
RUN_ID=${RUN_ID:-"$(date -u +%Y%m%dT%H%M%SZ)"}
RESULT_ROOT=${RESULT_ROOT:-"${BENCH_ROOT}/results"}
RESULT_DIR="${RESULT_ROOT}/${RUN_MODE}/${RUN_ID}"
ONCACHE_RESULT_DIR="${RESULT_DIR}/oncache"
export CONFIG_SNAPSHOT="$CONFIG_FILE"
if [[ -z "${REMOTE_WORKDIR:-}" ]]; then
	export REMOTE_WORKDIR="/tmp/oncache_mixed_netperf_${RUN_ID}"
fi

remote() {
	local host="$1"
	shift
	ssh $SSH_OPTS "$host" "$@"
}

remote_bash() {
	local host="$1"
	shift
	ssh $SSH_OPTS "$host" "bash -s" -- "$@"
}

log_msg() {
	printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

resolve_server_container_ip() {
	if [[ "${AUTO_SERVER_CONTAINER_IP:-1}" != "1" && -n "${SERVER_CONTAINER_IP:-}" ]]; then
		printf '%s' "$SERVER_CONTAINER_IP"
		return
	fi
	remote "$SERVER_HOST" "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' '${SERVER_CONTAINER}'"
}

clean_hosts() {
	log_msg "Cleaning hosts (ONCache stop, netperf/netserver, remote workdir)"
	if [[ -x "${ONCACHE_DOCKER}/scripts/stop_all.sh" ]]; then
		"${ONCACHE_DOCKER}/scripts/stop_all.sh" "${ONCACHE_CONF}" || true
	fi
	remote "$CLIENT_HOST" "docker exec '${CLIENT_CONTAINER}' sh -c 'pkill -x netperf 2>/dev/null || true'" || true
	remote "$SERVER_HOST" "docker exec '${SERVER_CONTAINER}' sh -c 'pkill netserver 2>/dev/null; pkill iperf3 2>/dev/null || true'" || true
	remote "$CLIENT_HOST" "docker exec '${CLIENT_CONTAINER}' sh -c 'pkill iperf3 2>/dev/null || true'" || true
	local rw="${REMOTE_WORKDIR:-/tmp/oncache_mixed_netperf_${RUN_ID}}"
	remote "$CLIENT_HOST" "rm -rf '${rw}'" || true
	remote "$SERVER_HOST" "rm -rf '${rw}'" || true
}

prepare_ipvlan_lab() {
	export SERVER_UNDERLAY CLIENT_UNDERLAY
	export IPVLAN_NETWORK_NAME IPVLAN_SUBNET IPVLAN_GATEWAY IPVLAN_SERVER_IP IPVLAN_CLIENT_IP
	log_msg "Preparing ipvlan L3 lab (containers ${IPVLAN_SERVER_IP:-10.0.3.2} <-> ${IPVLAN_CLIENT_IP:-10.0.3.3}, vSwitch ${SERVER_UNDERLAY:-} -> ${CLIENT_UNDERLAY:-})"
	"${ONCACHE_DOCKER}/scripts/stop_all.sh" "${ONCACHE_CONF}" || true
	"${ONCACHE_DOCKER}/scripts/migrate_netperf_to_ipvlan.sh" "${ONCACHE_CONF}"
	"${ONCACHE_DOCKER}/scripts/verify_ipvlan_lab.sh" "${ONCACHE_CONF}"
}


verify_overlay_connectivity() {
	local ip="${SERVER_CONTAINER_IP:-}"
	if [[ -z "$ip" ]]; then
		ip="$(resolve_server_container_ip)"
		export SERVER_CONTAINER_IP="$ip"
	fi
	if remote "$CLIENT_HOST" "docker exec '${CLIENT_CONTAINER}' ping -c 1 -W 4 '${ip}'" >/dev/null 2>&1; then
		return 0
	fi
	log_msg "Overlay unreachable (${ip}); restoring ${OVERLAY_NETWORK:-bench-net} containers"
	"${ONCACHE_DOCKER}/scripts/restore_overlay_netperf.sh" "${ONCACHE_CONF}"
	export SERVER_CONTAINER_IP="$(resolve_server_container_ip)"
}

prepare_overlay_lab() {
	log_msg "Preparing Swarm overlay containers (bench-net)"
	"${ONCACHE_DOCKER}/scripts/ensure_overlay_lab.sh" "${ONCACHE_CONF}"
}

read_map_count() {
	local file="$1"
	local map_name="$2"
	local line
	line="$(grep -E "^map_${map_name}=" "$file" 2>/dev/null | tail -1 || true)"
	if [[ -z "$line" ]]; then
		echo 0
		return 0
	fi
	printf '%s' "${line#map_${map_name}=}"
}

fastpath_map_totals() {
	local phase="$1"
	local server_file="${ONCACHE_RESULT_DIR}/server_maps_${phase}.txt"
	local client_file="${ONCACHE_RESULT_DIR}/client_maps_${phase}.txt"
	local egress_total ingress_total
	egress_total="$(( $(read_map_count "$server_file" egress_cache) + $(read_map_count "$client_file" egress_cache) + $(read_map_count "$server_file" egressip_cache) + $(read_map_count "$client_file" egressip_cache) ))"
	ingress_total="$(( $(read_map_count "$server_file" ingress_cache) + $(read_map_count "$client_file" ingress_cache) ))"
	printf '%s %s\n' "$egress_total" "$ingress_total"
}

verify_fastpath_ready() {
	local phase="$1"
	local totals egress_total ingress_total
	totals="$(fastpath_map_totals "$phase")"
	read -r egress_total ingress_total <<<"$totals"
	if [[ "$egress_total" -lt "${ONCACHE_FASTPATH_MIN_EGRESS_CACHE:-1}" ]]; then
		printf '%s\n' "ONCache egress caches empty after ${phase} (total=${egress_total})" >&2
		return 1
	fi
	if [[ "$ingress_total" -lt 1 ]]; then
		printf '%s\n' "ONCache ingress_cache empty after ${phase}" >&2
		return 1
	fi
	printf '[%s] ONCache maps ready after %s: egress=%s ingress=%s\n' "$(date -u +%H:%M:%S)" "$phase" "$egress_total" "$ingress_total"
	return 0
}

snapshot_maps() {
	local phase="$1"
	mkdir -p "$ONCACHE_RESULT_DIR"
	remote_bash "$SERVER_HOST" <<EOF >"${ONCACHE_RESULT_DIR}/server_maps_${phase}.txt"
set -euo pipefail
for map_name in devmap ingress_cache egressip_cache egress_cache policy_cache; do
  c=\$(bpftool map dump pinned "/sys/fs/bpf/tc/globals/\${map_name}" 2>/dev/null | grep -c '^key:' || true)
  echo "map_\${map_name}=\${c}"
done
EOF
	remote_bash "$CLIENT_HOST" <<EOF >"${ONCACHE_RESULT_DIR}/client_maps_${phase}.txt"
set -euo pipefail
for map_name in devmap ingress_cache egressip_cache egress_cache policy_cache; do
  c=\$(bpftool map dump pinned "/sys/fs/bpf/tc/globals/\${map_name}" 2>/dev/null | grep -c '^key:' || true)
  echo "map_\${map_name}=\${c}"
done
EOF
}

warmup_oncache() {
	local w="${ONCACHE_WARMUP_SEC:-30}"
	local n="${ONCACHE_WARMUP_TCP_RR_WORKERS:-8}"
	if [[ "$w" -le 0 || "$n" -le 0 ]]; then
		return 0
	fi
	log_msg "ONCache warmup: ${n} TCP_RR x ${w}s"
	remote "$SERVER_HOST" "docker exec '${SERVER_CONTAINER}' pkill netserver 2>/dev/null || true"
	remote "$SERVER_HOST" "docker exec -d '${SERVER_CONTAINER}' netserver -D"
	sleep 1
	local i
	for i in $(seq 1 "$n"); do
		remote "$CLIENT_HOST" "docker exec '${CLIENT_CONTAINER}' netperf -H '${SERVER_CONTAINER_IP}' -p '${NETSERVER_PORT}' -t TCP_RR -l '${w}' -- -r '${REQUEST_SIZE},${RESPONSE_SIZE}'" >/dev/null 2>&1 &
	done
	wait
	snapshot_maps "warmup"
	if [[ "${REQUIRE_ONCACHE_FASTPATH:-1}" == "1" ]] && ! verify_fastpath_ready "warmup"; then
		exit 1
	fi
}

prepare_oncache_stack() {
	if [[ "${ONCACHE_REBUILD_ON_START:-1}" == "1" ]]; then
		local build_env
		if [[ "${IPVLAN_PREPARE_EACH_RUN:-0}" == "1" ]]; then
			log_msg "Sync + rebuild ONCache (ipvlan: ONCACHE_OVERLAY_FLAGS='' ONCACHE_IPVLAN_L3=1)"
			build_env="ONCACHE_OVERLAY_FLAGS='' ONCACHE_IPVLAN_L3=1"
		else
			log_msg "Sync + rebuild ONCache (Swarm overlay: SWARM_OVERLAY_SANDBOX + SWARM_OVERLAY_RESTORE)"
			build_env="ONCACHE_OVERLAY_FLAGS='-DSWARM_OVERLAY_SANDBOX -DSWARM_OVERLAY_RESTORE'"
		fi
		"${ONCACHE_DOCKER}/scripts/sync_to_hosts.sh" "${ONCACHE_CONF}"
		for host in "${SERVER_HOST}" "${CLIENT_HOST}"; do
			remote "$host" "env ${build_env} bash '${REMOTE_SETUP_DIR}/scripts/build_oncache.sh' '${REMOTE_ONCACHE_DIR}'"
		done
	fi
	if [[ "${RESTART_ONCACHE:-1}" == "1" ]]; then
		"${ONCACHE_DOCKER}/scripts/stop_all.sh" "${ONCACHE_CONF}" || true
	fi
	"${ONCACHE_DOCKER}/scripts/start_oncache.sh" "${ONCACHE_CONF}"
}

post_benchmark_oncache() {
	snapshot_maps "after"
	cat >"${ONCACHE_RESULT_DIR}/summary.txt" <<EOF
ONCache run ${RUN_ID}
Warmup: ${ONCACHE_WARMUP_SEC:-0}s x ${ONCACHE_WARMUP_TCP_RR_WORKERS:-0} workers
See server_maps_*.txt / client_maps_*.txt
EOF
}

if [[ "$REPARSE_ONLY" == "1" ]]; then
	if [[ ! -d "$RESULT_DIR" ]]; then
		echo "Result dir not found: $RESULT_DIR" >&2
		exit 1
	fi
	RUN_ID="$(basename "$RESULT_DIR")"
	RUN_MODE="$(basename "$(dirname "$RESULT_DIR")")"
	export RUN_MODE RUN_ID
	if [[ -f "$RESULT_DIR/config.snapshot" ]]; then
		export CONFIG_SNAPSHOT="$RESULT_DIR/config.snapshot"
	else
		export CONFIG_SNAPSHOT="$CONFIG_FILE"
	fi
	# shellcheck source=/dev/null
	source "${BENCH_ROOT}/benchmark_core.sh"
	write_summary
	exit 0
fi

sync_oncache_scripts_to_hosts() {
	log_msg "Syncing oncache-docker scripts to ${REMOTE_SETUP_DIR} on hosts"
	local _h
	for _h in "${SERVER_HOST}" "${CLIENT_HOST}"; do
		remote "${_h}" "mkdir -p '${REMOTE_SETUP_DIR}/scripts'"
		rsync -az "${ONCACHE_DOCKER}/scripts/" "${_h}:${REMOTE_SETUP_DIR}/scripts/"
	done
}

sync_oncache_scripts_to_hosts

clean_hosts
if [[ "${IPVLAN_PREPARE_EACH_RUN:-0}" == "1" ]]; then
	prepare_ipvlan_lab
elif [[ "${OVERLAY_PREPARE_EACH_RUN:-1}" == "1" ]]; then
	prepare_overlay_lab
fi

export SERVER_CONTAINER_IP
SERVER_CONTAINER_IP="$(resolve_server_container_ip)"
export SERVER_CONTAINER_IP

if [[ "${IPVLAN_PREPARE_EACH_RUN:-0}" != "1" && "${OVERLAY_PREPARE_EACH_RUN:-1}" == "1" ]]; then
	verify_overlay_connectivity
fi

if [[ "$RUN_MODE" == "oncache" ]]; then
	prepare_oncache_stack
	if [[ "${IPVLAN_PREPARE_EACH_RUN:-0}" != "1" ]]; then
		verify_overlay_connectivity
	fi
	mkdir -p "$RESULT_DIR" "$ONCACHE_RESULT_DIR"
	cp "$CONFIG_FILE" "$RESULT_DIR/config.snapshot"
	warmup_oncache
	remote "$CLIENT_HOST" "docker exec '${CLIENT_CONTAINER}' sh -c 'pkill -x netperf 2>/dev/null || true'" || true
	remote "$SERVER_HOST" "docker exec '${SERVER_CONTAINER}' pkill netserver 2>/dev/null || true"
	remote "$SERVER_HOST" "docker exec -d '${SERVER_CONTAINER}' netserver -D"
	sleep 1
else
	mkdir -p "$RESULT_DIR"
	cp "$CONFIG_FILE" "$RESULT_DIR/config.snapshot"
fi

# shellcheck source=/dev/null
source "${BENCH_ROOT}/benchmark_core.sh"
benchmark_main

if [[ "$RUN_MODE" == "oncache" ]]; then
	post_benchmark_oncache
fi

if [[ "$RUN_MODE" == "oncache" && "${STOP_ONCACHE_ON_EXIT:-0}" == "1" ]]; then
	"${ONCACHE_DOCKER}/scripts/stop_all.sh" "${ONCACHE_CONF}" || true
fi

printf '%s\n' "Results: $RESULT_DIR"
