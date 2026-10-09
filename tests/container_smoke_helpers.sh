#!/usr/bin/env bash
# Harness-only helpers, shared by actual-image smoke and deterministic fault tests.
# Caller defines ROOT, ARTIFACTS, PREFIX, NAME, CONTAINERS and PASS.

bounded_command() {
  local seconds=$1 kill_after=$2
  shift 2
  python3 "${ROOT}/tests/container_smoke_deadline.py" \
    --timeout "${seconds}" --kill-after "${kill_after}" "$@"
}

dkr_for() {
  local seconds=$1 remaining
  shift
  # Reserve 2s KILL escalation + 0.5s reap (rounded up) inside cleanup's 60s.
  if [[ -n "${CLEANUP_DEADLINE:-}" ]]; then
    remaining=$((CLEANUP_DEADLINE - SECONDS - 3))
    if (( remaining <= 0 )); then
      echo 'cleanup deadline exhausted; no more Docker calls are safe' >&2
      return 124
    fi
    (( seconds <= remaining )) || seconds=${remaining}
  fi
  bounded_command "${seconds}" 2 docker "$@"
}
dkr() { dkr_for 20 "$@"; }
fail() { echo "FAIL: $* (artifacts: ${ARTIFACTS})" >&2; exit 1; }
passed() { PASS=$((PASS + 1)); echo "PASS: $*"; }

# Capture to a same-directory temporary file. Failed refreshes never destroy
# earlier assertion evidence; stderr/partial stdout have separate destinations.
capture_docker() {
  local destination=$1 kind=$2 temporary status
  shift 2
  temporary="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
  if dkr "$@" > "${temporary}" 2>&1; then
    mv -- "${temporary}" "${destination}"
  else
    status=$?
    mv -- "${temporary}" "${destination}.${kind}.error" || return 1
    echo "cleanup/evidence: ${kind} failed (exit ${status}); preserved ${destination}" >&2
    return "${status}"
  fi
}
capture_logs() { capture_docker "$2" logs logs "$1"; }

cleanup_error() {
  printf 'FAIL: cleanup: %s\n' "$*" >&2
  printf 'FAIL: cleanup: %s\n' "$*" >> "${ARTIFACTS}/cleanup.log"
}

# Successful inventory, not failed inspect, is authoritative for absence.
# Keep immutable IDs so a same-name replacement cannot be deleted after lookup.
cleanup_inventory() {
  dkr ps --all --no-trunc \
    --format '{{.ID}}\t{{.Names}}\t{{.Label "io.github.runner-docker.smoke-owner"}}'
}

cleanup_resources() {
  local name id listed owner inventory result=0
  local -A ids=() owners=() remaining_names=()
  CLEANUP_DEADLINE=$((SECONDS + 60))
  if inventory="$(cleanup_inventory 2> "${ARTIFACTS}/cleanup-inventory.error")"; then
    printf '%s\n' "${inventory}" > "${ARTIFACTS}/cleanup-before.tsv"
    while IFS=$'\t' read -r id listed owner; do
      [[ -n "${id}" ]] || continue
      if [[ -z "${listed}" || -n "${ids[${listed}]:-}" ]]; then
        cleanup_error 'malformed/duplicate inventory; refusing all removals'
        return 1
      fi
      ids["${listed}"]=${id}
      owners["${listed}"]=${owner}
    done <<< "${inventory}"
    for name in "${CONTAINERS[@]}"; do
      if [[ "${name}" != "${PREFIX}-"* || "${PREFIX}" != hermes-issue2-smoke-* ]]; then
        cleanup_error "name outside this unique prefix: ${name}; not removed"
        result=1
        continue
      fi
      [[ -n "${ids[${name}]:-}" ]] || continue
      if [[ "${owners[${name}]}" != "${PREFIX}" ]]; then
        cleanup_error "ownership mismatch: ${name}; not removed"
        result=1
        continue
      fi
      id=${ids[${name}]}
      capture_logs "${id}" "${ARTIFACTS}/${name}.log" || result=1
      capture_docker "${ARTIFACTS}/${name}.inspect.json" inspect inspect "${id}" || result=1
      if ! dkr rm --force "${id}" > /dev/null 2> "${ARTIFACTS}/${name}.rm.error"; then
        cleanup_error "removal failed: ${name} (${id})"
        result=1
      fi
    done
  else
    cleanup_error 'authoritative inventory failed; ownership/absence unknown, no removal attempted'
    result=1
  fi
  # Always independently read back, including rm exit-0 no-op and missing names.
  if inventory="$(cleanup_inventory 2> "${ARTIFACTS}/cleanup-readback.error")"; then
    printf '%s\n' "${inventory}" > "${ARTIFACTS}/cleanup-after.tsv"
    while IFS=$'\t' read -r id listed owner; do
      [[ -n "${id}" ]] || continue
      if [[ -z "${listed}" ]]; then
        cleanup_error 'malformed read-back inventory'
        result=1
        continue
      fi
      remaining_names["${listed}"]=1
    done <<< "${inventory}"
    for name in "${CONTAINERS[@]}"; do
      if [[ -n "${remaining_names[${name}]:-}" ]]; then
        cleanup_error "resource remains: ${name}"
        result=1
      fi
    done
  else
    cleanup_error 'authoritative read-back failed; cannot verify absence'
    result=1
  fi
  unset CLEANUP_DEADLINE
  return "${result}"
}

cleanup() {
  local status=$?
  trap - EXIT
  # Repeated INT/TERM must not abort the defined cleanup grace.
  trap '' INT TERM
  if ! cleanup_resources; then
    (( status != 0 )) || status=1
  fi
  echo "Artifacts: ${ARTIFACTS}"
  if (( status == 0 )); then
    echo 'Cleanup verified: all recorded test containers absent'
    if [[ -n "${PASS:-}" ]]; then
      echo "PASS: ${PASS} offline actual-image acceptance tests; FAKE lifecycle is NOT live GitHub integration"
    fi
  fi
  exit "${status}"
}

# NAME is a caller-supplied global, distinct from cleanup's local name.
# shellcheck disable=SC2153
wait_ready() {
  local deadline=$((SECONDS + 15)) since=${1:-} remaining ready logs running
  local -a log_options=()
  [[ -z "${since}" ]] || log_options=(--since "${since}")
  while :; do
    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || fail 'FAKE readiness deadline exceeded'
    ready=false
    if logs="$(dkr_for "${remaining}" logs "${log_options[@]}" "${NAME}" \
        2> "${ARTIFACTS}/${NAME}.ready.error")"; then
      if grep -F 'FAKE_LISTENER_READY' <<< "${logs}" > /dev/null; then ready=true; fi
    fi
    # A late successful poll is still a deadline failure, never a readiness PASS.
    (( SECONDS < deadline )) || fail 'FAKE readiness deadline exceeded'
    [[ "${ready}" != true ]] || break
    remaining=$((deadline - SECONDS))
    running="$(dkr_for "${remaining}" inspect --format '{{.State.Running}}' "${NAME}")" \
      || fail 'could not inspect container during readiness'
    (( SECONDS < deadline )) || fail 'FAKE readiness deadline exceeded'
    [[ "${running}" == true ]] || fail 'exited before FAKE readiness'
    sleep 0.1
  done
  # 子行程 ready、signal handler 已安裝後才送 signal；不用固定 sleep 猜測。
  remaining=$((deadline - SECONDS))
  # shellcheck disable=SC2016 # 在 container 內讀 PID 1，確認真正使用 image init。
  dkr_for "${remaining}" exec "${NAME}" /bin/bash -c 'read -r init < /proc/1/comm; test "$init" = tini'
  (( SECONDS < deadline )) || fail 'FAKE readiness deadline exceeded'
  remaining=$((deadline - SECONDS))
  dkr_for "${remaining}" top "${NAME}" -eo pid,ppid,pgid,stat,args > "${ARTIFACTS}/${NAME}.processes"
  (( SECONDS < deadline )) || fail 'FAKE readiness deadline exceeded'
  for process in /usr/bin/tini run.sh /actions-runner/run-helper.sh /actions-runner/bin/Runner.Listener; do
    grep -F -- "${process}" "${ARTIFACTS}/${NAME}.processes" >/dev/null || fail "missing actual wrapper process: ${process}"
  done
}
