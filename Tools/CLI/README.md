# Terminal isolation for Claude Code

## Install for one macOS user

1. Install the signed PKG or copy Deus Airlock from its DMG to
   `/Applications/Deus Airlock.app`. Open Airlock, choose **Install System
   Extension** and approve the extension in macOS. The terminal tools require
   a graphical login, `/usr/bin/python3` from Apple's Command Line Tools or
   Xcode, and the signed vendor CLI at `~/.local/bin/claude`.
2. Prepare a private directory containing the four files below. Keep this
   directory outside the repository and restrict access to your account.
3. Run the setup from the installed app as the login user. Choose the input
   directory explicitly. macOS can ask for permission to save the VPN policy.

```sh
setup="/Applications/Deus Airlock.app/Contents/Resources/AirlockCLI/airlock-setup"
"$setup" install --config-dir "$HOME/private-airlock-inputs"
```

| Input | Values used during setup |
| --- | --- |
| `client.json` | Integer proxy `port`, `password`, and an optional nonempty `targets` array of signed paths. For terminal-only use, set `"targets": ["~/.local/bin/claude"]`. Add the Desktop app and its separately launched chrome-native-host explicitly if selected. |
| `peer.json` | Numeric VPS address in `server`, its TCP `server_port` and the loopback relay's TCP `listen_port`. The client and relay use different local ports. |
| `provider.json` | A single VLESS/REALITY upstream via the selected relay and one TLS HTTP listener on `127.0.0.1` at the client port. Its only proxy user is `airlock` with the password from `client.json`. The TLS certificate and key are inline. The signed host checks the complete transport policy before saving. |
| `proxy.crt` | The PEM certificate of that loopback HTTPS proxy. The launcher gives it to curl, Git, Node and the SSH CONNECT helper in the protected process tree. |

For an earlier authenticated `mixed` listener, setup changes its type to
`http` in the private installed copy. The host pins the bytes of that copy.
The user-supplied files retain their original contents. Without `targets`,
the controller uses the previously saved selection. The initial selection
on a fresh account is the vendor CLI.

Setup installs the versioned scripts and private inputs under
`~/Library/Application Support/Deus Airlock`, registers the peer relay in
the user's `Library/LaunchAgents`, and adds marked blocks to the interactive
zsh configuration and `~/.ssh/config`. The SSH block applies to commands
launched under Airlock. The relay verifies the fingerprint of `peer.json`
from its LaunchAgent before opening a listener. Setup finishes by saving
the selected application rules and the provider pin through the signed host.

Open a **new interactive zsh**. Check which executable it will run, then
start the profile and run Claude.

```sh
whence -v claude
whence -p claude
airlock-cli-start
claude
```

The executable path should end in `Deus Airlock/CLI/bin/claude`. Check any
alias or function reported by `whence -v`. The vendor binary remains in
`~/.local/bin`; invoking its absolute path skips the launcher. The
launcher passes its network restriction to children across exec. Claude,
curl, Git and OpenSSH use the authenticated TLS proxy. The signed Network
Extension owns the proxy and VLESS session. The user relay forwards the
encrypted stream to the selected numeric VPS.

`airlock-cli-start` reads back the selected application rules and waits
up to 30 seconds after binding for macOS to report the connected state.
Verify the actual egress address separately. Repeat live acceptance for a
new build, a changed provider or a new Claude version.

## Update and roll back

Run the same explicit setup command after installing an updated Airlock app
or changing the four local inputs. Stop the protected transport in Airlock
before replacing a working provider configuration. An identical install
reuses its release and relay. A new release retains the previous local
files for rollback. Setup reports an unrelated LaunchAgent or edited
Airlock settings block before switching the installation.

```sh
"/Applications/Deus Airlock.app/Contents/Resources/AirlockCLI/airlock-setup" rollback
```

Each rollback goes back one local release. Rolling back the initial install
removes its relay, launcher and marked shell/SSH blocks. Other settings and
later edits outside those blocks are preserved. Open a new zsh after
rollback. The saved macOS per-app policy retains its pin. If the previous
release needs different pins or targets, rollback stops before switching.
Close the selected applications, stop the transport, then run
`"$setup" rollback --restore-policy` to authorize the prior release through
the signed host. A rejected policy restores the current local release and
relay. Start the profile again with `airlock-cli-start`.

### Migrate a manual build-12 installation

Keep the matching signed build-12 qualification app for recovery. Close
the selected applications, stop the protected transport and confirm
macOS reports it disconnected. Install the new signed app and approve its
extension. The command below names the old private inputs explicitly.

```sh
setup="/Applications/Deus Airlock.app/Contents/Resources/AirlockCLI/airlock-setup"
cli="$HOME/Library/Application Support/Deus Airlock/CLI"
"$setup" migrate --config-dir "$cli"
```

Migration recognizes the documented CLI directory and its user LaunchAgent.
It moves both into the private `Terminal Releases/legacy-v12` backup on
the same volume and keeps every file, including user additions. Existing
shell and SSH settings remain in place. If onboarding fails, it restores
the original directory, original plist and prior relay registration.
A repeat can read the same original inputs from the backup.

To return to that installation later, first roll back any newer managed
releases to the migration boundary. Close the selected apps and stop the
transport. Restore the matching signed build-12 qualification app and
system extension, then run the saved recovery command as the same user.

```sh
"$HOME/Library/Application Support/Deus Airlock/Terminal Releases/legacy-v12/airlock-setup" restore-legacy
```

Recovery checks build 12 and the qualification host's disconnected policy
before restoring the original local files and registration. Open a new zsh
and qualify the restored system extension and network path before using
the protected applications.

## Offline and live checks

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
