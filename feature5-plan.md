# Feature 5 Plan: Throughput, Latency Quantiles, and CPU/Core Utilization Collection

## Objective
Collect and compute required performance metrics per connection and per host.

## Deliverables
- Per-flow throughput computation pipeline.
- Per-flow latency quantiles (p50, p99, p99.9).
- CPU/core utilization samples aligned to benchmark interval.

## Detailed Steps
1. Define metric schema:
   - identifiers: run_id, host roles, flow_id, src_port, dst_port,
   - throughput: packets/sec, bits/sec,
   - latency: p50/p99/p99.9 (us or ms),
   - cpu: per-core utilization (%) and aggregate summary.
2. Collect traffic artifacts:
   - sender transmitted packet counts/timestamps,
   - receiver observed packet counts/timestamps,
   - optional sequence-based loss/reorder data.
3. Compute latency quantiles from per-packet or sampled timestamp deltas.
4. Compute per-flow throughput over measurement window (exclude warmup/cooldown).
5. Collect host CPU metrics during run:
   - `mpstat -P ALL` / `pidstat` / `/proc/stat` sampler,
   - sample at fixed interval (e.g., 1s).
6. Normalize CPU output into per-core utilization fields:
   - user/system/softirq/irq/idle (or single utilization value).
7. Tag CPU metrics as "system-level" if packet-processing-only isolation is unavailable.
8. Validate metric completeness and flag missing flows/quantiles.

## Accuracy and Timing Strategy
- Use synchronized run start markers for both hosts.
- Capture absolute timestamps in UTC epoch for alignment.
- Record sampling interval and quantile method used for reproducibility.

## Acceptance Criteria
- For each successful flow, output includes throughput + p50/p99/p99.9.
- CPU utilization is reported per host and per core for benchmark window.
- Metric parser handles partial failures gracefully with explicit status fields.

## Unit Test Specification
- **Test framework:** `pytest` with numeric assertions (`pytest.approx`) and fixture-driven sample telemetry.
- **Core test cases:**
  - throughput calculator returns expected pps/bps from packet counts and window length.
  - quantile calculator returns correct p50/p99/p99.9 on known latency datasets.
  - warmup/cooldown exclusion logic removes out-of-window samples correctly.
  - CPU parser normalizes `mpstat`/`/proc/stat` samples into per-core utilization fields.
  - metric merger aligns flow metrics and CPU samples by run/host timestamps.
  - missing flow telemetry generates row with status/error instead of crash.
- **Fixtures/mocks:**
  - synthetic packet timestamp traces with closed-form expected quantiles.
  - representative CPU text outputs from multiple host/core layouts.
- **Pass criteria:**
  - computed metrics match expected values within tolerance.
  - parser robustness verified for malformed/partial input payloads.
