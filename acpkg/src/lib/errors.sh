#!/usr/bin/env bash
# Error handling for ac: exit codes, message helpers, and translation of
# pacman failures into ac's own error reporting. Sourced by src/ac.

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
readonly EX_NO_BACKEND=127   # pacman is not available
readonly EX_INTERRUPTED=130  # interrupted (SIGINT / SIGTERM)

# Prints "Error: <message>" to stderr.
# Arguments:
#   $@ - Message text.
# Returns: 0. Does not exit.
err_print() {
    printf 'Error: %s\n' "$*" >&2
}

# Prints a message to stderr exactly as given, without the "Error:" prefix.
# Used for messages whose wording is part of the CLI contract, such as
# "Package not found: foo".
# Arguments:
#   $@ - Message text.
# Returns: 0. Does not exit.
err_plain() {
    printf '%s\n' "$*" >&2
}

# Prints an error message and terminates ac.
# Arguments:
#   $1 - Exit code.
#   $2... - Message text.
# Returns: never returns; exits with the given code.
err_die() {
    local code=$1
    shift
    err_print "$*"
    exit "$code"
}

# Reports a command-line usage error and exits with EX_USAGE. Prints a usage
# line when one is supplied, otherwise a pointer to 'ac help'.
# Arguments:
#   $1 - Message text.
#   $2 - Optional usage line, e.g. "ac install <package>...".
# Returns: never returns; exits with EX_USAGE.
err_usage() {
    err_print "$1"
    if [ -n "${2:-}" ]; then
        printf '\nUsage:\n  %s\n' "$2" >&2
    else
        printf "\nRun 'ac help' for usage.\n" >&2
    fi
    exit "$EX_USAGE"
}

# Prints ac's own "<label> failed" line for a failed operation.
# Arguments:
#   $1 - Operation label, e.g. "package installation".
#   $2 - Optional reason appended after the label.
# Returns: 0. Does not exit.
err_fail() {
    if [ -n "${2:-}" ]; then
        printf 'ac: %s failed: %s\n' "$1" "$2" >&2
    else
        printf 'ac: %s failed.\n' "$1" >&2
    fi
}

# Interprets a failed pacman transaction and prints a clear ac-level
# explanation. pacman's own stderr has already been shown to the user (it is
# streamed live), so nothing useful is hidden; this adds classification and a
# stable exit code. Matching relies on pacman's English messages (ac runs
# pacman with LC_ALL=C for that reason). Checks run from most to least
# specific, so e.g. "failed to commit transaction (transaction interrupted)"
# is an interruption, not a generic transaction failure.
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
        err_fail "$label" "the package database is locked."
        err_plain "    Another package manager may be running. If not, remove /var/lib/pacman/db.lck."
        return "$EX_LOCKED"
    fi
    if grep -qi 'you cannot perform this operation unless you are root' "$errfile"; then
        err_fail "$label" "root privileges are required. Try running with sudo."
        return "$EX_PERMISSION"
    fi
    if grep -q 'target not found' "$errfile"; then
        names=$(sed -n 's/^error: target not found: *//p' "$errfile" | paste -sd, - | sed 's/,/, /g')
        if [ "$mode" = remove ]; then
            err_plain "Package not installed: $names"
        else
            err_plain "Package not found: $names"
        fi
        return "$EX_NOT_FOUND"
    fi
    if grep -qiE 'could not satisfy dependencies|unable to satisfy dependency|breaks dependency|conflicting dependencies|unresolvable package conflicts|are in conflict' "$errfile"; then
        if [ "$mode" = remove ]; then
            err_fail "$label" "other installed packages depend on it (see pacman's message above)."
        else
            err_fail "$label" "unresolved dependencies or package conflicts (see pacman's message above)."
        fi
        return "$EX_DEPENDENCY"
    fi
    if grep -qiE 'returned error: 404|error: 404' "$errfile"; then
        err_fail "$label" "a package file is missing on the mirror. Your package databases may be out of date; run: sudo ac update"
        return "$EX_NETWORK"
    fi
    if grep -qiE 'failed retrieving file|failed to retrieve some files|could not resolve|failed to connect|connection (timed out|refused)|network is unreachable|failed to synchronize all databases|operation too slow|transferred a partial file' "$errfile"; then
        err_fail "$label" "network failure. Check your connection and mirrors, then try again."
        return "$EX_NETWORK"
    fi
    if [ "$rc" -ge 128 ] || grep -qiE 'transaction interrupted|interrupt signal received' "$errfile"; then
        err_fail "$label" "the transaction was interrupted. Re-run the command to retry."
        return "$EX_INTERRUPTED"
    fi
    if grep -qiE 'failed to (init|prepare|commit) transaction' "$errfile"; then
        err_fail "$label" "pacman could not complete the transaction (see its messages above)."
        return "$EX_TRANSACTION"
    fi
    err_fail "$label" "pacman exited with status $rc."
    return "$rc"
}

# Removes the temporary file used to capture pacman's stderr, if one exists.
# Installed as the EXIT trap, so it runs on success, on failure, on exit
# through err_die/err_usage and after interruption; pm_tmp_release also
# calls it for the normal path.
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
