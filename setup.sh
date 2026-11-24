#!/usr/bin/env bash
set -euo pipefail

# 若显式指定了 ENV_FILE，则必须存在；否则若当前目录有 ./.env 则加载
ENV_FILE="${ENV_FILE:-./.env}"
if [[ -n "${ENV_FILE_EXPLICIT:-}" && ! -f "${ENV_FILE}" ]]; then
  echo "[ERROR] 找不到指定的环境文件: ${ENV_FILE}" >&2
  exit 1
fi
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

# ================= 1. 环境变量（带默认值） =================
DOMAIN="${DOMAIN:-example.com}"
ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
CF_Token="${CF_Token:-}"
CF_Account_ID="${CF_Account_ID:-}"

SITE_DOMAIN="${SITE_DOMAIN:-}"
SITE_CDN_DOMAIN="${SITE_CDN_DOMAIN:-}"

CERT_DIR="${CERT_DIR:-/etc/ssl/private/${DOMAIN}}"
SRC_NGINX_CONF="${SRC_NGINX_CONF:-./nginx.conf}"
DST_NGINX_CONF="${DST_NGINX_CONF:-/etc/nginx/nginx.conf}"
SRC_XRAY_YML="${SRC_XRAY_YML:-./xray.yml}"
DST_XRAY_YML="${DST_XRAY_YML:-/usr/local/etc/xray/config.yml}"
XRAY_UUID="${XRAY_UUID:-}"
XRAY_PRIVATE_KEY="${XRAY_PRIVATE_KEY:-}"
XRAY_SHORT="${XRAY_SHORT:-}"

# ================= 2. 校验与工具函数 =================
require_non_empty() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "[ERROR] 关键变量不能为空: ${name}" >&2
    exit 1
  fi
}

check_xray_inputs() {
  require_non_empty SITE_DOMAIN
  require_non_empty SRC_XRAY_YML
  require_non_empty DST_XRAY_YML

  [[ -f "${SRC_XRAY_YML}" ]] || { echo "[ERROR] 找不到源配置文件: ${SRC_XRAY_YML}" >&2; exit 1; }
}

check_inputs() {
  require_non_empty DOMAIN
  require_non_empty ACME_EMAIL
  require_non_empty CF_Token
  require_non_empty CF_Account_ID
  require_non_empty SITE_DOMAIN
  require_non_empty SITE_CDN_DOMAIN
  require_non_empty CERT_DIR
  require_non_empty SRC_NGINX_CONF
  require_non_empty DST_NGINX_CONF

  [[ -f "${SRC_NGINX_CONF}" ]] || { echo "[ERROR] 找不到源配置文件: ${SRC_NGINX_CONF}" >&2; exit 1; }
  check_xray_inputs
}

replace_literal() {
  local file="${1:-}"
  local old="${2:-}"
  local new="${3:-}"

  if [[ -z "${file}" || -z "${old}" ]]; then
    echo "[ERROR] replace_literal 参数缺失: file='${file}' old='${old}'" >&2
    return 1
  fi

  local tmp="${file}.tmp.$$"
  awk -v old="$old" -v new="$new" '
    {
      out = ""
      while ((pos = index($0, old)) > 0) {
        out = out substr($0, 1, pos - 1) new
        $0 = substr($0, pos + length(old))
      }
      print out $0
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ================= 3. 安装与签发 =================
install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl socat nginx libnginx-mod-stream gawk
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl socat nginx gawk
  else
    echo "[ERROR] 暂不支持的包管理器" >&2
    exit 1
  fi
}

enable_bbr() {
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
}

install_xray() {
  if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi
}

issue_cert() {
  local acme="${HOME}/.acme.sh/acme.sh"
  local fullchain="${CERT_DIR}/fullchain.pem"
  local privkey="${CERT_DIR}/privkey.pem"

  [[ -x "$acme" ]] || curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL}"

  export CF_Token
  export CF_Account_ID
  mkdir -p "${CERT_DIR}"

  # 使用 acme.sh 默认 CA 与 Cloudflare DNS API 签发
  if [[ ! -s "${fullchain}" || ! -s "${privkey}" ]]; then
    "${acme}" --issue --dns dns_cf -d "${DOMAIN}" -d "*.${DOMAIN}"
  fi

  "${acme}" --install-cert -d "${DOMAIN}" \
    --key-file "${privkey}" \
    --fullchain-file "${fullchain}" \
    --reloadcmd "nginx -t && systemctl reload nginx"
}

# ================= 4. 替换占位符与启动 =================
render_nginx() {
  local fullchain="${CERT_DIR}/fullchain.pem"
  local privkey="${CERT_DIR}/privkey.pem"

  mkdir -p "$(dirname "${DST_NGINX_CONF}")"
  cp -f "${SRC_NGINX_CONF}" "${DST_NGINX_CONF}"
  replace_literal "${DST_NGINX_CONF}" "__DOMAIN__" "${DOMAIN}"
  replace_literal "${DST_NGINX_CONF}" "__SITE_DOMAIN__" "${SITE_DOMAIN}"
  replace_literal "${DST_NGINX_CONF}" "__SITE_CDN_DOMAIN__" "${SITE_CDN_DOMAIN}"
  replace_literal "${DST_NGINX_CONF}" "__FULLCHAIN__" "${fullchain}"
  replace_literal "${DST_NGINX_CONF}" "__PRIVKEY__" "${privkey}"

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

render_xray() {
  mkdir -p "$(dirname "${DST_XRAY_YML}")"
  cp -f "${SRC_XRAY_YML}" "${DST_XRAY_YML}"
  replace_literal "${DST_XRAY_YML}" "__SITE_DOMAIN__" "${SITE_DOMAIN}"
  replace_literal "${DST_XRAY_YML}" "__XRAY_UUID__" "${XRAY_UUID}"
  replace_literal "${DST_XRAY_YML}" "__XRAY_PRIVATE_KEY__" "${XRAY_PRIVATE_KEY}"
  replace_literal "${DST_XRAY_YML}" "__XRAY_SHORT__" "${XRAY_SHORT}"

  xray run -test -config "${DST_XRAY_YML}"
  cp -f "./xray-override.conf" "/etc/systemd/system/xray.service.d/"
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray
}

render_xray_only() {
  check_xray_inputs
  render_xray
}

render_and_start() {
  render_nginx
  render_xray
}

usage() {
  cat <<'EOF'
用法:
  ./deploy.sh [all|xray]

说明:
  all   完整安装依赖、Xray、签发证书并启动 Nginx 与 Xray（默认）
  install_deps  安装依赖
  enable_bbr  启用 BBR 拥塞控制算法
  issue_cert  签发 SSL 证书
  xray  根据当前 .env 重新替换 xray.yml 占位符、校验并重启 xray
  nginx  根据当前 .env 重新替换 nginx.conf 占位符、校验并重启 nginx
EOF
}

main() {
  local action="${1:-all}"
  [[ "${EUID}" -eq 0 ]] || { echo "[ERROR] 请使用 root 权限运行" >&2; exit 1; }

  case "${action}" in
    all)
      check_inputs
      install_deps
      enable_bbr
      issue_cert
      install_xray
      render_and_start
      ;;
    install_deps)
      install_deps
      ;;
    enable_bbr)
      enable_bbr
      ;;
    issue_cert)
      issue_cert
      ;;
    xray)
      render_xray_only
      ;;
    nginx)
      render_nginx
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "[ERROR] 未知参数: ${action}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
