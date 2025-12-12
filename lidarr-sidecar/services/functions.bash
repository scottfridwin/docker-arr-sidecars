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
# Returns 0 (true) if album previously failed, 1 (false) otherwise
AlbumPreviouslyFailed() {
    local deezerAlbumID="$1"

    if [ -f "${AUDIO_DATA_PATH}/failed/${deezerAlbumID}" ]; then
        return 0
    else
        return 1
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

# Determine priority for a string based on preferences
CalculatePriority() {
    local input="$1"
    local prefs="$2"

    perl -e '
        use strict;
        use warnings;

        my ($input, $prefs) = @ARGV;

        # --- Split input tokens (always comma-separated) and normalize ---
        my @input_tokens = map {
            my $t = $_;
            $t =~ s/^"+|"+$//g;      # remove quotes
            $t =~ s/^\s+|\s+$//g;    # trim spaces
            lc($t)
        } split /,/, $input // "";
        @input_tokens = ("") unless @input_tokens;

        # --- Split prefs into groups by comma ---
        my @groups = split /,/, $prefs // "";

        my %priority;
        my $prio = 0;
        for my $grp (@groups) {
            next unless length $grp;
            # split group by | and normalize each token
            my @tokens = map {
                my $t = $_;
                $t =~ s/^"+|"+$//g;
                $t =~ s/^\s+|\s+$//g;
                lc($t)
            } split /\|/, $grp;

            for my $tok (@tokens) {
                next unless length $tok;
                $priority{$tok} //= $prio;   # first occurrence wins
            }
            $prio++;
        }

        # --- Find lowest priority matching input token ---
        my $best = 999;
        for my $tok (@input_tokens) {
            $best = $priority{$tok} if exists $priority{$tok} && $priority{$tok} < $best;
        }

        print $best;
    ' "$input" "$prefs"
}

# Calculate year difference between two years (returns absolute value)
CalculateYearDifference() {
    local year1="$1"
    local year2="$2"

    # Return 999 if either year is invalid to indicate uncalcuable difference
    if [[ -z "${year1}" || "${year1}" == "null" || -z "${year2}" || "${year2}" == "null" ]]; then
        echo "999"
        return
    fi

    local diff=$((year1 - year2))
    # Return absolute value
    echo "${diff#-}"
}

# Generic MusicBrainz API caller
# TODO: UnitTest
CallMusicBrainzAPI() {
    local url="$1"

    # Required by MusicBrainz: MUST identify client
    local mbUserAgent="MyApp/1.0.0 ( my-email@example.com )"

    local attempts=0
    local maxAttempts=10
    local backoff=5

    local response curlExit httpCode body

    while ((attempts < maxAttempts)); do
        ((attempts++))

        log "DEBUG :: Calling MusicBrainz API (${attempts}/${maxAttempts}): ${url}"

        # Run curl with:
        #   -S : show errors
        #   -s : silent otherwise
        #   timeouts: prevent hangs
        response="$(
            curl -sS \
                --connect-timeout 5 \
                --max-time 10 \
                -H "User-Agent: ${mbUserAgent}" \
                -H "Accept: application/json" \
                -w "\n%{http_code}" \
                "${url}" 2>&1
        )"

        curlExit=$?
        log "TRACE :: curl exit code: ${curlExit}"

        # On total failure, retry
        if ((curlExit != 0)); then
            log "WARNING :: curl failed (exit ${curlExit}). Retrying..."
            sleep ${backoff}
            backoff=$((backoff * 2))
            continue
        fi

        httpCode=$(tail -n1 <<<"${response}")
        body=$(sed '$d' <<<"${response}")

        log "DEBUG :: HTTP response code: ${httpCode}"
        log "TRACE :: HTTP response body: ${body}"

        case "$httpCode" in
        200)
            # Validate JSON
            if safe_jq --optional '.' <<<"${body}" >/dev/null 2>&1; then
                set_state "musicBrainzApiResponse" "${body}"
                return 0
            else
                log "WARNING :: Invalid JSON from MusicBrainz. Retrying..."
            fi
            ;;
        503)
            # MusicBrainz rate limits heavily
            log "WARNING :: MusicBrainz returned 503. Backing off..."
            sleep ${backoff}
            backoff=$((backoff * 2))
            ;;
        429)
            log "WARNING :: HTTP 429 (Too Many Requests). Backing off..."
            sleep ${backoff}
            backoff=$((backoff * 2))
            ;;
        5*)
            log "WARNING :: Server error ${httpCode}. Retrying..."
            sleep ${backoff}
            backoff=$((backoff * 2))
            ;;
        *)
            log "WARNING :: Unexpected HTTP ${httpCode} from MusicBrainz"
            break
            ;;
        esac
    done

    # Failed completely
    log "ERROR :: CallMusicBrainzAPI failed after ${maxAttempts} attempts"
    setUnhealthy
    exit 1
}

# Compute match metrics for a candidate album
ComputePrimaryMatchMetrics() {
    # Calculate name difference
    local searchReleaseTitleClean="$(get_state "searchReleaseTitleClean")"
    local deezerCandidateTitleVariant="$(get_state "deezerCandidateTitleVariant")"
    if [[ "${AUDIO_MATCH_THRESHOLD_TITLE}" == "0" ]]; then
        if [[ "${searchReleaseTitleClean,,}" == "${deezerCandidateTitleVariant,,}" ]]; then
            set_state "candidateNameDiff" "0"
        else
            set_state "candidateNameDiff" "999"
        fi
    else
        set_state "candidateNameDiff" "$(LevenshteinDistance "${searchReleaseTitleClean,,}" "${deezerCandidateTitleVariant,,}")"
    fi

    # Calculate track difference
    local lidarrReleaseTrackCount="$(get_state "lidarrReleaseTrackCount")"
    local deezerCandidateTrackCount="$(get_state "deezerCandidateTrackCount")"
    local trackDiff=$((lidarrReleaseTrackCount - deezerCandidateTrackCount))
    ((trackDiff < 0)) && trackDiff=$((-trackDiff))
    set_state "candidateTrackDiff" "${trackDiff}"

    # Calculate year difference
    local lidarrReleaseYear=$(get_state "lidarrReleaseYear")
    local deezerCandidateReleaseYear="$(get_state "deezerCandidateReleaseYear")"
    local yearDiff=$(CalculateYearDifference "${deezerCandidateReleaseYear}" "${lidarrReleaseYear}")
    set_state "candidateYearDiff" "${yearDiff}"
}

# Evaluate a single Deezer album candidate and update best match if better
# TODO: UnitTest
EvaluateDeezerAlbumCandidate() {
    local deezerCandidateAlbumID="$(get_state "deezerCandidateAlbumID")"
    local searchReleaseTitleClean="$(get_state "searchReleaseTitleClean")"
    local lidarrReleaseTrackCount="$(get_state "lidarrReleaseTrackCount")"
    local lidarrReleaseFormatPriority="$(get_state "lidarrReleaseFormatPriority")"
    local lidarrReleaseForeignId="$(get_state "lidarrReleaseForeignId")"
    local lidarrReleaseCountryPriority="$(get_state "lidarrReleaseCountryPriority")"
    local lidarrReleaseContainsCommentary="$(get_state "lidarrReleaseContainsCommentary")"
    local lidarrReleaseInfo="$(get_state "lidarrReleaseInfo")"

    # Get album info from Deezer
    GetDeezerAlbumInfo "${deezerCandidateAlbumID}"
    local returnCode=$?
    if [ "$returnCode" -ne 0 ]; then
        log "WARNING :: Failed to fetch album info for Deezer album ID ${deezerCandidateAlbumID}, skipping..."
        return
    fi

    # Extract candidate information
    local deezerAlbumData="$(get_state "deezerAlbumInfo")"
    local deezerCandidateTitle=$(jq -r ".title" <<<"${deezerAlbumData}")
    local deezerCandidateIsExplicit=$(jq -r ".explicit_lyrics" <<<"${deezerAlbumData}")
    local deezerCandidateTrackCount=$(safe_jq .nb_tracks <<<"${deezerAlbumData}")
    local deezerCandidateReleaseYear=$(safe_jq .release_date <<<"${deezerAlbumData}")
    deezerCandidateReleaseYear="${deezerCandidateReleaseYear:0:4}"
    set_state "deezerCandidateTrackCount" "${deezerCandidateTrackCount}"
    set_state "deezerCandidateReleaseYear" "${deezerCandidateReleaseYear}"
    set_state "deezerCandidateIsExplicit" "${deezerCandidateIsExplicit}"
    set_state "deezerCandidateTitle" "${deezerCandidateTitle}"

    local lyricTypeSetting="${AUDIO_LYRIC_TYPE:-}"
    local deezerCandidatelyricTypePreferred=$(IsLyricTypePreferred "${deezerCandidateIsExplicit}" "${lyricTypeSetting}")
    set_state "deezerCandidatelyricTypePreferred" "${deezerCandidatelyricTypePreferred}"

    # Skip albums that don't match the lyric type filter
    local shouldSkip=$(ShouldSkipAlbumByLyricType "${deezerCandidateIsExplicit}" "${AUDIO_LYRIC_TYPE:-}")
    if [[ "${shouldSkip}" == "true" ]]; then
        log "DEBUG :: Skipping Deezer album ID ${deezerCandidateAlbumID} (${deezerCandidateTitle}) due to lyric type filter"
        return
    fi

    # Calculate year difference
    local lidarrReleaseYear=$(get_state "lidarrReleaseYear")
    local yearDiff=$(CalculateYearDifference "${deezerCandidateReleaseYear}" "${lidarrReleaseYear}")
    set_state "candidateYearDiff" "${yearDiff}"

    # Get normalized titles
    NormalizeDeezerAlbumTitle "${deezerCandidateTitle}"
    local deezerCandidateTitleClean="$(get_state "deezerCandidateTitleClean")"
    local deezerCandidateTitleEditionless="$(get_state "deezerCandidateTitleEditionless")"

    log "DEBUG :: Comparing lidarr release \"${searchReleaseTitleClean}\" (${lidarrReleaseForeignId}) to Deezer album \"${deezerCandidateTitleClean}\" (${deezerCandidateAlbumID})"

    # Check both with and without edition info
    local titlesToCheck=()
    titlesToCheck+=("${deezerCandidateTitleClean}")
    if [[ "${deezerCandidateTitleClean}" != "${deezerCandidateTitleEditionless}" ]]; then
        titlesToCheck+=("${deezerCandidateTitleEditionless}")
        log "DEBUG :: Checking both edition and editionless titles: \"${deezerCandidateTitleClean}\", \"${deezerCandidateTitleEditionless}\""
    fi

    for titleVariant in "${titlesToCheck[@]}"; do
        set_state "deezerCandidateTitleVariant" "${titleVariant}"
        EvaluateTitleVariant
    done

    return
}

# Evaluate a single title variant against matching criteria
EvaluateTitleVariant() {

    # Compute match metrics
    ComputePrimaryMatchMetrics

    local candidateNameDiff=$(get_state "candidateNameDiff")
    local candidateTrackDiff=$(get_state "candidateTrackDiff")
    local candidateYearDiff=$(get_state "candidateYearDiff")

    # Check if meets thresholds
    local deezerCandidateTitleVariant="$(get_state "deezerCandidateTitleVariant")"
    if ((candidateNameDiff > AUDIO_MATCH_THRESHOLD_TITLE)); then
        log "DEBUG :: Album \"${deezerCandidateTitleVariant,,}\" does not meet matching threshold (NameDiff=${candidateNameDiff}), skipping..."
        return 0
    fi
    if ((candidateTrackDiff > AUDIO_MATCH_THRESHOLD_TRACKS)); then
        log "DEBUG :: Album \"${deezerCandidateTitleVariant,,}\" does not meet matching threshold (Track Difference=${candidateTrackDiff}), skipping..."
        return 0
    fi

    local lidarrReleaseYear=$(get_state "lidarrReleaseYear")
    local deezerCandidateAlbumID="$(get_state "deezerCandidateAlbumID")"
    log "INFO :: Potential match found: \"${deezerCandidateTitleVariant,,}\" (${deezerCandidateAlbumID})"
    log "DEBUG :: Match details: NameDiff=${candidateNameDiff} TrackDiff=${candidateTrackDiff} YearDiff=${candidateYearDiff}"

    # Check if this is a better match
    if IsBetterMatch; then
        # Check if previously failed
        local deezerCandidateAlbumID="$(get_state "deezerCandidateAlbumID")"
        if AlbumPreviouslyFailed "${deezerCandidateAlbumID}"; then
            log "WARNING :: Album \"${deezerCandidateTitleVariant}\" previously failed to download (deezer: ${deezerCandidateAlbumID})...Looking for a different match..."
            return 0
        fi

        # Update best match
        UpdateBestMatchState
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
    local lidarrReleaseFormatPriority="$(CalculatePriority "${lidarrReleaseFormat}" "${AUDIO_PREFERRED_FORMATS}")"
    local lidarrReleaseCountryPriority="$(CalculatePriority "${lidarrReleaseCountries}" "${AUDIO_PREFERRED_COUNTRIES}")"
    local lidarrReleaseDate=$(safe_jq --optional '.releaseDate' <<<"${release_json}")
    local lidarrReleaseYear=""
    local albumReleaseYear="$(get_state "lidarrAlbumReleaseYear")"

    # Get up-to-date musicbrainz information
    FetchMusicBrainzReleaseInfo "$lidarrReleaseForeignId"
    local mbJson="$(get_state "musicbrainzReleaseJson")"

    if [ -n "${lidarrReleaseDate}" ] && [ "${lidarrReleaseDate}" != "null" ]; then
        lidarrReleaseYear="${lidarrReleaseDate:0:4}"
    else
        local mb_year="$(safe_jq --optional '.date' <<<"$mbJson")"
        if [[ -n "$mb_year" ]]; then
            mb_year="${mb_year:0:4}"
            lidarrReleaseYear="$mb_year"
        elif [ -n "${albumReleaseYear}" ] && [ "${albumReleaseYear}" != "null" ]; then
            lidarrReleaseYear="${albumReleaseYear}"
        else
            lidarrReleaseYear=""
        fi
    fi

    # Check for commentary keywords
    IFS=',' read -r -a commentaryArray <<<"${AUDIO_COMMENTARY_KEYWORDS}"
    lowercaseKeywords=()
    for kw in "${commentaryArray[@]}"; do
        lowercaseKeywords+=("${kw,,}")
    done

    commentaryPattern="($(
        IFS='|'
        echo "${lowercaseKeywords[*]}"
    ))"
    local lidarrReleaseContainsCommentary="false"
    if [[ "${lidarrReleaseTitle,,}" =~ ${commentaryPattern,,} ]]; then
        log "DEBUG :: Release title \"${lidarrReleaseTitle}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
        lidarrReleaseContainsCommentary="true"
    elif [[ "${lidarrReleaseDisambiguation,,}" =~ ${commentaryPattern,,} ]]; then
        log "DEBUG :: Release disambiguation \"${lidarrReleaseDisambiguation}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
        lidarrReleaseContainsCommentary="true"
    else
        # Check track names
        while IFS= read -r track_title; do
            # Skip blank (just in case safe_jq returns empty)
            [[ -z "$track_title" ]] && continue
            if [[ "${track_title,,}" =~ ${commentaryPattern,,} ]]; then
                log "DEBUG :: track \"${track_title}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
                lidarrReleaseContainsCommentary="true"
                break
            fi
        done < <(
            safe_jq --optional -r '
        .media[]?.tracks[]?.title // empty
    ' <<<"$mbJson"
        )
    fi

    set_state "lidarrReleaseContainsCommentary" "${lidarrReleaseContainsCommentary}"
    set_state "lidarrReleaseInfo" "${release_json}"
    set_state "lidarrReleaseTitle" "${lidarrReleaseTitle}"
    set_state "lidarrReleaseDisambiguation" "${lidarrReleaseDisambiguation}"
    set_state "lidarrReleaseTrackCount" "${lidarrReleaseTrackCount}"
    set_state "lidarrReleaseForeignId" "${lidarrReleaseForeignId}"
    set_state "lidarrReleaseFormatPriority" "${lidarrReleaseFormatPriority}"
    set_state "lidarrReleaseCountryPriority" "${lidarrReleaseCountryPriority}"
    set_state "lidarrReleaseYear" "${lidarrReleaseYear}"
    set_state "lidarrReleaseMBJson" "${mbJson}"

    log "TRACE :: Exiting ExtractReleaseInfo..."
}

# Fetch MusicBrainz release JSON with caching
# TODO: UnitTest
FetchMusicBrainzReleaseInfo() {
    local mbid="$1"

    if [[ -z "$mbid" || "$mbid" == "null" ]]; then
        set_state "musicbrainzReleaseJson" ""
        return 0
    fi

    local url="https://musicbrainz.org/ws/2/release/${mbid}?fmt=json&inc=recordings"
    local cacheFile="${AUDIO_WORK_PATH}/cache/mb-release-${mbid}.json"

    mkdir -p "${AUDIO_WORK_PATH}/cache"

    # Try cache first
    if [[ -f "${cacheFile}" ]] &&
        safe_jq --optional '.' <"${cacheFile}" >/dev/null 2>&1; then
        log "DEBUG :: Using cached MB release for ${mbid}"
        set_state "musicbrainzReleaseJson" "$(<"${cacheFile}")"
        return 0
    fi

    # API fetch using generic helper
    if CallMusicBrainzAPI "${url}" "musicbrainzReleaseJson"; then
        json="$(get_state "musicBrainzApiResponse")"
        set_state "musicbrainzReleaseJson" "${json}"
        echo "${json}" >"${cacheFile}"
        return 0
    fi

    return 1
}

# Determine if the current candidate is a better match than the best match so far
# Returns 0 (true) if candidate is a better match, 1 (false) otherwise
IsBetterMatch() {
    local candidateNameDiff=$(get_state "candidateNameDiff")
    local candidateTrackDiff=$(get_state "candidateTrackDiff")
    local candidateYearDiff=$(get_state "candidateYearDiff")
    local deezerCandidateTrackCount="$(get_state "deezerCandidateTrackCount")"
    local lidarrReleaseFormatPriority="$(get_state "lidarrReleaseFormatPriority")"
    local lidarrReleaseCountryPriority="$(get_state "lidarrReleaseCountryPriority")"
    local deezerCandidatelyricTypePreferred="$(get_state "deezerCandidatelyricTypePreferred")"

    local bestMatchNameDiff="$(get_state "bestMatchNameDiff")"
    local bestMatchTrackDiff="$(get_state "bestMatchTrackDiff")"
    local bestMatchYearDiff="$(get_state "bestMatchYearDiff")"
    local bestMatchNumTracks="$(get_state "bestMatchNumTracks")"
    local bestMatchLyricTypePreferred="$(get_state "bestMatchLyricTypePreferred")"
    local bestMatchFormatPriority="$(get_state "bestMatchFormatPriority")"
    local bestMatchCountryPriority="$(get_state "bestMatchCountryPriority")"

    # Compare against current best-match globals
    log "DEBUG :: Comparing candidate (NameDiff=${candidateNameDiff}, TrackDiff=${candidateTrackDiff}, YearDiff=${candidateYearDiff}, NumTracks=${deezerCandidateTrackCount}, LyricPreferred=${deezerCandidatelyricTypePreferred}, FormatPriority=${lidarrReleaseFormatPriority}, CountryPriority=${lidarrReleaseCountryPriority}) against best match (Diff=${bestMatchNameDiff}, TrackDiff=${bestMatchTrackDiff}, YearDiff=${bestMatchYearDiff}, NumTracks=${bestMatchNumTracks}, LyricPreferred=${bestMatchLyricTypePreferred}, FormatPriority=${bestMatchFormatPriority}, CountryPriority=${bestMatchCountryPriority})"

    # Primary match criteria
    # 1. Name difference
    # 2. Track number difference
    # 3. Published year difference
    if ((candidateNameDiff < bestMatchNameDiff)); then
        return 0
    elif ((candidateNameDiff == bestMatchNameDiff)) && ((candidateTrackDiff < bestMatchTrackDiff)); then
        return 0
    elif ((candidateNameDiff == bestMatchNameDiff)) && ((candidateTrackDiff == bestMatchTrackDiff)) && (($candidateYearDiff < bestMatchYearDiff)); then
        return 0
    elif ((candidateNameDiff == bestMatchNameDiff)) && ((candidateTrackDiff == bestMatchTrackDiff)) && ((candidateYearDiff == bestMatchYearDiff)); then
        # Secondary criteria
        # 1. Release country
        # 2. Track count
        # 3. Release format
        # 4. Lyric preference
        if ((lidarrReleaseCountryPriority < bestMatchCountryPriority)); then
            return 0
        elif ((lidarrReleaseCountryPriority == bestMatchCountryPriority)) && ((deezerCandidateTrackCount > bestMatchNumTracks)); then
            return 0
        elif ((lidarrReleaseCountryPriority == bestMatchCountryPriority)) && ((deezerCandidateTrackCount == bestMatchNumTracks)) && ((lidarrReleaseFormatPriority < bestMatchFormatPriority)); then
            return 0
        elif ((lidarrReleaseCountryPriority == bestMatchCountryPriority)) && ((deezerCandidateTrackCount == bestMatchNumTracks)) && ((lidarrReleaseFormatPriority == bestMatchFormatPriority)) && [[ "$deezerCandidatelyricTypePreferred" == "true" && "$bestMatchLyricTypePreferred" == "false" ]]; then
            return 0
        fi
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
    local deezerCandidateTitle="$1"

    # Normalize title
    local titleClean="$(normalize_string "$deezerCandidateTitle")"
    titleClean="${titleClean:0:130}"

    # Get editionless version
    local titleEditionless="$(RemoveEditionsFromAlbumTitle "${titleClean}")"

    # Apply replacements to both versions
    titleClean="$(ApplyTitleReplacements "${titleClean}")"
    titleEditionless="$(ApplyTitleReplacements "${titleEditionless}")"

    # Return both as newline-separated values
    set_state "deezerCandidateTitleClean" "${titleClean}"
    set_state "deezerCandidateTitleEditionless" "${titleEditionless}"
}

# Remove common edition keywords from the end of an album title
RemoveEditionsFromAlbumTitle() {
    local title="$1"
    local lower="${title,,}" # lowercase once

    # Ordered patterns
    local patterns=(
        "super deluxe version"
        "super deluxe edition"
        "deluxe edition"
        "deluxe version"
        "super deluxe"
        "deluxe"
        "collector's edition"
        "platinum edition"
        "special edition"
        "limited edition"
        "expanded edition"
        "remastered"
        "anniversary edition"
        "original motion picture soundtrack"
    )

    # Handle numeric Anniversary patterns FIRST
    if [[ "$title" =~ ^(.*)\([[:space:]]*[0-9]+(st|nd|rd|th)[[:space:]]+Anniversary([[:space:]]+(Edition|Version))?[[:space:]]*\)(.*)$ ]]; then
        title="${BASH_REMATCH[1]}${BASH_REMATCH[5]}"
    fi

    if [[ "$title" =~ ^(.*)[[:space:]]+[0-9]+(st|nd|rd|th)[[:space:]]+Anniversary([[:space:]]+(Edition|Version))?(.*)$ ]]; then
        title="${BASH_REMATCH[1]}${BASH_REMATCH[5]}"
    fi

    # Filter only patterns that exist in the title
    local p
    for p in "${patterns[@]}"; do
        if [[ "$lower" == *"$p"* ]]; then
            # Call your existing complex logic
            title=$(RemovePatternFromAlbumTitle "$title" "$p")
        fi
    done

    printf '%s\n' "$title"
}

# Remove a pattern from an album title
RemovePatternFromAlbumTitle() {
    local title="$1"
    local pattern="$2"

    # Escape pattern for literal use in regex
    local esc
    esc="$(printf '%s\n' "$pattern" | sed 's/[][\^$.*/]/\\&/g')"

    title="$(
        perl -pe "
            my \$esc = q{$esc};

            # 1. Remove containers that consist ONLY of the pattern
            s/\((?:\s*\$esc\s*)\)//ig;
            s/\[(?:\s*\$esc\s*)\]//ig;

            # 2. Remove pattern in containers with separators, keep other side
            s/\(\s*\$esc\s*[\|\/:\-]\s*([^)]+)\)/(\\1)/ig;
            s/\(\s*([^)]+)\s*[\|\/:\-]\s*\$esc\s*\)/(\\1)/ig;

            s/\[\s*\$esc\s*[\|\/:\-]\s*([^\]]+)\]/[\\1]/ig;
            s/\[\s*([^\]]+)\s*[\|\/:\-]\s*\$esc\s*\]/[\\1]/ig;

            # 3. Top-level separators
            s/\b\$esc\s*[\|\/:\-]\s*([A-Za-z0-9]+)/\\1/ig;
            s/([A-Za-z0-9]+)\s*[\|\/:\-]\s*\$esc\b/\\1/ig;

            # 4. Standalone pattern removal
            s/\b\$esc\b//ig;
            s/[:\-\|\/]\s*\$esc\b//ig;

            # 5. Remove empty containers
            s/\(\s*\)//g;
            s/\[\s*\]//g;

            # 6. Normalize spacing and punctuation
            s/\s{2,}/ /g;
            s/\(\s+/\(/g;
            s/\s+\)/\)/g;
            s/\[\s+/\[/g;
            s/\s+\]/\]/g;
            s/^\s+|\s+$//g;
        " <<<"$title"
    )"

    printf '%s\n' "$title"
}

# Reset best match state variables
ResetBestMatch() {
    set_state "bestMatchID" ""
    set_state "bestMatchTitle" ""
    set_state "bestMatchYear" ""
    set_state "bestMatchNameDiff" 9999
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

# Determine if a release should be skipped
# Returns 0 (true) if candidate should be skipped, 1 (false) otherwise
SkipReleaseCandidate() {
    # Optionally de-prioritize releases that contain commentary tracks
    bestMatchContainsCommentary=$(get_state "bestMatchContainsCommentary")
    lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
    if [[ "${AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES}" == "true" ]]; then
        if [[ "${lidarrReleaseContainsCommentary}" == "true" && "${bestMatchContainsCommentary}" == "false" ]]; then
            log "DEBUG :: Current candidate has commentary while best match does not. Skipping..."
            return 0
        elif [[ "${lidarrReleaseContainsCommentary}" == "false" && "${bestMatchContainsCommentary}" == "true" ]]; then
            log "DEBUG :: Current candidate does not have commentary while best match does. Proceeding..."
            return 1
        fi
    fi

    # If a exact match has been found, we only want to process releases that are potentially better matches
    local exactMatchFound="$(get_state "exactMatchFound")"
    if [ "${exactMatchFound}" == "true" ]; then
        # Same or better country match
        local bestMatchCountryPriority lidarrReleaseCountryPriority
        bestMatchCountryPriority="$(get_state "bestMatchCountryPriority")"
        lidarrReleaseCountryPriority="$(get_state "lidarrReleaseCountryPriority")"
        if ! is_numeric "$bestMatchCountryPriority" || ! is_numeric "$lidarrReleaseCountryPriority"; then
            # Don't skip, error should be caught somewhere downstream
            return 1
        fi
        if ((lidarrReleaseCountryPriority < bestMatchCountryPriority)); then
            log "DEBUG :: Current candidate has better country priority than best match; Proceeding..."
            return 1
        elif ((lidarrReleaseCountryPriority > bestMatchCountryPriority)); then
            log "DEBUG :: Current candidate has worse country priority than best match; Skipping..."
            return 0
        fi

        # Must be same or better number of tracks
        local bestMatchNumTracks lidarrReleaseTrackCount
        bestMatchNumTracks="$(get_state "bestMatchNumTracks")"
        lidarrReleaseTrackCount="$(get_state "lidarrReleaseTrackCount")"
        if ! is_numeric "$bestMatchNumTracks" || ! is_numeric "$lidarrReleaseTrackCount"; then
            # Don't skip, error should be caught somewhere downstream
            return 1
        fi
        if ((lidarrReleaseTrackCount > bestMatchNumTracks)); then
            log "DEBUG :: Current candidate has more tracks than best match; Proceeding..."
            return 1
        elif ((lidarrReleaseTrackCount < bestMatchNumTracks)); then
            log "DEBUG :: Current candidate has fewer tracks than best match; Skipping..."
            return 0
        fi

        # Same or better format match
        local bestMatchFormatPriority lidarrReleaseFormatPriority
        bestMatchFormatPriority="$(get_state "bestMatchFormatPriority")"
        lidarrReleaseFormatPriority="$(get_state "lidarrReleaseFormatPriority")"
        if ! is_numeric "$bestMatchFormatPriority" || ! is_numeric "$lidarrReleaseFormatPriority"; then
            # Don't skip, error should be caught somewhere downstream
            return 1
        fi
        if ((lidarrReleaseFormatPriority < bestMatchFormatPriority)); then
            log "DEBUG :: Current candidate has better format priority than best match; Proceeding..."
            return 1
        elif ((lidarrReleaseFormatPriority > bestMatchFormatPriority)); then
            log "DEBUG :: Current candidate has worse format priority than best match; Skipping..."
            return 0
        fi
    fi

    return 1
}

# Update best match state with new candidate
UpdateBestMatchState() {
    local deezerCandidateAlbumID="$(get_state "deezerCandidateAlbumID")"
    local deezerCandidateTitleVariant="$(get_state "deezerCandidateTitleVariant")"
    local candidateNameDiff=$(get_state "candidateNameDiff")
    local candidateTrackDiff=$(get_state "candidateTrackDiff")
    local candidateYearDiff=$(get_state "candidateYearDiff")
    local deezerCandidateTrackCount="$(get_state "deezerCandidateTrackCount")"
    local deezerCandidateReleaseYear="$(get_state "deezerCandidateReleaseYear")"
    local lidarrReleaseFormatPriority="$(get_state "lidarrReleaseFormatPriority")"
    local lidarrReleaseCountryPriority="$(get_state "lidarrReleaseCountryPriority")"
    local deezerCandidatelyricTypePreferred="$(get_state "deezerCandidatelyricTypePreferred")"
    local lidarrReleaseContainsCommentary="$(get_state "lidarrReleaseContainsCommentary")"
    local lidarrReleaseInfo="$(get_state "lidarrReleaseInfo")"

    set_state "bestMatchID" "${deezerCandidateAlbumID}"
    set_state "bestMatchTitle" "${deezerCandidateTitleVariant}"
    set_state "bestMatchNameDiff" "${candidateNameDiff}"
    set_state "bestMatchTrackDiff" "${candidateTrackDiff}"
    set_state "bestMatchYearDiff" "${candidateYearDiff}"

    set_state "bestMatchYear" "${deezerCandidateReleaseYear}"
    set_state "bestMatchNumTracks" "${deezerCandidateTrackCount}"
    set_state "bestMatchFormatPriority" "${lidarrReleaseFormatPriority}"
    set_state "bestMatchCountryPriority" "${lidarrReleaseCountryPriority}"
    set_state "bestMatchLyricTypePreferred" "${deezerCandidatelyricTypePreferred}"
    set_state "bestMatchContainsCommentary" "${lidarrReleaseContainsCommentary}"
    set_state "bestMatchLidarrReleaseInfo" "${lidarrReleaseInfo}"

    # Check for exact match
    if is_numeric "$candidateNameDiff" && is_numeric "$candidateTrackDiff" && is_numeric "$candidateYearDiff"; then
        if ((candidateNameDiff == 0 && candidateTrackDiff == 0 && candidateYearDiff == 0)); then
            log "INFO :: Exact match found: ${deezerCandidateTitleVariant} (${deezerCandidateAlbumID})"
            set_state "exactMatchFound" "true"
        fi
    else
        log "INFO :: New best match: ${deezerCandidateTitleVariant} (${deezerCandidateAlbumID})"
    fi
}
