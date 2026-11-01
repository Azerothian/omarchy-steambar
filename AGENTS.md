# Agent notes

Steam bar widget for Omarchy's shell (plugin id `blip.steam`). The UI is one QML file,
`Panel.qml`; the Python helpers it runs are `steam.py` (local Steam files, store requests,
caches), `steamctl.py` (talks to the Steam client's debugging port: chat, installs, live
friends) and `cache.py`. `demo/` is a stand-in Steam account and client, and `tests/` holds the unit tests.

## Testing a change locally

The dev checkout is the installed plugin, so there's nothing to copy. The repo itself lives
at `~/.config/omarchy/plugins/blip.steam`, and `~/dev/omarchy-steambar` is a symlink to it.

1. Save your changes, then restart the shell:

   ```sh
   omarchy-restart-shell
   ```

   The shell does reload the plugin by itself on save (`Local plugin changed, reloading:
   blip.steam` in `journalctl --user`), but that reload can keep running the old QML: a
   moved button still showed in its old place after it. Only a restart reliably loads the
   new `Panel.qml`. The bar blinks for a moment while it restarts.

2. Open the popup (`omarchy-shell blip.steam toggle`, or `tab friends` and so on) and check
   the change by eye. `omarchy-shell blip.steam image <https url>` opens the image viewer
   and `video <https url>` the video one; `grim` can screenshot them for a look without
   clicking around.

Whatever branch is checked out is what the bar runs, uncommitted edits included.

### Why the link points this way

The shell finds changes with `inotifywait -r` on `~/.config/omarchy/plugins`, and recursive
inotify doesn't follow symlinks. With `plugins/blip.steam` as a symlink to a checkout
elsewhere, the plugin still loads but saves never even trigger the reload. With the real files under
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
  modules). The real check is restarting the shell and looking at the result.
- QML JavaScript here has no semicolons: a line starting with `[` or `(` joins onto the line
  above it. Start it with a variable instead.
