"""Demo mode: the widget running on a made-up Steam account.

  python3 -m demo on      build the account (see world.py) and switch to it
  python3 -m demo off     back to your own Steam
  python3 -m demo build   rebuild the account without switching
  python3 -m demo status

(run from the plugin's folder). While it's on, the helpers read the demo's
Steam folder and cache instead of yours, answer the store's requests from
the demo catalogue, and send the scripts meant for Steam's debugging port to
a stand-in client (fake_steam.js, run with Node or Bun) that holds the demo's
friends, chats and Remote Play computers. Nothing reaches your Steam.

The switch is a file in $XDG_RUNTIME_DIR, so it ends at logout, and the
running shell picks it up without a restart; BLIP_STEAM_DEMO=1 turns it on
for one command (the tests use that, with BLIP_STEAM_DEMO_DIR).
"""
import glob
import json
import os
import shutil
import subprocess
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
FLAG = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "blip-steam-demo")
ROOT = os.environ.get("BLIP_STEAM_DEMO_DIR") or os.path.expanduser("~/.cache/blip-steam-demo")
ACTIVE = os.environ.get("BLIP_STEAM_DEMO", "") == "1" or (os.environ.get("BLIP_STEAM_DEMO", "") != "0" and os.path.exists(FLAG))

STEAM = os.path.join(ROOT, "steam")
CACHE = os.path.join(ROOT, "cache")
WORLD = os.path.join(ROOT, "world.json")


def state():
    with open(WORLD) as f:
        return json.load(f)


# ---------- the stand-in Steam client ----------
def runtime():
    """Node, or Bun (the shell's PATH may only have one of them)."""
    for name in ("node", "bun"):
        path = shutil.which(name)
        if path:
            return path
    found = sorted(glob.glob(os.path.expanduser("~/.config/nvm/versions/node/*/bin/node"))
                   + glob.glob(os.path.expanduser("~/.nvm/versions/node/*/bin/node"))) \
        + [p for p in (os.path.expanduser("~/.bun/bin/bun"),) if os.path.exists(p)]
    if not found:
        raise RuntimeError("Demo mode needs Node or Bun to stand in for Steam")
    return found[-1]


def evaluate(js, timeout=15):
    """What steamctl.evaluate does, answered by fake_steam.js."""
    p = subprocess.run([runtime(), os.path.join(HERE, "fake_steam.js"), WORLD], input=js,
                       capture_output=True, text=True, timeout=min(timeout, 30))
    try:
        out = json.loads(p.stdout)
    except ValueError:
        raise RuntimeError("demo client: %s" % (p.stderr.strip() or "no answer")[-300:])
    if not out.get("ok"):
        raise RuntimeError(out.get("error") or "JS error")
    return local_urls(out.get("value"), state().get("urls", {}))


def local_urls(value, urls):
    """The client hands out web addresses (avatars, shared images); the demo
    has those files on disk."""
    if isinstance(value, str):
        return urls.get(value, value)
    if isinstance(value, list):
        return [local_urls(v, urls) for v in value]
    if isinstance(value, dict):
        return {k: local_urls(v, urls) for k, v in value.items()}
    return value


# ---------- the store, offline ----------
def fetch(url, timeout=10, limit=None):
    """steam.fetch for the demo: the store endpoints the widget calls,
    answered from the catalogue."""
    if not isinstance(url, str):
        url = url.full_url
    from . import world as w
    u = urllib.parse.urlparse(url)
    q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
    if u.path == "/search/results/":
        kind = {"filter=topsellers": "top", "filter=popularcomingsoon": "upcoming"}.get(
            "filter=" + q.get("filter", ""), "new")
        start = int(q.get("start", 0))
        rows = "".join('<a href="#" data-ds-appid="%d"><div class="search_released">%s</div></a>' % (a, released(a))
                       for a in w.STORE[kind][start:start + 100])
        return json.dumps({"results_html": rows}).encode()
    if u.path.endswith("/IStoreBrowseService/GetItems/v1/"):
        ids = [i["appid"] for i in json.loads(q["input_json"])["ids"]]
        return json.dumps({"response": {"store_items": [store_item(a) for a in ids]}}).encode()
    if u.path == "/api/appdetails":
        appid = int(q["appids"])
        return json.dumps({str(appid): {"success": True, "data": app_details(appid)}}).encode()
    if u.path.startswith("/appreviews/"):
        return json.dumps({"reviews": REVIEWS}).encode()
    if u.path.endswith("/IStoreService/GetTagList/v1/"):
        return json.dumps({"response": {"tags": [{"tagid": i, "name": n} for i, n in w.TAGS]}}).encode()
    if u.netloc == "www.youtube.com" and u.path == "/oembed":
        return json.dumps({"title": "Deep Rock Galactic - Season 6 Trailer", "author_name": "Ghost Ship Games"}).encode()
    raise OSError("demo mode is offline: %s" % url)


def fetch_small_json(url):
    return json.loads(fetch(url))


def name_of(appid):
    from . import world as w
    return dict((a, n) for a, n, _ in w.LIBRARY).get(appid) or w.STORE_GAMES.get(appid, ("App %d" % appid,))[0]


def released(appid):
    return "Coming soon" if appid >= 9900000 else ["Oct 3, 2024", "Feb 20, 2024", "Sep 17, 2020", "Mar 13, 2018"][appid % 4]


def price(appid):
    from . import world as w
    if appid in w.FREE or appid >= 9900000:
        return "", 0
    if appid in w.PRICES:
        return w.PRICES[appid]
    p = w.STORE_GAMES.get(appid)
    return (p[1], p[2]) if p and p[1] else ("$19.99", 0)


def store_item(appid):
    from . import world as w
    final, off = price(appid)
    item = {"appid": appid, "success": 1, "type": 0, "name": name_of(appid), "is_free": appid in w.FREE,
            "is_early_access": appid == 9900002,
            "best_purchase_option": {"formatted_final_price": final, "discount_pct": off} if final else {},
            "tags": [{"tagid": t} for t, _ in w.TAGS[appid % 3:appid % 3 + 5]],
            "platforms": {"steam_deck_compat_category": 3 if appid % 2 else 2},
            "reviews": {"summary_filtered": {"review_score_label": "Overwhelmingly Positive", "percent_positive": 97,
                                             "review_count": 250000 + appid % 9000},
                        "summary_language_specific": {"review_score_label": "Overwhelmingly Positive",
                                                      "percent_positive": 96, "review_count": 180000 + appid % 7000}}}
    return item


def app_details(appid):
    from . import world as w
    root = state()
    final, off = price(appid)
    shots = [p for u, p in root["urls"].items() if u.startswith("https://demo.invalid/shot/")]
    portrait = os.path.join(STEAM, "appcache", "librarycache", str(appid), "library_600x900.jpg")
    blurb = w.BLURBS.get(appid, "%s is part of the demo's catalogue." % name_of(appid))
    about = ("<h2>About This Game</h2><p>%s</p><p>Team up with friends or go it alone, and see how far you get.</p>"
             '<img src="%s" width="600" height="900"><h2>Features</h2><ul><li>Co-op for up to four players</li>'
             "<li>Hand-crafted levels</li><li>Full controller support</li></ul>" % (blurb, portrait))
    media = {"movies": [{"thumbnail": shots[0], "mp4": {"max": root["urls"]["https://demo.invalid/clip.mp4"]}}]} \
        if "https://demo.invalid/clip.mp4" in root["urls"] else {}
    return dict(media, **{
        "name": name_of(appid), "short_description": blurb, "is_free": appid in w.FREE,
        "price_overview": {"final_formatted": final, "initial_formatted": "$29.99" if off else final, "discount_percent": off}
        if final else {},
        "release_date": {"coming_soon": appid >= 9900000, "date": released(appid)},
        "developers": ["Demo Studio"], "publishers": ["Demo Publishing"],
        "categories": [{"description": d} for d in ("Single-player", "Online Co-op", "Steam Achievements", "Full controller support")],
        "platforms": {"windows": True, "mac": appid % 2 == 0, "linux": True},
        "supported_languages": "English<strong>*</strong>, French, German<br><strong>*</strong>languages with full audio support",
        "achievements": {"total": 48}, "dlc": [1, 2],
        "screenshots": [{"path_thumbnail": s, "path_full": s} for s in shots],
        "about_the_game": about,
        "pc_requirements": {"minimum": "<strong>Minimum:</strong><br><ul><li>OS: SteamOS or Windows 10</li><li>Memory: 8 GB RAM</li></ul>",
                            "recommended": "<strong>Recommended:</strong><br><ul><li>Memory: 16 GB RAM</li></ul>"},
    })


REVIEWS = [
    {"voted_up": True, "review": "Forty hours in and I still say 'one more run' every night.", "votes_up": 1204,
     "author": {"playtime_forever": 2460}},
    {"voted_up": True, "review": "Best co-op I've played with my friends in years.", "votes_up": 877,
     "author": {"playtime_forever": 6100}},
    {"voted_up": False, "review": "Great game, but the late game drags a little for me.", "votes_up": 143,
     "author": {"playtime_forever": 1300}},
]


# ---------- switching the helpers over ----------
def disk_bytes(path):
    """Downloads in the demo report made-up progress instead of filling the disk."""
    return state().get("staged", {}).get(os.path.basename(path.rstrip("/")), 0)


def patch(module, name):
    """Point one of the helper modules ("steam", "steamctl" or "cache") at the demo."""
    if name == "cache":
        module.CACHE = CACHE
        module.DB = os.path.join(CACHE, "steam.db")
        return
    import cache
    patch(cache, "cache")
    if name == "steam":
        module.STEAM = STEAM
        module.CACHE = CACHE
        module.DEBUG_FLAG = os.path.join(STEAM, ".cef-enable-remote-debugging")
        module.fetch = fetch
        module.disk_bytes = disk_bytes
        module.steam_reachable = lambda: True
        module.steam_running = lambda: True
        module.steam_overview = lambda: evaluate(_steamctl().OVERVIEW_JS)
    elif name == "steamctl":
        module.evaluate = evaluate
        module.fetch_small_json = fetch_small_json


def _steamctl():
    import steamctl
    patch(steamctl, "steamctl")
    return steamctl


def ensure_built():
    if not os.path.exists(WORLD):
        from . import world as w
        w.build(ROOT, offline=os.environ.get("BLIP_STEAM_DEMO_OFFLINE") == "1")
