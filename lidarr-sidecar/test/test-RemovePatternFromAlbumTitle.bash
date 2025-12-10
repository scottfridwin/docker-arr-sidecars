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

# --- Define test cases ---
declare -A TESTS=(
    ["albumTitle - PATTERN"]="albumTitle"
    ["albumTitle (PATTERN)"]="albumTitle"
    ["albumTitle (realToken / PATTERN)"]="albumTitle (realToken)"
    ["albumTitle (realToken/PATTERN)"]="albumTitle (realToken)"
    ["albumTitle (PATTERN / realToken)"]="albumTitle (realToken)"
    ["albumTitle (PATTERN/realToken)"]="albumTitle (realToken)"
    ["albumTitle [PATTERN]"]="albumTitle"
    ["albumTitle [realToken / PATTERN]"]="albumTitle [realToken]"
    ["albumTitle [realToken/PATTERN]"]="albumTitle [realToken]"
    ["albumTitle [PATTERN / realToken]"]="albumTitle [realToken]"
    ["albumTitle [PATTERN/realToken]"]="albumTitle [realToken]"
    ["albumTitle realToken / PATTERN"]="albumTitle realToken"
    ["albumTitle realToken/PATTERN"]="albumTitle realToken"
    ["albumTitle PATTERN / realToken"]="albumTitle realToken"
    ["albumTitle PATTERN/realToken"]="albumTitle realToken"
    ["albumTitle realToken PATTERN"]="albumTitle realToken"
    ["albumTitle:PATTERN"]="albumTitle"
    ["albumTitle: PATTERN"]="albumTitle"
)

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

for input in "${!TESTS[@]}"; do
    expected="${TESTS[$input]}"
    output="$(RemovePatternFromAlbumTitle "$input" "PATTERN")"

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
