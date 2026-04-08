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

local preview_svg = preview_dir .. "page.svg"
local preview_png = preview_dir .. "page.png"

---@type uv.uv_fs_event_t?
local watcher = nil

---@type vim.SystemObj?
local current_job = nil

---@param force boolean?
function M.update_preview_size(force)
    if not uv.fs_stat(preview_png) then return end
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
        vim.api.nvim_win_set_width(state.preview.win, math.floor(page.cols))
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

--- Convert SVG to PNG via rsvg-convert, then render
function M.convert_and_render()
    if not uv.fs_stat(preview_svg) then return end

    if current_job and not current_job:is_closing() then
        current_job:kill(9)
        current_job = nil
    end

    local ppi = config.ppi
    if ppi == 0 then
        local px = state.meta.preview_px or 0
        if px > 0 then
            local f = io.open(preview_svg, "r")
            if f then
                local hdr = f:read(500) or ""
                f:close()
                local sw = tonumber(hdr:match('width="([%d%.]+)"')) or 0
                if sw > 0 then ppi = (px / sw) * 72 end
            end
        end
    end
    if ppi <= 0 then ppi = 96 end
    if ppi > 192 then ppi = 192 end
    local zoom = tostring(ppi / 72)
    current_job = vim.system({
        "rsvg-convert",
        "--zoom", zoom,
        "-o", preview_png,
        preview_svg,
    }, {}, function(obj)
        if obj.signal == 9 then return end
        if obj.code == 0 then
            state.code.compiled = true
            M.update_preview_size()
            M.render()
        else
            state.code.compiled = false
            vim.schedule(function()
                log.warn("(preview) rsvg-convert failed:\n" .. (obj.stderr or ""))
            end)
        end
        vim.schedule(function()
            statusline.update(state)
        end)
    end)
end

local function start_watcher()
    watcher = uv.new_fs_event()
    watcher:start(preview_dir, {}, function(err, fname)
        if err or fname ~= "page.svg" then return end
        M.convert_and_render()
    end)
end

local function stop_watcher()
    if watcher then
        watcher:stop()
        watcher:close()
        watcher = nil
    end
end

function M.update_meta()
    local cell_width, cell_height = utils.get_cell_dimensions()
    local prev_cols = vim.api.nvim_win_get_width(state.preview.win)
    state.meta = {
        win_rows = vim.api.nvim_win_get_height(0),
        win_cols = vim.api.nvim_win_get_width(state.code.win) + prev_cols + 1,
        cell_height = cell_height,
        cell_width = cell_width,
        preview_px = prev_cols * cell_width,
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
    local scroll = require("typst-preview.scroll")
    state.pages.total = scroll.total_pages()
    if n > state.pages.total then
        n = state.pages.total
    elseif n < 1 then
        n = 1
    end

    if n == state.pages.current then return end

    state.pages.current = n
    scroll.set_page(n)
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
    start_watcher()
    local scroll = require("typst-preview.scroll")
    local path = vim.api.nvim_buf_get_name(state.code.buf)
    scroll.start(state.code.buf, path, preview_svg)
    if uv.fs_stat(preview_svg) then
        M.convert_and_render()
    end
end

function M.close_preview()
    M.clear_preview()
    stop_watcher()
    require("typst-preview.scroll").stop()
    if vim.api.nvim_win_is_valid(state.preview.win) then
        vim.api.nvim_win_close(state.preview.win, true)
    end
    vim.fn.delete(preview_dir, "rf")
end

return M
