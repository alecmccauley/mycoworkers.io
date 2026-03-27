#!/usr/bin/env bash
set -euo pipefail

# This script prepares a fresh Apple Silicon Mac mini to act as a hardened,
# server-first Colima container host.
#
# What this script does:
# - installs the command-line tooling needed to run Colima
# - applies a conservative set of host optimizations from the source Mac mini
#   deployment document
# - starts Colima with Apple-native virtualization settings
# - creates one persistent ARM-native work container
# - installs a LaunchAgent that restores Colima and the work container at login
#
# What this script does NOT do:
# - it does NOT install Docker Desktop
# - it does NOT install Rosetta
# - it does NOT configure OpenClaw itself
# - it does NOT create Google Chat, Cloudflare, or tenant-specific config
# - it does NOT enable auto-login for you; that remains a manual security choice
#
# Why the Docker CLI is still installed:
# - Colima is the runtime and Linux VM
# - the Docker CLI is only the client used to talk to Colima's Docker-compatible
#   API from macOS
#
# About the default image:
# - the default image reference is alpine/openclaw:latest
# - despite the repository name, Docker Hub currently notes that the image is
#   Debian-based
# - this script only keeps that image running as a generic ARM-native work box
#
# Why auto-login matters:
# - a user LaunchAgent only runs after a user session starts
# - if you require the container to come back after reboot without manual action,
#   the dedicated local service user must auto-login on boot

DRY_RUN=0
HOSTNAME_VALUE=""
WORKSPACE_ROOT="${HOME}/workspace"
CONTAINER_NAME="workbox"
IMAGE="alpine/openclaw:latest"
COLIMA_CPU="4"
COLIMA_MEMORY="8"
COLIMA_DISK="80"
SKIP_MACOS_UPDATE=0

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
DEFAULT_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
STATE_DIR="${HOME}/.config/mac-mini-colima"

# These paths are derived from the selected container name so multiple copies of
# the script can be used safely with different work containers if needed.
WRAPPER_PATH=""
LAUNCHAGENT_PATH=""
LAUNCHAGENT_LABEL=""
LAUNCH_LOG_PATH=""

usage() {
  cat <<'EOF'
Usage:
  ./mac-mini-colima-bootstrap.sh [options]

Options:
  --dry-run                 Print actions without making changes.
  --hostname <name>         Set ComputerName, HostName, and LocalHostName.
  --workspace-root <path>   Host directory to bind-mount into the container.
                            Default: $HOME/workspace
  --container-name <name>   Name of the persistent work container.
                            Default: workbox
  --image <ref>             ARM-native image to use for the persistent container.
                            Default: alpine/openclaw:latest
  --colima-cpu <n>          CPU count for Colima.
                            Default: 4
  --colima-memory <gb>      Memory in GB for Colima.
                            Default: 8
  --colima-disk <gb>        Disk size in GB for Colima.
                            Default: 80
  --skip-macos-update       Skip softwareupdate -ia.
  --help                    Show this help text.
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# run_cmd executes a normal command, or just prints it when --dry-run is active.
run_cmd() {
  log "+ $*"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    "$@"
  fi
}

# run_sudo is identical to run_cmd but prepends sudo so the intent stays obvious
# at call sites.
run_sudo() {
  run_cmd sudo "$@"
}

# write_file writes a file with supplied content. The content is passed through
# stdin so we can preserve formatting and comments exactly.
write_file() {
  local target="$1"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "+ write file ${target}"
    cat >/dev/null
    return
  fi
  mkdir -p "$(dirname "${target}")"
  cat >"${target}"
}

# write_file_if_missing only creates a file the first time. This helps keep the
# script idempotent when rerun on the same host.
write_file_if_missing() {
  local target="$1"
  if [[ -e "${target}" ]]; then
    log "File already exists, leaving it in place: ${target}"
    cat >/dev/null
    return
  fi
  write_file "${target}"
}

ensure_line_in_file() {
  local line="$1"
  local file="$2"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "+ ensure line in ${file}: ${line}"
    return
  fi
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  if ! grep -Fqx "${line}" "${file}"; then
    printf '%s\n' "${line}" >>"${file}"
  fi
}

wait_for_docker() {
  local attempts=30
  local delay_seconds=2
  local i

  for ((i = 1; i <= attempts; i++)); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay_seconds}"
  done

  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --hostname)
        [[ $# -ge 2 ]] || die "--hostname requires a value"
        HOSTNAME_VALUE="$2"
        shift 2
        ;;
      --workspace-root)
        [[ $# -ge 2 ]] || die "--workspace-root requires a value"
        WORKSPACE_ROOT="$2"
        shift 2
        ;;
      --container-name)
        [[ $# -ge 2 ]] || die "--container-name requires a value"
        CONTAINER_NAME="$2"
        shift 2
        ;;
      --image)
        [[ $# -ge 2 ]] || die "--image requires a value"
        IMAGE="$2"
        shift 2
        ;;
      --colima-cpu)
        [[ $# -ge 2 ]] || die "--colima-cpu requires a value"
        COLIMA_CPU="$2"
        shift 2
        ;;
      --colima-memory)
        [[ $# -ge 2 ]] || die "--colima-memory requires a value"
        COLIMA_MEMORY="$2"
        shift 2
        ;;
      --colima-disk)
        [[ $# -ge 2 ]] || die "--colima-disk requires a value"
        COLIMA_DISK="$2"
        shift 2
        ;;
      --skip-macos-update)
        SKIP_MACOS_UPDATE=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

derive_paths() {
  LAUNCHAGENT_LABEL="com.coworkers.colima.${CONTAINER_NAME}"
  WRAPPER_PATH="${HOME}/bin/start-colima-${CONTAINER_NAME}.sh"
  LAUNCHAGENT_PATH="${HOME}/Library/LaunchAgents/${LAUNCHAGENT_LABEL}.plist"
  LAUNCH_LOG_PATH="${HOME}/Library/Logs/${LAUNCHAGENT_LABEL}.log"
}

preflight_checks() {
  log "Running preflight checks"

  [[ "$(uname -s)" == "Darwin" ]] || die "This script only supports macOS."
  [[ "$(uname -m)" == "arm64" ]] || die "This script only supports Apple Silicon Macs."
  [[ "${EUID}" -ne 0 ]] || die "Run this script as your local admin user, not as root."

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    sudo -v
  else
    log "+ sudo -v"
  fi

  if [[ -z "${CURRENT_USER}" || "${CURRENT_USER}" == "root" ]]; then
    die "Could not determine a safe non-root user context."
  fi

  local autologin_user=""
  autologin_user="$(sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
  if [[ -z "${autologin_user}" ]]; then
    warn "Automatic login does not appear to be enabled. Unattended reboot recovery will not work until you enable it for ${CURRENT_USER}."
  elif [[ "${autologin_user}" != "${CURRENT_USER}" ]]; then
    warn "Automatic login is configured for ${autologin_user}, not ${CURRENT_USER}. The LaunchAgent in this guide is tied to the current user."
  else
    log "Automatic login appears to be configured for the current user."
  fi

  local filevault_status=""
  filevault_status="$(fdesetup status 2>/dev/null || true)"
  if printf '%s' "${filevault_status}" | grep -qi "FileVault is On"; then
    warn "FileVault appears to be enabled. On macOS, FileVault typically prevents automatic login, which conflicts with unattended reboot recovery."
  fi
}

install_command_line_tools() {
  if xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools are already installed."
    return
  fi

  log "Installing Xcode Command Line Tools"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "+ touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    log "+ softwareupdate -l"
    log "+ softwareupdate -i '<latest Command Line Tools package>'"
    log "+ xcode-select -switch /Library/Developer/CommandLineTools"
    return
  fi

  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  local clt_package=""
  clt_package="$(softwareupdate -l 2>/dev/null | awk -F'*' '/Command Line Tools/ {print $2}' | sed 's/^ *//' | tail -n 1)"
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

  [[ -n "${clt_package}" ]] || die "Could not find a Command Line Tools package via softwareupdate."

  sudo softwareupdate -i "${clt_package}" --verbose
  sudo xcode-select -switch /Library/Developer/CommandLineTools
}

ensure_homebrew() {
  if command_exists brew; then
    log "Homebrew is already installed."
  else
    log "Installing Homebrew"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "+ /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    else
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
  fi

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    ensure_line_in_file 'eval "$(/opt/homebrew/bin/brew shellenv)"' "${HOME}/.zprofile"
  elif command_exists brew; then
    eval "$(brew shellenv)"
  else
    die "Homebrew was not installed correctly."
  fi
}

brew_install_formula() {
  local formula="$1"
  if brew list "${formula}" >/dev/null 2>&1; then
    log "Homebrew formula already installed: ${formula}"
  else
    run_cmd brew install "${formula}"
  fi
}

set_hostnames() {
  if [[ -z "${HOSTNAME_VALUE}" ]]; then
    log "No hostname was provided. Leaving macOS names unchanged."
    return
  fi

  log "Setting system hostnames to ${HOSTNAME_VALUE}"
  run_sudo scutil --set ComputerName "${HOSTNAME_VALUE}"
  run_sudo scutil --set HostName "${HOSTNAME_VALUE}"
  run_sudo scutil --set LocalHostName "${HOSTNAME_VALUE}"
}

apply_power_settings() {
  log "Applying server-first power settings"

  run_sudo systemsetup -setrestartpowerfailure on
  run_sudo pmset -a disablesleep 1
  run_sudo pmset -a sleep 0
  run_sudo pmset -a displaysleep 0
  run_sudo pmset -a disksleep 0
  run_sudo pmset -a powernap 0
  run_sudo pmset -a networkoversleep 1
}

apply_ui_defaults() {
  log "Reducing animation and transparency overhead"

  run_cmd defaults write NSGlobalDomain AppleReduceMotion -bool true
  run_cmd defaults write NSGlobalDomain AppleReduceTransparency -bool true
  run_cmd defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
  run_cmd defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
  run_cmd defaults write NSGlobalDomain NSScrollAnimationEnabled -bool false
  run_cmd defaults write com.apple.finder DisableAllAnimations -bool true
  run_cmd defaults write com.apple.dock expose-animation-duration -float 0.1
  run_cmd defaults write com.apple.dock autohide-time-modifier -float 0

  # Restarting Dock and Finder applies the preference changes immediately for
  # the current session. These commands are harmless if the processes are not
  # currently running.
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "+ killall Dock"
    log "+ killall Finder"
  else
    killall Dock >/dev/null 2>&1 || true
    killall Finder >/dev/null 2>&1 || true
  fi
}

disable_spotlight() {
  log "Disabling Spotlight indexing to reduce background I/O"
  run_sudo mdutil -a -i off
}

enable_firewall() {
  log "Enabling the macOS application firewall and stealth mode"
  run_sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
  run_sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
}

run_macos_updates() {
  if [[ "${SKIP_MACOS_UPDATE}" -eq 1 ]]; then
    log "Skipping macOS software updates because --skip-macos-update was passed."
    return
  fi

  log "Checking for available macOS software updates"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "+ softwareupdate -l"
    log "+ softwareupdate -ia --verbose"
    return
  fi

  local update_output
  update_output="$(softwareupdate -l 2>&1 || true)"
  if printf '%s' "${update_output}" | grep -q "No new software available"; then
    log "No macOS software updates are currently available."
    return
  fi

  sudo softwareupdate -ia --verbose
}

start_colima() {
  log "Ensuring Colima is running with Apple-native settings"

  if colima status >/dev/null 2>&1; then
    log "Colima is already running."
  else
    run_cmd colima start \
      --cpu "${COLIMA_CPU}" \
      --memory "${COLIMA_MEMORY}" \
      --disk "${COLIMA_DISK}" \
      --vm-type vz \
      --mount-type virtiofs
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "+ docker context use colima"
    log "+ docker info"
    return
  fi

  docker context use colima >/dev/null 2>&1 || true

  if ! wait_for_docker; then
    die "Docker did not become ready after starting Colima."
  fi

  docker info >/dev/null
}

prepare_workspace() {
  log "Preparing the host workspace mount"
  run_cmd mkdir -p "${WORKSPACE_ROOT}"

  write_file_if_missing "${WORKSPACE_ROOT}/README-host-workspace.txt" <<EOF
This directory lives on the macOS host.

It is bind-mounted into the persistent work container at:
  /workspace

That means:
- files created here on macOS show up inside the container
- files created inside the container under /workspace show up here on macOS

This guide intentionally stops at a ready-to-work container host.
No OpenClaw application configuration is created here.
EOF
}

container_exists() {
  docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]
}

ensure_work_container() {
  log "Ensuring the persistent work container exists and is running"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "+ docker pull --platform linux/arm64 ${IMAGE}"
    log "+ docker create --name ${CONTAINER_NAME} --restart unless-stopped --platform linux/arm64 ..."
    log "+ docker start ${CONTAINER_NAME}"
    return
  fi

  docker pull --platform linux/arm64 "${IMAGE}"

  if container_exists; then
    local current_image=""
    local current_mount=""
    local current_restart=""

    current_image="$(docker inspect -f '{{.Config.Image}}' "${CONTAINER_NAME}")"
    current_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "${CONTAINER_NAME}")"
    current_restart="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${CONTAINER_NAME}")"

    if [[ "${current_image}" != "${IMAGE}" ]]; then
      warn "Container ${CONTAINER_NAME} already exists with image ${current_image}. Leaving it in place."
    fi
    if [[ "${current_mount}" != "${WORKSPACE_ROOT}" ]]; then
      warn "Container ${CONTAINER_NAME} already mounts ${current_mount} at /workspace, not ${WORKSPACE_ROOT}. Leaving it in place."
    fi
    if [[ "${current_restart}" != "unless-stopped" ]]; then
      warn "Container ${CONTAINER_NAME} restart policy is ${current_restart}, not unless-stopped. Leaving it in place."
    fi

    if container_running; then
      log "Container ${CONTAINER_NAME} is already running."
    else
      run_cmd docker start "${CONTAINER_NAME}"
    fi
    return
  fi

  run_cmd docker create \
    --name "${CONTAINER_NAME}" \
    --platform linux/arm64 \
    --restart unless-stopped \
    --workdir /workspace \
    --mount "type=bind,src=${WORKSPACE_ROOT},dst=/workspace" \
    --entrypoint sh \
    "${IMAGE}" \
    -c 'while true; do sleep 3600; done'

  run_cmd docker start "${CONTAINER_NAME}"
}

write_wrapper_script() {
  log "Writing the Colima/container restore wrapper script"

  write_file "${WRAPPER_PATH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# This wrapper is executed by launchd after login.
# Its job is simple:
# 1. make sure Colima is running
# 2. wait for the Docker API to become reachable
# 3. make sure the persistent work container exists
# 4. start the work container if it is stopped

PATH="${DEFAULT_PATH}"

CONTAINER_NAME="${CONTAINER_NAME}"
IMAGE="${IMAGE}"
WORKSPACE_ROOT="${WORKSPACE_ROOT}"
COLIMA_CPU="${COLIMA_CPU}"
COLIMA_MEMORY="${COLIMA_MEMORY}"
COLIMA_DISK="${COLIMA_DISK}"

wait_for_docker() {
  local attempts=30
  local delay_seconds=2
  local i

  for ((i = 1; i <= attempts; i++)); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep "\${delay_seconds}"
  done

  return 1
}

if ! colima status >/dev/null 2>&1; then
  colima start \\
    --cpu "\${COLIMA_CPU}" \\
    --memory "\${COLIMA_MEMORY}" \\
    --disk "\${COLIMA_DISK}" \\
    --vm-type vz \\
    --mount-type virtiofs
fi

docker context use colima >/dev/null 2>&1 || true
wait_for_docker

mkdir -p "\${WORKSPACE_ROOT}"

if ! docker container inspect "\${CONTAINER_NAME}" >/dev/null 2>&1; then
  docker pull --platform linux/arm64 "\${IMAGE}"
  docker create \\
    --name "\${CONTAINER_NAME}" \\
    --platform linux/arm64 \\
    --restart unless-stopped \\
    --workdir /workspace \\
    --mount "type=bind,src=\${WORKSPACE_ROOT},dst=/workspace" \\
    --entrypoint sh \\
    "\${IMAGE}" \\
    -c 'while true; do sleep 3600; done'
fi

if [[ "\$(docker inspect -f '{{.State.Running}}' "\${CONTAINER_NAME}" 2>/dev/null || true)" != "true" ]]; then
  docker start "\${CONTAINER_NAME}" >/dev/null
fi
EOF

  run_cmd chmod +x "${WRAPPER_PATH}"
}

write_launchagent() {
  log "Writing the user LaunchAgent that restores Colima and the work container at login"

  write_file "${LAUNCHAGENT_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${LAUNCHAGENT_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
      <string>${WRAPPER_PATH}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>300</integer>

    <key>StandardOutPath</key>
    <string>${LAUNCH_LOG_PATH}</string>

    <key>StandardErrorPath</key>
    <string>${LAUNCH_LOG_PATH}</string>
  </dict>
</plist>
EOF

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "+ launchctl bootout gui/${CURRENT_UID} ${LAUNCHAGENT_PATH}"
    log "+ launchctl bootstrap gui/${CURRENT_UID} ${LAUNCHAGENT_PATH}"
    log "+ launchctl kickstart -k gui/${CURRENT_UID}/${LAUNCHAGENT_LABEL}"
    return
  fi

  launchctl bootout "gui/${CURRENT_UID}" "${LAUNCHAGENT_PATH}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${CURRENT_UID}" "${LAUNCHAGENT_PATH}"
  launchctl kickstart -k "gui/${CURRENT_UID}/${LAUNCHAGENT_LABEL}" >/dev/null 2>&1 || true
}

print_summary() {
  cat <<EOF

Setup complete.

What changed:
- macOS host tuning was applied for headless, server-first operation
- Colima was installed and started
- Docker CLI was installed and pointed at Colima
- Host workspace prepared at: ${WORKSPACE_ROOT}
- Persistent work container ensured: ${CONTAINER_NAME}
- LaunchAgent installed at: ${LAUNCHAGENT_PATH}
- Restore wrapper installed at: ${WRAPPER_PATH}

What remains manual:
- confirm automatic login is enabled for ${CURRENT_USER}
- confirm FileVault settings align with unattended reboot needs
- reboot the Mac mini and validate recovery end-to-end

Useful verification commands:
  pmset -g
  sudo systemsetup -getrestartpowerfailure
  sudo mdutil -s /
  colima status
  docker info
  docker ps

Shell into the running container:
  docker exec -it ${CONTAINER_NAME} bash

If bash is unavailable in the image:
  docker exec -it ${CONTAINER_NAME} sh

EOF
}

main() {
  parse_args "$@"
  derive_paths

  preflight_checks
  install_command_line_tools
  ensure_homebrew

  brew_install_formula colima
  brew_install_formula docker
  brew_install_formula docker-compose
  brew_install_formula jq
  brew_install_formula git

  set_hostnames
  apply_power_settings
  apply_ui_defaults
  disable_spotlight
  enable_firewall
  run_macos_updates

  start_colima
  prepare_workspace
  ensure_work_container

  run_cmd mkdir -p "${STATE_DIR}"
  write_wrapper_script
  write_launchagent
  print_summary
}

main "$@"
