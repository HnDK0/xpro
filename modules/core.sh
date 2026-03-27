#!/bin/bash
# =================================================================
# core.sh — Общие переменные, утилиты, OS detection
# =================================================================

XPRO_VERSION="1.0"
XPRO_LIB="/usr/local/lib/xpro"
XPRO_CONF_DIR="/usr/local/etc/xpro"
XPRO_CONF="${XPRO_CONF_DIR}/xpro.conf"

# Порты сервисов
WARP_PORT=40000
PSIPHON_PORT=40002
TOR_PORT=40003
TOR_CONTROL_PORT=40004

# =================================================================
# ЦВЕТА
# Используем жёсткие ANSI-коды вместо tput — работают всегда,
# даже при запуске через bash <(curl ...) до инициализации терминала.
# =================================================================
red=$'\033[1;31m'
green=$'\033[1;32m'
yellow=$'\033[1;33m'
cyan=$'\033[1;36m'
reset=$'\033[0m'

# =================================================================
# XPRO.CONF — get / set / del
# =================================================================
xpro_conf_get() {
    local key="$1"
    grep "^${key}=" "$XPRO_CONF" 2>/dev/null | cut -d= -f2-
}

xpro_conf_set() {
    local key="$1" val="$2"
    mkdir -p "$XPRO_CONF_DIR"
    touch "$XPRO_CONF"
    if grep -q "^${key}=" "$XPRO_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$XPRO_CONF"
    else
        echo "${key}=${val}" >> "$XPRO_CONF"
    fi
}

xpro_conf_del() {
    local key="$1"
    sed -i "/^${key}=/d" "$XPRO_CONF" 2>/dev/null || true
}

# =================================================================
# СИСТЕМА
# =================================================================
isRoot() {
    [[ "$EUID" -ne 0 ]] && {
        echo "${red}Запусти от root: sudo xpro${reset}"
        exit 1
    }
}

identifyOS() {
    [[ "$(uname)" != "Linux" ]] && {
        echo "error: Только Linux"
        exit 1
    }

    # Определяем имя OS для отображения
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_NAME="${PRETTY_NAME:-Linux}"
    else
        OS_NAME="Linux"
    fi

    if command -v apt &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
        PACKAGE_MANAGEMENT_REMOVE='apt purge -y'
        PACKAGE_MANAGEMENT_UPDATE='apt update'
    elif command -v dnf &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
        PACKAGE_MANAGEMENT_REMOVE='dnf remove -y'
        PACKAGE_MANAGEMENT_UPDATE='dnf update'
    elif command -v yum &>/dev/null; then
        PACKAGE_MANAGEMENT_INSTALL='yum -y install'
        PACKAGE_MANAGEMENT_REMOVE='yum remove -y'
        PACKAGE_MANAGEMENT_UPDATE='yum update'
        ${PACKAGE_MANAGEMENT_INSTALL} epel-release &>/dev/null || true
    else
        echo "error: Пакетный менеджер не поддерживается"
        exit 1
    fi

    export OS_NAME
    export PACKAGE_MANAGEMENT_INSTALL
    export PACKAGE_MANAGEMENT_REMOVE
    export PACKAGE_MANAGEMENT_UPDATE
}

installPackage() {
    local pkg="$1"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS

    if ${PACKAGE_MANAGEMENT_INSTALL} "$pkg" &>/dev/null; then
        echo "info: $pkg установлен"
        return 0
    fi

    # Попытка починить зависимости и повторить
    echo "${yellow}warn: Пытаемся починить зависимости для $pkg...${reset}"
    command -v dpkg &>/dev/null && dpkg --configure -a 2>/dev/null || true
    ${PACKAGE_MANAGEMENT_UPDATE} &>/dev/null || true

    if ${PACKAGE_MANAGEMENT_INSTALL} "$pkg"; then
        echo "info: $pkg установлен (после починки)"
        return 0
    fi

    echo "${red}error: Не удалось установить $pkg${reset}"
    return 1
}

uninstallPackage() {
    local pkg="$1"
    [ -z "${PACKAGE_MANAGEMENT_REMOVE:-}" ] && identifyOS
    ${PACKAGE_MANAGEMENT_REMOVE} "$pkg" &>/dev/null && \
        echo "info: $pkg удалён" || true
}

# =================================================================
# run_task — обёртка с визуальным DONE/FAIL
# Использование: run_task "Описание" команда [аргументы...]
# =================================================================
run_task() {
    local msg="$1"; shift
    printf "\n${yellow}>>> %s${reset}\n" "$msg"
    if eval "$@"; then
        printf "[${green} DONE ${reset}] %s\n" "$msg"
        return 0
    else
        printf "[${red} FAIL ${reset}] %s\n" "$msg"
        return 1
    fi
}

# =================================================================
# SWAP
# Создаёт swap если его нет или он меньше 256MB
# Размер определяется по RAM автоматически
# =================================================================
setupSwap() {
    local swap_total
    swap_total=$(free -m | awk '/^Swap:/{print $2}')
    if [ "${swap_total:-0}" -gt 256 ]; then
        echo "info: Swap уже есть (${swap_total}MB), пропускаем"
        return 0
    fi

    local ram_mb swap_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')

    if   [ "$ram_mb" -le 512 ];  then swap_mb=1024
    elif [ "$ram_mb" -le 1024 ]; then swap_mb=1024
    elif [ "$ram_mb" -le 2048 ]; then swap_mb=2048
    else swap_mb=1024
    fi

    echo "${cyan}Создаём swap ${swap_mb}MB...${reset}"

    local swapfile="/swapfile"
    if fallocate -l "${swap_mb}M" "$swapfile" 2>/dev/null || \
       dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mb" status=none; then
        chmod 600 "$swapfile"
        mkswap "$swapfile" &>/dev/null
        swapon "$swapfile"
        grep -q "$swapfile" /etc/fstab || \
            echo "$swapfile none swap sw 0 0" >> /etc/fstab
        sysctl -w vm.swappiness=10 &>/dev/null
        grep -q "vm.swappiness" /etc/sysctl.conf || \
            echo "vm.swappiness=10" >> /etc/sysctl.conf
        echo "${green}Swap ${swap_mb}MB создан${reset}"
    else
        echo "${yellow}warn: Не удалось создать swap${reset}"
    fi
}

# =================================================================
# ALIAS — команда xpro
# install.sh всегда скачивает menu.sh в XPRO_LIB при загрузке модулей,
# поэтому берём только оттуда. Не полагаемся на BASH_SOURCE —
# при запуске через bash <(curl ...) он указывает на /dev/fd/N.
# =================================================================
setupAlias() {
    if [ ! -f "${XPRO_LIB}/menu.sh" ]; then
        echo "${red}Ошибка: menu.sh не найден в ${XPRO_LIB}${reset}"
        echo "${red}Это не должно происходить — модули не были загружены?${reset}"
        return 1
    fi
    cp "${XPRO_LIB}/menu.sh" /usr/local/bin/xpro
    chmod +x /usr/local/bin/xpro
    echo "info: Команда xpro установлена"
}

# =================================================================
# СЕТЬ — getServerIP
# Пробует несколько сервисов с фалбеками
# Возвращает только публичный IPv4
# =================================================================
getServerIP() {
    local ip
    for url in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://checkip.amazonaws.com" \
        "https://api4.my-ip.io/ip" \
        "https://ipv4.wtfismyip.com/text"; do
        ip=$(curl -s --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # Пропускаем приватные адреса
            if ! [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                echo "$ip"
                return 0
            fi
        fi
    done

    # Последний фалбек — локальный маршрут
    ip=$(ip route get 8.8.8.8 2>/dev/null | \
         awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    echo "${ip:-UNKNOWN}"
}

# =================================================================
# ГEOIP — код страны и emoji флаг
# =================================================================
getCountryCode() {
    local ip="${1:-$(getServerIP)}"
    local code
    code=$(curl -s --connect-timeout 5 \
        "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | \
        tr -d '[:space:]')
    if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
        echo "$code"
    else
        echo "??"
    fi
}

getCountryFlag() {
    local code="${1:-$(getCountryCode)}"
    [[ "$code" == "??" ]] && { echo "🌐"; return; }
    python3 -c "
c='${code}'
flag=''.join(chr(0x1F1E6 + ord(ch) - ord('A')) for ch in c)
print(flag)
" 2>/dev/null || echo "🌐"
}

# =================================================================
# checkServiceIP — проверка IP через прокси с фалбеками
# Использование: checkServiceIP "socks5://127.0.0.1:40000" "WARP"
# =================================================================
checkServiceIP() {
    local proxy="$1"
    local name="${2:-Service}"
    local ip=""
    local ok=0

    for url in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://api4.my-ip.io/ip" \
        "https://checkip.amazonaws.com" \
        "https://ipv4.wtfismyip.com/text"; do
        ip=$(curl -s --connect-timeout 8 -x "$proxy" "$url" 2>/dev/null | \
             tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ok=1
            break
        fi
    done

    if [ "$ok" -eq 1 ]; then
        # Определяем страну для найденного IP
        local country
        country=$(curl -s --connect-timeout 5 \
            "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | \
            tr -d '[:space:]')
        [[ "$country" =~ ^[A-Z]{2}$ ]] || country="??"
        echo "${green}${name} IP: ${ip} [${country}]${reset}"
    else
        echo "${red}${name} IP: недоступен${reset}"
    fi
}

# =================================================================
# СТАТУС СЕРВИСОВ — для главного экрана
# =================================================================
getServiceStatus() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "${green}RUNNING${reset}"
    else
        echo "${red}STOPPED${reset}"
    fi
}

# =================================================================
# PAD — выравнивание с учётом ANSI escape кодов
# Использование: _pad "строка с цветом" ширина
# =================================================================
_pad() {
    local v="$1" w="$2" vis
    vis=$(printf '%s' "$v" | \
          sed 's/\x1b\[[0-9;]*[mABCDJKHf]//g; s/\x1b(B//g')
    printf "%s%*s" "$v" $((w - ${#vis})) ""
}

# =================================================================
# ГЕНЕРАЦИЯ СЛУЧАЙНОГО ПУТИ (без коллизий с nginx locations)
# =================================================================
generateRandomPath() {
    local path attempts=0
    while [ $attempts -lt 20 ]; do
        path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)"
        # Проверяем коллизию: путь не должен совпадать ни с одним
        # существующим location в nginx конфигах
        if ! grep -rqE "location[[:space:]]+[~*]*[[:space:]]*\"?${path}" \
                /etc/nginx/conf.d/ /etc/nginx/sites-enabled/ 2>/dev/null; then
            echo "$path"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    # После 20 попыток шанс коллизии пренебрежимо мал — отдаём последний
    echo "$path"
}

# =================================================================
# ГЕНЕРАЦИЯ СЛУЧАЙНОГО ПОРТА (свободного)
# =================================================================
generateFreePort() {
    local port
    while true; do
        port=$(shuf -i 10000-65000 -n 1)
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
    done
}
