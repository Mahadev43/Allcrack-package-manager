#!/usr/bin/env bash
# `ac doctor` command. Sourced by src/ac.

# Runs read-only diagnostics of the package-management setup and reports each
# check as pass, fail, warning or skipped. It never changes the system and
# never reports "healthy" while a check failed (warnings do not count as
# failures). Checks needing pacman are skipped if pacman is missing. Besides
# the usual checks it reports pacman's and libalpm's versions and the
# architecture, and verifies backend compatibility by running the read-only
# pacman operations ac needs (not by trusting a version number).
# Arguments: none (validated by the CLI layer).
# Returns: 0 if no check failed; EX_FAILURE otherwise.
# Side effects: none (one HTTP request to the first mirror for the network check).
cmd_doctor() {
    local entry label fn rc status detail w i
    local failures=0 warnings=0
    local -a names=() statuses=() details=() objs=()
    local qn qs qd arr healthy compatible=false
    local -a checks=(
        "libalpm:pm_check_libalpm"
        "architecture:pm_check_arch"
        "package database:pm_check_local_db"
        "sync databases:pm_check_sync_db"
        "database lock:pm_check_lock"
        "pacman configuration:pm_check_pacman_conf"
        "permissions:pm_check_permissions"
        "network:pm_check_network"
        "backend compatibility:pm_check_compat"
    )

    names+=("pacman")
    if pm_locate; then
        pm_check_pacman
        case $? in 0) statuses+=("pass") ;; *) statuses+=("warn") ;; esac
        details+=("$PM_CHECK_DETAIL")
        for entry in "${checks[@]}"; do
            label=${entry%%:*}
            fn=${entry##*:}
            "$fn"
            rc=$?
            case "$rc" in
                0) status=pass ;;
                1) status=fail ;;
                *) status=warn ;;
            esac
            names+=("$label")
            statuses+=("$status")
            details+=("$PM_CHECK_DETAIL")
        done
    else
        statuses+=("fail")
        details+=("pacman was not found in PATH (or AC_PACMAN). ac requires an Arch Linux based system.")
        for entry in "${checks[@]}"; do
            names+=("${entry%%:*}")
            statuses+=("skip")
            details+=("pacman is not available")
        done
    fi

    names+=("ac configuration")
    if [ "${#CFG_WARNINGS[@]}" -eq 0 ]; then
        statuses+=("pass")
        details+=("")
    else
        statuses+=("warn")
        details+=("$(out_join "${CFG_WARNINGS[@]}")")
    fi

    for i in "${!names[@]}"; do
        case "${statuses[$i]}" in
            fail) failures=$((failures + 1)) ;;
            warn) warnings=$((warnings + 1)) ;;
        esac
    done
    healthy=true
    [ "$failures" -eq 0 ] || healthy=false
    for i in "${!names[@]}"; do
        if [ "${names[$i]}" = "backend compatibility" ] && [ "${statuses[$i]}" = pass ]; then
            compatible=true
        fi
    done

    if [ "$AC_OPT_JSON" -eq 1 ]; then
        for i in "${!names[@]}"; do
            json_quote qn "${names[$i]}"
            json_quote qs "${statuses[$i]}"
            json_quote_or_null qd "${details[$i]}"
            objs+=("{\"name\":$qn,\"status\":$qs,\"detail\":$qd}")
        done
        json_array arr "${objs[@]}"
        json_emit "{\"healthy\":$healthy,\"compatible\":$compatible,\"failures\":$failures,\"warnings\":$warnings,\"checks\":$arr}"
    else
        out_info "$AC_NAME Doctor"
        out_info ""
        for i in "${!names[@]}"; do
            status=${statuses[$i]}
            detail=${details[$i]}
            if [ "$status" = pass ] && [ -n "$detail" ]; then
                out_check "$status" "${names[$i]}: $(out_clean "$detail")"
            else
                out_check "$status" "${names[$i]}"
            fi
            if [ -n "$detail" ] && [ "$status" != pass ]; then
                if [ "$status" = fail ]; then
                    out_info "  Reason: $(out_clean "${detail//$'\n'/ }")"
                else
                    out_info "  $(out_clean "${detail//$'\n'/ }")"
                fi
            fi
        done
        out_info ""
        if [ "$failures" -eq 0 ]; then
            if [ "$warnings" -eq 0 ]; then
                out_success "System package management looks healthy."
            else
                out_success "System package management looks healthy ($warnings warning(s) above)."
            fi
            if [ "$compatible" = true ]; then
                out_info "Backend appears compatible."
            fi
        else
            out_check fail "Problems found: $failures check(s) failed. Package management may not work correctly."
        fi
    fi
    [ "$failures" -eq 0 ] || return "$EX_FAILURE"
    return "$EX_OK"
}
