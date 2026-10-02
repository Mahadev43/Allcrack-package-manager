#!/usr/bin/env bash
# `ac search` command. Sourced by src/ac.

# Searches the synchronized repositories and prints results in ac's own
# layout. Terms are passed to pacman, so partial words work, several terms must
# all match, and pacman's regular-expression syntax is accepted.
# Arguments:
#   $@ - One or more search terms (validated by the CLI layer).
# Returns: 0 (including "no results", which is not an error); EX_FAILURE (or
#   EX_PERMISSION) when pacman fails, e.g. an invalid expression or an
#   unreadable database. A failed query is never reported as "no results".
# Side effects: none (read-only; works without root).
cmd_search() {
    local row repo name ver inst desc key arch
    local -a rows=() targets=()
    local -A archmap=()

    out_banner
    out_info "Search results for: $*"
    out_info ""

    pm_capture -Ss -- "$@"
    if pm_query_failed; then
        if [[ $PM_ERR == *"invalid regular expression"* ]]; then
            pm_report_query_failure "invalid search expression."
        else
            pm_report_query_failure
        fi
        return $?
    fi
    pm_forward_warnings
    if [ -z "$PM_OUT" ]; then
        out_info "No packages found matching: $*"
        out_info "(If the package databases were never synchronized, run: sudo ac update)"
        return "$EX_OK"
    fi

    mapfile -t rows < <(printf '%s\n' "$PM_OUT" | pm_parse_listing)
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r repo name _ <<<"$row"
        targets+=("$repo/$name")
    done
    while IFS=$'\t' read -r key arch; do
        archmap[$key]=$arch
    done < <(pm_arch_lookup "${targets[@]}")

    for row in "${rows[@]}"; do
        IFS=$'\t' read -r repo name ver inst desc <<<"$row"
        out_search_result "$repo" "$name" "$ver" "${archmap[$repo/$name]:-unknown}" "$inst" "$desc"
    done
    out_info "${#rows[@]} package(s) found."
}
