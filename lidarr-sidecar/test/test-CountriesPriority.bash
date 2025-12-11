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

# --- Define test cases: "countries:preferredCountries" -> expected_priority ---
declare -A TESTS=(
    ["US:US,UK,JP"]="0"
    ["UK:US,UK,JP"]="1"
    ["JP:US,UK,JP"]="2"
    ["US,UK:US,UK,JP"]="0"
    ["FR:US,UK,JP"]="999"
    ["US:"]="0"
    ["UK:"]="0"
    ["US:US"]="0"
    ["us:US,UK,JP"]="0"
    ["United States:US,UK,JP"]="999"
    ["uk:US,UK,JP"]="1"
    ["Japan:US,UK,JP"]="999"
    ["UK|US:UK,JP"]="0"
    ["US|UK,JP:US,UK,JP"]="0"
    ["JP,UK|US:US,UK,JP"]="0"
    ["JP|UK|US:US,UK,JP"]="0"
    ["UK|JP|US:US,UK,JP"]="0"
    ["US|US|UK:US,UK,JP"]="0"
    ["JP,JP:US,UK,JP"]="2"
    [" US , UK :US,UK,JP"]="0"
    ["  JP | UK  :US,UK,JP"]="1"
    ["US:  US ,  UK , JP  "]="0"
    ["uS|Uk:Us,uK,Jp"]="0"
    ["RUS:US,UK,JP"]="999"
    ["AUS:US,UK,JP"]="999"
    ["RUS|AUS:US,UK,JP"]="999"
    ["USA:US,UK,JP"]="999"
    ["England:US,UK,JP"]="999"
    ["Great Britain:US,UK,JP"]="999"
    ["UK:US,UK,UK,JP"]="1"
    ["JP:US,JP,JP"]="1"
)

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

for test_case in "${!TESTS[@]}"; do
    IFS=':' read -r countries prefs <<<"$test_case"
    expected="${TESTS[$test_case]}"
    output="$(CountriesPriority "$countries" "$prefs")"

    if [[ "$output" == "$expected" ]]; then
        printf "✅ PASS: %-50s → %s\n" "\"$countries\" with prefs \"$prefs\"" "$output"
        ((pass++))
    else
        printf "❌ FAIL: %-50s → got '%s', expected '%s'\n" "\"$countries\" with prefs \"$prefs\"" "$output" "$expected"
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
