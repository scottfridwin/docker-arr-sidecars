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
reset_state

echo "----------------------------------------------"

# Helper: assert state equals expected
assert_state_eq() {
    local key="$1"
    local expected="$2"
    local actual
    actual="$(get_state "$key")"
    # If values look like JSON, normalize with jq -c before comparing to avoid formatting differences
    if ([[ "$expected" == "["* ]] || [[ "$expected" == "{"* ]] || [[ "$actual" == "["* ]] || [[ "$actual" == "{"* ]]); then
        local expected_canonical actual_canonical
        if expected_canonical=$(jq -c . <<<"$expected" 2>/dev/null) && actual_canonical=$(jq -c . <<<"$actual" 2>/dev/null); then
            if [[ "$actual_canonical" == "$expected_canonical" ]]; then
                ((pass++))
            else
                ((fail++))
            fi
            return
        fi
    fi

    if [[ "$actual" == "$expected" ]]; then
        ((pass++))
    else
        ((fail++))
    fi
}

# Test helpers to emit a single summary line per test
test_begin() {
    test_pass_before=$pass
    test_fail_before=$fail
}

test_end() {
    local name="$1"
    local p=$((pass - test_pass_before))
    local f=$((fail - test_fail_before))
    if ((f == 0)); then
        echo "✅ PASS: ${name} (${p} assertions)"
    else
        echo "❌ FAIL: ${name} (${p} passed, ${f} failed)"
    fi

}

# Test 1: Full release JSON with all fields
reset_state
release_json='{
    "contains_commentary": true,
    "lyric_type_preferred": false,
    "title": "Test Album",
    "disambiguation": "Deluxe",
    "foreign_id": "rid-123",
    "track_count": 2,
    "format_priority": 5,
    "country_priority": 7,
    "tiebreaker_country_priority": 8,
    "year": 1999,
    "recording_titles": ["Rec A", "Rec B"],
    "track_titles": ["Track A", "Track B"],
    "deezer_album_id": 555,
    "release_status": "official",
    "rarities": ["rare"],
    "instrumental": true
}'
test_begin "Full release JSON with all fields"
ExtractReleaseInfo "$release_json"
assert_state_eq "lidarrReleaseContainsCommentary" "true"
assert_state_eq "lidarrReleaseLyricTypePreferred" "false"
assert_state_eq "lidarrReleaseTitle" "Test Album"
assert_state_eq "lidarrReleaseDisambiguation" "Deluxe"
assert_state_eq "lidarrReleaseForeignId" "rid-123"
assert_state_eq "lidarrReleaseTrackCount" "2"
assert_state_eq "lidarrReleaseFormatPriority" "5"
assert_state_eq "lidarrReleaseCountryPriority" "7"
assert_state_eq "lidarrReleaseTiebreakerCountryPriority" "8"
assert_state_eq "lidarrReleaseYear" "1999"
assert_state_eq "lidarrReleaseRecordingTitles" '[
    "Rec A",
    "Rec B"
]'
assert_state_eq "lidarrReleaseTrackTitles" '[
    "Track A",
    "Track B"
]'
assert_state_eq "lidarrReleaseLinkedDeezerAlbumId" "555"
assert_state_eq "lidarrReleaseStatus" "official"
assert_state_eq "lidarrReleaseDisambiguationRarities" '[
    "rare"
]'
assert_state_eq "lidarrReleaseIsInstrumental" "true"
test_end "Full release JSON with all fields"

# Test 2: Minimal release JSON with missing optional fields
reset_state
release_json='{
    "title": "No Disambig Album",
    "foreign_id": "rid-2",
    "track_count": 0,
    "format_priority": 1,
    "country_priority": 1,
    "tiebreaker_country_priority": 1,
    "year": 2021,
    "recording_titles": [],
    "track_titles": []
}'
test_begin "Minimal release JSON with missing optional fields"
ExtractReleaseInfo "$release_json"
assert_state_eq "lidarrReleaseTitle" "No Disambig Album"
assert_state_eq "lidarrReleaseDisambiguation" ""
assert_state_eq "lidarrReleaseForeignId" "rid-2"
assert_state_eq "lidarrReleaseTrackCount" "0"
assert_state_eq "lidarrReleaseFormatPriority" "1"
assert_state_eq "lidarrReleaseCountryPriority" "1"
assert_state_eq "lidarrReleaseTiebreakerCountryPriority" "1"
assert_state_eq "lidarrReleaseYear" "2021"
assert_state_eq "lidarrReleaseRecordingTitles" '[]'
assert_state_eq "lidarrReleaseTrackTitles" '[]'
assert_state_eq "lidarrReleaseLinkedDeezerAlbumId" ""
assert_state_eq "lidarrReleaseStatus" ""
assert_state_eq "lidarrReleaseDisambiguationRarities" ""
assert_state_eq "lidarrReleaseIsInstrumental" ""
test_end "Minimal release JSON with missing optional fields"

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
