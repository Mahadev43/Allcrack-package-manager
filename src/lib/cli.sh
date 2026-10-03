#!/usr/bin/env bash
# Command-line parsing for ac: help text, option parsing and validation, and
# dispatch to the cmd_* handlers in commands/. Options may appear before or
# after the command and are validated against what each command supports.
# Sourced by src/ac.

# Prints the help text. Used by `ac help`, `-h`, `--help` and `ac <cmd> --help`.
# Arguments: none.
# Returns: 0. Writes to stdout.
cli_help() {
    cat <<EOF2
${AC_NAME} ${AC_SERIES}

Usage:
  ac <command> [options] [arguments]

Commands:

  install <package>...    Install packages
  remove <package>...     Remove packages
  reinstall <package>...  Reinstall installed packages
  search <query>          Search for packages
  info <package>...       Show package information (alias: show)
  status <package>...     Show whether packages are installed or available
  list [query]            List installed packages (--upgradable: those with updates)
  orphan                  List orphan packages (--remove to remove them)
  clean                   Clean the package cache (--all for everything)
  history                 Show recent package transactions
  doctor                  Diagnose package-management problems
  update                  Synchronize/update system
  upgrade                 Upgrade installed packages
  help                    Show this help
  version                 Show version

Options:

  -y, --yes               Do not ask for confirmation (install, remove,
                          reinstall, update, upgrade, clean)
  --json                  Machine-readable output (info, search, status, list,
                          orphan, history, doctor, version)
  --no-color              Plain output without colors
  --all                   clean: remove every cached package file (always asks)
  --installed             list: installed packages (the default)
  --upgradable            list: installed packages with a newer version available
  --remove                orphan: remove the orphan packages (always asks)
  -n, --limit N           history: number of entries to show (default 20)
  --install, --remove, --upgrade
                          history: show only that kind of transaction
  -h, --help              Show this help
  -V, --version           Show version

Examples:

  sudo ac install firefox
  sudo ac install --yes firefox git
  sudo ac remove firefox
  ac search docker
  ac info firefox --json
  ac list --upgradable
  ac status firefox
  ac list
  ac orphan
  ac history -n 10
  ac doctor
  sudo ac update
  sudo ac upgrade

Notes:

  'update' and 'upgrade' both refresh the package databases AND upgrade the
  whole system in one step (pacman -Syu). ac never refreshes the databases
  on their own, because a partial upgrade is unsupported on Arch Linux and
  can leave the system broken. 'ac install' therefore never syncs; run
  'sudo ac update' first if a package cannot be found or downloaded.

  Orphan removal and 'clean --all' always ask for confirmation; --yes is
  rejected for them. In --json mode stdout contains only JSON, and errors are
  reported as {"error":{"type","message","reason","exit_code"}}.

  Settings (color, confirm, progress) can be set in /etc/ac.conf and
  ~/.config/ac/config; see the README.
EOF2
}

# Parses the command line into the AC_OPT_* globals, AC_CMD and CLI_ARGS.
# Boolean options (--yes, --json, --no-color, --all, --remove) and the value
# option --limit may appear anywhere; "--" ends option parsing. Words with
# control characters are rejected: no package name or search term has any, and
# multi-line names would corrupt pacman's line-based error messages. The first
# non-option word is the command, the rest are its arguments. Only the first
# unrecognised option is remembered (CLI_BAD_OPT) so the error can name the
# command once it is known. Nothing here is evaluated: arguments are only
# compared and stored.
# Arguments:
#   $@ - The command line given to ac.
# Returns: 0; exits with EX_USAGE for an empty or control-character argument or
#   a bad --limit value.
# Side effects: sets AC_OPT_*, AC_CMD, CLI_ARGS, CLI_WANT_HELP, CLI_WANT_VERSION,
#   CLI_BAD_OPT, CLI_SEEN_LIMIT.
cli_parse() {
    local arg value end_opts=0
    CLI_ARGS=()
    while [ "$#" -gt 0 ]; do
        arg=$1
        shift
        if [ "$end_opts" -eq 0 ]; then
            case "$arg" in
                --) end_opts=1; continue ;;
                --yes | -y) AC_OPT_YES=1; continue ;;
                --json) AC_OPT_JSON=1; continue ;;
                --no-color) AC_OPT_NOCOLOR=1; continue ;;
                --all) AC_OPT_ALL=1; continue ;;
                --remove) AC_OPT_REMOVE=1; continue ;;
                --installed) AC_OPT_INSTALLED=1; continue ;;
                --upgradable) AC_OPT_UPGRADABLE=1; continue ;;
                --install) AC_OPT_FILTER=installed; CLI_FILTER_COUNT=$((CLI_FILTER_COUNT + 1)); continue ;;
                --upgrade) AC_OPT_FILTER=upgraded; CLI_FILTER_COUNT=$((CLI_FILTER_COUNT + 1)); continue ;;
                --help | -h) CLI_WANT_HELP=1; continue ;;
                --version | -V | -v) CLI_WANT_VERSION=1; continue ;;
                --limit=*) value=${arg#--limit=} ;;
                --limit | -n)
                    if [ "$#" -eq 0 ]; then
                        err_usage "option '$arg' needs a number." "ac history $arg <count>"
                    fi
                    value=$1
                    shift
                    ;;
                "") err_usage "empty argument given${AC_CMD:+ to 'ac $AC_CMD'}." ;;
                -*)
                    [ -n "$CLI_BAD_OPT" ] || CLI_BAD_OPT=$arg
                    continue
                    ;;
                *) value="" ;;
            esac
            if [ "${arg#-}" != "$arg" ]; then
                if [[ ! $value =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 100000 ]; then
                    err_usage "invalid value '$value' for the limit option (use a number from 1 to 100000)."
                fi
                AC_OPT_LIMIT=$value
                CLI_SEEN_LIMIT=1
                continue
            fi
        fi
        if [ -z "$arg" ]; then
            err_usage "empty argument given${AC_CMD:+ to 'ac $AC_CMD'}."
        fi
        if [[ $arg == *[[:cntrl:]]* ]]; then
            err_usage "invalid argument: control characters (such as newlines) are not allowed."
        fi
        if [ -z "$AC_CMD" ]; then
            AC_CMD=$arg
        else
            CLI_ARGS+=("$arg")
        fi
    done
}

# Tells whether a command is one of ac's commands.
# Arguments:
#   $1 - Command name.
# Returns: 0 if known, 1 otherwise.
cli_is_command() {
    case "$1" in
        install | remove | reinstall | search | info | show | status | list | orphan | clean | history | doctor | update | upgrade | help | version) return 0 ;;
    esac
    return 1
}

# Tells whether a command may auto-confirm pacman's prompts (--yes or
# confirm=false). Orphan removal and clean --all are deliberately excluded:
# they delete data and must always ask.
# Arguments:
#   $1 - Command name.
# Returns: 0 if auto-confirmation is allowed, 1 otherwise.
cli_supports_yes() {
    case "$1" in
        install | remove | reinstall | update | upgrade) return 0 ;;
        clean) [ "$AC_OPT_ALL" -eq 0 ] ;;
        *) return 1 ;;
    esac
}

# Rejects option/command combinations that are unsupported or unsafe, with a
# message that says what to do instead.
# Arguments: none (uses AC_CMD and AC_OPT_*).
# Returns: 0 if the combination is valid; exits with EX_USAGE otherwise.
cli_validate_options() {
    local cmd=$AC_CMD
    if [ -n "$CLI_BAD_OPT" ]; then
        err_usage "invalid option '$CLI_BAD_OPT'${cmd:+ for 'ac $cmd'}."
    fi
    if [ "$AC_OPT_YES" -eq 1 ]; then
        case "$cmd" in
            install | remove | reinstall | update | upgrade) ;;
            clean)
                [ "$AC_OPT_ALL" -eq 0 ] ||
                    err_usage "'--yes' cannot be combined with '--all': removing the whole cache always asks for confirmation."
                ;;
            orphan)
                err_usage "option '--yes' is not supported by 'ac orphan': removing orphans always asks for confirmation."
                ;;
            *) err_usage "option '--yes' is not supported by 'ac $cmd'." ;;
        esac
    fi
    if [ "$AC_OPT_JSON" -eq 1 ]; then
        case "$cmd" in
            info | search | status | list | history | doctor | version) ;;
            orphan)
                [ "$AC_OPT_REMOVE" -eq 0 ] ||
                    err_usage "option '--json' cannot be combined with '--remove': removal is interactive."
                ;;
            *) err_usage "option '--json' is not supported by 'ac $cmd'." ;;
        esac
    fi
    if { [ "$AC_OPT_INSTALLED" -eq 1 ] || [ "$AC_OPT_UPGRADABLE" -eq 1 ]; } && [ "$cmd" != list ]; then
        err_usage "options '--installed' and '--upgradable' are only supported by 'ac list'."
    fi
    if [ "$AC_OPT_INSTALLED" -eq 1 ] && [ "$AC_OPT_UPGRADABLE" -eq 1 ]; then
        err_usage "use only one of '--installed' and '--upgradable'."
    fi
    if [ "$AC_OPT_UPGRADABLE" -eq 1 ] && [ "${#CLI_ARGS[@]}" -gt 0 ]; then
        err_usage "'ac list --upgradable' does not take a query."
    fi
    if [ "$AC_OPT_ALL" -eq 1 ] && [ "$cmd" != clean ]; then
        err_usage "option '--all' is only supported by 'ac clean'."
    fi
    if [ "$AC_OPT_REMOVE" -eq 1 ] && [ "$cmd" = history ]; then
        AC_OPT_REMOVE=0
        AC_OPT_FILTER=removed
        CLI_FILTER_COUNT=$((CLI_FILTER_COUNT + 1))
    fi
    if [ "$AC_OPT_REMOVE" -eq 1 ] && [ "$cmd" != orphan ]; then
        err_usage "option '--remove' is only supported by 'ac orphan' and 'ac history'."
    fi
    if [ "$CLI_FILTER_COUNT" -gt 0 ] && [ "$cmd" != history ]; then
        err_usage "options '--install', '--upgrade' and '--remove' filters are only supported by 'ac history'."
    fi
    if [ "$CLI_FILTER_COUNT" -gt 1 ]; then
        err_usage "use only one of '--install', '--remove' and '--upgrade'."
    fi
    if [ "$CLI_SEEN_LIMIT" -eq 1 ] && [ "$cmd" != history ]; then
        err_usage "option '--limit' is only supported by 'ac history'."
    fi
}

# Checks that a command received a valid number of positional arguments.
# Arguments: none (uses AC_CMD and CLI_ARGS).
# Returns: 0 if valid; exits with EX_USAGE otherwise.
cli_check_arity() {
    local cmd=$AC_CMD n=${#CLI_ARGS[@]}
    case "$cmd" in
        install | remove | reinstall | info | status)
            [ "$n" -ge 1 ] || err_usage "package name required." "ac $cmd <package>..."
            ;;
        search)
            [ "$n" -ge 1 ] || err_usage "search query required." "ac search <query>..."
            ;;
        update | upgrade | version | orphan | clean | history | doctor)
            [ "$n" -eq 0 ] || err_usage "'$cmd' takes no arguments." "ac $cmd"
            ;;
    esac
}

# Maps a command to the backend capability it needs.
# Arguments:
#   $1 - Command name.
# Returns: prints the capability name on stdout (empty if none is needed).
cli_capability_for() {
    case "$1" in
        install) printf INSTALL ;;
        remove) printf REMOVE ;;
        reinstall) printf REINSTALL ;;
        search) printf SEARCH ;;
        info) printf INFO ;;
        status) printf STATUS ;;
        list) printf LIST ;;
        orphan) printf ORPHAN ;;
        clean) printf CLEAN ;;
        history) printf HISTORY ;;
        update | upgrade) printf UPGRADE ;;
    esac
}

# Prints the version, as text or (with --json) as {"name":...,"version":...}.
# Arguments: none.
# Returns: 0.
cli_version() {
    local n v
    if [ "$AC_OPT_JSON" -eq 1 ]; then
        json_quote n "$AC_NAME"
        json_quote v "$AC_VERSION"
        json_emit "{\"name\":$n,\"version\":$v}"
    else
        out_version
    fi
}

# Parses the command line, loads the configuration, and runs the command.
# Order: parse -> help/version -> validation -> configuration and output
# setup -> backend + capability check -> command handler.
# Arguments:
#   $@ - The command line given to ac.
# Returns: the exit status of the command handler. Usage errors exit directly
#   with EX_USAGE.
cli_main() {
    local cap w
    cli_parse "$@"
    if [ "$CLI_WANT_HELP" -eq 1 ] || [ "$AC_CMD" = help ]; then
        cli_help
        return "$EX_OK"
    fi
    if [ -z "$AC_CMD" ] && [ "$CLI_WANT_VERSION" -eq 1 ]; then
        AC_CMD=version
        CLI_WANT_VERSION=0
    fi
    if [ "$CLI_WANT_VERSION" -eq 1 ]; then
        err_usage "option '--version' cannot be combined with 'ac $AC_CMD'."
    fi
    if [ -z "$AC_CMD" ] && [ -n "$CLI_BAD_OPT" ]; then
        err_usage "invalid option '$CLI_BAD_OPT'."
    fi
    [ -n "$AC_CMD" ] || err_usage "command required."
    [ "$AC_CMD" != show ] || AC_CMD=info
    cli_is_command "$AC_CMD" || err_usage "unknown command '$AC_CMD'."
    cli_validate_options
    cli_check_arity

    cfg_load
    if [ "$AC_OPT_YES" -eq 1 ] || { [ "$AC_CONF_CONFIRM" = false ] && cli_supports_yes "$AC_CMD"; }; then
        AC_AUTO_YES=1
    fi
    out_init
    if [ "$AC_CMD" != doctor ]; then
        for w in "${CFG_WARNINGS[@]}"; do
            out_warning "$w"
        done
    fi

    if [ "$AC_CMD" = version ]; then
        cli_version
        return "$EX_OK"
    fi
    if [ "$AC_CMD" != doctor ]; then
        pm_init
        cap=$(cli_capability_for "$AC_CMD")
        pm_require_cap "$cap" "$AC_CMD" || return $?
    fi
    "cmd_$AC_CMD" "${CLI_ARGS[@]}"
    return $?
}
