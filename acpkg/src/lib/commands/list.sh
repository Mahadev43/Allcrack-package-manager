#!/usr/bin/env bash
# `ac list` command. Sourced by src/ac.

# Lists installed packages, optionally filtered by a query, using pacman's
# existing local database (ac keeps no database of its own).
# Arguments:
#   $@ - Optional search terms; all must match (pacman -Qs semantics).
# Returns: 0 (including "no matches"); EX_FAILURE (or EX_PERMISSION) when the
#   query fails, which is never reported as an empty list.
# Side effects: none (read-only; works without root).
cmd_list() {
    local row name ver title
    local -a rows=()

    if [ "$#" -eq 0 ]; then
        pm_capture -Q
        title="Installed packages"
    else
        pm_capture -Qs -- "$@"
        title="Installed packages matching: $*"
    fi
    if pm_query_failed; then
        pm_report_query_failure
        return $?
    fi
    pm_forward_warnings

    if [ "$#" -eq 0 ]; then
        mapfile -t rows < <(printf '%s\n' "$PM_OUT" | awk 'NF {print $1 "\t" $2}')
    else
        mapfile -t rows < <(printf '%s\n' "$PM_OUT" | pm_parse_listing | cut -f2,3)
    fi
    if [ "${#rows[@]}" -eq 0 ]; then
        if [ "$#" -eq 0 ]; then
            out_info "No installed packages found."
        else
            out_info "No installed packages found matching: $*"
        fi
        return "$EX_OK"
    fi

    out_info "$title (${#rows[@]}):"
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r name ver <<<"$row"
        printf '  %-32s %s\n' "$name" "$ver"
    done
}
