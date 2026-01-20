#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"

# --- Define test cases ---
declare -A TESTS=(
    ["Don't 'test' this"]="Don't 'test' this"
    ["2020–2021"]="2020-2021"
    ["Too    many     spaces"]="Too many spaces"
    ["Album (Deluxe)"]="Album Deluxe"
    ["What? Where?"]="What Where"
    ["Hello! World!"]="Hello World"
    ["One, Two, Three"]="One Two Three"
    ["  trimmed  "]="trimmed"
    ["Nº 1"]="N° 1"
    ["Don't (test) this, okay?"]="Don't test this okay"
    ["This & that"]="This and that"
    ["This: Part II"]="This Part II"
    ["…oh my"]="...oh my"
    ["...oh my"]="...oh my"
    ["2020‐2021"]="2020-2021"
    ["Peace “☮︎” Sign"]="Peace \"☮︎\" Sign"
    ["\udcb3Strange Title\udcb3"]="Strange Title"
)

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

for input in "${!TESTS[@]}"; do
    expected="${TESTS[$input]}"
    output="$(normalize_string "$input")"

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
