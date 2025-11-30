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
    ["The Vectors (Deluxe Edition)"]="The Vectors"
    ["The Vectors (Deluxe Edition / Red Album)"]="The Vectors (Red Album)"
    ["The Vectors Deluxe Edition / Red Album"]="The Vectors Red Album"
    ["The Vectors (Red Album / Deluxe Edition)"]="The Vectors (Red Album)"
    ["The Vectors Red Album / Deluxe Edition"]="The Vectors Red Album"
    ["The Vectors (Super Deluxe Version)"]="The Vectors"
    ["The Vectors (Collector's Edition / Remastered)"]="The Vectors"
    ["The Vectors - Deluxe Edition"]="The Vectors"
    ["The Vectors (Red Album)"]="The Vectors (Red Album)"
    ["The Vectors"]="The Vectors"
    ["The Vectors (Red Album / )"]="The Vectors (Red Album)"
    ["The Vectors ( / Deluxe Edition)"]="The Vectors"
    ["Aurora Lane (Platinum Edition)"]="Aurora Lane"
    ["Aurora Lane 2048 (Deluxe Edition)"]="Aurora Lane 2048"
    ["Rogue Nights"]="Rogue Nights"
    ["Lesser Ground Greater Sky Deluxe Edition"]="Lesser Ground Greater Sky"
    ["Lesser Ground, Greater Sky Deluxe Edition"]="Lesser Ground, Greater Sky"
    ["Lesser Ground Greater Sky (Deluxe Edition)"]="Lesser Ground Greater Sky"
    ["Lesser Ground, Greater Sky (Deluxe Edition)"]="Lesser Ground, Greater Sky"
    ["Pretty Plâte (45th Anniversary Edition)"]="Pretty Plâte"
    ["Pretty Plâte 45th Anniversary Edition"]="Pretty Plâte"
    ["Pretty Plâte 45th Anniversary"]="Pretty Plâte"
    ["Crazy Bois (Deluxe)"]="Crazy Bois"
    ["Crazy Bois Deluxe"]="Crazy Bois"
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
