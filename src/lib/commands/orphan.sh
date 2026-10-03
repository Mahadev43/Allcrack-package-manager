#!/usr/bin/env bash
# `ac orphan` command. Sourced by src/ac.

# Lists orphan packages (installed as dependencies, no longer required), as
# determined by pacman. With --remove it removes them through pacman, which
# shows the full list and asks for confirmation (never auto-confirmed). Plain
# `ac orphan` NEVER removes anything and needs no root.
# Arguments: none (validated by the CLI layer).
# Returns: 0 on success (including "no orphans"); EX_FAILURE/EX_PERMISSION when
#   the query fails; with --remove, the status of pm_remove_orphans.
# Side effects: with --remove only, removes packages (requires root).
cmd_orphan() {
    local rc doc arr
    local -a orphans=()

    if [ "$AC_OPT_REMOVE" -eq 1 ]; then
        pm_require_root orphan --remove
    fi
    pm_orphans
    if [ $? -ne 0 ]; then
        pm_report_query_failure
        return $?
    fi
    orphans=("${PM_NAMES[@]}")

    if [ "$AC_OPT_REMOVE" -eq 1 ]; then
        out_banner
        if [ "${#orphans[@]}" -eq 0 ]; then
            out_info "No orphan packages found. Nothing to remove."
            return "$EX_OK"
        fi
        out_list_block "Orphan packages to remove:" "${orphans[@]}"
        pm_remove_orphans "${orphans[@]}"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            out_success "Removed ${#orphans[@]} orphan package(s)."
        else
            out_failure "Failed: orphan removal"
        fi
        return "$rc"
    fi

    if [ "$AC_OPT_JSON" -eq 1 ]; then
        json_string_array arr "${orphans[@]}"
        json_emit "{\"count\":${#orphans[@]},\"orphans\":$arr}"
        return "$EX_OK"
    fi
    if [ "${#orphans[@]}" -eq 0 ]; then
        out_info "No orphan packages found."
        return "$EX_OK"
    fi
    out_list_block "Orphan packages:" "${orphans[@]}"
    out_info "Remove them with: sudo ac orphan --remove"
}
