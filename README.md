# VK TURN VPS Setup

[![Smoke tests](https://github.com/XXcipherX/vkturn-vps-setup/actions/workflows/smoke.yml/badge.svg)](https://github.com/XXcipherX/vkturn-vps-setup/actions/workflows/smoke.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Набор установщиков для развёртывания VK TURN-прокси на Linux VPS. Репозиторий поддерживает два серверных протокола и три варианта установки:

- **WDTT + systemd** — сборка актуального server core из исходников;
- **WDTT + Docker Compose** — запуск готового контейнерного образа;
- **Free Turn Proxy + Docker Compose** — альтернативный режим SRTP-WRAP-S с локальным или внешним backend.

Установщики настраивают не только процесс сервера, но и необходимые сетевые параметры, firewall, автозапуск, резервное копирование состояния и проверку готовности. Документация ниже описывает устройство каждого варианта, установку, обновление, управление клиентами и диагностику.

> Проект не связан с VK и не является официальным продуктом VK. Работа соединения зависит от доступности VK Calls/TURN и совместимости клиентских приложений.

## Выбор варианта развёртывания

| Вариант | Скрипт | Протокол | Клиентские ссылки | Особенности |
| --- | --- | --- | --- | --- |
| WDTT, systemd | **install.sh** | SRTP-WRAP-A | **wdtt://** | Сборка server core из исходников, нативный systemd-сервис |
| WDTT, Docker | **vps-setup.sh** | SRTP-WRAP-A | **wdtt://** | Готовый image, интерактивная установка, Docker Compose |
| Free Turn Proxy | **free-turn-setup.sh** | SRTP-WRAP-S | **vkturnproxy://** и **freeturn://** | Отдельные клиенты, OBF rtpopus3, локальный или внешний backend |

WDTT и Free Turn используют разные протоколы и форматы конфигурации. Ссылка **wdtt://** не подходит для SRTP-WRAP-S, а ссылки Free Turn не подходят для WDTT.

Оба варианта по умолчанию используют публичный порт **56000/udp**. Для одновременного размещения WDTT и Free Turn на одном VPS необходимо назначить разные публичные порты и внимательно проверить firewall. Для обычной эксплуатации проще использовать отдельный VPS для каждого сервера.

## Архитектура

### WDTT / SRTP-WRAP-A

~~~text
Android или iOS
  -> VK TURN relay
  -> WRAP-A / DTLS
  -> wdtt-server на VPS
  -> встроенный WireGuard, интерфейс wdtt0
  -> NAT
  -> Internet
~~~

WDTT получает соединение через VK TURN, проверяет пароль, выдаёт клиенту WireGuard-конфигурацию через GETCONF и создаёт внутренний туннель. Отдельно устанавливать WireGuard-сервер для WDTT не требуется.

Используется серверная часть форка [XXcipherX/proxy-turn-vk-android](https://github.com/XXcipherX/proxy-turn-vk-android), ветка **main-new**. Она совместима с Android-клиентом из того же репозитория и iOS-клиентом [anton48/vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios).

### Free Turn Proxy / SRTP-WRAP-S

~~~text
Android или iOS
  -> VK TURN relay
  -> SRTP-WRAP-S / DTLS
  -> free-turn-proxy на VPS
  -> локальный WireGuard wgfreeturn или внешний backend
  -> NAT
  -> Internet
~~~

Free Turn не реализует WDTT GETCONF. При стандартной установке скрипт создаёт локальный WireGuard backend и отдельную WireGuard-конфигурацию для каждого клиента.

## Общие требования

- Linux VPS с публичным IPv4;
- root-доступ или пользователь с sudo;
- доступный VK group call вида **https://vk.ru/call/join/...**;
- открытый у VPS-провайдера публичный UDP-порт сервера;
- отсутствие конфликтов с уже существующими VPN, firewall и сетевыми интерфейсами.

Поддержка ОС различается:

- **install.sh:** Debian 11+, Ubuntu 20.04+, Fedora, RHEL/Rocky/Alma/CentOS/Oracle Linux и Arch-like Linux с systemd;
- **vps-setup.sh:** системы с apt, dnf, yum или pacman и доступным Docker;
- **free-turn-setup.sh:** Debian/Ubuntu и другие apt-based системы с systemd.

Архитектуры автоматической установки Go для нативного WDTT: **amd64** и **arm64**.

### Порты WDTT по умолчанию

| Назначение | Значение | Доступ извне |
| --- | --- | --- |
| DTLS / WRAP-A | 56000/udp | Открыть |
| Внутренний WireGuard | 56001/udp | Закрыть |
| Клиентская подсеть | 10.66.66.0/24 | Не маршрутизировать напрямую |
| Интерфейс | wdtt0 | Внутренний |

### Порты Free Turn по умолчанию

| Назначение | Значение | Доступ извне |
| --- | --- | --- |
| DTLS / SRTP-WRAP-S | 56000/udp | Открыть |
| Локальный WireGuard backend | 127.0.0.1:51820/udp | Закрыть |
| Клиентская подсеть | 10.13.13.0/24 | Не маршрутизировать напрямую |
| Интерфейс | wgfreeturn | Внутренний |

## WDTT с systemd

Этот вариант собирает сервер из исходников, устанавливает бинарник в **/usr/local/bin** и создаёт systemd-сервисы. Он подходит для VPS без Docker и позволяет закрепить конкретную ветку, tag или commit server core.

### Быстрая установка

На Debian/Ubuntu достаточно предварительно установить инструменты загрузки:

~~~bash
sudo -i
apt update
apt install -y curl ca-certificates openssl
~~~

Загрузите установщик:

~~~bash
curl -fsSL -o /tmp/vkturn-install.sh \
  https://raw.githubusercontent.com/XXcipherX/vkturn-vps-setup/main/install.sh
chmod +x /tmp/vkturn-install.sh
~~~

Создайте пароль длиной не менее восьми символов. Разрешены латинские буквы, цифры, точка, подчёркивание и дефис:

~~~bash
WDTT_PASS="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 28)"
printf '%s\n' "$WDTT_PASS"
~~~

Запустите установку:

~~~bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --vk-link "https://vk.ru/call/join/PASTE_YOUR_HASH_HERE"
~~~

После успешной проверки готовности будет напечатана ссылка:

~~~text
wdtt://VPS_IP:56000:56001:9000:PASSWORD:VK_HASH
~~~

Ссылка содержит пароль. Её следует передавать только доверенным пользователям и хранить как секрет.

Путь **/tmp/vkturn-install.sh** используется только для быстрого старта и может исчезнуть после перезагрузки. Для последующего администрирования скрипт можно загрузить повторно либо работать из локального clone этого репозитория:

~~~bash
git clone https://github.com/XXcipherX/vkturn-vps-setup.git
cd vkturn-vps-setup
sudo bash install.sh status
~~~

### Что устанавливается

Скрипт выполняет следующие операции:

1. Определяет семейство Linux и устанавливает системные зависимости.
2. Использует подходящую системную версию Go либо устанавливает Go в **/opt/wdtt/go**.
3. Клонирует исходники server core в **/opt/wdtt/source**.
4. Собирает модуль **app/src/main/assets/linux-server**.
5. Устанавливает бинарник **/usr/local/bin/wdtt-server**.
6. Сохраняет конфигурацию в **/etc/wdtt/wdtt.env** с правами 600.
7. Включает постоянный **net.ipv4.ip_forward=1**.
8. Создаёт firewall helper и сервис **wdtt-firewall.service**.
9. Создаёт и запускает **wdtt.service**.
10. Ожидает строку готовности сервера и проверяет стабильность процесса после старта.
11. Перед обновлением сохраняет резервную копию базы паролей.

Основные пути:

~~~text
/usr/local/bin/wdtt-server
/usr/local/lib/wdtt/apply-firewall.sh
/etc/wdtt/wdtt.env
/etc/wdtt/passwords.json
/etc/wdtt/backups/
/etc/systemd/system/wdtt.service
/etc/systemd/system/wdtt-firewall.service
/opt/wdtt/source/
~~~

### Команды управления

~~~bash
# Состояние сервиса и краткая диагностика
sudo /tmp/vkturn-install.sh status

# Логи в реальном времени
sudo /tmp/vkturn-install.sh logs

# Печать ссылки с новым VK hash
sudo /tmp/vkturn-install.sh link \
  --vk-link "https://vk.ru/call/join/NEW_HASH"

# Обновление или переустановка с сохранением базы
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --vk-link "https://vk.ru/call/join/PASTE_YOUR_HASH_HERE"

# Удаление сервиса с сохранением /etc/wdtt
sudo /tmp/vkturn-install.sh uninstall

# Полное удаление конфигурации и данных
sudo /tmp/vkturn-install.sh uninstall --purge
~~~

Если публичный адрес невозможно определить безопасно, сервер будет установлен, но скрипт не напечатает заведомо нерабочую ссылку с приватным IP. В таком случае передайте **--host** явно.

### Параметры install.sh

Параметры можно задавать флагами или соответствующими переменными окружения.

| Флаг | Переменная | Назначение |
| --- | --- | --- |
| --password | WDTT_PASSWORD | Главный пароль WDTT |
| --vk-link, --vk-hash | WDTT_VK_LINK | Полная VK Call URL или hash |
| --host | WDTT_PUBLIC_HOST | Публичный IPv4 или DNS без схемы, пути и порта |
| --dtls-port | WDTT_DTLS_PORT | Публичный UDP-порт, по умолчанию 56000 |
| --wg-port | WDTT_WG_PORT | Внутренний WG-порт, по умолчанию 56001 |
| --ssh-port | WDTT_SSH_PORT | SSH-порт для совместимости и очистки прежних правил |
| --dns | WDTT_DNS | IPv4 DNS через запятую, по умолчанию 1.1.1.1,1.0.0.1 |
| --admin-id | WDTT_ADMIN_ID | Telegram admin ID |
| --bot-token | WDTT_BOT_TOKEN | Telegram bot token |
| --source-repo | WDTT_SOURCE_REPO | Репозиторий server core |
| --source-ref | WDTT_SOURCE_REF | Ветка, tag или commit |
| --go-version | WDTT_GO_VERSION | Версия Go, по умолчанию 1.26.5 |

Пароль должен содержать от 8 до 128 символов из набора **A-Z**, **a-z**, **0-9**, **.**, **_**, **-**. Ограничение исключает неоднозначное разбиение ссылки **wdtt://**.

**WDTT_PUBLIC_HOST** принимает только публичный IPv4 или корректное DNS-имя. Значения со схемой, путём, портом, loopback, private IPv4 или link-local адресом отклоняются.

SSH-порт сохраняется для совместимости и удаления правил старых версий. Текущий установщик не открывает SSH в firewall — доступ к SSH должен быть настроен отдельно.

Пример с доменом:

~~~bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --host "vpn.example.com" \
  --vk-link "https://vk.ru/call/join/PASTE_YOUR_HASH_HERE"
~~~

Пример с Telegram-ботом для управления временными паролями:

~~~bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --admin-id "123456789" \
  --bot-token "123456789:AA..." \
  --vk-link "https://vk.ru/call/join/PASTE_YOUR_HASH_HERE"
~~~

### Обновление и закрепление server core

По умолчанию используется ветка **main-new** форка XXcipherX. Чтобы установить проверенный commit или tag:

~~~bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --source-ref "COMMIT_OR_TAG"
~~~

При повторной установке исходники обновляются, бинарник пересобирается, а база **/etc/wdtt/passwords.json** сохраняется. Перед заменой создаётся копия **/etc/wdtt/backups/passwords-*.json**.

Закреплённый ref должен поддерживать текущий firewall-контракт: server core владеет правилами **WDTT_MANAGED**, включая NAT, направленный FORWARD и изоляцию клиентов. Старые версии ядра, которые полагались на NAT/FORWARD установщика, не поддерживаются.

## WDTT с Docker Compose

Docker-вариант устанавливает готовый image **ghcr.io/xxcipherx/wdtt-server:latest** и хранит stack в **/opt/vkturn-vps-setup**.

### Установка

~~~bash
git clone https://github.com/XXcipherX/vkturn-vps-setup.git
cd vkturn-vps-setup
sudo bash vps-setup.sh
~~~

Скрипт интерактивно запрашивает пароль, VK Call link/hash, публичный host, порты, DNS и необязательные Telegram-параметры. При повторном запуске сохранённые значения используются как defaults. Пустой ввод не заменяет существующий пароль. Пароль должен содержать 16–128 разрешённых символов, не менее двух классов и не менее восьми различных символов; автоматически сгенерированный пароль уже соответствует этим требованиям.

Если Docker Engine или Compose plugin отсутствуют, скрипт устанавливает их с помощью официального bootstrap-скрипта **get.docker.com** и включает Docker через systemd.

Основные пути:

~~~text
/opt/vkturn-vps-setup/docker-compose.yml
/opt/vkturn-vps-setup/.env
/opt/vkturn-vps-setup/run-wdtt.sh
/opt/vkturn-vps-setup/data/passwords.json
/opt/vkturn-vps-setup/backups/
~~~

Файл **.env** содержит секреты и создаётся с правами 600. Каталог резервных копий имеет права 700, файлы внутри — 600.

Контейнер использует **network_mode: host**, **privileged: true** и **/dev/net/tun**, поскольку WDTT создаёт WireGuard-интерфейс и управляет сетевыми правилами хоста. Это доверенная привилегированная нагрузка; рекомендуется использовать image только из контролируемого registry и проверять изменения перед обновлением тега **latest**.

### Повторная установка и обновление

Для применения актуальной версии установщика и образа:

~~~bash
cd ~/vkturn-vps-setup
git pull
sudo bash vps-setup.sh
~~~

Перед остановкой текущего контейнера скрипт сначала загружает новый image. Ошибка registry или сети поэтому не останавливает уже работающий сервер. Перед обновлением **passwords.json** копируется в каталог backups.

Другой image можно задать переменной:

~~~bash
sudo WDTT_DOCKER_IMAGE=registry.example.com/wdtt-server:tag bash vps-setup.sh
~~~

Образ должен содержать актуальный server core с поддержкой правил **WDTT_MANAGED**.

Команды Docker Compose:

~~~bash
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml ps
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml logs -f
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml pull
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml up -d
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml down
~~~

После **pull** следует выполнять **up -d**. Команда **restart** перезапускает существующий контейнер и не переводит его на загруженный image.

Штатный **docker compose down** удаляет правила зон **WDTT_DOCKER** и **WDTT_MANAGED**. При запуске контейнера они создаются заново.

## Free Turn Proxy

**free-turn-setup.sh** разворачивает [samosvalishe/free-turn-proxy](https://github.com/samosvalishe/free-turn-proxy) в режиме SRTP-WRAP-S. По умолчанию используется профиль маскировки **rtpopus3**, allowlist клиентов и локальный WireGuard backend.

### Установка

~~~bash
git clone https://github.com/XXcipherX/vkturn-vps-setup.git
cd vkturn-vps-setup
sudo bash free-turn-setup.sh
~~~

Сценарий установки:

1. Устанавливает системные зависимости и, при необходимости, Docker через **get.docker.com**.
2. Устанавливает wireguard-tools для локального backend.
3. Загружает **ghcr.io/samosvalishe/free-turn-proxy:latest**.
4. Создаёт OBF key.
5. Создаёт случайный Client ID и allowlist **clients.json**.
6. Поднимает контейнер с host networking.
7. По умолчанию создаёт локальный WireGuard **wgfreeturn** на 127.0.0.1:51820.
8. Настраивает NAT, направленный FORWARD, изоляцию клиентов и запрет доступа к VPS.
9. Блокирует внешний доступ к WireGuard backend по IPv4 и IPv6.
10. Проверяет реальную готовность процесса, порт, OBF-профиль, WireGuard и firewall.
11. Печатает ссылки для iOS и Android.

Основные пути:

~~~text
/opt/free-turn-proxy/docker-compose.yml
/opt/free-turn-proxy/.env
/opt/free-turn-proxy/clients.json
/opt/free-turn-proxy/wireguard-client.conf
/opt/free-turn-proxy/clients/<client-id>.conf
/etc/wireguard/wgfreeturn.conf
/etc/systemd/system/free-turn-proxy-firewall.service
/usr/local/lib/free-turn-proxy/apply-firewall.sh
/usr/local/lib/free-turn-proxy/apply-wg-firewall.sh
~~~

### Ссылки и сохранение VK Call

Для iOS создаётся ссылка:

~~~text
vkturnproxy://import?data=...
~~~

Для Android-клиента [samosvalishe/turn-proxy-android](https://github.com/samosvalishe/turn-proxy-android):

~~~text
freeturn://...
~~~

Указанная при установке VK Call URL канонизируется, проверяется и сохраняется как **FREE_TURN_VK_LINK** в защищённом файле **/opt/free-turn-proxy/.env**. После этого она автоматически используется при создании клиентов, печати ссылок, QR-кодов и ротации OBF key.

Явный параметр **--vk-link** имеет приоритет и обновляет сохранённое значение. Это также позволяет один раз перенести VK-ссылку в конфигурацию старой установки:

~~~bash
sudo bash free-turn-setup.sh \
  --print-link \
  --vk-link "https://vk.ru/call/join/<hash>"
~~~

Если VK-ссылка никогда не была указана, iOS import link содержит плейсхолдер **VK_HASH**. Такой плейсхолдер нельзя импортировать как рабочую конфигурацию — сначала сохраните реальную ссылку командой выше.

Формат **freeturn://** намеренно не содержит VK Call URL. После импорта Android-клиент запрашивает её отдельно.

### Управление клиентами

Каждому устройству рекомендуется выдавать отдельного клиента. Это упрощает отзыв доступа и не требует менять настройки остальных устройств.

Создание клиентов с понятными именами:

~~~bash
sudo bash free-turn-setup.sh --add-client --client-name iphone
sudo bash free-turn-setup.sh --add-client --client-name windows
~~~

Каждая команда создаёт:

- случайный уникальный Client ID;
- отдельный WireGuard private/public key;
- отдельный IP в WireGuard-подсети;
- peer в серверной WireGuard-конфигурации;
- конфигурацию в **/opt/free-turn-proxy/clients/**;
- готовые ссылки iOS и Android.

Отображаемое имя хранится в штатном поле **comment** файла **clients.json** отдельно от технического ID. Переименование не меняет ключи и не делает существующую ссылку недействительной.

~~~bash
# Таблица клиентов, имён и Client ID
sudo bash free-turn-setup.sh --list-clients

# Назначить или изменить имя существующего клиента
sudo bash free-turn-setup.sh --name-client <client-id> ipad-home

# Удалить клиента и отозвать его доступ
sudo bash free-turn-setup.sh --remove-client <client-id>
~~~

Имена должны быть уникальными. Технический Client ID остаётся случайным и используется протоколом независимо от отображаемого имени.

### Команды управления Free Turn

~~~bash
sudo bash free-turn-setup.sh --status
sudo bash free-turn-setup.sh --logs
sudo bash free-turn-setup.sh --restart
sudo bash free-turn-setup.sh --update

sudo bash free-turn-setup.sh --print-link
sudo bash free-turn-setup.sh --print-link --client-id <client-id>
sudo bash free-turn-setup.sh --print-qr --client-id <client-id>

sudo bash free-turn-setup.sh --rotate-obf-key
~~~

Дополнительные параметры:

| Параметр | Назначение |
| --- | --- |
| --vk-link VALUE | Использовать и сохранить VK Call URL/hash |
| --client-id VALUE | Выбрать существующего клиента при формировании ссылки |
| --client-name NAME | Задать отображаемое имя при создании клиента |
| --connections 1-50 | Число соединений в создаваемой iOS-ссылке |
| --rotate-keys | При установке сменить серверный WireGuard key, сохранив клиентов |

При необходимости VK-ссылку можно передать позиционно или через **--vk-link**:

~~~bash
sudo bash free-turn-setup.sh \
  --print-link "https://vk.ru/call/join/<hash>" \
  --client-id <client-id>

sudo bash free-turn-setup.sh \
  --rotate-obf-key "https://vk.ru/call/join/<hash>"
~~~

**--update** загружает свежий image, обновляет управляемые firewall/WireGuard helpers и выполняет полный health-check.

**--rotate-obf-key** меняет общий OBF key. После ротации необходимо заново импортировать ссылки на все устройства.

Повторный интерактивный запуск сохраняет созданные WireGuard peers. Флаг **--rotate-keys** меняет серверный WireGuard key, сохраняет клиентские ключи и обновляет публичный ключ сервера в сохранённых профилях. Ранее импортированные профили после этого также требуется импортировать повторно.

Другой контейнерный image можно выбрать переменной **FREE_TURN_IMAGE**:

~~~bash
sudo FREE_TURN_IMAGE=registry.example.com/free-turn-proxy:tag \
  bash free-turn-setup.sh
~~~

### Внешний backend

Если на VPS уже существует WireGuard, AmneziaWG или другой UDP/TCP backend, на вопрос:

~~~text
Create local WireGuard backend on this VPS?
~~~

ответьте **n** и укажите **host:port** в поле **Existing backend address**.

Для локального backend обязательны управляемые firewall-правила. Переменная **FREE_TURN_NO_FIREWALL=1** допускается только при внешнем backend, когда сетевую политику обеспечивает оператор отдельно.

### Параметры ссылок

Ссылки по умолчанию создаются с 10 соединениями. Для Android также задаётся 10 потоков на кэш VK credentials. Это консервативное значение: чрезмерное число TURN-сессий повышает нагрузку, может ухудшить маскировку и увеличить вероятность ограничений со стороны VK.

Для ручной настройки iOS SRTP-WRAP-S используются:

~~~text
Server mode: SRTP-WRAP-S
Peer address: <VPS_IP>:56000
OBF profile: rtpopus3
OBF key: значение из установки
Client ID: ID выбранного клиента
WireGuard config: /opt/free-turn-proxy/clients/<client-id>.conf
VK link: https://vk.ru/call/join/<hash>
~~~

## Настройка клиентов WDTT

### iOS

Предпочтительный способ — открыть напечатанную установщиком ссылку **wdtt://** или импортировать её в настройках приложения.

Для ручной конфигурации:

~~~text
Server mode: SRTP-WRAP-A
VK link: https://vk.ru/call/join/<hash>
Peer address: <VPS_IP>:56000
WRAP-A password: <WDTT_PASSWORD>
Use UDP: off
Connections: 20-30
~~~

WireGuard-поля для SRTP-WRAP-A заполнять не требуется. Сервер выдаёт приватный ключ клиента, публичный ключ сервера, адрес **10.66.66.x/32**, DNS и MTU через GETCONF.

### Android

Ссылка для Android и iOS одинакова:

~~~text
wdtt://VPS_IP:56000:56001:9000:PASSWORD:VK_HASH
~~~

В Android-приложении:

1. Откройте настройки.
2. Включите режим ссылки.
3. Вставьте ссылку **wdtt://**.
4. Нажмите подключение и подтвердите Android VPN permission.

Ручные значения:

~~~text
Сервер/VPS: <публичный IPv4 или DNS>
VK hash: полная VK Call URL или чистый hash
Пароль подключения: <WDTT_PASSWORD>
DTLS port: 56000
WG port: 56001
Локальный порт: 9000
~~~

Android-клиент и приложение VK должны обходить создаваемый VPN-туннель, иначе получение TURN credentials может оборваться. Актуальный Android-форк добавляет необходимые исключения автоматически; при ручной настройке списка приложений это следует проверить отдельно.

## Firewall и сетевая модель

Cloud firewall в панели VPS-провайдера работает независимо от локального iptables.

Для WDTT:

~~~text
56000/udp — разрешить входящий трафик
56001/udp — не открывать
SSH — разрешить отдельно только по принятой политике администрирования
~~~

Для Free Turn с defaults:

~~~text
56000/udp — разрешить входящий трафик
51820/udp — не открывать: backend слушает loopback
SSH — разрешить отдельно
~~~

### Владение правилами WDTT

- **WDTT_SETUP** — нативный установщик: публичный DTLS ingress, блокировка внешнего WireGuard и TCPMSS clamp;
- **WDTT_DOCKER** — те же вспомогательные правила для Docker-варианта;
- **WDTT_MANAGED** — server core: NAT, строго направленный FORWARD, запрет доступа к VPS и изоляция VPN-клиентов.

Проверка systemd-варианта:

~~~bash
iptables -w -S | grep WDTT_SETUP
iptables -w -t mangle -S | grep WDTT_SETUP
iptables -w -S | grep WDTT_MANAGED
iptables -w -t nat -S | grep WDTT_MANAGED
~~~

Для Docker замените **WDTT_SETUP** на **WDTT_DOCKER**.

### Владение правилами Free Turn

- **FREE_TURN_INPUT / FREE_TURN_PROXY** — доступ к публичному порту и блокировка backend;
- **FREE_TURN_WG** — scoped NAT/FORWARD, запрет доступа к хосту и изоляция клиентов.

~~~bash
iptables -w -S FREE_TURN_INPUT
iptables -w -S FORWARD | grep FREE_TURN_WG
iptables -w -t nat -S POSTROUTING | grep FREE_TURN_WG
~~~

В **FREE_TURN_INPUT** должны присутствовать разрешение публичного порта, блокировка внешнего WireGuard backend и блокировка входа с **wgfreeturn**. В FORWARD должен присутствовать запрет **wgfreeturn -> wgfreeturn**.

Правила восстанавливаются после перезагрузки:

- systemd WDTT — сервисами **wdtt-firewall.service** и **wdtt.service**;
- Docker WDTT — Docker restart policy и entrypoint контейнера;
- Free Turn — **free-turn-proxy-firewall.service**, WireGuard unit и Docker restart policy.

## VK Call hash

1. Создайте или откройте групповой звонок VK.
2. Скопируйте ссылку приглашения.
3. Передайте полную URL либо часть после **/join/**.
4. Не завершайте звонок для всех участников: после закрытия комнаты hash перестаёт работать.

Ссылка на звонок является частью рабочей конфигурации. Не публикуйте её вместе с паролями, OBF key, Client ID или импорт-ссылками.

## Проверка после установки

### WDTT systemd

~~~bash
systemctl is-enabled wdtt wdtt-firewall
systemctl is-active wdtt wdtt-firewall
systemctl status wdtt --no-pager
journalctl -u wdtt -n 100 --no-pager

sysctl net.ipv4.ip_forward
ip -br address show wdtt0
ss -lunp | grep -E ':(56000|56001)'
~~~

Ожидаемые сообщения сервера:

~~~text
[NAT] Режим: ...
DTLS: 0.0.0.0:56000
[SERVER] Готов
~~~

### WDTT Docker

~~~bash
docker compose -f /opt/vkturn-vps-setup/docker-compose.yml ps
docker inspect wdtt --format \
  'status={{.State.Status}} running={{.State.Running}} restarts={{.RestartCount}}'
docker logs --since 10m wdtt

sysctl net.ipv4.ip_forward
ip -br address show wdtt0
~~~

### Free Turn

~~~bash
sudo bash free-turn-setup.sh --status
docker ps --filter name=free-turn-proxy
docker logs --since 10m free-turn-proxy
systemctl is-active wg-quick@wgfreeturn
~~~

Команда **--status** проверяет compose-файл, готовность контейнера, UDP listener, OBF profile, WireGuard, IPv4 forwarding, client isolation, allowlist и firewall.

Окончательная функциональная проверка требует реального подключения клиента и открытия сайта через туннель. Локальная готовность процесса сама по себе не подтверждает доступность VK TURN или корректность cloud firewall.

## Диагностика

### WDTT не запускается

~~~bash
journalctl -u wdtt -n 150 --no-pager
systemctl status wdtt wdtt-firewall --no-pager
~~~

Для Docker:

~~~bash
docker compose -f /opt/vkturn-vps-setup/docker-compose.yml ps
docker compose -f /opt/vkturn-vps-setup/docker-compose.yml logs --tail=150
~~~

### Порт не слушается

~~~bash
ss -lunp | grep -E ':(56000|56001|51820)'
~~~

Проверьте:

- не занят ли порт другим сервисом;
- совпадает ли порт в конфигурации и клиенте;
- разрешён ли UDP в cloud firewall;
- применились ли локальные правила;
- не запущены ли WDTT и Free Turn одновременно на 56000/udp.

### Типичные ошибки WDTT

~~~text
DENIED:wrong_password
  Пароль клиента не совпадает с серверным.

DENIED:device_mismatch
  Временный пароль уже привязан к другому устройству.

WRAP auth failed
  Неверный пароль, несовместимый server core или неверный режим клиента.

Bootstrap timeout
  Недоступен публичный UDP-порт, неверен VK hash, звонок завершён
  либо VK требует дополнительную проверку.

Туннель подключён, но Internet недоступен
  Требуется проверить IPv4 forwarding, NAT, FORWARD и cloud firewall.
~~~

Отсутствие IPv6 на VPS не является ошибкой: текущий WDTT-туннель и выдаваемый DNS-контракт рассчитаны на IPv4. Сообщение Android о **IPv6=false** или **ENETUNREACH** допустимо, если IPv4 через туннель работает.

## Данные, резервные копии и секреты

| Вариант | Основное состояние | Резервные копии |
| --- | --- | --- |
| WDTT systemd | /etc/wdtt/passwords.json | /etc/wdtt/backups/ |
| WDTT Docker | /opt/vkturn-vps-setup/data/passwords.json | /opt/vkturn-vps-setup/backups/ |
| Free Turn | /opt/free-turn-proxy/clients.json и clients/ | Повторный запуск сохраняет peers; рекомендуется внешняя резервная копия /opt/free-turn-proxy и /etc/wireguard |

Не публикуйте:

- **wdtt://** и **vkturnproxy://** import links;
- главный и временные пароли;
- **.env** файлы;
- Telegram bot token;
- OBF key и Client ID;
- WireGuard private keys и client configs;
- содержимое баз и резервных копий.

Root-пользователь VPS имеет доступ к этим данным. Текущий WDTT server core принимает главный пароль как аргумент процесса, поэтому root также может увидеть его в process/systemd metadata.

## Структура репозитория

~~~text
install.sh
  Нативная установка WDTT с systemd и сборкой из исходников.

vps-setup.sh
  Интерактивная Docker Compose установка WDTT.

free-turn-setup.sh
  Установка и управление Free Turn Proxy.

templates_for_script/
  Шаблоны compose, environment, entrypoint, systemd и firewall.

examples/wdtt.env.example
  Пример переменных окружения WDTT.

tests/smoke.sh
  Статические и генерационные smoke-тесты установщиков.

.github/workflows/smoke.yml
  Автоматический запуск проверок при push, pull request и вручную.
~~~

## Автоматические проверки

Workflow [Smoke tests](https://github.com/XXcipherX/vkturn-vps-setup/actions/workflows/smoke.yml) запускается:

- при каждом push;
- при создании и обновлении pull request;
- вручную через GitHub Actions.

Он проверяет:

- синтаксис Bash и ошибки ShellCheck;
- YAML workflow и compose templates;
- генерацию конфигурации WDTT и Free Turn;
- права secret-файлов и каталогов backups;
- валидацию паролей, public host, DNS и фиксированных подсетей;
- сохранение базы перед обновлением;
- разделение владельцев firewall-правил;
- readiness-контракты systemd и Docker;
- безопасный порядок обновления Docker;
- сохранение Free Turn peers, client metadata и VK link;
- наличие ключевых ссылок и команд в README.

На Linux с установленными **shellcheck**, **envsubst**, **jq** и Docker Compose тот же набор запускается командой:

~~~bash
bash tests/smoke.sh
~~~

Smoke-тесты не заменяют проверку на реальном VPS: они не подключаются к VK TURN и не изменяют firewall GitHub runner.

## Разработка и pull requests

Изменения установщиков следует сопровождать обновлением:

- соответствующих файлов в **templates_for_script/**;
- **tests/smoke.sh**, если меняется контракт установки;
- README, если меняются команды, defaults, пути или ограничения.

Перед pull request рекомендуется выполнить smoke-тесты на Linux и проверить установку или обновление на отдельном тестовом VPS. Не добавляйте в commit реальные **.env**, import links, ключи, bot tokens, базы клиентов или резервные копии.

## Лицензии

Код этого репозитория распространяется по лицензии [MIT](LICENSE).

Серверные ядра и клиентские приложения загружаются из отдельных проектов и распространяются на условиях их собственных лицензий:

- [XXcipherX/proxy-turn-vk-android](https://github.com/XXcipherX/proxy-turn-vk-android);
- [anton48/vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios);
- [samosvalishe/free-turn-proxy](https://github.com/samosvalishe/free-turn-proxy);
- [samosvalishe/turn-proxy-android](https://github.com/samosvalishe/turn-proxy-android).
