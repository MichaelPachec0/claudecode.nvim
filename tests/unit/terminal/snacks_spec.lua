-- Regression test for Snacks provider command handling.
--
-- The Snacks provider must pass the Claude command to Snacks.terminal.open as an
-- argv list, NOT a shell string. As a string, Snacks hands it to the shell,
-- which glob-expands bracketed model aliases such as "opus[1m]" (zsh aborts with
-- "no matches found"), preventing Claude from launching. See snacks.lua M.open.

describe("claudecode.terminal.snacks command handling", function()
  local snacks_provider
  local original_vim
  local spy
  local captured
  local mock_snacks
  local saved_modules

  local function make_term_instance()
    return {
      buf = 1,
      win = nil,
      buf_valid = function()
        return true
      end,
      win_valid = function()
        return false
      end,
      on = function() end,
      toggle = function() end,
      focus = function() end,
      close = function() end,
    }
  end

  before_each(function()
    original_vim = vim
    spy = require("luassert.spy")

    _G.vim = {
      -- Mock additions for the session-aware provider (buffer flag, pid retry,
      -- BufUnload hook, tabpage scoping).
      b = setmetatable({}, {
        __index = function(t, buf)
          rawset(t, buf, {})
          return rawget(t, buf)
        end,
      }),
      defer_fn = function() end,
      log = { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } },
      notify = spy.new(function() end),
      inspect = function(v)
        return tostring(v)
      end,
      schedule = function(fn)
        fn()
      end,
      cmd = function() end,
      bo = setmetatable({}, {
        __index = function(t, buf)
          rawset(t, buf, {})
          return rawget(t, buf)
        end,
      }),
      split = function(str, sep, _opts)
        local result = {}
        local start = 1
        while true do
          local s, e = string.find(str, sep, start, true)
          if not s then
            table.insert(result, string.sub(str, start))
            break
          end
          table.insert(result, string.sub(str, start, s - 1))
          start = e + 1
        end
        return result
      end,
      tbl_deep_extend = function(_, ...)
        local res = {}
        for _, t in ipairs({ ... }) do
          if type(t) == "table" then
            for k, v in pairs(t) do
              res[k] = v
            end
          end
        end
        return res
      end,
      api = {
        -- Mock additions for the session-aware provider.
        nvim_create_autocmd = function() end,
        nvim_buf_get_var = function()
          error("no terminal_job_id in mock")
        end,
        nvim_win_get_tabpage = function()
          return 1
        end,
        nvim_get_current_tabpage = function()
          return 1
        end,
        nvim_buf_is_valid = function()
          return true
        end,
        nvim_win_is_valid = function()
          return true
        end,
        nvim_buf_get_option = function()
          return "terminal"
        end,
        nvim_win_call = function(_, fn)
          fn()
        end,
        nvim_get_current_win = function()
          return 1
        end,
        nvim_set_current_win = function() end,
      },
    }

    captured = {}
    mock_snacks = {
      terminal = {
        open = spy.new(function(cmd, opts)
          captured.cmd = cmd
          captured.opts = opts
          return make_term_instance()
        end),
      },
    }

    package.loaded["snacks"] = mock_snacks

    -- Multi-session collaborators (mock additions for the session-aware
    -- provider): the terminal module's session hooks and the OSC handler.
    saved_modules = {
      ["claudecode.terminal"] = package.loaded["claudecode.terminal"],
      ["claudecode.terminal.osc_handler"] = package.loaded["claudecode.terminal.osc_handler"],
    }
    package.loaded["claudecode.terminal"] = {
      defaults = { cleanup_strategy = "jobstop_only" },
      register_buffer_session = function() end,
      update_session_terminal_info = function() end,
      setup_terminal_keymaps = function() end,
      setup_scroll_keymaps = function() end,
      track_terminal_pid = function() end,
    }
    package.loaded["claudecode.terminal.osc_handler"] = {
      setup_buffer_handler = function() end,
      cleanup_buffer_handler = function() end,
    }
    package.loaded["claudecode.logger"] = {
      debug = spy.new(function() end),
      info = spy.new(function() end),
      warn = spy.new(function() end),
      error = spy.new(function() end),
    }
    -- Use the real utils module: snacks.lua calls utils.shell_split, and utils
    -- is pure Lua (safe under the mocked vim).
    package.loaded["claudecode.utils"] = nil
    package.loaded["claudecode.terminal.snacks"] = nil

    snacks_provider = require("claudecode.terminal.snacks")
  end)

  after_each(function()
    _G.vim = original_vim
    for name, mod in pairs(saved_modules) do
      package.loaded[name] = mod
    end
    package.loaded["snacks"] = nil
    package.loaded["claudecode.utils"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.terminal.snacks"] = nil
  end)

  local function base_config()
    return { cwd = "/work", split_side = "right", split_width_percentage = 0.30, auto_close = false }
  end

  it("passes a bracketed model alias to Snacks as an argv list, not a shell string", function()
    snacks_provider.open("claude --model opus[1m]", { FOO = "bar" }, base_config(), true)

    assert.spy(mock_snacks.terminal.open).was_called(1)
    assert.is_table(captured.cmd)
    assert.are.same({ "claude", "--model", "opus[1m]" }, captured.cmd)
  end)

  it("wraps an argument-less command in a single-element list", function()
    snacks_provider.open("claude", {}, base_config(), true)

    assert.is_table(captured.cmd)
    assert.are.same({ "claude" }, captured.cmd)
  end)

  it("keeps quoted arguments intact instead of splitting on inner spaces", function()
    snacks_provider.open("claude --message='hello world'", {}, base_config(), true)

    assert.is_table(captured.cmd)
    assert.are.same({ "claude", "--message=hello world" }, captured.cmd)
  end)

  it("expands a tilde in terminal_cmd before handing argv to Snacks", function()
    local home = os.getenv("HOME")
    snacks_provider.open("~/.claude/local/claude", {}, base_config(), true)

    assert.is_table(captured.cmd)
    assert.are.same({ home .. "/.claude/local/claude" }, captured.cmd)
  end)
end)

-- Task 9 fix round 1: register_new_instance used to only call
-- setup_terminal_keymaps (smart ESC + legacy exit key + split navigation) when
-- config.esc_timeout > 0, so a Snacks user who set only split_navigation =
-- true (esc_timeout at its Task 9 default of 0) got no split-nav keymaps at
-- all, unlike the native provider which calls setup_terminal_keymaps
-- unconditionally. These tests drive the real claudecode.terminal (not the
-- fake stub the describe above uses) so setup_terminal_keymaps' own gating
-- logic installs (or withholds) real vim.keymap.set calls on a Snacks buffer.
-- This is a sibling of the describe above (not nested in it): that describe's
-- before_each replaces package.loaded["claudecode.terminal"] with a
-- no-op-only fake, which would hide the very call-site bug being fixed here.
describe("claudecode.terminal.snacks keymap wiring (Task 9 fix round 1)", function()
  local snacks_provider
  local original_vim
  local saved_modules

  local function make_term_instance()
    return {
      buf = 1,
      win = nil,
      buf_valid = function()
        return true
      end,
      win_valid = function()
        return false
      end,
      on = function() end,
      toggle = function() end,
      focus = function() end,
      close = function() end,
    }
  end

  before_each(function()
    original_vim = vim
    -- Unlike the describe above, use the shared, fuller vim mock: real
    -- setup_terminal_keymaps/setup_scroll_keymaps need vim.keymap.set,
    -- vim.api.nvim_create_autocmd, and friends, which that describe's
    -- hand-rolled minimal mock does not provide.
    _G.vim = require("tests.mocks.vim")
    if _G.vim._mock and _G.vim._mock.reset then
      _G.vim._mock.reset()
    end
    -- The shared mock has no vim.bo; snacks.lua's create_terminal_buffer sets
    -- vim.bo[buf].filetype directly.
    vim.bo = setmetatable({}, {
      __index = function(t, buf)
        rawset(t, buf, {})
        return rawget(t, buf)
      end,
    })
    -- Register the mock terminal instance's buffer (id 1, see
    -- make_term_instance below) as a real buffer so nvim_buf_is_valid(1) is
    -- true: setup_terminal_keymaps/setup_scroll_keymaps are no-ops on an
    -- invalid buffer, which would mask the very thing under test here.
    vim._buffers[1] = { name = "", lines = {}, options = {} }

    package.loaded["snacks"] = {
      terminal = {
        open = function()
          return make_term_instance()
        end,
      },
    }

    saved_modules = {
      ["claudecode.server.init"] = package.loaded["claudecode.server.init"],
      ["claudecode.logger"] = package.loaded["claudecode.logger"],
      ["claudecode.terminal.osc_handler"] = package.loaded["claudecode.terminal.osc_handler"],
      ["claudecode.terminal"] = package.loaded["claudecode.terminal"],
      ["claudecode.terminal.snacks"] = package.loaded["claudecode.terminal.snacks"],
    }

    -- Keep claudecode.terminal's own module graph light: it requires
    -- claudecode.server.init at load time, which otherwise pulls in the full
    -- server/tools graph. claudecode.session and claudecode.tab_registry are
    -- left real (pure Lua, no heavy deps) since register_new_instance's
    -- session bookkeeping calls need to succeed.
    package.loaded["claudecode.server.init"] = { state = {} }
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }
    package.loaded["claudecode.terminal.osc_handler"] = {
      setup_buffer_handler = function() end,
      cleanup_buffer_handler = function() end,
    }

    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.terminal.snacks"] = nil
    require("claudecode.terminal")
    snacks_provider = require("claudecode.terminal.snacks")
  end)

  after_each(function()
    for name, mod in pairs(saved_modules) do
      package.loaded[name] = mod
    end
    package.loaded["snacks"] = nil
    _G.vim = original_vim
  end)

  ---@param overrides table?
  local function base_config(overrides)
    local cfg = {
      cwd = "/work",
      split_side = "right",
      split_width_percentage = 0.30,
      auto_close = false,
      keymaps = { exit_terminal = false },
      esc_timeout = 0,
      split_navigation = false,
      tui_keymaps = false,
      scroll_up_enabled = false,
    }
    for k, v in pairs(overrides or {}) do
      cfg[k] = v
    end
    return cfg
  end

  it("installs no ESC or split-navigation buffer maps with default config", function()
    local set = spy.on(vim.keymap, "set")
    snacks_provider.open("sh", {}, base_config(), true)
    assert.spy(set).was_not_called()
    set:revert()
  end)

  it("installs split-navigation maps when split_navigation = true alone (esc_timeout stays 0)", function()
    local set = spy.on(vim.keymap, "set")
    snacks_provider.open("sh", {}, base_config({ split_navigation = true }), true)
    assert.spy(set).was_called_with("t", "<C-h>", match._, match._)
    assert.spy(set).was_called_with("n", "<C-h>", match._, match._)
    set:revert()
  end)

  it("installs the smart ESC map when esc_timeout = 200", function()
    local set = spy.on(vim.keymap, "set")
    snacks_provider.open("sh", {}, base_config({ esc_timeout = 200 }), true)
    assert.spy(set).was_called_with("t", "<Esc>", match._, match._)
    set:revert()
  end)
end)
