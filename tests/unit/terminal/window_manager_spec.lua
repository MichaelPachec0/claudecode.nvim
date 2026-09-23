describe("claudecode.terminal.window_manager", function()
  local window_manager
  local mock_vim
  local original_vim
  local spy

  before_each(function()
    -- Store original vim global
    original_vim = vim

    -- Create spy module
    spy = require("luassert.spy")

    -- Create mock vim
    mock_vim = {
      api = {
        nvim_win_is_valid = spy.new(function()
          return true
        end),
        nvim_win_get_buf = spy.new(function()
          return 1
        end),
        nvim_win_get_width = spy.new(function()
          return 80
        end),
        nvim_win_get_height = spy.new(function()
          return 24
        end),
        nvim_get_current_win = spy.new(function()
          return 1000
        end),
        nvim_create_augroup = spy.new(function()
          return 1
        end),
        nvim_create_autocmd = spy.new(function() end),
      },
      bo = setmetatable({}, {
        __index = function(_, bufnr)
          return { channel = 123 }
        end,
      }),
      fn = {
        jobresize = spy.new(function() end),
        has = spy.new(function(feature)
          if feature == "nvim-0.10" then
            return 1
          end
          return 0
        end),
      },
      defer_fn = spy.new(function(fn, delay)
        fn()
      end),
    }

    -- Set global vim to mock
    _G.vim = mock_vim

    -- Clear package cache and reload module
    package.loaded["claudecode.terminal.window_manager"] = nil
    package.loaded["claudecode.logger"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = spy.new(function() end),
      info = spy.new(function() end),
      warn = spy.new(function() end),
      error = spy.new(function() end),
    }

    window_manager = require("claudecode.terminal.window_manager")
  end)

  after_each(function()
    -- Restore original vim
    _G.vim = original_vim
    -- Reset module state
    package.loaded["claudecode.terminal.window_manager"] = nil
  end)

  describe("setup", function()
    it("should create resize autocommands", function()
      window_manager.setup({})

      -- Should create augroup
      assert.spy(mock_vim.api.nvim_create_augroup).was_called_with("ClaudeCodeTerminalResize", { clear = true })

      -- Should create VimResized, WinEnter, TabEnter, and TermEnter autocommands
      assert.spy(mock_vim.api.nvim_create_autocmd).was_called(4)
    end)

    it("should create VimResized autocommand", function()
      window_manager.setup({})

      local calls = mock_vim.api.nvim_create_autocmd.calls
      local vim_resized_found = false

      for _, call in ipairs(calls) do
        if call.vals[1] == "VimResized" then
          vim_resized_found = true
          assert.is_not_nil(call.vals[2].group)
          assert.is_function(call.vals[2].callback)
        end
      end

      assert.is_true(vim_resized_found, "VimResized autocommand should be created")
    end)

    it("should create WinEnter autocommand", function()
      window_manager.setup({})

      local calls = mock_vim.api.nvim_create_autocmd.calls
      local win_enter_found = false

      for _, call in ipairs(calls) do
        if call.vals[1] == "WinEnter" then
          win_enter_found = true
          assert.is_not_nil(call.vals[2].group)
          assert.is_function(call.vals[2].callback)
        end
      end

      assert.is_true(win_enter_found, "WinEnter autocommand should be created")
    end)

    it("should create TabEnter autocommand", function()
      window_manager.setup({})

      local calls = mock_vim.api.nvim_create_autocmd.calls
      local tab_enter_found = false

      for _, call in ipairs(calls) do
        if call.vals[1] == "TabEnter" then
          tab_enter_found = true
          assert.is_not_nil(call.vals[2].group)
          assert.is_function(call.vals[2].callback)
        end
      end

      assert.is_true(tab_enter_found, "TabEnter autocommand should be created")
    end)

    it("should create TermEnter autocommand", function()
      window_manager.setup({})

      local calls = mock_vim.api.nvim_create_autocmd.calls
      local term_enter_found = false

      for _, call in ipairs(calls) do
        if call.vals[1] == "TermEnter" then
          term_enter_found = true
          assert.is_not_nil(call.vals[2].group)
          assert.is_function(call.vals[2].callback)
        end
      end

      assert.is_true(term_enter_found, "TermEnter autocommand should be created")
    end)
  end)

  describe("ensure_window buffer ownership", function()
    it("does not claim a user's unrelated terminal window", function()
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)
      local other_terminal_win = 2000
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return { other_terminal_win }
      end)
      mock_vim.api.nvim_win_is_valid = spy.new(function()
        return true
      end)
      mock_vim.api.nvim_win_get_buf = spy.new(function()
        return 1
      end)
      -- Plain :terminal buffer: buftype is "terminal" but no claudecode flag
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { buftype = "terminal", channel = 123 }
        end,
      })
      mock_vim.b = setmetatable({}, {
        __index = function()
          return {}
        end,
      })

      -- The fallback path creates a fresh split window
      mock_vim.o = { columns = 200 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_get_current_win = spy.new(function()
        return 1000
      end)

      window_manager.setup({})

      local win = window_manager.ensure_window()
      assert.are_not.equal(other_terminal_win, win)
    end)

    it("claims a window showing a Claude terminal buffer", function()
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)
      local claude_win = 2000
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return { claude_win }
      end)
      mock_vim.api.nvim_win_is_valid = spy.new(function()
        return true
      end)
      mock_vim.api.nvim_win_get_buf = spy.new(function()
        return 1
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { buftype = "terminal", channel = 123 }
        end,
      })
      mock_vim.b = setmetatable({}, {
        __index = function()
          return { claudecode_terminal = true }
        end,
      })

      window_manager.setup({})

      assert.are.equal(claude_win, window_manager.ensure_window())
    end)
  end)

  describe("notify_resize", function()
    it("should be a no-op when no terminal window exists", function()
      window_manager.setup({})
      -- Don't set up any window
      window_manager.notify_resize()

      -- jobresize should not be called
      assert.spy(mock_vim.fn.jobresize).was_not_called()
    end)

    it("should be a no-op when window is not valid", function()
      mock_vim.api.nvim_win_is_valid = spy.new(function()
        return false
      end)

      window_manager.setup({})
      window_manager.notify_resize()

      assert.spy(mock_vim.fn.jobresize).was_not_called()
    end)

    it("should call jobresize with correct dimensions when terminal window exists", function()
      -- Mock additional APIs needed for window creation
      mock_vim.o = { columns = 200 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return {}
      end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)

      window_manager.setup({})

      -- Create a window first
      local winid = window_manager.ensure_window()
      assert.is_not_nil(winid)

      -- Now call notify_resize
      window_manager.notify_resize()

      -- jobresize should be called with channel and dimensions
      assert.spy(mock_vim.fn.jobresize).was_called_with(123, 80, 24)
    end)

    it("should not call jobresize when channel is invalid", function()
      -- Mock buffer with no channel
      mock_vim.bo = setmetatable({}, {
        __index = function(_, bufnr)
          return { channel = 0 }
        end,
      })
      mock_vim.o = { columns = 200 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return {}
      end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)

      window_manager.setup({})

      -- Create a window first
      window_manager.ensure_window()

      -- Now call notify_resize
      window_manager.notify_resize()

      -- jobresize should not be called with invalid channel
      assert.spy(mock_vim.fn.jobresize).was_not_called()
    end)
  end)

  describe("VimResized autocommand callback", function()
    it("should call notify_resize on VimResized event", function()
      -- Mock additional APIs needed for window creation
      mock_vim.o = { columns = 200 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return {}
      end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)

      window_manager.setup({})

      -- Create a window first
      window_manager.ensure_window()

      -- Find and call the VimResized callback
      local vim_resized_callback
      for _, call in ipairs(mock_vim.api.nvim_create_autocmd.calls) do
        if call.vals[1] == "VimResized" then
          vim_resized_callback = call.vals[2].callback
          break
        end
      end

      assert.is_function(vim_resized_callback)

      -- Call the callback
      vim_resized_callback()

      -- jobresize should be called
      assert.spy(mock_vim.fn.jobresize).was_called()
    end)
  end)

  describe("WinEnter autocommand callback", function()
    -- WinEnter only sends jobresize immediately when the entered window IS the
    -- terminal window; entering any other window defers the resize until
    -- TermEnter (so sidebar toggles do not make the TUI redraw). See the
    -- WinEnter handler in window_manager.lua.
    it("should call notify_resize when entering the terminal window itself", function()
      -- Mock additional APIs needed
      mock_vim.o = { columns = 200 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)

      -- Mock find_terminal_window to return a terminal window
      local terminal_win = 2000
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return { terminal_win }
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { buftype = "terminal", channel = 123 }
        end,
      })
      mock_vim.b = setmetatable({}, {
        __index = function()
          return { claudecode_terminal = true }
        end,
      })
      mock_vim.api.nvim_win_is_valid = spy.new(function()
        return true
      end)
      mock_vim.api.nvim_win_get_buf = spy.new(function()
        return 1
      end)
      mock_vim.api.nvim_get_current_win = spy.new(function()
        return terminal_win
      end)

      window_manager.setup({})

      -- Find the WinEnter callback
      local win_enter_callback
      for _, call in ipairs(mock_vim.api.nvim_create_autocmd.calls) do
        if call.vals[1] == "WinEnter" then
          win_enter_callback = call.vals[2].callback
          break
        end
      end

      assert.is_function(win_enter_callback)

      -- Reset spies
      mock_vim.fn.jobresize = spy.new(function() end)
      mock_vim.defer_fn = spy.new(function(fn, delay)
        fn()
      end)

      -- Call the callback (entering the terminal window)
      win_enter_callback()

      -- The resize is sent immediately, not deferred
      assert.spy(mock_vim.fn.jobresize).was_called()
    end)

    it("should defer the resize to TermEnter when entering a different window", function()
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)
      local terminal_win = 2000
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return { terminal_win, 1000 }
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { buftype = "terminal", channel = 123 }
        end,
      })
      mock_vim.b = setmetatable({}, {
        __index = function()
          return { claudecode_terminal = true }
        end,
      })
      -- The user is in a non-terminal window (1000)
      mock_vim.api.nvim_get_current_win = spy.new(function()
        return 1000
      end)

      window_manager.setup({})

      local callbacks = {}
      for _, call in ipairs(mock_vim.api.nvim_create_autocmd.calls) do
        callbacks[call.vals[1]] = call.vals[2].callback
      end
      assert.is_function(callbacks.WinEnter)
      assert.is_function(callbacks.TermEnter)

      mock_vim.fn.jobresize = spy.new(function() end)

      callbacks.WinEnter()
      assert.spy(mock_vim.fn.jobresize).was_not_called()

      callbacks.TermEnter()
      assert.spy(mock_vim.fn.jobresize).was_called()
    end)

    it("should NOT restore configured width on WinEnter (allows manual resizing)", function()
      mock_vim.o = { columns = 200 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)

      local terminal_win = 2000
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return { terminal_win }
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { buftype = "terminal", channel = 123 }
        end,
      })
      mock_vim.b = setmetatable({}, {
        __index = function()
          return { claudecode_terminal = true }
        end,
      })
      mock_vim.api.nvim_win_is_valid = spy.new(function()
        return true
      end)
      mock_vim.api.nvim_win_get_buf = spy.new(function()
        return 1
      end)
      mock_vim.api.nvim_get_current_win = spy.new(function()
        return terminal_win
      end)

      window_manager.setup({ split_width_percentage = 0.4 })

      local win_enter_callback
      for _, call in ipairs(mock_vim.api.nvim_create_autocmd.calls) do
        if call.vals[1] == "WinEnter" then
          win_enter_callback = call.vals[2].callback
          break
        end
      end

      assert.is_function(win_enter_callback)

      -- Reset spies after setup
      mock_vim.fn.jobresize = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.defer_fn = spy.new(function(fn, delay)
        fn()
      end)

      win_enter_callback()

      -- jobresize should be called (notify_resize works)
      assert.spy(mock_vim.fn.jobresize).was_called()

      -- BUT nvim_win_set_width should NOT be called (no width restoration on WinEnter)
      assert.spy(mock_vim.api.nvim_win_set_width).was_not_called()
    end)

    it("should not call notify_resize when no terminal in tab", function()
      -- Mock additional APIs
      mock_vim.o = { columns = 200 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)

      -- Mock find_terminal_window to return nil (no terminal in tab)
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return { 1001 } -- A non-terminal window
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { buftype = "", channel = 0 } -- Not a terminal
        end,
      })
      mock_vim.api.nvim_win_is_valid = spy.new(function()
        return true
      end)
      mock_vim.api.nvim_win_get_buf = spy.new(function()
        return 1
      end)

      window_manager.setup({})

      -- Find the WinEnter callback
      local win_enter_callback
      for _, call in ipairs(mock_vim.api.nvim_create_autocmd.calls) do
        if call.vals[1] == "WinEnter" then
          win_enter_callback = call.vals[2].callback
          break
        end
      end

      assert.is_function(win_enter_callback)

      -- Reset spies
      mock_vim.fn.jobresize = spy.new(function() end)
      mock_vim.defer_fn = spy.new(function(fn, delay)
        fn()
      end)

      -- Call the callback
      win_enter_callback()

      -- defer_fn should not be called since no terminal in tab
      assert.spy(mock_vim.defer_fn).was_not_called()

      -- jobresize should not be called
      assert.spy(mock_vim.fn.jobresize).was_not_called()
    end)
  end)

  describe("TabEnter autocommand callback", function()
    it("should find terminal window and call notify_resize when switching tabs", function()
      -- Mock additional APIs needed for window creation
      mock_vim.o = { columns = 200 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)

      -- Mock find_terminal_window to return a terminal window in the new tab
      local terminal_win_in_tab = 2000
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return { terminal_win_in_tab }
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function(_, bufnr)
          return { buftype = "terminal", channel = 123 }
        end,
      })
      mock_vim.b = setmetatable({}, {
        __index = function()
          return { claudecode_terminal = true }
        end,
      })

      window_manager.setup({})

      -- Find the TabEnter callback
      local tab_enter_callback
      for _, call in ipairs(mock_vim.api.nvim_create_autocmd.calls) do
        if call.vals[1] == "TabEnter" then
          tab_enter_callback = call.vals[2].callback
          break
        end
      end

      assert.is_function(tab_enter_callback)

      -- Mock the terminal window validation and dimensions
      mock_vim.api.nvim_win_is_valid = spy.new(function(win)
        return win == terminal_win_in_tab
      end)
      mock_vim.api.nvim_win_get_buf = spy.new(function()
        return 1
      end)

      -- Reset spies
      mock_vim.fn.jobresize = spy.new(function() end)
      mock_vim.defer_fn = spy.new(function(fn, delay)
        fn()
      end)

      -- Call the callback (simulating tab switch)
      tab_enter_callback()

      -- defer_fn should be called
      assert.spy(mock_vim.defer_fn).was_called()

      -- Since our mock immediately executes the deferred function, jobresize should be called
      assert.spy(mock_vim.fn.jobresize).was_called()
    end)

    it("should not call notify_resize when no terminal window in new tab", function()
      -- Mock additional APIs
      mock_vim.o = { columns = 200 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)

      -- Mock find_terminal_window to return nil (no terminal in this tab)
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return { 1001 } -- A non-terminal window
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function(_, bufnr)
          return { buftype = "", channel = 0 } -- Not a terminal
        end,
      })
      mock_vim.api.nvim_win_is_valid = spy.new(function()
        return true
      end)
      mock_vim.api.nvim_win_get_buf = spy.new(function()
        return 1
      end)

      window_manager.setup({})

      -- Find the TabEnter callback
      local tab_enter_callback
      for _, call in ipairs(mock_vim.api.nvim_create_autocmd.calls) do
        if call.vals[1] == "TabEnter" then
          tab_enter_callback = call.vals[2].callback
          break
        end
      end

      assert.is_function(tab_enter_callback)

      -- Reset spies
      mock_vim.fn.jobresize = spy.new(function() end)
      mock_vim.defer_fn = spy.new(function(fn, delay)
        fn()
      end)

      -- Call the callback (simulating tab switch)
      tab_enter_callback()

      -- defer_fn should not be called since no terminal window found
      assert.spy(mock_vim.defer_fn).was_not_called()

      -- jobresize should not be called
      assert.spy(mock_vim.fn.jobresize).was_not_called()
    end)
  end)

  describe("split_side (top/bottom/left/right) and window pinning", function()
    local win_options

    before_each(function()
      win_options = {}
      mock_vim.o = { columns = 200, lines = 40 }
      mock_vim.wo = setmetatable({}, {
        __index = function(_, win)
          win_options[win] = win_options[win] or {}
          return setmetatable({}, {
            __index = function(_, opt)
              return win_options[win][opt]
            end,
            __newindex = function(_, opt, val)
              win_options[win][opt] = val
            end,
          })
        end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.fn.has = spy.new(function(feature)
        if feature == "nvim-0.10" then
          return 1
        end
        return 0
      end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_win_set_height = spy.new(function() end)
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return {}
      end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)
    end)

    it("creates a horizontal split sized by lines for split_side=bottom", function()
      window_manager.setup({ split_side = "bottom", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()

      assert.spy(mock_vim.cmd).was_called_with("botright new")
      assert.spy(mock_vim.api.nvim_win_set_height).was_called_with(win, 12)
    end)

    it("creates a horizontal split using topleft for split_side=top", function()
      window_manager.setup({ split_side = "top", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()

      assert.spy(mock_vim.cmd).was_called_with("topleft new")
      assert.spy(mock_vim.api.nvim_win_set_height).was_called_with(win, 12)
    end)

    it("creates a vertical split sized by columns for split_side=right", function()
      window_manager.setup({ split_side = "right", split_width_percentage = 0.25 })
      local win = window_manager.ensure_window()

      assert.spy(mock_vim.cmd).was_called_with("botright vertical new")
      assert.spy(mock_vim.api.nvim_win_set_width).was_called_with(win, 50)
    end)

    it("creates a vertical split using topleft for split_side=left", function()
      window_manager.setup({ split_side = "left", split_width_percentage = 0.25 })
      window_manager.ensure_window()

      assert.spy(mock_vim.cmd).was_called_with("topleft vertical new")
    end)

    it("pins winfixwidth, disables spell, and sets winfixbuf for split_side=right on nvim-0.10+", function()
      window_manager.setup({ split_side = "right", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()

      assert.is_true(win_options[win].winfixwidth)
      assert.is_false(win_options[win].spell)
      assert.is_true(win_options[win].winfixbuf)
      assert.is_nil(win_options[win].winfixheight)
    end)

    it("pins winfixheight (not winfixwidth) for split_side=bottom", function()
      window_manager.setup({ split_side = "bottom", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()

      assert.is_true(win_options[win].winfixheight)
      assert.is_nil(win_options[win].winfixwidth)
    end)

    it("does not set winfixbuf on Neovim < 0.10", function()
      mock_vim.fn.has = spy.new(function()
        return 0
      end)

      window_manager.setup({ split_side = "right", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()

      assert.is_true(win_options[win].winfixwidth)
      assert.is_nil(win_options[win].winfixbuf)
    end)

    it("swaps session buffers even when winfixbuf is set", function()
      mock_vim.api.nvim_buf_is_valid = spy.new(function()
        return true
      end)
      mock_vim.api.nvim_buf_get_name = spy.new(function()
        return ""
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { channel = 123, buftype = "" }
        end,
      })

      -- Real Neovim raises E1513 from nvim_win_set_buf while winfixbuf is on;
      -- set_win_buf must lift the pin before calling it, so this mock only
      -- throws if winfixbuf is still (incorrectly) set at call time.
      mock_vim.api.nvim_win_set_buf = spy.new(function(winid)
        if win_options[winid] and win_options[winid].winfixbuf then
          error("Vim:E1513: Cannot switch buffer. 'winfixbuf' is enabled", 0)
        end
      end)

      window_manager.setup({ split_side = "right", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()
      assert.is_true(win_options[win].winfixbuf)

      local ok = window_manager.display_buffer(42, false)

      assert.is_true(ok)
      assert.spy(mock_vim.api.nvim_win_set_buf).was_called_with(win, 42)
      assert.is_true(win_options[win].winfixbuf)
    end)

    it("restores winfixbuf and propagates the error when the buffer swap fails for another reason", function()
      mock_vim.api.nvim_buf_is_valid = spy.new(function()
        return true
      end)
      mock_vim.api.nvim_buf_get_name = spy.new(function()
        return ""
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { channel = 123, buftype = "" }
        end,
      })
      -- Some other failure, unrelated to winfixbuf (e.g. an invalid buffer).
      mock_vim.api.nvim_win_set_buf = spy.new(function()
        error("boom: something else went wrong", 0)
      end)

      window_manager.setup({ split_side = "right", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()
      assert.is_true(win_options[win].winfixbuf)

      local ok, err = pcall(window_manager.display_buffer, 42, false)

      assert.is_false(ok)
      assert.matches("boom: something else went wrong", tostring(err), 1, true)
      assert.is_true(win_options[win].winfixbuf)
    end)

    it("recreates the managed window when the previous one was closed externally", function()
      window_manager.setup({ split_side = "right", split_width_percentage = 0.3 })
      local win1 = window_manager.ensure_window()
      assert.is_not_nil(win1)

      -- Simulate the window having been closed externally (e.g. the user ran :q,
      -- or a hidden buffer is being shown again after having lost its window).
      mock_vim.api.nvim_win_is_valid = spy.new(function(w)
        return w ~= win1
      end)
      mock_vim.api.nvim_get_current_win = spy.new(function()
        return win1 + 1
      end)

      local win2 = window_manager.ensure_window()

      assert.is_not_nil(win2)
      assert.are_not.equal(win1, win2)
      assert.spy(mock_vim.cmd).was_called(2)
    end)

    it("close_window hides the managed window and updates visibility state", function()
      mock_vim.api.nvim_win_get_tabpage = spy.new(function()
        return 1
      end)
      mock_vim.api.nvim_win_close = spy.new(function() end)

      window_manager.setup({ split_side = "right", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()
      assert.is_true(window_manager.is_visible())

      window_manager.close_window()

      assert.spy(mock_vim.api.nvim_win_close).was_called_with(win, false)
      assert.is_false(window_manager.is_visible())
      assert.is_nil(window_manager.get_window())
    end)

    it("display_buffer focuses the window and starts insert mode when focus=true", function()
      mock_vim.api.nvim_buf_is_valid = spy.new(function()
        return true
      end)
      mock_vim.api.nvim_buf_get_name = spy.new(function()
        return ""
      end)
      mock_vim.api.nvim_win_set_buf = spy.new(function() end)
      mock_vim.api.nvim_set_current_win = spy.new(function() end)
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { channel = 123, buftype = "" }
        end,
      })

      window_manager.setup({ split_side = "right", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()

      local ok = window_manager.display_buffer(7, true)

      assert.is_true(ok)
      assert.spy(mock_vim.api.nvim_set_current_win).was_called_with(win)

      local saw_startinsert = false
      for _, call in ipairs(mock_vim.cmd.calls) do
        if call.vals[1] == "startinsert" then
          saw_startinsert = true
        end
      end
      assert.is_true(saw_startinsert)
    end)
  end)

  describe("manual resize persistence (D4: no auto-restore on VimResized/TabEnter)", function()
    it("does not undo a manual resize on VimResized or TabEnter", function()
      mock_vim.o = { columns = 200, lines = 40 }
      mock_vim.wo = setmetatable({}, {
        __index = function()
          return {}
        end,
        __newindex = function() end,
      })
      mock_vim.cmd = spy.new(function() end)
      mock_vim.fn.has = spy.new(function()
        return 1
      end)
      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.api.nvim_win_set_height = spy.new(function() end)
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return {}
      end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)

      window_manager.setup({ split_side = "right", split_width_percentage = 0.3 })
      local win = window_manager.ensure_window()
      assert.is_not_nil(win)

      -- Make find_terminal_window() actually locate this window as a real
      -- Claude terminal, so the TabEnter callback body below runs instead of
      -- short-circuiting on a nil find (which would make the "was not
      -- called" assertions pass vacuously).
      mock_vim.api.nvim_tabpage_list_wins = spy.new(function()
        return { win }
      end)
      mock_vim.bo = setmetatable({}, {
        __index = function()
          return { channel = 123, buftype = "terminal" }
        end,
      })
      mock_vim.b = setmetatable({}, {
        __index = function()
          return { claudecode_terminal = true }
        end,
      })

      -- Simulate the user manually resizing the window.
      local manual_width = 50
      mock_vim.api.nvim_win_get_width = spy.new(function()
        return manual_width
      end)

      -- Find VimResized and TabEnter callbacks via the recorded autocmd calls
      -- (R4: drive them directly rather than through nvim_exec_autocmds).
      local vim_resized_callback, tab_enter_callback
      for _, call in ipairs(mock_vim.api.nvim_create_autocmd.calls) do
        if call.vals[1] == "VimResized" then
          vim_resized_callback = call.vals[2].callback
        elseif call.vals[1] == "TabEnter" then
          tab_enter_callback = call.vals[2].callback
        end
      end
      assert.is_function(vim_resized_callback)
      assert.is_function(tab_enter_callback)

      mock_vim.api.nvim_win_set_width = spy.new(function() end)
      mock_vim.fn.jobresize = spy.new(function() end)

      vim_resized_callback()

      -- Prove the VimResized callback actually reached notify_resize (it
      -- always does, regardless of find_terminal_window; notify_resize(true)
      -- forces the jobresize call).
      assert.spy(mock_vim.fn.jobresize).was_called()

      -- Change the reported height so TabEnter's (non-forced) notify_resize
      -- sees a dimension change and reaches jobresize again; this proves the
      -- TabEnter callback body executed rather than short-circuiting.
      mock_vim.api.nvim_win_get_height = spy.new(function()
        return 30
      end)
      mock_vim.fn.jobresize = spy.new(function() end)
      mock_vim.defer_fn = spy.new(function(fn)
        fn()
      end)

      tab_enter_callback()

      assert.spy(mock_vim.defer_fn).was_called()
      assert.spy(mock_vim.fn.jobresize).was_called_with(123, manual_width, 30)
      assert.spy(mock_vim.api.nvim_win_set_width).was_not_called()
      assert.spy(mock_vim.api.nvim_win_set_height).was_not_called()
      assert.are.equal(manual_width, mock_vim.api.nvim_win_get_width(win))
    end)
  end)
end)
