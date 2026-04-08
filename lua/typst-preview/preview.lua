local renderer = require("typst-preview.renderer.renderer")
local utils = require("typst-preview.utils")
local config = require("typst-preview.config").opts.preview
local statusline = require("typst-preview.statusline")
local log = require("typst-preview.logger")

assert(config ~= nil, "config must not be nil")

local M = {}

local uv = vim.uv

---@class State
---@field code { win: number, buf: number, compiled: boolean }
---@field preview { win?: number, buf: number }
---@field pages { total: number, current: number, placements: {
---width: number, height: number, rows: number, cols:number , win_offset: number }[] }
---@field meta { cell_width: number, cell_height: number, win_rows: number, win_cols: number }
local state = {
    code = {},
    preview = {},
    pages = {
        total = 1,
        current = 1,
        placements = {},
    },
    meta = {},
}

local pid = vim.fn.getpid()
local preview_dir = "/dev/shm/typst_preview_" .. pid .. "/"
if not uv.fs_stat(preview_dir) then uv.fs_mkdir(preview_dir, 493) end

local stem = vim.fn.expand("%:t:r")
local preview_pdf = preview_dir .. stem .. ".pdf"
local preview_png = preview_dir .. "page.png"

---@type uv.uv_fs_event_t?
local watcher = nil

---@type vim.SystemObj?
local current_job = nil

---@param force boolean?
function M.update_preview_size(force)
    local img_height, img_width = utils.get_page_dimensions(preview_png)
    local page = state.pages.placements[state.pages.current]
    if force or not page or page.width ~= img_width or page.height ~= img_height then
        local rows = state.meta.win_rows
        local cols = math.ceil((state.meta.cell_height * rows * img_width) / (img_height * state.meta.cell_width))
        if cols > config.max_width then
            cols = config.max_width
            rows = math.ceil((state.meta.cell_width * cols * img_height) / (img_width * state.meta.cell_height))
        end
        page = {
            width = img_width,
            height = img_height,
            cols = cols or 0,
            rows = rows,
            win_offset = config.position == "left" and 0 or state.meta.win_cols - cols + 1,
        }
        state.pages.placements[state.pages.current] = page
    end
    vim.schedule(function()
        vim.api.nvim_win_set_width(state.preview.win, page.cols)
    end)
end

function M.render()
    if not uv.fs_stat(preview_png) then return end
    M.update_preview_size()
    local page = state.pages.placements[state.pages.current]
    renderer.render(
        preview_png,
        page.win_offset,
        page.rows,
        page.cols,
        state.meta.win_rows
    )
end

function M.clear_preview()
    renderer.clear()
end

local function update_page_count()
    local res = vim.system({ "pdfinfo", preview_pdf }):wait()
    if res.code ~= 0 then return end
    local n = res.stdout:match("Pages:%s+(%d+)")
    if n then state.pages.total = tonumber(n) end
end

--- Convert current page of the PDF to PNG via pdftoppm, then render
function M.convert_and_render()
    if not uv.fs_stat(preview_pdf) then return end

    if current_job and not current_job:is_closing() then
        current_job:kill(9)
        current_job = nil
    end

    current_job = vim.system({
        "pdftoppm", "-png", "-singlefile",
        "-f", tostring(state.pages.current),
        "-l", tostring(state.pages.current),
        "-r", tostring(config.ppi),
        preview_pdf,
        preview_dir .. "page",
    }, {}, function(obj)
        if obj.signal == 9 then return end
        if obj.code == 0 then
            state.code.compiled = true
            M.update_preview_size()
            M.render()
        else
            state.code.compiled = false
            vim.schedule(function()
                log.warn("(preview) pdftoppm failed:\n" .. obj.stderr)
            end)
        end
        vim.schedule(function()
            statusline.update(state)
        end)
    end)
end

local function on_pdf_change()
    update_page_count()
    M.convert_and_render()
end

local function start_watcher()
    watcher = uv.new_fs_event()
    local pdf_name = stem .. ".pdf"
    watcher:start(preview_dir, {}, function(err, fname)
        if err or fname ~= pdf_name then return end
        on_pdf_change()
    end)
end

local function stop_watcher()
    if watcher then
        watcher:stop()
        watcher:close()
        watcher = nil
    end
end

local function configure_lsp()
    local client = utils.get_lsp(state.code.buf)
    if not client then return false end
    client.notify("workspace/didChangeConfiguration", {
        settings = {
            exportPdf = "onType",
            outputPath = preview_dir .. "$name",
        },
    })
    return true
end

local function unconfigure_lsp()
    local client = utils.get_lsp(state.code.buf)
    if not client then return end
    client.notify("workspace/didChangeConfiguration", {
        settings = {
            exportPdf = "never",
        },
    })
end

function M.update_meta()
    local cell_width, cell_height = utils.get_cell_dimensions()
    state.meta = {
        win_rows = vim.api.nvim_win_get_height(0),
        win_cols = vim.api.nvim_win_get_width(state.code.win) + vim.api.nvim_win_get_width(state.preview.win) + 1,
        cell_height = cell_height,
        cell_width = cell_width,
    }
end

local function setup_preview_win()
    state.code.win = vim.api.nvim_get_current_win()
    state.code.buf = vim.api.nvim_get_current_buf()

    state.preview.win = vim.api.nvim_open_win(0, false, {
        split = config.position,
        win = 0,
        focusable = false,
        vertical = true,
        style = "minimal",
    })
    state.preview.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(state.preview.win, state.preview.buf)

    if config.position == "left" then
        vim.schedule(function()
            vim.api.nvim_set_current_win(state.code.win)
        end)
    end
end

---@param n number
function M.goto_page(n)
    if n > state.pages.total then
        n = state.pages.total
    elseif n < 1 then
        n = 1
    end

    if n == state.pages.current then return end

    state.pages.current = n
    M.convert_and_render()
    statusline.update(state)
end

---@param n? number
function M.next_page(n)
    if not n then n = 1 end
    M.goto_page(state.pages.current + n)
end

---@param n? number
function M.prev_page(n)
    if not n then n = 1 end
    M.goto_page(state.pages.current - n)
end

function M.first_page()
    M.goto_page(1)
end

function M.last_page()
    M.goto_page(state.pages.total)
end

function M.open_preview()
    setup_preview_win()
    M.update_meta()
    if not configure_lsp() then return end
    start_watcher()
    local scroll = require("typst-preview.scroll")
    local path = vim.api.nvim_buf_get_name(state.code.buf)
    scroll.start(state.code.buf, path)
    if uv.fs_stat(preview_pdf) then
        on_pdf_change()
    end
end

function M.close_preview()
    M.clear_preview()
    stop_watcher()
    require("typst-preview.scroll").stop()
    unconfigure_lsp()
    vim.api.nvim_win_close(state.preview.win, true)
    vim.fn.delete(preview_dir, "rf")
end

return M
