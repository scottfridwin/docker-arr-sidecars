#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

# --- Define test cases ---
declare -A TESTS=(
    ["I"]="1"
    ["II"]="2"
    ["III"]="3"
    ["IV"]="4"
    ["V"]="5"
    ["VI"]="6"
    ["VII"]="7"
    ["VIII"]="8"
    ["IX"]="9"
    ["X"]="10"
    ["XL"]="40"
    ["L"]="50"
    ["XC"]="90"
    ["C"]="100"
    ["CD"]="400"
    ["D"]="500"
    ["CM"]="900"
    ["M"]="1000"
    ["MMXX"]="2020"
)

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

for input in "${!TESTS[@]}"; do
    expected="${TESTS[$input]}"
    output="$(roman_to_int "$input")"

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

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
