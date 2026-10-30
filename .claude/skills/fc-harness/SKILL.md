---
name: fc-harness
description: Build, run and read the FC1 Co-op test harness (tools/harness, tests/*.txt) — rebuilding the mod pack, FarCryCoopNet.asi and harness.exe, running one scenario or the full suite, writing a new scenario, and telling a real failure from environment noise. Use it whenever you are about to start Far Cry through the harness, check a Lua or ASI fix, claim something is "fixed", commit a fix (the full suite comes first), add a regression test, or look at a red run in .harness/runs — even if the user only says "проверь", "прогони тесты", "почини" or "сделай сценарий".
---

# Харнес FC1 Co-op

Всё, что мы утверждаем про игру, проверяется харнесом: он поднимает слушающий сервер и клиентов на одной машине, внутри каждого экземпляра работает Lua-агент (`scripts/harness/agent.lua`), а харнес шлёт ему команды и сравнивает сущности сервера и клиентов. Подробности устройства — `tools/harness/README.md`, синтаксис сценариев — шапка `tools/harness/test.go`. Правила, когда что запускать, — раздел «Отладка и десинки» в `CLAUDE.md`; этот скилл про то, *как*.

## Перед запуском

Игра, установка и `tools/bin` общие на всю машину, поэтому одновременно идёт только один прогон. Сначала проверь окружение — почти все «странные» падения были отсюда:

1. **Steam запущен.** Без него `FarCry.exe` выходит с кодом 53 (`up` скажет об этом).
2. **Сессия Windows на консоли или RDP-окно развёрнуто.** `query session`: строка `console` с `Active` — хорошо. Если владелец подключён по RDP и окно свёрнуто или отключено, второй экземпляр падает на создании D3D9-устройства. Не чини это кодом: попроси развернуть окно или перевести сессию на консоль (`tscon <id> /dest:console`, монитор включён).
3. **Ничего не висит от прошлого прогона:** `tools/bin/harness.exe down` безвреден, если всё уже закрыто.
4. **Запускай харнес из bash, не из PowerShell 5.1.** PowerShell съедает кавычки в `-start '#CoopMap("training")'`, и карта не грузится.

## Сборка

Харнес сам пакует `games/far-cry/mod/FarCryCoop` в `FarCryCoop.pak` при каждом `up -mod FarCryCoop`, отдельно пак собирать не надо. Остальное — руками, когда менялся соответствующий код:

| Что менялось | Команда (из корня) |
|---|---|
| `games/far-cry/asi/*.c` | `bash .claude/skills/fc-harness/scripts/build.sh asi` → `tools/bin/FarCryCoopNet.asi` |
| `tools/harness/*.go` | `bash .claude/skills/fc-harness/scripts/build.sh harness` → `tools/bin/harness.exe` |
| `scripts/harness/agent.lua` | ничего: грузится при старте; на живом прогоне — `harness lua <inst> "dofile(...)"` |

Без аргумента `build.sh` собирает оба. Внутри — `tools\fcc\build-asi.cmd` (MSVC 2019 x86, путь зашит в нём; строка `'vswhere.exe' is not recognized` от `vcvarsall` безвредна) и `GOARCH=386 go build`. Не собирай ASI и не правь Lua мода, пока идёт прогон: следующий `up` возьмёт полусобранное.

## Один сценарий

```bash
tools/bin/harness.exe test tests/heli-rotor.txt
MAP=steam tools/bin/harness.exe test tests/smoke-map.txt      # сценарии с ${VAR}
tools/bin/harness.exe test -keep tests/pickups.txt            # не гасить игру в конце, чтобы покопаться
```

Вывод: `PASS/FAIL <строка> <шаг>` и итог `<файл>: N steps, K failed`. Папка прогона — строка `run: …\.harness\runs\<время>` в начале вывода; её путь и итог приводи в отчёте, когда заявляешь результат.

Сценарий идёт 1–4 минуты (карты Steam/River дольше). Запускай с таймаутом 10 минут или в фоне.

## Полный прогон

Перед коммитом фикса (правило 6) — весь `tests/*.txt`:

```bash
bash .claude/skills/fc-harness/scripts/run-suite.sh            # все сценарии + дым training и dam
bash .claude/skills/fc-harness/scripts/run-suite.sh heli-rotor pickups   # выборочно
```

Это 40–70 минут: запускай в фоне (`run_in_background`) и жди уведомления, не опрашивай. Итог — `.harness/suite/summary.txt`, по строке на сценарий, вывод каждого — `.harness/suite/<имя>.out`. Сценарии с `OPEN` в шапке (известная открытая проблема, падают до фикса) помечены `open`, их падение не регрессия; если такой вдруг позеленел — это новость, проверь и сними `OPEN` отдельным коммитом.

Последний известный результат держи в голове из `docs/changelog.md`: красный сценарий, который там был зелёным, — регрессия, коммита нет.

## Красный прогон: баг или шум

Прежде чем трогать код, открой папку прогона:

- `events.log` — крэши, диалоги ошибок, «agent stalled» от супервизора; `supervisor.log` — как шёл запуск.
- `<inst>/game.log` — лог игры (`server`, `client1`, …). Ищи `Lua error`, `stack overflow`, `pos is invalid`, первую ошибку после `MON`.
- Минидампы и скриншоты кладёт супервизор туда же при крэше.

Шум (записать как шум с замером, код не трогать):
- свёрнутый или отключённый RDP: в `<inst>/game.log` `Couldn't find any suitable device`, затем `Exception 0xC0000005 at 0x38010FA3` (модуль `<Unknown>`, это рендерер), в `events.log` — `dialog Critical Exception`; иногда просто «no window»;
- окно автонастройки `FarCryConfigurator` («no window after 90s»): в установке `system.cfg` должен начинаться строкой `-- This file has been written by FarCryConfigurator.exe` (резерв исходного — `.harness/cfg-before-autodetect/`);
- таймаут `wait` на долгой карте при загруженной машине — повтори с тем же сценарием.

Плавающее падение сначала меряй: прогони тот же сценарий N раз и запиши «k из N» (правило 7). Для этого:

```bash
bash .claude/skills/fc-harness/scripts/run-suite.sh -n 10 steam-boat-crew
```

## Новый сценарий

Сценарий пишется **до** фикса и должен падать именно по причине бага (правило 1). Образец — `tests/heli-rotor.txt`. Шаблон и приёмы — `references/scenario.md`; прочитай его, когда пишешь или меняешь сценарий.

Ожидания в существующем сценарии (`expect`, `max=`, `exclude=`, таймауты) меняй отдельным коммитом с причиной в сообщении — ослабление проверки тоже смена ожиданий.

## Ловушки, на которых уже теряли время

- Lua 4, а не 5: нет `local function`, внешние локальные — через `%имя`, `^` не степень; `GetPos()` отдаёт общий вектор — копируй `x,y,z` сразу.
- Код в `lua`/`expect` идёт одной строкой; длинную логику держи в моде или в агенте.
- `CoopMovePlayer` для удалённого игрока, а не `SetPos` с сервера: клиент владеет своей позицией, и сырой `SetPos` доходит через 8–22 с.
- `#CoopMap` на уже идущей карте роняет сервер — меняй карту через новый `up`.
- В папке игры агент ничего не удаляет (тестовые `save_*.lua` и прочее удаляет владелец); после неудачного опыта проверь, что там не осталось чужого ASI или пака.
