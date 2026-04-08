local log = require("typst-preview.logger")

local M = {}

local uv = vim.uv

local bridge_bin = "tvp-bridge"

---@class ScrollState
---@field server uv.uv_process_t?
---@field bridge uv.uv_process_t?
---@field ws uv.uv_process_t?
---@field ws_in uv.uv_pipe_t?
---@field map { line: number, page: number }[]
---@field buf number
---@field path string
---@field svg_out string
local st = {
    server = nil,
    bridge = nil,
    ws = nil,
    ws_in = nil,
    map = {},
    buf = 0,
    path = "",
    svg_out = "",
}

---@type string[]
local pending = {}

local function flush_pending()
    if not st.ws_in then return end
    for _, msg in ipairs(pending) do
        st.ws_in:write(msg)
    end
    pending = {}
end

---@param title string
---@param lines string[]
---@return number?
local function find_heading(title, lines)
    for i, ln in ipairs(lines) do
        local hd = ln:match("^=+%s+(.+)$")
        if hd and hd:find(title, 1, true) then
            return i
        end
    end
    return nil
end

local max_page = 1

---@param items table[]
local function on_outline(items)
    vim.schedule(function()
        local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
        local map = {}
        local function collect(list)
            for _, item in ipairs(list) do
                local pg = item.position.page_no
                if pg > max_page then max_page = pg end
                local ln = find_heading(item.title, lines)
                if ln then
                    table.insert(map, { line = ln, page = pg })
                end
                if item.children then collect(item.children) end
            end
        end
        collect(items)
        table.sort(map, function(a, b) return a.line < b.line end)
        st.map = map
    end)
end

---@param json_str string
local function on_msg(json_str)
    local ok, msg = pcall(vim.json.decode, json_str)
    if not ok then return end
    if msg.event == "outline" and msg.items then
        on_outline(msg.items)
    end
end

---@param port string
local function connect_ws(port)
    st.ws_in = uv.new_pipe()
    local ws_out = uv.new_pipe()
    local ws_err = uv.new_pipe()
    st.ws, _ = uv.spawn("websocat", {
        args = { "-B", "10000000", "--origin", "http://localhost",
            "ws://127.0.0.1:" .. port .. "/" },
        stdio = { st.ws_in, ws_out, ws_err },
    })
    flush_pending()

    local buf = ""
    ws_out:read_start(function(err, data)
        if err or not data then return end
        buf = buf .. data
        while true do
            local nl = buf:find("\n")
            if not nl then break end
            on_msg(buf:sub(1, nl - 1))
            buf = buf:sub(nl + 1)
        end
    end)
end

---@type fun()?
local on_bridge_ready = nil

---@type uv.uv_pipe_t?
local bridge_in = nil

local is_dark = false

---@param port string
local function start_bridge(port)
    bridge_in = uv.new_pipe()
    local br_err = uv.new_pipe()
    local br_args = { "--url", "ws://127.0.0.1:" .. port .. "/",
        "--page", "1", "--out", st.svg_out }
    if is_dark then
        table.insert(br_args, "--dark")
    end
    st.bridge, _ = uv.spawn(bridge_bin, {
        args = br_args,
        stdio = { bridge_in, nil, br_err },
    })
    br_err:read_start(function(err, data)
        if err or not data then return end
        if data:find("tvp%-bridge: connected") and on_bridge_ready then
            on_bridge_ready()
            on_bridge_ready = nil
        end
    end)
end

--- Tell bridge to switch to a different page.
---@param n number
function M.set_page(n)
    if bridge_in then
        bridge_in:write(tostring(n) .. "\n")
    end
end

---@param path string
---@param content string
function M.update(path, content)
    local msg = vim.json.encode({
        event = "updateMemoryFiles",
        files = { [path] = content },
    }) .. "\n"
    if st.ws_in then
        flush_pending()
        st.ws_in:write(msg)
    else
        table.insert(pending, msg)
    end
end

---@return number
function M.total_pages()
    return max_page
end

---@param line number
---@return number?
function M.page_at(line)
    if #st.map == 0 then return nil end
    local page = st.map[1].page
    for _, entry in ipairs(st.map) do
        if entry.line > line then break end
        page = entry.page
    end
    return page
end

---@param bufnr number
function M.watch_buf(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = "TypstPreview",
        buffer = bufnr,
        callback = function()
            local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
            M.update(path, content)
        end,
    })
end

---@param buf number
---@param path string
---@param svg_out string
function M.start(buf, path, svg_out)
    is_dark = vim.o.background == "dark"
    st.buf = buf
    st.path = path
    st.svg_out = svg_out

    local stderr = uv.new_pipe()
    local srv_args = { "preview", "--no-open",
        "--data-plane-host", "127.0.0.1:0",
        "--control-plane-host", "127.0.0.1:0" }
    local root = require("typst-preview.config").opts.preview.root or vim.fn.getcwd()
    if root then
        table.insert(srv_args, "--root")
        table.insert(srv_args, root)
    end
    table.insert(srv_args, path)

    st.server, _ = uv.spawn("tinymist", {
        args = srv_args,
        stdio = { nil, nil, stderr },
    })
    if not st.server then
        log.error("failed to start tinymist preview")
        return
    end

    local ctrl_ready = false
    local bridge_ready = false

    local function send_init()
        if not ctrl_ready or not bridge_ready then return end
        vim.schedule(function()
            local content = table.concat(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), "\n")
            -- Append a zero-width space to force a diff vs on-disk content,
            -- ensuring tinymist recompiles and the bridge gets its first frame.
            -- Next real edit sends correct content.
            M.update(path, content .. "\u{200b}")
        end)
    end

    on_bridge_ready = function()
        bridge_ready = true
        send_init()
    end

    stderr:read_start(function(err, data)
        if err or not data then return end
        local cp = data:match("Control panel server listening on: 127%.0%.0%.1:(%d+)")
        if cp and not ctrl_ready then
            connect_ws(cp)
            ctrl_ready = true
            send_init()
        end
        local dp = data:match("Data plane server listening on: 127%.0%.0%.1:(%d+)")
        if dp then
            start_bridge(dp)
        end
    end)
end

function M.stop()
    if bridge_in then
        if not bridge_in:is_closing() then bridge_in:close() end
        bridge_in = nil
    end
    if st.bridge then
        st.bridge:kill(9)
        st.bridge = nil
    end
    if st.ws then
        st.ws:kill(9)
        st.ws = nil
    end
    if st.ws_in then
        if not st.ws_in:is_closing() then st.ws_in:close() end
        st.ws_in = nil
    end
    if st.server then
        st.server:kill(9)
        st.server = nil
    end
    st.map = {}
    pending = {}
    max_page = 1
end

---@return boolean
function M.ensure_bridge()
    if vim.fn.executable(bridge_bin) == 1 then return true end
    vim.notify("typst-preview: installing tvp-bridge...", vim.log.levels.INFO)
    local src = debug.getinfo(1, "S").source:sub(2)
    local dir = vim.fn.fnamemodify(src, ":p:h:h:h") .. "/bridge"
    local res = vim.system({ "cargo", "install", "--path", dir }):wait()
    if res.code ~= 0 then
        vim.notify("typst-preview: failed to install tvp-bridge:\n" .. (res.stderr or ""), vim.log.levels.ERROR)
        return false
    end
    vim.notify("typst-preview: tvp-bridge installed", vim.log.levels.INFO)
    return true
end

return M
