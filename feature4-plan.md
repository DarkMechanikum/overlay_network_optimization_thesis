# Feature 4 Plan: Unique-Connection Traffic Generation with Per-Flow Rate Profile

## Objective
Generate concurrent unique connections where each flow has a distinct packet rate (`base_pps + index`).

## Deliverables
- Flow profile generator (connection tuples + target pps).
- Sender execution strategy that maintains per-flow independent rate control.
- Validation that all connection tuples are unique.

## Detailed Steps
1. Define benchmark inputs:
   - `num_connections` (e.g., 100),
   - `base_pps` (e.g., 100),
   - packet size,
   - duration,
   - warmup.
2. Generate deterministic flow table:
   - assign unique `(src_port, dst_port)` per flow,
   - assign `target_pps = base_pps + flow_index`.
3. Serialize flow table to machine-readable profile (JSON/CSV) mounted into sender container.
4. Implement sender logic to open all flows concurrently and pace each independently.
5. Implement receiver logic to track per-flow packet arrivals and timestamps.
6. Add runtime checks:
   - all flows established,
   - expected number of active flows reached before measurement window.
7. Detect and report failed or partial flow establishment.
8. Emit raw per-flow counters/timestamps for downstream metric computation.

## Scalability and Correctness Concerns
- Avoid source port collisions and ephemeral port conflicts.
- Bound socket/file descriptor limits and set ulimits if needed.
- Consider multi-thread/process sender design to sustain high flow counts.

## Acceptance Criteria
- All requested flows use unique `(src_port, dst_port)` tuples.
- Each flow runs at its specified pps target within acceptable tolerance.
- Raw flow-level artifacts are produced for every active connection.

## Unit Test Specification
- **Test framework:** `pytest`; pure-function tests for profile generation + mocked sender/receiver adapters.
- **Core test cases:**
  - flow table generator produces exactly `num_connections` rows.
  - every `(src_port, dst_port)` tuple is unique across generated flows.
  - `target_pps` sequence equals `base_pps + flow_index` for all flows.
  - profile serializer writes valid JSON/CSV schema and is parseable back.
  - runtime validator flags partial flow establishment correctly.
  - port allocator handles collision/invalid-range scenarios with explicit errors.
- **Fixtures/mocks:**
  - deterministic seeds/port ranges for reproducible generation.
  - mocked sender telemetry for full success and partial-failure runs.
- **Pass criteria:**
  - uniqueness, rate mapping, and error paths are fully asserted.
  - tests run locally without network traffic generation.
