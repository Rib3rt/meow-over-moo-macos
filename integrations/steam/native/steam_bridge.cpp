#include "steam_bridge.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>

namespace {

std::string resultToString(EResult result) {
    return std::to_string(static_cast<int>(result));
}

std::string lobbyEnterResponseToString(EChatRoomEnterResponse response) {
    return std::to_string(static_cast<int>(response));
}

std::string friendRelationToBucket(EFriendRelationship relationship) {
    switch (relationship) {
        case k_EFriendRelationshipFriend:
            return "friend";
        case k_EFriendRelationshipRequestRecipient:
        case k_EFriendRelationshipRequestInitiator:
            return "friend_of_friend";
        default:
            return "other";
    }
}

std::string remotePlayInputTypeToString(ERemotePlayInputType type) {
    switch (type) {
        case k_ERemotePlayInputMouseMotion:
            return "mouse_motion";
        case k_ERemotePlayInputMouseButtonDown:
            return "mouse_button_down";
        case k_ERemotePlayInputMouseButtonUp:
            return "mouse_button_up";
        case k_ERemotePlayInputMouseWheel:
            return "mouse_wheel";
        case k_ERemotePlayInputKeyDown:
            return "key_down";
        case k_ERemotePlayInputKeyUp:
            return "key_up";
        default:
            return "unknown";
    }
}

std::string steamInputTypeToString(ESteamInputType type) {
    switch (type) {
        case k_ESteamInputType_SteamController:
            return "steam_controller";
        case k_ESteamInputType_XBox360Controller:
            return "xbox360";
        case k_ESteamInputType_XBoxOneController:
            return "xboxone";
        case k_ESteamInputType_GenericGamepad:
            return "generic_gamepad";
        case k_ESteamInputType_PS4Controller:
            return "ps4";
        case k_ESteamInputType_AppleMFiController:
            return "apple_mfi";
        case k_ESteamInputType_AndroidController:
            return "android";
        case k_ESteamInputType_SwitchJoyConPair:
            return "switch_joycon_pair";
        case k_ESteamInputType_SwitchJoyConSingle:
            return "switch_joycon_single";
        case k_ESteamInputType_SwitchProController:
            return "switch_pro";
        case k_ESteamInputType_MobileTouch:
            return "mobile_touch";
        case k_ESteamInputType_PS3Controller:
            return "ps3";
        case k_ESteamInputType_PS5Controller:
            return "ps5";
        case k_ESteamInputType_SteamDeckController:
            return "steam_deck";
        default:
            return "unknown";
    }
}

std::string steamInputSourceModeToString(EInputSourceMode mode) {
    switch (mode) {
        case k_EInputSourceMode_None:
            return "none";
        case k_EInputSourceMode_Dpad:
            return "dpad";
        case k_EInputSourceMode_Buttons:
            return "buttons";
        case k_EInputSourceMode_FourButtons:
            return "four_buttons";
        case k_EInputSourceMode_AbsoluteMouse:
            return "absolute_mouse";
        case k_EInputSourceMode_RelativeMouse:
            return "relative_mouse";
        case k_EInputSourceMode_JoystickMove:
            return "joystick_move";
        case k_EInputSourceMode_JoystickMouse:
            return "joystick_mouse";
        case k_EInputSourceMode_JoystickCamera:
            return "joystick_camera";
        case k_EInputSourceMode_ScrollWheel:
            return "scroll_wheel";
        case k_EInputSourceMode_Trigger:
            return "trigger";
        case k_EInputSourceMode_TouchMenu:
            return "touch_menu";
        case k_EInputSourceMode_MouseJoystick:
            return "mouse_joystick";
        case k_EInputSourceMode_MouseRegion:
            return "mouse_region";
        case k_EInputSourceMode_RadialMenu:
            return "radial_menu";
        case k_EInputSourceMode_SingleButton:
            return "single_button";
        case k_EInputSourceMode_Switches:
            return "switches";
        default:
            return "unknown";
    }
}

int relationPriority(const std::string& relation) {
    if (relation == "friend") {
        return 0;
    }
    if (relation == "friend_of_friend") {
        return 1;
    }
    return 2;
}

constexpr uint32_t kRatingProfileSignatureMod = 2147483647u;
constexpr uint32_t kRatingProfilePepperA = 0x4D4F4D52u;
constexpr uint32_t kRatingProfilePepperB = 0x32505246u;

std::string buildRatingProfileSignatureToken(
    const std::string& canonicalPayload,
    const std::string& ownerSteamId,
    const std::string& appId
) {
    const std::string combined = std::string("MOM_RATING_PROFILE_V2_NATIVE\n")
        + ownerSteamId + "\n"
        + appId + "\n"
        + canonicalPayload;

    uint32_t hashA = kRatingProfilePepperA;
    uint32_t hashB = kRatingProfilePepperB;
    for (std::size_t index = 0; index < combined.size(); ++index) {
        const uint32_t byte = static_cast<uint8_t>(combined[index]);
        hashA = static_cast<uint32_t>((static_cast<uint64_t>(hashA) * 131ull + byte + 17ull + (index % 23ull)) % kRatingProfileSignatureMod);
        hashB = static_cast<uint32_t>((static_cast<uint64_t>(hashB) * 257ull + byte + 29ull + (index % 31ull)) % kRatingProfileSignatureMod);
    }

    char buffer[32] = {0};
    std::snprintf(buffer, sizeof(buffer), "N1:%08X%08X", hashA, hashB);
    return std::string(buffer);
}

void debugLog(bool enabled, const char* message) {
    if (!enabled || !message) {
        return;
    }
    std::fprintf(stderr, "[SteamBridge] %s\n", message);
}

void writeCursorPixel(std::vector<uint8_t>& buffer, int width, int x, int y,
                      uint8_t b, uint8_t g, uint8_t r, uint8_t a) {
    if (x < 0 || y < 0 || width <= 0) {
        return;
    }
    const std::size_t index = static_cast<std::size_t>((y * width + x) * 4);
    if (index + 3 >= buffer.size()) {
        return;
    }
    buffer[index + 0] = b;
    buffer[index + 1] = g;
    buffer[index + 2] = r;
    buffer[index + 3] = a;
}

std::vector<uint8_t> buildLightArrowCursor(int size) {
    const int width = std::max(16, size);
    const int height = width;
    std::vector<uint8_t> pixels(static_cast<std::size_t>(width * height * 4), 0);

    const int headHeight = std::max(10, height / 2);
    const int headWidth = std::max(8, width / 3);
    const int shaftLeft = std::max(3, width / 8);
    const int shaftRight = std::min(width - 6, shaftLeft + std::max(4, width / 7));
    const int shaftTop = std::max(6, headHeight - std::max(3, height / 12));
    const int shaftBottom = std::max(shaftTop + 6, height - std::max(8, height / 6));
    const int tailTipX = std::min(width - 4, shaftRight + std::max(5, width / 6));
    const int tailTipY = std::min(height - 4, shaftBottom + std::max(4, height / 8));

    auto inArrowFill = [&](int x, int y) {
        if (x < 0 || y < 0 || x >= width || y >= height) {
            return false;
        }
        if (y <= headHeight) {
            const float t = static_cast<float>(y) / static_cast<float>(std::max(1, headHeight));
            const int span = std::max(1, static_cast<int>(std::round(t * headWidth)));
            return x >= 0 && x <= span;
        }
        if (y >= shaftTop && y <= shaftBottom) {
            return x >= shaftLeft && x <= shaftRight;
        }
        if (y > shaftBottom && y <= tailTipY) {
            const int dy = y - shaftBottom;
            const int maxDy = std::max(1, tailTipY - shaftBottom);
            const int extension = static_cast<int>(std::round((static_cast<float>(dy) / static_cast<float>(maxDy)) * (tailTipX - shaftRight)));
            return x >= shaftLeft && x <= (shaftRight + extension);
        }
        return false;
    };

    auto shadow = [&](int x, int y) {
        writeCursorPixel(pixels, width, x, y, 0, 0, 0, 140);
    };
    auto fill = [&](int x, int y) {
        writeCursorPixel(pixels, width, x, y, 240, 245, 255, 255);
    };
    auto outline = [&](int x, int y) {
        writeCursorPixel(pixels, width, x, y, 20, 22, 24, 255);
    };

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            if (!inArrowFill(x, y)) {
                continue;
            }
            shadow(x + 1, y + 1);
            fill(x, y);
        }
    }

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            if (!inArrowFill(x, y)) {
                continue;
            }
            bool isEdge = false;
            for (int oy = -1; oy <= 1 && !isEdge; ++oy) {
                for (int ox = -1; ox <= 1; ++ox) {
                    if (ox == 0 && oy == 0) {
                        continue;
                    }
                    if (!inArrowFill(x + ox, y + oy)) {
                        isEdge = true;
                        break;
                    }
                }
            }
            if (isEdge) {
                outline(x, y);
            }
        }
    }

    return pixels;
}

} // namespace

SteamBridge::SteamBridge()
    : callbackLobbyJoinRequested_(this, &SteamBridge::onLobbyJoinRequested),
      callbackLobbyInvite_(this, &SteamBridge::onLobbyInvite),
      callbackLobbyChatUpdate_(this, &SteamBridge::onLobbyChatUpdate),
      callbackLobbyDataUpdate_(this, &SteamBridge::onLobbyDataUpdate),
      callbackRemotePlaySessionConnected_(this, &SteamBridge::onRemotePlaySessionConnected),
      callbackRemotePlaySessionDisconnected_(this, &SteamBridge::onRemotePlaySessionDisconnected),
      callbackNetworkingSessionRequest_(this, &SteamBridge::onNetworkingSessionRequest),
      callbackNetworkingSessionFailed_(this, &SteamBridge::onNetworkingSessionFailed) {
}

SteamBridge::~SteamBridge() {
    std::string reason;
    shutdown();
}

bool SteamBridge::requireInitialized(std::string& reason) const {
    if (initialized_) {
        return true;
    }
    reason = "steam_not_initialized";
    return false;
}

bool SteamBridge::parseSteamId64(const std::string& value, CSteamID& outId) {
    if (value.empty()) {
        return false;
    }
    char* end = nullptr;
    const unsigned long long raw = std::strtoull(value.c_str(), &end, 10);
    if (!end || *end != '\0') {
        return false;
    }
    if (raw == 0ULL) {
        return false;
    }
    outId = CSteamID(static_cast<uint64>(raw));
    return outId.IsValid();
}

bool SteamBridge::parseInputHandle(const std::string& value, InputHandle_t& outHandle) {
    if (value.empty()) {
        return false;
    }
    char* end = nullptr;
    const unsigned long long raw = std::strtoull(value.c_str(), &end, 10);
    if (!end || *end != '\0') {
        return false;
    }
    outHandle = static_cast<InputHandle_t>(raw);
    return outHandle != 0;
}

std::string SteamBridge::steamIdToString(CSteamID id) {
    return std::to_string(id.ConvertToUint64());
}

std::string SteamBridge::steamIdToString(uint64 value) {
    return std::to_string(static_cast<unsigned long long>(value));
}

ELeaderboardSortMethod SteamBridge::mapSortMethod(const std::string& sortMethod) {
    if (sortMethod == "ascending") {
        return k_ELeaderboardSortMethodAscending;
    }
    return k_ELeaderboardSortMethodDescending;
}

ELeaderboardDisplayType SteamBridge::mapDisplayType(const std::string& displayType) {
    if (displayType == "time_seconds") {
        return k_ELeaderboardDisplayTypeTimeSeconds;
    }
    if (displayType == "time_milliseconds") {
        return k_ELeaderboardDisplayTypeTimeMilliSeconds;
    }
    return k_ELeaderboardDisplayTypeNumeric;
}

bool SteamBridge::resolveLobbyId(const std::string& lobbyId, CSteamID& outLobbyId, std::string& reason) const {
    if (!parseSteamId64(lobbyId, outLobbyId)) {
        reason = "invalid_lobby_id";
        return false;
    }
    return true;
}

bool SteamBridge::resolvePeerId(const std::string& peerId, CSteamID& outPeerId, std::string& reason) const {
    if (!parseSteamId64(peerId, outPeerId)) {
        reason = "invalid_peer_id";
        return false;
    }
    return true;
}

bool SteamBridge::ensureSteamInputConfigured(std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!steamInputInitialized_) {
        reason = "steam_input_not_initialized";
        return false;
    }
    if (!steamInputConfigured_) {
        reason = "steam_input_not_configured";
        return false;
    }
    if (!SteamInput()) {
        reason = "steam_input_unavailable";
        return false;
    }
    return true;
}

template <typename TResult>
bool SteamBridge::waitForCallResult(SteamAPICall_t callHandle, TResult& result, std::string& reason, int timeoutMs) const {
    if (callHandle == k_uAPICallInvalid) {
        reason = "steam_api_call_invalid";
        return false;
    }
    if (!SteamUtils()) {
        reason = "steam_utils_unavailable";
        return false;
    }

    const auto start = std::chrono::steady_clock::now();
    while (true) {
        SteamAPI_RunCallbacks();

        bool failed = false;
        if (SteamUtils()->IsAPICallCompleted(callHandle, &failed)) {
            if (failed) {
                reason = "steam_api_call_failed";
                return false;
            }
            bool got = SteamUtils()->GetAPICallResult(
                callHandle,
                &result,
                sizeof(TResult),
                TResult::k_iCallback,
                &failed
            );
            if (!got || failed) {
                reason = "steam_api_call_result_failed";
                return false;
            }
            return true;
        }

        const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start
        ).count();
        if (elapsedMs >= timeoutMs) {
            reason = "steam_api_call_timeout";
            return false;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

void SteamBridge::pushLobbyEvent(const SteamLobbyEvent& event) {
    lobbyEvents_.push_back(event);
}

bool SteamBridge::init(const SteamInitOptions& options, std::string& reason) {
    if (initialized_) {
        return true;
    }

    debugLogs_ = options.debugLogs;

    if (!options.appId.empty()) {
#ifdef _WIN32
        _putenv_s("SteamAppId", options.appId.c_str());
        _putenv_s("SteamGameId", options.appId.c_str());
#else
        setenv("SteamAppId", options.appId.c_str(), 1);
        setenv("SteamGameId", options.appId.c_str(), 1);
#endif
    }

    if (options.autoRestartAppIfNeeded) {
        const uint32 appId = static_cast<uint32>(std::strtoul(options.appId.c_str(), nullptr, 10));
        if (SteamAPI_RestartAppIfNecessary(appId)) {
            reason = "steam_restart_required";
            return false;
        }
    }

    SteamErrMsg errMsg = {0};
    ESteamAPIInitResult initResult = SteamAPI_InitEx(&errMsg);
    if (initResult != k_ESteamAPIInitResult_OK) {
        reason = "steam_api_init_failed:";
        reason += std::to_string(static_cast<int>(initResult));
        if (errMsg[0] != '\0') {
            reason += ":";
            reason += errMsg;
        }
        return false;
    }

    initialized_ = true;
    remotePlayDirectInputEnabled_ = false;
    remotePlayCursorAssetsReady_ = false;
    remotePlayHiddenCursorId_ = 0;
    remotePlayLightCursor32Id_ = 0;
    remotePlayLightCursor48Id_ = 0;
    remotePlayLightCursor64Id_ = 0;
    debugLog(debugLogs_, "SteamAPI_Init succeeded");
    return true;
}

bool SteamBridge::runCallbacks() {
    if (!initialized_) {
        return true;
    }
    if (steamInputInitialized_ && SteamInput()) {
        SteamInput()->RunFrame();
    }
    SteamAPI_RunCallbacks();
    return true;
}

bool SteamBridge::shutdown() {
    if (!initialized_) {
        return true;
    }

    if (steamInputInitialized_ && SteamInput()) {
        SteamInput()->Shutdown();
    }
    remotePlayDirectInputEnabled_ = false;
    remotePlayCursorAssetsReady_ = false;
    remotePlayHiddenCursorId_ = 0;
    remotePlayLightCursor32Id_ = 0;
    remotePlayLightCursor48Id_ = 0;
    remotePlayLightCursor64Id_ = 0;
    steamInputInitialized_ = false;
    steamInputConfigured_ = false;
    steamInputManifestPath_.clear();
    steamInputActionSetName_.clear();
    steamInputActionSetHandle_ = 0;
    steamInputDigitalHandles_.clear();
    steamInputAnalogHandles_.clear();
    SteamAPI_Shutdown();
    initialized_ = false;
    leaderboardHandles_.clear();
    lobbyEvents_.clear();
    return true;
}

bool SteamBridge::activateOverlay(const std::string& target, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamFriends()) {
        reason = "steam_friends_unavailable";
        return false;
    }

    SteamFriends()->ActivateGameOverlay(target.empty() ? "Friends" : target.c_str());
    return true;
}

bool SteamBridge::setRichPresence(const std::string& key, const std::string& value, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamFriends()) {
        reason = "steam_friends_unavailable";
        return false;
    }

    return SteamFriends()->SetRichPresence(key.c_str(), value.c_str());
}

bool SteamBridge::clearRichPresence(std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamFriends()) {
        reason = "steam_friends_unavailable";
        return false;
    }

    SteamFriends()->ClearRichPresence();
    return true;
}

bool SteamBridge::showRemotePlayTogetherUI(std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamRemotePlay()) {
        reason = "steam_remote_play_unavailable";
        return false;
    }

    const bool shown = SteamRemotePlay()->ShowRemotePlayTogetherUI();
    if (!shown) {
        reason = "remote_play_ui_unavailable";
        return false;
    }

    return true;
}

int SteamBridge::getRemotePlaySessionCount(std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return 0;
    }
    if (!SteamRemotePlay()) {
        reason = "steam_remote_play_unavailable";
        return 0;
    }

    return static_cast<int>(SteamRemotePlay()->GetSessionCount());
}

std::vector<SteamRemotePlaySessionEntry> SteamBridge::listRemotePlaySessions(std::string& reason) const {
    std::vector<SteamRemotePlaySessionEntry> sessions;
    const int count = getRemotePlaySessionCount(reason);
    if (!reason.empty()) {
        return sessions;
    }

    sessions.reserve(static_cast<std::size_t>(count > 0 ? count : 0));
    for (int i = 0; i < count; ++i) {
        const RemotePlaySessionID_t sessionId = SteamRemotePlay()->GetSessionID(i);
        if (sessionId == 0) {
            continue;
        }

        SteamRemotePlaySessionEntry entry;
        entry.sessionId = static_cast<uint32_t>(sessionId);

        const CSteamID userId = SteamRemotePlay()->GetSessionSteamID(sessionId);
        if (userId.IsValid()) {
            entry.userId = steamIdToString(userId);
            if (SteamFriends()) {
                const char* persona = SteamFriends()->GetFriendPersonaName(userId);
                entry.personaName = persona ? persona : "";
            }
        }

        const char* clientName = SteamRemotePlay()->GetSessionClientName(sessionId);
        entry.clientName = clientName ? clientName : "";

        sessions.push_back(entry);
    }

    return sessions;
}

bool SteamBridge::setRemotePlayDirectInputEnabled(bool enabled, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamRemotePlay()) {
        reason = "steam_remote_play_unavailable";
        return false;
    }

    if (enabled) {
        const bool ok = SteamRemotePlay()->BEnableRemotePlayTogetherDirectInput();
        if (!ok) {
            reason = "remote_play_direct_input_enable_failed";
            return false;
        }
        remotePlayDirectInputEnabled_ = true;
        return true;
    }

    SteamRemotePlay()->DisableRemotePlayTogetherDirectInput();
    remotePlayDirectInputEnabled_ = false;
    return true;
}

std::vector<SteamRemotePlayInputEvent> SteamBridge::pollRemotePlayInput(std::size_t maxEvents, std::string& reason) const {
    std::vector<SteamRemotePlayInputEvent> events;
    if (!initialized_) {
        reason = "steam_not_initialized";
        return events;
    }
    if (!SteamRemotePlay()) {
        reason = "steam_remote_play_unavailable";
        return events;
    }

    const uint32 requested = static_cast<uint32>(std::min<std::size_t>(maxEvents > 0 ? maxEvents : 0, 256));
    if (requested == 0) {
        return events;
    }

    std::vector<RemotePlayInput_t> raw(requested);
    const uint32 count = SteamRemotePlay()->GetInput(raw.data(), requested);
    if (count == 0) {
        return events;
    }

    events.reserve(count);
    for (uint32 i = 0; i < count; ++i) {
        const RemotePlayInput_t& input = raw[i];
        SteamRemotePlayInputEvent event;
        event.sessionId = static_cast<uint32_t>(input.m_unSessionID);
        event.type = remotePlayInputTypeToString(input.m_eType);

        switch (input.m_eType) {
            case k_ERemotePlayInputMouseMotion:
                event.mouseAbsolute = input.m_MouseMotion.m_bAbsolute;
                event.mouseNormalizedX = input.m_MouseMotion.m_flNormalizedX;
                event.mouseNormalizedY = input.m_MouseMotion.m_flNormalizedY;
                event.mouseDeltaX = input.m_MouseMotion.m_nDeltaX;
                event.mouseDeltaY = input.m_MouseMotion.m_nDeltaY;
                break;
            case k_ERemotePlayInputMouseButtonDown:
            case k_ERemotePlayInputMouseButtonUp:
                event.mouseButton = static_cast<int>(input.m_eMouseButton);
                break;
            case k_ERemotePlayInputMouseWheel:
                event.wheelDirection = static_cast<int>(input.m_MouseWheel.m_eDirection);
                event.wheelAmount = input.m_MouseWheel.m_flAmount;
                break;
            case k_ERemotePlayInputKeyDown:
            case k_ERemotePlayInputKeyUp:
                event.keyScancode = input.m_Key.m_eScancode;
                event.keyModifiers = input.m_Key.m_unModifiers;
                event.keyCode = input.m_Key.m_unKeycode;
                break;
            default:
                break;
        }

        events.push_back(std::move(event));
    }

    return events;
}

bool SteamBridge::setRemotePlayMouseVisibility(uint32_t sessionId, bool visible, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamRemotePlay()) {
        reason = "steam_remote_play_unavailable";
        return false;
    }
    if (!remotePlayDirectInputEnabled_) {
        reason = "remote_play_direct_input_not_enabled";
        return false;
    }

    SteamRemotePlay()->SetMouseVisibility(static_cast<RemotePlaySessionID_t>(sessionId), visible);
    return true;
}

bool SteamBridge::setRemotePlayMouseCursor(uint32_t sessionId, const std::string& cursorKind, std::string& reason) {
    if (!ensureRemotePlayCursorAssets(reason)) {
        return false;
    }
    if (!SteamRemotePlay()) {
        reason = "steam_remote_play_unavailable";
        return false;
    }

    RemotePlayCursorID_t cursorId = remotePlayHiddenCursorId_;
    if (cursorKind != "hidden") {
        cursorId = resolveRemotePlayVisibleCursorId(sessionId);
    }
    if (cursorId == 0) {
        reason = "remote_play_cursor_invalid";
        return false;
    }

    SteamRemotePlay()->SetMouseCursor(static_cast<RemotePlaySessionID_t>(sessionId), cursorId);
    return true;
}

bool SteamBridge::setRemotePlayMousePosition(uint32_t sessionId, float normalizedX, float normalizedY, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamRemotePlay()) {
        reason = "steam_remote_play_unavailable";
        return false;
    }
    if (!remotePlayDirectInputEnabled_) {
        reason = "remote_play_direct_input_not_enabled";
        return false;
    }

    const float x = std::max(0.0f, std::min(1.0f, normalizedX));
    const float y = std::max(0.0f, std::min(1.0f, normalizedY));
    SteamRemotePlay()->SetMousePosition(static_cast<RemotePlaySessionID_t>(sessionId), x, y);
    return true;
}

RemotePlayCursorID_t SteamBridge::resolveRemotePlayVisibleCursorId(uint32_t sessionId) const {
    if (!SteamRemotePlay()) {
        return remotePlayLightCursor48Id_;
    }

    int resolutionX = 0;
    int resolutionY = 0;
    const bool hasResolution = SteamRemotePlay()->BGetSessionClientResolution(
        static_cast<RemotePlaySessionID_t>(sessionId),
        &resolutionX,
        &resolutionY
    );

    const int height = hasResolution ? ((resolutionY > 0) ? resolutionY : resolutionX) : 1440;
    if (height >= 1800 && remotePlayLightCursor64Id_ != 0) {
        return remotePlayLightCursor64Id_;
    }
    if (height >= 1200 && remotePlayLightCursor48Id_ != 0) {
        return remotePlayLightCursor48Id_;
    }
    if (remotePlayLightCursor32Id_ != 0) {
        return remotePlayLightCursor32Id_;
    }
    if (remotePlayLightCursor48Id_ != 0) {
        return remotePlayLightCursor48Id_;
    }
    return remotePlayLightCursor64Id_;
}

bool SteamBridge::ensureRemotePlayCursorAssets(std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamRemotePlay()) {
        reason = "steam_remote_play_unavailable";
        return false;
    }
    if (!remotePlayDirectInputEnabled_) {
        reason = "remote_play_direct_input_not_enabled";
        return false;
    }
    if (remotePlayCursorAssetsReady_) {
        return true;
    }

    const uint8_t transparentPixel[4] = {0, 0, 0, 0};
    remotePlayHiddenCursorId_ = SteamRemotePlay()->CreateMouseCursor(1, 1, 0, 0, transparentPixel, 4);
    if (remotePlayHiddenCursorId_ == 0) {
        reason = "remote_play_hidden_cursor_create_failed";
        return false;
    }

    const std::vector<uint8_t> lightCursor32 = buildLightArrowCursor(32);
    remotePlayLightCursor32Id_ = SteamRemotePlay()->CreateMouseCursor(32, 32, 1, 1, lightCursor32.data(), 32 * 4);
    if (remotePlayLightCursor32Id_ == 0) {
        reason = "remote_play_light_cursor_32_create_failed";
        return false;
    }

    const std::vector<uint8_t> lightCursor48 = buildLightArrowCursor(48);
    remotePlayLightCursor48Id_ = SteamRemotePlay()->CreateMouseCursor(48, 48, 2, 2, lightCursor48.data(), 48 * 4);
    if (remotePlayLightCursor48Id_ == 0) {
        reason = "remote_play_light_cursor_48_create_failed";
        return false;
    }

    const std::vector<uint8_t> lightCursor64 = buildLightArrowCursor(64);
    remotePlayLightCursor64Id_ = SteamRemotePlay()->CreateMouseCursor(64, 64, 3, 3, lightCursor64.data(), 64 * 4);
    if (remotePlayLightCursor64Id_ == 0) {
        reason = "remote_play_light_cursor_64_create_failed";
        return false;
    }

    remotePlayCursorAssetsReady_ = true;
    return true;
}

bool SteamBridge::configureSteamInput(const std::string& manifestPath,
                                      const std::string& actionSetName,
                                      const std::vector<std::string>& digitalActionNames,
                                      const std::vector<std::string>& analogActionNames,
                                      std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamInput()) {
        reason = "steam_input_unavailable";
        return false;
    }

    const bool manifestChanged = manifestPath != steamInputManifestPath_;
    if (steamInputInitialized_ && manifestChanged) {
        SteamInput()->Shutdown();
        steamInputInitialized_ = false;
        steamInputConfigured_ = false;
    }

    if (!steamInputInitialized_) {
        if (!manifestPath.empty()) {
            if (!SteamInput()->SetInputActionManifestFilePath(manifestPath.c_str())) {
                reason = "steam_input_manifest_set_failed";
                return false;
            }
        }
        if (!SteamInput()->Init(false)) {
            reason = "steam_input_init_failed";
            return false;
        }
        steamInputInitialized_ = true;
        steamInputManifestPath_ = manifestPath;
    }

    const std::string resolvedActionSet = actionSetName.empty() ? "global_controls" : actionSetName;
    const InputActionSetHandle_t actionSetHandle = SteamInput()->GetActionSetHandle(resolvedActionSet.c_str());
    if (actionSetHandle == 0) {
        reason = "steam_input_action_set_missing:" + resolvedActionSet;
        return false;
    }

    std::unordered_map<std::string, InputDigitalActionHandle_t> digitalHandles;
    for (const std::string& name : digitalActionNames) {
        if (name.empty()) {
            continue;
        }
        const InputDigitalActionHandle_t handle = SteamInput()->GetDigitalActionHandle(name.c_str());
        if (handle == 0) {
            reason = "steam_input_digital_action_missing:" + name;
            return false;
        }
        digitalHandles[name] = handle;
    }

    std::unordered_map<std::string, InputAnalogActionHandle_t> analogHandles;
    for (const std::string& name : analogActionNames) {
        if (name.empty()) {
            continue;
        }
        const InputAnalogActionHandle_t handle = SteamInput()->GetAnalogActionHandle(name.c_str());
        if (handle == 0) {
            reason = "steam_input_analog_action_missing:" + name;
            return false;
        }
        analogHandles[name] = handle;
    }

    steamInputActionSetName_ = resolvedActionSet;
    steamInputActionSetHandle_ = actionSetHandle;
    steamInputDigitalHandles_ = std::move(digitalHandles);
    steamInputAnalogHandles_ = std::move(analogHandles);
    steamInputConfigured_ = true;
    reason.clear();
    return true;
}

bool SteamBridge::shutdownSteamInput(std::string& reason) {
    if (!initialized_) {
        steamInputInitialized_ = false;
        steamInputConfigured_ = false;
        steamInputManifestPath_.clear();
        steamInputActionSetName_.clear();
        steamInputActionSetHandle_ = 0;
        steamInputDigitalHandles_.clear();
        steamInputAnalogHandles_.clear();
        return true;
    }
    if (!SteamInput()) {
        reason = "steam_input_unavailable";
        return false;
    }

    if (steamInputInitialized_) {
        SteamInput()->Shutdown();
    }

    steamInputInitialized_ = false;
    steamInputConfigured_ = false;
    steamInputManifestPath_.clear();
    steamInputActionSetName_.clear();
    steamInputActionSetHandle_ = 0;
    steamInputDigitalHandles_.clear();
    steamInputAnalogHandles_.clear();
    reason.clear();
    return true;
}

std::vector<SteamInputControllerEntry> SteamBridge::listSteamInputControllers(std::string& reason) const {
    std::vector<SteamInputControllerEntry> controllers;
    if (!initialized_) {
        reason = "steam_not_initialized";
        return controllers;
    }
    if (!steamInputInitialized_) {
        reason = "steam_input_not_initialized";
        return controllers;
    }
    if (!SteamInput()) {
        reason = "steam_input_unavailable";
        return controllers;
    }

    InputHandle_t handles[STEAM_INPUT_MAX_COUNT] = {};
    const int count = SteamInput()->GetConnectedControllers(handles);
    controllers.reserve(count > 0 ? static_cast<std::size_t>(count) : 0);
    for (int i = 0; i < count; ++i) {
        const InputHandle_t handle = handles[i];
        if (handle == 0) {
            continue;
        }

        SteamInputControllerEntry entry;
        entry.handleId = std::to_string(static_cast<unsigned long long>(handle));
        entry.remotePlaySessionId = static_cast<uint32_t>(SteamInput()->GetRemotePlaySessionID(handle));
        entry.gamepadIndex = SteamInput()->GetGamepadIndexForController(handle);
        entry.inputType = steamInputTypeToString(SteamInput()->GetInputTypeForHandle(handle));
        controllers.push_back(std::move(entry));
    }

    return controllers;
}

std::vector<SteamInputControllerSnapshot> SteamBridge::pollSteamInput(std::string& reason) {
    std::vector<SteamInputControllerSnapshot> snapshots;
    if (!ensureSteamInputConfigured(reason)) {
        return snapshots;
    }

    SteamInput()->RunFrame();

    std::vector<SteamInputControllerEntry> controllers = listSteamInputControllers(reason);
    if (!reason.empty()) {
        return snapshots;
    }

    snapshots.reserve(controllers.size());
    for (const SteamInputControllerEntry& controller : controllers) {
        InputHandle_t handle = 0;
        if (!parseInputHandle(controller.handleId, handle)) {
            continue;
        }

        SteamInput()->ActivateActionSet(handle, steamInputActionSetHandle_);

        SteamInputControllerSnapshot snapshot;
        snapshot.controller = controller;
        snapshot.digitalActions.reserve(steamInputDigitalHandles_.size());
        snapshot.analogActions.reserve(steamInputAnalogHandles_.size());

        for (const auto& entry : steamInputDigitalHandles_) {
            const InputDigitalActionData_t data = SteamInput()->GetDigitalActionData(handle, entry.second);
            SteamInputDigitalActionState actionState;
            actionState.name = entry.first;
            actionState.state = data.bState != 0;
            actionState.active = data.bActive != 0;
            snapshot.digitalActions.push_back(std::move(actionState));
        }

        for (const auto& entry : steamInputAnalogHandles_) {
            const InputAnalogActionData_t data = SteamInput()->GetAnalogActionData(handle, entry.second);
            SteamInputAnalogActionState actionState;
            actionState.name = entry.first;
            actionState.x = data.x;
            actionState.y = data.y;
            actionState.active = data.bActive != 0;
            actionState.mode = steamInputSourceModeToString(data.eMode);
            snapshot.analogActions.push_back(std::move(actionState));
        }

        snapshots.push_back(std::move(snapshot));
    }

    reason.clear();
    return snapshots;
}

bool SteamBridge::showSteamInputBindingPanel(const std::string& handleId, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!steamInputInitialized_) {
        reason = "steam_input_not_initialized";
        return false;
    }
    if (!SteamInput()) {
        reason = "steam_input_unavailable";
        return false;
    }

    InputHandle_t handle = 0;
    if (!parseInputHandle(handleId, handle)) {
        reason = "invalid_steam_input_handle";
        return false;
    }

    if (!SteamInput()->ShowBindingPanel(handle)) {
        reason = "steam_input_binding_panel_failed";
        return false;
    }

    return true;
}

bool SteamBridge::getAchievement(const std::string& achievementId, bool& achieved, std::string& reason) const {
    achieved = false;
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return false;
    }
    if (achievementId.empty()) {
        reason = "achievement_id_missing";
        return false;
    }

    bool value = false;
    if (!SteamUserStats()->GetAchievement(achievementId.c_str(), &value)) {
        reason = "get_achievement_failed";
        return false;
    }

    achieved = value;
    return true;
}

bool SteamBridge::setAchievement(const std::string& achievementId, std::string& reason) {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return false;
    }
    if (achievementId.empty()) {
        reason = "achievement_id_missing";
        return false;
    }
    if (!SteamUserStats()->SetAchievement(achievementId.c_str())) {
        reason = "set_achievement_failed";
        return false;
    }
    return true;
}

bool SteamBridge::clearAchievement(const std::string& achievementId, std::string& reason) {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return false;
    }
    if (achievementId.empty()) {
        reason = "achievement_id_missing";
        return false;
    }
    if (!SteamUserStats()->ClearAchievement(achievementId.c_str())) {
        reason = "clear_achievement_failed";
        return false;
    }
    return true;
}

bool SteamBridge::storeUserStats(std::string& reason) {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return false;
    }
    if (!SteamUserStats()->StoreStats()) {
        reason = "store_user_stats_failed";
        return false;
    }
    return true;
}

bool SteamBridge::getStatInt(const std::string& statId, int32_t& value, std::string& reason) const {
    value = 0;
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return false;
    }
    if (statId.empty()) {
        reason = "stat_id_missing";
        return false;
    }
    int32 valueOut = 0;
    if (!SteamUserStats()->GetStat(statId.c_str(), &valueOut)) {
        reason = "get_stat_failed";
        return false;
    }
    value = valueOut;
    return true;
}

bool SteamBridge::setStatInt(const std::string& statId, int32_t value, std::string& reason) {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return false;
    }
    if (statId.empty()) {
        reason = "stat_id_missing";
        return false;
    }
    if (!SteamUserStats()->SetStat(statId.c_str(), value)) {
        reason = "set_stat_failed";
        return false;
    }
    return true;
}

bool SteamBridge::incrementStatInt(const std::string& statId, int32_t delta, int32_t& newValue, std::string& reason) {
    int32_t currentValue = 0;
    if (!getStatInt(statId, currentValue, reason)) {
        return false;
    }
    newValue = currentValue + delta;
    if (!setStatInt(statId, newValue, reason)) {
        return false;
    }
    return true;
}

bool SteamBridge::getGameBadgeLevel(int series, bool foil, int& level, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamUser()) {
        reason = "steam_user_unavailable";
        return false;
    }
    if (series <= 0) {
        reason = "badge_series_invalid";
        return false;
    }

    level = SteamUser()->GetGameBadgeLevel(series, foil);
    return true;
}

bool SteamBridge::getPlayerSteamLevel(int& level, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamUser()) {
        reason = "steam_user_unavailable";
        return false;
    }

    level = SteamUser()->GetPlayerSteamLevel();
    return true;
}

bool SteamBridge::computeRatingProfileSignature(
    const std::string& canonicalPayload,
    const std::string& ownerSteamId,
    const std::string& appId,
    std::string& token,
    std::string& reason
) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (canonicalPayload.empty()) {
        reason = "rating_profile_payload_missing";
        return false;
    }
    if (ownerSteamId.empty()) {
        reason = "rating_profile_owner_missing";
        return false;
    }
    if (appId.empty()) {
        reason = "rating_profile_appid_missing";
        return false;
    }

    token = buildRatingProfileSignatureToken(canonicalPayload, ownerSteamId, appId);
    return true;
}

bool SteamBridge::getLocalUserId(std::string& userId, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamUser()) {
        reason = "steam_user_unavailable";
        return false;
    }

    userId = steamIdToString(SteamUser()->GetSteamID());
    return true;
}

bool SteamBridge::getPersonaName(std::string& personaName, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamFriends()) {
        reason = "steam_friends_unavailable";
        return false;
    }

    const char* raw = SteamFriends()->GetPersonaName();
    personaName = raw ? raw : "";
    return true;
}


bool SteamBridge::getPersonaNameForUser(const std::string& userId, std::string& personaName, std::string& reason) const {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamFriends()) {
        reason = "steam_friends_unavailable";
        return false;
    }

    CSteamID targetUser;
    if (!parseSteamId64(userId, targetUser)) {
        reason = "invalid_user_id";
        return false;
    }

    const char* raw = SteamFriends()->GetFriendPersonaName(targetUser);
    if (!raw || raw[0] == '\0') {
        reason = "persona_name_unavailable";
        return false;
    }

    personaName = raw;
    return true;
}

bool SteamBridge::createFriendsLobby(int maxMembers, SteamLobbyCreateResult& result, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return false;
    }

    const int boundedMembers = std::max(2, std::min(maxMembers, 16));
    const SteamAPICall_t call = SteamMatchmaking()->CreateLobby(k_ELobbyTypePublic, boundedMembers);

    LobbyCreated_t created {};
    if (!waitForCallResult(call, created, reason)) {
        return false;
    }

    if (created.m_eResult != k_EResultOK) {
        reason = "lobby_create_failed:" + resultToString(created.m_eResult);

        SteamLobbyEvent event;
        event.type = "lobby_create_failed";
        event.result = resultToString(created.m_eResult);
        pushLobbyEvent(event);
        return false;
    }

    result.lobbyId = steamIdToString(created.m_ulSteamIDLobby);
    if (SteamUser()) {
        result.ownerId = steamIdToString(SteamUser()->GetSteamID());
    }

    SteamLobbyEvent event;
    event.type = "lobby_created";
    event.lobbyId = result.lobbyId;
    event.ownerId = result.ownerId;
    event.result = "ok";
    pushLobbyEvent(event);

    return true;
}

bool SteamBridge::joinLobby(const std::string& lobbyId, SteamLobbyJoinResult& result, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return false;
    }

    CSteamID lobby;
    if (!resolveLobbyId(lobbyId, lobby, reason)) {
        return false;
    }

    const SteamAPICall_t call = SteamMatchmaking()->JoinLobby(lobby);
    LobbyEnter_t entered {};
    if (!waitForCallResult(call, entered, reason)) {
        return false;
    }

    const EChatRoomEnterResponse chatEnterResponse = static_cast<EChatRoomEnterResponse>(entered.m_EChatRoomEnterResponse);

    result.lobbyId = steamIdToString(entered.m_ulSteamIDLobby);
    result.enterResponse = static_cast<int>(chatEnterResponse);

    if (chatEnterResponse != k_EChatRoomEnterResponseSuccess) {
        reason = "lobby_join_failed:" + lobbyEnterResponseToString(chatEnterResponse);

        SteamLobbyEvent event;
        event.type = "lobby_join_failed";
        event.lobbyId = result.lobbyId;
        event.result = lobbyEnterResponseToString(chatEnterResponse);
        pushLobbyEvent(event);
        return false;
    }

    CSteamID owner = SteamMatchmaking()->GetLobbyOwner(CSteamID(entered.m_ulSteamIDLobby));

    SteamLobbyEvent event;
    event.type = "lobby_joined";
    event.lobbyId = result.lobbyId;
    event.ownerId = steamIdToString(owner);
    event.result = "ok";
    pushLobbyEvent(event);

    return true;
}

bool SteamBridge::leaveLobby(const std::string& lobbyId, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return false;
    }

    CSteamID lobby;
    if (!resolveLobbyId(lobbyId, lobby, reason)) {
        return false;
    }

    SteamMatchmaking()->LeaveLobby(lobby);

    SteamLobbyEvent event;
    event.type = "lobby_left";
    event.lobbyId = lobbyId;
    event.result = "ok";
    pushLobbyEvent(event);

    return true;
}

bool SteamBridge::inviteFriend(const std::string& lobbyId, const std::string& friendId, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return false;
    }

    CSteamID lobby;
    if (!resolveLobbyId(lobbyId, lobby, reason)) {
        return false;
    }

    CSteamID friendSteamId;
    if (!resolvePeerId(friendId, friendSteamId, reason)) {
        return false;
    }

    const bool invited = SteamMatchmaking()->InviteUserToLobby(lobby, friendSteamId);
    if (!invited) {
        reason = "lobby_invite_failed";
        return false;
    }

    SteamLobbyEvent event;
    event.type = "lobby_invite_requested";
    event.lobbyId = lobbyId;
    event.memberId = friendId;
    event.result = "ok";
    pushLobbyEvent(event);

    return true;
}

std::vector<SteamLobbyEvent> SteamBridge::pollLobbyEvents(std::size_t maxEvents) {
    const std::size_t limit = maxEvents == 0 ? 64 : maxEvents;
    std::vector<SteamLobbyEvent> events;
    events.reserve(std::min(limit, lobbyEvents_.size()));

    while (!lobbyEvents_.empty() && events.size() < limit) {
        events.push_back(lobbyEvents_.front());
        lobbyEvents_.pop_front();
    }

    return events;
}

bool SteamBridge::getLobbySnapshot(const std::string& lobbyId, SteamLobbySnapshot& snapshot, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return false;
    }

    CSteamID lobby;
    if (!resolveLobbyId(lobbyId, lobby, reason)) {
        return false;
    }

    snapshot = SteamLobbySnapshot {};
    snapshot.lobbyId = lobbyId;

    CSteamID owner = SteamMatchmaking()->GetLobbyOwner(lobby);
    snapshot.ownerId = steamIdToString(owner);
    const int memberCount = SteamMatchmaking()->GetNumLobbyMembers(lobby);
    snapshot.members.reserve(std::max(memberCount, 0));
    for (int i = 0; i < memberCount; ++i) {
        const CSteamID member = SteamMatchmaking()->GetLobbyMemberByIndex(lobby, i);
        snapshot.members.push_back(steamIdToString(member));
    }

    const char* sessionId = SteamMatchmaking()->GetLobbyData(lobby, "session_id");
    snapshot.sessionId = sessionId ? sessionId : "";

    const char* protocolVersion = SteamMatchmaking()->GetLobbyData(lobby, "protocol_version");
    snapshot.protocolVersion = protocolVersion ? protocolVersion : "";

    return true;
}

std::vector<SteamLobbyListEntry> SteamBridge::listJoinableLobbies(std::size_t maxResults, const std::string& protocolVersion, std::string& reason) const {
    std::vector<SteamLobbyListEntry> entries;
    reason.clear();

    if (!initialized_) {
        reason = "steam_not_initialized";
        return entries;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return entries;
    }

    const std::size_t clampedMax = std::max<std::size_t>(1, std::min<std::size_t>(maxResults == 0 ? 20 : maxResults, 100));
    const int requestCount = static_cast<int>(std::min<std::size_t>(clampedMax * 4, 100));
    SteamMatchmaking()->AddRequestLobbyListResultCountFilter(requestCount);
    SteamMatchmaking()->AddRequestLobbyListFilterSlotsAvailable(1);
    SteamMatchmaking()->AddRequestLobbyListDistanceFilter(k_ELobbyDistanceFilterWorldwide);
    SteamMatchmaking()->AddRequestLobbyListStringFilter("mom_game", "MeowOverMoo", k_ELobbyComparisonEqual);
    SteamMatchmaking()->AddRequestLobbyListStringFilter("mom_joinable", "1", k_ELobbyComparisonEqual);

    const SteamAPICall_t call = SteamMatchmaking()->RequestLobbyList();
    LobbyMatchList_t list {};
    if (!waitForCallResult(call, list, reason)) {
        return entries;
    }

    std::vector<SteamLobbyListEntry> collected;
    collected.reserve(list.m_nLobbiesMatching);

    const bool hasProtocolFilter = !protocolVersion.empty();

    for (uint32 i = 0; i < list.m_nLobbiesMatching; ++i) {
        const CSteamID lobby = SteamMatchmaking()->GetLobbyByIndex(static_cast<int>(i));
        if (!lobby.IsValid()) {
            continue;
        }

        SteamLobbyListEntry entry;
        entry.lobbyId = steamIdToString(lobby);

        const CSteamID owner = SteamMatchmaking()->GetLobbyOwner(lobby);
        entry.ownerId = steamIdToString(owner);
        if (SteamFriends() && owner.IsValid()) {
            const char* ownerName = SteamFriends()->GetFriendPersonaName(owner);
            entry.ownerName = ownerName ? ownerName : "";
            entry.relation = friendRelationToBucket(SteamFriends()->GetFriendRelationship(owner));
        } else {
            entry.ownerName = "";
            entry.relation = "other";
        }

        entry.memberCount = std::max(SteamMatchmaking()->GetNumLobbyMembers(lobby), 0);
        entry.memberLimit = std::max(SteamMatchmaking()->GetLobbyMemberLimit(lobby), 0);

        const char* sessionIdRaw = SteamMatchmaking()->GetLobbyData(lobby, "session_id");
        entry.sessionId = sessionIdRaw ? sessionIdRaw : "";

        const char* protocolRaw = SteamMatchmaking()->GetLobbyData(lobby, "protocol_version");
        entry.protocolVersion = protocolRaw ? protocolRaw : "";

        const char* joinableRaw = SteamMatchmaking()->GetLobbyData(lobby, "mom_joinable");
        entry.joinable = !joinableRaw || std::string(joinableRaw) != "0";

        if (hasProtocolFilter && !entry.protocolVersion.empty() && entry.protocolVersion != protocolVersion) {
            continue;
        }

        collected.push_back(std::move(entry));
    }

    auto sorter = [](const SteamLobbyListEntry& a, const SteamLobbyListEntry& b) {
        const int relationCmp = relationPriority(a.relation) - relationPriority(b.relation);
        if (relationCmp != 0) {
            return relationCmp < 0;
        }

        if (a.joinable != b.joinable) {
            return a.joinable && !b.joinable;
        }

        if (a.memberCount != b.memberCount) {
            return a.memberCount < b.memberCount;
        }

        return a.lobbyId < b.lobbyId;
    };

    std::stable_sort(collected.begin(), collected.end(), sorter);

    for (std::size_t i = 0; i < collected.size() && entries.size() < clampedMax; ++i) {
        entries.push_back(collected[i]);
    }

    return entries;
}

bool SteamBridge::setLobbyData(const std::string& lobbyId, const std::string& key, const std::string& value, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return false;
    }

    CSteamID lobby;
    if (!resolveLobbyId(lobbyId, lobby, reason)) {
        return false;
    }

    if (!SteamMatchmaking()->SetLobbyData(lobby, key.c_str(), value.c_str())) {
        reason = "set_lobby_data_failed";
        return false;
    }

    return true;
}

bool SteamBridge::setLobbyVisibility(const std::string& lobbyId, const std::string& visibility, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return false;
    }

    CSteamID lobby;
    if (!resolveLobbyId(lobbyId, lobby, reason)) {
        return false;
    }

    ELobbyType lobbyType = k_ELobbyTypePublic;
    if (visibility == "friends") {
        lobbyType = k_ELobbyTypeFriendsOnly;
    } else if (visibility != "public") {
        reason = "invalid_lobby_visibility";
        return false;
    }

    if (!SteamMatchmaking()->SetLobbyType(lobby, lobbyType)) {
        reason = "set_lobby_visibility_failed";
        return false;
    }

    return true;
}

bool SteamBridge::getLobbyData(const std::string& lobbyId, const std::string& key, std::string& value, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return false;
    }

    CSteamID lobby;
    if (!resolveLobbyId(lobbyId, lobby, reason)) {
        return false;
    }

    const char* raw = SteamMatchmaking()->GetLobbyData(lobby, key.c_str());
    value = raw ? raw : "";
    return true;
}

bool SteamBridge::getSteamIdFromLobbyMember(const std::string& lobbyId, int indexOneBased, std::string& steamId, std::string& reason) const {
    if (!initialized_) {
        reason = "steam_not_initialized";
        return false;
    }
    if (!SteamMatchmaking()) {
        reason = "steam_matchmaking_unavailable";
        return false;
    }

    CSteamID lobby;
    if (!resolveLobbyId(lobbyId, lobby, reason)) {
        return false;
    }

    const int index = indexOneBased - 1;
    const int memberCount = SteamMatchmaking()->GetNumLobbyMembers(lobby);
    if (index < 0 || index >= memberCount) {
        reason = "lobby_member_index_out_of_range";
        return false;
    }

    const CSteamID member = SteamMatchmaking()->GetLobbyMemberByIndex(lobby, index);
    steamId = steamIdToString(member);
    return true;
}

bool SteamBridge::sendNet(const std::string& peerId, const std::string& payload, int channel, const std::string& sendType, std::string& reason) {
    if (!requireInitialized(reason)) {
        return false;
    }

    ISteamNetworkingMessages* net = SteamNetworkingMessages();
    if (!net) {
        reason = "steam_networking_messages_unavailable";
        return false;
    }

    CSteamID peer;
    if (!resolvePeerId(peerId, peer, reason)) {
        return false;
    }

    SteamNetworkingIdentity peerIdentity {};
    peerIdentity.SetSteamID64(peer.ConvertToUint64());

    int flags = k_nSteamNetworkingSend_Reliable;
    if (sendType == "unreliable") {
        flags = k_nSteamNetworkingSend_Unreliable;
    } else if (sendType == "unreliable_nodelay") {
        flags = k_nSteamNetworkingSend_UnreliableNoDelay;
    }

    const EResult sent = net->SendMessageToUser(
        peerIdentity,
        payload.data(),
        static_cast<uint32>(payload.size()),
        flags,
        channel
    );

    if (sent != k_EResultOK) {
        reason = "send_failed:" + resultToString(sent);
        return false;
    }

    return true;
}

std::vector<SteamNetPacket> SteamBridge::pollNet(std::size_t maxPackets) {
    std::vector<SteamNetPacket> packets;

    if (!initialized_) {
        return packets;
    }

    ISteamNetworkingMessages* net = SteamNetworkingMessages();
    if (!net) {
        return packets;
    }

    const std::size_t cap = maxPackets == 0 ? 64 : maxPackets;
    packets.reserve(cap);

    const int channels[] = {0, 1, 2, 3};

    bool receivedAny = true;
    while (receivedAny && packets.size() < cap) {
        receivedAny = false;

        for (int channel : channels) {
            if (packets.size() >= cap) {
                break;
            }

            SteamNetworkingMessage_t* messages[16] = {nullptr};
            const int remaining = static_cast<int>(std::min<std::size_t>(16, cap - packets.size()));
            const int count = net->ReceiveMessagesOnChannel(channel, messages, remaining);

            if (count <= 0) {
                continue;
            }

            receivedAny = true;

            for (int i = 0; i < count; ++i) {
                SteamNetworkingMessage_t* message = messages[i];
                if (!message) {
                    continue;
                }

                SteamNetPacket packet;
                if (message->m_identityPeer.GetSteamID64() != 0ULL) {
                    packet.peerId = steamIdToString(message->m_identityPeer.GetSteamID64());
                }
                packet.channel = channel;
                if (message->m_pData && message->m_cbSize > 0) {
                    packet.payload.assign(static_cast<const char*>(message->m_pData), static_cast<std::size_t>(message->m_cbSize));
                }
                packet.recvTs = static_cast<double>(message->m_usecTimeReceived) / 1000000.0;

                packets.push_back(std::move(packet));
                message->Release();

                if (packets.size() >= cap) {
                    break;
                }
            }
        }
    }

    return packets;
}

bool SteamBridge::findLeaderboardHandle(const std::string& name, SteamLeaderboard_t& handle, std::string& reason) {
    const auto found = leaderboardHandles_.find(name);
    if (found != leaderboardHandles_.end()) {
        handle = found->second;
        return true;
    }

    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return false;
    }

    const SteamAPICall_t call = SteamUserStats()->FindLeaderboard(name.c_str());
    LeaderboardFindResult_t foundResult {};
    if (!waitForCallResult(call, foundResult, reason)) {
        return false;
    }

    if (foundResult.m_bLeaderboardFound == 0) {
        reason = "leaderboard_not_found";
        return false;
    }

    handle = foundResult.m_hSteamLeaderboard;
    leaderboardHandles_[name] = handle;
    return true;
}

bool SteamBridge::findOrCreateLeaderboard(
    const std::string& name,
    const std::string& sortMethod,
    const std::string& displayType,
    SteamLeaderboardInfo& info,
    std::string& reason
) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return false;
    }

    const SteamAPICall_t call = SteamUserStats()->FindOrCreateLeaderboard(
        name.c_str(),
        mapSortMethod(sortMethod),
        mapDisplayType(displayType)
    );

    LeaderboardFindResult_t foundResult {};
    if (!waitForCallResult(call, foundResult, reason)) {
        return false;
    }

    if (foundResult.m_bLeaderboardFound == 0) {
        reason = "leaderboard_find_or_create_failed";
        return false;
    }

    leaderboardHandles_[name] = foundResult.m_hSteamLeaderboard;
    info.name = name;
    info.handle = std::to_string(static_cast<unsigned long long>(foundResult.m_hSteamLeaderboard));
    return true;
}

bool SteamBridge::uploadLeaderboardScore(
    const std::string& name,
    int score,
    const std::vector<int32_t>& details,
    bool forceUpdate,
    std::string& reason
) {
    if (!requireInitialized(reason)) {
        return false;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return false;
    }

    SteamLeaderboard_t handle = 0;
    if (!findLeaderboardHandle(name, handle, reason)) {
        SteamLeaderboardInfo info;
        if (!findOrCreateLeaderboard(name, "descending", "numeric", info, reason)) {
            return false;
        }
        handle = leaderboardHandles_[name];
    }

    const ELeaderboardUploadScoreMethod method = forceUpdate
        ? k_ELeaderboardUploadScoreMethodForceUpdate
        : k_ELeaderboardUploadScoreMethodKeepBest;

    const int32_t* detailsData = details.empty() ? nullptr : details.data();
    const int detailsCount = static_cast<int>(details.size());

    const SteamAPICall_t call = SteamUserStats()->UploadLeaderboardScore(
        handle,
        method,
        score,
        detailsData,
        detailsCount
    );

    LeaderboardScoreUploaded_t uploaded {};
    if (!waitForCallResult(call, uploaded, reason)) {
        return false;
    }

    if (uploaded.m_bSuccess == 0) {
        reason = "leaderboard_upload_failed";
        return false;
    }

    return true;
}

std::vector<SteamLeaderboardEntryRecord> SteamBridge::downloadLeaderboardEntriesForUsers(
    const std::string& name,
    const std::vector<std::string>& userIds,
    std::string& reason
) {
    std::vector<SteamLeaderboardEntryRecord> records;

    if (!initialized_ || userIds.empty()) {
        return records;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return records;
    }

    SteamLeaderboard_t handle = 0;
    if (!findLeaderboardHandle(name, handle, reason)) {
        return records;
    }

    std::vector<CSteamID> steamIds;
    steamIds.reserve(userIds.size());
    for (const std::string& userId : userIds) {
        CSteamID steamId;
        if (parseSteamId64(userId, steamId)) {
            steamIds.push_back(steamId);
        }
    }

    if (steamIds.empty()) {
        return records;
    }

    const SteamAPICall_t call = SteamUserStats()->DownloadLeaderboardEntriesForUsers(
        handle,
        steamIds.data(),
        static_cast<int>(steamIds.size())
    );

    LeaderboardScoresDownloaded_t downloaded {};
    if (!waitForCallResult(call, downloaded, reason)) {
        return records;
    }

    records.reserve(std::max(downloaded.m_cEntryCount, 0));

    for (int i = 0; i < downloaded.m_cEntryCount; ++i) {
        LeaderboardEntry_t entry {};
        int32_t detailsBuffer[16] = {0};

        if (!SteamUserStats()->GetDownloadedLeaderboardEntry(
                downloaded.m_hSteamLeaderboardEntries,
                i,
                &entry,
                detailsBuffer,
                16)) {
            continue;
        }

        SteamLeaderboardEntryRecord record;
        record.userId = steamIdToString(entry.m_steamIDUser);
        record.score = entry.m_nScore;
        record.rank = entry.m_nGlobalRank;
        for (int detailIndex = 0; detailIndex < entry.m_cDetails && detailIndex < 16; ++detailIndex) {
            record.details.push_back(detailsBuffer[detailIndex]);
        }

        records.push_back(std::move(record));
    }

    return records;
}


std::vector<SteamLeaderboardEntryRecord> SteamBridge::downloadLeaderboardTop(
    const std::string& name,
    int startRank,
    int maxEntries,
    std::string& reason
) {
    std::vector<SteamLeaderboardEntryRecord> records;

    if (!initialized_) {
        return records;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return records;
    }

    SteamLeaderboard_t handle = 0;
    if (!findLeaderboardHandle(name, handle, reason)) {
        return records;
    }

    const int clampedStartRank = std::max(startRank, 1);
    const int clampedCount = std::max(1, std::min(maxEntries, 100));
    const int startIndex = clampedStartRank - 1;
    const int endIndex = startIndex + clampedCount - 1;

    const SteamAPICall_t call = SteamUserStats()->DownloadLeaderboardEntries(
        handle,
        k_ELeaderboardDataRequestGlobal,
        startIndex,
        endIndex
    );

    LeaderboardScoresDownloaded_t downloaded {};
    if (!waitForCallResult(call, downloaded, reason)) {
        return records;
    }

    records.reserve(std::max(downloaded.m_cEntryCount, 0));

    for (int i = 0; i < downloaded.m_cEntryCount; ++i) {
        LeaderboardEntry_t entry {};
        int32_t detailsBuffer[16] = {0};

        if (!SteamUserStats()->GetDownloadedLeaderboardEntry(
                downloaded.m_hSteamLeaderboardEntries,
                i,
                &entry,
                detailsBuffer,
                16)) {
            continue;
        }

        SteamLeaderboardEntryRecord record;
        record.userId = steamIdToString(entry.m_steamIDUser);
        record.score = entry.m_nScore;
        record.rank = entry.m_nGlobalRank;
        for (int detailIndex = 0; detailIndex < entry.m_cDetails && detailIndex < 16; ++detailIndex) {
            record.details.push_back(detailsBuffer[detailIndex]);
        }

        records.push_back(std::move(record));
    }

    return records;
}

std::vector<SteamLeaderboardEntryRecord> SteamBridge::downloadLeaderboardAroundUser(
    const std::string& name,
    int rangeStart,
    int rangeEnd,
    std::string& reason
) {
    std::vector<SteamLeaderboardEntryRecord> records;

    if (!initialized_) {
        return records;
    }
    if (!SteamUserStats()) {
        reason = "steam_user_stats_unavailable";
        return records;
    }

    SteamLeaderboard_t handle = 0;
    if (!findLeaderboardHandle(name, handle, reason)) {
        return records;
    }

    const SteamAPICall_t call = SteamUserStats()->DownloadLeaderboardEntries(
        handle,
        k_ELeaderboardDataRequestGlobalAroundUser,
        rangeStart,
        rangeEnd
    );

    LeaderboardScoresDownloaded_t downloaded {};
    if (!waitForCallResult(call, downloaded, reason)) {
        return records;
    }

    records.reserve(std::max(downloaded.m_cEntryCount, 0));

    for (int i = 0; i < downloaded.m_cEntryCount; ++i) {
        LeaderboardEntry_t entry {};
        int32_t detailsBuffer[16] = {0};

        if (!SteamUserStats()->GetDownloadedLeaderboardEntry(
                downloaded.m_hSteamLeaderboardEntries,
                i,
                &entry,
                detailsBuffer,
                16)) {
            continue;
        }

        SteamLeaderboardEntryRecord record;
        record.userId = steamIdToString(entry.m_steamIDUser);
        record.score = entry.m_nScore;
        record.rank = entry.m_nGlobalRank;
        for (int detailIndex = 0; detailIndex < entry.m_cDetails && detailIndex < 16; ++detailIndex) {
            record.details.push_back(detailsBuffer[detailIndex]);
        }

        records.push_back(std::move(record));
    }

    return records;
}

void SteamBridge::onLobbyJoinRequested(GameLobbyJoinRequested_t* data) {
    if (!data) {
        return;
    }

    SteamLobbyEvent event;
    event.type = "lobby_invite_requested";
    event.lobbyId = steamIdToString(data->m_steamIDLobby);
    event.memberId = steamIdToString(data->m_steamIDFriend);
    event.result = "requested";
    pushLobbyEvent(event);
}

void SteamBridge::onLobbyInvite(LobbyInvite_t* data) {
    if (!data) {
        return;
    }

    SteamLobbyEvent event;
    event.type = "lobby_invite_received";
    event.lobbyId = steamIdToString(data->m_ulSteamIDLobby);
    event.memberId = steamIdToString(data->m_ulSteamIDUser);
    event.result = "received";
    pushLobbyEvent(event);
}

void SteamBridge::onLobbyChatUpdate(LobbyChatUpdate_t* data) {
    if (!data) {
        return;
    }

    SteamLobbyEvent event;
    event.type = "lobby_member_update";
    event.lobbyId = steamIdToString(data->m_ulSteamIDLobby);
    event.memberId = steamIdToString(data->m_ulSteamIDUserChanged);
    event.ownerId = steamIdToString(data->m_ulSteamIDMakingChange);
    event.memberState = static_cast<int>(data->m_rgfChatMemberStateChange);
    event.result = "ok";
    pushLobbyEvent(event);
}

void SteamBridge::onLobbyDataUpdate(LobbyDataUpdate_t* data) {
    if (!data) {
        return;
    }

    SteamLobbyEvent event;
    event.type = "lobby_data_update";
    event.lobbyId = steamIdToString(data->m_ulSteamIDLobby);
    event.memberId = steamIdToString(data->m_ulSteamIDMember);
    event.result = data->m_bSuccess != 0 ? "ok" : "failed";
    pushLobbyEvent(event);
}

void SteamBridge::onRemotePlaySessionConnected(SteamRemotePlaySessionConnected_t* data) {
    if (!data) {
        return;
    }

    SteamLobbyEvent event;
    event.type = "remote_play_session_connected";
    event.result = "connected";
    event.memberId = std::to_string(static_cast<unsigned long long>(data->m_unSessionID));
    pushLobbyEvent(event);
}

void SteamBridge::onRemotePlaySessionDisconnected(SteamRemotePlaySessionDisconnected_t* data) {
    if (!data) {
        return;
    }

    SteamLobbyEvent event;
    event.type = "remote_play_session_disconnected";
    event.result = "disconnected";
    event.memberId = std::to_string(static_cast<unsigned long long>(data->m_unSessionID));
    pushLobbyEvent(event);
}

void SteamBridge::onNetworkingSessionRequest(SteamNetworkingMessagesSessionRequest_t* data) {
    if (!data) {
        return;
    }

    ISteamNetworkingMessages* net = SteamNetworkingMessages();
    if (!net) {
        debugLog(debugLogs_, "Networking session request received but SteamNetworkingMessages unavailable");
        return;
    }

    const bool accepted = net->AcceptSessionWithUser(data->m_identityRemote);
    if (debugLogs_) {
        const uint64 peerSteamId = data->m_identityRemote.GetSteamID64();
        std::string msg = "Networking session request peer=" + steamIdToString(peerSteamId) +
            " accepted=" + (accepted ? "true" : "false");
        debugLog(debugLogs_, msg.c_str());
    }
}

void SteamBridge::onNetworkingSessionFailed(SteamNetworkingMessagesSessionFailed_t* data) {
    if (!data) {
        return;
    }
    if (debugLogs_) {
        const uint64 peerSteamId = data->m_info.m_identityRemote.GetSteamID64();
        std::string msg = "Networking session failed peer=" + steamIdToString(peerSteamId) +
            " endReason=" + std::to_string(static_cast<int>(data->m_info.m_eEndReason));
        debugLog(debugLogs_, msg.c_str());
    }
}
