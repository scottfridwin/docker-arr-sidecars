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
FetchMusicBrainzReleaseInfo() {
    set_state "Mock_FetchMusicBrainzReleaseInfo" "true"
}
# Mock environment variables
export AUDIO_PREFERRED_FORMATS="CD,Vinyl,Digital"
export AUDIO_PREFERRED_COUNTRIES="US,UK,JP"

# --- Run tests ---
pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 1: Extract basic release info
reset_state
release_json='{
  "title": "2048",
  "disambiguation": "Deluxe Edition",
  "trackCount": 13,
  "foreignReleaseId": "abc123-def456",
  "format": "CD",
  "country": ["US"],
  "releaseDate": "2014-10-27T00:00:00Z"
}'

ExtractReleaseInfo "$release_json"

if [[ "$(get_state "lidarrReleaseTitle")" == "2048" ]] &&
    [[ "$(get_state "lidarrReleaseDisambiguation")" == "Deluxe Edition" ]] &&
    [[ "$(get_state "lidarrReleaseTrackCount")" == "13" ]] &&
    [[ "$(get_state "lidarrReleaseForeignId")" == "abc123-def456" ]] &&
    [[ "$(get_state "lidarrReleaseYear")" == "2014" ]]; then
    echo "✅ PASS: Extract basic release info"
    ((pass++))
else
    echo "❌ FAIL: Extract basic release info"
    echo "  title: '$(get_state "lidarrReleaseTitle")'"
    echo "  trackCount: '$(get_state "lidarrReleaseTrackCount")'"
    echo "  year: '$(get_state "lidarrReleaseYear")'"
    ((fail++))
fi

# Test 2: Format priority calculation
reset_state
release_json='{
  "title": "Test Album",
  "disambiguation": "",
  "trackCount": 10,
  "foreignReleaseId": "test-123",
  "format": "Vinyl",
  "country": ["UK"],
  "releaseDate": "2020-01-01T00:00:00Z"
}'

ExtractReleaseInfo "$release_json"

if [[ "$(get_state "lidarrReleaseFormatPriority")" == "1" ]]; then
    echo "✅ PASS: Format priority calculation (Vinyl=1)"
    ((pass++))
else
    echo "❌ FAIL: Format priority (got '$(get_state "lidarrReleaseFormatPriority")')"
    ((fail++))
fi

# Test 3: Country priority calculation
reset_state
release_json='{
  "title": "Test Album",
  "disambiguation": "",
  "trackCount": 10,
  "foreignReleaseId": "test-456",
  "format": "CD",
  "country": ["JP"],
  "releaseDate": "2020-01-01T00:00:00Z"
}'

ExtractReleaseInfo "$release_json"

if [[ "$(get_state "lidarrReleaseCountryPriority")" == "2" ]]; then
    echo "✅ PASS: Country priority calculation (JP=2)"
    ((pass++))
else
    echo "❌ FAIL: Country priority (got '$(get_state "lidarrReleaseCountryPriority")')"
    ((fail++))
fi

# Test 4: Release without disambiguation
reset_state
release_json='{
  "title": "Maple Street",
  "disambiguation": null,
  "trackCount": 17,
  "foreignReleaseId": "beetles-ar-001",
  "format": "CD",
  "country": ["US"],
  "releaseDate": "1969-09-26T00:00:00Z"
}'

ExtractReleaseInfo "$release_json"

if [[ "$(get_state "lidarrReleaseDisambiguation")" == "" ]]; then
    echo "✅ PASS: Release without disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Release without disambiguation"
    ((fail++))
fi

# Test 5: Release with null date checks musicbrainz date
reset_state
set_state "lidarrAlbumReleaseYear" "2015"
set_state "musicbrainzReleaseJson" "{ \"date\":\"2000\" }"
release_json='{
  "title": "Test Release",
  "disambiguation": "",
  "trackCount": 12,
  "foreignReleaseId": "test-789",
  "format": "Digital",
  "country": ["US"],
  "releaseDate": null
}'

ExtractReleaseInfo "$release_json"

Mock_FetchMusicBrainzReleaseInfo=$(get_state "Mock_FetchMusicBrainzReleaseInfo")
if [[ "$(get_state "lidarrReleaseYear")" == "2000" ]] &&
    [[ "$Mock_FetchMusicBrainzReleaseInfo" == "true" ]]; then
    echo "✅ PASS: Release year falls back to musicbrainz year"
    ((pass++))
else
    echo "❌ FAIL: Release year fallback (got '$(get_state "lidarrReleaseYear")')"
    ((fail++))
fi

# Test 6: Release with null date falls back to album year
reset_state
set_state "lidarrAlbumReleaseYear" "2015"
set_state "musicbrainzReleaseJson" "{ }"
release_json='{
  "title": "Test Release",
  "disambiguation": "",
  "trackCount": 12,
  "foreignReleaseId": "test-789",
  "format": "Digital",
  "country": ["US"],
  "releaseDate": null
}'

ExtractReleaseInfo "$release_json"

Mock_FetchMusicBrainzReleaseInfo=$(get_state "Mock_FetchMusicBrainzReleaseInfo")
if [[ "$(get_state "lidarrReleaseYear")" == "2015" ]] &&
    [[ "$Mock_FetchMusicBrainzReleaseInfo" == "true" ]]; then
    echo "✅ PASS: Release year falls back to album year"
    ((pass++))
else
    echo "❌ FAIL: Release year fallback (got '$(get_state "lidarrReleaseYear")')"
    ((fail++))
fi

# Test 7: Verify JSON stored correctly
reset_state
release_json='{"title":"Test","disambiguation":"","trackCount":5,"foreignReleaseId":"id","format":"CD","country":["US"],"releaseDate":"2020-01-01T00:00:00Z"}'

ExtractReleaseInfo "$release_json"

if [[ "$(get_state "lidarrReleaseInfo")" == "$release_json" ]]; then
    echo "✅ PASS: JSON stored correctly"
    ((pass++))
else
    echo "❌ FAIL: JSON not stored correctly"
    ((fail++))
fi

# Test 8: Unknown format gets low priority
reset_state
release_json='{
  "title": "Test",
  "disambiguation": "",
  "trackCount": 8,
  "foreignReleaseId": "test-cassette",
  "format": "Cassette",
  "country": ["US"],
  "releaseDate": "1990-01-01T00:00:00Z"
}'

ExtractReleaseInfo "$release_json"

if [[ "$(get_state "lidarrReleaseFormatPriority")" == "999" ]]; then
    echo "✅ PASS: Unknown format gets low priority"
    ((pass++))
else
    echo "❌ FAIL: Unknown format priority (got '$(get_state "lidarrReleaseFormatPriority")')"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
