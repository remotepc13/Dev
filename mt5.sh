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
# │ Wine                          │
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

LOG_DIR="${LOG_DIR:-${GITHUB_WORKSPACE:-$PWD}/logs}"
TUNNEL_DIR="${TUNNEL_DIR:-${GITHUB_WORKSPACE:-$PWD}/tunnel}"
MT5_DATA_DIR="${MT5_DATA_DIR:-${GITHUB_WORKSPACE:-$PWD}/mt5_data}"

CLOUDFLARE_LOG="${CLOUDFLARE_LOG:-${TUNNEL_DIR}/cloudflared.log}"
TUNNEL_URL_FILE="${TUNNEL_URL_FILE:-${TUNNEL_DIR}/tunnel_url.txt}"

SESSION_MINUTES="${INPUT_SESSION_MINUTES:-60}"
RESOLUTION="${INPUT_RESOLUTION:-1920x1080}"

ENABLE_TUNNEL="${INPUT_ENABLE_TUNNEL:-true}"
SAVE_ARTIFACTS="${INPUT_SAVE_ARTIFACTS:-true}"
CLEAN_WORKSPACE="${INPUT_CLEAN_WORKSPACE:-false}"


# ============================================================
# Runtime State
# ============================================================

CLOUDFLARED_PID=""

START_TIME_UNIX="0"
END_TIME_UNIX="0"


# ============================================================
# Logging
# ============================================================

mkdir -p \
  "${LOG_DIR}" \
  "${TUNNEL_DIR}"

MAIN_LOG="${LOG_DIR}/mt5-runtime.log"

touch "${MAIN_LOG}"

exec > >(tee -a "${MAIN_LOG}") 2>&1


# ============================================================
# Utility Functions
# ============================================================

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


append_summary() {

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat >> "${GITHUB_STEP_SUMMARY}"
  fi
}


# ============================================================
# Cleanup
# ============================================================

cleanup() {

  local exit_code=$?

  set +e

  section "🧹 Cleanup"

  if [[ -n "${CLOUDFLARED_PID}" ]]; then

    if kill -0 "${CLOUDFLARED_PID}" 2>/dev/null; then

      log "Stopping Cloudflare process..."

      kill "${CLOUDFLARED_PID}" 2>/dev/null || true

      sleep 2

      kill -9 "${CLOUDFLARED_PID}" 2>/dev/null || true

    fi

  fi


  if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then

    RUNNING="$(
      docker inspect \
        --format '{{.State.Running}}' \
        "${CONTAINER_NAME}" \
        2>/dev/null || echo "false"
    )"

    if [[ "${RUNNING}" == "true" ]]; then

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


case "${ENABLE_TUNNEL,,}" in
  true|false|1|0|yes|no|y|n|on|off)
    ;;
  *)
    die "Invalid ENABLE_TUNNEL value: ${ENABLE_TUNNEL}"
    ;;
esac


log "Container       : ${CONTAINER_NAME}"
log "Image           : ${MT5_IMAGE}"
log "Resolution      : ${RESOLUTION}"
log "Session         : ${SESSION_MINUTES} minutes"
log "Web bind        : ${MT5_WEB_BIND}:${MT5_WEB_PORT}"
log "API bind        : ${MT5_API_BIND}:${MT5_API_PORT}"
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
log "Docker info:"
docker info --format \
  'Server={{.ServerVersion}} | Storage={{.Driver}} | CPUs={{.NCPU}} | Memory={{.MemTotal}}' \
  2>/dev/null || true


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
# Install Cloudflare Tunnel
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

if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then

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

# Intentionally no Docker cache.
# GitHub-hosted runners are ephemeral.
docker pull "${MT5_IMAGE}"

log "✅ MT5 image pulled successfully."


# ============================================================
# Verify Image
# ============================================================

section "🔍 Verify Docker image"

docker image inspect "${MT5_IMAGE}" \
  --format \
  'Repository={{index .RepoTags 0}} | ID={{.Id}} | Size={{.Size}} bytes' \
  || die "Unable to inspect MT5 image."


# ============================================================
# Start MT5 Container
# ============================================================

section "🚀 Start MetaTrader 5 container"

log "Starting container..."

# IMPORTANT:
# Do NOT use --init here.
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

log "Container PID : ${CONTAINER_PID}"
log "Running       : ${CONTAINER_RUNNING}"


if [[ "${CONTAINER_RUNNING}" != "true" ]]; then

  echo
  echo "Container logs:"
  docker logs --tail 300 "${CONTAINER_NAME}" 2>&1 || true

  die "MT5 container is not running."

fi


# ============================================================
# Wait for KasmVNC
# ============================================================

section "⏳ Wait for KasmVNC :3000"

WEB_READY="false"

for attempt in $(seq 1 60); do

  if nc -z \
    "${MT5_WEB_BIND}" \
    "${MT5_WEB_PORT}" \
    >/dev/null 2>&1; then

    WEB_READY="true"

    log "✅ KasmVNC port is ready."

    break

  fi


  if ! docker inspect \
    --format '{{.State.Running}}' \
    "${CONTAINER_NAME}" \
    2>/dev/null | grep -qx "true"; then

    echo
    echo "❌ Container stopped during startup."

    docker logs \
      --tail 300 \
      "${CONTAINER_NAME}" \
      2>&1 || true

    die "MT5 container stopped unexpectedly."

  fi


  log "Waiting for KasmVNC... ${attempt}/60"

  sleep 5

done


if [[ "${WEB_READY}" != "true" ]]; then

  echo
  echo "Recent container logs:"
  docker logs \
    --tail 400 \
    "${CONTAINER_NAME}" \
    2>&1 || true

  die "KasmVNC port ${MT5_WEB_PORT} did not become ready."

fi


# ============================================================
# Wait for mt5linux / RPyC
# ============================================================

section "⏳ Wait for mt5linux / RPyC :8001"

API_READY="false"

for attempt in $(seq 1 60); do

  if nc -z \
    "${MT5_API_BIND}" \
    "${MT5_API_PORT}" \
    >/dev/null 2>&1; then

    API_READY="true"

    log "✅ mt5linux/RPyC port is ready."

    break

  fi


  if ! docker inspect \
    --format '{{.State.Running}}' \
    "${CONTAINER_NAME}" \
    2>/dev/null | grep -qx "true"; then

    echo
    echo "❌ Container stopped during RPyC startup."

    docker logs \
      --tail 300 \
      "${CONTAINER_NAME}" \
      2>&1 || true

    die "MT5 container stopped unexpectedly."

  fi


  log "Waiting for RPyC... ${attempt}/60"

  sleep 5

done


if [[ "${API_READY}" != "true" ]]; then

  echo
  echo "Recent container logs:"
  docker logs \
    --tail 400 \
    "${CONTAINER_NAME}" \
    2>&1 || true

  die "mt5linux/RPyC port ${MT5_API_PORT} did not become ready."

fi


# ============================================================
# HTTP Health Check
# ============================================================

section "❤️ KasmVNC HTTP health check"

HTTP_CODE="$(
  curl \
    --silent \
    --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    --max-time 15 \
    "http://${MT5_WEB_BIND}:${MT5_WEB_PORT}/" \
    2>/dev/null || echo "000"
)"

log "HTTP status: ${HTTP_CODE}"


case "${HTTP_CODE}" in
  2??|3??|401|403)
    log "✅ Web service is responding."
    ;;
  *)
    echo
    echo "Container logs:"
    docker logs --tail 300 "${CONTAINER_NAME}" 2>&1 || true

    die "Unexpected HTTP status from KasmVNC: ${HTTP_CODE}"
    ;;
esac


# ============================================================
# Start Cloudflare Quick Tunnel
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


  local tunnel_url=""

  for attempt in $(seq 1 60); do

    if ! kill -0 "${CLOUDFLARED_PID}" 2>/dev/null; then

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
    )"


    if [[ -n "${tunnel_url}" ]]; then

      printf '%s\n' "${tunnel_url}" \
        > "${TUNNEL_URL_FILE}"

      log "🌐 Public URL:"
      echo
      echo "    ${tunnel_url}"
      echo

      break

    fi


    sleep 2

  done


  if [[ ! -s "${TUNNEL_URL_FILE}" ]]; then

    echo
    echo "Cloudflare log:"
    cat "${CLOUDFLARE_LOG}" || true

    die "Unable to obtain Cloudflare tunnel URL."

  fi


  tunnel_url="$(cat "${TUNNEL_URL_FILE}")"


  # ----------------------------------------------------------
  # Public connectivity check
  # ----------------------------------------------------------

  log "Checking public tunnel..."

  local public_code

  public_code="$(
    curl \
      --silent \
      --show-error \
      --output /dev/null \
      --write-out '%{http_code}' \
      --max-time 20 \
      "${tunnel_url}/" \
      2>/dev/null || echo "000"
  )"


  log "Public HTTP status: ${public_code}"


  case "${public_code}" in
    2??|3??|401|403)
      log "✅ Public tunnel is reachable."
      ;;
    *)
      log "⚠️ Public tunnel returned HTTP ${public_code}."
      log "The tunnel exists, but the web application may still be initializing."
      ;;
  esac
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
**Browser URL**

\`${TUNNEL_URL}\`

**Username**

\`${MT5_WEB_USER}\`

**Password**

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

## 📦 Runtime

Docker image is pulled directly from the upstream registry.

No Docker build or GitHub Actions cache is used.

EOF

fi


# ============================================================
# Session Monitor
# ============================================================

section "⏱️ Monitor MT5 Session"

# IMPORTANT:
# Use Bash arithmetic expansion.
#
# Correct:
#   SESSION_SECONDS=$((SESSION_MINUTES * 60))
#
# Incorrect:
#   SESSION_SECONDS=$(($SESSION_MINUTES * 60))
#   SESSION_SECONDS=$( ( $SESSION_MINUTES * 60 ) )

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

  RUNNING="$(
    docker inspect \
      --format '{{.State.Running}}' \
      "${CONTAINER_NAME}" \
      2>/dev/null \
      || echo "false"
  )"


  if [[ "${RUNNING}" != "true" ]]; then

    echo
    echo "❌ MT5 container stopped unexpectedly."

    echo
    echo "Container inspection:"
    docker inspect \
      "${CONTAINER_NAME}" \
      2>&1 || true

    echo
    echo "Container logs:"
    docker logs \
      --tail 300 \
      "${CONTAINER_NAME}" \
      2>&1 || true

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
  # Resource snapshot every ~60 seconds
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
# Final Runtime Diagnostics
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
    docker inspect "${CONTAINER_NAME}" 2>&1 || true
    echo
    echo "Container logs:"
    docker logs --tail 1000 "${CONTAINER_NAME}" 2>&1 || true
  } > "${LOG_DIR}/diagnostics.txt"


  if [[ -s "${CLOUDFLARE_LOG}" ]]; then
    cp \
      "${CLOUDFLARE_LOG}" \
      "${LOG_DIR}/cloudflared.log"
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
