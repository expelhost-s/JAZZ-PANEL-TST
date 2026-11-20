#!/usr/bin/env bash
# =====================================================================
#  JAZZ VPS MANAGEMENT PANEL - Self-extracting installer
#  Installs every dependency + every panel file, starts the panel in
#  PM2 and gives you the jazz-panel command (start/stop/restart/...).
#  Supported: Debian 11/12/13, Ubuntu 20.04/22.04/24.04 (run as root)
#  Works on full servers AND on restricted/shared VPS (proot, no systemd, no snap,
#  no mount rights): optional parts are skipped instead of failing the install.
#  Problems?  bash jazz-installer.sh --doctor
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
export PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 PIP_ROOT_USER_ACTION=ignore PIP_BREAK_SYSTEM_PACKAGES=1
export NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false NPM_CONFIG_UPDATE_NOTIFIER=false

# ---------- environment detection (real server vs. shared / proot / container VPS) ----------
# "Restricted" = no systemd, a proot/ptrace fake-root sandbox, or no right to mount filesystems.
# There snap/LXD, loop-mounted disks and systemd services cannot work. The panel itself runs fine,
# so the installer switches to a compatibility mode instead of dying on those optional parts.
# Override with JAZZ_RESTRICTED=1 (force) or JAZZ_RESTRICTED=0 (never).
HAS_SYSTEMD=0; RESTRICTED=0; CAN_MOUNT=1; IN_PROOT=0; HAS_SYS_ADMIN=1; ENV_NOTES=""
detect_env() {
  local tracer d
  [[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
  tracer="$(awk '/^TracerPid:/{print $2}' /proc/self/status 2>/dev/null)"
  if (( ! HAS_SYSTEMD )); then RESTRICTED=1; ENV_NOTES+="no systemd; "; fi
  if [[ -n "${tracer:-}" && "$tracer" != "0" ]] || [[ -n "${PROOT_TMP_DIR:-}${PROOT_L2S_DIR:-}" ]]; then
    RESTRICTED=1; IN_PROOT=1; ENV_NOTES+="proot/ptrace sandbox; "
  fi
  # CAP_SYS_ADMIN (bit 21) is what loop-mounting a per-VPS disk needs
  local cap; cap="$(awk '/^CapEff:/{print $2}' /proc/self/status 2>/dev/null)"
  if [[ -n "${cap:-}" ]] && (( ! (0x$cap >> 21 & 1) )); then HAS_SYS_ADMIN=0; fi
  if [[ $EUID -eq 0 ]]; then
    d="$(mktemp -d 2>/dev/null || echo "/tmp/.jazz-probe.$$")"; mkdir -p "$d" 2>/dev/null
    if mount -t tmpfs jazzprobe "$d" >/dev/null 2>&1; then umount "$d" >/dev/null 2>&1
    else CAN_MOUNT=0; RESTRICTED=1; ENV_NOTES+="cannot mount filesystems; "; fi
    rmdir "$d" 2>/dev/null
  fi
  [[ -n "${JAZZ_RESTRICTED:-}" ]] && RESTRICTED="$JAZZ_RESTRICTED"
  return 0
}

# ---------- apt hardening (works on minimal images and inside proot) ----------
APT_OPTS=(-o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o APT::Sandbox::User=root
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt-get() { command apt-get "${APT_OPTS[@]}" "$@"; }   # every apt-get call below gets these options
apt_install() {   # install, and if dpkg is left half-configured repair it and retry once
  apt-get install -y "$@" >> "$LOG_FILE" 2>&1 && return 0
  quiet dpkg --configure -a --force-confdef --force-confold
  quiet apt-get -f install -y
  apt-get install -y "$@" >> "$LOG_FILE" 2>&1
}
POLICY_CREATED=0
block_services() {   # no systemd -> stop package post-install scripts from trying to start daemons
  [[ -e /usr/sbin/policy-rc.d ]] && return 0
  { printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d && POLICY_CREATED=1; } 2>/dev/null
  return 0
}
unblock_services() { (( POLICY_CREATED )) && rm -f /usr/sbin/policy-rc.d && POLICY_CREATED=0; return 0; }

# ---------- look & feel: colours, symbols, spinner / progress animation ----------
# Disable all animation with:  JAZZ_NO_ANIM=1 bash jazz-installer.sh
if [[ -t 1 ]]; then
  R=$'\033[38;5;203m'; G=$'\033[38;5;42m'; Y=$'\033[38;5;214m'; C=$'\033[38;5;80m'
  B=$'\033[38;5;39m';  W=$'\033[1;97m';    DIM=$'\033[38;5;244m'; D=$'\033[0m'
  GRAD=($'\033[38;5;121m' $'\033[38;5;84m' $'\033[38;5;48m' $'\033[38;5;42m' $'\033[38;5;36m' $'\033[38;5;29m')
else
  R=""; G=""; Y=""; C=""; B=""; W=""; DIM=""; D=""; GRAD=("" "" "" "" "" "")
fi
ANIM=0
[[ -t 1 && "${TERM:-dumb}" != dumb && -z "${JAZZ_NO_ANIM:-}" ]] && ANIM=1
COLS="${COLUMNS:-}"; [[ "$COLS" =~ ^[0-9]+$ ]] || COLS="$(tput cols 2>/dev/null || echo 80)"; [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
ROWS="${LINES:-}";   [[ "$ROWS" =~ ^[0-9]+$ ]] || ROWS="$(tput lines 2>/dev/null || echo 40)"; [[ "$ROWS" =~ ^[0-9]+$ ]] || ROWS=40
SP=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
BAR_W=36; BW=48
STEP_I=0; STEP_N=1; CUR_PCT=0; BANNER_DONE=0; TASK_PID=""; LAST_SECS=0
PROMPT=" ${G}❯${D} ${W}Select option${D} ${DIM}›${D} "

cur_hide() { (( ANIM )) && printf '\033[?25l'; return 0; }
cur_show() { (( ANIM )) && printf '\033[?25h'; return 0; }
dly()  { (( ANIM )) && sleep "${1:-0.04}"; return 0; }                   # small pause (animation only)
nap()  { (( ANIM && ! BANNER_DONE )) && sleep "${1:-0.03}"; return 0; }  # first screen only
rep()  { local i s=""; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }

ok()   { echo " ${G}✔${D} $*${D}"; }
info() { echo " ${C}›${D} $*${D}"; }
warn() { echo " ${Y}!${D} $*${D}"; }
err()  { echo " ${R}✖${D} $*${D}" >&2; }
die()  { cur_show; err "$*"; echo "   ${DIM}Full log : $LOG_FILE${D}" >&2; echo "   ${DIM}Diagnose : bash $(basename "$SELF") --doctor${D}" >&2; unblock_services; exit 1; }
heading() { echo; echo " ${B}▍${D}${W}$1${D}"; }

# spinner: animates while a background job runs, returns the job's exit code
_spin() {   # _spin <pid> <message>
  local pid="$1" msg="$2" i=0 t0=$SECONDS rc
  msg="${msg:0:$((COLS - 16))}"; TASK_PID="$pid"
  if (( ANIM )); then
    cur_hide
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r\033[K %s%s%s %s %s%ss%s' "$C" "${SP[i % 10]}" "$D" "$msg" "$DIM" "$((SECONDS - t0))" "$D"
      i=$((i + 1)); sleep 0.09
    done
    printf '\r\033[K'; cur_show
  else
    info "$msg"
  fi
  wait "$pid"; rc=$?
  TASK_PID=""; LAST_SECS=$((SECONDS - t0))
  return $rc
}
task() {    # task "message" cmd args...   -> spinner, output goes to the log, silent when done
  local desc="$1"; shift
  echo "### $desc :: $*" >> "$LOG_FILE"
  "$@" >> "$LOG_FILE" 2>&1 &
  _spin $! "$desc"
}

# animated progress bar (overall install progress)
_bar() {
  local p="$1" f i s1="" s2=""
  f=$((BAR_W * p / 100))
  for ((i = 0; i < f; i++)); do s1+="━"; done
  for ((i = f; i < BAR_W; i++)); do s2+="─"; done
  printf '\r %s%s%s%s%s %s%3d%%%s' "$G" "$s1" "$DIM" "$s2" "$D" "$W" "$p" "$D"
}
progress() {   # progress <percent>
  local t="$1" p="$CUR_PCT"
  if (( ANIM )); then
    cur_hide
    while (( p < t )); do p=$((p + 3)); (( p > t )) && p=$t; _bar "$p"; sleep 0.01; done
    cur_show
  fi
  _bar "$t"; echo; CUR_PCT=$t
}
section() {    # section "Title"  -> prints title + animated bar
  STEP_I=$((STEP_I + 1))
  echo
  echo " ${B}━━${D} ${W}$1${D}  ${DIM}step $STEP_I of $STEP_N${D}"
  progress $(( (STEP_I - 1) * 100 / STEP_N ))
}

# helper jobs (run through "task" so they can show a spinner)
nodesource_install() { curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh && bash /tmp/nodesource_setup.sh && apt-get install -y nodejs; }
pm2_logrotate()      { pm2 install pm2-logrotate && pm2 set pm2-logrotate:max_size 20M && pm2 set pm2-logrotate:retain 7; }
snapd_up()           { systemctl enable --now snapd.socket snapd.service; snap wait system seed.loaded; return 0; }
pm2_autostart()      { pm2 startup systemd -u root --hp /root; systemctl enable pm2-root; pm2 save; }
sshx_install()       { curl -fsSL https://sshx.io/get -o /tmp/sshx_get.sh && sh /tmp/sshx_get.sh; }

# ---------- banner + menu box ----------
LOGO=(
"     ██╗ █████╗ ███████╗███████╗"
"     ██║██╔══██╗╚══███╔╝╚══███╔╝"
"     ██║███████║  ███╔╝   ███╔╝ "
"██   ██║██╔══██║ ███╔╝   ███╔╝  "
"╚█████╔╝██║  ██║███████╗███████╗"
" ╚════╝ ╚═╝  ╚═╝╚══════╝╚══════╝"
)
banner() {
  clear 2>/dev/null || true
  local i
  echo
  if (( ROWS >= 30 )); then
    for i in 0 1 2 3 4 5; do printf '  %s%s%s\n' "${GRAD[i]}" "${LOGO[i]}" "$D"; nap 0.05; done
    echo
    printf '  %sVPS MANAGEMENT PANEL%s  %s·  Installer & Manager%s\n' "$W" "$D" "$DIM" "$D"
  else   # short terminal -> compact header so the menu still fits
    printf '  %s██ JAZZ%s  %sVPS MANAGEMENT PANEL%s  %s·  Installer & Manager%s\n' "${GRAD[2]}" "$D" "$W" "$D" "$DIM" "$D"
  fi
  echo
}
box_top()    { printf '  %s╭─ %s%s%s %s╮%s\n' "$B" "$W" "$1" "$B" "$(rep ─ $((BW - ${#1} - 3)))" "$D"; nap 0.02; }
box_bottom() { printf '  %s╰%s╯%s\n' "$B" "$(rep ─ "$BW")" "$D"; }
mblank()     { printf '  %s│%s%*s%s│%s\n' "$B" "$D" "$BW" "" "$B" "$D"; nap 0.02; }
mhead()      { printf '  %s│%s  %s%s%s%*s%s│%s\n' "$B" "$D" "$DIM" "$1" "$D" $((BW - 2 - ${#1})) "" "$B" "$D"; nap 0.02; }
mrow() {     # mrow <number> <text> [colour]
  local n="$1" t="$2" col="${3:-$W}"
  printf '  %s│%s  %s%2s%s  %s%s%s%*s%s│%s\n' "$B" "$D" "$G" "$n" "$D" "$col" "$t" "$D" $((BW - 6 - ${#t})) "" "$B" "$D"; nap 0.02
}

need_root() { [[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $(basename "$SELF")"; }

# run a command with a spinner, log everything, show tail on failure
run() {
  local desc="$1"; shift
  if task "$desc" "$@"; then
    if (( LAST_SECS >= 2 )); then ok "$desc ${DIM}${LAST_SECS}s"; else ok "$desc"; fi
    return 0
  fi
  err "$desc failed. Last log lines:"; tail -n 15 "$LOG_FILE" >&2; return 1
}
quiet() { "$@" >> "$LOG_FILE" 2>&1; }   # best-effort, silent
step() {   # step "Description" cmd...  : spinner, then done / skipped (never fails the caller)
  local d="$1"; shift
  if task "$d" "$@"; then ok "$d"; else warn "$d ${DIM}(skipped)"; fi
  return 0
}

ask() {  # ask "Question" default  -> echoes answer
  local q="$1" def="${2:-}" a=""
  if [[ ${JAZZ_YES:-0} == 1 || ! -t 0 ]]; then echo "$def"; return; fi
  read -r -p " ${C}?${D} ${W}$q${D} ${DIM}[$def]${D} ${G}›${D} " a </dev/tty || true
  echo "${a:-$def}"
}
ask_secret() {
  local q="$1" a=""
  if [[ ${JAZZ_YES:-0} == 1 || ! -t 0 ]]; then echo ""; return; fi
  read -r -s -p " ${C}?${D} ${W}$q${D} ${DIM}(blank = auto-generate)${D} ${G}›${D} " a </dev/tty || true; echo >&2
  echo "$a"
}
yesno() { # yesno "Question" Y|N
  local q="$1" def="${2:-n}" a="" hint="y/N"
  [[ "${def,,}" == y* ]] && hint="Y/n"
  if [[ ${JAZZ_YES:-0} == 1 || ! -t 0 ]]; then a="$def"
  else read -r -p " ${C}?${D} ${W}$q${D} ${DIM}[$hint]${D} ${G}›${D} " a </dev/tty || true; a="${a:-$def}"; fi
  [[ "${a,,}" == y* ]]
}
ask_pw() {  # hidden input, Enter = default
  local q="$1" def="$2" a=""
  if [[ ${JAZZ_YES:-0} == 1 || ! -t 0 ]]; then echo "$def"; return; fi
  read -r -s -p " ${C}?${D} ${W}$q${D} ${DIM}[$def]${D} ${G}›${D} " a </dev/tty || true; echo >&2
  echo "${a:-$def}"
}
pause() { read -r -p " ${DIM}↵  ${1:-Press Enter to continue}...${D} " _ </dev/tty || exit 0; }
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
    if task "Downloading panel from GitHub ($JAZZ_REPO)" env GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$JAZZ_BRANCH" "https://github.com/$JAZZ_REPO.git" "$w/repo"; then
      if [[ -f "$w/repo/$JAZZ_ZIP" ]]; then zip="$w/repo/$JAZZ_ZIP"
      elif [[ -f "$w/repo/jazz.py" ]]; then root="$w/repo"
      else zip="$(find "$w/repo" -maxdepth 2 -iname '*.zip' | head -1)"; fi
    else
      warn "git clone failed - trying direct download"
      curl -fsSL "https://raw.githubusercontent.com/$JAZZ_REPO/$JAZZ_BRANCH/$JAZZ_ZIP" -o "$w/panel.zip" >>"$LOG_FILE" 2>&1 && zip="$w/panel.zip"
    fi
  fi
  if [[ -z "${root:-}" ]]; then
    [[ -n "$zip" && -f "$zip" ]] || die "Panel zip '$JAZZ_ZIP' not found in github.com/$JAZZ_REPO ($JAZZ_BRANCH). Is the repo public and the file uploaded?"
    mkdir -p "$w/x"; unzip -q -o "$zip" -d "$w/x" >>"$LOG_FILE" 2>&1 || die "Could not unzip the panel zip (damaged file?)"
    root="$(dirname "$(find "$w/x" -name jazz.py -not -path '*/__MACOSX/*' | head -1)")"
  fi
  [[ -f "$root/jazz.py" ]] || die "jazz.py not found inside the panel zip"
  [[ -f "$root/requirements.txt" ]] || die "requirements.txt not found inside the panel zip"
  mkdir -p "$dest"
  [[ -f "$w/repo/jazz-installer.sh" ]] && grep -q "^fetch_panel()" "$w/repo/jazz-installer.sh" && cp -f "$w/repo/jazz-installer.sh" "$dest/jazz-installer.sh"
  ( cd "$root" && tar cf - --exclude='.git' --exclude='__pycache__' --exclude='.trashed-*' --exclude='*.pyc' --exclude='jazz.db' . ) | tar xf - -C "$dest"
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
    heading "Install location"
    echo "   ${G}1${D}  root   ${DIM}/root/jazz-vps-panel${D}"
    echo "   ${G}2${D}  opt    ${DIM}/opt/jazz-vps-panel${D}"
    echo "   ${G}3${D}  home   ${DIM}/home/jazz-vps-panel${D}"
    read -r -p " ${G}❯${D} ${W}Choose 1 / 2 / 3${D} ${DIM}›${D} " c </dev/tty || exit 1
    case "$c" in
      1) INSTALL_DIR=/root/jazz-vps-panel ;;
      2) INSTALL_DIR=/opt/jazz-vps-panel ;;
      3) INSTALL_DIR=/home/jazz-vps-panel ;;
      *) warn "Please type 1, 2 or 3"; continue ;;
    esac
    read -r -p " ${C}?${D} ${W}Install in $INSTALL_DIR ?${D} ${DIM}[yes/no]${D} ${G}›${D} " a </dev/tty || exit 1
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
  # jazz.py calls socket.gethostbyname(socket.gethostname()) at import time - it crashes (PM2 shows
  # "errored") if the hostname does not resolve. Fix /etc/hosts if we can; setup_venv also installs
  # a Python-level fallback for servers where /etc/hosts cannot be changed (shared / proot).
  local h; h="$(hostname 2>/dev/null)"; [[ -n "$h" ]] || h="$(cat /etc/hostname 2>/dev/null)"; [[ -n "$h" ]] || h=localhost
  getent hosts "$h" >/dev/null 2>&1 && return 0
  if { echo "127.0.1.1 $h" >> /etc/hosts; } 2>/dev/null && getent hosts "$h" >/dev/null 2>&1; then
    ok "Added hostname '$h' to /etc/hosts"; return 0
  fi
  warn "Hostname '$h' does not resolve and /etc/hosts cannot be changed - using the built-in fallback"
}

install_apt() {
  (( RESTRICTED )) && block_services
  quiet dpkg --configure -a --force-confdef --force-confold      # heal any half-finished earlier install
  if ! run "Updating package lists" apt-get update -y; then
    warn "apt update failed - retrying once"; sleep 3
    run "Updating package lists (retry)" apt-get update -y || die "apt update failed"
  fi
  local core="ca-certificates curl wget git tar gzip unzip xz-utils rsync sqlite3 openssl gnupg build-essential python3 python3-dev python3-venv python3-pip libffi-dev libssl-dev"
  local p
  if ! task "Installing core packages" apt_install $core; then
    warn "Bulk install failed - installing the packages one by one"
    tail -n 8 "$LOG_FILE" >&2
    for p in $core; do task "Installing $p" apt_install "$p" || warn "package $p could not be installed"; done
    for p in python3 python3-venv curl git unzip ca-certificates tar; do
      dpkg -s "$p" >/dev/null 2>&1 || die "Essential package '$p' could not be installed"
    done
  fi
  ok "Core packages ready"
  local opt="iptables openssh-client e2fsprogs util-linux lsb-release"
  (( RESTRICTED )) || opt+=" quota tmate snapd uidmap btrfs-progs"     # snap/quota/uidmap need a real server; btrfs-progs = per-VPS dedicated disk pools
  local on=0 ot; ot=$(wc -w <<<"$opt")
  for p in $opt; do on=$((on + 1)); task "Installing optional tools ($on/$ot)  $p" apt_install "$p" || warn "optional package $p not installed"; done
  quiet dpkg --configure -a --force-confdef --force-confold
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

node_major() {
  hash -r 2>/dev/null
  command -v node >/dev/null 2>&1 && node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0
}

install_node_tarball() {   # official binary - needs no apt/snap/systemd, so it works everywhere
  local arch ver="v20.18.1" tmp
  case "$(uname -m)" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; *) return 1 ;; esac
  tmp="$(mktemp -d)"
  if curl -fsSL --retry 3 --connect-timeout 20 "https://nodejs.org/dist/$ver/node-$ver-linux-$arch.tar.xz" -o "$tmp/node.tar.xz" >>"$LOG_FILE" 2>&1 \
     && tar -xJf "$tmp/node.tar.xz" --exclude='CHANGELOG.md' --exclude='LICENSE' --exclude='README.md' -C /usr/local --strip-components=1 >>"$LOG_FILE" 2>&1; then
    rm -rf "$tmp"; hash -r; return 0
  fi
  rm -rf "$tmp"; return 1
}

install_node_pm2() {
  local major; major=$(node_major)
  if (( major < 16 )); then
    if (( ! RESTRICTED )); then
      if task "Installing Node.js 20 (NodeSource)" nodesource_install; then :
      else warn "NodeSource failed"; fi
      major=$(node_major)
    fi
    if (( major < 16 )); then task "Installing Node.js (nodejs.org binary)" install_node_tarball || warn "nodejs.org download failed"; hash -r; major=$(node_major); fi
    if (( major < 16 )); then
      run "Installing nodejs + npm (distro packages)" apt-get install -y nodejs npm || die "Node.js install failed"
    fi
  fi
  command -v node >/dev/null 2>&1 || die "Node.js is not available"
  ok "Node.js $(node -v)"
  command -v npm >/dev/null 2>&1 || { quiet apt-get install -y npm; hash -r; }
  command -v npm >/dev/null 2>&1 || die "npm is not available"
  if ! command -v pm2 >/dev/null 2>&1; then
    run "Installing PM2" npm install -g pm2 \
      || { warn "retrying PM2 install"; run "Installing PM2 (retry)" npm install -g pm2 || die "PM2 install failed"; }
    hash -r
  fi
  ok "PM2 $(pm2 -v 2>/dev/null | tail -1)"
  if (( ! RESTRICTED )); then
    task "Setting up PM2 log rotation" pm2_logrotate || true
  fi
}

# Make sure LXD has storage pool "default" (+ root disk on the default profile + lxdbr0 network).
# The panel needs a pool it can grow and put quotas on, so prefer zfs, then btrfs; "dir" is the last resort.
ensure_lxd_pool() {
  command -v lxc >/dev/null 2>&1 || { warn "lxc command not found"; return 1; }
  task "Waiting for LXD to be ready" lxd waitready --timeout 120
  if lxc storage show default >/dev/null 2>&1; then
    ok "LXD storage pool 'default' exists"
  else
    local avail size drv created=0
    avail=$(df -BG --output=avail /var/snap 2>/dev/null | tail -1 | tr -dc '0-9'); [[ -n "$avail" ]] || avail=20
    size=$(( avail * 6 / 10 )); (( size > 30 )) && size=30; (( size < 5 )) && size=5
    for drv in zfs btrfs dir; do
      if [[ $drv == dir ]]; then
        task "Creating LXD storage pool (dir)" lxc storage create default dir && created=1
      else
        task "Creating LXD storage pool ($drv, ${size}GiB)" lxc storage create default "$drv" "size=${size}GiB" && created=1
      fi
      if (( created )); then ok "Created LXD storage pool 'default' ($drv$( [[ $drv != dir ]] && echo ", ${size}GiB loop-backed"))"; break; fi
      warn "storage driver '$drv' not available on this kernel - trying next"
    done
    (( created )) || { err "Could not create storage pool 'default' (see $LOG_FILE)"; return 1; }
  fi
  # default profile: root disk on pool 'default'
  if lxc profile device show default 2>/dev/null | grep -q '^root:'; then
    quiet lxc profile device set default root pool default
  else
    quiet lxc profile device add default root disk path=/ pool=default
  fi
  # network bridge + nic
  lxc network show lxdbr0 >/dev/null 2>&1 || quiet lxc network create lxdbr0 ipv4.address=auto ipv4.nat=true ipv6.address=none
  lxc profile device show default 2>/dev/null | grep -q '^eth0:' || quiet lxc profile device add default eth0 nic network=lxdbr0 name=eth0
  ok "LXD ready (pool 'default', network lxdbr0)"
}

install_lxd() {
  if (( RESTRICTED )) && [[ ${JAZZ_FORCE_LXD:-0} != 1 ]]; then
    warn "LXD skipped: it needs snap + systemd, which this environment does not have (panel still works)"; return 1
  fi
  if command -v lxc >/dev/null 2>&1 && quiet lxc info; then ok "LXD already installed and running"; ensure_lxd_pool; return $?; fi
  task "Starting snapd" snapd_up
  if ! command -v snap >/dev/null 2>&1; then warn "snap not available - install LXD manually later"; return 1; fi
  task "Installing snap core" snap install core
  if ! snap list lxd >/dev/null 2>&1; then
    run "Installing LXD snap" snap install lxd || { warn "LXD install failed - panel will still work, but VPS creation needs LXD"; return 1; }
  fi
  ln -sf /snap/bin/lxc /usr/local/bin/lxc 2>/dev/null; ln -sf /snap/bin/lxd /usr/local/bin/lxd 2>/dev/null
  ensure_lxd_pool
}

do_fix_lxd() {
  need_root; : >> "$LOG_FILE"
  heading "Fix LXD storage pool"
  info "Checking / repairing LXD ${DIM}(VPS creation error: storage pool 'default' not found)"
  install_lxd || die "LXD repair failed"
  echo; lxc storage list; echo
  ok "Done. Try creating the VPS again in the panel (no restart needed)."
}

# ---------- identity shown inside shared VPS ("Host:" line of neofetch + kernel) ----------
# Default = the MAIN VPS's own Host name and kernel (nothing is faked). The VPS hostname is NOT asked:
# it is generated automatically per VPS. Stored in /etc/jazz-shared/identity (read when a shared VPS starts).
# Change later with:  jazz-panel identity
main_host() {  # what neofetch prints as "Host:" on this (main) VPS
  local d=/sys/devices/virtual/dmi/id h
  h="$(echo "$(cat $d/product_name 2>/dev/null) $(cat $d/product_version 2>/dev/null)" | xargs 2>/dev/null)"
  [[ -n "$h" ]] || h="$(hostname 2>/dev/null)"
  echo "$h"
}
write_identity() {  # write_identity <host> <kernel>
  local h k; h="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._()+-')"; k="$(printf '%s' "$2" | tr -cd 'A-Za-z0-9._+~-')"
  [[ -n "$h" ]] || h="$(main_host)"; [[ -n "$k" ]] || k="$(uname -r)"
  mkdir -p /etc/jazz-shared
  printf 'HOST=%s\nKERNEL=%s\n' "$h" "$k" > /etc/jazz-shared/identity && chmod 644 /etc/jazz-shared/identity
  ok "Shared VPS will show Host '$h' and kernel '$k'"
}
ask_identity() {
  local dh dk h k
  dh="$(main_host)"; dk="$(uname -r)"
  heading "Shared VPS host & kernel"
  echo "   ${DIM}Shown by neofetch inside shared VPS. Enter = keep the MAIN VPS values.${D}"
  h=$(ask "Host shown inside shared VPS" "$dh")
  k=$(ask "Kernel shown inside shared VPS" "$dk")
  write_identity "$h" "$k"
}
do_identity() {
  need_root; mkdir -p /etc/jazz-shared
  ask_identity
  ok "Shared VPS pick it up the next time they are opened (no restart needed)"
}

# ---------- per-VPS dedicated disk (shared hosting accounts get their own ext4 loop volume) ----------
loop_diag() {   # print WHY loop-mounting is (not) possible - used when the self-test fails and by --doctor
  echo " loop diag     : proot=$IN_PROOT  CAP_SYS_ADMIN=$( ((HAS_SYS_ADMIN)) && echo yes || echo NO )  can-mount=$( ((CAN_MOUNT)) && echo yes || echo NO )"
  echo " loop diag     : /dev/loop-control $([[ -e /dev/loop-control ]] && echo present || echo MISSING), loop nodes: $(ls /dev/loop[0-9]* 2>/dev/null | wc -l)"
  echo " loop diag     : kernel loop support: $(grep -qw loop /proc/devices 2>/dev/null && echo yes || echo 'NO (not in /proc/devices)')"
}

loop_selftest() {  # create a 64MB image, mkfs, loop-mount it, read df, clean up. Prints the real error on failure.
  local d=/opt/jazz-shared/disks img m err ld
  mkdir -p "$d"; img="$d/.selftest.img"; m="$(mktemp -d)"
  rm -f "$img"; truncate -s 64M "$img" 2>/dev/null || { err "Not enough disk space to create a test image"; return 1; }
  command -v mkfs.ext4 >/dev/null 2>&1 || { err "mkfs.ext4 is missing (apt install e2fsprogs)"; rm -f "$img"; return 1; }
  mkfs.ext4 -F -q "$img" >>"$LOG_FILE" 2>&1 || { err "mkfs.ext4 failed"; rm -f "$img"; return 1; }
  if err=$(mount -o loop,noatime "$img" "$m" 2>&1); then
    ok "Loop-mount test passed: a 64MB volume shows as $(df -h --output=size "$m" | tail -1 | tr -d ' ') (not the host disk)"
    umount "$m" 2>/dev/null; rm -f "$img"; rmdir "$m" 2>/dev/null; return 0
  fi
  # second try: attach the loop device by hand, then mount it (works where 'mount -o loop' cannot find a free device)
  if ld=$(losetup -f --show "$img" 2>>"$LOG_FILE") && mount -o noatime "$ld" "$m" >>"$LOG_FILE" 2>&1; then
    ok "Loop-mount test passed via losetup ($ld): 64MB volume shows as $(df -h --output=size "$m" | tail -1 | tr -d ' ')"
    umount "$m" 2>/dev/null; losetup -d "$ld" 2>/dev/null; rm -f "$img"; rmdir "$m" 2>/dev/null; return 0
  fi
  [[ -n "${ld:-}" ]] && losetup -d "$ld" 2>/dev/null
  err "Loop-mount FAILED: $err"
  loop_diag >&2
  rm -f "$img"; rmdir "$m" 2>/dev/null
  return 1
}

prepare_storage() {
  # Per-VPS dedicated disks (shared accounts) are ext4 images mounted through /dev/loop*. That needs real root,
  # CAP_SYS_ADMIN and loop devices - NOT systemd. So we no longer skip this in "restricted" mode: we install the
  # tools, create the loop nodes and TEST a real loop mount. Only the test result decides.
  info "Preparing separate-disk support ${DIM}(dedicated storage per shared VPS)"
  (( RESTRICTED )) && block_services
  local pair bin pkg
  for pair in mkfs.ext4:e2fsprogs resize2fs:e2fsprogs losetup:util-linux mount:mount setquota:quota debootstrap:debootstrap systemd-nspawn:systemd-container proot:proot tmux:tmux; do
    bin="${pair%%:*}"; pkg="${pair##*:}"
    command -v "$bin" >/dev/null 2>&1 || task "Installing $pkg" apt_install "$pkg" || warn "package $pkg not installed (needed for $bin)"
  done
  # loop devices: load module now + on every boot, make sure the nodes exist
  quiet modprobe loop
  mkdir -p /etc/modules-load.d 2>/dev/null && echo loop > /etc/modules-load.d/jazz-loop.conf 2>/dev/null
  [[ -e /dev/loop-control ]] || quiet mknod /dev/loop-control c 10 237
  local i; for i in $(seq 0 63); do [[ -e /dev/loop$i ]] || quiet mknod /dev/loop$i b 7 $i; done
  mkdir -p /opt/jazz-shared/disks /etc/jazz-shared
  if ! loop_selftest; then
    warn "This server cannot loop-mount disks, so each shared VPS would show the HOST disk in 'df -h'."
    if (( IN_PROOT )); then
      warn "Cause: the installer runs inside proot/ptrace, which can never mount filesystems. Run it on the real host (not inside proot)."
    elif (( ! HAS_SYS_ADMIN )); then
      warn "Cause: no CAP_SYS_ADMIN. In Docker start the container with --privileged (or --cap-add SYS_ADMIN --device /dev/loop-control)."
    else
      warn "Cause is usually a container/OpenVZ host without loop support or a kernel without the 'loop' module."
    fi
    warn "Fix the cause (KVM/dedicated server or privileged container), then run: jazz-panel fix-storage"
    (( RESTRICTED )) && unblock_services
    return 1
  fi
  (( RESTRICTED )) && unblock_services
  return 0
}

do_fix_storage() {
  need_root; : >> "$LOG_FILE"
  heading "Fix separate disk per VPS"
  prepare_storage || die "Storage support is not available on this server"
  if [[ -x "$CLI_PATH" ]]; then "$CLI_PATH" restart >/dev/null 2>&1 && ok "Panel restarted (re-mounts existing account disks)"; fi
  echo
  ok "Done. NOTE: a shared VPS that was already created without its own disk must be re-created / reinstalled"
  echo "       from the panel once - new ones get their own disk automatically (df -h shows only the assigned size)."
}

install_sshx() {
  command -v sshx >/dev/null 2>&1 && return 0
  if task "Installing sshx (optional web terminal)" sshx_install; then ok "sshx installed"
  else warn "sshx not installed (optional)"; fi
}

setup_files() {
  local tmp; tmp="$(mktemp -d)"
  fetch_panel "$tmp"
  mkdir -p "$INSTALL_DIR"
  if [[ -f "$INSTALL_DIR/jazz.db" ]]; then
    mkdir -p "$INSTALL_DIR/backups"
    cp -a "$INSTALL_DIR/jazz.db" "$INSTALL_DIR/backups/jazz.db.pre-update.$(date +%Y%m%d-%H%M%S)"
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

install_hostfix() {   # Python-level fallback for an unresolvable hostname (see fix_hostname)
  local sp; sp="$(venv/bin/python -c 'import sysconfig;print(sysconfig.get_paths()["purelib"])' 2>/dev/null)"
  [[ -d "$sp" ]] || return 0
  cat > "$sp/jazz_hostfix.py" <<'PY'
# jazz.py runs socket.gethostbyname(socket.gethostname()) when it is imported. If the hostname is not in
# /etc/hosts (shared / proot / minimal images) that raises and the panel never starts. Fall back to 127.0.0.1.
import socket as _s
_orig = _s.gethostbyname
def _gethostbyname(host):
    try:
        return _orig(host)
    except OSError:
        try:
            if host == _s.gethostname():
                return "127.0.0.1"
        except Exception:
            pass
        raise
_s.gethostbyname = _gethostbyname
PY
  echo "import jazz_hostfix" > "$sp/jazz_hostfix.pth"
}

setup_venv() {
  cd "$INSTALL_DIR" || die "cd failed"
  [[ -x venv/bin/python ]] && ! venv/bin/python -c 'import sys;sys.exit(0 if sys.version_info>=(3,10) else 1)' 2>/dev/null && rm -rf venv
  if [[ ! -x venv/bin/python ]]; then
    if ! run "Creating Python virtual environment" "$PYBIN" -m venv venv; then
      warn "python -m venv failed - trying virtualenv instead"
      rm -rf venv
      run "Installing virtualenv" "$PYBIN" -m pip install virtualenv || die "venv creation failed"
      run "Creating virtual environment (virtualenv)" "$PYBIN" -m virtualenv venv || die "venv creation failed"
    fi
  fi
  local PIPF=(--prefer-binary --no-cache-dir --retries 5 --timeout 60)
  task "Preparing pip" venv/bin/python -m pip install "${PIPF[@]}" --upgrade pip setuptools wheel
  tr -d '\r' < requirements.txt | grep -viE '^(pip|setuptools|wheel)==' > .requirements.install
  if task "Installing Python dependencies (can take a few minutes)" venv/bin/python -m pip install "${PIPF[@]}" -r .requirements.install; then
    ok "Python dependencies installed (pinned versions)"
  else
    warn "Pinned versions failed on this Python - retrying with compatible versions"
    sed -E 's/==.*//' .requirements.install | grep -viE '^(colorama)$' > .requirements.loose
    # keep the versions the panel code was written against
    sed -i -E 's/^Flask$/Flask==2.3.3/; s/^Werkzeug$/Werkzeug==2.3.7/; s/^Flask-SocketIO$/Flask-SocketIO==5.3.6/; s/^python-socketio$/python-socketio==5.11.2/; s/^python-engineio$/python-engineio==4.9.0/; s/^Flask-Login$/Flask-Login==0.6.3/' .requirements.loose
    run "Installing Python dependencies (fallback)" venv/bin/python -m pip install "${PIPF[@]}" -r .requirements.loose || die "Python dependency install failed"
  fi
  rm -f .requirements.install .requirements.loose
  local chk
  if ! chk=$(venv/bin/python -c "import flask, flask_login, flask_socketio, flask_cors, paramiko, PIL, psutil, requests, bcrypt, simple_websocket" 2>&1); then
    echo "$chk" >> "$LOG_FILE"; err "$chk"; die "Dependency self-check failed (see log)"
  fi
  install_hostfix
  ok "Dependency self-check passed"
}

write_env() {
  local port="$1" user="$2" pass="$3" email="$4" name="$5" ip="$6" domain="${7:-}"
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    grep -q '^DEDICATED_DISK=' "$INSTALL_DIR/.env" 2>/dev/null || printf '\n# Dedicated storage: own disk pool per dedicated VPS (0 = shared pool)\nDEDICATED_DISK=1\nDEDICATED_POOL_DRIVERS=btrfs,zfs,lvm\n' >> "$INSTALL_DIR/.env"
    ok "Keeping existing configuration (.env)"; return
  fi
  local secret; secret="$(rand 48)"
  cat > "$INSTALL_DIR/.env" <<ENV
# JAZZ VPS MANAGEMENT PANEL configuration  (edit, then: jazz-panel restart)
PANEL_NAME=$name
PANEL_DEVELOPER=JAZZ
HOST=0.0.0.0
PORT=$port
SECRET_KEY=$secret
DATABASE_PATH=$INSTALL_DIR/jazz.db
MAIN_ADMIN_USERNAME=$user
MAIN_ADMIN_PASSWORD=$pass
MAIN_ADMIN_EMAIL=$email
YOUR_SERVER_IP=$ip
PANEL_DOMAIN=$domain
DEFAULT_STORAGE_POOL=default
# Dedicated storage: every dedicated VPS gets its OWN disk pool of exactly its assigned size
# (df -h inside the VPS shows the full assigned disk). 0 = old shared-pool mode.
DEDICATED_DISK=1
DEDICATED_POOL_DRIVERS=btrfs,zfs,lvm
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
    script: 'jazz.py',
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
  fix-lxd) bash "$INSTALL_DIR/jazz-installer.sh" --fix-lxd ;;
  fix-storage) bash "$INSTALL_DIR/jazz-installer.sh" --fix-storage ;;
  identity) bash "$INSTALL_DIR/jazz-installer.sh" --identity ;;
  doctor)  bash "$INSTALL_DIR/jazz-installer.sh" --doctor ;;
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
  jazz-panel fix-lxd      repair LXD storage pool (error: Storage pool not found)
  jazz-panel fix-storage  enable separate disk per VPS (df -h shows only the assigned size)
  jazz-panel identity     change Host / kernel shown inside shared VPS
  jazz-panel doctor       diagnose problems (environment, network, logs)
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
  if (( HAS_SYSTEMD )); then
    task "Enabling auto-start on boot" pm2_autostart
    ok "PM2 auto-start on boot enabled"
  else
    warn "No systemd here, so PM2 cannot auto-start after a reboot. Start it again with:  jazz-panel start"
  fi
}

open_firewall() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    quiet ufw allow "$port"/tcp && ok "ufw: opened port $port/tcp"
  fi
}

health_check() {
  local port="$1" i j f=0 code="" tries=45 up=0 t0=$SECONDS
  (( RESTRICTED )) && tries=120          # proot / shared environments start much slower
  (( ANIM )) || info "Waiting for the panel to answer on port $port (up to $((tries * 2))s) ..."
  cur_hide
  for i in $(seq 1 "$tries"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port/" || true)
    if [[ "$code" =~ ^(200|301|302|401|403)$ ]] && pm2_online; then up=1; break; fi
    if (( ANIM )); then
      for j in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        printf '\r\033[K %s%s%s Waiting for the panel on port %s %s%ss%s' "$C" "${SP[f % 10]}" "$D" "$port" "$DIM" "$((SECONDS - t0))" "$D"
        f=$((f + 1)); sleep 0.1
      done
    else sleep 2; fi
  done
  (( ANIM )) && printf '\r\033[K'
  cur_show
  if (( up )); then ok "Panel is ${W}ONLINE${D} ${DIM}(HTTP $code, $((SECONDS - t0))s)"; return 0; fi
  err "Panel did not come up."
  pm2 describe "$PM2_NAME" 2>/dev/null | grep -E "status|restarts|exec cwd" >&2
  echo "--- panel-error.log (last 40) ---" >&2; tail -n 40 "$INSTALL_DIR/logs/panel-error.log" 2>/dev/null >&2
  echo "--- panel-out.log (last 25) ---" >&2;   tail -n 25 "$INSTALL_DIR/logs/panel-out.log" 2>/dev/null >&2
  return 1
}

# ---------- actions ----------
do_install() {
  need_root
  : > "$LOG_FILE"
  banner; BANNER_DONE=1
  check_os
  (( RESTRICTED )) && warn "Restricted environment detected (${ENV_NOTES%; }) - compatibility mode"

  choose_location
  ok "Install folder: ${W}$INSTALL_DIR"
  local port user pass email name ip domain="" update=0
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    info "Existing installation found - ${W}UPDATE mode${D} ${DIM}(config, database and uploads are kept)"
    update=1
    port=$(env_get PORT); ip=$(env_get YOUR_SERVER_IP); user=$(env_get MAIN_ADMIN_USERNAME); pass="(unchanged)"
  else
    heading "Setup"
    ip="$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    name=$(ask "Panel name" "JAZZ VPS Management Panel")
    port=$(ask "Panel port" "3000")
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || die "Invalid port"
    ip=$(ask "Server public IP (shown for VPS port-forwards)" "$ip")
    domain=$(ask "Panel / tunnel domain, e.g. panel.example.com (Enter = none)" "")
    domain="${domain#http://}"; domain="${domain#https://}"; domain="${domain%%/*}"
  fi
  local want_lxd=1
  if (( RESTRICTED )) && [[ ${JAZZ_FORCE_LXD:-0} != 1 ]]; then
    want_lxd=0
    info "LXD / snap / systemd services are skipped here ${DIM}(no systemd). Per-VPS loop disks are still set up and tested."
  elif (( ! update )) && ! command -v lxc >/dev/null 2>&1; then
    yesno "Install LXD (required to create VPS containers)?" "y" || want_lxd=0
  fi

  STEP_I=0; CUR_PCT=0
  if (( update )); then STEP_N=5; else STEP_N=$(( 6 + want_lxd )); fi

  if (( update )); then
    section "Runtime"
    ensure_python
  else
    section "System packages"
    fix_hostname
    install_apt
    section "Runtime"
    ensure_python
    install_node_pm2
    if (( want_lxd )); then section "Container engine"; install_lxd; fi
    install_sshx
  fi

  section "Panel files"
  setup_files
  setup_venv

  section "Storage"
  prepare_storage || warn "Continuing - the panel works, but per-VPS disks need loop support (jazz-panel fix-storage)"
  unblock_services

  section "Configuration"
  if (( ! update )); then
    echo
    echo " ${W}Admin account${D}  ${DIM}(Enter = default; change later with: jazz-panel admin)${D}"
    user=$(ask "Admin username" "admin")
    email=$(ask "Admin email" "admin@gmail.com")
    pass=$(ask_pw "Admin password" "admin")
  fi
  if (( ! update )) || [[ ! -f /etc/jazz-shared/identity ]]; then ask_identity; fi
  write_env "${port:-3000}" "$user" "$pass" "${email:-admin@gmail.com}" "${name:-JAZZ VPS Management Panel}" "$ip" "$domain"
  write_ecosystem
  write_cli
  port=$(env_get PORT)

  section "Launch"
  start_pm2
  open_firewall "$port"
  health_check "$port" || die "Install finished but the panel is not healthy - see logs above"
  echo
  progress 100

  local dom; dom="$(env_get PANEL_DOMAIN)"
  echo
  echo " ${G}$(rep ━ 54)${D}"; dly
  if (( update )); then echo " ${G}✔${D} ${W}JAZZ VPS MANAGEMENT PANEL UPDATED${D}"; else echo " ${G}✔${D} ${W}JAZZ VPS MANAGEMENT PANEL INSTALLED${D}"; fi
  echo " ${G}$(rep ━ 54)${D}"; dly
  echo
  if [[ -n "$dom" ]]; then
    echo "   ${DIM}Panel URL ${D} ${W}https://$dom${D}  ${DIM}(tunnel -> http://localhost:$port)${D}"; dly
    echo "   ${DIM}Direct URL${D} http://$(env_get YOUR_SERVER_IP):$port"; dly
  else
    echo "   ${DIM}Panel URL ${D} ${W}http://$(env_get YOUR_SERVER_IP):$port${D}"; dly
  fi
  echo "   ${DIM}Username  ${D} ${W}$user${D}"; dly
  echo "   ${DIM}Password  ${D} ${W}$pass${D}  ${DIM}(change: jazz-panel admin)${D}"; dly
  echo "   ${DIM}Folder    ${D} $INSTALL_DIR"; dly
  echo
  echo " ${B}▍${D}${W}Commands${D}"; dly
  echo "   ${G}jazz-panel${D} start | stop | restart | status | logs | info | admin"; dly
  echo "   ${G}pm2${D} list | restart $PM2_NAME | stop $PM2_NAME | logs $PM2_NAME"; dly
  echo
  pm2 list
}

do_doctor() {
  need_root; : >> "$LOG_FILE" 2>/dev/null
  echo "${W}JAZZ installer - diagnostics${D}"
  local u c d h; h="$(hostname 2>/dev/null)"
  [[ -r /etc/os-release ]] && . /etc/os-release
  echo " OS            : ${PRETTY_NAME:-unknown} ($(uname -m), kernel $(uname -r))"
  echo " user / host   : $(id -un) / ${h:-?}   (hostname resolves: $(getent hosts "${h:-localhost}" >/dev/null 2>&1 && echo yes || echo NO))"
  echo " systemd       : $( ((HAS_SYSTEMD)) && echo yes || echo NO )"
  echo " can mount     : $( ((CAN_MOUNT)) && echo yes || echo NO )"
  echo " install mode  : $( ((RESTRICTED)) && echo "RESTRICTED (${ENV_NOTES%; }) -> compatibility mode" || echo "full server" )"
  echo " resources     : $(free -m 2>/dev/null | awk '/Mem:/{print $2" MB RAM"}'), $(df -h / 2>/dev/null | awk 'NR==2{print $4" free on /"}')"
  for u in https://github.com https://pypi.org https://files.pythonhosted.org https://nodejs.org https://registry.npmjs.org; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || true)
    echo " network       : $u -> ${c:-no answer}"
  done
  loop_diag
  echo " versions      : $(python3 --version 2>&1 | head -n1) | node $(command -v node >/dev/null 2>&1 && node -v || echo missing) | pm2 $(command -v pm2 >/dev/null 2>&1 && pm2 -v 2>&1 | tail -1 || echo missing)"
  echo " dpkg state    : $(dpkg --audit 2>/dev/null | head -n 1 | grep -q . && echo "BROKEN (run: dpkg --configure -a)" || echo ok)"
  d="$(find_existing_install || true)"
  if [[ -n "$d" ]]; then
    echo " panel folder  : $d"
    pm2 describe "$PM2_NAME" 2>/dev/null | grep -E "status|restarts" | sed 's/^/ pm2           : /'
    echo "--- $d/logs/panel-error.log (last 25) ---"; tail -n 25 "$d/logs/panel-error.log" 2>/dev/null
  fi
  echo "--- $LOG_FILE (last 30) ---"; tail -n 30 "$LOG_FILE" 2>/dev/null
}

backup_panel_data() {   # backup_panel_data <dir>
  local bk="$1"; mkdir -p "$bk"
  [[ -f "$INSTALL_DIR/jazz.db" ]] && cp -a "$INSTALL_DIR/jazz.db" "$bk/"
  [[ -f "$INSTALL_DIR/.env" ]] && cp -a "$INSTALL_DIR/.env" "$bk/"
  [[ -d "$INSTALL_DIR/static/uploads" ]] && cp -a "$INSTALL_DIR/static/uploads" "$bk/"
  return 0
}
remove_panel_files() { rm -f "$CLI_PATH"; rm -rf "$INSTALL_DIR"; }

do_uninstall() {
  need_root
  [[ -n "$INSTALL_DIR" ]] || INSTALL_DIR="$(find_existing_install || true)"
  [[ -n "$INSTALL_DIR" ]] || { warn "No JAZZ panel installation found"; return 0; }
  : >> "$LOG_FILE"
  echo " ${R}▍${D}${W}Uninstall JAZZ VPS Management Panel${D}"
  echo "   ${DIM}Installed in${D} $INSTALL_DIR"
  echo

  yesno "Remove the panel? (PM2 process, jazz-panel command, panel files)" "n" || { echo " ${DIM}Cancelled.${D}"; return 0; }

  local rm_deps=0 rm_lxd=0 rm_db=0
  yesno "Also remove dependencies? (PM2, Node.js, sshx, tmate, quota)" "n" && rm_deps=1
  if command -v lxc >/dev/null 2>&1; then
    if yesno "Remove LXD too?  ${R}This DELETES ALL VPS containers and images${D}" "n"; then
      yesno "Are you really sure? ALL VPS data will be lost" "n" && rm_lxd=1
    fi
  fi
  yesno "Delete the database? (users, VPS records, settings, uploads)" "n" && rm_db=1

  local yes="${R}REMOVE${D}" no="${DIM}keep${D}"
  echo
  echo " ${W}Summary${D}"
  printf '   %-48s %s\n' "Panel files, PM2 process, jazz-panel command" "$yes"
  printf '   %-48s %s\n' "Dependencies (PM2, Node.js, sshx, tmate, quota)" "$( ((rm_deps)) && echo "$yes" || echo "$no" )"
  printf '   %-48s %s\n' "LXD and all VPS containers" "$( ((rm_lxd)) && echo "$yes" || echo "$no" )"
  printf '   %-48s %s\n' "Database" "$( ((rm_db)) && echo "${R}DELETE${D}" || echo "${no} ${DIM}(backup saved in /root)${D}" )"
  echo
  yesno "Proceed with uninstall?" "n" || { echo " ${DIM}Cancelled.${D}"; return 0; }
  echo

  step "Stopping panel (PM2)" pm2 delete "$PM2_NAME"
  quiet pm2 save --force

  if (( ! rm_db )); then
    local bk="/root/jazz-panel-backup-$(date +%Y%m%d-%H%M%S)"
    step "Saving database backup" backup_panel_data "$bk"
    echo "   ${DIM}Backup folder: $bk${D}"
  fi
  step "Removing panel files and command" remove_panel_files

  if (( rm_deps )); then
    local others=0
    others=$(pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(0)" 2>/dev/null || echo 0)
    if (( others > 0 )); then
      warn "PM2 still runs $others other app(s) - PM2 and Node.js are kept"
    else
      step "Removing PM2 log rotation" pm2 uninstall pm2-logrotate
      quiet pm2 unstartup systemd
      quiet systemctl disable --now pm2-root
      step "Removing PM2" npm uninstall -g pm2
      step "Removing Node.js" apt-get remove -y --purge nodejs
      rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/keyrings/nodesource.gpg /usr/share/keyrings/nodesource.gpg
      rm -rf /root/.pm2
    fi
    step "Removing tmate + quota" apt-get remove -y --purge tmate quota
    step "Removing sshx" rm -f /usr/local/bin/sshx /root/.sshx
    step "Cleaning unused packages" apt-get autoremove -y
  fi

  if (( rm_lxd )); then
    local n
    for n in $(lxc list -c n --format csv 2>/dev/null); do step "Deleting VPS container $n" lxc delete "$n" --force; done
    step "Removing LXD" snap remove --purge lxd
    rm -f /usr/local/bin/lxc /usr/local/bin/lxd
  fi

  echo
  echo " ${G}$(rep ━ 54)${D}"; dly
  echo " ${G}✔${D} ${W}JAZZ VPS MANAGEMENT PANEL has been uninstalled${D}"; dly
  echo " ${G}$(rep ━ 54)${D}"
  echo "   ${DIM}python3, curl, git and other shared packages were left in place.${D}"
  INSTALL_DIR=""
}

pm2_action() {
  need_root; [[ -x "$CLI_PATH" ]] || die "Panel is not installed yet"
  local v d
  case "$1" in
    start)   v="Starting panel";   d="Panel started" ;;
    stop)    v="Stopping panel";   d="Panel stopped" ;;
    restart) v="Restarting panel"; d="Panel restarted" ;;
    *)       "$CLI_PATH" "$1"; return ;;      # status / logs / admin keep their own output
  esac
  if task "$v" "$CLI_PATH" "$1"; then ok "$d"; else err "$v failed (see $LOG_FILE)"; fi
  echo; pm2 list
}

manager_menu() {
  local o
  while true; do
    banner
    box_top "MENU"
    mhead "PANEL"
    mrow 1 "Install / Update panel"
    mrow 2 "Start panel"
    mrow 3 "Stop panel"
    mrow 4 "Restart panel"
    mrow 5 "Status & info"
    mrow 6 "View logs"
    mhead "SETTINGS"
    mrow 7 "Change admin username / email / password"
    mrow 8 "Change shared VPS host / kernel"
    mhead "REPAIR"
    mrow 9 "Fix LXD storage pool"
    mrow 10 "Fix separate disk per VPS"
    mblank
    mrow 11 "Uninstall" "$R"
    mrow 0 "Exit" "$DIM"
    box_bottom
    BANNER_DONE=1
    echo
    read -r -p "$PROMPT" o </dev/tty || exit 0
    echo
    case "$o" in
      1) do_install ;;
      2) pm2_action start ;;
      3) pm2_action stop ;;
      4) pm2_action restart ;;
      5) pm2_action status; "$CLI_PATH" info ;;
      6) pm2_action logs ;;
      7) pm2_action admin ;;
      8) do_identity ;;
      9) do_fix_lxd ;;
      10) do_fix_storage ;;
      11) do_uninstall ;;
      0) exit 0 ;;
      *) warn "Invalid option" ;;
    esac
    echo; pause
  done
}

start_menu() {
  local o
  while true; do
    banner
    box_top "START"
    mrow 1 "Install panel / Update panel"
    mrow 2 "Status & info"
    mrow 3 "Uninstall" "$R"
    mblank
    mrow 0 "Exit" "$DIM"
    box_bottom
    BANNER_DONE=1
    echo
    read -r -p "$PROMPT" o </dev/tty || exit 0
    echo
    case "$o" in
      1) do_install
         echo; pause "Press Enter to open the panel menu"
         manager_menu; exit 0 ;;
      2) if [[ -x "$CLI_PATH" ]]; then "$CLI_PATH" status; "$CLI_PATH" info; else warn "Panel is not installed yet"; fi ;;
      3) do_uninstall ;;
      0) exit 0 ;;
      *) warn "Invalid option" ;;
    esac
    echo; pause
  done
}

usage() {
  cat <<U
$APP_TITLE installer
  bash $(basename "$SELF")               start menu (install / update / status / uninstall)
  bash $(basename "$SELF") --install     install / update (asks questions)
  bash $(basename "$SELF") --install --yes   unattended (defaults, random admin password)
  bash $(basename "$SELF") --uninstall   remove
  bash $(basename "$SELF") --doctor      diagnose a failing install
Env overrides: JAZZ_INSTALL_DIR, JAZZ_RESTRICTED=1|0 (force/disable compatibility mode), JAZZ_FORCE_LXD=1, JAZZ_NO_ANIM=1
U
}

main() {
  trap 'cur_show; [[ -n "$TASK_PID" ]] && { pkill -P "$TASK_PID" 2>/dev/null; kill "$TASK_PID" 2>/dev/null; }; unblock_services; echo; echo " ${DIM}Bye. (The panel keeps running in PM2 - run: jazz-panel menu)${D}"; exit 0' INT
  trap 'cur_show' EXIT
  local action=""
  for a in "$@"; do
    case "$a" in
      --install) action=install ;; --uninstall) action=uninstall ;; --yes|-y) JAZZ_YES=1 ;;
      --selftest) action=selftest ;; --fix-lxd) action=fixlxd ;; --fix-storage) action=fixstorage ;; --identity) action=identity ;; --update) action=install; JAZZ_YES=1 ;; --menu) action=menu ;; --doctor) action=doctor ;; -h|--help) usage; exit 0 ;;
    esac
  done
  : >> "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/jazz-installer.log"   # /var/log not writable? use /tmp
  detect_env
  case "$action" in
    doctor)    do_doctor ;;
    install)   do_install ;;
    fixlxd)    do_fix_lxd ;;
    fixstorage) do_fix_storage ;;
    identity)  do_identity ;;
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
