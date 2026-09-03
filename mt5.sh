#!/usr/bin/env bash

set -Eeuo pipefail

# ==============================================================
# MT5 Cloud Desktop
#
# Host-side lifecycle controller for GitHub Actions.
#
# Responsibilities:
#   - Validate runtime
#   - Pull official upstream MT5 image
#   - Generate a corrected MT5 startup script
#   - Run the container
#   - Keep ports private
#   - Health-check KasmVNC and mt5linux
#   - Start Cloudflare Quick Tunnel
#   - Monitor the session
#   - Collect diagnostics
#   - Cleanup everything on exit
#
# No custom Docker image.
# No GitHub Actions cache.
# ==============================================================


# ==============================================================
# Paths
# ==============================================================

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


# ==============================================================
# Logging
# ==============================================================

MAIN_LOG="${LOG_DIR}/mt5-runtime.log"

exec > >(tee -a "${MAIN_LOG}") 2>&1


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


# ==============================================================
# Configuration
# ==============================================================

CONTAINER_NAME="${CONTAINER_NAME:-mt5-cloud}"

MT5_IMAGE="${MT5_IMAGE:-ghcr.io/gmag11/metatrader5-docker:2.3}"

WEB_BIND="${MT5_WEB_BIND:-127.0.0.1}"
WEB_PORT="${MT5_WEB_PORT:-3000}"

API_BIND="${MT5_API_BIND:-127.0.0.1}"
API_PORT="${MT5_API_PORT:-8001}"

WEB_USER="${MT5_WEB_USER:-trader}"
WEB_PASSWORD="${MT5_WEB_PASSWORD:-MT5-Demo-2026-StrongPassword!}"

RESOLUTION="${MT5_RESOLUTION:-1920x1080}"

SESSION_MINUTES="${MT5_SESSION_MINUTES:-60}"

ENABLE_TUNNEL="${MT5_ENABLE_TUNNEL:-true}"
SAVE_ARTIFACTS="${MT5_SAVE_ARTIFACTS:-true}"
CLEAN_WORKSPACE="${MT5_CLEAN_WORKSPACE:-false}"

TCP_TIMEOUT="${MT5_TCP_TIMEOUT:-120}"
HTTP_TIMEOUT="${MT5_HTTP_TIMEOUT:-180}"
TUNNEL_TIMEOUT="${MT5_TUNNEL_TIMEOUT:-120}"
CHECK_INTERVAL="${MT5_CHECK_INTERVAL:-3}"

CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-}"

CLOUDFLARE_LOG="${TUNNEL_DIR}/cloudflared.log"
TUNNEL_URL_FILE="${TUNNEL_DIR}/tunnel-url.txt"

CONTAINER_START="${RUNTIME_DIR}/mt5-start.sh"

CLOUDFLARE_PID=""


# ==============================================================
# Cleanup
# ==============================================================

cleanup() {

  local rc=$?

  trap - EXIT

  section "🧹 Cleanup"

  # ------------------------------------------------------------
  # Cloudflare
  # ------------------------------------------------------------

  if [[ -n "${CLOUDFLARE_PID}" ]]; then

    if kill -0 "${CLOUDFLARE_PID}" 2>/dev/null; then

      log "Stopping Cloudflare..."

      kill "${CLOUDFLARE_PID}" 2>/dev/null || true

      sleep 2

      kill -9 "${CLOUDFLARE_PID}" 2>/dev/null || true

    fi

  fi


  # ------------------------------------------------------------
  # MT5 container
  # ------------------------------------------------------------

  if docker ps -a --format '{{.Names}}' 2>/dev/null \
    | grep -qx "${CONTAINER_NAME}"; then

    log "Stopping MT5 container..."

    docker stop \
      --timeout 20 \
      "${CONTAINER_NAME}" \
      >/dev/null 2>&1 || true


    log "Removing MT5 container..."

    docker rm \
      -f \
      "${CONTAINER_NAME}" \
      >/dev/null 2>&1 || true

  fi


  echo
  echo "============================================================"
  echo "🏁 Cleanup completed"
  echo "Exit code: ${rc}"
  echo "============================================================"

  exit "${rc}"
}

trap cleanup EXIT


# ==============================================================
# Validate parameters
# ==============================================================

validate_config() {

  [[ "${SESSION_MINUTES}" =~ ^[0-9]+$ ]] \
    || die "SESSION_MINUTES must be numeric."

  if (( SESSION_MINUTES < 15 || SESSION_MINUTES > 300 )); then
    die "Session duration must be between 15 and 300 minutes."
  fi


  case "${RESOLUTION}" in

    1920x1080)
      ;;

    1600x900)
      ;;

    1280x720)
      ;;

    *)
      die "Unsupported resolution: ${RESOLUTION}"
      ;;

  esac


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
}


# ==============================================================
# Wait for TCP
# ==============================================================

wait_for_tcp() {

  local host="$1"
  local port="$2"
  local timeout="$3"

  local started
  started="$(date +%s)"


  while true; do

    if nc -z -w 2 "${host}" "${port}" >/dev/null 2>&1; then
      return 0
    fi


    if ! docker inspect \
      -f '{{.State.Running}}' \
      "${CONTAINER_NAME}" \
      2>/dev/null \
      | grep -qx true; then

      return 1

    fi


    if (( $(date +%s) - started >= timeout )); then
      return 1
    fi


    sleep "${CHECK_INTERVAL}"

  done
}


# ==============================================================
# HTTP readiness
# ==============================================================

wait_for_http() {

  local url="$1"
  local timeout="$2"

  local started
  local code
  local rc

  started="$(date +%s)"


  while true; do

    if code="$(
      curl \
        --silent \
        --show-error \
        --output /dev/null \
        --write-out '%{http_code}' \
        --connect-timeout 5 \
        --max-time 15 \
        "${url}" \
        2>"${LOG_DIR}/curl-error.log"
    )"; then

      rc=0

    else

      rc=$?

      code="000"

    fi


    # KasmVNC normally answers 401 because basic auth is enabled.
    #
    # 2xx = success
    # 3xx = success
    # 401 = expected auth challenge
    # 403 = service alive but access denied
    #

    if [[ "${code}" =~ ^2[0-9][0-9]$|^3[0-9][0-9]$|^401$|^403$ ]]; then

      log "HTTP ${code} from ${url}"

      return 0

    fi


    if (( $(date +%s) - started >= timeout )); then

      log "HTTP readiness timeout."

      log "URL       : ${url}"
      log "Last code : ${code}"
      log "Curl rc   : ${rc}"

      cat "${LOG_DIR}/curl-error.log" \
        2>/dev/null || true

      return 1

    fi


    sleep "${CHECK_INTERVAL}"

  done
}


# ==============================================================
# Generate corrected container startup script
#
# We replace ONLY the upstream /Metatrader/start.sh at runtime.
# No custom Docker image is built.
#
# Reasons:
#   1. Initialize Wine before downloading mono.msi.
#   2. Use current mt5linux CLI.
#   3. Install current mt5linux on both Linux + Wine Python.
#   4. Run mt5linux server under Wine directly.
# ==============================================================

write_container_start() {

cat >"${CONTAINER_START}" <<'CONTAINER_START_EOF'
#!/usr/bin/env bash

set -Eeuo pipefail


# ==============================================================
# Wine
# ==============================================================

WINEPREFIX="${WINEPREFIX:-/config/.wine}"

export WINEPREFIX

export WINEDEBUG="${WINEDEBUG:--all}"


# ==============================================================
# Files
# ==============================================================

MT5_FILE="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"

MONO_MARKER="${WINEPREFIX}/drive_c/windows/mono"

MONO_MSI="${WINEPREFIX}/drive_c/mono.msi"

MT5_INSTALLER="${WINEPREFIX}/drive_c/mt5setup.exe"


# ==============================================================
# Download URLs
# ==============================================================

MONO_URL="https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi"

PYTHON_URL="https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe"

MT5_SETUP_URL="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"


# ==============================================================
# Runtime configuration
# ==============================================================

MT5_SERVER_PORT="${MT5_SERVER_PORT:-8001}"

MT5_CMD_OPTIONS="${MT5_CMD_OPTIONS:-}"


# ==============================================================
# Logging
# ==============================================================

log() {

  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"

}


die() {

  log "ERROR: $*"

  exit 1

}


# ==============================================================
# Basic checks
# ==============================================================

command -v curl >/dev/null 2>&1 \
  || die "curl is not installed."

command -v wine >/dev/null 2>&1 \
  || die "wine is not installed."


# ==============================================================
# Ensure Wine directory exists
# ==============================================================

mkdir -p "${WINEPREFIX}/drive_c"


# ==============================================================
# [0/7] Initialize Wine PREFIX
# ==============================================================

log "[0/7] Initializing Wine prefix..."

if ! wineboot -u >/tmp/wineboot.log 2>&1; then

  cat /tmp/wineboot.log || true

  die "wineboot failed."

fi


for _ in $(seq 1 60); do

  if [[ -d "${WINEPREFIX}/drive_c/windows" ]]; then
    break
  fi

  sleep 1

done


if [[ ! -d "${WINEPREFIX}/drive_c/windows" ]]; then

  die "Wine prefix was not initialized correctly."

fi


# ==============================================================
# [1/7] Wine Mono
# ==============================================================

if [[ ! -e "${MONO_MARKER}" ]]; then

  log "[1/7] Downloading Wine Mono..."

  rm -f "${MONO_MSI}"


  curl \
    --fail \
    --location \
    --retry 4 \
    --retry-delay 2 \
    "${MONO_URL}" \
    --output "${MONO_MSI}"


  log "[1/7] Installing Wine Mono..."


  WINEDLLOVERRIDES=mscoree=d \
  wine msiexec \
    /i "${MONO_MSI}" \
    /qn


  rm -f "${MONO_MSI}"


  log "[1/7] Mono installed."

else

  log "[1/7] Mono is already installed."

fi


# ==============================================================
# [2/7] Configure Wine
# ==============================================================

log "[2/7] Configuring Wine Windows version..."

wine reg add \
  'HKEY_CURRENT_USER\Software\Wine' \
  /v Version \
  /t REG_SZ \
  /d win10 \
  /f \
  >/dev/null


# ==============================================================
# [3/7] Install MetaTrader 5 if needed
# ==============================================================

if [[ ! -e "${MT5_FILE}" ]]; then

  log "[3/7] MetaTrader 5 is not installed."

  log "[3/7] Downloading MT5 installer..."

  rm -f "${MT5_INSTALLER}"


  curl \
    --fail \
    --location \
    --retry 4 \
    --retry-delay 2 \
    "${MT5_SETUP_URL}" \
    --output "${MT5_INSTALLER}"


  log "[3/7] Installing MetaTrader 5..."

  wine \
    "${MT5_INSTALLER}" \
    /auto


  rm -f "${MT5_INSTALLER}"

else

  log "[3/7] MetaTrader 5 already installed."

fi


# ==============================================================
# Verify MT5
# ==============================================================

if [[ ! -e "${MT5_FILE}" ]]; then

  die "MetaTrader 5 terminal64.exe was not found."

fi


# ==============================================================
# [4/7] Start MT5
# ==============================================================

log "[4/7] Starting MetaTrader 5..."

if pgrep -af 'terminal64\.exe' >/dev/null 2>&1; then

  log "[4/7] MetaTrader 5 is already running."

else

  if [[ -n "${MT5_CMD_OPTIONS}" ]]; then

    # Intentional word splitting because this variable represents
    # command-line options.
    #
    # shellcheck disable=SC2206
    MT5_ARGS=( ${MT5_CMD_OPTIONS} )


    wine \
      "${MT5_FILE}" \
      "${MT5_ARGS[@]}" \
      >/tmp/mt5-terminal.log \
      2>&1 &

  else

    wine \
      "${MT5_FILE}" \
      >/tmp/mt5-terminal.log \
      2>&1 &

  fi

fi


# ==============================================================
# [5/7] Install Windows Python
# ==============================================================

if ! wine python --version >/dev/null 2>&1; then

  log "[5/7] Downloading Windows Python 3.9.13..."

  rm -f /tmp/python-installer.exe


  curl \
    --fail \
    --location \
    --retry 4 \
    --retry-delay 2 \
    "${PYTHON_URL}" \
    --output /tmp/python-installer.exe


  log "[5/7] Installing Python in Wine..."


  wine \
    /tmp/python-installer.exe \
    /quiet \
    InstallAllUsers=1 \
    PrependPath=1 \
    Include_test=0


  rm -f /tmp/python-installer.exe

else

  log "[5/7] Python is already installed in Wine."

fi


wine python --version


# ==============================================================
# [6/7] Windows Python dependencies
# ==============================================================

log "[6/7] Updating Windows pip..."

wine \
  python \
  -m pip \
  install \
  --upgrade \
  --no-cache-dir \
  pip \
  setuptools \
  wheel


log "[6/7] Installing MetaTrader5 + current mt5linux..."

wine \
  python \
  -m pip \
  install \
  --upgrade \
  --no-cache-dir \
  MetaTrader5 \
  mt5linux


# ==============================================================
# [6/7] Linux-side mt5linux
# ==============================================================

log "[6/7] Installing Linux mt5linux client..."

python3 \
  -m pip \
  install \
  --break-system-packages \
  --upgrade \
  --no-cache-dir \
  mt5linux


# ==============================================================
# [7/7] Start current mt5linux server
#
# IMPORTANT:
# Current mt5linux no longer uses the old "-w wine python.exe"
# syntax used by the upstream container.
#
# The modern architecture is:
#
#   Wine Python
#       ↓
#   python -m mt5linux
#       ↓
#   RPyC :8001
#
# ==============================================================

log "[7/7] Starting mt5linux RPyC server..."


# Clean up only an old copy created by this container.
pkill \
  -f 'python.*-m mt5linux' \
  >/dev/null 2>&1 \
  || true


sleep 1


wine \
  python \
  -m mt5linux \
  --host 0.0.0.0 \
  --port "${MT5_SERVER_PORT}" \
  >/tmp/mt5linux-server.log \
  2>&1 &


# ==============================================================
# Wait for mt5linux
# ==============================================================

MT5LINUX_READY="false"


for _ in $(seq 1 90); do

  if ss -ltn 2>/dev/null \
    | grep -q ":${MT5_SERVER_PORT} "; then

    MT5LINUX_READY="true"

    log "[7/7] mt5linux server is listening on ${MT5_SERVER_PORT}."

    break

  fi


  sleep 1

done


if [[ "${MT5LINUX_READY}" != "true" ]]; then

  log "============================================================"
  log "mt5linux startup log"
  log "============================================================"

  cat /tmp/mt5linux-server.log || true


  log "============================================================"
  log "MT5 terminal log"
  log "============================================================"

  cat /tmp/mt5-terminal.log || true


  die "mt5linux server failed to bind port ${MT5_SERVER_PORT}."

fi


# ==============================================================
# Runtime ready
# ==============================================================

log "============================================================"
log "✅ MT5 runtime is ready"
log "============================================================"

log "Wine prefix : ${WINEPREFIX}"
log "MT5         : ${MT5_FILE}"
log "mt5linux    : 0.0.0.0:${MT5_SERVER_PORT}"

log "============================================================"


# Keep this service alive.
wait
CONTAINER_START_EOF

  chmod +x "${CONTAINER_START}"
}


# ==============================================================
# Runner diagnostics
# ==============================================================

runner_diagnostics() {

  section "🖥 Runner diagnostics"

  echo "Runner:"
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
}


# ==============================================================
# Main
# ==============================================================

section "🚀 MT5 Cloud Desktop"

validate_config

runner_diagnostics


# ==============================================================
# Architecture check
# ==============================================================

if [[ "$(uname -m)" != "x86_64" ]]; then

  die "This MT5 Docker image requires x86_64/amd64."

fi


# ==============================================================
# Install host utilities
# ==============================================================

section "📦 Host dependencies"

sudo apt-get update -y >/dev/null

sudo apt-get install \
  -y \
  --no-install-recommends \
  ca-certificates \
  curl \
  jq \
  netcat-openbsd \
  procps \
  >/dev/null


# ==============================================================
# Cloudflare
# ==============================================================

if [[ "${ENABLE_TUNNEL}" == "true" ]]; then

  section "☁️ Cloudflare"

  if command -v cloudflared >/dev/null 2>&1; then

    CLOUDFLARED_BIN="$(command -v cloudflared)"

  else

    log "Installing Cloudflare cloudflared..."

    curl \
      --fail \
      --location \
      --retry 4 \
      --retry-delay 2 \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
      --output "${RUNTIME_DIR}/cloudflared.deb"


    sudo dpkg \
      -i \
      "${RUNTIME_DIR}/cloudflared.deb"


    CLOUDFLARED_BIN="$(command -v cloudflared || true)"

  fi


  [[ -n "${CLOUDFLARED_BIN}" ]] \
    || die "cloudflared installation failed."


  "${CLOUDFLARED_BIN}" --version

fi


# ==============================================================
# Session-local data
# ==============================================================

section "💾 Workspace"

if [[ "${CLEAN_WORKSPACE}" == "true" ]]; then

  log "Cleaning session-local MT5 data..."

  rm -rf "${DATA_DIR:?}"/*

else

  log "Keeping existing session-local data."

fi


# ==============================================================
# Generate corrected container startup
# ==============================================================

section "🛠 Generate MT5 runtime"

write_container_start

echo "Runtime script:"
echo "${CONTAINER_START}"

echo
echo "Syntax check:"

bash -n "${CONTAINER_START}"

echo "✅ Container startup script is syntactically valid."


# ==============================================================
# Remove stale container
# ==============================================================

docker rm -f \
  "${CONTAINER_NAME}" \
  >/dev/null 2>&1 \
  || true


# ==============================================================
# Pull upstream image
# ==============================================================

section "📦 Pull MT5 image"

log "Image: ${MT5_IMAGE}"

docker pull \
  "${MT5_IMAGE}"


docker image inspect \
  "${MT5_IMAGE}" \
  --format \
  'Image={{.RepoTags}} ID={{.Id}} Size={{.Size}}' \
  | tee "${LOG_DIR}/image.txt"


# ==============================================================
# Start container
# ==============================================================

section "🐳 Start container"

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
  --volume "${DATA_DIR}:/config" \
  --volume "${CONTAINER_START}:/Metatrader/start.sh:ro" \
  --publish "${WEB_BIND}:${WEB_PORT}:3000" \
  --publish "${API_BIND}:${API_PORT}:8001" \
  "${MT5_IMAGE}"


# ==============================================================
# Container info
# ==============================================================

docker ps \
  --filter "name=${CONTAINER_NAME}" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'


echo

docker inspect \
  "${CONTAINER_NAME}" \
  --format 'Running={{.State.Running}} PID={{.State.Pid}}'


# ==============================================================
# Wait for KasmVNC TCP
# ==============================================================

section "⏳ KasmVNC readiness"

log "Waiting for 127.0.0.1:${WEB_PORT} ..."

if ! wait_for_tcp \
  127.0.0.1 \
  "${WEB_PORT}" \
  "${TCP_TIMEOUT}"; then

  docker logs \
    --tail 300 \
    "${CONTAINER_NAME}" \
    || true

  die "KasmVNC TCP port ${WEB_PORT} did not become ready."

fi


log "✅ KasmVNC TCP is ready."


# ==============================================================
# Wait for mt5linux TCP
# ==============================================================

section "🐍 mt5linux readiness"

log "Waiting for 127.0.0.1:${API_PORT} ..."

if ! wait_for_tcp \
  127.0.0.1 \
  "${API_PORT}" \
  "${TCP_TIMEOUT}"; then

  docker logs \
    --tail 500 \
    "${CONTAINER_NAME}" \
    || true

  die "mt5linux TCP port ${API_PORT} did not become ready."

fi


log "✅ mt5linux TCP is ready."


# ==============================================================
# KasmVNC HTTP readiness
# ==============================================================

section "🌐 KasmVNC HTTP"

if ! wait_for_http \
  "http://127.0.0.1:${WEB_PORT}/" \
  "${HTTP_TIMEOUT}"; then

  docker logs \
    --tail 500 \
    "${CONTAINER_NAME}" \
    || true

  die "KasmVNC HTTP service did not become ready."

fi


log "✅ KasmVNC HTTP service is ready."


# ==============================================================
# HTTP headers
# ==============================================================

echo
echo "KasmVNC response headers:"

curl \
  --silent \
  --show-error \
  --head \
  --connect-timeout 5 \
  --max-time 15 \
  "http://127.0.0.1:${WEB_PORT}/" \
  | head -n 30 \
  || true


# ==============================================================
# Cloudflare Quick Tunnel
# ==============================================================

TUNNEL_URL=""

if [[ "${ENABLE_TUNNEL}" == "true" ]]; then

  section "☁️ Cloudflare Quick Tunnel"

  : >"${CLOUDFLARE_LOG}"

  rm -f "${TUNNEL_URL_FILE}"


  log "Starting Quick Tunnel..."

  "${CLOUDFLARED_BIN}" \
    tunnel \
    --no-autoupdate \
    --url "http://${WEB_BIND}:${WEB_PORT}" \
    >"${CLOUDFLARE_LOG}" \
    2>&1 &


  CLOUDFLARE_PID=$!


  tunnel_started="$(date +%s)"


  while true; do

    if grep \
      -Eo \
      'https://[-a-z0-9]+\.trycloudflare\.com' \
      "${CLOUDFLARE_LOG}" \
      | tail -n 1 \
      >"${TUNNEL_URL_FILE}"; then

      TUNNEL_URL="$(
        tr -d '\r\n' <"${TUNNEL_URL_FILE}"
      )"


      if [[ -n "${TUNNEL_URL}" ]]; then
        break
      fi

    fi


    if ! kill -0 "${CLOUDFLARE_PID}" 2>/dev/null; then

      cat "${CLOUDFLARE_LOG}" || true

      die "Cloudflare tunnel exited unexpectedly."

    fi


    if (( $(date +%s) - tunnel_started >= TUNNEL_TIMEOUT )); then

      cat "${CLOUDFLARE_LOG}" || true

      die "Cloudflare tunnel URL was not detected within ${TUNNEL_TIMEOUT}s."

    fi


    sleep 2

  done


  log "✅ Tunnel URL detected:"
  echo "${TUNNEL_URL}"


  # ------------------------------------------------------------
  # Public URL readiness
  # ------------------------------------------------------------

  section "🌍 Public URL check"

  public_code="000"
  public_rc=1


  for _ in $(seq 1 10); do

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


    if [[ "${public_code}" =~ ^2[0-9][0-9]$|^3[0-9][0-9]$|^401$|^403$ ]]; then

      log "✅ Public tunnel reachable: HTTP ${public_code}"

      break

    fi


    log \
      "Public probe: HTTP ${public_code}, curl_rc ${public_rc}; retrying..."

    sleep 3

  done

else

  log "Cloudflare tunnel disabled."

fi


# ==============================================================
# Connection information
# ==============================================================

section "✅ Connection"

BROWSER_URL="${TUNNEL_URL:-http://127.0.0.1:${WEB_PORT}}"


echo "Browser URL : ${BROWSER_URL}"
echo "Username    : ${WEB_USER}"
echo "Password    : ${WEB_PASSWORD}"
echo "Resolution  : ${RESOLUTION}"
echo "Session     : ${SESSION_MINUTES} minutes"
echo "MT5 API     : private ${API_BIND}:${API_PORT}"
echo "MT5 Data    : ${DATA_DIR}"


# ==============================================================
# Save connection information
#
# This is intentionally local to the workflow artifact.
# The password is the demo web-desktop password only.
# ==============================================================

cat >"${LOG_DIR}/connection.txt" <<EOF
Browser URL : ${BROWSER_URL}
Username    : ${WEB_USER}
Password    : ${WEB_PASSWORD}
Resolution  : ${RESOLUTION}
Session     : ${SESSION_MINUTES} minutes
MT5 API     : ${API_BIND}:${API_PORT}
MT5 Image   : ${MT5_IMAGE}
EOF


# ==============================================================
# Python test/client instructions
# ==============================================================

cat >"${LOG_DIR}/python-client.txt" <<'EOF'
# Install client:

python3 -m pip install mt5linux

# Connect from Python running INSIDE the MT5 desktop/container:

from mt5linux import MetaTrader5

mt5 = MetaTrader5(
    host="127.0.0.1",
    port=8001,
)

print("Version:", mt5.version())
print("Terminal:", mt5.terminal_info())

mt5.shutdown()
EOF


echo
echo "Python client example:"
echo "----------------------------------------"
cat "${LOG_DIR}/python-client.txt"
echo "----------------------------------------"


# ==============================================================
# GitHub Step Summary
# ==============================================================

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then

  {
    echo "# 🚀 MT5 Cloud Desktop"
    echo

    echo "| Setting | Value |"
    echo "|---|---|"
    echo "| Image | \`${MT5_IMAGE}\` |"
    echo "| Resolution | ${RESOLUTION} |"
    echo "| Session | ${SESSION_MINUTES} min |"
    echo "| Browser | ${BROWSER_URL} |"
    echo "| User | \`${WEB_USER}\` |"
    echo "| API | private \`${API_BIND}:${API_PORT}\` |"
    echo "| Cloudflare | ${ENABLE_TUNNEL} |"

    echo

    echo "### Connection"

    echo
    echo "Open the Browser URL from the job log and use the displayed demo password."

  } >>"${GITHUB_STEP_SUMMARY}"

fi


# ==============================================================
# Session monitor
# ==============================================================

section "⏱ Session monitor"

START_TIME="$(date +%s)"

END_TIME=$(
  (
    START_TIME + SESSION_MINUTES * 60
  )
)


while true; do

  NOW="$(date +%s)"

  REMAINING=$(
    (
      END_TIME - NOW
    )
  )


  if (( REMAINING <= 0 )); then
    break
  fi


  # ------------------------------------------------------------
  # Container must stay alive
  # ------------------------------------------------------------

  if ! docker inspect \
    -f '{{.State.Running}}' \
    "${CONTAINER_NAME}" \
    2>/dev/null \
    | grep -qx true; then

    section "❌ MT5 container stopped unexpectedly"

    docker logs \
      --tail 1000 \
      "${CONTAINER_NAME}" \
      || true

    die "MT5 container stopped before session ended."

  fi


  printf \
    '[%s] Remaining: %02dh %02dm\n' \
    "$(timestamp)" \
    $(( REMAINING / 3600 )) \
    $(( (REMAINING % 3600) / 60 ))


  sleep 30

done


# ==============================================================
# Final diagnostics
# ==============================================================

section "📊 Final diagnostics"

if [[ "${SAVE_ARTIFACTS}" == "true" ]]; then

  docker logs \
    --tail 2000 \
    "${CONTAINER_NAME}" \
    >"${LOG_DIR}/container.log" \
    2>&1 \
    || true


  docker inspect \
    "${CONTAINER_NAME}" \
    >"${LOG_DIR}/container-inspect.json" \
    2>&1 \
    || true


  docker stats \
    --no-stream \
    "${CONTAINER_NAME}" \
    >"${LOG_DIR}/container-stats.txt" \
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
    >"${LOG_DIR}/processes.txt" \
    2>&1 \
    || true

fi


# ==============================================================
# Success
# ==============================================================

section "🏁 Session complete"

echo "✅ MT5 Cloud Desktop session completed successfully."
echo
echo "Browser : ${BROWSER_URL}"
echo "User    : ${WEB_USER}"
echo "API     : private ${API_BIND}:${API_PORT}"
echo "Runtime : ${SESSION_MINUTES} minutes"
