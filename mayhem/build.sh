#!/usr/bin/env bash
#
# mayhem/build.sh — builds the AFL-instrumented rsync, the wildmatch libFuzzer harness and the test tree.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# configure_in <dir> <CC> <CFLAGS> <LDFLAGS>: out-of-tree configure (rsync's ./configure wrapper
# regenerates configure.sh/config.h.in into the build dir; the source tree stays pristine). A dir that
# is already configured is reused, so re-running this script is cheap and idempotent.
configure_in() {
  local dir="$1" cc="$2" cflags="$3" ldflags="$4"
  mkdir -p "$dir"
  if [ ! -f "$dir/Makefile" ]; then
    (cd "$dir" && env -u CFLAGS -u LDFLAGS -u CXXFLAGS ../../configure --disable-md2man \
        CC="$cc" CFLAGS="$cflags" LDFLAGS="$ldflags")
  fi
}

# 1) The project itself, sanitized + DWARF 3, built with afl-clang-fast: this is the rsync binary the AFL
#    targets drive (`rsync --server`, `rsync --server --sender`, `rsync --server --daemon`).
mkdir -p mayhem/build-afl
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/mayhem/build-afl/lsan_off.o"
# recv_scratch.o gives rsync_server_recv a fresh, self-removing destination per exec (see mayhem/recv_scratch.c).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -c "$SRC/mayhem/recv_scratch.c" -o "$SRC/mayhem/build-afl/recv_scratch.o"
configure_in mayhem/build-afl afl-clang-fast "$SANITIZER_FLAGS $DEBUG_FLAGS -O1" \
    "$SANITIZER_FLAGS $DEBUG_FLAGS $SRC/mayhem/build-afl/lsan_off.o $SRC/mayhem/build-afl/recv_scratch.o"
make -C mayhem/build-afl -j"$MAYHEM_JOBS" rsync
cp mayhem/build-afl/rsync /mayhem/rsync-afl

# 2) libFuzzer harness over lib/wildmatch.c (the include/exclude/filter matcher), compiled sanitized from the
#    project source with the AFL tree's config.h; plus its standalone run-once reproducer.
#    -fsanitize=fuzzer-no-link puts SanCov on wildmatch.c itself, else libFuzzer sees only the harness (3 edges).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off_wild.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 -DHAVE_CONFIG_H -Imayhem/build-afl -I"$SRC" -I"$SRC/lib" -c lib/wildmatch.c -o /tmp/wildmatch_fuzz.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem/fuzz_wildmatch.c" -I"$SRC/lib" \
    /tmp/wildmatch_fuzz.o /tmp/lsan_off_wild.o -o /mayhem/fuzz_wildmatch
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link "$STANDALONE_FUZZ_MAIN" "$SRC/mayhem/fuzz_wildmatch.c" -I"$SRC/lib" \
    /tmp/wildmatch_fuzz.o /tmp/lsan_off_wild.o -o /mayhem/fuzz_wildmatch-standalone

# 3) The project's own test suite, built with NORMAL flags (no sanitizers) in a separate tree that test.sh
#    only runs: the rsync binary plus every helper runtests.py needs (`make check-progs`).
configure_in mayhem/build-test "$CC" "-O2 $COVERAGE_FLAGS" "$COVERAGE_FLAGS"
make -C mayhem/build-test -j"$MAYHEM_JOBS" check-progs
