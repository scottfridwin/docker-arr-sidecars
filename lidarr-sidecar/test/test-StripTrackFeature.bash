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

# --- Parody stripping cases ---

run_test \
    "parody parenthetical lowercase" \
    "Song Title (parody of Madonna)" \
    "Song Title"

run_test \
    "Parody capitalized" \
    "Song Title (Parody of Madonna)" \
    "Song Title"

# run_test \
#     "parody without parentheses" \
#     "Song Title parody of Madonna" \
#     "Song Title"

run_test \
    "parody with dash" \
    "Song Title - Parody of Madonna" \
    "Song Title"

run_test \
    "parody with em dash" \
    "Song Title — parody of Madonna" \
    "Song Title"

run_test \
    "parody mixed case" \
    "Song Title (PaRoDy Of Madonna)" \
    "Song Title"

run_test \
    "parody multiple words artist" \
    "Song Title (Parody of Taylor Swift)" \
    "Song Title"

run_test \
    "parody extra spacing" \
    "Song Title   (parody   of   Madonna )" \
    "Song Title"

# --- Parody negative cases ---

run_test \
    "parody word in title" \
    "Parody of Love" \
    "Parody of Love"

run_test \
    "parody phrase mid-title" \
    "This Is a Parody of Love Song" \
    "This Is a Parody of Love Song"

run_test \
    "parody not suffix" \
    "Song Title parody version" \
    "Song Title parody version"

run_test \
    "parenthetical without parody keyword" \
    "Song Title (Comedy Version)" \
    "Song Title (Comedy Version)"

# --- Combined feature + parody cases ---

run_test \
    "feature then parody" \
    "Song Title (feat. Drake) (Parody of Madonna)" \
    "Song Title"

run_test \
    "parody then live preserved" \
    "Song Title (Parody of Madonna) (Live)" \
    "Song Title (Live)"

run_test \
    "dash parody then feature" \
    "Song Title - Parody of Madonna feat. Drake" \
    "Song Title"

# --- Real cases ---

run_test \
    "real test 1" \
    "Another Tattoo Parody of \"Nothin' On You\" by B.o.B. featuring Bruno Mars" \
    "Another Tattoo"

run_test \
    "real test 2" \
    "Party In the CIA Parody of \"Party In The U.S.A.\" by Miley Cyrus" \
    "Party In the CIA"

run_test \
    "real test 3" \
    "TMZ Parody of \"You Belong With Me\" by Taylor Swift" \
    "TMZ"

run_test \
    "real test 4" \
    "It's All About the Pentiums An adaptation of \"It's All About the Benjamins\" by Puff Daddy" \
    "It's All About the Pentiums"

run_test \
    "real test 5" \
    "The Saga Begins Lyrical Adaption of \"American Pie\"" \
    "The Saga Begins"

run_test \
    "real test 6" \
    "Pretty Fly for a Rabbi Parody of \"Pretty Fly For a White Guy\" by Offspring" \
    "Pretty Fly for a Rabbi"

run_test \
    "real test 7" \
    "Grapefruit Diet Parody of \"Zoot Suit Riot\" by Cherry Poppin' Daddies" \
    "Grapefruit Diet"

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail"

# --- Exit nonzero if any failed ---
if ((fail > 0)); then
    exit 1
fi

exit 0
