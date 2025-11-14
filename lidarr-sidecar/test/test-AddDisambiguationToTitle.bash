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
    ["2048|Deluxe Edition"]="2048 (Deluxe Edition)"
    ["The Vectors|Red Album"]="The Vectors (Red Album)"
    ["Maple Street|Remastered"]="Maple Street (Remastered)"
    ["Aurora Lane|"]="Aurora Lane"
    ["Lightning Brigade V|null"]="Lightning Brigade V"
    ["The Beetles| "]="The Beetles ( )"
    ["Perception|Deluxe Version"]="Perception (Deluxe Version)"
    ["Storybook|"]="Storybook"
    ["Twilights|4pm Edition"]="Twilights (4pm Edition)"
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
