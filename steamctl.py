#!/usr/bin/env python3
"""Control the running Steam client through its CEF debugging port.

Steam's UI runs in an embedded browser; with the flag file
~/.local/share/Steam/.cef-enable-remote-debugging present it listens on
localhost:8080, and its SharedJSContext page exposes the SteamClient API the
client's own UI uses. This is how Decky Loader talks to Steam too.

  steamctl.py folders               -> Steam library folders with free space
  steamctl.py overview              -> live download overview (speed, ETA, paused)
  steamctl.py pause <appid>         -> pause a download
  steamctl.py resume <appid>        -> resume a download
  steamctl.py install <appid> <folder index>
                                    -> install without Steam's window
  steamctl.py uninstall <appid>     -> uninstall a game (no confirmation dialog)
  steamctl.py friends               -> friend list with live presence and unread counts
  steamctl.py groups                -> your group chats and their rooms
  steamctl.py members <group id>    -> everyone in a group chat, online first
  steamctl.py remote                -> other computers online and the games they can stream
  steamctl.py stream <appid> <client id>
                                    -> stream a game from one of them
  steamctl.py desktop <client id>   -> Remote Play another computer's desktop
  steamctl.py chat <chat> [read]    -> recent messages in a chat ("read" marks them read);
                                       <chat> is a friend's account id or groupid:roomid
  steamctl.py react <accountid> <ts> <ordinal> <type> <reaction> add|remove
                                    -> react to a message (or take it back)
  steamctl.py send <accountid>      -> send the chat message read from stdin
                                       (never argv, where other users can see it)
  steamctl.py wizard-state          -> install wizard state (8 = showing a EULA)
  steamctl.py eval '<js>'           -> JSON result of the expression

Every command prints {"ok": true, "value": ...} or {"ok": false, "error": ...}.
"""
import base64
import json
import os
import re
import socket
import struct
import sys
import urllib.error
import urllib.request

import cache

PORT = 8080
# Byte ceilings for what Steam's debug port hands back, and for what's
# printed to the widget.
MAX_TARGETS = 1024 * 1024
MAX_MESSAGE = 16 * 1024 * 1024
MAX_OUTPUT = 8 * 1024 * 1024
MAX_APPINFO = 1024 * 1024


def target_ws():
    with urllib.request.urlopen("http://127.0.0.1:%d/json" % PORT, timeout=3) as r:
        pages = r.read(MAX_TARGETS + 1)
    if len(pages) > MAX_TARGETS:
        raise RuntimeError("Steam's debug target list is too large")
    pages = json.loads(pages)
    if not isinstance(pages, list):
        raise RuntimeError("Steam's SharedJSContext isn't available")
    for p in pages:
        if isinstance(p, dict) and p.get("title") == "SharedJSContext":
            return p["webSocketDebuggerUrl"]
    raise RuntimeError("Steam's SharedJSContext isn't available")


class WebSocket:
    """Just enough RFC 6455 for CDP: text frames, client masking, no extensions."""

    def __init__(self, url):
        rest = url.split("://", 1)[1]
        hostport, path = rest.split("/", 1)
        host, port = hostport.split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=15)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            "GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, hostport, key)
        ).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise RuntimeError("websocket handshake failed")
            head += chunk
            if len(head) > 16384:
                raise RuntimeError("websocket handshake failed")
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise RuntimeError("websocket handshake refused")

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("websocket closed")
            buf += chunk
        return buf

    def send(self, text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            header = struct.pack("!BB", 0x81, 0x80 | n)
        elif n < 65536:
            header = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        else:
            header = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        message = b""
        while True:
            b1, b2 = self._recv(2)
            n = b2 & 0x7F
            if n == 126:
                n, = struct.unpack("!H", self._recv(2))
            elif n == 127:
                n, = struct.unpack("!Q", self._recv(8))
            if len(message) + n > MAX_MESSAGE:
                raise RuntimeError("Steam's answer was too large")
            payload = self._recv(n)
            op = b1 & 0x0F
            if op == 8:
                raise RuntimeError("websocket closed")
            if op in (0, 1, 2):
                message += payload
                if b1 & 0x80:
                    return message.decode("utf-8", "replace")


def evaluate(js, timeout=15):
    ws = WebSocket(target_ws())
    ws.sock.settimeout(timeout)
    ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {
        "expression": js, "awaitPromise": True, "returnByValue": True}}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get("id") == 1:
            break
    result = msg.get("result", {})
    if "exceptionDetails" in result:
        d = result["exceptionDetails"]
        raise RuntimeError(d.get("exception", {}).get("description") or d.get("text", "JS error"))
    return result.get("result", {}).get("value")


FOLDERS_JS = """
SteamClient.InstallFolder.GetInstallFolders().then(f => f.filter(x => x.bIsMounted).map(x => ({
  index: x.nFolderIndex, path: x.strFolderPath, label: x.strUserLabel, drive: x.strDriveName,
  free: x.nFreeSpace, isDefault: x.bIsDefaultFolder })))
"""

OVERVIEW_JS = """
new Promise((resolve, reject) => {
  const h = SteamClient.Downloads.RegisterForDownloadOverview(o => {
    h.unregister()
    resolve({ appid: o.update_appid, state: o.update_state, paused: o.paused,
      networkBytesPerSecond: o.update_network_bytes_per_second,
      diskBytesPerSecond: o.update_disc_bytes_per_second,
      percent: o.overall_percent_complete, eta: o.overall_estimated_time_remaining_sec })
  })
  setTimeout(() => reject(new Error("no download overview from Steam")), 3000)
})
"""

# Steam's own Downloads page pauses the running download by pausing the whole
# queue, and pauses anything else by taking it out of the queue.
PAUSE_JS = """
new Promise(resolve => {
  const h = SteamClient.Downloads.RegisterForDownloadOverview(o => {
    h.unregister()
    if (o.update_appid === %(appid)d) SteamClient.Downloads.EnableAllDownloads(false, "0")
    else SteamClient.Downloads.PauseAppUpdate(%(appid)d, "0")
    resolve("paused")
  })
})
"""

RESUME_JS = """
SteamClient.Downloads.ResumeAppUpdate(%(appid)d, "0");
SteamClient.Downloads.EnableAllDownloads(true, "0");
"resumed"
"""

# Installing goes through Steam's install wizard: open it, wait until it's
# asking where to install (state 7), pick the folder and continue. Windows
# Steam opens meanwhile (the wizard dialog, and the main window if Steam
# brings it up to host the dialog) are hidden the moment they're created, via
# a popup-created hook installed once per Steam session.
#
# A game with a licence agreement then moves to state 8: the wizard dialog is
# shown with the EULA, and this waits (up to 10 minutes) for it to be
# accepted or declined there. If the wizard stops anywhere else it's left
# showing so it can be finished by hand.
INSTALL_JS = """
(async () => {
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  const hide = p => { try { p.window.SteamClient.Window.HideWindow() } catch (e) {} }
  const show = p => { try { p.window.SteamClient.Window.ShowWindow(); p.window.SteamClient.Window.BringToFront() } catch (e) {} }
  // Versioned so a changed hook installs even if an older one is loaded.
  if (!window.__blipSteamHook3) {
    window.__blipSteamHook3 = true
    g_PopupManager.AddPopupCreatedCallback(p => {
      if (window.__blipQuietUntil > Date.now() && !/contextmenu/.test(p.m_strName || "")) hide(p)
    })
  }
  const S = { None: 0, ShowConfig: 7, ShowEULAs: 8, Complete: 14, Failed: 15, Canceled: 16 }
  const desk = () => g_PopupManager.GetExistingPopup("SP Desktop_uid0")
  const mainWasVisible = !!desk() && !desk().window.document.hidden
  const wizard = () => Array.from(g_PopupManager.GetPopups()).filter(p => /Install/.test(p.m_strName || ""))
  // Steam re-shows its (already existing) main window to host the wizard,
  // which the popup hook can't catch, so keep it hidden while working quietly.
  let quiet = true
  const guard = setInterval(() => {
    if (!quiet) return
    const d = desk()
    if (d && !mainWasVisible && !d.window.document.hidden) hide(d)
  }, 30)
  const finish = result => {
    quiet = false
    clearInterval(guard)
    window.__blipQuietUntil = 0
    if (result !== "needs-steam") {
      for (const p of wizard()) hide(p)
      const d = desk()
      if (d && !mainWasVisible) hide(d)
    }
    return result
  }
  const reveal = () => {
    quiet = false
    window.__blipQuietUntil = 0
    const d = desk()
    if (d) show(d)
    for (const p of wizard()) show(p)
  }
  const state = async () => (await SteamClient.Installs.GetInstallManagerInfo()).eInstallState
  const waitUntil = async (done, ms) => {
    const end = Date.now() + ms
    let s = await state()
    while (!done(s) && Date.now() < end) { await sleep(100); s = await state() }
    return s
  }
  // Licence agreement: that's for you to accept, so show it and wait.
  const eula = async () => {
    reveal()
    const s = await waitUntil(s => s !== S.ShowEULAs, 600000)
    quiet = true
    window.__blipQuietUntil = Date.now() + 5000
    return s
  }
  const ended = s => s === S.None || s === S.Complete || s === S.Failed || s === S.Canceled

  window.__blipQuietUntil = Date.now() + 5000
  SteamClient.Installs.OpenInstallWizard([%(appid)d])
  let s = await waitUntil(s => s === S.ShowConfig || s === S.ShowEULAs || ended(s), 8000)
  if (s === S.ShowEULAs) {
    await eula()
    s = await waitUntil(s => s === S.ShowConfig || ended(s), 8000)
  }
  if (s === S.ShowEULAs || (s !== S.ShowConfig && !ended(s))) { reveal(); return finish("needs-steam") }
  if (s !== S.ShowConfig) return finish(s === S.Failed ? "failed" : "cancelled")

  window.__blipQuietUntil = Date.now() + 5000
  SteamClient.Installs.SetInstallFolder(%(folder)d)
  SteamClient.Installs.ContinueInstall()
  // Starting an install also starts the queue, so make that explicit.
  SteamClient.Downloads.EnableAllDownloads(true, "0")
  s = await waitUntil(s => s === S.ShowEULAs || ended(s), 8000)
  if (s === S.ShowEULAs) s = await eula()
  s = await waitUntil(ended, 8000)
  if (!ended(s)) { reveal(); return finish("needs-steam") }
  await sleep(300)
  if (s === S.Failed) return finish("failed")
  if (s === S.Complete) return finish("installing")
  // Declined or closed: check whether it made it into the download queue.
  const listed = await new Promise(resolve => {
    const h = SteamClient.Downloads.RegisterForDownloadItems((paused, items) => {
      h.unregister()
      resolve((items || []).some(c => (c.item_data || []).some(i => i.appid === %(appid)d && !i.completed)))
    })
    setTimeout(() => resolve(false), 2000)
  })
  return finish(listed ? "installing" : "cancelled")
})()
"""


# A Steam player (a friend, a group member, a chat sender) as the widget shows
# them: name, avatar, presence, and the game they're in with its icon.
PERSONA_JS = r"""(() => {
  const states = ["offline", "online", "busy", "away", "away", "online", "online"]
  const avatar = hash => hash && !/^0+$/.test(hash) ? "https://avatars.fastly.steamstatic.com/" + hash + "_medium.jpg" : ""
  const of = f => {
    const p = f.m_persona || {}
    const appid = p.m_unGamePlayedAppID || 0
    const inGame = (appid > 0 || (p.m_gameid && p.m_gameid !== "0")) && (p.m_ePersonaState || 0) !== 0
    let game = "", gameIcon = ""
    if (inGame) {
      game = p.m_strGameExtraInfo || f.current_game_name || ""
      if (!game && appid) {
        try { game = (g_FriendsUIApp.AppInfoStore.GetAppInfo(appid) || {}).name || "" } catch (e) {}
      }
      // A full URL, or the hash Steam's community CDN files the icon under.
      try {
        const icon = String(f.current_game_icon_url || "")
        gameIcon = /^https:\/\//.test(icon) ? icon
          : appid && /^[0-9a-f]{40}$/i.test(icon) ? "https://cdn.fastly.steamstatic.com/steamcommunity/public/images/apps/" + appid + "/" + icon + ".jpg" : ""
      } catch (e) {}
    }
    const persona = p.m_strPlayerName || ""
    const name = f.display_name || f.m_strNickname || persona || String(f.accountid)
    return {
      accountid: String(f.accountid),
      steamid: String(f.steamid64 || (p.m_steamid && p.m_steamid.ConvertTo64BitString ? p.m_steamid.ConvertTo64BitString() : "")),
      name: name,
      personaName: persona && persona !== name ? persona : "",
      avatar: avatar(p.m_strAvatarHash),
      state: inGame ? "in-game" : states[p.m_ePersonaState || 0] || "online",
      game: game,
      appid: inGame ? appid : 0,
      gameIcon: gameIcon,
    }
  }
  return { of: of }
})()"""

FRIENDS_JS = """
(() => {
  const app = g_FriendsUIApp
  const persona = %(persona)s
  // The user's own friend groups (Steam's categories) and favorites, as the
  // client's friend list shows them.
  const store = app.FriendStore.FriendGroupStore
  const groups = Array.from((store && store.user_groups) || []).map(g => ({
    id: String(g.m_iGroupID), name: g.m_strName || "", members: Array.from(g.m_rgAccountIDMembers || []),
  }))
  let favorites = []
  try {
    favorites = Array.from(app.FriendStore.FavoritesStore.favorites || [])
      .filter(x => x && x.friend).map(x => x.friend.accountid)
  } catch (e) {}
  const memberOf = {}
  for (const g of groups) for (const a of g.members) (memberOf[a] = memberOf[a] || []).push(g.id)
  for (const a of favorites) (memberOf[a] = memberOf[a] || []).unshift("favorites")
  const friends = Array.from(app.FriendStore.all_friends || []).map(f => {
    let presence = ""
    try { presence = f.current_game_rich_presence || "" } catch (e) {}
    const chat = app.ChatStore.GetFriendChat(f.accountid, false)
    return Object.assign(persona.of(f), {
      presence: presence,
      groups: memberOf[f.accountid] || [],
      unread: chat ? chat.unread_message_count || 0 : 0,
    })
  })
  return {
    friends: friends,
    groups: (favorites.length ? [{ id: "favorites", name: "Favorites" }] : [])
      .concat(groups.map(g => ({ id: g.id, name: g.name }))),
  }
})()
"""

# Messages are BBCode; turn the common tags into plain text for the widget.
CHAT_JS = """
(async () => {
  const chat = %(target)s
  if (!chat) throw new Error("That chat isn't available")
  if (!chat.m_bChatLogsLoaded) await chat.LoadChatLogs()
  if (%(read)s) chat.OnActivate()
  const me = g_FriendsUIApp.FriendStore.self.accountid
  // Escaped brackets (\\[) are literal text: park them while tags are stripped.
  const plain = s => String(s || "")
    .replace(/\\\\\\[/g, "\\u0001")
    .replace(/\\[emoticon\\](.*?)\\[\\/emoticon\\]/g, ":$1:")
    .replace(/\\[sticker[^\\]]*\\](.*?)\\[\\/sticker\\]/g, "(sticker)")
    .replace(/\\[url=([^\\]]*)\\](.*?)\\[\\/url\\]/g, "$2 ($1)")
    .replace(/\\[img[^\\]]*\\](.*?)\\[\\/img\\]/g, "(image) $1")
    .replace(/\\[\\/?[a-z]+[^\\]]*\\]/gi, "")
    .replace(/\\u0001/g, "[")
  const html = %(html)s
  const embeds = %(embeds)s
  // Who wrote each message: group chats show the sender's name.
  const persona = %(persona)s
  const senders = {}
  const sender = id => {
    if (!senders[id]) {
      let who = { name: String(id), avatar: "" }
      try { who = persona.of(g_FriendsUIApp.FriendStore.GetPlayer(id)) } catch (e) {}
      senders[id] = who
    }
    return senders[id]
  }
  const msgs = chat.chat_messages.slice(-80).map(m => {
    const e = embeds(m.strMessage !== undefined ? m.strMessage : m.strMessageInternal)
    const from = sender(m.unAccountID)
    return {
    mine: m.unAccountID === me,
    accountid: String(m.unAccountID),
    senderName: from.name,
    senderAvatar: from.avatar,
    text: plain(e.rest).trim(),
    html: html(e.rest.trim()),
    cards: e.cards,
    // Emoticon (type 1) or sticker reactions: how many, and whether you're one.
    reactions: (m.m_rgReactions || []).map(r => ({
      type: r.eReactionType, name: r.strReaction, count: r.cReactors, mine: !!r.bUserReacted,
    })),
    ordinal: m.unOrdinal,
    ts: m.rtTimestamp,
    key: m.rtTimestamp + ":" + m.unOrdinal + ":" + (m.m_iLocalEchoID || 0),
    pending: m.unAccountID === me && !m.m_bServerAcknowledged && m.unOrdinal < 0,
    failed: !!(m.eErrorSending || m.eErrorSendingObservable),
  }})
  return { messages: msgs, typing: !!chat.is_friend_typing, unread: chat.unread_message_count || 0 }
})()
"""

# The same BBCode as Qt StyledText for the chat bubble: clickable links
# (tagged and bare), inline emoticons and stickers, basic bold/italic.
HTML_JS = r"""(s => {
  const CDN = "https://steamcommunity-a.akamaihd.net/economy/"
  const KNOWN = /^(spoiler|code|quote|pre|noparse|strike|s|h[1-6]|list|olist|table|tr|td|th|hr|flip|random|lobbyinvite|gameinvite|tradeoffer|broadcastinvite|giphy|video|og|embed|mention|roomeffect|reply|sticker|emoticon|img|url)$/
  const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  const link = (href, label) => /^(https?|steam):/i.test(href)
    ? '<a href="' + esc(href) + '">' + label + '</a>' : label
  const text = t => t.split(/(https?:\/\/[^\s<>"\[\]]+)/i).map((part, i) => {
    if (i % 2 === 0) return esc(part).replace(/\n/g, "<br>")
    const trail = (part.match(/[.,;:!?)']+$/) || [""])[0]
    const url = part.slice(0, part.length - trail.length)
    return link(url, esc(url)) + esc(trail)
  }).join("")
  const img = (src, size) => '<img src="' + esc(src) + '" width="' + size + '" height="' + size + '" align="middle">'
  // Escaped brackets (\[) are literal text: park them while tags are handled.
  s = String(s || "").replace(/\\\[/g, "\u0001")
  const out = []
  const re = /\[(\/?)([a-z]+)((?:=[^\]]*)|(?:\s[^\]]*))?\]/gi
  let last = 0, m, inUrl = null
  const flush = end => {
    const chunk = s.slice(last, end).replace(/\u0001/g, "[")
    if (inUrl) inUrl.label += chunk
    else out.push(text(chunk))
  }
  const arg = (a, key) => {
    const r = new RegExp(key + '="([^"]*)"').exec(a || "")
    return r ? r[1] : ""
  }
  while ((m = re.exec(s))) {
    flush(m.index)
    last = re.lastIndex
    const close = m[1] === "/", tag = m[2].toLowerCase(), a = m[3] || ""
    if (tag === "emoticon" && !close) {
      const end = s.indexOf("[/emoticon]", last)
      const name = s.slice(last, end < 0 ? s.length : end)
      out.push(img(CDN + "emoticon/" + encodeURIComponent(name), 20))
      last = re.lastIndex = end < 0 ? s.length : end + 11
    } else if (tag === "sticker" && !close) {
      const end = s.indexOf("[/sticker]", last)
      out.push((out.join("") ? "<br>" : "") + img(CDN + "sticker/" + encodeURIComponent(arg(a, "type")), 96))
      last = re.lastIndex = end < 0 ? last : end + 10
    } else if (tag === "img" && !close) {
      const end = s.indexOf("[/img]", last)
      const src = arg(a, "src") || s.slice(last, end < 0 ? s.length : end)
      out.push(link(src, "(image)"))
      last = re.lastIndex = end < 0 ? s.length : end + 6
    } else if (tag === "url") {
      if (!close) inUrl = { href: a.charAt(0) === "=" ? a.slice(1).replace(/^"|"$/g, "") : "", label: "" }
      else if (inUrl) {
        const href = inUrl.href || inUrl.label
        out.push(link(href, esc(inUrl.label || href)))
        inUrl = null
      }
    } else if (["b", "i", "u"].indexOf(tag) >= 0) {
      if (!inUrl) out.push("<" + (close ? "/" : "") + tag + ">")
    } else if (!KNOWN.test(tag)) {
      // Not Steam markup (e.g. "[brb]"): keep it as typed.
      last = m.index
      flush(re.lastIndex)
      last = re.lastIndex
    }
  }
  flush(s.length)
  if (inUrl) out.push(link(inUrl.href || inUrl.label, esc(inUrl.label || inUrl.href)))
  return out.join("")
})"""

# Store links and Workshop items arrive as [steamstore] and [publishedfile]
# tags; lift them out of the text as cards the chat bubble draws.
EMBEDS_JS = r"""(s => {
  const cards = []
  // Values come quoted (with \" escapes) or bare, as [img src=... width=949].
  const attr = (a, key) => {
    const r = new RegExp("\\b" + key + '=(?:"((?:[^"\\\\]|\\\\.)*)"|([^\\s"\\]]+))').exec(a || "")
    return !r ? "" : r[1] !== undefined ? r[1].replace(/\\(.)/g, "$1") : r[2]
  }
  const num = v => parseInt(v, 10) || 0
  const rest = String(s || "").replace(/\[(publishedfile|steamstore)(\s[^\]]*)?\]([\s\S]*?)\[\/\1\]/gi, (all, tag, a, body) => {
    body = body.trim()
    if (tag.toLowerCase() === "steamstore") {
      const appid = num(attr(a, "app")) || num((body.match(/\/app\/(\d+)/) || [])[1])
      if (!appid) return all
      // The link's slug is the game's name (Lightyear_Frontier).
      let name = (body.match(/\/app\/\d+\/([^\/?#]+)/) || [])[1] || ""
      try { name = decodeURIComponent(name) } catch (e) {}
      cards.push({ type: "store", appid: appid, name: name.replace(/_/g, " ").trim(),
        url: /^https?:/.test(body) ? body : "https://store.steampowered.com/app/" + appid })
    } else {
      const url = attr(a, "url") || body
      if (!/^https?:/.test(url)) return all
      cards.push({ type: "workshop", url: url, title: attr(a, "title"), description: attr(a, "description"),
        preview: attr(a, "preview_url"), appid: num(attr(a, "creator_appid")),
        votesUp: num(attr(a, "votes_up")), votesDown: num(attr(a, "votes_down")),
        comments: num(attr(a, "num_comments_public")) })
    }
    return ""
  })
  // Shared images: [img src=... thumbnail_src=... width=... height=...][url=...]...[/url][/img],
  // or plainly [img]https://...[/img].
  const left = rest.replace(/\[img(\s[^\]]*)?\]([\s\S]*?)\[\/img\]/gi, (all, a, body) => {
    const src = attr(a, "src") || (body.match(/https?:\/\/[^\s\[\]"]+/) || [""])[0]
    if (!/^https?:/.test(src)) return all
    cards.push({ type: "image", src: src, thumb: attr(a, "thumbnail_src") || src,
      width: num(attr(a, "width")), height: num(attr(a, "height")) })
    return ""
  })
  // Steam-hosted videos and YouTube links get players of their own.
  const media = left
    .replace(/\[video(\s[^\]]*)?\]([\s\S]*?)\[\/video\]/gi, (all, a, body) => {
      const src = attr(a, "src") || (body.match(/https?:\/\/[^\s\[\]"]+/) || [""])[0]
      if (!/^https:\/\//.test(src)) return all
      cards.push({ type: "video", src: src })
      return ""
    })
    .replace(/\[youtube(=[^\s\]]+)?(\s[^\]]*)?\]([\s\S]*?)\[\/youtube\]/gi, (all, first, a, body) => {
      const url = (first || "").slice(1) || body.trim()
      const id = attr(a, "v") || (url.match(/(?:v=|youtu\.be\/|shorts\/)([\w-]{11})/) || [])[1] || ""
      if (!/^[\w-]{11}$/.test(id)) return all
      cards.push({ type: "youtube", id: id, url: "https://www.youtube.com/watch?v=" + id })
      return ""
    })
  // Link previews: [og url=... img=... title=... desc=...]url[/og].
  const previewed = media.replace(/\[og(\s[^\]]*)?\]([\s\S]*?)\[\/og\]/gi, (all, a, body) => {
    const url = attr(a, "url") || body.trim()
    if (!/^https?:\/\//.test(url)) return all
    const img = attr(a, "img")
    cards.push({ type: "link", url: url, title: attr(a, "title"), description: attr(a, "desc"),
      preview: /^https:\/\//.test(img) ? img : "" })
    return ""
  })
  // Any other Steam tag ([roomeffect], ...) becomes a card
  // listing what it carries, with the original to copy. Plain bracketed
  // text like [brb] has no closing tag or fields, so it stays as typed.
  const RENDERED = /^(url|b|i|u|emoticon|sticker)$/i
  const fields = a => {
    const out = []
    a = a || ""
    const first = /^=("[^"]*"|[^\s\]]+)/.exec(a)
    if (first) out.push(["", first[1].replace(/^"|"$/g, "")])
    const re = /([a-z_][a-z0-9_]*)=(?:"((?:[^"\\]|\\.)*)"|([^\s"\]]+))/gi
    let m
    while ((m = re.exec(a.slice(first ? first[0].length : 0))) && out.length < 20)
      out.push([m[1], m[2] !== undefined ? m[2].replace(/\\(.)/g, "$1") : m[3]])
    return out
  }
  const tagCard = (all, tag, a, body) => {
    if (RENDERED.test(tag)) return all
    cards.push({ type: "tag", tag: tag.toLowerCase(), fields: fields(a), body: (body || "").replace(/\[\/?[a-z][^\]]*\]/gi, "").trim().slice(0, 2000),
      raw: all.slice(0, 20000) })
    return ""
  }
  const tagged = previewed
    .replace(/\[([a-z][a-z0-9_]*)((?:=|\s)[^\]]*)?\]([\s\S]*?)\[\/\1\]/gi, tagCard)
    .replace(/\[([a-z][a-z0-9_]*)(\s+[a-z_][a-z0-9_]*=[^\]]*)\]/gi, (all, tag, a) => tagCard(all, tag, a, ""))
  return { rest: tagged, cards: cards }
})"""

# Remote Play: your other computers signed in to Steam and online, which
# games each has installed (so you can stream them here), and the computer
# Steam last picked for each game.
REMOTE_JS = """
(() => {
  const devices = Array.from((window.RemotePlayStore_SteamUI && RemotePlayStore_SteamUI.devices) || [])
    .filter(d => d && d.clientId && d.status === "Connected")
    .map(d => ({ id: String(d.clientId), name: d.clientName || "" }))
  const online = new Set(devices.map(d => d.id))
  const apps = {}, selected = {}
  for (const a of Array.from(appStore.allApps || [])) {
    const on = (a.per_client_data || []).filter(c => c.installed && online.has(String(c.clientid)))
    if (!on.length) continue
    apps[a.appid] = on.map(c => String(c.clientid))
    if (a.selected_clientid && online.has(String(a.selected_clientid))) selected[a.appid] = String(a.selected_clientid)
  }
  return { devices: devices, apps: apps, selected: selected }
})()
"""

# Your group chats (named groups, Steam group chats and ad-hoc chats with
# several friends), most recently active first, with their text rooms.
GROUPS_JS = """
(() => {
  const avatar = g => {
    const url = g.hasAvatarSHA ? String(g.avatar_url_medium || "") : ""
    return /\\/_(medium|64)\\.jpg$/.test(url) ? "" : url
  }
  return Array.from(g_FriendsUIApp.ChatStore.currentChatRoomGroups || []).map(g => {
    const rooms = Array.from(g.textRoomList || []).map(r => ({
      id: String(r.GetRoomID()), name: r.name || "", unread: r.unread_message_count || 0,
      mention: !!r.has_unread_mention,
    }))
    const unread = rooms.reduce((n, r) => n + r.unread, 0)
    return {
      id: String(g.GetGroupID()),
      name: g.name || "",
      tagline: g.tagline || "",
      avatar: avatar(g),
      members: g.memberCountTotal || 0,
      defaultRoom: String(g.GetDefaultChatID()),
      rooms: rooms,
      unread: unread,
      mention: rooms.some(r => r.mention),
      activity: g.time_last_activity || 0,
    }
  }).sort((a, b) => b.activity - a.activity)
})()
"""

# Everyone in a group chat. The client only loads a group's member list
# while the group is active, so mark it active (telling Steam, as its own
# chat window does), wait for the list, read it, and let go again.
MEMBERS_JS = """
(async () => {
  const cs = g_FriendsUIApp.ChatStore
  const g = cs.GetChatRoomGroup("%(group)s")
  if (!g) throw new Error("That group chat isn't available")
  const id = g.GetGroupID()
  cs.IncRefActiveChatRoomGroup(id, true)
  try {
    for (let i = 0; i < 20 && !g.m_bFullStateLoaded; i++) await new Promise(r => setTimeout(r, 250))
    const persona = %(persona)s
    const rank = { "in-game": 0, online: 1, busy: 2, away: 2, offline: 3 }
    return Array.from((g.memberList && g.memberList.member_list) || []).map(f => {
      return Object.assign(persona.of(f), { isFriend: !!f.is_friend })
    }).sort((a, b) => (rank[a.state] - rank[b.state]) || a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
  } finally {
    cs.DecRefActiveChatRoomGroup(id, true)
  }
})()
"""

# Add or take back your reaction on one message, as Steam's own chat does.
REACT_JS = """
(async () => {
  const chat = %(target)s
  if (!chat) throw new Error("That chat isn't available")
  const m = chat.chat_messages.find(m => m.rtTimestamp === %(ts)d && m.unOrdinal === %(ordinal)d)
  if (!m) throw new Error("That message isn't loaded any more")
  return await chat.UpdateMessageReaction(m, %(type)d, %(reaction)s, %(add)s)
})()
"""

SEND_JS = """
(() => {
  const chat = %(target)s
  if (!chat) throw new Error("That chat isn't available")
  chat.SendChatMessage(%(text)s)
  return "sent"
})()
"""


def cached_lookup(table, key, fetch):
    """Details for a shared link, from the cache when it has them (a month;
    a failed lookup is retried after an hour), else fetch(), then kept."""
    info, age = cache.load_lookup(table, key)
    if info is not None and age < (30 * 86400 if info else 3600):
        return info
    try:
        info = fetch()
    except Exception:
        info = {}
    cache.save_lookup(table, key, info)
    return info


def fetch_small_json(url):
    with urllib.request.urlopen(url, timeout=4) as r:
        body = r.read(MAX_APPINFO + 1)
    return json.loads(body) if len(body) <= MAX_APPINFO else {}


def store_app(appid):
    """Name and header art for a shared store link. Newer games keep their
    art under a hashed path only the store's API knows, so ask it once."""
    if not isinstance(appid, int) or appid <= 0:
        return {}

    def fetch():
        d = (fetch_small_json("https://store.steampowered.com/api/appdetails?appids=%d&filters=basic" % appid)
             .get(str(appid)) or {}).get("data") or {}
        info = {}
        if isinstance(d.get("name"), str):
            info["name"] = d["name"][:256]
        if isinstance(d.get("header_image"), str) and d["header_image"].startswith("https://"):
            info["header"] = d["header_image"][:2048]
        return info
    return cached_lookup("apps", appid, fetch)


def youtube_info(video_id):
    """Title and channel for a shared YouTube link, from YouTube's oEmbed endpoint."""
    if not isinstance(video_id, str) or not re.fullmatch(r"[\w-]{11}", video_id):
        return {}

    def fetch():
        d = fetch_small_json("https://www.youtube.com/oembed?format=json&url="
                             + urllib.request.quote("https://www.youtube.com/watch?v=" + video_id, safe=""))
        info = {}
        if isinstance(d.get("title"), str):
            info["title"] = d["title"][:300]
        if isinstance(d.get("author_name"), str):
            info["author"] = d["author_name"][:200]
        return info
    return cached_lookup("embeds", "youtube:" + video_id, fetch)


def digits(value, what):
    """An id from argv (only digits, so it's safe inside a JS string)."""
    if not re.fullmatch(r"\d{1,20}", value):
        raise ValueError("not a %s: %s" % (what, value))
    return value


def chat_target(target):
    """JS for a chat: a friend's (account id) or a group chat room (groupid:roomid)."""
    m = re.fullmatch(r"(\d{1,20}):(\d{1,20})", target)
    if m:
        return 'g_FriendsUIApp.ChatStore.GetChatRoomGroup("%s").GetChatRoom("%s")' % m.groups()
    if re.fullmatch(r"\d{1,10}", target):
        return "g_FriendsUIApp.ChatStore.GetFriendChat(%d, true)" % int(target)
    raise ValueError("not a chat: %s" % target)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "eval":
        return evaluate(argv[2])
    if cmd == "folders":
        return evaluate(FOLDERS_JS)
    if cmd == "uninstall":
        # What Steam's own "Uninstall" confirmation calls once you confirm.
        return evaluate('SteamClient.Installs.OpenUninstallWizard([%d], true); "uninstalling"' % int(argv[2]))
    if cmd == "friends":
        value = evaluate(FRIENDS_JS % {"persona": PERSONA_JS})
        if isinstance(value, dict):
            cache.save_friends(value.get("friends") or [], value.get("groups") or [])
        return value
    if cmd == "chat":
        read = "true" if len(argv) > 3 and argv[3] == "read" else "false"
        value = evaluate(CHAT_JS % {"target": chat_target(argv[2]), "read": read, "html": HTML_JS, "embeds": EMBEDS_JS, "persona": PERSONA_JS})
        for m in value.get("messages", []) if isinstance(value, dict) else []:
            for card in m.get("cards") or []:
                if card.get("type") == "store":
                    card.update(store_app(card.get("appid")))
                elif card.get("type") == "youtube":
                    card.update(youtube_info(card.get("id")))
        return value
    if cmd == "react":
        # react <account> <timestamp> <ordinal> <type> <reaction> <add|remove>
        reaction = argv[6]
        if not re.fullmatch(r":?[\w-]{1,64}:?", reaction):
            raise ValueError("not a reaction: %s" % reaction)
        return evaluate(REACT_JS % {"target": chat_target(argv[2]), "ts": int(argv[3]), "ordinal": int(argv[4]),
                                    "type": int(argv[5]), "reaction": json.dumps(reaction),
                                    "add": "true" if argv[7] == "add" else "false"})
    if cmd == "send":
        return evaluate(SEND_JS % {"target": chat_target(argv[2]), "text": json.dumps(sys.stdin.read())})
    if cmd == "groups":
        return evaluate(GROUPS_JS)
    if cmd == "members":
        return evaluate(MEMBERS_JS % {"group": digits(argv[2], "group"), "persona": PERSONA_JS})
    if cmd == "remote":
        return evaluate(REMOTE_JS)
    if cmd == "stream":
        # What Steam's Stream button does.
        return evaluate('SteamClient.Apps.StreamGame(%d, "%s", -1); "streaming"' % (int(argv[2]), digits(argv[3], "computer")))
    if cmd == "desktop":
        # Remote Play another computer's whole desktop, as Steam's device list does.
        return evaluate('SteamClient.RemotePlay.StartDesktopStream("%s"); "streaming"' % digits(argv[2], "computer"))
    if cmd == "wizard-state":
        return evaluate("SteamClient.Installs.GetInstallManagerInfo().then(i => i.eInstallState)")
    if cmd == "overview":
        return evaluate(OVERVIEW_JS)
    if cmd == "pause":
        return evaluate(PAUSE_JS % {"appid": int(argv[2])})
    if cmd == "resume":
        return evaluate(RESUME_JS % {"appid": int(argv[2])})
    if cmd == "install":
        return evaluate(INSTALL_JS % {"appid": int(argv[2]), "folder": int(argv[3])}, timeout=660)
    raise ValueError("unknown command: %s" % cmd)


if __name__ == "__main__":
    try:
        out = json.dumps({"ok": True, "value": main(sys.argv)})
        if len(out) > MAX_OUTPUT:
            raise RuntimeError("Steam's answer was too large to show")
        print(out)
    except Exception as e:
        # Most likely Steam isn't running, or was started before the
        # debugging flag file existed.
        msg = str(e)
        if isinstance(e, (OSError, urllib.error.URLError)):
            msg = "Can't reach Steam. Is it running?"
        print(json.dumps({"ok": False, "error": msg[:500]}))
        sys.exit(1)
