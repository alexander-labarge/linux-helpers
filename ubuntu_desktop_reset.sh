#!/usr/bin/env bash
# Ubuntu 24.04.3 GNOME desktop repair & reset helper
# Features:
#  - Fix python3 alternative (forces 3.12 if 3.13 caused apt issues)
#  - Repair apt python bindings
#  - Reinstall GNOME Terminal / VTE stack
#  - Reset themes to Adwaita, restore Ctrl+Alt+T
#  - Force Xorg (disable Wayland) if requested
#  - Optional NVIDIA driver (auto-detected) reinstall
#  - Optional latest kernel meta package install
#  - Provides fallback terminals (kgx, tilix)
#  - Structured logging + dry-run

set -euo pipefail

########################################
# Config / Defaults
WITH_NVIDIA=1
FORCE_XORG=1
KERNEL_LATEST=0
DRY_RUN=0
SKIP_FALLBACK=0
LOG_DIR="/var/log"
START_TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/fix-desktop-$START_TS.log"
SUDO_USER_REAL="${SUDO_USER:-$(id -un)}"
TTY_USER_HOME="$(getent passwd "$SUDO_USER_REAL" | cut -d: -f6)"
BACKUP_DIR="$TTY_USER_HOME/.fix_desktop_backups"
COLOR=1

########################################
usage() {
  cat <<EOF
Usage: $0 [options]
  --with-nvidia / --no-nvidia    Enable/disable NVIDIA driver reinstall (default: enabled)
  --force-xorg / --no-force-xorg Force disable Wayland (default: enabled)
  --kernel-latest                Install latest GA/HWE kernel meta
  --dry-run                      Show actions only
  --skip-fallback                Do not install fallback terminals
  --no-color                     Disable colored log output
  --help                         Show this help
Examples:
  sudo bash $0
  sudo bash $0 --kernel-latest
  sudo bash $0 --no-nvidia --dry-run
EOF
}

########################################
# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-nvidia) WITH_NVIDIA=1 ;;
    --no-nvidia) WITH_NVIDIA=0 ;;
    --force-xorg) FORCE_XORG=1 ;;
    --no-force-xorg) FORCE_XORG=0 ;;
    --kernel-latest) KERNEL_LATEST=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-fallback) SKIP_FALLBACK=1 ;;
    --no-color) COLOR=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

########################################
# Logging helpers
cecho() {
  local lvl="$1"; shift
  local msg="$*"
  local ts
  ts="$(date +'%F %T')"
  [[ $COLOR -eq 1 ]] && case "$lvl" in
    INFO) printf "\033[1;34m[%s] %s\033[0m\n" "$lvl" "$msg" ;;
    WARN) printf "\033[1;33m[%s] %s\033[0m\n" "$lvl" "$msg" ;;
    OK)   printf "\033[1;32m[%s] %s\033[0m\n" "$lvl" "$msg" ;;
    ERR)  printf "\033[1;31m[%s] %s\033[0m\n" "$lvl" "$msg" ;;
    *)    printf "[%s] %s\n" "$lvl" "$msg" ;;
  esac || printf "[%s] %s\n" "$lvl" "$msg"
  printf "%s [%s] %s\n" "$ts" "$lvl" "$msg" >>"$LOG_FILE" 2>/dev/null || true
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

trap 'cecho ERR "Script aborted (line $LINENO). See $LOG_FILE"; exit 1' INT TERM
trap 'cecho INFO "Script finished. Log: $LOG_FILE"' EXIT

require_root "$@"
mkdir -p "$BACKUP_DIR" || true
touch "$LOG_FILE" 2>/dev/null || { echo "Cannot write log $LOG_FILE"; exit 1; }

cecho INFO "Log file: $LOG_FILE"
cecho INFO "User context: $SUDO_USER_REAL (home: $TTY_USER_HOME)"

########################################
phase() { cecho INFO "=== Phase: $* ==="; }

########################################
phase "Pre-flight checks"
if [[ -z "${DISPLAY:-}" ]]; then
  cecho WARN "DISPLAY not set. Running outside graphical session; GNOME Terminal launch test may fail."
fi
if ! command -v apt-get &>/dev/null; then
  cecho ERR "apt-get not found. Unsupported environment."
  exit 1
fi

########################################
phase "Fix python3 alternative (prefer 3.12)"
if command -v python3.12 &>/dev/null; then
  run "update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 10"
fi
if command -v python3.13 &>/dev/null; then
  if update-alternatives --display python3 2>/dev/null | grep -q '/usr/bin/python3.13'; then
    run "update-alternatives --remove python3 /usr/bin/python3.13 || true"
  fi
fi
run "python3 --version || true"

########################################
phase "APT health + python3-apt reinstall"
run "apt-get update -y || true"
run "apt-get install -y --reinstall python3-apt"

########################################
phase "Reinstall GNOME Terminal stack"
run "apt-get install -y --reinstall gnome-terminal gnome-terminal-data libvte-2.91-0 libgtk-3-0 gsettings-desktop-schemas gnome-tweaks"

########################################
if [[ $FORCE_XORG -eq 1 ]]; then
  phase "Force Xorg (disable Wayland)"
  GDM_CONF="/etc/gdm3/custom.conf"
  if [[ -f $GDM_CONF ]]; then
    cp -a "$GDM_CONF" "$BACKUP_DIR/custom.conf.$START_TS.bak" || true
    if grep -q '^WaylandEnable=false' "$GDM_CONF"; then
      cecho OK "Wayland already disabled in $GDM_CONF"
    else
      if grep -q '^#*WaylandEnable=' "$GDM_CONF"; then
        run "sed -i 's/^#*WaylandEnable=.*/WaylandEnable=false/' $GDM_CONF"
      else
        run "printf '\\nWaylandEnable=false\\n' >> $GDM_CONF"
      fi
      cecho INFO "Wayland disabled (reboot to apply)."
    fi
  else
    cecho WARN "$GDM_CONF not found; skipping Xorg enforcement."
  fi
fi

########################################
phase "Reset GNOME Terminal + theme"
run "dconf reset -f /org/gnome/terminal/ || true"
run "gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita'"
run "gsettings set org.gnome.desktop.interface icon-theme 'Yaru' || true"
run "gsettings set org.gnome.desktop.interface cursor-theme 'Yaru' || true"
run "gsettings set org.gnome.desktop.interface color-scheme 'default' || true"
run "gsettings set org.gnome.settings-daemon.plugins.media-keys terminal '<Primary><Alt>t'"

########################################
phase "Clean caches"
run "rm -rf $TTY_USER_HOME/.cache/gnome-terminal $TTY_USER_HOME/.cache/vte* $TTY_USER_HOME/.cache/fontconfig/* 2>/dev/null || true"
run "sudo -u $SUDO_USER_REAL fc-cache -f || true"

########################################
phase "Test GNOME Terminal launch"
if [[ $DRY_RUN -eq 0 ]]; then
  sudo -u "$SUDO_USER_REAL" bash -c "env -u GTK_MODULES -u GTK3_MODULES LANG=en_US.UTF-8 gnome-terminal &>/dev/null &"
  sleep 3
  if pgrep -u "$SUDO_USER_REAL" -f gnome-terminal-server >/dev/null 2>&1; then
    cecho OK "GNOME Terminal server is running."
    TERMINAL_OK=1
  else
    cecho WARN "GNOME Terminal not persisting."
    TERMINAL_OK=0
  fi
else
  cecho INFO "DRY: Skipping actual launch."
  TERMINAL_OK=0
fi

########################################
if [[ $TERMINAL_OK -eq 0 && $SKIP_FALLBACK -eq 0 ]]; then
  phase "Install fallback terminals (kgx, tilix)"
  run "apt-get install -y kgx tilix"
  if [[ $DRY_RUN -eq 0 ]]; then
    sudo -u "$SUDO_USER_REAL" bash -c "kgx &>/dev/null &" || true
    sudo -u "$SUDO_USER_REAL" bash -c "tilix &>/dev/null &" || true
  fi
fi

########################################
if [[ $WITH_NVIDIA -eq 1 ]]; then
  phase "NVIDIA driver (auto-detect recommended)"
  if ! command -v ubuntu-drivers &>/dev/null; then
    run "apt-get install -y ubuntu-drivers-common"
  fi
  REC=$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ {print $3; exit}' || true)
  if [[ -n "${REC:-}" ]]; then
    cecho INFO "Recommended NVIDIA package: $REC"
    run "apt-get install -y --reinstall $REC"
  else
    cecho WARN "Could not auto-detect recommended driver (maybe no NVIDIA GPU?)."
  fi
fi

########################################
if [[ $KERNEL_LATEST -eq 1 ]]; then
  phase "Kernel latest meta install"
  # Detect release
  REL=$(lsb_release -rs 2>/dev/null || echo "24.04")
  # Candidate order: linux-generic-hwe-24.04 (if exists) else linux-generic
  HWE_META="linux-generic-hwe-${REL}"
  if apt-cache policy "$HWE_META" 2>/dev/null | grep -q Candidate; then
    cecho INFO "Installing HWE kernel meta: $HWE_META"
    run "apt-get install -y $HWE_META"
  else
    cecho INFO "Installing generic kernel meta"
    run "apt-get install -y linux-generic"
  fi
fi

########################################
phase "Final diagnostics"
run "update-alternatives --display python3 || true"
run "python3 -c 'import apt_pkg; print(\"apt_pkg import OK\")'"
if [[ $DRY_RUN -eq 0 ]]; then
  if pgrep -u "$SUDO_USER_REAL" -f gnome-terminal-server >/dev/null; then
    cecho OK "GNOME Terminal operational."
  else
    cecho WARN "GNOME Terminal still failing; capture debug with:
      G_MESSAGES_DEBUG=all gnome-terminal --wait 2>&1 | tee \$HOME/gt-debug.log"
  fi
fi

cecho INFO "Summary:"
[[ $WITH_NVIDIA -eq 1 ]] && cecho INFO " - NVIDIA driver processed"
[[ $FORCE_XORG -eq 1 ]] && cecho INFO " - Wayland disabled (reboot to apply)"
[[ $KERNEL_LATEST -eq 1 ]] && cecho INFO " - Kernel meta installed/updated (reboot required)"
[[ $DRY_RUN -eq 1 ]] && cecho INFO " - DRY RUN (no changes applied)"

cecho INFO "Reboot recommended if NVIDIA driver, kernel, or Xorg changes were applied."
exit 0