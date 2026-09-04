local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local ButtonWidget = require("ui/widget/button")
local VerticalSpan = require("ui/widget/verticalspan")
local ImageWidget = require("ui/widget/imagewidget")
local Font = require("ui/font")
local Size = require("ui/size")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local LichessDashboard = require("lichessdashboard")

local FrameContainer = require("ui/widget/container/framecontainer")

local StartMenu = FrameContainer:extend{
    name = "inkmate_startmenu",
}

function StartMenu:paintTo(bb, x, y)
    -- Clear stale pixels on e-ink before redrawing (e.g. menu transitions).
    bb:paintRect(0, 0, Screen:getWidth(), Screen:getHeight(), Blitbuffer.COLOR_WHITE)
    FrameContainer.paintTo(self, bb, x, y)
end

function StartMenu:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    self.dimen = require("ui/geometry"):new{ w = self.width, h = self.height }
    self.background = Blitbuffer.COLOR_WHITE
    self.padding = 0
    self.bordersize = 0
    self.covers_fullscreen = true

    -- Resolve logo path relative to this plugin's directory
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    local plugin_dir = src:match("^(.*[/\\])") or "."
    local logo_path = plugin_dir .. "inkmate_logo.jpg"

    self.title = CenterContainer:new{
        dimen = require("ui/geometry"):new{ w = Screen:getWidth(), h = 200 },
        ImageWidget:new{
            file = logo_path,
        },
    }
    
    self.btn_w = math.floor(Screen:getWidth() * 0.6)
    self.btn_h = 70

    -- When recreated from LichessDashboard:goBack(), the callbacks may not be
    -- passed explicitly. Fall back to the parent's stored versions so every
    -- button keeps working after a dashboard round-trip.
    if not self.onPlayOffline and self.parent and self.parent._start_onPlayOffline then
        self.onPlayOffline = self.parent._start_onPlayOffline
    end
    if not self.onPromptToken and self.parent and self.parent._start_onPromptToken then
        self.onPromptToken = self.parent._start_onPromptToken
    end
    if not self.onOptions and self.parent and self.parent._start_onOptions then
        self.onOptions = self.parent._start_onOptions
    end

    self:showMainMenu()
end

function StartMenu:showMainMenu()
    local btn_offline = ButtonWidget:new{
        text = _("Play Offline"),
        width = self.btn_w, height = self.btn_h,
        callback = function() self:showOfflineMenu() end
    }

    local btn_online = ButtonWidget:new{
        text = _("Play on Lichess"),
        width = self.btn_w, height = self.btn_h,
        callback = function()
            local token = self.parent:getSetting("lichess_token", "")
            if token == "" then
                if self.onPromptToken then self.onPromptToken() end
            else
                local dashboard = LichessDashboard:new{ parent = self.parent }
                UIManager:show(dashboard)
                UIManager:close(self)
            end
        end
    }

    local btn_options = ButtonWidget:new{
        text = _("Options"),
        width = self.btn_w, height = self.btn_h,
        callback = function() if self.onOptions then self.onOptions() end end
    }

    local btn_exit = ButtonWidget:new{
        text = _("Exit"),
        width = self.btn_w, height = self.btn_h,
        callback = function()
            if self.parent then
                if self.parent.stopThinkingIndicator then self.parent:stopThinkingIndicator() end
                if self.parent.timer and self.parent.timer.stop then self.parent.timer:stop() end
                if self.parent.saveGameState then self.parent:saveGameState() end
            end
            UIManager:close(self, "full")
        end
    }

    local group = VerticalGroup:new{
        align = "center",
        self.title,
        VerticalSpan:new{ width = 10, height = 80 },
        btn_offline,
        VerticalSpan:new{ width = 10, height = 20 },
        btn_online,
        VerticalSpan:new{ width = 10, height = 20 },
        btn_options,
        VerticalSpan:new{ width = 10, height = 20 },
        btn_exit,
    }

    self[1] = CenterContainer:new{
        dimen = require("ui/geometry"):new{ w = Screen:getWidth(), h = Screen:getHeight() },
        group
    }
    UIManager:setDirty(self, "ui")
end

function StartMenu:showOfflineMenu()
    local btn_computer = ButtonWidget:new{
        text = _("Play Against the Computer"),
        width = self.btn_w, height = self.btn_h,
        callback = function()
            UIManager:close(self)
            if self.onPlayOffline then self.onPlayOffline() end
        end
    }

    local btn_puzzles = ButtonWidget:new{
        text = _("Solve Puzzles"),
        width = self.btn_w, height = self.btn_h,
        callback = function()
            UIManager:close(self)
            if self.parent.startPuzzle then self.parent:startPuzzle(false) end
        end
    }

    local btn_back = ButtonWidget:new{
        text = _("Back"),
        width = self.btn_w, height = self.btn_h,
        callback = function() self:showMainMenu() end
    }

    local group = VerticalGroup:new{
        align = "center",
        self.title,
        VerticalSpan:new{ width = 10, height = 80 },
        btn_computer,
        VerticalSpan:new{ width = 10, height = 20 },
        btn_puzzles,
        VerticalSpan:new{ width = 10, height = 20 },
        btn_back,
    }

    self[1] = CenterContainer:new{
        dimen = require("ui/geometry"):new{ w = Screen:getWidth(), h = Screen:getHeight() },
        group
    }
    UIManager:setDirty(self, "ui")
end

return StartMenu
