--[[
calibre companion for a jailbroken Kindle.

A headless client for calibre's "Smart Device App" wireless driver. Tap the
"calibre" scriptlet: this finds calibre on the LAN, connects, and the Kindle
shows up in calibre exactly like a USB device (on-device ticks, Send to device,
delete, device book list). Books land in /mnt/us/documents as native Kindle
files; the stock scanner indexes them. No KOReader UI is involved -- only its
bundled LuaJIT/luasocket/rapidjson runtime is used.

Protocol references: calibre src/calibre/devices/smart_device_app/driver.py
and KOReader plugins/calibre.koplugin/wireless.lua.

Runtime: bundled LuaJIT + luasocket + lfs (runtime/<abi>/), dkjson (pure Lua)
via json.lua; FBInk for on-screen messages. Nothing from KOReader is needed.
--]]

local socket = require("socket")
local rapidjson = require("json")   -- dkjson facade with a rapidjson-shaped API (see json.lua)
local lfs = require("lfs")

local HERE = os.getenv("COMPANION_DIR") or "/mnt/us/calibre-wireless"
local ok_cfg, cfg = pcall(dofile, HERE .. "/config.lua")
if not ok_cfg or type(cfg) ~= "table" then cfg = {} end

local C = {
    inbox         = cfg.inbox or "/mnt/us/documents",
    formats       = cfg.formats or { "azw3", "mobi", "azw", "kfx", "prc", "azw4", "pdf", "txt" },
    device_name   = cfg.device_name or "Kindle",
    calibre_host  = cfg.calibre_host,          -- nil = discover by broadcast
    calibre_port  = cfg.calibre_port,
    keep_awake    = cfg.keep_awake or "charging",  -- "charging" | "always" | "never"
    max_idle_min  = cfg.max_idle_minutes or 180,   -- quit if no calibre for this long
    fbink         = cfg.fbink or os.getenv("FBINK") or "/var/local/kmc/bin/fbink",
    show_messages = cfg.show_messages ~= false,
}

local DB_FILE    = HERE .. "/books.json"
local DRIVE_FILE = HERE .. "/driveinfo.json"
local LOG_FILE   = HERE .. "/log.txt"
local INCOMING   = "/mnt/us/.calibre_incoming"
local APP_NAME   = "KindleCompanion"
local APP_VER    = 100

local BROADCAST_PORTS = { 54982, 48123, 39001, 44044, 59678 }
local OP = {
    OK = 0, SET_CALIBRE_DEVICE_INFO = 1, SET_CALIBRE_DEVICE_NAME = 2,
    GET_DEVICE_INFORMATION = 3, TOTAL_SPACE = 4, FREE_SPACE = 5,
    GET_BOOK_COUNT = 6, SEND_BOOKLISTS = 7, SEND_BOOK = 8,
    GET_INITIALIZATION_INFO = 9, BOOK_DONE = 11, NOOP = 12, DELETE_BOOK = 13,
    GET_BOOK_FILE_SEGMENT = 14, GET_BOOK_METADATA = 15, SEND_BOOK_METADATA = 16,
    DISPLAY_MESSAGE = 17, CALIBRE_BUSY = 18, SET_LIBRARY_INFO = 19, ERROR = 20,
    GET_COLLECTIONS = 21, UPDATE_COLLECTIONS = 22,
}
local OPNAME = {}
for k, v in pairs(OP) do OPNAME[v] = k end

---------------------------------------------------------------- utilities ----
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = os.date("%Y-%m-%d %H:%M:%S ") .. table.concat(parts, " ")
    local f = io.open(LOG_FILE, "a")
    if f then f:write(line, "\n"); f:close() end
end

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'"
end

local function show(msg)
    log("SHOW:", msg)
    if not C.show_messages then return end
    if lfs.attributes(HERE .. "/ui_open", "mode") then return end  -- the app owns the screen
    if lfs.attributes(C.fbink, "mode") then
        os.execute(C.fbink .. " -q -m -y -2 -- " .. sh_quote(msg) .. " >/dev/null 2>&1")
    end
end

local function popen_line(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return nil end
    local out = p:read("*a") or ""
    p:close()
    return out
end

local function file_exists(p) return lfs.attributes(p, "mode") == "file" end
local function dir_exists(p) return lfs.attributes(p, "mode") == "directory" end

local function mkdir_p(path)
    local cur = ""
    for part in path:gmatch("[^/]+") do
        cur = cur .. "/" .. part
        if not dir_exists(cur) then lfs.mkdir(cur) end
    end
end

local function basename(p) return p:match("([^/]+)$") or p end
local function dirname(p) return p:match("^(.*)/[^/]*$") or "." end
local function ext_of(p) return (p:match("%.([^./]+)$") or ""):lower() end

local function df_bytes()
    local out = popen_line("df -k " .. sh_quote("/mnt/us") .. " | tail -1") or ""
    local fs, total, used, avail = out:match("(%S+)%s+(%d+)%s+(%d+)%s+(%d+)")
    if not total then return 1024 ^ 3, 1024 ^ 3 end
    return tonumber(total) * 1024, tonumber(avail) * 1024
end

local function is_charging()
    local out = popen_line("lipc-get-prop com.lab126.powerd isCharging") or ""
    return out:match("1") ~= nil
end

local awake_held = false
local awake_last_set = 0
local function hold_awake(on)
    -- re-assert every 60s even if unchanged: the UI and powerd can race us
    if on == awake_held and (socket.gettime() - awake_last_set) < 60 then return end
    awake_held = on
    awake_last_set = socket.gettime()
    os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (on and "1" or "0") .. " >/dev/null 2>&1")
end

local function want_awake()
    if file_exists(HERE .. "/ui_open") then return true end  -- someone is looking at the app
    if C.keep_awake == "always" then return true end
    if C.keep_awake == "charging" then return is_charging() end
    return false
end

---------------------------------------------------------- UI state/commands ----
-- The on-screen app (ui.lua) reads state.json and writes cmd.* files.
local UI = {
    status = "starting",
    host = nil, calibre_name = nil,
    started_at = os.time(),
    last_activity = socket.gettime(),
    forever = false,
    last_book = nil, received_count = 0,
    this_book = nil, total_books = nil,
}

local function ui_deadline()
    if UI.forever then return nil end
    return math.floor(UI.last_activity + C.max_idle_min * 60)
end

local function write_state()
    local cands = rapidjson.array({})
    for i, c in ipairs(UI.candidates or {}) do
        cands[i] = rapidjson.object({ host = c.host, port = c.port, name = c.name or rapidjson.null })
    end
    local t = rapidjson.object({
        status = UI.status,
        candidates = cands,
        host = UI.host or rapidjson.null,
        port = UI.port or rapidjson.null,
        calibre_name = UI.calibre_name or rapidjson.null,
        started_at = UI.started_at,
        deadline = ui_deadline() or rapidjson.null,
        forever = UI.forever,
        last_book = UI.last_book or rapidjson.null,
        received_count = UI.received_count,
        this_book = UI.this_book or rapidjson.null,
        total_books = UI.total_books or rapidjson.null,
        pid_alive = true,
        updated = os.time(),
    })
    rapidjson.dump(t, HERE .. "/state.json.tmp")
    os.rename(HERE .. "/state.json.tmp", HERE .. "/state.json")
end

local function set_status(st, extra)
    UI.status = st
    if extra then for k, v in pairs(extra) do UI[k] = v end end
    write_state()
end

local stop_requested = false
local switch_requested = false   -- UI picked a (different) calibre: {host=,port=}
-- Called often (every idle tick): apply UI commands, refresh state & awake hold.
local function poll_commands()
    local f = io.open(HERE .. "/cmd.forever", "r")
    if f then
        local v = f:read("*a"); f:close()
        os.remove(HERE .. "/cmd.forever")
        UI.forever = (v:match("1") ~= nil)
        log("forever =", UI.forever)
        write_state()
    end
    if file_exists(HERE .. "/cmd.stop") then
        os.remove(HERE .. "/cmd.stop")
        stop_requested = true
    end
    -- cmd.connect: {"host":"192.168.1.20","port":9090} from the chooser/keypad
    local cf = io.open(HERE .. "/cmd.connect", "r")
    if cf then
        local v = cf:read("*a"); cf:close()
        os.remove(HERE .. "/cmd.connect")
        local ok, t = pcall(rapidjson.decode, v)
        if ok and type(t) == "table" and type(t.host) == "string" and tonumber(t.port) then
            switch_requested = { host = t.host, port = tonumber(t.port) }
            log("UI chose calibre at", t.host, t.port)
        end
    end
    hold_awake(want_awake())
    -- keep the timer fresh for the UI once a second-ish
    write_state()
end

local function write_pid()
    local f = io.open(HERE .. "/pid", "w")
    if f then f:write(tostring(popen_line("echo $PPID"):match("%d+") or ""), "\n"); f:close() end
end

------------------------------------------------------------------ book db ----
local DB = { books = rapidjson.array({}) }

local function load_json(path, default)
    if not file_exists(path) then return default end
    local v = rapidjson.load(path)
    return v or default
end

local function save_json(path, v)
    local tmp = path .. ".tmp"
    if rapidjson.dump(v, tmp, { pretty = true }) then os.rename(tmp, path) end
end

local function db_load()
    local v = load_json(DB_FILE, nil)
    if type(v) == "table" then DB.books = v else DB.books = rapidjson.array({}) end
end

local function db_save() save_json(DB_FILE, DB.books) end

local function db_index(lpath)
    for i, b in ipairs(DB.books) do
        if b.lpath == lpath then return i end
    end
end

local function db_upsert(rec)
    local i = db_index(rec.lpath)
    if i then DB.books[i] = rec else DB.books[#DB.books + 1] = rec end
end

local function db_remove(lpath)
    local i = db_index(lpath)
    if i then table.remove(DB.books, i) end
end

local function format_set()
    local s = {}
    for _, e in ipairs(C.formats) do s[e:lower()] = true end
    return s
end

-- calibre's USB driver keeps /mnt/us/metadata.calibre (lpaths like
-- "documents/Author/Title.azw3") with full metadata + uuids for books it sent
-- over the cable. Use it to describe books the companion never received itself,
-- so calibre matches them to its library (green ticks) instead of "Unknown".
local USB_CACHE = "/mnt/us/metadata.calibre"
local usb_cache_index

local function usb_cache_lookup(lpath)
    if usb_cache_index == nil then
        usb_cache_index = {}
        if file_exists(USB_CACHE) then
            local ok, books = pcall(rapidjson.load, USB_CACHE)
            if ok and type(books) == "table" then
                local prefix = C.inbox:gsub("^/mnt/us/", "") .. "/"
                for _, b in ipairs(books) do
                    if type(b) == "table" and type(b.lpath) == "string" and b.lpath:sub(1, #prefix) == prefix then
                        usb_cache_index[b.lpath:sub(#prefix + 1)] = b
                    end
                end
                log("usb metadata.calibre indexed:", #books, "entries")
            end
        end
    end
    return usb_cache_index[lpath]
end

-- "Title - Author.azw3" inside an "Author Sort/" folder (calibre's default
-- send template) -> title, authors.
local function guess_from_name(lrel)
    local name = basename(lrel):gsub("%.[^.]+$", "")
    local title, author = name:match("^(.-)%s+%-%s+([^%-]+)$")
    if not title then title = name end
    if not author then
        local folder = lrel:match("^(.-)/")
        if folder then
            local last, first = folder:match("^(.-),%s*(.+)$")
            author = first and (first .. " " .. last) or folder
        end
    end
    return title, author or "Unknown"
end

-- Make sure every book file in the inbox has a record (minimal if calibre never
-- told us about it) and drop records whose files are gone.
local function db_sync_with_disk()
    local fmts = format_set()
    local seen = {}
    local function walk(dir, rel)
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local full = dir .. "/" .. name
                local lrel = rel and (rel .. "/" .. name) or name
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    if not name:match("%.sdr$") then walk(full, lrel) end
                elseif mode == "file" and fmts[ext_of(name)] then
                    seen[lrel] = true
                    local i = db_index(lrel)
                    local rec = i and DB.books[i]
                    local needs = (not rec) or rec.uuid == nil or rec.uuid == rapidjson.null
                    if needs then
                        local attr = lfs.attributes(full)
                        local cached = usb_cache_lookup(lrel)
                        if cached then
                            local copy = {}
                            for k, v in pairs(cached) do copy[k] = v end
                            copy.lpath = lrel
                            copy.size = attr.size
                            db_upsert(copy)
                        elseif not rec then
                            local title, author = guess_from_name(lrel)
                            db_upsert({
                                lpath = lrel,
                                title = title,
                                authors = rapidjson.array({ author }),
                                size = attr.size,
                                uuid = rapidjson.null,
                                last_modified = rapidjson.null,
                            })
                        end
                    end
                end
            end
        end
    end
    if dir_exists(C.inbox) then walk(C.inbox, nil) end
    for i = #DB.books, 1, -1 do
        if not seen[DB.books[i].lpath] then table.remove(DB.books, i) end
    end
    db_save()
end

------------------------------------------------------------------ framing ----
local Conn = {}
Conn.__index = Conn

function Conn.new(tcp)
    return setmetatable({ tcp = tcp }, Conn)
end

function Conn:send_raw(data)
    local pos, total = 1, #data
    while pos <= total do
        local sent, err, last = self.tcp:send(data, pos)
        if sent then pos = sent + 1
        elseif err == "timeout" then pos = (last or (pos - 1)) + 1
        else error("send failed: " .. tostring(err)) end
    end
end

function Conn:send_json(opname, data)
    local payload = rapidjson.encode(rapidjson.array({ OP[opname], data }))
    log("->", opname, #payload > 300 and (payload:sub(1, 300) .. "...") or payload)
    self:send_raw(tostring(#payload) .. payload)
end

function Conn:recv_exact(n)
    local chunks, got = {}, 0
    while got < n do
        local data, err, partial = self.tcp:receive(math.min(65536, n - got))
        if data then
            chunks[#chunks + 1] = data; got = got + #data
        elseif err == "timeout" then
            if partial and #partial > 0 then chunks[#chunks + 1] = partial; got = got + #partial end
            if self.idle_deadline and socket.gettime() > self.idle_deadline then error("idle timeout") end
            if not self.in_transfer then
                poll_commands()
                if stop_requested then error("stop requested") end
            end
        else
            error("receive failed: " .. tostring(err))
        end
    end
    return table.concat(chunks)
end

-- messages look like:  34[0, {"key": value}]
function Conn:recv_json()
    local digits = ""
    while true do
        local ch = self:recv_exact(1)
        if ch == "[" then break end
        if not ch:match("%d") then error("protocol error: bad length prefix " .. tostring(ch)) end
        digits = digits .. ch
        if #digits > 12 then error("protocol error: length prefix too long") end
    end
    local size = tonumber(digits)
    if not size or size < 1 then error("protocol error: bad size") end
    local body = "[" .. self:recv_exact(size - 1)
    local msg, err = rapidjson.decode(body)
    if not msg then error("json decode failed: " .. tostring(err)) end
    return msg[1], msg[2] or {}
end

------------------------------------------------------------ discovery -------
local function parse_banner(dgram)
    local name, replied_port = dgram:match("calibre wireless device client %(on (.-)%);%d*,(%d+)$")
    if replied_port then return tonumber(replied_port), name end
end

-- Our Wi-Fi IPv4 (for the subnet-directed broadcast and the unicast sweep).
local function wlan_ip()
    local out = popen_line("ip -4 addr show wlan0") or ""
    return out:match("inet (%d+%.%d+%.%d+%.%d+)")
end

-- calibre replies to any UDP "hello" on one of its broadcast ports. Limited
-- broadcast is often dropped by PC firewalls, so after that we try the
-- subnet-directed broadcast and finally a unicast sweep of the local /24
-- (254 tiny packets): unicast gets through where broadcast does not.
-- Returns a list of every calibre that answered: { {host=,port=,name=}, ... }
local function discover_all()
    local found, seen = {}, {}
    local udp = socket.udp4()
    if not udp then return found end
    udp:setoption("broadcast", true)
    udp:setsockname("*", 0)
    local ip = wlan_ip()
    local prefix = ip and ip:match("^(%d+%.%d+%.%d+)%.")
    local targets = { "255.255.255.255" }
    if prefix then targets[#targets + 1] = prefix .. ".255" end

    -- collect replies for `seconds`, keep going after the first so that
    -- several calibre instances on the LAN all show up
    local function listen(seconds)
        local deadline = socket.gettime() + seconds
        while true do
            local left = deadline - socket.gettime()
            if left <= 0 then break end
            udp:settimeout(left)
            local dgram, host = udp:receivefrom()
            if dgram and host then
                local port, name = parse_banner(dgram)
                local key = host .. ":" .. tostring(port)
                if port and not seen[key] then
                    seen[key] = true
                    found[#found + 1] = { host = host, port = port, name = name }
                end
            else
                break
            end
        end
    end

    for _, port in ipairs(BROADCAST_PORTS) do
        for _, t in ipairs(targets) do udp:sendto("hello", t, port) end
        listen(1.5)
        if #found > 0 then break end
    end

    if #found == 0 and prefix then
        log("discovery: broadcast got no reply, sweeping " .. prefix .. ".0/24")
        for i = 1, 254 do
            local t = prefix .. "." .. i
            if t ~= ip then udp:sendto("hello", t, BROADCAST_PORTS[1]) end
        end
        listen(2.5)
    end
    udp:close()
    return found
end

local function discover()
    local list = discover_all()
    if list[1] then return list[1].host, list[1].port, list[1].name end
end

-- Remember where calibre was so the next session can skip discovery.
local LAST_FILE = HERE .. "/last_calibre.json"
local function last_calibre()
    local v = load_json(LAST_FILE, nil)
    if type(v) == "table" and type(v.host) == "string" and tonumber(v.port) then
        return v.host, tonumber(v.port)
    end
end
local function remember_calibre(host, port)
    save_json(LAST_FILE, { host = host, port = port, when = os.time() })
end

------------------------------------------------------------- handlers -------
local S = {}  -- per-connection state

local function device_store_uuid()
    local d = load_json(DRIVE_FILE, {})
    if type(d) ~= "table" then d = {} end
    if not d.device_store_uuid then
        local hex = ("%08x%04x%04x%04x%012x"):format(
            math.random(0, 0xffffffff), math.random(0, 0xffff), math.random(0, 0xffff),
            math.random(0, 0xffff), math.random(0, 0xffffffffffff))
        d.device_store_uuid = hex:sub(1, 8) .. "-" .. hex:sub(9, 12) .. "-" .. hex:sub(13, 16)
            .. "-" .. hex:sub(17, 20) .. "-" .. hex:sub(21, 32)
        save_json(DRIVE_FILE, d)
    end
    return d.device_store_uuid, d
end

local H = {}

H.GET_INITIALIZATION_INFO = function(conn, arg)
    S.calibre_version = arg.calibre_version
    local ext_lens = rapidjson.object({})
    local exts = rapidjson.array({})
    for i, e in ipairs(C.formats) do exts[i] = e; ext_lens[e] = 37 end
    conn:send_json("OK", {
        appName = APP_NAME,
        acceptedExtensions = exts,
        cacheUsesLpaths = true,
        canAcceptLibraryInfo = true,
        canDeleteMultipleBooks = true,
        canReceiveBookBinary = true,
        canSendOkToSendbook = true,
        canStreamBooks = true,
        canStreamMetadata = true,
        canUseCachedMetadata = true,
        ccVersionNumber = APP_VER,
        coverHeight = 240,
        deviceKind = "Kindle",
        deviceName = C.device_name,
        extensionPathLengths = ext_lens,
        passwordHash = "",
        maxBookContentPacketLen = 4096,
        useUuidFileNames = false,
        versionOK = true,
    })
end

H.GET_DEVICE_INFORMATION = function(conn)
    local uuid = device_store_uuid()
    conn:send_json("OK", {
        device_info = { device_store_uuid = uuid, device_name = C.device_name },
        version = tostring(APP_VER),
        device_version = tostring(APP_VER),
    })
end

H.SET_CALIBRE_DEVICE_INFO = function(conn, arg)
    local _, d = device_store_uuid()
    for k, v in pairs(arg) do d[k] = v end
    d.device_name = C.device_name
    save_json(DRIVE_FILE, d)
    conn:send_json("OK", rapidjson.object({}))
end

H.SET_CALIBRE_DEVICE_NAME = function(conn) conn:send_json("OK", rapidjson.object({})) end
H.SET_LIBRARY_INFO = function(conn) conn:send_json("OK", rapidjson.object({})) end

H.TOTAL_SPACE = function(conn)
    local total = df_bytes()
    conn:send_json("OK", { total_space_on_device = total })
end

H.FREE_SPACE = function(conn)
    local _, free = df_bytes()
    conn:send_json("OK", { free_space_on_device = free })
end

H.GET_BOOK_COUNT = function(conn)
    db_sync_with_disk()
    conn:send_json("OK", { willStream = true, willScan = true, count = #DB.books })
    for i, b in ipairs(DB.books) do
        conn:send_json("OK", {
            priKey = i,
            uuid = b.uuid == nil and rapidjson.null or b.uuid,
            lpath = b.lpath,
            last_modified = b.last_modified == nil and rapidjson.null or b.last_modified,
        })
    end
end

H.NOOP = function(conn, arg)
    if arg.ejecting then
        conn:send_json("OK", rapidjson.object({}))
        S.ejected = true
        return
    end
    if arg.count then
        S.pending = arg.count
        return
    end
    if arg.priKey then
        local b = DB.books[arg.priKey]
        conn:send_json("OK", b or rapidjson.object({}))
        return
    end
    conn:send_json("OK", rapidjson.object({}))
end

H.SEND_BOOK = function(conn, arg)
    local lpath = arg.lpath
    local length = tonumber(arg.length) or 0
    local target = C.inbox .. "/" .. lpath
    local _, free = df_bytes()
    if free < length + 128 * 1024 then
        conn:send_json("ERROR", { message = "No space left on the Kindle for " .. lpath })
        return
    end
    mkdir_p(INCOMING)
    mkdir_p(dirname(target))
    local staged = INCOMING .. "/" .. basename(lpath) .. ".part"
    local f = assert(io.open(staged, "wb"))
    conn:send_json("OK", rapidjson.object({}))
    local nice = basename(lpath):gsub("%.[^.]+$", "")
    local meta_title = type(arg.metadata) == "table" and arg.metadata.title
    if type(meta_title) == "string" and #meta_title > 0 then nice = meta_title end
    set_status("receiving", { this_book = (arg.thisBook or 0) + 1, total_books = arg.totalBooks or 1, last_book = nice })
    show(("calibre: receiving %d/%d %s"):format((arg.thisBook or 0) + 1, arg.totalBooks or 1, basename(lpath)))
    conn.in_transfer = true
    local remaining = length
    while remaining > 0 do
        local chunk = conn:recv_exact(math.min(65536, remaining))
        f:write(chunk)
        remaining = remaining - #chunk
    end
    conn.in_transfer = false
    f:close()
    os.remove(target)
    assert(os.rename(staged, target))
    local rec = arg.metadata or {}
    rec.lpath = lpath
    rec.size = length
    db_upsert(rec)
    db_save()
    log("received", lpath, length)
    UI.received_count = UI.received_count + 1
    UI.last_activity = socket.gettime()
    set_status("connected", { last_book = nice })
    show(("calibre: received %s"):format(basename(lpath)))
end

H.SEND_BOOKLISTS = function() end  -- no reply expected

H.SEND_BOOK_METADATA = function(conn, arg)
    local rec = arg.data
    if type(rec) == "table" and rec.lpath then
        local i = db_index(rec.lpath)
        if i then
            local size = DB.books[i].size
            DB.books[i] = rec
            if rec.size == nil then DB.books[i].size = size end
        else
            db_upsert(rec)
        end
    end
    if arg.index ~= nil and arg.count ~= nil and (arg.index + 1) == arg.count then db_save() end
end

H.DELETE_BOOK = function(conn, arg)
    conn:send_json("OK", rapidjson.object({}))
    for _, lpath in ipairs(arg.lpaths or {}) do
        local i = db_index(lpath)
        local uuid = (i and DB.books[i].uuid) or "none"
        if not lpath:find("%.%.") then
            local full = C.inbox .. "/" .. lpath
            os.remove(full)
            local base = full:gsub("%.[^./]+$", "")
            os.execute("rm -rf -- " .. sh_quote(base .. ".sdr") .. " " .. sh_quote(full .. ".sdr") .. " >/dev/null 2>&1")
            log("deleted", lpath)
        end
        db_remove(lpath)
        conn:send_json("OK", { uuid = uuid })
    end
    db_save()
    show("calibre: deleted " .. tostring(#(arg.lpaths or {})) .. " book(s)")
end

H.GET_BOOK_FILE_SEGMENT = function(conn, arg)
    local full = C.inbox .. "/" .. (arg.lpath or "")
    local size = lfs.attributes(full, "size")
    local f = size and io.open(full, "rb")
    if not f then
        conn:send_json("NOOP", rapidjson.object({}))
        return
    end
    conn:send_json("OK", { fileLength = size })
    while true do
        local data = f:read(65536)
        if not data then break end
        conn:send_raw(data)
    end
    f:close()
end

H.DISPLAY_MESSAGE = function(conn, arg)
    log("DISPLAY_MESSAGE", rapidjson.encode(arg))
    if arg.messageKind == 1 then
        show("calibre: password required -- set calibre_password in config")
    elseif arg.message then
        show("calibre: " .. tostring(arg.message))
    end
    conn:send_json("OK", rapidjson.object({}))
end

H.CALIBRE_BUSY = function(conn, arg)
    show("calibre is busy with another device: " .. tostring(arg.otherDevice))
    S.busy = true
end

------------------------------------------------------------------ session ----
-- Ask a known calibre host for its banner (gives us the PC's name) without
-- broadcasting. Used when calibre_host is configured.
local function probe_name(host)
    local udp = socket.udp4()
    if not udp then return nil end
    udp:settimeout(1.5)
    local ok = udp:sendto("hello", host, 54982)
    local name
    if ok then
        local dgram = udp:receivefrom()
        if dgram then name = dgram:match("calibre wireless device client %(on (.-)%);") end
    end
    udp:close()
    return name
end

local function session(host, port, calibre_name)
    if not calibre_name then calibre_name = probe_name(host) end
    local tcp = assert(socket.tcp())
    tcp:settimeout(10)
    local okc, err = tcp:connect(host, port)
    if not okc then
        tcp:close()
        return false, "connect failed: " .. tostring(err)
    end
    tcp:settimeout(1)  -- poll in 1s slices; idle handled via deadline
    tcp:setoption("tcp-nodelay", true)
    local conn = Conn.new(tcp)
    S = {}
    log("connected to", host, port)
    show("calibre: connected to " .. host)
    remember_calibre(host, port)
    UI.last_activity = socket.gettime()
    set_status("connected", { host = host, port = port, calibre_name = calibre_name })
    local result, serr = pcall(function()
        while not S.ejected and not S.busy do
            conn.idle_deadline = socket.gettime() + 15 * 60
            local opcode, arg = conn:recv_json()
            local name = OPNAME[opcode] or tostring(opcode)
            log("<-", name)
            UI.last_activity = socket.gettime()
            local h = H[name]
            if h then h(conn, arg) else log("unhandled opcode", name) end
            poll_commands()
            if stop_requested or switch_requested then break end
        end
    end)
    tcp:close()
    UI.last_activity = socket.gettime()
    set_status(S.busy and "busy" or "searching", { host = nil, this_book = nil, total_books = nil })
    if not result then
        log("session ended:", serr)
        show("calibre: disconnected")
        return false, serr
    end
    show(S.busy and "calibre: busy, will retry" or "calibre: disconnected")
    return true
end

--------------------------------------------------------------------- main ----
local function main()
    math.randomseed(os.time())
    mkdir_p(HERE)
    db_load()
    write_pid()
    log("companion start; inbox", C.inbox, "formats", table.concat(C.formats, ","))
    os.remove(HERE .. "/cmd.stop")
    set_status("searching")
    show("calibre: searching for calibre on Wi-Fi...")
    local last_show = 0
    -- sleep in 1s slices so UI commands (quit / forever) are picked up quickly
    local function idle(seconds)
        for _ = 1, seconds do
            poll_commands()
            if stop_requested or file_exists(HERE .. "/stop") then return true end
            if switch_requested then return false end   -- the app picked a calibre: go now
            socket.sleep(1)
        end
        return false
    end
    while true do
        if stop_requested or file_exists(HERE .. "/stop") then
            os.remove(HERE .. "/stop")
            log("stop requested"); break
        end
        local host, port, cname = C.calibre_host, C.calibre_port, nil
        if switch_requested then
            -- The app picked one (chooser or typed address).
            host, port = switch_requested.host, switch_requested.port
            switch_requested = false
            cname = probe_name(host)
        elseif not host then
            -- Who is out there? Publish everyone so the app can offer a choice.
            local cands = discover_all()
            UI.candidates = cands
            local lh, lp = last_calibre()
            local remembered
            for _, c in ipairs(cands) do
                if c.host == lh and c.port == lp then remembered = c end
            end
            if #cands == 1 then
                host, port, cname = cands[1].host, cands[1].port, cands[1].name
            elseif remembered then
                host, port, cname = remembered.host, remembered.port, remembered.name
            elseif #cands > 1 then
                -- Several calibres and no memory of which: let the user pick.
                set_status("choose")
                show("calibre: several calibre instances found - open the app to choose")
            elseif lh and lp then
                -- Nothing answered discovery; try the remembered address directly.
                local name = probe_name(lh)
                if name then host, port, cname = lh, lp, name end
            end
        end
        if host and port then
            local okses, err = session(host, port, cname)
            if not okses then
                log("retrying after error:", err)
                -- Fixed address didn't answer? Maybe the PC's IP changed: try discovery.
                if C.calibre_host and tostring(err):match("connect failed") then
                    local dh, dp, dn = discover()
                    if dh and dp and (dh ~= host or dp ~= port) then
                        log("discovered calibre at", dh, dp, "instead of configured", host, port)
                        okses, err = session(dh, dp, dn)
                    end
                end
            end
            if idle(3) then break end
        else
            if UI.status ~= "choose" and socket.gettime() - last_show > 60 then
                show("calibre: waiting for calibre (Connect/share > Start wireless device connection)")
                last_show = socket.gettime()
            end
            if idle(5) then break end
        end
        local deadline = ui_deadline()
        if deadline and os.time() > deadline then
            show("calibre companion: idle, exiting")
            log("idle deadline reached")
            break
        end
    end
    set_status("stopped")
    hold_awake(false)
    os.remove(HERE .. "/pid")
    log("companion exit")
end

local okm, errm = pcall(main)
if not okm then
    log("FATAL", errm)
    show("calibre companion crashed: " .. tostring(errm):sub(1, 80))
    hold_awake(false)
    os.remove(HERE .. "/pid")
    os.exit(1)
end
