# Issue #2 Formalization Status

此文件記錄 repository 內能直接落地的修正，以及仍需要 runtime / policy 決策的項目。它不把未驗證 runtime 行為標示成已完成。

| Finding | 本次狀態 | 處理 |
| --- | --- | --- |
| F01 | Implemented | 已存在 `.runner` 時永不重跑 `config.sh`；`RUNNER_REPLACE` 改為首次設定的 opt-in，預設 false |
| F02 | Implemented + 離線 actual-image 驗收通過；真實 job pending | 實際 `tini` / entrypoint / upstream wrappers 搭配明確 FAKE Listener 通過 TERM / INT、合成 busy child drain 與 stop bound；未驗證真實 GitHub idle / busy job |
| F03 | Implemented | 預設 Compose 移除 Docker socket；另以明確 override opt-in，文件列出 root-equivalent trust boundary |
| F04 | Implemented + host matrix pending | Docker override 要求 `DOCKER_GID` supplemental group，entrypoint 以 `docker info` fail-fast |
| F05 | Contract narrowed | 不宣告 DooD 的 GitHub job container / service / container action 支援，只承諾主動 docker CLI 使用 |
| F06 | Implemented | 提供 fresh-container ephemeral 流程，reuse `.runner` 時 fail closed；更完整 JIT orchestrator 仍屬外部系統 |
| F07 | Implemented | 支援 token file、設定後 unset token、加入 ignore / dockerignore |
| F08 | Implemented | Runner 更新至 2.337.0；更新 SLA / EOL 仍需維護流程持續執行 |
| F09 | Partially implemented | Runner archive 有固定 SHA-256、fail/retry；base image digest 於正式 release evidence 記錄，尚未永久 pin |
| F10 | Partially implemented | CI image build 後有界離線 actual-image smoke，另有不接觸 daemon 的 harness fault regressions；本地已實跑 6 個 lifecycle tests、25 個 fault tests、3 組 Compose renders、10 個 smoke tests。遠端 CI 狀態以本 PR **目前 head commit 的 Checks 頁面**為準，不以本地 GREEN 推定遠端通過，也不預告尚未執行的 checks；registry provenance / release publication 仍未啟用 |
| F11 | Decision pending | 不代替維護者選 LICENSE；README 明示目前未授權狀態 |
| F12 | Partially implemented | 新增 SECURITY、CONTRIBUTING、CODEOWNERS；branch protection、Dependabot、repo security settings 未自動變更 |
| F13 | Implemented | 保持既有 Organization-only 意圖並在 entrypoint 驗證；Dockerfile fail-fast 限定 amd64 |
| F14 | Partially implemented | 加入 stop grace、log rotation 與 operations runbook；ready/metrics/resource limits 仍需依部署環境設計 |

## 仍需獨立批准 / 驗證

1. LICENSE 選擇。
2. GitHub branch ruleset、required checks、Dependabot / vulnerability settings。
3. 真實 GitHub runner 的 idle / busy signal integration test。
4. Production runner rollout / rollback。
5. Registry release、SBOM／scan 的 publication、attestation 與 provenance。本次已補本機 Trivy／CycloneDX 證據，但仍有 high／critical 命中，未 security cleared；見 [image-security](image-security.md)。
6. 若未來要支援 repository-level runner、ARM64 或 GitHub container features，需另建支援矩陣與測試。
7. Host Docker socket 的正確／錯誤 supplemental GID、daemon 不可達與 permission matrix；本次沒有掛 host socket。

## 本地驗收證據與界線

在 Linux/amd64 Docker daemon 上，由目前 Dockerfile 實際建置 image，非只檢查設定文字。`tests/container_smoke_test.sh` 共 10 個 acceptance cases：

| Cases | 實際驗證 | 不代表 |
| --- | --- | --- |
| 1–2 | 未替換 image 的 `Runner.Listener --version` = 2.337.0、UID = 1001；首次設定缺 token exit 2 | 真實 registration / GitHub session |
| 3–6 | 實際 PID 1 是 `tini`，保留 entrypoint / upstream `run.sh` / `run-helper.sh`；FAKE idle / busy 的 TERM / INT 送到 process group，Listener 與合成 child 收 INT，child drain / reap | 真實 GitHub job cancellation、Worker / job descendants 或 production stop SLA |
| 7 | 真實 upstream config wrapper + FAKE configure；token-file 覆蓋 env token，Listener 環境不存在三個 registration-token 變數 | token 已從 Docker metadata / configure argv / secret file 移除 |
| 8–9 | 同一容器 stop-start，synthetic `.runner` 不變且只 configure 一次；ephemeral reuse exit 2 | synthetic `.runner` 是有效 GitHub credentials |
| 10 | Docker opt-in 缺 socket 時 exit 2，尚未進入 Listener | host socket / supplemental GID 權限矩陣 |

Busy TERM 使用真正 `docker stop --timeout 10`；ready 後送 signal，要求 15 秒內結束、非 OOM、非 SIGKILL，合成 child 完成 drain / reap。上游 manual-trap 路徑把 TERM / INT 都轉成 helper process-group INT；此 image 實測外層 exit code 分別為 **143 / 130**，不是 0。這是 wrapper / fixture 的退出語意，不是所有真實 job 的承諾。

另外實跑 scratch-only 負控制：僅將 entrypoint 最後一行改成 `exec env -u RUNNER_MANUALLY_TRAP_SIG ./run.sh`，建置獨立 `hermes-issue2-runner:no-forwarding` image。相同 smoke 在第三個 case idle TERM 因缺少 `FAKE_LISTENER_SIGNAL=INT` **RED（suite exit 1）**；回到未變更的正式 Dockerfile image 後 **GREEN（10/10）**。失敗發生在 signal 語意，不是 syntax / lint。repository 的 `entrypoint.sh` / `Dockerfile` 不需修改。

### Harness 故障回歸修正

`container_smoke_fault_test.py` 直接載入 actual-image smoke 共用的 sourceable helpers；不以 source-text eval 或完整偽造 image 驗收取代 runtime。**歷史 helper-fix snapshot** 以當時相同 **20** 個 fault cases 得到 **RED：18 failures、suite exit 1**，修正後 **GREEN：20/20、exit 0**；包含 query exit 1／124 被誤判成功、`rm` exit 0 但 resource 仍在、logs overwrite、16 秒晚到 ready 被接受及忽略 TERM 的 CLI 無 hard bound。這不是目前 25-case suite 對舊 helper 的 RED 聲明。該輪另實跑未變更 production source 的 `hermes-issue2-runner:test`，**10/10、exit 0**。

**第一輪 PID-rerun fix（23-case 快照）**：保存修正前 Python runner 原文（不是只換舊 helper），在同一個新 artifact base 的兩次程序 invocation 僅跑 `FaultTests.test_supervisor_term_cleans_up_nested_cli`。第一次 PASS，第二次 **RED（exit 1，0.002s，`-15 != 143`）**，重現舊 PID 檔誤判 readiness 導致 handlers 安裝前就 TERM。修正後對同一 base 的兩次 invocation 都 **GREEN（exit 0，2.618s／2.619s）**，產生不同 `run-28rfilz3`／`run-qh_zy7ih` child 及不同 readiness nonce。該輪 suite 為 **23/23、exit 0、83.957s**；另外三個新增 semantic regressions focused run **3/3、8.074s**，6 個 lifecycle tests 與 ShellCheck／Bash／Perl／Python syntax checks 通過。

`FAULT_ARTIFACT_DIR` 是可重用 **base**，每次 suite invocation 建立唯一 `run-*`，case／PID 檔永不跨 run 重用；stdout 印出的 `FAULT artifacts: ...` 是實際 evidence 路徑。CLI 與 child handlers ready 後 atomic publish 本次 nonce／start-time identities；readiness 與 teardown 驗證 runtime nonce、command ancestry、`/proc` start time，再使用 pidfd，沒有裸 PID-file `kill` 或 broad `pkill`。Repeated-base regression 只跑單一 current target case 兩次，不跑兩輪完整 23-case suite。Legacy numeric／stale nonce／unrelated process（即使有本次 nonce）／start-time mismatch 的真實 canaries 均保留且無 signal，並以 pipe round-trip 確認未被延遲 signal 影響。

第一輪 23-case fix 時，共用 `container_smoke_helpers.sh`／deadline supervisor／actual-image smoke／Perl fixture 及 Dockerfile／entrypoint 與 fix 前 SHA-256 完全相同。該輪 read-back 快照確認 **77 個不同 recorded PIDs 全部 absent（含 zombie）**、無 canary leftovers／signal logs；`worker-verification.json` 的 78 筆 record checks 包含重複 PID，不能當成 78 個不同程序，也不是後續新增測試的累計總數。該輪另重跑未變更的 `hermes-issue2-runner:test`，**10/10、exit 0**；`pid-rerun-fix/actual-image.log` 與 `worker-verification.json` 記錄精確 image ID、resource bounds，以及成功 live inventory 證實該輪所有 10 個 owned names／IDs 都 absent。交付 review 後對 harness-only deadline supervisor 的安全修正另列如下；production Dockerfile／entrypoint 未變。

### 交付 review 的安全補強

獨立 QUALITY review 發現兩個安全邊界：leader 已被 `poll()` reap 後才以裸 PGID 送 signal，及非 signal case 尚未取得 fixture pidfds 就等待 supervisor 結果。新增真實 subprocess 回歸先得到 **RED：1 failure＋1 error、5.368s、exit 1**，分別是 signal 前 leader 已不存在，以及 nested supervisor 被刻意殺掉後仍有 orphaned CLI 持有 stdout，第二次 `communicate()` 逾時。RED 的獨立 guardian 只清理事先驗證的 fixture pidfds，清理不算 PASS 證據。

修正為 `waitid(WNOWAIT)` 查看退出而不 reap，完成 group signal 才 `wait()`；所有忽略 TERM 的 fixture 在 ancestry 完整時先取得 pidfds。相同兩項 regression **GREEN：2/2、0.339s、exit 0**，leader signaling 時仍是 pinned zombie，watchdog 明確 FAIL 後 CLI／child 已不存在，absence 在 guardian fallback 前斷言。這兩項加入原 23 cases，完整 suite 實跑 **25/25、84.369s、exit 0**；另以同一實際 image 重跑 **10/10、exit 0** 並完成 cleanup read-back。沒有減少原 acceptance、調大 deadline 或改 production signal policy。

Cleanup 以成功 inventory 確認 ownership／absence，只有記錄且 prefix／label 都相符的 immutable ID 才能移除，再做 authoritative read-back；不確定就非零退出、不刪除 unrelated resources。失敗 logs refresh 不覆蓋既有有效 assertion evidence，成功擷取保留 stdout + stderr。最終 suite PASS 在 cleanup 確認後才輸出。

Deadline supervisor 對 CLI／suite 皆有 TERM → KILL escalation，Linux subreaper 收回合成 descendants；signal／timeout 保留原本非零退出。一般 CLI 為 20 秒 TERM + 2 秒 KILL + 最多 0.5 秒 reap，ready／exit CLI 為 15 秒 TERM + 同樣 escalation；suite 為 180 秒 TERM + 90 秒 cleanup grace（之後 KILL），cleanup 共用 60 秒 budget。晚到成功 poll 仍不得越過 15 秒 readiness admission deadline；精確界線與 daemon 不可用時的殘留風險見 OPERATIONS。

歷史 helper-fix snapshot 量測：忽略 TERM 的 CLI 在 **22.071s** exit 124；縮短 suite timeout 的 nested-CLI／cleanup fault 在 **3.501s** exit 124；對 supervisor 發 TERM 在 **2.616s** exit 143；直接對內層 shell 發 TERM 在 **22.494s** exit 143 且完成 cleanup。該輪 GREEN 記錄的 **12 個 CLI／child PIDs 全部已不存在**（含 zombie 檢查）；成功 live inventory read-back 確認該輪 **10 個 test containers 全部不存在**，inspect snapshots 證實 network-none、512 MiB／1 CPU／64 PIDs、無 ports／mounts／privileged。

上述本地回歸不是遠端 CI、真實 GitHub registration／job 或安全清查完成聲明。CI 狀態以本 PR current-head Checks 為準，不以本地 GREEN 推定遠端通過。High／critical scanner findings 仍未 security cleared；scanner／local SBOM 證據由 [image-security](image-security.md) 記錄，release／publication／attestation／provenance 與 production／live-runner gates 仍需完成。沒有採用其他 runtime runner version。

本次本地 evidence 位於 repository 外：

```text
/root/.hermes/cache/scratch/issue-formalization.nVqlzc/runner-evidence/
  baseline-lifecycle.log        # 6/6
  compose-{base,docker,ephemeral}.yml
  baseline-build.log
  final-build.log
  shellcheck.log
  final-lifecycle.log           # 隔離外部 RUNNER_* 環境後 6/6
  final-compose.log             # 3 組 renders 通過
  red-verified.log              # 最終負控制 exit 1，缺 INT marker
  red-verified/                 # 負控制 logs / inspect / process tree
  green-final-verified.log      # 最終 10/10
  green-final-verified/         # 每個 case logs / inspect / markers；upstream wrapper snapshots
  cleanup-verified.log          # RED / GREEN 後無殘留 test containers
  no-forwarding/               # scratch-only variant Dockerfile / entrypoint
  fault-fix/                   # 歷史 20-case helper-fix snapshot，不是目前 case count
    original-container-smoke.sh # 修正前 harness snapshot
    red-helpers.sh             # 修正前函式 verbatim extraction（僅供 local RED）
    red-verified.log           # 20 cases，18 failures，exit 1
    green-verified.log         # 20/20，exit 0
    red-verified/              # 每個 fake CLI fault 的 state／output
    green-verified/            # state／output／elapsed／PIDs
    actual-image-verified.log  # 10/10，cleanup read-back 後才 final PASS
    actual-image-verified/     # logs／inspect／markers／cleanup inventory
    lifecycle.log             # 6/6
    shellcheck.log
    syntax.log
    live-inventory-after.tsv   # 成功 live inventory，10 個 owned containers absent
    verification.json          # 20 RED/GREEN、10 resource bounds、12 GREEN PIDs absent
    verify_evidence.py         # read-only evidence assertions
    commands.md                # 精確重跑命令
  pid-rerun-fix/
    original-fault-runner.py   # 修正前 Python runner 原文
    before/tests/             # 同原文 + 指向未變更 current helper／deadline 的 symlinks
    red-run{1,2}.log           # 同 base selected case：先 PASS、後 -15 != 143
    red-repeated-base/         # 歷史 bug 重現 evidence（直接 base/case）
    green-run{1,2}.log         # 同 base selected case：兩次 PASS
    green-repeated-base/run-*/ # 每次唯一 child，current readiness.json／PID identities
    focused-final.log          # 3/3，8.074s
    focused-final/run-*/       # 真實 canaries／selected child invocation evidence
    green-suite.log           # 23/23，83.957s
    green-suite/run-*/         # 23 cases；nested repeated-base 也有自己的 run-* children
    green-suite-repeat.log    # 相同 base 的第二次完整執行，23/23
    focused-current.log       # 最終 source 的新增 regressions，3/3
    mutations/*/red.log       # unsafe numeric teardown／移除 start identity：canary 語意 RED
    actual-image.log          # 本輪重跑實際 image，10/10
    actual-image/             # 本輪 logs／inspect／markers／cleanup inventories
    worker-verification.json # 精確 image／owned IDs／PID absence／protected SHA-256
    lifecycle.log             # 6/6
    shellcheck.log
    syntax.log
    unchanged-runtime-sha256.json
    live-inventory-after.tsv   # 本次成功 live inventory，原 10 個 names／IDs absent
    verification.json         # read-back 快照：23 GREEN、77 個不同 PIDs absent
    verify_evidence.py         # read-only evidence assertions
    commands.md               # base／unique-run 精確命令
  delivery/
    spec-review.log           # 第一輪獨立 SPEC review
    quality-review.log        # 第一輪 QUALITY review：兩個安全 blocker
    safety-red.log            # 兩個新安全 regression 的 RED（1 failure＋1 error）
    safety-green.log          # 相同安全 regressions GREEN，2/2
    fault-suite-final.log     # 安全修正後完整 25/25，84.369s
    faults-final/run-*/        # 25-case evidence（含 selected repeated-base）
    actual-image-final.log    # 安全修正後實際 image 10/10，cleanup read-back
    actual-image-final/       # logs／inspect／markers／inventory
```

可重跑命令見 CONTRIBUTING；上述 scratch 路徑是本機 evidence，不是公開下載 URL 或遠端 CI 通過聲明。遠端 current-head CI 的 logs 與 `runner-acceptance-<run-id>-<attempt>` artifact 則可由 PR Checks 進入 workflow 執行頁查看／下載，artifact 保留 14 天；早期失敗可能尚無 evidence，不能把 artifact 上傳成功當作驗收成功。所有本機測試容器已由 suite trap 清除；保留本地 proof images，不做 global prune。LICENSE、Organization-only / amd64 / unsupported DooD container features 合約、repo settings、production rollout / rollback 與 release gates 均不因此變更。
