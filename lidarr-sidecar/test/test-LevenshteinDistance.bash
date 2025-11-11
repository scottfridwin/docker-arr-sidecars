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

# --- Define test cases: "string1|string2" -> expected_distance ---
declare -A TESTS=(
    ["kitten|sitting"]="3"
    ["saturday|sunday"]="3"
    ["book|back"]="2"
    ["hello|hello"]="0"
    ["abc|def"]="3"
    ["|hello"]="5"
    ["hello|"]="5"
    ["|"]="0"
    ["a|b"]="1"
    ["taylor swift|taylor swift"]="0"
    ["1989|1989 deluxe"]="7"
    ["weezer|weezer (blue album)"]="13"
    ["the beatles|beatles"]="4"
    ["led zeppelin iv|led zeppelin 4"]="2"
)

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

for test_case in "${!TESTS[@]}"; do
    IFS='|' read -r s1 s2 <<<"$test_case"
    expected="${TESTS[$test_case]}"
    output="$(LevenshteinDistance "$s1" "$s2")"

    if [[ "$output" == "$expected" ]]; then
        printf "✅ PASS: %-50s → %s\n" "\"$s1\" vs \"$s2\"" "$output"
        ((pass++))
    else
        printf "❌ FAIL: %-50s → got '%s', expected '%s'\n" "\"$s1\" vs \"$s2\"" "$output" "$expected"
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
