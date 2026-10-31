"""python3 -m demo on|off|build|status (from the plugin's folder)."""
import os
import sys

from . import FLAG, ROOT, WORLD
from . import world


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    offline = os.environ.get("BLIP_STEAM_DEMO_OFFLINE") == "1"
    if cmd in ("on", "build"):
        world.build(ROOT, offline=offline)
        print("Built the demo account in %s" % ROOT)
    if cmd == "on":
        open(FLAG, "w").close()
        print("Demo mode is on: the widget shows the demo account from its next refresh.")
    elif cmd == "off":
        if os.path.exists(FLAG):
            os.remove(FLAG)
        print("Demo mode is off.")
    elif cmd == "status":
        print("Demo mode is %s (%s)." % ("on" if os.path.exists(FLAG) else "off",
                                         "built" if os.path.exists(WORLD) else "not built yet"))
    elif cmd != "build":
        sys.exit(__doc__)


main(sys.argv)
