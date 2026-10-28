# FC1 Co-op

**RU** · [EN](#english)

Кооп кампании Far Cry 1 (2004) в духе Sven Co-op и Synergy: оригинальные 20 карт, вместе с друзьями по сети, внешне как ванила.

> **Статус: в разработке, для игроков пока ничего нет.** Первый релиз — когда первая глава будет полностью проходима вдвоём.

## Основа и благодарности

- Проект — форк [FarCryCoop](https://github.com/Bantila/FarCryCoop) (Bantila, MIT): Lua-пак (game type `COOP`) + ASI-плагин с хуками `CryGame.dll` 1.4 + лаунчер. Их код лежит в `games/far-cry/`, их технический журнал — [games/far-cry/NOTES.md](games/far-cry/NOTES.md), инструкции по установке и консоли базы — в [README апстрима](https://github.com/Bantila/FarCryCoop#readme).
- Contest Island: Invasion (Mixer, Garcy, Garbitos) — изучен как пример кооп-мода на Lua.
- Метод — плейбук [coop-anything](https://github.com/cranebeaker/coop-anything).

## Что здесь своего

- **Харнес** (`tools/harness`, Go): запускает listen-сервер и N клиентов на одном ПК, управляет ими через Lua-агента в игре (`scripts/harness/agent.lua`), сравнивает снапшоты сущностей сервера и клиентов (детектор десинка), ловит крэши, диалоги ошибок и зависания, снимает минидампы и скриншоты. Сценарии-тесты в `tests/`.
- **Фиксы базы** (в `main`): вертолёты синхронизируются сразу и доинициализируются у клиента, интро карты ждёт всех игроков, выпавшее у ИИ оружие появляется у трупа, пикапы уровня не проваливаются в MP, снаряжение переносится между картами как в одиночной игре и хранится по ключу игрока (переподключение, сейвы).
- Журналы: [docs/findings.md](docs/findings.md) (находки и замеры), [docs/maps.md](docs/maps.md) (статус 20 карт), [docs/changelog.md](docs/changelog.md) (журнал сессий).

## Как прогнать тесты

Нужны: Far Cry 1.4 из Steam (Steam запущен), Go, MSVC 2019 Build Tools (x86).

```
tools\fcc\build-asi.cmd
cd tools && set GOARCH=386 && go build -o bin/harness.exe ./harness && cd ..
tools\bin\harness.exe test tests\training-basic.txt
```

Подробности — [tools/harness/README.md](tools/harness/README.md).

## Лицензия

Код FarCryCoop — [MIT](LICENSE). Лицензия на наш код будет выбрана до первого релиза. Код на базе Mod SDK 1.4 распространяется только бесплатно, по лицензии SDK. Far Cry — торговая марка Crytek / Ubisoft; это фанатский проект, не связанный с ними. Нужна своя копия игры.

---

## English

Campaign co-op for Far Cry 1 (2004) in the spirit of Sven Co-op and Synergy: the original 20 levels with friends over the network, looking like vanilla.

**Status: work in progress, nothing for players yet.**

- A fork of [FarCryCoop](https://github.com/Bantila/FarCryCoop) by Bantila (MIT). Its code is in `games/far-cry/`, its research log in [games/far-cry/NOTES.md](games/far-cry/NOTES.md).
- Ours: an automated test harness (`tools/harness`: a listen server and N clients on one PC driven by an in-game Lua agent, entity snapshot diffs, crash/hang capture) with scenarios in `tests/`, and fixes to the base (helicopter net presence at spawn, the map intro waits for all players, AI drops spawn at the body).
- Notes are in Russian: `docs/findings.md`, `docs/maps.md`, `docs/changelog.md`.

Far Cry is a trademark of Crytek / Ubisoft. This is a fan project, not affiliated with them. You need your own copy of the game.
