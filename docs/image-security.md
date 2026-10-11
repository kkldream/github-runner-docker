# 本機映像安全掃描與版本候選

日期：2026-10-08（台灣時間）。本機已對 actual runner image 執行 Trivy 0.75.0 漏洞掃描及 CycloneDX SBOM；**不是已發布 release、attestation、registry provenance 或安全放行**。

## 掃描來源與快照

- Build source：main `194699204be418b91ab1dbe9b143397c9feea34e`；本次 `Dockerfile` 與 `entrypoint.sh` 未變。掃描對象以下列精確 image ID 為準，不冒充最終 PR SHA 的 release。
- `ubuntu:22.04` 實際 build pull digest：`sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401`（由 build log 與本機 RepoDigests 核對）。這是此次輸入記錄，**Dockerfile 仍是浮動 tag，並未完成 source digest pinning**。
- Scanner：Trivy **0.75.0**；同一次漏洞 DB schema **2**，`UpdatedAt=2026-10-07T07:38:55.515026687Z`、`DownloadedAt=2026-10-08T14:45:04.998567642Z`（原始 UTC metadata）。
- 此次 DB 檔 SHA-256：`5f4b978a55284b1997dc31e9f2fc3f4f1abae80829f51451ade221d5675a69b9`。所有比較使用相同 cache 並帶 `--skip-db-update`，結果只適用此快照，不能當作後續最新漏洞狀態。

## 目前 Dockerfile 的 2.337.0 image

- 本機 image ID：`sha256:66a82859f107d58d414163dbc463460072f3394bb9797aac0552ef94ae42ca23`；不是 registry manifest digest。
- Package/advisory 紀錄：CRITICAL **2**、HIGH **33**、MEDIUM **52**、LOW **27**。
- Ubuntu 22.04 的 OS 類沒有 high／critical；上述 high／critical 位於 Node package 類。沒有因 OS 類沒有 high／critical 就宣稱整張 image 安全。
- high／critical 涵蓋 **25 個不同 CVE ID**，其中 **33 筆紀錄**有 scanner 提供的修補版本；同一 CVE 可以命中不同 package version，因此不把紀錄數當成可達漏洞數。
- 本機 SBOM **882 components**，已生成並解析；未做 registry publication。
- 原始 evidence：`runner-vulnerabilities.json`、`runner-sbom.cdx.json`，位於此次 checkout 旁的 `../parent-evidence/`（本機 scratch；與 `../runner-evidence/` 的生命週期測試證據分開）。未提交原始報告；scratch 可能被清理，可對精確候選重跑。

## 官方 2.338.0 候選試建

[官方 release v2.338.0](https://github.com/actions/runner/releases/tag/v2.338.0) 於 2026-10-06 發布；Linux x64 archive SHA-256：`af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32`。本次只以既有 Dockerfile 的 build args 試建，校驗 archive 並執行真正 `Runner.Listener --version`，結果為 **2.338.0**；沒有更動 repo 預設、正式 runner 或註冊。

- 候選本機 image ID：`sha256:2bf3da2475770750551b635184c3b8668f980e78a4c7ae85239a24f9ee9a73c4`。
- 相同 scanner／DB 下為 1 critical／30 high／49 medium／25 low，high／critical 涵蓋 24 個不同 CVE ID。
- **仍有 high／critical，不是安全修復完成。** 沒有用 2.337.0 的 smoke 結果冒充 2.338.0 的 10-case 驗收。
- GitHub 採 progressive release；採用版本要核對目標 organization 的 download instructions，再跑完整 image／signal smoke、更新 checksum 與 evidence。此試建沒有證明目標 organization 已獲准該版本，也不能由 Dockerfile 推定已註冊的 runner 未自動更新。

## Release 安全閘門

1. 核對上游 packaged Node/npm 的實際路徑、公告條件與可達性；優先跟隨 official runner 修補，不任意改寫已校驗 archive 內的第三方依賴或刪除 compatibility runtime。
2. 每次版本／base 更新重新 build、shell lifecycle、Compose、actual-image signal smoke、掃描與 SBOM；未提供 fix 的命中需 vendor 分析及明確風險處置。
3. 本次只是 local scan/SBOM 證據；**尚未 security cleared，也未發布 release／SBOM／attestation／provenance**。
4. 真實 registration／idle／busy job、host socket permission matrix、LICENSE、repo policy、production rollback 仍是獨立閘門，見 [FORMALIZATION](FORMALIZATION.md)。

```sh
trivy image --scanners vuln --format json --output image-vulnerabilities.json <exact-candidate-image>
trivy image --format cyclonedx --output image-sbom.cdx.json <exact-candidate-image>
```

本次 binary 已核對官方 release SHA-256；第二條只生成 SBOM，不等於漏洞掃描。沒有新增 ignore policy，也沒有執行任何 production／registry 寫入。
