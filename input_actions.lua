local inputActions = {
    NAV_UP = {id = "NAV_UP", steamActionName = "nav_up"},
    NAV_DOWN = {id = "NAV_DOWN", steamActionName = "nav_down"},
    NAV_LEFT = {id = "NAV_LEFT", steamActionName = "nav_left"},
    NAV_RIGHT = {id = "NAV_RIGHT", steamActionName = "nav_right"},
    CONFIRM = {id = "CONFIRM", steamActionName = "confirm"},
    CANCEL = {id = "CANCEL", steamActionName = "cancel"},
    ALT_CONFIRM = {id = "ALT_CONFIRM", steamActionName = "alt_confirm"},
    CONTEXT_TOGGLE = {id = "CONTEXT_TOGGLE", steamActionName = "context_toggle"},
    CODEX_TOGGLE = {id = "CODEX_TOGGLE", steamActionName = "codex_toggle"},
    TAB_LEFT = {id = "TAB_LEFT", steamActionName = "tab_left"},
    TAB_RIGHT = {id = "TAB_RIGHT", steamActionName = "tab_right"},
    PAGE_UP = {id = "PAGE_UP", steamActionName = "page_up"},
    PAGE_DOWN = {id = "PAGE_DOWN", steamActionName = "page_down"},
    BACK_TO_MENU = {id = "BACK_TO_MENU", steamActionName = "back_to_menu"}
}

function inputActions.get(actionId)
    return inputActions[actionId]
end

return inputActions
