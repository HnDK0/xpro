#!/bin/bash
# =================================================================
# xui.sh — 3x-ui MHSanaei: установка, обновление, БД функции
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

    # Убираем встроенный SSL панели — nginx терминирует TLS сам,
    # proxy_pass http:// сломается если панель слушает на HTTPS
    echo "${cyan}Отключаем встроенный SSL панели...${reset}"
    sqlite3 "$XUI_DB" "UPDATE settings SET value='' WHERE key IN \
        ('webCertFile','webKeyFile','subCertFile','subKeyFile');" 2>/dev/null || true
    x-ui restart 2>/dev/null || systemctl restart x-ui 2>/dev/null || true
    sleep 2

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
# БД ФУНКЦИИ — прямая модификация sqlite БД 3x-ui
# =================================================================

# Записать все три outbound'а (warp/tor/psiphon) в xrayTemplateConfig.
# Читаем полный текущий конфиг, удаляем только наши теги,
# добавляем все три заново, пишем полный объект обратно.
# Остальные поля (dns, routing, policy, log и т.д.) не трогаем.
xuiDbWriteOutbounds() {
    echo "${cyan}Записываем outbound'ы warp/tor/psiphon в xrayTemplateConfig...${reset}"

    [ -f "$XUI_DB" ] || {
        echo "${red}Ошибка: База 3x-ui не найдена (${XUI_DB})${reset}"
        return 1
    }

    python3 << EOF
import sqlite3, json, sys

db = sqlite3.connect('${XUI_DB}')
cur = db.cursor()

# Читаем полный текущий шаблон. Если записи ещё нет (первый запуск до входа
# в панель) — создаём минимальный валидный шаблон, который x-ui примет.
cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'")
row = cur.fetchone()
if row:
    config = json.loads(row[0])
else:
    # Базовый шаблон — идентичен дефолту 3x-ui (mhsanaei)
    config = {
        "log":    {"access": "none", "dnsLog": False, "error": "", "loglevel": "warning", "maskAddress": ""},
        "api":    {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]},
        "inbounds": [{"tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "tunnel", "settings": {"address": "127.0.0.1"}}],
        "outbounds": [
            {"tag": "direct",  "protocol": "freedom",   "settings": {"domainStrategy": "AsIs", "redirect": "", "noises": []}},
            {"tag": "blocked", "protocol": "blackhole",  "settings": {}}
        ],
        "policy": {
            "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
            "system": {"statsInboundDownlink": True, "statsInboundUplink": True, "statsOutboundDownlink": False, "statsOutboundUplink": False}
        },
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
                {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
                {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]}
            ]
        },
        "stats": {},
        "metrics": {"tag": "metrics_out", "listen": "127.0.0.1:11111"}
    }
    print("info: xrayTemplateConfig не найден — создаём базовый шаблон")

# Удаляем только наши теги — всё остальное (direct, block и т.д.) не трогаем
our_tags = {'warp', 'tor', 'psiphon'}
clean = [o for o in config.get('outbounds', []) if o.get('tag') not in our_tags]

# Добавляем все три всегда — неиспользуемые outbound'ы без routing rules не влияют на трафик
clean += [
    {
        "tag": "warp",
        "protocol": "socks",
        "settings": {"servers": [{"address": "127.0.0.1", "port": ${WARP_PORT:-40000}}]}
    },
    {
        "tag": "tor",
        "protocol": "socks",
        "settings": {"servers": [{"address": "127.0.0.1", "port": ${TOR_PORT:-40003}}]}
    },
    {
        "tag": "psiphon",
        "protocol": "socks",
        "settings": {"servers": [{"address": "127.0.0.1", "port": ${PSIPHON_PORT:-40002}}]}
    }
]

config['outbounds'] = clean

# Пишем полный объект обратно
cur.execute(
    "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)",
    (json.dumps(config, indent=2),)
)
db.commit()
db.close()
print("Outbound'ы warp/tor/psiphon записаны")
EOF

    local rc=$?
    [ $rc -ne 0 ] && { echo "${red}Ошибка при записи outbound'ов${reset}"; return 1; }

    x-ui restart 2>/dev/null || systemctl restart x-ui 2>/dev/null || true
    sleep 2
    echo "${green}Outbound'ы записаны. Routing настраивается в панели 3x-ui.${reset}"
}

# =================================================================
# НАСТРОЙКА ПОДПИСКИ ЧЕРЕЗ БД
# =================================================================
xuiDbSetSubSettings() {
    local domain="$1"
    local sub_path="${2:-}"
    local sub_port="${3:-}"

    echo "${cyan}Настройка подписки через БД...${reset}"

    [ -f "$XUI_DB" ] || {
        echo "${red}Ошибка: База 3x-ui не найдена (${XUI_DB})${reset}"
        return 1
    }

    # Генерируем рандомный путь если не передан
    if [ -z "$sub_path" ]; then
        sub_path=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)
    fi
    sub_path="${sub_path#/}"; sub_path="${sub_path%/}"

    # Порт: берём из БД если уже есть, иначе 2096
    if [ -z "$sub_port" ]; then
        sub_port=$(sqlite3 "$XUI_DB" \
            "SELECT value FROM settings WHERE key='subPort' LIMIT 1;" 2>/dev/null)
        sub_port="${sub_port:-2096}"
    fi

    # Пишем напрямую в БД — SQLite сам лочит запись, останавливать x-ui не нужно
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('subDomain', '${domain}');"
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('subPort', '${sub_port}');"
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('subPath', '/${sub_path}');"
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('subJsonPath', '/${sub_path}/json');"
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('subEnable', '1');"

    # Убираем встроенный SSL — панель и подписка должны слушать HTTP,
    # TLS терминируется на nginx
    sqlite3 "$XUI_DB" "UPDATE settings SET value='' WHERE key IN \
        ('webCertFile','webKeyFile','subCertFile','subKeyFile');" 2>/dev/null || true

    x-ui restart 2>/dev/null || systemctl restart x-ui 2>/dev/null || true
    sleep 2

    # Сохраняем в xpro.conf с trailing slash
    xpro_conf_set "XUI_SUB_PATH" "/${sub_path}/"

    echo "${green}Подписка настроена:${reset}"
    echo "${green}  Домен: ${domain}${reset}"
    echo "${green}  Путь: /${sub_path}/${reset}"
    echo "${green}  Порт: ${sub_port}${reset}"

    # Примечание: syncXrayInbounds НЕ вызываем здесь —
    # эта функция вызывается до установки nginx, файла xpro.conf ещё нет.
    # Синхронизацию выполняет install.sh после writeNginxConfig (шаг 5).
}

# Получить текущие настройки подписки
xuiDbGetSubSettings() {
    [ -f "$XUI_DB" ] || { echo "${red}БД не найдена${reset}"; return 1; }
    
    local domain port path json_path enabled
    domain=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subDomain' LIMIT 1;" 2>/dev/null)
    port=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort' LIMIT 1;" 2>/dev/null)
    path=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPath' LIMIT 1;" 2>/dev/null)
    json_path=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subJsonPath' LIMIT 1;" 2>/dev/null)
    enabled=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subEnable' LIMIT 1;" 2>/dev/null)
    
    echo "  subEnable:   ${enabled:-0}"
    echo "  subDomain:   ${domain:-не задан}"
    echo "  subPort:     ${port:-2096}"
    echo "  subPath:     ${path:-/sub}"
    echo "  subJsonPath: ${json_path:-/sub/json}"
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

    echo ""
    echo "${cyan}  WS inbound'ы:${reset}"
    local ws_found=0
    while IFS='|' read -r remark port network ws_path grpc_service xhttp_path; do
        [ "$network" != "ws" ] && continue
        printf "    ${green}%-20s${reset}  порт: %-6s  path: %s\n" "$remark" "$port" "$ws_path"
        ws_found=1
    done < <(sqlite3 "$XUI_DB" \
        "SELECT remark, port,
            json_extract(stream_settings, '$.network'),
            json_extract(stream_settings, '$.wsSettings.path'),
            json_extract(stream_settings, '$.grpcSettings.serviceName'),
            json_extract(stream_settings, '$.xhttpSettings.path')
         FROM inbounds WHERE protocol IN ('vless','vmess','trojan');")
    [ "$ws_found" -eq 0 ] && echo "    нет"

    echo ""
    echo "${cyan}  gRPC inbound'ы:${reset}"
    local grpc_found=0
    while IFS='|' read -r remark port network ws_path grpc_service xhttp_path; do
        [ "$network" != "grpc" ] && continue
        printf "    ${green}%-20s${reset}  порт: %-6s  service: %s\n" "$remark" "$port" "$grpc_service"
        grpc_found=1
    done < <(sqlite3 "$XUI_DB" \
        "SELECT remark, port,
            json_extract(stream_settings, '$.network'),
            json_extract(stream_settings, '$.wsSettings.path'),
            json_extract(stream_settings, '$.grpcSettings.serviceName'),
            json_extract(stream_settings, '$.xhttpSettings.path')
         FROM inbounds WHERE protocol IN ('vless','vmess','trojan');")
    [ "$grpc_found" -eq 0 ] && echo "    нет"

    echo ""
    echo "${cyan}  xHTTP inbound'ы:${reset}"
    local xhttp_found=0
    while IFS='|' read -r remark port network ws_path grpc_service xhttp_path; do
        [ "$network" != "xhttp" ] && continue
        printf "    ${green}%-20s${reset}  порт: %-6s  path: %s\n" "$remark" "$port" "$xhttp_path"
        xhttp_found=1
    done < <(sqlite3 "$XUI_DB" \
        "SELECT remark, port,
            json_extract(stream_settings, '$.network'),
            json_extract(stream_settings, '$.wsSettings.path'),
            json_extract(stream_settings, '$.grpcSettings.serviceName'),
            json_extract(stream_settings, '$.xhttpSettings.path')
         FROM inbounds WHERE protocol IN ('vless','vmess','trojan');")
    [ "$xhttp_found" -eq 0 ] && echo "    нет"

    echo ""
    echo "${cyan}  Подписка:${reset}"
    local sub_enabled sub_port sub_path domain
    sub_enabled=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subEnable' LIMIT 1;" 2>/dev/null)
    sub_port=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort' LIMIT 1;" 2>/dev/null)
    sub_path=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPath' LIMIT 1;" 2>/dev/null)
    domain=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subDomain' LIMIT 1;" 2>/dev/null)
    
    if [ "${sub_enabled:-0}" = "1" ]; then
        printf "    ${green}%-20s${reset}  порт: %-6s  path: %s\n" \
            "subscription" "${sub_port:-2096}" "${sub_path:-/sub}"
        printf "    URL: ${cyan}https://%s%s${reset}\n" "${domain:-?}" "${sub_path:-/sub}"
    else
        echo "    ${yellow}отключена${reset}"
    fi
    echo ""
}

# =================================================================
# ОТКЛЮЧЕНИЕ ВСТРОЕННОГО SSL ПАНЕЛИ
# nginx терминирует TLS сам — панель должна слушать HTTP
# =================================================================
xuiDisablePanelSsl() {
    [ -f "$XUI_DB" ] || { echo "${red}БД не найдена${reset}"; return 1; }
    sqlite3 "$XUI_DB" "UPDATE settings SET value='' WHERE key IN \
        ('webCertFile','webKeyFile','subCertFile','subKeyFile');" 2>/dev/null
    x-ui restart 2>/dev/null || systemctl restart x-ui 2>/dev/null || true
    echo "${green}Встроенный SSL панели отключён${reset}"
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
        echo "  Пароль:   $(xpro_conf_get XUI_PASS)"
        echo ""
        echo "  ${green}1.${reset} Перезапустить 3x-ui"
        echo "  ${green}2.${reset} Обновить 3x-ui"
        echo "  ${green}3.${reset} Показать credentials"
        echo "  ${green}4.${reset} Сменить порт панели"
        echo "  ${green}5.${reset} Показать WS/gRPC/xHTTP inbound'ы"
        echo "  ${green}6.${reset} Синхронизировать inbound'ы → Nginx"
        echo "  ${green}7.${reset} Настроить подписку"
        echo "  ${green}8.${reset} Показать настройки подписки"
        echo "  ${green}9.${reset} Отключить встроенный SSL панели"
        echo "  ${green}10.${reset} Пересоздать outbound'ы Xray (warp/tor/psiphon)"
        echo "  ${red}11.${reset} Удалить 3x-ui"
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
                xuiShowInbounds
                read -r
                ;;
            6)
                if declare -f syncXrayInbounds &>/dev/null; then
                    syncXrayInbounds
                else
                    local lib="${XPRO_LIB}/nginx.sh"
                    [ -f "$lib" ] && source "$lib" && syncXrayInbounds \
                        || echo "${red}nginx.sh не найден${reset}"
                fi
                read -r
                ;;
            7)
                echo ""
                read -rp "  Домен для подписки: " sub_domain
                read -rp "  Путь подписки (Enter для случайного): " sub_path
                read -rp "  Порт подписки (Enter для текущего/2096): " sub_port
                xuiDbSetSubSettings "$sub_domain" "$sub_path" "$sub_port"
                read -r
                ;;
            8)
                echo ""
                xuiDbGetSubSettings
                read -r
                ;;
            9)
                xuiDisablePanelSsl
                read -r
                ;;
            10)
                xuiDbWriteOutbounds
                read -r
                ;;
            11)
                remove3xui
                read -r
                ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}