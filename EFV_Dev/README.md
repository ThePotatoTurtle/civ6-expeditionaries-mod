# VEF Dev Tools (EFV_Dev)

A separate mod with a developer panel for testing Volunteer & Expeditionary Forces (VEF) in game. It needs Gathering Storm and VEF (mod id `fcc83bd7-1abf-4d9a-bddb-01633574bf40`). Its own id is `94ec021d-9956-4a30-b9c1-5ccf136679bf`.

Version 0.6.1-dev, made for VEF 0.6.1-dev. Never enable it in a real game.

The internal prefix of the project is `EFV_`, so files, Lua names and log tags use that. Players only ever see "VEF".

## Files

| File | Context | What it does |
|---|---|---|
| `EFV_Dev.modinfo` | | Gameplay script and UI context (InGame), load order 14000, Gathering Storm only |
| `Scripts/EFV_Dev_Gameplay.lua` | gameplay | handles `GameEvents.EFV_Dev(playerID, params)` by `params.cmd`, plus the final-session checks |
| `UI/EFV_Dev_Panel.xml/.lua` | UI | the panel; sends flat `EXECUTE_SCRIPT` requests |

The gameplay script changes VEF state only through VEF's own record API (`EFV_Records`: `Load`, `Get`, `FindByUnit`, `New`, `Touch`, `Commit`, `AddPending`, `Delete`, `Dump`) and `EFV_Units` (`Snapshot`, `ApplySnapshot`, `Remove`, `GetForRecord`). Everything goes through the Game properties, as INTERFACES.md sections 3.4 and 5 describe. The script runs in its own Lua state and includes VEF's modules itself. They keep no state of their own, so VEF sees every change on its next handler call.

## Install and open

1. Close the game, then run `powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Dev -Watch`. It copies `EFV\` and `EFV_Dev\` into the Mods folder and follows `Lua.log`.
2. In Additional Content enable Gathering Storm, Volunteer & Expeditionary Forces and VEF Dev Tools. Leave the old EFV Spike Test mod off: it also answers `EXECUTE_SCRIPT` requests.
3. Open the panel with Ctrl+Shift+D or the DEV button on the launch bar. Esc or Close hides it. The context loads hidden (INTERFACES note 19), so `Initialize` shows it and only toggles `Main`.

## Final session buttons

These are at the top of the panel. Each one sets up a whole test situation in one click. `EFV/TESTING_FINAL.md` walks through them in order, and `tools/summarize_efv_log.py` reads the results from `Lua.log` afterwards.

| Button | cmd | What it sets up | Check line at your next turn |
|---|---|---|---|
| S0 Setup session | `scn_setup` | B (first other major) your ally, F (second) your friend, C (third) at war with you, B, F and the first city-state; 2000 gold, 10 Iron, 3 Swordsmen next to your capital | `SETUP` (right away) |
| S1 Arrive next turn | `scn_arrive` | every unit you sent, or that is coming home, arrives at the next turn start | `ARRIVE` (placement of every arrival), `HOME`, `RECALL` |
| S2 Expire CS unit | `scn_expire_cs` | your newest deployed City-State unit ends its service next turn, standing in the city-state's land | `EXPIRE` |
| S3 Grace/mutiny step | `scn_grace` | your newest Expeditionary unit, one phase per press: onto neutral land with its service ending, then 1 grace turn left, then back onto the host's land | `GRACE`, `MUTINY`, `MUTINY_RETURN` |
| S4 Lapse on/off | `scn_lapse` | ends your alliance with B (your Volunteers lapse, paused on valid land), or restores it | `LAPSE`, `LAPSE_PAUSE`, `LAPSE_RESTORE` |
| S5 Upgrade test | `scn_upgrade` | a Volunteer "VEF-UPGRADE" in your land whose upgrade is your civ's unique unit when there is one; tech, resource and gold granted. You click Upgrade | `UPGRADE` |
| S6 Veteran copies | `scn_vet` (+ `scn_vetb`, `scn_vetdone`) | three copies of the selected veteran: VEF-A (XP to the threshold, then SetPromotion), VEF-B (XP, then the game's PROMOTE command, sent by the panel), VEF-C (SetPromotion only, like the current restore) | `VET_A/B/C` (next-level XP), `VET_LEVEL_A/B/C` (UI level) |
| S7 Killed unit | `scn_kill` | a damaged Warrior "VEF-KILL" of a one-city city-state, tracked as your City-State unit; you at war with that city-state; 3 Tanks next to it | `KILLED` |
| S8 Relink guard | `scn_guard` | a tracked City-State Warrior removed without combat, with two identical Warriors of that city-state next to its tile | `GUARD` |
| S9 Crowded arrival | `scn_place` | rings 1 and 2 around B's capital full of B's Warriors, and your Swordsman arriving there next turn | `CROWDED` |
| S10 Mutiny combat | `scn_t31` | "VEF-T31", B's Expeditionary unit hosted by you, in mutiny on neutral land next to 2 Barbarian Warriors | `T31_EVENT` (at the fight), `T31` |
| S11 Entrust city | `scn_entrust` | 3 Tanks next to C's city nearest to you, B allied again | `ENTRUST` |
| Go to scenario | (UI) | moves the camera back to the current test and selects your test unit | |
| Check now | `scn_check` | runs the checks that don't need a new turn (S7, S11) | |

Notes:
- Check lines look like `[EFV][CHECK] <ID> <PASS|CHECK|INFO> T<turn> <detail>`. The checks run at your `GameEvents.PlayerTurnStartComplete`, after VEF's turn pipeline.
- Scenario state lives in the Game property `EFV_DEV_SCN`, so it survives save and load. Empty tables do not survive the property round trip, so the code re-creates them on use.
- Units the AI would otherwise move are held in place: FinishMoves now, plus a pending entry in VEF's own list (`EFV_Records.AddPending`), so VEF repeats FinishMoves at that player's next turn start.
- After a scenario button the panel moves the camera to the test once gameplay has answered (matched by a request stamp).
- No gameplay call to upgrade a unit is known, so S5 needs your click. The PROMOTE command exists only in the UI, so route B of S6 runs from the panel.
- The older test scripts built an `EFV_BASE` save by hand with the diplomacy buttons below. S0 does the same in one click.

## Panel fields

| Field | Meaning |
|---|---|
| Target `<` `>` | Target player: recipient, diplomacy partner, or owner for spawns. Starts at the first other living major. |
| Type | Unit, promotion or resource type (`UNIT_TANK`, `PROMOTION_BATTLECRY`, `RESOURCE_OIL`), or a force type for forged sends. |
| Amount | The number for the command. |
| Extra | `k=v;k=v` pairs copied into the request: `rec=<id>`, `a=<pid>`, `who=<pid>`, `owner=<pid>`, `field=`, `value=`. |
| Info lines | The selected unit and city. For a tracked unit, its VEF record (read with `EFV_UI_RecordForUnit` and `EFV_UI_StateText`). |

## Other commands

Every command logs `[EFV][T<turn>][Dev] <cmd>: ...` to `Lua.log`, and the panel logs `[EFV][Dev][UI] request ...`.

Units. These act on the selected unit. With Extra `rec=<id>` they act on that record's unit on the map instead (identity-checked), so you can also reach AI-owned Expeditionary units.

| Button | cmd | Effect |
|---|---|---|
| Spawn Type x Amt -> Tgt | `spawn` | creates Amount (default 1) units of Type (default `UNIT_SWORDSMAN`) for Target (or `owner=`) on the nearest free tile to the selection; naval types go on water |
| Fill rings (Amt) -> Tgt | `fill` | fills every empty land tile within Amount rings (default 5) of the selected city with Type (default `UNIT_WARRIOR`) |
| Damage = Amount / Heal | `damage` / `heal` | sets the damage to Amount / to 0 |
| XP + Amount | `xp` | adds experience (default 15) |
| Promote (Type) | `promote` | gives promotion Type, or the first one of the unit's class it lacks |
| Finish moves | `finish` | uses up the unit's moves (tests the "needs full movement points" reason) |
| Corps on/off (Amt 0) | `corps` | makes the unit a Corps; Amount 0 turns it back |
| Kill (Destroy) | `kill` | removes the unit |
| Place at tx,ty (extra) | `place` | moves the unit to Extra `tx=<x>;ty=<y>` (no stacking or terrain check) |
| Unit info (G) | `unit` | logs damage, XP, promotions, moves, formation, tile owner and the VEF record |

Economy (you, or Extra `who=<pid>`): Gold + Amount, Set gold = Amount, Resource + Amount, Set resource = Amt (resource Type, default `RESOURCE_OIL`).

Diplomacy (you, or Extra `a=<pid>`, with Target):

| Button | cmd | Effect |
|---|---|---|
| Ally (Amt 0 = end) | `ally` | alliance both ways; Amount 0 ends it. It does not end a war: make peace first |
| Friend (Amt 0 = end) | `friend` | declared friendship both ways; Amount 0 ends it |
| War | `war` | formal war |
| Peace (try) | `peace` | there is no known peace call; this only reports the war state. Make peace in the diplomacy screen |
| Meet | `meet` | both players meet |
| Diplo matrix | `diplo` | logs war / alliance / friendship / open borders / met / team for every pair |

VEF records (the selected unit's record, Extra `rec=<id>`, or the only record):

| Button | cmd | Effect |
|---|---|---|
| Dump | `dump` | logs the whole store (`[Dump]` lines; compare before and after a reload) |
| List records | `records` | one line per record |
| Shift clock by Amt | `shift` | Deployed, Grace or Mutiny: `deployedTurn -= N`. Outbound or Returning: `arrivalTurn -= N` |
| Expire next turn | `expire` | the service ends at the next turn start (Expeditionary and City-State only) |
| Set field (extra) | `setfield` | sets `field=<name>;value=<v>` (`value=nil` clears it) |
| VEF properties | `state` | logs the store's Game properties |
| UI store (UI) | (UI) | logs the store as the UI sees it |

Forged requests go straight to VEF and skip its UI checks, to test the gameplay side:

| Button | Request |
|---|---|
| EFV_Send sel. unit | `EFV_Send` for the selected unit to Target's selected city, else Target's city nearest the unit. Type = force type (default Expeditionary), Amount = expected fee (default 99999) |
| EFV_Recall sel. unit | `EFV_Recall` for the selected unit |
| EFV_Entrust sel. city | `EFV_Entrust` for the selected city to Target |

## Offline tests

`tests/offline/test_dev_mod.lua` runs this mod in the offline fake engine: every command, every final-session scenario and its check line, and the panel (hidden start, hotkey, flat parameters, forged requests, scenario buttons, camera focus). Run it with `python tests/offline/run_tests.py -k dev`.
