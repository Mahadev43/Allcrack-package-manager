#!/usr/bin/env bash
# `ac update` command. Sourced by src/ac.

# Synchronizes the package databases and upgrades the system in one step.
# v0.1 ran `pacman -Sy`, which leaves Arch in an unsupported partial-upgrade
# state; since v0.2 this performs a full `pacman -Syu` instead. Honors --yes /
# confirm=false through AC_AUTO_YES.
# Arguments: none (validated by the CLI layer).
# Returns: the status of pm_full_upgrade.
# Side effects: refreshes databases and upgrades packages; requires root.
cmd_update() {
    local rc
    pm_require_root update
    out_banner
    out_progress "Synchronizing package databases and upgrading the system..."
    out_info ""
    pm_full_upgrade "system update"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        out_success "System synchronized and upgraded."
    else
        out_failure "Failed: system update"
    fi
    return "$rc"
}
