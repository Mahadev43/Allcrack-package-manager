#!/usr/bin/env bash
# Output layer for ac: all styling and formatting lives here. Commands call
# the out_* helpers and never emit colors or symbols themselves. In --json mode
# every stdout helper below is silent, so stdout carries only the JSON that
# json_emit prints. Sourced by src/ac.

# Style state, safe defaults (plain text). out_init upgrades it once the
# options and configuration are known. OUT_* are for stdout, OUT_E_* for stderr.
OUT_BOLD="" OUT_DIM="" OUT_GREEN="" OUT_RESET=""
OUT_E_RED="" OUT_E_YELLOW="" OUT_E_RESET=""
OUT_SYM_OK="[ok]" OUT_SYM_FAIL="[x]" OUT_SYM_WARN="[!]" OUT_SYM_ARROW="->" OUT_SYM_SKIP="[-]"

# Chooses colors and symbols. Color applies per stream and only when that
# stream is a terminal, the color mode is not "never", TERM is not "dumb",
# NO_COLOR is unset and --no-color was not given; AC_CONF_COLOR=always forces
# it on. Unicode symbols are used when the locale looks like UTF-8, otherwise
# ASCII ones.
# Arguments: none (uses AC_CONF_COLOR, AC_OPT_NOCOLOR, NO_COLOR, TERM, locale).
# Returns: 0. Side effects: sets the OUT_* style variables.
out_init() {
    local mode=${AC_CONF_COLOR:-auto} out_on=0 err_on=0 loc
    OUT_BOLD="" OUT_DIM="" OUT_GREEN="" OUT_RESET=""
    OUT_E_RED="" OUT_E_YELLOW="" OUT_E_RESET=""
    if [ "$AC_OPT_NOCOLOR" -eq 1 ] || { [ -n "${NO_COLOR:-}" ] && [ -z "${AC_COLOR:-}" ]; }; then
        mode=never
    fi
    case "$mode" in
        always) out_on=1 err_on=1 ;;
        never) ;;
        *)
            if [ "${TERM:-dumb}" != dumb ]; then
                [ -t 1 ] && out_on=1
                [ -t 2 ] && err_on=1
            fi
            ;;
    esac
    if [ "$out_on" -eq 1 ]; then
        OUT_BOLD=$'\033[1m' OUT_DIM=$'\033[2m' OUT_GREEN=$'\033[32m' OUT_RESET=$'\033[0m'
    fi
    if [ "$err_on" -eq 1 ]; then
        OUT_E_RED=$'\033[31m' OUT_E_YELLOW=$'\033[33m' OUT_E_RESET=$'\033[0m'
    fi
    loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
    case "$loc" in
        *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*)
            OUT_SYM_OK="✓" OUT_SYM_FAIL="✗" OUT_SYM_WARN="!" OUT_SYM_ARROW="→" OUT_SYM_SKIP="-"
            ;;
        *)
            OUT_SYM_OK="[ok]" OUT_SYM_FAIL="[x]" OUT_SYM_WARN="[!]" OUT_SYM_ARROW="->" OUT_SYM_SKIP="[-]"
            ;;
    esac
}

# Strips control characters (terminal escape sequences, etc.) from text that
# comes from package metadata or logs, so a hostile description cannot
# manipulate the user's terminal.
# Arguments:
#   $1 - Raw text.
# Returns: prints the cleaned text on stdout, without a trailing newline.
out_clean() {
    local s=$1
    printf '%s' "${s//[[:cntrl:]]/}"
}

# Prints the product banner, e.g. "AllCrack Package Manager 0.3", plus a blank
# line. Silent in JSON mode.
# Arguments: none.
# Returns: 0.
out_banner() {
    [ "$AC_OPT_JSON" -eq 1 ] && return 0
    printf '%s%s %s%s\n\n' "$OUT_BOLD" "$AC_NAME" "$AC_SERIES" "$OUT_RESET"
}

# Prints the full version string, e.g. "AllCrack Package Manager 0.3.0".
# Arguments: none.
# Returns: 0.
out_version() {
    printf '%s %s\n' "$AC_NAME" "$AC_VERSION"
}

# Prints a plain informational line to stdout. Silent in JSON mode.
# Arguments:
#   $@ - Text to print (an empty call prints a blank line).
# Returns: 0.
out_info() {
    [ "$AC_OPT_JSON" -eq 1 ] && return 0
    printf '%s\n' "$*"
}

# Prints a progress line ("→ Installing firefox...") unless the progress
# setting is off. Silent in JSON mode.
# Arguments:
#   $@ - Progress text.
# Returns: 0.
out_progress() {
    [ "$AC_OPT_JSON" -eq 1 ] && return 0
    [ "${AC_CONF_PROGRESS:-true}" = true ] || return 0
    printf '%s %s\n' "$OUT_SYM_ARROW" "$*"
}

# Prints a success line ("✓ Installed: firefox") to stdout. Silent in JSON mode.
# Arguments:
#   $@ - Message text.
# Returns: 0.
out_success() {
    [ "$AC_OPT_JSON" -eq 1 ] && return 0
    printf '%s%s%s %s\n' "$OUT_GREEN" "$OUT_SYM_OK" "$OUT_RESET" "$*"
}

# Prints a failure line ("✗ Failed: firefox") to stderr.
# Arguments:
#   $@ - Message text.
# Returns: 0.
out_failure() {
    printf '%s%s%s %s\n' "$OUT_E_RED" "$OUT_SYM_FAIL" "$OUT_E_RESET" "$*" >&2
}

# Prints a warning ("! Warning: ...") to stderr.
# Arguments:
#   $@ - Warning text.
# Returns: 0.
out_warning() {
    printf '%s%s Warning:%s %s\n' "$OUT_E_YELLOW" "$OUT_SYM_WARN" "$OUT_E_RESET" "$*" >&2
}

# Prints one diagnostic line for `ac doctor` to stdout.
# Arguments:
#   $1 - Status: pass, fail, warn or skip.
#   $2 - Check name or message.
# Returns: 0.
out_check() {
    local sym=$OUT_SYM_OK
    case "$1" in
        fail) sym=$OUT_SYM_FAIL ;;
        warn) sym=$OUT_SYM_WARN ;;
        skip) sym=$OUT_SYM_SKIP ;;
    esac
    printf '%s %s\n' "$sym" "$2"
}

# Prints a titled, indented list followed by a blank line. Silent in JSON mode.
# Arguments:
#   $1 - Title line, e.g. "Installing:".
#   $2... - Items, one per line.
# Returns: 0.
out_list_block() {
    local title=$1 item
    shift
    [ "$AC_OPT_JSON" -eq 1 ] && return 0
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
#   $6 - One-line description (control characters are stripped).
# Returns: 0.
out_search_result() {
    local tag="" desc=$6
    [ "$AC_OPT_JSON" -eq 1 ] && return 0
    if [ "$5" = 1 ]; then
        tag=" ${OUT_GREEN}[installed]${OUT_RESET}"
    fi
    printf '%s%s/%s%s%s\n' "$OUT_BOLD" "$1" "$2" "$OUT_RESET" "$tag"
    printf '  Version: %s\n' "$3"
    printf '  Architecture: %s\n' "$4"
    printf '  Description: %s\n\n' "${desc//[[:cntrl:]]/}"
}

# Prints an aligned "Key: value" line used by `ac info` and `ac status`.
# Control characters in the value are stripped.
# Arguments:
#   $1 - Key (without colon).
#   $2 - Value.
# Returns: 0.
out_kv() {
    local v=$2
    [ "$AC_OPT_JSON" -eq 1 ] && return 0
    printf '%-16s%s\n' "$1:" "${v//[[:cntrl:]]/}"
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
