# Feature 3 Plan: Benchmark Image Build, Distribution, and Runtime Setup

## Objective
Prepare and run benchmark containers on both hosts with consistent runtime configuration.

## Deliverables
- Docker build pipeline for benchmark image(s).
- Remote image availability strategy (build on each host or load/pull).
- Container startup routine with deterministic networking and runtime args.

## Detailed Steps
1. Define benchmark image content:
   - traffic generator/sink tools,
   - parser/export scripts,
   - minimal runtime dependencies.
2. Choose image deployment mode:
   - remote build on each host (simple, slower), or
   - local build + `docker save/load` transfer (faster repeat runs).
3. Implement artifact transfer method (e.g., `scp` tarball or remote git checkout).
4. Start receiver/server-side container on destination host first.
5. Start sender/client-side container on source host with generated run profile mount.
6. Use explicit container naming convention with run ID for easy cleanup.
7. Verify container liveness and readiness before benchmark start.
8. Record image digest/tag and container IDs in run metadata.

## Networking Considerations
- Ensure container networking mode supports desired latency/throughput fidelity.
- Prefer host networking if minimizing NAT/bridge overhead is required.
- Validate route reachability between host1 and host2 service endpoints.

## Acceptance Criteria
- Both hosts run expected container versions for a given run.
- Containers can communicate and are ready before traffic phase begins.
- Runtime metadata is persisted for auditability.

## Unit Test Specification
- **Test framework:** `pytest` with command-layer mocks and temp artifact directories.
- **Core test cases:**
  - deployment mode selector chooses remote-build vs save/load path as configured.
  - image transfer plan emits expected `scp`/remote load commands and paths.
  - receiver container start is ordered before sender container start.
  - container naming includes run ID and host role deterministically.
  - readiness checks retry until ready and fail after timeout.
  - metadata capture records image tag/digest and container IDs.
- **Fixtures/mocks:**
  - mocked command responses for `docker build`, `docker load`, `docker ps`, `docker inspect`.
  - simulated startup states (`starting`, `healthy`, `exited`).
- **Pass criteria:**
  - orchestration logic is validated end-to-end in unit scope.
  - no dependency on real Docker daemon in unit tests.
