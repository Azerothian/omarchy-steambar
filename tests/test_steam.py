import json
import os
import time
import unittest
from unittest import mock

import support
import demo
import steam
from demo import world


class Basics(unittest.TestCase):
    def test_clip_obj_number_seq(self):
        self.assertEqual(steam.clip("abcdef", 3), "abc")
        self.assertEqual(steam.clip(5, 3), "")
        self.assertEqual(steam.obj([1]), {})
        self.assertEqual(steam.number(True), 0)
        self.assertEqual(steam.number(2.5), 2.5)
        self.assertEqual(steam.seq("abc", 2), [])
        self.assertEqual(steam.seq([1, 2, 3], 2), [1, 2])

    def test_case_insensitive_lookup(self):
        d = {"AppState": {"Name": "x"}}
        self.assertEqual(steam.ci(d, "appstate"), {"Name": "x"})
        self.assertEqual(steam.ci(d, "missing"), {})
        self.assertEqual(steam.ci("not a dict", "x"), {})

    def test_read_json_max_age(self):
        path = os.path.join(support.TMP, "age.json")
        steam.write_json(path, {"a": 1})
        self.assertEqual(steam.read_json(path), {"a": 1})
        self.assertEqual(steam.read_json(path, max_age=60), {"a": 1})
        old = time.time() - 120
        os.utime(path, (old, old))
        self.assertIsNone(steam.read_json(path, max_age=60))
        self.assertIsNone(steam.read_json(path + ".missing"))


class TextVdf(unittest.TestCase):
    def test_nested_and_escaped(self):
        text = '"root"\n{\n\t"name"\t\t"say \\"hi\\""\n\t"path"\t\t"C:\\\\Games"\n\t"inner"\n\t{\n\t\t"k"\t"v"\n\t}\n}\n'
        self.assertEqual(steam.parse_text_vdf(text), {"root": {"name": 'say "hi"', "path": "C:\\Games", "inner": {"k": "v"}}})

    def test_round_trip_with_the_demo_writer(self):
        d = {"a": {"b": "1", "c": {"d": 'q"uote'}}, "e": "back\\slash"}
        self.assertEqual(steam.parse_text_vdf(world.text_vdf(d)), d)

    def test_unbalanced_braces_do_not_crash(self):
        self.assertEqual(steam.parse_text_vdf('}"a"{"b""c"'), {"a": {"b": "c"}})


class AppInfo(unittest.TestCase):
    def check(self, version):
        path = os.path.join(support.TMP, "appinfo-%d.vdf" % version)
        with open(path, "wb") as f:
            f.write(world.appinfo_vdf({10: ("Counter-Strike", "Game"), 228980: ("Redist", "Tool")}, version))
        self.assertEqual(steam.parse_appinfo(path), {10: {"name": "Counter-Strike", "type": "game"},
                                                     228980: {"name": "Redist", "type": "tool"}})

    def test_v29_string_table(self):
        self.check(29)

    def test_v28_inline_keys(self):
        self.check(28)


class DemoSteam(unittest.TestCase):
    """steam.py's readers against the demo account's Steam folder."""

    @classmethod
    def setUpClass(cls):
        cls.world = support.demo_account()
        cls.saved = {k: getattr(steam, k) for k in ("STEAM", "CACHE", "DEBUG_FLAG", "fetch", "disk_bytes",
                                                     "steam_reachable", "steam_running", "steam_overview")}
        demo.patch(steam, "steam")

    @classmethod
    def tearDownClass(cls):
        for k, v in cls.saved.items():
            setattr(steam, k, v)

    def setUp(self):
        support.fresh_cache()

    def test_current_user(self):
        self.assertEqual(steam.current_user(), {"steamid": world.account(world.SELF), "accountid": "1000", "name": "Blip"})

    def test_games(self):
        games = steam.games()["games"]
        names = [g["name"] for g in games]
        # Library games only (not the runtime, not store-only games), most recent first.
        self.assertEqual(len(games), len(world.LIBRARY))
        self.assertNotIn(world.TOOL[1], names)
        self.assertEqual(names[:2], ["Hades", "Deep Rock Galactic"])
        hades = games[0]
        self.assertTrue(hades["installed"])
        self.assertEqual(hades["playtime"], 62 * 60)
        self.assertTrue(hades["portrait"].endswith("1145360/library_600x900.jpg"))
        self.assertTrue(os.path.exists(hades["icon"]))
        never = [g for g in games if not g["lastPlayed"]]
        self.assertEqual([g["name"] for g in never], sorted(g["name"] for g in never))
        self.assertFalse(next(g for g in games if g["appid"] == 1086940)["installed"])

    def test_appinfo_is_cached_until_steam_rewrites_it(self):
        steam.read_appinfo()
        with mock.patch.object(steam, "parse_appinfo", side_effect=AssertionError("parsed again")):
            self.assertIn(620, steam.read_appinfo())
        path = os.path.join(steam.STEAM, "appcache", "appinfo.vdf")
        with open(path, "ab") as f:
            f.write(b"\0")
        try:
            with mock.patch.object(steam, "parse_appinfo", return_value={}) as parse:
                steam.read_appinfo()
                parse.assert_called_once()
        finally:
            with open(path, "rb+") as f:
                f.truncate(os.path.getsize(path) - 1)

    def test_art_falls_back_to_the_cdn(self):
        header, icon, portrait = steam.art_for(123)
        self.assertEqual(icon, "")
        self.assertTrue(header.startswith("https://") and header.endswith("/123/header.jpg"))
        self.assertTrue(portrait.endswith("/123/library_600x900.jpg"))

    def test_library_paths_dedupe(self):
        paths = steam.library_paths()
        self.assertEqual(paths[0], steam.STEAM)
        self.assertEqual(len(paths), 2)

    def test_downloads_fold_the_runtime_into_the_game(self):
        out = steam.downloads()
        self.assertTrue(out["controllable"])
        self.assertEqual(len(out["downloads"]), 1)
        d = out["downloads"][0]
        self.assertEqual((d["name"], d["status"]), ("Terraria", "downloading"))
        self.assertEqual(d["total"], (900 + 180) * 1024 * 1024)
        self.assertAlmostEqual(d["progress"], (610 + 180) / (900 + 180))
        self.assertEqual(d["speed"], self.world["download"]["speed"])

    def test_community_friends_with_nicknames(self):
        def status(accountid):
            return {"state": "in-game" if accountid == "1001" else "online", "name": "", "statusText": "",
                    "game": "Deep Rock Galactic" if accountid == "1001" else "", "gameIcon": "", "appid": 0}
        with mock.patch.object(steam, "fetch_status", side_effect=status), mock.patch.object(steam.time, "sleep"):
            people = {p["accountid"]: p for p in steam.friends()["friends"]}
        self.assertEqual(len(people), len(world.FRIENDS))
        self.assertEqual(people["1001"]["state"], "in-game")
        self.assertEqual((people["1002"]["name"], people["1002"]["personaName"]), ("Kes", "Kestrel"))
        self.assertTrue(people["1003"]["avatar"].startswith("https://avatars.fastly.steamstatic.com/"))
        # Saved for the next start.
        self.assertEqual(len(steam.cache.load_friends()["friends"]), len(world.FRIENDS))

    def test_community_friends_stop_at_the_first_refusal(self):
        calls = []

        def refuse(accountid):
            calls.append(accountid)
            raise OSError("HTTP 500")
        with mock.patch.object(steam, "fetch_status", side_effect=refuse), mock.patch.object(steam.time, "sleep"):
            people = steam.friends()["friends"]
        self.assertEqual(len(calls), 1)
        self.assertTrue(all(p["state"] == "unknown" for p in people))

    def test_store_lists(self):
        lists = steam.store_lists()
        self.assertEqual({k: len(v["games"]) for k, v in lists.items()},
                         {k: len(v) for k, v in world.STORE.items()})
        top = lists["top"]["games"]
        self.assertEqual([g["rank"] for g in top], list(range(1, len(top) + 1)))
        cs2 = next(g for g in top if g["appid"] == 730)
        self.assertEqual((cs2["free"], cs2["price"]), (True, "Free"))
        # Cached for an hour.
        with mock.patch.object(steam, "fetch", side_effect=AssertionError("fetched again")):
            self.assertEqual(steam.store_list("top")["games"], top)

    def test_store_list_keeps_the_last_copy_when_offline(self):
        good = steam.store_list("new")
        path = os.path.join(steam.CACHE, "store-new.json")
        steam.write_json(path, dict(good, time=0))
        with mock.patch.object(steam, "fetch", side_effect=OSError("offline")):
            self.assertEqual(steam.store_list("new")["games"], good["games"])
        os.remove(path)
        with mock.patch.object(steam, "fetch", side_effect=OSError("offline")):
            self.assertIn("error", steam.store_list("new"))

    def test_store_page(self):
        page = steam.store_page(548430)
        self.assertEqual(page["name"], "Deep Rock Galactic")
        self.assertEqual((page["price"], page["discount"], page["initialPrice"]), ("$29.99", 75, "$29.99"))
        self.assertEqual(page["deck"], "Playable")
        self.assertEqual([b["type"] for b in page["about"]], ["text", "image", "text"])
        self.assertEqual(page["languages"], "English*, French, German")
        self.assertEqual(page["media"][0]["type"], "video")
        self.assertEqual(len(page["topReviews"]), 3)
        self.assertTrue(page["tags"])

    def test_store_page_errors(self):
        with mock.patch.object(steam, "fetch", side_effect=OSError("offline")):
            self.assertIn("Couldn't load", steam.store_page(4242)["error"])

    def test_clear_cache(self):
        steam.store_list("top")
        self.assertGreaterEqual(steam.clear_cache()["cleared"], 1)
        self.assertFalse(os.path.exists(os.path.join(steam.CACHE, "store-top.json")))


class Profiles(unittest.TestCase):
    PAGE = ('<div class="persona in-game">Some &amp; One</div>'
            '<span class="friend_status_in-game">In-Game</span>'
            '<span class="miniprofile_game_name">Hades</span>'
            '<img class="game_logo" src="https://cdn.example/steam/apps/1145360/logo.jpg">')

    def fetched(self, page):
        with mock.patch.object(steam, "fetch", return_value=page.encode()):
            return steam.fetch_status("5")

    def test_in_game(self):
        self.assertEqual(self.fetched(self.PAGE), {"state": "in-game", "name": "Some & One", "statusText": "In-Game",
                                                    "game": "Hades", "appid": 1145360,
                                                    "gameIcon": "https://cdn.example/steam/apps/1145360/logo.jpg"})

    def test_snooze_reads_as_away(self):
        s = self.fetched('<div class="persona online">X</div><span class="friend_status_online">Snooze</span>')
        self.assertEqual(s["state"], "away")

    def test_private_profile(self):
        self.assertEqual(self.fetched("<html></html>")["state"], "offline")


class Downloads(unittest.TestCase):
    def test_log_states(self):
        log = ("[2026-01-01 10:00:00] AppID 5 state changed : Fully Installed,Update Running,\n"
               "[2026-01-01 10:00:01] AppID 5 App update changed : Downloading,\n"
               "[2026-01-01 10:00:02] AppID 5 update started : download 0/100, stage 3/200\n")
        folder = os.path.join(support.TMP, "logsteam")
        os.makedirs(os.path.join(folder, "logs"), exist_ok=True)
        with open(os.path.join(folder, "logs", "content_log.txt"), "w") as f:
            f.write(log)
        with mock.patch.object(steam, "STEAM", folder):
            self.assertEqual(steam.log_states(), {5: {"state": "Fully Installed,Update Running,", "phase": "Downloading,",
                                                      "download": 100, "stage": 200}})

    def test_fold_tools_alone_keeps_the_tool(self):
        tool = {"type": "tool", "total": 10, "staged": 5, "status": "downloading"}
        self.assertEqual(steam.fold_tools([tool], {}), [tool])

    def test_fold_tools_moves_the_game_with_the_tool(self):
        game = {"type": "game", "total": 100, "staged": 0, "status": "queued", "progress": 0}
        tool = {"type": "tool", "total": 100, "staged": 50, "status": "downloading", "speed": 9, "eta": 3}
        out = steam.fold_tools([game, tool], {"downloading": 0, "queued": 1})
        self.assertEqual(out, [{"type": "game", "total": 200, "staged": 50, "status": "downloading",
                                "progress": 0.25, "speed": 9, "eta": 3}])


class Markup(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(steam.plain("<b>Fish</b>, &amp; chips"), "Fish, & chips")

    def test_styled_lists_and_paragraphs(self):
        self.assertEqual(steam.styled("<p>One</p><p>Two</p><ul><li>A</li><li>B</li></ul>"), "One<br><br>Two<br>• A<br>• B")
        self.assertEqual(steam.styled('<H1 class="x">T</H1><span>s</span><em>e</em>'), "<h3>T</h3>s<i>e</i>")

    def test_description_blocks(self):
        blocks = steam.description_blocks('<p>Intro</p><img src="a.png" width="10" height="20"><p>More</p>'
                                          '<video poster="p.jpg"><source src="v.webm"><source src="v.mp4"></video>')
        self.assertEqual(blocks, [{"type": "text", "text": "Intro"}, {"type": "image", "src": "a.png", "w": 10, "h": 20},
                                  {"type": "text", "text": "More"},
                                  {"type": "video", "src": "v.mp4", "poster": "p.jpg", "w": 0, "h": 0}])

    def test_local_image_leaves_other_formats(self):
        self.assertEqual(steam.local_image("https://x/y.jpg"), "https://x/y.jpg")


class Fetch(unittest.TestCase):
    class Answer:
        def __init__(self, body, length=None):
            self.body, self.headers = body, {"Content-Length": length} if length else {}

        def read(self, n):
            return self.body[:n]

        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

    def test_size_limits(self):
        with mock.patch.object(steam.urllib.request, "urlopen", return_value=self.Answer(b"x" * 11)):
            self.assertRaises(ValueError, steam.fetch, "https://x", limit=10)
        with mock.patch.object(steam.urllib.request, "urlopen", return_value=self.Answer(b"", "99")):
            self.assertRaises(ValueError, steam.fetch, "https://x", limit=10)
        with mock.patch.object(steam.urllib.request, "urlopen", return_value=self.Answer(b"[1]")):
            self.assertRaises(ValueError, steam.fetch_json, "https://x")
        with mock.patch.object(steam.urllib.request, "urlopen", return_value=self.Answer(json.dumps({"a": 1}).encode())):
            self.assertEqual(steam.fetch_json("https://x"), {"a": 1})


if __name__ == "__main__":
    unittest.main()
