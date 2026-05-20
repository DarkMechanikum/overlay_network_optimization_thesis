# ONCache on Kubernetes + Antrea

Scripts to prepare the thesis lab hosts for **upstream ONCache** (`daemon.py`, stock `make all`) on a two-node kubeadm cluster with Antrea.

For the **unified Docker mixed netperf** (baseline vs full ONCache, ipvlan), use `../oncache-benchmark/` instead of legacy benchmark trees.

## Configuration

Edit `conf/oncache_k8s_setup.conf` for hostnames, transport NICs (`enp4s0.4000` / `enp1s0.4000` when vSwitch VLAN is up), and remote paths.

## Scripts

| Script | Purpose |
|--------|---------|
| `prepare_hosts.sh` | Full setup (deps, K8s, Antrea, pods, ONCache build) |
| `provision_cluster.sh` | kubeadm init/join + Antrea (resets cluster) |
| `reset_oncache_repo.sh` | `git reset --hard` + clean on hosts |
| `sync_to_hosts.sh` | Rsync ONCache + these scripts |
| `build_oncache.sh` | Upstream build (`-DONCACHE_K8S_ANTREA`) |
| `start_oncache.sh` / `stop_oncache.sh` | `daemon.py` on both nodes |
| `clear_hosts_for_k8s_benchmark.sh` | Destructive cleanup before fresh K8s benchmark |
| `apply_overlay_stress.sh` | Antrea MTU 1280 + 150 NetworkPolicies |
| `teardown_overlay_stress.sh` | Remove stress policies, restore MTU |
| `verify_overlay_stress.sh` | Smoke test after stress apply |
| `run_latency_benchmark.sh` | Multi-mode latency campaign (`baseline`, `oncache`, `falcon`, `hybrid`); hot (TCP_RR) + cold (TCP_CRR) per mode |
| `apply_cpu_stress.sh` / `teardown_cpu_stress.sh` | stress-ng on both nodes |
| `verify_cpu_stress.sh` | load + netperf smoke under CPU stress |
| `run_latency_benchmark_overlay_stress.sh` | MTU + NetworkPolicies + benchmark |
| `run_latency_benchmark_cpu_stress.sh` | CPU stress + benchmark |
| `run_latency_benchmark_full_stress.sh` | CPU + overlay stress + benchmark |
| `run_latency_benchmark_falcon_only.sh` | Baseline vs Falcon-style multi-core fallback only (no ONCache) |

## Overlay-stress benchmark (recommended)

Increases overlay datapath cost via **low pod MTU** and **many Antrea NetworkPolicies** so baseline vs ONCache differences are easier to measure than on a high-RTT WAN path alone.

```bash
cd hybrid-overlay-ebpf/oncache-k8s
chmod +x scripts/*.sh

# Optional: fresh cluster
./scripts/clear_hosts_for_k8s_benchmark.sh ./conf/oncache_k8s_setup.conf
./scripts/prepare_hosts.sh ./conf/oncache_k8s_setup.conf

# Apply stress + run baseline and ONCache
./scripts/run_latency_benchmark_overlay_stress.sh \
  ./conf/oncache_k8s_setup.conf ./conf/latency_benchmark.conf
```

Results: `results/k8s-latency-overlay-stress/<RUN_ID>/summary.csv`

Tune in `conf/oncache_k8s_setup.conf`: `OVERLAY_STRESS_MTU`, `OVERLAY_STRESS_POLICY_COUNT`.

## CPU stress benchmark

```bash
./scripts/run_latency_benchmark_cpu_stress.sh \
  ./conf/oncache_k8s_setup.conf ./conf/cpu_stress_benchmark.conf
```

Results: `results/k8s-latency-cpu-stress/<RUN_ID>/summary.csv`  
See `docs/CPU_STRESS.md` for tuning.

## Plain latency benchmark (no stress)

```bash
./scripts/run_latency_benchmark.sh ./conf/oncache_k8s_setup.conf ./conf/latency_benchmark.conf
```

Results: `results/k8s-latency/<RUN_ID>/summary.csv`

### `summary.csv` columns

`run_id,mode,flow_type,netperf_test,workers,repeat,ok,failed,total_txn_s,avg_latency_ms,...`

- **hot** — `TCP_RR` (one persistent TCP per worker; cache-friendly)
- **cold** — `TCP_CRR` (new TCP per request–response)

Filter examples:

```bash
# Baseline hot only
awk -F, '$2=="baseline" && $3=="hot"' results/k8s-latency/*/summary.csv

# ONCache cold vs baseline cold at w=8
awk -F, '$3=="cold" && $5==8' results/k8s-latency/*/summary.csv
```

To run hot flows only: `BENCHMARK_FLOW_TYPES=hot ./scripts/run_latency_benchmark.sh ...`

## Overlay modes

The latency benchmark exercises a configurable list of overlay modes
(`BENCHMARK_MODES` in `conf/latency_benchmark.conf`, default
`baseline oncache falcon hybrid` — the full four-row matrix used in the
thesis results table):

- `baseline` — stock Antrea overlay
- `oncache` — upstream ONCache cache fast path (daemon + TC eBPF)
- `falcon` — Falcon-style multi-core fallback only (RPS/XPS spread across all
  CPUs on the transport NIC, physical NIC, Geneve, Antrea, OVS, and matching
  veth devices); see `../oncache-falcon-hybrid/`
- `hybrid` — ONCache cache fast path **plus** the Falcon-style fallback for
  cache misses and cold flows

Run a subset (e.g. only Falcon vs baseline) by overriding `BENCHMARK_MODES`:

```bash
BENCHMARK_MODES="baseline falcon" \
  ./scripts/run_latency_benchmark.sh \
  ./conf/oncache_k8s_setup.conf ./conf/latency_benchmark.conf
```

A pre-set wrapper for that comparison ships at
`scripts/run_latency_benchmark_falcon_only.sh` (writes into
`results/k8s-latency-falcon/<RUN_ID>/summary.csv`).
