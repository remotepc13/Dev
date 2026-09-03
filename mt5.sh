#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# MT5 Cloud Desktop
# Runtime / Lifecycle Script
#
# Architecture:
#
# GitHub Actions
#       ↓
#     mt5.yml
#       ↓
#     mt5.sh
#       ↓
# docker pull
#       ↓
# gmag11/metatrader5_vnc
#       ↓
# ┌──────────────────────────────┐
# │ KasmVNC       :3000          │
# │ MetaTrader 5                 │
# │ Wine                         │
# │ Python                       │
# │ mt5linux / RPyC :8001        │
# └──────────────────────────────┘
#       ↓
# Cloudflare Tunnel
#       ↓
# Browser
#
# IMPORTANT:
# - No Docker build
# - No Docker cache
# - No --init
# - Port 8001 stays private
# - Cloudflare exposes only port 3000
# - TCP and HTTP health checks are separate
# ============================================================


# ============================================================
# Configuration
# ============================================================

CONTAINER_NAME="${CONTAINER_NAME:-mt5-cloud}"

MT5_IMAGE="${MT5_IMAGE:-gmag11/metatrader5_vnc:latest}"

MT5_WEB_PORT="${MT5_WEB_PORT:-3000}"
MT5_WEB_BIND="${MT5_WEB_BIND:-127.0.0.1}"

MT5_API_PORT="${MT5_API_PORT:-8001}"
MT5_API_BIND="${MT5_API_BIND:-127.0.0.1}"

MT5_WEB_USER="${MT5_WEB_USER:-trader}"
MT5_WEB_PASSWORD="${MT5_WEB_PASSWORD:-MT5-Demo-2026-StrongPassword!}"

TZ="${TZ:-UTC}"

WORKSPACE_ROOT="${GITHUB_WORKSPACE:-$PWD}"

LOG_DIR="${LOG_DIR:-${WORKSPACE_ROOT}/logs}"
TUNNEL_DIR="${TUNNEL_DIR:-${WORKSPACE_ROOT}/tunnel}"
MT5_DATA_DIR="${MT5_DATA_DIR:-${WORKSPACE_ROOT}/mt5_data}"

CLOUDFLARE_LOG="${CLOUDFLARE_LOG:-${TUNNEL_DIR}/cloudflared.log}"
TUNNEL_URL_FILE="${TUNNEL_URL_FILE:-${TUNNEL_DIR}/tunnel_url.txt}"

SESSION_MINUTES="${INPUT_SESSION_MINUTES:-60}"
RESOLUTION="${INPUT_RESOLUTION:-1920x1080}"

ENABLE_TUNNEL="${INPUT_ENABLE_TUNNEL:-true}"
SAVE_ARTIFACTS="${INPUT_SAVE_ARTIFACTS:-true}"
CLEAN_WORKSPACE="${INPUT_CLEAN_WORKSPACE:-false}"


# ============================================================
# Health Check Configuration
# ============================================================

# TCP port startup timeout.
TCP_TIMEOUT_SECONDS="${TCP_TIMEOUT_SECONDS:-120}"

# HTTP service startup timeout.
HTTP_TIMEOUT_SECONDS="${HTTP_TIMEOUT_SECONDS:-120}"

# Cloudflare startup timeout.
TUNNEL_TIMEOUT_SECONDS="${TUNNEL_TIMEOUT_SECONDS:-120}"

# How often to retry health checks.
HEALTH_INTERVAL_SECONDS="${HEALTH_INTERVAL_SECONDS:-3}"

# Public Cloudflare request timeout.
PUBLIC_HTTP_TIMEOUT_SECONDS="${PUBLIC_HTTP_TIMEOUT_SECONDS:-20}"


# ============================================================
# Runtime State
# ============================================================

CLOUDFLARED_PID=""

START_TIME_UNIX="0"
END_TIME_UNIX="0"

MAIN_LOG=""


# ============================================================
# Logging
# ============================================================

mkdir -p \
  "${LOG_DIR}" \
  "${TUNNEL_DIR}"

MAIN_LOG="${LOG_DIR}/mt5-runtime.log"

touch "${MAIN_LOG}"

exec > >(tee -a "${MAIN_LOG}") 2>&1


timestamp() {
  date -u '+%Y-%m-%d %H:%M:%S UTC'
}


log() {
  echo
  echo "[$(timestamp)] $*"
}


section() {
  echo
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}


die() {
  echo
  echo "❌ ERROR: $*"
  exit 1
}


command_exists() {
  command -v "$1" >/dev/null 2>&1
}


is_true() {
  case "${1,,}" in
    true|1|yes|y|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}


# ============================================================
# Container Helpers
# ============================================================

container_exists() {

  docker inspect \
    "${CONTAINER_NAME}" \
    >/dev/null 2>&1

}


container_running() {

  [[ "$(
    docker inspect \
      --format '{{.State.Running}}' \
      "${CONTAINER_NAME}" \
      2>/dev/null || echo "false"
  )" == "true" ]]

}


show_container_logs() {

  echo
  echo "------------------------------------------------------------"
  echo "📋 Recent MT5 container logs"
  echo "------------------------------------------------------------"

  docker logs \
    --tail 400 \
    "${CONTAINER_NAME}" \
    2>&1 || true

  echo
  echo "------------------------------------------------------------"

}


# ============================================================
# Cleanup
# ============================================================

cleanup() {

  local exit_code=$?

  set +e

  section "🧹 Cleanup"

  # ----------------------------------------------------------
  # Stop Cloudflare
  # ----------------------------------------------------------

  if [[ -n "${CLOUDFLARED_PID}" ]]; then

    if kill -0 "${CLOUDFLARED_PID}" 2>/dev/null; then

      log "Stopping Cloudflare process..."

      kill \
        "${CLOUDFLARED_PID}" \
        2>/dev/null || true

      sleep 2

      kill -9 \
        "${CLOUDFLARED_PID}" \
        2>/dev/null || true

    fi

  fi


  # ----------------------------------------------------------
  # Stop MT5
  # ----------------------------------------------------------

  if container_exists; then

    if container_running; then

      log "Stopping MT5 container..."

      docker stop \
        --timeout 15 \
        "${CONTAINER_NAME}" \
        2>&1 || true

    fi


    log "Removing MT5 container..."

    docker rm \
      -f \
      "${CONTAINER_NAME}" \
      2>&1 || true

  fi


  echo
  echo "============================================================"
  echo "🏁 Cleanup completed"
  echo "Exit code: ${exit_code}"
  echo "============================================================"


  exit "${exit_code}"
}


trap cleanup EXIT


# ============================================================
# Validate Configuration
# ============================================================

section "🔎 Validate configuration"


if ! [[ "${SESSION_MINUTES}" =~ ^[0-9]+$ ]]; then
  die "Invalid session duration: ${SESSION_MINUTES}"
fi


if (( SESSION_MINUTES < 1 )); then
  die "Session duration must be greater than zero."
fi


if ! [[ "${RESOLUTION}" =~ ^[0-9]+x[0-9]+$ ]]; then
  die "Invalid resolution: ${RESOLUTION}"
fi


if ! [[ "${TCP_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
  die "Invalid TCP timeout: ${TCP_TIMEOUT_SECONDS}"
fi


if ! [[ "${HTTP_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
  die "Invalid HTTP timeout: ${HTTP_TIMEOUT_SECONDS}"
fi


if ! [[ "${TUNNEL_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
  die "Invalid tunnel timeout: ${TUNNEL_TIMEOUT_SECONDS}"
fi


if ! [[ "${HEALTH_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]]; then
  die "Invalid health interval: ${HEALTH_INTERVAL_SECONDS}"
fi


log "Container       : ${CONTAINER_NAME}"
log "Image           : ${MT5_IMAGE}"
log "Resolution      : ${RESOLUTION}"
log "Session         : ${SESSION_MINUTES} minutes"
log "Web endpoint    : ${MT5_WEB_BIND}:${MT5_WEB_PORT}"
log "API endpoint    : ${MT5_API_BIND}:${MT5_API_PORT}"
log "Tunnel enabled  : ${ENABLE_TUNNEL}"
log "Clean workspace : ${CLEAN_WORKSPACE}"

echo
echo "Web user        : ${MT5_WEB_USER}"
echo "Web password    : ${MT5_WEB_PASSWORD}"


# ============================================================
# Runner Diagnostics
# ============================================================

section "🖥️ Runner diagnostics"


log "Operating system:"
cat /etc/os-release || true


echo
log "Kernel:"
uname -a || true


echo
log "Architecture:"
uname -m


echo
log "CPU:"
nproc || true


echo
log "Memory:"
free -h || true


echo
log "Disk:"
df -h / || true


echo
log "Docker:"
docker --version || true


echo
log "Docker server:"
docker info \
  --format \
  'Server={{.ServerVersion}} | Storage={{.Driver}} | CPUs={{.NCPU}} | Memory={{.MemTotal}}' \
  2>/dev/null \
  || true


# ============================================================
# Validate Architecture
# ============================================================

section "🧬 Validate architecture"


ARCH="$(uname -m)"


if [[ "${ARCH}" != "x86_64" ]]; then

  die "Unsupported architecture: ${ARCH}. MT5 Docker image requires AMD64/x86_64."

fi


log "Architecture: AMD64 / x86_64"
log "✅ Architecture supported."


# ============================================================
# Install Minimal Dependencies
# ============================================================

section "📦 Install minimal dependencies"


export DEBIAN_FRONTEND=noninteractive


sudo apt-get update -qq


sudo apt-get install -y -qq \
  ca-certificates \
  curl \
  jq \
  netcat-openbsd \
  procps \
  unzip


log "✅ Base dependencies installed."


# ============================================================
# Install Cloudflare
# ============================================================

install_cloudflared() {

  if command_exists cloudflared; then

    log "cloudflared already installed."

    cloudflared --version || true

    return 0

  fi


  log "Installing latest cloudflared..."


  local package="/tmp/cloudflared.deb"


  rm -f "${package}"


  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-delay 2 \
    -o "${package}" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"


  sudo dpkg -i "${package}"


  rm -f "${package}"


  if ! command_exists cloudflared; then

    die "cloudflared installation failed."

  fi


  cloudflared --version


  log "✅ cloudflared installed."

}


if is_true "${ENABLE_TUNNEL}"; then

  section "☁️ Cloudflare Tunnel"

  install_cloudflared

else

  log "Cloudflare Tunnel disabled."

fi


# ============================================================
# Prepare Workspace
# ============================================================

section "📁 Prepare workspace"


mkdir -p \
  "${LOG_DIR}" \
  "${TUNNEL_DIR}" \
  "${MT5_DATA_DIR}"


if is_true "${CLEAN_WORKSPACE}"; then

  log "Cleaning MT5 workspace..."

  find "${MT5_DATA_DIR}" \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf {} +

  log "✅ MT5 workspace cleaned."

else

  log "Keeping current workspace."

fi


rm -f \
  "${TUNNEL_URL_FILE}"


# ============================================================
# Remove Stale Container
# ============================================================

section "🧹 Remove stale MT5 container"


if container_exists; then

  log "Existing container detected."


  docker stop \
    --timeout 10 \
    "${CONTAINER_NAME}" \
    2>&1 || true


  docker rm \
    -f \
    "${CONTAINER_NAME}" \
    2>&1 || true


  log "✅ Stale container removed."

else

  log "No stale container found."

fi


# ============================================================
# Pull MT5 Image
# ============================================================

section "🐳 Pull MT5 Docker image"


log "Pulling:"
log "${MT5_IMAGE}"


# Intentionally NO:
# - docker build
# - Docker cache
#
# GitHub-hosted runners are ephemeral.

docker pull \
  "${MT5_IMAGE}"


log "✅ MT5 image pulled successfully."


# ============================================================
# Verify Image
# ============================================================

section "🔍 Verify Docker image"


docker image inspect \
  "${MT5_IMAGE}" \
  --format \
  'Repository={{index .RepoTags 0}} | ID={{.Id}} | Size={{.Size}} bytes' \
  || die "Unable to inspect MT5 image."


# ============================================================
# Start MT5 Container
# ============================================================

section "🚀 Start MetaTrader 5 container"


log "Starting container..."


# IMPORTANT:
#
# DO NOT USE --init.
#
# The upstream image uses s6-overlay and expects /init
# to be PID 1. Docker --init would insert tini as PID 1
# and break s6-overlay.


docker run \
  --detach \
  --name "${CONTAINER_NAME}" \
  --shm-size=2g \
  --stop-timeout 15 \
  --label "managed-by=github-actions" \
  --label "project=mt5-cloud-desktop" \
  --label "run-id=${GITHUB_RUN_ID:-local}" \
  --env "CUSTOM_USER=${MT5_WEB_USER}" \
  --env "PASSWORD=${MT5_WEB_PASSWORD}" \
  --env "DISPLAY_RESOLUTION=${RESOLUTION}" \
  --env "TZ=${TZ}" \
  --volume "${MT5_DATA_DIR}:/config" \
  --publish "${MT5_WEB_BIND}:${MT5_WEB_PORT}:3000" \
  --publish "${MT5_API_BIND}:${MT5_API_PORT}:8001" \
  "${MT5_IMAGE}"


log "Container started."


# ============================================================
# Verify Container PID
# ============================================================

section "🔍 Verify container"


CONTAINER_PID="$(
  docker inspect \
    --format '{{.State.Pid}}' \
    "${CONTAINER_NAME}"
)"


CONTAINER_RUNNING="$(
  docker inspect \
    --format '{{.State.Running}}' \
    "${CONTAINER_NAME}"
)"


CONTAINER_STATUS="$(
  docker inspect \
    --format '{{.State.Status}}' \
    "${CONTAINER_NAME}"
)"


log "Container PID : ${CONTAINER_PID}"
log "Running       : ${CONTAINER_RUNNING}"
log "Status        : ${CONTAINER_STATUS}"


if [[ "${CONTAINER_RUNNING}" != "true" ]]; then

  show_container_logs

  die "MT5 container is not running."

fi


# ============================================================
# Generic TCP Wait Function
# ============================================================

wait_for_tcp() {

  local host="$1"
  local port="$2"
  local timeout="$3"
  local description="$4"

  local started
  local now
  local elapsed
  local attempt=0


  started="$(date +%s)"


  log "Waiting for ${description} at ${host}:${port}..."


  while true; do

    attempt=$((attempt + 1))


    if nc \
      -z \
      -w 2 \
      "${host}" \
      "${port}" \
      >/dev/null 2>&1; then

      log "✅ ${description} TCP port is ready."

      return 0

    fi


    if ! container_running; then

      echo
      echo "❌ Container stopped while waiting for ${description}."

      show_container_logs

      return 1

    fi


    now="$(date +%s)"

    elapsed=$((now - started))


    if (( elapsed >= timeout )); then

      echo
      echo "❌ Timeout waiting for ${description} TCP port."

      show_container_logs

      return 1

    fi


    log "Waiting for ${description}... attempt=${attempt}, elapsed=${elapsed}s/${timeout}s"


    sleep "${HEALTH_INTERVAL_SECONDS}"

  done

}


# ============================================================
# Wait for KasmVNC TCP
# ============================================================

section "⏳ TCP readiness — KasmVNC :3000"


wait_for_tcp \
  "${MT5_WEB_BIND}" \
  "${MT5_WEB_PORT}" \
  "${TCP_TIMEOUT_SECONDS}" \
  "KasmVNC"


# ============================================================
# Wait for RPyC TCP
# ============================================================

section "⏳ TCP readiness — mt5linux/RPyC :8001"


wait_for_tcp \
  "${MT5_API_BIND}" \
  "${MT5_API_PORT}" \
  "${TCP_TIMEOUT_SECONDS}" \
  "mt5linux/RPyC"


# ============================================================
# HTTP Health Check
# ============================================================

check_http_once() {

  local url="$1"
  local response_file="$2"


  : > "${response_file}"


  local http_code


  http_code="$(
    curl \
      --silent \
      --show-error \
      --output /dev/null \
      --write-out '%{http_code}' \
      --connect-timeout 5 \
      --max-time 15 \
      "${url}" \
      2>"${response_file}"
  )"

  local curl_exit=$?


  if (( curl_exit != 0 )); then

    # curl commonly returns 000 when no HTTP response exists.
    # This is a transport failure, not a real HTTP status.

    echo "curl_exit=${curl_exit}"
    echo "http_code=${http_code:-000}"

    if [[ -s "${response_file}" ]]; then
      echo "curl_error:"
      cat "${response_file}"
    fi

    return 1

  fi


  echo "http_code=${http_code}"


  case "${http_code}" in

    2??|3??|401|403)

      return 0
      ;;

    *)

      return 1
      ;;

  esac

}


wait_for_http() {

  local url="$1"
  local timeout="$2"
  local description="$3"


  local started
  local now
  local elapsed
  local attempt=0

  local response_file="${LOG_DIR}/http-health-error.txt"


  started="$(date +%s)"


  log "Waiting for ${description} HTTP readiness..."

  log "URL: ${url}"


  while true; do

    attempt=$((attempt + 1))


    if check_http_once \
      "${url}" \
      "${response_file}"; then

      log "✅ ${description} HTTP service is ready."

      return 0

    fi


    if ! container_running; then

      echo
      echo "❌ Container stopped during HTTP readiness check."

      show_container_logs

      return 1

    fi


    now="$(date +%s)"

    elapsed=$((now - started))


    if (( elapsed >= timeout )); then

      echo
      echo "❌ HTTP readiness timeout for ${description}."

      echo
      echo "Last curl diagnostic:"

      if [[ -s "${response_file}" ]]; then
        cat "${response_file}"
      else
        echo "No curl diagnostic available."
      fi


      show_container_logs

      return 1

    fi


    log "HTTP not ready yet... attempt=${attempt}, elapsed=${elapsed}s/${timeout}s"


    sleep "${HEALTH_INTERVAL_SECONDS}"

  done

}


# ============================================================
# KasmVNC HTTP Health
# ============================================================

section "❤️ HTTP readiness — KasmVNC"


wait_for_http \
  "http://${MT5_WEB_BIND}:${MT5_WEB_PORT}/" \
  "${HTTP_TIMEOUT_SECONDS}" \
  "KasmVNC"


# ============================================================
# Optional HTTP Header Diagnostics
# ============================================================

section "🔬 KasmVNC HTTP diagnostics"


curl \
  --silent \
  --show-error \
  --head \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${MT5_WEB_BIND}:${MT5_WEB_PORT}/" \
  2>&1 \
  | head -n 30 \
  || true


# ============================================================
# Cloudflare Tunnel
# ============================================================

start_cloudflare() {

  section "☁️ Start Cloudflare Quick Tunnel"


  rm -f \
    "${CLOUDFLARE_LOG}" \
    "${TUNNEL_URL_FILE}"


  touch "${CLOUDFLARE_LOG}"


  log "Starting Cloudflare tunnel..."


  nohup cloudflared tunnel \
    --no-autoupdate \
    --url "http://${MT5_WEB_BIND}:${MT5_WEB_PORT}" \
    > "${CLOUDFLARE_LOG}" \
    2>&1 &


  CLOUDFLARED_PID="$!"


  log "cloudflared PID: ${CLOUDFLARED_PID}"


  local started
  local now
  local elapsed
  local attempt=0

  local tunnel_url=""


  started="$(date +%s)"


  while true; do

    attempt=$((attempt + 1))


    if ! kill -0 \
      "${CLOUDFLARED_PID}" \
      2>/dev/null; then

      echo
      echo "❌ cloudflared stopped unexpectedly."

      cat "${CLOUDFLARE_LOG}" || true

      die "Cloudflare tunnel failed to start."

    fi


    tunnel_url="$(
      grep \
        -Eo \
        'https://[-a-zA-Z0-9]+\.trycloudflare\.com' \
        "${CLOUDFLARE_LOG}" \
        2>/dev/null \
        | head -n 1 \
        || true
    )


    if [[ -n "${tunnel_url}" ]]; then

      printf '%s\n' \
        "${tunnel_url}" \
        > "${TUNNEL_URL_FILE}"


      log "🌐 Cloudflare public URL detected:"
      echo
      echo "    ${tunnel_url}"
      echo

      break

    fi


    now="$(date +%s)"

    elapsed=$((now - started))


    if (( elapsed >= TUNNEL_TIMEOUT_SECONDS )); then

      echo
      echo "❌ Cloudflare URL detection timed out."

      echo
      echo "Cloudflare log:"

      cat "${CLOUDFLARE_LOG}" || true

      die "Unable to obtain Cloudflare tunnel URL."

    fi


    log "Waiting for Cloudflare URL... attempt=${attempt}, elapsed=${elapsed}s/${TUNNEL_TIMEOUT_SECONDS}s"


    sleep 2

  done


  # ----------------------------------------------------------
  # Public connectivity
  # ----------------------------------------------------------

  section "🌍 Cloudflare public HTTP health"


  local public_started
  local public_now
  local public_elapsed
  local public_attempt=0
  local public_code


  public_started="$(date +%s)"


  while true; do

    public_attempt=$((public_attempt + 1))


    public_code="$(
      curl \
        --silent \
        --show-error \
        --output /dev/null \
        --write-out '%{http_code}' \
        --connect-timeout 5 \
        --max-time "${PUBLIC_HTTP_TIMEOUT_SECONDS}" \
        "${tunnel_url}/" \
        2>/dev/null
    )"

    local curl_exit=$?


    if (( curl_exit == 0 )); then

      log "Public HTTP status: ${public_code}"


      case "${public_code}" in

        2??|3??|401|403)

          log "✅ Public Cloudflare tunnel is reachable."

          break
          ;;

        *)

          log "⚠️ Public tunnel responded with HTTP ${public_code}."

          ;;

      esac

    else

      log "⚠️ Public HTTP connection failed. curl exit=${curl_exit}"

    fi


    public_now="$(date +%s)"

    public_elapsed=$((public_now - public_started))


    if (( public_elapsed >= TUNNEL_TIMEOUT_SECONDS )); then

      log "⚠️ Public HTTP check timed out."

      log "The Cloudflare tunnel URL exists, but public connectivity could not be confirmed."

      break

    fi


    sleep "${HEALTH_INTERVAL_SECONDS}"

  done

}


if is_true "${ENABLE_TUNNEL}"; then

  start_cloudflare

fi


# ============================================================
# Connection Information
# ============================================================

section "🔗 CONNECTION INFORMATION"


echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                 🚀 MT5 CLOUD DESKTOP                       ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║ User:     ${MT5_WEB_USER}"
echo "║ Password: ${MT5_WEB_PASSWORD}"
echo "║                                                            ║"


if [[ -s "${TUNNEL_URL_FILE}" ]]; then

  TUNNEL_URL="$(cat "${TUNNEL_URL_FILE}")"

  echo "║ Browser:  ${TUNNEL_URL}"
  echo "║                                                            ║"

else

  echo "║ Browser:  http://${MT5_WEB_BIND}:${MT5_WEB_PORT}"
  echo "║                                                            ║"

fi


echo "║ RPyC:     ${MT5_API_BIND}:${MT5_API_PORT}"
echo "║                                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo


# ============================================================
# GitHub Step Summary
# ============================================================

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then

  cat >> "${GITHUB_STEP_SUMMARY}" <<EOF

# 🚀 MT5 Cloud Desktop

| Setting | Value |
|---|---|
| Resolution | \`${RESOLUTION}\` |
| Session | \`${SESSION_MINUTES} minutes\` |
| Docker Image | \`${MT5_IMAGE}\` |
| Container | \`${CONTAINER_NAME}\` |
| Web Port | \`${MT5_WEB_PORT}\` |
| RPyC Port | \`${MT5_API_PORT}\` |
| Cloudflare | \`${ENABLE_TUNNEL}\` |

## 🔗 Connection

EOF


  if [[ -s "${TUNNEL_URL_FILE}" ]]; then

    TUNNEL_URL="$(cat "${TUNNEL_URL_FILE}")"


    cat >> "${GITHUB_STEP_SUMMARY}" <<EOF
### 🌐 Browser

\`${TUNNEL_URL}\`

### 👤 Username

\`${MT5_WEB_USER}\`

### 🔑 Password

\`${MT5_WEB_PASSWORD}\`

EOF

  else

    cat >> "${GITHUB_STEP_SUMMARY}" <<EOF
Cloudflare Tunnel is disabled.

Local web endpoint:

\`http://${MT5_WEB_BIND}:${MT5_WEB_PORT}\`

EOF

  fi


  cat >> "${GITHUB_STEP_SUMMARY}" <<EOF

## 🔌 Python / mt5linux

Private RPyC endpoint:

\`${MT5_API_BIND}:${MT5_API_PORT}\`

## 🐳 Docker

Image is pulled directly from the upstream registry.

No Docker build is performed.

No GitHub Actions cache is used.

## ❤️ Health

- Docker container: **RUNNING**
- KasmVNC TCP: **READY**
- mt5linux/RPyC TCP: **READY**
- KasmVNC HTTP: **READY**
- Cloudflare: **${ENABLE_TUNNEL}**

EOF

fi


# ============================================================
# Session Monitor
# ============================================================

section "⏱️ Monitor MT5 Session"


SESSION_SECONDS=$((SESSION_MINUTES * 60))

START_TIME_UNIX="$(date +%s)"

END_TIME_UNIX=$((START_TIME_UNIX + SESSION_SECONDS))


log "Session started : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

log "Duration        : ${SESSION_MINUTES} minutes"

log "End time        : $(date -u -d "@${END_TIME_UNIX}" '+%Y-%m-%d %H:%M:%S UTC')"


while true; do

  NOW_UNIX="$(date +%s)"


  if (( NOW_UNIX >= END_TIME_UNIX )); then

    echo
    log "⏰ Session duration reached."

    break

  fi


  # ----------------------------------------------------------
  # Container health
  # ----------------------------------------------------------

  if ! container_running; then

    echo
    echo "❌ MT5 container stopped unexpectedly."

    show_container_logs

    exit 1

  fi


  # ----------------------------------------------------------
  # Remaining time
  # ----------------------------------------------------------

  REMAINING_SECONDS=$((END_TIME_UNIX - NOW_UNIX))

  REMAINING_MINUTES=$((REMAINING_SECONDS / 60))

  REMAINING_ONLY_SECONDS=$((REMAINING_SECONDS % 60))


  CONTAINER_STARTED="$(
    docker inspect \
      --format '{{.State.StartedAt}}' \
      "${CONTAINER_NAME}" \
      2>/dev/null \
      || echo "unknown"
  )"


  echo
  echo "------------------------------------------------------------"
  echo "[$(timestamp)]"
  echo "Container : RUNNING"
  echo "Remaining : ${REMAINING_MINUTES}m ${REMAINING_ONLY_SECONDS}s"
  echo "Started   : ${CONTAINER_STARTED}"
  echo "------------------------------------------------------------"


  # ----------------------------------------------------------
  # Resource snapshot
  # ----------------------------------------------------------

  if (( REMAINING_SECONDS % 60 < 30 )); then

    docker stats \
      --no-stream \
      --format \
      'CPU={{.CPUPerc}} | MEM={{.MemUsage}} ({{.MemPerc}}) | NET={{.NetIO}} | BLOCK={{.BlockIO}}' \
      "${CONTAINER_NAME}" \
      2>/dev/null \
      || true

  fi


  sleep 30

done


# ============================================================
# Final Diagnostics
# ============================================================

section "📊 Final MT5 diagnostics"


echo
echo "Container:"
docker inspect \
  --format \
  'Name={{.Name}} | Status={{.State.Status}} | Running={{.State.Running}} | Started={{.State.StartedAt}}' \
  "${CONTAINER_NAME}" \
  2>/dev/null \
  || true


echo
echo "Docker stats:"
docker stats \
  --no-stream \
  --format \
  'CPU={{.CPUPerc}} | MEM={{.MemUsage}} ({{.MemPerc}}) | NET={{.NetIO}} | BLOCK={{.BlockIO}}' \
  "${CONTAINER_NAME}" \
  2>/dev/null \
  || true


echo
echo "Listening ports:"
ss -lntp \
  2>/dev/null \
  | grep -E ":(${MT5_WEB_PORT}|${MT5_API_PORT})" \
  || true


echo
echo "MT5 container processes:"
docker top \
  "${CONTAINER_NAME}" \
  2>/dev/null \
  || true


# ============================================================
# Save Diagnostics
# ============================================================

if is_true "${SAVE_ARTIFACTS}"; then

  section "📦 Prepare diagnostics"


  {
    echo "MT5 Cloud Desktop Diagnostics"
    echo "=============================="
    echo
    echo "Timestamp: $(timestamp)"
    echo "Run ID: ${GITHUB_RUN_ID:-local}"
    echo "Image: ${MT5_IMAGE}"
    echo "Container: ${CONTAINER_NAME}"
    echo "Resolution: ${RESOLUTION}"
    echo "Session minutes: ${SESSION_MINUTES}"
    echo
    echo "Health configuration:"
    echo "TCP timeout: ${TCP_TIMEOUT_SECONDS}s"
    echo "HTTP timeout: ${HTTP_TIMEOUT_SECONDS}s"
    echo "Tunnel timeout: ${TUNNEL_TIMEOUT_SECONDS}s"
    echo "Health interval: ${HEALTH_INTERVAL_SECONDS}s"
    echo
    echo "Docker:"
    docker --version
    echo
    echo "Architecture:"
    uname -m
    echo
    echo "Disk:"
    df -h /
    echo
    echo "Memory:"
    free -h
    echo
    echo "Container inspect:"
    docker inspect \
      "${CONTAINER_NAME}" \
      2>&1 \
      || true
    echo
    echo "Container logs:"
    docker logs \
      --tail 1000 \
      "${CONTAINER_NAME}" \
      2>&1 \
      || true
  } > "${LOG_DIR}/diagnostics.txt"


  if [[ -s "${CLOUDFLARE_LOG}" ]]; then

    cp \
      "${CLOUDFLARE_LOG}" \
      "${LOG_DIR}/cloudflared.log"

  fi


  if [[ -s "${TUNNEL_URL_FILE}" ]]; then

    cp \
      "${TUNNEL_URL_FILE}" \
      "${LOG_DIR}/tunnel_url.txt"

  fi


  log "Diagnostics saved to:"
  log "${LOG_DIR}"

fi


# ============================================================
# Successful Completion
# ============================================================

section "✅ MT5 SESSION COMPLETED"


echo
echo "MetaTrader 5 session completed normally."
echo
echo "Duration   : ${SESSION_MINUTES} minutes"
echo "Resolution : ${RESOLUTION}"


if [[ -s "${TUNNEL_URL_FILE}" ]]; then

  echo
  echo "🌐 Browser URL:"
  cat "${TUNNEL_URL_FILE}"

fi


echo
echo "The cleanup handler will now stop:"
echo "  • Cloudflare Tunnel"
echo "  • MT5 Docker container"
echo
echo "✅ Runtime finished successfully."
