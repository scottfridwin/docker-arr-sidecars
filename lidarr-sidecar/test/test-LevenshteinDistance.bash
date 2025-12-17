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
    ["aurora lane|aurora lane"]="0"
    ["2048|2048 deluxe"]="7"
    ["the vectors|the vectors (red album)"]="12"
    ["the beetles|beetles"]="4"
    ["lightning brigade vi|lightning brigade 5"]="2"
    ["|"]="0"
    [" | "]="0"
    ["\t|\t"]="0"
    ["\n|\n"]="0"
    ["foo |foo"]="1"
    ["foo| foo"]="1"
    ["\$HOME|HOME"]="1"
    ["*|*"]="0"
    ["?|!"]="1"
    ["foo;rm -rf /|foo"]="9"
    ["\"quoted\"|quoted"]="2"
    ["'single'|single"]="2"
    ["foo\\bar|foobar"]="1"
    ["café|cafe"]="1"
    ["naïve|naive"]="1"
    ["über|uber"]="1"
    ["🎵|"]="1"
    ["🎵|🎵"]="0"
    ["00123|123"]="2"
    ["123.45|12345"]="1"
    ["1e10|10000000000"]="9"
    ["foo"$'\x7f'"|foo"]="1"
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
echo "Fuzzy testing..."
fuzzyFail=0
for i in {1..100}; do
    s1="$(tr -dc '[:print:]' </dev/urandom | head -c 20)"
    s2="$(tr -dc '[:print:]' </dev/urandom | head -c 20)"

    out="$(LevenshteinDistance "$s1" "$s2")"

    if ! [[ "$out" =~ ^[0-9]+$ ]]; then
        echo "❌ FUZZ FAIL: '$s1' vs '$s2' → '$out'"
        ((fail++))
        fuzzyFail=1
    fi
done
if ((fuzzyFail == 0)); then
    echo "✅ Fuzzy tests PASS"
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
