# Security Policy

## Supported versions

安全修正以目前 `main` 與最新正式 release 為優先。舊 image tag 若未另行公告，不保證持續獲得安全更新。

## Threat model

Self-hosted runner 會執行 workflow 內容，因此 workflow 的信任來源就是主要安全邊界。

特別注意：

- 不可信 PR 不應被導向持有部署憑證或高權限 host control 的 runner。
- 掛載 `/var/run/docker.sock` 會讓 runner 工作負載取得高權限 Docker API；容器內使用非 root 使用者並不能消除此風險。
- Registration token 是短期敏感資訊，不應寫入 Git、image layer、log 或公開 issue。
- Persistent runner 會在同一 container writable layer 保留工作狀態；若工作彼此不互信，應優先採 fresh ephemeral container。

## Reporting a vulnerability

請不要在 public issue 張貼 token、憑證、可直接利用的 exploit 細節或內網資訊。

若 GitHub repository 頁面提供 private vulnerability reporting，請優先使用該管道。若沒有可用的私密管道，可先建立不含敏感細節的 public issue，要求維護者提供私密聯絡方式，再交換完整內容。

## Secret handling

建議使用 `RUNNER_TOKEN_FILE`，例如 Docker Compose secret。entrypoint 在完成設定後會移除 token 相關環境變數，再啟動 runner listener。

Repository 已忽略常見 `.env`、`secrets/`、`_work/` 與 `_diag/` 路徑；這不是 secret scanning 的替代品。

## Docker socket mode

Docker socket mode 必須明確 opt-in，並以宿主 socket GID 加入 supplemental group。不要使用 `chmod 666` 放寬 socket，也不要把 socket mode 視為 sandbox。

本專案目前不宣告 Docker-out-of-Docker 下的 GitHub job containers、service containers 或 Docker container actions 為支援功能。

## Supply chain

Runner archive 固定版本並驗證 GitHub release 提供的 SHA-256。正式 release 應另外保存 source commit、base image digest、built image digest、SBOM / vulnerability scan 結果與 rollback digest。
