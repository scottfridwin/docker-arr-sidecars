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
export AUDIO_MATCH_THRESHOLD_TITLE=5

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

# Test 5: Name bypass positive
reset_state
setup_state "oak street" "OAK STREET" "17" "17" "1999" "1999" "{ \"abc\": \"123\" }"
export AUDIO_MATCH_THRESHOLD_TITLE=0
ComputePrimaryMatchMetrics
candidateNameDiff=$(get_state "candidateNameDiff")
candidateTrackDiff=$(get_state "candidateTrackDiff")
candidateYearDiff=$(get_state "candidateYearDiff")
if [[ "$candidateNameDiff" == "0" ]] && [[ "$candidateTrackDiff" == "0" ]] && [[ "$candidateYearDiff" == "0" ]]; then
    echo "✅ PASS: Name bypass positive (candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((pass++))
else
    echo "❌ FAIL: Name bypass positive (got candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((fail++))
fi
export AUDIO_MATCH_THRESHOLD_TITLE=5

# Test 6: Name bypass negative
reset_state
setup_state "oak street" "ELM STREET" "17" "17" "1999" "1999" "{ \"abc\": \"123\" }"
export AUDIO_MATCH_THRESHOLD_TITLE=0
ComputePrimaryMatchMetrics
candidateNameDiff=$(get_state "candidateNameDiff")
candidateTrackDiff=$(get_state "candidateTrackDiff")
candidateYearDiff=$(get_state "candidateYearDiff")
if [[ "$candidateNameDiff" == "999" ]] && [[ "$candidateTrackDiff" == "0" ]] && [[ "$candidateYearDiff" == "0" ]]; then
    echo "✅ PASS: Name bypass negative (candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((pass++))
else
    echo "❌ FAIL: Name bypass negative (got candidateNameDiff=$candidateNameDiff, candidateTrackDiff=$candidateTrackDiff, candidateYearDiff=$candidateYearDiff)"
    ((fail++))
fi
export AUDIO_MATCH_THRESHOLD_TITLE=5

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
