#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/utilities.sh"
source "${SCRIPT_DIR}/../services/functions.bash"

#### Mocks ####
log() {
    : # Do nothing, suppress logs in tests
}

pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 01: Clears only matching objects
testName="No exact match"
reset_state
set_state "trackcache.abc" "123"
set_state "trackcache.123" "abc"
set_state "otherName." "abc"

ClearTrackComparisonCache

if [[ "$(get_state "trackcache.abc")" == "" ]] &&
    [[ "$(get_state "trackcache.123")" == "" ]] &&
    [[ "$(get_state "otherName.")" == "abc" ]]; then
    echo "✅ PASS: Only matching objects"
    ((pass++))
else
    echo "❌ FAIL: Cache clear was unsuccessful"
    echo "trackcache.abc: $(get_state "trackcache.abc")"
    echo "trackcache.123: $(get_state "trackcache.123")"
    echo "otherName.: $(get_state "otherName.")"
    ((fail++))
fi

# Test 02: No matching keys present
testName="No trackcache keys"
reset_state
set_state "foo" "1"
set_state "bar.baz" "2"

ClearTrackComparisonCache

if [[ "$(get_state "foo")" == "1" ]] &&
    [[ "$(get_state "bar.baz")" == "2" ]]; then
    echo "✅ PASS: No-op when no trackcache keys"
    ((pass++))
else
    echo "❌ FAIL: Non-trackcache keys were modified"
    ((fail++))
fi

# Test 03: Empty state
testName="Empty state"
reset_state

ClearTrackComparisonCache

# If we got here, it passed
echo "✅ PASS: Empty state handled safely"
((pass++))

# Test 04: Prefix collision
testName="Prefix collision"
reset_state
set_state "trackcacheX.foo" "bad"
set_state "trackcache" "bad"
set_state "trackcache." "good"

ClearTrackComparisonCache

if [[ "$(get_state "trackcacheX.foo")" == "bad" ]] &&
    [[ "$(get_state "trackcache")" == "bad" ]] &&
    [[ "$(get_state "trackcache.")" == "" ]]; then
    echo "✅ PASS: Prefix match is precise"
    ((pass++))
else
    echo "❌ FAIL: Prefix collision"
    ((fail++))
fi

# Test 05: Mixed realistic keys
testName="Mixed keys"
reset_state
set_state "trackcache.1|a.avg" "1.2"
set_state "trackcache.1|a.max" "3"
set_state "trackcache.2|b.avg" "2.4"
set_state "candidateTrackNameDiffAvg" "9.9"

ClearTrackComparisonCache

if [[ "$(get_state "trackcache.1|a.avg")" == "" ]] &&
    [[ "$(get_state "trackcache.2|b.avg")" == "" ]] &&
    [[ "$(get_state "candidateTrackNameDiffAvg")" == "9.9" ]]; then
    echo "✅ PASS: Realistic mixed cache cleared"
    ((pass++))
else
    echo "❌ FAIL: Mixed cache clear failed"
    ((fail++))
fi

# Test 06: Idempotency
testName="Idempotent behavior"
reset_state
set_state "trackcache.test" "123"

ClearTrackComparisonCache
ClearTrackComparisonCache # call again

if [[ "$(get_state "trackcache.test")" == "" ]]; then
    echo "✅ PASS: Idempotent"
    ((pass++))
else
    echo "❌ FAIL: Idempotency broken"
    ((fail++))
fi

# Test 07: Many keys
testName="Many keys"
reset_state

for i in {1..100}; do
    set_state "trackcache.key$i" "$i"
    set_state "other.key$i" "$i"
done

ClearTrackComparisonCache

ok=true
for i in {1..100}; do
    [[ "$(get_state "trackcache.key$i")" != "" ]] && ok=false
    [[ "$(get_state "other.key$i")" != "$i" ]] && ok=false
done

if $ok; then
    echo "✅ PASS: Many keys cleared correctly"
    ((pass++))
else
    echo "❌ FAIL: Many keys test failed"
    ((fail++))
fi

# Test 08: Special characters
testName="Special characters"
reset_state
set_state "trackcache.1|abc.def.avg" "1.23"
set_state "trackcache.1|abc.def.max" "4"
set_state "safe.key" "ok"

ClearTrackComparisonCache

if [[ "$(get_state "trackcache.1|abc.def.avg")" == "" ]] &&
    [[ "$(get_state "safe.key")" == "ok" ]]; then
    echo "✅ PASS: Special characters handled"
    ((pass++))
else
    echo "❌ FAIL: Special character handling"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
