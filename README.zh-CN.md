# incus-gha-runners

[English](README.md)

**在一台 Linux 主机上跑多个 GitHub Actions self-hosted runner，每个 runner 一个 Incus 系统容器。**

> **用 AI 编码助手？** 先安装 skill：
>
> ```bash
> npx skills add riverscn/incus-gha-runners
> ```
>
> 然后在你的项目里打开 agent，这样说，例如：
>
> ```text
> 用 incus-gha-runners 在我的主机（`ssh myhost`）上给这个仓库装 4 个 GitHub Actions self-hosted runner，
> 每个 runner 一个 Incus 容器。主机在国内。读工作流，找出要用的标签和任务需要预装的系统包。
> 改动主机之前先把每一项改动给我看，不要打印任何令牌。
> ```
>
> 以后也可以直接问："再加两个 runner"、"升级 Playwright 后 e2e 报缺共享库"、"3 号 runner 为什么离线？"。
> agent 会执行脚本，改动主机或 runner 之前先问你。

几个 self-hosted runner 以同一个用户的进程跑在同一台主机上时会互相干扰：并行任务同时改写 `$HOME` 里的同一个工具目录；一个任务 `docker compose down` 改了网络，另一个任务里的浏览器报 `net::ERR_NETWORK_CHANGED`；`docker` 组等于主机 root。本项目给每个 runner 一个非特权的 Incus 系统容器，从模板复制，里面有自己的 systemd、dockerd、网络命名空间和 `runner` 用户。任务看到的是一台独立的机器，工作流写法和 GitHub 托管的 runner 一样。

- 在主机上以 root 执行的 Bash 脚本：`prepare-host`、`build-template`、`add-runner`、`remove-runner`、`apply-hooks`、`status`、`doctor`。都可以重复执行，都支持 `--dry-run`。
- 一组 runner 一份配置文件：仓库或组织、标签、名字、数量。
- 长期容器：缓存、镜像、构建缓存在任务之间保留。不是一次性（ephemeral）runner。
- 国内网络开关：Debian 镜像源、本地构建系统镜像代替 images.linuxcontainers.org、Docker Hub 拉取缓存。
- 项目特有的系统依赖（如 Playwright 浏览器的系统库）写成钩子脚本。
- 注册令牌从你电脑上的 `gh` 经管道传进去，主机上不放 GitHub 凭据。
- 一个 [agent skill](skills/incus-gha-runners/SKILL.md)：由 agent 执行脚本，改动主机或 runner 前先问你。

## 快速开始

在主机上：

```bash
sudo git clone https://github.com/riverscn/incus-gha-runners /opt/incus-gha-runners
sudo install -d /etc/incus-gha-runners
sudo cp /opt/incus-gha-runners/config.example.env /etc/incus-gha-runners/config.env
sudoedit /etc/incus-gha-runners/config.env        # GITHUB_URL、RUNNER_LABELS、RUNNER_COUNT、NETWORK_PRESET
sudo /opt/incus-gha-runners/bin/prepare-host --dry-run   # 看清楚，再去掉 --dry-run 执行
sudo /opt/incus-gha-runners/bin/build-template
```

在你的电脑上：

```bash
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
  | ssh HOST sudo /opt/incus-gha-runners/bin/add-runner --token-stdin --all
ssh HOST sudo /opt/incus-gha-runners/bin/doctor
```

然后在工作流里用这个标签：`runs-on: [self-hosted, ci]`。

## 文档

- [安装](docs/setup.zh-CN.md)：从一台空主机到可用的 runner
- [日常操作](docs/operations.zh-CN.md)：加减 runner、换模板、钩子、迁移、一台主机多组
- [故障排查](docs/troubleshooting.zh-CN.md)
- [设计](docs/design.zh-CN.md)：所有配置项、脚本、参数和退出码

## 验证环境

Debian 13（trixie）主机，Docker 29.9，Incus 6.0.4（Debian 自带的包），QEMU 虚拟机 12 核 11G，跑 4 个 runner，承担一个 pnpm monorepo 的 CI（类型检查、桌面和手机两路 Playwright e2e、用 Compose 的 Docker 镜像构建），`NETWORK_PRESET=cn`。`images.linuxcontainers.org` 那条路径（`BASE_IMAGE=images`）未验证。其他有 systemd、装得上 Incus 6.0+ 的主机应该可用（容器里都是 Debian），见[主机要求](docs/setup.zh-CN.md#主机要求)。

## 安全

任务执行的是仓库里的代码。容器是非特权的，碰不到主机的文件、主机的 Docker 和其他容器，但能访问主机所在的网络，而且容器在任务之间保留状态。只给你信任的仓库用，不要让 fork 来的 PR 在上面跑。

## 许可证

[MIT](LICENSE)
