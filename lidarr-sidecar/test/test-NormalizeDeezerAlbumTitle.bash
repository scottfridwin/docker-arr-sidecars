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

# Mock normalize_string (simplified version for testing)
normalize_string() {
    local str="$1"
    # Simple normalization: lowercase and basic cleanup
    echo "$str" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ()/-]//g'
}

# Mock RemoveEditionsFromAlbumTitle (simplified)
RemoveEditionsFromAlbumTitle() {
    local title="$1"
    # Simple mock: remove common patterns
    title="${title// (deluxe edition)/}"
    title="${title// (remastered)/}"
    title="${title// (super deluxe version)/}"
    echo "$title"
}

# Mock ApplyTitleReplacements
ApplyTitleReplacements() {
    local title="$1"
    # Check for custom replacement in state
    local replacement="$(get_state "titleReplacement_${title}")"
    if [[ -n "$replacement" ]]; then
        echo "${replacement}"
    else
        echo "${title}"
    fi
}

# --- Run tests ---
pass=0
fail=0
init_state
reset_state

echo "----------------------------------------------"

# Test 1: Basic title without edition
reset_state
NormalizeDeezerAlbumTitle "Maple Street"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleClean" == "maple street" ]] && [[ "$titleEditionless" == "maple street" ]]; then
    echo "✅ PASS: Basic title without edition"
    ((pass++))
else
    echo "❌ FAIL: Basic title (got clean='$titleClean', editionless='$titleEditionless')"
    ((fail++))
fi

# Test 2: Title with Deluxe Edition
reset_state
NormalizeDeezerAlbumTitle "2048 (Deluxe Edition)"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleClean" == "2048 (deluxe edition)" ]] && [[ "$titleEditionless" == "2048" ]]; then
    echo "✅ PASS: Title with Deluxe Edition removed"
    ((pass++))
else
    echo "❌ FAIL: Deluxe Edition (got clean='$titleClean', editionless='$titleEditionless')"
    ((fail++))
fi

# Test 3: Title with replacement rule
reset_state
set_state "titleReplacement_the vectors (deluxe edition)" "the vectors dlx"
NormalizeDeezerAlbumTitle "The Vectors (Deluxe Edition)"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleClean" == "the vectors dlx" ]]; then
    echo "✅ PASS: Replacement rule applied to clean title"
    ((pass++))
else
    echo "❌ FAIL: Replacement rule (got clean='$titleClean', expected 'the vectors dlx')"
    ((fail++))
fi

# Test 4: Title with replacement rule on editionless version
reset_state
set_state "titleReplacement_2048" "2048 deluxe version"
NormalizeDeezerAlbumTitle "2048 (Deluxe Edition)"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleEditionless" == "2048 deluxe version" ]]; then
    echo "✅ PASS: Replacement rule applied to editionless title"
    ((pass++))
else
    echo "❌ FAIL: Editionless replacement (got editionless='$titleEditionless', expected '2048 deluxe version')"
    ((fail++))
fi

# Test 5: Both versions have different replacements
reset_state
set_state "titleReplacement_album (deluxe edition)" "album dlx"
set_state "titleReplacement_album" "album standard"
NormalizeDeezerAlbumTitle "Album (Deluxe Edition)"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleClean" == "album dlx" ]] && [[ "$titleEditionless" == "album standard" ]]; then
    echo "✅ PASS: Different replacements for clean and editionless"
    ((pass++))
else
    echo "❌ FAIL: Different replacements (got clean='$titleClean', editionless='$titleEditionless')"
    ((fail++))
fi

# Test 6: Empty title
reset_state
NormalizeDeezerAlbumTitle ""
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleClean" == "" ]] && [[ "$titleEditionless" == "" ]]; then
    echo "✅ PASS: Empty title handled"
    ((pass++))
else
    echo "❌ FAIL: Empty title (got clean='$titleClean', editionless='$titleEditionless')"
    ((fail++))
fi

# Test 7: Title with Remastered
reset_state
NormalizeDeezerAlbumTitle "The Bright Side of the Sun (Remastered)"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleEditionless" == "the bright side of the sun" ]]; then
    echo "✅ PASS: Remastered edition removed"
    ((pass++))
else
    echo "❌ FAIL: Remastered (got editionless='$titleEditionless', expected 'the bright side of the sun')"
    ((fail++))
fi

# Test 8: Title truncation at 130 chars
reset_state
long_title="This Is A Very Long Album Title That Should Be Truncated At Exactly One Hundred And Thirty Characters To Prevent Issues With Database Storage And Other Systems That Might Have Length Limitations For String Fields"
NormalizeDeezerAlbumTitle "$long_title"
titleClean=$(get_state "deezerCandidateTitleClean")
length=${#titleClean}
if [[ $length -le 130 ]]; then
    echo "✅ PASS: Long title truncated to 130 chars (length=$length)"
    ((pass++))
else
    echo "❌ FAIL: Title not truncated (length=$length, expected <=130)"
    ((fail++))
fi

# Test 9: Title with special characters
reset_state
NormalizeDeezerAlbumTitle "Deluxe Version (Deluxe Edition)"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ -n "$titleClean" ]] && [[ -n "$titleEditionless" ]]; then
    echo "✅ PASS: Special characters handled"
    ((pass++))
else
    echo "❌ FAIL: Special characters (got clean='$titleClean', editionless='$titleEditionless')"
    ((fail++))
fi

# Test 10: Clean and editionless are same when no edition
reset_state
NormalizeDeezerAlbumTitle "Storybook"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleClean" == "$titleEditionless" ]]; then
    echo "✅ PASS: Clean and editionless are same when no edition"
    ((pass++))
else
    echo "❌ FAIL: Should be same (got clean='$titleClean', editionless='$titleEditionless')"
    ((fail++))
fi

# Test 11: Multiple edition keywords
reset_state
NormalizeDeezerAlbumTitle "Greatest Hits (Super Deluxe Version)"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleEditionless" == "greatest hits" ]]; then
    echo "✅ PASS: Multiple edition keywords removed"
    ((pass++))
else
    echo "❌ FAIL: Multiple keywords (got editionless='$titleEditionless', expected 'greatest hits')"
    ((fail++))
fi

# Test 12: No replacement applied when not in state
reset_state
NormalizeDeezerAlbumTitle "Test Album"
titleClean=$(get_state "deezerCandidateTitleClean")
if [[ "$titleClean" == "test album" ]]; then
    echo "✅ PASS: No replacement when not in state"
    ((pass++))
else
    echo "❌ FAIL: No replacement (got clean='$titleClean', expected 'test album')"
    ((fail++))
fi

# Test 13: Replacement not applied when title doesn't match
reset_state
set_state "titleReplacement_other album" "replaced album"
NormalizeDeezerAlbumTitle "Test Album"
titleClean=$(get_state "deezerCandidateTitleClean")
if [[ "$titleClean" == "test album" ]]; then
    echo "✅ PASS: Replacement not applied for non-matching title"
    ((pass++))
else
    echo "❌ FAIL: Wrong replacement applied (got clean='$titleClean', expected 'test album')"
    ((fail++))
fi

# Test 14: Both clean and editionless get their own replacements
reset_state
set_state "titleReplacement_album (deluxe edition)" "album special"
set_state "titleReplacement_album" "album basic"
NormalizeDeezerAlbumTitle "Album (Deluxe Edition)"
titleClean=$(get_state "deezerCandidateTitleClean")
titleEditionless=$(get_state "deezerCandidateTitleEditionless")
if [[ "$titleClean" == "album special" ]] && [[ "$titleEditionless" == "album basic" ]]; then
    echo "✅ PASS: Independent replacements for clean and editionless"
    ((pass++))
else
    echo "❌ FAIL: Independent replacements (got clean='$titleClean', editionless='$titleEditionless')"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
