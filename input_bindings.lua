local ACTIONS = require("input_actions")

local function actionId(action)
    return action and action.id or nil
end

local bindings = {
    gamepad = {
        buttonToAction = {
            dpup = actionId(ACTIONS.NAV_UP),
            dpdown = actionId(ACTIONS.NAV_DOWN),
            dpleft = actionId(ACTIONS.NAV_LEFT),
            dpright = actionId(ACTIONS.NAV_RIGHT),

            a = actionId(ACTIONS.CONFIRM),
            x = actionId(ACTIONS.ALT_CONFIRM),
            y = actionId(ACTIONS.CONTEXT_TOGGLE),
            start = actionId(ACTIONS.CODEX_TOGGLE),

            b = actionId(ACTIONS.CANCEL),
            back = actionId(ACTIONS.CANCEL),

            leftshoulder = actionId(ACTIONS.TAB_LEFT),
            rightshoulder = actionId(ACTIONS.TAB_RIGHT)
        },
        axisToActions = {
            leftx = {negative = actionId(ACTIONS.NAV_LEFT), positive = actionId(ACTIONS.NAV_RIGHT)},
            lefty = {negative = actionId(ACTIONS.NAV_UP), positive = actionId(ACTIONS.NAV_DOWN)},
            righty = {negative = actionId(ACTIONS.PAGE_UP), positive = actionId(ACTIONS.PAGE_DOWN)}
        },
        triggerAxesToAction = {
            triggerleft = actionId(ACTIONS.CONFIRM),
            triggerright = actionId(ACTIONS.CONFIRM)
        },
        ignoredAxes = {
            lefttrigger = true,
            righttrigger = true
        }
    },
    joystick = {
        buttonToAction = {
            [1] = actionId(ACTIONS.CONFIRM),
            [2] = actionId(ACTIONS.CANCEL),
            [3] = actionId(ACTIONS.ALT_CONFIRM),
            [5] = actionId(ACTIONS.TAB_LEFT),
            [6] = actionId(ACTIONS.TAB_RIGHT),
            [7] = actionId(ACTIONS.CANCEL),
            [8] = actionId(ACTIONS.CANCEL)
        },
        axisToActions = {
            ["1"] = {negative = actionId(ACTIONS.NAV_LEFT), positive = actionId(ACTIONS.NAV_RIGHT)},
            ["2"] = {negative = actionId(ACTIONS.NAV_UP), positive = actionId(ACTIONS.NAV_DOWN)}
        }
    },
    steamInput = {
        manifestFile = "steam_input_manifest.vdf",
        actionSet = "global_controls",
        digitalActionToAction = {
            nav_up = actionId(ACTIONS.NAV_UP),
            nav_down = actionId(ACTIONS.NAV_DOWN),
            nav_left = actionId(ACTIONS.NAV_LEFT),
            nav_right = actionId(ACTIONS.NAV_RIGHT),
            confirm = actionId(ACTIONS.CONFIRM),
            cancel = actionId(ACTIONS.CANCEL),
            alt_confirm = actionId(ACTIONS.ALT_CONFIRM),
            context_toggle = actionId(ACTIONS.CONTEXT_TOGGLE),
            codex_toggle = actionId(ACTIONS.CODEX_TOGGLE),
            tab_left = actionId(ACTIONS.TAB_LEFT),
            tab_right = actionId(ACTIONS.TAB_RIGHT),
            page_up = actionId(ACTIONS.PAGE_UP),
            page_down = actionId(ACTIONS.PAGE_DOWN)
        },
        analogActionToNavigation = {
            -- Steam Input joystick_move reports positive Y for stick-up on the profiles we ship.
            navigate = {
                x = {negative = actionId(ACTIONS.NAV_LEFT), positive = actionId(ACTIONS.NAV_RIGHT)},
                y = {negative = actionId(ACTIONS.NAV_DOWN), positive = actionId(ACTIONS.NAV_UP)}
            },
            page_scroll = {
                y = {negative = actionId(ACTIONS.PAGE_DOWN), positive = actionId(ACTIONS.PAGE_UP)}
            }
        }
    },
    actionToKey = {
        [ACTIONS.NAV_UP.id] = "w",
        [ACTIONS.NAV_DOWN.id] = "s",
        [ACTIONS.NAV_LEFT.id] = "a",
        [ACTIONS.NAV_RIGHT.id] = "d",
        [ACTIONS.CONFIRM.id] = "return",
        [ACTIONS.CANCEL.id] = "escape",
        [ACTIONS.ALT_CONFIRM.id] = "space",
        [ACTIONS.CONTEXT_TOGGLE.id] = "tab",
        [ACTIONS.CODEX_TOGGLE.id] = "c",
        [ACTIONS.TAB_LEFT.id] = "q",
        [ACTIONS.TAB_RIGHT.id] = "e",
        [ACTIONS.PAGE_UP.id] = "pageup",
        [ACTIONS.PAGE_DOWN.id] = "pagedown",
        [ACTIONS.BACK_TO_MENU.id] = "escape"
    },
    repeatConfig = {
        axisThreshold = 0.45,
        axisReleaseThreshold = 0.35,
        axisInitialDelay = 0.25,
        axisRepeatInterval = 0.08,
        buttonInitialDelay = 0.25,
        buttonRepeatInterval = 0.08
    }
}

return bindings
