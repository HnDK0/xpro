#!/bin/bash
# =================================================================
# xui.sh — 3x-ui MHSanaei: установка, обновление, API
# =================================================================

XUI_DIR="/usr/local/x-ui"
XUI_DB="/etc/x-ui/x-ui.db"
XUI_BIN="/usr/local/bin/x-ui"
XUI_SERVICE="x-ui"

# =================================================================
# УСТАНОВКА
# =================================================================
install3xui() {
    local panel="${1:-mhsanaei}"
    local xui_user="${2:-}"
    local xui_pass="${3:-}"
    local xui_port="${4:-}"
    local xui_path="${5:-}"

    echo "${cyan}Установка 3x-ui (${panel})...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS

    case "$panel" in
        mhsanaei)
            bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< $'\n'
            ;;
        alireza)
            bash <(curl -Ls https://raw.githubusercontent.com/alireza0/x-ui/master/install.sh) <<< $'\n'
            ;;
        *)
            echo "${red}Неизвестная панель: $panel${reset}"
            return 1
            ;;
    esac

    # Ждём запуска
    sleep 3
    systemctl enable x-ui &>/dev/null

    # Перезаписываем credentials если переданы
    if [ -n "$xui_user" ]; then
        echo "${cyan}Настройка credentials 3x-ui...${reset}"
        /usr/local/x-ui/x-ui setting -username "$xui_user" -password "$xui_pass" \
            -port "$xui_port" -webBasePath "$xui_path" &>/dev/null
        systemctl restart x-ui
        sleep 2
    fi

    echo "${green}3x-ui установлен${reset}"
    [ -n "$xui_port" ] && echo "${green}  Порт: ${xui_port}${reset}"
    [ -n "$xui_path" ] && echo "${green}  Путь: /${xui_path}/${reset}"
}

update3xui() {
    echo "${cyan}Обновление 3x-ui...${reset}"
    local current_ver
    current_ver=$(x-ui version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    echo "Текущая версия: $current_ver"

    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< $'\n'
    systemctl restart x-ui
    echo "${green}3x-ui обновлён${reset}"
}

remove3xui() {
    echo "${red}Удаление 3x-ui...${reset}"
    echo "${yellow}Это удалит все inbound'ы и пользователей. Продолжить? (y/N)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "Отменено"; return 0; }

    systemctl stop x-ui 2>/dev/null || true
    systemctl disable x-ui 2>/dev/null || true

    # Удаляем outbound'ы из xpro.conf
    xpro_conf_del "XUI_PORT"
    xpro_conf_del "XUI_USER"
    xpro_conf_del "XUI_PASS"

    x-ui uninstall 2>/dev/null || {
        rm -rf "$XUI_DIR"
        rm -f "$XUI_BIN"
        rm -f /etc/systemd/system/x-ui.service
        systemctl daemon-reload
    }

    echo "${green}3x-ui удалён${reset}"
}

# =================================================================
# ПОРТ И CREDENTIALS
# Источник правды: x-ui settings (официальная команда 3x-ui)
# =================================================================

# Парсим вывод x-ui settings: "key: value"
_xui_settings_get() {
    local key="$1"
    x-ui settings 2>/dev/null \
        | grep -i "^${key}:" \
        | sed "s/^${key}:[[:space:]]*//" \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

xuiGetPort() {
    local port
    port=$(_xui_settings_get "port")
    echo "${port:-2053}"
}

xuiGetUser() {
    _xui_settings_get "username"
}

xuiGetPass() {
    _xui_settings_get "password"
}

# WebBasePath — рандомный путь панели (генерируется 3x-ui при установке)
xuiGetWebBasePath() {
    local path
    path=$(_xui_settings_get "webBasePath")
    # Убираем пробелы, слеши — приводим к формату /path/
    path=$(echo "$path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^/*||' -e 's|/*$||')
    if [ -n "$path" ]; then
        echo "/${path}/"
    else
        echo "/"
    fi
}

xuiSetPort() {
    local new_port="$1"
    x-ui setting -port "$new_port" &>/dev/null
    systemctl restart x-ui 2>/dev/null || true
    echo "${green}Порт панели изменён на ${new_port}${reset}"
}

# Ждём пока 3x-ui инициализирует БД и сгенерирует credentials
xuiWaitForDB() {
    local timeout="${1:-15}"
    local elapsed=0
    echo -n "  Ожидание инициализации БД"
    while [ "$elapsed" -lt "$timeout" ]; do
        # Первичный маркер: файл БД существует и не пустой
        if [ -f "$XUI_DB" ] && [ -s "$XUI_DB" ]; then
            local test_port test_user
            test_port=$(xpro_conf_get "XUI_PORT")
            test_user=$(xpro_conf_get "XUI_USER")
            # Порт должен быть числом, user — непустым
            if [[ "$test_port" =~ ^[0-9]+$ ]] && [ -n "$test_user" ]; then
                echo " [OK]"
                return 0
            fi
        fi
        sleep 1
        echo -n "."
        elapsed=$((elapsed + 1))
    done
    echo " [Timeout]"
    return 1
}

# =================================================================
# API — базовые функции
# =================================================================

# Получить базовый URL панели
_xuiBaseUrl() {
    local port
    port=$(xpro_conf_get "XUI_PORT")
    echo "http://127.0.0.1:${port}"
}

# Логин — возвращает session cookie в файл
_XUI_COOKIE_FILE="/tmp/xpro_xui_session"

xuiApiLogin() {
    local user pass base_url web_path login_url
    user=$(xpro_conf_get "XUI_USER")
    pass=$(xpro_conf_get "XUI_PASS")
    base_url=$(_xuiBaseUrl)
    web_path=$(xpro_conf_get "XUI_WEB_BASE_PATH")
    web_path="${web_path#/}"; web_path="${web_path%/}"

    # Путь логина зависит от WebBasePath
    if [ -n "$web_path" ]; then
        login_url="${base_url}/${web_path}/login"
    else
        login_url="${base_url}/login"
    fi

    local response
    response=$(curl -s -c "$_XUI_COOKIE_FILE" \
        -X POST "${login_url}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${user}&password=${pass}" \
        --connect-timeout 10 2>/dev/null)

    if echo "$response" | grep -q '"success":true'; then
        return 0
    else
        rm -f "$_XUI_COOKIE_FILE"
        echo "${red}Ошибка авторизации в 3x-ui API${reset}"
        echo "${yellow}Проверь credentials: user=${user}, path=/${web_path}/${reset}"
        return 1
    fi
}

# Выполнить API запрос (требует активной сессии)
_xuiApiCall() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local base_url web_path
    base_url=$(_xuiBaseUrl)
    web_path=$(xpro_conf_get "XUI_WEB_BASE_PATH")
    web_path="${web_path#/}"; web_path="${web_path%/}"

    # Если cookie нет — логинимся
    [ ! -f "$_XUI_COOKIE_FILE" ] && xuiApiLogin

    # Строим полный URL с учётом WebBasePath
    local full_url
    if [ -n "$web_path" ]; then
        full_url="${base_url}/${web_path}${endpoint}"
    else
        full_url="${base_url}${endpoint}"
    fi

    local args=(-s -b "$_XUI_COOKIE_FILE" --connect-timeout 10)
    args+=(-X "$method" "$full_url")

    if [ -n "$data" ]; then
        args+=(-H "Content-Type: application/json" -d "$data")
    fi

    local response
    response=$(curl "${args[@]}" 2>/dev/null)

    # Если сессия истекла — логинимся заново и повторяем
    if echo "$response" | grep -q '"success":false'; then
        xuiApiLogin && \
        response=$(curl "${args[@]}" 2>/dev/null)
    fi

    echo "$response"
}

# =================================================================
# API — OUTBOUND'Ы
# =================================================================

# Сформировать JSON outbound для SOCKS5
_xuiBuildSocks5Outbound() {
    local tag="$1"
    local address="$2"
    local port="$3"

    cat << EOF
{
    "tag": "${tag}",
    "protocol": "socks",
    "settings": {
        "servers": [{
            "address": "${address}",
            "port": ${port}
        }]
    },
    "streamSettings": {
        "network": "tcp"
    }
}
EOF
}

xuiApiAddOutbound() {
    local tag="$1"       # warp | tor | psiphon
    local address="$2"   # 127.0.0.1
    local port="$3"      # 40000 | 40003 | 40002

    echo "${cyan}Добавляем outbound '${tag}' в 3x-ui...${reset}"

    # Проверяем не существует ли уже
    local existing
    existing=$(xuiApiListOutbounds 2>/dev/null)
    if echo "$existing" | grep -q "\"tag\":\"${tag}\""; then
        echo "${yellow}Outbound '${tag}' уже существует, обновляем...${reset}"
        xuiApiDelOutbound "$tag" 2>/dev/null || true
        sleep 1
    fi

    local json
    json=$(_xuiBuildSocks5Outbound "$tag" "$address" "$port")

    local response
    response=$(_xuiApiCall "POST" "/xui/xray/outbounds/add" "$json")

    if echo "$response" | grep -q '"success":true'; then
        echo "${green}Outbound '${tag}' добавлен${reset}"
        xpro_conf_set "OUTBOUND_${tag^^}_ADDED" "yes"
        return 0
    else
        echo "${red}Не удалось добавить outbound '${tag}'${reset}"
        echo "${yellow}Добавь вручную в 3x-ui: Xray Configs → Outbounds → Add${reset}"
        echo "${yellow}  Protocol: SOCKS5, Address: ${address}, Port: ${port}, Tag: ${tag}${reset}"
        return 1
    fi
}

xuiApiDelOutbound() {
    local tag="$1"

    echo "${cyan}Удаляем outbound '${tag}' из 3x-ui...${reset}"

    local response
    response=$(_xuiApiCall "POST" "/xui/xray/outbounds/del/${tag}")

    if echo "$response" | grep -q '"success":true'; then
        echo "${green}Outbound '${tag}' удалён${reset}"
        xpro_conf_del "OUTBOUND_${tag^^}_ADDED"
        return 0
    else
        echo "${yellow}Outbound '${tag}' не найден или уже удалён${reset}"
        return 0
    fi
}

xuiApiListOutbounds() {
    _xuiApiCall "GET" "/xui/xray/outbounds/list"
}

xuiApiRestart() {
    local response
    response=$(_xuiApiCall "POST" "/xui/xray/restart")
    if echo "$response" | grep -q '"success":true'; then
        echo "${green}Xray перезапущен${reset}"
    else
        echo "${yellow}Перезапуск через systemctl...${reset}"
        systemctl restart x-ui 2>/dev/null || true
    fi
}

# =================================================================
# ПРОСМОТР INBOUND'ОВ (WS / gRPC) — из БД напрямую
# =================================================================
xuiShowInbounds() {
    [ -f "$XUI_DB" ] || {
        echo "${red}База 3x-ui не найдена (${XUI_DB})${reset}"
        return 1
    }
    command -v sqlite3 &>/dev/null || {
        echo "${red}sqlite3 не установлен${reset}"
        return 1
    }
    command -v jq &>/dev/null || {
        echo "${red}jq не установлен${reset}"
        return 1
    }

    echo ""
    echo "${cyan}  WS inbound'ы:${reset}"
    local ws_found=0
    while IFS='|' read -r remark port settings; do
        local path
        path=$(echo "$settings" | jq -r '.wsSettings.path // "?"' 2>/dev/null)
        printf "    ${green}%-20s${reset}  порт: %-6s  path: %s\n" "$remark" "$port" "$path"
        ws_found=1
    done < <(sqlite3 "$XUI_DB" \
        "SELECT remark, port, stream_settings FROM inbounds
         WHERE protocol IN ('vless','vmess','trojan')
         AND stream_settings LIKE '%\"network\":\"ws\"%';")
    [ "$ws_found" -eq 0 ] && echo "    нет"

    echo ""
    echo "${cyan}  gRPC inbound'ы:${reset}"
    local grpc_found=0
    while IFS='|' read -r remark port settings; do
        local service
        service=$(echo "$settings" | jq -r '.grpcSettings.serviceName // "?"' 2>/dev/null)
        printf "    ${green}%-20s${reset}  порт: %-6s  service: %s\n" "$remark" "$port" "$service"
        grpc_found=1
    done < <(sqlite3 "$XUI_DB" \
        "SELECT remark, port, stream_settings FROM inbounds
         WHERE protocol IN ('vless','vmess','trojan')
         AND stream_settings LIKE '%\"network\":\"grpc\"%';")
    [ "$grpc_found" -eq 0 ] && echo "    нет"
    echo ""
}

# =================================================================
# МЕНЮ 3x-ui
# =================================================================
manage3xuiMenu() {
    while true; do
        clear
        local port user status web_path panel_url
        port=$(xpro_conf_get "XUI_PORT")
        user=$(xpro_conf_get "XUI_USER")
        status=$(getServiceStatus x-ui)
        web_path=$(xpro_conf_get "XUI_WEB_BASE_PATH")
        local domain
        domain=$(xpro_conf_get "DOMAIN")

        # Убираем trailing slash для URL чтобы не было //
        local web_path_display="${web_path#/}"; web_path_display="${web_path_display%/}"
        if [ -n "$web_path_display" ]; then
            panel_url="https://${domain}/${web_path_display}"
        else
            panel_url="https://${domain}/  ${yellow}(путь не определён)${reset}"
        fi

        echo ""
        echo "${cyan}══════════════════════════════════════${reset}"
        echo "${cyan}  3x-ui MHSanaei${reset}"
        echo "${cyan}══════════════════════════════════════${reset}"
        echo ""
        echo "  Статус:   $status"
        echo "  Панель:   $panel_url"
        echo "  Порт:     $port"
        echo "  Логин:    $user"
        echo ""
        echo "  ${green}1.${reset} Перезапустить 3x-ui"
        echo "  ${green}2.${reset} Обновить 3x-ui"
        echo "  ${green}3.${reset} Показать credentials"
        echo "  ${green}4.${reset} Сменить порт панели"
        echo "  ${green}5.${reset} Перезапустить Xray"
        echo "  ${green}6.${reset} Список outbound'ов"
        echo "  ${green}7.${reset} Показать WS/gRPC inbound'ы"
        echo "  ${green}8.${reset} Синхронизировать inbound'ы → Nginx"
        echo "  ${red}9.${reset} Удалить 3x-ui"
        echo "  ${green}0.${reset} Назад"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1)
                systemctl restart x-ui
                echo "${green}3x-ui перезапущен${reset}"
                sleep 1
                ;;
            2)
                update3xui
                read -r
                ;;
            3)
                echo ""
                echo "  URL:     https://${domain}/${web_path_display}/"
                echo "  Логин:   $(xpro_conf_get XUI_USER)"
                echo "  Пароль:  $(xpro_conf_get XUI_PASS)"
                echo "  Порт:    $(xpro_conf_get XUI_PORT)"
                read -r
                ;;
            4)
                read -rp "  Новый порт (1024-65535): " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && \
                   [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
                    xuiSetPort "$new_port"
                else
                    echo "${red}Неверный порт${reset}"
                fi
                sleep 1
                ;;
            5)
                xuiApiLogin && xuiApiRestart
                sleep 1
                ;;
            6)
                echo ""
                xuiApiLogin && xuiApiListOutbounds | \
                    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    obs = data.get('obj', [])
    if not obs:
        print('  Outbound\'ов нет')
    for o in obs:
        print(f\"  tag={o.get('tag','?')} protocol={o.get('protocol','?')}\")
except:
    print('  Не удалось получить список')
" 2>/dev/null || echo "  Ошибка API"
                read -r
                ;;
            7)
                xuiShowInbounds
                read -r
                ;;
            8)
                if declare -f syncXrayInbounds &>/dev/null; then
                    syncXrayInbounds
                else
                    local lib="${XPRO_LIB}/nginx.sh"
                    [ -f "$lib" ] && source "$lib" && syncXrayInbounds \
                        || echo "${red}nginx.sh не найден${reset}"
                fi
                read -r
                ;;
            9)
                remove3xui
                read -r
                ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}
