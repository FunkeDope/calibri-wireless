--[[
calibre wireless -- the on-screen app.

Full-screen e-ink UI drawn with FBInk, touch read straight from /dev/input.
Talks to the daemon (companion.lua) through small files in the install dir:
  state.json   written by the daemon  (status, host, timers, candidates ...)
  cmd.forever  written by the UI      ("1"/"0")
  cmd.stop     written by the UI      (daemon exits)
  cmd.connect  written by the UI      ({"host":..,"port":..} chooser / keypad)
  ui.quit      written by anyone      (UI closes gracefully)
  ui_open      exists while the UI is up (daemon keeps the Kindle awake)

Screens: main (status + controls), choose (every calibre found on the LAN),
keypad (type an address by hand).

Device independence:
  * screen size and dark mode come from the framebuffer's variable screen
    info (FBIOGET_VSCREENINFO); layout is proportional to a 1236x1648 base
  * the touch device is auto-detected (first /dev/input/event* that reports
    multitouch or absolute X/Y) and raw coordinates are scaled using the
    panel's own ABS ranges (EVIOCGABS); swap/mirror overrides in config.lua
  * fonts: Amazon Ember when present, else older firmware fonts

E-ink notes: one flashing full refresh per screen change, then only small
regional updates (status line, timer, entry box) so nothing flickers.
--]]

local ffi = require("ffi")
local socket = require("socket")
local json = require("json")

local HERE = os.getenv("COMPANION_DIR") or "/mnt/us/calibre-wireless"
local ASSETS = HERE .. "/assets"
local FBINK = os.getenv("FBINK") or "/var/local/kmc/bin/fbink"

local ok_cfg, cfg = pcall(dofile, HERE .. "/config.lua")
if not ok_cfg or type(cfg) ~= "table" then cfg = {} end

ffi.cdef[[
typedef struct { long sec; long usec; unsigned short type; unsigned short code; int value; } input_event_t;
struct pollfd { int fd; short events; short revents; };
int open(const char *pathname, int flags);
int close(int fd);
int read(int fd, void *buf, size_t count);
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
int ioctl(int fd, unsigned long request, ...);
]]
local O_RDONLY, O_NONBLOCK = 0, 2048
local POLLIN = 1

---------------------------------------------------------------- helpers ----
local function sq(s) return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'" end
local function sh(cmd) return os.execute(cmd .. " >/dev/null 2>&1") end
local function log(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    local f = io.open(HERE .. "/ui.log", "a")
    if f then f:write(os.date("%H:%M:%S "), table.concat(t, " "), "\n"); f:close() end
end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end
local function write_file(p, s) local f = io.open(p, "w"); if f then f:write(s); f:close() end end
local function popen_line(cmd)
    local p = io.popen(cmd .. " 2>/dev/null"); if not p then return "" end
    local out = p:read("*a") or ""; p:close(); return out
end
local function round(x) return math.floor(x + 0.5) end

---------------------------------------------------------------- screen -----
local FBIOGET_VSCREENINFO = 0x4600
local function fb_info()
    local info = { w = 1236, h = 1648, dark = false }
    local fd = ffi.C.open("/dev/fb0", O_RDONLY)
    if fd >= 0 then
        local v = ffi.new("unsigned int[40]")
        if ffi.C.ioctl(fd, FBIOGET_VSCREENINFO, v) == 0 and v[0] > 0 and v[1] > 0 then
            info.w, info.h, info.dark = tonumber(v[0]), tonumber(v[1]), (v[7] == 2)
        end
        ffi.C.close(fd)
    end
    return info
end

local FB = fb_info()
local W, H = FB.w, FB.h
local BASE_W, BASE_H = 1236, 1648
local SX, SY = W / BASE_W, H / BASE_H
local S = math.min(SX, SY)
local function X(x) return round(x * SX) end
local function Y(y) return round(y * SY) end
local function P(px) return math.max(8, round(px * S)) end

local theme = cfg.theme or "auto"
local DARK = (theme == "dark") or (theme == "auto" and FB.dark)
local DARK_FLAG = (DARK and (cfg.dark_draw_invert and " -H" or "")) or ""
log(("screen %dx%d scale %.3f dark=%s"):format(W, H, S, tostring(DARK)))

------------------------------------------------------------------ fonts -----
local FONT_DIR = "/usr/java/lib/fonts"
local function pick_font(list)
    for _, f in ipairs(list) do
        if exists(FONT_DIR .. "/" .. f) then return FONT_DIR .. "/" .. f end
    end
    return FONT_DIR .. "/" .. list[#list]
end
local REG  = pick_font({ "Amazon-Ember-Regular.ttf", "Bookerly-Regular.ttf", "Caecilia_LT_65_Medium.ttf", "Helvetica_LT_65_Medium.ttf" })
local MED  = pick_font({ "Amazon-Ember-Medium.ttf", "Amazon-Ember-Regular.ttf", "Bookerly-Regular.ttf", "Caecilia_LT_65_Medium.ttf" })
local BOLD = pick_font({ "Amazon-Ember-Bold.ttf", "Bookerly-Bold.ttf", "Caecilia_LT_75_Bold.ttf", "Helvetica_LT_75_Bold.ttf" })

----------------------------------------------------------------- drawing ----
local function fb(args) return sh(FBINK .. " -q" .. DARK_FLAG .. " " .. args) end

local ASSET = {
    ["logo.png"] = { 400, 400 }, ["btn_bg.png"] = { 900, 128 }, ["btn_quit.png"] = { 900, 128 },
    ["chk_on.png"] = { 900, 110 }, ["chk_off.png"] = { 900, 110 }, ["rule.png"] = { 1156, 3 },
    ["batt.png"] = { 56, 35 }, ["wifi.png"] = { 42, 42 },
    ["pill_blank.png"] = { 900, 110 }, ["pill_blank_inv.png"] = { 900, 110 },
    ["pill_type_address.png"] = { 900, 110 }, ["pill_connect.png"] = { 900, 110 },
    ["key.png"] = { 170, 120 }, ["entry_box.png"] = { 900, 110 },
}
local function asset_size(file)
    local a = ASSET[file] or ASSET[(file:gsub("_%w+%.png$", ".png"))] or { 0, 0 }
    return a[1], a[2]
end
local function scaled(file)
    local aw, ah = asset_size(file)
    if S ~= 1 and aw > 0 then return (",w=%d,h=%d"):format(round(aw * S), math.max(1, round(ah * S))) end
    return ""
end
local function img(file, x, y)
    fb(("-b -g file=%s,x=%d,y=%d%s"):format(sq(ASSETS .. "/" .. file), x, y, scaled(file)))
end
local function img_center(file, y)
    fb(("-b -g file=%s,halign=CENTER,y=%d%s"):format(sq(ASSETS .. "/" .. file), y, scaled(file)))
end

-- TrueType text. opts: left/right margins, bgless (draw over artwork), white
local function text(str, y, px, font, opts)
    opts = opts or {}
    local f = ("regular=%s,px=%d,top=%d,left=%d,right=%d"):format(font or REG, px, y, opts.left or X(60), opts.right or X(60))
    local extra = (opts.bgless and " -O" or "") .. (opts.white and " -C WHITE" or "")
    fb(("-b -m%s -t %s %s"):format(extra, f, sq(str)))
end
local function text_at(str, x, y, px, font, opts)
    opts = opts or {}
    local extra = (opts.bgless and " -O" or "") .. (opts.white and " -C WHITE" or "")
    fb(("-b%s -t regular=%s,px=%d,top=%d,left=%d %s"):format(extra, font or REG, px, y, x, sq(str)))
end
local function clear_region(top, height, left, width)
    fb(("-b -k top=%d,left=%d,width=%d,height=%d"):format(top, left or 0, width or W, height))
end
local function refresh_region(top, height, left, width, flash)
    fb(("-s top=%d,left=%d,width=%d,height=%d%s"):format(top, left or 0, width or W, height, flash and " -f" or ""))
end
local function refresh_all(flash) fb(flash and "-s -f" or "-s") end

----------------------------------------------------------------- header -----
-- Laid out like the stock 5.18 home screen: time at the left; Wi-Fi,
-- battery percentage and battery icon at the right; no title, no rule.
local HDR_BASE_PX = 30
local HDR_PX = 32
local ADV = { ["0"]=18, ["1"]=18, ["2"]=18, ["3"]=18, ["4"]=18, ["5"]=18, ["6"]=18, ["7"]=18, ["8"]=18, ["9"]=18,
              [":"]=8, ["%"]=28, [" "]=8, ["A"]=19, ["P"]=18, ["M"]=26 }   -- Ember Regular @30px
local function text_w(s, px)
    local w = 0
    for ch in s:gmatch(".") do w = w + (ADV[ch] or 18) end
    return round(w * S * (px or HDR_BASE_PX) / HDR_BASE_PX)
end
local hdr = { key = nil }
local function header_values()
    local batt = tonumber((popen_line("lipc-get-prop com.lab126.powerd battLevel")):match("%d+")) or 0
    local chg = (popen_line("lipc-get-prop com.lab126.powerd isCharging")):match("1") ~= nil
    local bars = tonumber((popen_line("lipc-get-prop com.lab126.wifid signalStrength")):match("(%d)/5")) or 0
    local t = os.date("%I:%M %p"):gsub("^0", "")
    return batt, chg, bars, t
end
local function draw_header(refresh)
    local batt, chg, bars, t = header_values()
    local key = ("%d|%s|%d|%s"):format(batt, tostring(chg), bars, t)
    if key == hdr.key and not refresh then return end
    hdr.key = key
    local H_TOP, H_H = 0, Y(84)
    clear_region(H_TOP, H_H)
    local px = P(HDR_PX)
    local pct = batt .. "%"
    -- Icons are the Kindle's own status-bar artwork (see make_assets.py);
    -- sizes mirror ASSET["batt.png"] / ASSET["wifi.png"].
    -- Positions measured from a stock 5.18 home screen (Paperwhite 5).
    local x_batt = W - X(28) - round(56 * S)
    local x_pct = x_batt - X(10) - text_w(pct, HDR_PX)
    local x_wifi = x_pct - X(24) - round(42 * S)
    text_at(t, X(32), Y(33), px, REG)
    text_at(pct, x_pct, Y(33), px, REG)
    img(chg and "batt_chg.png" or ("batt_" .. math.floor(batt / 10 + 0.5) .. ".png"), x_batt, Y(34))
    img("wifi_" .. math.max(0, math.min(5, bars)) .. ".png", x_wifi, Y(28))
    if refresh then refresh_region(H_TOP, H_H) end
end

---------------------------------------------------------------- layout -----
local L = {
    logo_y = Y(175), title_y = Y(605), status_y = Y(760), sub_y = Y(828),
    book_y = Y(915), timer_y = Y(1045), chk_y = Y(1140), bg_y = Y(1285),
    quit_y = Y(1440), foot_y = Y(1596),
}
local BW, BH, CH = round(900 * S), round(128 * S), round(110 * S)
local BX = math.floor((W - BW) / 2)
local function in_rect(r, x, y) return x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 end
local function rect(x, y, w, h, pad) pad = pad or Y(8); return { x1 = x - pad, y1 = y - pad, x2 = x + w + pad, y2 = y + h + pad } end

local hit_main = {
    pick = rect(0, L.status_y - Y(10), W, L.timer_y - Y(20) - L.status_y, 0),
    chk  = rect(BX, L.chk_y, BW, CH),
    bg   = rect(BX, L.bg_y, BW, BH),
    quit = rect(BX, L.quit_y, BW, BH),
}

------------------------------------------------------------------ state -----
local state = {}
local last = { status = nil, sub = nil, book = nil, timer = nil, forever = nil }

local function load_state()
    -- UI_STATE_FILE is a QC aid: render from a hand-written state file
    -- (tools/qc_shots.py uses it for the README screenshots).
    local fresh = json.load(os.getenv("UI_STATE_FILE") or (HERE .. "/state.json"))
    -- Keep showing the last good state if the file is mid-rewrite or unreadable.
    if type(fresh) ~= "table" then
        if next(state) == nil then state = {} end
        return
    end
    state = fresh
    for k, v in pairs(state) do
        if v == json.null then state[k] = nil end
    end
    local c = {}
    for _, cand in ipairs(state.candidates or {}) do
        if type(cand) == "table" and type(cand.host) == "string" then
            c[#c + 1] = { host = cand.host, port = tonumber(cand.port) or 9090,
                          name = (cand.name ~= json.null) and cand.name or nil }
        end
    end
    state.candidates = c
end

local function fmt_dur(sec)
    sec = math.max(0, math.floor(sec))
    local h, m = math.floor(sec / 3600), math.floor(sec % 3600 / 60)
    if h > 0 then return ("%d h %02d min"):format(h, m) end
    if m < 1 then return "under a minute" end
    return ("%d min"):format(m)
end

local function status_lines()
    local st = state.status or "starting"
    if st == "connected" then
        local who = state.calibre_name and ("calibre on " .. state.calibre_name) or ("calibre at " .. tostring(state.host or "?"))
        return "Connected to " .. who, "Send books from calibre \226\128\148 they appear on your home screen."
    elseif st == "receiving" then
        return ("Receiving %d of %d\226\128\166"):format(state.this_book or 1, state.total_books or 1), state.last_book or ""
    elseif st == "choose" then
        return ("Found %d calibre instances"):format(#state.candidates), "Tap below to choose which one to use"
    elseif st == "searching" then
        return "Looking for calibre on Wi-Fi\226\128\166", "In calibre: Connect/share \226\128\186 Start wireless device connection"
    elseif st == "busy" then
        return "calibre is busy with another device", "Will retry automatically"
    elseif st == "stopped" then
        return "Companion stopped", ""
    else
        return "Starting\226\128\166", ""
    end
end

local function book_line()
    if state.received_count and state.received_count > 0 and state.last_book then
        return ("Last received: %s"):format(state.last_book)
    end
    return "Tap here to choose a calibre or type an address \226\128\186"
end

local function timer_line()
    local now = os.time()
    local up = state.started_at and (now - state.started_at) or 0
    if state.forever then
        return ("Running %s \194\183 stays on until you quit or reboot"):format(fmt_dur(up))
    end
    local left = state.deadline and (state.deadline - now) or nil
    if left then
        return ("Running %s \194\183 auto\226\128\145exits in %s"):format(fmt_dur(up), fmt_dur(left))
    end
    return ("Running %s"):format(fmt_dur(up))
end

local function fit(s, n)
    if #s <= n then return s end
    return s:sub(1, n - 1) .. "\226\128\166"
end

-------------------------------------------------------------- main screen --
-- The status block (between the title and the timer) has two layouts: when
-- connected, the PC's name sits in a big pill so it is the first thing you
-- read; otherwise plain status lines.
local BLK_TOP = L.status_y - Y(14)
local BLK_H = (L.timer_y - Y(14)) - BLK_TOP
local function rows()
    if state.status == "connected" then return { sub = Y(935), book = Y(982) } end
    return { sub = L.sub_y, book = L.book_y }
end
local function draw_status_block()
    local s1, s2 = status_lines()
    local r = rows()
    if state.status == "connected" then
        local name = state.calibre_name or tostring(state.host or "?")
        text("Connected to calibre on", Y(752), P(30), REG)
        img("pill_blank.png", BX, Y(798))
        text(fit(name, 24), Y(824), P(52), BOLD, { bgless = true })
        text(fit(s2, 70), r.sub, P(28), REG)
    else
        text(s1, L.status_y, P(44), MED)
        text(fit(s2, 70), r.sub, P(32), REG)
    end
    text(fit(book_line(), 60), r.book, P(30), REG)
    last.status, last.sub, last.book = s1, s2, book_line()
end

local function draw_main()
    fb("-b -k")
    draw_header(false)
    img_center("logo.png", L.logo_y)
    text("calibre wireless", L.title_y, P(84), BOLD)
    draw_status_block()
    text(timer_line(), L.timer_y, P(36), REG)
    img("chk_" .. (state.forever and "on" or "off") .. ".png", BX, L.chk_y)
    img("btn_bg.png", BX, L.bg_y)
    img("btn_quit.png", BX, L.quit_y)
    text("Tip: the Kindle sleeps after ~10 min idle and drops Wi\226\128\145Fi \226\128\148 tap the screen to wake it.", L.foot_y, P(24), REG)
    refresh_all(true)
    last.timer, last.forever = timer_line(), state.forever
end

local function update_text_row(y, height, str, px, font)
    clear_region(y - Y(4), height)
    text(str, y, px, font)
    refresh_region(y - Y(4), height)
end

local function draw_main_delta()
    draw_header(true)
    local s1, s2 = status_lines()
    if s1 ~= last.status or s2 ~= last.sub or book_line() ~= last.book then
        clear_region(BLK_TOP, BLK_H)
        draw_status_block()
        refresh_region(BLK_TOP, BLK_H)
    end
    local t = timer_line()
    if t ~= last.timer then
        update_text_row(L.timer_y, Y(60), t, P(36), REG)
        last.timer = t
    end
    if state.forever ~= last.forever then
        img("chk_" .. (state.forever and "on" or "off") .. ".png", BX, L.chk_y)
        refresh_region(L.chk_y, CH, BX, BW)
        last.forever = state.forever
    end
end

local function toast(msg)
    local y = rows().book
    clear_region(y - Y(4), Y(60))
    text(msg, y, P(34), MED)
    refresh_region(y - Y(4), Y(60))
end

------------------------------------------------------------ choose screen --
local ROW_Y0, ROW_STEP, MAX_ROWS = Y(300), Y(135), 6
local hit_choose = {}   -- filled by draw_choose

-- inv = a pre-rendered black pill (label baked into the PNG; `big` names it)
local function pill_label(y, big, small, inv)
    if inv then img(big, BX, y); return end
    img("pill_blank.png", BX, y)
    local opts = { bgless = true, left = BX + X(20), right = W - BX - BW + X(20) }
    if small then
        text(big, y + Y(14), P(36), MED, opts)
        text(small, y + Y(62), P(26), REG, opts)
    else
        text(big, y + Y(30), P(40), MED, opts)
    end
end

local function draw_choose()
    fb("-b -k")
    draw_header(false)
    text("Choose calibre", Y(150), P(64), BOLD)
    local n = #state.candidates
    text(n > 0 and ("%d found on Wi\226\128\145Fi"):format(n) or "Nothing found on Wi\226\128\145Fi yet", Y(235), P(30), REG)
    hit_choose = {}
    local y = ROW_Y0
    for i, c in ipairs(state.candidates) do
        if i > MAX_ROWS then break end
        local current = (state.host == c.host) and (tonumber(state.port or 0) == c.port or state.status == "connected")
        pill_label(y, (c.name or c.host) .. (current and "  \226\128\162 connected" or ""), c.host .. ":" .. c.port, false)
        hit_choose[#hit_choose + 1] = { r = rect(BX, y, BW, CH), action = "connect", host = c.host, port = c.port }
        y = y + ROW_STEP
    end
    y = y + Y(20)
    pill_label(y, "pill_type_address.png", nil, true)
    hit_choose[#hit_choose + 1] = { r = rect(BX, y, BW, CH), action = "keypad" }
    y = y + ROW_STEP
    pill_label(y, "Search again", nil, false)
    hit_choose[#hit_choose + 1] = { r = rect(BX, y, BW, CH), action = "rescan" }
    local back_y = math.max(y + ROW_STEP, L.quit_y)
    pill_label(back_y, "Back", nil, false)
    hit_choose[#hit_choose + 1] = { r = rect(BX, back_y, BW, CH), action = "back" }
    refresh_all(true)
end

------------------------------------------------------------ keypad screen --
local KW, KH, KGAP = round(170 * S), round(120 * S), X(20)
local KX0 = math.floor((W - (4 * KW + 3 * KGAP)) / 2)
local KY0 = Y(470)
local KEYS = {
    { "1", "2", "3", "Del" },
    { "4", "5", "6", "." },
    { "7", "8", "9", ":" },
    { "Clear", "0" },
}
local ENTRY_Y = Y(250)
local CONNECT_Y, CANCEL_Y = Y(1100), Y(1250)
local entry = ""
local hit_keypad = {}

local function draw_entry(refresh)
    clear_region(ENTRY_Y, CH, BX, BW)
    img("entry_box.png", BX, ENTRY_Y)
    local shown = (#entry > 0) and entry or "IP address : port"
    text(shown, ENTRY_Y + Y(28), P(44), MED, { bgless = true, left = BX + X(30), right = W - BX - BW + X(30) })
    if refresh then refresh_region(ENTRY_Y, CH, BX, BW) end
end

local function draw_keypad()
    fb("-b -k")
    draw_header(false)
    text("calibre address", Y(150), P(64), BOLD)
    draw_entry(false)
    text("e.g. 192.168.1.20:9090 \194\183 port is optional (9090)", Y(380), P(26), REG)
    hit_keypad = {}
    for r, row in ipairs(KEYS) do
        for c, label in ipairs(row) do
            local x, y = KX0 + (c - 1) * (KW + KGAP), KY0 + (r - 1) * (KH + KGAP)
            img("key.png", x, y)
            local px = (#label > 1) and P(32) or P(48)
            text(label, y + (#label > 1 and Y(40) or Y(30)), px, MED, { bgless = true, left = x, right = W - x - KW })
            hit_keypad[#hit_keypad + 1] = { r = rect(x, y, KW, KH, Y(4)), key = label }
        end
    end
    pill_label(CONNECT_Y, "pill_connect.png", nil, true)
    hit_keypad[#hit_keypad + 1] = { r = rect(BX, CONNECT_Y, BW, CH), key = "Connect" }
    pill_label(CANCEL_Y, "Cancel", nil, false)
    hit_keypad[#hit_keypad + 1] = { r = rect(BX, CANCEL_Y, BW, CH), key = "Cancel" }
    refresh_all(true)
end

local function parse_address(s)
    local host, port = s:match("^%s*([%d%.]+):?(%d*)%s*$")
    if not host then return nil, "Use digits and dots, e.g. 192.168.1.20" end
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil, "IP needs four numbers, e.g. 192.168.1.20" end
    for _, o in ipairs({ a, b, c, d }) do
        if tonumber(o) > 255 then return nil, "Each part of the IP must be 0\226\128\147255" end
    end
    local p = tonumber(port ~= "" and port or "9090")
    if p < 1 or p > 65535 then return nil, "Port must be 1\226\128\14765535" end
    return host, p
end

local function keypad_note(msg)
    clear_region(Y(380) - Y(4), Y(50))
    text(msg, Y(380), P(26), MED)
    refresh_region(Y(380) - Y(4), Y(50))
end

------------------------------------------------------------------ touch -----
local function IOC_READ(nr, size) return 0x80000000 + size * 0x10000 + 0x45 * 0x100 + nr end
local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local ABS_X, ABS_Y, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0, 1, 53, 54, 57
local BTN_TOUCH, SYN_REPORT = 330, 0

local function bit_test(byte, bit) return math.floor(byte / (2 ^ bit)) % 2 == 1 end
local function has_abs(fd, code)
    local bits = ffi.new("unsigned char[8]")
    if ffi.C.ioctl(fd, IOC_READ(0x20 + EV_ABS, 8), bits) < 0 then return false end
    return bit_test(bits[math.floor(code / 8)], code % 8)
end
local function abs_range(fd, code)
    local info = ffi.new("int[6]")
    if ffi.C.ioctl(fd, IOC_READ(0x40 + code, 24), info) < 0 then return nil end
    return tonumber(info[1]), tonumber(info[2])
end

local touch = { fd = -1, dev = nil, mt = true, xmax = nil, ymax = nil }
local function open_touch()
    local candidates = {}
    if cfg.touch_dev then candidates[#candidates + 1] = cfg.touch_dev end
    candidates[#candidates + 1] = "/dev/input/touch"
    for i = 0, 9 do candidates[#candidates + 1] = "/dev/input/event" .. i end
    for _, dev in ipairs(candidates) do
        local fd = ffi.C.open(dev, O_RDONLY + O_NONBLOCK)
        if fd >= 0 then
            local mt = has_abs(fd, ABS_MT_POSITION_X)
            local st = has_abs(fd, ABS_X)
            if mt or st then
                touch.fd, touch.dev, touch.mt = fd, dev, mt
                local _, xmax = abs_range(fd, mt and ABS_MT_POSITION_X or ABS_X)
                local _, ymax = abs_range(fd, mt and ABS_MT_POSITION_Y or ABS_Y)
                touch.xmax, touch.ymax = xmax, ymax
                log(("touch %s mt=%s range %sx%s"):format(dev, tostring(mt), tostring(xmax), tostring(ymax)))
                return
            end
            ffi.C.close(fd)
        end
    end
    log("no touch device found")
end

local function to_screen(rx, ry)
    local x, y = rx, ry
    if cfg.touch_swap_xy then x, y = y, x end
    local xm = cfg.touch_swap_xy and touch.ymax or touch.xmax
    local ym = cfg.touch_swap_xy and touch.xmax or touch.ymax
    if xm and xm > 0 and math.abs(xm - (W - 1)) > 2 then x = x * (W - 1) / xm end
    if ym and ym > 0 and math.abs(ym - (H - 1)) > 2 then y = y * (H - 1) / ym end
    if cfg.touch_mirror_x then x = (W - 1) - x end
    if cfg.touch_mirror_y then y = (H - 1) - y end
    return round(x), round(y)
end

local ev = ffi.new("input_event_t[64]")
local pfd = ffi.new("struct pollfd[1]")
local cur = { x = nil, y = nil, down = false, saw_tracking = false, saw_btn = false, frame_had_pos = false }

local function wait_tap(timeout_ms)
    if touch.fd < 0 then socket.sleep(timeout_ms / 1000); return nil end
    pfd[0].fd, pfd[0].events, pfd[0].revents = touch.fd, POLLIN, 0
    local r = ffi.C.poll(pfd, 1, timeout_ms)
    if r <= 0 then return nil end
    local n = ffi.C.read(touch.fd, ev, ffi.sizeof(ev))
    if n <= 0 then return nil end
    local tap
    for i = 0, math.floor(n / ffi.sizeof("input_event_t")) - 1 do
        local e = ev[i]
        if e.type == EV_ABS then
            if e.code == ABS_MT_POSITION_X or e.code == ABS_X then cur.x = e.value; cur.frame_had_pos = true
            elseif e.code == ABS_MT_POSITION_Y or e.code == ABS_Y then cur.y = e.value; cur.frame_had_pos = true
            elseif e.code == ABS_MT_TRACKING_ID then
                cur.saw_tracking = true
                if e.value == -1 then
                    if cur.down and cur.x and cur.y then tap = { x = cur.x, y = cur.y } end
                    cur.down = false
                else
                    cur.down = true
                end
            end
        elseif e.type == EV_KEY and e.code == BTN_TOUCH then
            cur.saw_btn = true
            if e.value == 0 and cur.down and cur.x and cur.y then tap = { x = cur.x, y = cur.y } end
            cur.down = e.value == 1
        elseif e.type == EV_SYN and e.code == SYN_REPORT then
            if not cur.saw_tracking and not cur.saw_btn then
                if cur.frame_had_pos then cur.down = true
                elseif cur.down and cur.x and cur.y then tap = { x = cur.x, y = cur.y }; cur.down = false end
            end
            cur.frame_had_pos = false
        end
    end
    if tap then
        local x, y = to_screen(tap.x, tap.y)
        return { x = x, y = y, rx = tap.x, ry = tap.y }
    end
    return nil
end

-------------------------------------------------------------- framework -----
local function take_screen()
    sh("lipc-set-prop com.lab126.pillow disableEnablePillow disable")
    sh("killall -STOP awesome")
    write_file(HERE .. "/ui_open", tostring(os.time()))
end
local function give_screen_back()
    os.remove(HERE .. "/ui_open")
    sh("killall -CONT awesome")
    sh("lipc-set-prop com.lab126.pillow disableEnablePillow enable")
    sh("lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home")
end

-------------------------------------------------------------------- main -----
local function request_connect(host, port)
    write_file(HERE .. "/cmd.connect", json.encode(json.object({ host = host, port = port })))
end

local function main()
    os.remove(HERE .. "/ui.quit")
    load_state()
    open_touch()
    take_screen()
    -- UI_START_SCREEN=choose|keypad is a QC aid: open directly on that screen.
    local screen = os.getenv("UI_START_SCREEN") or "main"
    if screen == "choose" then draw_choose()
    elseif screen == "keypad" then entry = ""; draw_keypad()
    else screen = "main"; draw_main() end
    local opened = socket.gettime()
    while true do
        local tap = wait_tap(1000)
        load_state()
        if exists(HERE .. "/ui.quit") then os.remove(HERE .. "/ui.quit"); return "closed" end
        if tap and (socket.gettime() - opened) < 0.6 then tap = nil end

        if screen == "main" then
            if tap then
                log(("tap %d,%d (raw %d,%d)"):format(tap.x, tap.y, tap.rx, tap.ry))
                if in_rect(hit_main.chk, tap.x, tap.y) then
                    local nf = not state.forever
                    write_file(HERE .. "/cmd.forever", nf and "1" or "0")
                    state.forever = nf
                    draw_main_delta()
                elseif in_rect(hit_main.bg, tap.x, tap.y) then
                    toast(state.forever and "Running in the background until you quit or reboot." or
                          ("Running in the background \194\183 auto\226\128\145exits in " .. fmt_dur((state.deadline or os.time()) - os.time())))
                    socket.sleep(1.2)
                    return "background"
                elseif in_rect(hit_main.quit, tap.x, tap.y) then
                    write_file(HERE .. "/cmd.stop", "1")
                    toast("Disconnecting\226\128\166")
                    socket.sleep(0.8)
                    return "quit"
                elseif in_rect(hit_main.pick, tap.x, tap.y) then
                    screen = "choose"; draw_choose()
                end
            else
                if state.status == "stopped" or (state.pid_alive == false) then
                    toast("Companion has stopped."); socket.sleep(1.5); return "stopped"
                end
                draw_main_delta()
            end

        elseif screen == "choose" then
            if tap then
                for _, h in ipairs(hit_choose) do
                    if in_rect(h.r, tap.x, tap.y) then
                        if h.action == "connect" then
                            request_connect(h.host, h.port)
                            screen = "main"; draw_main(); toast(("Connecting to %s:%d\226\128\166"):format(h.host, h.port))
                        elseif h.action == "keypad" then
                            entry = ""; screen = "keypad"; draw_keypad()
                        elseif h.action == "rescan" then
                            -- the daemon rediscovers on its own loop; just redraw with what it knows
                            draw_choose()
                        elseif h.action == "back" then
                            screen = "main"; draw_main()
                        end
                        break
                    end
                end
            else
                draw_header(true)
            end

        elseif screen == "keypad" then
            if tap then
                for _, h in ipairs(hit_keypad) do
                    if in_rect(h.r, tap.x, tap.y) then
                        local k = h.key
                        if k == "Del" then entry = entry:sub(1, -2); draw_entry(true)
                        elseif k == "Clear" then entry = ""; draw_entry(true)
                        elseif k == "Cancel" then screen = "choose"; draw_choose()
                        elseif k == "Connect" then
                            local host, port = parse_address(entry)
                            if host then
                                request_connect(host, port)
                                screen = "main"; draw_main(); toast(("Connecting to %s:%d\226\128\166"):format(host, port))
                            else
                                keypad_note(port)   -- error message
                            end
                        elseif #entry < 21 then entry = entry .. k; draw_entry(true)
                        end
                        break
                    end
                end
            else
                draw_header(true)
            end
        end
    end
end

local ok, err = pcall(main)
if not ok then log("UI error:", err) end
if touch.fd >= 0 then ffi.C.close(touch.fd) end
give_screen_back()
