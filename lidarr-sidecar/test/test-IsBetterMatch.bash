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
setup_best_state() {
    set_state "bestMatchNameDiff" "${1:-9999}"
    set_state "bestMatchTrackDiff" "${2:-9999}"
    set_state "bestMatchYearDiff" "${3:-9999}"
    set_state "bestMatchCountryPriority" "${4:-999}"
    set_state "bestMatchNumTracks" "${5:-0}"
    set_state "bestMatchFormatPriority" "${6:-999}"
    set_state "bestMatchLyricTypePreferred" "${7:-false}"
}

# Helper to setup candidate state
setup_cand_state() {
    set_state "candidateNameDiff" "${1:-0}"
    set_state "candidateTrackDiff" "${2:-0}"
    set_state "candidateYearDiff" "${3:-0}"
    set_state "lidarrReleaseCountryPriority" "${4:-0}"
    set_state "deezerCandidateTrackCount" "${5:-99}"
    set_state "lidarrReleaseFormatPriority" "${6:-0}"
    set_state "deezerCandidatelyricTypePreferred" "${7:-true}"
}

# --- Run tests ---
pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 1: Better because of lower NameDiff
reset_state
setup_best_state 5 5 5 5 15 5 "true"
setup_cand_state 3 5 5 5 15 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to lower NameDiff"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to lower NameDiff"
    ((fail++))
fi

# Test 2: Worse because of higher NameDiff
reset_state
setup_best_state 3 5 5 5 15 5 "true"
setup_cand_state 5 5 5 5 15 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to higher NameDiff"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to higher NameDiff"
    ((fail++))
fi

# Test 3: Equal NameDiff, better TrackDiff
reset_state
setup_best_state 5 5 5 5 15 5 "true"
setup_cand_state 5 3 5 5 15 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to lower TrackDiff"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to lower TrackDiff"
    ((fail++))
fi

# Test 4: Equal NameDiff, worse TrackDiff
reset_state
setup_best_state 5 3 5 5 15 5 "true"
setup_cand_state 5 5 5 5 15 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to higher TrackDiff"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to higher TrackDiff"
    ((fail++))
fi

# Test 5: Equal NameDiff, equal TrackDiff, better YearDiff
reset_state
setup_best_state 5 5 5 5 15 5 "true"
setup_cand_state 5 5 3 5 15 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to lower YearDiff"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to lower YearDiff"
    ((fail++))
fi

# Test 6: Equal NameDiff, equal TrackDiff, worse YearDiff
reset_state
setup_best_state 5 5 3 5 15 5 "true"
setup_cand_state 5 5 5 5 15 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to higher YearDiff"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to higher YearDiff"
    ((fail++))
fi

# Test 7: Equal NameDiff, equal TrackDiff, equal YearDiff, better CountryPriority
reset_state
setup_best_state 5 5 5 5 15 5 "true"
setup_cand_state 5 5 5 3 15 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to lower CountryPriority"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to lower CountryPriority"
    ((fail++))
fi

# Test 8: Equal NameDiff, equal TrackDiff, equal YearDiff, worse CountryPriority
reset_state
setup_best_state 5 5 5 3 15 5 "true"
setup_cand_state 5 5 5 5 15 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to higher CountryPriority"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to higher CountryPriority"
    ((fail++))
fi

# Test 9: Equal NameDiff, equal TrackDiff, equal YearDiff, equal CountryPriority, higher TrackCount
reset_state
setup_best_state 5 5 5 5 10 5 "true"
setup_cand_state 5 5 5 5 15 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to higher TrackCount"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to higher TrackCount"
    ((fail++))
fi

# Test 10: Equal NameDiff, equal TrackDiff, equal YearDiff, equal CountryPriority, lower TrackCount
reset_state
setup_best_state 5 5 5 5 15 5 "true"
setup_cand_state 5 5 5 5 10 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to lower TrackCount"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to lower TrackCount"
    ((fail++))
fi

# Test 11: Equal NameDiff, equal TrackDiff, equal YearDiff, equal CountryPriority, equal TrackCount, better FormatPriority
reset_state
setup_best_state 5 5 5 5 15 5 "true"
setup_cand_state 5 5 5 5 15 3 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to higher FormatPriority"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to higher FormatPriority"
    ((fail++))
fi

# Test 12: Equal NameDiff, equal TrackDiff, equal YearDiff, equal CountryPriority, equal TrackCount, worse FormatPriority
reset_state
setup_best_state 5 5 5 5 15 3 "true"
setup_cand_state 5 5 5 5 15 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to lower FormatPriority"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to lower FormatPriority"
    ((fail++))
fi

# Test 11: Equal NameDiff, equal TrackDiff, equal YearDiff, equal CountryPriority, equal TrackCount, equal FormatPriority, more preferred LyricType
reset_state
setup_best_state 5 5 5 5 15 5 "false"
setup_cand_state 5 5 5 5 15 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to more preferred LyricType"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to more preferred LyricType"
    ((fail++))
fi

# Test 12: Equal NameDiff, equal TrackDiff, equal YearDiff, equal CountryPriority, equal TrackCount, equal FormatPriority, less preferred LyricType
reset_state
setup_best_state 5 5 5 5 15 5 "true"
setup_cand_state 5 5 5 5 15 5 "false"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to less preferred LyricType"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to less preferred LyricType"
    ((fail++))
fi

# Test 13: All equal
reset_state
setup_best_state 5 5 5 5 15 5 "true"
setup_cand_state 5 5 5 5 15 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: All equal counts as worse"
    ((pass++))
else
    echo "❌ FAIL: All equal should count as worse"
    ((fail++))
fi

# Test 14: Varied case
reset_state
setup_best_state 3 5 3 5 10 5 "false"
setup_cand_state 5 3 5 3 15 3 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Varied case is worse"
    ((pass++))
else
    echo "❌ FAIL: Varied case should be worse"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
