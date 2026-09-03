#!/usr/bin/env bash

# ============================================================
# MT5 CLOUD DESKTOP
# ============================================================
#
# GitHub Actions runtime for:
#
#   MetaTrader 5
#   Wine
#   KasmVNC
#   mt5linux
#   RPyC
#   Cloudflare Quick Tunnel
#
# Design:
#
#   GitHub Runner
#       │
#       ▼
#   Docker Container
#       │
#       ├── KasmVNC :3000
#       │
#       └── mt5linux/RPyC :8001
#                │
#                ▼
#            Python / MT5
#
# Cloudflare:
#
#   Internet
#      │
#      ▼
#   trycloudflare.com
#      │
#      ▼
#   127.0.0.1:3000
#
# IMPORTANT:
#
# - No Docker build
# - No GitHub Cache
# - No Docker --init
# - Port 8001 remains private
# - Only KasmVNC :3000 is tunneled
# ============================================================


# ============================================================
# Bash Safety
# ============================================================

set -Eeuo pipefail


# ============================================================
# Basic Variables
# ============================================================

CONTAINER_NAME="${CONTAINER_NAME:-mt5-cloud}"

MT5_IMAGE="${MT5_IMAGE:-gmag11/metatrader5_vnc:latest}"


MT5_WEB_BIND="${MT5_WEB_BIND:-127.0.0.1}"

MT5_WEB_PORT="${MT5_WEB_PORT:-3000}"


MT5_API_BIND="${MT5_API_BIND:-127.0.0.1}"

MT5_API_PORT="${MT5_API_PORT:-8001}"


MT5_WEB_USER="${MT5_WEB_USER:-trader}"

MT5_WEB_PASSWORD="${MT5_WEB_PASSWORD:-MT5-Demo-2026-StrongPassword!}"


TZ="${TZ:-UTC}"


# ============================================================
# GitHub Workspace
# ============================================================

WORKSPACE_ROOT="${GITHUB_WORKSPACE:-$(pwd)}"


LOG_DIR="${LOG_DIR:-${WORKSPACE_ROOT}/logs}"

TUNNEL_DIR="${TUNNEL_DIR:-${WORKSPACE_ROOT}/tunnel}"

MT5_DATA_DIR="${MT5_DATA_DIR:-${WORKSPACE_ROOT}/mt5_data}"


CLOUDFLARE_LOG="${CLOUDFLARE_LOG:-${TUNNEL_DIR}/cloudflared.log}"

TUNNEL_URL_FILE="${TUNNEL_URL_FILE:-${TUNNEL_DIR}/tunnel_url.txt}"


# ============================================================
# Inputs
# ============================================================

RESOLUTION="${INPUT_RESOLUTION:-1920x1080}"

SESSION_MINUTES="${INPUT_SESSION_MINUTES:-60}"

ENABLE_TUNNEL="${INPUT_ENABLE_TUNNEL:-true}"

SAVE_ARTIFACTS="${INPUT_SAVE_ARTIFACTS:-true}"

CLEAN_WORKSPACE="${INPUT_CLEAN_WORKSPACE:-false}"


# ============================================================
# Timeouts
# ============================================================

TCP_TIMEOUT_SECONDS="${TCP_TIMEOUT_SECONDS:-120}"

HTTP_TIMEOUT_SECONDS="${HTTP_TIMEOUT_SECONDS:-120}"

TUNNEL_TIMEOUT_SECONDS="${TUNNEL_TIMEOUT_SECONDS:-120}"

HEALTH_INTERVAL_SECONDS="${HEALTH_INTERVAL_SECONDS:-3}"

PUBLIC_HTTP_TIMEOUT_SECONDS="${PUBLIC_HTTP_TIMEOUT_SECONDS:-20}"


# ============================================================
# Runtime State
# ============================================================

CLOUDFLARED_PID=""

MAIN_LOG=""

START_TIME_UNIX="0"

END_TIME_UNIX="0"


# ============================================================
# Directories
# ============================================================

mkdir -p \
  "${LOG_DIR}" \
  "${TUNNEL_DIR}" \
  "${MT5_DATA_DIR}"


MAIN_LOG="${LOG_DIR}/mt5-runtime.log"

touch "${MAIN_LOG}"


# ============================================================
# Logging
# ============================================================

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
  echo

}


die() {

  echo

  echo "❌ ERROR: $*"

  exit 1

}


# ============================================================
# Error Handler
# ============================================================

on_error() {

  local exit_code=$?

  local line_number="${BASH_LINENO[0]:-unknown}"

  local command="${BASH_COMMAND:-unknown}"


  echo

  echo "============================================================"
  echo "❌ COMMAND FAILED"
  echo "============================================================"

  echo

  echo "Exit code : ${exit_code}"

  echo "Line      : ${line_number}"

  echo "Command   : ${command}"

  echo

  echo "Container status:"

  docker inspect \
    --format \
    'Running={{.State.Running}} | Status={{.State.Status}} | ExitCode={{.State.ExitCode}} | Started={{.State.StartedAt}}' \
    "${CONTAINER_NAME}" \
    2>/dev/null \
    || true


  echo

  echo "Recent container logs:"

  docker logs \
    --tail 200 \
    "${CONTAINER_NAME}" \
    2>&1 \
    || true


  echo

  echo "============================================================"


  return "${exit_code}"

}


trap on_error ERR


# ============================================================
# Container Functions
# ============================================================

container_exists() {

  docker inspect \
    "${CONTAINER_NAME}" \
    >/dev/null 2>&1

}


container_running() {

  local state

  state="$(
    docker inspect \
      --format '{{.State.Running}}' \
      "${CONTAINER_NAME}" \
      2>/dev/null \
      || echo "false"
  )"


  [[ "${state}" == "true" ]]

}


show_container_logs() {

  echo

  echo "------------------------------------------------------------"

  echo "📋 MT5 container logs"

  echo "------------------------------------------------------------"


  docker logs \
    --tail 500 \
    "${CONTAINER_NAME}" \
    2>&1 \
    || true


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
  # Cloudflare
  # ----------------------------------------------------------

  if [[ -n "${CLOUDFLARED_PID}" ]]; then

    if kill -0 \
      "${CLOUDFLARED_PID}" \
      2>/dev/null; then

      log "Stopping Cloudflare..."

      kill \
        "${CLOUDFLARED_PID}" \
        2>/dev/null \
        || true


      sleep 2


      kill -9 \
        "${CLOUDFLARED_PID}" \
        2>/dev/null \
        || true

    fi

  fi


  # ----------------------------------------------------------
  # Docker container
  # ----------------------------------------------------------

  if container_exists; then

    if container_running; then

      log "Stopping MT5 container..."


      docker stop \
        --timeout 15 \
        "${CONTAINER_NAME}" \
        2>&1 \
        || true

    fi


    log "Removing MT5 container..."


    docker rm \
      -f \
      "${CONTAINER_NAME}" \
      2>&1 \
      || true

  fi


  echo

  echo "============================================================"

  echo "🏁 Cleanup completed"

  echo "Exit code: ${exit_code}"

  echo "============================================================"


  return "${exit_code}"

}


trap cleanup EXIT


# ============================================================
# Validate Configuration
# ============================================================

section "🔎 Validate configuration"


if ! [[ "${SESSION_MINUTES}" =~ ^[0-9]+$ ]]; then

  die "Invalid SESSION_MINUTES: ${SESSION_MINUTES}"

fi


if (( SESSION_MINUTES < 1 )); then

  die "Session duration must be at least 1 minute."

fi


if (( SESSION_MINUTES > 300 )); then

  die "Session duration cannot exceed 300 minutes."

fi


if ! [[ "${RESOLUTION}" =~ ^[0-9]+x[0-9]+$ ]]; then

  die "Invalid resolution: ${RESOLUTION}"

fi


if ! [[ "${TCP_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then

  die "Invalid TCP timeout."

fi


if ! [[ "${HTTP_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then

  die "Invalid HTTP timeout."

fi


if ! [[ "${TUNNEL_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then

  die "Invalid tunnel timeout."

fi


if ! [[ "${HEALTH_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]]; then

  die "Invalid health interval."

fi


log "Container       : ${CONTAINER_NAME}"

log "Image           : ${MT5_IMAGE}"

log "Resolution      : ${RESOLUTION}"

log "Session         : ${SESSION_MINUTES} minutes"

log "Web endpoint    : ${MT5_WEB_BIND}:${MT5_WEB_PORT}"

log "API endpoint    : ${MT5_API_BIND}:${MT5_API_PORT}"

log "Tunnel enabled  : ${ENABLE_TUNNEL}"

log "Clean workspace : ${CLEAN_WORKSPACE}"

log "Save artifacts  : ${SAVE_ARTIFACTS}"

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
# Architecture
# ============================================================

section "🧬 Validate architecture"


ARCH="$(uname -m)"


if [[ "${ARCH}" != "x86_64" ]]; then

  die "This MT5 image requires x86_64 / AMD64. Current architecture: ${ARCH}"

fi


log "✅ AMD64 / x86_64 detected."


# ============================================================
# Install Dependencies
# ============================================================

section "📦 Install runtime dependencies"


export DEBIAN_FRONTEND=noninteractive


sudo apt-get update -qq


sudo apt-get install \
  -y \
  -qq \
  ca-certificates \
  curl \
  jq \
  netcat-openbsd \
  procps


log "✅ Dependencies installed."


# ============================================================
# Install Cloudflared
# ============================================================

install_cloudflared() {

  if command -v cloudflared >/dev/null 2>&1; then

    log "cloudflared is already installed."

    cloudflared --version

    return 0

  fi


  log "Downloading latest cloudflared..."


  local package="/tmp/cloudflared-amd64.deb"


  rm -f "${package}"


  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 15 \
    --max-time 120 \
    -o "${package}" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"


  sudo dpkg \
    -i \
    "${package}"


  rm -f "${package}"


  if ! command -v cloudflared >/dev/null 2>&1; then

    die "cloudflared installation failed."

  fi


  cloudflared --version


  log "✅ cloudflared installed."

}


if [[ "${ENABLE_TUNNEL,,}" == "true" ]]; then

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


rm -f \
  "${TUNNEL_URL_FILE}" \
  "${CLOUDFLARE_LOG}" \
  "${LOG_DIR}/http-health-error.txt"


if [[ "${CLEAN_WORKSPACE,,}" == "true" ]]; then

  log "🧹 Cleaning MT5 workspace..."


  find \
    "${MT5_DATA_DIR}" \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf {} +


  log "✅ MT5 workspace cleaned."

else

  log "Keeping MT5 workspace."

fi


# ============================================================
# Remove Existing Container
# ============================================================

section "🧹 Remove stale MT5 container"


if container_exists; then

  log "Existing container found."


  docker stop \
    --timeout 10 \
    "${CONTAINER_NAME}" \
    2>&1 \
    || true


  docker rm \
    -f \
    "${CONTAINER_NAME}" \
    2>&1 \
    || true


  log "✅ Old container removed."

else

  log "No existing MT5 container."

fi


# ============================================================
# Pull Image
# ============================================================

section "🐳 Pull MT5 image"


log "Pulling image:"

echo "${MT5_IMAGE}"


docker pull \
  "${MT5_IMAGE}"


log "✅ MT5 image pulled successfully."


# ============================================================
# Image Information
# ============================================================

section "🔍 Docker image information"


docker image inspect \
  "${MT5_IMAGE}" \
  --format \
  'Repository={{index .RepoTags 0}} | ID={{.Id}} | Size={{.Size}} bytes'


# ============================================================
# Start Container
# ============================================================

section "🚀 Start MetaTrader 5 container"


log "Starting Docker container..."


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


log "✅ Container started."


# ============================================================
# Container Verification
# ============================================================

section "🔍 Verify MT5 container"


CONTAINER_PID="$(
  docker inspect \
    --format '{{.State.Pid}}' \
    "${CONTAINER_NAME}"
)"


CONTAINER_STATUS="$(
  docker inspect \
    --format '{{.State.Status}}' \
    "${CONTAINER_NAME}"
)"


CONTAINER_RUNNING="$(
  docker inspect \
    --format '{{.State.Running}}' \
    "${CONTAINER_NAME}"
)"


log "Container PID : ${CONTAINER_PID}"

log "Status        : ${CONTAINER_STATUS}"

log "Running       : ${CONTAINER_RUNNING}"


if [[ "${CONTAINER_RUNNING}" != "true" ]]; then

  show_container_logs

  die "MT5 container failed to start."

fi


# ============================================================
# TCP Health Check
# ============================================================

wait_for_tcp() {

  local host="$1"

  local port="$2"

  local timeout="$3"

  local description="$4"

  local start_time

  local current_time

  local elapsed


  start_time="$(date +%s)"


  log "Waiting for ${description} at ${host}:${port}..."


  while true; do


    if nc \
      -z \
      -w 2 \
      "${host}" \
      "${port}" \
      >/dev/null \
      2>&1; then

      log "✅ ${description} TCP port is ready."

      return 0

    fi


    if ! container_running; then

      echo

      echo "❌ Container stopped while waiting for ${description}."

      show_container_logs

      return 1

    fi


    current_time="$(date +%s)"

    elapsed=$((current_time - start_time))


    if (( elapsed >= timeout )); then

      echo

      echo "❌ TCP timeout for ${description}."

      show_container_logs

      return 1

    fi


    log "⏳ ${description} not ready yet: ${elapsed}s/${timeout}s"


    sleep "${HEALTH_INTERVAL_SECONDS}"

  done

}


# ============================================================
# KasmVNC TCP
# ============================================================

section "⏳ TCP readiness — KasmVNC :3000"


wait_for_tcp \
  "${MT5_WEB_BIND}" \
  "${MT5_WEB_PORT}" \
  "${TCP_TIMEOUT_SECONDS}" \
  "KasmVNC"


# ============================================================
# mt5linux TCP
# ============================================================

section "⏳ TCP readiness — mt5linux/RPyC :8001"


wait_for_tcp \
  "${MT5_API_BIND}" \
  "${MT5_API_PORT}" \
  "${TCP_TIMEOUT_SECONDS}" \
  "mt5linux/RPyC"


# ============================================================
# HTTP Probe
# ============================================================

http_probe() {

  local url="$1"

  local error_file="$2"

  local code=""

  local rc=0


  : > "${error_file}"


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

  fi


  if (( rc != 0 )); then

    echo "curl_exit=${rc}"

    echo "http_code=${code:-000}"


    if [[ -s "${error_file}" ]]; then

      echo "curl_error:"

      cat "${error_file}"

    fi


    return 1

  fi


  echo "http_code=${code}"


  # KasmVNC may return:
  #
  # 200 = success
  # 3xx = redirect
  # 401 = authentication required
  # 403 = forbidden/auth layer
  #
  # All of these prove the HTTP service is alive.


  if [[ "${code}" =~ ^2[0-9][0-9]$ ]]; then

    return 0

  fi


  if [[ "${code}" =~ ^3[0-9][0-9]$ ]]; then

    return 0

  fi


  if [[ "${code}" == "401" ]]; then

    return 0

  fi


  if [[ "${code}" == "403" ]]; then

    return 0

  fi


  return 1

}


# ============================================================
# HTTP Readiness
# ============================================================

wait_for_http() {

  local url="$1"

  local timeout="$2"

  local description="$3"

  local error_file="${LOG_DIR}/http-health-error.txt"

  local start_time

  local current_time

  local elapsed

  local attempt=0


  start_time="$(date +%s)"


  log "Waiting for ${description} HTTP service..."

  log "URL: ${url}"


  while true; do

    attempt=$((attempt + 1))


    # --------------------------------------------------------
    # IMPORTANT
    #
    # Do NOT call:
    #
    #   http_probe ...
    #
    # directly under `set -e`.
    #
    # The if statement intentionally absorbs exit code 1
    # while the service is still starting.
    # --------------------------------------------------------

    if http_probe \
      "${url}" \
      "${error_file}"; then

      log "✅ ${description} HTTP service is ready."

      return 0

    fi


    if ! container_running; then

      echo

      echo "❌ Container stopped during HTTP readiness."

      show_container_logs

      return 1

    fi


    current_time="$(date +%s)"

    elapsed=$((current_time - start_time))


    if (( elapsed >= timeout )); then

      echo

      echo "❌ HTTP readiness timeout."

      echo "Description : ${description}"

      echo "URL         : ${url}"

      echo "Attempts    : ${attempt}"

      echo "Elapsed     : ${elapsed}s"


      echo

      echo "Last curl diagnostics:"


      if [[ -s "${error_file}" ]]; then

        cat "${error_file}"

      else

        echo "No curl error."

      fi


      show_container_logs

      return 1

    fi


    log "⏳ HTTP not ready: attempt=${attempt}, elapsed=${elapsed}s/${timeout}s"


    if [[ -s "${error_file}" ]]; then

      tail -n 2 \
        "${error_file}" \
        2>/dev/null \
        || true

    fi


    sleep "${HEALTH_INTERVAL_SECONDS}"

  done

}


# ============================================================
# KasmVNC HTTP
# ============================================================

section "❤️ HTTP readiness — KasmVNC"


wait_for_http \
  "http://${MT5_WEB_BIND}:${MT5_WEB_PORT}/" \
  "${HTTP_TIMEOUT_SECONDS}" \
  "KasmVNC"


# ============================================================
# KasmVNC Header Diagnostics
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


  rm -f "${CLOUDFLARE_LOG}"

  touch "${CLOUDFLARE_LOG}"


  log "Starting Cloudflare..."


  cloudflared tunnel \
    --no-autoupdate \
    --url "http://${MT5_WEB_BIND}:${MT5_WEB_PORT}" \
    > "${CLOUDFLARE_LOG}" \
    2>&1 &


  CLOUDFLARED_PID="$!"


  log "cloudflared PID: ${CLOUDFLARED_PID}"


  local start_time

  local current_time

  local elapsed

  local tunnel_url=""


  start_time="$(date +%s)"


  while true; do


    if ! kill -0 \
      "${CLOUDFLARED_PID}" \
      2>/dev/null; then

      echo

      echo "❌ cloudflared stopped unexpectedly."

      echo

      cat "${CLOUDFLARE_LOG}" \
        2>/dev/null \
        || true

      return 1

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

      printf '%s\n' \
        "${tunnel_url}" \
        > "${TUNNEL_URL_FILE}"


      log "🌐 Cloudflare URL:"

      echo

      echo "${tunnel_url}"

      echo


      break

    fi


    current_time="$(date +%s)"

    elapsed=$((current_time - start_time))


    if (( elapsed >= TUNNEL_TIMEOUT_SECONDS )); then

      echo

      echo "❌ Cloudflare URL detection timeout."

      echo

      echo "Cloudflare log:"

      cat "${CLOUDFLARE_LOG}" \
        2>/dev/null \
        || true

      return 1

    fi


    log "⏳ Waiting for Cloudflare URL: ${elapsed}s/${TUNNEL_TIMEOUT_SECONDS}s"


    sleep 2

  done


  # ----------------------------------------------------------
  # Public health
  # ----------------------------------------------------------

  section "🌍 Public Cloudflare health"


  local public_start

  local public_now

  local public_elapsed

  local public_code

  local public_rc


  public_start="$(date +%s)"


  while true; do


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

    public_rc=$?


    if (( public_rc == 0 )); then

      log "Public HTTP status: ${public_code}"


      if [[ "${public_code}" =~ ^2[0-9][0-9]$ ]]; then

        log "✅ Cloudflare public endpoint is reachable."

        break

      fi


      if [[ "${public_code}" =~ ^3[0-9][0-9]$ ]]; then

        log "✅ Cloudflare public endpoint is reachable."

        break

      fi


      if [[ "${public_code}" == "401" ]]; then

        log "✅ Cloudflare endpoint reached KasmVNC authentication."

        break

      fi


      if [[ "${public_code}" == "403" ]]; then

        log "✅ Cloudflare endpoint reached the server."

        break

      fi

    else

      log "⏳ Public HTTP connection failed. curl=${public_rc}"

    fi


    public_now="$(date +%s)"

    public_elapsed=$((public_now - public_start))


    if (( public_elapsed >= TUNNEL_TIMEOUT_SECONDS )); then

      echo

      echo "⚠️ Cloudflare URL exists but public health check timed out."

      echo "URL: ${tunnel_url}"

      echo

      echo "Continuing because the tunnel process is alive."

      break

    fi


    sleep "${HEALTH_INTERVAL_SECONDS}"

  done

}


if [[ "${ENABLE_TUNNEL,,}" == "true" ]]; then

  start_cloudflare

fi


# ============================================================
# Connection Information
# ============================================================

section "🔗 CONNECTION INFORMATION"


echo

echo "╔════════════════════════════════════════════════════════════╗"

echo "║                  🚀 MT5 CLOUD DESKTOP                      ║"

echo "╠════════════════════════════════════════════════════════════╣"

echo "║                                                            ║"

echo "║ Username : ${MT5_WEB_USER}"

echo "║ Password : ${MT5_WEB_PASSWORD}"

echo "║                                                            ║"


if [[ -s "${TUNNEL_URL_FILE}" ]]; then

  TUNNEL_URL="$(cat "${TUNNEL_URL_FILE}")"

  echo "║ Browser  : ${TUNNEL_URL}"

else

  echo "║ Browser  : http://${MT5_WEB_BIND}:${MT5_WEB_PORT}"

fi


echo "║                                                            ║"

echo "║ RPyC     : ${MT5_API_BIND}:${MT5_API_PORT}"

echo "║                                                            ║"

echo "╚════════════════════════════════════════════════════════════╝"

echo


# ============================================================
# GitHub Step Summary
# ============================================================

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then


  {

    echo "# 🚀 MT5 Cloud Desktop"

    echo

    echo "| Setting | Value |"

    echo "|---|---|"

    echo "| Resolution | \`${RESOLUTION}\` |"

    echo "| Session | \`${SESSION_MINUTES} minutes\` |"

    echo "| Docker Image | \`${MT5_IMAGE}\` |"

    echo "| Container | \`${CONTAINER_NAME}\` |"

    echo "| KasmVNC | \`${MT5_WEB_BIND}:${MT5_WEB_PORT}\` |"

    echo "| mt5linux/RPyC | \`${MT5_API_BIND}:${MT5_API_PORT}\` |"

    echo "| Cloudflare | \`${ENABLE_TUNNEL}\` |"

    echo

    echo "## 🔗 Connection"

    echo


    if [[ -s "${TUNNEL_URL_FILE}" ]]; then

      TUNNEL_URL="$(cat "${TUNNEL_URL_FILE}")"

      echo "**Browser:**"

      echo

      echo "${TUNNEL_URL}"

      echo

      echo "**Username:** \`${MT5_WEB_USER}\`"

      echo

      echo "**Password:** \`${MT5_WEB_PASSWORD}\`"

    else

      echo "Cloudflare Tunnel is disabled."

    fi


    echo

    echo "## ❤️ Health"

    echo

    echo "- Docker container: **READY**"

    echo "- KasmVNC TCP :3000: **READY**"

    echo "- mt5linux/RPyC TCP :8001: **READY**"

    echo "- KasmVNC HTTP: **READY**"

    echo

    echo "## 🔐 Network"

    echo

    echo "Only KasmVNC :3000 is exposed through Cloudflare."

    echo

    echo "mt5linux/RPyC :8001 remains bound to localhost."

  } >> "${GITHUB_STEP_SUMMARY}"

fi


# ============================================================
# Session Timer
# ============================================================

section "⏱️ MT5 SESSION"


SESSION_SECONDS=$((SESSION_MINUTES * 60))


START_TIME_UNIX="$(date +%s)"

END_TIME_UNIX=$((START_TIME_UNIX + SESSION_SECONDS))


log "Session started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

log "Duration       : ${SESSION_MINUTES} minutes"

log "End time       : $(date -u -d "@${END_TIME_UNIX}" '+%Y-%m-%d %H:%M:%S UTC')"


# ============================================================
# Monitor
# ============================================================

while true; do


  NOW_UNIX="$(date +%s)"


  if (( NOW_UNIX >= END_TIME_UNIX )); then

    log "⏰ Session duration reached."

    break

  fi


  # ----------------------------------------------------------
  # Container must remain alive
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


  echo

  echo "------------------------------------------------------------"

  echo "[$(timestamp)] MT5 SESSION"

  echo "------------------------------------------------------------"

  echo "Container : RUNNING"

  echo "Remaining : ${REMAINING_MINUTES}m ${REMAINING_ONLY_SECONDS}s"

  echo "------------------------------------------------------------"


  sleep 30

done


# ============================================================
# Final Diagnostics
# ============================================================

section "📊 Final diagnostics"


echo "Container state:"

docker inspect \
  --format \
  'Running={{.State.Running}} | Status={{.State.Status}} | ExitCode={{.State.ExitCode}} | Started={{.State.StartedAt}}' \
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
  | grep \
    -E ":(${MT5_WEB_PORT}|${MT5_API_PORT})" \
  || true


echo

echo "Container processes:"

docker top \
  "${CONTAINER_NAME}" \
  2>/dev/null \
  || true


# ============================================================
# Save Diagnostics
# ============================================================

if [[ "${SAVE_ARTIFACTS,,}" == "true" ]]; then


  section "📦 Save diagnostics"


  {

    echo "MT5 Cloud Desktop Diagnostics"

    echo "=============================="

    echo

    echo "Timestamp: $(timestamp)"

    echo "GitHub Run ID: ${GITHUB_RUN_ID:-local}"

    echo "Image: ${MT5_IMAGE}"

    echo "Container: ${CONTAINER_NAME}"

    echo "Resolution: ${RESOLUTION}"

    echo "Session: ${SESSION_MINUTES} minutes"

    echo

    echo "Architecture:"

    uname -m

    echo

    echo "Kernel:"

    uname -a

    echo

    echo "Docker:"

    docker --version

    echo

    echo "Memory:"

    free -h

    echo

    echo "Disk:"

    df -h /

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


  log "✅ Diagnostics saved."

fi


# ============================================================
# Success
# ============================================================

section "✅ MT5 SESSION COMPLETED"


echo "MetaTrader 5 session completed normally."

echo

echo "Resolution : ${RESOLUTION}"

echo "Duration   : ${SESSION_MINUTES} minutes"


if [[ -s "${TUNNEL_URL_FILE}" ]]; then

  echo

  echo "🌐 Browser URL:"

  cat "${TUNNEL_URL_FILE}"

fi


echo

echo "Cleanup will now stop the temporary session."

echo

echo "✅ Done."
