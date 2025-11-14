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

# Test 1: Extract basic album info with valid date
reset_state
album_json='{
  "title": "2048",
  "albumType": "Album",
  "foreignAlbumId": "d4e5f6a7-b8c9-4567-89ab-cdef01234567",
  "disambiguation": "Sailors Version",
  "releaseDate": "2014-10-27T00:00:00Z"
}'

ExtractAlbumInfo "$album_json"

if [[ "$(get_state "lidarrAlbumTitle")" == "2048" ]] &&
    [[ "$(get_state "lidarrAlbumType")" == "Album" ]] &&
    [[ "$(get_state "lidarrAlbumForeignAlbumId")" == "d4e5f6a7-b8c9-4567-89ab-cdef01234567" ]] &&
    [[ "$(get_state "lidarrAlbumDisambiguation")" == "Sailors Version" ]] &&
    [[ "$(get_state "lidarrAlbumReleaseYear")" == "2014" ]] &&
    [[ "$(get_state "lidarrAlbumReleaseDateClean")" == "20141027" ]]; then
    echo "✅ PASS: Extract basic album info with valid date"
    ((pass++))
else
    echo "❌ FAIL: Extract basic album info with valid date"
    echo "  title: '$(get_state "lidarrAlbumTitle")'"
    echo "  releaseYear: '$(get_state "lidarrAlbumReleaseYear")'"
    echo "  releaseDateClean: '$(get_state "lidarrAlbumReleaseDateClean")'"
    ((fail++))
fi

# Test 2: Album without disambiguation
reset_state
album_json='{
  "title": "Maple Street",
  "albumType": "Album",
  "foreignAlbumId": "e5f6a7b8-c9d0-5678-9abc-def012345678",
  "disambiguation": null,
  "releaseDate": "1969-09-26T00:00:00Z"
}'

ExtractAlbumInfo "$album_json"

if [[ "$(get_state "lidarrAlbumTitle")" == "Maple Street" ]] &&
    [[ "$(get_state "lidarrAlbumDisambiguation")" == "" ]] &&
    [[ "$(get_state "lidarrAlbumReleaseYear")" == "1969" ]]; then
    echo "✅ PASS: Album without disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Album without disambiguation"
    ((fail++))
fi

# Test 3: Album with EP type
reset_state
album_json='{
  "title": "Storybook: The Short Lake Studio Sessions",
  "albumType": "EP",
  "foreignAlbumId": "f6a7b8c9-d0e1-6789-abcd-ef0123456789",
  "disambiguation": "Live from Short Lake Studio",
  "releaseDate": "2020-11-25T00:00:00Z"
}'

ExtractAlbumInfo "$album_json"

if [[ "$(get_state "lidarrAlbumType")" == "EP" ]] &&
    [[ "$(get_state "lidarrAlbumDisambiguation")" == "Live from Short Lake Studio" ]]; then
    echo "✅ PASS: Album with EP type"
    ((pass++))
else
    echo "❌ FAIL: Album with EP type"
    ((fail++))
fi

# Test 4: Album with null release date
reset_state
album_json='{
  "title": "Unreleased Album",
  "albumType": "Album",
  "foreignAlbumId": "null-date-test-1234-5678-90ab",
  "disambiguation": "",
  "releaseDate": null
}'

ExtractAlbumInfo "$album_json"

if [[ "$(get_state "lidarrAlbumReleaseYear")" == "" ]]; then
    echo "✅ PASS: Album with null release date"
    ((pass++))
else
    echo "❌ FAIL: Album with null release date (got year '$(get_state "lidarrAlbumReleaseYear")')"
    ((fail++))
fi

# Test 5: Verify JSON stored correctly
reset_state
album_json='{"title":"Test Album","albumType":"Album","foreignAlbumId":"test-123","disambiguation":"test","releaseDate":"2020-01-01T00:00:00Z"}'

ExtractAlbumInfo "$album_json"

stored_json="$(get_state "lidarrAlbumInfo")"
if [[ "$stored_json" == "$album_json" ]]; then
    echo "✅ PASS: JSON stored correctly"
    ((pass++))
else
    echo "❌ FAIL: JSON not stored correctly"
    ((fail++))
fi

# Test 6: Date cleaning works correctly
reset_state
album_json='{
  "title": "Date Test",
  "albumType": "Album",
  "foreignAlbumId": "date-test-1234",
  "disambiguation": "",
  "releaseDate": "2023-12-25T12:34:56Z"
}'

ExtractAlbumInfo "$album_json"

if [[ "$(get_state "lidarrAlbumReleaseDateClean")" == "20231225" ]]; then
    echo "✅ PASS: Date cleaning works correctly"
    ((pass++))
else
    echo "❌ FAIL: Date cleaning (got '$(get_state "lidarrAlbumReleaseDateClean")')"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
