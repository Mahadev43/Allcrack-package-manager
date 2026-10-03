#!/usr/bin/env bash
# `ac search` command. Sourced by src/ac.

# Searches the synchronized repositories and prints results in ac's own
# layout (or as JSON). Terms are passed to pacman, so partial words work,
# several terms must all match, and pacman's regular-expression syntax is
# accepted. The query is made through pm_search (one pacman call plus one per
# 500 results for architectures).
# Arguments:
#   $@ - One or more search terms (validated by the CLI layer).
# Returns: 0 (including "no results", which is not an error); EX_FAILURE (or
#   EX_PERMISSION) when pacman fails, e.g. an invalid expression or an
#   unreadable database. A failed query is never reported as "no results".
# Side effects: none (read-only; works without root).
cmd_search() {
    local row repo name ver inst arch desc qt qr qn qv qa qd arr
    local -a objs=() terms=()

    out_banner
    out_info "Search results for: $*"
    out_info ""

    pm_search "$@"
    if [ $? -ne 0 ]; then
        if [[ $PM_ERR == *"invalid regular expression"* ]]; then
            pm_report_query_failure "invalid search expression." invalid-search
        else
            pm_report_query_failure
        fi
        return $?
    fi

    if [ "$AC_OPT_JSON" -eq 1 ]; then
        for row in "${PM_ROWS[@]}"; do
            IFS=$'\t' read -r repo name ver inst arch desc <<<"$row"
            json_quote qr "$repo"
            json_quote qn "$name"
            json_quote qv "$ver"
            json_quote qa "$arch"
            json_quote qd "$desc"
            objs+=("{\"repository\":$qr,\"name\":$qn,\"version\":$qv,\"architecture\":$qa,\"description\":$qd,\"installed\":$([ "$inst" = 1 ] && echo true || echo false)}")
        done
        json_array arr "${objs[@]}"
        json_string_array qt "$@"
        json_emit "{\"query\":$qt,\"count\":${#PM_ROWS[@]},\"results\":$arr}"
        return "$EX_OK"
    fi

    if [ "${#PM_ROWS[@]}" -eq 0 ]; then
        out_info "No packages found matching: $*"
        out_info "(If the package databases were never synchronized, run: sudo ac update)"
        return "$EX_OK"
    fi
    for row in "${PM_ROWS[@]}"; do
        IFS=$'\t' read -r repo name ver inst arch desc <<<"$row"
        out_search_result "$repo" "$name" "$ver" "$arch" "$inst" "$desc"
    done
    out_info "${#PM_ROWS[@]} package(s) found."
}
