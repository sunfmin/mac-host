#!/bin/bash
# 在自己的 home 目录里装一份自己的 Homebrew（~/homebrew），再装需要的软件。给没有 sudo 的标准账号用。
# 用你自己的账号执行（不是 root），怎么执行见本仓库的 README.md。可以重复执行：已装的跳过，Homebrew 本身更新到最新版本。
#
# 机器上没有给员工用的全局 Homebrew：/opt/homebrew 要么没有，要么归管理员，标准账号往里装不了东西；每人用自己的这份。
# 它不在 Homebrew 的默认位置，没有能直接用的预编译包的软件要从源码编译，会慢。
# PATH 不归本脚本管：机器要在 ~/.zshenv 里加载 ~/homebrew/bin/brew（见 README.md「机器要满足的」）。
#
# 下载源官方优先，国内的镜像和加速代理只是候补，国外的机器用不上它们。
#   - Homebrew 本体：只拉最新版本那一个提交，先直连 GitHub 问到它的提交 sha，拉下来核对，代理改不了内容。
#     不用 brew update：它要拉完整历史，国内会卡住（~/homebrew/etc/homebrew/brew.env 里关掉了自动更新）。
#     重新执行本脚本就会更新到最新版本。
#   - 软件包索引和预编译包：官方太慢时用 BOTTLE_MIRRORS，写进 brew.env，之后自己执行 brew 也照它下载。
#   - 第三方 tap 和应用的下载地址在 GitHub 和各个厂商那里，镜像管不到。慢的话自己给这条命令指定代理
#     （https_proxy 等环境变量）；本脚本不会自己去用代理。
#
# 参数（都可以不填）：
#   <包名>          命令行软件，例如 jq
#   cask:<包名>     图形界面应用，装进 ~/Applications，例如 cask:stablyai/orca/orca
#   --upgrade       把已装的软件全部升级
set -Eeuo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
# bash 3.2 在 UTF-8 环境下会把紧跟在 $变量 后面的中文当成变量名的一部分，"$X（" 会报 unbound variable。
# 只让 bash 自己用 C 语言环境（不 export，子进程照旧）；中文照样原样输出。
LC_ALL=C
cd "$HOME"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*"; exit 1; }

# 任何没被 || 接住的命令失败都报出行号和退出码。执行的人只能看输出，
# 没有这一行的话脚本中途退出会完全没有线索。set -E 让函数和子 shell 里也生效。
trap 'rc=$?; printf "[%s] ERROR: 第 %s 行失败，退出码 %s。\n" "$(date "+%H:%M:%S")" "$LINENO" "$rc"; exit "$rc"' ERR
[[ $EUID -ne 0 ]] || die "用你自己的账号执行，不要用 root。"

PREFIX="$HOME/homebrew"
BREW_GIT="https://github.com/Homebrew/brew"
BREW_ENV="$PREFIX/etc/homebrew/brew.env"
LOW_SPEED=102400   # 字节/秒
GH_PROXIES="https://gh-proxy.com/"
BOTTLE_MIRRORS="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles https://mirrors.ustc.edu.cn/homebrew-bottles https://mirrors.bfsu.edu.cn/homebrew-bottles"
[[ -z "${https_proxy:-}" ]] || log "使用你指定的代理：$https_proxy"

FORMULAE=()
CASKS=()
UPGRADE=0
for arg in "$@"; do
  case "$arg" in
    --upgrade) UPGRADE=1 ;;
    --*) die "未知参数：$arg" ;;
    cask:*) CASKS+=("${arg#cask:}") ;;
    *) FORMULAE+=("$arg") ;;
  esac
done

xcode-select -p >/dev/null 2>&1 || die "机器上没有 Xcode Command Line Tools，要管理员装（xcode-select --install），找运维。"

api_ok() {
  curl -fsS -o /dev/null --connect-timeout 10 --speed-limit "$LOW_SPEED" --speed-time 15 --max-time 600 \
    "$1/formula.jws.json" 2>/dev/null
}
brew_run() {
  NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 "$PREFIX/bin/brew" "$@"
}
# 列出装 $1 时要从源码编译的包（它自己和还没装的依赖）。预编译包里写死了 /opt/homebrew 的
# （cellar 不是 :any / :any_skip_relocation），~/homebrew 比它长，只能现编，一编就是几十分钟。
needs_source() {
  local f="$1" tag dep pending=()
  tag="$(brew_run ruby -e 'puts Utils::Bottles.tag.to_sym')"
  for dep in "$f" $(brew_run deps "$f"); do
    brew_run list --formula "$dep" >/dev/null 2>&1 || pending+=("$dep")
  done
  (( ${#pending[@]} )) || return 0
  brew_run info --json=v2 "${pending[@]}" | /usr/bin/jq -r --arg t "$tag" '
    .formulae[] | ((.bottle.stable.files // {}) as $b | ($b[$t] // $b.all // {}).cellar // "none") as $c
    | select($c != ":any" and $c != ":any_skip_relocation") | .name'
}

# ---------------------------------------------------------------------------
log "== 软件包的下载源"
SOURCE=""
if api_ok https://formulae.brew.sh/api; then
  SOURCE=official
  log "官方（formulae.brew.sh、ghcr.io）"
else
  warn "官方源连不上或太慢，试国内镜像。"
  for m in $BOTTLE_MIRRORS; do
    if api_ok "$m/api"; then SOURCE="$m"; log "镜像：$m"; break; fi
    warn "$m 也不行，换下一个。"
  done
  [[ -n "$SOURCE" ]] || die "官方源和所有镜像都连不上或太慢。"
fi
mkdir -p "${BREW_ENV%/*}"
{
  echo "# 由 sunfmin/mac-host 的 skills/mac-host/scripts/homebrew.sh 生成，重新执行会覆盖。"
  echo "# 不自动更新：要从 GitHub 拉完整历史，国内会卡住。重新执行 homebrew.sh 就会更新到最新版本。"
  echo "HOMEBREW_NO_AUTO_UPDATE=1"
  if [[ "$SOURCE" != official ]]; then
    echo "# 官方源太慢，用国内镜像下载软件包索引和预编译包。"
    echo "HOMEBREW_API_DOMAIN=$SOURCE/api"
    echo "HOMEBREW_BOTTLE_DOMAIN=$SOURCE"
  fi
} > "$BREW_ENV"

# ---------------------------------------------------------------------------
log "== Homebrew → $PREFIX"
TAG="$(git ls-remote --tags --refs "$BREW_GIT" 2>/dev/null | awk -F/ '$3 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print $3 }' \
  | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[[ -n "$TAG" ]] || die "问不到 Homebrew 的最新版本（git ls-remote $BREW_GIT 失败）。"
WANT="$(git ls-remote "$BREW_GIT" "refs/tags/$TAG^{}" 2>/dev/null | cut -f1)"
[[ -n "$WANT" ]] || WANT="$(git ls-remote "$BREW_GIT" "refs/tags/$TAG" 2>/dev/null | cut -f1)"
[[ "$WANT" =~ ^[0-9a-f]{40}$ ]] || die "问不到 Homebrew $TAG 的提交 sha。"
git -C "$PREFIX" init -q
GOT=0
for src in "$BREW_GIT" $(for p in $GH_PROXIES; do echo "$p$BREW_GIT"; done); do
  log "拉取 Homebrew $TAG：$src"
  if git -C "$PREFIX" -c http.lowSpeedLimit="$LOW_SPEED" -c http.lowSpeedTime=15 \
       fetch -q --depth=1 "$src" "+refs/tags/$TAG:refs/tags/$TAG" \
     && [[ "$(git -C "$PREFIX" rev-parse "$TAG^{commit}" 2>/dev/null)" == "$WANT" ]]; then
    GOT=1
    break
  fi
  warn "拉取失败、太慢，或者提交和 GitHub 说的不一致，换下一个。"
done
(( GOT )) || die "Homebrew 本体从 GitHub 和所有加速代理都拉不下来。"
log "提交核对一致：$WANT"
git -C "$PREFIX" checkout -q -f -B stable "$TAG"
git -C "$PREFIX" remote add origin "$BREW_GIT" 2>/dev/null || git -C "$PREFIX" remote set-url origin "$BREW_GIT"
log "$(brew_run --version | head -1)"

# ---------------------------------------------------------------------------
FAILED=()
if (( ${#FORMULAE[@]} )); then
  log "== 命令行软件：${FORMULAE[*]}"
  for f in "${FORMULAE[@]}"; do
    if brew_run list --formula "$f" >/dev/null 2>&1; then
      log "  $f 已安装"
      continue
    fi
    src="$(needs_source "$f" | xargs)"
    if [[ -n "$src" ]]; then
      warn "  $f 不装：$src 没有能用在 ~/homebrew 的预编译包，要从源码编译。改用 pixi（见 SKILL.md）：pixi global install $f"
      FAILED+=("$f")
    elif brew_run install --formula "$f"; then
      log "  $f 安装完成"
    else
      FAILED+=("$f")
    fi
  done
fi
if (( ${#CASKS[@]} )); then
  log "== 图形界面应用：${CASKS[*]}"
  mkdir -p "$HOME/Applications"
  for c in "${CASKS[@]}"; do
    if brew_run list --cask "$c" >/dev/null 2>&1; then
      log "  $c 已安装"
    elif brew_run install --cask --appdir="$HOME/Applications" "$c"; then
      log "  $c 安装完成"
    else
      # 用 .pkg 安装的应用要管理员权限，标准账号装不了。
      FAILED+=("cask:$c")
    fi
  done
fi
if (( UPGRADE )); then
  log "== 升级全部软件"
  brew_run upgrade || FAILED+=("(upgrade)")
fi

log "== 已安装"
log "命令行：$(brew_run list --formula -1 | xargs)"
log "应用：$(brew_run list --cask -1 2>/dev/null | xargs)"
if (( ${#FAILED[@]} )); then
  warn "以下安装失败：${FAILED[*]}（用 .pkg 安装的应用要管理员权限，标准账号装不了）"
  exit 1
fi
log "== 完成。新开一个终端，brew 就在 PATH 里。"
