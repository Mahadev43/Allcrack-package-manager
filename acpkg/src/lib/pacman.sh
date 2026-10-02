#!/usr/bin/env bash
# Pacman backend for ac. This is the ONLY module that executes pacman or
# parses its output; commands talk to the package system through the pm_*
# functions below. A future libalpm backend would replace this file (keeping
# the same pm_* interface) without touching commands/ or cli.sh.
# Sourced by src/ac.

# Globals filled by pm_capture and pm_parse_info:
#   PM_OUT, PM_ERR, PM_RC - stdout, stderr and exit status of the last capture.
#   PM_INFO               - associative array of one package's info fields.
#   PM_SOURCE             - "sync" or "local": where pm_package_info found it.
#   PM_VERSION            - installed version found by pm_installed_version.
#   PM_ERRFILE            - temp file of the pacman call in progress (removed
#                           by pm_tmp_release or, on any exit, ac_cleanup).
PM_BIN=""
PM_OUT=""
PM_ERR=""
PM_RC=0
PM_ERRFILE=""
PM_SOURCE=""
PM_VERSION=""
declare -gA PM_INFO=()

# Locates the pacman binary (AC_PACMAN overrides the PATH lookup).
# Arguments: none.
# Returns: 0 on success; exits with EX_NO_BACKEND if pacman is unavailable.
# Side effects: sets the global PM_BIN.
pm_init() {
    PM_BIN=${AC_PACMAN:-}
    if [ -z "$PM_BIN" ]; then
        PM_BIN=$(command -v pacman) || PM_BIN=""
    fi
    if [ -z "$PM_BIN" ] || [ ! -x "$PM_BIN" ]; then
        err_die "$EX_NO_BACKEND" "pacman not found. ac requires an Arch Linux based system."
    fi
}

# Exits with EX_PERMISSION unless ac is running as root. Called before any
# command that modifies the system so the user gets a clear message instead of
# a pacman error.
# Arguments:
#   $@ - The ac command line (without "ac"), used in the "try sudo" hint.
# Returns: 0 if root; otherwise exits.
pm_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err_die "$EX_PERMISSION" "permission denied. This command must be run as root. Try: sudo ac $*"
    fi
}

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
        err_die "$EX_FAILURE" "cannot create a temporary file."
}

# Deletes the temporary file created by pm_tmp_acquire.
# Arguments: none.
# Returns: 0. Side effects: removes the file and clears PM_ERRFILE.
pm_tmp_release() {
    ac_cleanup
}

# Runs pacman, capturing stdout and stderr instead of printing them. Used for
# read-only queries whose output ac reformats.
# Arguments:
#   $@ - Arguments passed to pacman.
# Returns: pacman's exit status.
# Side effects: sets PM_OUT, PM_ERR and PM_RC.
pm_capture() {
    pm_tmp_acquire
    PM_OUT=$(pm_run "$@" 2>"$PM_ERRFILE")
    PM_RC=$?
    PM_ERR=$(<"$PM_ERRFILE")
    pm_tmp_release
    return "$PM_RC"
}

# Runs a state-changing pacman operation (install, remove, upgrade).
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

# Performs a full system synchronization and upgrade (pacman -Syu). ac never
# refreshes the databases without upgrading: that would create a partial
# upgrade, which Arch Linux does not support.
# Arguments:
#   $1 - Operation label used in failure messages, e.g. "system upgrade".
# Returns: the status of pm_transaction.
# Side effects: refreshes databases and upgrades packages.
pm_full_upgrade() {
    pm_transaction system "$1" -Syu
}

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
# chunk (search results do not include it).
# Arguments:
#   $@ - Targets in "repo/name" form.
# Returns: prints "repo/name<TAB>architecture" lines on stdout; packages that
#   cannot be resolved are omitted.
pm_arch_lookup() {
    local -a targets=("$@")
    local chunk=100 out
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

# Parses the text of `pacman -Si` / `pacman -Qi` for one package into PM_INFO.
# Continuation lines (indented) are appended to the previous field.
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
            PM_INFO[$key]+=" ${BASH_REMATCH[1]}"
        fi
    done <<<"$1"
}

# Reports a failed read-only query using the last pm_capture data: a headline,
# then "Reason:" with pacman's actual error (continuation lines indented).
# Warnings are not part of the reason. Permission problems get EX_PERMISSION.
# Arguments:
#   $1 - Optional headline (default: "unable to query package database.").
# Returns: the exit code to use (EX_PERMISSION or EX_FAILURE). Does not exit.
pm_report_query_failure() {
    local headline=${1:-"unable to query package database."}
    local line text reason="" extra="" code=$EX_FAILURE
    while IFS= read -r line; do
        case "$line" in
            "error: "*)
                text=${line#error: }
                if [ -z "$reason" ]; then reason=$text; else extra+="        $text"$'\n'; fi
                ;;
            "warning: "* | "") ;;
            *)
                text=${line#"${line%%[![:space:]]*}"}
                extra+="        $text"$'\n'
                ;;
        esac
    done <<<"$PM_ERR"
    if [ -z "$reason" ]; then
        reason="pacman exited with status $PM_RC."
    fi
    if [[ $PM_ERR == *"Permission denied"* ]]; then
        code=$EX_PERMISSION
    fi
    err_print "$headline"
    printf 'Reason: %s\n' "$reason" >&2
    if [ -n "$extra" ]; then
        printf '%s' "$extra" >&2
    fi
    return "$code"
}
