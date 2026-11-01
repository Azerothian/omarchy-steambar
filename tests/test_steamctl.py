import json
import os
import shutil
import socket
import struct
import unittest
from unittest import mock

import support
import cache
import demo
import steamctl


class Arguments(unittest.TestCase):
    def test_digits(self):
        self.assertEqual(steamctl.digits("123", "group"), "123")
        for bad in ("", "12a", "1" * 21, '1"); alert(1); ("'):
            self.assertRaises(ValueError, steamctl.digits, bad, "group")

    def test_chat_target(self):
        self.assertEqual(steamctl.chat_target("42"), "g_FriendsUIApp.ChatStore.GetFriendChat(42, true)")
        self.assertEqual(steamctl.chat_target("5:6"),
                         'g_FriendsUIApp.ChatStore.GetChatRoomGroup("5").GetChatRoom("6")')
        for bad in ("", "1:", "12345678901", "a:b", "1:2:3"):
            self.assertRaises(ValueError, steamctl.chat_target, bad)

    def test_unknown_command(self):
        self.assertRaises(ValueError, steamctl.main, ["steamctl.py", "nope"])

    def test_reaction_names_are_checked(self):
        with mock.patch.object(steamctl, "evaluate") as ev:
            self.assertRaises(ValueError, steamctl.main, ["steamctl.py", "react", "1", "0", "0", "1", "a\"); x(", "add"])
            ev.assert_not_called()

    def test_send_reads_the_message_from_stdin(self):
        with mock.patch.object(steamctl, "evaluate", return_value="sent") as ev, \
                mock.patch.object(steamctl.sys, "stdin", mock.Mock(read=lambda: 'hi "there"')):
            steamctl.main(["steamctl.py", "send", "7"])
        self.assertIn(json.dumps('hi "there"'), ev.call_args[0][0])


class Lookups(unittest.TestCase):
    def setUp(self):
        support.fresh_cache()

    def test_fetched_once_then_cached(self):
        fetch = mock.Mock(return_value={"name": "X"})
        self.assertEqual(steamctl.cached_lookup("apps", 1, fetch), {"name": "X"})
        self.assertEqual(steamctl.cached_lookup("apps", 1, fetch), {"name": "X"})
        fetch.assert_called_once()

    def test_failures_are_retried_after_an_hour(self):
        fetch = mock.Mock(side_effect=OSError("down"))
        self.assertEqual(steamctl.cached_lookup("apps", 2, fetch), {})
        steamctl.cached_lookup("apps", 2, fetch)
        self.assertEqual(fetch.call_count, 1)
        with mock.patch.object(cache, "load_lookup", return_value=({}, 3601)):
            steamctl.cached_lookup("apps", 2, fetch)
        self.assertEqual(fetch.call_count, 2)

    def test_bad_ids_are_not_looked_up(self):
        with mock.patch.object(steamctl, "fetch_small_json") as f:
            self.assertEqual(steamctl.store_app(0), {})
            self.assertEqual(steamctl.store_app("5"), {})
            self.assertEqual(steamctl.youtube_info("short"), {})
            self.assertEqual(steamctl.youtube_info("../../etc/pa"), {})
            f.assert_not_called()

    def test_store_app_keeps_only_https_art(self):
        answer = {"7": {"data": {"name": "Seven", "header_image": "http://plain/h.jpg"}}}
        with mock.patch.object(steamctl, "fetch_small_json", return_value=answer):
            self.assertEqual(steamctl.store_app(7), {"name": "Seven"})


class WebSocketFrames(unittest.TestCase):
    def setUp(self):
        self.ours, self.theirs = socket.socketpair()
        self.ws = object.__new__(steamctl.WebSocket)
        self.ws.sock = self.ours

    def tearDown(self):
        self.ours.close()
        self.theirs.close()

    def frame(self, payload, op=1, fin=True):
        n = len(payload)
        head = bytes([(0x80 if fin else 0) | op])
        head += bytes([n]) if n < 126 else b"\x7e" + struct.pack("!H", n)
        return head + payload

    def test_sent_frames_are_masked(self):
        text = "x" * 300
        self.ws.send(text)
        data = self.theirs.recv(1000)
        self.assertEqual(data[0], 0x81)
        self.assertEqual(data[1], 0x80 | 126)
        (n,) = struct.unpack("!H", data[2:4])
        mask, body = data[4:8], data[8:8 + n]
        self.assertEqual(bytes(b ^ mask[i % 4] for i, b in enumerate(body)).decode(), text)

    def test_fragments_and_pings(self):
        self.theirs.sendall(self.frame(b'{"a":', fin=False) + self.frame(b"", op=9) + self.frame(b"1}", op=0))
        self.assertEqual(self.ws.recv(), '{"a":1}')

    def test_long_frame(self):
        self.theirs.sendall(self.frame(b"y" * 1000))
        self.assertEqual(self.ws.recv(), "y" * 1000)

    def test_close(self):
        self.theirs.sendall(self.frame(b"", op=8))
        self.assertRaises(RuntimeError, self.ws.recv)

    def test_too_large(self):
        self.theirs.sendall(b"\x81\x7f" + struct.pack("!Q", steamctl.MAX_MESSAGE + 1))
        self.assertRaises(RuntimeError, self.ws.recv)


@unittest.skipUnless(support.has_js(), "needs Node or Bun")
class Commands(unittest.TestCase):
    """Each command's script, run against the demo's stand-in Steam client."""

    @classmethod
    def setUpClass(cls):
        support.demo_account()
        cls.saved = {k: getattr(steamctl, k) for k in ("evaluate", "fetch_small_json")}
        demo.patch(steamctl, "steamctl")

    @classmethod
    def tearDownClass(cls):
        for k, v in cls.saved.items():
            setattr(steamctl, k, v)

    def setUp(self):
        support.fresh_cache()
        # Commands that change the chats get a copy of the world each.
        self.world = os.path.join(support.TMP, "world-%s.json" % self._testMethodName)
        shutil.copy(demo.WORLD, self.world)
        patcher = mock.patch.object(demo, "WORLD", self.world)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_cmd(self, *args):
        return steamctl.main(["steamctl.py"] + list(args))

    def test_friends(self):
        value = self.run_cmd("friends")
        friends = {f["accountid"]: f for f in value["friends"]}
        nova, kes = friends["1001"], friends["1002"]
        self.assertEqual((nova["state"], nova["game"], nova["unread"]), ("in-game", "Deep Rock Galactic", 2))
        self.assertEqual(nova["groups"], ["favorites", "raid"])
        self.assertTrue(os.path.exists(nova["avatar"]) and os.path.exists(nova["gameIcon"]))
        self.assertEqual((kes["name"], kes["personaName"]), ("Kes", "Kestrel"))
        self.assertEqual(friends["1011"]["state"], "offline")
        self.assertEqual(value["groups"][0], {"id": "favorites", "name": "Favorites"})
        # Saved for the next start.
        self.assertEqual(len(cache.load_friends()["friends"]), len(friends))

    def test_join_and_invite(self):
        value = self.run_cmd("friends")
        friends = {f["accountid"]: f for f in value["friends"]}
        self.assertEqual(friends["1001"]["join"], "steam://joinlobby/548430/90071992547409/76561197960266729")
        self.assertEqual(friends["1010"]["join"], "steam://rungame/892970/76561197960266738/%2Bconnect%20203.0.113.7%3A27015")
        self.assertEqual(friends["1003"]["join"], "")
        self.assertEqual(value["self"], {"appid": 548430, "game": "Deep Rock Galactic"})
        self.assertEqual(self.run_cmd("invite", "1002"), "invited")
        with open(self.world) as f:
            self.assertEqual(json.load(f)["invites"], [{"to": 1002, "appid": 548430, "lobby": "90071992547410"}])
        self.assertRaises(RuntimeError, self.run_cmd, "invite", "999")
        self.assertRaises(ValueError, self.run_cmd, "invite", "1); x(")

    def test_events(self):
        value = self.run_cmd("events")
        self.assertEqual(value["error"], "")
        texts = [e["text"] for e in value["events"]]
        # Newest first, and no chat messages.
        self.assertEqual(texts, [
            "%s and 2 more from your wishlist are on sale" % demo.name_of(1145360),
            "Kes commented",
            "Gravel Gus sent you a friend invite",
            "3 new items in your inventory",
            "You're invited to the %s playtest" % demo.name_of(892970),
        ])
        comment = value["events"][1]
        self.assertEqual((comment["kind"], comment["detail"], comment["accountid"]),
                         ("comment", "gg last night, that last drop was wild", "1002"))
        self.assertEqual(value["events"][3]["detail"], "Deep Rock Galactic")

    def test_events_are_kept_when_steam_is_gone(self):
        self.run_cmd("events")
        with mock.patch.object(steamctl, "evaluate", side_effect=OSError("refused")):
            value = self.run_cmd("events")
        self.assertEqual(value["error"], "Can't reach Steam. Is it running?")
        self.assertEqual(len(value["events"]), 5)

    def test_friend_changes_join_the_events(self):
        self.run_cmd("friends")
        with open(self.world) as f:
            world = json.load(f)
        next(f for f in world["friends"] if f["accountid"] == 1002).update(state="in-game", appid=553850)
        with open(self.world, "w") as f:
            json.dump(world, f)
        self.run_cmd("friends")
        playing = [e for e in self.run_cmd("events")["events"] if e["kind"] == "playing"]
        self.assertEqual([e["text"] for e in playing], ["Kes started playing HELLDIVERS 2"])

    def test_groups_most_recent_first(self):
        groups = self.run_cmd("groups")
        self.assertEqual([g["name"] for g in groups], ["Deep Rock Diggers", "Weekend LAN", "Speedrun Club"])
        self.assertEqual((groups[0]["unread"], groups[0]["mention"], groups[0]["defaultRoom"]), (3, True, "5011"))

    def test_members_online_first(self):
        members = self.run_cmd("members", "501")
        states = [m["state"] for m in members]
        order = {"in-game": 0, "online": 1, "busy": 2, "away": 2, "offline": 3}
        self.assertEqual(states, sorted(states, key=order.get))
        self.assertFalse(next(m for m in members if m["name"] == "Mira")["isFriend"])
        self.assertRaises(RuntimeError, self.run_cmd, "members", "999")

    def test_remote(self):
        value = self.run_cmd("remote")
        self.assertEqual([d["name"] for d in value["devices"]], ["Living Room PC", "Steam Deck"])
        self.assertEqual(value["apps"]["892970"], ["11", "22"])
        self.assertEqual(value["selected"]["504230"], "22")

    def test_friend_chat_cards(self):
        value = self.run_cmd("chat", "1001")
        self.assertTrue(value["typing"])
        cards = [c for m in value["messages"] for c in m["cards"]]
        self.assertEqual([c["type"] for c in cards], ["store", "image", "video", "link", "workshop", "tag"])
        store = cards[0]
        self.assertEqual((store["appid"], store["name"]), (548430, "Deep Rock Galactic"))
        self.assertTrue(os.path.exists(cards[1]["src"]))
        mine = [m for m in value["messages"] if m["mine"]]
        self.assertEqual(mine[0]["senderName"], "Blip")

    def test_reading_marks_the_chat_read(self):
        self.assertEqual(self.run_cmd("chat", "1001")["unread"], 2)
        self.run_cmd("chat", "1001", "read")
        self.assertEqual(self.run_cmd("chat", "1001")["unread"], 0)

    def test_group_chat_senders(self):
        value = self.run_cmd("chat", "501:5011")
        self.assertIn("Gravel Gus", {m["senderName"] for m in value["messages"]})

    def test_send(self):
        with mock.patch.object(steamctl.sys, "stdin", mock.Mock(read=lambda: "on my way")):
            self.assertEqual(self.run_cmd("send", "1006"), "sent")
        last = self.run_cmd("chat", "1006")["messages"][-1]
        self.assertEqual((last["text"], last["mine"]), ("on my way", True))

    def test_react_and_take_back(self):
        message = self.run_cmd("chat", "1001")["messages"][0]
        args = ["react", "1001", str(message["ts"]), str(message["ordinal"]), "1", ":steamhappy:"]
        self.run_cmd(*args, "add")
        r = self.run_cmd("chat", "1001")["messages"][0]["reactions"]
        self.assertEqual(r, [{"type": 1, "name": ":steamhappy:", "count": 1, "mine": True}])
        self.run_cmd(*args, "remove")
        self.assertEqual(self.run_cmd("chat", "1001")["messages"][0]["reactions"], [])

    def test_downloads(self):
        self.assertEqual(self.run_cmd("overview")["appid"], 105600)
        self.assertEqual(self.run_cmd("pause", "105600"), "paused")
        self.assertTrue(self.run_cmd("overview")["paused"])
        self.assertEqual(self.run_cmd("resume", "105600"), "resumed")
        self.assertFalse(self.run_cmd("overview")["paused"])

    def test_folders_and_actions(self):
        self.assertEqual([f["label"] for f in self.run_cmd("folders")], ["", "GAMES"])
        self.assertEqual(self.run_cmd("stream", "892970", "22"), "streaming")
        self.assertEqual(self.run_cmd("desktop", "11"), "streaming")
        self.assertEqual(self.run_cmd("uninstall", "620"), "uninstalling")
        self.assertEqual(self.run_cmd("wizard-state"), 0)
        self.assertEqual(self.run_cmd("install", "440", "1"), "cancelled")
        self.assertRaises(ValueError, self.run_cmd, "stream", "1", "x")


if __name__ == "__main__":
    unittest.main()
