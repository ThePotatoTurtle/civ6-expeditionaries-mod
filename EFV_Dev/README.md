# VEF Dev Tools (EFV_Dev)

A separate mod with a developer panel for testing Volunteers & Expeditionary Forces (VEF) in game. It needs Gathering Storm and VEF (mod id `fcc83bd7-1abf-4d9a-bddb-01633574bf40`). Its own id is `94ec021d-9956-4a30-b9c1-5ccf136679bf`.

Version 1.0.5.2, made for VEF 1.0.5. VEF Dev Tools is not on the Steam Workshop: install it from this folder (see "Install and open"). It needs no change to VEF. Never enable it in a real game.

The panel's title line names both versions, for example "VEF Dev 1.0.5.2 | VEF 1.0.5". It reads the VEF version from the VEF files the game really loaded, so it shows "WRONG VEF 1.0.4, needs 1.0.5" when the Workshop copy runs instead of the local one.

The internal prefix of the project is `EFV_`, so files, Lua names and log tags use that. Players only ever see "VEF".

## Files

| File | Context | What it does |
|---|---|---|
| `EFV_Dev.modinfo` | | Database rows, gameplay script and UI context (InGame), load order 14000, Gathering Storm only |
| `Data/EFV_Dev_Denounce.xml` | database | `DIPLOMACY_DENOUNCE_TIME_LIMIT` 3 instead of 30: every denouncement lasts 3 turns while the dev tools are on (VEF 1.0.5 test). Side effect: a formal war needs a denouncement 5 turns old, which a 3-turn one never reaches |
| `Data/EFV_Dev_Spike.xml` | database | two hidden unit abilities for the veteran spike (V button), granted only by the spike |
| `Scripts/EFV_Dev_Gameplay.lua` | gameplay | handles `GameEvents.EFV_Dev(playerID, params)` by `params.cmd`, plus the test-session checks and the Screenshot scenes |
| `UI/EFV_Dev_Panel.xml/.lua` | UI | the panel; sends flat `EXECUTE_SCRIPT` requests |

The gameplay script changes VEF state only through VEF's own record API (`EFV_Records`: `Load`, `IDs`, `Get`, `FindByUnit`, `New`, `Touch`, `Commit`, `AddPending`, `Delete`, `Dump`), `EFV_Units` (`Snapshot`, `ApplySnapshot`, `Remove`, `GetForRecord`) and `EFV_Notify` (`Queue`, `Flush`, for the notifications of the Shot scenes). It also asks VEF's rules (`EFV_EvaluateSend`, `EFV_DestinationRows`, `EFV_PartnerBasis`, `EFV_VolunteerBasis` and others) and `EFV_Spawn` (`Valid`, `DryRun`, `DomainOf`) for its checks. Everything goes through the Game properties, as INTERFACES.md sections 3.4 and 5 describe. The script runs in its own Lua state and includes VEF's modules itself. They keep no state of their own, so VEF sees every change on its next handler call.

## Install and open

1. Close the game. VEF 1.0.4 is on the Steam Workshop, so to test the released build stay subscribed and run `powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly`: it installs only the dev tools and warns if a local `Mods\EFV` is left over (delete it). To test a local VEF build that is not released yet, unsubscribe from VEF on the Workshop first, then run `install.ps1 -Dev`: it copies both `EFV\` and `EFV_Dev\` into the Mods folder and warns while the Workshop copy is still there. The local and the Workshop copy have the same mod id; with both present Additional Content can list VEF twice and it is unclear which one loads (`workshop/PUBLISHING.md` step 10; `Mods.sqlite` keeps one row per modinfo file, not per mod id). Afterwards `-Uninstall` removes `Mods\EFV` again (the dev tools stay) and you resubscribe. `-Watch` also follows `Lua.log`. The script refuses to run while the game is running.
2. In Additional Content enable Gathering Storm, Volunteers & Expeditionary Forces and VEF Dev Tools. VEF must be listed once, with the version under test in its name ("Volunteers & Expeditionary Forces v1.0.5"). Leave the old EFV Spike Test mod off: it also answers `EXECUTE_SCRIPT` requests.
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

These sit under "Test sessions", below the Screenshot buttons. Each one sets up a whole test situation in one click. `EFV/TESTING_1.0.5.md` (the VEF 1.0.5 session: P1 instead of S0, the P buttons and A9, see "VEF 1.0.5 test" below), `EFV/TESTING_1.0.4.md` (the VEF 1.0.4 session: S0, S20, S21, checked by eye, no log needed), `EFV/TESTING_1.0.3.md` (the VEF 1.0.3 session: S0, S17, S18, S19, S16 twice and the V spike), `EFV/TESTING_RETEST_0.7.md` (the short 0.7 re-test) and `EFV/TESTING_FINAL.md` (the full session, written for 0.6.1, so its City-State and veteran steps predate the 0.7 rules) walk through them in order, and `tools/summarize_efv_log.py` (`--v103` for the 1.0.3 session, `--retest` for the 0.7 one, no option for the full session) reads the results from `Lua.log` afterwards. The 1.0.4 session has no summary mode.

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
| S17 Tracker labels | `scn_labels` | four records in transit between you and F, without units, all arriving in 2 turns: F sends you an Expeditionary "VEF-IN" (Inbound), F's Volunteer "VEF-DEPARTED" goes home from you (Departed), your Expeditionary "VEF-OUT" goes to F (Outbound) and your Volunteer "VEF-RET" comes home (Returning). The panel opens the tracker and reads its rows with VEF's own `EFV_UI_TrackerRows`. The records are deleted when you end the turn; S16 and the HOME check skip them | `TRACKER_PREP` (right away), `TRACKER_LABELS` (UI, one line per row and a summary) |
| S18 Entrust city-state | `scn_entrust_cs` | a one-city city-state other than CS that B and F are at peace with: you meet it and declare war on it, its city is revealed, walls down, 1 HP, 3 Tanks next to it. Taking its only city eliminates it; Entrust must offer B (VEF 1.0.3: no at-war check for a city-state or an eliminated owner) | `ENTRUST_CS_UI` (at the capture), `ENTRUST_CS` (next turn: PASS when B or F owns it) |
| S19 Entrust major | `scn_entrust_major` | D = the 4th major (needs 5 civs): you meet it and declare war on it, B and F stay at peace with it. D's nearest non-capital city, else a small new city founded for D 5-10 tiles from your capital (never its last city), revealed, 1 HP, 3 Tanks. After the capture Entrust must read "Entrust (no eligible partner)": choose Keep | `ENTRUST_MAJOR_UI` (at the capture), `ENTRUST_MAJOR` (next turn: PASS when still yours, FAIL when a partner got it) |
| S20 War sends home | `scn_war_home` | VEF 1.0.4: two Expeditionary Swordsmen, deployed: "VEF-LENT", yours, lent to B and controlled by B next to B's capital (held until the next turn start), and "VEF-BORROWED", B's, lent to you next to your capital. Then your friendship with B ends (no war on a declared friend) and you declare war on B. At the end of the turn VEF sends both home: "Unit Coming Home" (tracker: Returning) and "Lent Unit Gone Home" (tracker: Departed). Once per game: a second press while at war with B changes nothing | `WAR_HOME` (INFO right away, no verdict) |
| S21 Veteran home | `scn_vet_home` | VEF 1.0.4: an Expeditionary record of yours coming home from F next turn: "VEF-VETERAN", a Swordsman at level 4 with Battlecry, Tortoise and Commando (the class's first two level-1 and first level-2 promotions), XP 100/150, no damage. VEF recreates it next to your capital and your UI takes all three promotions back in the arrival turn (one-turn restore); it ends that turn with 0 moves. F is the partner, so S20's war with B does not touch it | `VET_HOME` (INFO right away, no verdict) |
| V Veteran spike | `vs_start` (+ `vs_sync`, `vs_off`) | see "Veteran spike" below | `VSPIKE` (gameplay), `VSPIKE_UI`, `VSPIKE_V0` to `VSPIKE_V3`, `VSPIKE_V1_OFF` (UI) |
| T1 Volunteer partners | `elig_t1` | see "Eligibility tests" below | `ELIG_T1`, `ELIG_T1_UI` (right away) |
| T2 Shared enemy | `elig_t2` | see "Eligibility tests" below | `ELIG_T2`, `ELIG_T2_UI` (right away) |
| Go to scenario | (UI) | moves the camera back to the current test and selects your test unit | |
| Check now | `scn_check` | runs the checks that don't need a new turn (S7, S11, S12, S13, S18, S19) | |
| D Setup | `denounce_setup` | see "Denounce spike" below | `DENOUNCE_SETUP` (right away) |
| D Denounce probe | `denounce_probe` | see "Denounce spike" below | `[EFV][Probe]` lines (right away, no verdict) |
| A1 to A5, A Status | `air_city`, `air_host`, `air_fuel`, `air_ally`, `air_carrier`, `air_status` | see "Air-unit spike" below | `AIR_A1` to `AIR_A5`, `AIR_STATUS` (right away, INFO), `AIR_TURN` (your next 4 turn starts), `[EFV][Air]` lines |
| C1 to C9, C Status | `corps_probe`, `corps_give`, `corps_merge`, `corps_cs_ai`, `corps_cs_force`, `corps_host`, `corps_trip`, `corps_split`, `corps_vol`, `corps_status` | see "Corps spike" below | `CORPS_C1` to `CORPS_C9`, `CORPS_STATUS` (right away, INFO), `CORPS_WATCH` (your next 6 turn starts), `[EFV][Corps]` lines |
| C10 Merge guard | (UI) | see "Corps spike" below | `[EFV][Corps] UI guard` lines |

Notes:
- Check lines look like `[EFV][CHECK] <ID> <PASS|CHECK|FAIL|INFO> T<turn> <detail>` (FAIL: `MUT_DEATH`, `BADGE_AUDIT`, `TRACKER_LABELS`, `ENTRUST_CS_UI`, `ENTRUST_MAJOR_UI`, `ENTRUST_MAJOR`). The checks run at your `GameEvents.PlayerTurnStartComplete`, after VEF's turn pipeline; the `_UI` checks, `TRACKER_LABELS` and the spike verdicts come from the panel.
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

## Veteran spike (V button)

The 1.0.3 experiment behind the VEF 1.0.4 one-turn restore (DECISIONS "Veteran restore in one turn": V2 adopted). The button stays for reference; the 1.0.4 session uses S21 instead. Can a returning veteran of a human player get all its promotions back in one turn? In 1.0.3 (route B) VEF raises the XP and your UI sends the game's PROMOTE command, one promotion per turn, because a promotion ends the unit's turn (no moves left, so PROMOTE is not offered). The V button makes four copies of one template next to your capital, VEF-V0 to VEF-V3, and restores each in its own way. The template is your selected land unit with promotions (its type, promotions and XP), else a Warrior with Battlecry, Tortoise and Commando and 90 XP. Play a civ other than Gran Colombia: its trait keeps a unit's moves after every promotion (the button logs a CHECK line if you do).

| Copy | Technique | Pass criterion | In game (2026-10-05) |
|---|---|---|---|
| V0 | control: route B as in VEF 1.0.3 (XP to the threshold, PROMOTE from the panel, gameplay sync) | `VSPIKE_V0` PASS: 1 promotion in the first turn, then PROMOTE is not offered. INFO when all are back (about 3 turns) | one promotion per turn, the 1.0.3 behaviour |
| V1 | hidden ability `EFV_DEV_ABILITY_PROMOTE_KEEP_MOVES` (COLLECTION_OWNER + `EFFECT_ADJUST_UNIT_PROMOTE_NO_FINISH_MOVES`, NoFinishMoves = true), granted with `GetAbility():ChangeAbilityCount(type, 1)`; the panel chains PROMOTE; then the ability is removed and one more normal promotion must end the turn | `VSPIKE_V1` PASS: all in the first turn, level 1 + n. `VSPIKE_V1_OFF` PASS: moves 0 after that promotion | V1 PASS (3 of 3 in the first turn), but V1_OFF CHECK: 2 moves left after removing the ability, so the effect can stay on the unit. Rejected |
| V2 | no database change: after each landed promotion gameplay refills the moves with `unit:ChangeMovesRemaining(max - remaining)`, then the panel sends the next PROMOTE | `VSPIKE_V2` PASS: all in the first turn, level 1 + n | PASS: 3 of 3 in the first turn, level 4. Adopted in VEF 1.0.4 |
| V3 | hidden ability `EFV_DEV_ABILITY_VET_LEVEL` (`MODIFIER_PLAYER_UNIT_ADJUST_EXPERIENCE_LEVEL`, Amount 3, the Giant Death Robot pattern), then `SetPromotion` for each promotion and the XP | `VSPIKE_V3`: level, XP and next-level XP, and whether PROMOTE is offered. PASS only if the level is 1 + n with the XP kept and no pending promotion | PASS: level 4, XP 90/150, no PROMOTE offered. Kept for later (FUTURE.md F2) |

Gameplay logs `VSPIKE INFO` lines (moves, XP and next-level XP, CanPromote, HP, promotions, ability counts) at every step and at each of your next 3 turn starts; the panel logs `VSPIKE_UI INFO` lines (UI level, moves, XP, PROMOTE offered, HP, promotions). The panel keeps its runner in memory only: after a reload V0 stops, the gameplay lines go on. `summarize_efv_log.py --v103` lists the spike results as findings. API evidence: `GetAbility():ChangeAbilityCount` / `GetAbilityCount` (PiratesScenario_UnitCommands.lua:661-662, CivRoyaleScenario_UnitCommands.lua:53-54, PiratesScenario_StartScript.lua:1516-1518), `ChangeMovesRemaining` with `GetMaxMoves` (PiratesScenario_UnitCommands.lua:665-666), PROMOTE (UnitPromotionPopup.lua:70-72, 81-82), all in `tools/api_allowlist_extra.json`.

## Denounce spike (D buttons)

The spike behind the proxy-war idea for Expeditionary Forces (`FIXPLAN_proxy_war.md`, FUTURE.md F4): can gameplay Lua, the synced side that would enforce the rule, read a denouncement? So far only UI readers are known. Both buttons are read only, except that D Setup meets a civ and reveals its capital. The by-eye script is session 1 of `EFV/TESTING_SPIKES.md`, together with the air-unit spike. The buttons sit in their own group below the test sessions.

- **D Setup** (`denounce_setup`) picks the lowest-ID major civ you could denounce: alive, with a city, not on your team, not at war with you, not allied and not a declared friend (so never S0's B, F or C). You meet it and its capital is revealed. The panel moves the camera there, sets the Target to it and says "D Setup: denounce <civ>". There is no script call for a denouncement, so you denounce it yourself in the diplomacy screen. With nobody eligible it logs `DENOUNCE_SETUP CHECK` and changes nothing.
- **D Denounce probe** (`denounce_probe`) reads every pair of you and a major civ you have met, in both directions, first in gameplay (the synced `EXECUTE_SCRIPT` handler), then the same reads in the panel (UI). Each method is looked up by name, so a missing one is logged as `MISSING` and a failing one as `ERROR`; nothing throws. One line per reader and direction, for example `[EFV][Probe] G GetDenounceTurn(0->3)=12` or `[EFV][Probe] UI DiploAI:GetDiplomaticStateIndex(3->0)=5 (number; index DIPLO_STATE_DENOUNCED)`. A `has` line per reader says whether the method exists at all, and a `compare` line per reader puts G and UI side by side.

| Short | Reader (`Players[a]` ... `(b)`) | Source |
|---|---|---|
| Turn | `:GetDiplomacy():GetDenounceTurn(b)` | DiplomacyActionView.lua:1486-1487 (UI) |
| IsDen, HasDen | `:GetDiplomacy():IsDenouncing(b)`, `:HasDenounced(b)` | guessed names, not in the game files |
| AiState | `:GetAi_Diplomacy():GetDiplomaticState(b)`: raw value, its type, and its name by index and by hash | Debug/Diplomacy.ltp:260 (GameCore tuner) |
| StateIdx | `:GetDiplomaticAI():GetDiplomaticStateIndex(b)`, named through `GameInfo.DiplomaticStates` | DiplomacyActionView.lua:1473, 1483 (UI) |
| AiMods, AIMods | `:GetAi_Diplomacy():GetDiplomaticModifiers(b)` / `:GetDiplomaticAI():GetDiplomaticModifiers(b)`: the count and any modifier that mentions a denouncement | Debug/Diplomacy.ltp:293, DiplomacyActionView.lua:895 (UI) |
| limit | `Game.GetGameDiplomacy():GetDenounceTimeLimit()`, once | DiplomacyActionView.lua:1500 (UI) |

Since EFV_Dev 1.0.5.1 every denouncement lasts 3 turns while the dev tools are on (`Data/EFV_Dev_Denounce.xml`), so the limit reads 3 in the UI. The spike's verdict (SPIKES.md 8.1): `AiState` is the gameplay reader, `StateIdx` the UI one; VEF 1.0.5 uses both (PLAN Appendix A A64, U20).

The status line shows three lines: the head (turn, number of civs, the limit in G and UI, whether G and UI agree), then `G:` and `UI:` with each reader's state (`ok`, `nil` = missing, `err`, `mixed`) and its hits, the pairs it reads as denounced (`0>3`, with the turn for Turn; `-` for none). A hit is a turn of 0 or more, `true`, a state named `DIPLO_STATE_DENOUNCED`, or a modifier about a denouncement. Gameplay hands its result to the panel in the dev tools' own Game property `EFV_DEV_SCN` (`dprobe`) and writes nothing else. The calls are looked up by name, so `api_audit` does not see them and they are not in `tools/api_allowlist_extra.json`; a reader the spike confirms gets an entry with the in-game evidence when the feature is built.

## VEF 1.0.5 test (P buttons, A9)

The by-eye script is `EFV/TESTING_1.0.5.md`. Start a new game and press P1 instead of S0: the test needs you at peace with everyone. The buttons sit in their own group right after the test sessions. Each one sends a stamped request; once gameplay answered (`EFV_DEV_SCN` `proxy.ans`, player IDs only, no translated names) the camera goes to the scene and the status line shows gameplay's text, then `UI:` with B, E and X by name, each pair's state as the UI reads it (U20), who denounced on which turn (UI `GetDenounceTurn`, both ways), the turns left (`EFV_UI_DenounceTurnsLeft`, the base game's own count) and the engine's denounce limit (UI `GetDenounceTimeLimit`). The first info line reads "Proxy test: B=... E=... X=...".

| Button | cmd | What it sets up |
|---|---|---|
| P1 Proxy war setup | `scn_proxy` | Instead of S0. Refused (CHECK, nothing changes) after S0, after an earlier P1, while you are at war with any civ or city-state, without a capital, or with fewer than 3 other civs with a city. B = the lowest-ID civ whose capital is a 2-turn trip from yours (else 3, else 4, else 1), your declared friend with open borders from B; E and X = the two lowest-ID other civs with a city, both at war with B. Everyone meets everyone, B's cities and E's and X's capitals are revealed, 2000 gold and three Swordsmen VEF-PROXY-1 to -3 with full moves next to your capital. The answer gives the trip, the fee, VEF's send rule to B for Expeditionary and Volunteers (both NO_COMMON_WAR) and the denounce limit in the game data |
| P2 X denounces you | (panel) | `DiplomacyManager.RequestSession(X, you, "DENOUNCE")`, the base game's call with an AI as the first argument (`DiplomacyActionView.lua:469` passes the local player: whether the engine takes another initiator is the test), then P Status after 1 s. The verdict comes first: "X denounced you on turn T", "WRONG WAY: the game made you denounce X" or "nothing happened: press P3" |
| P3 X dislikes you (if P2 fails) | `proxy_lower` | X's (or, when X is already in a denouncement with you, E's) opinion of you set to -30 with the tuner's `AdjustBaseDiplomacy` (`Debug/Diplomacy.ltp:19-33`, read with `GetDiplomaticScore`, :260): inside the UNFRIENDLY to DENOUNCED window, above the war threshold (`DiplomaticActions.xml:239-242`). End Turn 2 to 4 times until it denounces you |
| P4 Hold the unit on its way | `proxy_hold` | your newest outbound record arrives 8 turns from now (trip, band and fee untouched), so the denouncement runs out first |
| P5 Poor host (press twice) | `proxy_poor` | press 1: a Modern Anti-Tank VEF-UPKEEP (8 gold upkeep, no strategic resource) next to your capital, selected; send it to B as Expeditionary. Press 2: it arrives next turn and B's gold is set to 0 (without the send: CHECK) |
| P Status | `proxy_status` | the pair states as gameplay reads them (A64), the wars of B and of you with E and X, VEF's send rule to B (with the proxy-war enemies), B's gold and your records |
| A9 Carrier for a rebase (press twice) | `air_rebase` | press 1: a Carrier VEF-CV9 on your own water within 3 tiles of your capital and a Fighter VEF-AIR-9 on free water 2 or 3 tiles from it (never its tile; else land, noted), VEF's send rule for the carrier (no CARRIER_LOADED yet), the plane selected. Rebase VEF-AIR-9 onto VEF-CV9 by hand, then press again: the carrier's tile and both units are probed and the send rule should say CARRIER_LOADED; the `UI:` part says how many planes the carrier has aboard and what the UI send rule says. Needs P1 or S0 |

For 12 turns after P1 each of your turn starts logs a `PROXY_WATCH` INFO line with the P Status text, plus VEF-UPKEEP's record state, whether its unit is still on the map, and B's gold. `tools/api_allowlist_extra.json` lists `DiplomacyManager.RequestSession` (panel), `AdjustBaseDiplomacy` and `GetDiplomaticScore` (gameplay) for EFV_Dev only; the pair readers are VEF's own (PLAN Appendix A A64, U20, U23). Gameplay writes only through the synced request, iterates players by ascending ID and uses no random and no local-player call.

## Upgrade spike (U1 button)

`U1 Upgrade spike (press 1, 2, 3)` sits in the VEF 1.0.5 group. It answers the questions of `FIXPLAN_upgrade_relink.md` U6 (Q-A to Q-G) from the log, and it checks VEF 1.0.5's upgrade relink in the same run. It works after P1 (B = P1's B) or after S0 (B = S0's B), so it runs in the same game as the 1.0.5 disband re-check (`EFV/TESTING_1.0.5.md`). Gameplay keeps its state in `EFV_DEV_SCN` `upg` (player and unit IDs only); the panel shows gameplay's answer (`upg.ans`) in the status line.

| Press | When | What it does |
|---|---|---|
| 1 | no U1 yet in this game, or after press 3 | Grants what the upgrade of the S5 pair needs (your civilization's unique upgrade when there is one, else Warrior to Swordsman): its tech (`SetTech`) and civic, its strategic resource for two upgrades (twice the Gathering Storm `Units_XP2` ResourceCost plus 10, at least 20) and 3000 gold. Makes two units of the "from" type in your land: VEF-U1-M (one level-1 promotion, XP, 30 damage, 2 extra moves so a move onto rough ground still leaves one) on a tile with a free tile of yours next to it, and VEF-U1-S (fresh) as far from it as your land allows. Both are lent to you by B as Expeditionary records (`MakeRecord`), the case of the multiplayer report: a human host upgrades a lent unit. Also a Battering Ram VEF-U1-R exactly 2 tiles from VEF-U1-M and a Builder VEF-U1-B; their formations are logged (Q-F), with your highest unit serial (`id / 65536`, Q-G). VEF-U1-M is selected. Check line `UPG_U1 PASS` (CHECK when a unit is missing or not both are in your land: the game only upgrades in friendly territory). The panel then asks the engine whether Upgrade is available for both units, as the base unit panel does (`UnitManager.CanStartCommand(u, UnitCommandTypes.UPGRADE, false, true)`), and logs `[EFV][Upg] UI press 1 Upgrade button: VEF-U1-M yes -> <type>, ...` |
| 2 | the same turn, after the upgrades | Logs both records (relinked or not), both old unit objects (FindID: tile, damage, `EFV_UnitGoneReason`: live, ghost or none), both new units (ID, serial, slot, type, tile, **moves left** (Q-D), XP, promotions, damage) and whether each new serial is above the press-1 maximum |
| 3 | a later turn | Logs the records again and `[EFV][CHECK] UPG_SPIKE INFO` with VEF's verdict and the answers Q-A to Q-G. The same line is written once by itself at your first turn start after press 1, in case press 3 is forgotten |

**The trace** (armed in the press-1 turn, your units only, information only; writes nothing to VEF): `GameEvents.OnUnitMoved` (the U1 units), `GameEvents.UnitCreated`, `GameEvents.UnitInitialized` and `Events.UnitUpgraded` each log `[EFV][Upg] G <event> #<n> P<pid>/<uid> serial= slot= type= at= moves= xp= dmg= promos= = <which unit>; VEF-U1-M P0/<id>: live at x,y | ghost (<why>) at x,y dmg d | none, record ...; VEF-U1-S ...`. A new unit of the upgrade type is matched to VEF-U1-M or VEF-U1-S by the tile its old unit stood on. The event order (`#n`) and the old unit's state at the first event about each new unit are kept for press 3 (Q-B, Q-C). The panel logs `Events.UnitUpgraded` (UI) too: `[EFV][Upg] UI Events.UnitUpgraded P<pid>/<uid> upgradeType= ...`. `tools/api_allowlist_extra.json` lists `GameEvents.UnitCreated` / `UnitInitialized` (G) and `Events.UnitUpgraded` (UI) as PENDING until this spike, and `UnitCommandTypes.UPGRADE` / `UnitCommandResults.UNIT_TYPE` (UI, EFV_Dev only).

## Air-unit spike (A buttons)

The spike behind lending planes (`FIXPLAN_air_units.md` section 7, FUTURE.md F3): can VEF put a plane into a city's air slot by script, does the plane work there without Flight, and can gameplay see it? The by-eye script is session 1 of `EFV/TESTING_SPIKES.md`, together with the denounce spike. Play a new Ancient-era game and press S0 first: every A button needs S0's B and F. Found your capital on the coast, or A5 has no water.

No tech is granted. A script `Create` ignores tech (SPIKES S10), and Deploy and Rebase need none (UnitOperations.xml). So the planes exist without Flight, Advanced Flight or Radio, and whether they offer Deploy and Rebase anyway is part of the answer. Every unit is a Fighter (`UNIT_FIGHTER`, upkeep 1 Aluminium).

| Button | cmd | What it sets up |
|---|---|---|
| A1 Plane in your city | `air_city` | VEF-AIR-1 and VEF-AIR-2 in your capital (the second is over the one city-centre slot), VEF-AIR-3 on free land 2-4 tiles away (no base). The panel selects VEF-AIR-1 |
| A2 Plane for B | `air_host` | a Fighter for B in B's capital through VEF's own restore path (`EFV_Units.Recreate` with a stand-in record: one promotion, 20 damage), as an Expeditionary arrival would make it |
| A3 Fuel (press per step) | `air_fuel` | step 1: VEF-AIR-1 at 30 damage, your Aluminium 0. Step 2, two turns after A1 (a unit does not heal in the turn it was made): reads the damage, then adds 2 Aluminium for each of your Aluminium units, so the upkeep can't use it up. Step 3, a turn later: reads the damage again. A press too early says how long to wait |
| A4 Plane with ally F | `air_ally` | F becomes your ally (Civil Service for both, then the alliance flag, as T1) and your Fighter VEF-AIR-V is created in F's capital. F, not B: A2's plane fills B's capital slot |
| A5 Loaded carrier (again after the send) | `air_carrier` | a Carrier VEF-CV on free water next to your capital (your own water first: a send needs it) and a Fighter VEF-AIR-CV created on its tile; the answer says what VEF's send rule says for B, F and the city-state. Send the carrier with VEF 1.0.4's normal button, then press A5 again: it reports the carrier's record and where the plane is now. The next VEF greys this send out (a carrier with planes aboard can't be sent); the button stays to show why |
| A Status | `air_status` | where each spike unit is now |

Each button writes a short summary on the panel's second line: gameplay's answer first, then `UI:` with what the screen side sees. In gameplay a unit reads as "in city of P0", "land" or "on water", with its damage and whether `Units.GetUnitsInPlot` lists it ("in plot list", the check `EFV_UnitGoneReason` relies on). The UI part says whether the plane is based (listed by its plot's or its district's `GetAirUnits`), the district's slots, whether the unit panel would offer Deploy and Rebase (`UnitManager.CanStartOperation`, as `UnitPanel.lua` asks) and the number of rebase targets. For A4 it also says whether VEF-AIR-1 may rebase to F's capital, for A5 how many planes the carrier has aboard.

`Lua.log` gets one `[EFV][Air] G` line per probed tile and unit: `GetUnitCount`, the `Units.GetUnitsInPlot` list with each unit's Domain, `plot:GetAirUnits`, the city-centre district's `GetAirSlots` and `GetAirUnits`, and per unit its description, `EFV_UnitMatches`, `GetCombat`, `GetAirSlots`, `GetAirUnits`, `CanStartOperation` for DEPLOY and REBASE and the REBASE targets. The panel writes the same reads from the screen side as `[EFV][Air] UI` lines. None of the air readers is confirmed in gameplay, and only some in the UI (base `UnitFlagManager.lua`, `CityBannerManager.lua`, `WorldInput.lua`, `UnitPanel.lua`). So every one is looked up by name and pcall-guarded: a missing one reads `MISSING`, a failing one `ERROR`, nothing throws, and `api_audit` does not see them. `tools/api_allowlist_extra.json` lists only `GameInfo.UnitOperations` (the operation hashes) and `UnitOperationResults.PLOTS` (the rebase target list, unverified in gameplay), for EFV_Dev only. The answer for the panel goes into `EFV_DEV_SCN` (`air`), without translated names. At each of your turn starts for 4 turns after the last A button, an `AIR_TURN` line gives the status again.

## Corps spike (C buttons)

The spike behind sending and returning Corps and Armies (`FIXPLAN_corps.md` section 5, its "Designer rulings" and, for C8 to C10 and the merge trace, "Rulings 2" R2.7; FUTURE.md F0). The by-eye script is session 2 of `EFV/TESTING_SPIKES.md`. Play a new Ancient-era game and press S0 first: nobody has Nationalism or Mobilization yet, so you, B and the city-states are hosts without the civic. Run C6 before C3 and C9, because both give you Nationalism. The buttons sit in their own group below the air spike.

| Button | cmd | What it sets up |
|---|---|---|
| C1 Formation probe (press per step) | `corps_probe` | your Swordsman VEF-C1, Galley VEF-C1N (on free water near your capital, if any) and Tank VEF-C1T. Press 1 sets them to Army, press 2 to Corps, press 3 back to a plain unit (the downgrade, unverified); a fourth press starts over. A Builder VEF-C1B and a Battering Ram VEF-C1R are made and read once. Every step reads your total gold upkeep and Oil upkeep, and the per-type upkeep readers |
| C2 Formations for B and a city-state | `corps_give` | for CS2 (a second city-state, no Nationalism): VEF-C2-A made, set to Corps, then 2 promotions, 40 XP and 30 damage by hand (formation first); VEF-C2-B through `EFV_Units.Recreate` with the same values, then Corps (formation last). For B: VEF-C2-ARMY like C2-B, as an Army |
| C3 Merge as host (again after End Turn) | `corps_merge` | press 1: you get Nationalism; B lends you two Spearmen (Expeditionary records): VEF-C3-LENT (0 XP, 20 damage) next to your VEF-C3-OWN (30 XP, 1 promotion), and VEF-C3-LENT2 (30 XP, 1 promotion) next to your VEF-C3-OWN2 (20 damage), all with full moves. You merge both pairs. Press 2, after End Turn: every C3 record still open ends its service next turn (its unit is put on your land first, so it goes home without grace) |
| C4 City-state merges (optional) | `corps_cs_ai` | a third city-state gets Nationalism; two of your Swordsmen serve it as City-State units (VEF-C4-1, VEF-C4-2, service ends in 6 turns) next to its own VEF-C4-N. Information only: does its AI merge them |
| C5 Forced city-state merges | `corps_cs_force` | three cases at the session's city-state, at least 4 tiles apart: 1) your tracked VEF-C5-S becomes a Corps, its partner VEF-C5-N is removed, its service ends next turn; 2) the city-state's VEF-C5-M becomes a Corps and your tracked VEF-C5-A next to it is removed; 3) your tracked VEF-C5-X is removed with a city-state Builder VEF-C5-BLD 2 tiles away and no Corps near. Shows VEF 1.0.4's merge handling (FIXPLAN_corps.md Part 1, cases b, a, e) |
| C6 Host without the civic | `corps_host` | reads Nationalism and Mobilization of you, B and CS2 first. Then `EFV_Units.Recreate` + `SetMilitaryFormation`: VEF-C6-CORPS and VEF-C6-ARMY for you, lent by B (Expeditionary records, full moves) with C's Warrior VEF-C6-FOE next to the Corps to attack; VEF-C6-B, a Corps for B, and VEF-C6-CS, an Army for CS2, both lent by you |
| C7 Formation round trip (press twice) | `corps_trip` | press 1: your Swordsman VEF-C7 with 2 promotions, 20 XP, 30 damage, set to Army; then VEF's way home: `EFV_Units.Snapshot`, `Remove`, `Recreate` (route B: your UI takes the promotions back, as for a veteran) and `SetMilitaryFormation` with the snapshot's formation. Upkeep is read as a plain unit, as an Army, after the removal and after the restore. Press 2 reads it back; a third press starts over |
| C8 Split a mixed Army (press twice) | `corps_split` | what VEF's split of a formation with units of two senders will do. Press 1: B's Swordsman VEF-C8-B through `EFV_Units.Recreate` (1 promotion, 15 XP), set to Army, 30 damage; CS2's VEF-C8-CS (no promotion) set to Corps, 30 damage. The lent units inside are stand-ins kept in `EFV_DEV_SCN`: B's Army holds the host's unit, yours (2 promotions, 40 XP) and F's (10 XP); CS2's Corps holds yours (1 promotion, 20 XP) and F's, no host unit. Press 2: B's Army is lowered to a plain unit in place and read back (same ID, formation, XP, promotions, damage, moves, strength); CS2's Corps is removed with `EFV_Units.Remove`; each part comes back through `EFV_Units.Recreate` for its sender next to that sender's capital, with 30 damage (VEF-C8-YOU, -F, -YOU2, -F2). A third press starts over |
| C9 Volunteer merges (again after End Turn) | `corps_vol` | press 1: you get Nationalism if you lack it; three pairs on your land, at least 3 tiles apart, with Volunteer records (you to B, deployed 10 turns ago): VEF-C9-V1 (1 promotion, 20 XP) + VEF-C9-V2 (20 damage); your regular VEF-C9-REG (30 XP) + VEF-C9-V3; VEF-C9-V4 (30 XP) + your regular VEF-C9-REG2. You merge each pair, selecting the first. A second press in the same turn says to merge and End Turn. Press 2 after End Turn: per pair the unit that survived, its formation, XP and promotions, each Volunteer record (open with its state, or closed) and `FindID` (or `EFV_UnitGoneReason`) of the absorbed unit. A third press starts over |
| C10 Merge guard off/ask/block | (UI) | cycles off, ask, block. Ask: when you enter Form Corps or Form Army and the selected unit or a unit it can merge with has a VEF record, a popup lists them ("lent by P<n>" or "Volunteer") with Continue and Cancel; Cancel leaves the mode (`UI.SetInterfaceMode(SELECTION)`) and logs the mode read back. Block: the popup, and the panel's input handler swallows a left click (`MouseEvents.LButtonUp`) in Form Corps or Form Army mode on a plot with a unit that has a VEF record, and says "click blocked at x,y". Sends nothing |
| C Status | `corps_status` | every C unit now |

Each button writes a short summary on the panel's second line: gameplay's answer first (per unit: owner and ID, formation, strength, XP, promotions, damage, moves, tile, "(moved)" when it left its first tile, and its VEF record's state or "closed"), then `UI:` with each unit's formation and strength as the screen side reads them. At each of your turn starts for 6 turns after the last C button, a `CORPS_WATCH` line gives the C Status text.

**Merge trace** (no button, information only). C3 press 1 and C9 press 1 arm it until the next turn start. While it is on, every `GameEvents.OnUnitMoved` about a C3 or C9 unit logs `[EFV][Corps] G trace OnUnitMoved P<pid>/<uid> (<key>): ...` with every C3 and C9 unit: alive (with formation and XP) or gone (`FindID` nil or the `EFV_UnitGoneReason`). The panel does the same for `Events.UnitFormCorps`, `UnitFormArmy` and `UnitRemovedFromMap` (`[EFV][Corps] UI trace ...`). It answers whether a synchronous gameplay callback runs during a merge while the absorbed unit still exists. Read only.

When you enter Form Corps or Form Army mode, the panel also logs `[EFV][Corps] UI FORM_CORPS mode: selected ... can merge with: ...` and shows it on the second line: the selected unit (the one giving the command) and the units it can merge with (`UnitManager.GetCommandTargets`, as `WorldInput.lua` asks), each marked lent or not. That is the hook a VEF merge warning could use (FIXPLAN_corps.md "Merge confirmation: feasibility"). Read only.

`GetMilitaryFormation` and `SetMilitaryFormation` (Corps and Army) are confirmed in gameplay. The other readers are not, so they are looked up by name and pcall-guarded (`MISSING`, `ERROR`, nothing throws), and `api_audit` does not see them: `GetCulture():HasCivic`, `GetTreasury():GetTotalMaintenance`, `GetResources():GetUnitResourceDemandPerTurn("RESOURCE_OIL")`, `UnitManager.GetUnitMaintenance` / `GetUnitCorpsMaintenance` / `GetUnitArmyMaintenance` (by hash, as `ReportScreen.lua:319-334` in the UI), `UnitManager.CanFormMilitaryFormation`, the unit's `GetCombat`, and in the panel `GetCombat` and `GetVeteranName`. `tools/api_allowlist_extra.json` lists `MilitaryFormationTypes.ARMY_FORMATION` and, for the panel's mode log, `Events.InterfaceModeChanged`, `UnitManager.GetCommandTargets`, `UnitCommandTypes.FORM_CORPS` / `FORM_ARMY` and `UnitCommandResults.UNITS`, and for 1.0.4.5 `GameEvents.OnUnitMoved` (gameplay, the trace) and `MouseEvents.LButtonUp` / `UI.GetCursorPlotID` (panel, C10 block mode), for EFV_Dev only. Gameplay writes only through the synced request, iterates lists in order and uses no random and no local-player call. The answer for the panel goes into `EFV_DEV_SCN` (`corps`).

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

`tests/offline/test_dev_mod.lua` runs this mod in the offline fake engine: every command, every test-session scenario and its check line (S12 end to end with VEF's promotion context and the panel; S17 to S19 with the panel's UI checks; S20 to the trip home of both units and the two notifications; S21 end to end with VEF's promotion context and the rule "a promotion ends the turn": all three promotions in the arrival turn, 0 moves, full moves next turn; the panel title with the loaded VEF version; the denounce spike with the fake engine's missing readers (MISSING and ERROR lines, the answer in `EFV_DEV_SCN`), D Setup with and without an eligible civ, and the panel's G and UI summary; the air spike: A1 to A5 and A Status with the fake engine's missing air readers (MISSING lines, no error), B's plane with its promotion and damage, the A3 steps and their waits, A5 before and after the carrier is gone, A1 without S0 (CHECK), and the panel's A buttons with gameplay's and the UI's summary; the Corps spike: C1's three formation steps and a new round, C2's formations for B and a city-state with their promotions and damage, C3's two lent pairs, the wait message and the expiry after End Turn, C5's tracked Corps, C6's formations for you, B and the city-state with full moves and C's Warrior, C7's round trip and read back, C Status and the `CORPS_WATCH` line, C1 without S0 (CHECK), and the panel's C buttons with the Form Corps mode line; C8's two presses (B's Army lowered in place with the same ID, CS2's Corps removed, the four parts home) and a new round, C9's three pairs with their Volunteer records, the wait message and the survivors after End Turn, C8 and C9 without S0 (CHECK), the merge trace (on in the C3 / C9 turn for those units only, off after the turn start, the panel's UI trace line), and C10's mode cycling, popup and Cancel, and the swallowed click in the fake UI; the V spike with the rule "a promotion ends the turn" on in the fake UI, with Gran Colombia's rule, and without the ability rows), every Shot scene from a fresh game and the panel's Shot steps, T1 and T2 with 7 AI civs, with 3 (skipped roles), without a capital and with an ally the engine pulls into your war, and the panel (hidden start, hotkey, flat parameters, forged requests, scenario buttons, camera focus, session line, Target set to B). The final-session tests start from a fake brand-new game (nobody met, nothing revealed, no diplomacy) and run S0 first; S0 is also tested without a capital, without the reveal call (Scout fallback) and with a refused open-borders deal (alliance fallback). Run it with `python tests/offline/run_tests.py -k dev`.

The U1 upgrade spike (1.0.5.2) is tested there too: press 1 after P1 (the units, records, Ram, Builder, grants and the answer), the move and the two upgrades with the trace lines, press 2 with the moves left, the turn-start line, press 3 with Q-A to Q-G and VEF's verdict (both records follow their upgraded units, no merge notice), U1 after S0 and without a session (CHECK), and the panel (the request, the UI Upgrade check, the UI `Events.UnitUpgraded` line).
