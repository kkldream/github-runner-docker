# Operations

## Persistent runner lifecycle

### First start

1. 建立 fresh registration token。
2. 以 secret file 提供 token。
3. 啟動 fresh container。
4. entrypoint 在沒有 `.runner` 時執行一次 `config.sh`。
5. 設定完成後 token 變數被移除，接著啟動 `run.sh`。

### Restart / stop-start

只要同一 container writable layer 的 `.runner` 還存在，entrypoint 就沿用既有設定，不重新註冊。

`RUNNER_REPLACE=true` 不會改變這個規則；它只會在首次設定時傳給 upstream `config.sh`，用於 GitHub 遠端同名 runner 的明確替換。

### Recreate

Container recreate 會得到新的 writable layer，因此需要 fresh registration token。不要假設舊 registration token 還有效。

如果需要跨 recreate 保留 runner 設定，應先另外設計受控的 state volume 與移除流程；本專案目前不預設持久化 `.runner`。

## Ephemeral runner lifecycle

Ephemeral 模式應使用 fresh container：

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.ephemeral.yml \
  run --rm github-runner-docker
```

每次啟動供應 fresh token。若容器中已有 `.runner`，entrypoint 會 fail closed，不嘗試重用。

GitHub 端自動解除註冊不等於本地 container 自動銷毀；因此必須保留 `--rm` 或由外部 orchestrator 明確清除舊環境。

## Graceful stop

Image 以 `tini` 作為 init，且 `RUNNER_MANUALLY_TRAP_SIG=1` 交給 upstream `run.sh` 執行 TERM / INT forwarding。

目前封裝的 upstream 2.337.0 `run.sh` 使用 job control，對 TERM / INT 執行 `kill -INT -$PID`，也就是向 helper 的 process group 送 **SIGINT**，不是原樣轉送 SIGTERM。`run-helper.sh` 等待 Listener 後才退出；外層 interrupted wait 的實測 exit code 為 TERM **143**、INT **130**。Supervisor 應區分預期停止與非預期 crash，不要只把 exit 0 當正常人工停止。這是目前 wrappers 的離線驗收結果，並非真實 GitHub job 的完整退出合約。

Compose 設定 `stop_grace_period: 2m`。實際 production 所需 grace period 應依最長 job shutdown 行為調整；不要把 SIGKILL 當正常停止流程。

`tests/container_smoke_test.sh` 已在真正 image 上，以明確 FAKE Listener 驗證 idle / 合成 busy child 的 TERM / INT、process-group forwarding、child drain / reap、`docker stop --timeout 10` 在 15 秒 test bound 內完成。它只替換 Listener，不替換 init、entrypoint 或 upstream wrappers；fixture `.runner` 明確不是 GitHub 註冊。此 10 秒 timeout 只是合成 drain 的測試設定，不取代 Compose 的 2 分鐘或 production SLA。

在導入 production 前，仍應在獨立批准的隔離真實 runner 上實測：

- idle SIGTERM
- busy job SIGTERM
- SIGINT
- job child process 是否殘留
- 實際 exit code

重現安全的本地 smoke（先依 CONTRIBUTING 建置 image）：

```bash
export TMPDIR="${HOME}/.cache/github-runner-docker-tests"
mkdir -p "$TMPDIR"
SMOKE_ARTIFACT_DIR="$TMPDIR/container-smoke" \
  bash tests/container_smoke_test.sh hermes-issue2-runner:test
```

Suite 使用 `--network none`、不公開 ports、不掛 host socket、不註冊／移除 runner。每個容器有 512 MiB / 1 CPU / 64 PIDs 上限。harness-only Python supervisor 以獨立 process group、TERM → KILL escalation 及 Linux subreaper 控制 CLI descendants；不改 production runner signal policy。

| 邊界 | 時間與失敗處理 |
| --- | --- |
| Readiness | 15 秒內取得新 ready marker 並完成 init／wrapper checks；每次 CLI 前限制剩餘時間，成功 poll 後也檢查 deadline，晚到 marker 不可通過 |
| Exit wait／Docker stop | CLI 的 TERM deadline 15 秒，2 秒後 KILL；合成 graceful signal case 仍要求整段停止 `<15s` |
| 一般 Docker CLI | 20 秒 TERM deadline，2 秒後 KILL；另有最多 0.5 秒 bounded descendant reap（約 22.5 秒上限，另受 OS 排程影響） |
| 整套 smoke | 180 秒 TERM deadline，保留 90 秒 cleanup escalation grace，之後 KILL；最多另加 0.5 秒 reap，CI step 限 5 分鐘 |
| Cleanup | 共用 60 秒 budget；每個 CLI 都縮至剩餘時間並保留 KILL／reap 空間，耗盡就停止新查詢／刪除並非零退出 |

Suite 的 90 秒 grace 足以涵蓋 signal 到達時尚未完成的 CLI（最多約 22.5 秒）及 60 秒 cleanup；不能再用更短的外層 timeout 先殺掉 cleanup。ready／exit deadline 到期後，終止 CLI 最多另需 2 秒 KILL + 0.5 秒 reap，這不是接受晚到 readiness 的延長窗口。deadline supervisor 的非零 timeout status 為 124；shell INT／TERM status 保持 130／143。

正常／失敗／TERM 時，cleanup 先成功取得 authoritative inventory，只有這次記錄且 unique prefix + ownership label 都相符的 immutable container ID 才能移除，避免同名 replacement race；成功 read-back 才能確認 absent。query 失敗／timeout 不等於不存在，ownership 不符不刪除，`rm` exit 0 但資源仍在也非零退出。若 daemon 不可用或 budget 耗盡，harness 明確失敗並保留診斷；**不保證這種情況能刪除殘留容器**，不得用 global prune 補救。最終 suite PASS 只在 cleanup read-back 通過後輸出。

logs／inspect 先寫同目錄 temporary file，只有 CLI 成功才 atomic replace；failed refresh 不覆蓋先前有效 assertion evidence，失敗輸出留在獨立 `*.logs.error`／`*.inspect.error`。成功 Docker logs 的 stdout 與 stderr 都保留。inventory、process tree、synthetic markers 與 diagnostics 留在指定 evidence 目錄。

ShellCheck 與 10 個 smoke 通過也不能略過真實 GitHub idle / busy job、host socket permission matrix、production rollout / rollback 或 release scan / provenance gates。

### Fault-suite artifact base 與 PID ownership

```bash
FAULT_ARTIFACT_DIR="$TMPDIR/fault-regressions" \
  python3 tests/container_smoke_fault_test.py
# 可再次執行同一命令；每次 evidence 在新的 fault-regressions/run-*/<case>/。
```

`FAULT_ARTIFACT_DIR` 是 base；stdout 的 `FAULT artifacts: ...` 才是當次 run 目錄。25 個 fault regressions 不接觸 daemon，包含 selected supervisor-TERM case 在同一 base 的兩次 fresh subprocess invocation；不把整套 suite 跑兩次。舊 case／PID 檔不重用，也不可用它們送 signal。Current readiness 只接受本次 nonce、已安裝 handlers 的 CLI／child、runtime environment／ancestry 與 `/proc` start-time proof。Teardown 使用已驗證 pidfd，不會用 PID 檔內的裸數字 `kill`，也不做 broad `pkill`；Linux pidfd 與 Python 3.9+ 是此 fault suite 的必要條件。Stale nonce、legacy numeric records、非本次 command 的 canary 與 start-time mismatch 都由真實 subprocess 回歸驗證無 signal；canary 明確 ready，檢查時還會做 pipe liveness round-trip。

Deadline supervisor 以 `waitid(WNOWAIT)` 查看退出狀態，送完 group signal 才 reap leader，讓 PID／PGID 在 signaling 期間保持 pinned。所有忽略 TERM 的 fault fixtures 都先取得 ownership-verified pidfds，再等待結果；即使 nested supervisor 異常死亡、CLI 被 reparent，watchdog／teardown 仍只向原 fixture identities 送 signal。故障測試會預期 watchdog 明確 FAIL，並在 test-only guardian fallback 前驗證 CLI／child（含 zombie）不存在；guardian 不構成 harness 成功證據。

## Docker socket opt-in

只有使用 `docker-compose.docker.yml` 時才會掛載 socket。

Host：

```bash
export DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
```

Container 啟動時會執行 `docker info`。若 socket 不存在、supplemental GID 錯誤或 daemon 不可達，會在 runner 接 job 前失敗。

此模式不等於 GitHub job container 支援；只承諾 workflow step 可在通過 preflight 後主動使用 host Docker API。

## Workspace and diagnostics

Persistent container 的 writable layer 可能保留 `_work` 與 `_diag`。同一 runner 接收互不信任的工作時，這是資料殘留風險。

目前預設：

- 不把 `_work` 掛成 persistent volume
- container recreate 後 workspace 消失
- Docker logs 使用 10 MB × 3 rotation
- 不自動刪除 active container 的 workspace

需要跨工作嚴格隔離時，使用 ephemeral fresh container，而不是在 persistent runner 上依賴 best-effort cleanup。

## Release evidence

正式 release 至少應記錄：

- source commit SHA
- GitHub Actions runner version
- runner archive SHA-256
- Ubuntu base image digest
- built image digest
- build / test result
- SBOM 位置
- vulnerability scan result
- registry tag → immutable digest 對應
- rollback image digest

本 repository 目前不自動修改 production、registry 或 GitHub branch protection；這些操作需要獨立核准。
