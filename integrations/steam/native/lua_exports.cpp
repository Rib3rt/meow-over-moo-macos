extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

#include "steam_bridge.hpp"

#include <string>
#include <vector>

#if LUA_VERSION_NUM < 502 && !defined(luaL_newlib)
#define luaL_newlib(L, l) (lua_newtable((L)), luaL_register((L), NULL, (l)))
#endif

static SteamBridge g_bridge;

static std::string luaCheckString(lua_State* L, int index) {
    const char* value = luaL_checkstring(L, index);
    return value ? value : "";
}

static std::string luaOptString(lua_State* L, int index, const std::string& fallback = std::string()) {
    const char* value = luaL_optstring(L, index, fallback.c_str());
    return value ? value : fallback;
}

static bool tableGetBooleanField(lua_State* L, int index, const char* key, bool fallback) {
    bool value = fallback;
    lua_getfield(L, index, key);
    if (lua_isboolean(L, -1)) {
        value = lua_toboolean(L, -1) != 0;
    }
    lua_pop(L, 1);
    return value;
}

static std::string tableGetStringField(lua_State* L, int index, const char* key, const std::string& fallback = std::string()) {
    std::string value = fallback;
    lua_getfield(L, index, key);
    if (lua_isstring(L, -1)) {
        value = lua_tostring(L, -1);
    }
    lua_pop(L, 1);
    return value;
}

static void pushLobbyEvent(lua_State* L, const SteamLobbyEvent& event) {
    lua_newtable(L);

    lua_pushstring(L, event.type.c_str());
    lua_setfield(L, -2, "type");

    lua_pushstring(L, event.lobbyId.c_str());
    lua_setfield(L, -2, "lobbyId");

    lua_pushstring(L, event.ownerId.c_str());
    lua_setfield(L, -2, "ownerId");

    lua_pushstring(L, event.memberId.c_str());
    lua_setfield(L, -2, "memberId");

    lua_pushstring(L, event.result.c_str());
    lua_setfield(L, -2, "result");

    lua_pushinteger(L, event.memberState);
    lua_setfield(L, -2, "memberState");
}

static void pushLobbySnapshot(lua_State* L, const SteamLobbySnapshot& snapshot) {
    lua_newtable(L);

    lua_pushstring(L, snapshot.lobbyId.c_str());
    lua_setfield(L, -2, "lobbyId");

    lua_pushstring(L, snapshot.ownerId.c_str());
    lua_setfield(L, -2, "ownerId");

    lua_pushstring(L, snapshot.sessionId.c_str());
    lua_setfield(L, -2, "sessionId");

    lua_pushstring(L, snapshot.protocolVersion.c_str());
    lua_setfield(L, -2, "protocolVersion");

    lua_newtable(L);
    for (std::size_t i = 0; i < snapshot.members.size(); ++i) {
        lua_pushstring(L, snapshot.members[i].c_str());
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, -2, "members");
}

static void pushLobbyListEntry(lua_State* L, const SteamLobbyListEntry& entry) {
    lua_newtable(L);

    lua_pushstring(L, entry.lobbyId.c_str());
    lua_setfield(L, -2, "lobbyId");

    lua_pushstring(L, entry.ownerId.c_str());
    lua_setfield(L, -2, "ownerId");

    lua_pushstring(L, entry.ownerName.c_str());
    lua_setfield(L, -2, "ownerName");

    lua_pushinteger(L, entry.memberCount);
    lua_setfield(L, -2, "memberCount");

    lua_pushinteger(L, entry.memberLimit);
    lua_setfield(L, -2, "memberLimit");

    lua_pushstring(L, entry.sessionId.c_str());
    lua_setfield(L, -2, "sessionId");

    lua_pushstring(L, entry.protocolVersion.c_str());
    lua_setfield(L, -2, "protocolVersion");

    lua_pushstring(L, entry.relation.c_str());
    lua_setfield(L, -2, "relation");

    lua_pushboolean(L, entry.joinable ? 1 : 0);
    lua_setfield(L, -2, "joinable");
}

static void pushNetPacket(lua_State* L, const SteamNetPacket& packet) {
    lua_newtable(L);

    lua_pushstring(L, packet.peerId.c_str());
    lua_setfield(L, -2, "peerId");

    lua_pushinteger(L, packet.channel);
    lua_setfield(L, -2, "channel");

    lua_pushlstring(L, packet.payload.data(), packet.payload.size());
    lua_setfield(L, -2, "payload");

    lua_pushnumber(L, packet.recvTs);
    lua_setfield(L, -2, "recvTs");
}

static void pushLeaderboardEntry(lua_State* L, const SteamLeaderboardEntryRecord& entry) {
    lua_newtable(L);

    lua_pushstring(L, entry.userId.c_str());
    lua_setfield(L, -2, "userId");

    lua_pushinteger(L, entry.score);
    lua_setfield(L, -2, "score");

    lua_pushinteger(L, entry.rank);
    lua_setfield(L, -2, "rank");

    lua_newtable(L);
    for (std::size_t i = 0; i < entry.details.size(); ++i) {
        lua_pushinteger(L, entry.details[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, -2, "details");
}

static void pushRemotePlaySession(lua_State* L, const SteamRemotePlaySessionEntry& entry) {
    lua_newtable(L);

    lua_pushinteger(L, static_cast<lua_Integer>(entry.sessionId));
    lua_setfield(L, -2, "sessionId");

    lua_pushstring(L, entry.userId.c_str());
    lua_setfield(L, -2, "userId");

    lua_pushstring(L, entry.personaName.c_str());
    lua_setfield(L, -2, "personaName");

    lua_pushstring(L, entry.clientName.c_str());
    lua_setfield(L, -2, "clientName");
}

static void pushRemotePlayInputEvent(lua_State* L, const SteamRemotePlayInputEvent& event) {
    lua_newtable(L);

    lua_pushinteger(L, static_cast<lua_Integer>(event.sessionId));
    lua_setfield(L, -2, "sessionId");

    lua_pushstring(L, event.type.c_str());
    lua_setfield(L, -2, "type");

    lua_pushboolean(L, event.mouseAbsolute ? 1 : 0);
    lua_setfield(L, -2, "mouseAbsolute");

    lua_pushnumber(L, event.mouseNormalizedX);
    lua_setfield(L, -2, "mouseNormalizedX");

    lua_pushnumber(L, event.mouseNormalizedY);
    lua_setfield(L, -2, "mouseNormalizedY");

    lua_pushinteger(L, event.mouseDeltaX);
    lua_setfield(L, -2, "mouseDeltaX");

    lua_pushinteger(L, event.mouseDeltaY);
    lua_setfield(L, -2, "mouseDeltaY");

    lua_pushinteger(L, event.mouseButton);
    lua_setfield(L, -2, "mouseButton");

    lua_pushinteger(L, event.wheelDirection);
    lua_setfield(L, -2, "wheelDirection");

    lua_pushnumber(L, event.wheelAmount);
    lua_setfield(L, -2, "wheelAmount");

    lua_pushinteger(L, event.keyScancode);
    lua_setfield(L, -2, "keyScancode");

    lua_pushinteger(L, static_cast<lua_Integer>(event.keyModifiers));
    lua_setfield(L, -2, "keyModifiers");

    lua_pushinteger(L, static_cast<lua_Integer>(event.keyCode));
    lua_setfield(L, -2, "keyCode");
}

static void pushSteamInputController(lua_State* L, const SteamInputControllerEntry& entry) {
    lua_newtable(L);

    lua_pushstring(L, entry.handleId.c_str());
    lua_setfield(L, -2, "handleId");

    lua_pushinteger(L, static_cast<lua_Integer>(entry.remotePlaySessionId));
    lua_setfield(L, -2, "remotePlaySessionId");

    lua_pushinteger(L, static_cast<lua_Integer>(entry.gamepadIndex));
    lua_setfield(L, -2, "gamepadIndex");

    lua_pushstring(L, entry.inputType.c_str());
    lua_setfield(L, -2, "inputType");
}

static void pushSteamInputControllerSnapshot(lua_State* L, const SteamInputControllerSnapshot& snapshot) {
    lua_newtable(L);

    pushSteamInputController(L, snapshot.controller);
    lua_setfield(L, -2, "controller");

    lua_newtable(L);
    for (std::size_t i = 0; i < snapshot.digitalActions.size(); ++i) {
        const SteamInputDigitalActionState& action = snapshot.digitalActions[i];
        lua_newtable(L);
        lua_pushstring(L, action.name.c_str());
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, action.state ? 1 : 0);
        lua_setfield(L, -2, "state");
        lua_pushboolean(L, action.active ? 1 : 0);
        lua_setfield(L, -2, "active");
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, -2, "digitalActions");

    lua_newtable(L);
    for (std::size_t i = 0; i < snapshot.analogActions.size(); ++i) {
        const SteamInputAnalogActionState& action = snapshot.analogActions[i];
        lua_newtable(L);
        lua_pushstring(L, action.name.c_str());
        lua_setfield(L, -2, "name");
        lua_pushnumber(L, action.x);
        lua_setfield(L, -2, "x");
        lua_pushnumber(L, action.y);
        lua_setfield(L, -2, "y");
        lua_pushboolean(L, action.active ? 1 : 0);
        lua_setfield(L, -2, "active");
        lua_pushstring(L, action.mode.c_str());
        lua_setfield(L, -2, "mode");
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, -2, "analogActions");
}

static std::vector<int32_t> readIntVector(lua_State* L, int index) {
    std::vector<int32_t> values;
    if (!lua_istable(L, index)) {
        return values;
    }

    const int len = static_cast<int>(lua_objlen(L, index));
    values.reserve(len > 0 ? len : 0);

    for (int i = 1; i <= len; ++i) {
        lua_rawgeti(L, index, i);
        if (lua_isnumber(L, -1)) {
            values.push_back(static_cast<int32_t>(lua_tointeger(L, -1)));
        }
        lua_pop(L, 1);
    }

    return values;
}

static std::vector<std::string> readStringVector(lua_State* L, int index) {
    std::vector<std::string> values;
    if (!lua_istable(L, index)) {
        return values;
    }

    const int len = static_cast<int>(lua_objlen(L, index));
    values.reserve(len > 0 ? len : 0);

    for (int i = 1; i <= len; ++i) {
        lua_rawgeti(L, index, i);
        if (lua_isstring(L, -1)) {
            values.emplace_back(lua_tostring(L, -1));
        }
        lua_pop(L, 1);
    }

    return values;
}

static int l_init(lua_State* L) {
    SteamInitOptions options;

    if (lua_istable(L, 1)) {
        options.appId = tableGetStringField(L, 1, "appId", "480");
        options.autoRestartAppIfNeeded = tableGetBooleanField(L, 1, "autoRestartAppIfNeeded", false);
        options.required = tableGetBooleanField(L, 1, "required", false);
        options.debugLogs = tableGetBooleanField(L, 1, "debugLogs", false);
        options.sdkRoot = tableGetStringField(L, 1, "sdkRoot", "integrations/steam/sdk");
        options.redistributableRoot = tableGetStringField(L, 1, "redistributableRoot", "integrations/steam/redist");
    }

    std::string reason;
    const bool ok = g_bridge.init(options, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_runCallbacks(lua_State* L) {
    const bool ok = g_bridge.runCallbacks();
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

static int l_shutdown(lua_State* L) {
    const bool ok = g_bridge.shutdown();
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

static int l_activateOverlay(lua_State* L) {
    const std::string target = luaOptString(L, 1, "Friends");
    std::string reason;
    const bool ok = g_bridge.activateOverlay(target, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_setRichPresence(lua_State* L) {
    const std::string key = luaCheckString(L, 1);
    const std::string value = luaCheckString(L, 2);

    std::string reason;
    const bool ok = g_bridge.setRichPresence(key, value, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_clearRichPresence(lua_State* L) {
    std::string reason;
    const bool ok = g_bridge.clearRichPresence(reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_showRemotePlayTogetherUI(lua_State* L) {
    std::string reason;
    const bool ok = g_bridge.showRemotePlayTogetherUI(reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_getRemotePlaySessionCount(lua_State* L) {
    std::string reason;
    const int count = g_bridge.getRemotePlaySessionCount(reason);

    lua_pushboolean(L, reason.empty() ? 1 : 0);
    lua_pushinteger(L, static_cast<lua_Integer>(count));
    if (!reason.empty()) {
        lua_pushstring(L, reason.c_str());
        return 3;
    }
    return 2;
}

static int l_listRemotePlaySessions(lua_State* L) {
    std::string reason;
    const std::vector<SteamRemotePlaySessionEntry> sessions = g_bridge.listRemotePlaySessions(reason);

    lua_pushboolean(L, reason.empty() ? 1 : 0);
    lua_newtable(L);
    for (std::size_t i = 0; i < sessions.size(); ++i) {
        pushRemotePlaySession(L, sessions[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }

    if (!reason.empty()) {
        lua_pushstring(L, reason.c_str());
        return 3;
    }
    return 2;
}

static int l_setRemotePlayDirectInputEnabled(lua_State* L) {
    const bool enabled = lua_toboolean(L, 1) != 0;
    std::string reason;
    const bool ok = g_bridge.setRemotePlayDirectInputEnabled(enabled, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_pollRemotePlayInput(lua_State* L) {
    const std::size_t maxEvents = static_cast<std::size_t>(luaL_optinteger(L, 1, 64));

    std::string reason;
    const std::vector<SteamRemotePlayInputEvent> events = g_bridge.pollRemotePlayInput(maxEvents, reason);

    lua_pushboolean(L, reason.empty() ? 1 : 0);
    lua_newtable(L);
    for (std::size_t i = 0; i < events.size(); ++i) {
        pushRemotePlayInputEvent(L, events[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }

    if (!reason.empty()) {
        lua_pushstring(L, reason.c_str());
        return 3;
    }
    return 2;
}

static int l_setRemotePlayMouseVisibility(lua_State* L) {
    const uint32_t sessionId = static_cast<uint32_t>(luaL_checkinteger(L, 1));
    const bool visible = lua_toboolean(L, 2) != 0;

    std::string reason;
    const bool ok = g_bridge.setRemotePlayMouseVisibility(sessionId, visible, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_setRemotePlayMouseCursor(lua_State* L) {
    const uint32_t sessionId = static_cast<uint32_t>(luaL_checkinteger(L, 1));
    const std::string cursorKind = luaCheckString(L, 2);

    std::string reason;
    const bool ok = g_bridge.setRemotePlayMouseCursor(sessionId, cursorKind, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_setRemotePlayMousePosition(lua_State* L) {
    const uint32_t sessionId = static_cast<uint32_t>(luaL_checkinteger(L, 1));
    const float normalizedX = static_cast<float>(luaL_checknumber(L, 2));
    const float normalizedY = static_cast<float>(luaL_checknumber(L, 3));

    std::string reason;
    const bool ok = g_bridge.setRemotePlayMousePosition(sessionId, normalizedX, normalizedY, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_configureSteamInput(lua_State* L) {
    std::string manifestPath;
    std::string actionSetName = "global_controls";
    std::vector<std::string> digitalActions;
    std::vector<std::string> analogActions;

    if (lua_istable(L, 1)) {
        manifestPath = tableGetStringField(L, 1, "manifestPath", "");
        actionSetName = tableGetStringField(L, 1, "actionSet", "global_controls");

        lua_getfield(L, 1, "digitalActions");
        digitalActions = readStringVector(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 1, "analogActions");
        analogActions = readStringVector(L, -1);
        lua_pop(L, 1);
    }

    std::string reason;
    const bool ok = g_bridge.configureSteamInput(manifestPath, actionSetName, digitalActions, analogActions, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_shutdownSteamInput(lua_State* L) {
    std::string reason;
    const bool ok = g_bridge.shutdownSteamInput(reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_listSteamInputControllers(lua_State* L) {
    std::string reason;
    const std::vector<SteamInputControllerEntry> controllers = g_bridge.listSteamInputControllers(reason);

    lua_pushboolean(L, reason.empty() ? 1 : 0);
    lua_newtable(L);
    for (std::size_t i = 0; i < controllers.size(); ++i) {
        pushSteamInputController(L, controllers[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }

    if (!reason.empty()) {
        lua_pushstring(L, reason.c_str());
        return 3;
    }
    return 2;
}

static int l_pollSteamInput(lua_State* L) {
    std::string reason;
    const std::vector<SteamInputControllerSnapshot> snapshots = g_bridge.pollSteamInput(reason);

    lua_pushboolean(L, reason.empty() ? 1 : 0);
    lua_newtable(L);
    for (std::size_t i = 0; i < snapshots.size(); ++i) {
        pushSteamInputControllerSnapshot(L, snapshots[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }

    if (!reason.empty()) {
        lua_pushstring(L, reason.c_str());
        return 3;
    }
    return 2;
}

static int l_showSteamInputBindingPanel(lua_State* L) {
    const std::string handleId = luaCheckString(L, 1);

    std::string reason;
    const bool ok = g_bridge.showSteamInputBindingPanel(handleId, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_getAchievement(lua_State* L) {
    const std::string achievementId = luaCheckString(L, 1);

    bool achieved = false;
    std::string reason;
    const bool ok = g_bridge.getAchievement(achievementId, achieved, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushboolean(L, achieved ? 1 : 0);
        return 2;
    }
    lua_pushstring(L, reason.c_str());
    return 2;
}

static int l_setAchievement(lua_State* L) {
    const std::string achievementId = luaCheckString(L, 1);

    std::string reason;
    const bool ok = g_bridge.setAchievement(achievementId, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_clearAchievement(lua_State* L) {
    const std::string achievementId = luaCheckString(L, 1);

    std::string reason;
    const bool ok = g_bridge.clearAchievement(achievementId, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_storeUserStats(lua_State* L) {
    std::string reason;
    const bool ok = g_bridge.storeUserStats(reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_getStatInt(lua_State* L) {
    const std::string statId = luaCheckString(L, 1);

    int32_t value = 0;
    std::string reason;
    const bool ok = g_bridge.getStatInt(statId, value, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushinteger(L, static_cast<lua_Integer>(value));
        return 2;
    }
    lua_pushstring(L, reason.c_str());
    return 2;
}

static int l_setStatInt(lua_State* L) {
    const std::string statId = luaCheckString(L, 1);
    const int32_t value = static_cast<int32_t>(luaL_checkinteger(L, 2));

    std::string reason;
    const bool ok = g_bridge.setStatInt(statId, value, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_incrementStatInt(lua_State* L) {
    const std::string statId = luaCheckString(L, 1);
    const int32_t delta = static_cast<int32_t>(luaL_checkinteger(L, 2));

    int32_t newValue = 0;
    std::string reason;
    const bool ok = g_bridge.incrementStatInt(statId, delta, newValue, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushinteger(L, static_cast<lua_Integer>(newValue));
        return 2;
    }
    lua_pushstring(L, reason.c_str());
    return 2;
}

static int l_getGameBadgeLevel(lua_State* L) {
    const int series = static_cast<int>(luaL_checkinteger(L, 1));
    const bool foil = lua_toboolean(L, 2) != 0;

    int level = 0;
    std::string reason;
    const bool ok = g_bridge.getGameBadgeLevel(series, foil, level, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushinteger(L, static_cast<lua_Integer>(level));
        return 2;
    }
    lua_pushstring(L, reason.c_str());
    return 2;
}

static int l_getPlayerSteamLevel(lua_State* L) {
    int level = 0;
    std::string reason;
    const bool ok = g_bridge.getPlayerSteamLevel(level, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushinteger(L, static_cast<lua_Integer>(level));
        return 2;
    }
    lua_pushstring(L, reason.c_str());
    return 2;
}

static int l_computeRatingProfileSignature(lua_State* L) {
    const std::string canonicalPayload = luaCheckString(L, 1);
    const std::string ownerSteamId = luaCheckString(L, 2);
    const std::string appId = luaCheckString(L, 3);

    std::string token;
    std::string reason;
    const bool ok = g_bridge.computeRatingProfileSignature(canonicalPayload, ownerSteamId, appId, token, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushstring(L, token.c_str());
        return 2;
    }
    lua_pushstring(L, reason.c_str());
    return 2;
}

static int l_getLocalUserId(lua_State* L) {
    std::string userId;
    std::string reason;
    const bool ok = g_bridge.getLocalUserId(userId, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushstring(L, userId.c_str());
    } else {
        lua_pushstring(L, reason.c_str());
    }
    return 2;
}

static int l_getPersonaName(lua_State* L) {
    std::string personaName;
    std::string reason;
    const bool ok = g_bridge.getPersonaName(personaName, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushstring(L, personaName.c_str());
    } else {
        lua_pushstring(L, reason.c_str());
    }
    return 2;
}

static int l_getPersonaNameForUser(lua_State* L) {
    const std::string userId = luaCheckString(L, 1);

    std::string personaName;
    std::string reason;
    const bool ok = g_bridge.getPersonaNameForUser(userId, personaName, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushstring(L, personaName.c_str());
    } else {
        lua_pushstring(L, reason.c_str());
    }
    return 2;
}

static int l_createFriendsLobby(lua_State* L) {
    const int maxMembers = static_cast<int>(luaL_optinteger(L, 1, 2));

    SteamLobbyCreateResult result;
    std::string reason;
    const bool ok = g_bridge.createFriendsLobby(maxMembers, result, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }

    lua_newtable(L);
    lua_pushstring(L, result.lobbyId.c_str());
    lua_setfield(L, -2, "lobbyId");
    lua_pushstring(L, result.ownerId.c_str());
    lua_setfield(L, -2, "ownerId");
    return 2;
}

static int l_joinLobby(lua_State* L) {
    const std::string lobbyId = luaCheckString(L, 1);

    SteamLobbyJoinResult result;
    std::string reason;
    const bool ok = g_bridge.joinLobby(lobbyId, result, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }

    lua_newtable(L);
    lua_pushstring(L, result.lobbyId.c_str());
    lua_setfield(L, -2, "lobbyId");
    lua_pushinteger(L, result.enterResponse);
    lua_setfield(L, -2, "enterResponse");
    return 2;
}

static int l_leaveLobby(lua_State* L) {
    const std::string lobbyId = luaCheckString(L, 1);

    std::string reason;
    const bool ok = g_bridge.leaveLobby(lobbyId, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_inviteFriend(lua_State* L) {
    const std::string lobbyId = luaCheckString(L, 1);
    const std::string friendId = luaCheckString(L, 2);

    std::string reason;
    const bool ok = g_bridge.inviteFriend(lobbyId, friendId, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_pollLobbyEvents(lua_State* L) {
    const std::size_t maxEvents = static_cast<std::size_t>(luaL_optinteger(L, 1, 64));
    const std::vector<SteamLobbyEvent> events = g_bridge.pollLobbyEvents(maxEvents);

    lua_pushboolean(L, 1);
    lua_newtable(L);
    for (std::size_t i = 0; i < events.size(); ++i) {
        pushLobbyEvent(L, events[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    return 2;
}

static int l_getLobbySnapshot(lua_State* L) {
    const std::string lobbyId = luaCheckString(L, 1);

    SteamLobbySnapshot snapshot;
    std::string reason;
    const bool ok = g_bridge.getLobbySnapshot(lobbyId, snapshot, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }

    pushLobbySnapshot(L, snapshot);
    return 2;
}

static int l_listJoinableLobbies(lua_State* L) {
    std::size_t maxResults = 20;
    std::string protocolVersion;

    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "maxResults");
        if (lua_isnumber(L, -1)) {
            const lua_Integer value = lua_tointeger(L, -1);
            if (value > 0) {
                maxResults = static_cast<std::size_t>(value);
            }
        }
        lua_pop(L, 1);

        lua_getfield(L, 1, "protocolVersion");
        if (lua_isstring(L, -1)) {
            protocolVersion = lua_tostring(L, -1);
        }
        lua_pop(L, 1);
    }

    std::string reason;
    const std::vector<SteamLobbyListEntry> entries = g_bridge.listJoinableLobbies(maxResults, protocolVersion, reason);
    if (!reason.empty()) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, reason.c_str());
        return 2;
    }

    lua_pushboolean(L, 1);
    lua_newtable(L);
    for (std::size_t i = 0; i < entries.size(); ++i) {
        pushLobbyListEntry(L, entries[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    return 2;
}

static int l_setLobbyData(lua_State* L) {
    const std::string lobbyId = luaCheckString(L, 1);
    const std::string key = luaCheckString(L, 2);
    const std::string value = luaOptString(L, 3, "");

    std::string reason;
    const bool ok = g_bridge.setLobbyData(lobbyId, key, value, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_setLobbyVisibility(lua_State* L) {
    const std::string lobbyId = luaCheckString(L, 1);
    const std::string visibility = luaOptString(L, 2, "public");

    std::string reason;
    const bool ok = g_bridge.setLobbyVisibility(lobbyId, visibility, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_getLobbyData(lua_State* L) {
    const std::string lobbyId = luaCheckString(L, 1);
    const std::string key = luaCheckString(L, 2);

    std::string value;
    std::string reason;
    const bool ok = g_bridge.getLobbyData(lobbyId, key, value, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushstring(L, value.c_str());
    } else {
        lua_pushstring(L, reason.c_str());
    }
    return 2;
}

static int l_getSteamIdFromLobbyMember(lua_State* L) {
    const std::string lobbyId = luaCheckString(L, 1);
    const int index = static_cast<int>(luaL_checkinteger(L, 2));

    std::string steamId;
    std::string reason;
    const bool ok = g_bridge.getSteamIdFromLobbyMember(lobbyId, index, steamId, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (ok) {
        lua_pushstring(L, steamId.c_str());
    } else {
        lua_pushstring(L, reason.c_str());
    }
    return 2;
}

static int l_sendNet(lua_State* L) {
    const std::string peerId = luaCheckString(L, 1);

    size_t payloadLength = 0;
    const char* payloadRaw = luaL_checklstring(L, 2, &payloadLength);
    const std::string payload(payloadRaw, payloadLength);

    const int channel = static_cast<int>(luaL_optinteger(L, 3, 1));
    const std::string sendType = luaOptString(L, 4, "reliable");

    std::string reason;
    const bool ok = g_bridge.sendNet(peerId, payload, channel, sendType, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_pollNet(lua_State* L) {
    const std::size_t maxPackets = static_cast<std::size_t>(luaL_optinteger(L, 1, 64));
    const std::vector<SteamNetPacket> packets = g_bridge.pollNet(maxPackets);

    lua_pushboolean(L, 1);
    lua_newtable(L);
    for (std::size_t i = 0; i < packets.size(); ++i) {
        pushNetPacket(L, packets[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    return 2;
}

static int l_findOrCreateLeaderboard(lua_State* L) {
    const std::string name = luaCheckString(L, 1);
    const std::string sortMethod = luaOptString(L, 2, "descending");
    const std::string displayType = luaOptString(L, 3, "numeric");

    SteamLeaderboardInfo info;
    std::string reason;
    const bool ok = g_bridge.findOrCreateLeaderboard(name, sortMethod, displayType, info, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }

    lua_newtable(L);
    lua_pushstring(L, info.name.c_str());
    lua_setfield(L, -2, "name");
    lua_pushstring(L, info.handle.c_str());
    lua_setfield(L, -2, "handle");
    return 2;
}

static int l_uploadLeaderboardScore(lua_State* L) {
    const std::string name = luaCheckString(L, 1);
    const int score = static_cast<int>(luaL_checkinteger(L, 2));
    const std::vector<int32_t> details = readIntVector(L, 3);
    const bool forceUpdate = lua_toboolean(L, 4) != 0;

    std::string reason;
    const bool ok = g_bridge.uploadLeaderboardScore(name, score, details, forceUpdate, reason);

    lua_pushboolean(L, ok ? 1 : 0);
    if (!ok) {
        lua_pushstring(L, reason.c_str());
        return 2;
    }
    return 1;
}

static int l_downloadLeaderboardEntriesForUsers(lua_State* L) {
    const std::string name = luaCheckString(L, 1);
    const std::vector<std::string> userIds = readStringVector(L, 2);

    std::string reason;
    const std::vector<SteamLeaderboardEntryRecord> entries = g_bridge.downloadLeaderboardEntriesForUsers(name, userIds, reason);

    lua_pushboolean(L, reason.empty() ? 1 : 0);
    lua_newtable(L);
    for (std::size_t i = 0; i < entries.size(); ++i) {
        pushLeaderboardEntry(L, entries[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }

    if (!reason.empty()) {
        lua_pushstring(L, reason.c_str());
        return 3;
    }

    return 2;
}

static int l_downloadLeaderboardAroundUser(lua_State* L) {
    const std::string name = luaCheckString(L, 1);
    const int rangeStart = static_cast<int>(luaL_optinteger(L, 2, -10));
    const int rangeEnd = static_cast<int>(luaL_optinteger(L, 3, 10));

    std::string reason;
    const std::vector<SteamLeaderboardEntryRecord> entries = g_bridge.downloadLeaderboardAroundUser(name, rangeStart, rangeEnd, reason);

    lua_pushboolean(L, reason.empty() ? 1 : 0);
    lua_newtable(L);
    for (std::size_t i = 0; i < entries.size(); ++i) {
        pushLeaderboardEntry(L, entries[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }

    if (!reason.empty()) {
        lua_pushstring(L, reason.c_str());
        return 3;
    }

    return 2;
}


static int l_downloadLeaderboardTop(lua_State* L) {
    const std::string name = luaCheckString(L, 1);
    const int startRank = static_cast<int>(luaL_optinteger(L, 2, 1));
    const int maxEntries = static_cast<int>(luaL_optinteger(L, 3, 100));

    std::string reason;
    const std::vector<SteamLeaderboardEntryRecord> entries = g_bridge.downloadLeaderboardTop(name, startRank, maxEntries, reason);

    lua_pushboolean(L, reason.empty() ? 1 : 0);
    lua_newtable(L);
    for (std::size_t i = 0; i < entries.size(); ++i) {
        pushLeaderboardEntry(L, entries[i]);
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }

    if (!reason.empty()) {
        lua_pushstring(L, reason.c_str());
        return 3;
    }

    return 2;
}

static const luaL_Reg kSteamBridgeMethods[] = {
    {"init", l_init},
    {"runCallbacks", l_runCallbacks},
    {"shutdown", l_shutdown},
    {"activateOverlay", l_activateOverlay},
    {"setRichPresence", l_setRichPresence},
    {"clearRichPresence", l_clearRichPresence},
    {"showRemotePlayTogetherUI", l_showRemotePlayTogetherUI},
    {"getRemotePlaySessionCount", l_getRemotePlaySessionCount},
    {"listRemotePlaySessions", l_listRemotePlaySessions},
    {"setRemotePlayDirectInputEnabled", l_setRemotePlayDirectInputEnabled},
    {"pollRemotePlayInput", l_pollRemotePlayInput},
    {"setRemotePlayMouseVisibility", l_setRemotePlayMouseVisibility},
    {"setRemotePlayMouseCursor", l_setRemotePlayMouseCursor},
    {"setRemotePlayMousePosition", l_setRemotePlayMousePosition},
    {"configureSteamInput", l_configureSteamInput},
    {"shutdownSteamInput", l_shutdownSteamInput},
    {"listSteamInputControllers", l_listSteamInputControllers},
    {"pollSteamInput", l_pollSteamInput},
    {"showSteamInputBindingPanel", l_showSteamInputBindingPanel},
    {"getAchievement", l_getAchievement},
    {"setAchievement", l_setAchievement},
    {"clearAchievement", l_clearAchievement},
    {"storeUserStats", l_storeUserStats},
    {"getStatInt", l_getStatInt},
    {"setStatInt", l_setStatInt},
    {"incrementStatInt", l_incrementStatInt},
    {"getGameBadgeLevel", l_getGameBadgeLevel},
    {"getPlayerSteamLevel", l_getPlayerSteamLevel},
    {"computeRatingProfileSignature", l_computeRatingProfileSignature},
    {"getLocalUserId", l_getLocalUserId},
    {"getPersonaName", l_getPersonaName},
    {"getPersonaNameForUser", l_getPersonaNameForUser},
    {"createFriendsLobby", l_createFriendsLobby},
    {"joinLobby", l_joinLobby},
    {"leaveLobby", l_leaveLobby},
    {"inviteFriend", l_inviteFriend},
    {"pollLobbyEvents", l_pollLobbyEvents},
    {"getLobbySnapshot", l_getLobbySnapshot},
    {"listJoinableLobbies", l_listJoinableLobbies},
    {"setLobbyData", l_setLobbyData},
    {"setLobbyVisibility", l_setLobbyVisibility},
    {"getLobbyData", l_getLobbyData},
    {"getSteamIdFromLobbyMember", l_getSteamIdFromLobbyMember},
    {"sendNet", l_sendNet},
    {"pollNet", l_pollNet},
    {"findOrCreateLeaderboard", l_findOrCreateLeaderboard},
    {"uploadLeaderboardScore", l_uploadLeaderboardScore},
    {"downloadLeaderboardEntriesForUsers", l_downloadLeaderboardEntriesForUsers},
    {"downloadLeaderboardAroundUser", l_downloadLeaderboardAroundUser},
    {"downloadLeaderboardTop", l_downloadLeaderboardTop},
    {NULL, NULL}
};

#if defined(_WIN32)
#define LUA_MODULE_EXPORT extern "C" __declspec(dllexport)
#else
#define LUA_MODULE_EXPORT extern "C"
#endif

LUA_MODULE_EXPORT int luaopen_steam_bridge_native(lua_State* L) {
#if LUA_VERSION_NUM >= 502
    luaL_newlib(L, kSteamBridgeMethods);
#else
    lua_newtable(L);
    luaL_register(L, NULL, kSteamBridgeMethods);
#endif
    return 1;
}
