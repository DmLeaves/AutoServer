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
RESTORE_OLD_DIR="${BACKUP_DIR}/restore_old"
KEEP_BACKUPS=10

SERVICE_NAME="pzserver"
BACKUP_CRON_FILE="/etc/cron.d/${SERVICE_NAME}-backup"
BACKUP_LOG_FILE="/var/log/${SERVICE_NAME}-backup.log"
DEFAULT_BACKUP_INTERVAL="6h"

# 网络端口（默认推荐）
PZ_UDP_RANGE="16261:16290"   # UDP 端口段
PZ_TCP_PORT="16261"          # TCP 可选（服务器浏览/查询场景有时用到）

# B42 分支（默认跟随 unstable）
PZ_APPID="380870"
PZ_BRANCH_ARGS=(-beta unstable)   # 如果以后 B42 转正，改成：PZ_BRANCH_ARGS=()

# 远程自更新（installVx.sh）
SELF_UPDATE_API_URL="https://api.github.com/repos/DmLeaves/AutoServer/contents/Project_Zombie"
SELF_UPDATE_RAW_BASE_URL="https://raw.githubusercontent.com/DmLeaves/AutoServer/main/Project_Zombie"

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

remove_backup_cron() {
  rm -f "$BACKUP_CRON_FILE"
}

latest_install_script_name_from_json() {
  local json="$1"
  printf '%s\n' "$json" \
    | tr ',' '\n' \
    | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(installV[0-9][0-9]*\.sh\)".*/\1/p' \
    | sort -V \
    | tail -n1
}

get_latest_install_script_url() {
  has_cmd curl || die "缺少 curl，无法执行远程更新"

  local json latest_name
  json="$(curl -fsSL "$SELF_UPDATE_API_URL")" || die "获取远程脚本列表失败：$SELF_UPDATE_API_URL"
  latest_name="$(latest_install_script_name_from_json "$json")"
  [[ -n "$latest_name" ]] || die "远程未找到 installVx.sh"

  echo "${SELF_UPDATE_RAW_BASE_URL}/${latest_name}"
}

run_as_pz() {
  if has_cmd sudo; then
    sudo -u "$PZ_USER" -H "$@"
    return
  fi

  if has_cmd runuser; then
    HOME="$PZ_HOME" runuser -u "$PZ_USER" -- "$@"
    return
  fi

  die "需要 sudo 或 runuser 才能切换到 ${PZ_USER} 执行"
}

# ========= 依赖安装 =========
install_deps() {
  say "安装依赖..."
  if has_cmd apt-get; then
    apt-get update -y
    dpkg --add-architecture i386 >/dev/null 2>&1 || true
    apt-get update -y
    apt-get install -y curl wget tar ca-certificates unzip tmux \
      lib32gcc-s1 libstdc++6:i386 || true
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
  mkdir -p "$PZ_SERVER_DIR" "$STEAMCMD_DIR" "$BACKUP_DIR" "$RESTORE_OLD_DIR" \
           "$ZOMBOID_DIR" "$SERVER_CFG_DIR" "$SAVES_DIR"

  chown -R "$PZ_USER:$PZ_USER" \
    "$PZ_HOME" "$ZOMBOID_DIR" "$PZ_SERVER_DIR" "$STEAMCMD_DIR" "$BACKUP_DIR" 2>/dev/null || true
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
  say "安装/更新 Project Zomboid Dedicated Server 到：$PZ_SERVER_DIR（B42 unstable）"
  run_as_pz "$STEAMCMD" \
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
  say "已设置开机自启；首次不要直接用 systemd，请先按安装提示手动前台初始化一次"
}

# ========= pzctl（管理命令） =========
install_pzctl() {
  say "安装 pzctl：/usr/local/bin/pzctl"
  cat >/usr/local/bin/pzctl <<'PZCTL_EOF'
#!/usr/bin/env bash
set -euo pipefail

PZ_USER="pz"
PZ_HOME="/home/${PZ_USER}"
ZOMBOID_DIR="${PZ_HOME}/Zomboid"
SERVER_CFG_DIR="${ZOMBOID_DIR}/Server"
SAVES_DIR="${ZOMBOID_DIR}/Saves/Multiplayer"
SERVER_NAME="servertest"

BACKUP_DIR="/opt/pzbackup"
RESTORE_OLD_DIR="${BACKUP_DIR}/restore_old"
KEEP_BACKUPS=10

SERVICE_NAME="pzserver"
BACKUP_CRON_FILE="/etc/cron.d/${SERVICE_NAME}-backup"
BACKUP_LOG_FILE="/var/log/${SERVICE_NAME}-backup.log"
DEFAULT_BACKUP_INTERVAL="6h"
PZ_JSON_FILE="/opt/pzserver/ProjectZomboid64.json"
SELF_UPDATE_API_URL="https://api.github.com/repos/DmLeaves/AutoServer/contents/Project_Zombie"
SELF_UPDATE_RAW_BASE_URL="https://raw.githubusercontent.com/DmLeaves/AutoServer/main/Project_Zombie"

say()  { echo -e "\033[1;32m[pzctl]\033[0m $*"; }
warn() { echo -e "\033[1;33m[pzctl]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[pzctl]\033[0m $*" >&2; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 执行"; }
ensure_dirs() { mkdir -p "$SAVES_DIR" "$SERVER_CFG_DIR" "$BACKUP_DIR" "$RESTORE_OLD_DIR"; }

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

valid_mem_size() {
  [[ "$1" =~ ^[1-9][0-9]*[mMgG]$ ]] || die "内存格式无效：$1（示例：4g 12g / 4096m 12288m）"
}

do_mem_show() {
  [[ -f "$PZ_JSON_FILE" ]] || die "找不到配置文件：$PZ_JSON_FILE"

  local xms xmx
  xms="$(grep -oE '"-Xms[^"]+"' "$PZ_JSON_FILE" | head -n1 | tr -d '"' || true)"
  xmx="$(grep -oE '"-Xmx[^"]+"' "$PZ_JSON_FILE" | head -n1 | tr -d '"' || true)"

  [[ -n "$xms" ]] || xms="(未找到 -Xms)"
  [[ -n "$xmx" ]] || xmx="(未找到 -Xmx)"

  say "当前 JVM 内存参数：$xms $xmx"
}

do_mem_set() {
  local xms="${1:-}"
  local xmx="${2:-}"

  [[ -f "$PZ_JSON_FILE" ]] || die "找不到配置文件：$PZ_JSON_FILE"

  if [[ -z "$xms" ]]; then
    read -r -p "输入 Xms（例如 4g）: " xms
  fi
  if [[ -z "$xmx" ]]; then
    read -r -p "输入 Xmx（例如 12g）: " xmx
  fi

  valid_mem_size "$xms"
  valid_mem_size "$xmx"

  sed -i -E "s/\"-Xms[^\"]+\"/\"-Xms${xms}\"/; s/\"-Xmx[^\"]+\"/\"-Xmx${xmx}\"/" "$PZ_JSON_FILE"
  say "已更新：$PZ_JSON_FILE"
  do_mem_show
  warn "如服务正在运行，请执行：systemctl restart ${SERVICE_NAME}.service"
}

do_update_server() {
  need_root
  say "停服..."
  systemctl stop "${SERVICE_NAME}.service" || true

  say "更新服务端（B42 unstable）..."
  if has_cmd sudo; then
    sudo -u "$PZ_USER" -H /opt/steamcmd/steamcmd.sh \
      +force_install_dir /opt/pzserver \
      +login anonymous \
      +app_update 380870 -beta unstable validate \
      +quit
  elif has_cmd runuser; then
    HOME="$PZ_HOME" runuser -u "$PZ_USER" -- /opt/steamcmd/steamcmd.sh \
      +force_install_dir /opt/pzserver \
      +login anonymous \
      +app_update 380870 -beta unstable validate \
      +quit
  else
    die "缺少 sudo/runuser，无法切换到 ${PZ_USER} 执行 steamcmd"
  fi

  say "启动..."
  systemctl start "${SERVICE_NAME}.service" || true
  say "更新完成"
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

${cron_expr} root /usr/local/bin/pzctl backup >>"${BACKUP_LOG_FILE}" 2>&1
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

latest_install_script_name_from_json() {
  local json="$1"
  printf '%s\n' "$json" \
    | tr ',' '\n' \
    | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(installV[0-9][0-9]*\.sh\)".*/\1/p' \
    | sort -V \
    | tail -n1
}

do_self_update() {
  need_root
  has_cmd curl || die "缺少 curl，无法执行远程更新"

  local json latest_name url tmp
  json="$(curl -fsSL "$SELF_UPDATE_API_URL")" || die "获取远程脚本列表失败：$SELF_UPDATE_API_URL"
  latest_name="$(latest_install_script_name_from_json "$json")"
  [[ -n "$latest_name" ]] || die "远程未找到 installVx.sh"

  url="${SELF_UPDATE_RAW_BASE_URL}/${latest_name}"
  tmp="/tmp/${latest_name}"

  say "下载最新脚本：$url"
  curl -fsSL "$url" -o "$tmp"
  chmod +x "$tmp"

  say "执行最新脚本 install（已安装环境会仅更新 pzctl）..."
  bash "$tmp" install
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
  [[ "$choice" =~ ^[Qq]$ ]] && { echo "已退出。"; return 0; }
  [[ "$choice" =~ ^[0-9]+$ ]] || die "输入无效：$choice"
  local idx=$((choice-1))
  (( idx >= 0 && idx < ${#files[@]} )) || die "序号超出范围：$choice"

  local pkg="${files[$idx]}"
  echo "将恢复：$pkg"
  read -r -p "确认执行？输入 yes 继续: " ok
  [[ "$ok" == "yes" ]] || { echo "已取消。"; return 0; }
  restore_from_pkg "$pkg"
}

usage() {
  cat <<USAGE
用法：pzctl <cmd>

服务：
  pzctl start|stop|restart|status|logs

备份/回档：
  pzctl backup            在线备份（不停服）
  pzctl backup-stop       停服备份（更一致）
  pzctl restore           菜单选择备份并恢复

定时备份：
  pzctl cron              定时备份菜单
  pzctl cron-on [6h]      开启/更新定时备份
  pzctl cron-off          关闭自动备份
  pzctl cron-status       查看自动备份状态

其他：
  pzctl menu              交互式菜单
  pzctl mem-show          查看 JVM 内存参数（Xms/Xmx）
  pzctl mem-set [4g] [12g] 修改 JVM 内存参数（写入 ProjectZomboid64.json）
  pzctl update-server     更新服务端（B42 unstable）
  pzctl self-update       远程拉取最新 installVx.sh 并执行 install

配置文件目录：
  ${SERVER_CFG_DIR}/
USAGE
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
    echo "10) 查看内存参数 mem-show"
    echo "11) 修改内存参数 mem-set"
    echo "12) 更新服务端 update-server"
    echo "13) 远程更新脚本 self-update"
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
      10) do_mem_show ;;
      11) do_mem_set ;;
      12) do_update_server ;;
      13) do_self_update ;;
      0) return 0 ;;
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
  mem-show) do_mem_show ;;
  mem-set) do_mem_set "${1:-}" "${2:-}" ;;
  update-server) do_update_server ;;
  self-update) do_self_update ;;
  help|-h|--help) usage ;;
  *) die "未知命令：$cmd（用 pzctl help 查看）" ;;
esac
PZCTL_EOF
  chmod +x /usr/local/bin/pzctl
}

# ========= 防火墙放行 =========
fw_allow() {
  say "放行端口：UDP ${PZ_UDP_RANGE}（必要），TCP ${PZ_TCP_PORT}（可选）"

  if has_cmd ufw; then
    ufw allow "${PZ_UDP_RANGE}/udp" || true
    ufw allow "${PZ_TCP_PORT}/tcp" || true
    warn "已写入 ufw 规则（若 ufw 未启用，请自行 ufw enable）。云安全组必须把 UDP ${PZ_UDP_RANGE} 全部放行，不然会连接超时或连接丢失。"
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

  warn "未检测到 ufw/firewalld，请手动放行：UDP ${PZ_UDP_RANGE}。云安全组也必须把 UDP ${PZ_UDP_RANGE} 全部放行，不然会连接超时或连接丢失。"
}

fw_revert() {
  say "尝试回滚防火墙规则..."

  if has_cmd ufw; then
    ufw delete allow "${PZ_UDP_RANGE}/udp" >/dev/null 2>&1 || true
    ufw delete allow "${PZ_TCP_PORT}/tcp" >/dev/null 2>&1 || true
    say "ufw：已尝试删除规则（若不存在会忽略）"
    return
  fi

  if has_cmd firewall-cmd; then
    firewall-cmd --permanent --remove-port="${PZ_UDP_RANGE}/udp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-port="${PZ_TCP_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    say "firewalld：已尝试删除规则（若不存在会忽略）"
    return
  fi

  warn "未检测到 ufw/firewalld，无法自动回滚规则。"
}

# ========= 第一次启动提示 =========
first_run_hint() {
  local start_sh
  start_sh="$(detect_start_script)"

  cat <<EOF

==================== 下一步（很重要） ====================

1) 第一次不要直接用 systemd；请先手动前台运行一次初始化（会提示输入 admin 密码）：
   sudo -u ${PZ_USER} -H /bin/bash ${start_sh} -servername ${SERVER_NAME}
   如果系统没有 sudo，也可以用：
   runuser -u ${PZ_USER} -- /bin/bash ${start_sh} -servername ${SERVER_NAME}

2) 初始化完成后，按 Ctrl+C 退出前台，再用 systemd 启动：
   systemctl start ${SERVICE_NAME}

3) 配置文件目录（以后覆盖旧配置放这里）：
   ${SERVER_CFG_DIR}/
   例如：
     ${SERVER_NAME}.ini
     ${SERVER_NAME}_SandboxVars.lua
     ${SERVER_NAME}_spawnpoints.lua
     ${SERVER_NAME}_spawnregions.lua

4) 存档目录：
   ${SAVES_DIR}/${SERVER_NAME}

5) 控制菜单：
   pzctl menu

6) 定时备份（手动开启，可自定义间隔）：
   pzctl cron-on 6h

7) 查看日志：
   journalctl -u ${SERVICE_NAME} -f

提示：云服务器还必须在“云安全组”放行 UDP ${PZ_UDP_RANGE}
      必须 UDP ${PZ_UDP_RANGE} 全开，不然会有连接超时/连接丢失。

==========================================================
EOF
}

# ========= 卸载 =========
do_uninstall() {
  need_root
  warn "将卸载：服务、SteamCMD、服务器目录、备份目录、pz 用户、cron、防火墙规则（尽量回滚）"
  read -r -p "确认卸载？输入 yes 继续: " ok
  [[ "$ok" == "yes" ]] || { echo "已取消"; exit 0; }

  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload || true

  rm -f /usr/local/bin/pzctl
  remove_backup_cron

  rm -rf "$PZ_SERVER_DIR" "$STEAMCMD_DIR" "$BACKUP_DIR"

  fw_revert

  if id -u "$PZ_USER" >/dev/null 2>&1; then
    userdel -r "$PZ_USER" >/dev/null 2>&1 || true
  fi

  say "卸载完成"
}

do_install() {
  need_root

  if [[ -x /usr/local/bin/pzctl ]]; then
    say "检测到已安装环境（/usr/local/bin/pzctl），跳过环境安装，仅更新 pzctl..."
    install_pzctl
    say "pzctl 更新完成"
    return
  fi

  install_deps
  ensure_user
  ensure_dirs
  install_steamcmd
  install_pz_server
  install_systemd
  install_pzctl
  fw_allow
  chown -R "$PZ_USER:$PZ_USER" \
    "$PZ_HOME" "$ZOMBOID_DIR" "$PZ_SERVER_DIR" "$STEAMCMD_DIR" "$BACKUP_DIR" 2>/dev/null || true
  say "安装完成"
  first_run_hint
}

do_self_update() {
  need_root
  has_cmd curl || die "缺少 curl，无法执行远程更新"

  local url name tmp
  url="$(get_latest_install_script_url)"
  name="${url##*/}"
  tmp="/tmp/${name}"

  say "下载最新脚本：$url"
  curl -fsSL "$url" -o "$tmp"
  chmod +x "$tmp"

  say "执行最新脚本 install（已安装环境会仅更新 pzctl）..."
  bash "$tmp" install
}

do_update() {
  need_root
  say "停服..."
  systemctl stop "${SERVICE_NAME}.service" || true

  say "更新服务端（B42 unstable）..."
  run_as_pz "$STEAMCMD" \
    +force_install_dir "$PZ_SERVER_DIR" \
    +login anonymous \
    +app_update "$PZ_APPID" "${PZ_BRANCH_ARGS[@]}" validate \
    +quit
  chown -R "$PZ_USER:$PZ_USER" "$PZ_SERVER_DIR" 2>/dev/null || true

  say "启动..."
  systemctl start "${SERVICE_NAME}.service" || true
  say "更新完成"
}

main() {
  local cmd="${1:-install}"
  shift || true
  case "$cmd" in
    install)
      [[ $# -eq 0 ]] || die "install 不接受额外参数"
      do_install
      ;;
    uninstall)
      [[ $# -eq 0 ]] || die "uninstall 不接受额外参数"
      do_uninstall
      ;;
    update)
      [[ $# -eq 0 ]] || die "update 不接受额外参数"
      do_update
      ;;
    self-update)
      [[ $# -eq 0 ]] || die "self-update 不接受额外参数"
      do_self_update
      ;;
    help|-h|--help)
      cat <<EOF
用法：
  sudo bash $0 install
  sudo bash $0 update
  sudo bash $0 self-update
  sudo bash $0 uninstall
EOF
      ;;
    *) die "未知命令：$cmd（install/update/self-update/uninstall）" ;;
  esac
}

main "$@"
