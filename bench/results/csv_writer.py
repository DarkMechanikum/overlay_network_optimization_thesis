from __future__ import annotations

import csv
from pathlib import Path
from typing import Any


CSV_COLUMNS = [
    "run_id",
    "run_timestamp",
    "duration_seconds",
    "connection_count",
    "packet_size",
    "host1_id",
    "host2_id",
    "flow_id",
    "src_port",
    "dst_port",
    "target_pps",
    "pps",
    "bps",
    "latency_p50",
    "latency_p99",
    "latency_p999",
    "sender_cpu_avg",
    "receiver_cpu_avg",
    "sender_cpu_core_cv",
    "receiver_cpu_core_cv",
    "sender_cpu_top_core_utilization",
    "receiver_cpu_top_core_utilization",
    "sender_cpu_bottom_core_utilization",
    "receiver_cpu_bottom_core_utilization",
    "status",
    "error",
]

REQUIRED_FIELDS = {"run_id", "flow_id", "status"}


def validate_metric_rows(rows: list[dict[str, Any]], expected_count: int | None = None) -> list[str]:
    errors: list[str] = []
    if expected_count is not None and len(rows) != expected_count:
        errors.append(f"row count mismatch: expected {expected_count}, got {len(rows)}")
    for idx, row in enumerate(rows):
        missing = [field for field in REQUIRED_FIELDS if not row.get(field)]
        if missing:
            errors.append(f"row {idx} missing mandatory fields: {', '.join(missing)}")
    return errors


def write_metrics_csv(path: Path, rows: list[dict[str, Any]]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in CSV_COLUMNS})
    return path
