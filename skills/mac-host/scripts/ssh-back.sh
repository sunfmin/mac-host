#!/bin/bash
# 【本人电脑】让远程机器 SSH 回到你自己的电脑。在你的电脑上执行，前提是你从这台电脑 ssh 得到远程机器。可以重复执行。
#
# 用法：
#   ssh-back.sh <远程>             接通，<远程> 是你平时 ssh 用的目标，例如 felix@mac-studio
#   ssh-back.sh <远程> --port <n>  指定远程机器上隧道的端口（默认远程的 $DEV_PORT_BASE+96）
#   ssh-back.sh --remove <远程>    拆掉：隧道、公钥授权、远程 ~/.ssh/config 里的那一段
#   ssh-back.sh --status           列出已接通的远程机器和各自隧道的状态
# 接通后在远程机器上：ssh <你电脑的 LocalHostName，小写>，例如 ssh felixmbairm1。
#
# 为什么是反向隧道：远程机器直接连你的电脑，往往被 Tailscale ACL 挡住（例如 tagged-devices 不许连个人设备），
# 而你电脑连远程是通的。所以由你的电脑 ssh -R 出去，远程机器经它自己的 127.0.0.1:<端口> 回来，
# 不改 Tailscale 配置（2026-11-23 在 Mac Studio 上实测：直连 TCP 被 ACL 丢弃，-R 隧道通）。
#
# 你的电脑上（都不要 admin，MDM 管的标准账号也行）：
#   - 一个你自己的 sshd（系统自带的 /usr/sbin/sshd，非 root 运行），只监听 127.0.0.1:2222，只认公钥，
#     只许你本人登录。系统「远程登录」不用开。配置、主机密钥、日志在 ~/.local/state/ssh-back/。
#     不放在 ~/.ssh 下：主机密钥按 sshd 的要求不加密，1Password 会把 ~/.ssh 里不加密的私钥报成问题。
#     旧版放在 ~/.ssh/ssh-back/，再执行一次会原样搬过来（主机密钥不变，远程钉住的指纹照样有效）。
#   - 每台远程一条隧道。sshd 和隧道都是 LaunchAgent（ssh-back.sshd、ssh-back.tunnel.<远程>），
#     登录桌面后自动起来，断了 30 秒后自己重连。电脑睡眠、关机、没登录时连不回来。
#   - 隧道由本脚本的 --run 跑：除了 ssh 自己的心跳，每 60 秒从远程连一次隧道端口，读不到本机 sshd 的
#     「SSH-2.0-」开头，而且这段时间隧道 ssh 几乎没收到字节（< 64 KB），就算坏；连续 2 次坏就杀掉隧道让
#     launchd 重起。只靠心跳不够：2026-11-24 实测，外层 SSH 连接和心跳都正常，Tailscale SSH（远程的
#     tailscaled）却不再读隧道端口上的连接（一个 rsync 的 1.4 MB 堆在那里 25 分钟以上），新连接卡在握手
#     （Connection timed out during banner exchange），隧道进程一直不退。看字节是为了不误杀：远程往电脑
#     推 10 MB 时（经东京中转约 1 Mbit/s，79 秒），新连接排在后面，握手要 64 秒，但隧道是好的。
#   - ~/.ssh/authorized_keys 里每台远程一行，带 from="127.0.0.1,::1"，行尾注释是 ssh-back:<远程>。
# 远程机器上：
#   - 专用密钥 ~/.ssh/id_ed25519_back（没有就生成，私钥不出那台机器）。
#   - ~/.ssh/config 开头一段 Host <你电脑名>（# >>> ssh-back 标记之间），主机指纹钉在 ~/.ssh/known_hosts.ssh-back。
#   - 共用机器上别人也连得到 127.0.0.1:<端口>，但没有你的私钥登不进来。
set -Eeuo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
# bash 3.2 在 UTF-8 环境下会把紧跟在 $变量 后面的中文当成变量名的一部分。只让 bash 自己用 C 语言环境。
LC_ALL=C

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*"; exit 1; }
trap 'rc=$?; printf "[%s] ERROR: 第 %s 行失败，退出码 %s。\n" "$(date "+%H:%M:%S")" "$LINENO" "$rc"; exit "$rc"' ERR
[[ $EUID -ne 0 ]] || die "用你自己的账号执行，不要用 root。"

SSHD_PORT=2222
PROBE_INTERVAL="${SSH_BACK_PROBE_INTERVAL:-60}" # 环境变量只给测试用
BUSY_BYTES=65536
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
DIR="$HOME/.local/state/ssh-back"
OLD_DIR="$HOME/.ssh/ssh-back"
AGENTS="$HOME/Library/LaunchAgents"
SSHD_LABEL="ssh-back.sshd"
DOMAIN="gui/$(id -u)"
ME="$(id -un)"
ALIAS="$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]')"
AUTH="$HOME/.ssh/authorized_keys"

tunnel_label() { printf 'ssh-back.tunnel.%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9.' '-')"; }

# 在远程执行一段 bash 脚本。Tailscale SSH 回给 ssh 的退出码总是 0，所以靠最后一行「退出码：」判断。
remote() {
  local target="$1" script="$2"; shift 2
  local out
  # ssh 把参数拼成一条命令交给远程 shell，所以参数要先转义好再拼进去。
  out="$(printf 'LC_ALL=C\n%s' "$script" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
    "/bin/bash -c \"\$(cat)\" _ $(printf '%q ' "$@"); echo \"退出码：\$?\"")" || die "ssh $target 失败：$out"
  printf '%s\n' "$out" | grep -q '^退出码：0$' || die "远程执行失败：
$out"
  printf '%s\n' "$out" | sed '$d'
}

# launchd：先卸再装，保证读到最新的 plist。
reload() {
  launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
  local i; for i in 1 2 3 4 5; do
    launchctl bootstrap "$DOMAIN" "$AGENTS/$1.plist" 2>/dev/null && return 0; sleep 1
  done
  launchctl bootstrap "$DOMAIN" "$AGENTS/$1.plist"
}

write_plist() { # label, args...
  local label="$1"; shift
  mkdir -p "$AGENTS"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n<key>Label</key><string>%s</string>\n<key>ProgramArguments</key><array>\n' "$label"
    local a; for a in "$@"; do printf '  <string>%s</string>\n' "$a"; done
    printf '</array>\n<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><true/>\n<key>ThrottleInterval</key><integer>30</integer>\n'
    printf '<key>StandardErrorPath</key><string>%s/%s.log</string>\n</dict></plist>\n' "$DIR" "$label"
  } > "$AGENTS/$label.plist.tmp"
  if cmp -s "$AGENTS/$label.plist.tmp" "$AGENTS/$label.plist" && launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    rm "$AGENTS/$label.plist.tmp"
  else
    mv "$AGENTS/$label.plist.tmp" "$AGENTS/$label.plist"; reload "$label"
  fi
}

ensure_sshd() {
  if [[ -d "$OLD_DIR" && ! -e "$DIR" ]]; then
    mkdir -p "$(dirname "$DIR")"; mv "$OLD_DIR" "$DIR"; log "状态目录从 $OLD_DIR 搬到 $DIR"
  fi
  mkdir -p "$DIR"; chmod 700 "$HOME/.ssh" "$DIR"
  [[ -f "$DIR/ssh_host_ed25519_key" ]] || ssh-keygen -q -t ed25519 -N '' -C "ssh-back@$ALIAS" -f "$DIR/ssh_host_ed25519_key"
  cat > "$DIR/sshd_config" <<EOF
# 由 mac-host 的 ssh-back.sh 生成，改了会被覆盖。
Port $SSHD_PORT
ListenAddress 127.0.0.1
HostKey $DIR/ssh_host_ed25519_key
PidFile $DIR/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers $ME
Subsystem sftp /usr/libexec/sftp-server
EOF
  touch "$AUTH"; chmod 600 "$AUTH"
  /usr/sbin/sshd -t -f "$DIR/sshd_config"
  write_plist "$SSHD_LABEL" /usr/sbin/sshd -D -f "$DIR/sshd_config" -E "$DIR/sshd.log"
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    nc -z -G 1 127.0.0.1 "$SSHD_PORT" 2>/dev/null && return 0; sleep 1
  done
  die "sshd 没有在 127.0.0.1:$SSHD_PORT 起来，看 $DIR/sshd.log"
}

# 远程：确保密钥、写 ~/.ssh/config 那一段和钉住的指纹，打出端口和公钥。参数：别名 端口(可空) 用户 主机公钥
REMOTE_SETUP='set -eu
alias="$1"; port="$2"; user="$3"; hostkey="$4"
if [ -z "$port" ]; then
  [ -n "${DEV_PORT_BASE:-}" ] || { echo "远程没有 DEV_PORT_BASE，用 --port 指定端口" >&2; exit 2; }
  port=$((DEV_PORT_BASE + 96))
fi
mkdir -p ~/.ssh; chmod 700 ~/.ssh
[ -f ~/.ssh/id_ed25519_back ] || ssh-keygen -q -t ed25519 -N "" -C "ssh-back@$(hostname -s)" -f ~/.ssh/id_ed25519_back
kh=~/.ssh/known_hosts.ssh-back; touch "$kh"
{ grep -v "^$alias " "$kh" || true; echo "$alias $hostkey"; } > "$kh.tmp"; mv "$kh.tmp" "$kh"
cfg=~/.ssh/config; touch "$cfg"
{
  echo "# >>> ssh-back ${alias}（由 ssh-back.sh 管理）"
  echo "Host $alias"
  echo "  HostName 127.0.0.1"
  echo "  Port $port"
  echo "  User $user"
  echo "  IdentityFile ~/.ssh/id_ed25519_back"
  echo "  IdentitiesOnly yes"
  echo "  HostKeyAlias $alias"
  echo "  UserKnownHostsFile ~/.ssh/known_hosts.ssh-back"
  echo "  StrictHostKeyChecking yes"
  echo "# <<< ssh-back $alias"
  awk -v a="$alias" "index(\$0, \"# >>> ssh-back \" a \"（\")==1{s=1} !s{print} index(\$0, \"# <<< ssh-back \" a)==1 && length(\$0)==length(\"# <<< ssh-back \" a){s=0}" "$cfg"
} > "$cfg.tmp"; mv "$cfg.tmp" "$cfg"; chmod 600 "$cfg"
echo "PORT $port"
echo "PUBKEY $(cut -d" " -f1,2 ~/.ssh/id_ed25519_back.pub)"
'

REMOTE_REMOVE='set -eu
alias="$1"
kh=~/.ssh/known_hosts.ssh-back
[ -f "$kh" ] && { grep -v "^$alias " "$kh" > "$kh.tmp" || true; mv "$kh.tmp" "$kh"; }
cfg=~/.ssh/config
[ -f "$cfg" ] && { awk -v a="$alias" "index(\$0, \"# >>> ssh-back \" a \"（\")==1{s=1} !s{print} index(\$0, \"# <<< ssh-back \" a)==1 && length(\$0)==length(\"# <<< ssh-back \" a){s=0}" "$cfg" > "$cfg.tmp"; mv "$cfg.tmp" "$cfg"; chmod 600 "$cfg"; }
true
'

set_auth_line() { # target, line(空=删掉)
  local marker=" ssh-back:$1"
  # 只删行尾正好是这个标记的行（felix@mac-studio 不会误删 felix@mac-studio2 的）。
  { awk -v m="$marker" 'length($0) < length(m) || substr($0, length($0)-length(m)+1) != m' "$AUTH"
    [[ -z "$2" ]] || printf '%s\n' "$2"; } > "$AUTH.tmp"
  mv "$AUTH.tmp" "$AUTH"; chmod 600 "$AUTH"
}

connect() {
  local target="$1" port="${2:-}"
  ensure_sshd
  log "sshd 在 127.0.0.1:$SSHD_PORT"
  local hostkey out rport pub label
  hostkey="$(cut -d' ' -f1,2 "$DIR/ssh_host_ed25519_key.pub")"
  out="$(remote "$target" "$REMOTE_SETUP" "$ALIAS" "$port" "$ME" "$hostkey")"
  rport="$(printf '%s\n' "$out" | sed -n 's/^PORT //p')"
  pub="$(printf '%s\n' "$out" | sed -n 's/^PUBKEY //p')"
  [[ -n "$rport" && -n "$pub" ]] || die "远程没打出端口或公钥：$out"
  set_auth_line "$target" "from=\"127.0.0.1,::1\",no-agent-forwarding $pub ssh-back:$target"
  log "远程公钥已授权，隧道端口 $target 上的 127.0.0.1:$rport"
  label="$(tunnel_label "$target")"
  write_plist "$label" /bin/bash "$SELF" --run "$target" "$rport"
  local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if remote "$target" 'ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" "echo BACK-OK" 2>&1 || true' "$ALIAS" | grep -q '^BACK-OK$'; then
      log "接通了：在 $target 上执行 ssh $ALIAS"; return 0
    fi
    sleep 2
  done
  die "隧道起了，但远程还连不回来。看 $DIR/$label.log（端口被占用时会写 remote port forwarding failed）"
}

# 远程：连 127.0.0.1:<端口>，10 秒内读到「SSH-2.0-」打 BANNER-OK，否则打 NO-BANNER 和原因。
REMOTE_PROBE='port="$1"
/usr/bin/perl -MIO::Socket::INET -e '\''
  $SIG{ALRM} = sub { print "NO-BANNER timeout\n"; exit };
  alarm 10;
  my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1", PeerPort => $ARGV[0], Timeout => 5)
    or do { print "NO-BANNER connect: $!\n"; exit };
  my $l = <$s>;
  print(defined $l && $l =~ /^SSH-2\.0-/ ? "BANNER-OK\n" : "NO-BANNER got: " . ($l // "eof") . "\n");
'\'' "$port"'

# 进程从网络收到的总字节数（nettop -n 不查 DNS，马上返回）。
bytes_in() { nettop -P -L 1 -n -x -p "$1" -J bytes_in </dev/null 2>/dev/null | awk -F, 'NR==2{print $2+0; f=1} END{if(!f) print 0}'; }

# launchd 跑的隧道：起 ssh -R，再定时从远程验证隧道端口真能连到本机 sshd。坏了就退出，launchd 30 秒后重起。
run_tunnel() {
  local target="$1" rport="$2" pid out fails=0
  trap - ERR; set +e
  /usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ControlMaster=no -o ControlPath=none \
    -R "127.0.0.1:$rport:127.0.0.1:$SSHD_PORT" "$target" &
  pid=$!
  trap 'kill "$pid" 2>/dev/null; exit 0' TERM INT
  log "隧道 ssh 进程 $pid，远程 127.0.0.1:$rport" >&2
  local before=0 now
  while kill -0 "$pid" 2>/dev/null; do
    before="$(bytes_in "$pid")"
    sleep "$PROBE_INTERVAL" & wait $!
    kill -0 "$pid" 2>/dev/null || break
    out="$(printf '%s' "$REMOTE_PROBE" | /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
      -o ControlMaster=no -o ControlPath=none "$target" "/bin/bash -c \"\$(cat)\" _ $rport" 2>&1)"
    now="$(bytes_in "$pid")"
    case "$out" in
      *BANNER-OK*) fails=0 ;;
      *NO-BANNER*)
        # 远程往电脑传大文件时（链路只有 1–2 Mbit/s），新连接排在后面，握手也会超时，但字节一直在进来，不算坏。
        if (( now - before >= BUSY_BYTES )); then
          fails=0; log "探测超时，但这 ${PROBE_INTERVAL} 秒收了 $(( (now - before) / 1024 )) KB，隧道忙，不算失败" >&2
        else
          fails=$((fails + 1)); log "探测失败 $fails/2，这 ${PROBE_INTERVAL} 秒只收了 $((now - before)) 字节：$(printf '%s' "$out" | grep NO-BANNER)" >&2
          if [[ $fails -ge 2 ]]; then log "隧道不通，杀掉重起" >&2; kill "$pid" 2>/dev/null; kill -CONT "$pid" 2>/dev/null; wait "$pid"; exit 1; fi
        fi ;;
      *) ;; # 远程本身连不上：隧道多半也断了，交给 ssh 的心跳判断，不算一次失败。
    esac
  done
  wait "$pid"; local rc=$?
  log "隧道 ssh 退出，退出码 $rc" >&2
  exit 1
}

remove() {
  local target="$1" label; label="$(tunnel_label "$target")"
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  rm -f "$AGENTS/$label.plist" "$DIR/$label.log"
  set_auth_line "$target" ""
  log "本机：隧道和授权已删"
  if remote "$target" "$REMOTE_REMOVE" "$ALIAS" >/dev/null; then log "远程：~/.ssh/config 那一段已删"
  else log "远程连不上，它的 ~/.ssh/config 里 ssh-back $ALIAS 那一段留着，下次连得上再执行一次"; fi
  if ! ls "$AGENTS"/ssh-back.tunnel.*.plist >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$SSHD_LABEL" 2>/dev/null || true
    rm -f "$AGENTS/$SSHD_LABEL.plist"
    log "没有别的隧道了，sshd 已停（主机密钥留在 $DIR）"
  fi
}

status() {
  local f label st args
  printf 'sshd   %s\n' "$(launchctl print "$DOMAIN/$SSHD_LABEL" 2>/dev/null | awk '/^\tstate =/{print $3; exit}' || true)"
  for f in "$AGENTS"/ssh-back.tunnel.*.plist; do
    [[ -e "$f" ]] || { echo "（没有隧道）"; return 0; }
    label="$(basename "$f" .plist)"
    st="$(launchctl print "$DOMAIN/$label" 2>/dev/null | awk '/^\tstate =/{print $3; exit}' || true)"
    args="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$f" | sed -e '1d' -e '$d' -e 's/^ *//')"
    # 参数是 /bin/bash <本脚本> --run <远程> <端口>；没有 --run 的是旧版直接跑 ssh 的，再执行一次接通就换成新的。
    if printf '%s\n' "$args" | grep -qx -- '--run'; then
      printf '%-24s 远程 127.0.0.1:%-12s %s\n' "$(printf '%s\n' "$args" | sed -n '/^--run$/{n;p;}')" \
        "$(printf '%s\n' "$args" | tail -1)" "${st:-not loaded}"
    else
      printf '%-24s 远程 %-22s %s（旧版，没有探测，再执行一次接通）\n' "$(printf '%s\n' "$args" | tail -1)" \
        "$(printf '%s\n' "$args" | sed -n 's/^127\.0\.0\.1:\([0-9]*\):.*/127.0.0.1:\1/p')" "${st:-not loaded}"
    fi
  done
}

case "${1:-}" in
  ""|-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  --status) status ;;
  --remove) [[ -n "${2:-}" ]] || die "用法：ssh-back.sh --remove <远程>"; remove "$2" ;;
  --run) [[ -n "${3:-}" ]] || die "用法（launchd 用）：ssh-back.sh --run <远程> <端口>"; run_tunnel "$2" "$3" ;;
  -*) die "不认识的参数 $1" ;;
  *) t="$1"; shift; p=""
     if [[ "${1:-}" == "--port" ]]; then [[ -n "${2:-}" ]] || die "--port 要跟端口号"; p="$2"; fi
     connect "$t" "$p" ;;
esac
