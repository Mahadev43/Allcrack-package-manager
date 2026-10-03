#!/usr/bin/env bash
# `ac update` command. Sourced by src/ac.

# Synchronizes the package databases and upgrades the system in one step.
# v0.1 ran `pacman -Sy`, which leaves Arch in an unsupported partial-upgrade
# state; from v0.2 this performs a full `pacman -Syu` instead.
# Arguments: none (validated by the CLI layer).
# Returns: the status of pm_full_upgrade.
# Side effects: refreshes databases and upgrades packages; requires root.
cmd_update() {
    pm_require_root update
    out_banner
    out_info "Synchronizing package databases and upgrading the system..."
    out_info ""
    pm_full_upgrade "system update"
}
