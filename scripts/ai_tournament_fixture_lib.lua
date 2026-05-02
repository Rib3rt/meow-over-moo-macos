local M = {}

local GRID_SIZE = 8
local DEFAULT_TURN = 18
local DEFAULT_MAX_ACTIONS = 2

local UNIT_STARTING_HP = {
    Commandant = 12,
    Wingstalker = 3,
    Crusher = 4,
    Bastion = 6,
    Cloudstriker = 4,
    Earthstalker = 3,
    Healer = 4,
    Artillery = 5
}

local REQUIRED_FIXTURE_IDS = {
    "immediate_commandant_lethal",
    "immediate_commandant_defense",
    "supply_block_lethal",
    "enemy_supply_present",
    "enemy_supply_absent",
    "healer_filler",
    "draw_pressure_faction_attack_priority",
    "move_plus_deploy",
    "deploy_plus_attack",
    "two_action_mandatory_continuation",
    "tactical_extension_proof",
    "tactical_extension_refutation",
    "combat_direct_attack_reaches_rank",
    "combat_direct_attack_reaches_finalist",
    "combat_required_under_draw_pressure",
    "passive_override_requires_defense_proof",
    "move_attack_lane_generates_candidate",
    "must_bucket_rescue_before_top_n_fill",
    "mirror_combat_before_draw",
    "safe_unit_kill_beats_passive_build",
    "high_damage_beats_generic_deploy",
    "anti_draw_safe_attack_required_after_full_turn_11",
    "safe_commandant_pressure_beats_generic_deploy_under_draw_pressure",
    "safe_kill_beats_rebuild_when_ahead",
    "finish_low_hp_commandant_before_supply_deploy",
    "eliminate_last_unit_before_passive_move",
    "no_suicide_under_draw_pressure",
    "no_ignore_defense_during_conversion",
    "unsafe_attack_rejected_for_commandant_lethal",
    "defense_beats_safe_attack_when_own_commandant_threatened",
    "commandant_pressure_defense_targets_active_attacker",
    "commandant_pressure_prefers_removal_deploy_over_nonlethal_ally_trade",
    "commandant_pressure_rejects_nonreducing_chip",
    "defend_now_prioritizes_active_threat_chip_over_side_attack",
    "defend_now_focus_fire_over_single_chip",
    "defend_now_deploy_eta1_over_nonreducing_chip",
    "defend_now_deploy_eta1_over_move_eta1",
    "defend_now_reinforce_eta_gt1_survivable",
    "defend_now_win_race_ttw_leq_ttd",
    "defend_now_ranged_line_block_with_removal_plan",
    "draw_reset_safe_chip_beats_passive_after_turn_10",
    "rock_attack_does_not_satisfy_combat_contract",
    "kernel_returns_safe_attack_when_full_search_times_out",
    "kernel_returns_legal_non_skip_when_no_combat_exists",
    "kernel_prevents_no_ranked_candidates_against_burns_state",
    "kernel_does_not_override_immediate_defense",
    "kernel_does_not_force_unsafe_attack",
    "runtime_trace_selected_attack_executes",
    "runtime_trace_classifies_melee_and_ranged_attacks"
}

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local clone = {}
    seen[value] = clone

    for key, child in pairs(value) do
        clone[deepCopy(key, seen)] = deepCopy(child, seen)
    end

    return clone
end

local function defaultHpFor(unitName)
    return UNIT_STARTING_HP[unitName] or 1
end

local function makeUnit(unitName, player, row, col, overrides)
    local startingHp = defaultHpFor(unitName)
    local unit = {
        name = unitName,
        player = player,
        row = row,
        col = col,
        currentHp = startingHp,
        startingHp = startingHp,
        hasActed = false,
        hasMoved = false,
        actionsUsed = 0,
        corvetteDamageFlag = false,
        artilleryDamageFlag = false
    }

    for key, value in pairs(overrides or {}) do
        unit[key] = value
    end

    return unit
end

local function makeSupplyUnit(unitName, overrides)
    local startingHp = defaultHpFor(unitName)
    local unit = {
        name = unitName,
        currentHp = startingHp,
        startingHp = startingHp
    }

    for key, value in pairs(overrides or {}) do
        unit[key] = value
    end

    return unit
end

local function makeHub(player, row, col, currentHp, startingHp)
    local start = startingHp or defaultHpFor("Commandant")
    local hp = currentHp or start
    return {
        name = "Commandant",
        player = player,
        row = row,
        col = col,
        currentHp = hp,
        startingHp = start
    }
end

local function ensureCommandantUnits(state)
    local units = state.units or {}
    state.units = units

    for player = 1, 2 do
        local hub = state.commandHubs and state.commandHubs[player]
        if hub then
            local found = false
            for _, unit in ipairs(units) do
                if unit
                    and unit.name == "Commandant"
                    and unit.player == player
                    and unit.row == hub.row
                    and unit.col == hub.col then
                    unit.currentHp = hub.currentHp or unit.currentHp
                    unit.startingHp = hub.startingHp or unit.startingHp
                    found = true
                    break
                end
            end

            if not found then
                units[#units + 1] = makeUnit("Commandant", player, hub.row, hub.col, {
                    currentHp = hub.currentHp,
                    startingHp = hub.startingHp
                })
            end
        end
    end
end

local function buildBaseState(opts)
    opts = opts or {}
    local playerOneHub = opts.playerOneHub or makeHub(1, 1, 1)
    local playerTwoHub = opts.playerTwoHub or makeHub(2, 8, 8)

    local state = {
        phase = opts.phase or "actions",
        turnNumber = opts.turnNumber or DEFAULT_TURN,
        currentTurn = opts.currentTurn or opts.turnNumber or DEFAULT_TURN,
        currentPlayer = opts.currentPlayer or opts.actingPlayer or 1,
        turnsWithoutDamage = opts.turnsWithoutDamage or 0,
        hasDeployedThisTurn = opts.hasDeployedThisTurn == true,
        turnActionCount = opts.turnActionCount or 0,
        firstActionRangedAttack = opts.firstActionRangedAttack,
        maxActionsPerTurn = opts.maxActionsPerTurn or DEFAULT_MAX_ACTIONS,
        gridSize = opts.gridSize or GRID_SIZE,
        units = deepCopy(opts.units or {}),
        unitsWithRemainingActions = deepCopy(opts.unitsWithRemainingActions or {}),
        commandHubs = {
            [1] = deepCopy(playerOneHub),
            [2] = deepCopy(playerTwoHub)
        },
        neutralBuildings = deepCopy(opts.neutralBuildings or {}),
        supply = {
            [1] = deepCopy((opts.supply and opts.supply[1]) or opts.supplyOne or {}),
            [2] = deepCopy((opts.supply and opts.supply[2]) or opts.supplyTwo or {})
        },
        attackedObjectivesThisTurn = deepCopy(opts.attackedObjectivesThisTurn or {}),
        guardAssignments = deepCopy(opts.guardAssignments or {})
    }

    ensureCommandantUnits(state)
    return state
end

local function newFixture(def)
    local fixture = deepCopy(def)
    fixture.expected = fixture.expected or {}
    fixture.expected.legal = fixture.expected.legal or {}
    fixture.expected.legal.mustIncludeActionSignatures = fixture.expected.legal.mustIncludeActionSignatures or {}
    fixture.expected.legal.mustExcludeActionSignatures = fixture.expected.legal.mustExcludeActionSignatures or {}
    fixture.expected.legal.turnPatterns = fixture.expected.legal.turnPatterns or {}
    fixture.expected.outcome = fixture.expected.outcome or {}
    fixture.expected.risk = fixture.expected.risk or {}
    fixture.state = fixture.state or buildBaseState({actingPlayer = fixture.actingPlayer})
    fixture.actingPlayer = fixture.actingPlayer or 1
    fixture.opponentPlayer = fixture.opponentPlayer or (fixture.actingPlayer == 1 and 2 or 1)

    ensureCommandantUnits(fixture.state)

    return fixture
end

local FIXTURE_DEFS = {
    {
        id = "immediate_commandant_lethal",
        title = "Immediate Commandant Lethal",
        description = "Acting player can immediately kill enemy Commandant with a legal action.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 1, 1, 12),
            playerTwoHub = makeHub(2, 4, 6, 3),
            units = {
                makeUnit("Crusher", 1, 4, 5),
                makeUnit("Wingstalker", 1, 2, 2)
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:4,5->4,6"
                },
                turnPatterns = {
                    "attack+terminal_win"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                winnerAfterBestPlay = 1,
                terminalWinAvailable = true
            },
            risk = {
                ownCommandantImmediateLethal = false,
                enemyCommandantImmediateLethal = true
            }
        }
    },
    {
        id = "immediate_commandant_defense",
        title = "Immediate Commandant Defense",
        description = "Acting player is under immediate Commandant threat and has a direct legal defense.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 4, 4, 3),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Crusher", 1, 2, 4),
                makeUnit("Crusher", 2, 4, 5, {currentHp = 1, startingHp = 4})
            },
            supplyTwo = {
                makeSupplyUnit("Bastion")
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:5,5->4,5"
                },
                turnPatterns = {
                    "defense_first"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                immediateDefenseExists = true,
                terminalWinAvailable = false
            },
            risk = {
                ownCommandantImmediateLethal = true,
                defenseRequired = true
            }
        }
    },
    {
        id = "supply_block_lethal",
        title = "Supply Block Lethal",
        description = "Only a supply deploy on the open hub-adjacent cell can block lethal lane pressure.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 4, 4, 3),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Bastion", 1, 3, 4, {hasActed = true, actionsUsed = 1}),
                makeUnit("Wingstalker", 1, 4, 3, {hasActed = true, actionsUsed = 1}),
                makeUnit("Crusher", 1, 5, 4, {hasActed = true, actionsUsed = 1}),
                makeUnit("Cloudstriker", 2, 4, 7)
            },
            supplyOne = {
                makeSupplyUnit("Bastion")
            }
        }),
        expected = {
            legal = {
                minLegalActions = 1,
                mustIncludeActionSignatures = {
                    "supply_deploy:Bastion@4,5"
                },
                turnPatterns = {
                    "supply_deploy+defense"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                immediateDefenseExists = true,
                blockingDeployRequired = true
            },
            risk = {
                ownCommandantImmediateLethal = true,
                recommendedBlockCell = "4,5"
            }
        }
    },
    {
        id = "enemy_supply_present",
        title = "Enemy Supply Present",
        description = "Enemy has reserve units, so adversarial reply model must consider enemy deploy lines.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 7, 7, 6),
            units = {
                makeUnit("Cloudstriker", 1, 7, 4),
                makeUnit("Wingstalker", 1, 6, 4)
            },
            supplyTwo = {
                makeSupplyUnit("Bastion")
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:7,4->7,7"
                },
                turnPatterns = {
                    "commandant_pressure"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                pressureLineAvailable = true
            },
            risk = {
                enemySupplyCount = 1,
                enemyDeployReplyExpected = true
            }
        }
    },
    {
        id = "enemy_supply_absent",
        title = "Enemy Supply Absent",
        description = "Same tactical shape as supply-present case but enemy reserve is empty.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 7, 7, 6),
            units = {
                makeUnit("Cloudstriker", 1, 7, 4),
                makeUnit("Wingstalker", 1, 6, 4)
            },
            supplyTwo = {}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:7,4->7,7"
                },
                turnPatterns = {
                    "commandant_pressure"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                pressureLineAvailable = true
            },
            risk = {
                enemySupplyCount = 0,
                enemyDeployReplyExpected = false
            }
        }
    },
    {
        id = "healer_filler",
        title = "Healer Filler",
        description = "Healer deploy is legal but should be considered low value when no repair/defense need exists.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Crusher", 1, 1, 2, {hasActed = true, actionsUsed = 1}),
                makeUnit("Bastion", 1, 3, 2, {hasActed = true, actionsUsed = 1}),
                makeUnit("Wingstalker", 1, 2, 1, {hasActed = true, actionsUsed = 1}),
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6)
            },
            supplyOne = {
                makeSupplyUnit("Healer")
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "supply_deploy:Healer@2,3",
                    "attack:5,5->5,6"
                },
                turnPatterns = {
                    "attack+non_filler_followup"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                usefulNonDeployActionAvailable = true
            },
            risk = {
                noDamagedAllies = true,
                ownCommandantThreatened = false,
                fillerDeployShouldBeRejected = true
            }
        }
    },
    {
        id = "draw_pressure_faction_attack_priority",
        title = "Draw Pressure Faction Attack Priority",
        description = "Under official draw pressure, a legal faction-vs-faction attack should be preferred to passive turn shapes.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 15,
            currentTurn = 15,
            turnsWithoutDamage = 4,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Crusher", 1, 2, 3, {hasActed = true, actionsUsed = 1}),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 2, startingHp = 3}),
                makeUnit("Bastion", 2, 7, 7)
            },
            supplyOne = {
                makeSupplyUnit("Bastion")
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:5,5->5,6",
                    "supply_deploy:Bastion@2,1"
                },
                turnPatterns = {
                    "faction_attack_preferred_under_draw_pressure"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                drawPressureActive = true,
                factionAttackPreferred = true
            },
            risk = {
                legalFactionAttackExists = true,
                passiveTurnShouldBeRejected = true,
                neutralAttackDoesNotCount = true
            }
        }
    },
    {
        id = "move_plus_deploy",
        title = "Move Plus Deploy",
        description = "A first move can free a hub-adjacent cell so a supply deploy becomes legal as second action.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 4, 4, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 4, 3),
                makeUnit("Crusher", 1, 3, 4, {hasActed = true, actionsUsed = 1}),
                makeUnit("Wingstalker", 2, 4, 5)
            },
            neutralBuildings = {
                {row = 5, col = 4, currentHp = 5, startingHp = 5}
            },
            supplyOne = {
                makeSupplyUnit("Bastion")
            }
        }),
        expected = {
            legal = {
                minLegalActions = 1,
                mustIncludeActionSignatures = {
                    "move:4,3->4,2"
                },
                mustExcludeActionSignatures = {
                    "supply_deploy:Bastion@4,5"
                },
                turnPatterns = {
                    "move+supply_deploy"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                moveCanEnableDeploy = true
            },
            risk = {
                deployInitiallyUnavailable = true,
                requiresTwoActionContinuation = true
            }
        }
    },
    {
        id = "deploy_plus_attack",
        title = "Deploy Plus Attack",
        description = "Supply deploy and board attack are both legal in the same turn.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Crusher", 1, 1, 2, {hasActed = true, actionsUsed = 1}),
                makeUnit("Bastion", 1, 3, 2, {hasActed = true, actionsUsed = 1}),
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6)
            },
            neutralBuildings = {
                {row = 2, col = 1, currentHp = 5, startingHp = 5}
            },
            supplyOne = {
                makeSupplyUnit("Bastion")
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "supply_deploy:Bastion@2,3",
                    "attack:5,5->5,6"
                },
                turnPatterns = {
                    "supply_deploy+attack"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                twoActionPatternAvailable = true
            },
            risk = {
                deployAndAttackBothLegal = true
            }
        }
    },
    {
        id = "two_action_mandatory_continuation",
        title = "Two Action Mandatory Continuation",
        description = "State has multiple legal non-skip actions and no terminal win, so complete-turn continuation is mandatory.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 1, 1, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 4, 4),
                makeUnit("Crusher", 1, 6, 6),
                makeUnit("Wingstalker", 2, 4, 5)
            }
        }),
        expected = {
            legal = {
                minLegalActions = 3,
                mustIncludeActionSignatures = {
                    "attack:4,4->4,5",
                    "move:6,6->6,5"
                },
                turnPatterns = {
                    "attack+move",
                    "move+attack"
                },
                requiresCompleteTurnUnlessTerminal = true,
                disallowSingleActionWithoutTerminal = true
            },
            outcome = {
                terminalWinAvailable = false,
                completeTurnRequired = true
            },
            risk = {
                skipNotAllowedWhenLegalActionsExist = true,
                oneActionOnlyShouldBeRejected = true
            }
        }
    },
    {
        id = "tactical_extension_proof",
        title = "Tactical Extension Proof",
        description = "Finalist creates commandant pressure line that should be extendable for proof.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 2, 2, 10),
            playerTwoHub = makeHub(2, 4, 7, 8),
            units = {
                makeUnit("Cloudstriker", 1, 4, 4, {atkRange = 3}),
                makeUnit("Crusher", 1, 5, 7),
                makeUnit("Wingstalker", 2, 2, 7)
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:4,4->4,7",
                    "attack:5,7->4,7"
                },
                turnPatterns = {
                    "commandant_pressure",
                    "forcing_candidate"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                finalistShouldBeExtended = true
            },
            risk = {
                tacticalExtensionSuggested = true,
                expectedExtensionResult = "proved_force"
            }
        }
    },
    {
        id = "tactical_extension_refutation",
        title = "Tactical Extension Refutation",
        description = "Apparent commandant pressure has a clean enemy defensive reply and should be refuted in extension.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            playerOneHub = makeHub(1, 2, 2, 10),
            playerTwoHub = makeHub(2, 4, 7, 8),
            units = {
                makeUnit("Cloudstriker", 1, 4, 4, {atkRange = 3}),
                makeUnit("Wingstalker", 1, 6, 6),
                makeUnit("Bastion", 2, 5, 7)
            },
            supplyTwo = {
                makeSupplyUnit("Bastion")
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:4,4->4,7"
                },
                turnPatterns = {
                    "commandant_pressure",
                    "fake_force_candidate"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                finalistShouldBeExtended = true
            },
            risk = {
                tacticalExtensionSuggested = true,
                expectedExtensionResult = "refuted_force",
                enemySupplyCount = 1,
                enemyHasCleanReply = true
            }
        }
    },
    {
        id = "combat_direct_attack_reaches_rank",
        title = "Combat Direct Attack Reaches Rank",
        description = "Legal direct faction attack exists and must survive at least to ranking stage.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 7,
            currentTurn = 7,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 2, startingHp = 3}),
                makeUnit("Bastion", 1, 2, 3, {hasActed = true, actionsUsed = 1})
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:5,5->5,6"
                },
                turnPatterns = {
                    "direct_attack"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                combatDirectAttackMustReachRank = true
            },
            risk = {
                legalFactionAttackExists = true,
                expectAttackLossReasonNotFilteredBeforeRank = true
            }
        }
    },
    {
        id = "combat_direct_attack_reaches_finalist",
        title = "Combat Direct Attack Reaches Finalist",
        description = "Legal direct faction attack exists and at least one combat finalist should survive.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 9,
            currentTurn = 9,
            turnsWithoutDamage = 2,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Crusher", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 2, startingHp = 3}),
                makeUnit("Wingstalker", 1, 3, 3),
                makeUnit("Bastion", 2, 7, 7)
            },
            supplyOne = {
                makeSupplyUnit("Bastion")
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:5,5->5,6"
                },
                turnPatterns = {
                    "direct_attack_finalist"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                combatDirectAttackMustReachFinalist = true
            },
            risk = {
                legalFactionAttackExists = true
            }
        }
    },
    {
        id = "combat_required_under_draw_pressure",
        title = "Combat Required Under Draw Pressure",
        description = "Under official draw pressure, combat contract should trigger and keep attack lane alive.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 15,
            currentTurn = 15,
            turnsWithoutDamage = 4,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 2, startingHp = 3}),
                makeUnit("Bastion", 2, 7, 7)
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:5,5->5,6"
                },
                turnPatterns = {
                    "draw_pressure_attack"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                combatContractMustTrigger = true
            },
            risk = {
                officialDrawPressureActive = true
            }
        }
    },
    {
        id = "passive_override_requires_defense_proof",
        title = "Passive Override Requires Defense Proof",
        description = "If passive line is chosen while combat is active, decision must carry allowed proof reason.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 12,
            currentTurn = 12,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 4, 4, 3),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Cloudstriker", 2, 4, 7),
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6)
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:5,5->5,6",
                    "move:5,5->4,5"
                },
                turnPatterns = {
                    "passive_with_proof_or_forced_combat"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                passiveOverrideMustBeProved = true
            },
            risk = {
                immediateDefenseExists = true,
                legalFactionAttackExists = true
            }
        }
    },
    {
        id = "move_attack_lane_generates_candidate",
        title = "Move Attack Lane Generates Candidate",
        description = "No direct attack available initially, but move+attack should exist.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 8,
            currentTurn = 8,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 4),
                makeUnit("Earthstalker", 2, 5, 6),
                makeUnit("Bastion", 1, 2, 3, {hasActed = true, actionsUsed = 1})
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "move:5,4->5,5"
                },
                turnPatterns = {
                    "move_attack"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                moveAttackLaneRequired = true
            },
            risk = {
                noDirectFactionAttackInitially = true
            }
        }
    },
    {
        id = "must_bucket_rescue_before_top_n_fill",
        title = "Must Bucket Rescue Before Top N Fill",
        description = "High-value attack bucket must survive finalist selection before generic top-N fill.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 10,
            currentTurn = 10,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Artillery", 2, 5, 6, {currentHp = 2, startingHp = 5}),
                makeUnit("Wingstalker", 1, 4, 4),
                makeUnit("Bastion", 1, 3, 3)
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:5,5->5,6"
                },
                turnPatterns = {
                    "high_value_attack_rescue"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                mustBucketRescueRequired = true
            },
            risk = {
                highValueAttackMustReachFinalists = true
            }
        }
    },
    {
        id = "mirror_combat_before_draw",
        title = "Mirror Combat Before Draw",
        description = "Mirror opening shape should create faction attacks before official draw trigger window.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 6,
            currentTurn = 6,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 7, 7, 12),
            units = {
                makeUnit("Wingstalker", 1, 4, 4),
                makeUnit("Earthstalker", 2, 4, 5),
                makeUnit("Earthstalker", 1, 5, 4),
                makeUnit("Wingstalker", 2, 5, 5)
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:4,4->4,5",
                    "attack:5,4->5,5"
                },
                turnPatterns = {
                    "mirror_combat"
                },
                requiresCompleteTurnUnlessTerminal = true
            },
            outcome = {
                mirrorCombatExpected = true
            },
            risk = {
                drawWindowNotYetActive = true,
                factionInteractionShouldAppear = true
            }
        }
    },
    {
        id = "safe_unit_kill_beats_passive_build",
        title = "Safe Unit Kill Beats Passive Build",
        description = "Safe faction kill must be preferred over passive deploy/build line.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 8,
            currentTurn = 8,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 1, startingHp = 3}),
                makeUnit("Bastion", 1, 2, 3, {hasActed = true, actionsUsed = 1})
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:5,5->5,6"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "high_damage_beats_generic_deploy",
        title = "High Damage Beats Generic Deploy",
        description = "High-value commandant pressure/damage should beat generic deploy.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 9,
            currentTurn = 9,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 4, 7, 8),
            units = {
                makeUnit("Cloudstriker", 1, 4, 4),
                makeUnit("Bastion", 1, 2, 3, {hasActed = true, actionsUsed = 1}),
                makeUnit("Wingstalker", 2, 5, 7)
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:4,4->4,7"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "unsafe_attack_rejected_for_commandant_lethal",
        title = "Unsafe Attack Rejected For Commandant Lethal",
        description = "Unsafe combat must not be forced when it leaves own commandant lethal.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 12,
            currentTurn = 12,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 4, 4, 2),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Crusher", 2, 4, 5, {currentHp = 1, startingHp = 4}),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 2, startingHp = 3})
            }
        }),
        expected = {legal = {minLegalActions = 2, requiresCompleteTurnUnlessTerminal = true}}
    },
    {
        id = "defense_beats_safe_attack_when_own_commandant_threatened",
        title = "Defense Beats Safe Attack When Threatened",
        description = "DEFEND_NOW must beat safe attack when own commandant is threatened.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 12,
            currentTurn = 12,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 4, 4, 3),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Crusher", 2, 4, 5, {currentHp = 1, startingHp = 4}),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 1, startingHp = 3}),
                makeUnit("Wingstalker", 1, 2, 2)
            }
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:5,5->4,5"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "commandant_pressure_defense_targets_active_attacker",
        title = "Commandant Pressure Defense Targets Active Attacker",
        description = "When own Commandant is taking direct non-lethal damage, defense must target the active attacker before pressuring the enemy Commandant.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 8,
            currentTurn = 8,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 1, 3, 7),
            playerTwoHub = makeHub(2, 7, 3, 8),
            units = {
                makeUnit("Artillery", 1, 4, 3, {currentHp = 2, startingHp = 5}),
                makeUnit("Artillery", 1, 1, 2),
                makeUnit("Bastion", 2, 2, 3, {currentHp = 1, startingHp = 6}),
                makeUnit("Artillery", 2, 6, 3)
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:4,3->2,3"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "commandant_pressure_prefers_removal_deploy_over_nonlethal_ally_trade",
        title = "Commandant Pressure Prefers Removal Deploy Over Nonlethal Ally Trade",
        description = "When the Commandant is under non-lethal pressure, a deploy that sets up faster removal of the active attacker should beat trading into a secondary non-lethal threat.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 5,
            currentTurn = 5,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 1, 6, 10),
            playerTwoHub = makeHub(2, 7, 2, 12),
            units = {
                makeUnit("Artillery", 1, 1, 3, {currentHp = 5, startingHp = 5}),
                makeUnit("Artillery", 1, 2, 2, {currentHp = 4, startingHp = 5}),
                makeUnit("Bastion", 2, 1, 5, {currentHp = 5, startingHp = 6}),
                makeUnit("Artillery", 2, 5, 2, {currentHp = 5, startingHp = 5})
            },
            supplyOne = {makeSupplyUnit("Artillery")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:1,3->1,5",
                    "supply_deploy:Artillery@1,7"
                },
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "draw_reset_safe_chip_beats_passive_after_turn_10",
        title = "Draw Reset Safe Chip Beats Passive After Turn 10",
        description = "Under official draw pressure, safe faction chip must beat passive line.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 15,
            currentTurn = 15,
            turnsWithoutDamage = 4,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Artillery", 2, 5, 6, {currentHp = 5, startingHp = 5}),
                makeUnit("Bastion", 1, 2, 3, {hasActed = true, actionsUsed = 1})
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:5,5->5,6"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "anti_draw_safe_attack_required_after_full_turn_11",
        title = "Anti Draw Safe Attack Required After Full Turn 11",
        description = "After official draw window opens, safe faction attack should be selected over passive lines.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 12,
            currentTurn = 12,
            turnsWithoutDamage = 4,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 2, startingHp = 3}),
                makeUnit("Bastion", 1, 2, 3, {hasActed = true, actionsUsed = 1})
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:5,5->5,6"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "commandant_pressure_rejects_nonreducing_chip",
        title = "Commandant Pressure Rejects Nonreducing Chip",
        description = "A weak attack into the active Commandant threat is not valid defense proof unless it reduces pressure or pairs with a real removal setup.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 5,
            currentTurn = 5,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 1, 7, 10),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Artillery", 1, 1, 4, {currentHp = 5, startingHp = 5}),
                makeUnit("Artillery", 1, 3, 4, {currentHp = 5, startingHp = 5}),
                makeUnit("Bastion", 2, 1, 6, {currentHp = 5, startingHp = 6}),
                makeUnit("Artillery", 2, 6, 4, {currentHp = 5, startingHp = 5})
            },
            supplyOne = {makeSupplyUnit("Artillery")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:1,4->1,6"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "defend_now_prioritizes_active_threat_chip_over_side_attack",
        title = "Defend Now Prioritizes Active Threat Chip Over Side Attack",
        description = "When the Commandant is under melee pressure, a direct chip into the active attacker must beat a side attack plus future setup.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 5,
            currentTurn = 5,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 1, 2, 10),
            playerTwoHub = makeHub(2, 7, 5, 12),
            units = {
                makeUnit("Artillery", 1, 2, 4, {currentHp = 5, startingHp = 5}),
                makeUnit("Artillery", 1, 1, 1, {currentHp = 5, startingHp = 5}),
                makeUnit("Bastion", 2, 2, 2, {currentHp = 5, startingHp = 6}),
                makeUnit("Artillery", 2, 6, 4, {currentHp = 5, startingHp = 5}),
                makeUnit("Artillery", 2, 7, 4, {currentHp = 5, startingHp = 5})
            },
            supplyOne = {}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:2,4->2,2"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "defend_now_focus_fire_over_single_chip",
        title = "Defend Now Focus Fire Over Single Chip",
        description = "When immediate threat removal needs two hits, focus fire must beat weaker single-chip alternatives.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 7,
            currentTurn = 7,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 4, 4, 8),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Wingstalker", 1, 3, 5),
                makeUnit("Crusher", 2, 4, 5, {currentHp = 2, startingHp = 4}),
                makeUnit("Earthstalker", 2, 5, 4, {currentHp = 1, startingHp = 3}),
                makeUnit("Wingstalker", 2, 6, 4)
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:5,5->4,5",
                    "attack:3,5->4,5"
                },
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "defend_now_deploy_eta1_over_nonreducing_chip",
        title = "Defend Now Deploy Eta1 Over Nonreducing Chip",
        description = "An ETA1 deploy setup should beat nonreducing chip attacks into active Commandant pressure.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 9,
            currentTurn = 9,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 1, 5, 4),
            playerTwoHub = makeHub(2, 6, 2, 10),
            units = {
                makeUnit("Bastion", 2, 1, 4),
                makeUnit("Cloudstriker", 1, 4, 8),
                makeUnit("Bastion", 1, 3, 4),
                makeUnit("Artillery", 2, 1, 8),
                makeUnit("Wingstalker", 2, 5, 8)
            },
            supplyOne = {makeSupplyUnit("Crusher")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "attack:4,8->1,8",
                    "supply_deploy:Crusher@1,6"
                },
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "defend_now_deploy_eta1_over_move_eta1",
        title = "Defend Now Deploy Eta1 Over Move Eta1",
        description = "When both move/deploy routes can set ETA1, deploy should be chosen when it scores better.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 8,
            currentTurn = 8,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 1, 2, 10),
            playerTwoHub = makeHub(2, 6, 6, 10),
            units = {
                makeUnit("Bastion", 2, 1, 1),
                makeUnit("Wingstalker", 1, 1, 7),
                makeUnit("Earthstalker", 1, 3, 1),
                makeUnit("Cloudstriker", 1, 4, 6),
                makeUnit("Bastion", 2, 6, 8),
                makeUnit("Earthstalker", 2, 1, 5)
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "move:3,1->3,3",
                    "supply_deploy:Bastion@1,3"
                },
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "defend_now_reinforce_eta_gt1_survivable",
        title = "Defend Now Reinforce Eta Gt1 Survivable",
        description = "ETA>1 reinforcement is valid only with survival window and no better win race.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 10,
            currentTurn = 10,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 1, 2, 6),
            playerTwoHub = makeHub(2, 6, 3, 10),
            units = {
                makeUnit("Bastion", 2, 1, 1),
                makeUnit("Bastion", 2, 8, 8),
                makeUnit("Bastion", 1, 4, 7),
                makeUnit("Earthstalker", 1, 8, 3),
                makeUnit("Wingstalker", 1, 4, 4)
            },
            supplyOne = {makeSupplyUnit("Crusher")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"move:8,3->7,3"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "defend_now_win_race_ttw_leq_ttd",
        title = "Defend Now Win Race Ttw Leq Ttd",
        description = "A verified win race must override defensive setup when TTW is not slower than TTD.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 11,
            currentTurn = 11,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 3, 3, 10),
            playerTwoHub = makeHub(2, 8, 4, 7),
            units = {
                makeUnit("Cloudstriker", 2, 3, 1),
                makeUnit("Crusher", 1, 6, 2),
                makeUnit("Artillery", 1, 8, 2)
            },
            supplyOne = {makeSupplyUnit("Wingstalker")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:8,2->8,4"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "defend_now_ranged_line_block_with_removal_plan",
        title = "Defend Now Ranged Line Block With Removal Plan",
        description = "Line block counts only when pressure drops and a follow-up removal plan exists.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 9,
            currentTurn = 9,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 5, 3, 9),
            playerTwoHub = makeHub(2, 6, 6, 8),
            units = {
                makeUnit("Cloudstriker", 2, 5, 6),
                makeUnit("Wingstalker", 1, 5, 2),
                makeUnit("Artillery", 1, 7, 8),
                makeUnit("Earthstalker", 1, 2, 5),
                makeUnit("Wingstalker", 1, 6, 5)
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {
                    "supply_deploy:Bastion@5,4",
                    "attack:6,5->6,6"
                },
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "safe_commandant_pressure_beats_generic_deploy_under_draw_pressure",
        title = "Safe Commandant Pressure Beats Generic Deploy Under Draw Pressure",
        description = "Under draw pressure, safe commandant damage should beat generic deploy.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 13,
            currentTurn = 13,
            turnsWithoutDamage = 4,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 4, 7, 8),
            units = {
                makeUnit("Cloudstriker", 1, 4, 4),
                makeUnit("Bastion", 1, 2, 3, {hasActed = true, actionsUsed = 1}),
                makeUnit("Wingstalker", 2, 5, 7)
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:4,4->4,7"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "safe_kill_beats_rebuild_when_ahead",
        title = "Safe Kill Beats Rebuild When Ahead",
        description = "With advantage and a safe kill available, passive rebuild should not be selected.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 12,
            currentTurn = 12,
            turnsWithoutDamage = 2,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Bastion", 1, 4, 4),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 1, startingHp = 3})
            },
            supplyOne = {makeSupplyUnit("Healer"), makeSupplyUnit("Bastion")},
            supplyTwo = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:5,5->5,6"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "finish_low_hp_commandant_before_supply_deploy",
        title = "Finish Low HP Commandant Before Supply Deploy",
        description = "When commandant can be safely finished, attack should be prioritized over supply deploy.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 14,
            currentTurn = 14,
            turnsWithoutDamage = 3,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 4, 7, 2),
            units = {
                makeUnit("Cloudstriker", 1, 4, 4),
                makeUnit("Bastion", 1, 2, 3, {hasActed = true, actionsUsed = 1})
            },
            supplyOne = {makeSupplyUnit("Bastion"), makeSupplyUnit("Healer")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:4,4->4,7"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "eliminate_last_unit_before_passive_move",
        title = "Eliminate Last Unit Before Passive Move",
        description = "When the last enemy combat unit is safely killable, elimination should be preferred.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 13,
            currentTurn = 13,
            turnsWithoutDamage = 2,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 1, startingHp = 3})
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:5,5->5,6"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "no_suicide_under_draw_pressure",
        title = "No Suicide Under Draw Pressure",
        description = "Draw pressure must not force a line that leaves immediate own commandant lethal.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 14,
            currentTurn = 14,
            turnsWithoutDamage = 4,
            playerOneHub = makeHub(1, 4, 4, 2),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Cloudstriker", 1, 6, 6),
                makeUnit("Crusher", 2, 4, 5, {currentHp = 1, startingHp = 4}),
                makeUnit("Wingstalker", 2, 5, 6, {currentHp = 2, startingHp = 3})
            }
        }),
        expected = {legal = {minLegalActions = 1, requiresCompleteTurnUnlessTerminal = true}}
    },
    {
        id = "no_ignore_defense_during_conversion",
        title = "No Ignore Defense During Conversion",
        description = "Conversion pressure must never override immediate defensive obligations.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 13,
            currentTurn = 13,
            turnsWithoutDamage = 4,
            playerOneHub = makeHub(1, 4, 4, 3),
            playerTwoHub = makeHub(2, 8, 8, 7),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Crusher", 2, 4, 5, {currentHp = 1, startingHp = 4}),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 1, startingHp = 3}),
                makeUnit("Cloudstriker", 1, 4, 4)
            },
            supplyOne = {makeSupplyUnit("Bastion")}
        }),
        expected = {
            legal = {
                minLegalActions = 2,
                mustIncludeActionSignatures = {"attack:5,5->4,5"},
                requiresCompleteTurnUnlessTerminal = true
            }
        }
    },
    {
        id = "rock_attack_does_not_satisfy_combat_contract",
        title = "Rock Attack Does Not Satisfy Combat Contract",
        description = "Attacks against neutral rocks must not count as faction combat interaction.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 13,
            currentTurn = 13,
            turnsWithoutDamage = 3,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Artillery", 1, 5, 5),
                makeUnit("Bastion", 2, 8, 7)
            },
            neutralBuildings = {
                {row = 5, col = 7, currentHp = 5, startingHp = 5}
            }
        }),
        expected = {legal = {minLegalActions = 1, requiresCompleteTurnUnlessTerminal = true}}
    },
    {
        id = "kernel_returns_safe_attack_when_full_search_times_out",
        title = "Kernel Returns Safe Attack When Full Search Times Out",
        description = "Kernel must still return safe attack when full search is budget-starved.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 10,
            currentTurn = 10,
            turnsWithoutDamage = 2,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 1, startingHp = 3}),
                makeUnit("Bastion", 1, 3, 3)
            }
        }),
        expected = {legal = {minLegalActions = 2, requiresCompleteTurnUnlessTerminal = true}}
    },
    {
        id = "kernel_returns_legal_non_skip_when_no_combat_exists",
        title = "Kernel Returns Legal Non Skip When No Combat Exists",
        description = "Kernel must return legal non-skip sequence when no combat exists.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 5,
            currentTurn = 5,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 2, 4),
                makeUnit("Bastion", 2, 8, 7)
            }
        }),
        expected = {legal = {minLegalActions = 1, requiresCompleteTurnUnlessTerminal = true}}
    },
    {
        id = "kernel_prevents_no_ranked_candidates_against_burns_state",
        title = "Kernel Prevents No Ranked Candidates Against Burns State",
        description = "Kernel must prevent no_ranked_candidates fallback in normal legal state.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 1,
            currentTurn = 1,
            turnsWithoutDamage = 0,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 7, 7, 12),
            units = {
                makeUnit("Wingstalker", 1, 4, 4),
                makeUnit("Earthstalker", 2, 4, 5),
                makeUnit("Bastion", 1, 3, 3)
            }
        }),
        expected = {legal = {minLegalActions = 2, requiresCompleteTurnUnlessTerminal = true}}
    },
    {
        id = "kernel_does_not_override_immediate_defense",
        title = "Kernel Does Not Override Immediate Defense",
        description = "Kernel must preserve immediate defense obligations.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 11,
            currentTurn = 11,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 4, 4, 3),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Crusher", 2, 4, 5, {currentHp = 1, startingHp = 4}),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 1, startingHp = 3})
            }
        }),
        expected = {legal = {minLegalActions = 2, requiresCompleteTurnUnlessTerminal = true}}
    },
    {
        id = "kernel_does_not_force_unsafe_attack",
        title = "Kernel Does Not Force Unsafe Attack",
        description = "Kernel must avoid unsafe combat when it leaves immediate lethal.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 12,
            currentTurn = 12,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 4, 4, 2),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Cloudstriker", 1, 6, 6),
                makeUnit("Crusher", 2, 4, 5, {currentHp = 3, startingHp = 4})
            }
        }),
        expected = {legal = {minLegalActions = 1, requiresCompleteTurnUnlessTerminal = true}}
    },
    {
        id = "runtime_trace_selected_attack_executes",
        title = "Runtime Trace Selected Attack Executes",
        description = "Selected faction attack must be observed as executed attack in runtime trace.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 10,
            currentTurn = 10,
            turnsWithoutDamage = 1,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 8, 8, 12),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 1, startingHp = 3})
            }
        }),
        expected = {legal = {minLegalActions = 2, requiresCompleteTurnUnlessTerminal = true}}
    },
    {
        id = "runtime_trace_classifies_melee_and_ranged_attacks",
        title = "Runtime Trace Classifies Melee And Ranged Attacks",
        description = "Runtime trace must classify melee and ranged faction attacks.",
        actingPlayer = 1,
        state = buildBaseState({
            actingPlayer = 1,
            turnNumber = 14,
            currentTurn = 14,
            turnsWithoutDamage = 2,
            playerOneHub = makeHub(1, 2, 2, 12),
            playerTwoHub = makeHub(2, 7, 7, 10),
            units = {
                makeUnit("Wingstalker", 1, 5, 5),
                makeUnit("Cloudstriker", 1, 4, 4),
                makeUnit("Earthstalker", 2, 5, 6, {currentHp = 2, startingHp = 3}),
                makeUnit("Bastion", 2, 4, 7, {currentHp = 4, startingHp = 6})
            }
        }),
        expected = {legal = {minLegalActions = 2, requiresCompleteTurnUnlessTerminal = true}}
    }
}

local FIXTURES = {}
local FIXTURE_BY_ID = {}

for _, def in ipairs(FIXTURE_DEFS) do
    local fixture = newFixture(def)
    FIXTURES[#FIXTURES + 1] = fixture
    FIXTURE_BY_ID[fixture.id] = fixture
end

function M.actionSignature(action)
    if type(action) ~= "table" then
        return "invalid"
    end

    local actionType = tostring(action.type or "unknown")

    if actionType == "supply_deploy" then
        local target = action.target or {}
        local unitName = action.unitName or action.unitType or "?"
        return string.format(
            "supply_deploy:%s@%d,%d",
            tostring(unitName),
            tonumber(target.row) or -1,
            tonumber(target.col) or -1
        )
    end

    if actionType == "skip" then
        return "skip"
    end

    local unit = action.unit or {}
    local target = action.target or {}
    return string.format(
        "%s:%d,%d->%d,%d",
        actionType,
        tonumber(unit.row) or -1,
        tonumber(unit.col) or -1,
        tonumber(target.row) or -1,
        tonumber(target.col) or -1
    )
end

function M.buildBaseState(opts)
    return buildBaseState(opts)
end

function M.deepCopy(value)
    return deepCopy(value)
end

function M.getFixture(id)
    local fixture = FIXTURE_BY_ID[id]
    if not fixture then
        return nil
    end
    return deepCopy(fixture)
end

function M.getAllFixtures()
    return deepCopy(FIXTURES)
end

function M.listFixtureIds()
    local ids = {}
    for i = 1, #FIXTURES do
        ids[i] = FIXTURES[i].id
    end
    return ids
end

function M.getRequiredFixtureIds()
    return deepCopy(REQUIRED_FIXTURE_IDS)
end

return M
