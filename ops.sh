#!/usr/bin/env bash
# ==============================================================================
# VPS Ops Toolkit (ops.sh)
# 常用 Linux 运维一体化交互脚本（支持交互菜单与子命令直达）
# ==============================================================================

set -u

OPS_VERSION="1.1.0"
OPS_REPO_RAW_URL="https://raw.githubusercontent.com/realLeoKnox/VPS-Ops/main/ops.sh"
OPS_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"

# ------------------------------------------------------------------------------
# 终端颜色与输出函数
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

msg()  { printf '%s[*]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
step() { printf '%s==> %s%s\n' "$C_CYAN" "$*" "$C_RESET"; }
die()  { err "$*"; exit 1; }

# ------------------------------------------------------------------------------
# TTY 输入封装（兼容 curl ... | bash 与测试模式）
# ------------------------------------------------------------------------------
TTY_FD=0
init_tty() {
  if [[ "${OPS_USE_STDIN:-0}" != "1" ]] && [[ -r /dev/tty ]]; then
    exec 3</dev/tty
    TTY_FD=3
  else
    TTY_FD=0
  fi
}

read_prompt() {
  local __var="$1" __prompt="$2" __default="${3-}" val=""
  if [[ -n "$__default" ]]; then
    IFS= read -r -u "$TTY_FD" -p "${__prompt} [${__default}]: " val || return 1
    printf -v "$__var" '%s' "${val:-$__default}"
  else
    IFS= read -r -u "$TTY_FD" -p "${__prompt}: " val || return 1
    printf -v "$__var" '%s' "$val"
  fi
}

read_secret() {
  local __var="$1" __prompt="$2" val=""
  IFS= read -r -s -u "$TTY_FD" -p "${__prompt}: " val || return 1
  printf '\n'
  printf -v "$__var" '%s' "$val"
}

confirm_yn() {
  local prompt="$1" default="${2:-N}" hint="[y/N]" ans=""
  if [[ "$default" =~ ^[Yy]$ ]]; then
    hint="[Y/n]"
  fi
  IFS= read -r -u "$TTY_FD" -p "${prompt} ${hint}: " ans || return 1
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

pause_enter() {
  local _dummy=""
  printf '\n'
  IFS= read -r -u "$TTY_FD" -p "按回车键返回主菜单..." _dummy || true
}

# ------------------------------------------------------------------------------
# 通用辅助函数
# ------------------------------------------------------------------------------
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "该功能需要 root 权限，请使用 root 或 sudo 运行。"
    return 1
  fi
}

require_cmds() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    err "缺少必要命令: ${missing[*]}"
    return 1
  fi
}

is_valid_hostname() {
  local name="$1"
  printf '%s' "$name" | grep -qE '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
}

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.' o1 o2 o3 o4
  read -r o1 o2 o3 o4 <<< "$ip"
  (( 10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255 ))
}

is_valid_ipv6() {
  local ip="$1"
  [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]
}

shell_quote_single() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

mask_proxy_url() {
  local url="$1"
  printf '%s' "$url" | sed -E 's#^([a-zA-Z0-9+.-]+://)([^/@:]+):([^/@]*)@#\1\2:******@#'
}

urlencode() {
  local LC_ALL=C
  local string="$1"
  local length="${#string}"
  local encoded="" pos char hex
  for ((pos = 0; pos < length; pos++)); do
    char="${string:$pos:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        encoded+="$char"
        ;;
      *)
        printf -v hex '%%%02X' "'$char"
        encoded+="$hex"
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# 解析 Swap 大小（支持 512M / 1G / 2048，纯数字默认按 MB），输出 MB 整数
parse_size_to_mb() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  if [[ "$raw" =~ ^([0-9]+)(M|MB)?$ ]]; then
    local val=$((10#${BASH_REMATCH[1]}))
    (( val > 0 )) || return 1
    printf '%d' "$val"
    return 0
  elif [[ "$raw" =~ ^([0-9]+)(G|GB)$ ]]; then
    local val=$((10#${BASH_REMATCH[1]} * 1024))
    (( val > 0 )) || return 1
    printf '%d' "$val"
    return 0
  fi
  return 1
}

detect_os_name() {
  if [[ -r /etc/os-release ]]; then
    awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/,"",$2); print $2; exit}' /etc/os-release
  else
    uname -s
  fi
}

# 安全合并 Docker daemon.json 的日志轮转配置（保留已有字段）
configure_docker_log_rotation() {
  local max_size="${1:-50m}" max_file="${2:-3}"
  local daemon_json="/etc/docker/daemon.json"

  if ! command -v python3 >/dev/null 2>&1; then
    warn "未检测到 python3，跳过自动合并 ${daemon_json}（请手动配置 log-opts）。"
    return 1
  fi

  mkdir -p /etc/docker
  if [[ -f "$daemon_json" ]]; then
    cp -a "$daemon_json" "${daemon_json}.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  DOCKER_LOG_MAX_SIZE="$max_size" DOCKER_LOG_MAX_FILE="$max_file" \
  python3 - "$daemon_json" <<'PY' || return 1
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise SystemExit('daemon.json 顶层不是 JSON 对象')
data.setdefault('log-driver', 'json-file')
opts = data.get('log-opts')
if not isinstance(opts, dict):
    opts = {}
opts['max-size'] = os.environ['DOCKER_LOG_MAX_SIZE']
opts['max-file'] = os.environ['DOCKER_LOG_MAX_FILE']
data['log-opts'] = opts
tmp = path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
os.replace(tmp, path)
PY

  ok "已写入 Docker 日志轮转配置：${daemon_json} (max-size=${max_size}, max-file=${max_file})"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    if confirm_yn "是否立即重启 docker 服务使新日志配置生效（会影响运行中容器）？" N; then
      systemctl restart docker || warn "重启 docker 失败，请手动检查"
    else
      msg "已保存配置，下次重启 docker 后对新建容器生效。"
    fi
  fi
}

# 同步 /etc/hosts（支持 127.0.1.1 及 127.0.0.1 行中残留的旧主机名）
sync_hosts_file() {
  local hosts_file="$1" old_host="$2" new_host="$3"
  local tmp_file
  tmp_file="$(mktemp)"

  if [[ -f "$hosts_file" ]]; then
    awk -v old="$old_host" -v nw="$new_host" '
      BEGIN { updated_127011 = 0 }
      /^[[:space:]]*127\.0\.1\.1([[:space:]]|$)/ {
        print "127.0.1.1 " nw
        updated_127011 = 1
        next
      }
      /^[[:space:]]*127\.0\.0\.1([[:space:]]|$)/ && old != "" && old != "localhost" {
        out = $1
        for (i = 2; i <= NF; i++) {
          tok = ($i == old ? nw : $i)
          out = out " " tok
        }
        print out
        next
      }
      { print }
      END {
        if (!updated_127011) {
          print "127.0.1.1 " nw
        }
      }
    ' "$hosts_file" > "$tmp_file"
  else
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$new_host" > "$tmp_file"
  fi

  cat "$tmp_file" > "$hosts_file"
  rm -f "$tmp_file"
}

# ==============================================================================
# 模块 1：修改主机名
# ==============================================================================
mod_hostname() {
  set -e
  require_root || return 1
  local old new
  old="$(hostname)"
  printf '\n%s=== 修改主机名 ===%s\n' "$C_BOLD" "$C_RESET"
  echo "当前主机名: $old"
  read_prompt new "请输入新主机名（小写字母/数字/连字符，如 hk-hytron-01）" || return 1

  if ! is_valid_hostname "$new"; then
    err "主机名不合法（需 1-63 位小写字母/数字/连字符，不能以连字符开头或结尾），已中止。"
    return 1
  fi

  if [[ "$old" == "$new" ]]; then
    ok "新主机名与当前一致（${old}），无需修改。"
    return 0
  fi

  if ! confirm_yn "确认将 ${old} 改为 ${new}？" N; then
    msg "已取消"
    return 0
  fi

  if command -v hostnamectl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    hostnamectl set-hostname "$new"
  else
    hostname "$new"
    printf '%s\n' "$new" > /etc/hostname
  fi

  sync_hosts_file /etc/hosts "$old" "$new"

  # 云镜像防止重启后被 cloud-init 改回
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
  fi

  ok "主机名: ${old} -> $(hostname)（执行 exec bash 可刷新当前提示符）"
}

# ==============================================================================
# 模块 2：瘦身拳（系统清理）
# ==============================================================================
mod_slim() {
  require_root || return 1
  printf '\n%s=== 系统瘦身拳 ===%s\n' "$C_BOLD" "$C_RESET"

  local log_max tmp_days docker_log_max
  read_prompt log_max "journald 最大日志体积" "100M" || return 1
  read_prompt tmp_days "清理多少天未修改且未访问的临时文件" "7" || return 1
  read_prompt docker_log_max "截断超过该体积的 Docker 容器日志" "50M" || return 1

  if [[ ! "$tmp_days" =~ ^[0-9]+$ ]]; then
    err "天数必须是非负整数"
    return 1
  fi

  used_kb() { df -Pk / | awk 'NR==2{print $3}'; }

  local before_kb io_prefix=()
  before_kb="$(used_kb)"
  command -v nice >/dev/null 2>&1 && io_prefix+=(nice -n 19)
  command -v ionice >/dev/null 2>&1 && io_prefix+=(ionice -c3)

  if command -v journalctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    step "journald 限制为 ${log_max}"
    mkdir -p /etc/systemd/journald.conf.d
    printf '[Journal]\nSystemMaxUse=%s\n' "$log_max" > /etc/systemd/journald.conf.d/99-size.conf
    systemctl restart systemd-journald || warn "重启 systemd-journald 失败"
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-size="$log_max" >/dev/null 2>&1 || true
  fi

  if command -v apt-get >/dev/null 2>&1; then
    step "apt：自动卸载、清除残留配置、清缓存"
    export DEBIAN_FRONTEND=noninteractive
    local apt_opts=(-o DPkg::Lock::Timeout=120 -qq)
    apt-get "${apt_opts[@]}" autoremove --purge -y >/dev/null || true
    local rc_pkgs
    rc_pkgs="$(dpkg -l 2>/dev/null | awk '/^rc/{print $2}')"
    if [[ -n "$rc_pkgs" ]]; then
      # shellcheck disable=SC2086
      apt-get "${apt_opts[@]}" purge -y $rc_pkgs >/dev/null || true
    fi
    apt-get "${apt_opts[@]}" clean || true
  elif command -v dnf >/dev/null 2>&1; then
    step "dnf：自动卸载并清理缓存"
    dnf -q autoremove -y >/dev/null 2>&1 || true
    dnf -q clean all >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    step "yum：清理缓存"
    yum -q clean all >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    step "apk：清缓存"
    apk cache clean >/dev/null 2>&1 || true
    rm -rf /var/cache/apk/*
  fi

  step "删除轮转后的旧日志"
  "${io_prefix[@]}" find /var/log -xdev -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' -o -name '*.old' \) -delete 2>/dev/null || true

  # 使用 -mtime 与 -atime 双条件，避免 relatime/noatime 下误删仍被写入的临时文件
  step "清理 ${tmp_days} 天未修改且未访问的临时文件"
  "${io_prefix[@]}" find /tmp /var/tmp -xdev -mindepth 1 -type f -mtime "+${tmp_days}" -atime "+${tmp_days}" -delete 2>/dev/null || true

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    step "Docker：悬空镜像、构建缓存、超过 ${docker_log_max} 的容器日志"
    docker image prune -f >/dev/null || true
    docker builder prune -f >/dev/null 2>&1 || true
    if [[ -d /var/lib/docker/containers ]]; then
      find /var/lib/docker/containers -name '*-json.log' -size "+${docker_log_max}" -exec truncate -s 0 {} + 2>/dev/null || true
    fi

    if [[ ! -f /etc/docker/daemon.json ]] || ! grep -q '"max-size"' /etc/docker/daemon.json 2>/dev/null; then
      printf '\n'
      warn "检测到 /etc/docker/daemon.json 尚未配置日志轮转限额（仅手动截断治标不治本）。"
      if confirm_yn "是否顺便配置 Docker 全局日志轮转（max-size=50m, max-file=3）？" N; then
        configure_docker_log_rotation "50m" "3" || true
      fi
    fi
  fi

  local after_kb freed_mb
  after_kb="$(used_kb)"
  freed_mb=$(( (before_kb - after_kb) / 1024 ))
  printf '\n'
  df -h / | awk -v f="$freed_mb" 'NR==2{printf "根分区：已用 %s / %s（%s），本次释放 %s MB\n",$3,$2,$5,f}'
}

# ==============================================================================
# 模块 3：开启 TCP BBR
# ==============================================================================
mod_bbr() {
  set -e
  require_root || return 1
  printf '\n%s=== 开启 TCP BBR ===%s\n' "$C_BOLD" "$C_RESET"

  local virt=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  case "$virt" in
    lxc*|openvz|docker|podman)
      err "检测到容器环境 (${virt})，无法直接修改内核开启 BBR。"
      return 1
      ;;
  esac

  require_cmds sysctl || return 1

  local cur_cc cur_qdisc
  cur_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  cur_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  if [[ "$cur_cc" == "bbr" && "$cur_qdisc" == "fq" ]]; then
    ok "BBR 已开启（cc=bbr, qdisc=fq），无需改动。"
    return 0
  fi

  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    err "当前内核不支持 BBR：$(uname -r)"
    return 1
  fi

  mkdir -p /etc/modules-load.d /etc/sysctl.d
  printf 'tcp_bbr\n' > /etc/modules-load.d/bbr.conf
  printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > /etc/sysctl.d/99-bbr.conf
  sysctl --system >/dev/null

  ok "cc=$(sysctl -n net.ipv4.tcp_congestion_control)  qdisc=$(sysctl -n net.core.default_qdisc)"
}

# ==============================================================================
# 模块 4：Swap 交互式管理（新增 / 修改大小 / 删除 / swappiness / 兼容 Btrfs）
# ==============================================================================
mod_swap() {
  require_root || return 1
  printf '\n%s=== Swap 交互式管理 ===%s\n' "$C_BOLD" "$C_RESET"

  local swapfile="/swapfile"
  local root_fstype
  root_fstype="$(df -T / 2>/dev/null | awk 'NR==2{print $2}')"

  show_swap_state() {
    echo "当前内存与 Swap："
    free -h 2>/dev/null || true
    echo
    echo "当前已启用 Swap 设备："
    swapon --show 2>/dev/null || echo "（无）"
    echo
    echo "根分区：文件系统 ${root_fstype:-unknown}，可用 $(df -h / | awk 'NR==2{print $4 " / " $2 " (已用 " $5 ")"}')"
    if [[ -r /proc/sys/vm/swappiness ]]; then
      echo "当前 vm.swappiness：$(cat /proc/sys/vm/swappiness)"
    fi
  }

  show_swap_state
  printf '\n'
  echo "1) 创建或修改 ${swapfile} 大小"
  echo "2) 调整 vm.swappiness"
  echo "3) 关闭并删除 ${swapfile}"
  echo "0) 返回"
  local op
  read_prompt op "请选择操作" "1" || return 1

  case "$op" in
    1)
      local size_in size_mb avail_mb
      read_prompt size_in "请输入目标 Swap 大小（如 512M / 1G / 2G，纯数字默认 MB）" "1G" || return 1
      if ! size_mb="$(parse_size_to_mb "$size_in")"; then
        err "无效大小格式：${size_in}"
        return 1
      fi

      local cur_file_mb=0
      if [[ -f "$swapfile" ]]; then
        cur_file_mb=$(( $(stat -c '%s' "$swapfile" 2>/dev/null || echo 0) / 1024 / 1024 ))
      fi
      avail_mb="$(df -Pm / | awk 'NR==2{print $4}')"
      local effective_avail=$(( avail_mb + cur_file_mb ))
      if (( size_mb >= effective_avail - 128 )); then
        err "目标大小 ${size_mb}MB 超出根分区安全可用空间（约 ${effective_avail}MB，已预留 128MB 缓冲）。"
        return 1
      fi

      if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$swapfile"; then
        warn "检测到已启用 ${swapfile}（约 ${cur_file_mb}MB），修改大小需要先 swapoff。"
        local swap_used_mb mem_avail_mb
        swap_used_mb="$(free -m | awk '/^Swap:/{print $3}')"
        mem_avail_mb="$(free -m | awk '/^Mem:/{print $7}')"
        if [[ -n "$swap_used_mb" && -n "$mem_avail_mb" ]] && (( swap_used_mb > mem_avail_mb )); then
          warn "当前已用 Swap (${swap_used_mb}MB) 大于可用内存 (${mem_avail_mb}MB)，swapoff 可能触发 OOM！"
        fi
        confirm_yn "确认先关闭并重建 ${swapfile} 为 ${size_mb}MB？" N || { msg "已取消"; return 0; }
        swapoff "$swapfile" || { err "swapoff 失败"; return 1; }
        rm -f "$swapfile"
      elif [[ -e "$swapfile" ]]; then
        confirm_yn "检测到未启用的 ${swapfile}，是否覆盖重建为 ${size_mb}MB？" N || { msg "已取消"; return 0; }
        rm -f "$swapfile"
      else
        confirm_yn "确认创建 ${size_mb}MB 的 ${swapfile}？" Y || { msg "已取消"; return 0; }
      fi

      # 捕获中断，避免残留半截文件
      trap 'rm -f -- "$swapfile"; err "操作中断，已清理未完成的 ${swapfile}"; exit 130' INT TERM

      # Btrfs 必须先创建空文件并关闭 COW（chattr +C），否则 swapon 会失败
      if [[ "$root_fstype" == "btrfs" ]]; then
        step "检测到 Btrfs 文件系统，为 ${swapfile} 设置 nocow (chattr +C)..."
        : > "$swapfile"
        chmod 600 "$swapfile"
        if command -v chattr >/dev/null 2>&1; then
          chattr +C "$swapfile" || warn "chattr +C 失败，swapon 可能不兼容当前 Btrfs 配置"
        else
          warn "未找到 chattr 命令，Btrfs 上 swapon 可能会失败"
        fi
      fi

      step "写入 ${size_mb}MB Swap 文件（${swapfile}）..."
      local dd_args=(if=/dev/zero of="$swapfile" bs=1M count="$size_mb" conv=notrunc)
      if dd --help 2>&1 | grep -q 'status='; then
        dd_args+=(status=progress)
      fi
      if ! dd "${dd_args[@]}"; then
        rm -f "$swapfile"
        trap - INT TERM
        err "写入 ${swapfile} 失败，已清理残留文件。"
        return 1
      fi
      chmod 600 "$swapfile"
      mkswap "$swapfile" >/dev/null
      if ! swapon "$swapfile"; then
        rm -f "$swapfile"
        trap - INT TERM
        err "swapon 失败（如在 LXC/OpenVZ 容器中或不支持的文件系统上可能无法开启），已清理。"
        return 1
      fi
      trap - INT TERM

      if ! grep -qE "^${swapfile}[[:space:]]" /etc/fstab 2>/dev/null; then
        printf '%s none swap sw 0 0\n' "$swapfile" >> /etc/fstab
      fi

      ok "Swap 配置完成！"
      swapon --show
      free -h
      ;;

    2)
      local swappiness
      read_prompt swappiness "请输入 vm.swappiness (0-100，VPS 常用 10~60)" "10" || return 1
      if [[ ! "$swappiness" =~ ^[0-9]+$ ]] || (( swappiness < 0 || swappiness > 100 )); then
        err "无效值，必须是 0-100 的整数。"
        return 1
      fi
      sysctl -w "vm.swappiness=${swappiness}" >/dev/null
      mkdir -p /etc/sysctl.d
      printf 'vm.swappiness = %s\n' "$swappiness" > /etc/sysctl.d/99-swap.conf
      ok "已设置 vm.swappiness = ${swappiness}（已持久化到 /etc/sysctl.d/99-swap.conf）"
      ;;

    3)
      if [[ ! -e "$swapfile" ]] && ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$swapfile"; then
        warn "未检测到 ${swapfile}"
        return 0
      fi
      confirm_yn "确认关闭并彻底删除 ${swapfile}？" N || { msg "已取消"; return 0; }
      if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$swapfile"; then
        swapoff "$swapfile" || { err "swapoff 失败"; return 1; }
      fi
      rm -f "$swapfile"
      if [[ -f /etc/fstab ]]; then
        sed -i -E "\|^${swapfile}[[:space:]]|d" /etc/fstab
      fi
      ok "已删除 ${swapfile} 并移除 /etc/fstab 对应条目。"
      free -h
      ;;

    0)
      msg "返回主菜单"
      ;;

    *)
      err "无效选择"
      return 1
      ;;
  esac
}

# ==============================================================================
# 模块 5：Ookla SpeedTest（支持临时测速用完即删 / 永久安装 / 卸载）
# ==============================================================================
mod_speedtest() {
  set -e
  printf '\n%s=== Ookla SpeedTest ===%s\n' "$C_BOLD" "$C_RESET"
  require_cmds curl tar || return 1

  local bin_path="" cleanup_dir="" mode=""
  trap '[[ -z "${cleanup_dir:-}" ]] || rm -rf -- "$cleanup_dir"' EXIT

  download_ookla_to_dir() {
    local dst_dir="$1" arch_tag tgz_name url
    case "$(uname -m)" in
      x86_64|amd64)  arch_tag="x86_64" ;;
      aarch64|arm64) arch_tag="aarch64" ;;
      armv7l)        arch_tag="armhf" ;;
      i386|i686)     arch_tag="i386" ;;
      *) err "暂不支持的 CPU 架构: $(uname -m)"; return 1 ;;
    esac
    tgz_name="ookla-speedtest-1.2.0-linux-${arch_tag}.tgz"
    url="https://install.speedtest.net/app/cli/${tgz_name}"
    step "下载 ${tgz_name}..."
    curl -fsSL --connect-timeout 15 --retry 2 "$url" -o "${dst_dir}/${tgz_name}"
    tar -xzf "${dst_dir}/${tgz_name}" -C "$dst_dir" speedtest
    chmod 755 "${dst_dir}/speedtest"
  }

  if command -v speedtest >/dev/null 2>&1 && speedtest --version 2>/dev/null | grep -qi 'ookla'; then
    local existing_bin
    existing_bin="$(command -v speedtest)"
    ok "已检测到 Ookla Speedtest: ${existing_bin}"
    echo "1) 直接测速"
    echo "2) 重新下载安装到 /usr/local/bin/speedtest 并测速"
    echo "3) 卸载 /usr/local/bin/speedtest"
    echo "0) 返回"
    read_prompt mode "请选择操作" "1" || return 1
    case "$mode" in
      1) bin_path="$existing_bin" ;;
      2)
        require_root || return 1
        cleanup_dir="$(mktemp -d)"
        download_ookla_to_dir "$cleanup_dir"
        install -m 755 "${cleanup_dir}/speedtest" /usr/local/bin/speedtest
        rm -rf "$cleanup_dir"; cleanup_dir=""
        bin_path="/usr/local/bin/speedtest"
        ok "已更新 /usr/local/bin/speedtest"
        ;;
      3)
        require_root || return 1
        if [[ -f /usr/local/bin/speedtest ]]; then
          rm -f /usr/local/bin/speedtest
          ok "已卸载 /usr/local/bin/speedtest"
        else
          warn "未找到 /usr/local/bin/speedtest（当前命令位于 ${existing_bin}，请通过包管理器卸载）"
        fi
        return 0
        ;;
      0) msg "返回主菜单"; return 0 ;;
      *) err "无效选择"; return 1 ;;
    esac
  else
    echo "1) 临时下载并测速，测完自动删除（推荐，不残留文件且无需 root）"
    echo "2) 安装到 /usr/local/bin/speedtest 并测速（保留命令）"
    echo "0) 返回"
    read_prompt mode "请选择方式" "1" || return 1
    case "$mode" in
      1)
        cleanup_dir="$(mktemp -d)"
        download_ookla_to_dir "$cleanup_dir"
        bin_path="${cleanup_dir}/speedtest"
        ;;
      2)
        require_root || return 1
        cleanup_dir="$(mktemp -d)"
        download_ookla_to_dir "$cleanup_dir"
        install -m 755 "${cleanup_dir}/speedtest" /usr/local/bin/speedtest
        rm -rf "$cleanup_dir"; cleanup_dir=""
        bin_path="/usr/local/bin/speedtest"
        ok "已安装到 /usr/local/bin/speedtest"
        ;;
      0) msg "返回主菜单"; return 0 ;;
      *) err "无效选择"; return 1 ;;
    esac
  fi

  local server_id=""
  read_prompt server_id "指定测速节点 Server ID（留空自动选择最佳节点）" "" || return 1
  if [[ -n "$server_id" ]]; then
    if [[ ! "$server_id" =~ ^[0-9]+$ ]]; then
      err "Server ID 必须是纯数字"
      return 1
    fi
    "$bin_path" --accept-license --accept-gdpr -s "$server_id"
  else
    "$bin_path" --accept-license --accept-gdpr
  fi

  if [[ -n "$cleanup_dir" ]]; then
    rm -rf -- "$cleanup_dir"
    cleanup_dir=""
    ok "测速完成，已自动清理临时 Speedtest 文件。"
  fi
}

# ==============================================================================
# 模块 6：快速 GOST 开 SOCKS5 / HTTP 代理（实例管理器）
# ==============================================================================
mod_gost() {
  set -Eeuo pipefail
  umask 077

  local VER="3.3.0"
  local PREFIX="/usr/local/bin"
  local CONF_DIR="/etc/gost/instances"
  local BACKUP_DIR="/var/backups/gost-manager"
  local UNIT_DIR="/etc/systemd/system"
  local GOST_USER="gost"
  local TMP=""
  trap '[[ -z "${TMP:-}" ]] || rm -rf -- "$TMP"' EXIT

  require_root || return 1
  require_cmds systemctl python3 curl tar sha256sum awk grep ss install mktemp cp || return 1

  local ARCH="" BINARY="" SVC="" UNIT="" DROP="" CONF="" BK=""
  local PORT="" PROTO="" BIND="" IPV4="" AUTH="" USERNAME="" PASSWORD="" RUN_USER="root"

  gost_arch() {
    case "$(uname -m)" in
      x86_64|amd64)  ARCH="amd64" ;;
      aarch64|arm64) ARCH="arm64" ;;
      armv7l)        ARCH="armv7" ;;
      i386|i686)     ARCH="386" ;;
      *) die "暂不支持的 CPU 架构: $(uname -m)" ;;
    esac
  }

  gost_ensure_user() {
    if id -u "$GOST_USER" >/dev/null 2>&1; then
      RUN_USER="$GOST_USER"
      return 0
    fi
    if command -v useradd >/dev/null 2>&1; then
      if useradd --system --no-create-home --shell /usr/sbin/nologin "$GOST_USER" 2>/dev/null \
        || useradd -r -M -s /sbin/nologin "$GOST_USER" 2>/dev/null; then
        RUN_USER="$GOST_USER"
        return 0
      fi
    elif command -v adduser >/dev/null 2>&1; then
      if adduser -S -H -s /sbin/nologin "$GOST_USER" 2>/dev/null; then
        RUN_USER="$GOST_USER"
        return 0
      fi
    fi
    warn "无法创建低权限用户 ${GOST_USER}，将回退以 root 运行该实例。"
    RUN_USER="root"
  }

  gost_install_binary() {
    gost_arch
    BINARY="${PREFIX}/gost-v${VER}"
    if [[ -x "$BINARY" ]]; then
      "$BINARY" -V >/dev/null || die "已有二进制不可用: $BINARY"
      ok "复用 $BINARY"
      return
    fi
    TMP="$(mktemp -d)"
    local file="gost_${VER}_linux_${ARCH}.tar.gz"
    local url="https://github.com/go-gost/gost/releases/download/v${VER}"
    msg "下载 ${file}"
    curl -fLsS --retry 3 --connect-timeout 15 --max-time 120 "${url}/${file}" -o "${TMP}/${file}" || die "下载失败"
    curl -fLsS --retry 3 --connect-timeout 15 --max-time 30 "${url}/checksums.txt" -o "${TMP}/checksums.txt" || die "下载校验文件失败"
    local expected actual
    expected="$(awk -v f="$file" '$2==f || $2=="*"f {print $1}' "${TMP}/checksums.txt" | head -1)"
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || die "缺少 SHA256 校验项"
    actual="$(sha256sum "${TMP}/${file}" | awk '{print $1}')"
    [[ "${expected,,}" == "${actual,,}" ]] || die "SHA256 不匹配"
    tar -xzf "${TMP}/${file}" -C "$TMP" || die "解压失败"
    [[ -f "${TMP}/gost" ]] || die "压缩包不含 gost"
    install -m 0755 "${TMP}/gost" "$BINARY"
    "$BINARY" -V || die "新版二进制无法执行"
    rm -rf "$TMP"; TMP=""
    ok "安装 ${BINARY} 完成"
  }

  gost_validate_name() {
    [[ "$SVC" =~ ^gost-[A-Za-z0-9_-]+$ ]] || die "服务名须为 gost- 开头的字母、数字、下划线、短横线"
  }

  gost_paths() {
    UNIT="${UNIT_DIR}/${SVC}.service"
    DROP="${UNIT_DIR}/${SVC}.service.d"
    CONF="${CONF_DIR}/${SVC}.json"
  }

  gost_service_info() {
    msg "服务：${SVC}"
    systemctl show "$SVC" -p ActiveState -p SubState -p User -p FragmentPath -p ExecStart --no-pager 2>/dev/null \
      | sed -E 's#(socks5?://|https?://)[^ @]+@#\1***@#g' || true
    systemctl cat "$SVC" 2>/dev/null \
      | sed -E 's#(socks5?://|https?://)[^ @]+@#\1***@#g' \
      | grep -E '^# |^User=|^ExecStart=|^RestrictAddressFamilies=|^Description=' || true
  }

  gost_port_in_use() {
    local bind_ip="$1" port="$2"
    if [[ "$bind_ip" == "0.0.0.0" || "$bind_ip" == "::" ]]; then
      ss -H -lnt | awk '{print $4}' | grep -Eq ":${port}$"
    else
      local target_addr="$bind_ip"
      [[ "$bind_ip" == *:* ]] && target_addr="[${bind_ip}]"
      ss -H -lnt | awk -v t="${target_addr}:${port}" -v p=":${port}" '
        $4 == t || $4 == "0.0.0.0" p || $4 == "*" p || $4 == "[::]" p { found = 1 }
        END { exit(found ? 0 : 1) }
      '
    fi
  }

  gost_config_wizard() {
    local choice
    read_prompt VER "GOST 版本号" "$VER" || die "终端输入中断"
    [[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] || die "版本号格式非法"

    read_prompt PORT "监听端口" "50166" || die "终端输入中断"
    [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die "端口不合法"
    PORT=$((10#$PORT))
    (( PORT >= 1 && PORT <= 65535 )) || die "端口越界"

    read_prompt SVC "systemd 实例名" "gost-${PORT}" || die "终端输入中断"
    SVC="${SVC%.service}"
    gost_validate_name
    gost_paths

    printf '协议：1 SOCKS5；2 HTTP\n'
    read_prompt choice "选择" "1" || die "终端输入中断"
    case "$choice" in
      1) PROTO="socks5" ;;
      2) PROTO="http" ;;
      *) die "无效选项" ;;
    esac

    printf '监听：1 全部 IPv4；2 全部 IPv6；3 本机 IPv4；4 选择本机网卡 IP；5 手动输入 IP\n'
    read_prompt choice "选择" "1" || die "终端输入中断"
    case "$choice" in
      1) BIND="0.0.0.0" ;;
      2) BIND="::" ;;
      3) BIND="127.0.0.1" ;;
      4)
        require_cmds ip || die "缺少 ip 命令"
        local ADDRS=() i
        mapfile -t ADDRS < <(ip -o addr show | awk '$3=="inet" || $3=="inet6" {split($4,a,"/"); if(a[1]!="::1" && a[1]!="127.0.0.1" && a[1]!~/^fe80:/) print a[1]}')
        (( ${#ADDRS[@]} > 0 )) || die "没有检测到可用 IP"
        for i in "${!ADDRS[@]}"; do
          printf '%d) %s\n' "$((i + 1))" "${ADDRS[$i]}"
        done
        read_prompt choice "序号" "1" || die "终端输入中断"
        [[ "$choice" =~ ^[0-9]+$ ]] || die "无效序号"
        (( choice >= 1 && choice <= ${#ADDRS[@]} )) || die "序号越界"
        BIND="${ADDRS[$((choice - 1))]}"
        ;;
      5) read_prompt BIND "输入 IP" "0.0.0.0" || die "终端输入中断" ;;
      *) die "无效选项" ;;
    esac

    python3 - "$BIND" <<'PY' || die "IP 地址非法"
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY

    printf '出站模式：1 IPv4-only（严格限制进程 IPv6 socket）；2 双栈\n'
    read_prompt choice "选择" "1" || die "终端输入中断"
    case "$choice" in
      1) IPV4=1 ;;
      2) IPV4=0 ;;
      *) die "无效选项" ;;
    esac
    [[ "$IPV4" == 0 || "$BIND" != *:* ]] || die "严格 IPv4-only 与 IPv6 监听不能同时使用"

    read_prompt choice "启用用户名密码认证 Y/n" "Y" || die "终端输入中断"
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      AUTH=1
      read_prompt USERNAME "用户名" "LeoKnox" || die "终端输入中断"
      [[ -n "$USERNAME" ]] || die "用户名为空"
      read_secret PASSWORD "代理密码（隐藏输入）" || die "密码输入中断"
      [[ -n "$PASSWORD" ]] || die "密码不可为空"
    elif [[ "$choice" =~ ^[Nn]$ ]]; then
      AUTH=0
      USERNAME=""
      PASSWORD=""
      warn "无认证公网代理风险极高"
      confirm_yn "确定继续无认证?" N || die "已取消"
    else
      die "无效认证选项"
    fi
  }

  gost_write_config() {
    gost_ensure_user
    install -d -m 0750 "$CONF_DIR"
    if [[ "$RUN_USER" != "root" ]]; then
      chown "root:${RUN_USER}" "$CONF_DIR" 2>/dev/null || true
    fi
    local output="$1"
    GOST_PROTO="$PROTO" GOST_BIND="$BIND" GOST_PORT="$PORT" GOST_NAME="$SVC" \
    GOST_AUTH="$AUTH" GOST_USERNAME="$USERNAME" GOST_PASSWORD="$PASSWORD" GOST_IPV4="$IPV4" \
    python3 - "$output" <<'PY'
import json, os, sys
x = os.environ
b = x['GOST_BIND']
addr = (f'[{b}]' if ':' in b else b) + ':' + x['GOST_PORT']
s = {
    'name': x['GOST_NAME'],
    'addr': addr,
    'handler': {'type': x['GOST_PROTO']},
    'listener': {'type': 'tcp'},
}
if x['GOST_AUTH'] == '1':
    s['handler']['auth'] = {'username': x['GOST_USERNAME'], 'password': x['GOST_PASSWORD']}
c = {'services': [s]}
if x['GOST_IPV4'] == '1':
    s['resolver'] = 'only-v4'
    c['resolvers'] = [{
        'name': 'only-v4',
        'nameservers': [
            {'addr': '1.1.1.1', 'only': 'ipv4'},
            {'addr': '8.8.8.8', 'only': 'ipv4'},
        ],
    }]
with open(sys.argv[1], 'w') as f:
    json.dump(c, f, ensure_ascii=False, indent=2)
PY
    if [[ "$RUN_USER" != "root" ]]; then
      chown "root:${RUN_USER}" "$output"
      chmod 0640 "$output"
    else
      chmod 0600 "$output"
    fi
  }

  gost_write_unit() {
    local output="$1"
    local cap_line=""
    if [[ "$RUN_USER" != "root" ]] && (( PORT < 1024 )); then
      cap_line="AmbientCapabilities=CAP_NET_BIND_SERVICE"
    fi
    cat > "$output" <<EOF
[Unit]
Description=GOST v${VER} ${PROTO} ${SVC}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
ExecStart=${BINARY} -C ${CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
${cap_line}
$( [[ "$IPV4" == 1 ]] && echo 'RestrictAddressFamilies=AF_UNIX AF_INET' || : )

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$output"
  }

  gost_backup() {
    BK="${BACKUP_DIR}/${SVC}-$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 0700 "$BK"
    [[ ! -e "$UNIT" ]] || cp -a "$UNIT" "${BK}/unit.service"
    [[ ! -d "$DROP" ]] || cp -a "$DROP" "${BK}/drop-in"
    [[ ! -e "$CONF" ]] || cp -a "$CONF" "${BK}/instance.json"
    local original_cfg
    original_cfg="$(systemctl show "$SVC" -p ExecStart --value 2>/dev/null | grep -oE '(/[^ ;]+\.(json|yaml|yml))' | head -1 || true)"
    if [[ -n "$original_cfg" && -f "$original_cfg" && "$original_cfg" != "$CONF" ]]; then
      cp -a "$original_cfg" "${BK}/external-config.$(basename "$original_cfg" | sed 's/[^a-zA-Z0-9_.-]/_/g')"
      printf '%s\n' "$original_cfg" > "${BK}/external-config-path.txt"
    fi
    systemctl is-enabled --quiet "$SVC" && echo 1 > "${BK}/was-enabled" || echo 0 > "${BK}/was-enabled"
    systemctl is-active --quiet "$SVC" && echo 1 > "${BK}/was-active" || echo 0 > "${BK}/was-active"
    ok "备份：${BK}"
  }

  gost_restore() {
    local b="$1"
    msg "恢复旧 systemd 单元、override 与实例配置"
    systemctl stop "$SVC" >/dev/null 2>&1 || true
    rm -f "$UNIT" "$CONF"
    rm -rf "$DROP"
    [[ ! -f "${b}/unit.service" ]] || cp -a "${b}/unit.service" "$UNIT"
    [[ ! -d "${b}/drop-in" ]] || cp -a "${b}/drop-in" "$DROP"
    [[ ! -f "${b}/instance.json" ]] || cp -a "${b}/instance.json" "$CONF"
    systemctl daemon-reload
    if [[ "$(cat "${b}/was-enabled")" == "1" ]]; then
      systemctl enable "$SVC" >/dev/null 2>&1 || true
    else
      systemctl disable "$SVC" >/dev/null 2>&1 || true
    fi
    if [[ "$(cat "${b}/was-active")" == "1" ]]; then
      systemctl start "$SVC" || warn "旧服务启动失败，请手动排查"
    fi
  }

  gost_verify() {
    sleep 2
    systemctl is-active --quiet "$SVC" || return 1
    local main_pid
    main_pid="$(systemctl show "$SVC" -p MainPID --value 2>/dev/null || echo 0)"
    [[ "$main_pid" =~ ^[0-9]+$ ]] && (( main_pid > 0 )) || return 1
    if ss -H -lntp 2>/dev/null | grep -q "pid=${main_pid}," ; then
      ss -H -lntp 2>/dev/null | grep "pid=${main_pid}," | awk '{print $4}' | grep -Eq ":${PORT}$" || return 1
    else
      ss -H -lnt | awk '{print $4}' | grep -Eq ":${PORT}$" || return 1
    fi
    ok "服务正在运行（PID=${main_pid}, User=${RUN_USER}）且 TCP 端口 ${PORT} 监听中"
  }

  gost_post_deploy_hints() {
    local scheme="$PROTO"
    [[ "$scheme" == "socks5" ]] && scheme="socks5h"
    local display_host="$BIND"
    [[ "$display_host" == "0.0.0.0" || "$display_host" == "::" ]] && display_host="<VPS_IP>"
    [[ "$display_host" == *:* && "$display_host" != \<* ]] && display_host="[${display_host}]"

    printf '\n'
    if [[ "$AUTH" == "1" ]]; then
      msg "客户端参考地址：${scheme}://${USERNAME}:******@${display_host}:${PORT}"
    else
      msg "客户端参考地址：${scheme}://${display_host}:${PORT}（无认证）"
    fi

    # 防火墙放行提醒
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
      if ! ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${PORT}(/tcp)?[[:space:]].*ALLOW"; then
        warn "检测到 UFW 防火墙已开启，如外部无法连接请放行：ufw allow ${PORT}/tcp"
      fi
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
      if ! firewall-cmd --list-ports 2>/dev/null | grep -qw "${PORT}/tcp"; then
        warn "检测到 firewalld 已开启，如外部无法连接请放行：firewall-cmd --permanent --add-port=${PORT}/tcp && firewall-cmd --reload"
      fi
    fi

    # 可选本机立即实测（使用 curl -K - 避免密码出现在进程命令行）
    if confirm_yn "是否通过本机立即测试该代理的出站连通性？" Y; then
      local test_host="$BIND"
      [[ "$test_host" == "0.0.0.0" ]] && test_host="127.0.0.1"
      [[ "$test_host" == "::" ]] && test_host="[::1]"
      [[ "$test_host" == *:* && "$test_host" != \[*\] ]] && test_host="[${test_host}]"
      local proxy_endpoint="${scheme}://${test_host}:${PORT}"
      local test_ip=""
      if [[ "$AUTH" == "1" ]]; then
        local enc_u enc_p
        enc_u="$(urlencode "$USERNAME")"
        enc_p="$(urlencode "$PASSWORD")"
        test_ip="$(printf 'proxy = "%s://%s:%s@%s:%s"\n' "$scheme" "$enc_u" "$enc_p" "$test_host" "$PORT" \
          | curl -fsS -K - --connect-timeout 6 --max-time 10 https://api4.ipify.org 2>/dev/null || true)"
      else
        test_ip="$(curl -fsS -x "$proxy_endpoint" --connect-timeout 6 --max-time 10 https://api4.ipify.org 2>/dev/null || true)"
      fi
      if [[ -n "$test_ip" ]]; then
        ok "代理实测成功，IPv4 出口：${test_ip}"
      else
        warn "代理实测未能获取出口 IP（请检查网络/认证或查看 journalctl -u ${SVC}）"
      fi
    fi
    PASSWORD=""
  }

  gost_deploy() {
    local existing="$1"
    gost_install_binary
    if [[ "$existing" == 0 ]]; then
      [[ ! -e "$UNIT" && ! -d "$DROP" && ! -e "$CONF" ]] || die "同名实例已经存在，请重新进入菜单选择升级/覆盖"
      if gost_port_in_use "$BIND" "$PORT"; then
        die "目标地址 ${BIND}:${PORT} 已被占用"
      fi
      if ! gost_write_config "$CONF" || ! gost_write_unit "$UNIT" || ! systemctl daemon-reload; then
        PASSWORD=""
        warn "新实例配置生成失败，清理本次文件"
        rm -f "$UNIT" "$CONF"
        systemctl daemon-reload || true
        return 1
      fi
      if ! systemctl enable --now "$SVC" || ! gost_verify; then
        PASSWORD=""
        journalctl -u "$SVC" -n 20 --no-pager || true
        warn "新部署失败，移除新生成的 unit 与配置"
        systemctl stop "$SVC" >/dev/null 2>&1 || true
        systemctl disable "$SVC" >/dev/null 2>&1 || true
        rm -f "$UNIT" "$CONF"
        systemctl daemon-reload
        return 1
      fi
      ok "新实例 ${SVC} 部署完成"
      gost_post_deploy_hints
      return 0
    fi

    local fragment
    fragment="$(systemctl show "$SVC" -p FragmentPath --value 2>/dev/null || true)"
    [[ "$fragment" == "$UNIT" ]] || die "旧服务单元路径非 ${UNIT}，拒绝覆盖：${fragment}"
    gost_backup
    msg "新认证参数来自本次交互输入；不会自动搬运旧密码。"
    confirm_yn "备份完毕，确认中断该实例现有连接并切换新版?" N || { PASSWORD=""; return 0; }
    systemctl stop "$SVC" || die "旧服务无法停止，未写入新版配置"
    rm -rf "$DROP"
    if ! gost_write_config "$CONF" || ! gost_write_unit "$UNIT" || ! systemctl daemon-reload; then
      PASSWORD=""
      warn "生成配置或重载 systemd 失败，开始回滚"
      gost_restore "$BK"
      return 1
    fi
    if systemctl enable --now "$SVC" && gost_verify; then
      ok "升级成功，回滚备份目录：${BK}"
      gost_post_deploy_hints
    else
      PASSWORD=""
      warn "新服务启动或监听检查失败，开始自动回滚"
      journalctl -u "$SVC" -n 25 --no-pager || true
      gost_restore "$BK"
      return 1
    fi
  }

  printf '\n%s========== GOST 实例管理器 ==========%s\n' "$C_BOLD" "$C_RESET"
  echo "1) 新建/升级/替换实例（交互向导，默认 v${VER}）"
  echo "2) 查看已有实例及状态"
  echo "3) 从备份目录恢复实例"
  echo "4) 停止并移除指定实例（先自动备份）"
  echo "0) 返回"
  local op choice target
  read_prompt op "请选择功能" "1" || die "终端输入中断"
  case "$op" in
    1)
      gost_config_wizard
      if [[ -e "$UNIT" || -d "$DROP" || -e "$CONF" ]]; then
        warn "发现已有 ${SVC}"
        gost_service_info
        printf '1) 备份并使用新输入配置升级/覆盖  2) 改为创建新实例  0) 取消\n'
        read_prompt choice "选择" "0" || die "终端输入中断"
        case "$choice" in
          1) gost_deploy 1 ;;
          2) PASSWORD=""; warn "请重新运行向导选择新端口/实例名；未做任何修改" ;;
          *) PASSWORD=""; msg "已取消" ;;
        esac
      else
        gost_deploy 0
      fi
      ;;
    2)
      systemctl list-units --all 'gost-*.service' --no-pager || true
      read_prompt SVC "要查看的实例名" "gost-50166" || die "终端输入中断"
      SVC="${SVC%.service}"
      gost_validate_name
      gost_paths
      gost_service_info
      journalctl -u "$SVC" -n 15 --no-pager || true
      ;;
    3)
      read_prompt SVC "要恢复的实例名" "gost-50166" || die "终端输入中断"
      SVC="${SVC%.service}"
      gost_validate_name
      gost_paths
      msg "可用备份："
      find "$BACKUP_DIR" -maxdepth 1 -type d -name "${SVC}-*" -print 2>/dev/null | sort || true
      read_prompt target "请输入完整备份目录绝对路径" "" || die "终端输入中断"
      [[ "$target" == "${BACKUP_DIR}/${SVC}-"* && -d "$target" && -f "${target}/was-active" && -f "${target}/was-enabled" ]] \
        || die "备份路径不合法"
      confirm_yn "确认停止现有实例，并从备份恢复?" N || die "已取消"
      gost_restore "$target"
      ok "恢复动作已执行，请检查服务状态和日志"
      ;;
    4)
      systemctl list-units --all 'gost-*.service' --no-pager || true
      read_prompt SVC "要停止并移除的实例名" "gost-50166" || die "终端输入中断"
      SVC="${SVC%.service}"
      gost_validate_name
      gost_paths
      [[ -e "$UNIT" || -d "$DROP" || -e "$CONF" ]] || die "未找到实例 ${SVC}"
      gost_service_info
      confirm_yn "确认备份后停止并删除实例 ${SVC}？" N || { msg "已取消"; return 0; }
      gost_backup
      systemctl stop "$SVC" >/dev/null 2>&1 || true
      systemctl disable "$SVC" >/dev/null 2>&1 || true
      rm -f "$UNIT" "$CONF"
      rm -rf "$DROP"
      systemctl daemon-reload
      ok "实例 ${SVC} 已移除（备份已保留在 ${BK}）"
      ;;
    0)
      msg "返回主菜单"
      ;;
    *)
      die "无效选择"
      ;;
  esac
}

# ==============================================================================
# 模块 7：LinuxMirrors 换源脚本
# ==============================================================================
mod_mirror() {
  require_root || return 1
  require_cmds curl || return 1
  printf '\n%s=== LinuxMirrors 一键换源 ===%s\n' "$C_BOLD" "$C_RESET"
  msg "即将拉取并运行：https://linuxmirrors.cn/main.sh"
  confirm_yn "确认继续？" Y || { msg "已取消"; return 0; }
  bash <(curl -fsSL --connect-timeout 15 https://linuxmirrors.cn/main.sh)
}

# ==============================================================================
# 模块 8：Cloudflare DDNS 安装与管理
# ==============================================================================
mod_ddns() {
  set -euo pipefail
  require_root || return 1

  local INSTALL_PATH="/usr/local/bin/cf-ddns.sh"
  local CONFIG_FILE="/etc/cf-ddns.conf"
  local SERVICE_FILE="/etc/systemd/system/cf-ddns.service"
  local TIMER_FILE="/etc/systemd/system/cf-ddns.timer"

  ddns_install_all() {
    echo "=========================================="
    echo "        Cloudflare DDNS 一键安装器"
    echo "=========================================="
    echo

    step "[1/5] 安装依赖 (curl, jq)..."
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y curl jq
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl jq
      elif command -v yum >/dev/null 2>&1; then
        yum install -y curl jq
      elif command -v apk >/dev/null 2>&1; then
        apk add curl jq
      else
        die "无法识别包管理器，请手动安装 curl jq"
      fi
    else
      ok "curl 与 jq 已安装"
    fi

    step "[2/5] 写入 DDNS 主程序 -> ${INSTALL_PATH}"
    cat > "$INSTALL_PATH" <<'SCRIPT'
#!/usr/bin/env bash
set -u

CONFIG_FILE="/etc/cf-ddns.conf"
STATE_DIR="/var/lib/cf-ddns"
STATE_FILE="${STATE_DIR}/last_state"
CF_API="https://api.cloudflare.com/client/v4"
FORCE_SYNC=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

TTY_FD=0
if [[ -r /dev/tty ]]; then
    exec 3</dev/tty
    TTY_FD=3
fi

shell_quote() {
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

# 通过 curl -K - 从 stdin 传递认证 Header，避免 Token 出现在 ps 命令行中
cf_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local escaped_token="${CF_TOKEN//\\/\\\\}"
    escaped_token="${escaped_token//\"/\\\"}"

    if [[ -n "$data" ]]; then
        printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$escaped_token" \
            | curl -fsS \
                --connect-timeout 10 \
                --max-time 20 \
                -K - \
                -X "$method" \
                "${CF_API}${endpoint}" \
                --data "$data"
    else
        printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$escaped_token" \
            | curl -fsS \
                --connect-timeout 10 \
                --max-time 20 \
                -K - \
                -X "$method" \
                "${CF_API}${endpoint}"
    fi
}

verify_token() {
    local response
    if ! response=$(cf_request GET "/user/tokens/verify"); then
        error "无法连接 Cloudflare API"
        return 1
    fi
    if [[ "$(echo "$response" | jq -r '.success')" != "true" ]]; then
        error "Cloudflare Token 验证失败"
        echo "$response" | jq
        return 1
    fi
    success "Cloudflare Token 验证成功"
}

get_zone_id() {
    local response
    if ! response=$(cf_request GET "/zones?name=${ZONE_NAME}"); then
        error "查询 Zone 失败"
        return 1
    fi
    if [[ "$(echo "$response" | jq -r '.success')" != "true" ]]; then
        error "Cloudflare API 查询 Zone 失败"
        echo "$response" | jq
        return 1
    fi
    ZONE_ID=$(echo "$response" | jq -r '.result[0].id // empty')
    if [[ -z "$ZONE_ID" ]]; then
        error "找不到 Zone：${ZONE_NAME}"
        return 1
    fi
    success "Zone ID：${ZONE_ID}"
}

select_zone() {
    info "正在从 Cloudflare 读取可用域名列表..."
    local response=""
    if response=$(cf_request GET "/zones?status=active&per_page=50" 2>/dev/null) \
        && [[ "$(echo "$response" | jq -r '.success // false')" == "true" ]]; then
        local count
        count=$(echo "$response" | jq -r '.result | length')
        if [[ "$count" == "0" ]]; then
            response=$(cf_request GET "/zones?per_page=50" 2>/dev/null || true)
        fi
    else
        response=""
    fi

    local zone_ids=() zone_names=() zid zname
    if [[ -n "$response" ]] && [[ "$(echo "$response" | jq -r '.success // false')" == "true" ]]; then
        while IFS=$'\t' read -r zid zname; do
            [[ -n "$zid" && -n "$zname" ]] || continue
            zone_ids+=("$zid")
            zone_names+=("$zname")
        done < <(echo "$response" | jq -r '.result[] | "\(.id)\t\(.name)"')
    fi

    if (( ${#zone_names[@]} > 0 )); then
        echo
        echo "检测到以下 Cloudflare 域名："
        local i
        for i in "${!zone_names[@]}"; do
            printf '  %d) %s\n' "$((i + 1))" "${zone_names[$i]}"
        done
        echo "  0) 手动输入根域名"

        local pick
        while true; do
            IFS= read -r -u "$TTY_FD" -p "请选择根域名 [1]: " pick || exit 1
            pick="${pick:-1}"
            if [[ "$pick" == "0" ]]; then
                break
            elif [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#zone_names[@]} )); then
                ZONE_ID="${zone_ids[$((pick - 1))]}"
                ZONE_NAME="${zone_names[$((pick - 1))]}"
                success "已选择域名：${ZONE_NAME}（Zone ID：${ZONE_ID}）"
                return 0
            else
                warn "请输入 0 到 ${#zone_names[@]} 之间的数字"
            fi
        done
    else
        warn "未能自动获取域名列表（可能是 Token 权限限制或账号下暂无 Zone），切换为手动输入。"
    fi

    echo
    IFS= read -r -u "$TTY_FD" -p "请输入根域名，例如 leoknox.de: " ZONE_NAME || exit 1
    while [[ -z "$ZONE_NAME" ]]; do
        IFS= read -r -u "$TTY_FD" -p "不能为空，请重新输入: " ZONE_NAME || exit 1
    done
    get_zone_id
}

default_host_prefix() {
    local h
    h="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
    h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
    if [[ -z "$h" || "$h" == "localhost" ]]; then
        printf ''
    else
        printf '%s' "$h"
    fi
}

resolve_record_name() {
    local input="$1" zone="$2"
    input="$(printf '%s' "$input" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    input="${input%.}"
    zone="$(printf '%s' "$zone" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    zone="${zone%.}"

    if [[ -z "$input" ]]; then
        return 1
    elif [[ "$input" == "@" || "$input" == "$zone" ]]; then
        printf '%s' "$zone"
    elif [[ "$input" == *".${zone}" ]]; then
        printf '%s' "$input"
    else
        printf '%s.%s' "$input" "$zone"
    fi
}

get_ipv4() {
    local ip
    ip="$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://api4.ipify.org 2>/dev/null \
        || curl -4 -fsS --connect-timeout 5 --max-time 10 https://ip.sb 2>/dev/null \
        || true)"
    printf '%s' "$ip" | tr -d '[:space:]'
}

get_ipv6() {
    local ip
    ip="$(curl -6 -fsS --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null \
        || curl -6 -fsS --connect-timeout 5 --max-time 10 https://ip.sb 2>/dev/null \
        || true)"
    printf '%s' "$ip" | tr -d '[:space:]'
}

valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.' o1 o2 o3 o4
    read -r o1 o2 o3 o4 <<< "$ip"
    (( 10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255 ))
}

valid_ipv6() {
    local ip="$1"
    [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]
}

load_state() {
    LAST_RECORD=""
    LAST_PROXIED=""
    LAST_IPV4=""
    LAST_IPV6=""
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    fi
}

save_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    {
        printf 'LAST_RECORD=%s\n'  "$(shell_quote "$RECORD_NAME")"
        printf 'LAST_PROXIED=%s\n' "$(shell_quote "$PROXIED")"
        printf 'LAST_IPV4=%s\n'    "$(shell_quote "${NEW_LAST_IPV4:-}")"
        printf 'LAST_IPV6=%s\n'    "$(shell_quote "${NEW_LAST_IPV6:-}")"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

update_record() {
    local type="$1"
    local ip="$2"

    info "检查 ${type}：${RECORD_NAME}"

    local response
    if ! response=$(cf_request GET "/zones/${ZONE_ID}/dns_records?type=${type}&name=${RECORD_NAME}"); then
        error "查询 ${type} 记录失败"
        return 1
    fi

    if [[ "$(echo "$response" | jq -r '.success')" != "true" ]]; then
        error "Cloudflare 返回错误"
        echo "$response" | jq
        return 1
    fi

    local record_id old_ip old_proxied
    record_id=$(echo "$response" | jq -r '.result[0].id // empty')
    old_ip=$(echo "$response" | jq -r '.result[0].content // empty')
    old_proxied=$(echo "$response" | jq -r '.result[0].proxied // empty')

    local payload
    payload=$(jq -n \
        --arg type "$type" \
        --arg name "$RECORD_NAME" \
        --arg content "$ip" \
        --argjson proxied "$PROXIED" \
        '{
            type: $type,
            name: $name,
            content: $content,
            ttl: 1,
            proxied: $proxied
        }')

    if [[ -z "$record_id" ]]; then
        warn "${type} 记录不存在，正在创建"
        local create_response
        if ! create_response=$(cf_request POST "/zones/${ZONE_ID}/dns_records" "$payload"); then
            error "${type} 创建失败"
            return 1
        fi
        if [[ "$(echo "$create_response" | jq -r '.success')" == "true" ]]; then
            success "${type} 创建成功：${RECORD_NAME} -> ${ip} (proxied=${PROXIED})"
        else
            error "${type} 创建失败"
            echo "$create_response" | jq
            return 1
        fi
        return 0
    fi

    if [[ "$old_ip" == "$ip" && "$old_proxied" == "$PROXIED" ]]; then
        success "${type} 远端无变化：${ip} (proxied=${PROXIED})"
        return 0
    fi

    info "${type} 发生变化：${old_ip} (proxied=${old_proxied}) -> ${ip} (proxied=${PROXIED})"

    local update_response
    if ! update_response=$(cf_request PUT "/zones/${ZONE_ID}/dns_records/${record_id}" "$payload"); then
        error "${type} 更新失败"
        return 1
    fi

    if [[ "$(echo "$update_response" | jq -r '.success')" == "true" ]]; then
        success "${type} 更新成功：${RECORD_NAME} -> ${ip} (proxied=${PROXIED})"
    else
        error "${type} 更新失败"
        echo "$update_response" | jq
        return 1
    fi
}

setup_config() {
    echo
    echo "=========================================="
    echo "        Cloudflare DDNS 配置向导"
    echo "=========================================="
    echo
    echo "Cloudflare API Token 建议权限："
    echo "  Zone -> DNS -> Edit"
    echo "  Zone -> Zone -> Read"
    echo
    echo "Zone Resources 建议只授权你要用的域名。"
    echo

    while true; do
        IFS= read -r -s -u "$TTY_FD" -p "请输入 Cloudflare API Token: " CF_TOKEN || exit 1
        echo
        [[ -n "$CF_TOKEN" ]] || { warn "Token 不能为空"; continue; }
        if verify_token; then
            break
        fi
    done

    select_zone || exit 1

    echo
    local host_prefix default_record="" raw_record
    host_prefix="$(default_host_prefix)"
    [[ -n "$host_prefix" ]] && default_record="${host_prefix}.${ZONE_NAME}"
    echo "子域名可直接输入前缀（如 hkbn -> hkbn.${ZONE_NAME}），输入 @ 使用根域名。"
    while true; do
        if [[ -n "$host_prefix" ]]; then
            IFS= read -r -u "$TTY_FD" -p "请输入 DDNS 子域名前缀或完整域名 [默认: ${default_record}]: " raw_record || exit 1
            raw_record="${raw_record:-$default_record}"
        else
            IFS= read -r -u "$TTY_FD" -p "请输入 DDNS 子域名前缀或完整域名: " raw_record || exit 1
        fi
        if RECORD_NAME="$(resolve_record_name "$raw_record" "$ZONE_NAME")" && [[ -n "$RECORD_NAME" ]]; then
            break
        fi
        warn "域名不能为空，请重新输入"
    done
    info "目标 DDNS 域名：${RECORD_NAME}"

    echo
    echo "请选择记录类型："
    echo "  1) IPv4 / A"
    echo "  2) IPv6 / AAAA"
    echo "  3) IPv4 + IPv6"

    local choice
    while true; do
        IFS= read -r -u "$TTY_FD" -p "请选择 [1-3]: " choice || exit 1
        case "$choice" in
            1) ENABLE_IPV4=true;  ENABLE_IPV6=false; break ;;
            2) ENABLE_IPV4=false; ENABLE_IPV6=true;  break ;;
            3) ENABLE_IPV4=true;  ENABLE_IPV6=true;  break ;;
            *) warn "请输入 1、2 或 3" ;;
        esac
    done

    echo
    echo "Cloudflare 橙云代理："
    echo "SSH / VPS / 面板 / 非 HTTP 服务建议选择 N"
    echo

    local proxy
    IFS= read -r -u "$TTY_FD" -p "是否启用 Cloudflare Proxy？[y/N]: " proxy || exit 1
    proxy=${proxy:-N}
    if [[ "$proxy" =~ ^[Yy]$ ]]; then
        PROXIED=true
    else
        PROXIED=false
    fi

    {
        printf 'CF_TOKEN=%s\n'    "$(shell_quote "$CF_TOKEN")"
        printf 'ZONE_NAME=%s\n'   "$(shell_quote "$ZONE_NAME")"
        printf 'ZONE_ID=%s\n'     "$(shell_quote "$ZONE_ID")"
        printf 'RECORD_NAME=%s\n' "$(shell_quote "$RECORD_NAME")"
        printf 'ENABLE_IPV4=%s\n' "${ENABLE_IPV4}"
        printf 'ENABLE_IPV6=%s\n' "${ENABLE_IPV6}"
        printf 'PROXIED=%s\n'     "${PROXIED}"
    } > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"
    rm -f "$STATE_FILE"
    success "配置已保存：${CONFIG_FILE}"
}

run_ddns() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        setup_config
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    load_state

    local NEW_LAST_IPV4="$LAST_IPV4"
    local NEW_LAST_IPV6="$LAST_IPV6"
    local state_dirty=0
    local had_err=0

    echo
    info "开始 DDNS 检查：${RECORD_NAME}"

    if [[ "$ENABLE_IPV4" == "true" ]]; then
        IPV4=$(get_ipv4)
        if [[ -n "$IPV4" ]] && valid_ipv4 "$IPV4"; then
            info "公网 IPv4：${IPV4}"
            if (( FORCE_SYNC == 0 )) && [[ "$LAST_RECORD" == "$RECORD_NAME" && "$LAST_PROXIED" == "$PROXIED" && "$LAST_IPV4" == "$IPV4" ]]; then
                success "A 记录本地缓存一致（${IPV4}），跳过 Cloudflare API 请求"
            else
                if update_record "A" "$IPV4"; then
                    NEW_LAST_IPV4="$IPV4"
                    state_dirty=1
                else
                    had_err=1
                fi
            fi
        else
            warn "未检测到有效公网 IPv4"
        fi
    fi

    if [[ "$ENABLE_IPV6" == "true" ]]; then
        IPV6=$(get_ipv6)
        if [[ -n "$IPV6" ]] && valid_ipv6 "$IPV6"; then
            info "公网 IPv6：${IPV6}"
            if (( FORCE_SYNC == 0 )) && [[ "$LAST_RECORD" == "$RECORD_NAME" && "$LAST_PROXIED" == "$PROXIED" && "$LAST_IPV6" == "$IPV6" ]]; then
                success "AAAA 记录本地缓存一致（${IPV6}），跳过 Cloudflare API 请求"
            else
                if update_record "AAAA" "$IPV6"; then
                    NEW_LAST_IPV6="$IPV6"
                    state_dirty=1
                else
                    had_err=1
                fi
            fi
        else
            warn "未检测到有效公网 IPv6"
        fi
    fi

    if (( state_dirty == 1 )); then
        save_state
    fi

    if (( had_err == 0 )); then
        success "DDNS 检查完成"
    else
        error "DDNS 检查存在失败项"
        return 1
    fi
}

if [[ "${CF_DDNS_SOURCE_ONLY:-0}" != "1" ]]; then
    case "${1:-}" in
        --reset)
            rm -f "$CONFIG_FILE" "$STATE_FILE"
            FORCE_SYNC=1
            setup_config
            run_ddns
            ;;
        --configure)
            rm -f "$CONFIG_FILE" "$STATE_FILE"
            setup_config
            ;;
        --force)
            FORCE_SYNC=1
            run_ddns
            ;;
        *)
            run_ddns
            ;;
    esac
fi
SCRIPT

    chmod 755 "$INSTALL_PATH"

    step "[3/5] 写入 systemd service..."
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Cloudflare DDNS Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=60
ExecStart=${INSTALL_PATH}
EOF_SERVICE

    step "[4/5] 写入 systemd timer..."
    cat > "$TIMER_FILE" <<'EOF_TIMER'
[Unit]
Description=Run Cloudflare DDNS every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=15s
Persistent=true
Unit=cf-ddns.service

[Install]
WantedBy=timers.target
EOF_TIMER

    step "[5/5] 启用 systemd timer..."
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
      systemctl daemon-reload
      systemctl enable --now cf-ddns.timer
    else
      warn "未检测到 systemd，跳过 timer 启用（可通过 cron 定时执行 ${INSTALL_PATH}）。"
    fi

    echo
    echo "=========================================="
    echo "现在开始首次配置"
    echo "=========================================="
    "$INSTALL_PATH" --force

    echo
    ok "Cloudflare DDNS 安装完成！"
    echo "常用命令：cf-ddns.sh | cf-ddns.sh --force | cf-ddns.sh --reset | systemctl status cf-ddns.timer | journalctl -u cf-ddns.service"
  }

  printf '\n%s=== Cloudflare DDNS 管理 ===%s\n' "$C_BOLD" "$C_RESET"
  if [[ -x "$INSTALL_PATH" ]]; then
    echo "检测到已安装：${INSTALL_PATH}"
    echo "1) 立即执行一次 DDNS 强制同步（--force）"
    echo "2) 重新配置（--reset）"
    echo "3) 查看定时器状态与最近日志"
    echo "4) 重新安装/升级主程序与 systemd timer"
    echo "0) 返回"
    local op
    read_prompt op "请选择操作" "1" || return 1
    case "$op" in
      1) "$INSTALL_PATH" --force ;;
      2) "$INSTALL_PATH" --reset ;;
      3)
        systemctl --no-pager status cf-ddns.timer || true
        printf '\n'
        journalctl -u cf-ddns.service -n 20 --no-pager || true
        ;;
      4) ddns_install_all ;;
      0) msg "返回主菜单" ;;
      *) err "无效选择"; return 1 ;;
    esac
  else
    ddns_install_all
  fi
}

# ==============================================================================
# 模块 9：终端代理引导式配置（v3.1：凭据 600 独立落盘 + 动态状态 + 准确出口测试）
# ==============================================================================
mod_proxy() {
  printf '\n%s==============================================%s\n' "$C_BOLD" "$C_RESET"
  printf '%s          终端代理一键配置工具 v3.1%s\n' "$C_BOLD" "$C_RESET"
  printf '%s==============================================%s\n\n' "$C_BOLD" "$C_RESET"

  if ! command -v curl >/dev/null 2>&1; then
    warn "未检测到 curl。代理配置仍可继续，但测试功能不可用。"
  fi

  # 若在 sudo 下运行，支持优先写入原普通用户 HOME，避免误写 /root
  local TARGET_USER="" TARGET_HOME="${HOME}" TARGET_SHELL="${SHELL:-}"
  if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local sudo_home="" sudo_shell=""
    if command -v getent >/dev/null 2>&1; then
      sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
      sudo_shell="$(getent passwd "$SUDO_USER" | cut -d: -f7)"
    else
      sudo_home="$(eval echo "~${SUDO_USER}" 2>/dev/null || true)"
    fi
    if [[ -n "$sudo_home" && -d "$sudo_home" ]]; then
      echo "检测到当前通过 sudo 运行（原用户：${SUDO_USER}）："
      echo "1) 配置原用户 ${SUDO_USER} (${sudo_home})"
      echo "2) 配置 root (${HOME})"
      local user_choice
      read_prompt user_choice "请选择写入目标用户" "1" || return 1
      if [[ "$user_choice" == "1" ]]; then
        TARGET_USER="$SUDO_USER"
        TARGET_HOME="$sudo_home"
        [[ -n "$sudo_shell" ]] && TARGET_SHELL="$sudo_shell"
      fi
    fi
  fi

  local CURRENT_SHELL RC_FILE
  case "$TARGET_SHELL" in
    */zsh)  CURRENT_SHELL="zsh";  RC_FILE="${TARGET_HOME}/.zshrc" ;;
    */bash) CURRENT_SHELL="bash"; RC_FILE="${TARGET_HOME}/.bashrc" ;;
    *)
      if [[ -n "${ZSH_VERSION:-}" ]]; then
        CURRENT_SHELL="zsh"; RC_FILE="${TARGET_HOME}/.zshrc"
      elif [[ -n "${BASH_VERSION:-}" ]]; then
        CURRENT_SHELL="bash"; RC_FILE="${TARGET_HOME}/.bashrc"
      else
        CURRENT_SHELL="unknown"; RC_FILE="${TARGET_HOME}/.profile"
      fi
      ;;
  esac

  local ENV_DIR="${TARGET_HOME}/.config/terminal-proxy"
  local ENV_FILE="${ENV_DIR}/env"
  local START_MARKER="# >>> TERMINAL_PROXY_V3_MANAGED >>>"
  local END_MARKER="# <<< TERMINAL_PROXY_V3_MANAGED <<<"

  fix_owner() {
    if [[ -n "$TARGET_USER" ]]; then
      chown -R "${TARGET_USER}:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$@" 2>/dev/null || true
    fi
  }

  remove_old_block() {
    if [[ ! -f "$RC_FILE" ]]; then
      touch "$RC_FILE"
      fix_owner "$RC_FILE"
      return
    fi
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v start="$START_MARKER" -v end="$END_MARKER" '
      $0 == start { skip = 1; next }
      $0 == end   { skip = 0; next }
      !skip       { print }
    ' "$RC_FILE" > "$tmp_file"
    cat "$tmp_file" > "$RC_FILE"
    rm -f "$tmp_file"
    fix_owner "$RC_FILE"
  }

  write_proxy_env_file() {
    local q_url="$1" q_no_proxy="$2"
    mkdir -p "$ENV_DIR"
    chmod 700 "$ENV_DIR"
    cat > "$ENV_FILE" <<ENVEOF
# Terminal Proxy v3.1 credentials (mode 600, auto-generated by ops.sh)
TERMINAL_PROXY_URL=${q_url}
TERMINAL_NO_PROXY=${q_no_proxy}
ENVEOF
    chmod 600 "$ENV_FILE"
    fix_owner "$ENV_DIR"
  }

  echo "检测到 Shell: ${CURRENT_SHELL}，配置文件: ${RC_FILE}"
  echo "凭据独立文件: ${ENV_FILE}（权限 600）"
  echo "1) 配置/更新终端代理"
  echo "2) 清理 ${RC_FILE} 中的代理配置块与凭据文件"
  echo "0) 返回"
  local entry_op
  read_prompt entry_op "请选择" "1" || return 1
  if [[ "$entry_op" == "0" ]]; then
    msg "返回主菜单"
    return 0
  elif [[ "$entry_op" == "2" ]]; then
    remove_old_block
    rm -f "$ENV_FILE"
    ok "已从 ${RC_FILE} 移除终端代理配置块并删除 ${ENV_FILE}，请执行 source \"${RC_FILE}\" 或重开终端。"
    return 0
  elif [[ "$entry_op" != "1" ]]; then
    err "无效选择"
    return 1
  fi

  local PROXY_HOST RAW_PROXY_HOST PROXY_HOST_TYPE PROXY_HOST_URL
  read_prompt PROXY_HOST "请输入代理服务器 IP / IPv6 / 域名" "192.168.31.134" || return 1
  [[ -n "$PROXY_HOST" ]] || { err "代理服务器地址不能为空。"; return 1; }

  RAW_PROXY_HOST="$PROXY_HOST"
  if [[ "$RAW_PROXY_HOST" == \[*\] ]]; then
    RAW_PROXY_HOST="${RAW_PROXY_HOST#[}"
    RAW_PROXY_HOST="${RAW_PROXY_HOST%]}"
  fi

  if [[ "$RAW_PROXY_HOST" == *:* ]]; then
    PROXY_HOST_TYPE="IPv6"
    PROXY_HOST_URL="[${RAW_PROXY_HOST}]"
  elif is_valid_ipv4 "$RAW_PROXY_HOST"; then
    PROXY_HOST_TYPE="IPv4"
    PROXY_HOST_URL="$RAW_PROXY_HOST"
  else
    PROXY_HOST_TYPE="域名"
    PROXY_HOST_URL="$RAW_PROXY_HOST"
  fi

  local PROXY_PORT
  printf '\n'
  read_prompt PROXY_PORT "请输入代理端口" "10808" || return 1
  if [[ ! "$PROXY_PORT" =~ ^[0-9]+$ ]] || (( 10#$PROXY_PORT < 1 || 10#$PROXY_PORT > 65535 )); then
    err "端口必须是 1-65535 之间的数字。"
    return 1
  fi
  PROXY_PORT=$((10#$PROXY_PORT))

  printf '\n请选择代理协议：\n'
  echo "1) SOCKS5h   推荐，域名由代理端解析"
  echo "2) SOCKS5    域名通常由本机解析"
  echo "3) HTTP"
  local PROTOCOL_CHOICE PROTOCOL
  read_prompt PROTOCOL_CHOICE "选择 [1/2/3]" "1" || return 1
  case "$PROTOCOL_CHOICE" in
    1) PROTOCOL="socks5h" ;;
    2) PROTOCOL="socks5" ;;
    3) PROTOCOL="http" ;;
    *) err "无效的协议选择。"; return 1 ;;
  esac

  local AUTH_PART="" DISPLAY_PROXY_URL="" PROXY_USER="" PROXY_PASS=""
  printf '\n'
  if confirm_yn "代理是否需要用户名/密码认证？" N; then
    read_prompt PROXY_USER "请输入代理用户名" "" || return 1
    [[ -n "$PROXY_USER" ]] || { err "代理用户名不能为空。"; return 1; }
    read_secret PROXY_PASS "请输入代理密码" || return 1
    [[ -n "$PROXY_PASS" ]] || { err "代理密码不能为空。"; return 1; }

    local ENCODED_USER ENCODED_PASS
    ENCODED_USER="$(urlencode "$PROXY_USER")"
    ENCODED_PASS="$(urlencode "$PROXY_PASS")"
    AUTH_PART="${ENCODED_USER}:${ENCODED_PASS}@"
    DISPLAY_PROXY_URL="${PROTOCOL}://${PROXY_USER}:******@${PROXY_HOST_URL}:${PROXY_PORT}"
  else
    DISPLAY_PROXY_URL="${PROTOCOL}://${PROXY_HOST_URL}:${PROXY_PORT}"
  fi

  local PROXY_URL="${PROTOCOL}://${AUTH_PART}${PROXY_HOST_URL}:${PROXY_PORT}"

  local DEFAULT_NO_PROXY="localhost,127.0.0.1,::1" NO_PROXY_VALUE
  printf '\n'
  read_prompt NO_PROXY_VALUE "NO_PROXY" "$DEFAULT_NO_PROXY" || return 1

  printf '\n==============================================\n'
  echo "                 配置预览"
  printf '==============================================\n\n'
  echo "主机类型  : ${PROXY_HOST_TYPE}"
  echo "代理主机  : ${PROXY_HOST_URL}"
  echo "代理端口  : ${PROXY_PORT}"
  echo "代理协议  : ${PROTOCOL}"
  echo "代理 URL  : ${DISPLAY_PROXY_URL}"
  echo "NO_PROXY  : ${NO_PROXY_VALUE}"
  echo "当前 Shell: ${CURRENT_SHELL}"
  echo "配置文件  : ${RC_FILE}"
  echo "凭据文件  : ${ENV_FILE} (600)"

  apply_proxy_local() {
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
    export no_proxy="$NO_PROXY_VALUE" NO_PROXY="$NO_PROXY_VALUE"
  }

  local Q_PROXY_URL Q_NO_PROXY Q_ENV_FILE
  Q_PROXY_URL="$(shell_quote_single "$PROXY_URL")"
  Q_NO_PROXY="$(shell_quote_single "$NO_PROXY_VALUE")"
  Q_ENV_FILE="$(shell_quote_single "$ENV_FILE")"

  printf '\n请选择配置方式：\n'
  echo "1) 仅输出当前终端临时生效命令（不改配置文件）"
  echo "2) 写入配置文件，永久开启代理（密码存于 600 独立文件）"
  echo "3) 添加快捷命令 proxy_on / proxy_off / proxy_status / proxy_test（密码存于 600 独立文件）"
  local MODE_CHOICE
  read_prompt MODE_CHOICE "选择 [1/2/3]" "3" || return 1

  case "$MODE_CHOICE" in
    1)
      apply_proxy_local
      printf '\n'
      ok "已在本脚本环境临时应用代理（可用于下方立即测试）。"
      warn "因脚本运行在子进程中，若要在当前终端生效，请复制执行："
      printf '\n'
      printf 'export http_proxy=%s https_proxy=%s all_proxy=%s HTTP_PROXY=%s HTTPS_PROXY=%s ALL_PROXY=%s no_proxy=%s NO_PROXY=%s\n' \
        "$Q_PROXY_URL" "$Q_PROXY_URL" "$Q_PROXY_URL" "$Q_PROXY_URL" "$Q_PROXY_URL" "$Q_PROXY_URL" "$Q_NO_PROXY" "$Q_NO_PROXY"
      ;;

    2)
      write_proxy_env_file "$Q_PROXY_URL" "$Q_NO_PROXY"
      remove_old_block
      cat >> "$RC_FILE" <<BLOCK

${START_MARKER}
# Terminal Proxy v3.1 (auto-generated by ops.sh)
if [ -r ${Q_ENV_FILE} ]; then
    . ${Q_ENV_FILE}
    export http_proxy="\$TERMINAL_PROXY_URL" https_proxy="\$TERMINAL_PROXY_URL" all_proxy="\$TERMINAL_PROXY_URL"
    export HTTP_PROXY="\$TERMINAL_PROXY_URL" HTTPS_PROXY="\$TERMINAL_PROXY_URL" ALL_PROXY="\$TERMINAL_PROXY_URL"
    export no_proxy="\$TERMINAL_NO_PROXY" NO_PROXY="\$TERMINAL_NO_PROXY"
    unset TERMINAL_PROXY_URL TERMINAL_NO_PROXY
fi
${END_MARKER}
BLOCK
      fix_owner "$RC_FILE"
      apply_proxy_local
      printf '\n'
      ok "代理凭据已写入：${ENV_FILE} (600)"
      ok "自动加载块已写入：${RC_FILE}"
      echo "请运行：source \"${RC_FILE}\" 或重新打开终端。"
      ;;

    3)
      write_proxy_env_file "$Q_PROXY_URL" "$Q_NO_PROXY"
      remove_old_block
      cat >> "$RC_FILE" <<BLOCK

${START_MARKER}
# Terminal Proxy v3.1 (auto-generated by ops.sh)
_proxy_mask_url() {
    printf '%s' "\$1" | sed -E 's#^([a-zA-Z0-9+.-]+://)([^/@:]+):([^/@]*)@#\\1\\2:******@#'
}

proxy_on() {
    if [ ! -r ${Q_ENV_FILE} ]; then
        echo "[✗] 未找到代理凭据文件：${ENV_FILE}" >&2
        return 1
    fi
    . ${Q_ENV_FILE}
    export http_proxy="\$TERMINAL_PROXY_URL" https_proxy="\$TERMINAL_PROXY_URL" all_proxy="\$TERMINAL_PROXY_URL"
    export HTTP_PROXY="\$TERMINAL_PROXY_URL" HTTPS_PROXY="\$TERMINAL_PROXY_URL" ALL_PROXY="\$TERMINAL_PROXY_URL"
    export no_proxy="\$TERMINAL_NO_PROXY" NO_PROXY="\$TERMINAL_NO_PROXY"
    local masked
    masked="\$(_proxy_mask_url "\$TERMINAL_PROXY_URL")"
    unset TERMINAL_PROXY_URL TERMINAL_NO_PROXY
    echo "========================================"
    echo "终端代理已开启"
    printf '代理: %s\n' "\$masked"
    echo "========================================"
}

proxy_off() {
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
    echo "终端代理已关闭"
}

proxy_status() {
    echo
    echo "========================================"
    echo "              代理状态"
    echo "========================================"
    local active_url="\${ALL_PROXY:-\${all_proxy:-\${HTTPS_PROXY:-\${https_proxy:-\${HTTP_PROXY:-\${http_proxy:-}}}}}}"
    if [ -n "\$active_url" ]; then
        echo "状态       : ON"
        printf '当前代理   : %s\n' "\$(_proxy_mask_url "\$active_url")"
        echo
        echo "http_proxy : \${http_proxy:+已设置}"
        echo "https_proxy: \${https_proxy:+已设置}"
        echo "all_proxy  : \${all_proxy:+已设置}"
        echo "HTTP_PROXY : \${HTTP_PROXY:+已设置}"
        echo "HTTPS_PROXY: \${HTTPS_PROXY:+已设置}"
        echo "ALL_PROXY  : \${ALL_PROXY:+已设置}"
        echo
        echo "NO_PROXY   : \${NO_PROXY:-\${no_proxy:-未设置}}"
    else
        echo "状态       : OFF"
    fi
    echo "========================================"
}

proxy_test() {
    echo
    echo "========================================"
    echo "              代理测试"
    echo "========================================"
    echo
    if ! command -v curl >/dev/null 2>&1; then
        echo "[失败] 系统没有安装 curl"
        return 1
    fi
    local HTTP_CODE EXIT_IP IPV4_IP IPV6_IP
    echo "[1] 测试 HTTPS 连通性..."
    HTTP_CODE=\$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 https://www.google.com 2>/dev/null || true)
    if [[ "\$HTTP_CODE" =~ ^(200|204|301|302|307|308)$ ]]; then
        echo "[成功] Google 可访问，HTTP \$HTTP_CODE"
    else
        echo "[失败] Google 测试失败，HTTP \${HTTP_CODE:-无响应}"
    fi
    echo
    echo "[2] 查询默认出口 IP..."
    EXIT_IP=\$(curl -fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true)
    echo "出口 IP: \${EXIT_IP:-无法获取}"
    echo
    echo "[3] 测试代理 IPv4 出口（纯 A 域名，不限制本机连代理协议族）..."
    IPV4_IP=\$(curl -fsS --connect-timeout 5 --max-time 10 https://api4.ipify.org 2>/dev/null || true)
    echo "IPv4 出口: \${IPV4_IP:-不可用}"
    echo
    echo "[4] 测试代理 IPv6 出口（纯 AAAA 域名，不限制本机连代理协议族）..."
    IPV6_IP=\$(curl -fsS --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null || true)
    echo "IPv6 出口: \${IPV6_IP:-不可用}"
    echo
    echo "========================================"
}
${END_MARKER}
BLOCK
      fix_owner "$RC_FILE"
      apply_proxy_local
      printf '\n'
      ok "代理凭据已写入：${ENV_FILE} (600)"
      ok "快捷代理命令已写入：${RC_FILE}"
      echo "先执行：source \"${RC_FILE}\""
      echo "之后可使用：proxy_on | proxy_off | proxy_status | proxy_test"
      ;;

    *)
      err "无效选择。"
      return 1
      ;;
  esac

  printf '\n----------------------------------------------\n'
  if confirm_yn "是否立即测试代理？" Y; then
    if ! command -v curl >/dev/null 2>&1; then
      err "系统没有 curl，无法执行测试。"
    else
      local http_code exit_ip ipv4_ip ipv6_ip
      printf '\n'
      msg "测试 HTTPS 连通性..."
      http_code="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 https://www.google.com 2>/dev/null || true)"
      if [[ "$http_code" =~ ^(200|204|301|302|307|308)$ ]]; then
        ok "Google 连通成功，HTTP ${http_code}"
      else
        err "Google 连接失败，HTTP ${http_code:-无响应}"
      fi

      printf '\n'
      msg "查询默认出口 IP..."
      exit_ip="$(curl -fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
      [[ -n "$exit_ip" ]] && ok "默认出口 IP: ${exit_ip}" || err "无法获取默认出口 IP"

      # 不传 -4 / -6，避免把“本机连代理那一跳”锁死，改用纯 A / 纯 AAAA 端点测代理真实出口
      printf '\n'
      msg "测试代理 IPv4 出口..."
      ipv4_ip="$(curl -fsS --connect-timeout 5 --max-time 10 https://api4.ipify.org 2>/dev/null || true)"
      [[ -n "$ipv4_ip" ]] && ok "IPv4 出口: ${ipv4_ip}" || warn "IPv4 出口不可用"

      printf '\n'
      msg "测试代理 IPv6 出口..."
      ipv6_ip="$(curl -fsS --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null || true)"
      [[ -n "$ipv6_ip" ]] && ok "IPv6 出口: ${ipv6_ip}" || warn "IPv6 出口不可用"
    fi
  fi
}

# ==============================================================================
# 模块 10：安装 Docker
# ==============================================================================
mod_docker() {
  set -e
  require_root || return 1
  require_cmds curl || return 1
  printf '\n%s=== 安装 Docker ===%s\n' "$C_BOLD" "$C_RESET"

  if command -v docker >/dev/null 2>&1; then
    ok "已检测到 Docker: $(docker --version 2>/dev/null || true)"
    if confirm_yn "是否仍要重新运行官方安装脚本？" N; then
      curl -fsSL --connect-timeout 15 https://get.docker.com | sh
    fi
  else
    confirm_yn "确认通过官方脚本 https://get.docker.com 安装 Docker？" Y || { msg "已取消"; return 0; }
    curl -fsSL --connect-timeout 15 https://get.docker.com | sh
  fi

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl enable --now docker || warn "启用 docker 服务失败，请手动检查"
  fi

  ok "Docker 状态：$(docker --version 2>/dev/null || echo '未找到 docker 命令')"
  docker compose version 2>/dev/null || true

  if confirm_yn "是否配置 Docker 全局日志轮转（max-size=50m, max-file=3，防止日志撑爆磁盘）？" Y; then
    configure_docker_log_rotation "50m" "3" || true
  fi
}

# ==============================================================================
# 模块 11：NodeQuality 测试
# ==============================================================================
mod_nodequality() {
  require_cmds curl || return 1
  printf '\n%s=== NodeQuality 综合网络与质量测试 ===%s\n' "$C_BOLD" "$C_RESET"
  msg "即将运行：https://run.NodeQuality.com"
  confirm_yn "确认开始测试？" Y || { msg "已取消"; return 0; }
  bash <(curl -fsSL --connect-timeout 15 https://run.NodeQuality.com)
}

# ==============================================================================
# 模块 12：系统信息与状态速查（只读）
# ==============================================================================
mod_status() {
  printf '\n%s=== 系统信息与状态速查 ===%s\n' "$C_BOLD" "$C_RESET"
  local os_name virt cc qdisc
  os_name="$(detect_os_name)"
  virt="$(systemd-detect-virt 2>/dev/null || echo 'unknown')"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'N/A')"

  printf '主机名    : %s\n' "$(hostname)"
  printf '系统      : %s\n' "$os_name"
  printf '内核/架构 : %s (%s)\n' "$(uname -r)" "$(uname -m)"
  printf '虚拟化    : %s\n' "$virt"
  printf '运行时间  : %s\n' "$(uptime -p 2>/dev/null || uptime)"
  printf 'TCP BBR   : cc=%s | qdisc=%s\n' "$cc" "$qdisc"
  printf 'Docker    : %s\n' "$(docker --version 2>/dev/null || echo '未安装')"

  printf '\n%s[内存与 Swap]%s\n' "$C_CYAN" "$C_RESET"
  if command -v free >/dev/null 2>&1; then
    free -h
  else
    echo "（当前系统无 free 命令）"
  fi

  printf '\n%s[磁盘使用 (根分区)]%s\n' "$C_CYAN" "$C_RESET"
  df -h /

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    printf '\n%s[相关 systemd 服务]%s\n' "$C_CYAN" "$C_RESET"
    systemctl list-units --all 'gost-*.service' 'cf-ddns.timer' 'docker.service' --no-pager 2>/dev/null || true
  fi

  if command -v curl >/dev/null 2>&1; then
    printf '\n'
    if confirm_yn "是否查询公网 IPv4 / IPv6？" N; then
      local v4 v6
      v4="$(curl -4 -fsS --connect-timeout 5 --max-time 6 https://api4.ipify.org 2>/dev/null || true)"
      v6="$(curl -6 -fsS --connect-timeout 5 --max-time 6 https://api6.ipify.org 2>/dev/null || true)"
      echo "公网 IPv4 : ${v4:-不可用}"
      echo "公网 IPv6 : ${v6:-不可用}"
    fi
  fi
}

# ==============================================================================
# 模块 13：安装/更新全局快捷命令 /usr/local/bin/ops
# ==============================================================================
mod_install_self() {
  require_root || return 1
  printf '\n%s=== 安装 / 更新快捷命令 ops ===%s\n' "$C_BOLD" "$C_RESET"

  local dst="/usr/local/bin/ops"
  local src=""
  if [[ -f "$OPS_SCRIPT_PATH" ]]; then
    src="$(cd "$(dirname "$OPS_SCRIPT_PATH")" && pwd)/$(basename "$OPS_SCRIPT_PATH")"
  fi

  install_from_github() {
    require_cmds curl mktemp install || return 1
    local tmp_script
    tmp_script="$(mktemp)"
    trap 'rm -f -- "${tmp_script:-}"' RETURN
    step "从 GitHub 拉取最新版 ops.sh..."
    curl -fsSL --connect-timeout 15 --max-time 60 "$OPS_REPO_RAW_URL" -o "$tmp_script" || {
      err "下载失败：${OPS_REPO_RAW_URL}"
      return 1
    }
    if ! bash -n "$tmp_script"; then
      err "下载的文件语法校验未通过，已中止覆盖。"
      return 1
    fi
    install -m 0755 "$tmp_script" "$dst"
    ok "已从 GitHub 安装/更新到 ${dst}（$("$dst" --version 2>/dev/null || echo 'ok')）"
  }

  if [[ -n "$src" && "$src" != "$dst" ]]; then
    echo "1) 从当前本地脚本安装到 ${dst}"
    echo "2) 从 GitHub 仓库拉取最新版安装到 ${dst}"
    echo "0) 返回"
    local mode
    read_prompt mode "请选择方式" "1" || return 1
    case "$mode" in
      1)
        install -m 0755 "$src" "$dst"
        ok "已安装到 ${dst}，之后在任意目录直接输入 ops 即可打开工具箱。"
        ;;
      2) install_from_github ;;
      0) msg "返回主菜单" ;;
      *) err "无效选择"; return 1 ;;
    esac
  else
    msg "将从 GitHub 拉取最新版并安装/更新到 ${dst}："
    echo "  ${OPS_REPO_RAW_URL}"
    confirm_yn "确认继续？" Y || { msg "已取消"; return 0; }
    install_from_github
  fi
}

# ==============================================================================
# 主菜单与 CLI 调度
# ==============================================================================
print_banner() {
  local host os_name arch cc disk_info swap_info user_tag
  host="$(hostname 2>/dev/null || echo 'unknown')"
  os_name="$(detect_os_name)"
  arch="$(uname -m)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')"
  disk_info="$(df -h / 2>/dev/null | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}')"
  if command -v free >/dev/null 2>&1; then
    swap_info="$(free -h | awk '/^Swap:/{print $3 "/" $2}')"
  else
    swap_info="-"
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    user_tag="${C_GREEN}root${C_RESET}"
  else
    user_tag="${C_YELLOW}$(id -un 2>/dev/null || echo non-root)${C_RESET}"
  fi

  printf '\n%s=====================================================%s\n' "$C_BLUE" "$C_RESET"
  printf '%s  VPS 运维工具箱 v%s%s   [%s@%s]\n' "$C_BOLD" "$OPS_VERSION" "$C_RESET" "$user_tag" "$host"
  printf '%s  %s | %s | BBR:%s | 磁盘:%s | Swap:%s%s\n' \
    "$C_DIM" "$os_name" "$arch" "$cc" "${disk_info:--}" "${swap_info:--}" "$C_RESET"
  printf '%s=====================================================%s\n' "$C_BLUE" "$C_RESET"
  cat <<'MENU'
  [系统基础]
   1) 修改主机名               2) 瘦身拳（系统/日志/Docker 清理）
   3) 开启 TCP BBR             4) Swap 交互式管理（增/改/删）
   7) LinuxMirrors 一键换源   12) 系统信息与状态速查

  [网络与代理]
   5) SpeedTest 测速（可即用即删） 6) 快速 GOST 代理管理 (SOCKS5/HTTP)
   8) Cloudflare DDNS 管理         9) 终端代理引导式配置 (v3.1)
  11) NodeQuality 测试

  [容器与工具]
  10) 安装 Docker             13) 安装/更新全局命令 (ops)
   0) 退出
MENU
  printf '%s-----------------------------------------------------%s\n' "$C_BLUE" "$C_RESET"
}

run_module_isolated() {
  local fn="$1"
  ( "$fn" )
  return $?
}

usage() {
  cat <<EOF
VPS 运维工具箱 v${OPS_VERSION}

用法:
  ops.sh                  进入交互式菜单
  ops.sh <subcommand>     直接执行指定模块

可用子命令:
  hostname      修改主机名
  slim          系统瘦身拳
  bbr           开启 TCP BBR
  swap          Swap 交互式管理
  speedtest     Ookla SpeedTest（支持临时测速用完即删 / 永久安装 / 卸载）
  gost          GOST 实例管理（默认低权限用户运行）
  mirror        LinuxMirrors 换源
  ddns          Cloudflare DDNS 安装与管理
  proxy         终端代理引导式配置 v3.1
  docker        安装 Docker（含可选日志轮转配置）
  nodequality   NodeQuality 测试
  status        系统信息与状态速查
  install-self  安装/更新脚本到 /usr/local/bin/ops（别名: update）
  -h, --help    显示本帮助
  -v, --version 显示版本号
EOF
}

dispatch_subcommand() {
  case "$1" in
    1|hostname)    run_module_isolated mod_hostname ;;
    2|slim)        run_module_isolated mod_slim ;;
    3|bbr)         run_module_isolated mod_bbr ;;
    4|swap)        run_module_isolated mod_swap ;;
    5|speedtest)   run_module_isolated mod_speedtest ;;
    6|gost)        run_module_isolated mod_gost ;;
    7|mirror)      run_module_isolated mod_mirror ;;
    8|ddns)        run_module_isolated mod_ddns ;;
    9|proxy)       run_module_isolated mod_proxy ;;
    10|docker)     run_module_isolated mod_docker ;;
    11|nodequality) run_module_isolated mod_nodequality ;;
    12|status)     run_module_isolated mod_status ;;
    13|install-self|update) run_module_isolated mod_install_self ;;
    -h|--help|help) usage ;;
    -v|--version)  echo "ops.sh v${OPS_VERSION}" ;;
    *)
      err "未知子命令: $1"
      usage
      return 1
      ;;
  esac
}

interactive_loop() {
  local choice rc
  while true; do
    print_banner
    read_prompt choice "请输入功能编号" "0" || { printf '\n'; break; }
    case "$choice" in
      0|q|Q|exit)
        msg "已退出运维工具箱。"
        break
        ;;
      1|2|3|4|5|6|7|8|9|10|11|12|13)
        dispatch_subcommand "$choice"
        rc=$?
        if (( rc != 0 )); then
          warn "操作未完成（退出码: ${rc}）"
        fi
        pause_enter
        ;;
      *)
        warn "无效编号：${choice}"
        ;;
    esac
  done
}

main() {
  init_tty
  if (( $# > 0 )); then
    dispatch_subcommand "$1"
  else
    interactive_loop
  fi
}

# 允许测试脚本设置 OPS_SOURCE_ONLY=1 后 source，同时兼容 curl ... | bash 执行
if [[ "${OPS_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
