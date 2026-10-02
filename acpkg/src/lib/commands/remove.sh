#!/usr/bin/env bash
# `ac remove` command. Sourced by src/ac.

# Removes one or more installed packages. Every name is checked first so a
# typo produces a clean "not installed" error before pacman starts; pacman
# still decides which dependencies may be removed (ac adds no removal logic).
# Arguments:
#   $@ - Names of the packages to remove (validated by the CLI layer).
# Returns: EX_NOT_FOUND if any name is not installed (nothing is removed);
#   otherwise the code from pm_transaction.
# Side effects: removes packages; requires root.
cmd_remove() {
    local pkg
    local -a missing=()

    pm_require_root remove "$@"

    for pkg in "$@"; do
        if ! pm_is_installed "$pkg" && ! pm_is_group_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        err_plain "Package not installed: $(out_join "${missing[@]}")"
        return "$EX_NOT_FOUND"
    fi

    out_banner
    out_list_block "Removing:" "$@"
    pm_transaction remove "package removal" -R -- "$@"
}
