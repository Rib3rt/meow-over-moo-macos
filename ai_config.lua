-- AI Configuration Module
-- Contains all AI parameters and constants

local aiConfig = {}

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy

    for k, v in pairs(value) do
        copy[deepCopy(k, seen)] = deepCopy(v, seen)
    end

    return copy
end

local SHARED_RUNTIME = {
    ZERO = 0,
    MIN_HP = 1,
    DEFAULT_TURN = 1,
    DEFAULT_GRID_SIZE = 8,
    DISTANCE_FALLBACK = 999,
    PLAYER_INDEX_SUM = 3,
}

local SHARED_PLAYERS = {
    NEUTRAL = 0,
    PLAYER_ONE = 1,
    PLAYER_TWO = 2,
}

local SHARED_RANGED_RANGE = {
    MIN = 2,
    MAX = 3,
}

local SHARED_CORVETTE = {
    TARGET_SCORES = {
        COMMANDANT = 70,
        HEAVY = 40,
        DEFAULT = 20,
    },
    HEAVY_UNITS = { "Bastion", "Crusher" },
    ADJACENT_ENEMY_PENALTY = 100,
    ADJACENT_IGNORE_UNITS = { "Cloudstriker" },
    HUB_BONUSES = {
        LINE_OF_SIGHT = 100,
        IN_RANGE = 50,
        EXTENDED_RANGE = 25,
    },
    EDGE = {
        DISTANCE_THRESHOLD = 2,
        BONUS = 30,
    }
}

local SHARED_RISKY_ATTACK_FILTER = {
    MIN_DAMAGE = 2,
    CHIP_DAMAGE_MIN = 1,
    ALLOW_RANGED_CHIP = true,
    ALLOW_DRAW_URGENCY_CHIP = true,
    REJECT_SPECIAL = true,
    REJECT_LEAVE_AT_ONE_HP = true,
}

local SHARED_MOBILITY = {
    TILE_SCORE = {
        IMMEDIATE_WEIGHT = 30,
        TWO_STEP_WEIGHT = 14,
    },
    OBJECTIVE_SUPPORT = {
        PROGRESS_PER_TILE = 30,
        VALUE_WEIGHT_BASE = 120,
        APPROACH_BONUS = 15,
        SUPPORT_MULTIPLIER = 0.9,
        SUPPORT_FLAT = 70,
        COMMANDANT_VALUE = 320
    },
    SUPPORT_REINFORCEMENT = {
        BASE_SCORE = 200,
        DIST_WEIGHT = 30,
        IMPROVEMENT_BONUS = 60,
        REGRESSION_PENALTY = 30,
        PRIMARY_PROXIMITY_BASE = 60,
        PRIMARY_PROXIMITY_STEP = 15,
        DIAGONAL_SUPPORT_BONUS = 80,
        TWO_STEP_SUPPORT_BONUS = 65,
        PRIMARY_EXCESS_THRESHOLD = 2,
        PRIMARY_EXCESS_PENALTY = 20,
        MOBILITY_WEIGHT = 8,
        RANGED_ALIGNMENT_BONUS = 25,
        RANGED_BETWEEN_BONUS = 35,
        MOVE_BONUS_BASE = 40,
        MOVE_DISTANCE_WEIGHT = 12,
        PATH_MAX_STEPS = 2,
        MIN_DIST_FROM_PRIMARY = 2,
        CLEAR_TO_TARGET_MAX_DIST = 2
    },
    SUPPORT_FOLLOW_UP = {
        PATH_MAX_STEPS = 2,
        CURRENT_DIST_MIN_EXCLUSIVE = 2,
        HEALER_HUB_RADIUS = 3,
        PATH_TO_TARGET_DIST_MAX = 2,
        NOT_HUGGING_ATTACKER_MIN = 1,
        ATTACKER_PROX_OR_PATH_DIST = 2,
        MELEE_SUPPORT_DIST = 1,
        RANGED_PROXIMITY_BASE = 20,
        RANGED_PROXIMITY_STEP = 10,
        MELEE_PROXIMITY_BASE = 30,
        MELEE_PROXIMITY_STEP = 15,
        RANGED_VALUE_BONUS = 15,
        MIN_CANDIDATE_VALUE = 0
    }
}

local SHARED_SUPPLY_EVAL = {
    UNIT_SPAWN_VALUES_UNDER_ATTACK = {
        Bastion = 60,
        Crusher = 90,
        Earthstalker = 100,
        Artillery = 95,
        Cloudstriker = 40,
        Wingstalker = 70,
        Healer = 40,
    },
    UNIT_SPAWN_VALUES = {
        Bastion = 40,
        Crusher = 70,
        Earthstalker = 50,
        Artillery = 95,
        Cloudstriker = 100,
        Wingstalker = 75,
        Healer = 90,
    },
    GOOD_FIRING_LANE = 20,
    BLOCK_LINE_OF_SIGHT = 50,
}

local SHARED_POSITIONAL_COMPONENT_WEIGHTS = {
    IMPROVEMENT = 1.0,
    REPAIR = 0.9,
    THREAT = 0.8,
    OFFENSIVE = 0.45,
    FORWARD_PRESSURE = 0.5
}

local SHARED_WINGSTALKER_PROFILE = {
    tags = {scout = true, mobile = true, wingstalker = true},
    targetPriority = 20,
    targetTier = 1
}

local RULE_CONTRACT = {
    SETUP = {
        OBSTACLES = {
            COUNT = 4,
            ROWS = {3, 4, 5, 6},
            ONE_PER_ROW = true,
            RANDOMIZE_COLUMN = true
        },
        COMMANDANT_ZONE = {
            [1] = {MIN_ROW = 1, MAX_ROW = 2},
            [2] = {MIN_ROW = 7, MAX_ROW = 8}
        },
        INITIAL_DEPLOY = {
            COUNT = 1,
            ADJACENT_ORTHOGONAL_ONLY = true
        }
    },
    TURN = {
        ACTIONS_PER_TURN = 2,
        PHASE_ORDER = {"commandHub", "actions", "endTurn"},
        DEPLOY_PER_TURN = 1
    },
    ACTIONS = {
        MANDATORY_ACTION_COUNT = 2,
        SKIP_ONLY_WHEN_NO_LEGAL_ACTIONS = true,
        SURROUNDED_UNIT_EXCEPTION = true,
        HEALER_FULL_HP_REPAIR_EXCEPTION = true
    },
    DRAW = {
        START_TURN = 10,
        NO_INTERACTION_LIMIT = 20,
        COUNTER_UNIT = "player_turn",
        RESET_ON_ANY_ATTACK = true,
        RESET_ON_ZERO_DAMAGE_ATTACK = true,
        RESET_ON_COMMANDANT_ATTACK = true
    },
    PERFORMANCE = {
        DECISION_BUDGET_MS = 500,
        MAX_SAMPLE_WINDOW = 200,
        REPORT_INTERVAL = 20,
        DETERMINISM_CHECK = true,
        DETERMINISM_CACHE_SIZE = 500
    }
}

local BASE_AI_PARAMS = {
    RULE_CONTRACT = RULE_CONTRACT,
    -- Evaluation weights
    EVAL = {
        -- Unit base values (canonical keys are in-game unit names).
        UNIT_VALUES = {
            Commandant = 150,
            Artillery = 90,
            Bastion = 70,
            Crusher = 80,
            Earthstalker = 75,
            Cloudstriker = 75,
            Wingstalker = 45,
            Healer = 40,
            Rock = 0,
        },

        -- Compatibility aliases (canonical source is SCORES.SUPPLY_EVAL).
        UNIT_SPAWN_VALUES_UNDER_ATTACK = SHARED_SUPPLY_EVAL.UNIT_SPAWN_VALUES_UNDER_ATTACK,
        UNIT_SPAWN_VALUES = SHARED_SUPPLY_EVAL.UNIT_SPAWN_VALUES,

        ROLE_BONUSES = {
            HEALER = {
                DAMAGED_ALLY_BONUS = 20,
                NEARBY_DISTANCE = 3,
                NEARBY_DAMAGE_WEIGHT = 50,
            },
            SCOUT = {
                EARLY_BONUS_BASE = 50,
                EARLY_BONUS_DECAY = 5,
            }
        },

        EXPOSURE = {
            MAX_DISTANCE = 3,
            ENEMY_WEIGHT = 10,
            ALLY_WEIGHT = 5,
        },

        THREAT = {
            BASE_DIVISOR = 10,
            DISTANCE = {
                BASE = 10,
                MULTIPLIER = 5,
            },
            UNIT_MULTIPLIERS = {
                Bastion = 1.5,
                Cloudstriker = 1.3,
                Artillery = 1.4,
                Wingstalker = 0.7,
            },
            HUB_MAX_DISTANCE = 4,
        },
        DEFAULTS = {
            ZERO_VALUE = 0,
            MIN_HP = 1,
            CURRENT_TURN = 1,
            UNIT_MULTIPLIER = 1
        },
        UNIT_VALUE_ALIASES = {},

        POSITIONAL = {
            FREE_CELL_BONUS = 6,
            FREE_CELL_PENALTY = 4
        },

        -- Compatibility alias (canonical source is SCORES.MOBILITY).
        MOBILITY = SHARED_MOBILITY,
        -- Compatibility aliases (canonical source is SCORES.SUPPLY_EVAL).
        POSITION = SHARED_SUPPLY_EVAL,
        TACTICAL = SHARED_SUPPLY_EVAL
    },

    -- Unified scoring knobs used by ai_decision.lua. Keep these in one place.
    SCORES = {
        UNIT_EVAL = {},
        MOBILITY = SHARED_MOBILITY,
        SUPPLY_EVAL = SHARED_SUPPLY_EVAL,
        CORVETTE = {
            ATTACK_COMMANDANT = SHARED_CORVETTE.TARGET_SCORES.COMMANDANT,
            ATTACK_HIGH_VALUE = SHARED_CORVETTE.TARGET_SCORES.HEAVY,
            ATTACK_STANDARD = SHARED_CORVETTE.TARGET_SCORES.DEFAULT,
            ADJACENT_ENEMY_PENALTY = SHARED_CORVETTE.ADJACENT_ENEMY_PENALTY,
            HUB_LOS_BONUS = SHARED_CORVETTE.HUB_BONUSES.LINE_OF_SIGHT,
            HUB_RANGE_NO_LOS_BONUS = SHARED_CORVETTE.HUB_BONUSES.IN_RANGE,
            HUB_RANGE_DIST4_BONUS = SHARED_CORVETTE.HUB_BONUSES.EXTENDED_RANGE,
            CENTER_BONUS = SHARED_CORVETTE.EDGE.BONUS
        },
        SAFETY = {
            BASE_SCORE = 1000,
            DIRECT_THREAT_MULT = 50,
            MOVE_THREAT_MULT = 25,
            FRIENDLY_SUPPORT_PER_TILE = 10,
            COMMANDER_EXPOSURE = {
                LINE_OPEN_DAMAGE_MULT = 80,
                VACATED_REACH_DAMAGE_MULT = 60,
                VACATED_REACH_DISTANCE_BUFFER = 2
            }
        },
        SAFETY_POLICY = {
            move_strict = {
                checkVulnerable = true,
                requireVulnerable = false,
                allowSuicidalMove = false
            },
            move_base = {
                checkVulnerable = false,
                requireVulnerable = false,
                allowSuicidalMove = false
            },
            move_risky = {
                checkVulnerable = false,
                requireVulnerable = true,
                allowSuicidalMove = false
            },
            attack_base = {
                allowSuicidalAttack = false,
                allowBeneficialSuicide = false
            },
            attack_beneficial = {
                allowSuicidalAttack = false,
                allowBeneficialSuicide = true
            },
            attack_unrestricted = {
                allowSuicidalAttack = true,
                allowBeneficialSuicide = false
            }
        },
        POSITIONAL = {
            RANGED_ADJACENT_THREAT_PENALTY = 75,
            HISTORY_KEEP_TURNS = 10,
            INFLUENCE_WEIGHT = 1.35,
            COMPONENT_WEIGHTS = deepCopy(SHARED_POSITIONAL_COMPONENT_WEIGHTS),
            PRESSURE_PHASE = {
                TURN_BUCKET = 3,
                OFFENSIVE_LOG_MULT = 15,
                DEFENSIVE_LOG_MULT = 7.5,
                ENEMY_PROX_DIST_NORMALIZER = 10,
                PRESSURE_SCALE = 0.7
            },
            RANGED_LANE = {
                IDEAL_RANGE = 2,
                IDEAL_RANGE_BONUS = 60,
                SETUP_RANGE_BONUS = 30,
                NO_TARGET_PENALTY_RANGED = 35,
                NO_TARGET_PENALTY_MELEE = 70,
                NEW_TARGET_ONLY_PENALTY = 25,
                ZERO_OVERLAP_PENALTY = 40,
                RANGE_REGRESSION_PENALTY = 30,
                FRIENDLY_LOS_BLOCK_PENALTY = 150,
                CROSSFIRE_OVERLAP_BONUS = 28,
                HUB_THREAT_FOCUS_BONUS = 45,
                HUB_THREAT_DISTANCE_MAX = 3
            },
            THREAT_WEIGHT = 1.0,
            SAFE_THRESHOLD = {
                BASE = 5,
                HIGH_THREAT_VALUE = 40,
                HIGH_FACTOR = 0.2,
                HIGH_MIN = 2,
                MED_THREAT_VALUE = 20,
                MED_FACTOR = 0.4,
                MED_MIN = 3,
                UNIT_OVERRIDE = {
                    corvette = 15,
                    healer = 8,
                    earthstalker = 5
                }
            },
            RISKY_THRESHOLD = {
                BASE = -5,
                HIGH_THREAT_VALUE = 50,
                HIGH_FACTOR = 1.6,
                HIGH_MIN = -8,
                MED_THREAT_VALUE = 30,
                MED_FACTOR = 1.0,
                MED_MIN = -5,
                LOW_THREAT_VALUE = 10,
                LOW_FACTOR = 0.4,
                LOW_MIN = -2,
                UNIT_OVERRIDE = {
                    corvette = 0,
                    healer = 0,
                    earthstalker = 0
                }
            },
            FORWARD_PRESSURE = {
                CLOSER_PER_TILE = 60,
                CLOSE_RANGE = 3,
                CLOSE_RANGE_BONUS = 180,
                RETREAT_PER_TILE = 30
            },
            REPAIR_ADJACENCY = {
                BASE = 50,
                MISSING_HP_MULT = 10
            },
            WINGSTALKER_DISENGAGE = {
                THREAT_DISTANCE_MAX = 1,
                PENALTY = 250
            },
            HEALER_ORBIT = {
                IDEAL_MIN = 2,
                IDEAL_MAX = 3,
                IDEAL_BONUS = 200,
                DISTANCE_PENALTY_MULT = 120,
                REPOSITION_BONUS = 90,
                ADJACENT_PENALTY = 160
            },
            RISKY_PENALTY = {
                IMMEDIATE_DAMAGE_PER_HP = 30,
                VULNERABLE_VALUE = 40
            }
        },
        PATH_OPENING = {
            HIGH_VALUE_BONUS = 40,
            MID_VALUE_BONUS = 25,
            BASE_BONUS = 15
        },
        THREAT_COUNTER = {
            BASE = 20,
            DISTANCE_PENALTY = 5,
            LOOKAHEAD_TURNS = 3,
            MAX_THREAT_TURN = 2,
            FRONTIER_MAX = 24,
            LOOKAHEAD_BONUS = {
                NOW = 40,
                NEXT = 20,
                LATE = 8
            },
            BONUS_BY_TAG = {
                tank = 15,
                corvette = 10
            }
        },
        THREAT_RELEASE_OFFENSE = {
            ENABLED = true,
            MEMORY_TURNS = 3,
            ARM_ON_THREAT_LEVEL = 120,
            ARM_ON_HUB_HP_AT_OR_BELOW = 8,
            RELEASE_THREAT_LEVEL_MAX = 60,
            ATTACK_BONUS = 180,
            MOVE_ATTACK_BONUS = 150,
            ENEMY_HUB_ADJ_BONUS = 110,
            ENEMY_HUB_NEAR_DISTANCE = 2,
            ENEMY_HUB_NEAR_BONUS = 60,
            SUPPRESS_DEFENSIVE_REPOSITION = true,
            SUPPRESS_GUARD_REPOSITION = true
        },
        COMMANDANT_THREAT_RESPONSE = {
            ACTIVATE_ON_POTENTIAL = false,
            TRIGGER_THREAT_LEVEL = 80,
            MIN_THREAT_LEVEL = 20,
            HUB_HP_TRIGGER = 8,
            CRITICAL_HUB_HP = 6,
            EMERGENCY_THREAT_LEVEL = 220,
            CRITICAL_THREAT_LEVEL = 180,
            UNDER_ATTACK_ALLOW_TWO_ACTIONS = true,
            UNDER_ATTACK_TWO_ACTIONS_MIN_THREAT = 140,
            UNDER_ATTACK_TWO_ACTIONS_FOR_RANGED = true,
            ALLOW_HEALER_ATTACKS = true,
            REQUIRE_SAFE_ATTACK = true,
            REQUIRE_SAFE_MOVE = true,
            CHECK_VULNERABLE_MOVE = true,
            CRITICAL_ALLOW_UNSAFE_ATTACK = true,
            CRITICAL_ALLOW_UNSAFE_MOVE = true,
            CRITICAL_IGNORE_VULNERABLE_MOVE = true,
            BASE_ATTACK_BONUS = 220,
            MOVE_ATTACK_BONUS = 150,
            THREAT_ELIMINATION_BONUS = 260,
            CRITICAL_ATTACK_BONUS = 180,
            MAX_DIRECT_ATTACK_CHAIN = 2,
            THREAT_LEVEL_MULT = 1.5,
            ADJACENT_HUB_TARGET_BONUS = 180,
            NEAR_HUB_TARGET_BONUS = 90,
            RANGED_HUB_THREAT_BONUS = 120
        },
        COMMANDANT_GUARD = {
            CELL_BONUS = {
                line_block = 30,
                pressure = 15,
                hub_screen = 10
            },
            SCORE = {
                BASE = 50,
                DISTANCE_PENALTY = 10,
                MELEE_ADJ_HUB_BONUS = 90,
                MELEE_NEAR_HUB_BONUS = 35,
                RANGED_THREAT_BONUS = 20,
                HUB_SCREEN_PURPOSE_BONUS = 30,
                LINE_BLOCK_PURPOSE_BONUS = 20,
                ASSIGNED_MATCH_BONUS = 70,
                ASSIGNED_MISMATCH_PENALTY = 120
            }
        },
        COMMANDANT_DEFENSE_UNBLOCK = {
            ENABLED = true,
            BLOCKER_MAX_HUB_DISTANCE = 2,
            CHECK_VULNERABLE_MOVE = true,
            COUNTER_LOOKAHEAD_TURNS = 3,
            FREE_CELL_GAIN_BONUS = 120,
            ENABLE_COUNTER_NOW_BONUS = 260,
            ENABLE_COUNTER_SOON_BONUS = 140,
            HUB_RING_EXIT_BONUS = 90,
            HUB_DISTANCE_GAIN_BONUS = 25,
            MOVE_DISTANCE_PENALTY = 8,
            STAY_ADJ_HUB_PENALTY = 60,
            EXPOSURE_PENALTY_SCALE = 0.2,
            MIN_SCORE = 80
        },
        SUPPLY_DEPLOYMENT = {
            EARLY_CORVETTE_TURN_MAX = 3,
            HUB_DISTANCE = {
                BASE = 10,
                PER_TILE = 5
            },
            DEFENSIVE_PROXIMITY = {
                THREAT_BASE = 20,
                THREAT_DECAY = 6,
                HUB_BASE = 25,
                HUB_DECAY = 8,
                CALM_BASE = 15,
                CALM_DECAY = 4
            },
            RESPONSE = {
                CLOSE_THREAT_DISTANCE = 2,
                COUNTER_BASE_CLOSE = 45,
                COUNTER_BASE_FAR = 25,
                COUNTER_DECAY = 8,
                BLOCK_PRIMARY_THREAT_BONUS = 200,
                COUNTER_THREAT_TURN1_BONUS = 90,
                COUNTER_THREAT_TURN2_BONUS = 45,
                FAIL_PENALTY_CLOSE = 200,
                FAIL_PENALTY_FAR = 80
            },
            STRATEGIC_BONUS = {
                CORVETTE_LINE_BLOCK = 50,
                SCOUT_LINE_BLOCK = 75
            },
            SELECTION = {
                DEFENSIVE_UNITS = {
                    "name:Crusher",
                    "name:Earthstalker"
                }
            },
            THREAT_GATING = {
                LOOKAHEAD_TURNS = 2,
                FRONTIER_MAX = 20,
                EARLY_THREAT_TURN_MAX = 2,
                STRICT_GATING_REQUIRES_HUB_THREAT = true,
                REQUIRE_COUNTER_OR_BLOCK_WHEN_HUB_THREAT = true,
                REJECT_IF_THREAT_BEFORE_IMPACT = true,
                REJECT_IF_THREAT_TIE_IMPACT = true,
                MAX_IMPACT_TURN = 2,
                REJECT_IF_NO_IMPACT_AND_EARLY_THREAT = true,
                THREAT_BEFORE_IMPACT_PENALTY = 140,
                NO_IMPACT_UNDER_THREAT_PENALTY = 220,
                IMPACT_TURN_1_BONUS = 45,
                IMPACT_TURN_2_BONUS = 20
            }
        },
        NEUTRAL_BUILDING_ATTACK = {
            BASE_DAMAGE_MULT = 10,
            BLOCKED_UNIT_SAFE_MOVE_THRESHOLD = 1,
            BLOCKED_UNIT_BONUS = 20,
            ENEMY_HUB_ADJ_BONUS = 30,
            CORVETTE_LOS_MAX_HUB_DISTANCE = 3,
            CORVETTE_LOS_BONUS = 25
        },
        RISKY_MOVE = {
            FORWARD_PROGRESS_PER_TILE = 30,
            ENEMY_HUB_ADJ_BONUS = 150,
            THREAT_SCALE = 0.5,
            TRAP_VULNERABLE_BONUS = 100,
            THREAT_TARGET_VALUE_SCALE = 0.3,
            THREAT_DAMAGE_SCALE = 10,
            THREAT_REASON_THRESHOLD = 50,
            BLOCKING_PATH_BONUS = 40
        },
        BLOCKING_OBJECTIVES = {
            HUB_ACCESS_BONUS = 200,
            ATTACK_LANE_BONUS = 100,
            CORRIDOR_DIST1_BONUS = 30,
            CORRIDOR_DIST2_BONUS = 15,
            ENEMY_SUPPLY_BONUS = 80,
            HUB_PROXIMITY_THRESHOLD = 2,
            ENEMY_HUB_BLOCK_RANGE = 3,
            ENEMY_SUPPLY_ADJ_THRESHOLD = 1
        },
        RANDOM_ACTION = {
            SAFE_MOVE_PRIORITY = 3,
            SAFE_ATTACK_PRIORITY = 2,
            DEPLOY_PRIORITY = 2,
            ZERO_DAMAGE_ATTACK_PRIORITY = 1,
            HEALING_REPAIR_PRIORITY = 2,
            FULL_HP_REPAIR_PRIORITY = 1
        },
        TURN_FLOW = {
            START_DELAY = 0.7,
            ACTION_SEQUENCE_DELAY = 0.7,
            ATTACK_POINTER_DELAY = 0.05,
            SKIP_FALLBACK_CELL = {
                row = SHARED_RUNTIME.MIN_HP,
                col = SHARED_RUNTIME.MIN_HP
            }
        },
        SETUP = {
            REQUIRED_NEUTRAL_BUILDINGS = 4,
            HUB_PLACEMENT_ATTEMPTS = 10,
            HUB_PREFERRED_ROW_ATTEMPTS = 3,
            NEUTRAL_ROCK_DISPLAY = {
                currentHp = 5,
                startingHp = 5,
                atkDamage = 0,
                atkRange = 0,
                move = 0,
                player = 0
            }
        },
        KILL_RISK = {
            CORVETTE_LOS = {
                TARGET_HP_MAX = SHARED_RUNTIME.MIN_HP
            },
            RISKY_ATTACK = deepCopy(SHARED_RISKY_ATTACK_FILTER),
            RISKY_MOVE_ATTACK = deepCopy(SHARED_RISKY_ATTACK_FILTER),
            RISKY_EXPANDED = {
                MIN_DAMAGE = SHARED_RUNTIME.MIN_HP
            },
            DESPERATE = {
                MIN_DAMAGE = SHARED_RUNTIME.MIN_HP
            },
            NO_GATE = {
                MIN_DAMAGE = SHARED_RUNTIME.MIN_HP,
                ENEMY_HUB_ADJ_BONUS = 150
            },
            THREAT_PROJECTION = {
                LOOKAHEAD_TURNS = 3,
                FRONTIER_MAX = 16,
                TURN_SCALE = {
                    [1] = 1.0,
                    [2] = 0.45,
                    [3] = 0.25
                },
                DIRECT_VALUE_SCALE = 0.4,
                DIRECT_DAMAGE_SCALE = 8,
                DIRECT_KILL_BONUS = 50,
                DIRECT_HUB_BONUS = 100,
                MOVE_VALUE_SCALE = 0.3,
                MOVE_DAMAGE_SCALE = 6,
                MOVE_KILL_BONUS = 35,
                MOVE_HUB_BONUS = 75,
                FORK_MIN_ATTACK_CELLS = 3,
                FORK_BONUS_PER_CELL = 10
            },
            REACHABILITY = {
                VALUE_SCALE = 0.3,
                DAMAGE_SCALE = 5,
                HUB_BONUS = 80,
                HIGH_VALUE_BONUS = 40,
                TANK_BONUS = 20,
                KILL_BONUS = 50,
                MAX_TOTAL_BONUS = 100
            },
            EVASION = {
                MIN_POSITIONAL_BENEFIT = 10
            }
        },
        WINNING = {
            HUB_FALLBACK_HP = 12,
            LAST_ENEMY_UNIT_COUNT = SHARED_RUNTIME.MIN_HP
        },
        OFFENSIVE = {
            ATTACK_COUNT_BONUS = 20,
            DAMAGE_POTENTIAL_BONUS = 15,
            HIGH_VALUE_TARGET_BONUS = 10,
            MULTI_TARGET_BONUS = 30
        },
        HEALER_OFFENSE = {
            ENABLED = true,
            LATE_GAME_TURN_MIN = 10,
            MAX_FRIENDLY_NON_HEALER_UNITS = SHARED_RUNTIME.MIN_HP,
            MAX_ENEMY_UNITS = SHARED_RANGED_RANGE.MIN,
            REQUIRE_NO_NON_HEALER_ATTACKERS = true,
            NON_HEALER_ATTACK_LOOKAHEAD_TURNS = SHARED_RUNTIME.MIN_HP,
            ALLOW_EMERGENCY_COMMANDANT_DEFENSE = true,
            EMERGENCY_HUB_HP_AT_OR_BELOW = 5
        },
        ATTACK_DECISION = {
            DAMAGE_MULT = 50,
            NO_GATE_DAMAGE_MULT = 75,
            SPECIAL_ABILITY_BONUS = 100,
            SPECIAL_FINISH_BONUS = 50,
            NEAR_DEATH_FINISH_BONUS = 25,
            DOOMED_KILL_BONUS = 220,
            COMMANDANT_BONUS = 150,
            OWN_HUB_ADJ_BONUS = 200,
            OWN_HUB_NEAR_ADJ_BONUS = 100,
            OWN_HUB_RANGED_THREAT_BONUS = 160,
            SAFE_ENEMY_HUB_ADJ_BONUS = 100,
            UNSAFE_ENEMY_HUB_ADJ_BONUS = 75,
            CORVETTE_RETALIATION_LETHAL_PENALTY = 350,
            CORVETTE_RETALIATION_NONLETHAL_PENALTY = 180,
            DISTANCE_FALLBACK = 999
        },
        REPAIR = {
            BASE_ELIGIBLE = 100,
            SINGLE_HP_PRIORITY_BASE = 90,
            SURVIVAL_BONUS = 400,
            NO_SURVIVAL_BONUS = 200,
            HP_MISSING_MULT = 10,
            MOVE_DISTANCE_BASE = 5,
            MOVE_DISTANCE_DECAY = 1,
            SINGLE_HP_PRIORITY_UNITS = { "Bastion", "Cloudstriker", "Earthstalker", "Artillery" },
            UNIT_PRIORITY = {
                Commandant = 1000,
                Bastion = 200,
                Crusher = 150,
                Earthstalker = 140,
                Cloudstriker = 130,
                Wingstalker = 110
            }
        },
        HUB_THREAT = {
            MAX_DISTANCE = 4,
            DISTANCE_BASE = 5,
            DISTANCE_MULT = 10,
            POTENTIAL_THRESHOLD = 50,
            RANGED_MIN_RANGE = SHARED_RANGED_RANGE.MIN,
            RANGED_MAX_RANGE = SHARED_RANGED_RANGE.MAX,
            CORVETTE_LOS_BONUS = 50,
            ARTILLERY_RANGE_BONUS = 40,
            UNIT_BASE = {
                Crusher = 100,
                Earthstalker = 80,
                Cloudstriker = 90,
                Artillery = 85,
                Bastion = 70,
                Wingstalker = 30
            },
            MELEE_TRIGGER_RANGE = {
                Crusher = SHARED_RANGED_RANGE.MIN,
                Earthstalker = SHARED_RUNTIME.MIN_HP,
                Bastion = SHARED_RUNTIME.MIN_HP,
                Wingstalker = SHARED_RUNTIME.MIN_HP
            }
        },
        HUB_THREAT_LOOKAHEAD = {
            ENABLED = true,
            HORIZON_NORMAL = 2,
            HORIZON_THREATENED = 3,
            FRONTIER_MAX = 16,
            TURN_WEIGHT = {
                [1] = 1.0,
                [2] = 0.65,
                [3] = 0.35
            },
            PROJECTED_THREAT_MULT = 1.0
        },
        STRATEGY = {
            ENABLED = true,
            HORIZON_TURNS = 3,
            MAX_PLAN_CANDIDATES = 18,
            MAX_FRONTIER_PER_UNIT = 16,
            PLANNER_BUDGET_MS = 170,
            DEFENSE = {
                HARD_TRIGGER_TURNS = 2,
                RESERVE_ALL_ACTIONS = true,
                REQUIRE_NEUTRALIZE_OR_BLOCK = true,
                PROJECTED_TRIGGER_MIN_SCORE = 120,
                PROJECTED_TRIGGER_MAX_TURN = 2,
                PROJECTED_TRIGGER_MIN_UNITS = 1,
                HYSTERESIS_HOLD_TURNS = 2,
                HYSTERESIS_EXIT_MULT = 0.7,
                REQUIRE_BACKED_ATTACK_NONLETHAL = true,
                MIN_NONLETHAL_EXCHANGE_DELTA = 0,
                MIN_FOLLOWUP_ATTACKERS = 1
            },
            PLAN_SCORE_MIN = 1,
            VERIFIER = {
                ENABLED = true,
                BUDGET_MS = 180,
                TOP_K = 6,
                RESPONSE_K = 4,
                MAX_CANDIDATES = 12,
                HORIZON_PLIES = 2,
                RUN_DURING_SIEGE = true,
                SKIP_ONLY_FOR_PRIORITY00 = true
            },
            SIEGE = {
                ENABLED = true,
                PACKAGE_TYPES = {
                    "ARTILLERY_CORVETTE_SCREEN",
                    "DOUBLE_CORVETTE_ANCHOR",
                    "CRUSHER_LANE_RANGED_FINISH"
                },
                ROLE_WEIGHTS = {
                    PRIMARY = 220,
                    SECONDARY = 150,
                    SCREEN = 110,
                    ANCHOR = 90
                },
                HUB_PRESSURE_WEIGHTS = {
                    DIRECT_DAMAGE = 90,
                    TIMING = 70,
                    SURVIVABILITY = 55,
                    LANE_QUALITY = 35,
                    PATH_OPENING = 30,
                    CONVERGENCE_REQUIRE_PRIMARY_SECONDARY = true,
                    CONVERGENCE_TURN1_BONUS = 190,
                    CONVERGENCE_TURN2_BONUS = 120,
                    CONVERGENCE_MISS_PENALTY = 170,
                    RANGED_ADJACENCY_PENALTY_MULT = 4,
                    RANGED_ADJACENCY_HARD_AVOID_PRIMARY_SECONDARY = true,
                    RANGED_ADJACENCY_ALLOW_IF_CONVERGENCE_TURN1 = true
                }
            },
            ADVANCEMENT = {
                SUPPRESS_GENERIC_REPOSITION_WHEN_PLAN_ACTIVE = true,
                SUPPRESS_GENERIC_DEPLOY_WHEN_PLAN_ACTIVE = true
            },
            DEPLOY_SYNC = {
                STRICT_IMPACT_GATE = true,
                REQUIRE_PLAN_ROLE_FILL = true,
                REJECT_NO_IMPACT = true,
                STRICT_THREAT_TIMING_REQUIRES_HUB_THREAT = true,
                REJECT_IF_THREAT_BEFORE_IMPACT = true,
                THREAT_TIE_COUNTS_AS_TOO_LATE = true,
                MAX_THREAT_LEAD_TURNS = 0,
                MAX_IMPACT_TURN = 2,
                EARLY_THREAT_TURN_MAX = 2,
                REQUIRE_IMMEDIATE_IMPACT_WHEN_EARLY_THREAT = true,
                ALLOW_HEALER_DEPLOY_OUTSIDE_DEFENSE = false,
                SKIP_BAD_DEPLOY_WHEN_DEFENDING = true,
                DEFENSE_DEPLOY_MIN_NET_IMPACT = 60,
                DEFENSE_DEPLOY_REQUIRE_SURVIVE_TURNS = 1,
                ALLOW_SACRIFICE_IF_FORCES_ENEMY_ACTION = true,
                SACRIFICE_MIN_FORCED_VALUE = 180
            }
        },
        DOCTRINE = {
            GAME_PHASE = {
                EARLY_TURN_MAX = 10,
                MID_CONTACT_TRIGGER_ENABLED = true,
                CONTACT_RECENT_DAMAGE_WINDOW = 2,
                CONTACT_DISTANCE_THRESHOLD = 3,
                ENEMY_SUPPLY_EMPTY_ENDGAME = true
            },
            EARLY_TEMPO = {
                POLICY = "balanced",
                ALLOW_SAFE_HIGH_VALUE_ATTACK = true,
                SUPPRESS_RISKY_ATTACK_TIERS = true,
                MIN_SUPPORTED_ATTACK_GAIN = 120,
                MOVE_ATTACK_EXPOSURE_PENALTY = 220,
                MAX_EARLY_RISKY_ACTIONS_PER_TURN = 0
            },
            MID_TEMPO = {
                ENABLE_FREQUENT_INTERACTIONS = true,
                LOWER_SUPPORTED_ATTACK_GAIN = 70,
                ENABLE_CHAIN_KILL_BONUS = true,
                MID_RISK_BUDGET = 1
            },
            ENDGAME_CLOSEOUT = {
                ETA_HORIZON_TURNS = 3,
                PREFER = "eta_based",
                TIE_BREAK = "commandant_first",
                DEPLOY_STYLE = "finish_first",
                DEPLOY_ONLY_IF_ETA_IMPROVES_BY = 1
            },
            OPENING_COUNTER = {
                MODE = "dynamic_score",
                COUNTER_WEIGHT_RANGED = 1.0,
                COUNTER_WEIGHT_TANK = 1.0,
                COUNTER_WEIGHT_AIR = 1.0,
                COUNTER_WEIGHT_LANE_PRESSURE = 1.2,
                FORMATION_WEIGHT_STANDOFF = 1.0
            },
            WIDE_FRONT = {
                ENABLED = true,
                MOBILE_MIN_MOVE = 3,
                STACK_THRESHOLD = 2,
                SPREAD_FROM_STACK_BONUS = 38,
                STACK_PENALTY = 34,
                FLANK_OFFSET_MIN = 2,
                FLANK_OFFSET_BONUS = 62,
                FLANK_APPROACH_BONUS = 26,
                BACKLINE_REACH_ROWS = 3,
                BACKLINE_FLANK_BONUS = 36,
                ISOLATION_PENALTY = 58,
                APPLY_PHASES = {
                    early = true,
                    mid = true,
                    ["end"] = false
                }
            },
            INFLUENCE_MOBILITY = {
                ENABLED = true,
                MOBILE_MIN_MOVE = 3,
                MOVE_DELTA_WEIGHT = 1.4,
                RING_DELTA_WEIGHT = 0.9,
                RING_POSITIVE_CELL_BONUS = 11,
                ORBIT_OFFSET_BONUS = 30,
                ORBIT_MAX_RETREAT = 1,
                ORBIT_RETREAT_PENALTY = 26,
                BONUS_CAP = 140,
                APPLY_PHASES = {
                    early = true,
                    mid = true,
                    ["end"] = true
                }
            },
            OBJECTIVE_PATHING = {
                ENABLED = true,
                HORIZON_TURNS = 3,
                MAX_TARGETS_PER_UNIT = 4,
                REQUIRE_UNCONTESTED_OBJECTIVE = true,
                ETA_GAIN_BONUS = 115,
                ETA_ACQUIRE_BONUS = 90,
                DIST_GAIN_BONUS = 24,
                TARGET_PRIORITY_SCALE = 0.45,
                HUB_FOCUS_BONUS = 40,
                BONUS_CAP = 220
            },
            HEALER = {
                EARLY_DEPLOY_TURN_MIN = 5,
                ALLOW_EARLY_IF_HUB_THREAT = true,
                ALLOW_EARLY_IF_DAMAGED_ALLIES_AT_LEAST = 2,
                FRONTLINE_MIN_DISTANCE = 2,
                ORBIT_MIN = 2,
                ORBIT_MAX = 3,
                ALLOW_OFFENSIVE = false
            },
            ROCK_ATTACK = {
                ONLY_IF_STRATEGIC = true,
                LAST_RESORT_ONLY = true,
                REQUIRE_LOS_OR_PATH_IMPROVEMENT = true,
                ENEMY_HUB_PROGRESS_WINDOW = 2
            },
            FALLBACK = {
                PREFER_DEPLOY_OR_POSITION = true,
                ROCK_ATTACK_PENALTY = 4000,
                UNSUPPORTED_NONLETHAL_PENALTY = 6000
            },
            RANGED_STANDOFF = {
                HARD_AVOID_ADJACENT = true,
                EXCEPT_IF_LETHAL_OR_PRIORITY00 = true,
                PIN_ESCAPE_BASE_BONUS = 95,
                PIN_ESCAPE_THREAT_DELTA_BONUS = 75,
                PIN_ESCAPE_UNSAFE_PENALTY = 55,
                CLOUDSTRIKER_HARD_NO_ADJ_IF_ESCAPE = true,
                CLOUDSTRIKER_ALLOW_ADJ_IN_EXTREME_DEFENSE = true
            },
            RANGED_DUEL_EVASION = {
                ENABLED = true,
                RETALIATION_BREAK_BONUS = 165,
                RETALIATION_DELAY_BONUS = 90,
                ATTACK_POSTURE_BONUS = 65,
                LOS_MAINTAIN_BONUS = 40,
                FAILED_POSTURE_PENALTY = 55,
                MIN_BONUS_TO_FORCE_EVASION = 35,
                BONUS_CAP = 240
            },
            ADJACENT_RANGED_RESCUE = {
                ENABLED = true,
                BASE_BONUS = 140,
                ONE_TURN_REACH_BONUS = 180,
                TWO_TURN_REACH_BONUS = 90,
                NO_REACH_BONUS = 20,
                THREAT_VALUE_SCALE = 0.35,
                THREAT_VALUE_CAP = 80,
                RANGED_NONBRAWLER_PENALTY = 220,
                HEALER_PENALTY = 260,
                EARTHSTALKER_BONUS = 80,
                CRUSHER_BONUS = 70,
                BASTION_BONUS = 55,
                WINGSTALKER_BONUS = 30
            },
            OPENING = {
                MODE = "adaptive_guardrails",
                NO_HEALER_BEFORE_TURN = 5,
                REQUIRE_OPENING_SYNERGY = true
            },
            VERIFIER_PHASE_GUARD = {
                EARLY_ATTACK_DROP_MIN_GAIN = 260,
                MID_ATTACK_DROP_MIN_GAIN = 180,
                ALLOW_ATTACK_DROP_IN_DEFEND_HARD = true,
                EARLY_FALLBACK_VARIANT_LIMIT = 0
            },
            VERIFIER_ATTACK_GUARD = {
                ENABLED = true,
                EARLY_TURN_MAX = 6,
                EARLY_MIN_GAIN = 260,
                MID_MIN_GAIN = 180,
                DISABLE_IN_DEFEND_HARD = true
            }
        },
        TARGET_HEALTH_THRESHOLDS = {
            DEFAULT = SHARED_RUNTIME.MIN_HP,
            FORTIFIED = 4,
            FORTIFIED_STRICT = SHARED_RANGED_RANGE.MIN,
            ARTILLERY = SHARED_RANGED_RANGE.MIN
        }
    },

    -- Unit profiles used by ai_decision.lua for tag-based branching and target priority.
    UNIT_PROFILES = {
        DEFAULT = {
            tags = {},
            attackPattern = "standard",
            targetPriority = 10,
            targetTier = 1
        },
        Commandant = {
            tags = {commandant = true, hub = true},
            targetPriority = 1000,
            targetTier = 3
        },
        Cloudstriker = {
            tags = {ranged = true, corvette = true, los = true, high_value = true},
            attackPattern = "corvette",
            minRange = SHARED_RANGED_RANGE.MIN,
            maxRange = SHARED_RANGED_RANGE.MAX,
            targetPriority = 100,
            targetTier = 2
        },
        Artillery = {
            tags = {ranged = true, artillery = true, high_value = true},
            attackPattern = "artillery",
            minRange = SHARED_RANGED_RANGE.MIN,
            maxRange = SHARED_RANGED_RANGE.MAX,
            targetPriority = 100,
            targetTier = 2
        },
        Earthstalker = {
            tags = {melee = true, mobile = true, earthstalker = true},
            targetPriority = 80,
            targetTier = 1
        },
        Crusher = {
            tags = {melee = true, tank = true},
            targetPriority = 60,
            targetTier = 2
        },
        Bastion = {
            tags = {tank = true, fortified = true},
            targetPriority = 40,
            targetTier = 2
        },
        Healer = {
            tags = {healer = true}
        },
        Wingstalker = SHARED_WINGSTALKER_PROFILE,
        Rock = {
            tags = {obstacle = true},
            targetPriority = 0,
            targetTier = 0
        }
    },
    RUNTIME = {
        ZERO = SHARED_RUNTIME.ZERO,
        MIN_HP = SHARED_RUNTIME.MIN_HP,
        DEFAULT_TURN = SHARED_RUNTIME.DEFAULT_TURN,
        DEFAULT_GRID_SIZE = SHARED_RUNTIME.DEFAULT_GRID_SIZE,
        DISTANCE_FALLBACK = SHARED_RUNTIME.DISTANCE_FALLBACK,
        PLAYER_INDEX_SUM = SHARED_RUNTIME.PLAYER_INDEX_SUM
    },
    DEBUG_SUPPORT = false,

    -- Baseline profile parameters with alias-driven personality references.
    PROFILE = {
        TYPES = {"base", "burt", "maggie", "marge", "homer", "burns"},
        DEFAULT_REFERENCE = "base",
        DEFAULT_TYPE = "fixed",
        RANDOMIZER = {
            BASE_TOLERANCE = 5,
            VALUE_RATIO = 0.10,
            DETERMINISTIC = true
        },
        INITIAL_DEPLOYMENT = {
            base = {}
        },
        ALIAS_TO_REFERENCE = {
            preset_ai_5 = "base",
            ["Lisa (AI)"] = "base",
            preset_ai_2 = "burt",
            ["Burt (AI)"] = "burt",
            preset_ai_1 = "maggie",
            ["Maggie (AI)"] = "maggie",
            preset_ai_3 = "marge",
            ["Marge (AI)"] = "marge",
            preset_ai_4 = "homer",
            ["Homer (AI)"] = "homer",
            preset_ai_6 = "burns",
            ["Burns (AI)"] = "burns"
        },
        SCORE_OVERRIDES = {
            base = {},
            burt = {
                DOCTRINE = {
                    EARLY_TEMPO = {
                        SUPPRESS_RISKY_ATTACK_TIERS = false,
                        MIN_SUPPORTED_ATTACK_GAIN = 55,
                        MOVE_ATTACK_EXPOSURE_PENALTY = 90,
                        MAX_EARLY_RISKY_ACTIONS_PER_TURN = 2
                    },
                    MID_TEMPO = {
                        ENABLE_FREQUENT_INTERACTIONS = true,
                        LOWER_SUPPORTED_ATTACK_GAIN = 25,
                        ENABLE_CHAIN_KILL_BONUS = true,
                        MID_RISK_BUDGET = 3
                    },
                    WIDE_FRONT = {
                        SPREAD_FROM_STACK_BONUS = 55,
                        STACK_PENALTY = 24,
                        FLANK_OFFSET_BONUS = 90,
                        FLANK_APPROACH_BONUS = 45
                    },
                    INFLUENCE_MOBILITY = {
                        MOVE_DELTA_WEIGHT = 1.8,
                        ORBIT_OFFSET_BONUS = 45,
                        BONUS_CAP = 180
                    },
                    VERIFIER_PHASE_GUARD = {
                        MID_ATTACK_DROP_MIN_GAIN = 140
                    }
                },
                STRATEGY = {
                    DEFENSE = {
                        PROJECTED_TRIGGER_MIN_SCORE = 210,
                        HYSTERESIS_HOLD_TURNS = 1,
                        HYSTERESIS_EXIT_MULT = 0.45,
                        RESERVE_ALL_ACTIONS = false
                    }
                },
                THREAT_RELEASE_OFFENSE = {
                    ARM_ON_THREAT_LEVEL = 90,
                    RELEASE_THREAT_LEVEL_MAX = 75,
                    ATTACK_BONUS = 260,
                    MOVE_ATTACK_BONUS = 220,
                    ENEMY_HUB_ADJ_BONUS = 180
                }
            },
            maggie = {
                DOCTRINE = {
                    EARLY_TEMPO = {
                        MIN_SUPPORTED_ATTACK_GAIN = 90,
                        MOVE_ATTACK_EXPOSURE_PENALTY = 170,
                        MAX_EARLY_RISKY_ACTIONS_PER_TURN = 1
                    },
                    MID_TEMPO = {
                        LOWER_SUPPORTED_ATTACK_GAIN = 45,
                        MID_RISK_BUDGET = 2
                    },
                    WIDE_FRONT = {
                        SPREAD_FROM_STACK_BONUS = 46,
                        STACK_PENALTY = 28,
                        FLANK_OFFSET_BONUS = 72,
                        FLANK_APPROACH_BONUS = 34
                    },
                    INFLUENCE_MOBILITY = {
                        MOVE_DELTA_WEIGHT = 1.6,
                        ORBIT_OFFSET_BONUS = 36,
                        BONUS_CAP = 160
                    },
                    VERIFIER_PHASE_GUARD = {
                        MID_ATTACK_DROP_MIN_GAIN = 160
                    }
                },
                STRATEGY = {
                    DEFENSE = {
                        PROJECTED_TRIGGER_MIN_SCORE = 160,
                        HYSTERESIS_HOLD_TURNS = 2,
                        HYSTERESIS_EXIT_MULT = 0.60,
                        RESERVE_ALL_ACTIONS = false
                    }
                },
                THREAT_RELEASE_OFFENSE = {
                    ATTACK_BONUS = 220,
                    MOVE_ATTACK_BONUS = 180,
                    ENEMY_HUB_ADJ_BONUS = 140
                }
            },
            marge = {
                DOCTRINE = {
                    EARLY_TEMPO = {
                        SUPPRESS_RISKY_ATTACK_TIERS = true,
                        MIN_SUPPORTED_ATTACK_GAIN = 180,
                        MOVE_ATTACK_EXPOSURE_PENALTY = 320,
                        MAX_EARLY_RISKY_ACTIONS_PER_TURN = 0
                    },
                    MID_TEMPO = {
                        ENABLE_FREQUENT_INTERACTIONS = false,
                        LOWER_SUPPORTED_ATTACK_GAIN = 120,
                        ENABLE_CHAIN_KILL_BONUS = false,
                        MID_RISK_BUDGET = 0
                    },
                    FALLBACK = {
                        UNSUPPORTED_NONLETHAL_PENALTY = 8500
                    },
                    WIDE_FRONT = {
                        SPREAD_FROM_STACK_BONUS = 20,
                        STACK_PENALTY = 45,
                        FLANK_OFFSET_BONUS = 20,
                        BACKLINE_FLANK_BONUS = 18
                    },
                    INFLUENCE_MOBILITY = {
                        MOVE_DELTA_WEIGHT = 0.95,
                        RING_DELTA_WEIGHT = 0.7,
                        ORBIT_OFFSET_BONUS = 12,
                        BONUS_CAP = 90
                    },
                    VERIFIER_PHASE_GUARD = {
                        MID_ATTACK_DROP_MIN_GAIN = 240
                    }
                },
                STRATEGY = {
                    DEFENSE = {
                        HARD_TRIGGER_TURNS = 3,
                        PROJECTED_TRIGGER_MIN_SCORE = 70,
                        HYSTERESIS_HOLD_TURNS = 4,
                        HYSTERESIS_EXIT_MULT = 0.90,
                        RESERVE_ALL_ACTIONS = true
                    }
                },
                SUPPLY_DEPLOYMENT = {
                    SELECTION = {
                        DEFENSIVE_UNITS = {"name:Earthstalker", "name:Crusher", "name:Bastion"}
                    }
                },
                THREAT_RELEASE_OFFENSE = {
                    ARM_ON_THREAT_LEVEL = 160,
                    RELEASE_THREAT_LEVEL_MAX = 40,
                    ATTACK_BONUS = 100,
                    MOVE_ATTACK_BONUS = 70,
                    ENEMY_HUB_ADJ_BONUS = 60
                }
            },
            homer = {
                DOCTRINE = {
                    EARLY_TEMPO = {
                        MIN_SUPPORTED_ATTACK_GAIN = 145,
                        MOVE_ATTACK_EXPOSURE_PENALTY = 260,
                        MAX_EARLY_RISKY_ACTIONS_PER_TURN = 0
                    },
                    MID_TEMPO = {
                        LOWER_SUPPORTED_ATTACK_GAIN = 90,
                        MID_RISK_BUDGET = 0
                    },
                    WIDE_FRONT = {
                        SPREAD_FROM_STACK_BONUS = 34,
                        STACK_PENALTY = 38,
                        FLANK_OFFSET_BONUS = 52
                    },
                    INFLUENCE_MOBILITY = {
                        MOVE_DELTA_WEIGHT = 1.2,
                        ORBIT_OFFSET_BONUS = 24,
                        BONUS_CAP = 120
                    },
                    VERIFIER_PHASE_GUARD = {
                        MID_ATTACK_DROP_MIN_GAIN = 210
                    }
                },
                STRATEGY = {
                    DEFENSE = {
                        PROJECTED_TRIGGER_MIN_SCORE = 95,
                        HYSTERESIS_HOLD_TURNS = 3,
                        HYSTERESIS_EXIT_MULT = 0.82,
                        RESERVE_ALL_ACTIONS = true
                    }
                },
                THREAT_RELEASE_OFFENSE = {
                    ATTACK_BONUS = 140,
                    MOVE_ATTACK_BONUS = 110,
                    ENEMY_HUB_ADJ_BONUS = 90
                }
            },
            burns = {}
        },
        DYNAMIC_ALIAS = {
            burns = {
                ENABLED = true,
                SWITCH_MODE = "turn_lock",
                MIN_HOLD_OWN_TURNS = 2,
                EMERGENCY_FORCE_DEFENSE = true,
                DEFENSE_HARD_REF = "marge",
                DEFENSE_SOFT_REF = "homer",
                NEUTRAL_REF = "base",
                BALANCED_REF = "maggie",
                AGGRESSIVE_REF = "burt",
                RULES = {
                    CONTACT_DISTANCE_THRESHOLD = 3,
                    CONTACT_RECENT_DAMAGE_WINDOW = 2,
                    IMMEDIATE_HUB_HP_CRITICAL = 6,
                    IMMEDIATE_THREAT_LEVEL_MIN = 120,
                    IMMEDIATE_THREAT_UNITS_MIN = 1,
                    PROJECTED_THREAT_LEVEL_MIN = 140,
                    PROJECTED_THREAT_UNITS_MIN = 2,
                    PROJECTED_DISTANCE_BUFFER = 2,
                    ADVANTAGE_WIN_CHANCE_MIN = 54,
                    ADVANTAGE_HP_DELTA_MIN = 3,
                    ADVANTAGE_SUPPLY_LEAD_MIN = 1,
                    ADVANTAGE_MIN_TURN = 4
                }
            }
        }
    },
    SCHEDULER = {
        ANIMATION_POLL_INTERVAL = 0.05,
        DEFAULT_DELAY = 0
    },
    ADAPTIVE_PROFILE = {
        CHANGE_INTERVAL = 3,
        MIN_TURN = 3,
        MIN_TURNS_BETWEEN_CHANGES = 3,
        DISABLE_AFTER_TURN = 25
    },
    WIN_PROFILE = {
        START_TURN = 25,
        CHECK_INTERVAL = 5,
        PROFILE_THRESHOLDS = {
            BASE = 50
        }
    },
    WIN_PERCENTAGE = {
        WEIGHTS = {
            INFLUENCE = 30,
            UNIT_VALUE = 25,
            HP = 20,
            HUB_HP = 15,
            SUPPLY = 10
        },
        HP_WEIGHT_DISTRIBUTION = {
            RAW = 0.7,
            EFFICIENCY = 0.3
        },
        SUPPLY_UNIT_VALUES = {
            Artillery = 100,
            Cloudstriker = 100,
            DEFAULT = 50
        },
        DEFAULT_UNIT_VALUE = 50,
        FALLBACK = {
            ZERO_VALUE = SHARED_RUNTIME.ZERO,
            MIN_DENOMINATOR = SHARED_RUNTIME.MIN_HP,
            NEUTRAL_RATIO = 0.5,
            DEFAULT_EFFICIENCY = 0.5,
            DEFAULT_TURN = SHARED_RUNTIME.DEFAULT_TURN,
            DEFAULT_GRID_SIZE = SHARED_RUNTIME.DEFAULT_GRID_SIZE,
            PERCENT_SCALE = 100
        }
    },

    SAFETY_MODEL = {
        ADJACENT_RANGE = SHARED_RUNTIME.MIN_HP,
        RANGED_MIN_RANGE = SHARED_RANGED_RANGE.MIN,
        DEFAULTS = {
            ZERO_DAMAGE = SHARED_RUNTIME.ZERO,
            DEFAULT_ATTACK_RANGE = SHARED_RUNTIME.MIN_HP,
            MIN_HP = SHARED_RUNTIME.MIN_HP,
            FIRST_DAMAGE_INDEX = SHARED_RUNTIME.MIN_HP,
            SECOND_DAMAGE_INDEX = SHARED_RANGED_RANGE.MIN,
            NEUTRAL_PLAYER_ID = SHARED_PLAYERS.NEUTRAL
        },
        BENEFICIAL_SUICIDE = {
            ALWAYS_BENEFICIAL_TARGETS = {
                "Commandant"
            },
            KILL_TRADE_RATIO_MIN = 1.0,
            NON_KILL_MAX_TARGET_HP = SHARED_RUNTIME.MIN_HP,
            NON_KILL_TRADE_RATIO_MIN = 1.2
        },
        NEUTRAL_BUILDING = {
            NEARBY_ENEMY_DISTANCE = 2,
            NEARBY_ENEMY_MIN = 2,
            NEARBY_ENEMY_BONUS = 30,
            DIRECTIONAL_BONUS = 20,
            MIN_STRATEGIC_VALUE = 30
        },
        DEAD_END = {
            DEAD_END_ROUTE_MAX = SHARED_RUNTIME.MIN_HP,
            RESTRICTION_HIGH = 3,
            RESTRICTION_MID_ROUTE_MAX = SHARED_RANGED_RANGE.MIN,
            RESTRICTION_MID = SHARED_RANGED_RANGE.MIN,
            RESTRICTION_LOW = SHARED_RUNTIME.MIN_HP
        },
        LINE_OF_SIGHT_BLOCK = {
            CHECK_DISTANCE = 3
        },
        FIRING_LANES = {
            CHECK_DISTANCE = 3,
            CLEAR_CELLS_REQUIRED = SHARED_RANGED_RANGE.MIN,
            GOOD_LANES_REQUIRED = SHARED_RANGED_RANGE.MIN
        },
        COMPLETE_SAFETY = {
            SAFE_DAMAGE_THRESHOLD = SHARED_RUNTIME.MIN_HP
        }
    },

    DRAW_URGENCY = {
        ENABLED = true,
        MIN_TURN = 4,
        TRIGGER_MARGIN = 8,
        WIN_PERCENT_THRESHOLD = 0,
        ATTACK_BONUS_BASE = 220,
        ATTACK_BONUS_PER_LEVEL = 85,
        NON_ATTACK_PENALTY_BASE = 95,
        NON_ATTACK_PENALTY_PER_LEVEL = 55,
        PASSIVE_PENALTY_RATIO = 0.65,
        FORCE_ACTIVATION_MARGIN = 8,
        CRITICAL_MARGIN = 6,
        CRITICAL_ALLOW_SUICIDAL_ENGAGE = true,
        CRITICAL_IGNORE_VULNERABLE_CHECK = true,
        CRITICAL_ENGAGE_MIN_SCORE = 0,
        CRITICAL_ALLOW_NEUTRAL_TARGETS = true,
        CRITICAL_THREAT_LOOKAHEAD_TURNS = 4,
        PIPELINE = {
            RUN_BEFORE_POSITIONING = true,
            BLOCK_POSITIONING_WHEN_ATTACK_EXISTS = true,
            BLOCK_DEPLOY_WHEN_ATTACK_EXISTS = true,
            FORCE_INTERACTION_WHEN_NO_HARD_THREAT = true,
            FORCE_INTERACTION_MIN_TURN = 2
        },
        SUPPRESS_DEFENSIVE_REPOSITION = true,
        SUPPRESS_GUARD_REPOSITION = true,
        ENFORCE_ATTACK = {
            ENABLED = true,
            ENABLE_WHEN_STALEMATE_PRESSURE = true,
            ALLOW_WHEN_HUB_THREATENED = false,
            MIN_PREFIX_ACTIONS = 0,
            ALLOW_ZERO_DAMAGE = true,
            ALLOW_NEUTRAL_TARGETS = true,
            DAMAGE_WEIGHT = 120,
            TARGET_VALUE_WEIGHT = 1.0,
            KILL_BONUS = 140,
            COMMANDANT_BONUS = 260,
            ZERO_DAMAGE_PENALTY = 25
        },
        ENGAGEMENT_MOVE = {
            ENABLED = true,
            ALLOW_WHEN_HUB_THREATENED = true,
            ALLOW_SUICIDAL = false,
            CHECK_VULNERABLE_MOVE = false,
            THREAT_LOOKAHEAD_TURNS = 3,
            THREAT_FRONTIER_MAX = 16,
            DIST_GAIN_WEIGHT = 85,
            PROXIMITY_BASE = 90,
            PROXIMITY_DECAY = 20,
            TARGET_VALUE_WEIGHT = 0.2,
            THREAT_NOW_BONUS = 160,
            THREAT_NEXT_BONUS = 90,
            THREAT_LATE_BONUS = 45,
            ADJACENT_ENGAGE_BONUS = 80,
            EXPOSURE_PENALTY_SCALE = 0.1,
            MIN_SCORE = 15
        },
        STALEMATE_PRESSURE = {
            ENABLED = true,
            START_STREAK = 1,
            ALLOW_WHEN_HUB_THREATENED = true,
            DIST_GAIN_WEIGHT = 45,
            RETREAT_PENALTY_WEIGHT = 18,
            ENEMY_PROX_BASE = 32,
            ENEMY_PROX_DECAY = 5,
            HUB_DIST_GAIN_WEIGHT = 22,
            SCALE_PER_STREAK = 0.25,
            MAX_SCALE = 2.5,
            LOW_IMPACT_TRIGGER_STREAK = 2,
            LOW_IMPACT_NO_PROGRESS_PENALTY = 80,
            LOW_IMPACT_RETREAT_PENALTY = 130,
            LOW_IMPACT_NO_THREAT_PENALTY = 55,
            LOW_IMPACT_SCALE_PER_STREAK = 0.20,
            LOW_IMPACT_MAX_SCALE = 2.0,
            PATTERN_REPEAT_WINDOW = 5,
            PATTERN_REPEAT_PENALTY = 65,
            PATTERN_OSCILLATION_PENALTY = 95,
            PATTERN_SCALE_PER_REPEAT = 0.35,
            PATTERN_MAX_SCALE = 2.4
        }
    },
        LOGGING = {
        MAX_PRIORITY_LOGGED = 35,
        DETAIL_DEPTH_DEFAULT = 0,
        MAX_DETAIL_DEPTH = 2,
        ARRAY_PREVIEW_LIMIT = 5,
        OBJECT_PREVIEW_LIMIT = 6,
        DEFAULT_GRID_SIZE = SHARED_RUNTIME.DEFAULT_GRID_SIZE,
        UNIT_SYMBOL_WIDTH = 7,
        UNIT_SYMBOL = {
            NEUTRAL_PLAYER_ID = SHARED_PLAYERS.NEUTRAL,
            PLAYER_ONE_ID = SHARED_PLAYERS.PLAYER_ONE,
            PLAYER_TWO_ID = SHARED_PLAYERS.PLAYER_TWO,
            HP_MIN = SHARED_RUNTIME.ZERO,
            HP_MAX = 9
        }
    }
}

local function normalizeConfig(params)
    if type(params) ~= "table" then
        return params
    end

    params.SCORES = params.SCORES or {}
    params.EVAL = params.EVAL or {}

    -- Canonical profile trees.
    params.PROFILE = params.PROFILE or {}
    params.ADAPTIVE_PROFILE = params.ADAPTIVE_PROFILE or {}
    params.WIN_PROFILE = params.WIN_PROFILE or {}

    -- Canonical core evaluation tree: SCORES.UNIT_EVAL.
    local unitEval = params.SCORES.UNIT_EVAL or {}
    params.SCORES.UNIT_EVAL = unitEval

    if unitEval.UNIT_VALUES == nil then
        unitEval.UNIT_VALUES = params.EVAL.UNIT_VALUES or {}
    end
    if unitEval.UNIT_VALUE_ALIASES == nil then
        unitEval.UNIT_VALUE_ALIASES = params.EVAL.UNIT_VALUE_ALIASES or {}
    end
    if unitEval.ROLE_BONUSES == nil then
        unitEval.ROLE_BONUSES = params.EVAL.ROLE_BONUSES or {}
    end
    if unitEval.EXPOSURE == nil then
        unitEval.EXPOSURE = params.EVAL.EXPOSURE or {}
    end
    if unitEval.THREAT == nil then
        unitEval.THREAT = params.EVAL.THREAT or {}
    end
    if unitEval.DEFAULTS == nil then
        unitEval.DEFAULTS = params.EVAL.DEFAULTS or {}
    end

    params.EVAL.UNIT_VALUES = unitEval.UNIT_VALUES
    params.EVAL.UNIT_VALUE_ALIASES = unitEval.UNIT_VALUE_ALIASES
    params.EVAL.ROLE_BONUSES = unitEval.ROLE_BONUSES
    params.EVAL.EXPOSURE = unitEval.EXPOSURE
    params.EVAL.THREAT = unitEval.THREAT
    params.EVAL.DEFAULTS = unitEval.DEFAULTS

    -- Canonical positional tree: SCORES.POSITIONAL.
    if params.SCORES.POSITIONAL == nil then
        params.SCORES.POSITIONAL = params.EVAL.POSITIONAL or {}
    end
    local canonicalPositional = params.SCORES.POSITIONAL
    local legacyPositional = params.EVAL.POSITIONAL or {}
    if canonicalPositional.COMPONENT_WEIGHTS == nil then
        canonicalPositional.COMPONENT_WEIGHTS =
            legacyPositional.COMPONENT_WEIGHTS
            or deepCopy(SHARED_POSITIONAL_COMPONENT_WEIGHTS)
    end
    params.SCORES.POSITIONAL = canonicalPositional
    params.EVAL.POSITIONAL = canonicalPositional
    params.EVAL.POSITIONAL.COMPONENT_WEIGHTS = params.SCORES.POSITIONAL.COMPONENT_WEIGHTS

    -- Canonical mobility tree: SCORES.MOBILITY.
    if params.SCORES.MOBILITY == nil then
        params.SCORES.MOBILITY = params.EVAL.MOBILITY or {}
    end
    params.EVAL.MOBILITY = params.SCORES.MOBILITY

    -- Canonical supply-eval tree: SCORES.SUPPLY_EVAL.
    local supplyEval = params.SCORES.SUPPLY_EVAL or {}
    params.SCORES.SUPPLY_EVAL = supplyEval

    if supplyEval.UNIT_SPAWN_VALUES == nil then
        supplyEval.UNIT_SPAWN_VALUES = params.EVAL.UNIT_SPAWN_VALUES or {}
    end
    if supplyEval.UNIT_SPAWN_VALUES_UNDER_ATTACK == nil then
        supplyEval.UNIT_SPAWN_VALUES_UNDER_ATTACK = params.EVAL.UNIT_SPAWN_VALUES_UNDER_ATTACK or {}
    end
    if supplyEval.GOOD_FIRING_LANE == nil then
        supplyEval.GOOD_FIRING_LANE = (params.EVAL.POSITION or {}).GOOD_FIRING_LANE
    end
    if supplyEval.BLOCK_LINE_OF_SIGHT == nil then
        supplyEval.BLOCK_LINE_OF_SIGHT = (params.EVAL.TACTICAL or {}).BLOCK_LINE_OF_SIGHT
    end

    params.EVAL.UNIT_SPAWN_VALUES = supplyEval.UNIT_SPAWN_VALUES
    params.EVAL.UNIT_SPAWN_VALUES_UNDER_ATTACK = supplyEval.UNIT_SPAWN_VALUES_UNDER_ATTACK
    params.EVAL.POSITION = supplyEval
    params.EVAL.TACTICAL = supplyEval

    return params
end

aiConfig.normalizeConfig = normalizeConfig
aiConfig.AI_PARAMS = normalizeConfig(deepCopy(BASE_AI_PARAMS))
aiConfig.LOGGING = {
    enableDebug = true,
    enableSummary = true,
    enableSummaryDetails = true,
    enableSafetyDebug = false
}

return aiConfig
