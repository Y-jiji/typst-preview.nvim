local log = require("typst-preview.logger")

local M = {}

local uv = vim.uv

local this_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(this_file, ":p:h:h:h:h")
local bridge_dir = plugin_root .. "/bridge"
local bridge_bin = bridge_dir .. "/target/release/tvp-bridge"

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

---@param items table[]
local function on_outline(items)
    vim.schedule(function()
        local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
        local map = {}
        for _, item in ipairs(items) do
            local page = item.position.page_no
            local title = item.title
            for i, ln in ipairs(lines) do
                local hd = ln:match("^=+%s+(.+)$")
                if hd and hd:find(title, 1, true) then
                    table.insert(map, { line = i, page = page })
                    break
                end
            end
            if item.children then
                for _, child in ipairs(item.children) do
                    local cp = child.position.page_no
                    local ct = child.title
                    for i, ln in ipairs(lines) do
                        local hd = ln:match("^=+%s+(.+)$")
                        if hd and hd:find(ct, 1, true) then
                            table.insert(map, { line = i, page = cp })
                            break
                        end
                    end
                end
            end
        end
        table.sort(map, function(a, b) return a.line < b.line end)
        st.map = map
    end)
end

---@type fun()?
local on_compile = nil

---@param json_str string
local function on_msg(json_str)
    local ok, msg = pcall(vim.json.decode, json_str)
    if not ok then return end
    if msg.event == "outline" and msg.items then
        on_outline(msg.items)
    elseif msg.event == "compileStatus" and msg.kind == "CompileSuccess" then
        if on_compile then on_compile() end
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

---@param port string
local function start_bridge(port)
    st.bridge, _ = uv.spawn(bridge_bin, {
        args = { "--url", "ws://127.0.0.1:" .. port .. "/",
            "--page", "1",
            "--out", st.svg_out },
        stdio = { nil, nil, nil },
    })
end

---@param path string
---@param content string
function M.update(path, content)
    if not st.ws_in then return end
    local msg = vim.json.encode({
        event = "updateMemoryFiles",
        files = { [path] = content },
    })
    st.ws_in:write(msg .. "\n")
end

---@param line number
---@param char number
function M.scroll(line, char)
    if not st.ws_in then return end
    local msg = vim.json.encode({
        event = "panelScrollTo",
        filepath = st.path,
        line = line,
        character = char,
    })
    st.ws_in:write(msg .. "\n")
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

---@param cb fun()
function M.on_compile(cb)
    on_compile = cb
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

---@return string
function M.svg_path()
    return st.svg_out
end

---@param buf number
---@param path string
---@param svg_out string
function M.start(buf, path, svg_out)
    st.buf = buf
    st.path = path
    st.svg_out = svg_out

    local stderr = uv.new_pipe()
    st.server, _ = uv.spawn("tinymist", {
        args = { "preview", "--no-open",
            "--data-plane-host", "127.0.0.1:0",
            "--control-plane-host", "127.0.0.1:0",
            path },
        stdio = { nil, nil, stderr },
    })
    if not st.server then
        log.error("failed to start tinymist preview")
        return
    end

    local ctrl_port = nil
    local data_port = nil
    stderr:read_start(function(err, data)
        if err or not data then return end
        local cp = data:match("Control panel server listening on: 127%.0%.0%.1:(%d+)")
        if cp and not ctrl_port then
            ctrl_port = cp
            connect_ws(cp)
        end
        local dp = data:match("Data plane server listening on: 127%.0%.0%.1:(%d+)")
        if dp and not data_port then
            data_port = dp
            start_bridge(dp)
        end
    end)
end

function M.stop()
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
end

--- Build the bridge binary if missing.
---@return boolean
function M.ensure_bridge()
    if uv.fs_stat(bridge_bin) then return true end
    vim.notify("typst-preview: building tvp-bridge (first time)...", vim.log.levels.INFO)
    local res = vim.system({ "cargo", "build", "--release" }, { cwd = bridge_dir }):wait()
    if res.code ~= 0 then
        vim.notify("typst-preview: failed to build tvp-bridge:\n" .. (res.stderr or ""), vim.log.levels.ERROR)
        return false
    end
    vim.notify("typst-preview: tvp-bridge built", vim.log.levels.INFO)
    return true
end

return M
