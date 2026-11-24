#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPS_SH="${ROOT_DIR}/ops.sh"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s: expected=%q actual=%q\n' "$name" "$expected" "$actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_ok() {
  local name="$1"
  shift
  if "$@"; then
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s (command failed)\n' "$name" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@"; then
    printf '[FAIL] %s (expected failure but succeeded)\n' "$name" >&2
    FAIL=$((FAIL + 1))
  else
    printf '[PASS] %s\n' "$name"
    PASS=$((PASS + 1))
  fi
}

echo "=== 1. 语法与内嵌脚本安全检查 ==="
assert_ok "ops.sh bash -n" bash -n "$OPS_SH"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
awk '/^    cat > "\$INSTALL_PATH" <<\x27SCRIPT\x27$/{flag=1; next} /^SCRIPT$/{flag=0} flag' "$OPS_SH" > "${TMP_DIR}/cf-ddns.sh"
assert_ok   "extracted cf-ddns.sh non-empty" test -s "${TMP_DIR}/cf-ddns.sh"
assert_ok   "extracted cf-ddns.sh bash -n" bash -n "${TMP_DIR}/cf-ddns.sh"
assert_ok   "cf-ddns uses curl -K - for token" grep -q -- "-K -" "${TMP_DIR}/cf-ddns.sh"
assert_fail "cf-ddns does not pass Bearer in -H arg" grep -q -- '-H "Authorization: Bearer' "${TMP_DIR}/cf-ddns.sh"
assert_ok   "cf-ddns compares old_proxied" grep -q 'old_proxied' "${TMP_DIR}/cf-ddns.sh"
assert_ok   "cf-ddns supports state cache & --force" grep -q 'LAST_IPV4' "${TMP_DIR}/cf-ddns.sh"

# 测试 cf-ddns 的域名列表选择与主机名默认前缀/智能补全
ddns_helper_check="$(bash -c "
  set -euo pipefail
  CF_DDNS_SOURCE_ONLY=1 source '${TMP_DIR}/cf-ddns.sh'
  [[ \"\$(resolve_record_name 'hkbn' 'leoknox.de')\" == 'hkbn.leoknox.de' ]]
  [[ \"\$(resolve_record_name 'hkbn.leoknox.de' 'leoknox.de')\" == 'hkbn.leoknox.de' ]]
  [[ \"\$(resolve_record_name 'HK-01.' 'leoknox.de')\" == 'hk-01.leoknox.de' ]]
  [[ \"\$(resolve_record_name '@' 'leoknox.de')\" == 'leoknox.de' ]]
  [[ \"\$(resolve_record_name 'leoknox.de' 'leoknox.de')\" == 'leoknox.de' ]]
  # 模拟 Cloudflare /zones 响应测试 select_zone
  if command -v jq >/dev/null 2>&1; then
    TTY_FD=0
    cf_request() {
      printf '{\"success\":true,\"result\":[{\"id\":\"z111\",\"name\":\"leoknox.de\"},{\"id\":\"z222\",\"name\":\"example.org\"}]}'
    }
    select_zone <<< '2' >/dev/null
    [[ \"\$ZONE_ID\" == 'z222' && \"\$ZONE_NAME\" == 'example.org' ]]
  fi
  echo OK
")"
assert_eq "cf-ddns resolve_record_name & select_zone" "OK" "$ddns_helper_check"

echo
echo "=== 2. 纯函数单元测试 ==="
OPS_SOURCE_ONLY=1 source "$OPS_SH"

assert_ok   "hostname valid: hk-hytron-01" is_valid_hostname "hk-hytron-01"
assert_ok   "hostname valid: a"            is_valid_hostname "a"
assert_fail "hostname invalid: uppercase"  is_valid_hostname "HK-01"
assert_fail "hostname invalid: leading -"  is_valid_hostname "-abc"
assert_fail "hostname invalid: trailing -" is_valid_hostname "abc-"
assert_fail "hostname invalid: space"      is_valid_hostname "a b"

assert_ok   "ipv4 valid: 1.2.3.4"          is_valid_ipv4 "1.2.3.4"
assert_fail "ipv4 invalid: 256.1.1.1"      is_valid_ipv4 "256.1.1.1"
assert_fail "ipv4 invalid: text"           is_valid_ipv4 "not-an-ip"
assert_ok   "ipv6 valid: 2001:db8::1"      is_valid_ipv6 "2001:db8::1"
assert_fail "ipv6 invalid: html error"     is_valid_ipv6 "<html>:error</html>"

assert_eq "parse_size_to_mb 1G"    "1024" "$(parse_size_to_mb "1G")"
assert_eq "parse_size_to_mb 2gb"   "2048" "$(parse_size_to_mb "2gb")"
assert_eq "parse_size_to_mb 512M"  "512"  "$(parse_size_to_mb "512M")"
assert_eq "parse_size_to_mb 1024"  "1024" "$(parse_size_to_mb "1024")"
assert_fail "parse_size_to_mb 0G"  parse_size_to_mb "0G"
assert_fail "parse_size_to_mb abc" parse_size_to_mb "abc"

assert_eq "urlencode special chars" "p%40ss%3A%2F%3F%23%27%201" "$(urlencode "p@ss:/?#' 1")"
assert_eq "shell_quote_single"      "'a'\\''b'"                  "$(shell_quote_single "a'b")"
assert_eq "mask_proxy_url with auth" "socks5h://leo:******@[2001:db8::1]:10808" \
  "$(mask_proxy_url "socks5h://leo:s3cr%40t@[2001:db8::1]:10808")"
assert_eq "mask_proxy_url no auth"   "http://192.168.1.2:7890" \
  "$(mask_proxy_url "http://192.168.1.2:7890")"

# 测试 sync_hosts_file
HOSTS_TMP="${TMP_DIR}/hosts"
printf '127.0.0.1 localhost old-vps\n127.0.1.1 old-vps\n::1 localhost\n' > "$HOSTS_TMP"
sync_hosts_file "$HOSTS_TMP" "old-vps" "hk-hytron-01"
assert_ok   "sync_hosts updates 127.0.0.1 old name" grep -qx "127.0.0.1 localhost hk-hytron-01" "$HOSTS_TMP"
assert_ok   "sync_hosts updates 127.0.1.1"          grep -qx "127.0.1.1 hk-hytron-01" "$HOSTS_TMP"
assert_fail "sync_hosts removes old hostname"       grep -q "old-vps" "$HOSTS_TMP"

echo
echo "=== 3. CLI 调度、管道与 SpeedTest 临时模式检查 ==="
ver_out="$(bash "$OPS_SH" --version)"
assert_eq "CLI --version" "ops.sh v1.1.0" "$ver_out"

pipe_ver="$(cat "$OPS_SH" | bash -s -- --version)"
assert_eq "Piped bash -s -- --version" "ops.sh v1.1.0" "$pipe_ver"

help_out="$(bash "$OPS_SH" --help)"
assert_ok "CLI --help contains swap" grep -q "swap" <<< "$help_out"
assert_fail "CLI unknown subcommand fails" bash "$OPS_SH" nonexistent-cmd >/dev/null 2>&1

menu_out="$(printf '0\n' | OPS_USE_STDIN=1 bash "$OPS_SH")"
assert_ok "Interactive menu renders and exits on 0" grep -q "已退出运维工具箱" <<< "$menu_out"

status_out="$(printf 'n\n' | OPS_USE_STDIN=1 bash "$OPS_SH" status)"
assert_ok "status module prints hostname" grep -q "主机名" <<< "$status_out"

speedtest_out="$(printf '0\n' | OPS_USE_STDIN=1 bash "$OPS_SH" speedtest)"
assert_ok "speedtest offers temp auto-delete mode or existing menu" grep -Eq "临时下载并测速|直接测速" <<< "$speedtest_out"

echo
echo "=== 4. 终端代理模块 (mod_proxy v3.1) 沙盒端到端测试 ==="
FAKE_HOME="${TMP_DIR}/home"
mkdir -p "$FAKE_HOME"
printf '# existing user config\nexport FOO=bar\n' > "${FAKE_HOME}/.bashrc"

# 模式 3：IPv6 + 含特殊字符密码认证 + 跳过联网测试
printf '1\n[2001:db8::1]\n10808\n1\ny\nuser@1\np@ss:w'\''d\nlocalhost,127.0.0.1\n3\nn\n' \
  | HOME="$FAKE_HOME" SHELL="/bin/bash" OPS_USE_STDIN=1 bash "$OPS_SH" proxy >/dev/null

ENV_FILE="${FAKE_HOME}/.config/terminal-proxy/env"
assert_ok   "proxy mode 3 created env file" test -f "$ENV_FILE"
assert_ok   "proxy mode 3 wrote marker to bashrc" grep -q "TERMINAL_PROXY_V3_MANAGED" "${FAKE_HOME}/.bashrc"
assert_fail "proxy mode 3 keeps password OUT of bashrc" grep -q "p%40ss" "${FAKE_HOME}/.bashrc"
assert_ok   "proxy mode 3 keeps password IN 600 env file" grep -q "p%40ss%3Aw%27d" "$ENV_FILE"
assert_fail "proxy_test does not pass -4/-6 to curl" grep -Eq 'curl -[46]' "${FAKE_HOME}/.bashrc"
assert_ok   "proxy mode 3 preserved existing line" grep -q "export FOO=bar" "${FAKE_HOME}/.bashrc"
assert_ok   "proxy mode 3 generated bash-valid rc" bash -n "${FAKE_HOME}/.bashrc"

# 验证权限为 600
env_perm="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE")"
assert_eq "proxy env file permission is 600" "600" "$env_perm"

# 实际 source 生成的 .bashrc 并测试 proxy_on / 动态 proxy_status / proxy_off
proxy_check="$(bash -c "
  set -e
  source '${FAKE_HOME}/.bashrc'
  proxy_on >/dev/null
  [[ \"\$ALL_PROXY\" == 'socks5h://user%401:p%40ss%3Aw%27d@[2001:db8::1]:10808' ]]
  [[ -z \"\${TERMINAL_PROXY_URL:-}\" ]]
  [[ \"\$NO_PROXY\" == 'localhost,127.0.0.1' ]]
  st_on=\$(proxy_status)
  grep -q '状态       : ON' <<< \"\$st_on\"
  grep -q '当前代理   : socks5h://user%401:\*\*\*\*\*\*@\[2001:db8::1\]:10808' <<< \"\$st_on\"
  # 验证动态读取当前环境变量而非静态写死值
  export ALL_PROXY='http://alice:secret99@10.0.0.1:8080'
  st_dyn=\$(proxy_status)
  grep -q '当前代理   : http://alice:\*\*\*\*\*\*@10.0.0.1:8080' <<< \"\$st_dyn\"
  proxy_off >/dev/null
  [[ -z \"\${ALL_PROXY:-}\" ]]
  st_off=\$(proxy_status)
  grep -q '状态       : OFF' <<< \"\$st_off\"
  echo OK
")"
assert_eq "proxy_on/dynamic status/off lifecycle (bash)" "OK" "$proxy_check"

# zsh 兼容性测试（如果系统有 zsh）
if command -v zsh >/dev/null 2>&1; then
  zsh_check="$(zsh -c "
    set -e
    source '${FAKE_HOME}/.bashrc'
    proxy_on >/dev/null
    [[ \"\$ALL_PROXY\" == 'socks5h://user%401:p%40ss%3Aw%27d@[2001:db8::1]:10808' ]]
    proxy_status | grep -q '状态       : ON'
    proxy_off >/dev/null
    [[ -z \"\${ALL_PROXY:-}\" ]]
    echo OK
  ")"
  assert_eq "proxy_on/status/off lifecycle (zsh)" "OK" "$zsh_check"
fi

# 模式 2：覆盖更新（不应出现重复 marker 块）
printf '1\n192.168.31.134\n7890\n3\nn\n\n2\nn\n' \
  | HOME="$FAKE_HOME" SHELL="/bin/bash" OPS_USE_STDIN=1 bash "$OPS_SH" proxy >/dev/null
marker_count="$(grep -c ">>> TERMINAL_PROXY_V3_MANAGED >>>" "${FAKE_HOME}/.bashrc")"
assert_eq "proxy mode 2 replaces old block without duplication" "1" "$marker_count"
assert_ok "proxy mode 2 writes http URL to env file" grep -q "TERMINAL_PROXY_URL='http://192.168.31.134:7890'" "$ENV_FILE"

# 入口选项 2：清理配置块与凭据文件
printf '2\n' \
  | HOME="$FAKE_HOME" SHELL="/bin/bash" OPS_USE_STDIN=1 bash "$OPS_SH" proxy >/dev/null
assert_fail "proxy cleanup removes marker" grep -q "TERMINAL_PROXY_V3_MANAGED" "${FAKE_HOME}/.bashrc"
assert_fail "proxy cleanup deletes env file" test -e "$ENV_FILE"
assert_ok   "proxy cleanup keeps original user config" grep -q "export FOO=bar" "${FAKE_HOME}/.bashrc"

echo
echo "=== 5. 非 root 拦截与 errexit 隔离检查 ==="
if [[ "$(id -u)" -ne 0 ]]; then
  bbr_out="$(OPS_USE_STDIN=1 bash "$OPS_SH" bbr 2>&1 || true)"
  assert_ok   "non-root bbr shows root error" grep -q "需要 root 权限" <<< "$bbr_out"
  assert_fail "non-root bbr stops before body" grep -q "开启 TCP BBR" <<< "$bbr_out"
fi

echo
echo "=== 测试汇总: PASS=${PASS}, FAIL=${FAIL} ==="
(( FAIL == 0 ))
