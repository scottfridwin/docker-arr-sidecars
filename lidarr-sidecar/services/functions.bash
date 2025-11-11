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

# Get release title with disambiguation if available
AddDisambiguationToTitle() {
    # $1 -> The title
    # $2 -> The disambiguation
    local title="$1"
    local disambiguation="$2"
    if [[ -n "${disambiguation}" && "${disambiguation}" != "null" && "${disambiguation}" != "" ]]; then
        echo "${title} (${disambiguation})"
    else
        echo "${title}"
    fi
}

# Extract artist info from JSON and set state variables
ExtractArtistInfo() {
    local artist_json="$1"

    local lidarrArtistName lidarrArtistId lidarrArtistForeignArtistId
    lidarrArtistName=$(jq -r ".artistName" <<<"$artist_json")
    lidarrArtistId=$(jq -r ".artistMetadataId" <<<"$artist_json")
    lidarrArtistForeignArtistId=$(jq -r ".foreignArtistId" <<<"$artist_json")
    set_state "lidarrArtistInfo" "${artist_json}"
    set_state "lidarrArtistName" "${lidarrArtistName}"
    set_state "lidarrArtistId" "${lidarrArtistId}"
    set_state "lidarrArtistForeignArtistId" "${lidarrArtistForeignArtistId}"
}

# Extract album info from JSON and set state variables
ExtractAlbumInfo() {
    local album_json="$1"

    local lidarrAlbumTitle lidarrAlbumType lidarrAlbumForeignAlbumId
    lidarrAlbumTitle=$(jq -r ".title" <<<"$album_json")
    lidarrAlbumType=$(jq -r ".albumType" <<<"$album_json")
    lidarrAlbumForeignAlbumId=$(jq -r ".foreignAlbumId" <<<"$album_json")

    # Extract disambiguation from album info
    local lidarrAlbumDisambiguation
    lidarrAlbumDisambiguation=$(jq -r ".disambiguation" <<<"$album_json")

    local albumReleaseYear
    local albumReleaseDate="$(jq -r '.releaseDate' <<<"${album_json}")"
    if [ -n "${albumReleaseDate}" ] && [ "${albumReleaseDate}" != "null" ]; then
        albumReleaseYear="${albumReleaseDate:0:4}"
    else
        albumReleaseYear=""
    fi
    releaseDateClean=${albumReleaseDate:0:10}                             # YYYY-MM-DD
    releaseDateClean=$(echo "${releaseDateClean}" | sed -e 's/[^0-9]//g') # YYYYMMDD

    set_state "lidarrAlbumInfo" "${album_json}"
    set_state "lidarrAlbumTitle" "${lidarrAlbumTitle}"
    set_state "lidarrAlbumType" "${lidarrAlbumType}"
    set_state "lidarrAlbumForeignAlbumId" "${lidarrAlbumForeignAlbumId}"
    set_state "lidarrAlbumDisambiguation" "${lidarrAlbumDisambiguation}"
    set_state "lidarrAlbumReleaseDate" "${albumReleaseDate}"
    set_state "lidarrAlbumReleaseDateClean" "${releaseDateClean}"
    set_state "lidarrAlbumReleaseYear" "${albumReleaseYear}"
}

# Extract release info from JSON and set state variables
ExtractReleaseInfo() {
    local release_json="$1"

    local lidarrReleaseTitle="$(jq -r ".title" <<<"${release_json}")"
    local lidarrReleaseDisambiguation="$(jq -r ".disambiguation" <<<"${release_json}")"
    local lidarrReleaseTrackCount="$(jq -r ".trackCount" <<<"${release_json}")"
    local lidarrReleaseForeignId="$(jq -r ".foreignReleaseId" <<<"${release_json}")"
    local lidarrReleaseFormat="$(jq -r ".format" <<<"${release_json}")"
    local lidarrReleaseCountries="$(jq -r '.country // [] | join(",")' <<<"${release_json}")"
    local lidarrReleaseFormatPriority="$(FormatPriority "${lidarrReleaseFormat}" "${AUDIO_PREFERED_FORMATS}")"
    local lidarrReleaseCountryPriority="$(CountriesPriority "${lidarrReleaseCountries}" "${AUDIO_PREFERED_COUNTRIES}")"
    local lidarrReleaseDate=$(jq -r '.releaseDate' <<<"${release_json}")
    local lidarrReleaseYear=""
    local albumReleaseYear="$(get_state "lidarrAlbumReleaseYear")"
    if [ -n "${lidarrReleaseDate}" ] && [ "${lidarrReleaseDate}" != "null" ]; then
        lidarrReleaseYear="${lidarrReleaseDate:0:4}"
    elif [ -n "${albumReleaseYear}" ] && [ "${albumReleaseYear}" != "null" ]; then
        lidarrReleaseYear="${albumReleaseYear}"
    else
        lidarrReleaseYear=""
    fi
    set_state "lidarrReleaseInfo" "${release_json}"
    set_state "lidarrReleaseTitle" "${lidarrReleaseTitle}"
    set_state "lidarrReleaseDisambiguation" "${lidarrReleaseDisambiguation}"
    set_state "lidarrReleaseTrackCount" "${lidarrReleaseTrackCount}"
    set_state "lidarrReleaseForeignId" "${lidarrReleaseForeignId}"
    set_state "lidarrReleaseFormatPriority" "${lidarrReleaseFormatPriority}"
    set_state "lidarrReleaseCountryPriority" "${lidarrReleaseCountryPriority}"
    set_state "lidarrReleaseYear" "${lidarrReleaseYear}"
}

# Set lidarrTitlesToSearch state variable with various title permutations
SetLidarrTitlesToSearch() {
    local lidarrReleaseTitle="$1"
    local lidarrReleaseDisambiguation="$2"

    # Search for base title
    local lidarrTitlesToSearch=()
    lidarrTitlesToSearch+=("${lidarrReleaseTitle}")

    _add_unique() {
        local value="$1"
        shift
        if [[ -z "${value}" ]]; then
            return 0
        fi
        for existing in "$@"; do
            [[ "$existing" == "$value" ]] && return 0 # already exists, do nothing
        done
        lidarrTitlesToSearch+=("$value")
    }

    # Search for title without edition suffixes
    local titleNoEditions=$(RemoveEditionsFromAlbumTitle "${lidarrReleaseTitle}")
    _add_unique "${titleNoEditions}" "${lidarrTitlesToSearch[@]}"

    # Search for title with release disambiguation
    local lidarrReleaseTitleWithReleaseDisambiguation="$(AddDisambiguationToTitle "${lidarrReleaseTitle}" "${lidarrReleaseDisambiguation}")"
    _add_unique "${lidarrReleaseTitleWithReleaseDisambiguation}" "${lidarrTitlesToSearch[@]}"

    # Search for title with album disambiguation
    local albumDisambiguation=$(get_state "lidarrAlbumDisambiguation")
    if [[ -n "${albumDisambiguation}" && "${albumDisambiguation}" != "null" && "${albumDisambiguation}" != "" ]]; then
        local lidarrTitleWithAlbumDisambiguation="$(AddDisambiguationToTitle "${lidarrReleaseTitle}" "${albumDisambiguation}")"
        _add_unique "${lidarrTitleWithAlbumDisambiguation}" "${lidarrTitlesToSearch[@]}"
    fi

    # Search for title without edition suffixes and added album disambiguation
    if [[ -n "${albumDisambiguation}" && "${albumDisambiguation}" != "null" && "${albumDisambiguation}" != "" ]]; then
        local titleNoEditionsWithAlbumDisambiguation="$(AddDisambiguationToTitle "${titleNoEditions}" "${albumDisambiguation}")"
        _add_unique "${titleNoEditionsWithAlbumDisambiguation}" "${lidarrTitlesToSearch[@]}"
    fi

    set_state "lidarrTitlesToSearch" "$(
        printf '%s\n' "${lidarrTitlesToSearch[@]}"
    )"
}

# Reset best match state variables
ResetBestMatch() {
    set_state "bestMatchID" ""
    set_state "bestMatchTitle" ""
    set_state "bestMatchYear" ""
    set_state "bestMatchDistance" 9999
    set_state "bestMatchTrackDiff" 9999
    set_state "bestMatchNumTracks" 0
    set_state "bestMatchContainsCommentary" "false"
    set_state "bestMatchLidarrReleaseInfo" ""
    set_state "bestMatchFormatPriority" ""
    set_state "bestMatchCountryPriority" ""
    set_state "bestMatchLyricTypePreferred" ""
    set_state "bestMatchYearDiff" -1
    set_state "exactMatchFound" "false"
}

# Determine if the current candidate is a better match than the best match so far
isBetterMatch() {
    local diff="$1"
    local trackDiff="$2"
    local deezerAlbumTrackCount="$3"
    local lyricTypePreferred="$4"
    local lidarrReleaseFormatPriority="$5"
    local lidarrReleaseCountryPriority="$6"
    local deezerAlbumYear="$7"

    local bestMatchDistance="$(get_state "bestMatchDistance")"
    local bestMatchTrackDiff="$(get_state "bestMatchTrackDiff")"
    local bestMatchNumTracks="$(get_state "bestMatchNumTracks")"
    local bestMatchLyricTypePreferred="$(get_state "bestMatchLyricTypePreferred")"
    local bestMatchFormatPriority="$(get_state "bestMatchFormatPriority")"
    local bestMatchCountryPriority="$(get_state "bestMatchCountryPriority")"
    local bestMatchYearDiff="$(get_state "bestMatchYearDiff")"

    # Get the expected release year from Lidarr
    local lidarrAlbumInfo="$(get_state "lidarrAlbumInfo")"
    local lidarrReleaseYear=$(get_state "lidarrReleaseYear")

    # Check if the current release year difference is better/worse/same than the best match so far
    # If the best match year diff is not set, any year diff is better
    # If the current year diff is not set, it is worse than any set year diff
    # If both are set, compare numerically
    local yearDiffEvaluation="worse"
    currentYearDiff=$(get_state "currentYearDiff")
    if [[ "${bestMatchYearDiff}" -eq -1 && "${currentYearDiff}" -ne -1 ]]; then
        yearDiffEvaluation="better"
    elif [[ "${bestMatchYearDiff}" -ne -1 && "${currentYearDiff}" -eq -1 ]]; then
        yearDiffEvaluation="worse"
    elif [[ "${bestMatchYearDiff}" -ne -1 && "${currentYearDiff}" -ne -1 ]]; then
        if ((currentYearDiff < bestMatchYearDiff)); then
            yearDiffEvaluation="better"
        elif ((currentYearDiff == bestMatchYearDiff)); then
            yearDiffEvaluation="same"
        else
            yearDiffEvaluation="worse"
        fi
    fi

    log "DEBUG :: Comparing candidate (Diff=${diff}, TrackDiff=${trackDiff}, YearDiff=${currentYearDiff} (${yearDiffEvaluation}), NumTracks=${deezerAlbumTrackCount}, LyricPreferred=${lyricTypePreferred}, FormatPriority=${lidarrReleaseFormatPriority}, CountryPriority=${lidarrReleaseCountryPriority}) against best match (Diff=${bestMatchDistance}, TrackDiff=${bestMatchTrackDiff}, YearDiff=${bestMatchYearDiff}, NumTracks=${bestMatchNumTracks}, LyricPreferred=${bestMatchLyricTypePreferred}, FormatPriority=${bestMatchFormatPriority}, CountryPriority=${bestMatchCountryPriority})"
    # Compare against current best-match globals
    # Return 0 (true) if current candidate is better, 1 (false) otherwise
    if ((diff < bestMatchDistance)); then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff < bestMatchTrackDiff)); then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "better" ]]; then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "same" ]] && ((deezerAlbumTrackCount > bestMatchNumTracks)); then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "same" ]] && ((deezerAlbumTrackCount == bestMatchNumTracks)) &&
        [[ "$lyricTypePreferred" == "true" && "$bestMatchLyricTypePreferred" == "false" ]]; then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "same" ]] && ((deezerAlbumTrackCount == bestMatchNumTracks)) &&
        [[ "$lyricTypePreferred" == "$bestMatchLyricTypePreferred" ]] &&
        ((lidarrReleaseFormatPriority < bestMatchFormatPriority)); then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "same" ]] && ((deezerAlbumTrackCount == bestMatchNumTracks)) &&
        [[ "$lyricTypePreferred" == "$bestMatchLyricTypePreferred" ]] &&
        ((lidarrReleaseFormatPriority == bestMatchFormatPriority)) &&
        ((lidarrReleaseCountryPriority < bestMatchCountryPriority)); then
        return 0
    fi

    return 1
}
