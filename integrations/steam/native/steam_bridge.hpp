#pragma once

#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

#include "steam/steam_api.h"

struct SteamInitOptions {
    std::string appId;
    bool autoRestartAppIfNeeded = false;
    bool required = false;
    bool debugLogs = false;
    std::string sdkRoot;
    std::string redistributableRoot;
};

struct SteamLobbyCreateResult {
    std::string lobbyId;
    std::string ownerId;
};

struct SteamLobbyJoinResult {
    std::string lobbyId;
    int enterResponse = 0;
};

struct SteamLobbyEvent {
    std::string type;
    std::string lobbyId;
    std::string ownerId;
    std::string memberId;
    std::string result;
    int memberState = 0;
};

struct SteamLobbySnapshot {
    std::string lobbyId;
    std::string ownerId;
    std::string sessionId;
    std::string protocolVersion;
    std::vector<std::string> members;
};

struct SteamLobbyListEntry {
    std::string lobbyId;
    std::string ownerId;
    std::string ownerName;
    int memberCount = 0;
    int memberLimit = 0;
    std::string sessionId;
    std::string protocolVersion;
    std::string relation;
    bool joinable = true;
};

struct SteamNetPacket {
    std::string peerId;
    int channel = 0;
    std::string payload;
    double recvTs = 0.0;
};

struct SteamLeaderboardInfo {
    std::string name;
    std::string handle;
};

struct SteamLeaderboardEntryRecord {
    std::string userId;
    int score = 0;
    int rank = 0;
    std::vector<int32_t> details;
};

struct SteamRemotePlaySessionEntry {
    uint32_t sessionId = 0;
    std::string userId;
    std::string personaName;
    std::string clientName;
};

struct SteamRemotePlayInputEvent {
    uint32_t sessionId = 0;
    std::string type;
    bool mouseAbsolute = false;
    float mouseNormalizedX = 0.0f;
    float mouseNormalizedY = 0.0f;
    int mouseDeltaX = 0;
    int mouseDeltaY = 0;
    int mouseButton = 0;
    int wheelDirection = 0;
    float wheelAmount = 0.0f;
    int keyScancode = 0;
    uint32_t keyModifiers = 0;
    uint32_t keyCode = 0;
};

struct SteamInputDigitalActionState {
    std::string name;
    bool state = false;
    bool active = false;
};

struct SteamInputAnalogActionState {
    std::string name;
    float x = 0.0f;
    float y = 0.0f;
    bool active = false;
    std::string mode;
};

struct SteamInputControllerEntry {
    std::string handleId;
    uint32_t remotePlaySessionId = 0;
    int gamepadIndex = -1;
    std::string inputType;
};

struct SteamInputControllerSnapshot {
    SteamInputControllerEntry controller;
    std::vector<SteamInputDigitalActionState> digitalActions;
    std::vector<SteamInputAnalogActionState> analogActions;
};

class SteamBridge {
public:
    SteamBridge();
    ~SteamBridge();

    bool init(const SteamInitOptions& options, std::string& reason);
    bool runCallbacks();
    bool shutdown();

    bool activateOverlay(const std::string& target, std::string& reason);
    bool setRichPresence(const std::string& key, const std::string& value, std::string& reason);
    bool clearRichPresence(std::string& reason);
    bool showRemotePlayTogetherUI(std::string& reason);
    int getRemotePlaySessionCount(std::string& reason) const;
    std::vector<SteamRemotePlaySessionEntry> listRemotePlaySessions(std::string& reason) const;
    bool setRemotePlayDirectInputEnabled(bool enabled, std::string& reason);
    std::vector<SteamRemotePlayInputEvent> pollRemotePlayInput(std::size_t maxEvents, std::string& reason) const;
    bool setRemotePlayMouseVisibility(uint32_t sessionId, bool visible, std::string& reason) const;
    bool setRemotePlayMouseCursor(uint32_t sessionId, const std::string& cursorKind, std::string& reason);
    bool setRemotePlayMousePosition(uint32_t sessionId, float normalizedX, float normalizedY, std::string& reason) const;
    bool configureSteamInput(const std::string& manifestPath,
                             const std::string& actionSetName,
                             const std::vector<std::string>& digitalActionNames,
                             const std::vector<std::string>& analogActionNames,
                             std::string& reason);
    bool shutdownSteamInput(std::string& reason);
    std::vector<SteamInputControllerEntry> listSteamInputControllers(std::string& reason) const;
    std::vector<SteamInputControllerSnapshot> pollSteamInput(std::string& reason);
    bool showSteamInputBindingPanel(const std::string& handleId, std::string& reason) const;
    bool getAchievement(const std::string& achievementId, bool& achieved, std::string& reason) const;
    bool setAchievement(const std::string& achievementId, std::string& reason);
    bool clearAchievement(const std::string& achievementId, std::string& reason);
    bool storeUserStats(std::string& reason);
    bool getStatInt(const std::string& statId, int32_t& value, std::string& reason) const;
    bool setStatInt(const std::string& statId, int32_t value, std::string& reason);
    bool incrementStatInt(const std::string& statId, int32_t delta, int32_t& newValue, std::string& reason);
    bool getGameBadgeLevel(int series, bool foil, int& level, std::string& reason) const;
    bool getPlayerSteamLevel(int& level, std::string& reason) const;
    bool computeRatingProfileSignature(const std::string& canonicalPayload, const std::string& ownerSteamId, const std::string& appId, std::string& token, std::string& reason) const;

    bool getLocalUserId(std::string& userId, std::string& reason) const;
    bool getPersonaName(std::string& personaName, std::string& reason) const;
    bool getPersonaNameForUser(const std::string& userId, std::string& personaName, std::string& reason) const;

    bool createFriendsLobby(int maxMembers, SteamLobbyCreateResult& result, std::string& reason);
    bool joinLobby(const std::string& lobbyId, SteamLobbyJoinResult& result, std::string& reason);
    bool leaveLobby(const std::string& lobbyId, std::string& reason);
    bool inviteFriend(const std::string& lobbyId, const std::string& friendId, std::string& reason);

    std::vector<SteamLobbyEvent> pollLobbyEvents(std::size_t maxEvents);
    bool getLobbySnapshot(const std::string& lobbyId, SteamLobbySnapshot& snapshot, std::string& reason) const;
    std::vector<SteamLobbyListEntry> listJoinableLobbies(std::size_t maxResults, const std::string& protocolVersion, std::string& reason) const;
    bool setLobbyData(const std::string& lobbyId, const std::string& key, const std::string& value, std::string& reason);
    bool setLobbyVisibility(const std::string& lobbyId, const std::string& visibility, std::string& reason);
    bool getLobbyData(const std::string& lobbyId, const std::string& key, std::string& value, std::string& reason) const;
    bool getSteamIdFromLobbyMember(const std::string& lobbyId, int indexOneBased, std::string& steamId, std::string& reason) const;

    bool sendNet(const std::string& peerId, const std::string& payload, int channel, const std::string& sendType, std::string& reason);
    std::vector<SteamNetPacket> pollNet(std::size_t maxPackets);

    bool findOrCreateLeaderboard(const std::string& name, const std::string& sortMethod, const std::string& displayType,
                                 SteamLeaderboardInfo& info, std::string& reason);
    bool uploadLeaderboardScore(const std::string& name, int score, const std::vector<int32_t>& details,
                                bool forceUpdate, std::string& reason);
    std::vector<SteamLeaderboardEntryRecord> downloadLeaderboardEntriesForUsers(const std::string& name,
                                                                                 const std::vector<std::string>& userIds,
                                                                                 std::string& reason);
    std::vector<SteamLeaderboardEntryRecord> downloadLeaderboardAroundUser(const std::string& name,
                                                                           int rangeStart,
                                                                           int rangeEnd,
                                                                           std::string& reason);
    std::vector<SteamLeaderboardEntryRecord> downloadLeaderboardTop(const std::string& name,
                                                                    int startRank,
                                                                    int maxEntries,
                                                                    std::string& reason);

private:
    bool initialized_ = false;
    bool debugLogs_ = false;
    bool remotePlayDirectInputEnabled_ = false;
    bool remotePlayCursorAssetsReady_ = false;
    RemotePlayCursorID_t remotePlayHiddenCursorId_ = 0;
    RemotePlayCursorID_t remotePlayLightCursor32Id_ = 0;
    RemotePlayCursorID_t remotePlayLightCursor48Id_ = 0;
    RemotePlayCursorID_t remotePlayLightCursor64Id_ = 0;
    bool steamInputInitialized_ = false;
    bool steamInputConfigured_ = false;
    std::string steamInputManifestPath_;
    std::string steamInputActionSetName_;
    InputActionSetHandle_t steamInputActionSetHandle_ = 0;
    std::unordered_map<std::string, InputDigitalActionHandle_t> steamInputDigitalHandles_;
    std::unordered_map<std::string, InputAnalogActionHandle_t> steamInputAnalogHandles_;
    std::unordered_map<std::string, SteamLeaderboard_t> leaderboardHandles_;
    std::deque<SteamLobbyEvent> lobbyEvents_;

    CCallback<SteamBridge, GameLobbyJoinRequested_t> callbackLobbyJoinRequested_;
    CCallback<SteamBridge, LobbyInvite_t> callbackLobbyInvite_;
    CCallback<SteamBridge, LobbyChatUpdate_t> callbackLobbyChatUpdate_;
    CCallback<SteamBridge, LobbyDataUpdate_t> callbackLobbyDataUpdate_;
    CCallback<SteamBridge, SteamRemotePlaySessionConnected_t> callbackRemotePlaySessionConnected_;
    CCallback<SteamBridge, SteamRemotePlaySessionDisconnected_t> callbackRemotePlaySessionDisconnected_;
    CCallback<SteamBridge, SteamNetworkingMessagesSessionRequest_t> callbackNetworkingSessionRequest_;
    CCallback<SteamBridge, SteamNetworkingMessagesSessionFailed_t> callbackNetworkingSessionFailed_;

    bool requireInitialized(std::string& reason) const;
    bool ensureSteamInputConfigured(std::string& reason) const;
    bool ensureRemotePlayCursorAssets(std::string& reason);
    RemotePlayCursorID_t resolveRemotePlayVisibleCursorId(uint32_t sessionId) const;

    static bool parseSteamId64(const std::string& value, CSteamID& outId);
    static std::string steamIdToString(CSteamID id);
    static std::string steamIdToString(uint64 value);
    static bool parseInputHandle(const std::string& value, InputHandle_t& outHandle);

    static ELeaderboardSortMethod mapSortMethod(const std::string& sortMethod);
    static ELeaderboardDisplayType mapDisplayType(const std::string& displayType);

    bool resolveLobbyId(const std::string& lobbyId, CSteamID& outLobbyId, std::string& reason) const;
    bool resolvePeerId(const std::string& peerId, CSteamID& outPeerId, std::string& reason) const;

    bool findLeaderboardHandle(const std::string& name, SteamLeaderboard_t& handle, std::string& reason);

    template <typename TResult>
    bool waitForCallResult(SteamAPICall_t callHandle, TResult& result, std::string& reason, int timeoutMs = 4000) const;

    void pushLobbyEvent(const SteamLobbyEvent& event);

    void onLobbyInvite(LobbyInvite_t* data);
    void onLobbyJoinRequested(GameLobbyJoinRequested_t* data);
    void onLobbyChatUpdate(LobbyChatUpdate_t* data);
    void onLobbyDataUpdate(LobbyDataUpdate_t* data);
    void onRemotePlaySessionConnected(SteamRemotePlaySessionConnected_t* data);
    void onRemotePlaySessionDisconnected(SteamRemotePlaySessionDisconnected_t* data);
    void onNetworkingSessionRequest(SteamNetworkingMessagesSessionRequest_t* data);
    void onNetworkingSessionFailed(SteamNetworkingMessagesSessionFailed_t* data);
};
