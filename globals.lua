_G.love = require("love")

local Controller = require("controller")
local Factions = require("factions")

local function createDefaultControllers()
    local controllers = {}

    local faction1Controller = Controller.new({
        id = "local_player_1",
        nickname = "Player 1",
        type = Controller.TYPES.HUMAN,
        isLocal = true,
        metadata = { slot = 1 }
    })

    local faction2Controller = Controller.new({
        id = "local_ai_1",
        nickname = "AI Commander",
        type = Controller.TYPES.AI,
        isLocal = true,
        metadata = { slot = 2 }
    })

    local player2Controller = Controller.new({
        id = "local_player_2",
        nickname = "Player 2",
        type = Controller.TYPES.HUMAN,
        isLocal = true,
        metadata = { slot = 2 }
    })

    local ai2Controller = Controller.new({
        id = "local_ai_2",
        nickname = "AI Commander 2",
        type = Controller.TYPES.AI,
        isLocal = true,
        metadata = { slot = 2 }
    })

    controllers[faction1Controller.id] = faction1Controller
    controllers[faction2Controller.id] = faction2Controller
    controllers[player2Controller.id] = player2Controller
    controllers[ai2Controller.id] = ai2Controller

    return controllers, faction1Controller.id, faction2Controller.id
end

local DEFAULT_CONTROLLERS, DEFAULT_FACTION1_CONTROLLER_ID, DEFAULT_FACTION2_CONTROLLER_ID = createDefaultControllers()

local function cloneControllerMap(source)
    local copy = {}
    for id, controller in pairs(source or {}) do
        copy[id] = controller
    end
    return copy
end

local function refreshDerivedAssignmentState()
    if not GAME or not GAME.CURRENT then
        return
    end

    local assignments = GAME.CURRENT.FACTION_ASSIGNMENTS or {}
    local controllers = GAME.CURRENT.CONTROLLERS or {}

    local aiPlayerNumber = GAME.getAIFactionId()
    GAME.CURRENT.AI_PLAYER_NUMBER = aiPlayerNumber
    GAME.CURRENT.PLAYER_1_FACTION = 1
    GAME.CURRENT.TURN_ORDER = Factions.getTurnOrder()
end

VERSION = "1.0.0.1"
PLATFORM_BUILD_LABEL = "Windows Edition"
SETTINGS = {
    DISPLAY = {
        BORDERLESS = false,
        FULLSCREEN = false,
        RESIZABLE = false,
        SCALE = 1,
        WIDTH = 1280,
        HEIGHT = 800,
        VSYNC = 1,
        CENTERED = true,
        DISPLAY = 1,
        MINWIDTH = 500,
        MINHEIGHT = 325,
        HIGHDPI = false,
        OFFSETX = 0,
        OFFSETY = 0
    },
    FONT = {
        INFO_SIZE = 16,
        DEFAULT_SIZE = 20,
        TITLE_SIZE = 24,
        BIG_SIZE = 32
    },
    AUDIO = {
        SFX = true,
        SFX_VOLUME = 0.4,
        MUSIC = true,
        MUSIC_VOLUME = 0.1
    },
    -- Build-time feature switches. Do not expose these in runtime menus.
    FEATURES = {
        SCENARIO_MODE = false
    },
    INPUT = {
        GAMEPAD_AXIS_THRESHOLD = 0.45,
        GAMEPAD_AXIS_RELEASE_THRESHOLD = 0.35,
        GAMEPAD_AXIS_INITIAL_REPEAT_DELAY = 0.25,
        GAMEPAD_AXIS_REPEAT_INTERVAL = 0.08,
        GAMEPAD_BUTTON_INITIAL_REPEAT_DELAY = 0.25,
        GAMEPAD_BUTTON_REPEAT_INTERVAL = 0.08,
        TOUCH_PRIMARY_ONLY = true
    },
    PERF = {
        ENABLE_PROFILING = false,
        OVERLAY_ENABLED = false,
        CAPTURE_ENABLED = false,
        CAPTURE_PATH = "docs/perf_last_session.csv",
        SUMMARY_PATH = "docs/perf_last_session_summary.txt",
        HITCH_THRESHOLD_MS = 33.0,
        LOG_LEVEL = "warn",
        LOG_CATEGORIES = {
            AI = false,
            GAMEPLAY = false,
            GRID = false,
            UI = false,
            PERF = false
        },
        DRAW_CACHE_ENABLED = true,
        WRAP_CACHE_ENABLED = true
    },
    STEAM = {
        ENABLED = true,
        APP_ID = "1573941",
        BRIDGE_MODULE = "integrations.steam.bridge",
        AUTO_RESTART_APP_IF_NEEDED = false,
        REQUIRED = false,
        GUIDE_BUTTON_OVERLAY = "Friends",
        DEBUG_LOGS = false,
        SDK_ROOT = "integrations/steam/sdk",
        REDISTRIBUTABLE_ROOT = "integrations/steam/redist"
    },
    STEAM_ONLINE = {
        PROTOCOL_VERSION = 1,
        RECONNECT_TIMEOUT_SEC = 30,
        HEARTBEAT_SEC = 1,
        PACKET_CHANNEL_ACTION = 1,
        PACKET_CHANNEL_CONTROL = 2
    },
    RATING = {
        LEADERBOARD_NAME = "global_glicko2_v1",
        DEFAULT_RATING = 1200,
        DEFAULT_RD = 350,
        MIGRATED_DEFAULT_RD = 200,
        DEFAULT_VOLATILITY = 0.06,
        TAU = 0.5,
        CONVERGENCE_EPSILON = 0.000001,
        MIN_RATING = 100,
        MAX_RATING = 5000,
        MIN_RD = 40,
        MAX_RD = 350,
        UPDATE_ON_DRAW = true,
        UPDATE_ON_TIMEOUT_FORFEIT = true,
        UPDATE_ON_DESYNC_ABORT = false,
        REMATCH_WINDOW_DAYS = 1,
        REMATCH_MAX_RANKED = 2,
        PROFILE_FILE = "OnlineRatingProfile.dat"
    }
}

SETTINGS.ELO = SETTINGS.RATING

-- Granular debug flags
DEBUG = {
    AI = true,
    UI = false,
    RENDER = false,
    AUDIO = false
}
GAME = {
    CONSTANTS = {
        TILE_SIZE = 90,
        GRID_WIDTH = 720,
        GRID_HEIGHT = 720,
        GRID_SIZE = 8,
        GRID_ORIGIN_X = (SETTINGS.DISPLAY.WIDTH - 720) / 2,
        GRID_ORIGIN_Y = (SETTINGS.DISPLAY.HEIGHT - 720) / 2,
        MOVE_DURATION = 0.2,
        MAX_ACTIONS_PER_TURN = 2,
        MAX_AI_DECISION_TIME_MS = 500,
        MAX_TURNS_WITHOUT_DAMAGE = 20,
        -- Clamp large frame deltas so animation/scheduled timing does not skip after AI spikes.
        MAX_ANIMATION_FRAME_DT = 1 / 30,
        FACTION_IDS = {1, 2},
        FACTIONS = {
            [1] = Factions.getById(1),
            [2] = Factions.getById(2)
        }
    },
    MODE = {
        SINGLE_PLAYER = "singlePlayer",
        MULTYPLAYER_LOCAL = "localMultyplayer",
        MULTYPLAYER_NET = "onlineMultyplayer",
        SCENARIO = "scenarioMode",
        AI_VS_AI = "aiVsAi",
    },
    -- AI always plays optimally - no difficulty levels needed
    -- AI uses one baseline profile across all AI characters/controllers.
    CURRENT = {
        MODE = "singlePlayer",
        -- AI always plays optimally - no difficulty setting needed
        AI_PLAYER_NUMBER = 2,
        PLAYER_1_FACTION = 1,
        TURN = 1,
        SEED = 0,
        CONTROLLERS = DEFAULT_CONTROLLERS,
        CONTROLLER_SEQUENCE = {
            DEFAULT_FACTION1_CONTROLLER_ID,
            DEFAULT_FACTION2_CONTROLLER_ID
        },
        FACTION_ASSIGNMENTS = {
            [1] = DEFAULT_FACTION1_CONTROLLER_ID,
            [2] = DEFAULT_FACTION2_CONTROLLER_ID
        },
        TURN_ORDER = Factions.getTurnOrder(),
        LOCAL_MATCH_VARIANT = "couch",
        SCENARIO = nil,
        SCENARIO_REQUESTED_MODE = nil,
        REMOTE_PLAY_EXIT_PROMPT_PENDING = false,
        ONLINE = {
            active = false,
            role = nil,
            session = nil,
            lockstep = nil
        }
    },
}

function GAME.getFactionDefinition(factionId)
    return GAME.CONSTANTS.FACTIONS[factionId]
end

function GAME.getController(controllerId)
    if not controllerId then
        return nil
    end
    local controllers = GAME.CURRENT.CONTROLLERS
    return controllers and controllers[controllerId]
end

function GAME.getControllerForFaction(factionId)
    local assignments = GAME.CURRENT.FACTION_ASSIGNMENTS
    if not assignments then
        return nil
    end
    local controllerId = assignments[factionId]
    return GAME.getController(controllerId)
end

function GAME.getAIFactionId()
    if not GAME or not GAME.CURRENT then
        return nil
    end

    local assignments = GAME.CURRENT.FACTION_ASSIGNMENTS or {}
    local controllers = GAME.CURRENT.CONTROLLERS or {}

    for factionId, controllerId in pairs(assignments) do
        local controller = controllers[controllerId]
        if controller and controller.type == Controller.TYPES.AI then
            return factionId
        end
    end

    return nil
end

function GAME.isFactionControlledByAI(factionId)
    local controller = GAME.getControllerForFaction(factionId)
    return controller and controller.type == Controller.TYPES.AI or false
end

function GAME.isFactionControlledLocally(factionId)
    local controller = GAME.getControllerForFaction(factionId)
    if not controller then
        return false
    end
    return controller.isLocal ~= false
end

function GAME.getLocalFactionId()
    for factionId = 1, 2 do
        if GAME.isFactionControlledLocally(factionId) then
            return factionId
        end
    end
    return nil
end

function GAME.getFactionControllerNickname(factionId)
    local controller = GAME.getControllerForFaction(factionId)
    return controller and controller.nickname or nil
end

function GAME.assignControllerToFaction(controllerId, factionId)
    if not factionId or not controllerId then
        return false
    end
    GAME.CURRENT.FACTION_ASSIGNMENTS = GAME.CURRENT.FACTION_ASSIGNMENTS or {}
    GAME.CURRENT.FACTION_ASSIGNMENTS[factionId] = controllerId
    refreshDerivedAssignmentState()
    return true
end

function GAME.setControllers(controllerTable)
    GAME.CURRENT.CONTROLLERS = cloneControllerMap(controllerTable)
    refreshDerivedAssignmentState()
end

function GAME.setControllerSequence(sequence)
    GAME.CURRENT.CONTROLLER_SEQUENCE = sequence or {}
    refreshDerivedAssignmentState()
end

function GAME.resetToDefaultControllers()
    GAME.CURRENT.CONTROLLERS = cloneControllerMap(DEFAULT_CONTROLLERS)
    GAME.CURRENT.FACTION_ASSIGNMENTS = {
        [1] = DEFAULT_FACTION1_CONTROLLER_ID,
        [2] = DEFAULT_FACTION2_CONTROLLER_ID
    }
    GAME.CURRENT.CONTROLLER_SEQUENCE = {
        DEFAULT_FACTION1_CONTROLLER_ID,
        DEFAULT_FACTION2_CONTROLLER_ID
    }
    refreshDerivedAssignmentState()
end

-- Global mouse visibility state
MOUSE_STATE = {
    IS_HIDDEN = false  -- Tracks if mouse cursor is currently hidden
}

-- Global hover indicator visibility state
HOVER_INDICATOR_STATE = {
    IS_HIDDEN = false  -- Tracks if hover indicator is currently hidden
}
