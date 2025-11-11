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

# Test 1: Basic state update
reset_state
set_state "currentYearDiff" "2"
UpdateBestMatchState "123456" "Abbey Road" "1969" "0" "0" "17" "true" "0" "0" "false" '{"releaseId":"abc"}'

if [[ "$(get_state "bestMatchID")" == "123456" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "Abbey Road" ]] &&
    [[ "$(get_state "bestMatchYear")" == "1969" ]] &&
    [[ "$(get_state "bestMatchDistance")" == "0" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "17" ]]; then
    echo "✅ PASS: Basic state update"
    ((pass++))
else
    echo "❌ FAIL: Basic state update"
    ((fail++))
fi

# Test 2: Exact match detection (distance=0, trackDiff=0)
reset_state
set_state "currentYearDiff" "0"
UpdateBestMatchState "789012" "1989" "2014" "0" "0" "13" "true" "1" "1" "false" '{}'

if [[ "$(get_state "exactMatchFound")" == "true" ]]; then
    echo "✅ PASS: Exact match detected (distance=0, trackDiff=0)"
    ((pass++))
else
    echo "❌ FAIL: Exact match detection (got '$(get_state "exactMatchFound")')"
    ((fail++))
fi

# Test 3: Non-exact match (distance > 0)
reset_state
set_state "currentYearDiff" "1"
UpdateBestMatchState "111111" "Test Album" "2020" "5" "0" "10" "true" "2" "2" "false" '{}'
if [[ "$(get_state "exactMatchFound")" != "true" ]]; then
    echo "✅ PASS: Non-exact match not marked as exact (distance=5)"
    ((pass++))
else
    echo "❌ FAIL: Non-exact match incorrectly marked as exact"
    ((fail++))
fi

# Test 4: Non-exact match (trackDiff > 0)
reset_state
set_state "currentYearDiff" "0"
UpdateBestMatchState "222222" "Test Album 2" "2021" "0" "3" "12" "false" "3" "3" "false" '{}'

if [[ "$(get_state "exactMatchFound")" != "true" ]]; then
    echo "✅ PASS: Non-exact match not marked as exact (trackDiff=3)"
    ((pass++))
else
    echo "❌ FAIL: Non-exact match with trackDiff incorrectly marked as exact"
    ((fail++))
fi

# Test 5: Lyric type preference stored
reset_state
set_state "currentYearDiff" "1"
UpdateBestMatchState "333333" "Album" "2022" "2" "1" "15" "false" "4" "4" "false" '{}'

if [[ "$(get_state "bestMatchLyricTypePreferred")" == "false" ]]; then
    echo "✅ PASS: Lyric type preference stored correctly"
    ((pass++))
else
    echo "❌ FAIL: Lyric type preference (got '$(get_state "bestMatchLyricTypePreferred")')"
    ((fail++))
fi

# Test 6: Format priority stored
reset_state
set_state "currentYearDiff" "0"
UpdateBestMatchState "444444" "Format Test" "2023" "1" "0" "20" "true" "5" "6" "false" '{}'

if [[ "$(get_state "bestMatchFormatPriority")" == "5" ]]; then
    echo "✅ PASS: Format priority stored correctly"
    ((pass++))
else
    echo "❌ FAIL: Format priority (got '$(get_state "bestMatchFormatPriority")')"
    ((fail++))
fi

# Test 7: Country priority stored
reset_state
set_state "currentYearDiff" "2"
UpdateBestMatchState "555555" "Country Test" "2024" "0" "1" "18" "true" "7" "8" "false" '{}'

if [[ "$(get_state "bestMatchCountryPriority")" == "8" ]]; then
    echo "✅ PASS: Country priority stored correctly"
    ((pass++))
else
    echo "❌ FAIL: Country priority (got '$(get_state "bestMatchCountryPriority")')"
    ((fail++))
fi

# Test 8: Commentary flag stored
reset_state
set_state "currentYearDiff" "0"
UpdateBestMatchState "666666" "Commentary Album" "2025" "0" "0" "25" "true" "9" "9" "true" '{}'

if [[ "$(get_state "bestMatchContainsCommentary")" == "true" ]]; then
    echo "✅ PASS: Commentary flag stored correctly"
    ((pass++))
else
    echo "❌ FAIL: Commentary flag (got '$(get_state "bestMatchContainsCommentary")')"
    ((fail++))
fi

# Test 9: Release info JSON stored
reset_state
set_state "currentYearDiff" "1"
releaseInfoJson='{"releaseId":"test123","format":"CD","country":["US"]}'
UpdateBestMatchState "777777" "JSON Test" "2026" "1" "2" "30" "false" "10" "10" "false" "$releaseInfoJson"

if [[ "$(get_state "bestMatchLidarrReleaseInfo")" == "$releaseInfoJson" ]]; then
    echo "✅ PASS: Release info JSON stored correctly"
    ((pass++))
else
    echo "❌ FAIL: Release info JSON storage"
    ((fail++))
fi

# Test 10: Year diff stored from currentYearDiff state
reset_state
set_state "currentYearDiff" "5"
UpdateBestMatchState "888888" "Year Diff Test" "2027" "0" "0" "14" "true" "11" "11" "false" '{}'

if [[ "$(get_state "bestMatchYearDiff")" == "5" ]]; then
    echo "✅ PASS: Year diff stored from currentYearDiff"
    ((pass++))
else
    echo "❌ FAIL: Year diff (got '$(get_state "bestMatchYearDiff")', expected 5)"
    ((fail++))
fi

# Test 11: All 11 parameters stored correctly
reset_state
set_state "currentYearDiff" "3"
UpdateBestMatchState \
    "999999" \
    "Complete Test" \
    "2028" \
    "7" \
    "4" \
    "22" \
    "true" \
    "12" \
    "13" \
    "true" \
    '{"complete":"test"}'

allCorrect=true
[[ "$(get_state "bestMatchID")" != "999999" ]] && allCorrect=false
[[ "$(get_state "bestMatchTitle")" != "Complete Test" ]] && allCorrect=false
[[ "$(get_state "bestMatchYear")" != "2028" ]] && allCorrect=false
[[ "$(get_state "bestMatchDistance")" != "7" ]] && allCorrect=false
[[ "$(get_state "bestMatchTrackDiff")" != "4" ]] && allCorrect=false
[[ "$(get_state "bestMatchNumTracks")" != "22" ]] && allCorrect=false
[[ "$(get_state "bestMatchLyricTypePreferred")" != "true" ]] && allCorrect=false
[[ "$(get_state "bestMatchFormatPriority")" != "12" ]] && allCorrect=false
[[ "$(get_state "bestMatchCountryPriority")" != "13" ]] && allCorrect=false
[[ "$(get_state "bestMatchContainsCommentary")" != "true" ]] && allCorrect=false
[[ "$(get_state "bestMatchYearDiff")" != "3" ]] && allCorrect=false

if [[ "$allCorrect" == "true" ]]; then
    echo "✅ PASS: All 11 parameters stored correctly"
    ((pass++))
else
    echo "❌ FAIL: Not all parameters stored correctly"
    echo "  ID: $(get_state "bestMatchID")"
    echo "  Title: $(get_state "bestMatchTitle")"
    echo "  Year: $(get_state "bestMatchYear")"
    echo "  Distance: $(get_state "bestMatchDistance")"
    echo "  TrackDiff: $(get_state "bestMatchTrackDiff")"
    echo "  NumTracks: $(get_state "bestMatchNumTracks")"
    echo "  LyricPreferred: $(get_state "bestMatchLyricTypePreferred")"
    echo "  FormatPriority: $(get_state "bestMatchFormatPriority")"
    echo "  CountryPriority: $(get_state "bestMatchCountryPriority")"
    echo "  ContainsCommentary: $(get_state "bestMatchContainsCommentary")"
    echo "  YearDiff: $(get_state "bestMatchYearDiff")"
    ((fail++))
fi

# Test 12: Exact match with exact year
reset_state
set_state "currentYearDiff" "0"
UpdateBestMatchState "101010" "Perfect Match" "2029" "0" "0" "16" "true" "0" "0" "false" '{}'

if [[ "$(get_state "exactMatchFound")" == "true" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "0" ]]; then
    echo "✅ PASS: Exact match with exact year"
    ((pass++))
else
    echo "❌ FAIL: Exact match with exact year"
    ((fail++))
fi

# Test 13: Update overwrites previous values
reset_state
set_state "currentYearDiff" "1"
set_state "bestMatchID" "old123"
set_state "bestMatchTitle" "Old Title"
set_state "bestMatchDistance" "99"

UpdateBestMatchState "new456" "New Title" "2030" "2" "1" "19" "false" "14" "15" "true" '{}'

if [[ "$(get_state "bestMatchID")" == "new456" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "New Title" ]] &&
    [[ "$(get_state "bestMatchDistance")" == "2" ]]; then
    echo "✅ PASS: Update overwrites previous values"
    ((pass++))
else
    echo "❌ FAIL: Update did not overwrite previous values"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
