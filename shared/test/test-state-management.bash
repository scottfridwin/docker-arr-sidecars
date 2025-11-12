#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

# Mock functions to avoid exit
scriptName="test"
setUnhealthy() {
    echo "Would call setUnhealthy"
    return 1
}

pass=0
fail=0

echo "----------------------------------------------"

# Test 1: Initialize state
init_state
state_name=$(_get_state_name)
if declare -p "$state_name" &>/dev/null; then
    echo "✅ PASS: State initialized"
    ((pass++))
else
    echo "❌ FAIL: State not initialized"
    ((fail++))
fi

# Test 2: Set and get state
set_state "testKey" "testValue"
result=$(get_state "testKey")
if [[ "$result" == "testValue" ]]; then
    echo "✅ PASS: Set and get state"
    ((pass++))
else
    echo "❌ FAIL: Set/get state (got '$result')"
    ((fail++))
fi

# Test 3: Get non-existent key returns empty
result=$(get_state "nonExistentKey")
if [[ -z "$result" ]]; then
    echo "✅ PASS: Non-existent key returns empty"
    ((pass++))
else
    echo "❌ FAIL: Non-existent key (got '$result')"
    ((fail++))
fi

# Test 4: Overwrite existing key
set_state "testKey" "newValue"
result=$(get_state "testKey")
if [[ "$result" == "newValue" ]]; then
    echo "✅ PASS: Key overwritten"
    ((pass++))
else
    echo "❌ FAIL: Overwrite (got '$result')"
    ((fail++))
fi

# Test 5: Multiple keys
set_state "key1" "value1"
set_state "key2" "value2"
set_state "key3" "value3"
r1=$(get_state "key1")
r2=$(get_state "key2")
r3=$(get_state "key3")
if [[ "$r1" == "value1" ]] && [[ "$r2" == "value2" ]] && [[ "$r3" == "value3" ]]; then
    echo "✅ PASS: Multiple keys stored"
    ((pass++))
else
    echo "❌ FAIL: Multiple keys (got '$r1', '$r2', '$r3')"
    ((fail++))
fi

# Test 6: Reset state
reset_state
result=$(get_state "key1")
if [[ -z "$result" ]]; then
    echo "✅ PASS: State reset clears keys"
    ((pass++))
else
    echo "❌ FAIL: State reset (got '$result')"
    ((fail++))
fi

# Test 7: Set after reset
set_state "afterReset" "works"
result=$(get_state "afterReset")
if [[ "$result" == "works" ]]; then
    echo "✅ PASS: Can set after reset"
    ((pass++))
else
    echo "❌ FAIL: Set after reset (got '$result')"
    ((fail++))
fi

# Test 8: Values with spaces
set_state "spaceKey" "value with spaces"
result=$(get_state "spaceKey")
if [[ "$result" == "value with spaces" ]]; then
    echo "✅ PASS: Values with spaces"
    ((pass++))
else
    echo "❌ FAIL: Spaces in value (got '$result')"
    ((fail++))
fi

# Test 9: Values with special characters
set_state "specialKey" 'value with "quotes" and $symbols'
result=$(get_state "specialKey")
if [[ "$result" == 'value with "quotes" and $symbols' ]]; then
    echo "✅ PASS: Special characters preserved"
    ((pass++))
else
    echo "❌ FAIL: Special chars (got '$result')"
    ((fail++))
fi

# Test 10: Empty value
set_state "emptyKey" ""
result=$(get_state "emptyKey")
if [[ "$result" == "" ]]; then
    echo "✅ PASS: Empty value stored"
    ((pass++))
else
    echo "❌ FAIL: Empty value (got '$result')"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
