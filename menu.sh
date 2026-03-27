#!/bin/bash
# =================================================================
# menu.sh — X-UI PRO главное меню (команда xpro)
# =================================================================

# set -euo pipefail НЕ используем в интерактивном меню:
# любая ненулевая команда (например getWarpStatus при остановленном сервисе)
# завершила бы скрипт. Используем только -u для защиты от необъявленных переменных.
set -uo pipefail

XPRO_LIB="/usr/local/lib/xpro"
XPRO_CONF="/usr/local/etc/xpro/xpro.conf"

# =================================================================
# ЗАГРУЗКА МОДУЛЕЙ
# =================================================================
_load_modules() {
    for mod in core xui nginx warp tor psiphon security; do
        local f="${XPRO_LIB}/${mod}.sh"
        if [ -f "$f" ]; then
            # shellcheck source=/dev/null
            source "$f"
        else
            echo "Ошибка: модуль ${mod}.sh не найден в ${XPRO_LIB}"
            exit 1
        fi
    done
}

# =================================================================
# СТРОКА СТАТУСА ДЛЯ ГЛАВНОГО ЭКРАНА
# =================================================================
_status_line() {
    local label="$1"   # "WARP"
    local status="$2"  # результат getXxxStatus()
    local port="$3"    # "40000" (опционально)
    local width=12

    printf "  %-${width}s %s" "$label" "$status"
    [ -n "$port" ] && printf "   :${port}"
    printf "\n"
}

# =================================================================
# ГЛАВНЫЙ ЭКРАН — статус всех сервисов
# =================================================================
show_status() {
    clear

    # Получаем данные
    local server_ip country_code flag
    server_ip=$(getServerIP 2>/dev/null || echo "...")
    country_code=$(getCountryCode "$server_ip" 2>/dev/null || echo "??")
    flag=$(getCountryFlag "$country_code" 2>/dev/null || echo "🌐")

    local domain xui_port web_path panel_url
    domain=$(xpro_conf_get "DOMAIN" 2>/dev/null || echo "не задан")
    xui_port=$(xuiGetPort 2>/dev/null || echo "?")
    web_path=$(xuiGetWebBasePath 2>/dev/null || echo "")
    if [ -n "$web_path" ]; then
        panel_url="${domain}/${web_path}"
    else
        panel_url="${domain}/???"
    fi

    local xui_status nginx_status
    xui_status=$(getServiceStatus "x-ui" 2>/dev/null)
    nginx_status=$(getServiceStatus "nginx" 2>/dev/null)

    local cert_expiry
    cert_expiry=$(checkCertExpiry 2>/dev/null || echo "${red}?${reset}")

    echo ""
    echo "${cyan}╔══════════════════════════════════════════╗${reset}"
    printf "${cyan}║${reset}  X-UI PRO v%-5s  ${cyan}|${reset}  %s  %-15s${cyan}║${reset}\n" \
        "$XPRO_VERSION" "$flag" "$server_ip"
    echo "${cyan}╠══════════════════════════════════════════╣${reset}"
    echo "${cyan}║${reset}                                          ${cyan}║${reset}"

    # 3x-ui
    printf "${cyan}║${reset}  %-10s  %s   (%s)%*s${cyan}║${reset}\n" \
        "3x-ui" "$xui_status" "$panel_url" \
        $((16 - ${#panel_url})) ""

    # Nginx + SSL
    printf "${cyan}║${reset}  %-10s  %s   SSL: %s%*s${cyan}║${reset}\n" \
        "Nginx" "$nginx_status" "$cert_expiry" 8 ""

    echo "${cyan}║${reset}                                          ${cyan}║${reset}"
    echo "${cyan}╠══════════════════════════════════════════╣${reset}"

    # WARP
    local warp_s="—"
    if [ "$(xpro_conf_get WARP_INSTALLED)" = "yes" ]; then
        warp_s=$(getWarpStatus 2>/dev/null || echo "${red}?${reset}")
    fi
    printf "${cyan}║${reset}  %-10s  %-30s${cyan}║${reset}\n" "WARP" "$warp_s"

    # Tor
    local tor_s="—"
    if [ "$(xpro_conf_get TOR_INSTALLED)" = "yes" ]; then
        tor_s=$(getTorStatus 2>/dev/null || echo "${red}?${reset}")
    fi
    printf "${cyan}║${reset}  %-10s  %-30s${cyan}║${reset}\n" "Tor" "$tor_s"

    # Psiphon
    local psiphon_s="—"
    if [ "$(xpro_conf_get PSIPHON_INSTALLED)" = "yes" ]; then
        psiphon_s=$(getPsiphonStatus 2>/dev/null || echo "${red}?${reset}")
    fi
    printf "${cyan}║${reset}  %-10s  %-30s${cyan}║${reset}\n" "Psiphon" "$psiphon_s"

    echo "${cyan}║${reset}                                          ${cyan}║${reset}"
    echo "${cyan}╚══════════════════════════════════════════╝${reset}"
    echo ""
}

# =================================================================
# ГЛАВНОЕ МЕНЮ
# =================================================================
main_menu() {
    while true; do
        show_status

        echo "  ${green}1.${reset} Управление WARP"
        echo "  ${green}2.${reset} Управление Tor"
        echo "  ${green}3.${reset} Управление Psiphon"
        echo "  ${green}4.${reset} Nginx / SSL"
        echo "  ${green}5.${reset} Безопасность"
        echo "  ${green}6.${reset} 3x-ui"
        echo "  ${green}0.${reset} Выход"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1) warpMenu ;;
            2) torMenu ;;
            3) psiphonMenu ;;
            4) nginxMenu ;;
            5) securityMenu ;;
            6) manage3xuiMenu ;;
            0)
                echo ""
                echo "  Для возврата: xpro"
                echo ""
                exit 0
                ;;
            *) ;;
        esac
    done
}

# =================================================================
# CLI АРГУМЕНТЫ — xpro [команда]
# Позволяет вызывать функции напрямую из командной строки:
#   xpro update-cf-ips
#   xpro check-warp
#   xpro status
# =================================================================
handle_cli() {
    local cmd="${1:-}"

    case "$cmd" in
        update-cf-ips)
            _load_modules
            setupRealIpRestore
            ;;
        check-warp)
            _load_modules
            checkWarpIP
            ;;
        check-tor)
            _load_modules
            checkTorIP
            ;;
        check-psiphon)
            _load_modules
            checkPsiphonIP
            ;;
        status)
            _load_modules
            show_status
            ;;
        uninstall)
            _load_modules
            _uninstall_xpro
            ;;
        "")
            # Без аргументов — запускаем меню
            isRoot
            _load_modules
            main_menu
            ;;
        *)
            echo "Неизвестная команда: $cmd"
            echo "Доступные: update-cf-ips, check-warp, check-tor, check-psiphon, status, uninstall"
            exit 1
            ;;
    esac
}

# =================================================================
# ПОЛНОЕ УДАЛЕНИЕ
# =================================================================
_uninstall_xpro() {
    echo "${red}═══════════════════════════════════════${reset}"
    echo "${red}  Удаление X-UI PRO${reset}"
    echo "${red}═══════════════════════════════════════${reset}"
    echo ""
    echo "${yellow}Будет удалено: 3x-ui, Nginx конфиг, WARP, Tor, Psiphon, xpro${reset}"
    echo "${yellow}SSL сертификат и acme.sh НЕ удаляются${reset}"
    echo ""
    echo "Продолжить? (y/N)"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "Отменено"; return 0; }

    echo ""

    # Удаляем сервисы если установлены
    [ "$(xpro_conf_get WARP_INSTALLED)" = "yes" ] && {
        echo "${cyan}Удаляем WARP...${reset}"
        _warp_cmd disconnect 2>/dev/null || true
        systemctl stop warp-svc 2>/dev/null || true
        systemctl disable warp-svc 2>/dev/null || true
        uninstallPackage "cloudflare-warp" 2>/dev/null || true
    }

    [ "$(xpro_conf_get TOR_INSTALLED)" = "yes" ] && {
        echo "${cyan}Удаляем Tor...${reset}"
        systemctl stop tor 2>/dev/null || true
        systemctl disable tor 2>/dev/null || true
        uninstallPackage "tor" 2>/dev/null || true
    }

    [ "$(xpro_conf_get PSIPHON_INSTALLED)" = "yes" ] && {
        echo "${cyan}Удаляем Psiphon...${reset}"
        systemctl stop psiphon 2>/dev/null || true
        systemctl disable psiphon 2>/dev/null || true
        rm -f /usr/local/bin/psiphon-tunnel-core
        rm -f /etc/systemd/system/psiphon.service
    }

    # Удаляем nginx конфиг xpro (оставляем nginx сам)
    rm -f /etc/nginx/conf.d/xpro.conf
    rm -f /etc/nginx/conf.d/cf_guard.conf
    rm -f /etc/nginx/conf.d/real_ip_restore.conf
    rm -f /etc/nginx/conf.d/sub_map.conf
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

    # Удаляем 3x-ui
    echo "${cyan}Удаляем 3x-ui...${reset}"
    x-ui uninstall 2>/dev/null || {
        systemctl stop x-ui 2>/dev/null || true
        systemctl disable x-ui 2>/dev/null || true
        rm -rf /usr/local/x-ui
        rm -f /usr/local/bin/x-ui
        rm -f /etc/systemd/system/x-ui.service
    }

    # Cron
    rm -f /etc/cron.d/xpro-cf-ips

    # Конфиг и модули xpro
    rm -f /usr/local/bin/xpro
    rm -rf "$XPRO_LIB"
    # xpro.conf намеренно НЕ удаляем — там могут быть CF ключи

    systemctl daemon-reload

    echo ""
    echo "${green}X-UI PRO удалён${reset}"
    echo "${yellow}Конфиг сохранён: ${XPRO_CONF}${reset}"
    echo "${yellow}SSL сертификат: /etc/nginx/cert/${reset}"
}

# =================================================================
# ТОЧКА ВХОДА
# =================================================================
handle_cli "${1:-}"
