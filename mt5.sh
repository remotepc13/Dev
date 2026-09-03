#!/usr/bin/env bash

# ============================================================================
# MT5 Cloud Desktop for GitHub Actions
#
# Host:
#   GitHub Ubuntu 24.04
#
# Container:
#   ghcr.io/gmag11/metatrader5-docker:2.3
#
# Provides:
#   - MetaTrader 5
#   - Wine
#   - KasmVNC browser desktop
#   - mt5linux server
#   - Cloudflare Quick Tunnel
#
# Design:
#   - No custom Docker image
#   - No GitHub Actions cache
#   - Session-local /config
#   - KasmVNC exposed only through localhost + Cloudflare
#   - mt5linux port remains private
#   - Maximum session: 300 minutes
#
# ============================================================================

set -Eeuo pipefail


# ============================================================================
# Paths
# ============================================================================

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

LOG_DIR="${ROOT_DIR}/logs"
TUNNEL_DIR="${ROOT_DIR}/tunnel"
DATA_DIR="${ROOT_DIR}/mt5_data"
RUNTIME_DIR="${ROOT_DIR}/.mt5-runtime"

mkdir -p \
  "${LOG_DIR}" \
  "${TUNNEL_DIR}" \
  "${DATA_DIR}" \
  "${RUNTIME_DIR}"


# ============================================================================
# Main log
# ============================================================================

MAIN_LOG="${LOG_DIR}/mt5-runtime.log"

exec > >(tee -a "${MAIN_LOG}") 2>&1


# ============================================================================
# Configuration
# ============================================================================

CONTAINER_NAME="${CONTAINER_NAME:-mt5-cloud}"

MT5_IMAGE="${MT5_IMAGE:-ghcr.io/gmag11/metatrader5-docker:2.3}"


# KasmVNC
WEB_BIND="${MT5_WEB_BIND:-127.0.0.1}"
WEB_PORT="${MT5_WEB_PORT:-3000}"

# mt5linux / RPyC
API_BIND="${MT5_API_BIND:-127.0.0.1}"
API_PORT="${MT5_API_PORT:-8001}"


# KasmVNC authentication
WEB_USER="${MT5_WEB_USER:-trader}"
WEB_PASSWORD="${MT5_WEB_PASSWORD:-MT5-Demo-2026-StrongPassword!}"


# Desktop
RESOLUTION="${MT5_RESOLUTION:-1920x1080}"


# Session
SESSION_MINUTES="${MT5_SESSION_MINUTES:-60}"


# Options
ENABLE_TUNNEL="${MT5_ENABLE_TUNNEL:-true}"
SAVE_ARTIFACTS="${MT5_SAVE_ARTIFACTS:-true}"
CLEAN_WORKSPACE="${MT5_CLEAN_WORKSPACE:-false}"


# Timeouts
TCP_TIMEOUT="${MT5_TCP_TIMEOUT:-120}"
HTTP_TIMEOUT="${MT5_HTTP_TIMEOUT:-180}"
TUNNEL_TIMEOUT="${MT5_TUNNEL_TIMEOUT:-120}"
CHECK_INTERVAL="${MT5_CHECK_INTERVAL:-3}"


# Optional MT5 command line options
MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"


# mt5linux current server release
MT5LINUX_VERSION="${MT5LINUX_VERSION:-1.1.1}"

# Current standalone mt5server release
MT5SERVER_TAG="${MT5SERVER_TAG:-server-1.1.1}"


# Runtime generated script
CONTAINER_START_SCRIPT="${RUNTIME_DIR}/start.sh"


# Logs
CONTAINER_LOG="${LOG_DIR}/container.log"
CLOUDFLARE_LOG="${TUNNEL_DIR}/cloudflared.log"
TUNNEL_URL_FILE="${TUNNEL_DIR}/tunnel-url.txt"

MT5SERVER_LOG="${LOG_DIR}/mt5server.log"
MT5_INSTALL_LOG="${LOG_DIR}/mt5-install.log"
WINEBOOT_LOG="${LOG_DIR}/wineboot.log"
PYTHON_LOG="${LOG_DIR}/python-install.log"


# Cloudflare process
CLOUDFLARE_PID=""


# ============================================================================
# Helpers
# ============================================================================

timestamp() {
  date -u '+%Y-%m-%d %H:%M:%S UTC'
}


log() {
  echo "[$(timestamp)] $*"
}


section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}


die() {
  echo
  echo "❌ ERROR: $*"
  exit 1
}


# ============================================================================
# Error handler
# ============================================================================

on_error() {

  local rc="$?"
  local line="${1:-unknown}"
  local command="${2:-unknown}"

  echo
  echo "============================================================"
  echo "❌ Runtime error"
  echo "============================================================"
  echo "Exit code : ${rc}"
  echo "Line      : ${line}"
  echo "Command   : ${command}"
  echo "============================================================"

  if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then

    echo
    echo "---------------- Container state ----------------"

    docker inspect \
      "${CONTAINER_NAME}" \
      --format \
      'Running={{.State.Running}} Status={{.State.Status}} ExitCode={{.State.ExitCode}} Error={{.State.Error}}' \
      || true

    echo
    echo "---------------- Container logs ----------------"

    docker logs \
      --tail 500 \
      "${CONTAINER_NAME}" \
      || true

  fi

  return "${rc}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR


# ============================================================================
# Cleanup
# ============================================================================

cleanup() {

  local rc=$?

  trap - ERR
  trap - EXIT


  section "🧹 Cleanup"


  # --------------------------------------------------------------------------
  # Cloudflare
  # --------------------------------------------------------------------------

  if [[ -n "${CLOUDFLARE_PID}" ]]; then

    if kill -0 "${CLOUDFLARE_PID}" 2>/dev/null; then

      log "Stopping Cloudflare..."

      kill \
        "${CLOUDFLARE_PID}" \
        >/dev/null 2>&1 \
        || true

      sleep 2

      kill -9 \
        "${CLOUDFLARE_PID}" \
        >/dev/null 2>&1 \
        || true

    fi

  fi


  # --------------------------------------------------------------------------
  # Container
  # --------------------------------------------------------------------------

  if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then

    log "Stopping MT5 container..."

    docker stop \
      --timeout 20 \
      "${CONTAINER_NAME}" \
      >/dev/null 2>&1 \
      || true


    log "Removing MT5 container..."

    docker rm \
      -f \
      "${CONTAINER_NAME}" \
      >/dev/null 2>&1 \
      || true

  fi


  echo
  echo "============================================================"
  echo "🏁 Cleanup completed"
  echo "Exit code: ${rc}"
  echo "============================================================"


  exit "${rc}"
}

trap cleanup EXIT


# ============================================================================
# Validate configuration
# ============================================================================

validate_config() {

  section "🔎 Validate configuration"


  # Session
  if ! [[ "${SESSION_MINUTES}" =~ ^[0-9]+$ ]]; then
    die "SESSION_MINUTES must be numeric."
  fi


  if (( SESSION_MINUTES < 15 )); then
    die "Minimum session duration is 15 minutes."
  fi


  if (( SESSION_MINUTES > 300 )); then
    die "Maximum session duration is 300 minutes."
  fi


  # Resolution
  case "${RESOLUTION}" in

    1920x1080|1600x900|1280x720)
      ;;

    *)
      die "Unsupported resolution: ${RESOLUTION}"
      ;;

  esac


  # Boolean values
  case "${ENABLE_TUNNEL}" in
    true|false)
      ;;
    *)
      die "MT5_ENABLE_TUNNEL must be true or false."
      ;;
  esac


  case "${SAVE_ARTIFACTS}" in
    true|false)
      ;;
    *)
      die "MT5_SAVE_ARTIFACTS must be true or false."
      ;;
  esac


  case "${CLEAN_WORKSPACE}" in
    true|false)
      ;;
    *)
      die "MT5_CLEAN_WORKSPACE must be true or false."
      ;;
  esac


  echo "Image       : ${MT5_IMAGE}"
  echo "Resolution  : ${RESOLUTION}"
  echo "Session     : ${SESSION_MINUTES} minutes"
  echo "Web         : ${WEB_BIND}:${WEB_PORT}"
  echo "API         : ${API_BIND}:${API_PORT}"
  echo "Tunnel      : ${ENABLE_TUNNEL}"
  echo "Clean data  : ${CLEAN_WORKSPACE}"

  echo
  echo "✅ Configuration valid."
}


# ============================================================================
# Runner diagnostics
# ============================================================================

runner_diagnostics() {

  section "🖥 Runner diagnostics"


  echo "OS:"
  cat /etc/os-release | sed -n '1,8p'


  echo
  echo "Kernel:"
  uname -a


  echo
  echo "Architecture:"
  uname -m


  echo
  echo "CPU:"
  nproc


  echo
  echo "Memory:"
  free -h


  echo
  echo "Disk:"
  df -h /


  echo
  echo "Docker:"
  docker --version


  echo
  echo "Docker info:"
  docker info \
    --format \
    'ServerVersion={{.ServerVersion}} OSType={{.OSType}} Architecture={{.Architecture}} CPUs={{.NCPU}} Memory={{.MemTotal}}' \
    || true
}


# ============================================================================
# Install host dependencies
# ============================================================================

install_host_dependencies() {

  section "📦 Host dependencies"


  sudo apt-get update -y


  sudo apt-get install \
    -y \
    --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    netcat-openbsd \
    procps \
    psmisc \
    unzip \
    file \
    >/dev/null


  echo
  echo "curl:"
  curl --version | head -n 1


  echo
  echo "nc:"
  nc -h 2>&1 | head -n 1 || true
}


# ============================================================================
# Install Cloudflare
# ============================================================================

install_cloudflared() {

  [[ "${ENABLE_TUNNEL}" == "true" ]] || return 0


  section "☁️ Cloudflare"


  if command -v cloudflared >/dev/null 2>&1; then

    CLOUDFLARED_BIN="$(command -v cloudflared)"

  else

    log "Downloading latest cloudflared..."

    curl \
      --fail \
      --location \
      --retry 5 \
      --retry-delay 2 \
      --connect-timeout 15 \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
      --output "${RUNTIME_DIR}/cloudflared.deb"


    sudo dpkg \
      --install \
      "${RUNTIME_DIR}/cloudflared.deb"


    CLOUDFLARED_BIN="$(command -v cloudflared || true)"

  fi


  [[ -n "${CLOUDFLARED_BIN}" ]] \
    || die "cloudflared was not found."


  "${CLOUDFLARED_BIN}" --version
}


# ============================================================================
# Prepare data
# ============================================================================

prepare_data() {

  section "💾 MT5 data"


  if [[ "${CLEAN_WORKSPACE}" == "true" ]]; then

    log "Cleaning MT5 data directory..."

    find "${DATA_DIR}" \
      -mindepth 1 \
      -maxdepth 1 \
      -exec rm -rf -- {} +

  else

    log "Keeping existing session-local /config data."

  fi


  mkdir -p "${DATA_DIR}"


  echo
  echo "Data directory:"
  du -sh "${DATA_DIR}" 2>/dev/null || true
}


# ============================================================================
# Generate corrected startup script
# ============================================================================

generate_container_start_script() {

  section "🛠 Generate corrected MT5 startup"


  cat >"${CONTAINER_START_SCRIPT}" <<'CONTAINER_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail


# ============================================================================
# Container configuration
# ============================================================================

export WINEPREFIX="${WINEPREFIX:-/config/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"

MT5_SERVER_PORT="${MT5_SERVER_PORT:-8001}"
RESOLUTION="${DISPLAY_RESOLUTION:-1920x1080}"


# ============================================================================
# Directories
# ============================================================================

mkdir -p \
  "${WINEPREFIX}" \
  "${WINEPREFIX}/drive_c"


# ============================================================================
# Logging
# ============================================================================

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}


die() {
  log "ERROR: $*"
  exit 1
}


# ============================================================================
# Tool checks
# ============================================================================

command -v wine >/dev/null 2>&1 \
  || die "wine is not installed."

command -v curl >/dev/null 2>&1 \
  || die "curl is not installed."


# ============================================================================
# Constants
# ============================================================================

MONO_URL="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"

MT5_SETUP_URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

PYTHON_URL="https://www.python.org/ftp/python/3.13.7/python-3.13.7-amd64.exe"

MT5SERVER_URL="https://github.com/lucas-campagna/mt5linux/releases/download/server-1.1.1/mt5server.exe"


MONO_MSI="${WINEPREFIX}/drive_c/mono.msi"

MT5_INSTALLER="${WINEPREFIX}/drive_c/mt5setup.exe"

PYTHON_INSTALLER="${WINEPREFIX}/drive_c/python-installer.exe"

MT5SERVER_EXE="${WINEPREFIX}/drive_c/mt5server.exe"

MT5_EXE="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"


# ============================================================================
# Basic Wine prefix initialization
# ============================================================================

log "[1/8] Preparing Wine prefix..."

mkdir -p "${WINEPREFIX}/drive_c"

if [[ ! -d "${WINEPREFIX}/drive_c/windows" ]]; then

  log "[1/8] Running wineboot..."

  if ! wineboot -u >/tmp/wineboot.log 2>&1; then

    cat /tmp/wineboot.log || true

    die "wineboot failed."

  fi

fi


for _ in $(seq 1 90); do

  if [[ -d "${WINEPREFIX}/drive_c/windows" ]]; then
    break
  fi

  sleep 1

done


[[ -d "${WINEPREFIX}/drive_c/windows" ]] \
  || die "Wine prefix was not created."


# ============================================================================
# Wine Mono
# ============================================================================

if [[ ! -f "${WINEPREFIX}/drive_c/windows/system32/mscoree.dll" ]]; then

  log "[2/8] Wine Mono not detected."

  rm -f "${MONO_MSI}"


  log "[2/8] Downloading Wine Mono..."

  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 20 \
    "${MONO_URL}" \
    --output "${MONO_MSI}"


  [[ -s "${MONO_MSI}" ]] \
    || die "Wine Mono download is empty."


  log "[2/8] Installing Wine Mono..."


  WINEDLLOVERRIDES=mscoree=d \
  wine \
    msiexec \
    /i "${MONO_MSI}" \
    /qn


  rm -f "${MONO_MSI}"


  log "[2/8] Wine Mono installed."

else

  log "[2/8] Wine Mono already exists."

fi


# ============================================================================
# Wine configuration
# ============================================================================

log "[3/8] Configuring Wine..."


wine \
  reg add \
  'HKEY_CURRENT_USER\Software\Wine' \
  /v Version \
  /t REG_SZ \
  /d win10 \
  /f \
  >/dev/null \
  2>&1 \
  || true


# ============================================================================
# MetaTrader 5
# ============================================================================

if [[ ! -f "${MT5_EXE}" ]]; then

  log "[4/8] MetaTrader 5 not found."

  rm -f "${MT5_INSTALLER}"


  log "[4/8] Downloading MetaTrader 5 installer..."

  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 20 \
    "${MT5_SETUP_URL}" \
    --output "${MT5_INSTALLER}"


  [[ -s "${MT5_INSTALLER}" ]] \
    || die "MetaTrader 5 installer download failed."


  log "[4/8] Installing MetaTrader 5..."

  wine \
    "${MT5_INSTALLER}" \
    /auto \
    >/tmp/mt5-install.log \
    2>&1 \
    || true


  rm -f "${MT5_INSTALLER}"


  # Give MetaTrader installer/update process some time.
  for _ in $(seq 1 120); do

    if [[ -f "${MT5_EXE}" ]]; then
      break
    fi

    sleep 2

  done

else

  log "[4/8] MetaTrader 5 already installed."

fi


if [[ ! -f "${MT5_EXE}" ]]; then

  log "Searching for terminal64.exe..."

  FOUND_MT5="$(
    find "${WINEPREFIX}/drive_c" \
      -type f \
      -iname 'terminal64.exe' \
      2>/dev/null \
      | head -n 1
  )"


  if [[ -n "${FOUND_MT5}" ]]; then
    MT5_EXE="${FOUND_MT5}"
  fi

fi


[[ -f "${MT5_EXE}" ]] \
  || die "MetaTrader 5 terminal64.exe was not found."


log "[4/8] MT5 executable:"
log "${MT5_EXE}"


# ============================================================================
# Start MetaTrader
# ============================================================================

log "[5/8] Starting MetaTrader 5..."


if ! pgrep -af 'terminal64\.exe' >/dev/null 2>&1; then

  if [[ -n "${MT5_CMD_OPTIONS:-}" ]]; then

    # shellcheck disable=SC2206
    MT5_ARGS=( ${MT5_CMD_OPTIONS} )


    wine \
      "${MT5_EXE}" \
      "${MT5_ARGS[@]}" \
      >/tmp/mt5-terminal.log \
      2>&1 &

  else

    wine \
      "${MT5_EXE}" \
      >/tmp/mt5-terminal.log \
      2>&1 &

  fi

else

  log "[5/8] MetaTrader 5 is already running."

fi


sleep 5


# ============================================================================
# Python 3.13 for Wine
#
# MetaTrader5 current wheels include CPython 3.13 Windows amd64.
# ============================================================================

if ! wine python --version >/dev/null 2>&1; then

  log "[6/8] Windows Python not detected."


  rm -f "${PYTHON_INSTALLER}"


  log "[6/8] Downloading Python 3.13..."

  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 20 \
    "${PYTHON_URL}" \
    --output "${PYTHON_INSTALLER}"


  [[ -s "${PYTHON_INSTALLER}" ]] \
    || die "Python installer download failed."


  log "[6/8] Installing Python..."

  wine \
    "${PYTHON_INSTALLER}" \
    /quiet \
    InstallAllUsers=1 \
    PrependPath=1 \
    Include_test=0 \
    >/tmp/python-install.log \
    2>&1


  rm -f "${PYTHON_INSTALLER}"

else

  log "[6/8] Windows Python already exists."

fi


wine python --version


# ============================================================================
# Install Python packages
#
# mt5linux 1.1.1's server architecture uses the standalone mt5server.exe.
# The Linux package is still installed because the client imports:
#
#   from mt5linux import MetaTrader5
# ============================================================================

log "[7/8] Installing Python dependencies..."


wine \
  python \
  -m pip \
  install \
  --upgrade \
  --no-cache-dir \
  pip \
  setuptools \
  wheel \
  >/tmp/wine-pip-upgrade.log \
  2>&1


wine \
  python \
  -m pip \
  install \
  --upgrade \
  --no-cache-dir \
  "MetaTrader5>=5.0.6147" \
  "mt5linux==1.1.1" \
  >/tmp/wine-mt5linux-install.log \
  2>&1


python3 \
  -m pip \
  install \
  --break-system-packages \
  --upgrade \
  --no-cache-dir \
  "mt5linux==1.1.1" \
  >/tmp/linux-mt5linux-install.log \
  2>&1


# ============================================================================
# Download standalone mt5server.exe
# ============================================================================

if [[ ! -f "${MT5SERVER_EXE}" ]]; then

  log "[7/8] Downloading mt5server.exe..."

  rm -f "${MT5SERVER_EXE}"


  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 20 \
    "${MT5SERVER_URL}" \
    --output "${MT5SERVER_EXE}"


  [[ -s "${MT5SERVER_EXE}" ]] \
    || die "mt5server.exe download failed."

fi


chmod +x "${MT5SERVER_EXE}" || true


log "[7/8] mt5server.exe ready."


# ============================================================================
# Show server help/version
# ============================================================================

log "[7/8] Validating mt5server.exe..."

wine \
  "${MT5SERVER_EXE}" \
  --help \
  >/tmp/mt5server-help.log \
  2>&1 \
  || true


# ============================================================================
# Start mt5server.exe
#
# This is the current mt5linux server architecture.
# ============================================================================

log "[8/8] Starting mt5server.exe on port ${MT5_SERVER_PORT}..."


pkill \
  -f 'mt5server\.exe' \
  >/dev/null \
  2>&1 \
  || true


wine \
  "${MT5SERVER_EXE}" \
  --host 0.0.0.0 \
  --port "${MT5_SERVER_PORT}" \
  >/tmp/mt5server.log \
  2>&1 &


MT5SERVER_PID="$!"


log "[8/8] mt5server PID: ${MT5SERVER_PID}"


# ============================================================================
# Wait for server
# ============================================================================

READY="false"


for _ in $(seq 1 120); do

  if ! kill -0 "${MT5SERVER_PID}" >/dev/null 2>&1; then

    log "mt5server process exited."

    cat /tmp/mt5server.log || true

    break

  fi


  if ss -ltn 2>/dev/null \
    | grep -Eq ":${MT5_SERVER_PORT}[[:space:]]"; then

    READY="true"

    break

  fi


  sleep 1

done


if [[ "${READY}" != "true" ]]; then

  log "============================================================"
  log "mt5server.log"
  log "============================================================"

  cat /tmp/mt5server.log || true


  log "============================================================"
  log "MetaTrader terminal log"
  log "============================================================"

  cat /tmp/mt5-terminal.log || true


  die "mt5server did not bind port ${MT5_SERVER_PORT}."

fi


# ============================================================================
# Final runtime information
# ============================================================================

log "============================================================"
log "✅ MT5 runtime is ready"
log "============================================================"

log "Wine prefix : ${WINEPREFIX}"
log "MT5         : ${MT5_EXE}"
log "mt5server   : ${MT5SERVER_EXE}"
log "API         : 0.0.0.0:${MT5_SERVER_PORT}"


# ============================================================================
# Keep container process alive
# ============================================================================

wait
CONTAINER_SCRIPT


  chmod +x "${CONTAINER_START_SCRIPT}"


  bash -n "${CONTAINER_START_SCRIPT}"


  echo "✅ Runtime startup script is syntactically valid."
}


# ============================================================================
# Pull image
# ============================================================================

pull_image() {

  section "📦 Pull MT5 image"


  log "Pulling:"
  log "${MT5_IMAGE}"


  docker pull \
    "${MT5_IMAGE}"


  docker image inspect \
    "${MT5_IMAGE}" \
    --format \
    'Repository={{.RepoTags}} ID={{.Id}} Size={{.Size}} Created={{.Created}}' \
    | tee "${LOG_DIR}/image.txt"
}


# ============================================================================
# Start container
# ============================================================================

start_container() {

  section "🐳 Start MT5 container"


  # Remove any stale container first.
  docker rm \
    -f \
    "${CONTAINER_NAME}" \
    >/dev/null 2>&1 \
    || true


  # --------------------------------------------------------------------------
  # Important:
  # No --init
  #
  # The upstream image uses s6-overlay and expects /init to be PID 1.
  # --------------------------------------------------------------------------

  docker run \
    --detach \
    --name "${CONTAINER_NAME}" \
    --shm-size=2g \
    --stop-timeout 20 \
    --label "app=mt5-cloud" \
    --label "managed-by=github-actions" \
    --env "CUSTOM_USER=${WEB_USER}" \
    --env "PASSWORD=${WEB_PASSWORD}" \
    --env "DISPLAY_RESOLUTION=${RESOLUTION}" \
    --env "TZ=UTC" \
    --env "MT5_SERVER_PORT=${API_PORT}" \
    --env "MT5_CMD_OPTIONS=${MT5_CMD_OPTIONS}" \
    --volume "${DATA_DIR}:/config" \
    --volume "${CONTAINER_START_SCRIPT}:/Metatrader/start.sh:ro" \
    --publish "${WEB_BIND}:${WEB_PORT}:3000" \
    --publish "${API_BIND}:${API_PORT}:8001" \
    "${MT5_IMAGE}"


  echo
  echo "Container:"
  docker ps \
    --filter "name=${CONTAINER_NAME}" \
    --format \
    'table {{.Names}}\t{{.Status}}\t{{.Image}}'


  echo
  docker inspect \
    "${CONTAINER_NAME}" \
    --format \
    'Running={{.State.Running}} PID={{.State.Pid}} Status={{.State.Status}}'


  docker inspect \
    "${CONTAINER_NAME}" \
    >"${LOG_DIR}/container-inspect-start.json"
}


# ============================================================================
# Verify container
# ============================================================================

container_running() {

  local state

  state="$(
    docker inspect \
      -f '{{.State.Running}}' \
      "${CONTAINER_NAME}" \
      2>/dev/null \
      || echo "false"
  )"


  [[ "${state}" == "true" ]]
}


# ============================================================================
# Wait for TCP port
# ============================================================================

wait_for_tcp() {

  local host="$1"
  local port="$2"
  local timeout_seconds="$3"

  local started_at
  local elapsed


  started_at="$(date +%s)"


  while true; do

    if nc \
      -z \
      -w 2 \
      "${host}" \
      "${port}" \
      >/dev/null \
      2>&1; then

      return 0

    fi


    if ! container_running; then

      return 1

    fi


    elapsed=$(( $(date +%s) - started_at ))


    if (( elapsed >= timeout_seconds )); then

      return 1

    fi


    sleep "${CHECK_INTERVAL}"

  done
}


# ============================================================================
# HTTP probe
# ============================================================================

http_probe() {

  local url="$1"
  local error_file="$2"

  local code
  local rc


  if code="$(
    curl \
      --silent \
      --show-error \
      --output /dev/null \
      --write-out '%{http_code}' \
      --connect-timeout 5 \
      --max-time 15 \
      "${url}" \
      2>"${error_file}"
  )"; then

    rc=0

  else

    rc=$?

    code="000"

  fi


  printf '%s %s\n' \
    "${code}" \
    "${rc}"

  return 0
}


# ============================================================================
# Wait for HTTP
# ============================================================================

wait_for_http() {

  local url="$1"
  local timeout_seconds="$2"

  local started_at
  local elapsed

  local result
  local code
  local curl_rc


  started_at="$(date +%s)"


  while true; do

    result="$(
      http_probe \
        "${url}" \
        "${LOG_DIR}/curl-error.log"
    )"


    read -r code curl_rc <<<"${result}"


    case "${code}" in

      2??|3??|401|403)

        log "HTTP ${code} from ${url}"

        return 0

        ;;

    esac


    if ! container_running; then

      return 1

    fi


    elapsed=$(( $(date +%s) - started_at ))


    if (( elapsed >= timeout_seconds )); then

      log "HTTP readiness timeout."

      log "URL      : ${url}"
      log "Code     : ${code}"
      log "Curl rc  : ${curl_rc}"


      cat \
        "${LOG_DIR}/curl-error.log" \
        2>/dev/null \
        || true


      return 1

    fi


    sleep "${CHECK_INTERVAL}"

  done
}


# ============================================================================
# Start Cloudflare tunnel
# ============================================================================

start_cloudflare() {

  [[ "${ENABLE_TUNNEL}" == "true" ]] || return 0


  section "☁️ Start Cloudflare Quick Tunnel"


  : >"${CLOUDFLARE_LOG}"

  rm -f "${TUNNEL_URL_FILE}"


  log "Forwarding:"
  log "http://${WEB_BIND}:${WEB_PORT}"


  "${CLOUDFLARED_BIN}" \
    tunnel \
    --no-autoupdate \
    --url "http://${WEB_BIND}:${WEB_PORT}" \
    >"${CLOUDFLARE_LOG}" \
    2>&1 &


  CLOUDFLARE_PID="$!"


  log "cloudflared PID: ${CLOUDFLARE_PID}"


  local started_at
  local elapsed


  started_at="$(date +%s)"


  while true; do

    if grep \
      -Eo \
      'https://[-a-z0-9]+\.trycloudflare\.com' \
      "${CLOUDFLARE_LOG}" \
      | tail -n 1 \
      >"${TUNNEL_URL_FILE}"; then


      TUNNEL_URL="$(
        tr \
          -d '\r\n' \
          <"${TUNNEL_URL_FILE}"
      )"


      if [[ -n "${TUNNEL_URL}" ]]; then

        log "✅ Cloudflare URL detected:"
        log "${TUNNEL_URL}"

        return 0

      fi

    fi


    if ! kill -0 "${CLOUDFLARE_PID}" 2>/dev/null; then

      cat \
        "${CLOUDFLARE_LOG" \
        2>/dev/null \
        || true

      die "Cloudflare exited before producing a tunnel URL."

    fi


    elapsed=$(( $(date +%s) - started_at ))


    if (( elapsed >= TUNNEL_TIMEOUT )); then

      cat \
        "${CLOUDFLARE_LOG" \
        2>/dev/null \
        || true

      die "Cloudflare tunnel URL timeout."

    fi


    sleep 2

  done
}


# ============================================================================
# Test public tunnel
# ============================================================================

check_public_tunnel() {

  [[ "${ENABLE_TUNNEL}" == "true" ]] || return 0


  section "🌍 Public tunnel health"


  local attempt
  local public_code
  local public_rc


  for attempt in $(seq 1 10); do

    if public_code="$(
      curl \
        --silent \
        --show-error \
        --output /dev/null \
        --write-out '%{http_code}' \
        --connect-timeout 5 \
        --max-time 20 \
        "${TUNNEL_URL}/"
    )"; then

      public_rc=0

    else

      public_rc=$?

      public_code="000"

    fi


    case "${public_code}" in

      2??|3??|401|403)

        log "✅ Public URL reachable: HTTP ${public_code}"

        return 0

        ;;

    esac


    log \
      "Public probe ${attempt}/10: HTTP ${public_code}, curl_rc=${public_rc}"


    sleep 3

  done


  log "⚠️ Public URL did not answer within the probe window."

  log "Tunnel process is still running; continuing."


  return 0
}


# ============================================================================
# Save diagnostics
# ============================================================================

save_diagnostics() {

  [[ "${SAVE_ARTIFACTS}" == "true" ]] || return 0


  section "📊 Save diagnostics"


  docker logs \
    --tail 5000 \
    "${CONTAINER_NAME}" \
    >"${CONTAINER_LOG}" \
    2>&1 \
    || true


  docker inspect \
    "${CONTAINER_NAME}" \
    >"${LOG_DIR}/container-inspect-final.json" \
    2>&1 \
    || true


  docker stats \
    --no-stream \
    "${CONTAINER_NAME}" \
    >"${LOG_DIR}/container-stats.txt" \
    2>&1 \
    || true


  docker top \
    "${CONTAINER_NAME}" \
    >"${LOG_DIR}/container-processes.txt" \
    2>&1 \
    || true


  df -h \
    >"${LOG_DIR}/disk.txt" \
    2>&1 \
    || true


  free -h \
    >"${LOG_DIR}/memory.txt" \
    2>&1 \
    || true


  ps auxww \
    >"${LOG_DIR}/host-processes.txt" \
    2>&1 \
    || true


  if [[ -f "${CLOUDFLARE_LOG}" ]]; then

    tail -n 2000 \
      "${CLOUDFLARE_LOG}" \
      >"${TUNNEL_DIR}/cloudflared-tail.log" \
      2>/dev/null \
      || true

  fi


  if [[ -f "${TUNNEL_URL_FILE}" ]]; then
    cp "${TUNNEL_URL_FILE}" "${TUNNEL_DIR}/url.txt" || true
  fi
}


# ============================================================================
# Connection information
# ============================================================================

write_connection_info() {

  section "🔐 Connection"


  local browser_url


  if [[ "${ENABLE_TUNNEL}" == "true" ]]; then
    browser_url="${TUNNEL_URL}"
  else
    browser_url="http://127.0.0.1:${WEB_PORT}"
  fi


  echo
  echo "============================================================"
  echo "🌐 MT5 Cloud Desktop"
  echo "============================================================"
  echo "Browser URL : ${browser_url}"
  echo "Username    : ${WEB_USER}"
  echo "Password    : ${WEB_PASSWORD}"
  echo "Resolution  : ${RESOLUTION}"
  echo "Session     : ${SESSION_MINUTES} minutes"
  echo "Web         : ${WEB_BIND}:${WEB_PORT}"
  echo "API         : ${API_BIND}:${API_PORT} (PRIVATE)"
  echo "Image       : ${MT5_IMAGE}"
  echo "============================================================"


  cat >"${LOG_DIR}/connection.txt" <<EOF
Browser URL : ${browser_url}
Username    : ${WEB_USER}
Password    : ${WEB_PASSWORD}
Resolution  : ${RESOLUTION}
Session     : ${SESSION_MINUTES} minutes
Web         : ${WEB_BIND}:${WEB_PORT}
API         : ${API_BIND}:${API_PORT}
Image       : ${MT5_IMAGE}
EOF


  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then

    {
      echo "# 🚀 MT5 Cloud Desktop"
      echo
      echo "| Setting | Value |"
      echo "|---|---|"
      echo "| Image | \`${MT5_IMAGE}\` |"
      echo "| Resolution | \`${RESOLUTION}\` |"
      echo "| Session | ${SESSION_MINUTES} min |"
      echo "| Browser URL | ${browser_url} |"
      echo "| Username | \`${WEB_USER}\` |"
      echo "| API | private \`${API_BIND}:${API_PORT}\` |"
      echo "| Tunnel | ${ENABLE_TUNNEL} |"
    } >>"${GITHUB_STEP_SUMMARY}"

  fi
}


# ============================================================================
# Session monitor
# ============================================================================

monitor_session() {

  section "⏱ Session monitor"


  # IMPORTANT:
  # Use Bash arithmetic expansion.
  # Do NOT use command substitution for arithmetic.
  #

  START_TIME="$(date +%s)"

  SESSION_SECONDS=$(( SESSION_MINUTES * 60 ))

  END_TIME=$(( START_TIME + SESSION_SECONDS ))


  log "Session started."
  log "Duration : ${SESSION_MINUTES} minutes"
  log "End time : $(date -u -d "@${END_TIME}" '+%Y-%m-%d %H:%M:%S UTC')"


  while true; do

    NOW="$(date +%s)"

    REMAINING=$(( END_TIME - NOW ))


    # ------------------------------------------------------------------------
    # Completed
    # ------------------------------------------------------------------------

    if (( REMAINING <= 0 )); then

      log "✅ Session duration completed."

      break

    fi


    # ------------------------------------------------------------------------
    # Container health
    # ------------------------------------------------------------------------

    if ! container_running; then

      section "❌ MT5 container stopped unexpectedly"


      docker logs \
        --tail 1500 \
        "${CONTAINER_NAME}" \
        || true


      die "MT5 container stopped before session ended."

    fi


    # ------------------------------------------------------------------------
    # Cloudflare health
    # ------------------------------------------------------------------------

    if [[ "${ENABLE_TUNNEL}" == "true" ]]; then

      if [[ -z "${CLOUDFLARE_PID}" ]]; then

        die "Cloudflare PID is empty."

      fi


      if ! kill \
        -0 \
        "${CLOUDFLARE_PID}" \
        >/dev/null \
        2>&1; then

        section "❌ Cloudflare stopped"


        tail \
          -n 300 \
          "${CLOUDFLARE_LOG}" \
          2>/dev/null \
          || true


        die "Cloudflare tunnel stopped during session."

      fi

    fi


    # ------------------------------------------------------------------------
    # Human-readable timer
    # ------------------------------------------------------------------------

    HOURS=$(( REMAINING / 3600 ))

    MINUTES=$(( (REMAINING % 3600) / 60 ))

    SECONDS=$(( REMAINING % 60 ))


    log \
      "✅ MT5 running | Remaining ${HOURS}h ${MINUTES}m ${SECONDS}s"


    # ------------------------------------------------------------------------
    # Sleep
    # ------------------------------------------------------------------------

    if (( REMAINING > 30 )); then

      sleep 30

    else

      sleep "${REMAINING}"

    fi

  done
}


# ============================================================================
# MAIN
# ============================================================================

main() {

  section "🚀 MT5 Cloud Desktop"


  validate_config

  runner_diagnostics


  # --------------------------------------------------------------------------
  # Architecture
  # --------------------------------------------------------------------------

  if [[ "$(uname -m)" != "x86_64" ]]; then

    die "MT5 image requires x86_64/amd64."

  fi


  # --------------------------------------------------------------------------
  # Host packages
  # --------------------------------------------------------------------------

  install_host_dependencies


  # --------------------------------------------------------------------------
  # Cloudflare
  # --------------------------------------------------------------------------

  install_cloudflared


  # --------------------------------------------------------------------------
  # Data
  # --------------------------------------------------------------------------

  prepare_data


  # --------------------------------------------------------------------------
  # Generate runtime startup script
  # --------------------------------------------------------------------------

  generate_container_start_script


  # --------------------------------------------------------------------------
  # Pull image
  # --------------------------------------------------------------------------

  pull_image


  # --------------------------------------------------------------------------
  # Start container
  # --------------------------------------------------------------------------

  start_container


  # --------------------------------------------------------------------------
  # KasmVNC TCP
  # --------------------------------------------------------------------------

  section "⏳ KasmVNC TCP readiness"


  log \
    "Waiting for 127.0.0.1:${WEB_PORT} ..."


  if ! wait_for_tcp \
    "127.0.0.1" \
    "${WEB_PORT}" \
    "${TCP_TIMEOUT}"; then


    docker logs \
      --tail 1500 \
      "${CONTAINER_NAME}" \
      || true


    die "KasmVNC TCP port ${WEB_PORT} did not become ready."

  fi


  log "✅ KasmVNC TCP ready."


  # --------------------------------------------------------------------------
  # mt5linux TCP
  # --------------------------------------------------------------------------

  section "🐍 mt5linux TCP readiness"


  log \
    "Waiting for 127.0.0.1:${API_PORT} ..."


  if ! wait_for_tcp \
    "127.0.0.1" \
    "${API_PORT}" \
    "${TCP_TIMEOUT}"; then


    docker logs \
      --tail 2000 \
      "${CONTAINER_NAME}" \
      || true


    die "mt5server port ${API_PORT} did not become ready."

  fi


  log "✅ mt5server TCP ready."


  # --------------------------------------------------------------------------
  # KasmVNC HTTP
  # --------------------------------------------------------------------------

  section "🌐 KasmVNC HTTP readiness"


  if ! wait_for_http \
    "http://127.0.0.1:${WEB_PORT}/" \
    "${HTTP_TIMEOUT}"; then


    docker logs \
      --tail 2000 \
      "${CONTAINER_NAME}" \
      || true


    die "KasmVNC HTTP service did not become ready."

  fi


  log "✅ KasmVNC HTTP ready."


  # --------------------------------------------------------------------------
  # Headers
  # --------------------------------------------------------------------------

  echo
  echo "KasmVNC headers:"


  curl \
    --silent \
    --show-error \
    --head \
    --connect-timeout 5 \
    --max-time 15 \
    "http://127.0.0.1:${WEB_PORT}/" \
    | head -n 30 \
    || true


  # --------------------------------------------------------------------------
  # Cloudflare
  # --------------------------------------------------------------------------

  TUNNEL_URL=""


  if [[ "${ENABLE_TUNNEL}" == "true" ]]; then

    start_cloudflare

    check_public_tunnel

  fi


  # --------------------------------------------------------------------------
  # Connection details
  # --------------------------------------------------------------------------

  write_connection_info


  # --------------------------------------------------------------------------
  # Diagnostics
  # --------------------------------------------------------------------------

  save_diagnostics


  # --------------------------------------------------------------------------
  # Session
  # --------------------------------------------------------------------------

  monitor_session


  # --------------------------------------------------------------------------
  # Final diagnostics
  # --------------------------------------------------------------------------

  save_diagnostics


  section "🏁 Session complete"


  echo "✅ MT5 Cloud Desktop session completed."
}


# ============================================================================
# Execute
# ============================================================================

main "$@"
