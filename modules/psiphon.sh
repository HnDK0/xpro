#!/bin/bash
# =================================================================
# psiphon.sh — Psiphon: установка, управление, режимы
# SOCKS5 на 127.0.0.1:40002
# =================================================================

PSIPHON_PORT=40002
PSIPHON_BIN="/usr/local/bin/psiphon-tunnel-core"
PSIPHON_CONFIG="/usr/local/etc/xpro/psiphon.json"
PSIPHON_SERVICE="/etc/systemd/system/psiphon.service"
PSIPHON_DATA_DIR="/var/lib/psiphon"
PSIPHON_LOG="/var/log/psiphon/psiphon.log"
PSIPHON_SVC="psiphon"

# Публичные ключи из открытых клиентов Psiphon
PSIPHON_PROPAGATION_CHANNEL="FFFFFFFFFFFFFFFF"
PSIPHON_SPONSOR_ID="FFFFFFFFFFFFFFFF"
PSIPHON_REMOTE_SERVER_LIST_URL="https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed"
PSIPHON_REMOTE_SERVER_LIST_KEY="MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM="

# =================================================================
# СТАТУС
# =================================================================
getPsiphonStatus() {
    if [ ! -f "$PSIPHON_BIN" ]; then
        echo "${red}НЕ УСТАНОВЛЕН${reset}"
        return
    fi

    if ! systemctl is-active --quiet "$PSIPHON_SVC" 2>/dev/null; then
        echo "${red}STOPPED${reset}"
        return
    fi

    local extra=""

    # Страна
    if [ -f "$PSIPHON_CONFIG" ]; then
        local country
        country=$(PSIPHON_CONFIG_PATH="$PSIPHON_CONFIG" python3 -c "
import json, os
try:
    d=json.load(open(os.environ['PSIPHON_CONFIG_PATH']))
    r=d.get('EgressRegion','')
    print(r if r else '')
except: pass
" 2>/dev/null)
        [ -n "$country" ] && extra="${extra} | ${country}"
    fi

    # Режим
    local mode
    mode=$(xpro_conf_get "PSIPHON_MODE")
    [ "$mode" = "warp" ] && extra="${extra} | WARP+Psiphon"

    echo "${green}ACTIVE${extra}${reset}"
}

getPsiphonAutostart() {
    systemctl is-enabled --quiet "$PSIPHON_SVC" 2>/dev/null \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

getPsiphonMode() {
    local mode
    mode=$(xpro_conf_get "PSIPHON_MODE")
    echo "${mode:-plain}"
}

getPsiphonCountry() {
    if [ -f "$PSIPHON_CONFIG" ]; then
        PSIPHON_CONFIG_PATH="$PSIPHON_CONFIG" python3 -c "
import json, os
try:
    d=json.load(open(os.environ['PSIPHON_CONFIG_PATH']))
    print(d.get('EgressRegion','') or 'auto')
except: print('auto')
" 2>/dev/null
    else
        echo "auto"
    fi
}

# =================================================================
# УСТАНОВКА БИНАРЯ
# =================================================================
installPsiphon() {
    if [ -f "$PSIPHON_BIN" ]; then
        echo "info: Psiphon уже установлен"
        return 0
    fi

    echo "${cyan}Установка Psiphon...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS

    local arch
    arch=$(uname -m)
    local arch_name
    case "$arch" in
        x86_64)  arch_name="x86_64" ;;
        aarch64) arch_name="arm64" ;;
        armv7l)  arch_name="arm" ;;
        *)
            echo "${red}Архитектура не поддерживается: $arch${reset}"
            return 1
            ;;
    esac

    local bin_url="https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries/raw/master/linux/psiphon-tunnel-core-${arch_name}"

    echo "${cyan}Загрузка psiphon-tunnel-core (${arch_name})...${reset}"
    if curl -fsSL -o "$PSIPHON_BIN" "$bin_url"; then
        chmod +x "$PSIPHON_BIN"
        echo "${green}Psiphon бинарь установлен${reset}"
    else
        echo "${red}Не удалось загрузить Psiphon${reset}"
        return 1
    fi

    mkdir -p "$PSIPHON_DATA_DIR" /var/log/psiphon /usr/local/etc/xpro
}

# =================================================================
# КОНФИГУРАЦИЯ
# =================================================================
writePsiphonConfig() {
    local country="${1:-}"      # "" = auto
    local mode="${2:-plain}"    # plain | warp

    mkdir -p "$(dirname "$PSIPHON_CONFIG")" "$PSIPHON_DATA_DIR"

    local upstream_proxy=""
    if [ "$mode" = "warp" ]; then
        # Проверяем что WARP запущен
        if ! systemctl is-active --quiet warp-svc 2>/dev/null; then
            echo "${yellow}Внимание: WARP не запущен. Psiphon запустится в обычном режиме${reset}"
            mode="plain"
        else
            upstream_proxy="socks5://127.0.0.1:${WARP_PORT}"
        fi
    fi

    xpro_conf_set "PSIPHON_MODE" "$mode"

    # Генерируем JSON конфиг через python3
    # Ключ передаётся через переменную окружения — shell expansion внутри heredoc
    # не затронет спецсимволы RSA ключа (=, +, /).
    PSIPHON_KEY_ENV="$PSIPHON_REMOTE_SERVER_LIST_KEY" \
    PSIPHON_URL_ENV="$PSIPHON_REMOTE_SERVER_LIST_URL" \
    PSIPHON_CHANNEL_ENV="$PSIPHON_PROPAGATION_CHANNEL" \
    PSIPHON_SPONSOR_ENV="$PSIPHON_SPONSOR_ID" \
    PSIPHON_PORT_ENV="$PSIPHON_PORT" \
    PSIPHON_DATA_ENV="$PSIPHON_DATA_DIR" \
    PSIPHON_CONFIG_ENV="$PSIPHON_CONFIG" \
    PSIPHON_UPSTREAM_ENV="${upstream_proxy}" \
    PSIPHON_COUNTRY_ENV="${country}" \
    python3 - << 'PYEOF'
import json, os

cfg = {
    "PropagationChannelId": os.environ["PSIPHON_CHANNEL_ENV"],
    "SponsorId":            os.environ["PSIPHON_SPONSOR_ENV"],
    "LocalSocksProxyPort":  int(os.environ["PSIPHON_PORT_ENV"]),
    "LocalHttpProxyPort":   0,
    "DisableLocalSocksProxy": False,
    "DisableLocalHTTPProxy":  True,
    "EgressRegion":         os.environ["PSIPHON_COUNTRY_ENV"],
    "DataRootDirectory":    os.environ["PSIPHON_DATA_ENV"],
    "RemoteServerListDownloadFilename": os.environ["PSIPHON_DATA_ENV"] + "/remote_server_list",
    "RemoteServerListUrl":  os.environ["PSIPHON_URL_ENV"],
    "RemoteServerListSignaturePublicKey": os.environ["PSIPHON_KEY_ENV"],
    "MigrateDataStoreDirectory": os.environ["PSIPHON_DATA_ENV"],
    "ClientPlatform":  "Android_4.0.4_com.example.exampleClientLibraryApp",
    "ClientVersion":   "1",
    "TunnelWholeDevice": 0,
    "EmitBytesTransferred": False,
    "EmitSLOK": False,
}

upstream = os.environ.get("PSIPHON_UPSTREAM_ENV", "")
if upstream:
    cfg["UpstreamProxyUrl"] = upstream

with open(os.environ["PSIPHON_CONFIG_ENV"], "w") as f:
    json.dump(cfg, f, indent=4)

print("Psiphon конфиг записан")
PYEOF

    echo "${green}Psiphon конфиг: страна=${country:-auto}, режим=${mode}${reset}"
}

# =================================================================
# SYSTEMD СЕРВИС
# =================================================================
writePsiphonService() {
    cat > "$PSIPHON_SERVICE" << EOF
[Unit]
Description=Psiphon Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${PSIPHON_BIN} -config ${PSIPHON_CONFIG}
Restart=on-failure
RestartSec=10s
StandardOutput=append:${PSIPHON_LOG}
StandardError=append:${PSIPHON_LOG}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo "info: Psiphon systemd сервис создан"
}

# =================================================================
# УПРАВЛЕНИЕ СЕРВИСОМ
# =================================================================
startPsiphon() {
    systemctl start "$PSIPHON_SVC"
    sleep 5  # Psiphon медленнее стартует — нужно время на подключение

    if systemctl is-active --quiet "$PSIPHON_SVC"; then
        echo "${green}Psiphon запущен${reset}"
    else
        echo "${red}Psiphon не запустился. Логи: journalctl -u psiphon -n 20${reset}"
        return 1
    fi
}

stopPsiphon() {
    systemctl stop "$PSIPHON_SVC"
    echo "${yellow}Psiphon остановлен${reset}"
}

enablePsiphon() {
    systemctl enable "$PSIPHON_SVC"
    echo "${green}Psiphon автозагрузка включена${reset}"
}

disablePsiphon() {
    systemctl disable "$PSIPHON_SVC"
    echo "${yellow}Psiphon автозагрузка выключена${reset}"
}

restartPsiphon() {
    systemctl restart "$PSIPHON_SVC"
    sleep 3
    echo "${green}Psiphon перезапущен${reset}"
}

# =================================================================
# УДАЛЕНИЕ
# =================================================================
removePsiphon() {
    echo "${yellow}Удалить Psiphon? (y/N)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "Отменено"; return 0; }

    systemctl stop "$PSIPHON_SVC" 2>/dev/null || true
    systemctl disable "$PSIPHON_SVC" 2>/dev/null || true

    rm -f "$PSIPHON_BIN"
    rm -f "$PSIPHON_SERVICE"
    rm -f "$PSIPHON_CONFIG"
    rm -rf "$PSIPHON_DATA_DIR"
    systemctl daemon-reload

    xpro_conf_set "PSIPHON_INSTALLED" "no"
    xpro_conf_del "PSIPHON_MODE"

    echo "${green}Psiphon удалён${reset}"
}

# =================================================================
# СМЕНА СТРАНЫ
# =================================================================
setPsiphonCountry() {
    local valid_countries="AT BE BG BR CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK UA US"

    echo ""
    echo "${cyan}Страна выхода Psiphon:${reset}"
    echo "  ${green}0.${reset} Авто (Psiphon выбирает)"
    echo ""
    echo "  Доступные: $valid_countries"
    echo ""
    read -rp "  Введи код страны (или 0 для авто): " country_input

    local current_mode
    current_mode=$(getPsiphonMode)

    if [ "$country_input" = "0" ] || [ -z "$country_input" ]; then
        writePsiphonConfig "" "$current_mode"
        echo "${green}Страна: авто${reset}"
    else
        country_input="${country_input^^}"
        if ! echo "$valid_countries" | grep -qw "$country_input"; then
            echo "${red}Неверный код: $country_input${reset}"
            return 1
        fi
        writePsiphonConfig "$country_input" "$current_mode"
        echo "${green}Страна: ${country_input}${reset}"
    fi

    restartPsiphon
}

# =================================================================
# СМЕНА РЕЖИМА
# =================================================================
setPsiphonMode() {
    local current_mode
    current_mode=$(getPsiphonMode)

    local current_country
    current_country=$(getPsiphonCountry)
    [ "$current_country" = "auto" ] && current_country=""

    echo ""
    echo "${cyan}Режим Psiphon:${reset}"
    echo "  ${green}1.${reset} plain          — обычный Psiphon"
    echo "  ${green}2.${reset} WARP+Psiphon   — трафик через WARP → Psiphon"
    echo ""
    echo "  Текущий: $current_mode"
    echo ""
    read -rp "  Выбор: " mode_choice

    case "$mode_choice" in
        1)
            writePsiphonConfig "$current_country" "plain"
            echo "${green}Режим: plain${reset}"
            restartPsiphon
            ;;
        2)
            if ! command -v warp-cli &>/dev/null; then
                echo "${red}WARP не установлен${reset}"
                return 1
            fi
            if ! systemctl is-active --quiet warp-svc 2>/dev/null; then
                echo "${yellow}WARP не запущен, запускаем...${reset}"
                startWarp 2>/dev/null || {
                    echo "${red}Не удалось запустить WARP${reset}"
                    return 1
                }
            fi
            writePsiphonConfig "$current_country" "warp"
            echo "${green}Режим: WARP+Psiphon${reset}"
            restartPsiphon
            ;;
        *)
            echo "Отменено"
            ;;
    esac
}

# =================================================================
# ПРОВЕРКА IP — с фалбеками
# =================================================================
checkPsiphonIP() {
    echo "${cyan}Проверяем IP через Psiphon...${reset}"
    echo "${yellow}Psiphon может быть медленным, ожидайте до 30 секунд...${reset}"
    checkServiceIP "socks5://127.0.0.1:${PSIPHON_PORT}" "Psiphon"
}

# =================================================================
# МЕНЮ PSIPHON
# =================================================================
psiphonMenu() {
    while true; do
        clear
        local status autostart mode country
        status=$(getPsiphonStatus)
        autostart=$(getPsiphonAutostart)
        mode=$(getPsiphonMode)
        country=$(getPsiphonCountry)

        echo ""
        echo "${cyan}══════════════════════════════════════${reset}"
        echo "${cyan}  Psiphon${reset}"
        echo "${cyan}══════════════════════════════════════${reset}"
        echo ""
        echo "  Статус:      $status"
        echo "  Автозагрузка: $autostart"
        echo "  Страна:      $country"
        echo "  Режим:       $mode"
        echo "  Порт:        socks5://127.0.0.1:${PSIPHON_PORT}"
        echo ""

        if [ ! -f "$PSIPHON_BIN" ]; then
            echo "  ${green}1.${reset} Установить Psiphon"
        else
            local is_active
            is_active=$(systemctl is-active "$PSIPHON_SVC" 2>/dev/null)
            if [ "$is_active" = "active" ]; then
                echo "  ${green}1.${reset} Остановить Psiphon"
            else
                echo "  ${green}1.${reset} Запустить Psiphon"
            fi

            local is_enabled
            is_enabled=$(systemctl is-enabled "$PSIPHON_SVC" 2>/dev/null)
            if [ "$is_enabled" = "enabled" ]; then
                echo "  ${green}2.${reset} Выключить автозагрузку"
            else
                echo "  ${green}2.${reset} Включить автозагрузку"
            fi

            echo "  ${green}3.${reset} Сменить страну"
            echo "  ${green}4.${reset} Сменить режим (plain / WARP+Psiphon)"
        fi

        echo "  ${green}5.${reset} Проверить IP"
        echo "  ${red}6.${reset} Удалить Psiphon"
        echo "  ${green}0.${reset} Назад"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1)
                if [ ! -f "$PSIPHON_BIN" ]; then
                    installPsiphon && \
                    writePsiphonConfig "" "plain" && \
                    writePsiphonService && \
                    startPsiphon && \
                    enablePsiphon
                else
                    local is_active
                    is_active=$(systemctl is-active "$PSIPHON_SVC" 2>/dev/null)
                    if [ "$is_active" = "active" ]; then stopPsiphon
                    else startPsiphon; fi
                fi
                sleep 1
                ;;
            2)
                [ ! -f "$PSIPHON_BIN" ] && { echo "${red}Psiphon не установлен${reset}"; sleep 1; continue; }
                local is_enabled
                is_enabled=$(systemctl is-enabled "$PSIPHON_SVC" 2>/dev/null)
                if [ "$is_enabled" = "enabled" ]; then disablePsiphon
                else enablePsiphon; fi
                sleep 1
                ;;
            3)
                [ ! -f "$PSIPHON_BIN" ] && { echo "${red}Psiphon не установлен${reset}"; sleep 1; continue; }
                setPsiphonCountry; read -r
                ;;
            4)
                [ ! -f "$PSIPHON_BIN" ] && { echo "${red}Psiphon не установлен${reset}"; sleep 1; continue; }
                setPsiphonMode; read -r
                ;;
            5) checkPsiphonIP; read -r ;;
            6) removePsiphon; read -r ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}
