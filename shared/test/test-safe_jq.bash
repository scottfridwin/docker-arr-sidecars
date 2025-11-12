#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

#### Mocks ####
log() {
    : # suppress logs in tests
}
setUnhealthy() {
    set_state "unhealthy" "true"
    return 1
}

pass=0
fail=0
init_state

echo "----------------------------------------------"

# --- Helpers ---

run_test() {
    local description="$1"
    local expected="$2"
    local result="$3"
    local expectUnhealthy="${4:-}"

    local unhealthy="$(get_state "unhealthy")"
    if [[ "$result" == "$expected" && "$unhealthy" == "$expectUnhealthy" ]]; then
        echo "✅ PASS: $description"
        ((pass++))
    else
        echo "❌ FAIL: $description (got '$result', unhealthy='$unhealthy', expected unhealthy='$expectUnhealthy')"
        ((fail++))
    fi
}

run_test_multiline() {
    local description="$1"
    local expected="$2"
    local result="$3"
    local expectUnhealthy="${4:-}"

    local unhealthy="$(get_state "unhealthy")"
    if cmp -s <(printf "%s" "$expected") <(printf "%s" "$result") && [[ "$unhealthy" == "$expectUnhealthy" ]]; then
        echo "✅ PASS: $description"
        ((pass++))
    else
        echo "❌ FAIL: $description"
        echo "---- Expected ----"
        printf "%s\n" "$expected"
        echo "---- Got ----"
        printf "%s\n" "$result"
        echo "Unhealthy: got='$unhealthy', expected='$expectUnhealthy'"
        ((fail++))
    fi
}

# --- Tests ---

reset_state
run_test "Simple property extraction" "test" "$(safe_jq <<<'{"name":"test","value":123}' '.name')"

reset_state
run_test "Numeric value extraction" "42" "$(safe_jq <<<'{"count":42}' '.count')"

reset_state
run_test "Nested property extraction" "Alice" "$(safe_jq <<<'{"user":{"name":"Alice","age":30}}' '.user.name')"

reset_state
run_test "Array element access" "b" "$(safe_jq <<<'["a","b","c"]' '.[1]')"

reset_state
run_test "Optional flag returns empty for null" "" "$(safe_jq --optional '.name' <<<'{"name":null}')"

reset_state
run_test "Optional flag returns empty for missing key" "" "$(safe_jq --optional '.missing' <<<'{"other":"value"}')"

reset_state
run_test "Boolean value extraction" "true" "$(safe_jq <<<'{"enabled":true}' '.enabled')"

reset_state
run_test "Array length calculation" "4" "$(safe_jq <<<'["a","b","c","d"]' 'length')"

reset_state
run_test "Complex filter" "1" "$(safe_jq <<<'[{"id":1,"name":"a"},{"id":2,"name":"b"}]' '.[0].id')"

reset_state
run_test "String with spaces" "Hello World" "$(safe_jq <<<'{"title":"Hello World"}' '.title')"

# Invalid JSON (wrap in subshell)
reset_state
if (safe_jq <<<'{bad json}' '.' >/dev/null 2>&1); then
    echo "❌ FAIL: Invalid JSON should fail"
    ((fail++))
else
    echo "✅ PASS: Invalid JSON correctly fails"
    ((pass++))
fi

reset_state
run_test "Empty object extraction" "{}" "$(safe_jq <<<'{}' '.')"

reset_state
run_test "Empty array extraction" "[]" "$(safe_jq <<<'[]' '.')"

# Nested null without optional (subshell)
reset_state
if (safe_jq <<<'{"a":null}' '.a' >/dev/null 2>&1); then
    echo "❌ FAIL: Nested null without optional should hard-fail"
    ((fail++))
else
    echo "✅ PASS: Nested null without optional correctly fails"
    ((pass++))
fi

# Missing key without optional (subshell)
reset_state
if (safe_jq <<<'{"x":1}' '.missing' >/dev/null 2>&1); then
    echo "❌ FAIL: Missing key without optional should fail"
    ((fail++))
else
    echo "✅ PASS: Missing key without optional fails as expected"
    ((pass++))
fi

reset_state
run_test "Nested optional null key" "" "$(safe_jq --optional '.user.name' <<<'{"user":{"age":25}}')"

reset_state
run_test "Nested array optional element" "" "$(safe_jq --optional '.list[0]' <<<'{"list":[]}')"

# Multi-line tests
reset_state
multi_result=$(safe_jq <<<'[{"id":1},{"id":2},{"id":3}]' '.[].id')
expected=$'1\n2\n3'
run_test_multiline "Multi-line extraction from array" "$expected" "$multi_result"

reset_state
multi_result=$(safe_jq <<<'[{"name":"Alice"},{"name":"Bob"},{"name":"Carol"}]' '.[].name')
expected=$'Alice\nBob\nCarol'
run_test_multiline "Multi-line string extraction" "$expected" "$multi_result"

reset_state
multi_result=$(safe_jq --optional '.[].name' <<<'[{"name":"Alice"},{"age":30}]')
expected=$'Alice'
run_test_multiline "Optional multi-line with missing keys" "$expected" "$multi_result"

reset_state
multi_result=$(safe_jq --optional '.[].name' <<<'[{"name":null},{"name":"Bob"}]')
expected=$'\nBob'
run_test_multiline "Optional multi-line with null values" "$expected" "$multi_result"

# --arg tests
reset_state
multi_result=$(safe_jq --arg target "Bob" '.[] | select(.name == $target) | .name' <<<'[{"name":"Alice"},{"name":"Bob"}]')
expected="Bob"
run_test "--arg injects string variable" "$expected" "$multi_result"

reset_state
multi_result=$(safe_jq --argjson target 2 '.[] | select(.id == $target) | .id' <<<'[{"id":1},{"id":2}]')
expected="2"
run_test "--argjson injects numeric variable" "$expected" "$multi_result"

reset_state
multi_result=$(safe_jq --arg target "Bob" 'any(.[]; .name == $target)' <<<'[{"name":"Alice"}]')
expected="false"
run_test "--arg no-match returns false" "$expected" "$multi_result"

reset_state
multi_result=$(safe_jq --optional --arg key "missing" '.[].[$key]' <<<'[{"name":"Alice"}]')
expected=""
run_test "--arg combined with --optional" "$expected" "$multi_result"

reset_state
multi_result=$(safe_jq --arg pattern '"quoted"' '.text | contains($pattern)' <<<'{"text":"hello \"quoted\" world"}')
expected="true"
run_test "--arg handles special characters safely" "$expected" "$multi_result"

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
