#!/usr/bin/env bash
# Error handling for ac. Every error is one structured record
#   type, exit status, message, reason (technical detail), hint, usage line
# stored in the ERR_* globals by err_raise, which renders it for humans
# (stderr) and, in --json mode, as a JSON error object (stdout). Commands
# never format errors themselves. Sourced by src/ac.

# Exit codes (documented in README.md; scripts may rely on them).
readonly EX_OK=0             # success
readonly EX_FAILURE=1        # generic failure (pacman's own status is reused)
readonly EX_USAGE=2          # bad command line
readonly EX_NOT_FOUND=3      # package not found / not installed
readonly EX_PERMISSION=4     # root privileges required
readonly EX_NETWORK=5        # mirrors or network unreachable
readonly EX_LOCKED=6         # pacman database lock is held
readonly EX_DEPENDENCY=7     # unresolved dependencies or package conflicts
readonly EX_TRANSACTION=8    # pacman could not prepare/commit the transaction
readonly EX_UNSUPPORTED=9    # the package-manager backend lacks the capability
readonly EX_NO_BACKEND=127   # pacman is not available
readonly EX_INTERRUPTED=130  # interrupted (SIGINT / SIGTERM)

# The last error record (see err_raise).
ERR_TYPE=""
ERR_EXIT=0
ERR_MESSAGE=""
ERR_REASON=""
ERR_HINT=""
ERR_USAGE=""

# Records an error and renders it. This is the single entry point for
# reporting an error; it does NOT exit, so callers choose between returning
# the code and exiting (see err_die). Error types in use: usage,
# invalid-search, not-found, not-installed, permission, repository-error
# (sync databases), database-error (local database), backend-unavailable,
# backend-error, unsupported, database-locked, network, dependency,
# transaction, interrupted and internal.
# Arguments:
#   $1 - Type: a stable identifier such as "usage", "not-found", "network".
#   $2 - Exit status to use.
#   $3 - Human message.
#   $4 - Optional technical reason (may span several lines separated by \n).
#   $5 - Optional hint, printed as an indented extra line.
#   $6 - Optional usage line (usage errors only).
# Returns: the exit status given in $2.
# Side effects: sets ERR_*; prints to stderr, plus a JSON error object on
#   stdout when AC_OPT_JSON=1.
err_raise() {
    ERR_TYPE=$1
    ERR_EXIT=$2
    ERR_MESSAGE=$3
    ERR_REASON=${4:-}
    ERR_HINT=${5:-}
    ERR_USAGE=${6:-}
    err_render_human
    if [ "$AC_OPT_JSON" -eq 1 ]; then
        err_render_json
    fi
    return "$ERR_EXIT"
}

# Prints the current ERR_* record for people on stderr. The wording follows
# the error type: "Package not found: x" stands alone, transaction-level
# failures read "ac: <message>: <reason>", everything else is
# "Error: <message>" followed by an optional "Reason:" block.
# Arguments: none (uses ERR_*).
# Returns: 0.
err_render_human() {
    local line first=1
    case "$ERR_TYPE" in
        not-found | not-installed)
            printf '%s\n' "$ERR_MESSAGE" >&2
            ;;
        database-locked | network | dependency | transaction | interrupted | backend-error)
            if [ -n "$ERR_REASON" ]; then
                printf 'ac: %s: %s\n' "$ERR_MESSAGE" "$ERR_REASON" >&2
            else
                printf 'ac: %s.\n' "$ERR_MESSAGE" >&2
            fi
            ;;
        *)
            printf '%sError:%s %s\n' "$OUT_E_RED" "$OUT_E_RESET" "$ERR_MESSAGE" >&2
            if [ -n "$ERR_REASON" ]; then
                while IFS= read -r line; do
                    if [ "$first" -eq 1 ]; then
                        printf 'Reason: %s\n' "$line" >&2
                        first=0
                    else
                        printf '        %s\n' "$line" >&2
                    fi
                done <<<"$ERR_REASON"
            fi
            ;;
    esac
    if [ -n "$ERR_HINT" ]; then
        printf '    %s\n' "$ERR_HINT" >&2
    fi
    if [ -n "$ERR_USAGE" ]; then
        printf '\nUsage:\n  %s\n' "$ERR_USAGE" >&2
    elif [ "$ERR_TYPE" = usage ]; then
        printf "\nRun 'ac help' for usage.\n" >&2
    fi
}

# Prints the current ERR_* record as ac's JSON error object on stdout.
# Arguments: none (uses ERR_*).
# Returns: 0.
err_render_json() {
    local doc
    json_error_object doc "$ERR_TYPE" "$ERR_MESSAGE" "$ERR_REASON" "$ERR_EXIT"
    json_emit "$doc"
}

# Reports an error and terminates ac.
# Arguments: same as err_raise.
# Returns: never returns; exits with the error's exit status.
err_die() {
    err_raise "$@"
    exit "$ERR_EXIT"
}

# Reports a command-line usage error and exits with EX_USAGE.
# Arguments:
#   $1 - Message text.
#   $2 - Optional usage line, e.g. "ac install <package>...". Without it the
#        output points to 'ac help'.
# Returns: never returns; exits with EX_USAGE.
err_usage() {
    err_die usage "$EX_USAGE" "$1" "" "" "${2:-}"
}

# Interprets a failed pacman transaction and reports it as a structured error.
# pacman's own stderr has already been shown to the user (it is streamed
# live), so nothing useful is hidden; this adds classification and a stable
# exit code. Matching relies on pacman's English messages (ac runs pacman
# with LC_ALL=C for that reason). Checks run from most to least specific, so
# e.g. "failed to commit transaction (transaction interrupted)" is an
# interruption, not a generic transaction failure.
# Arguments:
#   $1 - pacman's exit status.
#   $2 - Path of a file holding pacman's captured stderr.
#   $3 - Mode: "install", "remove" or "system"; selects the wording.
#   $4 - Operation label used in messages, e.g. "package installation".
# Returns: the exit code ac should terminate with: one of the EX_* codes, or
#   pacman's own status when nothing more specific is known. Does not exit.
err_report_pacman_failure() {
    local rc=$1 errfile=$2 mode=$3 label=$4 names

    if grep -qiE 'unable to lock database|could not lock database' "$errfile"; then
        err_raise database-locked "$EX_LOCKED" "$label failed" "the package database is locked." \
            "Another package manager may be running. If not, remove /var/lib/pacman/db.lck."
        return "$EX_LOCKED"
    fi
    if grep -qi 'you cannot perform this operation unless you are root' "$errfile"; then
        err_raise permission "$EX_PERMISSION" "$label failed" "root privileges are required. Try running with sudo."
        return "$EX_PERMISSION"
    fi
    if grep -q 'target not found' "$errfile"; then
        names=$(sed -n 's/^error: target not found: *//p' "$errfile" | paste -sd, - | sed 's/,/, /g')
        if [ "$mode" = remove ]; then
            err_raise not-installed "$EX_NOT_FOUND" "Package not installed: $names"
        else
            err_raise not-found "$EX_NOT_FOUND" "Package not found: $names"
        fi
        return "$EX_NOT_FOUND"
    fi
    if grep -qiE 'could not satisfy dependencies|unable to satisfy dependency|breaks dependency|conflicting dependencies|unresolvable package conflicts|are in conflict' "$errfile"; then
        if [ "$mode" = remove ]; then
            err_raise dependency "$EX_DEPENDENCY" "$label failed" "other installed packages depend on it (see pacman's message above)."
        else
            err_raise dependency "$EX_DEPENDENCY" "$label failed" "unresolved dependencies or package conflicts (see pacman's message above)."
        fi
        return "$EX_DEPENDENCY"
    fi
    if grep -qiE 'returned error: 404|error: 404' "$errfile"; then
        err_raise network "$EX_NETWORK" "$label failed" \
            "a package file is missing on the mirror. Your package databases may be out of date; run: sudo ac update"
        return "$EX_NETWORK"
    fi
    if grep -qiE 'failed retrieving file|failed to retrieve some files|could not resolve|failed to connect|connection (timed out|refused)|network is unreachable|failed to synchronize all databases|operation too slow|transferred a partial file' "$errfile"; then
        err_raise network "$EX_NETWORK" "$label failed" "network failure. Check your connection and mirrors, then try again."
        return "$EX_NETWORK"
    fi
    if [ "$rc" -ge 128 ] || grep -qiE 'transaction interrupted|interrupt signal received' "$errfile"; then
        err_raise interrupted "$EX_INTERRUPTED" "$label failed" "the transaction was interrupted. Re-run the command to retry."
        return "$EX_INTERRUPTED"
    fi
    if grep -qiE 'failed to (init|prepare|commit) transaction' "$errfile"; then
        err_raise transaction "$EX_TRANSACTION" "$label failed" "pacman could not complete the transaction (see its messages above)."
        return "$EX_TRANSACTION"
    fi
    err_raise backend-error "$rc" "$label failed" "pacman exited with status $rc."
    return "$rc"
}

# Removes the temporary file used to capture pacman's stderr, if one exists.
# Installed as the EXIT trap, so it runs on success, on failure, on exit
# through err_die and after interruption; pm_tmp_release also calls it for
# the normal path.
# Arguments: none.
# Returns: 0.
# Side effects: deletes the file named by the global PM_ERRFILE and clears it.
ac_cleanup() {
    if [ -n "${PM_ERRFILE:-}" ]; then
        rm -f -- "$PM_ERRFILE"
        PM_ERRFILE=""
    fi
    return 0
}

# Signal handler for SIGINT/SIGTERM. Reports the interruption and exits with
# EX_INTERRUPTED; the EXIT trap (ac_cleanup) then removes any temp file. bash
# runs this only after the foreground pacman process has finished, so pacman
# gets to clean up (release its lock) before ac exits.
# Arguments: none.
# Returns: never returns; exits with EX_INTERRUPTED.
ac_on_interrupt() {
    printf '\nac: interrupted.\n' >&2
    exit "$EX_INTERRUPTED"
}
