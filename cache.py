"""The widget's local cache: one SQLite file shared by steam.py and steamctl.py.

The friend list is kept as the last snapshot either source produced, so the
popup can show it straight away and swap in live data when it arrives. The
community fallback's per-profile statuses live here too.

Every call here is best effort: a busy or broken cache must never stop the
live data from reaching the widget.
"""
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
"""


def connect():
    os.makedirs(CACHE, exist_ok=True)
    # Several helpers run at once (friends, chat, downloads); WAL lets the
    # reader showing the cache go ahead while a refresh writes.
    db = sqlite3.connect(DB, timeout=3)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)
    return db


def save_friends(friends, groups):
    """Replace the snapshot. Unread counts are left out: shown later they'd be stale."""
    try:
        with connect() as db:
            db.execute("DELETE FROM friends")
            db.executemany("INSERT OR REPLACE INTO friends VALUES (?, ?, ?)", [
                (str(f.get("accountid", "")), i, json.dumps(dict(f, unread=0), ensure_ascii=False))
                for i, f in enumerate(friends) if isinstance(f, dict)])
            db.execute("DELETE FROM friend_groups")
            db.executemany("INSERT INTO friend_groups VALUES (?, ?, ?)",
                           [(i, str(g.get("id", "")), str(g.get("name", ""))) for i, g in enumerate(groups) if isinstance(g, dict)])
            db.execute("INSERT OR REPLACE INTO meta VALUES ('friends_saved', ?)", (str(int(time.time())),))
    except (sqlite3.Error, OSError):
        pass


def load_friends():
    """The last snapshot: {"friends", "groups", "saved"} (empty when there's none)."""
    try:
        with connect() as db:
            friends = [json.loads(d) for (d,) in db.execute("SELECT data FROM friends ORDER BY pos")]
            groups = [{"id": i, "name": n} for i, n in db.execute("SELECT id, name FROM friend_groups ORDER BY pos")]
            saved = db.execute("SELECT value FROM meta WHERE key = 'friends_saved'").fetchone()
            collapsed = db.execute("SELECT value FROM meta WHERE key = 'groups_collapsed'").fetchone()
        return {"friends": friends, "groups": groups, "saved": int(saved[0]) if saved else 0,
                "collapsed": json.loads(collapsed[0]) if collapsed else []}
    except (sqlite3.Error, OSError, ValueError):
        return {"friends": [], "groups": [], "saved": 0, "collapsed": []}


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
        with connect() as db:
            return {a: json.loads(d) for a, d in db.execute("SELECT accountid, data FROM profile_status")}
    except (sqlite3.Error, OSError, ValueError):
        return {}


def save_statuses(known):
    try:
        with connect() as db:
            db.executemany("INSERT OR REPLACE INTO profile_status VALUES (?, ?)",
                           [(a, json.dumps(s, ensure_ascii=False)) for a, s in known.items()])
    except (sqlite3.Error, OSError):
        pass


def load_app(appid, max_age):
    """A store app's {name, header} saved by save_app, if younger than max_age seconds."""
    try:
        with connect() as db:
            row = db.execute("SELECT data, saved FROM apps WHERE appid = ?", (int(appid),)).fetchone()
        if row and time.time() - row[1] < max_age:
            return json.loads(row[0])
    except (sqlite3.Error, OSError, ValueError):
        pass
    return None


def save_app(appid, info):
    try:
        with connect() as db:
            db.execute("INSERT OR REPLACE INTO apps VALUES (?, ?, ?)",
                       (int(appid), json.dumps(info, ensure_ascii=False), int(time.time())))
    except (sqlite3.Error, OSError):
        pass


def load_embed(key, max_age):
    """Details looked up for a shared link (e.g. a YouTube title), if younger than max_age seconds."""
    try:
        with connect() as db:
            row = db.execute("SELECT data, saved FROM embeds WHERE key = ?", (str(key),)).fetchone()
        if row and time.time() - row[1] < max_age:
            return json.loads(row[0])
    except (sqlite3.Error, OSError, ValueError):
        pass
    return None


def save_embed(key, info):
    try:
        with connect() as db:
            db.execute("INSERT OR REPLACE INTO embeds VALUES (?, ?, ?)",
                       (str(key), json.dumps(info, ensure_ascii=False), int(time.time())))
    except (sqlite3.Error, OSError):
        pass


def clear():
    """Forget everything cached (the friend list, statuses, looked-up links),
    keeping only which friend groups are minimised."""
    try:
        with connect() as db:
            for table in ("friends", "friend_groups", "profile_status", "apps", "embeds"):
                db.execute("DELETE FROM %s" % table)
            db.execute("DELETE FROM meta WHERE key != 'groups_collapsed'")
    except (sqlite3.Error, OSError):
        pass
