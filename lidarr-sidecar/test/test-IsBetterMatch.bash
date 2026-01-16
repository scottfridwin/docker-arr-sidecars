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
    set_state "bestMatchCountryPriority" "${3:-999}"
    set_state "bestMatchNumTracks" "${4:-0}"
    set_state "bestMatchYearDiff" "${5:-9999}"
    set_state "bestMatchFormatPriority" "${6:-999}"
    set_state "bestMatchDeezerLyricTypePreferred" "${7:-false}"
}

# Helper to setup candidate state
setup_cand_state() {
    set_state "candidateNameDiff" "${1:-0}"
    set_state "candidateTrackDiff" "${2:-0}"
    set_state "lidarrReleaseCountryPriority" "${3:-0}"
    set_state "deezerCandidateTrackCount" "${4:-99}"
    set_state "candidateYearDiff" "${5:-0}"
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

# Test 5: Equal NameDiff, equal TrackDiff, better CountryPriority
reset_state
setup_best_state 5 5 5 15 5 5 "true"
setup_cand_state 5 5 3 15 5 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to lower CountryPriority"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to lower CountryPriority"
    ((fail++))
fi

# Test 6: Equal NameDiff, equal TrackDiff, worse CountryPriority
reset_state
setup_best_state 5 5 3 15 5 5 "true"
setup_cand_state 5 5 5 15 5 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to higher CountryPriority"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to higher CountryPriority"
    ((fail++))
fi

# Test 7: Equal NameDiff, equal TrackDiff, equal CountryPriority, higher TrackCount
reset_state
setup_best_state 5 5 5 10 5 5 "true"
setup_cand_state 5 5 5 15 5 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to higher TrackCount"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to higher TrackCount"
    ((fail++))
fi

# Test 8: Equal NameDiff, equal TrackDiff, equal CountryPriority, lower TrackCount
reset_state
setup_best_state 5 5 5 15 5 5 "true"
setup_cand_state 5 5 5 10 5 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to lower TrackCount"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to lower TrackCount"
    ((fail++))
fi

# Test 9: Equal NameDiff, equal TrackDiff, equal CountryPriority, equal TrackCount, better YearDiff
reset_state
setup_best_state 5 5 5 15 5 5 "true"
setup_cand_state 5 5 5 15 3 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to lower YearDiff"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to lower YearDiff"
    ((fail++))
fi

# Test 10: Equal NameDiff, equal TrackDiff, equal CountryPriority, equal TrackCount, worse YearDiff
reset_state
setup_best_state 5 5 5 15 3 5 "true"
setup_cand_state 5 5 5 15 5 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to higher YearDiff"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to higher YearDiff"
    ((fail++))
fi

# Test 11: Equal NameDiff, equal TrackDiff, equal CountryPriority, equal TrackCount, equal YearDiff, better FormatPriority
reset_state
setup_best_state 5 5 5 15 5 5 "true"
setup_cand_state 5 5 5 15 5 3 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to higher FormatPriority"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to higher FormatPriority"
    ((fail++))
fi

# Test 12: Equal NameDiff, equal TrackDiff, equal CountryPriority, equal TrackCount, equal YearDiff, worse FormatPriority
reset_state
setup_best_state 5 5 5 15 5 3 "true"
setup_cand_state 5 5 5 15 5 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to lower FormatPriority"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to lower FormatPriority"
    ((fail++))
fi

# Test 11: Equal NameDiff, equal TrackDiff, equal CountryPriority, equal TrackCount, equal YearDiff, equal FormatPriority, more preferred LyricType
reset_state
setup_best_state 5 5 5 15 5 5 "false"
setup_cand_state 5 5 5 15 5 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Better match due to more preferred LyricType"
    ((pass++))
else
    echo "❌ FAIL: Should be better due to more preferred LyricType"
    ((fail++))
fi

# Test 12: Equal NameDiff, equal TrackDiff, equal CountryPriority, equal TrackCount, equal YearDiff, equal FormatPriority, less preferred LyricType
reset_state
setup_best_state 5 5 5 15 5 5 "true"
setup_cand_state 5 5 5 15 5 5 "false"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse match due to less preferred LyricType"
    ((pass++))
else
    echo "❌ FAIL: Should be worse due to less preferred LyricType"
    ((fail++))
fi

# Test 13: All equal
reset_state
setup_best_state 5 5 5 15 5 5 "true"
setup_cand_state 5 5 5 15 5 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: All equal counts as worse"
    ((pass++))
else
    echo "❌ FAIL: All equal should count as worse"
    ((fail++))
fi

# Test 14: Varied case
reset_state
setup_best_state 3 5 5 10 3 5 "false"
setup_cand_state 5 3 3 15 5 3 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Varied case is worse"
    ((pass++))
else
    echo "❌ FAIL: Varied case should be worse"
    ((fail++))
fi

# Test 15: Equal NameDiff + TrackDiff, multiple secondary fields better (country + trackcount + year + format + lyric)
reset_state
setup_best_state 5 5 5 10 10 5 "false"
setup_cand_state 5 5 3 12 5 3 "true"
if IsBetterMatch; then
    echo "✅ PASS: Multiple secondary improvements correctly produce better match"
    ((pass++))
else
    echo "❌ FAIL: Multiple secondary improvements should be better"
    ((fail++))
fi

# Test 16: Multiple secondary fields worse (country + trackcount + year + format + lyric)
reset_state
setup_best_state 5 5 3 12 5 3 "true"
setup_cand_state 5 5 5 10 10 7 "false"
if ! IsBetterMatch; then
    echo "✅ PASS: Multiple secondary worse fields produce worse match"
    ((pass++))
else
    echo "❌ FAIL: Multiple-worse candidate should lose"
    ((fail++))
fi

# Test 17: Negative CountryPriority values
reset_state
setup_best_state 5 5 -5 10 5 5 "true"
setup_cand_state 5 5 -3 10 5 5 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Higher (-3 > -5) country priority is worse"
    ((pass++))
else
    echo "❌ FAIL: Negative country priority case incorrect"
    ((fail++))
fi

# Test 18: Huge CountryPriority difference
reset_state
setup_best_state 5 5 9999 10 5 5 "true"
setup_cand_state 5 5 0 10 5 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Much lower country priority should win"
    ((pass++))
else
    echo "❌ FAIL: Huge country priority advantage should be better"
    ((fail++))
fi

# Test 19: Negative YearDiff (candidate better)
reset_state
setup_best_state 5 5 5 10 0 5 "true"
setup_cand_state 5 5 5 10 -1 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: Negative YearDiff is better"
    ((pass++))
else
    echo "❌ FAIL: Negative YearDiff should win"
    ((fail++))
fi

# Test 20: Format equal but lyricType decides
reset_state
setup_best_state 5 5 5 10 5 5 "false"
setup_cand_state 5 5 5 10 5 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: LyricType breaks tie when all else equal"
    ((pass++))
else
    echo "❌ FAIL: LyricType should determine winner"
    ((fail++))
fi

# Test 21: candidate lyric=true, best lyric="", should be better
reset_state
setup_best_state 5 5 5 10 5 5 ""
setup_cand_state 5 5 5 10 5 5 "true"
if IsBetterMatch; then
    echo "✅ PASS: candidate lyric=true beats empty best"
    ((pass++))
else
    echo "❌ FAIL: lyric empty should count as false"
    ((fail++))
fi

# Test 22: candidate lyric="", best lyric=true → candidate worse
reset_state
setup_best_state 5 5 5 10 5 5 "true"
setup_cand_state 5 5 5 10 5 5 ""
if ! IsBetterMatch; then
    echo "✅ PASS: empty candidate lyric loses to true"
    ((pass++))
else
    echo "❌ FAIL: empty candidate lyric should lose"
    ((fail++))
fi

# Test 23: candidate lyric=TRUE (uppercase) should NOT equal "true"
reset_state
setup_best_state 5 5 5 10 5 5 "false"
setup_cand_state 5 5 5 10 5 5 "TRUE"
if ! IsBetterMatch; then
    echo "✅ PASS: uppercase TRUE does not count as preferred lyric"
    ((pass++))
else
    echo "❌ FAIL: uppercase TRUE should not trigger lyric advantage"
    ((fail++))
fi

# Test 24: candidate lyric=yes, best=false → not considered better
reset_state
setup_best_state 5 5 5 10 5 5 "false"
setup_cand_state 5 5 5 10 5 5 "yes"
if ! IsBetterMatch; then
    echo "✅ PASS: 'yes' is not treated as true"
    ((pass++))
else
    echo "❌ FAIL: 'yes' should not be treated as true"
    ((fail++))
fi

# Test 25: Tie on all categories except candidate format better
reset_state
setup_best_state 5 5 5 10 5 5 "true"
setup_cand_state 5 5 5 10 5 3 "true"
if IsBetterMatch; then
    echo "✅ PASS: FormatPriority correctly breaks tie"
    ((pass++))
else
    echo "❌ FAIL: FormatPriority should win tie"
    ((fail++))
fi

# Test 26: Tie on all but lyricType worse
reset_state
setup_best_state 5 5 5 10 5 5 "true"
setup_cand_state 5 5 5 10 5 5 "false"
if ! IsBetterMatch; then
    echo "✅ PASS: LyricType worse loses"
    ((pass++))
else
    echo "❌ FAIL: LyricType worse should lose"
    ((fail++))
fi

# Test 27: Candidate worse NameDiff but better in all other secondary metrics → should still be WORSE
reset_state
setup_best_state 3 5 5 10 5 5 "false"
setup_cand_state 4 0 0 20 0 0 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse NameDiff cannot be overridden by secondary criteria"
    ((pass++))
else
    echo "❌ FAIL: NameDiff must dominate"
    ((fail++))
fi

# Test 28: Candidate equal NameDiff but worse TrackDiff even with all other fields better → still worse
reset_state
setup_best_state 5 3 5 10 5 5 "false"
setup_cand_state 5 4 0 20 0 0 "true"
if ! IsBetterMatch; then
    echo "✅ PASS: Worse TrackDiff cannot be overridden"
    ((pass++))
else
    echo "❌ FAIL: TrackDiff must dominate"
    ((fail++))
fi

# Test 29: Numeric strings with leading zeros
reset_state
setup_best_state "05" "03" 5 10 5 5 "false"
setup_cand_state "05" "02" 5 10 5 5 "false"
if IsBetterMatch; then
    echo "✅ PASS: Leading-zero values compare correctly"
    ((pass++))
else
    echo "❌ FAIL: Leading-zero handling incorrect"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
