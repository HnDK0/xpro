# X-UI PRO(Заброшено, но база работает)

Автоматический установщик и менеджер для 3x-ui с Nginx reverse proxy, SSL, анонимными туннелями и защитой сервера.

---

## Содержание

- [Требования](#требования)
- [Установка](#установка)
- [Аргументы установки](#аргументы-установки)
- [Примеры установки](#примеры-установки)
- [Что делает установщик](#что-делает-установщик)
- [Команда xpro](#команда-xpro)
- [Главное меню](#главное-меню)
- [WARP](#warp)
- [Tor](#tor)
- [Psiphon](#psiphon)
- [Nginx / SSL](#nginx--ssl)
- [Безопасность](#безопасность)
- [3x-ui](#3x-ui)
- [Логи](#логи)
- [Удаление](#удаление)
- [Файловая структура](#файловая-структура)

---

## Требования

- Linux (Ubuntu 20.04+ / Debian 11+ / CentOS 8+)
- Root доступ
- Домен с DNS записью, указывающей на IP сервера
- Порт 443 открыт

---

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) -domain example.com
```

---

## Аргументы установки

| Аргумент | Значения | По умолчанию | Описание |
|---|---|---|---|
| `-domain` | `example.com` | — | **Обязательный.** Домен для SSL и панели |
| `-panel` | `mhsanaei` / `alireza` | `mhsanaei` | Форк 3x-ui |
| `-cdn` | `on` / `off` | `off` | Режим Cloudflare CDN (проксирование через CF) |
| `-warp` | `on` / `off` | `off` | Установить Cloudflare WARP |
| `-tor` | `on` / `off` | `off` | Установить Tor |
| `-psiphon` | `on` / `off` | `off` | Установить Psiphon |
| `-ufw` | `on` / `off` | `off` | Включить UFW firewall |
| `-bbr` | `on` / `off` | `on` | Включить BBR congestion control |
| `-fake` | `on` / `off` | `on` | Фейковый сайт на главной странице |
| `-ssl-method` | `1` / `2` | интерактивно | Метод получения SSL: `1` = Cloudflare DNS API, `2` = Standalone HTTP |
| `-cf-email` | `user@example.com` | — | Email Cloudflare (только для `-ssl-method 1`) |
| `-cf-key` | `api_key` | — | Cloudflare Global API Key (только для `-ssl-method 1`) |

---

## Примеры установки

**Минимальная установка:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) \
  -domain example.com
```

**С WARP и Tor, SSL через Cloudflare DNS API:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) \
  -domain example.com \
  -warp on \
  -tor on \
  -ssl-method 1 \
  -cf-email user@cloudflare.com \
  -cf-key YOUR_API_KEY
```

**Полная установка с CDN и всеми туннелями:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) \
  -domain example.com \
  -cdn on \
  -warp on \
  -tor on \
  -psiphon on \
  -ufw on \
  -ssl-method 1 \
  -cf-email user@cloudflare.com \
  -cf-key YOUR_API_KEY
```

**Без фейкового сайта, с Standalone SSL:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) \
  -domain example.com \
  -fake off \
  -ssl-method 2
```

**Локальный запуск из репозитория:**
```bash
XPRO_LOCAL_DIR=/path/to/repo bash install.sh -domain example.com
```

---

## Что делает установщик

Установка идемпотентна — повторный запуск пропускает уже выполненные шаги.

| Шаг | Действие |
|---|---|
| 1 | Установка 3x-ui с рандомными credentials, портом и путём панели |
| 1б | Настройка пути подписки в БД 3x-ui |
| 2 | Установка Nginx |
| 3 | Получение SSL сертификата через acme.sh (Let's Encrypt) |
| 4 | Выбор случайного фейкового сайта |
| 5 | Запись Nginx конфига с reverse proxy для панели |
| 6 | Настройка Cloudflare Real IP restore |
| 7 | Установка WARP (если `-warp on`) |
| 8 | Установка Tor (если `-tor on`) |
| 9 | Установка Psiphon (если `-psiphon on`) |
| 9б | Запись outbound'ов WARP/Tor/Psiphon в шаблон Xray |
| 10 | Включение BBR (если `-bbr on`) |
| 11 | Sysctl оптимизации сети |
| 12 | Настройка logrotate |
| 13 | Настройка Fail2Ban (SSH) |
| 14 | Настройка UFW (если `-ufw on`) |
| 15 | Установка команды `xpro` |

После установки выводится итоговый экран с URL панели, логином, паролем и ссылкой на подписку.

---

## Команда xpro

После установки доступна глобальная команда:

```bash
xpro                    # Открыть главное меню
xpro update             # Обновить все модули xpro с репозитория
xpro status             # Показать статус всех сервисов
xpro sync-inbounds      # Синхронизировать WS/gRPC/xHTTP inbound'ы из 3x-ui в Nginx
xpro update-cf-ips      # Обновить Cloudflare IP диапазоны в Nginx
xpro check-warp         # Проверить IP через WARP
xpro check-tor          # Проверить IP через Tor
xpro check-psiphon      # Проверить IP через Psiphon
xpro uninstall          # Удалить X-UI PRO
```

### xpro update

Скачивает все модули (`core`, `xui`, `nginx`, `warp`, `tor`, `psiphon`, `security`, `logs`, `menu`) заново с GitHub. Обновляет команду `/usr/local/bin/xpro`. Сервисы не перезапускает.

```bash
xpro update
```

---

## Главное меню

```
xpro
```

Показывает статус всех сервисов: 3x-ui, Nginx, SSL, SSH порт, WARP, Tor, Psiphon. Навигация по разделам:

```
1. Управление WARP
2. Управление Tor
3. Управление Psiphon
4. Nginx / SSL
5. Безопасность
6. 3x-ui
7. Логи
0. Выход
```

---

## WARP

Cloudflare WARP как SOCKS5 прокси на `127.0.0.1:40000`. Используется как outbound в Xray для маршрутизации трафика через Cloudflare.

**Меню:** `xpro → 1`

| Действие | Описание |
|---|---|
| Установить WARP | Добавляет репозиторий Cloudflare, устанавливает `cloudflare-warp`, регистрирует и настраивает в режиме proxy |
| Запустить / Остановить | Управление сервисом `warp-svc` |
| Включить / Выключить автозагрузку | `systemctl enable/disable warp-svc` |
| Проверить IP | Делает запрос через `socks5://127.0.0.1:40000` и показывает внешний IP |
| Удалить WARP | Удаляет пакет, репозиторий, GPG ключ и systemd override |

**CLI:**
```bash
xpro check-warp    # Проверить IP через WARP
```

**Порт:** `40000`

---

## Tor

Tor как SOCKS5 прокси на `127.0.0.1:40003`. Поддерживает мосты (obfs4, meek, snowflake) и выбор страны выхода.

**Меню:** `xpro → 2`

| Действие | Описание |
|---|---|
| Установить Tor | Устанавливает из официального репозитория torproject.org (с fallback на зеркала EFF и mirror.torproject.org) |
| Запустить / Остановить | Управление сервисом `tor` |
| Включить / Выключить автозагрузку | `systemctl enable/disable tor` |
| Сменить страну выхода | Задаёт `ExitNodes {код_страны}` в `/etc/tor/torrc` |
| Настроить мосты | Выбор типа моста: obfs4 / meek-azure / snowflake. Для заблокированных регионов |
| Проверить IP | Делает запрос через `socks5://127.0.0.1:40003` и показывает внешний IP |
| Удалить Tor | Удаляет пакет и конфиг |

**CLI:**
```bash
xpro check-tor     # Проверить IP через Tor
```

**Порты:** SOCKS5 — `40003`, Control — `40004`

---

## Psiphon

Psiphon как SOCKS5 прокси на `127.0.0.1:40002`. Поддерживает разные режимы работы и выбор страны.

**Меню:** `xpro → 3`

| Действие | Описание |
|---|---|
| Установить Psiphon | Скачивает бинарь `psiphon-tunnel-core` под архитектуру сервера (x86_64 / aarch64 / armv7l) |
| Запустить / Остановить | Управление сервисом `psiphon` |
| Включить / Выключить автозагрузку | `systemctl enable/disable psiphon` |
| Сменить страну | Задаёт предпочтительную страну выхода |
| Сменить режим | `plain` — стандартный / другие режимы туннеля |
| Проверить IP | Делает запрос через `socks5://127.0.0.1:40002` и показывает внешний IP |
| Удалить Psiphon | Удаляет бинарь и systemd сервис |

**CLI:**
```bash
xpro check-psiphon    # Проверить IP через Psiphon
```

**Порт:** `40002`

---

## Nginx / SSL

**Меню:** `xpro → 4`

### Структура Nginx конфига

```
HTTPS :443
  ├── /{panel_path}/          → 3x-ui панель (proxy_pass http://127.0.0.1:{port})
  ├── /{ws_path}              → WebSocket inbound'ы (auto-sync из 3x-ui)
  ├── /{grpc_path}            → gRPC inbound'ы (auto-sync из 3x-ui)
  ├── /{xhttp_path}           → xHTTP inbound'ы (auto-sync из 3x-ui)
  ├── /{sub_path}/            → Подписка
  ├── /{sub_path}/json/       → JSON подписка
  └── /                       → Фейковый сайт
```

### Параметры proxy для каждого типа транспорта

**Панель 3x-ui:**
- `proxy_buffering on` — необходимо для корректной передачи статики (JS/CSS) по HTTP/2
- `proxy_buffer_size 16k`, `proxy_buffers 8 16k`
- `proxy_connect_timeout 10s`
- `proxy_next_upstream error timeout http_502 http_503` — автоповтор при недоступности

**WebSocket:**
- `if ($http_upgrade != "websocket") { return 404; }` — только WS соединения
- `proxy_buffering off`
- `proxy_read_timeout 604800s` / `proxy_send_timeout 604800s` (7 дней)
- `proxy_socket_keepalive on`

**gRPC:**
- `if ($request_method != "POST") { return 404; }` — только POST
- `proxy_buffering off`, `proxy_request_buffering off`
- `grpc_read_timeout 604800s` / `grpc_send_timeout 604800s` (7 дней)
- `grpc_socket_keepalive on`

**xHTTP:**
- `proxy_buffering off`, `proxy_request_buffering off`
- `proxy_read_timeout 168h` / `proxy_send_timeout 168h` (7 дней)
- `keepalive_timeout 168h`
- `proxy_socket_keepalive on`
- `client_max_body_size 0`

> IP клиента не передаётся на upstream ни в одном из транспортных блоков — анонимность сохраняется.

### Действия в меню Nginx

| Пункт | Описание |
|---|---|
| Сменить фейковый сайт | Случайный из списка / свой URL / выбор из списка |
| Обновить SSL сертификат | `acme.sh --renew` для текущего домена |
| Переполучить SSL | Новый домен, интерактивный выбор метода |
| Включить / Выключить CF Guard | Разрешить подключения только с Cloudflare IP |
| Обновить CF IP диапазоны | Скачивает актуальные IPv4/IPv6 диапазоны Cloudflare |
| Перезапустить Nginx | `nginx -t && systemctl reload nginx` |
| Синхронизировать inbound'ы | Читает WS/gRPC/xHTTP/sub из БД 3x-ui и обновляет Nginx конфиг |

### Синхронизация inbound'ов

```bash
xpro sync-inbounds
# или из меню: xpro → Nginx / SSL → 7
```

Читает все активные inbound'ы из БД `/etc/x-ui/x-ui.db` и автоматически обновляет зону `# xpro-sync-zone-begin ... # xpro-sync-zone-end` в Nginx конфиге. Cron задача обновляет каждые 5 минут автоматически.

### SSL методы

**Метод 1 — Cloudflare DNS API** (рекомендуется):
- Домен не обязан резолвиться на сервер во время выдачи
- Выдаёт wildcard `*.domain.com` + `domain.com`
- Требует Cloudflare Email и Global API Key

**Метод 2 — Standalone HTTP**:
- Порт 80 должен быть открыт и доступен
- Временно открывает порт 80, получает сертификат, закрывает

### CF Guard

Блокирует все подключения к панели не через Cloudflare. Включать только если домен проксируется через CF (оранжевое облако).

```
xpro → Nginx / SSL → 4
```

### Обновление CF IP (cron)

Каждый понедельник в 03:00 автоматически обновляет список IP-диапазонов Cloudflare в `/etc/nginx/conf.d/real_ip_restore.conf`.

```bash
xpro update-cf-ips    # Принудительное обновление
```

---

## Безопасность

**Меню:** `xpro → 5`

### BBR

TCP congestion control от Google. Увеличивает пропускную способность на каналах с потерями.

```
xpro → Безопасность → 1
```

### Fail2Ban

Защита SSH от брутфорса. После 3 неудачных попыток — бан на 24 часа.

```
xpro → Безопасность → 2
```

Конфиг: `/etc/fail2ban/jail.local`
- SSH: `maxretry=3`, `bantime=24h`
- Default: `maxretry=5`, `bantime=2h`, `findtime=10m`

### WebJail

Защита Nginx от сканеров. Банит IP за запросы к `.php`, `wp-login`, `admin`, `.env`, `.git` и другим типичным путям сканирования.

```
xpro → Безопасность → 3
```

- `maxretry=5`, `bantime=24h`
- Читает `/var/log/nginx/access.log`

### UFW

Файервол. Разрешает только SSH и HTTPS (443). Порт панели 3x-ui закрыт снаружи — доступ только через Nginx.

```
xpro → Безопасность → 4
```

Управление: открыть/закрыть порт, включить/выключить, сбросить правила.

### Смена SSH порта

```
xpro → Безопасность → 5
```

Автоматически: обновляет `sshd_config`, добавляет правило в UFW для нового порта, обновляет Fail2Ban.

### IPv6

```
xpro → Безопасность → 6
```

Включить / выключить IPv6 на уровне sysctl. Персистентно через `/etc/sysctl.d/99-xpro-ipv6.conf`.

### CPU Guard

Повышает приоритет сервисов `x-ui` и `nginx` (CPUWeight=200, Nice=-10) и снижает приоритет SSH сессий (CPUWeight=20). Защищает от просадок производительности под нагрузкой.

```
xpro → Безопасность → 7   # Включить
xpro → Безопасность → 8   # Удалить
```

### CF Guard

Разрешает подключения к панели только с IP адресов Cloudflare.

```
xpro → Безопасность → 9
```

> Включать только при активном проксировании через Cloudflare.

### Sysctl оптимизации

Применяются автоматически при установке. Файл: `/etc/sysctl.d/99-xpro-network.conf`

```
net.ipv4.icmp_echo_ignore_all = 1       # скрываем сервер от ping
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_keepalive_time = 120       # держит WS соединения через NAT
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
```

---

## 3x-ui

**Меню:** `xpro → 6`

| Пункт | Описание |
|---|---|
| Перезапустить 3x-ui | `systemctl restart x-ui` |
| Обновить 3x-ui | Скачивает последнюю версию с GitHub |
| Показать credentials | URL панели, логин, пароль, порт |
| Сменить порт панели | Меняет порт через `x-ui setting`, перезапускает сервис |
| Показать WS/gRPC/xHTTP inbound'ы | Читает из БД и выводит список с портами и путями |
| Синхронизировать inbound'ы → Nginx | Обновляет Nginx конфиг |
| Настроить подписку | Задаёт домен, путь и порт подписки в БД |
| Показать настройки подписки | Выводит текущие значения из БД |
| Отключить встроенный SSL панели | Очищает `webCertFile`/`webKeyFile` в БД (TLS терминируется на Nginx) |
| Пересоздать outbound'ы Xray | Записывает outbound'ы WARP/Tor/Psiphon в `xrayTemplateConfig` |
| Удалить 3x-ui | Полное удаление |

### Outbound'ы Xray

При установке автоматически добавляются три outbound'а в шаблон Xray:

```json
{ "tag": "warp",    "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 40000 }] } }
{ "tag": "tor",     "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 40003 }] } }
{ "tag": "psiphon", "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 40002 }] } }
```

Routing правила настраиваются вручную в панели 3x-ui. Неиспользуемые outbound'ы без routing rules не влияют на трафик.

Если шаблон не существовал (первая установка до входа в панель) — создаётся автоматически на основе дефолтного шаблона 3x-ui.

---

## Логи

**Меню:** `xpro → 7`

| Пункт | Описание |
|---|---|
| Очистить логи сейчас | Очищает Nginx, Psiphon, Tor логи + vacuum systemd journal (50MB / 7 дней) |
| Показать детали | Размер каждого лог-файла |
| Включить автоочистку | Cron задача каждое воскресенье в 04:00 |
| Выключить автоочистку | Удаляет cron задачу |
| Настроить logrotate | Ежедневная ротация Nginx логов (7 файлов), еженедельная для Psiphon/Tor (4 файла) |

**Логи:**
```
/var/log/nginx/access.log
/var/log/nginx/error.log
/var/log/psiphon/psiphon.log
/var/log/tor/notices.log
```

---

## Удаление

```bash
xpro uninstall
```

Удаляет: 3x-ui, Nginx конфиги xpro, WARP, Tor, Psiphon, cron задачи, модули xpro, команду `xpro`.

**Не удаляется:** SSL сертификат (`/etc/nginx/cert/`), acme.sh, конфиг `xpro.conf` (содержит Cloudflare ключи).

---

## Файловая структура

```
/usr/local/bin/xpro                  # Команда xpro (копия menu.sh)
/usr/local/lib/xpro/                 # Модули
  ├── core.sh                        # Утилиты, переменные, OS detection
  ├── menu.sh                        # Главное меню
  ├── xui.sh                         # Управление 3x-ui
  ├── nginx.sh                       # Nginx, SSL, синхронизация
  ├── warp.sh                        # Cloudflare WARP
  ├── tor.sh                         # Tor
  ├── psiphon.sh                     # Psiphon
  ├── security.sh                    # UFW, BBR, Fail2Ban, SSH
  └── logs.sh                        # Логи, logrotate

/usr/local/etc/xpro/xpro.conf        # Конфиг (домен, порты, credentials)

/etc/nginx/conf.d/xpro.conf          # Основной Nginx конфиг
/etc/nginx/conf.d/real_ip_restore.conf  # Cloudflare Real IP
/etc/nginx/conf.d/cf_guard.conf      # CF Guard (если включён)
/etc/nginx/cert/cert.pem             # SSL сертификат
/etc/nginx/cert/cert.key             # SSL ключ

/etc/x-ui/x-ui.db                   # БД 3x-ui (SQLite)

/etc/cron.d/xpro-cf-ips             # Cron: обновление CF IP (пн 03:00)
/etc/cron.d/xpro-sync-inbounds      # Cron: синхронизация inbound'ов (каждые 5 мин)
/etc/cron.d/xpro-clear-logs         # Cron: очистка логов (вс 04:00, если включена)

/etc/sysctl.d/99-xpro-network.conf  # Sysctl оптимизации
/etc/sysctl.d/99-xpro-ipv6.conf     # IPv6 настройки (если переключён)

/root/.cloudflare_api                # Cloudflare Email и API Key (chmod 600)
/root/.acme.sh/                      # acme.sh и сертификаты
```

---

## Конфиг xpro.conf

Хранится в `/usr/local/etc/xpro/xpro.conf`. Формат `KEY=VALUE`.

| Ключ | Описание |
|---|---|
| `DOMAIN` | Домен |
| `CDN` | `on` / `off` |
| `XUI_PANEL` | `mhsanaei` / `alireza` |
| `XUI_USER` | Логин панели |
| `XUI_PASS` | Пароль панели |
| `XUI_PORT` | Порт панели |
| `XUI_WEB_BASE_PATH` | Путь панели (например `/abc123/`) |
| `XUI_SUB_PATH` | Путь подписки (например `/xyz789/`) |
| `FAKE_SITE_URL` | URL фейкового сайта |
| `SSL_METHOD` | `dns_cf` / `standalone` |
| `WARP_INSTALLED` | `yes` / `no` |
| `TOR_INSTALLED` | `yes` / `no` |
| `PSIPHON_INSTALLED` | `yes` / `no` |
