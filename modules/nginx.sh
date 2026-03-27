#!/bin/bash
# =================================================================
# nginx.sh — Nginx reverse proxy, SSL, фейковый сайт, CF Guard
# =================================================================

NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_XPRO_CONF="${NGINX_CONF_DIR}/xpro.conf"
NGINX_CERT_DIR="/etc/nginx/cert"
CF_KEY_FILE="/root/.cloudflare_api"

# Список фейковых сайтов для proxy_pass
FAKE_SITES=(
    "https://natribu.org"
    "https://thatsthefinger.com"
    "https://cat-bounce.com"
    "https://hackertyper.net"
    "https://theuselessweb.com"
)

# =================================================================
# УСТАНОВКА NGINX
# =================================================================
installNginx() {
    if command -v nginx &>/dev/null; then
        echo "info: nginx уже установлен"
        return 0
    fi
    [ -z "${PACKAGE_MANAGEMENT_INSTALL:-}" ] && identifyOS
    installPackage "nginx"
    systemctl enable nginx
}

# =================================================================
# САМОПОДПИСАННЫЙ СЕРТИФИКАТ (fallback до получения реального)
# =================================================================
_setDefaultCert() {
    mkdir -p "$NGINX_CERT_DIR"
    if [ ! -f "${NGINX_CERT_DIR}/cert.pem" ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${NGINX_CERT_DIR}/cert.key" \
            -out "${NGINX_CERT_DIR}/cert.pem" \
            -subj "/CN=localhost" &>/dev/null
        echo "info: Создан временный self-signed сертификат"
    fi
}

# =================================================================
# NGINX RELOAD — безопасный, не падает если nginx ещё не запущен
# =================================================================
_nginx_reload() {
    if nginx -t 2>/dev/null; then
        # Пробуем reload, если не работает — start
        systemctl reload nginx 2>/dev/null || \
        systemctl restart nginx 2>/dev/null || \
        systemctl start nginx 2>/dev/null || true
    else
        echo "${red}Ошибка конфига nginx. Проверь: nginx -t${reset}"
        return 1
    fi
}

# Проверка: нужно ли пересоздавать конфиг (порт изменился или файл отсутствует)
# Возвращает 0 (true) если конфиг актуален и ничего делать не нужно,
# 1 (false) если нужна перезапись.
_nginx_conf_is_current() {
    local domain="$1"
    local xpro_conf="${NGINX_CONF_DIR:-/etc/nginx/conf.d}/xpro.conf"
    [ -f "$xpro_conf" ] || return 1
    grep -qF "server_name ${domain}" "$xpro_conf" || return 1
    local cfg_port db_port
    cfg_port=$(grep -oP 'proxy_pass http://127\.0\.0\.1:\K[0-9]+' "$xpro_conf" | head -1)
    db_port=$(xpro_conf_get "XUI_PORT")
    [ "$cfg_port" = "$db_port" ] || return 1
    nginx -t &>/dev/null || return 1
    return 0
}

# =================================================================
# ОСНОВНОЙ КОНФИГ NGINX
# =================================================================
writeNginxConfig() {
    local domain="$1"
    local cdn="${2:-off}"
    local xui_port="${3:-}"
    local web_path="${4:-}"

    # Если не переданы — читаем из xpro.conf
    [ -z "$xui_port" ] && xui_port=$(xpro_conf_get "XUI_PORT")
    [ -z "$web_path" ] && web_path=$(xpro_conf_get "XUI_WEB_BASE_PATH")
    [[ ! "$xui_port" =~ ^[0-9]+$ ]] && xui_port="2053"

    _setDefaultCert

    # Фейковый сайт — берём из xpro.conf или первый из списка
    local fake_url
    fake_url=$(xpro_conf_get "FAKE_SITE_URL" 2>/dev/null || true)
    [ -z "$fake_url" ] && fake_url="${FAKE_SITES[0]}"

    local fake_host
    fake_host=$(echo "$fake_url" | sed 's|https://||;s|http://||;s|/.*||')

    # Очищаем web_path от ANSI escape кодов и leading slash
    web_path=$(echo "$web_path" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
    web_path="${web_path#/}"
    [ -z "$web_path" ] && web_path=""

    # nginx.conf главный
    cat > /etc/nginx/nginx.conf << 'NGINXMAIN'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    tcp_nopush    on;
    tcp_nodelay   on;

    # Чуть больше таймаута CF (70s) чтобы не рвать соединения
    keepalive_timeout  75s;
    keepalive_requests 10000;

    server_tokens off;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json
               application/javascript application/xml+rss;

    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN

    # Редирект http → https
    cat > "${NGINX_CONF_DIR}/default.conf" << 'DEFAULTCONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl default_server;
    ssl_certificate     /etc/nginx/cert/cert.pem;
    ssl_certificate_key /etc/nginx/cert/cert.key;
    server_name _;
    return 444;
}
DEFAULTCONF

    # Основной конфиг домена
    cat > "$NGINX_XPRO_CONF" << EOF
server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate     ${NGINX_CERT_DIR}/cert.pem;
    ssl_certificate_key ${NGINX_CERT_DIR}/cert.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    proxy_buffering off;
    proxy_cache     off;

    # Панель 3x-ui — путь из WebBasePath (скрытый от сканеров)
    location /${web_path:-}/ {
        proxy_pass http://127.0.0.1:${xui_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # WebSocket для 3x-ui (live logs, stats)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Скрываем fingerprint-заголовки бэкенда
        proxy_hide_header X-Powered-By;
        proxy_hide_header Via;
        proxy_hide_header X-Cache;
        proxy_hide_header X-Runtime;
        proxy_hide_header Server;
    }

    # xpro-sync-zone-begin (auto-managed, do not edit manually)
    # xpro-sync-zone-end

    # Фейковый сайт — всё остальное
    location / {
        proxy_pass ${fake_url};
        proxy_http_version 1.1;
        proxy_set_header Host ${fake_host};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_ssl_server_name on;
        proxy_read_timeout 60s;

        # Скрываем fingerprint-заголовки фейкового сайта
        proxy_hide_header X-Powered-By;
        proxy_hide_header Via;
        proxy_hide_header X-Cache;
        proxy_hide_header Content-Security-Policy;
        proxy_hide_header X-Runtime;
        proxy_hide_header Server;
    }

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
}
EOF

    _nginx_reload
    echo "${green}Nginx конфиг записан для ${domain}${reset}"
}

# =================================================================
# ФЕЙКОВЫЙ САЙТ
# =================================================================
setFakeSite() {
    local mode="${1:-random}"

    local chosen_url=""

    case "$mode" in
        random)
            local idx=$(( RANDOM % ${#FAKE_SITES[@]} ))
            chosen_url="${FAKE_SITES[$idx]}"
            ;;
        url)
            read -rp "  Введи URL фейкового сайта (https://...): " chosen_url
            [[ "$chosen_url" =~ ^https?:// ]] || {
                echo "${red}Неверный URL${reset}"
                return 1
            }
            ;;
        menu)
            echo ""
            echo "${cyan}Выбери фейковый сайт:${reset}"
            echo "  ${green}1.${reset} Случайный"
            echo "  ${green}2.${reset} Свой URL"
            echo "  ${green}3.${reset} Выбрать из списка"
            read -rp "  Выбор: " fake_choice

            case "$fake_choice" in
                1) setFakeSite "random"; return ;;
                2) setFakeSite "url"; return ;;
                3)
                    echo ""
                    local i=1
                    for site in "${FAKE_SITES[@]}"; do
                        echo "  ${green}${i}.${reset} $site"
                        i=$((i+1))
                    done
                    read -rp "  Номер: " site_num
                    if [[ "$site_num" =~ ^[0-9]+$ ]] && \
                       [ "$site_num" -ge 1 ] && \
                       [ "$site_num" -le "${#FAKE_SITES[@]}" ]; then
                        chosen_url="${FAKE_SITES[$((site_num-1))]}"
                    else
                        echo "${red}Неверный номер${reset}"
                        return 1
                    fi
                    ;;
                *) echo "${red}Отменено${reset}"; return 1 ;;
            esac
            ;;
    esac

    local fake_host
    fake_host=$(echo "$chosen_url" | sed 's|https://||;s|http://||;s|/.*||')

    # Обновляем proxy_pass в конфиге если он уже существует
    if [ -f "$NGINX_XPRO_CONF" ]; then
        # Negative lookahead: заменяем только внешние proxy_pass (не 127.0.0.1)
        sed -i "s|proxy_pass https\?://\(127\.0\.0\.1\)\@!\([^;]*\);|proxy_pass ${chosen_url};|" \
            "$NGINX_XPRO_CONF"
        # Обновляем Host хедер фейкового сайта через python3
        python3 - "$NGINX_XPRO_CONF" "$fake_host" << 'PYEOF' 2>/dev/null || true
import sys, re
path, new_host = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = re.sub(
    r'(location\s*/\s*\{[^}]*proxy_set_header\s+Host\s+)([^$\s;][^;]*)(;)',
    lambda m: m.group(1) + new_host + m.group(3),
    content, flags=re.DOTALL
)
with open(path, 'w') as f:
    f.write(content)
PYEOF
        _nginx_reload || true
    fi

    xpro_conf_set "FAKE_SITE_URL" "$chosen_url"
    echo "${green}Фейковый сайт: ${chosen_url}${reset}"
}

# =================================================================
# PORT 80 — временно открыть/закрыть для ACME standalone
# =================================================================
openPort80() {
    ufw status 2>/dev/null | grep -q "inactive" && return 0
    ufw allow 80/tcp comment 'ACME temp' &>/dev/null
    echo "info: Порт 80 открыт для ACME"
}

closePort80() {
    ufw status 2>/dev/null | grep -q "inactive" && return 0
    ufw status numbered 2>/dev/null | \
        grep 'ACME temp' | \
        awk -F'[][]' '{print $2}' | \
        sort -rn | \
        while read -r n; do
            echo "y" | ufw delete "$n" &>/dev/null
        done
    echo "info: Порт 80 закрыт"
}

# =================================================================
# SSL — acme.sh + Cloudflare DNS или standalone
# =================================================================
configSSL() {
    local domain="${1:-$(xpro_conf_get DOMAIN)}"
    local cdn="${2:-$(xpro_conf_get CDN)}"
    # Третий аргумент: "1" = Cloudflare DNS API, "2" = standalone HTTP.
    # Если не задан — спрашиваем интерактивно.
    local method="${3:-}"
    local cf_email="${4:-}"
    local cf_key="${5:-}"

    [ -z "$domain" ] && {
        echo "${red}Домен не указан${reset}"
        return 1
    }

    installPackage "socat" || true

    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -fsSL https://get.acme.sh | sh -s email="acme@${domain}"
    fi

    [ ! -f ~/.acme.sh/acme.sh ] && {
        echo "${red}Не удалось установить acme.sh${reset}"
        return 1
    }

    ~/.acme.sh/acme.sh --upgrade --auto-upgrade &>/dev/null
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    echo ""
    echo "${cyan}Метод получения SSL сертификата:${reset}"
    echo "  ${green}1.${reset} Cloudflare DNS API (рекомендуется, домен не должен резолвиться на этот сервер)"
    echo "  ${green}2.${reset} Standalone HTTP (порт 80 должен быть доступен)"
    if [ -z "$method" ]; then
        read -rp "  Выбор: " cert_method
    else
        cert_method="$method"
        echo "  Выбор (non-interactive): ${cert_method}"
    fi

    mkdir -p "$NGINX_CERT_DIR"

    if [ "$cert_method" = "1" ]; then
        # Если cf_email и cf_key переданы как параметры — используем их
        if [ -n "$cf_email" ] && [ -n "$cf_key" ]; then
            CF_Email="$cf_email"
            CF_Key="$cf_key"
            printf "export CF_Email='%s'\nexport CF_Key='%s'\n" \
                "$CF_Email" "$CF_Key" > "$CF_KEY_FILE"
            chmod 600 "$CF_KEY_FILE"
        else
            # Иначе читаем из файла или спрашиваем интерактивно
            [ -f "$CF_KEY_FILE" ] && source "$CF_KEY_FILE"
            if [[ -z "${CF_Email:-}" || -z "${CF_Key:-}" ]]; then
                read -rp "  Cloudflare Email: " CF_Email
                read -rp "  Cloudflare Global API Key: " CF_Key
                printf "export CF_Email='%s'\nexport CF_Key='%s'\n" \
                    "$CF_Email" "$CF_Key" > "$CF_KEY_FILE"
                chmod 600 "$CF_KEY_FILE"
            fi
        fi

        export CF_Email CF_Key

        ~/.acme.sh/acme.sh --issue --dns dns_cf \
            -d "$domain" \
            -d "*.${domain}" \
            --force

        xpro_conf_set "SSL_METHOD" "dns_cf"

    else
        openPort80
        ~/.acme.sh/acme.sh --issue --standalone \
            -d "$domain" \
            --force
        closePort80

        xpro_conf_set "SSL_METHOD" "standalone"
    fi

    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file      "${NGINX_CERT_DIR}/cert.key" \
        --fullchain-file "${NGINX_CERT_DIR}/cert.pem" \
        --reloadcmd     "systemctl reload nginx 2>/dev/null || true"

    xpro_conf_set "DOMAIN" "$domain"
    echo "${green}SSL сертификат установлен для ${domain}${reset}"
}

renewCert() {
    local domain
    domain=$(xpro_conf_get "DOMAIN")
    [ -z "$domain" ] && {
        echo "${red}Домен не найден в конфиге${reset}"
        return 1
    }
    ~/.acme.sh/acme.sh --renew -d "$domain" --force
    echo "${green}Сертификат обновлён${reset}"
}

checkCertExpiry() {
    if [ -f "${NGINX_CERT_DIR}/cert.pem" ]; then
        local expire_date expire_epoch now_epoch days_left
        expire_date=$(openssl x509 -enddate -noout \
            -in "${NGINX_CERT_DIR}/cert.pem" | cut -d= -f2)
        expire_epoch=$(date -d "$expire_date" +%s)
        now_epoch=$(date +%s)
        days_left=$(( (expire_epoch - now_epoch) / 86400 ))

        if   [ "$days_left" -le 0  ]; then echo "${red}EXPIRED!${reset}"
        elif [ "$days_left" -lt 15 ]; then echo "${red}${days_left}d${reset}"
        else echo "${green}OK (${days_left}d)${reset}"
        fi
    else
        echo "${red}НЕТ${reset}"
    fi
}

# =================================================================
# CLOUDFLARE REAL IP RESTORE
# =================================================================
setupRealIpRestore() {
    echo "${cyan}Обновляем Cloudflare IP диапазоны...${reset}"

    local tmp=""
    tmp=$(mktemp) || return 1
    # Защищаем от unbound variable при set -u: tmp гарантированно строка
    trap 'rm -f "${tmp:-}"' RETURN

    printf '# Cloudflare Real IP Restore — auto-generated\n' > "$tmp"

    local ok=0
    for t in v4 v6; do
        local result
        result=$(curl -fsSL --connect-timeout 10 \
            "https://www.cloudflare.com/ips-${t}" 2>/dev/null) || continue
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "set_real_ip_from ${ip};" >> "$tmp"
            ok=1
        done < <(echo "$result" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$')
    done

    [ "$ok" -eq 0 ] && {
        echo "${red}Не удалось получить CF IP диапазоны${reset}"
        rm -f "$tmp"
        return 1
    }

    printf 'real_ip_header CF-Connecting-IP;\nreal_ip_recursive on;\n' >> "$tmp"

    mkdir -p "$NGINX_CONF_DIR"
    mv -f "$tmp" "${NGINX_CONF_DIR}/real_ip_restore.conf"

    # Не падаем если nginx ещё не запущен
    _nginx_reload || true
    echo "${green}CF Real IP настроен${reset}"
}

setupCfIpCron() {
    cat > /etc/cron.d/xpro-cf-ips << 'EOF'
# Обновление Cloudflare IP диапазонов каждый понедельник в 3:00
0 3 * * 1 root /usr/local/bin/xpro update-cf-ips
EOF
    chmod 644 /etc/cron.d/xpro-cf-ips
    echo "info: Cron CF IP обновления настроен"
}

# =================================================================
# CF GUARD — разрешить подключения только с CF IP
# =================================================================
toggleCfGuard() {
    if [ -f "${NGINX_CONF_DIR}/cf_guard.conf" ]; then
        echo "${yellow}CF Guard активен. Отключить? (y/N)${reset}"
        read -r confirm
        if [[ "$confirm" == "y" ]]; then
            rm -f "${NGINX_CONF_DIR}/cf_guard.conf"
            sed -i '/cloudflare_ip.*!=.*1/d' "$NGINX_XPRO_CONF" 2>/dev/null || true
            _nginx_reload || true
            echo "${green}CF Guard отключён${reset}"
        fi
    else
        echo "${yellow}Внимание: CF Guard блокирует НЕ-Cloudflare IP.${reset}"
        echo "${yellow}Убедись что -cdn on и DNS записи проксируются через CF.${reset}"
        echo "Включить? (y/N)"
        read -r confirm
        [[ "$confirm" != "y" ]] && return 0

        local tmp=""
        tmp=$(mktemp) || return 1

        printf '# CF Guard — allow only Cloudflare IPs\ngeo $realip_remote_addr $cloudflare_ip {\n    default 0;\n' > "$tmp"

        local ok=0
        for t in v4 v6; do
            local result
            result=$(curl -fsSL --connect-timeout 10 \
                "https://www.cloudflare.com/ips-${t}" 2>/dev/null) || continue
            while IFS= read -r ip; do
                [ -z "$ip" ] && continue
                echo "    ${ip} 1;" >> "$tmp"
                ok=1
            done < <(echo "$result" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$')
        done

        [ "$ok" -eq 0 ] && {
            echo "${red}Не удалось получить CF IP диапазоны${reset}"
            rm -f "$tmp"
            return 1
        }

        echo "}" >> "$tmp"
        mv -f "$tmp" "${NGINX_CONF_DIR}/cf_guard.conf"

        if ! grep -q "cloudflare_ip" "$NGINX_XPRO_CONF" 2>/dev/null; then
            local guard_path
            guard_path=$(xpro_conf_get "XUI_WEB_BASE_PATH")
            guard_path="${guard_path#/}"; guard_path="${guard_path%/}"
            # Если после strip получилась пустая строка — оставляем пустую (location /)
            [ -z "$guard_path" ] && guard_path=""
            sed -i "/location \/${guard_path:-} {/a\\        if (\$cloudflare_ip != 1) { return 444; }" \
                "$NGINX_XPRO_CONF"
        fi

        _nginx_reload || true
        echo "${green}CF Guard включён — только Cloudflare IP${reset}"
    fi
}

getCfGuardStatus() {
    [ -f "${NGINX_CONF_DIR}/cf_guard.conf" ] \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

# =================================================================
# АВТО-СИНХРОНИЗАЦИЯ WS / gRPC INBOUND'ОВ ИЗ 3X-UI
# =================================================================
syncXrayInbounds() {
    local xui_db="/etc/x-ui/x-ui.db"
    local domain
    domain=$(xpro_conf_get "DOMAIN")

    [ -f "$xui_db" ] || {
        echo "${red}Ошибка: База 3x-ui не найдена (${xui_db})${reset}"
        return 1
    }
    command -v jq     &>/dev/null || { echo "${red}Ошибка: jq не установлен${reset}"; return 1; }
    command -v sqlite3 &>/dev/null || { echo "${red}Ошибка: sqlite3 не установлен${reset}"; return 1; }
    [ -f "$NGINX_XPRO_CONF" ] || {
        echo "${red}Ошибка: ${NGINX_XPRO_CONF} не найден${reset}"
        return 1
    }

    local tmp_blocks
    tmp_blocks=$(mktemp)
    trap 'rm -f "$tmp_blocks"' RETURN

    local ws_count=0 grpc_count=0

    # ── WebSocket inbound'ы ──────────────────────────────────────
    while IFS='|' read -r port settings; do
        local path
        path=$(echo "$settings" | jq -r '.wsSettings.path // empty' 2>/dev/null)
        [ -z "$path" ] && continue

        cat >> "$tmp_blocks" << EOF
    # xpro-sync: ws ${port} ${path}
    location ${path} {
        proxy_pass             http://127.0.0.1:${port};
        proxy_http_version     1.1;
        proxy_set_header       Upgrade    \$http_upgrade;
        proxy_set_header       Connection "upgrade";
        proxy_set_header       Host       \$host;
        proxy_read_timeout     3600s;
        proxy_send_timeout     3600s;
        proxy_socket_keepalive on;
        access_log             off;
        error_log              /dev/null crit;
    }
    # xpro-sync-end

EOF
        ws_count=$((ws_count + 1))
    done < <(sqlite3 "$xui_db" \
        "SELECT port, stream_settings FROM inbounds
         WHERE protocol IN ('vless','vmess','trojan')
         AND stream_settings LIKE '%\"network\":\"ws\"%';")

    # ── gRPC inbound'ы ───────────────────────────────────────────
    while IFS='|' read -r port settings; do
        local service
        service=$(echo "$settings" | jq -r '.grpcSettings.serviceName // empty' 2>/dev/null)
        [ -z "$service" ] && continue

        cat >> "$tmp_blocks" << EOF
    # xpro-sync: grpc ${port} ${service}
    location /${service} {
        grpc_pass            grpc://127.0.0.1:${port};
        grpc_read_timeout    1h;
        grpc_send_timeout    1h;
        client_max_body_size 0;
        access_log           off;
        error_log            /dev/null crit;
    }
    # xpro-sync-end

EOF
        grpc_count=$((grpc_count + 1))
    done < <(sqlite3 "$xui_db" \
        "SELECT port, stream_settings FROM inbounds
         WHERE protocol IN ('vless','vmess','trojan')
         AND stream_settings LIKE '%\"network\":\"grpc\"%';")

    # ── Инжектируем блоки в xpro.conf через Python ───────────────
    python3 - "$NGINX_XPRO_CONF" "$tmp_blocks" << 'PYEOF'
import sys, re

conf_path = sys.argv[1]
blocks_path = sys.argv[2]

with open(conf_path) as f:
    content = f.read()

with open(blocks_path) as f:
    new_blocks = f.read()

# Удаляем все старые xpro-sync блоки внутри зоны
content = re.sub(
    r'(# xpro-sync-zone-begin[^\n]*\n).*?(    # xpro-sync-zone-end)',
    r'\1' + new_blocks + r'\2',
    content,
    flags=re.DOTALL
)

with open(conf_path, 'w') as f:
    f.write(content)
PYEOF

    _nginx_reload
    echo "${green}Синхронизировано: ${ws_count} WS, ${grpc_count} gRPC инбаундов${reset}"
}

_syncXrayInboundsStatus() {
    [ -f "$NGINX_XPRO_CONF" ] || { echo "—"; return; }
    local ws grpc
    ws=$(grep -c '# xpro-sync: ws'   "$NGINX_XPRO_CONF" 2>/dev/null || echo 0)
    grpc=$(grep -c '# xpro-sync: grpc' "$NGINX_XPRO_CONF" 2>/dev/null || echo 0)
    echo "${ws} WS, ${grpc} gRPC"
}

setupSyncCron() {
    cat > /etc/cron.d/xpro-sync-inbounds << 'EOF'
# Авто-синхронизация WS/gRPC inbound'ов из 3x-ui каждые 5 минут
*/5 * * * * root /usr/local/bin/xpro sync-inbounds 2>/dev/null
EOF
    chmod 644 /etc/cron.d/xpro-sync-inbounds
    echo "${green}Cron синхронизации inbound'ов настроен (каждые 5 минут)${reset}"
}

# =================================================================
# МЕНЮ NGINX
# =================================================================
nginxMenu() {
    while true; do
        clear
        local nginx_status cert_expiry cf_guard fake_url inbounds_status
        nginx_status=$(getServiceStatus nginx)
        cert_expiry=$(checkCertExpiry)
        cf_guard=$(getCfGuardStatus)
        fake_url=$(xpro_conf_get "FAKE_SITE_URL" 2>/dev/null || echo "не задан")
        inbounds_status=$(_syncXrayInboundsStatus)

        echo ""
        echo "${cyan}══════════════════════════════════════${reset}"
        echo "${cyan}  Nginx / SSL${reset}"
        echo "${cyan}══════════════════════════════════════${reset}"
        echo ""
        echo "  Nginx:      $nginx_status"
        echo "  SSL:        $cert_expiry"
        echo "  CF Guard:   $cf_guard"
        echo "  Fake site:  $fake_url"
        echo "  Inbounds:   $inbounds_status"
        echo ""
        echo "  ${green}1.${reset} Сменить фейковый сайт"
        echo "  ${green}2.${reset} Обновить SSL сертификат"
        echo "  ${green}3.${reset} Переполучить SSL (новый домен)"
        echo "  ${green}4.${reset} Включить/Выключить CF Guard"
        echo "  ${green}5.${reset} Обновить CF IP диапазоны"
        echo "  ${green}6.${reset} Перезапустить Nginx"
        echo "  ${green}7.${reset} Синхронизировать WS/gRPC inbound'ы"
        echo "  ${green}8.${reset} Настроить авто-синхронизацию (cron)"
        echo "  ${green}0.${reset} Назад"
        echo ""
        read -rp "  Выбор: " choice

        case "$choice" in
            1) setFakeSite "menu"; read -r ;;
            2) renewCert; read -r ;;
            3) configSSL; read -r ;;
            4) toggleCfGuard; read -r ;;
            5) setupRealIpRestore; read -r ;;
            6)
                _nginx_reload && echo "${green}Nginx перезапущен${reset}"
                read -r
                ;;
            7) syncXrayInbounds; read -r ;;
            8) setupSyncCron; read -r ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}