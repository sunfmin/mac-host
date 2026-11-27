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
# 自动更新 Orca 的 LaunchAgent（见下面「自动更新」）。
UPDATE_LABEL="orca-studio.orca-update"
UPDATE_AGENT="$HOME/Library/LaunchAgents/$UPDATE_LABEL.plist"
UPDATE_SCRIPT="$HOME/Library/Application Support/orca-studio/orca-update.sh"
UPDATE_LOG="$HOME/Library/Logs/Orca/orca-update.log"
UPDATE_HOUR=4 UPDATE_MINUTE=30
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
  launchctl bootout "$DOMAIN/$UPDATE_LABEL" >/dev/null 2>&1 || true
  rm -f "$AGENT" "$UPDATE_AGENT" "$UPDATE_SCRIPT"
  log "已停掉并删除你的 Orca 服务端和自动更新（Orca 和配对记录都还在，不带 --off 重新执行即可恢复）。"
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
  # brew 装上的带着 quarantine（「从网上下载的」）：第一次运行会弹「允许打开」，没人点就卡住，
  # 之后每个调 orca 的进程都排在它后面。先去掉，去不掉就停在这里。
  if ! err="$(xattr -dr com.apple.quarantine "$ORCA_APP" 2>&1)" \
     || xattr -p com.apple.quarantine "$ORCA_APP" >/dev/null 2>&1; then
    fix=""
    [[ "$err" == *"Operation not permitted"* ]] && fix="；缺「App 管理」权限，修法见 README「机器要满足的」（https://github.com/sunfmin/mac-host#app-management）"
    die "去不掉 $ORCA_APP 的 quarantine：$(tail -1 <<<"${err:-执行后属性还在}")$fix"
  fi
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
    <!-- 出错时自己按递增的间隔重启。它也会以 0 退出（连续失败太多放弃时，或原因不明：2026-11-20 mac-studio 上无日志地退出），所以下面 KeepAlive 无条件拉起。 -->
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
  <!-- 无条件拉起：机器没人看着，服务端停了就一直连不上。要停用 launchctl bootout（本脚本 --off），不受这条影响。 -->
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ExitTimeOut</key><integer>90</integer>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict>
</plist>
PLIST
plutil -lint "$NEW" >/dev/null || die "LaunchAgent 格式不对：$NEW"

# 配置没变、服务端也在跑，就不重启它（终端会留着，但连着的电脑和手机要断开重连）。
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
# 自动更新：服务端跑的是没有桌面的 orcad，用不上桌面版自己的更新（orca status 报
# remoteUpdateSupport.installMode = unsupported-headless-serve）；cask 标了 auto_updates，普通的
# brew upgrade 也会跳过它（要 --greedy）。所以另装一个 LaunchAgent，每天 $UPDATE_HOUR:$UPDATE_MINUTE（机器本地时间）
# 升级一次，服务端跑的不是装着的版本就重启它换上。
log "== 自动更新（$UPDATE_AGENT）"
mkdir -p "${UPDATE_SCRIPT%/*}"
{
# 开头这段由本脚本填上值，下面的正文原样写入。
cat <<UPDATE_VARS
#!/bin/bash
# 由 mac-host 的 scripts/orca-server.sh 生成，重新执行会覆盖。launchd 每天运行一次，记在 \$LOG。
APP="$ORCA_APP" BREW="$BREW" CASK="$ORCA_CASK" SERVICE="$DOMAIN/$LABEL" LOG="$UPDATE_LOG"
UPDATE_VARS
cat <<'UPDATE_SH'
export PATH="$HOME/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
cd "$HOME"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
installed() { defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null; }
# 服务端正在跑的版本。不看 brew 这次升没升：升了但没重启成的，第二天还会补上。
running() {
  "$APP/Contents/Resources/bin/orca" status --json 2>/dev/null \
    | plutil -extract result.runtime.appVersion raw -o - - 2>/dev/null
}
serving="$(running)"
before="$(installed)"
# 先拉新的 tap：brew 自己 24 小时才更新一次 tap，只靠它的话新版要晚一两天才装上
# （2026-11-21 实测：tap 发了 1.4.267，brew upgrade 仍说 1.4.266 是最新）。
if ! out="$("$BREW" update --quiet 2>&1)"; then
  log "brew update 失败，按本地已有的 tap 升级：$(tail -1 <<<"$out")"
fi
# --greedy：这个 cask 标了 auto_updates，不加的话 brew 认为它会自己更新，跳过。
if ! out="$("$BREW" upgrade --cask --greedy "$CASK" 2>&1)"; then
  log "升级失败（装着的是 $before）：$(tail -3 <<<"$out" | tr '\n' ' ')"
  exit 1
fi
now="$(installed)"
[[ "$now" == "$before" ]] || log "已升级 $before → $now"
if [[ "$serving" == "$now" ]]; then
  log "已是最新：$now"
  exit 0
fi
# brew 装上的新版带着 quarantine（「从网上下载的」），没有桌面时没人能点首次打开的对话框。去掉它，再先空跑一次，
# 让系统的首次检查在重启服务端之前做完（2026-11-21 在 mac-studio 上 brew 原地升级的新版 1 秒就过了；
# 复制到 /tmp 的副本却卡了 5 分钟以上，原因没查清）。等不到就不重启，正在跑的服务端照常用。
# 去完要核对：2026-11-27 1.4.278 的 quarantine 没去掉（报错被吞了，原因没查到），空跑等对话框 15 分钟，
# 之后 PATH 上的 orca 都指向这个新版，调用它的进程都卡在同一个对话框上，factorium 的 worker 全停，人点了「允许」才好。
# 去不掉就不空跑，在日志里写明，让人看到。11-27、11-28 去不掉的原因是 Operation not permitted：
# /bin/bash 没有「App 管理」权限（mac-host README「机器要满足的」）。
if ! err="$(xattr -dr com.apple.quarantine "$APP" 2>&1)" \
   || xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
  fix=""
  [[ "$err" == *"Operation not permitted"* ]] && fix="；/bin/bash 缺「App 管理」权限，修法见 https://github.com/sunfmin/mac-host#app-management"
  log "去不掉新版 $now 的 quarantine，调用 orca 会卡在「允许打开」对话框上：$(tail -1 <<<"${err:-执行后属性还在}")$fix"
  exit 1
fi
"$APP/Contents/Resources/bin/orca" --version >/dev/null 2>&1 &
p=$!
for (( i = 0; i < 900; i++ )); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
if kill -0 "$p" 2>/dev/null; then
  kill "$p" 2>/dev/null
  log "新版 $now 15 分钟还没启动起来（系统的首次检查没做完），这次不重启服务端（还在跑 ${serving:-?}）"
  exit 1
fi
# 终端不跟着重启：它们在 Orca 的终端守护进程里，新服务端接回去。2026-11-21 在 mac-studio 上实测，
# 1.4.254 → 1.4.266 重启服务端，3 个跑了 5–23 小时的 claude 会话都还在，终端照常 connected。
launchctl kickstart -k "$SERVICE"
for (( i = 0; i < 180; i++ )); do
  serving2="$(running)"
  [[ "$serving2" == "$now" ]] && break
  sleep 1
done
if [[ "$serving2" == "$now" ]]; then
  log "重启了服务端：${serving:-（原来没在跑）} → $now"
else
  log "重启了服务端，3 分钟后在跑的是 ${serving2:-（连不上）}，应该是 $now：看 ~/Library/Logs/Orca/orca-server.log"
  exit 1
fi
UPDATE_SH
} > "$UPDATE_SCRIPT"
chmod 755 "$UPDATE_SCRIPT"
NEW_UPDATE="$(mktemp)"
cat > "$NEW_UPDATE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- 由 mac-host 的 scripts/orca-server.sh 生成，重新执行会覆盖。 -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$UPDATE_LABEL</string>
  <key>LimitLoadToSessionType</key><string>Background</string>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$UPDATE_SCRIPT</string></array>
  <!-- 机器本地时间，人一般不在用。机器睡着错过了，醒来后补跑一次。 -->
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$UPDATE_HOUR</integer><key>Minute</key><integer>$UPDATE_MINUTE</integer></dict>
  <key>StandardOutPath</key><string>$UPDATE_LOG</string>
  <key>StandardErrorPath</key><string>$UPDATE_LOG</string>
</dict>
</plist>
PLIST
plutil -lint "$NEW_UPDATE" >/dev/null || die "LaunchAgent 格式不对：$NEW_UPDATE"
launchctl bootout "$DOMAIN/$UPDATE_LABEL" >/dev/null 2>&1 || true
mv "$NEW_UPDATE" "$UPDATE_AGENT"
launchctl bootstrap "$DOMAIN" "$UPDATE_AGENT"
log "每天 $UPDATE_HOUR:$UPDATE_MINUTE（机器本地时间）升级 Orca，有新版就重启服务端换上（终端不受影响）；记在 $UPDATE_LOG"
log "  马上跑一次：launchctl kickstart $DOMAIN/$UPDATE_LABEL"

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
