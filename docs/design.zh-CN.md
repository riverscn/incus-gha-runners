[English](design.md)

# 设计：脚本接口、配置与开关

> 本文是脚本的约定；改脚本的行为时先改本文。

## 1. 要解决的问题

在一台 Linux 主机上跑多个 GitHub Actions self-hosted runner 时，如果它们是同一个用户、同一个网络命名空间里的几个进程，会互相干扰：

- 共用家目录：工具的默认安装位置（如 `pnpm/action-setup` 的 `~/setup-pnpm`）被并行任务同时改写。
- 共用网络命名空间：别的任务 `docker compose up/down` 增删网桥，Chromium 收到网络变化通知，把进行中的请求以 `net::ERR_NETWORK_CHANGED` 中断。
- 共用主机的 Docker：`docker` 组等于主机 root，任务能碰到主机上的其他容器和其他 runner 的凭据。

本项目让**每个 runner 独占一个 Incus 非特权系统容器**：容器里有自己的 systemd、dockerd、网络命名空间、用户 `runner` 和 runner 程序。任务看到的是一台独立的机器，工作流的写法和 GitHub 托管的机器一样。容器内的 root 映射为主机上的普通 uid，容器内 `docker` 组的权限出不了容器。

不做的事：

- **不做 ephemeral（一次性）runner。** 容器长期存在，任务之间保留 pnpm store、浏览器、Docker 镜像和构建缓存，换来速度；代价是任务之间不完全隔离（同一个仓库的任务共用一个容器的状态）。所以只用于自己信任的仓库，不对 fork 的 PR 开放。
- 不做自动扩缩容，不做 Actions Runner Controller 那样的调度。容器数量是配置里的一个数字。
- 不管主机上其他的 runner（例如直接跑在主机上、负责部署的 runner）。

## 2. 结构

```
主机（Debian 13，已装 Docker 也可以）
├── incusbr0（Incus 管理的网桥，NAT 出网）
├── hub-mirror（可选，Docker Hub 拉取缓存，只绑 incusbr0 的地址）
├── <前缀>-tpl   模板容器，停止状态，只用来复制
├── <前缀>-1     runner 容器：systemd + dockerd + actions-runner 服务
├── <前缀>-2
└── …
```

- 一份配置文件描述**一组 runner**（同一个仓库或组织、同一组标签、同一个容器名前缀）。一台主机可以有多组，各用一份配置。
- 模板容器装好全部软件但不注册；`add-runner N` 复制模板、启动、注册、装成 systemd 服务。
- 换模板内容（升级 Docker、加系统库）的做法：`build-template --rebuild`，然后逐个 `remove-runner N && add-runner N`。runner 程序本身由 GitHub 自动升级，不需要重建。

## 3. 安装与运行方式

- 仓库克隆到主机任意位置（建议 `/opt/incus-gha-runners`），脚本用 root 执行（`sudo bin/…`）。
- 主机上**不需要** `gh`、GitHub 令牌或 `jq`。注册和注销用的一次性令牌由调用方（人或 agent，通常在自己的电脑上用 `gh`）获取，经标准输入传进去，不出现在命令行参数、环境变量列表和日志里：

  ```bash
  gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
    | ssh HOST sudo /opt/incus-gha-runners/bin/add-runner --token-stdin 1
  ```

  组织级 runner 用 `orgs/ORG/actions/runners/registration-token`；注销用 `…/remove-token`。
- 所有脚本可重复执行：已经是目标状态的步骤跳过并打印 `ok`，只做缺的部分。

## 4. 配置

默认读 `/etc/incus-gha-runners/config.env`，用 `--config FILE`（或环境变量 `IGR_CONFIG`）指定别的文件，一份文件一组 runner。格式是 shell 的 `KEY=value`，被脚本 `source`。不含任何密钥。仓库里带一份 `config.example.env`，每项都有注释。

### 4.1 这组 runner

| 键 | 默认值 | 说明 |
|---|---|---|
| `GITHUB_URL` | 必填 | `https://github.com/OWNER/REPO` 或 `https://github.com/ORG` |
| `RUNNER_LABELS` | 必填 | 逗号分隔，如 `ci`。`self-hosted`、`linux`、`x64` 由 GitHub 自动加 |
| `RUNNER_NAME_PREFIX` | `<主机名>-` | 注册名为 `<前缀><N>`，如 `bot-dev-1` |
| `RUNNER_GROUP` | 空 | 只对组织级 runner 有意义 |
| `CONTAINER_PREFIX` | `ci` | 模板叫 `<前缀>-tpl`，runner 容器叫 `<前缀>-N` |
| `RUNNER_COUNT` | `1` | `add-runner --all`、`status`、`doctor` 用的数量，编号 1…N |
| `RUNNER_VERSION` | `latest` | 模板里放的 runner 版本，如 `2.337.0` |
| `LIMITS_CPU` / `LIMITS_MEMORY` | 空（不限） | 写入每个 runner 容器的 `limits.cpu` / `limits.memory` |

### 4.2 模板内容

| 键 | 默认值 | 说明 |
|---|---|---|
| `DEBIAN_SUITE` | `trixie` | 容器的系统版本 |
| `EXTRA_PACKAGES` | 空 | 额外装进模板的 apt 包 |
| `DOCKER_BUILDER_KEEP` | `3GB` | 容器内 dockerd 的构建缓存上限（`builder.gc.defaultKeepStorage`） |
| `HOOKS_DIR` | `/etc/incus-gha-runners/hooks.d/<CONTAINER_PREFIX>` | 项目特有依赖的安装脚本目录，见 4.5 |

### 4.3 网络开关（国内网络）

三个开关独立，`NETWORK_PRESET=cn` 一次设成国内适用的默认值，单独写的键优先。

| 开关 | 默认（`NETWORK_PRESET=global`） | `NETWORK_PRESET=cn` 时 | 作用 |
|---|---|---|---|
| `BASE_IMAGE` | `images` | `mmdebstrap` | `images`：从 images.linuxcontainers.org 下载 `debian/<版本>`。`mmdebstrap`：在主机上从 `DEBIAN_MIRROR` 构建 minbase 系统镜像并导入（国内下载 images.linuxcontainers.org 常被中断） |
| `DEBIAN_MIRROR` | `https://deb.debian.org/debian` | `https://mirrors.tuna.tsinghua.edu.cn/debian` | mmdebstrap 和容器内 apt 使用的源 |
| `HUB_MIRROR` | `off` | `on` | 在主机上跑 Docker Hub 拉取缓存（官方 `registry:3` 镜像，代理模式），只绑 `incusbr0` 的地址；容器内 dockerd 配成 `registry-mirrors`。缓存不可用时 Docker 自动回退直连 |

和这几个开关一起变化的下载地址（也可以单独写）：

| 键 | global | cn |
|---|---|---|
| `DEBIAN_SECURITY_MIRROR` | `https://security.debian.org/debian-security` | `https://mirrors.tuna.tsinghua.edu.cn/debian-security` |
| `DOCKER_APT_URL` | `https://download.docker.com/linux/debian` | `https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/debian` |
| `RUNNER_DOWNLOAD_URL` | `https://github.com/actions/runner/releases/download` | 同左（GitHub 下载在国内一般可用，慢时改成自己的镜像） |

`HUB_MIRROR_PORT`（默认 `5000`）、`HUB_MIRROR_NAME`（默认 `hub-mirror`）可改。

### 4.4 主机

| 键 | 默认值 | 说明 |
|---|---|---|
| `INCUS_BRIDGE` | `incusbr0` | `incus admin init --minimal` 建的网桥 |
| `UPLINK_IF` | 默认路由的网卡 | 防火墙放行规则里的出口网卡 |

### 4.5 项目特有的依赖：钩子，不进配置

脚本只装通用的东西（系统、Docker、runner）。哪个项目需要什么系统库（如 Playwright 浏览器的系统库、某个语言的编译工具链），由人或 agent 按项目的工作流判断，写成钩子脚本，不在配置里为某个工具开专门的键。

- 钩子是 `HOOKS_DIR` 下的 `*.sh`，按文件名顺序推进容器、以 root 执行，必须可重复执行。环境变量里有 `DEBIAN_MIRROR` 等配置项，供钩子使用国内源。
- `build-template` 建模板时执行全部钩子；已有的 runner 容器用 `apply-hooks [N…|--all]` 补上，不用重建（跳过正在跑任务的容器）。
- 为什么要预装：runner 用户没有 sudo，工作流里装不了系统包（如 Playwright 的 `--with-deps`）。工作流自己能装到用户目录的东西（Node、pnpm、浏览器本体）不放进钩子。
- skill 说明怎么判断要装什么（看工作流里哪些步骤需要 root），`docs/operations` 给出常见例子，包括 Playwright：临时装 Node，`npx playwright@<项目用的版本> install-deps chromium`，删掉 Node；升级 Playwright 后再 `apply-hooks --all`。

## 5. 脚本

都在 `bin/`，以 root 执行，共用 `lib/common.sh`。通用参数：`--config FILE`、`--dry-run`（只打印将要做的改动，不改任何东西）、`-h`。退出码：`0` 成功；`1` 失败；`2` 用法错误；`3` 需要确认（见 5.7）。

### 5.1 `prepare-host`

一次性准备主机，可重复执行。

1. 检查系统（Debian 13 以外的给出警告，不拒绝）。
2. `apt-get install incus`（`BASE_IMAGE=mmdebstrap` 时加 `mmdebstrap`）。
3. Incus 未初始化时 `incus admin init --minimal`（`dir` 存储池，网桥 `incusbr0`）；已初始化则不动。
4. 主机装了 Docker 且 `FORWARD` 链默认策略是 DROP 时，安装 `incus-docker-forward.service`（`After=docker.service`，开机执行）：在 `DOCKER-USER` 链只放行 `incusbr0 → UPLINK_IF` 和回程的 `RELATED,ESTABLISHED`，不放开主机的其他转发，也不用 Incus 的 `ip-forward-no-drop` 之类放开全部转发的办法。**改防火墙，需确认。**
5. `HUB_MIRROR=on` 时在主机 Docker 上起拉取缓存容器（`--restart unless-stopped`，`-p <网桥地址>:<端口>:5000`，数据卷 `hub-mirror`）。主机没装 Docker 时报错并提示改为 `off`。**在主机上开放一个服务（只对容器网段），需确认。**

已存在的同名单元和容器视为已完成（兼容本文之前手工搭的环境）。

### 5.2 `build-template [--rebuild]`

建模板容器 `<前缀>-tpl`，结束时是停止状态。

1. 系统镜像：`BASE_IMAGE=images` 时直接用 `images:debian/<版本>`；`mmdebstrap` 时在主机上构建 minbase（加 `systemd`、`systemd-resolved`、`udev`、`dbus`、`ca-certificates`、`curl`、`git`、`iproute2`、`gnupg`、`sudo`、`locales`；写 `/etc/systemd/network/eth0.network` 走 DHCP；缺 `udev` 时 networkd 一直等待、拿不到地址），以别名 `igr/debian-<版本>` 导入，之后复用。
2. 起容器，设 `security.nesting=true`、`security.syscalls.intercept.mknod=true`、`security.syscalls.intercept.setxattr=true`（容器内跑 Docker 需要），等网络就绪。
3. 容器内 apt 源指向 `DEBIAN_MIRROR`；按 Docker 官方 apt 源（`DOCKER_APT_URL`）装 `docker-ce`、`docker-ce-cli`、`containerd.io`、`docker-buildx-plugin`、`docker-compose-plugin`；写 `/etc/docker/daemon.json`（构建缓存上限、日志轮转；`HUB_MIRROR=on` 时加 `registry-mirrors` 和 `insecure-registries`）。
4. 装 `EXTRA_PACKAGES`。
5. 建用户 `runner`（只在容器内 `docker` 组，无 sudo）。runner 安装包在主机上下载并缓存到 `/var/cache/incus-gha-runners/`，推进容器解压到 `/home/runner/actions-runner`，执行自带的 `bin/installdependencies.sh`（否则缺 libicu 等）。
6. 执行钩子（见 4.5）。
7. 封装：清空 `/etc/machine-id`（否则复制出的容器 DHCP 拿到同一地址），删 `/var/lib/docker/engine-id`，`apt-get clean`，停止容器。

模板已存在且完整（有完成标记）时什么都不做。构建在 `<前缀>-tpl-new` 里进行，成功后才替换 `<前缀>-tpl`，构建失败不会留下一个坏模板。`--rebuild` 重建并替换已有模板（需要 `--yes`；不影响已有 runner 容器）。

### 5.3 `add-runner [--token-stdin] N… | --all`

对每个编号：

1. `<前缀>-N` 不存在：`incus copy <前缀>-tpl <前缀>-N`，设 `boot.autostart=true` 和 `LIMITS_*`，启动，等网络。
2. 未注册（没有 `.runner` 文件）：用标准输入读到的令牌，以 `runner` 用户执行 `config.sh --unattended --url GITHUB_URL --token … --name <RUNNER_NAME_PREFIX>N --labels RUNNER_LABELS [--runnergroup …] --replace`，然后 `svc.sh install runner`。没有令牌时停下，提示怎么取令牌（退出码 3）。
3. 服务没在运行：`svc.sh start`。

一个令牌可以注册多台（令牌一小时内有效），所以 `--all` 只要一个令牌。`--replace` 让同名的旧注册被顶替，重建容器时不用先在 GitHub 上删。

### 5.4 `remove-runner [--token-stdin] [--force] [--yes] N…`

1. 容器里有 `Runner.Worker` 进程（正在跑任务）时拒绝，`--force` 才继续。
2. 有令牌（注销用的 remove-token）时 `svc.sh stop && svc.sh uninstall && config.sh remove`；没有令牌时提示 GitHub 上会留下一个离线的 runner 记录，需要到仓库设置里删，或以后用 `add-runner` 同名注册时被 `--replace` 顶替。
3. 删除容器（连同里面的 Docker 数据）。

**停用、注销、删除，需确认**：非 `--yes` 时打印将要做的事，退出码 3。

### 5.5 `apply-hooks [N…|--all]`

在已有的 runner 容器里执行钩子（见 4.5），跳过正在跑任务的容器并报告。

### 5.6 `status`、`doctor`

- `status`：每个容器的状态、IP、runner 服务状态、注册名、是否在跑任务、磁盘占用；模板是否存在、建于何时。只读。
- `doctor`：只读检查，逐项打印 `ok` / `FAIL` 和修复办法：Incus 可用；网桥存在；转发放行规则在（主机有 Docker 时）；拉取缓存可从容器访问（`HUB_MIRROR=on` 时）；每个容器能解析域名、能访问 GitHub、容器内 `docker info` 正常、runner 服务在运行；容器 machine-id 互不相同。

### 5.7 需要确认的操作

脚本本身不交互。会改动主机或注销 runner 的操作要么由 `--dry-run` 先列出，要么需要 `--yes`，由人（或 agent 征得人同意后）再执行：

| 操作 | 脚本 | 方式 |
|---|---|---|
| 改防火墙（`DOCKER-USER` 规则和 systemd 单元） | `prepare-host` | 先 `--dry-run` 给人看 |
| 在主机上起服务（拉取缓存） | `prepare-host` | 同上 |
| 重启主机 Docker | 无（脚本从不重启 Docker；`doctor` 只提示） | 人自己执行 |
| 停用、注销、删除 runner | `remove-runner` | `--yes` |
| 删模板 | `build-template --rebuild` | `--yes` |

## 6. Agent skill

`skills/incus-gha-runners/SKILL.md` 只编排：先问清目标（新装、加 runner、换模板、装项目依赖、排障），读目标仓库的工作流判断它需要哪些预装的系统依赖并写成钩子，读本文和 `docs/` 中对应的部分，按顺序执行脚本；上表的操作以及删除主机上的用户和目录（例如迁移前直接跑在主机上的旧 runner）前，先把具体命令和影响告诉人、等到同意。令牌只经管道传，不打印。

## 7. 文档

`README` 和 `docs/` 中英双语（`*.zh-CN.md` 同步）。`docs/`：`design`（本文）、`setup`（从零开始的步骤）、`operations`（日常：加减 runner、换模板、写钩子和常见例子如 Playwright、迁移手工搭的环境）、`troubleshooting`（踩过的坑：networkd 等待、DHCP 同一 IP、FORWARD DROP、Docker Hub 被重置、`ERR_NETWORK_CHANGED`）。

## 8. 验证环境

Debian 13（trixie）主机，Docker 29.9，Incus 6.0.4（Debian 自带的包），QEMU 虚拟机 12 核 11G。验证的是 `NETWORK_PRESET=cn`；`global` 的 `BASE_IMAGE=images` 路径未在该主机上验证。
