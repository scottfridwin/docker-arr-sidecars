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

# Helper to execute a test
run_test() {
    local name="$1"
    local input="$2"
    local expected="$3"

    local output
    output="$(StripTrackFeature "$input")"

    if [[ "$output" == "$expected" ]]; then
        echo "✅ PASS: $name"
        ((pass++))
    else
        echo "❌ FAIL: $name"
        echo "   input:    '$input'"
        echo "   expected: '$expected'"
        echo "   got:      '$output'"
        ((fail++))
    fi
}

# --- Run tests ---
pass=0
fail=0

echo "----------------------------------------------"

# --- Positive cases (should strip) ---

run_test \
    "feat. lowercase" \
    "Song Title (feat. Drake)" \
    "Song Title"

run_test \
    "Feat. capitalized" \
    "Song Title (Feat. Drake)" \
    "Song Title"

run_test \
    "FT shorthand" \
    "Song Title (ft Kanye West)" \
    "Song Title"

run_test \
    "featuring full word" \
    "Song Title (featuring Jay-Z)" \
    "Song Title"

run_test \
    "multiple artists" \
    "Song Title (feat. Drake & Rihanna)" \
    "Song Title"

run_test \
    "extra spaces" \
    "Song Title   (feat.   Drake )" \
    "Song Title"

run_test \
    "mixed case keyword" \
    "Song Title (FeAt. Drake)" \
    "Song Title"

run_test \
    "no separator" \
    "Song Title feat. Drake" \
    "Song Title"

run_test \
    "no separator short" \
    "Song Title ft. Drake" \
    "Song Title"

run_test \
    "dash separator" \
    "Song Title - feat. Drake" \
    "Song Title"

run_test \
    "dash separator short" \
    "Song Title - ft. Drake" \
    "Song Title"

run_test \
    "dash feat suffix" \
    "Song Title - feat. Drake" \
    "Song Title"

run_test \
    "dash ft suffix" \
    "Song Title - ft Drake" \
    "Song Title"

run_test \
    "no dash feat suffix" \
    "Song Title feat. Drake" \
    "Song Title"

run_test \
    "featuring without parentheses" \
    "Song Title featuring Jay-Z" \
    "Song Title"

run_test \
    "em dash feature" \
    "Song Title — feat. Drake" \
    "Song Title"

# --- Negative cases (should NOT strip) ---

run_test \
    "live version preserved" \
    "Song Title (Live)" \
    "Song Title (Live)"

run_test \
    "remastered preserved" \
    "Song Title (Remastered 2011)" \
    "Song Title (Remastered 2011)"

run_test \
    "mono preserved" \
    "Song Title (Mono)" \
    "Song Title (Mono)"

run_test \
    "parentheses without feature keyword" \
    "Song Title (Bonus Track)" \
    "Song Title (Bonus Track)"

run_test \
    "dash live preserved" \
    "Song Title - Live" \
    "Song Title - Live"

run_test \
    "dash remix preserved" \
    "Song Title - Remix" \
    "Song Title - Remix"

run_test \
    "parenthetical live preserved" \
    "Song Title (Live)" \
    "Song Title (Live)"

# --- Edge cases ---

run_test \
    "no parentheses" \
    "Song Title" \
    "Song Title"

run_test \
    "feature in middle of title" \
    "Song (feat. Drake) Title" \
    "Song Title"

run_test \
    "multiple parentheses only feature removed" \
    "Song Title (feat. Drake) (Live)" \
    "Song Title (Live)"

run_test \
    "leading and trailing spaces" \
    "  Song Title (feat. Drake)  " \
    "Song Title"

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
