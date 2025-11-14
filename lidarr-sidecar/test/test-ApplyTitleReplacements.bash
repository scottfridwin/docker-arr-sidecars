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

echo "----------------------------------------------"

# Test 1: No replacement defined (title unchanged)
reset_state
result=$(ApplyTitleReplacements "Maple Street")
if [[ "$result" == "Maple Street" ]]; then
    echo "✅ PASS: No replacement returns original title"
    ((pass++))
else
    echo "❌ FAIL: No replacement (got '$result', expected 'Maple Street')"
    ((fail++))
fi

# Test 2: Replacement exists
reset_state
set_state "titleReplacement_2048 (Deluxe Edition)" "2048 A.B.C."
result=$(ApplyTitleReplacements "2048 (Deluxe Edition)")
if [[ "$result" == "2048 A.B.C." ]]; then
    echo "✅ PASS: Replacement applied correctly"
    ((pass++))
else
    echo "❌ FAIL: Replacement (got '$result', expected '2048 A.B.C.')"
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
set_state "titleReplacement_The Vectors (Red Album)" "The Vectors - Red"
result=$(ApplyTitleReplacements "The Vectors (Red Album)")
if [[ "$result" == "The Vectors - Red" ]]; then
    echo "✅ PASS: Replacement with special characters"
    ((pass++))
else
    echo "❌ FAIL: Special characters (got '$result', expected 'The Vectors - Red')"
    ((fail++))
fi

# Test 6: Case sensitivity check
reset_state
set_state "titleReplacement_maple street" "Maple Street Remastered"
result=$(ApplyTitleReplacements "Maple Street")
if [[ "$result" == "Maple Street" ]]; then
    echo "✅ PASS: Replacement is case-sensitive (no match)"
    ((pass++))
else
    echo "❌ FAIL: Case sensitivity (got '$result', expected 'Maple Street')"
    ((fail++))
fi

# Test 7: Exact case match
reset_state
set_state "titleReplacement_Maple Street" "Maple Street Remastered"
result=$(ApplyTitleReplacements "Maple Street")
if [[ "$result" == "Maple Street Remastered" ]]; then
    echo "✅ PASS: Exact case match applied"
    ((pass++))
else
    echo "❌ FAIL: Exact case match (got '$result', expected 'Maple Street Remastered')"
    ((fail++))
fi

# Test 8: Title with numbers
reset_state
set_state "titleReplacement_2048" "2048 (Deluxe Version)"
result=$(ApplyTitleReplacements "2048")
if [[ "$result" == "2048 (Deluxe Version)" ]]; then
    echo "✅ PASS: Replacement with numbers"
    ((pass++))
else
    echo "❌ FAIL: Numbers (got '$result', expected '2048 (Deluxe Version)')"
    ((fail++))
fi

# Test 9: Title with spaces
reset_state
set_state "titleReplacement_The Bright Side of the Sun" "Bright Side Sun"
result=$(ApplyTitleReplacements "The Bright Side of the Sun")
if [[ "$result" == "Bright Side Sun" ]]; then
    echo "✅ PASS: Replacement with spaces"
    ((pass++))
else
    echo "❌ FAIL: Spaces (got '$result', expected 'Bright Side Sun)')"
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
