local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local ButtonWidget = require("ui/widget/button")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Size = require("ui/size")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Lichess = require("lichess")

local FrameContainer = require("ui/widget/container/framecontainer")

local LichessDashboard = FrameContainer:extend{
    name = "lichess_dashboard",
}

function LichessDashboard:paintTo(bb, x, y)
    bb:paintRect(0, 0, Screen:getWidth(), Screen:getHeight(), Blitbuffer.COLOR_WHITE)
    FrameContainer.paintTo(self, bb, x, y)
end

function LichessDashboard:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    self.dimen = require("ui/geometry"):new{ w = self.width, h = self.height }
    self.background = Blitbuffer.COLOR_WHITE
    self.padding = 0
    self.bordersize = 0
    self.covers_fullscreen = true

    self.loading_text = TextWidget:new{ text = _("Fetching Lichess profile..."), face = Font:getFace("cfont", 24) }
    
    self[1] = CenterContainer:new{
        dimen = require("ui/geometry"):new{ w = Screen:getWidth(), h = Screen:getHeight() },
        VerticalGroup:new{ align = "center", self.loading_text }
    }
    
    UIManager:nextTick(function() self:fetchData() end)
end

function LichessDashboard:fetchData()
    local token = self.parent:getSetting("lichess_token", "")
    local api = Lichess.new{ token = token, curl = self.parent:getSetting("lichess_curl_path", "curl") }
    
    api:request({ path = "/api/account" }, function(ok, account_data, code, err)
        -- ok can still come back with an empty or unparseable body.
        if not ok or type(account_data) ~= "table" then
            local nl = string.char(10)
            self:showError(_("Could not reach Lichess") .. ":" .. nl ..
                tostring(err or "unexpected response") .. nl .. nl ..
                _("Online play needs curl installed on this device."))
            return
        end

        local username = account_data.username or account_data.id or "Unknown"
        
        api:request({ path = "/api/games/user/" .. username .. "?max=5" }, function(g_ok, games_data)
            self:buildDashboard(account_data, g_ok and games_data or {})
        end)
    end)
end

function LichessDashboard:showError(msg)
    -- Build the group into a local first. Previously this was assigned to
    -- self[1] and then self[1] was overwritten by a container whose only child
    -- was `group` -- an undeclared global, so nil, which crashed on paint.
    local group = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = msg, face = Font:getFace("cfont", 20) },
        VerticalSpan:new{ width = 10, height = 40 },
        ButtonWidget:new{
            text = _("Back"),
            width = math.floor(Screen:getWidth() * 0.6), height = 60,
            callback = function() self:goBack() end
        }
    }
    self[1] = CenterContainer:new{
        dimen = require("ui/geometry"):new{ w = Screen:getWidth(), h = Screen:getHeight() },
        group
    }
    UIManager:setDirty(self, "ui")
end

function LichessDashboard:goBack()
    UIManager:close(self)
    local StartMenu = require("startmenu")
    local menu = StartMenu:new{ parent = self.parent }
    UIManager:show(menu)
end

function LichessDashboard:buildDashboard(account, games)
    local username = account.username or "Unknown"
    local perfs = account.perfs or {}
    local puzzle_rating = (perfs.puzzle and perfs.puzzle.rating) or "?"
    local rapid_rating = (perfs.rapid and perfs.rapid.rating) or "?"
    local blitz_rating = (perfs.blitz and perfs.blitz.rating) or "?"

    local header = TextWidget:new{
        text = username,
        face = Font:getFace("cfont", 40),
        bold = true
    }
    
    local function makeCard(title, rating)
        return FrameContainer:new{
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = 15,
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{
                align = "center",
                TextWidget:new{ text = title, face = Font:getFace("cfont", 18) },
                VerticalSpan:new{ width = 10, height = 10 },
                TextWidget:new{ text = tostring(rating), face = Font:getFace("cfont", 24), bold = true },
            }
        }
    end

    local cards = HorizontalGroup:new{
        align = "center",
        makeCard("Puzzles", puzzle_rating),
        HorizontalSpan:new{ width = 20 },
        makeCard("Rapid", rapid_rating),
        HorizontalSpan:new{ width = 20 },
        makeCard("Blitz", blitz_rating),
    }

    local history_group = VerticalGroup:new{ align = "left" }
    table.insert(history_group, TextWidget:new{ text = "Recent Games", face = Font:getFace("cfont", 20), bold = true })
    table.insert(history_group, VerticalSpan:new{ width = 10, height = 10 })

    if not games or #games == 0 then
        table.insert(history_group, TextWidget:new{ text = "No recent games found.", face = Font:getFace("cfont", 18) })
    else
        for _, g in ipairs(games) do
            local color = "?"
            local opp_name = "?"
            local opp_rating = "?"
            if g.players and g.players.white and g.players.white.user and g.players.white.user.name == username then
                color = "white"
                opp_name = (g.players.black and g.players.black.user and g.players.black.user.name) or "?"
                opp_rating = (g.players.black and g.players.black.rating) or "?"
            elseif g.players and g.players.black and g.players.black.user and g.players.black.user.name == username then
                color = "black"
                opp_name = (g.players.white and g.players.white.user and g.players.white.user.name) or "?"
                opp_rating = (g.players.white and g.players.white.rating) or "?"
            end
            
            local result = "="
            if g.winner == color then result = "+"
            elseif g.winner then result = "-" end

            local type_str = (g.perf == "blitz" and "Blitz") or (g.perf == "rapid" and "Rapid") or g.perf or "?"
            
            local row_text = string.format("[%s] %s (%s)  %s", type_str, opp_name, tostring(opp_rating), result)
            table.insert(history_group, TextWidget:new{ text = row_text, face = Font:getFace("cfont", 18) })
            table.insert(history_group, VerticalSpan:new{ width = 10, height = 5 })
        end
    end

    local btn_w = math.floor(Screen:getWidth() * 0.6)
    local btn_h = 60

    local btn_play = ButtonWidget:new{
        text = _("Play a Game"),
        width = btn_w, height = btn_h,
        callback = function()
            UIManager:close(self)
            self.parent:setSetting("play_online", true)
            self.parent:setSetting("game_mode", "chess")
            self.parent:startGame()
        end
    }

    local btn_puzzles = ButtonWidget:new{
        text = _("Solve Puzzles"),
        width = btn_w, height = btn_h,
        callback = function()
            UIManager:close(self)
            if self.parent.startPuzzle then self.parent:startPuzzle(true) end
        end
    }

    local btn_back = ButtonWidget:new{
        text = _("Back"),
        width = btn_w, height = btn_h,
        callback = function() self:goBack() end
    }
    
    local content = VerticalGroup:new{
        align = "center",
        header,
        VerticalSpan:new{ width = 10, height = 20 },
        cards,
        VerticalSpan:new{ width = 10, height = 30 },
        history_group,
        VerticalSpan:new{ width = 10, height = 40 },
        btn_play,
        VerticalSpan:new{ width = 10, height = 15 },
        btn_puzzles,
        VerticalSpan:new{ width = 10, height = 15 },
        btn_back
    }
    self[1] = CenterContainer:new{
        dimen = require("ui/geometry"):new{ w = Screen:getWidth(), h = Screen:getHeight() },
        content
    }

    UIManager:setDirty(self, "ui")
end

return LichessDashboard
