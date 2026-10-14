#!/usr/bin/env bash
#
# go-toml/mayhem/build.sh (mining layer) — build mayhem/harness_float, a go-fuzz harness that decodes
# TOML into float-typed destinations, as a sanitized libFuzzer binary (like OSS-Fuzz's compile_go_fuzzer).
#
# We produce:
#   /mayhem/fuzz_float — mining harness (mayhem/harness_float, go-fuzz, ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by the go-fuzz builder); we link it
# against the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like compile_go_fuzzer's
# final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag).
# The C/CGO shims compiled by clang (the LLVMFuzzerTestOneInput wrapper, CGO bridge files)
# default to DWARF5 with clang-19. We force those shims to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS
# and the final clang++ link to DWARF3 via $DEBUG_FLAGS. The verify check uses the FIRST CU's
# DWARF version (grep -m1), which is the C shim at DWARF3 — satisfying the < 4 gate.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-fuzz builders rewrite source + need the AdamKorcz testing shim as a module dep. Add the
# module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order matters: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── Mining harness: mayhem/harness_float.Fuzz via go-fuzz (LEGACY []byte harness) ─────────────
# Decodes TOML into float-typed destinations (struct fields, maps), the only way to push a TOML
# integer such as `0` through parseFloat; the OSS-Fuzz interface{} harness never does.
echo "=== building fuzz_float (harness_float.Fuzz, go-fuzz) ==="
go-fuzz -func Fuzz -o "$SRC/mayhem-build/fuzz_float.a" \
    github.com/pelletier/go-toml/v2/mayhem/harness_float
# Init-ordering shim (go_runtime_ready.c), linked FIRST.
SHIM_O="$SRC/mayhem-build/go_runtime_ready.o"
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem/go_runtime_ready.c" -o "$SHIM_O"
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SHIM_O" "$SRC/mayhem-build/fuzz_float.a" -o /mayhem/fuzz_float
nm /mayhem/fuzz_float | grep ' T LLVMFuzzerInitialize$' >/dev/null \
  || { echo "build.sh: LLVMFuzzerInitialize shim missing from /mayhem/fuzz_float" >&2; exit 1; }
echo "built /mayhem/fuzz_float"
