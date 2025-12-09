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

# Test 1: Identical match
reset_state
set_state "searchReleaseTitleClean" "oak street"
set_state "deezerCandidateTitleVariant" "oak street"
set_state "lidarrReleaseTrackCount" "17"
set_state "deezerCandidateTrackCount" "17"
set_state "lidarrReleaseYear" "1999"
set_state "deezerCandidateReleaseYear" "1999"
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
set_state "searchReleaseTitleClean" "oak street"
set_state "deezerCandidateTitleVariant" "elm street"
set_state "lidarrReleaseTrackCount" "13"
set_state "deezerCandidateTrackCount" "16"
set_state "lidarrReleaseYear" "1999"
set_state "deezerCandidateReleaseYear" "2002"
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
set_state "searchReleaseTitleClean" "oak street"
set_state "deezerCandidateTitleVariant" "green album"
set_state "lidarrReleaseTrackCount" "17"
set_state "deezerCandidateTrackCount" "30"
set_state "lidarrReleaseYear" "1999"
set_state "deezerCandidateReleaseYear" "2015"
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
set_state "searchReleaseTitleClean" "oak street"
set_state "deezerCandidateTitleVariant" "OAK STREET"
set_state "lidarrReleaseTrackCount" "17"
set_state "deezerCandidateTrackCount" "17"
set_state "lidarrReleaseYear" "1999"
set_state "deezerCandidateReleaseYear" "1999"
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

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
