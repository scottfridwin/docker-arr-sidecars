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
    set_state "searchReleaseTitleClean" "${1}"
    set_state "deezerCandidateTitleVariant" "${2}"
    set_state "lidarrReleaseTrackCount" "${3}"
    set_state "deezerCandidateTrackCount" "${4}"
    set_state "lidarrReleaseYear" "${5}"
    set_state "deezerCandidateReleaseYear" "${6}"
    set_state "lidarrReleaseMBJson" "${7}"
}
# Mock environment variables
export AUDIO_COMMENTARY_KEYWORDS="commentary,talkytalky"

pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 1: Identical match
reset_state
setup_state "oak street" "oak street" "17" "17" "1999" "1999" "{ \"abc\": \"123\" }"
ComputePrimaryMatchMetrics
candidateNameDiff=$(get_state "candidateNameDiff")
candidateTrackDiff=$(get_state "candidateTrackDiff")
candidateYearDiff=$(get_state "candidateYearDiff")
if [[ "$candidateNameDiff" == "0" ]] && [[ "$candidateTrackDiff" == "0" ]] && [[ "$candidateYearDiff" == "0" ]]; then
    echo "✅ PASS: Identical (candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((pass++))
else
    echo "❌ FAIL: Identical (got candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((fail++))
fi

# Test 2: Similar
reset_state
setup_state "oak street" "elm street" "13" "16" "1999" "2002" "{ \"abc\": \"123\" }"
ComputePrimaryMatchMetrics
candidateNameDiff=$(get_state "candidateNameDiff")
candidateTrackDiff=$(get_state "candidateTrackDiff")
candidateYearDiff=$(get_state "candidateYearDiff")
if [[ "$candidateNameDiff" == "3" ]] && [[ "$candidateTrackDiff" == "3" ]] && [[ "$candidateYearDiff" == "3" ]]; then
    echo "✅ PASS: Similar (candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((pass++))
else
    echo "❌ FAIL: Similar (got candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((fail++))
fi

# Test 3: Very different
reset_state
setup_state "oak street" "green album" "17" "30" "1999" "2015" "{ \"abc\": \"123\" }"
ComputePrimaryMatchMetrics
candidateNameDiff=$(get_state "candidateNameDiff")
candidateTrackDiff=$(get_state "candidateTrackDiff")
candidateYearDiff=$(get_state "candidateYearDiff")
if [[ "$candidateNameDiff" == "11" ]] && [[ "$candidateTrackDiff" == "13" ]] && [[ "$candidateYearDiff" == "16" ]]; then
    echo "✅ PASS: Very different (candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((pass++))
else
    echo "❌ FAIL: Very different (got candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((fail++))
fi

# Test 4: Case insensitivity
reset_state
setup_state "oak street" "OAK STREET" "17" "17" "1999" "1999" "{ \"abc\": \"123\" }"
ComputePrimaryMatchMetrics
candidateNameDiff=$(get_state "candidateNameDiff")
candidateTrackDiff=$(get_state "candidateTrackDiff")
candidateYearDiff=$(get_state "candidateYearDiff")
if [[ "$candidateNameDiff" == "0" ]] && [[ "$candidateTrackDiff" == "0" ]] && [[ "$candidateYearDiff" == "0" ]]; then
    echo "✅ PASS: Case insensitivity (candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((pass++))
else
    echo "❌ FAIL: Case insensitivity (got candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((fail++))
fi

# Test 5: Commentary detection positive 1
reset_state
setup_state "oak street (talkytalky)" "elm street" "13" "16" "1999" "2002" "{ \"abc\": \"123\" }"
ComputePrimaryMatchMetrics
lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
if [[ "$lidarrReleaseContainsCommentary" == "true" ]]; then
    echo "✅ PASS: Commentary detection positive 1"
    ((pass++))
else
    echo "❌ FAIL: Commentary detection positive 1"
    ((fail++))
fi

# Test 6: Commentary detection positive 2
reset_state
setup_state "oak street (commentary)" "elm street" "13" "16" "1999" "2002" "{ \"abc\": \"123\" }"
ComputePrimaryMatchMetrics
lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
if [[ "$lidarrReleaseContainsCommentary" == "true" ]]; then
    echo "✅ PASS: Commentary detection positive 2"
    ((pass++))
else
    echo "❌ FAIL: Commentary detection positive 2"
    ((fail++))
fi

# Test 7: Commentary detection positive 3
reset_state
setup_state "oak street" "elm street" "13" "16" "1999" "2002" "{\"media\":[{\"tracks\": [{\"title\": \"Overture\"},{\"title\": \"Overture (Commentary)\"}]}]}"
ComputePrimaryMatchMetrics
lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
if [[ "$lidarrReleaseContainsCommentary" == "true" ]]; then
    echo "✅ PASS: Commentary detection positive 3"
    ((pass++))
else
    echo "❌ FAIL: Commentary detection positive 3"
    ((fail++))
fi

# Test 8: Commentary detection positive 4
reset_state
setup_state "oak street" "elm street" "13" "16" "1999" "2002" "{\"media\":[{\"tracks\": [{\"title\": \"Overture\"},{\"title\": \"Overture (reprise)\"},{\"title\": \"Overture (talkytalky)\"}]}]}"
ComputePrimaryMatchMetrics
lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
if [[ "$lidarrReleaseContainsCommentary" == "true" ]]; then
    echo "✅ PASS: Commentary detection positive 4"
    ((pass++))
else
    echo "❌ FAIL: Commentary detection positive 4"
    ((fail++))
fi

# Test 9: Commentary detection negative 1
reset_state
setup_state "oak street (commantary)" "elm street" "13" "16" "1999" "2002" "{ \"abc\": \"123\" }"
ComputePrimaryMatchMetrics
lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
if [[ "$lidarrReleaseContainsCommentary" == "false" ]]; then
    echo "✅ PASS: Commentary detection negative 1"
    ((pass++))
else
    echo "❌ FAIL: Commentary detection negative 1"
    ((fail++))
fi

# Test 10: Commentary detection negative 2
reset_state
setup_state "oak street (deluxe)" "elm street" "13" "16" "1999" "2002" "{ \"abc\": \"123\" }"
ComputePrimaryMatchMetrics
lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
if [[ "$lidarrReleaseContainsCommentary" == "false" ]]; then
    echo "✅ PASS: Commentary detection negative 2"
    ((pass++))
else
    echo "❌ FAIL: Commentary detection negative 2"
    ((fail++))
fi

# Test 11: Commentary detection negative 3
reset_state
setup_state "oak street" "elm street" "13" "16" "1999" "2002" "{\"media\":[{\"tracks\": [{\"title\": \"Overture\"},{\"title\": \"Overture (commantary)\"}]}]}"
ComputePrimaryMatchMetrics
lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
if [[ "$lidarrReleaseContainsCommentary" == "false" ]]; then
    echo "✅ PASS: Commentary detection negative 3"
    ((pass++))
else
    echo "❌ FAIL: Commentary detection negative 3"
    ((fail++))
fi

# Test 12: Commentary detection negative 4
reset_state
setup_state "oak street" "elm street" "13" "16" "1999" "2002" "{\"media\":[{\"tracks\": [{\"title\": \"Overture\"},{\"title\": \"Overture (reprise)\"},{\"title\": \"Overture (remix)\"}]}]}"
ComputePrimaryMatchMetrics
lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
if [[ "$lidarrReleaseContainsCommentary" == "false" ]]; then
    echo "✅ PASS: Commentary detection negative 4"
    ((pass++))
else
    echo "❌ FAIL: Commentary detection negative 4"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
