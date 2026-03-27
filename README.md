# X-PRO

Автоматизированный установщик и менеджер для [3x-ui (MHSanaei)](https://github.com/MHSanaei/3x-ui) с поддержкой Cloudflare WARP, Tor, Psiphon, Nginx reverse proxy, SSL и набором инструментов безопасности.

```
================================================================
   X-UI PRO v1.0  |  🇩🇪  1.2.3.4      06.04.2025 14:32
================================================================
  3x-ui:   RUNNING   example.com/xAbCdEfGhIjK/
  Nginx:   RUNNING   SSL: OK (87d)
  SSH:     port 22
----------------------------------------------------------------
  WARP:    ACTIVE
  Tor:     не установлен
  Psiphon: не установлен
================================================================

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

## Содержание

- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Аргументы установки](#аргументы-установки)
- [Idempotency — повторный запуск](#idempotency--повторный-запуск)
- [Структура проекта](#структура-проекта)
- [Модули](#модули)
  - [core.sh](#coresh)
  - [xui.sh](#xuish)
  - [nginx.sh](#nginxsh)
  - [warp.sh](#warpsh)
  - [tor.sh](#torsh)
  - [psiphon.sh](#psiphonsh)
  - [security.sh](#securitysh)
  - [logs.sh](#logssh)
- [Команда xpro](#команда-xpro)
- [Порты сервисов](#порты-сервисов)
- [Хранилище конфигурации](#хранилище-конфигурации)
- [Работа с Cloudflare CDN](#работа-с-cloudflare-cdn)
- [SSL сертификаты](#ssl-сертификаты)
- [Outbound в 3x-ui](#outbound-в-3x-ui)
- [Удаление](#удаление)
- [Известные ограничения](#известные-ограничения)
- [FAQ](#faq)

---

## Требования

| Параметр | Требование |
|---|---|
| ОС | Ubuntu 20.04 / 22.04 / 24.04, Debian 11/12, CentOS 8+ |
| Права | root |
| Архитектура | x86\_64, aarch64 (arm64), armv7l (только для Psiphon) |
| Домен | Обязателен, должен резолвиться на IP сервера (или через CF CDN) |
| Python | Python 3.x (для emoji флагов и вывода Psiphon конфига) |

**Зависимости** устанавливаются автоматически: `nginx`, `curl`, `gnupg2`, `sqlite3`, `socat`, `fail2ban`, `ufw`, `openssl`.

---

## Быстрый старт

### Минимальная установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) -domain example.com
```

Установит: 3x-ui (MHSanaei), Nginx, SSL, фейковый сайт, BBR, Fail2Ban, sysctl оптимизации.

### Полная автоматическая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) \
  -domain example.com \
  -ufw on \
  -bbr on \
  -ssl-method 1 \
  -cf-email user@example.com \
  -cf-key your_cloudflare_api_key
```

### После установки

```bash
xpro          # интерактивное меню
xpro status   # статус всех сервисов
```

---

## Аргументы установки

| Аргумент | Значения | По умолчанию | Описание |
|---|---|---|---|
| `-domain` | `example.com` | — | **Обязательный.** Домен для SSL и Nginx |
| `-panel` | `mhsanaei` \| `alireza` | `mhsanaei` | Форк 3x-ui |
| `-cdn` | `on` \| `off` | `off` | Cloudflare CDN режим |
| `-warp` | `on` \| `off` | `off` | Установить Cloudflare WARP |
| `-tor` | `on` \| `off` | `off` | Установить Tor |
| `-psiphon` | `on` \| `off` | `off` | Установить Psiphon |
| `-ufw` | `on` \| `off` | `off` | Настроить и включить UFW |
| `-bbr` | `on` \| `off` | `on` | Включить TCP BBR |
| `-fake` | `on` \| `off` | `on` | Установить фейковый сайт |
| `-ssl-method` | `1` \| `2` | интерактивно | Метод SSL: 1=Cloudflare DNS API, 2=standalone HTTP |
| `-cf-email` | `user@example.com` | — | Cloudflare Email (для ssl-method 1) |
| `-cf-key` | `api_key` | — | Cloudflare Global API Key (для ssl-method 1) |

> **Примечание:** Порт панели 3x-ui, логин, пароль и WebBasePath (24 символа) генерируются автоматически при установке через `x-ui setting`. Панель доступна только через HTTPS на порту 443 — прямой порт панели закрыт через UFW.

---

## Idempotency — повторный запуск

Установщик безопасно запускается повторно. Каждый шаг имеет отдельную проверку и пропускается если уже выполнен:

| Шаг | Условие пропуска |
|---|---|
| 3x-ui | `systemctl is-active x-ui` + бинарь на месте |
| SSL | Валидный Let's Encrypt сертификат для домена, срок > 14 дней, `acme.sh --list` управляет доменом |
| Nginx конфиг | `xpro.conf` содержит `server_name domain`, nginx тест проходит |
| CF Real IP | Файл `real_ip_restore.conf` существует и свежее 7 дней |
| Fail2Ban | `jail.local` содержит `bantime = 24h`, сервис активен |
| UFW | Статус `active`, правило `443` + правило для порта панели |
| Sysctl | Файл `/etc/sysctl.d/99-xpro-network.conf` содержит `somaxconn` и `tcp_keepalive` |
| BBR | `sysctl net.ipv4.tcp_congestion_control == bbr` |
| WARP / Tor / Psiphon | Бинарь + `systemctl is-active` + флаг `*_INSTALLED=yes` в xpro.conf |

---

## Структура проекта

```
x-ui-pro/
├── install.sh          # Установщик (14 шагов, idempotent)
├── menu.sh             # Главное меню (команда xpro)
└── modules/
    ├── core.sh         # Утилиты, переменные, OS detection
    ├── xui.sh          # Управление 3x-ui и его API
    ├── nginx.sh        # Nginx, SSL, фейковый сайт, CF Guard
    ├── warp.sh         # Cloudflare WARP
    ├── tor.sh          # Tor с мостами и выбором страны
    ├── psiphon.sh      # Psiphon (plain и WARP+Psiphon режимы)
    ├── security.sh     # UFW, BBR, Fail2Ban, SSH, IPv6, CPU Guard
    └── logs.sh         # Логи, logrotate, автоочистка
```

После установки модули копируются в `/usr/local/lib/xpro/`, конфиг — в `/usr/local/etc/xpro/xpro.conf`.

### Загрузка модулей

`install.sh` поддерживает два источника модулей:

- **GitHub (по умолчанию):** скачивает каждый `.sh` из `https://raw.githubusercontent.com/HnDK0/xpro/main/modules/`
- **Локальная копия:** если задана переменная `XPRO_LOCAL_DIR=/path/to/repo`, копирует из неё — удобно для разработки без пуша

```bash
XPRO_LOCAL_DIR=/home/user/xpro bash install.sh -domain example.com
```

---

## Модули

### core.sh

Базовый модуль. Загружается первым, предоставляет общие функции для всех остальных модулей.

**Переменные:**

```bash
XPRO_VERSION="1.0"
XPRO_LIB="/usr/local/lib/xpro"
XPRO_CONF="/usr/local/etc/xpro/xpro.conf"

WARP_PORT=40000
PSIPHON_PORT=40002
TOR_PORT=40003
TOR_CONTROL_PORT=40004
```

**Ключевые функции:**

| Функция | Описание |
|---|---|
| `identifyOS` | Определяет ОС, настраивает `PACKAGE_MANAGEMENT_INSTALL/REMOVE/UPDATE` |
| `installPackage pkg` | Устанавливает пакет с автоматической починкой зависимостей (`dpkg --configure -a`) |
| `uninstallPackage pkg` | Удаляет пакет через менеджер пакетов ОС |
| `isRoot` | Проверяет root права, завершает с сообщением если нет |
| `setupSwap` | Создаёт swap если < 256MB: 1GB для RAM ≤ 1GB, 2GB для ≤ 2GB |
| `getServerIP` | Публичный IPv4 с 5 fallback-сервисами, пропускает приватные адреса |
| `getCountryCode ip` | Код страны по IP через ip-api.com |
| `getCountryFlag code` | Emoji флаг (`🇩🇪`, `🇺🇸`) через Python unicode |
| `checkServiceIP proxy name` | Проверяет IP через SOCKS5 прокси с fallback'ами, выводит страну |
| `getServiceStatus svc` | `RUNNING`/`STOPPED` с цветом для systemd сервиса |
| `xpro_conf_get key` | Читает значение из xpro.conf |
| `xpro_conf_set key val` | Записывает/обновляет значение в xpro.conf (создаёт файл если нет) |
| `xpro_conf_del key` | Удаляет ключ из xpro.conf |
| `run_task "описание" команда` | Выполняет команду с выводом `[DONE]`/`[FAIL]` |
| `generateRandomPath` | Случайный URL-путь из 12 символов, проверяет коллизии с nginx locations |
| `generateFreePort` | Свободный случайный порт 10000–65000, проверяет через `ss -tlnp` |
| `setupAlias` | Копирует menu.sh из `XPRO_LIB` в `/usr/local/bin/xpro` |

**Цвета** используют `tput` для совместимости с терминалами без поддержки ANSI escape: `red`, `green`, `yellow`, `cyan`, `reset`.

**`_pad()`** — выравнивает строки с ANSI escape кодами по нужной ширине, убирая escape-последовательности при подсчёте видимой длины.

---

### xui.sh

Управление 3x-ui панелью и её REST API.

**Установка и обновление:**

| Функция | Описание |
|---|---|
| `install3xui [panel]` | Устанавливает 3x-ui через официальный скрипт MHSanaei или Alireza |
| `update3xui` | Обновляет до последней версии, перезапускает сервис |
| `remove3xui` | Полное удаление с подтверждением, очищает xpro.conf |

**Порт и credentials — генерируются скриптом:**

При установке скрипт сам генерирует порт (случайный 10000–65000), логин (8 символов), пароль (16 символов) и WebBasePath (24 символа), затем устанавливает их через `x-ui setting`. Это гарантирует что credentials всегда известны.

| Функция | Описание |
|---|---|
| `xuiGetPort` | Порт панели из `x-ui settings` |
| `xuiGetUser` | Логин панели из `x-ui settings` |
| `xuiGetPass` | Пароль панели из `x-ui settings` |
| `xuiGetWebBasePath` | Путь панели в формате `/path/` из `x-ui settings` |
| `xuiSetPort port` | Меняет порт через `x-ui setting -port`, перезапускает сервис |
| `xuiWaitForDB [timeout]` | Ждёт инициализации БД: файл существует, порт числовой, user не пустой |

**API функции:**

Все API запросы работают через сессионный cookie (`/tmp/xpro_xui_session`). При истечении сессии или ответе `"success":false` логин происходит автоматически. URL строится с учётом `WebBasePath`.

| Функция | Endpoint | Описание |
|---|---|---|
| `xuiApiLogin` | `POST /{webBasePath}/login` | Авторизация, сохранение cookie |
| `xuiApiAddOutbound tag addr port` | `POST /xui/xray/outbounds/add` | Добавляет SOCKS5 outbound (если существует — удаляет и добавляет заново) |
| `xuiApiDelOutbound tag` | `POST /xui/xray/outbounds/del/{tag}` | Удаляет outbound по тегу |
| `xuiApiListOutbounds` | `GET /xui/xray/outbounds/list` | Список всех outbound'ов |
| `xuiApiRestart` | `POST /xui/xray/restart` | Перезапуск Xray, fallback на `systemctl restart x-ui` |

**Меню 3x-ui** (`xpro` → пункт 6):
- Перезапустить 3x-ui / Xray
- Обновить 3x-ui
- Показать credentials и URL панели
- Сменить порт панели (с валидацией 1024–65535)
- Список outbound'ов с форматированным выводом через python3

---

### nginx.sh

Nginx как reverse proxy перед 3x-ui с SSL, фейковым сайтом и защитой Cloudflare.

**Схема проксирования:**

```
Клиент → :443 (Nginx, TLS termination)
    ├── /{webBasePath}/  → 127.0.0.1:{xui_port}   # панель 3x-ui
    └── /                → https://fake-site.com    # маскировка (proxy_pass)
```

**Конфигурация:**

| Функция | Описание |
|---|---|
| `installNginx` | Установка nginx, enable в systemd |
| `writeNginxConfig domain cdn` | Записывает основной конфиг в `/etc/nginx/conf.d/xpro.conf` |
| `setFakeSite [random\|url\|menu]` | Меняет фейковый сайт: `random` — случайный из списка, `url` — конкретный, `menu` — интерактивный выбор |

**Фейковые сайты** (15 встроенных):
`wikipedia.org`, `debian.org`, `ubuntu.com`, `kernel.org`, `gnu.org`, `python.org`, `nginx.org`, `openssl.org`, `archlinux.org`, `freebsd.org`, `openbsd.org`, `netbsd.org`, `mozilla.org`, `apache.org`, `postgresql.org`

Можно выбрать случайный, из списка или ввести собственный URL. Выбранный сайт сохраняется в `xpro.conf` → `FAKE_SITE_URL`.

**SSL:**

| Функция | Описание |
|---|---|
| `configSSL domain cdn [method]` | Интерактивная настройка: CF DNS API или standalone. При передаче `method` пропускает вопрос |
| `renewCert` | Принудительное обновление через acme.sh |
| `checkCertExpiry` | Дней до истечения с цветовой индикацией: зелёный (>30d), жёлтый (>14d), красный (<14d) |
| `openPort80` / `closePort80` | Временное открытие :80 для ACME HTTP challenge |

**Cloudflare Real IP:**

| Функция | Описание |
|---|---|
| `setupRealIpRestore` | Скачивает актуальные CF IP диапазоны (ipv4/ipv6), пишет `real_ip_restore.conf` с директивами `set_real_ip_from` |
| `setupCfIpCron` | Cron задание `/etc/cron.d/xpro-cf-ips`: обновление CF IP каждый понедельник в 3:00 |
| `toggleCfGuard` | Включает/выключает блокировку не-CF IP на endpoint'е панели |
| `getCfGuardStatus` | Статус CF Guard (`ON`/`OFF`) |

> **CF Guard:** При включении блокирует прямые подключения к серверу, пропуская только трафик через Cloudflare. Требует `-cdn on`. Конфиг: `/etc/nginx/conf.d/cf_guard.conf`.

---

### warp.sh

Cloudflare WARP в режиме SOCKS5 прокси на `127.0.0.1:40000`.

**Как работает:** WARP запускается как системный сервис (`warp-svc`), `warp-cli` переключается в режим `proxy` и слушает на `127.0.0.1:40000`. Xray использует этот SOCKS5 как outbound для выбранных inbound'ов.

**Функции:**

| Функция | Описание |
|---|---|
| `installWarp` | Очищает мусорные CF-репозитории, добавляет актуальный, устанавливает `cloudflare-warp` |
| `configWarp` | Регистрация (3 попытки), режим proxy, порт 40000, `warp-cli connect`, автозапуск |
| `startWarp` / `stopWarp` | Запуск/остановка сервиса + CLI connect/disconnect |
| `enableWarp` / `disableWarp` | Автозагрузка вкл/выкл |
| `removeWarp` | Полное удаление с подтверждением, очистка репозитория и outbound из 3x-ui |
| `addWarpOutbound` | Добавляет SOCKS5 outbound `warp` в 3x-ui через API |
| `removeWarpOutbound` | Удаляет outbound `warp` из 3x-ui |
| `checkWarpIP` | Проверяет IP через WARP с 5 fallback URL |
| `getWarpStatus` | `ACTIVE` / `DISCONNECTED` / `STOPPED` / `НЕ УСТАНОВЛЕН` с цветами |
| `getWarpAutostart` | `ON`/`OFF` — статус `systemctl is-enabled warp-svc` |

**Совместимость версий:** `_warp_cmd()` автоматически определяет нужен ли флаг `--accept-tos` для текущей версии `warp-cli` — проверяет `warp-cli --help`.

**Systemd override:** Устанавливается drop-in `/etc/systemd/system/warp-svc.service.d/restart.conf` с `Restart=on-failure, RestartSec=10s` вместо встроенного watchdog. Это устраняет проблему зависания сервиса при рестарте на некоторых VPS.

**Меню WARP** (`xpro` → пункт 1) — динамические пункты:
- Если warp-cli не установлен → `Установить WARP`
- Если сервис активен → `Остановить WARP`, иначе `Запустить WARP`
- Если автозагрузка включена → `Выключить`, иначе `Включить`
- Добавить / Удалить outbound в 3x-ui
- Проверить IP
- Удалить WARP

---

### tor.sh

Tor с поддержкой мостов (obfs4, snowflake, meek-azure) и выбором страны выхода.

**Установка:** Автоматически перебирает зеркала с таймаутом 5 секунд на каждое. Это важно для серверов в РФ и других странах где официальный репозиторий заблокирован.

**Порядок зеркал:**

| Зеркало | URL | Примечание |
|---|---|---|
| Официальный | `deb.torproject.org/torproject.org` | Заблокирован в РФ |
| EFF | `tor.eff.org/torproject.org` | Зеркало EFF |
| Official mirror | `mirror.torproject.org/debian` | Официальное зеркало Tor Project |
| Системный репо | — | Финальный fallback, версия может быть старее |

Все зеркала используют один GPG ключ Tor Project. Использованное зеркало сохраняется в `xpro.conf` (`TOR_MIRROR`). GPG ключ скачивается последовательно с каждого зеркала; финальный fallback — `keyserver.ubuntu.com`.

**Дополнительные пакеты:**
- `tor-geoipdb` — для `ExitNodes {XX}` по коду страны
- `obfs4proxy` — для obfs4 и meek мостов
- `snowflake-client` — для snowflake (если доступен в репо)

**Функции:**

| Функция | Описание |
|---|---|
| `installTor` | Установка через torproject.org репо + fallback'и |
| `upgradeTor` | Обновление до последней версии |
| `configTor [country] [bridge_type]` | Записывает torrc: SocksPort, ControlPort, мосты, страна |
| `startTor` / `stopTor` / `restartTor` | Управление сервисом |
| `enableTor` / `disableTor` | Автозагрузка |
| `removeTor` | Удаление + очистка outbound из 3x-ui |
| `setTorCountry` | Интерактивная смена ExitNodes в работающем torrc |
| `configureTorBridges` | Выбор и настройка типа моста |
| `addTorOutbound` / `removeTorOutbound` | Управление outbound в 3x-ui |
| `checkTorIP` | Проверка IP через Tor SOCKS5 (до 30 сек ожидания) |
| `getTorStatus` | Статус + страна + тип моста |

**Страны выхода:**
`AT BE BG BR CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK UA US`

**Типы мостов:**

| Тип | Описание | Требует |
|---|---|---|
| `obfs4` | Обфускация трафика | obfs4proxy, мосты с bridges.torproject.org |
| `snowflake` | Через WebRTC | snowflake-client |
| `meek-azure` | Маскировка под Azure CDN | obfs4proxy |
| `custom` | Собственные мосты любого типа | obfs4proxy или snowflake |

Свои obfs4/custom мосты сохраняются в `/usr/local/etc/xpro/tor_bridges.txt`.

---

### psiphon.sh

Psiphon в двух режимах: обычный (`plain`) и `WARP+Psiphon` — трафик Psiphon туннелируется через WARP.

**Бинарь:** Загружается напрямую с [GitHub Psiphon-Labs](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries).

**Поддерживаемые архитектуры:** `x86_64`, `aarch64` (arm64), `armv7l`. Проверяется на этапе `pre_checks` установщика — установка прерывается заранее если архитектура несовместима.

**Функции:**

| Функция | Описание |
|---|---|
| `installPsiphon` | Загрузка бинаря под текущую архитектуру в `/usr/local/bin/psiphon-tunnel-core` |
| `writePsiphonConfig [country] [mode]` | Пишет JSON конфиг: порт, `EgressRegion`, `UpstreamProxyUrl` (для WARP+режима) |
| `writePsiphonService` | Создаёт systemd unit `/etc/systemd/system/psiphon.service` |
| `startPsiphon` / `stopPsiphon` / `restartPsiphon` | Управление сервисом |
| `enablePsiphon` / `disablePsiphon` | Автозагрузка |
| `removePsiphon` | Полное удаление бинаря, конфига и systemd unit |
| `setPsiphonCountry` | Смена `EgressRegion` в JSON конфиге без пересоздания |
| `setPsiphonMode` | Переключение plain ↔ WARP+Psiphon (проверяет активность `warp-svc`) |
| `addPsiphonOutbound` / `removePsiphonOutbound` | Управление outbound в 3x-ui |
| `checkPsiphonIP` | Проверка IP через Psiphon SOCKS5 (до 30 сек) |
| `getPsiphonStatus` | Статус + страна + режим |

**Режим WARP+Psiphon:**

```
Xray → Psiphon (SOCKS5 :40002)
           ↓ UpstreamProxyUrl: socks5://127.0.0.1:40000
       WARP (SOCKS5 :40000)
           ↓
       Cloudflare WARP Network
```

Psiphon туннелирует весь свой трафик через WARP. Полезно для регионов где Psiphon блокируется напрямую, но WARP работает.

**Конфиг:** `/usr/local/etc/xpro/psiphon.json`  
**Логи:** `/var/log/psiphon/psiphon.log`

---

### security.sh

Комплексные инструменты защиты сервера.

#### BBR

```bash
enableBBR    # Проверяет текущее состояние, применяет через sysctl
getBbrStatus # ON / OFF
```

> **Совместимость с 3x-ui:** 3x-ui умеет включать BBR сам через панель. Перед включением через xpro проверяется текущее состояние — двойное включение безопасно.

#### Fail2Ban

```bash
setupFail2Ban    # SSH защита: 3 попытки → бан на 24ч
setupWebJail     # nginx-probe jail: блокировка сканеров .php/wp-login/.env/.git
getF2BStatus     # ON / OFF
getWebJailStatus # ON / inactive / OFF
```

`setupFail2Ban` автоматически определяет backend:
- Ubuntu ≤ 20.04 / файл `/var/log/auth.log` существует → backend `auto`
- Ubuntu 22.04+ (journald) → backend `systemd`

> Системный Fail2Ban защищает SSH и Nginx. Встроенная защита панели 3x-ui работает независимо — конфликта нет.

#### UFW

```bash
setupUFW port cdn    # Начальная настройка: SSH, 443, опционально порт панели
manageUFW            # Интерактивное управление (открыть/закрыть порт, вкл/выкл)
getUfwStatus         # ACTIVE / INACTIVE
```

При `-cdn on` порт панели 3x-ui **не открывается** снаружи — панель доступна только через `https://domain/{webBasePath}/`.

#### SSH порт

```bash
changeSshPort    # Меняет порт в sshd_config, перезапускает sshd, открывает новый порт в UFW
```

> **Внимание:** Перед закрытием текущей SSH сессии обязательно проверь подключение на новый порт в отдельной вкладке.

#### IPv6

```bash
toggleIPv6     # Включить/выключить IPv6 через sysctl
getIPv6Status  # ON / OFF
```

Настройки сохраняются в `/etc/sysctl.d/99-xpro.conf` в отдельном блоке. `applySysctl` **не трогает** IPv6 — управление только через `toggleIPv6`.

#### CPU Guard

```bash
setupCpuGuard    # x-ui и nginx: CPUWeight=200, Nice=-10; user.slice: CPUWeight=20
removeCpuGuard   # Убирает drop-in конфиги, сбрасывает на дефолт (100)
getCpuGuardStatus # ON / OFF
```

Создаёт persistent drop-in конфиги в `/etc/systemd/system/{svc}.service.d/cpuguard.conf`. Полезно на серверах с ограниченными ресурсами — гарантирует приоритет x-ui и nginx.

#### Sysctl оптимизации

`applySysctl` записывает в `/etc/sysctl.d/99-xpro-network.conf`:

```
net.ipv4.icmp_echo_ignore_all = 1     # скрываем сервер от ping
net.core.somaxconn = 65535            # очередь входящих соединений
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_keepalive_time = 120     # поддержка WebSocket через мобильный NAT
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
```

IPv6 в этот файл **не пишется** — управляется через `toggleIPv6` отдельно.

### logs.sh

Управление логами: просмотр размера, очистка, ротация и автоочистка по расписанию.

**Отслеживаемые логи:**

| Файл | Описание |
|---|---|
| `/var/log/nginx/access.log` | Access log Nginx |
| `/var/log/nginx/error.log` | Error log Nginx |
| `/var/log/psiphon/psiphon.log` | Лог Psiphon |
| `/var/log/tor/notices.log` | Лог Tor |
| systemd journal | Логи 3x-ui, WARP (управляются через journalctl) |

**Функции:**

| Функция | Описание |
|---|---|
| `getLogsSize` | Общий размер файловых логов + journal |
| `showLogsDetails` | Размер каждого файла отдельно |
| `clearLogs` | Очистка файловых логов (`: > file`) + journal vacuum (50MB, 7 дней) |
| `setupLogrotate` | Настройка ротации: Nginx — daily/7 дней, Psiphon/Tor — weekly/4 недели |
| `setupLogClearCron` | Автоочистка каждое воскресенье в 04:00 через cron |
| `removeLogClearCron` | Отключение автоочистки |
| `getLogClearCronStatus` | Статус: `ON` / `OFF` |

**Меню логов** (`xpro` → пункт 7):
- Очистить логи сейчас (показывает сколько KB освобождено)
- Показать детали (размер каждого файла)
- Включить/выключить автоочистку (воскресенье 04:00)
- Настроить logrotate

**Logrotate** создаётся в `/etc/logrotate.d/xpro`:
- Nginx: daily, rotate 7, compress, dateext
- Psiphon/Tor: weekly, rotate 4, compress

**Cron автоочистка:**
- Скрипт: `/usr/local/bin/clear-logs.sh`
- Расписание: `/etc/cron.d/xpro-clear-logs` — каждое воскресенье в 04:00
- Действие: очищает файлы логов + journal vacuum до 50MB

---

## Команда xpro

После установки доступна глобальная команда `xpro` (копия `menu.sh` в `/usr/local/bin/xpro`):

```bash
xpro                  # Интерактивное меню
xpro status           # Статус всех сервисов без входа в меню
xpro update-cf-ips    # Обновить CF IP диапазоны (вызывается cron'ом)
xpro check-warp       # Быстрая проверка IP через WARP
xpro check-tor        # Быстрая проверка IP через Tor
xpro check-psiphon    # Быстрая проверка IP через Psiphon
xpro uninstall        # Полное удаление X-UI PRO
```

`xpro status` выводит полный статусный экран без входа в интерактивный режим — удобно для мониторинга через cron или скриптов.

---

## Порты сервисов

| Сервис | Адрес | Протокол |
|---|---|---|
| 3x-ui панель | `127.0.0.1:{random}` | HTTP (только через Nginx) |
| Nginx HTTPS | `0.0.0.0:443` | HTTPS |
| WARP | `127.0.0.1:40000` | SOCKS5 |
| Psiphon | `127.0.0.1:40002` | SOCKS5 |
| Tor SOCKS | `127.0.0.1:40003` | SOCKS5 |
| Tor Control | `127.0.0.1:40004` | TCP |

Все локальные сервисы слушают только на `127.0.0.1` — недоступны снаружи напрямую.

---

## Хранилище конфигурации

Файл: `/usr/local/etc/xpro/xpro.conf`

```ini
DOMAIN=example.com
CDN=off
XUI_PANEL=mhsanaei
XUI_PORT=54321
XUI_USER=admin
XUI_PASS=xxxxxxxxx
XUI_WEB_BASE_PATH=/xAbCdEfGhIjK/
WARP_INSTALLED=yes
TOR_INSTALLED=yes
PSIPHON_INSTALLED=no
SSL_METHOD=dns_cf
FAKE_SITE_URL=https://www.debian.org
OUTBOUND_WARP_ADDED=yes
OUTBOUND_TOR_ADDED=yes
TOR_COUNTRY=DE
TOR_BRIDGE_TYPE=obfs4
TOR_MIRROR=tor.eff.org/torproject.org
PSIPHON_MODE=plain
```

Файл **не удаляется** при `xpro uninstall` — там могут храниться Cloudflare API ключи.

Cloudflare API ключи: `/root/.cloudflare_api` (права 600)

---

## Работа с Cloudflare CDN

### Требования для `-cdn on`

1. DNS запись для домена проксируется через CF (оранжевое облако ☁)
2. SSL/TLS режим в CF: **Full (strict)**
3. WebSockets: включены (Settings → Network → WebSockets)

### Что меняется при `-cdn on`

- Порт панели 3x-ui **не открывается** в UFW — только `443` и SSH
- Панель доступна только через `https://domain/{webBasePath}/`
- CF Guard (`toggleCfGuard`) блокирует прямые подключения к серверу
- CF IP диапазоны обновляются автоматически раз в неделю через cron

### Ограничения CF Free плана

- Timeout CF: 70 секунд. Nginx настроен на `keepalive_timeout 75s` (с запасом)
- WebSocket соединения работают, но могут рваться при длинных idle периодах
- Для долгих WS соединений рекомендуется настроить keepalive на стороне клиента

---

## SSL сертификаты

Используется [acme.sh](https://github.com/acmesh-official/acme.sh) с Let's Encrypt.

### Метод 1: Cloudflare DNS API (рекомендуется)

Не требует открытого порта 80. Работает с CDN. Получает wildcard сертификат (`*.domain.com`).

Требует Cloudflare Email и **Global API Key** (не Token — нужен именно Key):

```
Cloudflare Dashboard → My Profile → API Tokens → Global API Key
```

### Метод 2: Standalone HTTP

Требует открытый порт 80 на момент получения. Не работает за CDN.

### Проверка idempotency для SSL

Установщик проверяет 4 условия перед получением сертификата:
1. Файл `cert.pem` существует и содержит подпись Let's Encrypt (не self-signed)
2. CN или SAN сертификата содержит запрошенный домен
3. Срок действия > 14 дней
4. `acme.sh --list` управляет этим доменом (гарантия автопродления)

Если хоть одно условие не выполнено — SSL настраивается заново.

### Автообновление

`acme.sh` настраивает автообновление через `--reloadcmd "systemctl reload nginx"`. Сертификат хранится в `/etc/nginx/cert/cert.pem` и `cert.key`.

---

## Outbound в 3x-ui

После установки WARP/Tor/Psiphon outbound'ы добавляются в Xray конфигурацию 3x-ui автоматически. Затем в панели 3x-ui:

1. Создай inbound (VLESS/VMess/Trojan — любой)
2. В настройках inbound → Routing → выбери outbound тег: `warp`, `tor` или `psiphon`
3. Весь трафик этого inbound пойдёт через выбранный прокси

**Теги outbound'ов:**

| Тег | Прокси | Порт |
|---|---|---|
| `warp` | Cloudflare WARP | 40000 |
| `tor` | Tor | 40003 |
| `psiphon` | Psiphon | 40002 |

Управление outbound'ами из меню: `xpro` → `WARP/Tor/Psiphon` → `Добавить/Удалить outbound`.

---

## Удаление

```bash
xpro uninstall
```

**Удаляет:**
- 3x-ui (все inbound'ы и пользователи будут потеряны)
- Cloudflare WARP
- Tor
- Psiphon
- Nginx конфиги xpro (сам nginx-пакет остаётся)
- Команду `xpro` (`/usr/local/bin/xpro`)
- Модули в `/usr/local/lib/xpro/`
- Cron задание CF IP обновления (`/etc/cron.d/xpro-cf-ips`)

**НЕ удаляет:**
- SSL сертификат (`/etc/nginx/cert/`)
- acme.sh и автопродление
- Конфиг `/usr/local/etc/xpro/xpro.conf`
- Cloudflare API ключи (`/root/.cloudflare_api`)
- Сам nginx пакет

---

## Известные ограничения

**WARP на некоторых VPS**

Cloudflare WARP использует UDP на порту 2408. Ряд провайдеров блокирует или ограничивает UDP — WARP может не подключаться. Симптом: статус `DISCONNECTED` сразу после установки. Обходного пути нет — зависит от провайдера.

**Psiphon и публичные ключи**

Psiphon использует публичные ключи из открытых клиентов. Это стандартная практика для self-hosted использования, но Psiphon Labs может ограничить использование в будущем.

**Tor + ExitNodes с StrictNodes**

Принудительный выбор страны выхода (`ExitNodes {DE} StrictNodes 1`) замедляет установку цепочки и уменьшает количество доступных нод. При недоступности нод Tor не подключится. Для надёжности используй без `StrictNodes` или выбирай популярные страны: DE, NL, SE, FR, US.

**WebSocket inbound'ы через Cloudflare**

Xray inbound'ы с WebSocket транспортом работают через Nginx/CF только если nginx настроен как proxy для конкретного пути этого inbound. Шаблон есть в закомментированном виде в nginx конфиге xpro. Настраивай отдельно для каждого WS inbound.

**3x-ui порт через CDN**

При `-cdn on` Cloudflare проксирует только порт 443. Прямое подключение к порту панели (например `:54321`) не работает через CF. Всегда используй `https://domain/{webBasePath}/`.

**BBR и 3x-ui**

3x-ui имеет собственную настройку BBR в панели (Xray Configs → System). Если BBR уже включён через панель, `enableBBR` в xpro просто сообщит об этом — повторного применения не будет.

---

## FAQ

**Q: Можно ли установить без домена?**  
A: Нет. SSL сертификат и Nginx конфиг требуют домен. Без домена используй 3x-ui напрямую без xpro.

**Q: Можно ли поменять домен после установки?**  
A: Да. `xpro` → `Nginx / SSL` → `Переполучить SSL (новый домен)`. Затем вручную обнови `DOMAIN` в `/usr/local/etc/xpro/xpro.conf` и выполни `systemctl reload nginx`.

**Q: WARP не подключается, статус DISCONNECTED**  
A: Попробуй: `xpro` → `WARP` → `Остановить` → `Запустить`. Если не помогает — переустанови через меню. WARP может не работать на VPS провайдерах с блокировкой UDP 2408 (OVH, некоторые Hetzner конфигурации).

**Q: Tor очень медленный**  
A: Это нормально — Tor маршрутизирует трафик через 3 ретранслятора. Для ускорения: выбери популярную страну выхода (DE, NL, US), не используй `StrictNodes`.

**Q: Psiphon не подключается**  
A: Проверь логи: `journalctl -u psiphon -n 50`. Psiphon может занимать несколько минут на первоначальное подключение к инфраструктуре. В режиме WARP+Psiphon убедись что WARP активен: `xpro check-warp`.

**Q: После обновления 3x-ui outbound'ы исчезли**  
A: Обновление пересоздаёт конфигурацию Xray. Добавь outbound'ы заново: `xpro` → выбери сервис → `Добавить outbound в 3x-ui`.

**Q: CF Guard заблокировал мой доступ к панели**  
A: Если подключаешься к серверу напрямую (не через CF CDN), CF Guard заблокирует соединение. Отключи: `xpro` → `Nginx / SSL` → `CF Guard` → выбери отключение.

**Q: Можно ли запустить установку повторно без потери данных?**  
A: Да. Установщик полностью idempotent — все уже выполненные шаги пропускаются. 3x-ui, SSL, outbound'ы и конфигурации не пересоздаются если уже готовы.

**Q: Как проверить что все сервисы работают?**

```bash
xpro status          # Общий статус в меню
xpro check-warp      # IP через WARP
xpro check-tor       # IP через Tor
xpro check-psiphon   # IP через Psiphon
```

**Q: Как обновить CF IP диапазоны вручную?**

```bash
xpro update-cf-ips
```

Автоматически выполняется каждый понедельник в 3:00 через cron.

**Q: Где логи?**

| Сервис | Лог |
|---|---|
| Nginx | `/var/log/nginx/access.log`, `error.log` |
| 3x-ui / Xray | `journalctl -u x-ui` |
| Tor | `/var/log/tor/notices.log` |
| Psiphon | `/var/log/psiphon/psiphon.log` |
| WARP | `journalctl -u warp-svc` |
| Fail2Ban | `fail2ban-client status sshd` |

---

## Лицензия

MIT