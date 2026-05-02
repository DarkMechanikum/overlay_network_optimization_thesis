# Feature 2 Plan: Docker Cleanup and Host Baseline Preparation

## Objective
Reset both hosts to a clean, repeatable Docker/runtime baseline before each benchmark run.

## Deliverables
- Idempotent cleanup routine for containers, images, networks, and stale artifacts.
- Host baseline checks (disk, ports, kernel/sysctl prerequisites if needed).
- Structured cleanup logs for both hosts.

## Detailed Steps
1. Build cleanup command set for each host:
   - stop/remove running containers created by previous runs,
   - remove benchmark-related images (or full prune if user enables aggressive mode),
   - remove temporary benchmark directories.
2. Implement two cleanup modes:
   - `safe`: only benchmark-tagged containers/images,
   - `full`: `docker system prune -af --volumes` (explicit confirmation flag).
3. Validate Docker daemon is healthy post-cleanup (`docker ps`, `docker images`).
4. Check host resource baseline:
   - free disk space threshold,
   - available CPU cores,
   - optional memory threshold warning.
5. Ensure required host-side paths exist (`/tmp/bench-run-*` or project-defined path).
6. Capture baseline metadata (host kernel, docker version, core count) for result context.

## Safety and Guardrails
- Avoid deleting unrelated resources in default mode.
- Enforce explicit flag for destructive global prune.
- Print exactly what will be removed before executing cleanup.

## Acceptance Criteria
- Re-running cleanup multiple times is safe and deterministic.
- Both hosts end in a known baseline with no stale benchmark containers/images.
- Logs clearly indicate cleanup actions and resulting state.

## Unit Test Specification
- **Test framework:** `pytest` with mocked remote command executor.
- **Core test cases:**
  - `safe` cleanup mode generates only benchmark-scoped remove/prune commands.
  - `full` cleanup mode requires explicit confirmation flag or raises validation error.
  - cleanup routine is idempotent when no containers/images exist.
  - post-cleanup health checks fail fast when Docker daemon probe fails.
  - baseline checks correctly detect low-disk and low-resource warning conditions.
  - metadata snapshot parsing captures kernel/docker/core count fields.
- **Fixtures/mocks:**
  - fake host command outputs for `docker ps`, `docker images`, `df`, `nproc`.
  - host profiles with both healthy and degraded states.
- **Pass criteria:**
  - deletion guardrails are enforced by tests.
  - command ordering and decision logic are validated without real host mutation.
