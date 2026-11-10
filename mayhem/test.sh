#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS rsync's own test suite (runtests.py) plus known-answer transfers (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Behavioral oracle, part 1: real transfers with known answers through the built rsync. A patch that
# neuters rsync (exit 0 / no-op) leaves dst/ empty and fails these before the suite even starts.
BT="$SRC/mayhem/build-test"
RSYNC="$BT/rsync"
[ -x "$RSYNC" ] || { echo "missing $RSYNC — mayhem/build.sh did not build the test tree" >&2; emit_ctrf "rsync" 0 1; exit 1; }

KA_PASS=0; KA_FAIL=0
ka() {  # ka <name> <expected> <actual>
  if [ "$2" = "$3" ]; then KA_PASS=$((KA_PASS+1)); else KA_FAIL=$((KA_FAIL+1)); echo "FAIL known-answer $1: expected '$2' got '$3'" >&2; fi
}

ka_dir=$(mktemp -d)
trap 'rm -rf "$ka_dir"' EXIT
mkdir -p "$ka_dir/src/sub" "$ka_dir/dst"
printf 'hello rsync\n' > "$ka_dir/src/a.txt"
seq 1 1000 > "$ka_dir/src/n.txt"
printf 'x\n' > "$ka_dir/src/skip.tmp"
printf 'y\n' > "$ka_dir/src/sub/b7x"
printf 'z\n' > "$ka_dir/src/sub/keep.txt"
ln -s a.txt "$ka_dir/src/link"
"$RSYNC" -a --exclude='*.tmp' --exclude='b[0-9]?' "$ka_dir/src/" "$ka_dir/dst/" >/dev/null 2>&1
ka copy-content "hello rsync" "$(cat "$ka_dir/dst/a.txt" 2>/dev/null)"
ka copy-sha256 "67d4ff71d43921d5739f387da09746f405e425b07d727e4c69d029461d1f051f" "$(sha256sum "$ka_dir/dst/n.txt" 2>/dev/null | cut -d' ' -f1)"
ka exclude-star-tmp "absent" "$([ -e "$ka_dir/dst/skip.tmp" ] && echo present || echo absent)"
ka exclude-bracket "absent" "$([ -e "$ka_dir/dst/sub/b7x" ] && echo present || echo absent)"
ka keeps-unmatched "z" "$(cat "$ka_dir/dst/sub/keep.txt" 2>/dev/null)"
ka symlink "a.txt" "$(readlink "$ka_dir/dst/link" 2>/dev/null)"
# Delta transfer: change the tail of the big file; the receiver must end up byte-identical, and the
# --stats literal data must be far smaller than the file (the rolling checksum matched the rest).
seq 1 1000 > "$ka_dir/dst/n.txt"; seq 1001 1010 >> "$ka_dir/src/n.txt"
stats=$("$RSYNC" -a --no-whole-file --stats "$ka_dir/src/" "$ka_dir/dst/" 2>/dev/null)
ka delta-converged "$(sha256sum < "$ka_dir/src/n.txt")" "$(sha256sum < "$ka_dir/dst/n.txt")"
lit=$(printf '%s\n' "$stats" | sed -n 's/^Literal data: \([0-9]*\) bytes.*/\1/p')
ka delta-literal-small "yes" "$([ "${lit:-99999}" -gt 0 ] && [ "${lit:-99999}" -lt 1000 ] && echo yes || echo "no(${lit:-none})")"
ka list-only "a.txt" "$("$RSYNC" --list-only "$ka_dir/src/a.txt" 2>/dev/null | awk '{print $NF}')"

# Part 2: upstream's own suite (python runner) against the same tree. install-strip installs into the
# source prefix, which an out-of-tree read-only image cannot do.
out=$(mktemp)
(cd "$BT" && timeout 1500 python3 "$SRC/runtests.py" --rsync-bin="$BT/rsync" -j "$MAYHEM_JOBS" --exclude install-strip) >"$out" 2>&1
rc=$?
passed=$(grep -c '^PASS ' "$out"); failed=$(grep -c '^FAIL ' "$out"); skipped=$(grep -c '^SKIP ' "$out")
grep '^FAIL ' "$out" >&2 || true
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; tail -20 "$out" >&2; fi
rm -f "$out"
emit_ctrf "rsync-runtests+known-answers" $((passed + KA_PASS)) $((failed + KA_FAIL)) "$skipped"
