// A stand-in for the Steam client's SharedJSContext, for demo mode and the
// tests: the same objects steamctl.py's scripts read (g_FriendsUIApp,
// appStore, RemotePlayStore_SteamUI, SteamClient), filled from world.json.
//
//   node fake_steam.js world.json < script.js   ->  {"ok": true, "value": ...}
//
// Sending a message, reacting and reading a chat are saved back to world.json.
"use strict"
const fs = require("fs")

const worldPath = process.argv[2]
const world = JSON.parse(fs.readFileSync(worldPath, "utf8"))
let dirty = false
const save = () => { dirty = true }

const hex = id => id.toString(16).padStart(40, "0")
const appName = appid => {
  const own = world.names && world.names[appid]
  return own || ""
}

// ---------- people ----------
const STATE = { offline: 0, online: 1, busy: 2, away: 3, "in-game": 1 }
function player(p) {
  const id = Number(p.accountid)
  const inGame = p.state === "in-game" && p.appid
  return {
    accountid: id,
    steamid64: String(76561197960265728n + BigInt(id)),
    display_name: p.nickname || p.name,
    m_strNickname: p.nickname || "",
    current_game_name: "",
    current_game_icon_url: inGame ? "https://demo.invalid/icon/" + p.appid + ".jpg" : "",
    current_game_rich_presence: p.presence || "",
    is_friend: !!p.friend,
    m_persona: {
      m_strPlayerName: p.name,
      m_strAvatarHash: hex(id),
      m_ePersonaState: STATE[p.state] || 0,
      m_unGamePlayedAppID: inGame ? p.appid : 0,
      m_gameid: inGame ? String(p.appid) : "0",
      m_strGameExtraInfo: "",
      m_game_lobby_id: inGame && p.lobby || "0",
      connect_string: inGame && p.connect || undefined,
      is_in_joinable_game: !!(inGame && (p.lobby || p.connect)),
    },
  }
}
const people = {}
for (const f of world.friends) people[f.accountid] = player(Object.assign({ friend: true }, f))
for (const s of world.strangers || []) people[s.accountid] = player(s)
people[world.self] = player(Object.assign({ accountid: world.self, name: "Blip", state: "online" }, world.selfGame || {}))

// ---------- chats ----------
function chat(key, onRead) {
  const log = world.chats[key] = world.chats[key] || []
  const message = m => ({
    unAccountID: m.from,
    strMessage: m.text,
    rtTimestamp: m.ts,
    unOrdinal: m.ordinal || 0,
    m_bServerAcknowledged: true,
    m_rgReactions: (m.reactions || []).map(r => ({
      eReactionType: r.type, strReaction: r.name, cReactors: r.count, bUserReacted: !!r.mine,
    })),
    _m: m,
  })
  return {
    m_bChatLogsLoaded: true,
    LoadChatLogs: async () => {},
    get chat_messages() { return log.map(message) },
    get unread_message_count() { return onRead.unread() },
    is_friend_typing: !!onRead.typing,
    OnActivate() { onRead.read(); save() },
    SendChatMessage(text) {
      const now = Math.floor(Date.now() / 1000)
      const ordinal = log.filter(m => m.ts === now).length
      log.push({ from: world.self, ts: now, ordinal: ordinal, text: String(text).trim(), reactions: [] })
      save()
    },
    async UpdateMessageReaction(m, type, name, add) {
      const rs = m._m.reactions = m._m.reactions || []
      let r = rs.find(x => x.type === type && x.name === name)
      if (add && !r) rs.push(r = { type: type, name: name, count: 0, mine: false })
      if (r && add !== r.mine) { r.count += add ? 1 : -1; r.mine = add }
      m._m.reactions = rs.filter(x => x.count > 0)
      save()
      return true
    },
  }
}

function friendChat(accountid) {
  const f = world.friends.find(x => x.accountid === Number(accountid))
  if (!f) return null
  return chat("friend:" + f.accountid, {
    unread: () => f.unread || 0, read: () => { f.unread = 0 }, typing: f.typing,
  })
}

function chatGroup(g) {
  const rooms = g.rooms.map(r => ({
    GetRoomID: () => r.id,
    name: r.name,
    get unread_message_count() { return r.unread || 0 },
    get has_unread_mention() { return !!r.mention },
    time_last_message: g.activity,
    chat: () => chat("group:" + g.id + ":" + r.id, { unread: () => r.unread || 0, read: () => { r.unread = 0; r.mention = false } }),
  }))
  return {
    GetGroupID: () => g.id,
    GetDefaultChatID: () => g.rooms[0].id,
    GetChatRoom: id => { const r = rooms.find(x => x.GetRoomID() === String(id)); return r ? r.chat() : null },
    name: g.name,
    tagline: g.tagline,
    hasAvatarSHA: !!g.avatar,
    avatar_url_medium: g.avatar,
    memberCountTotal: g.members.length,
    textRoomList: rooms,
    time_last_activity: g.activity,
    m_bFullStateLoaded: true,
    memberList: { member_list: g.members.map(id => people[id]).filter(Boolean) },
  }
}

const favorites = world.friends.filter(f => f.favorite).map(f => ({ friend: people[f.accountid] }))
globalThis.g_FriendsUIApp = {
  FriendStore: {
    self: people[world.self],
    all_friends: world.friends.map(f => people[f.accountid]),
    GetPlayer: id => people[id],
    FriendGroupStore: {
      user_groups: world.groups.map(g => ({
        m_iGroupID: g.id, m_strName: g.name,
        m_rgAccountIDMembers: world.friends.filter(f => f.groups.indexOf(g.id) >= 0).map(f => f.accountid),
      })),
    },
    FavoritesStore: { favorites: favorites },
    InviteToLobby(f, appid, lobby) { (world.invites = world.invites || []).push({ to: f.accountid, appid: appid, lobby: lobby }); save() },
    InviteToGame(f, appid, connect) { (world.invites = world.invites || []).push({ to: f.accountid, appid: appid, connect: connect }); save() },
  },
  ChatStore: {
    GetFriendChat: (id, create) => friendChat(id),
    currentChatRoomGroups: (world.groupChats || []).map(chatGroup),
    GetChatRoomGroup: id => { const g = (world.groupChats || []).find(x => x.id === String(id)); return g ? chatGroup(g) : null },
    IncRefActiveChatRoomGroup() {},
    DecRefActiveChatRoomGroup() {},
    EmoticonStore: {
      is_initialized: true,
      emoticon_list: (world.emoticons || []).map(name => ({ name: name })),
      recent_emoticons: (world.emoticons || []).slice(0, 3).map(name => ({ name: name })),
      RequestEmoticonList() {},
      BAwaitInitialized: () => Promise.resolve(true),
    },
  },
  AppInfoStore: { GetAppInfo: appid => ({ name: appName(appid) }) },
}

// ---------- notifications ----------
globalThis.NotificationStore = { m_rgNotificationTray: world.notifications || [] }

// ---------- Remote Play ----------
globalThis.window = globalThis
globalThis.RemotePlayStore_SteamUI = {
  devices: (world.computers || []).map(c => ({ clientId: c.id, clientName: c.name, status: "Connected" })),
}
globalThis.appStore = {
  allApps: Object.entries(world.remoteApps || {}).map(([appid, on]) => ({
    appid: Number(appid),
    per_client_data: on.map(id => ({ clientid: id, installed: true })),
    selected_clientid: on[0],
  })),
}

// ---------- the client API ----------
const done = v => Promise.resolve(v)
const download = world.download || {}
globalThis.SteamClient = {
  InstallFolder: {
    GetInstallFolders: () => done((world.folders || []).map(f => ({
      nFolderIndex: f.index, strFolderPath: f.path, strUserLabel: f.label, strDriveName: f.drive,
      nFreeSpace: f.free, bIsDefaultFolder: f.isDefault, bIsMounted: true,
    }))),
  },
  Downloads: {
    RegisterForDownloadOverview(cb) {
      setTimeout(() => cb({
        update_appid: download.appid || 0, update_state: download.appid ? "Downloading" : "None",
        paused: !!download.paused, update_network_bytes_per_second: download.paused ? 0 : download.speed || 0,
        update_disc_bytes_per_second: 0, overall_percent_complete: 0, overall_estimated_time_remaining_sec: download.eta || 0,
      }), 0)
      return { unregister() {} }
    },
    RegisterForDownloadItems(cb) { setTimeout(() => cb(false, []), 0); return { unregister() {} } },
    EnableAllDownloads(on) { download.paused = !on; save() },
    PauseAppUpdate() { download.paused = true; save() },
    ResumeAppUpdate() { download.paused = false; save() },
  },
  Installs: {
    GetInstallManagerInfo: () => done({ eInstallState: 0 }),
    OpenInstallWizard() {}, OpenUninstallWizard() {}, SetInstallFolder() {}, ContinueInstall() {},
  },
  Apps: { StreamGame() {} },
  RemotePlay: { StartDesktopStream() {} },
  Window: { HideWindow() {}, ShowWindow() {}, BringToFront() {} },
  WebChat: { GetPrivateConnectString: () => done("") },
}
globalThis.g_PopupManager = {
  AddPopupCreatedCallback() {}, GetExistingPopup: () => null, GetPopups: () => [],
}

// ---------- run the script ----------
let src = ""
process.stdin.setEncoding("utf8")
process.stdin.on("data", d => { src += d })
process.stdin.on("end", async () => {
  let out
  try {
    const value = await (0, eval)(src)
    out = { ok: true, value: value === undefined ? null : value }
  } catch (e) {
    out = { ok: false, error: String((e && e.message) || e) }
  }
  if (dirty) fs.writeFileSync(worldPath, JSON.stringify(world, null, 1))
  process.stdout.write(JSON.stringify(out))
})
