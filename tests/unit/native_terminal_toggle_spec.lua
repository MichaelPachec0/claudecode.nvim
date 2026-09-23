describe("claudecode.terminal.native toggle behavior", function()
  local native_provider
  local mock_vim
  local logger_spy
  local mock_state

  before_each(function()
    -- Set up the package path for tests
    package.path = "./lua/?.lua;" .. package.path

    -- Clean up any loaded modules. "claudecode.terminal.native" pulls in
    -- claudecode.session and claudecode.terminal.window_manager (real modules,
    -- fresh each test) plus claudecode.terminal (stubbed below, since the real
    -- module also boots the websocket server and is out of scope for this
    -- unit-level provider test).
    package.loaded["claudecode.terminal.native"] = nil
    package.loaded["claudecode.terminal.window_manager"] = nil
    package.loaded["claudecode.terminal.osc_handler"] = nil
    package.loaded["claudecode.terminal.tabbar"] = nil
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.tab_registry"] = nil
    package.loaded["claudecode.utils"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.terminal"] = nil

    -- Mock state: buffers/windows are a single tabpage (tabpage handle 1).
    mock_state = {
      buffers = {},
      windows = {},
      current_win = nil,
      current_buf_context = nil, -- bufnr currently inside nvim_buf_call
      next_bufnr = 1,
      next_winid = 1000,
      next_jobid = 10000,
      job_exit_callbacks = {}, -- jobid -> on_exit callback
      termopen_calls = {},
    }

    -- Mock vim API with stateful behavior matching the window-less native
    -- provider (PR #164): providers create buffers via nvim_create_buf and
    -- run termopen inside nvim_buf_call; window_manager.display_buffer puts
    -- the buffer in the single managed window.
    mock_vim = {
      api = {
        nvim_create_buf = function(listed, scratch)
          local bufnr = mock_state.next_bufnr
          mock_state.next_bufnr = bufnr + 1
          mock_state.buffers[bufnr] = {
            name = "",
            -- channel defaults to 0 (no attached job yet) so window_manager's
            -- `chan and chan > 0` resize check never compares against the
            -- generic "" fallback used for unset string options below.
            options = { channel = 0 },
            vars = {},
            listed = listed,
            scratch = scratch,
          }
          return bufnr
        end,
        nvim_buf_is_valid = function(bufnr)
          return mock_state.buffers[bufnr] ~= nil
        end,
        nvim_buf_delete = function(bufnr, _)
          mock_state.buffers[bufnr] = nil
        end,
        nvim_buf_call = function(bufnr, fn)
          local prev = mock_state.current_buf_context
          mock_state.current_buf_context = bufnr
          local ok, result = pcall(fn)
          mock_state.current_buf_context = prev
          if not ok then
            error(result, 0)
          end
          return result
        end,
        nvim_buf_get_var = function(bufnr, name)
          local buf = mock_state.buffers[bufnr]
          return buf and buf.vars and buf.vars[name]
        end,
        nvim_buf_set_var = function(bufnr, name, value)
          local buf = mock_state.buffers[bufnr]
          if buf then
            buf.vars = buf.vars or {}
            buf.vars[name] = value
          end
        end,
        nvim_buf_get_name = function(bufnr)
          local buf = mock_state.buffers[bufnr]
          return buf and buf.name or ""
        end,
        nvim_win_is_valid = function(winid)
          return mock_state.windows[winid] ~= nil
        end,
        nvim_win_get_buf = function(winid)
          local win = mock_state.windows[winid]
          return win and win.bufnr or 0
        end,
        nvim_win_get_tabpage = function(_)
          return 1
        end,
        nvim_win_get_width = function(_)
          return 80
        end,
        nvim_win_get_height = function(_)
          return 24
        end,
        nvim_win_set_height = function(_, _) end,
        nvim_win_set_width = function(_, _) end,
        nvim_win_close = function(winid, _)
          mock_state.windows[winid] = nil
          if mock_state.current_win == winid then
            mock_state.current_win = nil
          end
        end,
        nvim_win_set_buf = function(winid, bufnr)
          local win = mock_state.windows[winid]
          if win then
            win.bufnr = bufnr
          end
        end,
        nvim_get_current_tabpage = function()
          return 1
        end,
        nvim_tabpage_list_wins = function(_)
          local wins = {}
          for winid, _ in pairs(mock_state.windows) do
            table.insert(wins, winid)
          end
          return wins
        end,
        nvim_tabpage_is_valid = function(_)
          return true
        end,
        nvim_get_current_win = function()
          return mock_state.current_win
        end,
        nvim_set_current_win = function(winid)
          if mock_state.windows[winid] then
            mock_state.current_win = winid
          end
        end,
        nvim_create_augroup = function(_, _)
          return 1
        end,
        nvim_create_autocmd = function(_, _) end,
        nvim_del_augroup_by_id = function(_) end,
        nvim_exec_autocmds = function(_, _) end,
        nvim_feedkeys = function(_, _, _) end,
      },
      cmd = function(command)
        if
          command == "topleft new"
          or command == "botright new"
          or command == "topleft vertical new"
          or command == "botright vertical new"
        then
          local winid = mock_state.next_winid
          mock_state.next_winid = winid + 1
          mock_state.windows[winid] = { bufnr = 0 }
          mock_state.current_win = winid
        end
        -- "startinsert" and any other command are recorded but not simulated.
      end,
      o = {
        columns = 120,
        lines = 40,
      },
      fn = {
        has = function(feature)
          if feature == "nvim-0.10" then
            return mock_state.has_nvim_010 == false and 0 or 1
          end
          return 0
        end,
        jobresize = function(_, _, _) end,
        jobpid = function(jobid)
          return 100000 + jobid
        end,
        system = function(_) end,
        termopen = function(cmd, opts)
          local jobid = mock_state.next_jobid
          mock_state.next_jobid = jobid + 1

          local target_buf = mock_state.current_buf_context
          if target_buf and mock_state.buffers[target_buf] then
            mock_state.buffers[target_buf].options.buftype = "terminal"
            mock_state.buffers[target_buf].options.channel = jobid
          end

          mock_state.job_exit_callbacks[jobid] = opts and opts.on_exit
          table.insert(mock_state.termopen_calls, { cmd = cmd, opts = opts, jobid = jobid })

          return jobid
        end,
        jobstop = function(jobid)
          local callback = mock_state.job_exit_callbacks[jobid]
          if callback then
            mock_state.job_exit_callbacks[jobid] = nil
            callback(jobid, 0, "exit")
          end
          return 1
        end,
      },
      keymap = {
        set = function() end,
      },
      notify = function() end,
      schedule = function(callback)
        callback() -- Execute immediately in tests
      end,
      defer_fn = function(callback)
        callback() -- Execute immediately in tests
      end,
      log = { levels = { INFO = 1, WARN = 2, ERROR = 3 } },
      wo = setmetatable({}, {
        __index = function(_, win)
          return setmetatable({}, {
            __newindex = function(_, option, value)
              local w = mock_state.windows[win]
              if w then
                w.options = w.options or {}
                w.options[option] = value
              end
            end,
            __index = function(_, option)
              local w = mock_state.windows[win]
              return w and w.options and w.options[option]
            end,
          })
        end,
      }),
      bo = setmetatable({}, {
        __index = function(_, bufnr)
          return setmetatable({}, {
            __newindex = function(_, option, value)
              local buf = mock_state.buffers[bufnr]
              if buf then
                buf.options = buf.options or {}
                buf.options[option] = value
              end
            end,
            __index = function(_, option)
              local buf = mock_state.buffers[bufnr]
              return buf and buf.options and buf.options[option] or ""
            end,
          })
        end,
      }),
      b = setmetatable({}, {
        __index = function(_, bufnr)
          local buf = mock_state.buffers[bufnr]
          if not buf then
            return {}
          end
          buf.vars = buf.vars or {}
          return buf.vars
        end,
        __newindex = function(_, bufnr, vars)
          local buf = mock_state.buffers[bufnr]
          if buf then
            buf.vars = vars
          end
        end,
      }),
    }
    _G.vim = mock_vim

    -- Mock logger
    logger_spy = {
      debug = function(module, message, ...) end,
      warn = function(module, message, ...) end,
      error = function(module, message, ...) end,
    }
    package.loaded["claudecode.logger"] = logger_spy

    -- Stub the parent "claudecode.terminal" module. The real module also
    -- boots the websocket server and a raft of other subsystems at require
    -- time; native.lua only needs these few entry points from it.
    package.loaded["claudecode.terminal"] = {
      defaults = { show_native_term_exit_tip = false, auto_insert = true },
      setup_scroll_keymaps = function() end,
      setup_terminal_keymaps = function() end,
      register_buffer_session = function() end,
      update_session_terminal_info = function() end,
      track_terminal_pid = function() end,
    }

    -- Load the native provider
    native_provider = require("claudecode.terminal.native")
    native_provider.setup({})

    -- Helper function to get mock state for verification
    _G.get_mock_state = function()
      return mock_state
    end
  end)

  after_each(function()
    _G.vim = nil
    _G.get_mock_state = nil
    package.loaded["claudecode.terminal.native"] = nil
    package.loaded["claudecode.terminal.window_manager"] = nil
    package.loaded["claudecode.terminal.osc_handler"] = nil
    package.loaded["claudecode.terminal.tabbar"] = nil
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.tab_registry"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.logger"] = nil
  end)

  describe("toggle with no existing terminal", function()
    it("should create a new terminal when none exists", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Mock termopen to succeed
      mock_vim.fn.termopen = function(cmd, opts)
        assert.are.equal(cmd_string, cmd[1])
        assert.are.same(env_table, opts.env)
        return 12345 -- Valid job ID
      end

      native_provider.toggle(cmd_string, env_table, config)

      -- Should have created terminal and have active buffer
      assert.is_not_nil(native_provider.get_active_bufnr())
    end)

    it("passes a bracketed model alias as one argv element", function()
      local env_table = {}
      local config = { split_side = "right", split_width_percentage = 0.3 }
      local captured_cmd

      mock_vim.fn.termopen = function(cmd, opts)
        captured_cmd = cmd
        return 12345
      end

      native_provider.open("claude --model opus[1m]", env_table, config)

      assert.are.same({ "claude", "--model", "opus[1m]" }, captured_cmd)
    end)

    it("keeps quoted arguments intact", function()
      local env_table = {}
      local config = { split_side = "right", split_width_percentage = 0.3 }
      local captured_cmd

      mock_vim.fn.termopen = function(cmd, opts)
        captured_cmd = cmd
        return 12345
      end

      native_provider.open([[claude --append-system-prompt "be brief"]], env_table, config)

      assert.are.same({ "claude", "--append-system-prompt", "be brief" }, captured_cmd)
    end)

    it("should set filetype to claudecode on the terminal buffer", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      native_provider.open(cmd_string, env_table, config)

      local bufnr = native_provider.get_active_bufnr()
      assert.is_not_nil(bufnr)

      local state = _G.get_mock_state()
      assert.are.equal("claudecode", state.buffers[bufnr].options.filetype)
    end)

    it("sets bufhidden to hide on the terminal buffer", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      native_provider.open(cmd_string, env_table, config)

      local bufnr = native_provider.get_active_bufnr()
      assert.is_not_nil(bufnr)

      local state = _G.get_mock_state()
      assert.are.equal("hide", state.buffers[bufnr].options.bufhidden)
    end)

    -- Window pinning (winfixwidth/winfixheight/winfixbuf, nospell) is owned by
    -- window_manager, not this provider; see the "split_side (top/bottom/left/right)
    -- and window pinning" describe block in tests/unit/terminal/window_manager_spec.lua.
  end)

  -- "toggle with existing hidden terminal" and "toggle with visible terminal":
  -- managed-window reuse and hide/show/focus of the pinned window are now
  -- window_manager concerns; see window_manager_spec.lua ("recreates the
  -- managed window when the previous one was closed externally", "close_window
  -- hides the managed window and updates visibility state", "display_buffer
  -- focuses the window and starts insert mode when focus=true").

  describe("close vs toggle behavior", function()
    it("should preserve process on toggle but kill on close", function()
      pending("re-ported in Task 5: close() must stop the terminal job (upstream ClaudeCodeClose semantics)")
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Create a terminal
      native_provider.open(cmd_string, env_table, config)
      local initial_bufnr = native_provider.get_active_bufnr()
      assert.is_not_nil(initial_bufnr)

      local state = _G.get_mock_state()

      -- Find the terminal window
      local terminal_winid = nil
      for winid, win in pairs(state.windows) do
        if win.bufnr == initial_bufnr then
          terminal_winid = winid
          break
        end
      end
      assert.is_not_nil(terminal_winid)

      -- Mock being in terminal window
      state.current_win = terminal_winid

      -- Toggle should hide but preserve process
      native_provider.toggle(cmd_string, env_table, config)
      assert.are.equal(initial_bufnr, native_provider.get_active_bufnr())

      -- Job must still be running (on_exit not fired yet)
      assert.is_not_nil(next(state.job_exit_callbacks))

      -- Close should kill the process (jobstop) and clean up via the on_exit handler
      native_provider.close()
      assert.is_nil(native_provider.get_active_bufnr())
      assert.is_nil(next(state.job_exit_callbacks))
    end)
  end)

  describe("simple_toggle behavior", function()
    -- "should always hide terminal when visible, regardless of focus" and
    -- "should show hidden terminal when toggled" are now window_manager
    -- concerns; see window_manager_spec.lua ("close_window hides the managed
    -- window and updates visibility state", "recreates the managed window
    -- when the previous one was closed externally").

    it("should always show terminal when not visible", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Start with no terminal
      assert.is_nil(native_provider.get_active_bufnr())

      -- Simple toggle should create new terminal
      native_provider.simple_toggle(cmd_string, env_table, config)

      -- Should have created terminal
      assert.is_not_nil(native_provider.get_active_bufnr())
    end)
  end)

  -- "focus_toggle behavior": focus/hide of the pinned window and the
  -- top/bottom split_side command and size are now window_manager concerns;
  -- see window_manager_spec.lua ("display_buffer focuses the window and
  -- starts insert mode when focus=true", "close_window hides the managed
  -- window and updates visibility state", "creates a horizontal split sized
  -- by lines for split_side=bottom", "creates a horizontal split using
  -- topleft for split_side=top").
end)
