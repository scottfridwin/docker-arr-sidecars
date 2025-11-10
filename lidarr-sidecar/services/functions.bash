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
