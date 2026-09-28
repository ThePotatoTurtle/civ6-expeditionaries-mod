#!/usr/bin/env python3
"""run_tests.py - T2 offline harness for the EFV mod (PLAN 5.1 WP T2, PLAN 6.5).

Loads EFV/Scripts/*.lua into a fake Civ VI gameplay engine running on lupa's Lua 5.1
runtime (tests/offline/lib/fake_engine.lua + lib/harness.lua) and runs the tests in
tests/offline/test_*.lua. Every test gets a fresh Lua state.

Usage:
    python tests/offline/run_tests.py                 # syntax check + all tests
    python tests/offline/run_tests.py -k fee          # only tests whose file/name contains "fee"
    python tests/offline/run_tests.py -v              # print logs/tracebacks of failures and xfails
    python tests/offline/run_tests.py --echo -k name  # stream the Lua log while running
    python tests/offline/run_tests.py --list          # list tests
    python tests/offline/run_tests.py --regen         # rebuild data/gameinfo_data.lua from the DB

Results:
    PASS   test passed.
    FAIL   assertion failed / Lua error / EFV logged ERROR lines (swallowed by its pcalls)
           in any test that is not explicitly marked expected-fail. Hitting an EFV stub
           ("[Stub] X not implemented") never excuses a failure; it is only shown as a hint.
    XFAIL  failed, and the test is explicitly marked expected-fail with a reason that names
           the pending work package or phase:
               test("name", fn, xfail("Phase 6 (WP6.1): Entrust gameplay"))
           (xfail(reason) is the harness helper for opts { xfail = reason }). A mark whose
           reason names no "WPx.y" / "Phase N" is rejected (FAIL).
    XPASS  marked xfail but passed (remove the mark).
Exit code: 0 if no FAIL and no syntax error, 1 otherwise, 2 on harness setup problems.

Test file formats:
    native  (first line contains "@harness native"): tests call test(name, fn, opts)
            and build their own world with H.world / H.baseScenario and H.loadEFV.
    foreign (any other test_*.lua, e.g. WP1.2's test_records.lua): loaded into a default
            world with EFV already loaded; test(name, fn) registrations, a returned table
            of functions, or the plain file run (pass = no error) are all accepted.

GameInfo comes from the game's cached DB (Cache/DebugGameplay.sqlite), exported once to
tests/offline/data/gameinfo_data.lua (regenerated when the DB is newer). Text comes from
EFV/Data/EFV_Text.xml. Notification Types missing from the DB are synthesised from
EFV/Data/*.sql and EFV_Config.lua so EFV_Notify can resolve hashes before WP1.6 lands.
"""
from __future__ import annotations

import argparse
import os
import re
import sqlite3
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
DB_DEFAULT = Path(os.path.expandvars(
    r"S:\Libraries\Documents\My Games\Sid Meier's Civilization VI\Cache\DebugGameplay.sqlite"))
DATA_LUA = HERE / "data" / "gameinfo_data.lua"

# Search order for include(name) (engine: ImportFiles are flat by name).
INCLUDE_DIRS = ["EFV/Scripts", "EFV/UI", "EFV_Dev/Scripts", "EFV_Dev/UI", "tests/offline/lib"]
SYNTAX_DIRS = ["EFV", "EFV_Dev", "tests/offline"]

# table -> (primary key column, row filter SQL or None)
EXPORT_TABLES = {
    "Units": ("UnitType", None),
    "Units_XP2": ("UnitType", None),
    "GameSpeeds": ("GameSpeedType", None),
    "GlobalParameters": ("Name", None),
    "UnitPromotions": ("UnitPromotionType", None),
    "UnitPromotionClasses": ("PromotionClassType", None),
    "Resources": ("ResourceType", None),
    "DiplomaticStates": ("StateType", None),
    "Maps": ("MapSizeType", None),
    "UnitUpgrades": ("Unit", None),
    # 0.5.2 (Session F item 3): unique-unit replacements and the traits that
    # grant them (only the unit-granting trait rows, to keep the file small).
    "UnitReplaces": ("CivUniqueUnitType", None),
    "CivilizationTraits": ("TraitType", "TraitType IN (SELECT TraitType FROM Units WHERE TraitType IS NOT NULL)"),
    "LeaderTraits": ("TraitType", "TraitType IN (SELECT TraitType FROM Units WHERE TraitType IS NOT NULL)"),
    "Types": ("Type", "Kind IN ('KIND_NOTIFICATION','KIND_UNIT','KIND_GAMESPEED','KIND_PROMOTION',"
                      "'KIND_RESOURCE','KIND_MAPSIZE','KIND_DIPLOMATIC_STATE')"),
}


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def fnv1a_signed(s: str) -> int:
    h = 2166136261
    for ch in s.encode("utf-8"):
        h ^= ch
        h = (h * 16777619) % 4294967296
    return h - 4294967296 if h >= 2147483648 else h


def lua_quote(s: str) -> str:
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif o < 32 or o == 127:
            out.append("\\%03d" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def lua_value(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    return lua_quote(str(v))


def export_gameinfo(db: Path, out: Path):
    con = sqlite3.connect("file:%s?mode=ro" % db.as_posix(), uri=True)
    type_hash = {}
    for t, h in con.execute("SELECT Type, Hash FROM Types"):
        type_hash[t] = h
    lines = ["-- Generated by tests/offline/run_tests.py from %s. Do not edit." % db.name, "return {"]
    for table, (pk, where) in EXPORT_TABLES.items():
        cols = list(con.execute("PRAGMA table_info(%s)" % table))
        if not cols:
            continue
        names = [c[1] for c in cols]
        booleans = {c[1] for c in cols if (c[2] or "").upper() == "BOOLEAN"}
        sql = "SELECT * FROM %s" % table + (" WHERE " + where if where else "") + " ORDER BY rowid"
        lines.append("  %s = { pk = %s, rows = {" % (table, lua_quote(pk)))
        for row in con.execute(sql):
            fields = []
            rec = dict(zip(names, row))
            for k in names:
                v = rec[k]
                if v is None:
                    continue
                if k in booleans:
                    v = bool(v)
                fields.append("%s=%s" % (k, lua_value(v)))
            if "Hash" not in rec:
                key = rec.get(pk)
                if key is not None:
                    fields.append("Hash=%d" % type_hash.get(key, fnv1a_signed(str(key))))
            lines.append("    {" + ",".join(fields) + "},")
        lines.append("  } },")
    lines.append("}")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    con.close()


def load_text() -> dict:
    texts = {}
    for path in sorted((ROOT / "EFV" / "Data").glob("*.xml")):
        try:
            tree = ET.parse(path)
        except ET.ParseError as e:
            print("WARN: cannot parse %s: %s" % (path.name, e))
            continue
        for row in tree.iter():
            if row.tag not in ("Row", "Replace"):
                continue
            tag = row.get("Tag")
            text_el = row.find("Text")
            text = text_el.text if text_el is not None else row.get("Text")
            if tag and text is not None:
                texts[tag] = text
    return texts


def extra_types() -> list:
    names = set()
    for path in list((ROOT / "EFV" / "Data").glob("*.sql")) + [ROOT / "EFV" / "Scripts" / "EFV_Config.lua"]:
        if path.exists():
            names.update(re.findall(r"EFV_NOTIF_[A-Z0-9_]+", path.read_text(encoding="utf-8", errors="replace")))
    names.add("EFV_NOTIF_LAPSE_CANCELLED")  # orchestrator call (DECISIONS, designer answers)
    return sorted(n for n in names if not n.endswith("_"))


def read_rel(rel):
    p = ROOT / rel
    if p.is_file():
        return p.read_text(encoding="utf-8", errors="replace")
    return None


def find_include(name):
    name = str(name)
    base = name[:-4] if name.lower().endswith(".lua") else name
    for d in INCLUDE_DIRS:
        p = ROOT / d / (base + ".lua")
        if p.is_file():
            return "%s/%s.lua" % (d, base)
    return None


# ---------------------------------------------------------------------------
# Lua runtime
# ---------------------------------------------------------------------------
class Env:
    def __init__(self, echo=False):
        import lupa.lua51 as lua51
        self.lua51 = lua51
        self.echo = echo
        self.text = load_text()
        self.types = extra_types()

    def runtime(self):
        rt = self.lua51.LuaRuntime(unpack_returned_tuples=True)
        g = rt.globals()
        g["__py_read"] = read_rel
        g["__py_find"] = find_include
        g["__py_echo"] = lambda s: print("      | " + str(s))
        g["FAKE_TEXT"] = rt.table_from(self.text)
        g["FAKE_EXTRA_TYPES"] = rt.table_from(self.types)
        rt.execute(BOOT)
        g["FAKE"]["echo"] = self.echo
        return rt


BOOT = r"""
local function load(rel)
  local src = __py_read(rel)
  if src == nil then error("missing " .. rel) end
  local f, e = loadstring(src, "@" .. rel)
  if not f then error(e) end
  return f()
end
__load = load
load("tests/offline/lib/fake_engine.lua")
FAKE.LoadGameInfo(load("tests/offline/data/gameinfo_data.lua"), FAKE_EXTRA_TYPES)
load("tests/offline/lib/harness.lua")

function __load_test_file(rel)
  local src = __py_read(rel)
  local f, e = loadstring(src, "@" .. rel)
  if not f then return false, e end
  local ok, ret = xpcall(f, debug.traceback)
  if not ok then return false, ret end
  __file_return = ret
  return true, nil
end

function __test_names()
  local out = {}
  for i, t in ipairs(TESTS) do out[i] = t.name end
  if #out == 0 and type(__file_return) == "table" then
    for _, k in ipairs(FAKE.SortedKeys(__file_return)) do
      if type(__file_return[k]) == "function" then out[#out + 1] = "@" .. tostring(k) end
    end
  end
  return out
end

function __test_opts(name)
  for _, t in ipairs(TESTS) do
    if t.name == name then
      return t.opts.xfail, t.opts.allowErrors and true or false
    end
  end
  return nil, false
end

function __run_named(name)
  local fn
  if string.sub(name, 1, 1) == "@" then
    fn = __file_return[string.sub(name, 2)]
    if type(fn) ~= "function" then
      local k = tonumber(string.sub(name, 2))
      fn = k and __file_return[k]
    end
  else
    for _, t in ipairs(TESTS) do if t.name == name then fn = t.fn end end
  end
  if fn == nil then return false, "test not found: " .. name end
  if FAKE.bodyStart == nil then FAKE.bodyStart = #FAKE.log end
  local ok, err = xpcall(fn, debug.traceback)
  return ok, err
end

function __log_lines(from)
  local out = {}
  for i = (from or 0) + 1, #FAKE.log do out[#out + 1] = FAKE.log[i] end
  return out
end

function __default_world()
  H.world{}
  H.loadEFV()
end
"""


def lua_list(tbl):
    if tbl is None:
        return []
    out = []
    i = 1
    while True:
        v = tbl[i]
        if v is None:
            break
        out.append(v)
        i += 1
    return out


def is_native(path: Path) -> bool:
    with open(path, encoding="utf-8", errors="replace") as f:
        return "@harness native" in f.readline()


# ---------------------------------------------------------------------------
# Syntax check (Lua 5.1 loadstring over every .lua file of the project parts we own/test)
# ---------------------------------------------------------------------------
def syntax_check(env) -> list:
    rt = env.lua51.LuaRuntime(unpack_returned_tuples=True)
    comp = rt.eval("function(src, name) local f, e = loadstring(src, name) return f ~= nil, e end")
    errors, count = [], 0
    for d in SYNTAX_DIRS:
        base = ROOT / d
        if not base.exists():
            continue
        for p in sorted(base.rglob("*.lua")):
            if "data" in p.relative_to(ROOT).parts and p.name == "gameinfo_data.lua":
                continue
            count += 1
            rel = p.relative_to(ROOT).as_posix()
            ok, err = comp(p.read_text(encoding="utf-8", errors="replace"), "@" + rel)
            if not ok:
                errors.append("%s: %s" % (rel, err))
            # Havok-only type annotation check (PLAN 6.1): "local x : number"
            src = p.read_text(encoding="utf-8", errors="replace")
            for ln, line in enumerate(src.splitlines(), 1):
                code = line.split("--", 1)[0]
                if re.search(r"\blocal\s+\w+\s*:\s*\w+", code):
                    errors.append("%s:%d: type annotation (Havok-only syntax)" % (rel, ln))
    return count, errors


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------
class Result:
    def __init__(self, file, name, status, detail="", log=None, stubs=None, xfail=None):
        self.file, self.name, self.status, self.detail = file, name, status, detail
        self.log = log or []
        self.stubs = stubs or []
        self.xfail = xfail


# An xfail reason must name the pending work (a PLAN 5.x work package or phase).
XFAIL_REASON = re.compile(r"\bWP\d+(\.\d+)?\b|\bPhase \d+\b")


def stub_names(lines):
    names = []
    for l in lines:
        m = re.search(r"\[Stub\] (\S+)", l)
        if m:
            n = m.group(1).split("(")[0]
            if n not in names:
                names.append(n)
    return names


def error_lines(lines):
    return [l for l in lines if re.search(r"\]\[[^\]]+\] ERROR ", l) or "Runtime Error" in l]


def run_one(env, rel, native, name):
    rt = env.runtime()
    g = rt.globals()
    if not native:
        g["__default_world"]()
    ok, err = g["__load_test_file"](rel)
    if not ok:
        return Result(rel, name, "FAIL", "test file failed to load: %s" % err)
    xfail, allow_errors = g["__test_opts"](name)
    ok, err = g["__run_named"](name)
    body = lua_list(g["__log_lines"](g["FAKE"]["bodyStart"] or 0))
    stubs = stub_names(body)
    handler_errors = lua_list(g["FAKE"]["handlerErrors"])
    detail = ""
    passed = bool(ok)
    if not passed:
        detail = str(err)
    elif not allow_errors:
        errs = error_lines(body)
        if errs:
            passed = False
            detail = "EFV logged errors (swallowed by pcall):\n" + "\n".join(errs[:8])
    if passed and handler_errors and not allow_errors:
        passed = False
        detail = "event handler errors:\n" + "\n".join(handler_errors[:8])
    status, detail, xfail = classify(passed, detail, xfail, stubs)
    return Result(rel, name, status, detail, body, stubs, xfail)


def classify(passed, detail, xfail, stubs):
    """Result status of one test -> (status, detail, xfail).

    XFAIL only for a failing test with an explicit xfail mark whose reason names
    the pending work package or phase. Stubs hit during the test body never make
    a failure expected (Phase 5 fix: they used to turn ANY failure into XFAIL,
    e.g. a full-turn test that passes the Entrust stub in pipeline step 0a)."""
    if xfail is not None and not XFAIL_REASON.search(str(xfail)):
        passed = False
        detail = ("xfail mark %r names no pending work package ('WPx.y') or phase ('Phase N')\n"
                  % str(xfail)) + (detail or "")
        xfail = None
    if passed:
        return ("XPASS" if xfail else "PASS"), detail, xfail
    if xfail:
        return "XFAIL", "[marked xfail: %s] %s" % (xfail, detail), xfail
    if stubs:
        detail = "(stubs hit, not an excuse: %s)\n%s" % (", ".join(stubs[:4]), detail)
    return "FAIL", detail, None


def is_standalone(path: Path) -> bool:
    """Self-contained test scripts with their own fake engine (WP1.2's test_records.lua):
    they read EFV_ROOT and report "PASS name" / "FAIL name: err" and "RESULT passed=n failed=m"."""
    src = path.read_text(encoding="utf-8", errors="replace")
    return "EFV_ROOT" in src and "RESULT passed=" in src


def run_standalone(env, path: Path):
    rel = path.relative_to(ROOT).as_posix()
    lines = []
    rt = env.lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.globals()["EFV_ROOT"] = ROOT.as_posix()
    rt.globals()["print"] = lambda *a: lines.append("	".join("nil" if x is None else str(x) for x in a))
    try:
        chunk = rt.eval("function(src, name) return assert(loadstring(src, name)) end")(
            path.read_text(encoding="utf-8", errors="replace"), "@" + rel)
        chunk()
    except Exception as exc:
        lines.append("ERROR %s" % exc)
    results, summary = [], None
    for line in lines:
        # re.S: a FAIL message may span several lines (it used to be dropped).
        m = re.match(r"(PASS|FAIL) (.*)", line, re.S)
        if m:
            name, detail = m.group(2), ""
            if m.group(1) == "FAIL" and ": " in name:
                name, detail = name.split(": ", 1)
            results.append(Result(rel, name, m.group(1), detail, lines))
        m = re.match(r"RESULT passed=(\d+) failed=(\d+)", line)
        if m:
            summary = (int(m.group(1)), int(m.group(2)))
    if summary is None:
        errs = [l for l in lines if l.startswith("ERROR")]
        results.append(Result(rel, "<script>", "FAIL", "no RESULT line (script aborted) " + " ".join(errs[:3]), lines))
    elif summary[1] > sum(1 for r in results if r.status == "FAIL"):
        results.append(Result(rel, "<summary>", "FAIL", "RESULT reports %d failure(s) the runner did not parse" % summary[1], lines))
    notes = [l for l in lines if l.startswith("NOTE")]
    return results, notes


def discover(env, path: Path):
    rel = path.relative_to(ROOT).as_posix()
    native = is_native(path)
    rt = env.runtime()
    g = rt.globals()
    if not native:
        g["__default_world"]()
        mark = g["FAKE"]["bodyStart"] or 0
    ok, err = g["__load_test_file"](rel)
    if not ok:
        return rel, native, None, Result(rel, "<load>", "FAIL", "test file failed: %s" % err)
    names = lua_list(g["__test_names"]())
    if not names:
        if native:
            return rel, native, [], None
        body = lua_list(g["__log_lines"](mark))
        stubs = stub_names(body)
        errs = error_lines(body)
        status = "PASS" if not errs else "FAIL"  # a plain script cannot be marked xfail
        return rel, native, None, Result(rel, "<script>", status, "\n".join(errs[:8]), body, stubs)
    return rel, native, names, None


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-k", dest="filter", default=None, help="substring filter on file or test name")
    ap.add_argument("-v", "--verbose", action="store_true", help="details for FAIL and XFAIL")
    ap.add_argument("--echo", action="store_true", help="stream Lua print output while running")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--regen", action="store_true", help="re-export GameInfo from the DB")
    ap.add_argument("--db", default=str(DB_DEFAULT))
    ap.add_argument("--no-syntax", action="store_true")
    ap.add_argument("--show-xfail", action="store_true", help="print the failure line of XFAIL tests")
    a = ap.parse_args(argv)

    try:
        import lupa.lua51  # noqa: F401
    except Exception as e:  # pragma: no cover
        print("run_tests: lupa with Lua 5.1 is required (pip install lupa): %s" % e)
        return 2

    db = Path(a.db)
    if a.regen or not DATA_LUA.exists() or (db.exists() and db.stat().st_mtime > DATA_LUA.stat().st_mtime):
        if not db.exists():
            print("run_tests: gameplay DB not found: %s (and no cached %s)" % (db, DATA_LUA))
            if not DATA_LUA.exists():
                return 2
        else:
            export_gameinfo(db, DATA_LUA)
            print("run_tests: exported GameInfo from %s" % db)

    t0 = time.time()
    env = Env(echo=a.echo)
    syntax_errors = []
    if not a.no_syntax:
        n, syntax_errors = syntax_check(env)
        print("== Lua 5.1 syntax: %d files, %d error(s)" % (n, len(syntax_errors)))
        for e in syntax_errors:
            print("   SYNTAX " + e)

    files = sorted(HERE.glob("test_*.lua"))
    results = []
    for path in files:
        if not is_native(path) and is_standalone(path):
            rel = path.relative_to(ROOT).as_posix()
            if a.filter is not None and a.filter.lower() not in rel.lower():
                continue
            if a.list:
                print("== %s  (standalone; run as a whole)" % rel)
                continue
            print("== %s  (standalone, own fake engine)" % rel)
            sub, notes = run_standalone(env, path)
            for n in notes:
                print("         " + n)
            for r in sub:
                results.append(r)
                print("  %-6s %s" % (r.status, r.name))
                if r.status == "FAIL" and r.detail:
                    print("         " + r.detail.strip().splitlines()[0])
            continue
        rel, native, names, early = discover(env, path)
        if early is not None:
            if a.filter is None or a.filter.lower() in rel.lower():
                results.append(early)
                print("== %s%s" % (rel, "" if native else "  (foreign format)"))
                print("  %-6s %s" % (early.status, early.name))
            continue
        selected = [n for n in names if a.filter is None or a.filter.lower() in (rel + " " + n).lower()]
        if not selected:
            continue
        print("== %s%s" % (rel, "" if native else "  (foreign format)"))
        for name in selected:
            if a.list:
                print("         %s" % name)
                continue
            if a.echo:
                print("  ...    %s" % name)
            r = run_one(env, rel, native, name)
            results.append(r)
            extra = ""
            if r.status in ("XFAIL", "XPASS"):
                extra = "  [xfail: %s]" % r.xfail
            print("  %-6s %s%s" % (r.status, name, extra))
            show = r.status == "FAIL" or (a.verbose and r.status == "XFAIL") or (a.show_xfail and r.status == "XFAIL")
            if show and r.detail:
                lines = r.detail.strip().splitlines()
                limit = 40 if a.verbose else (2 if r.status == "XFAIL" else 12)
                for l in lines[:limit]:
                    print("         " + l)
            if a.verbose and r.status in ("FAIL", "XFAIL") and r.log:
                print("         -- log (last 25 lines) --")
                for l in r.log[-25:]:
                    print("         | " + l)
    if a.list:
        return 0
    counts = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
    dt = time.time() - t0
    print()
    print("== Summary: %d passed, %d failed, %d xfail (explicitly marked), %d xpass; %d tests in %.1fs%s" % (
        counts.get("PASS", 0), counts.get("FAIL", 0), counts.get("XFAIL", 0), counts.get("XPASS", 0),
        len(results), dt, ("; %d SYNTAX error(s)" % len(syntax_errors)) if syntax_errors else ""))
    if counts.get("XFAIL"):
        marks = {}
        for r in results:
            if r.status == "XFAIL":
                marks[str(r.xfail)] = marks.get(str(r.xfail), 0) + 1
        top = sorted(marks.items(), key=lambda kv: (-kv[1], kv[0]))[:12]
        print("   xfail marks (reason: tests): " + ", ".join("%s: %d" % kv for kv in top))
    return 1 if counts.get("FAIL") or syntax_errors else 0


if __name__ == "__main__":
    sys.exit(main())
