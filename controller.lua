local Controller = {}
Controller.__index = Controller

local CONTROLLER_TYPES = {
    HUMAN = "human",
    AI = "ai",
    REMOTE = "remote"
}

function Controller.new(params)
    params = params or {}
    local self = setmetatable({}, Controller)
    self.id = params.id
    self.nickname = params.nickname or "Unknown"
    self.type = params.type or CONTROLLER_TYPES.HUMAN
    self.isLocal = params.isLocal ~= false
    self.metadata = params.metadata or {}
    return self
end

function Controller:serialize()
    return {
        id = self.id,
        nickname = self.nickname,
        type = self.type,
        isLocal = self.isLocal,
        metadata = self.metadata
    }
end

Controller.TYPES = CONTROLLER_TYPES

return Controller
