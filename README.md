# X-PRO

Автоматизированный установщик и менеджер для [3x-ui (MHSanaei)](https://github.com/MHSanaei/3x-ui) с поддержкой Cloudflare WARP, Tor, Psiphon, Nginx reverse proxy, SSL и набором инструментов безопасности.

```
╔══════════════════════════════════════════╗
║  X-PRO v1.0  |  🇩🇪  1.2.3.4         ║
╠══════════════════════════════════════════╣
║                                          ║
║  3x-ui     RUNNING   (example.com)       ║
║  Nginx     RUNNING   SSL: OK (45d)       ║
║                                          ║
╠══════════════════════════════════════════╣
║  WARP      ACTIVE                        ║
║  Tor       —                             ║
║  Psiphon   —                             ║
║                                          ║
╚══════════════════════════════════════════╝

  1. Управление WARP
  2. Управление Tor
  3. Управление Psiphon
  4. Nginx / SSL
  5. Безопасность
  6. 3x-ui
  0. Выход
```

---

## Содержание

- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Аргументы установки](#аргументы-установки)
- [Структура проекта](#структура-проекта)
- [Модули](#модули)
  - [core.sh](#coresh)
  - [xui.sh](#xuish)
  - [nginx.sh](#nginxsh)
  - [warp.sh](#warpsh)
  - [tor.sh](#torsh)
  - [psiphon.sh](#psiphonsh)
  - [security.sh](#securitysh)
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
| Python | Python 3.x (для конфига Psiphon и вывода флагов) |

**Зависимости** устанавливаются автоматически: `nginx`, `curl`, `socat`, `fail2ban`, `ufw`, `sqlite3`, `openssl`.

---

## Быстрый старт

### Минимальная установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) -domain example.com
```

Установит: 3x-ui (MHSanaei), Nginx, SSL, фейковый сайт, BBR, Fail2Ban, sysctl оптимизации.

### Полная установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/HnDK0/xpro/main/install.sh) -domain example.com -cdn on -warp yes -tor off -ufw on -psiphon off -bbr yes -fake yes
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
| `-port` | `1024–65535` | случайный | Порт панели 3x-ui |
| `-cdn` | `on` \| `off` | `off` | Cloudflare CDN режим |
| `-warp` | `yes` \| `no` | `no` | Установить Cloudflare WARP |
| `-tor` | `yes` \| `no` | `no` | Установить Tor |
| `-psiphon` | `yes` \| `no` | `no` | Установить Psiphon |
| `-ufw` | `on` \| `off` | `off` | Настроить и включить UFW |
| `-bbr` | `yes` \| `no` | `yes` | Включить TCP BBR |
| `-fake` | `yes` \| `no` | `yes` | Установить фейковый сайт |

> **Примечание:** `-port` сохраняется в `xpro.conf` после подтверждения реального порта из БД 3x-ui. Если порт занят — установщик автоматически выбирает свободный.

---

## Структура проекта

```
x-ui-pro/
├── install.sh          # Установщик
├── menu.sh             # Главное меню (команда xpro)
└── modules/
    ├── core.sh         # Утилиты, переменные, OS detection
    ├── xui.sh          # Управление 3x-ui и его API
    ├── nginx.sh        # Nginx, SSL, фейковый сайт, CF Guard
    ├── warp.sh         # Cloudflare WARP
    ├── tor.sh          # Tor с мостами и выбором страны
    ├── psiphon.sh      # Psiphon (plain и WARP+Psiphon режимы)
    └── security.sh     # UFW, BBR, Fail2Ban, SSH, IPv6, CPU Guard
```

После установки модули копируются в `/usr/local/lib/xpro/`, конфиг — в `/usr/local/etc/xpro/xpro.conf`.

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
| `installPackage pkg` | Устанавливает пакет с автоматическим починкой зависимостей |
| `isRoot` | Проверяет root права, завершает с сообщением если нет |
| `setupSwap` | Создаёт swap если < 256MB: 1GB для RAM ≤ 1GB, 2GB для ≤ 2GB |
| `getServerIP` | Публичный IPv4 с 5 fallback-сервисами |
| `getCountryCode ip` | Код страны по IP через ip-api.com |
| `getCountryFlag code` | Emoji флаг (`🇩🇪`, `🇺🇸`) через Python unicode |
| `checkServiceIP proxy name` | Проверяет IP через SOCKS5 прокси с fallback'ами |
| `getServiceStatus svc` | `RUNNING`/`STOPPED` с цветом для systemd сервиса |
| `xpro_conf_get key` | Читает значение из xpro.conf |
| `xpro_conf_set key val` | Записывает/обновляет значение в xpro.conf |
| `xpro_conf_del key` | Удаляет ключ из xpro.conf |
| `run_task "описание" команда` | Выполняет команду с выводом `[DONE]`/`[FAIL]` |
| `generateRandomPath` | Случайный URL-путь из 12 символов |
| `generateFreePort` | Свободный случайный порт 10000–65000 |
| `setupAlias` | Копирует menu.sh в `/usr/local/bin/xpro` |

---

### xui.sh

Управление 3x-ui панелью и её REST API.

**Установка и обновление:**

| Функция | Описание |
|---|---|
| `install3xui [panel] [port]` | Устанавливает 3x-ui через официальный скрипт MHSanaei или Alireza |
| `update3xui` | Обновляет до последней версии |
| `remove3xui` | Полное удаление с подтверждением |

**Порт и credentials:**

| Функция | Описание |
|---|---|
| `xuiGetPort` | Читает порт: xpro.conf → sqlite3 БД → config.json → fallback 2053 |
| `xuiGetUser` | Логин панели (xpro.conf → sqlite3 → fallback `admin`) |
| `xuiGetPass` | Пароль панели (xpro.conf → sqlite3 → fallback `admin`) |
| `xuiSetPort port` | Меняет порт в БД и xpro.conf, перезапускает x-ui |

**API функции:**

Все API запросы работают через сессионный cookie (`/tmp/xpro_xui_session`). При истечении сессии логин происходит автоматически.

| Функция | Endpoint | Описание |
|---|---|---|
| `xuiApiLogin` | `POST /login` | Авторизация, сохранение cookie |
| `xuiApiAddOutbound tag addr port` | `POST /xui/xray/outbounds/add` | Добавляет SOCKS5 outbound |
| `xuiApiDelOutbound tag` | `POST /xui/xray/outbounds/del/{tag}` | Удаляет outbound по тегу |
| `xuiApiListOutbounds` | `GET /xui/xray/outbounds/list` | Список всех outbound'ов |
| `xuiApiRestart` | `POST /xui/xray/restart` | Перезапуск Xray |

**Меню 3x-ui** (`xpro` → пункт 6):
- Перезапустить 3x-ui / Xray
- Обновить 3x-ui
- Показать credentials и URL панели
- Сменить порт панели
- Список outbound'ов

---

### nginx.sh

Nginx как reverse proxy перед 3x-ui с SSL, фейковым сайтом и защитой Cloudflare.

**Конфигурация:**

| Функция | Описание |
|---|---|
| `installNginx` | Установка nginx через пакетный менеджер, enable в systemd |
| `writeNginxConfig domain port cdn` | Записывает основной конфиг с proxy на 3x-ui |
| `setFakeSite [random\|url\|menu]` | Меняет фейковый сайт для маскировки |

**Схема проксирования:**

```
Клиент → :443 (Nginx)
    ├── /xui/  → 127.0.0.1:{xui_port}   # панель 3x-ui
    └── /      → https://fake-site.com    # маскировка
```

WebSocket для Xray inbound'ов настраивается вручную в `xpro.conf` через закомментированный шаблон в конфиге.

**Фейковые сайты** (15 встроенных):
wikipedia.org, debian.org, ubuntu.com, kernel.org, gnu.org, python.org, nginx.org, openssl.org, archlinux.org, freebsd.org, openbsd.org, netbsd.org, mozilla.org, apache.org, postgresql.org

Можно выбрать случайный, из списка или ввести собственный URL.

**SSL:**

| Функция | Описание |
|---|---|
| `configSSL domain cdn` | Интерактивная настройка: CF DNS API или standalone |
| `renewCert` | Принудительное обновление через acme.sh |
| `checkCertExpiry` | Дней до истечения с цветовой индикацией |
| `openPort80` / `closePort80` | Временное открытие :80 для ACME challenge |

**Cloudflare Real IP:**

| Функция | Описание |
|---|---|
| `setupRealIpRestore` | Скачивает актуальные CF IP диапазоны, пишет `real_ip_restore.conf` |
| `setupCfIpCron` | Cron задание: обновление CF IP каждый понедельник в 3:00 |
| `toggleCfGuard` | Включает/выключает блокировку не-CF IP на `/xui/` |
| `getCfGuardStatus` | Статус CF Guard (`ON`/`OFF`) |

> **CF Guard:** При включении блокирует прямые подключения к серверу, пропуская только трафик через Cloudflare. Требует `-cdn on`.

---

### warp.sh

Cloudflare WARP в режиме SOCKS5 прокси.

**Как работает:** WARP запускается как системный сервис (`warp-svc`), `warp-cli` переключает в режим `proxy` и слушает на `127.0.0.1:40000`. Xray использует этот SOCKS5 как outbound.

**Функции:**

| Функция | Описание |
|---|---|
| `installWarp` | Добавляет репозиторий Cloudflare, устанавливает `cloudflare-warp` |
| `configWarp` | Регистрация, режим proxy, порт 40000, автозапуск |
| `startWarp` / `stopWarp` | Запуск/остановка сервиса + CLI |
| `enableWarp` / `disableWarp` | Автозагрузка вкл/выкл |
| `removeWarp` | Полное удаление с подтверждением |
| `addWarpOutbound` | Добавляет SOCKS5 outbound в 3x-ui через API |
| `removeWarpOutbound` | Удаляет outbound из 3x-ui |
| `checkWarpIP` | Проверяет IP через WARP с fallback'ами |
| `getWarpStatus` | `ACTIVE`/`DISCONNECTED`/`STOPPED`/`НЕ УСТАНОВЛЕН` |

**Совместимость:** `_warp_cmd()` автоматически определяет нужен ли флаг `--accept-tos` для текущей версии `warp-cli`.

**Systemd override:** Устанавливается drop-in конфиг `Restart=on-failure` вместо встроенного watchdog, что устраняет проблему с зависанием при рестарте.

---

### tor.sh

Tor с поддержкой мостов (obfs4, snowflake, meek-azure) и выбором страны выхода.

**Установка:** Автоматически ищет доступное зеркало репозитория Tor (5 сек на каждое), затем устанавливает из первого доступного. Это важно для серверов в РФ и других странах где `deb.torproject.org` заблокирован.

**Порядок зеркал:**

| Зеркало | URL | Примечание |
|---|---|---|
| Официальный | `deb.torproject.org/torproject.org` | Заблокирован в РФ |
| EFF | `tor.eff.org/torproject.org` | Зеркало EFF, обычно доступен в РФ |
| Official mirror | `mirror.torproject.org/debian` | Официальное зеркало Tor Project |
| Системный репо | — | Финальный fallback, версия может быть старее |

Все зеркала используют одинаковый GPG ключ Tor Project — пакеты идентичны. Использованное зеркало сохраняется в `xpro.conf` (`TOR_MIRROR`) и применяется при последующих обновлениях (`upgradeTor`). GPG ключ скачивается последовательно с каждого зеркала; если ни одно не ответило — резерв через `keyserver.ubuntu.com`.

**Дополнительные пакеты:**
- `tor-geoipdb` — для `ExitNodes {XX}` по коду страны
- `obfs4proxy` — для obfs4 и meek мостов
- `snowflake-client` — для snowflake (если доступен в репо)

**Функции:**

| Функция | Описание |
|---|---|
| `installTor` | Установка через torproject.org репо + fallback |
| `upgradeTor` | Обновление до последней версии |
| `configTor [country] [bridge_type]` | Записывает torrc: SocksPort, ControlPort, мосты, страна |
| `startTor` / `stopTor` / `restartTor` | Управление сервисом |
| `enableTor` / `disableTor` | Автозагрузка |
| `removeTor` | Удаление + очистка outbound из 3x-ui |
| `setTorCountry` | Интерактивная смена ExitNodes |
| `configureTorBridges` | Выбор и настройка типа моста |
| `addTorOutbound` / `removeTorOutbound` | Управление outbound в 3x-ui |
| `checkTorIP` | Проверка IP через Tor (до 30 сек) |
| `getTorStatus` | Статус + страна + тип моста |

**Страны выхода:**
`AT BE BG BR CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK UA US`

**Типы мостов:**

| Тип | Описание | Требует |
|---|---|---|
| `obfs4` | Обфускация трафика | obfs4proxy, свои мосты с bridges.torproject.org |
| `snowflake` | Через WebRTC | snowflake-client |
| `meek-azure` | Маскировка под Azure CDN | obfs4proxy |
| `custom` | Собственные мосты любого типа | obfs4proxy или snowflake |

Свои obfs4/custom мосты сохраняются в `/usr/local/etc/xpro/tor_bridges.txt`.

---

### psiphon.sh

Psiphon в двух режимах: обычный и `WARP+Psiphon` (трафик через WARP → Psiphon).

**Бинарь:** Загружается напрямую с [GitHub Psiphon-Labs](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries). Поддерживаемые архитектуры: `x86_64`, `arm64`, `arm`.

**Функции:**

| Функция | Описание |
|---|---|
| `installPsiphon` | Загрузка бинаря под текущую архитектуру |
| `writePsiphonConfig [country] [mode]` | JSON конфиг: порт, страна, upstream прокси |
| `writePsiphonService` | Создаёт systemd unit |
| `startPsiphon` / `stopPsiphon` / `restartPsiphon` | Управление сервисом |
| `enablePsiphon` / `disablePsiphon` | Автозагрузка |
| `removePsiphon` | Полное удаление |
| `setPsiphonCountry` | Смена `EgressRegion` в JSON конфиге |
| `setPsiphonMode` | Переключение plain ↔ WARP+Psiphon |
| `addPsiphonOutbound` / `removePsiphonOutbound` | Управление outbound в 3x-ui |
| `checkPsiphonIP` | Проверка IP через Psiphon (до 30 сек) |
| `getPsiphonStatus` | Статус + страна + режим |

**Режим WARP+Psiphon:**

```
Xray → Psiphon (SOCKS5 :40002)
           ↓ UpstreamProxyUrl
       WARP (SOCKS5 :40000)
           ↓
       Cloudflare WARP
```

Psiphon туннелирует свой трафик через WARP. Полезно для регионов где Psiphon блокируется напрямую. При переключении в этот режим автоматически проверяется запущен ли `warp-svc`.

**Конфиг:** `/usr/local/etc/xpro/psiphon.json`  
**Логи:** `/var/log/psiphon/psiphon.log`

---

### security.sh

Комплексные инструменты защиты сервера.

#### BBR

```bash
enableBBR    # Проверяет не включён ли уже (в т.ч. через 3x-ui), применяет через sysctl
getBbrStatus # ON / OFF
```

> **Совместимость с 3x-ui:** 3x-ui умеет включать BBR сам. Перед включением через xpro проверяется текущее состояние. Двойное включение безопасно — `sysctl` просто обновит параметр.

#### Fail2Ban

```bash
setupFail2Ban    # SSH защита: 3 попытки → бан на 24ч
setupWebJail     # nginx-probe jail: блокировка сканеров .php/wp-login/.env/.git
getF2BStatus     # ON / OFF
getWebJailStatus # ON / inactive / OFF
```

`setupFail2Ban` автоматически определяет backend:
- Ubuntu ≤ 20.04 / файл `/var/log/auth.log` → backend `auto`
- Ubuntu 22.04+ (journald) → backend `systemd`

> **Совместимость:** 3x-ui имеет встроенную защиту панели. Системный Fail2Ban защищает SSH и Nginx — конфликта нет, разные задачи.

#### UFW

```bash
setupUFW port cdn    # Начальная настройка при установке
manageUFW            # Интерактивное управление (открыть/закрыть порт, вкл/выкл)
getUfwStatus         # ACTIVE / INACTIVE
```

При `-cdn on` порт панели 3x-ui **не открывается** снаружи. Панель доступна только через `https://domain/xui/`.

> **Совместимость:** 3x-ui только отображает статус UFW. Управление — только через xpro или `ufw` напрямую.

#### SSH порт

```bash
changeSshPort    # Меняет порт в sshd_config, открывает новый в UFW
```

**Внимание:** Перед закрытием текущей SSH сессии проверь что новый порт доступен.

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

Создаёт persistent drop-in конфиги в `/etc/systemd/system/{svc}.service.d/cpuguard.conf`.

#### Sysctl оптимизации

`applySysctl` записывает в `/etc/sysctl.d/99-xpro.conf`:

```
net.ipv4.icmp_echo_ignore_all = 1     # скрываем от ping
net.core.somaxconn = 65535            # очередь соединений
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_keepalive_time = 120     # поддержка WS через мобильный NAT
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
```

IPv6 в этот файл **не пишется** — управляется через `toggleIPv6` отдельно.

---

## Команда xpro

После установки доступна глобальная команда `xpro`:

```bash
xpro                  # Интерактивное меню
xpro status           # Статус всех сервисов без входа в меню
xpro update-cf-ips    # Обновить CF IP диапазоны (вызывается cron'ом)
xpro check-warp       # Быстрая проверка IP через WARP
xpro check-tor        # Быстрая проверка IP через Tor
xpro check-psiphon    # Быстрая проверка IP через Psiphon
xpro uninstall        # Полное удаление X-UI PRO
```

---

## Порты сервисов

| Сервис | Адрес | Протокол |
|---|---|---|
| 3x-ui панель | `127.0.0.1:{random}` | HTTP (через Nginx) |
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
XUI_PORT=54321
XUI_PANEL=mhsanaei
XUI_USER=admin
XUI_PASS=xxxxxxxxx
WARP_INSTALLED=yes
TOR_INSTALLED=yes
PSIPHON_INSTALLED=no
SSL_METHOD=dns_cf
FAKE_SITE_URL=https://www.debian.org
OUTBOUND_WARP_ADDED=yes
OUTBOUND_TOR_ADDED=yes
TOR_COUNTRY=DE
TOR_BRIDGE_TYPE=obfs4
PSIPHON_MODE=plain
```

Файл **не удаляется** при `xpro uninstall` — там хранятся Cloudflare API ключи.

Cloudflare API ключи: `/root/.cloudflare_api` (права 600)

---

## Работа с Cloudflare CDN

### Требования для `-cdn on`

1. DNS запись для домена проксируется через CF (оранжевое облако ☁)
2. SSL/TLS режим в CF: **Full (strict)**
3. WebSockets: включены (Settings → Network → WebSockets)

### Что меняется при `-cdn on`

- Порт панели 3x-ui **не открывается** в UFW (только `443` и SSH)
- Панель доступна только через `https://domain/xui/`
- CF Guard (`toggleCfGuard`) блокирует прямые подключения к серверу
- CF IP диапазоны обновляются автоматически раз в неделю через cron

### Ограничения CF Free плана

- WebSocket соединения работают, но могут рваться при длинных idle периодах
- Timeout CF: 70 секунд. Nginx настроен на `keepalive_timeout 75s` (с запасом)
- Для долгих WS соединений рекомендуется настроить `keepalive` на стороне клиента

---

## SSL сертификаты

Используется [acme.sh](https://github.com/acmesh-official/acme.sh) с Let's Encrypt.

### Метод 1: Cloudflare DNS API (рекомендуется)

Не требует открытого порта 80. Работает с CDN. Получает wildcard сертификат (`*.domain.com`).

Требует: Cloudflare Email и Global API Key (не Token — нужен именно Key).

```
Cloudflare Dashboard → My Profile → API Tokens → Global API Key
```

### Метод 2: Standalone HTTP

Требует открытый порт 80 на момент получения. Не работает за CDN.

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
- 3x-ui (все inbound'ы и пользователи)
- Cloudflare WARP
- Tor
- Psiphon
- Nginx конфиг xpro (сам nginx остаётся)
- Команду `xpro`
- Модули в `/usr/local/lib/xpro/`
- Cron задание CF IP обновления

**НЕ удаляет:**
- SSL сертификат (`/etc/nginx/cert/`)
- acme.sh
- Конфиг `/usr/local/etc/xpro/xpro.conf`
- Cloudflare API ключи (`/root/.cloudflare_api`)
- Сам nginx пакет

---

## Известные ограничения

**Psiphon и публичные ключи**

Psiphon использует публичные ключи из открытых клиентов (`FFFFFFFFFFFFFFFF`). Это стандартная практика для self-hosted использования, но Psiphon Labs может ограничить использование в будущем.

**Tor + ExitNodes**

Принудительный выбор страны выхода (`ExitNodes {DE} StrictNodes 1`) замедляет установку цепочки и уменьшает количество доступных нод. При недоступности нод Tor не подключится. Для надёжности используй без `StrictNodes` или выбирай популярные страны (DE, NL, SE, FR).

**WebSocket через Cloudflare**

Xray inbound'ы использующие WebSocket транспорт работают через Nginx/CF только если nginx настроен как proxy для конкретного пути. Шаблон есть в закомментированном виде в `xpro.conf`. Настрой отдельно для каждого inbound.

**3x-ui порт через CDN**

При `-cdn on` Cloudflare проксирует только порт 443. Прямое подключение к порту панели (например `:54321`) не работает через CF. Всегда используй `https://domain/xui/`.

**BBR и 3x-ui**

3x-ui имеет собственную настройку BBR в панели (Xray Configs → System). Если BBR уже включён через панель, `enableBBR` в xpro просто сообщит об этом и не будет применять изменения повторно.

---

## FAQ

**Q: Можно ли установить без домена?**  
A: Нет. SSL сертификат и Nginx конфиг требуют домен. Без домена используй 3x-ui напрямую без xpro.

**Q: Можно ли поменять домен после установки?**  
A: Да. `xpro` → `Nginx / SSL` → `Переполучить SSL (новый домен)`. Затем вручную обнови `DOMAIN` в `xpro.conf` и перезапусти nginx.

**Q: WARP не подключается, статус DISCONNECTED**  
A: Попробуй: `xpro` → `WARP` → `Остановить` → `Запустить`. Если не помогает — переустанови через меню. WARP может не работать на некоторых VPS провайдерах (блокировка UDP 2408).

**Q: Tor очень медленный**  
A: Это нормально. Tor маршрутизирует трафик через 3 узла. Для ускорения: выбери популярную страну выхода (DE, NL, US) и не используй `StrictNodes`.

**Q: Psiphon не подключается**  
A: Проверь логи: `journalctl -u psiphon -n 50`. Psiphon может занимать несколько минут на первоначальное подключение. В режиме WARP+Psiphon убедись что WARP активен.

**Q: После обновления 3x-ui outbound'ы исчезли**  
A: Обновление пересоздаёт БД Xray. Добавь outbound'ы заново: `xpro` → выбери сервис → `Добавить outbound в 3x-ui`.

**Q: CF Guard заблокировал мой доступ**  
A: Если подключаешься напрямую (не через CF CDN), CF Guard заблокирует соединение. Отключи: `xpro` → `Nginx / SSL` → `CF Guard` → подтверди отключение.

**Q: Как проверить что сервисы работают?**  
```bash
xpro status          # Общий статус
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

