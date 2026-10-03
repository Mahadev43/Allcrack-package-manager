#!/usr/bin/env bash
# `ac clean` command. Sourced by src/ac.

# Cleans pacman's package cache through pacman itself (ac never deletes cache
# files). Without options it runs `pacman -Sc` (cached packages that are no
# longer installed); with --all it runs `pacman -Scc` (everything), which
# always asks for confirmation. --yes is allowed only without --all.
# Arguments: none (validated by the CLI layer).
# Returns: the status of pm_clean.
# Side effects: deletes files from the package cache; requires root.
cmd_clean() {
    local rc
    pm_require_root clean
    out_banner
    if [ "$AC_OPT_ALL" -eq 1 ]; then
        out_progress "Removing ALL cached package files (pacman asks first)..."
    else
        out_progress "Removing cached packages that are no longer installed..."
    fi
    out_info ""
    pm_clean "$AC_OPT_ALL"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        out_success "Package cache cleaned."
    else
        out_failure "Failed: cache cleaning"
    fi
    return "$rc"
}
