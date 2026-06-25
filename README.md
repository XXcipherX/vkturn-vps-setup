# vkturn-vps-setup

Автоматический установщик WDTT/VK TURN VPS-сервера для использования с iOS-клиентом `vk-turn-proxy-ios` в режиме **SRTP-WRAP-A**.

Скрипт рассчитан на чистый VPS с Linux и `systemd`. Он сам ставит зависимости, скачивает Go при необходимости, собирает `wdtt-server` из исходников Android-проекта, настраивает `systemd`, `ip_forward`, NAT и firewall-правила, а в конце печатает готовую `wdtt://` ссылку для импорта в iPhone.

## Какой стек используется

Этот репозиторий не содержит серверное ядро. Он автоматизирует установку на основе двух проектов:

- `amurcanov/proxy-turn-vk-android` - WDTT server core, встроенный WireGuard, WRAP-A/RTP AEAD, `GETCONF`.
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
56001/udp - внутренний WireGuard-порт wdtt-server
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

## Что делает установщик

Команда `install` выполняет:

1. Определяет Linux-дистрибутив.
2. Ставит системные зависимости: `curl`, `git`, `iproute2`, `iptables`, `nftables`, `procps`, `psmisc`.
3. Проверяет Go. Если системный Go старее нужного, скачивает Go в `/opt/wdtt/go`.
4. Клонирует исходники WDTT из `https://github.com/amurcanov/proxy-turn-vk-android.git` в `/opt/wdtt/source`.
5. Собирает `server.go` в `/usr/local/bin/wdtt-server`.
6. Создает `/etc/wdtt/wdtt.env` с параметрами установки.
7. Включает `net.ipv4.ip_forward`.
8. Создает `/usr/local/lib/wdtt/apply-firewall.sh`.
9. Создает `wdtt-firewall.service`, чтобы правила NAT/firewall применялись после перезагрузки.
10. Создает и запускает `wdtt.service`.

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
--host / WDTT_PUBLIC_HOST        IP или домен для ссылки iOS
--dtls-port / WDTT_DTLS_PORT     публичный UDP-порт, default 56000
--wg-port / WDTT_WG_PORT         внутренний WG UDP-порт, default 56001
--ssh-port / WDTT_SSH_PORT       SSH TCP-порт, default 22
--dns / WDTT_DNS                 DNS для клиентов, default 1.1.1.1,1.0.0.1
--admin-id / WDTT_ADMIN_ID       Telegram admin ID, optional
--bot-token / WDTT_BOT_TOKEN     Telegram bot token, optional
--source-repo / WDTT_SOURCE_REPO upstream repo для сборки wdtt-server
--source-ref / WDTT_SOURCE_REF   branch, tag или commit, default main
--go-version / WDTT_GO_VERSION   Go version, default 1.25.0
--no-firewall / WDTT_NO_FIREWALL не трогать iptables
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
56000/udp - обязательно
56001/udp - желательно оставить открытым для совместимости
22/tcp или твой SSH-порт
```

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

По умолчанию скрипт собирает текущую ветку `main` upstream-репозитория.

Чтобы зафиксироваться на конкретном теге или commit:

```bash
sudo /tmp/vkturn-install.sh install \
  --password "$WDTT_PASS" \
  --source-ref "main"
```

При повторном запуске:

- исходники обновятся в `/opt/wdtt/source`;
- бинарник пересоберется;
- `wdtt.service` перезапустится;
- база устройств и паролей в `/etc/wdtt/passwords.json` сохранится.

## Безопасность

- Используй длинный уникальный пароль.
- Для совместимости с `wdtt://` ссылками пароль ограничен символами `A-Z`, `a-z`, `0-9`, `.`, `_`, `-`.
- `/etc/wdtt/wdtt.env` создается с правами `600`.
- Upstream `wdtt-server` принимает пароль CLI-флагом, поэтому root-пользователь на VPS сможет увидеть его в процессах или systemd metadata. Это ограничение текущего server core.
- Не публикуй `wdtt://` ссылку публично. В ней есть пароль.

## Лицензии

Этот репозиторий содержит только установщик и README, лицензия - MIT.

Серверное ядро `wdtt-server` скачивается и собирается из upstream-проекта `proxy-turn-vk-android`, его лицензия и условия распространения остаются условиями upstream-проекта.
