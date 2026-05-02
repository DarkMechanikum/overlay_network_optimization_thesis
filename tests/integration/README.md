# Integration Tests (Phase 1 Smoke)

These tests run the real pipeline against real hosts by invoking:

- `python -m bench.cli ...`

They are **opt-in** and skipped by default.

## Prerequisites

- Two reachable hosts configured for this project.
- Valid SSH keys and hostnames in a config file.
- Docker/dependencies installed on hosts (preflight-compatible).

## Required Environment Variables

- `RUN_INTEGRATION=1`
- `INTEGRATION_CONFIG_PATH=/absolute/path/to/config.cfg`

Sample config in repo:

- `tests/integration/config.cfg`

If either is missing, integration tests skip with a clear reason.

## Run Command

```bash
RUN_INTEGRATION=1 INTEGRATION_CONFIG_PATH=/path/to/config.cfg pytest tests/integration/test_functional_smoke.py -q
```

Example using the repo config path:

```bash
RUN_INTEGRATION=1 INTEGRATION_CONFIG_PATH=tests/integration/config.cfg pytest tests/integration/test_functional_smoke.py -q
```

## Safety Notes

- The smoke test uses conservative parameters (`connections=2`, short duration).
- It uses `--cleanup-mode safe` by default.
- It expects real runtime telemetry (`synthetic_metrics=false`) in the manifest.
- These tests still execute real remote operations; run only in intended environments.
