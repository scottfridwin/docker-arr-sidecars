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
RemoveEditionsFromAlbumTitle() {
    local s="$1"
    # simple test substitutions — keep them idempotent and perform on the local var
    s="${s// (Deluxe Edition)/}"
    s="${s// (Remastered)/}"
    # trim leading/trailing whitespace
    s="$(echo "$s" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    printf '%s' "$s"
}
AddDisambiguationToTitle() {
    local title="$1"
    local disambig="$2"
    if [[ -z "$disambig" ]]; then
        echo "$title"
    else
        echo "${title} (${disambig})"
    fi
}

# --- Helpers ---
# Compare two arrays for equality
arrays_equal() {
    local -n arr1=$1
    local -n arr2=$2

    # Compare lengths
    if ((${#arr1[@]} != ${#arr2[@]})); then
        return 1
    fi

    # Compare each element
    for i in "${!arr1[@]}"; do
        if [[ "${arr1[$i]}" != "${arr2[$i]}" ]]; then
            return 1
        fi
    done

    return 0
}

# --- Run tests ---
pass=0
fail=0
init_state

echo "----------------------------------------------"

# Test 1: Basic title without disambiguation
reset_state
set_state "lidarrAlbumDisambiguation" ""
expected=("2048")

SetLidarrTitlesToSearch "2048" ""
tmpResult=$(get_state "lidarrTitlesToSearch")
mapfile -t result <<<"${tmpResult}"
if arrays_equal result expected; then
    echo "✅ PASS: Basic title without disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Basic title without disambiguation (expected ${expected[*]}, got ${result[*]})"
    ((fail++))
fi

# Test 2: Title with release disambiguation
reset_state
set_state "lidarrAlbumDisambiguation" ""
expected=("2048" "2048 (Deluxe Version)")

SetLidarrTitlesToSearch "2048" "Deluxe Version"
tmpResult=$(get_state "lidarrTitlesToSearch")
mapfile -t result <<<"${tmpResult}"
if arrays_equal result expected; then
    echo "✅ PASS: Title with release disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Title with release disambiguation (expected ${expected[*]}, got ${result[*]})"
    ((fail++))
fi

# Test 3: Title with edition suffix
reset_state
set_state "lidarrAlbumDisambiguation" ""
expected=("The Vectors (Deluxe Edition)" "The Vectors")

SetLidarrTitlesToSearch "The Vectors (Deluxe Edition)" ""
tmpResult=$(get_state "lidarrTitlesToSearch")
mapfile -t result <<<"${tmpResult}"
if arrays_equal result expected; then
    echo "✅ PASS: Title with edition suffix"
    ((pass++))
else
    echo "❌ FAIL: Title with edition suffix (expected ${expected[*]}, got ${result[*]})"
    echo "  Got: $result"
    ((fail++))
fi

# Test 4: Title with album disambiguation only
reset_state
set_state "lidarrAlbumDisambiguation" "Red Album"
expected=("The Vectors" "The Vectors (Red Album)")

SetLidarrTitlesToSearch "The Vectors" ""
tmpResult=$(get_state "lidarrTitlesToSearch")
mapfile -t result <<<"${tmpResult}"
if arrays_equal result expected; then
    echo "✅ PASS: Title with album disambiguation only"
    ((pass++))
else
    echo "❌ FAIL: Title with album disambiguation only (expected ${expected[*]}, got ${result[*]})"
    ((fail++))
fi

# Test 5: Title with both edition and album disambiguation
reset_state
set_state "lidarrAlbumDisambiguation" "Red Album"
expected=("The Vectors (Deluxe Edition)" "The Vectors" "The Vectors (Deluxe Edition) (Red Album)" "The Vectors (Red Album)")

SetLidarrTitlesToSearch "The Vectors (Deluxe Edition)" ""
tmpResult=$(get_state "lidarrTitlesToSearch")
mapfile -t result <<<"${tmpResult}"
if arrays_equal result expected; then
    echo "✅ PASS: Title with both edition and album disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Title with both edition and album disambiguation (expected ${expected[*]}, got ${result[*]})"
    ((fail++))
fi

# Test 6: Title with release disambiguation and edition
reset_state
set_state "lidarrAlbumDisambiguation" ""
expected=("2048 (Deluxe Edition)" "2048" "2048 (Deluxe Edition) (Deluxe Version)")

SetLidarrTitlesToSearch "2048 (Deluxe Edition)" "Deluxe Version"
tmpResult=$(get_state "lidarrTitlesToSearch")
mapfile -t result <<<"${tmpResult}"
if arrays_equal result expected; then
    echo "✅ PASS: Title with release disambiguation and edition"
    ((pass++))
else
    echo "❌ FAIL: Title with release disambiguation and edition (expected ${expected[*]}, got ${result[*]})"
    ((fail++))
fi

# Test 7: Complex case with all features
reset_state
set_state "lidarrAlbumDisambiguation" "Original"
expected=("Maple Street (Remastered)" "Maple Street" "Maple Street (Remastered) (50th Anniversary)" "Maple Street (Remastered) (Original)" "Maple Street (Original)")

SetLidarrTitlesToSearch "Maple Street (Remastered)" "50th Anniversary"
tmpResult=$(get_state "lidarrTitlesToSearch")
mapfile -t result <<<"${tmpResult}"
if arrays_equal result expected; then
    echo "✅ PASS: Complex case with all features"
    ((pass++))
else
    echo "❌ FAIL: Complex case with all features (expected ${expected[*]}, got ${result[*]})"
    ((fail++))
fi

# Test 8: Null album disambiguation
reset_state
set_state "lidarrAlbumDisambiguation" "null"
expected=("Storybook")

SetLidarrTitlesToSearch "Storybook" ""
tmpResult=$(get_state "lidarrTitlesToSearch")
mapfile -t result <<<"${tmpResult}"
if arrays_equal result expected; then
    echo "✅ PASS: Null album disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Null album disambiguation (expected ${expected[*]}, got ${result[*]})"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
