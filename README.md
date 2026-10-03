# AllCrack Package Manager (`ac`)

**Version: 0.3.0**

`ac` is a lightweight package-management frontend for **Arch Linux and Arch-based systems**.

It provides a simple, consistent command-line interface while delegating the actual package-management operations to `pacman`.

```text
User
  ↓
 ac
  ↓
pacman
  ↓
libalpm
  ↓
Arch Linux repositories
```

The goal of `ac` is simple:

> **Make package management easier to use without replacing the existing Arch Linux package-management stack.**

---

## Features

* Simple package-management commands
* Install multiple packages at once
* Remove packages
* Reinstall packages
* Search packages
* View package information
* List installed and upgradable packages
* Check package status
* Safely update and upgrade the system
* Clean package cache
* Find and remove orphan packages
* Package-management history
* Package-manager diagnostics
* `--yes` / `-y` support
* Machine-readable JSON output
* Configurable output behavior
* Structured error handling
* Safe command execution
* Ctrl+C / interruption handling

---

## Installation

Clone the repository:

```bash
git clone https://github.com/Mahadev43/Allcrack-package-manager.git
cd Allcrack-package-manager
```

Run the installer:

```bash
sudo ./install.sh
```

Verify the installation:

```bash
ac --version
```

Show available commands:

```bash
ac help
```

### Requirements

* Arch Linux or an Arch-based system
* Bash 4.4+
* `pacman`

`ac` uses the existing `pacman` installation on the system.

Optional utilities may be used by `ac doctor` for additional diagnostics.

---

# Usage

## Install packages

Install a package:

```bash
sudo ac install firefox
```

Install multiple packages:

```bash
sudo ac install firefox git curl
```

Skip confirmation:

```bash
sudo ac install -y firefox
```

or:

```bash
sudo ac install --yes firefox
```

Package dependency resolution and transaction handling are delegated to `pacman`.

---

## Remove packages

Remove a package:

```bash
sudo ac remove firefox
```

Remove multiple packages:

```bash
sudo ac remove firefox git
```

Skip confirmation:

```bash
sudo ac remove -y firefox
```

---

## Reinstall packages

Reinstall an installed package:

```bash
sudo ac reinstall firefox
```

The reinstall operation is performed through the existing `pacman` backend.

---

# Update and Upgrade

Update the system:

```bash
sudo ac update
```

Upgrade the system:

```bash
sudo ac upgrade
```

Both commands use the safe full system synchronization and upgrade operation provided by `pacman`.

Conceptually:

```text
ac update
     ↓
pacman -Syu
```

```text
ac upgrade
     ↓
pacman -Syu
```

`ac` does **not** perform an unsafe partial synchronization using:

```bash
pacman -Sy
```

This is intentional because Arch Linux does not support partial system upgrades.

---

# Search

Search for packages:

```bash
ac search firefox
```

The search is performed using the existing pacman package-management infrastructure.

---

# Package Information

View package information:

```bash
ac info firefox
```

You can also use:

```bash
ac show firefox
```

JSON output:

```bash
ac info firefox --json
```

Example:

```json
{
  "name": "firefox",
  "version": "...",
  "architecture": "...",
  "description": "..."
}
```

The exact fields depend on the package information provided by the backend.

---

# List Packages

List installed packages:

```bash
ac list
```

Explicitly request installed packages:

```bash
ac list --installed
```

List packages with available upgrades:

```bash
ac list --upgradable
```

JSON output:

```bash
ac list --json
```

`ac` does not maintain a separate package database. Package state comes from the existing Arch/pacman package database.

---

# Package Status

Check the status of a package:

```bash
ac status firefox
```

JSON output:

```bash
ac status firefox --json
```

The status is derived from the package state provided by the system's package-management infrastructure.

---

# Clean Package Cache

Clean unused package cache:

```bash
sudo ac clean
```

For the more aggressive cache-cleaning operation:

```bash
sudo ac clean --all
```

Destructive cache operations require appropriate confirmation.

`ac` delegates cache management to pacman rather than maintaining its own cache system.

---

# Orphan Packages

Find orphan packages:

```bash
ac orphan
```

Remove orphan packages:

```bash
sudo ac orphan --remove
```

The normal `ac orphan` command only reports orphan packages.

It does not automatically remove them.

Dependency relationships are handled by pacman rather than by a custom dependency resolver inside `ac`.

---

# History

View package-management history:

```bash
ac history
```

JSON output:

```bash
ac history --json
```

History is intended to provide a record of package-management activity.

It is informational and does not provide transaction rollback or automatic undo functionality.

---

# Doctor

Check the package-management environment:

```bash
ac doctor
```

JSON output:

```bash
ac doctor --json
```

`ac doctor` focuses specifically on the package-management environment.

It can check areas such as:

* `ac` availability
* `pacman` availability
* pacman version
* architecture
* pacman configuration
* package database
* synchronization databases
* package database lock
* permissions
* relevant configuration
* backend availability
* network availability where relevant

It is **not** intended to be a general-purpose Linux system diagnostic or repair utility.

---

# JSON Output

Commands that support JSON can be used with:

```bash
--json
```

For example:

```bash
ac search firefox --json
ac info firefox --json
ac list --json
ac status firefox --json
ac history --json
ac doctor --json
```

When JSON output is requested:

* stdout contains machine-readable JSON
* diagnostic messages are written separately
* output is designed to be suitable for scripts and other tools

---

# Configuration

`ac` supports a small configuration system for frontend behavior.

The configuration is intentionally limited to settings relevant to the CLI experience.

Typical settings include:

```text
color
confirm
progress
```

System configuration:

```text
/etc/ac.conf
```

Optional user configuration:

```text
~/.config/ac/config
```

Configuration does not execute shell commands and is not intended to provide package repository or package-management infrastructure.

---

# Safety

`ac` is designed to safely pass package names and options to `pacman`.

It does not rely on unsafe shell evaluation for package-management commands.

The project specifically avoids patterns such as:

```bash
eval "$command"
```

or dynamically constructed shell commands containing untrusted package names.

Package operations are delegated to the existing `pacman` backend.

---

# Ctrl+C Handling

Package operations can be interrupted with:

```text
Ctrl+C
```

The frontend handles interruptions and returns an appropriate exit status.

Temporary resources created during operations are cleaned up when possible.

---

# Architecture

`ac` intentionally has a small architecture:

```text
                    User
                      │
                      ▼
                 ┌────────┐
                 │   ac   │
                 │  CLI   │
                 └────┬───┘
                      │
                      ▼
               ┌────────────┐
               │ pm_*       │
               │ backend    │
               └─────┬──────┘
                     │
                     ▼
                ┌─────────┐
                │ pacman  │
                └────┬────┘
                     │
                     ▼
                ┌─────────┐
                │ libalpm │
                └────┬────┘
                     │
                     ▼
             Arch repositories
```

The command layer does not directly implement package-management transactions.

Commands use the internal package-management backend, which communicates with `pacman`.

---

# What `ac` Does Not Do

`ac` intentionally does **not** attempt to become a complete package ecosystem.

It does not provide:

* ❌ Custom package repository
* ❌ Package mirror infrastructure
* ❌ Custom package format
* ❌ Custom package database
* ❌ Custom dependency resolver
* ❌ Package-building service
* ❌ Package-hosting service
* ❌ Package server
* ❌ AUR replacement
* ❌ Direct libalpm package-management backend
* ❌ GUI
* ❌ Background daemon
* ❌ AI package management
* ❌ Remote package management
* ❌ Package rollback system
* ❌ Generic Linux command wrappers
* ❌ Archive extraction commands

For example, `ac` does **not** replace normal Linux commands:

```bash
unzip file.zip
tar -xf file.tar
7z x file.7z
git clone ...
curl ...
wget ...
```

Those commands remain separate utilities.

`ac` is for **package management only**.

---

# AUR

`ac` is not an AUR helper.

It does not:

* search the AUR
* build AUR packages
* install PKGBUILDs
* provide an AUR repository
* replace existing AUR tools

Users can continue using their preferred AUR tooling separately.

---

# Why `pacman` Remains the Backend

`ac` does not attempt to replace pacman.

This keeps the project smaller and reduces maintenance.

The Arch Linux package-management stack remains responsible for:

* dependency resolution
* package downloads
* package verification
* package installation
* package removal
* package transactions
* package database management
* repository interaction

`ac` provides the user-facing interface on top of that infrastructure.

---

# Testing

The project includes an extensive automated test suite.

Current v0.3.0 test result:

```text
779 passed, 0 failed, 0 skipped
```

The test suite covers areas including:

* CLI parsing
* package operations
* search
* package information
* listing
* status
* update/upgrade behavior
* JSON output
* configuration
* error handling
* security
* interruption handling
* temporary-file cleanup
* installer
* uninstaller
* complete package-management workflow

The test suite uses controlled/mock environments where appropriate so normal tests do not require modifying the host package database.

---

# Example Workflow

A typical workflow can look like:

```bash
# Search
ac search firefox

# View information
ac info firefox

# Install
sudo ac install firefox

# Check status
ac status firefox

# List installed packages
ac list --installed

# Update and upgrade
sudo ac update

# Check for orphan packages
ac orphan

# View history
ac history

# Diagnose package-management issues
ac doctor

# Remove
sudo ac remove firefox
```

---

# Design Philosophy

`ac` follows a simple principle:

> **Improve the package-management experience without rebuilding the package-management ecosystem.**

That means:

```text
ac
 ↓
pacman
 ↓
libalpm
 ↓
Arch Linux
```

The project focuses on making common package-management operations easier to discover, easier to use, safer to script, and more consistent.

---

# Project Status

**Version:** `0.3.0`

**Status:** Stable release candidate / release-ready

Test status:

```text
779 passed
0 failed
0 skipped
```

The v0.3 architecture is intentionally focused on being a **CLI package-management frontend** rather than expanding into a separate package ecosystem.

---

# License

See the `LICENSE` file in this repository for licensing information.
