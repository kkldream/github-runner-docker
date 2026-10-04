# GitHub Actions Self-Hosted Runner (Docker)

以 Docker 執行 GitHub Actions self-hosted runner。此專案目前以「安全預設、可驗證生命週期」為目標，預設不掛載宿主 Docker socket。

> Docker Hub：<https://hub.docker.com/repository/docker/kkldream/github-runner-docker>

## 支援範圍

| 項目 | 目前契約 |
| --- | --- |
| Runner scope | GitHub Organization only |
| OS / arch | Linux / amd64 |
| Runner version | 2.337.0 |
| Persistent runner | 支援 |
| Ephemeral runner | 支援 fresh container 流程 |
| 宿主 Docker daemon | 可選、明確 opt-in |
| GitHub job container / service container | 不宣告支援 |
| Docker container action | 不宣告支援 |

Docker-out-of-Docker 模式下，GitHub runner 內的路徑與宿主 Docker daemon 的 bind-mount 路徑語意不同，因此本專案目前只把 socket 模式定位為「workflow step 主動執行 docker CLI」；不把它宣告為 GitHub `container:`、service container 或 Docker container action 的完整支援方案。

## 安全預設

- Runtime 使用非 root `runner`（uid/gid 1001）。
- 預設不掛載 `/var/run/docker.sock`。
- 註冊 token 可由 secret file 提供，設定完成後不再傳給 `run.sh`。
- 已存在 `.runner` 時不重新執行 `config.sh`。
- `RUNNER_REPLACE` 只影響「首次設定」時是否取代 GitHub 上的同名 runner，不代表重設本機已配置目錄。
- 使用 `tini`，並啟用 upstream `RUNNER_MANUALLY_TRAP_SIG=1`，讓停止訊號可由 runner wrapper 轉送。
- Runner 壓縮檔使用固定版本與官方 SHA-256 驗證。
- Compose 預設設定 2 分鐘停止寬限與 Docker log rotation。

## Persistent runner 快速開始

建立 token secret：

```bash
mkdir -p secrets
printf '%s' '<FRESH_REGISTRATION_TOKEN>' > secrets/runner_token
chmod 600 secrets/runner_token
```

設定 organization URL 後啟動：

```bash
export RUNNER_URL=https://github.com/<YOUR_ORG>
docker compose up -d --build
docker compose logs -f
```

Runner 第一次設定後，容器 writable layer 中會存在 `.runner`。之後 `restart` 或 `stop/start` 會沿用該設定，不會因 `RUNNER_REPLACE=true` 再跑一次 `config.sh`。

> `RUNNER_REPLACE=true` 是危險的明確 opt-in，只適用於首次設定、且你確定 GitHub 上同名 runner 應被取代時。

## Ephemeral runner

Ephemeral runner 不應重用舊的 `.runner`。每次工作應以新容器及 fresh registration token 啟動：

```bash
export RUNNER_URL=https://github.com/<YOUR_ORG>
docker compose \
  -f docker-compose.yml \
  -f docker-compose.ephemeral.yml \
  run --rm github-runner-docker
```

若 ephemeral 模式發現既有 `.runner`，entrypoint 會直接拒絕啟動，避免把已使用或已解除註冊的 runner 狀態重新拿來跑。

## 可選：存取宿主 Docker daemon

掛載 Docker socket 等同把高權限的 Docker API 暴露給 runner 工作負載。只應在專用、受信任的 runner host 使用，不應讓不可信 PR 或第三方 workflow 取得該 runner。

Linux host 先取得 socket GID：

```bash
export DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
export RUNNER_URL=https://github.com/<YOUR_ORG>
```

再明確加入 Docker override：

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.docker.yml \
  up -d --build
```

此 override 會：

- 掛載 `/var/run/docker.sock`
- 將宿主 socket GID 加入 runner 的 supplemental group
- 啟用 `RUNNER_DOCKER_ENABLED=true`
- 啟動前執行 `docker info` preflight；權限不符時 fail fast

不要用 `chmod 666 /var/run/docker.sock` 或長期以 root 執行 runner 來繞過權限問題。

## 環境變數

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `RUNNER_URL` | 空 | GitHub Organization URL；首次設定必填 |
| `RUNNER_TOKEN_FILE` | 空 | token 檔案；優先於 `RUNNER_TOKEN` |
| `RUNNER_TOKEN` | 空 | 相容用環境變數；不建議長期使用 |
| `RUNNER_GROUP` | `Default` | Organization runner group |
| `RUNNER_NAME` | `github-runner-docker` | Runner 名稱 |
| `RUNNER_LABELS` | `docker` | 自訂 labels |
| `RUNNER_WORKDIR` | `_work` | 工作目錄 |
| `RUNNER_REPLACE` | `false` | 首次註冊時是否取代 GitHub 上同名 runner |
| `RUNNER_EPHEMERAL` | `false` | 設定為 ephemeral runner |
| `RUNNER_DOCKER_ENABLED` | `false` | 是否要求 Docker socket preflight |

`RUNNER_TOKEN_FILE` 有值時會讀取檔案內容；設定完成後 entrypoint 會 `unset RUNNER_TOKEN`、`RUNNER_TOKEN_FILE` 與內部 token 變數，再啟動 runner。

## 建置

```bash
docker build -t github-runner-docker:local .
```

目前 Dockerfile 固定：

- GitHub Actions Runner：`2.337.0`
- Linux x64 SHA-256：`70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613`
- Ubuntu：`22.04`

下載使用 `curl --fail`、有限 retry，並在解壓前驗證官方 checksum。

## 驗證

```bash
bash tests/entrypoint_test.sh
docker compose config
DOCKER_GID=999 docker compose -f docker-compose.yml -f docker-compose.docker.yml config
docker build -t github-runner-docker:test .
```

CI 會執行 ShellCheck、entrypoint lifecycle tests、Compose config 與 Docker build。

## 維運

Persistent / ephemeral 生命週期、停止、診斷與 release evidence 請看 [docs/OPERATIONS.md](docs/OPERATIONS.md)。

Issue #2 各 finding 的本次處理狀態請看 [docs/FORMALIZATION.md](docs/FORMALIZATION.md)。

## Security

請先閱讀 [SECURITY.md](SECURITY.md)。尤其是 Docker socket：即使容器內 runner 是非 root，能操作宿主 Docker daemon 通常仍等同具備宿主高權限控制能力。

## License

此 repository 目前尚未由維護者選定軟體授權條款。公開可讀不等同授予自由使用、修改或再散布權利；在正式 LICENSE 決策前，不應假設本專案是已授權的 open-source software。
