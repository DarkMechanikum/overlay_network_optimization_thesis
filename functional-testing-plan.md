# Functional Testing Plan: Real-Host End-to-End Benchmark Validation

## Objective
Validate that the benchmark automation works end-to-end on real hosts using real SSH connectivity, real Docker runtime, and real benchmark traffic, and that produced artifacts/results are correct and reproducible.

This plan complements unit tests by verifying integration across:
- configuration loading,
- host connectivity and dependencies,
- cleanup and deploy behavior,
- traffic generation and flow establishment,
- metrics parsing/merging,
- CSV/manifests/artifacts output.

## Scope
- In scope:
  - Running `bench.cli` against two actual hosts defined in `config.cfg`.
  - Executing the full pipeline under multiple scenarios.
  - Validating run artifacts (`artifacts/<run_id>/...`) and result files (`results/result*.csv`).
  - Verifying expected behavior for success and controlled-failure cases.
- Out of scope:
  - Throughput/latency performance tuning and optimization.
  - Long-term benchmarking at production scale (this can be a later performance campaign).

## Prerequisites
1. Two reachable hosts on the intended L2/L3 path.
2. Valid `config.cfg` with:
   - `host1_ip`, `host2_ip`
   - `host1_ssh_hostname`, `host2_ssh_hostname`
   - `host1_key_path`, `host2_key_path`
3. SSH keys readable from repo-relative paths.
4. Required binaries installed on hosts (as expected by preflight and stages).
5. Local machine has Python + project dependencies.
6. Dedicated results baseline folder state (do not delete prior results; indexing must work).

## Test Environment Strategy
- Define two environments:
  - `functional-smoke`: lightweight, frequent runs.
  - `functional-scale`: heavier runs, less frequent (nightly or before milestones).
- Keep host state stable between tests:
  - Run `safe` cleanup by default.
  - Use `full` cleanup only for explicitly destructive validation.
- Record environment metadata for each run:
  - hostnames, kernel, docker version, CPU core count,
  - git commit hash (if available),
  - timestamp and run_id.

## Functional Test Coverage Matrix

### A. Happy Path (Core E2E)
1. **Smoke E2E**
   - Small connection count, short duration.
   - Expect full pipeline success and valid CSV/manifests/artifacts.
2. **Standard E2E**
   - Moderate connections and duration.
   - Expect complete per-flow rows, quantiles, throughput, CPU fields.
3. **Repeatability E2E**
   - Execute same command 2-3 times.
   - Expect non-overwriting indexed files: `result.csv`, `result-1.csv`, ...

### B. Operational Control Path
4. **Cleanup Mode Validation**
   - Run with `safe`; verify only benchmark-tagged resources touched.
   - Run with `full` + confirmation; verify behavior and guardrails.
5. **Keep-Containers Mode**
   - Run with keep mode enabled.
   - Verify benchmark containers remain after completion/failure.
6. **Dry-Run Mode**
   - Run with dry-run enabled.
   - Verify no mutating actions while pipeline wiring/logging works.

### C. Resilience and Failure Path
7. **Unreachable Host**
   - Provide unreachable hostname for one host.
   - Expect preflight failure with clear stage and reason.
8. **Missing Dependency**
   - Simulate missing Docker/tool on one host.
   - Expect explicit dependency failure with remediation hint.
9. **Transient SSH Failure + Retry**
   - Introduce temporary connectivity disruption.
   - Expect retry behavior and either recovery or clear exhausted-retry failure.
10. **Stage Timeout**
   - Configure aggressive timeout to trigger timeout path.
   - Expect timeout classification, non-zero exit, and teardown behavior.
11. **Interrupted Run**
   - Send interrupt signal during deploy/benchmark.
   - Expect graceful teardown policy and persisted partial diagnostics.

### D. Data Integrity Path
12. **Flow Completeness**
   - Validate row count matches attempted flow count or explicit failed-flow rows exist.
13. **Metric Field Integrity**
   - Validate p50/p99/p99.9, throughput, and CPU columns are present and parseable.
14. **Manifest Consistency**
   - Validate `run.json` contains params, stage outcomes, result path, and artifact references.

## Execution Profiles (Recommended)
- Smoke profile:
  - low connections, short duration, short warmup/cooldown.
- Standard profile:
  - medium connections, moderate duration.
- Stress-lite profile:
  - higher connection count without exhausting host resources.

Define these as reusable CLI command templates in a helper doc/script so testers run exactly the same parameters.

## Test Data and Artifacts Validation Checklist
For every functional run:
1. Exit code matches expected scenario (0 for success, non-zero for failures).
2. Stage log markers exist in order.
3. `results/` receives correct indexed output file.
4. CSV header is stable and contains required columns.
5. CSV rows are consistent with attempted flow count policy.
6. `artifacts/<run_id>/` exists and contains host/local expected files.
7. Manifest exists and references CSV and major artifact files.
8. Failure runs include sufficient diagnostics (failed stage, error reason, hint).

## Automation Plan
1. Add integration test entrypoint under `tests/integration/`:
   - `test_functional_e2e.py`
   - mark all with `@pytest.mark.integration`.
2. Add environment gating:
   - require `RUN_INTEGRATION=1`.
   - optionally require `INTEGRATION_CONFIG_PATH` and `INTEGRATION_REPO_ROOT`.
3. Add reusable fixture/helpers:
   - command runner wrapper for `python -m bench.cli ...`,
   - artifact/result locator utilities,
   - CSV + manifest validators.
4. Keep integration suite layered:
   - `test_functional_smoke.py` (fast path),
   - `test_functional_resilience.py` (negative/retry/timeout),
   - `test_functional_integrity.py` (artifact and schema checks).
5. Add optional shell runner:
   - `scripts/run_functional_tests.sh` to run a predefined subset with clear logging.

## CI/CD Strategy
- Default CI:
  - keep `tests/unit` only (no host dependencies).
- Optional CI job (self-hosted runner with host access):
  - run smoke integration tests on schedule or manual trigger.
- Release gate:
  - require recent successful smoke integration run before milestone merges.

## Implementation Roadmap
1. **Phase 1: Foundation**
   - Create integration test package + pytest markers + env gating.
   - Implement smoke E2E and result/artifact validators.
2. **Phase 2: Resilience**
   - Add failure-path tests (unreachable host, missing dependency, timeout).
   - Add retry behavior verification scenarios.
3. **Phase 3: Operational Modes**
   - Add dry-run and keep-containers tests.
   - Add cleanup mode guardrail tests.
4. **Phase 4: Hardening**
   - Stabilize flaky tests with stricter setup/teardown and richer diagnostics.
   - Document runbooks for triaging functional test failures.

## Pass/Fail Criteria
- Functional testing is considered implemented when:
1. Smoke E2E runs reliably and validates all required outputs.
2. At least one resilience scenario per failure class is automated and passing.
3. Artifact + CSV + manifest integrity checks are automated.
4. Integration tests are gated, documented, and runnable by another engineer.
5. Test logs are actionable enough to identify failure stage and probable cause quickly.

## Risks and Mitigations
- Host instability/noise:
  - use dedicated test windows and capture host baseline metadata.
- Flaky network behavior:
  - separate deterministic failures from transient-retry scenarios.
- Destructive cleanup risks:
  - isolate full-cleanup tests and require explicit confirmation.
- Long runtime:
  - prioritize smoke suite for frequent feedback; schedule heavier scenarios.

## Deliverables
- `tests/integration/` functional test suite with pytest markers.
- Integration fixtures and validators for CSV/artifacts/manifest.
- Optional runner script for repeatable execution.
- Functional testing README with prerequisites and commands.
- Documented scenario matrix and acceptance checklist (this file).
