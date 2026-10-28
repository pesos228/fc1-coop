# harness

Запускает Far Cry (сервер и N клиентов) с Lua-агентом внутри игры, управляет ими командами и собирает состояние, логи, скриншоты и минидампы.

Сборка (32-битная, чтобы минидампы x86-процесса были нативными):

```
cd tools && GOARCH=386 go build -o bin/harness.exe ./harness
```

Типовая сессия (из корня репозитория):

```
tools/bin/harness.exe up -mode host -map training -clients 1
tools/bin/harness.exe state
tools/bin/harness.exe lua client1 "return tostring(Game:IsInMenu())"
tools/bin/harness.exe cmd server "SkipCutScene"
tools/bin/harness.exe shot all
tools/bin/harness.exe log client1 -grep "rror" -n 20
tools/bin/harness.exe down
```

Как устроено:
- `up` создаёт `.harness/runs/<время>/` и запускает в фоне супервизор (`harness supervise`). Он бэкапит `system.cfg`/`game.cfg`, пишет `SystemCfgOverride.cfg` (оконный режим, включённый лог), запускает экземпляры, раскладывает окна, ждёт загрузки уровня и потом следит за процессами: крэши, диалоги ошибок, пропавший heartbeat агента. В этих случаях делает скриншот и минидамп. По `down` или после выхода всех процессов восстанавливает конфиги.
- В каждый экземпляр через `boot.lua` грузится `scripts/harness/agent.lua`. Агент читает `cmd.txt`, пишет `ack.txt` и раз в ~1 с обновляет `state.txt` (уровень, игроки, ИИ, позиция). Агента можно перезагрузить на лету: `harness lua <inst> "dofile('D:/fc1-coop/scripts/harness/agent.lua')"`.
- Клиенты играют под именами `client1`, `client2`, … (`p_name`): хост узнаёт игрока по имени, а у всех копий игры на одном ПК оно одно. Помощники агента для сценариев: `Harness:RemotePlayer()`, `Harness:Player(имя)`, `Harness:Loadout(P)` (снаряжение одной строкой).
- Подводные камни: командная строка `FarCry.exe` обрезается до 256 символов (поэтому всё идёт через `boot.lua`); таймеры скриптов сбрасываются при загрузке уровня (агент перевзводится обёртками `Game.Load*`); загрузку уровня нельзя запускать из колбэка таймера (агент откладывает её в `Hud:OnUpdate`); без запущенного Steam игра сразу выходит с кодом 53 (`up` проверяет это заранее).

## Сценарии (регрессионные тесты)

`tools/bin/harness.exe test tests/training-basic.txt` поднимает игру, выполняет шаги и печатает PASS/FAIL по каждому (отчёт сохраняется в папку прогона). Шаги: `up`, `sleep`, `wait`, `lua`, `cmd`, `expect <inst> <code> => <value>`, `expect-log`, `expect-diff max= class= exclude= missing=0`, `down`. Синтаксис описан в начале `test.go`.

Сценарии:
- `tests/training-basic.txt` (19 шагов): подключение, интро, `diff` игроков, наёмников и вертолётов, убийство ИИ и выпавшее оружие, триггер и телепорт удалённого игрока. На исходном FarCryCoop падает в 3 шагах (интро у поздно подключившегося клиента, вертолёты, выпавшее оружие).
- `tests/pickups.txt` (17): пикапы уровня в MP лежат как в SP, подбор удалённым игроком.
- `tests/level-change.txt` (32): перенос снаряжения Training → Carrier и при переподключении.
- `tests/progress.txt` (22): снаряжение по ключу игрока через сейв и перезапуск сервера.
- `tests/smoke-map.txt` (`MAP=<карта>`): дымовой тест одной карты, результаты в `docs/maps.md`.
