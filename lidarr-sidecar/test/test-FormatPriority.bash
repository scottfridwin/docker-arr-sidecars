#!/usr/bin/env bash
set -uo pipefail

# --- Source the function under test ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../services/functions.bash"

# --- Define test cases: "format|preferredFormats" -> expected_priority ---
declare -A TESTS=(
    ["CD|CD,Vinyl,Digital"]="0"
    ["Vinyl|CD,Vinyl,Digital"]="1"
    ["Digital Media|CD,Vinyl,Digital"]="2"
    ["Cassette|CD,Vinyl,Digital"]="999"
    ["CD|"]="0"
    ["Vinyl|"]="0"
    ["CD|CD"]="0"
    ["vinyl|CD,Vinyl,Digital"]="1"
    ["VINYL|CD,Vinyl,Digital"]="1"
    ["12\" Vinyl|CD,Vinyl,Digital"]="1"
    ["Digital|digital"]="0"
)

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

for test_case in "${!TESTS[@]}"; do
    IFS='|' read -r format prefs <<<"$test_case"
    expected="${TESTS[$test_case]}"
    output="$(FormatPriority "$format" "$prefs")"

    if [[ "$output" == "$expected" ]]; then
        printf "✅ PASS: %-50s → %s\n" "\"$format\" with prefs \"$prefs\"" "$output"
        ((pass++))
    else
        printf "❌ FAIL: %-50s → got '%s', expected '%s'\n" "\"$format\" with prefs \"$prefs\"" "$output" "$expected"
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
