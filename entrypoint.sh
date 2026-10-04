#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[entrypoint] $*"
}

fail() {
  echo "[entrypoint] ERROR: $*" >&2
  exit 2
}

require_bool() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *) fail "${name} must be 'true' or 'false' (got: ${value})" ;;
  esac
}

: "${RUNNER_URL:=}"
: "${RUNNER_TOKEN:=}"
: "${RUNNER_TOKEN_FILE:=}"
: "${RUNNER_NAME:=github-runner-docker}"
: "${RUNNER_GROUP:=Default}"
: "${RUNNER_LABELS:=docker}"
: "${RUNNER_WORKDIR:=_work}"
: "${RUNNER_REPLACE:=false}"
: "${RUNNER_EPHEMERAL:=false}"
: "${RUNNER_DOCKER_ENABLED:=false}"
: "${RUNNER_MANUALLY_TRAP_SIG:=1}"

require_bool RUNNER_REPLACE "${RUNNER_REPLACE}"
require_bool RUNNER_EPHEMERAL "${RUNNER_EPHEMERAL}"
require_bool RUNNER_DOCKER_ENABLED "${RUNNER_DOCKER_ENABLED}"

validate_org_url() {
  if [[ ! "${RUNNER_URL}" =~ ^https://github\.com/[^/]+/?$ ]]; then
    fail "RUNNER_URL must be a GitHub organization URL such as https://github.com/example-org"
  fi
}

load_registration_token() {
  local token="${RUNNER_TOKEN}"

  if [[ -n "${RUNNER_TOKEN_FILE}" ]]; then
    [[ -r "${RUNNER_TOKEN_FILE}" ]] || fail "RUNNER_TOKEN_FILE is not readable: ${RUNNER_TOKEN_FILE}"
    token="$(tr -d '\r\n' < "${RUNNER_TOKEN_FILE}")"
  fi

  [[ -n "${token}" ]] || fail "RUNNER_TOKEN or RUNNER_TOKEN_FILE is required for first-time configuration"
  RUNNER_REGISTRATION_TOKEN="${token}"
}

config_runner() {
  local -a args=(
    --unattended
    --url "${RUNNER_URL}"
    --token "${RUNNER_REGISTRATION_TOKEN}"
    --name "${RUNNER_NAME}"
    --labels "${RUNNER_LABELS}"
    --runnergroup "${RUNNER_GROUP}"
    --work "${RUNNER_WORKDIR}"
  )

  if [[ "${RUNNER_REPLACE}" == "true" ]]; then
    args+=(--replace)
  fi

  if [[ "${RUNNER_EPHEMERAL}" == "true" ]]; then
    args+=(--ephemeral)
  fi

  ./config.sh "${args[@]}"
}

preflight_docker_socket() {
  [[ -S /var/run/docker.sock ]] || fail "RUNNER_DOCKER_ENABLED=true but /var/run/docker.sock is not mounted"

  if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
    fail "Docker daemon is not reachable. Check the socket mount and supplemental DOCKER_GID."
  fi
}

if [[ -f .runner ]]; then
  if [[ "${RUNNER_EPHEMERAL}" == "true" ]]; then
    fail "Refusing to reuse an existing .runner directory in ephemeral mode; start a fresh container instead"
  fi
  log "Existing runner configuration detected; keeping it unchanged"
else
  [[ -n "${RUNNER_URL}" ]] || fail "RUNNER_URL is required for first-time configuration"
  validate_org_url
  load_registration_token
  log "No existing configuration detected; configuring runner"
  config_runner
fi

unset RUNNER_TOKEN RUNNER_TOKEN_FILE RUNNER_REGISTRATION_TOKEN || true

if [[ "${RUNNER_DOCKER_ENABLED}" == "true" ]]; then
  preflight_docker_socket
  log "Docker socket preflight succeeded"
fi

export RUNNER_MANUALLY_TRAP_SIG
exec ./run.sh
