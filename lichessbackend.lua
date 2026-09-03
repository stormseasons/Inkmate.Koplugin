-- Lichess Board API opponent.
--
-- Duck-types uci.lua's UCIEngine exactly the way goldfishuci.lua does, so main.lua
-- drives an online opponent through the code path it already uses for Stockfish:
--
--   position{moves=...}  -> any move in the list Lichess has not seen is OURS, POST it
--   go{...}              -> arm "waiting"; the search is the opponent thinking
--   <gameState arrives>  -> _trigger("bestmove", uci)
--
-- On top of that it emits online-only events main.lua subscribes to:
--   game_started(info)   my color, opponent name, initial FEN
--   clock(white_s, black_s)
--   resync(initial_fen, moves)   server state diverged from ours; rebuild
--   game_over(status, winner)
--   move_rejected(uci, err)
--   net_error(msg)
--   waiting_for_opponent()       a seek is open, no game yet

local UIManager = require("ui/uimanager")
local Lichess = require("lichess")

local RECONNECT_DELAY = 3
local MAX_RECONNECT_DELAY = 30

local LichessBackend = {}
LichessBackend.__index = LichessBackend

local function splitMoves(moves)
    local out = {}
    if type(moves) ~= "string" then return out end
    for move in moves:gmatch("%S+") do
        out[#out + 1] = move
    end
    return out
end

--- Is `a` a prefix of `b`? Used to tell "we are ahead with a POST in flight"
--- apart from "the server actually rewound the game".
local function isPrefix(a, b)
    if #a > #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

--- opts = {
---   token, curl, game_id,
---   seek = { minutes, increment, rated, color, rating_range },
--- }
function LichessBackend.new(opts)
    opts = opts or {}
    local self = setmetatable({}, LichessBackend)

    self.api = Lichess.new{ token = opts.token, curl = opts.curl }
    self.callbacks = {}
    self.closed = false

    self.game_id = opts.game_id
    self.seek = opts.seek
    self.my_color = nil          -- "white" | "black", known once gameFull arrives
    self.username = nil
    self.initial_fen = nil

    self.local_moves = {}        -- what the board has played
    self.server_moves = {}       -- last move list Lichess confirmed
    self.sent_upto = 0           -- how far we have POSTed
    self.waiting = false
    self.reconnect_delay = RECONNECT_DELAY

    -- Track draw/takeback offer flags so we only fire events on transitions.
    self._last_wdraw = false
    self._last_bdraw = false
    self._last_wtakeback = false
    self._last_btakeback = false

    self.state = {
        uciok = false,
        readyok = false,
        bestmove = nil,
        searching = false,
        options = {},
        id_name = "Lichess",
        last_output = "Lichess backend starting.",
        last_error = nil,
        _engine = self,
    }

    self.send = function(command) return self:handleCommand(command) end
    return self
end

-- ---------------------------------------------------------------- event bus

function LichessBackend:on(event, fn)
    self.callbacks[event] = self.callbacks[event] or {}
    table.insert(self.callbacks[event], fn)
end

function LichessBackend:_trigger(event, ...)
    local list = self.callbacks[event]
    if not list then return end
    for _, fn in ipairs(list) do pcall(fn, ...) end
end

function LichessBackend:emitLine(line)
    self.state.last_output = line
    self:_trigger("read", line)
end

function LichessBackend:_fail(msg)
    self.state.last_error = msg
    self:emitLine(msg)
    self:_trigger("net_error", msg)
end

-- ------------------------------------------------------------------ startup

function LichessBackend:uci()
    if not self.api:hasToken() then
        self:_fail("No Lichess token configured.")
        return
    end

    local ok, detail = Lichess.probeCurl(self.api.curl)
    if not ok then
        self:_fail(detail .. "\nLichess play needs curl on this device.")
        return
    end

    self.api:request({ path = "/api/account" }, function(req_ok, data, _, err)
        if self.closed then return end
        if not req_ok or type(data) ~= "table" or not data.id then
            self:_fail("Lichess sign-in failed: " .. tostring(err or "unexpected response"))
            return
        end
        self.username = data.id      -- lowercase id, what gameFull uses
        self:emitLine("Signed in to Lichess as " .. tostring(data.username or data.id))

        self:_openEventStream()

        if self.game_id then
            self:attachGame(self.game_id)
        elseif self.seek then
            self:startSeek()
        end
    end)
end

function LichessBackend:isready()
    self.state.readyok = true
    self:emitLine("readyok")
    self:_trigger("readyok")
end

-- The engine-tuning options mean nothing online; accept and ignore them so
-- settingswidget's applyEngineChanges path stays harmless.
function LichessBackend:setOption(name, value)
    self.state.options[name] = self.state.options[name] or { type = "string" }
    self.state.options[name].value = tostring(value)
end

function LichessBackend:ucinewgame()
    -- A new game online is a new Lichess game, not a reset of this one.
end

-- ------------------------------------------------------------- event stream

-- The account event stream is how a seek turns into a game: the POST that opens
-- the seek never returns the id, gameStart does.
function LichessBackend:_openEventStream()
    if self.closed then return end
    if self.event_stream then self.event_stream.close() end

    self.event_stream = self.api:stream({ path = "/api/stream/event", idle_timeout = 0 },
        function(event)
            if self.closed then return end
            if event.type == "gameStart" and event.game and event.game.gameId then
                if not self.game_id then
                    self:attachGame(event.game.gameId)
                end
            elseif event.type == "gameFinish" and event.game
                   and event.game.gameId == self.game_id then
                self.seek_open = false
            end
        end,
        function(ok, err)
            if self.closed then return end
            -- The event stream is our only source of gameStart; keep it alive.
            UIManager:scheduleIn(RECONNECT_DELAY, function()
                if not self.closed then self:_openEventStream() end
            end)
            if not ok and err then self:emitLine("Lichess event stream: " .. err) end
        end)
end

-- ------------------------------------------------------------------- seeking

function LichessBackend:startSeek()
    if self.closed or self.game_id then return end
    local s = self.seek or {}
    self.seek_open = true
    self:emitLine("Seeking a Lichess opponent...")
    self:_trigger("waiting_for_opponent")

    -- This request streams: it stays open until Lichess pairs us, and the pairing
    -- itself is announced on the event stream, not here.
    self.seek_stream = self.api:stream({
        method = "POST",
        path = "/api/board/seek",
        idle_timeout = 0,
        form = {
            rated = s.rated and "true" or "false",
            time = tostring(s.minutes or 10),
            increment = tostring(s.increment or 0),
            color = s.color or "random",
            ratingRange = s.rating_range or nil,
        },
    },
    function() end,
    function(ok, err)
        if self.closed or self.game_id then return end
        self.seek_open = false
        if not ok then
            self:_fail("Lichess seek failed: " .. tostring(err))
        else
            -- Lichess closes the seek after ~20s without a pairing; re-open it.
            UIManager:scheduleIn(1, function()
                if not self.closed and not self.game_id then self:startSeek() end
            end)
        end
    end)
end

function LichessBackend:cancelSeek()
    if self.seek_stream then
        self.seek_stream.close()
        self.seek_stream = nil
    end
    self.seek_open = false
end

-- -------------------------------------------------------------- game stream

function LichessBackend:attachGame(game_id)
    if self.closed then return end
    self.game_id = game_id
    self:cancelSeek()
    self:_openGameStream()
end

function LichessBackend:_openGameStream()
    if self.closed or not self.game_id then return end
    if self.game_stream then
        self.game_stream.close()
        self.game_stream = nil
    end

    self:emitLine("Connecting to Lichess game " .. self.game_id)
    self.game_stream = self.api:stream({
        path = "/api/board/game/stream/" .. self.game_id,
    },
    function(event) self:_onGameEvent(event) end,
    function(ok, err)
        if self.closed or self.finished then return end
        -- Wifi on these devices sleeps aggressively; reconnect and resync from
        -- the gameFull snapshot rather than assuming we did not miss a move.
        local delay = self.reconnect_delay
        self.reconnect_delay = math.min(MAX_RECONNECT_DELAY, delay * 2)
        self:emitLine("Lichess stream lost (" .. tostring(err or "closed")
            .. "); reconnecting in " .. delay .. "s")
        UIManager:scheduleIn(delay, function()
            if not self.closed and not self.finished then self:_openGameStream() end
        end)
    end)
end

function LichessBackend:_onGameEvent(event)
    if self.closed then return end
    self.reconnect_delay = RECONNECT_DELAY

    if event.type == "gameFull" then
        self:_onGameFull(event)
    elseif event.type == "gameState" then
        self:_onGameState(event)
    end
end

function LichessBackend:_onGameFull(full)
    local white_id = full.white and full.white.id
    local black_id = full.black and full.black.id
    -- Guard against a nil username matching a nil id: in a game against the
    -- Lichess AI the computer's side has neither `id` nor `name`, only `aiLevel`.
    if self.username and white_id == self.username then
        self.my_color = "white"
    elseif self.username and black_id == self.username then
        self.my_color = "black"
    else
        self:_fail("This Lichess game does not belong to your account.")
        return
    end

    self.initial_fen = full.initialFen
    if self.initial_fen == "startpos" then self.initial_fen = nil end

    local opponent = (self.my_color == "white") and full.black or full.white
    local opponent_name
    if opponent then
        if opponent.aiLevel then
            opponent_name = "Stockfish level " .. tostring(opponent.aiLevel)
        else
            opponent_name = opponent.name or opponent.id
        end
    end

    self:_trigger("game_started", {
        game_id = self.game_id,
        my_color = self.my_color,
        initial_fen = self.initial_fen,
        opponent_name = opponent_name or "Anonymous",
        opponent_rating = opponent and opponent.rating or nil,
        rated = full.rated and true or false,
        speed = full.speed,
    })

    -- uciok must land before the resync: main.lua guards launchUCI on it, so
    -- resyncing first would rebuild the board and then decline to wait for the
    -- opponent.
    if not self.state.uciok then
        self.state.uciok = true
        self:emitLine("uciok")
        self:_trigger("uciok")
    end

    -- Lichess is the source of truth. Hand main.lua the server's move list and let
    -- it rebuild the board rather than trusting whatever we had locally.
    local moves = splitMoves(full.state and full.state.moves)
    self.server_moves = moves
    self.local_moves = moves
    self.sent_upto = #moves
    self:_trigger("resync", self.initial_fen, moves)

    if full.state then self:_onGameState(full.state) end
end

function LichessBackend:_onGameState(state)
    if state.wtime and state.btime then
        self:_trigger("clock", state.wtime / 1000, state.btime / 1000)
    end

    local moves = splitMoves(state.moves)
    self.server_moves = moves

    if isPrefix(moves, self.local_moves) then
        -- The server list is a prefix of ours, so nothing has diverged. Either it
        -- is identical, or we are one move ahead with a POST still in flight --
        -- which is exactly what a clock-only gameState looks like. Do not resync
        -- here, or we would rip out our own unconfirmed move.
        if #moves == #self.local_moves then
            self.sent_upto = math.max(self.sent_upto, #moves)
        end
    elseif isPrefix(self.local_moves, moves) and #moves == #self.local_moves + 1 then
        -- Exactly one new move on top of ours: the opponent's. Only consume it
        -- while armed; otherwise leave local_moves behind so the next go() picks
        -- it up, rather than advancing past a move the board never played.
        if self.waiting then
            local uci = moves[#moves]
            self.waiting = false
            self.state.searching = false
            self.state.bestmove = uci
            self.local_moves = moves
            self.sent_upto = math.max(self.sent_upto, #moves)
            self:emitLine("bestmove " .. uci)
            self:_trigger("bestmove", uci)
        end
    else
        -- A takeback, or a gap we missed while disconnected. Rebuild from the
        -- server rather than guessing which moves we are short of.
        self.local_moves = moves
        self.sent_upto = #moves
        self.waiting = false
        self:_trigger("resync", self.initial_fen, moves)
    end

    -- Detect draw/takeback offers from the opponent.
    -- Lichess sends wdraw/bdraw/wtakeback/btakeback booleans on every gameState.
    -- We fire events only on false->true transitions to avoid repeated prompts.
    if self.my_color then
        local opp_draw = (self.my_color == "white") and state.bdraw or state.wdraw
        local opp_take = (self.my_color == "white") and state.btakeback or state.wtakeback
        local last_draw_key = (self.my_color == "white") and "_last_bdraw" or "_last_wdraw"
        local last_take_key = (self.my_color == "white") and "_last_btakeback" or "_last_wtakeback"

        if opp_draw and not self[last_draw_key] then
            self:_trigger("draw_offer_received")
        end
        self[last_draw_key] = opp_draw and true or false

        if opp_take and not self[last_take_key] then
            self:_trigger("takeback_offer_received")
        end
        self[last_take_key] = opp_take and true or false
    end

    local status = state.status
    if status and status ~= "started" and status ~= "created" then
        self.finished = true
        self.waiting = false
        self.state.searching = false
        self:_trigger("game_over", status, state.winner)
    end
end

-- --------------------------------------------------------- engine interface

--- main.lua hands us the complete local move list every time, so we can diff it
--- against what Lichess has and POST whatever is new and ours.
function LichessBackend:position(spec)
    spec = spec or {}
    if not self.game_id or not self.my_color then return end

    local list = splitMoves(spec.moves)
    self.local_moves = list

    local start = math.max(self.sent_upto, #self.server_moves)
    for i = start + 1, #list do
        -- Odd indices are White's moves.
        local is_white_move = (i % 2 == 1)
        local is_ours = (is_white_move == (self.my_color == "white"))
        if is_ours then
            self:_postMove(list[i])
        end
    end
    self.sent_upto = math.max(self.sent_upto, #list)
end

function LichessBackend:_postMove(uci)
    if not uci or uci == "" then return end
    self:emitLine("-> " .. uci)
    self.api:request({
        method = "POST",
        path = string.format("/api/board/game/%s/move/%s", self.game_id, uci),
    }, function(ok, _, _, err)
        if self.closed then return end
        if not ok then
            -- Lichess refused it: our board is now ahead of the real game.
            self.sent_upto = #self.server_moves
            self:_trigger("move_rejected", uci, err or "move rejected")
        end
    end)
end

--- "Search" online means waiting for the opponent.
function LichessBackend:go(opts)
    if self.finished then return end
    self.state.bestmove = nil
    self.state.searching = true
    self.waiting = true

    -- The opponent may have already moved while we were applying ours; the stream
    -- left it unconsumed because we were not armed yet.
    if isPrefix(self.local_moves, self.server_moves)
       and #self.server_moves == #self.local_moves + 1 then
        local uci = self.server_moves[#self.server_moves]
        self.local_moves = self.server_moves
        self.sent_upto = math.max(self.sent_upto, #self.server_moves)
        self.waiting = false
        self.state.searching = false
        self.state.bestmove = uci
        UIManager:nextTick(function()
            if not self.closed then self:_trigger("bestmove", uci) end
        end)
    end
end

function LichessBackend:stop()
    self.waiting = false
    self.state.searching = false
end

-- ------------------------------------------------------------ game controls

function LichessBackend:resign(cb)
    if not self.game_id then return end
    self.api:request({
        method = "POST",
        path = "/api/board/game/" .. self.game_id .. "/resign",
    }, cb)
end

function LichessBackend:abort(cb)
    if not self.game_id then return end
    self.api:request({
        method = "POST",
        path = "/api/board/game/" .. self.game_id .. "/abort",
    }, cb)
end

function LichessBackend:offerDraw(accept, cb)
    if not self.game_id then return end
    self.api:request({
        method = "POST",
        path = string.format("/api/board/game/%s/draw/%s",
            self.game_id, accept and "yes" or "no"),
    }, cb)
end

function LichessBackend:takeback(accept, cb)
    if not self.game_id then return end
    self.api:request({
        method = "POST",
        path = string.format("/api/board/game/%s/takeback/%s",
            self.game_id, accept and "yes" or "no"),
    }, cb)
end

function LichessBackend:quit()
    if self.closed then return end
    self.closed = true
    self.waiting = false
    self.state.searching = false
    self.state.uciok = false
    self:cancelSeek()
    if self.game_stream then self.game_stream.close(); self.game_stream = nil end
    if self.event_stream then self.event_stream.close(); self.event_stream = nil end
    self.api:closeAll()
end

--- main.lua talks to the engine with raw UCI strings in a few places.
function LichessBackend:handleCommand(command)
    if self.closed then return false end
    command = tostring(command or "")
    if command == "isready" then
        self:isready()
    elseif command == "quit" then
        self:quit()
    elseif command == "stop" then
        self:stop()
    end
    -- ucinewgame / setoption are deliberately no-ops online.
    return true
end

return LichessBackend
