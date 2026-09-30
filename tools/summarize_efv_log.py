#!/usr/bin/env python3
"""summarize_efv_log.py - one PASS/CHECK line per step of an in-game test session.

Usage:
    python tools/summarize_efv_log.py [--retest | --s14 | --eligibility | --v103] [--log PATH] [--db PATH] [-v]

Reads Lua.log of the last game run (default: %LOCALAPPDATA%\\Firaxis Games\\Sid Meier's
Civilization VI\\Logs\\Lua.log, or EFV_CIV6_LOGS) and prints the result of every step of
EFV/TESTING_FINAL.md, with --retest of the 6-step 0.7 re-test EFV/TESTING_RETEST_0.7.md, or with
--s14 of the mutiny-death check EFV/TESTING_S14.md. Every mode also prints the EFV_Dev badge audit
(BADGE_AUDIT lines, EFV_Dev 0.7.2-dev.1) next to the error count. --eligibility prints the T1 / T2
eligibility buttons of EFV_Dev 1.0.1.3+ instead: one line per civ (role, picker result expected
and actual for Expeditionary and Volunteers; T2 also one per city-state for the City-State picker,
EFV_Dev 1.0.2.1; PASS/FAIL/CHECK) for the gameplay rules and the UI
rules, from the last press of each button. --v103 summarises the VEF 1.0.3 session
EFV/TESTING_1.0.3.md (EFV_Dev 1.0.3.2: tracker labels, Entrust rules, transit cancel) and lists
the veteran spike results (V0-V3) as findings, which never fail the run:

    Step  3  PASS   Send Expeditionary: fee 36 (band 2, expected 36)
    Step  7  CHECK  Grace (S3): record 2 state=DEPLOYED grace=nil (expected GRACE with 5 turns)
    Step 12  -      Recall and friendship restored: not run

Sources: the "[EFV][CHECK] <ID> <PASS|CHECK|INFO> T<turn> <detail>" lines written by the
EFV_Dev scenario buttons (EFV_Dev 0.7.2-dev.1) and a few of EFV's own log lines (version,
[Send] ok, [Entrust] ok, loads). Lua.log is buffered while the game runs: quit to the
desktop (or the main menu) before running this. -v also prints every CHECK line.
Exit code 0 when every step that ran passed, 1 otherwise.
"""
from __future__ import annotations

import argparse
import math
import os
import re
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import efvlib as L  # noqa: E402

EFV_VERSION = "0.7.2-dev"
DEV_VERSION = "0.7.2-dev.1"

CHECK_RE = re.compile(r"\[EFV\]\[CHECK\] (\S+) (PASS|CHECK|FAIL|INFO) T(-?\d+) (.*)$")
EFV_RE = re.compile(r"\[EFV\]\[T(-?\d+)\]\[([A-Za-z]+)\] (.*)$")
SEND_RE = re.compile(r"ok id=(\d+) force=(\S+) sender=\d+ recipient=(\d+) unit=\S+ type=(\S+) fee=(\d+) band=(\S+)")
SPEED_RE = re.compile(r"derived PM=(\d+) speedPct=(\d+)")

FEE_PCT = {"EXPEDITIONARY": 0, "CS_EXPEDITIONARY": 0, "VOLUNTEER": 20}
SURCHARGE_PCT = {1: 0, 2: 10, 3: 20, 4: 30}


class Log:
    def __init__(self, lines):
        self.lines = lines
        self.checks = []   # (id, verdict, turn, detail)
        self.efv = []      # (turn, tag, msg)
        for ln in lines:
            m = CHECK_RE.search(ln)
            if m:
                self.checks.append((m.group(1), m.group(2), int(m.group(3)), m.group(4).strip()))
                continue
            m = EFV_RE.search(ln)
            if m:
                self.efv.append((int(m.group(1)), m.group(2), m.group(3).strip()))

    def checks_of(self, cid, contains=None):
        return [c for c in self.checks if c[0] == cid and (contains is None or contains in c[3])]

    def efv_of(self, tag, prefix=""):
        return [e for e in self.efv if e[1] == tag and e[2].startswith(prefix)]


def short(s, n=150):
    s = s.replace("LOC_CIVILIZATION_", "").replace("_NAME", "")
    return s if len(s) <= n else s[: n - 3] + "..."


def verdict_of(log, cid, contains=None):
    """Last non-INFO verdict of a check ID: ('PASS'|'CHECK'|None, detail)."""
    rows = [c for c in log.checks_of(cid, contains) if c[1] != "INFO"]
    if not rows:
        return None, ""
    last = rows[-1]
    return last[1], last[3]


def ids_step(*ids, contains=None):
    """Step verdict from check IDs: PASS when every ID's last verdict is PASS."""
    contains = contains or {}

    def ev(log, ctx):
        parts, seen, bad = [], 0, False
        for cid in ids:
            v, d = verdict_of(log, cid, contains.get(cid))
            if v is None:
                parts.append("%s not seen" % cid)
                bad = True
                continue
            seen += 1
            bad = bad or v != "PASS"
            parts.append(d)
        if seen == 0:
            return None, "not run"
        return ("CHECK" if bad else "PASS"), "; ".join(parts)
    return ev


def unit_cost(db, unit_type):
    if not db or not os.path.exists(db):
        return None
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
        row = con.execute("SELECT Cost FROM Units WHERE UnitType=?", (unit_type,)).fetchone()
        con.close()
        return int(row[0]) if row else None
    except sqlite3.Error:
        return None


def expected_fee(ctx, unit_type, force, band):
    pm, speed = ctx.get("pm"), ctx.get("speed")
    cost = unit_cost(ctx.get("db"), unit_type)
    try:
        b = int(band)
    except (TypeError, ValueError):
        return None
    if pm is None or speed is None or cost is None or force not in FEE_PCT or b not in SURCHARGE_PCT:
        return None
    n = cost * speed * pm * (FEE_PCT[force] + SURCHARGE_PCT[b])
    return int(math.floor((n + 9999) / 10000))


def send_step(*forces):
    def ev(log, ctx):
        parts, worst, seen = [], "PASS", 0
        for force in forces:
            rows = [SEND_RE.search(e[2]) for e in log.efv_of("Send", "ok ")]
            rows = [m for m in rows if m and m.group(2) == force]
            if not rows:
                parts.append("%s send not seen" % force)
                worst = "CHECK"
                continue
            seen += 1
            m = rows[0]
            fee, band, utype = int(m.group(5)), m.group(6), m.group(4)
            exp = expected_fee(ctx, utype, force, band)
            if exp is None:
                parts.append("%s fee %d (band %s)" % (force, fee, band))
            elif exp == fee:
                parts.append("%s fee %d (band %s, expected %d)" % (force, fee, band, exp))
            else:
                parts.append("%s fee %d (band %s, EXPECTED %d)" % (force, fee, band, exp))
                worst = "CHECK"
        if seen == 0:
            return None, "not run"
        return worst, "; ".join(parts)
    return ev


def version_step(log, ctx, efv_version=None, dev_version=None):
    efv_version = efv_version or EFV_VERSION
    dev_version = dev_version or DEV_VERSION
    loads = [e for e in log.efv_of("Init", "EFV_Gameplay loading version=")]
    if not loads:
        return "CHECK", "VEF did not load (no '[Init] EFV_Gameplay loading' line)"
    ver = loads[-1][2].split("version=", 1)[1].strip()
    dev = [ln for ln in log.lines if "EFV_Dev gameplay loaded" in ln]
    devver = None
    if dev:
        m = re.search(r"version=(\S+)", dev[-1])
        devver = m.group(1) if m else None
    spike = any("[EFV_SPIKE]" in ln for ln in log.lines)
    mismatch = any("version mismatch" in ln for ln in log.lines)
    parts = ["VEF %s" % ver, "VEF Dev %s" % devver]
    ok = ver == efv_version and devver == dev_version and not spike and not mismatch
    if spike:
        parts.append("SPIKE TEST MOD IS ENABLED")
    if mismatch:
        parts.append("VERSION MISMATCH")
    if ver != efv_version:
        parts.append("expected VEF %s" % efv_version)
    if devver != dev_version:
        parts.append("expected VEF Dev %s" % dev_version)
    return ("PASS" if ok else "CHECK"), ", ".join(parts)


def reload_step(log, ctx):
    loads = log.efv_of("Init", "EFV_Gameplay loading version=")
    if len(loads) < 2:
        return None, "not run (only one game load in this log)"
    # after the reload the grace countdown must continue (S3 checks keep passing)
    later = [c for c in log.checks if c[0] in ("MUTINY", "MUTINY_RETURN") and c[1] != "INFO"]
    bad = [c for c in later if c[1] != "PASS"]
    return ("CHECK" if bad else "PASS"), "%d game loads; the grace countdown %s after the reload" % (
        len(loads), "did NOT continue" if bad else ("continued" if later else "not checked yet"))


def entrust_step(log, ctx):
    v, d = verdict_of(log, "ENTRUST")
    ok_lines = log.efv_of("Entrust", "ok ")
    if v is None and not ok_lines:
        return None, "not run"
    parts = []
    if ok_lines:
        parts.append("[Entrust] " + ok_lines[-1][2])
    if d:
        parts.append(d)
    good = (v == "PASS") or (v is None and ok_lines)
    return ("PASS" if good else "CHECK"), "; ".join(parts)


def vet_step(log, ctx):
    rows = {}
    for r in ("A", "B", "C"):
        vg, dg = verdict_of(log, "VET_" + r)
        vu, du = verdict_of(log, "VET_LEVEL_" + r)
        rows[r] = (vg, dg, vu, du)
    if all(v[0] is None and v[2] is None for v in rows.values()):
        info = log.checks_of("VET")
        return (None, "not run") if not info else ("CHECK", short(info[-1][3]))
    parts, kept = [], []
    for r in ("A", "B", "C"):
        vg, dg, vu, du = rows[r]
        lvl = re.search(r"level (\S+) \(original (\S+)\)", du or "")
        state = "kept" if vu == "PASS" or (vu is None and vg == "PASS") else "reset"
        if vg is None and vu is None:
            state = "not run"
        if state == "kept":
            kept.append(r)
        parts.append("%s %s%s" % (r, state, (" (level %s of %s)" % lvl.groups()) if lvl else ""))
    note = ("route %s keeps the level" % "/".join(kept)) if kept else "no route keeps the level (known limitation stays)"
    complete = all(rows[r][0] is not None and rows[r][2] is not None for r in ("A", "B", "C"))
    return ("PASS" if complete else "CHECK"), ", ".join(parts) + "; " + note


STEPS = [
    (1, "Install and version check", version_step),
    (2, "New game and setup (S0)", ids_step("SETUP")),
    (3, "Send Expeditionary", send_step("EXPEDITIONARY")),
    (4, "Send Volunteers and City-State unit", send_step("VOLUNTEER", "CS_EXPEDITIONARY")),
    (5, "Arrival next to the host city (S1)", None),
    (6, "Expiry and automatic return (S2)", ids_step("EXPIRE")),
    (7, "Grace (S3)", ids_step("GRACE")),
    (8, "Save and reload", reload_step),
    (9, "Mutiny, 20 damage (S3)", ids_step("MUTINY")),
    (10, "Back on valid land, home with damage (S3, S1)", ids_step("MUTINY_RETURN", "HOME", contains={"HOME": "(MUTINY_RETURN)"})),
    (11, "Volunteer lapse paused (S4)", ids_step("LAPSE", "LAPSE_PAUSE")),
    (12, "Recall and friendship restored (S4, S1)", ids_step("RECALL", "LAPSE_RESTORE", "HOME", contains={"HOME": "(RECALL)"})),
    (13, "Upgrade keeps the unit tracked (S5)", ids_step("UPGRADE")),
    (14, "Veteran level on restore (S6)", vet_step),
    (15, "Killed unit is not sent home (S7)", ids_step("KILLED")),
    (16, "No relink to a stranger (S8)", ids_step("GUARD")),
    (17, "Arrival next to a crowded city (S9)", ids_step("CROWDED")),
    (18, "Combat during mutiny, T31 (S10)", ids_step("T31_EVENT", "T31")),
    (19, "Entrust a captured city (S11)", entrust_step),
]


def arrival_step(log, ctx):
    rows = log.checks_of("ARRIVE")
    if not rows:
        return None, "not run"
    bad = [r for r in rows if r[1] != "PASS"]
    forces = sorted({m.group(1) for m in (re.search(r"record \d+ (\S+)", r[3]) for r in rows) if m})
    if bad:
        return "CHECK", "%d arrival(s), %d with a problem: %s" % (len(rows), len(bad), short(bad[0][3]))
    return "PASS", "%d arrival(s) placed correctly (%s)" % (len(rows), ", ".join(forces))


def combine(*evs):
    """Step verdict from several evaluators: PASS only when every part ran and passed."""
    def ev(log, ctx):
        parts, ran, bad = [], 0, False
        for part in evs:
            v, d = part(log, ctx)
            if v is None:
                bad = True
                parts.append(d if d and d != "not run" else "part not run")
                continue
            ran += 1
            bad = bad or v != "PASS"
            parts.append(d)
        if ran == 0:
            return None, "not run"
        return ("CHECK" if bad else "PASS"), "; ".join(parts)
    return ev


def pressed(log, cmd):
    """True when the dev panel sent scenario command `cmd` in this log."""
    return any("cmd=%s," % cmd in ln and "request ok=" in ln for ln in log.lines)


def sent_ids(log):
    """Record IDs of every '[Send] ok' line, in log order."""
    out = []
    for e in log.efv_of("Send", "ok "):
        m = SEND_RE.search(e[2])
        if m and int(m.group(1)) not in out:
            out.append(int(m.group(1)))
    return out


def from_land_step(log, ctx):
    """Re-test step 2, second part: S13 (0.7.2: says so when S13 was never pressed)."""
    if not log.checks_of("FROM_LAND_RULES") and not log.checks_of("FROM_LAND"):
        if not pressed(log, "scn_inland"):
            return None, "S13 NOT PRESSED in this game (no scn_inland request in the log)"
        return None, "S13 pressed but no FROM_LAND line"
    return ids_step("FROM_LAND_RULES", "FROM_LAND")(log, ctx)


def arrivals_step(log, ctx):
    """Re-test step 3: every unit sent in this game arrived (ARRIVE PASS for each [Send] ok record).
    0.7.2: the expected count follows the sends (3, or 4 with the S13 Spearman)."""
    v, d = arrival_step(log, ctx)
    if v is None:
        return v, d
    sent = sent_ids(log)
    arrived = set()
    for c in log.checks_of("ARRIVE"):
        m = re.search(r"record (\d+) ", c[3])
        if m:
            arrived.add(int(m.group(1)))
    missing = [i for i in sent if i not in arrived]
    if missing:
        return "CHECK", "%s; %d of %d sent unit(s) arrived, missing record(s) %s" % (
            d, len(sent) - len(missing), len(sent), ",".join(str(i) for i in missing))
    note = "" if pressed(log, "scn_inland") else " (S13 not pressed: 3 sends expected)"
    return v, "%s; all %d sent unit(s) arrived%s" % (d, len(sent), note)


LAPSE_PAUSE_OLD_RE = re.compile(r"Volunteer record (\d+) grace=(\S+) \(was (\S+): the countdown must not move")
RESUMED_RE = re.compile(r"resumed id=(\d+) .* at=(-?\d+),(-?\d+) hook=")


def lapse_step(log, ctx):
    """Re-test step 4. 0.7.2: when the countdown moved, a '[Lapse] resumed' line of that record
    means the Volunteer had left B's land first, so the step is 'not verified', not a VEF bug
    (EFV_Dev 0.7.0 logs; EFV_Dev 0.7.2 says so itself and holds the unit for the check)."""
    v, d = ids_step("EXPIRE", "LAPSE", "LAPSE_PAUSE", "LAPSE_TEXT")(log, ctx)
    pv, pd = verdict_of(log, "LAPSE_PAUSE")
    m = LAPSE_PAUSE_OLD_RE.search(pd or "")
    if pv == "CHECK" and m:
        moves = [RESUMED_RE.search(e[2]) for e in log.efv_of("Lapse", "resumed ")]
        moves = [r for r in moves if r and r.group(1) == m.group(1)]
        if moves:
            d = ("NOT VERIFIED: Volunteer record %s left B's land (at %s,%s) before the countdown, so grace %s -> %s "
                 "is correct; leave it on B's land. " % (
                     m.group(1), moves[0].group(2), moves[0].group(3), m.group(3), m.group(2))) + d
    return v, d


def vet_restore_step(log, ctx):
    """Re-test step 5. 0.7.2: an 0.7.0 log where the level came back a turn late (the UI found no
    promotion to take at 0 moves on the arrival turn) is named, and its damage explained."""
    v, d = ids_step("VET_RESTORE", "VET_RESTORE_LEVEL")(log, ctx)
    waits = [e for e in log.efv_of("UIVet", "waiting ")]
    promotes = [e for e in log.efv_of("UIVet", "PROMOTE ")]
    if v == "CHECK" and waits and promotes and promotes[0][0] > waits[0][0]:
        late = promotes[0][0] - waits[0][0]
        d = ("LEVEL BACK %d TURN(S) LATE: no promotion was offered on the arrival turn (0 moves); damage lower by the "
             "engine's heal of 15 per round in your land (normal). " % late) + d
    return v, d


def t31_step(log, ctx):
    """Re-test step 6: every combat event PASS and the T31 verdict. 0.7.2: a Spearman killed by
    extra Barbarian attacks is named as a test-setup problem (EFV_Dev 0.7.2 removes them)."""
    events = [c for c in log.checks_of("T31_EVENT") if c[1] != "INFO"]
    v, d = verdict_of(log, "T31")
    if not events and v is None:
        return None, "not run"
    bad_ev = [c for c in events if c[1] != "PASS"]
    parts = []
    if v is not None and "is gone" in d:
        parts.append("TEST UNIT KILLED: the Barbarians' attacks and the mutiny damage killed it before the check "
                     "(test setup, not VEF; EFV_Dev 0.7.2 removes them after your fight)")
    parts.append("%d combat event(s), %s" % (len(events), "all PASS" if not bad_ev else "%d CHECK: %s" % (len(bad_ev), bad_ev[0][3])))
    if events:
        parts.append("first: " + events[0][3])
    parts.append("T31 verdict not seen" if v is None else d)
    ok = not bad_ev and v == "PASS"
    return ("PASS" if ok else "CHECK"), "; ".join(parts)


def no_errors_step(log, ctx):
    errs = error_lines(log)
    if errs:
        return "CHECK", "%d error line(s), first: %s" % (len(errs), short(errs[0], 120))
    return "PASS", "no errors"


# The 0.7 re-test (EFV/TESTING_RETEST_0.7.md, FIXPLAN_0.7 section 4).
RETEST_STEPS = [
    (1, "Install, new game and setup (S0)", combine(version_step, ids_step("SETUP"))),
    (2, "Sends, and a send from B's land (S13)", combine(send_step("EXPEDITIONARY", "VOLUNTEER", "CS_EXPEDITIONARY"),
                                                         from_land_step)),
    (3, "Arrivals (S1)", arrivals_step),
    (4, "City-State recall from neutral land, lapse text (S2, S4)", lapse_step),
    (5, "Veteran level restored (S12)", vet_restore_step),
    (6, "Mutiny combat, no errors (S10)", combine(t31_step, no_errors_step)),
]


def mut_death_step(n):
    """S14 copy n: the MUT_DEATH verdict at the next turn start (EFV_Dev 0.7.2-dev.1)."""
    def ev(log, ctx):
        rows = [c for c in log.checks_of("MUT_DEATH", "copy %d (" % n) if c[1] != "INFO"]
        if not rows:
            if log.checks_of("MUT_DEATH"):
                return "CHECK", "no verdict for copy %d yet: End Turn once more, then quit" % n
            return None, "not run (press S14)"
        last = rows[-1]
        return ("PASS" if last[1] == "PASS" else "CHECK"), last[3]
    return ev


def badge_audit(log):
    """(verdict, detail) of the BADGE_AUDIT lines; verdict None when there are none."""
    rows = [c for c in log.checks_of("BADGE_AUDIT") if c[1] != "INFO"]
    if not rows:
        info = log.checks_of("BADGE_AUDIT")
        return None, (short(info[-1][3]) if info else "not run (needs VEF Dev Tools 0.7.2-dev.1)")
    fails = [c for c in rows if c[1] != "PASS"]
    if fails:
        return "CHECK", "%d of %d audit line(s) FAIL, first T%d: %s" % (len(fails), len(rows), fails[0][2], fails[0][3])
    return "PASS", "%d audit line(s), every VEF tag on its record's live unit; last: %s" % (len(rows), rows[-1][3])


def badge_audit_step(log, ctx):
    return badge_audit(log)


# The S14 mutiny-death check (EFV/TESTING_S14.md, EFV_Dev 0.7.2-dev.1).
S14_STEPS = [
    (1, "New game, setup (S0) and S14", combine(version_step, ids_step("SETUP"),
                                                lambda log, ctx: (("PASS", "S14 set up: " + short(log.checks_of("MUT_DEATH")[-1][3], 90))
                                                                  if log.checks_of("MUT_DEATH") else (None, "not run (press S14)")))),
    (2, "Copy 1 killed by the Barbarians (or the mutiny)", mut_death_step(1)),
    (3, "Copy 2 killed attacking a Barbarian", mut_death_step(2)),
    (4, "No VEF tag or tracker row on the wrong unit", badge_audit_step),
]


# The VEF 1.0.3 session (EFV/TESTING_1.0.3.md, EFV_Dev 1.0.3.2).
V103_EFV = "1.0.3"
V103_DEV = "1.0.3.2"


def v103_version_step(log, ctx):
    return version_step(log, ctx, V103_EFV, V103_DEV)


def cancel_step(mode):
    """S16 CANCEL verdict of one mode (CS_TAKEN or PARTNER_ENDED), from the next turn start."""
    def ev(log, ctx):
        v, d = verdict_of(log, "CANCEL", " %s:" % mode)
        if v is None:
            if log.checks_of("CANCEL_PREP", " %s " % mode):
                return "CHECK", "S16 was pressed (%s), but no CANCEL line: End Turn once more, then quit" % mode
            return None, "not run (send a unit, press S16, End Turn)"
        return ("PASS" if v == "PASS" else "CHECK"), d
    return ev


V103_STEPS = [
    (1, "Install, new game and setup (S0)", combine(v103_version_step, ids_step("SETUP"))),
    (2, "Tracker labels: Inbound, Departed, Outbound, Returning (S17)",
     ids_step("TRACKER_LABELS", contains={"TRACKER_LABELS": "summary:"})),
    (3, "Entrust a city-state's last city to a partner at peace with it (S18)", ids_step("ENTRUST_CS_UI", "ENTRUST_CS")),
    (4, "Entrust of a living major's city stays greyed (S19)", ids_step("ENTRUST_MAJOR_UI", "ENTRUST_MAJOR")),
    (5, "Transit cancelled: the city-state loses its city (S16)", cancel_step("CS_TAKEN")),
    (6, "Transit cancelled: the partner stops qualifying (S16)", cancel_step("PARTNER_ENDED")),
]

V103_SPIKE = [
    ("V0", "VSPIKE_V0", "control, route B as today (expected: 1 promotion in the first turn)"),
    ("V1", "VSPIKE_V1", "hidden keep-moves ability"),
    ("V1 off", "VSPIKE_V1_OFF", "ability removed: a promotion ends the turn again"),
    ("V2", "VSPIKE_V2", "moves restored after each promotion"),
    ("V3", "VSPIKE_V3", "level-adjust ability + SetPromotion + XP"),
]


def spike_report(log):
    """Prints the veteran spike findings (EFV_Dev 1.0.3.2); they never fail the run."""
    warn = [c for c in log.checks_of("VSPIKE") if c[1] == "CHECK"]
    if not log.checks_of("VSPIKE") and not any(log.checks_of(cid) for _, cid, _ in V103_SPIKE):
        print("Veteran spike: not run (press V Veteran spike)")
        return
    print("Veteran spike (findings, not pass/fail):")
    for c in warn:
        print("    WARN   T%d %s" % (c[2], short(c[3], 200)))
    for label, cid, title in V103_SPIKE:
        rows = [c for c in log.checks_of(cid) if c[1] != "INFO"]
        info = [c for c in log.checks_of(cid) if c[1] == "INFO"]
        if not rows and not info:
            print("    %-6s -      %s: no result" % (label, title))
            continue
        last = rows[-1] if rows else info[-1]
        print("    %-6s %-5s  T%d %s" % (label, last[1], last[2], short(last[3], 220)))
        if cid == "VSPIKE_V0" and rows and info:
            print("    %-6s INFO   T%d %s" % ("", info[-1][2], short(info[-1][3], 200)))


ELIG_TITLES = {"T1": "Volunteer partners", "T2": "Shared enemy"}
ELIG_CIV_RE = re.compile(r"^(\S+?)=(.+?) \| (.*?) \| Expeditionary expected (\S+) actual (.+?) \| "
                         r"Volunteers expected (\S+) actual (.+?)(?: \| SETUP: (.*?))? \[(?:gameplay|UI) rules\]$")
# T2 city-state lines (EFV_Dev 1.0.2.1; VEF 1.0.2: no shared enemy needed for City-State sends).
ELIG_CS_RE = re.compile(r"^(\S+?)=(.+?) \| (.*?) \| City-State expected (\S+) actual (.+?)"
                        r"(?: \| SETUP: (.*?))? \[(?:gameplay|UI) rules\]$")


def elig_runs(log, cid):
    """Per-civ check lines and the summary line of the last complete run of ELIG_T1 / ELIG_T2
    (or their _UI twins): ([(verdict, detail)], (verdict, detail) or None)."""
    runs, cur = [], []
    for c in log.checks_of(cid):
        if c[3].startswith("summary"):
            runs.append((cur, (c[1], c[3])))
            cur = []
        else:
            cur.append((c[1], c[3]))
    if runs:
        return runs[-1]
    if cur:
        return cur, None
    return [], None


def elig_civ_text(detail):
    def part(name, want, got):
        return "%s %s" % (name, got) if want == got else "%s %s (EXPECTED %s)" % (name, got, want)
    m = ELIG_CIV_RE.match(detail)
    if not m:
        mc = ELIG_CS_RE.match(detail)
        if not mc:
            return short(detail, 200)
        role, civ, _facts, xc, ac, setup = mc.groups()
        civ = re.sub(r" \((major|minor/other)\)$", "", civ)
        text = "%-5s %s: %s" % (role, short(civ, 40), part("City-State", xc, ac))
        if setup:
            text += "; SETUP: " + setup
        return text
    role, civ, _facts, xe, ae, xv, av, setup = m.groups()
    civ = re.sub(r" \((major|minor/other)\)$", "", civ)
    text = "%-5s %s: %s; %s" % (role, short(civ, 40), part("Expeditionary", xe, ae), part("Volunteers", xv, av))
    if setup:
        text += "; SETUP: " + setup
    return text


def eligibility_report(log):
    """Prints the T1 / T2 results; returns the number of tests (per rules) that did not pass."""
    bad, seen = 0, 0
    for test in ("T1", "T2"):
        for cid, rules in (("ELIG_" + test, "gameplay rules"), ("ELIG_%s_UI" % test, "UI rules")):
            civs, summ = elig_runs(log, cid)
            if not civs and summ is None:
                print("%s %s, %s: not run" % (test, ELIG_TITLES[test], rules))
                continue
            seen += 1
            if summ is None:
                bad += 1
                print("%s %s, %s: CHECK  no summary line (setup stopped early)" % (test, ELIG_TITLES[test], rules))
            else:
                if summ[0] != "PASS":
                    bad += 1
                print("%s %s, %s: %-5s  %s" % (test, ELIG_TITLES[test], rules, summ[0],
                                               short(summ[1].split(": ", 1)[-1], 200)))
            for verdict, detail in civs:
                print("    %-5s  %s" % (verdict, elig_civ_text(detail)))
    if seen == 0:
        print("No T1 / T2 lines: press T1 Volunteer partners or T2 Shared enemy on the dev panel (EFV_Dev 1.0.1.3)")
        return 1
    return bad


def error_lines(log):
    out = []
    for i, ln in enumerate(log.lines):
        if "[EFV]" in ln and (re.search(r"\]\s+ERROR\b", ln) or ": ERROR " in ln):
            out.append(ln.strip())
        elif ("Runtime Error" in ln or "Syntax Error" in ln) and any("EFV" in x for x in log.lines[i:i + 6]):
            out.append(ln.strip())
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", default=os.path.join(L.LOGS_DIR, "Lua.log"))
    ap.add_argument("--db", default=L.GAMEPLAY_DB)
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--retest", action="store_true", help="the 6-step 0.7 re-test (EFV/TESTING_RETEST_0.7.md)")
    ap.add_argument("--s14", action="store_true", help="the S14 mutiny-death check (EFV/TESTING_S14.md)")
    ap.add_argument("--eligibility", action="store_true",
                    help="the T1 / T2 eligibility buttons (EFV_Dev 1.0.1.3): per-civ lines and PASS/FAIL")
    ap.add_argument("--v103", action="store_true",
                    help="the VEF 1.0.3 session (EFV/TESTING_1.0.3.md, EFV_Dev 1.0.3.2) and the veteran spike findings")
    a = ap.parse_args(argv)
    if not os.path.exists(a.log):
        print("Lua.log not found: %s" % a.log)
        return 2
    with open(a.log, "r", encoding="utf-8", errors="replace") as fh:
        log = Log(fh.read().splitlines())
    ctx = {"db": a.db}
    for ln in log.lines:
        m = SPEED_RE.search(ln)
        if m:
            ctx["pm"], ctx["speed"] = int(m.group(1)), int(m.group(2))
    if a.eligibility:
        print("VEF eligibility tests (%s, %d check lines)" % (a.log, len(log.checks)))
        bad = eligibility_report(log)
        errs = error_lines(log)
        print("Errors: %s" % ("none" if not errs else "%d, first: %s" % (len(errs), short(errs[0], 200))))
        return 1 if bad or errs else 0
    if a.v103:
        title, steps = "VEF 1.0.3 session summary", V103_STEPS
    elif a.s14:
        title, steps = "VEF S14 mutiny-death summary", S14_STEPS
    elif a.retest:
        title, steps = "VEF 0.7 re-test summary", RETEST_STEPS
    else:
        title, steps = "VEF final session summary", STEPS
    print("%s (%s, %d VEF lines, %d check lines)" % (title, a.log, len(log.efv), len(log.checks)))
    failed = 0
    for num, title, ev in steps:
        if ev is None:
            ev = arrival_step
        try:
            v, detail = ev(log, ctx)
        except Exception as exc:  # a broken log line must not hide the other steps
            v, detail = "CHECK", "summary error: %s" % exc
        mark = v if v else "-"
        if v == "CHECK":
            failed += 1
        print("Step %2d  %-5s  %s: %s" % (num, mark, title, short(detail, 230)))
    errs = error_lines(log)
    print("Errors: %s" % ("none" if not errs else "%d, first: %s" % (len(errs), short(errs[0], 200))))
    av, ad = badge_audit(log)
    print("Badge audit: %s%s" % ("" if av is None else av + " ", short(ad, 200)))
    if av == "CHECK":
        failed += 1
    if a.v103:
        spike_report(log)
    if a.verbose:
        for c in log.checks:
            if c[1] == "CHECK":
                print("  CHECK %s T%d %s" % (c[0], c[2], c[3]))
    return 1 if failed or errs else 0


if __name__ == "__main__":
    sys.exit(main())
