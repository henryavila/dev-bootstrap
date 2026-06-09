-- ~/.config/nvim/init.lua — managed by dotfiles/config/nvim/init.lua
-- Minimal config: sensible defaults + Catppuccin Mocha (auto-installed).
-- No plugin manager. Plugins are added as start-pack git clones on first run.
-- Philosophy: `EDITOR=nvim` should feel decent out of the box without
-- requiring `:PackerSync` or `:Lazy` ritual on a fresh machine.

-- ─── Sensible defaults ──────────────────────────────────────────────
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.cursorline = true
vim.opt.scrolloff = 8
vim.opt.sidescrolloff = 8
vim.opt.mouse = "a"
vim.opt.clipboard = "unnamedplus"
vim.opt.termguicolors = true
vim.opt.signcolumn = "yes"

-- Indent
vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4
vim.opt.smartindent = true

-- Search
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true

-- Splits feel natural: new window on the right / below
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Undo across sessions
vim.opt.undofile = true
vim.opt.swapfile = false
vim.opt.backup = false

-- Faster redraw, shorter timeouts
vim.opt.updatetime = 250
vim.opt.timeoutlen = 400

-- Completion behaves like a modern editor
vim.opt.completeopt = "menuone,noselect"

-- ─── Leader ────────────────────────────────────────────────────────
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- ─── Keymaps ────────────────────────────────────────────────────────
local map = vim.keymap.set
map("n", "<leader>w", "<cmd>write<CR>", { desc = "Save" })
map("n", "<leader>q", "<cmd>quit<CR>", { desc = "Quit" })
map("n", "<leader>x", "<cmd>xit<CR>", { desc = "Save and quit" })
map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })

-- Buffer navigation
map("n", "<leader>bn", "<cmd>bnext<CR>", { desc = "Next buffer" })
map("n", "<leader>bp", "<cmd>bprevious<CR>", { desc = "Prev buffer" })
map("n", "<leader>bd", "<cmd>bdelete<CR>", { desc = "Delete buffer" })

-- Window navigation (Ctrl-hjkl)
map("n", "<C-h>", "<C-w>h")
map("n", "<C-j>", "<C-w>j")
map("n", "<C-k>", "<C-w>k")
map("n", "<C-l>", "<C-w>l")

-- Keep cursor centered on half-page jumps
map("n", "<C-d>", "<C-d>zz")
map("n", "<C-u>", "<C-u>zz")

-- Stay in visual mode after indent
map("v", "<", "<gv")
map("v", ">", ">gv")

-- ─── Catppuccin Mocha auto-bootstrap ────────────────────────────────
-- Install as a packpath start plugin on first run so the colorscheme
-- is ready without any extra step. ~15 MB one-time clone.
local catp_dir = vim.fn.stdpath("data") .. "/site/pack/colors/start/catppuccin"
if vim.fn.isdirectory(catp_dir) == 0 and vim.fn.executable("git") == 1 then
    vim.notify("bootstrapping catppuccin/nvim → " .. catp_dir, vim.log.levels.INFO)
    vim.fn.system({
        "git", "clone", "--depth=1",
        "https://github.com/catppuccin/nvim.git", catp_dir,
    })
    vim.cmd("packadd catppuccin")
end

-- Fall back to default `habamax` if the clone failed (no network, etc.).
local ok = pcall(vim.cmd, "colorscheme catppuccin-mocha")
if not ok then
    pcall(vim.cmd, "colorscheme habamax")
end

-- ─── Filetype tweaks ────────────────────────────────────────────────
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "markdown", "text", "gitcommit" },
    callback = function()
        vim.opt_local.wrap = true
        vim.opt_local.linebreak = true
        vim.opt_local.spell = false
    end,
})

-- 2-space indent for YAML / web
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "yaml", "yml", "json", "html", "css", "scss", "javascript", "typescript", "vue" },
    callback = function()
        vim.opt_local.tabstop = 2
        vim.opt_local.shiftwidth = 2
        vim.opt_local.softtabstop = 2
    end,
})

-- Trim trailing whitespace on save (except for binary / diff)
vim.api.nvim_create_autocmd("BufWritePre", {
    pattern = "*",
    callback = function()
        local ft = vim.bo.filetype
        if ft == "diff" or ft == "gitcommit" or ft == "markdown" then return end
        local save = vim.fn.winsaveview()
        vim.cmd([[keeppatterns %s/\s\+$//e]])
        vim.fn.winrestview(save)
    end,
})
