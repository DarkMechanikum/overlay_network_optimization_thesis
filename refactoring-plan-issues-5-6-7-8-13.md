# Refactoring Plan for Findings 5, 6, 7, 8, 13

## Objective

Address the following findings in a coordinated refactor while keeping the test suite aligned at every step:

- **5**: Orchestrator timeout is post-hoc, not preemptive
- **6**: Synthetic telemetry fallback can mask invalid benchmark runs
- **7**: Poll loops do not honor polling interval
- **8**: Retry behavior is inconsistent across exception/result paths
- **13**: Validation is fragmented across layers

## Guiding principles

- Keep backward compatibility where possible, but prefer correctness over silent fallback.
- Do not merge refactors without matching test updates in the same PR.
- Introduce structured failure semantics first, then tighten behavior.
- Stage changes behind explicit flags only when needed to avoid breaking active experiments.

## Target architecture (end state)

1. **Central validated runtime params object**
   - Single place for argument normalization and validation.
   - Stages receive already-validated values.

2. **Unified transient failure model**
   - Standard `retryable` semantics represented consistently.
   - No dependence on brittle error-string parsing.

3. **Real preemptive stage timeout enforcement**
   - Stage deadlines are calculated before execution.
   - Overruns are interrupted and surfaced as typed failures.

4. **Deterministic polling behavior**
   - Poll loops always sleep according to configured interval.
   - Payload includes attempt count and elapsed timing.

5. **Telemetry integrity policy**
   - Synthetic telemetry is explicitly opt-in.
   - Manifest and result payload clearly indicate telemetry source.

## Implementation plan (phased)

## Phase 0: Baseline and safety net

### Code tasks

- Freeze current behavior contracts in tests before modifying logic.
- Add lightweight utility module for shared failure/status types (e.g. `bench/errors.py` or `bench/runtime/failures.py`).

### Test tasks

- Add regression tests for current behavior where missing:
  - orchestrator timeout currently post-hoc behavior,
  - synthetic fallback currently enabled path,
  - polling loops currently attempt counting behavior,
  - retry decisions currently based on message/exception mix,
  - scattered validation entry points.

### Exit criteria

- Tests fully green and baseline coverage unchanged or improved.

---

## Phase 1: Centralized validation (Finding 13)

### Code tasks

1. Create a validated params layer, for example:
   - `bench/config/validation.py` with `ValidatedRunParams`.
2. Move validation from ad-hoc locations into one validation pass:
   - durations, warmup/cooldown relationships,
   - poll interval bounds,
   - retry and timeout bounds,
   - any mode flags related to telemetry policy.
3. Keep CLI parsing thin:
   - parse raw args -> construct `ValidatedRunParams` -> pass to context.
4. Standardize error format for validation failures:
   - actionable message and field name.

### Test tasks

- **New file**: `tests/unit/test_validation.py`
  - valid config/params matrix,
  - invalid bounds (negative retries, non-positive timeouts, invalid poll interval),
  - invalid timing windows (warmup + cooldown >= duration),
  - telemetry policy flag validation.
- Update `tests/unit/test_cli.py`:
  - ensure CLI surfaces validation failures clearly and exits deterministically.

### Exit criteria

- Validation no longer duplicated in stages.
- All invalid-input failures happen before orchestration begins.

---

## Phase 2: Unified retry semantics (Finding 8)

### Code tasks

1. Introduce typed failure representation, e.g.:
   - `StageFailure(kind, message, retryable, details)`.
2. Update stage return payload contract:
   - on failure include `retryable` explicitly.
3. Refactor orchestrator retry decision:
   - priority order: explicit `retryable` -> typed exception mapping -> default non-retryable.
   - remove/limit message substring heuristics.
4. Update remote layer behavior:
   - timeout and transient SSH/network failures map to retryable failures consistently.
   - avoid ambiguity between return code `124` and retry policy.

### Test tasks

- Update `tests/unit/test_orchestrator.py`:
  - retries when `retryable=True`,
  - no retries when `retryable=False`,
  - deterministic behavior for unknown failure type.
- Update `tests/unit/test_ssh_remote.py`:
  - timeout path produces retryable transient classification.
- Update stage tests (`test_preflight_stage.py`, `test_deploy_stage.py`, `test_benchmark_stage.py`, `test_metrics_stage.py`) to assert explicit retryability in failure payloads.

### Exit criteria

- Retry behavior is fully data-driven and predictable.
- No retry decisions depend on unstructured error strings.

---

## Phase 3: Preemptive timeout enforcement (Finding 5)

### Code tasks

1. Add deadline model:
   - `stage_deadline = start + timeout_seconds`.
   - pass deadline into stage execution context.
2. Enforce timeout preemptively:
   - option A: run stage in cancellable worker and enforce join timeout,
   - option B: enforce subprocess-level timeouts in all blocking remote calls and use cooperative checks.
3. Add typed timeout failure:
   - `kind="timeout"`, `retryable` configurable by stage policy.
4. Define clear precedence between stage timeout and command timeout.

### Test tasks

- Update `tests/unit/test_orchestrator.py`:
  - hung stage is aborted by orchestrator timeout,
  - timeout failure shape is deterministic,
  - retry behavior for timeout follows policy.
- Add tests for long-running benchmark path in `tests/unit/test_benchmark_stage.py`:
  - command timeout derived from benchmark lifecycle (duration + buffers).

### Exit criteria

- A hung stage cannot block indefinitely.
- Timeout behavior is deterministic and documented.

---

## Phase 4: Poll loop correctness and observability (Finding 7)

### Code tasks

1. Refactor polling into shared helper:
   - `poll_with_interval(max_attempts, interval_s, check_fn, clock, sleeper)`.
2. Replace ad-hoc loops in:
   - `bench/stages/deploy.py`,
   - `bench/stages/benchmark.py`.
3. Emit poll telemetry in payload:
   - attempts made,
   - total elapsed seconds,
   - final state reason.

### Test tasks

- Add/extend tests with injected sleeper/clock:
  - assert sleep called exactly between attempts,
  - no sleep after terminal success/failure,
  - elapsed time recorded correctly.
- Candidate updates:
  - `tests/unit/test_deploy_stage.py`,
  - `tests/unit/test_benchmark_stage.py`.

### Exit criteria

- Poll interval configuration is honored in all loops.
- Poll behavior is verifiable via payload metadata.

---

## Phase 5: Telemetry integrity policy (Finding 6)

### Code tasks

1. Add explicit policy flag:
   - `allow_synthetic_telemetry: bool = False`.
2. Adjust benchmark behavior:
   - if real telemetry is missing and synthetic not allowed -> stage failure with actionable error,
   - if allowed -> mark clearly as synthetic.
3. Propagate telemetry-source metadata:
   - stage payload (`telemetry_source`),
   - run manifest (`synthetic_metrics`),
   - optional CSV column if needed (`telemetry_source`).

### Test tasks

- Update `tests/unit/test_benchmark_stage.py`:
  - default path rejects synthetic fallback,
  - opt-in flag allows synthetic and marks payload.
- Update `tests/unit/test_results_manifest.py`:
  - manifest includes synthetic marker.
- Update integration tests:
  - `tests/integration/test_functional_smoke.py` asserts no synthetic telemetry in normal real-host run.

### Exit criteria

- Synthetic data can no longer silently pass as real results.

---

## Phase 6: Documentation and migration cleanup

### Code tasks

- Update docs:
  - `README.md`,
  - `architecture.md`,
  - `tests-architecture.md`,
  - integration README for new behavior/flags.
- Add migration notes for operators (new validation behavior, timeout policy, telemetry flag defaults).

### Test tasks

- Ensure docs examples match actual CLI and validation behavior.
- Keep `pytest -m "not integration"` green in CI-equivalent local run.

### Exit criteria

- Documentation reflects runtime behavior exactly.

## Test maintenance strategy (must-do per PR)

- Every PR in this refactor must include:
  - production change,
  - tests for newly introduced branch/error path,
  - updated fixtures/contracts where payload schema changes.
- Prefer adding tests before changing behavior where feasible.
- Keep and enforce this sequence per PR:
  1. unit tests for changed module,
  2. affected cross-module unit tests,
  3. integration smoke (if contract/output changed).

## Suggested PR breakdown

1. **PR-1**: Validation centralization + CLI wiring + tests (`test_validation.py`, `test_cli.py`).
2. **PR-2**: Retry semantics unification + orchestrator/remote changes + tests (`test_orchestrator.py`, `test_ssh_remote.py`, stage tests).
3. **PR-3**: Preemptive timeout enforcement + timeout tests.
4. **PR-4**: Poll helper refactor + deploy/benchmark loop tests.
5. **PR-5**: Synthetic telemetry policy + manifest/integration assertions.
6. **PR-6**: Documentation sync and minor cleanup.

## Acceptance criteria checklist

- [ ] Validation failures are centralized and triggered pre-run.
- [ ] Retry logic consumes explicit structured retryability.
- [ ] Stage timeout is enforced preemptively (hung stage test passes).
- [ ] Poll loops sleep according to configured interval.
- [ ] Synthetic telemetry is opt-in and visibly marked when used.
- [ ] Unit tests updated for all changed branches.
- [ ] Integration smoke updated and passing with real telemetry policy.
- [ ] Documentation updated to match runtime behavior.

## Risks and mitigations

- **Risk**: behavior changes break existing benchmark workflows.
  - **Mitigation**: rollout via small PRs and explicit migration notes.
- **Risk**: timeout enforcement introduces flakiness.
  - **Mitigation**: deterministic clock/sleeper injection in tests.
- **Risk**: stricter telemetry policy increases failures in imperfect environments.
  - **Mitigation**: explicit opt-in synthetic mode for controlled fallback.

## Estimated effort

- Phase 1: 0.5-1 day
- Phase 2: 1 day
- Phase 3: 1-1.5 days
- Phase 4: 0.5-1 day
- Phase 5: 0.5-1 day
- Phase 6: 0.5 day

Total: **~4-6 engineering days**, depending on integration environment stability.
