linux-helpers
=============

Overview
--------
This repository contains recovery / utility scripts for Ubuntu desktop systems. The focus is pragmatic repair of a broken graphical environment after an unsafe Python upgrade or package disruption. The code is intentionally explicit (no magic abstractions) so you can audit every command before running it.

Why This Exists
---------------
The primary script `ubuntu_desktop_reset.sh` was written after a manual Python 3.13 installation displaced the system Python 3.12 alternative. That broke:
- python3-apt (import failures, `apt` unusable)
- GNOME Terminal / VTE (no graphical terminal would launch)
- The ability to conveniently recover without reinstalling

From a TTY session, this script provides an idempotent path to restore a working GNOME session and terminal, while giving you logging and optional remediation steps (drivers, kernel, Wayland toggle).

Script: ubuntu_desktop_reset.sh
--------------------------------
Purpose: Repair a damaged Ubuntu 24.04 GNOME desktop when python / VTE / terminal stack is broken.

Key phases (executed in order):
1. Pre-flight checks
	- Detect distribution, environment (DISPLAY) and basic tooling.
2. Python alternative repair
	- Re-pins `/usr/bin/python3` to python3.12 if present.
	- Removes python3.13 alternative entry if it hijacked the link (does not delete the binary).
3. APT health
	- `apt-get update` (tolerates transient failures) and forced reinstall of `python3-apt`.
4. GNOME terminal stack reinstall
	- Reinstalls terminal + core VTE / GTK / schema components.
5. Optional Wayland disable
	- Ensures `WaylandEnable=false` in `/etc/gdm3/custom.conf` when `--force-xorg` is active.
	- Backs up the original file under `~/.fix_desktop_backups/`.
6. GNOME reset
	- Resets terminal dconf path and restores a sane theme + Ctrl+Alt+T binding.
7. Cache cleanup
	- Clears terminal, vte, fontconfig caches; rebuilds font cache.
8. Launch test
	- Attempts to spawn GNOME Terminal (best-effort if no graphical session available).
9. Fallback terminals
	- Installs `kgx` and `tilix` if GNOME Terminal still fails (unless suppressed).
10. Optional NVIDIA remediation
	 - Installs `ubuntu-drivers-common` and reinstalls the recommended driver.
11. Optional kernel meta update
	 - Installs HWE meta if available; falls back to generic meta.
12. Final diagnostics
	 - Reports python alternative state and validates `apt_pkg` import.
13. Summary output
	 - Clear recap and reboot guidance.

Usage
-----
Run from a TTY (Ctrl+Alt+F3) or any root-capable session. Always review the script first.

Examples:
```
sudo bash ubuntu_desktop_reset.sh
sudo bash ubuntu_desktop_reset.sh --kernel-latest
sudo bash ubuntu_desktop_reset.sh --no-nvidia --dry-run
```

Options:
- `--with-nvidia` / `--no-nvidia`    Toggle NVIDIA driver reinstall (default: on)
- `--force-xorg` / `--no-force-xorg` Toggle Wayland disable (default: on)
- `--kernel-latest`                  Install latest GA/HWE kernel meta
- `--dry-run`                        Print actions only; make no changes
- `--skip-fallback`                  Don’t install fallback terminals
- `--no-color`                       Disable ANSI color in console output
- `--help`                           Show help

Logging
-------
Primary log location: `/var/log/fix-desktop-<timestamp>.log`.
If `/var/log` is not writable (container / restricted environment), a fallback log is placed under `~/log/`.

Design Notes
------------
- Idempotent where possible: re-running should not worsen state.
- Avoids purging packages; only reinstalls and resets minimal settings.
- Makes small, auditable edits (e.g. single setting in `custom.conf`).
- Respects a dry-run switch for cautious review.
- Exits on first failing command (unless intentionally guarded) for predictability.

Recovery Flow Rationale
-----------------------
1. Restore the system Python alternative because many subsequent operations depend on a functioning `python3-apt`.
2. Reinstall `python3-apt` early so that apt operations are reliable for subsequent package reinstalls.
3. Rebuild GNOME Terminal stack to ensure VTE and the terminal front-end align.
4. Reset GNOME / caches only after binaries are in a sane state.
5. Provide fallbacks so the user is not left without any graphical terminal.

When to Reboot
--------------
Required after: kernel meta update, NVIDIA driver reinstall, Wayland -> Xorg switch. Safe (but not required) otherwise.

Troubleshooting
---------------
If GNOME Terminal still fails after a successful run:
```
G_MESSAGES_DEBUG=all gnome-terminal --wait 2>&1 | tee ~/gt-debug.log
```
Review the log for GTK / VTE module load errors or schema lookup failures.

Security Considerations
-----------------------
The script only writes to:
- `/etc/gdm3/custom.conf` (conditional Wayland toggle)
- `/var/log` (or user log dir) for logging
- User cache directories it removes
- User backup directory under `~/.fix_desktop_backups`

It does not change shell profiles, network settings, or unrelated system services.

Extending
---------
Possible future enhancements (not implemented yet):
- Separate module to revert changes (undo mode)
- Optional purge of conflicting Python builds installed under `/usr/local`
- Automated capture of `journalctl -b` slices related to gnome-terminal

Contribution Guidelines
-----------------------
Open a PR with concise commits. Keep additions explicit; avoid large framework layers. Provide rationale in commit messages for any new package operations.

License
-------
See `LICENSE`.

Disclaimer
----------
Use at your own risk. Review before executing on production or irreplaceable systems.
