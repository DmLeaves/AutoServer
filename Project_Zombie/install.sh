#!/usr/bin/env bash
set -euo pipefail

# ====== 默认配置（写死，小白一键）======
PZ_USER="pz"
PZ_HOME="/home/${PZ_USER}"

PZ_SERVER_DIR="/opt/pzserver"
STEAMCMD_DIR="/opt/steamcmd"
STEAMCMD="${STEAMCMD_DIR}/steamcmd.sh"

ZOMBOID_DIR="${PZ_HOME}/Zomboid"
SAVES_DIR="${ZOMBOID_DIR}/Saves/Multiplayer"

SERVER_NAME="servertest"

BACKUP_DIR="/opt/pzbackup"
RESTORE_OLD_DIR="/opt/pzbackup/restore_old"
KEEP_BACKUPS=10

SERVICE_NAME="pzserver"
BACKUP_CRON_FILE="/etc/cron.d/${SERVICE_NAME}-backup"

# ====== 防火墙端口（PZ 常用默认）======
PZ_MAIN_PORT="16261"
PZ_EXTRA_PORT_RANGE="16262:16272"  # UDP 端口段（按需改大/改小）

# ====== 工具函数 ======
say()  { echo -e "\033[1;32m[pz-installer]\033[0m $*"; }
warn() { echo -e "\033[1;33m[pz-installer]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[pz-installer]\033[0m $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请用 root 执行：sudo bash $0 [install|uninstall]"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

remove_backup_cron() {
  rm -f "$BACKUP_CRON_FILE"
}

# ====== 安装依赖 ======
install_deps() {
  say "安装依赖..."
  if has_cmd apt-get; then
    apt-get update -y
    apt-get install -y curl tar ca-certificates unzip tmux \
      lib32gcc-s1 || apt-get install -y curl tar ca-certificates unzip tmux lib32gcc1
  elif has_cmd dnf; then
    dnf install -y curl tar ca-certificates unzip tmux glibc.i686 libstdc++.i686
  elif has_cmd yum; then
    yum install -y curl tar ca-certificates unzip tmux glibc.i686 libstdc++.i686
  else
    die "未识别包管理器（apt/dnf/yum），请手动安装依赖：curl tar ca-certificates unzip 以及 32 位库"
  fi
}

# ====== 用户/目录 ======
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
  mkdir -p "$PZ_SERVER_DIR" "$STEAMCMD_DIR" "$SAVES_DIR" "$BACKUP_DIR" "$RESTORE_OLD_DIR"
  chown -R "$PZ_USER:$PZ_USER" "$PZ_HOME" "$ZOMBOID_DIR" 2>/dev/null || true
}

# ====== SteamCMD ======
install_steamcmd() {
  if [[ -x "$STEAMCMD" ]]; then
    say "SteamCMD 已安装：$STEAMCMD"
    return
  fi
  say "安装 SteamCMD 到：$STEAMCMD_DIR"
  cd "$STEAMCMD_DIR"
  curl -fsSL -o steamcmd_linux.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
  tar -xzf steamcmd_linux.tar.gz
  rm -f steamcmd_linux.tar.gz
  chmod +x "$STEAMCMD"
}

# ====== PZ 服务端 ======
install_pz_server() {
  say "安装/更新 Project Zomboid Dedicated Server 到：$PZ_SERVER_DIR"
  "$STEAMCMD" +force_install_dir "$PZ_SERVER_DIR" +login anonymous +app_update 380870 -beta unstable validate +quit
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
  [[ -n "$f" ]] || die "找不到 start-server.sh（请检查 $PZ_SERVER_DIR 是否正确安装）"
  echo "$f"
}

# ====== systemd ======
install_systemd() {
  local start_sh
  start_sh="$(detect_start_script)"

  say "写入 systemd 服务：/etc/systemd/system/${SERVICE_NAME}.service"
  cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Project Zomboid Dedicated Server (${SERVER_NAME})
After=network.target

[Service]
Type=simple
User=${PZ_USER}
WorkingDirectory=${PZ_SERVER_DIR}
Environment=HOME=${PZ_HOME}
ExecStart=/bin/bash -lc '${start_sh} -servername ${SERVER_NAME}'
Restart=on-failure
RestartSec=10
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
}

# ====== pzctl ======
install_pzctl() {
  say "安装控制命令：/usr/local/bin/pzctl"
  cat >/usr/local/bin/pzctl <<'PZCTL_EOF'
#!/usr/bin/env bash
set -euo pipefail

PZ_USER="pz"
PZ_HOME="/home/${PZ_USER}"
ZOMBOID_DIR="${PZ_HOME}/Zomboid"
SAVES_DIR="${ZOMBOID_DIR}/Saves/Multiplayer"
SERVER_NAME="servertest"

BACKUP_DIR="/opt/pzbackup"
RESTORE_OLD_DIR="/opt/pzbackup/restore_old"
KEEP_BACKUPS=10

SERVICE_NAME="pzserver"
BACKUP_CRON_FILE="/etc/cron.d/${SERVICE_NAME}-backup"
BACKUP_LOG_FILE="/var/log/${SERVICE_NAME}-backup.log"
DEFAULT_BACKUP_INTERVAL="6h"

say()  { echo -e "\033[1;32m[pzctl]\033[0m $*"; }
warn() { echo -e "\033[1;33m[pzctl]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[pzctl]\033[0m $*" >&2; exit 1; }

ensure_dirs() { mkdir -p "$SAVES_DIR" "$BACKUP_DIR" "$RESTORE_OLD_DIR"; }
need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请用 root 执行此操作"
  fi
}

do_start()   { systemctl start  "${SERVICE_NAME}.service"; }
do_stop()    { systemctl stop   "${SERVICE_NAME}.service"; }
do_restart() { systemctl restart "${SERVICE_NAME}.service"; }
do_status()  { systemctl status "${SERVICE_NAME}.service" -n 80 --no-pager; }
do_logs()    { journalctl -u "${SERVICE_NAME}.service" -f; }

backup_name() { echo "pz-${SERVER_NAME}-$(date +'%F_%H%M').tar.gz"; }

cleanup_backups_fifo() {
  ls -1t "$BACKUP_DIR"/pz-"$SERVER_NAME"-*.tar.gz 2>/dev/null | tail -n +"$((KEEP_BACKUPS+1))" | xargs -r rm -f
}

do_backup() {
  ensure_dirs
  local src="$SAVES_DIR/$SERVER_NAME"
  [[ -d "$src" ]] || die "找不到存档目录：$src"
  local out="$BACKUP_DIR/$(backup_name)"
  say "备份：$src -> $out（不停服）"
  tar -czf "$out" -C "$SAVES_DIR" "$SERVER_NAME"
  cleanup_backups_fifo
  say "备份完成：$out"
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
  cleanup_backups_fifo
  say "备份完成：$out"
}

parse_backup_interval() {
  local interval="$1"

  if [[ "$interval" =~ ^([1-9][0-9]*)([mhd])$ ]]; then
    local value="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"

    case "$unit" in
      m)
        (( value <= 59 )) || die "分钟间隔必须在 1-59 之间"
        echo "*/${value} * * * *"
        ;;
      h)
        (( value <= 23 )) || die "小时间隔必须在 1-23 之间"
        echo "0 */${value} * * *"
        ;;
      d)
        (( value <= 31 )) || die "天间隔必须在 1-31 之间"
        echo "0 0 */${value} * *"
        ;;
    esac
    return
  fi

  die "间隔格式无效：${interval}（示例：30m / 6h / 2d）"
}

write_backup_cron() {
  local cron_expr="$1"

  cat >"$BACKUP_CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

${cron_expr} root /usr/local/bin/pzctl backup >"${BACKUP_LOG_FILE}" 2>&1
EOF
  chmod 0644 "$BACKUP_CRON_FILE"
}

do_cron_status() {
  if [[ -f "$BACKUP_CRON_FILE" ]]; then
    say "当前已启用定时备份：$BACKUP_CRON_FILE"
    cat "$BACKUP_CRON_FILE"
  else
    warn "当前未启用定时备份"
  fi
}

do_cron_enable() {
  need_root

  local interval="${1:-}"
  if [[ -z "$interval" ]]; then
    read -r -p "输入备份间隔（默认 ${DEFAULT_BACKUP_INTERVAL}，如 30m/6h/2d）: " interval
    interval="${interval:-$DEFAULT_BACKUP_INTERVAL}"
  fi

  local cron_expr
  cron_expr="$(parse_backup_interval "$interval")"
  write_backup_cron "$cron_expr"
  say "已开启定时备份：${interval}（${cron_expr}）"
  say "日志：${BACKUP_LOG_FILE}"
}

do_cron_disable() {
  need_root

  if [[ -f "$BACKUP_CRON_FILE" ]]; then
    rm -f "$BACKUP_CRON_FILE"
    say "已关闭定时备份"
  else
    warn "定时备份本来就没有开启"
  fi
}

do_cron_menu() {
  while true; do
    echo
    echo "==== 定时备份 ===="
    echo "1) 查看状态"
    echo "2) 开启/更新"
    echo "3) 关闭"
    echo "0) 返回"
    read -r -p "请选择: " c
    case "$c" in
      1) do_cron_status ;;
      2) do_cron_enable ;;
      3) do_cron_disable ;;
      0) return 0 ;;
      *) echo "无效选择" ;;
    esac
  done
}

restore_from_pkg() {
  local pkg="$1"
  [[ -f "$pkg" ]] || die "找不到备份文件：$pkg"
  ensure_dirs

  local ts old_dir
  ts="$(date +%F_%H%M%S)"
  old_dir="$RESTORE_OLD_DIR/${SERVER_NAME}_$ts"
  mkdir -p "$old_dir"

  say "[1/5] 停止服务"
  systemctl stop "${SERVICE_NAME}.service" || true

  say "[2/5] 归档当前存档到：$old_dir"
  if [[ -d "$SAVES_DIR/$SERVER_NAME" ]]; then
    mv "$SAVES_DIR/$SERVER_NAME" "$old_dir/"
  fi

  say "[3/5] 解压恢复：$pkg -> $SAVES_DIR"
  tar -xzf "$pkg" -C "$SAVES_DIR"

  say "[4/5] 修正权限"
  chown -R "${PZ_USER}:${PZ_USER}" "$SAVES_DIR/$SERVER_NAME" 2>/dev/null || true

  say "[5/5] 启动服务"
  systemctl start "${SERVICE_NAME}.service" || true

  say "恢复完成：$(basename "$pkg")"
  say "旧存档保留：$old_dir"
}

do_restore_menu() {
  ensure_dirs
  shopt -s nullglob
  mapfile -t files < <(ls -1t "$BACKUP_DIR"/pz-"$SERVER_NAME"-*.tar.gz 2>/dev/null || true)
  [[ ${#files[@]} -gt 0 ]] || die "未找到备份：$BACKUP_DIR/pz-${SERVER_NAME}-*.tar.gz"

  echo "==== 可用备份（新 -> 旧）===="
  for i in "${!files[@]}"; do
    local n f
    n=$((i+1))
    f="${files[$i]}"
    printf "%2d) %-40s  %8s  %s\n" \
      "$n" \
      "$(basename "$f")" \
      "$(du -h "$f" | awk '{print $1}')" \
      "$(date -r "$f" '+%F %T')"
  done

  echo
  read -r -p "输入要恢复的序号（1-${#files[@]}），或 q 退出: " choice
  [[ "$choice" =~ ^[Qq]$ ]] && { echo "已退出。"; exit 0; }
  [[ "$choice" =~ ^[0-9]+$ ]] || die "输入无效：$choice"
  local idx=$((choice-1))
  (( idx >= 0 && idx < ${#files[@]} )) || die "序号超出范围：$choice"

  local pkg="${files[$idx]}"
  echo "将恢复：$pkg"
  read -r -p "确认执行？输入 yes 继续: " ok
  [[ "$ok" == "yes" ]] || { echo "已取消。"; exit 0; }
  restore_from_pkg "$pkg"
}

usage() {
  cat <<'EOF'
用法：pzctl <command>

运行管理：
  pzctl start|stop|restart|status|logs

备份/回档：
  pzctl backup           在线备份（不停服）
  pzctl backup-stop      停服备份（更一致）
  pzctl restore          菜单选择备份并恢复
  pzctl cron             定时备份菜单
  pzctl cron-on [6h]     开启/更新定时备份
  pzctl cron-off         关闭定时备份
  pzctl cron-status      查看定时备份状态
  pzctl menu             交互式菜单

ini 配置你手动放到：
  /home/pz/Zomboid/Server/
EOF
}

do_menu() {
  while true; do
    echo
    echo "==== PZ 控制面板 ===="
    echo "1) 状态 status"
    echo "2) 启动 start"
    echo "3) 停止 stop"
    echo "4) 重启 restart"
    echo "5) 跟踪日志 logs"
    echo "6) 在线备份 backup"
    echo "7) 停服备份 backup-stop"
    echo "8) 回档恢复 restore"
    echo "9) 定时备份 cron"
    echo "0) 退出"
    read -r -p "请选择: " c
    case "$c" in
      1) do_status ;;
      2) do_start ;;
      3) do_stop ;;
      4) do_restart ;;
      5) do_logs ;;
      6) do_backup ;;
      7) do_backup_stop ;;
      8) do_restore_menu ;;
      9) do_cron_menu ;;
      0) exit 0 ;;
      *) echo "无效选择" ;;
    esac
  done
}

cmd="${1:-}"
shift || true
case "$cmd" in
  menu|"") do_menu ;;
  start) do_start ;;
  stop) do_stop ;;
  restart) do_restart ;;
  status) do_status ;;
  logs) do_logs ;;
  backup) do_backup ;;
  backup-stop) do_backup_stop ;;
  restore) do_restore_menu ;;
  cron) do_cron_menu ;;
  cron-on) do_cron_enable "${1:-}" ;;
  cron-off) do_cron_disable ;;
  cron-status) do_cron_status ;;
  help|-h|--help) usage ;;
  *) echo "未知命令：$cmd"; usage; exit 1 ;;
esac
PZCTL_EOF
  chmod +x /usr/local/bin/pzctl
}

# ====== 防火墙放行 ======
fw_allow() {
  say "配置防火墙放行端口（UDP ${PZ_MAIN_PORT} 和 ${PZ_EXTRA_PORT_RANGE}）..."

  # Ubuntu/Debian 常见：ufw
  if has_cmd ufw; then
    # ufw 未启用也没关系，规则先加进去
    ufw allow "${PZ_MAIN_PORT}/udp" || true
    ufw allow "${PZ_EXTRA_PORT_RANGE}/udp" || true
    warn "检测到 ufw：已添加规则。若 ufw 未启用，请自行执行：ufw enable"
    return
  fi

  # CentOS/RHEL 常见：firewalld
  if has_cmd firewall-cmd; then
    # firewalld 可能没启动，这里尽量处理
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${PZ_MAIN_PORT}/udp" || true
    firewall-cmd --permanent --add-port="${PZ_EXTRA_PORT_RANGE}/udp" || true
    firewall-cmd --reload || true
    say "检测到 firewalld：已添加规则并 reload"
    return
  fi

  warn "未检测到 ufw/firewalld，已跳过自动放行。请手动开放 UDP ${PZ_MAIN_PORT} 和 ${PZ_EXTRA_PORT_RANGE}"
}

fw_revert() {
  say "尝试回滚防火墙规则..."
  if has_cmd ufw; then
    ufw delete allow "${PZ_MAIN_PORT}/udp" >/dev/null 2>&1 || true
    ufw delete allow "${PZ_EXTRA_PORT_RANGE}/udp" >/dev/null 2>&1 || true
    say "ufw：已尝试删除规则（若不存在会忽略）"
    return
  fi
  if has_cmd firewall-cmd; then
    firewall-cmd --permanent --remove-port="${PZ_MAIN_PORT}/udp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-port="${PZ_EXTRA_PORT_RANGE}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    say "firewalld：已尝试删除规则（若不存在会忽略）"
    return
  fi
  warn "未检测到 ufw/firewalld，无法自动回滚规则。"
}

# ====== 卸载 ======
do_uninstall() {
  need_root
  warn "即将卸载以下内容："
  echo "  - systemd 服务：${SERVICE_NAME}.service"
  echo "  - cron：${BACKUP_CRON_FILE}"
  echo "  - 目录：${PZ_SERVER_DIR} ${STEAMCMD_DIR} ${BACKUP_DIR}"
  echo "  - 命令：/usr/local/bin/pzctl"
  echo "  - 用户：${PZ_USER}（含家目录 ${PZ_HOME}）"
  echo "  - 防火墙规则：UDP ${PZ_MAIN_PORT} 和 ${PZ_EXTRA_PORT_RANGE}（尽量回滚）"
  echo

  read -r -p "确认卸载？输入 yes 继续: " ok
  [[ "$ok" == "yes" ]] || { echo "已取消。"; exit 0; }

  say "停止并禁用服务..."
  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload || true

  say "删除文件/目录..."
  remove_backup_cron
  rm -f /usr/local/bin/pzctl
  rm -rf "$PZ_SERVER_DIR" "$STEAMCMD_DIR" "$BACKUP_DIR"

  fw_revert

  say "删除用户（含家目录）..."
  if id -u "$PZ_USER" >/dev/null 2>&1; then
    # --remove 会删家目录；用于测试还原环境更干净
    userdel -r "$PZ_USER" >/dev/null 2>&1 || warn "删除用户失败（可能有进程占用或目录异常），请手动检查：userdel -r $PZ_USER"
  else
    warn "用户不存在：$PZ_USER"
  fi

  say "卸载完成。"
}

post_hint() {
  cat <<EOF

==================== 安装完成 ====================

服务：
  systemctl start ${SERVICE_NAME}
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f

控制面板：
  pzctl menu
  （定时备份可在菜单里手动开启）

ini 配置（你手动放）：
  ${ZOMBOID_DIR}/Server/
  （通常是 servertest.ini / servertest_SandboxVars.lua 等）

默认服务器名（存档目录名）：
  ${SERVER_NAME}

存档目录：
  ${SAVES_DIR}/${SERVER_NAME}

备份目录：
  ${BACKUP_DIR}

防火墙（已尝试放行）：
  UDP ${PZ_MAIN_PORT}
  UDP ${PZ_EXTRA_PORT_RANGE}

卸载（用于测试还原环境）：
  sudo bash install.sh uninstall

=================================================

EOF
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
  chown -R "$PZ_USER:$PZ_USER" "$PZ_HOME" "$ZOMBOID_DIR" 2>/dev/null || true
  say "完成。"
  post_hint
}

main() {
  local cmd="${1:-install}"
  shift || true
  case "$cmd" in
    install)
      [[ $# -eq 0 ]] || die "install 不接受额外参数，请安装后用 pzctl 菜单手动开启定时备份"
      do_install
      ;;
    uninstall)
      [[ $# -eq 0 ]] || die "uninstall 不接受额外参数"
      do_uninstall
      ;;
    -h|--help|help)
      cat <<EOF
Usage:
  sudo bash install.sh install
  sudo bash install.sh uninstall
用法：
  sudo bash install.sh install     # 默认：一键安装
  sudo bash install.sh uninstall   # 卸载（用于测试还原环境）
EOF
      ;;
    *) die "未知命令：$cmd（用 install / uninstall）" ;;
  esac
}

main "$@"
