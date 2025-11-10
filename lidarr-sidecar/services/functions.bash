#!/usr/bin/env bash

# Remove common edition keywords from the end of an album title
RemoveEditionsFromAlbumTitle() {
    local title="$1"

    # Define edition patterns to remove
    local edition_patterns=(
        "Deluxe Edition"
        "Super Deluxe Version"
        "Collector's Edition"
        "Platinum Edition"
        "Deluxe Version"
        "Special Edition"
        "Limited Edition"
        "Expanded Edition"
        "Remastered"
        "Anniversary Edition"
    )

    # Remove " - Deluxe Edition" style suffixes
    for pattern in "${edition_patterns[@]}"; do
        title="${title% - $pattern}"
    done

    # Remove edition patterns from within parentheses
    # First, handle patterns like "(Deluxe Edition)" or "(Something / Deluxe Edition)"
    for pattern in "${edition_patterns[@]}"; do
        # Remove standalone edition in parentheses: "(Deluxe Edition)"
        title="${title//\($pattern\)/}"

        # Remove edition after slash: "(Something / Deluxe Edition)"
        title="${title// \/ $pattern)/\)}"

        # Remove edition before slash: "(Deluxe Edition / Something)"
        title="${title//\($pattern \/ /\(}"
    done

    # Clean up empty or malformed parentheses
    title="${title//\( \/ /\(}" # "( / " -> "("
    title="${title// \/ \)/\)}" # " / )" -> ")"
    title="${title//\( \)/}"    # "( )" -> ""
    title="${title//\(\)/}"     # "()" -> ""

    # Trim trailing/leading spaces
    title="${title#"${title%%[![:space:]]*}"}"
    title="${title%"${title##*[![:space:]]}"}"

    echo "$title"
}

# Calculate Levenshtein distance between two strings
LevenshteinDistance() {
    local s1="${1}"
    local s2="${2}"
    local len_s1=${#s1}
    local len_s2=${#s2}

    # If either string is empty, distance is the other's length
    if ((len_s1 == 0)); then
        echo "${len_s2}"
        return
    elif ((len_s2 == 0)); then
        echo "${len_s1}"
        return
    fi

    # Initialize 2 arrays for the current and previous row
    local -a prev curr
    for ((j = 0; j <= len_s2; j++)); do
        prev[j]=${j}
    done

    for ((i = 1; i <= len_s1; i++)); do
        curr[0]=${i}
        local s1_char="${s1:i-1:1}"
        for ((j = 1; j <= len_s2; j++)); do
            local s2_char="${s2:j-1:1}"
            local cost=1
            [[ "$s1_char" == "$s2_char" ]] && cost=0

            local del=$((prev[j] + 1))
            local ins=$((curr[j - 1] + 1))
            local sub=$((prev[j - 1] + cost))

            local min=${del}
            ((ins < min)) && min=${ins}
            ((sub < min)) && min=${sub}

            curr[j]=${min}
        done
        prev=("${curr[@]}")
    done

    echo "${curr[len_s2]}"
}

# Determine priority for a format string based on AUDIO_PREFERED_FORMATS
FormatPriority() {
    local formatString="${1}"
    local preferredFormats="${2:-}"
    local priority=999 # Default low priority

    # If preferredFormats is blank, all formats are equal priority
    if [[ -z "${preferredFormats}" ]]; then
        priority=0
    else
        IFS=',' read -r -a formatArray <<<"${preferredFormats}"
        for i in "${!formatArray[@]}"; do
            if [[ "${formatString,,}" == *"${formatArray[$i],,}"* ]]; then
                priority=$i
                break
            fi
        done
    fi

    echo "${priority}"
}

# Determine priority for a countries string based on AUDIO_PREFERED_COUNTRIES
CountriesPriority() {
    local countriesString="${1}"
    local preferredCountries="${2:-}"
    local priority=999 # Default low priority

    # If preferredCountries is blank, all countries are equal priority
    if [[ -z "${preferredCountries}" ]]; then
        priority=0
    else
        IFS=',' read -r -a countryArray <<<"${preferredCountries}"
        for i in "${!countryArray[@]}"; do
            if [[ "${countriesString,,}" == *"${countryArray[$i],,}"* ]]; then
                priority=$i
                break
            fi
        done
    fi

    echo "${priority}"
}
