#!/usr/bin/env bash
# `ac status` command. Sourced by src/ac.

# Reports, for each package, whether it is installed, merely available from a
# repository, or not available at all. States: "installed", "available" (not
# installed but present in a repository) and "not-available". Installed
# packages also get an update state: "current", "available" (a newer version is
# in the synchronized databases; ac never refreshes them here) or "unknown".
# Built on pm_package_status, the same query path as `ac info`.
# Arguments:
#   $@ - Package names (validated by the CLI layer).
# Returns: 0 if every package was found; EX_NOT_FOUND if some were not (all
#   results are still printed); EX_FAILURE/EX_PERMISSION if a query failed
#   (takes precedence; in --json mode only the error object is printed).
# Side effects: none (read-only).
cmd_status() {
    local pkg rc state version repo update latest qn qs qv qr qu ql
    local missing=0 first=1
    local -a objs=() missing_names=()

    for pkg in "$@"; do
        pm_package_status "$pkg"
        rc=$?
        case "$rc" in
            0)
                state=$PM_ST_STATE version=$PM_ST_VERSION repo=$PM_ST_REPO
                update=$PM_ST_UPDATE latest=$PM_ST_LATEST
                ;;
            1)
                state=not-available version="" repo="" update="" latest=""
                missing=1
                missing_names+=("$pkg")
                ;;
            *)
                pm_report_query_failure
                return $?
                ;;
        esac
        if [ "$AC_OPT_JSON" -eq 1 ]; then
            json_quote qn "$pkg"
            json_quote qs "$state"
            json_quote_or_null qv "$version"
            json_quote_or_null qr "$repo"
            json_quote_or_null qu "$update"
            json_quote_or_null ql "$latest"
            objs+=("{\"name\":$qn,\"status\":$qs,\"version\":$qv,\"repository\":$qr,\"update\":$qu,\"latest_version\":$ql}")
            continue
        fi
        if [ "$first" -eq 0 ]; then
            out_info ""
        fi
        first=0
        out_kv "Package" "$pkg"
        out_kv "Status" "$state"
        if [ "$state" != not-available ]; then
            out_kv "Version" "$version"
            out_kv "Repository" "$repo"
        fi
        case "$update" in
            available) out_kv "Update" "available ($version -> $latest)" ;;
            current) out_kv "Update" "current" ;;
            unknown) out_kv "Update" "unknown (could not read the upgrade list)" ;;
        esac
    done

    if [ "$AC_OPT_JSON" -eq 1 ]; then
        if [ "${#objs[@]}" -eq 1 ]; then
            json_emit "${objs[0]}"
        else
            json_array qn "${objs[@]}"
            json_emit "$qn"
        fi
    fi
    if [ "$missing" -ne 0 ]; then
        return "$EX_NOT_FOUND"
    fi
    return "$EX_OK"
}
