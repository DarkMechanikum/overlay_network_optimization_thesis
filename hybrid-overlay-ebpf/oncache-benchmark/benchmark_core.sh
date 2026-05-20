#!/usr/bin/env bash
# Mixed hot/cold netperf core (sourced by run_mixed_netperf.sh after config).
# Expects: SERVER_HOST, CLIENT_HOST, SERVER_CONTAINER, CLIENT_CONTAINER,
# SERVER_CONTAINER_IP, HOT_WORKERS, COLD_WORKERS, DURATION_SEC, WARMUP_SEC,
# REQUEST_SIZE, RESPONSE_SIZE, NETSERVER_PORT, NETPERF_OUTPUT_FIELDS,
# LATENCY_MIN_TXN_RATE_HOT, LATENCY_MIN_TXN_RATE_COLD, RUN_ID, RESULT_DIR,
# REMOTE_WORKDIR, SSH_OPTS, MEASURE_LINK_LIMIT, COLLECT_SOFTIRQS, RUN_MODE, etc.

# REMOTE_WORKDIR set by run_mixed_netperf.sh when empty.

: "${RUN_MODE:-baseline}"
: "${NETPERF_OUTPUT_FIELDS:?}"
: "${LATENCY_MIN_TXN_RATE_HOT:?}"
: "${LATENCY_MIN_TXN_RATE_COLD:?}"

REMOTE_WORKDIR=${REMOTE_WORKDIR:-"/tmp/oncache_mixed_netperf_${RUN_ID}"}
HOT_START_BATCH_SIZE=${HOT_START_BATCH_SIZE:-128}
COLD_START_BATCH_SIZE=${COLD_START_BATCH_SIZE:-128}
BATCH_SLEEP_SEC=${BATCH_SLEEP_SEC:-0.2}
CPU_SAMPLE_INTERVAL=${CPU_SAMPLE_INTERVAL:-1}
COLLECT_SOFTIRQS=${COLLECT_SOFTIRQS:-1}
NETPERF_EXTRA_ARGS=${NETPERF_EXTRA_ARGS:-""}
SERVER_NET_IFACE=${SERVER_NET_IFACE:-""}
CLIENT_NET_IFACE=${CLIENT_NET_IFACE:-""}
MEASURE_LINK_LIMIT=${MEASURE_LINK_LIMIT:-0}
IPERF3_PORT=${IPERF3_PORT:-5202}
IPERF3_DURATION_SEC=${IPERF3_DURATION_SEC:-10}
IPERF3_PARALLEL=${IPERF3_PARALLEL:-4}
LINK_LIMIT_GBPS_OVERRIDE=${LINK_LIMIT_GBPS_OVERRIDE:-""}
LINK_LIMIT_GBPS=${LINK_LIMIT_GBPS:-nan}

log() {
	printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

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

check_prerequisites() {
	log "Checking SSH, Docker, and netperf prerequisites"
	remote "$SERVER_HOST" "command -v docker >/dev/null && docker ps >/dev/null"
	remote "$CLIENT_HOST" "command -v docker >/dev/null && docker ps >/dev/null"
	remote "$SERVER_HOST" "docker inspect '$SERVER_CONTAINER' >/dev/null"
	remote "$CLIENT_HOST" "docker inspect '$CLIENT_CONTAINER' >/dev/null"
	remote "$SERVER_HOST" "docker exec '$SERVER_CONTAINER' sh -c 'command -v netserver >/dev/null'"
	remote "$CLIENT_HOST" "docker exec '$CLIENT_CONTAINER' sh -c 'command -v netperf >/dev/null'"
	remote "$SERVER_HOST" "command -v mpstat >/dev/null || echo 'WARN: install sysstat for mpstat'"
	remote "$CLIENT_HOST" "command -v mpstat >/dev/null || echo 'WARN: install sysstat for mpstat'"
	if [[ "$MEASURE_LINK_LIMIT" == "1" && -z "$LINK_LIMIT_GBPS_OVERRIDE" ]]; then
		remote "$SERVER_HOST" "docker exec '$SERVER_CONTAINER' sh -c 'command -v iperf3 >/dev/null'" || echo "WARN: iperf3 missing in server container"
		remote "$CLIENT_HOST" "docker exec '$CLIENT_CONTAINER' sh -c 'command -v iperf3 >/dev/null'" || echo "WARN: iperf3 missing in client container"
	fi
}

prepare_remote_dirs() {
	log "Preparing remote work directories"
	remote "$CLIENT_HOST" "rm -rf '$REMOTE_WORKDIR'; mkdir -p '$REMOTE_WORKDIR/hot' '$REMOTE_WORKDIR/cold' '$REMOTE_WORKDIR/cpu' '$REMOTE_WORKDIR/net'"
	remote "$SERVER_HOST" "rm -rf '$REMOTE_WORKDIR'; mkdir -p '$REMOTE_WORKDIR/cpu' '$REMOTE_WORKDIR/net'"
}

start_netserver() {
	log "Starting netserver on ${SERVER_HOST}:${SERVER_CONTAINER}"
	remote "$SERVER_HOST" "
		docker exec '$SERVER_CONTAINER' pkill netserver 2>/dev/null || true
		docker exec -d '$SERVER_CONTAINER' netserver -D
	"
	sleep 1
}

wait_for_netserver() {
	local attempt
	for attempt in $(seq 1 30); do
		if remote "$CLIENT_HOST" "docker exec '$CLIENT_CONTAINER' netperf -H '$SERVER_CONTAINER_IP' -p '$NETSERVER_PORT' -t TCP_RR -l 1 -- -r '${REQUEST_SIZE},${RESPONSE_SIZE}'" >/dev/null 2>&1; then
			log "netserver ready on ${SERVER_CONTAINER_IP}:${NETSERVER_PORT}"
			return 0
		fi
		sleep 1
	done
	echo "netserver did not become ready" >&2
	return 1
}

start_cpu_collection() {
	local host="$1"
	local label="$2"
	log "Starting CPU collection on $label ($host)"
	remote_bash "$host" <<EOF_REMOTE
set -euo pipefail
mkdir -p '$REMOTE_WORKDIR/cpu'
if command -v mpstat >/dev/null; then
  mpstat -P ALL '$CPU_SAMPLE_INTERVAL' > '$REMOTE_WORKDIR/cpu/${label}_mpstat.log' 2>&1 &
  echo \$! > '$REMOTE_WORKDIR/cpu/${label}_mpstat.pid'
else
  echo 'mpstat not found' > '$REMOTE_WORKDIR/cpu/${label}_mpstat.log'
  echo '' > '$REMOTE_WORKDIR/cpu/${label}_mpstat.pid'
fi
if [[ '$COLLECT_SOFTIRQS' == '1' ]]; then
  cat /proc/softirqs > '$REMOTE_WORKDIR/cpu/${label}_softirqs_before.txt'
fi
EOF_REMOTE
}

stop_cpu_collection() {
	local host="$1"
	local label="$2"
	log "Stopping CPU collection on $label ($host)"
	remote_bash "$host" <<EOF_REMOTE || true
set +e
PID_FILE='${REMOTE_WORKDIR}/cpu/${label}_mpstat.pid'
if [[ -s "\$PID_FILE" ]]; then
  kill "\$(cat "\$PID_FILE")" 2>/dev/null || true
  sleep 1
fi
if [[ '${COLLECT_SOFTIRQS}' == '1' ]]; then
  cat /proc/softirqs > '${REMOTE_WORKDIR}/cpu/${label}_softirqs_after.txt'
fi
EOF_REMOTE
}

detect_net_iface() {
	local host="$1"
	local configured="$2"
	if [[ -n "$configured" ]]; then
		echo "$configured"
		return 0
	fi
	remote "$host" "ip route show default 2>/dev/null | awk '{print \$5; exit}'"
}

start_netdev_collection() {
	local host="$1"
	local label="$2"
	local iface="$3"
	remote_bash "$host" <<EOF_REMOTE
set -euo pipefail
mkdir -p '$REMOTE_WORKDIR/net'
echo '$iface' > '$REMOTE_WORKDIR/net/${label}_iface.txt'
date +%s.%N > '$REMOTE_WORKDIR/net/${label}_netdev_before_ts.txt'
cat /proc/net/dev > '$REMOTE_WORKDIR/net/${label}_netdev_before.txt'
EOF_REMOTE
}

stop_netdev_collection() {
	local host="$1"
	local label="$2"
	remote_bash "$host" <<EOF_REMOTE || true
set +e
mkdir -p '$REMOTE_WORKDIR/net'
date +%s.%N > '$REMOTE_WORKDIR/net/${label}_netdev_after_ts.txt'
cat /proc/net/dev > '$REMOTE_WORKDIR/net/${label}_netdev_after.txt'
EOF_REMOTE
}

measure_link_limit() {
	LINK_LIMIT_GBPS="nan"
	if [[ -n "$LINK_LIMIT_GBPS_OVERRIDE" ]]; then
		LINK_LIMIT_GBPS="$LINK_LIMIT_GBPS_OVERRIDE"
		log "Link limit override: ${LINK_LIMIT_GBPS} Gbps"
		return 0
	fi
	if [[ "$MEASURE_LINK_LIMIT" != "1" ]]; then
		log "Skipping iperf3 link ceiling test"
		return 0
	fi
	if ! remote "$SERVER_HOST" "docker exec '$SERVER_CONTAINER' sh -c 'command -v iperf3 >/dev/null'" >/dev/null 2>&1; then
		log "iperf3 missing; link limit nan"
		return 0
	fi
	remote "$SERVER_HOST" "docker exec '$SERVER_CONTAINER' sh -c 'pkill iperf3 2>/dev/null || true; iperf3 -s -p $IPERF3_PORT -1 >/tmp/iperf3_link_server.log 2>&1 &'"
	sleep 1
	local iperf_json="$RESULT_DIR/net/iperf3_link_limit.json"
	mkdir -p "$RESULT_DIR/net"
	if remote "$CLIENT_HOST" "docker exec '$CLIENT_CONTAINER' iperf3 -J -c '$SERVER_CONTAINER_IP' -p '$IPERF3_PORT' -t '$IPERF3_DURATION_SEC' -P '$IPERF3_PARALLEL'" >"$iperf_json" 2>"$RESULT_DIR/net/iperf3_link_limit.err"; then
		LINK_LIMIT_GBPS=$(python3 - "$iperf_json" <<'PY_IPERF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
    end = data.get("end", {})
    bps = None
    for key in ("sum_received", "sum", "sum_sent"):
        if isinstance(end.get(key), dict) and "bits_per_second" in end[key]:
            bps = float(end[key]["bits_per_second"])
            break
    if bps is None:
        vals = []
        for st in end.get("streams", []):
            r = st.get("receiver") or st.get("sender") or {}
            if "bits_per_second" in r:
                vals.append(float(r["bits_per_second"]))
        bps = sum(vals) if vals else None
    print(f"{bps/1e9:.6f}" if bps else "nan")
except Exception:
    print("nan")
PY_IPERF
)
		log "Measured iperf3 link ceiling: ${LINK_LIMIT_GBPS} Gbps"
	else
		LINK_LIMIT_GBPS="nan"
	fi
}

parse_netdev_rate() {
	local iface_file="$1"
	local before_file="$2"
	local after_file="$3"
	local before_ts_file="$4"
	local after_ts_file="$5"
	python3 - "$iface_file" "$before_file" "$after_file" "$before_ts_file" "$after_ts_file" <<'PY_NETDEV'
import sys
iface_file, before_file, after_file, before_ts_file, after_ts_file = sys.argv[1:6]

def read_iface(path):
    try:
        return open(path).read().strip()
    except Exception:
        return ""

def read_ts(path):
    try:
        return float(open(path).read().strip())
    except Exception:
        return None

def read_netdev(path, iface):
    try:
        with open(path) as f:
            for line in f:
                if ":" not in line:
                    continue
                name, rest = line.split(":", 1)
                if name.strip() == iface:
                    vals = rest.split()
                    rx = int(vals[0])
                    tx = int(vals[8])
                    return rx, tx
    except Exception:
        pass
    return None

iface = read_iface(iface_file)
t0 = read_ts(before_ts_file)
t1 = read_ts(after_ts_file)
b = read_netdev(before_file, iface)
a = read_netdev(after_file, iface)
if not iface or t0 is None or t1 is None or not b or not a or t1 <= t0:
    print("nan,nan,nan")
    sys.exit(0)
rx_bps = max(0, a[0] - b[0]) * 8.0 / (t1 - t0)
tx_bps = max(0, a[1] - b[1]) * 8.0 / (t1 - t0)
print(f"{rx_bps/1e9:.6f},{tx_bps/1e9:.6f},{max(rx_bps, tx_bps)/1e9:.6f}")
PY_NETDEV
}

launch_workers() {
	local kind="$1"
	local count="$2"
	local test_type="$3"
	local batch_size="$4"
	local remote_dir="$REMOTE_WORKDIR/$kind"
	log "Launching $count $kind workers ($test_type) on $CLIENT_HOST"
	if [[ "$kind" == "hot" ]]; then
		remote "$CLIENT_HOST" "docker exec '$CLIENT_CONTAINER' sh -c 'pkill -x netperf 2>/dev/null || true'"
	fi
	remote_bash "$CLIENT_HOST" <<EOF_REMOTE
set -euo pipefail
mkdir -p '$remote_dir'
for i in \$(seq 1 '$count'); do
  id=\$(printf '%04d' "\$i")
  (
    docker exec '$CLIENT_CONTAINER' \
      netperf -H '$SERVER_CONTAINER_IP' \
      -p '$NETSERVER_PORT' \
      -t '$test_type' \
      -l '$DURATION_SEC' \
      $NETPERF_EXTRA_ARGS \
      -- -r '${REQUEST_SIZE},${RESPONSE_SIZE}' \
      -o '${NETPERF_OUTPUT_FIELDS}' \
      > '$remote_dir/${kind}_'"\$id"'.log' 2>&1
  ) &
  if (( i % ${batch_size} == 0 )); then
    sleep ${BATCH_SLEEP_SEC}
  fi
done
if [[ '${kind}' == 'cold' ]]; then
  wait
  sleep 1
fi
EOF_REMOTE
}

wait_for_client_workers() {
	log "Waiting for client-side netperf workers to finish"
	local remaining waited=0
	local max_wait=$((DURATION_SEC + WARMUP_SEC + 120))
	while true; do
		remaining=$(remote "$CLIENT_HOST" "docker exec '$CLIENT_CONTAINER' sh -c 'pgrep -x netperf 2>/dev/null | wc -l'" | tr -d '[:space:]')
		if [[ -z "$remaining" || "$remaining" == "0" ]]; then
			log "All netperf workers finished"
			sleep 2
			break
		fi
		if (( waited >= max_wait )); then
			log "Timeout; killing netperf on client"
			remote "$CLIENT_HOST" "docker exec '$CLIENT_CONTAINER' sh -c 'pkill -x netperf 2>/dev/null || true'" || true
			break
		fi
		log "Still running netperf workers: $remaining"
		sleep 5
		waited=$((waited + 5))
	done
}

collect_logs() {
	log "Packing logs on remote hosts"
	remote "$CLIENT_HOST" "cd '$REMOTE_WORKDIR' && tar -czf hot_logs.tar.gz hot && tar -czf cold_logs.tar.gz cold && tar -czf client_cpu_logs.tar.gz cpu"
	remote "$SERVER_HOST" "cd '$REMOTE_WORKDIR' && tar -czf server_cpu_logs.tar.gz cpu"
	scp $SSH_OPTS "$CLIENT_HOST:$REMOTE_WORKDIR/hot_logs.tar.gz" "$RESULT_DIR/" >/dev/null
	scp $SSH_OPTS "$CLIENT_HOST:$REMOTE_WORKDIR/cold_logs.tar.gz" "$RESULT_DIR/" >/dev/null
	scp $SSH_OPTS "$CLIENT_HOST:$REMOTE_WORKDIR/client_cpu_logs.tar.gz" "$RESULT_DIR/" >/dev/null || true
	scp $SSH_OPTS "$SERVER_HOST:$REMOTE_WORKDIR/server_cpu_logs.tar.gz" "$RESULT_DIR/" >/dev/null || true
	mkdir -p "$RESULT_DIR/hot" "$RESULT_DIR/cold" "$RESULT_DIR/cpu/client"
	tar -xzf "$RESULT_DIR/hot_logs.tar.gz" -C "$RESULT_DIR"
	tar -xzf "$RESULT_DIR/cold_logs.tar.gz" -C "$RESULT_DIR"
	mkdir -p "$RESULT_DIR/_server_cpu_extract" "$RESULT_DIR/_client_cpu_extract"
	if [[ -f "$RESULT_DIR/server_cpu_logs.tar.gz" ]]; then
		tar -xzf "$RESULT_DIR/server_cpu_logs.tar.gz" -C "$RESULT_DIR/_server_cpu_extract"
		cp -a "$RESULT_DIR/_server_cpu_extract/cpu/." "$RESULT_DIR/cpu/" || true
	fi
	if [[ -f "$RESULT_DIR/client_cpu_logs.tar.gz" ]]; then
		tar -xzf "$RESULT_DIR/client_cpu_logs.tar.gz" -C "$RESULT_DIR/_client_cpu_extract"
		mkdir -p "$RESULT_DIR/cpu/client"
		cp -a "$RESULT_DIR/_client_cpu_extract/cpu/." "$RESULT_DIR/cpu/client/" || true
	fi
	rm -rf "$RESULT_DIR/_server_cpu_extract" "$RESULT_DIR/_client_cpu_extract"
}

summarize_group() {
	local dir="$1"
	local expected_count="$2"
	local rates_file="$3"
	local kind="${4:-hot}"
	local min_rate="$LATENCY_MIN_TXN_RATE_HOT"
	if [[ "$kind" == "cold" ]]; then
		min_rate="$LATENCY_MIN_TXN_RATE_COLD"
	fi
	local latencies_file
	if [[ "$rates_file" == *_rates.txt ]]; then
		latencies_file="${rates_file%_rates.txt}_latencies_ms.txt"
	else
		latencies_file="${rates_file%.txt}_latencies_ms.txt"
	fi
	python3 - "$dir" "$rates_file" "$latencies_file" "$min_rate" <<'PY'
import glob
import re
import sys

log_dir, rates_path, latencies_path, min_rate = sys.argv[1:5]
min_rate = float(min_rate)
csv_data_re = re.compile(r"^[\d.]+\,\s*[\d.]+")

def nan_fields(n):
    return ",".join(["nan"] * n)

def percentile(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = k - lo
    return sorted_vals[lo] * (1.0 - frac) + sorted_vals[hi] * frac

def parse_netperf_csv_log(path):
    mean_lat_us = rate = None
    has_error = False
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("netperf:") or "command terminated" in line:
                has_error = True
                continue
            if "Latency" in line or "TRANSACTION" in line.upper():
                continue
            if csv_data_re.match(line):
                parts = [p.strip() for p in line.split(",")]
                if len(parts) >= 2:
                    try:
                        mean_lat_us = float(parts[0])
                        rate = float(parts[1])
                    except ValueError:
                        pass
    return mean_lat_us, rate, has_error

rates = []
latencies = []
ok = failed = latency_ok = latency_excluded = 0

for path in sorted(glob.glob(f"{log_dir}/*.log")):
    mean_lat_us, rate, has_error = parse_netperf_csv_log(path)
    if rate is None or rate <= 0 or mean_lat_us is None or mean_lat_us <= 0:
        failed += 1
        continue
    ok += 1
    rates.append(rate)
    latency_ms = mean_lat_us / 1000.0
    if not has_error and rate >= min_rate:
        latency_ok += 1
        latencies.append(latency_ms)
    else:
        latency_excluded += 1

with open(rates_path, "w") as f:
    for value in rates:
        f.write(f"{value:.6f}\n")

with open(latencies_path, "w") as f:
    for value in latencies:
        f.write(f"{value:.6f}\n")

total = sum(rates)
if latencies:
    latencies.sort()
    lat_stats = (
        f"{sum(latencies) / len(latencies):.6f},"
        f"{min(latencies):.6f},"
        f"{max(latencies):.6f},"
        f"{percentile(latencies, 50):.6f},"
        f"{percentile(latencies, 95):.6f},"
        f"{percentile(latencies, 99):.6f}"
    )
else:
    lat_stats = nan_fields(6)

print(
    f"{ok},{failed},{total:.6f},{latency_ok},{latency_excluded},{lat_stats}"
)
PY
}

parse_cpu_imbalance() {
	local file="$1"
	awk '
    $1 ~ /^[0-9]+:[0-9]+:[0-9]+$/ {
      if ($2 == "AM" || $2 == "PM") { cpu=$3; idle=$NF }
      else { cpu=$2; idle=$NF }
      if (cpu ~ /^[0-9]+$/) {
        busy = 100.0 - idle
        sum[cpu] += busy
        count[cpu] += 1
      }
    }
    END {
      n = 0; total = 0; max = 0
      for (cpu in sum) {
        avg = sum[cpu] / count[cpu]
        total += avg
        n += 1
        if (avg > max) max = avg
      }
      if (n > 0 && total > 0) printf "%.6f", max / (total / n)
      else printf "nan"
    }
  ' "$file"
}

softirq_imbalance() {
	local before="$1"
	local after="$2"
	local line_name="$3"
	if [[ ! -s "$before" || ! -s "$after" ]]; then
		echo "nan"
		return
	fi
	python3 - "$before" "$after" "$line_name" <<'PY'
import sys

before, after, name = sys.argv[1:4]

def read(path):
    with open(path) as f:
        for line in f:
            if line.strip().startswith(name + ":"):
                return [int(x) for x in line.split(":", 1)[1].split()]
    return []

b = read(before)
a = read(after)
if not b or not a or len(a) != len(b):
    print("nan")
    sys.exit(0)
d = [max(0, x - y) for x, y in zip(a, b)]
active = [x for x in d if x > 0]
if not active:
    print("nan")
else:
    avg = sum(active) / len(active)
    print(f"{max(active)/avg:.6f}" if avg else "nan")
PY
}

write_summary() {
	log "Parsing benchmark results"
	local hot_summary cold_summary
	hot_summary=$(summarize_group "$RESULT_DIR/hot" "$HOT_WORKERS" "$RESULT_DIR/hot_rates.txt" hot)
	cold_summary=$(summarize_group "$RESULT_DIR/cold" "$COLD_WORKERS" "$RESULT_DIR/cold_rates.txt" cold)
	IFS=',' read -r hot_ok hot_failed total_hot_txn_s hot_lat_ok hot_lat_excluded \
		avg_hot_latency_ms hot_lat_min_ms hot_lat_max_ms hot_lat_p50_ms hot_lat_p95_ms hot_lat_p99_ms <<<"$hot_summary"
	IFS=',' read -r cold_ok cold_failed total_cold_txn_s cold_lat_ok cold_lat_excluded \
		avg_cold_latency_ms cold_lat_min_ms cold_lat_max_ms cold_lat_p50_ms cold_lat_p95_ms cold_lat_p99_ms <<<"$cold_summary"
	local server_mpstat="$RESULT_DIR/cpu/server_mpstat.log"
	local client_mpstat="$RESULT_DIR/cpu/client/client_mpstat.log"
	local server_cpu_imbalance client_cpu_imbalance
	server_cpu_imbalance=$(parse_cpu_imbalance "$server_mpstat")
	client_cpu_imbalance=$(parse_cpu_imbalance "$client_mpstat")
	local server_net_rx_imbalance="nan"
	local server_net_tx_imbalance="nan"
	local client_net_rx_imbalance="nan"
	local client_net_tx_imbalance="nan"
	if [[ "$COLLECT_SOFTIRQS" == "1" ]]; then
		server_net_rx_imbalance=$(softirq_imbalance "$RESULT_DIR/cpu/server_softirqs_before.txt" "$RESULT_DIR/cpu/server_softirqs_after.txt" "NET_RX")
		server_net_tx_imbalance=$(softirq_imbalance "$RESULT_DIR/cpu/server_softirqs_before.txt" "$RESULT_DIR/cpu/server_softirqs_after.txt" "NET_TX")
		client_net_rx_imbalance=$(softirq_imbalance "$RESULT_DIR/cpu/client/client_softirqs_before.txt" "$RESULT_DIR/cpu/client/client_softirqs_after.txt" "NET_RX")
		client_net_tx_imbalance=$(softirq_imbalance "$RESULT_DIR/cpu/client/client_softirqs_before.txt" "$RESULT_DIR/cpu/client/client_softirqs_after.txt" "NET_TX")
	fi
	local server_netdev client_netdev
	local server_rx_gbps server_tx_gbps server_max_gbps
	local client_rx_gbps client_tx_gbps client_max_gbps
	server_netdev=$(parse_netdev_rate "$RESULT_DIR/net/server_iface.txt" "$RESULT_DIR/net/server_netdev_before.txt" "$RESULT_DIR/net/server_netdev_after.txt" "$RESULT_DIR/net/server_netdev_before_ts.txt" "$RESULT_DIR/net/server_netdev_after_ts.txt")
	client_netdev=$(parse_netdev_rate "$RESULT_DIR/net/client/client_iface.txt" "$RESULT_DIR/net/client/client_netdev_before.txt" "$RESULT_DIR/net/client/client_netdev_after.txt" "$RESULT_DIR/net/client/client_netdev_before_ts.txt" "$RESULT_DIR/net/client/client_netdev_after_ts.txt")
	IFS=',' read -r server_rx_gbps server_tx_gbps server_max_gbps <<<"$server_netdev"
	IFS=',' read -r client_rx_gbps client_tx_gbps client_max_gbps <<<"$client_netdev"
	local observed_max_gbps link_utilization_pct total_payload_gbps hot_payload_gbps cold_payload_gbps
	observed_max_gbps=$(awk -v a="$server_max_gbps" -v b="$client_max_gbps" 'BEGIN {if (a=="nan" && b=="nan") print "nan"; else {if (a=="nan") a=0; if (b=="nan") b=0; printf "%.6f", (a>b?a:b)}}')
	if awk "BEGIN {exit !($LINK_LIMIT_GBPS > 0 && $observed_max_gbps >= 0)}" 2>/dev/null; then
		link_utilization_pct=$(awk -v used="$observed_max_gbps" -v cap="$LINK_LIMIT_GBPS" 'BEGIN {printf "%.6f", (used/cap)*100.0}')
	else
		link_utilization_pct="nan"
	fi
	hot_payload_gbps=$(awk -v t="$total_hot_txn_s" -v req="$REQUEST_SIZE" -v resp="$RESPONSE_SIZE" 'BEGIN {printf "%.6f", t*(req+resp)*8.0/1e9}')
	cold_payload_gbps=$(awk -v t="$total_cold_txn_s" -v req="$REQUEST_SIZE" -v resp="$RESPONSE_SIZE" 'BEGIN {printf "%.6f", t*(req+resp)*8.0/1e9}')
	total_payload_gbps=$(awk -v h="$hot_payload_gbps" -v c="$cold_payload_gbps" 'BEGIN {printf "%.6f", h+c}')
	cat >"$RESULT_DIR/summary.csv" <<EOF_SUMMARY
timestamp,server_host,client_host,server_container,client_container,server_container_ip,run_mode,hot_workers,hot_ok,hot_failed,hot_lat_ok,hot_lat_excluded,cold_workers,cold_ok,cold_failed,cold_lat_ok,cold_lat_excluded,duration_sec,warmup_sec,request_size,response_size,total_hot_txn_s,avg_hot_latency_ms,hot_lat_min_ms,hot_lat_max_ms,hot_lat_p50_ms,hot_lat_p95_ms,hot_lat_p99_ms,total_cold_txn_s,avg_cold_latency_ms,cold_lat_min_ms,cold_lat_max_ms,cold_lat_p50_ms,cold_lat_p95_ms,cold_lat_p99_ms,hot_payload_gbps,cold_payload_gbps,total_payload_gbps,link_limit_gbps,observed_max_gbps,link_utilization_pct,server_rx_gbps,server_tx_gbps,client_rx_gbps,client_tx_gbps,server_cpu_imbalance,client_cpu_imbalance,server_net_rx_imbalance,server_net_tx_imbalance,client_net_rx_imbalance,client_net_tx_imbalance
$RUN_ID,$SERVER_HOST,$CLIENT_HOST,$SERVER_CONTAINER,$CLIENT_CONTAINER,$SERVER_CONTAINER_IP,$RUN_MODE,$HOT_WORKERS,$hot_ok,$hot_failed,$hot_lat_ok,$hot_lat_excluded,$COLD_WORKERS,$cold_ok,$cold_failed,$cold_lat_ok,$cold_lat_excluded,$DURATION_SEC,$WARMUP_SEC,$REQUEST_SIZE,$RESPONSE_SIZE,$total_hot_txn_s,$avg_hot_latency_ms,$hot_lat_min_ms,$hot_lat_max_ms,$hot_lat_p50_ms,$hot_lat_p95_ms,$hot_lat_p99_ms,$total_cold_txn_s,$avg_cold_latency_ms,$cold_lat_min_ms,$cold_lat_max_ms,$cold_lat_p50_ms,$cold_lat_p95_ms,$cold_lat_p99_ms,$hot_payload_gbps,$cold_payload_gbps,$total_payload_gbps,$LINK_LIMIT_GBPS,$observed_max_gbps,$link_utilization_pct,$server_rx_gbps,$server_tx_gbps,$client_rx_gbps,$client_tx_gbps,$server_cpu_imbalance,$client_cpu_imbalance,$server_net_rx_imbalance,$server_net_tx_imbalance,$client_net_rx_imbalance,$client_net_tx_imbalance
EOF_SUMMARY
	cat >"$RESULT_DIR/summary.txt" <<EOF_TEXT
Mixed netperf benchmark summary
================================
Run ID: $RUN_ID
Run mode: $RUN_MODE
Server: $SERVER_HOST / container $SERVER_CONTAINER / IP $SERVER_CONTAINER_IP
Client: $CLIENT_HOST / container $CLIENT_CONTAINER
Duration: ${DURATION_SEC}s, warmup before cold load: ${WARMUP_SEC}s
Request/response: ${REQUEST_SIZE},${RESPONSE_SIZE} bytes

Hot flows:  $HOT_WORKERS requested, $hot_ok parsed, $hot_failed failed
  Total TCP_RR transactions/s: $total_hot_txn_s
  RTT latency (ms, netperf MEAN_LATENCY, healthy flows): $hot_lat_ok of $hot_ok used ($hot_lat_excluded excluded)
    avg=$avg_hot_latency_ms min=$hot_lat_min_ms max=$hot_lat_max_ms p50=$hot_lat_p50_ms p95=$hot_lat_p95_ms p99=$hot_lat_p99_ms

Cold flows: $COLD_WORKERS requested, $cold_ok parsed, $cold_failed failed
  Total TCP_CRR transactions/s: $total_cold_txn_s
  RTT latency (ms, netperf MEAN_LATENCY, healthy flows): $cold_lat_ok of $cold_ok used ($cold_lat_excluded excluded)
    avg=$avg_cold_latency_ms min=$cold_lat_min_ms max=$cold_lat_max_ms p50=$cold_lat_p50_ms p95=$cold_lat_p95_ms p99=$cold_lat_p99_ms

Network utilization:
  Measured/overridden link ceiling: $LINK_LIMIT_GBPS Gbps
  Observed max host interface throughput: $observed_max_gbps Gbps
  Link utilization: $link_utilization_pct %
  Server RX/TX: $server_rx_gbps / $server_tx_gbps Gbps
  Client RX/TX: $client_rx_gbps / $client_tx_gbps Gbps
  Payload throughput hot/cold/total: $hot_payload_gbps / $cold_payload_gbps / $total_payload_gbps Gbps

CPU imbalance, max busy / average busy:
  Server: $server_cpu_imbalance
  Client: $client_cpu_imbalance

Softirq imbalance, max delta / average active delta:
  Server NET_RX: $server_net_rx_imbalance
  Server NET_TX: $server_net_tx_imbalance
  Client NET_RX: $client_net_rx_imbalance
  Client NET_TX: $client_net_tx_imbalance
EOF_TEXT
	cat "$RESULT_DIR/summary.txt"
	log "Summary written to $RESULT_DIR/summary.csv"
}

cleanup_on_error() {
	local code=$?
	if [[ $code -ne 0 ]]; then
		echo "Benchmark failed with exit code $code" >&2
		stop_cpu_collection "$SERVER_HOST" "server" || true
		stop_cpu_collection "$CLIENT_HOST" "client" || true
	fi
}

benchmark_main() {
	trap cleanup_on_error EXIT
	mkdir -p "$RESULT_DIR" "$RESULT_DIR/hot" "$RESULT_DIR/cold" "$RESULT_DIR/cpu" "$RESULT_DIR/net"
	cp "$CONFIG_SNAPSHOT" "$RESULT_DIR/config.snapshot"
	log "Starting mixed netperf benchmark: $RUN_ID (mode=$RUN_MODE)"
	check_prerequisites
	prepare_remote_dirs
	start_netserver
	wait_for_netserver
	measure_link_limit
	local server_iface client_iface
	server_iface=$(detect_net_iface "$SERVER_HOST" "$SERVER_NODE_IFNAME")
	client_iface=$(detect_net_iface "$CLIENT_HOST" "$CLIENT_NODE_IFNAME")
	log "Using network interfaces: server=$server_iface client=$client_iface"
	start_cpu_collection "$SERVER_HOST" "server"
	start_cpu_collection "$CLIENT_HOST" "client"
	start_netdev_collection "$SERVER_HOST" "server" "$server_iface"
	start_netdev_collection "$CLIENT_HOST" "client" "$client_iface"
	launch_workers "hot" "$HOT_WORKERS" "TCP_RR" "$HOT_START_BATCH_SIZE"
	log "Warmup: sleeping $WARMUP_SEC seconds before starting cold workers"
	sleep "$WARMUP_SEC"
	launch_workers "cold" "$COLD_WORKERS" "TCP_CRR" "$COLD_START_BATCH_SIZE"
	wait_for_client_workers
	stop_cpu_collection "$SERVER_HOST" "server"
	stop_cpu_collection "$CLIENT_HOST" "client"
	stop_netdev_collection "$SERVER_HOST" "server"
	stop_netdev_collection "$CLIENT_HOST" "client"
	collect_logs
	write_summary
	trap - EXIT
	log "Done. Results directory: $RESULT_DIR"
}
