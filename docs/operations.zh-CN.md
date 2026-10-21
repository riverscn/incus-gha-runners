[English](operations.md)

# 日常操作

以下命令都在主机上以 root 执行，`bin/` 指 `/opt/incus-gha-runners/bin/`。取令牌的命令在已登录 `gh` 的地方执行（`OWNER/REPO` 与 `GITHUB_URL` 一致；组织用 `orgs/ORG/…`）。任何会停掉 runner 的操作之前先看 `status`：`JOB` 一列必须是 `no`。

## 加 runner

把配置里的 `RUNNER_COUNT` 调大，然后加新编号：

```bash
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
  | ssh HOST sudo bin/add-runner --token-stdin 5 6
```

## 减 runner

```bash
ssh HOST sudo bin/status
gh api -X POST repos/OWNER/REPO/actions/runners/remove-token --jq .token \
  | ssh HOST sudo bin/remove-runner --token-stdin --yes 6
```

然后调小 `RUNNER_COUNT`。`remove-runner` 拒绝处理正在跑任务的 runner（`--force` 可以强制，那个任务会失败）。容器里的东西一起删掉，包括它的 Docker 镜像和缓存。

## 换模板

每个 runner 都需要新东西时（新版 Docker、`EXTRA_PACKAGES`、改过的钩子不适合原地执行）：

```bash
sudo bin/build-template --rebuild --yes
```

它先建 `<前缀>-tpl-new`，成功后才替换旧模板。已有的 runner 不受影响，逐个重建，让其他 runner 继续接任务：

```bash
# 对每个 N，等 status 显示它空闲时：
gh api -X POST repos/OWNER/REPO/actions/runners/remove-token --jq .token \
  | ssh HOST sudo bin/remove-runner --token-stdin --yes N
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
  | ssh HOST sudo bin/add-runner --token-stdin N
```

重建的 runner 缓存是空的，头几个任务会慢一些。

runner 程序会自己升级（GitHub 给空闲的 runner 推送更新），不需要为此重建。系统镜像（`BASE_IMAGE=mmdebstrap` 时的 `igr/debian-<版本>`）每次重建都复用，建模板时会 `apt-get full-upgrade`。确实要从新的系统镜像开始时，重建前先 `incus image delete igr/debian-trixie`。

## 用钩子装项目依赖

钩子是 `HOOKS_DIR`（默认 `/etc/incus-gha-runners/hooks.d/<CONTAINER_PREFIX>`）里的 `*.sh`。每个钩子被推进容器，按文件名顺序以 root 执行，环境变量里有这些配置：`NETWORK_PRESET`、`DEBIAN_SUITE`、`DEBIAN_MIRROR`、`DEBIAN_SECURITY_MIRROR`、`DOCKER_APT_URL`、`HUB_MIRROR`、`HUB_MIRROR_ADDR`（`HUB_MIRROR=on` 时）、`EXTRA_PACKAGES`、`DOCKER_BUILDER_KEEP`。钩子必须可以重复执行，失败时必须以非零退出。

该放进钩子的：工作流需要 root 才能装的东西，因为 `runner` 用户没有 sudo——`apt-get install` 系统库、`playwright install --with-deps`、系统级的工具链。不该放的：工作流能装到用户目录的东西（`actions/setup-node` 装的 Node、pnpm、Playwright 浏览器本体），这些本来就在容器里跨任务缓存。

`build-template` 在模板里执行全部钩子。改了钩子后，不重建也能让已有 runner 跟上：

```bash
sudo bin/apply-hooks --all
```

执行钩子期间会停掉该 runner 的服务；正在跑任务的 runner 被跳过（退出码 3，稍后再执行一次）。

### 例子：Playwright

[`examples/hooks/50-playwright-chromium.sh`](../examples/hooks/50-playwright-chromium.sh) 临时装一份 Node，执行 `npx playwright@<版本> install-deps chromium`，再删掉 Node。把其中的 `PLAYWRIGHT_VERSION` 改成项目 `@playwright/test` 的版本。工作流里用 `playwright install chromium`（不加 `--with-deps`）。项目升级 Playwright 后 e2e 报缺系统库时，改钩子里的版本，执行 `apply-hooks --all`。

```bash
sudo install -d /etc/incus-gha-runners/hooks.d/ci
sudo cp /opt/incus-gha-runners/examples/hooks/50-playwright-chromium.sh /etc/incus-gha-runners/hooks.d/ci/
```

## 一台主机多组 runner

每组一份配置文件，各用自己的 `CONTAINER_PREFIX`（通常还有自己的 `GITHUB_URL` 或标签）：`sudo bin/add-runner --config /etc/incus-gha-runners/other.env --all`。主机部分（`prepare-host`）共用，用哪份配置执行都行。

## 迁移直接跑在主机上的 runner

1. 先建模板，用**新名字**加容器 runner（换一个 `RUNNER_NAME_PREFIX`，或者接在已有编号后面），新旧并行一段时间。
2. 容器 runner 跑过几轮都正常后，趁旧 runner 空闲时停掉：在每个旧 runner 目录里 `sudo ./svc.sh stop && sudo ./svc.sh uninstall`，再以当初配置它的用户执行 `./config.sh remove --token …`（remove-token）。
3. 这之后才删旧 runner 的目录；旧用户如果只为 runner 而建，也一并删掉。

要把手工搭的容器换成本脚本建的容器，用相同的容器名和 runner 名：`build-template` 遇到不是自己建的模板会拒绝，直到你加 `--rebuild --yes`；然后按"换模板"逐个重建 runner。`add-runner` 注册时带 `--replace`，新容器会顶替同名的旧注册。

## 更新本脚本

```bash
sudo git -C /opt/incus-gha-runners pull
```

已有的容器和模板照常工作；模板内容相关的改动在下一次 `build-template --rebuild` 后生效。
