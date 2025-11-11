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

# Helper to setup best match state
setup_best_match() {
    set_state "bestMatchDistance" "${1:-9999}"
    set_state "bestMatchTrackDiff" "${2:-9999}"
    set_state "bestMatchNumTracks" "${3:-0}"
    set_state "bestMatchLyricTypePreferred" "${4:-}"
    set_state "bestMatchFormatPriority" "${5:-999}"
    set_state "bestMatchCountryPriority" "${6:-999}"
    set_state "bestMatchYearDiff" "${7:--1}"
    set_state "lidarrReleaseYear" "2020"
}

# --- Run tests ---
pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 1: Better because of lower distance
reset_state
setup_best_match 5 2 10 "true" 1 1 2
set_state "currentYearDiff" 2
if IsBetterMatch 3 2 10 "true" 1 1 "2020"; then
    echo "✅ PASS: Better match due to lower distance (3 < 5)"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to lower distance"
    ((fail++))
fi

# Test 2: Worse because of higher distance
reset_state
setup_best_match 3 2 10 "true" 1 1 2
set_state "currentYearDiff" 2
if ! IsBetterMatch 5 2 10 "true" 1 1 "2020"; then
    echo "✅ PASS: Worse match due to higher distance (5 > 3)"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to higher distance"
    ((fail++))
fi

# Test 3: Equal distance, better track diff
reset_state
setup_best_match 5 5 10 "true" 1 1 2
set_state "currentYearDiff" 2
if IsBetterMatch 5 3 10 "true" 1 1 "2020"; then
    echo "✅ PASS: Better match due to lower track diff (3 < 5)"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to lower track diff"
    ((fail++))
fi

# Test 4: Equal distance and track diff, better year
reset_state
setup_best_match 5 2 10 "true" 1 1 5
set_state "currentYearDiff" 1
if IsBetterMatch 5 2 10 "true" 1 1 "2021"; then
    echo "✅ PASS: Better match due to closer year (diff 1 < 5)"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to closer year"
    ((fail++))
fi

# Test 5: Equal distance, track diff, and year; more tracks wins
reset_state
setup_best_match 5 2 10 "true" 1 1 2
set_state "currentYearDiff" 2
if IsBetterMatch 5 2 15 "true" 1 1 "2022"; then
    echo "✅ PASS: Better match due to more tracks (15 > 10)"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to more tracks"
    ((fail++))
fi

# Test 6: All equal except lyric preference
reset_state
setup_best_match 5 2 10 "false" 1 1 2
set_state "currentYearDiff" 2
if IsBetterMatch 5 2 10 "true" 1 1 "2022"; then
    echo "✅ PASS: Better match due to preferred lyric type"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to preferred lyric type"
    ((fail++))
fi

# Test 7: All equal except format priority
reset_state
setup_best_match 5 2 10 "true" 3 1 2
set_state "currentYearDiff" 2
if IsBetterMatch 5 2 10 "true" 1 1 "2022"; then
    echo "✅ PASS: Better match due to better format priority (1 < 3)"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to better format priority"
    ((fail++))
fi

# Test 8: All equal except country priority
reset_state
setup_best_match 5 2 10 "true" 1 3 2
set_state "currentYearDiff" 2
if IsBetterMatch 5 2 10 "true" 1 1 "2022"; then
    echo "✅ PASS: Better match due to better country priority (1 < 3)"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to better country priority"
    ((fail++))
fi

# Test 9: Worse in all criteria
reset_state
setup_best_match 2 1 15 "true" 0 0 1
set_state "currentYearDiff" 5
if ! IsBetterMatch 8 5 10 "false" 5 5 "2015"; then
    echo "✅ PASS: Worse in all criteria"
    ((pass++))
else
    echo "❌ FAIL: Should be worse in all criteria"
    ((fail++))
fi

# Test 10: First match (best match is at defaults)
reset_state
setup_best_match 9999 9999 0 "" 999 999 -1
set_state "currentYearDiff" 1
if IsBetterMatch 5 2 10 "true" 1 1 "2021"; then
    echo "✅ PASS: First match is better than defaults"
    ((pass++))
else
    echo "❌ FAIL: First match should be better than defaults"
    ((fail++))
fi

# Test 11: Year diff evaluation - no year info for candidate
reset_state
setup_best_match 5 2 10 "true" 1 1 2
set_state "currentYearDiff" -1
if ! IsBetterMatch 5 2 10 "true" 1 1 ""; then
    echo "✅ PASS: Candidate with no year is worse"
    ((pass++))
else
    echo "❌ FAIL: Candidate with no year should be worse"
    ((fail++))
fi

# Test 12: Year diff evaluation - best match has no year, candidate does
reset_state
setup_best_match 5 2 10 "true" 1 1 -1
set_state "currentYearDiff" 2
if IsBetterMatch 5 2 10 "true" 1 1 "2022"; then
    echo "✅ PASS: Candidate with year is better than best match without year"
    ((pass++))
else
    echo "❌ FAIL: Candidate with year should be better"
    ((fail++))
fi

# Test 13: Exact tie - should not be better
reset_state
setup_best_match 5 2 10 "true" 1 1 2
set_state "currentYearDiff" 2
if ! IsBetterMatch 5 2 10 "true" 1 1 "2022"; then
    echo "✅ PASS: Exact tie is not considered better"
    ((pass++))
else
    echo "❌ FAIL: Exact tie should not be considered better"
    ((fail++))
fi

# Test 14: Better distance trumps everything else
reset_state
setup_best_match 10 1 20 "true" 0 0 0
set_state "currentYearDiff" 10
if IsBetterMatch 5 10 5 "false" 10 10 "2010"; then
    echo "✅ PASS: Lower distance wins despite worse other metrics"
    ((pass++))
else
    echo "❌ FAIL: Lower distance should win"
    ((fail++))
fi

# Test 15: Same distance, better track diff trumps other metrics
reset_state
setup_best_match 5 10 20 "true" 0 0 0
set_state "currentYearDiff" 10
if IsBetterMatch 5 5 5 "false" 10 10 "2010"; then
    echo "✅ PASS: Lower track diff wins despite worse other metrics"
    ((pass++))
else
    echo "❌ FAIL: Lower track diff should win"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
