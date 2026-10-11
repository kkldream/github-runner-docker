# 離線 container smoke fixtures

`FakeListener.pl` 是**明確的 FAKE Listener**，只實作本測試用的 `configure` / `run`；不連線 GitHub、不註冊／移除 runner、不執行真實 GitHub job。測試容器固定 `--network none`、不公開 ports、不掛 host socket、不使用 privileged，只有假 token。

測試只將這個 fixture 複製到 stopped test container 的 `bin/Runner.Listener`；保留實際 image 的 `tini`、`entrypoint.sh`、upstream `config.sh` / `env.sh` / `run.sh` / `run-helper.sh.template`。真正的 `Listener --version` 與 UID probe 使用**未替換**的 image。

- `configure` 只接受 `https://github.com/example-org` 與 `FAKE-ENV-TOKEN` / `FAKE-FILE-TOKEN`，並驗證 token-file 優先權。
- `.runner` 內容包含 `FAKE_TEST_ONLY` / `NOT_REGISTERED`；它只測試 entrypoint 的存在性分支，**不能當 GitHub registration evidence**。
- `fake-*` marker / stdout 是合成行為的證據。`FAKE_LISTENER_READY` 在 signal handler 與 busy child 已準備後才出現；host harness 取得 ready 後才送 signal。
- busy 模式產生一個真實 OS child，但工作內容是合成等待。child 接收 upstream process-group signal，等待約 1 秒 drain；FAKE parent 不代替 upstream 轉送 signal，而是等待並 reap child。
- fixture 驗證 `RUNNER_TOKEN`、`RUNNER_TOKEN_FILE`、`RUNNER_REGISTRATION_TOKEN` 沒有傳入 Listener environment；這**不**表示 Docker container metadata、首次 configure argv 或 token 檔已被清除。
- fixture 對重複 configure fail closed；同一容器 stop-start 必須沿用 synthetic `.runner`，ephemeral stop-start 必須拒絕。

Fault suite 的 fake Docker CLI／child 與 actual-image Perl Listener 是不同 fixtures。25 個 fault cases 每次在 `FAULT_ARTIFACT_DIR` base 下建立唯一 `run-*`，ready PID records 含 fresh nonce／start time，teardown 僅向驗證 runtime ownership 的 pidfd 送 signal。Repeated-base 回歸只在 fresh subprocess 中跑單一 TERM case 兩次；stale／unrelated canaries 必須保留且無 signal，不代表真實 daemon 或 image 驗收。另以真實退出 leader 驗證 group signal 前仍未 reap，並刻意殺掉已驗證 nested supervisor，確認 early-captured pidfds 可處理 orphaned CLI／child；absence 必須在獨立 guardian fallback 前成立。

所有 test containers 使用 `hermes-issue2-smoke-*` 唯一名稱，EXIT / INT / TERM 時只移除自己記錄且 unique prefix／ownership label 相符的 immutable container ID，再以成功 inventory read-back 確認 absence。query failure／timeout 或 ownership 不確定時 fail closed，不嘗試刪除其他資源；daemon 不可用時可能留下 test containers，但一定非零退出。logs 成功擷取才 atomic replace，失敗輸出另存 `*.logs.error`，不覆蓋有效 assertion evidence。logs、inspect、process tree 與 markers 保留於 `SMOKE_ARTIFACT_DIR`，其中的 token 全是 FAKE。deadline 與 cleanup grace 見 OPERATIONS；`container_smoke_fault_test.py` 直接測試共用 helper，不接觸真實 daemon。真實 runner idle / busy job 行為與 host socket GID matrix 仍需另外驗收。
