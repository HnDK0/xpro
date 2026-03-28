#!/bin/bash
# =================================================================
# tor.sh — Tor: установка, мосты, страна выхода
# SOCKS5 на 127.0.0.1:40003
# =================================================================

TOR_PORT=40003
TOR_CONTROL_PORT=40004
TOR_CONFIG="/etc/tor/torrc"
TOR_SVC="tor"

# =================================================================
# СТАТУС
# =================================================================
getTorStatus() {
    if ! command -v tor &>/dev/null; then
        echo "${red}НЕ УСТАНОВЛЕН${reset}"
        return
    fi

    if ! systemctl is-active --quiet "$TOR_SVC" 2>/dev/null; then
        echo "${red}STOPPED${reset}"
        return
    fi

    local extra=""

    # Страна выхода
    if grep -q "^ExitNodes" "$TOR_CONFIG" 2>/dev/null; then
        local country
        country=$(grep "^ExitNodes" "$TOR_CONFIG" | \
            grep -oP '\{[A-Z]+\}' | tr -d '{}' | head -1)
        [ -n "$country" ] && extra="${extra} | ${country}"
    fi

    # Тип моста
    if grep -q "^UseBridges 1" "$TOR_CONFIG" 2>/dev/null; then
        local bridge_type
        bridge_type=$(grep "^Bridge " "$TOR_CONFIG" | \
            awk '{print $2}' | head -1)
        [ -n "$bridge_type" ] && extra="${extra} | bridge:${bridge_type}"
    fi

    echo "${green}ACTIVE${extra}${reset}"
}

getTorAutostart() {
    systemctl is-enabled --quiet "$TOR_SVC" 2>/dev/null \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

getTorCountry() {
    grep "^ExitNodes" "$TOR_CONFIG" 2>/dev/null | \
        grep -oP '\{[A-Z]+\}' | tr -d '{}' | head -1
}

getTorBridgeType() {
    if grep -q "^UseBridges 1" "$TOR_CONFIG" 2>/dev/null; then
        grep "^Bridge " "$TOR_CONFIG" | awk '{print $2}' | head -1
    else
        echo "нет"
    fi
}

# =================================================================
# ЗЕРКАЛА РЕПОЗИТОРИЯ TOR
#
# Приоритет:
#   1. deb.torproject.org    — официальный (заблокирован в РФ и ряде других стран)
#   2. tor.eff.org           — зеркало EFF, идентично официальному, тот же GPG ключ
#   3. mirror.torproject.org — официальное зеркало Tor Project
#
# GPG ключ один для всех зеркал — пакеты подписаны Tor Project,
# зеркало только раздаёт файлы.
# =================================================================
_TOR_MIRRORS=(
    "deb.torproject.org/torproject.org"
    "tor.eff.org/torproject.org"
    "mirror.torproject.org/debian"
)

# Fingerprint GPG ключа Tor Project
_TOR_GPG_FP="A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89"

# =================================================================
# ПОИСК ДОСТУПНОГО ЗЕРКАЛА
# Перебирает зеркала с таймаутом 5 сек на каждое.
# Выводит hostname первого доступного зеркала (без https://).
# =================================================================
_findTorMirror() {
    local mirror
    for mirror in "${_TOR_MIRRORS[@]}"; do
        printf "  Проверяем https://%s ... " "$mirror"
        local code
        code=$(curl -fsSL \
            --connect-timeout 5 \
            --max-time 5 \
            -o /dev/null \
            -w "%{http_code}" \
            "https://${mirror}" 2>/dev/null)
        if [[ "$code" =~ ^[23] ]]; then
            echo "${green}OK${reset}"
            echo "$mirror"
            return 0
        else
            echo "${yellow}недоступен (${code:-timeout})${reset}"
        fi
    done
    return 1
}

# =================================================================
# ЗАГРУЗКА GPG КЛЮЧА TOR PROJECT
# Пробует скачать с найденного зеркала, затем остальные,
# затем keyserver как последний резерв.
# =================================================================
_fetchTorGpgKey() {
    local primary_mirror="$1"
    local keyring="/usr/share/keyrings/tor-archive-keyring.gpg"
    local mirror

    # Сначала пробуем primary_mirror, затем остальные (исключая дубликат)
    for mirror in "${_TOR_MIRRORS[@]}"; do
        [ "$mirror" = "$primary_mirror" ] && continue
        local asc_url="https://${mirror}/${_TOR_GPG_FP}.asc"
        if curl -fsSL \
                --connect-timeout 8 \
                --max-time 15 \
                "$asc_url" \
                | gpg --dearmor -o "$keyring" 2>/dev/null; then
            return 0
        fi
    done

    # Последний резерв — keyserver
    echo "${yellow}Пробуем получить ключ с keyserver.ubuntu.com...${reset}"
    if gpg --keyserver keyserver.ubuntu.com \
           --recv-keys "$_TOR_GPG_FP" 2>/dev/null && \
       gpg --export "$_TOR_GPG_FP" | gpg --dearmor -o "$keyring" 2>/dev/null; then
        return 0
    fi

    echo "${red}Не удалось получить GPG ключ Tor Project${reset}"
    return 1
}

# =================================================================
# УСТАНОВКА ИЗ КОНКРЕТНОГО ЗЕРКАЛА (apt-репо)
# mirror — hostname без https://, например: tor.eff.org/torproject.org
# =================================================================
_installTorFromMirror() {
    local mirror="$1"
    local codename="$2"

    echo "${cyan}Используем зеркало: https://${mirror}${reset}"
    installPackage "apt-transport-https gpg" || true

    _fetchTorGpgKey "$mirror" || return 1

    cat > /etc/apt/sources.list.d/tor.list << EOF
deb [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://${mirror} ${codename} main
deb-src [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://${mirror} ${codename} main
EOF

    # Обновляем только добавленный репо — экономим время
    apt-get update \
        -o Dir::Etc::sourcelist="sources.list.d/tor.list" \
        -o Dir::Etc::sourceparts="-" \
        -o APT::Get::List-Cleanup="0" &>/dev/null || \
        ${PACKAGE_MANAGEMENT_UPDATE} &>/dev/null || true

    if installPackage "tor deb.torproject.org-keyring"; then
        xpro_conf_set "TOR_MIRROR" "$mirror"
        return 0
    fi

    # Не вышло — чистим за собой чтобы не сломать apt
    echo "${yellow}Установка из этого зеркала не удалась, откатываем sources.list...${reset}"
    rm -f /etc/apt/sources.list.d/tor.list \
          /usr/share/keyrings/tor-archive-keyring.gpg
    return 1
}

# =================================================================
# УСТАНОВКА ИЗ СИСТЕМНОГО РЕПО (финальный fallback)
# Версия может быть старее официальной.
# =================================================================
_installTorFromSystemRepo() {
    echo "${cyan}Устанавливаем Tor из системного репозитория...${reset}"
    echo "${yellow}Версия может быть старее официальной.${reset}"
    installPackage "tor" || {
        echo "${red}Не удалось установить Tor${reset}"
        return 1
    }
}

# =================================================================
# УСТАНОВКА TOR — ГЛАВНАЯ ФУНКЦИЯ
#
# Логика выбора источника:
#   1. Перебираем зеркала (официальный + EFF + mirror), 5 сек на каждое
#   2. Нашли зеркало → устанавливаем из него (актуальная версия)
#   3. Зеркало нашли, установка упала → следующее зеркало
#   4. Все зеркала недоступны → системный репо
# =================================================================
installTor() {
    if command -v tor &>/dev/null; then
        echo "info: Tor уже установлен"
        return 0
    fi

    echo "${cyan}Установка Tor...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS

    if command -v apt &>/dev/null; then
        local codename
        codename=$(lsb_release -sc 2>/dev/null || \
            (. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}"))

        if [ -n "$codename" ]; then
            echo "${cyan}Поиск доступного репозитория Tor...${reset}"

            local mirror installed=0
            if mirror=$(_findTorMirror); then
                # Строим список: найденное зеркало первым, остальные без него
                local try_mirrors=("$mirror")
                local m
                for m in "${_TOR_MIRRORS[@]}"; do
                    [ "$m" != "$mirror" ] && try_mirrors+=("$m")
                done

                for m in "${try_mirrors[@]}"; do
                    echo "${yellow}Пробуем зеркало: ${m}${reset}"
                    _installTorFromMirror "$m" "$codename" && installed=1 && break
                done
            fi

            if [ "$installed" -eq 0 ]; then
                echo "${yellow}Все зеркала исчерпаны, используем системный репо${reset}"
                _installTorFromSystemRepo || return 1
            fi
        else
            _installTorFromSystemRepo || return 1
        fi

    else
        # dnf/yum — системный репо (EPEL для CentOS)
        installPackage "tor" || {
            echo "${red}Не удалось установить Tor${reset}"
            return 1
        }
    fi

    # GeoIP для ExitNodes по странам
    installPackage "tor-geoipdb" 2>/dev/null || \
        installPackage "geoip-database" 2>/dev/null || true

    # Обфускация мостов
    installPackage "obfs4proxy" 2>/dev/null || true

    local ver
    ver=$(tor --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
    echo "${green}Tor установлен${ver:+ v${ver}}${reset}"
}

upgradeTor() {
    echo "${cyan}Обновление Tor...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS

    if command -v apt &>/dev/null; then
        # Если репо уже добавлен — пробуем обновить его индекс через сохранённое зеркало
        if [ -f /etc/apt/sources.list.d/tor.list ]; then
            local saved_mirror reachable=0
            saved_mirror=$(xpro_conf_get "TOR_MIRROR" 2>/dev/null || true)

            if [ -n "$saved_mirror" ]; then
                local code
                code=$(curl -fsSL --connect-timeout 5 --max-time 5 \
                    -o /dev/null -w "%{http_code}" \
                    "https://${saved_mirror}" 2>/dev/null)
                [[ "$code" =~ ^[23] ]] && reachable=1
            fi

            if [ "$reachable" -eq 1 ]; then
                apt-get update \
                    -o Dir::Etc::sourcelist="sources.list.d/tor.list" \
                    -o Dir::Etc::sourceparts="-" \
                    -o APT::Get::List-Cleanup="0" &>/dev/null || true
            else
                echo "${yellow}Зеркало ${saved_mirror:-tor repo} недоступно, обновляем из кэша${reset}"
            fi
        fi

        apt-get install -y --only-upgrade tor tor-geoipdb 2>/dev/null || \
            apt-get install -y tor tor-geoipdb 2>/dev/null || true
    else
        ${PACKAGE_MANAGEMENT_INSTALL} tor || true
    fi

    systemctl restart tor
    echo "${green}Tor обновлён: $(tor --version 2>/dev/null | head -1)${reset}"
}

# =================================================================
# КОНФИГУРАЦИЯ torrc
# =================================================================
configTor() {
    local country="${1:-}"
    local bridge_type="${2:-}"  # "" | obfs4 | snowflake | meek-azure

    cat > "$TOR_CONFIG" << EOF
SocksPort 127.0.0.1:${TOR_PORT}
ControlPort 127.0.0.1:${TOR_CONTROL_PORT}
SocksPolicy accept 127.0.0.1
Log notice file /var/log/tor/notices.log
DataDirectory /var/lib/tor
EOF

    # Страна выхода
    if [ -n "$country" ] && [ "$country" != "xx" ]; then
        cat >> "$TOR_CONFIG" << EOF
ExitNodes {${country^^}}
StrictNodes 1
EOF
    fi

    # Мосты
    case "$bridge_type" in
        obfs4)
            cat >> "$TOR_CONFIG" << 'EOF'
UseBridges 1
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
EOF
            # Если есть сохранённые мосты — добавляем
            local bridges_file="/usr/local/etc/xpro/tor_bridges.txt"
            if [ -f "$bridges_file" ] && [ -s "$bridges_file" ]; then
                while IFS= read -r bridge; do
                    [ -z "$bridge" ] && continue
                    echo "Bridge $bridge" >> "$TOR_CONFIG"
                done < "$bridges_file"
            fi
            ;;
        snowflake)
            cat >> "$TOR_CONFIG" << 'EOF'
UseBridges 1
ClientTransportPlugin snowflake exec /usr/bin/snowflake-client
Bridge snowflake 0.0.3.4:1 2B280B23E1107BB62ABFC40DDCC8824814F80A72
EOF
            ;;
        meek-azure)
            cat >> "$TOR_CONFIG" << 'EOF'
UseBridges 1
ClientTransportPlugin meek_lite exec /usr/bin/obfs4proxy
Bridge meek_lite 192.0.2.2:2 B9E7141C594AF25699E0079C1F0146F409495296 url=https://meek.azureedge.net/ front=ajax.aspnetcdn.com
EOF
            ;;
        custom)
            local bridges_file="/usr/local/etc/xpro/tor_bridges.txt"
            if [ -f "$bridges_file" ] && [ -s "$bridges_file" ]; then
                echo "UseBridges 1" >> "$TOR_CONFIG"
                # Определяем тип первого моста для ClientTransportPlugin
                local first_type
                first_type=$(head -1 "$bridges_file" | awk '{print $1}')
                case "$first_type" in
                    obfs4)     echo "ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy" >> "$TOR_CONFIG" ;;
                    snowflake) echo "ClientTransportPlugin snowflake exec /usr/bin/snowflake-client" >> "$TOR_CONFIG" ;;
                esac
                while IFS= read -r bridge; do
                    [ -z "$bridge" ] && continue
                    echo "Bridge $bridge" >> "$TOR_CONFIG"
                done < "$bridges_file"
            fi
            ;;
    esac

    echo "${green}torrc обновлён${reset}"
}

# =================================================================
# УПРАВЛЕНИЕ СЕРВИСОМ
# =================================================================
startTor() {
    systemctl start "$TOR_SVC"
    sleep 3

    if systemctl is-active --quiet "$TOR_SVC"; then
        echo "${green}Tor запущен${reset}"
    else
        echo "${red}Tor не запустился. Проверь логи: journalctl -u tor -n 20${reset}"
        return 1
    fi
}

stopTor() {
    systemctl stop "$TOR_SVC"
    echo "${yellow}Tor остановлен${reset}"
}

enableTor() {
    systemctl enable "$TOR_SVC"
    echo "${green}Tor автозагрузка включена${reset}"
}

disableTor() {
    systemctl disable "$TOR_SVC"
    echo "${yellow}Tor автозагрузка выключена${reset}"
}

restartTor() {
    systemctl restart "$TOR_SVC"
    sleep 2
    echo "${green}Tor перезапущен${reset}"
}

# =================================================================
# УДАЛЕНИЕ
# =================================================================
removeTor() {
    echo "${yellow}Удалить Tor? (y/N)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "Отменено"; return 0; }

    systemctl stop "$TOR_SVC" 2>/dev/null || true
    systemctl disable "$TOR_SVC" 2>/dev/null || true

    uninstallPackage "tor"
    uninstallPackage "tor-geoipdb" 2>/dev/null || true

    rm -f /etc/apt/sources.list.d/tor.list
    rm -f /usr/share/keyrings/tor-archive-keyring.gpg
    rm -f /usr/local/etc/xpro/tor_bridges.txt
    systemctl daemon-reload

    xpro_conf_set "TOR_INSTALLED" "no"

    echo "${green}Tor удалён${reset}"
}

# =================================================================
# СМЕНА СТРАНЫ ВЫХОДА
# =================================================================
setTorCountry() {
    local valid_countries="AT BE BG BR CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK UA US"

    echo ""
    echo "${cyan}Страна выхода Tor:${reset}"
    echo "  ${green}0.${reset} Случайная (без фиксации)"
    echo ""
    echo "  Доступные: $valid_countries"
    echo ""
    read -rp "  Введи код страны (или 0 для случайной): " country_input

    local current_bridge_type
    current_bridge_type=$(getTorBridgeType)
    [ "$current_bridge_type" = "нет" ] && current_bridge_type=""

    if [ "$country_input" = "0" ] || [ -z "$country_input" ]; then
        # Убираем ExitNodes из конфига
        sed -i '/^ExitNodes/d; /^StrictNodes/d' "$TOR_CONFIG" 2>/dev/null
        echo "${green}Страна выхода: случайная${reset}"
    else
        country_input="${country_input^^}"
        # Валидация
        if ! echo "$valid_countries" | grep -qw "$country_input"; then
            echo "${red}Неверный код страны: $country_input${reset}"
            echo "Допустимые: $valid_countries"
            return 1
        fi

        # Обновляем ExitNodes в torrc
        if grep -q "^ExitNodes" "$TOR_CONFIG" 2>/dev/null; then
            sed -i "s/^ExitNodes.*/ExitNodes {${country_input}}/" "$TOR_CONFIG"
        else
            echo "ExitNodes {${country_input}}" >> "$TOR_CONFIG"
            echo "StrictNodes 1" >> "$TOR_CONFIG"
        fi

        echo "${green}Страна выхода: ${country_input}${reset}"
    fi

    xpro_conf_set "TOR_COUNTRY" "${country_input:-xx}"
    restartTor
}

# =================================================================
# НАСТРОЙКА МОСТОВ
# =================================================================
configureTorBridges() {
    echo ""
    echo "${cyan}Мосты Tor (для обхода блокировок Tor):${reset}"
    echo "  ${green}1.${reset} obfs4        (рекомендуется)"
    echo "  ${green}2.${reset} snowflake    (через WebRTC)"
    echo "  ${green}3.${reset} meek-azure   (маскировка под Azure CDN)"
    echo "  ${green}4.${reset} Свои мосты  (вставить вручную)"
    echo "  ${green}5.${reset} Отключить мосты"
    echo ""
    read -rp "  Выбор: " bridge_choice

    local current_country
    current_country=$(getTorCountry)

    case "$bridge_choice" in
        1)
            echo ""
            echo "${yellow}Мосты obfs4 можно получить на:${reset}"
            echo "  https://bridges.torproject.org/options"
            echo "  Email: bridges@torproject.org"
            echo ""
            echo "${cyan}Вставь мосты (по одному на строку, пустая строка для завершения):${reset}"
            echo "${cyan}Формат: obfs4 IP:PORT FINGERPRINT cert=... iat-mode=0${reset}"
            echo ""

            local bridges_file="/usr/local/etc/xpro/tor_bridges.txt"
            mkdir -p /usr/local/etc/xpro
            > "$bridges_file"

            while true; do
                read -rp "  Bridge: " bridge_line
                [ -z "$bridge_line" ] && break
                echo "$bridge_line" >> "$bridges_file"
            done

            if [ -s "$bridges_file" ]; then
                configTor "$current_country" "obfs4"
                xpro_conf_set "TOR_BRIDGE_TYPE" "obfs4"
                echo "${green}obfs4 мосты настроены${reset}"
            else
                echo "${yellow}Мосты не введены, используем встроенные obfs4${reset}"
                configTor "$current_country" "obfs4"
                xpro_conf_set "TOR_BRIDGE_TYPE" "obfs4"
            fi
            ;;
        2)
            # Snowflake — проверяем наличие бинаря
            if ! command -v snowflake-client &>/dev/null; then
                echo "${yellow}Устанавливаем snowflake-client...${reset}"
                installPackage "snowflake-client" 2>/dev/null || {
                    echo "${red}snowflake-client недоступен в репозитории${reset}"
                    echo "${yellow}Установи вручную: apt install snowflake-client${reset}"
                    return 1
                }
            fi
            configTor "$current_country" "snowflake"
            xpro_conf_set "TOR_BRIDGE_TYPE" "snowflake"
            echo "${green}snowflake мост настроен${reset}"
            ;;
        3)
            if ! command -v obfs4proxy &>/dev/null; then
                installPackage "obfs4proxy" || {
                    echo "${red}obfs4proxy не установлен (нужен для meek)${reset}"
                    return 1
                }
            fi
            configTor "$current_country" "meek-azure"
            xpro_conf_set "TOR_BRIDGE_TYPE" "meek-azure"
            echo "${green}meek-azure мост настроен${reset}"
            ;;
        4)
            echo ""
            echo "${cyan}Вставь мосты (по одному на строку, пустая строка для завершения):${reset}"
            echo "${cyan}Формат: тип IP:PORT FINGERPRINT [параметры]${reset}"
            echo ""

            local bridges_file="/usr/local/etc/xpro/tor_bridges.txt"
            mkdir -p /usr/local/etc/xpro
            > "$bridges_file"

            while true; do
                read -rp "  Bridge: " bridge_line
                [ -z "$bridge_line" ] && break
                echo "$bridge_line" >> "$bridges_file"
            done

            if [ -s "$bridges_file" ]; then
                configTor "$current_country" "custom"
                xpro_conf_set "TOR_BRIDGE_TYPE" "custom"
                echo "${green}Кастомные мосты настроены${reset}"
            else
                echo "${yellow}Мосты не введены${reset}"
                return 1
            fi
            ;;
        5)
            # Убираем все bridge-настройки из torrc
            sed -i '/^UseBridges/d; /^ClientTransportPlugin/d; /^Bridge /d' \
                "$TOR_CONFIG" 2>/dev/null
            xpro_conf_set "TOR_BRIDGE_TYPE" ""
            echo "${green}Мосты отключены${reset}"
            ;;
        *)
            echo "${red}Отменено${reset}"
            return 1
            ;;
    esac

    restartTor
}

# =================================================================
# ПРОВЕРКА IP
# =================================================================
checkTorIP() {
    echo "${cyan}Проверяем IP через Tor...${reset}"
    echo "${yellow}Tor медленный, ожидайте до 30 секунд...${reset}"
    checkServiceIP "socks5://127.0.0.1:${TOR_PORT}" "Tor"
}

# =================================================================
# МЕНЮ TOR
# =================================================================
torMenu() {
    while true; do
        clear
        local status autostart country bridge_type
        status=$(getTorStatus)
        autostart=$(getTorAutostart)
        country=$(getTorCountry)
        [ -z "$country" ] && country="random"
        bridge_type=$(getTorBridgeType)

        echo ""
        echo "${cyan}══════════════════════════════════════${reset}"
        echo "${cyan}  Tor${reset}"
        echo "${cyan}══════════════════════════════════════${reset}"
        echo ""
        echo "  Статус:      $status"
        echo "  Автозагрузка: $autostart"
        echo "  Страна:      $country"
        echo "  Мосты:       $bridge_type"
        echo "  Порт:        socks5://127.0.0.1:${TOR_PORT}"
        echo ""

        if ! command -v tor &>/dev/null; then
            echo "  ${green}1.${reset} Установить Tor"
        else
            local is_active
            is_active=$(systemctl is-active "$TOR_SVC" 2>/dev/null)
            if [ "$is_active" = "active" ]; then
                echo "  ${green}1.${reset} Остановить Tor"
            else
                echo "  ${green}1.${reset} Запустить Tor"
            fi

            local is_enabled
            is_enabled=$(systemctl is-enabled "$TOR_SVC" 2>/dev/null)
            if [ "$is_enabled" = "enabled" ]; then
                echo "  ${green}2.${reset} Выключить автозагрузку"
            else
                echo "  ${green}2.${reset} Включить автозагрузку"
            fi

            echo "  ${green}3.${reset} Сменить страну выхода"
            echo "  ${green}4.${reset} Настроить мосты"
            echo "  ${green}5.${reset} Обновить Tor"
        fi

        echo "  ${green}6.${reset} Проверить IP"
        echo "  ${red}7.${reset} Удалить Tor"
        echo "  ${green}0.${reset} Назад"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1)
                if ! command -v tor &>/dev/null; then
                    installTor && configTor && startTor && enableTor
                else
                    local is_active
                    is_active=$(systemctl is-active "$TOR_SVC" 2>/dev/null)
                    if [ "$is_active" = "active" ]; then stopTor
                    else startTor; fi
                fi
                sleep 1
                ;;
            2)
                ! command -v tor &>/dev/null && { echo "${red}Tor не установлен${reset}"; sleep 1; continue; }
                local is_enabled
                is_enabled=$(systemctl is-enabled "$TOR_SVC" 2>/dev/null)
                if [ "$is_enabled" = "enabled" ]; then disableTor
                else enableTor; fi
                sleep 1
                ;;
            3)
                ! command -v tor &>/dev/null && { echo "${red}Tor не установлен${reset}"; sleep 1; continue; }
                setTorCountry; read -r
                ;;
            4)
                ! command -v tor &>/dev/null && { echo "${red}Tor не установлен${reset}"; sleep 1; continue; }
                configureTorBridges; read -r
                ;;
            5)
                ! command -v tor &>/dev/null && { echo "${red}Tor не установлен${reset}"; sleep 1; continue; }
                upgradeTor; read -r
                ;;
            6) checkTorIP; read -r ;;
            7) removeTor; read -r ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}
