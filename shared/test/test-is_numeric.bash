#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

pass=0
fail=0

# Helper to run a test scenario
run_test() {
    local input="$1"
    local expected="$2"

    if is_numeric "$input"; then
        result=0
    else
        result=1
    fi

    if [[ "$result" == "$expected" ]]; then
        echo "✅ PASS: is_numeric '$input' returned $result as expected"
        ((pass++))
    else
        echo "❌ FAIL: is_numeric '$input' returned $result, expected $expected"
        ((fail++))
    fi
}

echo "----------------------------------------------"

# Valid numeric tests (expect success = 0)
run_test "0" 0
run_test "1" 0
run_test "42" 0
run_test "007" 0
run_test "-1" 0

# Invalid numeric tests (expect failure = 1)
run_test "" 1
run_test " " 1
run_test "abc" 1
run_test "123abc" 1
run_test "12.5" 1
run_test "--2" 1
run_test "+-3" 1
run_test "+5" 1

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
