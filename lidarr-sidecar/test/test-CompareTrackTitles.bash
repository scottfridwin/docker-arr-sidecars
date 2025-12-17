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

# Helper to execute a test
run_test() {
    local testName="$1"
    local -n local_lidarr_tracks="$2"
    local -n local_deezer_tracks="$3"
    local expected_Total="$4"
    local expected_Average="$5"
    local expected_Max="$6"
    local matchDeezerId="$7"
    local matchLidarrId="$8"

    set_state "candidateTrackNameDiffAvg" "unset"
    set_state "candidateTrackNameDiffTotal" "unset"
    set_state "candidateTrackNameDiffMax" "unset"

    set_state "trackCompareDeezerID" "deezerId"
    set_state "trackCompareLidarrID" "lidarrId"
    if [[ "$matchDeezerId" == "true" ]]; then
        set_state "deezerCandidateAlbumID" "deezerId"
    fi
    if [[ "$matchLidarrId" == "true" ]]; then
        set_state "lidarrReleaseForeignId" "lidarrId"
    fi

    set_state "lidarrReleaseTrackTitles" "$(printf "%s${TRACK_SEP}" "${local_lidarr_tracks[@]}")"
    set_state "deezerCandidateTrackTitles" "$(printf "%s${TRACK_SEP}" "${local_deezer_tracks[@]}")"

    CompareTrackTitles

    if [[ "$(get_state "candidateTrackNameDiffTotal")" == "$expected_Total" ]] &&
        [[ "$(get_state "candidateTrackNameDiffAvg")" == "$expected_Average" ]] &&
        [[ "$(get_state "candidateTrackNameDiffMax")" == "$expected_Max" ]]; then
        echo "✅ PASS: $testName"
        ((pass++))
    else
        echo "❌ FAIL: $testName"
        echo "  candidateTrackNameDiffTotal: '$(get_state "candidateTrackNameDiffTotal")'"
        echo "  candidateTrackNameDiffAvg: '$(get_state "candidateTrackNameDiffAvg")'"
        echo "  candidateTrackNameDiffMax: '$(get_state "candidateTrackNameDiffMax")'"
        ((fail++))
    fi
}

# --- Run tests ---
pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 1: Single track exact match
reset_state
lidarr_tracks=(
    "Overture"
)
deezer_tracks=(
    "Overture"
)
run_test "Single track exact match" lidarr_tracks deezer_tracks "0" "0.00" "0" "false" "false"

# Test 2: Single track almost match
reset_state
lidarr_tracks=(
    "Overture"
)
deezer_tracks=(
    "AvertuKe"
)
run_test "Single track almost match" lidarr_tracks deezer_tracks "2" "2.00" "2" "false" "false"

# Test 3: Two tracks exact match
reset_state
lidarr_tracks=(
    "Overture"
    "Movement I"
)
deezer_tracks=(
    "Overture"
    "Movement I"
)
run_test "Two tracks exact match" lidarr_tracks deezer_tracks "0" "0.00" "0" "false" "false"

# Test 4: Two tracks almost match
reset_state
lidarr_tracks=(
    "Overture"
    "Movemena I"
)
deezer_tracks=(
    "Overture"
    "Movement I"
)
run_test "Two tracks almost match" lidarr_tracks deezer_tracks "1" "0.50" "1" "false" "false"

# Test 5: Track missing in Deezer (unequal lengths)
reset_state
lidarr_tracks=(
    "Overture"
    "Movement I"
)
deezer_tracks=(
    "Overture"
)
run_test "Deezer missing track" lidarr_tracks deezer_tracks "999" "999.00" "999" "false" "false"

# Test 6: Track missing in Lidarr (unequal lengths)
reset_state
lidarr_tracks=(
    "Overture"
)
deezer_tracks=(
    "Overture"
    "Movement I"
)
run_test "Lidarr missing track" lidarr_tracks deezer_tracks "999" "999.00" "999" "false" "false"

# Test 7: Empty tracks
reset_state
lidarr_tracks=()
deezer_tracks=()
run_test "Empty track lists" lidarr_tracks deezer_tracks "0" "0.00" "0" "false" "false"

# Test 8: All tracks different
reset_state
lidarr_tracks=(
    "Intro"
    "Verse"
    "Chorus"
)
deezer_tracks=(
    "Outro"
    "Bridge"
    "Finale"
)
run_test "Completely different tracks" lidarr_tracks deezer_tracks "13" "4.33" "6" "false" "false"

# Test 9: Off-by-one matches (shifting positions)
reset_state
lidarr_tracks=(
    "Intro"
    "Verse"
    "Chorus"
)
deezer_tracks=(
    "Verse"
    "Chorus"
    "Outro"
)
run_test "Off-by-one track positions" lidarr_tracks deezer_tracks "15" "5.00" "5" "false" "false"

# Test 10: Mixed exact and almost matches
reset_state
lidarr_tracks=(
    "Overture"
    "Movement I"
    "Movement II"
)
deezer_tracks=(
    "Overture"
    "Movment I"
    "Movement II"
)
run_test "Mixed exact and almost matches" lidarr_tracks deezer_tracks "1" "0.33" "1" "false" "false"

# Test 11: Tracks with different casing and punctuation
reset_state
lidarr_tracks=(
    "Overture!"
    "Movement I"
)
deezer_tracks=(
    "overture"
    "Movement I."
)
run_test "Case and punctuation differences" lidarr_tracks deezer_tracks "2" "1.00" "1" "false" "false"

# Test 12: Longer album with multiple differences
reset_state
lidarr_tracks=(
    "Track 1"
    "Track 2"
    "Track 3"
    "Track 4"
    "Track 5"
)
deezer_tracks=(
    "Track One"
    "Track Two"
    "Track Three"
    "Track Four"
    "Track Five"
)
run_test "Long album with multiple small diffs" lidarr_tracks deezer_tracks "19" "3.80" "5" "false" "false"

# Test 13: Very long track name
reset_state
lidarr_tracks=("This is a very long track name with multiple words 123456")
deezer_tracks=("This is a very long track name with multiple words 12345")
run_test "Long track names off by one char" lidarr_tracks deezer_tracks "1" "1.00" "1" "false" "false"

# Test 14: Unicode / accented characters
reset_state
lidarr_tracks=("Café del Mar" "L'été")
deezer_tracks=("Cafe del Mar" "Lete")
run_test "Unicode / accented characters" lidarr_tracks deezer_tracks "4" "2.00" "3" "false" "false"

# Test 15: Longer album with one mix-matched track
reset_state
lidarr_tracks=(
    "Track 1"
    "Track 2"
    "Track 3"
    "Track 4"
    "Track 5"
)
deezer_tracks=(
    "Track 1"
    "Track 2"
    "Don't Stop Me Now"
    "Track 4"
    "Track 5"
)
run_test "Longer album with one mix-matched track" lidarr_tracks deezer_tracks "16" "3.20" "16" "false" "false"

# Test 16: Real Example 1
reset_state
lidarr_tracks=(
    "She Looks So Perfect"
    "Don't Stop"
    "Good Girls"
    "Kiss Me Kiss Me"
    "18"
    "Everything I Didn't Say"
    "Beside You"
    "End Up Here"
    "Long Way Home"
    "Heartbreak Girl"
    "Mrs All American"
    "Amnesia"
    "Social Casualty"
    "Never Be"
    "Voodoo Doll"
)
deezer_tracks=(
    "She Looks So Perfect"
    "Don’t Stop"
    "Good Girls"
    "Kiss Me Kiss Me"
    "18"
    "Everything I Didn’t Say"
    "Beside You"
    "End Up Here"
    "Long Way Home"
    "Heartbreak Girl"
    "English Love Affair"
    "Amnesia"
    "Social Casualty"
    "Never Be"
    "Voodoo Doll"
)
run_test "Real Example 1" lidarr_tracks deezer_tracks "16" "1.07" "16" "false" "false"

# Test 17: Same Deezer Id
reset_state
lidarr_tracks=(
    "Overture"
)
deezer_tracks=(
    "Overture"
)
run_test "Same Deezer Id" lidarr_tracks deezer_tracks "0" "0.00" "0" "true" "false"

# Test 18: Same Lidarr Id
reset_state
lidarr_tracks=(
    "Overture"
)
deezer_tracks=(
    "Overture"
)
run_test "Same Lidarr Id" lidarr_tracks deezer_tracks "0" "0.00" "0" "false" "true"

# Test 19: Same both Ids
reset_state
lidarr_tracks=(
    "Overture"
)
deezer_tracks=(
    "Overture"
)
run_test "Same both Ids" lidarr_tracks deezer_tracks "unset" "unset" "unset" "true" "true"

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
