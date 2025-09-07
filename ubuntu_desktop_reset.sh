#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# ubuntu_desktop_reset.sh
#
# Purpose:
#   Recovery helper for a broken Ubuntu 24.04 GNOME desktop after an unsafe
#   Python 3.13 install replaced /usr/bin/python3 and broke python3-apt, GNOME
#   Terminal (VTE / GTK stack), and apt itself. Intended to be run from a TTY.
#
# Scope / What it does:
#   * Re-pins /usr/bin/python3 alternative to python3.12 (removing 3.13 alt)
#   * Reinstalls python3-apt to restore apt's python binding
#   * Reinstalls GNOME Terminal + VTE / common GTK / gsettings components
#   * Optionally disables Wayland (forces Xorg) via /etc/gdm3/custom.conf
#   * Resets GNOME interface + terminal keybinding (Ctrl+Alt+T)
#   * Cleans user caches (terminal, vte, fontconfig) + rebuilds font cache
#   * Tests GNOME Terminal launch (best-effort outside graphical session)
#   * Installs fallback terminals (kgx, tilix) if GNOME Terminal still fails
#   * Optionally reinstalls recommended NVIDIA driver
#   * Optionally installs latest kernel meta (HWE if available)
#   * Structured logging, dry-run mode, backups, idempotent changes
#
# Safety / Assumptions:
#   * Target: Ubuntu 24.04 (should work on nearby versions)
#   * Requires root (will self-elevate)
#   * Does NOT purge user data; only resets terminal dconf path + UI themes
#   * Edits only /etc/gdm3/custom.conf (adds or updates WaylandEnable=false)
#
# Usage: See --help or README.
# -----------------------------------------------------------------------------

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 022

# --------------------------- Config / Defaults -------------------------------
WITH_NVIDIA=1
FORCE_XORG=1
KERNEL_LATEST=0
DRY_RUN=0
SKIP_FALLBACK=0
COLOR=1
LOG_DIR="/var/log"
START_TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/fix-desktop-$START_TS.log"
SUDO_USER_REAL="${SUDO_USER:-$(id -un)}"
TTY_USER_HOME="$(getent passwd "$SUDO_USER_REAL" | cut -d: -f6)"
BACKUP_DIR="$TTY_USER_HOME/.fix_desktop_backups"

# --------------------------- Function Definitions ---------------------------
usage() {
  cat <<EOF
Usage: $0 [options]
  --with-nvidia / --no-nvidia    Enable/disable NVIDIA driver reinstall (default: enabled)
  --force-xorg / --no-force-xorg Force disable Wayland (default: enabled)
  --kernel-latest                Install latest GA/HWE kernel meta
  --dry-run                      Show actions only (no changes)
  --skip-fallback                Do not install fallback terminals
  --no-color                     Disable colored log output
  --help                         Show this help
Examples:
  sudo bash $0
  sudo bash $0 --kernel-latest
  sudo bash $0 --no-nvidia --dry-run
EOF
}

supports_color() { [[ -t 1 ]] && [[ ${TERM:-dumb} != dumb ]]; }

cecho() {
  local lvl="$1"; shift
  local msg="$*"
  local ts="$(date +'%F %T')"
  
  if [[ $COLOR -eq 1 ]] && supports_color; then
    case "$lvl" in
      INFO) printf '\033[1;34m[%s] %s\033[0m\n' "$lvl" "$msg" ;;
      WARN) printf '\033[1;33m[%s] %s\033[0m\n' "$lvl" "$msg" ;;
      OK)   printf '\033[1;32m[%s] %s\033[0m\n' "$lvl" "$msg" ;;
      ERR)  printf '\033[1;31m[%s] %s\033[0m\n' "$lvl" "$msg" ;;
      *)    printf '[%s] %s\n' "$lvl" "$msg" ;;
    esac
  else
    printf '[%s] %s\n' "$lvl" "$msg"
  fi
  
  # Log to file in background
  {
    printf '%s [%s] %s\n' "$ts" "$lvl" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  } &
}

run() {
  local cmd="$*"
  if [[ $DRY_RUN -eq 1 ]]; then
    cecho INFO "DRY: $cmd"
    return 0
  fi
  cecho INFO "RUN: $cmd"
  if eval "$cmd"; then
    return 0
  else
    cecho ERR "Command failed: $cmd"
    return 1
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    cecho INFO "Elevating to root..."
    exec sudo --preserve-env=WITH_NVIDIA,FORCE_XORG,KERNEL_LATEST,DRY_RUN,SKIP_FALLBACK,COLOR "$0" "$@"
  fi
}

phase() { cecho INFO "=== Phase: $* ==="; }

on_error() {
  local ec=$?
  cecho ERR "Script aborted (exit $ec) at line ${BASH_LINENO[0]}"
  cecho ERR "See log: $LOG_FILE"
  exit $ec
}

# --------------------------- Error Handling ---------------------------------
trap on_error ERR
trap 'cecho INFO "Script finished. Log: $LOG_FILE"' EXIT

# --------------------------- Argument Parsing -------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-nvidia)    WITH_NVIDIA=1 ;;
    --no-nvidia)      WITH_NVIDIA=0 ;;
    --force-xorg)     FORCE_XORG=1 ;;
    --no-force-xorg)  FORCE_XORG=0 ;;
    --kernel-latest)  KERNEL_LATEST=1 ;;
    --dry-run)        DRY_RUN=1 ;;
    --skip-fallback)  SKIP_FALLBACK=1 ;;
    --no-color)       COLOR=0 ;;
    -h|--help)        usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

# --------------------------- Pre-flight Setup -------------------------------
require_root "$@"

# Ensure log directory exists and is writable
if ! (mkdir -p "$LOG_DIR" && touch "$LOG_FILE" 2>/dev/null); then
  LOG_DIR="$TTY_USER_HOME/log"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/fix-desktop-$START_TS.log"
  touch "$LOG_FILE" || {
    echo "Cannot write log file" >&2
    exit 1
  }
fi

mkdir -p "$BACKUP_DIR" || true
export DEBIAN_FRONTEND=noninteractive

cecho INFO "Log file: $LOG_FILE"
cecho INFO "User: $SUDO_USER_REAL (home: $TTY_USER_HOME)"
cecho INFO "Dry run: $DRY_RUN"

# --------------------------- Main Script Logic -------------------------------

phase "Pre-flight checks"
if [[ -z "${DISPLAY:-}" ]]; then
  cecho WARN "DISPLAY unset (TTY). Launch test may be partial."
fi

if ! command -v apt-get >/dev/null 2>&1; then
  cecho ERR "apt-get missing; unsupported system."
  exit 1
fi

if command -v lsb_release >/dev/null 2>&1; then
  DISTRO_ID=$(lsb_release -is 2>/dev/null || echo Unknown)
  DISTRO_REL=$(lsb_release -rs 2>/dev/null || echo Unknown)
  cecho INFO "Detected distro: $DISTRO_ID $DISTRO_REL"
  [[ $DISTRO_ID != Ubuntu ]] && cecho WARN "Non-Ubuntu distribution (untested)."
else
  cecho WARN "lsb_release not installed; skipping distro identification."
fi

phase "Fix python3 alternative (prefer 3.12)"
if command -v python3.12 >/dev/null 2>&1; then
  run "update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 10"
else
  cecho WARN "python3.12 not found; cannot re-pin."
fi

if command -v python3.13 >/dev/null 2>&1; then
  if update-alternatives --display python3 2>/dev/null | grep -q '/usr/bin/python3.13'; then
    run "update-alternatives --remove python3 /usr/bin/python3.13 || true"
    cecho INFO "Removed python3.13 alternative entry."
  fi
fi
run "python3 --version || true"

phase "APT health + python3-apt reinstall"
run "apt-get update -y || true"
run "apt-get install -y --reinstall python3-apt"

phase "Reinstall GNOME Terminal stack"
run "apt-get install -y --reinstall gnome-terminal gnome-terminal-data libvte-2.91-0 libgtk-3-0 gsettings-desktop-schemas gnome-tweaks dbus-x11"

if [[ $FORCE_XORG -eq 1 ]]; then
  phase "Force Xorg (disable Wayland)"
  GDM_CONF="/etc/gdm3/custom.conf"
  if [[ -f $GDM_CONF ]]; then
    cp -a "$GDM_CONF" "$BACKUP_DIR/custom.conf.$START_TS.bak" || true
    if grep -q '^WaylandEnable=false' "$GDM_CONF"; then
      cecho OK "Wayland already disabled."
    else
      if grep -q '^#*WaylandEnable=' "$GDM_CONF"; then
        run "sed -i 's/^#*WaylandEnable=.*/WaylandEnable=false/' '$GDM_CONF'"
      else
        run "printf '\nWaylandEnable=false\n' >> '$GDM_CONF'"
      fi
      cecho INFO "Wayland disabled (reboot required)."
    fi
  else
    cecho WARN "$GDM_CONF missing; skipping."
  fi
fi

phase "Reset GNOME Terminal + theme"
if command -v gsettings >/dev/null 2>&1; then
  # Ensure dbus session is available for gsettings/dconf
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v dbus-launch >/dev/null 2>&1; then
    export $(dbus-launch)
  fi
  
  run "sudo -u '$SUDO_USER_REAL' dconf reset -f /org/gnome/terminal/ || true"
  run "sudo -u '$SUDO_USER_REAL' gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita' || true"
  run "sudo -u '$SUDO_USER_REAL' gsettings set org.gnome.desktop.interface icon-theme 'Yaru' || true"
  run "sudo -u '$SUDO_USER_REAL' gsettings set org.gnome.desktop.interface cursor-theme 'Yaru' || true"
  run "sudo -u '$SUDO_USER_REAL' gsettings set org.gnome.desktop.interface color-scheme 'default' || true"
  run "sudo -u '$SUDO_USER_REAL' gsettings set org.gnome.settings-daemon.plugins.media-keys terminal \"['<Primary><Alt>t']\" || true"
else
  cecho WARN "gsettings not found; skipping reset."
fi

phase "Clean caches"
run "rm -rf '$TTY_USER_HOME/.cache/gnome-terminal' '$TTY_USER_HOME'/.cache/vte* '$TTY_USER_HOME/.cache/fontconfig'/* 2>/dev/null || true"
run "sudo -u '$SUDO_USER_REAL' fc-cache -f || true"

phase "Test GNOME Terminal launch"
TERMINAL_OK=0
if [[ $DRY_RUN -eq 0 ]]; then
  sudo -u "$SUDO_USER_REAL" bash -c "env -u GTK_MODULES -u GTK3_MODULES LANG=en_US.UTF-8 gnome-terminal &>/dev/null &" || true
  sleep 3
  if pgrep -u "$SUDO_USER_REAL" -f gnome-terminal-server >/dev/null 2>&1; then
    cecho OK "GNOME Terminal server running."
    TERMINAL_OK=1
  else
    cecho WARN "GNOME Terminal not detected running."
  fi
else
  cecho INFO "DRY: Skipping launch."
fi

if [[ $TERMINAL_OK -eq 0 && $SKIP_FALLBACK -eq 0 ]]; then
  phase "Install fallback terminals (kgx, tilix)"
  run "apt-get install -y kgx tilix"
  if [[ $DRY_RUN -eq 0 ]]; then
    sudo -u "$SUDO_USER_REAL" bash -c "kgx &>/dev/null &" || true
    sudo -u "$SUDO_USER_REAL" bash -c "tilix &>/dev/null &" || true
  fi
fi

if [[ $WITH_NVIDIA -eq 1 ]]; then
  phase "NVIDIA driver (auto-detect recommended)"
  if ! command -v ubuntu-drivers >/dev/null 2>&1; then
    run "apt-get install -y ubuntu-drivers-common"
  fi
  REC=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3; exit}' || true)
  if [[ -n "${REC:-}" ]]; then
    cecho INFO "Recommended NVIDIA package: $REC"
    run "apt-get install -y --reinstall $REC"
  else
    cecho WARN "Recommended driver not detected."
  fi
fi

if [[ $KERNEL_LATEST -eq 1 ]]; then
  phase "Kernel latest meta install"
  REL=$(lsb_release -rs 2>/dev/null || echo "24.04")
  HWE_META="linux-generic-hwe-${REL}"
  if apt-cache policy "$HWE_META" 2>/dev/null | grep -q Candidate; then
    cecho INFO "Installing HWE kernel meta: $HWE_META"
    run "apt-get install -y $HWE_META"
  else
    cecho INFO "Installing generic kernel meta"
    run "apt-get install -y linux-generic"
  fi
fi

phase "Final diagnostics"
run "update-alternatives --display python3 || true"
run "python3 -c 'import apt_pkg; print(\"apt_pkg import OK\")' || true"
if [[ $DRY_RUN -eq 0 ]]; then
  if pgrep -u "$SUDO_USER_REAL" -f gnome-terminal-server >/dev/null; then
    cecho OK "GNOME Terminal operational."
  else
    cecho WARN "GNOME Terminal still failing; debug: G_MESSAGES_DEBUG=all gnome-terminal --wait 2>&1 | tee ~/gt-debug.log"
  fi
fi

# --------------------------- Summary ----------------------------------------
cecho INFO "Summary:"
[[ $WITH_NVIDIA -eq 1 ]] && cecho INFO " - NVIDIA driver processed"
[[ $FORCE_XORG -eq 1 ]] && cecho INFO " - Wayland disabled (reboot to apply)"
[[ $KERNEL_LATEST -eq 1 ]] && cecho INFO " - Kernel meta updated (reboot required)"
[[ $DRY_RUN -eq 1 ]] && cecho INFO " - DRY RUN (no changes applied)"
[[ $TERMINAL_OK -eq 1 ]] && cecho INFO " - GNOME Terminal launch test: OK" || cecho INFO " - GNOME Terminal launch test: NOT CONFIRMED"
cecho INFO "Reboot recommended if NVIDIA, kernel, or Xorg changes were applied." || true
exit 0