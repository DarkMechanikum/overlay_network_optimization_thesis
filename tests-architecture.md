# Tests Architecture (Skeleton)

This document defines how tests are structured so they align with [`overall-plan.md`](overall-plan.md) and [`architecture.md`](architecture.md): **pytest**, **mocked remote execution**, **deterministic filesystem tests** for results, and **clear boundaries** between unit tests (fast, no SSH/Docker) and optional integration/e2e runs.

---

## 1. Goals

| Goal | How |
|------|-----|
| Run tests as soon as a feature lands | Unit tests live next to layers from `architecture.md`; CI runs `pytest` without live hosts |
| Avoid flakiness | No real `ssh`, `docker`, or network in default suite |
| Mirror program skeleton | Package names under `tests/` mirror `bench/` modules |
| Match overall deliverables | Assert CSV indexing, metric shapes, orchestration order — the same outcomes the plan promises |

---

## 2. Directory Layout (Recommended)

```
tests/
  conftest.py                 # shared fixtures: fake remote, tmp repo root, sample HostConfig
  unit/
    test_config_loader.py     # bench/config/loader.py
    test_validation.py        # bench/config/validation.py
    test_ssh_remote.py        # bench/remote/ssh.py (argv + subprocess mock)
    test_preflight_stage.py   # bench/stages/preflight.py (fake remote)
    test_cleanup_stage.py
    test_deploy_stage.py
    test_benchmark_stage.py
    test_metrics_throughput.py
    test_metrics_latency.py
    test_metrics_cpu.py
    test_metrics_merge.py
    test_results_paths.py
    test_results_csv.py
    test_manifest.py
    test_orchestrator.py      # bench/orchestrator.py — stage order, retries, teardown hooks
    test_cli.py               # bench/cli.py
  integration/                # optional; not required for default CI
    README.md                 # documents need for real hosts / credentials
```

- **`unit/`** — default; must pass offline.
- **`integration/`** — manual or nightly; may require `config.cfg`, VPN, SSH. Keep **empty or skipped** unless `RUN_INTEGRATION=1`.

This matches the **feature plans** where each feature has explicit unit-test specs and can be implemented incrementally.

---

## 3. Naming and Conventions

- **Files:** `test_<module_behavior>.py` aligned to the module under test.
- **Test names:** `test_<scenario>_<expected>` (e.g., `test_resolve_result_path_increments_when_base_exists`).
- **Framework:** `pytest` only; use `pytest.approx` for floats.
- **Mocks:** prefer `unittest.mock.patch` on **`RemoteSession.run`** or the **subprocess** behind `ssh.py`, not patching entire stages unless necessary.

---

## 4. Shared Fixtures (`conftest.py`)

Define reusable building blocks:

| Fixture | Purpose |
|---------|---------|
| `repo_root` | `pathlib.Path` to a temp directory containing a minimal `config.cfg` |
| `host_configs` | Two `HostConfig` instances pointing at dummy key files created in `repo_root` |
| `fake_remote` | Callable or class that records commands and returns scripted stdout/stderr/exit code |
| `run_context_minimal` | `RunContext` with small `BenchParams` for orchestrator tests |
| `assert_ssh_argv` | Helper asserting `-i`, hostname, and `BatchMode=yes` (or project policy) |

The **fake remote** is the main seam: it implements the same contract as real SSH without network I/O.

---

## 5. Layered Test Strategy (Maps to Architecture)

### 5.1 Config (`bench/config/`)

- Parse valid/invalid `config.cfg`; key path resolution relative to repo root.
- No subprocess.

### 5.2 Remote (`bench/remote/ssh.py`)

- Command vector construction (hostname, identity file, timeout-related options).
- `subprocess.run` mocked: success, timeout, non-zero exit.

### 5.3 Stages (`bench/stages/`)

- Each stage tested with **`fake_remote`** returning canned outputs for success/failure branches.
- Assert **which commands** were issued (docker cleanup vs deploy vs benchmark trigger), not Docker behavior.

### 5.4 Metrics (`bench/metrics/`)

- Pure functions: synthetic timestamps/counters → throughput; known arrays → quantiles.
- Golden files optional: small text blobs for CPU parsers under `tests/fixtures/cpu/` if needed.

### 5.5 Results (`bench/results/`)

- **`tmp_path`**: create `result.csv`, assert next path is `result-1.csv`.
- CSV header stability and escaping.

### 5.6 Orchestrator (`bench/orchestrator.py`)

- Patch stage functions or inject a **stub pipeline**: record call order `[preflight, cleanup, deploy, benchmark, metrics, results, teardown]`.
- Failure injection at a stage → verify retries/teardown/exits **without** real SSH.

### 5.7 CLI (`bench/cli.py`)

- Invoke parser with argv lists; defaults match overall-plan defaults (connections, duration, etc.).

---

## 6. Coverage Expectations (High Level)

| Area | Minimum unit coverage |
|------|------------------------|
| Config loader | All keys, missing key, bad paths |
| SSH wrapper | Happy path + failure exit + timeout/retryable classification |
| Each stage | At least one success + one controlled failure |
| Metrics | Correct math + malformed input handling |
| Results paths | Indexing edge cases (empty dir, many existing files) |
| Orchestrator | Full order + interrupt/failure teardown + structured retryability + preemptive timeout |

Detailed case lists remain in **`feature*-plan.md`** Unit Test Specification sections.

---

## 7. Integration / E2E (Optional)

- Guard with `@pytest.mark.integration` and `pytest.ini` **exclude by default** or env var.
- Document in `tests/integration/README.md`: prerequisites (two hosts, Docker, keys).
- Optional smoke: small connection count — aligns with **Validation Strategy** in `overall-plan.md`.
- Integration smoke validates `synthetic_metrics=false` for normal real-host runs.

---

## 8. Running Tests

```bash
pytest tests/unit -q
```

Optional:

```bash
RUN_INTEGRATION=1 pytest tests/integration -q
```

---

## 9. Alignment Checklist (vs `overall-plan.md`)

- [x] Tests runnable without manual hosts for core development.
- [x] Structure supports incremental delivery per feature (unit tests beside each layer).
- [x] CSV indexing and metric shapes testable without a live benchmark.
- [x] Integration path reserved for smoke/scale validation per overall validation strategy.

---

## 10. Relation to `architecture.md`

| Architecture module | Primary test home |
|---------------------|-------------------|
| `bench/config/loader.py` | `tests/unit/test_config_loader.py` |
| `bench/remote/ssh.py` | `tests/unit/test_ssh_remote.py` |
| `bench/stages/*.py` | `tests/unit/test_<stage>_stage.py` |
| `bench/metrics/*.py` | `tests/unit/test_metrics_*.py` |
| `bench/results/*.py` | `tests/unit/test_results_*.py` |
| `bench/orchestrator.py` | `tests/unit/test_orchestrator.py` |
| `bench/cli.py` | `tests/unit/test_cli.py` |

Keeping this mapping stable makes **tests-architecture** and **architecture** stay in sync as the codebase grows.
