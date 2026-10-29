#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

REPO_URL="https://github.com/telegramdesktop/tproxy-server.git"
SELF_RAW_URL="https://raw.githubusercontent.com/IohnMorris/tg_web_proxy_deploy/main/install.sh"
INSTALL_DIR="/opt/tproxy-server"
SITE_DIR="/srv/tproxy-site"
SITE_INDEX="/srv/tproxy-site/index.html"
CONFIG_FILE="/etc/tproxy-server/config.json"
PROFILES_FILE="/etc/tproxy-server/profiles.json"
TRAFFIC_DB="/etc/tproxy-server/traffic_stats.json"
MTPROXY_ENV="/etc/mtproxy/mtproxy.env"
CADDYFILE="/etc/caddy/Caddyfile"
CLI_PATH="/usr/local/bin/tg-proxy"
ALIAS_PATH="/usr/local/bin/proxy"
NFT_TABLE="tg_proxy_stats"
BASE_BACKEND_PORT=2398

# A single nft snapshot is reused while a screen is rendered.  Calling nft for
# every profile made large installations noticeably slower without improving
# the displayed counters.
PROFILE_ROWS=()

load_profile_rows() {
  PROFILE_ROWS=()
  [[ -f "$PROFILES_FILE" ]] || return 0
  mapfile -t PROFILE_ROWS < <(
    jq -r '.profiles[] | [(.name // ""), (.secret // ""), (.carrier_mode // "https"), (.backend // "")] | join("\u001f")' \
      "$PROFILES_FILE" 2>/dev/null || true
  )
}

begin_metrics_snapshot() {
  NFT_SNAPSHOT_CACHE="$(nft -j list table inet "$NFT_TABLE" 2>/dev/null || true)"
}

end_metrics_snapshot() {
  unset NFT_SNAPSHOT_CACHE
}

# Interactive sessions choose a language; scripted calls keep the Russian default.
# PROXY_LANG=ru or PROXY_LANG=en selects a language without prompting.
PROXY_LANG="${PROXY_LANG:-}"
if [[ "$PROXY_LANG" != "ru" && "$PROXY_LANG" != "en" ]]; then
  PROXY_LANG=ru
  if [[ -t 0 && -t 1 ]]; then
    printf 'Language / Язык: 1) Русский  2) English [1]: '
    read -r language_choice || language_choice=""
    case "${language_choice,,}" in 2|en|english) PROXY_LANG=en ;; esac
  fi
fi
export PROXY_LANG
tr_text() { if [[ "$PROXY_LANG" == en ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

write_file_atomically() {
  local source="$1" target="$2" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 1
  if ! cat "$source" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -e "$target" ]]; then
    chown --reference="$target" "$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$target" "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$target"
}

# --- Цвета и оформление ---
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "$(tr_text "Ошибка: $*" "Error: $*")"; exit 1; }

hr() {
  cyan "────────────────────────────────────────────────────────────────────────────"
}

header_box() {
  local title="$1"
  cyan "┌──────────────────────────────────────────────────────────────────────────┐"
  printf "\033[36m│\033[0m \033[1m%s\033[0m\n" "$title"
  cyan "└──────────────────────────────────────────────────────────────────────────┘"
}

ask() {
  local prompt="$1" var="$2" value=""
  read -r -p "$prompt" value
  printf -v "$var" '%s' "$value"
}

pause_menu() {
  printf '\n'
  read -r -p "$(tr_text "Нажми Enter, чтобы продолжить..." "Press Enter to continue...")" _
}

# Подтверждение опасных действий (защита от случайного нажатия)
confirm_danger() {
  local warn_msg="$1"
  local ans=""
  printf '\n'
  yellow "$(tr_text "⚠️  ВНИМАНИЕ: $warn_msg" "⚠️  WARNING: $warn_msg")"
  read -r -p "$(tr_text "Для подтверждения введи 'yes' (или 'д') [Enter = Отмена]: " "Type 'yes' to confirm [Enter = Cancel]: ")" ans
  case "${ans,,}" in
    yes|y|д|да) return 0 ;;
    *)
      cyan "$(tr_text "Операция отменена. Ничего не изменено." "Operation cancelled. Nothing was changed.")"
      return 1
      ;;
  esac
}

trap 'rc=$?; red "$(tr_text "Выполнение прервано (код $rc)." "Execution interrupted (code $rc).")"; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || die "$(tr_text "Запустите скрипт от имени root: sudo bash $0" "Run as root: sudo bash $0")"

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (Мониторинг CPU/RAM, Криптография, Конфиги, Трафик)
# ==============================================================================

# Валидация и нормализация названия режима транспорта (carrier_mode)
normalize_carrier_mode() {
  local m="${1,,}"
  case "$m" in
    1|https) echo "https" ;;
    2|https-lanes|lanes) echo "https-lanes" ;;
    3|websocket|ws) echo "websocket" ;;
    4|websocket-lanes|ws-lanes|wslanes) echo "websocket-lanes" ;;
    *) echo "" ;;
  esac
}

# Интерактивный выбор режима транспорта (carrier_mode)
prompt_carrier_mode() {
  local default_mode="${1:-https}"
  local out_var="$2"
  local cur_label="$default_mode"

  printf '\n'
  bold "$(tr_text "Выбери транспорт (carrier_mode):" "Choose a transport (carrier_mode):")"
  printf "$(tr_text "  \033[1;36m1) https\033[0m           — 1 POST + 1 long poll (базовый, макс. совместимость)\n" "  \033[1;36m1) https\033[0m           — 1 POST + 1 long poll (basic, maximum compatibility)\n")"
  printf "$(tr_text "  \033[1;36m2) https-lanes\033[0m     — независимые POST/poll на каждый поток (HTTP/2, изоляция задержек)\n" "  \033[1;36m2) https-lanes\033[0m     — independent POST/poll per stream (HTTP/2, latency isolation)\n")"
  printf "$(tr_text "  \033[1;32m3) websocket\033[0m       — 1 общий WebSocket для всех потоков (без пауз HTTP stop-and-wait)\n" "  \033[1;32m3) websocket\033[0m       — 1 shared WebSocket for all streams (no HTTP stop-and-wait pauses)\n")"
  printf "$(tr_text "  \033[1;32m4) websocket-lanes\033[0m — отдельный WebSocket на каждый поток (медиа не блокирует чат)\n" "  \033[1;32m4) websocket-lanes\033[0m — separate WebSocket per stream (media does not block chat)\n")"

  local ch=""
  read -r -p "$(tr_text "Выбор [1-4 или название, Enter = ${cur_label}]: " "Choice [1-4 or name, Enter = ${cur_label}]: ")" ch
  if [[ -z "$ch" ]]; then
    printf -v "$out_var" '%s' "$default_mode"
    return 0
  fi

  local norm
  norm="$(normalize_carrier_mode "$ch")"
  if [[ -n "$norm" ]]; then
    printf -v "$out_var" '%s' "$norm"
  else
    yellow "$(tr_text "Неизвестный режим '$ch', используется '$default_mode'." "Unknown mode '$ch'; using '$default_mode'.")"
    printf -v "$out_var" '%s' "$default_mode"
  fi
}

# Мгновенный срез нагрузки CPU, RAM, Load Average и диска для шапки меню
get_system_metrics_line() {
  python3 - <<'PY'
import os, time
english = os.environ.get("PROXY_LANG") == "en"

def read_cpu():
    with open('/proc/stat', 'r') as f:
        vals = [int(x) for x in f.readline().split()[1:]]
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    return idle, sum(vals)

try:
    i1, t1 = read_cpu()
    time.sleep(0.12)
    i2, t2 = read_cpu()
    dt = t2 - t1
    cpu_pct = int(round(100.0 * (1.0 - (i2 - i1) / dt))) if dt > 0 else 0
except Exception:
    cpu_pct = 0

cores = os.cpu_count() or 1
try:
    la = os.getloadavg()[0]
except Exception:
    la = 0.0

mem = {}
try:
    with open('/proc/meminfo', 'r') as f:
        for line in f:
            parts = line.split(':')
            if len(parts) == 2:
                mem[parts[0].strip()] = int(parts[1].strip().split()[0])
    total_mb = mem.get('MemTotal', 0) // 1024
    avail_mb = mem.get('MemAvailable', mem.get('MemFree', 0)) // 1024
    used_mb = max(0, total_mb - avail_mb)
    ram_pct = int(round(100.0 * used_mb / total_mb)) if total_mb > 0 else 0
except Exception:
    used_mb, total_mb, ram_pct = 0, 0, 0

try:
    st = os.statvfs('/')
    disk_total = st.f_blocks * st.f_frsize
    disk_free = st.f_bavail * st.f_frsize
    disk_used = disk_total - disk_free
    disk_pct = int(round(100.0 * disk_used / disk_total)) if disk_total > 0 else 0
except Exception:
    disk_pct = 0

def colorize(val_str, pct):
    if pct >= 85:
        return f"\033[1;31m{val_str}\033[0m"
    elif pct >= 65:
        return f"\033[1;33m{val_str}\033[0m"
    return f"\033[1;32m{val_str}\033[0m"

cpu_s = colorize(f"{cpu_pct}%", cpu_pct)
ram_s = colorize(f"{used_mb}/{total_mb} MB ({ram_pct}%)", ram_pct)
disk_s = colorize(f"{disk_pct}%", disk_pct)

print(f"CPU: {cpu_s} ({cores} {'cores' if english else 'яд.'}, LA: {la:.2f})   |   RAM: {ram_s}   |   {'Disk' if english else 'Диск'}: {disk_s}")
PY
}

# Запуск интерактивного htop
open_htop_monitor() {
  if ! command -v htop >/dev/null 2>&1; then
    yellow "$(tr_text "Устанавливаем htop..." "Installing htop...")"
    apt-get update && apt-get install -y htop
  fi
  htop
}

# 1 устройство в Telegram открывает от 1 до 6 TCP-потоков (сигнал + медиа DC).
# Считаем: 1..6 потоков = ~1 чел., 7..12 = ~2 чел. и т.д.
calc_users_from_conns() {
  local c="${1:-0}"
  if (( c <= 0 )); then
    echo 0
  else
    echo $(( (c + 5) / 6 ))
  fi
}

# Генерация ровно 16-символьного base32 slug (a-z, 2-7) без переносов строки
generate_base_path_slug() {
  python3 -c 'import secrets; alphabet = "abcdefghijklmnopqrstuvwxyz234567"; print("".join(secrets.choice(alphabet) for _ in range(16)), end="")'
}

# Деривация клиентского секрета для ссылки t.me/webproxy
derive_web_secret() {
  local hex_secret="${1#dd}"
  local base_path="${2:-}"
  if [[ -z "$base_path" ]]; then
    printf '%s' "$hex_secret"
  else
    { printf '\x70'; printf "$(printf '%s' "$hex_secret" | sed 's/../\\x&/g')"; } \
      | base64 | tr '+/' '-_' | tr -d '=\n'
  fi
}

format_bytes() {
  local bytes="${1:-0}"
  python3 - "$bytes" <<'PY'
import sys
b = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 0
for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
    if b < 1024.0 or unit == 'TB':
        print(f"{b:.2f} {unit}" if unit != 'B' else f"{int(b)} B")
        break
    b /= 1024.0
PY
}

get_hostname() {
  local h=""
  if [[ -f "$CONFIG_FILE" ]]; then
    h=$(jq -r '.public_hostname // .hostname // empty' "$CONFIG_FILE" 2>/dev/null || true)
  fi
  if [[ -z "$h" && -f "$CADDYFILE" ]]; then
    h=$(awk '/^[a-zA-Z0-9._-]+(\:[0-9]+)?[[:space:]]*\{/ {gsub(/:[0-9]+/, "", $1); print $1; exit}' "$CADDYFILE" 2>/dev/null || true)
  fi
  if [[ -z "$h" && -f "$SITE_INDEX" ]]; then
    h=$(sed -n 's/.*<title>\(.*\)<\/title>.*/\1/p' "$SITE_INDEX" 2>/dev/null | head -n 1 || true)
  fi
  printf '%s' "$h"
}

get_base_path() {
  if [[ -f "$CONFIG_FILE" ]]; then
    jq -r '.base_path // empty' "$CONFIG_FILE" 2>/dev/null || true
  fi
}

# Установка глобальных команд: sudo tg-proxy и sudo proxy
# Работает даже при запуске через bash -c "$(curl -sSL ...)"
install_cli_command() {
  local src=""

  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  elif [[ -f "$0" && "$(basename "$0")" != "bash" && "$(basename "$0")" != "sh" ]]; then
    src="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  fi

  if [[ -n "$src" && -f "$src" ]]; then
    if [[ "$src" != "$CLI_PATH" ]]; then
      cp -f "$src" "$CLI_PATH"
    fi
    chmod +x "$CLI_PATH"
  else
    local tmp_cli
    tmp_cli="$(mktemp)"
    if curl -fsSL "${SELF_RAW_URL}?t=$(date +%s)" -o "$tmp_cli" 2>/dev/null && grep -q "REPO_URL=" "$tmp_cli"; then
      mv -f "$tmp_cli" "$CLI_PATH"
      chmod +x "$CLI_PATH"
    else
      rm -f "$tmp_cli"
      for f in install.sh tg-proxy.sh deploy.sh; do
        if [[ -f "./$f" ]]; then
          cp -f "./$f" "$CLI_PATH"
          chmod +x "$CLI_PATH"
          break
        fi
      done
    fi
  fi

  if [[ -x "$CLI_PATH" ]]; then
    ln -sf "$CLI_PATH" "$ALIAS_PATH" 2>/dev/null || true
  fi
}

# Самообновление скрипта панели с GitHub
self_update_script() {
  printf '\n'
  header_box "$(tr_text "ОБНОВЛЕНИЕ ПАНЕЛИ TG-PROXY С GITHUB" "UPDATE TG-PROXY PANEL FROM GITHUB")"
  yellow "$(tr_text "Скачивание свежей версии из: $SELF_RAW_URL" "Downloading latest version from: $SELF_RAW_URL")"

  local tmp_new
  tmp_new="$(mktemp)"
  if ! curl -fsSL "${SELF_RAW_URL}?t=$(date +%s)" -o "$tmp_new"; then
    rm -f "$tmp_new"
    red "$(tr_text "Не удалось скачать файл с GitHub. Проверь интернет или доступность репозитория." "Could not download from GitHub. Check your connection and repository availability.")"
    return 1
  fi

  if ! grep -q "REPO_URL=" "$tmp_new"; then
    rm -f "$tmp_new"
    red "$(tr_text "Скачанный файл поврежден или не является скриптом tg-proxy." "The downloaded file is damaged or is not a tg-proxy script.")"
    return 1
  fi

  mv -f "$tmp_new" "$CLI_PATH"
  chmod +x "$CLI_PATH"
  ln -sf "$CLI_PATH" "$ALIAS_PATH" 2>/dev/null || true

  green "$(tr_text "Скрипт панели успешно обновлен в $CLI_PATH (и $ALIAS_PATH)!" "Panel updated successfully at $CLI_PATH (and $ALIAS_PATH)!")"
  sleep 1
  exec "$CLI_PATH"
}

# ==============================================================================
# АККУРАТНАЯ СМЕНА ДОМЕНА ПРОКСИ + ПЕРЕВЫПУСК СЕРТИФИКАТА В CADDY
# ==============================================================================

change_domain() {
  local new_host="${1:-}"
  local old_host
  old_host="$(get_hostname)"

  printf '\n'
  header_box "$(tr_text "СМЕНА ДОМЕНА ПРОКСИ И ПОЛУЧЕНИЕ SSL-СЕРТИФИКАТА CADDY" "CHANGE PROXY DOMAIN AND ISSUE CADDY SSL CERTIFICATE")"
  printf "$(tr_text "  Текущий домен: \033[1;33m%s\033[0m\n\n" "  Current domain: \033[1;33m%s\033[0m\n\n")" "${old_host:-$(tr_text "не задан" "not set")}"

  if [[ -z "$new_host" ]]; then
    ask "$(tr_text "Введи новый домен (например, example.com) [Enter = Отмена]: " "Enter a new domain (e.g. example.com) [Enter = Cancel]: ")" new_host
  fi

  # Очистка от протокола, слешей и пробелов
  new_host="${new_host#http://}"
  new_host="${new_host#https://}"
  new_host="${new_host%%/*}"
  new_host="${new_host//[[:space:]]/}"
  new_host="${new_host,,}"

  if [[ -z "$new_host" ]]; then
    cyan "$(tr_text "Смена домена отменена." "Domain change cancelled.")"
    return 0
  fi

  if [[ ! "$new_host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
    red "$(tr_text "Некорректный формат домена: '$new_host'" "Invalid domain format: '$new_host'")"
    return 1
  fi

  if [[ "$new_host" == "$old_host" ]]; then
    yellow "$(tr_text "Новый домен совпадает с текущим ($old_host)." "The new domain matches the current domain ($old_host).")"
    return 0
  fi

  local new_email=""
  ask "$(tr_text "Email для сертификата Let's Encrypt [Enter = admin@${new_host}]: " "Let's Encrypt certificate email [Enter = admin@${new_host}]: ")" new_email
  [[ -z "$new_email" ]] && new_email="admin@${new_host}"

  # Проверяем DNS-запись домена и внешний IP сервера
  yellow "$(tr_text "Проверка DNS A-записи для $new_host..." "Checking DNS A record for $new_host...")"
  local srv_ip="" dom_ip=""
  srv_ip="$(curl -4fsSL --max-time 4 https://api.ipify.org 2>/dev/null || curl -4fsSL --max-time 4 https://ifconfig.me 2>/dev/null || true)"
  dom_ip="$(python3 -c "import socket; print(socket.gethostbyname('$new_host'))" 2>/dev/null || true)"

  if [[ -z "$dom_ip" ]]; then
    if ! confirm_danger "$(tr_text "Домен $new_host сейчас не резолвится в IP (DNS еще не обновился). Caddy не сможет получить сертификат, пока A-запись не направлена на сервер (${srv_ip:-IP}). Продолжить всё равно?" "Domain $new_host does not resolve to an IP yet. Caddy cannot obtain a certificate until its A record points to this server (${srv_ip:-IP}). Continue anyway?")"; then
      return 0
    fi
  elif [[ -n "$srv_ip" && "$dom_ip" != "$srv_ip" ]]; then
    if ! confirm_danger "$(tr_text "Домен $new_host указывает на IP $dom_ip, а IP этого сервера — $srv_ip. Если не включен прокси и порт 80/443 не ведет сюда, Caddy не получит сертификат. Продолжить?" "Domain $new_host points to $dom_ip, but this server's IP is $srv_ip. If ports 80/443 do not reach this server, Caddy cannot obtain a certificate. Continue?")"; then
      return 0
    fi
  else
    green "$(tr_text "✔ DNS проверен: $new_host -> ${dom_ip:-OK}" "✔ DNS verified: $new_host -> ${dom_ip:-OK}")"
  fi

  if ! confirm_danger "$(tr_text "Домен будет изменен с '${old_host:-нет}' на '$new_host'. Все ключи и пути (base_path) сохранятся, но ссылки обновятся." "The domain will change from '${old_host:-none}' to '$new_host'. Keys and base paths will be preserved, but links will change.")"; then
    return 0
  fi

  # Создаем резервные копии перед изменениями
  local bkp_dir
  bkp_dir="$(mktemp -d /tmp/tg_proxy_dom_bkp.XXXXXX)"
  [[ -f "$CONFIG_FILE" ]] && cp -f "$CONFIG_FILE" "$bkp_dir/config.json"
  [[ -f "$CADDYFILE" ]] && cp -f "$CADDYFILE" "$bkp_dir/Caddyfile"
  [[ -f "$SITE_INDEX" ]] && cp -f "$SITE_INDEX" "$bkp_dir/index.html"

  # 1. Обновляем config.json (если там хранятся поля public_hostname / hostname)
  if [[ -f "$CONFIG_FILE" ]]; then
    local tmp_cfg
    tmp_cfg="$(mktemp)"
    jq --arg h "$new_host" '
      if has("public_hostname") then .public_hostname = $h else . end |
      if has("hostname") then .hostname = $h else . end
    ' "$CONFIG_FILE" > "$tmp_cfg"
    write_file_atomically "$tmp_cfg" "$CONFIG_FILE"
    rm -f "$tmp_cfg"
  fi

  # 2. Обновляем или пересоздаем /etc/caddy/Caddyfile
  local listen_addr="127.0.0.1:8080"
  if [[ -f "$CONFIG_FILE" ]]; then
    listen_addr=$(jq -r '.listen_addr // "127.0.0.1:8080"' "$CONFIG_FILE" 2>/dev/null || echo "127.0.0.1:8080")
  fi

  if [[ -f "$CADDYFILE" ]]; then
    python3 - "$CADDYFILE" "$old_host" "$new_host" "$new_email" "$listen_addr" <<'PY'
import re, sys

c_path, old_h, new_h, email, l_addr = sys.argv[1:6]
with open(c_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Обновляем email в глобальном блоке
if re.search(r'(?m)^\s*email\s+\S+', content):
    content = re.sub(r'(?m)^(\s*email\s+)\S+', r'\g<1>' + email, content)

replaced = False
if old_h and old_h in content:
    content = content.replace(old_h, new_h)
    replaced = True
else:
    # Заменяем заголовок сайта вида domain.tld { или domain.tld:443 {
    new_content, n = re.subn(
        r'(?m)^([a-zA-Z0-9._-]+(?:\:[0-9]+)?)(\s*\{)',
        f'{new_h}\\2',
        content,
        count=1
    )
    if n > 0:
        content = new_content
        replaced = True

if not replaced:
    content = f"""{{
    email {email}
}}

{new_h} {{
    reverse_proxy {l_addr}
}}
"""

with open(c_path, 'w', encoding='utf-8') as f:
    f.write(content)
PY
  else
    mkdir -p "$(dirname "$CADDYFILE")"
    cat > "$CADDYFILE" <<EOF
{
    email ${new_email}
}

${new_host} {
    reverse_proxy ${listen_addr}
}
EOF
  fi

  # 3. Валидируем конфигурацию Caddy перед применением
  if command -v caddy >/dev/null 2>&1; then
    caddy fmt --overwrite "$CADDYFILE" 2>/dev/null || true
    if ! caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then
      red "$(tr_text "Ошибка валидации Caddyfile! Откатываем изменения обратно..." "Caddyfile validation failed! Rolling back changes...")"
      [[ -f "$bkp_dir/config.json" ]] && cp -f "$bkp_dir/config.json" "$CONFIG_FILE"
      [[ -f "$bkp_dir/Caddyfile" ]] && cp -f "$bkp_dir/Caddyfile" "$CADDYFILE"
      rm -rf "$bkp_dir"
      return 1
    fi
  fi

  # 4. Обновляем title в сайте-заглушке, если там стоял старый домен
  if [[ -f "$SITE_INDEX" && -n "$old_host" ]]; then
    sed -i "s|${old_host}|${new_host}|g" "$SITE_INDEX" 2>/dev/null || true
  fi

  # 5. Перезапускаем сервисы и Caddy
  yellow "$(tr_text "Применяем новый домен в Caddy и перезапускаем прокси..." "Applying the new domain in Caddy and restarting the proxy...")"
  sync_and_restart_services
  if ! systemctl reload caddy 2>/dev/null; then
    systemctl restart caddy 2>/dev/null || true
  fi

  # 6. Ждем выпуска SSL-сертификата и проверяем HTTPS
  yellow "$(tr_text "Ожидание выпуска TLS-сертификата Let's Encrypt для https://${new_host} (до 30 сек)..." "Waiting for a Let's Encrypt TLS certificate for https://${new_host} (up to 30 seconds)...")"
  local cert_ok=0
  for (( step=1; step<=15; step++ )); do
    if curl -fsSIL --max-time 3 "https://${new_host}/" >/dev/null 2>&1; then
      cert_ok=1
      break
    fi
    printf "."
    sleep 2
  done
  printf "\n"

  rm -rf "$bkp_dir"

  if (( cert_ok == 1 )); then
    green "$(tr_text "✅ Сертификат успешно получен и HTTPS на https://${new_host} полностью работает!" "✅ Certificate obtained successfully; HTTPS at https://${new_host} is working!")"
  else
    yellow "$(tr_text "⚠️  Конфиг успешно применен, но HTTPS пока в процессе выпуска сертификата." "⚠️  Configuration applied, but the HTTPS certificate is still being issued.")"
    yellow "$(tr_text "   Проверь логи: journalctl -u caddy -n 30 --no-pager" "   Check logs: journalctl -u caddy -n 30 --no-pager")"
  fi

  print_proxy_info "$new_host"
}

# Редактор сайта-заглушки (/srv/tproxy-site/index.html)
edit_site_stub() {
  mkdir -p "$SITE_DIR"
  local host
  host="$(get_hostname)"
  [[ -z "$host" ]] && host="localhost"

  if [[ ! -f "$SITE_INDEX" ]]; then
    cat > "$SITE_INDEX" <<HTML
<!doctype html>
<html lang="${PROXY_LANG}">
<head>
  <meta charset="utf-8">
  <title>${host}</title>
</head>
<body><h1>$(tr_text "Сайт находится в разработке." "This site is under construction.")</h1></body>
</html>
HTML
    chmod 644 "$SITE_INDEX"
  fi

  while true; do
    clear 2>/dev/null || true
    header_box "$(tr_text "УПРАВЛЕНИЕ САЙТОМ-ЗАГЛУШКОЙ" "PLACEHOLDER WEBSITE MANAGEMENT")"
    printf "$(tr_text "  Путь к файлу:  \033[1;33m%s\033[0m\n" "  File path:  \033[1;33m%s\033[0m\n")" "$SITE_INDEX"
    printf "$(tr_text "  Папка статики: \033[36m%s\033[0m\n" "  Static directory: \033[36m%s\033[0m\n")" "$SITE_DIR"
    printf "$(tr_text "  URL проверка:  https://%s/\n" "  Check URL:  https://%s/\n")" "$host"
    hr
    printf "$(tr_text "  \033[1mТекущее содержимое (первые 12 строк):\033[0m\n" "  \033[1mCurrent contents (first 12 lines):\033[0m\n")"
    sed -n '1,12p' "$SITE_INDEX" | sed 's/^/    /'
    hr
    printf "$(tr_text "  \033[1;32m1)\033[0m Открыть и редактировать в \033[1mnano\033[0m\n" "  \033[1;32m1)\033[0m Open and edit in \033[1mnano\033[0m\n")"
    printf "$(tr_text "  \033[1;36m2)\033[0m Сбросить на стандартный шаблон («Сайт в разработке»)\n" "  \033[1;36m2)\033[0m Reset to the default template (site under construction)\n")"
    printf "$(tr_text "  \033[1;90m0)\033[0m Назад в главное меню\n\n" "  \033[1;90m0)\033[0m Back to main menu\n\n")"

    local s_ch=""
    ask "$(tr_text "Выбор [1/2/0, Enter = 1]: " "Choice [1/2/0, Enter = 1]: ")" s_ch
    case "${s_ch:-1}" in
      1)
        if ! command -v nano >/dev/null 2>&1; then
          yellow "$(tr_text "Устанавливаем nano..." "Installing nano...")"
          apt-get update && apt-get install -y nano
        fi
        nano "$SITE_INDEX"
        chmod -R 755 "$SITE_DIR"
        green "$(tr_text "Изменения сохранены! Сайт по адресу https://$host/ уже обновлен." "Changes saved! The site at https://$host/ is updated.")"
        pause_menu
        ;;
      2)
        if confirm_danger "$(tr_text "Текущий файл $SITE_INDEX будет перезаписан стандартным шаблоном." "The current file $SITE_INDEX will be overwritten with the default template.")"; then
          cat > "$SITE_INDEX" <<HTML
<!doctype html>
<html lang="${PROXY_LANG}">
<head>
  <meta charset="utf-8">
  <title>${host}</title>
</head>
<body><h1>$(tr_text "Сайт находится в разработке." "This site is under construction.")</h1></body>
</html>
HTML
          chmod -R 755 "$SITE_DIR"
          green "$(tr_text "Стандартная заглушка восстановлена." "Default placeholder restored.")"
        fi
        pause_menu
        ;;
      0|q) return 0 ;;
    esac
  done
}

# Строгая нормализация profiles.json (ТОЛЬКО поля name, secret, backend, carrier_mode!)
ensure_profiles_structure() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  mkdir -p "$(dirname "$PROFILES_FILE")"

  local cur_bp
  cur_bp="$(get_base_path)"
  if [[ ${#cur_bp} -eq 32 && "${cur_bp:0:16}" == "${cur_bp:16:16}" ]]; then
    local fixed_bp="${cur_bp:0:16}"
    local tmp_c
    tmp_c="$(mktemp)"
    jq --arg bp "$fixed_bp" '.base_path = $bp' "$CONFIG_FILE" > "$tmp_c"
    write_file_atomically "$tmp_c" "$CONFIG_FILE"
    rm -f "$tmp_c"
  fi

  if [[ ! -f "$TRAFFIC_DB" ]]; then
    echo "{}" > "$TRAFFIC_DB"
    chmod 0600 "$TRAFFIC_DB"
  fi

  if [[ ! -f "$PROFILES_FILE" ]]; then
    local legacy_secret=""
    if [[ -f "$MTPROXY_ENV" ]]; then
      legacy_secret=$(sed -n 's/^MTPROXY_SECRET=\([0-9a-fA-F]\{32\}\).*/\1/p' "$MTPROXY_ENV" 2>/dev/null | head -n 1 || true)
    fi
    [[ -z "$legacy_secret" ]] && legacy_secret="$(openssl rand -hex 16)"

    local default_cm="${INITIAL_CARRIER_MODE:-https}"

    cat > "$PROFILES_FILE" <<EOF
{
  "profiles": [
    {
      "name": "default",
      "secret": "${legacy_secret}",
      "backend": "127.0.0.1:${BASE_BACKEND_PORT}",
      "carrier_mode": "${default_cm}"
    }
  ]
}
EOF
  fi

  local tmp_prof tmp_db
  tmp_prof="$(mktemp)"
  tmp_db="$(mktemp)"
  python3 - "$PROFILES_FILE" "$TRAFFIC_DB" "$BASE_BACKEND_PORT" "$(date +%Y-%m-%d)" "$tmp_prof" "$tmp_db" <<'PY'
import json, sys

prof_path, db_path, base_port, today, out_prof, out_db = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
)

with open(prof_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

try:
    with open(db_path, 'r', encoding='utf-8') as f:
        db = json.load(f)
except Exception:
    db = {}

raw_profiles = data.get("profiles", [])
used_ports = set()

for p in raw_profiles:
    b = p.get("backend", "")
    if ":" in b:
        try:
            port = int(b.rsplit(":", 1)[1])
            if port not in used_ports and port >= base_port:
                used_ports.add(port)
                continue
        except ValueError:
            pass
    p["backend"] = ""

valid_modes = {"https", "https-lanes", "websocket", "websocket-lanes"}

next_port = base_port
clean_profiles = []
for p in raw_profiles:
    name = p.get("name", "default")
    backend = p.get("backend", "")
    if not backend:
        while next_port in used_ports:
            next_port += 1
        backend = f"127.0.0.1:{next_port}"
        used_ports.add(next_port)

    created = p.get("created_at") or db.get(name, {}).get("created_at") or today
    db.setdefault(name, {"rx": 0, "tx": 0})
    db[name]["created_at"] = created

    cm = p.get("carrier_mode") or "https"
    if cm not in valid_modes:
        cm = "https"

    clean_profiles.append({
        "name": name,
        "secret": p.get("secret", ""),
        "backend": backend,
        "carrier_mode": cm
    })

with open(out_prof, 'w', encoding='utf-8') as f:
    json.dump({"profiles": clean_profiles}, f, indent=2, ensure_ascii=False)

with open(out_db, 'w', encoding='utf-8') as f:
    json.dump(db, f, indent=2, ensure_ascii=False)
PY
  write_file_atomically "$tmp_prof" "$PROFILES_FILE"
  write_file_atomically "$tmp_db" "$TRAFFIC_DB"
  rm -f "$tmp_prof" "$tmp_db"

  chown root:tproxy "$PROFILES_FILE" 2>/dev/null || chown root:root "$PROFILES_FILE"
  chmod 0400 "$PROFILES_FILE"
  chmod 0600 "$TRAFFIC_DB"
}

# Сохранение текущих счетчиков nftables в базу перед перезагрузкой правил
save_nft_traffic_to_db() {
  [[ -f "$PROFILES_FILE" ]] || return 0
  [[ -f "$TRAFFIC_DB" ]] || echo "{}" > "$TRAFFIC_DB"

  local nft_json=""
  nft_json="$(nft -j list table inet "$NFT_TABLE" 2>/dev/null || true)"
  [[ -z "$nft_json" ]] && return 0

  local tmp_db
  tmp_db="$(mktemp)"
  python3 - "$TRAFFIC_DB" "$nft_json" > "$tmp_db" <<'PY'
import json, sys

db_file, nft_raw = sys.argv[1], sys.argv[2]
try:
    with open(db_file, 'r') as f:
        db = json.load(f)
except Exception:
    db = {}

try:
    nft_data = json.loads(nft_raw).get("nftables", [])
except Exception:
    nft_data = []

for item in nft_data:
    rule = item.get("rule")
    if not rule:
        continue
    comment = rule.get("comment", "")
    exprs = rule.get("expr", [])
    bytes_val = sum(int(e["counter"].get("bytes", 0)) for e in exprs if "counter" in e)
    if comment.startswith("tx_"):
        name = comment[3:]
        db.setdefault(name, {"rx": 0, "tx": 0})
        db[name]["tx"] = int(db[name].get("tx", 0)) + bytes_val
    elif comment.startswith("rx_"):
        name = comment[3:]
        db.setdefault(name, {"rx": 0, "tx": 0})
        db[name]["rx"] = int(db[name].get("rx", 0)) + bytes_val

print(json.dumps(db, indent=2))
PY
  write_file_atomically "$tmp_db" "$TRAFFIC_DB"
  rm -f "$tmp_db"
}

# Настройка счетчиков nftables на loopback для каждого профиля
setup_nft_counters() {
  command -v nft >/dev/null 2>&1 || return 0
  save_nft_traffic_to_db

  nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  nft add table inet "$NFT_TABLE"
  nft add chain inet "$NFT_TABLE" local_acct '{ type filter hook output priority 0; policy accept; }'

  local count
  count=$(jq '.profiles | length' "$PROFILES_FILE" 2>/dev/null || echo 0)
  for (( i=0; i<count; i++ )); do
    local name backend port
    name=$(jq -r ".profiles[$i].name" "$PROFILES_FILE")
    backend=$(jq -r ".profiles[$i].backend" "$PROFILES_FILE")
    port="${backend##*:}"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      nft add rule inet "$NFT_TABLE" local_acct oifname "lo" tcp dport "$port" counter comment "\"tx_${name}\""
      nft add rule inet "$NFT_TABLE" local_acct oifname "lo" tcp sport "$port" counter comment "\"rx_${name}\""
    fi
  done
}

# Возвращает: rx_bytes tx_bytes total_bytes active_conns created_at
get_profile_metrics() {
  local name="$1" port="$2"
  local nft_json=""
  if [[ ${NFT_SNAPSHOT_CACHE+x} ]]; then
    nft_json="$NFT_SNAPSHOT_CACHE"
  else
    nft_json="$(nft -j list table inet "$NFT_TABLE" 2>/dev/null || true)"
  fi

  local active_conns=0
  if command -v ss >/dev/null 2>&1 && [[ "$port" =~ ^[0-9]+$ ]]; then
    active_conns=$(ss -Htan state established "( dport = :$port )" 2>/dev/null | wc -l || echo 0)
  fi

  python3 - "$TRAFFIC_DB" "$name" "$nft_json" "$active_conns" <<'PY'
import json, sys

db_file, name, nft_raw, conns = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    with open(db_file, 'r') as f:
        db = json.load(f)
except Exception:
    db = {}

entry = db.get(name, {})
rx = int(entry.get("rx", 0))
tx = int(entry.get("tx", 0))
created = entry.get("created_at", "-")

if nft_raw:
    try:
        for item in json.loads(nft_raw).get("nftables", []):
            rule = item.get("rule")
            if not rule:
                continue
            c = rule.get("comment", "")
            b = sum(int(e["counter"].get("bytes", 0)) for e in rule.get("expr", []) if "counter" in e)
            if c == f"rx_{name}":
                rx += b
            elif c == f"tx_{name}":
                tx += b
    except Exception:
        pass

print(f"{rx} {tx} {rx + tx} {conns} {created}")
PY
}

reset_user_traffic() {
  local target_name="$1"
  save_nft_traffic_to_db
  if [[ -f "$TRAFFIC_DB" ]]; then
    local tmp_db
    tmp_db="$(mktemp)"
    jq --arg n "$target_name" '.[$n].rx = 0 | .[$n].tx = 0' "$TRAFFIC_DB" > "$tmp_db"
    write_file_atomically "$tmp_db" "$TRAFFIC_DB"
    rm -f "$tmp_db"
  fi
  setup_nft_counters
}

# Чтение сырой статистики MTProxy с 127.0.0.1:8888
fetch_mtproxy_stats() {
  python3 - <<'PY'
import socket
try:
    with socket.create_connection(("127.0.0.1", 8888), timeout=2.0) as s:
        s.sendall(b"GET /stats HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
    text = data.decode("utf-8", errors="replace")
    if "\r\n\r\n" in text:
        text = text.split("\r\n\r\n", 1)[1]
    lines = [line for line in text.splitlines() if line.strip()]
    print("\n".join(lines[:18]) if lines else ("No data from port 8888" if __import__("os").environ.get("PROXY_LANG") == "en" else "Нет данных от порта 8888"))
except Exception as e:
    print((f"Statistics port 127.0.0.1:8888 is not responding ({e})" if __import__("os").environ.get("PROXY_LANG") == "en" else f"Порт статистики 127.0.0.1:8888 не отвечает ({e})"))
PY
}

# Полная синхронизация profiles.json -> mtproxy + systemd + nftables
sync_and_restart_services() {
  ensure_profiles_structure

  local secrets_list=()
  local ports_list=()
  mapfile -t secrets_list < <(jq -r '.profiles[].secret // empty' "$PROFILES_FILE" 2>/dev/null)
  mapfile -t ports_list < <(jq -r '.profiles[].backend // empty' "$PROFILES_FILE" 2>/dev/null | awk -F: '{print $NF}')

  if [[ ${#secrets_list[@]} -gt 0 && -f "$MTPROXY_ENV" ]]; then
    local first_secret="${secrets_list[0]}"
    local secret_args=""
    for s in "${secrets_list[@]}"; do
      secret_args+="-S ${s} "
    done
    secret_args="${secret_args% }"

    local ports_csv
    ports_csv="$(IFS=,; echo "${ports_list[*]}")"
    [[ -z "$ports_csv" ]] && ports_csv="$BASE_BACKEND_PORT"

    if grep -q "^MTPROXY_SECRET=" "$MTPROXY_ENV"; then
      sed -i "s|^MTPROXY_SECRET=.*|MTPROXY_SECRET=${first_secret}|" "$MTPROXY_ENV"
    else
      echo "MTPROXY_SECRET=${first_secret}" >> "$MTPROXY_ENV"
    fi

    mkdir -p /etc/systemd/system/mtproxy.service.d
    cat > /etc/systemd/system/mtproxy.service.d/multi-profile.conf <<EOF
[Service]
ExecStart=
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u nobody -p 8888 -H ${ports_csv} ${secret_args} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M \${MTPROXY_WORKERS} -C \${MTPROXY_MAX_CONNECTIONS} \$MTPROXY_NAT_ARGS
EOF
    rm -f /etc/systemd/system/mtproxy.service.d/multi-secret.conf
  fi

  if [[ -f /etc/systemd/system/tproxy-server.service ]] && ! grep -q "profiles.json" /etc/systemd/system/tproxy-server.service; then
    mkdir -p /etc/systemd/system/tproxy-server.service.d
    cat > /etc/systemd/system/tproxy-server.service.d/profiles.conf <<EOF
[Service]
LoadCredential=profiles.json:${PROFILES_FILE}
ExecStart=
ExecStart=/usr/local/bin/tproxy-server -config ${CONFIG_FILE} -profiles-file %d/profiles.json
EOF
  fi

  if [[ -x "/usr/local/bin/tproxy-server" ]]; then
    if ! /usr/local/bin/tproxy-server -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check >/dev/null 2>&1; then
      yellow "$(tr_text "Внимание: проверка tproxy-server -check выявила предупреждение:" "Warning: tproxy-server -check reported a warning:")"
      /usr/local/bin/tproxy-server -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check || true
    fi
  fi

  setup_nft_counters

  systemctl daemon-reload
  systemctl reset-failed tproxy-server mtproxy 2>/dev/null || true
  systemctl restart mtproxy 2>/dev/null || true
  systemctl restart tproxy-server 2>/dev/null || true
  sleep 1
}

# ==============================================================================
# ВЫВОД ТАБЛИЦЫ ПОЛЬЗОВАТЕЛЕЙ, ТРАФИКА И ССЫЛОК
# ==============================================================================

build_user_link() {
  local hex_secret="$1"
  local host="${2:-$(get_hostname)}"
  local base_path
  base_path="$(get_base_path)"
  local server_encoded="$host"
  [[ -n "$base_path" ]] && server_encoded="${host}%2F${base_path}"
  local client_sec
  client_sec="$(derive_web_secret "$hex_secret" "$base_path")"
  printf 'https://t.me/webproxy?server=%s&secret=%s' "$server_encoded" "$client_sec"
}

print_proxy_info() {
  local host="${1:-$(get_hostname)}"
  [[ -f "$CONFIG_FILE" ]] || die "$(tr_text "Файл конфигурации $CONFIG_FILE не найден. Сначала выполните установку." "Configuration file $CONFIG_FILE not found. Run the installer first.")"
  ensure_profiles_structure
  setup_nft_counters 2>/dev/null || true
  begin_metrics_snapshot
  load_profile_rows

  local base_path
  base_path="$(get_base_path)"
  [[ -z "$host" ]] && host="$(tr_text "<ТВОЙ_ДОМЕН>" "<YOUR_DOMAIN>")"

  printf '\n'
  hr
  printf "$(tr_text " \033[1mДомен:\033[0m %-24s \033[1mSlug:\033[0m \033[33m%s\033[0m\n" " \033[1mDomain:\033[0m %-24s \033[1mSlug:\033[0m \033[33m%s\033[0m\n")" "$host" "${base_path:+/$base_path}${base_path:-$(tr_text "/ (корень)" "/ (root)")}"
  hr
  printf " \033[1m%-3s %-15s %-16s %-18s %-11s %-11s %-11s\033[0m\n" "#" "KEY NAME" "MODE" "$(tr_text "ONLINE (1-6п=1ч)" "ONLINE (1-6=1)")" "RX (DOWN)" "TX (UP)" "TOTAL"
  hr

  local count
  count=${#PROFILE_ROWS[@]}
  for (( i=0; i<count; i++ )); do
    local p_name p_mode p_backend p_port rx tx tot conns created u_est
    IFS=$'\x1f' read -r p_name p_hex p_mode p_backend <<< "${PROFILE_ROWS[$i]}"
    p_port="${p_backend##*:}"

    read -r rx tx tot conns created < <(get_profile_metrics "$p_name" "$p_port")
    local rx_h tx_h tot_h online_str
    rx_h="$(format_bytes "$rx")"
    tx_h="$(format_bytes "$tx")"
    tot_h="$(format_bytes "$tot")"
    u_est="$(calc_users_from_conns "$conns")"

    printf " \033[1;36m%-3s\033[0m %-15s %-16s " "$((i+1))" "${p_name:0:14}" "$p_mode"
    if (( conns > 0 )); then
      online_str="$(tr_text "~${u_est} чел (${conns} пот)" "~${u_est} users (${conns} streams)")"
      printf "\033[32m%-24s\033[0m " "$online_str"
    else
      printf "\033[90m%-18s\033[0m " "0"
    fi
    printf "%-11s %-11s \033[1;33m%-11s\033[0m\n" "$rx_h" "$tx_h" "$tot_h"
  done
  hr

  printf '\n'
  bold "$(tr_text " Ссылки подключения:" " Connection links:")"
  for (( i=0; i<count; i++ )); do
    local p_name p_hex p_mode tg_link
    IFS=$'\x1f' read -r p_name p_hex p_mode _ <<< "${PROFILE_ROWS[$i]}"
    tg_link="$(build_user_link "$p_hex" "$host")"
    printf "  \033[1;36m[%d] %-14s\033[0m \033[90m(%s)\033[0m \033[32m%s\033[0m\n" "$((i+1))" "$p_name" "$p_mode" "$tg_link"
  done
  printf '\n'
  end_metrics_snapshot
}

# ==============================================================================
# БЫСТРЫЕ ОПЕРАЦИИ С КЛЮЧАМИ, ТРАНСПОРТОМ И ПОЛЬЗОВАТЕЛЯМИ
# ==============================================================================

quick_create_user() {
  ensure_profiles_structure
  local name="${1:-}"
  local carrier_mode="${2:-}"

  if [[ -z "$name" ]]; then
    printf '\n'
    cyan "$(tr_text "--- Создание нового ключа ---" "--- Create a new key ---")"
    ask "$(tr_text "Имя ключа (латиница/цифры, например: iphone, ivan): " "Key name (Latin letters/digits, e.g. iphone, ivan): ")" name
  fi

  name="${name//[^a-zA-Z0-9_-]/}"
  if [[ -z "$name" ]]; then
    red "$(tr_text "Имя не может быть пустым." "Name cannot be empty.")"
    return 1
  fi

  if jq -e --arg n "$name" '.profiles[] | select(.name == $n)' "$PROFILES_FILE" >/dev/null 2>&1; then
    red "$(tr_text "Ключ '$name' уже существует!" "Key '$name' already exists!")"
    return 1
  fi

  if [[ -n "$carrier_mode" ]]; then
    local norm_m
    norm_m="$(normalize_carrier_mode "$carrier_mode")"
    if [[ -z "$norm_m" ]]; then
      red "$(tr_text "Некорректный режим '$carrier_mode'. Допустимые: https, https-lanes, websocket, websocket-lanes." "Invalid mode '$carrier_mode'. Supported: https, https-lanes, websocket, websocket-lanes.")"
      return 1
    fi
    carrier_mode="$norm_m"
  else
    prompt_carrier_mode "websocket-lanes" carrier_mode
  fi

  local new_hex tmp_prof
  new_hex="$(openssl rand -hex 16)"

  tmp_prof="$(mktemp)"
  jq --arg name "$name" --arg sec "$new_hex" --arg mode "$carrier_mode" \
    '.profiles += [{"name": $name, "secret": $sec, "backend": "", "carrier_mode": $mode}]' \
    "$PROFILES_FILE" > "$tmp_prof"
  write_file_atomically "$tmp_prof" "$PROFILES_FILE"
  rm -f "$tmp_prof"

  sync_and_restart_services

  local tg_link
  tg_link="$(build_user_link "$new_hex")"

  printf '\n'
  green "$(tr_text "Ключ '$name' создан (режим: $carrier_mode):" "Key '$name' created (mode: $carrier_mode):")"
  printf "\033[1;32m%s\033[0m\n\n" "$tg_link"
}

quick_delete_user() {
  ensure_profiles_structure
  local target="${1:-}"
  local count
  count=$(jq '.profiles | length' "$PROFILES_FILE")

  if (( count <= 1 )); then
    red "$(tr_text "Нельзя удалить единственный ключ (должен остаться минимум 1)." "Cannot delete the only key (at least one must remain).")"
    return 1
  fi

  if [[ -z "$target" ]]; then
    ask "$(tr_text "Номер или имя ключа для удаления: " "Number or name of key to delete: ")" target
  fi
  [[ -z "$target" ]] && return 0

  local del_idx=-1 del_name=""
  if [[ "$target" =~ ^[0-9]+$ ]] && (( target >= 1 && target <= count )); then
    del_idx=$((target - 1))
    del_name=$(jq -r ".profiles[$del_idx].name" "$PROFILES_FILE")
  else
    for (( i=0; i<count; i++ )); do
      local n
      n=$(jq -r ".profiles[$i].name" "$PROFILES_FILE")
      if [[ "$n" == "$target" ]]; then
        del_idx=$i
        del_name="$n"
        break
      fi
    done
  fi

  if (( del_idx < 0 )); then
    red "$(tr_text "Ключ '$target' не найден." "Key '$target' not found.")"
    return 1
  fi

  if ! confirm_danger "$(tr_text "Ключ '$del_name' будет удален, а его ссылка перестанет работать." "Key '$del_name' will be deleted and its link will stop working.")"; then
    return 0
  fi

  local tmp_prof
  tmp_prof="$(mktemp)"
  jq "del(.profiles[$del_idx])" "$PROFILES_FILE" > "$tmp_prof"
  write_file_atomically "$tmp_prof" "$PROFILES_FILE"
  rm -f "$tmp_prof"

  sync_and_restart_services
  green "$(tr_text "Ключ '$del_name' удален." "Key '$del_name' deleted.")"
}

rotate_single_user_secret() {
  local idx="$1"
  local u_name new_hex tmp_prof
  u_name=$(jq -r ".profiles[$idx].name" "$PROFILES_FILE")

  if ! confirm_danger "$(tr_text "Секрет для ключа '$u_name' будет изменен (старая ссылка этого пользователя перестанет работать)." "The secret for key '$u_name' will change (its old link will stop working).")"; then
    return 0
  fi

  new_hex="$(openssl rand -hex 16)"

  tmp_prof="$(mktemp)"
  jq --arg idx "$idx" --arg sec "$new_hex" '.profiles[$idx|tonumber].secret = $sec' "$PROFILES_FILE" > "$tmp_prof"
  write_file_atomically "$tmp_prof" "$PROFILES_FILE"
  rm -f "$tmp_prof"

  sync_and_restart_services
  green "$(tr_text "Секрет для '$u_name' обновлен!" "Secret for '$u_name' updated!")"
  printf "$(tr_text "Новая ссылка: \033[1;32m%s\033[0m\n" "New link: \033[1;32m%s\033[0m\n")" "$(build_user_link "$new_hex")"
}

# Выбор любого из 4 режимов транспорта для конкретного ключа (по индексу 0..N-1)
change_single_user_mode() {
  local idx="$1"
  local preset_mode="${2:-}"
  local cur_mode new_mode u_name tmp_prof

  u_name=$(jq -r ".profiles[$idx].name" "$PROFILES_FILE")
  cur_mode=$(jq -r ".profiles[$idx].carrier_mode // \"https\"" "$PROFILES_FILE")

  if [[ -n "$preset_mode" ]]; then
    new_mode="$(normalize_carrier_mode "$preset_mode")"
    if [[ -z "$new_mode" ]]; then
      red "$(tr_text "Некорректный режим: '$preset_mode'. Допустимые: https, https-lanes, websocket, websocket-lanes." "Invalid mode: '$preset_mode'. Supported: https, https-lanes, websocket, websocket-lanes.")"
      return 1
    fi
  else
    printf "$(tr_text "\nТекущий транспорт для ключа \033[1m%s\033[0m: \033[1;33m%s\033[0m\n" "\nCurrent transport for key \033[1m%s\033[0m: \033[1;33m%s\033[0m\n")" "$u_name" "$cur_mode"
    prompt_carrier_mode "$cur_mode" new_mode
  fi

  if [[ "$new_mode" == "$cur_mode" ]]; then
    yellow "$(tr_text "Режим для '$u_name' не изменился ($cur_mode)." "Mode for '$u_name' is unchanged ($cur_mode).")"
    return 0
  fi

  tmp_prof="$(mktemp)"
  jq --arg idx "$idx" --arg m "$new_mode" '.profiles[$idx|tonumber].carrier_mode = $m' "$PROFILES_FILE" > "$tmp_prof"
  write_file_atomically "$tmp_prof" "$PROFILES_FILE"
  rm -f "$tmp_prof"

  sync_and_restart_services
  green "$(tr_text "Транспорт ключа '$u_name' успешно изменен: $cur_mode -> $new_mode (ссылка осталась прежней)" "Transport for '$u_name' changed: $cur_mode -> $new_mode (the link remains the same)")"
}

# Смена режима транспорта по номеру/имени ключа или сразу для всех (all)
quick_change_mode() {
  ensure_profiles_structure
  local target="${1:-}"
  local desired_mode="${2:-}"
  local count
  count=$(jq '.profiles | length' "$PROFILES_FILE")

  if [[ -z "$target" ]]; then
    print_proxy_info
    ask "$(tr_text "Введи номер/имя ключа (или 'all' для всех ключей сразу): " "Enter key number/name (or 'all' for all keys): ")" target
  fi
  [[ -z "$target" ]] && return 0

  if [[ "${target,,}" == "all" || "${target,,}" == "*" || "${target,,}" == "все" ]]; then
    local new_mode=""
    if [[ -n "$desired_mode" ]]; then
      new_mode="$(normalize_carrier_mode "$desired_mode")"
      [[ -z "$new_mode" ]] && { red "$(tr_text "Некорректный режим '$desired_mode'." "Invalid mode '$desired_mode'.")"; return 1; }
    else
      prompt_carrier_mode "websocket-lanes" new_mode
    fi

    local tmp_prof
    tmp_prof="$(mktemp)"
    jq --arg m "$new_mode" '.profiles |= map(.carrier_mode = $m)' "$PROFILES_FILE" > "$tmp_prof"
    write_file_atomically "$tmp_prof" "$PROFILES_FILE"
    rm -f "$tmp_prof"

    sync_and_restart_services
    green "$(tr_text "Для ВСЕХ ключей ($count шт.) установлен транспорт: $new_mode" "Transport set for ALL keys ($count): $new_mode")"
    return 0
  fi

  local target_idx=-1
  if [[ "$target" =~ ^[0-9]+$ ]] && (( target >= 1 && target <= count )); then
    target_idx=$((target - 1))
  else
    for (( i=0; i<count; i++ )); do
      local n
      n=$(jq -r ".profiles[$i].name" "$PROFILES_FILE")
      if [[ "$n" == "$target" ]]; then
        target_idx=$i
        break
      fi
    done
  fi

  if (( target_idx < 0 )); then
    red "$(tr_text "Ключ '$target' не найден." "Key '$target' not found.")"
    return 1
  fi

  change_single_user_mode "$target_idx" "$desired_mode"
}

user_detail_menu() {
  local idx="$1"
  while true; do
    clear 2>/dev/null || true
    local count
    count=$(jq '.profiles | length' "$PROFILES_FILE")
    (( idx >= count )) && return 0

    local u_name u_hex u_mode u_backend u_port base_path client_sec tg_link rx tx tot conns u_date u_est
    u_name=$(jq -r ".profiles[$idx].name" "$PROFILES_FILE")
    u_hex=$(jq -r ".profiles[$idx].secret" "$PROFILES_FILE")
    u_mode=$(jq -r ".profiles[$idx].carrier_mode // \"https\"" "$PROFILES_FILE")
    u_backend=$(jq -r ".profiles[$idx].backend" "$PROFILES_FILE")
    u_port="${u_backend##*:}"
    base_path="$(get_base_path)"
    client_sec="$(derive_web_secret "$u_hex" "$base_path")"
    tg_link="$(build_user_link "$u_hex")"

    read -r rx tx tot conns u_date < <(get_profile_metrics "$u_name" "$u_port")
    u_est="$(calc_users_from_conns "$conns")"

    header_box "$(tr_text "ПРОФИЛЬ КЛЮЧА: $u_name (#$((idx+1)))" "KEY PROFILE: $u_name (#$((idx+1)))")"
    printf "$(tr_text "  Создан:          %s\n" "  Created:          %s\n")" "$u_date"
    printf "$(tr_text "  Режим (carrier): \033[1;32m%s\033[0m\n" "  Mode (carrier): \033[1;32m%s\033[0m\n")" "$u_mode"
    printf "  Backend:         %s\n" "$u_backend"
    if (( conns > 0 )); then
      printf "$(tr_text "  Онлайн сейчас:   \033[1;32m~%s чел.\033[0m (%s TCP-потоков, норма 1-6 на устройство)\n" "  Online now:   \033[1;32m~%s users\033[0m (%s TCP streams, typically 1-6 per device)\n")" "$u_est" "$conns"
    else
      printf "$(tr_text "  Онлайн сейчас:   \033[90m0 (оффлайн)\033[0m\n" "  Online now:   \033[90m0 (offline)\033[0m\n")"
    fi
    hr
    printf "$(tr_text "  Скачано (RX):    %s\n" "  Downloaded (RX):    %s\n")" "$(format_bytes "$rx")"
    printf "$(tr_text "  Отдано (TX):     %s\n" "  Uploaded (TX):     %s\n")" "$(format_bytes "$tx")"
    printf "$(tr_text "  Всего:           \033[1;33m%s\033[0m\n" "  Total:           \033[1;33m%s\033[0m\n")" "$(format_bytes "$tot")"
    hr
    printf "$(tr_text "  HEX-ключ:        %s\n" "  HEX key:        %s\n")" "$u_hex"
    printf "$(tr_text "  Web-секрет:      %s\n" "  Web secret:      %s\n")" "$client_sec"
    printf "$(tr_text "  Ссылка ТГ:       \033[1;32m%s\033[0m\n" "  Telegram link:       \033[1;32m%s\033[0m\n")" "$tg_link"
    hr
    printf "$(tr_text "  [M] Сменить транспорт (https / https-lanes / websocket / websocket-lanes)\n" "  [M] Change transport (https / https-lanes / websocket / websocket-lanes)\n")"
    printf "$(tr_text "  [R] Перевыпустить секрет   [Z] Обнулить трафик   [D] Удалить   [0] Назад\n\n" "  [R] Regenerate secret   [Z] Reset traffic   [D] Delete   [0] Back\n\n")"

    local act=""
    ask "$(tr_text "Выбор [M/R/Z/D/0]: " "Choice [M/R/Z/D/0]: ")" act
    case "${act,,}" in
      m) change_single_user_mode "$idx"; pause_menu ;;
      r) rotate_single_user_secret "$idx"; pause_menu ;;
      z)
        if confirm_danger "$(tr_text "Обнулить статистику трафика для ключа '$u_name'?" "Reset traffic statistics for key '$u_name'?")"; then
          reset_user_traffic "$u_name"
          green "$(tr_text "Трафик для '$u_name' обнулен." "Traffic for '$u_name' reset.")"
          sleep 1
        fi
        ;;
      d)
        quick_delete_user "$((idx+1))"
        pause_menu
        return 0
        ;;
      0|q|"") return 0 ;;
    esac
  done
}

users_manager_menu() {
  while true; do
    clear 2>/dev/null || true
    print_proxy_info

    printf "$(tr_text "  \033[1;36m[1..N]\033[0m Карточка ключа   \033[1;32m[A]\033[0m Создать   \033[1;35m[M]\033[0m Сменить режим   \033[1;31m[D]\033[0m Удалить   \033[1;33m[U]\033[0m Обновить   \033[1m[0]\033[0m Назад\n\n" "  \033[1;36m[1..N]\033[0m Key details   \033[1;32m[A]\033[0m Create   \033[1;35m[M]\033[0m Change mode   \033[1;31m[D]\033[0m Delete   \033[1;33m[U]\033[0m Refresh   \033[1m[0]\033[0m Back\n\n")"

    local cmd=""
    ask "$(tr_text "Выбор: " "Choice: ")" cmd
    case "${cmd,,}" in
      a|add|+) quick_create_user || true; pause_menu ;;
      m|mode) quick_change_mode || true; pause_menu ;;
      d|del|-) quick_delete_user || true; pause_menu ;;
      u|r) continue ;;
      0|q|"") return 0 ;;
      *)
        local count
        count=$(jq '.profiles | length' "$PROFILES_FILE")
        if [[ "$cmd" =~ ^[0-9]+$ ]] && (( cmd >= 1 && cmd <= count )); then
          user_detail_menu "$((cmd - 1))"
        else
          red "$(tr_text "Некорректный ввод." "Invalid input.")"
          sleep 1
        fi
        ;;
    esac
  done
}

# ==============================================================================
# ГИБКАЯ РОТАЦИЯ СЕКРЕТОВ И ПУТЕЙ (--rotate и интерактивный мастер)
# ==============================================================================

rotate_proxy() {
  local mode="${1:-all}"
  local skip_confirm="${2:-no}"
  [[ -f "$CONFIG_FILE" ]] || die "$(tr_text "Конфиг $CONFIG_FILE не найден." "Configuration $CONFIG_FILE not found.")"
  ensure_profiles_structure

  if [[ "$skip_confirm" != "force" ]]; then
    local msg=""
    case "$mode" in
      all)     msg="$(tr_text "Будет сгенерирован НОВЫЙ путь (base_path) и НОВЫЕ секреты для ВСЕХ пользователей! Все старые ссылки перестанут работать." "A NEW base path and NEW secrets will be generated for ALL users! All old links will stop working.")" ;;
      secrets) msg="$(tr_text "Будут сброшены и перевыпущены секреты для ВСЕХ пользователей! Все старые ссылки перестанут работать." "Secrets for ALL users will be regenerated! All old links will stop working.")" ;;
      path)    msg="$(tr_text "Будет изменен секретный путь (base_path)! Все старые ссылки потребуют обновления." "The secret base path will change! All old links must be updated.")" ;;
    esac
    if ! confirm_danger "$msg"; then
      return 0
    fi
  fi

  if [[ "$mode" == "all" || "$mode" == "path" ]]; then
    local new_slug tmp_cfg
    new_slug="$(generate_base_path_slug)"
    tmp_cfg="$(mktemp)"
    jq --arg bp "$new_slug" '.base_path = $bp' "$CONFIG_FILE" > "$tmp_cfg"
    write_file_atomically "$tmp_cfg" "$CONFIG_FILE"
    rm -f "$tmp_cfg"
    green "$(tr_text "Новый секретный путь (base_path): /$new_slug" "New secret path (base_path): /$new_slug")"
  fi

  if [[ "$mode" == "all" || "$mode" == "secrets" ]]; then
    local count tmp_prof
    count=$(jq '.profiles | length' "$PROFILES_FILE")
    tmp_prof="$(mktemp)"
    cp "$PROFILES_FILE" "$tmp_prof"
    for (( i=0; i<count; i++ )); do
      local new_hex
      new_hex="$(openssl rand -hex 16)"
      jq --arg idx "$i" --arg sec "$new_hex" '.profiles[$idx|tonumber].secret = $sec' "$tmp_prof" > "${tmp_prof}.new"
      mv "${tmp_prof}.new" "$tmp_prof"
    done
    write_file_atomically "$tmp_prof" "$PROFILES_FILE"
    rm -f "$tmp_prof"
    chmod 0400 "$PROFILES_FILE"
    green "$(tr_text "Сгенерированы новые секреты для всех ключей." "New secrets generated for all keys.")"
  fi

  yellow "$(tr_text "Перезапуск сервисов..." "Restarting services...")"
  sync_and_restart_services
  green "$(tr_text "Ротация выполнена!" "Rotation complete!")"
  print_proxy_info
}

secrets_and_rotation_menu() {
  while true; do
    clear 2>/dev/null || true
    local bp
    bp="$(get_base_path)"
    header_box "$(tr_text "УПРАВЛЕНИЕ СЕКРЕТАМИ И ПУТЯМИ (BASE_PATH)" "SECRETS AND PATHS (BASE_PATH)")"
    printf "$(tr_text "  Текущий путь: \033[1;33m%s\033[0m\n" "  Current path: \033[1;33m%s\033[0m\n")" "${bp:+/$bp}${bp:-$(tr_text "/ (корень сайта)" "/ (root)")}"
    hr
    printf "$(tr_text "  1) Сменить секрет одному ключу\n" "  1) Change one key's secret\n")"
    printf "$(tr_text "  2) Сменить секреты всем ключам (сохранить путь)\n" "  2) Change all secrets (keep path)\n")"
    printf "$(tr_text "  3) Сгенерировать новый случайный путь (16 симв.)\n" "  3) Generate a random path (16 characters)\n")"
    printf "$(tr_text "  4) Задать свой путь вручную\n" "  4) Set a custom path\n")"
    printf "$(tr_text "  5) Полная ротация (новый путь + все секреты)\n" "  5) Full rotation (new path + all secrets)\n")"
    printf "$(tr_text "  0) Назад\n\n" "  0) Back\n\n")"

    local ch=""
    ask "$(tr_text "Выбор [0-5]: " "Choice [0-5]: ")" ch
    case "$ch" in
      1)
        printf '\n'
        local count
        count=$(jq '.profiles | length' "$PROFILES_FILE")
        for (( i=0; i<count; i++ )); do
          printf "  [%d] %s\n" "$((i+1))" "$(jq -r ".profiles[$i].name" "$PROFILES_FILE")"
        done
        local u_idx=""
        ask "$(tr_text "Номер ключа: " "Key number: ")" u_idx
        if [[ "$u_idx" =~ ^[0-9]+$ ]] && (( u_idx >= 1 && u_idx <= count )); then
          rotate_single_user_secret "$((u_idx - 1))"
        else
          red "$(tr_text "Неверный номер." "Invalid number.")"
        fi
        pause_menu
        ;;
      2) rotate_proxy "secrets"; pause_menu ;;
      3) rotate_proxy "path"; pause_menu ;;
      4)
        printf '\n'
        local new_bp=""
        ask "$(tr_text "Новый путь без слешей (пусто = корень /): " "New path without slashes (empty = root /): ")" new_bp
        new_bp="${new_bp#/}"
        new_bp="${new_bp%/}"
        if confirm_danger "$(tr_text "Сменить base_path на '${new_bp:-/ (корень)}'? Все клиентские ссылки изменятся." "Change base_path to '${new_bp:-/ (root)}'? All client links will change.")"; then
          local tmp_cfg
          tmp_cfg="$(mktemp)"
          jq --arg bp "$new_bp" '.base_path = $bp' "$CONFIG_FILE" > "$tmp_cfg"
          write_file_atomically "$tmp_cfg" "$CONFIG_FILE"
          rm -f "$tmp_cfg"
          sync_and_restart_services
          green "$(tr_text "Путь обновлен!" "Path updated!")"
          print_proxy_info
        fi
        pause_menu
        ;;
      5) rotate_proxy "all"; pause_menu ;;
      0|q|"") return 0 ;;
    esac
  done
}

# ==============================================================================
# ТЮНИНГ И ОБНОВЛЕНИЕ (--update)
# ==============================================================================

tune_limits_and_routes() {
  printf '\n'
  header_box "$(tr_text "ТЮНИНГ ЛИМИТОВ И МАРШРУТИЗАЦИИ" "LIMITS AND ROUTING SETTINGS")"
  local cur_routes cur_workers="1" cur_conns="4096"
  cur_routes=$(jq -r '.static_routes // "exact"' "$CONFIG_FILE" 2>/dev/null)
  if [[ -f "$MTPROXY_ENV" ]]; then
    cur_workers=$(sed -n 's/^MTPROXY_WORKERS=\([0-9]*\).*/\1/p' "$MTPROXY_ENV" | head -n 1)
    cur_conns=$(sed -n 's/^MTPROXY_MAX_CONNECTIONS=\([0-9]*\).*/\1/p' "$MTPROXY_ENV" | head -n 1)
    [[ -z "$cur_workers" ]] && cur_workers="1"
    [[ -z "$cur_conns" ]] && cur_conns="4096"
  fi

  printf "  • static_routes:           %s\n" "$cur_routes"
  printf "  • MTPROXY_WORKERS:         %s\n" "$cur_workers"
  printf "  • MTPROXY_MAX_CONNECTIONS: %s\n\n" "$cur_conns"

  local new_workers="" new_conns="" new_routes=""
  ask "$(tr_text "Воркеры MTProxy [Enter = $cur_workers]: " "MTProxy workers [Enter = $cur_workers]: ")" new_workers
  ask "$(tr_text "Макс. соединений [Enter = $cur_conns]: " "Max connections [Enter = $cur_conns]: ")" new_conns
  ask "$(tr_text "Режим статики (exact / legacy) [Enter = $cur_routes]: " "Static routing mode (exact / legacy) [Enter = $cur_routes]: ")" new_routes

  [[ -z "$new_workers" ]] && new_workers="$cur_workers"
  [[ -z "$new_conns" ]] && new_conns="$cur_conns"
  [[ -z "$new_routes" ]] && new_routes="$cur_routes"

  if [[ -f "$MTPROXY_ENV" ]]; then
    grep -q "^MTPROXY_WORKERS=" "$MTPROXY_ENV" \
      && sed -i "s/^MTPROXY_WORKERS=.*/MTPROXY_WORKERS=${new_workers}/" "$MTPROXY_ENV" \
      || echo "MTPROXY_WORKERS=${new_workers}" >> "$MTPROXY_ENV"

    grep -q "^MTPROXY_MAX_CONNECTIONS=" "$MTPROXY_ENV" \
      && sed -i "s/^MTPROXY_MAX_CONNECTIONS=.*/MTPROXY_MAX_CONNECTIONS=${new_conns}/" "$MTPROXY_ENV" \
      || echo "MTPROXY_MAX_CONNECTIONS=${new_conns}" >> "$MTPROXY_ENV"
  fi

  if [[ "$new_routes" == "exact" || "$new_routes" == "legacy" ]]; then
    local tmp_cfg
    tmp_cfg="$(mktemp)"
    jq --arg sr "$new_routes" '.static_routes = $sr' "$CONFIG_FILE" > "$tmp_cfg"
    write_file_atomically "$tmp_cfg" "$CONFIG_FILE"
    rm -f "$tmp_cfg"
  fi

  sync_and_restart_services
  green "$(tr_text "Настройки применены!" "Settings applied!")"
}

update_proxy() {
  printf '\n'
  header_box "$(tr_text "ОБНОВЛЕНИЕ ЯДРА TPROXY-SERVER" "UPDATE TPROXY-SERVER")"

  [[ -d "$INSTALL_DIR/.git" ]] || die "$(tr_text "Репозиторий в $INSTALL_DIR не найден." "Repository not found at $INSTALL_DIR.")"
  [[ -f "$CONFIG_FILE" ]] || die "$(tr_text "Конфиг $CONFIG_FILE не найден." "Configuration $CONFIG_FILE not found.")"

  ensure_profiles_structure
  save_nft_traffic_to_db

  local old_commit new_commit
  old_commit=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

  yellow "$(tr_text "Проверка обновлений telegramdesktop/tproxy-server..." "Checking telegramdesktop/tproxy-server for updates...")"
  git -C "$INSTALL_DIR" fetch --depth=1 origin
  git -C "$INSTALL_DIR" checkout -f FETCH_HEAD

  new_commit=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

  if [[ "$old_commit" == "$new_commit" ]]; then
    green "$(tr_text "Установлена актуальная версия ($new_commit)." "Already up to date ($new_commit).")"
  else
    cyan "$(tr_text "Обновление: $old_commit -> $new_commit" "Update: $old_commit -> $new_commit")"
  fi

  local bkp_dir="/tmp/tproxy_backup_$$"
  mkdir -p "$bkp_dir"
  cp -f "$CONFIG_FILE" "$bkp_dir/config.json"
  [[ -f "$PROFILES_FILE" ]] && cp -f "$PROFILES_FILE" "$bkp_dir/profiles.json"

  cd "$INSTALL_DIR"

  if [[ -f "./deploy/update-relay.sh" ]]; then
    bash ./deploy/update-relay.sh
  else
    local saved_host saved_bp saved_hex
    saved_host="$(get_hostname)"
    saved_bp="$(get_base_path)"
    saved_hex="$(openssl rand -hex 16)"
    ./deploy/install.sh \
      --hostname "$saved_host" \
      --email "admin@${saved_host}" \
      --site-dir "$SITE_DIR" \
      ${saved_bp:+--base-path "$saved_bp"} \
      --secret "$saved_hex"
  fi

  cp -f "$bkp_dir/config.json" "$CONFIG_FILE"
  if [[ -f "$bkp_dir/profiles.json" ]]; then
    cp -f "$bkp_dir/profiles.json" "$PROFILES_FILE"
    chmod 0400 "$PROFILES_FILE"
  fi
  rm -rf "$bkp_dir"

  sync_and_restart_services
  install_cli_command

  printf '\n'
  green "$(tr_text "Обновление завершено ($old_commit -> $new_commit)!" "Update complete ($old_commit -> $new_commit)!")"
  print_proxy_info
}

# ==============================================================================
# ГЛАВНАЯ ИНТЕРАКТИВНАЯ CLI-ПАНЕЛЬ (tg-proxy)
# ==============================================================================

service_badge() {
  local svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    printf '\033[32m● on\033[0m'
  else
    printf '\033[31m○ off\033[0m'
  fi
}

readyz_badge() {
  if curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
    printf '\033[32mOK\033[0m'
  else
    printf '\033[33mDOWN\033[0m'
  fi
}

run_panel() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    yellow "$(tr_text "Прокси еще не установлен. Запуск мастера установки..." "Proxy is not installed yet. Starting the installation wizard...")"
    install_proxy
    exit 0
  fi

  ensure_profiles_structure
  if ! systemctl is-active --quiet tproxy-server 2>/dev/null; then
    sync_and_restart_services
  else
    setup_nft_counters 2>/dev/null || true
  fi
  install_cli_command

  while true; do
    clear 2>/dev/null || true
    local host base_path prof_count git_ver sys_line total_all=0 active_conns_all=0 active_users_all=0
    host="$(get_hostname)"
    base_path="$(get_base_path)"
    load_profile_rows
    prof_count=${#PROFILE_ROWS[@]}
    git_ver=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "n/a")
    sys_line="$(get_system_metrics_line)"
    begin_metrics_snapshot

    for (( i=0; i<prof_count; i++ )); do
      local n b p rx tx tot c dt u_est row_secret row_mode
      IFS=$'\x1f' read -r n row_secret row_mode b <<< "${PROFILE_ROWS[$i]}"
      p="${b##*:}"
      read -r rx tx tot c dt < <(get_profile_metrics "$n" "$p")
      total_all=$((total_all + tot))
      active_conns_all=$((active_conns_all + c))
      u_est="$(calc_users_from_conns "$c")"
      active_users_all=$((active_users_all + u_est))
    done
    end_metrics_snapshot

    local online_summary="0"
    if (( active_conns_all > 0 )); then
      online_summary="$(tr_text "~${active_users_all} чел. (${active_conns_all} пот.)" "~${active_users_all} users (${active_conns_all} streams)")"
    fi

    header_box "$(tr_text "TG-PROXY — ПАНЕЛЬ УПРАВЛЕНИЯ (вызов: sudo proxy / sudo tg-proxy)" "TG-PROXY — CONTROL PANEL (sudo proxy / sudo tg-proxy)")"
    printf "$(tr_text "  Домен:    \033[1m%s\033[0m\n" "  Domain:    \033[1m%s\033[0m\n")" "${host:-$(tr_text "не найден" "not found")}"
    printf "$(tr_text "  Путь:     \033[33m%s\033[0m\n" "  Path:     \033[33m%s\033[0m\n")" "${base_path:+/$base_path}${base_path:-$(tr_text "/ (корень)" "/ (root)")}"
    printf "$(tr_text "  Заглушка: \033[36m%s\033[0m\n" "  Website: \033[36m%s\033[0m\n")" "$SITE_INDEX"
    printf "$(tr_text "  Ключей:   \033[1m%s\033[0m   |   Онлайн: \033[1;32m%s\033[0m   |   Трафик: \033[1;33m%s\033[0m   |   Релей: %s\n" "  Keys:   \033[1m%s\033[0m   |   Online: \033[1;32m%s\033[0m   |   Traffic: \033[1;33m%s\033[0m   |   Relay: %s\n")" \
      "$prof_count" "$online_summary" "$(format_bytes "$total_all")" "$git_ver"
    hr
    printf "$(tr_text "  Сервер:   %s\n" "  Server:   %s\n")" "$sys_line"
    printf "$(tr_text "  Службы:   tproxy: %s   mtproxy: %s   caddy: %s   readyz: %s\n" "  Services:   tproxy: %s   mtproxy: %s   caddy: %s   readyz: %s\n")" \
      "$(service_badge tproxy-server)" "$(service_badge mtproxy)" "$(service_badge caddy)" "$(readyz_badge)"
    hr
    printf "\n"
    bold "$(tr_text "  КЛЮЧИ, ТРАНСПОРТ И ТРАФИК" "  KEYS, TRANSPORT AND TRAFFIC")"
    printf "$(tr_text "   \033[1;36m1)\033[0m Таблица ключей, трафик и ссылки\n" "   \033[1;36m1)\033[0m Key table, traffic and links\n")"
    printf "$(tr_text "   \033[1;32m2)\033[0m Создать ключ (https / websocket / lanes)\n" "   \033[1;32m2)\033[0m Create key (https / websocket / lanes)\n")"
    printf "$(tr_text "   \033[1;35mM)\033[0m Сменить транспорт существующему ключу (или всем сразу)\n" "   \033[1;35mM)\033[0m Change transport for one or all keys\n")"
    printf "$(tr_text "   \033[1;31m3)\033[0m Удалить ключ\n\n" "   \033[1;31m3)\033[0m Delete key\n\n")"

    bold "$(tr_text "  ДОМЕН, СЕКРЕТЫ И САЙТ" "  DOMAIN, SECRETS AND WEBSITE")"
    printf "$(tr_text "   \033[1;36m4)\033[0m Настройка секретов и base_path\n" "   \033[1;36m4)\033[0m Configure secrets and base_path\n")"
    printf "$(tr_text "   \033[1;33m5)\033[0m Полная ротация (новый путь + все секреты) \033[90m[с защитой]\033[0m\n" "   \033[1;33m5)\033[0m Full rotation (new path + all secrets) \033[90m[confirmation required]\033[0m\n")"
    printf "$(tr_text "   \033[1;35m8)\033[0m Сайт-заглушка (nano)\n" "   \033[1;35m8)\033[0m Placeholder website (nano)\n")"
    printf "$(tr_text "   \033[1;36mD)\033[0m Сменить домен прокси (выпуск SSL в Caddy)\n\n" "   \033[1;36mD)\033[0m Change proxy domain (Caddy SSL)\n\n")"

    bold "$(tr_text "  СЕРВЕР И МОНИТОРИНГ" "  SERVER AND MONITORING")"
    printf "$(tr_text "   \033[1;36m6)\033[0m Обновить ядро tproxy-server\n" "   \033[1;36m6)\033[0m Update tproxy-server\n")"
    printf "$(tr_text "   \033[1;32m7)\033[0m Обновить панель tg-proxy\n" "   \033[1;32m7)\033[0m Update tg-proxy panel\n")"
    printf "$(tr_text "   \033[1;36m9)\033[0m Лимиты и воркеры MTProxy\n" "   \033[1;36m9)\033[0m MTProxy limits and workers\n")"
    printf "$(tr_text "   \033[1;33mH)\033[0m Открыть интерактивный монитор (htop)\n" "   \033[1;33mH)\033[0m Open resource monitor (htop)\n")"
    printf "$(tr_text "   \033[1;36mL)\033[0m Диагностика и логи             \033[1;36mR)\033[0m Перезапустить сервисы\n" "   \033[1;36mL)\033[0m Diagnostics and logs             \033[1;36mR)\033[0m Restart services\n")"
    printf "$(tr_text "   \033[1;90m0)\033[0m Выход\n\n" "   \033[1;90m0)\033[0m Exit\n\n")"

    local choice=""
    ask "$(tr_text "Пункт меню [0-9 / M / D / H / L / R]: " "Menu item [0-9 / M / D / H / L / R]: ")" choice
    case "${choice,,}" in
      1) users_manager_menu ;;
      2) quick_create_user || true; pause_menu ;;
      m|mode) quick_change_mode || true; pause_menu ;;
      3)
        print_proxy_info
        quick_delete_user || true
        pause_menu
        ;;
      4) secrets_and_rotation_menu ;;
      5) rotate_proxy "all"; pause_menu ;;
      6) update_proxy; pause_menu ;;
      7) self_update_script || pause_menu ;;
      8) edit_site_stub ;;
      9) tune_limits_and_routes || true; pause_menu ;;
      d|domain)
        change_domain || true
        pause_menu
        ;;
      h|htop|top)
        open_htop_monitor
        ;;
      l)
        printf '\n'
        cyan "$(tr_text "--- Проверка конфига (tproxy-server -check) ---" "--- Configuration check (tproxy-server -check) ---")"
        if /usr/local/bin/tproxy-server -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check; then
          green "$(tr_text "Конфигурация валидна." "Configuration is valid.")"
        fi
        printf '\n'
        cyan "$(tr_text "--- Статистика MTProxy (127.0.0.1:8888/stats) ---" "--- MTProxy statistics (127.0.0.1:8888/stats) ---")"
        fetch_mtproxy_stats
        printf '\n'
        cyan "$(tr_text "--- Логи (последние 20 строк) ---" "--- Logs (last 20 lines) ---")"
        journalctl -u tproxy-server -u mtproxy --no-pager -n 20
        pause_menu
        ;;
      r)
        yellow "$(tr_text "Перезапуск сервисов..." "Restarting services...")"
        sync_and_restart_services
        systemctl restart caddy 2>/dev/null || true
        green "$(tr_text "Все сервисы перезапущены!" "All services restarted!")"
        pause_menu
        ;;
      0|q|exit)
        save_nft_traffic_to_db 2>/dev/null || true
        printf "$(tr_text "\nПанель доступна по команде: \033[1;32msudo proxy\033[0m или \033[1;32msudo tg-proxy\033[0m\n\n" "\nOpen the panel with: \033[1;32msudo proxy\033[0m or \033[1;32msudo tg-proxy\033[0m\n\n")"
        exit 0
        ;;
      *)
        red "$(tr_text "Неверный выбор." "Invalid choice.")"
        sleep 1
        ;;
    esac
  done
}

# ==============================================================================
# ПЕРВИЧНАЯ УСТАНОВКА
# ==============================================================================

install_proxy() {
  printf '\n'
  header_box "$(tr_text "TELEGRAM WEB PROXY — УСТАНОВКА" "TELEGRAM WEB PROXY — INSTALLATION")"
  printf '\n'

  ask "$(tr_text "Домен для прокси (например, proxy.example.com): " "Proxy domain (for example, proxy.example.com): ")" HOST
  HOST="${HOST,,}"

  ask "$(tr_text "Email для сертификата (Enter = admin@${HOST}): " "Certificate email (Enter = admin@${HOST}): ")" EMAIL
  if [[ -z "$EMAIL" ]]; then
    EMAIL="admin@${HOST}"
    green "$(tr_text "Используется email: $EMAIL" "Using email: $EMAIL")"
  fi

  local init_mode="https"
  prompt_carrier_mode "https" init_mode
  export INITIAL_CARRIER_MODE="$init_mode"
  green "$(tr_text "Выбран режим транспорта: $init_mode" "Selected transport: $init_mode")"

  SECRET_HEX="$(openssl rand -hex 16)"
  green "$(tr_text "Сгенерирован серверный секрет (HEX): $SECRET_HEX" "Generated server secret (HEX): $SECRET_HEX")"

  yellow "$(tr_text "Подготовка директории сайта ($SITE_DIR)..." "Preparing website directory ($SITE_DIR)...")"
  mkdir -p "$SITE_DIR"
  cat > "$SITE_INDEX" <<HTML
<!doctype html>
<html lang="${PROXY_LANG}">
<head>
  <meta charset="utf-8">
  <title>${HOST}</title>
</head>
<body><h1>$(tr_text "Сайт находится в разработке." "This site is under construction.")</h1></body>
</html>
HTML
  chmod -R 755 "$SITE_DIR"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl git nftables openssl jq python3 iproute2 nano htop

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" fetch --depth=1 origin
    git -C "$INSTALL_DIR" checkout -f FETCH_HEAD
  else
    git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"
  fi

  cd "$INSTALL_DIR"

  cyan "$(tr_text "\nЗапуск официального установщика tproxy-server..." "\nRunning the official tproxy-server installer...")"
  ./deploy/install.sh \
    --hostname "$HOST" \
    --email "$EMAIL" \
    --site-dir "$SITE_DIR" \
    --secret "$SECRET_HEX"

  sleep 3

  ensure_profiles_structure

  # Принудительно устанавливаем выбранный при установке carrier_mode для созданного профиля
  if [[ -f "$PROFILES_FILE" ]]; then
    local tmp_p
    tmp_p="$(mktemp)"
    jq --arg m "$init_mode" '.profiles |= map(.carrier_mode = $m)' "$PROFILES_FILE" > "$tmp_p"
    write_file_atomically "$tmp_p" "$PROFILES_FILE"
    rm -f "$tmp_p"
  fi

  sync_and_restart_services
  install_cli_command

  printf '\n'
  hr
  green "$(tr_text "Установка успешно завершена!" "Installation completed successfully!")"
  hr

  print_proxy_info "$HOST"

  hr
  green "$(tr_text "Быстрый запуск панели в любой момент:" "Open the panel at any time:")"
  printf "$(tr_text "  \033[1;32msudo proxy\033[0m  или  \033[1;32msudo tg-proxy\033[0m\n" "  \033[1;32msudo proxy\033[0m  or  \033[1;32msudo tg-proxy\033[0m\n")"
  hr
  printf '\n'
}

# ==============================================================================
# СПРАВКА И РОУТИНГ АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ==============================================================================

show_help() {
  if [[ "$PROXY_LANG" == en ]]; then
    cat <<'HELP'
Usage: sudo proxy [COMMAND] (or sudo tg-proxy [COMMAND])

Commands:
  (no arguments)                    Open the control panel
  users, -l, --link                 List keys, traffic and links
  add <name> [mode]                 Create a key
  mode <name|number|all> [mode]     Change transport
  del <name_or_number>              Delete a key
  domain [new_domain]               Change the domain and issue a certificate
  site, nano                        Edit the placeholder website
  htop, top                         Open the resource monitor
  -r, --rotate                      Rotate path and all secrets (with confirmation)
  -u, --update                      Update tproxy-server
  --self-update                     Update the panel script
  --install                         Run the installer
  -h, --help                        Show this help
HELP
    return
  fi
  printf '\nИспользование: sudo proxy [КОМАНДА] (или sudo tg-proxy [КОМАНДА])\n\n'
  printf 'Команды:\n'
  printf '  (без аргументов)                  Открыть панель управления\n'
  printf '  users, -l, --link                 Таблица ключей, трафик и ссылки\n'
  printf '  add <имя> [режим]                 Создать ключ (sudo proxy add ivan websocket-lanes)\n'
  printf '  mode <имя|номер|all> [режим]      Сменить транспорт (https | https-lanes | websocket | websocket-lanes)\n'
  printf '  del <имя_или_номер>               Удалить ключ (sudo proxy del ivan)\n'
  printf '  domain [новый_домен]              Сменить домен прокси и перевыпустить SSL в Caddy\n'
  printf '  site, nano                        Редактировать сайт-заглушку через nano\n'
  printf '  htop, top                         Открыть интерактивный монитор ресурсов htop\n'
  printf '  -r, --rotate                      Сменить путь и все секреты (с подтверждением)\n'
  printf '  -u, --update                      Обновить ядро tproxy-server\n'
  printf '  --self-update                     Обновить сам скрипт панели с GitHub\n'
  printf '  --install                         Перезапустить мастер установки\n'
  printf '  -h, --help                        Справка\n\n'
}

# Гарантируем установку глобальной команды при любом вызове
install_cli_command 2>/dev/null || true

case "${1:-}" in
  --install)
    install_proxy
    ;;
  -m|--menu|menu)
    run_panel
    ;;
  -u|--update|update)
    update_proxy
    ;;
  --self-update|self-update)
    self_update_script
    ;;
  domain|set-domain)
    change_domain "${2:-}"
    ;;
  site|nano|stub)
    edit_site_stub
    ;;
  htop|top)
    open_htop_monitor
    ;;
  -r|--rotate|rotate)
    rotate_proxy "all"
    ;;
  -l|--link|users|list|status)
    print_proxy_info
    ;;
  add|create|new)
    quick_create_user "${2:-}" "${3:-}"
    ;;
  mode|carrier|set-mode|transport)
    quick_change_mode "${2:-}" "${3:-}"
    ;;
  del|rm|remove|delete)
    quick_delete_user "${2:-}"
    ;;
  -h|--help|help)
    show_help
    ;;
  "")
    if [[ -f "$CONFIG_FILE" ]]; then
      run_panel
    else
      install_proxy
    fi
    ;;
  *)
    die "$(tr_text "Неизвестная команда: $1 (справка: sudo proxy --help)" "Unknown command: $1 (help: sudo proxy --help)")"
    ;;
esac
