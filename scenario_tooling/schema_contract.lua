local M = {}

M.freeze = {
  name = "scenario_schema_freeze_step_minus_2",
  version = "1.0.0",
  description = "Frozen schema contract for scenario-only offline tooling (Step -2).",
  deterministic = {
    version_strategy = "SemVer; bump major for breaking schema changes, minor for additive fields, patch for clarifications only.",
    hash_strategy = "Compute SHA-256 over canonical UTF-8 JSON of freeze.version + sorted schema definitions (sorted keys, sorted array values where order is non-semantic).",
    canonicalization = "Stable key ordering; no implicit defaults; explicit null/unknown markers when data is unavailable."
  }
}

local schemas = {
  ScenarioState = {
    name = "ScenarioState",
    version = "1.0.0",
    kind = "record",
    description = "Complete scenario position snapshot used by generator, solver, and proof tooling.",
    required = { "board", "units", "currentPlayer", "scenarioTurn", "turnLimit", "maxActionsPerTurn", "objectiveType", "supplyEnabled" },
    optional = { "seed", "tags", "notes" },
    enums = {
      currentPlayer = { 1, 2, "blue", "red" },
      objectiveType = { "destroy_commandant", "destroy_red_commandant_within_turn_limit" }
    }
  },
  UnitState = {
    name = "UnitState",
    version = "1.0.0",
    kind = "record",
    description = "Per-unit state in scenario mode.",
    required = { "id", "name", "player", "row", "col", "currentHp", "startingHp", "hasMoved", "hasActed" },
    optional = { "status_effects", "used_actions", "metadata" },
    enums = {
      player = { 0, 1, 2, "neutral", "blue", "red" }
    }
  },
  Action = {
    name = "Action",
    version = "1.0.0",
    kind = "record",
    description = "Single legal action emitted by scenario legal move generation.",
    required = { "type", "actorId", "legal" },
    optional = { "from", "to", "targetId", "targetCell", "damage", "cost", "reasonCode" },
    enums = {
      type = { "move", "attack", "end_turn" }
    }
  },
  LegalMoveSet = {
    name = "LegalMoveSet",
    version = "1.0.0",
    kind = "record",
    description = "Deterministic legal move expansion for a given ScenarioState.",
    required = { "stateHash", "actorPlayer", "actions", "generationVersion", "complete" },
    optional = { "pruned", "diagnostics" },
    enums = {
      actor_player = { "blue", "red" }
    }
  },
  MicroInteractionSpec = {
    name = "MicroInteractionSpec",
    version = "1.0.0",
    kind = "record",
    description = "Versioned technical declaration of a micro-interaction used by mechanism and proof analysis.",
    required = { "micro_id", "family", "preconditions", "effect", "timing_window", "verification_predicates" },
    optional = { "required_units", "required_cells", "failure_modes", "unknown_behavior" },
    enums = {
      family = { "unlock", "displacement", "line_open", "tempo_gain", "resource_trade", "threat_redirect" }
    },
    unknown_behavior = "If required analysis is missing, emit unknown and block acceptance."
  },
  MechanismSpec = {
    name = "MechanismSpec",
    version = "1.0.0",
    kind = "record",
    description = "Declared lock-key-path-risk-payoff mechanism for one scenario candidate.",
    required = { "mechanism_id", "family", "lock", "key", "path", "risk", "payoff", "micro_interactions" },
    optional = { "false_trails", "notes", "unknown_behavior" },
    enums = {
      family = { "timing_lock", "los_lock", "access_lock", "survival_lock", "interference_lock" }
    },
    unknown_behavior = "If mechanism cannot be mapped to computable predicates, candidate remains draft/unknown."
  },
  TacticalFingerprint = {
    name = "TacticalFingerprint",
    version = "1.0.0",
    kind = "record",
    description = "Semantic fingerprint used for novelty and anti-macro-template checks.",
    required = { "fingerprint_version", "mechanism_family", "micro_sequence_signature", "role_signature", "pressure_signature", "false_line_signature", "hash" },
    optional = { "distance_features", "symmetry_features", "unknown_behavior" },
    unknown_behavior = "Unknown fingerprint blocks approval and promotion."
  },
  DefensiveDomainRule = {
    name = "DefensiveDomainRule",
    version = "1.0.0",
    kind = "record",
    description = "Rule that classifies Red defensive moves using computable predicates over current state.",
    required = { "rule_id", "predicate_name", "inputs", "decision_if_true", "decision_if_false", "priority", "rule_version" },
    optional = { "decision_if_unknown", "reason_code_true", "reason_code_false", "notes" },
    enums = {
      decision_if_true = { "include", "exclude", "unknown", "fallback_all_legal" },
      decision_if_false = { "include", "exclude", "unknown", "fallback_all_legal" },
      decision_if_unknown = { "include", "exclude", "unknown", "fallback_all_legal" }
    }
  },
  DefensiveDomainDecision = {
    name = "DefensiveDomainDecision",
    version = "1.0.0",
    kind = "record",
    description = "Per-legal-Red-action classification result for solver proof domain.",
    required = { "redAction", "decision", "reasonCodes", "predicateInputs", "predicateResults", "policyScoreBand", "equivalenceReason", "domainVersion" },
    optional = { "stateHash", "domainHash", "ruleTrace", "equivalenceClass", "unknown_behavior" },
    enums = {
      decision = { "include", "exclude", "unknown", "fallback_all_legal" }
    },
    unknown_behavior = "Unknown decision must not silently count as exclude."
  },
  PredicateResult = {
    name = "PredicateResult",
    version = "1.0.0",
    kind = "record",
    description = "Deterministic outcome for one computable semantic predicate.",
    required = { "predicate", "predicateVersion", "inputDigest", "value", "deterministic", "ownerModule" },
    optional = { "evidence", "reason", "unknown_behavior" },
    enums = {
      value = { "true", "false", "unknown" }
    },
    unknown_behavior = "Unknown is explicit and cannot justify acceptance."
  },
  AblationResult = {
    name = "AblationResult",
    version = "1.0.0",
    kind = "record",
    description = "Outcome of removing/altering a unit, cell, pressure, or micro-interaction to test necessity.",
    required = { "ablation_id", "subject_type", "subject_id", "baseline_outcome", "ablated_outcome", "changed", "horizon" },
    optional = { "delta_metrics", "predicate_results", "notes" },
    enums = {
      subject_type = { "unit", "cell", "micro_interaction", "red_pressure", "line", "rule" },
      baseline_outcome = { "forced_win", "unsolved", "unknown", "not_generated" },
      ablated_outcome = { "forced_win", "unsolved", "unknown", "not_generated" }
    }
  },
  QualityFeatureSet = {
    name = "QualityFeatureSet",
    version = "1.0.0",
    kind = "record",
    description = "Versioned, computable quality features and component scores.",
    required = { "feature_version", "features", "component_scores", "total_score", "pass", "reasons" },
    optional = { "threshold_profile", "unknown_behavior" },
    unknown_behavior = "Narrative-only quality checks are forbidden; unknown features fail safe."
  },
  ProofCertificate = {
    name = "ProofCertificate",
    version = "1.0.0",
    kind = "record",
    description = "Verifiable certificate required for scenario certification and promotion eligibility.",
    required = { "seed", "contract_version", "contract_hash", "rules_version", "rules_hash", "policy_version", "policy_hash", "initial_state", "turn_limit", "max_actions_per_turn", "winning_line", "red_responses", "proof_domain_version", "proof_domain_hash", "search_result", "false_lines", "predicate_versions", "tactical_fingerprint" },
    optional = { "defensive_domain_version", "defensive_domain_hash", "explanation", "unknown_behavior" },
    enums = {
      search_result = { "forced_win", "unsolved", "unknown" }
    },
    unknown_behavior = "Missing required versions/hashes invalidates certification."
  },
  RejectionReason = {
    name = "RejectionReason",
    version = "1.0.0",
    kind = "record",
    description = "Structured rejection code and evidence for failed candidate attempts.",
    required = { "code", "category", "message", "blocking", "evidence_refs" },
    optional = { "predicate_results", "suggested_retry_strategy" },
    enums = {
      category = { "contract", "solver", "defensive_domain", "quality", "novelty", "runtime_exactness", "compute_limit" }
    }
  },
  GenerationDossier = {
    name = "GenerationDossier",
    version = "1.0.0",
    kind = "record",
    description = "Top-level result artifact for each generation attempt.",
    required = { "id", "seed", "pipelineState", "scenarioState", "mechanismSpec", "proofCertificate", "qualityFeatureSet", "rejectionReasons", "tacticalFingerprint", "schemaFreezeVersion", "predicateFreezeVersion" },
    optional = { "diagnostics", "retry_hint", "elapsed_ms" },
    enums = {
      pipelineState = { "draft", "candidate", "certified", "approved", "not_generated", "unknown", "unsolved", "forced_win" }
    }
  }
}

local required_schema_names = {
  "ScenarioState",
  "UnitState",
  "Action",
  "LegalMoveSet",
  "MicroInteractionSpec",
  "MechanismSpec",
  "TacticalFingerprint",
  "DefensiveDomainRule",
  "DefensiveDomainDecision",
  "PredicateResult",
  "AblationResult",
  "QualityFeatureSet",
  "ProofCertificate",
  "RejectionReason",
  "GenerationDossier"
}

M.schemas = schemas
M.requiredSchemaNames = required_schema_names

function M.getSchema(name)
  return schemas[name]
end

function M.listSchemaNames()
  local out = {}
  local k
  for k in pairs(schemas) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

function M.validateFreeze()
  local errors = {}
  local i
  local function push(msg)
    errors[#errors + 1] = msg
  end

  if type(M.freeze) ~= "table" then
    push("freeze metadata missing")
  else
    if type(M.freeze.version) ~= "string" or M.freeze.version == "" then
      push("freeze.version missing")
    end
    if type(M.freeze.deterministic) ~= "table" then
      push("freeze.deterministic missing")
    else
      if type(M.freeze.deterministic.version_strategy) ~= "string" or M.freeze.deterministic.version_strategy == "" then
        push("freeze.deterministic.version_strategy missing")
      end
      if type(M.freeze.deterministic.hash_strategy) ~= "string" or M.freeze.deterministic.hash_strategy == "" then
        push("freeze.deterministic.hash_strategy missing")
      end
    end
  end

  for i = 1, #required_schema_names do
    local name = required_schema_names[i]
    local s = schemas[name]
    if type(s) ~= "table" then
      push("missing schema: " .. name)
    else
      if s.name ~= name then
        push("schema " .. name .. " has unstable name field")
      end
      if type(s.version) ~= "string" or s.version == "" then
        push("schema " .. name .. " missing version")
      end
      if type(s.kind) ~= "string" or s.kind == "" then
        push("schema " .. name .. " missing kind")
      end
      if type(s.description) ~= "string" or s.description == "" then
        push("schema " .. name .. " missing description")
      end
      if type(s.required) ~= "table" or #s.required == 0 then
        push("schema " .. name .. " missing required fields")
      end
    end
  end

  return #errors == 0, errors
end

return M
