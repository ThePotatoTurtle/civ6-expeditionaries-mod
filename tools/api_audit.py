#!/usr/bin/env python3
"""api_audit.py - engine API usage audit for EFV (PLAN 6.3, 1.6, Appendix A).

Usage:
    python tools/api_audit.py <root> [--strict] [--info] [--regen] [--no-checklist]
    python tools/api_audit.py --regen            (only rebuild tools/api_allowlist.json + tools/.luacheckrc)

Allowlist:
    tools/api_allowlist.json        generated from PLAN.md Appendix A (auto-regenerated when PLAN.md changes)
    tools/api_allowlist_extra.json  manual additions / overrides (same shape; see README)

Per Lua file the context is G (gameplay), UI or both (shared), from the modinfo actions + include graph
(fallback: Scripts/ = G, UI/ = UI, EFV_Config/EFV_Util/EFV_Rules = both). Inside
`-- EFV:G-ONLY begin/end` and `-- EFV:UI-ONLY begin/end` regions the region's context applies.

Reports:
  ERROR  engine call / member / event not in the allowlist; call in a context it is not listed for;
         forbidden pattern (PLAN 1.6 / 6.3.5); state mutation inside an Events.* handler in gameplay;
         unknown function on a project module table (EFV_Util.Foo); UI OnStart without a GameEvents handler.
  WARN   call only LIKELY / NEW-VERIFY / pending an in-game test in that context (test ID given);
         GameInfo table that exists in the DB but is not in Appendix A; conditional registration in G; etc.
Exit code 1 on any ERROR (or WARN with --strict).
"""
from __future__ import annotations

import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import efvlib as L  # noqa: E402

ALLOWLIST_PATH = os.path.join(L.TOOLS_DIR, "api_allowlist.json")
EXTRA_PATH = os.path.join(L.TOOLS_DIR, "api_allowlist_extra.json")
LUACHECKRC_PATH = os.path.join(L.TOOLS_DIR, ".luacheckrc")

LEVEL_RANK = {"C": 3, "L": 2, "PENDING": 1, "NV": 0}
EVENT_ROOTS = {"GameEvents", "Events", "LuaEvents"}

LUA_STD = {
    "string": {"byte", "char", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep", "reverse", "sub", "upper"},
    "table": {"concat", "insert", "maxn", "remove", "sort"},
    "math": {"abs", "acos", "asin", "atan", "atan2", "ceil", "cos", "cosh", "deg", "exp", "floor", "fmod", "frexp",
             "huge", "ldexp", "log", "log10", "max", "min", "modf", "pi", "pow", "rad", "sin", "sinh", "sqrt", "tan", "tanh"},
    "coroutine": {"create", "resume", "running", "status", "wrap", "yield"},
    "os": set(),
}
STRING_METHODS = LUA_STD["string"]
LUA_BUILTIN_FUNCS = {"assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "print", "rawequal", "rawget",
                     "rawset", "select", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "collectgarbage"}

# Calls that mutate synchronised state: never inside an Events.* handler in gameplay (PLAN 1.6, 6.3.5)
ASYNC_FORBIDDEN = {
    "GetRandNum": "synced RNG", "Create": "unit creation", "Destroy": "unit removal", "ChangeGoldBalance": "gold change",
    "SetProperty": "property write", "InitUnit": "unit creation", "Kill": "unit removal", "TransferCity": "city transfer",
    "SetDamage": "unit change", "ChangeDamage": "unit change", "ChangeExperience": "unit change",
    "SetPromotion": "unit change", "ChangeResourceAmount": "resource change", "FinishMoves": "unit change",
    "SetVeteranName": "unit change", "SetMilitaryFormation": "unit change", "SendNotification": "notification",
}
DV13_HANDLER_SUFFIX = "OnPlayerDefeatHint"
# backticked words in Appendix A that are not engine APIs
NON_API_WORDS = {"ImportFiles", "AddGameplayScripts", "AddUserInterfaces", "ReplaceUIScript", "UpdateDatabase"}


# ===========================================================================
# Allowlist generation from PLAN.md Appendix A
# ===========================================================================
def _level_of(s):
    s = s.strip()
    tests = re.findall(r"T\d+\+?", s)
    w = s.split()[0] if s.split() else ""
    w = w.strip("[(")
    if w in ("C", "L", "NV"):
        return w, tests
    if tests:
        return "PENDING", tests
    return "C", tests


def _parse_status(status):
    general, per = None, {}
    for part in [p.strip() for p in status.split(";") if p.strip()]:
        if part.startswith("G fallback"):
            continue
        m = re.match(r"^(UI|G)\s+(.*)$", part)
        if m and m.group(2) and m.group(2)[0] in "CLN[":
            per[m.group(1)] = _level_of(m.group(2))
        else:
            general = _level_of(part)
    return general, per


def _strip_args(text):
    prev = None
    while prev != text:
        prev = text
        text = re.sub(r"\([^()]*\)", "()", text)
    text = re.sub(r"\[[^\[\]]*\]", "[]", text)
    text = re.sub(r"\s*/\s*", "/", text)
    text = text.replace("<X>", "*")
    return text.strip()


def _split_chain(text):
    """'Players[]:GetUnits():FindID()' -> ['Players', '[]', ':GetUnits', '()', ':FindID', '()']"""
    parts = []
    i = 0
    m = re.match(r"(\.\.\.|[A-Za-z_][\w*]*)", text)
    if not m:
        return None
    parts.append(m.group(1))
    i = m.end()
    while i < len(text):
        m = re.match(r"([.:])([A-Za-z_][\w*]*)|(\[\])|(\(\))", text[i:])
        if not m:
            break
        if m.group(1):
            parts.append(m.group(1) + m.group(2))
        else:
            parts.append(m.group(3) or m.group(4))
        i += m.end()
    return parts


def _prefix_of(chain_text):
    k = max(chain_text.rfind("."), chain_text.rfind(":"))
    return chain_text[:k + 1] if k >= 0 else ""


def _expand_slashes(text, prev_prefix, events_row):
    pieces = text.split("/")
    first = pieces[0]
    if first and first[0] in ".:" and prev_prefix:
        first = prev_prefix.rstrip(".:") + first
    elif not re.search(r"[.:]", first) and prev_prefix and not events_row:
        first = prev_prefix + first
    out = [first]
    base_prefix = _prefix_of(first)
    for p in pieces[1:]:
        p = p.strip()
        if not p:
            continue
        if re.search(r"[.:]", p):
            out.append(p)
        elif not base_prefix:
            # bare names: suffix replacement for UnitMovementPointsChanged/Cleared/Restored
            if re.fullmatch(r"[A-Z][a-z]+", p):
                words = re.findall(r"[A-Z][a-z0-9]*|[A-Z]+(?![a-z])", first)
                out.append("".join(words[:-1]) + p if len(words) > 1 else p)
            else:
                out.append(p)
        else:
            out.append(base_prefix + p)
    return out


def _add_entry(table, key, ctxs, ref, note=None):
    e = table.setdefault(key, {"ctx": {}, "refs": []})
    if ref and ref not in e["refs"]:
        e["refs"].append(ref)
    for c, (lvl, tests) in ctxs.items():
        cur = e["ctx"].get(c)
        if cur is None or LEVEL_RANK[lvl] > LEVEL_RANK[cur["level"]]:
            e["ctx"][c] = {"level": lvl, "tests": sorted(set(tests))}
        elif LEVEL_RANK[lvl] == LEVEL_RANK[cur["level"]]:
            cur["tests"] = sorted(set(cur["tests"]) | set(tests))
    if note:
        e["note"] = note


def appendix_a_rows(plan_text):
    m = re.search(r"^## Appendix A.*?$(.*?)^## ", plan_text, re.S | re.M)
    if not m:
        raise SystemExit("api_audit: PLAN.md has no '## Appendix A' section")
    rows = []
    for line in m.group(1).splitlines():
        if not re.match(r"^\|\s*[AU]\d+\s*\|", line):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5:
            continue
        rows.append(cells[:5])
    return rows


def build_allowlist(plan_path=L.PLAN_PATH):
    text = L.read_file(plan_path)
    rows = appendix_a_rows(text)
    al = {"globals": {}, "static": {}, "methods": {}, "events": {}, "gameinfo": {}}
    for rid, call, ctx_cell, ref, status in rows:
        general, per = _parse_status(status)
        c = ctx_cell.strip()
        base = set()
        both_only = None
        read_both = False
        probe_g = False
        if c.startswith("both"):
            base = {"G", "UI"}
            mm = re.search(r"\((\w+)\)", c)
            if mm:
                both_only = mm.group(1)
                base = {"G"}
        elif c.startswith("G"):
            base = {"G"}
            read_both = "read both" in c
        elif c.startswith("UI"):
            base = {"UI"}
            probe_g = "G probe" in c
        events_row = call.startswith("UI events")
        prev_prefix = ""
        for mm in re.finditer(r"`([^`]+)`(?:\s*\((G|UI|both)\))?", call):
            raw, annot = mm.group(1).strip(), mm.group(2)
            if raw.startswith("[") or raw in NON_API_WORDS:
                continue
            if raw.replace(" ", "") in ("UI==nil",):
                _add_entry(al["globals"], "UI", {"G": ("C", []), "UI": ("C", [])}, rid, "bare `UI == nil` context test")
                continue
            stripped = _strip_args(raw)
            # engine names used inside argument lists: MapLayers.ANY, PlayerOperations.EXECUTE_SCRIPT, ...
            arg_items = []
            for am in re.finditer(r"\(([^()]*(?:\([^()]*\)[^()]*)*)\)", raw):
                for nm in re.finditer(r"\b([A-Z][A-Za-z]*(?:[.:][A-Za-z_]\w*)+)(\(\))?", am.group(1)):
                    arg_items.append(nm.group(1) + (nm.group(2) or ""))
            items = _expand_slashes(stripped, prev_prefix, events_row)
            for item in items + arg_items:
                parts = _split_chain(item)
                if not parts:
                    continue
                name_last = re.sub(r"^[.:]", "", parts[-1] if parts[-1] not in ("()", "[]") else
                                   next((p for p in reversed(parts) if p not in ("()", "[]")), parts[0]))
                if annot:
                    ctxs_set = {"G", "UI"} if annot == "both" else {annot}
                else:
                    ctxs_set = set(base)
                    if both_only and name_last == both_only:
                        ctxs_set = {"G", "UI"}
                    if read_both and name_last.startswith("Get"):
                        ctxs_set.add("UI")
                    if probe_g:
                        ctxs_set.add("G")
                ctxs = {}
                for cx in ctxs_set:
                    if cx in per:
                        ctxs[cx] = per[cx]
                    elif probe_g and cx == "G" and not annot:
                        ctxs[cx] = ("PENDING", general[1] if general else [])
                    elif general:
                        ctxs[cx] = general
                    else:
                        ctxs[cx] = ("C", [])
                _entries_from_chain(al, parts, ctxs, rid, events_row)
                if item in items:
                    prev_prefix = _prefix_of(item)
    al["_source"] = "PLAN.md Appendix A (generated by tools/api_audit.py --regen; do not edit, use api_allowlist_extra.json)"
    al["_plan_appendix_sha1"] = appendix_hash(text)
    al["_generated"] = datetime.date.today().isoformat()
    return al


def _entries_from_chain(al, parts, ctxs, rid, events_row):
    head = parts[0]
    if events_row and (len(parts) == 1 or (len(parts) == 2 and parts[1] == "()")):
        _add_entry(al["events"], "Events." + head, ctxs, rid)
        _add_entry(al["globals"], "Events", ctxs, rid)
        return
    is_root = head[0].isupper() and head != "..."
    if is_root:
        _add_entry(al["globals"], head, ctxs, rid)
    if head in EVENT_ROOTS:
        if len(parts) > 1 and parts[1].startswith("."):
            _add_entry(al["events"], head + parts[1], ctxs, rid)
        return
    if head == "GameInfo":
        if len(parts) > 1 and parts[1].startswith("."):
            _add_entry(al["gameinfo"], parts[1][1:], ctxs, rid)
        return
    if len(parts) == 1 or (len(parts) == 2 and parts[1] == "()"):
        if len(parts) == 2 and head != "...":
            _add_entry(al["static"], head, ctxs, rid)       # global function: include(), print()
            if not is_root:
                _add_entry(al["globals"], head, ctxs, rid)
        elif not is_root and head != "...":
            _add_entry(al["methods"], head, ctxs, rid)      # bare method name
        return
    after_call = False
    for k, p in enumerate(parts[1:], start=1):
        if p in ("()", "[]"):
            after_call = True
            continue
        name = p[1:]
        if p.startswith(":"):
            _add_entry(al["methods"], name, ctxs, rid)
            if is_root and k == 1:
                _add_entry(al["static"], head + p, ctxs, rid)
        elif p.startswith(".") and is_root and not after_call and k == 1:
            _add_entry(al["static"], head + p, ctxs, rid)
        elif p.startswith(".") and not is_root and k == 1 and head != "...":
            pass  # e.g. item.Field
        after_call = False


def appendix_hash(plan_text):
    m = re.search(r"^## Appendix A.*?$(.*?)^## ", plan_text, re.S | re.M)
    return hashlib.sha1((m.group(1) if m else "").encode("utf-8")).hexdigest()


def write_luacheckrc(al, extra):
    names = set(L.PLAN_ENGINE_GLOBALS) | set(al.get("globals", {})) | set(extra.get("globals", {})) | L.harvested_engine_globals()
    names = sorted(n for n in names if not n.startswith("_") and "*" not in n)
    lines = [
        "-- tools/.luacheckrc: generated by tools/api_audit.py --regen from PLAN.md 6.1 + Appendix A",
        "-- + api_allowlist_extra.json globals + engine_globals.json (harvest_engine_globals.py). Regenerate instead of editing.",
        "-- Project globals (EFV_* module tables etc.) are passed by check_lua.py via --globals,",
        "-- because luacheck checks each file on its own.",
        'std = "lua51"',
        "max_line_length = false",
        "unused_args = false",
        "read_globals = {",
    ]
    for n in names:
        lines.append('  "%s",' % n)
    lines.append("}")
    with open(LUACHECKRC_PATH, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def load_allowlist(regen=False, quiet=False):
    plan_text = L.read_file(L.PLAN_PATH) if os.path.exists(L.PLAN_PATH) else None
    al = L.load_json(ALLOWLIST_PATH, None)
    stale = al is None or (plan_text is not None and al.get("_plan_appendix_sha1") != appendix_hash(plan_text))
    extra = L.load_json(EXTRA_PATH, {})
    if (regen or stale) and plan_text is not None:
        al = build_allowlist()
        with open(ALLOWLIST_PATH, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(al, fh, indent=1, sort_keys=True)
        write_luacheckrc(al, extra)
        if not quiet:
            print("api_audit: regenerated %s from PLAN.md Appendix A (%d static, %d methods, %d events, %d GameInfo tables)" % (
                os.path.relpath(ALLOWLIST_PATH, L.PROJECT_DIR), len(al["static"]), len(al["methods"]), len(al["events"]), len(al["gameinfo"])))
    if al is None:
        raise SystemExit("api_audit: no allowlist and no PLAN.md")
    return merge_extra(al, extra)


def merge_extra(al, extra):
    merged = json.loads(json.dumps(al))
    for sect in ("globals", "static", "methods", "events", "gameinfo"):
        for key, e in extra.get(sect, {}).items():
            if key.startswith("_"):
                continue
            tgt = merged[sect].setdefault(key, {"ctx": {}, "refs": []})
            if e.get("replace"):
                tgt["ctx"] = {}
            for c, v in e.get("ctx", {}).items():
                if isinstance(v, str):
                    v = {"level": v, "tests": []}
                tgt["ctx"][c] = v
            for r in e.get("refs", []):
                if r not in tgt["refs"]:
                    tgt["refs"].append(r)
            if "only_paths" in e:
                tgt["only_paths"] = e["only_paths"]
            if "note" in e:
                tgt["note"] = e["note"]
    merged["_forbidden_extra"] = extra.get("forbidden", [])
    return merged


def lookup(table, key):
    if key in table:
        return table[key]
    for k, v in table.items():
        if "*" in k and fnmatch.fnmatchcase(key, k):
            return v
    return None


# ===========================================================================
# Audit
# ===========================================================================
class Auditor:
    def __init__(self, root, al, rep):
        self.root = os.path.abspath(root)
        self.al = al
        self.rep = rep
        self.proj = L.LuaProject(self.root)
        self.checklist = {}   # (key, ctx, level, tests) -> [locations]
        self.db_tables = self._db_tables()
        self.parsed = {}
        for f in self.proj.files:
            try:
                toks, comments = L.lex(self.proj.src[f])
            except L.LexError as e:
                rep.error(f, e.line, "lex", "cannot tokenize (%s); run check_lua.py" % e.msg)
                continue
            funcs = L.scan_functions(toks)
            self.parsed[f] = {
                "toks": toks, "comments": comments, "funcs": funcs,
                "chains": L.scan_chains(toks), "methods": L.scan_method_calls(toks),
                "locals": L.local_names(toks),
                "top": L.top_level_global_assignments(toks, funcs),
            }
        # every real engine global (harvested) is audited, so non-allowlisted ones are reported
        self.engine_roots = set(al["globals"]) | set(L.PLAN_ENGINE_GLOBALS) | L.harvested_engine_globals()
        self.project_methods = set()
        self.module_members = {}
        self._index_project()

    def _db_tables(self):
        if not os.path.exists(L.GAMEPLAY_DB):
            return None
        try:
            con = sqlite3.connect("file:%s?mode=ro" % L.GAMEPLAY_DB.replace("\\", "/"), uri=True)
            names = {r[0] for r in con.execute("select name from sqlite_master where type in ('table','view')")}
            con.close()
            return names
        except sqlite3.Error:
            return None

    def _index_project(self):
        for f, p in self.parsed.items():
            toks = p["toks"]
            for fd in p["funcs"]:
                if fd.name and ":" in fd.name:
                    self.project_methods.add(fd.name.split(":")[-1])
                if fd.name and "." in fd.name.replace(":", "."):
                    root, member = re.split(r"[.:]", fd.name, 1)
                    self.module_members.setdefault(root, set()).add(member.split(".")[0].split(":")[0])
            for ch in p["chains"]:
                # X.Y = ... assignments anywhere
                if len(ch.parts) >= 2 and ch.parts[1].startswith("."):
                    end = ch.idx + 1 + 2 * (len(ch.parts) - 1)
                    if end < len(toks) and toks[end].kind == "op" and toks[end].val == "=" and len(ch.parts) == 2:
                        self.module_members.setdefault(ch.head, set()).add(ch.parts[1][1:])
            # X = { key = ..., key2 = ... } at any level (top-level keys only)
            for i in range(len(toks) - 2):
                if toks[i].kind == "name" and toks[i + 1].kind == "op" and toks[i + 1].val == "=" and \
                        toks[i + 2].kind == "op" and toks[i + 2].val == "{" and \
                        not (i > 0 and toks[i - 1].kind == "op" and toks[i - 1].val in (".", ":")):
                    end = L.skip_balanced(toks, i + 2)
                    depth = 0
                    keys = set()
                    for j in range(i + 3, end - 1):
                        t = toks[j]
                        if t.kind == "op" and t.val in "({[":
                            depth += 1
                        elif t.kind == "op" and t.val in ")}]":
                            depth -= 1
                        elif depth == 0 and t.kind == "name" and j + 1 < end and toks[j + 1].kind == "op" and toks[j + 1].val == "=":
                            keys.add(t.val)
                    self.module_members.setdefault(toks[i].val, set()).update(keys)
            # methods assigned as X.Name = function(self
            for i in range(len(toks) - 4):
                if toks[i].kind == "op" and toks[i].val == "." and toks[i + 1].kind == "name" and \
                        toks[i + 2].val == "=" and toks[i + 3].val == "function" and toks[i + 4].val == "(" and \
                        i + 5 < len(toks) and toks[i + 5].val == "self":
                    self.project_methods.add(toks[i + 1].val)
        self.project_globals = set()
        for p in self.parsed.values():
            self.project_globals |= set(p["top"])

    # ------------------------------------------------------------------
    def _ctx_ok(self, entry, ctx, key, f, line, kind):
        if entry.get("only_paths") and not any(s.lower() in f.replace("\\", "/").lower() for s in entry["only_paths"]):
            self.rep.error(f, line, "api-scope", "%s '%s' is allowed only in %s" % (kind, key, ", ".join(entry["only_paths"])))
            return
        c = entry["ctx"].get(ctx)
        if c is None:
            allowed = "/".join(sorted(entry["ctx"])) or "none"
            self.rep.error(f, line, "api-context", "%s '%s' used in %s context; allowlist permits: %s (refs %s)" % (
                kind, key, ctx, allowed, ",".join(entry.get("refs", [])) or "-"))
            return
        lvl, tests = c["level"], c.get("tests", [])
        if lvl != "C":
            desc = {"L": "LIKELY", "NV": "NEW-VERIFY", "PENDING": "pending in-game test"}[lvl]
            self.rep.warn(f, line, "api-unverified", "%s '%s' in %s is %s%s (refs %s)" % (
                kind, key, ctx, desc, (" [" + ",".join(tests) + "]") if tests else "", ",".join(entry.get("refs", []))))
            self.checklist.setdefault((kind, key, ctx, desc, tuple(tests)), []).append((f, line))

    def audit(self):
        for f in self.proj.files:
            if f in self.parsed:
                self.audit_file(f)
        self.cross_checks()

    def audit_file(self, f):
        p = self.parsed[f]
        toks = p["toks"]
        fctx = self.proj.ctx[f]
        regions, problems = L.region_map(p["comments"])
        for ln, msg in problems:
            self.rep.error(f, ln, "region-marker", msg)
        for a, b, c in regions:
            if c not in fctx:
                self.rep.error(f, a, "region-marker", "EFV:%s-ONLY region in a file that only runs in %s" % (c, "/".join(sorted(fctx))))
        is_g_file = "G" in fctx
        locals_ = p["locals"]

        def ctxs_at(line):
            return sorted(L.line_context(fctx, regions, line))

        # enclosing-function lookup
        funcs = p["funcs"]

        def enclosing(idx):
            best = []
            for fd in funcs:
                if fd.start <= idx <= fd.end:
                    best.append(fd)
            return best

        # ---- forbidden tokens anywhere
        forbidden_names = {
            "InitUnitValidAdjacentHex": "PLAN 6.3.5", "ReportActivation": "PLAN 6.3.5",
            "GetRingPlots": "PLAN 6.3.5 (use Map.GetNeighborPlots + distance filter)",
            "ExposedMembers": "PLAN 1.2 (UI never uses ExposedMembers; requests go through EXECUTE_SCRIPT)",
            "TerrainBuilder": "PLAN 6.3.5 (map-script only)",
        }
        for extra in self.al.get("_forbidden_extra", []):
            forbidden_names[extra["name"]] = extra.get("why", "api_allowlist_extra.json forbidden")
        for i, t in enumerate(toks):
            if t.kind == "name" and t.val in forbidden_names:
                self.rep.error(f, t.line, "forbidden", "'%s' is forbidden: %s" % (t.val, forbidden_names[t.val]))
            if t.kind == "op" and t.val == ":" and i + 1 < len(toks) and toks[i + 1].val == "Kill":
                self.rep.error(f, t.line, "forbidden", "':Kill(' is forbidden (use UnitManager.Kill(unit), A21)")

        # ---- chains starting at global names
        for ch in p["chains"]:
            head, parts, line = ch.head, ch.parts, ch.line
            # skip definitions: function X.Y(  and table keys { X = }
            if ch.idx > 0 and toks[ch.idx - 1].kind == "kw" and toks[ch.idx - 1].val == "function":
                continue
            nxt = ch.idx + 1
            if len(parts) == 1 and nxt < len(toks) and toks[nxt].kind == "op" and toks[nxt].val == "=" and \
                    ch.idx > 0 and toks[ch.idx - 1].kind == "op" and toks[ch.idx - 1].val in ("{", ","):
                continue
            if head in locals_ and head not in ("UI",):
                continue
            for ctx in ctxs_at(line):
                self.check_chain(f, ch, ctx, enclosing)

        # ---- method calls
        for name, line, idx in p["methods"]:
            recv = self._receiver_head(toks, idx)
            for ctx in ctxs_at(line):
                self.check_method(f, name, line, ctx, recv, locals_)

        # ---- registration inside functions (G)
        if is_g_file:
            for ch in p["chains"]:
                if ch.head in ("GameEvents", "Events") and len(ch.parts) >= 4 and ch.parts[2] == ".Add":
                    if "G" in ctxs_at(ch.line) and any(fd.depth >= 0 for fd in enclosing(ch.idx)):
                        self.rep.warn(f, ch.line, "conditional-registration",
                                      "%s%s.Add inside a function: PLAN 1.7 registers all gameplay handlers at file load" % (ch.head, ch.parts[1]))

        # ---- Events.* handlers in gameplay must not mutate state
        if is_g_file:
            self.check_async_handlers(f)

    def _receiver_head(self, toks, idx):
        # idx = index of method name; toks[idx-1] == ':'
        j = idx - 2
        if j >= 0 and toks[j].kind == "name":
            text, _ = L._name_chain_back(toks, j)
            return text
        return None

    def check_chain(self, f, ch, ctx, enclosing):
        head, parts, line = ch.head, ch.parts, ch.line
        al = self.al
        # Lua builtins
        if head in LUA_STD and len(parts) >= 2 and parts[1].startswith("."):
            member = parts[1][1:]
            key = head + "." + member
            if head == "math" and member in ("random", "randomseed"):
                self.rep.error(f, line, "forbidden", "%s is forbidden (PLAN 1.6: only Game.GetRandNum in GameEvents handlers)" % key)
            elif head == "os":
                if ctx == "G":
                    self.rep.error(f, line, "forbidden", "%s in gameplay is non-deterministic / not allowed (PLAN 1.6)" % key)
                else:
                    self.rep.warn(f, line, "os-call", "%s in UI: not deterministic, avoid" % key)
            elif member not in LUA_STD[head]:
                if head == "table" and member in ("unpack", "pack"):
                    self.rep.error(f, line, "lua52", "%s is Lua 5.2+; use unpack() (A61)" % key)
                else:
                    self.rep.error(f, line, "unknown-std", "%s is not a Lua 5.1 standard function" % key)
            return
        if head in ("io", "debug", "require", "dofile", "loadfile", "package", "bit32", "utf8"):
            self.rep.error(f, line, "forbidden", "'%s' is not available / not allowed in Civ VI mods" % head)
            return
        if head == "pairs" and len(parts) >= 2 and parts[1] == "()":
            fds = enclosing(ch.idx)
            in_sorted = any(fd.name and fd.name.endswith("SortedKeys") for fd in fds)
            if ctx == "G" and not in_sorted:
                self.rep.error(f, line, "forbidden-pairs",
                               "pairs() in gameplay outside EFV_SortedKeys (PLAN 1.6: iteration order is not deterministic)")
            elif ctx == "UI":
                toks = self.parsed[f]["toks"]
                end = L.skip_balanced(toks, ch.idx + 1) if ch.idx + 1 < len(toks) else ch.idx
                arg = " ".join(t.val for t in toks[ch.idx + 2:end - 1])
                if re.search(r"rec|store|EFV_", arg, re.I):
                    self.rep.warn(f, line, "pairs-records", "pairs() over '%s' in UI: display order is not deterministic; iterate sorted ids" % arg)
            return
        if head in LUA_BUILTIN_FUNCS or head in L.LUA51_GLOBALS and head not in self.engine_roots:
            return
        if head in self.engine_roots:
            self.check_engine_chain(f, ch, ctx)
            return
        if head in self.project_globals or head in self.module_members:
            members = self.module_members.get(head, set())
            if len(parts) >= 2 and parts[1].startswith(".") and members:
                m = parts[1][1:]
                if m not in members:
                    is_call = len(parts) >= 3 and parts[2] == "()"
                    toks = self.parsed[f]["toks"]
                    end = ch.idx + 3
                    assigned = end < len(toks) and toks[end].kind == "op" and toks[end].val == "=" and len(parts) == 2
                    if not assigned:
                        (self.rep.error if is_call else self.rep.warn)(
                            f, line, "unknown-member", "%s '%s.%s' is not defined anywhere in the project (typo?)" % (
                                "function" if is_call else "field", head, m))

    def check_engine_chain(self, f, ch, ctx):
        head, parts, line = ch.head, ch.parts, ch.line
        al = self.al
        g = al["globals"].get(head)
        if head == "UI" and len(parts) == 1:
            return  # `UI == nil` context test (A58)
        if head == "Controls":
            if ctx != "UI":
                self.rep.error(f, line, "api-context", "Controls used in %s context" % ctx)
            return
        if head in EVENT_ROOTS:
            if len(parts) < 2 or not parts[1].startswith("."):
                return
            key = head + parts[1]
            e = lookup(al["events"], key)
            if e is None:
                self.rep.error(f, line, "unknown-event", "event '%s' is not in the allowlist (misspelt events fail silently; PLAN 1.7)" % key)
                return
            self._ctx_ok(e, ctx, key, f, line, "event")
            # Member after the event name: .Add / .Remove (base UnitFlagManager.lua:2000-2002,
            # InGame.lua:371) or a direct call (LuaEvents.X(...), GameEvents.X(...)).
            if len(parts) >= 3 and parts[2].startswith(".") and parts[2] not in (".Add", ".Remove"):
                self.rep.error(f, line, "unknown-event-member", "'%s%s' is not an event member (use .Add / .Remove)" % (key, parts[2]))
            return
        if head == "GameInfo":
            if len(parts) < 2 or not parts[1].startswith("."):
                if g:
                    self._ctx_ok(g, ctx, head, f, line, "global")
                return
            tbl = parts[1][1:]
            e = lookup(al["gameinfo"], tbl)
            if e is not None:
                self._ctx_ok(e, ctx, "GameInfo." + tbl, f, line, "GameInfo table")
            elif self.db_tables is not None and tbl not in self.db_tables:
                self.rep.error(f, line, "gameinfo-unknown", "GameInfo.%s: no such table in DebugGameplay.sqlite" % tbl)
            else:
                self.rep.warn(f, line, "gameinfo-unlisted", "GameInfo.%s exists but is not in Appendix A (A51); add it to api_allowlist_extra.json if intended" % tbl)
            return
        if len(parts) == 1 or parts[1] == "[]":
            if g is None:
                self.rep.error(f, line, "unknown-global", "'%s' is not an allowlisted engine global" % head)
            else:
                self._ctx_ok(g, ctx, head, f, line, "global")
            return
        if parts[1] == "()":
            e = lookup(al["static"], head)
            if e is None:
                e = g
            if e is None:
                self.rep.error(f, line, "unknown-api", "global function '%s' is not in the allowlist" % head)
            else:
                self._ctx_ok(e, ctx, head, f, line, "function")
            return
        key = head + parts[1]
        e = lookup(al["static"], key)
        if e is None:
            kind = "method" if parts[1].startswith(":") else ("call" if len(parts) > 2 and parts[2] == "()" else "member")
            self.rep.error(f, line, "unknown-api", "%s '%s' is not in the Appendix A allowlist (or api_allowlist_extra.json)" % (kind, key))
            return
        self._ctx_ok(e, ctx, key, f, line, "call" if len(parts) > 2 and parts[2] == "()" else "member")

    def check_method(self, f, name, line, ctx, recv, locals_):
        al = self.al
        recv_root = recv.split(".")[0].split(":")[0] if recv else None
        if recv_root in self.engine_roots and recv and "." not in recv and ":" not in recv and recv_root not in locals_:
            # Root:Method -> handled as static key by check_engine_chain
            return
        e = lookup(al["methods"], name)
        if e is not None:
            self._ctx_ok(e, ctx, ":" + name, f, line, "method")
            return
        if name in self.project_methods or name in STRING_METHODS:
            return
        self.rep.error(f, line, "unknown-method", "method ':%s' (receiver %s) is not in the Appendix A allowlist" % (name, recv or "?"))

    # ------------------------------------------------------------------
    def _function_index(self, comp):
        idx = {}
        for f in comp:
            p = self.parsed.get(f)
            if not p:
                continue
            for fd in p["funcs"]:
                if fd.name:
                    key = fd.name.replace(":", ".")
                    if fd.is_local:
                        idx.setdefault(("local", f, key), (f, fd))
                    else:
                        idx.setdefault(("global", key), (f, fd))
        return idx

    def check_async_handlers(self, f):
        p = self.parsed[f]
        toks = p["toks"]
        comp = self.proj.component(f)
        fidx = self._function_index(comp)
        for ch in p["chains"]:
            if ch.head != "Events" or len(ch.parts) < 4 or ch.parts[2] != ".Add":
                continue
            if "G" not in L.line_context(self.proj.ctx[f], L.region_map(p["comments"])[0], ch.line):
                continue
            evname = "Events" + ch.parts[1]
            a = ch.first_arg
            if a is None or a >= len(toks):
                continue
            target = None
            if toks[a].kind == "kw" and toks[a].val == "function":
                fd = next((fd for fd in p["funcs"] if fd.start == a), None)
                if fd:
                    target = (f, fd, "<inline handler>")
            elif toks[a].kind == "name":
                text, _ = L._name_chain_back(toks, a)  # single name expected
                j = a
                parts = [toks[a].val]
                while j + 2 < len(toks) and toks[j + 1].val in (".", ":") and toks[j + 2].kind == "name":
                    parts.append(toks[j + 2].val)
                    j += 2
                name = ".".join(parts)
                hit = fidx.get(("local", f, name)) or fidx.get(("global", name))
                if hit:
                    target = (hit[0], hit[1], name)
                else:
                    self.rep.warn(f, ch.line, "async-handler-unresolved", "%s handler '%s' not found; cannot check it for state mutation" % (evname, name))
            if target:
                self._walk_handler(evname, target, fidx, f, ch.line)

    def _walk_handler(self, evname, target, fidx, reg_file, reg_line):
        root_name = target[2]
        dv13 = root_name.endswith(DV13_HANDLER_SUFFIX)
        seen = set()
        stack = [(target[0], target[1], [root_name])]
        while stack:
            f, fd, path = stack.pop()
            key = (f, fd.start)
            if key in seen or len(path) > 10:
                continue
            seen.add(key)
            p = self.parsed[f]
            toks = p["toks"]
            for name, line, idx in p["methods"]:
                if fd.start <= idx <= fd.end and name in ASYNC_FORBIDDEN:
                    self._async_hit(evname, name, f, line, path, dv13)
            for ch in p["chains"]:
                if not (fd.start < ch.idx <= fd.end):
                    continue
                # static forbidden calls: Game.GetRandNum, UnitManager.InitUnit/Kill, CityManager.TransferCity
                for part in ch.parts[1:]:
                    nm = part[1:] if part[:1] in ".:" else None
                    if nm in ASYNC_FORBIDDEN and part.startswith("."):
                        self._async_hit(evname, nm, f, ch.line, path, dv13)
                # follow calls to project functions
                if len(ch.parts) >= 2:
                    names = []
                    cur = ch.head
                    for part in ch.parts[1:]:
                        if part == "()":
                            names.append(cur)
                            break
                        if part.startswith("."):
                            cur += part
                        else:
                            break
                    for nm in names:
                        hit = fidx.get(("local", f, nm)) or fidx.get(("global", nm))
                        if hit:
                            stack.append((hit[0], hit[1], path + [nm]))

    def _async_hit(self, evname, call, f, line, path, dv13):
        via = " -> ".join(path)
        if dv13 and call == "SetProperty":
            self.rep.warn(f, line, "async-dv13", "SetProperty reached from %s handler via %s (allowed DV13 exception; review in Phase 8)" % (evname, via))
            return
        self.rep.error(f, line, "async-mutation", "%s (%s) reached from gameplay %s handler via %s: Events.* are async, "
                       "state changes belong in GameEvents handlers (PLAN 1.6)" % (call, ASYNC_FORBIDDEN[call], evname, via))

    # ------------------------------------------------------------------
    def cross_checks(self):
        sent = {}      # name -> (file, line)
        handled = {}
        # string constants such as EFV_Config.REQ_SEND = "EFV_Send" / { REQ_SEND = "EFV_Send" }
        consts = {}
        for f, p in self.parsed.items():
            toks = p["toks"]
            for i in range(len(toks) - 2):
                if toks[i].kind == "name" and toks[i + 1].val == "=" and toks[i + 2].kind == "str" and \
                        re.fullmatch(r"EFV_\w+", toks[i + 2].val):
                    consts.setdefault(toks[i].val, toks[i + 2].val)
        for f, p in self.parsed.items():
            toks = p["toks"]
            fctx = self.proj.ctx[f]
            for i, t in enumerate(toks):
                if t.kind == "name" and t.val == "OnStart" and i + 2 < len(toks) and toks[i + 1].val == "=" and toks[i + 2].kind == "str":
                    if "UI" in fctx:
                        sent.setdefault(toks[i + 2].val, (f, t.line))
                if t.kind == "name" and re.search(r"Request$", t.val) and t.val != "RequestPlayerOperation" and \
                        i + 2 < len(toks) and toks[i + 1].val == "(" and "UI" in fctx:
                    a = toks[i + 2]
                    val = None
                    if a.kind == "str" and re.fullmatch(r"EFV_\w+", a.val):
                        val = a.val
                    elif a.kind == "name":
                        j = i + 2
                        while j + 2 < len(toks) and toks[j + 1].val == "." and toks[j + 2].kind == "name":
                            j += 2
                        val = consts.get(toks[j].val)
                    if val:
                        sent.setdefault(val, (f, t.line))
            for ch in p["chains"]:
                if ch.head == "GameEvents" and len(ch.parts) >= 3 and ch.parts[2] == ".Add" and "G" in fctx:
                    handled.setdefault(ch.parts[1][1:], (f, ch.line))
        for name, (f, line) in sorted(sent.items()):
            if name not in handled:
                self.rep.error(f, line, "onstart-unhandled", "UI sends OnStart='%s' but no gameplay file registers GameEvents.%s.Add" % (name, name))
        for name, (f, line) in sorted(handled.items()):
            if name.startswith("EFV_") and name not in sent:
                self.rep.warn(f, line, "handler-unused", "GameEvents.%s has a handler but no UI file sends OnStart='%s'" % (name, name))

    def print_checklist(self, stream=sys.stdout):
        if not self.checklist:
            return
        stream.write("\nIn-game verification checklist (calls used before their test closes):\n")
        by_test = {}
        for (kind, key, ctx, desc, tests), locs in self.checklist.items():
            for t in (tests or ("no test ID",)):
                by_test.setdefault(t, []).append((key, ctx, desc, len(locs)))
        for t in sorted(by_test, key=lambda s: (s == "no test ID", int(re.sub(r"\D", "", s) or 999), s)):
            items = ", ".join("%s (%s, %s, %dx)" % x for x in sorted(set(by_test[t])))
            stream.write("  %s: %s\n" % (t, items))


def audit(root, rep=None, regen=False):
    rep = rep or L.Report("api_audit", base=L.PROJECT_DIR)
    al = load_allowlist(regen=regen)
    a = Auditor(root, al, rep)
    a.audit()
    return rep, a


def main(argv=None):
    L.configure_stdout()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", nargs="?")
    ap.add_argument("--regen", action="store_true", help="rebuild api_allowlist.json and .luacheckrc from PLAN.md")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--info", action="store_true")
    ap.add_argument("--no-checklist", action="store_true")
    a = ap.parse_args(argv)
    if a.root is None:
        if a.regen:
            load_allowlist(regen=True)
            return 0
        a.root = os.path.join(L.PROJECT_DIR, "EFV")
    if not os.path.exists(a.root):
        print("api_audit: root not found: %s" % a.root)
        return 2
    rep, auditor = audit(a.root, regen=a.regen)
    rep.print(show_info=a.info)
    if not a.no_checklist:
        auditor.print_checklist()
    return rep.exit_code(a.strict)


if __name__ == "__main__":
    sys.exit(main())
