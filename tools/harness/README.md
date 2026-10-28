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
- Подробности и подводные камни (лимит командной строки 256 символов, сброс таймеров, загрузка из таймера) — в `docs/findings.md`.

## Сценарии (регрессионные тесты)

`tools/bin/harness.exe test tests/training-basic.txt` поднимает игру, выполняет шаги и печатает PASS/FAIL по каждому (отчёт сохраняется в папку прогона). Шаги: `up`, `sleep`, `wait`, `lua`, `expect <inst> <code> => <value>`, `expect-log`, `expect-diff max= class= exclude= missing=0`, `down`. Синтаксис описан в начале `test.go`.

`tests/training-basic.txt` на исходном FarCryCoop падает в 3 шагах (интро у поздно подключившегося клиента, вертолёты, выпавшее оружие), а с нашими фиксами проходит 13/13.
