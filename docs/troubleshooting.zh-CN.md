[English](troubleshooting.md)

# 故障排查

先执行 `sudo bin/doctor`：每个 `FAIL` 都附带修复办法。进容器看：`sudo incus exec <前缀>-N -- bash`；runner 自己的日志在 `/home/runner/actions-runner/_diag/`，服务的日志用 `journalctl -u 'actions.runner.*'`。

## 容器拿不到 IPv4 地址，或新容器一直不就绪

**`build-template` 或 `add-runner` 停在 "did not get a working network within 3 minutes"。**

- 手工做的镜像缺 `udev`：systemd-networkd 一直等网卡设备，永远不发 DHCP。`build-template` 用 mmdebstrap 建的镜像带 `udev`。
- 所有副本拿到**同一个**地址：模板的 `/etc/machine-id` 没有清空，所有副本发出的 DHCP 客户端 ID 相同。`build-template` 封装时会清空；`doctor` 会报告重复。用 `build-template` 建的模板重建受影响的 runner。
- 有地址但出不了网：见下一节。

## 容器有地址但上不了网（主机跑着 Docker）

Docker 把 `FORWARD` 链的默认策略设为 DROP，`incusbr0` 到出口网卡的流量也被丢掉。`prepare-host` 安装的 `incus-docker-forward.service` 在 Docker 的 `DOCKER-USER` 链里只放行 `incusbr0 → 出口网卡` 和回包。检查：

```bash
sudo iptables -S DOCKER-USER
sudo systemctl status incus-docker-forward.service
```

规则没了（比如有东西清空了这条链）就重启这个服务。出口网卡不是默认路由那块时，设置 `UPLINK_IF`，删掉单元文件后重新执行 `prepare-host`。不要按 Incus 的提示放开全部转发：那样主机上的 Docker 网络也一起被放开了。

## 从 images.linuxcontainers.org 下载失败（国内）

国内下载常被重置。用 `BASE_IMAGE=mmdebstrap`（`NETWORK_PRESET=cn` 已包含）：系统镜像在主机上从 `DEBIAN_MIRROR` 构建。

## 容器里拉 Docker Hub 镜像失败（国内）

国内连接 Docker Hub 常被重置，新容器第一次需要某个镜像时任务就会失败。`HUB_MIRROR=on` 时，各容器的 dockerd 先问主机上的缓存，每个镜像只从 Docker Hub 拉一次（缓存会重试，被重置只是慢一点）。在容器里检查：

```bash
sudo incus exec ci-1 -- curl -fsS http://10.1.231.1:5000/v2/   # 网桥地址
sudo incus exec ci-1 -- docker info --format '{{.RegistryConfig.Mirrors}}'
```

缓存只管 Docker Hub。其他仓库（ghcr.io、quay.io）的镜像直接拉。

## Chromium 报 `net::ERR_NETWORK_CHANGED`

这是多个 runner 共用一个网络命名空间、别的任务增删 Docker 网络时出现的。这些容器之间不会发生（各自有自己的命名空间）；如果看到它，说明任务跑在了容器以外的 runner 上。看任务日志里的 runner 名字。

## e2e 报缺少共享库

浏览器的系统库由钩子按其中写的 Playwright 版本安装。项目升级 Playwright 后，改钩子里的版本，执行 `sudo bin/apply-hooks --all`。

## 任务需要 `sudo`

`runner` 用户故意没有 sudo。用钩子以 root 装好任务需要的东西，把工作流里的 `sudo` 步骤（或 `--with-deps`）去掉。

## runner 在 GitHub 上显示离线

- `sudo bin/status`：容器在运行吗？服务是 `active` 吗？
- 主机重启而 `boot.autostart` 是关的：`sudo incus start <前缀>-N`。
- 注册在 GitHub 上被删了（或者 runner 离线 14 天被 GitHub 清掉）：`svc.sh uninstall` 后删掉 `/home/runner/actions-runner` 里的 `.runner`、`.credentials`、`.credentials_rsaparams`，或者直接重建这个 runner（`remove-runner` 再 `add-runner`）。

## 任务被强制中止后的残留

runner 在任务中途被杀掉（主机断电）时，`if: always()` 的清理步骤来不及执行。进那个容器（`docker ps -a`、`docker volume ls`）删掉任务留下的东西。每个容器的磁盘占用见 `status`。

## `build-template` 说模板存在但不是本脚本建的

现有的 `<前缀>-tpl` 没有完成标记：它是手工建的，或者上次构建中断了。只有加 `--rebuild --yes` 才会替换它。
