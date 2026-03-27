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
    "https://www.wikipedia.org"
    "https://www.debian.org"
    "https://www.ubuntu.com"
    "https://www.kernel.org"
    "https://www.gnu.org"
    "https://www.python.org"
    "https://www.nginx.org"
    "https://www.openssl.org"
    "https://www.archlinux.org"
    "https://www.freebsd.org"
    "https://www.openbsd.org"
    "https://www.netbsd.org"
    "https://www.mozilla.org"
    "https://www.apache.org"
    "https://www.postgresql.org"
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
# ОСНОВНОЙ КОНФИГ NGINX
# =================================================================
writeNginxConfig() {
    local domain="$1"
    local xui_port="$2"
    local cdn="${3:-off}"

    _setDefaultCert

    # Фейковый сайт — берём из xpro.conf или random
    local fake_url
    fake_url=$(xpro_conf_get "FAKE_SITE_URL")
    [ -z "$fake_url" ] && fake_url="${FAKE_SITES[0]}"

    local fake_host
    fake_host=$(echo "$fake_url" | sed 's|https://||;s|http://||;s|/.*||')

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
    listen 443 ssl;
    server_name ${domain};

    ssl_certificate     ${NGINX_CERT_DIR}/cert.pem;
    ssl_certificate_key ${NGINX_CERT_DIR}/cert.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    proxy_buffering off;
    proxy_cache     off;

    # Панель 3x-ui
    location /xui/ {
        proxy_pass http://127.0.0.1:${xui_port}/;
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
    }

    # WebSocket подключения Xray (все пути кроме /xui/)
    # Клиенты подключаются через Xray inbound напрямую по своим путям
    # Nginx проксирует их на порт Xray inbound (настраивается в 3x-ui)
    # Пример: если в 3x-ui inbound port=10000
    # location /your-ws-path/ {
    #     proxy_pass http://127.0.0.1:10000;
    #     proxy_http_version 1.1;
    #     proxy_set_header Upgrade \$http_upgrade;
    #     proxy_set_header Connection "upgrade";
    #     proxy_set_header Host \$host;
    #     proxy_read_timeout 3600s;
    #     proxy_send_timeout 3600s;
    #     proxy_socket_keepalive on;
    # }

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
    }

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
}
EOF

    # Применяем конфиг
    nginx -t && systemctl reload nginx || {
        echo "${red}Ошибка конфига nginx. Проверь: nginx -t${reset}"
        return 1
    }

    echo "${green}Nginx конфиг записан для ${domain}${reset}"
}

# =================================================================
# ФЕЙКОВЫЙ САЙТ
# =================================================================
setFakeSite() {
    local mode="${1:-random}"   # random | url | menu

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

    # Обновляем proxy_pass в конфиге
    if [ -f "$NGINX_XPRO_CONF" ]; then
        sed -i "s|proxy_pass https\?://[^;]*;|proxy_pass ${chosen_url};|" \
            "$NGINX_XPRO_CONF"
        # Заменяем Host хедер фейкового сайта — он единственный без \$host
        # (в location /xui/ используется \$host, у fake — реальное имя хоста)
        sed -i "s|proxy_set_header Host ${fake_host_prev:-[^$][^;]*};|proxy_set_header Host ${fake_host};|" \
            "$NGINX_XPRO_CONF" 2>/dev/null || true
        # Надёжный fallback — заменяем последний proxy_set_header Host без $ 
        python3 - "$NGINX_XPRO_CONF" "$fake_host" << 'PYEOF'
import sys, re
path, new_host = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
# Заменяем Host в location / (fake site) — строка без \$host
content = re.sub(
    r'(location\s*/\s*\{[^}]*proxy_set_header\s+Host\s+)([^$\s;][^;]*)(;)',
    lambda m: m.group(1) + new_host + m.group(3),
    content, flags=re.DOTALL
)
with open(path, 'w') as f:
    f.write(content)
PYEOF
        nginx -t && systemctl reload nginx
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
    # Удаляем все правила с комментарием ACME temp
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

    [ -z "$domain" ] && {
        echo "${red}Домен не указан${reset}"
        return 1
    }

    # Устанавливаем socat и acme.sh
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

    # Выбор метода получения сертификата
    echo ""
    echo "${cyan}Метод получения SSL сертификата:${reset}"
    echo "  ${green}1.${reset} Cloudflare DNS API (рекомендуется, домен не должен резолвиться на этот сервер)"
    echo "  ${green}2.${reset} Standalone HTTP (порт 80 должен быть доступен)"
    read -rp "  Выбор: " cert_method

    mkdir -p "$NGINX_CERT_DIR"

    if [ "$cert_method" = "1" ]; then
        # Cloudflare DNS API
        [ -f "$CF_KEY_FILE" ] && source "$CF_KEY_FILE"

        if [[ -z "${CF_Email:-}" || -z "${CF_Key:-}" ]]; then
            read -rp "  Cloudflare Email: " CF_Email
            read -rp "  Cloudflare Global API Key: " CF_Key
            printf "export CF_Email='%s'\nexport CF_Key='%s'\n" \
                "$CF_Email" "$CF_Key" > "$CF_KEY_FILE"
            chmod 600 "$CF_KEY_FILE"
        fi

        export CF_Email CF_Key

        ~/.acme.sh/acme.sh --issue --dns dns_cf \
            -d "$domain" \
            -d "*.${domain}" \
            --force

        xpro_conf_set "SSL_METHOD" "dns_cf"

    else
        # Standalone
        openPort80
        ~/.acme.sh/acme.sh --issue --standalone \
            -d "$domain" \
            --force
        closePort80

        xpro_conf_set "SSL_METHOD" "standalone"
    fi

    # Устанавливаем сертификат
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file      "${NGINX_CERT_DIR}/cert.key" \
        --fullchain-file "${NGINX_CERT_DIR}/cert.pem" \
        --reloadcmd     "systemctl reload nginx"

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
# Скачивает актуальные IP диапазоны CF и пишет конфиг nginx
# =================================================================
setupRealIpRestore() {
    echo "${cyan}Обновляем Cloudflare IP диапазоны...${reset}"

    local tmp
    tmp=$(mktemp) || return 1
    trap 'rm -f "$tmp"' RETURN

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

    nginx -t && systemctl reload nginx
    echo "${green}CF Real IP настроен${reset}"
}

# Cron для автообновления CF IP диапазонов раз в неделю
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
            # Убираем проверку из конфига домена
            sed -i '/cloudflare_ip.*!=.*1/d' "$NGINX_XPRO_CONF" 2>/dev/null || true
            nginx -t && systemctl reload nginx
            echo "${green}CF Guard отключён${reset}"
        fi
    else
        echo "${yellow}Внимание: CF Guard блокирует НЕ-Cloudflare IP.${reset}"
        echo "${yellow}Убедись что -cdn on и DNS записи проксируются через CF.${reset}"
        echo "Включить? (y/N)"
        read -r confirm
        [[ "$confirm" != "y" ]] && return 0

        # Скачиваем актуальные CF IP и строим geo блок
        local tmp
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

        # Добавляем проверку в location /xui/
        if ! grep -q "cloudflare_ip" "$NGINX_XPRO_CONF" 2>/dev/null; then
            sed -i '/location \/xui\/ {/a\        if ($cloudflare_ip != 1) { return 444; }' \
                "$NGINX_XPRO_CONF"
        fi

        nginx -t && systemctl reload nginx
        echo "${green}CF Guard включён — только Cloudflare IP${reset}"
    fi
}

getCfGuardStatus() {
    [ -f "${NGINX_CONF_DIR}/cf_guard.conf" ] \
        && echo "${green}ON${reset}" || echo "${red}OFF${reset}"
}

# =================================================================
# МЕНЮ NGINX
# =================================================================
nginxMenu() {
    while true; do
        clear
        local nginx_status cert_expiry cf_guard fake_url
        nginx_status=$(getServiceStatus nginx)
        cert_expiry=$(checkCertExpiry)
        cf_guard=$(getCfGuardStatus)
        fake_url=$(xpro_conf_get "FAKE_SITE_URL" || echo "не задан")

        echo ""
        echo "${cyan}══════════════════════════════════════${reset}"
        echo "${cyan}  Nginx / SSL${reset}"
        echo "${cyan}══════════════════════════════════════${reset}"
        echo ""
        echo "  Nginx:      $nginx_status"
        echo "  SSL:        $cert_expiry"
        echo "  CF Guard:   $cf_guard"
        echo "  Fake site:  $fake_url"
        echo ""
        echo "  ${green}1.${reset} Сменить фейковый сайт"
        echo "  ${green}2.${reset} Обновить SSL сертификат"
        echo "  ${green}3.${reset} Переполучить SSL (новый домен)"
        echo "  ${green}4.${reset} Включить/Выключить CF Guard"
        echo "  ${green}5.${reset} Обновить CF IP диапазоны"
        echo "  ${green}6.${reset} Перезапустить Nginx"
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
                nginx -t && systemctl reload nginx && \
                    echo "${green}Nginx перезапущен${reset}"
                read -r
                ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}
