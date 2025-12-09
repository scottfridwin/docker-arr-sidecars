#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/utilities.sh"
source "${SCRIPT_DIR}/../services/functions.bash"

#### Mocks ####
log() {
    : # Do nothing, suppress logs in tests
}
# Mock AUDIO_DATA_PATH
export AUDIO_DATA_PATH="/tmp/test-audio-data-$$"
mkdir -p "${AUDIO_DATA_PATH}/failed"

pass=0
fail=0

echo "----------------------------------------------"

# Test 1: Album not previously failed
if ! AlbumPreviouslyFailed "123456"; then
    echo "✅ PASS: Album not previously failed"
    ((pass++))
else
    echo "❌ FAIL: Album not failed (got $result, expected false)"
    ((fail++))
fi

# Test 2: Album previously failed
touch "${AUDIO_DATA_PATH}/failed/789012"
if AlbumPreviouslyFailed "789012"; then
    echo "✅ PASS: Album previously failed"
    ((pass++))
else
    echo "❌ FAIL: Album previously failed (got $result, expected true)"
    ((fail++))
fi

# Test 3: Different album ID
if ! AlbumPreviouslyFailed "999999"; then
    echo "✅ PASS: Different album ID not found"
    ((pass++))
else
    echo "❌ FAIL: Different album (got $result, expected false)"
    ((fail++))
fi

# Test 4: Multiple failed albums
touch "${AUDIO_DATA_PATH}/failed/111111"
touch "${AUDIO_DATA_PATH}/failed/222222"
if AlbumPreviouslyFailed "222222"; then
    echo "✅ PASS: Found in multiple failed albums"
    ((pass++))
else
    echo "❌ FAIL: Multiple failed (got $result, expected true)"
    ((fail++))
fi

# Cleanup
rm -rf "${AUDIO_DATA_PATH}"

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
