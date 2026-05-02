# Feature 7 Plan: End-to-End Orchestration, CLI, Logging, and Resilience

## Objective
Tie all features into a single local command with predictable execution flow and robust failure handling.

## Deliverables
- Main orchestration entrypoint (`python benchmark_runner.py ...` or equivalent).
- CLI parameters for benchmark and operational controls.
- Logging, retries, and teardown behavior.

## Detailed Steps
1. Design pipeline stages:
   - stage 1: config load and preflight,
   - stage 2: cleanup and baseline prep,
   - stage 3: deploy/start benchmark containers,
   - stage 4: execute traffic run,
   - stage 5: collect/parse metrics,
   - stage 6: write CSV + artifacts,
   - stage 7: optional teardown.
2. Implement CLI options:
   - benchmark params (`--connections`, `--base-pps`, `--duration`, `--packet-size`),
   - operational params (`--cleanup-mode`, `--timeout`, `--retries`, `--keep-containers`).
3. Add structured logging:
   - stage-level start/end markers,
   - host-prefixed command logs,
   - failure reason with remediation hints.
4. Add retry policy for transient SSH/network failures.
5. Add timeout enforcement per stage and per remote command.
6. Ensure graceful teardown on interruption/error:
   - stop background collectors,
   - optionally stop/remove benchmark containers.
7. Return non-zero exit codes on failures with clear terminal summary.

## Test and Verification Plan
- Dry-run mode for config and command preview without remote mutation.
- Unit tests for config parser and filename indexing logic.
- Integration smoke run against both hosts with small load.
- Negative tests (missing key, unreachable host, missing dependency).

## Acceptance Criteria
- One local command executes the full benchmark pipeline end-to-end.
- Failures are explicit, recoverable, and do not leave unknown remote state.
- Successful runs always produce consumable result files and useful logs.

## Unit Test Specification
- **Test framework:** `pytest` with stage-function spies/mocks and CLI invocation tests.
- **Core test cases:**
  - CLI parser applies defaults and overrides for all key flags.
  - orchestrator executes stages in strict order for success path.
  - transient stage failure triggers configured retry behavior and backoff.
  - non-retryable error exits with non-zero code and summarized failure reason.
  - interrupt/exception path triggers teardown hooks (collector/container cleanup).
  - dry-run mode skips mutating commands while still validating pipeline wiring.
- **Fixtures/mocks:**
  - mocked stage functions returning success/failure patterns.
  - captured log output to assert stage markers and error formatting.
- **Pass criteria:**
  - control-flow behavior is deterministic under success and failure scenarios.
  - each stage boundary and exit code contract is covered by tests.
