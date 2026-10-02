#!/usr/bin/env bash
# `ac info` command. Sourced by src/ac.

# Shows metadata for one or more packages. Repository packages are looked up
# first, then locally installed packages (for example ones built from the AUR).
# A genuinely missing package is reported as "Package not found" and the
# remaining packages are still shown; a pacman/database failure is reported as
# such, with pacman's reason, and stops the command (the rest would fail too).
# Arguments:
#   $@ - Package names (validated by the CLI layer).
# Returns: 0 if every package was found; EX_NOT_FOUND if some were missing;
#   EX_FAILURE or EX_PERMISSION if a query failed (takes precedence).
# Side effects: none (read-only; works without root).
cmd_info() {
    local pkg name status deps rc vrc
    local missing=0 first=1

    for pkg in "$@"; do
        pm_package_info "$pkg"
        rc=$?
        if [ "$rc" -eq 1 ]; then
            err_plain "Package not found: $pkg"
            missing=1
            continue
        elif [ "$rc" -ne 0 ]; then
            pm_report_query_failure
            return $?
        fi
        pm_forward_warnings
        pm_parse_info "$PM_OUT"

        name=${PM_INFO[Name]:-$pkg}
        pm_installed_version "$name"
        vrc=$?
        case "$vrc" in
            0) status="installed ($PM_VERSION)" ;;
            1) status="not installed" ;;
            *) status="unknown (could not read the local package database)" ;;
        esac
        deps=${PM_INFO["Depends On"]:-None}
        if [ "$deps" != None ]; then
            deps=$(out_comma_list "$deps")
        fi

        if [ "$first" -eq 0 ]; then
            out_info ""
        fi
        first=0
        out_kv "Package" "$name"
        out_kv "Version" "${PM_INFO[Version]:-unknown}"
        out_kv "Repository" "${PM_INFO[Repository]:-local (not in a sync repository)}"
        out_kv "Architecture" "${PM_INFO[Architecture]:-unknown}"
        out_kv "Installed Size" "${PM_INFO["Installed Size"]:-unknown}"
        out_kv "Status" "$status"
        out_kv "Dependencies" "$deps"
        out_info "Description:"
        out_info "  ${PM_INFO[Description]:-No description available.}"

        if [ "$vrc" -eq 2 ]; then
            pm_report_query_failure
            return $?
        fi
    done

    if [ "$missing" -ne 0 ]; then
        return "$EX_NOT_FOUND"
    fi
    return "$EX_OK"
}
