#!/usr/bin/env bash
# Test suite for AllCrack Package Manager (ac) v0.2.
#
# Usage:
#   tests/run_tests.sh                  Mock mode (default): uses tests/mock/pacman,
#                                       runs anywhere (Fedora, Arch, CI), changes nothing.
#   tests/run_tests.sh --live           Read-only checks against the REAL pacman.
#                                       Run inside an Arch / AllCrack OS VM.
#   tests/run_tests.sh --live-mutating  Also installs/removes the package "tree" and runs
#                                       a full system update. Must be root, VM only!
#
# Static checks (syntax, a comment on every function) run in every mode.

set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname -- "$HERE")
AC="$ROOT/src/ac"
MOCK_DIR="$HERE/mock"

LIVE=0
MUTATING=0
PASS=0
FAIL=0
OUT="" ERR="" RC=0
MOCK_STATE=""
TEST_PACMAN=""

# Records a passing assertion.
# Arguments:
#   $1 - Assertion label.
# Returns: 0. Side effects: increments PASS and prints a line.
pass() {
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$1"
}

# Records a failing assertion and shows the last command's output for debugging.
# Arguments:
#   $1 - Assertion label.
# Returns: 0. Side effects: increments FAIL and prints diagnostics.
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$1"
    printf '        rc=%s\n        stdout: %s\n        stderr: %s\n' "$RC" "$OUT" "$ERR" | head -n 12
}

# Prepares a fresh fake pacman state: a clean temp dir, a baseline set of
# installed packages, root identity and no injected failures.
# Arguments: none.
# Returns: 0. Side effects: sets/exports MOCK_STATE, MOCK_UID, MOCK_FAIL,
#   MOCK_DEP_BLOCK, MOCK_QUERY_FAIL, MOCK_EMPTY_SYNC, MOCK_SLOW and
#   TEST_PACMAN; removes the previous state dir. Creates $MOCK_STATE/tmp, which
#   run_ac uses as ac's TMPDIR so leftover temp files can be detected.
new_state() {
    if [ -n "$MOCK_STATE" ]; then
        rm -rf -- "$MOCK_STATE"
    fi
    MOCK_STATE=$(mktemp -d "${TMPDIR:-/tmp}/ac-test.XXXXXX")
    printf '%s\n' 'bash 5.2.037-1' 'glibc 2.40-1' 'git 2.47.0-1' 'ac-localpkg 1.0-1' >"$MOCK_STATE/installed"
    : >"$MOCK_STATE/calls.log"
    mkdir -p "$MOCK_STATE/tmp"
    export MOCK_STATE
    export MOCK_UID=0 MOCK_FAIL="" MOCK_DEP_BLOCK=0 MOCK_QUERY_FAIL="" MOCK_EMPTY_SYNC=0 MOCK_SLOW=""
    TEST_PACMAN="$MOCK_DIR/pacman"
}

# Runs ac with the given arguments and captures the result. In mock mode ac
# uses the fake pacman and fake id; in live mode it uses the real system and
# answers pacman's prompts automatically. ac's TMPDIR is $MOCK_STATE/tmp.
# Arguments:
#   $@ - Arguments for ac.
# Returns: 0. Side effects: sets OUT, ERR and RC.
run_ac() {
    local o e
    o=$(mktemp)
    e=$(mktemp)
    if [ "$LIVE" -eq 1 ]; then
        yes 2>/dev/null | TMPDIR="$MOCK_STATE/tmp" bash "$AC" "$@" >"$o" 2>"$e"
        RC=${PIPESTATUS[1]}
    else
        TMPDIR="$MOCK_STATE/tmp" PATH="$MOCK_DIR:$PATH" AC_PACMAN="$TEST_PACMAN" bash "$AC" "$@" >"$o" 2>"$e" </dev/null
        RC=$?
    fi
    OUT=$(<"$o")
    ERR=$(<"$e")
    rm -f "$o" "$e"
}

# Asserts that the last run exited with a given status.
# Arguments:
#   $1 - Expected exit status.
#   $2 - Assertion label.
# Returns: 0.
assert_rc() {
    if [ "$RC" -eq "$1" ]; then pass "$2"; else fail "$2 (expected rc=$1)"; fi
}

# Asserts that the last run's stdout contains a substring.
# Arguments:
#   $1 - Expected substring.
#   $2 - Assertion label.
# Returns: 0.
assert_out_has() {
    if [[ $OUT == *"$1"* ]]; then pass "$2"; else fail "$2 (stdout lacks '$1')"; fi
}

# Asserts that the last run's stdout does not contain a substring.
# Arguments:
#   $1 - Forbidden substring.
#   $2 - Assertion label.
# Returns: 0.
assert_out_lacks() {
    if [[ $OUT != *"$1"* ]]; then pass "$2"; else fail "$2 (stdout contains '$1')"; fi
}

# Asserts that the last run's stderr contains a substring.
# Arguments:
#   $1 - Expected substring.
#   $2 - Assertion label.
# Returns: 0.
assert_err_has() {
    if [[ $ERR == *"$1"* ]]; then pass "$2"; else fail "$2 (stderr lacks '$1')"; fi
}

# Asserts that the last run's stderr does not contain a substring.
# Arguments:
#   $1 - Forbidden substring.
#   $2 - Assertion label.
# Returns: 0.
assert_err_lacks() {
    if [[ $ERR != *"$1"* ]]; then pass "$2"; else fail "$2 (stderr contains '$1')"; fi
}

# Asserts that ac left no temporary files in its private TMPDIR.
# Arguments:
#   $1 - Assertion label.
# Returns: 0.
assert_no_tempfiles() {
    local left
    left=$(ls -A "$MOCK_STATE/tmp")
    if [ -z "$left" ]; then pass "$1"; else fail "$1 (left behind: $left)"; fi
}

# Waits up to a few seconds for a background process to exit and stores its
# status in RC; kills its whole process group if it does not exit in time.
# Arguments:
#   $1 - PID of the background job (its process group id when job control is on).
#   $2 - Maximum seconds to wait.
# Returns: 0. Side effects: sets RC (999 if the process had to be killed).
wait_for_exit() {
    local pid=$1 limit=$(($2 * 10)) i=0 status killed=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$limit" ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        killed=1
    fi
    wait "$pid" 2>/dev/null
    status=$?
    if [ "$killed" -eq 1 ]; then RC=999; else RC=$status; fi
}

# Asserts that the fake pacman was (not) invoked with arguments matching a
# regular expression. Mock mode only.
# Arguments:
#   $1 - "yes" or "no" (whether a match is expected).
#   $2 - Extended regular expression matched against each logged call.
#   $3 - Assertion label.
# Returns: 0.
assert_called() {
    local found=no
    grep -qE -- "$2" "$MOCK_STATE/calls.log" && found=yes
    if [ "$found" = "$1" ]; then pass "$3"; else fail "$3 (pacman call /$2/ expected: $1)"; fi
}

# Static check: every shell file parses cleanly with `bash -n`.
# Arguments: none.
# Returns: 0. Side effects: records assertions.
test_syntax() {
    local f
    echo "== syntax =="
    while IFS= read -r f; do
        if bash -n "$f" 2>/dev/null; then pass "syntax: ${f#"$ROOT"/}"; else fail "syntax: ${f#"$ROOT"/}"; fi
    done < <(find "$ROOT/src" "$HERE" "$ROOT/install.sh" -type f \( -name '*.sh' -o -name ac -o -name pacman -o -name id \) 2>/dev/null | sort)
}

# Static check: every function definition must be directly preceded by a
# comment line (the project's documentation rule).
# Arguments: none.
# Returns: 0. Side effects: records one assertion per file.
test_function_comments() {
    local f bad
    echo "== every function is commented =="
    while IFS= read -r f; do
        bad=$(awk '
            /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { if (prev !~ /^#/) print FILENAME ":" FNR ": " $0 }
            { prev = $0 }
        ' "$f")
        if [ -z "$bad" ]; then pass "documented: ${f#"$ROOT"/}"; else fail "undocumented function: $bad"; fi
    done < <(find "$ROOT/src" "$HERE" "$ROOT/install.sh" -type f \( -name '*.sh' -o -name ac -o -name pacman -o -name id \) 2>/dev/null | sort)
}

# Tests `ac --version`, `-V`, `version` and `ac help` (works without pacman).
# Arguments: none.
# Returns: 0. Side effects: records assertions.
test_version_and_help() {
    echo "== version and help =="
    new_state
    run_ac --version
    assert_rc 0 "--version exits 0"
    assert_out_has "AllCrack Package Manager 0.2.0" "--version prints 0.2.0"
    run_ac -V
    assert_out_has "AllCrack Package Manager 0.2.0" "-V prints 0.2.0"
    run_ac version
    assert_out_has "AllCrack Package Manager 0.2.0" "'version' prints 0.2.0"
    run_ac help
    assert_rc 0 "help exits 0"
    assert_out_has "search <query>" "help lists search"
    assert_out_has "info <package>..." "help lists info"
    assert_out_has "list [query]" "help lists list"
    assert_out_has "Synchronize/update system" "help describes update"
    assert_out_has "partial upgrade" "help documents update safety"
    assert_out_has "Examples:" "help has examples"
    run_ac install --help
    assert_out_has "Usage:" "'ac install --help' shows help"
    if [ "$LIVE" -eq 0 ]; then
        TEST_PACMAN=/nonexistent/pacman
        run_ac help
        assert_rc 0 "help works without pacman"
    fi
}

# Tests usage errors, unknown commands, root and backend requirements.
# Arguments: none.
# Returns: 0. Side effects: records assertions.
test_errors() {
    local cmd
    echo "== errors =="
    new_state
    run_ac
    assert_rc 2 "no command -> rc 2"
    assert_err_has "command required" "no command message"
    for cmd in install remove search info; do
        run_ac "$cmd"
        assert_rc 2 "'ac $cmd' without argument -> rc 2"
        assert_err_has "required" "'ac $cmd' says an argument is required"
    done
    run_ac install
    assert_err_has "Error: package name required." "install missing-argument message (v0.1 wording)"
    assert_err_has "ac install <package>..." "install usage line"
    run_ac unknown-command
    assert_rc 2 "unknown command -> rc 2"
    assert_err_has "unknown command 'unknown-command'" "unknown command message"
    assert_err_has "Run 'ac help' for usage." "unknown command hint"
    run_ac install --bogus
    assert_rc 2 "invalid option -> rc 2"
    assert_err_has "invalid option '--bogus'" "invalid option message"
    run_ac update extra
    assert_rc 2 "update with arguments -> rc 2"
    run_ac install ""
    assert_rc 2 "empty argument -> rc 2"
    run_ac search ""
    assert_rc 2 "empty search term -> rc 2"
    run_ac info ""
    assert_rc 2 "empty info argument -> rc 2"
    run_ac list --bogus
    assert_rc 2 "list with invalid option -> rc 2"
    run_ac -x
    assert_rc 2 "unknown top-level option -> rc 2"
    run_ac version extra
    assert_rc 2 "version with arguments -> rc 2"
    run_ac upgrade extra
    assert_rc 2 "upgrade with arguments -> rc 2"
    run_ac help extra
    assert_rc 0 "help ignores extra words"
    [ "$LIVE" -eq 1 ] && return 0

    MOCK_UID=1000
    for cmd in install remove; do
        run_ac "$cmd" git
        assert_rc 4 "non-root '$cmd' -> rc 4"
        assert_err_has "sudo ac $cmd git" "non-root '$cmd' suggests sudo"
    done
    run_ac update
    assert_rc 4 "non-root update -> rc 4"
    run_ac upgrade
    assert_rc 4 "non-root upgrade -> rc 4"
    assert_called no '^-S|^-R' "non-root never reaches pacman"
    run_ac search git
    assert_rc 0 "non-root search works"
    run_ac info git
    assert_rc 0 "non-root info works"
    run_ac list
    assert_rc 0 "non-root list works"
    MOCK_UID=0

    TEST_PACMAN=/nonexistent/pacman
    run_ac install git
    assert_rc 127 "pacman unavailable -> rc 127"
    assert_err_has "pacman not found" "pacman unavailable message"
}

# Tests `ac install`: multiple packages, skipping installed ones, unknown
# packages and failure classification (network, lock, interrupt, other).
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_install() {
    echo "== install =="
    new_state
    run_ac install git vim firefox
    assert_rc 0 "install git vim firefox -> rc 0"
    assert_out_has "Installing:" "install shows 'Installing:'"
    assert_out_has "  firefox" "install lists firefox"
    assert_out_has "  vim" "install lists vim"
    assert_out_has "Already installed (skipping):" "install reports already-installed git"
    assert_called yes '^-S --needed -- vim firefox$' "pacman got only the missing packages"
    assert_out_has "AllCrack Package Manager 0.2" "install shows banner"
    run_ac install git
    assert_rc 0 "install of installed package -> rc 0"
    assert_out_has "Nothing to do." "install says nothing to do"
    run_ac install nonexistent-package
    assert_rc 3 "unknown package -> rc 3"
    assert_err_has "Package not found: nonexistent-package" "package-not-found message"
    run_ac install firefox nonexistent-a nonexistent-b
    assert_err_has "Package not found: nonexistent-a, nonexistent-b" "lists every missing package"
    MOCK_FAIL=network run_ac install chromium
    assert_rc 5 "network failure -> rc 5"
    assert_err_has "network failure" "network failure message"
    MOCK_FAIL=lock run_ac install chromium
    assert_rc 6 "locked database -> rc 6"
    assert_err_has "db.lck" "lock message mentions db.lck"
    MOCK_FAIL=interrupted run_ac install chromium
    assert_rc 130 "interrupted transaction -> rc 130"
    MOCK_FAIL=signal run_ac install chromium
    assert_rc 130 "pacman killed by signal -> rc 130"
    MOCK_FAIL=generic run_ac install chromium
    assert_rc 8 "transaction failure (commit) -> rc 8"
    assert_err_has "ac: package installation failed" "v0.1 failure message preserved"
    assert_err_has "could not complete the transaction" "transaction failure explained"
    assert_err_has "conflicting files" "pacman's own error is not hidden"
    MOCK_FAIL=unknown run_ac install chromium
    assert_rc 1 "unexpected pacman failure keeps pacman's status"
    assert_err_has "pacman exited with status 1" "unexpected failure reports the status"
    assert_err_has "pacman.conf could not be read" "pacman's own error is not hidden (unexpected failure)"
}

# Tests `ac remove`: single and multiple packages, packages that are not
# installed, and dependency failures.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_remove() {
    echo "== remove =="
    new_state
    run_ac install firefox vim
    run_ac remove firefox
    assert_rc 0 "remove firefox -> rc 0"
    assert_out_has "Removing:" "remove shows 'Removing:'"
    assert_called yes '^-R -- firefox$' "pacman -R called"
    run_ac install firefox
    run_ac remove firefox vim
    assert_rc 0 "remove firefox vim -> rc 0"
    assert_called yes '^-R -- firefox vim$' "multi-package remove"
    run_ac remove firefox
    assert_rc 3 "removing a package that is not installed -> rc 3"
    assert_err_has "Package not installed: firefox" "not-installed message"
    run_ac remove git nope1 nope2
    assert_err_has "Package not installed: nope1, nope2" "lists every missing package"
    assert_called no '^-R -- git nope1' "nothing removed when any name is missing"
    MOCK_DEP_BLOCK=1 run_ac remove git
    assert_rc 7 "dependency failure -> rc 7"
    assert_err_has "depend on it" "dependency failure hint"
    assert_err_has "breaks dependency" "pacman's dependency text is shown"
}

# Tests `ac search` including partial terms, multiple terms, empty results
# and invalid expressions.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_search() {
    echo "== search =="
    new_state
    run_ac search firefox
    assert_rc 0 "search firefox -> rc 0"
    assert_out_has "Search results for: firefox" "search header"
    assert_out_has "extra/firefox" "search shows repo/name"
    assert_out_has "Version: 147.0-1" "search shows version"
    assert_out_has "Architecture: x86_64" "search shows architecture"
    assert_out_has "Description: Standalone web browser from mozilla.org" "search shows description"
    run_ac search docker
    assert_out_has "extra/docker" "search docker finds docker"
    assert_out_has "extra/docker-compose" "search docker finds docker-compose"
    run_ac search brow
    assert_out_has "extra/firefox" "partial term finds firefox"
    assert_out_has "extra/chromium" "partial term finds chromium"
    run_ac search web browser
    assert_out_has "extra/chromium" "multiple terms are combined"
    run_ac search git
    assert_out_has "[installed]" "installed packages are marked"
    run_ac search nonexistent-package
    assert_rc 0 "no results -> rc 0"
    assert_out_has "No packages found matching: nonexistent-package" "no-results message"
    run_ac search 'fire['
    assert_rc 1 "invalid expression -> rc 1"
    assert_err_has "invalid search expression" "invalid expression message"
    assert_err_has "Reason: invalid regular expression" "invalid expression shows pacman's reason"
}

# Tests `ac info` for repository, installed, local-only, several and missing
# packages.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_info() {
    echo "== info =="
    new_state
    run_ac info firefox
    assert_rc 0 "info firefox -> rc 0"
    assert_out_has "Package:        firefox" "info shows package"
    assert_out_has "Version:        147.0-1" "info shows version"
    assert_out_has "Repository:     extra" "info shows repository"
    assert_out_has "Architecture:   x86_64" "info shows architecture"
    assert_out_has "Installed Size: 263.00 MiB" "info shows installed size"
    assert_out_has "Dependencies:   dbus-glibc, ffmpeg, gtk3, libpulse" "info formats dependencies"
    assert_out_has "Status:         not installed" "info shows not-installed status"
    assert_out_has "  Standalone web browser from mozilla.org" "info shows description"
    run_ac info git
    assert_out_has "Status:         installed (2.47.0-1)" "info shows installed status"
    run_ac info firefox git
    assert_rc 0 "info with several packages -> rc 0"
    assert_out_has "Package:        firefox" "multi info: first package"
    assert_out_has "Package:        git" "multi info: second package"
    run_ac info ac-localpkg
    assert_rc 0 "info for a local-only package -> rc 0"
    assert_out_has "Repository:     local" "local-only package shows local repository"
    run_ac info nonexistent-package
    assert_rc 3 "info for unknown package -> rc 3"
    assert_err_has "Package not found: nonexistent-package" "info not-found message"
    run_ac info firefox nonexistent-package
    assert_rc 3 "mixed found/missing -> rc 3"
    assert_out_has "Package:        firefox" "found package still shown"
}

# Tests `ac list` with and without a query.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_list() {
    echo "== list =="
    new_state
    run_ac list
    assert_rc 0 "list -> rc 0"
    assert_out_has "Installed packages (4):" "list shows count"
    assert_out_has "git" "list shows git"
    assert_out_has "5.2.037-1" "list shows versions"
    run_ac list git
    assert_rc 0 "list git -> rc 0"
    assert_out_has "Installed packages matching: git (1):" "filtered list header"
    assert_out_lacks "glibc" "filtered list excludes other packages"
    run_ac list firefox
    assert_rc 0 "list of uninstalled package -> rc 0"
    assert_out_has "No installed packages found matching: firefox" "empty filtered list message"
}

# Tests `ac update` and `ac upgrade`: both must use a full -Syu and never a
# bare -Sy (partial upgrade).
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_update_upgrade() {
    echo "== update / upgrade =="
    new_state
    run_ac update
    assert_rc 0 "update -> rc 0"
    assert_called yes '^-Syu$' "update runs pacman -Syu"
    assert_called no '^-Sy$' "update never runs a bare -Sy"
    assert_out_has "Synchronizing package databases" "update explains what it does"
    run_ac upgrade
    assert_rc 0 "upgrade -> rc 0"
    assert_called yes '^-Syu$' "upgrade runs pacman -Syu"
    assert_called no '^-Sy$' "upgrade never runs a bare -Sy"
    assert_out_has "Checking for updates..." "upgrade progress text"
    assert_out_has "Preparing system upgrade..." "upgrade progress text (2)"
    MOCK_FAIL=network run_ac update
    assert_rc 5 "update network failure -> rc 5"
    MOCK_FAIL=lock run_ac upgrade
    assert_rc 6 "upgrade lock failure -> rc 6"
}

# Verifies that every v0.1 command still works (apart from the documented
# change that update now performs a full upgrade).
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_v01_compatibility() {
    echo "== v0.1 compatibility =="
    new_state
    run_ac install firefox
    assert_rc 0 "v0.1: sudo ac install firefox"
    run_ac remove firefox
    assert_rc 0 "v0.1: sudo ac remove firefox"
    run_ac update
    assert_rc 0 "v0.1: sudo ac update"
    run_ac upgrade
    assert_rc 0 "v0.1: sudo ac upgrade"
    run_ac help
    assert_rc 0 "v0.1: ac help"
    run_ac --version
    assert_rc 0 "v0.1: ac --version"
}

# Regression tests for `ac info` error handling: a genuinely missing package
# is "not found", but any pacman/database failure must be reported as a query
# failure with pacman's real reason (never as "Package not found").
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_info_failures() {
    echo "== info: not found vs. query failure =="
    new_state
    run_ac info nonexistent-package
    assert_rc 3 "genuinely missing package -> rc 3"
    assert_err_has "Package not found: nonexistent-package" "missing package: not-found message"
    assert_err_lacks "unable to query" "missing package is not a query failure"

    MOCK_QUERY_FAIL=sync run_ac info firefox
    assert_rc 1 "repository database failure -> rc 1"
    assert_err_has "Error: unable to query package database." "repo failure: headline"
    assert_err_has "Reason: could not register 'core' database (database is incorrect version)" "repo failure: pacman's real reason"
    assert_err_lacks "Package not found" "repo failure is not reported as not found"
    MOCK_QUERY_FAIL=sync run_ac info nonexistent-package
    assert_rc 1 "repo failure for an unknown name is still a failure"
    assert_err_lacks "Package not found" "repo failure never becomes not found"

    MOCK_QUERY_FAIL=local run_ac info ac-localpkg
    assert_rc 1 "local database failure -> rc 1"
    assert_err_has "Reason: failed to initialize alpm library" "local failure: pacman's real reason"
    assert_err_has "could not find or read directory" "local failure: detail line kept"
    assert_err_lacks "Package not found" "local failure is not reported as not found"
    MOCK_QUERY_FAIL=local run_ac info git
    assert_rc 1 "local failure while checking installed state -> rc 1"
    assert_out_has "Package:        git" "repository data is still shown"
    assert_out_has "Status:         unknown" "installed state is reported as unknown, not 'not installed'"
    assert_err_has "unable to query package database" "installed-state failure is reported"

    MOCK_QUERY_FAIL=other run_ac info firefox
    assert_rc 1 "other pacman query failure -> rc 1"
    assert_err_has "Reason: config file /etc/pacman.conf could not be read" "other failure: pacman's real reason"
    MOCK_QUERY_FAIL=perm run_ac info firefox
    assert_rc 4 "permission problem -> rc 4"
    assert_err_has "Permission denied" "permission failure shows pacman's reason"

    MOCK_QUERY_FAIL=sync run_ac info firefox git
    assert_rc 1 "failure with several packages -> rc 1"
    run_ac info firefox nonexistent-package
    assert_rc 3 "found + missing -> rc 3"
    assert_out_has "Package:        firefox" "found package is still shown"
}

# Regression tests for `ac search` and `ac list`: a failed query must not be
# mistaken for "no results", while a real empty result stays a success.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_query_failures() {
    echo "== search / list: failures vs. empty results =="
    new_state
    MOCK_QUERY_FAIL=sync run_ac search firefox
    assert_rc 1 "search: repository failure -> rc 1"
    assert_err_has "unable to query package database" "search: failure headline"
    assert_err_has "database is incorrect version" "search: pacman's reason shown"
    assert_out_lacks "No packages found" "search: failure is not 'no results'"
    MOCK_QUERY_FAIL=sync run_ac search nonexistent-package
    assert_rc 1 "search: failure with unmatched term is still a failure"
    assert_out_lacks "No packages found" "search: failure never becomes 'no results'"
    MOCK_QUERY_FAIL=local run_ac list
    assert_rc 1 "list: local database failure -> rc 1"
    assert_err_has "unable to query package database" "list: failure headline"
    assert_out_lacks "No installed packages" "list: failure is not 'empty list'"
    MOCK_QUERY_FAIL=local run_ac list git
    assert_rc 1 "list <query>: local database failure -> rc 1"
    assert_out_lacks "No installed packages" "list <query>: failure is not 'no matches'"
    MOCK_QUERY_FAIL=other run_ac search git
    assert_rc 1 "search: other query failure -> rc 1"
    MOCK_EMPTY_SYNC=1 run_ac search firefox
    assert_rc 0 "search on an unsynchronized system -> rc 0 (no results)"
    assert_out_has "No packages found matching: firefox" "unsynchronized: no-results message"
    assert_err_has "warning: database file for 'core' does not exist" "pacman's warning is forwarded"
    run_ac search nonexistent-package
    assert_rc 0 "real empty result -> rc 0"
    assert_err_lacks "Error" "real empty result prints no error"
    run_ac list nonexistent-package
    assert_rc 0 "list: real empty result -> rc 0"
    assert_no_tempfiles "queries leave no temp files (success, empty and failure)"
}

# Tests for the transaction layer: failure classification, preserved exit
# status, warnings that stay visible, and that nothing is installed when one
# of several packages is unknown.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_transactions() {
    echo "== transactions =="
    new_state
    run_ac install vim
    assert_rc 0 "successful transaction -> rc 0"
    assert_out_has ":: installing vim" "pacman's normal output is shown"
    assert_no_tempfiles "successful transaction leaves no temp files"
    run_ac install firefox nonexistent-package
    assert_rc 3 "one unknown package fails the whole install -> rc 3"
    assert_err_has "error: target not found: nonexistent-package" "pacman's own error is shown"
    run_ac list firefox
    assert_out_has "No installed packages found matching: firefox" "nothing was installed after the failure"
    assert_no_tempfiles "failed transaction leaves no temp files"
    MOCK_FAIL=deps run_ac install firefox
    assert_rc 7 "dependency failure -> rc 7"
    assert_err_has "unable to satisfy dependency 'libfoo'" "dependency failure: pacman's text shown"
    assert_err_has "unresolved dependencies or package conflicts" "dependency failure: ac explanation"
    MOCK_FAIL=conflict run_ac install firefox
    assert_rc 7 "package conflict -> rc 7"
    assert_err_has "chromium and firefox are in conflict" "conflict: pacman's text shown"
    MOCK_FAIL=lock run_ac install firefox
    assert_rc 6 "database lock -> rc 6"
    MOCK_FAIL=network run_ac upgrade
    assert_rc 5 "network failure -> rc 5"
    assert_err_has "Could not resolve host" "network: pacman's text shown"
    MOCK_FAIL=unknown run_ac update
    assert_rc 1 "unexpected failure keeps pacman's exit status"
    MOCK_SLOW=warn run_ac install chromium
    assert_rc 0 "install with a pacman warning -> rc 0"
    assert_err_has "warning: early warning from the transaction" "warnings are not lost on success"
    assert_no_tempfiles "all transactions above left no temp files"
}

# Verifies that pacman's stderr reaches the user while pacman is still
# running (not only after it finishes) and is shown exactly once.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_stderr_streaming() {
    local pid o e
    echo "== stderr is streamed live =="
    new_state
    o="$MOCK_STATE/stream.out"
    e="$MOCK_STATE/stream.err"
    (
        export PATH="$MOCK_DIR:$PATH" AC_PACMAN="$TEST_PACMAN" TMPDIR="$MOCK_STATE/tmp" MOCK_SLOW=warn
        exec bash "$AC" install chromium >"$o" 2>"$e" </dev/null
    ) &
    pid=$!
    sleep 1
    OUT="" ERR=$(<"$e") RC=-
    if kill -0 "$pid" 2>/dev/null && [[ $ERR == *"early warning"* ]]; then
        pass "warning is visible while pacman is still running"
    else
        fail "warning should be visible while pacman is still running"
    fi
    wait_for_exit "$pid" 6
    OUT=$(<"$o")
    ERR=$(<"$e")
    assert_rc 0 "streamed transaction -> rc 0"
    if [ "$(grep -c 'early warning' "$e")" -eq 1 ]; then pass "warning is shown exactly once"; else fail "warning shown exactly once"; fi
    assert_out_has ":: installing chromium" "stdout still reaches the user"
    assert_no_tempfiles "streamed transaction leaves no temp files"
}

# Simulates Ctrl+C: sends SIGINT to ac's whole process group while a
# transaction is running and checks the exit status, the visible messages and
# that no temp files remain.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_interrupt() {
    local pid o e
    echo "== Ctrl+C =="
    new_state
    o="$MOCK_STATE/int.out"
    e="$MOCK_STATE/int.err"
    set -m
    (
        export PATH="$MOCK_DIR:$PATH" AC_PACMAN="$TEST_PACMAN" TMPDIR="$MOCK_STATE/tmp" MOCK_SLOW=hang
        exec bash "$AC" install chromium >"$o" 2>"$e" </dev/null
    ) &
    pid=$!
    sleep 1
    kill -INT -- "-$pid"
    wait_for_exit "$pid" 5
    set +m
    OUT=$(<"$o")
    ERR=$(<"$e")
    assert_rc 130 "Ctrl+C during a transaction -> rc 130 (and ac exits promptly)"
    assert_err_has "transaction interrupted" "pacman's own interrupt message is shown"
    assert_err_has "ac: interrupted" "ac reports the interruption"
    assert_no_tempfiles "Ctrl+C leaves no temp files"
}

# Static check: no code line may run a bare `pacman -Sy` (refresh without
# upgrade), which would create an unsupported partial-upgrade state.
# Arguments: none.
# Returns: 0. Side effects: records one assertion.
test_no_bare_sy() {
    local hits
    echo "== no bare pacman -Sy =="
    hits=$(grep -rnE -- '-Sy([^u]|$)' "$ROOT/src" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
    if [ -z "$hits" ]; then pass "no bare -Sy in src/"; else fail "bare -Sy found: $hits"; fi
}

# Read-only checks against the real pacman (use inside an Arch/AllCrack VM).
# Arguments: none.
# Returns: 0. Side effects: records assertions; changes nothing on the system.
test_live_readonly() {
    echo "== live (read-only) =="
    new_state
    run_ac search git
    assert_rc 0 "live: search git"
    assert_out_has "Architecture:" "live: search shows architecture"
    run_ac search nonexistent-package-zzz
    assert_out_has "No packages found matching" "live: search with no results"
    run_ac info pacman
    assert_rc 0 "live: info pacman"
    assert_out_has "Package:        pacman" "live: info shows package"
    run_ac info nonexistent-package-zzz
    assert_rc 3 "live: info unknown package"
    run_ac list
    assert_rc 0 "live: list"
    assert_out_has "pacman" "live: list contains pacman"
    run_ac list pacman
    assert_rc 0 "live: list pacman"
}

# DESTRUCTIVE live checks: installs and removes "tree" and runs a full system
# update. Only run in a disposable VM, as root.
# Arguments: none.
# Returns: 0. Side effects: modifies the system.
test_live_mutating() {
    echo "== live (mutating, VM only) =="
    new_state
    run_ac update
    assert_rc 0 "live: update"
    run_ac install tree
    assert_rc 0 "live: install tree"
    run_ac install tree
    assert_out_has "Already installed" "live: second install is skipped"
    run_ac remove tree
    assert_rc 0 "live: remove tree"
    run_ac remove tree
    assert_rc 3 "live: removing a missing package"
    run_ac install nonexistent-package-zzz
    assert_rc 3 "live: install unknown package"
    run_ac upgrade
    assert_rc 0 "live: upgrade"
}

# Parses options, runs the selected tests and prints a summary.
# Arguments:
#   $@ - Optional: --live, --live-mutating, -h/--help.
# Returns: 0 if all assertions passed, 1 otherwise.
main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --live) LIVE=1 ;;
            --live-mutating) LIVE=1 MUTATING=1 ;;
            -h | --help)
                sed -n '2,13p' "${BASH_SOURCE[0]}"
                return 0
                ;;
            *)
                echo "unknown option: $arg" >&2
                return 2
                ;;
        esac
    done

    chmod +x "$MOCK_DIR"/* 2>/dev/null || true
    test_syntax
    test_function_comments
    test_version_and_help
    test_errors
    if [ "$LIVE" -eq 0 ]; then
        test_install
        test_remove
        test_search
        test_info
        test_list
        test_update_upgrade
        test_v01_compatibility
        test_info_failures
        test_query_failures
        test_transactions
        test_stderr_streaming
        test_interrupt
        test_no_bare_sy
    else
        test_live_readonly
        if [ "$MUTATING" -eq 1 ]; then
            if [ "$(id -u)" -ne 0 ]; then
                echo "--live-mutating must be run as root (in a VM)." >&2
                return 2
            fi
            test_live_mutating
        fi
    fi

    if [ -n "$MOCK_STATE" ]; then
        rm -rf -- "$MOCK_STATE"
    fi
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}

main "$@"
