"""Shared setup for the tests: import this before the plugin's modules.

  python3 -m unittest discover -s tests      (from the plugin's folder)

The tests never touch your Steam or the widget's cache: one demo account
(see demo/world.py) is built offline into a temporary folder per run, and
the cache is pointed there.
"""
import atexit
import os
import shutil
import sys
import tempfile

PLUGIN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp(prefix="blip-steam-tests-")
atexit.register(shutil.rmtree, TMP, True)

os.environ["BLIP_STEAM_DEMO"] = "0"            # ignore a demo switched on for the widget
os.environ["BLIP_STEAM_DEMO_DIR"] = os.path.join(TMP, "demo")
os.environ["BLIP_STEAM_DEMO_OFFLINE"] = "1"    # placeholder art, no downloads
os.environ.pop("STEAM_API_KEY", None)
sys.path.insert(0, PLUGIN)

import cache  # noqa: E402
import demo  # noqa: E402

cache.CACHE = os.path.join(TMP, "cache")
cache.DB = os.path.join(cache.CACHE, "steam.db")

_built = None


def demo_account():
    """The demo account's world (built on first use, once per run)."""
    global _built
    if _built is None:
        from demo import world
        _built = world.build(demo.ROOT, offline=True)
    return _built


def fresh_cache():
    """An empty cache database for one test."""
    if cache._db is not None:
        cache._db.close()
        cache._db = None
    if os.path.exists(cache.CACHE):
        shutil.rmtree(cache.CACHE)


def has_js():
    try:
        demo.runtime()
        return True
    except RuntimeError:
        return False
