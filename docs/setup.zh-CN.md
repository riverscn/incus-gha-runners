[English](setup.md)

# 安装：从一台空主机到可用的 runner

需要：一台 Linux 主机（在 Debian 13 上验证过），你有 sudo；只有要用 Docker Hub 拉取缓存时主机上才需要 Docker；你自己电脑上的 `gh` 已登录，对仓库（或组织）有管理员权限。

## 1. 取脚本，写配置

```bash
sudo git clone https://github.com/riverscn/incus-gha-runners /opt/incus-gha-runners
sudo install -d /etc/incus-gha-runners
sudo cp /opt/incus-gha-runners/config.example.env /etc/incus-gha-runners/config.env
sudoedit /etc/incus-gha-runners/config.env
```

至少设置 `GITHUB_URL`、`RUNNER_LABELS`（工作流里用的标签，如 `runs-on: [self-hosted, ci]` 里的 `ci`）、`RUNNER_COUNT`；主机在国内时设 `NETWORK_PRESET=cn`。所有配置项见 [design.zh-CN.md](design.zh-CN.md#4-配置)。

容量：每个容器跑过几次任务后约占 5~7G 磁盘（系统、Docker、依赖镜像、缓存、最多 `DOCKER_BUILDER_KEEP` 的构建缓存）。不设 `LIMITS_CPU` / `LIMITS_MEMORY` 时，容器共用主机的 CPU 和内存。

## 2. 准备主机

```bash
sudo /opt/incus-gha-runners/bin/prepare-host --dry-run
```

看清它要做什么。它可能改主机的防火墙（只在主机上的 Docker 把 `FORWARD` 默认策略设成 DROP 时：放行 Incus 网桥经出口网卡出网和回包，别的都不放开），以及启动 Docker Hub 拉取缓存容器（`HUB_MIRROR=on` 时，只绑网桥地址）。同意后：

```bash
sudo /opt/incus-gha-runners/bin/prepare-host
```

`HUB_MIRROR=on` 时，主机自己要从 Docker Hub 拉一次 `registry:3`。这次拉取被重置时，用你手头的任意镜像站拉下来，再 `docker tag` 成 `registry:3`。

## 3. 用钩子装项目 CI 需要的东西

`runner` 用户没有 sudo，工作流需要的系统包（如 Playwright 浏览器的系统库）必须预装在模板里。建模板前把安装脚本放进 `HOOKS_DIR`（默认 `/etc/incus-gha-runners/hooks.d/<CONTAINER_PREFIX>`），见 [operations.zh-CN.md](operations.zh-CN.md#用钩子装项目依赖)。工作流不需要 root 装任何东西时跳过这一步。

## 4. 建模板

```bash
sudo /opt/incus-gha-runners/bin/build-template
```

要几分钟：系统镜像（下载，或用 mmdebstrap 构建）、Docker、runner 程序、钩子。结束时有一个停止状态的 `<前缀>-tpl`，并打印一行，如 `built 2026-10-21T09:30Z: debian trixie, docker-ce 5:29.0.0-1~debian.13~trixie, runner 2.338.0, hooks: 50-playwright-chromium.sh`。

## 5. 加 runner

在你自己的电脑上：

```bash
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
  | ssh HOST sudo /opt/incus-gha-runners/bin/add-runner --token-stdin --all
```

令牌只经过管道，不进文件，也不出现在命令行上。然后：

```bash
ssh HOST sudo /opt/incus-gha-runners/bin/doctor
ssh HOST sudo /opt/incus-gha-runners/bin/status
```

`doctor` 每行都是 `ok`；仓库的 Settings → Actions → Runners 里能看到这些 runner 处于空闲状态。容器开机自动启动，runner 服务也随之启动。

## 安全

任务在容器里执行仓库的代码。容器是非特权的（容器内的 root 是主机上的普通 uid），碰不到主机的文件、主机的 Docker 和其他容器里的凭据，但能访问主机所在的网络和主机在网桥上的地址。容器长期存在，一个任务留下的东西，同一容器里的下一个任务能看到。只给你信任的仓库用，不要让 fork 来的 PR 触发工作流（公开仓库：Settings → Actions → General 里要求所有外部协作者先审批，或者干脆不在公开仓库用 self-hosted runner）。
