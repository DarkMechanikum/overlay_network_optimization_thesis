from __future__ import annotations

from pathlib import Path

import pytest

from bench.stages.flow_profile import FlowProfileError, generate_flow_profile, read_flow_profile_json, write_flow_profile_json


def test_flow_table_generates_exact_count_unique_tuples_and_pps_sequence() -> None:
    flows = generate_flow_profile(
        num_connections=6,
        base_pps=100,
        packet_size=128,
        src_port_start=20000,
        dst_port_start=30000,
        max_port=65535,
    )
    assert len(flows) == 6
    tuples = {(flow.src_port, flow.dst_port) for flow in flows}
    assert len(tuples) == 6
    assert [flow.target_pps for flow in flows] == [100, 101, 102, 103, 104, 105]


def test_flow_profile_is_deterministic_for_same_input() -> None:
    kwargs = dict(
        num_connections=4,
        base_pps=50,
        packet_size=64,
        src_port_start=22000,
        dst_port_start=32000,
        max_port=65535,
    )
    flows1 = generate_flow_profile(**kwargs)
    flows2 = generate_flow_profile(**kwargs)
    assert flows1 == flows2


def test_invalid_insufficient_port_range_raises_clear_error() -> None:
    with pytest.raises(FlowProfileError, match="insufficient port space"):
        generate_flow_profile(
            num_connections=5,
            base_pps=100,
            packet_size=128,
            src_port_start=65000,
            dst_port_start=65000,
            max_port=65002,
        )


def test_profile_serialization_roundtrip(tmp_path: Path) -> None:
    flows = generate_flow_profile(
        num_connections=3,
        base_pps=10,
        packet_size=256,
        src_port_start=20000,
        dst_port_start=20100,
        max_port=65535,
    )
    path = write_flow_profile_json(flows, tmp_path / "flow-profile.json")
    loaded = read_flow_profile_json(path)
    assert loaded == flows
