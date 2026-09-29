#!/usr/bin/env python3
"""summarize_efv_log.py - one PASS/CHECK line per step of the final in-game session.

Usage:
    python tools/summarize_efv_log.py [--log PATH] [--db PATH] [-v]

Reads Lua.log of the last game run (default: %LOCALAPPDATA%\\Firaxis Games\\Sid Meier's
Civilization VI\\Logs\\Lua.log, or EFV_CIV6_LOGS) and prints the result of every step of
EFV/TESTING_FINAL.md:

    Step  3  PASS   Send Expeditionary: fee 36 (band 2, expected 36)
    Step  7  CHECK  Grace (S3): record 2 state=DEPLOYED grace=nil (expected GRACE with 5 turns)
    Step 12  -      Recall and friendship restored: not run

Sources: the "[EFV][CHECK] <ID> <PASS|CHECK|INFO> T<turn> <detail>" lines written by the
EFV_Dev scenario buttons (EFV_Dev 0.6.1-dev.1) and a few of EFV's own log lines (version,
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

EFV_VERSION = "0.6.1-dev"
DEV_VERSION = "0.6.1-dev.1"

CHECK_RE = re.compile(r"\[EFV\]\[CHECK\] (\S+) (PASS|CHECK|INFO) T(-?\d+) (.*)$")
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


def version_step(log, ctx):
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
    ok = ver == EFV_VERSION and devver == DEV_VERSION and not spike and not mismatch
    if spike:
        parts.append("SPIKE TEST MOD IS ENABLED")
    if mismatch:
        parts.append("VERSION MISMATCH")
    if ver != EFV_VERSION:
        parts.append("expected VEF %s" % EFV_VERSION)
    if devver != DEV_VERSION:
        parts.append("expected VEF Dev %s" % DEV_VERSION)
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
    print("VEF final session summary (%s, %d VEF lines, %d check lines)" % (a.log, len(log.efv), len(log.checks)))
    failed = 0
    for num, title, ev in STEPS:
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
    if a.verbose:
        for c in log.checks:
            if c[1] == "CHECK":
                print("  CHECK %s T%d %s" % (c[0], c[2], c[3]))
    return 1 if failed or errs else 0


if __name__ == "__main__":
    sys.exit(main())
