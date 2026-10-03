#!/usr/bin/env bash
# `ac info` command. Sourced by src/ac.

# Shows metadata for one or more packages, as text or JSON. Repository
# packages are looked up first, then locally installed packages. Only fields
# pacman actually reports are shown (license and upstream URL included). A genuinely missing package is reported
# as "Package not found" (the remaining packages are still shown in text
# mode); a pacman/database failure is reported as such, with pacman's reason,
# and stops the command. In --json mode the output is all-or-nothing: either
# the package object (an array of objects for several packages) or a single
# JSON error object.
# Arguments:
#   $@ - Package names (validated by the CLI layer).
# Returns: 0 if every package was found; EX_NOT_FOUND if some were missing;
#   EX_FAILURE or EX_PERMISSION if a query failed (takes precedence).
# Side effects: none (read-only; works without root).
cmd_info() {
    local pkg name status deps rc optional entry doc
    local qn qv qd qa qr qi qiv qis qds qdeps qopt qlic qurl
    local missing=0 first=1
    local -a objs=() missing_names=() dep_list=() opt_list=() lic_list=()

    for pkg in "$@"; do
        pm_package_status "$pkg"
        rc=$?
        if [ "$rc" -eq 1 ]; then
            missing=1
            missing_names+=("$pkg")
            if [ "$AC_OPT_JSON" -eq 0 ]; then
                err_raise not-found "$EX_NOT_FOUND" "Package not found: $pkg"
            fi
            continue
        elif [ "$rc" -eq 2 ]; then
            pm_report_query_failure
            return $?
        fi

        name=${PM_INFO[Name]:-$pkg}
        deps=${PM_INFO["Depends On"]:-None}
        optional=${PM_INFO["Optional Deps"]:-None}
        dep_list=()
        opt_list=()
        lic_list=()
        if [ -n "${PM_INFO[Licenses]:-}" ] && [ "${PM_INFO[Licenses]}" != None ]; then
            read -ra lic_list <<<"${PM_INFO[Licenses]}"
        fi
        if [ "$deps" != None ]; then
            read -ra dep_list <<<"$deps"
        fi
        if [ "$optional" != None ]; then
            mapfile -t opt_list <<<"$optional"
        fi
        case "$PM_ST_STATE" in
            installed) status="installed ($PM_ST_INSTALLED_VERSION)" ;;
            available) status="not installed" ;;
            *) status="unknown (could not read the local package database)" ;;
        esac

        if [ "$AC_OPT_JSON" -eq 1 ]; then
            if [ "$rc" -eq 3 ]; then
                pm_report_query_failure
                return $?
            fi
            json_quote qn "$name"
            json_quote qv "${PM_INFO[Version]:-}"
            json_quote_or_null qd "${PM_INFO[Description]:-}"
            json_quote_or_null qa "${PM_INFO[Architecture]:-}"
            json_quote qr "$PM_ST_REPO"
            json_quote_or_null qiv "$PM_ST_INSTALLED_VERSION"
            json_quote_or_null qis "${PM_INFO["Installed Size"]:-}"
            json_quote_or_null qds "${PM_INFO["Download Size"]:-}"
            json_string_array qdeps "${dep_list[@]}"
            json_string_array qopt "${opt_list[@]}"
            json_string_array qlic "${lic_list[@]}"
            json_quote_or_null qurl "${PM_INFO[URL]:-}"
            objs+=("{\"name\":$qn,\"version\":$qv,\"description\":$qd,\"architecture\":$qa,\"repository\":$qr,\"installed\":$([ "$PM_ST_INSTALLED" -eq 1 ] && echo true || echo false),\"installed_version\":$qiv,\"installed_size\":$qis,\"download_size\":$qds,\"dependencies\":$qdeps,\"optional_dependencies\":$qopt,\"licenses\":$qlic,\"url\":$qurl}")
            continue
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
        if [ -n "${PM_INFO["Download Size"]:-}" ]; then
            out_kv "Download Size" "${PM_INFO["Download Size"]}"
        fi
        out_kv "Status" "$status"
        if [ "${#lic_list[@]}" -gt 0 ]; then
            out_kv "License" "$(out_join "${lic_list[@]}")"
        fi
        if [ -n "${PM_INFO[URL]:-}" ]; then
            out_kv "URL" "${PM_INFO[URL]}"
        fi
        if [ "$deps" = None ]; then
            out_kv "Dependencies" "None"
        else
            out_kv "Dependencies" "$(out_join "${dep_list[@]}")"
        fi
        if [ "$optional" != None ]; then
            out_info "Optional Deps:"
            for entry in "${opt_list[@]}"; do
                out_info "  $(out_clean "$entry")"
            done
        fi
        out_info "Description:"
        out_info "  $(out_clean "${PM_INFO[Description]:-No description available.}")"

        if [ "$rc" -eq 3 ]; then
            pm_report_query_failure
            return $?
        fi
    done

    if [ "$missing" -ne 0 ]; then
        if [ "$AC_OPT_JSON" -eq 1 ]; then
            err_raise not-found "$EX_NOT_FOUND" "Package not found: $(out_join "${missing_names[@]}")"
        fi
        return "$EX_NOT_FOUND"
    fi
    if [ "$AC_OPT_JSON" -eq 1 ]; then
        if [ "${#objs[@]}" -eq 1 ]; then
            json_emit "${objs[0]}"
        else
            json_array doc "${objs[@]}"
            json_emit "$doc"
        fi
    fi
    return "$EX_OK"
}
