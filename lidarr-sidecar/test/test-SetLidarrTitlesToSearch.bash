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

# --- Run tests ---
pass=0
fail=0
init_state

echo "----------------------------------------------"

# Test 1: Basic title without disambiguation
reset_state
set_state "lidarrAlbumDisambiguation" ""
SetLidarrTitlesToSearch "1989" ""
result=$(get_state "lidarrTitlesToSearch")
expected_count=1
actual_count=$(count_lines "$result")
if [[ "$actual_count" -eq "$expected_count" ]] && contains_line "$result" "1989"; then
    echo "✅ PASS: Basic title without disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Basic title without disambiguation (expected $expected_count titles, got $actual_count)"
    ((fail++))
fi

# Test 2: Title with release disambiguation
reset_state
set_state "lidarrAlbumDisambiguation" ""
SetLidarrTitlesToSearch "1989" "Taylor's Version"
result=$(get_state "lidarrTitlesToSearch")
expected_count=2
actual_count=$(count_lines "$result")
if [[ "$actual_count" -eq "$expected_count" ]] && contains_line "$result" "1989" && contains_line "$result" "1989 (Taylor's Version)"; then
    echo "✅ PASS: Title with release disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Title with release disambiguation (expected $expected_count titles, got $actual_count)"
    ((fail++))
fi

# Test 3: Title with edition suffix
reset_state
set_state "lidarrAlbumDisambiguation" ""
SetLidarrTitlesToSearch "Weezer (Deluxe Edition)" ""
result=$(get_state "lidarrTitlesToSearch")
expected_count=2
actual_count=$(count_lines "$result")
if [[ "$actual_count" -eq "$expected_count" ]] && contains_line "$result" "Weezer (Deluxe Edition)" && contains_line "$result" "Weezer"; then
    echo "✅ PASS: Title with edition suffix"
    ((pass++))
else
    echo "❌ FAIL: Title with edition suffix (expected $expected_count titles, got $actual_count)"
    echo "  Got: $result"
    ((fail++))
fi

# Test 4: Title with album disambiguation only
reset_state
set_state "lidarrAlbumDisambiguation" "Blue Album"
SetLidarrTitlesToSearch "Weezer" ""
result=$(get_state "lidarrTitlesToSearch")
expected_count=2
actual_count=$(count_lines "$result")
if [[ "$actual_count" -eq "$expected_count" ]] && contains_line "$result" "Weezer" && contains_line "$result" "Weezer (Blue Album)"; then
    echo "✅ PASS: Title with album disambiguation only"
    ((pass++))
else
    echo "❌ FAIL: Title with album disambiguation only (expected $expected_count titles, got $actual_count)"
    ((fail++))
fi

# Test 5: Title with both edition and album disambiguation
reset_state
set_state "lidarrAlbumDisambiguation" "Blue Album"
SetLidarrTitlesToSearch "Weezer (Deluxe Edition)" ""
result=$(get_state "lidarrTitlesToSearch")
expected_count=4
actual_count=$(count_lines "$result")
if [[ "$actual_count" -eq "$expected_count" ]] &&
    contains_line "$result" "Weezer (Deluxe Edition)" &&
    contains_line "$result" "Weezer" &&
    contains_line "$result" "Weezer (Deluxe Edition) (Blue Album)" &&
    contains_line "$result" "Weezer (Blue Album)"; then
    echo "✅ PASS: Title with both edition and album disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Title with both edition and album disambiguation (expected $expected_count titles, got $actual_count)"
    echo "  Got: $result"
    ((fail++))
fi

# Test 6: Title with release disambiguation and edition
reset_state
set_state "lidarrAlbumDisambiguation" ""
SetLidarrTitlesToSearch "1989 (Deluxe Edition)" "Taylor's Version"
result=$(get_state "lidarrTitlesToSearch")
expected_count=3
actual_count=$(count_lines "$result")
if [[ "$actual_count" -eq "$expected_count" ]] &&
    contains_line "$result" "1989 (Deluxe Edition)" &&
    contains_line "$result" "1989" &&
    contains_line "$result" "1989 (Deluxe Edition) (Taylor's Version)"; then
    echo "✅ PASS: Title with release disambiguation and edition"
    ((pass++))
else
    echo "❌ FAIL: Title with release disambiguation and edition (expected $expected_count titles, got $actual_count)"
    echo "  Got: $result"
    ((fail++))
fi

# Test 7: Complex case with all features
reset_state
set_state "lidarrAlbumDisambiguation" "Original"
SetLidarrTitlesToSearch "Abbey Road (Remastered)" "50th Anniversary"
result=$(get_state "lidarrTitlesToSearch")
# Should have: original, editionless, with release disambig, with album disambig, editionless with album disambig
expected_min=4
actual_count=$(count_lines "$result")
if [[ "$actual_count" -ge "$expected_min" ]] &&
    contains_line "$result" "Abbey Road (Remastered)" &&
    contains_line "$result" "Abbey Road"; then
    echo "✅ PASS: Complex case with all features"
    ((pass++))
else
    echo "❌ FAIL: Complex case with all features (expected at least $expected_min titles, got $actual_count)"
    echo "  Got: $result"
    ((fail++))
fi

# Test 8: Null album disambiguation
reset_state
set_state "lidarrAlbumDisambiguation" "null"
SetLidarrTitlesToSearch "Folklore" ""
result=$(get_state "lidarrTitlesToSearch")
expected_count=1
actual_count=$(count_lines "$result")
if [[ "$actual_count" -eq "$expected_count" ]] && contains_line "$result" "Folklore"; then
    echo "✅ PASS: Null album disambiguation"
    ((pass++))
else
    echo "❌ FAIL: Null album disambiguation (expected $expected_count titles, got $actual_count)"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
