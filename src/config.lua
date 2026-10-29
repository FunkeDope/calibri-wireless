-- calibre wireless settings (/mnt/us/calibre-wireless/config.lua)
-- Edit over USB or SSH; takes effect next time the companion starts.
return {
    -- Where calibre's books go. The stock Kindle scanner indexes this folder.
    inbox = "/mnt/us/documents",

    -- Formats, in order of preference. calibre sends the first one the book
    -- already has; if it has none of these it CONVERTS to the first entry.
    -- No "epub" here on purpose: EPUBs get converted to AZW3 and open in the
    -- normal Kindle reader. Add "epub" if you want raw EPUBs sent instead.
    formats = { "azw3", "mobi", "azw", "kfx", "prc", "azw4", "pdf", "txt" },

    -- Name shown in calibre.
    device_name = "Kindle",

    -- Leave nil to find calibre automatically (UDP broadcast). If your network
    -- blocks broadcast, set e.g. calibre_host = "192.168.1.10", calibre_port = 9090.
    -- With a fixed address the companion still falls back to discovery if it
    -- stops answering (PC got a new IP).
    calibre_host = nil,
    calibre_port = nil,

    -- Stop the Kindle from sleeping while connected to calibre:
    --   "charging" (default) only when plugged in, "always", or "never".
    -- (While the app is open on screen the Kindle always stays awake.)
    keep_awake = "charging",

    -- Give up and exit if calibre hasn't been seen for this long.
    max_idle_minutes = 180,

    -- On-screen status lines when the app is not open (bottom of the screen).
    show_messages = true,

    -- Display: "auto" follows the Kindle's dark mode, or force "light"/"dark".
    theme = "auto",

    -- Touch overrides (normally auto-detected; only set if taps land wrong).
    -- touch_dev = "/dev/input/event1",
    -- touch_swap_xy = false,
    -- touch_mirror_x = false,
    -- touch_mirror_y = false,
}
