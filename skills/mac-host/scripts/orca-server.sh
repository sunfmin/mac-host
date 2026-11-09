#!/bin/bash
# 【ssh 本人】电脑关着时手机也能用 Orca：给自己的电脑和手机配对这台机器上常驻的、你自己的 Orca 服务端。
# 用你自己的账号执行，命令见 mac-host 的 README「电脑关着时手机也能用」。可以重复执行。
#
# 服务端由管理员装（mac-studio-setup 的 ssh/root/35-orca-server.sh）：一个以你的身份运行的 LaunchDaemon，
# 开机就起，不用登录桌面，端口是你端口段里的 $DEV_PORT_BASE+97。本人装不了这种服务，原因见 README。
# 这个脚本不改服务端，只向它要配对：
#   不带参数        打出给电脑用的 Access Link（电脑上 Orca：Settings → Remote Orca Servers → Add Server）
#   --pair-mobile   打出手机扫的二维码（Orca Mobile；手机要先连上 Tailscale）
#   --rotate        作废还没用过的配对码、换一个新的（已经配对的设备不受影响）；可以和 --pair-mobile 一起用
# 配对码等同于登录凭据：只打在你的终端里，不要贴给别人。
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

# 管理员装的服务的名字（mac-studio-setup 的 35-orca-server.sh）。
LABEL="orca-studio.orca-server.$USER"
# 本脚本旧版本装的：登录桌面时打开桌面版 Orca。会和常驻的服务端抢同一份配置。
OLD_AGENT_LABEL="orca-studio.orca-server"
OLD_AGENT="$HOME/Library/LaunchAgents/$OLD_AGENT_LABEL.plist"

PAIR_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --pair-mobile) PAIR_ARGS+=(--mobile) ;;
    --rotate) PAIR_ARGS+=(--rotate) ;;
    *) die "未知参数：$arg" ;;
  esac
done

if [[ -f "$OLD_AGENT" ]]; then
  launchctl bootout "gui/$(id -u)/$OLD_AGENT_LABEL" >/dev/null 2>&1 || true
  rm -f "$OLD_AGENT"
  log "删掉了旧版本装的 $OLD_AGENT（登录桌面时打开桌面版 Orca；现在不用登录桌面了）"
fi

launchctl print "system/$LABEL" >/dev/null 2>&1 \
  || die "这台机器上还没有你常驻的 Orca 服务端：请管理员执行 mac-studio-setup 的 ssh/root/35-orca-server.sh $USER。"

ORCA_CLI=""
for a in "$HOME/Applications/Orca.app" /Applications/Orca.app; do
  if [[ -x "$a/Contents/Resources/bin/orca" ]]; then ORCA_CLI="$a/Contents/Resources/bin/orca"; break; fi
done
[[ -n "$ORCA_CLI" ]] || die "找不到 Orca.app：请管理员重新执行 ssh/root/35-orca-server.sh $USER。"

# 手机和电脑要连的地址：这台机器的 Tailscale IPv4。
TS_IP=""
for cli in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do
  if [[ -x "$cli" ]]; then
    TS_IP="$("$cli" ip -4 2>/dev/null | head -1 || true)"
    if [[ -n "$TS_IP" ]]; then break; fi
  fi
done
[[ -n "$TS_IP" ]] || die "拿不到这台机器的 Tailscale 地址，电脑和手机连不上它。"

# orca pair 向正在运行的服务端要一个配对，不重启它，已经连着的设备不受影响。
"$ORCA_CLI" pair ${PAIR_ARGS[@]+"${PAIR_ARGS[@]}"} --address "$TS_IP" \
  || die "服务端没给出配对：它可能没在运行，请管理员看 ssh/root/50-report.sh 的「Orca端口」一列。"

echo
if [[ " ${PAIR_ARGS[*]-} " == *" --mobile "* ]]; then
  log "用 iPhone 的 Orca Mobile 扫上面的二维码（手机要先连上 Tailscale）。"
else
  log "在自己电脑的 Orca 里：Settings → Remote Orca Servers → Add Server，粘贴上面的链接。"
  log "在这个 server 下建项目和 worktree，agent 就跑在这台机器上，电脑关了也不停，手机也看得到。"
  log "手机配对：重新执行本脚本并加上 --pair-mobile。"
fi
