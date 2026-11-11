#!/usr/bin/env bash
# Fixture test for ensures-coverage (README.md, "测试").
#
#   VERUS=<path to verus> tests/run.sh [--update]
#
# Verifies tests/fixture/fixture.rs with the given Verus, exports its VIR,
# runs `check` on it and compares the results with tests/expected.results.
# The test fails when Verus does not verify the fixture, when `check` prints
# anything on stderr (every warning means the VIR format may have changed,
# design.md 结论24), or when the results differ.  A difference means that
# either the VIR format changed or the check's behaviour did: look at the
# diff before updating anything.
#
# --update  rewrite tests/expected.results from this run (after a deliberate
#           change to the check or to the fixture; review the diff).
#
# Environment:
#   VERUS          the verus binary, e.g. $SRC/tools/verus/source/target-verus/release/verus
#   VERUS_Z3_PATH  passed through to Verus (e.g. $SRC/tools/verus/source/z3)
#   ITEM_INDEX     the item-index binary, when not in item-index/target/release
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
expected="$here/expected.results"
update=no
[ "${1:-}" = "--update" ] && update=yes

: "${VERUS:?set VERUS to the verus binary}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "Verus: $("$VERUS" --version 2>/dev/null | sed -n 's/^ *Version: //p')"

# 1. verify the fixture and export its VIR.  Run from the fixture's
#    directory so that the VIR names the source file relatively.
(cd "$here/fixture" &&
   "$VERUS" fixture.rs --crate-type=lib --log vir --log-dir "$tmp/vir") >"$tmp/verus.out" 2>&1
status=$?
if [ $status -ne 0 ] || ! grep -q "verification results:: [0-9]* verified, 0 errors" "$tmp/verus.out"; then
    cat "$tmp/verus.out" >&2
    fail "Verus did not verify the fixture (exit $status)"
fi
[ -f "$tmp/vir/crate.vir" ] || fail "Verus wrote no $tmp/vir/crate.vir"

# 2. check.  Any warning fails the test.
(cd "$root" && racket main.rkt check "$tmp/vir/crate.vir" "$tmp/out.results" "$here/fixture" ${ITEM_INDEX:+"$ITEM_INDEX"}) \
    >"$tmp/check.out" 2>"$tmp/check.err" || { cat "$tmp/check.out" "$tmp/check.err" >&2; fail "check failed"; }
if [ -s "$tmp/check.err" ]; then
    cat "$tmp/check.err" >&2
    fail "check printed warnings"
fi

# 3. compare, without the header and the (vir ...) line, which names the
#    temporary directory
sed 1,2d "$tmp/out.results" >"$tmp/actual.results"
if [ $update = yes ]; then
    {
        echo ";; Expected results of tests/run.sh on tests/fixture/fixture.rs (README.md, 测试)."
        echo ";; Regenerate with --update only after reviewing the diff."
        cat "$tmp/actual.results"
    } >"$expected"
    echo "updated $expected"
    exit 0
fi
[ -f "$expected" ] || fail "no $expected; run with --update first"
if ! diff -u <(grep -v '^;;' "$expected") "$tmp/actual.results"; then
    fail "results differ from $expected (lines: - expected, + actual)"
fi
echo "PASS: $(grep -c '^(fn ' "$tmp/actual.results") functions as expected"
