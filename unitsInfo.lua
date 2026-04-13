local unitsInfo = {}

unitsInfo.stats = {
    ["Commandant"]   = {startingHp = 12,
                    hp = 12,
                    move = 0,
                    atkRange = 1,
                    atkDamage = 1,
                    damage = 1,
                    fly = false,
                    repair = false,
                    name = "Commandant",
                    shortName = "CM",
                    descriptions = "The Commandant is the heart of your operations. Defend it!",
                    specialAbilitiesDescriptions = "Deploy new units on the battlefield. Automatically defend adjacent cells from enemy units.",
                    path = "assets/sprites/Blu_General.png",
                    pathRed = "assets/sprites/Red_General.png",
                    pathUiIcon = "assets/sprites/Blu_General.png",
                    pathUiIconRed = "assets/sprites/Red_General.png"
                },
    ["Wingstalker"]   = {startingHp = 3,
                    hp = 3,
                    move = 3,
                    atkRange = 1,
                    atkDamage = 1,
                    damage = 1,
                    fly = true,
                    repair = false,
                    name = "Wingstalker",
                    shortName = "WS",
                    descriptions = "Fast and agile, perfect for quick engagements skirmishes",
                    specialAbilitiesDescriptions = "+1 damage against flying units",
                    path = "assets/sprites/Blu_ScoutDrone.png",
                    pathRed = "assets/sprites/Red_ScoutDrone.png",
                    pathUiIcon = "assets/sprites/Blu_ScoutDrone.png",
                    pathUiIconRed = "assets/sprites/Red_ScoutDrone.png"
                },
    ["Crusher"]  = {startingHp = 4,
                    hp = 4,
                    move = 2,
                    atkRange = 1,
                    atkDamage = 3,
                    damage = 3,
                    fly = false,
                    repair = false,
                    name = "Crusher",
                    shortName = "CR",
                    descriptions = "An all around unit designed for frontline combat",
                    specialAbilitiesDescriptions = "+1 damage against enemy Commandant.",
                    path = "assets/sprites/Blu_AssaultMech.png",
                    pathRed = "assets/sprites/Red_AssaultMech.png",
                    pathUiIcon = "assets/sprites/Blu_AssaultMech.png",
                    pathUiIconRed = "assets/sprites/Red_AssaultMech.png"
                },
    ["Bastion"]     = {startingHp = 6,
                    hp = 6,
                    move = 3,
                    atkRange = 1,
                    atkDamage = 1,
                    damage = 1,
                    fly = false,
                    repair = false,
                    name = "Bastion",
                    shortName = "BA",
                    descriptions = "The perfect tank unit with high melee defence",
                    specialAbilitiesDescriptions = "-1 damage from melee attacks.",
                    path = "assets/sprites/Blu_GigaMech.png",
                    pathRed = "assets/sprites/Red_GigaMech.png",
                    pathUiIcon = "assets/sprites/Blu_GigaMech.png",
                    pathUiIconRed = "assets/sprites/Red_GigaMech.png"
                },
    ["Cloudstriker"]    = {startingHp = 4,
                    hp = 4,
                    move = 3,
                    atkRange = 3,
                    atkDamage = 2,
                    damage = 2,
                    fly = true,
                    repair = false,
                    name = "Cloudstriker",
                    shortName = "CS",
                    descriptions = "THE long-range unit, perfect for sniping or clear paths",
                    specialAbilitiesDescriptions = "Can't attack adjacent cells. Can't shoot through Rock. +1 damage to Rocks and Commandant.",
                    path = "assets/sprites/Blu_Corvette.png",
                    pathRed = "assets/sprites/Red_Corvette.png",
                    pathUiIcon = "assets/sprites/Blu_Corvette.png",
                    pathUiIconRed = "assets/sprites/Red_Corvette.png"
                },
    ["Earthstalker"]   = {startingHp = 3,
                    hp = 3,
                    move = 2,
                    atkRange = 1,
                    atkDamage = 2,
                    damage = 2,
                    fly = false,
                    repair = false,
                    name = "Earthstalker",
                    shortName = "ES",
                    descriptions = "Great offensive unit, expecially against other units",
                    specialAbilitiesDescriptions = "+2 damage against non-flying units.",
                    path = "assets/sprites/Blu_MechHunter.png",
                    pathRed = "assets/sprites/Red_MechHunter.png",
                    pathUiIcon = "assets/sprites/Blu_MechHunter.png",
                    pathUiIconRed = "assets/sprites/Red_MechHunter.png"
                },
    ["Healer"]  = {startingHp = 4,
                    hp = 4,
                    move = 3,
                    atkRange = 1,
                    atkDamage = 1,
                    damage = 1,
                    fly = true,
                    repair = true,
                    name = "Healer",
                    shortName = "HE",
                    descriptions = "Can repair damaged units, keeping your forces in the fight",
                    specialAbilitiesDescriptions = "+2 HP for damaged ally units and Commandant.",
                    path = "assets/sprites/Blu_Repair.png",
                    pathRed = "assets/sprites/Red_Repair.png",
                    pathUiIcon = "assets/sprites/Blu_Repair.png",
                    pathUiIconRed = "assets/sprites/Red_Repair.png"
                },
    ["Artillery"]  = {startingHp = 5,
                hp = 5,
                move = 1,
                atkRange = 3,
                atkDamage = 1,
                damage = 1,
                fly = false,
                repair = false,
                name = "Artillery",
                shortName = "AT",
                descriptions = "Long-range artillery unit, perfect for sniping or clear paths",
                specialAbilitiesDescriptions = "Can't attack adjacent cells. Can shoot through Rock. +1 damage to Rocks and Commandant.",
                path = "assets/sprites/Blu_Artillery.png",
                pathRed = "assets/sprites/Red_Artillery.png",
                pathUiIcon = "assets/sprites/Blu_Artillery.png",
                pathUiIconRed = "assets/sprites/Red_Artillery.png"
            },
    ["Rock"]     = {startingHp = 5,
                    hp = 5,
                    move = 0,
                    atkRange = 0,
                    atkDamage = 0,
                    damage = 0,
                    fly = false,
                    repair = false,
                    name = "Rock",
                    shortName = "RK",
                    descriptions = "A rock. Can be destroyed for strategic advantages.",
                    specialAbilitiesDescriptions = "A rock... Can be destroyed for strategic advantages.",
                    path = "assets/sprites/NeutralBulding1_Resized.png",
                    pathUiIcon = "assets/sprites/NeutralBulding1_Resized.png",
                    pathUiIconRed = "assets/sprites/NeutralBulding1_Resized.png"
                }
    }

-- Function to get unit information by type like "Healer"
function unitsInfo:getUnitInfo(unitType)
    return self.stats[unitType]
end

-- Function to get all unit information
function unitsInfo:getAllUnitInfo()
    return self.stats
end

-- Function to calculate attack damage with special abilities
function unitsInfo:calculateAttackDamage(attackingUnit, defendingUnit)
    if not attackingUnit or not defendingUnit then return 0 end

    local attackerInfo = self:getUnitInfo(attackingUnit.name)
    local defenderInfo = self:getUnitInfo(defendingUnit.name)
    local specialAbilitiesUsed = false 

    if not attackerInfo then return 0 end

    local baseDamage = attackerInfo.atkDamage or 0
    local finalDamage = baseDamage

    -- Apply special attack bonuses
    if attackingUnit.name == "Crusher" and defendingUnit.name == "Commandant" then
        finalDamage = finalDamage + 1
        specialAbilitiesUsed = true
    elseif attackingUnit.name == "Wingstalker" and defendingUnit.fly then
        finalDamage = finalDamage + 1
        specialAbilitiesUsed = true
    elseif attackingUnit.name == "Cloudstriker" and (defendingUnit.name == "Commandant" or defendingUnit.name == "Rock") then
        finalDamage = finalDamage + 1
        specialAbilitiesUsed = true
    elseif attackingUnit.name == "Artillery" and (defendingUnit.name == "Commandant" or defendingUnit.name == "Rock") then
        finalDamage = finalDamage + 1
        specialAbilitiesUsed = true
    elseif attackingUnit.name == "Earthstalker" and defendingUnit.name ~= "Commandant" and defendingUnit.name ~= "Rock" and not defendingUnit.fly then
        finalDamage = finalDamage + 2
        specialAbilitiesUsed = true
    end

    -- Apply defense modifiers
    if defendingUnit.name == "Bastion" and attackingUnit.name ~= "Cloudstriker" and attackingUnit.name ~= "Artillery" then
        finalDamage = finalDamage - 1
    end

    return math.max(0, finalDamage), specialAbilitiesUsed
end

-- Function to check if a unit can attack adjacent cells
function unitsInfo:canAttackAdjacent(unitName)
    return unitName ~= "Cloudstriker" and unitName ~= "Artillery"
end

-- Function to check if a unit can repair
function unitsInfo:canRepair(unitName)
    local unitInfo = self:getUnitInfo(unitName)
    return unitInfo and unitInfo.repair or false
end

-- Function to get unit names for statistics tracking
function unitsInfo:getAllUnitNames()
    local names = {}
    for unitName, _ in pairs(self.stats) do
        if unitName ~= "Rock" then -- Exclude Rocks from unit stats
            table.insert(names, unitName)
        end
    end
    return names
end

-- CENTRALIZED UNIT INFO RETRIEVAL FUNCTIONS WITH DEBUG PRINTING
-- These functions ensure all unit stats come from unitsInfo.lua with visibility

-- Get unit move range with debug printing
function unitsInfo:getUnitMoveRange(unit, debugContext)
    if not unit or not unit.name then
        return 1 -- Safe fallback
    end
    local unitInfo = self:getUnitInfo(unit.name)
    if not unitInfo then
        return 1
    end
    local moveRange = unitInfo.move or 1
    return moveRange
end

-- Get unit attack range
function unitsInfo:getUnitAttackRange(unit, debugContext)
    if not unit or not unit.name then
        return 1 -- Safe fallback
    end
    local unitInfo = self:getUnitInfo(unit.name)
    if not unitInfo then
        return 1
    end
    local attackRange = unitInfo.atkRange or 1
    return attackRange
end

-- Get unit attack damage
function unitsInfo:getUnitAttackDamage(unit, debugContext)
    if not unit or not unit.name then
        return 1 -- Safe fallback
    end
    local unitInfo = self:getUnitInfo(unit.name)
    if not unitInfo then
        return 1
    end
    local attackDamage = unitInfo.atkDamage or 1
    return attackDamage
end

-- Get unit HP
function unitsInfo:getUnitHP(unit, debugContext)
    if not unit or not unit.name then
        return 1 -- Safe fallback
    end
    local unitInfo = self:getUnitInfo(unit.name)
    if not unitInfo then
        return 1
    end
    local hp = unitInfo.startingHp or 1
    return hp
end

-- Get unit fly status
function unitsInfo:getUnitFlyStatus(unit, debugContext)
    if not unit or not unit.name then
        return false -- Safe fallback
    end
    local unitInfo = self:getUnitInfo(unit.name)
    if not unitInfo then
        return false
    end
    local flyStatus = unitInfo.fly or false
    return flyStatus
end

-- Get all unit stats at once with debug printing (comprehensive)
function unitsInfo:getUnitStats(unit, debugContext)
    if not unit or not unit.name then
        return {
            move = 1,
            atkRange = 1,
            atkDamage = 0,
            hp = 1,
            fly = false,
            repair = false
        }
    end
    
    local unitInfo = self:getUnitInfo(unit.name)
    if not unitInfo then
        return {
            move = 1,
            atkRange = 1,
            atkDamage = 0,
            hp = 1,
            fly = false,
            repair = false
        }
    end
    
    local stats = {
        move = unitInfo.move or 1,
        atkRange = unitInfo.atkRange or 1,
        atkDamage = unitInfo.atkDamage or 0,
        hp = unitInfo.startingHp or 1,
        fly = unitInfo.fly or false,
        repair = unitInfo.repair or false
    }
    
    
    return stats
end

return unitsInfo
