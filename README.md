# Steam for Omarchy

A bar widget for [Omarchy](https://omarchy.org)'s shell that puts Steam in a popup:

<p>
  <img src="screenshots/tour.gif" alt="The Steam popup switching between the Store, Recent and Library tabs" height="340">
  <img src="screenshots/store-page.gif" alt="Store pages with trailers open beside the list" height="340">
</p>

- **Store**: the store's top 50 sellers, popular upcoming games and popular new releases.
  Click a game you don't own (or press `i` on any game) to open its store page right in the
  popup: trailers and screenshots, description, reviews, tags, Steam Deck status, system
  requirements and the most helpful reviews. Buying opens Steam.
- **Recent**: your recently played, installed games. Click to play.
- **Library**: everything you own, searchable (`/`). It opens on **Installed** games, which
  includes games installed on your other computers (Remote Play): click one to stream it, or hover
  to pick another computer or install here. With other computers around, chips at the top pick
  which computer's games to show (hover one and press ▶ to Remote Play its desktop), and the list
  is split into a section per computer (**Group by computer**). The **Installed**, **Most played**
  and **Uninstalled** chips filter and sort; uninstalled games install to the drive of your choice.
- **Groups**: your Steam group chats (named groups, Steam group chats and chats with several
  friends), newest first, with unread counts. Open one to read and write in it, switch between its
  rooms, or pop it out into its own window. Needs Steam's debugging port.
- **Downloads**: live progress, speed and time left, with pause/resume. Collapse the section
  with its header or `d`.
- **Friends**: who's online and what they're playing, with chat in the popup.

It reads the Steam client's own files, so there's no sign-in or API key to set up.

## Install

```sh
omarchy plugin add https://github.com/BlippyOhNo/omarchy-steam.git --enable
```

Then log in to Steam (native `steam` or the Flatpak). The widget shows the account that last
logged in on the machine.

Everything it needs ships with Omarchy: Python 3, `jq`, ImageMagick (store page art is AVIF,
which Qt can't show, so it's converted) and Qt Multimedia (trailers).

### Optional: install, pause and chat from the popup

Steam has no command line for installing into a chosen folder, pausing downloads or chatting.
The widget does those through Steam's local debugging port, which is off by default. To turn it
on, create this file and restart Steam:

```sh
touch ~/.local/share/Steam/.cef-enable-remote-debugging
# Flatpak Steam: ~/.var/app/com.valvesoftware.Steam/.local/share/Steam/.cef-enable-remote-debugging
```

While it's on, **any program on your computer can control your Steam client** through
`localhost:8080`. Without it the widget still works: installs and chat open in Steam, and
pause/resume is hidden.

## Settings

The **Settings** tab (the gear at the end of the menu, or `5`) saves as you go, into this widget's
entry in `~/.config/omarchy/shell.json`:

- **Steam Web API key** (optional), with steps and a link to
  [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey): your exact friend list and
  status in one request when the debugging port is off, instead of reading public profiles.
- **Steam control**: whether the debugging port is connected, and if not, what's limited and the
  command to turn it on.
- **Layout**: the menu on the left or across the top; open on the first tab (on by default).
  Drag the tabs in the menu to reorder them.
- **Library**: games in Recent, start with **Installed** ticked, and the folder to install new games
  to (text matched against your Steam library folders' paths, e.g. `GAMES` for
  `/run/media/you/GAMES/SteamLibrary`; empty uses Steam's default).
- **Friends and chat**: show offline friends, Steam names beside nicknames, the time on each
  message, and which friend groups to show as rows of avatars above the
  friends search instead of in the list (with what they're playing; click to chat). The box on a
  group's header in the list promotes it; untick it in Settings to bring it back.
- **Cache**: clear what's kept in `~/.cache/blip-steam`.

## Keys

| Key | Action |
| --- | --- |
| `1`–`5` | The tabs, in the menu's order |
| `6` or `,` | Settings |
| `←` `→` | Previous/next list or tab (flip media when a store page is open) |
| `↑` `↓`, `Enter` | Move, then play / install / open |
| `i` | Store page for the selected game |
| `PgUp` `PgDn` | Scroll the store page |
| `/` | Search the library |
| `d` | Collapse or expand downloads |
| `x` `x` | Uninstall the selected game |
| `r` | Refresh |
| `Esc` | Close the store page, then the popup |

From a script or keybinding:

```sh
omarchy-shell blip.steam toggle
omarchy-shell blip.steam tab store        # store | recent | library | friends | groups | settings
omarchy-shell blip.steam store 1091500    # open a game's store page by app id
omarchy-shell blip.steam popout 12345678  # chat with a friend (by account id) in its own window
omarchy-shell blip.steam groupchat 50739  # open a group chat (by group id)
```

## What it talks to

Local Steam files (library, playtime, friends list, downloads) and, over HTTPS, Steam's public
store and community endpoints. Store lists are cached for an hour and store pages for six hours
in `~/.cache/blip-steam`. Prices are in US dollars.

## Update / remove

```sh
omarchy plugin update blip.steam
omarchy plugin remove blip.steam
```

## License

MIT, see [LICENSE](LICENSE).
