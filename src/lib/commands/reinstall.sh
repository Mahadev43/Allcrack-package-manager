#!/usr/bin/env bash
# `ac reinstall` command. Sourced by src/ac.

# Reinstalls one or more installed packages from the repositories. Every name
# must already be installed (use `ac install` otherwise); pacman performs the
# transaction. Honors --yes / confirm=false through AC_AUTO_YES.
# Arguments:
#   $@ - Names of installed packages (validated by the CLI layer).
# Returns: EX_NOT_FOUND if any name is not installed (nothing is reinstalled);
#   otherwise the code from pm_reinstall.
# Side effects: reinstalls packages; requires root.
cmd_reinstall() {
    local pkg rc
    local -a missing=()

    pm_require_root reinstall "$@"

    for pkg in "$@"; do
        if ! pm_is_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        err_raise not-installed "$EX_NOT_FOUND" "Package not installed: $(out_join "${missing[@]}")" "" \
            "Use 'sudo ac install' to install a package that is not installed yet."
        return "$EX_NOT_FOUND"
    fi

    out_banner
    out_list_block "Reinstalling:" "$@"
    pm_reinstall "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        out_success "Reinstalled: $(out_join "$@")"
    else
        out_failure "Failed: $(out_join "$@")"
    fi
    return "$rc"
}
