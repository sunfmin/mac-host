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
  denied; or when brew, PATH or a missing command behaves unexpectedly.
---

# 在这台 Mac 上做事

这类机器放在远处，没人看它的桌面，人是通过 SSH（Orca）用它的。员工账号是标准账号：没有 root，没有 sudo，东西都装在本人的 home 目录里。机器上的全局 Homebrew（`/opt/homebrew`）归管理员，员工往里装不了东西。

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
| node、python 这类运行时 | `mise use -g <工具>@<版本>` | mise 的目录 |
| Python 写的命令行工具 | `uv tool install <包>` | `~/.local` |
| npm 全局包 | `npm i -g --prefix ~/.local <包>` | `~/.local` |
| 单个二进制 | 下载并核对 sha，放进 `~/.local/bin` | `~/.local/bin` |

- **brew 只用 `~/homebrew` 这一份。** 先看 `~/homebrew/bin/brew` 在不在：在就直接用，不另装一份；不在就跑本 skill 目录下的 `scripts/homebrew.sh`（不带参数只装 Homebrew 本身），它负责下载源、核对 sha 和 `brew.env`。PATH 由 `~/.zshenv` 的托管段加载，不要再往 shell 配置里加 brew。`~/.homebrew` 不是安装位置，那是 Homebrew 的每用户配置目录。
- **会慢的要先估时。** `~/homebrew` 不在 Homebrew 的默认位置，没有能直接用的预编译包的软件要从源码编译。
- **不往系统目录或别人的 home 里写**，也不为了装东西去找 sudo。遇到 permission denied，换成上表里的路，不要提权。
- 网络慢时，机器上有代理的话（例如 `~/mihomo/proxy.env`），只给那一条命令用：`(. ~/mihomo/proxy.env; <命令>)`。脚本和 shell 配置都不会自动挂上代理。

## 给人看东西

这台机器的桌面和剪贴板都不是人手边的那个：

- **看文件**（图片、页面、文档……）：用 `orca file open <绝对路径> --focus`，它会在人的 Orca 里打开一个标签页。多个文件时，前面几个不带 `--focus` 逐个打开，最后对要先看的那个带 `--focus`。不要用这台机器的桌面程序打开（`open`、`qlmanage`、Preview、Safari、Finder……），没人看得到。
- **要人拿去别处发的文本**：在回复里给出全文。`pbcopy` 放进的是这台机器的剪贴板，人那边拿不到，不要用它代替全文。
