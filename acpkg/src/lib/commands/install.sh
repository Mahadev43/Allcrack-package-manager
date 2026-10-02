#!/usr/bin/env bash
# `ac install` command. Sourced by src/ac.

# Installs one or more packages. Packages that are already installed are
# reported and skipped (they are not reinstalled or partially upgraded);
# pacman performs dependency resolution and the transaction for the rest.
# Arguments:
#   $@ - Names of the packages to install (validated by the CLI layer).
# Returns: 0 on success or when everything is already installed; otherwise the
#   code from pm_transaction (e.g. EX_NOT_FOUND, EX_NETWORK).
# Side effects: installs packages; requires root.
cmd_install() {
    local pkg
    local -a to_install=() skipped=()

    pm_require_root install "$@"

    for pkg in "$@"; do
        if pm_is_installed "$pkg"; then
            skipped+=("$pkg")
        else
            to_install+=("$pkg")
        fi
    done

    out_banner
    if [ "${#skipped[@]}" -gt 0 ]; then
        out_list_block "Already installed (skipping):" "${skipped[@]}"
    fi
    if [ "${#to_install[@]}" -eq 0 ]; then
        out_info "Nothing to do."
        return "$EX_OK"
    fi
    out_list_block "Installing:" "${to_install[@]}"
    pm_transaction install "package installation" -S --needed -- "${to_install[@]}"
}
