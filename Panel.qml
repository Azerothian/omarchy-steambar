import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Commons
import qs.Ui

// Steam popup: recently played games, the rest of the library, friends with
// their online status, downloads, and the store's top sellers, popular
// upcoming and new releases (50 each), whose store pages open in a pane
// beside the list. Tabs run down a rail on the popup's left edge. Everything comes from steam.py, which
// reads the local Steam client's caches (no sign-in needed); friend status is
// fetched from Steam Community, or the Web API when an apiKey is set.
// Installing, pausing and resuming go through steamctl.py, which drives the
// running Steam client over its CEF debugging port so no Steam window opens.
Panel {
  id: root
  moduleName: "blip.steam"
  ipcTarget: "blip.steam"
  manageIpc: false

  property string tab: tabOrder[0]

  // ---------- settings ----------
  // Saved in this widget's shell.json entry (through the shell, as
  // `omarchy bar set` does); `pending` shows a change before it lands.
  property var pending: ({})

  function pref(name, fallback) {
    return pending[name] !== undefined ? pending[name] : setting(name, fallback)
  }

  function savePref(name, value) {
    var next = Object.assign({}, pending)
    next[name] = value
    pending = next
    // qs ipc splits arguments at commas, so none may reach it: lists are
    // saved as space-separated text, and commas inside text are escaped.
    var json = JSON.stringify(Array.isArray(value) ? value.join(" ") : value).replace(/,/g, "\\u002c")
    Quickshell.execDetached(["omarchy-shell", "-q", "shell", "setBarWidget", "blip.steam", name, json, "{}"])
  }

  readonly property var allTabs: ["store", "library", "friends", "groups"]
  // Your order from dragging the tabs; the first opens with the popup.
  readonly property var tabOrder: {
    var saved = pref("tabOrder", null), out = []
    if (typeof saved === "string") saved = saved.split(/[\s,]+/)
    if (Array.isArray(saved))
      for (var i = 0; i < saved.length; i++)
        if (allTabs.indexOf(saved[i]) >= 0 && out.indexOf(saved[i]) < 0) out.push(saved[i])
    for (var j = 0; j < allTabs.length; j++) if (out.indexOf(allTabs[j]) < 0) out.push(allTabs[j])
    return out
  }
  readonly property bool railTop: pref("menuPosition", "left") === "top"
  readonly property bool openFirstTab: pref("openFirstTab", true) !== false
  readonly property bool installedByDefault: pref("installedByDefault", true) !== false
  readonly property bool showOfflineFriends: pref("showOfflineFriends", true) !== false
  readonly property bool showSteamNames: pref("showSteamNames", true) !== false
  readonly property bool showMessageTimes: pref("showMessageTimes", true) !== false
  // Groups shown as rows of avatars above the friends search instead of in
  // the list (the box on a group's header). Saved as space-separated ids.
  readonly property var iconGroups: {
    var v = pref("iconGroups", null)
    if (typeof v === "string") v = v.split(/\s+/)
    return Array.isArray(v) ? v.map(String).filter(function(id) { return id !== "" }) : []
  }
  function toggleIconGroup(id) {
    var list = iconGroups.slice(), at = list.indexOf(id)
    if (at >= 0) list.splice(at, 1); else list.push(id)
    keepScroll(function() { savePref("iconGroups", list) })
  }

  // The icon of the game a friend is playing: your library's copy when you
  // own it, else what Steam reported, else the store's small capsule.
  function gameIcon(f) {
    if (!f || f.state !== "in-game" || !f.appid) return ""
    var g = gameById(f.appid)
    if (g && g.icon) return g.icon
    return f.gameIcon || "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/" + f.appid + "/capsule_sm_120.jpg"
  }


  // An avatar clicked (a friend group's icons, a group chat's members):
  // chat with a friend, or open someone else's Steam profile.
  function openPerson(person, inWindow) {
    if (!person) return
    if (person.isFriend === false) { launch("steam://url/SteamIDPage/" + person.steamid); return }
    if (inWindow) popOutChat(person)
    else openChat(person)
  }
  // Set by commands that open the popup on a particular tab.
  property bool keepTab: false

  function moveTab(from, to) {
    var order = tabOrder.slice()
    var moved = order.splice(from, 1)[0]
    order.splice(to, 0, moved)
    savePref("tabOrder", order)
  }
  // The Store tab's own lists, shown as sub-tabs above its rows.
  property string storeKind: "top"
  readonly property var storeKinds: ["top", "upcoming", "new"]
  property int rowIndex: 0
  property bool cursorActive: false
  property var games: []
  property var friends: []
  // Steam's friend groups ({id, name}), favorites first; each friend lists
  // the group ids it's in. Only known with Steam controllable.
  property var friendGroups: []
  // Section keys (group id, "online", "offline") minimised to their header;
  // kept in the cache so they stay that way.
  property var collapsedGroups: ({})
  property bool gamesLoaded: false
  property bool friendsLoaded: false
  // Showing the last list saved to the cache until the live one arrives.
  property bool friendsCached: false
  property var storeLists: ({})
  property bool storeListsLoaded: false
  property string errorText: ""
  property string friendsError: ""
  property string filterText: ""
  // Library ticks under the search field: most played first (played
  // games only), installed only (the default) and uninstalled only. The last
  // two exclude each other.
  property bool mostPlayed: false
  property bool installedOnly: installedByDefault
  property bool uninstalledOnly: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string script: Qt.resolvedUrl("steam.py").toString().replace(/^file:\/\//, "")
  readonly property int recentCount: Math.max(1, Number(pref("recentCount", 10)))
  readonly property string apiKey: String(pref("apiKey", "") || "")
  readonly property string installDrive: String(pref("installDrive", "") || "")
  readonly property string ctlScript: Qt.resolvedUrl("steamctl.py").toString().replace(/^file:\/\//, "")

  // Steam library folders (steamctl.py folders) and whether the running
  // client accepts commands (its debugging port is up). Without it, installs
  // fall back to Steam's own dialog and pause/resume are hidden.
  property var folders: []
  property bool controllable: false
  property string actionError: ""
  readonly property var preferredFolder: {
    var want = installDrive.trim().toLowerCase()
    var fallback = null
    for (var i = 0; i < folders.length; i++) {
      var f = folders[i]
      if (want !== "" && f.path.toLowerCase().indexOf(want) >= 0) return f
      if (f.isDefault) fallback = f
    }
    return fallback || (folders.length ? folders[0] : null)
  }

  // Steam's own presence colours; the theme accent is too grey to read as "online".
  readonly property color inGameColor: "#90ba3c"
  readonly property color onlineColor: "#57cbde"
  // The theme's urgent colour is grey here too, so uninstall gets a real red.
  readonly property color dangerColor: "#e0524d"
  readonly property color warnColor: "#e0a84d"

  // The bar button's middle-click plays the last game you can run here.
  readonly property var lastInstalled: {
    for (var i = 0; i < games.length; i++) if (games[i].lastPlayed > 0 && games[i].installed) return games[i]
    return null
  }

  readonly property var recentGames: {
    var out = []
    for (var i = 0; i < games.length && out.length < recentCount; i++)
      if (games[i].lastPlayed > 0 && (games[i].installed || streamable(games[i]))) out.push(games[i])
    return out
  }

  // Which computer the library shows ("" every one, "local" this one, or
  // a Remote Play computer's id), and whether it's split into a section
  // per computer (the default when other computers have games to stream).
  property string libraryPc: ""

  function pickPc(id) {
    libraryPc = id
    rowIndex = 0
    list.positionViewAtBeginning()
  }
  readonly property bool groupByPc: pref("groupByPc", true) !== false
  readonly property bool hasStreams: remoteDevices.length > 0 && Object.keys(remoteApps).length > 0

  // Remote Play heads the library like a friend group: a header that
  // minimises, then a row per computer (click for its desktop).
  // The box on the Remote Play header shows its computers as a row of
  // icons, still in its place in the list.
  readonly property bool remotePlayIcons: pref("remotePlayIcons", false) === true

  readonly property var remotePlayRows: {
    if (!remoteDevices.length) return []
    var collapsed = !!collapsedGroups.remoteplay
    var out = [{ isHeader: true, sectionId: "remoteplay", name: "Remote Play", count: remoteDevices.length,
                 collapsible: true, collapsed: collapsed }]
    var devices = remoteDevices.map(function(d) { return { isDevice: true, device: d, count: pcCounts[d.id] || 0 } })
    if (!collapsed) out = out.concat(remotePlayIcons ? [{ isDeviceBar: true, devices: devices }] : devices)
    return out
  }

  // How many of your games each computer has: "local" for this one, and
  // each Remote Play computer by id.
  readonly property var pcCounts: {
    var out = { local: 0 }
    for (var i = 0; i < games.length; i++) {
      if (games[i].installed) out.local++
      var on = remoteApps[String(games[i].appid)] || []
      for (var j = 0; j < on.length; j++) out[on[j]] = (out[on[j]] || 0) + 1
    }
    return out
  }

  // The library's search and chips (Installed counts games you can stream
  // from another computer too); `here` is whether g plays here or streams.
  function passesFilters(g, here, q) {
    if (q !== "" && g.name.toLowerCase().indexOf(q) < 0) return false
    if (installedOnly && !here) return false
    if (uninstalledOnly && here) return false
    if (mostPlayed && !(g.playtime > 0)) return false
    return true
  }

  // The library's Recent: your latest games that pass its filters (and the
  // computer chip), up to "Games in Recent". It heads the library, above
  // Remote Play, and minimises like a friend group.
  readonly property var recentFiltered: {
    var q = filterText.trim().toLowerCase()
    var pc = hasStreams ? libraryPc : ""
    var device = remoteDevices.filter(function(d) { return d.id === pc })[0]
    var out = []
    for (var i = 0; i < games.length && out.length < recentCount; i++) {
      var g = games[i]
      if (!(g.lastPlayed > 0) || !passesFilters(g, g.installed || streamable(g), q)) continue
      if (pc === "local" && !g.installed) continue
      if (device && (remoteApps[String(g.appid)] || []).indexOf(device.id) < 0) continue
      out.push(device ? Object.assign({}, g, { streamDevice: device }) : g)
    }
    if (mostPlayed) out.sort(function(a, b) { return b.playtime - a.playtime })
    return out
  }

  readonly property var recentRows: {
    if (!recentFiltered.length) return []
    var collapsed = !!collapsedGroups.recent
    return [{ isHeader: true, sectionId: "recent", name: "Recent", count: recentFiltered.length,
              collapsible: true, collapsed: collapsed }].concat(collapsed ? [] : recentFiltered)
  }

  readonly property var libraryHead: recentRows.concat(remotePlayRows)

  // Under those, an ungrouped list gets a header of its own.
  readonly property var libraryRowsFlat: !libraryHead.length || !libraryList.length || libraryList[0].isHeader
    ? libraryHead.concat(libraryList)
    : libraryHead.concat([{ isHeader: true, sectionId: "games", name: "Games", count: libraryList.length }], libraryList)

  // Panel view: each section's games as covers in rows that fill the width
  // (click one for its options); the list view keeps a row per game. Each
  // line of covers is its own list row, so only the ones on screen exist.
  readonly property bool libraryPanels: pref("libraryView", "list") === "panels"
  readonly property int gridColumns: Math.max(1, Math.floor(
    (list.width - Style.space(12) - listBar.width - Style.space(2) + Style.space(6)) / (Style.space(62) + Style.space(6))))
  readonly property var libraryGames: {
    if (!libraryPanels) return libraryRowsFlat
    var out = [], run = [], cols = gridColumns
    function flush() {
      for (var i = 0; i < run.length; i += cols) out.push({ isGameGrid: true, games: run.slice(i, i + cols), columns: cols })
      run = []
    }
    libraryRowsFlat.forEach(function(r) {
      if (r.isHeader || r.isDevice || r.isDeviceBar) { flush(); out.push(r) } else run.push(r)
    })
    flush()
    return out
  }

  // The game whose options are showing (panel view), and whether its
  // Uninstall has been pressed once.
  property var gameOptions: null
  property bool uninstallArmed: false

  function showGameOptions(game) { uninstallArmed = false; gameOptions = game }
  // An option was picked: close the options, then do it to that game.
  function withOptionsGame(fn) { var g = gameOptions; closeGameOptions(); if (g) fn(g) }
  function closeGameOptions() { gameOptions = null; keyCatcher.forceActiveFocus() }

  readonly property var libraryList: {
    var q = filterText.trim().toLowerCase()
    function keep(g, here) { return passesFilters(g, here, q) }
    function byName(a, b) {
      if (mostPlayed && a.playtime !== b.playtime) return b.playtime - a.playtime
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
    }
    function onPc(g, id) { return (remoteApps[String(g.appid)] || []).indexOf(id) >= 0 }
    function from(list, device) { return list.map(function(g) { return Object.assign({}, g, { streamDevice: device }) }) }

    var pcs = hasStreams ? remoteDevices : []
    var only = hasStreams ? libraryPc : ""
    if (hasStreams && groupByPc) {
      var sections = [{ id: "local", name: "This computer", list: games.filter(function(g) { return g.installed && keep(g, true) }) }]
      pcs.forEach(function(d) {
        sections.push({ id: d.id, name: d.name, list: from(games.filter(function(g) { return onPc(g, d.id) && keep(g, true) }), d) })
      })
      sections.push({ id: "none", name: "Not installed", list: games.filter(function(g) { return !g.installed && !streamable(g) && keep(g, false) }) })
      var out = []
      sections.forEach(function(sec) {
        if (!sec.list.length || (only !== "" && only !== sec.id)) return
        out.push({ isHeader: true, name: sec.name, count: sec.list.length, sectionId: sec.id })
        out = out.concat(sec.list.sort(byName))
      })
      return out
    }

    var flat = only === "local" ? games.filter(function(g) { return g.installed && keep(g, true) })
      : only !== "" ? from(games.filter(function(g) { return onPc(g, only) && keep(g, true) }),
                           pcs.filter(function(d) { return d.id === only })[0])
      : games.filter(function(g) { return keep(g, g.installed || streamable(g)) })
    // Installed here, then streamable, then the rest (each game's rank
    // worked out once, not on every comparison).
    var rank = {}
    flat.forEach(function(g) { rank[g.appid] = g.installed ? 0 : streamable(g) ? 1 : 2 })
    return flat.sort(function(a, b) {
      if (!mostPlayed && rank[a.appid] !== rank[b.appid]) return rank[a.appid] - rank[b.appid]
      return byName(a, b)
    })
  }

  // The selected store list, marked with what you own and have installed so
  // those rows act like library rows.
  readonly property var storeRows: {
    var list = storeLists[storeKind] && storeLists[storeKind].games ? storeLists[storeKind].games : []
    var out = []
    for (var j = 0; j < list.length; j++) {
      var p = list[j], g = gamesById[p.appid]
      out.push(Object.assign({}, p, { owned: !!g, installed: !!g && g.installed, icon: g ? g.icon : "" }))
    }
    return out
  }

  readonly property int friendsOnline: {
    var n = 0
    for (var i = 0; i < friends.length; i++)
      if (friends[i].state !== "offline" && friends[i].state !== "unknown") n++
    return n
  }

  // Without Steam's debugging port much of the widget falls back to slower
  // or Steam-window paths; the header's alert explains why and how to fix it.
  property bool controlChecked: false
  property bool steamRunning: true
  property bool debugFlag: false
  property string debugFlagPath: ""
  property bool degradedOpen: false
  readonly property bool degraded: controlChecked && !controllable
  readonly property string enableCommand: "touch " + debugFlagPath

  // Friends laid out like Steam's list: each group (a friend can be in
  // several), then everyone else online, then offline. The first row of a
  // section carries its header.
  readonly property var friendRows: {
    // A group ticked for icons keeps its place: its header, then one row of
    // avatars instead of a row per friend.
    var sections = friendGroups.map(function(g) { return { name: g.name, id: g.id, members: [], icons: iconGroups.indexOf(g.id) >= 0 } })
    var byId = {}
    for (var i = 0; i < sections.length; i++) byId[sections[i].id] = sections[i]
    var online = { name: "Online", id: "online", members: [] }, offline = { name: "Offline", id: "offline", members: [] }
    var q = filterText.trim().toLowerCase()
    for (var j = 0; j < friends.length; j++) {
      var f = friends[j], placed = false
      if (q !== "" && [f.name, f.personaName, f.game].join("\n").toLowerCase().indexOf(q) < 0) continue
      var ids = f.groups || []
      for (var k = 0; k < ids.length; k++)
        if (byId[ids[k]]) { byId[ids[k]].members.push(f); placed = true }
      if (!placed) (f.state === "offline" || f.state === "unknown" ? offline : online).members.push(f)
    }
    var out = []
    sections.concat([online, offline]).forEach(function(sec) {
      if (!sec.members.length) return
      var n = 0
      for (var m = 0; m < sec.members.length; m++)
        if (sec.members[m].state !== "offline" && sec.members[m].state !== "unknown") n++
      // With offline friends hidden, a section with nobody online (the
      // Offline one always) would only be an empty header.
      if (!showOfflineFriends && n === 0) return
      // While searching, every match shows, minimised group or not.
      var collapsed = !!collapsedGroups[sec.id] && q === ""
      out.push({
        isHeader: true, sectionId: sec.id, name: sec.name, collapsed: collapsed,
        icons: !!sec.icons,
        count: sec === online ? String(n) : sec === offline ? String(sec.members.length) : n + "/" + sec.members.length,
      })
      var shown = showOfflineFriends ? sec.members : sec.members.filter(function(f) {
        return f.state !== "offline" && f.state !== "unknown"
      })
      if (!collapsed) out = out.concat(sec.icons ? [{ isIconBar: true, sectionId: sec.id, members: shown }] : shown)
    })
    return out
  }

  readonly property var rows: tab === "library" ? libraryGames
    : tab === "store" ? storeRows : tab === "friends" ? friendRows : tab === "groups" ? groupRows : []

  // Active/queued/paused downloads from `steam.py downloads`, each with a
  // smoothed `speed` (bytes/s) worked out here from successive samples.
  property var downloads: []
  // The Downloads section above the list folds down to its header (d).
  property bool downloadsExpanded: true
  property var downloadSamples: ({})
  readonly property var downloadsById: {
    var map = {}
    for (var i = 0; i < downloads.length; i++) map[downloads[i].appid] = downloads[i]
    return map
  }
  readonly property var activeDownload: {
    for (var i = 0; i < downloads.length; i++)
      if (downloads[i].status !== "paused" && downloads[i].status !== "queued") return downloads[i]
    return null
  }

  function refreshDownloads() { if (!downloadsProc.running) downloadsProc.running = true }

  function updateDownloads(list, now) {
    var prev = downloadSamples
    var next = {}
    for (var i = 0; i < list.length; i++) {
      var d = list[i]
      var p = prev[d.appid]
      var speed = 0
      if (p && d.status === "downloading" && now > p.time) {
        var instant = Math.max(0, (d.staged - p.staged) / (now - p.time))
        // Light smoothing: Steam writes in bursts.
        speed = p.speed > 0 ? p.speed * 0.6 + instant * 0.4 : instant
        // Stalled or restarted: don't let the smoothing trail off forever.
        if (d.staged < p.staged || speed < 1024) speed = 0
      }
      d.speed = speed
      next[d.appid] = { staged: d.staged, time: now, speed: speed }
    }
    downloadSamples = next
    downloads = list
  }

  function sizeLabel(bytes) {
    if (bytes >= 1e9) return (bytes / 1e9).toFixed(bytes >= 1e10 ? 0 : 1) + " GB"
    if (bytes >= 1e6) return Math.round(bytes / 1e6) + " MB"
    return Math.round(bytes / 1e3) + " KB"
  }

  // Steam's own estimate when we have it, else from the bytes still to go.
  function downloadEta(d) {
    return d.eta > 0 ? d.eta : (d.total - d.staged) / d.speed
  }

  function etaLabel(seconds) {
    if (seconds < 60) return "<1 min left"
    if (seconds < 3600) return Math.round(seconds / 60) + " min left"
    var h = Math.floor(seconds / 3600)
    var m = Math.round((seconds % 3600) / 60)
    return h + " h " + (m ? m + " min " : "") + "left"
  }

  function downloadLine(d, withEta) {
    if (d.status === "paused") return "Paused · " + Math.floor(d.progress * 100) + "%"
    if (d.status === "queued") return "Queued"
    if (d.status === "installing") return "Installing…"
    if (d.status === "verifying") return "Verifying…"
    if (d.status === "preparing") return "Preparing…"
    if (!d.total) return "Downloading…"
    var done = sizeLabel(d.staged), total = sizeLabel(d.total)
    // "1.2 / 3.4 GB" when both share a unit, to keep the line short.
    if (done.slice(-2) === total.slice(-2)) done = done.slice(0, -3)
    var parts = [done + " / " + total]
    if (d.speed > 0) {
      parts.push(sizeLabel(d.speed) + "/s")
      var eta = downloadEta(d)
      if (withEta !== false && isFinite(eta) && eta < 30 * 86400) parts.push(etaLabel(eta))
    }
    return parts.join(" · ")
  }

  // Library filter checkbox: filled box when on, empty and dimmed when off.
  // One tab in the rail: icon, label, the Friends badge. Tabs that can move
  // follow the mouse once dragged a few pixels; a plain click selects.
  component RailTab: Rectangle {
    id: rt
    property string tabName: ""
    property int tabIndex: -1
    property bool draggable: false
    // The rail it sits in (its slot positions and drag state).
    property Item host: null
    property bool dragging: false
    property real dragOffset: 0
    property point pressAt
    readonly property bool selected: root.tab === tabName
    readonly property int badge: tabName === "friends" ? (root.unreadTotal || root.friendsOnline)
      : tabName === "groups" ? root.groupUnread : 0
    radius: Style.space(6)
    color: Util.alpha(root.foreground, dragging ? 0.18 : selected ? 0.12 : rtMouse.containsMouse ? 0.06 : 0)
    border.width: selected || dragging ? 1 : 0
    border.color: Util.alpha(root.foreground, 0.3)

    Column {
      anchors.centerIn: parent
      spacing: Style.space(3)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.tabInfo[rt.tabName] ? root.tabInfo[rt.tabName].icon : ""
        color: rt.selected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.tabInfo[rt.tabName] ? root.tabInfo[rt.tabName].label : ""
        color: rt.selected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: rt.selected
      }
    }

    // Friends online, or unread chats (in Steam's in-game green).
    Rectangle {
      visible: rt.badge > 0
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(4)
      width: Math.max(height, badgeText.implicitWidth + Style.space(8))
      height: badgeText.implicitHeight + Style.space(2)
      radius: height / 2
      color: root.unreadTotal || rt.tabName === "groups" ? root.inGameColor : Util.alpha(root.foreground, 0.16)

      Text {
        id: badgeText
        anchors.centerIn: parent
        text: rt.badge
        color: root.unreadTotal || rt.tabName === "groups" ? "black" : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption * 0.9
        font.bold: true
      }
    }

    function endDrag() {
      dragging = false
      dragOffset = 0
      rt.host.dragFrom = -1
      rt.host.dragTo = -1
    }

    MouseArea {
      id: rtMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: rt.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
      onPressed: function(mouse) { rt.pressAt = mapToItem(rt.host, mouse.x, mouse.y) }
      onPositionChanged: function(mouse) {
        if (!rt.draggable || !pressed) return
        var p = mapToItem(rt.host, mouse.x, mouse.y)
        var d = root.railTop ? p.x - rt.pressAt.x : p.y - rt.pressAt.y
        if (!rt.dragging && Math.abs(d) > Style.space(6)) { rt.dragging = true; rt.host.dragFrom = rt.tabIndex }
        if (!rt.dragging) return
        var last = root.tabOrder.length - 1
        rt.dragOffset = Math.max(-rt.tabIndex * rt.host.step, Math.min((last - rt.tabIndex) * rt.host.step, d))
        rt.host.dragTo = Math.max(0, Math.min(last, rt.tabIndex + Math.round(rt.dragOffset / rt.host.step)))
      }
      onReleased: {
        if (rt.dragging) {
          var from = rt.host.dragFrom, to = rt.host.dragTo
          rt.endDrag()
          if (from >= 0 && to >= 0 && from !== to) root.moveTab(from, to)
        } else root.tab = rt.tabName
      }
      onCanceled: rt.endDrag()
    }
  }

  // What's limited without the debugging port, and how to turn it on.
  component DebugNotice: Rectangle {
    // The header banner can be hidden; the Settings copy stays.
    property bool closable: true
    implicitHeight: noticeCol.implicitHeight + Style.space(20)
    radius: Style.space(6)
    color: Util.alpha(root.warnColor, 0.1)
    border.width: 1
    border.color: Util.alpha(root.warnColor, 0.45)

    ColumnLayout {
      id: noticeCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(6)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: !root.steamRunning ? "Steam isn't running"
            : root.debugFlag ? "Restart Steam to finish turning on control" : "Limited without Steam's debugging port"
          color: root.warnColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          wrapMode: Text.Wrap
        }

        ActionButton {
          visible: closable
          iconText: "󰅖"
          tooltipText: "Hide"
          foreground: root.dim
          fontSize: Style.font.caption
          onClicked: root.degradedOpen = false
        }
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: !root.steamRunning
          ? "Start Steam for live friends and chat, and to install or pause games from here."
          : root.debugFlag
          ? "The flag file is in place, but Steam only opens its debugging port when it starts."
          : "Friend status is read from public profiles (slow, often incomplete), with no friend groups or "
            + "most nicknames. Chat and installs open in Steam instead, chats can't pop out into their own "
            + "windows, and downloads can't be paused here. To turn it on, run this and restart Steam:"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      // Start Steam, or restart it once the flag file is in place.
      RowLayout {
        visible: !root.steamRunning || root.debugFlag
        spacing: Style.space(8)

        Button {
          enabled: !root.steamStarting
          text: root.steamStarting ? "Starting…" : root.steamRunning ? "Restart Steam" : "Start Steam"
          iconText: root.steamStarting ? "" : "󰓓"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: root.steamRunning ? root.restartSteam() : root.startSteam()
        }

        Text {
          visible: root.steamRunning && !root.steamStarting
          text: "Closes any game running in Steam."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      RowLayout {
        Layout.fillWidth: true
        visible: root.steamRunning && !root.debugFlag && root.debugFlagPath !== ""
        spacing: Style.space(6)

        Rectangle {
          Layout.fillWidth: true
          implicitHeight: cmdText.implicitHeight + Style.space(10)
          radius: Style.space(4)
          color: Util.alpha(root.foreground, 0.08)

          Text {
            id: cmdText
            anchors.fill: parent
            anchors.margins: Style.space(5)
            textFormat: Text.PlainText
            text: root.enableCommand
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
          }
        }

        ActionButton {
          iconText: "󰆏"
          tooltipText: "Copy"
          onClicked: root.copyText(root.enableCommand)
        }
      }

      Text {
        Layout.fillWidth: true
        visible: root.steamRunning && !root.debugFlag
        textFormat: Text.PlainText
        text: "While it's on, any program on this computer can control Steam through localhost:8080."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
    }
  }

  component SettingsHeader: SectionLabel {
    property bool first: false
    Layout.fillWidth: true
    Layout.topMargin: first ? 0 : Style.space(10)
    font.capitalization: Font.AllUppercase
  }

  component SettingsNote: Text {
    Layout.fillWidth: true
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }

  component SettingsToggle: FilterTick {
    implicitHeight: Style.space(24)
  }

  // A filter as a chip: icon, label, an optional count; selected ones are
  // outlined. actionIcon adds a button shown on hover (e.g. Remote Play).
  // The line between the list and the chat or store pane: drag to trade
  // width between them (the popup keeps its size, so it follows the mouse).
  // Past the list's minimum it widens the popup instead, growing the pane,
  // at whatever rate keeps the line under the mouse.
  component PaneDivider: MouseArea {
    id: divider
    property string pane: "chat"
    property real startX: 0
    property real startList: 0
    property real startPane: 0
    property real leftRate: 0
    width: Style.space(12)
    hoverEnabled: true
    cursorShape: Qt.SplitHCursor
    preventStealing: true
    onPressed: function(mouse) {
      startX = mapToGlobal(mouse.x, mouse.y).x
      startList = root.listWidth
      startPane = pane === "chat" ? root.chatWidth : root.storeWidth
      leftRate = root.edgeRate("left")
    }
    onPositionChanged: function(mouse) {
      if (!pressed) return
      var total = startList + startPane
      var minPane = pane === "chat" ? root.minChat : root.minStore
      var want = startList + mapToGlobal(mouse.x, mouse.y).x - startX
      var list = Math.max(root.minList, Math.min(total - minPane, want))
      if (want < root.minList && leftRate > 0)
        total = Math.min(panel.availableCardWidth, total + (root.minList - want) / leftRate)
      root.dragList = list
      if (pane === "chat") root.dragChat = total - list; else root.dragStore = total - list
    }
    onReleased: root.finishResize()
    onCanceled: root.finishResize()
  }

  // A corner of the popup: drag to resize it. The popup sits under its bar
  // button and is kept on screen, so an edge moves 1, ½ or 0 times as fast
  // as the width changes; the grip measures that when pressed and divides
  // it out, so the corner stays under the mouse. Grips whose edge can't
  // move hide. The right grip sizes an open chat/store pane, else the list.
  component ResizeGrip: MouseArea {
    id: grip
    property string side: "right"
    property real edgeRate: 0
    property real heightRate: 0
    property point start
    property real startW: 0
    property real startH: 0
    property string target: "list"
    // A border (the whole side, width only) rather than a corner.
    property bool edge: false
    // How fast this edge moves per unit of width, and the bottom per unit of height.
    function rates() { return { width: root.edgeRate(side), height: root.edgeRate("bottom") } }
    visible: root.opened && rates().width > 0
    width: Style.space(16)
    height: width
    hoverEnabled: true
    preventStealing: true
    cursorShape: edge ? Qt.SizeHorCursor : side === "right" ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor

    // Two short strokes in the corner.
    Repeater {
      model: grip.edge ? 0 : 2
      Rectangle {
        required property int index
        width: Style.space(index ? 6 : 11)
        height: 1
        rotation: grip.side === "right" ? -45 : 45
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: (grip.side === "right" ? 1 : -1) * Style.space(index ? 3 : 0)
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Style.space(index ? 3 : 0)
        color: Util.alpha(root.foreground, grip.containsMouse || grip.pressed ? 0.8 : 0.3)
      }
    }

    onPressed: function(mouse) {
      var r = rates()
      edgeRate = r.width
      heightRate = r.height
      start = mapToGlobal(mouse.x, mouse.y)
      target = side === "right" && root.chatShown ? "chat" : side === "right" && root.storeOpen ? "store" : "list"
      startW = target === "chat" ? root.chatWidth : target === "store" ? root.storeWidth : root.listWidth
      startH = panel.contentHeight
    }
    onPositionChanged: function(mouse) {
      if (!pressed) return
      var g = mapToGlobal(mouse.x, mouse.y)
      var dx = (g.x - start.x) * (side === "right" ? 1 : -1)
      var others = panel.contentWidth - (target === "chat" ? root.chatWidth : target === "store" ? root.storeWidth : root.listWidth)
      var maxW = Math.max(0, panel.availableCardWidth - others)
      if (edgeRate > 0) {
        var min = target === "chat" ? root.minChat : target === "store" ? root.minStore : root.minList
        var w = Math.max(min, Math.min(maxW, startW + dx / edgeRate))
        if (target === "chat") root.dragChat = w
        else if (target === "store") root.dragStore = w
        else root.dragList = w
      }
      if (heightRate > 0 && !edge)
        root.dragHeight = Math.max(root.minHeight, Math.min(panel.availableCardHeight, startH + (g.y - start.y) / heightRate))
    }
    onReleased: root.finishResize()
    onCanceled: root.finishResize()
  }

  // A dialog over the popup: the popup dims behind a centred card, which
  // takes the keys; clicking outside it dismisses. Content goes in the card.
  component ModalScrim: Rectangle {
    id: scrim
    property bool shown: false
    property real contentHeight: 0
    default property alias body: cardBox.data
    signal dismissed()
    anchors.fill: parent
    visible: shown
    color: Util.alpha(Color.background, 0.75)
    onVisibleChanged: if (visible) cardBox.forceActiveFocus()

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      // Holds the hover too, so rows behind don't react.
      hoverEnabled: true
      onClicked: scrim.dismissed()
    }

    Rectangle {
      id: cardBox
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(40), Style.space(320))
      height: Math.min(parent.height - Style.space(40), scrim.contentHeight + Style.space(28))
      radius: Style.space(8)
      color: Color.background
      border.width: 1
      border.color: Util.alpha(root.foreground, 0.25)
      clip: true
      focus: true

      // Clicks on the card stay on it.
      MouseArea { anchors.fill: parent }
    }
  }

  // Small bold label over a section (headers, Settings, bars).
  component SectionLabel: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
  }

  // A presence or unread dot, ringed in the background colour so it stands
  // off the avatar it sits on.
  component Dot: Rectangle {
    property real size: Style.space(9)
    width: size
    height: size
    radius: size / 2
    border.width: Style.space(2)
    border.color: Color.background
  }

  // The kit's action button with this widget's usual font, size and colour.
  component ActionButton: PanelActionButton {
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    foreground: root.foreground
  }

  component FilterChip: Rectangle {
    id: chip
    property string icon: ""
    property string label: ""
    property string detail: ""
    property bool selected: false
    property string actionIcon: ""
    property string actionTip: ""
    // Name shown on hover (for icon-only chips).
    property string tip: ""
    property real labelMax: 0
    property bool actionOnHover: false
    signal clicked()
    signal actionClicked()
    implicitWidth: chipRow.implicitWidth + Style.space(label === "" ? 12 : 16)
    implicitHeight: Style.space(30)
    radius: Style.space(6)
    color: Util.alpha(root.foreground, selected ? 0.16 : chipHover.hovered ? 0.1 : 0.05)
    border.width: 1
    border.color: selected ? root.foreground : Util.alpha(root.foreground, chipHover.hovered ? 0.35 : 0.14)

    HoverHandler { id: chipHover }
    ToolTip.visible: tip !== "" && chipHover.hovered
    ToolTip.delay: 300
    ToolTip.text: tip

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: chip.icon !== ""
        text: chip.icon
        color: chip.selected ? root.onlineColor : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: chip.label !== ""
        width: chip.labelMax > 0 ? Math.min(implicitWidth, chip.labelMax) : implicitWidth
        elide: Text.ElideRight
        text: chip.label
        color: chip.selected || chipHover.hovered ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: chip.detail !== ""
        text: chip.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // Faint until the chip is hovered (or only then, with actionOnHover).
      ActionButton {
        anchors.verticalCenter: parent.verticalCenter
        visible: chip.actionIcon !== "" && (!chip.actionOnHover || chipHover.hovered)
        opacity: chipHover.hovered ? 1 : 0.35
        size: Style.space(20)
        iconText: chip.actionIcon
        tooltipText: chip.actionTip
        foreground: root.onlineColor
        fontSize: Style.font.caption
        onClicked: chip.actionClicked()
      }
    }
  }

  component FilterTick: Item {
    id: tick
    property string label: ""
    property bool checked: false
    property color foreground: root.foreground
    property color dim: root.dim
    property string fontFamily: root.fontFamily
    signal toggled()
    implicitWidth: tickRow.implicitWidth

    Row {
      id: tickRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        text: tick.checked ? "󰄲" : "󰄱"
        color: tick.checked || tickMouse.containsMouse ? tick.foreground : tick.dim
        font.family: tick.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: tick.label
        textFormat: Text.PlainText
        color: tick.checked || tickMouse.containsMouse ? tick.foreground : tick.dim
        font.family: tick.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: tickMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tick.toggled()
    }
  }

  onTabChanged: { if (tab === "groups") refreshGroups(); if (!chatShown && chatView.inputFocused) keyCatcher.forceActiveFocus(); rowIndex = 0; filterText = ""; filterField.text = ""; armedUninstall = 0; list.positionViewAtBeginning(); if (tab === "store") refreshStoreLists() }
  onStoreKindChanged: { rowIndex = 0; list.positionViewAtBeginning() }
  onFilterTextChanged: rowIndex = 0
  onMostPlayedChanged: { rowIndex = 0; list.positionViewAtBeginning() }
  onUninstalledOnlyChanged: { rowIndex = 0; list.positionViewAtBeginning() }
  onInstalledOnlyChanged: { rowIndex = 0; list.positionViewAtBeginning() }

  // ---------- data ----------
  function refreshGames() { if (!gamesProc.running) gamesProc.running = true; refreshRemote() }

  // Remote Play: other computers online and the games installed on them
  // (steamctl.py remote), so the library can stream what isn't installed here.
  property var remoteDevices: []
  property var remoteApps: ({})
  property var remoteSelected: ({})
  property bool remoteBusy: false

  function refreshRemote() {
    if (!controllable || remoteBusy) return
    remoteBusy = true
    runCtl(["remote"], function(ok, value) {
      root.remoteBusy = false
      if (!ok || !value || !root.changed("remote", value)) return
      root.remoteDevices = value.devices || []
      root.remoteApps = value.apps || {}
      root.remoteSelected = value.selected || {}
    })
  }

  // The computers a game can stream from, the one Steam last used first.
  function streamDevices(game) {
    var ids = game ? remoteApps[String(game.appid)] || [] : []
    var first = game ? remoteSelected[String(game.appid)] : ""
    var out = []
    for (var i = 0; i < remoteDevices.length; i++)
      if (ids.indexOf(remoteDevices[i].id) >= 0) out.push(remoteDevices[i])
    out.sort(function(a, b) { return (b.id === first) - (a.id === first) })
    return out
  }

  function streamable(game) { return !!game && !game.installed && (remoteApps[String(game.appid)] || []).length > 0 }

  // Remote Play another computer's whole desktop.
  // Remote Play wakes another computer, so it asks first: these set what's
  // being asked about, and the dialog's Start runs it.
  property var pendingStream: null

  function streamDesktop(device) {
    if (device) pendingStream = { device: device, game: null }
  }

  function streamGame(game, device) {
    if (game && device) pendingStream = { device: device, game: game }
  }

  function confirmStream() {
    var p = pendingStream
    pendingStream = null
    if (!p) return
    actionError = ""
    if (p.game) runCtl(["stream", String(p.game.appid), p.device.id], function(ok, value, error) {
      if (!ok) root.actionError = "Couldn't stream " + p.game.name + ": " + error
    })
    else runCtl(["desktop", p.device.id], function(ok, value, error) {
      if (!ok) root.actionError = "Couldn't start Remote Play on " + p.device.name + ": " + error
    })
    close()
  }

  function cancelStream() {
    pendingStream = null
    keyCatcher.forceActiveFocus()
  }
  // steam.py caches the lists for an hour, so this is cheap to call often.
  function refreshStoreLists() { if (!storeListsProc.running) storeListsProc.running = true }
  // With Steam controllable the friend list comes live from the client
  // (presence, what they're playing, unread chats); otherwise steam.py.
  property bool friendsCtlBusy: false

  function refreshFriends() {
    if (controllable) {
      if (friendsCtlBusy) return
      friendsCtlBusy = true
      runCtl(["friends"], function(ok, value) {
        root.friendsCtlBusy = false
        if (!ok) return
        var v = value || []
        if (root.changed("friends", v)) root.keepScroll(function() {
          root.friendGroups = Array.isArray(v) ? [] : v.groups || []
          root.friends = root.sortFriends(Array.isArray(v) ? v : v.friends || [])
        })
        root.friendsCached = false
        root.friendsLoaded = true
        root.friendsError = ""
        root.syncChatFriend()
      })
      refreshGroups()
      return
    }
    if (friendsProc.running) return
    friendsProc.environment = { "STEAM_API_KEY": root.apiKey }
    friendsProc.running = true
  }

  // Replacing the list's rows sends it back to the top. Changes made in
  // place (minimising a group, a refresh) keep it where it was: the rows
  // above don't move, so what's below slides under them.
  function keepScroll(change) {
    if (tab !== "friends" && tab !== "library") { change(); return }
    var y = list.contentY
    function restore() {
      if (root.tab === "friends" || root.tab === "library")
        list.contentY = Math.max(list.originY, Math.min(y, list.originY + list.contentHeight - list.height))
    }
    change()
    restore()
    // Again once the rows are laid out, in case the view reset after.
    Qt.callLater(restore)
  }

  function toggleGroup(id) {
    var next = Object.assign({}, collapsedGroups)
    if (next[id]) delete next[id]; else next[id] = true
    keepScroll(function() { collapsedGroups = next })
    Quickshell.execDetached(["python3", root.script, "set-collapsed", JSON.stringify(Object.keys(next))])
  }

  function sortFriends(list) {
    var rank = { "in-game": 0, "online": 1, "busy": 2, "away": 2 }
    return list.slice().sort(function(a, b) {
      if (!!a.unread !== !!b.unread) return a.unread ? -1 : 1
      var ra = rank[a.state] === undefined ? 3 : rank[a.state]
      var rb = rank[b.state] === undefined ? 3 : rank[b.state]
      if (ra !== rb) return ra - rb
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
    })
  }

  onControllableChanged: if (controllable) { refreshFriends(); refreshRemote(); steamStarting = false }

  // ---------- chat ----------
  // Clicking a friend widens the popup to the right with a chat pane that
  // reads and sends through the Steam client (steamctl.py chat/send). A
  // chat can also pop out into its own window, which outlives the popup.
  property var chatFriend: null
  // A group chat open in the pane instead (one of groupChats).
  property var chatGroup: null
  readonly property bool chatOpen: !!chatFriend || !!chatGroup
  // The pane shows on its own tab (a friend's on Friends, a group's on
  // Groups); elsewhere it's tucked away and comes back with the tab.
  readonly property bool chatShown: (!!chatFriend && tab === "friends") || (!!chatGroup && tab === "groups")
  // Your group chats from the client (steamctl.py groups), newest first.
  property var groupChats: []
  property bool groupsBusy: false
  property string pendingGroupChat: ""
  readonly property int groupUnread: {
    var n = 0
    for (var i = 0; i < groupChats.length; i++) n += groupChats[i].unread || 0
    return n
  }
  readonly property var groupRows: {
    var q = filterText.trim().toLowerCase()
    return q === "" ? groupChats : groupChats.filter(function(g) {
      return (g.name + "\n" + g.tagline).toLowerCase().indexOf(q) >= 0
    })
  }
  // Account ids with a chat window open, and the friend each was opened
  // for (used while the live list doesn't have them).
  property var popouts: []
  property var popoutFriends: ({})
  // Popped-out group chats are "g:<group id>" in popouts.
  property var popoutGroups: ({})
  readonly property real railWidth: Style.space(64)
  // ---------- sizes ----------
  // The list, chat and store widths and the popup's height: the defaults,
  // your saved sizes (from dragging the corner grips or the divider beside a
  // pane), or the size being dragged right now.
  readonly property real minList: Style.space(300)
  readonly property real minChat: Style.space(260)
  readonly property real minStore: Style.space(360)
  readonly property real minHeight: Style.space(360)
  property real dragList: -1
  property real dragChat: -1
  property real dragStore: -1
  property real dragHeight: -1

  // How far the popup's left or right edge moves per unit of width (1, ½
  // or 0): it's centred under its bar button and kept on screen. And how
  // far its bottom moves per unit of height.
  function edgeRate(side) {
    var x = panel.cardOrigin.x, w = panel.contentWidth
    var leftStuck = x <= panel.margin + 1, rightStuck = x + w >= panel.screenW - panel.margin - 1
    if (side === "bottom") return panel.barPos === "top" ? 1 : panel.barPos === "bottom" ? 0 : 0.5
    if (side === "right") return panel.barPos === "left" ? 1 : panel.barPos === "right" ? 0 : rightStuck ? 0 : leftStuck ? 1 : 0.5
    return panel.barPos === "right" ? 1 : panel.barPos === "left" ? 0 : leftStuck ? 0 : rightStuck ? 1 : 0.5
  }

  // A drag ended: keep the new sizes.
  function finishResize() {
    var sizes = { listWidth: dragList, chatWidth: dragChat, storeWidth: dragStore, panelHeight: dragHeight }
    for (var name in sizes) if (sizes[name] >= 0) savePref(name, Math.round(sizes[name]))
    dragList = dragChat = dragStore = dragHeight = -1
  }

  function savedSize(name, fallback, min) {
    var v = Number(pref(name, 0))
    return Math.max(min, v > 0 ? v : fallback)
  }

  readonly property real listWidth: dragList >= 0 ? dragList
    : savedSize("listWidth", railTop ? Style.space(410) : railWidth + Style.space(340), minList)
  readonly property var tabInfo: ({
    store: { icon: "󰓜", label: "Store" },
    library: { icon: "󰓓", label: "Library" },
    friends: { icon: "󰡉", label: "Friends" },
    groups: { icon: "󰭹", label: "Groups" },
    settings: { icon: "󰒓", label: "Settings" }
  })
  readonly property real chatWidth: dragChat >= 0 ? dragChat : savedSize("chatWidth", Style.space(330), minChat)
  readonly property int unreadTotal: {
    var n = 0
    for (var i = 0; i < friends.length; i++) n += friends[i].unread || 0
    return n
  }

  function openChat(friend) {
    if (!friend) return
    closeStore()
    if (!controllable) { launch("steam://friends/message/" + friend.steamid); return }
    chatGroup = null
    if (!chatFriend || chatFriend.accountid !== friend.accountid) chatFriend = friend
    Qt.callLater(function() { chatView.focusInput() })
  }

  function openGroupChat(group) {
    if (!group) return
    closeStore()
    chatFriend = null
    if (!chatGroup || chatGroup.id !== group.id) chatGroup = group
    Qt.callLater(function() { chatView.focusInput() })
  }


  function closeChat() {
    chatFriend = null
    chatGroup = null
    keyCatcher.forceActiveFocus()
  }

  function groupLine(g) {
    if (!g) return ""
    var parts = []
    if ((g.rooms || []).length > 1) parts.push(g.rooms.length + " rooms")
    parts.push(g.tagline || (g.members + (g.members === 1 ? " member" : " members")))
    return parts.join(" · ")
  }

  function groupById(id) {
    for (var i = 0; i < groupChats.length; i++) if (groupChats[i].id === id) return groupChats[i]
    return popoutGroups[id] || null
  }

  function refreshGroups() {
    if (!controllable || groupsBusy) return
    groupsBusy = true
    runCtl(["groups"], function(ok, value) {
      root.groupsBusy = false
      if (!ok || !Array.isArray(value)) return
      if (root.changed("groups", value)) root.groupChats = value
      if (root.chatGroup) root.chatGroup = root.groupById(root.chatGroup.id) || root.chatGroup
      if (root.pendingGroupChat) {
        var g = root.groupById(root.pendingGroupChat)
        root.pendingGroupChat = ""
        if (g) root.openGroupChat(g)
      }
    })
  }

  function friendById(accountid) {
    for (var i = 0; i < friends.length; i++) if (friends[i].accountid === accountid) return friends[i]
    return popoutFriends[accountid] || null
  }

  // Games by app id, for lookups from rows, cards and the store lists.
  readonly property var gamesById: {
    var out = {}
    for (var i = 0; i < games.length; i++) out[games[i].appid] = games[i]
    return out
  }

  function gameById(appid) { return gamesById[appid] || null }

  // Polls bring the same data back most of the time; replacing a list with
  // an equal one would still rebuild everything bound to it, so this says
  // whether `value` differs from the last one seen under `key`.
  property var seen: ({})
  function changed(key, value) {
    var sig = typeof value === "string" ? value : JSON.stringify(value)
    if (seen[key] === sig) return false
    seen[key] = sig
    return true
  }

  // Opens the chat in its own window, or brings its window forward
  // (switching workspace if it's on another) when it's already open, and
  // closes the popup.
  function popOutChat(friend) {
    if (!friend) return
    var id = String(friend.accountid)
    var known = Object.assign({}, popoutFriends)
    known[id] = friend
    popoutFriends = known
    if (chatFriend) closeChat()
    if (popouts.indexOf(id) < 0) popouts = popouts.concat([id])
    else focusPopout(id)
    close()
  }

  // Copies through wl-copy's stdin, so chat text never shows in a process list.
  function copyText(text) {
    if (clipboardProc.running) return
    clipboardProc.pending = String(text || "")
    clipboardProc.stdinEnabled = true
    clipboardProc.running = true
  }

  Process {
    id: clipboardProc
    property string pending: ""
    command: ["wl-copy"]
    onStarted: { write(pending); stdinEnabled = false }
  }

  // Chat videos can play in a window each, picking up where the inline
  // player was; YouTube links play in mpv (through yt-dlp) when it's there.
  property var videoViewers: []
  property var videoStarts: ({})

  function openVideo(src, startMs) {
    if (!src) return
    var starts = Object.assign({}, videoStarts)
    starts[src] = startMs || 0
    videoStarts = starts
    if (videoViewers.indexOf(src) < 0) videoViewers = videoViewers.concat([src])
    else focusWindow(videoTitle(src))
  }

  function closeVideo(src) {
    videoViewers = videoViewers.filter(function(s) { return s !== src })
  }

  function videoTitle(src) {
    var parts = String(src).split("/").filter(function(p) { return p !== "" })
    return "Steam video · " + (parts.length ? parts[parts.length - 1].slice(0, 12) : "")
  }

  function playYoutube(card) {
    if (!card || !/^[\w-]{11}$/.test(card.id)) return
    Quickshell.execDetached(["sh", "-c",
      "if command -v mpv >/dev/null; then exec mpv --force-window=immediate --title=\"$2\" -- \"$1\"; else exec xdg-open \"$1\"; fi",
      "youtube", "https://www.youtube.com/watch?v=" + card.id, "YouTube · " + (card.title || card.id)])
  }

  function mediaTime(ms) {
    var t = Math.max(0, Math.floor((ms || 0) / 1000))
    var h = Math.floor(t / 3600), m = Math.floor(t % 3600 / 60), sec = t % 60
    return (h ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (sec < 10 ? "0" : "") + sec
  }

  // Chat images open full size in a window each, with zoom.
  property var imageViewers: []

  function openImage(src) {
    if (!src) return
    if (imageViewers.indexOf(src) < 0) imageViewers = imageViewers.concat([src])
    else focusWindow(imageTitle(src))
  }

  function closeImage(src) {
    imageViewers = imageViewers.filter(function(s) { return s !== src })
  }

  function imageTitle(src) {
    var parts = String(src).split("/").filter(function(p) { return p !== "" })
    return "Steam image · " + (parts.length ? parts[parts.length - 1].slice(0, 12) : "")
  }

  function popoutTitle(key) {
    if (String(key).indexOf("g:") === 0) {
      var g = groupById(key.slice(2))
      return "Steam group chat · " + (g ? g.name : key.slice(2))
    }
    var f = friendById(key)
    return "Steam chat · " + (f ? f.name : key)
  }

  function popOutGroup(group) {
    if (!group) return
    var known = Object.assign({}, popoutGroups)
    known[group.id] = group
    popoutGroups = known
    if (chatOpen) closeChat()
    var key = "g:" + group.id
    if (popouts.indexOf(key) < 0) popouts = popouts.concat([key])
    else focusPopout(key)
    close()
  }

  function focusPopout(accountid) { focusWindow(popoutTitle(accountid)) }

  // Bring one of this widget's windows forward by title, switching
  // workspace when it's on another.
  function focusWindow(title) {
    Quickshell.execDetached(["sh", "-c",
      "addr=$(hyprctl clients -j | jq -r --arg t \"$1\" " +
      "'map(select(.class == \"org.quickshell\" and .title == $t)) | .[0].address // empty'); " +
      "[ -n \"$addr\" ] || exit 0; " +
      "hyprctl dispatch \"hl.dsp.focus({ window = \\\"address:$addr\\\" })\" >/dev/null 2>&1 || " +
      "hyprctl dispatch focuswindow \"address:$addr\"",
      "focus-window", title])
  }

  function closePopout(accountid) {
    popouts = popouts.filter(function(id) { return id !== accountid })
  }

  // ---------- store page ----------
  // Clicking a game you don't own in Store (or pressing i on any game) widens
  // the popup with its store page from `steam.py store`. Buying still
  // happens in Steam.
  property var storeGame: null
  property var storePage: null
  property string storeError: ""
  property int storeWanted: 0
  property int mediaIndex: 0
  property bool storeMuted: true
  readonly property bool storeOpen: !!storeGame
  readonly property real storeWidth: dragStore >= 0 ? dragStore : savedSize("storeWidth", Style.space(460), minStore)
  readonly property var storeMedia: storePage && storePage.media ? storePage.media : []
  readonly property var storeOwned: storeGame ? gameById(storeGame.appid) : null

  function openStore(game) {
    // Only games have store pages (not headers, computers or group chats).
    if (!game || !game.appid) return
    chatFriend = null
    chatGroup = null
    if (storeGame && storeGame.appid === game.appid) return
    storeGame = game
    storeError = ""
    mediaIndex = 0
    if (!storePage || storePage.appid !== game.appid) storePage = null
    storeWanted = game.appid
    loadStore()
  }

  function closeStore() {
    storeGame = null
    storeWanted = 0
  }

  function loadStore() {
    if (storeProc.running || !storeWanted) return
    storeProc.appid = storeWanted
    storeProc.command = ["python3", root.script, "store", String(storeWanted)]
    storeProc.running = true
  }

  function stepMedia(delta) {
    var n = storeMedia.length
    if (n) mediaIndex = (mediaIndex + delta + n) % n
  }

  function buyInSteam() {
    if (storeGame) launch("steam://store/" + storeGame.appid)
  }

  function reviewColor(percent) {
    return percent >= 70 ? "#66c0f4" : percent >= 40 ? "#b9a074" : "#c35c2c"
  }

  function reviewLine(r) {
    if (!r || !r.count) return ""
    return r.label + " · " + r.percent + "% of " + Number(r.count).toLocaleString(Qt.locale(), "f", 0)
  }

  // Keep the header's status current as the friend list refreshes.
  function syncChatFriend() {
    if (!chatFriend) return
    for (var i = 0; i < friends.length; i++)
      if (friends[i].accountid === chatFriend.accountid) { chatFriend = friends[i]; return }
  }

  // Each message carries its time; a day label divides the days.
  function chatTime(ts) { return Qt.formatTime(new Date(ts * 1000), "HH:mm") }

  function chatDay(ts) {
    var d = new Date(ts * 1000), now = new Date()
    var yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
    if (d.toDateString() === now.toDateString()) return "Today"
    if (d.toDateString() === yesterday.toDateString()) return "Yesterday"
    return Qt.formatDate(d, d.getFullYear() === now.getFullYear() ? "ddd d MMM" : "d MMM yyyy")
  }

  // Native `steam` when installed, otherwise the Flatpak.
  readonly property var steamCommand: ["sh", "-c",
    "if command -v steam >/dev/null; then exec steam \"$@\"; else exec flatpak run com.valvesoftware.Steam \"$@\"; fi", "steam"]

  // From the debugging notice: start Steam, or restart it so it opens the
  // port. "Starting…" shows until the next check sees it (or a minute passes).
  property bool steamStarting: false

  function startSteam() {
    steamStarting = true
    steamStartTimeout.restart()
    Quickshell.execDetached(steamCommand)
    refreshSoon.restart()
  }

  function restartSteam() {
    steamStarting = true
    steamStartTimeout.restart()
    Quickshell.execDetached(["sh", "-c",
      "if command -v steam >/dev/null; then s=steam; else s='flatpak run com.valvesoftware.Steam'; fi; " +
      "$s -shutdown; i=0; while pgrep -x steam >/dev/null && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done; exec $s"])
    refreshSoon.restart()
  }

  Timer { id: steamStartTimeout; interval: 60000; onTriggered: root.steamStarting = false }
  // Check back every few seconds while Steam comes up, so the notice clears.
  Timer {
    id: refreshSoon
    interval: 3000
    repeat: true
    running: false
    onTriggered: { root.refreshDownloads(); if (!root.steamStarting) stop() }
  }

  function launch(command) {
    Quickshell.execDetached(steamCommand.concat([command]))
    root.close()
  }

  function activateRow(item) {
    if (!item) return
    if (root.tab === "friends" && item.isHeader) toggleGroup(item.sectionId)
    else if (root.tab === "friends" && item.isIconBar) return
    else if (root.tab === "friends") openChat(item)
    else if (root.tab === "groups") openGroupChat(item)
    else if (root.tab === "store" && !item.owned) openStore(item)
    else if (item.isHeader) { if (item.collapsible) toggleGroup(item.sectionId) }
    else if (item.isDevice) streamDesktop(item.device)
    else if (item.isDeviceBar || item.isGameGrid) return
    else if (item.streamDevice) streamGame(item, item.streamDevice)
    else if (item.installed) launch("steam://rungameid/" + item.appid)
    else if (streamable(item)) streamGame(item, streamDevices(item)[0])
    else if (downloadsById[item.appid]) toggleDownload(downloadsById[item.appid])
    else installGame(item, preferredFolder)
  }

  // ---------- Steam client commands (steamctl.py) ----------
  property var ctlQueue: []

  // input, if given, goes to the helper's stdin rather than its argv.
  function runCtl(args, input, onDone) {
    if (typeof input === "function") { onDone = input; input = undefined }
    ctlQueue = ctlQueue.concat([{ args: args, input: input, onDone: onDone }])
    if (!ctlProc.running) nextCtl()
  }

  function nextCtl() {
    if (!ctlQueue.length || ctlProc.running) return
    var job = ctlQueue[0]
    ctlQueue = ctlQueue.slice(1)
    ctlProc.job = job
    ctlProc.command = ["python3", root.ctlScript].concat(job.args)
    ctlProc.stdinEnabled = job.input !== undefined
    ctlProc.running = true
  }

  function refreshFolders() {
    runCtl(["folders"], function(ok, value) {
      root.controllable = ok
      if (ok) root.folders = value || []
    })
  }

  function folderName(f) {
    if (!f) return ""
    if (f.label) return f.label
    if (f.path.indexOf("/.local/share/Steam") >= 0) return "Home"
    var parts = String(f.drive || f.path).split("/").filter(function(x) { return !!x })
    return parts.length ? parts[parts.length - 1] : f.path
  }

  // Installs run one at a time in their own process, since one can sit
  // waiting for a licence agreement to be accepted in Steam. Until Steam's
  // log shows the download, it's listed from pendingInstalls.
  property var installQueue: []
  property var pendingInstalls: ({})
  property var installing: null
  // Last drawn progress-bar position per appid (see ProgressGlide).
  property var glideState: ({})

  function installGame(game, folder) {
    if (!game) return
    if (!controllable || !folder) { launch("steam://install/" + game.appid); return }
    if (pendingInstalls[game.appid] || downloadsById[game.appid]) return
    if (opened) reopenUntil = Date.now() + 6000
    actionError = ""
    var pending = Object.assign({}, pendingInstalls)
    pending[game.appid] = { appid: game.appid, name: game.name, status: "preparing", staged: 0, total: 0,
      progress: 0, header: game.header, icon: game.icon, speed: 0, since: Date.now() }
    pendingInstalls = pending
    downloads = mergePending(downloads)
    installQueue = installQueue.concat([{ game: game, folder: folder }])
    nextInstall()
  }

  function nextInstall() {
    if (installProc.running || !installQueue.length) return
    installing = installQueue[0]
    installQueue = installQueue.slice(1)
    installProc.command = ["python3", root.ctlScript, "install", String(installing.game.appid), String(installing.folder.index)]
    installProc.running = true
    eulaHint.restart()
  }

  function dropPending(appid) {
    var pending = Object.assign({}, pendingInstalls)
    delete pending[appid]
    pendingInstalls = pending
  }

  // Keep a just-started install listed until Steam reports it (or 30s pass).
  function mergePending(list) {
    var seen = {}
    for (var i = 0; i < list.length; i++) seen[list[i].appid] = true
    var out = list.slice()
    var now = Date.now()
    for (var id in pendingInstalls) {
      var p = pendingInstalls[id]
      var waiting = installing && installing.game.appid === p.appid
      if (seen[p.appid] || (!waiting && now - p.since > 30000)) { dropPending(p.appid); continue }
      out.push(p)
    }
    return out
  }

  // ---------- uninstalling ----------
  // appid -> true while Steam removes it; cleared once the library no longer
  // lists it as installed. armedUninstall is the game whose X was clicked
  // once and now asks for a second click to confirm.
  property var uninstalling: ({})
  property int armedUninstall: 0

  function uninstallGame(game) {
    if (!game || !game.installed || !controllable || uninstalling[game.appid]) return
    armedUninstall = 0
    actionError = ""
    var busy = Object.assign({}, uninstalling)
    busy[game.appid] = true
    uninstalling = busy
    runCtl(["uninstall", String(game.appid)], function(ok, value, error) {
      if (!ok) {
        root.actionError = "Couldn't uninstall " + game.name + ": " + error
        var b = Object.assign({}, root.uninstalling)
        delete b[game.appid]
        root.uninstalling = b
      }
      root.refreshGames()
    })
  }

  // X on the keyboard: first press arms the selected game, second uninstalls.
  function uninstallSelected() {
    if (!cursorActive || tab === "friends") return
    var game = rows[rowIndex]
    if (!game || !game.installed) return
    if (armedUninstall === game.appid) uninstallGame(game)
    else armedUninstall = game.appid
  }

  onRowIndexChanged: armedUninstall = 0

  // Watch the library until Steam has finished removing each game.
  Timer {
    interval: 1500
    repeat: true
    running: Object.keys(root.uninstalling).length > 0
    onTriggered: root.refreshGames()
  }

  onGamesChanged: {
    var ids = Object.keys(uninstalling)
    if (!ids.length) return
    var still = {}
    for (var i = 0; i < games.length; i++)
      if (uninstalling[games[i].appid] && games[i].installed) still[games[i].appid] = true
    if (Object.keys(still).length !== ids.length) uninstalling = still
  }

  function setDownloadStatus(appid, status) {
    var list = []
    for (var i = 0; i < downloads.length; i++) {
      var d = downloads[i]
      if (d.appid === appid) { d = Object.assign({}, d); d.status = status; d.speed = 0 }
      list.push(d)
    }
    downloads = list
  }

  function toggleDownload(d) {
    if (!d || !controllable) { launch("steam://open/downloads"); return }
    var pausing = d.status !== "paused"
    setDownloadStatus(d.appid, pausing ? "paused" : "preparing")
    runCtl([pausing ? "pause" : "resume", String(d.appid)], function(ok, value, error) {
      if (!ok) root.actionError = error
      settleTimer.restart()
    })
  }

  function imageSource(path) {
    if (!path) return ""
    return path.indexOf("http") === 0 ? path : "file://" + path
  }

  function storeLine(g) {
    var price = g.price ? g.price + (g.discount ? " (−" + g.discount + "%)" : "") : ""
    var mine = root.uninstalling[g.appid] ? "Uninstalling…" : g.installed ? "Installed" : g.owned ? "In library" : ""
    var released = String(g.released || "").replace(", " + new Date().getFullYear(), "")
    var parts = storeKind === "upcoming" ? ["#" + g.rank, released, mine || price]
      : storeKind === "new" ? [released, mine || price]
      : ["#" + g.rank, mine || price]
    return parts.filter(function(x) { return !!x }).join(" · ")
  }


  function playtimeLabel(minutes) {
    if (!minutes) return ""
    if (minutes < 60) return minutes + " min"
    var h = minutes / 60
    return (h < 10 ? h.toFixed(1) : Math.round(h)) + " h"
  }

  function stateColor(state) {
    if (state === "in-game") return inGameColor
    if (state === "online") return onlineColor
    if (state === "away" || state === "busy") return Qt.darker(onlineColor, 1.6)
    return dim
  }

  function friendLine(f) {
    if (f.state === "in-game")
      return f.game ? (f.presence ? f.game + " · " + f.presence : "Playing " + f.game) : f.presence || "In-Game"
    if (f.state === "unknown") return "Status unavailable"
    return f.statusText || (f.state.charAt(0).toUpperCase() + f.state.slice(1))
  }

  // ---------- keyboard ----------
  // Left/Right walk the store's lists, then the other tabs.
  function switchTab(delta) {
    var views = []
    tabOrder.concat(["settings"]).forEach(function(t) {
      views = views.concat(t === "store" ? storeKinds.map(function(k) { return "store:" + k }) : [t])
    })
    var i = views.indexOf(tab === "store" ? "store:" + storeKind : tab) + delta
    if (i < 0 || i >= views.length) return
    var v = views[i].split(":")
    tab = v[0]
    if (v[1]) storeKind = v[1]
  }

  function moveRow(delta) {
    if (!cursorActive) { cursorActive = true; return }
    if ((tab === "library" || tab === "friends" || tab === "groups") && delta < 0 && rowIndex === 0) { focusFilter(); return }
    var n = rows.length
    if (!n) return
    rowIndex = Math.max(0, Math.min(n - 1, rowIndex + delta))
    list.positionViewAtIndex(rowIndex, ListView.Contain)
    if (storeOpen && tab !== "friends") openStore(rows[rowIndex])
  }

  function focusFilter() {
    if (tab !== "library" && tab !== "friends" && tab !== "groups") tab = "library"
    filterField.forceActiveFocus()
    cursorActive = false
  }

  // ---------- routing (open on the main monitor, like the other widgets) ----------
  readonly property string screenName: {
    var w = button.QsWindow.window
    return w && w.screen ? String(w.screen.name) : ""
  }
  property string mainMonitor: ""

  function instances() {
    return bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) || [root] : [root]
  }

  function mainInstance() {
    mainMonitorProc.running = true  // refresh for next time
    var items = instances()
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i].screenName === mainMonitor) return items[i]
    return root
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.mainInstance().open() }
    function close(): void { var items = root.instances(); for (var i = 0; i < items.length; i++) items[i].close() }
    function show(): void { root.mainInstance().open() }
    function hide(): void { var items = root.instances(); for (var i = 0; i < items.length; i++) items[i].close() }
    function toggle(): void { root.mainInstance().toggle() }
    // Recent is a section of the library now.
    function tab(name: string): void { var t = root.mainInstance(); t.keepTab = true; t.tab = name === "recent" ? "library" : name; t.open() }
    function chat(account: string): void {
      var t = root.mainInstance()
      for (var i = 0; i < t.friends.length; i++)
        if (String(t.friends[i].accountid) === account) { t.keepTab = true; t.tab = "friends"; t.open(); t.openChat(t.friends[i]); return }
    }
    function video(url: string): void { if (/^https:\/\//.test(url)) root.mainInstance().openVideo(url, 0) }
    function image(url: string): void { if (/^https:\/\//.test(url)) root.mainInstance().openImage(url) }
    function groupchat(id: string): void {
      var t = root.mainInstance()
      t.keepTab = true
      t.tab = "groups"
      t.open()
      var g = t.groupById(id)
      // Not loaded yet (just started): open it when the list arrives.
      if (g) t.openGroupChat(g); else { t.pendingGroupChat = id; t.refreshGroups() }
    }
    function popout(account: string): void {
      var t = root.mainInstance()
      var f = t.friendById(account)
      if (f) t.popOutChat(f)
    }
    function store(appid: string): void {
      var t = root.mainInstance()
      t.keepTab = true
      t.tab = "store"
      t.open()
      var list = t.storeRows.concat(t.games)
      for (var i = 0; i < list.length; i++)
        if (String(list[i].appid) === appid) { t.openStore(list[i]); return }
      t.openStore({ appid: Number(appid), name: "" })
    }
    function state(): string {
      var t = root.mainInstance()
      return JSON.stringify({ opened: t.opened, reopenIn: Math.round(t.reopenUntil - Date.now()), installing: !!t.installing,
        controllable: t.controllable, folders: t.folders.length, preferred: t.preferredFolder ? t.preferredFolder.path : null, downloads: t.downloads.map(function(d) { return d.name + ":" + d.status }), error: t.actionError })
    }
  }

  Process {
    id: mainMonitorProc
    command: ["sh", "-c", "hyprctl getoption cursor:default_monitor -j | jq -r '.str // empty'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var name = String(text || "").trim()
        root.mainMonitor = name === "[[EMPTY]]" ? "" : name
      }
    }
  }

  Component.onCompleted: { mainMonitorProc.running = true; friendsCacheProc.running = true; refreshGames(); refreshDownloads(); refreshFolders() }

  // Downloads: quick checks while one is running or the popup is open (the
  // bar icon shows progress too), a slow check otherwise to notice new ones.
  Timer {
    interval: root.opened || root.activeDownload ? 2000 : 10000
    running: true
    repeat: true
    onTriggered: root.refreshDownloads()
  }

  Process {
    id: installProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var job = root.installing
        var r = {}
        try { r = JSON.parse(String(text || "{}")) } catch (e) { r = { ok: false, error: "no reply" } }
        eulaHint.stop()
        if (job) {
          var name = job.game.name
          if (!r.ok) root.actionError = "Couldn't install " + name + ": " + (r.error || "no reply")
          else if (r.value === "needs-steam") root.actionError = "Steam needs you to finish installing " + name + " in its window."
          else if (r.value === "failed") root.actionError = "Steam couldn't install " + name + "."
          else if (r.value === "cancelled") root.actionError = ""
          else if (root.actionError.indexOf("licence") >= 0) root.actionError = ""
          if (!r.ok || r.value === "cancelled" || r.value === "needs-steam" || r.value === "failed") {
            root.dropPending(job.game.appid)
            root.downloads = root.downloads.filter(function(d) { return d.appid !== job.game.appid || d.total > 0 })
          } else {
            // Restart the grace period from when Steam actually took it.
            var p = root.pendingInstalls[job.game.appid]
            if (p) p.since = Date.now()
          }
        }
        root.installing = null
        settleTimer.restart()
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.nextInstall)
  }

  // An install still waiting after a few seconds is at a licence agreement.
  Timer {
    id: eulaHint
    interval: 4000
    onTriggered: if (root.installing)
      root.actionError = "Accept the licence agreement for " + root.installing.game.name + " in Steam's window to start the download."
  }

  Process {
    id: ctlProc
    property var job: null
    // Writing the input then closing stdin lets the helper read to EOF.
    onStarted: {
      if (job && job.input !== undefined) {
        write(job.input)
        stdinEnabled = false
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var job = ctlProc.job
        var r = {}
        try { r = JSON.parse(String(text || "{}")) } catch (e) { r = { ok: false, error: "no reply" } }
        if (job && job.onDone) job.onDone(!!r.ok, r.value, r.error || "")
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.nextCtl)
  }

  // Steam takes a moment to report a pause/resume/install in its log.
  Timer {
    id: settleTimer
    interval: 1200
    onTriggered: root.refreshDownloads()
  }

  Process {
    id: downloadsProc
    command: ["python3", root.script, "downloads"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          var wasDownloading = root.downloads.length > 0
          if (d.controllable !== undefined && d.controllable !== root.controllable) {
            root.controllable = d.controllable
            if (d.controllable) root.refreshFolders()
          }
          if (d.controllable !== undefined) {
            root.controlChecked = true
            if (d.controllable) root.degradedOpen = false
            else {
              root.steamRunning = d.steamRunning !== false
              root.debugFlag = !!d.debugFlag
              root.debugFlagPath = d.debugFlagPath || ""
            }
          }
          if (d.downloads) root.updateDownloads(root.mergePending(d.downloads), d.time || Date.now() / 1000)
          // A finished download changes what's installed.
          if (wasDownloading && root.downloads.length === 0) root.refreshGames()
        } catch (e) {}
      }
    }
  }

  // Steam's install dialog flashes up for a moment even when hidden, taking
  // keyboard focus and so closing this popup. While a quiet install is
  // starting, reopen it -- unless you closed it, or Steam is now showing a
  // licence agreement you need to see.
  property real reopenUntil: 0
  property bool reopening: false

  Timer {
    id: reopenTimer
    interval: 400
    onTriggered: root.runCtl(["wizard-state"], function(ok, state) {
      if (root.opened || Date.now() > root.reopenUntil || (ok && state === 8)) return
      root.reopening = true
      root.open()
    })
  }

  onOpenedChanged: {
    if (!opened) { armedUninstall = 0; chatFriend = null; chatGroup = null; pendingStream = null; gameOptions = null; closeStore() }
    if (!opened && Date.now() < reopenUntil) { reopenTimer.restart(); return }
    if (opened && reopening) { reopening = false; return }
    if (opened) {
      if (openFirstTab && !keepTab) tab = tabOrder[0]
      keepTab = false
      refreshGames()
      refreshFriends()
      refreshDownloads()
      refreshFolders()
      actionError = ""
      cursorActive = false
      rowIndex = 0
    } else if (filterText !== "") {
      filterText = ""
      filterField.text = ""
    }
  }

  // Friends: live from Steam every few seconds while open (and slowly while
  // closed, for the bar's unread dot). Without Steam control, only while
  // open: the API is cheap, the per-profile fallback isn't.
  Timer {
    interval: root.controllable ? (root.opened ? 5000 : 20000) : (root.apiKey !== "" ? 30000 : 90000)
    running: root.opened || root.controllable
    repeat: true
    onTriggered: root.refreshFriends()
  }

  // Popped-out chats: a window each, open until you close it.
  Variants {
    model: root.popouts

    FloatingWindow {
      id: chatWindow
      required property string modelData
      readonly property bool isGroup: modelData.indexOf("g:") === 0
      readonly property var friend: isGroup ? null : root.friendById(modelData)
      readonly property var group: isGroup ? root.groupById(modelData.slice(2)) : null
      title: root.popoutTitle(modelData)
      implicitWidth: 420
      implicitHeight: 580
      minimumSize: Qt.size(300, 320)
      color: Color.background
      visible: true
      onClosed: root.closePopout(modelData)

      // Hyprland doesn't always hand focus to a new window; ask once it's mapped.
      Timer {
        interval: 250
        running: true
        onTriggered: root.focusPopout(chatWindow.modelData)
      }

      ChatView {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        friend: chatWindow.friend
        group: chatWindow.group
        active: true
        popout: true
        onCloseRequested: root.closePopout(chatWindow.modelData)
        Component.onCompleted: focusInput()
      }
    }
  }

  Variants {
    model: root.videoViewers

    FloatingWindow {
      id: videoWindow
      required property string modelData
      title: root.videoTitle(modelData)
      implicitWidth: 960
      implicitHeight: 600
      minimumSize: Qt.size(360, 260)
      color: "black"
      visible: true
      onClosed: root.closeVideo(modelData)

      Timer {
        interval: 250
        running: true
        onTriggered: { root.focusWindow(videoWindow.title); videoKeys.forceActiveFocus() }
      }

      Item {
        id: videoKeys
        anchors.fill: parent
        focus: true

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) root.closeVideo(videoWindow.modelData)
          else if (event.key === Qt.Key_Space || event.key === Qt.Key_K) windowPlayer.toggle()
          else if (event.key === Qt.Key_Left) windowPlayer.seek(Math.max(0, windowPlayer.position - 5000))
          else if (event.key === Qt.Key_Right) windowPlayer.seek(Math.min(windowPlayer.duration, windowPlayer.position + 5000))
          else if (event.key === Qt.Key_M) windowPlayer.muted = !windowPlayer.muted
          else return
          event.accepted = true
        }

        Video {
          id: windowPlayer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: videoBar.top
          source: videoWindow.modelData
          volume: 0.8
          fillMode: VideoOutput.PreserveAspectFit
          property bool started: false
          function toggle() { if (playbackState === MediaPlayer.PlayingState) pause(); else play() }
          // Start where the chat's player was.
          onDurationChanged: if (!started && duration > 0) {
            started = true
            var at = root.videoStarts[videoWindow.modelData] || 0
            if (at > 0 && at < duration - 1000) seek(at)
          }
          Component.onCompleted: play()

          TapHandler { onTapped: { videoKeys.forceActiveFocus(); windowPlayer.toggle() } }
        }

        Text {
          anchors.centerIn: windowPlayer
          visible: windowPlayer.error !== MediaPlayer.NoError || windowPlayer.mediaStatus === MediaPlayer.LoadingMedia
          text: windowPlayer.error !== MediaPlayer.NoError ? "Couldn't play the video" : "Loading…"
          color: "white"
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Rectangle {
          id: videoBar
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: barRow.implicitHeight + Style.space(16)
          color: Color.background

          RowLayout {
            id: barRow
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(8)

            ActionButton {
              iconText: windowPlayer.playbackState === MediaPlayer.PlayingState ? "󰏤" : "󰐊"
              tooltipText: windowPlayer.playbackState === MediaPlayer.PlayingState ? "Pause (Space)" : "Play (Space)"
              fontSize: Style.font.body
              onClicked: windowPlayer.toggle()
            }

            Text {
              text: root.mediaTime(windowPlayer.position) + " / " + root.mediaTime(windowPlayer.duration)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSlider {
              Layout.fillWidth: true
              minimum: 0
              maximum: Math.max(1, windowPlayer.duration)
              step: 100
              value: windowPlayer.position
              onMoved: function(v) { windowPlayer.seek(v) }
            }

            ActionButton {
              iconText: windowPlayer.muted || windowPlayer.volume === 0 ? "󰝟" : "󰕾"
              tooltipText: windowPlayer.muted ? "Unmute (M)" : "Mute (M)"
              fontSize: Style.font.body
              onClicked: windowPlayer.muted = !windowPlayer.muted
            }

            PanelSlider {
              Layout.preferredWidth: Style.space(90)
              minimum: 0
              maximum: 1
              step: 0.05
              value: windowPlayer.volume
              onMoved: function(v) { windowPlayer.volume = v; windowPlayer.muted = false }
            }

            ActionButton {
              iconText: "󰏌"
              tooltipText: "Open in browser"
              foreground: root.dim
              fontSize: Style.font.body
              onClicked: Qt.openUrlExternally(videoWindow.modelData)
            }

            ActionButton {
              iconText: "󰅖"
              tooltipText: "Close (Esc)"
              fontSize: Style.font.body
              onClicked: root.closeVideo(videoWindow.modelData)
            }
          }
        }
      }
    }
  }

  Variants {
    model: root.imageViewers

    FloatingWindow {
      id: viewer
      required property string modelData
      property real zoom: 1
      readonly property real fitZoom: full.implicitWidth > 0
        ? Math.min(flick.width / full.implicitWidth, flick.height / full.implicitHeight) : 1
      title: root.imageTitle(modelData)
      implicitWidth: 1000
      implicitHeight: 720
      minimumSize: Qt.size(360, 280)
      color: Color.background
      visible: true
      onClosed: root.closeImage(modelData)

      function setZoom(z) { zoom = Math.max(0.05, Math.min(4, z)) }

      // Zoom keeping the image point under (px, py) in the view where it is.
      function zoomAt(z, px, py) {
        var ux = (flick.contentX + px - full.x) / zoom
        var uy = (flick.contentY + py - full.y) / zoom
        setZoom(z)
        flick.contentX = Math.max(0, Math.min(ux * zoom + full.x - px, flick.contentWidth - flick.width))
        flick.contentY = Math.max(0, Math.min(uy * zoom + full.y - py, flick.contentHeight - flick.height))
      }

      function zoomCentre(z) { zoomAt(z, flick.width / 2, flick.height / 2) }

      Timer {
        interval: 250
        running: true
        onTriggered: { root.focusWindow(viewer.title); keys.forceActiveFocus() }
      }

      Item {
        id: keys
        anchors.fill: parent
        focus: true

        // Clicking anywhere gives the keys back (+ - 0 1 Esc).
        TapHandler { onTapped: keys.forceActiveFocus() }

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) root.closeImage(viewer.modelData)
          else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) viewer.zoomCentre(viewer.zoom * 1.25)
          else if (event.key === Qt.Key_Minus) viewer.zoomCentre(viewer.zoom / 1.25)
          else if (event.key === Qt.Key_0) viewer.setZoom(viewer.fitZoom)
          else if (event.key === Qt.Key_1) viewer.zoomCentre(1)
          else return
          event.accepted = true
        }

        // Drag to pan and the wheel scrolls; shift + wheel zooms at the
        // mouse, and clicks step the zoom by 10% there.
        Flickable {
          id: flick
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: bar.top
          clip: true
          contentWidth: Math.max(width, full.width)
          contentHeight: Math.max(height, full.height)
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

          Image {
            id: full
            x: Math.max(0, (flick.width - width) / 2)
            y: Math.max(0, (flick.height - height) / 2)
            width: implicitWidth * viewer.zoom
            height: implicitHeight * viewer.zoom
            source: viewer.modelData
            asynchronous: true
            smooth: true
            mipmap: true
            fillMode: Image.Stretch
            // Start fitted to the window, never blown up past full size.
            onStatusChanged: if (status === Image.Ready) viewer.setZoom(Math.min(1, viewer.fitZoom))
          }

        }

        Item {
          anchors.fill: flick

          WheelHandler {
            acceptedModifiers: Qt.ShiftModifier
            onWheel: function(event) {
              // Some setups turn shift + wheel into a sideways scroll.
              var delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
              if (delta !== 0) viewer.zoomAt(viewer.zoom * (delta > 0 ? 1.15 : 1 / 1.15), event.x, event.y)
            }
          }

          // Click zooms in to the next 10% at the mouse, right-click out.
          TapHandler {
            enabled: full.status === Image.Ready
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onTapped: function(eventPoint, button) {
              var p = eventPoint.position
              var percent = Math.round(viewer.zoom * 1000) / 10
              var next = button === Qt.RightButton ? Math.ceil(percent / 10) * 10 - 10 : Math.floor(percent / 10) * 10 + 10
              viewer.zoomAt(Math.max(10, next) / 100, p.x, p.y)
            }
          }
        }

        Text {
          anchors.centerIn: flick
          visible: full.status !== Image.Ready
          text: full.status === Image.Error ? "Couldn't load the image" : "Loading…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        RowLayout {
          id: bar
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(10)
          spacing: Style.space(8)

          ActionButton {
            iconText: "󰍴"
            tooltipText: "Zoom out (-)"
            fontSize: Style.font.body
            onClicked: viewer.zoomCentre(viewer.zoom / 1.25)
          }

          PanelSlider {
            Layout.fillWidth: true
            minimum: 0.05
            maximum: 4
            step: 0.01
            value: viewer.zoom
            onMoved: function(v) { viewer.zoomCentre(v) }
          }

          ActionButton {
            iconText: "󰐕"
            tooltipText: "Zoom in (+)"
            fontSize: Style.font.body
            onClicked: viewer.zoomCentre(viewer.zoom * 1.25)
          }

          Text {
            Layout.preferredWidth: Style.space(48)
            horizontalAlignment: Text.AlignRight
            text: Math.round(viewer.zoom * 100) + "%"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ActionButton {
            iconText: "Fit"
            tooltipText: "Fit to window (0)"
            onClicked: viewer.setZoom(viewer.fitZoom)
          }

          ActionButton {
            iconText: "1:1"
            tooltipText: "Actual size (1)"
            onClicked: viewer.zoomCentre(1)
          }

          ActionButton {
            iconText: "󰏌"
            tooltipText: "Open in browser"
            foreground: root.dim
            fontSize: Style.font.body
            onClicked: Qt.openUrlExternally(viewer.modelData)
          }

          ActionButton {
            iconText: "󰅖"
            tooltipText: "Close (Esc)"
            fontSize: Style.font.body
            onClicked: root.closeImage(viewer.modelData)
          }
        }
      }
    }
  }

  Process {
    id: gamesProc
    command: ["python3", root.script, "games"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.errorText = d.error || ""
          if (d.games && root.changed("games", d.games)) root.games = d.games
        } catch (e) {
          root.errorText = "Couldn't read your Steam library"
        }
        root.gamesLoaded = true
      }
    }
  }

  Process {
    id: storeProc
    property int appid: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = null
        try { d = JSON.parse(String(text || "{}")) } catch (e) { d = { error: "Couldn't read the store page" } }
        if (storeProc.appid === root.storeWanted) {
          root.storeError = d.error || ""
          root.storePage = d.error ? null : d
          root.mediaIndex = 0
        }
      }
    }
    // Moving through the list while a page loads: fetch the latest one next.
    onRunningChanged: if (!running && root.storeWanted && root.storeWanted !== appid) Qt.callLater(root.loadStore)
  }

  Process {
    id: storeListsProc
    command: ["python3", root.script, "storelists"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          if (!d.error) root.storeLists = d
        } catch (e) {
          root.storeLists = { error: "Couldn't load the store" }
        }
        root.storeListsLoaded = true
      }
    }
  }

  // The friend list saved by the last refresh, shown until a live one lands.
  Process {
    id: friendsCacheProc
    command: ["python3", root.script, "friends-cached"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          var c = {}
          for (var i = 0; i < (d.collapsed || []).length; i++) c[d.collapsed[i]] = true
          root.collapsedGroups = c
          if (root.friendsLoaded || !d.friends || !d.friends.length) return
          root.friendGroups = d.groups || []
          root.friends = root.sortFriends(d.friends)
          root.friendsCached = true
          root.friendsLoaded = true
        } catch (e) {}
      }
    }
  }

  Process {
    id: friendsProc
    command: ["python3", root.script, "friends"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.friendsError = d.error || ""
          if (d.friends) {
            if (root.changed("friends", d.friends))
              root.keepScroll(function() { root.friends = d.friends; root.friendGroups = d.groups || [] })
            root.friendsCached = false
          }
        } catch (e) {
          root.friendsError = "Couldn't load friends"
        }
        root.friendsLoaded = true
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓓"
    tooltipText: root.activeDownload
      ? root.activeDownload.name + " · " + (root.activeDownload.status === "downloading" && root.activeDownload.total
          ? Math.floor(root.activeDownload.progress * 100) + "% · " + root.downloadLine(root.activeDownload)
          : root.downloadLine(root.activeDownload))
      : root.lastInstalled ? "Steam · last played " + root.lastInstalled.name : "Steam"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) Quickshell.execDetached(steamCommand)
      else if (buttonCode === Qt.MiddleButton && root.lastInstalled) root.launch("steam://rungameid/" + root.lastInstalled.appid)
      else { root.reopenUntil = 0; root.toggle() }
    }
  }

  // Unread Steam chats: a small dot on the icon.
  Rectangle {
    visible: root.unreadTotal > 0
    width: Style.space(6)
    height: width
    radius: width / 2
    color: root.onlineColor
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: Style.space(3)
    anchors.topMargin: Style.space(4)
  }

  // Thin progress line under the icon while something downloads.
  Rectangle {
    visible: !!root.activeDownload
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(2)
    width: Style.space(16)
    height: Style.space(2)
    radius: height / 2
    color: Util.alpha(root.foreground, 0.25)

    Rectangle {
      width: parent.width * barGlide.value
      height: parent.height
      radius: parent.radius
      color: root.foreground
    }

    ProgressGlide { id: barGlide; download: root.activeDownload; active: parent.visible }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // The chat and store panes widen the popup beside the list.
    contentWidth: root.listWidth + (root.chatShown ? root.chatWidth : root.storeOpen ? root.storeWidth : 0)
    contentHeight: root.dragHeight >= 0 ? root.dragHeight : root.savedSize("panelHeight", Style.space(500), root.minHeight)

    ResizeGrip { side: "left"; anchors.left: parent.left; anchors.bottom: parent.bottom; z: 20 }
    ResizeGrip { side: "right"; anchors.right: parent.right; anchors.bottom: parent.bottom; z: 20 }

    // The side borders resize the width too; they sit mostly in the
    // popup's padding so they don't take clicks from what's inside.
    ResizeGrip {
      side: "left"
      edge: true
      anchors.left: parent.left
      anchors.leftMargin: -panel.padding
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(18)
      width: panel.padding + Style.space(3)
      height: undefined
      z: 19
    }
    ResizeGrip {
      side: "right"
      edge: true
      anchors.right: parent.right
      anchors.rightMargin: -panel.padding
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(18)
      width: panel.padding + Style.space(3)
      height: undefined
      z: 19
    }

    // Panel view: a game's options (play, stream, install, store page...).
    ModalScrim {
      id: optionsOverlay
      z: 49
      shown: !!root.gameOptions
      contentHeight: optionsCol.implicitHeight
      onDismissed: root.closeGameOptions()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.closeGameOptions(); event.accepted = true }
      }

      readonly property var game: root.gameOptions
      readonly property var download: game ? root.downloadsById[game.appid] || null : null
      readonly property var streamFrom: !game ? [] : game.streamDevice ? [game.streamDevice] : root.streamable(game) ? root.streamDevices(game) : []

      Flickable {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        contentHeight: optionsCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: optionsCol
          width: parent.width
          spacing: Style.space(6)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            ClippingRectangle {
              Layout.preferredWidth: Style.space(36)
              Layout.preferredHeight: Style.space(36)
              radius: Style.space(5)
              color: Util.alpha(root.foreground, 0.08)

              Image {
                anchors.fill: parent
                source: root.gameOptions ? root.imageSource(root.gameOptions.icon) : ""
                sourceSize.width: 72
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(1)

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.gameOptions ? root.gameOptions.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: !root.gameOptions ? "" : [
                    root.gameOptions.installed ? "Installed" : optionsOverlay.streamFrom.length ? "On " + optionsOverlay.streamFrom[0].name : "Not installed",
                    root.playtimeLabel(root.gameOptions.playtime) ? root.playtimeLabel(root.gameOptions.playtime) + " played" : ""
                  ].filter(function(x) { return x !== "" }).join(" · ")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          GameAction {
            visible: !!root.gameOptions && root.gameOptions.installed
            icon: "󰐊"
            label: "Play"
            onClicked: root.withOptionsGame(function(g) { root.launch("steam://rungameid/" + g.appid) })
          }

          Repeater {
            model: optionsOverlay.streamFrom
            GameAction {
              required property var modelData
              icon: "󰍹"
              label: "Stream from " + modelData.name
              onClicked: root.withOptionsGame(function(g) { root.pendingStream = { device: modelData, game: g }; root.confirmStream() })
            }
          }

          GameAction {
            visible: !!optionsOverlay.download
            icon: optionsOverlay.download && optionsOverlay.download.status === "paused" ? "󰐊" : "󰏤"
            label: optionsOverlay.download && optionsOverlay.download.status === "paused" ? "Resume download" : "Pause download"
            onClicked: root.toggleDownload(optionsOverlay.download)
          }

          Repeater {
            model: root.gameOptions && !root.gameOptions.installed && !optionsOverlay.download ? root.folders : []
            GameAction {
              required property var modelData
              icon: "󰇚"
              label: "Install to " + root.folderName(modelData) + " · " + root.sizeLabel(modelData.free) + " free"
              onClicked: root.withOptionsGame(function(g) { root.installGame(g, modelData) })
            }
          }

          GameAction {
            visible: !!root.gameOptions && !root.gameOptions.installed && !optionsOverlay.download && root.folders.length === 0
            icon: "󰇚"
            label: "Install"
            onClicked: root.withOptionsGame(function(g) { root.installGame(g, null) })
          }

          GameAction {
            icon: "󰓜"
            label: "Store page"
            onClicked: root.withOptionsGame(root.openStore)
          }

          GameAction {
            icon: "󰓓"
            label: "Open in Steam"
            onClicked: root.withOptionsGame(function(g) { root.launch("steam://nav/games/details/" + g.appid) })
          }

          GameAction {
            icon: "󰒓"
            label: "Properties"
            onClicked: root.withOptionsGame(function(g) { root.launch("steam://gameproperties/" + g.appid) })
          }

          GameAction {
            visible: !!root.gameOptions && root.gameOptions.installed && root.controllable
            icon: "󰆴"
            label: root.uninstallArmed ? "Click again to uninstall" : "Uninstall"
            danger: root.uninstallArmed
            onClicked: {
              if (!root.uninstallArmed) { root.uninstallArmed = true; return }
              root.withOptionsGame(root.uninstallGame)
            }
          }

          GameAction {
            icon: "󰅖"
            label: "Cancel"
            onClicked: root.closeGameOptions()
          }
        }
      }
    }

    // Asks before Remote Play starts (a computer's desktop or a game).
    ModalScrim {
      z: 50
      shown: !!root.pendingStream
      contentHeight: dialogCol.implicitHeight
      onDismissed: root.cancelStream()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.confirmStream()
        else if (event.key === Qt.Key_Escape) root.cancelStream()
        else return
        event.accepted = true
      }

      ColumnLayout {
        id: dialogCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(14)
        spacing: Style.space(8)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: !root.pendingStream ? "" : root.pendingStream.game
            ? "Stream " + root.pendingStream.game.name + "?"
            : "Remote Play " + root.pendingStream.device.name + "?"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          wrapMode: Text.Wrap
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: !root.pendingStream ? "" : root.pendingStream.game
            ? "Starts it on " + root.pendingStream.device.name + " and streams it here."
            : "Streams " + root.pendingStream.device.name + "'s desktop here."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(4)
          spacing: Style.space(8)

          Item { Layout.fillWidth: true }

          Button {
            text: "Cancel"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.cancelStream()
          }

          Button {
            text: "Start"
            iconText: "󰐊"
            bordered: true
            selected: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.confirmStream()
          }
        }
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: filterField.activeFocus || chatView.inputFocused || apiKeyField.activeFocus || driveField.activeFocus || !!root.pendingStream
        || !!root.gameOptions
      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.storeOpen) root.stepMedia(dx)
        else if (dx !== 0) root.switchTab(dx)
        else root.moveRow(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateRow(root.rows[root.rowIndex])
      onCloseRequested: {
        if (root.storeOpen) { root.closeStore(); return }
        root.reopenUntil = 0
        root.close()
      }
      onDeleteRequested: root.uninstallSelected()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") root.focusFilter()
        else if (/^[1-9]$/.test(t) && Number(t) <= root.tabOrder.length) root.tab = root.tabOrder[Number(t) - 1]
        else if (Number(t) === root.tabOrder.length + 1 || t === ",") root.tab = "settings"
        else if (t === "i" && root.tab !== "friends" && root.tab !== "groups" && root.cursorActive) {
          if (root.storeOpen) root.closeStore(); else root.openStore(root.rows[root.rowIndex])
        }
        else if (t === "d" && root.downloads.length) root.downloadsExpanded = !root.downloadsExpanded
        else if (t === "r") { root.refreshGames(); root.refreshFriends(); root.refreshStoreLists() }
      }

      // ---------- tab rail ----------
      // Down the left edge or across the top (Settings). Drag a tab to move
      // it; the order is saved and the first tab opens with the popup.
      Grid {
        id: rail
        anchors.left: parent.left
        // Across the top it sits in its slot under the header.
        y: root.railTop ? listPane.y + railSlot.y : 0
        // Across the top the logo moves to the header line, beside the title.
        columns: root.railTop ? root.tabOrder.length + 1 : 1
        spacing: Style.space(4)
        readonly property real tabWidth: root.railTop
          ? (root.listWidth - panel.padding * 2 - spacing * root.tabOrder.length) / (root.tabOrder.length + 1)
          : root.railWidth
        readonly property real tabHeight: root.railTop ? Style.space(48) : Style.space(54)
        readonly property real step: (root.railTop ? tabWidth : tabHeight) + spacing
        // While a tab is dragged: where it came from and where it would land.
        property int dragFrom: -1
        property int dragTo: -1

        Text {
          id: logo
          visible: !root.railTop
          width: root.railWidth
          height: Style.space(56)
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: "󰓓"
          color: logoMouse.containsMouse ? root.onlineColor : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display

          // Click the logo to open Steam.
          MouseArea {
            id: logoMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.launch("steam://open/main")
          }
          ToolTip.visible: logoMouse.containsMouse
          ToolTip.delay: 400
          ToolTip.text: "Open Steam"
        }

        Repeater {
          model: root.tabOrder

          Item {
            id: slot
            required property string modelData
            required property int index
            width: rail.tabWidth
            height: rail.tabHeight
            z: railTab.dragging ? 10 : 0
            // The other tabs slide aside to show where the dragged one would go.
            readonly property int shift: rail.dragFrom < 0 || index === rail.dragFrom ? 0
              : rail.dragFrom < index && index <= rail.dragTo ? -1
              : rail.dragTo <= index && index < rail.dragFrom ? 1 : 0

            RailTab {
              id: railTab
              width: parent.width
              height: parent.height
              tabName: slot.modelData
              tabIndex: slot.index
              draggable: true
              host: rail
              x: root.railTop ? (dragging ? dragOffset : slot.shift * rail.step) : 0
              y: root.railTop ? 0 : (dragging ? dragOffset : slot.shift * rail.step)
              Behavior on x { enabled: !railTab.dragging; NumberAnimation { duration: 120 } }
              Behavior on y { enabled: !railTab.dragging; NumberAnimation { duration: 120 } }
            }
          }
        }

        RailTab {
          width: rail.tabWidth
          height: rail.tabHeight
          tabName: "settings"
          tabIndex: -1
          draggable: false
          host: rail
        }
      }

      Rectangle {
        visible: !root.railTop
        x: rail.width + Style.space(8)
        width: 1
        height: parent.height
        color: Util.alpha(root.foreground, 0.12)
      }

      ColumnLayout {
        id: listPane
        anchors.left: root.railTop ? parent.left : rail.right
        anchors.leftMargin: root.railTop ? 0 : Style.space(17)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.railTop ? root.listWidth - panel.padding * 2
          : root.listWidth - root.railWidth - Style.space(17) - panel.padding * 2
        spacing: Style.space(10)

        // ---------- header (lines up with the rail's logo) ----------
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(56)

          Text {
            id: headerLogo
            visible: root.railTop
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰓓"
            color: headerLogoMouse.containsMouse ? root.onlineColor : root.foreground
            font.family: root.fontFamily
            // As tall as the title and the line under it.
            font.pixelSize: headerText.implicitHeight * 0.95

            MouseArea {
              id: headerLogoMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.launch("steam://open/main")
            }
            ToolTip.visible: headerLogoMouse.containsMouse
            ToolTip.delay: 400
            ToolTip.text: "Open Steam"
          }

          Column {
            id: headerText
            anchors.left: headerLogo.visible ? headerLogo.right : parent.left
            anchors.leftMargin: headerLogo.visible ? Style.space(14) : 0
            anchors.right: degradedButton.visible ? degradedButton.left : parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: root.tabInfo[root.tab] ? root.tabInfo[root.tab].label : "Steam"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            SectionLabel {
              width: parent.width
              text: (root.games.length + " GAMES") + (root.friendsLoaded ? " · " + root.friendsOnline + " FRIENDS ONLINE" : "")
                + (root.friendsCached && root.tab === "friends" ? " · UPDATING" : "")
              elide: Text.ElideRight
            }
          }

          ActionButton {
            id: degradedButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.degraded
            iconText: "󰀦"
            tooltipText: "Some features are limited"
            foreground: root.warnColor
            fontSize: Style.font.body
            onClicked: root.degradedOpen = !root.degradedOpen
          }
        }

        // With the tabs across the top: the header, a line, the tabs (placed
        // in this slot), another line, then the tab's content.
        Rectangle {
          Layout.fillWidth: true
          Layout.topMargin: -Style.space(4)
          visible: root.railTop
          implicitHeight: 1
          color: Util.alpha(root.foreground, 0.12)
        }

        Item {
          id: railSlot
          Layout.fillWidth: true
          visible: root.railTop
          implicitHeight: rail.height
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.bottomMargin: Style.space(2)
          visible: root.railTop
          implicitHeight: 1
          color: Util.alpha(root.foreground, 0.12)
        }

        DebugNotice {
          Layout.fillWidth: true
          visible: root.degraded && root.degradedOpen && root.tab !== "settings"
        }

        ButtonGroup {
          Layout.fillWidth: true
          visible: root.tab === "store"
          focusable: false
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          value: root.storeKind
          options: [
            { value: "top", label: "Top Sellers" },
            { value: "upcoming", label: "Upcoming" },
            { value: "new", label: "New Releases" }
          ]
          onChanged: function(v) { root.storeKind = v }
        }

        // ---------- library filters: one line of chips ----------
        // The options as icons (names on hover), then, with other computers
        // to stream from, a chip per computer: click to show only its games
        // (again for all). The wheel scrolls the line sideways if it doesn't fit.
        Flickable {
          id: chipScroll
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          visible: root.tab === "library"
          clip: true
          contentWidth: chipLine.implicitWidth
          contentHeight: height
          flickableDirection: Flickable.HorizontalFlick
          boundsBehavior: Flickable.StopAtBounds

          WheelHandler {
            onWheel: function(event) {
              var d = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
              chipScroll.contentX = Math.max(0, Math.min(chipScroll.contentWidth - chipScroll.width, chipScroll.contentX - d / 2))
            }
          }

          Row {
            id: chipLine
            spacing: Style.space(5)

            FilterChip {
              icon: root.libraryPanels ? "󰕰" : "󰈚"
              tip: root.libraryPanels ? "Panel view (click for the list)" : "List view (click for panels)"
              selected: root.libraryPanels
              onClicked: root.savePref("libraryView", root.libraryPanels ? "list" : "panels")
            }

            FilterChip {
              icon: "󰄲"
              tip: "Installed"
              selected: root.installedOnly
              onClicked: { root.installedOnly = !root.installedOnly; if (root.installedOnly) root.uninstalledOnly = false }
            }

            FilterChip {
              icon: "󰇚"
              tip: "Uninstalled"
              selected: root.uninstalledOnly
              onClicked: { root.uninstalledOnly = !root.uninstalledOnly; if (root.uninstalledOnly) root.installedOnly = false }
            }

            FilterChip {
              icon: "󰔟"
              tip: "Most played first"
              selected: root.mostPlayed
              onClicked: root.mostPlayed = !root.mostPlayed
            }

            FilterChip {
              visible: root.hasStreams
              icon: "󰙅"
              tip: "Group by computer"
              selected: root.groupByPc
              onClicked: root.savePref("groupByPc", !root.groupByPc)
            }

            Rectangle {
              visible: root.hasStreams
              width: 1
              height: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              color: Util.alpha(root.foreground, 0.2)
            }

            FilterChip {
              visible: root.hasStreams
              icon: "󰌢"
              tip: "This PC · " + root.pcCounts.local + " installed"
              selected: root.libraryPc === "local"
              onClicked: root.pickPc(root.libraryPc === "local" ? "" : "local")
            }

            Repeater {
              model: root.hasStreams ? root.remoteDevices : []

              FilterChip {
                required property var modelData
                readonly property int count: root.pcCounts[modelData.id] || 0
                icon: "󰍹"
                label: modelData.name
                labelMax: Style.space(84)
                tip: modelData.name + " · " + count + " games to stream"
                selected: root.libraryPc === modelData.id
                onClicked: root.pickPc(root.libraryPc === modelData.id ? "" : modelData.id)
              }
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.tab === "library" || root.tab === "friends" || (root.tab === "groups" && root.groupChats.length > 0)
          spacing: Style.space(6)

          TextField {
            id: filterField
            Layout.fillWidth: true
            placeholderText: root.tab === "friends" ? "Search " + root.friends.length + " friends  (/)"
              : root.tab === "groups" ? "Search " + root.groupChats.length + " group chats  (/)"
              : "Search " + root.games.length + " games  (/)"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            onTextEdited: root.filterText = text
            onVisibleChanged: if (!visible && activeFocus) keyCatcher.forceActiveFocus()
  
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (text !== "") { text = ""; root.filterText = "" }
                else root.close()
                event.accepted = true
              } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                keyCatcher.forceActiveFocus()
                root.cursorActive = true
                root.rowIndex = 0
                if (event.key !== Qt.Key_Down && root.rows.length) root.activateRow(root.rows[0])
                event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                keyCatcher.forceActiveFocus()
                root.switchPanel(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
                event.accepted = true
              }
            }
          }

        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          textFormat: Text.PlainText
          text: root.tab === "settings" ? ""
            : root.tab === "friends" ? root.friendsError
            : root.tab === "store" ? (root.actionError || (root.storeLists[root.storeKind] || {}).error || root.storeLists.error || "")
            : (root.actionError || root.errorText)
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------- downloads ----------
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.tab !== "friends" && root.tab !== "groups" && root.tab !== "settings" && root.downloads.length > 0
          spacing: Style.space(6)

          // Header doubles as the toggle; folded, it keeps a one-line summary.
          Item {
            Layout.fillWidth: true
            implicitHeight: dlHeader.implicitHeight

            RowLayout {
              id: dlHeader
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "DOWNLOADS" + (root.downloads.length > 1 ? " · " + root.downloads.length : "")
                foreground: dlToggle.containsMouse ? Qt.lighter(root.foreground, 1.2) : root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                Layout.fillWidth: true
                visible: !root.downloadsExpanded
                textFormat: Text.PlainText
                text: {
                  var d = root.activeDownload || root.downloads[0]
                  return d ? d.name + " · " + root.downloadLine(d) : ""
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Item { Layout.fillWidth: true; visible: root.downloadsExpanded }

              Text {
                text: root.downloadsExpanded ? "󰅀" : "󰅂"
                color: dlToggle.containsMouse ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              id: dlToggle
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.downloadsExpanded = !root.downloadsExpanded
            }

            PanelToolTip {
              visible: dlToggle.containsMouse
              text: root.downloadsExpanded ? "Collapse downloads (d)" : "Show downloads (d)"
            }
          }

          Repeater {
            model: root.downloadsExpanded ? root.downloads.slice(0, 3) : []
            DownloadRow {
              required property var modelData
              Layout.fillWidth: true
              download: modelData
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.downloadsExpanded && root.downloads.length > 3
            textFormat: Text.PlainText
            text: "and " + (root.downloads.length - 3) + " more in the queue"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            leftPadding: Style.space(6)
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }
        }

        // ---------- settings ----------
        Flickable {
          id: settingsView
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.tab === "settings"
          clip: true
          contentWidth: width
          contentHeight: settingsCol.implicitHeight + Style.space(12)
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { id: settingsBar; policy: ScrollBar.AsNeeded }
          property bool showKey: false
          property string keyStatus: ""
          property bool cacheCleared: false
          onVisibleChanged: if (visible) {
            apiKeyField.text = root.apiKey
            driveField.text = root.installDrive
            keyStatus = ""
            showKey = false
            cacheCleared = false
          }

          function saveKey() {
            var key = apiKeyField.text.trim()
            if (key === "") { root.savePref("apiKey", ""); keyStatus = "Key removed."; return }
            if (!/^[0-9A-Fa-f]{32}$/.test(key)) { keyStatus = "That doesn't look like a key: it should be 32 letters and numbers (0-9, A-F)."; return }
            root.savePref("apiKey", key.toUpperCase())
            keyStatus = "Saved."
            root.refreshFriends()
          }

          ColumnLayout {
            id: settingsCol
            width: settingsView.width - (settingsView.contentHeight > settingsView.height ? settingsBar.width + Style.space(4) : 0)
            spacing: Style.space(8)

            // ----- Steam Web API key -----
            SettingsHeader { text: "Steam Web API key"; first: true }

            SettingsNote {
              text: root.controllable
                ? "Optional while Steam's debugging port is on, since friends then come straight from Steam. Used when the port is off: your exact friend list and status in one quick request instead of reading each friend's public profile."
                : "Gets your exact friend list and status in one quick request, instead of reading each friend's public profile a few at a time."
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.StyledText
              text: "1. Open <a href=\"https://steamcommunity.com/dev/apikey\">steamcommunity.com/dev/apikey</a> and sign in.<br>"
                + "2. Enter any domain name (<i>localhost</i> is fine), agree to the terms and click <b>Register</b>.<br>"
                + "3. Copy the key it shows and paste it below."
              color: root.foreground
              linkColor: root.onlineColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              lineHeight: 1.15
              onLinkActivated: function(link) { Qt.openUrlExternally(link) }
              HoverHandler { cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              TextField {
                id: apiKeyField
                Layout.fillWidth: true
                placeholderText: "Paste your key"
                echoMode: settingsView.showKey ? TextInput.Normal : TextInput.Password
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                onAccepted: settingsView.saveKey()
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }

              ActionButton {
                iconText: settingsView.showKey ? "󰈉" : "󰈈"
                tooltipText: settingsView.showKey ? "Hide the key" : "Show the key"
                foreground: root.dim
                fontSize: Style.font.body
                onClicked: settingsView.showKey = !settingsView.showKey
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                text: "Save"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: settingsView.saveKey()
              }

              Button {
                visible: root.apiKey !== ""
                text: "Remove"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: { apiKeyField.text = ""; settingsView.saveKey() }
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: settingsView.keyStatus !== "" ? settingsView.keyStatus : root.apiKey !== "" ? "A key is saved." : "No key saved."
                color: /look like/.test(settingsView.keyStatus) ? root.dangerColor : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }

            SettingsNote { text: "Keep it private: it's saved in ~/.config/omarchy/shell.json with this widget's other settings." }

            // ----- Steam control -----
            SettingsHeader { text: "Steam control" }

            SettingsNote {
              visible: root.controllable
              text: "Connected through Steam's debugging port: live friends, groups and chat, and installing, pausing and resuming from here. While it's on, any program on this computer can control Steam through localhost:8080."
            }

            DebugNotice {
              Layout.fillWidth: true
              visible: !root.controllable
              closable: false
            }

            // ----- layout -----
            SettingsHeader { text: "Layout" }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              Text {
                text: "Menu"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              ButtonGroup {
                Layout.fillWidth: true
                focusable: false
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                value: root.railTop ? "top" : "left"
                options: [
                  { value: "left", label: "On the left" },
                  { value: "top", label: "Across the top" }
                ]
                onChanged: function(v) { root.savePref("menuPosition", v) }
              }
            }

            SettingsToggle {
              label: "Open on the first tab"
              checked: root.openFirstTab
              onToggled: root.savePref("openFirstTab", !root.openFirstTab)
            }

            SettingsNote {
              text: "Drag the tabs in the menu to reorder them" + (root.openFirstTab ? "; the first one opens when you open Steam." : ". Off, it opens where you left it.")
                + " Now: " + root.tabOrder.map(function(t) { return root.tabInfo[t].label }).join(" · ")
            }

            Button {
              visible: root.tabOrder.join() !== root.allTabs.join()
              text: "Reset tab order"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.savePref("tabOrder", root.allTabs)
            }

            // ----- library -----
            SettingsHeader { text: "Library" }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                text: "Games in Recent"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              ActionButton {
                iconText: "󰍴"
                tooltipText: "Fewer"
                onClicked: root.savePref("recentCount", Math.max(3, root.recentCount - 1))
              }

              Text {
                Layout.preferredWidth: Style.space(24)
                horizontalAlignment: Text.AlignHCenter
                text: root.recentCount
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              ActionButton {
                iconText: "󰐕"
                tooltipText: "More"
                onClicked: root.savePref("recentCount", Math.min(30, root.recentCount + 1))
              }
            }

            SettingsToggle {
              label: "Start with Installed ticked"
              checked: root.installedByDefault
              onToggled: { root.savePref("installedByDefault", !root.installedByDefault) }
            }

            Text {
              text: "Install new games to"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: driveField
              Layout.fillWidth: true
              placeholderText: "Steam's default folder"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              onEditingFinished: if (text.trim() !== root.installDrive) root.savePref("installDrive", text.trim())
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }

            SettingsNote {
              text: "Part of a Steam library folder's path, e.g. GAMES for /run/media/you/GAMES/SteamLibrary."
                + (root.folders.length ? " Yours: " + root.folders.map(function(f) { return f.path }).join(", ") : "")
            }

            // ----- friends and chat -----
            SettingsHeader { text: "Friends and chat" }

            SettingsToggle {
              label: "Show offline friends"
              checked: root.showOfflineFriends
              onToggled: root.savePref("showOfflineFriends", !root.showOfflineFriends)
            }

            SettingsToggle {
              label: "Show Steam names beside nicknames"
              checked: root.showSteamNames
              onToggled: root.savePref("showSteamNames", !root.showSteamNames)
            }

            SettingsToggle {
              label: "Show the time on each message"
              checked: root.showMessageTimes
              onToggled: root.savePref("showMessageTimes", !root.showMessageTimes)
            }

            Text {
              Layout.topMargin: Style.space(4)
              text: "Groups shown as icons"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            SettingsNote {
              text: root.friendGroups.length
                ? "Each shown in its place in the list as a row of avatars with what they're playing. Click one to chat. The box on a group's header does the same."
                : "Needs Steam's debugging port: your friend groups come from the running client."
            }

            Flow {
              Layout.fillWidth: true
              visible: root.friendGroups.length > 0
              spacing: Style.space(6)

              Repeater {
                model: root.friendGroups

                Button {
                  required property var modelData
                  text: modelData.name
                  bordered: true
                  selected: root.iconGroups.indexOf(modelData.id) >= 0
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.toggleIconGroup(modelData.id)
                }
              }
            }

            // ----- cache -----
            SettingsHeader { text: "Cache" }

            SettingsNote {
              text: "The last friend list (shown while the live one loads), store lists and pages, and details looked up for shared links, in ~/.cache/blip-steam."
            }

            RowLayout {
              spacing: Style.space(8)

              Button {
                text: "Clear cached data"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: {
                  Quickshell.execDetached(["python3", root.script, "clear-cache"])
                  settingsView.cacheCleared = true
                }
              }

              Text {
                visible: settingsView.cacheCleared
                text: "Cleared"
                color: root.onlineColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // ----- about -----
            SettingsHeader { text: "About" }

            Text {
              Layout.fillWidth: true
              textFormat: Text.StyledText
              text: "Steam for Omarchy · <a href=\"https://github.com/BlippyOhNo/omarchy-steambar\">github.com/BlippyOhNo/omarchy-steambar</a>"
              color: root.dim
              linkColor: root.onlineColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              onLinkActivated: function(link) { Qt.openUrlExternally(link) }
              HoverHandler { cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor }
            }
          }
        }

        ListView {
          id: list
          visible: root.tab !== "settings"
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          model: root.rows
          ScrollBar.vertical: ScrollBar { id: listBar; policy: ScrollBar.AsNeeded }

          delegate: Loader {
            required property var modelData
            required property int index
            // Leave a gutter for the scrollbar so it doesn't sit on the row's buttons.
            width: list.width - (list.contentHeight > list.height ? listBar.width + Style.space(2) : 0)
            sourceComponent: root.tab === "friends" ? (modelData && modelData.isIconBar ? friendIconBar : friendRow)
              : root.tab === "groups" ? groupRow
              : root.tab === "store" ? storeRow : modelData && modelData.isHeader ? libraryHeader
              : modelData && modelData.isDevice ? deviceRow : modelData && modelData.isDeviceBar ? deviceBar
              : modelData && modelData.isGameGrid ? gameGrid : libraryRow
            property var entry: modelData
            property int rowIdx: index
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: root.rows.length === 0
            textFormat: Text.PlainText
            text: root.tab === "groups"
              ? (!root.controllable ? "Group chats need Steam's debugging port (see the ⚠ above)."
                : root.filterText !== "" ? "No group chats match “" + root.filterText + "”" : "No group chats")
              : root.tab === "friends"
              ? (!root.friendsLoaded ? "Checking who's online…"
                : root.filterText !== "" ? "No friends match “" + root.filterText + "”" : "No friends found")
              : root.tab === "store" ? (root.storeListsLoaded ? "Couldn't load the store" : "Loading the Steam store…")
              : !root.gamesLoaded ? "Reading your library…"
              : root.tab === "library" && root.filterText !== "" ? "No games match “" + root.filterText + "”"
              : root.tab === "library" && root.installedOnly && !root.mostPlayed ? "No installed games. Untick Installed to see all " + root.games.length + "."
              : root.tab === "library" && (root.mostPlayed || root.installedOnly || root.uninstalledOnly) ? "No games match these filters"
              : "No games"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }

      // ---------- chat pane ----------
      Item {
        id: chatPane
        visible: root.chatShown
        anchors.left: listPane.right
        anchors.leftMargin: panel.padding * 2
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        Rectangle {
          anchors.right: parent.left
          anchors.rightMargin: panel.padding
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: 1
          color: Util.alpha(root.foreground, chatDivider.containsMouse || chatDivider.pressed ? 0.45 : 0.12)
        }

        PaneDivider {
          id: chatDivider
          pane: "chat"
          anchors.horizontalCenter: parent.left
          anchors.horizontalCenterOffset: -panel.padding
          anchors.top: parent.top
          anchors.bottom: parent.bottom
        }

        ChatView {
          id: chatView
          anchors.fill: parent
          friend: root.chatFriend
          group: root.chatGroup
          active: root.opened && root.chatShown
          onCloseRequested: root.closeChat()
          onPopOutRequested: root.chatGroup ? root.popOutGroup(root.chatGroup) : root.popOutChat(root.chatFriend)
          onTabPressed: keyCatcher.forceActiveFocus()
        }
      }

      // ---------- store pane ----------
      Item {
        id: storePane
        visible: root.storeOpen
        anchors.left: listPane.right
        anchors.leftMargin: panel.padding * 2
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        readonly property var page: root.storePage
        readonly property var current: root.storeMedia.length ? root.storeMedia[Math.min(root.mediaIndex, root.storeMedia.length - 1)] : null

        Rectangle {
          anchors.right: parent.left
          anchors.rightMargin: panel.padding
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: 1
          color: Util.alpha(root.foreground, storeDivider.containsMouse || storeDivider.pressed ? 0.45 : 0.12)
        }

        PaneDivider {
          id: storeDivider
          pane: "store"
          anchors.horizontalCenter: parent.left
          anchors.horizontalCenterOffset: -panel.padding
          anchors.top: parent.top
          anchors.bottom: parent.bottom
        }

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.space(8)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.storeGame && root.storeGame.name ? root.storeGame.name : root.storePage ? root.storePage.name : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            ActionButton {
              iconText: "󰓓"
              tooltipText: "Open store page in Steam"
              foreground: root.dim
              onClicked: root.buyInSteam()
            }

            ActionButton {
              iconText: "󰅖"
              tooltipText: "Close (Esc)"
              onClicked: root.closeStore()
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          Text {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !storePane.page
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.storeError || "Loading store page…"
            color: root.storeError ? root.dangerColor : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Flickable {
            id: storeFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !!storePane.page
            clip: true
            contentWidth: width
            contentHeight: storeContent.implicitHeight + Style.space(12)
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { id: storeBar; policy: ScrollBar.AsNeeded }

            Connections {
              target: root
              function onStoreGameChanged() { storeFlick.contentY = 0 }
            }

            function scrollPage(delta) {
              contentY = Math.max(0, Math.min(contentHeight - height, contentY + delta * height * 0.85))
            }

            Shortcut {
              sequences: [StandardKey.MoveToNextPage]
              enabled: root.storeOpen && root.opened
              onActivated: storeFlick.scrollPage(1)
            }

            Shortcut {
              sequences: [StandardKey.MoveToPreviousPage]
              enabled: root.storeOpen && root.opened
              onActivated: storeFlick.scrollPage(-1)
            }

            ColumnLayout {
              id: storeContent
              width: storeFlick.width - storeBar.width - Style.space(4)
              spacing: Style.space(10)

              // ----- trailers and screenshots -----
              ClippingRectangle {
                id: viewer
                Layout.fillWidth: true
                Layout.preferredHeight: width * 9 / 16
                radius: Style.space(4)
                color: "black"

                readonly property bool isVideo: !!storePane.current && storePane.current.type === "video"

                Image {
                  anchors.fill: parent
                  visible: !viewer.isVideo || trailer.playbackState === MediaPlayer.StoppedState || !trailer.hasVideo
                  source: storePane.current ? (viewer.isVideo ? storePane.current.thumb : storePane.current.src) : ""
                  sourceSize.width: 920
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  cache: true
                }

                Video {
                  id: trailer
                  anchors.fill: parent
                  visible: viewer.isVideo
                  source: viewer.isVideo && root.opened && root.storeOpen ? storePane.current.src : ""
                  muted: root.storeMuted
                  volume: 0.6
                  fillMode: VideoOutput.PreserveAspectFit
                  onSourceChanged: if (source != "") play()
                  onPlaybackStateChanged: if (playbackState === MediaPlayer.StoppedState && position > 0 && duration > 0
                                              && position >= duration - 500) root.stepMedia(1)
                }

                MouseArea {
                  id: viewerMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: viewer.isVideo ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: if (viewer.isVideo) {
                    if (trailer.playbackState === MediaPlayer.PlayingState) trailer.pause(); else trailer.play()
                  }
                }

                Text {
                  anchors.centerIn: parent
                  visible: viewer.isVideo && trailer.playbackState !== MediaPlayer.PlayingState
                  text: "󰐊"
                  color: "white"
                  style: Text.Outline
                  styleColor: Qt.rgba(0, 0, 0, 0.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display * 1.6
                }

                // Hover controls: previous/next and sound.
                Row {
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: Style.space(6)
                  spacing: Style.space(4)
                  visible: viewerMouse.containsMouse || viewerControls.hovered
                  opacity: 0.9
                  HoverHandler { id: viewerControls }

                  Repeater {
                    model: [
                      { icon: "󰒮", tip: "Previous (←)", act: "prev", show: true },
                      { icon: root.storeMuted ? "󰝟" : "󰕾", tip: root.storeMuted ? "Unmute" : "Mute", act: "mute", show: viewer.isVideo },
                      { icon: "󰒭", tip: "Next (→)", act: "next", show: true }
                    ]
                    Rectangle {
                      required property var modelData
                      visible: modelData.show
                      width: Style.space(26)
                      height: Style.space(26)
                      radius: Style.space(4)
                      color: Qt.rgba(0, 0, 0, ctrlMouse.containsMouse ? 0.8 : 0.55)
                      Text {
                        anchors.centerIn: parent
                        text: modelData.icon
                        color: "white"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      MouseArea {
                        id: ctrlMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: modelData.act === "mute" ? root.storeMuted = !root.storeMuted : root.stepMedia(modelData.act === "next" ? 1 : -1)
                      }
                    }
                  }
                }

                Text {
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  anchors.margins: Style.space(8)
                  visible: root.storeMedia.length > 0
                  text: (root.mediaIndex + 1) + " / " + root.storeMedia.length
                  color: "white"
                  style: Text.Outline
                  styleColor: Qt.rgba(0, 0, 0, 0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              ListView {
                id: thumbs
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(46)
                orientation: ListView.Horizontal
                spacing: Style.space(4)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.storeMedia
                currentIndex: root.mediaIndex
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                delegate: ClippingRectangle {
                  required property var modelData
                  required property int index
                  width: Style.space(80)
                  height: Style.space(45)
                  radius: Style.space(3)
                  color: Util.alpha(root.foreground, 0.08)
                  border.width: index === root.mediaIndex ? 2 : 0
                  border.color: root.foreground
                  opacity: index === root.mediaIndex || thumbMouse.containsMouse ? 1 : 0.6

                  Image {
                    anchors.fill: parent
                    anchors.margins: index === root.mediaIndex ? 2 : 0
                    source: modelData.thumb || ""
                    sourceSize.width: 160
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: modelData.type === "video"
                    text: "󰐊"
                    color: "white"
                    style: Text.Outline
                    styleColor: Qt.rgba(0, 0, 0, 0.6)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }

                  MouseArea {
                    id: thumbMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.mediaIndex = index
                  }
                }
              }

              // ----- summary -----
              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: storePane.page ? storePane.page.short : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                lineHeight: 1.15
              }

              GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Style.space(12)
                rowSpacing: Style.space(3)

                Repeater {
                  model: {
                    var p = storePane.page
                    if (!p) return []
                    var out = []
                    if (p.reviews.count) out.push({ k: "ALL REVIEWS", v: root.reviewLine(p.reviews), c: root.reviewColor(p.reviews.percent) })
                    if (p.englishReviews.count && p.englishReviews.count !== p.reviews.count)
                      out.push({ k: "ENGLISH", v: root.reviewLine(p.englishReviews), c: root.reviewColor(p.englishReviews.percent) })
                    if (p.releaseDate) out.push({ k: "RELEASE", v: p.releaseDate + (p.earlyAccess ? " · Early Access" : "") })
                    if (p.developers.length) out.push({ k: "DEVELOPER", v: p.developers.join(", ") })
                    if (p.publishers.length) out.push({ k: "PUBLISHER", v: p.publishers.join(", ") })
                    if (p.deck) out.push({ k: "STEAM DECK", v: p.deck, c: p.deck === "Verified" ? root.inGameColor : p.deck === "Playable" ? "#e0b84c" : root.dim })
                    var os = []
                    if (p.platforms.windows) os.push("Windows")
                    if (p.platforms.mac) os.push("macOS")
                    if (p.platforms.linux) os.push("Linux")
                    if (os.length) out.push({ k: "PLATFORMS", v: os.join(", ") })
                    return out
                  }

                  delegate: Item {
                    required property var modelData
                    required property int index
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    implicitHeight: Math.max(infoKey.implicitHeight, infoValue.implicitHeight)

                    Text {
                      id: infoKey
                      width: Style.space(86)
                      text: modelData.k
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1
                    }

                    Text {
                      id: infoValue
                      anchors.left: infoKey.right
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: modelData.v
                      color: modelData.c || root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }

              Flow {
                Layout.fillWidth: true
                spacing: Style.space(4)
                visible: !!storePane.page && storePane.page.tags.length > 0

                Repeater {
                  model: storePane.page ? storePane.page.tags : []
                  Rectangle {
                    required property string modelData
                    width: tagText.implicitWidth + Style.space(12)
                    height: tagText.implicitHeight + Style.space(6)
                    radius: Style.space(3)
                    color: Util.alpha(root.foreground, 0.08)
                    Text {
                      id: tagText
                      anchors.centerIn: parent
                      text: modelData
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              // ----- buy box -----
              Rectangle {
                Layout.fillWidth: true
                implicitHeight: buyRow.implicitHeight + Style.space(20)
                radius: Style.space(5)
                color: Util.alpha(root.foreground, 0.06)
                visible: !!storePane.page

                RowLayout {
                  id: buyRow
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  spacing: Style.space(8)

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: !storePane.page ? ""
                      : root.storeOwned ? (root.storeOwned.installed ? "Installed" : "In your library")
                      : (storePane.page.comingSoon ? "Coming soon: " : storePane.page.free ? "Play " : "Buy ") + storePane.page.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    wrapMode: Text.WordWrap
                  }

                  Rectangle {
                    visible: !root.storeOwned && !!storePane.page && storePane.page.discount > 0
                    implicitWidth: discountText.implicitWidth + Style.space(10)
                    implicitHeight: discountText.implicitHeight + Style.space(6)
                    color: "#4c6b22"
                    Text {
                      id: discountText
                      anchors.centerIn: parent
                      text: storePane.page ? "−" + storePane.page.discount + "%" : ""
                      color: "#beee11"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                  }

                  ColumnLayout {
                    visible: !root.storeOwned && !!storePane.page && storePane.page.price !== ""
                    spacing: 0
                    Text {
                      Layout.alignment: Qt.AlignRight
                      visible: !!storePane.page && storePane.page.discount > 0 && storePane.page.initialPrice !== ""
                      text: storePane.page ? storePane.page.initialPrice : ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.strikeout: true
                    }
                    Text {
                      Layout.alignment: Qt.AlignRight
                      text: storePane.page ? storePane.page.price : ""
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Rectangle {
                    implicitWidth: buyText.implicitWidth + Style.space(18)
                    implicitHeight: buyText.implicitHeight + Style.space(10)
                    radius: Style.space(3)
                    color: buyMouse.containsMouse ? "#79b82b" : "#5c9a1c"
                    Text {
                      id: buyText
                      anchors.centerIn: parent
                      text: root.storeOwned ? (root.storeOwned.installed ? "󰐊 Play" : "󰇚 Install")
                        : storePane.page && storePane.page.comingSoon ? "Wishlist in Steam"
                        : storePane.page && storePane.page.free ? "Get in Steam" : "Buy in Steam"
                      color: "white"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                    MouseArea {
                      id: buyMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var g = root.storeOwned
                        if (!g) root.buyInSteam()
                        else if (g.installed) root.launch("steam://rungameid/" + g.appid)
                        else root.installGame(g, root.preferredFolder)
                      }
                    }
                  }
                }
              }

              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: {
                  var p = storePane.page
                  if (!p) return ""
                  var bits = []
                  if (p.dlc) bits.push(p.dlc + " DLC")
                  if (p.achievements) bits.push(p.achievements + " achievements")
                  return bits.concat(p.features).join(" · ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // ----- about -----
              PanelSectionHeader {
                visible: !!storePane.page && storePane.page.about.length > 0
                text: "ABOUT THIS GAME"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: storePane.page ? storePane.page.about : []

                delegate: Item {
                  id: block
                  required property var modelData
                  Layout.fillWidth: true
                  implicitHeight: modelData.type === "text" ? aboutText.implicitHeight
                    : modelData.w && modelData.h ? width * modelData.h / modelData.w
                    : aboutImage.status === Image.Ready && aboutImage.sourceSize.width ? width * aboutImage.sourceSize.height / aboutImage.sourceSize.width
                    : Style.space(40)

                  // Description videos loop silently, like the store, while on screen.
                  readonly property bool onScreen: {
                    storeFlick.contentY
                    storeFlick.height
                    var p = block.mapToItem(storeContent, 0, 0)
                    return p.y + height > storeFlick.contentY && p.y < storeFlick.contentY + storeFlick.height
                  }

                  Text {
                    id: aboutText
                    width: parent.width
                    visible: block.modelData.type === "text"
                    textFormat: Text.StyledText
                    text: block.modelData.type === "text" ? block.modelData.text : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    lineHeight: 1.15
                  }

                  AnimatedImage {
                    id: aboutImage
                    anchors.fill: parent
                    visible: block.modelData.type === "image" || (block.modelData.type === "video"
                      && !(videoLoader.item && videoLoader.item.playbackState === MediaPlayer.PlayingState && videoLoader.item.hasVideo))
                    source: block.modelData.type === "image" ? root.imageSource(block.modelData.src)
                      : block.modelData.type === "video" ? root.imageSource(block.modelData.poster) : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true
                    playing: visible && block.onScreen && root.opened
                  }

                  Loader {
                    id: videoLoader
                    anchors.fill: parent
                    active: block.modelData.type === "video" && block.onScreen && root.opened
                    sourceComponent: Video {
                      source: block.modelData.src
                      muted: true
                      loops: MediaPlayer.Infinite
                      fillMode: VideoOutput.PreserveAspectFit
                      Component.onCompleted: play()
                    }
                  }
                }
              }

              // ----- details -----
              PanelSectionHeader {
                visible: !!storePane.page && storePane.page.contentNotes !== ""
                text: "MATURE CONTENT"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: storePane.page ? storePane.page.contentNotes.trim() : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              PanelSectionHeader {
                visible: !!storePane.page && (storePane.page.minimum !== "" || storePane.page.recommended !== "")
                text: "SYSTEM REQUIREMENTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: storePane.page ? [storePane.page.minimum, storePane.page.recommended].filter(function(x) { return !!x }) : []
                Text {
                  required property string modelData
                  Layout.fillWidth: true
                  textFormat: Text.StyledText
                  text: modelData
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              PanelSectionHeader {
                visible: !!storePane.page && storePane.page.languages !== ""
                text: "LANGUAGES"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                Layout.fillWidth: true
                visible: text !== ""
                textFormat: Text.PlainText
                text: storePane.page && storePane.page.languages ? storePane.page.languages
                  + (storePane.page.languages.indexOf("*") >= 0 ? "\n* with full audio" : "") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // ----- reviews -----
              PanelSectionHeader {
                visible: !!storePane.page && storePane.page.topReviews.length > 0
                text: "MOST HELPFUL REVIEWS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: storePane.page ? storePane.page.topReviews : []
                Rectangle {
                  required property var modelData
                  Layout.fillWidth: true
                  implicitHeight: reviewCol.implicitHeight + Style.space(16)
                  radius: Style.space(4)
                  color: Util.alpha(root.foreground, 0.05)

                  ColumnLayout {
                    id: reviewCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(8)
                    spacing: Style.space(4)

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: (modelData.up ? "󰔓 Recommended" : "󰔑 Not Recommended") + "  ·  " + modelData.hours + " hrs on record"
                        + (modelData.helpful ? "  ·  " + modelData.helpful + " found helpful" : "")
                      color: modelData.up ? "#66c0f4" : "#c35c2c"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: modelData.text.replace(/\[\/?[a-z0-9*]+(=[^\]]*)?\]/gi, "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ---------- rows ----------
  // A row of icons (a friend group, a group chat's members, Remote Play)
  // that scrolls sideways when it's longer than the space: the wheel or a
  // touchpad scrolls it (only then, so otherwise the list scrolls), and it
  // drags or flicks by mouse or touch.
  component IconStrip: Item {
    id: strip
    property alias model: lv.model
    property alias delegate: lv.delegate
    readonly property bool overflows: lv.contentWidth > lv.width + 1

    ListView {
      id: lv
      anchors.fill: parent
      orientation: ListView.Horizontal
      spacing: Style.space(6)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.HorizontalFlick
      interactive: strip.overflows
      ScrollBar.horizontal: ScrollBar { policy: strip.overflows ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }
    }

    // A layer on top that takes only the wheel (clicks and hover go
    // through to the icons): items on top get the wheel first, before the
    // ListView, which takes it without moving when it only scrolls sideways.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      onWheel: function(wheel) {
        if (!strip.overflows) { wheel.accepted = false; return }
        var px = wheel.pixelDelta.x !== 0 ? wheel.pixelDelta.x : wheel.pixelDelta.y
        var d = px !== 0 ? px : (wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : wheel.angleDelta.y) / 3
        lv.contentX = Math.max(lv.originX, Math.min(lv.originX + lv.contentWidth - lv.width, lv.contentX - d))
      }
    }
  }

  // A person as an avatar: presence dot, unread dot, the game they're
  // playing in the corner, name and status on hover. Click to chat (or see
  // the profile of someone who isn't a friend).
  component AvatarTile: Item {
    id: tile
    property var person: null
    property bool popout: false
    readonly property bool offline: !!person && (person.state === "offline" || person.state === "unknown")
    width: Style.space(34)
    height: Style.space(38)

    ClippingRectangle {
      anchors.centerIn: parent
      width: Style.space(32)
      height: width
      radius: Style.space(4)
      color: Util.alpha(root.foreground, 0.08)
      opacity: tile.offline ? 0.4 : 1
      border.width: tileMouse.containsMouse ? 1 : 0
      border.color: root.foreground

      Image {
        anchors.fill: parent
        source: tile.person ? tile.person.avatar || "" : ""
        sourceSize.width: 64
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
      }

      // What they're playing, in the corner.
      Image {
        visible: status === Image.Ready
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        width: Style.space(14)
        height: width
        source: root.gameIcon(tile.person)
        sourceSize.width: 32
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
      }
    }

    Dot {
      visible: !tile.offline
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(1)
      color: tile.person ? root.stateColor(tile.person.state) : root.dim
    }

    Dot {
      visible: !!tile.person && (tile.person.unread || 0) > 0
      anchors.right: parent.right
      anchors.top: parent.top
      color: root.inGameColor
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openPerson(tile.person, tile.popout)
    }

    ToolTip.visible: tileMouse.containsMouse
    ToolTip.delay: 300
    ToolTip.text: tile.person ? tile.person.name + " · " + root.friendLine(tile.person) : ""
  }

  // A friend group in icon mode: its friends as one row of avatars, with
  // what they're playing; click one to chat. Scrolls sideways if long.
  Component {
    id: friendIconBar
    Item {
      id: fib
      readonly property var entry: parent ? parent.entry : null
      width: parent ? parent.width : 0
      implicitHeight: Style.space(42)

      IconStrip {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.topMargin: Style.space(2)
        model: fib.entry ? fib.entry.members : []

          delegate: AvatarTile {
            required property var modelData
            person: modelData
          }
      }
    }
  }

  // One option in a game's options: icon and label, full width.
  component GameAction: Rectangle {
    id: ga
    property string icon: ""
    property string label: ""
    property bool danger: false
    signal clicked()
    Layout.fillWidth: true
    implicitHeight: Style.space(30)
    radius: Style.space(5)
    color: Util.alpha(root.foreground, gaMouse.containsMouse ? 0.1 : 0)

    Row {
      anchors.verticalCenter: parent.verticalCenter
      x: Style.space(8)
      spacing: Style.space(10)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16)
        horizontalAlignment: Text.AlignHCenter
        text: ga.icon
        color: ga.danger ? root.dangerColor : root.onlineColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: ga.label
        color: ga.danger ? root.dangerColor : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      id: gaMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: ga.clicked()
    }
  }

  // Panel view: a section's games as icons that wrap to the width.
  Component {
    id: gameGrid
    Item {
      id: gg
      readonly property var entry: parent ? parent.entry : null
      width: parent ? parent.width : 0
      implicitHeight: tileFlow.implicitHeight + Style.space(8)

      Flow {
        id: tileFlow
        x: Style.space(6)
        y: Style.space(4)
        width: gg.width - Style.space(12)
        spacing: Style.space(6)
        // As many columns as fit at the smallest size (worked out with the
        // rows, the same for each), then the covers stretch to fill the width.
        readonly property int columns: gg.entry ? gg.entry.columns : 1
        readonly property real tileWidth: Math.floor((width - spacing * (columns - 1)) / columns)

        Repeater {
          model: gg.entry ? gg.entry.games : []
          GameTile {
            required property var modelData
            game: modelData
            width: tileFlow.tileWidth
          }
        }
      }
    }
  }

  // A game as its portrait cover (as Steam's library grid shows it):
  // dimmed until you can play it here or stream it, a monitor badge when
  // it streams, the download's progress along the bottom. Click for its
  // options. Covers Steam doesn't have fall back to the header art, then
  // the icon.
  component GameTile: Item {
    id: gt
    property var game: null
    property int art: 0
    readonly property var download: game ? root.downloadsById[game.appid] || null : null
    readonly property bool streams: !!game && (!!game.streamDevice || root.streamable(game))
    readonly property bool playable: !!game && (game.installed || streams)
    readonly property var sources: game ? [game.portrait, game.header, game.icon].filter(function(x) { return !!x }) : []
    onGameChanged: art = 0
    width: Style.space(62)
    height: Math.round(width * 1.5)
    // Bigger covers can use sharper art.
    readonly property int artWidth: width > Style.space(90) ? 400 : 200

    ClippingRectangle {
      anchors.fill: parent
      radius: Style.space(6)
      color: Util.alpha(root.foreground, 0.08)
      opacity: gt.playable || gt.download ? 1 : 0.45
      border.width: tileHover.hovered ? 1 : 0
      border.color: root.foreground

      Image {
        anchors.fill: parent
        source: gt.art < gt.sources.length ? root.imageSource(gt.sources[gt.art]) : ""
        sourceSize.width: gt.artWidth
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        onStatusChanged: if (status === Image.Error) gt.art++
      }

      // No art at all: the name.
      Text {
        anchors.fill: parent
        anchors.margins: Style.space(4)
        visible: gt.art >= gt.sources.length
        text: gt.game ? gt.game.name : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      Rectangle {
        visible: !!gt.download && gt.download.total > 0
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        height: Style.space(3)
        width: gt.download ? parent.width * gt.download.progress : 0
        color: root.onlineColor
      }
    }

    Rectangle {
      visible: gt.streams && !(gt.game && gt.game.installed)
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: -Style.space(2)
      width: Style.space(16)
      height: width
      radius: width / 2
      color: Color.background
      border.width: 1
      border.color: root.onlineColor

      Text {
        anchors.centerIn: parent
        text: "󰍹"
        color: root.onlineColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption * 0.8
      }
    }

    HoverHandler { id: tileHover }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.showGameOptions(gt.game)
    }

    ToolTip.visible: tileHover.hovered
    ToolTip.delay: 300
    ToolTip.text: !gt.game ? "" : gt.game.name
      + (gt.game.installed ? " · installed" : gt.streams ? " · stream" : "")
      + (gt.game.playtime ? " · " + root.playtimeLabel(gt.game.playtime) : "")
  }

  // A section header in the library: Remote Play (which minimises, like a
  // friend group) or a computer's games when grouped by computer.
  Component {
    id: libraryHeader
    Item {
      id: lh
      readonly property var entry: parent ? parent.entry : null
      readonly property int entryIdx: parent ? parent.rowIdx : 0
      width: parent ? parent.width : 0
      implicitHeight: headerSurface.height + (entryIdx === 0 ? 0 : Style.space(6))

      RowSurface {
        id: headerSurface
        anchors.bottom: parent.bottom
        rowIdx: lh.entryIdx
        implicitHeight: Style.space(24)

        SectionLabel {
          anchors.fill: parent
          anchors.leftMargin: Style.space(6)
          anchors.rightMargin: Style.space(8)
          verticalAlignment: Text.AlignVCenter
          text: !lh.entry ? ""
            : (lh.entry.collapsible ? (lh.entry.collapsed ? "󰅂 " : "󰅀 ")
              : lh.entry.sectionId === "local" ? "󰌢  " : lh.entry.sectionId === "none" || lh.entry.sectionId === "games" ? "" : "󰍹  ")
              + lh.entry.name.toUpperCase() + "  " + lh.entry.count
          elide: Text.ElideRight
        }

        // Remote Play: show the computers as icons (in place) or as rows.
        FilterTick {
          visible: !!lh.entry && lh.entry.sectionId === "remoteplay"
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          height: parent.height
          label: ""
          checked: root.remotePlayIcons
          ToolTip.visible: remoteIconsHover.hovered
          ToolTip.delay: 300
          ToolTip.text: checked ? "Show as a list" : "Show as icons"
          HoverHandler { id: remoteIconsHover }
          onToggled: root.savePref("remotePlayIcons", !root.remotePlayIcons)
        }
      }
    }
  }

  // Remote Play in icon mode: the computers as a row of icons in the list,
  // sized and spaced like a friend group's avatars (names on hover).
  Component {
    id: deviceBar
    Item {
      id: db
      readonly property var entry: parent ? parent.entry : null
      width: parent ? parent.width : 0
      implicitHeight: Style.space(42)

      IconStrip {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.topMargin: Style.space(2)
        model: db.entry ? db.entry.devices : []

          // A computer: click to Remote Play its desktop.
          delegate: Item {
            id: tile
            required property var modelData
            width: Style.space(34)
            height: Style.space(38)

            Rectangle {
              anchors.centerIn: parent
              width: Style.space(32)
              height: width
              radius: Style.space(4)
              color: Util.alpha(root.foreground, tileMouse.containsMouse ? 0.16 : 0.08)
              border.width: tileMouse.containsMouse ? 1 : 0
              border.color: root.foreground

              Text {
                anchors.centerIn: parent
                text: tileMouse.containsMouse ? "󰐊" : "󰍹"
                color: tileMouse.containsMouse ? root.onlineColor : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Dot {
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(1)
              color: root.onlineColor
            }

            MouseArea {
              id: tileMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.streamDesktop(tile.modelData.device)
            }

            ToolTip.visible: tileMouse.containsMouse
            ToolTip.delay: 300
            ToolTip.text: tile.modelData.device.name + " · Remote Play its desktop · " + tile.modelData.count + " games to stream"
          }
      }
    }
  }

  // A Remote Play computer, like a friend: icon with an online dot, name,
  // and how many of your games it can stream. Click for its desktop.
  Component {
    id: deviceRow
    RowSurface {
      id: dr
      readonly property var entry: parent ? parent.entry : null
      rowIdx: parent ? parent.rowIdx : 0
      implicitHeight: Style.space(44)

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)

        Item {
          Layout.preferredWidth: Style.space(32)
          Layout.preferredHeight: Style.space(32)

          Rectangle {
            anchors.fill: parent
            radius: Style.space(4)
            color: Util.alpha(root.foreground, 0.08)

            Text {
              anchors.centerIn: parent
              text: "󰍹"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Dot {
            size: Style.space(10)
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: -Style.space(2)
            anchors.bottomMargin: -Style.space(2)
            color: root.onlineColor
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: dr.entry ? dr.entry.device.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: dr.entry ? "Online · " + dr.entry.count + " games to stream" : ""
            color: root.onlineColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        ActionButton {
          visible: dr.hasCursor
          iconText: "󰐊"
          tooltipText: dr.entry ? "Remote Play " + dr.entry.device.name + "'s desktop" : ""
          foreground: root.onlineColor
          onClicked: if (dr.entry) root.streamDesktop(dr.entry.device)
        }
      }
    }
  }

  // Library: small icon, name, playtime; uninstalled games are dimmed.
  Component {
    id: libraryRow
    RowSurface {
      id: l
      readonly property var game: parent ? parent.entry : null
      readonly property var download: game ? root.downloadsById[game.appid] || null : null
      // Installed on another computer: stream it from there.
      readonly property var streamFrom: game && game.streamDevice ? [game.streamDevice]
        : root.streamable(game) ? root.streamDevices(game) : []
      readonly property bool showActions: hasCursor && !!game && !game.installed && root.controllable
        && (!download || ["downloading", "paused", "queued", "preparing"].indexOf(download.status) >= 0)
      rowIdx: parent ? parent.rowIdx : 0
      implicitHeight: Style.space(34)

      ProgressLine {
        visible: !!l.download
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(38)
        anchors.rightMargin: Style.space(8)
        anchors.bottomMargin: Style.space(3)
        download: l.download
      }

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)
        opacity: l.game && (l.game.installed || l.download || l.streamFrom.length) ? 1 : 0.6

        Item {
          Layout.preferredWidth: Style.space(22)
          Layout.preferredHeight: Style.space(22)

          ClippingRectangle {
            anchors.fill: parent
            radius: Style.space(3)
            color: Util.alpha(root.foreground, 0.08)
            opacity: l.game && root.uninstalling[l.game.appid] ? 0.4 : 1

            Image {
              anchors.fill: parent
              source: l.game ? root.imageSource(l.game.icon) : ""
              sourceSize.width: 44
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
            }
          }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: l.game ? l.game.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          visible: text !== ""
          text: l.game && root.uninstalling[l.game.appid] ? "Uninstalling…"
            : l.download ? (l.download.status === "paused" ? "Paused" : l.download.total ? Math.floor(l.download.progress * 100) + "%" : "")
            : l.streamFrom.length && !l.showActions ? (l.game.streamDevice ? "Stream" : "Stream · " + l.streamFrom[0].name)
            : l.game ? root.playtimeLabel(l.game.playtime) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        UninstallBadge {
          game: l.game
          rowActive: l.hasCursor
          small: true
        }

        Text {
          visible: !l.showActions
          text: l.streamFrom.length ? "󰍹"
            : l.hasCursor ? (l.game && l.game.installed ? "󰐊" : "󰇚") : (l.game && l.game.installed ? "" : "󰇚")
          Layout.preferredWidth: Style.font.icon
          horizontalAlignment: Text.AlignHCenter
          color: l.hasCursor ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // Hovered and not installed: pause/resume if it's downloading,
        // otherwise one install button per Steam library drive (the
        // preferred one bright).
        ActionButton {
          readonly property bool paused: !!l.download && l.download.status === "paused"
          visible: l.showActions && !!l.download
          iconText: paused ? "󰐊" : "󰏤"
          tooltipText: paused ? "Resume download" : "Pause download"
          onClicked: root.toggleDownload(l.download)
        }

        // Hovered: stream from each computer that has it (the usual one bright)…
        Repeater {
          model: l.showActions && !l.download ? l.streamFrom : []
          ActionButton {
            required property var modelData
            required property int index
            iconText: "󰍹"
            tooltipText: "Stream from " + modelData.name
            foreground: index === 0 ? root.foreground : root.dim
            onClicked: root.streamGame(l.game, modelData)
          }
        }

        // …or install it here.
        Repeater {
          model: l.showActions && !l.download ? root.folders : []
          ActionButton {
            required property var modelData
            readonly property bool preferred: root.preferredFolder && root.preferredFolder.index === modelData.index
            iconText: root.folderName(modelData) === "Home" ? "󰋜" : "󰋊"
            tooltipText: "Install to " + root.folderName(modelData) + " · " + root.sizeLabel(modelData.free) + " free"
            foreground: preferred ? root.foreground : root.dim
            onClicked: root.installGame(l.game, modelData)
          }
        }
      }
    }
  }

  // Store lists: header art, rank, price or release date, or whether you have it.
  // Owned games play/install like library rows; others open their store page.
  Component {
    id: storeRow
    RowSurface {
      id: t
      readonly property var game: parent ? parent.entry : null
      rowIdx: parent ? parent.rowIdx : 0
      implicitHeight: Style.space(58)

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)

        Item {
          Layout.preferredWidth: Style.space(98)
          Layout.preferredHeight: Style.space(46)

          ClippingRectangle {
            anchors.fill: parent
            radius: Style.space(4)
            color: Util.alpha(root.foreground, 0.06)

            Image {
              anchors.fill: parent
              source: t.game ? root.imageSource(t.game.header) : ""
              sourceSize.width: 196
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: t.game ? t.game.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: t.game ? root.storeLine(t.game) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        UninstallBadge {
          game: t.game
          rowActive: t.hasCursor
        }

        Text {
          text: !t.game ? "" : t.game.installed ? "󰐊" : t.game.owned ? "󰇚" : "󰓜"
          color: t.hasCursor ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }
    }
  }

  // Group chats: picture, name, rooms or tagline, and unread messages.
  Component {
    id: groupRow
    RowSurface {
      id: gr
      readonly property var group: parent ? parent.entry : null
      rowIdx: parent ? parent.rowIdx : 0
      current: !!group && !!root.chatGroup && root.chatGroup.id === group.id
      implicitHeight: Style.space(44)

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)

        ClippingRectangle {
          Layout.preferredWidth: Style.space(32)
          Layout.preferredHeight: Style.space(32)
          radius: Style.space(4)
          color: Util.alpha(root.foreground, 0.08)

          Image {
            anchors.fill: parent
            source: gr.group ? gr.group.avatar : ""
            sourceSize.width: 64
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
          }

          Text {
            anchors.centerIn: parent
            visible: !!gr.group && !gr.group.avatar
            text: root.tabInfo.groups.icon
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: gr.group ? gr.group.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: !!gr.group && gr.group.unread > 0
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.groupLine(gr.group)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Rectangle {
          visible: !!gr.group && gr.group.unread > 0
          Layout.preferredHeight: Style.space(16)
          Layout.preferredWidth: Math.max(height, groupUnreadLabel.implicitWidth + Style.space(10))
          radius: height / 2
          color: gr.group && gr.group.mention ? root.warnColor : root.onlineColor

          Text {
            id: groupUnreadLabel
            anchors.centerIn: parent
            text: gr.group ? (gr.group.mention ? "@ " : "") + gr.group.unread : ""
            color: "black"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          visible: gr.hasCursor && !(gr.group && gr.group.unread > 0)
          text: "󰭹"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  // Friends: avatar with a presence dot, name, and what they're doing,
  // under their group's header when they start one.
  Component {
    id: friendRow
    Column {
      id: fc
      readonly property var entry: parent ? parent.entry : null
      readonly property int entryIdx: parent ? parent.rowIdx : 0
      width: parent ? parent.width : 0

      readonly property bool isHeader: !!entry && !!entry.isHeader

      // A group's header: click (or Enter) to minimise or expand it.
      Item {
        width: parent.width
        visible: fc.isHeader
        height: visible ? headerRow.height + (fc.entryIdx === 0 ? 0 : Style.space(6)) : 0

        RowSurface {
          id: headerRow
          anchors.bottom: parent.bottom
          rowIdx: fc.entryIdx
          implicitHeight: Style.space(24)

          SectionLabel {
            anchors.left: parent.left
            anchors.right: iconsTick.visible ? iconsTick.left : parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(8)
            verticalAlignment: Text.AlignVCenter
            text: !fc.isHeader ? "" : (fc.entry.collapsed ? "󰅂 " : "󰅀 ") + fc.entry.name.toUpperCase() + "  " + fc.entry.count
            elide: Text.ElideRight
          }

          // Show this group's friends as an icon bar above the search instead.
          FilterTick {
            id: iconsTick
            visible: fc.isHeader && fc.entry.sectionId !== "online" && fc.entry.sectionId !== "offline"
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height
            label: ""
            checked: fc.isHeader && !!fc.entry.icons
            ToolTip.visible: iconsHover.hovered
            ToolTip.delay: 300
            ToolTip.text: checked ? "Show as a list" : "Show as icons"
            HoverHandler { id: iconsHover }
            onToggled: root.toggleIconGroup(fc.entry.sectionId)
          }
        }
      }

      RowSurface {
        id: f
        visible: !fc.isHeader
        height: visible ? implicitHeight : 0
        readonly property var friend: fc.isHeader ? null : fc.entry
        readonly property bool isOffline: !friend || friend.state === "offline" || friend.state === "unknown"
        rowIdx: fc.entryIdx
        current: !!friend && !!root.chatFriend && root.chatFriend.accountid === friend.accountid
        implicitHeight: Style.space(44)

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(6)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(10)

          Item {
            Layout.preferredWidth: Style.space(32)
            Layout.preferredHeight: Style.space(32)

            ClippingRectangle {
              anchors.fill: parent
              radius: Style.space(4)
              color: Util.alpha(root.foreground, 0.08)
              opacity: f.isOffline ? 0.45 : 1

              Image {
                anchors.fill: parent
                source: f.friend ? f.friend.avatar : ""
                sourceSize.width: 64
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
              }
            }

            Dot {
              size: Style.space(10)
              visible: !f.isOffline
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.rightMargin: -Style.space(2)
              anchors.bottomMargin: -Style.space(2)
              color: f.friend ? root.stateColor(f.friend.state) : root.dim
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(1)

            // Your nickname for them, then their own Steam name. Anchored
            // rather than laid out: a layout sizing to its own width loops.
            Item {
              Layout.fillWidth: true
              implicitHeight: nameLabel.implicitHeight

              Text {
                id: nameLabel
                anchors.left: parent.left
                width: Math.min(implicitWidth, parent.width * (personaLabel.visible ? 0.65 : 1))
                textFormat: Text.PlainText
                text: f.friend ? f.friend.name : ""
                color: f.isOffline ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: !f.isOffline
                elide: Text.ElideRight
              }

              Text {
                id: personaLabel
                anchors.left: nameLabel.right
                anchors.leftMargin: Style.space(6)
                anchors.right: parent.right
                anchors.baseline: nameLabel.baseline
                visible: root.showSteamNames && !!f.friend && !!f.friend.personaName
                textFormat: Text.PlainText
                text: f.friend ? f.friend.personaName || "" : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(5)

              // The game they're playing, kept to the line's height.
              Image {
                id: gameIconImage
                visible: source != "" && status === Image.Ready
                Layout.preferredHeight: Style.space(14)
                Layout.preferredWidth: implicitHeight > 0 ? Style.space(14) * implicitWidth / implicitHeight : 0
                source: root.gameIcon(f.friend)
                sourceSize.height: 32
                fillMode: Image.PreserveAspectFit
                asynchronous: true
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: f.friend ? root.friendLine(f.friend) : ""
                color: f.friend && !f.isOffline ? root.stateColor(f.friend.state) : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          Rectangle {
            visible: !!f.friend && f.friend.unread > 0
            Layout.preferredHeight: Style.space(16)
            Layout.preferredWidth: Math.max(height, unreadLabel.implicitWidth + Style.space(10))
            radius: height / 2
            color: root.onlineColor

            Text {
              id: unreadLabel
              anchors.centerIn: parent
              text: f.friend ? String(f.friend.unread) : ""
              color: "black"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // On hover: open in Steam, or in a chat window of its own.
          ActionButton {
            visible: f.hasCursor && !!f.friend
            iconText: "󰓓"
            tooltipText: "Open in Steam"
            foreground: root.dim
            onClicked: root.launch("steam://friends/message/" + f.friend.steamid)
          }

          ActionButton {
            visible: f.hasCursor && !!f.friend && root.controllable
            iconText: "󰏌"
            tooltipText: "Chat in its own window"
            foreground: root.dim
            onClicked: root.popOutChat(f.friend)
          }

          Text {
            visible: f.hasCursor && !(f.friend && f.friend.unread > 0)
            text: "󰭹"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  // One download: art, name, bytes/speed/time left, and a progress bar.
  // Clicking opens Steam's Downloads page (pause/resume live there).
  component DownloadRow: CursorSurface {
    id: dl
    property var download: null
    foreground: root.foreground
    implicitHeight: dlInner.implicitHeight + Style.space(12)

    MouseArea {
      id: dlMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.launch("steam://open/downloads")
    }
    hasCursor: dlMouse.containsMouse

    RowLayout {
      id: dlInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      ClippingRectangle {
        Layout.preferredWidth: Style.space(72)
        Layout.preferredHeight: Style.space(34)
        radius: Style.space(4)
        color: Util.alpha(root.foreground, 0.06)
        opacity: dl.download && dl.download.status === "paused" ? 0.5 : 1

        Image {
          anchors.fill: parent
          source: dl.download ? root.imageSource(dl.download.header) : ""
          sourceSize.width: 144
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: dl.download ? dl.download.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            visible: !!dl.download && dl.download.total > 0 && dl.download.status !== "queued"
            text: dl.download ? Math.floor(dl.download.progress * 100) + "%" : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        ProgressLine {
          Layout.fillWidth: true
          download: dl.download
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: dl.download ? root.downloadLine(dl.download, false) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            readonly property var d: dl.download
            visible: text !== ""
            text: d && d.status === "downloading" && d.speed > 0 && d.total && root.downloadEta(d) < 30 * 86400 ? root.etaLabel(root.downloadEta(d)).replace(" left", "") : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      ActionButton {
        fontSize: Style.font.icon
        readonly property bool paused: !!dl.download && dl.download.status === "paused"
        visible: !!dl.download && root.controllable
          && ["downloading", "paused", "queued", "preparing"].indexOf(dl.download.status) >= 0
        iconText: paused ? "󰐊" : "󰏤"
        tooltipText: paused ? "Resume download" : "Pause download"
        onClicked: root.toggleDownload(dl.download)
      }
    }
  }

  // Round X that pops out beside the play button while the row is hovered or
  // selected. The first click turns it into a red "Uninstall" pill; clicking
  // that uninstalls. Moving to another row disarms it.
  component UninstallBadge: Item {
    id: badge
    property var game: null
    property bool rowActive: false
    property bool small: false
    readonly property bool armed: !!game && root.armedUninstall === game.appid
    readonly property bool busy: !!game && !!root.uninstalling[game.appid]
    readonly property bool available: !!game && game.installed && root.controllable && !busy
    readonly property bool shown: available && (rowActive || badgeMouse.containsMouse || armed)
    readonly property real size: small ? Style.space(18) : Style.space(22)

    visible: shown
    implicitWidth: pill.width
    implicitHeight: size
    Layout.preferredWidth: pill.width
    Layout.preferredHeight: size

    onShownChanged: if (!shown && armed) root.armedUninstall = 0

    Rectangle {
      id: pill
      height: badge.size
      width: badge.armed ? label.implicitWidth + badge.size : badge.size
      radius: height / 2
      color: badge.armed || badgeMouse.containsMouse ? root.dangerColor : Color.background
      border.width: 1
      border.color: badge.armed || badgeMouse.containsMouse ? root.dangerColor : Util.alpha(root.foreground, 0.35)
      anchors.right: parent.right
      scale: badge.shown ? 1 : 0
      transformOrigin: Item.Right
      Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
      Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 120 } }

      Row {
        anchors.centerIn: parent
        spacing: Style.space(3)

        Text {
          text: "󰅖"
          color: badge.armed || badgeMouse.containsMouse ? "white" : root.foreground
          font.family: root.fontFamily
          font.pixelSize: badge.small ? Style.font.caption : Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: label
          visible: badge.armed
          text: "Uninstall"
          color: "white"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    MouseArea {
      id: badgeMouse
      anchors.fill: pill
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (badge.armed) root.uninstallGame(badge.game)
        else root.armedUninstall = badge.game.appid
      }
    }

    PanelToolTip {
      visible: badgeMouse.containsMouse && !!badge.game
      text: badge.armed ? "Click again to uninstall " + badge.game.name : "Uninstall " + (badge.game ? badge.game.name : "")
    }
  }

  // One chat message: yours on the right, theirs on the left, with a time
  // label over the first of each burst. Unsent messages are dimmed; failed
  // ones get a red outline.
  // A conversation with one friend: header, messages, and a box to write
  // in. Used by the popup's chat pane and by popped-out chat windows; each
  // keeps its own messages and polls Steam while active.
  component ChatView: Item {
    id: cv
    // A friend's chat, or a group chat (one of its rooms, the default first).
    property var friend: null
    property var group: null
    property string roomId: ""
    property bool active: false
    property bool popout: false
    signal closeRequested()
    signal popOutRequested()
    signal tabPressed()

    readonly property string accountid: friend ? String(friend.accountid) : ""
    readonly property string groupId: group ? group.id : ""
    readonly property string currentRoom: group ? (roomId || group.defaultRoom) : ""
    // What steamctl.py calls the chat: an account id, or groupid:roomid.
    readonly property string target: group ? groupId + ":" + currentRoom : accountid
    readonly property var rooms: group ? group.rooms || [] : []
    readonly property string title: group ? group.name : friend ? friend.name : ""
    // A group chat's members (steamctl.py members), online first.
    property var members: []
    property bool membersBusy: false
    readonly property int membersOnline: members.filter(function(m) { return m.state !== "offline" }).length

    function refreshMembers() {
      if (!groupId || membersBusy) return
      membersBusy = true
      var id = groupId
      root.runCtl(["members", id], function(ok, value) {
        cv.membersBusy = false
        if (ok && Array.isArray(value) && cv.groupId === id) cv.members = value
      })
    }

    Timer {
      interval: 15000
      running: cv.active && cv.groupId !== ""
      repeat: true
      onTriggered: cv.refreshMembers()
    }
    readonly property bool inputFocused: chatInput.activeFocus
    onGroupIdChanged: { roomId = ""; members = []; refreshMembers() }
    property var messages: []
    property string signature: ""
    property bool typing: false
    property bool loaded: false
    property string error: ""

    function focusInput() { chatInput.forceActiveFocus() }

    function refresh() {
      if (!target || proc.running) return
      proc.account = target
      proc.command = ["python3", root.ctlScript, "chat", target, "read"]
      proc.running = true
    }

    function send() {
      var text = String(chatInput.text || "").trim()
      if (!text || !target) return
      chatInput.text = ""
      error = ""
      // Shown straight away (dimmed) until Steam's copy comes back.
      messages = messages.concat([{ mine: true, text: text, ts: Date.now() / 1000,
        key: "local:" + Date.now(), pending: true, failed: false, showDay: false }])
      root.runCtl(["send", target], text, function(ok, value, err) {
        if (!ok) cv.error = "Couldn't send: " + err
        cv.refresh()
      })
    }

    // Clicking a reaction under a message adds yours, or takes it back.
    function toggleReaction(message, reaction) {
      if (!target || !message || !reaction) return
      error = ""
      root.runCtl(["react", target, String(message.ts), String(message.ordinal), String(reaction.type),
                   reaction.name, reaction.mine ? "remove" : "add"], function(ok, value, err) {
        if (!ok) cv.error = "Couldn't react: " + err
        cv.refresh()
      })
    }

    onTargetChanged: {
      messages = []
      signature = ""
      loaded = false
      typing = false
      error = ""
      refresh()
    }

    Timer {
      interval: 1500
      running: cv.active && cv.target !== ""
      repeat: true
      onTriggered: cv.refresh()
    }

    Process {
      id: proc
      property string account: ""
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (cv.target !== proc.account) return
          var r = {}
          try { r = JSON.parse(String(text || "{}")) } catch (e) { r = { ok: false, error: "no reply" } }
          if (!r.ok) { cv.error = r.error || "Couldn't load the chat"; return }
          var v = r.value || {}
          cv.typing = !!v.typing
          cv.loaded = true
          var list = v.messages || []
          var sig = JSON.stringify(list)
          if (sig === cv.signature) return
          cv.signature = sig
          // A day label above the first message of each day; in group chats
          // the sender's name above each run of their messages.
          for (var i = 0; i < list.length; i++) {
            list[i].showDay = i === 0 || new Date(list[i].ts * 1000).toDateString() !== new Date(list[i - 1].ts * 1000).toDateString()
            list[i].showSender = !list[i].mine && (list[i].showDay || list[i - 1].accountid !== list[i].accountid)
          }
          cv.messages = list
        }
      }
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(8)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)

        ClippingRectangle {
          Layout.preferredWidth: Style.space(32)
          Layout.preferredHeight: Style.space(32)
          radius: Style.space(4)
          color: Util.alpha(root.foreground, 0.08)

          Image {
            anchors.fill: parent
            source: cv.group ? cv.group.avatar : cv.friend ? cv.friend.avatar : ""
            sourceSize.width: 64
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
          }

          Text {
            anchors.centerIn: parent
            visible: !!cv.group && !cv.group.avatar
            text: root.tabInfo.groups.icon
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: cv.title
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: cv.typing ? "typing…" : cv.group ? root.groupLine(cv.group) : cv.friend ? root.friendLine(cv.friend) : ""
            color: !cv.group && cv.friend && cv.friend.state !== "offline" ? root.stateColor(cv.friend.state) : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        ActionButton {
          iconText: "󰓓"
          tooltipText: "Open in Steam"
          foreground: root.dim
          onClicked: if (cv.group) root.launch("steam://open/friends")
            else if (cv.friend) root.launch("steam://friends/message/" + cv.friend.steamid)
        }

        ActionButton {
          visible: !cv.popout
          iconText: "󰏌"
          tooltipText: "Open in its own window"
          foreground: root.dim
          onClicked: cv.popOutRequested()
        }

        ActionButton {
          iconText: "󰅖"
          tooltipText: cv.popout ? "Close window" : "Close chat (Esc)"
          onClicked: cv.closeRequested()
        }
      }

      // Everyone in the group, as avatars (online first).
      ColumnLayout {
        Layout.fillWidth: true
        visible: !!cv.group && cv.members.length > 0
        spacing: Style.space(2)

        SectionLabel {
          leftPadding: Style.space(2)
          text: "MEMBERS  " + cv.membersOnline + "/" + cv.members.length
        }

        IconStrip {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(42)
          model: cv.members

          delegate: AvatarTile {
            required property var modelData
            person: modelData
            popout: cv.popout
          }
        }
      }

      // A group's rooms, when it has more than one.
      Flow {
        Layout.fillWidth: true
        visible: cv.rooms.length > 1
        spacing: Style.space(6)

        Repeater {
          model: cv.rooms

          Button {
            required property var modelData
            text: "# " + modelData.name + (modelData.unread ? "  " + modelData.unread : "")
            bordered: true
            selected: modelData.id === cv.currentRoom
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: cv.roomId = modelData.id
          }
        }
      }

      PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

      // Newest message at the bottom, like any chat.
      ListView {
        id: chatList
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.space(4)
        verticalLayoutDirection: ListView.BottomToTop
        boundsBehavior: Flickable.StopAtBounds
        model: cv.messages.slice().reverse()
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: ChatBubble {
          required property var modelData
          width: chatList.width
          message: modelData
          popout: cv.popout
          showSender: !!cv.group && !!modelData.showSender
          onReactionClicked: function(reaction) { cv.toggleReaction(modelData, reaction) }
        }

        Text {
          anchors.centerIn: parent
          width: parent.width - Style.space(20)
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          visible: cv.messages.length === 0
          textFormat: Text.PlainText
          text: cv.loaded ? "No recent messages in " + cv.title + ". Say hi!" : "Loading chat…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Text {
        Layout.fillWidth: true
        visible: text !== ""
        textFormat: Text.PlainText
        text: cv.error
        color: root.dangerColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        TextField {
          id: chatInput
          Layout.fillWidth: true
          placeholderText: cv.title ? "Message " + cv.title : ""
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              cv.send()
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              if (text !== "") text = ""
              else cv.closeRequested()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              cv.tabPressed()
              event.accepted = true
            }
          }
        }

        ActionButton {
          iconText: "󰒊"
          tooltipText: "Send (Enter)"
          foreground: chatInput.text.trim() !== "" ? root.onlineColor : root.dim
          fontSize: Style.font.body
          onClicked: { cv.send(); chatInput.forceActiveFocus() }
        }
      }
    }
  }

  component ChatBubble: Item {
    id: cb
    property var message: null
    property bool popout: false
    // Group chats: the sender's name above the first of their messages.
    property bool showSender: false
    readonly property bool mine: !!message && message.mine
    readonly property var cards: message && message.cards ? message.cards : []
    readonly property bool hasText: !!message && (message.html !== undefined ? message.html !== "" : message.text !== "")
    readonly property var reactions: message && message.reactions ? message.reactions : []
    readonly property real padX: Style.space(10)
    readonly property real padY: Style.space(6)
    readonly property real stampGap: Style.space(8)
    // The time sits on the text's line when a one-line message leaves room,
    // otherwise on a line of its own at the bubble's bottom right.
    readonly property bool stampInline: root.showMessageTimes && !cards.length && !!message
      && String(message.html !== undefined ? message.html : message.text).search(/<br>|\n/) < 0
      && msgText.implicitWidth + stampGap + stamp.implicitWidth <= cb.width * 0.82 - padX * 2
    signal reactionClicked(var reaction)
    height: reactionRow.visible ? reactionRow.y + reactionRow.height : bubble.y + bubble.height

    Text {
      id: timeLabel
      visible: !!cb.message && !!cb.message.showDay
      anchors.horizontalCenter: parent.horizontalCenter
      text: cb.message ? root.chatDay(cb.message.ts) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      id: senderRow
      visible: cb.showSender && !cb.mine
      y: timeLabel.visible ? timeLabel.implicitHeight + Style.space(4) : 0
      x: Style.space(2)
      spacing: Style.space(5)

      ClippingRectangle {
        width: Style.space(16)
        height: width
        radius: Style.space(3)
        color: Util.alpha(root.foreground, 0.08)
        anchors.verticalCenter: parent.verticalCenter

        Image {
          anchors.fill: parent
          source: cb.message && cb.message.senderAvatar ? cb.message.senderAvatar : ""
          sourceSize.width: 32
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: cb.message && cb.message.senderName ? cb.message.senderName : ""
        color: root.onlineColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Rectangle {
      id: bubble
      y: (timeLabel.visible ? timeLabel.implicitHeight + Style.space(4) : 0)
        + (senderRow.visible ? senderRow.implicitHeight + Style.space(3) : 0)
      x: cb.mine ? cb.width - width : 0
      // Cards get a fixed width; text alone hugs its words.
      width: cb.cards.length ? Math.min(cb.width * 0.82, Style.space(300))
        : cb.stampInline ? msgText.implicitWidth + cb.stampGap + stamp.implicitWidth + cb.padX * 2
        : Math.min(Math.max(msgText.implicitWidth, stamp.implicitWidth) + cb.padX * 2, cb.width * 0.82)
      height: content.implicitHeight + cb.padY * 2 + (cb.stampInline || !root.showMessageTimes ? 0 : stamp.implicitHeight + Style.space(2))
      radius: Style.space(10)
      color: Util.alpha(root.foreground, cb.mine ? 0.18 : 0.07)
      border.width: cb.message && cb.message.failed ? 1 : 0
      border.color: root.dangerColor
      opacity: cb.message && cb.message.pending ? 0.55 : 1

      Text {
        id: stamp
        visible: root.showMessageTimes
        anchors.right: parent.right
        anchors.rightMargin: cb.padX
        anchors.bottom: parent.bottom
        anchors.bottomMargin: cb.padY
        text: !cb.message ? "" : cb.message.failed ? "not sent" : cb.message.pending ? "sending…" : root.chatTime(cb.message.ts)
        color: cb.message && cb.message.failed ? root.dangerColor : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption * 0.9
      }

      Column {
        id: content
        x: cb.padX
        y: cb.padY
        width: bubble.width - cb.padX * 2 - (cb.stampInline ? cb.stampGap + stamp.implicitWidth : 0)
        spacing: Style.space(6)

        Text {
          id: msgText
          width: parent.width
          visible: cb.hasText
          // steamctl.py sends a StyledText copy with links and emoticons; the
          // local echo of a message you just sent is plain until Steam's arrives.
          textFormat: cb.message && cb.message.html !== undefined ? Text.StyledText : Text.PlainText
          text: !cb.message ? "" : cb.message.html !== undefined ? cb.message.html : cb.message.text
          wrapMode: Text.Wrap
          color: root.foreground
          linkColor: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          onLinkActivated: function(link) { Qt.openUrlExternally(link) }

          HoverHandler {
            cursorShape: msgText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
          }
        }

        Repeater {
          model: cb.cards
          delegate: Column {
            required property var modelData
            width: content.width

            ChatCard {
              visible: ["tag", "video", "youtube"].indexOf(modelData.type) < 0
              width: parent.width
              card: visible ? modelData : null
              popout: cb.popout
            }

            VideoCard {
              visible: modelData.type === "video"
              width: parent.width
              card: visible ? modelData : null
            }

            YouTubeCard {
              visible: modelData.type === "youtube"
              width: parent.width
              card: visible ? modelData : null
            }

            TagCard {
              visible: modelData.type === "tag"
              width: parent.width
              card: visible ? modelData : null
            }
          }
        }
      }
    }

    // Reactions sit under the bubble, on its side; yours are highlighted.
    Flow {
      id: reactionRow
      visible: cb.reactions.length > 0
      y: bubble.y + bubble.height + Style.space(3)
      x: cb.mine ? cb.width - width : Style.space(4)
      width: Math.min(implicitWidth, cb.width * 0.82)
      spacing: Style.space(4)
      layoutDirection: cb.mine ? Qt.RightToLeft : Qt.LeftToRight

      Repeater {
        model: cb.reactions
        delegate: Rectangle {
          id: pill
          required property var modelData
          readonly property string emoticon: String(modelData.name || "").replace(/^:|:$/g, "")
          width: pillRow.implicitWidth + Style.space(12)
          height: Style.space(22)
          radius: height / 2
          color: modelData.mine ? Util.alpha(root.onlineColor, 0.22)
            : Util.alpha(root.foreground, pillMouse.containsMouse ? 0.14 : 0.07)
          border.width: modelData.mine ? 1 : 0
          border.color: root.onlineColor

          Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: Style.space(4)

            Image {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16)
              height: width
              source: "https://steamcommunity-a.akamaihd.net/economy/" + (pill.modelData.type === 1 ? "emoticon/" : "sticker/")
                + encodeURIComponent(pill.emoticon)
              sourceSize.width: 32
              fillMode: Image.PreserveAspectFit
              asynchronous: true
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: String(pill.modelData.count)
              color: pill.modelData.mine ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: pill.modelData.mine
            }
          }

          MouseArea {
            id: pillMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: cb.reactionClicked(pill.modelData)
          }

          ToolTip.visible: pillMouse.containsMouse
          ToolTip.delay: 400
          ToolTip.text: (pill.modelData.mine ? "Take back your " : "React with ") + pill.modelData.name
        }
      }
    }
  }

  // A video shared through Steam: plays in the bubble once you press play
  // (nothing downloads before), or in a window of its own.
  component VideoCard: ClippingRectangle {
    id: vc
    property var card: null
    property bool started: false
    implicitHeight: card ? width * 9 / 16 : 0
    radius: Style.space(6)
    color: "black"

    Loader {
      id: inline
      anchors.fill: parent
      active: vc.started && !!vc.card
      sourceComponent: Video {
        source: vc.card ? vc.card.src : ""
        volume: 0.7
        fillMode: VideoOutput.PreserveAspectFit
        Component.onCompleted: play()
      }
    }

    readonly property var player: inline.item
    readonly property bool playing: !!player && player.playbackState === MediaPlayer.PlayingState

    function toggle() {
      if (!started) { started = true; return }
      if (player) { if (playing) player.pause(); else player.play() }
    }

    MouseArea {
      id: vcMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: vc.toggle()
    }

    Column {
      anchors.centerIn: parent
      visible: !vc.playing
      spacing: Style.space(2)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "󰐊"
        color: "white"
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.display * 1.4
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !vc.started
        text: "VIDEO"
        color: Qt.rgba(1, 1, 1, 0.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }
    }

    // On hover: position and length, sound, and a window of its own.
    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(4)
      spacing: Style.space(4)
      visible: vcMouse.containsMouse || vcControls.hovered
      HoverHandler { id: vcControls }

      Rectangle {
        visible: !!vc.player
        width: timeText.implicitWidth + Style.space(10)
        height: Style.space(20)
        radius: Style.space(4)
        color: Qt.rgba(0, 0, 0, 0.6)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: timeText
          anchors.centerIn: parent
          text: vc.player ? root.mediaTime(vc.player.position) + " / " + root.mediaTime(vc.player.duration) : ""
          color: "white"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Item { width: parent.width - (vc.player ? timeText.implicitWidth + Style.space(10) : 0) - muteBtn.width - windowBtn.width - Style.space(12); height: 1 }

      ActionButton {
        id: muteBtn
        visible: !!vc.player
        iconText: vc.player && vc.player.muted ? "󰝟" : "󰕾"
        tooltipText: vc.player && vc.player.muted ? "Unmute" : "Mute"
        foreground: "white"
        onClicked: if (vc.player) vc.player.muted = !vc.player.muted
      }

      ActionButton {
        id: windowBtn
        iconText: "󰏌"
        tooltipText: "Play in its own window"
        foreground: "white"
        onClicked: {
          var at = vc.player ? vc.player.position : 0
          if (vc.player) vc.player.pause()
          root.openVideo(vc.card.src, at)
        }
      }
    }

    // A thin progress line along the bottom while it plays.
    Rectangle {
      visible: !!vc.player && vc.player.duration > 0
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      height: Style.space(2)
      width: vc.player && vc.player.duration > 0 ? parent.width * vc.player.position / vc.player.duration : 0
      color: root.onlineColor
    }
  }

  // A YouTube link: thumbnail, title and channel. Plays in mpv's window
  // (falling back to the browser); the corner button opens the browser.
  component YouTubeCard: ClippingRectangle {
    id: yc
    property var card: null
    readonly property real pad: Style.space(8)
    implicitHeight: card ? thumb.height + ytInfo.implicitHeight + pad * 2 : 0
    radius: Style.space(6)
    color: Util.alpha(root.foreground, ycHover.hovered ? 0.12 : 0.06)

    HoverHandler { id: ycHover }

    Image {
      id: thumb
      width: parent.width
      height: width * 9 / 16
      // mqdefault is the one thumbnail size YouTube always has, already 16:9.
      source: yc.card ? "https://i.ytimg.com/vi/" + yc.card.id + "/mqdefault.jpg" : ""
      sourceSize.width: 320
      fillMode: Image.PreserveAspectCrop
      asynchronous: true

      Rectangle {
        anchors.centerIn: parent
        width: Style.space(48)
        height: Style.space(34)
        radius: Style.space(8)
        color: ycHover.hovered ? "#ff0033" : Qt.rgba(0.1, 0.1, 0.1, 0.8)

        Text {
          anchors.centerIn: parent
          text: "󰐊"
          color: "white"
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }
    }

    Column {
      id: ytInfo
      x: yc.pad
      y: thumb.height + yc.pad
      width: yc.width - yc.pad * 2
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "YOUTUBE" + (yc.card && yc.card.author ? " · " + yc.card.author.toUpperCase() : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: yc.card ? yc.card.title || yc.card.url : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: ycMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.playYoutube(yc.card)
    }

    ActionButton {
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(4)
      visible: ycHover.hovered
      iconText: "󰏌"
      tooltipText: "Open in browser"
      foreground: "white"
      onClicked: if (yc.card) Qt.openUrlExternally(yc.card.url)
    }
  }

  // A Steam tag this widget doesn't draw ([og], [video], [roomeffect], ...):
  // its name, the fields it carries and any text, with the original to copy.
  component TagCard: Rectangle {
    id: tc
    property var card: null
    property bool copied: false
    readonly property real pad: Style.space(8)
    implicitHeight: card ? tagCol.implicitHeight + pad * 2 : 0
    radius: Style.space(6)
    color: Util.alpha(root.foreground, 0.06)
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.12)

    Timer { id: copiedReset; interval: 1500; onTriggered: tc.copied = false }

    Column {
      id: tagCol
      x: tc.pad
      y: tc.pad
      width: tc.width - tc.pad * 2
      spacing: Style.space(3)

      RowLayout {
        width: parent.width
        spacing: Style.space(6)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: tc.card ? "[" + tc.card.tag + "]" : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          visible: tc.copied
          text: "Copied"
          color: root.onlineColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ActionButton {
          iconText: tc.copied ? "󰄬" : "󰆏"
          tooltipText: "Copy the tag"
          foreground: tc.copied ? root.onlineColor : root.dim
          onClicked: {
            if (!tc.card) return
            root.copyText(tc.card.raw)
            tc.copied = true
            copiedReset.restart()
          }
        }
      }

      Repeater {
        model: tc.card ? tc.card.fields : []
        delegate: Text {
          required property var modelData
          width: tagCol.width
          textFormat: Text.PlainText
          text: (modelData[0] !== "" ? modelData[0] + ": " : "= ") + modelData[1]
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAnywhere
          maximumLineCount: 3
          elide: Text.ElideRight
        }
      }

      Text {
        width: parent.width
        visible: !!tc.card && tc.card.body !== ""
        textFormat: Text.PlainText
        text: tc.card ? tc.card.body : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WrapAnywhere
        maximumLineCount: 6
        elide: Text.ElideRight
      }
    }
  }

  // A shared store page or Workshop item: art, title and the gist, opening
  // the game's store page (here in the popup) or the item on click.
  component ChatCard: ClippingRectangle {
    id: cc
    property var card: null
    property bool popout: false
    readonly property bool isStore: !!card && card.type === "store"
    readonly property bool isImage: !!card && card.type === "image"
    readonly property bool isLink: !!card && card.type === "link"
    // A link's site, as its label (discord.com).
    readonly property string site: isLink ? String(card.url).replace(/^https?:\/\/(www\.)?/, "").split(/[\/?#]/)[0] : ""
    // An image is just its thumbnail, unless it fails to load.
    readonly property bool showInfo: !isImage || art.status === Image.Error
    readonly property var game: card ? root.gameById(card.appid) : null
    readonly property real pad: Style.space(8)
    implicitHeight: art.height + (showInfo ? info.implicitHeight + pad * 2 : 0)
    radius: Style.space(6)
    color: Util.alpha(root.foreground, cardMouse.containsMouse ? 0.12 : 0.06)

    function open() {
      if (!card) return
      if (isImage) root.openImage(card.src)
      else if (!isStore) Qt.openUrlExternally(card.url)
      else if (popout) root.launch("steam://store/" + card.appid)
      else root.openStore({ appid: card.appid, name: game ? game.name : card.name })
    }

    Image {
      id: art
      width: parent.width
      // Store headers are 460x215; Workshop previews are cropped to 16:9 and
      // link previews to their usual 1.91:1; images keep their shape (very
      // tall ones are cropped).
      height: status === Image.Error || source == "" ? 0 : width * (cc.isStore ? 215 / 460 : cc.isLink ? 630 / 1200
        : cc.isImage && cc.card.width > 0 && cc.card.height > 0 ? Math.min(cc.card.height / cc.card.width, 1.25) : 9 / 16)
      source: !cc.card ? "" : cc.isImage ? cc.card.thumb : cc.isStore
        ? (cc.game && cc.game.header ? cc.game.header : cc.card.header
          || "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/" + cc.card.appid + "/header.jpg")
        : cc.card.preview || ""
      sourceSize.width: 600
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
    }

    Column {
      id: info
      visible: cc.showInfo
      x: cc.pad
      y: art.height + cc.pad
      width: cc.width - cc.pad * 2
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: cc.isImage ? "IMAGE" : cc.isLink ? cc.site.toUpperCase() : cc.isStore ? (cc.game ? "STEAM STORE · IN YOUR LIBRARY" : "STEAM STORE")
          : "WORKSHOP" + (cc.game ? " · " + cc.game.name.toUpperCase() : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: !cc.card ? "" : cc.isImage ? "Couldn't load the preview. Click to open it."
          : cc.isLink ? cc.card.title || cc.card.url
          : cc.isStore ? (cc.game ? cc.game.name : cc.card.name || "App " + cc.card.appid)
          : cc.card.title || "Workshop item"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: !cc.isStore && !cc.isImage && !!cc.card && !!cc.card.description
        textFormat: Text.PlainText
        text: cc.card && cc.card.description ? cc.card.description : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: !!cc.card && cc.card.type === "workshop" && (cc.card.votesUp + cc.card.votesDown > 0 || cc.card.comments > 0)
        textFormat: Text.PlainText
        text: {
          if (!cc.card || cc.isStore) return ""
          var parts = [], votes = cc.card.votesUp + cc.card.votesDown
          if (votes > 0) parts.push("󰔓 " + Math.round(cc.card.votesUp * 100 / votes) + "% of " + votes)
          if (cc.card.comments > 0) parts.push("󰆉 " + cc.card.comments)
          return parts.join("   ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: cc.open()
    }
  }


  // Smoothed progress for a download. Steam's figures arrive every couple of
  // seconds and in bursts, so between samples this runs ahead at the current
  // speed (at most a few seconds' worth) and eases toward that each frame.
  component ProgressGlide: Item {
    id: glide
    property var download: null
    property bool active: true
    property real value: 0
    property real sampledAt: 0
    readonly property real progress: download ? download.progress : 0

    // Rows are rebuilt on every poll, so carry the position over per appid
    // instead of starting again from zero.
    function restore() {
      var st = download ? root.glideState[download.appid] : null
      if (st && Math.abs(st.progress - progress) < 0.0001) { value = st.value; sampledAt = st.sampledAt }
      else {
        if (!st || Math.abs(st.value - progress) > 0.05) value = progress
        else value = st.value
        sampledAt = Date.now() / 1000
      }
    }
    Component.onCompleted: restore()
    onDownloadChanged: restore()
    onActiveChanged: if (active) restore()

    FrameAnimation {
      running: glide.active && (Math.abs(glide.value - glide.progress) > 0.0001
        || (!!glide.download && glide.download.status === "downloading" && glide.download.speed > 0))
      onTriggered: {
        var g = glide, d = g.download
        var target = g.progress
        if (d && d.status === "downloading" && d.speed > 0 && d.total > 0) {
          var ahead = Math.min(Date.now() / 1000 - g.sampledAt, 3)
          target = Math.min(1, g.progress + d.speed * ahead / d.total)
        }
        // Never slide backwards over a small overshoot; do follow a real drop.
        if (!(target < g.value && g.value - target < 0.03 && d && d.status === "downloading"))
          g.value += (target - g.value) * Math.min(1, frameTime * 3)
        if (d) root.glideState[d.appid] = { value: g.value, progress: g.progress, sampledAt: g.sampledAt }
      }
    }
  }

  component ProgressLine: Rectangle {
    property var download: null
    readonly property bool busy: !!download && (download.status === "installing" || download.status === "verifying"
      || download.status === "preparing" || (download.status === "downloading" && !download.total))
    implicitHeight: Style.space(3)
    height: implicitHeight
    radius: height / 2
    color: Util.alpha(root.foreground, 0.15)
    clip: true

    Rectangle {
      visible: !parent.busy
      width: parent.width * lineGlide.value
      height: parent.height
      radius: parent.radius
      color: parent.download && parent.download.status === "paused" ? root.dim : root.inGameColor
    }

    ProgressGlide { id: lineGlide; download: parent.download; active: parent.visible && !parent.busy }

    // Indeterminate sweep while Steam is preparing, verifying or installing.
    Rectangle {
      id: sweep
      visible: parent.busy
      width: parent.width * 0.3
      height: parent.height
      radius: parent.radius
      color: root.inGameColor
      NumberAnimation on x {
        running: sweep.visible
        loops: Animation.Infinite
        from: -sweep.width
        to: sweep.parent ? sweep.parent.width : 0
        duration: 1200
      }
    }
  }

  component RowSurface: CursorSurface {
    id: surface
    property int rowIdx: 0
    width: parent ? parent.width : 0
    hasCursor: root.cursorActive && root.rowIndex === rowIdx
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.rowIndex = surface.rowIdx }
      onClicked: root.activateRow(root.rows[surface.rowIdx])
    }
  }
}
