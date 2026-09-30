#!/usr/bin/env python3
"""test_tools.py - self-test for the EFV static tools, using tools/fixtures.

    python tools/test_tools.py            (exit 0 = all tests pass)

fixtures/good/EFV_Fixture   PLAN-shaped mini mod: every tool must report 0 errors.
fixtures/bad/EFV_Broken     one planted defect per check: every expected finding must be reported.
fixtures/logs/{good,bad}    synthetic game logs for check_logs.py.
fixtures/logs/retest        synthetic Lua.log of a passing 0.7 re-test for summarize_efv_log.py --retest.
"""
from __future__ import annotations

import io
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import efvlib as L  # noqa: E402
import check_lua  # noqa: E402
import validate_data  # noqa: E402
import api_audit  # noqa: E402
import check_logs  # noqa: E402
import check_all  # noqa: E402
import summarize_efv_log  # noqa: E402

FIX = os.path.join(L.TOOLS_DIR, "fixtures")
GOOD = os.path.join(FIX, "good")
BAD = os.path.join(FIX, "bad")


def found(rep, level=None):
    return {(os.path.basename(f.path), f.line, f.code) for f in rep.items if level is None or f.level == level}


def codes(rep, level="ERROR"):
    return {f.code for f in rep.items if f.level == level}


class TestCheckLua(unittest.TestCase):
    def test_runtime_is_lua51(self):
        self.assertIsNotNone(check_lua.lua_runtime(), "lupa Lua 5.1 runtime missing: pip install lupa")

    def test_good_clean(self):
        rep = check_lua.check(GOOD, luacheck="off")
        self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items])
        self.assertEqual(rep.count("WARN"), 0, [vars(f) for f in rep.items])

    def test_bad_detected(self):
        rep = check_lua.check(BAD, luacheck="off")
        f = found(rep)
        for exp in [("EFV_Gameplay.lua", 21, "undefined-global"),      # Plyers typo
                    ("EFV_Gameplay.lua", 23, "undefined-global"),      # pUnit
                    ("EFV_Gameplay.lua", 42, "undefined-global"),      # defined only in the UI state
                    ("EFV_Syntax.lua", 6, "syntax"),                   # missing end
                    ("EFV_Havok.lua", 2, "syntax"),                    # local x:number
                    ("EFV_Havok.lua", 2, "type-annotation"),
                    ("EFV_Gameplay.lua", 17, "global-assign-in-function")]:
            self.assertIn(exp, f)

    def test_basic_mode(self):
        rep = check_lua.check(BAD, basic=True, luacheck="off")
        f = found(rep)
        self.assertIn(("EFV_Syntax.lua", 2, "syntax-basic"), f)   # 'function' block never closed
        self.assertIn(("EFV_Havok.lua", 2, "type-annotation"), f)

    def test_syntax_variants(self):
        bad = {"goto x": "5.2 goto", "local a = 1 // 2": "floor div", "local a = 1 & 2": "bitwise",
               "if x then": "unclosed if", "local t = {1, 2": "unclosed table"}
        for src, why in bad.items():
            ok, _ = check_lua.compile_lua(src.encode(), "@t.lua")
            self.assertFalse(ok, why)
        ok, dump = check_lua.compile_lua(b"local x = Foo.Bar\nBaz = 1\nfunction f() Qux = 2 end", "@t.lua")
        self.assertTrue(ok)
        gl = {(op, n, d) for op, n, _l, d in check_lua.read_globals(dump)}
        self.assertEqual(gl, {("get", "Foo", 0), ("set", "Baz", 0), ("set", "f", 0), ("set", "Qux", 1)})


class TestValidateData(unittest.TestCase):
    def test_make_hash_matches_game(self):
        if not os.path.exists(L.GAMEPLAY_DB):
            self.skipTest("no gameplay DB")
        con = sqlite3.connect("file:%s?mode=ro" % L.GAMEPLAY_DB.replace("\\", "/"), uri=True)
        rows = con.execute("SELECT Type, Hash FROM Types LIMIT 500").fetchall()
        con.close()
        for t, h in rows:
            self.assertEqual(validate_data.make_hash(t), h, t)

    def test_good_clean(self):
        rep = validate_data.validate(GOOD)
        self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items if f.level == "ERROR"])
        self.assertEqual(rep.count("WARN"), 0, [vars(f) for f in rep.items if f.level == "WARN"])

    def test_display_name_efv_is_an_error(self):
        # Designer ruling 0.5.2: displayed text says "VEF"; "EFV_" identifiers are fine.
        tmp = tempfile.mkdtemp()
        try:
            dst = os.path.join(tmp, "EFV_Fixture")
            shutil.copytree(os.path.join(GOOD, "EFV_Fixture"), dst)
            txt = os.path.join(dst, "Data", "EFV_Text.xml")
            with open(txt, encoding="utf-8") as fh:
                src = fh.read()
            self.assertIn("VEF forces", src)
            with open(txt, "w", encoding="utf-8") as fh:
                fh.write(src.replace("VEF forces", "EFV forces"))
            rep = validate_data.validate(tmp)
            hits = [f for f in rep.items if f.code == "text-display-name"]
            self.assertEqual(len(hits), 1, [vars(f) for f in hits])
            self.assertIn("LOC_EFV_TRACKER_TITLE", hits[0].msg)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_original_db_untouched(self):
        if not os.path.exists(L.GAMEPLAY_DB):
            self.skipTest("no gameplay DB")
        before = (os.path.getmtime(L.GAMEPLAY_DB), os.path.getsize(L.GAMEPLAY_DB))
        validate_data.validate(BAD)
        self.assertEqual(before, (os.path.getmtime(L.GAMEPLAY_DB), os.path.getsize(L.GAMEPLAY_DB)))

    def test_bad_detected(self):
        rep = validate_data.validate(BAD)
        f = found(rep)
        c = codes(rep)
        for exp in [("EFV_Bad.sql", 9, "sql"),          # unknown column
                    ("EFV_Bad.sql", 12, "sql"),         # unknown table
                    ("EFV_Bad.sql", 15, "sql"),         # CHECK constraint
                    ("EFV_Icons.sql", 2, "sql-icons"),
                    ("EFV_Malformed.xml", 5, "xml"),
                    ("EFV_Gameplay.lua", 29, "text-args"),
                    ("EFV_Gameplay.lua", 30, "text-missing"),
                    ("EFV_Gameplay.lua", 32, "notification-missing"),
                    ("EFV_Panel.lua", 4, "ui-instance"),
                    ("EFV_Panel.lua", 10, "ui-control"),
                    ("EFV_Panel.lua", 23, "text-args"),         # L(key, ...) wrapper (WP7.3)
                    ("EFV_Text.xml", 0, "text-plural")]:        # malformed plural / fixed noun (WP7.3)
            self.assertIn(exp, f)
        for code in ["sql-fk", "sql-notification", "text-duplicate", "text-collision", "text-reason", "ui-id",
                     "modinfo-action", "modinfo-deps", "modinfo-files", "modinfo-props", "modinfo-replace",
                     "modinfo-ui", "modinfo-unlisted", "notification-plan", "notification-icon"]:
            self.assertIn(code, c)
        msgs = " | ".join(x.msg for x in rep.items)
        for frag in ["Data/EFV_Missing.sql does not exist", "EFV_Missing.sql is not listed in <Files>",
                     "UpdateText id=EFV_Text has no criteria", "undefined criteria 'EFV_NOPE'",
                     "action id EFV_Gameplay used twice", "UI/EFV_Gone.lua does not exist",
                     "Scripts/efv_havok.lua differs in case", "Scripts/EFV_Unlisted.lua exists on disk",
                     "AffectsSavedGames must be 1", "LuaReplace missing", "KIND_NOPE",
                     "malformed plural form", "fixed noun after a number"]:
            self.assertIn(frag, msgs)


class TestApiAudit(unittest.TestCase):
    def test_allowlist_parse(self):
        al = api_audit.load_allowlist(regen=True, quiet=True)
        s, m, e = al["static"], al["methods"], al["events"]
        self.assertEqual(set(s["Map.GetPlot"]["ctx"]), {"G", "UI"})
        self.assertEqual(set(s["Game:SetProperty"]["ctx"]), {"G"})
        self.assertEqual(set(s["Game:GetProperty"]["ctx"]), {"G", "UI"})
        self.assertEqual(set(s["Game.GetLocalPlayer"]["ctx"]), {"UI"})
        # Session A (T09) results merged from api_allowlist_extra.json: GetAttacksRemaining is available in G,
        # HasOpenBordersFrom is UI-only (no G context: gameplay use is an ERROR).
        self.assertEqual(m["GetAttacksRemaining"]["ctx"]["G"]["level"], "C")
        self.assertEqual(m["HasOpenBordersFrom"]["ctx"]["UI"]["level"], "C")
        self.assertNotIn("G", m["HasOpenBordersFrom"]["ctx"])
        self.assertEqual(m["IsRevealed"]["ctx"]["G"]["level"], "NV")
        self.assertEqual(set(m["ChangeGoldBalance"]["ctx"]), {"G"})
        self.assertIn("Events.UnitMovementPointsCleared", e)
        self.assertIn("Events.NotificationAdded", e)
        self.assertIn("GameEvents.EFV_*", e)
        self.assertIn("MapLayers.ANY", s)
        self.assertIn("PlayerOperations.EXECUTE_SCRIPT", s)
        self.assertNotIn("ImportFiles", al["globals"])

    def test_good_clean(self):
        rep, _ = api_audit.audit(GOOD)
        self.assertEqual(rep.count("ERROR"), 0, [vars(f) for f in rep.items if f.level == "ERROR"])
        w = found(rep, "WARN")
        self.assertIn(("EFV_Gameplay.lua", 16, "async-dv13"), w)       # DV13 exception is a warning
        # Events.PlayerDefeat is G C since Sessions D/E (was L [T20]): no longer a warning.
        self.assertNotIn(("EFV_Gameplay.lua", 63, "api-unverified"), w)

    def test_bad_detected(self):
        rep, _ = api_audit.audit(BAD)
        f = found(rep)
        for exp in [("EFV_Gameplay.lua", 5, "async-mutation"),      # ChangeGoldBalance via helper
                    ("EFV_Gameplay.lua", 6, "async-mutation"),      # GetRandNum via helper
                    ("EFV_Gameplay.lua", 14, "forbidden-pairs"),
                    ("EFV_Gameplay.lua", 18, "forbidden"),          # math.random
                    ("EFV_Gameplay.lua", 19, "forbidden"),          # os.time
                    ("EFV_Gameplay.lua", 20, "api-context"),        # Game.GetLocalPlayer in G
                    ("EFV_Gameplay.lua", 22, "lua52"),
                    ("EFV_Gameplay.lua", 23, "unknown-method"),
                    ("EFV_Gameplay.lua", 24, "api-context"),        # UI.RequestPlayerOperation in G
                    ("EFV_Gameplay.lua", 25, "forbidden"),          # ExposedMembers
                    ("EFV_Gameplay.lua", 26, "unknown-member"),
                    ("EFV_Gameplay.lua", 28, "forbidden"),          # :Kill(
                    ("EFV_Gameplay.lua", 33, "gameinfo-unknown"),
                    ("EFV_Gameplay.lua", 35, "unknown-api"),        # MapLayers.ANYY
                    ("EFV_Gameplay.lua", 39, "unknown-event"),      # OnGameTurnStartd
                    ("EFV_Gameplay.lua", 41, "api-context"),        # UI event in G
                    ("EFV_Util.lua", 8, "region-marker"),
                    ("EFV_Panel.lua", 7, "onstart-unhandled"),
                    ("EFV_Panel.lua", 9, "api-context"),            # Game.GetRandNum in UI
                    ("EFV_Panel.lua", 17, "api-context"),           # GameEvents in UI
                    ("EFV_Panel.lua", 19, "unknown-event")]:
            self.assertIn(exp, f)
        self.assertIn(("EFV_Gameplay.lua", 34, "gameinfo-unlisted"), found(rep, "WARN"))
        self.assertIn(("EFV_Panel.lua", 12, "pairs-records"), found(rep, "WARN"))


class TestCheckLogsAndAll(unittest.TestCase):
    def test_logs(self):
        out = io.StringIO()
        old = sys.stdout
        sys.stdout = out
        try:
            bad = check_logs.main(["--logs", os.path.join(FIX, "logs", "bad")])
            good = check_logs.main(["--logs", os.path.join(FIX, "logs", "good")])
        finally:
            sys.stdout = old
        self.assertEqual(bad, 1)
        self.assertEqual(good, 0)
        text = out.getvalue()
        self.assertIn("EFV_Transit.lua:42", text)
        self.assertIn("no column named NoSuchColumn", text)
        self.assertIn("EFV_Text - Failed loading XML", text)
        self.assertNotIn("something unrelated", text)

    def test_check_all_exit_codes(self):
        out = io.StringIO()
        self.assertEqual(check_all.run([GOOD], out=out)[0], 0)
        self.assertEqual(check_all.run([BAD], out=out)[0], 1)
        self.assertEqual(check_all.run([GOOD], strict=True, out=out)[0], 1)   # good fixture has 2 WARNs


class TestSummarizeRetest(unittest.TestCase):
    """summarize_efv_log.py --retest (0.7 re-test, EFV/TESTING_RETEST_0.7.md)."""

    LOG = os.path.join(FIX, "logs", "retest", "Lua.log")

    def run_summary(self, args):
        out = io.StringIO()
        old = sys.stdout
        sys.stdout = out
        try:
            code = summarize_efv_log.main(args + ["--db", os.path.join(FIX, "no_such.sqlite")])
        finally:
            sys.stdout = old
        return code, out.getvalue()

    def test_versions(self):
        self.assertEqual(summarize_efv_log.EFV_VERSION, "0.7.2-dev")
        self.assertEqual(summarize_efv_log.DEV_VERSION, "0.7.2-dev.1")
        self.assertEqual(len(summarize_efv_log.RETEST_STEPS), 6)

    def test_good_retest(self):
        code, text = self.run_summary(["--retest", "--log", self.LOG])
        self.assertEqual(code, 0, text)
        self.assertIn("VEF 0.7 re-test summary", text)
        for n in range(1, 7):
            self.assertIn("Step  %d  PASS" % n, text)
        self.assertIn("Errors: none", text)
        # the full-session mode still reads the same log without failing on a step
        code_full, text_full = self.run_summary(["--log", self.LOG])
        self.assertIn("VEF final session summary", text_full)
        self.assertNotIn("summary error", text_full)

    def test_bad_retest(self):
        with open(self.LOG, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        lines = [ln for ln in lines if "VET_RESTORE_LEVEL" not in ln and "FROM_LAND PASS" not in ln
                 and "ARRIVE PASS T3 record 4" not in ln]
        lines += ["Runtime Error: C:/Games/Base/Assets/UI/SelectedUnit.lua:195: attempt to index a nil value",
                  "stack traceback:", "EFV_Dev_Gameplay: [EFV][T6][Dev] scn: after the error"]
        tmp = tempfile.mkdtemp()
        try:
            path = os.path.join(tmp, "Lua.log")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(os.linesep.join(lines))
            code, text = self.run_summary(["--retest", "--log", path])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        self.assertEqual(code, 1)
        self.assertIn("Step  2  CHECK", text)      # FROM_LAND not seen
        self.assertIn("Step  3  CHECK", text)      # record 4 sent but not arrived
        self.assertIn("3 of 4 sent unit(s) arrived, missing record(s) 4", text)
        self.assertIn("Step  5  CHECK", text)      # UI level check missing
        self.assertIn("VET_RESTORE_LEVEL not seen", text)
        self.assertIn("Step  6  CHECK", text)      # the runtime error
        self.assertIn("SelectedUnit.lua:195", text)


    REAL_070 = os.path.join(FIX, "logs", "retest_070", "Lua.log")

    @unittest.skipUnless(os.path.exists(REAL_070), "local fixture: the 0.7.0 re-test log (*.log is not committed)")
    def test_real_070_retest_is_explained(self):
        """The 0.7.0 re-test (research/retest_0.7): each CHECK names its cause (0.7.2)."""
        code, text = self.run_summary(["--retest", "--log", self.REAL_070])
        self.assertEqual(code, 1)
        self.assertIn("S13 NOT PRESSED", text)
        self.assertIn("Step  3  PASS", text)
        self.assertIn("(S13 not pressed: 3 sends expected)", text)
        self.assertIn("NOT VERIFIED: Volunteer record 2 left B's land (at 50,34)", text)
        self.assertIn("grace 5 -> 4 is correct", text)
        self.assertIn("LEVEL BACK 1 TURN(S) LATE", text)
        self.assertIn("TEST UNIT KILLED", text)
        self.assertIn("3 combat event(s), all PASS", text)
        self.assertIn("Errors: none", text)

    def test_s13_not_pressed(self):
        with open(self.LOG, encoding="utf-8") as fh:
            lines = [ln for ln in fh.read().splitlines() if "FROM_LAND" not in ln and "scn_inland" not in ln
                     and "id=4 " not in ln and "record 4 " not in ln]
        tmp = tempfile.mkdtemp()
        try:
            path = os.path.join(tmp, "Lua.log")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(os.linesep.join(lines))
            code, text = self.run_summary(["--retest", "--log", path])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        self.assertIn("Step  2  CHECK", text)
        self.assertIn("S13 NOT PRESSED", text)
        self.assertIn("Step  3  PASS", text)
        self.assertIn("all 3 sent unit(s) arrived (S13 not pressed", text)


class TestSummarizeS14(unittest.TestCase):
    """summarize_efv_log.py --s14 and the badge-audit line (EFV_Dev 0.7.2-dev.1)."""

    GOOD = [
        "EFV_Gameplay: [EFV][T1][Init] EFV_Gameplay loading version=0.7.2-dev",
        "EFV_Dev_Gameplay: [EFV][T1][Dev] init: EFV_Dev gameplay loaded; registered GameEvents.EFV_Dev; version=0.7.2-dev.1 for EFV 0.7.2-dev EFV=0.7.2-dev",
        "EFV_Dev_Gameplay: [EFV][CHECK] SETUP PASS T2 B=P1 Rome (basis FRIEND, Volunteers FRIEND_OB), F=P2 Arabia",
        "EFV_Dev_Panel: [EFV][CHECK] BADGE_AUDIT PASS T2 (turn start) 0 VEF tag(s), each on its record's live unit; tracker: 0 on-map row(s)",
        "EFV_Dev_Gameplay: [EFV][CHECK] MUT_DEATH INFO T2 copy 1: record 1 P0/131075 (slot 3) UNIT_SWORDSMAN at 38,27 damage 80",
        "EFV_Dev_Gameplay: [EFV][CHECK] MUT_DEATH INFO T2 2 Volunteer Swordsman(s) of yours in MUTINY at 80 damage next to P2 Arabia's land",
        "EFV_Dev_Gameplay: [EFV][CHECK] MUT_DEATH PASS T3 copy 1 (record 1, 38,27): record closed, Swordsman gone; on the tile now: P63/131076 (slot 4) UNIT_WARRIOR",
        "EFV_Dev_Gameplay: [EFV][CHECK] MUT_DEATH PASS T3 copy 2 (record 2, 42,28): record closed, Swordsman gone; on the tile now: nothing",
        "EFV_Dev_Panel: [EFV][CHECK] BADGE_AUDIT PASS T3 (turn start) 0 VEF tag(s), each on its record's live unit; tracker: 0 on-map row(s)",
    ]

    def run_lines(self, lines):
        tmp = tempfile.mkdtemp()
        try:
            path = os.path.join(tmp, "Lua.log")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(os.linesep.join(lines))
            out = io.StringIO()
            old = sys.stdout
            sys.stdout = out
            try:
                code = summarize_efv_log.main(["--s14", "--log", path, "--db", os.path.join(FIX, "no_such.sqlite")])
            finally:
                sys.stdout = old
            return code, out.getvalue()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_good(self):
        code, text = self.run_lines(self.GOOD)
        self.assertEqual(code, 0, text)
        for n in range(1, 5):
            self.assertIn("Step  %d  PASS" % n, text)
        self.assertIn("Badge audit: PASS 2 audit line(s)", text)

    def test_glitch_is_caught(self):
        lines = [ln.replace("MUT_DEATH PASS T3 copy 1 (record 1, 38,27): record closed, Swordsman gone",
                            "MUT_DEATH FAIL T3 copy 1 (record 1, 38,27): a unit of yours stands there: P0/196611 (slot 3) UNIT_WARRIOR")
                 for ln in self.GOOD]
        lines.append("EFV_Dev_Panel: [EFV][CHECK] BADGE_AUDIT FAIL T3 (unit killed) flag P0/131075 (unit P0/196611 UNIT_WARRIOR): "
                     "the flag's unit is another unit")
        code, text = self.run_lines(lines)
        self.assertEqual(code, 1)
        self.assertIn("Step  2  CHECK", text)
        self.assertIn("a unit of yours stands there", text)
        self.assertIn("Step  4  CHECK", text)
        self.assertIn("Badge audit: CHECK 1 of 3 audit line(s) FAIL", text)

    def test_no_verdict_yet(self):
        code, text = self.run_lines(self.GOOD[:6])
        self.assertIn("no verdict for copy 1 yet: End Turn once more", text)


class TestOfflineRunnerClassify(unittest.TestCase):
    """tests/offline/run_tests.py: XFAIL only for an explicit, WP/phase-named mark (Phase 5)."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, os.path.join(os.path.dirname(L.TOOLS_DIR), "tests", "offline"))
        import run_tests  # noqa: E402
        cls.rt = run_tests

    def test_stub_hit_is_not_an_excuse(self):
        status, detail, _ = self.rt.classify(False, "ASSERT boom", None, ["EFV_Entrust.CleanupSnapshots"])
        self.assertEqual(status, "FAIL")
        self.assertIn("not an excuse", detail)

    def test_explicit_mark(self):
        self.assertEqual(self.rt.classify(False, "x", "Phase 6 (WP6.1): Entrust", [])[0], "XFAIL")
        self.assertEqual(self.rt.classify(True, "", "WP6.2 popup", [])[0], "XPASS")
        self.assertEqual(self.rt.classify(True, "", None, ["EFV_X.Y"])[0], "PASS")

    def test_mark_must_name_pending_work(self):
        status, detail, xfail = self.rt.classify(False, "x", "flaky", [])
        self.assertEqual((status, xfail), ("FAIL", None))
        self.assertIn("names no pending work package", detail)
        self.assertEqual(self.rt.classify(True, "", "someday", [])[0], "FAIL")


class TestSummarizeV103(unittest.TestCase):
    """summarize_efv_log.py --v103 (the VEF 1.0.3 session, EFV_Dev 1.0.3.2)."""

    P = "EFV_Dev_Gameplay: [EFV][CHECK] "
    U = "EFV_Dev_Panel: [EFV][CHECK] "
    GOOD = [
        "EFV_Gameplay: [EFV][T1][Init] EFV_Gameplay loading version=1.0.3",
        "EFV_Dev_Gameplay: [EFV][T1][Dev] init: EFV_Dev gameplay loaded; registered GameEvents.EFV_Dev; version=1.0.3.2 for EFV 1.0.3 EFV=1.0.3",
        P + "SETUP PASS T2 B=P1 Rome (basis FRIEND, Volunteers FRIEND_OB), F=P2 Arabia",
        P + "TRACKER_PREP INFO T2 4 record(s) in transit: INBOUND record 1 VEF-IN (P2 Arabia -> P0 Rome); they are removed when you end this turn",
        U + "TRACKER_LABELS PASS T2 INBOUND record 1 (VEF-IN, From Arabia): tracker shows 'Inbound' (expected 'Inbound')",
        U + "TRACKER_LABELS PASS T2 summary: 4/4 rows as expected (received: Inbound, Departed; sent: Outbound, Returning)",
        P + "ENTRUST_CS INFO T2 3 Tanks next to P5 Geneva's only city at 40,12",
        U + "ENTRUST_CS_UI PASS T2 city-state city captured: old owner Geneva, snapshot recipients Hungary, China, partners Hungary, China, button enabled for Hungary, China",
        P + "ENTRUST_MAJOR INFO T2 3 Tanks next to P7 Korea's city at 16,12",
        U + "ENTRUST_MAJOR_UI PASS T2 living major's city captured: old owner Korea, snapshot recipients none, partners Hungary, China, button greyed (ENTRUST_NO_PARTNER)",
        P + "CANCEL_PREP INFO T2 record 5 CS_EXPEDITIONARY to P4 Kabul CS_TAKEN origin 11,10 expected refund 0; end the turn",
        U + "VSPIKE_V0 PASS T2 V0 control (route B, one PROMOTE per turn): 1 promotion(s) in the first turn, then PROMOTE is not offered (moves 0)",
        U + "VSPIKE_V1 PASS T2 V1 hidden keep-moves ability + chained PROMOTE: 3/3 promotions in the first turn, level 4 (want 4), moves 2",
        U + "VSPIKE_V1_OFF PASS T2 ability removed, one normal promotion ended the unit's turn again (moves 0)",
        U + "VSPIKE_V2 PASS T2 V2 moves restored after each promotion: 3/3 promotions in the first turn, level 4 (want 4), moves 2",
        U + "VSPIKE_V3 CHECK T2 V3 level-adjust ability + SetPromotion + XP: level 1 (want 4), XP 15/15 (want XP 90)",
        P + "ENTRUST_CS PASS T3 the city-state's city now belongs to P1 Hungary (entrusted); P5 Geneva alive=false, B was at war with it=false",
        P + "ENTRUST_MAJOR PASS T3 the city is still yours: nobody could take it (P7 Korea alive=true, 1 city(ies) left)",
        P + "CANCEL PASS T3 record 5 CS_TAKEN: back at 11,10 ring 0 (expected ring 0) moves=0 (expected 0) refund expected 0 of fee 0",
        P + "CANCEL_PREP INFO T3 record 6 VOLUNTEER to P1 Hungary PARTNER_ENDED origin 12,10 (start tile blocked by VEF-BLOCK) expected refund 9; end the turn",
        P + "CANCEL PASS T4 record 6 PARTNER_ENDED: back at 12,11 ring 1 (expected ring 1) moves=0 (expected 0) refund expected 9 of fee 18",
        U + "VSPIKE_V0 INFO T4 V0 control (route B, one PROMOTE per turn): all 3 promotions back by turn 4 (3 turns), level 4",
    ]

    def run_lines(self, lines):
        tmp = tempfile.mkdtemp()
        try:
            path = os.path.join(tmp, "Lua.log")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(os.linesep.join(lines))
            out = io.StringIO()
            old = sys.stdout
            sys.stdout = out
            try:
                code = summarize_efv_log.main(["--v103", "--log", path, "--db", os.path.join(FIX, "no_such.sqlite")])
            finally:
                sys.stdout = old
            return code, out.getvalue()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_good(self):
        code, text = self.run_lines(self.GOOD)
        self.assertEqual(code, 0, text)
        self.assertEqual(len(summarize_efv_log.V103_STEPS), 6)
        for n in range(1, 7):
            self.assertIn("Step  %d  PASS" % n, text)
        self.assertIn("VEF 1.0.3, VEF Dev 1.0.3.2", text)
        self.assertIn("Veteran spike (findings, not pass/fail):", text)
        self.assertIn("V3     CHECK", text)
        self.assertIn("all 3 promotions back by turn 4", text)

    def test_missing_second_cancel_and_label_fail(self):
        lines = [ln for ln in self.GOOD if "PARTNER_ENDED:" not in ln]
        lines = [ln.replace("TRACKER_LABELS PASS T2 summary: 4/4", "TRACKER_LABELS FAIL T2 summary: 3/4") for ln in lines]
        code, text = self.run_lines(lines)
        self.assertEqual(code, 1)
        self.assertIn("Step  2  CHECK", text)
        self.assertIn("Step  6  CHECK", text)
        self.assertIn("End Turn once more", text)


if __name__ == "__main__":
    L.configure_stdout()
    unittest.main(verbosity=2)
