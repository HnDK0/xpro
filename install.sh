#!/bin/bash
# =================================================================
# install.sh — X-PRO установщик
# Использование:
#   bash <(curl -Ls https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) [аргументы]
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

set -euo pipefail

# =================================================================
# ПУТИ
# =================================================================
XPRO_LIB="/usr/local/lib/xpro"
XPRO_BIN="/usr/local/bin/xpro"
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

# =================================================================
# ПАРСИНГ АРГУМЕНТОВ
# =================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -panel)   ARG_PANEL="${2:-mhsanaei}";  shift 2 ;;
            -port)    ARG_PORT="${2:-}";            shift 2 ;;
            -domain)  ARG_DOMAIN="${2:-}";          shift 2 ;;
            -cdn)     ARG_CDN="${2:-off}";          shift 2 ;;
            -warp)    ARG_WARP="${2:-no}";          shift 2 ;;
            -tor)     ARG_TOR="${2:-no}";           shift 2 ;;
            -psiphon) ARG_PSIPHON="${2:-no}";       shift 2 ;;
            -ufw)     ARG_UFW="${2:-off}";          shift 2 ;;
            -bbr)     ARG_BBR="${2:-yes}";          shift 2 ;;
            -fake)    ARG_FAKE="${2:-yes}";         shift 2 ;;
            -h|--help) print_usage; exit 0 ;;
            *) echo "Неизвестный аргумент: $1"; print_usage; exit 1 ;;
        esac
    done
}

print_usage() {
    cat << 'EOF'
Использование: bash <(curl -Ls https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) [аргументы]

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

Примеры:
  bash <(curl -Ls https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) -domain example.com -cdn on -warp yes -tor yes
  bash <(curl -Ls https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) -domain example.com -warp yes -ufw on
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

    # Если запуск из локальной копии репо — подключаем напрямую
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -d "${script_dir}/modules" ]]; then
        for mod in core xui nginx warp tor psiphon security; do
            cp "${script_dir}/modules/${mod}.sh" "${XPRO_LIB}/${mod}.sh"
        done
        # Копируем menu.sh
        [[ -f "${script_dir}/menu.sh" ]] && \
            cp "${script_dir}/menu.sh" "${XPRO_LIB}/menu.sh"
        _ok "Модули загружены из локальной копии"
    else
        # Скачиваем с GitHub
        for mod in core xui nginx warp tor psiphon security; do
            curl -fsSL "${MODULES_URL}/${mod}.sh" -o "${XPRO_LIB}/${mod}.sh" || \
                _fail "Не удалось загрузить ${mod}.sh"
        done
        # Скачиваем menu.sh
        curl -fsSL "${MENU_URL}" -o "${XPRO_LIB}/menu.sh" || \
            _fail "Не удалось загрузить menu.sh"
        _ok "Модули загружены с GitHub"
    fi

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
# ОСНОВНОЙ УСТАНОВЩИК
# =================================================================
main() {
    parse_args "$@"

    clear
    cat << 'EOF'
╔═══════════════════════════════════════╗
║           X-UI PRO Installer          ║
╚═══════════════════════════════════════╝
EOF
    echo ""
    echo "  Панель:   $ARG_PANEL"
    echo "  Домен:    $ARG_DOMAIN"
    echo "  CDN:      $ARG_CDN"
    echo "  WARP:     $ARG_WARP"
    echo "  Tor:      $ARG_TOR"
    echo "  Psiphon:  $ARG_PSIPHON"
    echo "  UFW:      $ARG_UFW"
    echo "  BBR:      $ARG_BBR"
    echo ""

    _step "Проверка требований"
    pre_checks
    _ok "Проверки пройдены"

    load_modules

    _step "Определение системы"
    identifyOS
    _ok "OS определена: ${OS_NAME:-Linux}"

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

    # ШАГ 1 — 3x-ui
    _step "Установка 3x-ui (${ARG_PANEL})"
    install3xui "$ARG_PANEL" "$ARG_PORT"
    _ok "3x-ui установлен"

    local real_port
    real_port=$(xuiGetPort)
    xpro_conf_set "XUI_PORT" "$real_port"
    ARG_PORT="$real_port"

    local xui_user xui_pass
    xui_user=$(xuiGetUser)
    xui_pass=$(xuiGetPass)
    xpro_conf_set "XUI_USER" "$xui_user"
    xpro_conf_set "XUI_PASS" "$xui_pass"

    # ШАГ 2 — Nginx
    _step "Установка Nginx"
    installNginx
    _ok "Nginx установлен"

    # ШАГ 3 — SSL
    _step "Настройка SSL для ${ARG_DOMAIN}"
    configSSL "$ARG_DOMAIN" "$ARG_CDN"
    _ok "SSL настроен"

    # ШАГ 4 — Nginx конфиг
    _step "Настройка Nginx reverse proxy"
    writeNginxConfig "$ARG_DOMAIN" "$ARG_PORT" "$ARG_CDN"
    _ok "Nginx конфиг записан"

    # ШАГ 5 — Фейковый сайт
    if [[ "$ARG_FAKE" == "yes" ]]; then
        _step "Установка фейкового сайта"
        setFakeSite "random"
        _ok "Фейковый сайт установлен"
    fi

    # ШАГ 6 — Cloudflare Real IP
    _step "Настройка Cloudflare Real IP"
    setupRealIpRestore
    setupCfIpCron
    _ok "CF Real IP настроен"

    # ШАГ 7 — WARP
    if [[ "$ARG_WARP" == "yes" ]]; then
        _step "Установка Cloudflare WARP"
        installWarp
        configWarp
        sleep 3
        addWarpOutbound
        xpro_conf_set "WARP_INSTALLED" "yes"
        _ok "WARP установлен (socks5://127.0.0.1:40000)"
    else
        xpro_conf_set "WARP_INSTALLED" "no"
    fi

    # ШАГ 8 — Tor
    if [[ "$ARG_TOR" == "yes" ]]; then
        _step "Установка Tor"
        installTor
        configTor
        startTor
        enableTor
        sleep 3
        addTorOutbound
        xpro_conf_set "TOR_INSTALLED" "yes"
        _ok "Tor установлен (socks5://127.0.0.1:40003)"
    else
        xpro_conf_set "TOR_INSTALLED" "no"
    fi

    # ШАГ 9 — Psiphon
    if [[ "$ARG_PSIPHON" == "yes" ]]; then
        _step "Установка Psiphon"
        installPsiphon
        writePsiphonConfig "" "plain"
        writePsiphonService
        startPsiphon
        enablePsiphon
        sleep 5
        addPsiphonOutbound
        xpro_conf_set "PSIPHON_INSTALLED" "yes"
        _ok "Psiphon установлен (socks5://127.0.0.1:40002)"
    else
        xpro_conf_set "PSIPHON_INSTALLED" "no"
    fi

    # ШАГ 10 — BBR
    if [[ "$ARG_BBR" == "yes" ]]; then
        _step "Включение BBR"
        enableBBR
        _ok "BBR включён"
    fi

    # ШАГ 11 — Sysctl
    _step "Применение sysctl оптимизаций"
    applySysctl
    _ok "Sysctl применён"

    # ШАГ 12 — Fail2Ban
    _step "Настройка Fail2Ban"
    setupFail2Ban
    _ok "Fail2Ban настроен"

    # ШАГ 13 — UFW
    if [[ "$ARG_UFW" == "on" ]]; then
        _step "Настройка UFW"
        setupUFW "$ARG_PORT" "$ARG_CDN"
        _ok "UFW настроен"
    fi

    # ШАГ 14 — Команда xpro
    _step "Установка команды xpro"
    setupAlias
    _ok "Команда xpro готова"

    print_summary
}

# =================================================================
# ИТОГОВЫЙ ЭКРАН
# =================================================================
print_summary() {
    local server_ip
    server_ip=$(getServerIP)

    local ssl_days
    ssl_days=$(checkCertExpiry 2>/dev/null || echo "?")

    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║         X-UI PRO — Установка завершена        ║"
    echo "╠═══════════════════════════════════════════════╣"
    printf "║  %-45s║\n" ""
    printf "║  Панель:  https://%-27s║\n" "${ARG_DOMAIN}/xui/"
    printf "║  IP:      %-35s║\n" "$server_ip"
    printf "║  Логин:   %-35s║\n" "$(xpro_conf_get XUI_USER)"
    printf "║  Пароль:  %-35s║\n" "$(xpro_conf_get XUI_PASS)"
    printf "║  SSL:     %-35s║\n" "$ssl_days дней"
    printf "║  %-45s║\n" ""
    echo "╠═══════════════════════════════════════════════╣"

    [[ "$(xpro_conf_get WARP_INSTALLED)" == "yes" ]] && \
        printf "║  WARP     ● socks5://127.0.0.1:%-14s║\n" "40000"
    [[ "$(xpro_conf_get TOR_INSTALLED)" == "yes" ]] && \
        printf "║  Tor      ● socks5://127.0.0.1:%-14s║\n" "40003"
    [[ "$(xpro_conf_get PSIPHON_INSTALLED)" == "yes" ]] && \
        printf "║  Psiphon  ● socks5://127.0.0.1:%-14s║\n" "40002"

    echo "╠═══════════════════════════════════════════════╣"
    printf "║  %-45s║\n" "Управление: xpro"
    printf "║  %-45s║\n" "Удаление:   xpro uninstall"
    printf "║  %-45s║\n" ""
    echo "╚═══════════════════════════════════════════════╝"
    echo ""

    if [[ "$ARG_CDN" == "on" ]]; then
        _yellow "CDN включён. Убедись что в Cloudflare:"
        _yellow "  - DNS запись для ${ARG_DOMAIN} проксируется (оранжевое облако)"
        _yellow "  - SSL/TLS режим: Full (strict)"
        echo ""
    fi

    if [[ "$ARG_UFW" == "on" ]]; then
        _green "UFW активен. Прямой доступ к порту ${ARG_PORT} закрыт."
    else
        _yellow "UFW выключен. Рекомендуем: xpro → Безопасность → UFW"
    fi
    echo ""
}

# =================================================================
# ТОЧКА ВХОДА
# =================================================================
main "$@"
