# Unified ONCache / baseline mixed netperf

Two Docker containers on two hosts (see `oncache-docker/conf/oncache_real_setup.conf`). **Baseline** and **ONCache** share the same prepare path:

- **Default (thesis lab):** Swarm overlay `bench-net` via `ensure_overlay_lab.sh` (`OVERLAY_PREPARE_EACH_RUN=1`).
- **Full ONCache fast path:** set `IPVLAN_PREPARE_EACH_RUN=1` (requires working cross-host ipvlan routes; see `setup_ipvlan_routes.sh`).

## Prerequisite

Edit `benchmark.conf`:

- `SERVER_UNDERLAY` / `CLIENT_UNDERLAY` — each host’s underlay IPv4 reachable from the peer (required when `IPVLAN_PREPARE_EACH_RUN=1`).
- `RUN_MODE=baseline` or `RUN_MODE=oncache` (or `RUN_MODE=oncache ./run_mixed_netperf.sh ./benchmark.conf`).

## Run

```bash
cd hybrid-overlay-ebpf/oncache-benchmark
./run_mixed_netperf.sh ./benchmark.conf
```

ONCache mode (without editing the file):

```bash
RUN_MODE=oncache ./run_mixed_netperf.sh ./benchmark.conf
```

Re-parse logs only:

```bash
./run_mixed_netperf.sh --reparse-results ./results/baseline/20260518T120000Z ./benchmark.conf
```

Results: `results/<baseline|oncache>/<RUN_ID>/` (`summary.txt`, `summary.csv`, per-worker logs, `cpu/`, `oncache/` for map snapshots in oncache mode).

## Overlay vs ipvlan

| Config | Effect |
|--------|--------|
| `OVERLAY_PREPARE_EACH_RUN=1` (default) | Swarm + `bench-net` + fixed container IPs |
| `IPVLAN_PREPARE_EACH_RUN=1` | Recreate containers on ipvlan L3; set `SERVER_UNDERLAY` / `CLIENT_UNDERLAY` |
