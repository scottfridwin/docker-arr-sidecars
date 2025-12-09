#!/usr/bin/env bash
set -uo pipefail

# --- Source the function under test ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/utilities.sh"
source "${SCRIPT_DIR}/../services/functions.bash"

#### Mocks ####
log() {
    : # Do nothing, suppress logs in tests
}

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

# Test 1: Same year
result=$(CalculateYearDifference "2020" "2020")
if [[ "$result" == "0" ]]; then
    echo "✅ PASS: Same year returns 0"
    ((pass++))
else
    echo "❌ FAIL: Same year (got $result, expected 0)"
    ((fail++))
fi

# Test 2: Positive difference
result=$(CalculateYearDifference "2025" "2020")
if [[ "$result" == "5" ]]; then
    echo "✅ PASS: Positive difference (2025-2020=5)"
    ((pass++))
else
    echo "❌ FAIL: Positive difference (got $result, expected 5)"
    ((fail++))
fi

# Test 3: Negative difference returns absolute value
result=$(CalculateYearDifference "2020" "2025")
if [[ "$result" == "5" ]]; then
    echo "✅ PASS: Negative difference returns absolute value"
    ((pass++))
else
    echo "❌ FAIL: Negative difference (got $result, expected 5)"
    ((fail++))
fi

# Test 4: Null first year
result=$(CalculateYearDifference "null" "2020")
if [[ "$result" == "999" ]]; then
    echo "✅ PASS: Null first year returns 999"
    ((pass++))
else
    echo "❌ FAIL: Null first year (got $result, expected 999)"
    ((fail++))
fi

# Test 5: Null second year
result=$(CalculateYearDifference "2020" "null")
if [[ "$result" == "999" ]]; then
    echo "✅ PASS: Null second year returns 999"
    ((pass++))
else
    echo "❌ FAIL: Null second year (got $result, expected 999)"
    ((fail++))
fi

# Test 6: Empty first year
result=$(CalculateYearDifference "" "2020")
if [[ "$result" == "999" ]]; then
    echo "✅ PASS: Empty first year returns 999"
    ((pass++))
else
    echo "❌ FAIL: Empty first year (got $result, expected 999)"
    ((fail++))
fi

# Test 7: Large difference
result=$(CalculateYearDifference "1969" "2023")
if [[ "$result" == "54" ]]; then
    echo "✅ PASS: Large difference (1969-2023=54)"
    ((pass++))
else
    echo "❌ FAIL: Large difference (got $result, expected 54)"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi

exit 0
