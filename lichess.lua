-- Lichess HTTP client.
--
-- Every request is a `curl` subprocess whose stdout is drained non-blockingly by
-- Utils.reader/Utils.pollingLoop -- the same machinery uci.lua uses for Stockfish
-- stdout, so nothing here ever blocks the UI thread.
--
-- One-shot requests write the body to a temp file (-o) and print only
-- "%{http_code}" on stdout. That sidesteps Utils.reader's line buffering, which
-- would otherwise swallow a response body that has no trailing newline.
--
-- Streaming requests (-N) emit newline-delimited JSON, which Utils.reader handles
-- as-is.

local DataStorage = require("datastorage")
local Utils = require("utils")
local json = require("json")

local API_HOST = "https://lichess.org"

-- Lichess sends a blank keep-alive line every ~6s on an idle stream.
local STREAM_IDLE_TIMEOUT = 20
local POLL_INTERVAL = 0.25
-- Utils.reader() consumes at most 4 KB per call; drain harder than that per tick
-- so a large response does not trickle in at 16 KB/s.
local MAX_READS_PER_TICK = 64

local Lichess = {}
Lichess.__index = Lichess

local function tmpDir()
    return DataStorage:getSettingsDir()
end

-- Lichess personal access tokens are ASCII word characters; anything else is
-- either a paste accident or an attempt to inject into the curl config file.
function Lichess.sanitizeToken(token)
    token = tostring(token or ""):gsub("%s+", "")
    if token == "" then return nil, "empty token" end
    if token:match("[^%w_%-]") then return nil, "token contains invalid characters" end
    return token
end

function Lichess.probeCurl(curl_path)
    curl_path = curl_path or "curl"
    local ok, pipe = pcall(io.popen, "'" .. curl_path .. "' --version 2>/dev/null")
    if not ok or not pipe then return false, "could not run " .. curl_path end
    local first = pipe:read("*l")
    pipe:close()
    if not first or not first:match("^curl%s") then
        return false, curl_path .. " is not available on this device"
    end
    return true, first
end

function Lichess.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Lichess)
    self.curl = opts.curl or "curl"
    self.config_path = tmpDir() .. "/inkmate-lichess.curlrc"
    self.seq = 0
    self.handles = {}
    self:setToken(opts.token)
    return self
end

-- The token goes in a curl config file rather than argv: argv is readable through
-- `ps` on these devices.
function Lichess:setToken(token)
    local clean, err = Lichess.sanitizeToken(token)
    self.token = clean
    if not clean then return false, err end

    local f = io.open(self.config_path, "w")
    if not f then return false, "could not write curl config" end
    f:write(string.format('header = "Authorization: Bearer %s"\n', clean))
    f:write('header = "Accept: application/x-ndjson"\n')
    f:write("silent\n")
    f:write("show-error\n")
    f:close()
    os.execute(string.format("chmod 600 '%s' 2>/dev/null", self.config_path))
    return true
end

function Lichess:hasToken()
    return self.token ~= nil
end

function Lichess:_nextSeq()
    self.seq = self.seq + 1
    return self.seq
end

-- Shared teardown: close our end of the pipe and reap/kill the curl process.
local function closeHandle(self, handle)
    if handle.closed then return end
    handle.closed = true
    Utils.closeFd(handle.fd)
    handle.fd = nil
    if handle.wfd then
        Utils.closeFd(handle.wfd)
        handle.wfd = nil
    end
    Utils.pollProcess(handle.pid)
    Utils.terminateProcess(handle.pid)
    self.handles[handle] = nil
end

function Lichess:_spawn(args, on_line, on_exit)
    local pid, rfd, wfd = Utils.execInSubProcess(self.curl, args, true, false)
    if not pid or pid == false then
        on_exit(false, "could not start " .. self.curl)
        return nil
    end

    local handle = { pid = pid, fd = rfd, wfd = wfd, closed = false }
    handle.close = function() closeHandle(self, handle) end
    self.handles[handle] = true

    -- curl never reads stdin here; closing it avoids a hung child.
    Utils.closeFd(wfd)
    handle.wfd = nil

    local reader = Utils.reader(rfd, function(line)
        handle.last_rx = os.time()
        on_line(line)
    end)
    handle.last_rx = os.time()

    local fired = false
    local function finish(ok, err)
        if fired then return end
        fired = true
        handle.close()
        on_exit(ok, err)
    end

    Utils.pollingLoop(POLL_INTERVAL,
        function()
            if handle.closed then return end
            for _ = 1, MAX_READS_PER_TICK do
                local ok = reader()
                if ok == nil then break end      -- nothing waiting
                if ok == false then              -- EOF or pipe error
                    handle.eof = true
                    break
                end
            end
        end,
        function()
            if handle.closed then
                -- Closed from the outside (quit/reconnect): no callback.
                fired = true
                return false
            end
            if handle.eof or Utils.pollProcess(handle.pid) then
                finish(true)
                return false
            end
            -- idle_timeout of 0 or nil means "never time out".
            if handle.idle_timeout and handle.idle_timeout > 0
               and os.time() - (handle.last_rx or 0) > handle.idle_timeout then
                finish(false, "connection went quiet")
                return false
            end
            return true
        end)

    return handle
end

--- One-shot request. cb(ok, decoded_body, http_code, err)
-- opts = { method = "GET"|"POST", path = "/api/...", form = { k = v }, query = "a=b" }
function Lichess:request(opts, cb)
    cb = cb or function() end
    if not self.token then
        cb(false, nil, nil, "no Lichess token configured")
        return nil
    end

    local body_path = string.format("%s/inkmate-lichess-%d.json", tmpDir(), self:_nextSeq())
    local url = API_HOST .. opts.path .. (opts.query and ("?" .. opts.query) or "")

    local args = {
        "-K", self.config_path,
        "-o", body_path,
        "-w", "%{http_code}\n",
        "--max-time", tostring(opts.timeout or 20),
        "-X", opts.method or "GET",
    }
    if opts.form then
        for k, v in pairs(opts.form) do
            args[#args + 1] = "--data-urlencode"
            args[#args + 1] = string.format("%s=%s", k, tostring(v))
        end
    end
    args[#args + 1] = url

    local http_code, stderr_text
    self:_spawn(args,
        function(line)
            local code = line:match("^(%d%d%d)%s*$")
            if code then
                http_code = tonumber(code)
            elseif line ~= "" then
                stderr_text = line     -- curl --show-error writes here
            end
        end,
        function(ok, err)
            local raw
            local f = io.open(body_path, "r")
            if f then
                raw = f:read("*a")
                f:close()
            end
            os.remove(body_path)

            if not ok then
                cb(false, nil, http_code, err or stderr_text or "request failed")
                return
            end
            if not http_code then
                cb(false, nil, nil, stderr_text or "no response from Lichess")
                return
            end

            local data
            if raw and raw ~= "" then
                local decoded_ok, decoded = pcall(json.decode, raw)
                if decoded_ok then
                    data = decoded
                else
                    -- Fallback for NDJSON: split by newline and decode each line
                    data = {}
                    for line in raw:gmatch("[^\r\n]+") do
                        local ok, obj = pcall(json.decode, line)
                        if ok and type(obj) == "table" then
                            table.insert(data, obj)
                        end
                    end
                    if #data == 0 then data = nil end -- Failed to parse any valid JSON lines
                end
            end

            if http_code >= 200 and http_code < 300 then
                cb(true, data, http_code)
            else
                -- Most errors are {"error": "some string"}, but parameter
                -- validation returns {"error": {field: [...]}} -- only take the
                -- string form, or the message renders as "table: 0x...".
                local msg
                if type(data) == "table" and type(data.error) == "string" then
                    msg = data.error
                end
                msg = msg or stderr_text or ("HTTP " .. tostring(http_code))
                cb(false, data, http_code, msg)
            end
        end)

    return true
end

--- Long-lived NDJSON stream. on_event(decoded_object) fires per non-blank line;
-- on_close(ok, err) fires when curl exits or the stream goes quiet.
-- Returns a handle with :close().
function Lichess:stream(opts, on_event, on_close)
    on_close = on_close or function() end
    if not self.token then
        on_close(false, "no Lichess token configured")
        return nil
    end

    local args = {
        "-K", self.config_path,
        "-N",
        "--no-buffer",
        "-X", opts.method or "GET",
    }
    if opts.form then
        for k, v in pairs(opts.form) do
            args[#args + 1] = "--data-urlencode"
            args[#args + 1] = string.format("%s=%s", k, tostring(v))
        end
    end
    args[#args + 1] = API_HOST .. opts.path

    local handle = self:_spawn(args,
        function(line)
            -- Keep-alive lines are blank; they still refresh last_rx above.
            if line:match("^%s*$") then return end
            local ok, decoded = pcall(json.decode, line)
            if ok and type(decoded) == "table" then
                on_event(decoded)
            end
        end,
        on_close)

    if handle then
        handle.idle_timeout = opts.idle_timeout or STREAM_IDLE_TIMEOUT
    end
    return handle
end

function Lichess:closeAll()
    for handle in pairs(self.handles) do
        handle.close()
    end
    self.handles = {}
end

Lichess.API_HOST = API_HOST

return Lichess
