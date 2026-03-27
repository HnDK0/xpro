#!/bin/bash
# =================================================================
# logs.sh — Логи, logrotate, cron автоочистка
# =================================================================

# Список лог-файлов (xray управляется 3x-ui отдельно)
_LOG_FILES=(
    /var/log/nginx/access.log
    /var/log/nginx/error.log
    /var/log/psiphon/psiphon.log
    /var/log/tor/notices.log
)

# =================================================================
# РАЗМЕР ЛОГОВ — показать текущее потребление
# =================================================================
getLogsSize() {
    local total=0 f size
    for f in "${_LOG_FILES[@]}"; do
        [ -f "$f" ] || continue
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        total=$((total + size))
    done

    # Journal size
    local journal_size
    journal_size=$(journalctl --disk-usage 2>/dev/null | \
        grep -oP '[\d.]+\s*[KMGT]' || echo "unknown")

    local total_kb=$((total / 1024))
    echo "Файлы: ${total_kb} KB | Journal: ${journal_size}"
}

# =================================================================
# ПОКАЗАТЬ ДЕТАЛИ
# =================================================================
showLogsDetails() {
    echo ""
    echo "${cyan}Лог-файлы:${reset}"
    for f in "${_LOG_FILES[@]}"; do
        if [ -f "$f" ]; then
            local size
            size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
            printf "  %-40s %s\n" "$f" "$size"
        else
            printf "  %-40s ${yellow}не существует${reset}\n" "$f"
        fi
    done

    echo ""
    echo "${cyan}Systemd Journal:${reset}"
    journalctl --disk-usage 2>/dev/null || echo "  недоступен"
    echo ""
}

# =================================================================
# ОЧИСТКА ЛОГОВ — ручная
# =================================================================
clearLogs() {
    echo "${cyan}Очистка логов...${reset}"
    local total_before=0 total_after=0 f size

    # Считаем размер до очистки
    for f in "${_LOG_FILES[@]}"; do
        [ -f "$f" ] || continue
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        total_before=$((total_before + size))
    done

    # Очищаем файлы
    for f in "${_LOG_FILES[@]}"; do
        [ -f "$f" ] && : > "$f"
    done

    # Очищаем systemd journal (3x-ui, WARP)
    journalctl --vacuum-size=50M &>/dev/null
    journalctl --vacuum-time=7d &>/dev/null

    # Считаем размер после очистки
    total_after=0
    for f in "${_LOG_FILES[@]}"; do
        [ -f "$f" ] || continue
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        total_after=$((total_after + size))
    done

    local freed=$(( (total_before - total_after) / 1024 ))
    echo "${green}Логи очищены (освобождено: ${freed} KB)${reset}"
}

# =================================================================
# LOGROTATE — настройка автоматической ротации
# =================================================================
setupLogrotate() {
    cat > /etc/logrotate.d/xpro << 'EOF'
/var/log/nginx/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    dateext
    sharedscripts
    postrotate
        systemctl reload nginx 2>/dev/null || true
    endscript
}

/var/log/psiphon/*.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}

/var/log/tor/*.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}
EOF
    echo "${green}Logrotate настроен${reset}"
}

# =================================================================
# CRON — автоочистка каждое воскресенье в 04:00
# =================================================================
setupLogClearCron() {
    # Скрипт очистки
    cat > /usr/local/bin/clear-logs.sh << 'EOF'
#!/bin/bash
# X-PRO: автоочистка логов
for f in \
    /var/log/nginx/access.log \
    /var/log/nginx/error.log \
    /var/log/psiphon/psiphon.log \
    /var/log/tor/notices.log; do
    [ -f "$f" ] && : > "$f"
done
# Systemd journal (3x-ui, WARP)
journalctl --vacuum-size=50M &>/dev/null
journalctl --vacuum-time=7d &>/dev/null
EOF
    chmod +x /usr/local/bin/clear-logs.sh

    # Cron задача
    cat > /etc/cron.d/xpro-clear-logs << 'EOF'
# X-PRO: очистка логов каждое воскресенье в 04:00
0 4 * * 0 root /usr/local/bin/clear-logs.sh
EOF
    chmod 644 /etc/cron.d/xpro-clear-logs
    echo "${green}Автоочистка логов включена (воскресенье 04:00)${reset}"
}

removeLogClearCron() {
    rm -f /etc/cron.d/xpro-clear-logs /usr/local/bin/clear-logs.sh
    echo "${yellow}Автоочистка логов выключена${reset}"
}

getLogClearCronStatus() {
    [ -f /etc/cron.d/xpro-clear-logs ] \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

# =================================================================
# МЕНЮ ЛОГОВ
# =================================================================
logsMenu() {
    while true; do
        clear
        local cron_status logs_size
        cron_status=$(getLogClearCronStatus)
        logs_size=$(getLogsSize 2>/dev/null || echo "unknown")

        echo ""
        echo "${cyan}══════════════════════════════════════${reset}"
        echo "${cyan}  Логи${reset}"
        echo "${cyan}══════════════════════════════════════${reset}"
        echo ""
        echo "  Размер:      $logs_size"
        echo "  Автоочистка: $cron_status"
        echo ""
        echo "  ${green}1.${reset} Очистить логи сейчас"
        echo "  ${green}2.${reset} Показать детали"
        echo "  ${green}3.${reset} Включить автоочистку (воскресенье 04:00)"
        echo "  ${green}4.${reset} Выключить автоочистку"
        echo "  ${green}5.${reset} Настроить logrotate"
        echo "  ${green}0.${reset} Назад"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1) clearLogs; read -r ;;
            2) showLogsDetails; read -r ;;
            3) setupLogClearCron; read -r ;;
            4) removeLogClearCron; read -r ;;
            5) setupLogrotate; read -r ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}