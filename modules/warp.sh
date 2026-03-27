#!/bin/bash
# =================================================================
# warp.sh — Cloudflare WARP: установка, управление
# SOCKS5 на 127.0.0.1:40000
# =================================================================

WARP_PORT=40000
WARP_SVC="warp-svc"

# =================================================================
# СТАТУС
# =================================================================
getWarpStatus() {
    if ! command -v warp-cli &>/dev/null; then
        echo "${red}НЕ УСТАНОВЛЕН${reset}"
        return
    fi

    if ! systemctl is-active --quiet "$WARP_SVC" 2>/dev/null; then
        echo "${red}STOPPED${reset}"
        return
    fi

    local out
    out=$(_warp_cmd status 2>/dev/null)
    if echo "$out" | grep -q "Connected"; then
        echo "${green}ACTIVE${reset}"
    else
        echo "${yellow}DISCONNECTED${reset}"
    fi
}

getWarpAutostart() {
    systemctl is-enabled --quiet "$WARP_SVC" 2>/dev/null \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

# =================================================================
# ОБЁРТКА — совместимость старых и новых версий warp-cli
# =================================================================
_warp_cmd() {
    if warp-cli --help 2>&1 | grep -q "accept-tos"; then
        warp-cli --accept-tos "$@"
    else
        warp-cli "$@"
    fi
}

# =================================================================
# УСТАНОВКА
# =================================================================
installWarp() {
    if command -v warp-cli &>/dev/null; then
        echo "info: warp-cli уже установлен"
        return 0
    fi

    echo "${cyan}Установка Cloudflare WARP...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS

    # GPG должен быть установлен
    if ! command -v gpg &>/dev/null; then
        installPackage "gnupg2" || return 1
    fi

    # Очистка мусорных репозиториев CF (Баг: NO_PUBKEY на Ubuntu 24.04)
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /etc/apt/sources.list.d/cloudflare-warp.list

    if command -v apt &>/dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
            | gpg --yes --dearmor \
            -o /usr/share/keyrings/cloudflare-warp.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
            | tee /etc/apt/sources.list.d/cloudflare-client.list
    else
        curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
            | tee /etc/yum.repos.d/cloudflare-warp.repo
    fi

    ${PACKAGE_MANAGEMENT_UPDATE} &>/dev/null
    installPackage "cloudflare-warp"

    # Финальная проверка
    if ! command -v warp-cli &>/dev/null; then
        echo "${red}WARP не установлен — binary missing${reset}"
        return 1
    fi

    # Настраиваем systemd unit — автоперезапуск вместо watchdog
    local svc_override="/etc/systemd/system/warp-svc.service.d"
    mkdir -p "$svc_override"
    cat > "${svc_override}/restart.conf" << 'EOF'
[Service]
Restart=on-failure
RestartSec=10s
EOF
    systemctl daemon-reload
    echo "${green}WARP установлен${reset}"
}

# =================================================================
# КОНФИГУРАЦИЯ
# =================================================================
configWarp() {
    systemctl enable --now "$WARP_SVC"
    sleep 3

    # Регистрация если нет
    if ! _warp_cmd registration show &>/dev/null; then
        _warp_cmd registration delete &>/dev/null || true
        local attempts=0
        while [ $attempts -lt 3 ]; do
            _warp_cmd registration new && break
            attempts=$((attempts + 1))
            sleep 3
        done
    fi

    # Режим proxy (SOCKS5)
    _warp_cmd mode proxy
    _warp_cmd set-proxy-port "$WARP_PORT" 2>/dev/null || true
    _warp_cmd connect
    sleep 5

    echo "${green}WARP настроен на socks5://127.0.0.1:${WARP_PORT}${reset}"
}

# =================================================================
# УПРАВЛЕНИЕ СЕРВИСОМ
# =================================================================
startWarp() {
    systemctl start "$WARP_SVC"
    sleep 2
    _warp_cmd connect 2>/dev/null || true
    echo "${green}WARP запущен${reset}"
}

stopWarp() {
    _warp_cmd disconnect 2>/dev/null || true
    systemctl stop "$WARP_SVC"
    echo "${yellow}WARP остановлен${reset}"
}

enableWarp() {
    systemctl enable "$WARP_SVC"
    echo "${green}WARP автозагрузка включена${reset}"
}

disableWarp() {
    systemctl disable "$WARP_SVC"
    echo "${yellow}WARP автозагрузка выключена${reset}"
}

# =================================================================
# УДАЛЕНИЕ
# =================================================================
removeWarp() {
    echo "${yellow}Удалить WARP? (y/N)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "Отменено"; return 0; }

    _warp_cmd disconnect 2>/dev/null || true
    systemctl stop "$WARP_SVC" 2>/dev/null || true
    systemctl disable "$WARP_SVC" 2>/dev/null || true

    uninstallPackage "cloudflare-warp"

    # Удаляем override
    rm -rf /etc/systemd/system/warp-svc.service.d
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /etc/yum.repos.d/cloudflare-warp.repo
    rm -f /usr/share/keyrings/cloudflare-warp.gpg
    systemctl daemon-reload

    # Удаляем outbound из 3x-ui
    xuiApiLogin 2>/dev/null && xuiApiDelOutbound "warp" 2>/dev/null || true

    xpro_conf_set "WARP_INSTALLED" "no"
    xpro_conf_del "OUTBOUND_WARP_ADDED"

    echo "${green}WARP удалён${reset}"
}

# =================================================================
# OUTBOUND'Ы В 3x-ui
# =================================================================
addWarpOutbound() {
    xuiApiLogin || return 1
    xuiApiAddOutbound "warp" "127.0.0.1" "$WARP_PORT"
}

removeWarpOutbound() {
    xuiApiLogin || return 1
    xuiApiDelOutbound "warp"
}

# =================================================================
# ПРОВЕРКА IP
# =================================================================
checkWarpIP() {
    echo "${cyan}Проверяем IP через WARP...${reset}"
    checkServiceIP "socks5://127.0.0.1:${WARP_PORT}" "WARP"
}

# =================================================================
# МЕНЮ WARP
# =================================================================
warpMenu() {
    while true; do
        clear
        local status autostart outbound_status
        status=$(getWarpStatus)
        autostart=$(getWarpAutostart)
        outbound_status="${red}нет${reset}"
        [ "$(xpro_conf_get OUTBOUND_WARP_ADDED)" = "yes" ] && \
            outbound_status="${green}добавлен${reset}"

        echo ""
        echo "${cyan}══════════════════════════════════════${reset}"
        echo "${cyan}  Cloudflare WARP${reset}"
        echo "${cyan}══════════════════════════════════════${reset}"
        echo ""
        echo "  Статус:      $status"
        echo "  Автозагрузка: $autostart"
        echo "  Outbound:    $outbound_status"
        echo "  Порт:        socks5://127.0.0.1:${WARP_PORT}"
        echo ""

        # Динамические пункты меню в зависимости от состояния
        if ! command -v warp-cli &>/dev/null; then
            echo "  ${green}1.${reset} Установить WARP"
        else
            local is_active
            is_active=$(systemctl is-active "$WARP_SVC" 2>/dev/null)
            if [ "$is_active" = "active" ]; then
                echo "  ${green}1.${reset} Остановить WARP"
            else
                echo "  ${green}1.${reset} Запустить WARP"
            fi

            local is_enabled
            is_enabled=$(systemctl is-enabled "$WARP_SVC" 2>/dev/null)
            if [ "$is_enabled" = "enabled" ]; then
                echo "  ${green}2.${reset} Выключить автозагрузку"
            else
                echo "  ${green}2.${reset} Включить автозагрузку"
            fi
        fi

        echo "  ${green}3.${reset} Добавить outbound в 3x-ui"
        echo "  ${green}4.${reset} Удалить outbound из 3x-ui"
        echo "  ${green}5.${reset} Проверить IP"
        echo "  ${red}6.${reset} Удалить WARP"
        echo "  ${green}0.${reset} Назад"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1)
                if ! command -v warp-cli &>/dev/null; then
                    installWarp && configWarp
                else
                    local is_active
                    is_active=$(systemctl is-active "$WARP_SVC" 2>/dev/null)
                    if [ "$is_active" = "active" ]; then
                        stopWarp
                    else
                        startWarp
                    fi
                fi
                sleep 1
                ;;
            2)
                if ! command -v warp-cli &>/dev/null; then
                    echo "${red}WARP не установлен${reset}"; sleep 1; continue
                fi
                local is_enabled
                is_enabled=$(systemctl is-enabled "$WARP_SVC" 2>/dev/null)
                if [ "$is_enabled" = "enabled" ]; then
                    disableWarp
                else
                    enableWarp
                fi
                sleep 1
                ;;
            3) addWarpOutbound; read -r ;;
            4) removeWarpOutbound; read -r ;;
            5) checkWarpIP; read -r ;;
            6) removeWarp; read -r ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}
