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
    ["Weezer (Deluxe Edition)"]="Weezer"
    ["Weezer (Deluxe Edition / Blue Album)"]="Weezer (Blue Album)"
    ["Weezer Deluxe Edition / Blue Album"]="Weezer Blue Album"
    ["Weezer (Blue Album / Deluxe Edition)"]="Weezer (Blue Album)"
    ["Weezer Blue Album / Deluxe Edition"]="Weezer Blue Album"
    ["Weezer (Super Deluxe Version)"]="Weezer"
    ["Weezer (Collector's Edition / Remastered)"]="Weezer"
    ["Weezer - Deluxe Edition"]="Weezer"
    ["Weezer (Blue Album)"]="Weezer (Blue Album)"
    ["Weezer"]="Weezer"
    ["Weezer (Blue Album / )"]="Weezer (Blue Album)"
    ["Weezer ( / Deluxe Edition)"]="Weezer"
    ["Taylor Swift (Platinum Edition)"]="Taylor Swift"
    ["Taylor Swift 1989 (Deluxe Edition)"]="Taylor Swift 1989"
    ["Scoundrel Days"]="Scoundrel Days"
    ["Minor Earth Major Sky Deluxe Edition"]="Minor Earth Major Sky"
    ["Minor Earth, Major Sky Deluxe Edition"]="Minor Earth, Major Sky"
    ["Minor Earth Major Sky (Deluxe Edition)"]="Minor Earth Major Sky"
    ["Minor Earth, Major Sky (Deluxe Edition)"]="Minor Earth, Major Sky"
)

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

for input in "${!TESTS[@]}"; do
    expected="${TESTS[$input]}"
    output="$(RemoveEditionsFromAlbumTitle "$input")"

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
