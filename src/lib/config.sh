#!/usr/bin/env bash
# Configuration for ac. Three settings, all optional:
#
#   color    = auto | always | never   (default auto)
#   confirm  = true | false            (default true; false auto-confirms
#                                       pacman prompts like --yes, but only for
#                                       commands that support --yes)
#   progress = true | false            (default true; "-> doing x..." lines)
#
# Files are read in this order, later ones win: /etc/ac.conf, then the user's
# ~/.config/ac/config. Environment variables AC_COLOR, AC_CONFIRM and
# AC_PROGRESS override both files, NO_COLOR disables color, and command-line
# options (--no-color, --yes) override everything.
#
# Files are parsed line by line as "key = value" with # comments. They are
# NEVER sourced or evaluated; keys and values are checked against an allowlist
# and anything else is reported as a warning and ignored. Sourced by src/ac.
#
# Environment for tests/development: AC_SYSCONF (system file path, default
# /etc/ac.conf) and AC_USERCONF (user file path).

AC_CONF_COLOR=auto
AC_CONF_CONFIRM=true
AC_CONF_PROGRESS=true
declare -ga CFG_WARNINGS=()

# Normalises a boolean word.
# Arguments:
#   $1 - Candidate value (true/false/yes/no/on/off/1/0, any case).
# Returns: 0 and prints "true" or "false" if valid; 1 (no output) otherwise.
cfg_bool() {
    case "${1,,}" in
        true | yes | on | 1) printf 'true' ;;
        false | no | off | 0) printf 'false' ;;
        *) return 1 ;;
    esac
}

# Validates and applies one setting.
# Arguments:
#   $1 - Key (color, confirm or progress).
#   $2 - Value.
#   $3 - Source description for warnings, e.g. "/etc/ac.conf:3".
# Returns: 0 if applied; 1 if the key or value was rejected (a warning is
#   appended to CFG_WARNINGS).
# Side effects: sets AC_CONF_COLOR / AC_CONF_CONFIRM / AC_CONF_PROGRESS.
cfg_apply() {
    local key=$1 value=$2 where=$3 b
    case "$key" in
        color)
            case "${value,,}" in
                auto | always | never) AC_CONF_COLOR=${value,,} ;;
                *)
                    CFG_WARNINGS+=("$where: invalid value '$value' for 'color' (use auto, always or never); ignored")
                    return 1
                    ;;
            esac
            ;;
        confirm | progress)
            if ! b=$(cfg_bool "$value"); then
                CFG_WARNINGS+=("$where: invalid value '$value' for '$key' (use true or false); ignored")
                return 1
            fi
            if [ "$key" = confirm ]; then AC_CONF_CONFIRM=$b; else AC_CONF_PROGRESS=$b; fi
            ;;
        *)
            CFG_WARNINGS+=("$where: unknown setting '$key'; ignored")
            return 1
            ;;
    esac
}

# Reads one configuration file, applying each valid setting. A missing file is
# silently skipped; an unreadable one produces a warning.
# Arguments:
#   $1 - Path of the file.
# Returns: 0.
# Side effects: sets AC_CONF_*; may append to CFG_WARNINGS.
cfg_load_file() {
    local file=$1 line key value n=0
    [ -e "$file" ] || return 0
    if [ ! -r "$file" ] || [ -d "$file" ]; then
        CFG_WARNINGS+=("$file: cannot be read; ignored")
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [ -n "$line" ] || continue
        if [[ $line != *=* ]]; then
            CFG_WARNINGS+=("$file:$n: expected 'key = value'; ignored")
            continue
        fi
        key=${line%%=*}
        value=${line#*=}
        key=${key%"${key##*[![:space:]]}"}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        value=${value#[\"\']}
        value=${value%[\"\']}
        cfg_apply "$key" "$value" "$file:$n" || true
    done <"$file"
}

# Loads the effective configuration: defaults, system file, user file, then
# environment overrides.
# Arguments: none.
# Returns: 0.
# Side effects: sets AC_CONF_*; fills CFG_WARNINGS.
cfg_load() {
    local sys=${AC_SYSCONF:-/etc/ac.conf} user=${AC_USERCONF:-}
    CFG_WARNINGS=()
    if [ -z "$user" ] && [ -n "${XDG_CONFIG_HOME:-${HOME:-}}" ]; then
        user=${XDG_CONFIG_HOME:-$HOME/.config}
        [ -n "${XDG_CONFIG_HOME:-}" ] || user=$HOME/.config
        user=$user/ac/config
    fi
    cfg_load_file "$sys"
    if [ -n "$user" ]; then
        cfg_load_file "$user"
    fi
    if [ -n "${AC_COLOR:-}" ]; then cfg_apply color "$AC_COLOR" "environment AC_COLOR" || true; fi
    if [ -n "${AC_CONFIRM:-}" ]; then cfg_apply confirm "$AC_CONFIRM" "environment AC_CONFIRM" || true; fi
    if [ -n "${AC_PROGRESS:-}" ]; then cfg_apply progress "$AC_PROGRESS" "environment AC_PROGRESS" || true; fi
}
