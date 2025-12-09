#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/utilities.sh"
source "${SCRIPT_DIR}/../services/functions.bash"

#### Mocks ####
log() {
    : # Do nothing, suppress logs in tests
}

# Helper to setup state for the test
setup_state() {
    set_state "exactMatchFound" "${1}"
    set_state "lidarrReleaseCountryPriority" "${2}"
    set_state "bestMatchCountryPriority" "${3}"
    set_state "lidarrReleaseTrackCount" "${4}"
    set_state "bestMatchNumTracks" "${5}"
    set_state "lidarrReleaseFormatPriority" "${6}"
    set_state "bestMatchFormatPriority" "${7}"
}

pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 01: No exact match -> No skip
testName="No exact match"
reset_state
setup_state "false" "0" "0" "0" "0" "0" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 02: Non-numeric country priority -> No skip
testName="Non-numeric country priority"
reset_state
setup_state "true" "abc" "0" "0" "0" "0" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 03: Non-numeric best country priority -> No skip
testName="Non-numeric best country priority"
reset_state
setup_state "true" "0" "abc" "0" "0" "0" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 04: Better country priority -> No skip
testName="Better country priority"
reset_state
setup_state "true" "3" "5" "0" "0" "0" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 05: Equal country priority -> No skip
testName="Equal country priority"
reset_state
setup_state "true" "3" "3" "0" "0" "0" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 06: Worse country priority -> Skip
testName="Worse country priority"
reset_state
setup_state "true" "5" "3" "0" "0" "0" "0"
if SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> Skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should skip"
    ((fail++))
fi

# Test 07: Non-numeric track count -> No skip
testName="Non-numeric track count priority"
reset_state
setup_state "true" "0" "0" "abc" "0" "0" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 08: Non-numeric best track count -> No skip
testName="Non-numeric best track priority"
reset_state
setup_state "true" "0" "0" "0" "abc" "0" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 09: Better track count -> No skip
testName="Better track count"
reset_state
setup_state "true" "0" "0" "5" "3" "0" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 10: Equal track count -> No skip
testName="Equal track count"
reset_state
setup_state "true" "0" "0" "3" "3" "0" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 11: Worse track count -> Skip
testName="Worse track count"
reset_state
setup_state "true" "0" "0" "3" "5" "0" "0"
if SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> Skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should skip"
    ((fail++))
fi

# Test 12: Non-numeric format priority -> No skip
testName="Non-numeric format priority"
reset_state
setup_state "true" "0" "0" "0" "0" "abc" "0"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 13: Non-numeric best format priority -> No skip
testName="Non-numeric best format priority"
reset_state
setup_state "true" "0" "0" "0" "0" "0" "abc"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 14: Better format priority -> No skip
testName="Better format priority"
reset_state
setup_state "true" "0" "0" "0" "0" "3" "5"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 15: Equal format priority -> No skip
testName="Equal format priority"
reset_state
setup_state "true" "0" "0" "0" "0" "3" "3"
if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 16: Worse format priority -> Skip
testName="Worse format priority"
reset_state
setup_state "true" "0" "0" "0" "0" "5" "3"
if SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> Skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should skip"
    ((fail++))
fi

# Test 17: Country priority positive
testName="Country priority positive"
reset_state
setup_state "true" "5" "3" "20" "5" "1" "5"

if SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> Skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should skip"
    ((fail++))
fi

# Test 18: Country priority negative
testName="Country priority negative"
reset_state
setup_state "true" "3" "5" "5" "20" "5" "1"

if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 19: Track count positive
testName="Track count positive"
reset_state
setup_state "true" "5" "5" "5" "20" "1" "5"

if SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> Skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should skip"
    ((fail++))
fi

# Test 20: Track count negative
testName="Track count negative"
reset_state
setup_state "true" "5" "5" "20" "5" "5" "1"

if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

# Test 19: Format priority positive
testName="Format priority positive"
reset_state
setup_state "true" "5" "5" "20" "20" "5" "1"

if SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> Skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should skip"
    ((fail++))
fi

# Test 20: Format priority negative
testName="Format priority negative"
reset_state
setup_state "true" "5" "5" "20" "20" "1" "5"

if ! SkipReleaseCandidate; then
    echo "✅ PASS: $testName -> No skip"
    ((pass++))
else
    echo "❌ FAIL: '$testName' should not skip"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
