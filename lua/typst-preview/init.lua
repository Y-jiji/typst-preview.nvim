local M = {}
local running = false

local function setup_autocmds()
    local preview = require("typst-preview.preview")
    local scroll = require("typst-preview.scroll")
    vim.api.nvim_create_augroup("TypstPreview", {})
    local last_line
    require("typst-preview.utils").create_autocmds({
        {
            event = { "TextChanged", "TextChangedI" },
            callback = function()
                local buf = vim.api.nvim_get_current_buf()
                local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
                scroll.update(content)
            end,
        },
        {
            event = "CursorMoved",
            callback = function()
                local line = vim.api.nvim_win_get_cursor(0)[1]
                if last_line == line then return end
                last_line = line
                local page = scroll.page_at(line)
                if page then preview.goto_page(page) end
            end,
        },
        {
            event = "QuitPre",
            callback = function()
                preview.close_preview()
            end,
        },
        {
            no_ft = true,
            event = "VimSuspend",
            callback = function()
                if vim.bo.filetype == "typst" then preview.clear_preview() end
            end,
        },
        {
            no_ft = true,
            event = "VimResume",
            callback = function()
                if vim.bo.filetype == "typst" then preview.convert_and_render() end
            end,
        },
        {
            event = "FocusLost",
            callback = function()
                preview.clear_preview()
            end,
        },
        {
            event = "FocusGained",
            callback = function()
                preview.render()
            end,
        },
        {
            event = "VimResized",
            callback = function()
                preview.update_meta()
                preview.update_preview_size(true)
                preview.render()
            end,
        },
    })
end

---@param opts? ConfigOpts
function M.setup(opts)
    require("typst-preview.config").setup(opts)
    require("typst-preview.statusline").setup()
end

function M.start()
    if running then return end
    require("typst-preview.preview").open_preview()
    setup_autocmds()
    running = true
end

function M.stop()
    if not running then return end
    require("typst-preview.preview").close_preview()
    vim.api.nvim_clear_autocmds({ group = "TypstPreview" })
    running = false
end

---@param n number
function M.goto_page(n)
    if not running then return end
    require("typst-preview.preview").goto_page(n)
end

function M.first_page()
    if not running then return end
    require("typst-preview.preview").first_page()
end

function M.last_page()
    if not running then return end
    require("typst-preview.preview").last_page()
end

---@param n? number
function M.next_page(n)
    if not running then return end
    require("typst-preview.preview").next_page(n)
end

---@param n? number
function M.prev_page(n)
    if not running then return end
    require("typst-preview.preview").prev_page(n)
end

function M.refresh()
    if not running then return end
    local preview = require("typst-preview.preview")
    preview.update_meta()
    preview.update_preview_size(true)
    preview.render()
end

return M
