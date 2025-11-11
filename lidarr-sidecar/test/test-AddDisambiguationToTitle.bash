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

# --- Define test cases: "title|disambiguation" -> expected_output ---
declare -A TESTS=(
    ["1989|Deluxe Edition"]="1989 (Deluxe Edition)"
    ["Weezer|Blue Album"]="Weezer (Blue Album)"
    ["Abbey Road|Remastered"]="Abbey Road (Remastered)"
    ["Taylor Swift|"]="Taylor Swift"
    ["Led Zeppelin IV|null"]="Led Zeppelin IV"
    ["The Beatles| "]="The Beatles ( )"
    ["Reputation|Taylor's Version"]="Reputation (Taylor's Version)"
    ["Folklore|"]="Folklore"
    ["Midnights|3am Edition"]="Midnights (3am Edition)"
    ["||"]=""
    ["Title|"]="Title"
)

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

for test_case in "${!TESTS[@]}"; do
    IFS='|' read -r title disambiguation <<<"$test_case"
    expected="${TESTS[$test_case]}"
    output="$(AddDisambiguationToTitle "$title" "$disambiguation")"

    if [[ "$output" == "$expected" ]]; then
        printf "✅ PASS: %-50s → \"%s\"\n" "\"$title\" + \"$disambiguation\"" "$output"
        ((pass++))
    else
        printf "❌ FAIL: %-50s → got '%s', expected '%s'\n" "\"$title\" + \"$disambiguation\"" "$output" "$expected"
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
