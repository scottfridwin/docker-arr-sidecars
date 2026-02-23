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

    set_state "candidateTrackNameDiffAvg" "unset"
    set_state "candidateTrackNameDiffTotal" "unset"
    set_state "candidateTrackNameDiffMax" "unset"

    set_state "deezerCandidateAlbumID" "deezerId"
    set_state "lidarrReleaseForeignId" "lidarrId"
    set_state "searchReleaseTitleClean" "searchTitle"

    local lidarrReleaseTrackTitlesJson="$(printf '%s\n' "${local_lidarr_tracks[@]}" | jq -R . | jq -s .)"
    set_state "lidarrReleaseTrackTitles" "$lidarrReleaseTrackTitlesJson"
    local deezerCandidateTrackTitlesJson="$(printf '%s\n' "${local_deezer_tracks[@]}" | jq -R . | jq -s .)"
    set_state "deezerCandidateTrackTitles" "$deezerCandidateTrackTitlesJson"

    CompareTrackLists

    if [[ "$(get_state "candidateTrackNameDiffTotal")" == "$expected_Total" ]] &&
        [[ "$(get_state "candidateTrackNameDiffAvg")" == "$expected_Average" ]] &&
        [[ "$(get_state "candidateTrackNameDiffMax")" == "$expected_Max" ]] &&
        [[ "$(get_state "trackcache.lidarrId|deezerId.tot")" == "$expected_Total" ]] &&
        [[ "$(get_state "trackcache.lidarrId|deezerId.avg")" == "$expected_Average" ]] &&
        [[ "$(get_state "trackcache.lidarrId|deezerId.max")" == "$expected_Max" ]]; then
        echo "✅ PASS: $testName"
        ((pass++))
    else
        echo "❌ FAIL: $testName"
        echo "  candidateTrackNameDiffTotal: '$(get_state "candidateTrackNameDiffTotal")'"
        echo "  candidateTrackNameDiffAvg: '$(get_state "candidateTrackNameDiffAvg")'"
        echo "  candidateTrackNameDiffMax: '$(get_state "candidateTrackNameDiffMax")'"
        echo "  trackcache.lidarrId|deezerId.tot: '$(get_state "trackcache.lidarrId|deezerId.tot")'"
        echo "  trackcache.lidarrId|deezerId.avg: '$(get_state "trackcache.lidarrId|deezerId.avg")'"
        echo "  trackcache.lidarrId|deezerId.max: '$(get_state "trackcache.lidarrId|deezerId.max")'"
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
run_test "Single track exact match" lidarr_tracks deezer_tracks "0" "0.00" "0"

# Test 2: Single track almost match
reset_state
lidarr_tracks=(
    "Overture"
)
deezer_tracks=(
    "AvertuKe"
)
run_test "Single track almost match" lidarr_tracks deezer_tracks "2" "2.00" "2"

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
run_test "Two tracks exact match" lidarr_tracks deezer_tracks "0" "0.00" "0"

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
run_test "Two tracks almost match" lidarr_tracks deezer_tracks "1" "0.50" "1"

# Test 5: Track missing in Deezer (unequal lengths)
reset_state
lidarr_tracks=(
    "Overture"
    "Movement I"
)
deezer_tracks=(
    "Overture"
)
run_test "Deezer missing track" lidarr_tracks deezer_tracks "999" "999.00" "999"

# Test 6: Track missing in Lidarr (unequal lengths)
reset_state
lidarr_tracks=(
    "Overture"
)
deezer_tracks=(
    "Overture"
    "Movement I"
)
run_test "Lidarr missing track" lidarr_tracks deezer_tracks "999" "999.00" "999"

# Test 7: Empty tracks
reset_state
lidarr_tracks=()
deezer_tracks=()
run_test "Empty track lists" lidarr_tracks deezer_tracks "0" "0.00" "0"

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
run_test "Completely different tracks" lidarr_tracks deezer_tracks "13" "4.33" "6"

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
run_test "Off-by-one track positions" lidarr_tracks deezer_tracks "15" "5.00" "5"

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
run_test "Mixed exact and almost matches" lidarr_tracks deezer_tracks "1" "0.33" "1"

# Test 11: Tracks with different casing and punctuation
# Note: normalize_string removes punctuation, so both become "overture" and "movement i"
reset_state
lidarr_tracks=(
    "Overture!"
    "Movement I"
)
deezer_tracks=(
    "overture"
    "Movement. I"
)
run_test "Case and punctuation differences" lidarr_tracks deezer_tracks "0" "0.00" "0"

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
run_test "Long album with multiple small diffs" lidarr_tracks deezer_tracks "19" "3.80" "5"

# Test 13: Very long track name
reset_state
lidarr_tracks=("This is a very long track name with multiple words 123456")
deezer_tracks=("This is a very long track name with multiple words 12345")
run_test "Long track names off by one char" lidarr_tracks deezer_tracks "1" "1.00" "1"

# Test 14: Unicode / accented characters
# Note: normalize_string handles accents, so "Café" becomes "cafe"
reset_state
lidarr_tracks=("Café del Mar" "L'été")
deezer_tracks=("Cafe del Mar" "Lete")
run_test "Unicode / accented characters" lidarr_tracks deezer_tracks "3" "1.50" "2"

# Test 15: Longer album with one mis-matched track
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
run_test "Longer album with one mis-matched track" lidarr_tracks deezer_tracks "12" "2.40" "12"

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
run_test "Real Example 1" lidarr_tracks deezer_tracks "14" "0.93" "14"

# Test 17: Cache key exists
reset_state
lidarr_tracks=(
    "1234"
    "5678"
)
deezer_tracks=(
    "abcdefg"
)
set_state "trackcache.lidarrId|deezerId.avg" "2.34"
set_state "trackcache.lidarrId|deezerId.tot" "18"
set_state "trackcache.lidarrId|deezerId.max" "6"
run_test "Cache key exists" lidarr_tracks deezer_tracks "18" "2.34" "6"

# Test 18: Case sensitivity
reset_state
lidarr_tracks=(
    "cAsE seNsItIvItY"
)
deezer_tracks=(
    "Case Sensitivity"
)
run_test "Case sensitivity" lidarr_tracks deezer_tracks "0" "0.00" "0"

# Test 19: Real Example 2
reset_state
lidarr_tracks=(
    "I Forgot That You Existed"
    "Cruel Summer"
    "Lover"
    "The Man"
    "The Archer"
    "I Think He Knows"
    "Miss Americana and the Heartbreak Prince"
    "Paper Rings"
    "Cornelia Street"
    "Death by a Thousand Cuts"
    "London Boy"
    "Soon You'll Get Better"
    "False God"
    "You Need to Calm Down"
    "Afterglow"
    "ME"
    "It's Nice to Have a Friend"
    "Daylight"
)
deezer_tracks=(
    "I Forgot That You Existed"
    "Cruel Summer"
    "Lover"
    "The Man"
    "The Archer"
    "I Think He Knows"
    "Miss Americana and the Heartbreak Prince"
    "Paper Rings"
    "Cornelia Street"
    "Death by a Thousand Cuts"
    "London Boy"
    "Soon You'll Get Better"
    "False God"
    "You Need to Calm Down"
    "Afterglow"
    "ME feat. Brendon Urie of Panic At The Disco"
    "It's Nice To Have A Friend"
    "Daylight"
)
run_test "Real Example 2" lidarr_tracks deezer_tracks "0" "0.00" "0"

# Test 20: Album title stripping
reset_state
lidarr_tracks=(
    "Main Titles"
    "Overture"
    "Movement I"
    "Movement II"
)
deezer_tracks=(
    "Main Titles - searchTitle"
    "Overture [searchTitle]"
    "Movement I (searchTitle)"
    "Movement II searchTitle"
)
run_test "Album title stripping" lidarr_tracks deezer_tracks "0" "0.00" "0"

# Test 21: Contains check
# Note: After normalization "i'll give it all interlude" vs "interlude" - the substring "interlude" is contained
reset_state
lidarr_tracks=(
    "I'll Give It All interlude"
)
deezer_tracks=(
    "Interlude"
)
run_test "Contains check" lidarr_tracks deezer_tracks "1" "1.00" "1"

# Test 22: Real Example 3
reset_state
lidarr_tracks=(
    "ELECTROSHOCK"
    "NEATFREAK47"
    "DONTDANCE"
    "SAYDEMUP"
    "DRAGONBACKPACK"
    "HOTT"
    "IMNOTCOMINTOYOURPARTYGIRL"
    "HORNZ"
)
deezer_tracks=(
    "Electroshock"
    "Neatfreak47"
    "Don't Dance"
    "Say'dem Up"
    "Dragon Backpack"
    "Hott"
    "I'm Not Comin to Your Party Girl"
    "Hornz"
)
run_test "Real Example 3" lidarr_tracks deezer_tracks "0" "0.00" "0"

# Test 23: Real Example 4
reset_state
lidarr_tracks=(
    "Strangers by Nature"
    "Easy on Me"
    "My Little Love"
    "Cry Your Heart Out"
    "Oh My God"
    "Can I Get It"
    "I Drink Wine"
    "All Night Parking (interlude)"
    "Woman Like Me"
    "Hold On"
    "To Be Loved"
    "Love Is a Game"
)
deezer_tracks=(
    "Strangers by Nature"
    "Easy on Me"
    "My Little Love"
    "Cry Your Heart Out"
    "Oh My God"
    "Can I Get It"
    "I Drink Wine"
    "All Night Parking (with Erroll Garner) Interlude"
    "Woman Like Me"
    "Hold On"
    "To Be Loved"
    "Love Is a Game"
)
run_test "Real Example 4" lidarr_tracks deezer_tracks "0" "0.00" "0"

# Test 24: Real Example 5
reset_state
lidarr_tracks=(
    "Could Have Been Me (live acoustic)"
    "Kiss This (acoustic)"
    "Put Your Money on Me (live acoustic)"
    "Where Did She Go (live acoustic)"
    "I Always Knew / Hotline Bling (live acoustic)"
)
deezer_tracks=(
    "Could Have Been Me (Live / Acoustic)"
    "Kiss This (Acoustic)"
    "Put Your Money On Me (Live / Acoustic)"
    "Where Did She Go (Live / Acoustic)"
    "I Always Knew/Hotline Bling (Live / Acoustic)"
)
run_test "Real Example 5" lidarr_tracks deezer_tracks "0" "0.00" "0"

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
