describe("claudecode.terminal.native toggle behavior", function()
  local native_provider
  local mock_vim
  local logger_spy

  before_each(function()
    -- Set up the package path for tests
    package.path = "./lua/?.lua;" .. package.path

    -- Clean up any loaded modules
    package.loaded["claudecode.terminal.native"] = nil
    package.loaded["claudecode.logger"] = nil

    -- Mock state for more realistic testing
    local mock_state = {
      buffers = {},
      windows = {},
      current_win = 1,
      next_bufnr = 1,
      next_winid = 1000,
      next_jobid = 10000,
      buffer_options = {},
    }

    -- Mock vim API with stateful behavior
    mock_vim = {
      api = {
        nvim_buf_is_valid = function(bufnr)
          return mock_state.buffers[bufnr] ~= nil
        end,
        nvim_win_is_valid = function(winid)
          return mock_state.windows[winid] ~= nil
        end,
        nvim_list_wins = function()
          local wins = {}
          for winid, _ in pairs(mock_state.windows) do
            table.insert(wins, winid)
          end
          return wins
        end,
        nvim_list_bufs = function()
          local bufs = {}
          for bufnr, _ in pairs(mock_state.buffers) do
            table.insert(bufs, bufnr)
          end
          return bufs
        end,
        nvim_buf_get_name = function(bufnr)
          local buf = mock_state.buffers[bufnr]
          return buf and buf.name or ""
        end,
        nvim_buf_get_option = function(bufnr, option)
          local buf = mock_state.buffers[bufnr]
          if buf and buf.options and buf.options[option] then
            return buf.options[option]
          end
          return ""
        end,
        nvim_buf_set_option = function(bufnr, option, value)
          local buf = mock_state.buffers[bufnr]
          if buf then
            buf.options = buf.options or {}
            buf.options[option] = value
            -- Track calls for verification
            mock_state.buffer_options[bufnr] = mock_state.buffer_options[bufnr] or {}
            mock_state.buffer_options[bufnr][option] = value
          end
        end,
        nvim_win_get_buf = function(winid)
          local win = mock_state.windows[winid]
          return win and win.bufnr or 0
        end,
        nvim_win_close = function(winid, force)
          -- Remove window from state (simulates window closing)
          if winid and mock_state.windows[winid] then
            mock_state.windows[winid] = nil
          end
        end,
        nvim_get_current_win = function()
          return mock_state.current_win
        end,
        nvim_get_current_buf = function()
          local current_win = mock_state.current_win
          local win = mock_state.windows[current_win]
          return win and win.bufnr or 0
        end,
        nvim_set_current_win = function(winid)
          if mock_state.windows[winid] then
            mock_state.current_win = winid
          end
        end,
        nvim_win_set_buf = function(winid, bufnr)
          local win = mock_state.windows[winid]
          if win and mock_state.buffers[bufnr] then
            win.bufnr = bufnr
          end
        end,
        nvim_win_set_height = function(winid, height)
          -- Mock window resizing
        end,
        nvim_win_set_width = function(winid, width)
          -- Mock window resizing
        end,
        nvim_win_call = function(winid, fn)
          -- Mock window-specific function execution
          return fn()
        end,
      },
      cmd = function(command)
        -- Handle vsplit/split and other commands
        if
          command:match("^topleft %d+vsplit")
          or command:match("^botright %d+vsplit")
          or command:match("^topleft %d+split")
          or command:match("^botright %d+split")
        then
          -- Create new window
          local winid = mock_state.next_winid
          mock_state.next_winid = mock_state.next_winid + 1
          mock_state.windows[winid] = { bufnr = 0 }
          mock_state.current_win = winid
        elseif command == "enew" then
          -- Create new buffer in current window
          local bufnr = mock_state.next_bufnr
          mock_state.next_bufnr = mock_state.next_bufnr + 1
          mock_state.buffers[bufnr] = { name = "", options = {} }
          if mock_state.windows[mock_state.current_win] then
            mock_state.windows[mock_state.current_win].bufnr = bufnr
          end
        end
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
        termopen = function(cmd, opts)
          local jobid = mock_state.next_jobid
          mock_state.next_jobid = mock_state.next_jobid + 1

          -- Create terminal buffer
          local bufnr = mock_state.next_bufnr
          mock_state.next_bufnr = mock_state.next_bufnr + 1
          mock_state.buffers[bufnr] = {
            name = "term://claude",
            options = { buftype = "terminal", bufhidden = "wipe" },
            jobid = jobid,
            on_exit = opts.on_exit,
          }

          -- Set buffer in current window
          if mock_state.windows[mock_state.current_win] then
            mock_state.windows[mock_state.current_win].bufnr = bufnr
          end

          return jobid
        end,
      },
      keymap = {
        set = function() end,
      },
      schedule = function(callback)
        callback() -- Execute immediately in tests
      end,
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
              -- Mock buffer option setting
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
    }
    _G.vim = mock_vim

    -- Mock logger
    logger_spy = {
      debug = function(module, message, ...)
        -- Track debug calls for verification
      end,
      error = function(module, message, ...)
        -- Track error calls
      end,
    }
    package.loaded["claudecode.logger"] = logger_spy

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
    package.loaded["claudecode.terminal.native"] = nil
    package.loaded["claudecode.logger"] = nil
  end)

  describe("toggle with no existing terminal", function()
    it("should create a new terminal when none exists", function()
      pending("re-ported in Task 5: native terminal buffer creation via parse_command argv")
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

    it("should set filetype to claudecode on the terminal buffer", function()
      pending("re-ported in Task 5: filetype claudecode on the native terminal buffer")
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      native_provider.open(cmd_string, env_table, config)

      local bufnr = native_provider.get_active_bufnr()
      assert.is_not_nil(bufnr)

      local mock_state = _G.get_mock_state()
      assert.are.equal("claudecode", mock_state.buffers[bufnr].options.filetype)
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

      local mock_state = _G.get_mock_state()

      -- Find the terminal window
      local terminal_winid = nil
      for winid, win in pairs(mock_state.windows) do
        if win.bufnr == initial_bufnr then
          terminal_winid = winid
          break
        end
      end

      -- Mock being in terminal window
      mock_state.current_win = terminal_winid

      -- Toggle should hide but preserve process
      native_provider.toggle(cmd_string, env_table, config)
      assert.are.equal(initial_bufnr, native_provider.get_active_bufnr())

      -- Close should kill the process (cleanup_state called)
      native_provider.close()
      assert.is_nil(native_provider.get_active_bufnr())
    end)
  end)

  describe("simple_toggle behavior", function()
    -- "should always hide terminal when visible, regardless of focus" and
    -- "should show hidden terminal when toggled" are now window_manager
    -- concerns; see window_manager_spec.lua ("close_window hides the managed
    -- window and updates visibility state", "recreates the managed window
    -- when the previous one was closed externally").

    it("should always show terminal when not visible", function()
      pending("re-ported in Task 5: native terminal buffer creation via parse_command argv")
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
