# Volunteer & Expeditionary Forces (VEF)

Source for VEF, a Civilization VI mod that lets you lend combat units to your allies, friends and city-states, and hand captured cities to a partner. It needs the Gathering Storm expansion.

The rules and a full feature list are in [EFV/README.md](EFV/README.md). The project's internal prefix is `EFV_`, which is why folders and files use it. In the game the mod is always called VEF.

## Folders

- `EFV/` is the mod itself. This is the folder you install.
- `EFV_Dev/` is a second mod with a developer panel for in-game testing. Don't enable it in a normal game.
- `tools/` and `tests/` hold the offline checks: Lua syntax and globals, database and text validation, engine call audit, and a fake game engine that runs the mod's scripts. See [tools/README.md](tools/README.md).
- The rest (`PLAN.md`, `DECISIONS.md`, `research/`, `spike/` and the notes next to them) are design notes and early experiments.

## Installing by hand

1. Copy the `EFV` folder into your Civilization VI mods folder. On Windows that is `Documents\My Games\Sid Meier's Civilization VI\Mods`.
2. Start the game, open Additional Content and enable "Volunteer & Expeditionary Forces". Gathering Storm has to be enabled too.
3. Start a new game or load a save. The mod is saved with the game, so don't remove it in the middle of one.

## Running the checks

```
pip install lupa
python tools\check_all.py
python tests\offline\run_tests.py
```
