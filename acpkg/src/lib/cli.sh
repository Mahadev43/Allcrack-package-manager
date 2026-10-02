#!/usr/bin/env bash
# Command-line parsing for ac: help text, argument validation and dispatch to
# the cmd_* handlers in commands/. Sourced by src/ac.

# Prints the help text. Used by `ac help`, `-h`, `--help` and `ac <cmd> --help`.
# Arguments: none.
# Returns: 0. Writes to stdout.
cli_help() {
    cat <<EOF
${AC_NAME} ${AC_SERIES}

Usage:
  ac <command> [arguments]

Commands:

  install <package>...    Install packages
  remove <package>...     Remove packages
  search <query>          Search for packages
  info <package>...       Show package information
  list [query]            List installed packages
  update                  Synchronize/update system
  upgrade                 Upgrade installed packages
  help                    Show this help
  version                 Show version (also: -V, --version)

Examples:

  sudo ac install firefox
  sudo ac remove firefox
  ac search docker
  ac info firefox
  ac list
  sudo ac update
  sudo ac upgrade

Notes:

  'update' and 'upgrade' both refresh the package databases AND upgrade the
  whole system in one step (pacman -Syu). ac never refreshes the databases
  on their own, because a partial upgrade is unsupported on Arch Linux and
  can leave the system broken. 'ac install' therefore never syncs; run
  'sudo ac update' first if a package cannot be found or downloaded.
EOF
}

# Rejects arguments ac does not support: empty strings and anything that looks
# like an option. `-h`/`--help` after a command prints the help instead.
# Arguments:
#   $1 - The command name (used in messages).
#   $2... - The arguments given to that command.
# Returns: 0 if all arguments are acceptable; exits with EX_USAGE otherwise
#   (or with EX_OK after printing help).
cli_validate_args() {
    local cmd=$1 arg
    shift
    for arg in "$@"; do
        case "$arg" in
            -h | --help)
                cli_help
                exit "$EX_OK"
                ;;
            "")
                err_usage "empty argument given to 'ac $cmd'."
                ;;
            -*)
                err_usage "invalid option '$arg' for 'ac $cmd'."
                ;;
        esac
    done
}

# Checks that a command received a valid number of arguments.
# Arguments:
#   $1 - The command name.
#   $2... - The arguments given to that command.
# Returns: 0 if the argument count is valid; exits with EX_USAGE otherwise.
cli_check_arity() {
    local cmd=$1
    shift
    case "$cmd" in
        install | remove | info)
            [ "$#" -ge 1 ] || err_usage "package name required." "ac $cmd <package>..."
            ;;
        search)
            [ "$#" -ge 1 ] || err_usage "search query required." "ac search <query>..."
            ;;
        update | upgrade | version)
            [ "$#" -eq 0 ] || err_usage "'$cmd' takes no arguments." "ac $cmd"
            ;;
    esac
}

# Parses the command line and runs the requested command.
# Arguments:
#   $@ - The command line given to ac (command name first).
# Returns: the exit status of the command handler. Usage errors exit directly
#   with EX_USAGE.
cli_main() {
    local cmd
    [ "$#" -gt 0 ] || err_usage "command required."
    cmd=$1
    shift
    case "$cmd" in
        help | -h | --help)
            cli_help
            return "$EX_OK"
            ;;
        version | --version | -V | -v)
            cli_validate_args version "$@"
            cli_check_arity version "$@"
            out_version
            return "$EX_OK"
            ;;
        install | remove | search | info | list | update | upgrade)
            cli_validate_args "$cmd" "$@"
            cli_check_arity "$cmd" "$@"
            pm_init
            "cmd_$cmd" "$@"
            return $?
            ;;
        *)
            err_usage "unknown command '$cmd'."
            ;;
    esac
}
