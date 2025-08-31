# GitHub Actions Self-Hosted Runner (Docker)

以 Docker 方式部署 GitHub Actions 自託管 Runner。映像在建置時以 root 安裝依賴，執行時使用非 root 使用者 `runner`（uid/gid 1001）。

> Docker Hub：[kkldream/github-runner-docker](https://hub.docker.com/repository/docker/kkldream/github-runner-docker)

## 功能特性
- 非 root 執行，預設使用者 `runner`
- 入口腳本以 exec 形式啟動，正確處理 OS 訊號
- 以環境變數設定 Runner 名稱、群組、標籤、是否覆蓋及是否一次性
- 可選掛載 Docker socket，支援在 Runner 內部執行 Docker（Docker-out-of-Docker）
- 目前僅針對 Github Organization 使用，未支援 Github Repository

## 快速開始（使用既有映像）

```
docker run --rm -it --name github-runner-docker \
  -e RUNNER_URL=https://github.com/<YOUR_ORG> \
  -e RUNNER_TOKEN=<YOUR_TOKEN> \
  -e RUNNER_GROUP=Default \
  -e RUNNER_NAME=github-runner-docker \
  -e RUNNER_LABELS=docker \
  -e RUNNER_WORKDIR=_work \
  -e RUNNER_REPLACE=true \
  -e RUNNER_EPHEMERAL=false \
  -v /var/run/docker.sock:/var/run/docker.sock \
  kkldream/github-runner-docker:org-1.0
```

> 建議用 `docker compose` 管理，見下方範例。

## Docker Compose

`docker-compose.yml` 範例已提供在專案下，使用方法如下：

```
# 啟動
docker compose up -d

# 查看日志
docker compose logs -f

# 停止
docker compose down
```

## 環境變數說明
- `RUNNER_URL`：GitHub 組織或儲存庫 URL（必填），例如 `https://github.com/kkserver-projects`
- `RUNNER_TOKEN`：註冊 Runner 的 Token（必填）。請以 Secrets 或 `.env` 管理，勿提交到版本庫
- `RUNNER_GROUP`：Runner 所屬群組，預設 `Default`
- `RUNNER_NAME`：Runner 名稱，預設 `github-runner-docker`
- `RUNNER_LABELS`：逗號分隔的 labels，預設 `docker` 且固定包含 `self-hosted,Linux,X64`
- `RUNNER_WORKDIR`：工作目錄，預設 `_work`
- `RUNNER_REPLACE`：若同名 Runner 已存在是否覆蓋，預設 `true`
- `RUNNER_EPHEMERAL`：是否一次性 Runner（只跑一個 Job 後自動解除註冊），預設 `false`

## 注意事項
- 預設不持久化 `_work`。若你需要持久化，請確保掛載路徑擁有者為 `1001:1001`：
  - 方式一：在正在運行的容器中修正 `chown -R 1001:1001 /actions-runner/_work`
  - 方式二：離線用臨時容器調整 named volume 擁有者
- 不要將含 `RUNNER_TOKEN` 的 `.env` 或 compose 檔提交至公開版本庫
- 需要在 runner 內執行 Docker 時，請掛載 `/var/run/docker.sock`（安全性風險自行評估）

## 建置映像

```
# 建置
docker build -t github-runner-docker .
```
