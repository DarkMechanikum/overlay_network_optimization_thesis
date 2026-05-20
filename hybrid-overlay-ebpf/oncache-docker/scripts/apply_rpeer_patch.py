#!/usr/bin/env python3
"""Apply ONCache rpeer hunks to net/core/filter.c in an extracted kernel tree."""
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <dst filter.c> <patch-source filter.c>", file=sys.stderr)
        return 1
    dst_path, src_path = sys.argv[1:3]
    dst = open(dst_path).read()
    src = open(src_path).read()
    if not re.search(r"BPF_F_RPEER\s*=", dst):
        m = re.search(r"BPF_F_NEXTHOP\s*=\s*\(1ULL << (\d+)\),", dst)
        if not m:
            print("BPF_F_NEXTHOP enum entry not found", file=sys.stderr)
            return 1
        rpeer_shift = int(m.group(1)) + 1
        dst = re.sub(
            r"(BPF_F_NEXTHOP\s*=\s*\(1ULL << \d+\),)",
            rf"\1\n\tBPF_F_RPEER = (1ULL << {rpeer_shift}),",
            dst,
            count=1,
        )
        dst = re.sub(
            r"#define BPF_F_REDIRECT_INTERNAL\s+\(BPF_F_NEIGH \| BPF_F_PEER \| BPF_F_NEXTHOP\)",
            "#define BPF_F_REDIRECT_INTERNAL\t(BPF_F_NEIGH | BPF_F_PEER | BPF_F_NEXTHOP | BPF_F_RPEER)",
            dst,
            count=1,
        )
        src_fn = src[src.find("int skb_do_redirect") : src.find("BPF_CALL_2(bpf_redirect")]
        dst_start = dst.find("int skb_do_redirect")
        dst_end = dst.find("BPF_CALL_2(bpf_redirect", dst_start)
        if dst_start < 0 or dst_end < 0 or not src_fn:
            print("skb_do_redirect splice failed", file=sys.stderr)
            return 1
        dst = dst[:dst_start] + src_fn + dst[dst_end:]

    if "bpf_redirect_rpeer" not in dst:
        fn_start = src.find("BPF_CALL_2(bpf_redirect_rpeer")
        fn_end = src.find("static const struct bpf_func_proto bpf_redirect_rpeer_proto", fn_start)
        fn_end = src.find("};", fn_end) + 2
        insert_at = dst.find("static const struct bpf_func_proto bpf_redirect_peer_proto")
        if insert_at < 0:
            print("insert point missing", file=sys.stderr)
            return 1
        dst = dst[:insert_at] + src[fn_start:fn_end] + "\n\n" + dst[insert_at:]
        case_needle = "case BPF_FUNC_redirect_peer:"
        case_block = src[src.find("case BPF_FUNC_redirect_rpeer:") : src.find("case BPF_FUNC_redirect_neigh:")]
        if case_needle in dst and "BPF_FUNC_redirect_rpeer" not in dst:
            dst = dst.replace(case_needle, case_block + "\n\t" + case_needle, 1)

    open(dst_path, "w").write(dst)
    print("patched", dst_path)
    kernel_src = dst_path.split("/net/core/filter.c")[0]
    patch_bpf_h(f"{kernel_src}/include/uapi/linux/bpf.h")
    patch_filter_case(dst_path)
    return 0


def patch_bpf_h(bpf_h_path: str) -> bool:
    text = open(bpf_h_path).read()
    if "FN(redirect_rpeer)" in text:
        return False
    needle = "\tFN(redirect_peer),\t\t\\\n\tFN(task_storage_get),"
    repl = "\tFN(redirect_peer),\t\t\\\n\tFN(redirect_rpeer),\t\t\\\n\tFN(task_storage_get),"
    if needle not in text:
        raise SystemExit(f"bpf.h redirect_peer block not found in {bpf_h_path}")
    open(bpf_h_path, "w").write(text.replace(needle, repl, 1))
    print("patched", bpf_h_path)
    return True


def patch_filter_case(dst_path: str) -> bool:
    dst = open(dst_path).read()
    if "case BPF_FUNC_redirect_rpeer:" in dst:
        return False
    needle = "\tcase BPF_FUNC_redirect_peer:\n\t\treturn &bpf_redirect_peer_proto;\n"
    repl = (
        needle
        + "\tcase BPF_FUNC_redirect_rpeer:\n\t\treturn &bpf_redirect_rpeer_proto;\n"
    )
    if needle not in dst:
        raise SystemExit("filter.c redirect_peer case not found")
    open(dst_path, "w").write(dst.replace(needle, repl, 1))
    print("patched filter.c switch case")
    return True


if __name__ == "__main__":
    raise SystemExit(main())
