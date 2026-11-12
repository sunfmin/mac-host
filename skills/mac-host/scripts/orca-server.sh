#!/bin/bash
# 【ssh 本人】电脑关着时手机也能用 Orca：在这台机器上常驻你自己的 Orca 服务端，再给电脑和手机配对。
# 用你自己的账号执行（SSH 登录就行，不用登录桌面），命令见 mac-host 的 README「电脑关着时手机也能用」。可以重复执行。
# 需要先有自己的 Homebrew（同目录的 homebrew.sh）；机器要满足的见 mac-host 的 README。
#
# 参数：
#   （不带）        确保服务端在跑，打出给电脑用的 Access Link（电脑上 Orca：Settings → Remote Orca Servers → Add Server）
#   --pair-mobile   确保服务端在跑，打出手机扫的二维码（Orca Mobile；手机要先连上 Tailscale）
#   --rotate        作废还没用过的配对码、换一个新的（已经配对的设备不受影响）；可以和上面两种一起用
#   --port <n>      指定端口（默认你端口段的 $DEV_PORT_BASE+97）。指定过的记在服务配置里，以后不带它也沿用
#   --off           停掉并删除服务端（Orca 本身不卸载，配对记录保留）
# 配对码等同于登录凭据：只打在你的终端里，不要贴给别人。
#
# 服务端是一个 LaunchAgent，跑在你自己的 launchd 后台域（user/<UID>，会话类型 Background）里，
# 不在系统域、也不在桌面会话里（2026-11-12 在 Mac Mini 和 Mac Studio 上实测）：
#   - SSH 断开后照常运行；不用登录桌面。
#   - 它起的终端和 agent 也在你的后台域里，能读你的钥匙串（mytokens）：前提和 SSH 里一样，
#     这台机器开机后有人登录过一次桌面，否则钥匙串报 locked。放在系统域（root 装的 LaunchDaemon）的话，
#     钥匙串永远读不到（-25291 No keychain is available）。
#   - `orca serve` 在 macOS 上默认跑 Electron，要有桌面。ORCA_SERVE_RUNTIME=orcad 改跑纯 Node 的服务端。
#   - LaunchAgent 要写明 LimitLoadToSessionType=Background，本人才能 launchctl bootstrap user/<UID>
#     （不写报 5）。`orca serve service install` 装进 gui/<UID>，没登录桌面时报 125，所以不用它。
set -Eeuo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
# bash 3.2 在 UTF-8 环境下会把紧跟在 $变量 后面的中文当成变量名的一部分，"$X（" 会报 unbound variable。
# 只让 bash 自己用 C 语言环境（不 export，子进程照旧）；中文照样原样输出。
LC_ALL=C
cd "$HOME"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*"; exit 1; }

trap 'rc=$?; printf "[%s] ERROR: 第 %s 行失败，退出码 %s。\n" "$(date "+%H:%M:%S")" "$LINENO" "$rc"; exit "$rc"' ERR
[[ $EUID -ne 0 ]] || die "用你自己的账号执行，不要用 root。"

# 必须写全名，裸的 orca 是另一个无关的 cask。
ORCA_CASK="stablyai/orca/orca"
LABEL="orca-studio.orca-server"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="user/$(id -u)"
LOG_FILE="$HOME/Library/Logs/Orca/orca-server.log"
BREW="$HOME/homebrew/bin/brew"
# 管理员以前装的系统级服务（mac-studio-setup 的 ssh/root/35-orca-server.sh 旧版本）。它在系统域，读不到钥匙串，
# 而且和这里的服务端抢同一份配置。本人删不掉，要管理员执行 35-orca-server.sh 换过来。
OLD_DAEMON_LABEL="orca-studio.orca-server.$USER"
OLD_DAEMON="/Library/LaunchDaemons/$OLD_DAEMON_LABEL.plist"

OFF=0
PORT_ARG=""
PAIR_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --off) OFF=1; shift ;;
    --pair-mobile) PAIR_ARGS+=(--mobile); shift ;;
    --rotate) PAIR_ARGS+=(--rotate); shift ;;
    --port) PORT_ARG="${2:?--port 需要一个值}"; shift 2 ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ -z "$PORT_ARG" || "$PORT_ARG" =~ ^[0-9]+$ && "$PORT_ARG" -ge 1024 && "$PORT_ARG" -le 65535 ]] \
  || die "--port 要是 1024-65535 的数字：$PORT_ARG"

stop_agent() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  # 本脚本更早的版本把同名 LaunchAgent 装在桌面会话里（登录桌面时打开桌面版 Orca）。
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  # bootout 是异步的，紧接着 bootstrap 偶尔报 5：等旧的退干净。
  local i
  for (( i = 0; i < 30; i++ )); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
    sleep 1
  done
}

if (( OFF )); then
  stop_agent
  rm -f "$AGENT"
  log "已停掉并删除你的 Orca 服务端（Orca 和配对记录都还在，不带 --off 重新执行即可恢复）。"
  exit 0
fi

if launchctl print "system/$OLD_DAEMON_LABEL" >/dev/null 2>&1 || [[ -f "$OLD_DAEMON" ]]; then
  die "这台机器上还有管理员以前给你装的系统级 Orca 服务端（$OLD_DAEMON），它读不到钥匙串，要换掉：
  请管理员执行 mac-studio-setup 的 ssh/root/35-orca-server.sh $USER（端口不变，会顺带执行本脚本）。"
fi

# 端口：--port 指定的优先，其次沿用服务配置里的，都没有才用本人端口段的 +97（每人不同，不用找空闲的）。
# 已经配对过的电脑和手机记着端口，所以要沿用。+98、+99 是同目录 mihomo.sh 的代理和控制接口。
config_port() {
  plutil -extract ProgramArguments xml1 -o - "$1" 2>/dev/null \
    | awk '/<string>--port<\/string>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit }' || true
}
OLD_PORT="$(config_port "$AGENT")"
if [[ -n "$PORT_ARG" ]]; then
  PORT="$PORT_ARG"; PORT_WHY="--port 指定"
elif [[ -n "$OLD_PORT" ]]; then
  PORT="$OLD_PORT"; PORT_WHY="沿用服务配置里的"
else
  [[ -n "${DEV_PORT_BASE:-}" ]] || die "没有 \$DEV_PORT_BASE（管理员建账号时写进 ~/.zshenv）：请管理员补上，或用 --port 指定。"
  PORT=$(( DEV_PORT_BASE + 97 )); PORT_WHY="端口段 $DEV_PORT_BASE 起的 +97"
fi

# Orca 的 tap 和安装包在 GitHub 上，镜像管不到。国内直连慢的话自己指定代理（同目录的 mihomo.sh 装的，
# 用法见 mac-host 的 README「代理」）；本脚本不会自己去用代理。
[[ -z "${https_proxy:-}" ]] || log "使用你指定的代理：$https_proxy"

# ---------------------------------------------------------------------------
log "== Orca"
ORCA_APP=""
for a in "$HOME/Applications/Orca.app" /Applications/Orca.app; do
  if [[ -x "$a/Contents/Resources/bin/orca" ]]; then ORCA_APP="$a"; break; fi
done
# orcad 和 orca pair 是 1.4.255 才有的（2026-11-10 实测 1.4.249 还没有 pair 命令）。
if [[ -z "$ORCA_APP" ]] || ! "$ORCA_APP/Contents/Resources/bin/orca" pair --help >/dev/null 2>&1; then
  [[ -x "$BREW" ]] || die "还没有你自己的 Homebrew：先执行同目录的 homebrew.sh（不带参数），见 mac-host 的 README「自己的 Homebrew」。"
  mkdir -p "$HOME/Applications"
  if NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 "$BREW" list --cask "$ORCA_CASK" >/dev/null 2>&1; then
    log "你装的 Orca 太旧（没有 orca pair），升级"
    NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 \
      "$BREW" upgrade --cask "$ORCA_CASK" || die "升级 Orca 失败，见上面的输出。"
  else
    log "装进 ~/Applications（/Applications 里的归别人，太旧也不动它）"
    NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 \
      "$BREW" install --cask --appdir="$HOME/Applications" "$ORCA_CASK" || die "安装 Orca 失败，见上面的输出。"
  fi
  ORCA_APP="$HOME/Applications/Orca.app"
  "$ORCA_APP/Contents/Resources/bin/orca" pair --help >/dev/null 2>&1 \
    || die "装好后 $ORCA_APP 还是没有 orca pair，见上面 brew 的输出。"
fi
ORCA_CLI="$ORCA_APP/Contents/Resources/bin/orca"
log "$ORCA_APP，版本 $(defaults read "$ORCA_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"

# 手机和电脑要连的地址：这台机器的 Tailscale IPv4。
TS_IP=""
for cli in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do
  if [[ -x "$cli" ]]; then
    TS_IP="$("$cli" ip -4 2>/dev/null | head -1 || true)"
    if [[ -n "$TS_IP" ]]; then break; fi
  fi
done
[[ -n "$TS_IP" ]] || die "拿不到这台机器的 Tailscale 地址，电脑和手机连不上它。"

# ---------------------------------------------------------------------------
log "== 服务端（$AGENT）"
log "端口 $PORT（$PORT_WHY）"
SVC_PID="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^\tpid = / { print $3; exit }' || true)"
# 占着这个端口的不能是别的程序，包括你的其他 Orca（例如电脑上的 Orca 走 SSH 目标时起的、只听 127.0.0.1 的那个）。
# 这个服务端自己的（服务进程或它的子进程）不算，下面会重启它。
for pid in $(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true); do
  [[ -n "$SVC_PID" && ( "$pid" == "$SVC_PID" || "$(ps -o ppid= -p "$pid" | xargs)" == "$SVC_PID" ) ]] && continue
  die "$PORT 端口被 $(ps -o user=,comm= -p "$pid" | awk '{ print $1 " 的 " $2 }')（PID $pid）占着，换一个（--port）。"
done

mkdir -p "${AGENT%/*}" "${LOG_FILE%/*}"
NEW="$(mktemp)"
cat > "$NEW" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- 由 mac-host 的 scripts/orca-server.sh 生成，重新执行会覆盖。 -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <!-- 后台域（user/<UID>）：不要桌面，SSH 断开照常运行，能读钥匙串。 -->
  <key>LimitLoadToSessionType</key><string>Background</string>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ORCA_CLI</string><string>serve</string>
    <!-- 出错时自己按递增的间隔重启；连续失败太多会放弃并以 0 退出，launchd 不再拉起（见 orca serve --help）。 -->
    <string>--supervise</string>
    <!-- 不在日志里打配对码；用 orca pair 配对。 -->
    <string>--no-pairing</string>
    <string>--port</string><string>$PORT</string>
    <string>--pairing-address</string><string>$TS_IP</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ORCA_SERVE_RUNTIME</key><string>orcad</string>
    <key>SHELL</key><string>/bin/zsh</string>
    <key>LANG</key><string>en_US.UTF-8</string>
    <key>PATH</key><string>$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ExitTimeOut</key><integer>90</integer>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict>
</plist>
PLIST
plutil -lint "$NEW" >/dev/null || die "LaunchAgent 格式不对：$NEW"

# 配置没变、服务端也在跑，就不重启它（重启会断开它起的所有终端）。
if [[ -n "$SVC_PID" ]] && cmp -s "$NEW" "$AGENT"; then
  rm -f "$NEW"
  log "已在运行，配置没变，不重启"
else
  stop_agent
  # 桌面版开着时，同一份配置只能有一个 Orca 在服务，服务端会一直等它退出。只结束桌面版的主程序。
  if pkill -u "$(id -u)" -f "^$ORCA_APP/Contents/MacOS/Orca( |\$)" 2>/dev/null; then
    log "结束了你正开着的桌面版 Orca"
  fi
  mv "$NEW" "$AGENT"
  launchctl bootstrap "$DOMAIN" "$AGENT"
fi

listening() { lsof -nP -a -u "$(id -u)" -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; }
for (( i = 0; i < 60; i++ )); do
  listening && break
  sleep 1
done
if ! listening; then
  tail -n 20 "$LOG_FILE" 2>/dev/null || true
  die "60 秒内没在 $PORT 端口监听，日志见上面（$LOG_FILE）。"
fi
log "在 $PORT 端口监听，对外公布的地址 ws://$TS_IP:$PORT"

# ---------------------------------------------------------------------------
# orca pair 向正在运行的服务端要一个配对，不重启它，已经连着的设备不受影响。
log "== 配对"
"$ORCA_CLI" pair ${PAIR_ARGS[@]+"${PAIR_ARGS[@]}"} --address "$TS_IP" \
  || die "服务端没给出配对，看日志 $LOG_FILE。"

echo
if [[ " ${PAIR_ARGS[*]-} " == *" --mobile "* ]]; then
  log "用 iPhone 的 Orca Mobile 扫上面的二维码（手机要先连上 Tailscale）。"
else
  log "在自己电脑的 Orca 里：Settings → Remote Orca Servers → Add Server，粘贴上面的链接。"
  log "在这个 server 下建项目和 worktree，agent 就跑在这台机器上，电脑关了也不停，手机也看得到。"
  log "手机配对：重新执行本脚本并加上 --pair-mobile。"
fi
log "这台机器重启后：SSH 登录、不带参数执行一次本脚本，服务端就起来了（不用重新配对）。"
log "要在 Orca 起的终端里用 mytokens：开机后要有人登录过一次桌面（屏幕共享也行），钥匙串才解锁。"
