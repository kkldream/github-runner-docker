# Contributing

## Pull requests

變更應保持安全預設，且不要把 runtime 未驗證的行為寫成已保證支援。

提交前至少執行：

```bash
bash tests/entrypoint_test.sh
docker compose config
DOCKER_GID=999 docker compose -f docker-compose.yml -f docker-compose.docker.yml config
docker build -t github-runner-docker:test .
```

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
