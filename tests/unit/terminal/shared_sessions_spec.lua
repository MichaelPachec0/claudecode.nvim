-- D7 / C1: terminal.per_tab_sessions (default false) keeps ONE shared session
-- set across tabpages, like upstream. A second tabpage must never spawn a
-- second Claude; per_tab_sessions = true opts in to per-tab isolation.
require("tests.busted_setup")

describe("terminal shared sessions across tabpages (per_tab_sessions)", function()
  local terminal
  local session_manager
  local tab_registry
  local provider
  local chansend_calls

  -- A session-aware provider shaped like native.lua: one buffer per session,
  -- created on the first open_session for that session id.
  local function session_provider()
    local bufs = {}
    local last_buf
    local p = {
      setup = function() end,
      open = function() end,
      close = function() end,
      simple_toggle = function() end,
      focus_toggle = function() end,
      is_available = function()
        return true
      end,
      get_active_bufnr = function()
        return last_buf
      end,
      get_session_bufnr = function(sid)
        return bufs[sid]
      end,
      spawned = 0,
      open_calls = {},
    }
    p.open_session = function(sid, _, _, _, focus)
      table.insert(p.open_calls, { sid = sid, focus = focus, tab = vim.api.nvim_get_current_tabpage() })
      if not bufs[sid] then
        p.spawned = p.spawned + 1
        local buf = vim.api.nvim_create_buf(false, true)
        vim._buffers[buf].b_vars = { terminal_job_id = 700 + p.spawned }
        bufs[sid] = buf
      end
      last_buf = bufs[sid]
    end
    return p
  end

  before_each(function()
    package.loaded["tests.mocks.vim"] = nil
    _G.vim = require("tests.mocks.vim")
    vim.bo = setmetatable({}, {
      __index = function(t, k)
        local v = { channel = 0 }
        rawset(t, k, v)
        return v
      end,
    })
    vim.schedule_wrap = vim.schedule_wrap or function(fn)
      return fn
    end
    chansend_calls = {}
    vim.fn.chansend = function(chan, data)
      table.insert(chansend_calls, { chan = chan, data = data })
      return #data
    end

    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
      info = function() end,
      setup = function() end,
    }
    package.loaded["claudecode.server.init"] = { state = { port = 12345 } }
    package.loaded["claudecode.terminal.osc_handler"] = {
      setup_buffer_handler = function() end,
      cleanup_buffer_handler = function() end,
    }
    for _, m in ipairs({
      "claudecode.terminal",
      "claudecode.terminal.window_manager",
      "claudecode.terminal.tabbar",
      "claudecode.session",
      "claudecode.tab_registry",
    }) do
      package.loaded[m] = nil
    end

    terminal = require("claudecode.terminal")
    session_manager = require("claudecode.session")
    tab_registry = require("claudecode.tab_registry")
    session_manager.reset()
    tab_registry.reset()
    provider = session_provider()
  end)

  after_each(function()
    session_manager.reset()
    tab_registry.reset()
    package.loaded["claudecode.terminal"] = nil
  end)

  local function new_tab()
    vim.cmd("tabnew")
    return vim.api.nvim_get_current_tabpage()
  end

  describe("default (per_tab_sessions = false)", function()
    before_each(function()
      terminal.setup({ provider = provider })
    end)

    it("defaults per_tab_sessions to false", function()
      assert.is_false(terminal.defaults.per_tab_sessions)
      assert.is_false(tab_registry.is_per_tab_enabled())
    end)

    it(":ClaudeCode in tab 1 then tab 2 keeps exactly one session and process", function()
      terminal.simple_toggle()
      local tab2 = new_tab()
      terminal.simple_toggle()

      assert.are.equal(1, session_manager.get_session_count())
      assert.are.equal(1, provider.spawned)
      assert.are.equal(2, #provider.open_calls)
      assert.are.equal(provider.open_calls[1].sid, provider.open_calls[2].sid)
      -- The second call showed it in tab 2.
      assert.are.equal(tab2, provider.open_calls[2].tab)
    end)

    it("open, focus_toggle and ensure_visible from tab 2 reuse tab 1's session", function()
      terminal.open()
      local sid = provider.open_calls[1].sid
      new_tab()
      terminal.open()
      terminal.focus_toggle()
      terminal.ensure_visible()

      assert.are.equal(1, session_manager.get_session_count())
      assert.are.equal(1, provider.spawned)
      for _, call in ipairs(provider.open_calls) do
        assert.are.equal(sid, call.sid)
      end
    end)

    it("send from tab 2 reaches tab 1's session without creating a session", function()
      terminal.open()
      new_tab()
      local ok = terminal.send_to_terminal("hi", { submit = false })
      assert.is_true(ok)
      assert.are.equal(1, #chansend_calls)
      assert.are.equal(701, chansend_calls[1].chan)
      assert.are.equal(1, session_manager.get_session_count())
    end)

    it(":ClaudeCodeNew still creates additional sessions, and listing sees all of them", function()
      terminal.open()
      new_tab()
      terminal.open_new_session()
      assert.are.equal(2, session_manager.get_session_count())
      assert.are.equal(2, #terminal.list_sessions_for_current_tab())
      vim.api.nvim_set_current_tabpage(1)
      assert.are.equal(2, #terminal.list_sessions_for_current_tab())
    end)

    it("a window-owning provider shows the shared session in tab 2 instead of hiding tab 1's", function()
      local windows = {} -- sid -> winid
      provider.get_session_window = function(sid)
        return windows[sid]
      end
      provider.hide_session = function(sid)
        windows[sid] = nil
      end
      local base_open = provider.open_session
      provider.open_session = function(sid, ...)
        base_open(sid, ...)
        local win = vim._next_winid
        vim._next_winid = win + 1
        vim._windows[win] = { buf = provider.get_session_bufnr(sid), width = 80 }
        vim._win_tab[win] = vim.api.nvim_get_current_tabpage()
        windows[sid] = win
      end

      terminal.simple_toggle()
      local sid = provider.open_calls[1].sid
      new_tab()
      -- The session is on screen in tab 1 only: the toggle in tab 2 must show
      -- it here, not treat it as visible and hide it.
      terminal.simple_toggle()
      assert.are.equal(2, #provider.open_calls)
      assert.are.equal(sid, provider.open_calls[2].sid)
      assert.are.equal(1, session_manager.get_session_count())
    end)
  end)

  describe("per_tab_sessions = true", function()
    before_each(function()
      terminal.setup({ provider = provider, per_tab_sessions = true })
    end)

    it("gives tab 2 its own session", function()
      terminal.simple_toggle()
      new_tab()
      terminal.simple_toggle()
      assert.are.equal(2, session_manager.get_session_count())
      assert.are.equal(2, provider.spawned)
      assert.are_not.equal(provider.open_calls[1].sid, provider.open_calls[2].sid)
    end)

    it("scopes session listing to the current tab", function()
      terminal.open()
      new_tab()
      terminal.open()
      assert.are.equal(1, #terminal.list_sessions_for_current_tab())
    end)
  end)

  it("rejects a non-boolean per_tab_sessions and keeps the default", function()
    local warned = false
    vim.notify = function(msg)
      if tostring(msg):match("per_tab_sessions") then
        warned = true
      end
    end
    terminal.setup({ provider = provider, per_tab_sessions = "yes" })
    assert.is_true(warned)
    assert.is_false(terminal.defaults.per_tab_sessions)
  end)
end)
