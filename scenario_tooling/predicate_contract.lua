local M = {}

M.module = {
  name = "scenario_tooling.predicate_contract",
  version = "step-2-freeze-v1",
  description = "Frozen computable predicate contract for scenario-only offline tooling.",
  antiSelfAcquittalRule = "If required analysis is unavailable, result must be unknown/draft/reject and never approved.",
}

M.requiredPredicates = {
  "critical_blue_unit",
  "required_cell",
  "required_line",
  "gains_time",
  "real_pressure",
  "position_gained",
  "prevents_micro_interaction",
  "non_decorative_micro",
  "static_damage_clock",
  "multi_unit_damage_clock",
  "free_finisher_move",
  "support_already_free",
  "cosmetic_red_pressure",
  "macro_template_signature",
  "fingerprint_distinct",
  "defensive_domain_inclusion",
  "defensive_equivalence",
}

local function mk(name, description, inputSchemas, outputType, deterministicBehavior, ownerModule, versionHashStrategy, trueExample, falseExample, unknownBehavior, fixtureCoverageKeys, affects)
  return {
    name = name,
    version = "1.0.0",
    description = description,
    inputSchemas = inputSchemas,
    outputType = outputType,
    deterministicBehavior = deterministicBehavior,
    ownerModule = ownerModule,
    versionHashStrategy = versionHashStrategy,
    trueExample = trueExample,
    falseExample = falseExample,
    unknownBehavior = unknownBehavior,
    fixtureCoverageKeys = fixtureCoverageKeys,
    affects = affects,
  }
end

M.predicates = {
  critical_blue_unit = mk(
    "critical_blue_unit",
    "True when removing/disabling/delaying a Blue unit changes solver outcome, winning-line existence, false-line result, or exactness within horizon.",
    { "ScenarioState", "UnitState", "horizonTurns", "AblationResult" },
    "boolean|unknown",
    "Run deterministic ablation under frozen rules/policy; true only on outcome delta.",
    "scenario_tooling.predicate_eval",
    "Hash(name,version,inputSchemas,decisionProcedure,trueFixture,falseFixture).",
    "A support unit removed causes winning line to fail by timeout.",
    "Removing a decorative escort unit does not alter any proof outcome.",
    "If ablation or replay is unavailable, emit unknown and block approval.",
    { "fixture.critical_blue_unit.true", "fixture.critical_blue_unit.false" },
    { "contract_validation", "solver_proof", "quality_scoring", "proof_domain_inclusion", "promotion" }
  ),
  required_cell = mk(
    "required_cell",
    "True when a cell is necessary for declared mechanism execution (LOS/range/path/blocker/payoff) verified by replay and ablation.",
    { "ScenarioState", "cell", "MechanismSpec", "AblationResult" },
    "boolean|unknown",
    "Evaluate canonical mechanism constraints and replay with cell denial; true only if mechanism/proof breaks.",
    "scenario_tooling.predicate_eval",
    "Hash over schema ids + cell-necessity replay procedure.",
    "Blocking D4 removes only legal key path and solver can no longer force win.",
    "Cell H8 appears in narrative but no legal line uses it.",
    "If mechanism spec or ablation evidence is missing, emit unknown.",
    { "fixture.required_cell.true", "fixture.required_cell.false" },
    { "contract_validation", "solver_proof", "quality_scoring", "promotion" }
  ),
  required_line = mk(
    "required_line",
    "True when a line/sequence is necessary for mechanism success and alternatives do not preserve outcome under policy.",
    { "ScenarioState", "Action[]", "MechanismSpec", "DefensiveDomainDecision" },
    "boolean|unknown",
    "Deterministic branch comparison against canonical policy/domain; true only if omitted line removes proven win.",
    "scenario_tooling.predicate_eval",
    "Hash includes line-normalization and equivalence epsilon settings.",
    "Skipping setup attack loses tempo and no win remains within N.",
    "Alternative order remains equivalent and still proven winning.",
    "Unknown when branch proof is incomplete or domain proof is unavailable.",
    { "fixture.required_line.true", "fixture.required_line.false" },
    { "contract_validation", "solver_proof", "quality_scoring", "promotion" }
  ),
  gains_time = mk(
    "gains_time",
    "True when a Red action increases shortest Blue mate length, consumes slack, or forces detour past previous bound.",
    { "ScenarioState", "Action", "turnLimit", "solverDistanceMap" },
    "boolean|unknown",
    "Compute shortest proven distances before/after action with identical solver config.",
    "scenario_tooling.predicate_eval",
    "Hash over distance metric definition and tie-break normalization.",
    "Red block move raises shortest mate from 3 to 4.",
    "Red cosmetic shuffle leaves shortest mate unchanged.",
    "Unknown if distances cannot be proven for both compared states.",
    { "fixture.gains_time.true", "fixture.gains_time.false" },
    { "solver_proof", "quality_scoring", "proof_domain_inclusion" }
  ),
  real_pressure = mk(
    "real_pressure",
    "True when removing a Red pressure feature changes Blue legal win, false lines, Red responses, exactness, or quality output.",
    { "ScenarioState", "pressureFeatureId", "AblationResult", "QualityFeatureSet" },
    "boolean|unknown",
    "Deterministic pressure ablation with frozen policy and quality extractor.",
    "scenario_tooling.predicate_eval",
    "Hash includes pressure-feature schema + ablation comparator.",
    "Removing attack threat enables previously losing greedy line to win.",
    "Removing distant unit with no influence changes nothing.",
    "Unknown if pressure ablation could not be replayed fully.",
    { "fixture.real_pressure.true", "fixture.real_pressure.false" },
    { "contract_validation", "quality_scoring", "promotion" }
  ),
  position_gained = mk(
    "position_gained",
    "True only when new useful position is achieved via cost/risk/ordering/trade-off and affects proofed tactical outcome.",
    { "ScenarioState", "UnitState", "cell", "Action[]", "AblationResult" },
    "boolean|unknown",
    "Check prior unavailability/non-utility then verify utility delta under proof replay.",
    "scenario_tooling.predicate_eval",
    "Hash over utility criteria and pre/post position comparator.",
    "Unit sacrifices tempo to occupy key LOS cell enabling finisher.",
    "Unit moves to equivalent safe square with no downstream effect.",
    "Unknown if utility comparison cannot be established deterministically.",
    { "fixture.position_gained.true", "fixture.position_gained.false" },
    { "solver_proof", "quality_scoring", "promotion" }
  ),
  prevents_micro_interaction = mk(
    "prevents_micro_interaction",
    "True when a Red action invalidates micro-interaction preconditions/effects/timing/HP windows/required states.",
    { "ScenarioState", "Action", "microInteractionId", "MicroInteractionSpec" },
    "boolean|unknown",
    "Evaluate micro pre/post predicates against resulting state and turn index.",
    "scenario_tooling.predicate_eval",
    "Hash over micro schema version + invalidation rules.",
    "Red hit drops key unit below required HP threshold for micro to fire.",
    "Red move elsewhere leaves all micro preconditions satisfied.",
    "Unknown if micro specification or resulting state is incomplete.",
    { "fixture.prevents_micro_interaction.true", "fixture.prevents_micro_interaction.false" },
    { "solver_proof", "proof_domain_inclusion", "quality_scoring" }
  ),
  non_decorative_micro = mk(
    "non_decorative_micro",
    "True only when micro ablation changes winning line, false line, Red response, exactness, or fingerprint.",
    { "ScenarioState", "microInteractionId", "AblationResult", "TacticalFingerprint" },
    "boolean|unknown",
    "Remove micro, recompute proof/fingerprint under fixed versions, compare outputs.",
    "scenario_tooling.predicate_eval",
    "Hash includes fingerprint canonicalization + micro-ablation comparator.",
    "Removing blocker-pull micro destroys only forced winning branch.",
    "Removing flavor move note does not alter replay or fingerprint.",
    "Unknown if ablation/fingerprint recomputation is unavailable.",
    { "fixture.non_decorative_micro.true", "fixture.non_decorative_micro.false" },
    { "contract_validation", "quality_scoring", "promotion" }
  ),
  static_damage_clock = mk(
    "static_damage_clock",
    "True when scenario reduces to repeated damage accumulation on Commandant without tactical transformation.",
    { "ScenarioState", "Action[]", "ProofCertificate" },
    "boolean|unknown",
    "Detect repeated-commandant-damage pattern with no lock/key/path state transition markers.",
    "scenario_tooling.predicate_eval",
    "Hash over pattern grammar + transformation markers.",
    "Three turns of same ready attackers firing Commandant with no board change.",
    "Intermediate key-unlock changes LOS and is required for finish.",
    "Unknown if action/state trace is partial.",
    { "fixture.static_damage_clock.true", "fixture.static_damage_clock.false" },
    { "contract_validation", "quality_scoring", "promotion" }
  ),
  multi_unit_damage_clock = mk(
    "multi_unit_damage_clock",
    "True when multiple Blue units chain Commandant damage as primary mechanism without intermediate tactical lock/key events.",
    { "ScenarioState", "Action[]", "MechanismSpec" },
    "boolean|unknown",
    "Classify damage chain and require declared intermediate mechanism transitions; otherwise true.",
    "scenario_tooling.predicate_eval",
    "Hash over chain classifier and mechanism-transition checks.",
    "Two supports plus finisher sequentially damage Commandant with no enabling interaction.",
    "Support action first removes blocker and changes viable finish set.",
    "Unknown when mechanism markers or replay data are missing.",
    { "fixture.multi_unit_damage_clock.true", "fixture.multi_unit_damage_clock.false" },
    { "contract_validation", "quality_scoring", "promotion" }
  ),
  free_finisher_move = mk(
    "free_finisher_move",
    "True when finisher can move-and-shoot with no cost/risk/ordering constraint or trade-off.",
    { "ScenarioState", "UnitState", "Action[]", "MechanismSpec" },
    "boolean|unknown",
    "Detect unconstrained finisher movement to attack cell and zero counterfactual penalty.",
    "scenario_tooling.predicate_eval",
    "Hash over finisher constraints and penalty detector.",
    "Finisher steps into range and attacks; every branch still wins identically.",
    "Finisher advance requires prior shield setup or loses to counterattack.",
    "Unknown if risk model/counterfactual branches are unavailable.",
    { "fixture.free_finisher_move.true", "fixture.free_finisher_move.false" },
    { "contract_validation", "quality_scoring", "promotion" }
  ),
  support_already_free = mk(
    "support_already_free",
    "True when a support unit starts already in solved position and only contributes flat damage/value.",
    { "ScenarioState", "UnitState", "MechanismSpec", "AblationResult" },
    "boolean|unknown",
    "Check start-state support role; true if no enabling work is required and ablation shows only additive output.",
    "scenario_tooling.predicate_eval",
    "Hash over support-role taxonomy and ablation comparator.",
    "Support starts in final LOS and only adds fixed damage tick.",
    "Support must reposition through threatened corridor to unlock key line.",
    "Unknown if support role or ablation evidence cannot be computed.",
    { "fixture.support_already_free.true", "fixture.support_already_free.false" },
    { "contract_validation", "quality_scoring", "promotion" }
  ),
  cosmetic_red_pressure = mk(
    "cosmetic_red_pressure",
    "True when Red pressure appears but does not change Blue decision, false line, timing, or exactness.",
    { "ScenarioState", "pressureFeatureId", "AblationResult", "ProofCertificate" },
    "boolean|unknown",
    "Ablate pressure and compare decision graph/timing; unchanged results mark pressure cosmetic.",
    "scenario_tooling.predicate_eval",
    "Hash over decision-graph comparator and timing metrics.",
    "Red side move animation but no branch/timing difference.",
    "Red threat forces exact defensive tempo in winning line.",
    "Unknown if decision graph or timing data are incomplete.",
    { "fixture.cosmetic_red_pressure.true", "fixture.cosmetic_red_pressure.false" },
    { "contract_validation", "quality_scoring", "promotion" }
  ),
  macro_template_signature = mk(
    "macro_template_signature",
    "True when candidate matches disallowed macro-template structure rather than seed-driven mechanism variation.",
    { "GenerationDossier", "TacticalFingerprint", "templateLibrarySignatures" },
    "boolean|unknown",
    "Canonicalize fingerprint and compare against banned template signatures with exact/versioned matcher.",
    "scenario_tooling.predicate_eval",
    "Hash over canonical fingerprint encoder and template signature set.",
    "Candidate fingerprint equals known prebuilt complete scenario template.",
    "Candidate shares finisher family but differs in mechanism graph and risk path.",
    "Unknown if canonical fingerprint or signature set is unavailable.",
    { "fixture.macro_template_signature.true", "fixture.macro_template_signature.false" },
    { "contract_validation", "quality_scoring", "promotion" }
  ),
  fingerprint_distinct = mk(
    "fingerprint_distinct",
    "True when tactical fingerprint is canonical, versioned, reproducible, and distinct from equivalence class under declared thresholds.",
    { "TacticalFingerprint", "fingerprintCorpus", "equivalenceThresholds" },
    "boolean|unknown",
    "Recompute canonical fingerprint from scenario + predicates, then run deterministic distinctness check.",
    "scenario_tooling.predicate_eval",
    "Hash covers canonicalizer version and equivalence thresholds.",
    "Fingerprint differs in mechanism class and required interactions from corpus nearest neighbor.",
    "Fingerprint differs only by coordinates while mechanism graph is equivalent.",
    "Unknown if recomputation or corpus comparison is unavailable.",
    { "fixture.fingerprint_distinct.true", "fixture.fingerprint_distinct.false" },
    { "quality_scoring", "promotion", "contract_validation" }
  ),
  defensive_domain_inclusion = mk(
    "defensive_domain_inclusion",
    "True when a Red defense belongs to proof domain by computable current-state predicates only.",
    { "ScenarioState", "Action", "DefensiveDomainRule", "PredicateResult[]" },
    "boolean|unknown",
    "Evaluate domain rule tree using only frozen predicates over current state; no narrative or lookahead hacks.",
    "scenario_tooling.defensive_domain",
    "Hash over domain-rule AST + referenced predicate versions.",
    "Action attacks critical Blue unit; critical predicate true; rule includes action.",
    "Action is narratively scary but no inclusion predicate evaluates true.",
    "Unknown if any referenced predicate returns unknown; must not auto-include as proven.",
    { "fixture.defensive_domain_inclusion.true", "fixture.defensive_domain_inclusion.false" },
    { "solver_proof", "proof_domain_inclusion", "contract_validation", "promotion" }
  ),
  defensive_equivalence = mk(
    "defensive_equivalence",
    "True when exclude candidate is narrowly equivalent to included policy choice: same tactical class, bounded score epsilon, no effect on safety/critical units/cells/lines/timing/micros.",
    { "ScenarioState", "includedAction", "excludedAction", "equivalenceConfig", "PredicateResult[]" },
    "boolean|unknown",
    "Compute normalized tactical class and constrained deltas; equivalence true only if all guarded dimensions match.",
    "scenario_tooling.defensive_domain",
    "Hash over equivalence guard dimensions + epsilon + class normalizer.",
    "Two Red sidesteps to symmetric safe cells with identical downstream predicates and score within epsilon.",
    "Excluded action changes required_cell or gains_time outcome relative to included action.",
    "Unknown if any guarded predicate comparison is unavailable; fallback must be unknown/reject.",
    { "fixture.defensive_equivalence.true", "fixture.defensive_equivalence.false" },
    { "solver_proof", "proof_domain_inclusion", "contract_validation", "promotion" }
  ),
}

function M.getPredicate(name)
  return M.predicates[name]
end

function M.listPredicateNames()
  local names = {}
  for i = 1, #M.requiredPredicates do
    names[i] = M.requiredPredicates[i]
  end
  return names
end

function M.validateFreeze()
  local errors = {}
  local requiredFields = {
    "name",
    "version",
    "description",
    "inputSchemas",
    "outputType",
    "deterministicBehavior",
    "ownerModule",
    "versionHashStrategy",
    "trueExample",
    "falseExample",
    "unknownBehavior",
    "fixtureCoverageKeys",
    "affects",
  }
  local allowedAffects = {
    contract_validation = true,
    solver_proof = true,
    quality_scoring = true,
    proof_domain_inclusion = true,
    promotion = true,
  }

  if type(M.module) ~= "table" then
    errors[#errors + 1] = "module metadata must be a table"
  elseif type(M.module.antiSelfAcquittalRule) ~= "string" or M.module.antiSelfAcquittalRule == "" then
    errors[#errors + 1] = "antiSelfAcquittalRule must be present"
  end

  for i = 1, #M.requiredPredicates do
    local name = M.requiredPredicates[i]
    local pred = M.predicates[name]
    if pred == nil then
      errors[#errors + 1] = "missing required predicate: " .. name
    else
      for j = 1, #requiredFields do
        local field = requiredFields[j]
        local value = pred[field]
        if value == nil then
          errors[#errors + 1] = name .. " missing field: " .. field
        end
      end
      if pred.name ~= name then
        errors[#errors + 1] = name .. " name mismatch: " .. tostring(pred.name)
      end
      if type(pred.inputSchemas) ~= "table" or #pred.inputSchemas == 0 then
        errors[#errors + 1] = name .. " inputSchemas must be non-empty list"
      end
      if type(pred.fixtureCoverageKeys) ~= "table" or #pred.fixtureCoverageKeys < 2 then
        errors[#errors + 1] = name .. " fixtureCoverageKeys must include true and false keys"
      end
      if type(pred.affects) ~= "table" or #pred.affects == 0 then
        errors[#errors + 1] = name .. " affects must be a non-empty list"
      else
        local seen = {}
        for k = 1, #pred.affects do
          local target = pred.affects[k]
          if not allowedAffects[target] then
            errors[#errors + 1] = name .. " has invalid affects target: " .. tostring(target)
          elseif seen[target] then
            errors[#errors + 1] = name .. " has duplicate affects target: " .. tostring(target)
          else
            seen[target] = true
          end
        end
      end
    end
  end

  for name, _ in pairs(M.predicates) do
    local found = false
    for i = 1, #M.requiredPredicates do
      if M.requiredPredicates[i] == name then
        found = true
        break
      end
    end
    if not found then
      errors[#errors + 1] = "unexpected predicate in freeze table: " .. name
    end
  end

  return #errors == 0, errors
end

return M
