# Issue #2 Formalization Status

此文件記錄 repository 內能直接落地的修正，以及仍需要 runtime / policy 決策的項目。它不把未驗證 runtime 行為標示成已完成。

| Finding | 本次狀態 | 處理 |
| --- | --- | --- |
| F01 | Implemented | 已存在 `.runner` 時永不重跑 `config.sh`；`RUNNER_REPLACE` 改為首次設定的 opt-in，預設 false |
| F02 | Implemented + runtime verification pending | 加入 `tini`、`RUNNER_MANUALLY_TRAP_SIG=1`、`STOPSIGNAL SIGTERM`；busy-job 實測仍需隔離 runner |
| F03 | Implemented | 預設 Compose 移除 Docker socket；另以明確 override opt-in，文件列出 root-equivalent trust boundary |
| F04 | Implemented + host matrix pending | Docker override 要求 `DOCKER_GID` supplemental group，entrypoint 以 `docker info` fail-fast |
| F05 | Contract narrowed | 不宣告 DooD 的 GitHub job container / service / container action 支援，只承諾主動 docker CLI 使用 |
| F06 | Implemented | 提供 fresh-container ephemeral 流程，reuse `.runner` 時 fail closed；更完整 JIT orchestrator 仍屬外部系統 |
| F07 | Implemented | 支援 token file、設定後 unset token、加入 ignore / dockerignore |
| F08 | Implemented | Runner 更新至 2.337.0；更新 SLA / EOL 仍需維護流程持續執行 |
| F09 | Partially implemented | Runner archive 有固定 SHA-256、fail/retry；base image digest 於正式 release evidence 記錄，尚未永久 pin |
| F10 | Partially implemented | 新增 CI：ShellCheck、lifecycle tests、Compose config、image build；registry provenance / release publication 尚未啟用 |
| F11 | Decision pending | 不代替維護者選 LICENSE；README 明示目前未授權狀態 |
| F12 | Partially implemented | 新增 SECURITY、CONTRIBUTING、CODEOWNERS；branch protection、Dependabot、repo security settings 未自動變更 |
| F13 | Implemented | 保持既有 Organization-only 意圖並在 entrypoint 驗證；Dockerfile fail-fast 限定 amd64 |
| F14 | Partially implemented | 加入 stop grace、log rotation 與 operations runbook；ready/metrics/resource limits 仍需依部署環境設計 |

## 仍需獨立批准 / 驗證

1. LICENSE 選擇。
2. GitHub branch ruleset、required checks、Dependabot / vulnerability settings。
3. 真實 GitHub runner 的 idle / busy signal integration test。
4. Production runner rollout / rollback。
5. Registry release、SBOM、attestation 與 vulnerability scan publication。
6. 若未來要支援 repository-level runner、ARM64 或 GitHub container features，需另建支援矩陣與測試。
