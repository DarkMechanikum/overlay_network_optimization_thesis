# Feature 6 Plan: CSV Result Assembly, Indexed File Naming, and Artifacts

## Objective
Persist benchmark outputs into non-overwriting CSV results with full run metadata.

## Deliverables
- CSV writer for per-flow results.
- Filename indexing logic (`result.csv`, `result-1.csv`, `result-2.csv`, ...).
- Run artifact directory with raw files and manifest.

## Detailed Steps
1. Define output directory structure:
   - `results/` for final CSV files,
   - `artifacts/<run_id>/` for raw logs and intermediate files.
2. Implement filename resolver:
   - if `result.csv` does not exist -> use it,
   - else increment suffix until free filename is found.
3. Define CSV columns:
   - run metadata (timestamp, duration, connection count, packet size, host IDs),
   - flow metadata (flow_id, src_port, dst_port, target_pps),
   - measured metrics (throughput, p50, p99, p99.9, CPU summary fields),
   - status/error columns.
4. Write CSV deterministically (stable column order, UTF-8, newline-safe).
5. Save metadata manifest (`run.json`) with config snapshot and tool versions.
6. Save host command outputs and parser inputs in artifact folder.
7. Print final output paths and high-level run summary to console.

## Data Integrity Rules
- Never overwrite existing result files.
- Require successful file flush and fsync-equivalent behavior before completion.
- Validate row count matches number of attempted flows (or include explicit missing rows).

## Acceptance Criteria
- Multiple consecutive runs produce uniquely indexed result CSV files.
- CSV is analyzable directly in spreadsheet/pandas without manual cleanup.
- Raw artifacts are preserved for post-run debugging and reproducibility.

## Unit Test Specification
- **Test framework:** `pytest` with `tmp_path` filesystem fixtures.
- **Core test cases:**
  - filename resolver picks `result.csv` when absent.
  - resolver increments correctly to `result-1.csv`, `result-2.csv`, etc. when files exist.
  - CSV writer outputs stable column order and expected header names.
  - row writer handles special characters/newlines safely.
  - artifact manifest writer stores required metadata fields (`run_id`, params, versions).
  - integrity validator flags row-count mismatches and missing mandatory columns.
- **Fixtures/mocks:**
  - temporary results directory pre-populated with varying filename states.
  - sample metric rows including failed-flow status entries.
- **Pass criteria:**
  - no overwrite behavior guaranteed by tests.
  - generated CSV loads cleanly using standard parser (`csv`/`pandas`) in test.
