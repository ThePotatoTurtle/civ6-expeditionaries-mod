# VEF Dev Tools (EFV_Dev)

A separate mod with a developer panel for testing Volunteers & Expeditionary Forces (VEF) in game. It needs Gathering Storm and VEF (mod id `fcc83bd7-1abf-4d9a-bddb-01633574bf40`). Its own id is `94ec021d-9956-4a30-b9c1-5ccf136679bf`.

Version 1.0.3.1, made for VEF 1.0.3. Never enable it in a real game.

The internal prefix of the project is `EFV_`, so files, Lua names and log tags use that. Players only ever see "VEF".

## Files

| File | Context | What it does |
|---|---|---|
| `EFV_Dev.modinfo` | | Gameplay script and UI context (InGame), load order 14000, Gathering Storm only |
| `Scripts/EFV_Dev_Gameplay.lua` | gameplay | handles `GameEvents.EFV_Dev(playerID, params)` by `params.cmd`, plus the test-session checks and the Screenshot scenes |
| `UI/EFV_Dev_Panel.xml/.lua` | UI | the panel; sends flat `EXECUTE_SCRIPT` requests |

The gameplay script changes VEF state only through VEF's own record API (`EFV_Records`: `Load`, `Get`, `FindByUnit`, `New`, `Touch`, `Commit`, `AddPending`, `Delete`, `Dump`) and `EFV_Units` (`Snapshot`, `ApplySnapshot`, `Remove`, `GetForRecord`). Everything goes through the Game properties, as INTERFACES.md sections 3.4 and 5 describe. The script runs in its own Lua state and includes VEF's modules itself. They keep no state of their own, so VEF sees every change on its next handler call.

## Install and open

1. Close the game, then run `powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Dev -Watch`. It copies `EFV\` and `EFV_Dev\` into the Mods folder and follows `Lua.log`.
2. In Additional Content enable Gathering Storm, Volunteers & Expeditionary Forces and VEF Dev Tools. Leave the old EFV Spike Test mod off: it also answers `EXECUTE_SCRIPT` requests.
3. Open the panel with Ctrl+Shift+D or the DEV button on the launch bar. Esc or Close hides it. The context loads hidden (INTERFACES note 19), so `Initialize` shows it and only toggles `Main`.

## Screenshots

The five buttons at the top of the panel build the scenes for the Steam Workshop pictures (plan and captions: `workshop/SCREENSHOTS.md`). Start a new game with at least 5 civs and 3 city-states, found your capital, End Turn once, then press any Shot button, in any order and as often as you like. Each one runs S0 itself if needed, removes what the previous Shot built, deselects your units and clears VEF's notifications, builds its scene, moves and zooms the camera, then closes the panel and hides the DEV button (Ctrl+Shift+D brings both back).

| Button | cmd | Scene | Opened for you |
|---|---|---|---|
| Shot 1 Send picker | `shot1` | "Legio VEF" (Swordsman, full moves) next to your capital; B and F get a second city if they have one only; the next major becomes your friend without a common enemy, so its row is greyed | the Expeditionary destination list |
| Shot 2 Arrival | `shot2` | your Expeditionary Swordsman (B's colours) and your Volunteer Swordsman (yours) next to B's capital, both just arrived, two "Unit Arrived" notifications | |
| Shot 3 Tracker | `shot3` | six records: Grace (red, first), Deployed with F, Volunteers, a City-State unit Returning, an Outbound unit, one received from B; one Grace notification and the red banner | the VEF tracker (`LuaEvents.EFV_TrackerOpen`) |
| Shot 4 Entrust | `shot4` | the S11 scene: a city of C at 1 HP with its walls down and three Tanks next to it | Tank 1 attacks the city; once the capture screen shows, the Entrust list is expanded (`LuaEvents.EFV_EntrustExpand`) |
| Shot 5 Mutiny | `shot5` | your Expeditionary Swordsman (B's) in mutiny with 40 damage on neutral land near B's border, one Mutiny notification | |

Each Shot writes one `[EFV][CHECK] SHOTn PASS|CHECK` line with what it built. Four things are not proven in game yet, so each has a fallback: the map zoom (`UI.SetMapZoom`; if it fails, zoom with the mouse wheel), the Tank attack from the panel (if it is refused, click the city with the selected Tank), whether the destination list leaves the unit panel visible (if not, take one picture with the list and one after Esc while hovering "Send as Expeditionary"), and the flag tags on units created by script (the panel looks at the scene again after 1 second; if a tag is still missing, press the Shot button again).

## Test session buttons

These sit under "Test sessions", below the Screenshot buttons. Each one sets up a whole test situation in one click. `EFV/TESTING_RETEST_0.7.md` (the short 0.7 re-test) and `EFV/TESTING_FINAL.md` (the full session, written for 0.6.1, so its City-State and veteran steps predate the 0.7 rules) walk through them in order, and `tools/summarize_efv_log.py` (with `--retest` for the short one) reads the results from `Lua.log` afterwards.

**Start the session from a brand-new game** (any map, Standard speed, at least 5 civs and 3 city-states; found your capital, End Turn once, press S0). Never from an old save: a Civ VI save locks the mod set it was made with, so the old `EFV_BASE` save (made with the spike harness) turns the EFV Spike Test mod back on and VEF and VEF Dev Tools off. If the old spike panel shows up, or there is no DEV button, that is what happened. After S0 the panel's first line names B, F, C and CS, and the Target is set to B.

| Button | cmd | What it sets up | Check line at your next turn |
|---|---|---|---|
| S0 Setup session | `scn_setup` | from a new game: B, F, C = the three lowest-ID other majors with a city, CS = the lowest-ID city-state with a city. You meet them (and they meet each other), the land within 3 tiles of their cities is revealed to you, you, B and F declare war on C (the city-state stays at peace: since VEF 1.0.2 a City-State send needs no shared enemy), B becomes your declared friend and grants you open borders (VEF basis FRIEND for Expeditionary / Entrust, FRIEND_OB for Volunteers), F your friend; 2000 gold, 10 Iron, 3 Swordsmen with full moves next to your capital. The check asks VEF's own send rule (`EFV_EvaluateSend`) about B's capital and the city-state. Without a capital, or with fewer than 3 civs and 1 city-state with a city, it changes nothing and says what to do | `SETUP` (right away) |
| S1 Arrive next turn | `scn_arrive` | every unit you sent, or that is coming home, arrives at the next turn start | `ARRIVE` (placement of every arrival), `HOME`, `RECALL` |
| S2 Expire CS unit (off its land) | `scn_expire_cs` | your newest deployed City-State unit is moved onto free neutral land within 6 tiles (else onto land owned by neither the city-state nor you) and ends its service next turn. Since 0.7 it must start home at once, wherever it is, with no grace | `EXPIRE` (CHECK if it went into grace) |
| S3 Grace/mutiny step | `scn_grace` | your newest Expeditionary unit, one phase per press: onto neutral land with its service ending, then 1 grace turn left, then back onto the host's land | `GRACE`, `MUTINY`, `MUTINY_RETURN` |
| S4 Lapse on/off | `scn_lapse` | ends your friendship with B (your Volunteers lapse, paused on valid land), or restores it (and B's open borders if needed). It does not touch B's open-borders deal. At the next turn start the lapsed Volunteer is held in place for that turn (no moves), because the pause only holds on B's land or yours; if it still ends up elsewhere, `LAPSE_PAUSE` says "not verified" | `LAPSE`, `LAPSE_PAUSE`, `LAPSE_RESTORE` |
| S5 Upgrade test | `scn_upgrade` | a Volunteer "VEF-UPGRADE" in your land whose upgrade is your civ's unique unit when there is one; the target's tech and civic, its resource and gold granted (works in a new game). You click Upgrade | `UPGRADE` |
| S6 Veteran copies | `scn_vet` (+ `scn_vetb`, `scn_vetdone`) | three copies of the selected veteran: VEF-A (XP to the threshold, then SetPromotion), VEF-B (XP, then the game's PROMOTE command, sent by the panel), VEF-C (SetPromotion only, like the restore VEF still uses for AI owners) | `VET_A/B/C` (next-level XP), `VET_LEVEL_A/B/C` (UI level) |
| S7 Killed unit | `scn_kill` | a damaged Warrior "VEF-KILL" of a one-city city-state (not CS), tracked as your City-State unit; you meet and are at war with that city-state; its city revealed, walls down and 1 HP left; 3 Tanks next to it | `KILLED` |
| S8 Relink guard | `scn_guard` | a tracked City-State Warrior removed without combat, with two identical Warriors of that city-state next to its tile | `GUARD` |
| S9 Crowded arrival | `scn_place` | one of B's Warriors on every free land tile of rings 1 and 2 around B's capital (water, impassable and occupied tiles are skipped), and your Swordsman arriving there next turn. The INFO line says which ring VEF's spawn search expects. PASS when the unit stands on the nearest ring that had a valid free tile (ring 2 is fine if one tile there was left), never on a city centre or closed or war land, alone on its tile | `CROWDED` |
| S10 Mutiny combat | `scn_t31` | a Spearman (no custom name since 0.7), B's Expeditionary unit hosted by you, in mutiny on neutral land next to 2 Barbarian Warriors; the camera selects it. Once it has fought, the Barbarians are removed as soon as you end the turn, before they can attack (in the 0.7 re-test their two hits plus the mutiny damage killed it before the check). The Spearman is removed when you end the turn of the verdict, never at the start of your turn (removing a selected unit then broke `SelectedUnit.lua:195`) | `T31_EVENT` (at the fight), `T31` |
| S11 Entrust city | `scn_entrust` | a city of C that is not its last one: C's nearest non-capital city, else a small new city founded for C 5-10 tiles from your capital (so taking it does not eliminate C), else C's capital. Revealed, walls down, 1 HP left, 3 Tanks next to it; your partner basis with B renewed if it is off | `ENTRUST` |
| S12 Veteran return | `scn_vetret` | a Volunteer record of yours coming home from B next turn: "VEF-VET", a Warrior at level 3 with two level-1 promotions, 50/90 XP and 30 damage. VEF recreates it and your UI takes the promotions back with the game's PROMOTE command. The panel then checks the UI level (it must be back in the arrival turn) and presses Check now. If it comes back later, the damage may be 15 lower per extra turn: that is the normal heal in your land | `VET_RESTORE`, `VET_RESTORE_LEVEL` (UI) |
| S13 Unit in B's land | `scn_inland` | a Spearman of yours with full moves on a free tile of B within 3 tiles of B's capital, selected. The first check asks VEF's own picker rule right away (B's rows open, every other row `WRONG_TERRITORY`); send it to B the same turn | `FROM_LAND_RULES` (right away), `FROM_LAND` |
| S14 Mutiny death | `scn_mutdeath` | two Swordsmen of yours, lent to F as Volunteers, in mutiny with 80 damage on neutral land next to F's land, each next to two Barbarian Warriors, plus an enemy Warrior of C nearby. Leave copy 1 (no moves) for the Barbarians and attack with copy 2 (selected). Every unit ID is logged. At the next turn start each copy must be closed and gone, with no unit of yours and no VEF record on its tile. `EFV/TESTING_S14.md` walks through it (`--s14`) | `MUT_DEATH` |
| S15 Receive forces | `scn_receive` | B sends to you, both already deployed next to your capital: an Expeditionary Swordsman you now control (20 turns) and a Volunteer Swordsman B keeps in your land. Gives B open borders from you first if B has no Volunteer basis. Runs S0 if needed, removes the previous Shot or S15 scene and opens the VEF tracker | `RECEIVE` |
| S16 Break transit | `scn_cancel` | your newest unit on its way: a city-state destination is handed to C (its only city: the city-state is eliminated); a major destination: your friendship with it ends (an alliance too, if the game lets it) and a Warrior of yours "VEF-BLOCK" blocks the unit's start tile. At your next turn the unit must be back within 5 tiles of its start tile: ring 0 when not blocked, ring 1 when blocked, 0 moves. Nothing on its way: CHECK "send a unit first" | `CANCEL_PREP` (right away), `CANCEL` |
| T1 Volunteer partners | `elig_t1` | see "Eligibility tests" below | `ELIG_T1`, `ELIG_T1_UI` (right away) |
| T2 Shared enemy | `elig_t2` | see "Eligibility tests" below | `ELIG_T2`, `ELIG_T2_UI` (right away) |
| Go to scenario | (UI) | moves the camera back to the current test and selects your test unit | |
| Check now | `scn_check` | runs the checks that don't need a new turn (S7, S11, S12, S13) | |

Notes:
- Check lines look like `[EFV][CHECK] <ID> <PASS|CHECK|FAIL|INFO> T<turn> <detail>` (FAIL: `MUT_DEATH`, `BADGE_AUDIT`). The checks run at your `GameEvents.PlayerTurnStartComplete`, after VEF's turn pipeline.
- Scenario state lives in the Game property `EFV_DEV_SCN`, so it survives save and load. Empty tables do not survive the property round trip, so the code re-creates them on use.
- Units the AI would otherwise move are held in place: FinishMoves now, plus a pending entry in VEF's own list (`EFV_Records.AddPending`), so VEF repeats FinishMoves at that player's next turn start.
- After a scenario button the panel moves the camera to the test once gameplay has answered (matched by a request stamp).
- No gameplay call to upgrade a unit is known, so S5 needs your click. The PROMOTE command exists only in the UI, so route B of S6 runs from the panel.
- `BADGE_AUDIT` (UI, always on, 0.7.2-dev.1): at each of your turn starts and shortly after a unit is added, removed or killed, the panel asks VEF's flag wrapper for every flag that shows a VEF tag and checks that each sits on the live unit (owner, ID and type) of an on-map record, and counts the tracker's rows whose unit is gone. It logs PASS at every turn start, and otherwise only when the result changes or fails. Every summary mode prints it as "Badge audit".
- `LAPSE_TEXT` (UI): the first time one of your Volunteers has a paused lapse in grace, the panel checks that the tracker reads "Lapse: Grace N (paused)" in full.
- The older test scripts built an `EFV_BASE` save by hand. That save is retired (it locks the spike harness mod set); S0 builds everything from a new game.

Why friendship and not an alliance: alliances need Civil Service (nobody has it at turn 1), and Session F T27 showed that `SetHasAllied(false)` is a no-op in game, so S4 could never end one. S0 uses the alliance flag only as the last resort, when friendship plus open borders give no Volunteer basis (the SETUP line then shows basis ALLIANCE, and S4's LAPSE line says CHECK if it cannot end it).

Game calls S0, S5, S7 and S11 add for a new game (all pcall-guarded, EFV_Dev only; evidence in `tools/api_allowlist_extra.json`):

| What | Call | Evidence |
|---|---|---|
| meet | `GetDiplomacy():SetHasMet(p)` both ways | AlexanderScenario.lua:13-15, ColdWarScenario_StartScript.lua:36 |
| reveal | `PlayersVisibility[p]:ChangeVisibilityCount(plotIndex, 1)` for every plot within 3 tiles of a city. If the city still is not revealed, a Scout "VEF-SCOUT" of yours is placed within 2 tiles of it | AlexanderScenario.lua:59, AustraliaScenario.lua:1273 (gameplay), Debug/Map.ltp "Reveal All" |
| open borders | Early Empire for you and B (`GetCulture():SetCivic`), then a one-way scripted deal: working deal, `AddItemOfType(AGREEMENTS, B)`, `SetSubType(OPEN_BORDERS)`, `SetDuration(30)`, `SetLocked`, `Validate`, `EnactWorkingDeal` | IndonesiaKhmerScenario.lua:31; Debug/Diplomacy.ltp:115-127; Session F T27 PASS (F:L1080-L1082) |
| friendship, war | `SetHasDeclaredFriendship`, `DeclareWarOn(FORMAL_WAR)` | Session F T27 PASS |
| alliance (T1, T2) | Civil Service for both (`GetCulture():SetCivic`), then `SetHasAllied(p, true)` both ways, after the friendship | Session E 6 (the flag takes and does not end a war); whether the UI sees it is what the `ELIG_*_UI` lines show |
| tech, civic (S5) | `GetTechs():SetTech(idx, true)`, `GetCulture():SetCivic(idx, true)` | AustraliaScenario.lua:1368, VikingScenario.lua:38 |
| city HP (S7, S11) | `CityManager.GetDistrictAt(x, y)`, `SetDamage(DefenseTypes.DISTRICT_OUTER, max)`, `SetDamage(DefenseTypes.DISTRICT_GARRISON, max - 1)` | BlackDeathScenario.lua:437, PiratesScenario_StartScript.lua:1342-1369 |
| new city (S11) | `GetCities():Create(x, y)` | AustraliaScenario.lua:1163, 1346 |
| full moves | `UnitManager.RestoreMovementToFormation(u)`, only if a created Swordsman lacks moves | BlackDeathScenario_UnitCommands.lua:281 (LIKELY) |

## Eligibility tests (T1, T2)

Two buttons in the test group check who shows up in the Send picker, and how, after the 1.0.1 common-war fix (only real wars against a major civ or a city-state count; the Free Cities and the barbarians never do). T2 also checks the City-State list against the 1.0.2 rule: any city-state you have met, with no shared enemy needed, unless you are at war with it. Use a new game for each button (written for a Large map with 8 civs and city-states), found your capital, then press the button. Don't combine them with S0, the Shot buttons or each other in one game: wars can't be undone, and the peace cooldown is 10 turns.

Both buttons make every major civ and city-state meet every other one, so the diplomacy screen shows all relations. They reveal the cities of the civs involved, top your gold up to 2000 and your Iron to 10, and put 2 Swordsmen with full moves next to your capital (the first one selected). A second press replaces the Swordsmen, unless you already sent one. Roles go to the other majors with a city in player ID order. Majors left over get the role OTHER (met only, expected absent). With fewer civs than roles, the last roles are skipped and the summary says which ones.

The check asks VEF's own `EFV_DestinationRows` for the Expeditionary list (Swordsman 1) and the Volunteer list (Swordsman 2). Each civ comes out as ALLOWED (an open row), GREY with its eligibility reasons, or ABSENT (no row). Gameplay logs one `ELIG_T1` / `ELIG_T2` line per civ with the gameplay rules. About a second later the panel runs the same check with the UI rules the real picker uses and logs `ELIG_T1_UI` / `ELIG_T2_UI`, adding the UI's partner and Volunteer basis. Each line has the role, the facts (at war with E, real wars, ally, friend, open borders to you, at war with you), expected and actual for both force types, and a verdict. A summary line comes last.

- PASS: the picker matches the rule.
- FAIL: the picker disagrees with the rule (a VEF problem).
- CHECK: the setup didn't come out as planned, so the line says nothing about VEF. `SETUP:` says what went wrong. If the engine pulled an ally into your war, it reads "ENGINE EFFECT, not a VEF failure". An expected open row that is greyed only by other reasons (not revealed, gold, the unit) is also CHECK.

The panel's first line shows the role map (for example `T2: E=Gaul, FW=Japan, FOW=England, ...`). The second line shows a short result: `T2: gameplay 10/10 PASS, UI 10/10 PASS` (7 civs and 3 city-states).

T1 Volunteer partners (every partner shares the war with E, only the basis changes):

| Role | Setup | Expeditionary | Volunteers |
|---|---|---|---|
| E | you declare war on E | absent | absent |
| A | your ally (Civil Service granted to both), at war with E | allowed | allowed |
| F | declared friend, no open borders, at war with E | allowed | greyed, needs open borders |
| FO | declared friend, grants you open borders, at war with E | allowed | allowed |
| N | met only, at war with E | absent | absent |

T2 Shared enemy (with and without the shared war; needs 7 AI civs):

| Role | Setup | Expeditionary | Volunteers |
|---|---|---|---|
| E | at war with you | absent | absent |
| FW | declared friend, at war with E | allowed | greyed, needs open borders |
| FOW | declared friend, grants you open borders, at war with E | allowed | allowed |
| FN | declared friend, at war with nobody | greyed, no common enemy | greyed, no common enemy + needs open borders |
| FON | declared friend, grants you open borders, at war with nobody | greyed, no common enemy | greyed, no common enemy |
| NW | met only, at war with E | absent | absent |
| AN | your ally, at war with nobody | greyed, no common enemy | greyed, no common enemy |

T2 also gives the city-states with a city roles, in player ID order, and checks the City-State list (Swordsman 1). Each gets its own `ELIG_T2` / `ELIG_T2_UI` line with "City-State expected ... actual ...":

| Role | Setup | City-State |
|---|---|---|
| CSN | met, at war with nobody | allowed (no shared enemy needed) |
| CSX | met, you declare war on it | greyed, you are at war with it |
| CSO | any further city-state, met only | allowed |

The setup declares only the wars listed (you on E, you on CSX, then the "at war with E" roles on E), before any friendship or alliance, and never tries to make peace. Afterwards `python tools/summarize_efv_log.py --eligibility` prints the last run of each button, per rules, with one line per civ and city-state.

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

`tests/offline/test_dev_mod.lua` runs this mod in the offline fake engine: every command, every test-session scenario and its check line (S12 end to end with VEF's promotion context and the panel), every Shot scene from a fresh game and the panel's Shot steps, T1 and T2 with 7 AI civs, with 3 (skipped roles), without a capital and with an ally the engine pulls into your war, and the panel (hidden start, hotkey, flat parameters, forged requests, scenario buttons, camera focus, session line, Target set to B). The final-session tests start from a fake brand-new game (nobody met, nothing revealed, no diplomacy) and run S0 first; S0 is also tested without a capital, without the reveal call (Scout fallback) and with a refused open-borders deal (alliance fallback). Run it with `python tests/offline/run_tests.py -k dev`.
