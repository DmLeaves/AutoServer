#!/usr/bin/env bash
set -euo pipefail

# ========= 基本配置（可改） =========
PZ_USER="pz"
PZ_HOME="/home/${PZ_USER}"

PZ_SERVER_DIR="/opt/pzserver"
STEAMCMD_DIR="/opt/steamcmd"
STEAMCMD="${STEAMCMD_DIR}/steamcmd.sh"

SERVER_NAME="servertest"

ZOMBOID_DIR="${PZ_HOME}/Zomboid"
SERVER_CFG_DIR="${ZOMBOID_DIR}/Server"
SAVES_DIR="${ZOMBOID_DIR}/Saves/Multiplayer"

BACKUP_DIR="/opt/pzbackup"
KEEP_BACKUPS=10

SERVICE_NAME="pzserver"
BACKUP_CRON_FILE="/etc/cron.d/${SERVICE_NAME}-backup"
BACKUP_LOG_FILE="/var/log/${SERVICE_NAME}-backup.log"

# 网络端口（默认推荐）
PZ_UDP_RANGE="16261:16290"   # UDP 端口段
PZ_TCP_PORT="16261"          # TCP 可选（服务器浏览/查询场景有时用到）

# B42 分支（默认跟随 unstable）
PZ_APPID="380870"
PZ_BRANCH_ARGS=(-beta unstable)   # 如果以后 B42 转正，改成：PZ_BRANCH_ARGS=()

# ========= 工具函数 =========
say()  { echo -e "\033[1;32m[pz]\033[0m $*"; }
warn() { echo -e "\033[1;33m[pz]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[pz]\033[0m $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请用 root 执行：sudo bash $0 [install|uninstall]"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ========= 依赖安装 =========
install_deps() {
  say "安装依赖..."
  if has_cmd apt-get; then
    apt-get update -y
    # 尽量启用 i386（某些系统 steamcmd/库需要）
    dpkg --add-architecture i386 >/dev/null 2>&1 || true
    apt-get update -y
    apt-get install -y curl wget tar ca-certificates unzip tmux \
      lib32gcc-s1 libstdc++6:i386 || true
    # 再兜底一次（不同 Ubuntu 版本包名略有差异）
    apt-get install -y curl wget tar ca-certificates unzip tmux lib32gcc-s1 || true
  elif has_cmd dnf; then
    dnf install -y curl wget tar ca-certificates unzip tmux glibc.i686 libstdc++.i686
  elif has_cmd yum; then
    yum install -y curl wget tar ca-certificates unzip tmux glibc.i686 libstdc++.i686
  else
    die "未识别包管理器（apt/dnf/yum），请手动安装：curl wget tar ca-certificates unzip + 32位运行库"
  fi
}

# ========= 用户/目录 =========
ensure_user() {
  if id -u "$PZ_USER" >/dev/null 2>&1; then
    say "用户已存在：$PZ_USER"
  else
    say "创建用户：$PZ_USER"
    useradd -m -s /bin/bash "$PZ_USER"
  fi
}

ensure_dirs() {
  say "创建目录..."
  mkdir -p "$PZ_SERVER_DIR" "$STEAMCMD_DIR" "$BACKUP_DIR" \
           "$ZOMBOID_DIR" "$SERVER_CFG_DIR" "$SAVES_DIR"

  # 关键：让 pz 拥有服务器目录（避免 workshop/存档混写）
  chown -R "$PZ_USER:$PZ_USER" "$PZ_HOME" "$ZOMBOID_DIR" "$PZ_SERVER_DIR" "$STEAMCMD_DIR" "$BACKUP_DIR" 2>/dev/null || true
}

# ========= SteamCMD 安装 =========
install_steamcmd() {
  if [[ -x "$STEAMCMD" ]]; then
    say "SteamCMD 已存在：$STEAMCMD"
    return
  fi
  say "安装 SteamCMD 到：$STEAMCMD_DIR"
  cd "$STEAMCMD_DIR"
  wget -O steamcmd_linux.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
  tar -xzf steamcmd_linux.tar.gz
  rm -f steamcmd_linux.tar.gz
  chmod +x "$STEAMCMD"
  chown -R "$PZ_USER:$PZ_USER" "$STEAMCMD_DIR" 2>/dev/null || true
}

# ========= 安装/更新 PZ Dedicated Server（B42） =========
install_pz_server() {
  say "安装/更新 Project Zomboid Dedicated Server 到：$PZ_SERVER_DIR（B42 分支）"
  # 必须：force_install_dir 在 login 前（你之前踩的坑）
  "$STEAMCMD" \
    +force_install_dir "$PZ_SERVER_DIR" \
    +login anonymous \
    +app_update "$PZ_APPID" "${PZ_BRANCH_ARGS[@]}" validate \
    +quit

  chown -R "$PZ_USER:$PZ_USER" "$PZ_SERVER_DIR" 2>/dev/null || true
}

detect_start_script() {
  if [[ -x "$PZ_SERVER_DIR/start-server.sh" ]]; then
    echo "$PZ_SERVER_DIR/start-server.sh"; return
  fi
  if [[ -x "$PZ_SERVER_DIR/linux/start-server.sh" ]]; then
    echo "$PZ_SERVER_DIR/linux/start-server.sh"; return
  fi
  local f
  f="$(find "$PZ_SERVER_DIR" -maxdepth 4 -type f -name 'start-server.sh' -perm -111 2>/dev/null | head -n1 || true)"
  [[ -n "$f" ]] || die "找不到 start-server.sh（请检查 $PZ_SERVER_DIR 安装是否成功）"
  echo "$f"
}

# ========= systemd 服务 =========
install_systemd() {
  local start_sh
  start_sh="$(detect_start_script)"

  say "写入 systemd：/etc/systemd/system/${SERVICE_NAME}.service"
  cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Project Zomboid Dedicated Server (${SERVER_NAME})
After=network.target

[Service]
Type=simple
User=${PZ_USER}
WorkingDirectory=${PZ_SERVER_DIR}
Environment=HOME=${PZ_HOME}
Environment=SteamAppId=108600
ExecStart=/bin/bash ${start_sh} -servername ${SERVER_NAME}
Restart=on-failure
RestartSec=10
KillSignal=SIGINT
TimeoutStopSec=60
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
}

# ========= pzctl（管理命令） =========
install_pzctl() {
  say "安装 pzctl：/usr/local/bin/pzctl"
  cat >/usr/local/bin/pzctl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PZ_USER="pz"
PZ_HOME="/home/${PZ_USER}"
ZOMBOID_DIR="${PZ_HOME}/Zomboid"
SAVES_DIR="${ZOMBOID_DIR}/Saves/Multiplayer"
SERVER_CFG_DIR="${ZOMBOID_DIR}/Server"
SERVER_NAME="servertest"

BACKUP_DIR="/opt/pzbackup"
KEEP_BACKUPS=10

SERVICE_NAME="pzserver"
BACKUP_CRON_FILE="/etc/cron.d/${SERVICE_NAME}-backup"
BACKUP_LOG_FILE="/var/log/${SERVICE_NAME}-backup.log"

say()  { echo -e "\033[1;32m[pzctl]\033[0m $*"; }
warn() { echo -e "\033[1;33m[pzctl]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[pzctl]\033[0m $*" >&2; exit 1; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 执行"; }
ensure_dirs() { mkdir -p "$SAVES_DIR" "$SERVER_CFG_DIR" "$BACKUP_DIR"; }

do_start()   { systemctl start  "${SERVICE_NAME}.service"; }
do_stop()    { systemctl stop   "${SERVICE_NAME}.service"; }
do_restart() { systemctl restart "${SERVICE_NAME}.service"; }
do_status()  { systemctl status "${SERVICE_NAME}.service" -n 80 --no-pager; }
do_logs()    { journalctl -u "${SERVICE_NAME}.service" -f; }

backup_name() { echo "pz-${SERVER_NAME}-$(date +'%F_%H%M').tar.gz"; }

cleanup_backups() {
  ls -1t "$BACKUP_DIR"/pz-"$SERVER_NAME"-*.tar.gz 2>/dev/null | tail -n +"$((KEEP_BACKUPS+1))" | xargs -r rm -f
}

do_backup() {
  ensure_dirs
  local src="$SAVES_DIR/$SERVER_NAME"
  [[ -d "$src" ]] || die "找不到存档目录：$src（先启动一次服务器生成世界）"
  local out="$BACKUP_DIR/$(backup_name)"
  say "在线备份（不停服）：$src -> $out"
  tar -czf "$out" -C "$SAVES_DIR" "$SERVER_NAME"
  cleanup_backups
  say "完成：$out"
}

do_backup_stop() {
  ensure_dirs
  local src="$SAVES_DIR/$SERVER_NAME"
  [[ -d "$src" ]] || die "找不到存档目录：$src"
  say "停服备份（更一致）"
  systemctl stop "${SERVICE_NAME}.service" || true
  local out="$BACKUP_DIR/$(backup_name)"
  tar -czf "$out" -C "$SAVES_DIR" "$SERVER_NAME"
  systemctl start "${SERVICE_NAME}.service" || true
  cleanup_backups
  say "完成：$out"
}

# cron：每天 04:00 备份（你也可以自行改）
cron_enable_daily() {
  need_root
  cat >"$BACKUP_CRON_FILE" <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * * root /usr/local/bin/pzctl backup >>"${BACKUP_LOG_FILE}" 2>&1
CRON
  chmod 0644 "$BACKUP_CRON_FILE"
  say "已开启每天 04:00 自动备份：$BACKUP_CRON_FILE"
}

cron_disable() {
  need_root
  rm -f "$BACKUP_CRON_FILE"
  say "已关闭自动备份"
}

usage() {
  cat <<USAGE
用法：pzctl <cmd>

服务：
  pzctl start|stop|restart|status|logs

备份：
  pzctl backup            在线备份（不停服）
  pzctl backup-stop       停服备份（更一致）

定时备份：
  pzctl cron-on           每天 04:00 自动备份
  pzctl cron-off          关闭自动备份

配置文件目录：
  ${SERVER_CFG_DIR}/
USAGE
}

cmd="${1:-}"
case "$cmd" in
  start) do_start ;;
  stop) do_stop ;;
  restart) do_restart ;;
  status) do_status ;;
  logs) do_logs ;;
  backup) do_backup ;;
  backup-stop) do_backup_stop ;;
  cron-on) cron_enable_daily ;;
  cron-off) cron_disable ;;
  help|-h|--help|"") usage ;;
  *) die "未知命令：$cmd（用 pzctl help 查看）" ;;
esac
EOF
  chmod +x /usr/local/bin/pzctl
}

# ========= 防火墙放行 =========
fw_allow() {
  say "放行端口：UDP ${PZ_UDP_RANGE}（必要），TCP ${PZ_TCP_PORT}（可选）"

  if has_cmd ufw; then
    ufw allow "${PZ_UDP_RANGE}/udp" || true
    ufw allow "${PZ_TCP_PORT}/tcp" || true
    warn "已写入 ufw 规则（若 ufw 未启用，请自行 ufw enable）。云安全组也要放行同样端口。"
    return
  fi

  if has_cmd firewall-cmd; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${PZ_UDP_RANGE}/udp" || true
    firewall-cmd --permanent --add-port="${PZ_TCP_PORT}/tcp" || true
    firewall-cmd --reload || true
    say "firewalld：已放行端口"
    return
  fi

  warn "未检测到 ufw/firewalld，请手动放行：UDP ${PZ_UDP_RANGE}（云安全组也要放行）"
}

# ========= 第一次启动生成配置（用 pz 用户） =========
first_run_hint() {
  cat <<EOF

==================== 下一步（很重要） ====================

1) 先启动一次生成世界/配置（第一次会要求输入 admin 密码）：
   systemctl start ${SERVICE_NAME}

2) 配置文件目录（以后覆盖旧配置放这里）：
   ${SERVER_CFG_DIR}/
   例如：
     ${SERVER_NAME}.ini
     ${SERVER_NAME}_SandboxVars.lua
     ${SERVER_NAME}_spawnpoints.lua
     ${SERVER_NAME}_spawnregions.lua

3) 存档目录：
   ${SAVES_DIR}/${SERVER_NAME}

4) 定时备份（每天 04:00）：
   pzctl cron-on

5) 看日志：
   journalctl -u ${SERVICE_NAME} -f

提示：云服务器还必须在“云安全组”放行 UDP ${PZ_UDP_RANGE}

==========================================================
EOF
}

# ========= 卸载 =========
do_uninstall() {
  need_root
  warn "将卸载：服务、SteamCMD、服务器目录、备份目录、pz 用户、cron"
  read -r -p "确认卸载？输入 yes 继续: " ok
  [[ "$ok" == "yes" ]] || { echo "已取消"; exit 0; }

  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload || true

  rm -f /usr/local/bin/pzctl
  rm -f "$BACKUP_CRON_FILE"

  rm -rf "$PZ_SERVER_DIR" "$STEAMCMD_DIR" "$BACKUP_DIR"

  if id -u "$PZ_USER" >/dev/null 2>&1; then
    userdel -r "$PZ_USER" >/dev/null 2>&1 || true
  fi

  say "卸载完成"
}

do_install() {
  need_root
  install_deps
  ensure_user
  ensure_dirs
  install_steamcmd
  install_pz_server
  install_systemd
  install_pzctl
  fw_allow
  say "安装完成"
  first_run_hint
}

main() {
  local cmd="${1:-install}"
  case "$cmd" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    help|-h|--help)
      echo "用法：sudo bash $0 install|uninstall"
      ;;
    *) die "未知命令：$cmd（install/uninstall）" ;;
  esac
}

main "${1:-install}"