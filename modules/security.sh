#!/bin/bash
# =================================================================
# security.sh — UFW, BBR, Fail2Ban, WebJail, SSH, IPv6, CPU Guard
# =================================================================

# =================================================================
# BBR
# =================================================================
getBbrStatus() {
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr" \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

enableBBR() {
    local current
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    if [ "$current" = "bbr" ]; then
        echo "${yellow}BBR уже активен${reset}"
        echo "${yellow}Если включал через 3x-ui — дублировать не нужно${reset}"
        return 0
    fi

    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || \
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    grep -q "default_qdisc=fq" /etc/sysctl.conf || \
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

    sysctl -p &>/dev/null
    echo "${green}BBR включён${reset}"
}

# =================================================================
# FAIL2BAN — SSH защита
# =================================================================
getF2BStatus() {
    systemctl is-active --quiet fail2ban 2>/dev/null \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

setupFail2Ban() {
    echo "${cyan}Настройка Fail2Ban (SSH)...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    installPackage "fail2ban"

    local ssh_port
    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | \
        awk '{print $2}' | head -1)
    ssh_port="${ssh_port:-22}"

    # Ubuntu 22.04+ использует systemd backend
    local sshd_backend sshd_logpath
    if [ -f /var/log/auth.log ]; then
        sshd_backend="auto"
        sshd_logpath="logpath = /var/log/auth.log"
    else
        sshd_backend="systemd"
        sshd_logpath=""
    fi

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 2h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = ${ssh_port}
filter   = sshd
backend  = ${sshd_backend}
${sshd_logpath}
maxretry = 3
bantime  = 24h
EOF

    systemctl enable --now fail2ban
    systemctl restart fail2ban
    echo "${green}Fail2Ban настроен (SSH порт: ${ssh_port})${reset}"
    echo "${yellow}Примечание: 3x-ui имеет встроенную защиту панели.${reset}"
    echo "${yellow}Системный Fail2Ban защищает SSH — конфликта нет.${reset}"
}

# =================================================================
# WEBJAIL — защита nginx от сканеров
# =================================================================
getWebJailStatus() {
    if [ -f /etc/fail2ban/filter.d/nginx-probe.conf ]; then
        fail2ban-client status nginx-probe &>/dev/null \
            && echo "${green}ON${reset}" || echo "${yellow}inactive${reset}"
    else
        echo "${red}OFF${reset}"
    fi
}

setupWebJail() {
    echo "${cyan}Настройка WebJail (nginx probe защита)...${reset}"

    [ ! -f /etc/fail2ban/jail.local ] && setupFail2Ban

    cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'EOF'
[Definition]
failregex = ^<HOST> - .* "(GET|POST|HEAD) .*(\.php|wp-login|admin|\.env|\.git|config\.js|setup\.cgi|xmlrpc).*" (400|403|404|405) \d+
ignoreregex = ^<HOST> - .* "(GET|POST) /favicon.ico.*"
EOF

    if ! grep -q "\[nginx-probe\]" /etc/fail2ban/jail.local 2>/dev/null; then
        cat >> /etc/fail2ban/jail.local << 'EOF'

[nginx-probe]
enabled  = true
port     = http,https
filter   = nginx-probe
logpath  = /var/log/nginx/access.log
maxretry = 5
bantime  = 24h
EOF
    fi

    systemctl restart fail2ban
    echo "${green}WebJail настроен${reset}"
}

# =================================================================
# UFW
# =================================================================
getUfwStatus() {
    local status
    status=$(ufw status 2>/dev/null | head -1)
    if echo "$status" | grep -q "active"; then
        echo "${green}ACTIVE${reset}"
    else
        echo "${red}INACTIVE${reset}"
    fi
}

# Начальная настройка UFW при установке
setupUFW() {
    local xui_port="${1:-}"
    local cdn="${2:-off}"

    echo "${cyan}Настройка UFW...${reset}"
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    installPackage "ufw"

    # Дефолтные правила
    ufw --force reset &>/dev/null
    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null

    # SSH — текущий порт
    local ssh_port
    ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | \
        awk '{print $2}' | head -1)
    ssh_port="${ssh_port:-22}"
    ufw allow "${ssh_port}/tcp" comment 'SSH'

    # HTTPS всегда
    ufw allow 443/tcp comment 'HTTPS'

    if [ "$cdn" = "on" ]; then
        # При CDN — прямой порт 3x-ui закрыт снаружи
        # Панель доступна только через nginx /xui/
        echo "${yellow}CDN режим: порт панели ${xui_port} закрыт снаружи${reset}"
        echo "${yellow}Панель доступна через: https://$(xpro_conf_get DOMAIN)/xui/${reset}"
    else
        # Без CDN — открываем порт панели
        if [ -n "$xui_port" ]; then
            ufw allow "${xui_port}/tcp" comment '3x-ui panel'
        fi
    fi

    echo "y" | ufw enable
    echo "${green}UFW настроен${reset}"
    echo "${yellow}Примечание: 3x-ui показывает статус UFW но не управляет им.${reset}"
}

manageUFW() {
    while true; do
        clear
        echo ""
        echo "${cyan}══════════════════════════════════════${reset}"
        echo "${cyan}  UFW Firewall${reset}"
        echo "${cyan}══════════════════════════════════════${reset}"
        echo ""
        ufw status verbose 2>/dev/null || echo "  UFW не активен"
        echo ""
        echo "  ${green}1.${reset} Открыть порт"
        echo "  ${green}2.${reset} Закрыть порт"
        echo "  ${green}3.${reset} Включить UFW"
        echo "  ${green}4.${reset} Выключить UFW"
        echo "  ${green}5.${reset} Сбросить правила"
        echo "  ${green}0.${reset} Назад"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1)
                read -rp "  Порт: " port
                read -rp "  Протокол (tcp/udp/any): " proto
                [ "$proto" = "any" ] && proto=""
                if [ -n "$port" ]; then
                    ufw allow "${port}${proto:+/}${proto}" && \
                        echo "${green}Порт ${port} открыт${reset}"
                fi
                read -r
                ;;
            2)
                read -rp "  Порт для закрытия: " port
                [ -n "$port" ] && ufw delete allow "$port" && \
                    echo "${green}Порт ${port} закрыт${reset}"
                read -r
                ;;
            3)
                echo "y" | ufw enable && echo "${green}UFW включён${reset}"
                read -r
                ;;
            4)
                ufw disable && echo "${yellow}UFW выключен${reset}"
                read -r
                ;;
            5)
                echo "${red}Сбросить все правила UFW? (y/N)${reset}"
                read -r confirm
                [[ "$confirm" == "y" ]] && \
                    ufw --force reset && echo "${green}UFW сброшен${reset}"
                read -r
                ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}

# =================================================================
# SSH ПОРТ
# =================================================================
changeSshPort() {
    local current_port
    current_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | \
        awk '{print $2}' | head -1)
    current_port="${current_port:-22}"

    echo ""
    echo "  Текущий SSH порт: $current_port"
    read -rp "  Новый SSH порт (1024-65535): " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || \
       [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        echo "${red}Неверный порт${reset}"
        return 1
    fi

    # Открываем новый порт в UFW до смены
    ufw status 2>/dev/null | grep -q "active" && \
        ufw allow "${new_port}/tcp" comment 'SSH'

    sed -i "s/^#\?Port [0-9]*/Port ${new_port}/" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh

    # Проверяем что новый порт слушает
    sleep 2
    if ss -tlnp 2>/dev/null | grep -q ":${new_port} "; then
        echo "${green}SSH слушает на порту ${new_port}${reset}"
    else
        echo "${red}ВНИМАНИЕ: SSH не слушает на порту ${new_port}!${reset}"
        echo "${red}Проверь: journalctl -u sshd -n 10${reset}"
        echo "${yellow}НЕ закрывай текущую SSH сессию!${reset}"
    fi

    # Обновляем Fail2Ban — иначе SSH остаётся без защиты на новом порту
    if [ -f /etc/fail2ban/jail.local ]; then
        sed -i "s/^port\s*=.*/port     = ${new_port}/" /etc/fail2ban/jail.local
        systemctl restart fail2ban 2>/dev/null || true
        echo "${green}Fail2Ban обновлён для порта ${new_port}${reset}"
    fi

    echo "${green}SSH порт изменён на ${new_port}${reset}"
    echo "${yellow}Старое правило UFW для порта ${current_port} можно удалить вручную${reset}"
}

# =================================================================
# IPv6
# =================================================================
getIPv6Status() {
    local val
    val=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    [ "$val" = "1" ] && echo "${red}OFF${reset}" || echo "${green}ON${reset}"
}

toggleIPv6() {
    local current
    current=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)

    if [ "$current" = "1" ]; then
        # Включаем IPv6
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 &>/dev/null
        sysctl -w net.ipv6.icmp.echo_ignore_all=0 &>/dev/null
        rm -f /etc/sysctl.d/99-xpro-ipv6.conf
        echo "${green}IPv6 включён${reset}"
    else
        # Выключаем IPv6 — пишем в отдельный файл, не трогаем network.conf
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null
        sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
        sysctl -w net.ipv6.icmp.echo_ignore_all=1 &>/dev/null

        cat > /etc/sysctl.d/99-xpro-ipv6.conf << 'SYSCTL'
# IPv6 — управляется через xpro → Безопасность → Переключить IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.icmp.echo_ignore_all = 1
SYSCTL
        echo "${red}IPv6 отключён${reset}"
    fi
}

# =================================================================
# CPU GUARD
# =================================================================
getCpuGuardStatus() {
    local xray_weight
    xray_weight=$(systemctl show x-ui.service -p CPUWeight 2>/dev/null | \
        cut -d= -f2)
    [ "${xray_weight:-}" = "200" ] \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

setupCpuGuard() {
    echo "${cyan}Настройка CPU Guard...${reset}"

    # Высокий приоритет для основных сервисов
    for svc in x-ui.service nginx.service; do
        systemctl set-property "$svc" CPUWeight=200 2>/dev/null || true
    done

    # Низкий приоритет для интерактивных сессий
    systemctl set-property user.slice CPUWeight=20 2>/dev/null || true

    # Персистентность через drop-in конфиги
    for svc in x-ui nginx; do
        local drop_in="/etc/systemd/system/${svc}.service.d"
        mkdir -p "$drop_in"
        cat > "${drop_in}/cpuguard.conf" << 'EOF'
[Service]
CPUWeight=200
Nice=-10
EOF
    done

    mkdir -p /etc/systemd/system/user.slice.d
    cat > /etc/systemd/system/user.slice.d/cpuguard.conf << 'EOF'
[Slice]
CPUWeight=20
EOF

    systemctl daemon-reload
    echo "${green}CPU Guard включён${reset}"
    echo "  x-ui:       CPUWeight=200, Nice=-10"
    echo "  nginx:      CPUWeight=200, Nice=-10"
    echo "  user.slice: CPUWeight=20  (SSH сессии)"
}

removeCpuGuard() {
    echo "${yellow}Удалить CPU Guard? (y/N)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "Отменено"; return 0; }

    for svc in x-ui nginx; do
        rm -f "/etc/systemd/system/${svc}.service.d/cpuguard.conf"
        rmdir "/etc/systemd/system/${svc}.service.d" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/user.slice.d/cpuguard.conf
    rmdir /etc/systemd/system/user.slice.d 2>/dev/null || true

    systemctl daemon-reload
    systemctl set-property user.slice CPUWeight=100 2>/dev/null || true
    for svc in x-ui.service nginx.service; do
        systemctl set-property "$svc" CPUWeight=100 2>/dev/null || true
    done

    echo "${green}CPU Guard удалён${reset}"
}

# =================================================================
# SYSCTL ОПТИМИЗАЦИИ
# =================================================================
applySysctl() {
    # Сетевые оптимизации — отдельный файл, не затрагивает IPv6.
    # IPv6 управляется toggleIPv6() через 99-xpro-ipv6.conf.
    cat > /etc/sysctl.d/99-xpro-network.conf << 'SYSCTL'
# ICMP ignore — скрываем сервер от ping
net.ipv4.icmp_echo_ignore_all = 1

# Сетевые лимиты
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# TCP keepalive — держит WS соединения живыми через NAT мобильных операторов
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
SYSCTL

    sysctl --system &>/dev/null
    sysctl -p /etc/sysctl.d/99-xpro-network.conf &>/dev/null
    echo "${green}Sysctl оптимизации применены${reset}"
}

# =================================================================
# МЕНЮ БЕЗОПАСНОСТИ
# =================================================================
securityMenu() {
    while true; do
        clear
        local bbr_s f2b_s webjail_s ufw_s ipv6_s cpuguard_s cfguard_s ssh_port
        bbr_s=$(getBbrStatus)
        f2b_s=$(getF2BStatus)
        webjail_s=$(getWebJailStatus)
        ufw_s=$(getUfwStatus)
        ipv6_s=$(getIPv6Status)
        cpuguard_s=$(getCpuGuardStatus)
        cfguard_s=$(getCfGuardStatus 2>/dev/null || echo "${red}OFF${reset}")
        ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | \
            awk '{print $2}' | head -1)
        ssh_port="${ssh_port:-22}"

        echo ""
        echo "${cyan}══════════════════════════════════════${reset}"
        echo "${cyan}  Безопасность${reset}"
        echo "${cyan}══════════════════════════════════════${reset}"
        echo ""
        echo "  SSH порт:   ${green}${ssh_port}${reset}"
        echo "  BBR:        $bbr_s"
        echo "  Fail2Ban:   $f2b_s"
        echo "  WebJail:    $webjail_s"
        echo "  UFW:        $ufw_s"
        echo "  IPv6:       $ipv6_s"
        echo "  CPU Guard:  $cpuguard_s"
        echo "  CF Guard:   $cfguard_s"
        echo ""
        echo "  ${green}1.${reset} Включить BBR"
        echo "  ${green}2.${reset} Настроить Fail2Ban (SSH)"
        echo "  ${green}3.${reset} Настроить WebJail (Nginx)"
        echo "  ${green}4.${reset} Управление UFW"
        echo "  ${green}5.${reset} Сменить порт SSH"
        echo "  ${green}6.${reset} Переключить IPv6"
        echo "  ${green}7.${reset} Включить CPU Guard"
        echo "  ${green}8.${reset} Удалить CPU Guard"
        echo "  ${green}9.${reset} CF Guard (только Cloudflare IP)"
        echo "  ${green}0.${reset} Назад"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1) enableBBR; read -r ;;
            2) setupFail2Ban; read -r ;;
            3) setupWebJail; read -r ;;
            4) manageUFW ;;
            5) changeSshPort; read -r ;;
            6) toggleIPv6; read -r ;;
            7) setupCpuGuard; read -r ;;
            8) removeCpuGuard; read -r ;;
            9) toggleCfGuard; read -r ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}
