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

# Test 1: Extract basic artist info
reset_state
artist_json='{
  "artistName": "Aurora Lane",
  "foreignArtistId": "a1b2c3d4-e5f6-1234-5678-9abcdef01234"
}'

ExtractArtistInfo "$artist_json"

if [[ "$(get_state "lidarrArtistName")" == "Aurora Lane" ]] &&
    [[ "$(get_state "lidarrArtistForeignArtistId")" == "a1b2c3d4-e5f6-1234-5678-9abcdef01234" ]] &&
    [[ "$(get_state "lidarrArtistInfo")" == "$artist_json" ]]; then
    echo "✅ PASS: Extract basic artist info"
    ((pass++))
else
    echo "❌ FAIL: Extract basic artist info"
    echo "  artistName: '$(get_state "lidarrArtistName")'"
    echo "  foreignArtistId: '$(get_state "lidarrArtistForeignArtistId")'"
    ((fail++))
fi

# Test 2: Extract artist with special characters in name
reset_state
artist_json='{
  "artistName": "Chaos! at the Club",
  "foreignArtistId": "b2c3d4e5-f6a7-2345-6789-abcdef012345"
}'

ExtractArtistInfo "$artist_json"

if [[ "$(get_state "lidarrArtistName")" == "Chaos! at the Club" ]] &&
    [[ "$(get_state "lidarrArtistForeignArtistId")" == "b2c3d4e5-f6a7-2345-6789-abcdef012345" ]]; then
    echo "✅ PASS: Extract artist with special characters"
    ((pass++))
else
    echo "❌ FAIL: Extract artist with special characters"
    ((fail++))
fi

# Test 3: Verify JSON is stored as-is
reset_state
artist_json='{"artistName":"The Vectors","foreignArtistId":"c3d4e5f6-a7b8-3456-789a-bcdef0123456"}'

ExtractArtistInfo "$artist_json"

if [[ "$(get_state "lidarrArtistInfo")" == "$artist_json" ]]; then
    echo "✅ PASS: JSON stored correctly"
    ((pass++))
else
    echo "❌ FAIL: JSON not stored correctly"
    ((fail++))
fi

# Test 4: Various Artists ID
reset_state
artist_json='{
  "artistName": "Various Artists",
  "foreignArtistId": "89ad4ac3-39f7-470e-963a-56509c546377"
}'

ExtractArtistInfo "$artist_json"

if [[ "$(get_state "lidarrArtistName")" == "Various Artists" ]] &&
    [[ "$(get_state "lidarrArtistForeignArtistId")" == "89ad4ac3-39f7-470e-963a-56509c546377" ]]; then
    echo "✅ PASS: Various Artists extraction"
    ((pass++))
else
    echo "❌ FAIL: Various Artists extraction"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
