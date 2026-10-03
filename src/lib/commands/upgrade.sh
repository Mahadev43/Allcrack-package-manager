#!/usr/bin/env bash
# `ac upgrade` command. Sourced by src/ac.

# Performs the normal full system upgrade (pacman -Syu). Behaves like
# `ac update`; both exist so apt/dnf muscle memory works while the databases
# are never refreshed without an upgrade. Without --yes pacman keeps its
# normal confirmation prompt; with --yes (or confirm=false) it is auto-answered.
# Arguments: none (validated by the CLI layer).
# Returns: the status of pm_full_upgrade.
# Side effects: refreshes databases and upgrades packages; requires root.
cmd_upgrade() {
    local rc
    pm_require_root upgrade
    out_banner
    out_progress "Checking for updates..."
    out_progress "Preparing system upgrade..."
    out_info ""
    pm_full_upgrade "system upgrade"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        out_success "System upgrade complete."
    else
        out_failure "Failed: system upgrade"
    fi
    return "$rc"
}
