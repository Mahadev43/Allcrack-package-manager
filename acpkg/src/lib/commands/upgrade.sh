#!/usr/bin/env bash
# `ac upgrade` command. Sourced by src/ac.

# Performs the normal full system upgrade (pacman -Syu). Behaves like
# `ac update`; both exist so apt/dnf muscle memory works while the databases
# are never refreshed without an upgrade.
# Arguments: none (validated by the CLI layer).
# Returns: the status of pm_full_upgrade.
# Side effects: refreshes databases and upgrades packages; requires root.
cmd_upgrade() {
    pm_require_root upgrade
    out_banner
    out_info "Checking for updates..."
    out_info "Preparing system upgrade..."
    out_info ""
    pm_full_upgrade "system upgrade"
}
