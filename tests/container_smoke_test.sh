#!/usr/bin/env bash
# 實際 image 的離線驗收；FAKE Listener 不代表 GitHub 註冊或真實 job 驗收。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Suite TERM at 180s; 90s escalation grace covers an in-flight CLI (<=22.5s)
# plus bounded cleanup (<=60s). Nested supervisors own/kill their CLI groups.
if [[ "${1:-}" != --deadline-child ]]; then
  exec python3 "${ROOT}/tests/container_smoke_deadline.py" --timeout 180 --kill-after 90 \
    bash "${ROOT}/tests/container_smoke_test.sh" --deadline-child "$@"
fi
shift
IMAGE="${1:-github-runner-docker:test}"
ARTIFACTS="${SMOKE_ARTIFACT_DIR:-$(mktemp -d "${TMPDIR:?Set TMPDIR to a writable scratch directory}/hermes-issue2-smoke.XXXXXX")}"
mkdir -p "${ARTIFACTS}"
ARTIFACTS="$(cd "${ARTIFACTS}" && pwd)"
PREFIX="hermes-issue2-smoke-$$-${RANDOM}"
CONTAINERS=()
PASS=0
NAME=''

# 每次 Docker CLI 與 readiness / exit wait 都有 deadline；不全域 prune、不掛 socket。
# shellcheck source=tests/container_smoke_helpers.sh
source "${ROOT}/tests/container_smoke_helpers.sh"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

create_case() {
  local label=$1
  shift
  local -a options=() command=()
  while (( $# )); do
    if [[ "$1" == -- ]]; then shift; command=("$@"); break; fi
    options+=("$1")
    shift
  done
  NAME="${PREFIX}-${label}"
  CONTAINERS+=("${NAME}")
  dkr create --name "${NAME}" --network none --memory 512m --cpus 1 --pids-limit 64 \
    --label "io.github.runner-docker.smoke-owner=${PREFIX}" "${options[@]}" "${IMAGE}" "${command[@]}" > /dev/null
}
install_fake() {
  dkr cp "${ROOT}/tests/fixtures/FakeListener.pl" "${NAME}:/actions-runner/bin/Runner.Listener"
}
start_case() { dkr start "${NAME}" > /dev/null; }
wait_exit() {
  dkr_for 15 wait "${NAME}" > "${ARTIFACTS}/${NAME}.exit" || fail "bounded exit wait expired: ${NAME}"
  [[ "$(dkr inspect --format '{{.State.Running}}' "${NAME}")" == false ]] || fail "container still running"
  [[ "$(dkr inspect --format '{{.State.OOMKilled}}' "${NAME}")" == false ]] || fail "container OOM killed"
  capture_logs "${NAME}" "${ARTIFACTS}/${NAME}.log"
}
assert_exit() {
  local expected=$1 actual
  actual="$(dkr inspect --format '{{.State.ExitCode}}' "${NAME}")"
  [[ "${actual}" == "${expected}" ]] || fail "${NAME}: expected exit ${expected}, got ${actual}"
}
assert_log() {
  grep -F -- "$1" "${ARTIFACTS}/${NAME}.log" >/dev/null || fail "${NAME}: missing log marker '$1'"
}
assert_no_log() {
  if grep -F -- "$1" "${ARTIFACTS}/${NAME}.log" >/dev/null; then
    fail "${NAME}: unexpected log marker '$1'"
  fi
}
copy_marker() { dkr cp "${NAME}:/actions-runner/fake-$1" "${ARTIFACTS}/${NAME}.fake-$1"; }

# 不替換 Listener：驗證真正的 upstream binary、runtime dependencies 與預設 USER。
# shellcheck disable=SC2016 # 此 probe 必須在 container 內展開 id。
create_case identity --entrypoint /bin/bash -- -c 'set -e; id; test "$(id -u)" = 1001; test ! -f .runner; ./bin/Runner.Listener --version'
start_case
wait_exit
assert_exit 0
assert_log 'uid=1001(runner)'
EXPECTED_VERSION=''
while IFS= read -r line; do
  if [[ "${line}" == ARG\ RUNNER_VERSION=* ]]; then EXPECTED_VERSION="${line#ARG RUNNER_VERSION=}"; fi
done < "${ROOT}/Dockerfile"
[[ -n "${EXPECTED_VERSION}" ]] || fail 'Dockerfile RUNNER_VERSION not found'
grep -Fx -- "${EXPECTED_VERSION}" "${ARTIFACTS}/${NAME}.log" >/dev/null || fail "actual Listener version mismatch"
dkr cp "${NAME}:/actions-runner/run.sh" "${ARTIFACTS}/upstream-run.sh"
dkr cp "${NAME}:/actions-runner/run-helper.sh.template" "${ARTIFACTS}/upstream-run-helper.sh.template"
passed "actual Listener ${EXPECTED_VERSION}, non-root UID 1001"

create_case missing-token --env RUNNER_URL=https://github.com/example-org
start_case
wait_exit
assert_exit 2
assert_log 'RUNNER_TOKEN or RUNNER_TOKEN_FILE is required'
# 不使用 FAKE；first-time registration 在呼叫真正 config.sh 前 fail closed。
passed 'actual image missing-token fail closed (exit 2)'

signal_case() {
  local mode=$1 signal=$2 expected=$3 stop_command=${4:-kill}
  create_case "${mode}-${signal}" --env RUNNER_URL=https://github.com/example-org \
    --env RUNNER_TOKEN=FAKE-ENV-TOKEN --env "FAKE_LISTENER_MODE=${mode}"
  install_fake
  start_case
  wait_ready
  local started=$SECONDS
  if [[ "${stop_command}" == stop ]]; then
    # 真正 Docker stop (image STOPSIGNAL SIGTERM)，而非 fixture 直接收 signal。
    dkr_for 15 stop --timeout 10 "${NAME}" > /dev/null || fail 'bounded Docker stop failed'
  else
    dkr kill --signal "${signal}" "${NAME}" > /dev/null
  fi
  wait_exit
  (( SECONDS - started < 15 )) || fail 'graceful shutdown exceeded 15s test bound'
  assert_exit "${expected}"
  # upstream run.sh 把 TERM / INT 都轉為 helper process-group 的 INT。
  assert_log 'FAKE_LISTENER_SIGNAL=INT'
  assert_no_log 'FAKE_LISTENER_SIGNAL=TERM'
  assert_log 'FAKE_LISTENER_STOPPED'
  copy_marker env-clean
  copy_marker stopped
  if [[ "${mode}" == busy ]]; then
    assert_log 'FAKE_CHILD_SIGNAL=INT'
    assert_log 'FAKE_CHILD_DRAINED'
    assert_log 'FAKE_CHILD_REAPED'
    copy_marker child-drained
    copy_marker child-reaped
  fi
  passed "FAKE ${mode} ${signal}: forwarded INT, graceful exit ${expected}, bound <15s (not live job proof)"
}
signal_case idle TERM 143
signal_case busy TERM 143 stop
signal_case idle INT 130
signal_case busy INT 130

create_case token-file --env RUNNER_URL=https://github.com/example-org \
  --env RUNNER_TOKEN=FAKE-ENV-TOKEN --env RUNNER_TOKEN_FILE=/actions-runner/fake-token \
  --env FAKE_EXPECT_TOKEN=FAKE-FILE-TOKEN
install_fake
printf 'FAKE-FILE-TOKEN\r\n' > "${ARTIFACTS}/fake-token"
dkr cp "${ARTIFACTS}/fake-token" "${NAME}:/actions-runner/fake-token"
start_case
wait_ready
dkr kill --signal TERM "${NAME}" > /dev/null
wait_exit
assert_exit 143
assert_log 'FAKE_LISTENER_STOPPED'
copy_marker env-clean
passed 'FAKE token-file configuration; token / token-file / registration-token absent from Listener environment'

create_case reuse --env RUNNER_URL=https://github.com/example-org \
  --env RUNNER_TOKEN=FAKE-ENV-TOKEN --env RUNNER_REPLACE=true
install_fake
start_case
wait_ready
dkr kill --signal TERM "${NAME}" > /dev/null
wait_exit
assert_exit 143
dkr cp "${NAME}:/actions-runner/.runner" "${ARTIFACTS}/reuse-before.runner"
capture_logs "${NAME}" "${ARTIFACTS}/reuse-first.log"
# Docker restart 保留 writable layer 與同一環境；即使 REPLACE=true 也不能再 configure。
start_case
# Docker logs 包含上一輪；只接受此次 StartedAt 後的新 ready，避免舊 marker race。
started_at="$(dkr inspect --format '{{.State.StartedAt}}' "${NAME}")"
wait_ready "${started_at}"
dkr kill --signal TERM "${NAME}" > /dev/null
wait_exit
assert_exit 143
assert_log 'Existing runner configuration detected; keeping it unchanged'
[[ "$(grep -Fc 'FAKE_CONFIGURE_COMPLETE' "${ARTIFACTS}/${NAME}.log")" == 1 ]] || fail 'reuse repeated FAKE configure'
dkr cp "${NAME}:/actions-runner/.runner" "${ARTIFACTS}/reuse-after.runner"
cmp "${ARTIFACTS}/reuse-before.runner" "${ARTIFACTS}/reuse-after.runner" || fail 'reuse changed FAKE .runner'
passed 'FAKE stop-start reuse keeps synthetic .runner unchanged; configure called once (not registration proof)'

create_case ephemeral-reuse --env RUNNER_URL=https://github.com/example-org \
  --env RUNNER_TOKEN=FAKE-ENV-TOKEN --env RUNNER_EPHEMERAL=true
install_fake
start_case
wait_ready
dkr kill --signal TERM "${NAME}" > /dev/null
wait_exit
assert_exit 143
start_case
wait_exit
assert_exit 2
assert_log 'Refusing to reuse an existing .runner directory in ephemeral mode'
[[ "$(grep -Fc 'FAKE_CONFIGURE_COMPLETE' "${ARTIFACTS}/${NAME}.log")" == 1 ]] || fail 'ephemeral reuse repeated FAKE configure'
passed 'FAKE ephemeral stop-start fails closed (exit 2)'

create_case missing-socket --env RUNNER_URL=https://github.com/example-org \
  --env RUNNER_TOKEN=FAKE-ENV-TOKEN --env RUNNER_DOCKER_ENABLED=true
install_fake
start_case
wait_exit
assert_exit 2
assert_log 'RUNNER_DOCKER_ENABLED=true but /var/run/docker.sock is not mounted'
assert_no_log 'FAKE_LISTENER_READY'
passed 'actual image socket opt-in without socket fails before Listener (exit 2; not host GID matrix)'

# Final suite PASS is emitted by EXIT cleanup only after authoritative read-back.
