from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path


class FlowProfileError(ValueError):
    """Raised when flow profile generation input is invalid."""


@dataclass(frozen=True)
class FlowEntry:
    flow_id: str
    flow_index: int
    src_port: int
    dst_port: int
    target_pps: int
    packet_size: int
    sender_role: str = "host1"
    receiver_role: str = "host2"


def generate_flow_profile(
    *,
    num_connections: int,
    base_pps: int,
    packet_size: int,
    src_port_start: int,
    dst_port_start: int,
    max_port: int,
) -> list[FlowEntry]:
    if num_connections <= 0:
        raise FlowProfileError("num_connections must be > 0")
    if base_pps <= 0:
        raise FlowProfileError("base_pps must be > 0")
    if packet_size <= 0:
        raise FlowProfileError("packet_size must be > 0")
    if src_port_start <= 0 or dst_port_start <= 0 or max_port <= 0:
        raise FlowProfileError("port values must be > 0")
    if src_port_start > max_port or dst_port_start > max_port:
        raise FlowProfileError("port start values must be <= max_port")

    max_flows_src = max_port - src_port_start + 1
    max_flows_dst = max_port - dst_port_start + 1
    if num_connections > min(max_flows_src, max_flows_dst):
        raise FlowProfileError(
            "insufficient port space for requested connections; "
            f"requested={num_connections}, available={min(max_flows_src, max_flows_dst)}"
        )

    flows: list[FlowEntry] = []
    tuples: set[tuple[int, int]] = set()
    for index in range(num_connections):
        src_port = src_port_start + index
        dst_port = dst_port_start + index
        tup = (src_port, dst_port)
        if tup in tuples:
            raise FlowProfileError(f"port tuple collision at flow index {index}: {tup}")
        tuples.add(tup)
        flows.append(
            FlowEntry(
                flow_id=f"flow-{index}",
                flow_index=index,
                src_port=src_port,
                dst_port=dst_port,
                target_pps=base_pps + index,
                packet_size=packet_size,
            )
        )
    return flows


def write_flow_profile_json(flows: list[FlowEntry], output_path: Path) -> Path:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": 1,
        "flow_count": len(flows),
        "flows": [asdict(flow) for flow in flows],
    }
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return output_path


def read_flow_profile_json(path: Path) -> list[FlowEntry]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    return [FlowEntry(**entry) for entry in raw.get("flows", [])]
