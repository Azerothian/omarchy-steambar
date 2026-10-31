"""The demo's made-up Steam account, built on disk.

Everything a real account would have is written out the way Steam keeps it,
so the widget's helpers read it through their normal code paths:

  steam/                 a Steam install: loginusers.vdf, localconfig.vdf, a
                         binary appinfo.vdf, the library art cache, app
                         manifests, a content log with a download running
  world.json             the running client's state for the fake debug port
                         (friends, groups, chats, Remote Play computers)
  img/, clip.mp4         avatars, art and media

The people, groups and chats are invented. The games are real store titles
(their art is downloaded once, or drawn as a placeholder when offline), plus
a few invented upcoming ones.
"""
import json
import os
import shutil
import struct
import subprocess
import time
import urllib.request

SELF = 1000                          # your account id
STEAMID64_BASE = 76561197960265728
HOUR, DAY = 3600, 86400

# appid, name, how it sits in your library:
#   here      installed on this computer
#   remote    installed on your other computers (ids from COMPUTERS)
#   played    hours ago it was last played (None: never), and hours played
LIBRARY = [
    (1145360, "Hades", {"here": True, "played": (2, 62)}),
    (548430, "Deep Rock Galactic", {"here": True, "played": (20, 210)}),
    (413150, "Stardew Valley", {"here": True, "played": (70, 140)}),
    (1086940, "Baldur's Gate 3", {"remote": ["11"], "played": (120, 96)}),
    (367520, "Hollow Knight", {"here": True, "played": (170, 48)}),
    (646570, "Slay the Spire", {"here": True, "played": (330, 120)}),
    (892970, "Valheim", {"remote": ["11", "22"], "played": (500, 75)}),
    (620, "Portal 2", {"here": True, "played": (720, 22)}),
    (504230, "Celeste", {"remote": ["22"], "played": (900, 30)}),
    (1794680, "Vampire Survivors", {"here": True, "played": (1100, 35)}),
    (105600, "Terraria", {"here": True, "played": (1500, 180)}),
    (292030, "The Witcher 3: Wild Hunt", {"remote": ["11"], "played": (2000, 110)}),
    (1245620, "ELDEN RING", {"remote": ["11"], "played": (2600, 140)}),
    (2379780, "Balatro", {"here": True, "played": (3000, 41)}),
    (945360, "Among Us", {"here": True, "played": (5000, 12)}),
    (440, "Team Fortress 2", {"played": (9000, 300)}),
    (400, "Portal", {"played": (12000, 8)}),
    (1966720, "Lethal Company", {}),
    (739630, "Phasmophobia", {}),
    (230410, "Warframe", {}),
]
DOWNLOADING = 105600                 # an update downloading for Terraria...
TOOL = (1628350, "Steam Linux Runtime 3.0 (sniper)")   # ...with a runtime alongside

# The store's lists. Upcoming games are invented (appids past any real one).
STORE = {
    "top": [553850, 1086940, 1245620, 1091500, 271590, 730, 570, 252490, 1172470, 1145360, 2379780, 892970],
    "new": [2379780, 1966720, 1794680, 548430, 739630, 1145360, 504230, 367520],
    "upcoming": [9900001, 9900002, 9900003, 9900004, 9900005],
}
STORE_GAMES = {
    553850: ("HELLDIVERS 2", "$39.99", 0), 1091500: ("Cyberpunk 2077", "$59.99", 50),
    271590: ("Grand Theft Auto V Enhanced", "$29.98", 0), 730: ("Counter-Strike 2", "", 0),
    570: ("Dota 2", "", 0), 252490: ("Rust", "$39.99", 25), 1172470: ("Apex Legends", "", 0),
    9900001: ("Starfall Tactics", "", 0), 9900002: ("Moss Golem", "", 0), 9900003: ("Neon Courier", "", 0),
    9900004: ("Tidebound", "", 0), 9900005: ("Hollow Crown", "", 0),
}
FREE = {730, 570, 1172470, 230410, 440, 945360}
PRICES = {1145360: ("$24.99", 60), 1086940: ("$59.99", 0), 1245620: ("$59.99", 40), 2379780: ("$14.99", 0),
          892970: ("$19.99", 0), 548430: ("$29.99", 75), 1794680: ("$4.99", 0), 1966720: ("$9.99", 0),
          739630: ("$19.99", 0), 504230: ("$19.99", 75), 367520: ("$14.99", 50)}
BLURBS = {
    1145360: "Defy the god of the dead as you hack and slash out of the Underworld in this rogue-like dungeon crawler.",
    548430: "Work together as a team of space dwarves to dig, fight and mine your way through a hostile alien world.",
    2379780: "The poker roguelike. Build powerful synergies and win big with hands, jokers and a deck of your own.",
    1086940: "Gather your party and return to the Forgotten Realms in a tale of fellowship and betrayal.",
}
TAGS = [(19, "Action"), (21, "Adventure"), (492, "Indie"), (1716, "Roguelike"), (3843, "Online Co-Op"),
        (1662, "Survival"), (122, "RPG"), (597, "Casual"), (4182, "Singleplayer"), (1695, "Open World")]

# Your other computers signed in to Steam, for Remote Play.
COMPUTERS = [("11", "Living Room PC"), ("22", "Steam Deck")]

# Invented friends: name, nickname you gave them (or ""), state, the game
# they're in, your friend groups they're in, unread messages.
FRIENDS = [
    (1001, "Nova", "", "in-game", 548430, ["raid", "fav"], 2),
    (1002, "Kestrel", "Kes", "online", 0, ["raid", "fav"], 0),
    (1003, "Juniper Vale", "", "in-game", 1145360, ["coop"], 0),
    (1004, "Ozzie", "", "away", 0, ["coop"], 0),
    (1005, "Marlow", "", "busy", 0, ["raid"], 0),
    (1006, "Tamsin", "", "online", 0, ["coop", "fav"], 1),
    (1007, "rook_irl", "Rook", "in-game", 553850, ["raid"], 0),
    (1008, "Pixel Witch", "", "online", 0, [], 0),
    (1009, "Sable", "", "away", 0, ["coop"], 0),
    (1010, "Dax", "", "in-game", 892970, [], 0),
    (1011, "Wren", "", "offline", 0, ["raid"], 0),
    (1012, "Fennec", "", "offline", 0, [], 0),
    (1013, "Captain Lumen", "", "offline", 0, ["coop"], 0),
    (1014, "Iris", "", "offline", 0, [], 0),
    (1015, "Bodhi", "", "offline", 0, [], 0),
    (1016, "Quill", "", "online", 0, [], 0),
]
FRIEND_GROUPS = [("raid", "Raid Night"), ("coop", "Co-op Crew")]
STATES = {"offline": 0, "online": 1, "busy": 2, "away": 3}
COLORS = ["#7c5cff", "#ff6b6b", "#2ec4b6", "#ffb703", "#3a86ff", "#fb5607", "#8338ec", "#06d6a0",
          "#ef476f", "#118ab2", "#f4a261", "#9b5de5", "#00bbf9", "#e76f51", "#43aa8b", "#f15bb5"]

# Group chats: id, name, tagline, members (account ids; 2xxx aren't friends),
# rooms (id, name, unread, mentioned), hours since active.
GROUP_CHATS = [
    ("501", "Deep Rock Diggers", "Rock and Stone!", [1001, 1002, 1005, 1007, 1011, 2001, 2002, 2003],
     [("5011", "General", 3, True), ("5012", "Missions", 0, False)], 0.2),
    ("502", "Weekend LAN", "Saturdays from 8", [1003, 1004, 1006, 1009, 1013, 2004],
     [("5021", "Home", 1, False)], 5),
    ("503", "Speedrun Club", "", [1008, 1010, 1016, 2005, 2006, 2007],
     [("5031", "Home", 0, False)], 48),
]
STRANGERS = [(2001, "Gravel Gus", "online"), (2002, "Mira", "in-game"), (2003, "BeardBorn", "offline"),
             (2004, "lanparty_larry", "away"), (2005, "Frame Perfect", "online"), (2006, "Tess", "offline"),
             (2007, "any%", "in-game")]


def account(i):
    return str(STEAMID64_BASE + i)


# ---------- Steam's file formats ----------
def text_vdf(d, depth=0):
    pad = "\t" * depth
    out = []
    for k, v in d.items():
        if isinstance(v, dict):
            out.append('%s"%s"\n%s{\n%s%s}\n' % (pad, k, pad, text_vdf(v, depth + 1), pad))
        else:
            out.append('%s"%s"\t\t"%s"\n' % (pad, k, str(v).replace("\\", "\\\\").replace('"', '\\"')))
    return "".join(out)


def appinfo_vdf(apps, version=29):
    """A binary appinfo.vdf for {appid: (name, type)}: v29 keeps keys in a
    string table at the end, v28 inline."""
    strings = []

    def key(k):
        if version < 29:
            return k.encode() + b"\0"
        if k not in strings:
            strings.append(k)
        return struct.pack("<I", strings.index(k))

    def kv(d):
        out = b""
        for k, v in d.items():
            if isinstance(v, dict):
                out += b"\x00" + key(k) + kv(v)
            elif isinstance(v, int):
                out += b"\x02" + key(k) + struct.pack("<i", v)
            else:
                out += b"\x01" + key(k) + str(v).encode() + b"\0"
        return out + b"\x08"

    body = b""
    for appid, (name, kind) in apps.items():
        data = kv({"appinfo": {"appid": appid, "common": {"name": name, "type": kind}}})
        head = struct.pack("<IIQ20sI20s", 2, int(time.time()), 0, b"\0" * 20, 1, b"\0" * 20)
        body += struct.pack("<II", appid, len(head) + len(data)) + head + data
    body += struct.pack("<I", 0)
    magic = 0x07564429 if version >= 29 else 0x07564428
    if version < 29:
        return struct.pack("<II", magic, 1) + body
    table = struct.pack("<I", len(strings)) + b"".join(s.encode() + b"\0" for s in strings)
    return struct.pack("<IIq", magic, 1, 16 + len(body)) + body + table


# ---------- images ----------
def _magick(args):
    subprocess.run(["magick"] + args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)


def _font():
    try:
        return subprocess.run(["fc-match", "-f", "%{file}", "sans:bold"], capture_output=True, text=True, timeout=10).stdout
    except OSError:
        return ""


def placeholder(path, w, h, text, color, size=None):
    """A gradient card with a title on it, for art that isn't available."""
    font = _font()
    args = ["-size", "%dx%d" % (w, h), "gradient:%s-#14161c" % color, "-gravity", "center", "-fill", "white"]
    if font:
        args += ["-font", font]
    args += ["-pointsize", str(size or max(12, min(w, h) // 6)), "-annotate", "0", text, path]
    _magick(args)


def download(url, path, offline):
    if offline:
        return False
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            data = r.read(8 * 1024 * 1024)
        with open(path, "wb") as f:
            f.write(data)
        return True
    except Exception:
        return False


def art(base, appid, name, color, offline, cache_dir):
    """header.jpg, library_600x900.jpg and an icon for a game in Steam's
    library cache layout. Downloads are kept in cache_dir so a rebuild
    doesn't fetch them again."""
    os.makedirs(base, exist_ok=True)
    cdn = "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/%d/" % appid
    for name_, w, h in (("header.jpg", 460, 215), ("library_600x900.jpg", 600, 900)):
        kept = os.path.join(cache_dir, "%d-%s" % (appid, name_))
        if not os.path.exists(kept) and not (appid < 9900000 and download(cdn + name_, kept, offline)):
            placeholder(kept, w, h, name.replace(": ", ":\n"), color)
        shutil.copy(kept, os.path.join(base, name_))
    # The small icon sits at the top level, named by a hash.
    icon = os.path.join(base, "%040x.jpg" % appid)
    _magick([os.path.join(base, "header.jpg"), "-gravity", "center", "-crop", "215x215+0+0", "+repage",
             "-resize", "64x64", icon])
    return icon


def avatar(path, name, color):
    letters = "".join(w[0] for w in name.replace("_", " ").split()[:2]).upper() or "?"
    placeholder(path, 184, 184, letters, color, size=80)


# ---------- the account ----------
def build(root, offline=False):
    """Write the demo account under root (replacing any earlier one)."""
    now = int(time.time())
    steam = os.path.join(root, "steam")
    img = os.path.join(root, "img")
    kept = os.path.join(root, "downloads")
    for d in (steam, img):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
    os.makedirs(kept, exist_ok=True)
    os.makedirs(os.path.join(root, "cache"), exist_ok=True)
    urls = {}   # remote URL -> local file, for what the fake client hands out

    # Install, account, play history.
    os.makedirs(os.path.join(steam, "config"))
    with open(os.path.join(steam, "config", "loginusers.vdf"), "w") as f:
        f.write(text_vdf({"users": {account(SELF): {"AccountName": "blip", "PersonaName": "Blip",
                                                     "MostRecent": "1", "Timestamp": str(now)}}}))
    apps = {}
    for appid, _, how in LIBRARY:
        if how.get("played"):
            hours_ago, hours = how["played"]
            apps[str(appid)] = {"LastPlayed": str(now - hours_ago * HOUR), "Playtime": str(hours * 60)}
    friends_cfg = {str(i): {"name": n, "avatar": "%040x" % i} for i, n, *_ in FRIENDS}
    playercache = [{"steamid": account(i), "nickname": nick} for i, _, nick, *_ in FRIENDS if nick]
    userdir = os.path.join(steam, "userdata", str(SELF), "config")
    os.makedirs(userdir)
    with open(os.path.join(userdir, "localconfig.vdf"), "w") as f:
        f.write(text_vdf({"UserLocalConfigStore": {
            "friends": friends_cfg,
            "WebStorage": {"friendstore_playercache": json.dumps(playercache)},
            "Software": {"Valve": {"Steam": {"apps": apps}}},
        }}))

    # appinfo: your library and the runtime. Store-only games aren't in it,
    # so they stay out of the library while their art is still found.
    names = {appid: (name, "Game") for appid, name, _ in LIBRARY}
    names[TOOL[0]] = (TOOL[1], "Tool")
    os.makedirs(os.path.join(steam, "appcache"))
    with open(os.path.join(steam, "appcache", "appinfo.vdf"), "wb") as f:
        f.write(appinfo_vdf(names))

    cache = os.path.join(steam, "appcache", "librarycache")
    icons = {}
    every = [(a, n) for a, n, _ in LIBRARY] + [(a, v[0]) for a, v in STORE_GAMES.items()]
    for n, (appid, name) in enumerate(every):
        icons[appid] = art(os.path.join(cache, str(appid)), appid, name, COLORS[n % len(COLORS)], offline, kept)

    # Installed games, a second library drive, and a download in progress.
    games_drive = os.path.join(root, "GAMES", "SteamLibrary")
    for lib in (steam, games_drive):
        os.makedirs(os.path.join(lib, "steamapps"), exist_ok=True)
    with open(os.path.join(steam, "steamapps", "libraryfolders.vdf"), "w") as f:
        f.write(text_vdf({"libraryfolders": {"0": {"path": steam}, "1": {"path": games_drive}}}))
    installed = [(a, n) for a, n, how in LIBRARY if how.get("here")] + [TOOL]
    for k, (appid, name) in enumerate(installed):
        lib = games_drive if k % 3 == 2 else steam
        downloading = appid in (DOWNLOADING, TOOL[0])
        with open(os.path.join(lib, "steamapps", "appmanifest_%d.acf" % appid), "w") as f:
            f.write(text_vdf({"AppState": {"appid": str(appid), "name": name, "StateFlags": "1030" if downloading else "4",
                                           "BytesToStage": "0"}}))
    stage = {DOWNLOADING: 900 * 1024 * 1024, TOOL[0]: 180 * 1024 * 1024}
    log = []
    for appid, total in stage.items():
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now - 60))
        log += ["[%s] AppID %d state changed : Fully Installed,Update Required,Update Started,Update Running," % (stamp, appid),
                "[%s] AppID %d App update changed : Downloading," % (stamp, appid),
                "[%s] AppID %d update started : download 0/%d, store 0/0, reuse 0/0, delta 0/0, stage 0/%d" % (stamp, appid, total, total)]
    os.makedirs(os.path.join(steam, "logs"))
    with open(os.path.join(steam, "logs", "content_log.txt"), "w") as f:
        f.write("\n".join(log) + "\n")
    # How much of each has arrived; the demo reports this rather than
    # writing gigabytes to disk (see demo.disk_bytes).
    staged = {str(DOWNLOADING): 610 * 1024 * 1024, str(TOOL[0]): 180 * 1024 * 1024}

    # Avatars and media.
    people = [(i, n, s) for i, n, _, s, *_ in FRIENDS] + STRANGERS + [(SELF, "Blip", "online")]
    for n, (i, name, _) in enumerate(people):
        path = os.path.join(img, "avatar-%d.jpg" % i)
        avatar(path, name, COLORS[n % len(COLORS)])
        urls["https://avatars.fastly.steamstatic.com/%040x_medium.jpg" % i] = path
    for appid, icon in icons.items():
        urls["https://demo.invalid/icon/%d.jpg" % appid] = icon
    for gid, name, *_ in GROUP_CHATS:
        avatar(os.path.join(img, "group-%s.jpg" % gid), name, COLORS[int(gid) % len(COLORS)])

    # Screenshots: the art, wide. A short clip made from them.
    shots = []
    for k, appid in enumerate((548430, 1145360, 2379780, 892970)):
        path = os.path.join(img, "shot-%d.jpg" % appid)
        _magick([os.path.join(cache, str(appid), "header.jpg"), "-resize", "1280x598!", path])
        shots.append(path)
        urls["https://demo.invalid/shot/%d.jpg" % appid] = path
    clip = os.path.join(root, "clip.mp4")
    try:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-t", "3", "-i", shots[0],
                        "-loop", "1", "-t", "3", "-i", shots[1], "-filter_complex",
                        "[0][1]xfade=transition=slideleft:duration=1:offset=2,scale=1280:598,format=yuv420p",
                        "-r", "30", clip], check=True, timeout=120)
        urls["https://demo.invalid/clip.mp4"] = clip
    except (OSError, subprocess.SubprocessError):
        pass
    og = os.path.join(img, "og.jpg")
    placeholder(og, 600, 315, "Season 6", "#ff6b6b", size=60)
    urls["https://demo.invalid/og.jpg"] = og
    workshop = os.path.join(img, "workshop.jpg")
    placeholder(workshop, 256, 256, "Lanterns", "#ffb703", size=40)
    urls["https://demo.invalid/workshop.jpg"] = workshop

    world = {
        "now": now,
        "self": SELF,
        "names": {str(a): n for a, n in every},
        "urls": urls,
        "staged": staged,
        "friends": friends_world(now),
        "groups": [{"id": g, "name": n} for g, n in FRIEND_GROUPS],
        "strangers": [{"accountid": i, "name": n, "state": s,
                       "appid": 548430 if s == "in-game" else 0} for i, n, s in STRANGERS],
        "groupChats": [{"id": g, "name": n, "tagline": t, "avatar": os.path.join(img, "group-%s.jpg" % g),
                        "members": m, "rooms": [{"id": r, "name": rn, "unread": u, "mention": men} for r, rn, u, men in rooms],
                        "activity": now - int(h * HOUR)} for g, n, t, m, rooms, h in GROUP_CHATS],
        "chats": chats(now),
        "computers": [{"id": c, "name": n} for c, n in COMPUTERS],
        "remoteApps": {str(a): how["remote"] for a, _, how in LIBRARY if how.get("remote")},
        "folders": [{"index": 0, "path": steam, "label": "", "drive": "nvme0n1", "free": 412 * 1024 ** 3, "isDefault": True},
                    {"index": 1, "path": games_drive, "label": "GAMES", "drive": "sda", "free": 1310 * 1024 ** 3, "isDefault": False}],
        "download": {"appid": DOWNLOADING, "speed": 38 * 1024 * 1024, "eta": 8 * 60},
    }
    with open(os.path.join(root, "world.json"), "w") as f:
        json.dump(world, f, indent=1)
    return world


def friends_world(now):
    groups = {"raid": "raid", "coop": "coop"}
    out = []
    for n, (i, name, nick, state, appid, member_of, unread) in enumerate(FRIENDS):
        out.append({
            "accountid": i, "name": name, "nickname": nick, "state": state, "appid": appid,
            "groups": [groups[g] for g in member_of if g in groups], "favorite": "fav" in member_of,
            "unread": unread, "typing": i == 1001,
            "presence": {548430: "Hazard 4 · Mining Expedition", 1145360: "Escaping Tartarus"}.get(appid, ""),
        })
    return out


def chats(now):
    """Message history: a friend chat showing every kind of card, and a busy group room."""
    t = now - 2 * HOUR

    def at(minutes):
        return t + minutes * 60

    nova = [
        (1001, at(0), "you up for some Deep Rock tonight? [emoticon]steamhappy[/emoticon]", []),
        (SELF, at(1), "always. [b]rock and stone![/b]", [(1, ":steamthumbsup:", 1, False)]),
        (1001, at(3), "the new season just dropped\n[steamstore]https://store.steampowered.com/app/548430/Deep_Rock_Galactic/[/steamstore]", []),
        (SELF, at(5), 'look at this cave [img src="https://demo.invalid/shot/548430.jpg" thumbnail_src="https://demo.invalid/shot/548430.jpg" width=1280 height=598][/img]',
         [(1, ":steamhappy:", 2, True)]),
        (1001, at(8), 'my last run lol [video src="https://demo.invalid/clip.mp4"][/video]', []),
        (1001, at(10), 'patch notes are up: [og url="https://example.com/patch-notes" img="https://demo.invalid/og.jpg" '
                       'title="Season 6 patch notes" desc="New biome, two weapons and a lot of fixes"]https://example.com/patch-notes[/og]', []),
        (SELF, at(14), "grab this mod too, the caves are way less dark "
                       '[publishedfile id=31337 url="https://steamcommunity.com/sharedfiles/filedetails/?id=31337" '
                       'title="Better Lanterns" description="Brighter lanterns and flares" preview_url="https://demo.invalid/workshop.jpg" '
                       'creator_appid=892970 votes_up=812 votes_down=12 num_comments_public=64][/publishedfile]', []),
        (1001, at(20), '[gameinvite appid=548430 message="Join my lobby" lobbyid=90071992547409][/gameinvite]', []),
        (1001, at(21), "lobby's open, hop in when you're ready", []),
    ]
    general = [
        (2001, at(30), "who's on tonight?", []),
        (1007, at(32), "me, after dinner", [(1, ":steamthumbsup:", 3, False)]),
        (1002, at(35), "count me in. bringing snacks for the drop pod", []),
        (1005, at(50), "can't make it, raid night clash [emoticon]steamsad[/emoticon]", []),
        (2002, at(70), "@Blip you hosting?", []),
        (1001, at(75), "yep, lobby at 8 [steamstore]https://store.steampowered.com/app/548430/[/steamstore]", [(1, ":steamhappy:", 4, False)]),
    ]

    def msgs(rows):
        return [{"from": a, "ts": ts, "ordinal": 0, "text": text,
                 "reactions": [{"type": ty, "name": nm, "count": c, "mine": mine} for ty, nm, c, mine in react]}
                for a, ts, text, react in rows]

    out = {"friend:1001": msgs(nova), "group:501:5011": msgs(general)}
    out["friend:1006"] = msgs([(1006, at(60), "saturday still on?", [])])
    out["friend:1002"] = msgs([(SELF, at(40), "see you at 8", []), (1002, at(41), "o7", [])])
    out["group:502:5021"] = msgs([(1003, at(65), "I'll bring the spare monitor", [])])
    return out
