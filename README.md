# mac-host

给 agent 用的 skill：在一台**多人共用的远程 Mac** 上用**标准账号**（没有 sudo）做事。机器放在远处，没人看它的桌面，人通过 SSH（[Orca](https://onorca.dev)）用它。

skill 本身在 [`skills/mac-host/SKILL.md`](skills/mac-host/SKILL.md)，讲三件事：先判断账号类型；东西装到哪（每种东西只有一条路）；怎么把文件和文本给人看（不用这台机器的桌面和剪贴板）。

## 安装

```sh
npx skills add sunfmin/mac-host -g
```

skill 目录里带着三个脚本，装 skill 时一起装上，人和 agent 都在机器上直接执行（见「怎么执行」）：

| 脚本 | 用途 |
| --- | --- |
| `scripts/homebrew.sh` | 自己的 Homebrew，装命令行软件和应用 |
| `scripts/mihomo.sh` | 国内网络用：自己的代理 |
| `scripts/orca-server.sh` | 电脑关着时手机也能用 Orca：给电脑和手机配对常驻的 Orca 服务端 |

## 机器要满足的

skill 和脚本假定机器已经由管理员配好以下几点，它们自己不做：

- 员工账号是标准账号，home 目录归本人。
- `~/.zshenv` 里加载这几项 PATH（Orca 经 SSH 起的进程不一定是登录 shell，非交互的 zsh 只读 `.zshenv`）：

  ```sh
  [ -x "$HOME/homebrew/bin/brew" ] && eval "$("$HOME/homebrew/bin/brew" shellenv)"
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  export PATH="$PATH:$HOME/.pixi/bin"   # brew 要从源码编的命令行软件走 pixi（见 SKILL.md）
  ```
- 装了 Xcode Command Line Tools。
- `~/.zshenv` 里 `export DEV_PORT_BASE=<数字>`：本人的端口段起点，每人 100 个，互不重叠。`mihomo.sh` 用最后两个（`+98` 代理，`+99` 控制接口），常驻的 Orca 服务端用 `+97`。
- 用 `orca-server.sh` 的，还要：
  - 管理员给本人装好常驻的 Orca 服务端：LaunchDaemon `orca-studio.orca-server.<用户>`，以本人身份运行
    `~/Applications/Orca.app` 里的 `orca serve --supervise --no-pairing --port $DEV_PORT_BASE+97 --pairing-address <Tailscale IP>`，
    环境变量 `ORCA_SERVE_RUNTIME=orcad`（mac-studio-setup 的 `ssh/root/35-orca-server.sh` 就是做这个的）。
  - Tailscale ACL 让本人的设备连得到这台机器的 `$DEV_PORT_BASE+97`。
  - 应用防火墙自动放行有开发者签名的程序（`socketfilterfw --setallowsigned on --setallowsignedapp on`）：监听端口的是 Orca 自带的 node，有签名。

## 怎么执行

在机器上，用本人账号：

```sh
bash ~/.claude/skills/mac-host/scripts/homebrew.sh jq cask:visual-studio-code
```

（只给 Claude Code 装时 skill 在 `~/.claude/skills`；同时给几个 harness 装时实体在 `~/.agents/skills`，`~/.claude/skills` 是指过去的链接，上面这条两种都能用。）

从自己电脑上替某人执行（脚本从 GitHub 取、从标准输入传过去，机器上不用装 skill）：

```sh
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/sunfmin/mac-host/contents/skills/mac-host/scripts/homebrew.sh \
  | ssh <用户>@<机器> '/bin/bash -c "$(cat)" _ jq; echo "退出码：$?"'
```

- 换成别的脚本，改 URL 最后的文件名。从 `api.github.com` 取，不从 `raw.githubusercontent.com`：2026-11 在国内，前者 1.3 秒，后者 20 秒无响应。
- 用 `bash -c "$(cat)"`，不要用 `bash -s`：`bash -s` 边读边执行，脚本里哪条命令读了标准输入，就会把后面的脚本当成输入吃掉（2026-11 实测）。
- 参数写在 `_` 后面，用空格分隔。
- 成败看最后一行「退出码」：2026-11 实测 Tailscale SSH 回给 `ssh` 的退出码总是 0。
- 要走代理（`mihomo.sh` 装的），在前面加载它，只影响这一条：`ssh <用户>@<机器> '. ~/mihomo/proxy.env; /bin/bash -c "$(cat)" _; echo "退出码：$?"'`。

## 自己的 Homebrew（`scripts/homebrew.sh`）

机器上没有给员工用的全局 Homebrew：`/opt/homebrew` 要么没有，要么归管理员，员工往里装不了东西。每人在 `~/homebrew` 装一份自己的。

### 参数和行为

- **参数**：`<包名>` 装命令行软件；`cask:<包名>` 装图形界面应用，放进 `~/Applications`；`--upgrade` 升级全部。不带参数只装或刷新 Homebrew 本身。可以重复执行。
- **不在默认位置**：Homebrew 会提示 `prefix is not /opt/homebrew`。能挪位置的预编译包照样直接装（2026-11 实测 jq 和它依赖的 oniguruma 都是）；不能挪的要从源码编译，会慢。
- **下载源，官方优先**：软件包索引和预编译包，官方低于 100KB/s 持续 15 秒才换清华、中科大、北外的镜像，选中的写进 `~/homebrew/etc/homebrew/brew.env`，之后自己执行 brew 也照它下载。镜像改不了包的内容：索引有 Homebrew 的签名，预编译包的 sha256 在索引里。
- **Homebrew 本体**：只拉最新版本的那一个提交。先直连 GitHub 问到它的提交 sha，再从 GitHub 拉，慢就换 gh-proxy.com，拉下来核对 sha。
- **不用 `brew update`**：它要拉完整历史，2026-11 国内走代理 300 秒都没拉完。`brew.env` 里关掉了自动更新；重新执行脚本就更新到最新版本。
- **代理只在你指定时用**：第三方 tap 和应用的下载地址在 GitHub 和各个厂商那里，镜像管不到；慢的话给这条命令设 `https_proxy` 等环境变量。脚本不会自己去找代理。
- **用 `.pkg` 安装的 cask 装不上**：要管理员权限，员工是标准账号。

2026-11 在 Mac Mini 上不走代理装 jq，共 118 秒：官方源 25 秒判定太慢，换清华；向 GitHub 问版本和 sha 51 秒；本体直连 24 秒放弃，gh-proxy 6 秒；装 jq 10 秒。

## 代理（`scripts/mihomo.sh`）

国内网络直连 GitHub、Anthropic 等很慢或连不上。`mihomo.sh` 在本人的账号里装一个 mihomo（Clash Meta 内核），用订阅地址拿节点。国外的机器用不上它。

```sh
bash ~/.claude/skills/mac-host/scripts/mihomo.sh --subscription <订阅地址>   # 第一次
bash ~/.claude/skills/mac-host/scripts/mihomo.sh                            # 机器重启后、变慢了
```

机器上还没有这个 skill 时（国内的新账号，装 skill 本身就要代理），从自己电脑上执行，见「怎么执行」。

- **要用时自己指定**：脚本和 shell 配置都不会自动用它。代理的环境变量（`http_proxy`、`https_proxy`、`no_proxy` 及大写版本）只写在 `~/mihomo/proxy.env`。在终端里执行 `. ~/mihomo/proxy.env`，只影响这个终端；单条命令写成 `(. ~/mihomo/proxy.env; git clone …)`。
- **只开代理端口，不开 TUN**：只在 127.0.0.1 上监听 `$DEV_PORT_BASE+98`（HTTP 和 SOCKS5），不改路由，所以不影响 Tailscale。`+99` 是控制接口。
- **后台运行**：LaunchAgent 在本人的 `user/<UID>` 域里，SSH 断开后照样在跑。**机器重启后不会自己起来**：SSH 登录不会加载这类 LaunchAgent。要用时重新执行一次（不带参数）。两点都是 2026-11 在 Mac Mini 上实测的。
- **订阅地址等同于密码**：会出现在执行者的 shell 历史里；机器上只存在本人能读的 `~/mihomo/subscription.url`。以后重新执行不带 `--subscription` 就用它，顺便更新节点和 mihomo 版本。
- **mihomo 本身从哪里下**：只在 GitHub 发布，国内没有官方镜像。脚本从 GitHub API 拿版本号和官方 sha256，先直连 GitHub，低于 100KB/s 持续 15 秒才换 gh-proxy.com，sha256 对不上的一律丢掉。2026-11 在 Mac Mini 上：直连太慢，换 gh-proxy 后 38 秒下完，整个脚本 116 秒。
- **选节点看下载速度，不看延迟**：订阅里 Anthropic 的流量走 `💡AI` 分组，默认跟着 `🪜Proxy` → `🎏Auto`；`🎏Auto` 只挑延迟最低的，不看速度。2026-11-03 在 Mac Mini 上，它挑的节点下载 Claude Code 只有 180KB/s（313MB 要半小时），同一订阅里别的节点有 4MB/s，也有完全下不动的。所以每次执行都量一下现在的节点：经代理同时下载 Claude Code 的程序和 GitHub 上的发布文件各 4MB，都不低于 1MB/s 才算够快，够快就不动。不够就把 `🪜Proxy` 的节点同时量一遍，换成最快的（按两样里慢的那样排），再单独量它一次。同时量要另起一个测速用的 mihomo，借用代理的端口，所以这十几秒代理是停的；同时下载会分走本机带宽，量到的数只用来排先后。2026-11-06 在 Studio64 上，同一份订阅 18 个节点：从一个下不动的节点开始，选节点 23 秒（其中同时量 10 秒；原来按顺序一个个试要 131 秒）；现在的节点够快时 3 秒。选择存在 `~/mihomo/cache.db`。分组名是那份订阅的，订阅里没有 `🪜Proxy` 时只警告、不选。
- **AI 节点不能用香港的**：Anthropic 不服务香港，节点在香港时 `api.anthropic.com` 返回 403 `Request not allowed`，Claude Code 用不了；这样的节点下载 Claude Code 也会失败，选节点时不会选它。自己手动换过节点的，脚本最后的访问测试会提示。2026-11 在 Mac Mini 上实测：香港节点 403，换到日本节点后可用。
- **手动切换节点**：用控制接口选，选择存在 `~/mihomo/cache.db`，重启和重新执行后照旧（重新执行时太慢还是会换掉）。分组名和节点名以订阅为准：

  ```sh
  C="127.0.0.1:$((DEV_PORT_BASE + 99))"; S="$(cat ~/mihomo/controller.secret)"
  G="$(jq -rn '"🪜Proxy"|@uri')"
  curl -s -H "Authorization: Bearer $S" "http://$C/proxies/$G" | jq -r '.now, "--", .all[]'   # 当前的和可选的
  curl -X PUT -H "Authorization: Bearer $S" -d '{"name":"✨🇯🇵JP-06"}' "http://$C/proxies/$G"
  ```
- **卸载**：`mihomo.sh --uninstall`。

## 电脑关着时手机也能用（`scripts/orca-server.sh`）

默认做法里，自己电脑上的 Orca 通过 SSH 驱动这台机器，手机配对的也是电脑上的 Orca，所以电脑一关手机就用不了。
要让手机直接连这台机器，每人在这台机器上常驻一个自己的 Orca 服务端，作为 [Remote Orca Server](https://onorca.dev/docs/remote-servers)，电脑和手机都连它。

```
自己的电脑（Orca 客户端）──┐
                          ├─Tailscale─▶ 这台机器：以 alice 身份常驻的 orca serve（alice 端口段的 +97）
自己的手机（Orca Mobile）──┘
```

服务端由管理员装，本人只配对。2026-11-10 在 Mac Mini 上实测（Orca 1.4.255）：

- Orca 走 SSH 目标时在这台机器上起的服务端只监听 127.0.0.1，电脑断开 15 分钟后自己退出，也不提供手机配对。
- `orca serve` 在 macOS 上默认跑 Electron，要有人登录桌面。加 `ORCA_SERVE_RUNTIME=orcad` 改跑纯 Node 的服务端，SSH 里、没人登录桌面也能起来，5 秒就绪，终端在服务端重启后还在。
- 本人装不了不依赖桌面的常驻服务：`orca serve service install` 装进 `gui/<UID>`，没登录桌面时报 125；本人 `launchctl bootstrap user/<UID>` 报 5。它生成的配置里也没有 `ORCA_SERVE_RUNTIME=orcad`。所以由管理员装一个 LaunchDaemon，以本人身份运行，开机就起（见「机器要满足的」）。
- 服务端监听 0.0.0.0（手机配对要这样），默认只接受本机、局域网和 Tailscale 来的连接，每台设备有自己的令牌。

`orca-server.sh` 用 `orca pair` 向正在运行的服务端要配对，不重启它，已经连着的设备不受影响：

- 不带参数：打出给电脑用的 Access Link，在自己电脑的 Orca 里 Settings → Remote Orca Servers → Add Server 粘贴。
- `--pair-mobile`：打出二维码，用 Orca Mobile 扫，手机要先连上 Tailscale。
- `--rotate`：作废还没用过的配对码、换一个新的。没用过的配对码会一直有效，直到换掉。
- 配对码等同于登录凭据，只打在执行者的终端里。
- 本脚本旧版本装的 LaunchAgent（登录桌面时打开桌面版 Orca）会被删掉：桌面版开着时，常驻的服务端会一直等它退出。

限制：

- 用 SSH 目标建的 worktree 仍归电脑上的 Orca 管，电脑关了手机看不到；要手机能用，在 Remote Orca Server 下建。
- **升级 Orca**：Orca 装在本人的 `~/Applications`，orcad 没有应用内更新。本人执行 `~/homebrew/bin/brew upgrade --cask stablyai/orca/orca`（2026-11-10 实测 1.4.249 → 1.4.255），再请管理员重新执行 35-orca-server.sh 让服务端换到新版。`homebrew.sh --upgrade` 会不会升级它没实测。服务端和电脑上的 Orca 版本差太多会连不上。
