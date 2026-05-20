# Synthetic CPU stress (stress-ng)

Increases **host CPU contention** on both nodes during baseline vs ONCache runs. Same load applies to both modes so comparisons stay fair.

## What it does

- Installs `stress-ng` if missing
- Starts `stress-ng --cpu <workers> --cpu-load <N>%` on **server1** and **server2**
- Reserves **2 CPUs** by default (`CPU_STRESS_RESERVE_CPUS`) so SSH/kubelet stay responsive
- Stops on benchmark exit (`trap` → `teardown_cpu_stress.sh`)

## Run

```bash
cd oncache-k8s
./scripts/sync_to_hosts.sh ./conf/oncache_k8s_setup.conf

# CPU stress only
./scripts/apply_cpu_stress.sh ./conf/oncache_k8s_setup.conf
./scripts/verify_cpu_stress.sh ./conf/oncache_k8s_setup.conf
./scripts/run_latency_benchmark_cpu_stress.sh \
  ./conf/oncache_k8s_setup.conf ./conf/cpu_stress_benchmark.conf

# CPU + overlay stress (MTU + policies)
./scripts/run_latency_benchmark_full_stress.sh \
  ./conf/oncache_k8s_setup.conf ./conf/cpu_stress_benchmark.conf
```

## Tune (`oncache_k8s_setup.conf`)

| Variable | Default | Meaning |
|----------|---------|---------|
| `CPU_STRESS_LOAD` | 70 | % load per CPU worker |
| `CPU_STRESS_WORKERS` | 0 | 0 = `nproc - RESERVE` |
| `CPU_STRESS_RESERVE_CPUS` | 2 | CPUs left for system/SSH |
| `CPU_STRESS_METHOD` | cpu | `cpu` or `matrix` (heavier) |
| `CPU_STRESS_MIN_LOAD_FACTOR` | 0.4 | verify: load1 ≥ nproc×factor |

## Debug

```bash
./scripts/check_overlay_benchmark_status.sh   # shows stress-ng + loadavg
ssh server1 'pgrep -a stress-ng; cat /proc/loadavg'
ssh server2 'pgrep -a stress-ng; cat /proc/loadavg'
./scripts/teardown_cpu_stress.sh ./conf/oncache_k8s_setup.conf
```

## Thesis note

Label as **synthetic host CPU stress**. ONCache may show lower latency or higher txn/s when overlay work competes with stress-ng for CPU time; WAN RTT can still dominate unless vSwitch RTT is low.
