#!/usr/bin/env bash

#### Constants
readonly VARIOUS_ARTIST_ID_MUSICBRAINZ="89ad4ac3-39f7-470e-963a-56509c546377"

# Search Deezer artist's albums for matches
ArtistDeezerSearch() {
    log "TRACE :: Entering ArtistDeezerSearch..."
    # $1 -> Deezer Artist ID
    local artistId="${1}"

    # Get Deezer artist album list
    local artistAlbums filteredAlbums resultsCount
    if ! GetDeezerArtistAlbums "${artistId}"; then
        log "WARNING :: Failed to fetch album list for Deezer artist ID ${artistId}"
    else
        artistAlbums="$(get_state "deezerArtistInfo")"
        resultsCount=$(jq '.total' <<<"${artistAlbums}")
        log "DEBUG :: Searching albums for Artist ${artistId} (Total Albums: ${resultsCount} found)"

        # Pass filtered albums to the CalculateBestMatch function
        if ((resultsCount > 0)); then
            CalculateBestMatch <<<"${artistAlbums}"
        fi
    fi
    log "TRACE :: Exiting ArtistDeezerSearch..."
}

FuzzyDeezerSearch() {
    log "TRACE :: Entering FuzzyDeezerSearch..."
    # $1 -> Deezer Artist Name (default to blank)
    local artistName="${1:-}"

    local deezerSearch=""
    local resultsCount=0
    local url=""

    local searchReleaseTitle
    searchReleaseTitle="$(get_state "searchReleaseTitle")"

    # -------------------------------
    # Normalize and URI-encode album title
    # -------------------------------
    local albumTitleClean albumSearchTerm
    albumTitleClean="$(normalize_string "${searchReleaseTitle}")"
    # Use plain jq here; this is not JSON, just encoding a string
    albumSearchTerm="$(jq -Rn --arg str "$(remove_quotes "${albumTitleClean}")" '$str|@uri')"

    # -------------------------------
    # Build search URL
    # -------------------------------
    if [[ -z "${artistName}" ]]; then
        log "DEBUG :: Fuzzy searching for '${searchReleaseTitle}' with no artist filter..."
        url="https://api.deezer.com/search/album?q=album:${albumSearchTerm}&strict=on&limit=20"
    else
        log "DEBUG :: Fuzzy searching for '${searchReleaseTitle}' with artist name '${artistName}'..."
        local artistNameClean artistSearchTerm
        artistNameClean="$(normalize_string "${artistName}")"
        artistSearchTerm="$(jq -Rn --arg str "$(remove_quotes "${artistNameClean}")" '$str|@uri')"
        url="https://api.deezer.com/search/album?q=artist:${artistSearchTerm}%20album:${albumSearchTerm}&strict=on&limit=20"
    fi

    # -------------------------------
    # Call Deezer API
    # -------------------------------
    if ! CallDeezerAPI "${url}"; then
        log "WARNING :: Deezer Fuzzy Search failed for '${searchReleaseTitle}'"
        log "TRACE :: Exiting FuzzyDeezerSearch..."
        return 1
    fi

    deezerSearch="$(get_state "deezerApiResponse" || echo "")"
    log "TRACE :: deezerSearch: ${deezerSearch}"

    # -------------------------------
    # Validate JSON and parse
    # -------------------------------
    if [[ -n "${deezerSearch}" ]] && safe_jq --validate --optional 'true' <<<"${deezerSearch}"; then
        resultsCount="$(safe_jq --optional '.total // 0' <<<"${deezerSearch}")"
        log "DEBUG :: ${resultsCount} search results found for '${searchReleaseTitle}'"

        if ((resultsCount > 0)); then
            local formattedAlbums
            formattedAlbums="$(safe_jq '{
                data: ([.data[]] | unique_by(.id | select(. != null))),
                total: ([.data[] | .id] | unique | length)
            }' <<<"${deezerSearch}" || echo '{}')"

            log "TRACE :: Formatted unique album data: ${formattedAlbums}"
            CalculateBestMatch <<<"${formattedAlbums}"
        else
            log "DEBUG :: No results found via Fuzzy Search for '${searchReleaseTitle}'"
        fi
    else
        log "WARNING :: Deezer Fuzzy Search API returned invalid JSON for '${searchReleaseTitle}'"
    fi

    log "TRACE :: Exiting FuzzyDeezerSearch..."
}

# Given a JSON array of Deezer albums, find the best match based on title similarity and track count
CalculateBestMatch() {
    log "TRACE :: Entering CalculateBestMatch..."
    # stdin -> JSON array containing list of Deezer albums to check

    local albums albumsRaw albumsCount
    albumsRaw=$(cat) # read JSON array from stdin
    albumsCount=$(jq '.total' <<<"${albumsRaw}")
    albums=$(jq '[.data[]]' <<<"${albumsRaw}")

    log "DEBUG :: Calculating best match for \"${searchReleaseTitleClean}\" with ${albumsCount} Deezer albums to compare"

    for ((i = 0; i < albumsCount; i++)); do
        local deezerAlbumData deezerAlbumID

        deezerAlbumData=$(jq -c ".[$i]" <<<"${albums}")
        deezerAlbumID=$(jq -r ".id" <<<"${deezerAlbumData}")
        set_state "deezerCandidateAlbumID" "${deezerAlbumID}"

        # Evaluate this candidate
        EvaluateDeezerAlbumCandidate
    done

    log "TRACE :: Exiting CalculateBestMatch..."
}

# Generic Deezer API call with retries and error handling
# Returns 0 on success, 1 on failure
CallDeezerAPI() {
    log "TRACE :: Entering CallDeezerAPI..."
    local url="${1}"
    local maxRetries="${AUDIO_DEEZER_API_RETRIES:-3}"
    local retries=0
    local httpCode body response curlExit returnCode=1

    while ((retries < maxRetries)); do
        log "DEBUG :: Calling Deezer api: ${url}"

        # Run curl and capture output + HTTP code
        response="$(curl -sS -w '\n%{http_code}' \
            --connect-timeout 5 \
            --max-time "${AUDIO_DEEZER_API_TIMEOUT:-10}" \
            "${url}" 2>/dev/null || true)"
        curlExit=$?

        if [[ $curlExit -ne 0 || -z "$response" ]]; then
            log "WARNING :: curl failed (exit $curlExit) for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            retries=$((retries + 1))
            sleep 1
            continue
        fi

        # Split body and HTTP code
        httpCode=$(tail -n1 <<<"$response")
        body=$(sed '$d' <<<"$response")

        # Treat HTTP 000 as failure
        if [[ -z "$httpCode" || "$httpCode" == "000" || "$httpCode" == "0" ]]; then
            log "WARNING :: No HTTP response (000) from Deezer API for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            retries=$((retries + 1))
            sleep 1
            continue
        fi

        # Check for success
        if [[ "$httpCode" -eq 200 && -n "$body" ]]; then
            # Validate JSON safely
            if safe_jq --validate --optional '.' <<<"$body"; then
                set_state "deezerApiResponse" "$body"
                returnCode=0
                break
            else
                log "WARNING :: Invalid JSON body from Deezer API for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            fi
        else
            log "WARNING :: Deezer API returned HTTP ${httpCode:-<empty>} for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
        fi

        retries=$((retries + 1))
        sleep 1
    done

    if ((returnCode != 0)); then
        log "WARNING :: Failed to get a valid response from Deezer API after ${maxRetries} attempts for URL ${url}"
    fi

    log "TRACE :: Exiting CallDeezerAPI..."
    return "$returnCode"
}

# Fetch Deezer album info with caching (uses CallDeezerAPI)
# Returns 0 on success, 1 on failure
GetDeezerAlbumInfo() {
    log "TRACE :: Entering GetDeezerAlbumInfo..."
    local albumId="$1"
    local albumCacheFile="${AUDIO_WORK_PATH}/cache/deezer-album-${albumId}.json"
    local albumJson=""

    mkdir -p "${AUDIO_WORK_PATH}/cache"

    # Load from cache if valid
    if [[ -f "${albumCacheFile}" ]]; then
        if safe_jq --optional --validate '.' <"${albumCacheFile}"; then
            log "DEBUG :: Using cached Deezer album data for ${albumId}"
            albumJson="$(<"${albumCacheFile}")"
        else
            log "WARNING :: Cached album JSON invalid, will refetch: ${albumCacheFile}"
        fi
    fi

    if [[ -z "$albumJson" ]]; then
        local apiUrl="https://api.deezer.com/album/${albumId}"
        if ! CallDeezerAPI "${apiUrl}"; then
            log "ERROR :: Failed to get album info for ${albumId}"
            setUnhealthy
            exit 1
        fi
        albumJson="$(get_state "deezerApiResponse")"

        # Check for errors in response
        local errorCode
        errorCode="$(safe_jq --optional '.error.code' <<<"$albumJson")"
        if [[ -n "$errorCode" && "$errorCode" != "null" ]]; then
            log "WARNING :: Deezer API returned error code ${errorCode} for album ID ${albumId}"
            return 1
        fi

        # Determine if track pagination is needed
        local nb_tracks embedded_tracks
        nb_tracks="$(safe_jq '.nb_tracks' <<<"$albumJson")"
        embedded_tracks="$(safe_jq '.tracks.data | length' <<<"$albumJson")"

        if ((embedded_tracks < nb_tracks)); then
            log "DEBUG :: Album ${albumId} has ${nb_tracks} tracks, fetching remaining pages"

            local all_tracks=()
            local nextUrl="https://api.deezer.com/album/${albumId}/tracks"

            while [[ -n "$nextUrl" ]]; do
                if ! CallDeezerAPI "$nextUrl"; then
                    log "ERROR :: Failed fetching Deezer album tracks"
                    setUnhealthy
                    exit 1
                fi

                local page
                page="$(get_state "deezerApiResponse")"

                # Validate JSON
                if ! safe_jq --validate '.' <<<"$page"; then
                    log "ERROR :: Deezer returned invalid JSON for url ${nextUrl}"
                    log "ERROR :: Raw response (first 200 chars): ${page:0:200}"
                    setUnhealthy
                    exit 1
                fi

                mapfile -t page_tracks < <(
                    safe_jq -c '[.data[]]' <<<"$page"
                )

                all_tracks+=("${page_tracks[@]}")

                # Follow pagination
                nextUrl="$(safe_jq --optional '.next' <<<"$page")"

                [[ -n "$nextUrl" ]] && sleep 0.2
            done

            # Replace the json track data in the original result with the new full track list
            albumJson="$(
                printf '%s\n' "${all_tracks[@]}" |
                    safe_jq -s \
                        --argjson album "$albumJson" '
                            add as $tracks
                            | ($tracks | length) as $total
                            | $album
                            | .tracks.data = $tracks
                            | .tracks.total = $total
                        '
            )"
        fi
    fi

    echo "${albumJson}" >"${albumCacheFile}"
    set_state "deezerAlbumInfo" "${albumJson}"

    log "TRACE :: Exiting GetDeezerAlbumInfo..."
    return 0
}

# Fetch Deezer artist albums with caching (uses CallDeezerAPI)
# Returns 0 on success, 1 on failure
GetDeezerArtistAlbums() {
    log "TRACE :: Entering GetDeezerArtistAlbums..."
    local artistId="$1"
    local artistCacheFile="${AUDIO_WORK_PATH}/cache/deezer-artist-${artistId}-albums.json"
    local artistJson=""

    mkdir -p "${AUDIO_WORK_PATH}/cache"

    # Use cache if exists and valid
    if [[ -f "${artistCacheFile}" ]]; then
        if safe_jq --validate --optional '.' <"${artistCacheFile}"; then
            log "DEBUG :: Using cached Deezer artist album list for ${artistId}"
            artistJson="$(<"${artistCacheFile}")"
        else
            log "WARNING :: Cached artist album JSON invalid, will refetch: ${artistCacheFile}"
        fi
    fi

    if [[ -z "$artistJson" ]]; then
        local all_albums=()
        local nextUrl="https://api.deezer.com/artist/${artistId}/albums?limit=100"

        while [[ -n "$nextUrl" ]]; do
            if ! CallDeezerAPI "$nextUrl"; then
                log "ERROR :: Failed calling Deezer artist albums endpoint"
                setUnhealthy
                exit 1
            fi

            # Check for errors in response
            local errorCode
            errorCode="$(safe_jq --optional '.error.code' <<<"$albumJson")"
            if [[ -n "$errorCode" && "$errorCode" != "null" ]]; then
                log "WARNING :: Deezer API returned error code ${errorCode} for artist ID ${artistId}"
                return 1
            fi

            local page
            page="$(get_state "deezerApiResponse")"

            # Extract albums
            mapfile -t page_albums < <(
                safe_jq -c '[.data[]]' <<<"$page"
            )

            all_albums+=("${page_albums[@]}")

            # Follow pagination
            nextUrl="$(safe_jq --optional '.next' <<<"$page")"

            [[ -n "$nextUrl" ]] && sleep 0.2
        done

        artistJson="$(
            printf '%s\n' "${all_albums[@]}" | safe_jq -s '
        add as $arr
        | { total: ($arr | length), data: $arr }
    '
        )"
    fi

    echo "${artistJson}" >"${artistCacheFile}"
    set_state "deezerArtistInfo" "${artistJson}"

    log "TRACE :: Exiting GetDeezerArtistAlbums..."
    return 0
}

# Get release title with disambiguation if available
AddDisambiguationToTitle() {
    # $1 -> The title
    # $2 -> The disambiguation
    local title="$1"
    local disambiguation="$2"
    if [[ -n "${disambiguation}" && "${disambiguation}" != "null" && "${disambiguation}" != "" ]]; then
        local normalizedDisambiguation=$(normalize_string "${disambiguation}")
        echo "${title} (${normalizedDisambiguation})"
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
        log "TRACE :: No title replacement found for: \"${title}\""
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

        # Sentinel for blank values
        my $BLANK = "__BLANK__";

        # --- Split input tokens (always comma-separated) and normalize ---
        my @input_tokens = map {
            my $t = $_;
            $t =~ s/^"+|"+$//g;      # remove quotes
            $t =~ s/^\s+|\s+$//g;    # trim spaces
            length($t) ? lc($t) : $BLANK
        } split /,/, $input // "";

        @input_tokens = ($BLANK) unless @input_tokens;

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
                lc($t) eq "[blank]" ? $BLANK : lc($t)
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
            if (exists $priority{$tok} && $priority{$tok} < $best) {
                $best = $priority{$tok};
            }
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

        response="$(
            curl -sS -L \
                --connect-timeout 5 \
                --max-time 15 \
                -H "User-Agent: ${mbUserAgent}" \
                -H "Accept: application/json" \
                -w "\n%{http_code}" \
                "${url}" 2>&1
        )"

        curlExit=$?
        log "TRACE :: curl exit code: ${curlExit}"

        # Curl-level failure (DNS, TLS, timeout, etc)
        if ((curlExit != 0)); then
            log "WARNING :: curl failed (exit ${curlExit}). Retrying..."
            sleep "${backoff}"
            backoff=$((backoff * 2))
            continue
        fi

        httpCode="$(tail -n1 <<<"${response}")"
        body="$(sed '$d' <<<"${response}")"

        log "DEBUG :: HTTP response code: ${httpCode}"
        log "TRACE :: HTTP response body: ${body}"

        case "${httpCode}" in
        200)
            if safe_jq --validate --optional '.' <<<"${body}"; then
                set_state "musicBrainzApiResponse" "${body}"
                return 0
            else
                log "WARNING :: Invalid JSON from MusicBrainz. Retrying..."
            fi
            ;;
        301 | 302)
            # Should not happen often because -L is enabled,
            # but treat as retryable just in case
            log "DEBUG :: Redirect response (${httpCode}) handled by curl"
            ;;
        429)
            log "WARNING :: HTTP 429 (Too Many Requests). Backing off..."
            sleep "${backoff}"
            backoff=$((backoff * 2))
            ;;
        503)
            log "WARNING :: MusicBrainz returned 503. Backing off..."
            sleep "${backoff}"
            backoff=$((backoff * 2))
            ;;
        5*)
            log "WARNING :: Server error ${httpCode}. Retrying..."
            sleep "${backoff}"
            backoff=$((backoff * 2))
            ;;
        *)
            log "WARNING :: Unexpected HTTP ${httpCode} from MusicBrainz"
            break
            ;;
        esac
    done

    log "ERROR :: CallMusicBrainzAPI failed after ${maxAttempts} attempts"
    setUnhealthy
    exit 1
}

# Clears the state values for track name comparisons
ClearTrackComparisonCache() {
    local name=$(_get_state_name)

    # Ensure the state object exists
    if ! declare -p "$name" &>/dev/null; then
        log "ERROR :: State object '$name' not found for track cache clear."
        setUnhealthy
        exit 1
    fi

    log "DEBUG :: Clearing cached track values from state"
    # Name reference to the associative array
    local -n obj="$name"

    for k in "${!obj[@]}"; do
        log "TRACE :: key: $k"
        [[ "$k" == trackcache.* ]] && unset "obj[$k]"
    done
    log "DEBUG :: Cleared all cached track values from state"
}

# Compares a lidarr track title to a deezer track title
CompareTrack() {
    local lidarrTrackTitle="${1}"
    local deezerTrackTitle="${2}"
    local deezerLongTrackTitle="${3}"

    # Normalize titles
    local lidarrTrackTitleNorm deezerTrackTitleNorm deezerLongTrackTitleNorm
    lidarrTrackTitleNorm="$(normalize_string "${lidarrTrackTitle}")"
    deezerTrackTitleNorm="$(normalize_string "${deezerTrackTitle}")"
    deezerLongTrackTitleNorm="$(normalize_string "${deezerLongTrackTitle}")"

    # First pass comparison: plain titles
    local d="$(LevenshteinDistance "${lidarrTrackTitleNorm,,}" "${deezerTrackTitleNorm,,}")"
    log "DEBUG :: Calculated distance \"$lidarrTrackTitleNorm\" to \"$deezerTrackTitleNorm\": $d"

    if [[ "$d" =~ ^[0-9]+$ ]]; then

        # Second pass comparison: strip feature annotations from Deezer title
        if ((d > 0)); then
            local deezerTrackTitleStripped
            deezerTrackTitleStripped="$(normalize_string "$(StripTrackFeature "$deezerTrackTitle")")"

            if [[ -n "$deezerTrackTitleStripped" && "$deezerTrackTitleStripped" != "$deezerTrackTitle" ]]; then
                local d_feature_stripped
                d_feature_stripped="$(LevenshteinDistance "${lidarrTrackTitleNorm,,}" "${deezerTrackTitleStripped,,}")"
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitleNorm\" to \"$deezerTrackTitleStripped\" (feature stripped): $d_feature_stripped"

                ((d_feature_stripped < d)) && d="$d_feature_stripped"
            fi
        fi

        # Third pass comparison: use long Deezer title
        if ((d > 0)); then
            if [[ -n "$deezerLongTrackTitle" && "$deezerLongTrackTitle" != "$deezerTrackTitle" ]]; then
                local d_longtitle
                d_longtitle="$(LevenshteinDistance "${lidarrTrackTitleNorm,,}" "${deezerLongTrackTitleNorm,,}")"
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitleNorm\" to \"$deezerLongTrackTitleNorm\" (long title): $d_longtitle"

                ((d_longtitle < d)) && d="$d_longtitle"
            fi
        fi

        # Fourth pass comparison: strip common track modifiers like "Remastered", "Live", "Acoustic", etc from both titles
        if ((d > 0)); then
            local lidarrStripped
            local deezerStripped

            lidarrStripped="$(normalize_string "$(RemoveModifiersFromTrackTitle "$lidarrTrackTitle")")"
            deezerStripped="$(normalize_string "$(RemoveModifiersFromTrackTitle "$deezerTrackTitle")")"

            if [[ "$lidarrStripped" != "$lidarrTrackTitleNorm" ]] ||
                [[ "$deezerStripped" != "$deezerTrackTitleNorm" ]]; then

                local d_modifiers
                d_modifiers="$(LevenshteinDistance "${lidarrStripped,,}" "${deezerStripped,,}")"

                log "DEBUG :: Recalculated distance \"$lidarrStripped\" to \"$deezerStripped\" (modifiers stripped): $d_modifiers"

                ((d_modifiers < d)) && d="$d_modifiers"
            fi
        fi

        # Fifth pass comparison: remove album title from track title (niche case)
        if ((d > 0)); then
            local deezerTrackTitleStripped
            local searchReleaseTitleClean="$(get_state "searchReleaseTitleClean")"
            deezerTrackTitleStripped="$(normalize_string "$(RemovePatternFromString "$deezerTrackTitle" "${searchReleaseTitleClean}")")"

            if [[ -n "$deezerTrackTitleStripped" && "$deezerTrackTitleStripped" != "$deezerTrackTitle" ]]; then
                local d_album_stripped
                d_album_stripped="$(LevenshteinDistance "${lidarrTrackTitleNorm,,}" "${deezerTrackTitleStripped,,}")"
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitleNorm\" to \"$deezerTrackTitleStripped\" (album title stripped): $d_album_stripped"

                ((d_album_stripped < d)) && d="$d_album_stripped"
            fi
        fi

        # Sixth pass comparison: remove spaces and punctuation from track titles (niche case)
        if ((d > 0)); then
            local deezerTrackTitleStripped
            local searchReleaseTitleClean="$(get_state "searchReleaseTitleClean")"

            deezerTrackTitleStripped="$(normalize_string "$(tr -cd '[:alnum:]' <<<"$deezerTrackTitle")")"
            lidarrTrackTitleStripped="$(normalize_string "$(tr -cd '[:alnum:]' <<<"$lidarrTrackTitle")")"

            if [[ -n "$deezerTrackTitleStripped" && "$deezerTrackTitleStripped" != "$deezerTrackTitle" ]] ||
                [[ -n "$lidarrTrackTitleStripped" && "$lidarrTrackTitleStripped" != "$lidarrTrackTitle" ]]; then
                local d_nopunct_nospace
                d_nopunct_nospace="$(LevenshteinDistance "${lidarrTrackTitleStripped,,}" "${deezerTrackTitleStripped,,}")"
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitleStripped\" to \"$deezerTrackTitleStripped\" (no spaces): $d_nopunct_nospace"

                ((d_nopunct_nospace < d)) && d="$d_nopunct_nospace"
            fi
        fi

        # Seventh pass comparison: substring containment (Deezer ⊆ Lidarr or Lidarr ⊆ Deezer)
        if ((d > 0)); then
            if [[ " ${deezerTrackTitle,,} " == *" ${lidarrTrackTitle,,} "* ]] ||
                [[ " ${lidarrTrackTitle,,} " == *" ${deezerTrackTitle,,} "* ]]; then
                # Treat as a close match (but not quite exact)
                local d_contains=1
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitle\" to \"$deezerTrackTitle\" (contains check): $d_contains"
                ((d_contains < d)) && d="$d_contains"
            fi
        fi

        if [[ "$d" =~ ^[0-9]+$ ]]; then
            set_state "trackTitleDiff" "$d"
        else
            log "ERROR :: Invalid Levenshtein distance '$d' for '$lidarrTrackTitle' vs '$deezerTrackTitle'"
            setUnhealthy
            exit 1
        fi
    else
        log "ERROR :: Invalid Levenshtein distance '$d' for '$lidarrTrackTitle' vs '$deezerTrackTitle'"
        setUnhealthy
        exit 1
    fi
}

# Compares the track lists from a lidarr release and a deezer album
CompareTrackLists() {
    log "TRACE :: Entering CompareTrackLists..."

    # Check if a cached comparison exists
    local deezerCandidateAlbumID="$(get_state "deezerCandidateAlbumID")"
    local lidarrReleaseForeignId="$(get_state "lidarrReleaseForeignId")"
    local cache_key="${lidarrReleaseForeignId}|${deezerCandidateAlbumID}"
    local cached_avg
    cached_avg="$(get_state "trackcache.${cache_key}.avg")"

    if [[ -n "$cached_avg" ]]; then
        log "DEBUG :: Using cached track comparison for $cache_key"

        set_state "candidateTrackNameDiffAvg" "$cached_avg"
        set_state "candidateTrackNameDiffTotal" "$(get_state "trackcache.${cache_key}.tot")"
        set_state "candidateTrackNameDiffMax" "$(get_state "trackcache.${cache_key}.max")"
        return 0
    fi

    local lidarr_raw deezer_raw
    lidarr_raw="$(get_state "lidarrReleaseTrackTitles")"
    lidarr_recording_raw="$(get_state "lidarrReleaseRecordingTitles")"
    deezer_raw="$(get_state "deezerCandidateTrackTitles")"
    deezer_long_raw="$(get_state "deezerCandidateLongTrackTitles")"
    log "DEBUG :: Comparing track lists of lidarr \"$lidarrReleaseForeignId\" to deezer \"$deezerCandidateAlbumID\""

    local lidarr_tracks=() deezer_tracks=()
    [[ -n "$lidarr_raw" ]] && mapfile -t lidarr_tracks < <(jq -r '.[]' <<<"$lidarr_raw")
    [[ -n "$lidarr_recording_raw" ]] && mapfile -t lidarr_recordings < <(jq -r '.[]' <<<"$lidarr_recording_raw")
    [[ -n "$deezer_raw" ]] && mapfile -t deezer_tracks < <(jq -r '.[]' <<<"$deezer_raw")
    [[ -n "$deezer_long_raw" ]] && mapfile -t deezer_long_tracks < <(jq -r '.[]' <<<"$deezer_long_raw")

    local lidarr_len=${#lidarr_tracks[@]}
    local deezer_len=${#deezer_tracks[@]}
    local max_len=$(($lidarr_len > $deezer_len ? $lidarr_len : $deezer_len))
    if (($lidarr_len == 0 || $deezer_len == 0)); then
        set_state "candidateTrackNameDiffAvg" "0.00"
        set_state "candidateTrackNameDiffTotal" "0"
        set_state "candidateTrackNameDiffMax" "0"

        # Cache results
        set_state "trackcache.${cache_key}.avg" "0.00"
        set_state "trackcache.${cache_key}.tot" "0"
        set_state "trackcache.${cache_key}.max" "0"
        return 0
    fi

    local total_diff=0
    local max_diff=0
    local compared_tracks=0
    if (($lidarr_len != $deezer_len)); then
        log "DEBUG :: Lidarr release has a different number of tracks that the deezer release (lidarr $lidarr_len; deezer $deezer_len)"
        total_diff=999
        max_diff=999
        compared_tracks=1
    else
        for ((i = 0; i < max_len; i++)); do
            CompareTrack "${lidarr_tracks[i]:-}" "${deezer_tracks[i]:-}" "${deezer_long_tracks[i]:-}"
            local d="$(get_state "trackTitleDiff")"
            if ((d > 0)); then
                CompareTrack "${lidarr_recordings[i]:-}" "${deezer_tracks[i]:-}" "${deezer_long_tracks[i]:-}"
                local d2="$(get_state "trackTitleDiff")"
                ((d2 < d)) && d="$d2"
            fi
            total_diff=$((total_diff + d))
            compared_tracks=$((compared_tracks + 1))
            ((d > max_diff)) && max_diff="$d"
        done
    fi

    local diff_avg
    diff_avg="$(awk -v d="$total_diff" -v n="$compared_tracks" \
        'BEGIN { printf "%.2f", (n > 0 ? d / n : 0) }')"

    log "DEBUG :: Track diffs: avg=${diff_avg}, total=${total_diff}, max=${max_diff}"

    set_state "candidateTrackNameDiffAvg" "$diff_avg"
    set_state "candidateTrackNameDiffTotal" "$total_diff"
    set_state "candidateTrackNameDiffMax" "$max_diff"

    # Cache results
    set_state "trackcache.${cache_key}.avg" "$diff_avg"
    set_state "trackcache.${cache_key}.tot" "$total_diff"
    set_state "trackcache.${cache_key}.max" "$max_diff"

    log "TRACE :: Exiting CompareTrackLists..."
}

# Compute match metrics for a candidate album
ComputeMatchMetrics() {
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
    local lidarrReleaseForeignId="$(get_state "lidarrReleaseForeignId")"

    # Get album info from Deezer
    if ! GetDeezerAlbumInfo "${deezerCandidateAlbumID}"; then
        log "WARNING :: Failed to fetch album info for Deezer album ID ${deezerCandidateAlbumID}, skipping..."
        return
    fi

    # Extract candidate information
    local deezerAlbumData="$(get_state "deezerAlbumInfo")"
    local deezerCandidateTitle=$(safe_jq ".title" <<<"${deezerAlbumData}")
    local deezerCandidateIsExplicit=$(safe_jq ".explicit_lyrics" <<<"${deezerAlbumData}")
    local deezerCandidateTrackCount=$(safe_jq .nb_tracks <<<"${deezerAlbumData}")
    local deezerCandidateReleaseYear=$(safe_jq .release_date <<<"${deezerAlbumData}")
    deezerCandidateReleaseYear="${deezerCandidateReleaseYear:0:4}"
    set_state "deezerCandidateTrackCount" "${deezerCandidateTrackCount}"
    set_state "deezerCandidateReleaseYear" "${deezerCandidateReleaseYear}"
    set_state "deezerCandidateIsExplicit" "${deezerCandidateIsExplicit}"
    set_state "deezerCandidateTitle" "${deezerCandidateTitle}"

    # Extract track titles
    local track_titles=()
    local deezerCandidateTrackTitles=""

    while IFS= read -r track_title; do
        [[ -z "$track_title" ]] && continue
        track_titles+=("$track_title")
    done < <(
        safe_jq --optional -r '
            .tracks?.data[]?.title_short // empty
        ' <<<"$deezerAlbumData"
    )

    local deezerCandidateTrackTitles="$(printf '%s\n' "${track_titles[@]}" | jq -R . | jq -s .)"
    set_state "deezerCandidateTrackTitles" "${deezerCandidateTrackTitles}"

    local track_titles_long=()
    local deezerCandidateLongTrackTitles=""

    while IFS= read -r track_title; do
        [[ -z "$track_title" ]] && continue
        track_titles_long+=("$track_title")
    done < <(
        safe_jq --optional -r '
            .tracks?.data[]?.title // empty
        ' <<<"$deezerAlbumData"
    )

    local deezerCandidateLongTrackTitles="$(printf '%s\n' "${track_titles_long[@]}" | jq -R . | jq -s .)"
    set_state "deezerCandidateLongTrackTitles" "${deezerCandidateLongTrackTitles}"

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
    local deezerCandidateTitleMinimal="$(get_state "deezerCandidateTitleMinimal")"

    log "DEBUG :: Comparing lidarr release \"${searchReleaseTitleClean}\" (${lidarrReleaseForeignId}) to Deezer album \"${deezerCandidateTitleClean}\" (${deezerCandidateAlbumID})"

    # Check both with and without edition info
    local titlesToCheck=()
    titlesToCheck+=("${deezerCandidateTitleClean}")
    if [[ "${deezerCandidateTitleClean}" != "${deezerCandidateTitleEditionless}" ]]; then
        titlesToCheck+=("${deezerCandidateTitleEditionless}")
        log "DEBUG :: Additionally checking editionless title: \"${deezerCandidateTitleEditionless}\""
    fi
    if [[ "${deezerCandidateTitleClean}" != "${deezerCandidateTitleMinimal}" ]] && [[ "${deezerCandidateTitleMinimal}" != "${deezerCandidateTitleEditionless}" ]]; then
        titlesToCheck+=("${deezerCandidateTitleMinimal}")
        log "DEBUG :: Additionally checking minimal title: \"${deezerCandidateTitleMinimal}\""
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
    ComputeMatchMetrics

    local candidateNameDiff=$(get_state "candidateNameDiff")
    local candidateTrackDiff=$(get_state "candidateTrackDiff")
    local candidateYearDiff=$(get_state "candidateYearDiff")

    # Check if meets thresholds
    local deezerCandidateTitleVariant="$(get_state "deezerCandidateTitleVariant")"
    if ((candidateNameDiff > AUDIO_MATCH_THRESHOLD_TITLE)); then
        log "DEBUG :: Album \"${deezerCandidateTitleVariant,,}\" does not meet matching threshold (Name difference=${candidateNameDiff}), skipping..."
        return 0
    fi
    if ((candidateTrackDiff > AUDIO_MATCH_THRESHOLD_TRACKS)); then
        log "DEBUG :: Album \"${deezerCandidateTitleVariant,,}\" does not meet matching threshold (Track count difference=${candidateTrackDiff}), skipping..."
        return 0
    fi

    # Calculate track title score
    CompareTrackLists

    local candidateTrackNameDiffAvg=$(get_state "candidateTrackNameDiffAvg")
    local candidateTrackNameDiffMax=$(get_state "candidateTrackNameDiffMax")
    if awk "BEGIN { exit !($candidateTrackNameDiffAvg > $AUDIO_MATCH_THRESHOLD_TRACK_DIFF_AVG) }"; then
        log "DEBUG :: Album \"${deezerCandidateTitleVariant,,}\" does not meet matching threshold (Track name difference average=${candidateTrackNameDiffAvg}), skipping..."
        return 0
    fi
    if ((candidateTrackNameDiffMax > AUDIO_MATCH_THRESHOLD_TRACK_DIFF_MAX)); then
        log "DEBUG :: Album \"${deezerCandidateTitleVariant,,}\" does not meet matching threshold (Track name difference maximum=${candidateTrackNameDiffMax}), skipping..."
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
    lidarrAlbumTitle=$(normalize_string "$lidarrAlbumTitle")
    lidarrAlbumTitle=$(remove_punctuation "$lidarrAlbumTitle")
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
    set_state "lidarrReleaseContainsCommentary" "$(safe_jq ".contains_commentary" <<<"${release_json}")"
    set_state "lidarrReleaseLyricTypePreferred" "$(safe_jq ".lyric_type_preferred" <<<"${release_json}")"
    set_state "lidarrReleaseTitle" "$(safe_jq ".title" <<<"${release_json}")"
    set_state "lidarrReleaseDisambiguation" "$(safe_jq --optional ".disambiguation" <<<"${release_json}")"
    set_state "lidarrReleaseForeignId" "$(safe_jq ".foreign_id" <<<"${release_json}")"
    set_state "lidarrReleaseTrackCount" "$(safe_jq ".track_count" <<<"${release_json}")"
    set_state "lidarrReleaseFormatPriority" "$(safe_jq ".format_priority" <<<"${release_json}")"
    set_state "lidarrReleaseCountryPriority" "$(safe_jq ".country_priority" <<<"${release_json}")"
    set_state "lidarrReleaseTiebreakerCountryPriority" "$(safe_jq ".tiebreaker_country_priority" <<<"${release_json}")"
    set_state "lidarrReleaseYear" "$(safe_jq ".year" <<<"${release_json}")"
    set_state "lidarrReleaseRecordingTitles" "$(safe_jq ".recording_titles" <<<"${release_json}")"
    set_state "lidarrReleaseTrackTitles" "$(safe_jq ".track_titles" <<<"${release_json}")"
    set_state "lidarrReleaseLinkedDeezerAlbumId" "$(safe_jq --optional ".deezer_album_id" <<<"${release_json}")"
    set_state "lidarrReleaseStatus" "$(safe_jq --optional ".release_status" <<<"${release_json}")"
    set_state "lidarrReleaseDisambiguationRarities" "$(safe_jq --optional ".rarities" <<<"${release_json}")"
    set_state "lidarrReleaseIsInstrumental" "$(safe_jq --optional ".instrumental" <<<"${release_json}")"

    log "TRACE :: Exiting ExtractReleaseInfo..."
}

CreateReleaseJson() {
    log "TRACE :: Entering CreateReleaseJson..."

    local release_json="$1"
    local lidarrReleaseTitle="$(safe_jq ".title" <<<"${release_json}")"
    local lidarrReleaseDisambiguation="$(safe_jq --optional ".disambiguation" <<<"${release_json}")"
    local lidarrReleaseTrackCount="$(safe_jq ".trackCount" <<<"${release_json}")"
    local lidarrReleaseForeignId="$(safe_jq ".foreignReleaseId" <<<"${release_json}")"
    local lidarrReleaseFormat="$(safe_jq ".format" <<<"${release_json}")"
    local lidarrReleaseCountries="$(safe_jq --optional '.country // [] | join(",")' <<<"${release_json}")"
    local lidarrReleaseFormatPriority="$(CalculatePriority "${lidarrReleaseFormat}" "${AUDIO_PREFERRED_FORMATS}")"
    local lidarrReleaseCountryPriority="$(CalculatePriority "${lidarrReleaseCountries}" "${AUDIO_PREFERRED_COUNTRIES}")"
    local lidarrReleaseTiebreakerCountryPriority="$(CalculatePriority "${lidarrReleaseCountries}" "${AUDIO_TIEBREAKER_COUNTRIES}")"
    local lidarrReleaseDate=$(safe_jq --optional '.releaseDate' <<<"${release_json}")
    local lidarrReleaseYear=""
    local albumReleaseYear="$(get_state "lidarrAlbumReleaseYear")"

    # Get up-to-date musicbrainz information
    FetchMusicBrainzReleaseInfo "$lidarrReleaseForeignId"
    local mbJson="$(get_state "musicbrainzReleaseJson")"
    local lidarrReleaseStatus="$(safe_jq --optional '.status' <<<"$mbJson")"

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

    # Determine if this release has a Deezer link
    local lidarrReleaseLinkedDeezerAlbumId="$(
        safe_jq --optional '
            .relations[]?
            | select(.ended == false)
            | .url.resource
            | select(contains("deezer.com/album/"))
            | capture("/album/(?<id>[0-9]+)$").id
        ' <<<"$mbJson" | head -n1
    )"

    # Extract track titles
    local recording_titles=()
    local recording_disambiguations=()
    local track_titles=()

    while IFS= read -r recording_title; do
        [[ -z "$recording_title" ]] && continue
        recording_titles+=("$recording_title")
    done < <(
        safe_jq --optional -r '
            .media[]?.tracks[]?.recording?.title // empty
        ' <<<"$mbJson"
    )
    while IFS= read -r track_title; do
        [[ -z "$track_title" ]] && continue
        track_titles+=("$track_title")
    done < <(
        safe_jq --optional -r '
            .media[]?.tracks[]?.title // empty
        ' <<<"$mbJson"
    )
    while IFS= read -r recording_disambiguation; do
        [[ -z "$recording_disambiguation" ]] && continue
        recording_disambiguations+=("$recording_disambiguation")
    done < <(
        safe_jq --optional -r '
            .media[]?.tracks[]?.recording?.disambiguation // empty
        ' <<<"$mbJson"
    )

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
        for t in "${track_titles[@]}"; do
            # Skip blank (just in case safe_jq returns empty)
            [[ -z "$t" ]] && continue
            if [[ "${t,,}" =~ ${commentaryPattern,,} ]]; then
                log "DEBUG :: track \"${t}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
                lidarrReleaseContainsCommentary="true"
                break
            fi
        done
    fi

    # Check for "rarities" tag
    local lidarrReleaseDisambiguationRarities="false"
    if [[ "${lidarrReleaseDisambiguation,,}" =~ "rarities" ]]; then
        log "DEBUG :: Release disambiguation \"${lidarrReleaseDisambiguation}\" matched \"rarities\" keyword"
        lidarrReleaseDisambiguationRarities="true"
    fi

    # Check for instrumental-like titles
    local lidarrReleaseIsInstrumental="false"
    # Convert comma-separated list into an alternation pattern for Bash regex
    IFS=',' read -r -a keywordArray <<<"${AUDIO_INSTRUMENTAL_KEYWORDS}"
    keywordPattern="($(
        IFS="|"
        echo "${keywordArray[*]}"
    ))" # join array with | for pattern matching

    if [[ "${lidarrReleaseTitle,,}" =~ ${keywordPattern,,} ]]; then
        log "DEBUG :: Release title \"${lidarrReleaseTitle}\" matched instrumental keyword (${AUDIO_INSTRUMENTAL_KEYWORDS})"
        lidarrReleaseIsInstrumental="true"
    elif [[ "${lidarrReleaseDisambiguation,,}" =~ ${keywordPattern,,} ]]; then
        log "DEBUG :: Release disambiguation \"${lidarrReleaseDisambiguation}\" matched instrumental keyword (${AUDIO_INSTRUMENTAL_KEYWORDS})"
        lidarrReleaseIsInstrumental="true"
    fi

    # Check for explicit lyrics
    local lidarrReleaseContainsExplicitLyrics="false"
    if [[ "${lidarrReleaseDisambiguation,,}" =~ "explicit" ]]; then
        log "DEBUG :: Release disambiguation \"${lidarrReleaseDisambiguation}\" matched explicit lyrics keyword"
        lidarrReleaseContainsExplicitLyrics="true"
    else
        # Check recording disambiguations
        for t in "${recording_disambiguations[@]}"; do
            # Skip blank (just in case safe_jq returns empty)
            [[ -z "$t" ]] && continue
            if [[ "${t,,}" =~ "explicit" ]]; then
                log "DEBUG :: recording \"${t}\" matched explicit lyrics keyword"
                lidarrReleaseContainsExplicitLyrics="true"
                break
            fi
        done
    fi
    local lyricTypeSetting="${AUDIO_LYRIC_TYPE:-}"
    local lidarrReleaseLyricTypePreferred=$(IsLyricTypePreferred "${lidarrReleaseContainsExplicitLyrics}" "${lyricTypeSetting}")

    local lidarrReleaseRecordingTitlesJson="$(printf '%s\n' "${recording_titles[@]}" | jq -R . | jq -s .)"
    local lidarrReleaseTrackTitlesJson="$(printf '%s\n' "${track_titles[@]}" | jq -R . | jq -s .)"
    local lidarrReleaseCountriesJson="$(printf '%s\n' "${countries[@]}" | jq -R . | jq -s .)"

    lidarrReleaseObject="$(
        jq -n \
            --arg contains_commentary "${lidarrReleaseContainsCommentary}" \
            --arg lyric_type_preferred "${lidarrReleaseLyricTypePreferred}" \
            --arg title "${lidarrReleaseTitle}" \
            --arg disambiguation "${lidarrReleaseDisambiguation}" \
            --arg foreign_id "${lidarrReleaseForeignId}" \
            --arg track_count "${lidarrReleaseTrackCount}" \
            --arg format_priority "${lidarrReleaseFormatPriority}" \
            --arg country_priority "${lidarrReleaseCountryPriority}" \
            --arg tiebreaker_country_priority "${lidarrReleaseTiebreakerCountryPriority}" \
            --arg year "${lidarrReleaseYear}" \
            --argjson recording_titles "$lidarrReleaseRecordingTitlesJson" \
            --argjson track_titles "$lidarrReleaseTrackTitlesJson" \
            --arg deezer_album_id "${lidarrReleaseLinkedDeezerAlbumId}" \
            --arg release_status "${lidarrReleaseStatus}" \
            --arg lyric_type_preferred "${lidarrReleaseLyricTypePreferred}" \
            --arg rarities "${lidarrReleaseDisambiguationRarities}" \
            --arg instrumental "${lidarrReleaseIsInstrumental}" \
            '
                def to_bool:
                ascii_downcase as $v
                | if $v == "true" then true
                    elif $v == "false" then false
                    else null end;

                def to_num:
                tonumber? // null;

                {
                contains_commentary: ($contains_commentary | to_bool),
                lyric_type_preferred: ($lyric_type_preferred | to_bool),
                title: $title,
                disambiguation: $disambiguation,
                foreign_id: $foreign_id,
                track_count: ($track_count | to_num),
                format_priority: ($format_priority | to_num),
                country_priority: ($country_priority | to_num),
                tiebreaker_country_priority: ($tiebreaker_country_priority | to_num),
                year: ($year | to_num),
                recording_titles: $recording_titles,
                track_titles: $track_titles,
                deezer_album_id: (if $deezer_album_id != "" then $deezer_album_id else "" end),
                release_status: $release_status,
                rarities: $rarities,
                instrumental: ($instrumental | to_bool)
                }
            '
    )"

    echo "$lidarrReleaseObject"
    log "TRACE :: Exiting CreateReleaseJson..."
}

# Fetch MusicBrainz release JSON with caching
# TODO: UnitTest
FetchMusicBrainzReleaseInfo() {
    local mbid="$1"

    if [[ -z "$mbid" || "$mbid" == "null" ]]; then
        set_state "musicbrainzReleaseJson" ""
        return 0
    fi

    local url="https://musicbrainz.org/ws/2/release/${mbid}?fmt=json&inc=recordings+url-rels"
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

# Given a Lidarr album ID, search for the best available Deezer album to match
FindDeezerMatch() {
    log "TRACE :: Entering FindDeezerMatch..."

    local lidarrAlbumId=$(get_state "lidarrAlbumId")

    # Fetch album data from Lidarr
    local lidarrAlbumData
    ArrApiRequest "GET" "album/${lidarrAlbumId}"
    lidarrAlbumData="$(get_state "arrApiResponse")"
    if [ -z "$lidarrAlbumData" ]; then
        log "WARNING :: Lidarr returned no data for album ID ${lidarrAlbumId}"
        return
    fi
    set_state "lidarrAlbumData" "${lidarrAlbumData}" # Cache response in state object

    ExtractArtistInfo "$(safe_jq '.artist' <<<"$lidarrAlbumData")"
    ExtractAlbumInfo "$(safe_jq '.' <<<"$lidarrAlbumData")"
    local lidarrArtistForeignArtistId=$(get_state "lidarrArtistForeignArtistId")
    local lidarrAlbumForeignAlbumId=$(get_state "lidarrAlbumForeignAlbumId")
    local lidarrArtistName=$(get_state "lidarrArtistName")
    local lidarrAlbumTitle=$(get_state "lidarrAlbumTitle")

    # Check if album was previously marked "not found"
    if [ -f "${AUDIO_DATA_PATH}/notfound/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
        log "DEBUG :: Album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\" was previously marked as not found, skipping..."
        return
    fi

    # Check if album was previously marked "downloaded"
    if [ -f "${AUDIO_DATA_PATH}/downloaded/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
        log "DEBUG :: Album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\" was previously marked as downloaded, skipping..."
        return
    fi

    # Release date check
    local albumIsNewRelease=false
    local lidarrAlbumReleaseDate=$(get_state "lidarrAlbumReleaseDate")
    local lidarrAlbumReleaseDateClean=$(get_state "lidarrAlbumReleaseDateClean")

    currentDateClean=$(date "+%Y%m%d")
    if [[ "${currentDateClean}" -lt "${lidarrAlbumReleaseDateClean}" ]]; then
        log "DEBUG :: Album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\" has not been released yet (${lidarrAlbumReleaseDate}), skipping..."
        return
    elif ((currentDateClean - lidarrAlbumReleaseDateClean < 8)); then
        albumIsNewRelease=true
    fi
    set_state "lidarrAlbumIsNewRelease" "${albumIsNewRelease}"

    log "INFO :: Starting search for album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\""

    # Extract artist links
    local deezerArtistIds
    local lidarrArtistInfo="$(get_state "lidarrArtistInfo")"
    local deezerArtistUrl=$(safe_jq '.links[]? | select(.name=="deezer") | .url' <<<"${lidarrArtistInfo}")
    if [ -z "${deezerArtistUrl}" ]; then
        log "WARNING :: Missing Deezer link for artist ${lidarrArtistName}"
    else
        deezerArtistIds=($(echo "${deezerArtistUrl}" | grep -Eo '[[:digit:]]+' | sort -u))
    fi

    # Initialize and sort releases for processing
    releaseJsonArray="[]"
    local lidarrAlbumInfo="$(get_state "lidarrAlbumInfo")"
    mapfile -t inputReleases < <(jq -c '.releases[]' <<<"$lidarrAlbumInfo")
    for inputRelease in "${inputReleases[@]}"; do
        local releaseJson=$(CreateReleaseJson "$inputRelease")
        log "TRACE :: Created Lidarr release JSON: ${releaseJson}"
        releaseJsonArray="$(
            jq -c --argjson r "$releaseJson" '. + [$r]' <<<"$releaseJsonArray"
        )"
    done
    releaseJsonArray="$(jq -c 'sort_by(.deezer_album_id == "" , - .track_count)' <<<"$releaseJsonArray")"

    # Start search loop
    ResetBestMatch
    local exactMatchFound="false"
    mapfile -t releasesArray < <(jq -c '.[]' <<<"$releaseJsonArray")
    for release_json in "${releasesArray[@]}"; do
        ExtractReleaseInfo "${release_json}"

        # Shortcut the evaluation process if the release isn't potentially better in some ways
        if SkipReleaseCandidate; then
            continue
        fi

        local lidarrReleaseTitle="$(get_state "lidarrReleaseTitle")"
        local lidarrReleaseDisambiguation="$(get_state "lidarrReleaseDisambiguation")"

        SetLidarrTitlesToSearch "${lidarrReleaseTitle}" "${lidarrReleaseDisambiguation}"
        local lidarrTitlesToSearch=$(get_state "lidarrTitlesToSearch")
        mapfile -t titleArray <<<"${lidarrTitlesToSearch}"

        local lidarrReleaseForeignId="$(get_state "lidarrReleaseForeignId")"
        log "DEBUG :: Processing Lidarr release \"${lidarrReleaseTitle}\" (${lidarrReleaseForeignId})"

        # Loop over all titles to search for this release
        for searchReleaseTitle in "${titleArray[@]}"; do
            set_state "searchReleaseTitle" "${searchReleaseTitle}"

            # Normalize Lidarr release title
            local searchReleaseTitle="$(get_state "searchReleaseTitle")"
            local searchReleaseTitleClean
            searchReleaseTitleClean="$(normalize_string "${searchReleaseTitle}")"
            searchReleaseTitleClean="${searchReleaseTitleClean:0:130}"
            set_state "searchReleaseTitleClean" "${searchReleaseTitleClean}"

            log "TRACE :: Searching for release title variant: \"${searchReleaseTitleClean}\""

            # If the release has a linked Deezer album, no need to perform search, just check if it's a best match
            local lidarrReleaseLinkedDeezerAlbumId="$(get_state "lidarrReleaseLinkedDeezerAlbumId")"
            if [[ -n "${lidarrReleaseLinkedDeezerAlbumId}" ]]; then
                log "DEBUG :: Release has linked Deezer album ID ${lidarrReleaseLinkedDeezerAlbumId}, evaluating directly..."
                set_state "deezerCandidateAlbumID" "${lidarrReleaseLinkedDeezerAlbumId}"
                EvaluateDeezerAlbumCandidate
            else
                # First search through the artist's Deezer albums to find a match on album title and track count
                log "DEBUG :: Starting search with searchReleaseTitle: ${searchReleaseTitle}"
                if [ "${lidarrArtistForeignArtistId}" != "${VARIOUS_ARTIST_ID_MUSICBRAINZ}" ]; then
                    for dId in "${!deezerArtistIds[@]}"; do
                        local deezerArtistId="${deezerArtistIds[$dId]}"
                        ArtistDeezerSearch "${deezerArtistId}"
                    done

                    # Fuzzy search with album and artist name
                    exactMatchFound="$(get_state "exactMatchFound")"
                    if [ "${exactMatchFound}" != "true" ]; then
                        FuzzyDeezerSearch "${lidarrArtistName}"
                    fi
                fi

                # Fuzzy search with only album name
                exactMatchFound="$(get_state "exactMatchFound")"
                if [ "${exactMatchFound}" != "true" ]; then
                    FuzzyDeezerSearch
                fi
            fi
        done
    done

    log "TRACE :: Exiting FindDeezerMatch..."
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
    local lidarrReleaseLinkedDeezerAlbumId=$(get_state "lidarrReleaseLinkedDeezerAlbumId")

    local bestMatchNameDiff="$(get_state "bestMatchNameDiff")"
    local bestMatchTrackDiff="$(get_state "bestMatchTrackDiff")"
    local bestMatchYearDiff="$(get_state "bestMatchYearDiff")"
    local bestMatchNumTracks="$(get_state "bestMatchNumTracks")"
    local bestMatchDeezerLyricTypePreferred="$(get_state "bestMatchDeezerLyricTypePreferred")"
    local bestMatchFormatPriority="$(get_state "bestMatchFormatPriority")"
    local bestMatchCountryPriority="$(get_state "bestMatchCountryPriority")"
    local bestMatchLidarrReleaseLinkedDeezerAlbumId=$(get_state "bestMatchLidarrReleaseLinkedDeezerAlbumId")

    # Compare against current best-match globals
    log "DEBUG :: Comparing candidate (NameDiff=${candidateNameDiff}, TrackDiff=${candidateTrackDiff}, YearDiff=${candidateYearDiff}, NumTracks=${deezerCandidateTrackCount}, LyricPreferred=${deezerCandidatelyricTypePreferred}, FormatPriority=${lidarrReleaseFormatPriority}, CountryPriority=${lidarrReleaseCountryPriority}) against best match (Diff=${bestMatchNameDiff}, TrackDiff=${bestMatchTrackDiff}, YearDiff=${bestMatchYearDiff}, NumTracks=${bestMatchNumTracks}, LyricPreferred=${bestMatchDeezerLyricTypePreferred}, FormatPriority=${bestMatchFormatPriority}, CountryPriority=${bestMatchCountryPriority})"

    # Primary match criteria
    # 1. Name difference
    # 2. Track number difference
    if ((candidateNameDiff < bestMatchNameDiff)); then
        return 0
    elif ((candidateNameDiff > bestMatchNameDiff)); then
        return 1
    elif ((candidateTrackDiff < bestMatchTrackDiff)); then
        return 0
    elif ((candidateTrackDiff > bestMatchTrackDiff)); then
        return 1
    else
        # Secondary criteria
        # 1. Has a linked Deezer album ID
        # 2. Release country
        # 3. Track count
        # 4. Lyric preference (Deezer)
        # 5. Published year difference
        # 6. Release format
        if [[ -n "${lidarrReleaseLinkedDeezerAlbumId}" && -z "${bestMatchLidarrReleaseLinkedDeezerAlbumId}" ]]; then
            return 0
        elif [[ -z "${lidarrReleaseLinkedDeezerAlbumId}" && -n "${bestMatchLidarrReleaseLinkedDeezerAlbumId}" ]]; then
            return 1
        elif ((lidarrReleaseCountryPriority < bestMatchCountryPriority)); then
            return 0
        elif ((lidarrReleaseCountryPriority > bestMatchCountryPriority)); then
            return 1
        elif ((deezerCandidateTrackCount > bestMatchNumTracks)); then
            return 0
        elif ((deezerCandidateTrackCount < bestMatchNumTracks)); then
            return 1
        elif [[ "$deezerCandidatelyricTypePreferred" == "true" && "$bestMatchDeezerLyricTypePreferred" == "false" ]]; then
            return 0
        elif [[ "$deezerCandidatelyricTypePreferred" == "false" && "$bestMatchDeezerLyricTypePreferred" == "true" ]]; then
            return 1
        elif ((candidateYearDiff < bestMatchYearDiff)); then
            return 0
        elif ((candidateYearDiff > bestMatchYearDiff)); then
            return 1
        elif ((lidarrReleaseFormatPriority < bestMatchFormatPriority)); then
            return 0
        elif ((lidarrReleaseFormatPriority > bestMatchFormatPriority)); then
            return 1
        else
            # Tiebreaker criteria. Generally applies when multiple MusicBrainz releases map to the same Deezer release.
            # 1. Tiebreaker country priority
            # 2. Lyric preference (Lidarr). Not included in secondary criteria as it may not be set for all releases in MusicBrainz database.
            # 3. Alphabetical order of MBID (lowest first)
            local lidarrReleaseTiebreakerCountryPriority="$(get_state "lidarrReleaseTiebreakerCountryPriority")"
            local bestMatchTiebreakerCountryPriority="$(get_state "bestMatchTiebreakerCountryPriority")"
            local bestMatchReleaseLyricTypePreferred="$(get_state "bestMatchReleaseLyricTypePreferred")"
            local lidarrReleaseLyricTypePreferred="$(get_state "lidarrReleaseLyricTypePreferred")"
            if ((lidarrReleaseTiebreakerCountryPriority < bestMatchTiebreakerCountryPriority)); then
                return 0
            elif ((lidarrReleaseTiebreakerCountryPriority > bestMatchTiebreakerCountryPriority)); then
                return 1
            elif [[ "$bestMatchReleaseLyricTypePreferred" == "false" && "$lidarrReleaseLyricTypePreferred" == "true" ]]; then
                return 0
            elif [[ "$bestMatchReleaseLyricTypePreferred" == "true" && "$lidarrReleaseLyricTypePreferred" == "false" ]]; then
                return 1
            else
                local lidarrReleaseForeignId="$(get_state "lidarrReleaseForeignId")"
                local bestMatchLidarrReleaseForeignId="$(get_state "bestMatchLidarrReleaseForeignId")"
                if [[ "${lidarrReleaseForeignId}" < "${bestMatchLidarrReleaseForeignId}" ]]; then
                    return 0
                fi
            fi
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

# Calculate Levenshtein distance between two strings (integer-only, hardened)
LevenshteinDistance() {
    local s1="${1:-}"
    local s2="${2:-}"

    local len_s1=${#s1}
    local len_s2=${#s2}

    # Empty string fast-paths (guaranteed integers)
    if ((len_s1 == 0)); then
        printf '%d\n' "$len_s2"
        return 0
    fi
    if ((len_s2 == 0)); then
        printf '%d\n' "$len_s1"
        return 0
    fi

    local -a prev curr
    local i j

    # Initialize first row
    for ((j = 0; j <= len_s2; j++)); do
        prev[j]=$j
    done

    for ((i = 1; i <= len_s1; i++)); do
        curr[0]=$i
        local s1_char="${s1:i-1:1}"

        for ((j = 1; j <= len_s2; j++)); do
            local s2_char="${s2:j-1:1}"
            local cost=1
            [[ "$s1_char" == "$s2_char" ]] && cost=0

            # All operands guaranteed integers
            local del=$((prev[j] + 1))
            local ins=$((curr[j - 1] + 1))
            local sub=$((prev[j - 1] + cost))

            local min=$del
            ((ins < min)) && min=$ins
            ((sub < min)) && min=$sub

            curr[j]=$min
        done

        # Copy row safely
        prev=("${curr[@]}")
    done

    # Final guard — should never trigger, but guarantees integer output
    if [[ "${curr[len_s2]:-}" =~ ^[0-9]+$ ]]; then
        printf '%d\n' "${curr[len_s2]}"
    else
        printf '0\n'
    fi
}

# Loads title replacements from the specified replacement file.
LoadTitleReplacements() {
    # Preload title replacement file
    if [[ -f "${AUDIO_TITLE_REPLACEMENTS_FILE}" ]]; then
        log "DEBUG :: Loading custom title replacements from ${AUDIO_TITLE_REPLACEMENTS_FILE}"
        while IFS="=" read -r key value; do
            key="$(normalize_string "$key")"
            value="$(normalize_string "$value")"
            set_state "titleReplacement_${key}" "$value"
            log "DEBUG :: Loaded title replacement: ${key} -> ${value}"
        done < <(
            jq -r 'to_entries[] | "\(.key)=\(.value)"' "${AUDIO_TITLE_REPLACEMENTS_FILE}" 2>/dev/null
        )
    else
        log "DEBUG :: No custom title replacements file found (${AUDIO_TITLE_REPLACEMENTS_FILE})"
    fi
}

# Normalize a Deezer album title (truncate and apply replacements)
NormalizeDeezerAlbumTitle() {
    local deezerCandidateTitle="$1"

    # Normalize title and remove punctuation
    local titleClean="$(normalize_string "$deezerCandidateTitle")"
    titleClean="$(remove_punctuation "$titleClean")"
    # Truncate to 130 characters to avoid excessive lengths
    titleClean="${titleClean:0:130}"

    # Get editionless version and minimal version
    local titleEditionless="$(RemoveEditionsFromAlbumTitle "${titleClean}")"
    local titleMinimal="$(remove_whitespace "${titleEditionless}")"

    # Apply replacements
    titleClean="$(ApplyTitleReplacements "${titleClean}")"
    titleEditionless="$(ApplyTitleReplacements "${titleEditionless}")"
    titleMinimal="$(ApplyTitleReplacements "${titleMinimal}")"

    # Trim leading/trailing whitespace
    titleClean="${titleClean%"${titleClean##*[![:space:]]}"}"
    titleEditionless="${titleEditionless%"${titleEditionless##*[![:space:]]}"}"
    titleMinimal="${titleMinimal%"${titleMinimal##*[![:space:]]}"}"

    # Set into state
    set_state "deezerCandidateTitleClean" "${titleClean}"
    set_state "deezerCandidateTitleEditionless" "${titleEditionless}"
    set_state "deezerCandidateTitleMinimal" "${titleMinimal}"
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
        "soundtrack from the motion picture"
        "soundtrack"
    )

    # Handle numeric Anniversary or Remaster patterns FIRST
    shopt -s nocasematch

    # Ordinals: numeric + word
    ordinal='[0-9]+(st|nd|rd|th)|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|twentieth'

    # 1) Remove parenthesized Anniversary / Remaster
    title="$(sed -E "
        s/[[:space:]]*\([[:space:]]*(($ordinal)[[:space:]]+anniversary|[0-9]{4}[[:space:]]+remaster(ed)?)([[:space:]]+(edition|version))?[[:space:]]*\)//Ig
    " <<<"$title")"

    # 2) Remove bare Anniversary / Remaster
    title="$(sed -E "
        s/[[:space:]]+(($ordinal)[[:space:]]+anniversary|[0-9]{4}[[:space:]]+remaster(ed)?)([[:space:]]+(edition|version))?//Ig
    " <<<"$title")"

    shopt -u nocasematch

    # Filter only patterns that exist in the title
    local p
    for p in "${patterns[@]}"; do
        if [[ "$lower" == *"$p"* ]]; then
            # Call your existing complex logic
            title=$(RemovePatternFromString "$title" "$p")
        fi
    done

    printf '%s\n' "$title"
}

# Remove common modifiers from a track title
RemoveModifiersFromTrackTitle() {
    local title="$1"
    local lower="${title,,}"

    local patterns=(
        "live acoustic"
        "live"
        "acoustic"
        "remix"
        "radio edit"
        "edit"
        "version"
        "instrumental"
        "demo"
        "explicit"
        "clean"
    )

    local p
    for p in "${patterns[@]}"; do
        if [[ "$lower" == *"$p"* ]]; then
            title=$(RemovePatternFromString "$title" "$p")
        fi
    done

    printf '%s\n' "$title"
}

# Remove a pattern from a string
RemovePatternFromString() {
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
    set_state "bestMatchTitleWithDisambiguation" ""
    set_state "bestMatchYear" ""
    set_state "bestMatchNameDiff" 9999
    set_state "bestMatchTrackDiff" 9999
    set_state "bestMatchNumTracks" 0
    set_state "bestMatchContainsCommentary" "false"
    set_state "bestMatchReleaseLyricTypePreferred" "false"
    set_state "bestMatchLidarrReleaseForeignId" ""
    set_state "bestMatchFormatPriority" "999"
    set_state "bestMatchCountryPriority" "999"
    set_state "bestMatchTiebreakerCountryPriority" "999"
    set_state "bestMatchDeezerLyricTypePreferred" "false"
    set_state "bestMatchDisambiguationRarities" ""
    set_state "bestMatchYearDiff" 999
    set_state "bestMatchLidarrReleaseLinkedDeezerAlbumId" ""
    set_state "exactMatchFound" "false"
}

# Set lidarrTitlesToSearch state variable with various title permutations
SetLidarrTitlesToSearch() {
    local lidarrReleaseTitle="$1"
    local lidarrReleaseDisambiguation="$2"

    # Search for base title
    local lidarrTitlesToSearch=()
    local normalizedTile=$(normalize_string "${lidarrReleaseTitle}")
    normalizedTile=$(remove_punctuation "${normalizedTile}")
    lidarrTitlesToSearch+=("${normalizedTile}")

    _add_unique() {
        local value="$1"
        shift
        if [[ -z "${value}" ]]; then
            return 0
        fi
        log "TRACE :: Checking uniqueness of title: ${value}"
        for existing in "$@"; do
            [[ "$existing" == "$value" ]] && return 0 # already exists, do nothing
        done
        log "TRACE :: Adding unique title to search list: ${value}"
        lidarrTitlesToSearch+=("$value")
    }

    # Search for title without edition suffixes
    local titleNoEditions=$(RemoveEditionsFromAlbumTitle "${normalizedTile}")
    _add_unique "${titleNoEditions}" "${lidarrTitlesToSearch[@]}"

    # Search for title with release disambiguation
    local lidarrReleaseTitleWithReleaseDisambiguation="$(AddDisambiguationToTitle "${normalizedTile}" "${lidarrReleaseDisambiguation}")"
    _add_unique "${lidarrReleaseTitleWithReleaseDisambiguation}" "${lidarrTitlesToSearch[@]}"
    set_state "lidarrReleaseTitleWithReleaseDisambiguation" "${lidarrReleaseTitleWithReleaseDisambiguation}"

    # Search for title with album disambiguation
    local albumDisambiguation=$(get_state "lidarrAlbumDisambiguation")
    if [[ -n "${albumDisambiguation}" && "${albumDisambiguation}" != "null" && "${albumDisambiguation}" != "" ]]; then
        local lidarrTitleWithAlbumDisambiguation="$(AddDisambiguationToTitle "${normalizedTile}" "${albumDisambiguation}")"
        _add_unique "${lidarrTitleWithAlbumDisambiguation}" "${lidarrTitlesToSearch[@]}"
    fi

    # Search for title without edition suffixes and added album disambiguation
    if [[ -n "${albumDisambiguation}" && "${albumDisambiguation}" != "null" && "${albumDisambiguation}" != "" ]]; then
        local titleNoEditionsWithAlbumDisambiguation="$(AddDisambiguationToTitle "${titleNoEditions}" "${albumDisambiguation}")"
        _add_unique "${titleNoEditionsWithAlbumDisambiguation}" "${lidarrTitlesToSearch[@]}"
    fi

    # Search for title with release disambiguation and no whitespace
    local titleWithDisambiguationNoWhitespace="$(remove_whitespace "${lidarrReleaseTitleWithReleaseDisambiguation}")"
    _add_unique "${titleWithDisambiguationNoWhitespace}" "${lidarrTitlesToSearch[@]}"

    # Search for minimal title (without edition suffixes and without whitespace)
    local titleMinimal=$(remove_whitespace "${titleNoEditions}")
    _add_unique "${titleMinimal}" "${lidarrTitlesToSearch[@]}"

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
    local lidarrReleaseForeignId=$(get_state "lidarrReleaseForeignId")
    log "TRACE :: Checking candidate ${lidarrReleaseForeignId}"

    # Optionally only consider releases that have linked Deezer albums
    if [[ "${AUDIO_REQUIRE_MUSICBRAINZ_REL}" == "true" ]]; then
        local lidarrReleaseLinkedDeezerAlbumId=$(get_state "lidarrReleaseLinkedDeezerAlbumId")
        if [[ -z "${lidarrReleaseLinkedDeezerAlbumId}" ]]; then
            log "DEBUG :: Current candidate does not have a linked Deezer album; Skipping..."
            return 0
        fi
    fi

    # Skip releases that are not "Official"
    local lidarrReleaseStatus=$(get_state "lidarrReleaseStatus")
    if [[ "${lidarrReleaseStatus}" != "Official" ]]; then
        log "DEBUG :: Current candidate is not an official release. Skipping..."
        return 0
    fi

    # De-prioritize releases that are "rarities" specials
    local bestMatchDisambiguationRarities=$(get_state "bestMatchDisambiguationRarities")
    local lidarrReleaseDisambiguationRarities=$(get_state "lidarrReleaseDisambiguationRarities")
    if [[ "${lidarrReleaseDisambiguationRarities}" == "true" && "${bestMatchDisambiguationRarities}" == "false" ]]; then
        log "DEBUG :: Current candidate is marked as \"rarities\" while best match is not. Skipping..."
        return 0
    elif [[ "${lidarrReleaseDisambiguationRarities}" == "false" && "${bestMatchDisambiguationRarities}" == "true" ]]; then
        log "DEBUG :: Current candidate is not marked as \"rarities\" while best match is. Proceeding..."
        return 1
    fi

    # Optionally de-prioritize releases that contain commentary tracks
    local bestMatchContainsCommentary=$(get_state "bestMatchContainsCommentary")
    local lidarrReleaseContainsCommentary=$(get_state "lidarrReleaseContainsCommentary")
    if [[ "${AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES}" == "true" ]]; then
        if [[ "${lidarrReleaseContainsCommentary}" == "true" && "${bestMatchContainsCommentary}" == "false" ]]; then
            log "DEBUG :: Current candidate has commentary while best match does not. Skipping..."
            return 0
        elif [[ "${lidarrReleaseContainsCommentary}" == "false" && "${bestMatchContainsCommentary}" == "true" ]]; then
            log "DEBUG :: Current candidate does not have commentary while best match does. Proceeding..."
            return 1
        fi
    fi

    # Optionally ignore instrumental releases
    if [[ "${AUDIO_IGNORE_INSTRUMENTAL_RELEASES}" == "true" ]]; then
        local lidarrReleaseIsInstrumental=$(get_state "lidarrReleaseIsInstrumental")
        if [[ "${lidarrReleaseIsInstrumental}" == "true" ]]; then
            log "DEBUG :: Current candidate is marked as instrumental. Skipping..."
            return 0
        fi
    fi

    # If a exact match has been found, we only want to process releases that are potentially better matches
    local exactMatchFound="$(get_state "exactMatchFound")"
    if [ "${exactMatchFound}" == "true" ]; then
        # If best match has linked Deezer album, only consider releases that also have linked Deezer albums
        local bestMatchLidarrReleaseLinkedDeezerAlbumId=$(get_state "bestMatchLidarrReleaseLinkedDeezerAlbumId")
        local lidarrReleaseLinkedDeezerAlbumId=$(get_state "lidarrReleaseLinkedDeezerAlbumId")
        if [[ -n "${bestMatchLidarrReleaseLinkedDeezerAlbumId}" && -z "${lidarrReleaseLinkedDeezerAlbumId}" ]]; then
            log "DEBUG :: Best match has linked Deezer album while current candidate does not; Skipping..."
            return 0
        elif [[ -z "${bestMatchLidarrReleaseLinkedDeezerAlbumId}" && -n "${lidarrReleaseLinkedDeezerAlbumId}" ]]; then
            log "DEBUG :: Current candidate has linked Deezer album while best match does not; Proceeding..."
            return 1
        fi

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

        # Same or better number of tracks
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

        # Same or better lyric preference
        local bestMatchReleaseLyricTypePreferred lidarrReleaseLyricTypePreferred
        bestMatchReleaseLyricTypePreferred="$(get_state "bestMatchReleaseLyricTypePreferred")"
        lidarrReleaseLyricTypePreferred="$(get_state "lidarrReleaseLyricTypePreferred")"
        if [[ "${lidarrReleaseLyricTypePreferred}" == "true" && "${bestMatchReleaseLyricTypePreferred}" == "false" ]]; then
            log "DEBUG :: Current candidate has preferred lyric type while best match does not. Proceeding..."
            return 1
        elif [[ "${lidarrReleaseLyricTypePreferred}" == "false" && "${bestMatchReleaseLyricTypePreferred}" == "true" ]]; then
            log "DEBUG :: Current candidate does not have preferred lyric type while best match does. Skipping..."
            return 0
        fi

        # Same or better tiebreaker country match
        local bestMatchTiebreakerCountryPriority lidarrReleaseTiebreakerCountryPriority
        bestMatchTiebreakerCountryPriority="$(get_state "bestMatchTiebreakerCountryPriority")"
        lidarrReleaseTiebreakerCountryPriority="$(get_state "lidarrReleaseTiebreakerCountryPriority")"
        if ! is_numeric "$bestMatchTiebreakerCountryPriority" || ! is_numeric "$lidarrReleaseTiebreakerCountryPriority"; then
            # Don't skip, error should be caught somewhere downstream
            return 1
        fi
        if ((lidarrReleaseTiebreakerCountryPriority < bestMatchTiebreakerCountryPriority)); then
            log "DEBUG :: Current candidate has better tiebreaker country priority than best match; Proceeding..."
            return 1
        elif ((lidarrReleaseTiebreakerCountryPriority > bestMatchTiebreakerCountryPriority)); then
            log "DEBUG :: Current candidate has worse tiebreaker country priority than best match; Skipping..."
            return 0
        fi

        # Same or longer title with disambiguation
        local bestMatchTitleWithDisambiguation lidarrReleaseTitleWithReleaseDisambiguation
        lidarrReleaseTitleWithReleaseDisambiguation="$(get_state "lidarrReleaseTitleWithReleaseDisambiguation")"
        bestMatchTitleWithDisambiguation="$(get_state "bestMatchTitleWithDisambiguation")"
        if ((${#lidarrReleaseTitleWithReleaseDisambiguation} > ${#bestMatchTitleWithDisambiguation})); then
            log "DEBUG :: Current candidate has longer title with disambiguation than best match; Proceeding..."
            return 1
        elif ((${#lidarrReleaseTitleWithReleaseDisambiguation} < ${#bestMatchTitleWithDisambiguation})); then
            log "DEBUG :: Current candidate has shorter title with disambiguation than best match; Skipping..."
            return 0
        fi

        # Same or better MusicBrainz ID (alphabetically)
        local bestMatchLidarrReleaseForeignId lidarrReleaseForeignId
        lidarrReleaseForeignId="$(get_state "lidarrReleaseForeignId")"
        bestMatchLidarrReleaseForeignId="$(get_state "bestMatchLidarrReleaseForeignId")"
        if [[ "${lidarrReleaseForeignId}" < "${bestMatchLidarrReleaseForeignId}" ]]; then
            log "DEBUG :: Current candidate has better MBID than best match; Proceeding..."
            return 1
        elif [[ "${lidarrReleaseForeignId}" > "${bestMatchLidarrReleaseForeignId}" ]]; then
            log "DEBUG :: Current candidate has worse MBID than best match; Skipping..."
            return 0
        fi

        log "DEBUG :: Current candidate is not better in any measured attribute; Skipping..."
        return 0
    fi

    return 1
}

# Strips artist feature / parody tags from a track name
# Strips artist feature / parody tags from a track name
StripTrackFeature() {
    sed -E '
        # 1) Remove parenthetical feature/parody/adaptation annotations
        s/[[:space:]]*\((feat\.?|ft\.?|featuring|duet[[:space:]]+with|with|parody[[:space:]]+of|an[[:space:]]+adaptation[[:space:]]+of|lyrical[[:space:]]+adapt(ation|ion)[[:space:]]+of)[^)]*\)//Ig;

        # 2) Remove dash-separated suffix annotations
        s/[[:space:]]*[-–—][[:space:]]*(feat\.?|ft\.?|featuring|duet[[:space:]]+with|with|parody[[:space:]]+of|an[[:space:]]+adaptation[[:space:]]+of|lyrical[[:space:]]+adapt(ation|ion)[[:space:]]+of)[[:space:]].*$//Ig;

        # 3) Remove bare trailing feature annotations
        s/[[:space:]]+(feat\.?|ft\.?|featuring|duet[[:space:]]+with)[[:space:]].*$//Ig
        s/[[:space:]]+with[[:space:]]+[A-Z][^[:space:]]+.*$//g

        # 4) Remove prose-style parody/adaptation metadata when quoted
        s/[[:space:]]+(parody|an[[:space:]]+adaptation|lyrical[[:space:]]+adapt(ation|ion))[[:space:]]+of[[:space:]]+"[^"]+".*$//Ig;

        # 5) Normalize whitespace
        s/[[:space:]]+/ /g;
        s/^ //;
        s/ $//;
    ' <<<"$1"
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
    local lidarrReleaseTiebreakerCountryPriority="$(get_state "lidarrReleaseTiebreakerCountryPriority")"
    local deezerCandidatelyricTypePreferred="$(get_state "deezerCandidatelyricTypePreferred")"
    local lidarrReleaseContainsCommentary="$(get_state "lidarrReleaseContainsCommentary")"
    local lidarrReleaseLyricTypePreferred="$(get_state "lidarrReleaseLyricTypePreferred")"
    local lidarrReleaseForeignId="$(get_state "lidarrReleaseForeignId")"
    local lidarrReleaseTitleWithReleaseDisambiguation="$(get_state "lidarrReleaseTitleWithReleaseDisambiguation")"
    local lidarrReleaseLinkedDeezerAlbumId="$(get_state "lidarrReleaseLinkedDeezerAlbumId")"
    local lidarrReleaseDisambiguationRarities=$(get_state "lidarrReleaseDisambiguationRarities")

    set_state "bestMatchID" "${deezerCandidateAlbumID}"
    set_state "bestMatchTitle" "${deezerCandidateTitleVariant}"
    set_state "bestMatchNameDiff" "${candidateNameDiff}"
    set_state "bestMatchTrackDiff" "${candidateTrackDiff}"
    set_state "bestMatchYearDiff" "${candidateYearDiff}"

    set_state "bestMatchYear" "${deezerCandidateReleaseYear}"
    set_state "bestMatchNumTracks" "${deezerCandidateTrackCount}"
    set_state "bestMatchFormatPriority" "${lidarrReleaseFormatPriority}"
    set_state "bestMatchCountryPriority" "${lidarrReleaseCountryPriority}"
    set_state "bestMatchTiebreakerCountryPriority" "${lidarrReleaseTiebreakerCountryPriority}"
    set_state "bestMatchDeezerLyricTypePreferred" "${deezerCandidatelyricTypePreferred}"
    set_state "bestMatchContainsCommentary" "${lidarrReleaseContainsCommentary}"
    set_state "bestMatchReleaseLyricTypePreferred" "${lidarrReleaseLyricTypePreferred}"
    set_state "bestMatchLidarrReleaseForeignId" "${lidarrReleaseForeignId}"
    set_state "bestMatchTitleWithDisambiguation" "${lidarrReleaseTitleWithReleaseDisambiguation}"
    set_state "bestMatchLidarrReleaseLinkedDeezerAlbumId" "${lidarrReleaseLinkedDeezerAlbumId}"
    set_state "bestMatchDisambiguationRarities" "${lidarrReleaseDisambiguationRarities}"

    # Check for exact match
    if is_numeric "$candidateNameDiff" && is_numeric "$candidateTrackDiff"; then
        if ((candidateNameDiff == 0 && candidateTrackDiff == 0)); then
            log "INFO :: New best match: ${deezerCandidateTitleVariant} (${deezerCandidateAlbumID}) - Exact Match"
            set_state "exactMatchFound" "true"
        fi
    else
        log "INFO :: New best match: ${deezerCandidateTitleVariant} (${deezerCandidateAlbumID})"
    fi
}

# Write the result of search process to the result file
WriteResultFile() {
    if [[ -n "${AUDIO_DEEMIX_ARL_FILE}" ]]; then
        local outFile="${AUDIO_WORK_PATH}/${AUDIO_RESULT_FILE_NAME}"

        local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        local lidarrArtistName="$(get_state "lidarrArtistName")"
        local lidarrAlbumTitle="$(get_state "lidarrAlbumTitle")"
        local lidarrAlbumId="$(get_state "lidarrAlbumId")"
        local lidarrAlbumForeignAlbumId="$(get_state "lidarrAlbumForeignAlbumId")"

        local result="No match"
        local bestMatchLidarrReleaseForeignId=""
        local deezerId="$(get_state "bestMatchID")"
        if [[ -n "${deezerId}" ]]; then
            result="Matched"
            bestMatchLidarrReleaseForeignId="$(get_state "bestMatchLidarrReleaseForeignId")"
        fi

        # Create file + header if missing
        if [[ ! -f "$outFile" ]]; then
            {
                echo "# Download Match History"
                echo
                echo "| Timestamp | Artist | Album | Album Id | Release Group Id | Result | Release Id | Deezer Id |"
                echo "|-----------|--------|-------|----------|------------------|--------|------------|-----------|"
            } >"$outFile"
        fi

        # Append row
        printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
            "$timestamp" \
            "$lidarrArtistName" \
            "$lidarrAlbumTitle" \
            "$lidarrAlbumId" \
            "$lidarrAlbumForeignAlbumId" \
            "$result" \
            "$bestMatchLidarrReleaseForeignId" \
            "$deezerId" \
            >>"$outFile"
    fi
}
