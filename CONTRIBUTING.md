# Contributing

## Pull requests

變更應保持安全預設，且不要把 runtime 未驗證的行為寫成已保證支援。

提交前至少執行：

```bash
# 指向 repository 外、可寫入的 scratch 目錄；不要使用真實 registration token。
export TMPDIR="${HOME}/.cache/github-runner-docker-tests"
mkdir -p "$TMPDIR"
export RUNNER_URL=https://github.com/example-org
export RUNNER_TOKEN_FILE="$TMPDIR/FAKE-token"
printf '%s' 'FAKE-FILE-TOKEN' > "$RUNNER_TOKEN_FILE"

# 舊 unit harness 會繼承環境；保留工具路徑及 scratch，避免外部 RUNNER_* 干擾。
env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" bash tests/entrypoint_test.sh
# 可重用 artifact BASE；每次 suite 建立新的 fault-regressions/run-*，印出實際路徑。
FAULT_ARTIFACT_DIR="$TMPDIR/fault-regressions" python3 tests/container_smoke_fault_test.py
docker compose config >/dev/null
DOCKER_GID=999 docker compose -f docker-compose.yml -f docker-compose.docker.yml config >/dev/null
docker compose -f docker-compose.yml -f docker-compose.ephemeral.yml config >/dev/null
docker build -t hermes-issue2-runner:test .
SMOKE_ARTIFACT_DIR="$TMPDIR/container-smoke" \
  bash tests/container_smoke_test.sh hermes-issue2-runner:test
```

預期為 6 個 Bash lifecycle tests、25 個不接觸 Docker daemon 的 fault regressions、3 組 Compose renders，以及 10 個離線 actual-image acceptance tests。Compose 命令只 render，不啟動服務；`DOCKER_GID=999` 是 render 假值，不是 host 權限驗收。

Container smoke 需要 Linux/amd64 Docker daemon、Bash、Python 3.9+（標準函式庫）與可寫入 scratch 目錄。每個容器固定 `--network none`，不公開 ports、不掛 host Docker socket，並限制為 512 MiB / 1 CPU / 64 PIDs；fixture Perl 使用 image 既有 runtime。harness 本身內建 deadline，不要再用沒有 KILL escalation 的 `timeout 180s` 外包；完整時間界線見 [OPERATIONS](docs/OPERATIONS.md)。

Fault suite 的 PID ownership 防護另需要 Linux pidfd 支援（kernel 5.3+ 與 Python 的 `os.pidfd_open`／`signal.pidfd_send_signal`）。`FAULT_ARTIFACT_DIR` 是可重用的 **base**，不是單次 evidence 目錄；每次程序 invocation 建立唯一 `<base>/run-*/<test-case>/`，不提供時則在 `TMPDIR` 下建立。讀取 stdout 的 `FAULT artifacts: ...` 找本次 evidence，不要讀 base 下舊的 case／PID 檔。PID readiness 在兩個 fixture handlers 都準備後才 atomic publish，含本次 nonce 與 `/proc` start time；送信號前驗證 runtime nonce、command ancestry 與 start time，再使用 pidfd 避免 PID recycling race。Legacy numeric／stale／unverified PID records 都不能觸發 teardown signal。三個新增 semantic regressions 包含同一 base 只跑 selected TERM case 兩次（非兩輪完整 suite）、unrelated canary 無 signal，以及不符 start-time 的 PID identity。

Fault suite 直接載入 actual-image harness 使用的 `container_smoke_helpers.sh`，fake Docker 只模擬 inventory／ownership／logs／removal，不是 image 或 daemon 驗收。涵蓋 query exit 1／124、移除 exit 0 但資源仍在、移除回報錯誤但資源已消失、read-back failure、真正不存在、ownership／prefix 不符、保留既有 logs（含 stderr）、16 秒才回傳 ready、忽略 TERM 的 CLI／child、suite timeout／TERM 與 cleanup；不使用 source-text eval。cleanup 只有成功 inventory 才能判斷不存在，只移除記錄且 prefix／label 都相符的 immutable container ID，再以成功 inventory read-back 確認消失。查詢不確定、證據擷取失敗或資源殘留都會非零退出，原本非零／signal status 不被覆蓋；無 global prune。

交付 review 另補兩個安全回歸：deadline supervisor 用 `waitid(WNOWAIT)` 保留已退出 leader，完成 group signaling 才 reap，避免 PID／PGID reuse；所有忽略 TERM 的 fixture 在 supervisor 仍存活時就取得 pidfds，supervisor 異常死亡／reparent 後仍能安全 teardown。Regression 以真實 leader 的 zombie/pinning 狀態及刻意殺掉已驗證 supervisor 重現，watchdog 仍必須明確報錯；descendants absence 在獨立 guardian fallback 前斷言，不能靠測試清理把失敗變 PASS。

真實 Listener version / UID / missing-token 是未替換 image 的證據；signal / stop-start 使用明確 FAKE Listener，保留 upstream wrappers。不要把這些結果寫成真實 GitHub 註冊或 busy-job 通過；界線及回歸負控制見 [FORMALIZATION](docs/FORMALIZATION.md)、[OPERATIONS](docs/OPERATIONS.md) 與 [fixtures 說明](tests/fixtures/README.md)。

遠端 CI 的 logs 可在 PR Checks 查看；該次 workflow 執行頁面的 `runner-acceptance-<run-id>-<attempt>` artifact 保留 fault suite 的唯一 `run-*` 子目錄及 actual-image logs／inspect／markers，成功或失敗均嘗試上傳，保留 14 天。若較早步驟失敗、尚未產生 evidence，上傳 step 會警告，不代表驗收通過。Artifact 只有明確 FAKE token／離線 fixture 證據，不是 release、SBOM publication 或真實 GitHub job 證明。

若有 ShellCheck：

```bash
shellcheck entrypoint.sh tests/*.sh
```

## Security-sensitive changes

以下變更需要在 PR 說明威脅模型與回退方式：

- Docker socket / privileged access
- registration token 或其他 secrets
- runner registration / replacement / removal lifecycle
- signal handling / shutdown behavior
- image publishing / provenance
- runner group、labels 或 workflow trust boundary

不要在測試、fixture、issue 或 PR 中放入真實 token。

## Support contract

目前只承諾 GitHub Organization、Linux/amd64，以及 README 明列的 persistent / ephemeral 使用方式。新增 repo-level registration、ARM、job container 或 service container 支援時，必須同時加入可重現測試與文件。
