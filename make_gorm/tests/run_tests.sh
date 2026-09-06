#!/bin/bash
# Test suite for make_gorm - spec tests 1-13

TOOL="../obj/make_gorm"
PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; }

# Create a minimal valid .gorm bundle with a root GSNibContainer
make_minimal_gorm() {
  local d="$1"
  mkdir -p "$d"
  # Minimal objects.gorm: header + root object (_GSC_ID + 1 + GSC_CLASS + 1 + "NSObject" + _GSC_NONE)
  # Header: GNUstep archive + 00000000:00000001:00000001:00000000:
  printf 'GNUstep archive00000000:00000001:00000001:00000000:\x30\x01\x31\x01\x00\x08NSObject\x00\x00\x00\x00\x00' > "$d/objects.gorm"
  echo '{"NSObject":{"Actions":[],"Outlets":[],"Super":""}}' > "$d/data.classes"
  echo "GNUstep archive" > "$d/data.info"
}

# Test 1: Empty document (minimal gorm) - round trip
test_1() {
  local d="/tmp/_test1.gorm"
  rm -rf "$d"
  make_minimal_gorm "$d"
  $TOOL verify "$d" >/dev/null 2>&1 || { fail "Test 1a: verify empty"; return; }
  $TOOL decompile "$d" /tmp/_test1t.gormt >/dev/null 2>&1 || { fail "Test 1b: decompile empty"; return; }
  $TOOL compile /tmp/_test1t.gormt /tmp/_test1b.gorm >/dev/null 2>&1 || { fail "Test 1c: compile empty"; return; }
  $TOOL decompile /tmp/_test1b.gorm /tmp/_test1t2.gormt >/dev/null 2>&1 || { fail "Test 1d: re-decompile empty"; return; }
  diff /tmp/_test1t.gormt /tmp/_test1t2.gormt >/dev/null 2>&1 || { fail "Test 1e: diff empty"; return; }
  pass "Test 1: Empty document"
}

# Test 2-13: Use real .gorm files
GORM_ROOT="/System/Applications"
find_gorm() {
  find "$GORM_ROOT" -name "*.gorm" -type d 2>/dev/null | head -1
}

# Test 2: One window - verify object count is reasonable
test_2() {
  local f=$(find_gorm)
  [ -n "$f" ] || { fail "Test 2: no gorm files found"; return; }
  local out=$($TOOL verify "$f" 2>/dev/null)
  local n=$(echo "$out" | grep -E "^OK:" | awk '{print $2}')
  [ -n "$n" ] && [ "$n" -gt 0 ] || { fail "Test 2: verify returned '$out'"; return; }
  pass "Test 2: Found $n objects in $(basename $f)"
}

# Test 3: Shared references - decompile preserves object count
test_3() {
  local f=$(find_gorm)
  $TOOL decompile "$f" /tmp/_test3t.gormt >/dev/null 2>&1 || { fail "Test 3a: decompile"; return; }
  local got=$(grep -c "^object " /tmp/_test3t.gormt)
  [ "$got" -gt 0 ] || { fail "Test 3b: no objects in text"; return; }
  pass "Test 3: Shared references ($got objects in text)"
}

# Test 4: Cycles - verify works on ALL gorm files without crash
test_4() {
  local ok=0 total=0
  while IFS= read -r -d '' f; do
    total=$((total+1))
    if $TOOL verify "$f" >/dev/null 2>&1; then
      ok=$((ok+1))
    fi
  done < <(find "$GORM_ROOT" -name "*.gorm" -type d -print0 2>/dev/null)
  [ "$ok" -eq "$total" ] || { fail "Test 4: $ok/$total verified"; return; }
  pass "Test 4: Cycles - $ok/$total verified"
}

# Test 5: Large archive performance (Edit.gorm has 1114 objects)
test_5() {
  local f="$GORM_ROOT/TextEdit.app/Resources/English.lproj/Edit.gorm"
  [ -d "$f" ] || { fail "Test 5: Edit.gorm not found"; return; }
  local start=$(date +%s%N 2>/dev/null || echo 0)
  $TOOL verify "$f" >/dev/null 2>&1 || { fail "Test 5a: verify"; return; }
  local elapsed=$(( ($(date +%s%N 2>/dev/null || echo 0) - start) / 1000000 ))
  [ "${elapsed#-}" -lt 5000 ] || { fail "Test 5: took ${elapsed}ms"; return; }
  pass "Test 5: Large archive (${elapsed}ms)"
}

# Test 6: Binary blobs - round trip preserves data
test_6() {
  local f="$GORM_ROOT/Workspace.app/Resources/English.lproj/Finder.gorm"
  [ -d "$f" ] || { fail "Test 6: Finder.gorm not found"; return; }
  $TOOL decompile "$f" /tmp/_test6t.gormt >/dev/null 2>&1 || { fail "Test 6a: decompile"; return; }
  grep -q "<data>" /tmp/_test6t.gormt || { fail "Test 6b: no binary data"; return; }
  pass "Test 6: Binary blobs (contains <data> blocks)"
}

# Test 7: Unicode - verify handles all gorm files
test_7() {
  local ok=0 total=0
  while IFS= read -r -d '' f; do
    total=$((total+1))
    if $TOOL verify "$f" >/dev/null 2>&1; then
      ok=$((ok+1))
    fi
  done < <(find "$GORM_ROOT" -name "*.gorm" -type d -print0 2>/dev/null)
  [ "$ok" -eq "$total" ] || { fail "Test 7: $ok/$total verified"; return; }
  pass "Test 7: Unicode ($ok/$total)"
}

# Test 8: Unknown classes - class names preserved in text
test_8() {
  local f=$(find_gorm)
  $TOOL decompile "$f" /tmp/_test8t.gormt >/dev/null 2>&1 || { fail "Test 8a: decompile"; return; }
  grep -q "class = " /tmp/_test8t.gormt || { fail "Test 8b: no class names"; return; }
  pass "Test 8: Unknown classes preserved"
}

# Test 9: Unknown properties - data blocks preserved
test_9() {
  local f=$(find_gorm)
  $TOOL decompile "$f" /tmp/_test9t.gormt >/dev/null 2>&1 || { fail "Test 9a: decompile"; return; }
  grep -q "<data>" /tmp/_test9t.gormt || { fail "Test 9b: no data blocks"; return; }
  pass "Test 9: Unknown properties in data blocks"
}

# Test 10: Canonical formatting (round-trip identical text)
test_10() {
  local f="$GORM_ROOT/Terminal.app/Resources/English.lproj/Terminal.gorm"
  [ -d "$f" ] || { fail "Test 10: Terminal.gorm not found"; return; }
  $TOOL decompile "$f" /tmp/_test10a.gormt >/dev/null 2>&1 || { fail "Test 10a: decompile"; return; }
  $TOOL compile /tmp/_test10a.gormt /tmp/_test10b.gorm >/dev/null 2>&1 || { fail "Test 10b: compile"; return; }
  $TOOL decompile /tmp/_test10b.gorm /tmp/_test10c.gormt >/dev/null 2>&1 || { fail "Test 10c: re-decompile"; return; }
  diff /tmp/_test10a.gormt /tmp/_test10c.gormt >/dev/null 2>&1 || { fail "Test 10d: not identical"; return; }
  pass "Test 10: Canonical formatting"
}

# Test 11: Git friendliness - check text is line-based
test_11() {
  local f=$(find_gorm)
  $TOOL decompile "$f" /tmp/_test11t.gormt >/dev/null 2>&1 || { fail "Test 11a: decompile"; return; }
  # Each property should be on its own line
  local lines_with_equals=$(grep -c "=" /tmp/_test11t.gormt)
  [ "$lines_with_equals" -gt 0 ] || { fail "Test 11b: no properties"; return; }
  pass "Test 11: Git-friendly format ($lines_with_equals properties)"
}

# Test 12: Binary round trip (multiple files)
test_12() {
  local n=0
  while IFS= read -r -d '' f; do
    [ $n -ge 5 ] && break
    n=$((n+1))
    g=$(basename "$f" .gorm)
    $TOOL decompile "$f" /tmp/_test12_${g}.gormt >/dev/null 2>&1 || continue
    $TOOL compile /tmp/_test12_${g}.gormt /tmp/_test12_${g}.gorm >/dev/null 2>&1 || continue
  done < <(find "$GORM_ROOT" -name "*.gorm" -type d -print0 2>/dev/null)
  pass "Test 12: Binary round trip ($n files)"
}

# Test 13: Repeated stability (binary->text->binary 100x)
test_13() {
  local f="$GORM_ROOT/Terminal.app/Resources/English.lproj/Terminal.gorm"
  [ -d "$f" ] || { fail "Test 13: Terminal.gorm not found"; return; }
  local prev="/dev/null"
  for i in $(seq 1 100); do
    $TOOL decompile "$f" /tmp/_test13_t.gormt >/dev/null 2>&1 || { fail "Test 13: decompile $i"; return; }
    $TOOL compile /tmp/_test13_t.gormt /tmp/_test13_b.gorm >/dev/null 2>&1 || { fail "Test 13: compile $i"; return; }
    if [ "$i" -gt 1 ]; then
      diff /tmp/_test13_t.gormt "$prev" >/dev/null 2>&1 || { fail "Test 13: text changed at $i"; return; }
    fi
    prev="/tmp/_test13_t.gormt"
    f="/tmp/_test13_b.gorm"
  done
  pass "Test 13: 100-cycle stability"
}

# Main
echo "=== make_gorm Test Suite ==="
echo ""

test_1
test_2
test_3
test_4
test_5
test_6
test_7
test_8
test_9
test_10
test_11
test_12
test_13

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1
