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

Compose 設定 `stop_grace_period: 2m`。實際 production 所需 grace period 應依最長 job shutdown 行為調整；不要把 SIGKILL 當正常停止流程。

在導入 production 前，仍應在隔離 runner 上實測：

- idle SIGTERM
- busy job SIGTERM
- SIGINT
- job child process 是否殘留
- 實際 exit code

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
