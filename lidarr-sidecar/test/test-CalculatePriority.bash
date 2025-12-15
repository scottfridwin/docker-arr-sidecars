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

# --- Define test cases: "inputString:preferenceString" -> expected_priority ---
declare -A TESTS=(
    # --- BASIC MATCHING ---
    ["CD:CD"]="0"
    ["Digital Media:Digital Media"]="0"
    ["Vinyl:Vinyl"]="0"

    # --- MULTI-VALUE INPUT ---
    ["CD,Digital Media:Digital Media"]="0" # first match because DM is first in pref list
    ["CD,Digital Media:CD"]="0"            # CD matches first
    ["CD,Digital Media:Vinyl,CD"]="1"      # CD is index 1 in pref list

    # --- MULTI-VALUE PREFERENCES (comma) ---
    ["CD:Digital Media,CD"]="1"
    ["Digital Media:Digital Media,CD"]="0"

    # --- MULTI-SEPARATOR PREFERENCES (|) ---
    ["CD:Digital Media|CD"]="0"
    ["Digital Media:Digital Media|CD"]="0"

    # --- MIXED SEPARATORS ---
    ["CD:Vinyl,Digital Media|CD"]="1"
    ["Digital Media:Vinyl|Digital Media,CD"]="0"

    # --- CASE INSENSITIVITY ---
    ["cd:CD"]="0"
    ["Cd:dIgItAl mEdIa|cD"]="0"
    ["DIGITAL MEDIA:cd|digital media"]="0"

    # --- WHITESPACE HANDLING ---
    ["  CD  :   CD  , Vinyl "]="0"
    [" Digital Media  :  CD | Digital Media "]="0"
    [" Digital Media  :  CD , Digital Media "]="1"
    ["   CD , Digital Media  : Digital Media  "]="0"

    # --- QUOTED INPUT / PREFERENCES ---
    ["\"CD\":CD"]="0"
    ["CD:\"Digital Media\",CD"]="1"
    ["\"Digital Media\",CD:\"Digital Media\""]="0"

    # --- NO PREFERENCE LIST ---
    ["CD:"]="999"
    ["CD,Digital Media:"]="999"
    ["Something:"]="999"

    # --- NO MATCHES ---
    ["CD:Vinyl"]="999"
    ["CD,Digital Media:Vinyl"]="999"
    ["A,B,C:D,E,F"]="999"

    # --- DIFFERENT INPUT ORDER ---
    ["CD,Digital Media:CD,Digital Media"]="0"
    ["Digital Media,CD:CD,Digital Media"]="0"

    # --- MULTIPLE INPUT TOKENS / FIRST MATCH WINS ---
    ["CD,Digital Media,Flac:Flac,CD"]="0"
    ["Flac,Digital Media,CD:Digital Media,CD"]="0"
    ["CD,Flac,Digital Media:Digital Media|CD"]="0"

    # --- DUPLICATE PREFERENCES ---
    ["CD:CD,CD,CD"]="0"
    ["Digital Media:Vinyl,Digital Media,Digital Media"]="1"

    # --- [blank] PREFERENCE ---
    [":[blank],CD"]="0"
    [" :CD,[blank]"]="1"
    [" :CD,[BLANK]"]="1"
    ["CD:[blank],CD"]="1"

    # --- EDGE CASES ---
    [" :CD"]="999"
    ["CD: "]="999"
    ["  :   "]="999"
)

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

for test_case in "${!TESTS[@]}"; do
    IFS=':' read -r inputs prefs <<<"$test_case"
    expected="${TESTS[$test_case]}"
    output="$(CalculatePriority "$inputs" "$prefs")"

    if [[ "$output" == "$expected" ]]; then
        printf "✅ PASS: %-50s → %s\n" "\"$inputs\" with prefs \"$prefs\"" "$output"
        ((pass++))
    else
        printf "❌ FAIL: %-50s → got '%s', expected '%s'\n" "\"$inputs\" with prefs \"$prefs\"" "$output" "$expected"
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
