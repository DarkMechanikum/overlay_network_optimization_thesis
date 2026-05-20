# Why server2 looked unreachable during benchmarks

## Scripts do not SSH to server2 for overlay stress

`apply_overlay_stress.sh` only runs on **server1** via `kubectl`. It does not log into server2 directly.

So when logs say "server2 unreachable", it is usually one of:

1. **SSH timeout from the orchestrator** while server2 is busy (rsync, kubelet, Antrea restart) — not necessarily a dead host.
2. **Kubernetes node2 NotReady** — kubelet/antrea-agent unhealthy; **public SSH can still work** (as you verified).
3. **Cluster-wide Antrea misconfiguration** affecting server2 networking.

## Likely root cause: wrong `transportInterface` on server2

An older helper (`ensure_antrea_transport.sh`) set a **single** interface name from **server1** (e.g. `enp4s0.4000`) in the Antrea ConfigMap for **all** agents.

On server2 the VLAN NIC is **`enp1s0.4000`**, not `enp4s0.4000`. After `kubectl rollout restart daemonset/antrea-agent`, the agent on server2 can fail or mis-handle tunnel traffic → node **NotReady**, benchmark scripts fail, and concurrent SSH/rsync to server2 may **time out**.

**Fix:** use `transportInterfaceCIDRs: [168.119.133.0/24]` so each node picks the interface with the vSwitch IP.

```bash
./scripts/fix_antrea_transport.sh ./conf/oncache_k8s_setup.conf
# or
./scripts/audit_lab_network.sh ./conf/oncache_k8s_setup.conf
```

## Other contributors

| Factor | Effect |
|--------|--------|
| Antrea agent restart | 1–5 min churn; node NotReady; heavy CPU on server2 |
| `sync_to_hosts` rsync | Large tree to server2; slow, can exceed SSH timeout |
| Leftover nested VXLAN / TC | If `vxnl*` or clsact `mirred` still on NICs, can break underlay |
| Low MTU 1280 | Affects pods/tunnels, not public SSH on `195.201.193.69` |

## Audit commands (both hosts reachable)

```bash
cd oncache-k8s
./scripts/audit_lab_network.sh ./conf/oncache_k8s_setup.conf
ssh server1 'kubectl -n kube-system get cm antrea-config -o yaml | grep -E transportInterface'
ssh server2 'ip -br link; ip route; systemctl is-active kubelet antrea-agent 2>/dev/null; ip link | grep vxnl || true'
```

## Safe overlay-stress order (after fixes)

1. `./scripts/fix_antrea_transport.sh`
2. `./scripts/apply_overlay_stress.sh` (policies before Antrea restart; rollout warning-only on timeout)
3. `./scripts/verify_overlay_stress.sh`
4. `./scripts/run_latency_benchmark_overlay_stress.sh`
