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
SKIP=0
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

# A UTF-8 locale that exists on this machine, so the tests are not noisy about
# a missing en_US.UTF-8 (falls back to C.UTF-8, which ac treats the same way).
if locale -a 2>/dev/null | grep -qix 'en_US.utf-\?8'; then
    TEST_UTF8_LOCALE=en_US.UTF-8
else
    TEST_UTF8_LOCALE=C.UTF-8
fi

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
    mkdir -p "$MOCK_STATE/tmp" "$MOCK_STATE/db"
    export MOCK_STATE
    export MOCK_UID=0 MOCK_FAIL="" MOCK_DEP_BLOCK=0 MOCK_QUERY_FAIL="" MOCK_EMPTY_SYNC=0 MOCK_SLOW=""
    export MOCK_CONF_FAIL=0 MOCK_NET=ok
    export AC_SYSCONF="$MOCK_STATE/etc-ac.conf" AC_USERCONF="$MOCK_STATE/user-ac.conf"
    unset AC_COLOR AC_CONFIRM AC_PROGRESS NO_COLOR LC_ALL LC_CTYPE
    export LANG=$TEST_UTF8_LOCALE
    if [ "$LIVE" -eq 0 ]; then
        write_sample_log "$MOCK_STATE/pacman.log"
        export AC_PACMAN_LOG="$MOCK_STATE/pacman.log"
    else
        unset AC_PACMAN_LOG
    fi
    TEST_PACMAN="$MOCK_DIR/pacman"
}

# Writes the fixture pacman log used by the history tests: five valid package
# transactions (one with the older timestamp style) among lines ac must ignore.
# Arguments:
#   $1 - Path of the log file to create.
# Returns: 0. Side effects: creates the file.
write_sample_log() {
    cat >"$1" <<'LOG'
[2026-10-02T10:29:58+0000] [PACMAN] Running 'pacman -S firefox'
[2026-10-02T10:30:01+0000] [ALPM] transaction started
[2026-10-02T10:30:05+0000] [ALPM] installed firefox (147.0-1)
[2026-10-02T10:31:10+0000] [ALPM] installed git (2.47.0-1)
[2026-10-02T10:45:00+0000] [ALPM] removed nano (8.2-1)
[2026-10-02T11:00:00+0000] [ALPM] upgraded vim (9.0.0-1 -> 9.1.0-1)
[2026-10-02T11:00:01+0000] [ALPM-SCRIPTLET] ignored line
this line is garbage
[2026-10-02 11:05] [ALPM] reinstalled bash (5.2.037-1)
LOG
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
        TMPDIR="$MOCK_STATE/tmp" PATH="$MOCK_DIR:$PATH" AC_PACMAN="$TEST_PACMAN" with_timeout bash "$AC" "$@" >"$o" 2>"$e" </dev/null
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

# Tells whether a launcher exists that can reset SIGINT to its default action.
# A shell started as a background job (CI runners, `cmd &`) inherits SIGINT as
# "ignored", and bash cannot undo that, so the Ctrl+C tests need perl or python3.
# Arguments: none.
# Returns: 0 if one is available (and sets SIGDFL to the launcher words), 1
#   otherwise.
have_sigint_launcher() {
    if command -v perl >/dev/null 2>&1; then
        SIGDFL=(perl -e '$SIG{INT}="DEFAULT"; exec @ARGV or exit 127;' --)
    elif command -v python3 >/dev/null 2>&1; then
        SIGDFL=(python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])')
    else
        SIGDFL=()
        return 1
    fi
    return 0
}

# Runs a command under a time limit when `timeout` exists, so a hung ac or
# helper becomes a visible failure (status 124) instead of stalling the suite.
# Arguments:
#   $@ - The command and its arguments.
# Returns: the command's status (124 on timeout).
with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout --foreground "${TEST_TIMEOUT:-60}" "$@"
    else
        "$@"
    fi
}

# Tells whether python3 is available for JSON validation.
# Arguments: none.
# Returns: 0 if python3 exists, 1 otherwise.
have_python() {
    command -v python3 >/dev/null 2>&1
}

# Records a skipped assertion (a missing optional tool).
# Arguments:
#   $1 - Assertion label.
# Returns: 0. Side effects: increments SKIP and prints a line.
skip() {
    SKIP=$((SKIP + 1))
    printf '  SKIP  %s\n' "$1"
}

# Asserts that the last run's stdout is exactly one valid JSON document (and
# nothing else). Needs python3; skipped otherwise.
# Arguments:
#   $1 - Assertion label.
# Returns: 0.
assert_json() {
    if ! have_python; then skip "$1 (python3 missing)"; return 0; fi
    if printf '%s' "$OUT" | with_timeout python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        pass "$1"
    else
        fail "$1 (stdout is not valid JSON)"
    fi
}

# Reads a value from the last run's JSON stdout by a dotted path (object keys
# or list indexes), e.g. "results.0.name". Strings print raw; other values
# print as JSON (true, 4, null, [...]).
# Arguments:
#   $1 - Dotted path.
# Returns: prints the value (empty on error).
json_get() {
    printf '%s' "$OUT" | with_timeout python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d if isinstance(d, str) else json.dumps(d))
' "$1" 2>/dev/null
}

# Asserts that a JSON path in the last run's stdout has an expected value.
# Arguments:
#   $1 - Dotted path.
#   $2 - Expected value (as json_get prints it).
#   $3 - Assertion label.
# Returns: 0.
assert_json_eq() {
    local got
    if ! have_python; then skip "$3 (python3 missing)"; return 0; fi
    got=$(json_get "$1")
    if [ "$got" = "$2" ]; then pass "$3"; else fail "$3 (json $1 = '$got', expected '$2')"; fi
}

# Writes a configuration file for the tests.
# Arguments:
#   $1 - Path of the file.
#   $2 - File content.
# Returns: 0. Side effects: creates/overwrites the file.
write_conf() {
    printf '%b' "$2" >"$1"
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
    done < <(find "$ROOT/src" "$HERE" "$ROOT/install.sh" -type f \( -name '*.sh' -o -name ac -o -name pacman -o -name pacman-conf -o -name curl -o -name id \) 2>/dev/null | sort)
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
    done < <(find "$ROOT/src" "$HERE" "$ROOT/install.sh" -type f \( -name '*.sh' -o -name ac -o -name pacman -o -name pacman-conf -o -name curl -o -name id \) 2>/dev/null | sort)
}

# Tests `ac --version`, `-V`, `version` and `ac help` (works without pacman).
# Arguments: none.
# Returns: 0. Side effects: records assertions.
test_version_and_help() {
    echo "== version and help =="
    new_state
    run_ac --version
    assert_rc 0 "--version exits 0"
    assert_out_has "AllCrack Package Manager 0.3.0" "--version prints 0.3.0"
    run_ac -V
    assert_out_has "AllCrack Package Manager 0.3.0" "-V prints 0.3.0"
    run_ac version
    assert_out_has "AllCrack Package Manager 0.3.0" "'version' prints 0.3.0"
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
    assert_out_has "AllCrack Package Manager 0.3" "install shows banner"
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

# Tests the `show` alias and the `list --installed` / `--upgradable` options.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_show_and_list_options() {
    echo "== show / list --installed / list --upgradable =="
    new_state
    run_ac show git
    assert_rc 0 "show git -> rc 0"
    assert_out_has "Package:        git" "show behaves like info"
    run_ac show git --json
    assert_rc 0 "show --json -> rc 0"
    assert_json_eq name git "json: show name"
    run_ac show
    assert_rc 2 "show without a package -> rc 2"
    run_ac list --installed
    assert_rc 0 "list --installed -> rc 0"
    assert_out_has "Installed packages (4):" "list --installed equals list"
    run_ac list --upgradable
    assert_rc 0 "list --upgradable (none) -> rc 0"
    assert_out_has "All packages are up to date" "no upgradable packages message"
    printf 'git 2.46.0-1 -> 2.47.0-1\n' >"$MOCK_STATE/upgrades"
    run_ac list --upgradable
    assert_rc 0 "list --upgradable -> rc 0"
    assert_out_has "Upgradable packages (1):" "upgradable header"
    assert_out_has "2.46.0-1 -> 2.47.0-1" "upgradable versions"
    run_ac list --upgradable --json
    assert_rc 0 "list --upgradable --json -> rc 0"
    assert_json_eq count 1 "json: upgradable count"
    assert_json_eq packages.0.latest_version 2.47.0-1 "json: latest version"
    assert_called no '^-Sy' "list --upgradable never syncs"
    run_ac list --upgradable git
    assert_rc 2 "list --upgradable with a query -> rc 2"
    run_ac list --installed --upgradable
    assert_rc 2 "--installed with --upgradable -> rc 2"
    run_ac search git --upgradable
    assert_rc 2 "--upgradable on another command -> rc 2"
    run_ac info git --installed
    assert_rc 2 "--installed on another command -> rc 2"
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
        exec "${SIGDFL[@]}" bash "$AC" install chromium >"$o" 2>"$e" </dev/null
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

# Tests option parsing: --yes/-y/--json/--no-color in any position, the
# per-command support matrix, rejected combinations, --limit and "--".
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_v03_options() {
    local cmd
    echo "== v0.3 option parsing =="
    new_state
    run_ac install firefox --yes
    assert_rc 0 "install firefox --yes"
    assert_called yes '^-S --needed --noconfirm -- firefox$' "--yes after the package reaches pacman as --noconfirm"
    run_ac install --yes vim
    assert_called yes '^-S --needed --noconfirm -- vim$' "--yes before the package"
    run_ac install -y chromium
    assert_called yes '^-S --needed --noconfirm -- chromium$' "-y short option"
    run_ac --yes install docker
    assert_called yes '^-S --needed --noconfirm -- docker$' "--yes before the command"
    new_state
    run_ac install vim
    assert_called no 'noconfirm' "without --yes pacman keeps its confirmation prompt"
    run_ac --no-color list
    assert_rc 0 "--no-color before the command"
    run_ac list --no-color
    assert_rc 0 "--no-color after the command"
    run_ac search -- -x
    assert_rc 0 "'--' lets a search term start with a dash"
    assert_called yes '^-Ss -- -x$' "dash term reaches pacman after --"

    run_ac --unknown
    assert_rc 2 "ac --unknown -> rc 2"
    assert_err_has "invalid option '--unknown'" "ac --unknown message"
    run_ac install --unknown firefox
    assert_rc 2 "ac install --unknown -> rc 2"
    assert_err_has "invalid option '--unknown' for 'ac install'" "names the command"
    run_ac remove
    assert_rc 2 "ac remove without package -> rc 2"
    run_ac reinstall
    assert_rc 2 "ac reinstall without package -> rc 2"
    assert_err_has "ac reinstall <package>..." "reinstall usage line"
    run_ac status
    assert_rc 2 "ac status without package -> rc 2"
    run_ac --json
    assert_rc 2 "options without a command -> rc 2"
    assert_err_has "command required" "options without a command message"
    for cmd in list info search status history doctor; do
        run_ac "$cmd" --yes x
        assert_rc 2 "--yes rejected by '$cmd'"
        assert_err_has "option '--yes' is not supported by 'ac $cmd'" "--yes message for '$cmd'"
    done
    run_ac orphan --yes
    assert_rc 2 "--yes rejected by orphan"
    assert_err_has "always asks for confirmation" "orphan --yes explains why"
    run_ac orphan --remove --yes
    assert_rc 2 "--yes rejected by orphan --remove"
    run_ac clean --all --yes
    assert_rc 2 "clean --all --yes rejected"
    assert_err_has "cannot be combined" "clean --all --yes message"
    assert_called no '^-Scc' "clean --all --yes never reaches pacman"
    for cmd in install remove reinstall update upgrade clean; do
        run_ac "$cmd" --json x
        assert_rc 2 "--json rejected by '$cmd'"
    done
    run_ac orphan --remove --json
    assert_rc 2 "orphan --remove --json rejected"
    run_ac list --all
    assert_rc 2 "--all only valid for clean"
    run_ac list --remove
    assert_rc 2 "--remove only valid for orphan"
    run_ac list --limit 5
    assert_rc 2 "--limit only valid for history"
    run_ac history --limit 0
    assert_rc 2 "--limit 0 rejected"
    run_ac history --limit abc
    assert_rc 2 "--limit abc rejected"
    run_ac history --limit
    assert_rc 2 "--limit without value rejected"
    run_ac history -n 2
    assert_rc 0 "-n 2 accepted"
    run_ac history --limit=2
    assert_rc 0 "--limit=2 accepted"
    run_ac install --version
    assert_rc 2 "--version cannot be combined with a command"
    run_ac install -rf
    assert_rc 2 "dash-leading 'package names' are options -> rc 2"
    run_ac --help
    assert_out_has "--json" "help documents --json"
    assert_out_has "--yes" "help documents --yes"
    assert_out_has "reinstall <package>..." "help documents reinstall"
    assert_out_has "orphan" "help documents orphan"
    assert_out_has "history" "help documents history"
    assert_out_has "doctor" "help documents doctor"
    assert_out_has "--no-color" "help documents --no-color"
    assert_out_has "status <package>..." "help documents status"
    assert_out_has "clean" "help documents clean"
}

# Tests --yes/confirm handling for every command that supports it.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_yes_matrix() {
    echo "== --yes per command =="
    new_state
    run_ac install vim
    run_ac remove --yes vim
    assert_called yes '^-R --noconfirm -- vim$' "remove --yes"
    run_ac reinstall --yes git
    assert_called yes '^-S --noconfirm -- git$' "reinstall --yes"
    run_ac upgrade --yes
    assert_called yes '^-Syu --noconfirm$' "upgrade --yes"
    run_ac update -y
    assert_called yes '^-Syu --noconfirm$' "update -y"
    run_ac clean --yes
    assert_called yes '^-Sc --noconfirm$' "clean --yes"
    assert_called no '^-Sy( |$)' "no --yes path runs a bare -Sy"
    new_state
    run_ac upgrade
    assert_called yes '^-Syu$' "upgrade without --yes keeps pacman's prompt"
    assert_called no 'noconfirm' "no --noconfirm without --yes"
}

# Tests `ac reinstall`: success, multiple packages, validation, and failures.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_reinstall() {
    echo "== reinstall =="
    new_state
    run_ac reinstall git
    assert_rc 0 "reinstall git -> rc 0"
    assert_called yes '^-S -- git$' "reinstall uses pacman -S without --needed"
    assert_out_has "Reinstalling:" "reinstall header"
    assert_out_has ":: reinstalling git" "pacman output is shown"
    assert_out_has "✓ Reinstalled: git" "reinstall success line"
    run_ac reinstall git bash
    assert_called yes '^-S -- git bash$' "multi-package reinstall"
    run_ac reinstall firefox
    assert_rc 3 "reinstall of a package that is not installed -> rc 3"
    assert_err_has "Package not installed: firefox" "reinstall not-installed message"
    assert_err_has "sudo ac install" "reinstall suggests install"
    run_ac reinstall git nonexistent
    assert_rc 3 "one missing package aborts the whole reinstall"
    assert_called no '^-S -- git nonexistent' "nothing reinstalled when a name is missing"
    run_ac reinstall ac-localpkg
    assert_rc 3 "installed package missing from the repositories -> rc 3"
    assert_err_has "Package not found: ac-localpkg" "pacman's not-found is reported"
    MOCK_UID=1000 run_ac reinstall git
    assert_rc 4 "non-root reinstall -> rc 4"
    assert_err_has "sudo ac reinstall git" "non-root reinstall suggests sudo"
    MOCK_FAIL=network run_ac reinstall git
    assert_rc 5 "reinstall network failure -> rc 5"
    assert_err_has "✗ Failed: git" "reinstall failure line"
    MOCK_FAIL=lock run_ac reinstall git
    assert_rc 6 "reinstall database lock -> rc 6"
    MOCK_FAIL=deps run_ac reinstall git
    assert_rc 7 "reinstall dependency failure -> rc 7"
    assert_no_tempfiles "reinstall leaves no temp files"
}

# Tests `ac clean`: pacman -Sc / -Scc, validation and failures.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_clean() {
    echo "== clean =="
    new_state
    run_ac clean
    assert_rc 0 "clean -> rc 0"
    assert_called yes '^-Sc$' "clean runs pacman -Sc"
    assert_out_has "✓ Package cache cleaned." "clean success line"
    run_ac clean --all
    assert_rc 0 "clean --all -> rc 0"
    assert_called yes '^-Scc$' "clean --all runs pacman -Scc"
    assert_out_has "pacman asks first" "clean --all says pacman asks for confirmation"
    run_ac clean extra
    assert_rc 2 "clean with arguments -> rc 2"
    MOCK_UID=1000 run_ac clean
    assert_rc 4 "non-root clean -> rc 4"
    MOCK_FAIL=lock run_ac clean
    assert_rc 6 "clean database lock -> rc 6"
    assert_err_has "ac: cache cleaning failed" "clean failure message"
    MOCK_FAIL=unknown run_ac clean
    assert_rc 1 "clean unexpected failure keeps pacman's status"
    assert_no_tempfiles "clean leaves no temp files"
}

# Tests `ac orphan`: listing never removes, --remove asks pacman, failures.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_orphan() {
    echo "== orphan =="
    new_state
    run_ac orphan
    assert_rc 0 "orphan with none -> rc 0"
    assert_out_has "No orphan packages found." "no-orphans message"
    printf 'libold 1.0-1\nlibunused 2.0-1\n' >>"$MOCK_STATE/installed"
    printf 'libold\nlibunused\n' >"$MOCK_STATE/orphans"
    run_ac orphan
    assert_rc 0 "orphan lists -> rc 0"
    assert_out_has "Orphan packages:" "orphan header"
    assert_out_has "  libold" "orphan lists libold"
    assert_out_has "  libunused" "orphan lists libunused"
    assert_out_has "sudo ac orphan --remove" "orphan shows how to remove"
    assert_called yes '^-Qdtq$' "the analysis is done by pacman -Qdtq"
    assert_called no '^-R' "plain 'ac orphan' never removes anything"
    MOCK_UID=1000 run_ac orphan
    assert_rc 0 "orphan listing works without root"
    MOCK_UID=1000 run_ac orphan --remove
    assert_rc 4 "orphan --remove needs root -> rc 4"
    assert_called no '^-R' "non-root --remove never reaches pacman"
    run_ac orphan --remove
    assert_rc 0 "orphan --remove -> rc 0"
    assert_called yes '^-Rs -- libold libunused$' "removal goes through pacman -Rs"
    assert_called no 'noconfirm' "orphan removal never auto-confirms"
    assert_out_has "Orphan packages to remove:" "removal shows the list first"
    assert_out_has "✓ Removed 2 orphan package(s)." "removal success line"
    run_ac orphan
    assert_out_has "No orphan packages found." "orphans are gone afterwards"
    run_ac orphan --remove
    assert_rc 0 "orphan --remove with none -> rc 0"
    assert_out_has "Nothing to remove." "nothing-to-remove message"
    printf 'libold 1.0-1\n' >>"$MOCK_STATE/installed"
    printf 'libold\n' >"$MOCK_STATE/orphans"
    MOCK_DEP_BLOCK=1 run_ac orphan --remove
    assert_rc 7 "orphan removal blocked by pacman -> rc 7"
    assert_err_has "✗ Failed: orphan removal" "orphan removal failure line"
    MOCK_QUERY_FAIL=local run_ac orphan
    assert_rc 1 "orphan query failure -> rc 1"
    assert_err_has "unable to query package database" "orphan query failure message"
    assert_out_lacks "No orphan" "query failure is not 'no orphans'"
    run_ac orphan extra
    assert_rc 2 "orphan with arguments -> rc 2"
    assert_no_tempfiles "orphan leaves no temp files"
}

# Tests `ac history`: parsing pacman's log, limits, empty and unreadable logs.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_history() {
    echo "== history =="
    new_state
    run_ac history
    assert_rc 0 "history -> rc 0"
    assert_out_has "Recent package transactions:" "history header"
    assert_out_has "2026-10-02 10:30  Installed firefox (147.0-1)" "installed entry"
    assert_out_has "2026-10-02 10:31  Installed git (2.47.0-1)" "second installed entry"
    assert_out_has "2026-10-02 10:45  Removed nano (8.2-1)" "removed entry"
    assert_out_has "Upgraded vim (9.0.0-1 -> 9.1.0-1)" "upgraded entry"
    assert_out_has "2026-10-02 11:05  Reinstalled bash (5.2.037-1)" "older timestamp style"
    assert_out_lacks "ignored line" "non-package log lines are ignored"
    assert_out_lacks "garbage" "garbage lines are ignored"
    run_ac history -n 2
    assert_out_has "Reinstalled bash" "limit keeps the newest entries"
    assert_out_has "Upgraded vim" "limit keeps the second newest"
    assert_out_lacks "Installed firefox" "limit drops older entries"
    run_ac history --limit=1
    assert_out_lacks "Upgraded vim" "--limit=1 shows one entry"
    printf '[2026-10-02T10:00:00+0000] [PACMAN] only noise\n' >"$AC_PACMAN_LOG"
    run_ac history
    assert_rc 0 "log without package lines -> rc 0"
    assert_out_has "No matching package transactions found" "empty history message"
    if [ "$(id -u)" -ne 0 ]; then
        write_sample_log "$AC_PACMAN_LOG"
        chmod 000 "$AC_PACMAN_LOG"
        run_ac history
        assert_rc 4 "unreadable log (permission problem) -> rc 4"
        assert_err_has "unable to read the package transaction log" "unreadable log headline"
        assert_err_has "Permission denied" "unreadable log shows the real reason"
        chmod 644 "$AC_PACMAN_LOG"
    else
        skip "unreadable log (running as root)"
    fi
    run_ac history extra
    assert_rc 2 "history with arguments -> rc 2"
    assert_no_tempfiles "history leaves no temp files"
}

# Tests backend capability detection: history is unavailable without a log,
# everything else keeps working.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_capabilities() {
    echo "== backend capabilities =="
    new_state
    rm -f "$AC_PACMAN_LOG"
    run_ac history
    assert_rc 9 "history without a pacman log -> rc 9 (unsupported)"
    assert_err_has "'history' is not available with this package-manager backend" "unsupported message"
    assert_err_has "pacman log was not found" "unsupported reason"
    run_ac history --json
    assert_rc 9 "unsupported in JSON mode -> rc 9"
    assert_json "unsupported error is valid JSON"
    assert_json_eq error.type unsupported "unsupported error type"
    run_ac list
    assert_rc 0 "other commands are unaffected"
    run_ac doctor
    assert_rc 0 "doctor does not need the log"
}

# Tests `ac status`: installed, available, not found, local-only and failures.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_status() {
    echo "== status =="
    new_state
    run_ac status git
    assert_rc 0 "status git -> rc 0"
    assert_out_has "Package:        git" "status shows the package"
    assert_out_has "Status:         installed" "installed state"
    assert_out_has "Version:        2.47.0-1" "installed version"
    assert_out_has "Repository:     extra" "repository"
    run_ac status firefox
    assert_rc 0 "status of an available package -> rc 0"
    assert_out_has "Status:         available" "available state"
    assert_out_has "Version:        147.0-1" "repository version"
    run_ac status nonexistent-package
    assert_rc 3 "status of an unknown package -> rc 3"
    assert_out_has "Status:         not-available" "not-available state"
    run_ac status ac-localpkg
    assert_rc 0 "status of a local-only package -> rc 0"
    assert_out_has "Status:         installed" "local-only package is installed"
    assert_out_has "Repository:     local" "local-only repository"
    run_ac status git firefox nonexistent-package
    assert_rc 3 "several packages, one unknown -> rc 3"
    assert_out_has "Status:         installed" "several: installed"
    assert_out_has "Status:         available" "several: available"
    MOCK_QUERY_FAIL=sync run_ac status firefox
    assert_rc 1 "status with a repository failure -> rc 1"
    assert_err_has "unable to query package database" "status failure message"
    assert_out_lacks "not-available" "failure is not 'not-available'"
    MOCK_QUERY_FAIL=local run_ac status git
    assert_rc 1 "status with a local database failure -> rc 1"
    assert_no_tempfiles "status leaves no temp files"
}

# Tests the improved `ac info` output (download size, optional dependencies).
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_info_v03() {
    echo "== info (v0.3 fields) =="
    new_state
    run_ac info firefox
    assert_out_has "Download Size:  80.00 MiB" "info shows the download size"
    assert_out_has "Optional Deps:" "info shows optional dependencies"
    assert_out_has "  none-test: first optional dep" "first optional dependency"
    assert_out_has "  other-test: continuation line" "continuation line kept as its own entry"
    run_ac info ac-localpkg
    assert_out_lacks "Download Size" "no invented download size for local-only packages"
    run_ac info evilpkg
    assert_out_lacks $'\033' "escape sequences in descriptions are stripped"
    assert_out_has "Evil [31mred[0m description" "the visible text is kept"
}

# Tests --json for every command that supports it: stdout must be exactly one
# valid JSON document, with a consistent error object on failure.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_json() {
    echo "== --json =="
    new_state
    run_ac info firefox --json
    assert_rc 0 "info --json -> rc 0"
    assert_json "info --json is valid JSON only"
    assert_json_eq name firefox "info name"
    assert_json_eq version 147.0-1 "info version"
    assert_json_eq repository extra "info repository"
    assert_json_eq architecture x86_64 "info architecture"
    assert_json_eq installed false "info installed=false"
    assert_json_eq dependencies.0 dbus-glibc "info dependencies array"
    assert_json_eq optional_dependencies.1 "other-test: continuation line" "info optional dependencies array"
    assert_json_eq download_size "80.00 MiB" "info download size"
    run_ac --json info git
    assert_json_eq installed true "installed=true (option before command)"
    assert_json_eq installed_version 2.47.0-1 "installed version"
    run_ac info firefox git --json
    assert_json "info with several packages is valid JSON"
    assert_json_eq 0.name firefox "several: first"
    assert_json_eq 1.name git "several: second"
    run_ac info nonexistent-package --json
    assert_rc 3 "info --json missing package -> rc 3"
    assert_json "missing package error is valid JSON"
    assert_json_eq error.type not-found "error type"
    assert_json_eq error.exit_code 3 "error exit code"
    assert_json_eq error.message "Package not found: nonexistent-package" "error message"
    assert_err_has "Package not found: nonexistent-package" "human error still goes to stderr"
    MOCK_QUERY_FAIL=sync run_ac info firefox --json
    assert_rc 1 "info --json database failure -> rc 1"
    assert_json "database failure error is valid JSON"
    assert_json_eq error.type repository-error "repository failure type"
    if have_python && [[ $(json_get error.reason) == *"database is incorrect version"* ]]; then
        pass "database failure reason is pacman's own text"
    elif have_python; then
        fail "database failure reason is pacman's own text"
    fi
    run_ac info --json
    assert_rc 2 "usage error in JSON mode -> rc 2"
    assert_json "usage error is valid JSON"
    assert_json_eq error.type usage "usage error type"
    run_ac install --json vim
    assert_rc 2 "--json on a mutating command -> rc 2"
    assert_json "unsupported-option error is valid JSON"

    run_ac search firefox --json
    assert_json "search --json is valid JSON only"
    assert_json_eq count 1 "search count"
    assert_json_eq results.0.name firefox "search result name"
    assert_json_eq results.0.architecture x86_64 "search result architecture"
    assert_json_eq results.0.installed false "search result installed flag"
    assert_json_eq query.0 firefox "search echoes the query"
    run_ac search git --json
    assert_json_eq results.0.installed true "installed search result"
    MOCK_EMPTY_SYNC=1 run_ac search firefox --json
    assert_rc 0 "empty search --json -> rc 0"
    assert_json "empty search with a pacman warning keeps stdout pure JSON"
    assert_json_eq count 0 "empty search count"
    assert_err_has "warning: database file" "pacman's warning stays on stderr"
    run_ac search evilpkg --json
    assert_json "search with control characters is valid JSON"
    assert_json_eq results.0.description $'Evil \033[31mred\033[0m description' "control characters survive JSON escaping"
    MOCK_QUERY_FAIL=sync run_ac search firefox --json
    assert_rc 1 "search --json failure -> rc 1"
    assert_json_eq error.type repository-error "search failure error type"

    run_ac list --json
    assert_json "list --json is valid JSON only"
    assert_json_eq count 4 "list count"
    assert_json_eq packages.2.name git "list package"
    run_ac list git --json
    assert_json_eq count 1 "filtered list count"

    run_ac status git --json
    assert_json "status --json is valid JSON"
    assert_json_eq status installed "status installed"
    run_ac status git firefox nonexistent --json
    assert_rc 3 "status --json with a missing package -> rc 3"
    assert_json "status array is valid JSON"
    assert_json_eq 2.status not-available "status not-available entry"

    run_ac orphan --json
    assert_json "orphan --json is valid JSON"
    assert_json_eq count 0 "orphan count"
    printf 'libold 1.0-1\n' >>"$MOCK_STATE/installed"
    printf 'libold\n' >"$MOCK_STATE/orphans"
    run_ac orphan --json
    assert_json_eq orphans.0 libold "orphan names"
    assert_called no '^-R' "orphan --json never removes"

    run_ac history --json
    assert_json "history --json is valid JSON"
    assert_json_eq count 5 "history count"
    assert_json_eq transactions.0.action installed "history action"
    assert_json_eq transactions.0.package firefox "history package"
    assert_json_eq transactions.0.date 2026-10-02 "history date"
    run_ac history --json -n 2
    assert_json_eq count 2 "history --json honors --limit"

    run_ac doctor --json
    assert_json "doctor --json is valid JSON"
    assert_json_eq healthy true "doctor healthy"
    assert_json_eq checks.0.name pacman "doctor first check"
    run_ac version --json
    assert_json "version --json is valid JSON"
    assert_json_eq version 0.3.0 "version json"
    assert_no_tempfiles "JSON commands leave no temp files"
}

# Unit-tests the JSON string escaper with awkward text (quotes, backslashes,
# newlines, control characters, UTF-8) by parsing the result with python.
# Arguments: none.
# Returns: 0. Side effects: records assertions.
test_json_escape() {
    local text quoted
    echo "== JSON escaping =="
    if ! have_python; then skip "JSON escaping (python3 missing)"; return 0; fi
    # shellcheck source=/dev/null
    . "$ROOT/src/lib/json.sh"
    for text in 'plain' 'say "hi"' 'back\slash' $'line1\nline2' $'tab\there' $'bell\a' $'esc\033[0m' 'héllo ✓ 日本' '' '\u0041 not an escape' '{"a":[1,2]}'; do
        json_quote quoted "$text"
        if S=$text python3 -c 'import json,os,sys; sys.exit(0 if json.loads(sys.argv[1]) == os.environ["S"] else 1)' "$quoted"; then
            pass "JSON round trip: ${text//[[:cntrl:]]/?}"
        else
            fail "JSON round trip: ${text//[[:cntrl:]]/?} -> $quoted"
        fi
    done
}

# Tests the doctor command: healthy system, each kind of failure, warnings,
# missing pacman, and that it never modifies anything.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_doctor() {
    echo "== doctor =="
    new_state
    run_ac doctor
    assert_rc 0 "doctor on a healthy system -> rc 0"
    assert_out_has "AllCrack Package Manager Doctor" "doctor title"
    assert_out_has "✓ pacman" "pacman check"
    assert_out_has "✓ package database" "package database check"
    assert_out_has "✓ sync databases" "sync database check"
    assert_out_has "✓ database lock" "lock check"
    assert_out_has "✓ pacman configuration" "pacman configuration check"
    assert_out_has "✓ permissions" "permissions check"
    assert_out_has "✓ network" "network check"
    assert_out_has "✓ ac configuration" "ac configuration check"
    assert_out_has "System package management looks healthy." "healthy summary"
    assert_called no '^-(S |Sy|Sc|R)' "doctor never modifies the system"
    if grep -q -- '--proto =http,https' "$MOCK_STATE/curl.log"; then pass "network check restricts curl to http(s)"; else fail "network check restricts curl to http(s)"; fi

    MOCK_EMPTY_SYNC=1 run_ac doctor
    assert_rc 1 "missing sync databases -> rc 1"
    assert_out_has "✗ sync databases" "sync failure line"
    assert_out_has "Reason: no synchronized repository data" "sync failure reason"
    assert_out_lacks "looks healthy" "never healthy while a check failed"
    assert_out_has "Problems found: 1 check(s) failed" "failure summary"
    MOCK_QUERY_FAIL=local run_ac doctor
    assert_rc 1 "unreadable local database -> rc 1"
    assert_out_has "✗ package database" "local database failure line"
    assert_out_has "Reason: failed to initialize alpm library" "pacman's reason is shown"
    touch "$MOCK_STATE/db/db.lck"
    run_ac doctor
    assert_rc 1 "database lock present -> rc 1"
    assert_out_has "✗ database lock" "lock failure line"
    assert_out_has "db.lck exists" "lock reason names the file"
    rm -f "$MOCK_STATE/db/db.lck"
    MOCK_CONF_FAIL=1 run_ac doctor
    assert_rc 1 "broken pacman configuration -> rc 1"
    assert_out_has "✗ pacman configuration" "configuration failure line"
    assert_out_has "directive 'Bogus'" "configuration reason is pacman-conf's own"
    MOCK_NET=fail run_ac doctor
    assert_rc 1 "unreachable mirror -> rc 1"
    assert_out_has "✗ network" "network failure line"
    assert_out_has "Could not resolve host" "network reason is curl's own"
    MOCK_UID=1000 run_ac doctor
    assert_rc 0 "running without root is only a warning -> rc 0"
    assert_out_has "! permissions" "permissions warning"
    assert_out_has "looks healthy (1 warning(s) above)" "healthy with a warning"
    TEST_PACMAN=/nonexistent/pacman run_ac doctor
    assert_rc 1 "pacman missing -> rc 1"
    assert_out_has "✗ pacman" "missing pacman line"
    assert_out_has "- package database" "other checks are skipped"
    assert_out_lacks "looks healthy" "missing pacman is never healthy"
    write_conf "$AC_SYSCONF" 'bogus = 1\n'
    run_ac doctor
    assert_rc 0 "an invalid ac setting is a warning -> rc 0"
    assert_out_has "! ac configuration" "ac configuration warning"
    assert_out_has "unknown setting 'bogus'" "warning names the setting"
    rm -f "$AC_SYSCONF"
    run_ac doctor extra
    assert_rc 2 "doctor with arguments -> rc 2"
    MOCK_EMPTY_SYNC=1 run_ac doctor --json
    assert_rc 1 "doctor --json failure -> rc 1"
    assert_json "unhealthy doctor --json is valid JSON"
    assert_json_eq healthy false "doctor healthy=false"
    assert_json_eq failures 1 "doctor failure count"
    assert_no_tempfiles "doctor leaves no temp files"
}

# Tests the configuration files, environment overrides and precedence.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_config() {
    local esc=$'\033'
    echo "== configuration =="
    new_state
    run_ac search firefox
    assert_out_lacks "$esc" "default output in a non-terminal has no colors"
    write_conf "$AC_SYSCONF" 'color = always\n'
    run_ac search firefox
    assert_out_has "$esc[1m" "system config: color=always"
    run_ac --no-color search firefox
    assert_out_lacks "$esc" "--no-color overrides the configuration"
    NO_COLOR=1 run_ac search firefox
    assert_out_lacks "$esc" "NO_COLOR disables color"
    AC_COLOR=never run_ac search firefox
    assert_out_lacks "$esc" "AC_COLOR overrides the file (never)"
    write_conf "$AC_SYSCONF" 'color = never\n'
    AC_COLOR=always run_ac search firefox
    assert_out_has "$esc[1m" "AC_COLOR overrides the file (always)"
    write_conf "$AC_USERCONF" 'color = always\n'
    run_ac search firefox
    assert_out_has "$esc[1m" "user config overrides the system config"
    rm -f "$AC_USERCONF"
    write_conf "$AC_SYSCONF" '# comment\n\n   color   =   "always"   # trailing comment\n'
    run_ac search firefox
    assert_out_has "$esc[1m" "comments, blank lines, spaces and quotes are handled"
    assert_err_lacks "Warning" "a valid file produces no warnings"

    write_conf "$AC_SYSCONF" 'bogus = 1\ncolor = always\njust some text\ncolor = purple\n'
    run_ac search firefox
    assert_rc 0 "invalid settings do not stop ac"
    assert_err_has "unknown setting 'bogus'" "unknown key warning"
    assert_err_has "expected 'key = value'" "malformed line warning"
    assert_err_has "invalid value 'purple' for 'color'" "invalid value warning"
    assert_out_has "$esc[1m" "valid settings in the same file still apply"

    write_conf "$AC_SYSCONF" 'confirm = false\n'
    run_ac install vim
    assert_called yes '^-S --needed --noconfirm -- vim$' "confirm=false auto-confirms install"
    run_ac upgrade
    assert_called yes '^-Syu --noconfirm$' "confirm=false auto-confirms upgrade"
    run_ac list
    assert_rc 0 "confirm=false does not affect read-only commands"
    printf 'libold 1.0-1\n' >>"$MOCK_STATE/installed"
    printf 'libold\n' >"$MOCK_STATE/orphans"
    run_ac orphan --remove
    assert_called yes '^-Rs -- libold$' "orphan removal still runs"
    assert_called no '^-Rs --noconfirm' "confirm=false never auto-confirms orphan removal"
    run_ac clean --all
    assert_called yes '^-Scc$' "clean --all still runs"
    assert_called no '^-Scc --noconfirm' "confirm=false never auto-confirms clean --all"
    AC_CONFIRM=true run_ac remove vim
    assert_called yes '^-R -- vim$' "AC_CONFIRM=true overrides the file"
    write_conf "$AC_SYSCONF" 'confirm = true\n'
    run_ac install chromium
    assert_called yes '^-S --needed -- chromium$' "confirm=true keeps pacman's prompt"
    AC_CONFIRM=no run_ac install docker
    assert_called yes '^-S --needed --noconfirm -- docker$' "AC_CONFIRM=no (false) auto-confirms"

    rm -f "$AC_SYSCONF"
    run_ac upgrade
    assert_out_has "→ Checking for updates..." "progress lines are shown by default"
    write_conf "$AC_SYSCONF" 'progress = false\n'
    run_ac upgrade
    assert_out_lacks "Checking for updates" "progress=false hides progress lines"
    assert_out_has "✓ System upgrade complete." "results are still shown"
    AC_PROGRESS=true run_ac upgrade
    assert_out_has "Checking for updates" "AC_PROGRESS overrides the file"

    write_conf "$AC_SYSCONF" "color = \$(touch $MOCK_STATE/pwned)\nprogress = \`touch $MOCK_STATE/pwned\`\n"
    run_ac list
    if [ ! -e "$MOCK_STATE/pwned" ]; then pass "config values are never executed"; else fail "config values are never executed"; fi
    assert_err_has "invalid value" "injection attempts are reported as invalid values"
    if [ "$(id -u)" -ne 0 ]; then
        write_conf "$AC_SYSCONF" 'color = always\n'
        chmod 000 "$AC_SYSCONF"
        run_ac list
        assert_rc 0 "an unreadable config does not stop ac"
        assert_err_has "cannot be read" "unreadable config warning"
        chmod 644 "$AC_SYSCONF"
    else
        skip "unreadable config (running as root)"
    fi
}

# Tests the output layer: symbols, ASCII fallback, failure lines on stderr.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_output_style() {
    echo "== output style =="
    new_state
    run_ac install vim
    assert_out_has "✓ Installed: vim" "unicode success line"
    run_ac remove vim
    assert_out_has "✓ Removed: vim" "remove success line"
    run_ac upgrade
    assert_out_has "→ Checking for updates..." "unicode progress line"
    MOCK_FAIL=network run_ac install vim
    assert_err_has "✗ Failed: vim" "failure line on stderr"
    assert_out_lacks "Failed" "failure line is not on stdout"
    LC_ALL=C run_ac install chromium
    assert_out_has "[ok] Installed: chromium" "ASCII fallback in a non-UTF-8 locale"
    LC_ALL=C run_ac upgrade
    assert_out_has "-> Checking for updates..." "ASCII progress"
    LC_ALL=C MOCK_FAIL=network run_ac install docker
    assert_err_has "[x] Failed: docker" "ASCII failure line"
}

# Tests the security-relevant behaviour: hostile package names and search
# strings are passed to pacman literally and never executed, option-looking
# names are rejected, and terminal escapes from data are neutralised.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_security() {
    local evil1 evil2 evil3
    echo "== shell safety =="
    new_state
    evil1="\$(touch $MOCK_STATE/pwned1)"
    evil2="x;touch $MOCK_STATE/pwned2;"
    evil3="\`touch $MOCK_STATE/pwned3\`"
    run_ac search "$evil1"
    assert_rc 0 "search with \$(...) is just a search"
    run_ac info "$evil1" "$evil2" "$evil3"
    assert_rc 3 "info with shell metacharacters -> not found"
    assert_err_has "Package not found: $evil2" "the name is reported literally"
    run_ac install "$evil1" "$evil2" "$evil3"
    assert_rc 3 "install with shell metacharacters -> not found"
    run_ac status "$evil2"
    assert_rc 3 "status with shell metacharacters -> not found"
    run_ac remove "$evil3"
    assert_rc 3 "remove with shell metacharacters -> not installed"
    run_ac reinstall "$evil1"
    assert_rc 3 "reinstall with shell metacharacters -> not installed"
    if [ ! -e "$MOCK_STATE/pwned1" ] && [ ! -e "$MOCK_STATE/pwned2" ] && [ ! -e "$MOCK_STATE/pwned3" ]; then
        pass "no injected command was executed"
    else
        fail "an injected command was executed"
    fi
    if grep -qF -- "-Ss -- $evil1" "$MOCK_STATE/calls.log"; then pass "pacman received the search string literally"; else fail "pacman received the search string literally"; fi
    run_ac install "two words"
    assert_rc 3 "a name with a space stays one argument"
    assert_err_has "Package not found: two words" "space name reported literally"
    run_ac info $'bad\nname'
    assert_rc 2 "a name with a newline is rejected as an invalid argument"
    assert_err_has "control characters" "control-character message"
    run_ac install $'bad\033name'
    assert_rc 2 "a name with an escape character is rejected"
    assert_called no 'bad' "rejected names never reach pacman"
    run_ac install -rf /
    assert_rc 2 "option-looking names are rejected"

    printf '[2026-10-02T12:00:00+0000] [ALPM] installed evil\033[2Jpkg (1.0-1)\n' >"$AC_PACMAN_LOG"
    run_ac history
    assert_out_lacks $'\033' "escape sequences from the log are stripped (text)"
    assert_out_has "Installed evil[2Jpkg" "visible text of the log entry is kept"
    run_ac history --json
    assert_json "log entry with control characters yields valid JSON"
    assert_json_eq transactions.0.package $'evil\033[2Jpkg' "control characters preserved by JSON escaping"
    assert_no_tempfiles "hostile input leaves no temp files"
}

# Simulates Ctrl+C for a command: sends SIGINT to ac's process group while
# pacman is busy and checks status, messages and temp-file cleanup.
# Arguments:
#   $1 - Label for the assertions.
#   $2... - ac arguments (MOCK_SLOW=hang is set for the run).
# Returns: 0. Side effects: records assertions (mock mode only).
interrupt_case() {
    local label=$1 pid o e
    shift
    new_state
    o="$MOCK_STATE/int.out"
    e="$MOCK_STATE/int.err"
    set -m
    (
        export PATH="$MOCK_DIR:$PATH" AC_PACMAN="$TEST_PACMAN" TMPDIR="$MOCK_STATE/tmp" MOCK_SLOW=hang
        exec "${SIGDFL[@]}" bash "$AC" "$@" >"$o" 2>"$e" </dev/null
    ) &
    pid=$!
    sleep 1
    kill -INT -- "-$pid"
    wait_for_exit "$pid" 5
    set +m
    OUT=$(<"$o")
    ERR=$(<"$e")
    assert_rc 130 "$label: Ctrl+C -> rc 130"
    assert_err_has "ac: interrupted" "$label: interruption reported"
    assert_no_tempfiles "$label: no temp files left"
}

# Runs one of the Ctrl+C test groups, or skips it when no launcher can reset an
# inherited "SIGINT ignored" state (see have_sigint_launcher).
# Arguments:
#   $1 - Name of the test function.
# Returns: 0. Side effects: records assertions or one skip.
interrupt_guard() {
    if have_sigint_launcher; then
        "$1"
    else
        skip "$1 (needs perl or python3 to reset SIGINT)"
    fi
}

# Regression test: the Ctrl+C tests must work even when the whole suite was
# started with SIGINT ignored (as happens for background jobs and many CI
# runners). Re-runs the transaction interrupt test from such a shell.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_interrupt_when_sigint_ignored() {
    local out
    echo "== Ctrl+C with SIGINT ignored by the parent =="
    have_sigint_launcher || { skip "SIGINT-ignored run (needs perl or python3)"; return 0; }
    out=$(TEST_TIMEOUT=240 with_timeout bash -c 'trap "" INT; exec bash "$0" --only-interrupt' "$ROOT/tests/run_tests.sh" 2>&1 </dev/null)
    if [[ $out == *"0 failed"* ]]; then
        pass "Ctrl+C tests pass when SIGINT is inherited as ignored"
    else
        fail "Ctrl+C tests fail when SIGINT is inherited as ignored: ${out##*$'\n'}"
    fi
}

# Tests Ctrl+C handling for the v0.3 commands that run transactions.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_interrupt_commands() {
    echo "== Ctrl+C for v0.3 commands =="
    interrupt_case "reinstall" reinstall git
    interrupt_case "upgrade --yes" upgrade --yes
    interrupt_case "install --yes" install --yes chromium
}

# Tests the error categories: each failure class gets its own type, in text
# and in the JSON error object, and none is reported as "not found".
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_error_types() {
    echo "== error categories =="
    new_state
    MOCK_QUERY_FAIL=sync run_ac info firefox --json
    assert_json_eq error.type repository-error "repository database failure -> repository-error"
    MOCK_QUERY_FAIL=local run_ac info ac-localpkg --json
    assert_json_eq error.type database-error "local database failure -> database-error"
    MOCK_QUERY_FAIL=perm run_ac info firefox --json
    assert_json_eq error.type permission "permission problem -> permission"
    assert_rc 4 "permission problem exit status"
    run_ac install --json
    assert_json_eq error.type usage "invalid arguments -> usage"
    run_ac frobnicate --json
    assert_rc 2 "invalid command -> rc 2"
    assert_json_eq error.type usage "invalid command -> usage"
    TEST_PACMAN=/nonexistent/pacman run_ac info git --json
    assert_rc 127 "missing backend -> rc 127"
    assert_json_eq error.type backend-unavailable "missing backend type"
    MOCK_UID=1000 run_ac install git
    assert_err_has "permission denied" "non-root message"
    MOCK_FAIL=unknown run_ac install firefox
    assert_err_has "ac: package installation failed: pacman exited with status 1." "unexpected failure is a backend error"
    assert_no_tempfiles "error paths leave no temp files"
}

# Tests `ac status` update detection: current, update available, unknown.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_status_updates() {
    echo "== status: update detection =="
    new_state
    run_ac status git
    assert_out_has "Update:         current" "an installed package without updates is current"
    printf 'git 2.46.0-1 -> 2.47.0-1\n' >"$MOCK_STATE/upgrades"
    run_ac status git
    assert_rc 0 "status with an update available -> rc 0"
    assert_out_has "Update:         available (2.47.0-1 -> 2.47.0-1)" "update available is shown"
    run_ac status firefox
    assert_out_lacks "Update:" "a package that is not installed has no update line"
    run_ac status git bash --json
    assert_json_eq 0.update available "json: update available"
    assert_json_eq 0.latest_version 2.47.0-1 "json: latest version"
    assert_json_eq 1.update current "json: current"
    assert_json_eq 1.latest_version null "json: no latest version when current"
    run_ac status firefox --json
    assert_json_eq update null "json: update is null for a package that is not installed"
    : >"$MOCK_STATE/calls.log"
    run_ac status git bash ac-localpkg
    if [ "$(grep -c '^-Qu$' "$MOCK_STATE/calls.log")" -eq 1 ]; then pass "the upgrade list is queried once for several packages"; else fail "the upgrade list is queried once for several packages"; fi
    assert_called no '^-Sy' "status never refreshes the databases"
    MOCK_QUERY_FAIL=local run_ac status git
    assert_rc 1 "status with a failing local database -> rc 1"
}

# Tests that `ac info` shows license and upstream URL only when pacman has
# them, in text and JSON.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_info_license() {
    echo "== info: license and upstream =="
    new_state
    run_ac info firefox
    assert_out_has "License:        MPL-2.0, GPL-2.0-or-later" "license shown"
    assert_out_has "URL:            https://example.org/firefox" "upstream URL shown"
    run_ac info ac-localpkg
    assert_out_lacks "License:" "no invented license for a package without one"
    assert_out_lacks "URL:" "no invented URL for a package without one"
    run_ac info firefox --json
    assert_json_eq licenses.1 GPL-2.0-or-later "json licenses"
    assert_json_eq url https://example.org/firefox "json url"
    run_ac info ac-localpkg --json
    assert_json_eq url null "json url is null when unknown"
    assert_json_eq licenses "[]" "json licenses is empty when unknown"
}

# Tests the extra doctor diagnostics: pacman/libalpm versions, architecture
# and the functional backend-compatibility probes.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_doctor_backend() {
    echo "== doctor: backend detection =="
    new_state
    run_ac doctor
    assert_out_has "✓ pacman: 7.0.0" "pacman version"
    assert_out_has "✓ libalpm: 15.0.0" "libalpm version"
    assert_out_has "✓ architecture: $(uname -m)" "architecture detected"
    assert_out_has "✓ backend compatibility: read-only query operations verified (pacman 7.0.0, libalpm 15.0.0)" "compatibility verified by probes"
    assert_out_has "Backend appears compatible." "compatibility summary"
    for probe in '-Q -- pacman' '-Si -- pacman' '-Qs -- \^pacman\$' '-Ss -- \^pacman\$' '-Qdtq' '-Qu'; do
        assert_called yes "^${probe}\$" "doctor probes: pacman $probe"
    done
    MOCK_VERSION=bad run_ac doctor
    assert_rc 1 "unreadable libalpm version -> rc 1"
    assert_out_has "✗ libalpm" "libalpm failure line"
    assert_out_has "Reason: libalpm's version could not be determined" "libalpm failure reason"
    assert_out_lacks "Backend appears compatible" "no compatibility claim after a failed check"
    assert_out_has "! pacman" "unparseable pacman version is a warning"
    MOCK_QUERY_FAIL=other run_ac doctor
    assert_rc 1 "pacman failing its probes -> rc 1"
    assert_out_has "✗ backend compatibility" "compatibility failure line"
    assert_out_lacks "Backend appears compatible" "no compatibility claim when probes fail"
    run_ac doctor --json
    assert_json_eq compatible true "json: compatible"
    assert_json_eq checks.1.name libalpm "json: libalpm check"
    assert_json_eq checks.1.detail 15.0.0 "json: libalpm version"
    MOCK_QUERY_FAIL=other run_ac doctor --json
    assert_json_eq compatible false "json: not compatible when probes fail"
}

# Tests the history filters (--install, --remove, --upgrade), including their
# interaction with --limit and invalid combinations.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_history_filters() {
    echo "== history filters =="
    new_state
    run_ac history --install
    assert_rc 0 "history --install -> rc 0"
    assert_out_has "Installed firefox" "--install keeps installs"
    assert_out_has "Installed git" "--install keeps every install"
    assert_out_lacks "Removed nano" "--install drops removals"
    assert_out_lacks "Upgraded vim" "--install drops upgrades"
    run_ac history --remove
    assert_out_has "Removed nano" "--remove keeps removals"
    assert_out_lacks "Installed" "--remove drops installs"
    run_ac history --upgrade
    assert_out_has "Upgraded vim (9.0.0-1 -> 9.1.0-1)" "--upgrade keeps upgrades"
    assert_out_lacks "Removed" "--upgrade drops removals"
    run_ac history --install -n 1
    assert_out_has "Installed git" "the limit applies after the filter"
    assert_out_lacks "Installed firefox" "limit keeps only the newest match"
    run_ac history --install --json
    assert_json_eq count 2 "json honors the filter"
    run_ac history --install --remove
    assert_rc 2 "two filters are rejected"
    run_ac list --install
    assert_rc 2 "filters are only valid for history"
    run_ac orphan --remove --install
    assert_rc 2 "--install is rejected by orphan"
}

# Simulates Ctrl+C during a read-only search and during remove: exit status,
# message and temp-file cleanup, as for the transaction commands.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_interrupt_search_remove() {
    echo "== Ctrl+C during search and remove =="
    interrupt_case "search" search git
    interrupt_case "remove" remove git
}

# Installs ac into a temporary prefix with install.sh, runs the whole user
# workflow through the installed (symlinked) command, then uninstalls and
# verifies that nothing is left behind.
# Arguments: none.
# Returns: 0. Side effects: records assertions (mock mode only).
test_install_and_workflow() {
    local prefix ac step
    echo "== installer and full workflow =="
    new_state
    prefix="$MOCK_STATE/prefix"
    PREFIX="$prefix" bash "$ROOT/install.sh" >/dev/null 2>&1
    ac="$prefix/bin/ac"
    if [ -L "$ac" ] && [ -x "$prefix/lib/ac/ac" ]; then pass "install.sh creates the command and the symlink"; else fail "install.sh creates the command and the symlink"; fi
    if [ -f "$prefix/share/ac/ac.conf.example" ]; then pass "install.sh installs the example configuration"; else fail "install.sh installs the example configuration"; fi
    run_installed() {
        local o e
        o=$(mktemp)
        e=$(mktemp)
        TMPDIR="$MOCK_STATE/tmp" PATH="$MOCK_DIR:$PATH" AC_PACMAN="$TEST_PACMAN" "$ac" "$@" >"$o" 2>"$e" </dev/null
        RC=$?
        OUT=$(<"$o")
        ERR=$(<"$e")
        rm -f "$o" "$e"
    }
    for step in "version" "help" "search firefox" "info firefox" "status firefox" "install firefox" "list" "history" "doctor" "upgrade" "remove firefox"; do
        # shellcheck disable=SC2086
        run_installed $step
        assert_rc 0 "installed workflow: ac $step"
        if [ "$step" = "install firefox" ]; then assert_out_has "✓ Installed: firefox" "workflow: firefox installed"; fi
        if [ "$step" = "list" ]; then assert_out_has "firefox" "workflow: list shows the new package"; fi
        if [ "$step" = "status firefox" ]; then assert_out_has "Status:         available" "workflow: status before install"; fi
    done
    run_installed list
    assert_out_lacks "firefox" "workflow: firefox is gone after remove"
    assert_called no '^-Sy( |$)' "workflow never ran a bare -Sy"
    PREFIX="$prefix" bash "$ROOT/install.sh" uninstall >/dev/null 2>&1
    if [ ! -e "$ac" ] && [ ! -e "$prefix/lib/ac" ] && [ ! -e "$prefix/share/ac" ]; then pass "uninstall removes everything"; else fail "uninstall removes everything"; fi
    assert_no_tempfiles "the workflow leaves no temp files"
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
    local arg only_interrupt=0
    for arg in "$@"; do
        case "$arg" in
            --only-interrupt) only_interrupt=1 ;; # internal: used by the SIGINT-ignored regression test
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
    if [ "$only_interrupt" -eq 1 ]; then
        interrupt_guard test_interrupt
        interrupt_guard test_interrupt_commands
        interrupt_guard test_interrupt_search_remove
        printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
        [ "$FAIL" -eq 0 ]
        return
    fi
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
        test_show_and_list_options
        test_update_upgrade
        test_v01_compatibility
        test_info_failures
        test_query_failures
        test_transactions
        test_stderr_streaming
        interrupt_guard test_interrupt
        test_no_bare_sy
        test_v03_options
        test_yes_matrix
        test_reinstall
        test_clean
        test_orphan
        test_history
        test_capabilities
        test_status
        test_info_v03
        test_json
        test_json_escape
        test_doctor
        test_config
        test_output_style
        test_security
        interrupt_guard test_interrupt_commands
        test_error_types
        test_status_updates
        test_info_license
        test_doctor_backend
        test_history_filters
        interrupt_guard test_interrupt_search_remove
        test_interrupt_when_sigint_ignored
        test_install_and_workflow
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
    printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" -eq 0 ]
}

main "$@"
