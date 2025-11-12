#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

pass=0
fail=0

echo "----------------------------------------------"

# Test 1: Single quotes
result=$(remove_quotes "'hello world'")
if [[ "$result" == "hello world" ]]; then
    echo "✅ PASS: Single quotes removed"
    ((pass++))
else
    echo "❌ FAIL: Single quotes (got '$result')"
    ((fail++))
fi

# Test 2: Double quotes
result=$(remove_quotes '"test string"')
if [[ "$result" == "test string" ]]; then
    echo "✅ PASS: Double quotes removed"
    ((pass++))
else
    echo "❌ FAIL: Double quotes (got '$result')"
    ((fail++))
fi

# Test 3: Mixed quotes
result=$(remove_quotes "\"test's\" 'string\"")
if [[ "$result" == "tests string" ]]; then
    echo "✅ PASS: Mixed quotes removed"
    ((pass++))
else
    echo "❌ FAIL: Mixed quotes (got '$result')"
    ((fail++))
fi

# Test 4: No quotes
result=$(remove_quotes "no quotes here")
if [[ "$result" == "no quotes here" ]]; then
    echo "✅ PASS: No quotes unchanged"
    ((pass++))
else
    echo "❌ FAIL: No quotes (got '$result')"
    ((fail++))
fi

# Test 5: Empty string
result=$(remove_quotes "")
if [[ "$result" == "" ]]; then
    echo "✅ PASS: Empty string handled"
    ((pass++))
else
    echo "❌ FAIL: Empty string (got '$result')"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
