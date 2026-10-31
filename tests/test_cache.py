import time
import unittest

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


if __name__ == "__main__":
    unittest.main()
