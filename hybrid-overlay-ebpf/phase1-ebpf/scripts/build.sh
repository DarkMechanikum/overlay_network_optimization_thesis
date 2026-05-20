#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THESIS_ROOT="$(cd "${ROOT}/../.." && pwd)"
BUILD_DIR="${ROOT}/build"
OBJ="${BUILD_DIR}/flow_classifier.bpf.o"
BPF_HEADERS="${BPF_HEADERS:-${ROOT}/vendor/bpf}"
if [[ ! -f "${BPF_HEADERS}/bpf_helpers.h" && -f "${THESIS_ROOT}/references/ONCache/headers/bpf/bpf_helpers.h" ]]; then
	BPF_HEADERS="${THESIS_ROOT}/references/ONCache/headers/bpf"
fi
CLANG="${CLANG:-clang}"
ARCH="$(uname -m)"
TARGET_ARCH="x86"

case "${ARCH}" in
x86_64|amd64)
	TARGET_ARCH="x86"
	UAPI_ARCH="x86"
	;;
aarch64|arm64)
	TARGET_ARCH="arm64"
	UAPI_ARCH="arm64"
	;;
*)
	echo "Unsupported architecture: ${ARCH}" >&2
	exit 1
	;;
esac

if ! command -v "${CLANG}" >/dev/null 2>&1; then
	for candidate in clang-10 clang-11 clang-12 clang-14 clang /usr/lib/llvm-*/bin/clang; do
		if command -v "${candidate}" >/dev/null 2>&1; then
			CLANG="${candidate}"
			break
		fi
	done
fi

if ! command -v "${CLANG}" >/dev/null 2>&1; then
	echo "clang is required to build the eBPF object" >&2
	exit 1
fi

if [[ ! -f "${BPF_HEADERS}/bpf_helpers.h" ]]; then
	echo "Missing libbpf headers at ${BPF_HEADERS}" >&2
	exit 1
fi

mkdir -p "${BUILD_DIR}"

UAPI_INCLUDES=()
if [[ -d "/usr/lib/linux/uapi/${UAPI_ARCH}" ]]; then
	UAPI_INCLUDES+=("-I/usr/lib/linux/uapi/${UAPI_ARCH}")
fi
if [[ -d "/usr/include/${ARCH}-linux-gnu" ]]; then
	UAPI_INCLUDES+=("-I/usr/include/${ARCH}-linux-gnu")
fi
if [[ -d "/usr/include" ]]; then
	UAPI_INCLUDES+=("-I/usr/include")
fi
if [[ ${#UAPI_INCLUDES[@]} -eq 0 ]]; then
	echo "Missing kernel UAPI headers for ${ARCH}" >&2
	exit 1
fi

CLANG_FLAGS=(
	-O2
	-target bpf
	-mcpu=v2
	"-D__TARGET_ARCH_${TARGET_ARCH}"
	"-I${ROOT}/ebpf"
	"-I${BPF_HEADERS}"
	"${UAPI_INCLUDES[@]}"
	-c "${ROOT}/ebpf/flow_classifier.bpf.c"
	-o "${OBJ}"
)

if [[ -n "${SAMPLE_DIVISOR:-}" ]]; then
	CLANG_FLAGS=(-D"SAMPLE_DIVISOR=${SAMPLE_DIVISOR}" "${CLANG_FLAGS[@]}")
fi

if [[ -n "${FLOW_STATS_MAX_ENTRIES:-}" ]]; then
	CLANG_FLAGS=(-D"FLOW_STATS_MAX_ENTRIES=${FLOW_STATS_MAX_ENTRIES}" "${CLANG_FLAGS[@]}")
fi

"${CLANG}" "${CLANG_FLAGS[@]}"
echo "Built ${OBJ}"
