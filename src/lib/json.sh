#!/usr/bin/env bash
# Minimal JSON writer for ac's --json mode. Pure Bash, no external tools.
# Only strings, booleans, numbers and arrays/objects assembled from already
# serialised pieces are supported, which is all ac needs. Sourced by src/ac.
#
# Assumption: input text is valid UTF-8 (pacman's metadata is). Bytes are passed
# through unchanged; control characters are escaped.
#
# The json_quote/json_array helpers return their result through a variable
# NAME (printf -v) instead of stdout so that loops over thousands of packages
# do not fork a subshell per value. Helper-internal variables start with an
# underscore (_s, _e, ...) so a caller's output variable must not use such
# names; every other name is safe.

# Escapes a string for use inside a JSON string literal (without the quotes).
# Arguments:
#   $1 - Name of the variable that receives the escaped text.
#   $2 - The raw text.
# Returns: 0. Side effects: sets the named variable.
json_escape() {
    local _s=$2 _i _c _u
    _s=${_s//\\/\\\\}
    _s=${_s//\"/\\\"}
    _s=${_s//$'\n'/\\n}
    _s=${_s//$'\r'/\\r}
    _s=${_s//$'\t'/\\t}
    _s=${_s//$'\b'/\\b}
    _s=${_s//$'\f'/\\f}
    if [[ $_s == *[[:cntrl:]]* ]]; then
        for ((_i = 1; _i < 32; _i++)); do
            printf -v _c "\\$(printf '%03o' "$_i")"
            printf -v _u '\\u%04x' "$_i"
            _s=${_s//"$_c"/"$_u"}
        done
    fi
    printf -v "$1" '%s' "$_s"
}

# Produces a complete JSON string literal (with quotes) for a text value.
# Arguments:
#   $1 - Name of the variable that receives the literal.
#   $2 - The raw text.
# Returns: 0. Side effects: sets the named variable.
json_quote() {
    local _e
    json_escape _e "$2"
    printf -v "$1" '"%s"' "$_e"
}

# Produces a JSON string literal, or the literal null for an empty value.
# Arguments:
#   $1 - Name of the variable that receives the literal.
#   $2 - The raw text (may be empty).
# Returns: 0. Side effects: sets the named variable.
json_quote_or_null() {
    if [ -z "$2" ]; then
        printf -v "$1" 'null'
    else
        json_quote "$1" "$2"
    fi
}

# Produces a JSON array of strings from the remaining arguments.
# Arguments:
#   $1 - Name of the variable that receives the array text.
#   $2... - Raw text items (may be none, giving []).
# Returns: 0. Side effects: sets the named variable.
json_string_array() {
    local _name=$1 _item _q _out=""
    shift
    for _item in "$@"; do
        json_quote _q "$_item"
        _out+="${_out:+,}$_q"
    done
    printf -v "$_name" '[%s]' "$_out"
}

# Produces a JSON array from items that are already serialised JSON values.
# Arguments:
#   $1 - Name of the variable that receives the array text.
#   $2... - Serialised JSON values (may be none, giving []).
# Returns: 0. Side effects: sets the named variable.
json_array() {
    local _name=$1 _item _out=""
    shift
    for _item in "$@"; do
        _out+="${_out:+,}$_item"
    done
    printf -v "$_name" '[%s]' "$_out"
}

# Writes one line of JSON to stdout. This is the only way ac prints to stdout
# in JSON mode (the human-oriented out_* helpers are silenced there).
# Arguments:
#   $@ - The serialised JSON document.
# Returns: 0.
json_emit() {
    printf '%s\n' "$*"
}

# Serialises ac's standard error object:
#   {"error":{"type":...,"message":...,"reason":...|null,"exit_code":N}}
# Arguments:
#   $1 - Name of the variable that receives the document.
#   $2 - Error type (e.g. "package-not-found").
#   $3 - Human message.
#   $4 - Technical reason (may be empty).
#   $5 - Exit status.
# Returns: 0. Side effects: sets the named variable.
json_error_object() {
    local _t _m _r
    json_quote _t "$2"
    json_quote _m "$3"
    json_quote_or_null _r "$4"
    printf -v "$1" '{"error":{"type":%s,"message":%s,"reason":%s,"exit_code":%d}}' "$_t" "$_m" "$_r" "$5"
}
