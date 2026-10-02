#!/usr/bin/env bash
# Output formatting for ac: banner, lists, search results and key/value blocks.
# All user-facing formatting lives here so it can change without touching the
# command logic. Sourced by src/ac.

# Chooses terminal styling. Colors are used only when stdout is a terminal,
# TERM is not "dumb" and NO_COLOR is unset.
# Arguments: none.
# Returns: 0.
# Side effects: sets the globals OUT_BOLD, OUT_DIM, OUT_GREEN and OUT_RESET.
out_init_colors() {
    OUT_BOLD="" OUT_DIM="" OUT_GREEN="" OUT_RESET=""
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
        OUT_BOLD=$'\033[1m'
        OUT_DIM=$'\033[2m'
        OUT_GREEN=$'\033[32m'
        OUT_RESET=$'\033[0m'
    fi
}
out_init_colors

# Prints the product banner, e.g. "AllCrack Package Manager 0.2", plus a blank line.
# Arguments: none.
# Returns: 0.
out_banner() {
    printf '%s%s %s%s\n\n' "$OUT_BOLD" "$AC_NAME" "$AC_SERIES" "$OUT_RESET"
}

# Prints the full version string, e.g. "AllCrack Package Manager 0.2.0".
# Arguments: none.
# Returns: 0.
out_version() {
    printf '%s %s\n' "$AC_NAME" "$AC_VERSION"
}

# Prints a plain informational line to stdout.
# Arguments:
#   $@ - Text to print (an empty call prints a blank line).
# Returns: 0.
out_info() {
    printf '%s\n' "$*"
}

# Prints a titled, indented list followed by a blank line.
# Arguments:
#   $1 - Title line, e.g. "Installing:".
#   $2... - Items, one per line.
# Returns: 0.
out_list_block() {
    local title=$1 item
    shift
    printf '%s\n' "$title"
    for item in "$@"; do
        printf '  %s\n' "$item"
    done
    printf '\n'
}

# Prints one search result in ac's block layout.
# Arguments:
#   $1 - Repository name.
#   $2 - Package name.
#   $3 - Package version.
#   $4 - Architecture (or "unknown").
#   $5 - "1" if the package is installed, otherwise "0".
#   $6 - One-line description.
# Returns: 0.
out_search_result() {
    local tag=""
    if [ "$5" = 1 ]; then
        tag=" ${OUT_GREEN}[installed]${OUT_RESET}"
    fi
    printf '%s%s/%s%s%s\n' "$OUT_BOLD" "$1" "$2" "$OUT_RESET" "$tag"
    printf '  Version: %s\n' "$3"
    printf '  Architecture: %s\n' "$4"
    printf '  Description: %s\n\n' "$6"
}

# Prints an aligned "Key: value" line used by `ac info`.
# Arguments:
#   $1 - Key (without colon).
#   $2 - Value.
# Returns: 0.
out_kv() {
    printf '%-16s%s\n' "$1:" "$2"
}

# Joins its arguments into one string separated by ", ".
# Arguments:
#   $@ - Items to join (may be empty).
# Returns: prints the joined text on stdout, without a trailing newline.
out_join() {
    local item joined=""
    for item in "$@"; do
        joined+="${joined:+, }$item"
    done
    printf '%s' "$joined"
}

# Converts pacman's whitespace-separated dependency list into a comma-separated
# one, e.g. "a  b  c" -> "a, b, c".
# Arguments:
#   $1 - Whitespace-separated items (may be empty).
# Returns: prints the joined list on stdout, without a trailing newline.
out_comma_list() {
    local -a items=()
    read -ra items <<<"$1"
    out_join "${items[@]}"
}
