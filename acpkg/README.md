# AllCrack Package Manager (`ac`)

**Current version: 0.2.0**

`ac` gives AllCrack OS an apt/dnf-style command line (`install`, `remove`, `search`, `info`, `list`, `update`, `upgrade`) on top of Arch Linux's package system.

> AllCrack Package Manager v0.2 is currently a frontend for the Arch Linux package-management system and does not yet replace pacman/libalpm.

All real work (dependency resolution, downloads, transactions, signature checks) is done by `pacman`, which remains the underlying package manager. `ac` adds a friendlier interface, validation, clearer errors and its own output.

The long-term goal is to evolve `ac`'s architecture toward a more independent package manager (first talking to libalpm directly, later more). None of that exists yet in v0.2.

## Installation

Requires an Arch-based system (or any machine with `pacman`) and bash 4.4+.

```bash
sudo ./install.sh              # installs to /usr/local/lib/ac, links /usr/local/bin/ac
sudo ./install.sh uninstall    # removes it
```

You can also run it straight from the source tree: `bash src/ac help`.

## Commands

| Command | Needs root | Description |
|---|---|---|
| `ac install <package>...` | yes | Install packages. Already-installed packages are reported and skipped. |
| `ac remove <package>...` | yes | Remove packages. Names that are not installed are rejected before anything changes. |
| `ac search <query>...` | no | Search the repositories. Partial words work; several terms must all match. "No results" is a success; a failed query is an error. |
| `ac info <package>...` | no | Package metadata: version, repository, architecture, size, dependencies, description. Reports "Package not found" only when the package really does not exist; database or pacman failures are reported as such, with pacman's reason. |
| `ac list [query]` | no | List installed packages, optionally filtered. |
| `ac update` | yes | Synchronize databases **and** upgrade the system (`pacman -Syu`). |
| `ac upgrade` | yes | Full system upgrade (`pacman -Syu`). |
| `ac help` | no | Show help. |
| `ac version`, `-V`, `--version` | no | Show version (`AllCrack Package Manager 0.2.0`). |

### Examples

```bash
sudo ac install firefox git vim
sudo ac remove firefox
ac search docker
ac info firefox git
ac list
ac list firefox
sudo ac update
```

### Why `update` also upgrades

Arch Linux does not support partial upgrades. Refreshing the package databases (`pacman -Sy`) without upgrading, then installing something, can leave the system with broken library versions. v0.1 ran `pacman -Sy` for `ac update`; v0.2 never does. Both `ac update` and `ac upgrade` run `pacman -Syu`, and `ac install` never syncs. If a package can't be found or downloaded, run `sudo ac update` and try again.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (including "no results" for `search`/`list`) |
| 1 | Unexpected pacman failure, or a failed database query (pacman's own status is reused for unclassified transaction failures) |
| 2 | Usage error: unknown command, missing or invalid argument |
| 3 | Package not found (`install`, `info`) or not installed (`remove`) |
| 4 | Root privileges required (also: a query failed with "Permission denied") |
| 5 | Network failure |
| 6 | Package database locked by another process |
| 7 | Unresolved dependencies or package conflicts |
| 8 | pacman could not prepare or commit the transaction (for example conflicting files) |
| 127 | `pacman` not found |
| 130 | Interrupted |

pacman's own error output is always shown; `ac` adds a short explanation on top. In v0.2 (before release) codes 7 and 8 replaced the generic status 1 that v0.2 development builds returned for dependency and transaction failures.

### How `ac` runs pacman

Read-only queries (`search`, `info`, `list`) capture pacman's output so `ac` can reformat it; pacman warnings are passed through to stderr. Changing operations (`install`, `remove`, `update`, `upgrade`) keep pacman attached to the terminal, so prompts, progress bars and output work as usual. pacman's stderr is shown live and copied to a temporary file only so a failure can be classified (lock, network, dependencies, ...). The temporary file is removed on success, failure and Ctrl+C. On Ctrl+C pacman is allowed to finish its own cleanup, then `ac` exits with 130.

## Architecture

```
ac (src/ac)  ->  cli  ->  commands  ->  pacman module  ->  pacman  ->  libalpm
                  |            |
                  |            +-> output (all formatting)
                  +-> errors (exit codes, failure classification)
```

```
src/
├── ac                   entry point: finds lib/, loads modules, runs the CLI
└── lib/
    ├── version.sh       version constants
    ├── cli.sh           help text, argument validation, dispatch
    ├── errors.sh        exit codes, messages, pacman failure classification
    ├── output.sh        banner, lists, search results, key/value blocks
    ├── pacman.sh        the ONLY module that runs/parses pacman (pm_* functions)
    └── commands/        install, remove, search, info, list, update, upgrade
tests/
├── run_tests.sh         test runner (mock and live modes)
└── mock/                fake pacman and fake id used by the mock tests
install.sh
```

Commands never call pacman directly; they use the `pm_*` functions of the package-manager layer in `pacman.sh`. Moving to libalpm later means replacing that file while keeping the interface.

Every function carries a comment block (purpose, arguments, return value, side effects). The test suite checks this.

Environment variables for development: `AC_PACMAN` (path to the pacman binary) and `AC_LIB_DIR` (module directory).

## Testing

```bash
tests/run_tests.sh                 # mock mode: no pacman needed, changes nothing
tests/run_tests.sh --live          # read-only checks against the real pacman
sudo tests/run_tests.sh --live-mutating   # also installs/removes "tree" and runs a full update
```

Mock mode uses a fake pacman, so it runs on the Fedora development machine. It checks syntax, that every function is documented, all commands and exit codes, `info`/`search`/`list` failure handling (missing package vs. repository, local and other pacman failures), transaction failure classification, live stderr streaming, Ctrl+C handling, temporary-file cleanup, and that neither `ac update` nor `ac upgrade` ever runs a bare `pacman -Sy` (also checked statically in the source). Run the two `--live` modes inside an Arch / AllCrack OS VM (never on a machine you care about for `--live-mutating`) before tagging a release.

## Current limitations

- Depends on `pacman`; no libalpm integration, own dependency resolver, package format, database or repository server.
- No AUR support. Packages built from the AUR show up in `list` and `info` as local packages.
- If `ac` itself is sent SIGTERM while pacman runs, it exits only after pacman finishes (Ctrl+C reaches both and works normally).
- Failure classification relies on pacman's English messages (`ac` runs pacman with `LC_ALL=C`, so pacman's own output is in English).
- `update` and `upgrade` are currently equivalent.
- No `--noconfirm`/`--yes` option yet; pacman prompts as usual.
- No rollback, package signing infrastructure, or GUI.

## Roadmap (proposed)

- **v0.3**: cleaner progress output, configuration file, `autoremove`/orphan cleanup, `--yes`.
- **v0.4**: `ac` talks to libalpm directly instead of calling pacman.
- Later: AUR support, rollback, AllCrack repositories.
