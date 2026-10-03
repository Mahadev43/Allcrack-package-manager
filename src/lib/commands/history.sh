#!/usr/bin/env bash
# `ac history` command. Sourced by src/ac.

# Shows recent package transactions taken from pacman's own log (no database
# of ac's own). Only completed package changes that libalpm logged are shown;
# nothing is inferred or invented. The log records packages, not the ac/pacman
# command that caused them, so the output is a per-package list.
# Honors --limit and the --install/--remove/--upgrade filters; the filter is
# applied before the limit, so "-n 5 --upgrade" means the last five upgrades.
# Arguments: none (validated by the CLI layer).
# Returns: 0 on success (including an empty history); EX_FAILURE if the log
#   cannot be read.
# Side effects: none (read-only).
cmd_history() {
    local row date time action pkg detail label q_d q_t q_a q_p q_v items="" doc
    local -a objs=()

    pm_history "$AC_OPT_LIMIT" "$AC_OPT_FILTER"
    if [ $? -ne 0 ]; then
        pm_report_query_failure "unable to read the package transaction log."
        return $?
    fi

    if [ "$AC_OPT_JSON" -eq 1 ]; then
        for row in "${PM_ROWS[@]}"; do
            IFS=$'\t' read -r date time action pkg detail <<<"$row"
            json_quote q_d "$date"
            json_quote q_t "$time"
            json_quote q_a "$action"
            json_quote q_p "$pkg"
            json_quote q_v "$detail"
            objs+=("{\"date\":$q_d,\"time\":$q_t,\"action\":$q_a,\"package\":$q_p,\"version\":$q_v}")
        done
        json_array items "${objs[@]}"
        json_emit "{\"count\":${#PM_ROWS[@]},\"transactions\":$items}"
        return "$EX_OK"
    fi

    if [ "${#PM_ROWS[@]}" -eq 0 ]; then
        out_info "No matching package transactions found in the pacman log."
        return "$EX_OK"
    fi
    out_info "Recent package transactions:"
    out_info ""
    for row in "${PM_ROWS[@]}"; do
        IFS=$'\t' read -r date time action pkg detail <<<"$row"
        label=${action^}
        printf '%s %s  %s %s (%s)\n' "$date" "$time" "$(out_clean "$label")" "$(out_clean "$pkg")" "$(out_clean "$detail")"
    done
}
