#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

pass=0
fail=0

echo "----------------------------------------------"

# Test 1: Smart quotes to regular quotes
result=$(normalize_string "Don't 'test' this")
if [[ "$result" == "Don't 'test' this" ]]; then
    echo "✅ PASS: Smart single quotes converted"
    ((pass++))
else
    echo "❌ FAIL: Smart quotes (got '$result')"
    ((fail++))
fi

# Test 2: En dash to hyphen
result=$(normalize_string "2020–2021")
if [[ "$result" == "2020-2021" ]]; then
    echo "✅ PASS: En dash converted to hyphen"
    ((pass++))
else
    echo "❌ FAIL: En dash (got '$result')"
    ((fail++))
fi

# Test 3: Multiple spaces collapsed
result=$(normalize_string "Too    many     spaces")
if [[ "$result" == "Too many spaces" ]]; then
    echo "✅ PASS: Multiple spaces collapsed"
    ((pass++))
else
    echo "❌ FAIL: Multiple spaces (got '$result')"
    ((fail++))
fi

# Test 4: Remove parentheses
result=$(normalize_string "Album (Deluxe)")
if [[ "$result" == "Album Deluxe" ]]; then
    echo "✅ PASS: Parentheses removed"
    ((pass++))
else
    echo "❌ FAIL: Parentheses (got '$result')"
    ((fail++))
fi

# Test 5: Remove question marks
result=$(normalize_string "What? Where?")
if [[ "$result" == "What Where" ]]; then
    echo "✅ PASS: Question marks removed"
    ((pass++))
else
    echo "❌ FAIL: Question marks (got '$result')"
    ((fail++))
fi

# Test 6: Remove exclamation marks
result=$(normalize_string "Hello! World!")
if [[ "$result" == "Hello World" ]]; then
    echo "✅ PASS: Exclamation marks removed"
    ((pass++))
else
    echo "❌ FAIL: Exclamation marks (got '$result')"
    ((fail++))
fi

# Test 7: Remove commas
result=$(normalize_string "One, Two, Three")
if [[ "$result" == "One Two Three" ]]; then
    echo "✅ PASS: Commas removed"
    ((pass++))
else
    echo "❌ FAIL: Commas (got '$result')"
    ((fail++))
fi

# Test 8: Trim leading/trailing spaces
result=$(normalize_string "  trimmed  ")
if [[ "$result" == "trimmed" ]]; then
    echo "✅ PASS: Spaces trimmed"
    ((pass++))
else
    echo "❌ FAIL: Trim spaces (got '$result')"
    ((fail++))
fi

# Test 9: Masculine ordinal to degree
result=$(normalize_string "Nº 1")
if [[ "$result" == "N° 1" ]]; then
    echo "✅ PASS: Masculine ordinal converted"
    ((pass++))
else
    echo "❌ FAIL: Ordinal (got '$result')"
    ((fail++))
fi

# Test 10: Combined transformations
result=$(normalize_string "Don't (test) this, okay?")
if [[ "$result" == "Don't test this okay" ]]; then
    echo "✅ PASS: Combined transformations"
    ((pass++))
else
    echo "❌ FAIL: Combined (got '$result')"
    ((fail++))
fi

# Test 11: Ampersand replacement
result=$(normalize_string "This & that")
if [[ "$result" == "This and that" ]]; then
    echo "✅ PASS: Ampersand replacement"
    ((pass++))
else
    echo "❌ FAIL: Ampersand (got '$result')"
    ((fail++))
fi

# Test 11: Colon removal
result=$(normalize_string "This: Part II")
if [[ "$result" == "This Part II" ]]; then
    echo "✅ PASS: Colon removal"
    ((pass++))
else
    echo "❌ FAIL: Colon (got '$result')"
    ((fail++))
fi

# Test 11: Ellipses replacement
result=$(normalize_string "…oh my")
if [[ "$result" == "...oh my" ]]; then
    echo "✅ PASS: Ellipses replacement"
    ((pass++))
else
    echo "❌ FAIL: Ellipses (got '$result')"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
