---Integration tests for multi-session terminals in a real Neovim.
---Drives the native provider with `sh` as the terminal command and checks the
---behavior the unit tests can only mock: split sizing and pinning, hide/show,
---session create/switch/close in the one managed window, send_to_terminal
---routing, that cleanup_all leaves no grandchild processes behind, and that
---diff_opts.keep_terminal_focus returns focus to the active session when a
---blocking openDiff opens and when it is accepted or denied.
---
---Under the plain busted + LuaJIT suite these are reported as pending. Run them
---inside Neovim with plenary.nvim on the runtimepath, from the repo root:
---  nvim --headless --clean -c "set rtp+=/path/to/plenary.nvim" -c "set rtp^=." \
---    -c "lua require('plenary.busted').run('tests/integration/terminal_multi_session_spec.lua')"

---True only inside a real Neovim process (not the busted vim mocks).
local function running_in_neovim()
  return type(vim) == "table"
    and type(vim.api) == "table"
    and type(vim.api.nvim_get_chan_info) == "function"
    and pcall(vim.api.nvim_get_chan_info, 0)
end

describe("multi-session terminal", function()
  if not running_in_neovim() then
    it("requires a real Neovim process", function()
      pending("spawns real terminal jobs; run inside Neovim with plenary (see file header)")
    end)
    return
  end
  if vim.fn.has("win32") == 1 then
    it("requires a POSIX shell", function()
      pending("uses sh, pgrep and background jobs")
    end)
    return
  end

  local terminal
  local SPLIT_FRACTION = 0.3

  vim.o.columns, vim.o.lines = 200, 50
  require("claudecode").setup({
    auto_start = false,
    terminal_cmd = "sh",
    log_level = "error",
    terminal = { provider = "native" },
  })
  terminal = require("claudecode.terminal")

  ---Windows in the current tab that show a Claude terminal buffer.
  local function claude_wins()
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.b[vim.api.nvim_win_get_buf(win)].claudecode_terminal then
        table.insert(wins, win)
      end
    end
    return wins
  end

  local function only_claude_win()
    local wins = claude_wins()
    assert.are.equal(1, #wins, "expected exactly one Claude window")
    return wins[1]
  end

  ---Opens the first session and waits for its window.
  local function open_session()
    vim.cmd("ClaudeCode")
    assert.is_true(vim.wait(1000, function()
      return #claude_wins() == 1
    end, 20))
    return only_claude_win()
  end

  ---PIDs of processes whose full command line is exactly `cmdline`.
  local function pgrep_exact(cmdline)
    local out = vim.trim(vim.fn.system({ "pgrep", "-f", "^" .. cmdline .. "$" }))
    return out == "" and {} or vim.split(out, "\n")
  end

  ---Closes every session, stops their jobs and drops back to one window.
  local function reset_terminals()
    for _, session in ipairs(terminal.list_sessions()) do
      pcall(terminal.close_session, session.id)
    end
    pcall(terminal.cleanup_all)
    vim.cmd("silent! tabonly! | silent! only!")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].buftype == "terminal" then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end

  for _, side in ipairs({ "right", "bottom" }) do
    local horizontal = side == "bottom"

    describe("split_side=" .. side, function()
      before_each(function()
        terminal.setup({ provider = "native", split_side = side, split_width_percentage = SPLIT_FRACTION }, "sh")
      end)

      after_each(reset_terminals)

      it("opens one sized, pinned Claude window", function()
        local win = open_session()
        if horizontal then
          assert.are.equal(math.floor(vim.o.lines * SPLIT_FRACTION), vim.api.nvim_win_get_height(win))
          assert.is_true(vim.wo[win].winfixheight)
        else
          assert.is_true(math.abs(vim.api.nvim_win_get_width(win) - math.floor(vim.o.columns * SPLIT_FRACTION)) <= 1)
          assert.is_true(vim.wo[win].winfixwidth)
        end
        if vim.fn.has("nvim-0.10") == 1 then
          assert.is_true(vim.wo[win].winfixbuf)
        end
        assert.are.equal("claudecode", vim.bo[vim.api.nvim_win_get_buf(win)].filetype)
      end)

      it("leaves the user's own :terminal window alone", function()
        vim.cmd("botright vsplit | terminal sh")
        local user_win, user_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
        vim.cmd("wincmd p")

        local win = open_session()

        assert.are_not.equal(user_win, win)
        assert.is_true(vim.api.nvim_win_is_valid(user_win))
        assert.are.equal(user_buf, vim.api.nvim_win_get_buf(user_win))
      end)

      it("keeps a manual resize across tab switches and VimResized", function()
        local win = open_session()
        if horizontal then
          vim.api.nvim_win_set_height(win, 9)
        else
          vim.api.nvim_win_set_width(win, 50)
        end

        vim.cmd("tabnew | tabprev")
        vim.api.nvim_exec_autocmds("VimResized", {})
        vim.wait(100)

        win = only_claude_win()
        if horizontal then
          assert.are.equal(9, vim.api.nvim_win_get_height(win))
        else
          assert.are.equal(50, vim.api.nvim_win_get_width(win))
        end
      end)

      it("hides and re-shows the same buffer without stopping the job", function()
        local buf = vim.api.nvim_win_get_buf(open_session())
        local job = vim.b[buf].terminal_job_id

        vim.cmd("ClaudeCode")
        assert.are.equal(0, #claude_wins())
        assert.are.equal(-1, vim.fn.jobwait({ job }, 0)[1], "job should still be running while hidden")

        vim.cmd("ClaudeCode")
        assert.are.equal(buf, vim.api.nvim_win_get_buf(only_claude_win()))
      end)

      it("creates, switches and closes sessions in the one managed window", function()
        local first_buf = vim.api.nvim_win_get_buf(open_session())

        vim.cmd("ClaudeCodeNew")
        assert.is_true(vim.wait(1000, function()
          return terminal.get_session_count() == 2
        end, 20))
        local second_buf = vim.api.nvim_win_get_buf(only_claude_win())
        assert.are_not.equal(first_buf, second_buf)

        -- winfixbuf must not block the manager's own buffer swap (E1513).
        vim.cmd("ClaudeCodeSwitch 1")
        local win = only_claude_win()
        assert.are.equal(first_buf, vim.api.nvim_win_get_buf(win))
        if vim.fn.has("nvim-0.10") == 1 then
          assert.is_true(vim.wo[win].winfixbuf)
        end

        vim.cmd("ClaudeCodeCloseSession 2")
        assert.is_true(vim.wait(1000, function()
          return terminal.get_session_count() == 1
        end, 20))
        assert.are.equal(first_buf, vim.api.nvim_win_get_buf(only_claude_win()))
      end)

      it("sends text to the active session", function()
        open_session()
        vim.cmd("ClaudeCodeNew")
        vim.cmd("ClaudeCodeSwitch 1")
        local active_job = vim.b[vim.api.nvim_win_get_buf(only_claude_win())].terminal_job_id
        local marker = vim.fn.tempname()

        assert.is_true(terminal.send_to_terminal("echo $$ > " .. marker, { submit = true }))

        assert.is_true(vim.wait(2000, function()
          return vim.fn.filereadable(marker) == 1 and #vim.fn.readfile(marker) > 0
        end, 20))
        assert.are.equal(tostring(vim.fn.jobpid(active_job)), vim.fn.readfile(marker)[1])
        os.remove(marker)
      end)

      it("refuses :bnext in the Claude window", function()
        local win = open_session()
        local buf = vim.api.nvim_win_get_buf(win)
        vim.api.nvim_set_current_win(win)

        pcall(vim.cmd, "bnext")

        assert.are.equal(buf, vim.api.nvim_win_get_buf(win))
      end)

      it("cleanup_all stops background children of a session shell", function()
        open_session()
        -- Distinct duration per side so a leftover from one case cannot satisfy another.
        local sleeper = horizontal and "sleep 7772" or "sleep 7771"
        assert.is_true(terminal.send_to_terminal(sleeper .. " &", { submit = true }))
        assert.is_true(
          vim.wait(2000, function()
            return #pgrep_exact(sleeper) > 0
          end, 50),
          "background child never started"
        )

        terminal.cleanup_all()

        assert.is_true(
          vim.wait(2000, function()
            return #pgrep_exact(sleeper) == 0
          end, 50),
          "background child survived cleanup_all"
        )
      end)
    end)
  end

  describe("diff focus", function()
    local diff = require("claudecode.diff")
    local base_config = require("claudecode").state.config
    local target_file

    ---Re-points the diff module at a config with the given keep_terminal_focus.
    local function set_keep_terminal_focus(enabled)
      diff.setup(vim.tbl_deep_extend("force", base_config, { diff_opts = { keep_terminal_focus = enabled } }))
    end

    ---Starts a blocking openDiff the way the MCP tool does (inside a coroutine)
    ---and returns a getter for the result Claude would receive.
    local function open_blocking_diff(tab_name)
      local result
      local co = coroutine.create(function()
        return diff.open_diff_blocking(target_file, target_file, "proposed\n", tab_name)
      end)
      _G.claude_deferred_responses = _G.claude_deferred_responses or {}
      _G.claude_deferred_responses[tostring(co)] = function(r)
        result = r
      end
      local ok, err = coroutine.resume(co)
      assert.is_true(ok, tostring(err))
      return function()
        return result
      end
    end

    ---The window showing the proposed-changes buffer of the diff.
    local function proposed_win()
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.b[vim.api.nvim_win_get_buf(win)].claudecode_diff_tab_name then
          return win
        end
      end
    end

    before_each(function()
      terminal.setup({ provider = "native", split_side = "right", split_width_percentage = SPLIT_FRACTION }, "sh")
      target_file = vim.fn.tempname() .. ".txt"
      vim.fn.writefile({ "original" }, target_file)
    end)

    after_each(function()
      -- Opening a diff with keep_terminal_focus schedules a refocus; run any
      -- pending one now so it cannot move focus during the next test.
      vim.wait(50)
      pcall(diff.close_all_diffs, "test teardown")
      diff.setup(base_config)
      reset_terminals()
      os.remove(target_file)
    end)

    it("keeps focus on the active session after a diff opens and after accept", function()
      open_session()
      vim.cmd("ClaudeCodeNew")
      vim.cmd("ClaudeCodeSwitch 1")
      local active_buf = vim.api.nvim_win_get_buf(only_claude_win())
      vim.cmd("wincmd p") -- start from the editor window, as a user would
      set_keep_terminal_focus(true)

      local get_result = open_blocking_diff("focus-accept")

      assert.is_not_nil(proposed_win(), "diff did not open")
      assert.is_true(
        vim.wait(1000, function()
          return vim.api.nvim_get_current_buf() == active_buf
        end, 20),
        "focus did not return to the active session after the diff opened"
      )

      vim.api.nvim_set_current_win(proposed_win())
      vim.cmd("ClaudeCodeDiffAccept")

      assert.are.equal(active_buf, vim.api.nvim_get_current_buf())
      assert.is_nil(proposed_win(), "diff window survived accept")
      assert.is_true(vim.wait(1000, function()
        return get_result() ~= nil
      end, 20))
      assert.are.equal("FILE_SAVED", get_result().content[1].text)
    end)

    it("returns focus to the active session after deny", function()
      local active_buf = vim.api.nvim_win_get_buf(open_session())
      vim.cmd("wincmd p")
      set_keep_terminal_focus(true)

      local get_result = open_blocking_diff("focus-deny")
      assert.is_true(
        vim.wait(1000, function()
          return vim.api.nvim_get_current_buf() == active_buf
        end, 20),
        "focus did not return to the active session after the diff opened"
      )
      vim.api.nvim_set_current_win(proposed_win())
      vim.cmd("ClaudeCodeDiffDeny")

      assert.are.equal(active_buf, vim.api.nvim_get_current_buf())
      assert.is_true(vim.wait(1000, function()
        return get_result() ~= nil
      end, 20))
      assert.are.equal("DIFF_REJECTED", get_result().content[1].text)
    end)

    it("leaves focus in the diff when keep_terminal_focus is off", function()
      open_session()
      vim.cmd("wincmd p")
      set_keep_terminal_focus(false)

      open_blocking_diff("focus-off")
      vim.wait(100) -- let any scheduled refocus run

      assert.are.equal(proposed_win(), vim.api.nvim_get_current_win())
    end)
  end)
end)
