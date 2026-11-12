---
name: mac-host
description: >-
  How to work on a shared remote Mac: a machine nobody
  watches, reached over SSH (files are shown through Orca, the clipboard is not
  the user's), and a standard (non-admin) account with no sudo, its own Homebrew
  in ~/homebrew, mise for runtimes, ~/.local for the rest. Use before showing
  the user a file, image or page, or putting text on the clipboard; before
  installing any tool, package, runtime or app; before any sudo; when a write to
  /opt/homebrew, /usr/local or another system directory fails with permission
  denied; when brew, PATH or a missing command behaves unexpectedly; or when
  the user wants their own proxy for a slow network, or Orca on their phone
  while their computer is off.
---

# 在这台 Mac 上做事

这类机器放在远处，没人看它的桌面，人是通过 SSH（Orca）用它的。员工账号是标准账号：没有 root，没有 sudo，东西都装在本人的 home 目录里。机器上没有给员工用的全局 Homebrew：`/opt/homebrew` 要么没有，要么归管理员，员工往里装不了东西。

## 先判断是哪种账号

```sh
dseditgroup -o checkmember -m "$(id -un)" admin
```

- 回答 `NOT a member`：**标准账号**，照下面「标准账号」做。多人共用机器上的员工账号都是这种。
- 回答 `is a member`：admin。只有 `~/.local/bin/askpass` 存在时才用 sudo，而且每条都写成 `SUDO_ASKPASS=$HOME/.local/bin/askpass sudo -A <命令>`（没有 tty）。它会弹窗让人逐条批准；被拒就当失败，不重试。askpass 不存在时，照标准账号的做法装在 home 里。

## 标准账号

装到哪，按东西的种类选，每种只有一条路：

| 要装的 | 怎么装 | 装到哪 |
| --- | --- | --- |
| brew 的命令行软件、cask 应用 | `bash <本 skill 目录>/scripts/homebrew.sh <包名> cask:<包名>` | `~/homebrew`，应用进 `~/Applications` |
| brew 要从源码编译的命令行软件（`homebrew.sh` 拒装并指过来的） | `pixi global install <包>=<版本>`（conda-forge） | `~/.pixi` |
| node、python 这类运行时 | `mise use -g <工具>@<版本>` | mise 的目录 |
| Python 写的命令行工具 | `uv tool install <包>` | `~/.local` |
| npm 全局包 | `npm i -g --prefix ~/.local <包>` | `~/.local` |
| 单个二进制 | 下载并核对 sha，放进 `~/.local/bin` | `~/.local/bin` |

- **brew 只用 `~/homebrew` 这一份。** 先看 `~/homebrew/bin/brew` 在不在：在就直接用，不另装一份；不在就跑本 skill 目录下的 `scripts/homebrew.sh`（不带参数只装 Homebrew 本身），它负责下载源、核对 sha 和 `brew.env`。PATH 由 `~/.zshenv` 的托管段加载，不要再往 shell 配置里加 brew。`~/.homebrew` 不是安装位置，那是 Homebrew 的每用户配置目录。
- **brew 不从源码编。** 很多预编译包写死了 `/opt/homebrew`（13 个字符），只能原地改成不长于它的路径；`~/homebrew` 更长，这些包（postgresql、gettext、krb5……）brew 会退回源码编译，一编几十分钟。`homebrew.sh` 装之前先查，要编的就拒装，提示改用 pixi。conda-forge 的包用超长占位路径打包，装到哪都能直接用；它没有 GUI 应用和闭源软件，那些仍走 cask。
- **pixi**：`~/.pixi/bin/pixi` 不在就从 GitHub release 下载 `pixi-aarch64-apple-darwin.tar.gz`（钉版本，核对同目录的 `.sha256`），解开放进 `~/.pixi/bin`；PATH 由 `~/.zshenv` 里 `export PATH="$PATH:$HOME/.pixi/bin"` 那行加载。装完缺的命令（例如 `pg_config`）用 `pixi global expose add --environment <环境> <命令>=<命令>` 补。
- **会慢的要先估时。**
- **不往系统目录或别人的 home 里写**，也不为了装东西去找 sudo。遇到 permission denied，换成上表里的路，不要提权。
- 网络慢时，机器上有代理的话（例如 `~/mihomo/proxy.env`），只给那一条命令用：`(. ~/mihomo/proxy.env; <命令>)`。脚本和 shell 配置都不会自动挂上代理。

## 代理和手机用 Orca

本 skill 目录下还有两个脚本，人要的时候执行。参数和行为写在各自开头的注释里，先读再执行：

- `scripts/mihomo.sh`：本人自己的代理（mihomo），国内网络用。第一次要人给订阅地址（`--subscription <地址>`，它等同于密码，不要回显）；机器重启后代理不会自己起来，下载变慢时也是，都不带参数重新执行，它会重新选一个下载够快的节点。
- `scripts/orca-server.sh`：让人的手机在电脑关着时也能用 Orca。本人 SSH 里执行就行（不用 root、不用桌面）：它常驻本人的 Orca 服务端，不带参数打出给电脑的 Access Link，`--pair-mobile` 打出手机扫的二维码。配对码等同于密码，只让人在自己的终端里执行、自己看，不要读出来或转贴。报「系统级 Orca 服务端」时，转告人找管理员执行 mac-studio-setup 的 `ssh/root/35-orca-server.sh`。

## 给人看东西

这台机器的桌面和剪贴板都不是人手边的那个：

- **看文件**（图片、页面、文档……）：用 `orca file open <绝对路径> --focus`，它会在人的 Orca 里打开一个标签页。路径要在某个 Orca worktree 里面；临时目录（`/tmp`、`$TMPDIR`）里的文件先复制到当前 repo 里被 git 忽略的目录再打开。多个文件时，前面几个不带 `--focus` 逐个打开，最后对要先看的那个带 `--focus`。不要用这台机器的桌面程序打开（`open`、`qlmanage`、Preview、Safari、Finder……），没人看得到。
- **看 HTML 页面**：文件标签页显示不正常（看到的是源码，或者 CDN 脚本、图表没跑起来）时，在这台机器上起一个只监听本机的静态服务器，再用 Orca 的内置浏览器打开它：
  - `uv run --no-project python -m http.server <端口> --bind 127.0.0.1`，在页面所在目录后台跑；
  - `orca tab create --url http://127.0.0.1:<端口>/<文件名>`。Orca 的内置浏览器能访问这台机器的 `127.0.0.1`，不用监听公网或 tailnet 地址；
  - 确认渲染出来了：`orca eval --expression 'document.title'` 返回页面标题。用完把服务器停掉。
- **要人拿去别处发的文本**：在回复里给出全文。`pbcopy` 放进的是这台机器的剪贴板，人那边拿不到，不要用它代替全文。
