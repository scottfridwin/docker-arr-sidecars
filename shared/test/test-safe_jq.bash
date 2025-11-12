#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

# Mock functions
scriptName="test"
setUnhealthy() {
    echo "Would setUnhealthy" >&2
    return 1
}

pass=0
fail=0

echo "----------------------------------------------"

# --- Existing tests ---
run_test() {
    local description="$1"
    local expected="$2"
    local result="$3"

    if [[ "$result" == "$expected" ]]; then
        echo "✅ PASS: $description"
        ((pass++))
    else
        echo "❌ FAIL: $description (got '$result')"
        ((fail++))
    fi
}

# Test 1: Simple extraction
run_test "Simple property extraction" "test" "$(echo '{"name":"test","value":123}' | safe_jq '.name')"

# Test 2: Numeric value
run_test "Numeric value extraction" "42" "$(echo '{"count":42}' | safe_jq '.count')"

# Test 3: Nested property
run_test "Nested property extraction" "Alice" "$(echo '{"user":{"name":"Alice","age":30}}' | safe_jq '.user.name')"

# Test 4: Array access
run_test "Array element access" "b" "$(echo '["a","b","c"]' | safe_jq '.[1]')"

# Test 5: Optional flag with null
run_test "Optional flag returns empty for null" "" "$(echo '{"name":null}' | safe_jq --optional '.name')"

# Test 6: Optional flag with missing key
run_test "Optional flag returns empty for missing key" "" "$(echo '{"other":"value"}' | safe_jq --optional '.missing')"

# Test 7: Boolean value
run_test "Boolean value extraction" "true" "$(echo '{"enabled":true}' | safe_jq '.enabled')"

# Test 8: Array length
run_test "Array length calculation" "4" "$(echo '["a","b","c","d"]' | safe_jq 'length')"

# Test 9: Complex filter
run_test "Complex filter" "1" "$(echo '[{"id":1,"name":"a"},{"id":2,"name":"b"}]' | safe_jq '.[0].id')"

# Test 10: String with spaces
run_test "String with spaces" "Hello World" "$(echo '{"title":"Hello World"}' | safe_jq '.title')"

# --- New edge-case tests ---

# Test 11: Invalid JSON should fail
if echo '{bad json}' | safe_jq '.' >/dev/null 2>&1; then
    echo "❌ FAIL: Invalid JSON should fail"
    ((fail++))
else
    echo "✅ PASS: Invalid JSON correctly fails"
    ((pass++))
fi

# Test 12: Empty object
run_test "Empty object extraction" "{}" "$(echo '{}' | safe_jq '.')"

# Test 13: Empty array
run_test "Empty array extraction" "[]" "$(echo '[]' | safe_jq '.')"

# Test 14: Nested null without optional
if echo '{"a":null}' | safe_jq '.a' >/dev/null 2>&1; then
    echo "❌ FAIL: Nested null without optional should hard-fail"
    ((fail++))
else
    echo "✅ PASS: Nested null without optional correctly fails"
    ((pass++))
fi

# Test 15: Missing key without optional should fail
if echo '{"x":1}' | safe_jq '.missing' >/dev/null 2>&1; then
    echo "❌ FAIL: Missing key without optional should fail"
    ((fail++))
else
    echo "✅ PASS: Missing key without optional fails as expected"
    ((pass++))
fi

# Test 16: Nested object with optional null key
run_test "Nested optional null key" "" "$(echo '{"user":{"age":25}}' | safe_jq --optional '.user.name')"

# Test 17: Nested array element optional
run_test "Nested array optional element" "" "$(echo '{"list":[]}' | safe_jq --optional '.list[0]')"

# Test 18: Simple multi-line extraction from array of objects
multi_result=$(echo '[{"id":1},{"id":2},{"id":3}]' | safe_jq '.[].id')
expected="1
2
3"
if [[ "$multi_result" == "$expected" ]]; then
    echo "✅ PASS: Multi-line extraction from array"
    ((pass++))
else
    echo "❌ FAIL: Multi-line extraction (got '$multi_result')"
    ((fail++))
fi

# Test 19: Multi-line with strings
multi_result=$(echo '[{"name":"Alice"},{"name":"Bob"},{"name":"Carol"}]' | safe_jq '.[].name')
expected="Alice
Bob
Carol"
if [[ "$multi_result" == "$expected" ]]; then
    echo "✅ PASS: Multi-line string extraction"
    ((pass++))
else
    echo "❌ FAIL: Multi-line string extraction (got '$multi_result')"
    ((fail++))
fi

# Test 20: Optional multi-line with missing keys
multi_result=$(echo '[{"name":"Alice"},{"age":30}]' | safe_jq --optional '.[].name')
# Remove final newline for comparison
multi_result="${multi_result%$'\n'}"
expected="Alice"
if [[ "$multi_result" == "$expected" ]]; then
    echo "✅ PASS: Optional multi-line with missing keys"
    ((pass++))
else
    echo "❌ FAIL: Optional multi-line missing keys (got '$multi_result')"
    ((fail++))
fi

# Test 21: Optional multi-line with null values
multi_result=$(echo '[{"name":null},{"name":"Bob"}]' | safe_jq --optional '.[].name')
multi_result="${multi_result%$'\n'}"
expected=$'\nBob'
if [[ "$multi_result" == "$expected" ]]; then
    echo "✅ PASS: Optional multi-line null values"
    ((pass++))
else
    echo "❌ FAIL: Optional multi-line null values (got '$multi_result')"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
