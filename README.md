# vkturn-vps-setup

Автоматический установщик WDTT/VK TURN VPS-сервера для использования с iOS-клиентом `vk-turn-proxy-ios` в режиме **SRTP-WRAP-A**.

Скрипт рассчитан на чистый VPS с Linux и `systemd`. Он сам ставит зависимости, скачивает Go при необходимости, собирает `wdtt-server` из исходников Android-проекта, настраивает `systemd`, `ip_forward`, NAT и firewall-правила, а в конце печатает готовую `wdtt://` ссылку для импорта в iPhone.

## Какой стек используется

Этот репозиторий не содержит серверное ядро. Он автоматизирует установку на основе двух проектов:

- `XXcipherX/proxy-turn-vk-android`, ветка `main-new` - актуальный WDTT server core, встроенный WireGuard, WRAP-A/RTP AEAD, `GETCONF`.
- `anton48/vk-turn-proxy-ios` - iOS-клиент, который умеет подключаться к WDTT server core в режиме `SRTP-WRAP-A`.

Для iOS в этом режиме **не нужно отдельно поднимать WireGuard на VPS** и не нужно вручную вводить WireGuard-ключи в приложение. Сервер сам выдает клиенту WireGuard-конфиг через `GETCONF`.

Схема:

```text
iPhone vk-turn-proxy-ios
  -> VK TURN relay
  -> WRAP-A / DTLS
  -> wdtt-server on VPS
  -> internal WireGuard wdtt0
  -> NAT
  -> Internet
```

## Требования

- Чистый VPS с публичным IPv4.
- Debian 11+, Ubuntu 20.04+, Fedora, Rocky/Alma/CentOS/RHEL или Arch-like Linux.
- `systemd`.
- Root-доступ по SSH.
- Открытый входящий UDP-порт `56000` у VPS-провайдера.
- iOS-приложение `vk-turn-proxy-ios`.
- Ссылка на VK group call вида `https://vk.com/call/join/...`.

По умолчанию используются:

```text
56000/udp - публичный WDTT DTLS/WRAP-A порт
56001/udp - внутренний WireGuard-порт wdtt-server, снаружи должен быть закрыт
10.66.66.0/24 - подсеть клиентов
wdtt0 - WireGuard-интерфейс на VPS
```

## Быстрый старт

Зайди на VPS под root или пользователем с `sudo`.

```bash
sudo -i
apt update
apt install -y curl ca-certificates openssl
```

Скачай установщик:

```bash
curl -fsSL -o /tmp/vkturn-install.sh \
  https://raw.githubusercontent.com/XXcipherX/vkturn-vps-setup/main/install.sh
chmod +x /tmp/vkturn-install.sh
```

Сгенерируй пароль без спецсимволов. Для `wdtt://` ссылки безопаснее использовать только буквы и цифры:

```bash
WDTT_PASS="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 28)"
echo "$WDTT_PASS"
```

Запусти установку:

```bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --vk-link "https://vk.com/call/join/PASTE_YOUR_HASH_HERE"
```

В конце скрипт напечатает ссылку:

```text
wdtt://VPS_IP:56000:56001:9000:PASSWORD:VK_HASH
```

Скопируй ее на iPhone и открой в приложении `vk-turn-proxy-ios`, либо вставь через:

```text
Settings -> Import from connection link
```

## Docker-установка

Если хочешь запускать WDTT как Docker Compose stack, используй отдельный установщик:

```bash
git clone https://github.com/XXcipherX/vkturn-vps-setup.git
cd vkturn-vps-setup
sudo bash vps-setup.sh
```

Он установит Docker при необходимости, скачает готовый image `ghcr.io/xxcipherx/wdtt-server:latest` и запишет stack в:

```text
/opt/vkturn-vps-setup/docker-compose.yml
/opt/vkturn-vps-setup/.env
/opt/vkturn-vps-setup/run-wdtt.sh
/opt/vkturn-vps-setup/data/
```

`docker-compose.yml`, `.env` и `run-wdtt.sh` генерируются из файлов в `templates_for_script`.
При повторном запуске сохраненные пароль, порты, DNS, Telegram-параметры, image,
режим firewall и данные для ссылки используются как значения по умолчанию. Новый
пароль устанавливается только если его явно ввести; пустой ввод сохраняет текущий.

Если нужен другой тег или свой registry, можно переопределить image:

```bash
sudo WDTT_DOCKER_IMAGE=ghcr.io/xxcipherx/wdtt-server:latest bash vps-setup.sh
```

Контейнер запускается с `network_mode: host`, `privileged: true` и доступом к `/dev/net/tun`, потому что WDTT создает WireGuard-интерфейс и настраивает NAT. По умолчанию entrypoint добавляет host `iptables` правила с комментарием `WDTT_DOCKER`: открывает только публичный DTLS-порт, блокирует прямой внешний доступ к внутреннему WireGuard-порту и настраивает NAT/FORWARD. SSH-порт установщик не открывает. Ошибка применения обязательного правила прерывает запуск, а `vps-setup.sh` ждет сообщения готовности сервера и показывает логи при неудаче.

Если firewall ведется вручную, на вопрос `Manage host iptables/NAT rules for WDTT?` ответь `n`. В этом режиме установщик скрывает `iptables` и `nft` также от server core, поэтому внешний DTLS-доступ, блокировку WG-порта, NAT и FORWARD необходимо настроить самостоятельно. При штатном `docker compose down` entrypoint удаляет правила `WDTT_DOCKER` и `WDTT_MANAGED`; повторный запуск установщика также очищает правила со старыми портами.

Команды после установки:

```bash
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml ps
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml logs -f
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml pull
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml restart
sudo docker compose -f /opt/vkturn-vps-setup/docker-compose.yml down
```

После установки файл `/opt/vkturn-vps-setup/.env` содержит пароль и создается с
правами `600`. Не публикуй его и не добавляй в Git.

Обычный `install.sh` с `systemd` остается основным вариантом для чистого VPS. Docker-вариант удобен, если тебе привычнее compose-структура и обновление через готовый Docker image.

## Free Turn Proxy / SRTP-WRAP-S

В репозитории есть установщик для `samosvalishe/free-turn-proxy`, который нужен iOS-приложению в режиме **SRTP-WRAP-S**. Это другой серверный режим, не совместимый с `wdtt://`.

Схема:

```text
iPhone vk-turn-proxy-ios
  -> VK TURN relay
  -> SRTP-WRAP-S / DTLS
  -> free-turn-proxy on VPS
  -> local backend on VPS, usually WireGuard wgfreeturn
  -> NAT
  -> Internet
```

В отличие от WDTT, `free-turn-proxy` сам не выдает WireGuard-конфиг через `GETCONF`. Он прокидывает трафик в backend. Поэтому установщик по умолчанию поднимает локальный WireGuard backend `wgfreeturn` и сохраняет клиентский конфиг в `/opt/free-turn-proxy/wireguard-client.conf`.

Запуск:

```bash
git clone https://github.com/XXcipherX/vkturn-vps-setup.git
cd vkturn-vps-setup
sudo bash free-turn-setup.sh
```

По умолчанию скрипт:

- ставит Docker и `wireguard-tools`;
- скачивает image `ghcr.io/samosvalishe/free-turn-proxy:latest`;
- генерирует `OBF_KEY`;
- генерирует `Client ID` и включает allowlist через `clients.json`;
- поднимает `free-turn-proxy` в Docker Compose с `network_mode: host`;
- поднимает локальный WireGuard backend `wgfreeturn` на `127.0.0.1:51820`;
- печатает готовые ссылки для iOS `vkturnproxy://import?...` и Android `freeturn://...`, а также отдельные значения для режима `SRTP-WRAP-S`.

После установки основные файлы находятся здесь:

```text
/opt/free-turn-proxy/docker-compose.yml
/opt/free-turn-proxy/.env
/opt/free-turn-proxy/clients.json
/opt/free-turn-proxy/wireguard-client.conf
/opt/free-turn-proxy/clients/<client-id>.conf
/etc/wireguard/wgfreeturn.conf
/etc/systemd/system/free-turn-proxy-firewall.service
```

Если скрипт поднимает локальный WireGuard backend, в конце установки он напечатает готовую ссылку:

```text
iOS import link:
vkturnproxy://import?data=...
```

И ссылку для Android-клиента [`samosvalishe/turn-proxy-android`](https://github.com/samosvalishe/turn-proxy-android):

```text
Android turn-proxy-android import link:
freeturn://...
```

Чтобы iOS-ссылка была готовой без ручного редактирования, при установке укажи `VK call link/hash`. Если оставить поле пустым, в iOS-ссылке будет плейсхолдер `VK_HASH`.

Ее можно импортировать в iOS-приложение сразу целиком. Если используешь внешний backend или хочешь заполнить поля вручную, укажи:

```text
Server mode: SRTP-WRAP-S
Peer address: <VPS_IP>:56000
OBF profile: значение, которое напечатал скрипт, default rtpopus3
OBF key: ключ, который напечатал скрипт
Client ID: ID, который напечатал скрипт
WireGuard config: /opt/free-turn-proxy/wireguard-client.conf
VK link: https://vk.com/call/join/<hash>
```

`freeturn://` уже содержит параметры сервера, OBF, Client ID и WireGuard-конфиг. Ссылка VK Call в этот формат намеренно не входит: при её импорте Android-клиент попросит указать свою ссылку на звонок.

Android-ссылка создаётся с 10 потоками и 10 потоками на кеш VK credentials. Это безопасное стартовое значение для лимитов VK TURN; число потоков можно увеличить позже в настройках Android-клиента, если сеть и TURN-серверы это позволяют.

Команды управления:

```bash
sudo bash free-turn-setup.sh --status
sudo bash free-turn-setup.sh --logs
sudo bash free-turn-setup.sh --restart
sudo bash free-turn-setup.sh --update
sudo bash free-turn-setup.sh --print-link https://vk.com/call/join/<hash>
sudo bash free-turn-setup.sh --print-link https://vk.com/call/join/<hash> --client-id <client-id>
sudo bash free-turn-setup.sh --print-qr https://vk.com/call/join/<hash> --client-id <client-id>
sudo bash free-turn-setup.sh --list-clients
sudo bash free-turn-setup.sh --add-client
sudo bash free-turn-setup.sh --remove-client <client-id>
sudo bash free-turn-setup.sh --rotate-obf-key https://vk.com/call/join/<hash>
```

`--add-client` создает полноценного отдельного клиента: новый `Client ID`, новый WireGuard private/public key, новый IP внутри WireGuard-сети, peer в серверном WireGuard-конфиге и готовые ссылки для iOS и Android.

При повторном запуске установщик переиспользует существующие WireGuard-ключи. Чтобы явно пересоздать ключи, запусти установку с `--rotate-keys`.

Если у тебя уже есть WireGuard, AmneziaWG или TCP backend на VPS, на вопрос `Create local WireGuard backend on this VPS?` ответь `n` и укажи свой `host:port` в `Existing backend address`.

## Настройка iOS вручную

Если не используешь импорт ссылки, заполни в iOS-приложении:

```text
Server mode: SRTP-WRAP-A
VK link: https://vk.com/call/join/<hash>
Peer address: <VPS_IP>:56000
WRAP-A password: <WDTT_PASS>
Use UDP: off
Connections: 20-30
```

WireGuard-раздел для `SRTP-WRAP-A` не заполняется. Сервер выдаст клиенту приватный ключ, публичный ключ сервера, адрес `10.66.66.x/32`, DNS и MTU автоматически.

## Подключение Android

Android-клиент WDTT использует тот же сервер, пароль и VK hash. Если VPS уже поднят этим скриптом, вкладка **Деплой** в Android-приложении не нужна - она делает то же самое через SSH с телефона.

Самый простой способ - использовать ссылку, которую печатает установщик:

```text
wdtt://VPS_IP:56000:56001:9000:PASSWORD:VK_HASH
```

В приложении WDTT на Android:

1. Установи актуальный APK `proxy-turn-vk-android`.
2. Открой **Настройки**.
3. Включи **Режим ссылки**.
4. Вставь `wdtt://...` ссылку в поле **Ссылка wdtt://**.
5. Нажми **Подключить** и выдай Android разрешение на VPN.

Если заполняешь вручную:

```text
Сервер/VPS: <VPS_IP или домен>
VK hash: https://vk.com/call/join/<hash> или чистый hash
Пароль подключения: <WDTT_PASS>
DTLS port: 56000
WG port: 56001
Локальный порт: 9000
```

Порты `56000`, `56001` и `9000` являются значениями по умолчанию. Если в Android-приложении ручное управление портами выключено, их можно не менять. Количество потоков начинай с `10-20`; если сеть стабильная, можно поднять до `30`. Для нескольких VK-звонков можно указать до 4 hash, но для обычного подключения достаточно одного.

Важно: сам Android-клиент и VK-клиент должны идти мимо туннеля, иначе приложение может оборвать получение TURN-учетных данных. В актуальной Android-версии WDTT они обычно исключаются автоматически, но если включал ручные исключения приложений, проверь это отдельно.

## Что делает установщик

Команда `install` выполняет:

1. Определяет Linux-дистрибутив.
2. Ставит системные зависимости: `curl`, `git`, `iproute2`, `iptables`, `nftables`, `procps`, `psmisc`.
3. Проверяет Go. Если системный Go старее нужного, скачивает Go в `/opt/wdtt/go`.
4. Клонирует актуальную ветку `main-new` из `https://github.com/XXcipherX/proxy-turn-vk-android.git` в `/opt/wdtt/source`.
5. Собирает многофайловый Go-модуль из `app/src/main/assets/linux-server` в `/usr/local/bin/wdtt-server`.
6. Создает `/etc/wdtt/wdtt.env` с параметрами установки.
7. Включает `net.ipv4.ip_forward`.
8. Создает `/usr/local/lib/wdtt/apply-firewall.sh` и runtime helper для совместимости режима `--no-firewall` с текущим server core.
9. Создает `wdtt-firewall.service`, чтобы правила NAT/firewall применялись после перезагрузки.
10. Создает и запускает `wdtt.service`, затем проверяет, что сервис активен.

Проверка:

```bash
systemctl status wdtt --no-pager
journalctl -u wdtt -n 80 --no-pager
```

В логах должны появиться строки вроде:

```text
WRAP: password HKDF + RTP AEAD | keys: 1
[SERVER] Готов
```

## Команды

Статус:

```bash
sudo /tmp/vkturn-install.sh status
```

Логи в реальном времени:

```bash
sudo /tmp/vkturn-install.sh logs
```

Печать новой ссылки для iOS:

```bash
sudo /tmp/vkturn-install.sh link \
  --vk-link "https://vk.com/call/join/NEW_HASH"
```

Переустановка или обновление сервера:

```bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --vk-link "https://vk.com/call/join/PASTE_YOUR_HASH_HERE"
```

Удаление сервиса с сохранением `/etc/wdtt`:

```bash
sudo /tmp/vkturn-install.sh uninstall
```

Полное удаление, включая `/etc/wdtt` и `/opt/wdtt`:

```bash
sudo /tmp/vkturn-install.sh uninstall --purge
```

## Параметры

Все параметры можно передавать флагами или переменными окружения.

```text
--password / WDTT_PASSWORD       главный пароль WDTT
--vk-link / WDTT_VK_LINK         VK call URL или чистый hash
--host / WDTT_PUBLIC_HOST        IP или домен для ссылки iOS, без схемы и порта
--dtls-port / WDTT_DTLS_PORT     публичный UDP-порт, default 56000
--wg-port / WDTT_WG_PORT         внутренний WG UDP-порт, default 56001
--ssh-port / WDTT_SSH_PORT       SSH TCP-порт для совместимости и очистки старых правил, default 22
--dns / WDTT_DNS                 DNS для клиентов, default 1.1.1.1,1.0.0.1
--admin-id / WDTT_ADMIN_ID       Telegram admin ID, optional
--bot-token / WDTT_BOT_TOKEN     Telegram bot token, optional
--source-repo / WDTT_SOURCE_REPO репозиторий для сборки wdtt-server, default XXcipherX/proxy-turn-vk-android
--source-ref / WDTT_SOURCE_REF   branch, tag или commit, default main-new
--go-version / WDTT_GO_VERSION   Go version, default 1.25.0
--no-firewall / WDTT_NO_FIREWALL не применять iptables/nft правила ни установщиком, ни server core
--with-firewall                  снова включить managed iptables после --no-firewall
```

При повторном запуске параметры, переданные флагами или переменными окружения, имеют приоритет над сохраненными значениями из `/etc/wdtt/wdtt.env`.

Пример с доменом и нестандартным SSH-портом:

```bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --host "vpn.example.com" \
  --ssh-port 2222 \
  --vk-link "https://vk.com/call/join/PASTE_YOUR_HASH_HERE"
```

Пример с Telegram-ботом для управления временными паролями:

```bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --admin-id "123456789" \
  --bot-token "123456789:AA..." \
  --vk-link "https://vk.com/call/join/PASTE_YOUR_HASH_HERE"
```

## Firewall у VPS-провайдера

Локальный `iptables` скрипт открывает порты внутри ОС, но многие VPS-провайдеры имеют отдельный cloud firewall в панели управления.

Открой там:

```text
56000/udp - открыть обязательно
56001/udp - обязательно закрыть снаружи; это только внутренний WireGuard-порт
22/tcp или твой SSH-порт - настрой отдельно по своей политике доступа
```

Установщик не открывает SSH-порт самостоятельно и блокирует вход к WireGuard-порту
со всех интерфейсов, кроме loopback. Если используется `--no-firewall`, эти правила,
NAT и FORWARD нужно настроить вручную до запуска WDTT.

Если меняешь `--dtls-port`, в iOS нужно указывать именно его:

```text
Peer address: VPS_IP:<dtls-port>
```

## VK call hash

1. Открой VK.
2. Создай или открой групповой звонок.
3. Скопируй ссылку приглашения.
4. Используй всю ссылку или только часть после `/join/`.

Важно: не завершай звонок "для всех". Если закрыть комнату для всех участников, hash перестанет работать.

## Диагностика

Сервис не запустился:

```bash
journalctl -u wdtt -n 120 --no-pager
```

Проверить, слушаются ли UDP-порты:

```bash
ss -lunp | grep -E ':(56000|56001)\b'
```

Проверить NAT/firewall-правила:

```bash
iptables -S | grep WDTT_SETUP
iptables -t nat -S | grep WDTT_SETUP
iptables -t mangle -S | grep WDTT_SETUP
```

Для Docker-варианта замени `WDTT_SETUP` на `WDTT_DOCKER`; правила, добавленные
самим server core, имеют комментарий `WDTT_MANAGED`.

Типичные ошибки:

```text
DENIED:wrong_password
  Пароль в iOS не совпадает с --password.

DENIED:device_mismatch
  Временный пароль уже привязан к другому устройству.

WRAP auth failed
  Неверный пароль, старый сервер без WRAP-A или клиент не в SRTP-WRAP-A.

Bootstrap timeout на iOS
  Не открыт 56000/udp, неверный VK hash, завершен VK-звонок или VK требует captcha.

Туннель подключился, но Интернета нет
  Проверяй ip_forward, NAT и cloud firewall у провайдера.
```

## Обновление server core

По умолчанию скрипт собирает текущую ветку `main-new` форка XXcipherX.

Чтобы зафиксироваться на конкретном теге или commit:

```bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --source-ref "b154ce94d7a85c862bf1f301e75966a1b71a9b86"
```

При повторном запуске:

- исходники обновятся в `/opt/wdtt/source`;
- бинарник пересоберется;
- `wdtt.service` перезапустится;
- база устройств и паролей в `/etc/wdtt/passwords.json` сохранится.

## Безопасность

- Используй длинный уникальный пароль.
- Для совместимости с `wdtt://` ссылками пароль ограничен символами `A-Z`, `a-z`, `0-9`, `.`, `_`, `-`.
- `/etc/wdtt/wdtt.env` и Docker-файл `/opt/vkturn-vps-setup/.env` создаются с правами `600`.
- Текущий `wdtt-server` принимает пароль CLI-флагом, поэтому root-пользователь на VPS сможет увидеть его в процессах или systemd metadata. Это ограничение текущего server core.
- Не публикуй `wdtt://` ссылку публично. В ней есть пароль.

## Автоматические проверки

Workflow `.github/workflows/smoke.yml` запускается при каждом push, при создании
или обновлении pull request и вручную через GitHub Actions. Он проверяет синтаксис
и ShellCheck всех shell-скриптов, YAML, генерацию конфигурации обоих установщиков,
Docker Compose для WDTT и Free Turn, права secret-файлов, валидацию входных данных,
firewall-инварианты и синхронизацию ключевых ссылок в README.

Тот же набор smoke-тестов можно запустить локально на Linux, если установлены
`shellcheck`, `envsubst` и Docker Compose:

```bash
bash tests/smoke.sh
```

## Лицензии

Этот репозиторий содержит только установщик и README, лицензия - MIT.

Серверное ядро `wdtt-server` скачивается и собирается из форка `XXcipherX/proxy-turn-vk-android`, его лицензия и условия распространения остаются условиями исходного проекта.
