package.path = package.path .. ";./?.lua"

SETTINGS = SETTINGS or {}
SETTINGS.STEAM_ONLINE = SETTINGS.STEAM_ONLINE or {
    PROTOCOL_VERSION = 1,
    RECONNECT_TIMEOUT_SEC = 30,
    HEARTBEAT_SEC = 1,
    PACKET_CHANNEL_ACTION = 1,
    PACKET_CHANNEL_CONTROL = 2
}
SETTINGS.ELO = SETTINGS.ELO or {
    DEFAULT_RATING = 1200
}

local SteamOnlineSession = require("steam_online_session")
local SteamLockstep = require("steam_lockstep")

local results = {}

local function runTest(name, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = {name = name, ok = ok, err = err}
end

local function assertTrue(condition, message)
    if not condition then
        error(message or "assertTrue failed", 2)
    end
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function wireLocksteps(a, b)
    a.sendPacket = function(self, packet, channel)
        b:injectPacket(packet)
        return true
    end
    b.sendPacket = function(self, packet, channel)
        a:injectPacket(packet)
        return true
    end
end

runTest("online_button_routes_to_online_lobby", function()
    local content = readFile("mainMenu.lua")
    assertTrue(type(content) == "string", "mainMenu.lua not readable")
    assertTrue(content:find("Online Multiplayer", 1, true) ~= nil, "Online Multiplayer button label missing")
    assertTrue(content:find('changeState("onlineLobby")', 1, true) ~= nil, "onlineLobby route missing")
end)

runTest("main_menu_has_leaderboard_button", function()
    local content = readFile("mainMenu.lua")
    assertTrue(type(content) == "string", "mainMenu.lua not readable")
    assertTrue(content:find("Leaderboard", 1, true) ~= nil, "Leaderboard button label missing")
end)

runTest("main_menu_leaderboard_routes_to_online_leaderboard_state", function()
    local content = readFile("mainMenu.lua")
    assertTrue(type(content) == "string", "mainMenu.lua not readable")
    assertTrue(content:find('changeState("onlineLeaderboard")', 1, true) ~= nil, "onlineLeaderboard route missing")
end)

runTest("main_menu_leaderboard_disabled_when_steam_offline", function()
    local content = readFile("mainMenu.lua")
    assertTrue(type(content) == "string", "mainMenu.lua not readable")
    assertTrue(content:find("uiButtons.playLeaderboard.enabled = onlineReady", 1, true) ~= nil, "leaderboard online-ready gate missing")
end)

runTest("state_machine_registers_online_leaderboard_state", function()
    local content = readFile("stateMachine.lua")
    assertTrue(type(content) == "string", "stateMachine.lua not readable")
    assertTrue(content:find('onlineLeaderboard = require("onlineLeaderboard")', 1, true) ~= nil, "onlineLeaderboard state registration missing")
end)

runTest("state_machine_flushes_transient_inputs_on_state_change", function()
    local content = readFile("stateMachine.lua")
    assertTrue(type(content) == "string", "stateMachine.lua not readable")
    assertTrue(content:find("local function resetTransientInputState()", 1, true) ~= nil, "transient input reset helper missing")
    assertTrue(content:find("resetTransientInputState()", 1, true) ~= nil, "state machine should reset transient inputs on state change")
    assertTrue(content:find("GAME.CURRENT.STATE_MACHINE = stateMachine", 1, true) ~= nil, "state machine should register itself for dialog/input reset hooks")
end)

runTest("main_menu_local_routes_direct_to_local_flow", function()
    local content = readFile("mainMenu.lua")
    assertTrue(type(content) == "string", "mainMenu.lua not readable")
    assertTrue(content:find("startLocalMultiplayerFromMenu", 1, true) ~= nil, "direct local multiplayer route helper missing")
    assertTrue(content:find('changeState("localMultiplayerMenu")', 1, true) == nil, "main menu should not route through local submenu")
end)

runTest("online_disabled_when_steam_unavailable", function()
    local session = SteamOnlineSession.new({localUserId = "u1"})
    session.isOnlineAvailable = function()
        return false
    end
    local ok, reason = session:startHostLobby(2)
    assertTrue(ok == false, "startHostLobby should fail with unavailable Steam runtime")
    assertTrue(type(reason) == "string", "startHostLobby should provide failure reason")
end)

runTest("host_setup_sync_guest_readonly", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.role = "host"
    hostSession.sessionId = "s1"
    hostSession.peerUserId = "guest"

    local guestSession = SteamOnlineSession.new({localUserId = "guest"})
    guestSession.active = true
    guestSession.role = "guest"
    guestSession.sessionId = "s1"
    guestSession.peerUserId = "host"

    local host = SteamLockstep.new({session = hostSession})
    local guest = SteamLockstep.new({session = guestSession})
    wireLocksteps(host, guest)

    host:sendPacket({
        kind = "SETUP_SNAPSHOT",
        sessionId = "s1",
        setup = {selectorOptions = {one = "steam_local_human", two = "steam_remote_human"}}
    }, 2)

    local event = guest:pollEvent()
    assertTrue(event and event.kind == "setup_snapshot", "guest must receive setup snapshot")
    assertTrue(guestSession:canControlSetup() == false, "guest setup must be read-only")
end)

runTest("lockstep_propose_accept_commit", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.role = "host"
    hostSession.sessionId = "s2"
    hostSession.peerUserId = "guest"

    local guestSession = SteamOnlineSession.new({localUserId = "guest"})
    guestSession.active = true
    guestSession.role = "guest"
    guestSession.sessionId = "s2"
    guestSession.peerUserId = "host"

    local host = SteamLockstep.new({session = hostSession})
    local guest = SteamLockstep.new({session = guestSession})
    wireLocksteps(host, guest)

    local ok = host:proposeAction({actionType = "end_turn"}, {turn = 3})
    assertTrue(ok == true, "proposeAction should succeed")

    local hostEvent = host:pollEvent()
    local guestEvent = guest:pollEvent()
    assertTrue(hostEvent and hostEvent.kind == "apply_command", "host should apply committed command")
    assertTrue(guestEvent and guestEvent.kind == "apply_command", "guest should apply committed command")
end)

runTest("hash_mismatch_aborts_no_winner", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.sessionId = "s3"
    hostSession.peerUserId = "guest"

    local host = SteamLockstep.new({session = hostSession})
    host.pendingStateHash["host:10"] = "aaa"
    host:handlePacket({kind = "STATE_HASH", seq = 10, proposerId = "host", commandId = "host:10", hash = "bbb", sessionId = "s3"})
    assertTrue(host:isAborted(), "lockstep must abort on hash mismatch")
    assertTrue(host:getAbortReason() == "desync_hash_mismatch", "abort reason must indicate desync")
end)

runTest("reconnect_within_short_window_resumes", function()
    local session = SteamOnlineSession.new({localUserId = "u1"})
    session.active = true
    session.peerUserId = "u2"
    session.connected = true

    session:markDisconnected("lost")
    assertTrue(session.connected == false, "session should mark disconnected")
    session:markReconnected("u2")
    assertTrue(session.connected == true, "session should reconnect before timeout")
    assertTrue(session:getReconnectTimeRemaining() == nil, "reconnect timer should clear after reconnect")
end)

runTest("reconnect_timeout_forfeit", function()
    local session = SteamOnlineSession.new({localUserId = "u1"})
    session.active = true
    session.peerUserId = "u2"
    session.connected = true

    session:markDisconnected("lost")
    session.disconnectDeadline = (session.disconnectDeadline or 0) - 999
    local status = session:update()
    assertTrue(status == "timeout", "session update must report timeout")
end)

runTest("online_lobby_no_debug_status_strings_rendered", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("statusMessage", 1, true) == nil, "statusMessage UI text should not be present")
    assertTrue(content:find("Role:", 1, true) == nil, "role/status UI text should not be rendered")
    assertTrue(content:find("love.graphics.printf(\"Steam online ready", 1, true) == nil, "inline steam ready UI text should not be present")
end)

runTest("online_lobby_title_hero_removed", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("drawTitle(\"ONLINE MULTIPLAYER\"", 1, true) == nil, "legacy hero title draw should be removed")
end)

runTest("online_lobby_list_panel_expanded_layout", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("panelTop = 54", 1, true) ~= nil, "expanded panelTop expected")
    assertTrue(content:find("panelBottom = 152", 1, true) ~= nil, "expanded list space panelBottom expected")
end)

runTest("online_lobby_contains_join_and_refresh_controls", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("Host Lobby", 1, true) ~= nil, "host control label missing")
    assertTrue(content:find("Join Selected", 1, true) ~= nil, "join control label missing")
    assertTrue(content:find("Refresh", 1, true) ~= nil, "refresh control label missing")
    assertTrue(content:find("Invite Friend", 1, true) ~= nil, "invite control label missing")
    assertTrue(content:find("Back", 1, true) ~= nil, "back control label missing")
end)

runTest("online_lobby_join_button_enabled_only_with_selection", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("selectedEntry ~= nil", 1, true) ~= nil, "join button selection gate missing")
end)

runTest("online_lobby_status_bar_present_and_updated_by_events", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("setStatusBar(", 1, true) ~= nil, "status bar setter missing")
    assertTrue(content:find("statusBarText", 1, true) ~= nil, "status bar text state missing")
    assertTrue(content:find("getStatusBarColor()", 1, true) ~= nil, "status bar color helper missing")
end)

runTest("online_lobby_row_includes_elo_score_and_rank_format", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("RATING %d (#%s)", 1, true) ~= nil, "lobby row rating format missing")
    assertTrue(content:find("downloadLeaderboardEntriesForUsers", 1, true) ~= nil, "lobby owner rating refresh missing")
end)

runTest("online_lobby_host_sees_local_waiting_row", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("buildLocalHostLobbyRow", 1, true) ~= nil, "local host lobby row builder missing")
    assertTrue(content:find("Your Lobby", 1, true) ~= nil, "local host lobby label missing")
end)

runTest("online_lobby_join_disabled_for_non_joinable_local_row", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("entry.joinable == false", 1, true) ~= nil, "non-joinable lobby gate missing")
end)

runTest("lobby_list_orders_friends_before_non_friends", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("relationPriority", 1, true) ~= nil, "relationPriority helper missing")
    assertTrue(content:find("relationCmp", 1, true) ~= nil, "relation compare missing")
end)

runTest("lobby_list_orders_friend_of_friend_before_other", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find('if relation == "friend_of_friend" then', 1, true) ~= nil, "friend_of_friend priority missing")
    assertTrue(content:find('return 2', 1, true) ~= nil, "other relation priority missing")
end)

runTest("lobby_list_shows_only_joinable_remote_rows", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("sortAndFilterAvailableLobbies", 1, true) ~= nil, "available lobby filter helper missing")
    assertTrue(content:find("elseif isEntryJoinable(entry) then", 1, true) ~= nil, "remote joinable filter rule missing")
end)

runTest("lobby_list_keeps_local_host_row_pinned_top_when_active", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("table.insert(filtered, 1, localRow)", 1, true) ~= nil, "local host row pinning missing")
end)

runTest("lobby_list_sort_is_deterministic_for_equal_relation", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("memberCmp", 1, true) ~= nil, "member count tie-break missing")
    assertTrue(content:find('tostring(a.lobbyId or "") < tostring(b.lobbyId or "")', 1, true) ~= nil, "lobbyId tie-break missing")
end)

runTest("online_leaderboard_draws_your_position_row", function()
    local content = readFile("onlineLeaderboard.lua")
    assertTrue(type(content) == "string", "onlineLeaderboard.lua not readable")
    assertTrue(content:find("Your Position", 1, true) ~= nil, "your position panel text missing")
    assertTrue(content:find("localPlayerRow", 1, true) ~= nil, "local player row state missing")
end)

runTest("online_leaderboard_supports_scrollable_top_100", function()
    local content = readFile("onlineLeaderboard.lua")
    assertTrue(type(content) == "string", "onlineLeaderboard.lua not readable")
    assertTrue(content:find("downloadLeaderboardTop", 1, true) ~= nil, "top leaderboard fetch missing")
    assertTrue(content:find("scrollbarGeometry", 1, true) ~= nil, "scrollbar support missing")
    assertTrue(content:find("scrollRows", 1, true) ~= nil, "scroll row support missing")
end)

runTest("online_leaderboard_back_returns_main_menu", function()
    local content = readFile("onlineLeaderboard.lua")
    assertTrue(type(content) == "string", "onlineLeaderboard.lua not readable")
    assertTrue(content:find('changeState("mainMenu")', 1, true) ~= nil, "back to main menu transition missing")
end)

runTest("remote_controller_name_uses_peer_persona", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("session.peerPersonaName", 1, true) ~= nil, "peer persona lookup missing")
    assertTrue(content:find("\"Remote Player\"", 1, true) == nil, "remote placeholder name should not be used")
end)

runTest("invite_received_event_triggers_global_join_reject_prompt", function()
    local content = readFile("stateMachine.lua")
    assertTrue(type(content) == "string", "stateMachine.lua not readable")
    assertTrue(content:find("lobby_invite_received", 1, true) ~= nil, "invite-received event handling missing")
    assertTrue(content:find('if type(events) == "table" and #events > 0 then', 1, true) ~= nil, "invite processing should not early-return before queued prompt display")
    assertTrue(content:find("online.pendingInvitePrompt = payload", 1, true) ~= nil, "pending invite prompt assignment missing")
    assertTrue(content:find('title = "Game Invite"', 1, true) ~= nil, "invite prompt title missing")
    assertTrue(content:find('confirmText = "Join"', 1, true) ~= nil, "invite join label missing")
    assertTrue(content:find('cancelText = "Reject"', 1, true) ~= nil, "invite reject label missing")
    assertTrue(content:find("runtimeOnline.pendingInviteJoinLobbyId = tostring(invitePrompt.lobbyId)", 1, true) ~= nil, "join branch should stage pending invite lobby id")
    assertTrue(content:find("stateMachine.changeState(\"onlineLobby\")", 1, true) ~= nil, "join branch should route to onlineLobby")
end)

runTest("invite_requested_click_event_deduped_when_received_prompt_pending", function()
    local content = readFile("stateMachine.lua")
    assertTrue(type(content) == "string", "stateMachine.lua not readable")
    assertTrue(content:find("INVITE_PROMPT_DEDUPE_SEC", 1, true) ~= nil, "invite dedupe window constant missing")
    assertTrue(content:find("lastInvitePromptKey", 1, true) ~= nil, "invite dedupe key tracking missing")
    assertTrue(content:find("isDuplicateRecent", 1, true) ~= nil, "recent duplicate guard missing")
    assertTrue(content:find("isDuplicatePending", 1, true) ~= nil, "pending duplicate guard missing")
    assertTrue(content:find("lobby_invite_requested", 1, true) ~= nil, "legacy invite-requested path should remain for compatibility")
end)

runTest("invite_button_can_create_friends_lobby_when_no_active_session", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("ensureFriendsInviteSession", 1, true) ~= nil, "invite auto-host helper missing")
    assertTrue(content:find('session:startHostLobby(2, "friends")', 1, true) ~= nil, "invite flow should create friends-only lobby")
    assertTrue(content:find("if session.active then", 1, true) ~= nil, "invite flow should handle active-session replacement")
    assertTrue(content:find("session:leave()", 1, true) ~= nil, "invite flow should leave current session before auto-hosting")
    assertTrue(content:find("steamRuntime.onGuideButtonPressed()", 1, true) ~= nil, "invite overlay trigger missing")
end)

runTest("invite_sender_wait_overlay_delayed_after_invite_send", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("INVITE_WAIT_OVERLAY_DELAY_SEC = 8", 1, true) ~= nil, "invite wait delay constant missing")
    assertTrue(content:find("armInviteWaitOverlay", 1, true) ~= nil, "invite wait arming helper missing")
    assertTrue(content:find("inviteWaitVisible = true", 1, true) ~= nil, "invite wait overlay visibility trigger missing")
    assertTrue(content:find("Waiting for Opponent", 1, true) ~= nil, "invite wait overlay title missing")
end)

runTest("invite_sender_cancel_closes_host_lobby", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("cancelInviteWaitAndCloseHostLobby", 1, true) ~= nil, "invite cancel helper missing")
    assertTrue(content:find("session:leave()", 1, true) ~= nil, "invite cancel should leave host lobby")
    assertTrue(content:find("Invite canceled. Lobby closed.", 1, true) ~= nil, "invite cancel status message missing")
end)

runTest("invite_sender_keep_waiting_preserves_active_lobby", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("handleInviteWaitDecision", 1, true) ~= nil, "invite wait decision helper missing")
    assertTrue(content:find("Still waiting for opponent...", 1, true) ~= nil, "keep waiting status message missing")
end)

runTest("invite_join_leaves_existing_active_lobby_before_joining_invited", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("consumePendingInviteJoinLobbyId", 1, true) ~= nil, "pending invite join consumer missing")
    assertTrue(content:find("Invite accepted: leaving current lobby before joining invited lobby", 1, true) ~= nil, "leave-before-join log missing")
    assertTrue(content:find("session:joinLobby(pendingInviteLobbyId)", 1, true) ~= nil, "pending invite join path missing")
end)

runTest("online_lobby_auto_enters_faction_select_when_connected", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    local hasConnectedGate = content:find("if session.connected then", 1, true) ~= nil or
        content:find("if session.connected and session.peerUserId then", 1, true) ~= nil
    assertTrue(hasConnectedGate, "connected auto-transition gate missing")
    assertTrue(content:find("enterFactionSelectOnline()", 1, true) ~= nil, "factionSelect auto-enter call missing")
end)

runTest("faction_ready_guest_request_host_broadcast_state", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.role = "host"
    hostSession.sessionId = "ready-1"
    hostSession.peerUserId = "guest"
    hostSession.connected = true

    local guestSession = SteamOnlineSession.new({localUserId = "guest"})
    guestSession.active = true
    guestSession.role = "guest"
    guestSession.sessionId = "ready-1"
    guestSession.peerUserId = "host"
    guestSession.connected = true

    local host = SteamLockstep.new({session = hostSession})
    local guest = SteamLockstep.new({session = guestSession})
    wireLocksteps(host, guest)

    local ok = guest:sendReadyRequest(true, 1)
    assertTrue(ok == true, "guest ready request send failed")

    local req = host:pollEvent()
    assertTrue(req and req.kind == "ready_request", "host must receive ready_request")
    assertTrue(req.payload.ready == true, "ready_request payload mismatch")

    local sent = host:sendReadyState(true, true, 2)
    assertTrue(sent == true, "host ready state send failed")

    local st = guest:pollEvent()
    assertTrue(st and st.kind == "ready_state", "guest must receive ready_state")
    assertTrue(st.payload.hostReady == true and st.payload.guestReady == true, "ready_state payload mismatch")
end)

runTest("faction_start_enabled_only_when_both_ready", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("session.connected == true", 1, true) ~= nil, "start gate should require connected session")
    assertTrue(content:find("prematchTransportReady == true", 1, true) ~= nil, "start gate should require prematch transport")
    assertTrue(content:find("onlineReadyState.hostReady == true", 1, true) ~= nil, "start gate should require host ready")
    assertTrue(content:find("onlineReadyState.guestReady == true", 1, true) ~= nil, "start gate should require guest ready")
    assertTrue(content:find("peerOnlineRatingProfile ~= nil", 1, true) ~= nil, "start gate should require exchanged rating profile")
end)

runTest("ready_reset_on_host_setup_change", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("hostResetOnlineReadyState()", 1, true) ~= nil, "ready reset helper missing")
    assertTrue(content:find("changeSelectorOption", 1, true) ~= nil, "selector change function missing")
    assertTrue(content:find("factionSelect.randomizeFactions", 1, true) ~= nil, "randomize function missing")
end)

runTest("timeout_in_gameplay_returns_main_menu_and_leaves_session", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("onlineSession:leave()", 1, true) ~= nil, "online session leave missing in gameplay timeout path")
    local hasMainMenuReturn = content:find("stateMachineRef.changeState(\"mainMenu\")", 1, true) ~= nil
        or content:find("stateMachine.changeState(\"mainMenu\")", 1, true) ~= nil
    assertTrue(hasMainMenuReturn, "main menu return missing in gameplay timeout path")
    assertTrue(content:find("timeout_forfeit", 1, true) ~= nil, "timeout result code missing in gameplay")
end)

runTest("timeout_forfeit_winner_resolution_uses_disconnect_reason", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("resolveTimeoutForfeitWinnerFaction", 1, true) ~= nil, "timeout winner resolver missing")
    assertTrue(content:find("peer_missing_from_lobby", 1, true) ~= nil, "peer-missing winner path missing")
    assertTrue(content:find("local_missing_from_lobby", 1, true) ~= nil, "local-missing loss path missing")
end)

runTest("timeout_forfeit_elo_policy_flag_is_applied", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("UPDATE_ON_TIMEOUT_FORFEIT", 1, true) ~= nil, "timeout forfeit rating policy flag not used")
end)

runTest("timeout_in_faction_setup_returns_main_menu_and_leaves_session", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("local timeoutStatus = session:update()", 1, true) ~= nil, "session timeout polling missing in factionSelect")
    assertTrue(content:find("showFactionDisconnectDialogAndExit", 1, true) ~= nil, "disconnect dialog helper missing for faction timeout path")
    assertTrue(content:find("Opponent disconnected. Returning to main menu.", 1, true) ~= nil, "faction disconnect confirm message missing")
end)

runTest("faction_peer_disconnect_routes_to_confirm_then_main_menu", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('disconnectReason == "peer_missing_from_lobby"', 1, true) ~= nil, "peer disconnect reason gate missing")
    assertTrue(content:find('ConfirmDialog.showMessage', 1, true) ~= nil, "disconnect should use confirm dialog")
    assertTrue(content:find('title = "Opponent Disconnected"', 1, true) ~= nil, "disconnect dialog title missing")
end)

runTest("online_text_debug_banners_not_rendered_in_faction_and_gameplay", function()
    local faction = readFile("factionSelect.lua")
    local gameplay = readFile("gameplay.lua")
    assertTrue(type(faction) == "string", "factionSelect.lua not readable")
    assertTrue(type(gameplay) == "string", "gameplay.lua not readable")
    assertTrue(faction:find("onlineBannerMessage", 1, true) == nil, "factionSelect should not render online banner message")
    assertTrue(gameplay:find("onlineStatusMessage", 1, true) == nil, "gameplay should not render online status banner")
end)

runTest("online_lobby_layout_contains_bottom_action_row_controls", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("buttonRowY", 1, true) ~= nil, "bottom action row layout missing")
    assertTrue(content:find("buttonOrder =", 1, true) ~= nil, "button row ordering missing")
end)

runTest("create_lobby_uses_public_type", function()
    local content = readFile("integrations/steam/native/steam_bridge.cpp")
    assertTrue(type(content) == "string", "steam_bridge.cpp not readable")
    assertTrue(content:find("CreateLobby(k_ELobbyTypePublic, boundedMembers)", 1, true) ~= nil, "public lobby type not configured")
end)

runTest("native_accepts_networking_session_request", function()
    local hpp = readFile("integrations/steam/native/steam_bridge.hpp")
    local cpp = readFile("integrations/steam/native/steam_bridge.cpp")
    assertTrue(type(hpp) == "string", "steam_bridge.hpp not readable")
    assertTrue(type(cpp) == "string", "steam_bridge.cpp not readable")
    assertTrue(hpp:find("SteamNetworkingMessagesSessionRequest_t", 1, true) ~= nil, "session request callback type missing in header")
    assertTrue(cpp:find("AcceptSessionWithUser", 1, true) ~= nil, "AcceptSessionWithUser call missing")
end)

runTest("native_invite_received_callback_emits_lobby_event", function()
    local hpp = readFile("integrations/steam/native/steam_bridge.hpp")
    local cpp = readFile("integrations/steam/native/steam_bridge.cpp")
    assertTrue(type(hpp) == "string", "steam_bridge.hpp not readable")
    assertTrue(type(cpp) == "string", "steam_bridge.cpp not readable")
    assertTrue(hpp:find("CCallback<SteamBridge, LobbyInvite_t>", 1, true) ~= nil, "LobbyInvite callback declaration missing")
    assertTrue(cpp:find("onLobbyInvite(LobbyInvite_t* data)", 1, true) ~= nil, "LobbyInvite callback handler missing")
    assertTrue(cpp:find('event.type = "lobby_invite_received"', 1, true) ~= nil, "lobby_invite_received event emission missing")
end)

runTest("draw_offer_requires_both_accept", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.role = "host"
    hostSession.sessionId = "s4"
    hostSession.peerUserId = "guest"

    local guestSession = SteamOnlineSession.new({localUserId = "guest"})
    guestSession.active = true
    guestSession.role = "guest"
    guestSession.sessionId = "s4"
    guestSession.peerUserId = "host"

    local host = SteamLockstep.new({session = hostSession})
    local guest = SteamLockstep.new({session = guestSession})
    wireLocksteps(host, guest)

    local ok = host:proposeDraw(12)
    assertTrue(ok == true, "host should propose draw")

    local proposed = guest:pollEvent()
    assertTrue(proposed and proposed.kind == "draw_proposed", "guest should receive draw proposal")

    guest:voteDraw(false)
    local rejected = host:pollEvent()
    assertTrue(rejected and rejected.kind == "draw_rejected", "draw should be rejected when one side votes no")
end)


runTest("session_member_update_enter_sets_peer_connected", function()
    local s = SteamOnlineSession.new({localUserId = "host"})
    s.active = true
    s.role = "host"
    s.lobbyId = "l1"

    s:handleLobbyEvent({
        type = "lobby_member_update",
        lobbyId = "l1",
        memberId = "guest",
        memberState = 0x01
    })

    assertTrue(s.peerUserId == "guest", "peer should be set on enter")
    assertTrue(s.connected == true, "session should be connected on peer enter")
end)

runTest("session_member_update_leave_clears_current_peer", function()
    local s = SteamOnlineSession.new({localUserId = "host"})
    s.active = true
    s.role = "host"
    s.lobbyId = "l2"
    s.peerUserId = "guest"
    s.connected = true

    s:handleLobbyEvent({
        type = "lobby_member_update",
        lobbyId = "l2",
        memberId = "guest",
        memberState = 0x02
    })

    assertTrue(s.peerUserId == nil, "peer should clear on leave")
    assertTrue(s.connected == false, "session should disconnect on peer leave")
end)

runTest("session_snapshot_single_local_does_not_immediately_clear_host_peer", function()
    local s = SteamOnlineSession.new({localUserId = "host"})
    s.active = true
    s.role = "host"
    s.peerUserId = "guest"
    s.connected = true
    s.peerLastSeenAt = 100
    s.peerStableSince = 100

    local savedNow = love and love.timer and love.timer.getTime
    love = love or {}
    love.timer = love.timer or {}
    love.timer.getTime = function()
        return 101
    end

    local ok = s:applyLobbySnapshot({
        lobbyId = "l3",
        ownerId = "host",
        members = {"host"}
    })

    if savedNow then
        love.timer.getTime = savedNow
    end

    assertTrue(ok == true, "snapshot apply should succeed")
    assertTrue(s.peerUserId == "guest", "host should keep peer during grace window")
end)

runTest("online_lobby_uses_peer_stable_gate_for_faction_transition", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("canEnterFactionSetup", 1, true) ~= nil, "faction transition gate helper missing")
    assertTrue(content:find("session:isPeerStable()", 1, true) ~= nil, "peer stable gate missing")
end)

runTest("online_lobby_no_nonce_ack_dependency_for_transition", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("mom_transition_nonce", 1, true) == nil, "nonce transition dependency should be removed")
    assertTrue(content:find("mom_guest_ack_nonce", 1, true) == nil, "guest ack dependency should be removed")
    assertTrue(content:find("mom_stage", 1, true) == nil, "stage dependency should be removed")
end)

runTest("host_pre_match_timeout_stays_in_lobby_waiting", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find('session.role == "host"', 1, true) ~= nil, "host timeout role branch missing")
    assertTrue(content:find('session:clearPeerForWaiting("peer_timeout_pre_match")', 1, true) ~= nil, "host pre-match clear peer path missing")
end)

runTest("guest_pre_match_timeout_returns_main_menu", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find('terminateOnlineAndReturnToMenu("timeout_forfeit")', 1, true) ~= nil, "guest timeout return-to-menu path missing")
end)

runTest("owner_identity_hydration_avoids_player_zero_fallback", function()
    local content = readFile("steam_runtime.lua")
    assertTrue(type(content) == "string", "steam_runtime.lua not readable")
    assertTrue(content:find('asString == "0"', 1, true) ~= nil, "steam id zero normalization guard missing")
end)


runTest("faction_sync_consumes_pending_lobby_events", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("consumePendingOnlineLobbyEvents", 1, true) ~= nil, "pending lobby event consume helper missing")
    assertTrue(content:find("session:handleLobbyEvent(lobbyEvent)", 1, true) ~= nil, "faction sync should pass queued lobby events into session handler")
end)

runTest("guest_ready_request_send_failure_does_not_mark_ready", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("if not sent then", 1, true) ~= nil, "guest ready send failure guard missing")
    assertTrue(content:find('clearPendingGuestReady("send_failed")', 1, true) ~= nil, "guest ready failure should clear pending state")
    assertTrue(content:find("return false", 1, true) ~= nil, "guest ready send failure should return false")
end)

runTest("guest_ready_sets_pending_until_ready_state", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("pendingGuestReady = desiredReady", 1, true) ~= nil, "pending guest ready assignment missing")
    assertTrue(content:find("pendingGuestReadySince = nowSeconds()", 1, true) ~= nil, "pending guest ready timestamp missing")
end)

runTest("ready_state_clears_pending_and_updates_both_flags", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("onlineReadyState.hostReady = payload.hostReady == true", 1, true) ~= nil, "ready_state host flag apply missing")
    assertTrue(content:find("onlineReadyState.guestReady = payload.guestReady == true", 1, true) ~= nil, "ready_state guest flag apply missing")
    assertTrue(content:find('clearPendingGuestReady("ready_state")', 1, true) ~= nil, "ready_state should clear pending guest ready")
end)

runTest("ready_packets_include_session_id", function()
    local session = SteamOnlineSession.new({localUserId = "local"})
    session.sessionId = "sess-ready"
    local l = SteamLockstep.new({session = session})

    local sent = {}
    l.sendPacket = function(self, packet, channel)
        sent[#sent + 1] = packet
        return true
    end

    local okReq = l:sendReadyRequest(true, 1)
    local okState = l:sendReadyState(true, false, 2)
    assertTrue(okReq == true and okState == true, "ready packet sends should succeed")
    assertTrue(sent[1] and sent[1].sessionId == "sess-ready", "READY_REQUEST must include sessionId")
    assertTrue(sent[2] and sent[2].sessionId == "sess-ready", "READY_STATE must include sessionId")
end)

runTest("snapshot_local_missing_uses_grace_before_disconnect", function()
    local s = SteamOnlineSession.new({localUserId = "host"})
    s.active = true
    s.role = "host"
    s.connected = true
    s.peerUserId = "guest"
    s.localPresentInLobby = true
    s.localLastSeenAt = 100
    s.peerLastSeenAt = 100
    s.peerStableSince = 100

    local savedNow = love and love.timer and love.timer.getTime
    love = love or {}
    love.timer = love.timer or {}
    love.timer.getTime = function()
        return 101
    end

    local ok = s:applyLobbySnapshot({
        lobbyId = "l4",
        ownerId = "host",
        members = {"guest"}
    })

    if savedNow then
        love.timer.getTime = savedNow
    end

    assertTrue(ok == true, "snapshot apply should succeed")
    assertTrue(s.disconnectReason ~= "local_missing_from_lobby", "local missing should be grace-protected")
end)

runTest("faction_ready_cards_removed_and_button_visual_state_used", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("drawOnlineReadyCards", 1, true) == nil, "ready card renderer should be removed")
    assertTrue(content:find("local function resolveButtonVisualState", 1, true) ~= nil, "button visual state resolver missing")
    assertTrue(content:find("button_ready_active", 1, true) == nil, "legacy ready-card state alias should not exist")
end)

runTest("faction_legacy_ready_dot_text_removed", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('"Host: " .. hostStateText', 1, true) == nil, "legacy host ready text should be removed")
    assertTrue(content:find('"Guest: " .. guestStateText', 1, true) == nil, "legacy guest ready text should be removed")
    assertTrue(content:find('love.graphics.rectangle("fill", SETTINGS.DISPLAY.WIDTH / 2 - 62', 1, true) == nil, "legacy host ready square should be removed")
    assertTrue(content:find('love.graphics.rectangle("fill", SETTINGS.DISPLAY.WIDTH / 2 + 188', 1, true) == nil, "legacy guest ready square should be removed")
end)

runTest("faction_ready_visual_states_use_existing_ready_flags", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("onlineReadyState.hostReady", 1, true) ~= nil, "host ready flag usage missing")
    assertTrue(content:find("onlineReadyState.guestReady", 1, true) ~= nil, "guest ready flag usage missing")
    assertTrue(content:find("pendingGuestReady", 1, true) ~= nil, "pending guest ready usage missing")
    assertTrue(content:find("BUTTON_STYLE_COLORS.ready", 1, true) ~= nil, "ready button visual state color missing")
    assertTrue(content:find("BUTTON_STYLE_COLORS.disabled", 1, true) ~= nil, "disabled start visual state color missing")
end)

runTest("faction_start_disabled_style_has_no_x_overlay", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("disabledVisual == true", 1, true) ~= nil, "disabled visual state guard missing")
    assertTrue(content:find("love.graphics.line(button.x + 10", 1, true) == nil, "disabled X overlay should be removed")
    assertTrue(content:find("love.graphics.line(button.x + button.width - 10", 1, true) == nil, "disabled X overlay should be removed")
end)

runTest("host_start_remains_disabled_while_guest_pending", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("return session.connected == true", 1, true) ~= nil, "host start gate should require connected session")
    assertTrue(content:find("peerOnlineRatingProfile ~= nil", 1, true) ~= nil, "host start gate should stay disabled until peer rating snapshot exists")
    assertTrue(content:find("if buttonKey == \"start\" then", 1, true) ~= nil, "start button visual handling missing")
end)

runTest("faction_online_selector_labels_use_steam_names_without_role_prefix", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('label = "Host: " .. tostring(hostName)', 1, true) == nil, "host role prefix should be removed from selector label")
    assertTrue(content:find('label = "Guest: " .. tostring(guestName)', 1, true) == nil, "guest role prefix should be removed from selector label")
    assertTrue(content:find('label = tostring(hostName)', 1, true) ~= nil, "host selector should use direct name label")
    assertTrue(content:find('label = tostring(guestName)', 1, true) ~= nil, "guest selector should use direct name label")
end)


runTest("ready_telemetry_logs_on_state_change", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("logReadyTelemetryState", 1, true) ~= nil, "ready telemetry helper missing")
    assertTrue(content:find("Ready telemetry", 1, true) ~= nil, "ready telemetry log line missing")
end)


runTest("online_setup_payload_uses_seat_assignment_not_local_controller_ids", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("seatAssignment", 1, true) ~= nil, "seatAssignment payload field missing")
    assertTrue(content:find("getSeatRoleFromOption", 1, true) ~= nil, "seat role resolver missing")
end)

runTest("online_apply_setup_payload_resolves_host_guest_seats_consistently", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("setSelectorBySeatRole", 1, true) ~= nil, "seat-based selector apply helper missing")
    assertTrue(content:find("resolveOnlineControllerBySeatRole", 1, true) ~= nil, "seat-to-controller resolver missing")
    assertTrue(content:find("seat_host", 1, true) ~= nil and content:find("seat_guest", 1, true) ~= nil, "seat option ids missing")
end)

runTest("guest_ready_pending_blocks_retoggle_until_ready_state", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    local hasLegacyGate = content:find('session.role == "guest" and pendingGuestReady ~= nil', 1, true) ~= nil
    local hasResolvedGate = content:find('syncResolvedOnlineRole(session) == "guest" and pendingGuestReady ~= nil', 1, true) ~= nil
    assertTrue(hasLegacyGate or hasResolvedGate, "guest pending debounce gate missing")
    assertTrue(content:find("Guest ready toggle ignored while pending confirmation", 1, true) ~= nil, "pending retoggle log missing")
end)

runTest("ready_state_ack_clears_guest_pending_once", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('clearPendingGuestReady("ready_state")', 1, true) ~= nil, "ready_state must clear pending guest ready")
end)

runTest("gameplay_validate_command_accepts_setup_phase_actions", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("placeNeutralBuilding", 1, true) ~= nil, "validateCommand setup action placeNeutralBuilding missing")
    assertTrue(content:find("placeAllNeutralBuildings", 1, true) ~= nil, "validateCommand setup action placeAllNeutralBuildings missing")
    assertTrue(content:find("placeCommandHub", 1, true) ~= nil, "validateCommand setup action placeCommandHub missing")
    assertTrue(content:find("confirmCommandHub", 1, true) ~= nil, "validateCommand setup action confirmCommandHub missing")
    assertTrue(content:find("confirmDeployment", 1, true) ~= nil, "validateCommand setup action confirmDeployment missing")
end)

runTest("game_ruler_place_neutral_building_dispatch_target_is_valid", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")
    assertTrue(content:find('return self:placeNeutralBuilding(params.row, params.col)', 1, true) ~= nil, "performAction dispatch should target placeNeutralBuilding")
    assertTrue(content:find('return self:placeAllNeutralBuilding(params.row, params.col)', 1, true) == nil, "legacy typo dispatch should not remain")
end)

runTest("online_faction_assignment_not_both_local_after_setup_sync", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("if controller1.id == controller2.id then", 1, true) ~= nil, "online assignment must reject same-controller seats")
    assertTrue(content:find("Online seat assignment -> F1:", 1, true) ~= nil, "online seat assignment mapping log missing")
end)

runTest("online_faction_back_terminates_session_and_clears_runtime_state", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("terminateOnlineFactionAndReturnToMainMenu", 1, true) ~= nil, "online faction terminate helper missing")
    assertTrue(content:find('lockstep:sendPacket({', 1, true) ~= nil and content:find('kind = "MATCH_ABORT"', 1, true) ~= nil, "online back should send MATCH_ABORT")
    assertTrue(content:find("session:leave()", 1, true) ~= nil, "online back should leave session")
    assertTrue(content:find("clearOnlineRuntimeState", 1, true) ~= nil, "online back should clear runtime state")
end)

runTest("host_ignores_remote_setup_snapshots", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("Ignoring remote setup snapshot %(host authoritative setup%)") ~= nil, "host-authoritative setup guard missing")
end)

runTest("ready_state_packet_carries_setup_revision", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.role = "host"
    hostSession.sessionId = "ready-setup-1"
    hostSession.peerUserId = "guest"

    local guestSession = SteamOnlineSession.new({localUserId = "guest"})
    guestSession.active = true
    guestSession.role = "guest"
    guestSession.sessionId = "ready-setup-1"
    guestSession.peerUserId = "host"

    local host = SteamLockstep.new({session = hostSession})
    local guest = SteamLockstep.new({session = guestSession})
    wireLocksteps(host, guest)

    local ok = host:sendReadyState(true, false, 7, 3)
    assertTrue(ok == true, "ready state send should succeed")

    local event = guest:pollEvent()
    assertTrue(event and event.kind == "ready_state", "guest must receive ready_state")
    assertTrue(event.payload and event.payload.setupRevision == 3, "ready_state must carry setupRevision")
end)

runTest("prematch_hello_ack_sets_transport_ready", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.role = "host"
    hostSession.sessionId = "prematch-1"
    hostSession.peerUserId = "guest"

    local guestSession = SteamOnlineSession.new({localUserId = "guest"})
    guestSession.active = true
    guestSession.role = "guest"
    guestSession.sessionId = "prematch-1"
    guestSession.peerUserId = "host"

    local host = SteamLockstep.new({session = hostSession})
    local guest = SteamLockstep.new({session = guestSession})
    wireLocksteps(host, guest)

    local okHello = host:sendPrematchHello(2, 11)
    assertTrue(okHello == true, "prematch hello send failed")

    local hello = guest:pollEvent()
    assertTrue(hello and hello.kind == "prematch_hello", "guest should receive prematch_hello")
    assertTrue((hello.payload or {}).nonce == 11, "prematch hello nonce mismatch")

    local okAck = guest:sendPrematchAck(2, 11)
    assertTrue(okAck == true, "prematch ack send failed")

    local ack = host:pollEvent()
    assertTrue(ack and ack.kind == "prematch_ack", "host should receive prematch_ack")
    assertTrue((ack.payload or {}).nonce == 11, "prematch ack nonce mismatch")
end)

runTest("ready_disabled_until_transport_ready", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("if prematchTransportReady ~= true then", 1, true) ~= nil, "ready toggle gate must require prematch transport ready")
end)

runTest("coalesced_broadcast_limits_send_frequency", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("BROADCAST_FLUSH_INTERVAL_SEC = 0.15", 1, true) ~= nil, "broadcast flush interval missing")
    assertTrue(content:find("pendingSetupSnapshot", 1, true) ~= nil, "pending setup snapshot queue missing")
    assertTrue(content:find("pendingReadyState", 1, true) ~= nil, "pending ready state queue missing")
    assertTrue(content:find("flushPendingHostBroadcasts", 1, true) ~= nil, "host broadcast flush helper missing")
end)

runTest("guest_back_sends_abort_and_returns_main_menu", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('kind = "MATCH_ABORT"', 1, true) ~= nil, "guest back path must send MATCH_ABORT")
    assertTrue(content:find("terminateOnlineFactionAndReturnToMainMenu", 1, true) ~= nil, "guest back terminate helper missing")
end)

runTest("host_on_guest_abort_shows_disconnect_dialog_and_returns_main_menu", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("showFactionDisconnectDialogAndExit", 1, true) ~= nil, "host abort path should route via disconnect dialog helper")
    assertTrue(content:find('reasonCode or "peer_disconnect"', 1, true) ~= nil, "disconnect helper should terminate to main menu")
    assertTrue(content:find('stateMachineRef.changeState("mainMenu")', 1, true) ~= nil, "faction abort should return to main menu")
end)


runTest("gameplay_active_match_ignores_snapshot_flap_as_primary_disconnect_signal", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("local usesSnapshotAuthority = onlineSession.lobbyId and not onlineSession.matchStarted", 1, true) ~= nil, "active-match snapshot authority gate missing")
end)

runTest("session_note_peer_traffic_prevents_false_pause", function()
    local s = SteamOnlineSession.new({localUserId = "host"})
    s.active = true
    s.role = "host"
    s.peerUserId = "guest"
    s.connected = false
    s.disconnectDeadline = 123
    s.disconnectReason = "peer_traffic_stale"

    local ok = s:notePeerTraffic("guest")
    assertTrue(ok == true, "notePeerTraffic should accept valid peer traffic")
    assertTrue(s.connected == true, "notePeerTraffic should restore connected state")
    assertTrue(s.disconnectDeadline == nil, "notePeerTraffic should clear reconnect deadline")
    assertTrue(s.disconnectReason == nil, "notePeerTraffic should clear disconnect reason")
end)

runTest("end_turn_success_not_coupled_to_next_turn_boolean_branch", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('elseif actionType == "end_turn" then', 1, true) ~= nil, "end_turn command branch missing")
    assertTrue(content:find('gameRuler:nextTurn()', 1, true) ~= nil, "end_turn should call gameRuler:nextTurn")
    assertTrue(content:find('return true', 1, true) ~= nil, "end_turn branch should return success")
end)

runTest("online_actions_complete_auto_end_turn_waits_for_animations", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('local onlineAutoAdvanceState = {', 1, true) ~= nil, "online auto advance state missing")
    assertTrue(content:find('and gameRuler:areActionsComplete()', 1, true) ~= nil, "auto end-turn should require completed actions")
    assertTrue(content:find('and not gameRuler:isAnimationInProgress()', 1, true) ~= nil, "auto end-turn should wait for animations")
    assertTrue(content:find('executeOrQueueCommand({ actionType = "end_turn" })', 1, true) ~= nil, "auto end-turn should reuse the normal online end-turn command")
    assertTrue(content:find('"auto_actions_complete"', 1, true) ~= nil, "auto end-turn source marker missing")
end)

runTest("online_setup_and_deployment_auto_advance_use_normal_commands", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('actionType = "placeAllNeutralBuildings"', 1, true) ~= nil, "setup auto advance should place random rocks")
    assertTrue(content:find('"auto_setup_rocks"', 1, true) ~= nil, "setup auto advance source marker missing")
    assertTrue(content:find('actionType = "confirmDeployment"', 1, true) ~= nil, "deployment auto advance should confirm deployment")
    assertTrue(content:find('"auto_deployment_complete"', 1, true) ~= nil, "deployment auto advance source marker missing")
end)

runTest("apply_command_failure_reports_hash_and_does_not_force_abort", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('onlineLockstep:reportLocalStateHash(payload.commandId or payload.seq, signature)', 1, true) ~= nil, "apply path must always report local state hash")
    assertTrue(content:find('ACTION_APPLY_REJECTED commandId=%s proposer=%s seq=%s action=%s reason=%s row=%s col=%s unitIndex=%s', 1, true) ~= nil, "apply rejection telemetry must include command context")
    assertTrue(content:find('onlineLockstep:abort("command_apply_failed")', 1, true) == nil, "apply failure should not hard-abort immediately")
end)

runTest("turn_switch_local_control_flips_between_host_and_guest", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("emitOnlineTurnTelemetry", 1, true) ~= nil, "turn ownership telemetry helper missing")
    assertTrue(content:find("TURN_OWNER player=", 1, true) ~= nil, "turn ownership telemetry log missing")
    assertTrue(content:find("isCurrentTurnLocallyControlled()", 1, true) ~= nil, "local turn control check missing")
end)

runTest("no_regression_faction_ready_and_match_start_sync", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('event.kind == "ready_state"', 1, true) ~= nil, "ready_state handler missing")
    assertTrue(content:find('event.kind == "match_start"', 1, true) ~= nil, "match_start handler missing")
    assertTrue(content:find('stateMachineRef.changeState("gameplay")', 1, true) ~= nil, "match_start gameplay transition missing")
end)


runTest("online_deploy_unit_near_hub_payload_includes_unit_index", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('actionType = "deployUnitNearHub"', 1, true) ~= nil, "deployUnitNearHub action payload missing")
    assertTrue(content:find('unitIndex = selectionIndex', 1, true) ~= nil, "deployUnitNearHub payload must include unitIndex")
end)

runTest("game_ruler_deploy_unit_near_hub_uses_payload_unit_index_when_present", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")
    assertTrue(content:find('return self:deployUnitNearHub(params.row, params.col, params.unitIndex)', 1, true) ~= nil, "performAction dispatch must pass unitIndex")
    assertTrue(content:find('function gameRuler:deployUnitNearHub(row, col, unitIndex)', 1, true) ~= nil, "deployUnitNearHub signature must accept unitIndex")
    assertTrue(content:find('local resolvedUnitIndex = tonumber(unitIndex)', 1, true) ~= nil, "deployUnitNearHub should resolve payload unit index")
end)

runTest("remote_deploy_unit_near_hub_applies_without_local_selection_state", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")
    assertTrue(content:find('resolvedUnitIndex = self.initialDeployment.selectedUnitIndex', 1, true) ~= nil, "legacy selected index fallback missing")
    assertTrue(content:find('local selectedUnit = playerSupply[unitIndex]', 1, true) ~= nil, "resolved unit index should drive supply lookup")
end)

runTest("online_phase_button_hidden_when_turn_not_local", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find('self:isOnlineNonLocalTurn(phaseInfo)', 1, true) ~= nil, "phase button online local-turn gate missing")
end)

runTest("online_supply_arrows_hidden_when_turn_not_local", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find('self:isOnlineNonLocalTurn({currentPlayer = gameRuler.currentPlayer})', 1, true) ~= nil, "supply arrows online local-turn gate missing")
end)

runTest("online_unit_action_arrows_hidden_when_turn_not_local", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    local count = 0
    local start = 1
    while true do
        local i = content:find('self:isOnlineNonLocalTurn({currentPlayer = gameRuler.currentPlayer})', start, true)
        if not i then
            break
        end
        count = count + 1
        start = i + 1
    end
    assertTrue(count >= 2, "both supply and action arrow online local-turn gates should exist")
end)

runTest("no_abort_on_valid_remote_initial_deploy_command", function()
    local gameplayContent = readFile("gameplay.lua")
    assertTrue(type(gameplayContent) == "string", "gameplay.lua not readable")
    assertTrue(gameplayContent:find('return params.row and params.col and (params.unitIndex ~= nil or hasLegacySelection)', 1, true) ~= nil, "online validator must accept deployUnitNearHub with payload unit index")
    assertTrue(gameplayContent:find('ACTION_APPLY_REJECTED commandId=%s proposer=%s seq=%s action=%s reason=%s row=%s col=%s unitIndex=%s', 1, true) ~= nil, "apply rejection diagnostics should include deploy command context")
end)

runTest("turn_handoff_p1_to_p2_preserves_local_control_switch", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('if commandAction == "end_turn" then', 1, true) ~= nil, "end_turn handoff branch missing")
    assertTrue(content:find('"[OnlineGameplay] TURN_HANDOFF prev=%s next=%s localTurn=%s"', 1, true) ~= nil, "turn handoff telemetry missing")
end)

runTest("lockstep_command_id_prevents_seq_collision_desync", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.sessionId = "cid-1"
    hostSession.peerUserId = "guest"

    local guestSession = SteamOnlineSession.new({localUserId = "guest"})
    guestSession.active = true
    guestSession.sessionId = "cid-1"
    guestSession.peerUserId = "host"

    local host = SteamLockstep.new({session = hostSession, validateCommand = function() return true end})
    local guest = SteamLockstep.new({session = guestSession, validateCommand = function() return true end})
    wireLocksteps(host, guest)

    local okA, seqA = host:proposeAction({actionType = "placeCommandHub", params = {row = 1, col = 1}}, {})
    assertTrue(okA == true and seqA == 1, "host first propose should use seq 1")

    while true do
        local evt = host:pollEvent()
        if not evt then break end
        if evt.kind == "apply_command" then
            host:reportLocalStateHash(evt.payload.commandId or evt.payload.seq, {owner = "host", commandId = evt.payload.commandId})
        end
    end
    while true do
        local evt = guest:pollEvent()
        if not evt then break end
        if evt.kind == "apply_command" then
            guest:reportLocalStateHash(evt.payload.commandId or evt.payload.seq, {owner = "host", commandId = evt.payload.commandId})
        end
    end

    local okB, seqB = guest:proposeAction({actionType = "placeCommandHub", params = {row = 2, col = 2}}, {})
    assertTrue(okB == true and seqB == 1, "guest first propose should also use seq 1")

    while true do
        local evt = guest:pollEvent()
        if not evt then break end
        if evt.kind == "apply_command" then
            guest:reportLocalStateHash(evt.payload.commandId or evt.payload.seq, {owner = "guest", commandId = evt.payload.commandId})
        end
    end
    while true do
        local evt = host:pollEvent()
        if not evt then break end
        if evt.kind == "apply_command" then
            host:reportLocalStateHash(evt.payload.commandId or evt.payload.seq, {owner = "guest", commandId = evt.payload.commandId})
        end
    end

    assertTrue(host:isAborted() == false, "host should not abort on overlapping seq values from different proposers")
    assertTrue(guest:isAborted() == false, "guest should not abort on overlapping seq values from different proposers")
end)

runTest("action_packets_include_session_and_command_identity", function()
    local content = readFile("steam_lockstep.lua")
    assertTrue(type(content) == "string", "steam_lockstep.lua not readable")
    assertTrue(content:find('commandId =', 1, true) ~= nil, "commandId must be present in action packets")
    assertTrue(content:find('proposerId =', 1, true) ~= nil, "proposerId must be present in action packets")
    assertTrue(content:find('sessionId = self.session and self.session.sessionId or nil', 1, true) ~= nil, "sessionId must be present in action/control packets")
end)

runTest("state_hash_matches_by_command_id_not_seq_only", function()
    local content = readFile("steam_lockstep.lua")
    assertTrue(type(content) == "string", "steam_lockstep.lua not readable")
    assertTrue(content:find('self.pendingStateHash[identity.commandId]', 1, true) ~= nil, "state hash lookup must use commandId")
    assertTrue(content:find('self.pendingStateHash[normalized.commandId] = hash', 1, true) ~= nil, "local state hash must store by commandId")
end)

runTest("legacy_packet_without_command_id_derives_identity_from_peer", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.sessionId = "legacy-1"
    hostSession.peerUserId = "guest"

    local host = SteamLockstep.new({session = hostSession, validateCommand = function() return true end})
    host:handlePacket({
        kind = "ACTION_PROPOSE",
        sessionId = "legacy-1",
        seq = 7,
        command = {actionType = "end_turn"},
        context = {}
    }, {peerId = "guest"})

    local event = host:pollEvent()
    assertTrue(event == nil, "legacy propose should not emit apply until commit")

    host:handlePacket({
        kind = "ACTION_COMMIT",
        sessionId = "legacy-1",
        seq = 7,
        command = {actionType = "end_turn"},
        context = {}
    }, {peerId = "guest"})

    local applied = host:pollEvent()
    assertTrue(applied and applied.kind == "apply_command", "legacy commit should still apply")
    assertTrue((applied.payload or {}).commandId == "guest:7", "legacy identity should derive commandId from peer+seq")
end)

runTest("non_local_turn_action_text_uses_controller_name", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find('if self:isOnlineNonLocalTurn(phaseInfo) then', 1, true) ~= nil, "online non-local turn gate missing in action description")
    assertTrue(content:find('text = string.format("%s turn", ownerName)', 1, true) ~= nil, "non-local action text should show owner name turn")
end)

runTest("game_over_online_winner_uses_controller_name", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find('winnerName = self:getFactionDisplayName(winnerIndex, "Player " .. tostring(winnerIndex))', 1, true) ~= nil, "winner name should resolve from controller")
    assertTrue(content:find('winnerText = winnerName .. " Wins!"', 1, true) ~= nil, "winner banner should use controller name")
end)

runTest("game_over_stats_headers_use_controller_names", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find('local p1DisplayName = self:truncateDisplayName(self:getFactionDisplayName(1, "Player 1"), 16)', 1, true) ~= nil, "player 1 stats name should come from controller")
    assertTrue(content:find('local p2DisplayName = self:truncateDisplayName(self:getFactionDisplayName(2, "Player 2"), 16)', 1, true) ~= nil, "player 2 stats name should come from controller")
    assertTrue(content:find('local p1Label = self:truncateDisplayName(self:getFactionDisplayName(1, "Player 1"), 22)', 1, true) ~= nil, "comparison header should use controller name")
end)

runTest("stale_traffic_grace_prevents_immediate_disconnect_at_match_start", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('ONLINE_TRAFFIC_STALE_GRACE_SEC', 1, true) ~= nil, "stale-traffic grace constant missing")
    assertTrue(content:find('onlineMatchTrafficGraceUntil = getOnlineNowSeconds() + ONLINE_TRAFFIC_STALE_GRACE_SEC', 1, true) ~= nil, "match-start stale grace initialization missing")
    assertTrue(content:find('local staleAllowed = (onlineMatchTrafficGraceUntil == nil) or (now >= onlineMatchTrafficGraceUntil)', 1, true) ~= nil, "stale check should honor grace window")
end)

runTest("online_surrender_is_sent_via_lockstep_command", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.sessionId = "surrender-1"
    hostSession.peerUserId = "guest"

    local guestSession = SteamOnlineSession.new({localUserId = "guest"})
    guestSession.active = true
    guestSession.sessionId = "surrender-1"
    guestSession.peerUserId = "host"

    local host = SteamLockstep.new({session = hostSession, validateCommand = function() return true end})
    local guest = SteamLockstep.new({session = guestSession, validateCommand = function() return true end})
    wireLocksteps(host, guest)

    local ok = host:proposeAction({
        actionType = "surrender",
        params = {surrenderingPlayer = 1}
    }, {turn = 3, phase = "turn", turnPhase = "actions", player = 1})
    assertTrue(ok == true, "surrender propose should succeed")

    local hostApplied = host:pollEvent()
    local guestApplied = guest:pollEvent()
    assertTrue(hostApplied and hostApplied.kind == "apply_command", "host should apply surrender command")
    assertTrue(guestApplied and guestApplied.kind == "apply_command", "guest should apply surrender command")
    assertTrue(hostApplied.payload and hostApplied.payload.command and hostApplied.payload.command.actionType == "surrender", "host applied action must be surrender")
    assertTrue(guestApplied.payload and guestApplied.payload.command and guestApplied.payload.command.actionType == "surrender", "guest applied action must be surrender")
end)

runTest("remote_surrender_moves_host_to_gameover_without_waiting_timeout", function()
    local gameplayContent = readFile("gameplay.lua")
    local uiContent = readFile("uiClass.lua")
    assertTrue(type(gameplayContent) == "string", "gameplay.lua not readable")
    assertTrue(type(uiContent) == "string", "uiClass.lua not readable")

    assertTrue(gameplayContent:find('actionType == "surrender"', 1, true) ~= nil, "gameplay surrender action handler missing")
    assertTrue(gameplayContent:find('gameRuler:setPhase("gameOver")', 1, true) ~= nil, "surrender should transition to gameOver")
    assertTrue(gameplayContent:find('actionType = "surrender"', 1, true) ~= nil, "ui surrender request should enqueue online surrender command")
    assertTrue(uiContent:find('if type(self.onSurrenderRequested) == "function" then', 1, true) ~= nil, "ui surrender callback integration missing")
    assertTrue(uiContent:find('if GAME and GAME.CURRENT and GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET then', 1, true) ~= nil, "online surrender local fallback guard missing")
end)

runTest("disconnect_timeout_in_gameplay_sets_forfeit_and_gameover", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find('finalizeOnlineMatchEnd("timeout_forfeit"', 1, true) ~= nil, "timeout forfeit finalizer missing")
    assertTrue(content:find('setGameOver = true', 1, true) ~= nil, "timeout forfeit should move to gameOver")
    assertTrue(content:find('if not gameOverPhase then', 1, true) ~= nil, "disconnect checks should be gated outside gameOver phase")
end)

runTest("gameplay_consumes_pending_lobby_events_during_online_match", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("consumePendingOnlineGameplayLobbyEvents", 1, true) ~= nil, "gameplay pending lobby event consumer missing")
    assertTrue(content:find("onlineSession:handleLobbyEvent(event)", 1, true) ~= nil, "gameplay should apply queued lobby events to session")
end)

runTest("broken_online_session_routes_to_main_menu_notice_instead_of_sticking", function()
    local gameplayContent = readFile("gameplay.lua")
    local menuContent = readFile("mainMenu.lua")
    assertTrue(type(gameplayContent) == "string", "gameplay.lua not readable")
    assertTrue(type(menuContent) == "string", "mainMenu.lua not readable")
    assertTrue(gameplayContent:find("returnBrokenOnlineMatchToMainMenu", 1, true) ~= nil, "main-menu failsafe helper missing")
    assertTrue(gameplayContent:find('Online match connection was lost. Returning to main menu.', 1, true) ~= nil, "failsafe notice copy missing")
    assertTrue(menuContent:find("MAIN_MENU_ONE_SHOT_NOTICE", 1, true) ~= nil, "main menu one-shot notice consumption missing")
end)

runTest("online_lobby_event_consumption_rechecks_gameplay_state_before_gameover_deref", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("local consumedLobbyEvents = consumePendingOnlineGameplayLobbyEvents()", 1, true) ~= nil, "gameplay should cache pending lobby-event consumption")
    assertTrue(content:find("if not isOnlineModeActive() or not gameRuler then", 1, true) ~= nil, "gameplay should recheck state after consuming lobby events")
end)

runTest("online_escape_broken_session_skips_unusable_concede_dialog", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("canOfferOnlineConcede", 1, true) ~= nil, "online concede health gate missing")
    assertTrue(content:find('escape_broken_session', 1, true) ~= nil, "broken session escape recovery path missing")
end)

runTest("surrender_failure_in_broken_online_state_triggers_recovery", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("SURRENDER_REQUEST_FAILED", 1, true) ~= nil, "surrender failure log missing")
    assertTrue(content:find("finalizeBrokenOnlineMatchIfPossible(\"surrender_failed\"", 1, true) ~= nil, "surrender failure should resolve or recover")
end)

runTest("strike_removed_when_no_legal_attack_targets", function()
    local content = readFile("gameRuler.lua")
    assertTrue(type(content) == "string", "gameRuler.lua not readable")
    assertTrue(content:find('function gameRuler:isLegalAttackTarget', 1, true) ~= nil, "shared legal attack helper missing")
    assertTrue(content:find('if self:unitHasValidAttacks(row, col) then', 1, true) ~= nil, "action list should use legal attack helper")
    assertTrue(content:find('table.insert(actions, "STRIKE")', 1, true) ~= nil, "strike list insertion missing")
end)

runTest("unit_action_arrow_hidden_when_attack_not_legal", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find('local hasLegalActions = gameRuler:unitHasLegalActions(row, col)', 1, true) ~= nil, "unit helper arrows must use legal-action gate")
    assertTrue(content:find('if hasLegalActions then', 1, true) ~= nil, "unit helper arrow draw should be gated by legal actions")
end)

runTest("invite_accept_guest_auto_transitions_to_faction_select", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find('if handled == "lobby_joined" then', 1, true) ~= nil, "guest join transition event handling missing")
    assertTrue(content:find("joinInFlight = false", 1, true) ~= nil, "joinInFlight should clear on lobby_joined")
    assertTrue(content:find("enterFactionSelectOnline()", 1, true) ~= nil, "faction auto-transition call missing")
end)

runTest("online_lobby_guest_does_not_get_disabled_dead_end_state", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("peerTransitionEligibleSince", 1, true) ~= nil, "guest transition fallback timer missing")
    assertTrue(content:find("Faction transition fallback", 1, true) ~= nil, "guest transition fallback log missing")
end)

runTest("surrender_button_theme_uses_local_faction_not_turn_owner", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find("resolveSurrenderFactionId", 1, true) ~= nil, "local surrender faction resolver missing")
    assertTrue(content:find("local surrenderFaction = self:resolveSurrenderFactionId()", 1, true) ~= nil, "surrender theme should be based on local faction")
end)

runTest("online_surrender_allowed_when_not_local_turn", function()
    local uiContent = readFile("uiClass.lua")
    local gameplayContent = readFile("gameplay.lua")
    assertTrue(type(uiContent) == "string", "uiClass.lua not readable")
    assertTrue(type(gameplayContent) == "string", "gameplay.lua not readable")
    assertTrue(uiContent:find("handleOnlineNonLocalClick", 1, true) ~= nil, "ui non-local surrender click helper missing")
    assertTrue(gameplayContent:find("ui.handleOnlineNonLocalClick", 1, true) ~= nil, "gameplay should route non-local online clicks to surrender helper")
end)

runTest("faction_select_guest_shows_only_back_and_ready_buttons", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('[FACTION_UI_PROFILE.ONLINE_GUEST] = {"back", "ready"}', 1, true) ~= nil, "guest visible button set missing")
end)

runTest("faction_select_host_shows_back_random_ready_start_buttons", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('[FACTION_UI_PROFILE.ONLINE_HOST] = {"back", "random", "ready", "start"}', 1, true) ~= nil, "host visible button set missing")
end)


runTest("faction_single_local_buttons_centered_no_gap", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('[FACTION_UI_PROFILE.SINGLE_LOCAL] = {"back", "random", "start"}', 1, true) ~= nil, "single/local visible button set missing")
    assertTrue(content:find("for _, key in ipairs(BUTTON_VISIBILITY_ORDER) do", 1, true) ~= nil, "visible button pass-through order missing")
    assertTrue(content:find("totalWidth = #buttons * buttonWidth + (#buttons - 1) * gap", 1, true) ~= nil, "centered contiguous row width calculation missing")
end)


runTest("faction_online_host_buttons_centered_no_gap", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('[FACTION_UI_PROFILE.ONLINE_HOST] = {"back", "random", "ready", "start"}', 1, true) ~= nil, "online host visible button set missing")
    assertTrue(content:find('local BUTTON_LAYOUT = {', 1, true) ~= nil, "shared button layout table missing")
    assertTrue(content:find('local totalWidth = #buttons * buttonWidth + (#buttons - 1) * gap', 1, true) ~= nil, "host button row centering formula missing")
end)

runTest("faction_layout_uses_single_visible_button_source_for_draw_input_nav", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find('resolveFactionUiProfile', 1, true) ~= nil, "UI profile resolver missing")
    assertTrue(content:find('getVisibleButtonKeysForProfile', 1, true) ~= nil, "profile-based button key resolver missing")
    assertTrue(content:find('for _, buttonDef in ipairs(getVisibleButtons()) do', 1, true) ~= nil, "visible button iteration should drive draw/input")
    assertTrue(content:find('triggerFactionButtonAction(selectedButton.__key)', 1, true) ~= nil, "keyboard activation should route through unified button dispatcher")
end)

runTest("faction_uielements_declared_before_visible_button_helpers", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")

    local helperPos = content:find("local function ensureButtonDefinitions()", 1, true)
    local uiDeclPos = content:find("local uiElements = {}", 1, true)
    local navDeclPos = content:find("local navState = {", 1, true)
    assertTrue(helperPos ~= nil, "ensureButtonDefinitions helper missing")
    assertTrue(uiDeclPos ~= nil and uiDeclPos < helperPos, "uiElements local declaration must appear before button helpers")
    assertTrue(navDeclPos ~= nil and navDeclPos < helperPos, "navState local declaration must appear before button helpers")

    local _, uiDeclCount = content:gsub("local%s+uiElements%s*=", "")
    local _, navDeclCount = content:gsub("local%s+navState%s*=", "")
    assertTrue(uiDeclCount == 1, "uiElements must have exactly one local declaration")
    assertTrue(navDeclCount == 1, "navState must have exactly one local declaration")
end)

runTest("faction_select_button_row_reflows_when_buttons_hidden", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("refreshButtonLayout", 1, true) ~= nil, "button layout refresh helper missing")
    assertTrue(content:find("totalWidth = #buttons * buttonWidth + (#buttons - 1) * gap", 1, true) ~= nil, "dynamic button row width calculation missing")
end)

runTest("faction_hidden_buttons_not_focusable_or_clickable", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("button.visible = isVisible", 1, true) ~= nil, "button visibility assignment missing")
    assertTrue(content:find("if not button or button.visible == false then return false end", 1, true) ~= nil, "mouse hit-test must ignore hidden buttons")
    assertTrue(content:find("local buttons = getVisibleButtons()", 1, true) ~= nil, "navigation must use visible button list")
end)

runTest("online_lobby_visibility_button_removed", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("uiButtons.visibility", 1, true) == nil, "visibility button wiring should be removed")
    assertTrue(content:find("onToggleVisibility", 1, true) == nil, "visibility toggle handler should be removed")
end)

runTest("online_lobby_host_creation_prompts_visibility_choice", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("Choose lobby visibility.", 1, true) ~= nil, "host visibility prompt missing")
    assertTrue(content:find('title = "Lobby Visibility"', 1, true) ~= nil, "visibility dialog title missing")
    assertTrue(content:find('confirmText = "Friends Only"', 1, true) ~= nil, "Friends Only choice missing")
    assertTrue(content:find('cancelText = "Public"', 1, true) ~= nil, "Public choice missing")
    assertTrue(content:find("startHostLobbyWithVisibility", 1, true) ~= nil, "visibility create helper missing")
end)

runTest("online_lobby_entry_does_not_immediately_activate_host_button", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("ENTRY_ACTIVATION_GUARD_SEC", 1, true) ~= nil, "entry activation guard constant missing")
    assertTrue(content:find("isEntryActivationGuardActive", 1, true) ~= nil, "entry activation guard helper missing")
    assertTrue(content:find("lobbyEnterAt = nowSeconds()", 1, true) ~= nil, "online lobby enter timestamp missing")
end)

runTest("online_lobby_buttons_reflow_after_visibility_button_removal", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("local count = 5", 1, true) ~= nil, "online lobby button count should be 5")
    assertTrue(content:find("buttonOrder = {uiButtons.host, uiButtons.join, uiButtons.refresh, uiButtons.invite, uiButtons.back}", 1, true) ~= nil, "online lobby button row order mismatch")
end)

runTest("non_local_turn_action_panel_text_uses_owner_name_only", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find('text = string.format("%s turn", ownerName)', 1, true) ~= nil, "non-local action panel owner-turn text missing")
end)

runTest("faction_guest_hides_selector_arrows", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("local showSelectorArrows = canEditOnlineSetup()", 1, true) ~= nil, "guest arrow visibility gate missing")
    assertTrue(content:find("if showSelectorArrows then", 1, true) ~= nil, "selector arrow draw gate missing")
end)

runTest("friends_only_lobby_visible_when_tagged_even_if_relation_other", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find('entry.visibility == "public" or relation == "friend" or relation == "friend_of_friend"', 1, true) == nil, "friends visibility should not be relation-gated")
    assertTrue(content:find("AppID 480 relation metadata is not always reliable", 1, true) ~= nil, "tag-based visibility rationale comment missing")
end)

runTest("faction_role_resolution_does_not_depend_only_on_online_role_flag", function()
    local content = readFile("factionSelect.lua")
    assertTrue(type(content) == "string", "factionSelect.lua not readable")
    assertTrue(content:find("resolveOnlineRole", 1, true) ~= nil, "online role resolver helper missing")
    assertTrue(content:find("syncResolvedOnlineRole", 1, true) ~= nil, "online role sync helper missing")
end)

runTest("online_lobby_column_visibility_replaces_rel", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find('love.graphics.printf("Visibility"', 1, true) ~= nil, "Visibility column header missing")
    assertTrue(content:find('love.graphics.printf("Rel"', 1, true) == nil, "legacy Rel column should be removed")
end)

runTest("online_lobby_status_bar_above_buttons_removed", function()
    local content = readFile("onlineLobby.lua")
    assertTrue(type(content) == "string", "onlineLobby.lua not readable")
    assertTrue(content:find("love.graphics.printf(statusBarText", 1, true) == nil, "status bar text should not render above buttons")
end)

runTest("online_avatar_theme_uses_local_faction_not_turn_owner", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find("GAME.CURRENT.MODE == GAME.MODE.MULTYPLAYER_NET and GAME.getLocalFactionId", 1, true) ~= nil, "local faction avatar theme gate missing")
end)

runTest("remote_preview_select_shows_cells_on_non_local_client", function()
    local lockstepContent = readFile("steam_lockstep.lua")
    local gameplayContent = readFile("gameplay.lua")
    assertTrue(type(lockstepContent) == "string", "steam_lockstep.lua not readable")
    assertTrue(type(gameplayContent) == "string", "gameplay.lua not readable")
    assertTrue(lockstepContent:find("sendPreviewSelect", 1, true) ~= nil, "preview select sender missing")
    assertTrue(lockstepContent:find('kind = "PREVIEW_SELECT"', 1, true) ~= nil, "PREVIEW_SELECT packet kind missing")
    assertTrue(gameplayContent:find("applyRemotePreviewSelect", 1, true) ~= nil, "remote preview apply handler missing")
end)

runTest("remote_preview_clear_removes_cells", function()
    local lockstepContent = readFile("steam_lockstep.lua")
    local gameplayContent = readFile("gameplay.lua")
    assertTrue(type(lockstepContent) == "string", "steam_lockstep.lua not readable")
    assertTrue(type(gameplayContent) == "string", "gameplay.lua not readable")
    assertTrue(lockstepContent:find("sendPreviewClear", 1, true) ~= nil, "preview clear sender missing")
    assertTrue(lockstepContent:find('kind = "PREVIEW_CLEAR"', 1, true) ~= nil, "PREVIEW_CLEAR packet kind missing")
    assertTrue(gameplayContent:find("clearRemotePreviewVisual", 1, true) ~= nil, "remote preview clear handler missing")
end)

runTest("debug_console_log_overwrites_on_new_game_start", function()
    local mainContent = readFile("main.lua")
    local rulerContent = readFile("gameRuler.lua")
    assertTrue(type(mainContent) == "string", "main.lua not readable")
    assertTrue(type(rulerContent) == "string", "gameRuler.lua not readable")
    assertTrue(mainContent:find('require("debug_console_log")', 1, true) ~= nil, "debug console module require missing")
    assertTrue(mainContent:find("debugConsoleLog.init()", 1, true) ~= nil, "debug console init missing")
    assertTrue(rulerContent:find('debugConsoleLog.reset("new_game")', 1, true) ~= nil, "debug console reset on new game missing")
    assertTrue(rulerContent:find('debugConsoleLog.reset("reset_game")', 1, true) ~= nil, "debug console reset on reset_game missing")
end)

runTest("debug_console_log_contains_print_mirror_lines", function()
    local content = readFile("debug_console_log.lua")
    assertTrue(type(content) == "string", "debug_console_log.lua not readable")
    assertTrue(content:find("_G.print = function", 1, true) ~= nil, "global print wrapper missing")
    assertTrue(content:find("M.append(...)", 1, true) ~= nil, "print mirror append call missing")
end)

runTest("online_escape_prompts_concede_and_routes_to_surrender", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("Concede match? This will count as a forfeit.", 1, true) ~= nil, "online concede confirm copy missing")
    assertTrue(content:find("requestSurrenderFromUi()", 1, true) ~= nil, "online escape should route through surrender handler")
end)

runTest("elo_summary_close_handles_keyboard_mouse_and_gamepad_path", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("hasVisibleOnlineEloSummary()", 1, true) ~= nil, "rating visibility helper missing")
    assertTrue(content:find("handleOnlineEloSummaryClick", 1, true) ~= nil, "rating mouse close handler missing")
    assertTrue(content:find("isEloSummaryCloseKey", 1, true) ~= nil, "rating key close helper missing")
    assertTrue(content:find('button == "b" or button == "back"', 1, true) ~= nil, "gamepad close mapping should include cancel")
end)

runTest("elo_modal_click_outside_consumed", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("return true", content:find("handleOnlineEloSummaryClick", 1, true) or 1, true) ~= nil, "rating click handler should consume outside clicks")
end)

runTest("match_start_objective_modal_static_guard_present", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("hasVisibleMatchObjectiveModal", 1, true) ~= nil, "objective modal visibility helper missing")
    assertTrue(content:find("WIN CONDITIONS", 1, true) ~= nil, "objective modal copy missing")
    assertTrue(content:find("Orders Received", 1, true) ~= nil, "objective modal CTA missing")
end)

runTest("online_non_local_turn_allows_readonly_grid_navigation", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    local hasLegacyGate = content:find("allowOnlineReadOnly", 1, true) ~= nil
    local hasUnifiedGate = content:find("allowReadOnlyTurn", 1, true) ~= nil
    assertTrue(hasLegacyGate or hasUnifiedGate, "non-local online read-only gate missing")
end)

runTest("online_non_local_turn_allows_game_log_panel_open", function()
    local gameplayContent = readFile("gameplay.lua")
    local uiContent = readFile("uiClass.lua")
    assertTrue(type(gameplayContent) == "string", "gameplay.lua not readable")
    assertTrue(type(uiContent) == "string", "uiClass.lua not readable")
    assertTrue(gameplayContent:find("isReadOnlyUiControlName", 1, true) ~= nil, "non-local activation whitelist helper missing")
    assertTrue(uiContent:find("canClickGameLog", 1, true) ~= nil, "non-local mouse helper should allow game log panel")
end)

runTest("online_non_local_turn_still_blocks_command_execution", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("if not isCurrentTurnLocallyControlled() then", 1, true) ~= nil, "non-local action block missing")
end)

runTest("gameover_battlefield_view_hides_action_hint_panel_text", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find("battlefieldGameOverView", 1, true) ~= nil, "battlefield game-over mode guard missing")
    assertTrue(content:find("self:drawPhaseInfo", 1, true) ~= nil, "phase panel draw call missing")
end)

runTest("online_reaction_signal_roundtrip", function()
    local hostSession = SteamOnlineSession.new({localUserId = "host"})
    hostSession.active = true
    hostSession.role = "host"
    hostSession.sessionId = "reaction_session"
    hostSession.peerUserId = "guest"

    local guestSession = SteamOnlineSession.new({localUserId = "guest"})
    guestSession.active = true
    guestSession.role = "guest"
    guestSession.sessionId = "reaction_session"
    guestSession.peerUserId = "host"

    local host = SteamLockstep.new({session = hostSession})
    local guest = SteamLockstep.new({session = guestSession})
    wireLocksteps(host, guest)

    local ok = host:sendReactionSignal({
        reactionId = "good",
        senderFaction = 1,
        senderName = "HostUser"
    })
    assertTrue(ok == true, "sendReactionSignal should succeed")

    local event = guest:pollEvent()
    assertTrue(event and event.kind == "reaction_received", "guest should receive reaction event")
    assertTrue(event.payload.reactionId == "good", "reaction id should roundtrip")
    assertTrue(event.payload.senderFaction == 1, "sender faction should roundtrip")
    assertTrue(event.payload.senderName == "HostUser", "sender name should roundtrip")
end)

runTest("online_reaction_buttons_render_only_on_non_local_turn", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find("canShowOnlineReactionButtons", 1, true) ~= nil, "reaction visibility helper missing")
    assertTrue(content:find("drawOnlineReactionButtons", 1, true) ~= nil, "reaction button renderer missing")
    assertTrue(content:find("reactionButton_", 1, true) ~= nil, "reaction button ids missing")
end)

runTest("online_reaction_receive_shows_notification_with_sender_faction_direction", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find("showOnlineReactionNotification", 1, true) ~= nil, "reaction notification hook missing")
    assertTrue(content:find("senderFaction == 1", 1, true) ~= nil, "top-entry direction for blue sender missing")
    assertTrue(content:find("senderFaction == 2", 1, true) ~= nil, "bottom-entry direction for red sender missing")
end)

runTest("online_reaction_cooldown_disables_buttons_for_sender", function()
    local uiContent = readFile("uiClass.lua")
    local gameplayContent = readFile("gameplay.lua")
    assertTrue(type(uiContent) == "string", "uiClass.lua not readable")
    assertTrue(type(gameplayContent) == "string", "gameplay.lua not readable")
    assertTrue(uiContent:find("cooldownUntil", 1, true) ~= nil, "reaction cooldown state missing")
    assertTrue(uiContent:find("disabledVisual = cooldownActive", 1, true) ~= nil, "reaction disabled visual state missing")
    assertTrue(gameplayContent:find("ONLINE_REACTION_COOLDOWN_SEC", 1, true) ~= nil, "reaction cooldown constant missing")
end)

runTest("online_reaction_sender_local_echo_exists", function()
    local content = readFile("gameplay.lua")
    assertTrue(type(content) == "string", "gameplay.lua not readable")
    assertTrue(content:find("ui:showOnlineReactionNotification({", 1, true) ~= nil, "reaction sender local echo missing")
end)

runTest("online_reaction_final_copy_is_locked", function()
    local content = readFile("uiClass.lua")
    assertTrue(type(content) == "string", "uiClass.lua not readable")
    assertTrue(content:find('label = "GOOD"', 1, true) ~= nil, "GOOD label missing")
    assertTrue(content:find('message = "Well played!"', 1, true) ~= nil, "GOOD message missing")
    assertTrue(content:find('label = "ZZZ"', 1, true) ~= nil, "ZZZ label missing")
    assertTrue(content:find('message = "Boring..."', 1, true) ~= nil, "ZZZ message missing")
    assertTrue(content:find('label = "BAD"', 1, true) ~= nil, "BAD label missing")
    assertTrue(content:find('message = "Not fun!"', 1, true) ~= nil, "BAD message missing")
end)

runTest("invite_receive_prompt_flow_unchanged_regression", function()
    local content = readFile("stateMachine.lua")
    assertTrue(type(content) == "string", "stateMachine.lua not readable")
    assertTrue(content:find('eventType == "lobby_invite_received"', 1, true) ~= nil, "invite receive prompt hook missing")
    assertTrue(content:find('title = "Game Invite"', 1, true) ~= nil, "invite prompt dialog missing")
end)

runTest("online_invite_and_lobby_flow_unchanged_by_remote_play_input_work", function()
    local stateMachineContent = readFile("stateMachine.lua")
    local onlineLobbyContent = readFile("onlineLobby.lua")
    assertTrue(type(stateMachineContent) == "string", "stateMachine.lua not readable")
    assertTrue(type(onlineLobbyContent) == "string", "onlineLobby.lua not readable")
    assertTrue(stateMachineContent:find('eventType == "lobby_invite_received"', 1, true) ~= nil, "invite receive flow should remain present")
    assertTrue(stateMachineContent:find("processRemotePlayDirectInput", 1, true) ~= nil, "remote play direct input processor should be present")
    assertTrue(onlineLobbyContent:find("consumePendingInviteJoinLobbyId", 1, true) ~= nil, "online lobby invite-join consumer missing")
end)

runTest("online_prematch_exchange_includes_rating_profiles", function()
    local factionContent = readFile("factionSelect.lua")
    local lockstepContent = readFile("steam_lockstep.lua")
    assertTrue(factionContent:find("ensureLocalOnlineRatingProfileLoaded()", 1, true) ~= nil, "local online rating profile loader missing")
    assertTrue(factionContent:find("capturePeerOnlineRatingProfile(payload.ratingProfile)", 1, true) ~= nil, "peer rating profile capture missing")
    assertTrue(lockstepContent:find("ratingProfile = ratingProfile", 1, true) ~= nil, "prematch packets should carry rating profiles")
end)

runTest("online_gameplay_uses_glicko2_profile_update", function()
    local content = readFile("gameplay.lua")
    assertTrue(content:find("glicko2.computeNextProfile", 1, true) ~= nil, "gameplay should use glicko2 updates")
    assertTrue(content:find("onlineRatingStore.saveProfile(updatedLocal)", 1, true) ~= nil, "updated local profile should persist after online match")
    assertTrue(content:find("summary.ratingReason", 1, true) ~= nil, "online summary should expose ranked/unranked reason")
end)

local passed = 0
for _, result in ipairs(results) do
    if result.ok then
        passed = passed + 1
    end
end

print("# Steam Online Smoke Report")
print("")
print("- Passed: " .. tostring(passed))
print("- Failed: " .. tostring(#results - passed))
print("")

for _, result in ipairs(results) do
    local status = result.ok and "PASS" or "FAIL"
    print(string.format("- `%s` %s", status, result.name))
    if not result.ok then
        print("  - Error: " .. tostring(result.err))
    end
end

local failed = #results - passed
os.exit((failed == 0) and 0 or 1)
