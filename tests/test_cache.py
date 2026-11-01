import time
import unittest
from unittest import mock

import support
import cache


class FriendSnapshot(unittest.TestCase):
    def setUp(self):
        support.fresh_cache()

    def test_empty_until_saved(self):
        self.assertEqual(cache.load_friends(), {"friends": [], "groups": [], "collapsed": []})

    def test_round_trip_keeps_order_and_drops_unread(self):
        friends = [{"accountid": "2", "name": "B", "unread": 4}, {"accountid": "1", "name": "A", "unread": 0}]
        cache.save_friends(friends, [{"id": "7", "name": "Raid"}])
        got = cache.load_friends()
        self.assertEqual([f["accountid"] for f in got["friends"]], ["2", "1"])
        self.assertTrue(all(f["unread"] == 0 for f in got["friends"]))
        self.assertEqual(got["groups"], [{"id": "7", "name": "Raid"}])

    def test_unchanged_snapshot_is_not_rewritten(self):
        cache.save_friends([{"accountid": "1", "name": "A"}], [])
        db = cache.connect()
        before = db.total_changes
        cache.save_friends([{"accountid": "1", "name": "A"}], [])
        self.assertEqual(db.total_changes, before)
        cache.save_friends([{"accountid": "1", "name": "Renamed"}], [])
        self.assertGreater(db.total_changes, before)
        self.assertEqual(cache.load_friends()["friends"][0]["name"], "Renamed")

    def test_ignores_rows_that_are_not_objects(self):
        cache.save_friends([{"accountid": "1"}, "junk", None], ["junk"])
        self.assertEqual(len(cache.load_friends()["friends"]), 1)

    def test_collapsed_sections(self):
        cache.save_collapsed(["online", 7, {"bad": 1}])
        self.assertEqual(cache.load_friends()["collapsed"], ["online", "7"])


class Lookups(unittest.TestCase):
    def setUp(self):
        support.fresh_cache()

    def test_missing(self):
        self.assertEqual(cache.load_lookup("apps", 1), (None, None))

    def test_saved_with_age(self):
        cache.save_lookup("embeds", "youtube:x", {"title": "T"})
        info, age = cache.load_lookup("embeds", "youtube:x")
        self.assertEqual(info, {"title": "T"})
        self.assertLess(age, 5)

    def test_unknown_table_is_refused(self):
        self.assertEqual(cache.load_lookup("friends; DROP TABLE meta", 1), (None, None))

    def test_statuses(self):
        cache.save_statuses({"5": {"state": "online", "checked": int(time.time())}})
        self.assertEqual(cache.load_statuses()["5"]["state"], "online")


class Clear(unittest.TestCase):
    def setUp(self):
        support.fresh_cache()

    def test_clear_keeps_collapsed_sections(self):
        cache.save_friends([{"accountid": "1"}], [{"id": "g", "name": "G"}])
        cache.save_collapsed(["g"])
        cache.save_lookup("apps", 10, {"name": "X"})
        cache.save_statuses({"1": {"state": "away"}})
        cache.clear()
        self.assertEqual(cache.load_friends(), {"friends": [], "groups": [], "collapsed": ["g"]})
        self.assertEqual(cache.load_lookup("apps", 10), (None, None))
        self.assertEqual(cache.load_statuses(), {})


class EventLog(unittest.TestCase):
    def setUp(self):
        support.fresh_cache()

    def test_newest_first_and_replaced_by_id(self):
        cache.add_events([{"id": "a", "ts": 1, "n": 1}, {"id": "b", "ts": 2}])
        cache.add_events([{"id": "a", "ts": 3, "n": 2}])
        self.assertEqual([(e["id"], e.get("n")) for e in cache.load_events()], [("a", 2), ("b", None)])

    def test_kept_to_the_limit(self):
        with mock.patch.object(cache, "MAX_EVENTS", 3):
            cache.add_events([{"id": str(i), "ts": i} for i in range(5)])
        self.assertEqual([e["id"] for e in cache.load_events()], ["4", "3", "2"])


def friend(accountid, state, appid=0, game=""):
    return {"accountid": accountid, "state": state, "appid": appid, "game": game, "name": "F" + accountid}


class Presence(unittest.TestCase):
    def setUp(self):
        support.fresh_cache()

    def kinds(self):
        return sorted((e["kind"], e["accountid"], e.get("game", "")) for e in cache.load_events())

    def test_changes_between_refreshes(self):
        cache.log_presence([friend("1", "offline"), friend("2", "online"), friend("3", "in-game", 620, "Portal 2"),
                            friend("4", "online"), friend("5", "in-game", 70, "Half-Life")], now=1000)
        self.assertEqual(cache.load_events(), [])  # the first list is only a baseline
        cache.log_presence([friend("1", "online"), friend("2", "offline"), friend("3", "online"),
                            friend("4", "in-game", 440, "TF2"), friend("5", "offline")], now=1020)
        self.assertEqual(self.kinds(), [("offline", "2", ""), ("offline", "5", ""), ("online", "1", ""),
                                        ("playing", "4", "TF2"), ("stopped", "3", "Portal 2")])

    def test_nothing_across_a_long_gap(self):
        cache.log_presence([friend("1", "offline")], now=1000)
        cache.log_presence([friend("1", "online")], now=1000 + cache.PRESENCE_GAP + 1)
        self.assertEqual(cache.load_events(), [])
        cache.log_presence([friend("1", "offline")], now=1000 + cache.PRESENCE_GAP + 30)
        self.assertEqual(self.kinds(), [("offline", "1", "")])

    def test_unknown_states_are_skipped(self):
        cache.log_presence([friend("1", "unknown")], now=1000)
        cache.log_presence([friend("1", "online")], now=1010)
        self.assertEqual(cache.load_events(), [])


if __name__ == "__main__":
    unittest.main()
