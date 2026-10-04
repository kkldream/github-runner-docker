#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${ROOT}/entrypoint.sh"
PASS=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

new_case() {
  CASE_DIR="$(mktemp -d)"
  cp "${ENTRYPOINT}" "${CASE_DIR}/entrypoint.sh"
  chmod +x "${CASE_DIR}/entrypoint.sh"
}

write_run_stub() {
  cat > "${CASE_DIR}/run.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${RUNNER_MANUALLY_TRAP_SIG:-}" == "1" ]] || exit 71
[[ -z "${RUNNER_TOKEN+x}" ]] || exit 72
[[ -z "${RUNNER_TOKEN_FILE+x}" ]] || exit 73
printf '%s\n' "run" > run.called
STUB
  chmod +x "${CASE_DIR}/run.sh"
}

write_config_stub() {
  cat > "${CASE_DIR}/config.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > config.args
touch .runner
STUB
  chmod +x "${CASE_DIR}/config.sh"
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_contains() {
  grep -F -- "$2" "$1" >/dev/null || fail "expected '$2' in $1"
}

test_fresh_configuration() {
  new_case
  write_config_stub
  write_run_stub

  (
    cd "${CASE_DIR}"
    RUNNER_URL="https://github.com/example-org" \
    RUNNER_TOKEN="test-token" \
    RUNNER_NAME="runner-a" \
    RUNNER_REPLACE="false" \
    ./entrypoint.sh
  )

  assert_file "${CASE_DIR}/.runner"
  assert_file "${CASE_DIR}/run.called"
  assert_contains "${CASE_DIR}/config.args" "--url"
  assert_contains "${CASE_DIR}/config.args" "https://github.com/example-org"
  assert_contains "${CASE_DIR}/config.args" "test-token"
  PASS=$((PASS + 1))
  rm -rf "${CASE_DIR}"
}

test_existing_configuration_is_not_reconfigured() {
  new_case
  touch "${CASE_DIR}/.runner"
  cat > "${CASE_DIR}/config.sh" <<'STUB'
#!/usr/bin/env bash
exit 90
STUB
  chmod +x "${CASE_DIR}/config.sh"
  write_run_stub

  (
    cd "${CASE_DIR}"
    RUNNER_REPLACE="true" ./entrypoint.sh
  )

  assert_file "${CASE_DIR}/run.called"
  PASS=$((PASS + 1))
  rm -rf "${CASE_DIR}"
}

test_token_file() {
  new_case
  write_config_stub
  write_run_stub
  printf '%s\n' "file-token" > "${CASE_DIR}/token"

  (
    cd "${CASE_DIR}"
    RUNNER_URL="https://github.com/example-org" \
    RUNNER_TOKEN_FILE="${CASE_DIR}/token" \
    ./entrypoint.sh
  )

  assert_contains "${CASE_DIR}/config.args" "file-token"
  PASS=$((PASS + 1))
  rm -rf "${CASE_DIR}"
}

test_repo_url_is_rejected() {
  new_case
  write_config_stub
  write_run_stub

  if (
    cd "${CASE_DIR}"
    RUNNER_URL="https://github.com/example-org/example-repo" \
    RUNNER_TOKEN="test-token" \
    ./entrypoint.sh
  ); then
    fail "repository URL should be rejected by the Organization-only contract"
  fi

  PASS=$((PASS + 1))
  rm -rf "${CASE_DIR}"
}

test_ephemeral_reuse_is_rejected() {
  new_case
  touch "${CASE_DIR}/.runner"
  write_config_stub
  write_run_stub

  if (
    cd "${CASE_DIR}"
    RUNNER_EPHEMERAL="true" ./entrypoint.sh
  ); then
    fail "ephemeral mode should reject an existing .runner"
  fi

  PASS=$((PASS + 1))
  rm -rf "${CASE_DIR}"
}

test_invalid_boolean_is_rejected() {
  new_case
  write_config_stub
  write_run_stub

  if (
    cd "${CASE_DIR}"
    RUNNER_REPLACE="yes" ./entrypoint.sh
  ); then
    fail "invalid boolean should be rejected"
  fi

  PASS=$((PASS + 1))
  rm -rf "${CASE_DIR}"
}

test_fresh_configuration
test_existing_configuration_is_not_reconfigured
test_token_file
test_repo_url_is_rejected
test_ephemeral_reuse_is_rejected
test_invalid_boolean_is_rejected

echo "PASS: ${PASS} entrypoint lifecycle tests"
