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

echo "Running tests for ShouldSkipAlbumByLyricType..."
echo "----------------------------------------------"

# Test 1: require-clean with explicit album (should skip)
result=$(ShouldSkipAlbumByLyricType "true" "require-clean")
if [[ "$result" == "true" ]]; then
    echo "✅ PASS: require-clean skips explicit albums"
    ((pass++))
else
    echo "❌ FAIL: require-clean with explicit (got $result)"
    ((fail++))
fi

# Test 2: require-clean with clean album (should not skip)
result=$(ShouldSkipAlbumByLyricType "false" "require-clean")
if [[ "$result" == "false" ]]; then
    echo "✅ PASS: require-clean does not skip clean albums"
    ((pass++))
else
    echo "❌ FAIL: require-clean with clean (got $result)"
    ((fail++))
fi

# Test 3: require-explicit with explicit album (should not skip)
result=$(ShouldSkipAlbumByLyricType "true" "require-explicit")
if [[ "$result" == "false" ]]; then
    echo "✅ PASS: require-explicit does not skip explicit albums"
    ((pass++))
else
    echo "❌ FAIL: require-explicit with explicit (got $result)"
    ((fail++))
fi

# Test 4: require-explicit with clean album (should skip)
result=$(ShouldSkipAlbumByLyricType "false" "require-explicit")
if [[ "$result" == "true" ]]; then
    echo "✅ PASS: require-explicit skips clean albums"
    ((pass++))
else
    echo "❌ FAIL: require-explicit with clean (got $result)"
    ((fail++))
fi

# Test 5: No filter (should not skip)
result=$(ShouldSkipAlbumByLyricType "true" "")
if [[ "$result" == "false" ]]; then
    echo "✅ PASS: No filter does not skip any albums"
    ((pass++))
else
    echo "❌ FAIL: No filter (got $result)"
    ((fail++))
fi

# Test 6: prefer-clean does not cause skipping
result=$(ShouldSkipAlbumByLyricType "true" "prefer-clean")
if [[ "$result" == "false" ]]; then
    echo "✅ PASS: prefer-clean does not skip albums"
    ((pass++))
else
    echo "❌ FAIL: prefer-clean should not skip (got $result)"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi

exit 0
