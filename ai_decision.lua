local shared = require('ai_decision.shared')
local turnState = require('ai_decision.turn_state')
local configRuntime = require('ai_decision.config_runtime')
local evaluationScoring = require('ai_decision.evaluation_scoring')
local tempoStrategy = require('ai_decision.tempo_strategy')
local executionFlow = require('ai_decision.execution_flow')
local tacticsAttack = require('ai_decision.tactics_attack')
local tacticsDefense = require('ai_decision.tactics_defense')

local M = {}

local MODULES = {
    turnState,
    configRuntime,
    evaluationScoring,
    tempoStrategy,
    executionFlow,
    tacticsAttack,
    tacticsDefense
}

function M.mixin(aiClass)
    for _, module in ipairs(MODULES) do
        module.mixin(aiClass, shared)
    end
end

return M
