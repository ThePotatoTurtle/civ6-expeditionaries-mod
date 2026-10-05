# Volunteers & Expeditionary Forces (VEF)

A Civilization VI mod for Gathering Storm. It lets you lend combat units to the civs and city-states that fight your wars, and hand a city you just captured to a partner.

Get it on the Steam Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=3810156577

Version 1.0.4.

## The four options

| Option | Who controls the unit | How long | Cost |
|---|---|---|---|
| Expeditionary Force | the partner (ally, teammate or declared friend) | 20 turns, then it comes home | free for a 1-turn trip, otherwise 5 to 15% of the unit's gold price |
| Volunteers | you | no limit; recall after 10 turns | 10 to 25% of the unit's gold price |
| City-State Expeditionary | a city-state you have met | 10 turns, then it comes home from wherever it is | same as Expeditionary |
| Entrust | the partner, for good | permanent | nothing |

Some basics:
- A lent unit leaves the map for 1 to 4 turns and then appears next to the city you picked.
- It keeps its type, promotions, damage and name, on the way out and on the way home. Units you control keep their level too, both a unit coming home to you and your Volunteers. They get all their promotions and their level back on the turn they arrive.
- If the host upgrades the unit, it comes home upgraded. That includes the host's unique unit, for example a Macedonian Hypaspist.
- The host does not need the tech for a unit it receives. It can host units it cannot build.
- When its time is up, an Expeditionary unit has to be on the host's land or yours. If it is anywhere else it gets 5 turns of grace and then mutinies. City-State units never mutiny: they simply come home after their 10 turns.
- The AI never sends units or entrusts cities, but it does use the units it receives. VEF does not change the AI.

## How to use it

### Sending a unit
1. Select a combat unit in your own territory, or in the territory of the partner or city-state you want to send it to. The unit panel gets three buttons: Send as Expeditionary, Send as Volunteers and Send to City-State.
2. A greyed-out button means the unit can't go right now. Its tooltip lists every reason, for example "not at full health" or "no common enemy".
3. Click a button to open the destination list. Each line shows the partner, the city, the distance, the travel time, the fee and how long the unit serves. Greyed-out lines say why that city is not possible. A unit standing in a partner's territory can only go to that partner's cities, and the list says so.
4. Pick a city and confirm. You pay the fee at once ("Free" when there is none) and the unit leaves the map.

### Recalling Volunteers
Select one of your Volunteers and click Recall Volunteers. You can do this after 10 turns of service, or at any time during a lapse (see below). The unit has to stand on your land or the host's. It leaves the map and reappears next to its home city when it arrives. Volunteers never come home on their own.

### Units you host
A unit lent to you has a status button in the unit panel. The tooltip says who sent it, how many turns it has left, and warns you about merging it into a Corps or Army.

Lent units carry a small tag under their unit flag with the lending civ's emblem: gold for Expeditionary, green for Volunteers, light blue for City-State. Hover the tag for details.

### The tracker
The VEF button on the launch bar (top left) opens a list of every unit you sent or received:
- Unit, partner ("To Rome", "From Babylon") and type of force.
- State: Outbound, Deployed, Service ended, Grace, Mutiny, Lapse, Returning, or Blocked (arrival delayed). A paused lapse reads "Lapse: Grace 3 (paused)".
- Turns: until arrival, until the service ends, of grace left, or until a mutinying unit dies. Volunteers have no limit and show "-".
- Destination, for units on the way.

While some of your units are on their way, a line at the bottom right shows their upkeep per turn and, in brackets, your real net gold per turn. Units off the map still cost their normal upkeep, but the gold per turn in the top bar doesn't count it.

Units in grace or mutiny are listed first, in red. Click a column title to sort by it: once for A to Z (or lowest first), twice for Z to A, a third time for the usual order. The sorted column shows a single arrow next to its title, and every other title shows a faded up and down pair. While a column is sorted, units in grace or mutiny stay red but are no longer kept on top. Hover a row for details. Click a row to go to the unit: your own unit gets selected, a unit you lent out is shown if you can see it, and for a unit on the way the map shows its destination. Esc closes the list.

While one of your units is in grace or mutiny, a red banner shows at the top of the screen and the VEF button gets an alert mark. Click the banner to jump through those units. Right-click it to open the tracker.

VEF warnings (grace, mutiny, lapse, service ending, delayed arrival) stay in your notification list until the problem is over or you dismiss them. Losses stay until you dismiss them. Plain news, such as a unit leaving, arriving or coming home, clears at the end of the turn.

### Entrust
When you capture a city, the capture screen (Keep / Raze) gets an Entrust... button. It gives the city for good to an ally, teammate or declared friend who was at war with the city's old owner when you took it. If the old owner was a city-state or has been knocked out of the game, any of them can take it. The same goes for a Free City. It works for capitals too.

1. Click Entrust... to see the partners who can take the city.
2. Click a partner, then click it again to confirm. The city changes hands at once, as a gift, with its buildings, districts, wonders and population. Your units inside are moved out.
3. You and the new owner both get a notification. After that the city is simply theirs.

If nobody qualifies, the button is greyed out and the tooltip says why. Entrust is only offered on the turn you take the city. You take the normal penalty for the capture. The new owner gets no extra penalty and no loyalty help, so a city it cannot hold may flip. If you close the capture screen without choosing, the game reopens it from the notification as usual.

## Rules

### Who can receive what
- Expeditionary Force: an ally, a teammate or a declared friend.
- Volunteers: a teammate, an ally, or a declared friend who grants you open borders. Open borders without friendship do not count, and neither does friendship without open borders.
- City-State Expeditionary: any city-state you have met.
- Entrust: an ally, a teammate or a declared friend who was at war with the city's old owner when you took it (any of them if the old owner was a city-state, a Free City, or has been knocked out of the game).
- Expeditionary Force and Volunteers: you and the partner must be at war with the same enemy (Barbarians and Free Cities don't count), and not at war with each other.
- City-State Expeditionary needs no shared enemy. You can lend a unit to any city-state you have met, for example to help it in a war of its own, as long as you are not at war with it.

This table shows who can receive units. "Yes" means you can send. "No" means the player's cities are listed but greyed out, with the reason in the tooltip. "Hidden" means the player doesn't appear in the destination list at all. "-" means that option doesn't apply to this kind of player. "any" in the "Shares an enemy" column means it doesn't matter.

| The recipient is | Shares an enemy with you | Expeditionary | Volunteers | City-State Expeditionary |
|---|---|---|---|---|
| Teammate | yes | Yes | Yes | - |
| Ally | yes | Yes | Yes | - |
| Ally | no | No: no shared enemy | No: no shared enemy | - |
| Declared friend who gives you open borders | yes | Yes | Yes | - |
| Declared friend who gives you open borders | no | No: no shared enemy | No: no shared enemy | - |
| Declared friend without open borders | yes | Yes | No: needs open borders | - |
| Declared friend without open borders | no | No: no shared enemy | No: needs open borders, no shared enemy | - |
| Other major civ (met, no alliance or friendship) | any | Hidden: not a partner | Hidden: not a partner | - |
| Major civ you are at war with | any | Hidden: at war with you | Hidden: at war with you | - |
| City-state you have met | any | - | - | Yes |
| City-state you are at war with | any | - | - | No: at war with you |
| City-state you haven't met | any | - | - | Hidden: not met |

- A shared enemy is a major civ or a city-state that you and the recipient are both at war with. Barbarians and the Free Cities never count, and they can't receive units.
- The unit must stand in your own territory, or in the recipient's territory. From the recipient's land it can only go to that recipient's cities.
- Entrust has its own rule: the city goes to an ally, teammate or declared friend who was at war with the city's old owner when you took it. If the old owner was a city-state, a Free City, or has been knocked out of the game, any of them can take it.

### Which units can go
Land and naval combat units, including Warrior Monks and Nihangs. The unit must:
- be at full health;
- have full movement points, so it can't have moved or attacked this turn;
- not be embarked;
- stand in your own territory, or in the territory of the partner or city-state you send it to. From a partner's land it can only go to that partner's cities. Neutral land and anyone else's land don't count;
- not be part of a Corps, Army, Fleet or Armada.

A naval unit also needs a free water tile near the destination city.

Not allowed: air units, civilians, support units, religious units, Great People, Heroes, Vampires and Questing Knights. Units that originally belonged to someone else (levied or gifted units) can't be sent either.

### Fees
The fee depends on the unit's gold price and the travel time. The gold price is 4 times the unit's production cost, adjusted for game speed. Policy and purchase discounts don't count.

| Travel time | 1 turn | 2 turns | 3 turns | 4 turns |
|---|---|---|---|---|
| Expeditionary and City-State | free | 5% | 10% | 15% |
| Volunteers | 10% | 15% | 20% | 25% |
| Swordsman at Standard speed, Expeditionary | free | 18 gold | 36 gold | 54 gold |
| Swordsman at Standard speed, Volunteers | 36 gold | 54 gold | 72 gold | 90 gold |

You pay once, and nobody receives the gold. The trip home is free. While the unit travels, in either direction, you keep paying its normal gold and strategic resource upkeep. Your treasury and stockpile never go below 0.

### Travel time
- Distance is measured from city to city: from your city nearest to the unit to the destination city, and on the way home from the host city to your return city. This also holds for a unit that leaves from a partner's land.
- On a Standard map a trip of up to 10 tiles takes 1 turn, 11 to 20 tiles 2 turns, 21 to 35 tiles 3 turns, and 36 or more 4 turns. The limits scale with the map width.
- The unit appears within 5 tiles of the city and can't move that turn. If there is no free tile, the arrival is delayed and tried again every turn.
- If something changes while a unit is on its way, the send can be called off. See "When a send is called off" below.
- Home is the city it was sent from if you still own it, otherwise your nearest city, then your capital. If you have no city left, the unit is lost.

### When a send is called off
A unit on its way out is checked at the start of each of your turns, and once more just before it arrives. The send is called off when:
- the destination city changes hands in any way: captured, razed, flipped by loyalty, traded or gifted. This counts even if the partner has taken the city back by the time of the check.
- the partner is knocked out of the game.
- the partner no longer qualifies for that kind of send. For Expeditionary Forces and Volunteers that means you are now at war with each other, the alliance, team or friendship is gone, or you no longer share an enemy. Volunteers sent to a declared friend also need the friend's open borders to last. A city-state only stops qualifying if you go to war with it.

What happens then:
- The unit comes straight back, on the same turn, to the tile it left from. If another unit stands there, or the tile is now enemy land or land you can't enter, it takes the nearest free tile, up to 5 tiles away. If there is none, it appears next to the city it would normally return to, and if even that is full it travels there and arrives when a tile frees up.
- It keeps its promotions, level, damage and name, like any unit coming home. It can't move on the turn it comes back.
- You get half the fee back, rounded down. A free send gives nothing back, and the upkeep you paid while it travelled is not refunded.
- A notification tells you why. A human partner is told too, with the reason, and the unit drops off the tracker.

Only the checks count: if an alliance ends and is renewed between two of your turns, nothing happens. A war declared on you in the middle of a round calls the unit back at the start of your next turn. Open borders from a friend end on their expiry turn, so Volunteers still on their way to that friend are called back unless you are also allies or teammates. There is no grace period for this. Units already on their way home are not affected.

### Service, grace and mutiny
- Expeditionary units serve 20 turns, City-State units 10. You and the host are warned 3 turns and 1 turn before the end.
- Making peace with the shared enemy, or the alliance or friendship ending, doesn't shorten an Expeditionary tour. The shared enemy only matters when you send (and while the unit is on its way). Only Volunteers lapse.
- When an Expeditionary unit's service ends, it comes home by itself if it stands on the host's land or yours. Anywhere else it gets 5 turns of grace to get back.
- After grace comes mutiny: 20 damage per turn and no healing. A unit at full health dies on the 5th mutiny turn, a damaged one sooner.
- An Expeditionary unit that reaches the host's land or yours during grace or mutiny comes home at the next turn. The damage stays.
- Grace and mutiny notifications come back every turn with an alert sound and move the map to the unit. The banner stays until the unit is safe.
- City-State units never go into grace or mutiny, because you don't control them. When their 10 turns are up they come home from wherever they are, even if the suzerain has levied them. The trip home takes the normal 1 to 4 turns.

### Volunteers: lapses and recall
- Volunteers stay your units. You move them and pay their upkeep. They heal at the normal rates: 15 HP on allied land, 10 on neutral land, 5 on a friend's land under open borders. VEF adds no healing.
- A lapse starts when the host is no longer a teammate, an ally or a declared friend with open borders, or when you no longer share a war with it.
- A lapse gives the same 5 turns of grace and then mutiny, and you can recall the unit before its 10 turns are up.
- While a lapsed Volunteer stands on your land or the host's, the lapse is paused: no countdown, no mutiny damage, normal healing. Recall it from there. If it leaves that land while still lapsed, the countdown or the mutiny damage picks up where it stopped. You get one "Volunteer Lapse Paused" notification when the pause starts.
- The lapse ends if the conditions come back, for example when the alliance is renewed. The Volunteers are then simply deployed again. Damage already taken is not refunded. Teammates never lapse over eligibility.
- When open borders end, the game itself moves your Volunteers out of the friend's land, usually onto neutral land. Neutral land does not count: walk them back to your land or the host's, where the lapse pauses, and recall them.
- Recall needs 10 turns deployed (or a lapse) and the unit on your land or the host's. Full health is not needed.

### War, elimination and losses
- If you and the host go to war with each other, no matter who declared it: lent Expeditionary and City-State units leave the host and travel home, the same trip as at the end of their service. This also applies to units in grace or mutiny. Deployed Volunteers are simply your units and VEF stops tracking them. Units on the way are called back (see When a send is called off), and units already heading home still arrive.
- If the host is eliminated: units on the way are called back to where they left, and you get half the fee back. Deployed Expeditionary units come home as they were when the host's last city fell (if VEF has no saved state for a unit, it is lost and you are told). A unit killed in that fight is lost, not sent home. Volunteers are not affected here; the normal lapse follows.
- If you are eliminated: your deployed Expeditionary and City-State units stay with their hosts for good, and those still on the way arrive on schedule and become the host's own units. If the destination city has changed hands by then, they go to the host's nearest other city. Your Volunteers, deployed or on the way, and any unit on its way home are lost.
- If a lent unit is killed or disbanded, you get a notification.

### Corps and Armies
- The host can merge a lent Expeditionary unit into a Corps or Army. The game can't prevent it, but the unit panel warns first.
- If the lent unit is absorbed into another unit, you lose it for good. If it is the surviving unit, it keeps serving and later comes home alone, without the formation.
- If you merge one of your own Volunteers, it stops being a Volunteer and VEF stops tracking it.
- Both players get a notification after a merge.

## Compatibility
- Requires Gathering Storm.
- Tested in multiplayer and works well.
- VEF replaces the unit flag script (UnitFlagManager) with a thin wrapper to show its flag tags. Mods that replace the same script with a higher load order, such as Gift It To Me, win: the tags disappear, but everything else still works. Replacements with a lower load order are overridden, except CQUI and Better Builder Charges Tracking, which VEF loads underneath its wrapper.
- CQUI should work but has not been tested.
- VEF is saved with your game. Don't remove it in the middle of a game: units on the way exist only in the mod's records.

## Future plans
- A matching grievance penalty for the new owner of an entrusted city. The game offers mods no way to add grievances today, so this waits for one.

## Known issues
- The AI never sends units or entrusts cities. It does use the units it receives.
- Entrust adds no grievance penalty for the new owner. The capturer takes the normal penalty; the game gives mods no way to add grievances.
- A unit whose owner has none of its strategic resource doesn't heal. This is a Gathering Storm rule and covers lent units too (a host without Iron can't heal a lent Swordsman). VEF warns you before you send and while it happens.
- If the host upgrades a lent unit and moves it away in the same turn, VEF can't be sure it's the same unit and reports it lost. The same applies to a city-state unit levied by its suzerain when it can't be told apart from the city-state's own units.
- If the host is eliminated, anything a deployed Expeditionary unit gained after the host's last city fell is lost.
- A mutinying unit may briefly show a "+HP" animation before VEF takes the healing back.
- A host who declares war on you can use your lent units until the next turn starts.
- Air units (planes) can't be sent yet.
- The gold per turn in the top bar doesn't count the upkeep of your units on their way, but VEF still charges it each turn. The VEF tracker shows that upkeep and your real net gold per turn.

## Changelog
- 1.0.4: Changed: if you and the host go to war, lent Expeditionary and City-State units now leave and travel home like at the end of their service, keeping their promotions. They no longer switch to you where they stand, which could drop a unit deep in the host's land. Send fees are halved: Expeditionary and City-State units are still free for a 1-turn trip, then cost 5, 10 or 15% of the unit's gold price; Volunteers cost 10 to 25%. Returning veterans now get all their promotions back on the turn they arrive, not one per turn. The tracker now shows the upkeep of your units on their way and your real net gold per turn, since the top bar leaves that upkeep out. The mod description in the game's Additional Content screen is rewritten and shorter. New known issues: a host who declares war on you can use your lent units until the next turn starts, and air units can't be sent yet.
- 1.0.3: Changed: a unit on its way to a partner is called back when the destination city changes hands or the partner stops qualifying. It returns at once to the tile it left from and you get half the fee back; it no longer goes to another city of the partner. If you are eliminated, Expeditionary and City-State units still on the way arrive and stay with the host. The send confirmation now says so. Entrust no longer needs a partner at war with the old owner when that owner was a city-state or has been knocked out of the game, so a city-state or a civ's last city can be entrusted now. In the tracker, units lent to you show as Inbound while on their way and Departed once they head home.
- 1.0.2: Changed: city-states can receive units without a shared enemy.
- 1.0.1: Fixed: Expeditionary sends were allowed without a shared enemy. The game keeps every civ at war with the Free Cities and VEF counted that, so any partner passed. Free Cities no longer count as a shared enemy (they still do for Entrust), and Volunteers now lapse when the real shared war ends.
- 1.0.0: First public release, on the Steam Workshop and GitHub. Same rules as 0.7.4.
- 0.7.4: Veterans with three or more promotions no longer lose their level when they come home. They get one promotion back per turn until all are back.
- 0.7.3: In the tracker, every column you can sort by shows a faded up and down mark next to its title. The sorted column keeps its single arrow.
- 0.7.2: The coloured emblem under a lent unit's flag was drawn almost black. It is now gold, green or light blue as intended. A veteran coming home gets its promotions back in the turn it arrives, not one turn later. The tracker's sort marks are now proper arrows. VEF warnings (grace, mutiny, lapse, service ending, blocked arrival, rerouted unit) stay until the problem is over, and losses stay until you dismiss them. Only plain news (departed, arrived, returned) still clears at the end of the turn. VEF never touches notifications from the game or other mods.
- 0.7.1: The tracker columns can be sorted by clicking their titles. The scroll bar is now dark blue and easier to see.
- 0.7.0: A unit can also be sent from the territory of the partner or city-state it goes to, but then only to that partner. City-State units no longer go into grace or mutiny; after 10 turns they come home from wherever they are. Your veterans keep their level when they come home or serve as Volunteers. The flag tag now shows the lending civ's emblem, coloured by type of force. The destination list shows one clear line per city. New icon for Send to City-State, and a wider, easier to read tracker.
- 0.6.1: A unit can only be sent with full movement points. A unit that has moved or attacked this turn has to wait until next turn.
- 0.6.0: Entrust is in. The capture screen can give a city you just captured to a partner that was at war with its former owner. New warning when a lent unit won't heal because its owner has none of its strategic resource.
- 0.5.2: New fees (Expeditionary and City-State free for a 1-turn trip, then 10, 20 or 30%; Volunteers 20 to 50%). Safer tracking: a unit killed in combat is never sent home, and a unit that gets a new identity through a levy or an upgrade is followed only when it is certainly the same unit, unique units included. Combat damage a mutinying unit takes just before the end-of-turn heal is kept. A restored unit's experience stops just below its next promotion. When a host's last city falls, its lent units start home at once. The short name in the game is now "VEF".
- 0.5.1: Volunteers never come home by themselves. A lapsed Volunteer on your land or the host's is paused until you recall it. New "Volunteer Lapse Paused" notification, and "(paused)" in the tracker and on the flag.
- 0.5.0: The tracker on the launch bar. All texts and notification icons checked. Player README and Workshop description.
- 0.4.0: War between sender and host, eliminated players, killed or disbanded units, lost destinations. Corps and Army rules with warnings.
- 0.3.0: Volunteers (friends need open borders, lapses, recall). The mod got its current name.
- 0.2.0: City-State Expeditionary and suzerain levies.
- Earlier builds: sending, travel, arrival and return, grace and mutiny, flag badges.

## For modders
- The easiest way to install is to subscribe on the Steam Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=3810156577
- To install by hand instead, copy the `EFV` folder into `Documents\My Games\Sid Meier's Civilization VI\Mods`, then enable Volunteers & Expeditionary Forces and Gathering Storm under Additional Content.
- `EFV` is the project's internal prefix, so folders, files and code use it. In the game the mod is always called VEF.
- `EFV_Dev` is a separate developer panel for in-game testing. Don't enable it in a normal game.
