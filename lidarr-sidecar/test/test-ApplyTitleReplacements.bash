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

# --- Run tests ---
pass=0
fail=0
init_state
reset_state

echo "Running tests for ApplyTitleReplacements..."
echo "----------------------------------------------"

# Test 1: No replacement defined (title unchanged)
reset_state
result=$(ApplyTitleReplacements "Abbey Road")
if [[ "$result" == "Abbey Road" ]]; then
    echo "✅ PASS: No replacement returns original title"
    ((pass++))
else
    echo "❌ FAIL: No replacement (got '$result', expected 'Abbey Road')"
    ((fail++))
fi

# Test 2: Replacement exists
reset_state
set_state "titleReplacement_1989 (Deluxe Edition)" "1989 D.L.X."
result=$(ApplyTitleReplacements "1989 (Deluxe Edition)")
if [[ "$result" == "1989 D.L.X." ]]; then
    echo "✅ PASS: Replacement applied correctly"
    ((pass++))
else
    echo "❌ FAIL: Replacement (got '$result', expected '1989 D.L.X.')"
    ((fail++))
fi

# Test 3: Empty title
reset_state
result=$(ApplyTitleReplacements "")
if [[ "$result" == "" ]]; then
    echo "✅ PASS: Empty title returns empty"
    ((pass++))
else
    echo "❌ FAIL: Empty title (got '$result', expected '')"
    ((fail++))
fi

# Test 4: Multiple replacements in state, correct one applied
reset_state
set_state "titleReplacement_Album A" "Album A Replaced"
set_state "titleReplacement_Album B" "Album B Replaced"
set_state "titleReplacement_Album C" "Album C Replaced"
result=$(ApplyTitleReplacements "Album B")
if [[ "$result" == "Album B Replaced" ]]; then
    echo "✅ PASS: Correct replacement from multiple options"
    ((pass++))
else
    echo "❌ FAIL: Multiple replacements (got '$result', expected 'Album B Replaced')"
    ((fail++))
fi

# Test 5: Title with special characters
reset_state
set_state "titleReplacement_Weezer (Blue Album)" "Weezer - Blue"
result=$(ApplyTitleReplacements "Weezer (Blue Album)")
if [[ "$result" == "Weezer - Blue" ]]; then
    echo "✅ PASS: Replacement with special characters"
    ((pass++))
else
    echo "❌ FAIL: Special characters (got '$result', expected 'Weezer - Blue')"
    ((fail++))
fi

# Test 6: Case sensitivity check
reset_state
set_state "titleReplacement_abbey road" "Abbey Road Remastered"
result=$(ApplyTitleReplacements "Abbey Road")
if [[ "$result" == "Abbey Road" ]]; then
    echo "✅ PASS: Replacement is case-sensitive (no match)"
    ((pass++))
else
    echo "❌ FAIL: Case sensitivity (got '$result', expected 'Abbey Road')"
    ((fail++))
fi

# Test 7: Exact case match
reset_state
set_state "titleReplacement_Abbey Road" "Abbey Road Remastered"
result=$(ApplyTitleReplacements "Abbey Road")
if [[ "$result" == "Abbey Road Remastered" ]]; then
    echo "✅ PASS: Exact case match applied"
    ((pass++))
else
    echo "❌ FAIL: Exact case match (got '$result', expected 'Abbey Road Remastered')"
    ((fail++))
fi

# Test 8: Title with numbers
reset_state
set_state "titleReplacement_1989" "1989 (Taylor's Version)"
result=$(ApplyTitleReplacements "1989")
if [[ "$result" == "1989 (Taylor's Version)" ]]; then
    echo "✅ PASS: Replacement with numbers"
    ((pass++))
else
    echo "❌ FAIL: Numbers (got '$result', expected '1989 (Taylor's Version)')"
    ((fail++))
fi

# Test 9: Title with spaces
reset_state
set_state "titleReplacement_The Dark Side of the Moon" "Dark Side Moon"
result=$(ApplyTitleReplacements "The Dark Side of the Moon")
if [[ "$result" == "Dark Side Moon" ]]; then
    echo "✅ PASS: Replacement with spaces"
    ((pass++))
else
    echo "❌ FAIL: Spaces (got '$result', expected 'Dark Side Moon')"
    ((fail++))
fi

# Test 10: No state initialized
reset_state
result=$(ApplyTitleReplacements "Test Album")
if [[ "$result" == "Test Album" ]]; then
    echo "✅ PASS: Empty state returns original title"
    ((pass++))
else
    echo "❌ FAIL: Empty state (got '$result', expected 'Test Album')"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
