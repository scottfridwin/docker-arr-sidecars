#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/utilities.sh"
source "${SCRIPT_DIR}/../services/functions.bash"

#### Constants ####

AUDIO_MATCH_THRESHOLD_TITLE=5
AUDIO_MATCH_THRESHOLD_TRACKS=3
AUDIO_MATCH_THRESHOLD_YEAR=1

#### Mocks ####
log() {
    : # Do nothing, suppress logs in tests
}
ComputePrimaryMatchMetrics() {
    set_state "MOCK_ComputePrimaryMatchMetrics" "true"
}

IsBetterMatch() {
    set_state "MOCK_IsBetterMatch" "true"
    return $(get_state "MOCK_IsBetterMatch_Ret")
}

AlbumPreviouslyFailed() {
    local albumID="$1"
    set_state "MOCK_AlbumPreviouslyFailed" "true"
    set_state "MOCK_AlbumPreviouslyFailed_Val1" "$1"
    return $(get_state "MOCK_AlbumPreviouslyFailed_Ret")
}

UpdateBestMatchState() {
    set_state "MOCK_UpdateBestMatchState" "true"
}

# Helper to setup state for the test
setup_state() {
    set_state "MOCK_ComputePrimaryMatchMetrics" "false"
    set_state "MOCK_IsBetterMatch" "false"
    set_state "MOCK_AlbumPreviouslyFailed" "false"
    set_state "MOCK_AlbumPreviouslyFailed_Val1" "unset"
    set_state "MOCK_UpdateBestMatchState" "false"
    set_state "candidateNameDiff" "${1}"
    set_state "candidateTrackDiff" "${2}"
    set_state "candidateYearDiff" "${3}"
    set_state "deezerCandidateTitleVariant" "${4}"
    set_state "lidarrReleaseYear" "${5}"
    set_state "deezerCandidateAlbumID" "${6}"
    set_state "MOCK_IsBetterMatch_Ret" "${7}"
    set_state "MOCK_AlbumPreviouslyFailed_Ret" "${8}"
}

# Helper to execute a test
run_test() {
    local testName="$1"
    local expected_ComputePrimaryMatchMetrics="$2"
    local expected_IsBetterMatch="$3"
    local expected_AlbumPreviouslyFailed="$4"
    local expected_AlbumPreviouslyFailed_Val1="$5"
    local expected_UpdateBestMatchState="$6"

    EvaluateTitleVariant

    MOCK_ComputePrimaryMatchMetrics=$(get_state "MOCK_ComputePrimaryMatchMetrics")
    MOCK_IsBetterMatch=$(get_state "MOCK_IsBetterMatch")
    MOCK_AlbumPreviouslyFailed=$(get_state "MOCK_AlbumPreviouslyFailed")
    MOCK_AlbumPreviouslyFailed_Val1=$(get_state "MOCK_AlbumPreviouslyFailed_Val1")
    MOCK_UpdateBestMatchState=$(get_state "MOCK_UpdateBestMatchState")
    if [[ "${MOCK_ComputePrimaryMatchMetrics}" == "${expected_ComputePrimaryMatchMetrics}" ]] &&
        [[ "${MOCK_IsBetterMatch}" == "${expected_IsBetterMatch}" ]] &&
        [[ "${MOCK_AlbumPreviouslyFailed}" == "${expected_AlbumPreviouslyFailed}" ]] &&
        [[ "${MOCK_AlbumPreviouslyFailed_Val1}" == "${expected_AlbumPreviouslyFailed_Val1}" ]] &&
        [[ "${MOCK_UpdateBestMatchState}" == "${expected_UpdateBestMatchState}" ]]; then
        echo "✅ PASS: $testName"
        ((pass++))
    else
        echo "❌ FAIL: $testName"
        echo "    MOCK_ComputePrimaryMatchMetrics=$MOCK_ComputePrimaryMatchMetrics (expected $expected_ComputePrimaryMatchMetrics)"
        echo "    MOCK_IsBetterMatch=$MOCK_IsBetterMatch (expected $expected_IsBetterMatch)"
        echo "    MOCK_AlbumPreviouslyFailed=$MOCK_AlbumPreviouslyFailed (expected $expected_AlbumPreviouslyFailed)"
        echo "    MOCK_AlbumPreviouslyFailed_Val1=$MOCK_AlbumPreviouslyFailed_Val1 (expected $expected_AlbumPreviouslyFailed_Val1)"
        echo "    MOCK_UpdateBestMatchState=$MOCK_UpdateBestMatchState (expected $expected_UpdateBestMatchState)"
        ((fail++))
    fi
}

pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 01: Skipped due to name diff
reset_state
testName="NameDiff"
setup_state 6 0 0 "title" "2001" "12345" "0" "1"
run_test "NameDiff" "true" "false" "false" "unset" "false"

# Test 02: Skipped due to track diff
reset_state
setup_state 5 4 0 "title" "2001" "12345" "0" "1"
run_test "TrackDiff" "true" "false" "false" "unset" "false"

# Test 03: Skipped due to year diff
reset_state
setup_state 5 3 2 "title" "2001" "12345" "0" "1"
run_test "YearDiff" "true" "false" "false" "unset" "false"

# Test 04: Not better match
reset_state
setup_state 5 3 1 "title" "2001" "12345" "1" "1"
run_test "WorseMatch" "true" "true" "false" "unset" "false"

# Test 05: Better match, previously failed
reset_state
setup_state 5 3 1 "title" "2001" "12345" "0" "0"
run_test "PreviouslyFailed" "true" "true" "true" "12345" "false"

# Test 06: Better match, not previously failed
reset_state
setup_state 5 3 1 "title" "2001" "12345" "0" "1"
run_test "PreviouslyFailed" "true" "true" "true" "12345" "true"
