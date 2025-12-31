#!/usr/bin/env bash

declare -A TRACK_SEP=$'\x1f'

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
            if safe_jq --optional '.' <<<"${body}" >/dev/null 2>&1; then
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

    # First-pass comparison: plain titles
    local d="$(LevenshteinDistance "${lidarrTrackTitle,,}" "${deezerTrackTitle,,}")"
    log "DEBUG :: Calculated distance \"$lidarrTrackTitle\" to \"$deezerTrackTitle\": $d"

    if [[ "$d" =~ ^[0-9]+$ ]]; then

        # Second-pass comparison: strip feature annotations from Deezer title
        if ((d > 0)); then
            local deezerTrackTitleStripped
            deezerTrackTitleStripped="$(StripTrackFeature "$deezerTrackTitle")"

            if [[ -n "$deezerTrackTitleStripped" && "$deezerTrackTitleStripped" != "$deezerTrackTitle" ]]; then
                local d2
                d2="$(LevenshteinDistance "${lidarrTrackTitle,,}" "${deezerTrackTitleStripped,,}")"
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitle\" to \"$deezerTrackTitleStripped\" (feature stripped): $d2"

                ((d2 < d)) && d="$d2"
            fi
        fi

        # Third-pass comparison: use long Deezer title
        if ((d > 0)); then
            if [[ -n "$deezerLongTrackTitle" && "$deezerLongTrackTitle" != "$deezerTrackTitle" ]]; then
                local d3
                d3="$(LevenshteinDistance "${lidarrTrackTitle,,}" "${deezerLongTrackTitle,,}")"
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitle\" to \"$deezerLongTrackTitle\" (long title): $d3"

                ((d3 < d)) && d="$d3"
            fi
        fi

        # Fourth-pass comparison: remove album title from track title (niche case)
        if ((d > 0)); then
            local deezerTrackTitleStripped
            local searchReleaseTitleClean="$(get_state "searchReleaseTitleClean")"
            deezerTrackTitleStripped="$(RemovePatternFromString "$deezerTrackTitle" "${searchReleaseTitleClean}")"

            if [[ -n "$deezerTrackTitleStripped" && "$deezerTrackTitleStripped" != "$deezerTrackTitle" ]]; then
                local d4
                d4="$(LevenshteinDistance "${lidarrTrackTitle,,}" "${deezerTrackTitleStripped,,}")"
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitle\" to \"$deezerTrackTitleStripped\" (album title stripped): $d4"

                ((d4 < d)) && d="$d4"
            fi
        fi

        # Fifth-pass comparison: remove spaces and punctuation from track title (niche case)
        if ((d > 0)); then
            local deezerTrackTitleStripped
            local searchReleaseTitleClean="$(get_state "searchReleaseTitleClean")"

            deezerTrackTitleStripped="$(tr -cd '[:alnum:]' <<<"$deezerTrackTitle")"

            if [[ -n "$deezerTrackTitleStripped" && "$deezerTrackTitleStripped" != "$deezerTrackTitle" ]]; then
                local d5
                d5="$(LevenshteinDistance "${lidarrTrackTitle,,}" "${deezerTrackTitleStripped,,}")"
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitle\" to \"$deezerTrackTitleStripped\" (no spaces): $d5"

                ((d5 < d)) && d="$d5"
            fi
        fi

        # Sixth-pass comparison: substring containment (Deezer ⊆ Lidarr or Lidarr ⊆ Deezer)
        if ((d > 0)); then
            if [[ " ${deezerTrackTitle,,} " == *" ${lidarrTrackTitle,,} "* ]] ||
                [[ " ${lidarrTrackTitle,,} " == *" ${deezerTrackTitle,,} "* ]]; then
                # Treat as a close match
                local d6=5
                log "DEBUG :: Recalculated distance \"$lidarrTrackTitle\" to \"$deezerTrackTitle\" (contains check): $d6"
                ((d6 < d)) && d="$d6"
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
    [[ -n "$lidarr_raw" ]] && IFS="$TRACK_SEP" read -r -a lidarr_tracks <<<"$lidarr_raw"
    [[ -n "$lidarr_recording_raw" ]] && IFS="$TRACK_SEP" read -r -a lidarr_recordings <<<"$lidarr_recording_raw"
    [[ -n "$deezer_raw" ]] && IFS="$TRACK_SEP" read -r -a deezer_tracks <<<"$deezer_raw"
    [[ -n "$deezer_long_raw" ]] && IFS="$TRACK_SEP" read -r -a deezer_long_tracks <<<"$deezer_long_raw"

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
        local lidarr_track_norm=() lidarr_recording_norm=() deezer_norm=() deezer_long_norm=()
        for t in "${lidarr_tracks[@]}"; do
            lidarr_track_norm+=("$(normalize_string "$t")")
        done
        for t in "${lidarr_recordings[@]}"; do
            lidarr_recording_norm+=("$(normalize_string "$t")")
        done
        for t in "${deezer_tracks[@]}"; do
            deezer_norm+=("$(normalize_string "$t")")
        done
        for t in "${deezer_long_tracks[@]}"; do
            deezer_long_norm+=("$(normalize_string "$t")")
        done

        for ((i = 0; i < max_len; i++)); do
            CompareTrack "${lidarr_track_norm[i]:-}" "${deezer_norm[i]:-}" "${deezer_long_norm[i]:-}"
            local d="$(get_state "trackTitleDiff")"
            if ((d > 0)); then
                CompareTrack "${lidarr_recording_norm[i]:-}" "${deezer_norm[i]:-}" "${deezer_long_norm[i]:-}"
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

    if ((${#track_titles[@]} > 0)); then
        deezerCandidateTrackTitles="$(printf "%s${TRACK_SEP}" "${track_titles[@]}")"
        deezerCandidateTrackTitles="${deezerCandidateTrackTitles%${TRACK_SEP}}"
    fi
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

    if ((${#track_titles_long[@]} > 0)); then
        deezerCandidateLongTrackTitles="$(printf "%s${TRACK_SEP}" "${track_titles_long[@]}")"
        deezerCandidateLongTrackTitles="${deezerCandidateLongTrackTitles%${TRACK_SEP}}"
    fi
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

    # Extract track titles
    local recording_titles=()
    local track_titles=()
    local lidarrReleaseRecordingTitles=""
    local lidarrReleaseTrackTitles=""

    while IFS= read -r track_title; do
        [[ -z "$track_title" ]] && continue
        recording_titles+=("$track_title")
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
    if ((${#recording_titles[@]} > 0)); then
        lidarrReleaseRecordingTitles="$(printf "%s${TRACK_SEP}" "${recording_titles[@]}")"
        lidarrReleaseRecordingTitles="${lidarrReleaseRecordingTitles%${TRACK_SEP}}"
    fi
    if ((${#track_titles[@]} > 0)); then
        lidarrReleaseTrackTitles="$(printf "%s${TRACK_SEP}" "${track_titles[@]}")"
        lidarrReleaseTrackTitles="${lidarrReleaseTrackTitles%${TRACK_SEP}}"
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
    set_state "lidarrReleaseCountries" "${lidarrReleaseCountries}"
    set_state "lidarrReleaseRecordingTitles" "${lidarrReleaseRecordingTitles}"
    set_state "lidarrReleaseTrackTitles" "${lidarrReleaseTrackTitles}"

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
    if ((candidateNameDiff < bestMatchNameDiff)); then
        return 0
    elif ((candidateNameDiff == bestMatchNameDiff)) && ((candidateTrackDiff < bestMatchTrackDiff)); then
        return 0
    elif ((candidateNameDiff == bestMatchNameDiff)) && ((candidateTrackDiff == bestMatchTrackDiff)); then
        # Secondary criteria
        # 1. Release country
        # 2. Track count
        # 3. Published year difference
        # 4. Release format
        # 5. Lyric preference
        if ((lidarrReleaseCountryPriority < bestMatchCountryPriority)); then
            return 0
        elif ((lidarrReleaseCountryPriority == bestMatchCountryPriority)) && ((deezerCandidateTrackCount > bestMatchNumTracks)); then
            return 0
        elif ((lidarrReleaseCountryPriority == bestMatchCountryPriority)) && ((deezerCandidateTrackCount == bestMatchNumTracks)) && ((candidateYearDiff < bestMatchYearDiff)); then
            return 0
        elif ((lidarrReleaseCountryPriority == bestMatchCountryPriority)) && ((deezerCandidateTrackCount == bestMatchNumTracks)) && ((candidateYearDiff == bestMatchYearDiff)) && ((lidarrReleaseFormatPriority < bestMatchFormatPriority)); then
            return 0
        elif ((lidarrReleaseCountryPriority == bestMatchCountryPriority)) && ((deezerCandidateTrackCount == bestMatchNumTracks)) && ((candidateYearDiff == bestMatchYearDiff)) && ((lidarrReleaseFormatPriority == bestMatchFormatPriority)) && [[ "$deezerCandidatelyricTypePreferred" == "true" && "$bestMatchLyricTypePreferred" == "false" ]]; then
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

    # Trim leading/trailing whitespace
    titleClean="${titleClean%"${titleClean##*[![:space:]]}"}"
    titleEditionless="${titleEditionless%"${titleEditionless##*[![:space:]]}"}"

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

    # Handle numeric Anniversary or Remaster patterns FIRST
    if [[ "$title" =~ ^(.*)\([[:space:]]*[0-9]+(st|nd|rd|th)[[:space:]]+Anniversary([[:space:]]+(Edition|Version))?[[:space:]]*\)(.*)$ ]]; then
        title="${BASH_REMATCH[1]}${BASH_REMATCH[5]}"
    fi
    if [[ "$title" =~ ^(.*)[[:space:]]+[0-9]+(st|nd|rd|th)[[:space:]]+Anniversary([[:space:]]+(Edition|Version))?(.*)$ ]]; then
        title="${BASH_REMATCH[1]}${BASH_REMATCH[5]}"
    fi
    if [[ "$title" =~ ^(.*)\([[:space:]]*[0-9]{4}[[:space:]]+Remaster(ed)?([[:space:]]+(Edition|Version))?[[:space:]]*\)(.*)$ ]]; then
        title="${BASH_REMATCH[1]}${BASH_REMATCH[5]}"
    fi
    if [[ "$title" =~ ^(.*)[[:space:]]+[0-9]{4}[[:space:]]+Remaster(ed)?([[:space:]]+(Edition|Version))?(.*)$ ]]; then
        title="${BASH_REMATCH[1]}${BASH_REMATCH[5]}"
    fi

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
    set_state "bestMatchYear" ""
    set_state "bestMatchNameDiff" 9999
    set_state "bestMatchTrackDiff" 9999
    set_state "bestMatchNumTracks" 0
    set_state "bestMatchContainsCommentary" "false"
    set_state "bestMatchLidarrReleaseForeignId" ""
    set_state "bestMatchFormatPriority" "999"
    set_state "bestMatchCountryPriority" "999"
    set_state "bestMatchLyricTypePreferred" "false"
    set_state "bestMatchYearDiff" 999
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

        log "DEBUG :: Current candidate is not better in any measured attribute; Skipping..."
        return 0
    fi

    return 1
}

# Strips artist feature / parody tags from a track name
StripTrackFeature() {
    local s="$1"

    # 1) Remove parenthetical annotations
    s="$(sed -E '
        s/[[:space:]]*\((feat\.?|ft\.?|featuring|duet[[:space:]]+with|parody[[:space:]]+of|an[[:space:]]+adaptation[[:space:]]+of|lyrical[[:space:]]+adapt(ation|ion)[[:space:]]+of)[^)]*\)//Ig
    ' <<<"$s")"

    # 2) Remove dash-separated suffix annotations
    s="$(sed -E '
        s/[[:space:]]*[-–—][[:space:]]*(feat\.?|ft\.?|featuring|duet[[:space:]]+with|parody[[:space:]]+of|an[[:space:]]+adaptation[[:space:]]+of|lyrical[[:space:]]+adapt(ation|ion)[[:space:]]+of)[[:space:]].*$//Ig
    ' <<<"$s")"

    # 3) Remove bare trailing feature annotations
    s="$(sed -E '
        s/[[:space:]]+(feat\.?|ft\.?|featuring|duet[[:space:]]+with)[[:space:]].*$//Ig
    ' <<<"$s")"

    # 4) Remove prose-style parody/adaptation metadata
    #    ONLY when followed by a quoted work
    s="$(sed -E '
        s/[[:space:]]+(parody|an[[:space:]]+adaptation|lyrical[[:space:]]+adapt(ation|ion))[[:space:]]+of[[:space:]]+"[^"]+".*$//Ig
    ' <<<"$s")"

    # 5) Normalize whitespace
    s="$(sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' <<<"$s")"

    printf '%s' "$s"
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
    local lidarrReleaseForeignId="$(get_state "lidarrReleaseForeignId")"

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
    set_state "bestMatchLidarrReleaseForeignId" "${lidarrReleaseForeignId}"

    # Check for exact match
    if is_numeric "$candidateNameDiff" && is_numeric "$candidateTrackDiff" && is_numeric "$candidateYearDiff"; then
        if ((candidateNameDiff == 0 && candidateTrackDiff == 0 && candidateYearDiff == 0)); then
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
