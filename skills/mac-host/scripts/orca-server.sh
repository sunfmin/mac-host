#!/bin/bash
# 【ssh 本人】让手机在你电脑关着时也能用 Orca：在这台机器上，你自己的桌面会话里常驻一个 Orca，
# 作为 Remote Orca Server，电脑和手机都连它。
# 用你自己的账号执行，命令见 mac-host 的 README「电脑关着时手机也能用」。可以重复执行。
# 需要先有自己的 Homebrew（同目录的 homebrew.sh），屏幕共享权限找管理员开；机器要满足的见 mac-host 的 README。
#
# 为什么不能只靠 SSH（读 Orca 源码得出）：
#   - 走 SSH 目标时这台机器上的 orcad 只听本机回环地址，电脑断开 15 分钟后自己退出，手机连不上；
#   - macOS 上从 SSH 启动 `orca serve` 会在注册应用时崩溃（SIGABRT），必须在本人的桌面会话里运行。
# 所以放一个 LaunchAgent：你每次登录桌面（屏幕共享“以自己身份登录”）时自动打开 Orca。
# Orca 的服务端口从 6768 起，被别人占了就往后找（最多到 6799），找到的端口会记住，下次还用它。
#
# 参数：
#   --off           不再常驻：删掉 LaunchAgent（Orca 本身不卸载）
#   --pair-mobile   在终端里打出手机配对的二维码，等手机扫码连上。要先登录过桌面。
#                   配对期间桌面版 Orca 退出一会儿，配完自动重新打开；智能体的终端不受影响。
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
BREW="$HOME/homebrew/bin/brew"
GUI="gui/$(id -u)"

OFF=0
PAIR=0
for arg in "$@"; do
  case "$arg" in
    --off) OFF=1 ;;
    --pair-mobile) PAIR=1 ;;
    *) die "未知参数：$arg" ;;
  esac
done
(( ! (OFF && PAIR) )) || die "--off 和 --pair-mobile 不能一起用。"

if (( OFF )); then
  launchctl bootout "$GUI/$LABEL" >/dev/null 2>&1 || true
  rm -f "$AGENT"
  log "已关闭：登录桌面时不再自动打开 Orca（正在运行的 Orca 不受影响）。"
  exit 0
fi

# Orca 的 tap 和安装包在 GitHub 上，镜像管不到。国内直连慢的话自己指定代理（同目录的 mihomo.sh 装的，
# 用法见 mac-host 的 README「代理」）；本脚本不会自己去用代理。
[[ -z "${https_proxy:-}" ]] || log "使用你指定的代理：$https_proxy"

# ---------------------------------------------------------------------------
log "== Orca"
[[ -x "$BREW" ]] || die "还没有你自己的 Homebrew：先执行同目录的 homebrew.sh（不带参数），见 mac-host 的 README「自己的 Homebrew」。"
if ! NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 "$BREW" list --cask "$ORCA_CASK" >/dev/null 2>&1; then
  mkdir -p "$HOME/Applications"
  NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 \
    "$BREW" install --cask --appdir="$HOME/Applications" "$ORCA_CASK" || die "安装 Orca 失败，见上面的输出。"
fi
ORCA_APP=""
for a in "$HOME/Applications/Orca.app" /Applications/Orca.app; do
  if [[ -d "$a" ]]; then ORCA_APP="$a"; break; fi
done
[[ -n "$ORCA_APP" ]] || die "brew 说装好了，但 ~/Applications 和 /Applications 里都没有 Orca.app。"
log "$ORCA_APP，版本 $(defaults read "$ORCA_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
# 机器的防火墙自动放行有开发者签名的应用（mac-host 的 README「机器要满足的」）；没签名的会被拦，手机连不上。
if spctl -a -t exec "$ORCA_APP" >/dev/null 2>&1; then
  log "签名有效，防火墙会自动放行"
  # Homebrew 给 cask 打了「从互联网下载」的隔离标记，第一次打开时桌面上会弹窗等人点「打开」，
  # Orca 一直起不来（2026-11 在 Mac Mini 上实测）。签名已经通过 Gatekeeper 检查，去掉标记。
  xattr -dr com.apple.quarantine "$ORCA_APP" 2>/dev/null || true
  if xattr -p com.apple.quarantine "$ORCA_APP" >/dev/null 2>&1; then
    warn "去不掉隔离标记：第一次打开 Orca 时桌面上会弹窗，要在屏幕共享里点「打开」。"
  fi
else
  warn "Orca 的签名没通过检查，防火墙可能拦它的连接。找管理员在防火墙里放行 $ORCA_APP。"
fi

# ---------------------------------------------------------------------------
log "== 登录桌面时自动打开 Orca"
mkdir -p "${AGENT%/*}"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- 由 mac-host 的 scripts/orca-server.sh 生成，重新执行会覆盖。 -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>$ORCA_APP</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
plutil -lint "$AGENT" >/dev/null || die "LaunchAgent 格式不对：$AGENT"
log "已写入 $AGENT"

# 在你的桌面会话里重新加载 LaunchAgent；RunAtLoad 让它马上打开 Orca。
start_orca() {
  launchctl bootout "$GUI/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$GUI" "$AGENT"
}

# 这台机器在 tailnet 里的名字（写进给你的说明）和 IPv4 地址（手机配对时手机连它）。
TS_NAME=""
TS_IP=""
for cli in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do
  if [[ -x "$cli" ]]; then
    TS_NAME="$("$cli" status --json 2>/dev/null \
      | sed -n 's/^[[:space:]]*"DNSName": "\([^."]*\)\..*/\1/p' | head -1 || true)"
    TS_IP="$("$cli" ip -4 2>/dev/null | head -1 || true)"
    if [[ -n "$TS_NAME" ]]; then break; fi
  fi
done
TS_NAME="${TS_NAME:-<这台机器的 Tailscale 名字>}"

# ---------------------------------------------------------------------------
# --pair-mobile：不经过界面生成手机配对。
# 能生成手机配对的命令只有 `orca serve --mobile-pairing`，而桌面版开着时它拒绝启动（一份配置只能
# 有一个 Orca 在服务）。所以先退出桌面版，在你的桌面会话里起 orca serve 打出二维码，等手机连上，
# 再停掉它、重新打开桌面版。两者的配对记录都在 ~/Library/Application Support/orca，桌面版重新
# 打开后监听同一个端口，手机自己重连（实测数据见 mac-host 的 README「手机配对」）。
#
# 这些步骤写成 pair.sh，由 launchd 在你的桌面会话里运行；SSH 这边只打出二维码、转述进度。
# 收尾不能放在 SSH 里：SSH 一断，SSH 里的进程连 EXIT trap 都来不及跑就被杀掉，桌面版就再也起不来了
# （实测见 mac-host 的 README「手机配对」）。pair.sh 不受 SSH 影响，总会等到配对完成或超时再收尾。
PAIR_LABEL="orca-studio.pair-mobile"
PAIR_DIR="$HOME/.orca-pair"

pair_mobile() {
  [[ -n "$TS_IP" ]] || die "拿不到这台机器的 Tailscale 地址，手机连不上它。"
  # 上一次配对留下的（SSH 断开后 pair.sh 照样跑完，但没人替它删目录）。
  launchctl bootout "$GUI/$PAIR_LABEL" >/dev/null 2>&1 || true
  rm -rf "$PAIR_DIR"
  mkdir -m 700 "$PAIR_DIR"
  : > "$PAIR_DIR/status"

  cat > "$PAIR_DIR/pair.sh" <<'PAIR_SH'
#!/bin/bash
# 由 mac-host 的 scripts/orca-server.sh --pair-mobile 生成，launchd 在桌面会话里运行它。
# 进度一行一行写进 status（单独一行 QR 表示在这里打出二维码），结束时把退出码写进 result。
# 参数：工作目录、Orca.app 的路径、手机要连的 Tailscale 地址、桌面版 Orca 的 LaunchAgent 文件和它的 Label。
DIR="$1" APP="$2" IP="$3" AGENT="$4" LABEL="$5"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
LC_ALL=C
GUI="gui/$UID"
# 桌面版和 orca serve 是同一个程序（Orca.app 的主程序）。智能体的终端跑在单独的 Orca Terminal 进程里，不算在内。
MAIN_RE="^$APP/Contents/MacOS/Orca( |\$)"
DEVICES="$HOME/Library/Application Support/orca/orca-devices.json"

say() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$DIR/status"; }

# 等 Orca 主程序全部退出，最多 30 秒。
wait_exit() {
  local i
  for (( i = 0; i < 30; i++ )); do
    if ! pgrep -u "$UID" -f "$MAIN_RE" >/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

# 停掉 orca serve，删掉配对码（等同于手机的登录凭据），重新打开桌面版，确认它对外监听。
# 要等 orca serve 真的退出了再打开：它还在时，open 会把它当成已经开着的 Orca，不再启动新的（2026-11 实测）。
finish() {
  local rc="$1" port="" i
  if [[ -s "$DIR/ready.json" ]]; then
    port="$(jq -r '.pairing.endpoint' "$DIR/ready.json")"
    port="${port##*:}"
  fi
  pkill -u "$UID" -f "$MAIN_RE"
  wait_exit || say "WARN: orca serve 30 秒内没退出。"
  rm -f "$DIR/serve.log" "$DIR/ready.json"
  launchctl bootout "$GUI/$LABEL" >/dev/null 2>&1
  if launchctl bootstrap "$GUI" "$AGENT"; then
    say "已重新打开桌面版 Orca"
  else
    say "WARN: 重新打开桌面版 Orca 失败：重新执行 orca-server.sh（不带参数）。"
    rc=1
  fi
  if [[ -n "$port" ]]; then
    for (( i = 0; i < 30; i++ )); do
      if lsof -a -nP -iTCP:"$port" -sTCP:LISTEN -u "$UID" 2>/dev/null | grep -F "*:$port" >/dev/null; then break; fi
      sleep 1
    done
    if (( i < 30 )); then
      say "桌面版 Orca 在 $port 端口对外监听，手机会自己重连"
    else
      say "WARN: 桌面版 Orca 30 秒内没在 $port 端口对外监听，手机连不上它。"
      rc=1
    fi
  fi
  echo "$rc" > "$DIR/result"
  exit "$rc"
}

pkill -u "$UID" -f "$MAIN_RE"
if ! wait_exit; then
  say "ERROR: 桌面版 Orca 30 秒内没退出（可能弹了确认框）：在屏幕共享里退出它，再重新执行 --pair-mobile。"
  echo 1 > "$DIR/result"
  exit 1
fi

"$APP/Contents/Resources/bin/orca" serve --mobile-pairing --pairing-address "$IP" --json > "$DIR/serve.log" 2>&1 &
SERVE=$!
for (( i = 0; i < 60; i++ )); do
  if grep -m1 '"type":"orca_server_ready"' "$DIR/serve.log" > "$DIR/ready.tmp" 2>/dev/null; then
    mv "$DIR/ready.tmp" "$DIR/ready.json"
    break
  fi
  kill -0 "$SERVE" 2>/dev/null || break
  sleep 1
done
if [[ ! -s "$DIR/ready.json" ]]; then
  tail -20 "$DIR/serve.log" >> "$DIR/status" 2>/dev/null
  say "ERROR: orca serve 没有起来，它的输出见上面。"
  finish 1
fi
DEV="$(jq -r '.pairing.deviceId // empty' "$DIR/ready.json")"
if [[ -z "$DEV" ]]; then
  say "ERROR: orca serve 没有给出配对码。"
  finish 1
fi

say "手机要连的地址：$(jq -r '.pairing.endpoint' "$DIR/ready.json")"
echo QR >> "$DIR/status"
say "用 iPhone 的 Orca Mobile 扫上面的二维码（手机要先连上 Tailscale）。最多等 5 分钟。"
# orca serve 先把这台手机记进配对记录（lastSeenAt 为 0），手机连上后 lastSeenAt 才有值。
for (( i = 0; i < 150; i++ )); do
  if jq -e --arg d "$DEV" 'any(.[]; .deviceId == $d and .lastSeenAt > 0)' "$DEVICES" >/dev/null 2>&1; then
    say "手机已配对并连上"
    finish 0
  fi
  sleep 2
done
say "ERROR: 5 分钟内手机没有连上。没扫到的话重新执行 --pair-mobile；扫了连不上的话，检查手机的 Tailscale。"
finish 1
PAIR_SH

  cat > "$PAIR_DIR/pair.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PAIR_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>$PAIR_DIR/pair.sh</string>
    <string>$PAIR_DIR</string><string>$ORCA_APP</string><string>$TS_IP</string><string>$AGENT</string><string>$LABEL</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$PAIR_DIR/pair.log</string>
  <key>StandardErrorPath</key><string>$PAIR_DIR/pair.log</string>
</dict>
</plist>
PLIST
  plutil -lint "$PAIR_DIR/pair.plist" >/dev/null || die "LaunchAgent 格式不对：$PAIR_DIR/pair.plist"
  launchctl bootstrap "$GUI" "$PAIR_DIR/pair.plist"

  # 转述 pair.sh 的进度，直到它写出 result。pair.sh 最长约 7.5 分钟
  # （等桌面版退出 30 秒、等 orca serve 60 秒、等手机 5 分钟、收尾 60 秒），这里等 9 分钟。
  local shown=0 n line finished=0 rc deadline=$(( SECONDS + 540 ))
  while :; do
    if [[ -s "$PAIR_DIR/result" ]]; then finished=1; fi
    n=$(( $(wc -l < "$PAIR_DIR/status") ))
    while (( shown < n )); do
      shown=$(( shown + 1 ))
      line="$(sed -n "${shown}p" "$PAIR_DIR/status")"
      if [[ "$line" == QR ]]; then
        jq -r '.pairing.qr' "$PAIR_DIR/ready.json" 2>/dev/null || warn "二维码已经失效，重新执行 --pair-mobile。"
      else
        printf '%s\n' "$line"
      fi
    done
    if (( finished )); then break; fi
    (( SECONDS < deadline )) || die "配对 9 分钟还没结束，看 $PAIR_DIR/pair.log。"
    sleep 1
  done
  launchctl bootout "$GUI/$PAIR_LABEL" >/dev/null 2>&1 || true
  rc="$(cat "$PAIR_DIR/result")"
  rm -rf "$PAIR_DIR"
  [[ "$rc" == 0 ]] || exit 1
}

# 你此刻已经登录着桌面的话马上生效，否则等下次登录。
if ! launchctl print "$GUI" >/dev/null 2>&1; then
  (( ! PAIR )) || die "你还没有登录桌面，配对不了：先用屏幕共享登录一次（不带参数执行本脚本，看输出的第 a 步）。"
  log "你还没有登录桌面：第一次用屏幕共享登录后 Orca 会自动打开"
elif (( PAIR )); then
  log "== 手机配对"
  pair_mobile
  exit 0
elif start_orca; then
  log "已在你的桌面会话里启动 Orca"
else
  warn "启动失败；下次登录桌面时会自动打开，或在屏幕共享里手动打开 Orca。"
fi

# 屏幕共享名单：组不存在说明设成了「所有用户」，谁都能连。
if dseditgroup -o read com.apple.access_screensharing >/dev/null 2>&1 \
   && ! dseditgroup -o checkmember -m "$USER" com.apple.access_screensharing >/dev/null 2>&1; then
  warn "你还没有屏幕共享权限，下面第 a 步做不了。找管理员给 $USER 开屏幕共享权限。"
fi

# ---------------------------------------------------------------------------
log "== 完成。接下来："
cat <<EOF

  a. 用屏幕共享登录：Finder → 前往 → 连接服务器 → vnc://$TS_NAME
     选“以我自己的身份登录”（不会占用别人的屏幕），用户名 $USER，密码是 IT 给你的那个（登录后请修改）。
     Orca 会自动打开。之后直接关掉屏幕共享窗口，不要注销，Orca 会一直在后台运行。
  b. 在这台机器的 Orca 里：Settings → Remote Orca Servers → New Link，
     Connection address 选 100. 开头的 Tailscale 地址，Generate Access Link，复制链接。
  c. 在自己电脑的 Orca 里：Settings → Remote Orca Servers → Add Server，粘贴链接。
     在这个 server 下建项目和 worktree，agent 就跑在这台机器上，电脑关了也不停。
     用 SSH 目标建的 worktree 归你电脑上的 Orca 管，电脑关了手机就看不到。
  d. 手机装 Orca Mobile 并连上 Tailscale；登录桌面后，重新执行本脚本并加上 --pair-mobile，
     终端里会打出二维码，用 Orca Mobile 扫。

  这台机器重启后要重复一次 a（只登录，不用重新配对）。
  用 iPhone 也能做 a：iPhone 上开 Tailscale，装 Screens 5（Edovia），新建连接，地址 $TS_NAME，
  用户名 $USER 和你的密码；提示时选 Log in as yourself（不要选 Share display）。
  其他 VNC app 多半开不出自己的会话，会连到别人的屏幕。
EOF
