local log = require("typst-preview.logger")

local M = {}

local uv = vim.uv

---@class ScrollState
---@field server uv.uv_process_t?
---@field ws uv.uv_process_t?
---@field ws_in uv.uv_pipe_t?
---@field map { line: number, page: number }[]
---@field buf number
---@field path string
local st = {
    server = nil,
    ws = nil,
    ws_in = nil,
    map = {},
    buf = 0,
    path = "",
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

--- Send buffer content to preview server as memory file
--- - `content`: file content string
function M.update(content)
    if not st.ws_in then return end
    local msg = vim.json.encode({
        event = "updateMemoryFiles",
        files = { [st.path] = content },
    })
    st.ws_in:write(msg .. "\n")
end

--- Send scroll position to preview server
--- - `line`: 0-indexed line
--- - `char`: 0-indexed character
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

--- Get the page number for a given 1-indexed line
--- - `line`: 1-indexed line number
--- - `return`: page number or nil
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

--- Start preview server and websocat for scroll sync
--- - `buf`: buffer number
--- - `path`: absolute file path
---@param buf number
---@param path string
function M.start(buf, path)
    st.buf = buf
    st.path = path

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

    stderr:read_start(function(err, data)
        if err or not data then return end
        local port = data:match("Control panel server listening on: 127%.0%.0%.1:(%d+)")
        if port then
            connect_ws(port)
        end
    end)
end

function M.stop()
    if st.ws then
        st.ws:kill(9)
        st.ws = nil
    end
    if st.ws_in then
        st.ws_in:close()
        st.ws_in = nil
    end
    if st.server then
        st.server:kill(9)
        st.server = nil
    end
    st.map = {}
end

return M
