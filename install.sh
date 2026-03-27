#!/bin/bash
# =================================================================
# install.sh — X-PRO установщик
# Использование:
#   bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) [аргументы]
#
# Аргументы:
#   -panel    mhsanaei|alireza     (default: mhsanaei)
#   -port     2053-65535           (default: random)
#   -domain   example.com
#   -cdn      on|off               (default: off)
#   -warp     yes|no               (default: no)
#   -tor      yes|no               (default: no)
#   -psiphon  yes|no               (default: no)
#   -ufw      on|off               (default: off)
#   -bbr      yes|no               (default: yes)
#   -fake     yes|no               (default: yes)
# =================================================================

# ВАЖНО: НЕ используем set -e — nginx reload на незапущенном nginx
# и другие некритичные ошибки убивали бы весь скрипт.
# Критичные шаги защищены через || _fail вручную.
set -uo pipefail

# =================================================================
# ПУТИ
# =================================================================
XPRO_LIB="/usr/local/lib/xpro"
XPRO_CONF_DIR="/usr/local/etc/xpro"
XPRO_CONF="${XPRO_CONF_DIR}/xpro.conf"

REPO_RAW="https://raw.githubusercontent.com/HnDK0/xpro/main"
MODULES_URL="${REPO_RAW}/modules"
MENU_URL="${REPO_RAW}/menu.sh"

# =================================================================
# ДЕФОЛТНЫЕ АРГУМЕНТЫ
# =================================================================
ARG_PANEL="mhsanaei"
ARG_PORT=""
ARG_DOMAIN=""
ARG_CDN="off"
ARG_WARP="no"
ARG_TOR="no"
ARG_PSIPHON="no"
ARG_UFW="off"
ARG_BBR="yes"
ARG_FAKE="yes"
ARG_SSL_METHOD=""

# =================================================================
# ПАРСИНГ АРГУМЕНТОВ
# =================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -panel)      ARG_PANEL="${2:-mhsanaei}";  shift 2 ;;
            -port)       ARG_PORT="${2:-}";            shift 2 ;;
            -domain)     ARG_DOMAIN="${2:-}";          shift 2 ;;
            -cdn)        ARG_CDN="${2:-off}";          shift 2 ;;
            -warp)       ARG_WARP="${2:-no}";          shift 2 ;;
            -tor)        ARG_TOR="${2:-no}";           shift 2 ;;
            -psiphon)    ARG_PSIPHON="${2:-no}";       shift 2 ;;
            -ufw)        ARG_UFW="${2:-off}";          shift 2 ;;
            -bbr)        ARG_BBR="${2:-yes}";          shift 2 ;;
            -fake)       ARG_FAKE="${2:-yes}";         shift 2 ;;
            -ssl-method) ARG_SSL_METHOD="${2:-}";      shift 2 ;;
            -h|--help) print_usage; exit 0 ;;
            *) echo "Неизвестный аргумент: $1"; print_usage; exit 1 ;;
        esac
    done
}

print_usage() {
    cat << 'EOF'
Использование: bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) [аргументы]

  -panel    mhsanaei|alireza     панель (default: mhsanaei)
  -port     2053-65535           порт панели (default: random)
  -domain   example.com          домен для SSL
  -cdn      on|off               Cloudflare CDN (default: off)
  -warp     yes|no               установить WARP (default: no)
  -tor      yes|no               установить Tor (default: no)
  -psiphon  yes|no               установить Psiphon (default: no)
  -ufw      on|off               включить UFW (default: off)
  -bbr      yes|no               включить BBR (default: yes)
  -fake     yes|no               фейковый сайт (default: yes)
  -ssl-method 1|2                метод SSL: 1=Cloudflare DNS API, 2=standalone HTTP (default: интерактивно)

Примеры:
  bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) -domain example.com -warp yes
  bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) -domain example.com -cdn on -warp yes -ufw on
EOF
}

# =================================================================
# МИНИМАЛЬНЫЕ УТИЛИТЫ ДО ЗАГРУЗКИ core.sh
# =================================================================
_red()    { echo -e "\033[1;31m$*\033[0m"; }
_green()  { echo -e "\033[1;32m$*\033[0m"; }
_yellow() { echo -e "\033[1;33m$*\033[0m"; }
_cyan()   { echo -e "\033[1;36m$*\033[0m"; }

_step() { echo ""; _cyan ">>> $*"; }
_ok()   { _green "    [DONE] $*"; }
_fail() { _red   "    [FAIL] $*"; exit 1; }

# =================================================================
# ПРОВЕРКИ ПЕРЕД УСТАНОВКОЙ
# =================================================================
pre_checks() {
    [[ "$EUID" -ne 0 ]] && _fail "Запусти от root: sudo bash install.sh"
    [[ "$(uname)" != "Linux" ]] && _fail "Только Linux"
    [[ -z "$ARG_DOMAIN" ]] && _fail "Укажи домен: -domain example.com"

    # Валидация формата домена — защита от инъекций в nginx конфиг
    if ! [[ "$ARG_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        _fail "Неверный формат домена: ${ARG_DOMAIN}"
    fi

    if [[ -n "$ARG_PORT" ]]; then
        if ! [[ "$ARG_PORT" =~ ^[0-9]+$ ]] || \
           [ "$ARG_PORT" -lt 1024 ] || [ "$ARG_PORT" -gt 65535 ]; then
            _fail "Порт должен быть от 1024 до 65535"
        fi
    fi

    if [[ "$ARG_PSIPHON" == "yes" ]]; then
        local arch; arch=$(uname -m)
        [[ "$arch" =~ ^(x86_64|aarch64|armv7l)$ ]] || \
            _fail "Psiphon не поддерживает архитектуру: $arch"
    fi

    if [[ "$ARG_WARP" == "yes" && "$ARG_PSIPHON" == "yes" ]]; then
        _yellow "Внимание: WARP и Psiphon установлены оба."
        _yellow "В меню можно включить режим WARP+Psiphon."
    fi
}

# =================================================================
# ЗАГРУЗКА МОДУЛЕЙ
# =================================================================
load_modules() {
    _step "Загрузка модулей..."

    mkdir -p "$XPRO_LIB" "$XPRO_CONF_DIR"

    # Локальный запуск: задай XPRO_LOCAL_DIR=/path/to/repo перед вызовом скрипта.
    # BASH_SOURCE[0] при bash <(curl ...) указывает на /dev/fd/N — ненадёжно.
    if [[ -n "${XPRO_LOCAL_DIR:-}" && -d "${XPRO_LOCAL_DIR}/modules" ]]; then
        for mod in core xui nginx warp tor psiphon security; do
            cp "${XPRO_LOCAL_DIR}/modules/${mod}.sh" "${XPRO_LIB}/${mod}.sh" || \
                _fail "Не удалось скопировать ${mod}.sh"
        done
        [[ -f "${XPRO_LOCAL_DIR}/menu.sh" ]] && \
            cp "${XPRO_LOCAL_DIR}/menu.sh" "${XPRO_LIB}/menu.sh"
        _ok "Модули загружены из локальной копии (${XPRO_LOCAL_DIR})"
    else
        # Скачиваем с GitHub
        for mod in core xui nginx warp tor psiphon security; do
            curl -fsSL "${MODULES_URL}/${mod}.sh" -o "${XPRO_LIB}/${mod}.sh" || \
                _fail "Не удалось загрузить ${mod}.sh"
        done
        curl -fsSL "${MENU_URL}" -o "${XPRO_LIB}/menu.sh" || \
            _fail "Не удалось загрузить menu.sh"
        _ok "Модули загружены с GitHub"
    fi

    chmod +x "${XPRO_LIB}"/*.sh

    # Подключаем все модули
    for mod in core xui nginx warp tor psiphon security; do
        # shellcheck source=/dev/null
        source "${XPRO_LIB}/${mod}.sh"
    done
}

# =================================================================
# ГЕНЕРАЦИЯ СЛУЧАЙНОГО ПОРТА
# =================================================================
gen_random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65000 -n 1)
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

# =================================================================
# IDEMPOTENCY HELPERS — проверки "уже сделано?"
# Каждая функция возвращает 0 (уже готово, пропустить)
# или 1 (нужно выполнить).
# =================================================================

# SSL — самая критичная проверка, используем двойную верификацию:
#   1. openssl проверяет файл cert.pem: домен в CN/SAN, срок, не self-signed
#   2. acme.sh --list подтверждает что сертификат управляется acme.sh
#      (т.е. будет автоматически продляться)
# Если хоть одна проверка падает — SSL нужно настраивать.
_ssl_is_done() {
    local domain="$1"
    local cert="${NGINX_CERT_DIR:-/etc/nginx/cert}/cert.pem"

    # Нет файла сертификата
    [ -f "$cert" ] || return 1

    # Проверяем что это Let's Encrypt, а не self-signed заглушка
    # _setDefaultCert() создаёт сертификат с CN=localhost — его пропускаем
    if ! openssl x509 -noout -issuer -in "$cert" 2>/dev/null \
            | grep -qi "Let.s Encrypt\|R3\|R10\|R11\|E1\|E2"; then
        echo "info: SSL: найден self-signed сертификат, нужен реальный"
        return 1
    fi

    # Домен совпадает с запрошенным (CN или SAN)
    if ! openssl x509 -noout -text -in "$cert" 2>/dev/null \
            | grep -qE "(CN\s*=\s*|DNS:).*${domain}"; then
        echo "info: SSL: сертификат выдан для другого домена"
        return 1
    fi

    # Не истекает в ближайшие 14 дней
    if ! openssl x509 -noout -checkend $((14 * 86400)) -in "$cert" 2>/dev/null; then
        echo "info: SSL: сертификат истекает менее чем через 14 дней"
        return 1
    fi

    # acme.sh знает об этом домене (будет продлевать)
    if [ -f ~/.acme.sh/acme.sh ]; then
        if ! ~/.acme.sh/acme.sh --list 2>/dev/null | grep -qF "$domain"; then
            echo "info: SSL: acme.sh не управляет доменом ${domain}, нужна регистрация"
            return 1
        fi
    fi

    return 0
}

# Nginx конфиг — проверяем что xpro.conf существует и содержит нужный домен
_nginx_conf_is_done() {
    local domain="$1"
    local xpro_conf="${NGINX_CONF_DIR:-/etc/nginx/conf.d}/xpro.conf"
    [ -f "$xpro_conf" ] || return 1
    grep -qF "server_name ${domain}" "$xpro_conf" 2>/dev/null || return 1
    # Nginx должен быть запущен и конфиг валиден
    nginx -t &>/dev/null || return 1
    return 0
}

# CF Real IP — проверяем что файл существует и не старше 7 дней
_cf_realip_is_done() {
    local cf_file="${NGINX_CONF_DIR:-/etc/nginx/conf.d}/real_ip_restore.conf"
    [ -f "$cf_file" ] || return 1
    # Файл должен содержать реальные IP диапазоны (не пустой)
    grep -q "set_real_ip_from" "$cf_file" 2>/dev/null || return 1
    # Не старше 7 дней
    if find "$cf_file" -mtime +7 2>/dev/null | grep -q .; then
        echo "info: CF Real IP: файл старше 7 дней, обновляем"
        return 1
    fi
    return 0
}

# Fail2Ban — проверяем что jail.local настроен нами (есть наша секция [sshd])
# и сервис запущен
_fail2ban_is_done() {
    [ -f /etc/fail2ban/jail.local ] || return 1
    # Проверяем что конфиг содержит наши настройки (bantime = 24h для sshd)
    grep -q "bantime  = 24h" /etc/fail2ban/jail.local 2>/dev/null || return 1
    systemctl is-active --quiet fail2ban 2>/dev/null || return 1
    return 0
}

# UFW — проверяем что UFW активен и содержит наши базовые правила.
# НЕ пропускаем если UFW выключен (inactive) — значит setupUFW не запускался.
_ufw_is_done() {
    local xui_port="$1"
    local cdn="$2"
    # UFW должен быть активен
    ufw status 2>/dev/null | grep -q "^Status: active" || return 1
    # Правило HTTPS должно быть
    ufw status 2>/dev/null | grep -q "443" || return 1
    # Если не CDN — правило для порта панели должно быть
    if [ "$cdn" != "on" ] && [ -n "$xui_port" ]; then
        ufw status 2>/dev/null | grep -q "$xui_port" || return 1
    fi
    return 0
}

# Sysctl — проверяем что наш файл уже существует с нужным содержимым
_sysctl_is_done() {
    local f="/etc/sysctl.d/99-xpro-network.conf"
    [ -f "$f" ] || return 1
    grep -q "somaxconn" "$f" 2>/dev/null || return 1
    grep -q "tcp_keepalive" "$f" 2>/dev/null || return 1
    return 0
}

# =================================================================
# ОСНОВНОЙ УСТАНОВЩИК
# =================================================================
main() {
    parse_args "$@"

    clear
    echo "${cyan}================================================================${reset}"
    echo "   ${green}X-UI PRO Installer${reset}"
    echo "${cyan}================================================================${reset}"
    echo ""
    echo "  Панель:   $ARG_PANEL"
    echo "  Домен:    $ARG_DOMAIN"
    echo "  Порт:     ${ARG_PORT:-random}"
    echo "  CDN:      $ARG_CDN"
    echo "  WARP:     $ARG_WARP"
    echo "  Tor:      $ARG_TOR"
    echo "  Psiphon:  $ARG_PSIPHON"
    echo "  UFW:      $ARG_UFW"
    echo "  BBR:      $ARG_BBR"
    echo "  Fake:     $ARG_FAKE"
    echo ""

    _step "Проверка требований"
    pre_checks
    _ok "Проверки пройдены"

    load_modules

    _step "Определение системы"
    identifyOS
    _ok "OS определена: ${OS_NAME:-Linux}"

    _step "Подготовка системы"
    # Удаляем мусорные CF-репо ДО любых apt операций (Баг: NO_PUBKEY на Ubuntu 24.04)
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /etc/apt/sources.list.d/cloudflare-warp.list
    ${PACKAGE_MANAGEMENT_UPDATE} -qq 2>/dev/null || true
    installPackage "gnupg2" || true
    installPackage "sqlite3" || true
    _ok "Базовые пакеты"

    _step "Настройка Swap"
    setupSwap
    _ok "Swap настроен"

    if [[ -z "$ARG_PORT" ]]; then
        ARG_PORT=$(gen_random_port)
        _yellow "Случайный порт панели: $ARG_PORT"
    fi

    xpro_conf_set "DOMAIN"    "$ARG_DOMAIN"
    xpro_conf_set "CDN"       "$ARG_CDN"
    xpro_conf_set "XUI_PANEL" "$ARG_PANEL"

    # =============================================================
    # ШАГ 1 — 3x-ui
    # =============================================================
    _step "Установка 3x-ui (${ARG_PANEL})"
    if systemctl is-active --quiet x-ui 2>/dev/null && \
       [ -f /usr/local/bin/x-ui ]; then
        echo "info: 3x-ui уже установлен и запущен — пропускаем"
        _ok "3x-ui установлен"
    else
        install3xui "$ARG_PANEL" "$ARG_PORT" || _fail "Не удалось установить 3x-ui"
        _ok "3x-ui установлен"
    fi

    # Ждём инициализации БД 3x-ui (credentials могут быть не готовы сразу)
    _step "Синхронизация с БД 3x-ui"
    xuiWaitForDB 15 || _yellow "warn: таймаут БД, credentials могут быть дефолтными"
    _ok "БД синхронизирована"

    # Читаем реальные данные из БД (единый источник правды)
    local real_port real_user real_pass real_web_path
    real_port=$(xuiGetPort)
    real_user=$(xuiGetUser)
    real_pass=$(xuiGetPass)
    real_web_path=$(xuiGetWebBasePath)
    ARG_PORT="$real_port"
    _yellow "Порт панели (из БД): $ARG_PORT"

    # Сохраняем в xpro.conf как кэш
    xpro_conf_set "XUI_PORT"          "$real_port"
    xpro_conf_set "XUI_USER"          "$real_user"
    xpro_conf_set "XUI_PASS"          "$real_pass"
    xpro_conf_set "XUI_WEB_BASE_PATH" "$real_web_path"

    # =============================================================
    # ШАГ 2 — Nginx
    # =============================================================
    _step "Установка Nginx"
    installNginx || _fail "Не удалось установить Nginx"
    _ok "Nginx установлен"

    # =============================================================
    # ШАГ 3 — SSL
    # =============================================================
    _step "Настройка SSL для ${ARG_DOMAIN}"
    if _ssl_is_done "$ARG_DOMAIN"; then
        _ok "SSL уже настроен — пропускаем"
    else
        configSSL "$ARG_DOMAIN" "$ARG_CDN" "$ARG_SSL_METHOD" || _fail "Не удалось настроить SSL"
        _ok "SSL настроен"
    fi

    # =============================================================
    # ШАГ 4 — Фейковый сайт (ДО writeNginxConfig — URL должен быть в конфиге)
    # =============================================================
    if [[ "$ARG_FAKE" == "yes" ]]; then
        _step "Выбор фейкового сайта"
        # Пропускаем только если nginx конфиг уже существует для этого домена
        # (т.е. writeNginxConfig уже отработал с каким-то сайтом).
        # При свежей установке или смене домена — всегда выбираем рандомный.
        if _nginx_conf_is_done "$ARG_DOMAIN"; then
            _ok "Фейковый сайт: $(xpro_conf_get FAKE_SITE_URL) — nginx уже настроен, пропускаем"
        else
            setFakeSite "random"
            _ok "Фейковый сайт: $(xpro_conf_get FAKE_SITE_URL)"
        fi
    fi

    # =============================================================
    # ШАГ 5 — Nginx конфиг (cert и fake_url уже готовы)
    # =============================================================
    _step "Настройка Nginx reverse proxy"
    if _nginx_conf_is_current "$ARG_DOMAIN"; then
        _ok "Nginx конфиг актуален — пропускаем"
    else
        writeNginxConfig "$ARG_DOMAIN" "$ARG_CDN" || \
            _fail "Не удалось записать конфиг Nginx"
        _ok "Nginx конфиг обновлён"
    fi

    # =============================================================
    # ШАГ 6 — Cloudflare Real IP
    # =============================================================
    _step "Настройка Cloudflare Real IP"
    if _cf_realip_is_done; then
        _ok "CF Real IP уже настроен — пропускаем"
    else
        setupRealIpRestore || _yellow "warn: Не удалось получить CF IP диапазоны"
        setupCfIpCron
        _ok "CF Real IP настроен"
    fi

    # =============================================================
    # ШАГ 7 — WARP
    # =============================================================
    if [[ "$ARG_WARP" == "yes" ]]; then
        _step "Установка Cloudflare WARP"
        if command -v warp-cli &>/dev/null && \
           systemctl is-active --quiet warp-svc 2>/dev/null && \
           [ "$(xpro_conf_get WARP_INSTALLED)" = "yes" ]; then
            _ok "WARP уже установлен и запущен — пропускаем"
        else
            installWarp || _fail "Не удалось установить WARP"
            configWarp || _fail "Не удалось настроить WARP"
            sleep 3
            addWarpOutbound || \
                _yellow "warn: Outbound WARP — добавь вручную: xpro → WARP → Добавить outbound"
            xpro_conf_set "WARP_INSTALLED" "yes"
            _ok "WARP установлен (socks5://127.0.0.1:40000)"
        fi
    else
        xpro_conf_set "WARP_INSTALLED" "no"
    fi

    # =============================================================
    # ШАГ 8 — Tor
    # =============================================================
    if [[ "$ARG_TOR" == "yes" ]]; then
        _step "Установка Tor"
        if command -v tor &>/dev/null && \
           systemctl is-active --quiet tor 2>/dev/null && \
           [ "$(xpro_conf_get TOR_INSTALLED)" = "yes" ]; then
            _ok "Tor уже установлен и запущен — пропускаем"
        else
            installTor || _fail "Не удалось установить Tor"
            configTor
            startTor || _fail "Tor не запустился"
            enableTor
            sleep 3
            addTorOutbound || \
                _yellow "warn: Outbound Tor — добавь вручную: xpro → Tor → Добавить outbound"
            xpro_conf_set "TOR_INSTALLED" "yes"
            _ok "Tor установлен (socks5://127.0.0.1:40003)"
        fi
    else
        xpro_conf_set "TOR_INSTALLED" "no"
    fi

    # =============================================================
    # ШАГ 9 — Psiphon
    # =============================================================
    if [[ "$ARG_PSIPHON" == "yes" ]]; then
        _step "Установка Psiphon"
        if [ -f /usr/local/bin/psiphon-tunnel-core ] && \
           systemctl is-active --quiet psiphon 2>/dev/null && \
           [ "$(xpro_conf_get PSIPHON_INSTALLED)" = "yes" ]; then
            _ok "Psiphon уже установлен и запущен — пропускаем"
        else
            installPsiphon || _fail "Не удалось установить Psiphon"
            writePsiphonConfig "" "plain"
            writePsiphonService
            startPsiphon || _fail "Psiphon не запустился"
            enablePsiphon
            sleep 5
            addPsiphonOutbound || \
                _yellow "warn: Outbound Psiphon — добавь вручную: xpro → Psiphon → Добавить outbound"
            xpro_conf_set "PSIPHON_INSTALLED" "yes"
            _ok "Psiphon установлен (socks5://127.0.0.1:40002)"
        fi
    else
        xpro_conf_set "PSIPHON_INSTALLED" "no"
    fi

    # =============================================================
    # ШАГ 10 — BBR
    # BBR уже имеет проверку внутри enableBBR(), но делаем step-уровень
    # =============================================================
    if [[ "$ARG_BBR" == "yes" ]]; then
        _step "Включение BBR"
        if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
            _ok "BBR уже активен — пропускаем"
        else
            enableBBR
            _ok "BBR включён"
        fi
    fi

    # =============================================================
    # ШАГ 11 — Sysctl
    # =============================================================
    _step "Применение sysctl оптимизаций"
    if _sysctl_is_done; then
        _ok "Sysctl уже применён — пропускаем"
    else
        applySysctl
        _ok "Sysctl применён"
    fi

    # =============================================================
    # ШАГ 12 — Fail2Ban
    # =============================================================
    _step "Настройка Fail2Ban"
    if _fail2ban_is_done; then
        _ok "Fail2Ban уже настроен — пропускаем"
    else
        setupFail2Ban
        _ok "Fail2Ban настроен"
    fi

    # =============================================================
    # ШАГ 13 — UFW
    # =============================================================
    if [[ "$ARG_UFW" == "on" ]]; then
        _step "Настройка UFW"
        if _ufw_is_done "$ARG_PORT" "$ARG_CDN"; then
            _ok "UFW уже настроен — пропускаем"
        else
            setupUFW "$ARG_PORT" "$ARG_CDN"
            _ok "UFW настроен"
        fi
    fi

    # =============================================================
    # ШАГ 14 — Команда xpro
    # menu.sh уже скачан в XPRO_LIB при load_modules — просто копируем
    # =============================================================
    _step "Установка команды xpro"
    cp "${XPRO_LIB}/menu.sh" /usr/local/bin/xpro
    chmod +x /usr/local/bin/xpro
    _ok "Команда xpro установлена"

    print_summary
}

# =================================================================
# ИТОГОВЫЙ ЭКРАН
# Читаем данные напрямую из xpro.conf — не вызываем функции,
# которые могут вернуть ненулевой код и уронить скрипт
# =================================================================
print_summary() {
    local domain xui_user xui_pass xui_port xui_path server_ip ssl_info panel_url
    domain=$(xpro_conf_get "DOMAIN"          2>/dev/null || echo "$ARG_DOMAIN")
    xui_user=$(xpro_conf_get "XUI_USER"      2>/dev/null || echo "?")
    xui_pass=$(xpro_conf_get "XUI_PASS"      2>/dev/null || echo "?")
    xui_port=$(xpro_conf_get "XUI_PORT"      2>/dev/null || echo "$ARG_PORT")
    xui_path=$(xpro_conf_get "XUI_WEB_BASE_PATH" 2>/dev/null || echo "")
    server_ip=$(getServerIP 2>/dev/null || echo "?")
    ssl_info=$(checkCertExpiry 2>/dev/null || echo "?")

    # Финальная синхронизация — credentials могли обновиться после всех шагов
    sleep 2
    xuiWaitForDB 5 2>/dev/null || true
    local fresh_user fresh_pass
    fresh_user=$(xuiGetUser 2>/dev/null || echo "")
    fresh_pass=$(xuiGetPass 2>/dev/null || echo "")
    [ -n "$fresh_user" ] && xui_user="$fresh_user"
    [ -n "$fresh_pass" ] && xui_pass="$fresh_pass"

    if [ -n "$xui_path" ]; then
        panel_url="${domain}/${xui_path}"
    else
        panel_url="${domain}  (путь не определён)"
    fi

    echo ""
    echo "${cyan}================================================================${reset}"
    printf "   ${green}X-UI PRO — Установка завершена${reset}\n"
    echo "${cyan}================================================================${reset}"
    printf "  Панель:  https://%s\n" "${panel_url}"
    printf "  IP:      %s\n" "$server_ip"
    printf "  Логин:   %s\n" "$xui_user"
    printf "  Пароль:  %s\n" "$xui_pass"
    printf "  SSL:     %s\n" "$ssl_info"
    echo "${cyan}================================================================${reset}"

    [[ "$(xpro_conf_get WARP_INSTALLED 2>/dev/null)" == "yes" ]] && \
        echo "  WARP:     socks5://127.0.0.1:40000"
    [[ "$(xpro_conf_get TOR_INSTALLED 2>/dev/null)" == "yes" ]] && \
        echo "  Tor:      socks5://127.0.0.1:40003"
    [[ "$(xpro_conf_get PSIPHON_INSTALLED 2>/dev/null)" == "yes" ]] && \
        echo "  Psiphon:  socks5://127.0.0.1:40002"

    echo "${cyan}================================================================${reset}"
    echo "  Управление: xpro"
    echo "  Удаление:   xpro uninstall"
    echo "${cyan}================================================================${reset}"
    echo ""

    if [[ "$ARG_CDN" == "on" ]]; then
        _yellow "CDN включён. Убедись что в Cloudflare:"
        _yellow "  - DNS запись для ${domain} проксируется (оранжевое облако)"
        _yellow "  - SSL/TLS режим: Full (strict)"
        echo ""
    fi

    if [[ "$ARG_UFW" == "on" ]]; then
        _green "UFW активен. Прямой доступ к порту ${xui_port} закрыт снаружи."
    else
        _yellow "UFW выключен. Рекомендуем: xpro → Безопасность → UFW"
    fi
    echo ""
}

# =================================================================
# ТОЧКА ВХОДА
# =================================================================
main "$@"