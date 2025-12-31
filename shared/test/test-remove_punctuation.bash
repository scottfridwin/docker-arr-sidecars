#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

# --- Define test cases ---
declare -A TESTS=(
    ["remove.period"]="removeperiod"
    ["hello, world!"]="hello world"
    ["what? no way."]="what no way"
    ["(test) string: yes; no!"]="(test) string yes no"
    ['single "double" quotes']="single double quotes"
    ["it's a test's string."]="its a tests string"
    ["well... maybe!"]="well maybe"
    ["Nº 1!"]="Nº 1"
    ["end."]="end"
    ["(parentheses)"]="(parentheses)"
    ["[brackets]"]="[brackets]"
    ["{braces}"]="{braces}"
    ["dash - hyphen"]="dash - hyphen"
    ["slash / backslash \\"]="slash / backslash \\"
    ["colon: semi; comma, period."]="colon semi comma period"
    ["multiple!!! punctuation???"]="multiple punctuation"
)

pass=0
fail=0

echo "----------------------------------------------"

for input in "${!TESTS[@]}"; do
    expected="${TESTS[$input]}"
    output="$(remove_punctuation "$input")"

    if [[ "$output" == "$expected" ]]; then
        printf "✅ PASS: %-45s → %s\n" "$input" "$output"
        ((pass++))
    else
        printf "❌ FAIL: %-45s → got '%s', expected '%s'\n" "$input" "$output" "$expected"
        ((fail++))
    fi
done

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
