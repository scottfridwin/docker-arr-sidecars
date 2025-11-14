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

# Test 1: Identical titles
reset_state
ComputeMatchMetrics "maple street" "maple street" 17 17
distance=$(get_state "candidateDistance")
trackDiff=$(get_state "candidateTrackDiff")
if [[ "$distance" == "0" ]] && [[ "$trackDiff" == "0" ]]; then
    echo "✅ PASS: Identical titles (distance=0, trackDiff=0)"
    ((pass++))
else
    echo "❌ FAIL: Identical (got distance=$distance, trackDiff=$trackDiff)"
    ((fail++))
fi

# Test 2: Similar titles
reset_state
ComputeMatchMetrics "2048" "2048 deluxe" 13 16
distance=$(get_state "candidateDistance")
trackDiff=$(get_state "candidateTrackDiff")
if [[ "$distance" == "7" ]] && [[ "$trackDiff" == "3" ]]; then
    echo "✅ PASS: Similar titles with track difference"
    ((pass++))
else
    echo "❌ FAIL: Similar (got distance=$distance, trackDiff=$trackDiff, expected 7, 3)"
    ((fail++))
fi

# Test 3: Very different titles
reset_state
ComputeMatchMetrics "maple street" "yellow album" 17 30
distance=$(get_state "candidateDistance")
trackDiff=$(get_state "candidateTrackDiff")
if [[ "$distance" -gt "5" ]] && [[ "$trackDiff" == "13" ]]; then
    echo "✅ PASS: Very different titles"
    ((pass++))
else
    echo "❌ FAIL: Different (got distance=$distance, trackDiff=$trackDiff)"
    ((fail++))
fi

# Test 4: Case insensitivity
reset_state
ComputeMatchMetrics "Maple Street" "MAPLE STREET" 17 17
distance=$(get_state "candidateDistance")
if [[ "$distance" == "0" ]]; then
    echo "✅ PASS: Case insensitive comparison"
    ((pass++))
else
    echo "❌ FAIL: Case insensitive (got distance=$distance, expected 0)"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
