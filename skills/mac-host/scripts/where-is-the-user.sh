#!/bin/bash
# 判断人是不是坐在这台 Mac 跟前：打印 local 或 remote（后面跟原因）。给人看文件、放剪贴板之前先执行。
#   local  -> 可以用这台机器的桌面（open、pbcopy）。
#   remote -> 照 SKILL.md「给人看东西」：用 Orca 打开文件，文本写在回复里。
# 三条里任一条成立就是 remote：
#   - SSH 进来的会话（SSH_CONNECTION）；
#   - Orca 远程服务端开的终端（ORCA_SERVE_RUNTIME=orcad）：SSH_CONNECTION 是空的，人在别的电脑上；
#   - 这台机器的屏幕前登录的不是本人（/dev/console 的属主），或者没人登录（root）。
set -u
me=$(id -un)
if [[ -n "${SSH_CONNECTION:-}" ]]; then echo "remote: ssh session ($SSH_CONNECTION)"; exit 0; fi
if [[ "${ORCA_SERVE_RUNTIME:-}" == "orcad" ]]; then echo "remote: terminal served by orcad"; exit 0; fi
console=$(stat -f %Su /dev/console 2>/dev/null || echo unknown)
if [[ "$console" != "$me" ]]; then echo "remote: console belongs to $console, not $me"; exit 0; fi
echo local
