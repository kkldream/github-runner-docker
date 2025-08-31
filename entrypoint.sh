#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[entrypoint] $*"
}

# Defaults are provided via Dockerfile ENV, but validate required ones here
: "${RUNNER_URL:=}"
: "${RUNNER_TOKEN:=}"
: "${RUNNER_NAME:=github-runner-docker}"
: "${RUNNER_GROUP:=Default}"
: "${RUNNER_LABELS:=docker}"
: "${RUNNER_WORKDIR:=_work}"
: "${RUNNER_REPLACE:=true}"
: "${RUNNER_EPHEMERAL:=false}"

if [[ -z "${RUNNER_URL}" || -z "${RUNNER_TOKEN}" ]]; then
  echo "RUNNER_URL and RUNNER_TOKEN are required" >&2
  exit 2
fi

config_runner() {
  local -a args=(
    --unattended
    --url "${RUNNER_URL}"
    --token "${RUNNER_TOKEN}"
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

# Configure if needed, or replace if requested
if [[ -f .runner ]]; then
  if [[ "${RUNNER_REPLACE}" == "true" ]]; then
    log "Existing configuration detected; reconfiguring (replace=true)"
    config_runner
  else
    log "Existing configuration detected; skipping reconfiguration (replace=false)"
  fi
else
  log "No existing configuration; configuring runner"
  config_runner
fi

# Start the runner as PID 1 to receive signals properly
exec ./run.sh


