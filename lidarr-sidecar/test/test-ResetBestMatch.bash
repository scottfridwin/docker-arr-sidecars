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
init_state

echo "----------------------------------------------"

# Test 1: Reset from populated state
reset_state
set_state "bestMatchID" "12345"
set_state "bestMatchTitle" "Some Album"
set_state "bestMatchYear" "2023"
set_state "bestMatchNameDiff" "5"
set_state "bestMatchTrackDiff" "2"
set_state "bestMatchNumTracks" "15"
set_state "bestMatchContainsCommentary" "true"
set_state "bestMatchLidarrReleaseForeignId" 'uuid123'
set_state "bestMatchFormatPriority" "1"
set_state "bestMatchCountryPriority" "2"
set_state "bestMatchDeezerLyricTypePreferred" "true"
set_state "bestMatchYearDiff" "1"
set_state "exactMatchFound" "true"

ResetBestMatch

if [[ "$(get_state "bestMatchID")" == "" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "" ]] &&
    [[ "$(get_state "bestMatchYear")" == "" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "9999" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "9999" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "0" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "false" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "999" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "999" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "false" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "999" ]] &&
    [[ "$(get_state "exactMatchFound")" != "true" ]]; then
    echo "✅ PASS: Reset from populated state"
    ((pass++))
else
    echo "❌ FAIL: Reset from populated state - not all values reset correctly"
    echo "  bestMatchID: '$(get_state "bestMatchID")'"
    echo "  bestMatchTitle: '$(get_state "bestMatchTitle")'"
    echo "  bestMatchNameDiff: '$(get_state "bestMatchNameDiff")'"
    echo "  bestMatchTrackDiff: '$(get_state "bestMatchTrackDiff")'"
    echo "  bestMatchNumTracks: '$(get_state "bestMatchNumTracks")'"
    echo "  exactMatchFound: '$(get_state "exactMatchFound")'"
    ((fail++))
fi

# Test 2: Reset from already empty state
reset_state
ResetBestMatch

if [[ "$(get_state "bestMatchID")" == "" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "9999" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "9999" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "0" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "999" ]] &&
    [[ "$(get_state "exactMatchFound")" != "true" ]]; then
    echo "✅ PASS: Reset from empty state"
    ((pass++))
else
    echo "❌ FAIL: Reset from empty state - values not set correctly"
    ((fail++))
fi

# Test 3: Verify bestMatchNameDiff is set to high value
reset_state
set_state "bestMatchNameDiff" "1"
ResetBestMatch
if [[ "$(get_state "bestMatchNameDiff")" == "9999" ]]; then
    echo "✅ PASS: bestMatchNameDiff reset to 9999"
    ((pass++))
else
    echo "❌ FAIL: bestMatchNameDiff not reset to 9999, got '$(get_state "bestMatchNameDiff")'"
    ((fail++))
fi

# Test 4: Verify bestMatchTrackDiff is set to high value
reset_state
set_state "bestMatchTrackDiff" "3"
ResetBestMatch
if [[ "$(get_state "bestMatchTrackDiff")" == "9999" ]]; then
    echo "✅ PASS: bestMatchTrackDiff reset to 9999"
    ((pass++))
else
    echo "❌ FAIL: bestMatchTrackDiff not reset to 9999, got '$(get_state "bestMatchTrackDiff")'"
    ((fail++))
fi

# Test 5: Verify bestMatchNumTracks is set to 0
reset_state
set_state "bestMatchNumTracks" "20"
ResetBestMatch
if [[ "$(get_state "bestMatchNumTracks")" == "0" ]]; then
    echo "✅ PASS: bestMatchNumTracks reset to 0"
    ((pass++))
else
    echo "❌ FAIL: bestMatchNumTracks not reset to 0, got '$(get_state "bestMatchNumTracks")'"
    ((fail++))
fi

# Test 6: Verify exactMatchFound is set to false
reset_state
set_state "exactMatchFound" "true"
ResetBestMatch
if [[ "$(get_state "exactMatchFound")" != "true" ]]; then
    echo "✅ PASS: exactMatchFound reset"
    ((pass++))
else
    echo "❌ FAIL: exactMatchFound not reset, got '$(get_state "exactMatchFound")'"
    ((fail++))
fi

# Test 7: Verify bestMatchContainsCommentary is set to false
reset_state
set_state "bestMatchContainsCommentary" "true"
ResetBestMatch
if [[ "$(get_state "bestMatchContainsCommentary")" == "false" ]]; then
    echo "✅ PASS: bestMatchContainsCommentary reset to false"
    ((pass++))
else
    echo "❌ FAIL: bestMatchContainsCommentary not reset to false, got '$(get_state "bestMatchContainsCommentary")'"
    ((fail++))
fi

# Test 8: Verify bestMatchYearDiff is set to 999
reset_state
set_state "bestMatchYearDiff" "5"
ResetBestMatch
if [[ "$(get_state "bestMatchYearDiff")" == "999" ]]; then
    echo "✅ PASS: bestMatchYearDiff reset to 999"
    ((pass++))
else
    echo "❌ FAIL: bestMatchYearDiff not reset to 999, got '$(get_state "bestMatchYearDiff")'"
    ((fail++))
fi

# Test 9: Verify all string fields are empty
reset_state
set_state "bestMatchID" "abc123"
set_state "bestMatchTitle" "Album Title"
set_state "bestMatchYear" "2020"
set_state "bestMatchLidarrReleaseForeignId" 'uuid123'
set_state "bestMatchFormatPriority" "high"
set_state "bestMatchCountryPriority" "US"
set_state "bestMatchDeezerLyricTypePreferred" "explicit"

ResetBestMatch

if [[ "$(get_state "bestMatchID")" == "" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "" ]] &&
    [[ "$(get_state "bestMatchYear")" == "" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "" ]]; then
    echo "✅ PASS: All string fields reset to empty"
    ((pass++))
else
    echo "❌ FAIL: Not all string fields reset to empty"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
