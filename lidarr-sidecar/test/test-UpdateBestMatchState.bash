#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/utilities.sh"
source "${SCRIPT_DIR}/../services/functions.bash"

#### Mocks ####
log() {
    : # Do nothing, suppress logs in tests
}

# Helper to setup candidate state
setup_cand_state() {
    set_state "deezerCandidateAlbumID" "${1}"
    set_state "deezerCandidateTitleVariant" "${2}"
    set_state "candidateNameDiff" "${3}"
    set_state "candidateTrackDiff" "${4}"
    set_state "candidateYearDiff" "${5}"
    set_state "deezerCandidateReleaseYear" "${6}"
    set_state "deezerCandidateTrackCount" "${7}"
    set_state "lidarrReleaseFormatPriority" "${8}"
    set_state "lidarrReleaseCountryPriority" "${9}"
    set_state "deezerCandidatelyricTypePreferred" "${10}"
    set_state "lidarrReleaseContainsCommentary" "${11}"
    set_state "lidarrReleaseForeignId" "${12}"
    set_state "exactMatchFound" "${13-exactMatch_unset}"
}

pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 1: All states updated
reset_state
setup_cand_state "id_set" "title_set" "nameDiff_set" "trackDiff_set" "yearDiff_set" "year_set" "trackCount_set" "formatPriority_set" "countryPriority_set" "lyricTypePreferred_set" "containsCommentary_set" 'releaseForeignId_set'
UpdateBestMatchState

if [[ "$(get_state "bestMatchID")" == "id_set" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "title_set" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "nameDiff_set" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "trackDiff_set" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "yearDiff_set" ]] &&
    [[ "$(get_state "bestMatchYear")" == "year_set" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "trackCount_set" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "formatPriority_set" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "countryPriority_set" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "lyricTypePreferred_set" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "containsCommentary_set" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "releaseForeignId_set" ]] &&
    [[ "$(get_state "exactMatchFound")" == "exactMatch_unset" ]]; then
    echo "✅ PASS: All states updated"
    ((pass++))
else
    echo "❌ FAIL: All states updated"
    ((fail++))
fi

# Test 2: Exact match detection (NameDiff=0, TrackDiff=0, YearDiff=0)
reset_state
setup_cand_state "id_set" "title_set" "0" "0" "0" "year_set" "trackCount_set" "formatPriority_set" "countryPriority_set" "lyricTypePreferred_set" "containsCommentary_set" 'releaseForeignId_set'
UpdateBestMatchState

if [[ "$(get_state "bestMatchID")" == "id_set" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "title_set" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYear")" == "year_set" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "trackCount_set" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "formatPriority_set" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "countryPriority_set" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "lyricTypePreferred_set" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "containsCommentary_set" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "releaseForeignId_set" ]] &&
    [[ "$(get_state "exactMatchFound")" == "true" ]]; then
    echo "✅ PASS: Non-exact match (NameDiff)"
    ((pass++))
else
    echo "❌ FAIL: Non-exact match (NameDiff)"
    ((fail++))
fi

# Test 3: Non-exact match (NameDiff > 0)
reset_state
setup_cand_state "id_set" "title_set" "1" "0" "0" "year_set" "trackCount_set" "formatPriority_set" "countryPriority_set" "lyricTypePreferred_set" "containsCommentary_set" 'releaseForeignId_set'
UpdateBestMatchState

if [[ "$(get_state "bestMatchID")" == "id_set" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "title_set" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "1" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYear")" == "year_set" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "trackCount_set" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "formatPriority_set" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "countryPriority_set" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "lyricTypePreferred_set" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "containsCommentary_set" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "releaseForeignId_set" ]] &&
    [[ "$(get_state "exactMatchFound")" == "exactMatch_unset" ]]; then
    echo "✅ PASS: Non-exact match (YearDiff)"
    ((pass++))
else
    echo "❌ FAIL: Non-exact match (YearDiff)"
    ((fail++))
fi

# Test 3: Non-exact match (TrackDiff > 0)
reset_state
setup_cand_state "id_set" "title_set" "0" "1" "0" "year_set" "trackCount_set" "formatPriority_set" "countryPriority_set" "lyricTypePreferred_set" "containsCommentary_set" 'releaseForeignId_set'
UpdateBestMatchState

if [[ "$(get_state "bestMatchID")" == "id_set" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "title_set" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "1" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYear")" == "year_set" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "trackCount_set" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "formatPriority_set" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "countryPriority_set" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "lyricTypePreferred_set" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "containsCommentary_set" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "releaseForeignId_set" ]] &&
    [[ "$(get_state "exactMatchFound")" == "exactMatch_unset" ]]; then
    echo "✅ PASS: Non-exact match (TrackDiff)"
    ((pass++))
else
    echo "❌ FAIL: Non-exact match (TrackDiff)"
    ((fail++))
fi

# Test 3: Non-exact match (YearDiff > 0)
# Now correctly maps to exact match
reset_state
setup_cand_state "id_set" "title_set" "0" "0" "1" "year_set" "trackCount_set" "formatPriority_set" "countryPriority_set" "lyricTypePreferred_set" "containsCommentary_set" 'releaseForeignId_set'
UpdateBestMatchState

if [[ "$(get_state "bestMatchID")" == "id_set" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "title_set" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "1" ]] &&
    [[ "$(get_state "bestMatchYear")" == "year_set" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "trackCount_set" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "formatPriority_set" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "countryPriority_set" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "lyricTypePreferred_set" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "containsCommentary_set" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "releaseForeignId_set" ]] &&
    [[ "$(get_state "exactMatchFound")" == "true" ]]; then
    echo "✅ PASS: Non-exact match (YearDiff)"
    ((pass++))
else
    echo "❌ FAIL: Non-exact match (YearDiff)"
    ((fail++))
fi

# Test 4: Update overwrites previous values
reset_state
setup_cand_state "id_set" "title_set" "nameDiff_set" "trackDiff_set" "yearDiff_set" "year_set" "trackCount_set" "formatPriority_set" "countryPriority_set" "lyricTypePreferred_set" "containsCommentary_set" 'releaseForeignId_set'
set_state "bestMatchID" "id_unset"
set_state "bestMatchTitle" "title_unset"
set_state "bestMatchNameDiff" "nameDiff_unset"
set_state "bestMatchTrackDiff" "trackDiff_unset"
set_state "bestMatchYearDiff" "yearDiff_unset"
set_state "bestMatchYear" "year_unset"
set_state "bestMatchNumTracks" "trackCount_unset"
set_state "bestMatchFormatPriority" "formatPriority_unset"
set_state "bestMatchCountryPriority" "countryPriority_unset"
set_state "bestMatchDeezerLyricTypePreferred" "lyricTypePreferred_unset"
set_state "bestMatchContainsCommentary" "containsCommentary_unset"
set_state "bestMatchLidarrReleaseForeignId" "releaseForeignId_unset"
UpdateBestMatchState

if [[ "$(get_state "bestMatchID")" == "id_set" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "title_set" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "nameDiff_set" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "trackDiff_set" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "yearDiff_set" ]] &&
    [[ "$(get_state "bestMatchYear")" == "year_set" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "trackCount_set" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "formatPriority_set" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "countryPriority_set" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "lyricTypePreferred_set" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "containsCommentary_set" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "releaseForeignId_set" ]] &&
    [[ "$(get_state "exactMatchFound")" == "exactMatch_unset" ]]; then
    echo "✅ PASS: Update overwrites previous values"
    ((pass++))
else
    echo "❌ FAIL: Update did not overwrite previous values"
    ((fail++))
fi

# Test 5: Non-numeric NameDiff
reset_state
setup_cand_state "id_set" "title_set" "abc" "0" "0" "year_set" "trackCount_set" "formatPriority_set" "countryPriority_set" "lyricTypePreferred_set" "containsCommentary_set" 'releaseForeignId_set'
UpdateBestMatchState

if [[ "$(get_state "bestMatchID")" == "id_set" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "title_set" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "abc" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYear")" == "year_set" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "trackCount_set" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "formatPriority_set" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "countryPriority_set" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "lyricTypePreferred_set" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "containsCommentary_set" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "releaseForeignId_set" ]] &&
    [[ "$(get_state "exactMatchFound")" == "exactMatch_unset" ]]; then
    echo "✅ PASS: Non-numeric NameDiff"
    ((pass++))
else
    echo "❌ FAIL: Non-numeric NameDiff"
    ((fail++))
fi

# Test 6: Non-numeric TrackDiff
reset_state
setup_cand_state "id_set" "title_set" "0" "abc" "0" "year_set" "trackCount_set" "formatPriority_set" "countryPriority_set" "lyricTypePreferred_set" "containsCommentary_set" 'releaseForeignId_set'
UpdateBestMatchState

if [[ "$(get_state "bestMatchID")" == "id_set" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "title_set" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "abc" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYear")" == "year_set" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "trackCount_set" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "formatPriority_set" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "countryPriority_set" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "lyricTypePreferred_set" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "containsCommentary_set" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "releaseForeignId_set" ]] &&
    [[ "$(get_state "exactMatchFound")" == "exactMatch_unset" ]]; then
    echo "✅ PASS: Non-numeric TrackDiff"
    ((pass++))
else
    echo "❌ FAIL: Non-numeric TrackDiff"
    ((fail++))
fi

# Test 7: Non-numeric YearDiff
reset_state
setup_cand_state "id_set" "title_set" "0" "0" "abc" "year_set" "trackCount_set" "formatPriority_set" "countryPriority_set" "lyricTypePreferred_set" "containsCommentary_set" 'releaseForeignId_set'
UpdateBestMatchState

if [[ "$(get_state "bestMatchID")" == "id_set" ]] &&
    [[ "$(get_state "bestMatchTitle")" == "title_set" ]] &&
    [[ "$(get_state "bestMatchNameDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchTrackDiff")" == "0" ]] &&
    [[ "$(get_state "bestMatchYearDiff")" == "abc" ]] &&
    [[ "$(get_state "bestMatchYear")" == "year_set" ]] &&
    [[ "$(get_state "bestMatchNumTracks")" == "trackCount_set" ]] &&
    [[ "$(get_state "bestMatchFormatPriority")" == "formatPriority_set" ]] &&
    [[ "$(get_state "bestMatchCountryPriority")" == "countryPriority_set" ]] &&
    [[ "$(get_state "bestMatchDeezerLyricTypePreferred")" == "lyricTypePreferred_set" ]] &&
    [[ "$(get_state "bestMatchContainsCommentary")" == "containsCommentary_set" ]] &&
    [[ "$(get_state "bestMatchLidarrReleaseForeignId")" == "releaseForeignId_set" ]] &&
    [[ "$(get_state "exactMatchFound")" == "true" ]]; then
    echo "✅ PASS: Non-numeric YearDiff"
    ((pass++))
else
    echo "❌ FAIL: Non-numeric YearDiff"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
