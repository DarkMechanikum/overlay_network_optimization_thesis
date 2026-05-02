from __future__ import annotations

import csv
from pathlib import Path

from bench.results.csv_writer import CSV_COLUMNS, validate_metric_rows, write_metrics_csv


def test_csv_writer_header_order_and_partial_rows(tmp_path: Path) -> None:
    rows = [
        {"run_id": "r1", "flow_id": "f1", "status": "ok", "error": "", "pps": 100.0},
        {"run_id": "r1", "flow_id": "f2", "status": "partial_failure", "error": "x\nline2", "pps": None},
    ]
    out = write_metrics_csv(tmp_path / "result.csv", rows)
    with out.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        assert header == CSV_COLUMNS
        body = list(reader)
        assert len(body) == 2
        assert body[1][header.index("error")] == "x\nline2"


def test_validate_metric_rows_integrity_errors() -> None:
    rows = [{"run_id": "r1", "flow_id": "", "status": "ok"}]
    errors = validate_metric_rows(rows, expected_count=2)
    assert any("row count mismatch" in err for err in errors)
    assert any("missing mandatory fields" in err for err in errors)
