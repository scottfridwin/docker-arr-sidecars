#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/utilities.sh"
source "${SCRIPT_DIR}/../services/functions.bash"

#### Mocks ####
log() {
    : # Do nothing, suppress logs in tests
}

# Helper to setup default state for the test
setup_default_state() {
    reset_state
    set_state "lidarrReleaseLinkedDeezerAlbumId" "someId2"
    set_state "lidarrReleaseStatus" "Official"
    set_state "bestMatchDisambiguationRarities" "false"
    set_state "lidarrReleaseDisambiguationRarities" "false"
    set_state "bestMatchContainsCommentary" "false"
    set_state "lidarrReleaseContainsCommentary" "false"
    set_state "lidarrReleaseIsInstrumental" "false"
    set_state "exactMatchFound" "false"

    export AUDIO_IGNORE_INSTRUMENTAL_RELEASES="true"
    export AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES="true"
    export AUDIO_REQUIRE_MUSICBRAINZ_REL="true"
}

# Helper to setup exact match state for the test
setup_exact_match_state() {
    setup_default_state
    # Disable automatic skip for missing deezer link
    export AUDIO_REQUIRE_MUSICBRAINZ_REL="false"

    set_state "lidarrReleaseLinkedDeezerAlbumId" ""
    set_state "lidarrReleaseStatus" "Official"
    set_state "bestMatchDisambiguationRarities" "false"
    set_state "lidarrReleaseDisambiguationRarities" "false"
    set_state "bestMatchContainsCommentary" "false"
    set_state "lidarrReleaseContainsCommentary" "false"
    set_state "lidarrReleaseIsInstrumental" "false"
    set_state "exactMatchFound" "true"
    set_state "bestMatchLidarrReleaseLinkedDeezerAlbumId" ""
    set_state "bestMatchCountryPriority" "3"
    set_state "lidarrReleaseCountryPriority" "3"
    set_state "bestMatchNumTracks" "10"
    set_state "lidarrReleaseTrackCount" "10"
    set_state "bestMatchFormatPriority" "3"
    set_state "lidarrReleaseFormatPriority" "3"
    set_state "bestMatchReleaseLyricTypePreferred" "false"
    set_state "lidarrReleaseLyricTypePreferred" "false"
    set_state "bestMatchTiebreakerCountryPriority" "3"
    set_state "lidarrReleaseTiebreakerCountryPriority" "3"
    set_state "bestMatchTitleWithDisambiguation" "Album Title (Deluxe Edition)"
    set_state "lidarrReleaseTitleWithReleaseDisambiguation" "Album Title (Deluxe Edition)"
    set_state "bestMatchLidarrReleaseForeignId" "mbid1"
    set_state "lidarrReleaseForeignId" "mbid1"
}

run_test() {
    local testName="$1"
    local expected_skip="$2"

    if SkipReleaseCandidate; then
        if [[ "$expected_skip" == "true" ]]; then
            echo "✅ PASS: $testName -> Skip"
            ((pass++))
        else
            echo "❌ FAIL: '$testName' should not skip"
            ((fail++))
        fi
    else
        if [[ "$expected_skip" == "false" ]]; then
            echo "✅ PASS: $testName -> No skip"
            ((pass++))
        else
            echo "❌ FAIL: '$testName' should skip"
            ((fail++))
        fi
    fi
}

pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 01: Default -> No skip
setup_default_state
run_test "Default" "false"

# Test 02: No Deezer link -> Skip
setup_default_state
set_state "lidarrReleaseLinkedDeezerAlbumId" ""
run_test "No Deezer link" "true"

# Test 03: Don't require Deezer link -> No skip
setup_default_state
set_state "lidarrReleaseLinkedDeezerAlbumId" ""
export AUDIO_REQUIRE_MUSICBRAINZ_REL="false"
run_test "Don't require Deezer link" "false"

# Test 04: Non-official status -> Skip
setup_default_state
set_state "lidarrReleaseStatus" "Promotion"
run_test "Non-official status" "true"

# Test 05: Current disambiguation rarities -> Skip
setup_default_state
set_state "lidarrReleaseDisambiguationRarities" "true"
run_test "Current disambiguation rarities" "true"

# Test 06: Best disambiguation rarities -> No skip
setup_default_state
set_state "bestMatchDisambiguationRarities" "true"
run_test "Best disambiguation rarities" "false"

# Test 07: Current commentary -> Skip
setup_default_state
set_state "lidarrReleaseContainsCommentary" "true"
run_test "Current commentary" "true"

# Test 08: Best commentary -> No skip
setup_default_state
set_state "bestMatchContainsCommentary" "true"
run_test "Best commentary" "false"

# Test 09: Don't deprioritize commentary -> No skip
setup_default_state
set_state "lidarrReleaseContainsCommentary" "true"
export AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES="false"
run_test "Don't deprioritize commentary" "false"

# Test 10: Current instrumental -> Skip
setup_default_state
set_state "lidarrReleaseIsInstrumental" "true"
run_test "Current instrumental" "true"

# Test 11: Best instrumental -> No skip
setup_default_state
set_state "bestMatchIsInstrumental" "true"
run_test "Best instrumental" "false"

# Test 12: Don't ignore instrumental -> No skip
setup_default_state
set_state "lidarrReleaseIsInstrumental" "true"
export AUDIO_IGNORE_INSTRUMENTAL_RELEASES="false"
run_test "Don't ignore instrumental" "false"

# Test 13: Exact match found -> Skip
setup_exact_match_state
run_test "Exact match found" "true"

# Test 14: Current Deezer link -> No skip
setup_exact_match_state
set_state "lidarrReleaseLinkedDeezerAlbumId" "someId2"
run_test "Current Deezer link" "false"

# Test 15: Best Deezer link -> Skip
setup_exact_match_state
set_state "bestMatchLidarrReleaseLinkedDeezerAlbumId" "someId2"
run_test "Best Deezer link" "true"

# Test 16: Better country priority -> No skip
setup_exact_match_state
set_state "lidarrReleaseCountryPriority" "2"
run_test "Better country priority" "false"

# Test 17: Worse country priority -> Skip
setup_exact_match_state
set_state "lidarrReleaseCountryPriority" "4"
run_test "Worse country priority" "true"

# Test 18: Non-numeric country priority -> No skip
setup_exact_match_state
set_state "lidarrReleaseCountryPriority" "abc"
run_test "Non-numeric country priority" "false"

# Test 19: Non-numeric best country priority -> No skip
setup_exact_match_state
set_state "bestMatchCountryPriority" "abc"
run_test "Non-numeric best country priority" "false"

# Test 20: Better track count -> No skip
setup_exact_match_state
set_state "lidarrReleaseTrackCount" "12"
run_test "Better track count" "false"

# Test 21: Worse track count -> Skip
setup_exact_match_state
set_state "lidarrReleaseTrackCount" "8"
run_test "Worse track count" "true"

# Test 22: Non-numeric track count -> No skip
setup_exact_match_state
set_state "lidarrReleaseTrackCount" "abc"
run_test "Non-numeric track count" "false"

# Test 23: Non-numeric best track count -> No skip
setup_exact_match_state
set_state "bestMatchNumTracks" "abc"
run_test "Non-numeric best track count" "false"

# Test 24: Better format priority -> No skip
setup_exact_match_state
set_state "lidarrReleaseFormatPriority" "2"
run_test "Better format priority" "false"

# Test 25: Worse format priority -> Skip
setup_exact_match_state
set_state "lidarrReleaseFormatPriority" "4"
run_test "Worse format priority" "true"

# Test 26: Non-numeric format priority -> No skip
setup_exact_match_state
set_state "lidarrReleaseFormatPriority" "abc"
run_test "Non-numeric format priority" "false"

# Test 27: Non-numeric best format priority -> No skip
setup_exact_match_state
set_state "bestMatchFormatPriority" "abc"
run_test "Non-numeric best format priority" "false"

# Test 28: Better lyric type preferred -> No skip
setup_exact_match_state
set_state "lidarrReleaseLyricTypePreferred" "true"
run_test "Better lyric type preferred" "false"

# Test 29: Worse lyric type preferred -> Skip
setup_exact_match_state
set_state "lidarrReleaseLyricTypePreferred" "false"
run_test "Worse lyric type preferred" "true"

# Test 30: Better tiebreaker country priority -> No skip
setup_exact_match_state
set_state "lidarrReleaseTiebreakerCountryPriority" "2"
run_test "Better tiebreaker country priority" "false"

# Test 31: Worse tiebreaker country priority -> Skip
setup_exact_match_state
set_state "lidarrReleaseTiebreakerCountryPriority" "4"
run_test "Worse tiebreaker country priority" "true"

# Test 32: Non-numeric tiebreaker country priority -> No skip
setup_exact_match_state
set_state "lidarrReleaseTiebreakerCountryPriority" "abc"
run_test "Non-numeric tiebreaker country priority" "false"

# Test 33: Non-numeric best tiebreaker country priority -> No skip
setup_exact_match_state
set_state "bestMatchTiebreakerCountryPriority" "abc"
run_test "Non-numeric best tiebreaker country priority" "false"

# Test 34: Better title with disambiguation -> No skip
setup_exact_match_state
set_state "lidarrReleaseTitleWithReleaseDisambiguation" "Album Title (Deluxe Edition) [Remastered]"
run_test "Better title with disambiguation" "false"

# Test 35: Worse title with disambiguation -> Skip
setup_exact_match_state
set_state "lidarrReleaseTitleWithReleaseDisambiguation" "Album Title"
run_test "Worse title with disambiguation" "true"

# Test 36: Better foreign ID -> No skip
setup_exact_match_state
set_state "lidarrReleaseForeignId" "mbid0"
run_test "Better foreign ID" "false"

# Test 37: Worse foreign ID -> Skip
setup_exact_match_state
set_state "lidarrReleaseForeignId" "mbid1"
run_test "Worse foreign ID" "true"

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
