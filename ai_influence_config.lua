-- AI Influence Map Configuration
-- Centralized configuration for easy tuning without touching code

return {
    -- Shared defaults used by ai_influence.lua when optional config blocks are absent.
    DEFAULTS = {
        ZERO = 0,
        ONE = 1,
        HALF = 0.5,
        GRID_SIZE = 8,
        CURRENT_TURN = 1,
        START_TIME = 0,
        MILLISECONDS_PER_SECOND = 1000,
        PRESSURE_MULTIPLIER = 1.0,
        DECAY_RATE = 0.4,
        DECAY_PHASE_TRANSITION = 20,
        ELIMINATION_GRADIENT = 0.5,
        SMOOTHSTEP_A = 3,
        SMOOTHSTEP_B = 2,
        DIAGONAL_GRADIENT_SCALE = 0.5,
        DEFENSE_RULE_THRESHOLD = 1,
        DEFENSE_RULE_MULTIPLIER = 1,
        DEFENSE_THREAT_MULTIPLIER = 1.5,
        DEFENSE_ADJACENT_GRADIENT = 0.7,
        ATTACK_RANGE_BONUS_FRIENDLY_DIRECT = 20,
        ATTACK_RANGE_BONUS_FRIENDLY_MOVE_ATTACK = 15,
        ATTACK_RANGE_BONUS_ENEMY_DIRECT = 30,
        ATTACK_RANGE_BONUS_ENEMY_MOVE_ATTACK = 20,
        DEFAULT_UNIT_VALUE = 30,
        MAX_INFLUENCE_CONTRIBUTION = 50,
        INFLUENCE_SCALE = 50,
        STATS_THRESHOLD = 5,
        DECAY_PHASE_DURATION = 20,
        DEBUG_MAP_VALUE_FORMAT = "%6.1f ",
        HEATMAP_COLOR_RANGE = 200,
        HEATMAP_LEGEND_ALPHA = 0.9,
        HEATMAP_CENTER_DIVISOR = 2,
        HEATMAP_NEUTRAL_COLOR = {0.3, 0.3, 0.3, 0.4},
        HEATMAP_OVERLAY_BASE_ALPHA = 0.5,
        HEATMAP_OVERLAY_ALPHA_SCALE = 0.3,
        HEATMAP_POSITIVE_RED_BASE = 0.2,
        HEATMAP_POSITIVE_GREEN_BASE = 0.4,
        HEATMAP_POSITIVE_GREEN_SCALE = 0.4,
        HEATMAP_POSITIVE_BLUE_BASE = 0.2,
        HEATMAP_NEGATIVE_RED_BASE = 0.4,
        HEATMAP_NEGATIVE_RED_SCALE = 0.4,
        HEATMAP_NEGATIVE_GREEN_BASE = 0.2,
        HEATMAP_NEGATIVE_BLUE_BASE = 0.2,
    },
    -- ========================================================================
    -- INFLUENCE SPREAD SETTINGS
    -- ========================================================================
    
    -- How influence decays over distance
    -- Options: "linear", "exponential", "quadratic", "sqrt"
    DECAY_TYPE = "exponential",
    
    -- Phase-based decay rate scaling (creates more focused late-game tactics)
    DECAY_RATE_EARLY = 0.35,--0.35,   -- Wider influence in early game
    DECAY_RATE_LATE = 0.5,--0.50,    -- Tighter influence in late game
    DECAY_PHASE_TRANSITION = 20,  -- Turn when decay starts tightening
    
    -- Maximum distance influence spreads (in Manhattan distance)
    -- Lower = more local influence, Higher = more global influence
    -- Recommended: 3-5 for tactical games
    MAX_INFLUENCE_RANGE = 3,
    
    -- ========================================================================
    -- UNIT INFLUENCE MULTIPLIERS
    -- ========================================================================
    
    -- Friendly unit influence (positive values attract units)
    FRIENDLY_MULTIPLIER = 1.0,

    -- Enemy unit influence (negative values repel units)
    -- Higher absolute value = enemies more threatening
    ENEMY_MULTIPLIER = -0.85,

    UNIT_BASE_VALUES = {
        Commandant = 100,
        Bastion = 60,
        Crusher = 50,
        Cloudstriker = 40,
        Wingstalker = 35,
        Earthstalker = 35,
    },

    -- Bonuses applied when units exert control or threat from attack ranges
    ATTACK_RANGE_BONUSES = {
        friendly = {
            direct = 26,      -- Added when ally can attack immediately
            moveAttack = 20,  -- Added when ally can move then attack
        },
        enemy = {
            direct = 24,      -- Subtracted when enemy can attack immediately (scaled by damage)
            moveAttack = 16,  -- Subtracted when enemy can move then attack (scaled by damage)
        },
    },

    -- ========================================================================
    -- OBJECTIVE INFLUENCE
    -- ========================================================================
    
    -- Influence at friendly Commandant position (protection pull - scales with pressure)
    FRIENDLY_COMMANDANT_INFLUENCE = {
        base = 18,           -- Keep defense pull but reduce over-turtling
        pressureScale = 0.6, -- Scales slower than offense (maintains balance)
    },
    
    -- ========================================================================
    -- INTEGRATION WEIGHTS
    -- ========================================================================
    
    -- Sigmoid scaling parameters (prevents influence from dominating tactical decisions)
    MAX_INFLUENCE_CONTRIBUTION = 65,  -- Max influence score contribution (±65)
    
    -- Sigmoid scale for influence normalization.
    INFLUENCE_SCALE = 40,
    
    -- Attack power scaling in threat zones
    -- Higher damage units create proportionally stronger threat
    -- Formula: 1.0 + (damage * ATTACK_POWER_SCALE)
    -- Example: 3 damage with 0.1 scale = 1.3x multiplier
    ATTACK_POWER_SCALE = 0.1,  -- +10% threat per damage point
    
    -- ========================================================================
    -- VICTORY PRESSURE SYSTEM
    -- ========================================================================
    
    -- Pressure curve that increases over time to push towards victory
    -- Victory conditions: 1) Destroy enemy Commandant, 2) Eliminate all enemy units
    
    -- Turn thresholds for pressure escalation
    PRESSURE_TURN_EARLY = 10,    -- Turns 1-10: Early game
    PRESSURE_TURN_MID = 20,      -- Turns 11-20: Mid game
    PRESSURE_TURN_LATE = 30,     -- Turns 21-30: Late game
    -- Pressure multipliers by turn phase
    PRESSURE_MULTIPLIERS = {
        early = 1.0,
        mid = 1.4,
        late = 1.8,
        critical = 2.2,
    },
    
    -- VICTORY PRESSURE VALUES (All scaled by pressure multiplier)
    -- ========================================================================
    
    -- Enemy Commandant attack priority (offensive)
    COMMANDANT_ATTACK_PRIORITY = {
        base = 360,                -- Stronger pressure toward enemy Commandant
        orthogonalGradient = 0.65, -- Bonus applied to orthogonal adjacent cells (strong guidance)
        orthogonalDecay = 0.7,    -- Multiplier for each additional orthogonal ring beyond distance 1
        diagonalGradient = 0.3,    -- Bonus applied to diagonal adjacent cells (lighter guidance)
    },
    COMMANDANT_ATTACK_GRADIENT = 0.6,  -- Legacy support: percentage applied to adjacent tiles around the enemy hub

    -- Commandant defense priority (scaled by pressure)
    COMMANDANT_DEFENSE_PRIORITY = {
        base = 48,
        pressureScale = 0.7,
    },
    COMMANDANT_DEFENSE_HP_SCALING = {
        { threshold = 0.50, multiplier = 1.5 },
        { threshold = 0.75, multiplier = 1.25 },
    },
    COMMANDANT_DEFENSE_RESPONSE = {
        threatMultiplier = 1.25,
        adjacentGradient = 0.6,
    },

    -- Unit elimination bonus (when enemy has few units - triggers earlier for momentum)
    UNIT_ELIMINATION_THRESHOLD = 5,  -- Increased from 3 to trigger earlier
    UNIT_ELIMINATION_BONUS = 130,    -- Stronger hunting pressure when enemy count is low
    UNIT_ELIMINATION_GRADIENT = 0.5, -- Percentage applied to adjacent tiles around priority targets
    
    -- ========================================================================
    -- POSITIONAL VALUE WEIGHTS (Balanced with Influence)
    -- ========================================================================
    
    POSITIONAL_WEIGHTS = {
        -- Proximity to enemy Commandant
        ENEMY_PROXIMITY = {
            base = 55,
            decay = 3,
        },
        
        -- Defensive positioning (near own Commandant)
        OWN_PROXIMITY = {
            base = 20,
            decay = 5,
        },
        
        -- Center positioning bonus
        CENTER_POSITIONING = 8,
        CENTER_DECAY = 2,        -- Per-distance decay
        
        -- Dead end penalty
        DEAD_END_BASE = -40,
        DEAD_END_PER_LEVEL = -20, -- Additional per restriction level
        DEAD_END_MAX = -80,
        DEAD_END_ESCAPE_ROUTE_BONUS = 15,  -- Bonus per additional escape route opened
        DEAD_END_NEW_SINGLE_EXIT_PENALTY = 30, -- Extra penalty when move ends in a single-exit dead end
        
        -- Position history penalty (anti-oscillation)
        HISTORY_RECENT = -25,    -- Recent visit penalty (stronger anti-oscillation)
        HISTORY_DECAY_TURNS = 4, -- Faster decay to recover after moving elsewhere
    },
    
    -- ========================================================================
    -- DEBUG SETTINGS
    -- ========================================================================
    
    -- Enable detailed influence map logging
    DEBUG_ENABLED = true,
    
    -- Print full 8x8 influence map grid (very verbose!)
    DEBUG_SHOW_MAP = false,
}
