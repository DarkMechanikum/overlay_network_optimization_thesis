from __future__ import annotations

from argparse import Namespace
from dataclasses import dataclass

from bench.context import BenchParams


@dataclass(frozen=True)
class ValidationError(ValueError):
    field: str
    reason: str

    def __str__(self) -> str:
        return f"Invalid '{self.field}': {self.reason}"


@dataclass(frozen=True)
class ValidatedRunParams:
    connections: int
    duration_seconds: int
    warmup_seconds: int
    cooldown_seconds: int
    base_pps: int
    packet_size: int
    ssh_timeout_seconds: float
    cleanup_mode: str
    confirm_full_cleanup: bool
    host_temp_root: str
    disk_warn_percent: int
    memory_warn_mb: int
    deployment_mode: str
    readiness_timeout_seconds: float
    readiness_poll_interval_seconds: float
    image_tag: str
    local_image_archive: str
    container_network_mode: str
    src_port_start: int
    dst_port_start: int
    max_port: int
    flow_startup_timeout_seconds: float
    flow_startup_poll_interval_seconds: float
    retries: int
    retry_backoff_seconds: float
    stage_timeout_seconds: float
    keep_containers: bool
    dry_run: bool
    fallback_runtime_image: str
    cpu_window_seconds: float
    allow_synthetic_telemetry: bool

    @classmethod
    def from_namespace(cls, args: Namespace) -> "ValidatedRunParams":
        raw = cls(
            connections=args.connections,
            duration_seconds=args.duration_seconds,
            warmup_seconds=args.warmup_seconds,
            cooldown_seconds=args.cooldown_seconds,
            base_pps=args.base_pps,
            packet_size=args.packet_size,
            ssh_timeout_seconds=args.ssh_timeout_seconds,
            cleanup_mode=args.cleanup_mode,
            confirm_full_cleanup=args.confirm_full_cleanup,
            host_temp_root=args.host_temp_root,
            disk_warn_percent=args.disk_warn_percent,
            memory_warn_mb=args.memory_warn_mb,
            deployment_mode=args.deployment_mode,
            readiness_timeout_seconds=args.readiness_timeout_seconds,
            readiness_poll_interval_seconds=args.readiness_poll_interval_seconds,
            image_tag=args.image_tag,
            local_image_archive=args.local_image_archive,
            container_network_mode=args.container_network_mode,
            src_port_start=args.src_port_start,
            dst_port_start=args.dst_port_start,
            max_port=args.max_port,
            flow_startup_timeout_seconds=args.flow_startup_timeout_seconds,
            flow_startup_poll_interval_seconds=args.flow_startup_poll_interval_seconds,
            retries=args.retries,
            retry_backoff_seconds=getattr(args, "retry_backoff_seconds", 0.0),
            stage_timeout_seconds=args.timeout,
            keep_containers=args.keep_containers,
            dry_run=args.dry_run,
            fallback_runtime_image=args.fallback_runtime_image,
            cpu_window_seconds=args.cpu_window_seconds,
            allow_synthetic_telemetry=args.allow_synthetic_telemetry,
        )
        raw._validate()
        return raw

    def to_bench_params(self) -> BenchParams:
        return BenchParams(
            connections=self.connections,
            duration_seconds=self.duration_seconds,
            warmup_seconds=self.warmup_seconds,
            cooldown_seconds=self.cooldown_seconds,
            base_pps=self.base_pps,
            packet_size=self.packet_size,
            ssh_timeout_seconds=self.ssh_timeout_seconds,
            cleanup_mode=self.cleanup_mode,
            confirm_full_cleanup=self.confirm_full_cleanup,
            host_temp_root=self.host_temp_root,
            disk_warn_percent=self.disk_warn_percent,
            memory_warn_mb=self.memory_warn_mb,
            deployment_mode=self.deployment_mode,
            readiness_timeout_seconds=self.readiness_timeout_seconds,
            readiness_poll_interval_seconds=self.readiness_poll_interval_seconds,
            image_tag=self.image_tag,
            local_image_archive=self.local_image_archive,
            container_network_mode=self.container_network_mode,
            src_port_start=self.src_port_start,
            dst_port_start=self.dst_port_start,
            max_port=self.max_port,
            flow_startup_timeout_seconds=self.flow_startup_timeout_seconds,
            flow_startup_poll_interval_seconds=self.flow_startup_poll_interval_seconds,
            retries=self.retries,
            retry_backoff_seconds=self.retry_backoff_seconds,
            stage_timeout_seconds=self.stage_timeout_seconds,
            keep_containers=self.keep_containers,
            dry_run=self.dry_run,
            fallback_runtime_image=self.fallback_runtime_image,
            cpu_window_seconds=self.cpu_window_seconds,
            allow_synthetic_telemetry=self.allow_synthetic_telemetry,
        )

    def _validate(self) -> None:
        self._require_int_ge("connections", self.connections, 1)
        self._require_int_ge("duration_seconds", self.duration_seconds, 1)
        self._require_int_ge("warmup_seconds", self.warmup_seconds, 0)
        self._require_int_ge("cooldown_seconds", self.cooldown_seconds, 0)
        if self.warmup_seconds + self.cooldown_seconds >= self.duration_seconds:
            raise ValidationError(
                "duration_seconds",
                "must be greater than warmup_seconds + cooldown_seconds",
            )

        self._require_int_ge("base_pps", self.base_pps, 1)
        self._require_int_ge("packet_size", self.packet_size, 1)
        self._require_float_gt("ssh_timeout_seconds", self.ssh_timeout_seconds, 0.0)
        self._require_float_gt("readiness_timeout_seconds", self.readiness_timeout_seconds, 0.0)
        self._require_float_gt("readiness_poll_interval_seconds", self.readiness_poll_interval_seconds, 0.0)
        self._require_float_gt("flow_startup_timeout_seconds", self.flow_startup_timeout_seconds, 0.0)
        self._require_float_gt("flow_startup_poll_interval_seconds", self.flow_startup_poll_interval_seconds, 0.0)
        self._require_int_ge("retries", self.retries, 0)
        self._require_float_ge("retry_backoff_seconds", self.retry_backoff_seconds, 0.0)
        self._require_float_gt("timeout", self.stage_timeout_seconds, 0.0)
        self._require_float_gt("cpu_window_seconds", self.cpu_window_seconds, 0.0)
        self._require_int_ge("src_port_start", self.src_port_start, 1)
        self._require_int_ge("dst_port_start", self.dst_port_start, 1)
        self._require_int_ge("max_port", self.max_port, 1)
        if self.src_port_start > self.max_port:
            raise ValidationError("src_port_start", "must be <= max_port")
        if self.dst_port_start > self.max_port:
            raise ValidationError("dst_port_start", "must be <= max_port")
        self._require_int_between("disk_warn_percent", self.disk_warn_percent, 1, 100)
        self._require_int_ge("memory_warn_mb", self.memory_warn_mb, 1)
        self._require_non_empty("host_temp_root", self.host_temp_root)
        self._require_non_empty("image_tag", self.image_tag)
        self._require_non_empty("local_image_archive", self.local_image_archive)
        self._require_non_empty("container_network_mode", self.container_network_mode)
        self._require_non_empty("fallback_runtime_image", self.fallback_runtime_image)

    @staticmethod
    def _require_int_ge(field: str, value: int, minimum: int) -> None:
        if value < minimum:
            raise ValidationError(field, f"must be >= {minimum} (got {value})")

    @staticmethod
    def _require_float_ge(field: str, value: float, minimum: float) -> None:
        if value < minimum:
            raise ValidationError(field, f"must be >= {minimum} (got {value})")

    @staticmethod
    def _require_float_gt(field: str, value: float, minimum: float) -> None:
        if value <= minimum:
            raise ValidationError(field, f"must be > {minimum} (got {value})")

    @staticmethod
    def _require_int_between(field: str, value: int, lo: int, hi: int) -> None:
        if value < lo or value > hi:
            raise ValidationError(field, f"must be between {lo} and {hi} (got {value})")

    @staticmethod
    def _require_non_empty(field: str, value: str) -> None:
        if not value.strip():
            raise ValidationError(field, "must not be empty")
