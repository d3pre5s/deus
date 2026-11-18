# Terminal isolation for Claude Code

The zsh entry point in `bin/claude` starts the vendor binary under macOS
Seatbelt. New IP sockets may connect only to the local TCP proxy port.
Children inherit that restriction across exec, including when they discard
proxy variables. Claude, curl and Git use an authenticated HTTPS proxy.
OpenSSH uses the CONNECT helper with the same local TLS trust configuration.
The signed Network Extension owns the proxy and the VLESS session. A user
LaunchAgent runs `peer-relay` and forwards encrypted TCP to one numeric VPS
address. Clients cannot supply a different destination to that relay.

The local acceptance build provides the host control commands. The installed
launcher reads `client.json` and `proxy.crt` from its installation directory.
Curl reads the matching `proxy-cacert` setting from the local `.curlrc`.
The relay reads `server`, `server_port` and `listen_port` from `peer.json`.
Keep the provider profile, private key and proxy password outside Git.

In a fresh interactive zsh, `whence -p claude` should end in
`Deus Airlock/CLI/bin/claude`. The vendor update target is still in
`~/.local/bin`. Running that original executable directly skips the launcher.
Run `airlock-cli-start` to request the stored profile when the provider is
disconnected. The command waits up to 30 seconds after binding for macOS to report
a connected tunnel. The separate egress check verifies the external IP. The local acceptance host reads back the exact rules for the
CLI, /Applications/Claude.app and its separately launched chrome-native-host when installed before starting that profile. The Desktop
rule uses the signed application identity and includes spawned helpers. Verify
a local Code session separately after installation or a Claude update.

For absolute `/usr/bin/ssh` invocations, place the block from
`ssh_config.airlock` at the start of the user's `~/.ssh/config`. Replace an
existing Airlock block when updating. The launcher provides `AIRLOCK_SSH_CONNECT`
and treats an empty `SHELL` as unset so OpenSSH can use its default shell.
Run `python3 Tests/CLI/test_ssh.py` on macOS to check both SSH entry points.

Run `python3 Tests/CLI/test_launcher.py` on macOS to check enforcement against
two real local listening sockets. Live acceptance also needs a VPS exit check,
a Git read, an SSH handshake and loss of the upstream path while an unrelated
control stays online.

### Проверка на установленном Mac

Из корня репозитория запусти команду с известным внешним IPv4 квартиры.
Значение задаётся явно, чтобы случайная смена маршрута не стала новым эталоном.

```sh
/usr/bin/python3 -B Tests/CLI/check_egress.py --expected-ip <IPv4> --outage
```

Без `--outage` тест проверяет рабочий канал и директории. С этим флагом он временно
останавливает пользовательский ретранслятор Airlock и снова запускает его в
`finally`. Открытые через Airlock соединения в этот момент прервутся.
Для запуска нужны установленный CLI Airlock, интерактивный zsh с командой
`claude`, системные Python 3 и clang. Тест создаёт временные helper-файлы в
каталогах установленных версий.

Выходной адрес измеряют системный curl и curl, запущенный через новый нативный
helper из дерева Claude. Ожидаются точное совпадение IPv4 и страна ES. Для самого
Claude используется ответ API на недействительный ключ, для SSH — получение
баннера без входа, для Git — чтение HEAD публичного репозитория. Сетевой обрыв
проверяется с независимым контролем интернета на Mac и закрытием уже открытого
SSH-канала. Проверка прямых сокетов требует запрета ядра для IPv4/IPv6 и TCP/UDP.

Проверка папок выполняется отдельно. Новый нативный helper пробует открыть
локальный контрольный порт при самостоятельном запуске и как потомок каждой
проверенной подписанной версии Claude Code. Тест сравнивает этот результат
с запретом того же порта у обычной команды `claude` в Airlock. Доступ к порту
выявляет отсутствие ожидаемого ограничения, не раскрывая внешний IP Mac.
Код возврата 1 означает, что хотя бы один критерий не выполнен. Принимается
только совместный успех дерева процессов и директорий. Этот тест сигнализирует
о смене IP; автоматическое отключение транспорта при смене адреса требует
отдельной проверки продукта.

В SSH-пробе результат «Нет сети» требует подтверждения от соединителя Airlock:
отказ локального соединения, ответ прокси 502/503/504 или закрытие потока
после успешного CONNECT до получения SSH-баннера. Ошибка сертификата,
отказ авторизации и неопределённый тайм-аут дают «Ошибка проверки» и требуют
разбирательства. SSH-баннер подтверждает доступность узла до аутентификации.

### Нативная проверка каталога

`python3 -B Tests/CLI/check_folder_filter.py` выполняет контрольный прогон без
изменения сетевых настроек. Сборка приёмки с поддержкой folder-filter и флаг
`--enable-filter` дополнительно включают фильтр на одном временном TCP-порту
127.0.0.1. Проба сравнивает независимый бинарник в каждой папке, его системный
curl и замену процесса через exec с таким же бинарником вне папок. Проверяется
также helper вне папок, запущенный установленными подписанными версиями Code.

Скрипт снимает конфигурацию в finally. Если тестовый процесс был принудительно
завершён до очистки, снять только его фильтр можно командой
`"/Applications/Deus Airlock.app/Contents/MacOS/Deus Airlock" --airlock-acceptance folder-filter-off`.
Эта проверка оценивает охват процессов на loopback. Для проверки маршрута и
обрыва через VPS используется отдельный набор выше.
