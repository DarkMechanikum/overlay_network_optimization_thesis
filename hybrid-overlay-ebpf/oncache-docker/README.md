# ONCache Docker Swarm Lab Setup

This directory adapts the upstream [ONCache](https://github.com/shengkai16/ONCache) reference implementation to the thesis Docker lab on `server1` and `server2`. It reuses the existing `netperf-server` and `netperf-client` containers and does not use the Kubernetes/Antrea benchmark flow from the paper.

**Benchmarks:** use `../oncache-benchmark/` (`run_mixed_netperf.sh`, single `benchmark.conf`).

## What is wired

- Host NIC: `tc_init_e` on egress (learns outer headers on VXLAN leaving the node).
- Container: `tc_init_in` on `eth0` ingress (learns container MACs into `ingress_cache`).
- Overlay sandbox netns: `tc_masq` on `veth1` ingress, `tc_restore` on `vxlan0` ingress.
- Map population through `set_map` and pinned maps under `/sys/fs/bpf/tc/globals/`.

## Important constraints

- Upstream ONCache expects Linux 5.13 or newer (`bpf_redirect_peer`, encap `bpf_skb_adjust_room`).
- The Antrea/OVS hook script is disabled by default (`ENABLE_OVS_HOOKS=0`).

### Swarm overlay vs fast path

Docker Swarm **overlay** puts the container veth inside a **sandbox network namespace** (`/var/run/docker/netns/...`), not on the host root namespace like Kubernetes/CRI pods. ONCache upstream attaches `tc_masq` on the **host-visible** pod veth and uses `bpf_redirect` to the node NIC.

On Swarm overlay:

| Program | Attach point | Fast path today |
|---------|----------------|-----------------|
| `tc_init_e` | Host NIC egress | Learning works |
| `tc_init_in` | Container `eth0` ingress | Works |
| `tc_masq` | Overlay `veth1` ingress | Encap works; **redirect to `vxlan0` or `br0` hangs** — default uses `SWARM_OVERLAY_SANDBOX` (learn only) |
| `tc_restore` | Overlay `vxlan0` ingress | Decap + `bpf_redirect` to container veth in same netns (`SWARM_OVERLAY_RESTORE`) |

The default build sets `SWARM_OVERLAY_SANDBOX` and `SWARM_OVERLAY_RESTORE` (see `scripts/build_oncache.sh`). Inbound restore can fast-path once maps are warm; outbound masq still needs a redirect target that does not break Swarm forwarding until you either:

1. Apply the upstream **`rpeer_kernel_patch`** (`bpf_redirect_rpeer`) and extend the Swarm daemon for cross-netns redirect, or
2. Move the lab to a **host-parent network** (ipvlan/macvlan) where the container interface is parented on `enp4s0` / `enp1s0` and rebuild with `ONCACHE_OVERLAY_FLAGS=''`.

Scripts: `scripts/migrate_netperf_to_ipvlan.sh`, `scripts/install_rpeer_helper.sh` (experimental).

## Prepare both hosts

```bash
cd hybrid-overlay-ebpf/oncache-docker
./scripts/prepare_hosts.sh ./conf/oncache_real_setup.conf
```

This initializes ONCache submodules in `references/ONCache`, syncs the source tree and these scripts to both hosts, installs build dependencies, and builds ONCache on each host.

## Validate the lab

```bash
./scripts/check_prerequisites.sh ./conf/oncache_real_setup.conf
./scripts/probe_tc_load.sh ./conf/oncache_real_setup.conf
```

`check_prerequisites.sh` confirms build artifacts, containers, and host NICs. `probe_tc_load.sh` attempts the host-side TC attach used by the daemon and is the gate for a kernel upgrade.

## Start and stop ONCache

```bash
./scripts/start_oncache.sh ./conf/oncache_real_setup.conf
./scripts/smoke_test.sh ./conf/oncache_real_setup.conf
./scripts/stop_all.sh ./conf/oncache_real_setup.conf
```

`start_oncache.sh` refuses to start when the host kernel is below 5.13. After the lab kernel is upgraded, run `probe_tc_load.sh`, then `start_oncache.sh`, then `smoke_test.sh`.

## Configuration

Edit `conf/oncache_real_setup.conf` for host NIC names, container names, and remote install paths. Container IPs are discovered automatically unless you override them for the smoke test.
