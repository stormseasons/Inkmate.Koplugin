local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local Size = require("ui/size")
local Geometry = require("ui/geometry")
-- The eval-bar code added later refers to these two names; they were used
-- without ever being required, so both resolved to nil globals at runtime.
local Geom = Geometry
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local LuaSettings  = require("luasettings")
local util = require("util")
local json = require("json")

pcall(function() util.makePath(DataStorage:getDataDir() .. "/icons") end)

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TitleBarWidget = require("ui/widget/titlebar")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ButtonWidget    = require("ui/widget/button")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local HorizontalGroup = require("ui/widget/horizontalgroup") 
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local MovableContainer = require("ui/widget/container/movablecontainer")
local TextWidget = require("ui/widget/textwidget")
local InputText = require("ui/widget/inputtext")
local PathChooser = require("ui/widget/pathchooser")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ConfirmBox = require("ui/widget/confirmbox")

local Chess = require("chessgame")
local ChessBoard = require("chessboard")
local CheckersGame = require("checkersgame")
local CheckersBoard = require("checkersboard")
local CheckersAI = require("checkersai")
local FoxHoundGame = require("foxhoundgame")
local FoxHoundBoard = require("foxhoundboard")
local FoxHoundAI = require("foxhoundai")
local ReversiGame = require("reversigame")
local ReversiBoard = require("reversiboard")
local ReversiAI = require("reversiai")
local Timer = require("timer")
local Uci = require("uci")
local GoldfishUCI = require("goldfishuci")
local LichessBackend = require("lichessbackend")
local Lichess = require("lichess")
local SettingsWidget = require("settingswidget")
local Weakening = require("weakening")
local _ = require("gettext")
local StartMenu = require("startmenu")
local Puzzle = require("puzzle")
-- KOReader renamed this widget; support both spellings.
local ButtonDialog = (pcall(require, "ui/widget/buttondialog")
        and require("ui/widget/buttondialog"))
    or require("ui/widget/buttondialogtitle")

local function getPluginPath()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    local path = src:match("^(.*[/\\])main%.lua$") or "."

    return path
end

local function normalizePath(path)
    path = (path or ""):gsub("\\", "/")
    return path:gsub("/+", "/")
end

local function joinPath(...)
    local parts = {...}
    local path = tostring(parts[1] or "")
    for i = 2, #parts do
        local part = tostring(parts[i] or "")
        path = path:gsub("/+$", "") .. "/" .. part:gsub("^/+", "")
    end
    return normalizePath(path)
end

local PLUGIN_PATH = normalizePath(getPluginPath()):gsub("/+$", "")

local ENGINES_DIR = joinPath(PLUGIN_PATH, "engines")

local function fileExists(path)
    local ok = lfs.attributes(path, "mode")
    return ok == "file"
end

local function chmodX(path)
    os.execute('chmod +x "' .. path .. '"')
end

local function getEnginePath()
    local path = joinPath(ENGINES_DIR, "stockfish")

    if fileExists(path) then
        chmodX(path)
        return path
    end

    return nil
end

local UCI_ENGINE_PATH = getEnginePath()
local GAMES_PATH = joinPath(PLUGIN_PATH, "Games")

local BACKGROUND_COLOR = Blitbuffer.COLOR_WHITE
local PGN_LOG_FONT = "smallinfofont"
local PGN_LOG_FONT_SIZE = 14
local TOOLBAR_PADDING = 4
local MODE_CHESS = "chess"
local MODE_CHECKERS = "checkers"
local MODE_FOXHOUND = "foxhound"
local MODE_REVERSI = "reversi"

local Kochess = FrameContainer:extend{
    name = "inkmate",
    covers_fullscreen = true,
    background = BACKGROUND_COLOR,
    bordersize = 0,
    padding = 0,
    full_width = Screen:getWidth(),
    full_height = Screen:getHeight(),
    notation_font = PGN_LOG_FONT,
    notation_size = PGN_LOG_FONT_SIZE,
    game = nil, timer = nil, engine = nil, board = nil,
    pgn_log = nil, status_bar = nil, running = false,
    _thinking_visible = false,
}

function Kochess:paintTo(bb, x, y)
    -- Clear the entire screen before drawing to prevent old pixels from lingering
    bb:paintRect(0, 0, Screen:getWidth(), Screen:getHeight(), Blitbuffer.COLOR_WHITE)
    FrameContainer.paintTo(self, bb, x, y)
end

function Kochess:onInkMateStart()
    -- Store callbacks on self so they survive LichessDashboard → StartMenu
    -- round-trips: goBack() creates a bare StartMenu{ parent = self }, and the
    -- StartMenu pulls these callbacks from parent when they aren't passed in
    -- directly.
    self._start_onPlayOffline = function()
        self:setSetting("play_online", false)
        self:startGame()
    end
    self._start_onPromptToken = function()
        self:promptLichessTokenAndStart()
    end
    self._start_onOptions = function()
        require("optionsmenu"):new{
            engine = self.engine,
            timer = self.timer,
            game = self.game,
            parent = self,
            -- Repaint whatever sits underneath when the options screen closes.
            on_close = function()
                UIManager:setDirty("all", "ui")
            end,
        }:show()
    end

    local menu = StartMenu:new{
        parent = self,
        onPlayOffline = self._start_onPlayOffline,
        onPromptToken = self._start_onPromptToken,
        onOptions = self._start_onOptions,
    }
    UIManager:show(menu)
    return true
end

function Kochess:onCloseWidget()
    if self.board then
        self.board:clearValidMoves()
    end
    if self.timer then
        self.timer:stop()
    end
    self:shutdownEngine()
end

function Kochess:handleEvent(event)
    -- Dispatcher can launch the game while this widget is not on the stack.
    if event.handler == "onInkMateStart" then
        return self:onInkMateStart()
    end
    -- FileManager can still propagate child events after UIManager:close().
    local on_stack = false
    for i = #UIManager._window_stack, 1, -1 do
        if UIManager._window_stack[i].widget == self then
            on_stack = true
            break
        end
    end
    if not on_stack then return false end
    return FrameContainer.handleEvent(self, event)
end

function Kochess:init()
    self.dimensions = Geometry:new{ w = self.full_width, h = self.full_height }
    self.covers_fullscreen = true
    Dispatcher:registerAction("inkmate", {
        category = "none", event = "InkMateStart", title = _("InkMate"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
    self:installIconsIfNeeded()
    local path = DataStorage:getSettingsDir() .. "/inkmate.lua"
    self.settings = LuaSettings:open(path)
end

function Kochess:saveSettings()
    self.settings:flush()
end

function Kochess:getSetting(key, default)
    return self.settings:readSetting(key, default)
end

function Kochess:setSetting(key, value)
    self.settings:saveSetting(key, value)
    self:saveSettings()
end

function Kochess:getEngineStatusText()
    if self:isLichessMode() then
        if self.engine and self.engine.state and self.engine.state.uciok then
            return "Connected to Lichess game " .. tostring(self.engine.game_id)
        end
        return self.engine_status_text
            or self.engine_last_output
            or "Connecting to Lichess..."
    end
    if self.goldfish_active then
        local text = "Goldfish Lua fallback is active."
        if self.engine_status_text and self.engine_status_text ~= "" then
            text = text .. "\n\nStockfish diagnostic:\n" .. self.engine_status_text
        end
        return text
    end
    if not UCI_ENGINE_PATH then
        return "Stockfish engine not found.\nCopy the engine binary to:\n" .. ENGINES_DIR .. "/"
    end
    if self.engine and self.engine.state and self.engine.state.uciok then
        return "Stockfish engine is ready."
    end

    local text = "Stockfish engine is not ready.\nPath:\n" .. UCI_ENGINE_PATH
    local detail = self.engine_status_text
        or self.engine_last_output
        or (self.engine and self.engine.state and (self.engine.state.last_error or self.engine.state.last_output))
    if detail and detail ~= "" then
        text = text .. "\n\nLast engine output:\n" .. detail
    end
    return text
end

function Kochess:switchToHumanVsHuman()
    self.human_white = true
    self.human_black = true
    if self.game then
        self.game.set_human(Chess.WHITE, true)
        self.game.set_human(Chess.BLACK, true)
    end
    self:setSetting("human_white", true)
    self:setSetting("human_black", true)
    if self.status_bar then
        self:updatePlayerDisplay()
    end
    self:updateBoardOrientation()
end

function Kochess:markEngineInvalid(reason)
    self.engine_status_text = reason or "Stockfish engine is not ready."
    if self:isChessMode() then
        self:startGoldfishFallback()
    else
        self:switchToHumanVsHuman()
    end
end

function Kochess:installIconsIfNeeded()
    local data_dir = DataStorage:getDataDir()
    local dest_dir = data_dir .. "/icons/casualchess"
    local src_dir  = joinPath(PLUGIN_PATH, "icons")
    if lfs.attributes(src_dir, "mode") ~= "directory" then return end
    util.makePath(dest_dir)
    for entry in lfs.dir(src_dir) do
        if entry:match("%.svg$") then
            local dest_file = dest_dir .. "/" .. entry
            if lfs.attributes(dest_file, "mode") ~= "file" then
                os.execute('cp "' .. joinPath(src_dir, entry) .. '" "' .. dest_file .. '"')
            end
        end
    end
end

function Kochess:addToMainMenu(menu_items)
    menu_items.inkmate = {
        text = _("InkMate"), sorting_hint = "tools", callback = function() self:onInkMateStart() end, keep_menu_open = false,
    }
end

Kochess.addToFileManagerMenu = Kochess.addToMainMenu

function Kochess:promptLichessTokenAndStart()
    local dialog
    dialog = InputDialog:new{
        title       = _("Lichess API Token"),
        description = _("To play online, create a token at lichess.org/account/oauth/token with 'Read incoming challenges' and 'Create/accept/decline challenges' scopes."),
        input       = "",
        input_hint  = "lip_xxxxxxxxxxxxxxxx",
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save & Play"),
                is_enter_default = true,
                callback = function()
                    local token, err = Lichess.sanitizeToken(dialog:getInputText())
                    if not token then
                        UIManager:show(InfoMessage:new{
                            text = _("That does not look like a Lichess token") ..
                                   ":\n" .. tostring(err) ..
                                   "\n\n" .. _("It should start with lip_"),
                        })
                        return
                    end
                    self:setSetting("lichess_token", token)
                    -- The dashboard's Play button sets this; without it, saving a
                    -- token here started an offline game against Stockfish.
                    self:setSetting("play_online", true)
                    self:setSetting("game_mode", "chess")
                    UIManager:close(dialog)
                    self:startGame()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Kochess:startPuzzleGame(fen, solution, first_is_opp)
    -- Deliberately NOT persisted: isLichessMode() requires game_mode == "chess",
    -- so saving "puzzle" would silently disable online play after one puzzle.
    self.game_mode = "puzzle"
    self.human_white = true
    self.human_black = true
    self.game = Chess:new()
    self.game.load(fen)
    self.current_puzzle = Puzzle.new(fen, solution, first_is_opp)
    
    if first_is_opp then
        local m = self.current_puzzle:getNextExpectedMove()
        if m then
            self.current_puzzle:advance()
            local r_move = self.game.move_from_uci(m)
            self.game.move(r_move)
        end
    end
    
    if UIManager.isWidgetShown and UIManager:isWidgetShown(self) then
        UIManager:close(self)
    end
    
    self.timer = Timer:new(
        {[Chess.WHITE]=0, [Chess.BLACK]=0},
        {[Chess.WHITE]=0, [Chess.BLACK]=0},
        function() end
    )
    self:initializeBoard()
    self:buildUILayout()
    self.board:updateBoard()
    UIManager:show(self)
end

function Kochess:startPuzzle(online)
    if not online then
        -- Load offline puzzle from puzzles.csv
        local path = joinPath(PLUGIN_PATH, "puzzles.csv")
        local f = io.open(path, "r")
        if not f then
            UIManager:show(require("startmenu"):new{ parent = self })
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Offline puzzles not found.\n\nPlease place a 'puzzles.csv' file in the plugin folder.")
            })
            return
        end
        local content = f:read("*a")
        f:close()
        
        local lines = {}
        for line in content:gmatch("[^\r\n]+") do
            table.insert(lines, line)
        end
        if #lines < 2 then return end -- header + 1 puzzle
        
        local target_idx = math.random(2, #lines)
        local parts = {}
        for part in lines[target_idx]:gmatch("[^,]+") do
            table.insert(parts, part)
        end
        
        if #parts >= 3 then
            local fen = parts[2]
            local moves = parts[3]
            self:startPuzzleGame(fen, moves, true)
        end
    else
        -- Load online puzzle from Lichess Daily API
        local UIManager = require("ui/uimanager")
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Fetching daily puzzle...") })
        
        local Lichess = require("lichess")
        local api = Lichess.new{ 
            curl = self:getSetting("lichess_curl_path", "curl"),
            token = self:getSetting("lichess_token", "")
        }
        api:request({ path = "/api/puzzle/daily" }, function(ok, data, code, err)
            -- close info message? Actually infomessage has no easy close handle if not kept,
            -- but let's just proceed to show board which will cover it or we can ignore it.
            if ok and data and data.puzzle and data.puzzle.fen and data.puzzle.solution then
                local fen = data.puzzle.fen
                local solution = data.puzzle.solution
                self:startPuzzleGame(fen, solution, false)
            else
                UIManager:show(require("startmenu"):new{ parent = self })
                UIManager:show(require("ui/widget/infomessage"):new{ text = _("Failed to fetch daily puzzle.") })
            end
        end)
    end
end

function Kochess:startGame()
    self.last_cp = nil
    self.last_mate = nil
    self.eval_turn = nil

    if UIManager.isWidgetShown and UIManager:isWidgetShown(self) then
        UIManager:close(self)
    end

    self.game_mode = self:getSetting("game_mode", MODE_CHESS)
    self:loadEngineSettings()
    self:initializeGameLogic()
    if self:isChessMode() then
        self:initializeEngine()
        self:loadOpenings()
    else
        self:shutdownEngine()
    end
    self:buildUILayout()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
    self:restoreGameState()
    self.board:updateBoard()
    UIManager:show(self)
    self:launchCurrentComputerMove()
end

function Kochess:isChessMode()
    return self.game_mode ~= MODE_CHECKERS and self.game_mode ~= MODE_FOXHOUND and self.game_mode ~= MODE_REVERSI
end

--- Online play is chess-only, and is a property of the opponent, not the board.
function Kochess:isLichessMode()
    return self.game_mode == MODE_CHESS and self:getSetting("play_online", false) == true
end

function Kochess:isCheckersMode()
    return self.game_mode == MODE_CHECKERS
end

function Kochess:isFoxHoundMode()
    return self.game_mode == MODE_FOXHOUND
end

function Kochess:isReversiMode()
    return self.game_mode == MODE_REVERSI
end

function Kochess:saveGameState()
    if self:isReversiMode() then
        self:saveReversiGameState()
        return
    end
    if self:isFoxHoundMode() then
        self:saveFoxHoundGameState()
        return
    end
    if self:isCheckersMode() then
        self:saveCheckersGameState()
        return
    end
    if self:isLichessMode() then
        -- Lichess owns the game record; we re-attach by id and resync from the
        -- stream instead of replaying a snapshot that may already be stale.
        self:setSetting("saved_pgn", "")
        self:setSetting("saved_running", false)
        return
    end
    local pgn = self.game.pgn and self.game.pgn() or ""
    self:setSetting("saved_pgn", pgn)
    self:setSetting("saved_time_white", self.timer:getRemainingTime(Chess.WHITE))
    self:setSetting("saved_time_black", self.timer:getRemainingTime(Chess.BLACK))
    self:setSetting("saved_running", self.running)
end

function Kochess:clearSavedGameStates()
    self:setSetting("saved_pgn", "")
    self:setSetting("saved_running", false)
    self:setSetting("saved_checkers_state", "")
    self:setSetting("saved_checkers_running", false)
    self:setSetting("saved_foxhound_state", "")
    self:setSetting("saved_foxhound_running", false)
    self:setSetting("saved_reversi_state", "")
    self:setSetting("saved_reversi_running", false)
end

function Kochess:restoreGameState()
    if self:isReversiMode() then
        self:restoreReversiGameState()
        return
    end
    if self:isFoxHoundMode() then
        self:restoreFoxHoundGameState()
        return
    end
    if self:isCheckersMode() then
        self:restoreCheckersGameState()
        return
    end
    if self:isLichessMode() then return end
    local pgn = self:getSetting("saved_pgn", "")
    if not pgn or pgn == "" then return end

    local ok = pcall(function() self.game.load_pgn(pgn) end)
    if not ok then
        self:setSetting("saved_pgn", "")
        return
    end

    local tw = self:getSetting("saved_time_white", nil)
    local tb = self:getSetting("saved_time_black", nil)
    if tw then self.timer.time[Chess.WHITE] = tw end
    if tb then self.timer.time[Chess.BLACK] = tb end

    self.timer.currentPlayer = self.game.turn()
    self.running = self:getSetting("saved_running", false)

    if self.engine and self.engine.state.uciok then
        self.engine.send("ucinewgame")
        local moves = {}
        for _, m in ipairs(self.game.history({ verbose = true })) do
            moves[#moves+1] = m.from .. m.to .. (m.promotion or "")
        end
        if #moves > 0 then
            self.engine:position({ moves = table.concat(moves, " ") })
        end
    end

    self:updatePgnLog()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
end

function Kochess:saveCheckersGameState()
    if not (self.game and self.game.export_state) then return end
    self:setSetting("saved_checkers_state", self.game:export_state())
    self:setSetting("saved_checkers_time_white", self.timer:getRemainingTime(Chess.WHITE))
    self:setSetting("saved_checkers_time_black", self.timer:getRemainingTime(Chess.BLACK))
    self:setSetting("saved_checkers_running", self.running)
end

function Kochess:restoreCheckersGameState()
    local state = self:getSetting("saved_checkers_state", nil)
    if type(state) ~= "table" then return end

    local ok = self.game.load_state and self.game:load_state(state)
    if not ok then
        self:setSetting("saved_checkers_state", "")
        return
    end

    local tw = self:getSetting("saved_checkers_time_white", nil)
    local tb = self:getSetting("saved_checkers_time_black", nil)
    if tw then self.timer.time[Chess.WHITE] = tw end
    if tb then self.timer.time[Chess.BLACK] = tb end

    self.timer.currentPlayer = self.game.turn()
    self.running = self:getSetting("saved_checkers_running", false)

    self:updatePgnLog()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
end

function Kochess:saveFoxHoundGameState()
    if not (self.game and self.game.export_state) then return end
    self:setSetting("saved_foxhound_state", self.game:export_state())
    self:setSetting("saved_foxhound_time_white", self.timer:getRemainingTime(Chess.WHITE))
    self:setSetting("saved_foxhound_time_black", self.timer:getRemainingTime(Chess.BLACK))
    self:setSetting("saved_foxhound_running", self.running)
end

function Kochess:restoreFoxHoundGameState()
    local state = self:getSetting("saved_foxhound_state", nil)
    if type(state) ~= "table" then return end

    local ok = self.game.load_state and self.game:load_state(state)
    if not ok then
        self:setSetting("saved_foxhound_state", "")
        return
    end

    local tw = self:getSetting("saved_foxhound_time_white", nil)
    local tb = self:getSetting("saved_foxhound_time_black", nil)
    if tw then self.timer.time[Chess.WHITE] = tw end
    if tb then self.timer.time[Chess.BLACK] = tb end

    self.timer.currentPlayer = self.game.turn()
    self.running = self:getSetting("saved_foxhound_running", false)

    self:updatePgnLog()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
end

function Kochess:saveReversiGameState()
    if not (self.game and self.game.export_state) then return end
    self:setSetting("saved_reversi_state", self.game:export_state())
    self:setSetting("saved_reversi_time_white", self.timer:getRemainingTime(Chess.WHITE))
    self:setSetting("saved_reversi_time_black", self.timer:getRemainingTime(Chess.BLACK))
    self:setSetting("saved_reversi_running", self.running)
end

function Kochess:restoreReversiGameState()
    local state = self:getSetting("saved_reversi_state", nil)
    if type(state) ~= "table" then return end

    local ok = self.game.load_state and self.game:load_state(state)
    if not ok then
        self:setSetting("saved_reversi_state", "")
        return
    end

    local tw = self:getSetting("saved_reversi_time_white", nil)
    local tb = self:getSetting("saved_reversi_time_black", nil)
    if tw then self.timer.time[Chess.WHITE] = tw end
    if tb then self.timer.time[Chess.BLACK] = tb end

    self.timer.currentPlayer = self.game.turn()
    self.running = self:getSetting("saved_reversi_running", false)

    self:updatePgnLog()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
end

function Kochess:loadOpenings()
    if not self:isChessMode() then return end
    if self.openings then return end

    self.openings = {}
    local path = joinPath(PLUGIN_PATH, "data/aperturas.json")

    local f = io.open(path, "r")
    if not f then

        return
    end

    local content = f:read("*all")
    f:close()

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then

        return
    end

    self.openings = data

end

function Kochess:startGoldfishFallback()
    if self.goldfish_active then return end

    local stockfish_status = self.engine_status_text
    if self.engine and not self.engine.closed then
        pcall(function() self.engine:quit() end)
    end

    self.engine_busy = false
    self.goldfish_active = true
    self.engine = GoldfishUCI.new()
    local engine = self.engine
    self.engine_status_text = stockfish_status
    self.engine_last_output = "Goldfish Lua fallback is active."

    engine:on("read", function(data)
        if self.engine ~= engine then return end
        if data then
            for line in tostring(data):gmatch("[^\r\n]+") do
                self.engine_last_output = line
            end
        end
    end)

    engine:on("uciok", function()
        if self.engine ~= engine then return end
        engine.send("setoption name Skill Level value " .. tostring(self.current_skill or 0))
        engine:ucinewgame()
        engine.send("isready")
        if not self:getSetting("saved_pgn", "") or self:getSetting("saved_pgn", "") == "" then
            self:updatePgnLogInitialText()
        end
        UIManager:setDirty(self, "ui")
        if self.game and not self.game.is_human(self.game.turn()) then
            UIManager:nextTick(function() self:launchCurrentComputerMove() end)
        end
    end)

    engine:on("bestmove", function(move_uci)
        if self.engine ~= engine then return end
        self.engine_busy = false
        self:stopThinkingIndicator()
        if not self.game.is_human(self.game.turn()) then
            self:uciMove(move_uci)
        end
    end)

    engine:uci()
end

function Kochess:loadEngineSettings()
    local defaults = {
        skill_level     = 0,
        engine_depth    = 2,
        engine_movetime = 1,
        blunder_chance  = 0.20,
    }

    for key, value in pairs(defaults) do
        if self.settings:readSetting(key) == nil then
            self:setSetting(key, value)
        end
    end

    self.current_skill = self:getSetting("skill_level", defaults.skill_level)
    local d = tonumber(self:getSetting("engine_depth", defaults.engine_depth)) or defaults.engine_depth
    self.engine_depth = (d >= 1 and d <= 5) and d or 0
    self.engine_movetime = math.max(1, math.min(10, tonumber(self:getSetting("engine_movetime", defaults.engine_movetime)) or defaults.engine_movetime))
    self.blunder_chance = math.max(0, math.min(1, tonumber(self:getSetting("blunder_chance", defaults.blunder_chance)) or defaults.blunder_chance))
    if self.weakening then
        self.weakening:setChance(self.blunder_chance)
    end
end

function Kochess:lichessSeekSettings()
    return {
        minutes   = tonumber(self:getSetting("seek_minutes", 10)) or 10,
        increment = tonumber(self:getSetting("seek_increment", 0)) or 0,
        rated     = self:getSetting("seek_rated", false) == true,
        color     = self:getSetting("seek_color", "random"),
    }
end

--- Online play is chess-only, and is a property of the opponent, not the board.
function Kochess:resyncFromServer(initial_fen, moves)
    if not (self.game and self.board) then return end
    self:stopUCI()
    self._lichess_browse_depth = 0

    self.game.reset()
    if initial_fen and initial_fen ~= "" then
        pcall(function() self.game.load(initial_fen) end)
    end
    self.game.initial_fen = self.game.fen and self.game.fen() or nil

    for _, uci in ipairs(moves or {}) do
        if #uci >= 4 then
            self.game.move{
                from = uci:sub(1, 2),
                to   = uci:sub(3, 4),
                promotion = (#uci >= 5) and uci:sub(5, 5) or nil,
            }
        end
    end

    self.board:clearValidMoves()
    self.board:clearPreviousMoveHints()
    self.board:clearCheckHint()
    self.board:updateBoard()

    -- launchCurrentComputerMove only starts the clock when it is the opponent to
    -- move, so mark the game live here too or our own turn shows as paused.
    self.running = true
    self.timer.currentPlayer = self.game.turn()
    self.timer:start()
    self:updatePgnLog()
    self:updateTimerDisplay()
    self:updatePlayerDisplay()
    UIManager:setDirty(self, "ui")

    self:launchCurrentComputerMove()
end

function Kochess:initializeLichess()
    self.goldfish_active = false
    self.engine_status_text = nil
    self.engine_last_output = nil
    self.last_cp = nil
    self.last_mate = nil

    local token = self:getSetting("lichess_token", "")
    if not token or token == "" then
        self.engine_status_text =
            "No Lichess token configured.\nOpen Settings and choose \"Play on Lichess...\"."
        UIManager:show(InfoMessage:new{
            text = _("Set a Lichess API token in Settings before playing online."),
        })
        return
    end

    local game_id = self:getSetting("lichess_game_id", "")
    if game_id == "" then game_id = nil end

    local backend = LichessBackend.new{
        token   = token,
        curl    = self:getSetting("lichess_curl_path", "curl"),
        game_id = game_id,
        seek    = (not game_id) and self:lichessSeekSettings() or nil,
    }
    self.engine = backend
    self.engine_busy = false

    backend:on("read", function(line)
        if self.engine ~= backend then return end
        self.engine_last_output = line
    end)

    backend:on("waiting_for_opponent", function()
        if self.engine ~= backend then return end
        if self.status_bar then
            self.status_bar:setSubTitle(_("Seeking an opponent..."))
            UIManager:setDirty(self.status_bar, "ui")
        end
    end)

    backend:on("game_started", function(info)
        if self.engine ~= backend then return end
        self.lichess_color = info.my_color
        self.lichess_opponent = info.opponent_name
        self:setSetting("lichess_game_id", info.game_id)
        self:setSetting("lichess_my_color", info.my_color)

        local i_am_white = (info.my_color == "white")
        self.game.set_human(Chess.WHITE, i_am_white)
        self.game.set_human(Chess.BLACK, not i_am_white)
        self:updateBoardOrientation()
        self:updatePlayerDisplay()
        UIManager:setDirty(self, "ui")
    end)

    backend:on("resync", function(initial_fen, moves)
        if self.engine ~= backend then return end
        self:resyncFromServer(initial_fen, moves)
    end)

    backend:on("clock", function(white_s, black_s)
        if self.engine ~= backend then return end
        self.timer:setRemaining(Chess.WHITE, white_s)
        self.timer:setRemaining(Chess.BLACK, black_s)
        self:updateTimerDisplay()
    end)

    backend:on("uciok", function()
        if self.engine ~= backend then return end
        self:updatePgnLogInitialText()
        UIManager:setDirty(self, "ui")
    end)

    backend:on("bestmove", function(move_uci)
        if self.engine ~= backend then return end
        -- If the user was browsing history, snap back to the latest position
        -- before applying the opponent's move.
        if (self._lichess_browse_depth or 0) > 0 then
            while self.game.redo() do end
            self._lichess_browse_depth = 0
            self.board:updateBoard()
        end
        self.engine_busy = false
        self:stopThinkingIndicator()
        if not self.game.is_human(self.game.turn()) then
            self:uciMove(move_uci)
        end
    end)

    backend:on("move_rejected", function(uci, err)
        if self.engine ~= backend then return end
        -- Our board ran ahead of the real game; take the move back.
        self.engine_busy = false
        self:stopThinkingIndicator()
        self.game.undo()
        self.board:clearValidMoves()
        self.board:updateBoard()
        self:updatePgnLog()
        self:updatePlayerDisplay()
        UIManager:setDirty(self, "ui")
        UIManager:show(InfoMessage:new{
            text = _("Lichess rejected the move") .. " " .. tostring(uci) .. ":\n" .. tostring(err),
        })
    end)

    backend:on("game_over", function(status, winner)
        if self.engine ~= backend then return end
        self:setSetting("lichess_game_id", "")
        self:showLichessGameOver(status, winner)
    end)

    backend:on("net_error", function(msg)
        if self.engine ~= backend then return end
        self.engine_status_text = msg
        self.engine_busy = false
        self:stopThinkingIndicator()
        UIManager:show(InfoMessage:new{ text = tostring(msg) })
    end)

    backend:on("draw_offer_received", function()
        if self.engine ~= backend then return end
        UIManager:show(ConfirmBox:new{
            text = _("Your opponent offers a draw. Accept?"),
            ok_text = _("Accept draw"),
            cancel_text = _("Decline"),
            ok_callback = function()
                backend:offerDraw(true, function(ok, _, _, err)
                    if not ok then
                        UIManager:show(InfoMessage:new{
                            text = _("Accept draw failed") .. ": " .. tostring(err),
                        })
                    end
                end)
            end,
            cancel_callback = function()
                backend:offerDraw(false)
            end,
        })
    end)

    backend:on("takeback_offer_received", function()
        if self.engine ~= backend then return end
        UIManager:show(ConfirmBox:new{
            text = _("Your opponent proposes a takeback. Accept?"),
            ok_text = _("Accept"),
            cancel_text = _("Decline"),
            ok_callback = function()
                backend:takeback(true, function(ok, _, _, err)
                    if not ok then
                        UIManager:show(InfoMessage:new{
                            text = _("Accept takeback failed") .. ": " .. tostring(err),
                        })
                    end
                end)
            end,
            cancel_callback = function()
                backend:takeback(false)
            end,
        })
    end)

    local function start()
        if self.engine ~= backend or backend.closed then return end
        backend:uci()
    end

    local ok = pcall(function()
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:runWhenOnline(start)
    end)
    if not ok then start() end
end

local LICHESS_STATUS_TEXT = {
    mate          = _("Checkmate!"),
    resign        = _("Resigned."),
    outoftime     = _("Out of time."),
    timeout       = _("Opponent left the game."),
    stalemate     = _("Draw! Stalemate."),
    draw          = _("Draw."),
    aborted       = _("Game aborted."),
    nostart       = _("Game aborted: opponent never started."),
    cheat         = _("Game ended: cheat detected."),
    unknownfinish = _("Game over."),
}

function Kochess:showLichessGameOver(status, winner)
    self:stopThinkingIndicator()
    self:stopUCI()
    self.timer:stop()
    self.running = false
    self:updateTimerDisplay()

    local text = LICHESS_STATUS_TEXT[status] or _("Game over.")
    if winner then
        local won = (winner == self.lichess_color)
        text = text .. "\n" .. (won and _("You win!") or _("You lose."))
    end

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Continue"),
        cancel_text = nil,
        ok_callback = function()
            -- The finished game is gone; the next online game needs a fresh seek.
            self:setSetting("lichess_game_id", "")
            self:shutdownEngine()
            self.game.reset()
            self.board:clearValidMoves()
            self.board:clearPreviousMoveHints()
            self.board:clearCheckHint()
            self.board:updateBoard()
            self:updatePgnLogInitialText()
            self:updateTimerDisplay()
            self:updatePlayerDisplay()
            UIManager:setDirty(self, "ui")
        end,
    })
end

function Kochess:initializeEngine()
    if not self:isChessMode() then return end
    self:loadEngineSettings()
    if self:isLichessMode() then
        self:initializeLichess()
        return
    end
    local defaultSkill = self.current_skill or 0
    self.human_white = self:getSetting("human_white", true)
    self.human_black = self:getSetting("human_black", false)
    self.last_cp = nil
    self.engine_status_text = nil
    self.engine_last_output = nil
    self.goldfish_active = false

    if self:getSetting("force_goldfish", false) then
        self.engine_status_text = "Goldfish forced for testing."
        self:startGoldfishFallback()
        return
    end

    if not UCI_ENGINE_PATH then
        self:markEngineInvalid("Stockfish engine not found.")
        return
    end

    self.engine = Uci.UCIEngine.spawn(UCI_ENGINE_PATH, {})
    local engine = self.engine

    
    if not engine then

        self:markEngineInvalid("Engine process could not be created.")
        return
    end

    engine:on("read", function(data)
        if self.engine ~= engine then return end
        if data then
            for line in tostring(data):gmatch("[^\r\n]+") do
                self.engine_last_output = line
                if line:match("execvp failed") then
                    self:markEngineInvalid(line)
                end
                if line:match("^info ") then
                    local mp = tonumber(line:match(" multipv (%d+)")) or 1
                    if mp == 1 then
                        local cp = line:match(" score cp (-?%d+)")
                        local mate = line:match(" score mate (-?%d+)")
                        if mate then
                            local mv = tonumber(mate)
                            if self.eval_turn == Chess.BLACK then mv = -mv end
                            self.last_mate = mv
                            self.last_cp = nil

                        elseif cp then
                            local cpv = tonumber(cp)
                            if self.eval_turn == Chess.BLACK then cpv = -cpv end
                            self.last_cp = cpv
                            self.last_mate = nil
                        end
                    end
                end
            end
        end
    end)

    engine:on("uciok", function()
        if self.engine ~= engine then return end
        self.engine_status_text = nil

        if not self:getSetting("saved_pgn", "") or self:getSetting("saved_pgn", "") == "" then
            self:updatePgnLogInitialText()
        end

        engine.send("setoption name Hash value 8")
        engine.send("setoption name Threads value 1")
        engine.send("setoption name Skill Level value " .. defaultSkill)
        engine.send("setoption name Move Overhead value 150")
        engine.send("setoption name Ponder value false")
        engine.send("setoption name Slow Mover value 90")
        self.current_skill = defaultSkill

        engine:ucinewgame()

        -- Restored computer-vs-computer games can resume once UCI is ready.
        local is_cvc = not self.game.is_human(Chess.WHITE) and not self.game.is_human(Chess.BLACK)
        if is_cvc and self.running then
            local moves = {}
            for _, m in ipairs(self.game.history({ verbose = true })) do
                moves[#moves+1] = m.from .. m.to .. (m.promotion or "")
            end
            if #moves > 0 then
                engine:position({ moves = table.concat(moves, " ") })
            end
            engine.send("isready")
            self:launchNextMove()
        else
            engine.send("isready")
        end

        UIManager:setDirty(self, "ui")
        if self.game and not self.game.is_human(self.game.turn()) then
            UIManager:nextTick(function() self:launchCurrentComputerMove() end)
        end
    end)

    engine:on("bestmove", function(move_uci)
        if self.engine ~= engine then return end
        self.engine_busy = false
        self:stopThinkingIndicator()

        if not self.game.is_human(self.game.turn()) then
            self:uciMove(move_uci)
        end
    end)

    engine:on("process_error", function(err)
        if self.engine ~= engine then return end
        self.engine_busy = false
        self:markEngineInvalid(err or "Stockfish engine process failed.")
    end)

    engine:on("uci_timeout", function(last_output)
        if self.engine ~= engine then return end
        local text = "Timed out waiting for Stockfish UCI response."
        if last_output and last_output ~= "" then
            text = text .. "\n" .. last_output
        end
        self:markEngineInvalid(text)
    end)

    engine:on("go_timeout", function(last_output)
        if self.engine ~= engine then return end
        self.engine_busy = false
        local text = "Timed out waiting for Stockfish bestmove."
        if last_output and last_output ~= "" then
            text = text .. "\n" .. last_output
        end
        self:markEngineInvalid(text)
    end)
    
    engine:uci()
end

function Kochess:initializeGameLogic()
    if self:isReversiMode() then
        self.game = ReversiGame:new()
    elseif self:isFoxHoundMode() then
        self.game = FoxHoundGame:new()
    elseif self:isCheckersMode() then
        self.game = CheckersGame:new()
    else
        self.game = Chess:new()
    end
    self.game.reset()
    self.game.initial_fen = self.game.fen and self.game.fen() or nil
    local human_white = self:getSetting("human_white", true)
    local human_black = self:getSetting("human_black", false)
    if self:isLichessMode() then
        -- Provisional until gameFull tells us which colour Lichess dealt us; it
        -- keeps the board the right way up across a restart.
        self.lichess_color = self:getSetting("lichess_my_color", "white")
        local i_am_white = self.lichess_color ~= "black"
        human_white = i_am_white
        human_black = not i_am_white
    end
    self.game.set_human(Chess.WHITE, human_white)
    self.game.set_human(Chess.BLACK, human_black)
    local base_w = self:getSetting("time_base_white", 900)
    local base_b = self:getSetting("time_base_black", 900)
    local incr_w = self:getSetting("time_incr_white", 10)
    local incr_b = self:getSetting("time_incr_black", 10)
    self.timer = Timer:new(
        {[Chess.WHITE]=base_w, [Chess.BLACK]=base_b},
        {[Chess.WHITE]=incr_w, [Chess.BLACK]=incr_b},
        function() self:updateTimerDisplay() end)
    self.running = false
    if self:isChessMode() then
        self.weakening = Weakening:new(self.game, self.blunder_chance or 0.0)
    else
        self.weakening = nil
    end
end

function Kochess:initializeBoard(board_h)
    -- Move hints are hidden online: the approved policy is no assistance during a
    -- Lichess game.
    local online = self:isLichessMode()
    local BoardClass = self:isReversiMode() and ReversiBoard
        or (self:isFoxHoundMode() and FoxHoundBoard)
        or (self:isCheckersMode() and CheckersBoard or ChessBoard)
    self.board = BoardClass:new{
        game          = self.game,
        width         = self.full_width,
        height        = board_h or math.floor(0.7 * self.full_height),
        moveCallback  = function(move) self:onMoveExecuted(move) end,
        onPromotionNeeded = function(f, t, c) self:openPromotionDialog(f, t, c) end,
        learning_mode = not online and self:getSetting("learning_mode", false) or false,
        show_selected = self:getSetting("show_selected", true),
        previous_move_hints = self:getSetting("previous_move_hints", false),
        opponent_hints = not online and self:getSetting("opponent_hints", false) or false,
        check_hints = self:getSetting("check_hints", false),
        flipped = self:shouldFlipBoard(),
        rotate_top_pieces = self:getSetting("rotate_top_pieces", false),
    }
end

function Kochess:shouldFlipBoard()
    -- Online, the board follows the colour Lichess dealt us.
    if self:isLichessMode() and self.lichess_color then
        return self.lichess_color == "black"
    end
    return self.game
       and self.game.is_human(Chess.BLACK)
       and not self.game.is_human(Chess.WHITE)
end

function Kochess:updateBoardOrientation()
    if not self.board then return end
    self.board:setFlipped(self:shouldFlipBoard())
    self.board:setRotateTopPieces(self:getSetting("rotate_top_pieces", false))
end

function Kochess:buildUILayout()
    local status_bar = self:createStatusBar()
    local status_h   = status_bar:getSize().h

    local pad           = Screen:scaleBySize(8)
    local line_h        = Screen:scaleBySize(PGN_LOG_FONT_SIZE) + 4
    local pgn_h         = line_h
    local eval_h        = line_h
    local log_border    = Screen:scaleBySize(1)
    local toolbar_btn_h = Screen:scaleBySize(24)
    local text_frame_h  = log_border * 2 + pad + pgn_h + eval_h + pad
    local min_log_h     = text_frame_h + toolbar_btn_h

    local BOARD_SIZE    = 8
    local board_pad     = 0
    local available_h   = self.full_height - status_h - min_log_h
    local usable_w      = self.full_width - 2 * board_pad
    local cell          = math.floor(math.min(usable_w, available_h - board_pad) / BOARD_SIZE)
    local board_h       = cell * BOARD_SIZE + board_pad
    local log_h         = self.full_height - status_h - board_h
    local pgn_h         = log_h - text_frame_h + line_h

    self:initializeBoard(board_h)
    local inner_w       = self.full_width - 2 * pad

    local frame_fixed_h = log_border * 2 + pad + eval_h + pad
    local pgn_h         = math.max(line_h, log_h - frame_fixed_h - toolbar_btn_h)

    self.eval_line = TextWidget:new{
        text    = "Eval: --",
        face    = Font:getFace(PGN_LOG_FONT, PGN_LOG_FONT_SIZE),
        halign  = "left",
        padding = 0,
        width   = inner_w,
    }

    local eval_line_left = LeftContainer:new{
        dimen = Geometry:new{ w = inner_w, h = eval_h },
        self.eval_line,
    }

    self:updateEvalLine()

    self.pgn_log = self:createPgnLogWidget("", inner_w, pgn_h)

    -- Collect specs first, so the width can be derived from the real button
    -- count BEFORE any button is built. Buttons lay themselves out in init(),
    -- so assigning .width afterwards does nothing -- and a text button built at
    -- width 0 computes a negative max_width for its label.
    local specs = {
        { icon = "chevron.left",  cb = function() self:handleUndoMove(false) end },
        { icon = "chevron.right", cb = function() self:handleRedoMove(false) end },
    }
    if self:isLichessMode() then
        -- Online: keep the arrows for browsing, swap Load PGN for game actions.
        specs[#specs + 1] = { icon = "bookmark",
            cb = function() UIManager:show(self:openSaveDialog()) end }
        specs[#specs + 1] = { text = "≡",
            cb = function() self:showLichessGameActions() end }
    elseif self:isChessMode() then
        specs[#specs + 1] = { icon = "bookmark",
            cb = function() UIManager:show(self:openSaveDialog()) end }
        specs[#specs + 1] = { icon = "appbar.filebrowser",
            cb = function() self:openLoadPgnDialog() end }
    end
    specs[#specs + 1] = { icon = "plus", cb = function()
        UIManager:show(ConfirmBox:new{
            text        = _("Start a new game?"),
            ok_text     = _("New Game"),
            ok_callback = function() self:resetGame() end,
        })
    end }
    specs[#specs + 1] = { icon = "home", cb = function()
        UIManager:show(ConfirmBox:new{
            text        = _("Return to main menu?"),
            ok_text     = _("Menu"),
            ok_callback = function()
                self:stopThinkingIndicator()
                self.timer:stop()
                self:saveGameState()
                UIManager:close(self)
                self:onInkMateStart()
            end,
        })
    end }

    local toolbar_btn_w = math.floor(self.full_width / #specs)
    local toolbar_buttons = {}
    for i, spec in ipairs(specs) do
        if spec.icon then
            toolbar_buttons[i] = self:createToolbarButton(
                spec.icon, toolbar_btn_w, toolbar_btn_h, spec.cb)
        else
            toolbar_buttons[i] = ButtonWidget:new{
                text = spec.text, width = toolbar_btn_w, height = toolbar_btn_h,
                padding = 0, margin = 0, bordersize = 0, callback = spec.cb,
            }
        end
    end
    local toolbar = HorizontalGroup:new(toolbar_buttons)

    local log_section = VerticalGroup:new{
        width = self.full_width,
        FrameContainer:new{
            background     = BACKGROUND_COLOR,
            bordersize     = log_border,
            padding        = 0,
            padding_left   = pad,
            padding_right  = pad,
            padding_top    = pad,
            padding_bottom = pad,
            width          = self.full_width,
            VerticalGroup:new{
                width = inner_w,
                self.pgn_log,
                eval_line_left,
            },
        },
        toolbar,
    }

    local board_section
    if self:isChessMode() and self.game_mode ~= "puzzle" then
        self.visual_eval_bar = FrameContainer:new{
            bordersize = 1, padding = 0, background = Blitbuffer.COLOR_BLACK,
            VerticalGroup:new{
                FrameContainer:new{ width = 6, height = math.floor(board_h / 2), background = Blitbuffer.COLOR_BLACK, padding = 0, bordersize = 0, WidgetContainer:new{ dimen = Geom:new{ w = 6, h = math.floor(board_h / 2) } } },
                FrameContainer:new{ width = 6, height = math.floor(board_h / 2), background = Blitbuffer.COLOR_WHITE, padding = 0, bordersize = 0, WidgetContainer:new{ dimen = Geom:new{ w = 6, h = math.floor(board_h / 2) } } },
            }
        }
        board_section = HorizontalGroup:new{
            align = "center",
            self.board,
            self.visual_eval_bar
        }
        self:updateVisualEvalBar()
    else
        board_section = self.board
    end

    local main_vgroup = VerticalGroup:new{
        align = "center", width = self.full_width, height = self.full_height,
        board_section, log_section, status_bar,
    }
    self.status_bar = status_bar
    -- Keep the full-screen layout anchored at y=0 even when content is tall.
    self[1] = main_vgroup
end

function Kochess:updatePgnLogInitialText()
    if self.pgn_log then self.pgn_log:setText(""); UIManager:setDirty(self, "ui") end
end

function Kochess:updateVisualEvalBar()
    if not self.visual_eval_bar then return end
    local cp = self.last_cp
    local mate = self.last_mate
    
    if cp and self.eval_turn == Chess.BLACK then cp = -cp end
    if mate and self.eval_turn == Chess.BLACK then mate = -mate end

    local w_pct = 50
    if mate then
        w_pct = mate > 0 and 100 or 0
    elseif cp then
        local capped = math.max(-1000, math.min(1000, cp))
        w_pct = 50 + (capped / 20)
    end
    
    local total_h = self.board.height
    local w_h = math.floor(total_h * (w_pct / 100))
    local b_h = total_h - w_h
    
    -- Recreate the two blocks to force geometry update
    self.visual_eval_bar[1] = VerticalGroup:new{
        FrameContainer:new{ 
            width = 6, height = b_h, background = Blitbuffer.COLOR_BLACK, padding = 0, bordersize = 0,
            WidgetContainer:new{ dimen = Geom:new{ w = 6, h = b_h } } 
        },
        FrameContainer:new{ 
            width = 6, height = w_h, background = Blitbuffer.COLOR_WHITE, padding = 0, bordersize = 0,
            WidgetContainer:new{ dimen = Geom:new{ w = 6, h = w_h } } 
        },
    }
    if UIManager.isWidgetShown and UIManager:isWidgetShown(self) then
        UIManager:setDirty(self.visual_eval_bar, "ui")
    end
end

function Kochess:detectOpening()
    if not self:isChessMode() then return nil end
    if not self.openings then return nil end

    local hist = self.game.history and self.game:history() or nil
    if type(hist) ~= "table" or #hist == 0 then
        hist = self.game.history and self.game.history() or {}
    end

    local moves = {}
    for i, san in ipairs(hist) do
        if type(san) == "string" and san ~= "" then
            san = san:gsub("[+#?!]", "")
            moves[#moves + 1] = san
        end
    end

    local played = table.concat(moves, " ")

    local best = nil
    for _, o in ipairs(self.openings) do
        if played:find(o.moves, 1, true) == 1 then
            if not best or #o.moves > #best.moves then
                best = o
            end
        end
    end

    return best
end

local function formatEval(self)
    if self:isCheckersMode() or self:isFoxHoundMode() or self:isReversiMode() then return "" end
    -- No engine evaluation during a Lichess game: engine assistance there is a
    -- ToS violation, so the display never exists to be tempted by.
    if self:isLichessMode() then return "" end
    local mate = self.last_mate
    if mate ~= nil then
        local m = tonumber(mate) or 0
        if m == 0 then
            return "eval: # (checkmate)"
        end
        local side  = (m > 0) and "White" or "Black"
        local moves = math.max(1, math.ceil(math.abs(m) / 2))
        return string.format("eval: Mate in %d (%s)", moves, side)
    end

    local cp = self.last_cp
    if cp == nil then
        return ""
    end

    local v = (tonumber(cp) or 0) / 100.0
    local abs = math.abs(v)

    local tag
    if abs < 0.20 then
        tag = "(roughly equal)"
    elseif abs < 0.50 then
        tag = (v > 0) and "(slight advantage for White)" or "(slight advantage for Black)"
    elseif abs < 1.00 then
        tag = (v > 0) and "(small advantage for White)" or "(small advantage for Black)"
    elseif abs < 2.00 then
        tag = (v > 0) and "(clear advantage for White)" or "(clear advantage for Black)"
    elseif abs < 4.00 then
        tag = (v > 0) and "(winning advantage for White)" or "(winning advantage for Black)"
    else
        tag = (v > 0) and "(decisive advantage for White)" or "(decisive advantage for Black)"
    end

    return string.format("eval: %+.2f %s", v, tag)
end

function Kochess:updateEvalLine()
    self:updateVisualEvalBar()
    if self.eval_line then
        self.eval_line:setText(formatEval(self))
        UIManager:setDirty(self, "ui")
    end
end

function Kochess:startThinkingIndicator()
    self:stopThinkingIndicator()
    if self:getSetting("thinking_indicator", true) == false then return end
    if not self.status_bar then return end
    local token = {}
    self._thinking_token = token
    self._thinking_started_at = os.time()
    UIManager:scheduleIn(3, function()
        if self._thinking_token == token then self:showThinkingIndicator() end
    end)
end

function Kochess:showThinkingIndicator()
    if self._thinking_visible or not self.status_bar then return end
    self._thinking_visible = true
    local label = self:isLichessMode() and _("Waiting for opponent...") or _("Computer thinking...")
    self.status_bar:setSubTitle(label)
    if self.eval_line then
        self.eval_line:setText(label)
    end
    UIManager:setDirty(self.status_bar, "ui")
    UIManager:setDirty(self, "ui")
end

function Kochess:stopThinkingIndicator()
    local was_visible = self._thinking_visible
    self._thinking_token = nil
    self._thinking_started_at = nil
    self._thinking_visible = false
    if was_visible and self.status_bar and self.game then
        self:updatePlayerDisplay()
        self:updateEvalLine()
    end
end

function Kochess:createPgnLogWidget(txt, w, h) return TextBoxWidget:new{ use_xtext=true, text=txt, face=Font:getFace(self.notation_font, self.notation_size), scroll=true, width=w, height=h, dialog=self } end
function Kochess:createToolbarButton(icon, w, h, cb) return ButtonWidget:new{ icon=icon, width=w, icon_width=w, icon_height=h, padding=0, margin=0, bordersize=0, callback=cb } end
function Kochess:handleUndoMove(all)
    if self:isLichessMode() then
        -- Lightweight history browsing: rewind the display without touching
        -- the engine or timer. The next server event (or pressing ▶) restores.
        local moved = false
        if all then
            while self.game.undo() do moved = true end
        else
            moved = self.game.undo() and true or false
        end
        if moved then
            self._lichess_browse_depth = (self._lichess_browse_depth or 0) + (all and 999 or 1)
            self.board:clearValidMoves()
            self.board:updateBoard()
            self:updatePgnLog()
            UIManager:setDirty(self, "ui")
        end
        return
    end
    self:stopUCI(); self.timer:stop()
    if all then while self.game.undo() do end else self.game.undo() end
    self.board:updateBoard(); self:updatePgnLog(); UIManager:setDirty(self, "ui")
    self.timer:start()
end

function Kochess:handleRedoMove(all)
    if self:isLichessMode() then
        local moved = false
        if all then
            while self.game.redo() do moved = true end
        else
            moved = self.game.redo() and true or false
        end
        if moved then
            self._lichess_browse_depth = math.max(0, (self._lichess_browse_depth or 0) - (all and 999 or 1))
            self.board:clearValidMoves()
            self.board:updateBoard()
            self:updatePgnLog()
            UIManager:setDirty(self, "ui")
        end
        return
    end
    self:stopUCI(); self.timer:stop()
    if all then while self.game.redo() do end else self.game.redo() end
    self.board:updateBoard(); self:updatePgnLog(); UIManager:setDirty(self, "ui")
    self.timer:start()
end

function Kochess:showOnlineLockedMessage()
    UIManager:show(InfoMessage:new{
        text = _("Not available during a Lichess game."),
    })
end

--- Resign the current Lichess game after a confirmation prompt.
function Kochess:handleResignOnline()
    local backend = self.engine
    if not backend or not backend.game_id or backend.finished then
        UIManager:show(InfoMessage:new{ text = _("No active Lichess game.") })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Resign this Lichess game?"),
        ok_text = _("Resign"),
        ok_callback = function()
            backend:resign(function(ok, _, _, err)
                if not ok then
                    UIManager:show(InfoMessage:new{
                        text = _("Resign failed") .. ": " .. tostring(err),
                    })
                end
            end)
        end,
    })
end

--- Offer (or accept) a draw on the current Lichess game.
function Kochess:handleOfferDraw()
    local backend = self.engine
    if not backend or not backend.game_id or backend.finished then
        UIManager:show(InfoMessage:new{ text = _("No active Lichess game.") })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Offer a draw to your opponent?"),
        ok_text = _("Offer draw"),
        ok_callback = function()
            backend:offerDraw(true, function(ok, _, _, err)
                if ok then
                    UIManager:show(InfoMessage:new{ text = _("Draw offered.") })
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Draw offer failed") .. ": " .. tostring(err),
                    })
                end
            end)
        end,
    })
end

--- Propose (or accept) a takeback on the current Lichess game.
function Kochess:handleProposeTakeback()
    local backend = self.engine
    if not backend or not backend.game_id or backend.finished then
        UIManager:show(InfoMessage:new{ text = _("No active Lichess game.") })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Propose a takeback to your opponent?\nThey must accept for the move to be undone."),
        ok_text = _("Propose takeback"),
        ok_callback = function()
            backend:takeback(true, function(ok, _, _, err)
                if ok then
                    UIManager:show(InfoMessage:new{ text = _("Takeback proposed.") })
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Takeback failed") .. ": " .. tostring(err),
                    })
                end
            end)
        end,
    })
end

--- In-game actions menu for Lichess games (replaces Load PGN in the toolbar).
function Kochess:showLichessGameActions()
    local backend = self.engine
    local has_game = backend and backend.game_id and not backend.finished
    local menu
    menu = ButtonDialog:new{
        title = _("Game Actions"),
        title_align = "center",
        buttons = {
            {{ text = "½ " .. _("Offer draw"),  callback = function() UIManager:close(menu); self:handleOfferDraw() end }},
            {{ text = "↩ " .. _("Propose takeback"), callback = function() UIManager:close(menu); self:handleProposeTakeback() end }},
            {{ text = "✕ " .. _("Resign"),      callback = function() UIManager:close(menu); self:handleResignOnline() end }},
            {{ text = _("Cancel"),       callback = function() UIManager:close(menu) end }},
        },
    }
    UIManager:show(menu)
end

function Kochess:onMoveExecuted(move)
    self:stopThinkingIndicator()
    if self:isFoxHoundMode() and not move then
        self:updatePgnLog()
        self:updateTimerDisplay()
        self:updatePlayerDisplay()
        self:launchCurrentComputerMove()
        UIManager:setDirty(self, "ui")
        return
    end

    if self.game_mode == "puzzle" and move then
        local uci = move.from .. move.to .. (move.promotion or "")
        if uci == self.current_puzzle:getNextExpectedMove() then
            self.current_puzzle:advance()
            if self.current_puzzle:isComplete() then
                self.current_puzzle.completed = true
                self.board:updateBoard()
                UIManager:setDirty(self, "ui")
                self:showGameOverDialog("puzzle", "solved")
                return
            else
                local reply_uci = self.current_puzzle:getNextExpectedMove()
                if reply_uci then
                    self.current_puzzle:advance()
                    local r_move = self.game.move_from_uci(reply_uci)
                    self.game.move(r_move)
                end
                self.board:updateBoard()
                UIManager:setDirty(self, "ui")
                if self.current_puzzle:isComplete() then
                    self.current_puzzle.completed = true
                    self:showGameOverDialog("puzzle", "solved")
                end
                return
            end
        else
            self.game.undo()
            self.board:updateBoard()
            UIManager:show(require("ui/widget/infomessage"):new{ text = _("Incorrect move, try again!") })
            return
        end
    end

    self.running = true

    self:updatePgnLog()

    local opening = self:detectOpening()

    if self.eval_line then
        local eval_txt = formatEval(self)
        if opening and eval_txt ~= "" then
            self.eval_line:setText(string.format("%s (%s) · %s", opening.name, opening.eco or "?", eval_txt))
        elseif opening then
            self.eval_line:setText(string.format("%s (%s)", opening.name, opening.eco or "?"))
        else
            self.eval_line:setText(eval_txt)
        end
    end

    local is_over, result, reason = self.game.game_over()
    if is_over then
        if self:isLichessMode() then
            -- Lichess confirms the result on the game stream; wait for that so we
            -- do not raise two dialogs for the same finish.
            self:stopUCI()
            self.timer:stop()
            self.running = false
            self:updateTimerDisplay()
        else
            self:showGameOverDialog(result, reason)
        end
        UIManager:setDirty(self, "ui")
        return
    end

    self:launchNextMove()
    UIManager:setDirty(self, "ui")
end

function Kochess:launchNextMove()
    self.timer:switchPlayer()
    self.timer.currentPlayer = self.game.turn()
    self:updateTimerDisplay()
    if self:isReversiMode() then
        if not self.game.is_human(self.game.turn()) then self:launchReversiAI() end
        return
    end
    if self:isFoxHoundMode() then
        if not self.game.is_human(self.game.turn()) then self:launchFoxHoundAI() end
        return
    end
    if self:isCheckersMode() then
        if not self.game.is_human(self.game.turn()) then self:launchCheckersAI() end
        return
    end
    if not (self.engine and self.engine.state.uciok and not self.game.is_human(self.game.turn())) then return end

    local is_cvc = not self.game.is_human(Chess.WHITE) and not self.game.is_human(Chess.BLACK)
    if not is_cvc then
        self:launchUCI()
    else
        -- Let UIManager process taps between computer-vs-computer moves.
        local token = {}
        self._pending_launch = token
        UIManager:scheduleIn(1, function()
            if self._pending_launch ~= token then return end
            self._pending_launch = nil
            self:launchUCI()
        end)
    end
end

function Kochess:launchCurrentComputerMove()
    if self:isReversiMode() then
        if self.game.is_human(self.game.turn()) then return end
        self.running = true
        self.timer.currentPlayer = self.game.turn()
        self.timer:start()
        self:updateTimerDisplay()
        self:launchReversiAI()
        return
    end
    if self:isFoxHoundMode() then
        if self.game.setup_pending or self.game.is_human(self.game.turn()) then return end
        self.running = true
        self.timer.currentPlayer = self.game.turn()
        self.timer:start()
        self:updateTimerDisplay()
        self:launchFoxHoundAI()
        return
    end
    if self:isCheckersMode() then
        if self.game.is_human(self.game.turn()) then return end
        self.running = true
        self.timer.currentPlayer = self.game.turn()
        self.timer:start()
        self:updateTimerDisplay()
        self:launchCheckersAI()
        return
    end
    if not (self.engine and self.engine.state.uciok and not self.game.is_human(self.game.turn())) then return end

    self.running = true
    self.timer.currentPlayer = self.game.turn()
    self.timer:start()
    self:updateTimerDisplay()
    self:launchUCI()
end

function Kochess:launchCheckersAI()
    if self.checkers_busy or self.game.is_human(self.game.turn()) then return end
    self:runCooperativeAI(
        "checkers_busy",
        function() return self:isCheckersMode() and not self.game.is_human(self.game.turn()) end,
        function(yield_fn)
            local depth = tonumber(self.engine_depth) or 4
            if depth == 0 then depth = 6 end
            depth = math.max(1, math.min(6, depth))
            return CheckersAI.bestMove(self.game, depth, self.blunder_chance or 0, yield_fn)
        end,
        function(move)
            if not move then return end
            local played = self.game.commit_path and self.game:commit_path{ path = move.path }
                or self.game:move{ from = move.from, to = move.to }
            if played then self.board:handleGameMove(played) end
        end
    )
end

function Kochess:runCooperativeAI(busy_key, guard, compute, apply)
    if self[busy_key] then return end
    self[busy_key] = true
    self:startThinkingIndicator()

    local checkpoint_limit = 200
    if self:isFoxHoundMode() then
        checkpoint_limit = 2000
    elseif self:isCheckersMode() then
        checkpoint_limit = 500
    elseif self:isReversiMode() then
        checkpoint_limit = 200
    end
    local initial_delay = 0.15
    local resume_delay = 0.02
    local token = {}
    self._ai_token = token
    local co
    local checks = 0
    local function yield_fn()
        checks = checks + 1
        if checks >= checkpoint_limit then
            checks = 0
            coroutine.yield()
        end
    end

    local function finish()
        if self._ai_token == token then self._ai_token = nil end
        self[busy_key] = false
        self:stopThinkingIndicator()
    end

    local function step()
        if self._ai_token ~= token or not guard() then
            finish()
            return
        end
        if self._thinking_started_at and os.time() - self._thinking_started_at >= 3 then
            self:showThinkingIndicator()
        end
        if not co then
            co = coroutine.create(function()
                return compute(yield_fn)
            end)
        end
        local ok, move = coroutine.resume(co)
        if not ok then
            finish()
            return
        end
        if coroutine.status(co) == "dead" then
            finish()
            if guard() then apply(move) end
            return
        end
        UIManager:scheduleIn(resume_delay, step)
    end

    UIManager:scheduleIn(initial_delay, step)
end

function Kochess:launchFoxHoundAI()
    if self.foxhound_busy or self.game.setup_pending or self.game.is_human(self.game.turn()) then return end
    self:runCooperativeAI(
        "foxhound_busy",
        function() return self:isFoxHoundMode() and not self.game.setup_pending and not self.game.is_human(self.game.turn()) end,
        function(yield_fn)
            local depth = tonumber(self.engine_depth) or 4
            return FoxHoundAI.bestMove(self.game, depth, self.blunder_chance or 0, yield_fn)
        end,
        function(move)
            if not move then return end
            local played = self.game:move{ from = move.from, to = move.to }
            if played then self.board:handleGameMove(played) end
        end
    )
end

function Kochess:launchReversiAI()
    if self.reversi_busy or self.game.is_human(self.game.turn()) then return end
    self:runCooperativeAI(
        "reversi_busy",
        function() return self:isReversiMode() and not self.game.is_human(self.game.turn()) end,
        function(yield_fn)
            local depth = tonumber(self.engine_depth) or 4
            return ReversiAI.bestMove(self.game, depth, self.blunder_chance or 0, yield_fn)
        end,
        function(move)
            if not move then return end
            local played = self.game:move{ to = move.to }
            if played then self.board:handleGameMove(played) end
        end
    )
end

function Kochess:uciMove(str)
    if not self:isChessMode() then return end
    -- Never rewrite a move that came off the wire: online it is the opponent's
    -- real move, not a suggestion we are free to weaken.
    if self.weakening and not self:isLichessMode() then
        str = self.weakening:maybeWeaken(str)
    end
    local m = self.game.move({from=str:sub(1,2), to=str:sub(3,4), promotion=(#str==5 and str:sub(5,5) or nil)})
    if m then self.board:handleGameMove(m) end
end

function Kochess:launchUCI()
    if not self:isChessMode() then return end
    if not (self.engine and self.engine.state and self.engine.state.uciok) then return end
    if self.engine_busy then return end
    self.engine_busy = true
    self:startThinkingIndicator()

    local moves = {}
    for _, m in ipairs(self.game.history({ verbose = true })) do
        moves[#moves + 1] = m.from .. m.to .. (m.promotion or "")
    end
    self.engine:position({ moves = table.concat(moves, " ") })

    self.eval_turn = self.game.turn()

    if self:isLichessMode() then
        -- Online there is nothing to configure: the "search" is the opponent
        -- thinking, and Lichess owns both clocks.
        self.engine:go({})
        return
    end

    local movetime_ms = (self.engine_movetime or 1) * 1000
    local wtime = math.max(100, self.timer:getRemainingTime(Chess.WHITE) * 1000)
    local btime = math.max(100, self.timer:getRemainingTime(Chess.BLACK) * 1000)

    local d = tonumber(self.engine_depth) or 0
    local depth_limit = (d >= 1 and d <= 5) and d or nil

    self.engine:go({
        wtime    = wtime,
        btime    = btime,
        winc     = self.timer.increment[Chess.WHITE] * 1000,
        binc     = self.timer.increment[Chess.BLACK] * 1000,
        movetime = movetime_ms,
        depth    = depth_limit,
    })
end

function Kochess:stopUCI()
    self._pending_launch = nil
    self._ai_token = nil
    self:stopThinkingIndicator()
    self.engine_busy = false
    self.checkers_busy = false
    self.foxhound_busy = false
    self.reversi_busy = false
    if self.engine and not self.engine.closed and self.engine.state.uciok then self.engine:stop() end
end

function Kochess:shutdownEngine()
    self._pending_launch = nil
    self._ai_token = nil
    self:stopThinkingIndicator()
    self.engine_busy = false
    self.checkers_busy = false
    self.foxhound_busy = false
    self.reversi_busy = false
    self.goldfish_active = false
    if self.engine and not self.engine.closed then
        self.engine:quit()
    end
    self.engine = nil
end

function Kochess:updatePgnLog()
    local moves = self.game:history()
    local txt = ""
    for i, m in ipairs(moves) do
        if i%2==1 then txt = txt .. " " .. (math.floor(i/2)+1) .. "." end
        txt = txt .. " " .. m
    end
    self.pgn_log:setText(txt)

    if self.pgn_log.scrollToBottom then
        self.pgn_log:scrollToBottom()
    elseif self.pgn_log.scrollTo then
        self.pgn_log:scrollTo(1e9)
    end
end

function Kochess:updateTimerDisplay()
    local ind = self.running and ((self.game.turn()==Chess.WHITE and " < ") or " > ") or " || "
    if self:isChessMode() then
        self.status_bar:setTitle(self.timer:formatTime(self.timer:getRemainingTime(Chess.WHITE)) .. ind .. self.timer:formatTime(self.timer:getRemainingTime(Chess.BLACK)))
    else
        self.status_bar:setTitle("")
    end
    self:updatePlayerDisplay(ind)
    UIManager:setDirty(self.status_bar, "ui")
end

function Kochess:updatePlayerDisplay(ind)
    if self._thinking_visible then return end
    if self:isFoxHoundMode() and self.game.setup_pending then
        self.status_bar:setSubTitle("Choose Fox Start")
        return
    end
    local white_label = self:isFoxHoundMode() and "Fox" or "White"
    local black_label = self:isFoxHoundMode() and "Hounds" or "Black"
    local opponent = self:isLichessMode() and (self.lichess_opponent or "Lichess") or ("Stockfish " .. self:getSetting("engine_elo", 1500))
    local white = white_label .. "(Human)"
    local black = "(" .. opponent .. ")" .. black_label
    local sep = ind or (self.running and ((self.game.turn()==Chess.WHITE and " < ") or " > ") or " || ")
    self.status_bar:setSubTitle(white .. sep .. black)
end

function Kochess:resetGame()
    if self:isLichessMode() then
        -- "New game" online means letting go of this Lichess game and seeking a
        -- fresh one, not rewinding the board.
        self:setSetting("lichess_game_id", "")
        self:shutdownEngine()
        self:stopUCI(); self.game.reset(); self.timer:reset()
        self.board:clearValidMoves()
        self.board:clearPreviousMoveHints()
        self.board:clearCheckHint()
        self.running = false
        self:updateTimerDisplay(); self:updatePlayerDisplay()
        self.board:updateBoard(); UIManager:setDirty(self, "ui")
        self:initializeEngine()
        return
    end
    self:stopUCI(); self.game.reset(); self.timer:reset()
    if self.engine and self:isChessMode() then self.engine.send("ucinewgame") end
    self.board:clearValidMoves()
    self.board:clearPreviousMoveHints()
    self.board:clearCheckHint()
    if self:isFoxHoundMode() then
        self:setSetting("saved_foxhound_state", "")
    elseif self:isReversiMode() then
        self:setSetting("saved_reversi_state", "")
    elseif self:isCheckersMode() then
        self:setSetting("saved_checkers_state", "")
    else
        self:setSetting("saved_pgn", "")
    end
    self.running = false
    self:updateTimerDisplay(); self:updatePlayerDisplay(); self.board:updateBoard(); UIManager:setDirty(self, "ui")
    self:launchCurrentComputerMove()
end

function Kochess:showGameOverDialog(result, reason)
    self:stopThinkingIndicator()
    local text
    if result == "1-0" or result == "0-1" then
        local winner
        if self:isFoxHoundMode() then
            winner = (result == "1-0") and _("Fox") or _("Hounds")
        else
            winner = (result == "1-0") and _("White") or _("Black")
        end
        if self:isCheckersMode() or self:isFoxHoundMode() or self:isReversiMode() then
            text = string.format(_("%s Wins!"), winner)
        else
            text = string.format(_("Checkmate! %s wins."), winner)
        end
    else
        local label
        if not reason then
            text = _("Draw!")
        elseif reason == "Stalemate" then
            label = _("Stalemate")
        elseif reason == "Insufficient material" then
            label = _("Insufficient material")
        elseif reason == "Threefold repetition" then
            label = _("Threefold repetition")
        elseif reason == "Fifty-move rule" then
            label = _("Fifty-move rule")
        else
            label = reason
        end
        if label then
            text = string.format(_("Draw! %s."), label)
        end
    end

    self:stopUCI()
    self.timer:stop()
    self.running = false
    self:updateTimerDisplay()

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Play again"),
        cancel_text = _("Close"),
        ok_callback = function() self:handleRematch() end,
        -- Close leaves the final position on the board so it can be looked over.
        -- The + toolbar button starts a fresh game whenever they are ready.
    })
end

--- Start another game with the same opponent and settings.
--- resetGame() already clears the board, the clock and the saved state, and ends
--- by calling launchCurrentComputerMove(), so it must not be called again here.
function Kochess:handleRematch()
    self.last_cp = nil
    self.last_mate = nil
    self.eval_turn = nil
    self.running = false

    self:resetGame()
    self:updatePgnLogInitialText()
    self:updateEvalLine()
end

function Kochess:createStatusBar()
    local Screen = require("device").screen
    return TitleBarWidget:new{
        fullscreen             = true,
        title                  = "00:00",
        subtitle               = "HvH",
        left_icon              = "appbar.settings",
        left_icon_size_ratio   = 1.0,
        right_icon_size_ratio  = 1.0,
        title_top_padding      = Screen:scaleBySize(2),
        bottom_v_padding       = Screen:scaleBySize(2),
        left_icon_tap_callback = function()
            self:stopThinkingIndicator()
            local was_online = self:isLichessMode()
            local was_game_id = self:getSetting("lichess_game_id", "")
            SettingsWidget:new{
                engine  = self.engine,
                timer   = self.timer,
                game    = self.game,
                parent  = self,
                onApply = function()
                    self:stopUCI()
                    local mode = self:getSetting("game_mode", MODE_CHESS)
                    -- Switching the opponent between local and Lichess swaps the
                    -- whole backend, so it needs the same full restart as a mode
                    -- change.
                    local online_target_changed = self:isLichessMode()
                        and self:getSetting("lichess_game_id", "") ~= was_game_id
                    if self:isLichessMode() ~= was_online or online_target_changed then
                        self:clearSavedGameStates()
                        self.game_mode = mode
                        self:shutdownEngine()
                        UIManager:nextTick(function() self:startGame() end)
                        return
                    end
                    if mode ~= self.game_mode then
                        self:clearSavedGameStates()
                        self.game_mode = mode
                        self:shutdownEngine()
                        UIManager:nextTick(function() self:startGame() end)
                        return
                    end
                    self.timer:reset()
                    self:updateBoardOrientation()
                    self:updatePlayerDisplay()
                    self:updateTimerDisplay()
                    self:launchCurrentComputerMove()
                end,
            }:show()
        end,
    }
end

function Kochess:openLoadPgnDialog()
    if not self:isChessMode() then return end
    UIManager:show(
        PathChooser:new{
            path = GAMES_PATH,
            title = _("Load PGN File"),
            select_directory = false,
            onConfirm = function(path)
                if not path then return end
                local fh = io.open(path, "r")
                if not fh then
                    UIManager:show(InfoMessage:new{
                        text = _("Could not open file:\n") .. path,
                    })
                    return
                end
                local pgn_data = fh:read("*a")
                fh:close()

                self:stopUCI()
                self.timer:stop()

                self.game.reset()
                self.game.load_pgn(pgn_data)

                self.board:updateBoard()
                self:updatePgnLog()
                self:updateTimerDisplay()
                self:updatePlayerDisplay()

                if self.engine and self.engine.state.uciok then
                    self.engine.send("ucinewgame")
                    self.engine.send("isready")
                end

                UIManager:setDirty(self, "ui")
                self.timer:start()
            end,
        }
    )
end

function Kochess:handleSaveFile(dialog, filename_input, current_dir)
    if not self:isChessMode() then return end
    filename_input:onCloseKeyboard()
    local dir = current_dir
    local file = filename_input:getText():gsub("\n$", "")

    if not file:lower():match("%.pgn$") then
        file = file .. ".pgn"
    end

    local sep = package.config:sub(1, 1)
    local fullpath = dir .. sep .. file
    local pgn_data = self.game.pgn()

    local fh, err = io.open(fullpath, "w")
    if not fh then
        UIManager:show(InfoMessage:new{
            text = _("Could not save file:\n") .. tostring(err),
        })
        return
    end

    fh:write(pgn_data)
    fh:close()

    UIManager:close(dialog)
    UIManager:show(InfoMessage:new{
        text = _("Game saved to:\n") .. fullpath,
    })
end

function Kochess:openSaveDialog()
    if not self:isChessMode() then return end
    local current_dir = GAMES_PATH
    local dialog
    local filename_input

    local function onSaveConfirm()
        self:handleSaveFile(dialog, filename_input, current_dir)
    end

    dialog = InputDialog:new{
        title = _("Save current game as"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        filename_input:onCloseKeyboard()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = onSaveConfirm,
                },
            }
        }
    }

    local dir_label = TextWidget:new{
        text = current_dir,
        face = Font:getFace("smallinfofont"),
        truncate_left = true,
        max_width = dialog:getSize().w * 0.8,
    }

    local browse_button = ButtonWidget:new{
        text = "...",
        callback = function()
            UIManager:show(
                PathChooser:new{
                    path = current_dir,
                    title = _("Select Save Folder"),
                    select_file = false,
                    show_files = true,
                    parent = dialog,
                    onConfirm = function(chosen)
                        if chosen and #chosen > 0 then
                            current_dir = chosen
                            dir_label:setText(chosen)
                            UIManager:setDirty(dialog, "ui")
                        end
                    end
                }
            )
        end,
    }

    filename_input = InputText:new{
        text = "game.pgn",
        focused = true,
        parent = dialog,
        enter_callback = onSaveConfirm,
    }

    local content = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "left",
            dialog.title_bar,
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Folder") .. ":", face = Font:getFace("cfont", 22) },
                dir_label,
                HorizontalSpan:new{ width = Size.padding.small },
                browse_button,
            },
            HorizontalGroup:new{
                spacing = Size.padding.large,
                TextWidget:new{ text = _("Filename") .. ":", face = Font:getFace("cfont", 22) },
                filename_input,
            },
            CenterContainer:new{
                dimen = Geometry:new{
                    w = dialog.title_bar:getSize().w,
                    h = dialog.button_table:getSize().h,
                },
                dialog.button_table
            },
        },
    }

    dialog.movable = MovableContainer:new{ content }
    dialog[1] = CenterContainer:new{ dimen = Screen:getSize(), dialog.movable }
    dialog:refocusWidget()
    return dialog
end

function Kochess:openPromotionDialog(f,t,c)
    local choices = {q=Chess.QUEEN, r=Chess.ROOK, b=Chess.BISHOP, n=Chess.KNIGHT}
    local icons_p = { [Chess.QUEEN] = {[Chess.WHITE]="casualchess/wQ", [Chess.BLACK]="casualchess/bQ"}, [Chess.ROOK] = {[Chess.WHITE]="casualchess/wR", [Chess.BLACK]="casualchess/bR"}, [Chess.BISHOP] = {[Chess.WHITE]="casualchess/wB", [Chess.BLACK]="casualchess/bB"}, [Chess.KNIGHT] = {[Chess.WHITE]="casualchess/wN", [Chess.BLACK]="casualchess/bN"} }

    local icon_size = Screen:scaleBySize(60)

    local dialog = InputDialog:new{ title=_("Promote to"), buttons={} }
    local btns = {}
    for char, type in pairs(choices) do
        table.insert(btns, ButtonWidget:new{ icon=icons_p[type][c], width=icon_size, icon_width=icon_size, icon_height=icon_size, callback=function()
            UIManager:close(dialog)
            local m = self.game.move({from=f, to=t, promotion=char})
            if m then self.board:handleGameMove(m) end
        end })
    end

    local content = FrameContainer:new{ radius=Size.radius.window, bordersize=Size.border.window, background=BACKGROUND_COLOR, padding=Size.padding.large,
        VerticalGroup:new{ align="center", dialog.title_bar, VerticalSpan:new{width=20}, HorizontalGroup:new{ spacing=20, unpack(btns) } }
    }
    dialog.movable = MovableContainer:new{ content }; dialog[1] = CenterContainer:new{ dimen = Screen:getSize(), dialog.movable }
    UIManager:show(dialog)
end

return Kochess
