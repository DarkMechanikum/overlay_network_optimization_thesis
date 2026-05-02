# Architecture (Program Skeleton)

This document defines the structural skeleton of the benchmark automation program. It aligns with [`overall-plan.md`](overall-plan.md): a **local orchestrator**, **SSH-based remote execution** driven by [`config.cfg`](config.cfg), **containers on two hosts**, and a **measurement plane** that produces **per-connection metrics** plus **CPU/core utilization**, persisted as **indexed CSV** and raw **artifacts**.

Feature-specific algorithms (traffic shaping, parsers, Docker image contents) belong in [`feature*-plan.md`](feature1-plan.md) files, not here.

---

## 1. Roles and Boundaries

| Plane | Responsibility | Runs where |
|-------|----------------|------------|
| Control | Parse config and CLI; sequence stages; timeouts, retries, teardown | Local machine only |
| Remote execution | SSH commands (and optional SCP/rsync); capture stdout/stderr | Local invokes; work on hosts |
| Runtime under test | Docker lifecycle, benchmark workloads (sender/receiver) | Remote hosts |
| Measurement | Aggregate raw probes into throughput, latency quantiles, CPU series | Mostly local orchestration logic; probes may run remotely |
| Persistence | Versioned CSV, manifests, artifact directories | Local filesystem |

Nothing in this skeleton mandates a particular benchmark tool inside the containers; only that **inputs** (run parameters, profiles) and **outputs** (raw logs, normalized rows) cross these boundaries cleanly.

---

## 2. Top-Level Entry Points

Suggested layout (names are placeholders; adjust to repo conventions):

```
bench/
  __init__.py
  cli.py                 # argparse: run params + operational flags
  orchestrator.py        # stage pipeline: validates order, delegates, aggregates RunContext
  context.py             # RunContext / RunConfig dataclasses (immutable where practical)
bench/config/
  __init__.py
  loader.py              # read config.cfg → HostConfig pair + repo-root resolution
bench/remote/
  __init__.py
  ssh.py                 # build ssh argv; execute one-shot commands; streaming optional
bench/stages/
  __init__.py
  preflight.py           # dependency checks via remote commands
  cleanup.py             # docker/host baseline preparation
  deploy.py              # image build/load + container start + readiness
  benchmark.py           # trigger benchmark window; coordinate start/stop markers
bench/metrics/
  __init__.py
  throughput.py          # derive rates from counters/timestamps
  latency.py             # quantiles; warmup exclusion
  cpu.py                 # normalize mpstat/proc samples → per-core utilization
  merge.py               # combine flow-level + host-level metrics into rows
bench/results/
  __init__.py
  paths.py               # resolve result.csv / result-N.csv without overwrite
  csv_writer.py          # deterministic columns; UTF-8 safe
  manifest.py            # run.json payload (metadata snapshot)
bench/artifacts/
  __init__.py
  layout.py              # artifacts/<run_id>/ directory naming
  sink.py                # append raw stdout files, optional checksums
```

**Single user-facing command:** `python -m bench.cli ...` (or a thin wrapper script at repo root). That matches the overall goal of **one orchestrator executable from the local machine**.

---

## 3. Core Runtime Objects

These types form the backbone; implementations stay thin here.

### 3.1 Configuration

- **`HostConfig`** — resolved fields from `config.cfg`: IP (informational), SSH hostname, absolute path to private key, optional labels (`host1` / `host2`).
- **`BenchParams`** — CLI-derived: connection count, base packet rate (or equivalent), duration, warmup/cooldown, packet size, timeouts, retry policy.
- **`ValidatedRunParams`** (`bench/config/validation.py`) — single centralized validation/normalization pass before pipeline start. CLI args are parsed once, validated once, then converted to `BenchParams`.
- **`RunContext`** — combines `HostConfig`, `BenchParams`, generated **`run_id`**, timestamps, artifact root path, and handles to **phase outcomes** (success/failure per stage).

The orchestrator passes **`RunContext`** downward so stages remain stateless aside from context mutation rules you define (e.g., append-only logs).

### 3.2 Remote abstraction

- **`RemoteSession` or protocol** — minimal interface:
  - `run(command: str | list[str], *, timeout: float) -> CompletedProcess-like`
  - Optional: `upload(local_path, remote_path)`, `download(...)`.
- **SSH implementation** uses OpenSSH (`ssh -i key ... hostname -- command`), matching **hostnames from config** and **keys relative to repo root**.

This isolates subprocess/SSH details from stages and enables **tests** to swap in fakes.

---

## 4. Orchestration Skeleton (`orchestrator.py`)

The orchestrator owns **stage order** and **global failure policy** only. No business logic beyond:

1. Load and validate **`RunContext`** (config + CLI).
2. **`preflight`** — exercise remote layer on both hosts; produce a structured report.
3. **`cleanup`** — per-host cleanup according to operational mode (safe vs full; see feature plans).
4. **`deploy`** — prepare images and containers; enforce start order (receiver before sender).
5. **`benchmark`** — start measurement windows, trigger the traffic phase, stop collectors; collect **raw artifacts** (sender/receiver logs, CPU samples).
6. **`metrics`** — parse artifacts into normalized **per-flow** and **per-host** metric objects.
7. **`results`** — write **indexed CSV** + **manifest** under `results/` and `artifacts/<run_id>/`.
8. **`teardown`** — on success or failure: optional container removal, flush logs; configurable **keep vs destroy**.

Stages return **`StageResult(success, message, payload)`**. On failure, payloads use a structured failure shape (`failure.kind`, `failure.message`, `failure.retryable`, `failure.details`) so retry policy is explicit and deterministic.

This matches **overall-plan** ordering: config/SSH → cleanup → Docker → benchmark → metrics → CSV.

---

## 5. Remote Stages (Thin Adapters)

Each module under `bench/stages/` should only:

- Build **remote command strings** or script invocations from **`RunContext`**.
- Invoke **`RemoteSession.run`**.
- Optionally write **remote stdout** to **`artifacts`** via **`sink`**.

They do **not** compute quantiles or CSV layout; that stays in **`bench/metrics`** and **`bench/results`**.

---

## 6. Measurement Pipeline (`bench/metrics/`)

**Inputs:** Raw text/JSON lines produced during the benchmark window (counts, timestamps, CPU tool output).

**Outputs:**

- Per-flow (or per-attempt-flow) records: identifiers, throughput, p50/p99/p99.9, status.
- Per-host CPU: time series or summary over the same window (tagged as system-level when not isolated).

**`merge.py`** joins flow records with CPU summaries by **`run_id`** and **host role** so **`csv_writer`** sees a single row model.

This reflects the **measurement plane** in the overall plan without fixing a specific file format here.

---

## 7. Results and Artifacts (`bench/results/`, `bench/artifacts/`)

- **`paths.py`** — implements **non-overwriting** `result.csv`, `result-1.csv`, … matching the overall deliverable.
- **`csv_writer.py`** — fixed column order; one row per flow (or per flow attempt) plus optional **summary** row if you add it later.
- **`manifest.py`** — `run.json`: tool versions, git commit if available, copy of **`BenchParams`**, host identities, stage timestamps.
- **`artifacts/layout.py`** — `artifacts/<run_id>/host1/`, `host2/`, `local/` if needed.

---

## 8. Cross-Cutting Concerns

| Concern | Where it lives |
|--------|----------------|
| Logging (stage markers, host prefix) | `orchestrator` + small `bench/logutil.py` if needed |
| Timeouts | Per remote call in `ssh.py`; preemptive per-stage deadline in `orchestrator` |
| Retries | Explicit `retryable` semantics in failure payloads; orchestrator consumes structured retryability |
| Dry-run | CLI flag that skips mutating stages but still validates wiring (see feature 7 plan) |
| Polling | Shared `poll_with_interval` helper for deploy/benchmark readiness and startup checks |
| Telemetry policy | Synthetic telemetry fallback is opt-in (`allow_synthetic_telemetry=False` by default) |

---

## 9. Alignment Checklist (vs `overall-plan.md`)

- [x] Single local orchestrator command.
- [x] SSH + `config.cfg` hostnames and keys as first-class inputs.
- [x] Separation: control vs remote execution vs measurement vs persistence.
- [x] Containers and traffic on hosts; aggregation and CSV on local machine.
- [x] Per-connection throughput + p50/p99/p99.9 + per-core CPU in the **data model** path.
- [x] Indexed CSV + artifact storage as explicit modules.
- [x] Raw outputs preserved for reproducibility before normalized CSV.

---

## 10. Non-Goals (This Document)

- Choosing iperf vs custom UDP tools (feature 4).
- Dockerfile contents (feature 3).
- Exact mpstat column mapping (feature 5).
- Full retry matrix (feature 7).

Those remain in **`feature*-plan.md`** and implementation.
