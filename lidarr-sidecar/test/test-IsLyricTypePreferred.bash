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

echo "----------------------------------------------"

# Test 1: prefer-clean with explicit album
result=$(IsLyricTypePreferred "true" "prefer-clean")
if [[ "$result" == "false" ]]; then
    echo "✅ PASS: prefer-clean with explicit album returns false"
    ((pass++))
else
    echo "❌ FAIL: prefer-clean with explicit album (got $result)"
    ((fail++))
fi

# Test 2: prefer-clean with clean album
result=$(IsLyricTypePreferred "false" "prefer-clean")
if [[ "$result" == "true" ]]; then
    echo "✅ PASS: prefer-clean with clean album returns true"
    ((pass++))
else
    echo "❌ FAIL: prefer-clean with clean album (got $result)"
    ((fail++))
fi

# Test 3: prefer-explicit with explicit album
result=$(IsLyricTypePreferred "true" "prefer-explicit")
if [[ "$result" == "true" ]]; then
    echo "✅ PASS: prefer-explicit with explicit album returns true"
    ((pass++))
else
    echo "❌ FAIL: prefer-explicit with explicit album (got $result)"
    ((fail++))
fi

# Test 4: prefer-explicit with clean album
result=$(IsLyricTypePreferred "false" "prefer-explicit")
if [[ "$result" == "false" ]]; then
    echo "✅ PASS: prefer-explicit with clean album returns false"
    ((pass++))
else
    echo "❌ FAIL: prefer-explicit with clean album (got $result)"
    ((fail++))
fi

# Test 5: No preference (empty setting)
result=$(IsLyricTypePreferred "true" "")
if [[ "$result" == "true" ]]; then
    echo "✅ PASS: No preference returns true"
    ((pass++))
else
    echo "❌ FAIL: No preference (got $result)"
    ((fail++))
fi

# Test 6: Unknown setting defaults to true
result=$(IsLyricTypePreferred "false" "unknown-setting")
if [[ "$result" == "true" ]]; then
    echo "✅ PASS: Unknown setting defaults to true"
    ((pass++))
else
    echo "❌ FAIL: Unknown setting (got $result)"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi

exit 0
