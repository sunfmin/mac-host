# mac-host

给 agent 用的 skill：在一台**多人共用的远程 Mac** 上用**标准账号**（没有 sudo）做事。机器放在远处，没人看它的桌面，人通过 SSH（[Orca](https://onorca.dev)）用它。

skill 本身在 [`skills/mac-host/SKILL.md`](skills/mac-host/SKILL.md)，讲三件事：先判断账号类型；东西装到哪（每种东西只有一条路）；怎么把文件和文本给人看（不用这台机器的桌面和剪贴板）。

## 安装

```sh
npx skills add sunfmin/mac-host -g
```

skill 目录里带着 `scripts/homebrew.sh`，装 skill 时一起装上，agent 在机器上直接执行它。

## 机器要满足的

skill 和脚本假定机器已经由管理员配好以下几点，它们自己不做：

- 员工账号是标准账号，home 目录归本人。
- `~/.zshenv` 里加载这几项 PATH（Orca 经 SSH 起的进程不一定是登录 shell，非交互的 zsh 只读 `.zshenv`）：

  ```sh
  [ -x "$HOME/homebrew/bin/brew" ] && eval "$("$HOME/homebrew/bin/brew" shellenv)"
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  ```
- 装了 Xcode Command Line Tools。

## 自己的 Homebrew（`scripts/homebrew.sh`）

机器上的全局 Homebrew（`/opt/homebrew`）归管理员，员工往里装不了东西。每人在 `~/homebrew` 装一份自己的。

### 怎么执行

在机器上，用本人账号：

```sh
bash ~/.agents/skills/mac-host/scripts/homebrew.sh jq cask:visual-studio-code
```

从自己电脑上替某人执行（脚本从标准输入传过去，机器上不用装 skill）：

```sh
curl -fsSL https://raw.githubusercontent.com/sunfmin/mac-host/main/skills/mac-host/scripts/homebrew.sh \
  | ssh <用户>@<机器> '/bin/bash -c "$(cat)" _ jq; echo "退出码：$?"'
```

- 用 `bash -c "$(cat)"`，不要用 `bash -s`：`bash -s` 边读边执行，脚本里哪条命令读了标准输入，就会把后面的脚本当成输入吃掉（2026-11 实测）。
- 参数写在 `_` 后面，用空格分隔。
- 成败看最后一行「退出码」：2026-11 实测 Tailscale SSH 回给 `ssh` 的退出码总是 0。

### 参数和行为

- **参数**：`<包名>` 装命令行软件；`cask:<包名>` 装图形界面应用，放进 `~/Applications`；`--upgrade` 升级全部。不带参数只装或刷新 Homebrew 本身。可以重复执行。
- **不在默认位置**：Homebrew 会提示 `prefix is not /opt/homebrew`。能挪位置的预编译包照样直接装（2026-11 实测 jq 和它依赖的 oniguruma 都是）；不能挪的要从源码编译，会慢。
- **下载源，官方优先**：软件包索引和预编译包，官方低于 100KB/s 持续 15 秒才换清华、中科大、北外的镜像，选中的写进 `~/homebrew/etc/homebrew/brew.env`，之后自己执行 brew 也照它下载。镜像改不了包的内容：索引有 Homebrew 的签名，预编译包的 sha256 在索引里。
- **Homebrew 本体**：只拉最新版本的那一个提交。先直连 GitHub 问到它的提交 sha，再从 GitHub 拉，慢就换 gh-proxy.com，拉下来核对 sha。
- **不用 `brew update`**：它要拉完整历史，2026-11 国内走代理 300 秒都没拉完。`brew.env` 里关掉了自动更新；重新执行脚本就更新到最新版本。
- **代理只在你指定时用**：第三方 tap 和应用的下载地址在 GitHub 和各个厂商那里，镜像管不到；慢的话给这条命令设 `https_proxy` 等环境变量。脚本不会自己去找代理。
- **用 `.pkg` 安装的 cask 装不上**：要管理员权限，员工是标准账号。

2026-11 在 Mac Mini 上不走代理装 jq，共 118 秒：官方源 25 秒判定太慢，换清华；向 GitHub 问版本和 sha 51 秒；本体直连 24 秒放弃，gh-proxy 6 秒；装 jq 10 秒。
