#!/usr/bin/env bash
# Package-manager abstraction with a pacman backend. This is the ONLY module
# that executes pacman (or pacman-conf, grep on pacman's log, curl for the
# network check) or parses their output. Commands talk to the package system
# exclusively through the pm_* functions below:
#
#   capabilities  pm_has_cap, pm_require_cap
#   queries       pm_search, pm_list_installed, pm_list_upgradable, pm_package_status, pm_orphans,
#                 pm_history, pm_is_installed, pm_is_group_installed
#   operations    pm_install, pm_reinstall, pm_remove, pm_remove_orphans,
#                 pm_full_upgrade, pm_clean
#   diagnostics   pm_check_* (used by `ac doctor`)
#
# Keeping every pacman call in this one file keeps argument handling and
# output parsing in a single reviewable place. pacman (and libalpm beneath
# it) remains the only backend. Sourced by src/ac.
#
# Result globals (set by the functions that document them):
#   PM_ROWS   - tab-separated result rows (search, list, history).
#   PM_NAMES  - plain name lists (orphans).
#   PM_INFO   - associative array of one package's info fields.
#   PM_ST_*   - package status (see pm_package_status).
#   PM_OUT, PM_ERR, PM_RC - stdout/stderr/status of the last captured call.
#   PM_ERRFILE - temp file of the call in progress (removed by pm_tmp_release
#                or, on any exit, ac_cleanup).

PM_BIN=""
PM_CONF_BIN=""
PM_OUT=""
PM_ERR=""
PM_RC=0
PM_ERRFILE=""
PM_SOURCE=""
PM_VERSION=""
PM_REASON=""
PM_CHECK_DETAIL=""
PM_LAST_OP=""
PM_PACMAN_VERSION=""
PM_LIBALPM_VERSION=""
PM_ST_STATE=""
PM_ST_VERSION=""
PM_ST_REPO=""
PM_ST_INSTALLED=0
PM_ST_INSTALLED_VERSION=""
declare -gA PM_INFO=()
declare -gA PM_CAP=()
declare -gA PM_CAP_REASON=()
declare -ga PM_ROWS=()
declare -ga PM_NAMES=()
declare -ga PM_CONFIRM_ARGS=()
declare -gA PM_UPGRADES=()
PM_UPGRADES_STATE=""
PM_ST_UPDATE=""
PM_ST_LATEST=""

# ---------------------------------------------------------------- setup ----

# Locates the pacman binary (AC_PACMAN overrides the PATH lookup) and the
# optional pacman-conf helper that ships with pacman.
# Arguments: none.
# Returns: 0 if pacman was found, 1 otherwise (never exits).
# Side effects: sets PM_BIN and PM_CONF_BIN (empty when not found).
pm_locate() {
    local dir
    PM_BIN=${AC_PACMAN:-}
    if [ -z "$PM_BIN" ]; then
        PM_BIN=$(command -v pacman) || PM_BIN=""
    fi
    if [ -z "$PM_BIN" ] || [ ! -x "$PM_BIN" ]; then
        PM_BIN=""
        PM_CONF_BIN=""
        return 1
    fi
    dir=${PM_BIN%/*}
    if [ "$dir" != "$PM_BIN" ] && [ -x "$dir/pacman-conf" ]; then
        PM_CONF_BIN=$dir/pacman-conf
    else
        PM_CONF_BIN=$(command -v pacman-conf) || PM_CONF_BIN=""
    fi
    return 0
}

# Locates pacman and detects the backend's capabilities; exits with
# EX_NO_BACKEND if pacman is unavailable. Called by the CLI before any command
# that needs the backend.
# Arguments: none.
# Returns: 0 on success; exits otherwise.
# Side effects: sets PM_BIN, PM_CONF_BIN, PM_CAP, PM_CAP_REASON.
pm_init() {
    if ! pm_locate; then
        err_die backend-unavailable "$EX_NO_BACKEND" "pacman not found. ac requires an Arch Linux based system."
    fi
    pm_detect_capabilities
}

# Runs pacman-conf (pacman's configuration reader) with the given arguments.
# Arguments:
#   $@ - Arguments for pacman-conf.
# Returns: pacman-conf's status, or 127 if it is not installed. Prints its
#   stdout; stderr is discarded.
pm_conf_run() {
    [ -n "$PM_CONF_BIN" ] || return 127
    LC_ALL=C "$PM_CONF_BIN" "$@" 2>/dev/null
}

# Returns the path of the pacman log: AC_PACMAN_LOG if set, otherwise the
# LogFile from pacman's configuration, otherwise /var/log/pacman.log.
# Arguments: none.
# Returns: prints the path on stdout.
pm_log_path() {
    local path=${AC_PACMAN_LOG:-}
    [ -n "$path" ] || path=$(pm_conf_run LogFile) || path=""
    printf '%s' "${path:-/var/log/pacman.log}"
}

# Returns the pacman database directory (with a trailing slash).
# Arguments: none.
# Returns: prints the path on stdout (pacman-conf DBPath or the default).
pm_db_path() {
    local path
    path=$(pm_conf_run DBPath) || path=""
    printf '%s' "${path:-/var/lib/pacman/}"
}

# Decides which operations this backend can perform and why not, if some
# cannot. Commands are gated on this (see pm_require_cap) so they never assume
# functionality the backend lacks. For pacman everything is available except
# history when the pacman log cannot be found.
# Arguments: none.
# Returns: 0.
# Side effects: fills PM_CAP[NAME]=1|0 and PM_CAP_REASON[NAME].
pm_detect_capabilities() {
    local name log
    PM_CAP=()
    PM_CAP_REASON=()
    for name in INSTALL REMOVE REINSTALL SEARCH INFO STATUS LIST ORPHAN CLEAN UPGRADE; do
        PM_CAP[$name]=1
    done
    log=$(pm_log_path)
    if [ -f "$log" ]; then
        PM_CAP[HISTORY]=1
    else
        PM_CAP[HISTORY]=0
        PM_CAP_REASON[HISTORY]="the pacman log was not found at $log"
    fi
}

# Tells whether the backend supports an operation.
# Arguments:
#   $1 - Capability name: INSTALL, REMOVE, REINSTALL, SEARCH, INFO, STATUS,
#        LIST, ORPHAN, CLEAN, UPGRADE or HISTORY.
# Returns: 0 if supported, 1 otherwise.
pm_has_cap() {
    [ "${PM_CAP[$1]:-0}" = 1 ]
}

# Fails with a structured "unsupported" error if a capability is missing.
# Arguments:
#   $1 - Capability name.
#   $2 - Command name used in the message.
# Returns: 0 if supported; otherwise reports the error and returns EX_UNSUPPORTED.
pm_require_cap() {
    if pm_has_cap "$1"; then
        return 0
    fi
    err_raise unsupported "$EX_UNSUPPORTED" \
        "'$2' is not available with this package-manager backend." "${PM_CAP_REASON[$1]:-}"
}

# Exits with EX_PERMISSION unless ac is running as root. Called before any
# command that modifies the system so the user gets a clear message instead of
# a pacman error.
# Arguments:
#   $@ - The ac command line (without "ac"), used in the "try sudo" hint.
# Returns: 0 if root; otherwise exits.
pm_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err_die permission "$EX_PERMISSION" "permission denied. This command must be run as root. Try: sudo ac $*"
    fi
}

# --------------------------------------------------------- running pacman ----

# Runs pacman with the given arguments, connected directly to the terminal.
# LC_ALL=C pins pacman's messages to English so ac can recognise errors and
# parse listings reliably.
# Arguments:
#   $@ - Arguments passed to pacman.
# Returns: pacman's exit status.
pm_run() {
    LC_ALL=C "$PM_BIN" "$@"
}

# Creates the temporary file that receives a copy of pacman's stderr.
# Arguments: none.
# Returns: 0; exits with EX_FAILURE if no temp file can be created.
# Side effects: sets PM_ERRFILE (removed by pm_tmp_release / ac_cleanup).
pm_tmp_acquire() {
    PM_ERRFILE=$(mktemp "${TMPDIR:-/tmp}/ac-pacman.XXXXXX") ||
        err_die internal "$EX_FAILURE" "cannot create a temporary file."
}

# Deletes the temporary file created by pm_tmp_acquire.
# Arguments: none.
# Returns: 0. Side effects: removes the file and clears PM_ERRFILE.
pm_tmp_release() {
    ac_cleanup
}

# Runs a command, capturing its stdout and stderr instead of printing them.
# Used for read-only queries whose output ac reformats; pm_capture is the
# pacman-specific wrapper.
# Arguments:
#   $@ - The command and its arguments (a function name such as pm_run works).
# Returns: the command's exit status.
# Side effects: sets PM_OUT, PM_ERR and PM_RC.
pm_capture_cmd() {
    pm_tmp_acquire
    PM_OUT=$("$@" 2>"$PM_ERRFILE")
    PM_RC=$?
    PM_ERR=$(<"$PM_ERRFILE")
    pm_tmp_release
    return "$PM_RC"
}

# Runs pacman, capturing stdout and stderr (see pm_capture_cmd).
# Arguments:
#   $@ - Arguments passed to pacman.
# Returns: pacman's exit status.
# Side effects: sets PM_OUT, PM_ERR and PM_RC.
pm_capture() {
    PM_LAST_OP=${1:-}
    pm_capture_cmd pm_run "$@"
}

# Runs a state-changing pacman operation (install, remove, upgrade, clean).
# pacman keeps the terminal on stdout and stdin, so prompts, progress bars and
# colors work normally. Its stderr goes through `tee`: the user sees every
# warning and error immediately while a copy is saved for classifying a
# failure. fd 3 carries the original stdout around the pipe; `tee` ignores
# SIGINT so that on Ctrl+C pacman can still write its final messages and
# release its database lock instead of hitting a closed pipe.
# Arguments:
#   $1 - Mode: "install", "remove" or "system".
#   $2 - Operation label used in failure messages, e.g. "package installation".
#   $3... - Arguments passed to pacman.
# Returns: 0 on success, otherwise the code chosen by
#   err_report_pacman_failure.
# Side effects: modifies the system via pacman; briefly uses fd 3 and PM_ERRFILE.
pm_transaction() {
    local mode=$1 label=$2 rc
    shift 2
    pm_tmp_acquire
    exec 3>&1
    pm_run "$@" 2>&1 1>&3 3>&- | (
        trap '' INT
        exec tee -- "$PM_ERRFILE" >&2
    )
    rc=${PIPESTATUS[0]}
    exec 3>&-
    if [ "$rc" -ne 0 ]; then
        err_report_pacman_failure "$rc" "$PM_ERRFILE" "$mode" "$label"
        rc=$?
    fi
    pm_tmp_release
    return "$rc"
}

# Prepares the extra pacman arguments that auto-confirm prompts. pacman's
# --noconfirm is added only when AC_AUTO_YES=1 (the CLI sets that only for
# commands that support it).
# Arguments: none.
# Returns: 0. Side effects: sets the PM_CONFIRM_ARGS array.
pm_confirm_args() {
    PM_CONFIRM_ARGS=()
    if [ "$AC_AUTO_YES" -eq 1 ]; then
        PM_CONFIRM_ARGS=(--noconfirm)
    fi
}

# ------------------------------------------------------------ operations ----

# Installs packages. --needed makes pacman skip anything already up to date.
# Arguments:
#   $@ - Package names.
# Returns: the status of pm_transaction.
# Side effects: modifies the system.
pm_install() {
    pm_confirm_args
    pm_transaction install "package installation" -S --needed "${PM_CONFIRM_ARGS[@]}" -- "$@"
}

# Reinstalls installed packages from the repositories (pacman -S without
# --needed).
# Arguments:
#   $@ - Names of installed packages.
# Returns: the status of pm_transaction.
# Side effects: modifies the system.
pm_reinstall() {
    pm_confirm_args
    pm_transaction install "package reinstallation" -S "${PM_CONFIRM_ARGS[@]}" -- "$@"
}

# Removes packages (pacman -R); pacman decides about dependencies.
# Arguments:
#   $@ - Names of installed packages.
# Returns: the status of pm_transaction.
# Side effects: modifies the system.
pm_remove() {
    pm_confirm_args
    pm_transaction remove "package removal" -R "${PM_CONFIRM_ARGS[@]}" -- "$@"
}

# Removes orphan packages with pacman -Rs (their no-longer-needed dependencies
# go too; configuration backups are kept). Never auto-confirms: pacman always
# shows the list and asks.
# Arguments:
#   $@ - Orphan package names (from pm_orphans).
# Returns: the status of pm_transaction.
# Side effects: modifies the system.
pm_remove_orphans() {
    pm_transaction remove "orphan removal" -Rs -- "$@"
}

# Performs a full system synchronization and upgrade (pacman -Syu). ac never
# refreshes the databases without upgrading: that would create a partial
# upgrade, which Arch Linux does not support.
# Arguments:
#   $1 - Operation label used in failure messages, e.g. "system upgrade".
# Returns: the status of pm_transaction.
# Side effects: refreshes databases and upgrades packages.
pm_full_upgrade() {
    pm_confirm_args
    pm_transaction system "$1" -Syu "${PM_CONFIRM_ARGS[@]}"
}

# Cleans the package cache through pacman: -Sc removes cached packages that
# are no longer installed; -Scc removes every cached file. ac never deletes
# cache files itself. pacman asks for confirmation.
# Arguments:
#   $1 - "1" for the complete cleanup (-Scc), anything else for -Sc.
# Returns: the status of pm_transaction.
# Side effects: deletes files from pacman's cache.
pm_clean() {
    pm_confirm_args
    if [ "$1" = 1 ]; then
        pm_transaction system "cache cleaning" -Scc "${PM_CONFIRM_ARGS[@]}"
    else
        pm_transaction system "cache cleaning" -Sc "${PM_CONFIRM_ARGS[@]}"
    fi
}

# ---------------------------------------------------------------- queries ----

# Tests whether a package is currently installed.
# Arguments:
#   $1 - Package name.
# Returns: 0 if installed, non-zero otherwise.
pm_is_installed() {
    pm_run -Qq -- "$1" >/dev/null 2>&1
}

# Tests whether a name refers to an installed package group (pacman -R accepts
# group names as well as packages).
# Arguments:
#   $1 - Group name.
# Returns: 0 if the group has installed members, non-zero otherwise.
pm_is_group_installed() {
    local members
    members=$(pm_run -Qgq -- "$1" 2>/dev/null) || return 1
    [ -n "$members" ]
}

# Tells whether the last captured pacman call failed only because the
# requested package does not exist (pacman's "package 'x' was not found").
# Any other error line, such as a database or configuration error, makes this
# false so real failures are never reported as "not found".
# Arguments: none (uses PM_RC and PM_ERR).
# Returns: 0 if the only errors are "was not found" errors, 1 otherwise.
pm_is_not_found_error() {
    local line seen=1
    [ "$PM_RC" -ne 0 ] || return 1
    while IFS= read -r line; do
        case "$line" in
            "error: "*"was not found"*) seen=0 ;;
            "error: "*) return 1 ;;
        esac
    done <<<"$PM_ERR"
    return "$seen"
}

# Tells whether the last captured read-only query failed (as opposed to
# merely finding nothing: pacman exits 1 with no error for an empty search).
# Arguments: none (uses PM_RC and PM_ERR).
# Returns: 0 if it failed, 1 if it succeeded or only found nothing.
pm_query_failed() {
    [ "$PM_RC" -ge 2 ] && return 0
    [[ $PM_ERR == "error:"* || $PM_ERR == *$'\n'"error:"* ]]
}

# Prints pacman's warning lines from the last capture to stderr, so warnings
# such as a missing sync database are not lost when ac reformats the output.
# Arguments: none (uses PM_ERR).
# Returns: 0.
pm_forward_warnings() {
    local line
    while IFS= read -r line; do
        case "$line" in
            "warning: "*) printf '%s\n' "$line" >&2 ;;
        esac
    done <<<"$PM_ERR"
}

# Turns the last captured stderr into a readable failure reason: the first
# "error:" line, followed by any further error or continuation lines
# (warnings are left out). Lines are separated by \n.
# Arguments: none (uses PM_ERR and PM_RC).
# Returns: 0. Side effects: sets PM_REASON.
pm_failure_reason() {
    local line text
    PM_REASON=""
    while IFS= read -r line; do
        case "$line" in
            "error: "*)
                text=${line#error: }
                PM_REASON+="${PM_REASON:+$'\n'}$text"
                ;;
            "warning: "* | "") ;;
            *)
                text=${line#"${line%%[![:space:]]*}"}
                PM_REASON+="${PM_REASON:+$'\n'}$text"
                ;;
        esac
    done <<<"$PM_ERR"
    if [ -z "$PM_REASON" ]; then
        PM_REASON="pacman exited with status $PM_RC."
    fi
}

# Reports a failed read-only query using the last captured call: a headline
# plus pacman's actual reason (see pm_failure_reason). Permission problems get
# EX_PERMISSION.
# The error type distinguishes repository problems (the last call read the sync
# databases: -S*) from local database problems (-Q*).
# Arguments:
#   $1 - Optional headline (default: "unable to query package database.").
#   $2 - Optional error type (default: repository-error or database-error).
# Returns: the exit code used (EX_PERMISSION or EX_FAILURE). Does not exit.
pm_report_query_failure() {
    local headline=${1:-"unable to query package database."} type=${2:-}
    if [ -z "$type" ]; then
        case "$PM_LAST_OP" in
            -S*) type=repository-error ;;
            *) type=database-error ;;
        esac
    fi
    pm_failure_reason
    if [[ $PM_ERR == *"Permission denied"* ]]; then
        err_raise permission "$EX_PERMISSION" "$headline" "$PM_REASON"
    else
        err_raise "$type" "$EX_FAILURE" "$headline" "$PM_REASON"
    fi
}

# Looks up the installed version of a package.
# Arguments:
#   $1 - Package name.
# Returns: 0 if installed, 1 if not installed, 2 if the query itself failed
#   (the failure text stays in PM_ERR for pm_report_query_failure).
# Side effects: sets PM_VERSION (on success) and the pm_capture globals.
pm_installed_version() {
    PM_VERSION=""
    if pm_capture -Q -- "$1"; then
        PM_VERSION=${PM_OUT#* }
        return 0
    fi
    pm_is_not_found_error && return 1
    return 2
}

# Fetches package metadata: repository databases first, then installed
# packages (for local-only packages). A failure to read a database is kept
# distinct from "package does not exist".
# Arguments:
#   $1 - Package name.
# Returns: 0 found, 1 genuinely not found, 2 the query failed (details in
#   PM_ERR/PM_RC for pm_report_query_failure).
# Side effects: sets PM_OUT (the info text), PM_SOURCE and the capture globals.
pm_package_info() {
    if pm_capture -Si -- "$1"; then
        PM_SOURCE=sync
        return 0
    fi
    pm_is_not_found_error || return 2
    if pm_capture -Qi -- "$1"; then
        PM_SOURCE=local
        return 0
    fi
    pm_is_not_found_error && return 1
    return 2
}

# Determines a package's metadata and installation state. This is the one
# place that combines "does it exist" with "is it installed"; `ac info` and
# `ac status` both build on it.
# Arguments:
#   $1 - Package name.
# Returns: 0 found; 1 genuinely not found; 2 a query failed; 3 found, but the
#   installed state could not be read (PM_ERR then holds that failure).
# Side effects: sets PM_INFO, and PM_ST_STATE ("installed", "available" or
#   "unknown"), PM_ST_VERSION (installed version if installed, else the
#   repository version), PM_ST_REPO ("local" for local-only packages),
#   PM_ST_INSTALLED (0|1) and PM_ST_INSTALLED_VERSION. For installed packages
#   also PM_ST_UPDATE ("current", "available" or "unknown") and PM_ST_LATEST.
pm_package_status() {
    local rc name
    PM_ST_STATE="" PM_ST_VERSION="" PM_ST_REPO="" PM_ST_INSTALLED=0 PM_ST_INSTALLED_VERSION=""
    PM_ST_UPDATE="" PM_ST_LATEST=""
    pm_package_info "$1"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    pm_forward_warnings
    pm_parse_info "$PM_OUT"
    name=${PM_INFO[Name]:-$1}
    PM_ST_REPO=${PM_INFO[Repository]:-local}
    PM_ST_VERSION=${PM_INFO[Version]:-}
    pm_installed_version "$name"
    case $? in
        0)
            PM_ST_STATE=installed
            PM_ST_INSTALLED=1
            PM_ST_INSTALLED_VERSION=$PM_VERSION
            PM_ST_VERSION=$PM_VERSION
            pm_update_state "$name"
            ;;
        1)
            PM_ST_STATE=available
            ;;
        *)
            PM_ST_STATE=unknown
            return 3
            ;;
    esac
    return 0
}

# Loads the list of installed packages that have a newer version in the
# already-synchronized repository databases (pacman -Qu; no network access, no
# database refresh). The result is cached for the rest of the run, so checking
# many packages costs one pacman call.
# Arguments: none.
# Returns: 0 if the list is available, 2 if the query failed (also cached).
# Side effects: fills PM_UPGRADES (name -> newest version) and PM_UPGRADES_STATE.
pm_load_upgrades() {
    local name old arrow new
    case "$PM_UPGRADES_STATE" in
        ok) return 0 ;;
        failed) return 2 ;;
    esac
    PM_UPGRADES=()
    pm_capture -Qu
    if pm_query_failed; then
        PM_UPGRADES_STATE=failed
        return 2
    fi
    while read -r name old arrow new _; do
        [ -n "$name" ] && [ "$arrow" = "->" ] && PM_UPGRADES[$name]=$new
    done <<<"$PM_OUT"
    PM_UPGRADES_STATE=ok
    return 0
}

# Lists installed packages that have a newer version in the already
# synchronized databases (pacman -Qu; never refreshes the databases).
# Arguments: none.
# Returns: 0 on success (PM_ROWS may be empty); 2 if the query failed.
# Side effects: sets PM_ROWS to tab-separated rows: name, installed version,
#   latest version.
pm_list_upgradable() {
    local name old arrow new
    PM_ROWS=()
    pm_capture -Qu
    if pm_query_failed; then
        return 2
    fi
    pm_forward_warnings
    while read -r name old arrow new _; do
        [ -n "$name" ] && [ "$arrow" = "->" ] && PM_ROWS+=("$name"$'\t'"$old"$'\t'"$new")
    done <<<"$PM_OUT"
    return 0
}

# Determines whether an installed package has an update available, using the
# cached pm_load_upgrades list.
# Arguments:
#   $1 - Installed package name.
# Returns: 0. Side effects: sets PM_ST_UPDATE ("available", "current" or
#   "unknown" when the upgrade list could not be read) and PM_ST_LATEST (the
#   newest version when an update is available, else empty).
pm_update_state() {
    PM_ST_UPDATE=unknown
    PM_ST_LATEST=""
    pm_load_upgrades || return 0
    if [ -n "${PM_UPGRADES[$1]:-}" ]; then
        PM_ST_UPDATE=available
        PM_ST_LATEST=${PM_UPGRADES[$1]}
    else
        PM_ST_UPDATE=current
    fi
}

# Parses the text of `pacman -Si` / `pacman -Qi` for one package into PM_INFO.
# Continuation lines (indented) are appended to the previous field, separated
# by a newline (this keeps the entries of "Optional Deps" apart).
# Arguments:
#   $1 - The pacman info text.
# Returns: 0.
# Side effects: replaces the contents of the global PM_INFO.
pm_parse_info() {
    local line key=""
    PM_INFO=()
    while IFS= read -r line; do
        if [[ $line =~ ^([^[:space:]][^:]*[^[:space:]])[[:space:]]*:[[:space:]]?(.*)$ ]]; then
            key=${BASH_REMATCH[1]}
            PM_INFO[$key]=${BASH_REMATCH[2]}
        elif [[ -n $key && $line =~ ^[[:space:]]+(.+)$ ]]; then
            PM_INFO[$key]+=$'\n'"${BASH_REMATCH[1]}"
        fi
    done <<<"$1"
}

# Converts pacman search/query listings (-Ss or -Qs) read from stdin into
# tab-separated rows: repo, name, version, installed(0|1), description.
# Arguments: none (reads stdin).
# Returns: prints one row per package on stdout.
pm_parse_listing() {
    awk '
        function flush() {
            if (have) print repo "\t" name "\t" ver "\t" inst "\t" desc
        }
        /^[^[:space:]]/ {
            flush()
            split($1, parts, "/")
            repo = parts[1]; name = parts[2]; ver = $2
            inst = ($0 ~ /\[installed/) ? 1 : 0
            desc = ""; have = 1
            next
        }
        /^[[:space:]]/ {
            sub(/^[[:space:]]+/, "")
            desc = (desc == "") ? $0 : desc " " $0
        }
        END { flush() }
    '
}

# Looks up the architecture of repository packages with one pacman call per
# 500 targets (search results do not include it).
# Arguments:
#   $@ - Targets in "repo/name" form.
# Returns: prints "repo/name<TAB>architecture" lines on stdout; packages that
#   cannot be resolved are omitted.
pm_arch_lookup() {
    local -a targets=("$@")
    local chunk=500 out
    while [ "${#targets[@]}" -gt 0 ]; do
        out=$(pm_run -Si -- "${targets[@]:0:$chunk}" 2>/dev/null) || true
        printf '%s\n' "$out" | awk '
            /^Repository/   { v = $0; sub(/^[^:]*:[ ]*/, "", v); repo = v }
            /^Name/         { v = $0; sub(/^[^:]*:[ ]*/, "", v); name = v }
            /^Architecture/ { v = $0; sub(/^[^:]*:[ ]*/, "", v); print repo "/" name "\t" v }
        '
        targets=("${targets[@]:$chunk}")
    done
}

# Searches the repositories. Every term must match (pacman -Ss semantics,
# regular expressions allowed). One pacman call finds the packages and one
# more per 500 results fetches their architectures.
# Arguments:
#   $@ - Search terms.
# Returns: 0 on success (PM_ROWS may be empty: "no results" is not an error);
#   2 if the query failed (PM_ERR/PM_RC describe it).
# Side effects: sets PM_ROWS to tab-separated rows:
#   repo, name, version, installed(0|1), architecture, description.
pm_search() {
    local row repo name ver inst desc key arch
    local -a rows=() targets=()
    local -A archmap=()
    PM_ROWS=()
    pm_capture -Ss -- "$@"
    if pm_query_failed; then
        return 2
    fi
    pm_forward_warnings
    [ -n "$PM_OUT" ] || return 0

    mapfile -t rows < <(printf '%s\n' "$PM_OUT" | pm_parse_listing)
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r repo name _ <<<"$row"
        targets+=("$repo/$name")
    done
    while IFS=$'\t' read -r key arch; do
        archmap[$key]=$arch
    done < <(pm_arch_lookup "${targets[@]}")
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r repo name ver inst desc <<<"$row"
        printf -v row '%s\t%s\t%s\t%s\t%s\t%s' "$repo" "$name" "$ver" "$inst" "${archmap[$repo/$name]:-unknown}" "$desc"
        PM_ROWS+=("$row")
    done
    return 0
}

# Lists installed packages, optionally filtered (pacman -Q / -Qs).
# Arguments:
#   $@ - Optional search terms; all must match.
# Returns: 0 on success (PM_ROWS may be empty); 2 if the query failed.
# Side effects: sets PM_ROWS to tab-separated rows: name, version.
pm_list_installed() {
    PM_ROWS=()
    if [ "$#" -eq 0 ]; then
        pm_capture -Q
    else
        pm_capture -Qs -- "$@"
    fi
    if pm_query_failed; then
        return 2
    fi
    pm_forward_warnings
    if [ "$#" -eq 0 ]; then
        mapfile -t PM_ROWS < <(printf '%s\n' "$PM_OUT" | awk 'NF {print $1 "\t" $2}')
    else
        mapfile -t PM_ROWS < <(printf '%s\n' "$PM_OUT" | pm_parse_listing | cut -f2,3)
    fi
    return 0
}

# Finds orphan packages: installed as dependencies and no longer required by
# any package. The dependency analysis is done entirely by pacman (-Qdtq).
# Arguments: none.
# Returns: 0 on success (PM_NAMES may be empty); 2 if the query failed.
# Side effects: sets PM_NAMES.
pm_orphans() {
    PM_NAMES=()
    pm_capture -Qdtq
    if pm_query_failed; then
        return 2
    fi
    pm_forward_warnings
    if [ -n "$PM_OUT" ]; then
        mapfile -t PM_NAMES <<<"$PM_OUT"
    fi
    return 0
}

# Reads the most recent package transactions from pacman's log. Only lines
# that pacman's libalpm writes for completed package changes are used
# ("[ALPM] installed|removed|upgraded|downgraded|reinstalled name (version)");
# both the ISO-8601 and the older "YYYY-MM-DD HH:MM" timestamp styles are
# understood. Anything that does not match is ignored, never guessed.
# Arguments:
#   $1 - Maximum number of entries (the newest ones are kept, oldest first).
#   $2 - Optional action filter: installed, removed or upgraded (anything else
#        is ignored; the value only ever selects a fixed pattern below).
# Returns: 0 on success (PM_ROWS may be empty); 2 if the log cannot be read
#   (PM_ERR then holds an "error:" line).
# Side effects: sets PM_ROWS to rows: date, time, action, package, detail.
pm_history() {
    local limit=$1 actions='installed|removed|upgraded|downgraded|reinstalled' log line total start i
    local -a lines=()
    local re='^\[([0-9]{4}-[0-9]{2}-[0-9]{2})[T ]([0-9]{2}:[0-9]{2})[^]]*\] \[ALPM\] (installed|removed|upgraded|downgraded|reinstalled) ([^ ]+) \((.*)\)$'
    PM_ROWS=()
    case "${2:-}" in
        installed | removed | upgraded) actions=$2 ;;
    esac
    log=$(pm_log_path)
    pm_capture_cmd grep -E -e "\[ALPM\] ($actions) " -- "$log"
    if [ "$PM_RC" -ge 2 ]; then
        PM_ERR="error: cannot read the pacman log: ${PM_ERR#grep: }"
        return 2
    fi
    [ -n "$PM_OUT" ] || return 0
    mapfile -t lines <<<"$PM_OUT"
    total=${#lines[@]}
    start=$((total > limit ? total - limit : 0))
    for ((i = start; i < total; i++)); do
        line=${lines[$i]}
        if [[ $line =~ $re ]]; then
            PM_ROWS+=("${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"$'\t'"${BASH_REMATCH[3]}"$'\t'"${BASH_REMATCH[4]}"$'\t'"${BASH_REMATCH[5]}")
        fi
    done
    return 0
}

# ------------------------------------------------------------ diagnostics ----
# Each pm_check_* function is read-only. It returns 0 (pass), 1 (fail) or
# 2 (warning) and leaves an explanation in PM_CHECK_DETAIL (empty on pass).

# Checks that pacman's local package database can be read.
# Arguments: none.
# Returns: 0 pass, 1 fail. Side effects: sets PM_CHECK_DETAIL.
pm_check_local_db() {
    PM_CHECK_DETAIL=""
    pm_capture -Q -- pacman
    if pm_query_failed && ! pm_is_not_found_error; then
        pm_failure_reason
        PM_CHECK_DETAIL=$PM_REASON
        return 1
    fi
    return 0
}

# Checks that the repository (sync) databases are present and readable by
# asking pacman about its own package.
# Arguments: none.
# Returns: 0 pass, 1 fail. Side effects: sets PM_CHECK_DETAIL.
pm_check_sync_db() {
    PM_CHECK_DETAIL=""
    if pm_capture -Si -- pacman; then
        return 0
    fi
    if pm_query_failed && ! pm_is_not_found_error; then
        pm_failure_reason
        PM_CHECK_DETAIL=$PM_REASON
    else
        PM_CHECK_DETAIL="no synchronized repository data was found. Run: sudo ac update"
    fi
    return 1
}

# Checks whether a pacman database lock file exists.
# Arguments: none.
# Returns: 0 pass, 1 fail. Side effects: sets PM_CHECK_DETAIL.
pm_check_lock() {
    local dir lock
    PM_CHECK_DETAIL=""
    dir=$(pm_db_path)
    lock=${dir%/}/db.lck
    if [ -e "$lock" ]; then
        PM_CHECK_DETAIL="lock file $lock exists. Another package manager may be running; if not, remove the file."
        return 1
    fi
    return 0
}

# Checks that pacman's configuration parses (using pacman-conf).
# Arguments: none.
# Returns: 0 pass, 1 fail, 2 warning if pacman-conf is unavailable.
# Side effects: sets PM_CHECK_DETAIL.
pm_check_pacman_conf() {
    PM_CHECK_DETAIL=""
    if [ -z "$PM_CONF_BIN" ]; then
        PM_CHECK_DETAIL="pacman-conf was not found, so the configuration was not checked."
        return 2
    fi
    pm_capture_cmd env LC_ALL=C "$PM_CONF_BIN"
    if [ "$PM_RC" -ne 0 ]; then
        pm_failure_reason
        PM_CHECK_DETAIL=$PM_REASON
        return 1
    fi
    return 0
}

# Checks the privileges ac is running with and that the database directory is
# readable. Not being root is only a warning: read-only commands work without it.
# Arguments: none.
# Returns: 0 pass, 1 fail, 2 warning. Side effects: sets PM_CHECK_DETAIL.
pm_check_permissions() {
    local dir
    PM_CHECK_DETAIL=""
    dir=$(pm_db_path)
    if [ ! -r "$dir" ]; then
        PM_CHECK_DETAIL="cannot read the package database directory $dir."
        return 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        PM_CHECK_DETAIL="not running as root: install, remove, update and similar commands need sudo."
        return 2
    fi
    return 0
}

# Checks that the first configured mirror answers (an HTTP request with a short
# timeout; only http/https URLs are used). Makes no change to the system.
# Arguments: none.
# Returns: 0 pass, 1 fail, 2 warning if the check cannot be performed.
# Side effects: sets PM_CHECK_DETAIL; contacts one mirror.
pm_check_network() {
    local url
    PM_CHECK_DETAIL=""
    url=$(pm_conf_run --repo=core Server | head -n 1)
    [ -n "$url" ] || url=$(pm_conf_run --repo=extra Server | head -n 1)
    if [ -z "$url" ]; then
        PM_CHECK_DETAIL="no mirror URL could be determined, so the network was not tested."
        return 2
    fi
    if [[ $url != http://* && $url != https://* ]]; then
        PM_CHECK_DETAIL="the first mirror ($url) is not an http(s) URL, so it was not tested."
        return 2
    fi
    if ! command -v curl >/dev/null 2>&1; then
        PM_CHECK_DETAIL="curl was not found, so the network was not tested."
        return 2
    fi
    pm_capture_cmd curl -sS -I --max-time 8 --proto '=http,https' --url "$url"
    if [ "$PM_RC" -ne 0 ]; then
        pm_failure_reason
        PM_CHECK_DETAIL="cannot reach $url: ${PM_ERR:-curl exited with status $PM_RC}"
        return 1
    fi
    return 0
}

# Reads pacman's and libalpm's versions from `pacman --version`, whose banner
# reads "Pacman vX.Y.Z - libalpm vA.B.C". Nothing is hard-coded: whatever
# versions are installed are reported, and compatibility is judged by the
# functional probes in pm_check_compat, not by a version list.
# Arguments: none.
# Returns: 0 if both versions were found, 1 if only pacman's was, 2 if neither.
# Side effects: sets PM_PACMAN_VERSION and PM_LIBALPM_VERSION (empty if unknown).
pm_version_info() {
    local ver='[0-9][0-9A-Za-z._+~-]*'
    local re="Pacman v($ver) - libalpm v($ver)" re2="[Pp]acman v($ver)"
    PM_PACMAN_VERSION="" PM_LIBALPM_VERSION=""
    pm_capture --version
    if [[ $PM_OUT =~ $re ]]; then
        PM_PACMAN_VERSION=${BASH_REMATCH[1]}
        PM_LIBALPM_VERSION=${BASH_REMATCH[2]}
        return 0
    fi
    if [[ $PM_OUT =~ $re2 ]]; then
        PM_PACMAN_VERSION=${BASH_REMATCH[1]}
        return 1
    fi
    return 2
}

# Doctor check: pacman is present and reports a version.
# Arguments: none.
# Returns: 0 pass, 2 warning if the version cannot be parsed.
# Side effects: sets PM_CHECK_DETAIL (the version on pass).
pm_check_pacman() {
    PM_CHECK_DETAIL=""
    pm_version_info
    if [ -z "$PM_PACMAN_VERSION" ]; then
        PM_CHECK_DETAIL="pacman is installed but its version could not be read."
        return 2
    fi
    PM_CHECK_DETAIL=$PM_PACMAN_VERSION
}

# Doctor check: libalpm is available (its version is part of pacman's banner).
# Arguments: none (uses the versions found by pm_check_pacman / pm_version_info).
# Returns: 0 pass, 1 fail. Side effects: sets PM_CHECK_DETAIL (the version on pass).
pm_check_libalpm() {
    PM_CHECK_DETAIL=""
    if [ -z "$PM_LIBALPM_VERSION" ]; then
        PM_CHECK_DETAIL="libalpm's version could not be determined from 'pacman --version'; the backend may be incompatible."
        return 1
    fi
    PM_CHECK_DETAIL=$PM_LIBALPM_VERSION
}

# Doctor check: detects the system architecture the way pacman sees it
# (pacman-conf Architecture), falling back to uname -m.
# Arguments: none.
# Returns: 0 pass, 2 warning if it cannot be determined.
# Side effects: sets PM_CHECK_DETAIL (the architecture on pass).
pm_check_arch() {
    local arch
    PM_CHECK_DETAIL=""
    arch=$(pm_conf_run Architecture | head -n 1) || arch=""
    if [ -z "$arch" ] || [ "$arch" = auto ]; then
        arch=$(uname -m 2>/dev/null) || arch=""
    fi
    if [ -z "$arch" ]; then
        PM_CHECK_DETAIL="the architecture could not be determined."
        return 2
    fi
    PM_CHECK_DETAIL=$arch
}

# Runs one read-only pacman probe for pm_check_compat. The probe passes when
# pacman exits normally, even with "nothing found"; it fails on any pacman
# error other than "package was not found".
# Arguments:
#   $@ - The pacman arguments to run (passed as separate words, never joined).
# Returns: 0 if the probe passed, 1 if pacman reported a real failure.
# Side effects: on failure sets PM_CHECK_DETAIL; sets the pm_capture globals.
pm_probe() {
    local op=$1
    pm_capture "$@"
    if pm_query_failed && ! pm_is_not_found_error; then
        pm_failure_reason
        PM_CHECK_DETAIL="'pacman $op' failed: ${PM_REASON//$'\n'/ }"
        return 1
    fi
    return 0
}

# Doctor check: actually exercises every read-only pacman operation ac relies
# on (local query, repository query, search, orphan and upgrade listings,
# group query). This detects a changed or incompatible pacman instead of
# assuming compatibility from a version number or the mere presence of
# libalpm.
# Arguments: none.
# Returns: 0 pass, 1 fail.
# Side effects: sets PM_CHECK_DETAIL; runs several read-only pacman calls.
pm_check_compat() {
    PM_CHECK_DETAIL=""
    pm_probe -Q -- pacman &&
        pm_probe -Si -- pacman &&
        pm_probe -Qs -- '^pacman$' &&
        pm_probe -Ss -- '^pacman$' &&
        pm_probe -Qdtq &&
        pm_probe -Qu &&
        pm_probe -Qgq -- base-devel || return 1
    PM_CHECK_DETAIL="read-only query operations verified${PM_PACMAN_VERSION:+ (pacman $PM_PACMAN_VERSION${PM_LIBALPM_VERSION:+, libalpm $PM_LIBALPM_VERSION})}"
}
