#!/usr/bin/env bash
# =====================================================================
#  JAZZ VPS MANAGEMENT PANEL - Self-extracting installer
#  Installs every dependency + every panel file, starts the panel in
#  PM2 and gives you the jazz-panel command (start/stop/restart/...).
#  Supported: Debian 11/12/13, Ubuntu 20.04/22.04/24.04 (run as root)
# =====================================================================
set -uo pipefail

# ---- where the panel files come from (your GitHub repo). Update the zip there, then run Update. ----
JAZZ_REPO="${JAZZ_REPO:-expelhost-s/JAZZ-PANEL-TST}"
JAZZ_BRANCH="${JAZZ_BRANCH:-main}"
JAZZ_ZIP="${JAZZ_ZIP:-JAZZSPAIN-VPS-MANAGE-PANEL.zip}"
# JAZZ_SOURCE_ZIP=/path/file.zip  -> use a local zip instead of GitHub (offline / testing)

APP_TITLE="JAZZ VPS MANAGEMENT PANEL"
PM2_NAME="jazz-panel"
INSTALL_DIR="${JAZZ_INSTALL_DIR:-}"   # chosen during install (root / opt / home)
CLI_PATH="/usr/local/bin/jazz-panel"
LOG_FILE="/var/log/jazz-installer.log"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/snap/bin:/usr/local/bin"

# ---------- colours ----------
if [[ -t 1 ]]; then
  R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; W=$'\033[1;37m'; D=$'\033[0m'
else R=""; G=""; Y=""; C=""; W=""; D=""; fi

ok()   { echo "${G}[ OK ]${D} $*"; }
info() { echo "${C}[ .. ]${D} $*"; }
warn() { echo "${Y}[WARN]${D} $*"; }
err()  { echo "${R}[FAIL]${D} $*" >&2; }
die()  { err "$*"; echo "       Full log: $LOG_FILE" >&2; exit 1; }

banner() {
  clear 2>/dev/null || true
  echo "${C}=============================================${D}"
  cat <<'ART'
     ████  █████  ██████ ██████
       ██ ██   ██    ██      ██
       ██ ███████   ██      ██
 ██    ██ ██   ██  ██      ██
  ██████  ██   ██ ██████ ██████
ART
  echo "${C}=============================================${D}"
  echo "${W} VPS MANAGEMENT PANEL  -  Installer & Manager${D}"
  echo "${C}=============================================${D}"
  echo
}

need_root() { [[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $(basename "$SELF")"; }

# run a command, log everything, show tail on failure
run() {
  local desc="$1"; shift
  info "$desc"
  echo "### $desc :: $*" >> "$LOG_FILE"
  if "$@" >> "$LOG_FILE" 2>&1; then ok "$desc"; return 0; fi
  err "$desc failed. Last log lines:"; tail -n 15 "$LOG_FILE" >&2; return 1
}
quiet() { "$@" >> "$LOG_FILE" 2>&1; }   # best-effort, silent

ask() {  # ask "Question" default  -> echoes answer
  local q="$1" def="${2:-}" a=""
  if [[ ${JAZZ_YES:-0} == 1 || ! -t 0 ]]; then echo "$def"; return; fi
  read -r -p "$q [$def]: " a </dev/tty || true
  echo "${a:-$def}"
}
ask_secret() {
  local q="$1" a=""
  if [[ ${JAZZ_YES:-0} == 1 || ! -t 0 ]]; then echo ""; return; fi
  read -r -s -p "$q (blank = auto-generate): " a </dev/tty || true; echo >&2
  echo "$a"
}
yesno() { # yesno "Question" Y|N
  local a; a=$(ask "$1 (y/n)" "$2"); [[ "${a,,}" == y* ]]
}

ask_pw() {  # hidden input, Enter = default
  local q="$1" def="$2" a=""
  if [[ ${JAZZ_YES:-0} == 1 || ! -t 0 ]]; then echo "$def"; return; fi
  read -r -s -p "$q [$def]: " a </dev/tty || true; echo >&2
  echo "${a:-$def}"
}
rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }

pm2_online() {
  command -v pm2 >/dev/null 2>&1 || return 1
  pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if any(p.get('name')=='$PM2_NAME' and p.get('pm2_env',{}).get('status')=='online' for p in d) else 1)"
}

env_get() { grep -E "^$1=" "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-; }

# ---------- panel source (GitHub zip) ----------
fetch_panel() {  # fetch_panel <dest> : download latest panel files from GitHub into <dest>
  local dest="$1" w zip="" root
  for t in git unzip curl; do
    command -v "$t" >/dev/null 2>&1 || quiet apt-get install -y "$t"
  done
  w="$(mktemp -d)"
  if [[ -n "${JAZZ_SOURCE_ZIP:-}" ]]; then
    zip="$JAZZ_SOURCE_ZIP"; info "Using local panel zip: $zip"
  elif [[ -f "$(dirname "$SELF")/$JAZZ_ZIP" ]]; then
    zip="$(dirname "$SELF")/$JAZZ_ZIP"; info "Using panel zip next to the installer: $zip"
  else
    info "Downloading panel files from GitHub: $JAZZ_REPO ($JAZZ_BRANCH)"
    if GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$JAZZ_BRANCH" "https://github.com/$JAZZ_REPO.git" "$w/repo" >>"$LOG_FILE" 2>&1; then
      if [[ -f "$w/repo/$JAZZ_ZIP" ]]; then zip="$w/repo/$JAZZ_ZIP"
      elif [[ -f "$w/repo/hvm.py" ]]; then root="$w/repo"
      else zip="$(find "$w/repo" -maxdepth 2 -iname '*.zip' | head -1)"; fi
    else
      warn "git clone failed - trying direct download"
      curl -fsSL "https://raw.githubusercontent.com/$JAZZ_REPO/$JAZZ_BRANCH/$JAZZ_ZIP" -o "$w/panel.zip" >>"$LOG_FILE" 2>&1 && zip="$w/panel.zip"
    fi
  fi
  if [[ -z "${root:-}" ]]; then
    [[ -n "$zip" && -f "$zip" ]] || die "Panel zip '$JAZZ_ZIP' not found in github.com/$JAZZ_REPO ($JAZZ_BRANCH). Is the repo public and the file uploaded?"
    mkdir -p "$w/x"; unzip -q -o "$zip" -d "$w/x" >>"$LOG_FILE" 2>&1 || die "Could not unzip the panel zip (damaged file?)"
    root="$(dirname "$(find "$w/x" -name hvm.py -not -path '*/__MACOSX/*' | head -1)")"
  fi
  [[ -f "$root/hvm.py" ]] || die "hvm.py not found inside the panel zip"
  [[ -f "$root/requirements.txt" ]] || die "requirements.txt not found inside the panel zip"
  mkdir -p "$dest"
  [[ -f "$w/repo/jazz-installer.sh" ]] && grep -q "^fetch_panel()" "$w/repo/jazz-installer.sh" && cp -f "$w/repo/jazz-installer.sh" "$dest/jazz-installer.sh"
  ( cd "$root" && tar cf - --exclude='.git' --exclude='__pycache__' --exclude='.trashed-*' --exclude='*.pyc' --exclude='hvm.db' . ) | tar xf - -C "$dest"
  rm -rf "$w"
  ok "Panel files unpacked"
}

# ---------- install location ----------
find_existing_install() {
  local d
  for d in "$INSTALL_DIR" /root/jazz-vps-panel /opt/jazz-vps-panel /home/jazz-vps-panel; do
    [[ -n "$d" ]] || continue
    [[ -f "$d/.env" ]] && { echo "$d"; return 0; }
  done
  return 1
}
choose_location() {
  [[ -n "$INSTALL_DIR" ]] && return 0
  local ex; ex="$(find_existing_install || true)"
  if [[ -n "$ex" ]]; then INSTALL_DIR="$ex"; return 0; fi
  if [[ ${JAZZ_YES:-0} == 1 || ! -t 0 ]]; then INSTALL_DIR="/root/jazz-vps-panel"; return 0; fi
  local c a
  while true; do
    echo "${W} Where do you want to install the panel?${D}"
    echo "   1  root   ->  /root/jazz-vps-panel"
    echo "   2  opt    ->  /opt/jazz-vps-panel"
    echo "   3  home   ->  /home/jazz-vps-panel"
    read -r -p " Choose 1 / 2 / 3: " c </dev/tty || exit 1
    case "$c" in
      1) INSTALL_DIR=/root/jazz-vps-panel ;;
      2) INSTALL_DIR=/opt/jazz-vps-panel ;;
      3) INSTALL_DIR=/home/jazz-vps-panel ;;
      *) warn "Please type 1, 2 or 3"; continue ;;
    esac
    read -r -p " Install in $INSTALL_DIR ?  (yes/no): " a </dev/tty || exit 1
    [[ "${a,,}" == y* ]] && break
    INSTALL_DIR=""
  done
}

# ---------- steps ----------
check_os() {
  [[ -r /etc/os-release ]] || die "Unknown OS"
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) ok "OS: ${PRETTY_NAME:-$ID}" ;;
    *) die "Only Debian / Ubuntu are supported (found: ${PRETTY_NAME:-$ID})" ;;
  esac
  [[ "$(uname -m)" =~ ^(x86_64|aarch64)$ ]] || warn "CPU $(uname -m) is untested"
}

fix_hostname() {
  # hvm.py calls socket.gethostbyname(socket.gethostname()) at import time - it
  # crashes (and PM2 shows "errored") if the hostname does not resolve.
  local h; h="$(hostname)"
  if ! getent hosts "$h" >/dev/null 2>&1; then
    echo "127.0.1.1 $h" >> /etc/hosts
    ok "Added hostname '$h' to /etc/hosts"
  fi
}

install_apt() {
  run "Updating package lists" apt-get -o DPkg::Lock::Timeout=180 update -y || die "apt update failed"
  run "Installing core packages" apt-get -o DPkg::Lock::Timeout=180 install -y \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      ca-certificates curl wget git tar gzip unzip rsync sqlite3 openssl gnupg \
      build-essential python3 python3-dev python3-venv python3-pip libffi-dev libssl-dev \
      iptables openssh-client e2fsprogs util-linux lsb-release \
      || die "Core package install failed"
  info "Installing optional tools (quota, tmate, snapd, uidmap)"
  for p in quota tmate snapd uidmap; do quiet apt-get -o DPkg::Lock::Timeout=180 install -y "$p" || warn "optional package $p not installed"; done
  ok "System packages ready"
}

PYBIN=""
find_python() {
  local c v
  for c in python3.13 python3.12 python3.11 python3.10 python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    v=$("$c" -c 'import sys;print(sys.version_info[0]*100+sys.version_info[1])' 2>/dev/null || echo 0)
    if (( v >= 310 )); then PYBIN="$(command -v "$c")"; return 0; fi
  done
  return 1
}
ensure_python() {
  if ! find_python; then
    warn "Python 3.10+ not found - trying to install python3.11"
    quiet apt-get install -y python3.11 python3.11-venv python3.11-dev
    if ! find_python && . /etc/os-release && [[ "${ID:-}" == "ubuntu" ]]; then
      quiet apt-get install -y software-properties-common
      quiet add-apt-repository -y ppa:deadsnakes/ppa
      quiet apt-get update -y
      quiet apt-get install -y python3.11 python3.11-venv python3.11-dev
    fi
    find_python || die "Python 3.10 or newer is required and could not be installed"
  fi
  ok "Python: $("$PYBIN" --version) ($PYBIN)"
}

install_node_pm2() {
  local major=0
  command -v node >/dev/null 2>&1 && major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if (( major < 16 )); then
    info "Installing Node.js 20 (NodeSource)"
    if curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh >>"$LOG_FILE" 2>&1 \
       && quiet bash /tmp/nodesource_setup.sh && quiet apt-get install -y nodejs; then :
    else
      warn "NodeSource failed, falling back to distro nodejs/npm"
      run "Installing nodejs + npm" apt-get install -y nodejs npm || die "Node.js install failed"
    fi
  fi
  ok "Node.js $(node -v)"
  if ! command -v pm2 >/dev/null 2>&1; then
    run "Installing PM2" npm install -g pm2 || die "PM2 install failed"
  fi
  ok "PM2 $(pm2 -v 2>/dev/null | tail -1)"
  quiet pm2 install pm2-logrotate && quiet pm2 set pm2-logrotate:max_size 20M && quiet pm2 set pm2-logrotate:retain 7
}

install_lxd() {
  if command -v lxc >/dev/null 2>&1 && quiet lxc info; then ok "LXD already installed and running"; return 0; fi
  info "Installing LXD (container engine used to create VPS)"
  quiet systemctl enable --now snapd.socket snapd.service
  quiet snap wait system seed.loaded
  if ! command -v snap >/dev/null 2>&1; then warn "snap not available - install LXD manually later"; return 1; fi
  quiet snap install core
  if ! snap list lxd >/dev/null 2>&1; then
    run "Installing LXD snap" snap install lxd || { warn "LXD install failed - panel will still work, but VPS creation needs LXD"; return 1; }
  fi
  ln -sf /snap/bin/lxc /usr/local/bin/lxc 2>/dev/null; ln -sf /snap/bin/lxd /usr/local/bin/lxd 2>/dev/null
  if ! quiet lxc storage show default; then
    run "Initialising LXD (storage pool 'default' + lxdbr0 network)" lxd init --auto || warn "lxd init failed - run 'lxd init --auto' manually"
  fi
  ok "LXD ready"
}

install_sshx() {
  command -v sshx >/dev/null 2>&1 && return 0
  info "Installing sshx (optional web-terminal sharing)"
  if curl -fsSL https://sshx.io/get -o /tmp/sshx_get.sh >>"$LOG_FILE" 2>&1 && quiet sh /tmp/sshx_get.sh; then ok "sshx installed"
  else warn "sshx not installed (optional)"; fi
}

setup_files() {
  local tmp; tmp="$(mktemp -d)"
  fetch_panel "$tmp"
  mkdir -p "$INSTALL_DIR"
  if [[ -f "$INSTALL_DIR/hvm.db" ]]; then
    mkdir -p "$INSTALL_DIR/backups"
    cp -a "$INSTALL_DIR/hvm.db" "$INSTALL_DIR/backups/hvm.db.pre-update.$(date +%Y%m%d-%H%M%S)"
    ok "Existing database backed up (update mode - data kept)"
  fi
  ( cd "$tmp" && tar cf - --exclude='./static/uploads' . ) | tar xf - -C "$INSTALL_DIR" || die "File copy failed"
  mkdir -p "$INSTALL_DIR/static/uploads"
  cp -an "$tmp"/static/uploads/. "$INSTALL_DIR"/static/uploads/ 2>/dev/null   # never overwrite existing uploads
  mkdir -p "$INSTALL_DIR"/{backups,logs,static/uploads/profiles,static/uploads/settings,static/uploads/os_icons,static/img}
  rm -rf "$tmp"
  if [[ ! -s "$INSTALL_DIR/jazz-installer.sh" ]]; then   # keep a copy for: jazz-panel menu / update / uninstall
    if [[ -f "$SELF" ]]; then cp -f "$SELF" "$INSTALL_DIR/jazz-installer.sh"
    else curl -fsSL "https://raw.githubusercontent.com/$JAZZ_REPO/$JAZZ_BRANCH/jazz-installer.sh" -o "$INSTALL_DIR/jazz-installer.sh" >>"$LOG_FILE" 2>&1 || warn "could not save installer copy"
    fi
  fi
  chmod 755 "$INSTALL_DIR/jazz-installer.sh" 2>/dev/null
  ok "Panel files installed in $INSTALL_DIR"
}

setup_venv() {
  cd "$INSTALL_DIR" || die "cd failed"
  [[ -x venv/bin/python ]] && ! venv/bin/python -c 'import sys;sys.exit(0 if sys.version_info>=(3,10) else 1)' 2>/dev/null && rm -rf venv
  [[ -x venv/bin/python ]] || run "Creating Python virtual environment" "$PYBIN" -m venv venv || die "venv creation failed"
  quiet venv/bin/python -m pip install --upgrade pip setuptools wheel
  grep -viE '^(pip|setuptools|wheel)==' requirements.txt > .requirements.install
  info "Installing Python dependencies (this can take a few minutes)"
  if venv/bin/python -m pip install -r .requirements.install >>"$LOG_FILE" 2>&1; then
    ok "Python dependencies installed (pinned versions)"
  else
    warn "Pinned versions failed on this Python - retrying with compatible versions"
    sed -E 's/==.*//' .requirements.install | grep -viE '^(colorama)$' > .requirements.loose
    # keep the versions the panel code was written against
    sed -i -E 's/^Flask$/Flask==2.3.3/; s/^Werkzeug$/Werkzeug==2.3.7/; s/^Flask-SocketIO$/Flask-SocketIO==5.3.6/; s/^python-socketio$/python-socketio==5.11.2/; s/^python-engineio$/python-engineio==4.9.0/; s/^Flask-Login$/Flask-Login==0.6.3/' .requirements.loose
    run "Installing Python dependencies (fallback)" venv/bin/python -m pip install -r .requirements.loose || die "Python dependency install failed"
  fi
  rm -f .requirements.install .requirements.loose
  venv/bin/python -c "import flask, flask_login, flask_socketio, flask_cors, paramiko, PIL, psutil, requests, bcrypt, simple_websocket" >>"$LOG_FILE" 2>&1 \
    || die "Dependency self-check failed (see log)"
  ok "Dependency self-check passed"
}

write_env() {
  local port="$1" user="$2" pass="$3" email="$4" name="$5" ip="$6" domain="${7:-}"
  if [[ -f "$INSTALL_DIR/.env" ]]; then ok "Keeping existing configuration (.env)"; return; fi
  local secret; secret="$(rand 48)"
  cat > "$INSTALL_DIR/.env" <<ENV
# JAZZ VPS MANAGEMENT PANEL configuration  (edit, then: jazz-panel restart)
PANEL_NAME=$name
PANEL_DEVELOPER=JAZZ
HOST=0.0.0.0
PORT=$port
SECRET_KEY=$secret
DATABASE_PATH=$INSTALL_DIR/hvm.db
MAIN_ADMIN_USERNAME=$user
MAIN_ADMIN_PASSWORD=$pass
MAIN_ADMIN_EMAIL=$email
YOUR_SERVER_IP=$ip
PANEL_DOMAIN=$domain
DEFAULT_STORAGE_POOL=default
DEBUG_MODE=False
AUTO_BACKUP_INTERVAL=3600
STATS_UPDATE_INTERVAL=5
ENV
  chmod 600 "$INSTALL_DIR/.env"
  ok "Configuration written (.env)"
}

write_ecosystem() {
  cat > "$INSTALL_DIR/ecosystem.config.js" <<'ECO'
// PM2 process file for JAZZ VPS MANAGEMENT PANEL - reads ./.env on every (re)start
const fs = require('fs');
const path = require('path');
const env = {};
try {
  fs.readFileSync(path.join(__dirname, '.env'), 'utf8').split(/\r?\n/).forEach((l) => {
    const m = l.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) return;
    let v = m[2];
    if (/^(".*"|'.*')$/.test(v)) v = v.slice(1, -1);
    env[m[1]] = v;
  });
} catch (e) { /* no .env yet */ }

module.exports = {
  apps: [{
    name: 'jazz-panel',
    script: 'hvm.py',
    cwd: __dirname,
    interpreter: path.join(__dirname, 'venv', 'bin', 'python'),
    autorestart: true,
    watch: false,
    max_restarts: 20,
    min_uptime: '15s',
    restart_delay: 3000,
    kill_timeout: 8000,
    time: true,
    out_file: path.join(__dirname, 'logs', 'panel-out.log'),
    error_file: path.join(__dirname, 'logs', 'panel-error.log'),
    merge_logs: true,
    env: Object.assign({
      PYTHONUNBUFFERED: '1',
      PATH: '/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    }, env),
  }],
};
ECO
  ok "PM2 process file written"
}

write_cli() {
  cat > "$CLI_PATH" <<'CLI'
#!/usr/bin/env bash
# jazz-panel - control the JAZZ VPS MANAGEMENT PANEL
INSTALL_DIR="__INSTALL_DIR__"
APP="jazz-panel"
export PATH="$PATH:/snap/bin:/usr/local/bin"
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo jazz-panel ...)"; exit 1; }
envget() { grep -E "^$1=" "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-; }
exists() { pm2 describe "$APP" >/dev/null 2>&1; }
case "${1:-help}" in
  start)   if exists; then pm2 start "$APP" --update-env; else pm2 start "$INSTALL_DIR/ecosystem.config.js"; fi; pm2 save >/dev/null ;;
  stop)    pm2 stop "$APP" ;;
  restart) if exists; then pm2 restart "$APP" --update-env; else pm2 start "$INSTALL_DIR/ecosystem.config.js"; fi; pm2 save >/dev/null ;;
  status)  pm2 list; pm2 describe "$APP" 2>/dev/null | grep -E "status|uptime|restarts|script path|exec cwd" ;;
  logs)    pm2 logs "$APP" --lines "${2:-80}" ;;
  info)    ip=$(envget YOUR_SERVER_IP); dom=$(envget PANEL_DOMAIN)
           [[ -n "$dom" ]] && echo "Domain URL: https://$dom (tunnel -> http://localhost:$(envget PORT))"
           echo "Panel URL : http://${ip}:$(envget PORT)"
           echo "Admin user: $(envget MAIN_ADMIN_USERNAME)"
           echo "Config    : $INSTALL_DIR/.env"
           echo "Folder    : $INSTALL_DIR" ;;
  admin|password)
           cur=$(envget MAIN_ADMIN_USERNAME)
           read -r -p "Admin username [$cur]: " u; u="${u:-$cur}"
           read -r -p "Admin email (Enter = keep): " e
           read -r -s -p "New admin password (Enter = keep): " p; echo
           cd "$INSTALL_DIR" && NEWPW="$p" NEWU="$u" NEWE="$e" DB="$(envget DATABASE_PATH)" venv/bin/python -I - <<'PYEND'
import os, sqlite3
from werkzeug.security import generate_password_hash
c = sqlite3.connect(os.environ["DB"])
row = c.execute("SELECT id FROM users WHERE is_main_admin=1").fetchone()
if not row:
    print("No main admin found (start the panel once first)"); raise SystemExit(1)
uid = row[0]
c.execute("UPDATE users SET username=? WHERE id=?", (os.environ["NEWU"], uid))
if os.environ["NEWE"]:
    c.execute("UPDATE users SET email=? WHERE id=?", (os.environ["NEWE"], uid))
if os.environ["NEWPW"]:
    c.execute("UPDATE users SET password_hash=? WHERE id=?", (generate_password_hash(os.environ["NEWPW"]), uid))
c.commit()
print("Admin account updated")
PYEND
           sed -i "s|^MAIN_ADMIN_USERNAME=.*|MAIN_ADMIN_USERNAME=$u|" "$INSTALL_DIR/.env"
           ;;
  update)  bash "$INSTALL_DIR/jazz-installer.sh" --update ;;
  uninstall) bash "$INSTALL_DIR/jazz-installer.sh" --uninstall ;;
  menu)    bash "$INSTALL_DIR/jazz-installer.sh" --menu ;;
  *) cat <<H
JAZZ VPS MANAGEMENT PANEL

  jazz-panel start        start the panel
  jazz-panel stop         stop the panel
  jazz-panel restart      restart the panel
  jazz-panel status       PM2 status
  jazz-panel logs [N]     live logs (last N lines)
  jazz-panel info         panel URL / admin user
  jazz-panel admin        change admin username / email / password
  jazz-panel update       download the latest panel files from GitHub (data is kept)
  jazz-panel menu         open the manager menu
  jazz-panel uninstall    remove the panel

Direct PM2 commands also work:
  pm2 list | pm2 restart $APP | pm2 stop $APP | pm2 start $APP | pm2 logs $APP
H
  ;;
esac
CLI
  sed -i "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$CLI_PATH"
  chmod 755 "$CLI_PATH"
  ok "Command installed: jazz-panel"
}

start_pm2() {
  cd "$INSTALL_DIR" || die "cd failed"
  quiet pm2 delete "$PM2_NAME"
  run "Starting panel in PM2" pm2 start ecosystem.config.js || die "pm2 start failed"
  quiet pm2 save
  quiet pm2 startup systemd -u root --hp /root
  quiet systemctl enable pm2-root
  quiet pm2 save
  ok "PM2 auto-start on boot enabled"
}

open_firewall() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    quiet ufw allow "$port"/tcp && ok "ufw: opened port $port/tcp"
  fi
}

health_check() {
  local port="$1" i code=""
  info "Waiting for the panel to answer on port $port ..."
  for i in $(seq 1 45); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port/" || true)
    if [[ "$code" =~ ^(200|301|302|401|403)$ ]] && pm2_online; then ok "Panel is ONLINE (HTTP $code)"; return 0; fi
    sleep 2
  done
  err "Panel did not come up. Last error log lines:"
  tail -n 40 "$INSTALL_DIR/logs/panel-error.log" 2>/dev/null >&2
  return 1
}

# ---------- actions ----------
do_install() {
  need_root
  : > "$LOG_FILE"
  banner
  check_os

  choose_location
  ok "Install folder: $INSTALL_DIR"
  local port user pass email name ip domain="" update=0
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    info "Existing installation found -> UPDATE mode (config, database and uploads are kept)"
    update=1
    port=$(env_get PORT); ip=$(env_get YOUR_SERVER_IP); user=$(env_get MAIN_ADMIN_USERNAME); pass="(unchanged)"
  else
    ip="$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    name=$(ask "Panel name" "JAZZ VPS Management Panel")
    port=$(ask "Panel port" "3000")
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || die "Invalid port"
    ip=$(ask "Server public IP (used for VPS port-forward display)" "$ip")
    domain=$(ask "Panel domain / tunnel domain, e.g. panel.example.com (Enter = none)" "")
    domain="${domain#http://}"; domain="${domain#https://}"; domain="${domain%%/*}"
  fi
  local want_lxd=1
  if (( ! update )) && ! command -v lxc >/dev/null 2>&1; then
    yesno "Install LXD (required to create VPS containers)?" "y" || want_lxd=0
  fi

  echo
  if (( update )); then
    ensure_python
  else
    fix_hostname
    install_apt
    ensure_python
    install_node_pm2
    (( want_lxd )) && install_lxd
    install_sshx
  fi
  setup_files
  setup_venv
  if (( ! update )); then
    echo
    echo "${C}-------- Create the admin account --------${D}"
    echo " (press Enter to keep the default; change later with: jazz-panel admin)"
    user=$(ask "Admin username" "admin")
    email=$(ask "Admin email" "admin@gmail.com")
    pass=$(ask_pw "Admin password" "admin")
    echo
  fi
  write_env "${port:-3000}" "$user" "$pass" "${email:-admin@gmail.com}" "${name:-JAZZ VPS Management Panel}" "$ip" "$domain"
  write_ecosystem
  write_cli
  port=$(env_get PORT)
  start_pm2
  open_firewall "$port"
  health_check "$port" || die "Install finished but the panel is not healthy - see logs above"

  echo
  echo "${G}=====================================================${D}"
  if (( update )); then echo "${G}  JAZZ VPS MANAGEMENT PANEL UPDATED SUCCESSFULLY${D}"; else echo "${G}  JAZZ VPS MANAGEMENT PANEL INSTALLED SUCCESSFULLY${D}"; fi
  echo "${G}=====================================================${D}"
  local dom; dom="$(env_get PANEL_DOMAIN)"
  if [[ -n "$dom" ]]; then
    echo "  Panel URL  : ${W}https://$dom${D}   (point your tunnel/domain to http://localhost:$port)"
    echo "  Direct URL : http://$(env_get YOUR_SERVER_IP):$port"
  else
    echo "  Panel URL  : ${W}http://$(env_get YOUR_SERVER_IP):$port${D}"
  fi
  echo "  Username   : ${W}$user${D}"
  echo "  Password   : ${W}$pass${D}   (change: jazz-panel admin)"
  echo "  Folder     : $INSTALL_DIR      Config: $INSTALL_DIR/.env"
  echo
  echo "  ${C}Commands${D}"
  echo "    jazz-panel start | stop | restart | status | logs | info | admin"
  echo "    pm2 list"
  echo "    pm2 restart $PM2_NAME     pm2 stop $PM2_NAME     pm2 start $PM2_NAME"
  echo "    pm2 logs $PM2_NAME"
  echo
  pm2 list
}

do_uninstall() {
  need_root
  [[ -n "$INSTALL_DIR" ]] || INSTALL_DIR="$(find_existing_install || true)"
  [[ -n "$INSTALL_DIR" ]] || { warn "No JAZZ panel installation found"; return 0; }
  : >> "$LOG_FILE"
  echo "${R}-------- Uninstall JAZZ VPS MANAGEMENT PANEL --------${D}"
  echo " Installed in: $INSTALL_DIR"
  echo

  yesno "1) Remove the panel? (PM2 process '$PM2_NAME', jazz-panel command, all panel files)" "n" || { echo "Cancelled."; return 0; }

  local rm_deps=0 rm_lxd=0 rm_db=0
  yesno "2) Remove the dependencies installed for the panel? (PM2, Node.js, sshx, tmate, quota)" "n" && rm_deps=1
  if command -v lxc >/dev/null 2>&1; then
    if yesno "3) Remove LXD too?  ${R}WARNING: this DELETES ALL VPS containers and images${D}" "n"; then
      yesno "   Are you really sure? ALL VPS data will be lost" "n" && rm_lxd=1
    fi
  fi
  yesno "4) Delete the database? (all users, VPS records, settings, uploads)" "n" && rm_db=1

  echo
  echo " Summary:"
  echo "   panel files + PM2 process + jazz-panel command : REMOVE"
  echo "   dependencies (PM2, Node.js, sshx, tmate, quota) : $( ((rm_deps)) && echo REMOVE || echo keep)"
  echo "   LXD + all VPS containers                        : $( ((rm_lxd)) && echo REMOVE || echo keep)"
  echo "   database                                        : $( ((rm_db)) && echo DELETE || echo "keep (backup saved in /root)")"
  yesno "Proceed with uninstall?" "n" || { echo "Cancelled."; return 0; }
  echo

  # --- panel process + command ---
  quiet pm2 delete "$PM2_NAME"; quiet pm2 save --force
  ok "PM2 process removed"

  # --- database: keep a backup unless the user wants it gone ---
  if (( ! rm_db )); then
    local bk="/root/jazz-panel-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk"
    [[ -f "$INSTALL_DIR/hvm.db" ]] && cp -a "$INSTALL_DIR/hvm.db" "$bk/"
    [[ -f "$INSTALL_DIR/.env" ]] && cp -a "$INSTALL_DIR/.env" "$bk/"
    [[ -d "$INSTALL_DIR/static/uploads" ]] && cp -a "$INSTALL_DIR/static/uploads" "$bk/"
    ok "Database kept: $bk"
  fi
  rm -f "$CLI_PATH"
  rm -rf "$INSTALL_DIR"
  ok "Panel files + jazz-panel command removed"

  # --- dependencies ---
  if (( rm_deps )); then
    local others=0
    others=$(pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(0)" 2>/dev/null || echo 0)
    if (( others > 0 )); then
      warn "PM2 still runs $others other app(s) - PM2 and Node.js are kept"
    else
      quiet pm2 uninstall pm2-logrotate
      quiet pm2 unstartup systemd
      quiet systemctl disable --now pm2-root
      quiet npm uninstall -g pm2 && ok "PM2 removed"
      quiet apt-get remove -y --purge nodejs && ok "Node.js removed"
      rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/keyrings/nodesource.gpg /usr/share/keyrings/nodesource.gpg
      rm -rf /root/.pm2
    fi
    quiet apt-get remove -y --purge tmate quota && ok "tmate + quota removed"
    rm -f /usr/local/bin/sshx /root/.sshx && ok "sshx removed"
    quiet apt-get autoremove -y
  fi

  # --- LXD ---
  if (( rm_lxd )); then
    info "Deleting all LXD containers (this can take a while)..."
    local n
    for n in $(lxc list -c n --format csv 2>/dev/null); do quiet lxc delete "$n" --force; done
    quiet snap remove --purge lxd && ok "LXD removed"
    rm -f /usr/local/bin/lxc /usr/local/bin/lxd
  fi

  echo
  echo "${G}JAZZ VPS MANAGEMENT PANEL has been uninstalled.${D}"
  echo " (system packages like python3, curl, git were left in place - other software may need them)"
  INSTALL_DIR=""
}

pm2_action() { need_root; local cli; [[ -x "$CLI_PATH" ]] || die "Panel is not installed yet"; "$CLI_PATH" "$1"; }

manager_menu() {
  while true; do
    banner
    cat <<'M'
 1. Install / Update JAZZ VPS Management Panel
 2. Start panel
 3. Stop panel
 4. Restart panel
 5. Status & info
 6. View logs
 7. Change admin username / email / password
 8. Uninstall

 0. Exit

M
    local o; read -r -p " Select option: " o </dev/tty || exit 0
    echo
    case "$o" in
      1) do_install ;;
      2) pm2_action start ;;
      3) pm2_action stop ;;
      4) pm2_action restart ;;
      5) pm2_action status; "$CLI_PATH" info ;;
      6) pm2_action logs ;;
      7) pm2_action admin ;;
      8) do_uninstall ;;
      0) exit 0 ;;
      *) warn "Invalid option" ;;
    esac
    echo; read -r -p " Press Enter to continue..." _ </dev/tty || exit 0
  done
}

start_menu() {
  while true; do
    banner
    cat <<'M'
 1. Install Panel / Update Panel
 2. Status & info
 3. Uninstall

 0. Exit

M
    local o; read -r -p " Select option: " o </dev/tty || exit 0
    echo
    case "$o" in
      1) do_install
         echo; read -r -p " Press Enter to open the panel menu..." _ </dev/tty || exit 0
         manager_menu; exit 0 ;;
      2) if [[ -x "$CLI_PATH" ]]; then "$CLI_PATH" status; "$CLI_PATH" info; else warn "Panel is not installed yet"; fi ;;
      3) do_uninstall ;;
      0) exit 0 ;;
      *) warn "Invalid option" ;;
    esac
    echo; read -r -p " Press Enter to continue..." _ </dev/tty || exit 0
  done
}

usage() {
  cat <<U
$APP_TITLE installer
  bash $(basename "$SELF")               start menu (install / update / status / uninstall)
  bash $(basename "$SELF") --install     install / update (asks questions)
  bash $(basename "$SELF") --install --yes   unattended (defaults, random admin password)
  bash $(basename "$SELF") --uninstall   remove
Env overrides (with --yes): JAZZ_INSTALL_DIR
U
}

main() {
  trap 'echo; echo " Bye. (The panel keeps running in PM2 - run: jazz-panel menu)"; exit 0' INT
  local action=""
  for a in "$@"; do
    case "$a" in
      --install) action=install ;; --uninstall) action=uninstall ;; --yes|-y) JAZZ_YES=1 ;;
      --selftest) action=selftest ;; --update) action=install; JAZZ_YES=1 ;; --menu) action=menu ;; -h|--help) usage; exit 0 ;;
    esac
  done
  case "$action" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    selftest)  need_root; : > "$LOG_FILE"; _d="$(mktemp -d)"; fetch_panel "$_d" && echo "source OK: $(ls "$_d" | tr '\n' ' ')" ;;
    menu)      need_root; INSTALL_DIR="${INSTALL_DIR:-$(find_existing_install || true)}"; manager_menu ;;
    "")        need_root
               # already installed -> full manager menu (start / stop / restart ...); fresh server -> install menu
               if _ex="$(find_existing_install)"; then INSTALL_DIR="${INSTALL_DIR:-$_ex}"; manager_menu; else start_menu; fi ;;
  esac
}

# curl ... | bash : stdin is the script pipe, so read answers from the terminal instead
if [[ ! -t 0 ]] && ( : </dev/tty ) 2>/dev/null; then main "$@" </dev/tty; else main "$@"; fi
exit 0
