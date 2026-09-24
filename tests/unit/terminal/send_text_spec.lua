-- Tests for terminal.send_to_terminal (#197): send raw text to the Claude pane.
require("tests.busted_setup")
require("tests.mocks.vim")

describe("terminal.send_to_terminal (#197)", function()
  local terminal
  local chansend_calls
  local warnings
  local open_calls
  local active_bufnr
  local BUF = 4242

  -- A minimal valid custom table provider whose get_active_bufnr we control.
  local function custom_provider()
    return {
      setup = function() end,
      open = function()
        open_calls = open_calls + 1
      end,
      close = function() end,
      simple_toggle = function() end,
      focus_toggle = function() end,
      get_active_bufnr = function()
        return active_bufnr
      end,
      is_available = function()
        return true
      end,
    }
  end

  local function register_buffer(bufnr, b_vars, channel)
    vim._buffers[bufnr] = { lines = {}, options = {}, b_vars = b_vars or {} }
    vim.bo[bufnr] = { channel = channel }
  end

  before_each(function()
    _G.vim = require("tests.mocks.vim")
    vim._buffers = {}
    -- The mock has no vim.bo; provide a simple table-of-tables for the fallback.
    vim.bo = {}

    vim.fn = vim.fn or {}
    vim.fn.getcwd = function()
      return "/mock/cwd"
    end
    vim.fn.expand = function(val)
      return val
    end
    vim.fn.fnamemodify = function(path)
      return path
    end

    chansend_calls = {}
    vim.fn.chansend = function(chan, data)
      table.insert(chansend_calls, { chan = chan, data = data })
      return type(data) == "string" and #data or 0
    end

    warnings = {}
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function(_, msg)
        table.insert(warnings, msg)
      end,
      error = function() end,
      info = function() end,
      setup = function() end,
    }
    package.loaded["claudecode.server.init"] = { state = { port = 12345 } }

    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.terminal.none"] = nil
    package.loaded["claudecode.terminal.native"] = nil
    package.loaded["claudecode.terminal.snacks"] = nil

    open_calls = 0
    active_bufnr = nil
    terminal = require("claudecode.terminal")
  end)

  local function setup_with_buffer(b_vars, channel)
    active_bufnr = BUF
    register_buffer(BUF, b_vars, channel)
    terminal.setup({ provider = custom_provider() }, nil, {})
  end

  local function warned(pattern)
    for _, m in ipairs(warnings) do
      if tostring(m):match(pattern) then
        return true
      end
    end
    return false
  end

  it("sends single-line text with a trailing CR by default", function()
    setup_with_buffer({ terminal_job_id = 42 })
    local ok = terminal.send_to_terminal("hello")
    assert.is_true(ok)
    assert.are.equal(1, #chansend_calls)
    assert.are.equal(42, chansend_calls[1].chan)
    assert.are.equal("hello\r", chansend_calls[1].data)
  end)

  it("omits the CR when submit=false", function()
    setup_with_buffer({ terminal_job_id = 42 })
    local ok = terminal.send_to_terminal("hello", { submit = false })
    assert.is_true(ok)
    assert.are.equal("hello", chansend_calls[1].data)
  end)

  it("wraps multi-line text in bracketed paste then a CR", function()
    setup_with_buffer({ terminal_job_id = 42 })
    terminal.send_to_terminal("a\nb")
    assert.are.equal("\27[200~a\nb\27[201~\r", chansend_calls[1].data)
  end)

  it("wraps multi-line text in bracketed paste with no CR when submit=false", function()
    setup_with_buffer({ terminal_job_id = 42 })
    terminal.send_to_terminal("a\nb", { submit = false })
    assert.are.equal("\27[200~a\nb\27[201~", chansend_calls[1].data)
  end)

  it("normalizes CRLF to LF and wraps as a single bracketed block", function()
    setup_with_buffer({ terminal_job_id = 42 })
    terminal.send_to_terminal("a\r\nb")
    assert.are.equal("\27[200~a\nb\27[201~\r", chansend_calls[1].data)
  end)

  it("normalizes a lone CR (which would otherwise submit prematurely)", function()
    setup_with_buffer({ terminal_job_id = 42 })
    terminal.send_to_terminal("a\rb")
    assert.are.equal("\27[200~a\nb\27[201~\r", chansend_calls[1].data)
  end)

  it("returns false and sends nothing for an empty string", function()
    setup_with_buffer({ terminal_job_id = 42 })
    local ok = terminal.send_to_terminal("")
    assert.is_false(ok)
    assert.are.equal(0, #chansend_calls)
  end)

  it("returns false for non-string text", function()
    setup_with_buffer({ terminal_job_id = 42 })
    assert.is_false(terminal.send_to_terminal(nil))
    assert.is_false(terminal.send_to_terminal(123))
    assert.are.equal(0, #chansend_calls)
  end)

  it("falls back to bo.channel when terminal_job_id is absent", function()
    setup_with_buffer({}, 7) -- no terminal_job_id, channel = 7
    local ok = terminal.send_to_terminal("hi")
    assert.is_true(ok)
    assert.are.equal(7, chansend_calls[1].chan)
  end)

  it("falls back to bo.channel when terminal_job_id is 0 (recovered terminal)", function()
    setup_with_buffer({ terminal_job_id = 0 }, 99) -- job id lost on recovery, channel intact
    local ok = terminal.send_to_terminal("hi")
    assert.is_true(ok)
    assert.are.equal(99, chansend_calls[1].chan)
  end)

  it("returns false when no channel can be resolved", function()
    setup_with_buffer({}, nil) -- no job id, no channel
    local ok = terminal.send_to_terminal("hi")
    assert.is_false(ok)
    assert.are.equal(0, #chansend_calls)
    assert.is_true(warned("no terminal job channel"))
  end)

  it("treats terminal_job_id 0 as invalid", function()
    setup_with_buffer({ terminal_job_id = 0 }, nil)
    local ok = terminal.send_to_terminal("hi")
    assert.is_false(ok)
    assert.are.equal(0, #chansend_calls)
  end)

  it("returns false and warns when no terminal is running (native)", function()
    active_bufnr = nil
    terminal.setup({ provider = "native" }, nil, {})
    local ok = terminal.send_to_terminal("hi")
    assert.is_false(ok)
    assert.are.equal(0, #chansend_calls)
    assert.is_true(warned("no Claude terminal is currently running"))
  end)

  it("warns and sends nothing for provider=none", function()
    terminal.setup({ provider = "none" }, nil, {})
    local ok = terminal.send_to_terminal("hi")
    assert.is_false(ok)
    assert.are.equal(0, #chansend_calls)
    assert.is_true(warned("outside Neovim"))
    assert.is_true(warned("none"))
  end)

  it("warns and sends nothing for provider=external", function()
    terminal.setup({ provider = "external", provider_opts = { external_terminal_cmd = "alacritty -e %s" } }, nil, {})
    local ok = terminal.send_to_terminal("hi")
    assert.is_false(ok)
    assert.are.equal(0, #chansend_calls)
    assert.is_true(warned("external"))
  end)

  it("treats a stale (invalid) bufnr as no terminal", function()
    active_bufnr = BUF -- provider returns it, but the buffer is never registered
    terminal.setup({ provider = custom_provider() }, nil, {})
    local ok = terminal.send_to_terminal("hi")
    assert.is_false(ok)
    assert.are.equal(0, #chansend_calls)
  end)

  it("focuses the terminal after a successful send when focus=true", function()
    setup_with_buffer({ terminal_job_id = 42 })
    open_calls = 0
    local ok = terminal.send_to_terminal("hi", { focus = true })
    assert.is_true(ok)
    assert.are.equal(1, #chansend_calls)
    assert.are.equal(1, open_calls)
  end)

  it("does not focus when the send fails even if focus=true", function()
    setup_with_buffer({}, nil) -- no channel -> failure
    open_calls = 0
    local ok = terminal.send_to_terminal("hi", { focus = true })
    assert.is_false(ok)
    assert.are.equal(0, open_calls)
  end)

  describe("multi-session routing (Task 8)", function()
    local session_manager
    local tab_registry
    local provider

    -- A session-aware provider: get_active_bufnr() models a provider's single
    -- legacy pointer (as a real provider would report it before any per-session
    -- fix), while get_session_bufnr(session_id) models the real per-session
    -- lookup that native.lua/snacks.lua expose.
    local function multi_session_provider()
      local session_bufnrs = {}
      local legacy_active_bufnr
      return {
        setup = function() end,
        open = function()
          open_calls = open_calls + 1
        end,
        close = function() end,
        simple_toggle = function() end,
        focus_toggle = function() end,
        get_active_bufnr = function()
          return legacy_active_bufnr
        end,
        get_session_bufnr = function(session_id)
          return session_bufnrs[session_id]
        end,
        is_available = function()
          return true
        end,
        -- Test helpers (not part of the provider contract).
        _set_session_bufnr = function(session_id, bufnr)
          session_bufnrs[session_id] = bufnr
        end,
        _set_legacy_active_bufnr = function(bufnr)
          legacy_active_bufnr = bufnr
        end,
      }
    end

    local function register(bufnr, channel)
      vim._buffers[bufnr] = { lines = {}, options = {}, b_vars = { terminal_job_id = channel } }
      vim.bo[bufnr] = { channel = channel }
    end

    before_each(function()
      session_manager = require("claudecode.session")
      tab_registry = require("claudecode.tab_registry")
      session_manager.reset()
      tab_registry.reset()
      provider = multi_session_provider()
      open_calls = 0
      terminal.setup({ provider = provider }, nil, {})
    end)

    after_each(function()
      session_manager.reset()
      tab_registry.reset()
    end)

    it("sends to the active session's channel, not a stale legacy pointer", function()
      local sid1 = session_manager.create_session()
      local sid2 = session_manager.create_session()
      register(101, 11)
      register(102, 22)
      provider._set_session_bufnr(sid1, 101)
      provider._set_session_bufnr(sid2, 102)
      -- The provider's plain get_active_bufnr() still names session 1 -- e.g.
      -- it was never told about the switch. If send_to_terminal ever falls
      -- back to it while an active session id is available, text lands in
      -- the wrong pane.
      provider._set_legacy_active_bufnr(101)

      session_manager.set_active_session(sid2)

      local ok = terminal.send_to_terminal("hi", { submit = true })
      assert.is_true(ok)
      assert.are.equal(1, #chansend_calls)
      assert.are.equal(22, chansend_calls[1].chan)
    end)

    it("switching to session 2 then back to session 1 sends to session 1 again", function()
      local sid1 = session_manager.create_session()
      local sid2 = session_manager.create_session()
      register(201, 1)
      register(202, 2)
      provider._set_session_bufnr(sid1, 201)
      provider._set_session_bufnr(sid2, 202)

      terminal.switch_to_session(sid2)
      terminal.switch_to_session(sid1)

      local ok = terminal.send_to_terminal("hi", { submit = false })
      assert.is_true(ok)
      assert.are.equal(1, #chansend_calls)
      assert.are.equal(1, chansend_calls[1].chan)
    end)

    it("routes to the current tab's active session, not another tab's (per_tab_sessions = true)", function()
      tab_registry.set_per_tab_enabled(true)
      local original_get_current_tabpage = vim.api.nvim_get_current_tabpage
      local current_tab = 1
      vim.api.nvim_get_current_tabpage = function()
        return current_tab
      end

      local sid_a = session_manager.create_session()
      local sid_b = session_manager.create_session()
      register(301, 31)
      register(302, 32)
      provider._set_session_bufnr(sid_a, 301)
      provider._set_session_bufnr(sid_b, 302)

      current_tab = 1
      tab_registry.bind(1, sid_a)
      current_tab = 2
      tab_registry.bind(2, sid_b)

      current_tab = 1
      local ok = terminal.send_to_terminal("hi", { submit = false })
      assert.is_true(ok)
      assert.are.equal(31, chansend_calls[1].chan)

      current_tab = 2
      ok = terminal.send_to_terminal("hi", { submit = false })
      assert.is_true(ok)
      assert.are.equal(32, chansend_calls[2].chan)

      vim.api.nvim_get_current_tabpage = original_get_current_tabpage
    end)
  end)
end)
