-- Tests for the Snacks provider hide/show/toggle logic that works around the
-- climbing-cursor bug (#240 split / #183 float).
--
-- The provider keeps Claude's terminal cursor anchor stable by NOT letting Snacks
-- destroy+recreate the window via open_win():
--   * float -> nvim_win_set_config({hide=true/false}) (window kept alive)
--   * split -> close on hide, recreate with vsplit + nvim_win_set_buf on show
-- These tests drive a self-contained Neovim mock that models window config
-- (relative/hide) so the float vs split branching can be asserted without a real
-- Neovim or Snacks.

describe("claudecode.terminal.snacks hide/show/toggle", function()
  local snacks_provider
  local original_vim
  local spy
  local windows -- id -> { buf, config = { relative, hide }, valid }
  local current_win
  local next_win_id
  local next_buf_id
  local mock_snacks
  local saved_modules
  local open_show_spy
  local last_split_cmd
  local current_tab

  local function make_window(buf, opts)
    local id = next_win_id
    next_win_id = next_win_id + 1
    windows[id] = {
      buf = buf,
      valid = true,
      tab = current_tab,
      config = { relative = (opts and opts.relative) or "", hide = false },
    }
    return id
  end

  -- A Snacks-like terminal instance backed by the mock window registry.
  local function make_term_instance(opts)
    local position = opts and opts.win and opts.win.position or "right"
    local relative = position == "float" and "editor" or ""
    local buf = next_buf_id
    next_buf_id = next_buf_id + 1
    local win = make_window(buf, { relative = relative })
    current_win = win
    local term
    term = {
      buf = buf,
      win = win,
      id = 1,
      opts = { wo = {}, w = {}, position = position },
      buf_valid = function()
        return vim.api.nvim_buf_is_valid(term.buf)
      end,
      win_valid = function()
        return term.win ~= nil and vim.api.nvim_win_is_valid(term.win)
      end,
      handlers = {},
      on = function(self, event, fn)
        self.handlers[event] = self.handlers[event] or {}
        table.insert(self.handlers[event], fn)
      end,
      focus = function() end,
      close = function() end,
      -- Snacks originals that patch_instance captures; show recreates a window.
      hide = function()
        if term.win then
          windows[term.win].valid = false
        end
        term.win = nil
      end,
      show = open_show_spy,
      toggle = function() end,
    }
    _G.__snacks_instances = _G.__snacks_instances or {}
    table.insert(_G.__snacks_instances, term)
    return term
  end

  before_each(function()
    _G.__snacks_instances = {}
    original_vim = vim
    spy = require("luassert.spy")
    windows = {}
    current_win = 0
    next_win_id = 1000
    next_buf_id = 1
    last_split_cmd = nil
    current_tab = 1

    open_show_spy = spy.new(function(self)
      -- Snacks re-creates the window from the original opts (e.g. a float).
      local position = self.opts and self.opts.position or "right"
      local relative = position == "float" and "editor" or ""
      self.win = make_window(self.buf, { relative = relative })
      current_win = self.win
      return self
    end)

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
      o = { columns = 120, lines = 40 },
      bo = setmetatable({}, {
        __index = function(t, buf)
          rawset(t, buf, {})
          return rawget(t, buf)
        end,
      }),
      w = setmetatable({}, {
        __index = function(t, win)
          rawset(t, win, rawget(t, win) or {})
          return rawget(t, win)
        end,
      }),
      fn = {
        has = function(feature)
          return feature == "nvim-0.10" and 1 or 0
        end,
      },
      cmd = function(c)
        c = tostring(c)
        -- matches both "vsplit" (vertical) and "split" (horizontal); record only
        -- split commands so a later startinsert/wincmd does not clobber it
        if c:find("split") then
          last_split_cmd = c
          local new_id = make_window(nil, { relative = "" })
          current_win = new_id
        end
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
      split = function(str, sep)
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
      api = {
        -- Mock additions for the session-aware provider.
        nvim_create_autocmd = function() end,
        nvim_buf_get_var = function()
          error("no terminal_job_id in mock")
        end,
        nvim_win_get_tabpage = function(w)
          return windows[w] and windows[w].tab or 1
        end,
        nvim_get_current_tabpage = function()
          return current_tab
        end,
        nvim_tabpage_list_wins = function(t)
          local ids = {}
          for id, w in pairs(windows) do
            if w.valid and w.tab == t then
              table.insert(ids, id)
            end
          end
          table.sort(ids)
          return ids
        end,
        nvim_buf_is_valid = function(b)
          return b ~= nil and b >= 1
        end,
        nvim_buf_get_option = function()
          return "terminal"
        end,
        nvim_win_is_valid = function(w)
          return w ~= nil and windows[w] ~= nil and windows[w].valid
        end,
        nvim_win_get_config = function(w)
          local win = windows[w]
          if not win then
            return {}
          end
          return { relative = win.config.relative, hide = win.config.hide }
        end,
        nvim_win_set_config = function(w, cfg)
          if windows[w] then
            for k, v in pairs(cfg) do
              windows[w].config[k] = v
            end
          end
        end,
        nvim_win_close = function(w)
          if windows[w] then
            windows[w].valid = false
          end
        end,
        nvim_win_get_buf = function(w)
          return windows[w] and windows[w].buf
        end,
        nvim_win_set_buf = function(w, b)
          if windows[w] then
            windows[w].buf = b
          end
        end,
        nvim_win_set_height = function() end,
        nvim_get_current_win = function()
          return current_win
        end,
        nvim_set_current_win = function(w)
          current_win = w
        end,
        nvim_win_call = function(_, fn)
          fn()
        end,
      },
    }

    mock_snacks = {
      terminal = {
        open = spy.new(function(_cmd, opts)
          return make_term_instance(opts)
        end),
      },
      util = { wo = function() end },
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
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }
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

  local function split_config()
    return { cwd = "/w", split_side = "right", split_width_percentage = 0.3, auto_close = false, snacks_win_opts = {} }
  end
  local function float_config()
    return {
      cwd = "/w",
      split_side = "right",
      split_width_percentage = 0.3,
      auto_close = false,
      snacks_win_opts = { position = "float" },
    }
  end

  it("split: simple_toggle hides by closing the window and shows by recreating it", function()
    snacks_provider.open("claude", {}, split_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    assert.is_not_nil(term.win)
    local first_win = term.win
    assert.is_true(windows[first_win].valid)

    -- Hide: window is closed, tracked win cleared.
    snacks_provider.simple_toggle("claude", {}, split_config())
    assert.is_false(windows[first_win].valid)
    assert.is_nil(term.win)

    -- Show: a fresh window is created via vsplit and the buffer is set in it.
    snacks_provider.simple_toggle("claude", {}, split_config())
    assert.is_not_nil(term.win)
    assert.is_true(windows[term.win].valid)
    assert.are.equal(term.buf, windows[term.win].buf)
    -- Snacks' own show() must NOT be used for a split (that path drifts).
    assert.spy(open_show_spy).was_not_called()
  end)

  it("float: simple_toggle config-hides (hide=true) and shows (hide=false) without closing", function()
    snacks_provider.open("claude", {}, float_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    local win = term.win
    assert.are.equal("editor", windows[win].config.relative)

    snacks_provider.simple_toggle("claude", {}, float_config())
    assert.is_true(windows[win].valid) -- window kept alive
    assert.is_true(windows[win].config.hide) -- just parked
    assert.are.equal(win, term.win)

    snacks_provider.simple_toggle("claude", {}, float_config())
    assert.is_false(windows[win].config.hide)
    assert.are.equal(win, term.win)
  end)

  it("treats a config-hidden float as not visible (so a send/open re-shows it)", function()
    snacks_provider.open("claude", {}, float_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    windows[term.win].config.hide = true
    -- get_active_bufnr still reports the buffer (terminal exists, just hidden)...
    assert.are.equal(term.buf, snacks_provider.get_active_bufnr())
    -- ...and a focus toggle un-hides rather than treating it as visible.
    snacks_provider.simple_toggle("claude", {}, float_config())
    assert.is_false(windows[term.win].config.hide)
  end)

  it("split close that errors (E444 last window) does not throw and keeps state sane", function()
    snacks_provider.open("claude", {}, split_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    local win = term.win
    -- Simulate "cannot close last window".
    vim.api.nvim_win_close = function()
      error("E444: Cannot close last window")
    end
    assert.has_no.errors(function()
      snacks_provider.simple_toggle("claude", {}, split_config())
    end)
    -- Close failed, so the window stays and remains tracked (no desync).
    assert.are.equal(win, term.win)
  end)

  it("externally-closed float reopens as a float (via Snacks), not a split", function()
    snacks_provider.open("claude", {}, float_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    -- External close (e.g. :q): window dies but buffer survives; no cc_hide ran.
    windows[term.win].valid = false
    term.win = nil

    snacks_provider.simple_toggle("claude", {}, float_config())
    -- Recreated through Snacks (preserves float opts), NOT the vsplit path.
    assert.spy(open_show_spy).was_called()
    assert.are.equal("editor", windows[term.win].config.relative)
  end)

  it("reuses the existing terminal on a second open() without error", function()
    snacks_provider.open("claude", {}, split_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    local win = term.win
    assert.has_no.errors(function()
      snacks_provider.open("claude", {}, split_config(), true)
    end)
    -- Still the same visible window (no destroy/recreate when already visible).
    assert.are.equal(win, term.win)
    assert.is_true(windows[win].valid)
  end)

  it("recreates a top/bottom position as a horizontal split, not a vsplit", function()
    local function bottom_config()
      return {
        cwd = "/w",
        split_side = "right",
        split_width_percentage = 0.3,
        auto_close = false,
        snacks_win_opts = { position = "bottom", height = 0.3 },
      }
    end
    snacks_provider.open("claude", {}, bottom_config(), true)
    snacks_provider.simple_toggle("claude", {}, bottom_config()) -- hide (close)
    last_split_cmd = nil
    snacks_provider.simple_toggle("claude", {}, bottom_config()) -- show (recreate)
    assert.is_truthy(last_split_cmd and last_split_cmd:find("split"))
    assert.is_nil(last_split_cmd:find("vsplit")) -- horizontal split, not vertical
    assert.spy(open_show_spy).was_not_called() -- native recreate, not Snacks'
  end)

  it("recreates an unsupported position (e.g. current) via Snacks, not a raw split", function()
    local function current_config()
      return {
        cwd = "/w",
        split_side = "right",
        split_width_percentage = 0.3,
        auto_close = false,
        snacks_win_opts = { position = "current" },
      }
    end
    snacks_provider.open("claude", {}, current_config(), true)
    snacks_provider.simple_toggle("claude", {}, current_config()) -- hide (close)
    snacks_provider.simple_toggle("claude", {}, current_config()) -- show
    assert.spy(open_show_spy).was_called() -- delegated to Snacks
  end)

  -- Multi-session: each session owns its own Snacks instance, and switching
  -- sessions parks the outgoing one (cc_hide) and unparks the target (cc_show)
  -- instead of destroying and recreating windows.
  it("parks the previous float instead of closing it when switching sessions", function()
    snacks_provider.open_session("s1", "claude", {}, float_config(), true)
    local s1_win = current_win
    snacks_provider.open_session("s2", "claude", {}, float_config(), true)
    -- Opening s2 parks s1's float (config-hidden, window kept alive).
    assert.is_true(windows[s1_win].valid)
    assert.is_true(windows[s1_win].config.hide)
    snacks_provider.focus_session("s1", float_config())
    assert.is_true(windows[s1_win].valid) -- not destroyed
    assert.is_false(windows[s1_win].config.hide == true) -- s1 visible again
  end)

  it("unparking a session with focus enters insert mode unless auto_insert is false", function()
    local cmds = {}
    local orig_cmd = vim.cmd
    vim.cmd = function(c)
      table.insert(cmds, tostring(c))
      return orig_cmd(c)
    end
    local function has_startinsert()
      for _, c in ipairs(cmds) do
        if c == "startinsert" then
          return true
        end
      end
      return false
    end

    local cfg = float_config()
    snacks_provider.open_session("s1", "claude", {}, cfg, true)
    local win = snacks_provider.get_session_window("s1")
    snacks_provider.hide_session("s1")
    assert.is_nil(snacks_provider.get_session_window("s1"))

    cmds = {}
    snacks_provider.open_session("s1", "claude", {}, cfg, true)
    assert.are.equal(win, snacks_provider.get_session_window("s1"))
    assert.are.equal(win, current_win)
    assert.is_true(has_startinsert())

    snacks_provider.hide_session("s1")
    cfg.auto_insert = false
    cmds = {}
    snacks_provider.open_session("s1", "claude", {}, cfg, true)
    assert.are.equal(win, current_win) -- still focused
    assert.is_false(has_startinsert())
  end)

  it("patches every session instance (hide keeps the process)", function()
    snacks_provider.open_session("s1", "claude", {}, split_config(), true)
    snacks_provider.simple_toggle("claude", {}, split_config())
    assert.is_not_nil(snacks_provider.get_session_bufnr("s1"))
  end)

  -- Shared sessions (per_tab_sessions = false): the same session is shown from
  -- a second tabpage. It must appear in the current tabpage, not jump focus to
  -- (or be treated as visible in) the tabpage where it was first opened.
  it("split: showing a session from another tabpage opens a split here and keeps the other", function()
    snacks_provider.open_session("s1", "claude", {}, split_config(), true)
    local tab1_win = snacks_provider.get_session_window("s1")
    current_tab = 2
    current_win = make_window(99, { relative = "" })
    snacks_provider.open_session("s1", "claude", {}, split_config(), true)
    local here = snacks_provider.get_session_window("s1")
    assert.is_not_nil(here)
    assert.are_not.equal(tab1_win, here)
    assert.are.equal(2, windows[here].tab)
    assert.are.equal(here, current_win)
    assert.is_true(windows[tab1_win].valid) -- tab 1 keeps its own split
  end)

  it("float: showing a session from another tabpage moves the float here", function()
    snacks_provider.open_session("s1", "claude", {}, float_config(), true)
    local tab1_win = snacks_provider.get_session_window("s1")
    current_tab = 2
    current_win = make_window(99, { relative = "" })
    snacks_provider.open_session("s1", "claude", {}, float_config(), false)
    local here = snacks_provider.get_session_window("s1")
    assert.is_not_nil(here)
    assert.are.equal(2, windows[here].tab)
    assert.is_false(windows[tab1_win].valid) -- a float belongs to one tabpage
  end)

  -- Shared sessions + split: a session shown in two tabpages must toggle per
  -- tabpage. Each toggle hides the window the current tab shows, or shows one
  -- there (reusing a window the tab already has); a tab never ends up with two
  -- windows of the same session, and no window is left stuck.
  describe("shared-mode split toggled across tabpages", function()
    -- Mirrors terminal.lua simple_toggle for a window-owning provider: hide the
    -- session when it is on screen in the current tab, otherwise show it.
    local function toggle(sid, cfg)
      local w = snacks_provider.get_session_window(sid)
      if w and windows[w].tab == current_tab then
        snacks_provider.hide_session(sid)
      else
        snacks_provider.open_session(sid, "claude", {}, cfg, true)
      end
    end

    local function wins_in_tab(tab, buf)
      local ids = {}
      for id, w in pairs(windows) do
        if w.valid and w.tab == tab and w.buf == buf and not w.config.hide then
          table.insert(ids, id)
        end
      end
      return ids
    end

    local function goto_tab(tab)
      current_tab = tab
      for id, w in pairs(windows) do
        if w.valid and w.tab == tab and w.buf ~= nil then
          current_win = id
          return
        end
      end
      current_win = make_window(90 + tab, { relative = "" })
    end

    it("tab 1 show, tab 2 show, tab 1 toggle hides with no second window", function()
      local cfg = split_config()
      goto_tab(1)
      toggle("s1", cfg)
      local buf = snacks_provider.get_session_bufnr("s1")
      assert.are.equal(1, #wins_in_tab(1, buf))

      goto_tab(2)
      toggle("s1", cfg)
      assert.are.equal(1, #wins_in_tab(2, buf))
      assert.are.equal(1, #wins_in_tab(1, buf)) -- tab 1 keeps its own view

      goto_tab(1)
      local visible = snacks_provider.get_session_window("s1")
      assert.is_not_nil(visible)
      assert.are.equal(1, windows[visible].tab) -- the tab's own window is found
      toggle("s1", cfg)
      assert.are.equal(0, #wins_in_tab(1, buf)) -- hidden, not duplicated
      assert.are.equal(1, #wins_in_tab(2, buf)) -- tab 2 untouched
    end)

    it("never stacks two windows in a tab over many alternating cycles", function()
      local cfg = split_config()
      goto_tab(1)
      toggle("s1", cfg)
      local buf = snacks_provider.get_session_bufnr("s1")
      local expect = { [1] = 1, [2] = 0 }
      for _ = 1, 10 do
        for _, tab in ipairs({ 2, 1 }) do
          goto_tab(tab)
          toggle("s1", cfg)
          expect[tab] = 1 - expect[tab]
          for t = 1, 2 do
            local n = #wins_in_tab(t, buf)
            assert.is_true(n <= 1, "tab " .. t .. " shows the session " .. n .. " times")
            assert.are.equal(expect[t], n, "tab " .. t .. " visibility")
          end
        end
      end
    end)

    it("reuses the tab's existing window instead of opening another split on show", function()
      local cfg = split_config()
      goto_tab(1)
      toggle("s1", cfg)
      local buf = snacks_provider.get_session_bufnr("s1")
      local tab1_win = wins_in_tab(1, buf)[1]
      goto_tab(2)
      toggle("s1", cfg)
      goto_tab(1)
      current_win = make_window(95, { relative = "" }) -- cursor in another window
      snacks_provider.open_session("s1", "claude", {}, cfg, true)
      assert.are.same({ tab1_win }, wins_in_tab(1, buf))
      assert.are.equal(tab1_win, current_win) -- focused, not duplicated
    end)

    it("parks a session shown in this tab when another session takes its place", function()
      local cfg = split_config()
      goto_tab(1)
      toggle("s1", cfg)
      local buf1 = snacks_provider.get_session_bufnr("s1")
      goto_tab(2)
      toggle("s1", cfg)
      goto_tab(1)
      snacks_provider.open_session("s2", "claude", {}, cfg, true)
      assert.are.equal(0, #wins_in_tab(1, buf1)) -- s1's tab-1 view was parked
      assert.are.equal(1, #wins_in_tab(2, buf1)) -- tab 2 keeps its own view
    end)
  end)

  -- I4: when a session exits, its replacement is chosen among sessions with
  -- their own live instance, and with per_tab_sessions on only among the
  -- exited session's own tabpage.
  describe("replacement on exit (I4)", function()
    local session_manager
    local tab_registry

    before_each(function()
      package.loaded["claudecode.session"] = nil
      package.loaded["claudecode.tab_registry"] = nil
      session_manager = require("claudecode.session")
      tab_registry = require("claudecode.tab_registry")
      session_manager.reset()
      tab_registry.reset()
      -- Reload the provider so it binds to these fresh session/registry modules.
      package.loaded["claudecode.terminal.snacks"] = nil
      snacks_provider = require("claudecode.terminal.snacks")
      vim.v = { event = { status = 0 } }
      vim.cmd = setmetatable({ checktime = function() end }, {
        __call = function(_, c)
          c = tostring(c)
          if c:find("split") then
            last_split_cmd = c
            current_win = make_window(nil, { relative = "" })
          end
        end,
      })
      vim.api.nvim_exec_autocmds = function() end
    end)

    after_each(function()
      session_manager.reset()
      tab_registry.reset()
      package.loaded["claudecode.session"] = nil
      package.loaded["claudecode.tab_registry"] = nil
    end)

    local function exit_session(sid)
      local term = snacks_provider._get_terminal_for_test()
      -- find the instance by its buffer
      local buf = snacks_provider.get_session_bufnr(sid)
      assert.is_not_nil(buf)
      for _, t in ipairs(_G.__snacks_instances) do
        if t.buf == buf then
          term = t
        end
      end
      for _, fn in ipairs(term.handlers.TermClose or {}) do
        fn()
      end
    end

    local function auto_close_split()
      local cfg = split_config()
      cfg.auto_close = true
      return cfg
    end

    it("per-tab: never pulls another tab's session into the exited session's place", function()
      tab_registry.set_per_tab_enabled(true)
      local s1 = session_manager.create_session()
      tab_registry.bind(1, s1)
      snacks_provider.open_session(s1, "claude", {}, auto_close_split(), true)

      current_tab = 2
      current_win = make_window(99, { relative = "" })
      local s2 = session_manager.create_session()
      tab_registry.bind(2, s2)
      snacks_provider.open_session(s2, "claude", {}, auto_close_split(), true)
      local s2_win = snacks_provider.get_session_window(s2)

      current_tab = 1
      exit_session(s1)

      -- s2 still lives only in tab 2; nothing of it was shown in tab 1.
      assert.are.equal(s2_win, snacks_provider.get_session_window(s2))
      assert.are.equal(2, windows[s2_win].tab)
      for _, w in pairs(windows) do
        if w.valid and w.tab == 1 then
          assert.are_not.equal(snacks_provider.get_session_bufnr(s2), w.buf)
        end
      end
    end)

    it("never maps one session's terminal onto another session", function()
      local s1 = session_manager.create_session()
      local s2 = session_manager.create_session() -- never opened: no instance
      local s3 = session_manager.create_session()
      snacks_provider.open_session(s1, "claude", {}, auto_close_split(), true)
      snacks_provider.open_session(s3, "claude", {}, auto_close_split(), true)
      local s3_buf = snacks_provider.get_session_bufnr(s3)
      session_manager.set_active_session(s2)

      exit_session(s1)

      assert.is_nil(snacks_provider.get_session_bufnr(s2))
      assert.are.equal(s3_buf, snacks_provider.get_session_bufnr(s3))
      assert.are.equal(s3, session_manager.get_active_session_id())
    end)
  end)
end)
