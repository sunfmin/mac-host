#!/bin/bash
# 【ssh 本人】在自己的账号里装一个 mihomo 代理（Clash Meta 内核），国内网络访问 GitHub、Anthropic 等慢时用。
# 用你自己的账号执行，命令见 mac-host 的 README「代理」。可以重复执行：每次重新下载订阅，mihomo 有新版本时顺便更新，
# 再量一次现在用的节点，下载太慢就把所有节点同时量一遍，换成最快的（见「选节点」）。
# 国外的机器用不上它。
#
# 只是装好、跑起来，不替你挂上：任何脚本和 shell 配置都不会自动用它。
# 要用时自己指定，例如在终端里执行 . ~/mihomo/proxy.env（只影响这个终端），用法见 mac-host 的 README「代理」。
#
# 全部东西都在 ~/mihomo（只有你能读）：程序、订阅地址、配置、日志、proxy.env。
# 只在 127.0.0.1 上开一个 HTTP + SOCKS5 端口，不开 TUN、不改路由，所以不影响 Tailscale。
# 端口用你端口段的最后两个：$DEV_PORT_BASE+98 是代理，+99 是切换节点用的控制接口。
# 以 LaunchAgent 在后台运行，SSH 断开后照样在跑；机器重启后不会自己起来，要用时重新执行本脚本。
#
# 参数：
#   --subscription <url>   订阅地址（返回 Clash 配置）。第一次必填；之后不填就用上次保存的。
#                          订阅地址等同于密码：它会出现在你电脑的 shell 历史里；这台机器上只存在 ~/mihomo 里。
#   --mihomo-url <url>     从这里下载 mihomo 的 .gz（不核对 sha256），代替默认的下载方式；
#                          可以是 file:///path/to/mihomo-darwin-arm64-vX.Y.Z.gz
#   --uninstall            停掉并删除 ~/mihomo 和 LaunchAgent
#
# mihomo 只在 GitHub 发布，国内没有官方镜像，直连 GitHub 很慢（实测 30-90KB/s）。
# 先从 GitHub API 拿版本号和官方 sha256（几百 KB），再下载：官方优先，GH_PROXIES 里的国内加速代理只是候补，
# 直连低于 100KB/s 持续 15 秒才换。每次都核对 sha256，对不上就丢掉换下一个，所以代理改不了文件内容。
#
# 例：--subscription https://example.com/api/user/account/subscribe/xxxx
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
# 没有这一行的话脚本中途退出会完全没有线索——例如命令被 SIGPIPE 杀掉（退出码 141）时，
# shell 本身不打印任何东西。set -E 让函数和子 shell 里也生效。
trap 'rc=$?; printf "[%s] ERROR: 第 %s 行失败，退出码 %s。\n" "$(date "+%H:%M:%S")" "$LINENO" "$rc"; exit "$rc"' ERR
[[ $EUID -ne 0 ]] || die "用你自己的账号执行，不要用 root。"

DIR="$HOME/mihomo"
BIN="$DIR/mihomo"
PROXY_ENV="$DIR/proxy.env"
LABEL=orca-studio.mihomo
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
# user/ 域：不需要登录桌面，SSH 断开后照样在跑（2026-11 在 Mac Mini 上实测）。
DOMAIN="user/$(id -u)"
# GitHub 在国内很慢；jsDelivr 上的同一份地理数据库快得多。
GEO_BASE="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release"
# 国内的 GitHub 加速代理，直连太慢时才用（2026-11 国内实测 20MB：gh-proxy.com 4 秒）。
GH_PROXIES="https://gh-proxy.com/"

SUB=""
MIHOMO_URL=""
UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUB="${2:?--subscription 需要一个值}"; shift 2 ;;
    --mihomo-url) MIHOMO_URL="${2:?--mihomo-url 需要一个值}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ -z "$SUB" || "$SUB" =~ ^https?:// ]] || die "订阅地址应以 http:// 或 https:// 开头。"

stop_agent() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  # bootout 返回时进程可能还没退干净，紧接着 bootstrap 会失败。
  for _ in $(seq 1 10); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
    sleep 1
  done
}

# ---------------------------------------------------------------------------
if (( UNINSTALL )); then
  log "== 卸载 mihomo"
  stop_agent
  rm -f "$AGENT"
  rm -rf "$DIR"
  log "已删除。执行过 . $PROXY_ENV 的终端里还留着代理变量，关掉重开即可。"
  exit 0
fi

# 端口段由管理员写进 ~/.zshenv（mac-host 的 README「机器要满足的」），这里向 zsh 问，不自己算。
DEV_PORT_BASE="$(/bin/zsh -c 'print -r -- "$DEV_PORT_BASE"' 2>/dev/null || true)"
[[ "$DEV_PORT_BASE" =~ ^[0-9]+$ ]] || die "~/.zshenv 里没有 DEV_PORT_BASE：这台机器没按 mac-host 的 README「机器要满足的」配好，找管理员。"
PORT=$(( DEV_PORT_BASE + 98 ))
CONTROLLER="127.0.0.1:$(( DEV_PORT_BASE + 99 ))"

# 临时文件放在只有你能读的固定目录（订阅里有节点密码），每次开头清空，成功后删掉。
# 不用 trap ... EXIT 清理：bash 3.2 有 EXIT trap 时，unbound variable 这类错误会以退出码 0 结束，
# 看起来像是成功了。
WORK="$DIR/work"
mkdir -p "$DIR"
chmod 700 "$DIR"
rm -rf "$WORK"
mkdir -m 700 "$WORK"

# ---------------------------------------------------------------------------
log "== 订阅"
SUB_FILE="$DIR/subscription.url"
if [[ -n "$SUB" ]]; then
  ( umask 077; printf '%s\n' "$SUB" > "$SUB_FILE" )
  log "已保存订阅地址（只有你能读）"
elif [[ -s "$SUB_FILE" ]]; then
  SUB="$(head -1 "$SUB_FILE")"
  log "使用上次保存的订阅地址"
else
  die "第一次执行需要 --subscription <订阅地址>。"
fi
# 不同的 User-Agent 会拿到不同格式；clash.meta 拿到的是完整的 Clash 配置。
curl -fsSL -A clash.meta --retry 3 --connect-timeout 20 --max-time 120 -o "$WORK/sub.yaml" "$SUB" \
  || die "下载订阅失败。"
grep -q '^proxies:' "$WORK/sub.yaml" || die "订阅返回的不是 Clash 配置（没有 proxies:）。"
log "节点 $(awk '/^proxies:/ { f = 1; next } /^[^ \t#-]/ { f = 0 } f && /^ *- /' "$WORK/sub.yaml" | wc -l | xargs) 个"

# 本机这几项由下面的开头部分决定，订阅里同名的顶层设置连同下属内容一起去掉。
OVERRIDDEN="port socks-port redir-port tproxy-port mixed-port allow-lan bind-address lan-allowed-ips"
OVERRIDDEN="$OVERRIDDEN external-controller external-controller-tls external-controller-unix"
OVERRIDDEN="$OVERRIDDEN external-controller-cors secret external-ui tun log-level geodata-mode geox-url profile"
# 订阅的内容，去掉顶层设置 $1（空格分隔）连同下属内容。
sub_config() {
  awk -v keys="$1" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) drop[k[i]] = 1 }
    /^[^ \t#-]/ { key = $0; sub(/:.*/, "", key); skip = (key in drop) }
    !skip
  ' "$WORK/sub.yaml"
}
SECRET_FILE="$DIR/controller.secret"
if [[ ! -s "$SECRET_FILE" ]]; then
  # head 放在管道上游：写成 tr ... | head -c N 的话，head 取够就退出，tr 收到 SIGPIPE（退出码 141），
  # 在 set -o pipefail 下脚本会不打印任何错误就中断。
  SECRET="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  SECRET="${SECRET:0:32}"
  [[ ${#SECRET} -eq 32 ]] || die "生成控制接口密钥失败。"
  ( umask 077; printf '%s' "$SECRET" > "$SECRET_FILE" )
  unset SECRET
fi
{
  cat <<EOF
# 由 mac-host 的 scripts/mihomo.sh 生成，重新执行会覆盖。开头这几项是本机设置，其余来自订阅。
mixed-port: $PORT
allow-lan: false
bind-address: 127.0.0.1
# 切换节点、看状态用：curl -H "Authorization: Bearer \$(cat $SECRET_FILE)" http://$CONTROLLER/proxies
external-controller: $CONTROLLER
secret: "$(cat "$SECRET_FILE")"
log-level: warning
geodata-mode: false
# 记住在控制接口里给各分组选的节点（存在 $DIR/cache.db），重启和重新执行本脚本后照旧。
profile:
  store-selected: true
geox-url:
  mmdb: "$GEO_BASE/country.mmdb"
  geoip: "$GEO_BASE/geoip.dat"
  geosite: "$GEO_BASE/geosite.dat"

EOF
  sub_config "$OVERRIDDEN"
} > "$WORK/config.yaml"

# ---------------------------------------------------------------------------
log "== mihomo 程序"
case "$(uname -m)" in
  arm64) PLATFORM=darwin-arm64 ;;
  x86_64) PLATFORM=darwin-amd64-compatible ;;
  *) die "不支持的 CPU：$(uname -m)" ;;
esac
CURRENT="$([[ -x "$BIN" ]] && "$BIN" -v 2>/dev/null | awk '{ print $3; exit }' || true)"
WANT=""
SHA=""
if [[ -n "$MIHOMO_URL" ]]; then
  URLS="$MIHOMO_URL"
else
  curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 -o "$WORK/release.json" \
    https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
    || die "查不到 mihomo 的最新版本（连不上 api.github.com）。可以用 --mihomo-url 指定下载地址。"
  WANT="$(jq -r .tag_name "$WORK/release.json")"
  [[ "$WANT" =~ ^v[0-9.]+$ ]] || die "mihomo 版本号格式不对：$WANT"
  ASSET="mihomo-$PLATFORM-$WANT.gz"
  SHA="$(jq -r --arg n "$ASSET" '.assets[] | select(.name == $n) | .digest // ""' "$WORK/release.json")"
  SHA="${SHA#sha256:}"
  [[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "GitHub 没有给出 $ASSET 的 sha256，不下载。"
  SRC="https://github.com/MetaCubeX/mihomo/releases/download/$WANT/$ASSET"
  URLS="$SRC"
  for m in $GH_PROXIES; do URLS="$URLS $m$SRC"; done
fi
if [[ -n "$WANT" && "$CURRENT" == "$WANT" ]]; then
  log "已是最新：$CURRENT"
else
  GOT=0
  for url in $URLS; do
    log "下载 $url"
    rm -f "$WORK/mihomo.gz"
    # 低于 100KB/s 持续 15 秒就放弃，换下一个（国内直连 GitHub 就是这样）。
    if ! curl -fsSL --connect-timeout 15 --speed-limit 102400 --speed-time 15 --max-time 1800 \
      -o "$WORK/mihomo.gz" "$url"; then
      warn "下载失败或太慢，换下一个。"
      continue
    fi
    if [[ -n "$SHA" && "$(shasum -a 256 "$WORK/mihomo.gz" | cut -d' ' -f1)" != "$SHA" ]]; then
      warn "sha256 和 GitHub 公布的不一致，丢掉，换下一个。"
      continue
    fi
    GOT=1
    break
  done
  (( GOT )) || die "所有地址都下载失败。可以用 --mihomo-url 指定别的地址。"
  [[ -z "$SHA" ]] || log "sha256 核对一致：$SHA"
  gunzip -c "$WORK/mihomo.gz" > "$WORK/mihomo" || die "解压失败，下载的文件可能不完整。"
  chmod 755 "$WORK/mihomo"
  NEW="$("$WORK/mihomo" -v 2>/dev/null | awk '{ print $3; exit }')" || die "下载的 mihomo 无法运行。"
  mv -f "$WORK/mihomo" "$BIN"
  log "已安装 ${NEW}（原来是 ${CURRENT:-无}）"
fi

# ---------------------------------------------------------------------------
log "== 配置"
# 地理数据库第一次要下载（从 jsDelivr，几秒钟），检查配置时会顺带下好放进 $DIR。
if ! out="$("$BIN" -t -d "$DIR" -f "$WORK/config.yaml" 2>&1)"; then
  printf '%s\n' "$out" | tail -20
  die "新配置检查不通过，没有替换现在的配置。"
fi
mv -f "$WORK/config.yaml" "$DIR/config.yaml"
log "已写入 $DIR/config.yaml"

# ---------------------------------------------------------------------------
log "== 后台运行"
mkdir -p "${AGENT%/*}"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- 由 mac-host 的 scripts/mihomo.sh 生成，重新执行会覆盖。 -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>-d</string><string>$DIR</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Background</string>
  <key>StandardOutPath</key><string>$DIR/mihomo.log</string>
  <key>StandardErrorPath</key><string>$DIR/mihomo.log</string>
</dict>
</plist>
EOF
plutil -lint "$AGENT" >/dev/null || die "LaunchAgent 格式不对：$AGENT"
# 端口空着才起；起来后等它开始监听。
start_agent() {
  # 停掉自己的之后端口还有人听，就是别的程序（例如你的 dev server）占了它。
  ! nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1 || die "端口 $PORT 被别的程序占用了：它是你端口段里留给代理的，把那个程序换个端口。"
  launchctl bootstrap "$DOMAIN" "$AGENT" || warn "launchctl bootstrap 返回失败，看它是否仍然起来了。"
  for _ in $(seq 1 30); do
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1 && break
    sleep 1
  done
  if ! nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    tail -20 "$DIR/mihomo.log" || true
    # 上次执行留下的 PROXY_ENV 指向的就是这个端口；代理没起来还留着它，加载它的终端会走这个不通的代理。
    rm -f "$PROXY_ENV"
    die "mihomo 没有在 30 秒内开始监听 ${PORT}，已删除 $PROXY_ENV。"
  fi
}
# 重启以加载新的程序和配置；正在走代理的连接会断一下。
stop_agent
start_agent
log "已在运行：127.0.0.1:$PORT"

# ---------------------------------------------------------------------------
# 订阅自带的 🎏Auto 只按延迟选节点，不看速度。2026-11-03 在 Mac Mini 上：它选的节点下载 Claude Code
# 只有 180KB/s（313MB 要半小时），同一订阅里别的节点有 4MB/s，也有完全下不动的。
# 所以先量现在用的节点，够快就不动（手动选的也留着）；慢了就把 SPEED_GROUP 的节点同时量一遍，换成最快的。
# 选择存在 cache.db，以后照旧；重新执行本脚本会再量一次。
# 量两样大文件的前 4MB：Claude Code 的程序（走 💡AI 分组，它默认跟着 SPEED_GROUP）和 GitHub 上的发布文件
# （mise、Homebrew 从这里下）。Anthropic 不服务的地区（例如香港）的节点拿不到 Claude Code，自然不算快。
log "== 选节点"
SPEED_GROUP="🪜Proxy"   # 分组名以订阅为准；订阅里没有这个分组就不选
SPEED_MIN_KB=1024       # 两样都不低于 1MB/s 才算快
CLAUDE_BASE="https://downloads.claude.ai/claude-code-releases"
GITHUB_TEST="https://github.com/astral-sh/uv/releases/download/0.13.6/uv-aarch64-apple-darwin.tar.gz"   # 14MB，版本固定
GROUP_URI="$(jq -rn --arg s "$SPEED_GROUP" '$s|@uri')"
MAIN_PROXY="http://127.0.0.1:$PORT"
# 控制接口的 /proxies（$1 为空）或 /proxies/<分组>（$1 是 GROUP_URI），其余参数给 curl。
api() { local p="$1"; shift; curl -fsS --max-time 10 -H "Authorization: Bearer $(cat "$SECRET_FILE")" "$@" "http://$CONTROLLER/proxies/$p"; }
# 经代理 $1 下载 $2 的前 4MB，打印 KB/s。最多下 6 秒（6 秒下不完 4MB 本来就不够快），没下完的按已下的算；
# 连不上、返回 403 这类失败是 0。
speed_kb() {
  local s
  s="$(curl -fsS -x "$1" -o /dev/null -r 0-4194303 -L --max-time 6 -w '%{speed_download}' "$2" 2>/dev/null || true)"
  awk -v s="${s:-0}" 'BEGIN { printf "%d", s / 1024 }'
}
# 经代理 $1 同时量两样，把「Claude 的 KB/s GitHub 的 KB/s」写进文件 $2。
measure() {
  local v c gp
  speed_kb "$1" "$GITHUB_TEST" > "$2.github" &
  gp=$!
  v="$(curl -fsS -x "$1" --max-time 10 "$CLAUDE_BASE/latest" 2>/dev/null || true)"
  c=0; [[ -z "$v" ]] || c="$(speed_kb "$1" "$CLAUDE_BASE/$v/darwin-arm64/claude")"
  wait "$gp" || true
  echo "$c $(cat "$2.github")" > "$2"
}
# measure 写的文件 $1：两样都够快吗；打印出来是什么样。
fast() { local c g; read -r c g < "$1"; (( c >= SPEED_MIN_KB && g >= SPEED_MIN_KB )); }
said() { local c g; read -r c g < "$1"; echo "Claude ${c}KB/s，GitHub ${g}KB/s"; }
select_node() { api "$GROUP_URI" -o /dev/null -X PUT -d "$(jq -cn --arg n "$1" '{name: $n}')"; }
# 分组层层往下跟，最后实际用的节点。
current_node() {
  api "" | jq -r --arg g "$SPEED_GROUP" '.proxies as $p | def r: if ($p[.].now // "") != "" then $p[.].now | r else . end; $g | r'
}
# 同时量 nodes.txt 里的每个节点，第 i 行（从 0 数）的结果写进 $WORK/probe/<i>。
# 分组一次只能选一个节点，所以另起一个只用来测速的 mihomo：节点和分组跟正式的一样来自订阅，
# 但入口要用户名，规则按用户名（IN-USER）把用户 n<i> 的流量交给第 i 个节点。
# 它用正式代理的端口（不多占你端口段里的端口），所以调用前要先停掉正式的。
# 订阅里这几项去掉：mode、rules 这一类由下面重写；skip-auth-prefixes 会让本机连接不带用户名，规则就分不出节点；
# listeners、tunnels 会多开端口；dns 可能要先从 GitHub 下地理数据库（国内很慢），测速用系统的 DNS 就够了。
PROBE_DROPPED="mode rules rule-providers sub-rules authentication skip-auth-prefixes listeners tunnels dns"
probe_all() {
  local p q i pids=""
  ! nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1 || return 1
  mkdir -m 700 "$WORK/probe"
  {
    cat <<EOF
mixed-port: $PORT
allow-lan: false
bind-address: 127.0.0.1
log-level: warning
mode: rule
authentication:
EOF
    awk '{ printf "  - \"n%d:x\"\n", NR - 1 }' "$WORK/nodes.txt"
    sub_config "$OVERRIDDEN $PROBE_DROPPED"
    echo "rules:"
    jq -Rnr '[inputs] | to_entries[] | "  - " + ("IN-USER,n\(.key),\(.value)" | tojson)' "$WORK/nodes.txt"
    echo "  - MATCH,REJECT"
  } > "$WORK/probe/config.yaml"
  "$BIN" -d "$WORK/probe" -f "$WORK/probe/config.yaml" > "$WORK/probe/mihomo.log" 2>&1 &
  p=$!
  for _ in $(seq 1 20); do
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if ! nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    tail -5 "$WORK/probe/mihomo.log" || true
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
    return 1
  fi
  i=0
  while IFS= read -r _; do
    measure "http://n$i:x@127.0.0.1:$PORT" "$WORK/probe/$i" &
    pids="$pids $!"
    i=$(( i + 1 ))
  done < "$WORK/nodes.txt"
  for q in $pids; do wait "$q" || true; done
  kill "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
}
if ! api "" > "$WORK/proxies.json" || ! jq -e --arg g "$SPEED_GROUP" '.proxies[$g].all' "$WORK/proxies.json" >/dev/null; then
  warn "控制接口里没有 $SPEED_GROUP 分组（分组名以订阅为准），不选节点。"
else
  CUR="$(current_node)"
  # 只要真正的节点，不要分组和直连。
  jq -r --arg g "$SPEED_GROUP" '.proxies as $p | $p[$g].all[]
    | select(($p[.].type // "") | test("^(Selector|URLTest|Fallback|LoadBalance|Relay|Direct|Reject|RejectDrop|Pass|Compatible)$") | not)' \
    "$WORK/proxies.json" > "$WORK/nodes.txt"
  measure "$MAIN_PROXY" "$WORK/now"
  if fast "$WORK/now"; then
    log "现在的节点 $CUR 够快：$(said "$WORK/now")"
  elif [[ ! -s "$WORK/nodes.txt" ]]; then
    warn "现在的节点 $CUR 太慢：$(said "$WORK/now")，$SPEED_GROUP 里又没有别的节点可换。"
  else
    log "现在的节点 $CUR 太慢：$(said "$WORK/now")。$(wc -l < "$WORK/nodes.txt" | xargs) 个节点同时量，代理停十几秒："
    stop_agent
    PROBED=1
    probe_all || PROBED=0
    start_agent
    if (( ! PROBED )); then
      warn "测速用的 mihomo 没起来，不换节点。"
    else
      # 按两样里慢的那样排，一样时看两样之和。同时下载会分走本机带宽，这里的数比单独量的低，只用来排先后。
      i=0
      while IFS= read -r n; do
        c=0; g=0
        if [[ -s "$WORK/probe/$i" ]]; then read -r c g < "$WORK/probe/$i"; fi
        printf '%d\t%d\t%d\t%d\t%s\n' "$(( c < g ? c : g ))" "$(( c + g ))" "$c" "$g" "$n"
        i=$(( i + 1 ))
      done < "$WORK/nodes.txt" | sort -t $'\t' -k1,1nr -k2,2nr > "$WORK/ranked.tsv"
      while IFS=$'\t' read -r _ _ c g n; do log "  $n：Claude ${c}KB/s，GitHub ${g}KB/s"; done < "$WORK/ranked.tsv"
      IFS=$'\t' read -r BEST_MIN _ _ _ BEST < "$WORK/ranked.tsv"
      if (( BEST_MIN == 0 )); then
        warn "没有一个节点两样都下得动，不换节点。装大东西会很慢，过一阵重新执行本脚本再选。"
      else
        select_node "$BEST"
        measure "$MAIN_PROXY" "$WORK/best"
        if fast "$WORK/best"; then
          log "换成最快的 $BEST，单独再量：$(said "$WORK/best")"
        else
          warn "换成了最快的 $BEST，但单独再量也不够 1MB/s：$(said "$WORK/best")。装大东西会很慢，过一阵重新执行本脚本再选。"
        fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
log "== 经代理访问测试"
FAILED=0
for u in https://github.com https://registry.npmjs.org https://api.anthropic.com/v1/messages; do
  code="$(curl -sS -o /dev/null -x "http://127.0.0.1:$PORT" --max-time 20 -w '%{http_code} %{time_total}s' "$u" 2>&1)" || FAILED=1
  log "  $u → $code"
done
(( FAILED == 0 )) || warn "有地址经代理访问失败：节点可能不可用，看 $DIR/mihomo.log。"
# Anthropic 不服务香港等地区：出口节点在这些地区时返回 403 Request not allowed，Claude Code 用不了。
[[ "$code" != 403* ]] || warn "api.anthropic.com 返回 403：AI 流量用的节点所在地区 Anthropic 不支持（例如香港）。换节点见 mac-host 的 README「代理」。"

# ---------------------------------------------------------------------------
# 最后才写：确认代理在监听之后，才让终端用它。
log "== 代理环境变量"
cat > "$PROXY_ENV" <<EOF
# 由 mac-host 的 scripts/mihomo.sh 生成，重新执行会覆盖。
# 需要代理时自己加载：. $PROXY_ENV，只影响加载它的终端或命令。
export http_proxy=http://127.0.0.1:$PORT
export https_proxy=http://127.0.0.1:$PORT
export HTTP_PROXY=http://127.0.0.1:$PORT
export HTTPS_PROXY=http://127.0.0.1:$PORT
export no_proxy=localhost,127.0.0.1,::1,.local,.ts.net,100.64.0.0/10,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
export NO_PROXY=\$no_proxy
EOF
log "已写入 $PROXY_ENV"

rm -rf "$WORK"
log "== 完成"
log "没有挂到任何地方：需要代理时执行 . $PROXY_ENV"
