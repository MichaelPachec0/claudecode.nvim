---Integration tests for terminal.reposition with the Snacks provider: moving a
---running session between a float and a split keeps the same buffer and job.
---Needs snacks.nvim: set $SNACKS_NVIM to its checkout, or have it at lazy.nvim's
---default location. Reported as pending when it is not found, and under the
---plain busted + LuaJIT suite. Run inside Neovim with plenary, from the repo root:
---  nvim --headless --clean -c "set rtp+=/path/to/plenary.nvim" -c "set rtp^=." \
---    -c "lua require('plenary.busted').run('tests/integration/snacks_reposition_spec.lua')"

---True only inside a real Neovim process (not the busted vim mocks).
local function running_in_neovim()
  return type(vim) == "table"
    and type(vim.api) == "table"
    and type(vim.api.nvim_get_chan_info) == "function"
    and pcall(vim.api.nvim_get_chan_info, 0)
end

---Puts snacks.nvim on the runtimepath; true when it loads.
local function load_snacks()
  for _, dir in ipairs({ os.getenv("SNACKS_NVIM") or "", vim.fn.stdpath("data") .. "/lazy/snacks.nvim" }) do
    if dir ~= "" and vim.fn.isdirectory(dir) == 1 then
      vim.opt.runtimepath:append(dir)
      local ok, snacks = pcall(require, "snacks")
      if ok then
        snacks.setup({})
        return true
      end
    end
  end
  return false
end

describe("snacks terminal reposition", function()
  if not running_in_neovim() then
    it("requires a real Neovim process", function()
      pending("needs real windows; run inside Neovim with plenary (see file header)")
    end)
    return
  end
  if not load_snacks() then
    it("requires snacks.nvim", function()
      pending("snacks.nvim not found; set $SNACKS_NVIM (see file header)")
    end)
    return
  end

  vim.o.columns, vim.o.lines = 200, 50
  require("claudecode").setup({
    auto_start = false,
    terminal_cmd = "sh",
    log_level = "error",
    terminal = { provider = "snacks", snacks_win_opts = { position = "float", width = 0.8, height = 0.8 } },
  })
  local terminal = require("claudecode.terminal")

  ---The visible (not config-hidden) window showing `buf`, or nil.
  local function visible_win(buf)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == buf and not vim.api.nvim_win_get_config(win).hide then
        return win
      end
    end
  end

  local function is_float(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end

  after_each(function()
    for _, session in ipairs(terminal.list_sessions()) do
      pcall(terminal.close_session, session.id)
    end
    pcall(terminal.cleanup_all)
    vim.cmd("silent! tabonly! | silent! only!")
  end)

  it("moves a running float into a right split and back without restarting Claude", function()
    vim.cmd("ClaudeCode")
    local buf = terminal.get_active_terminal_bufnr()
    assert.is_true(vim.wait(1000, function()
      return visible_win(buf) ~= nil
    end, 20))
    assert.is_true(is_float(visible_win(buf)))
    local job = vim.b[buf].terminal_job_id

    assert.is_true(terminal.reposition({ snacks_win_opts = { position = "right", width = 0.3 } }))

    local win = visible_win(buf)
    assert.is_not_nil(win, "terminal not visible after reposition")
    assert.is_false(is_float(win))
    assert.are.equal(math.floor(vim.o.columns * 0.3), vim.api.nvim_win_get_width(win))
    assert.are.equal(-1, vim.fn.jobwait({ job }, 0)[1], "Claude must keep running")

    assert.is_true(terminal.reposition({ snacks_win_opts = { position = "float", width = 0.8, height = 0.8 } }))

    win = visible_win(buf)
    assert.is_not_nil(win)
    assert.is_true(is_float(win))
    assert.are.equal(buf, terminal.get_active_terminal_bufnr())
  end)

  it("keeps the new layout across a hide and show", function()
    vim.cmd("ClaudeCode")
    local buf = terminal.get_active_terminal_bufnr()
    terminal.reposition({ snacks_win_opts = { position = "right", width = 0.3 } })

    vim.cmd("ClaudeCode") -- hide
    assert.is_nil(visible_win(buf))
    vim.cmd("ClaudeCode") -- show

    local win = visible_win(buf)
    assert.is_not_nil(win)
    assert.is_false(is_float(win), "came back as a float after hide/show")
  end)
end)
