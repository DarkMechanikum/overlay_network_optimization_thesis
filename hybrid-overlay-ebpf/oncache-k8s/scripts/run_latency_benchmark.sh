#!/usr/bin/env bash
# Latency-first benchmark runner: baseline overlay vs ONCache on Kubernetes+Antrea.
# Records hot (TCP_RR) and cold (TCP_CRR) flows separately in summary.csv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONFIG_FILE="${1:-${SETUP_ROOT}/conf/oncache_k8s_setup.conf}"
BENCH_CONF="${2:-${SETUP_ROOT}/conf/latency_benchmark.conf}"
load_config "${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${BENCH_CONF}"

HOT_NETPERF_TEST="${HOT_NETPERF_TEST:-${NETPERF_TEST:-TCP_RR}}"
COLD_NETPERF_TEST="${COLD_NETPERF_TEST:-TCP_CRR}"
BENCHMARK_FLOW_TYPES="${BENCHMARK_FLOW_TYPES:-hot cold}"
BENCHMARK_MODES="${BENCHMARK_MODES:-baseline oncache falcon hybrid}"
COLD_RUN_TIMEOUT_EXTRA_SEC="${COLD_RUN_TIMEOUT_EXTRA_SEC:-60}"

HYBRID_ROOT="${HYBRID_ROOT:-$(cd "${SETUP_ROOT}/../oncache-falcon-hybrid" && pwd)}"
HYBRID_SCRIPT_DIR="${HYBRID_ROOT}/scripts"
HYBRID_CONF="${HYBRID_CONF:-${HYBRID_ROOT}/conf/falcon_fallback.conf}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OVERLAY_STRESS_ENABLE="${OVERLAY_STRESS_ENABLE:-0}"
CPU_STRESS_ENABLE="${CPU_STRESS_ENABLE:-0}"
RESULT_DIR="${RESULT_ROOT}/${RUN_ID}"
mkdir -p "${RESULT_DIR}"

cleanup_overlay_stress() {
	if [[ "${OVERLAY_STRESS_ENABLE}" == "1" ]]; then
		"${SCRIPT_DIR}/teardown_overlay_stress.sh" "${CONFIG_FILE}" || true
	fi
}

cleanup_cpu_stress() {
	if [[ "${CPU_STRESS_ENABLE}" == "1" ]]; then
		"${SCRIPT_DIR}/teardown_cpu_stress.sh" "${CONFIG_FILE}" || true
	fi
}

cleanup_benchmark() {
	cleanup_cpu_stress
	cleanup_overlay_stress
}

if [[ "${OVERLAY_STRESS_ENABLE}" == "1" || "${CPU_STRESS_ENABLE}" == "1" ]]; then
	trap cleanup_benchmark EXIT
fi

if [[ "${CPU_STRESS_ENABLE}" == "1" ]]; then
	log "Applying CPU stress (stress-ng load=${CPU_STRESS_LOAD:-70}% workers=${CPU_STRESS_WORKERS:-auto})"
	"${SCRIPT_DIR}/apply_cpu_stress.sh" "${CONFIG_FILE}"
	if [[ "${CPU_STRESS_SKIP_VERIFY:-0}" != "1" ]]; then
		"${SCRIPT_DIR}/verify_cpu_stress.sh" "${CONFIG_FILE}" || {
			echo "CPU stress verification failed." >&2
			exit 1
		}
	fi
	{
		echo "host=${SERVER_HOST}"
		remote "${SERVER_HOST}" "cat /proc/loadavg; pgrep -c stress-ng || true"
	} >"${RESULT_DIR}/loadavg_server1.txt" 2>/dev/null || true
	{
		echo "host=${CLIENT_HOST}"
		remote "${CLIENT_HOST}" "cat /proc/loadavg; pgrep -c stress-ng || true"
	} >"${RESULT_DIR}/loadavg_client.txt" 2>/dev/null || true
fi

if [[ "${OVERLAY_STRESS_ENABLE}" == "1" ]]; then
	log "Applying overlay stress (MTU=${OVERLAY_STRESS_MTU:-1280}, policies=${OVERLAY_STRESS_POLICY_COUNT:-150})"
	"${SCRIPT_DIR}/apply_overlay_stress.sh" "${CONFIG_FILE}"
	if [[ "${OVERLAY_STRESS_SKIP_VERIFY:-0}" != "1" ]]; then
		"${SCRIPT_DIR}/verify_overlay_stress.sh" "${CONFIG_FILE}" || {
			echo "Overlay stress verification failed." >&2
			exit 1
		}
	fi
fi

CSV_FILE="${RESULT_DIR}/summary.csv"
cat >"${CSV_FILE}" <<'EOF'
run_id,mode,flow_type,netperf_test,workers,repeat,ok,failed,total_txn_s,avg_latency_ms,p50_latency_ms,p95_latency_ms,p99_latency_ms
EOF

log "Preparing benchmark run_id=${RUN_ID} flow_types=${BENCHMARK_FLOW_TYPES}"
"${SCRIPT_DIR}/check_prerequisites.sh" "${CONFIG_FILE}"
remote "${MASTER_HOST}" "kubectl get pods -n '${NAMESPACE}' '${SERVER_POD}' '${CLIENT_POD}' -o wide"

SERVER_POD_IP="$(kubectl_remote "get pod '${SERVER_POD}' -o jsonpath='{.status.podIP}'")"
if [[ -z "${SERVER_POD_IP}" ]]; then
	echo "Could not resolve ${SERVER_POD} pod IP" >&2
	exit 1
fi
log "Server pod IP: ${SERVER_POD_IP}"

NETPERF_PROBE_TIMEOUT="${NETPERF_PROBE_TIMEOUT:-20}"
NETPERF_RUN_TIMEOUT="${NETPERF_RUN_TIMEOUT:-$(( DURATION_SEC + 60 ))}"

netperf_test_for_flow() {
	case "$1" in
	hot) printf '%s' "${HOT_NETPERF_TEST}" ;;
	cold) printf '%s' "${COLD_NETPERF_TEST}" ;;
	*)
		echo "Unknown flow_type: $1 (expected hot or cold)" >&2
		return 1
		;;
	esac
}

run_timeout_for_flow() {
	local flow_type="$1"
	local duration="$2"
	local base="${NETPERF_RUN_TIMEOUT:-$(( duration + 60 ))}"
	if [[ "${flow_type}" == "cold" ]]; then
		echo $(( base + COLD_RUN_TIMEOUT_EXTRA_SEC ))
	else
		echo "${base}"
	fi
}

start_netserver() {
	kubectl_remote_timeout 30 \
		"exec '${SERVER_POD}' -- sh -c 'pkill netserver 2>/dev/null || true; netserver -D </dev/null >/dev/null 2>&1 & sleep 1; pgrep -x netserver >/dev/null || true'" \
		|| true
}

wait_for_netserver() {
	local tries="${1:-15}"
	local i
	for i in $(seq 1 "${tries}"); do
		log "netserver probe ${i}/${tries} -> ${SERVER_POD_IP}:12865 (${HOT_NETPERF_TEST})"
		if kubectl_remote_timeout "${NETPERF_PROBE_TIMEOUT}" \
			"exec '${CLIENT_POD}' -- sh -lc \"netperf -H '${SERVER_POD_IP}' -p 12865 -t '${HOT_NETPERF_TEST}' -l 1 -- -r 64,64 -o '${NETPERF_OUTPUT_FIELDS}'\"" \
			>/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	echo "netserver did not become ready on ${SERVER_POD_IP}:12865" >&2
	return 1
}

run_parallel_netperf() {
	local workers="$1"
	local duration="$2"
	local outdir="$3"
	local netperf_test="$4"
	local run_timeout="$5"
	log "netperf test=${netperf_test} workers=${workers} duration=${duration}s timeout=${run_timeout}s"
	remote_bash "${MASTER_HOST}" <<EOF
set -euo pipefail
mkdir -p '${outdir}'
for i in \$(seq 1 ${workers}); do
  (
    timeout --foreground ${run_timeout} kubectl -n '${NAMESPACE}' exec '${CLIENT_POD}' -- sh -lc \
      "netperf -H '${SERVER_POD_IP}' -t '${netperf_test}' -l '${duration}' -- -r '${REQUEST_SIZE},${RESPONSE_SIZE}' -o '${NETPERF_OUTPUT_FIELDS}'" \
      >'${outdir}/worker_'\$i'.log' 2>&1 || echo "worker \$i exit=\$?" >>'${outdir}/worker_'\$i'.log'
  ) &
done
wait || true
EOF
}

parse_logs() {
	local log_dir="$1"
	remote "${MASTER_HOST}" "python3 -c '
import glob, os
from statistics import mean

def pct(vals, p):
    vals = sorted(vals)
    if not vals: return float(\"nan\")
    if len(vals) == 1: return vals[0]
    k = (len(vals)-1)*(p/100.0); lo = int(k); hi = min(lo+1,len(vals)-1)
    return vals[lo]*(1-(k-lo)) + vals[hi]*(k-lo)

ok = failed = 0; rates = []; lats = []
for p in sorted(glob.glob(os.path.join(\"${log_dir}\", \"*.log\"))):
    line = \"\"
    with open(p, \"r\", errors=\"ignore\") as f:
        for raw in f:
            raw = raw.strip()
            if raw and raw[0].isdigit() and \",\" in raw: line = raw
    if not line: failed += 1; continue
    try: lat_us, rate = [float(x) for x in line.split(\",\")[:2]]
    except Exception: failed += 1; continue
    if lat_us <= 0 or rate <= 0: failed += 1; continue
    ok += 1; rates.append(rate); lats.append(lat_us/1000.0)

if ok == 0: print(\"0,0,0,0,0,0,0\")
else: print(f\"{ok},{failed},{sum(rates):.6f},{mean(lats):.6f},{pct(lats,50):.6f},{pct(lats,95):.6f},{pct(lats,99):.6f}\")
'"
}

count_map_entries() {
	local host="$1"
	local map="$2"
	remote "${host}" "sudo bpftool map dump name ${map} 2>/dev/null | awk '/^key:/{c++} END{print c+0}'"
}

check_oncache_maps() {
	local se ci si ii
	se="$(count_map_entries "${SERVER_HOST}" egress_cache)"
	si="$(count_map_entries "${SERVER_HOST}" ingress_cache)"
	ci="$(count_map_entries "${CLIENT_HOST}" egress_cache)"
	ii="$(count_map_entries "${CLIENT_HOST}" ingress_cache)"
	sp="$(count_map_entries "${SERVER_HOST}" policy_cache)"
	cp="$(count_map_entries "${CLIENT_HOST}" policy_cache)"
	log "Map entries: server(egress=${se},ingress=${si},policy=${sp}) client(egress=${ci},ingress=${ii},policy=${cp})"
	if [[ "${REQUIRE_MAP_WARMUP}" == "1" ]]; then
		if [[ "${se}" -lt "${MIN_EGRESS_ENTRIES}" || "${ci}" -lt "${MIN_EGRESS_ENTRIES}" ]]; then
			echo "ONCache egress_cache not warm enough" >&2
			return 1
		fi
		if [[ "${si}" -lt "${MIN_INGRESS_ENTRIES}" || "${ii}" -lt "${MIN_INGRESS_ENTRIES}" ]]; then
			echo "ONCache ingress_cache not warm enough" >&2
			return 1
		fi
	fi
	return 0
}

setup_mode() {
	local mode="$1"
	case "${mode}" in
	baseline)
		"${SCRIPT_DIR}/stop_oncache.sh" "${CONFIG_FILE}" || true
		"${HYBRID_SCRIPT_DIR}/revert_falcon_fallback.sh" "${CONFIG_FILE}" "${HYBRID_CONF}" || true
		;;
	oncache)
		"${SCRIPT_DIR}/start_oncache.sh" "${CONFIG_FILE}"
		"${HYBRID_SCRIPT_DIR}/revert_falcon_fallback.sh" "${CONFIG_FILE}" "${HYBRID_CONF}" || true
		;;
	falcon)
		"${SCRIPT_DIR}/stop_oncache.sh" "${CONFIG_FILE}" || true
		"${HYBRID_SCRIPT_DIR}/apply_falcon_fallback.sh" "${CONFIG_FILE}" "${HYBRID_CONF}"
		;;
	hybrid)
		"${HYBRID_SCRIPT_DIR}/start_hybrid.sh" "${CONFIG_FILE}" "${HYBRID_CONF}"
		;;
	*)
		echo "Unknown mode: ${mode} (expected baseline, oncache, falcon, hybrid)" >&2
		exit 1
		;;
	esac
}

run_mode() {
	local mode="$1"
	log "=== Mode: ${mode} ==="
	setup_mode "${mode}"
	start_netserver
	wait_for_netserver
	sleep 2

	if [[ "${mode}" == "oncache" || "${mode}" == "hybrid" ]]; then
		local warmdir="${RESULT_DIR}/${mode}/warmup/hot"
		run_parallel_netperf 8 "${WARMUP_SEC}" "${warmdir}" "${HOT_NETPERF_TEST}" "$(run_timeout_for_flow hot "${WARMUP_SEC}")"
		check_oncache_maps
	fi

	local flow_type netperf_test workers rep run_dir run_timeout stats ok failed txn avg p50 p95 p99
	for flow_type in ${BENCHMARK_FLOW_TYPES}; do
		netperf_test="$(netperf_test_for_flow "${flow_type}")"
		run_timeout="$(run_timeout_for_flow "${flow_type}" "${DURATION_SEC}")"
		for workers in ${WORKER_COUNTS}; do
			for rep in $(seq 1 "${REPEATS}"); do
				run_dir="${RESULT_DIR}/${mode}/${flow_type}/w${workers}/r${rep}"
				log "Running ${mode} flow=${flow_type} test=${netperf_test} workers=${workers} repeat=${rep}"
				run_parallel_netperf "${workers}" "${DURATION_SEC}" "${run_dir}" "${netperf_test}" "${run_timeout}"
				stats="$(parse_logs "${run_dir}")" || stats="0,0,0,0,0,0,0"
				IFS=',' read -r ok failed txn avg p50 p95 p99 <<<"${stats}"
				echo "${RUN_ID},${mode},${flow_type},${netperf_test},${workers},${rep},${ok},${failed},${txn},${avg},${p50},${p95},${p99}" >>"${CSV_FILE}"
			done
		done
	done
}

log "Running benchmark modes: ${BENCHMARK_MODES}"
for mode in ${BENCHMARK_MODES}; do
	run_mode "${mode}"
done

# Best-effort cleanup so the cluster ends in baseline state even after a
# hybrid/falcon mode run.
"${HYBRID_SCRIPT_DIR}/revert_falcon_fallback.sh" "${CONFIG_FILE}" "${HYBRID_CONF}" || true

log "Benchmark complete: ${RESULT_DIR}"
cat "${CSV_FILE}"
