"""The helpers as the widget runs them (separate processes, JSON out), in
demo mode: every command the panel uses answers, and nothing reaches Steam."""
import json
import os
import subprocess
import sys
import unittest

import support
import demo


def run(script, *args, stdin=""):
    env = dict(os.environ, BLIP_STEAM_DEMO="1")
    p = subprocess.run([sys.executable, os.path.join(support.PLUGIN, script)] + list(args), input=stdin,
                       capture_output=True, text=True, timeout=60, env=env)
    return json.loads(p.stdout)


class Switch(unittest.TestCase):
    def test_off_by_default(self):
        self.assertFalse(demo.ACTIVE)   # support.py sets BLIP_STEAM_DEMO=0

    def test_flag_file_and_variable(self):
        code = "import demo; print(demo.ACTIVE)"
        env = dict(os.environ)
        env.pop("BLIP_STEAM_DEMO")
        env["XDG_RUNTIME_DIR"] = support.TMP
        out = lambda: subprocess.run([sys.executable, "-c", code], cwd=support.PLUGIN, env=env,
                                     capture_output=True, text=True).stdout.strip()
        self.assertEqual(out(), "False")
        open(os.path.join(support.TMP, "blip-steam-demo"), "w").close()
        try:
            self.assertEqual(out(), "True")
            env["BLIP_STEAM_DEMO"] = "0"
            self.assertEqual(out(), "False")
        finally:
            os.remove(os.path.join(support.TMP, "blip-steam-demo"))

    def test_offline_fetch_refuses_other_hosts(self):
        self.assertRaises(OSError, demo.fetch, "https://steamcommunity.com/miniprofile/1")


class SteamPy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        support.demo_account()

    def test_games(self):
        self.assertEqual(len(run("steam.py", "games")["games"]), 20)

    def test_downloads(self):
        out = run("steam.py", "downloads")
        self.assertTrue(out["controllable"])
        self.assertEqual(out["downloads"][0]["name"], "Terraria")

    def test_store(self):
        lists = run("steam.py", "storelists")
        self.assertEqual(lists["top"]["games"][0]["name"], "HELLDIVERS 2")
        self.assertEqual(run("steam.py", "store", "2379780")["name"], "Balatro")

    def test_cached_friends_and_collapsed(self):
        self.assertEqual(run("steam.py", "set-collapsed", '["raid"]'), {})
        self.assertEqual(run("steam.py", "friends-cached")["collapsed"], ["raid"])


@unittest.skipUnless(support.has_js(), "needs Node or Bun")
class SteamCtl(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        support.demo_account()

    def test_every_command_the_panel_reads(self):
        for args in (["friends"], ["groups"], ["members", "502"], ["remote"], ["folders"], ["overview"],
                     ["chat", "1002"], ["chat", "502:5021"], ["wizard-state"]):
            out = run("steamctl.py", *args)
            self.assertTrue(out["ok"], (args, out))

    def test_errors_are_reported_not_raised(self):
        out = run("steamctl.py", "chat", "not-a-chat")
        self.assertEqual(out, {"ok": False, "error": "not a chat: not-a-chat"})


if __name__ == "__main__":
    unittest.main()
