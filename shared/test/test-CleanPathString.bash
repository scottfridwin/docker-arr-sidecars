#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

pass=0
fail=0

echo "----------------------------------------------"

# Test 1: Forward slash replacement
result=$(CleanPathString "artist/album")
if [[ "$result" == "artist_album" ]]; then
    echo "✅ PASS: Forward slash replaced"
    ((pass++))
else
    echo "❌ FAIL: Forward slash (got '$result')"
    ((fail++))
fi

# Test 2: Backslash replacement
result=$(CleanPathString 'artist\album')
if [[ "$result" == "artist_album" ]]; then
    echo "✅ PASS: Backslash replaced"
    ((pass++))
else
    echo "❌ FAIL: Backslash (got '$result')"
    ((fail++))
fi

# Test 3: Colon replacement
result=$(CleanPathString "Album: Special Edition")
if [[ "$result" == "Album_Special_Edition" ]]; then
    echo "✅ PASS: Colon replaced"
    ((pass++))
else
    echo "❌ FAIL: Colon (got '$result')"
    ((fail++))
fi

# Test 4: Asterisk replacement
result=$(CleanPathString "Best * Album")
if [[ "$result" == "Best_Album" ]]; then
    echo "✅ PASS: Asterisk replaced"
    ((pass++))
else
    echo "❌ FAIL: Asterisk (got '$result')"
    ((fail++))
fi

# Test 5: Question mark replacement
result=$(CleanPathString "What? Album")
if [[ "$result" == "What_Album" ]]; then
    echo "✅ PASS: Question mark replaced"
    ((pass++))
else
    echo "❌ FAIL: Question mark (got '$result')"
    ((fail++))
fi

# Test 6: Quote removal
result=$(CleanPathString '"Quoted" Album')
if [[ "$result" == "Quoted_Album" ]]; then
    echo "✅ PASS: Quotes removed"
    ((pass++))
else
    echo "❌ FAIL: Quotes (got '$result')"
    ((fail++))
fi

# Test 7: Hyphen removal
result=$(CleanPathString "Artist-Album")
if [[ "$result" == "ArtistAlbum" ]]; then
    echo "✅ PASS: Hyphens removed"
    ((pass++))
else
    echo "❌ FAIL: Hyphens (got '$result')"
    ((fail++))
fi

# Test 8: Multiple spaces to single underscore
result=$(CleanPathString "Too    Many     Spaces")
if [[ "$result" == "Too_Many_Spaces" ]]; then
    echo "✅ PASS: Multiple spaces collapsed to underscore"
    ((pass++))
else
    echo "❌ FAIL: Multiple spaces (got '$result')"
    ((fail++))
fi

# Test 9: Trim leading/trailing spaces
result=$(CleanPathString "  trimmed  ")
if [[ "$result" == "trimmed" ]]; then
    echo "✅ PASS: Leading/trailing spaces trimmed"
    ((pass++))
else
    echo "❌ FAIL: Trim (got '$result')"
    ((fail++))
fi

# Test 10: Length limitation
long_string="$(printf 'a%.0s' {1..200})"
result=$(CleanPathString "$long_string")
length=${#result}
if [[ $length -eq 150 ]]; then
    echo "✅ PASS: String truncated to 150 chars"
    ((pass++))
else
    echo "❌ FAIL: Length limit (got $length, expected 150)"
    ((fail++))
fi

# Test 11: All invalid characters
result=$(CleanPathString 'bad/\\:*?"<>|chars')
if [[ "$result" == "bad_chars" ]]; then
    echo "✅ PASS: All invalid characters replaced"
    ((pass++))
else
    echo "❌ FAIL: Invalid chars (got '$result')"
    ((fail++))
fi

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

if ((fail > 0)); then
    exit 1
fi
exit 0
