---------------------------------------------------------
-- Downloads for luakit                                --
-- (C) 2010 Fabian Streitel <karottenreibe@gmail.com>  --
-- (C) 2010 Mason Larobina  <mason.larobina@gmail.com> --
---------------------------------------------------------

-- Grab environment we need from the standard lib
local assert = assert
local ipairs = ipairs
local os = os
local pairs = pairs
local print = print
local setmetatable = setmetatable
local string = string
local table = table
local tonumber = tonumber
local type = type

-- Grab environment from luakit libs
local lousy = require("lousy")
local add_binds = add_binds
local add_cmds = add_cmds
local menu_binds = menu_binds
local new_mode = new_mode
local window = window
local theme = lousy.theme

-- Grab environment from C API
local capi = {
    download = download,
    timer = timer,
    luakit = luakit,
    widget = widget,
}

--- Provides internal support for downloads.
module("downloads")

-- Track speed data for downloads by weak table
local speeds = setmetatable({}, { __mode = "k" })

--- The list of active download objects.
downloads = {}

-- Setup signals on downloads module
lousy.signal.setup(_M)

-- Calculates a fancy name for a download to show to the user.
function get_basename(d)
    return string.match(d.destination or "", ".*/([^/]*)$") or "no filename"
end

-- Checks whether the download is in created or started state.
function is_running(d)
    return d.status == "created" or d.status == "started"
end

-- Calculates the speed of a download in b/s.
function get_speed(d)
    local s = speeds[d] or {}
    if s.current_size then
        return (s.current_size - (s.last_size or 0))
    end
    return 0
end

-- Track downloading speeds
local speed_timer = capi.timer{interval=1000}
speed_timer:add_signal("timeout", function ()
    for _, d in ipairs(downloads) do
        -- Get speed table
        if not speeds[d] then speeds[d] = {} end
        local s = speeds[d]

        -- Save download progress
        s.last_size = s.current_size or 0
        s.current_size = d.current_size
    end
    -- Only start timer again if there are active downloads
    if #downloads == 0 then
        speed_timer:stop()
    end
end)

-- Add indicator to status bar.
window.init_funcs.downloads_status = function (w)
    local r = w.sbar.r
    r.downloads = capi.widget{type="label"}
    r.layout:pack_start(r.downloads, false, false, 0)
    r.layout:reorder(r.downloads, 1)
    -- Apply theme
    local theme = theme.get()
    r.downloads.fg = theme.downloads_sbar_fg
    r.downloads.font = theme.downloads_sbar_font
end

-- Refresh indicator
local status_timer = capi.timer{interval=1000}
status_timer:add_signal("timeout", function ()
    for _, d in ipairs(downloads) do
        local running = 0
        for _, d in ipairs(downloads) do
            if is_running(d) then running = running + 1 end
        end
        for _, w in pairs(window.bywidget) do
            w.sbar.r.downloads.text = running == 0 and "" or running.."↓"
        end
    end
    -- Only start timer again if there are active downloads
    if #downloads == 0 then
        status_timer:stop()
    end
end)

--- The default directory for a new download.
default_dir = capi.luakit.get_special_dir("DOWNLOAD") or (os.getenv("HOME") .. "/downloads")

--- Adds a download.
-- Tries to apply one of the <code>rules</code>. If that fails,
-- asks the user to choose a location with a save dialog.
-- @param uri The uri to add.
-- @return <code>true</code> if a download was started
function add(uri, w)
    local d = capi.download{uri=uri}

    -- Emit signal to determine the download location.
    local file = _M:emit_signal("download-location", uri, d.suggested_filename)

    -- Check return type
    assert(file == nil or type(file) == "string" and #file > 1,
        string.format("invalid filename: %q", file or "nil"))

    -- If no download location returned ask the user
    if not file then
        file = capi.luakit.save_file("Save file", w, default_dir, d.suggested_filename)
    end

    -- If a suitable filename was given proceed with the download
    if file then
        d.destination = file
        d:start()
        table.insert(downloads, d)
        if not speed_timer.started then speed_timer:start() end
        if not status_timer.started then status_timer:start() end
        return true
    end
end

-- Add download window method
window.methods.download = function (w, uri)
    add(uri, w)
end

--- Removes all finished, cancelled or aborted downloads.
function clear()
    local tmp = {}
    for _, d in ipairs(downloads) do
        if is_running(d) then
            table.insert(tmp, d)
        end
    end
    downloads = tmp
end

local function get_download(d)
    if type(d) == "number" then
        d = assert(downloads[d], "invalid index")
    end
    assert(type(d) == "download", "invalid download object")
    return d
end

--- Opens the download at the given index after completion.
-- @param i The index of the download to open.
-- @param w A window to show notifications in, if necessary.
function open(d, w)
    d = get_download(d)
    local t = capi.timer{interval=1000}
    t:add_signal("timeout", function (t)
        if d.status == "finished" then
            t:stop()
            if _M:emit_signal("open-file", d.destination, d.mime_type, w) ~= true then
                if w then
                    w:error(string.format("Can't open: %q (%s)", d.desination, d.mime_type))
                end
            end
        end
    end)
    t:start()
end

-- Wrapper around download class cancel method.
function cancel(d)
    d = get_download(d)
    d:cancel()
end

-- Remove the given download object from the downloads table and cancel it if
-- necessary.
function delete(d)
    d = get_download(d)
    -- Remove download object from downloads table
    for i, v in ipairs(downloads) do
        if v == d then
            table.remove(downloads, i)
            break
        end
    end
    -- Stop download
    if is_running(d) then cancel(d) end
end

-- Removes and re-adds the given download.
function restart(d)
    d = get_download(d)
    local new_d = add(d.uri)
    if new_d then delete(d) end
    return new_d
end

-- Tests if any downloads are running.
-- @return true if the window can be closed.
local function can_close()
    if #(capi.luakit.windows) > 1 then return true end
    for _,d in ipairs(downloads) do
        if is_running(d) then
            return false
        end
    end
    return true
end

-- Tries to close the window, but will issue an error if any downloads are still
-- running.
-- @param w The window to close.
-- @param save true, if the session should be saved.
-- @param command The command to overwrite the check. Defaults to ":q!"
local function try_close(w, save, command)
    command = command or ":q!"
    if can_close() then
        if save then w:save_session() end
        w:close_win()
    else
        w:error("Can't close last window since downloads are still running. " ..
                "Use "..command.." to quit anyway.")
    end
end

-- Download normal mode binds.
local key, buf = lousy.bind.key, lousy.bind.buf
add_binds("normal", {
    key({"Control", "Shift"}, "D",
        function (w)
            w:enter_cmd(":download " .. ((w:get_current() or {}).uri or "http://") .. " ")
        end),
})

-- Overwrite quit binds to check if downloads are finished
add_binds("normal", {
    buf("^D$",
        function (w) try_close(w)      end),

    buf("^ZZ$",
        function (w) try_close(w,true) end),

    buf("^ZQ$",
        function (w) try_close(w)      end),

}, true)


-- Download commands.
local cmd = lousy.bind.cmd
add_cmds({
    cmd("down[load]",
        function (w, a)
            add(a)
        end),

    -- View all downloads in an interactive menu
    cmd("downloads",
        function (w)
            w:set_mode("downloadlist")
        end),

    cmd("dd[elete]",
        function (w, a)
            local d = downloads[assert(tonumber(a), "invalid index")]
            if d then delete(d) end
        end),

    cmd("dc[ancel]",
        function (w, a)
            local d = downloads[assert(tonumber(a), "invalid index")]
            if d then cancel(d) end
        end),

    cmd("dr[estart]",
        function (w, a)
            local d = downloads[assert(tonumber(a), "invalid index")]
            if d then restart(d) end
        end),

    cmd("dcl[ear]", clear),

    cmd("do[pen]",
        function (w, a)
            local d = downloads[assert(tonumber(a), "invalid index")]
            if d then open(d, w) end
        end),
})

-- Overwrite quit commands to check if downloads are finished
add_cmds({
    cmd("q[uit]",
        function (w) try_close(w)                   end),

    cmd({"quit!", "q!"},
        function (w) w:close_win()                  end),

    cmd({"writequit", "wq"},
        function (w) try_close(w, true, ":wq!")     end),

    cmd({"writequit!", "wq!"},
        function (w) w:save_session() w:close_win() end),

}, true)

-- Add mode to display all downloads in an interactive menu.
new_mode("downloadlist", {
    enter = function (w)
        -- Check if there are downloads
        if #downloads == 0 then
            w:notify("No downloads to list")
            return
        end

        -- Build downloads list
        local rows = {{ "Download", "Status", title = true }}
        for _, d in ipairs(downloads) do
            local function name()
                local i = lousy.util.table.hasitem(downloads, d) or 0
                return string.format("%3s %s", i, get_basename(d))
            end
            local function status()
                if is_running(d) then
                    return string.format("%.2f/%.2f Mb (%i%%) at %.1f Kb/s", d.current_size/1048576,
                        d.total_size/1048576, (d.progress * 100), get_speed(d) / 1024)
                else
                    return d.status
                end
            end
            table.insert(rows, { name, status, dl = d })
        end
        w.menu:build(rows)
        w:notify("Use j/k to move, d delete, c cancel, r restart, o open.", false)

        -- Update menu every second
        local update_timer = capi.timer{interval=1000}
        update_timer:add_signal("timeout", function ()
            w.menu:update()
        end)
        w.download_menu_state = { update_timer = update_timer }
        update_timer:start()
    end,

    leave = function (w)
        local ds = w.download_menu_state
        if ds and ds.update_timer.started then
            ds.update_timer:stop()
        end
        w.menu:hide()
    end,
})

-- Add additional binds to downloads menu mode.
local key = lousy.bind.key
add_binds("downloadlist", lousy.util.table.join({
    -- Delete download
    key({}, "d",
        function (w)
            local row = w.menu:get()
            if row and row.dl then
                delete(row.dl)
                w.menu:del()
            end
        end),

    -- Cancel download
    key({}, "c",
        function (w)
            local row = w.menu:get()
            if row and row.dl then
                cancel(row.dl)
            end
        end),

    -- Open download
    key({}, "o",
        function (w)
            local row = w.menu:get()
            if row and row.dl then
                open(row.dl, w)
            end
        end),

    -- Restart download
    key({}, "r",
        function (w)
            local row = w.menu:get()
            if row and row.dl then
                restart(row.dl)
            end
            -- HACK: Bad way of refreshing download list to show new items
            -- (I.e. the new download object from the restart)
            w:set_mode("downloadlist")
        end),

    -- Exit menu
    key({}, "q", function (w) w:set_mode() end),

}, menu_binds))

-- vim: et:sw=4:ts=8:sts=4:tw=80
