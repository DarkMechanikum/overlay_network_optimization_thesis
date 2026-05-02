# overlay_network_optimization_thesis

## Run Benchmarks

Run from repository root:

```bash
python3 -m bench.cli --config config.cfg
```

Important runtime flags:

- `--timeout`: per-stage orchestrator deadline (enforced preemptively).
- `--retries`: retry count for retryable stage failures.
- `--cpu-window-seconds`: CPU metric window size; per-window top/bottom/CV are averaged across windows.
- `--allow-synthetic-telemetry`: opt-in fallback when runtime telemetry is unavailable.

## Testing

Unit tests:

```bash
python3 -m pytest tests/unit -q
```

Full suite (integration remains opt-in):

```bash
python3 -m pytest tests -q
```

Integration smoke:

```bash
RUN_INTEGRATION=1 INTEGRATION_CONFIG_PATH=/absolute/path/to/config.cfg python3 -m pytest tests/integration/test_functional_smoke.py -q -rs
```

## Migration Notes

- Validation is now centralized in `bench/config/validation.py`. Invalid run parameters fail before orchestration starts.
- Retry behavior is now driven by explicit `retryable` metadata, not message substring matching.
- Stage timeout is enforced preemptively; a hung stage now fails fast with typed timeout failure payload.
- Poll loops in deploy/benchmark now sleep using configured poll intervals and record poll observability (`attempts`, `elapsed_seconds`, `terminal_reason`).
- Synthetic telemetry is disabled by default. If runtime telemetry is missing and synthetic mode is not enabled, benchmark stage fails with an actionable error.