# Agent notes

Steam bar widget for Omarchy's shell (plugin id `blip.steam`). The UI is one QML file,
`Panel.qml`; the Python helpers it runs are `steam.py` (local Steam files, store requests,
caches), `steamctl.py` (talks to the Steam client's debugging port: chat, installs, live
friends) and `cache.py`. `demo/` is a stand-in Steam account and client, and `tests/` holds the unit tests.

## Testing a change locally

The dev checkout is the installed plugin, so every save is live. The repo itself lives at
`~/.config/omarchy/plugins/blip.steam`, and `~/dev/omarchy-steambar` is a symlink to it.

1. Save a file. The shell watches `~/.config/omarchy/plugins` and reloads the plugin by
   itself; no copy, no restart. Check that it loaded:

   ```sh
   journalctl --user --since "-1min" | grep -iE "blip|Panel.qml"
   ```

   `Local plugin changed, reloading: blip.steam` with no QML errors after it means it loaded.

2. Open the popup (`omarchy-shell blip.steam toggle`, or `tab friends` and so on) and check
   the change by eye.

Whatever branch is checked out is what the bar runs, uncommitted edits included.

### Why the link points this way

The shell finds changes with `inotifywait -r` on `~/.config/omarchy/plugins`, and recursive
inotify doesn't follow symlinks. With `plugins/blip.steam` as a symlink to a checkout
elsewhere, the plugin still loads but saves never reload it. With the real files under
`plugins/` and the dev path as the symlink, saves land in the watched folder.

The watcher skips `.git`, so git commands don't reload the plugin. Writes anywhere else in
the repo do, including `.omc/` and `.serena/`.

To set this up on a new machine:

```sh
git clone https://github.com/Azerothian/omarchy-steambar ~/.config/omarchy/plugins/blip.steam
ln -s ~/.config/omarchy/plugins/blip.steam ~/dev/omarchy-steambar
omarchy plugin enable blip.steam
```

Don't run `omarchy plugin update` on this plugin; update it with git yourself. That command
fast-forwards whatever branch is checked out to the remote's default branch, and if the result
fails validation it runs `git reset --hard`, which throws away uncommitted edits.

To test without your own Steam data, `python3 -m demo on` switches the widget to the invented
demo account, and `python3 -m demo off` switches back (see the README).

## Checks

- `python3 -m unittest discover -s tests` runs the Python helpers and the JavaScript that
  `steamctl.py` sends to Steam. Nothing covers `Panel.qml`.
- `qmllint Panel.qml` prints nothing useful here (it can't resolve the shell's `qs.*`
  modules), so the reload log in step 3 is the real check that the QML loads.
- QML JavaScript here has no semicolons: a line starting with `[` or `(` joins onto the line
  above it. Start it with a variable instead.
