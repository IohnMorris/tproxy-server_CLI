# 🚀 Telegram WEB Proxy Auto-Installer & CLI Panel

[Русский](#русский) | [English](#english)

## Русский

Автоматический скрипт для быстрого развертывания и удобного управления официальным [Telegram WEB Proxy (tproxy-server)](https://github.com/telegramdesktop/tproxy-server).

Скрипт превращает сложную настройку релея, MTProxy, nftables и веб-сервера Caddy в **интерактивную панель управления** в терминале. Он сам генерирует криптостойкие ключи, получает SSL-сертификаты, считает трафик и онлайн по каждому пользователю, позволяет на лету менять транспорт (включая **WebSocket**) и выдаёт готовые ссылки для подключения в Telegram.

---

## ✨ Особенности

- **🖥 Удобная CLI-панель (`sudo proxy`)**: управление ключами, доменом, сайтом-заглушкой и сервером через наглядное меню без ручного редактирования JSON-конфигов.
- **⚡ Все режимы транспорта (`carrier_mode`)**: полная поддержка `https`, `https-lanes`, `websocket` и `websocket-lanes` с возможностью переключения на лету (даже на уже созданных ключах без смены ссылки).
- **👥 Мульти-пользовательский режим**: создавайте отдельные ключи для разных устройств, друзей или клиентов.
- **📊 Учет трафика и онлайна в реальном времени**: подсчет скачанных/отданных гигабайт (`RX`/`TX`) через `nftables` (сохраняется при перезагрузках) и отображение активных подключений по каждому ключу.
- **🌐 Смена домена в 1 клик**: встроенный мастер проверяет DNS A-запись, перенастраивает Caddy и автоматически выпускает новый сертификат Let's Encrypt.
- **🛡 Маскировка под обычный сайт (обход DPI)**: автоматическая генерация секретного пути (`base_path` slug) и встроенный редактор сайта-заглушки прямо из панели.
- **🔄 Безопасная ротация**: смена секретов или `base_path` для одного или сразу всех ключей с защитой от случайного нажатия.

---

## 📋 Требования

- **ОС:** Ubuntu 22.04+ или Debian 12+ (архитектура `x86_64`).
- **Права:** `root` (или пользователь с `sudo`).
- **Домен:** Привязанный к IP-адресу вашего сервера (A-запись).
- **Чистый сервер:** порты `80` и `443` не должны быть заняты другими веб-серверами (Nginx, Apache и т.д.).

---

## 🛠 Установка (Одной командой)

Подключитесь к вашему серверу по SSH и выполните:

```bash
sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/IohnMorris/tproxy-server_CLI/main/install.sh)"
```

Во время установки скрипт спросит язык, домен, email для сертификата и желаемый режим транспорта. Если пропустить выбор транспорта, будет использован `https` для максимальной совместимости. После этого скрипт настроит сервисы и выведет готовую ссылку вида `https://t.me/webproxy?...`.

---

## 🎛 Управление через интерактивную панель

После установки управление прокси доступно из любой точки системы по короткой команде:

```bash
sudo proxy
```

(или `sudo tg-proxy`)

**Что умеет панель управления:**

В верхней части панели всегда отображается живая сводка сервера: нагрузка на CPU, потребление RAM, место на диске, статус служб (tproxy, mtproxy, caddy, readyz), общий трафик и текущий онлайн.

### 1. 🔑 Управление ключами и трафиком (пункты 1, 2, 3)

- **Таблица всех ключей:** показывает имя ключа, выбранный транспорт (MODE), сколько человек сейчас онлайн, а также статистику трафика (RX / TX / TOTAL) и готовые ссылки для Telegram.
- **Карточка отдельного ключа:** внутри таблицы введите номер ключа (1..N), чтобы открыть детальную информацию, обнулить счетчик трафика ([Z]), перевыпустить секрет ([R]) или сменить транспорт ([M]).
- **Создание и удаление:** добавляйте новые ключи в пару нажатий — скрипт сам выделит локальный порт и перезапустит сервисы без обрыва связи.

### 2. 🚀 Выбор и смена транспорта ([M] — Carrier Mode)

Вы можете выбрать режим работы как при создании ключа, так и изменить его для уже существующих ключей (при этом клиентская ссылка в Telegram остаётся прежней!).

| Режим | Описание | Когда выбирать |
| --- | --- | --- |
| `websocket-lanes` | Отдельный WebSocket на каждый логический поток | Максимальная скорость и отзывчивость. Скачивание тяжелых видео и файлов не блокирует текстовые сообщения. |
| `websocket` | Один общий упорядоченный WebSocket для всех потоков | Убирает задержки HTTP stop-and-wait, экономит количество соединений. |
| `https-lanes` | Независимые POST и long-poll запросы поверх HTTP/2 | Отличная альтернатива, если на сети клиента режутся WebSocket-соединения. |
| `https` (по умолчанию) | Классический 1 POST + 1 long-poll | Консервативный базовый режим для максимальной совместимости со старыми сетями. |

### 3. 🌐 Смена домена и перевыпуск SSL ([D])

Если ваш старый домен попал в блок или вы решили переехать на новый:

1. Нажмите D в главном меню и введите новый домен.
2. Панель сама проверит, указывает ли DNS A-запись на IP вашего сервера.
3. Обновит конфиги Caddy, дождётся получения нового сертификата Let's Encrypt и выдаст обновлённые ссылки (сохранив все ваши ключи и статистику трафика).

### 4. 🔐 Ротация секретов и секретного пути (4, 5)

Позволяет сменить секретный путь (`base_path`), по которому отвечает прокси (например, `https://domain.com/a7f3k9...`), либо задать свой собственный путь вручную.

Поддерживает как точечную смену секрета одному пользователю, так и полную экстренную ротацию всех ключей и путей одной кнопкой.

### 5. 🎨 Управление сайтом-заглушкой (8)

Нажмите 8, чтобы прямо из панели открыть HTML-код вашего прикрытия (`/srv/tproxy-site/index.html`) во встроенном редакторе nano или сбросить его на шаблон по умолчанию.

### 6. ⚙️ Обновление, Тюнинг и Мониторинг (6, 7, 9, H, L, R)

- **6 — Обновить ядро tproxy-server:** скачивает свежий коммит официального репозитория Telegram, пересобирает бинарник с сохранением всех ваших профилей и настроек.
- **7 — Обновить панель tg-proxy:** в 1 клик скачивает свежую версию самого скрипта управления с GitHub.
- **9 — Лимиты и воркеры:** настройка числа воркеров `MTPROXY_WORKERS`, лимита соединений `MTPROXY_MAX_CONNECTIONS` и режима маршрутизации статики (exact / legacy).
- **H — Монитор ресурсов (htop):** запуск интерактивного диспетчера задач.
- **L — Диагностика:** автоматическая валидация конфигов (`tproxy-server -check`), срез внутренней статистики MTProxy и вывод последних логов.

---

## ⚡ Быстрые CLI-команды (без входа в меню)

Управлять прокси можно напрямую одной строкой в терминале:

```bash
# Открыть интерактивную панель управления
sudo proxy

# Показать таблицу ключей, онлайн, трафик и ссылки подключения
sudo proxy users

# Создать новый ключ (с выбором режима или указанием сразу)
sudo proxy add ivan websocket-lanes
sudo proxy add iphone ws

# Сменить транспорт для одного ключа (по имени или номеру) без смены ссылки
sudo proxy mode ivan websocket-lanes
sudo proxy mode 1 https-lanes

# Переключить СРАЗУ ВСЕ ключи на WebSocket-Lanes одной командой
sudo proxy mode all websocket-lanes

# Удалить ключ
sudo proxy del ivan

# Сменить домен прокси и автоматически получить новый SSL-сертификат
sudo proxy domain new-proxy.example.com

# Открыть редактор сайта-заглушки в nano
sudo proxy site

# Полная ротация секретного пути и всех ключей
sudo proxy --rotate

# Обновить ядро tproxy-server до последней версии
sudo proxy --update

# Обновить сам скрипт панели управления с GitHub
sudo proxy --self-update

# Показать справку по всем командам
sudo proxy --help
```

---

## 🛡 Важно для обхода блокировок (DPI)

Для надежной маскировки трафика от систем анализа провайдеров (DPI) ваш сервер должен открываться в браузере как обычный живой сайт. Во время установки скрипт создает базовую страницу в папке `/srv/tproxy-site/index.html`.

Рекомендуется заменить заглушку на полноценную страницу:

Вызовите редактор прямо через панель:

```bash
sudo proxy site
```

и вставьте сгенерированный через ИИ одностраничный HTML-лендинг (с CSS-стилями внутри файла).

Либо загрузите многостраничный шаблон: скачайте любой бесплатный HTML-шаблон и загрузите файлы в директорию `/srv/tproxy-site/` на сервере (например, через SFTP), убедившись, что главный файл называется `index.html`.

---

## 🔧 Системные команды (Systemd)

При необходимости вы также можете управлять службами напрямую через systemctl (либо использовать пункт R и L внутри `sudo proxy`):

**Проверить статус всех служб:**

```bash
sudo systemctl status tproxy-server mtproxy caddy
```

**Перезапустить сервисы:**

```bash
sudo systemctl restart tproxy-server mtproxy caddy
```

**Посмотреть подробные логи:**

```bash
sudo journalctl -u tproxy-server -u mtproxy -n 50 --no-pager
sudo journalctl -u caddy -n 50 --no-pager
```

---

## English

# 🚀 Telegram WEB Proxy Auto-Installer & CLI Panel

Automatically deploy and manage the official [Telegram WEB Proxy (tproxy-server)](https://github.com/telegramdesktop/tproxy-server). The script turns relay, MTProxy, nftables and Caddy setup into an interactive terminal panel. It generates strong secrets, issues TLS certificates, tracks traffic and online connections, supports multiple users, and prints ready-to-use Telegram links.

---

## ✨ Features

- **🖥 Interactive CLI panel (`sudo proxy`)** for keys, domains, the placeholder website and services without editing JSON by hand.
- **⚡ Four transport modes (`carrier_mode`)**: `https`, `https-lanes`, `websocket` and `websocket-lanes`. You can switch a key's mode later without changing its Telegram link.
- **👥 Multiple users**: create separate keys for phones, computers, friends or customers.
- **📊 Traffic and online statistics**: RX/TX counters through `nftables`, persisted across restarts, plus estimated active users per key.
- **🌐 One-click domain changes**: DNS A-record validation, Caddy reconfiguration and automatic Let's Encrypt certificate issuance.
- **🛡 DPI camouflage**: a random secret `base_path` and an editable website served by Caddy.
- **🔄 Safe rotation**: rotate one key or all secrets and paths with an explicit confirmation.
- **🧰 Maintenance tools**: update tproxy-server, update the panel, tune workers and limits, inspect diagnostics and restart services.

---

## 📋 Requirements

- **OS:** Ubuntu 22.04+ or Debian 12+ on `x86_64`.
- **Privileges:** `root` or a user with `sudo`.
- **Domain:** an A record pointing to the server's public IP.
- **Clean ports:** ports `80` and `443` must be available; stop Nginx, Apache or another web server before installation.

---

## 🛠 Installation (one command)

Connect to the server over SSH and run:

```bash
sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/IohnMorris/tproxy-server_CLI/main/install.sh)"
```

The installer asks for a language, domain, certificate email and transport. If you skip the transport selection, it uses `https` for maximum compatibility. It then installs the required packages, deploys the official tproxy-server, configures MTProxy, nftables and Caddy, and prints a Telegram link such as `https://t.me/webproxy?...`.

Interactive sessions offer **Русский** and **English**. For scripts or automation, select a language explicitly:

```bash
sudo PROXY_LANG=en proxy --help
sudo PROXY_LANG=ru proxy --help
```

Non-interactive calls default to Russian when `PROXY_LANG` is not set.

---

## 🎛 Interactive control panel

After installation, open the panel with `sudo proxy` or `sudo tg-proxy`. The header shows CPU, RAM, disk usage, service status (`tproxy`, `mtproxy`, `caddy`, `readyz`), total traffic and estimated online users.

### 1. 🔑 Keys, links and traffic (1, 2, 3)

The key table shows each name, transport, estimated online users, RX/TX/TOTAL traffic and Telegram link. Select a key by number (`1..N`) to view details, reset traffic (`Z`), regenerate its secret (`R`) or change transport (`M`). Add or delete keys in a few prompts; the script allocates a local port and synchronizes services. The last remaining key cannot be deleted.

### 2. 🚀 Choosing and changing transport (`M` — Carrier Mode)

Select a mode when creating a key or change it later; the Telegram link remains the same.

| Mode | Description | When to choose it |
| --- | --- | --- |
| `websocket-lanes` | Separate WebSocket for each logical stream | Best responsiveness; downloads do not block messages. |
| `websocket` | One ordered WebSocket for all streams | Fewer connections and no HTTP stop-and-wait pauses. |
| `https-lanes` | Independent POST and long-poll over HTTP/2 | When the client's network blocks WebSockets. |
| `https` **(default)** | Classic one POST plus one long-poll | Conservative compatibility mode for older networks. |

Shortcuts include `ws`, `ws-lanes`, `lanes`, and numeric choices `1`–`4`.

### 3. 🌐 Changing the domain and TLS (`D`)

Press `D`, enter the new domain, and let the panel validate its DNS A record, update Caddy and request a new Let's Encrypt certificate. Existing keys and traffic statistics are preserved; links are rebuilt for the new domain.

### 4. 🔐 Secret and path rotation (4, 5)

`base_path` is the secret URL path where the proxy responds, for example `https://example.com/a7f3k9...`. Generate a random path, set a custom path, rotate one key, rotate all secrets, or perform a full rotation. Old links stop working after the affected value changes.

### 5. 🎨 Placeholder website (8)

Press `8` to edit `/srv/tproxy-site/index.html` in `nano` or restore the default page. Replace it with a normal landing page so the domain looks like an ordinary website in a browser.

### 6. ⚙️ Updates, tuning and monitoring (6, 7, 9, H, L, R)

- **6 — Update tproxy-server:** fetch and rebuild the latest official relay while preserving profiles and settings.
- **7 — Update the panel:** download the latest `tg-proxy` script from GitHub.
- **9 — Limits and workers:** configure `MTPROXY_WORKERS`, `MTPROXY_MAX_CONNECTIONS` and static routing (`exact` / `legacy`).
- **H — Resource monitor:** open `htop`.
- **L — Diagnostics:** validate configuration, query MTProxy statistics and show recent logs.
- **R — Restart services:** restart the proxy services and Caddy.

---

## ⚡ Direct CLI commands

```bash
sudo proxy                         # Open the panel
sudo proxy users                   # List keys, traffic and links
sudo proxy add ivan websocket-lanes # Create a key
sudo proxy add iphone ws
sudo proxy mode ivan websocket-lanes # Change one key's transport
sudo proxy mode all websocket-lanes  # Change all keys
sudo proxy del ivan                # Delete a key
sudo proxy domain new-proxy.example.com # Change domain and TLS
sudo proxy site                    # Edit the placeholder website
sudo proxy --rotate                # Rotate path and all secrets
sudo proxy --update                # Update tproxy-server
sudo proxy --self-update           # Update the panel
sudo proxy --help                  # Show help
```

---

## 🛡 DPI camouflage and placeholder website

The server should open in a browser as a normal live website. The installer creates `/srv/tproxy-site/index.html` and serves it through Caddy. Edit it with `sudo proxy site`, paste a single-page landing page, or upload a multi-page template over SFTP. Keep the main file named `index.html` and store assets under `/srv/tproxy-site/`.

---

## 🔧 Systemd commands

```bash
sudo systemctl status tproxy-server mtproxy caddy
sudo systemctl restart tproxy-server mtproxy caddy
sudo journalctl -u tproxy-server -u mtproxy -n 50 --no-pager
sudo journalctl -u caddy -n 50 --no-pager
```

You can also use the `R` and `L` actions in the panel.
