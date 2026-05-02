# Benchmark Automation Implementation Plan

## Goal
Create a single local runner script (Python preferred, Bash possible) that:
- connects to two L2-connected hosts via SSH using values from `config.cfg`,
- validates dependencies,
- resets Docker state,
- prepares benchmark artifacts and runtime,
- executes a high-cardinality, per-flow-rate benchmark across two containers,
- collects throughput, latency quantiles, and CPU utilization,
- writes results to versioned CSV files (`result.csv`, `result-1.csv`, ...).

## Scope and Deliverables
- One orchestrator script executable from local machine.
- Remote helper commands/scripts executed via SSH (inline or copied files).
- Repeatable benchmark scenario with configurable connection count, rates, duration.
- CSV result persistence with automatic filename indexing.
- Logs/artifacts directory for raw outputs and debugging.

## Related Documentation
- [`architecture.md`](architecture.md) — program skeleton (packages, boundaries, orchestration stages, data flow).
- [`tests-architecture.md`](tests-architecture.md) — test layout, fixtures, and layer-to-test mapping.

## Architecture Overview
- **Control plane:** local script orchestrates end-to-end workflow.
- **Data plane under test:** one Docker container per host, benchmark traffic between hosts.
- **Measurement plane:** local script collects:
  - per-connection throughput,
  - per-connection latency (p50, p99, p99.9),
  - per-host CPU/core utilization samples during run.

## Feature Breakdown
1. `feature1-plan.md` - Config parsing, SSH connectivity, and dependency checks.
2. `feature2-plan.md` - Docker cleanup and deterministic host baseline preparation.
3. `feature3-plan.md` - Benchmark image build/deploy and remote runtime setup.
4. `feature4-plan.md` - Unique-connection traffic generation with per-flow packet rates.
5. `feature5-plan.md` - Metric collection (latency, throughput, CPU/core utilization).
6. `feature6-plan.md` - Result collation, CSV versioning, and run artifact management.
7. `feature7-plan.md` - Orchestration flow, CLI UX, retries, and failure handling.

## Implementation Order
1. Build config + SSH validation layer.
2. Add host cleanup and preparation steps.
3. Add container build/run logic.
4. Implement traffic profile generation and benchmark execution.
5. Integrate metrics collection and parsing.
6. Implement final result table writing + indexed filenames.
7. Harden workflow with retries, logging, and graceful teardown.

## Key Technical Decisions
- Prefer **Python** for maintainability, parsing, structured CSV writing, and robust subprocess/SSH handling.
- Use SSH hostnames from config for command execution and key paths for strict identity control.
- Keep benchmark run parameters configurable via CLI flags (connections, base pps, duration, warmup).
- Store raw command outputs (JSON/text) per run, and derive normalized CSV rows from those artifacts.

## Risks and Mitigations
- **Tool availability mismatch across hosts:** preflight checks with actionable install hints.
- **Time sync skew affecting latency interpretation:** verify NTP/clock status or use one-way-safe tooling.
- **Host noise in CPU utilization:** sample per-core stats and tag as "system-level" measurements.
- **Port exhaustion with many unique flows:** validate ephemeral range and/or configure custom source ports.
- **Benchmark instability under load:** warmup/cooldown windows, retry policy, and run health checks.

## Validation Strategy
- Smoke test with small connection count (e.g., 10) and short duration.
- Scale test with target connection count (e.g., 100+) verifying unique `(src_port, dst_port)` tuples.
- Confirm each connection has expected pps pattern (`base_pps + flow_index`).
- Verify output CSV completeness and monotonic result file indexing.

## Definition of Done
- Single command from local machine performs full workflow end-to-end.
- Both hosts are prepared automatically and benchmark runs without manual intervention.
- CSV output includes required per-connection latency quantiles, throughput, and CPU metrics.
- Repeated runs generate non-overwriting indexed result files.
