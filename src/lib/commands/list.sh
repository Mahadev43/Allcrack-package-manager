#!/usr/bin/env bash
# `ac list` command. Sourced by src/ac.

# Lists installed packages, optionally filtered by a query, using pacman's
# existing local database (ac keeps no database of its own), as text or JSON.
# Arguments:
#   $@ - Optional search terms; all must match (pacman -Qs semantics).
# Returns: 0 (including "no matches"); EX_FAILURE (or EX_PERMISSION) when the
#   query fails, which is never reported as an empty list.
# Side effects: none (read-only; works without root).
cmd_list() {
    local row name ver title qn qv arr
    local -a objs=()

    if [ "$AC_OPT_UPGRADABLE" -eq 1 ]; then
        cmd_list_upgradable
        return $?
    fi

    pm_list_installed "$@"
    if [ $? -ne 0 ]; then
        pm_report_query_failure
        return $?
    fi

    if [ "$AC_OPT_JSON" -eq 1 ]; then
        for row in "${PM_ROWS[@]}"; do
            IFS=$'\t' read -r name ver <<<"$row"
            json_quote qn "$name"
            json_quote qv "$ver"
            objs+=("{\"name\":$qn,\"version\":$qv}")
        done
        json_array arr "${objs[@]}"
        json_emit "{\"count\":${#PM_ROWS[@]},\"packages\":$arr}"
        return "$EX_OK"
    fi

    if [ "${#PM_ROWS[@]}" -eq 0 ]; then
        if [ "$#" -eq 0 ]; then
            out_info "No installed packages found."
        else
            out_info "No installed packages found matching: $*"
        fi
        return "$EX_OK"
    fi

    if [ "$#" -eq 0 ]; then
        title="Installed packages"
    else
        title="Installed packages matching: $*"
    fi
    out_info "$title (${#PM_ROWS[@]}):"
    for row in "${PM_ROWS[@]}"; do
        IFS=$'\t' read -r name ver <<<"$row"
        printf '  %-32s %s\n' "$name" "$ver"
    done
}

# `ac list --upgradable`: lists installed packages that have a newer version in
# the already synchronized databases (pacman -Qu). Never refreshes databases.
# Arguments: none.
# Returns: 0 (including "no updates"); EX_FAILURE (or EX_PERMISSION) when the
#   query fails.
# Side effects: none (read-only; works without root).
cmd_list_upgradable() {
    local row name ver latest qn qv ql arr
    local -a objs=()

    pm_list_upgradable
    if [ $? -ne 0 ]; then
        pm_report_query_failure
        return $?
    fi

    if [ "$AC_OPT_JSON" -eq 1 ]; then
        for row in "${PM_ROWS[@]}"; do
            IFS=$'\t' read -r name ver latest <<<"$row"
            json_quote qn "$name"
            json_quote qv "$ver"
            json_quote ql "$latest"
            objs+=("{\"name\":$qn,\"version\":$qv,\"latest_version\":$ql}")
        done
        json_array arr "${objs[@]}"
        json_emit "{\"count\":${#PM_ROWS[@]},\"packages\":$arr}"
        return "$EX_OK"
    fi

    if [ "${#PM_ROWS[@]}" -eq 0 ]; then
        out_info "All packages are up to date (as far as the synchronized databases know)."
        return "$EX_OK"
    fi
    out_info "Upgradable packages (${#PM_ROWS[@]}):"
    for row in "${PM_ROWS[@]}"; do
        IFS=$'\t' read -r name ver latest <<<"$row"
        printf '  %-32s %s -> %s\n' "$name" "$ver" "$latest"
    done
}
