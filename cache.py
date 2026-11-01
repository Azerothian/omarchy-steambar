"""The widget's local cache: one SQLite file shared by steam.py and steamctl.py.

The friend list is kept as the last snapshot either source produced, so the
popup can show it straight away and swap in live data when it arrives. The
Events tab's log lives here too: Steam's notifications as they were seen, and
friends coming online or starting a game, noticed between live refreshes. The
community fallback's per-profile statuses live here too, as do details looked
up for shared links (a store game's name and art, a YouTube title).

Every call here is best effort: a busy or broken cache must never stop the
live data from reaching the widget.
"""
import atexit
import hashlib
import json
import os
import sqlite3
import time

CACHE = os.path.expanduser("~/.cache/blip-steam")
DB = os.path.join(CACHE, "steam.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS friends (accountid TEXT PRIMARY KEY, pos INTEGER, data TEXT);
CREATE TABLE IF NOT EXISTS friend_groups (pos INTEGER PRIMARY KEY, id TEXT, name TEXT);
CREATE TABLE IF NOT EXISTS profile_status (accountid TEXT PRIMARY KEY, data TEXT);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS apps (appid INTEGER PRIMARY KEY, data TEXT, saved INTEGER);
CREATE TABLE IF NOT EXISTS embeds (key TEXT PRIMARY KEY, data TEXT, saved INTEGER);
CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, ts INTEGER, data TEXT);
"""

# The most events kept; older ones are dropped as new ones arrive.
MAX_EVENTS = 1000
# Presence seen longer ago than this is too old to tell what changed since.
PRESENCE_GAP = 600

_db = None


def connect():
    """One connection per process (each helper is a short-lived process)."""
    global _db
    if _db is None:
        os.makedirs(CACHE, exist_ok=True)
        # Several helpers run at once (friends, chat, downloads); WAL lets the
        # reader showing the cache go ahead while a refresh writes.
        _db = sqlite3.connect(DB, timeout=3)
        _db.execute("PRAGMA journal_mode=WAL")
        _db.executescript(SCHEMA)
        atexit.register(_db.close)
    return _db


def _meta(db, key):
    row = db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else None


def save_friends(friends, groups):
    """Replace the snapshot (skipped when it hasn't changed). Unread counts are
    left out: shown later they'd be stale."""
    rows = [(str(f.get("accountid", "")), i, json.dumps(dict(f, unread=0), ensure_ascii=False))
            for i, f in enumerate(friends) if isinstance(f, dict)]
    group_rows = [(i, str(g.get("id", "")), str(g.get("name", ""))) for i, g in enumerate(groups) if isinstance(g, dict)]
    digest = hashlib.sha1(json.dumps([rows, group_rows]).encode()).hexdigest()
    try:
        with connect() as db:
            if _meta(db, "friends_hash") == digest:
                return
            db.execute("DELETE FROM friends")
            db.executemany("INSERT OR REPLACE INTO friends VALUES (?, ?, ?)", rows)
            db.execute("DELETE FROM friend_groups")
            db.executemany("INSERT INTO friend_groups VALUES (?, ?, ?)", group_rows)
            db.execute("INSERT OR REPLACE INTO meta VALUES ('friends_hash', ?)", (digest,))
    except (sqlite3.Error, OSError):
        pass


def load_friends():
    """The last snapshot: {"friends", "groups", "collapsed"} (empty when there's none)."""
    try:
        db = connect()
        friends = [json.loads(d) for (d,) in db.execute("SELECT data FROM friends ORDER BY pos")]
        groups = [{"id": i, "name": n} for i, n in db.execute("SELECT id, name FROM friend_groups ORDER BY pos")]
        collapsed = _meta(db, "groups_collapsed")
        return {"friends": friends, "groups": groups, "collapsed": json.loads(collapsed) if collapsed else []}
    except (sqlite3.Error, OSError, ValueError):
        return {"friends": [], "groups": [], "collapsed": []}


def add_events(events):
    """Log events ({"id", "ts", ...}); one with a logged id replaces it (a
    Steam notification rolling up more items)."""
    rows = [(str(e["id"]), int(e.get("ts") or 0), json.dumps(e, ensure_ascii=False))
            for e in events if isinstance(e, dict) and e.get("id")]
    if not rows:
        return
    try:
        with connect() as db:
            db.executemany("INSERT OR REPLACE INTO events VALUES (?, ?, ?)", rows)
            db.execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY ts DESC LIMIT ?)", (MAX_EVENTS,))
    except (sqlite3.Error, OSError):
        pass


def load_events(limit=300):
    """The newest logged events first."""
    try:
        return [json.loads(d) for (d,) in connect().execute("SELECT data FROM events ORDER BY ts DESC, id LIMIT ?", (limit,))]
    except (sqlite3.Error, OSError, ValueError):
        return []


def log_presence(friends, now=None):
    """Log what changed since the last live friend list: who came online or
    went offline, and who started or stopped a game. Nothing is logged across
    a long gap (Steam or the widget wasn't running), only the new baseline."""
    now = int(now or time.time())
    seen = {}
    for f in friends:
        if not isinstance(f, dict) or f.get("state") in (None, "unknown"):
            continue
        seen[str(f.get("accountid"))] = {
            "online": f["state"] != "offline", "appid": f.get("appid") or 0, "game": f.get("game") or "",
            "name": f.get("name") or "", "avatar": f.get("avatar") or "", "steamid": f.get("steamid") or "",
        }
    try:
        db = connect()
        last = json.loads(_meta(db, "presence") or "{}")
    except (sqlite3.Error, OSError, ValueError):
        return
    events = []
    before = last.get("friends") or {} if now - (last.get("at") or 0) <= PRESENCE_GAP else {}
    for accountid, cur in seen.items():
        old = before.get(accountid)
        if not old:
            continue

        def event(kind, appid=0, game=""):
            events.append({"id": "%s:%s:%d" % (kind, accountid, now), "ts": now, "kind": kind, "accountid": accountid,
                           "steamid": cur["steamid"], "name": cur["name"], "avatar": cur["avatar"], "appid": appid, "game": game})

        if cur["online"] and not old["online"]:
            event("online")
        elif old["online"] and not cur["online"]:
            event("offline")
        if cur["appid"] and cur["appid"] != old["appid"]:
            event("playing", cur["appid"], cur["game"])
        elif old["appid"] and not cur["appid"] and cur["online"]:
            event("stopped", old["appid"], old["game"])
    add_events(events)
    try:
        with connect() as db:
            db.execute("INSERT OR REPLACE INTO meta VALUES ('presence', ?)", (json.dumps({"at": now, "friends": seen}),))
    except (sqlite3.Error, OSError):
        pass


def save_collapsed(ids):
    """Friend list sections minimised to their header."""
    try:
        with connect() as db:
            db.execute("INSERT OR REPLACE INTO meta VALUES ('groups_collapsed', ?)",
                       (json.dumps([str(i) for i in ids if isinstance(i, (str, int))][:500]),))
    except (sqlite3.Error, OSError):
        pass


def load_statuses():
    try:
        return {a: json.loads(d) for a, d in connect().execute("SELECT accountid, data FROM profile_status")}
    except (sqlite3.Error, OSError, ValueError):
        return {}


def save_statuses(known):
    try:
        with connect() as db:
            db.executemany("INSERT OR REPLACE INTO profile_status VALUES (?, ?)",
                           [(a, json.dumps(s, ensure_ascii=False)) for a, s in known.items()])
    except (sqlite3.Error, OSError):
        pass


# Looked-up details: "apps" by app id, "embeds" by a key like "youtube:<id>".
_KEYS = {"apps": "appid", "embeds": "key"}


def load_lookup(table, key):
    """(details, age in seconds) saved by save_lookup, or (None, None)."""
    try:
        row = connect().execute("SELECT data, saved FROM %s WHERE %s = ?" % (table, _KEYS[table]), (key,)).fetchone()
        if row:
            return json.loads(row[0]), time.time() - row[1]
    except (sqlite3.Error, OSError, ValueError, KeyError):
        pass
    return None, None


def save_lookup(table, key, info):
    try:
        with connect() as db:
            db.execute("INSERT OR REPLACE INTO %s VALUES (?, ?, ?)" % table,
                       (key, json.dumps(info, ensure_ascii=False), int(time.time())))
    except (sqlite3.Error, OSError):
        pass


def clear():
    """Forget everything cached (the friend list, statuses, looked-up links),
    keeping only which friend groups are minimised and the event log (history,
    not a copy of anything Steam still has)."""
    try:
        with connect() as db:
            for table in ("friends", "friend_groups", "profile_status", "apps", "embeds"):
                db.execute("DELETE FROM %s" % table)
            db.execute("DELETE FROM meta WHERE key != 'groups_collapsed'")
    except (sqlite3.Error, OSError):
        pass
