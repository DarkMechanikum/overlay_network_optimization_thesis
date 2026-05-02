# Feature 1 Plan: Config, SSH Access, and Dependency Preflight

## Objective
Implement robust preflight logic that validates local config and confirms both hosts are reachable and benchmark-ready.

## Inputs
- `config.cfg` keys:
  - `host1_ip`, `host2_ip`
  - `host1_key_path`, `host2_key_path`
  - `host1_ssh_hostname`, `host2_ssh_hostname`

## Deliverables
- Config parser with strict validation and clear error messages.
- SSH command wrapper that supports per-host key path and hostname.
- Preflight report indicating pass/fail for each required dependency.

## Detailed Steps
1. Parse `config.cfg` into structured host objects (`host1`, `host2`).
2. Validate required fields are present and non-empty.
3. Resolve key paths relative to repository root and verify file permissions/readability.
4. Validate hostname/IP pair consistency (optional warning if DNS resolves unexpectedly).
5. Implement SSH runner with:
   - key file (`-i`),
   - host key policy (`StrictHostKeyChecking=accept-new` or configurable),
   - timeout,
   - stdout/stderr capture.
6. Execute basic host checks:
   - `uname -a`
   - `docker --version`
   - container runtime status (e.g., `docker info` minimal probe)
   - one metric tool (`mpstat` or `pidstat`) availability.
7. Validate benchmark-tool dependencies (e.g., `python3`, `iperf3` or selected generator).
8. Produce consolidated preflight result object for next pipeline stages.

## Error Handling
- Hard fail if SSH cannot connect or Docker is unavailable.
- Soft fail with remediation hints for optional tools.
- Include host identifier in every error for quick triage.

## Acceptance Criteria
- Running preflight on valid hosts returns a machine-readable pass result.
- Missing config field or key path yields immediate actionable error.
- Dependency status is explicit per host and per binary/service.

## Unit Test Specification
- **Test framework:** `pytest` with `unittest.mock` for subprocess/SSH isolation.
- **Core test cases:**
  - parses valid `config.cfg` into both host objects with expected fields.
  - fails on missing required key with clear error text naming the key.
  - resolves key paths relative to repo root and fails when file is absent.
  - SSH command builder includes expected `-i`, hostname, timeout, and options.
  - dependency probe marks hard-fail tools (`docker`) vs soft-fail optional tools.
  - preflight report aggregates per-host statuses correctly.
- **Fixtures/mocks:**
  - temp config files for valid/invalid layouts.
  - mocked `subprocess.run` returning command-specific stdout/stderr/exit codes.
- **Pass criteria:**
  - all branch paths covered (success, soft failure, hard failure).
  - deterministic assertions independent of real SSH/Docker availability.
