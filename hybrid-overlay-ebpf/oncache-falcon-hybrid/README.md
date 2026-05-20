# Hybrid overlay MVP: ONCache fast path + Falcon-style fallback

A minimal hybrid datapath that composes two existing optimisation ideas:

- **ONCache** stays the cache fast path (TC eBPF programs + userspace daemon
  from `../oncache-k8s/`). Established "hot" flows reuse cached forwarding
  decisions and skip repeated Antrea/OVS classification work.
- **Falcon-style multi-core fallback** is applied alongside ONCache: any
  packet ONCache does not shortcut (cold flow, cache miss, fresh connection,
  policy churn) now traverses the conventional overlay chain with **RPS/XPS**
  enabled across all online CPUs on the transport NIC, physical NIC, the
  Geneve tunnel device, the Antrea internal port, OVS, and matching veth
  pairs. This approximates Falcon's parallelised softirq behaviour using
  standard Linux sysfs knobs, without requiring a kernel fork.

The MVP intentionally reuses the upstream ONCache build and daemon shipped
under `../oncache-k8s/`; only the multi-core fallback is added here.

## Layout

```
oncache-falcon-hybrid/
├── README.md
├── conf/
│   └── falcon_fallback.conf     # CPU masks, sysctls, state file location
└── scripts/
    ├── apply_falcon_fallback.sh # apply RPS/XPS + sysctls on both nodes
    ├── revert_falcon_fallback.sh# restore from persisted state file
    ├── start_hybrid.sh          # start_oncache + apply_falcon_fallback
    └── stop_hybrid.sh           # revert_falcon_fallback + stop_oncache
```

All scripts source `../oncache-k8s/scripts/lib.sh` for `load_config`,
`remote`, and `remote_bash`, and reuse `oncache-k8s/conf/oncache_k8s_setup.conf`
to identify the two nodes and their transport / physical interfaces.

## State and safety

`apply_falcon_fallback.sh` writes the previous `rps_cpus`, `xps_cpus`, and
`net.core` sysctl values to `/var/lib/oncache-hybrid/falcon_state.tsv` on
each host before changing them. `revert_falcon_fallback.sh` reads that file
and restores the originals exactly. The revert is also idempotent: running
it when no state file exists is a no-op.

## Usage outside the benchmark

```bash
# Apply only the Falcon-style fallback (no ONCache change):
./scripts/apply_falcon_fallback.sh \
  ../oncache-k8s/conf/oncache_k8s_setup.conf \
  ./conf/falcon_fallback.conf

# Compose with ONCache (cache fast path + multi-core fallback):
./scripts/start_hybrid.sh ../oncache-k8s/conf/oncache_k8s_setup.conf

# Tear down everything the hybrid added (and stop ONCache):
./scripts/stop_hybrid.sh ../oncache-k8s/conf/oncache_k8s_setup.conf
```

## Benchmark integration

`../oncache-k8s/scripts/run_latency_benchmark.sh` now honours
`BENCHMARK_MODES` and accepts `hybrid` (and optionally `falcon`) in addition
to the existing `baseline` and `oncache`. The default mode list is
`baseline oncache hybrid`; add `falcon` to compare cache-less multi-core
behaviour against the full hybrid:

```bash
BENCHMARK_MODES="baseline oncache falcon hybrid" \
  ./scripts/run_latency_benchmark.sh \
  ./conf/oncache_k8s_setup.conf ./conf/latency_benchmark.conf
```

For each mode the harness records hot (`TCP_RR`) and cold (`TCP_CRR`) flows,
so the resulting `summary.csv` directly populates the four-row results table
used in the thesis.

## Limitations of the MVP

- Falcon's full design modifies kernel softirq stages; this MVP approximates
  the *outcome* (multi-core softirq distribution on the overlay chain) using
  RPS/XPS. It does not change the kernel.
- IRQ affinity is left to `irqbalance`. If `irqbalance` is disabled, manual
  `/proc/irq/<n>/smp_affinity` tuning can be added without changing the
  rest of the harness.
- Admission policy of the hybrid is whatever ONCache's daemon implements:
  this MVP does not add a separate admission filter beyond ONCache's existing
  filter / egress / ingress / policy caches.
