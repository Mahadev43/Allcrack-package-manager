#!/usr/bin/env bash
# Global option state and defaults shared by all modules. Sourced by src/ac
# right after version.sh. Defines no functions; every variable is initialised
# here so no module can hit an unset variable under `set -u`.
#
# AC_OPT_*  - values given on the command line (set by cli_parse).
# AC_CMD    - the selected command; CLI_ARGS - its positional arguments.
# AC_AUTO_YES - 1 when pacman prompts must be auto-confirmed (--yes, or
#             confirm=false in the configuration, for commands that allow it).

AC_OPT_YES=0
AC_OPT_JSON=0
AC_OPT_NOCOLOR=0
AC_OPT_ALL=0
AC_OPT_REMOVE=0
AC_OPT_LIMIT=20
AC_OPT_FILTER=""
AC_OPT_INSTALLED=0
AC_OPT_UPGRADABLE=0
AC_AUTO_YES=0

AC_CMD=""
declare -a CLI_ARGS=()
CLI_WANT_HELP=0
CLI_WANT_VERSION=0
CLI_BAD_OPT=""
CLI_SEEN_LIMIT=0
CLI_FILTER_COUNT=0
