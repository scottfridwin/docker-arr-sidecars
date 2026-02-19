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

# --- Helpers ---
# Compare two arrays for equality
arrays_equal() {
    local arr1_name="$1"
    local arr2_name="$2"

    local -n arr1="$arr1_name"
    local -n arr2="$arr2_name"

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

# Helper to execute a test
run_test() {
    local testName="$1"
    local title="$2"
    local releaseDisambig="$3"
    local albumDisambig="$4"
    local expected_name="expected" # name of the array variable holding expected results

    reset_state
    set_state "lidarrAlbumDisambiguation" "$albumDisambig"
    SetLidarrTitlesToSearch "$title" "$releaseDisambig"
    tmpResult=$(get_state "lidarrTitlesToSearch")
    local result=()
    mapfile -t result <<<"${tmpResult}"

    if arrays_equal "$expected_name" "result"; then
        echo "✅ PASS: $testName"
        ((pass++))
    else
        local -n exp="$expected_name"
        echo "❌ FAIL: $testName (expected ${exp[*]}, got ${result[*]})"
        ((fail++))
    fi
}

# --- Run tests ---
pass=0
fail=0
init_state

echo "----------------------------------------------"

# Test 1: Basic title without disambiguation
expected=("2048")
run_test "Basic title without disambiguation" "2048" "" ""

# Test 2: Title with release disambiguation
expected=("2048" "2048 (Deluxe Version)" "2048(DeluxeVersion)")
run_test "Title with release disambiguation" "2048" "Deluxe Version" ""

# Test 3: Title with edition suffix
expected=("The Vectors Deluxe Edition" "The Vectors" "TheVectorsDeluxeEdition" "TheVectors")
run_test "Title with edition suffix" "The Vectors (Deluxe Edition)" "" ""

# Test 4: Title with album disambiguation only
expected=("The Vectors" "The Vectors (Red Album)" "TheVectors")
run_test "Title with album disambiguation only" "The Vectors" "" "Red Album"

# Test 5: Title with both edition and album disambiguation
expected=("The Vectors Deluxe Edition" "The Vectors" "The Vectors Deluxe Edition (Red Album)" "The Vectors (Red Album)" "TheVectorsDeluxeEdition" "TheVectors")
run_test "Title with both edition and album disambiguation" "The Vectors (Deluxe Edition)" "" "Red Album"

# Test 6: Title with release disambiguation and edition
expected=("2048 Deluxe Edition" "2048" "2048 Deluxe Edition (Deluxe Version)" "2048DeluxeEdition(DeluxeVersion)")
run_test "Title with release disambiguation and edition" "2048 (Deluxe Edition)" "Deluxe Version" ""

# Test 7: Complex case with all features
expected=("Maple Street Remastered" "Maple Street" "Maple Street Remastered (50th Anniversary)" "Maple Street Remastered (Original)" "Maple Street (Original)" "MapleStreetRemastered(50thAnniversary)" "MapleStreet")
run_test "Complex case with all features" "Maple Street (Remastered)" "50th Anniversary" "Original"

# Test 8: Null album disambiguation
expected=("Storybook")
run_test "Null album disambiguation" "Storybook" "" "null"

# Additional tests for edge cases and special characters

# Test 9: Multiple edition types in one title
# Behavior: editions are un-parenthesized in the normalized title
expected=("The Beatles White Album Deluxe Edition Remastered" "The Beatles White Album" "TheBeatlesWhiteAlbumDeluxeEditionRemastered" "TheBeatlesWhiteAlbum")
run_test "Multiple edition types in one title" "The Beatles White Album (Deluxe Edition) (Remastered)" "" "" expected

# Test 10: Title with special characters (ampersand)
# Behavior: ampersand becomes "and" in normalization
expected=("Rock and Roll" "RockandRoll")
run_test "Title with special characters (ampersand)" "Rock & Roll" "" "" expected

# Test 11: Title with apostrophe
expected=("The Artists Album" "TheArtistsAlbum")
run_test "Title with apostrophe" "The Artist's Album" "" "" expected

# Test 12: Title with hyphens and slashes
# Behavior: hyphens/slashes and spacing preserved in main normalized form; whitespace-removed variant concatenates parts (slashes may remain)
expected=("Love  Minus  Zero / No Limit" "LoveMinusZero/NoLimit")
run_test "Title with hyphens" "Love - Minus - Zero / No Limit" "" "" expected

# Test 13: Numbers in title
# Behavior: ampersand becomes "and" in normalized form
expected=("808s and Heartbreak" "808sandHeartbreak")
run_test "Title with numbers and special chars" "808s & Heartbreak" "" "" expected

# Test 14: Parentheses that aren't removed editions
expected=("Album Name Live Version" "AlbumNameLiveVersion")
run_test "Non-edition parentheses content" "Album Name (Live Version)" "" "" expected

# Test 15: Unicode/accented characters
# Behavior: accents may be preserved by normalize_string in this environment
expected=("Café del Mar" "CafédelMar")
run_test "Unicode/accented characters" "Café del Mar" "" "" expected

# Test 16: Very long title
expected=("This Is A Very Long Album Title With Multiple Words That Goes On And On" "ThisIsAVeryLongAlbumTitleWithMultipleWordsThatGoesOnAndOn")
run_test "Very long album title" "This Is A Very Long Album Title With Multiple Words That Goes On And On" "" "" expected

# Test 17: Release disambiguation with year
expected=("Album Name" "Album Name (2024 Remaster)" "AlbumName(2024Remaster)" "AlbumName")
run_test "Release disambiguation with year" "Album Name" "2024 Remaster" "" expected

# Test 18: All uppercase title
expected=("DARK SIDE OF THE MOON" "DARKSIDEOFTHEMOON")
run_test "All uppercase title" "DARK SIDE OF THE MOON" "" "" expected

# Test 19: Mixed whitespace and punctuation
# Behavior: multiple spaces preserved in main normalized form; whitespace-removed concatenation present
expected=("Album  Name" "AlbumName")
run_test "Multiple spaces and punctuation" "Album  -  Name..." "" "" expected

# Test 2: Musical with multiple editions
expected=("Musical Deluxe Edition Soundtrack" "Musical" "MusicalDeluxeEditionSoundtrack")
run_test "Musical with multiple editions" "Musical: Deluxe Edition Soundtrack" "" ""

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
