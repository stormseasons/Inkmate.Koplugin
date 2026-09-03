-- Lichess settings sub-dialog: token, seek preferences, and joining a game.
-- Built the same way as enginewidget.lua so it looks and behaves like the rest
-- of the settings tree.

local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geometry = require("ui/geometry")
local Size = require("ui/size")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputDialog = require("ui/widget/inputdialog")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonWidget = require("ui/widget/button")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local DoubleSpinWidget = require("ui/widget/doublespinwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")

local Lichess = require("lichess")
local _ = require("gettext")

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE

-- KOReader renamed this widget; support both spellings.
local ButtonDialog = (pcall(require, "ui/widget/buttondialog")
        and require("ui/widget/buttondialog"))
    or require("ui/widget/buttondialogtitle")

local LichessWidget = {}
LichessWidget.__index = LichessWidget

function LichessWidget:new(opts)
    assert(opts.parent, "parent is required")
    assert(opts.onSave, "onSave callback is required")

    local init = opts.initial or {}
    local o = setmetatable({
        parent = opts.parent,
        onSave = opts.onSave,
        dialog = nil,
    }, LichessWidget)

    o.changes = {
        play_online     = init.play_online and true or false,
        lichess_token   = init.lichess_token or "",
        seek_minutes    = tonumber(init.seek_minutes) or 10,
        seek_increment  = tonumber(init.seek_increment) or 0,
        seek_rated      = init.seek_rated and true or false,
        seek_color      = init.seek_color or "random",
        lichess_game_id = init.lichess_game_id or "",
    }

    return o
end

function LichessWidget:show()
    local dlg = InputDialog:new{
        title = _("Online Settings"),
        save_callback = function() self:saveAndClose() end,
        dismiss_callback = function() UIManager:close(self.dialog) end,
    }
    dlg.element_width = math.floor(dlg.width * 0.8)
    self.dialog = dlg

    self:buildAccountGroup()
    self:buildTimeControl()
    self:buildRatedToggle()
    self:buildColorGroup()
    self:assembleContent()

    dlg:refocusWidget()
    UIManager:show(dlg)
end

function LichessWidget:markDirty()
    if self.dialog._buttons_edit_callback then
        self.dialog:_buttons_edit_callback(true)
    end
    UIManager:setDirty(self.parent, "ui")
end

-- ------------------------------------------------------------------ account

function LichessWidget:accountLabelText()
    if self.account_name then
        return _("Signed in as") .. ": " .. self.account_name
    end
    if self.changes.lichess_token == "" then
        return _("No token set")
    end
    return _("Token set (not yet tested)")
end

function LichessWidget:buildAccountGroup()
    local w = self.dialog.element_width

    self.accountLabelWidget = TextWidget:new{
        text = self:accountLabelText(),
        face = Font:getFace("cfont", 20),
    }

    self.tokenButton = ButtonWidget:new{
        text = _("Set API token..."),
        width = w,
        radius = Size.radius.button,
        padding = Size.padding.small,
        callback = function() self:openTokenDialog() end,
    }

    self.testButton = ButtonWidget:new{
        text = _("Test connection"),
        width = w,
        radius = Size.radius.button,
        padding = Size.padding.small,
        callback = function() self:testConnection() end,
    }

    self.accountGroup = VerticalGroup:new{
        width = w,
        self.accountLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.tokenButton,
        VerticalSpan:new{ width = Size.padding.small },
        self.testButton,
    }
end

function LichessWidget:refreshAccountLabel()
    if self.accountLabelWidget then
        self.accountLabelWidget:setText(self:accountLabelText())
        UIManager:setDirty(self.dialog, "ui")
    end
end

function LichessWidget:openTokenDialog()
    local input
    input = InputDialog:new{
        title = _("Lichess API token"),
        description = _([[
Create a personal access token at lichess.org/account/oauth/token with the
"Play games with the board API" (board:play) scope.

The token is stored unencrypted in KOReader's settings on this device. Use a
token you can revoke, and give it no other scopes.]]),
        input = self.changes.lichess_token,
        input_hint = "lip_xxxxxxxxxxxxxxxx",
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(input) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local raw = input:getInputText()
                    local clean, err = Lichess.sanitizeToken(raw)
                    if not clean then
                        UIManager:show(InfoMessage:new{
                            text = _("Invalid token") .. ": " .. tostring(err),
                        })
                        return
                    end
                    self.changes.lichess_token = clean
                    self.account_name = nil
                    self:refreshAccountLabel()
                    self:markDirty()
                    UIManager:close(input)
                end,
            },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function LichessWidget:apiClient()
    if self.changes.lichess_token == "" then return nil, _("No token set.") end
    local ok, detail = Lichess.probeCurl(self:curlPath())
    if not ok then return nil, detail end
    return Lichess.new{ token = self.changes.lichess_token, curl = self:curlPath() }
end

function LichessWidget:curlPath()
    local p = self.parent
    if p and p.getSetting then return p:getSetting("lichess_curl_path", "curl") end
    return "curl"
end

function LichessWidget:testConnection()
    local api, err = self:apiClient()
    if not api then
        UIManager:show(InfoMessage:new{ text = tostring(err) })
        return
    end
    local waiting = InfoMessage:new{ text = _("Contacting Lichess...") }
    UIManager:show(waiting)
    api:request({ path = "/api/account" }, function(ok, data, _code, req_err)
        UIManager:close(waiting)
        if ok and type(data) == "table" and data.id then
            self.account_name = data.username or data.id
            self:refreshAccountLabel()
            UIManager:show(InfoMessage:new{
                text = _("Connected as") .. " " .. self.account_name,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Lichess connection failed") .. ":\n" .. tostring(req_err),
            })
        end
    end)
end

-- ------------------------------------------------------------------ toggles

local function checkbox(label, checked)
    return (checked and "☑ " or "☐ ") .. label
end

function LichessWidget:buildRatedToggle()
    local w = self.dialog.element_width
    local function label()
        return checkbox(_("Rated game"), self.changes.seek_rated)
    end
    self.ratedButton = ButtonWidget:new{
        text = label(),
        width = w,
        radius = Size.radius.button,
        padding = Size.padding.small,
        align = "left",
        callback = function()
            self.changes.seek_rated = not self.changes.seek_rated
            self.ratedButton.text = label()
            self.ratedButton:init()
            self:markDirty()
            UIManager:setDirty(self.dialog, "ui")
        end,
    }
end

function LichessWidget:timeLabelText()
    local m = self.changes.seek_minutes
    local i = self.changes.seek_increment
    if i > 0 then
        return _("Time control") .. string.format(": %d min +%ds", m, i)
    end
    return _("Time control") .. string.format(": %d min", m)
end

function LichessWidget:buildTimeControl()
    local w = self.dialog.element_width
    self.timeLabelWidget = TextWidget:new{
        text = self:timeLabelText(),
        face = Font:getFace("cfont", 20),
    }
    self.timeButton = ButtonWidget:new{
        text = _("Change time control..."),
        width = w,
        radius = Size.radius.button,
        padding = Size.padding.small,
        callback = function()
            local presets = {
                { text = _("Blitz 3+0"), m = 3, i = 0 },
                { text = _("Blitz 3+2"), m = 3, i = 2 },
                { text = _("Blitz 5+0"), m = 5, i = 0 },
                { text = _("Blitz 5+3"), m = 5, i = 3 },
                { text = _("Rapid 10+0"), m = 10, i = 0 },
                { text = _("Rapid 10+5"), m = 10, i = 5 },
                { text = _("Rapid 15+10"), m = 15, i = 10 },
            }
            local buttons = {}
            local chooser
            for _, p in ipairs(presets) do
                table.insert(buttons, {{
                    text = p.text,
                    callback = function()
                        UIManager:close(chooser)
                        self.changes.seek_minutes = p.m
                        self.changes.seek_increment = p.i
                        self.timeLabelWidget:setText(self:timeLabelText())
                        self:markDirty()
                        UIManager:setDirty(self.dialog, "ui")
                    end,
                }})
            end
            table.insert(buttons, {{
                text = _("Cancel"),
                callback = function() UIManager:close(chooser) end,
            }})
            chooser = ButtonDialog:new{
                title = _("Select Time Control"),
                title_align = "center",
                buttons = buttons,
            }
            UIManager:show(chooser)
        end,
    }
    self.timeGroup = VerticalGroup:new{
        width = w,
        self.timeLabelWidget,
        VerticalSpan:new{ width = Size.padding.small },
        self.timeButton,
    }
end

function LichessWidget:buildColorGroup()
    local w = self.dialog.element_width
    self.colorGroup = RadioButtonTable:new{
        width = w,
        radio_buttons = {
            {
                { text = _("Random"), checked = self.changes.seek_color == "random", color = "random" },
                { text = _("White"),  checked = self.changes.seek_color == "white",  color = "white" },
                { text = _("Black"),  checked = self.changes.seek_color == "black",  color = "black" },
            },
        },
        button_select_callback = function(entry)
            self.changes.seek_color = entry.color
            self:markDirty()
        end,
        parent = self.dialog,
    }
end

-- ------------------------------------------------------------------- layout

function LichessWidget:assembleContent()
    local D = self.dialog

    local function centered(widget)
        return CenterContainer:new{
            dimen = Geometry:new{ w = D.width, h = widget:getSize().h },
            widget,
        }
    end

    local group = VerticalGroup:new{
        align = "left",
        D.title_bar,
        VerticalSpan:new{ width = Size.padding.large },
        centered(self.accountGroup),
        VerticalSpan:new{ width = Size.padding.large },
        centered(self.timeGroup),
        VerticalSpan:new{ width = Size.padding.large },
        centered(self.ratedButton),
        VerticalSpan:new{ width = Size.padding.large },
        centered(self.colorGroup),
        VerticalSpan:new{ width = Size.padding.large },
        CenterContainer:new{
            dimen = Geometry:new{
                w = D.title_bar:getSize().w,
                h = D.button_table:getSize().h,
            },
            D.button_table,
        },
        VerticalSpan:new{ width = Size.padding.small },
    }

    local content = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = BACKGROUND_COLOR,
        padding = 0,
        margin = 0,
        group,
    }

    D.movable = MovableContainer:new{ content }
    D[1] = CenterContainer:new{ dimen = Screen:getSize(), D.movable }
end

function LichessWidget:saveAndClose()
    self.onSave(self.changes)
    UIManager:close(self.dialog)
end

return LichessWidget
