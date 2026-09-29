# Tools: static checks, install and logs

Offline checks for the VEF mod (internal prefix `EFV_`), plus the install script and log readers. Everything runs from the project folder with Python 3.12. Only `check_lua.py` needs an extra package: `pip install lupa`.

## Quick start

```
python tools\check_all.py                 # EFV\ and EFV_Dev\
python tools\check_all.py EFV EFV_Dev     # explicit folders (a mod folder or a folder of mods)
python tools\check_all.py EFV --strict    # warnings fail too
```

`check_all.py` runs `check_lua.py`, `validate_data.py` and `api_audit.py` and exits non-zero on any error. Findings look like `path:line: LEVEL [code] message`. At the end it prints a per-tool summary and a list of engine calls that still wait for an in-game test. `--info` shows INFO lines, `--basic` skips the Lua runtime, `--db PATH` picks another gameplay database.

The tools test themselves with `python tools\test_tools.py` (14 tests on `tools\fixtures`).

## check_lua.py: Lua syntax and globals

```
python tools\check_lua.py EFV [--basic] [--no-globals] [--luacheck auto|on|off] [--strict]
```

- Syntax: every file is compiled (never run) with the real Lua 5.1 parser from `lupa`. Firaxis type annotations (`local x:number`), `goto`, `//`, bit operators and unclosed blocks all fail with a line number.
- Globals: the compiled bytecode is read for global reads and writes. Each modinfo entry point (gameplay script, UI context, replaced UI script) plus everything it includes counts as one Lua state. A global that is read must be defined in every state the file runs in. Unknown reads are errors. A global assigned only inside a function is a warning (missing `local`?). Overwriting an engine global is an error. A file can declare extra globals with `-- EFV:GLOBALS Name1 Name2`.
- Code between `-- EFV:G-ONLY begin/end` or `-- EFV:UI-ONLY begin/end` counts only for that context.
- luacheck is used when it is on the PATH or in `tools\bin\`. It is not installed now; the bytecode check covers the same cases.
- `--basic` skips the Lua runtime and only does a rough block balance check.

## validate_data.py: XML, modinfo, SQL and text

```
python tools\validate_data.py EFV [--db PATH]
```

- Every `.xml`, `.modinfo` and `.artdef` file is well formed.
- modinfo: valid ids, every action has criteria, every listed file exists (exact case) and every file on disk is listed (except `.md` and `.txt`), the Gathering Storm dependency, `AffectsSavedGames=1`, complete `ReplaceUIScript` and `AddUserInterfaces` entries.
- SQL: the game's cached gameplay database is copied to a temp folder (the original is only read). Leftover `EFV*` rows from a previous game are removed from the copy. Then every database file of the mod runs there in load order, with the game's own hash function. Unknown tables or columns, constraint failures and hash collisions fail, and a final foreign key check copies what the game does on load. Notification types and rows must pair up. Icon files run against a small stub table.
- Text: no duplicate keys, no rows for keys the base game already has, every `LOC_*` key used in Lua, SQL, UI XML or the modinfo exists, placeholders get enough arguments, plural forms are written correctly, every reason code has its text, unused keys are warnings, and every notification has a message and a summary.
- Displayed name: the word "EFV" in any player-visible English text or modinfo display field is an error. Players see "VEF".
- Icons: every notification type needs an icon alias.
- Lua cross references: notification type names exist in the SQL, `Controls.X` exists in the paired XML, instance names match.

Database paths: the newest of `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Cache\` and `Documents\My Games\...\Cache\`. Override with `--db` or the `EFV_CIV6_DB` / `EFV_CIV6_LOC_DB` environment variables.

## api_audit.py: engine calls and multiplayer rules

```
python tools\api_audit.py EFV [--strict] [--no-checklist]
python tools\api_audit.py --regen          # rebuild api_allowlist.json and .luacheckrc from PLAN.md
```

- `api_allowlist.json` is generated from PLAN.md Appendix A and rebuilt when that appendix changes. It lists every engine call the mod may use, per context (gameplay or UI), with its test status.
- `api_allowlist_extra.json` holds additions by hand, each with evidence in `refs`: UI widget methods, input methods, calls only EFV_Dev may use (`only_paths`), and globals defined by base game files.
- `engine_globals.json` lists every global the game's own Lua reads but never defines (enums like `YieldTypes`). Rebuild it with `python tools\harvest_engine_globals.py [--game PATH]`.
- Errors: a call that is not on the list or is used in the wrong context, unknown project functions, forbidden patterns (`math.random`, `os.*` in gameplay, `pairs(` in gameplay outside sorted-key helpers, `table.unpack`, `ExposedMembers` and others), any state change reachable from an `Events.*` handler registered in gameplay, and a UI request without a gameplay handler.
- Warnings: calls that still wait for an in-game test (these also make up the printed checklist), and a few risky patterns.

## install.ps1: install and follow the log

```
powershell -ExecutionPolicy Bypass -File tools\install.ps1                # checks, then copy EFV\
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Dev -Watch     # also EFV_Dev\, then follow Lua.log
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -CheckLogs      # only scan the last run's logs
```

- Runs `check_all.py` first. Errors stop the install unless you pass `-Force` (`-SkipChecks` skips the checks, `-Strict` also stops on warnings).
- Mirrors the folders into `S:\Libraries\Documents\My Games\Sid Meier's Civilization VI\Mods\EFV` (and `EFV_Dev`). It refuses targets outside `-ModsDir` or folders not named `EFV*`. Files deleted in the source are deleted in the copy too.
- `-Watch` / `-WatchOnly` follow `Lua.log`, filtered by `-Pattern` (default `EFV|Runtime Error|Syntax Error|stack traceback`), and pick the file up again when the game recreates it.
- `-CheckLogs` runs `tools\check_logs.py` on Database.log, Modding.log, Lua.log and UserInterface.log. Exit code 1 on errors that involve the mod.
- Logs: `-LogsDir` defaults to `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs`. The copy under `Documents\My Games` is stale. `Lua.log` is buffered while you play, so read it after quitting to the menu or the desktop.

## summarize_efv_log.py: result of the final in-game session

```
python tools\summarize_efv_log.py [--retest | --s14] [--log PATH] [--db PATH] [-v]
```

`--retest` reads the short 0.7 re-test (`EFV/TESTING_RETEST_0.7.md`) and `--s14` the mutiny-death check (`EFV/TESTING_S14.md`). Every mode ends with the error count and the "Badge audit" line of VEF Dev Tools 0.7.2-dev.1.

Reads `Lua.log` after the session in `EFV/TESTING_FINAL.md` and prints one line per step, for example `Step  7  PASS   Grace (S3): ...`. A step is PASS, CHECK (look at it) or `-` (not run). It uses the `[EFV][CHECK]` lines written by the VEF Dev Tools scenario buttons, plus a few of the mod's own lines: the versions, every send with its fee (compared with the expected fee from the game database), Entrust, and the number of game loads. The last line counts error lines. `-v` also prints every CHECK line. Quit the game before running it.

## Fixtures

- `fixtures\good\EFV_Fixture`: a small mod shaped like VEF. 0 errors and 2 known warnings expected.
- `fixtures\bad\EFV_Broken`: one planted mistake per rule, each marked with a comment.
- `fixtures\logs\{good,bad}`: made-up logs for `check_logs.py`.

## Limits

- Method calls are matched by name only, so a method used on the wrong kind of object passes if the name is on the list.
- Code built at runtime (`GameEvents[name].Add`, keys built from strings, `include(variable)`) is not followed. Text key prefixes built at runtime are only checked for "matches at least one key".
- The check for state changes in `Events` handlers follows calls by name within one Lua state. Calls through tables of functions or `pcall(f, ...)` are not followed.
- The cached database reflects the last game's rules and mods, so rows from other mods can still collide. The icon check uses a stub table, and UI XML is checked for ids, not for layout.
