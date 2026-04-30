#!/usr/bin/env bash
# macFUSE performance baseline for libfuse-fs passthrough.
#
# Mounts examples/passthrough on macFUSE, runs the fio jobs in
# bench/fio.cfg, parses results into JSON, and appends to the baseline doc.
#
# Skips cleanly on non-macOS or when macFUSE / fio aren't available.
#
# Modes
# -----
#   default        single run (lazy mode, label = $LABEL or timestamp)
#   --ab           lazy=true vs lazy=false back-to-back, prints per-job
#                  ratio and writes both runs + ratio block to baseline.
#                  Aborts if any other macFUSE mount is detected (system
#                  noise dominated past results).
#
# Optional env:
#   MOUNT_POINT         Default: /tmp/libfusefs-bench-mnt
#   ROOT_DIR            Default: /tmp/libfusefs-bench-root
#   PASSTHROUGH_BIN     Default: target/release/examples/passthrough
#   FIO_CFG             Default: bench/fio.cfg
#   LABEL               Free-form label tagging this run (e.g. "baseline-pre-A")
#   KEEP_MOUNT          Set to 1 to leave mount up afterwards
#   AB_ALLOW_NOISE      Set to 1 to bypass the no-other-mount precondition
#                       (use only when you accept noisy numbers).

set -euo pipefail

AB_MODE=0
if [[ "${1:-}" == "--ab" ]]; then
    AB_MODE=1
    shift
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve the cargo target directory used by this workspace. Honour
# CARGO_TARGET_DIR; otherwise probe the package's own target/ first, then walk
# up looking for a workspace-level target/.
resolve_target_dir() {
    if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
        echo "$CARGO_TARGET_DIR"
        return
    fi
    if command -v cargo >/dev/null 2>&1; then
        local d
        d="$(cargo metadata --no-deps --format-version 1 \
                --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
            | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null)"
        if [[ -n "$d" ]]; then
            echo "$d"
            return
        fi
    fi
    echo "$REPO_ROOT/target"
}
TARGET_DIR="$(resolve_target_dir)"

skip() { echo "SKIP: $*" >&2; exit 0; }

# --- env probes -------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || skip "not on macOS"
MACFUSE_BIN="/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse"
[[ -x "$MACFUSE_BIN" ]] || skip "macFUSE not installed"
command -v fio >/dev/null 2>&1 || skip "fio not installed (try: brew install fio)"

PASSTHROUGH_BIN="${PASSTHROUGH_BIN:-$TARGET_DIR/release/examples/passthrough}"
if [[ ! -x "$PASSTHROUGH_BIN" ]]; then
    echo "Building passthrough example (release)…" >&2
    (cd "$REPO_ROOT" && cargo build --release --example passthrough)
fi

FIO_CFG="${FIO_CFG:-$REPO_ROOT/bench/fio.cfg}"
[[ -f "$FIO_CFG" ]] || { echo "FAIL: fio config $FIO_CFG missing" >&2; exit 1; }

MOUNT_POINT="${MOUNT_POINT:-/tmp/libfusefs-bench-mnt}"
ROOT_DIR="${ROOT_DIR:-/tmp/libfusefs-bench-root}"
LABEL="${LABEL:-$(date -u +%Y%m%dT%H%M%SZ)}"

mkdir -p "$MOUNT_POINT" "$ROOT_DIR"
# `mount(8)` reports realpaths (`/tmp` resolves to `/private/tmp` on macOS),
# so we compare against the canonicalized form when checking readiness.
MOUNT_POINT_REAL="$(cd "$MOUNT_POINT" && pwd -P)"

# Number of macFUSE mounts present *outside* this script's mountpoint.
# Past A/B runs were dominated by system noise from concurrent mounts on
# the dev machine; a non-zero count is recorded in the baseline so future
# readers can discount affected numbers.
#
# Implemented in pure awk (instead of `grep -vF | wc -l`) so an empty
# match doesn't trip `set -e -o pipefail`.
count_competing_macfuse_mounts() {
    mount | awk -v self="$MOUNT_POINT_REAL" '/macfuse/ && $3 != self {n++} END {print n+0}'
}

CONCURRENT_MOUNTS="$(count_competing_macfuse_mounts)"

# --- cache flush helper -----------------------------------------------------

flush_caches() {
    sync
    if command -v purge >/dev/null 2>&1; then
        sudo -n purge 2>/dev/null || purge 2>/dev/null || true
    fi
}

REPORT_DIR="$TARGET_DIR/bench"
mkdir -p "$REPORT_DIR"

# --- single-run helper ------------------------------------------------------
#
# Mounts the passthrough example, runs fio, writes raw JSON to
# $REPORT_DIR/<run_label>.json, and appends a markdown table to the
# baseline doc. Optional first arg: extra flags for the example.
#
# Sets: RUN_JSON (path to fio JSON for caller's analysis).
run_once() {
    local run_label="$1"; shift
    local extra_args=("$@")

    local pass_pid=""
    cleanup_run() {
        if [[ -n "$pass_pid" ]]; then
            if mount | grep -q " $MOUNT_POINT_REAL "; then
                umount "$MOUNT_POINT" 2>/dev/null \
                    || diskutil unmount force "$MOUNT_POINT" 2>/dev/null || true
            fi
            kill "$pass_pid" 2>/dev/null || true
            for _ in 1 2 3 4 5 6; do
                kill -0 "$pass_pid" 2>/dev/null || break
                sleep 0.5
            done
            kill -9 "$pass_pid" 2>/dev/null || true
            wait "$pass_pid" 2>/dev/null || true
        fi
    }
    trap cleanup_run RETURN

    # Clean any stale state in the backing dir from prior runs.
    rm -rf "$ROOT_DIR/bench-data" 2>/dev/null || true

    echo "[$run_label] Mounting: $ROOT_DIR -> $MOUNT_POINT (${extra_args[*]:-default})" >&2
    # Splice optional extra args without tripping `set -u` on an empty array.
    "$PASSTHROUGH_BIN" --mountpoint "$MOUNT_POINT" --rootdir "$ROOT_DIR" \
        ${extra_args[@]+"${extra_args[@]}"} &
    pass_pid=$!

    for _ in $(seq 1 20); do
        mount | grep -q " $MOUNT_POINT_REAL " && break
        sleep 0.5
    done
    mount | grep -q " $MOUNT_POINT_REAL " \
        || { echo "FAIL[$run_label]: mount not up" >&2; return 1; }

    local data_dir="$MOUNT_POINT/bench-data"
    mkdir -p "$data_dir"

    flush_caches
    RUN_JSON="$REPORT_DIR/macfuse-bench-$run_label.json"
    echo "[$run_label] Running fio: $FIO_CFG" >&2
    ( cd "$data_dir" && fio --output-format=json "$FIO_CFG" ) >"$RUN_JSON"

    REPO_ROOT="$REPO_ROOT" CONCURRENT_MOUNTS="$CONCURRENT_MOUNTS" \
        python3 - "$RUN_JSON" "$run_label" <<'PYEOF'
import json, os, sys, datetime, pathlib

raw = json.loads(pathlib.Path(sys.argv[1]).read_text())
label = sys.argv[2]
concurrent = os.environ.get("CONCURRENT_MOUNTS", "?")

rows = []
for job in raw.get("jobs", []):
    name = job.get("jobname", "?")
    read = job.get("read", {})
    iops = read.get("iops", 0.0)
    p50  = read.get("clat_ns", {}).get("percentile", {}).get("50.000000", 0)
    p99  = read.get("clat_ns", {}).get("percentile", {}).get("99.000000", 0)
    rows.append((name, iops, p50, p99))

print(f"=== macFUSE bench summary [{label}] ===")
print(f"{'job':<16} {'iops':>12} {'p50_us':>10} {'p99_us':>10}")
for name, iops, p50, p99 in rows:
    print(f"{name:<16} {iops:>12.1f} {p50/1000:>10.1f} {p99/1000:>10.1f}")

repo = pathlib.Path(os.environ.get("REPO_ROOT", "."))
doc = repo / "docs" / "macos-performance-baseline.md"
if doc.exists():
    block = [
        "",
        f"### Run `{label}` — {datetime.datetime.utcnow().isoformat()}Z (concurrent_mounts={concurrent})",
        "",
        "| job | iops | p50 (µs) | p99 (µs) |",
        "| --- | ---: | ---: | ---: |",
    ]
    for name, iops, p50, p99 in rows:
        block.append(f"| {name} | {iops:.1f} | {p50/1000:.1f} | {p99/1000:.1f} |")
    with doc.open("a") as f:
        f.write("\n".join(block) + "\n")
    print(f"Appended summary to {doc}")
PYEOF
}

# --- mode dispatch ----------------------------------------------------------

if [[ "$AB_MODE" == "1" ]]; then
    if [[ "$CONCURRENT_MOUNTS" -gt 0 && "${AB_ALLOW_NOISE:-0}" != "1" ]]; then
        echo "FAIL: $CONCURRENT_MOUNTS other macFUSE mount(s) detected." >&2
        echo "      A/B numbers are dominated by competing-mount noise on this" >&2
        echo "      box (see docs/macos-performance-baseline.md). Unmount them" >&2
        echo "      or set AB_ALLOW_NOISE=1 to override." >&2
        mount | awk '/macfuse/' | sed 's/^/    /' >&2
        exit 1
    fi
    LAZY_LABEL="${LABEL}-lazy"
    EAGER_LABEL="${LABEL}-eager"

    run_once "$LAZY_LABEL"
    run_once "$EAGER_LABEL" --macos-eager

    # Compute and append per-job ratios.
    REPO_ROOT="$REPO_ROOT" CONCURRENT_MOUNTS="$CONCURRENT_MOUNTS" \
        python3 - "$REPORT_DIR/macfuse-bench-$LAZY_LABEL.json" \
                  "$REPORT_DIR/macfuse-bench-$EAGER_LABEL.json" \
                  "$LABEL" <<'PYEOF'
import json, os, sys, datetime, pathlib

def load(p):
    raw = json.loads(pathlib.Path(p).read_text())
    return {j.get("jobname","?"): j.get("read", {}) for j in raw.get("jobs", [])}

lazy_p, eager_p, run_label = sys.argv[1], sys.argv[2], sys.argv[3]
lazy = load(lazy_p)
eager = load(eager_p)
concurrent = os.environ.get("CONCURRENT_MOUNTS", "?")

names = sorted(set(lazy) | set(eager))
print()
print(f"=== A/B ratio (lazy / eager) [{run_label}] concurrent_mounts={concurrent} ===")
print(f"{'job':<16} {'lazy_iops':>12} {'eager_iops':>12} {'ratio':>8}")
rows = []
for n in names:
    li = lazy.get(n, {}).get("iops", 0.0)
    ei = eager.get(n, {}).get("iops", 0.0)
    ratio = (li / ei) if ei > 0 else float("inf")
    rows.append((n, li, ei, ratio))
    print(f"{n:<16} {li:>12.1f} {ei:>12.1f} {ratio:>8.2f}x")

repo = pathlib.Path(os.environ.get("REPO_ROOT", "."))
doc = repo / "docs" / "macos-performance-baseline.md"
if doc.exists():
    block = [
        "",
        f"### A/B `{run_label}` — {datetime.datetime.utcnow().isoformat()}Z (concurrent_mounts={concurrent})",
        "",
        "| job | lazy iops | eager iops | ratio |",
        "| --- | ---: | ---: | ---: |",
    ]
    for n, li, ei, r in rows:
        block.append(f"| {n} | {li:.1f} | {ei:.1f} | {r:.2f}x |")
    with doc.open("a") as f:
        f.write("\n".join(block) + "\n")
    print(f"Appended A/B ratios to {doc}")
PYEOF
    echo "Done. Lazy: $REPORT_DIR/macfuse-bench-$LAZY_LABEL.json" >&2
    echo "Done. Eager: $REPORT_DIR/macfuse-bench-$EAGER_LABEL.json" >&2
else
    run_once "$LABEL"
    echo "Raw fio output: $REPORT_DIR/macfuse-bench-$LABEL.json" >&2
fi
