#!/usr/bin/env bash

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

# Check if album was previously marked as failed
AlbumPreviouslyFailed() {
    local deezerAlbumID="$1"

    if [ -f "${AUDIO_DATA_PATH}/failed/${deezerAlbumID}" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Apply title replacements from custom replacement rules
ApplyTitleReplacements() {
    local title="$1"

    # Check for custom replacement
    local replacement="$(get_state "titleReplacement_${title}")"
    if [[ -n "$replacement" ]]; then
        log "DEBUG :: Title matched replacement rule: \"${title}\" → \"${replacement}\""
        echo "${replacement}"
    else
        echo "${title}"
    fi
}

# Calculate year difference between two years (returns absolute value)
CalculateYearDifference() {
    local year1="$1"
    local year2="$2"

    # Return -1 if either year is invalid
    if [[ -z "${year1}" || "${year1}" == "null" || -z "${year2}" || "${year2}" == "null" ]]; then
        echo "-1"
        return
    fi

    local diff=$((year1 - year2))
    # Return absolute value
    echo "${diff#-}"
}

# Compute match metrics for a candidate album
ComputeMatchMetrics() {
    local searchReleaseTitleClean="$1"
    local candidateTitleVariant="$2"
    local lidarrReleaseTrackCount="$3"
    local deezerAlbumTrackCount="$4"

    # Calculate Levenshtein distance
    local distance=$(LevenshteinDistance "${searchReleaseTitleClean,,}" "${candidateTitleVariant,,}")
    set_state "candidateDistance" "${distance}"

    # Calculate track difference
    local trackDiff=$((lidarrReleaseTrackCount - deezerAlbumTrackCount))
    ((trackDiff < 0)) && trackDiff=$((-trackDiff))
    set_state "candidateTrackDiff" "${trackDiff}"
}

# Determine priority for a countries string based on AUDIO_PREFERRED_COUNTRIES
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

# Evaluate a single Deezer album candidate and update best match if better
EvaluateDeezerAlbumCandidate() {
    local deezerAlbumID="$1"
    local deezerAlbumTitle="$2"
    local deezerAlbumExplicitLyrics="$3"
    local searchReleaseTitleClean="$4"
    local lidarrReleaseTrackCount="$5"
    local lidarrReleaseFormatPriority="$6"
    local lidarrReleaseCountryPriority="$7"
    local lidarrReleaseContainsCommentary="$8"
    local lidarrReleaseInfo="$9"

    # Get album info from Deezer
    GetDeezerAlbumInfo "${deezerAlbumID}"
    local returnCode=$?
    if [ "$returnCode" -ne 0 ]; then
        log "WARNING :: Failed to fetch album info for Deezer album ID ${deezerAlbumID}, skipping..."
        return 1
    fi

    local deezerAlbumData="$(get_state "deezerAlbumInfo")"
    local deezerAlbumTrackCount=$(safe_jq .nb_tracks <<<"${deezerAlbumData}")
    local deezerReleaseYear=$(safe_jq .release_date <<<"${deezerAlbumData}")
    deezerReleaseYear="${deezerReleaseYear:0:4}"

    # Calculate year difference
    local lidarrReleaseYear=$(get_state "lidarrReleaseYear")
    local yearDiff=$(CalculateYearDifference "${deezerReleaseYear}" "${lidarrReleaseYear}")
    set_state "currentYearDiff" "${yearDiff}"

    # Get normalized titles
    NormalizeDeezerAlbumTitle "${deezerAlbumTitle}"
    local deezerAlbumTitleClean="$(get_state "deezerAlbumTitleClean")"
    local deezerAlbumTitleEditionless="$(get_state "deezerAlbumTitleEditionless")"

    log "DEBUG :: Comparing lidarr release \"${searchReleaseTitleClean}\" to Deezer album ID ${deezerAlbumID} with title \"${deezerAlbumTitleClean}\" (editionless: \"${deezerAlbumTitleEditionless}\" and explicit=${deezerAlbumExplicitLyrics})"

    # Check both with and without edition info
    local titlesToCheck=()
    titlesToCheck+=("${deezerAlbumTitleClean}")
    if [[ "${deezerAlbumTitleClean}" != "${deezerAlbumTitleEditionless}" ]]; then
        titlesToCheck+=("${deezerAlbumTitleEditionless}")
        log "DEBUG :: Checking both edition and editionless titles: \"${deezerAlbumTitleClean}\", \"${deezerAlbumTitleEditionless}\""
    fi

    for titleVariant in "${titlesToCheck[@]}"; do
        EvaluateTitleVariant \
            "${titleVariant}" \
            "${searchReleaseTitleClean}" \
            "${lidarrReleaseTrackCount}" \
            "${deezerAlbumTrackCount}" \
            "${deezerAlbumExplicitLyrics}" \
            "${deezerAlbumID}" \
            "${deezerReleaseYear}" \
            "${lidarrReleaseFormatPriority}" \
            "${lidarrReleaseCountryPriority}" \
            "${lidarrReleaseContainsCommentary}" \
            "${lidarrReleaseInfo}"
    done

    return 0
}

# Evaluate a single title variant against matching criteria
EvaluateTitleVariant() {
    local titleVariant="$1"
    local searchReleaseTitleClean="$2"
    local lidarrReleaseTrackCount="$3"
    local deezerAlbumTrackCount="$4"
    local deezerAlbumExplicitLyrics="$5"
    local deezerAlbumID="$6"
    local deezerReleaseYear="$7"
    local lidarrReleaseFormatPriority="$8"
    local lidarrReleaseCountryPriority="$9"
    local lidarrReleaseContainsCommentary="${10}"
    local lidarrReleaseInfo="${11}"

    # Compute match metrics
    ComputeMatchMetrics \
        "${searchReleaseTitleClean}" \
        "${titleVariant}" \
        "${lidarrReleaseTrackCount}" \
        "${deezerAlbumTrackCount}"

    local diff=$(get_state "candidateDistance")
    local trackDiff=$(get_state "candidateTrackDiff")

    # Check if meets threshold
    if ((diff > AUDIO_MATCH_DISTANCE_THRESHOLD)); then
        log "DEBUG :: Album \"${titleVariant,,}\" does not meet matching threshold (Distance=${diff}), skipping..."
        return 0
    fi

    local lidarrReleaseYear=$(get_state "lidarrReleaseYear")
    log "INFO :: Potential match found :: \"${titleVariant,,}\" :: Distance=${diff} TrackDiff=${trackDiff} LidarrYear=${lidarrReleaseYear}"

    # Check if lyric type is preferred
    local lyricTypeSetting="${AUDIO_LYRIC_TYPE:-}"
    local lyricTypePreferred=$(IsLyricTypePreferred "${deezerAlbumExplicitLyrics}" "${lyricTypeSetting}")

    # Check if this is a better match
    if IsBetterMatch "$diff" "$trackDiff" "$deezerAlbumTrackCount" "$lyricTypePreferred" "$lidarrReleaseFormatPriority" "$lidarrReleaseCountryPriority" "$deezerReleaseYear"; then
        # Check if previously failed
        local previouslyFailed=$(AlbumPreviouslyFailed "${deezerAlbumID}")
        if [[ "${previouslyFailed}" == "true" ]]; then
            log "WARNING :: Album \"${titleVariant}\" previously failed to download (deezer: ${deezerAlbumID})...Looking for a different match..."
            return 0
        fi

        # Update best match
        UpdateBestMatchState \
            "${deezerAlbumID}" \
            "${titleVariant}" \
            "${deezerReleaseYear}" \
            "${diff}" \
            "${trackDiff}" \
            "${deezerAlbumTrackCount}" \
            "${lyricTypePreferred}" \
            "${lidarrReleaseFormatPriority}" \
            "${lidarrReleaseCountryPriority}" \
            "${lidarrReleaseContainsCommentary}" \
            "${lidarrReleaseInfo}"
    fi

    return 0
}

# Extract album info from JSON and set state variables
ExtractAlbumInfo() {
    log "TRACE :: Entering ExtractAlbumInfo..."

    local album_json="$1"
    local lidarrAlbumTitle lidarrAlbumType lidarrAlbumForeignAlbumId
    lidarrAlbumTitle=$(safe_jq ".title" <<<"$album_json")
    lidarrAlbumType=$(safe_jq ".albumType" <<<"$album_json")
    lidarrAlbumForeignAlbumId=$(safe_jq ".foreignAlbumId" <<<"$album_json")

    # Extract disambiguation from album info
    local lidarrAlbumDisambiguation
    lidarrAlbumDisambiguation=$(safe_jq --optional ".disambiguation" <<<"$album_json")
    local albumReleaseYear
    local albumReleaseDate="$(safe_jq --optional '.releaseDate' <<<"${album_json}")"
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

    log "TRACE :: Exiting ExtractAlbumInfo..."
}

# Extract artist info from JSON and set state variables
ExtractArtistInfo() {
    log "TRACE :: Entering ExtractArtistInfo..."

    local artist_json="$1"
    local lidarrArtistName lidarrArtistForeignArtistId
    lidarrArtistName=$(safe_jq ".artistName" <<<"$artist_json")
    lidarrArtistForeignArtistId=$(safe_jq ".foreignArtistId" <<<"$artist_json")
    set_state "lidarrArtistInfo" "${artist_json}"
    set_state "lidarrArtistName" "${lidarrArtistName}"
    set_state "lidarrArtistForeignArtistId" "${lidarrArtistForeignArtistId}"

    log "TRACE :: Exiting ExtractArtistInfo..."
}

# Extract release info from JSON and set state variables
ExtractReleaseInfo() {
    log "TRACE :: Entering ExtractReleaseInfo..."

    local release_json="$1"
    local lidarrReleaseTitle="$(safe_jq ".title" <<<"${release_json}")"
    local lidarrReleaseDisambiguation="$(safe_jq --optional ".disambiguation" <<<"${release_json}")"
    local lidarrReleaseTrackCount="$(safe_jq ".trackCount" <<<"${release_json}")"
    local lidarrReleaseForeignId="$(safe_jq ".foreignReleaseId" <<<"${release_json}")"
    local lidarrReleaseFormat="$(safe_jq ".format" <<<"${release_json}")"
    local lidarrReleaseCountries="$(safe_jq --optional '.country // [] | join(",")' <<<"${release_json}")"
    local lidarrReleaseFormatPriority="$(FormatPriority "${lidarrReleaseFormat}" "${AUDIO_PREFERRED_FORMATS}")"
    local lidarrReleaseCountryPriority="$(CountriesPriority "${lidarrReleaseCountries}" "${AUDIO_PREFERRED_COUNTRIES}")"
    local lidarrReleaseDate=$(safe_jq --optional '.releaseDate' <<<"${release_json}")
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

    log "TRACE :: Exiting ExtractReleaseInfo..."
}

# Determine priority for a format string based on AUDIO_PREFERRED_FORMATS
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

# Determine if the current candidate is a better match than the best match so far
IsBetterMatch() {
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

# Check if lyric type is preferred based on AUDIO_LYRIC_TYPE setting
IsLyricTypePreferred() {
    local explicitLyrics="$1"
    local lyricTypeSetting="$2"

    case "${lyricTypeSetting}" in
    prefer-clean)
        if [ "${explicitLyrics}" == "true" ]; then
            echo "false"
        else
            echo "true"
        fi
        ;;
    prefer-explicit)
        if [ "${explicitLyrics}" == "false" ]; then
            echo "false"
        else
            echo "true"
        fi
        ;;
    *)
        echo "true"
        ;;
    esac
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

# Normalize a Deezer album title (truncate and apply replacements)
NormalizeDeezerAlbumTitle() {
    local deezerAlbumTitle="$1"

    # Normalize title
    local titleClean="$(normalize_string "$deezerAlbumTitle")"
    titleClean="${titleClean:0:130}"

    # Get editionless version
    local titleEditionless="$(RemoveEditionsFromAlbumTitle "${titleClean}")"

    # Apply replacements to both versions
    titleClean="$(ApplyTitleReplacements "${titleClean}")"
    titleEditionless="$(ApplyTitleReplacements "${titleEditionless}")"

    # Return both as newline-separated values
    set_state "deezerAlbumTitleClean" "${titleClean}"
    set_state "deezerAlbumTitleEditionless" "${titleEditionless}"
}

# Remove common edition keywords from the end of an album title
RemoveEditionsFromAlbumTitle() {
    local title="$1"

    # Define patterns to remove (case-insensitive match later)
    local patterns=(
        "Deluxe Edition"
        "Deluxe Version"
        "Super Deluxe Version"
        "Super Deluxe Edition"
        "Collector's Edition"
        "Platinum Edition"
        "Special Edition"
        "Limited Edition"
        "Expanded Edition"
        "Remastered"
        "Anniversary Edition"
        "Deluxe"
        "Super Deluxe"
        "Original Motion Picture Soundtrack"
    )

    # Normalize spacing
    title="${title//  / }"

    # Parenthesized version: (45th Anniversary Edition)
    if [[ "$title" =~ ^(.*)\([[:space:]]*[0-9]+(st|nd|rd|th)[[:space:]]+Anniversary([[:space:]]+(Edition|Version))?[[:space:]]*\)(.*)$ ]]; then
        title="${BASH_REMATCH[1]}${BASH_REMATCH[5]}"
    fi

    # Plain version: 45th Anniversary Edition
    if [[ "$title" =~ ^(.*)[[:space:]]+[0-9]+(st|nd|rd|th)[[:space:]]+Anniversary([[:space:]]+(Edition|Version))?(.*)$ ]]; then
        title="${BASH_REMATCH[1]}${BASH_REMATCH[5]}"
    fi

    # Remove patterns
    for pattern in "${patterns[@]}"; do
        title="${title% - $pattern}"        # - PATTERN
        title="${title//\($pattern\)/}"     # (PATTERN)
        title="${title// \/ $pattern)/\)}"  #  / PATTERN)
        title="${title//\/$pattern)/\)}"    # /PATTERN)
        title="${title//\($pattern \/ /\(}" # (PATTERN /
        title="${title//\($pattern\//\(}"   # (PATTERN/
        title="${title//\[$pattern\]/}"     # [PATTERN]
        title="${title// \/ $pattern]/\)}"  #  / PATTERN]
        title="${title//\/$pattern]/\)}"    # /PATTERN]
        title="${title//\[$pattern \/ /\(}" # [PATTERN /
        title="${title//\[$pattern\//\(}"   # [PATTERN/
        title="${title// \/ $pattern/}"     # / PATTERN
        title="${title//\/$pattern/}"       # /PATTERN
        title="${title//$pattern \/ /}"     # PATTERN /
        title="${title//$pattern\/ /}"      # PATTERN/
        title="${title/% $pattern/}"        #  PATTERN

        # Clean up malformed parentheses
        title="${title//\( \/ /\(}"
        title="${title// \/ \)/\)}"
        title="${title//\( \)/}"
        title="${title//\(\)/}"

        # Trim spaces
        title="${title#"${title%%[![:space:]]*}"}"
        title="${title%"${title##*[![:space:]]}"}"
    done

    echo "$title"
}

# Remove a pattern from an album title
RemovePatternFromAlbumTitle() {
    local title="$1"
    local pattern="$2"

    # Normalize spacing
    title="${title//  / }"

    # Remove patterns
    title="${title% - $pattern}"        # - PATTERN
    title="${title//\($pattern\)/}"     # (PATTERN)
    title="${title// \/ $pattern)/\)}"  #  / PATTERN)
    title="${title//\/$pattern)/\)}"    # /PATTERN)
    title="${title//\($pattern \/ /\(}" # (PATTERN /
    title="${title//\($pattern\//\(}"   # (PATTERN/
    title="${title//\[$pattern\]/}"     # [PATTERN]
    title="${title// \/ $pattern]/\]}"  #  / PATTERN]
    title="${title//\/$pattern]/\]}"    # /PATTERN]
    title="${title//\[$pattern \/ /\[}" # [PATTERN /
    title="${title//\[$pattern\//\[}"   # [PATTERN/
    title="${title// \/ $pattern/}"     # / PATTERN
    title="${title//\/$pattern/}"       # /PATTERN
    title="${title//$pattern \/ /}"     # PATTERN /
    title="${title//$pattern\//}"       # PATTERN/
    title="${title/% $pattern/}"        #  PATTERN

    # Handle ANY leading enclosure
    title="${title//\($pattern\//\(}"
    title="${title//\($pattern \/ /\(}"
    title="${title//\[$pattern\//\[}"
    title="${title//\[$pattern \/ /\[}"

    # Handle ANY trailing enclosure
    title="${title//\/$pattern\)/\)}"
    title="${title// \/ $pattern\)/\)}"
    title="${title//\/$pattern\]/\]}"
    title="${title// \/ $pattern\]/\]}"

    # Trim spaces
    title="${title#"${title%%[![:space:]]*}"}"
    title="${title%"${title##*[![:space:]]}"}"

    echo "$title"
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

# Check if an album should be skipped based on lyric type filter
ShouldSkipAlbumByLyricType() {
    local explicitLyrics="$1"
    local lyricTypeSetting="$2"

    if [[ "${lyricTypeSetting}" == "require-clean" && "${explicitLyrics}" == "true" ]]; then
        echo "true"
    elif [[ "${lyricTypeSetting}" == "require-explicit" && "${explicitLyrics}" == "false" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# Update best match state with new candidate
UpdateBestMatchState() {
    local deezerAlbumID="$1"
    local titleVariant="$2"
    local deezerReleaseYear="$3"
    local diff="$4"
    local trackDiff="$5"
    local deezerAlbumTrackCount="$6"
    local lyricTypePreferred="$7"
    local lidarrReleaseFormatPriority="$8"
    local lidarrReleaseCountryPriority="$9"
    local lidarrReleaseContainsCommentary="${10}"
    local lidarrReleaseInfo="${11}"

    set_state "bestMatchID" "${deezerAlbumID}"
    set_state "bestMatchTitle" "${titleVariant}"
    set_state "bestMatchYear" "${deezerReleaseYear}"
    set_state "bestMatchDistance" "${diff}"
    set_state "bestMatchTrackDiff" "${trackDiff}"
    set_state "bestMatchNumTracks" "${deezerAlbumTrackCount}"
    set_state "bestMatchFormatPriority" "${lidarrReleaseFormatPriority}"
    set_state "bestMatchCountryPriority" "${lidarrReleaseCountryPriority}"
    set_state "bestMatchLyricTypePreferred" "${lyricTypePreferred}"
    set_state "bestMatchContainsCommentary" "${lidarrReleaseContainsCommentary}"
    set_state "bestMatchLidarrReleaseInfo" "${lidarrReleaseInfo}"
    set_state "bestMatchYearDiff" "$(get_state "currentYearDiff")"

    log "INFO :: New best match :: ${titleVariant} (${deezerReleaseYear}) :: Distance=${diff} TrackDiff=${trackDiff} NumTracks=${deezerAlbumTrackCount} YearDiff=$(get_state "currentYearDiff") LyricPreferred=${lyricTypePreferred} FormatPriority=${lidarrReleaseFormatPriority} CountryPriority=${lidarrReleaseCountryPriority}"

    # Check for exact match
    if ((diff == 0 && trackDiff == 0)); then
        log "INFO :: Exact match found :: ${titleVariant} (${deezerReleaseYear}) with ${deezerAlbumTrackCount} tracks"
        set_state "exactMatchFound" "true"
    fi
}
