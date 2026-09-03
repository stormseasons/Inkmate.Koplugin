local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local ButtonWidget = require("ui/widget/button")
local VerticalSpan = require("ui/widget/verticalspan")
local Font = require("ui/font")
local Size = require("ui/size")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")

local SettingsWidget = require("settingswidget")
local LichessWidget = require("lichesswidget")

local FrameContainer = require("ui/widget/container/framecontainer")

local OptionsMenu = FrameContainer:extend{
    name = "inkmate_optionsmenu",
}

function OptionsMenu:paintTo(bb, x, y)
    bb:paintRect(0, 0, Screen:getWidth(), Screen:getHeight(), Blitbuffer.COLOR_WHITE)
    FrameContainer.paintTo(self, bb, x, y)
end

function OptionsMenu:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    self.dimen = require("ui/geometry"):new{ w = self.width, h = self.height }
    self.background = Blitbuffer.COLOR_WHITE
    self.padding = 0
    self.bordersize = 0
    self.covers_fullscreen = true

    self.title = TextWidget:new{
        text = _("Settings"),
        face = Font:getFace("cfont", 50),
        bold = true,
        align = "center",
    }
    
    self.btn_w = math.floor(Screen:getWidth() * 0.6)
    self.btn_h = 70

    local options_menu_self = self

    local btn_offline = ButtonWidget:new{
        text = _("Offline Options"),
        width = self.btn_w, height = self.btn_h,
        callback = function()
            SettingsWidget:new{
                engine = self.engine,
                timer = self.timer,
                game = self.game,
                parent = self.parent,
                onApply = function()
                    UIManager:setDirty(options_menu_self, "ui")
                end,
            }:show()
        end
    }

    local btn_online = ButtonWidget:new{
        text = _("Online Options"),
        width = self.btn_w, height = self.btn_h,
        callback = function()
            local p = self.parent
            local function get(key, default)
                if p and p.getSetting then return p:getSetting(key, default) end
                return default
            end
            local lw = LichessWidget:new{
                parent = p,
                initial = {
                    play_online     = get("play_online", false),
                    lichess_token   = get("lichess_token", ""),
                    seek_minutes    = get("seek_minutes", 10),
                    seek_increment  = get("seek_increment", 0),
                    seek_rated      = get("seek_rated", false),
                    seek_color      = get("seek_color", "random"),
                    lichess_game_id = get("lichess_game_id", ""),
                },
                onSave = function(saved)
                    if p and p.setSetting then
                        p:setSetting("play_online",     saved.play_online and true or false)
                        p:setSetting("lichess_token",   saved.lichess_token or "")
                        p:setSetting("seek_minutes",    tonumber(saved.seek_minutes) or 10)
                        p:setSetting("seek_increment",  tonumber(saved.seek_increment) or 0)
                        p:setSetting("seek_rated",      saved.seek_rated and true or false)
                        p:setSetting("seek_color",      saved.seek_color or "random")
                        p:setSetting("lichess_game_id", saved.lichess_game_id or "")
                    end
                    UIManager:setDirty(options_menu_self, "ui")
                end,
            }
            lw:show()
        end
    }

    local btn_back = ButtonWidget:new{
        text = _("Back"),
        width = self.btn_w, height = self.btn_h,
        callback = function()
            UIManager:close(self)
            -- This menu covers the whole screen, so whatever sits underneath
            -- has to be repainted explicitly or it comes back blank.
            if self.on_close then self.on_close() end
        end
    }

    local group = VerticalGroup:new{
        align = "center",
        self.title,
        VerticalSpan:new{ width = 10, height = 60 },
        btn_offline,
        VerticalSpan:new{ width = 10, height = 20 },
        btn_online,
        VerticalSpan:new{ width = 10, height = 20 },
        btn_back,
    }

    self[1] = CenterContainer:new{
        dimen = require("ui/geometry"):new{ w = Screen:getWidth(), h = Screen:getHeight() },
        group
    }
    UIManager:setDirty(self, "ui")
end

function OptionsMenu:show()
    UIManager:show(self)
end

return OptionsMenu
