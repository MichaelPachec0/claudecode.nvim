---Snacks.nvim terminal provider for Claude Code.
---Supports multiple terminal sessions.
---Each session owns a Snacks instance and its window; hide/show park and unpark it.
---@module 'claudecode.terminal.snacks'

local M = {}

local snacks_available, Snacks = pcall(require, "snacks")
local osc_handler = require("claudecode.terminal.osc_handler")
local session_manager = require("claudecode.session")
local utils = require("claudecode.utils")

---Module-level fallback config, used by call sites (e.g. close_session) that
---have no effective_config of their own in scope. Function parameters named
---`config`/`effective_config` shadow this within their own function bodies.
---@type ClaudeCodeTerminalConfig
local default_config = require("claudecode.terminal").defaults

-- Legacy single terminal support (backward compatibility)
local terminal = nil

-- Multi-session terminal storage
---@type table<string, table> Map of session_id -> terminal instance
local terminals = {}

-- Track sessions being intentionally closed (to suppress exit error messages)
---@type table<string, boolean>
local closing_sessions = {}

--- @return boolean
local function is_available()
  return snacks_available and Snacks and Snacks.terminal ~= nil
end

-- ---------------------------------------------------------------------------
-- Climbing-cursor workaround (#240 split / #183 float).
--
-- Snacks hides a terminal by CLOSING its window (nvim_win_close) and re-shows it
-- by recreating the window in open_win(). That recreate leaves Claude's terminal
-- cursor anchor one row off; Claude (Ink) re-renders relative to the cursor on
-- the focus-in event Neovim sends when the window is shown, so the prompt climbs
-- one row per toggle. Neither a pty resize nor the focus event alone causes it --
-- it is the destroy+recreate of the window. To avoid disturbing the anchor we
-- manage hide/show ourselves:
--   * floating window -> nvim_win_set_config({hide=true/false}) keeps the window
--     (and its grid/cursor) alive. Requires nvim-0.10 (the `hide` win-config field).
--   * split window -> cannot be config-hidden, so close on hide and recreate with
--     a plain vsplit + nvim_win_set_buf on show, exactly like the native provider
--     (which does not drift). Buffer-local state (the <S-CR> map) survives.
-- ---------------------------------------------------------------------------

local function win_get_config(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  if ok then
    return cfg
  end
  return nil
end

-- A real split window reports relative == "" regardless of the opts Snacks was
-- given; a float reports "editor"/"win"/"cursor".
local function win_is_floating(win)
  local cfg = win_get_config(win)
  return cfg ~= nil and cfg.relative ~= nil and cfg.relative ~= ""
end

local function win_is_config_hidden(win)
  local cfg = win_get_config(win)
  return cfg ~= nil and cfg.hide == true
end

local function supports_config_hide()
  return vim.fn ~= nil and vim.fn.has ~= nil and vim.fn.has("nvim-0.10") == 1
end

-- Resolve a Snacks width/height value to an absolute cell count: a fraction in
-- (0,1) scales `total`; a value >= 1 is taken as absolute; otherwise fall back
-- to `default_frac` of `total`.
local function resolve_split_size(val, total, default_frac)
  if type(val) == "number" and val > 0 then
    if val < 1 then
      return math.max(1, math.floor(total * val))
    end
    return math.floor(val)
  end
  return math.max(1, math.floor(total * default_frac))
end

local function start_insert_if_terminal(term)
  if
    term.buf
    and vim.api.nvim_buf_is_valid(term.buf)
    and vim.api.nvim_buf_get_option(term.buf, "buftype") == "terminal"
    and term.win
    and vim.api.nvim_win_is_valid(term.win)
  then
    vim.api.nvim_win_call(term.win, function()
      vim.cmd("startinsert")
    end)
  end
end

-- Enter insert mode unless the user opted out via terminal.auto_insert = false
-- (issue #232). When disabled, re-focusing the terminal window keeps Normal mode
-- and preserves the scroll position instead of jumping to the prompt.
local function maybe_start_insert(term, config)
  if not config or config.auto_insert ~= false then
    start_insert_if_terminal(term)
  end
end

-- Visible == a live window that shows our buffer and is not config-hidden.
local function cc_is_visible(term)
  local win = term and term.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if win_is_config_hidden(win) then
    return false
  end
  -- Match Snacks' own valid() / the native provider: a window showing some other
  -- buffer is not "our" terminal being visible.
  return vim.api.nvim_win_get_buf(win) == term.buf
end

local function set_backdrop_hidden(term, hidden)
  if term.backdrop and term.backdrop.win and vim.api.nvim_win_is_valid(term.backdrop.win) then
    pcall(vim.api.nvim_win_set_config, term.backdrop.win, { hide = hidden })
  end
end

-- Re-apply the Snacks-managed window-local options/vars that are lost when a
-- split window is closed and recreated (minimal style turns off number/sign
-- column, sets winhighlight, etc.), so the re-shown split matches the original.
local function reapply_snacks_window_state(term, win)
  if not (term.opts and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if snacks_available and Snacks and Snacks.util and Snacks.util.wo and term.opts.wo then
    pcall(Snacks.util.wo, win, term.opts.wo)
  end
  for k, v in pairs(term.opts.w or {}) do
    pcall(function()
      vim.w[win][k] = v
    end)
  end
  -- Stacking marker so a second Snacks split can equalize against this one.
  pcall(function()
    vim.w[win].snacks_win = { id = term.id, position = term.opts.position }
  end)
end

---True when `win` lives in the current tabpage.
---@param win number|nil
---@return boolean
local function win_in_current_tab(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  local ok_win, win_tab = pcall(vim.api.nvim_win_get_tabpage, win)
  local ok_cur, cur_tab = pcall(vim.api.nvim_get_current_tabpage)
  return ok_win and ok_cur and win_tab == cur_tab
end

---Hide the terminal window without disturbing the cursor anchor.
---@param term table Snacks terminal instance
local function cc_hide(term)
  if not cc_is_visible(term) then
    return
  end
  local logger = require("claudecode.logger")
  local win = term.win
  if win_is_floating(win) then
    if supports_config_hide() then
      logger.debug("terminal", "Snacks hide: config-hiding float (hide=true)")
      if term._cc then
        term._cc.kind = "float"
      end
      vim.api.nvim_win_set_config(win, { hide = true })
      set_backdrop_hidden(term, true)
      -- Neovim does not auto-leave a config-hidden window; step out of it.
      if vim.api.nvim_get_current_win() == win then
        pcall(vim.cmd, "wincmd p")
      end
    elseif term._cc and term._cc.orig_hide then
      -- Pre-0.10 float: no config-hide available, fall back to Snacks (cursor
      -- drift is not avoidable on these versions). Recreate as a float on show.
      logger.debug("terminal", "Snacks hide: pre-0.10 float via Snacks (drift unavoidable)")
      term._cc.kind = "float"
      term._cc.orig_hide(term)
    end
  else
    -- Split: close the window, keep the buffer + job alive. pcall so closing the
    -- LAST window (E444) is a harmless no-op instead of a throw; only forget the
    -- window on a successful close so state stays consistent.
    logger.debug("terminal", "Snacks hide: closing split window")
    if term._cc then
      term._cc.kind = "split"
    end
    if pcall(vim.api.nvim_win_close, win, false) then
      term.win = nil
    end
  end
end

---Show the terminal window, recreating splits the native way.
---@param term table Snacks terminal instance
---@param focus boolean Whether to focus the terminal and enter insert mode
---@param config table Effective terminal config (split_side, split_width_percentage)
---@return boolean shown
local function cc_show(term, focus, config)
  if not (term and term.buf and vim.api.nvim_buf_is_valid(term.buf)) then
    return false
  end
  local logger = require("claudecode.logger")
  local win = term.win

  -- Shared sessions (terminal.per_tab_sessions = false): the instance can be on
  -- screen, or parked, in another tabpage. Show it in this tabpage instead of
  -- jumping to that one. A float belongs to a single tabpage, so it is closed
  -- there and recreated here. A split is left in place (as the native provider
  -- does) and a new one is opened here.
  if win and vim.api.nvim_win_is_valid(win) and not win_in_current_tab(win) then
    if win_is_floating(win) then
      logger.debug("terminal", "Snacks show: moving float from another tabpage")
      if term.backdrop and term.backdrop.win and vim.api.nvim_win_is_valid(term.backdrop.win) then
        pcall(vim.api.nvim_win_close, term.backdrop.win, true)
      end
      pcall(vim.api.nvim_win_close, win, true)
      if term._cc then
        term._cc.kind = "float"
      end
    else
      logger.debug("terminal", "Snacks show: opening a split here; the other tabpage keeps its own")
      if term._cc then
        term._cc.kind = "split"
      end
    end
    term.win = nil
    win = nil
  end

  -- Config-hidden float -> just un-hide it.
  if win and vim.api.nvim_win_is_valid(win) and win_is_config_hidden(win) then
    logger.debug("terminal", "Snacks show: un-hiding config-hidden float")
    vim.api.nvim_win_set_config(win, { hide = false })
    set_backdrop_hidden(term, false)
    if focus then
      vim.api.nvim_set_current_win(win)
      maybe_start_insert(term, config)
    end
    return true
  end

  -- Already visible -> optionally focus.
  if cc_is_visible(term) then
    if focus then
      vim.api.nvim_set_current_win(term.win)
      maybe_start_insert(term, config)
    end
    return true
  end

  -- Window is fully gone. Recreate it honoring the configured Snacks position:
  --   * float / any non-split position -> let Snacks re-create it (it owns the
  --     geometry); recreating it as a plain split would change its kind.
  --   * left/right -> vertical split, top/bottom -> horizontal split. Recreated
  --     natively (the drift-free path), sized from the resolved Snacks opts.
  local win_opts = (config and config.snacks_win_opts) or {}
  local position = win_opts.position or (config and config.split_side) or "right"
  local is_native_split = position == "left" or position == "right" or position == "top" or position == "bottom"
  if (not is_native_split or (term._cc and term._cc.kind == "float")) and term._cc and term._cc.orig_show then
    logger.debug("terminal", "Snacks show: re-creating via Snacks (position=" .. tostring(position) .. ")")
    term._cc.kind = nil
    term._cc.orig_show(term)
    if focus and term.win and vim.api.nvim_win_is_valid(term.win) then
      vim.api.nvim_set_current_win(term.win)
      maybe_start_insert(term, config)
    end
    return true
  end

  local original_win = vim.api.nvim_get_current_win()
  local horizontal = position == "top" or position == "bottom"
  local lead = (position == "top" or position == "left") and "topleft " or "botright "
  local new_win
  if horizontal then
    local height = resolve_split_size(win_opts.height, vim.o.lines, 0.30)
    logger.debug("terminal", "Snacks show: re-creating " .. position .. " split (native, h=" .. height .. ")")
    vim.cmd(lead .. height .. "split")
    new_win = vim.api.nvim_get_current_win()
  else
    local width = resolve_split_size(win_opts.width, vim.o.columns, (config and config.split_width_percentage) or 0.30)
    logger.debug("terminal", "Snacks show: re-creating " .. position .. " split (native, w=" .. width .. ")")
    vim.cmd(lead .. width .. "vsplit")
    new_win = vim.api.nvim_get_current_win()
  end
  -- Set term.win before nvim_win_set_buf so Snacks' fixbuf BufWinEnter autocmd
  -- (if still registered) sees a valid window and does not self-delete.
  term.win = new_win
  vim.api.nvim_win_set_buf(new_win, term.buf)
  if not horizontal then
    vim.api.nvim_win_set_height(new_win, vim.o.lines) -- full height for vertical splits, like native
  end
  term.closed = false
  reapply_snacks_window_state(term, new_win)
  if focus then
    maybe_start_insert(term, config)
  elseif vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  end
  return true
end

---State stashed on a patched Snacks terminal instance.
---@class ClaudeCodeSnacksPatch
---@field orig_hide fun(self: table) Snacks' original Win:hide
---@field orig_show fun(self: table) Snacks' original Win:show
---@field orig_toggle fun(self: table) Snacks' original Win:toggle
---@field config table Effective terminal config captured at open time
---@field kind? "float"|"split" Window kind recorded at hide time

-- Monkeypatch the Snacks terminal instance so hide/show/toggle -- including any
-- the user wires to Snacks keymaps (e.g. self:hide() in snacks_win_opts.keys) --
-- use the anchor-preserving paths above instead of Snacks' destroy+recreate.
local function patch_instance(term, config)
  term._cc = {
    orig_hide = term.hide,
    orig_show = term.show,
    orig_toggle = term.toggle,
    config = config,
  }
  function term:hide()
    cc_hide(self)
    return self
  end
  function term:show()
    cc_show(self, true, self._cc and self._cc.config)
    return self
  end
  function term:toggle()
    if cc_is_visible(self) then
      cc_hide(self)
    else
      cc_show(self, true, self._cc and self._cc.config)
    end
    return self
  end
end

-- ---------------------------------------------------------------------------
-- Multi-session instances.
--
-- Every session owns its own Snacks terminal instance, and that instance owns
-- its own window (float or split, as configured). The shared window_manager
-- window is NOT used for Snacks: swapping another session's buffer into a
-- Snacks window would be undone by Snacks' own fixbuf autocmd, and closing the
-- Snacks window right after creation (to borrow the buffer) is exactly the
-- destroy+recreate cycle that makes Claude's prompt climb. Instead, a session
-- switch parks the outgoing instance (cc_hide) and unparks the target
-- (cc_show), so each instance keeps its window/cursor anchor across switches.
-- ---------------------------------------------------------------------------

---Park every visible session instance in the current tabpage except `keep`.
---Instances shown in other tabpages belong to those tabs' sessions and are
---left alone.
---@param keep table|nil The instance about to be shown (never parked)
local function park_others_in_current_tab(keep)
  local seen = {}
  local function park(term)
    if term and term ~= keep and not seen[term] then
      seen[term] = true
      if term:buf_valid() and cc_is_visible(term) and win_in_current_tab(term.win) then
        cc_hide(term)
      end
    end
  end
  for _, term in pairs(terminals) do
    park(term)
  end
  park(terminal)
end

---Attach the tab bar to a session instance's window (no-op when tabs are off
---or the instance has no window).
---@param term table Snacks terminal instance
local function attach_tabbar(term)
  if not (term and term.win and vim.api.nvim_win_is_valid(term.win)) then
    return
  end
  local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
  if ok then
    tabbar.attach(term.win, term.buf, term)
  end
end

---Close a session instance's window (config-hidden or not) so deleting its
---buffer never leaves a stray float or backdrop behind.
---@param term table Snacks terminal instance
local function close_instance_window(term)
  if term.backdrop and term.backdrop.win and vim.api.nvim_win_is_valid(term.backdrop.win) then
    pcall(vim.api.nvim_win_close, term.backdrop.win, true)
  end
  if term.win and vim.api.nvim_win_is_valid(term.win) then
    if pcall(vim.api.nvim_win_close, term.win, true) then
      term.win = nil
    end
  end
end

---Setup event handlers for terminal instance
---@param term_instance table The Snacks terminal instance
---@param config table Configuration options
---@param session_id string|nil Optional session ID for multi-session support
local function setup_terminal_events(term_instance, config, session_id)
  local logger = require("claudecode.logger")

  -- Stop tracking the job's PID as soon as the process exits, regardless of
  -- auto_close: a PID that stays tracked after exit can be reused by an
  -- unrelated process, which cleanup_all would then signal.
  local function untrack_job()
    local buf = term_instance.buf
    if not buf then
      return
    end
    local ok, job_id = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
    if ok and job_id then
      require("claudecode.terminal").untrack_terminal_pid(job_id)
    end
  end
  term_instance:on("TermClose", untrack_job, { buf = true })

  -- Handle command completion/exit - only if auto_close is enabled
  if config.auto_close then
    term_instance:on("TermClose", function()
      -- Check if this was an intentional close (via close_session_keep_window)
      local is_intentional_close = session_id and closing_sessions[session_id]

      -- Only show error if this wasn't an intentional close
      if vim.v.event.status ~= 0 and not is_intentional_close then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      -- If this was an intentional close, close_session_keep_window already handled
      -- the session switching - we just need minimal cleanup here
      if is_intentional_close then
        logger.debug("terminal", "TermClose for intentionally closed session, skipping switch logic")
        if session_id then
          terminals[session_id] = nil
          closing_sessions[session_id] = nil
        end
        if terminal == term_instance then
          terminal = nil
        end
        return
      end

      -- Remember whether the exited session was on screen, so another session
      -- only takes its place when the user was actually looking at it.
      local was_visible = cc_is_visible(term_instance)
      local session_count = session_manager.get_session_count()

      -- Track the exited session ID for cleanup
      local exited_session_id = session_id

      -- Clean up terminal state
      if session_id then
        terminals[session_id] = nil
        closing_sessions[session_id] = nil
        -- Destroy the session in session manager (only if it still exists)
        if session_manager.get_session(session_id) then
          session_manager.destroy_session(session_id)
        end
      else
        -- For legacy terminal, find and destroy associated session
        if term_instance.buf then
          local session = session_manager.find_session_by_bufnr(term_instance.buf)
          if session then
            exited_session_id = session.id
            logger.debug("terminal", "Destroying session for exited terminal: " .. session.id)
            if session_manager.get_session(session.id) then
              session_manager.destroy_session(session.id)
            end
          end
        end
      end

      if terminal == term_instance then
        terminal = nil
      end

      vim.schedule(function()
        -- Upstream behavior: close the exited instance's own window and buffer.
        local exited_buf = term_instance.buf
        close_instance_window(term_instance)
        pcall(function()
          term_instance:close({ buf = true })
        end)
        if exited_buf and vim.api.nvim_buf_is_valid(exited_buf) then
          pcall(vim.api.nvim_buf_delete, exited_buf, { force = true })
        end

        -- If there are other sessions, switch to the new active session
        if session_count > 1 then
          local new_active_id = session_manager.get_active_session_id()
          if new_active_id then
            local new_term = terminals[new_active_id]

            -- Fallback: check if any other terminal in our table is valid
            if not new_term or not new_term:buf_valid() then
              for sid, term in pairs(terminals) do
                if sid ~= exited_session_id and term and term:buf_valid() then
                  new_term = term
                  terminals[new_active_id] = new_term
                  logger.debug("terminal", "Recovered terminal from table for session: " .. new_active_id)
                  break
                end
              end
            end

            -- Fallback: check the global terminal variable
            if not new_term or not new_term:buf_valid() then
              if terminal and terminal:buf_valid() and terminal ~= term_instance then
                new_term = terminal
                terminals[new_active_id] = new_term
                logger.debug("terminal", "Recovered global terminal for session: " .. new_active_id)
              end
            end

            if new_term and new_term:buf_valid() then
              terminal = new_term
              -- Keep the session manager and the tab's active pointer on the
              -- session that is now in front.
              session_manager.set_active_session(new_active_id)
              if was_visible then
                -- Unpark the new active session in place of the exited one.
                cc_show(new_term, true, config)
                attach_tabbar(new_term)
              end
              logger.debug("terminal", "Switched to session " .. new_active_id)
            end
          end
        end

        vim.cmd.checktime()
      end)
    end, { buf = true })
  end

  -- Handle buffer deletion
  term_instance:on("BufWipeout", function()
    logger.debug("terminal", "Terminal buffer wiped" .. (session_id and (" for session " .. session_id) or ""))
    untrack_job()

    -- Cleanup OSC handler
    if term_instance.buf then
      osc_handler.cleanup_buffer_handler(term_instance.buf)
    end

    if session_id then
      terminals[session_id] = nil
      if session_manager.get_session(session_id) then
        session_manager.destroy_session(session_id)
      end
    else
      if term_instance.buf then
        local session = session_manager.find_session_by_bufnr(term_instance.buf)
        if session then
          logger.debug("terminal", "Destroying session for wiped terminal: " .. session.id)
          if session_manager.get_session(session.id) then
            session_manager.destroy_session(session.id)
          end
        end
      end
    end
    if terminal == term_instance then
      terminal = nil
    end
  end, { buf = true })
end

---Track terminal PID with retry mechanism
---Snacks.terminal.open() may not set terminal_job_id immediately on the buffer.
---This function retries tracking until successful or max retries reached.
---@param term_buf number The terminal buffer number
---@param max_retries number Maximum number of retries (default 5)
---@param delay_ms number Delay between retries in milliseconds (default 50)
local function track_pid_with_retry(term_buf, max_retries, delay_ms)
  max_retries = max_retries or 5
  delay_ms = delay_ms or 50
  local retries = 0

  local function try_track()
    if not term_buf or not vim.api.nvim_buf_is_valid(term_buf) then
      return
    end

    local ok, job_id = pcall(vim.api.nvim_buf_get_var, term_buf, "terminal_job_id")
    if ok and job_id then
      local terminal_module = require("claudecode.terminal")
      if terminal_module.track_terminal_pid then
        terminal_module.track_terminal_pid(job_id)
        local logger = require("claudecode.logger")
        logger.debug("terminal", "PID tracked for job_id: " .. tostring(job_id) .. " (attempt " .. (retries + 1) .. ")")
      end
      return
    end

    retries = retries + 1
    if retries < max_retries then
      vim.defer_fn(try_track, delay_ms * retries)
    else
      local logger = require("claudecode.logger")
      logger.warn("terminal", "Failed to track PID for buffer " .. term_buf .. " after " .. max_retries .. " retries")
    end
  end

  -- Start the first attempt
  try_track()
end

---Build initial title for session tabs
---@param session_id string|nil Optional session ID
---@return string title The title string
local function build_initial_title(session_id)
  local sm = require("claudecode.session")
  local reg = require("claudecode.tab_registry")
  -- With per_tab_sessions on, the title in tab N's terminal reflects tab N's
  -- sessions only (strictly tab-scoped, no fallthrough for unbound sessions).
  -- Otherwise every session is shared by all tabs and all of them are listed.
  local ok_tab, current_tab = pcall(vim.api.nvim_get_current_tabpage)
  local sessions = {}
  if not reg.is_per_tab_enabled() then
    sessions = sm.list_sessions()
  elseif ok_tab and current_tab then
    for _, s in ipairs(sm.list_sessions()) do
      if reg.tab_for_session(s.id) == current_tab then
        table.insert(sessions, s)
      end
    end
  end
  local active_id = session_id or sm.get_active_session_id()

  if #sessions == 0 then
    return "Claude Code"
  end

  local parts = {}
  for i, session in ipairs(sessions) do
    local is_active = session.id == active_id
    local name = session.name or ("Session " .. i)
    if #name > 15 then
      name = name:sub(1, 12) .. "..."
    end
    local label = string.format("%d:%s", i, name)
    if is_active then
      label = "[" .. label .. "]"
    end
    table.insert(parts, label)
  end
  table.insert(parts, "[+]")
  return table.concat(parts, " | ")
end

---Builds Snacks terminal options with focus control
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param env_table table Environment variables to set for the terminal process
---@param session_id string|nil Optional session ID for title
---@param focus boolean|nil Whether to focus the terminal when opened (defaults to true)
---@return snacks.terminal.Opts opts Snacks terminal options with start_insert/auto_insert controlled by focus parameter
local function build_opts(config, env_table, session_id, focus)
  focus = utils.normalize_focus(focus)
  local should_insert = focus and config.auto_insert ~= false

  -- Build keys table with optional exit_terminal keymap
  local keys = {
    claude_new_line = {
      "<S-CR>",
      function()
        vim.api.nvim_feedkeys("\\", "t", true)
        vim.defer_fn(function()
          vim.api.nvim_feedkeys("\r", "t", true)
        end, 10)
      end,
      mode = "t",
      desc = "New line",
    },
  }

  -- Only add exit_terminal keymap to Snacks keys if smart ESC handling is disabled
  local esc_timeout = config.esc_timeout
  if (not esc_timeout or esc_timeout == 0) and config.keymaps and config.keymaps.exit_terminal then
    keys.claude_exit_terminal = {
      config.keymaps.exit_terminal,
      "<C-\\><C-n>",
      mode = "t",
      desc = "Exit terminal mode",
    }
  end

  -- Build title for tabs if enabled
  local title = nil
  if config.tabs and config.tabs.enabled then
    title = build_initial_title(session_id)
  end

  -- Merge user's snacks_win_opts
  local win_opts = vim.tbl_deep_extend("force", {
    position = config.split_side,
    width = config.split_width_percentage,
    height = 0,
    relative = "editor",
    keys = keys,
    title = title,
    title_pos = title and "center" or nil,
  } --[[@as snacks.win.Config]], config.snacks_win_opts or {})

  return {
    env = env_table,
    cwd = config.cwd,
    start_insert = should_insert,
    auto_insert = should_insert,
    auto_close = false,
    win = win_opts,
  } --[[@as snacks.terminal.Opts]]
end

---Report a failed Snacks.terminal.open() with as much detail as we have.
---@param term_instance table|nil What Snacks.terminal.open() returned
---@param cmd_string string
---@param opts table The Snacks options that were used
local function report_open_failure(term_instance, cmd_string, opts)
  local logger = require("claudecode.logger")
  local error_details = {}
  if not term_instance then
    table.insert(error_details, "Snacks.terminal.open() returned nil")
  elseif not term_instance:buf_valid() then
    table.insert(error_details, "terminal instance is invalid")
    if term_instance.buf and not vim.api.nvim_buf_is_valid(term_instance.buf) then
      table.insert(error_details, "buffer is invalid")
    end
    if term_instance.win and not vim.api.nvim_win_is_valid(term_instance.win) then
      table.insert(error_details, "window is invalid")
    end
  end

  local context = string.format("cmd='%s', opts=%s", cmd_string, vim.inspect(opts))
  local error_msg = string.format(
    "Failed to open Claude terminal using Snacks. Details: %s. Context: %s",
    table.concat(error_details, ", "),
    context
  )
  vim.notify(error_msg, vim.log.levels.ERROR)
  logger.debug("terminal", error_msg)
end

---Create a session's Snacks terminal instance. The instance keeps the window
---Snacks opened for it (float or split); it is patched for park/unpark so
---hide/show never destroy and recreate a float, and splits are recreated the
---drift-free native way.
---@param cmd_string string Command to run
---@param env_table table Environment variables
---@param config table Terminal configuration
---@param session_id string Session ID
---@param focus boolean|nil Whether to focus the new terminal (defaults to true)
---@return table|nil term_instance The snacks terminal instance
local function create_terminal_buffer(cmd_string, env_table, config, session_id, focus)
  focus = utils.normalize_focus(focus)
  local original_win = vim.api.nvim_get_current_win()

  local opts = build_opts(config, env_table, session_id, focus)
  -- Pass an argv list (not a string) so Snacks spawns Claude via termopen()
  -- without a shell. A shell would glob-expand bracketed model aliases like
  -- "opus[1m]" (e.g. zsh aborts with "no matches found"). parse_command keeps
  -- quoted arguments intact and expands a leading "~". Mirrors native.
  local cmd = utils.parse_command(cmd_string)
  local term_instance = Snacks.terminal.open(cmd, opts)

  if not (term_instance and term_instance:buf_valid()) then
    report_open_failure(term_instance, cmd_string, opts)
    return nil
  end

  -- Mark this buffer as ours so window_manager never mistakes a user's own
  -- :terminal for a Claude terminal window.
  if term_instance.buf then
    vim.b[term_instance.buf].claudecode_terminal = true
    vim.bo[term_instance.buf].filetype = "claudecode"
  end

  -- Track PID for cleanup on Neovim exit (with retry mechanism)
  -- Snacks.terminal.open() may not set terminal_job_id immediately
  if term_instance.buf then
    track_pid_with_retry(term_instance.buf, 5, 50)

    -- Set up BufUnload autocmd to ensure job is stopped when buffer is deleted
    -- This catches :bd!, Neovim exit, and any other buffer deletion path
    -- that bypasses close_session()
    vim.api.nvim_create_autocmd("BufUnload", {
      buffer = term_instance.buf,
      once = true,
      callback = function()
        local unload_ok, unload_job_id = pcall(vim.api.nvim_buf_get_var, term_instance.buf, "terminal_job_id")
        if unload_ok and unload_job_id then
          require("claudecode.terminal.process_cleanup").stop(unload_job_id, config.cleanup_strategy)
        end
      end,
    })
  end

  setup_terminal_events(term_instance, config, session_id)
  patch_instance(term_instance, config)

  -- Snacks enters its window on open; honor focus = false by stepping back.
  if not focus and vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_get_current_win() ~= original_win then
    vim.api.nvim_set_current_win(original_win)
  end

  return term_instance
end

---Wire a freshly created session instance into the session layer: session
---terminal info, buffer->session map, keymaps, OSC title watcher, tab bar.
---@param session_id string
---@param term_instance table
---@param config table
local function register_new_instance(session_id, term_instance, config)
  local terminal_module = require("claudecode.terminal")

  terminal_module.update_session_terminal_info(session_id, {
    bufnr = term_instance.buf,
    winid = term_instance.win,
  })

  -- Register buffer-to-session mapping for cleanup on BufUnload (Fix 1)
  terminal_module.register_buffer_session(term_instance.buf, session_id)

  -- Set up terminal keymaps (smart ESC, legacy exit key, split navigation).
  -- Called unconditionally, exactly as the native provider does: the function
  -- itself gates smart ESC on esc_timeout > 0, the legacy simple keymap on
  -- keymaps.exit_terminal, and split navigation on split_navigation, so with
  -- default config (esc_timeout = 0, keymaps.exit_terminal = false,
  -- split_navigation = false) it installs nothing. Snacks' own win.keys-based
  -- exit_terminal binding in build_opts (used only when esc_timeout <= 0) is
  -- untouched by this call.
  if term_instance.buf then
    terminal_module.setup_terminal_keymaps(term_instance.buf, config)
  end

  -- Set up scroll keymaps (scroll up to view scrollback by default)
  if term_instance.buf then
    terminal_module.setup_scroll_keymaps(term_instance.buf, config)
  end

  -- Setup OSC title handler
  if term_instance.buf then
    osc_handler.setup_buffer_handler(term_instance.buf, function(title)
      if title and title ~= "" then
        session_manager.update_session_name(session_id, title)
      end
    end)
  end

  -- Attach tabbar once the window has settled
  local winid = term_instance.win
  if winid then
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(winid) then
        local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
        if ok then
          tabbar.attach(winid, term_instance.buf, term_instance)
        end
      end
    end)
  end
end

function M.setup()
  -- No specific setup needed for Snacks provider
end

---Open a terminal using Snacks.nvim (legacy interface, active session)
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open(cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  focus = utils.normalize_focus(focus)

  if terminal and terminal:buf_valid() then
    -- Reuse the existing terminal. Route through cc_show so a hidden terminal is
    -- restored without Snacks destroying+recreating the window (which would climb
    -- Claude's cursor -- #240/#183). cc_show honors config.auto_insert (#232).
    park_others_in_current_tab(terminal)
    cc_show(terminal, focus, config)
    return
  end

  -- Ensure a session exists
  local session_id = session_manager.ensure_session()

  park_others_in_current_tab(nil)
  local term_instance = create_terminal_buffer(cmd_string, env_table, config, session_id, focus)
  if term_instance then
    terminal = term_instance
    terminals[session_id] = term_instance
    register_new_instance(session_id, term_instance, config)
  else
    terminal = nil
  end
end

---Close the terminal
function M.close()
  if not is_available() then
    return
  end
  if terminal and terminal:buf_valid() then
    terminal:close()
  end
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param config table
function M.simple_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")

  if terminal and terminal:buf_valid() then
    if cc_is_visible(terminal) then
      logger.debug("terminal", "Simple toggle: hiding visible terminal")
      cc_hide(terminal)
    else
      logger.debug("terminal", "Simple toggle: showing hidden terminal")
      cc_show(terminal, true, config)
    end
  else
    logger.debug("terminal", "Simple toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param config table
function M.focus_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")

  if terminal and terminal:buf_valid() then
    if not cc_is_visible(terminal) then
      -- Terminal exists but is hidden -> show and focus it.
      logger.debug("terminal", "Focus toggle: showing hidden terminal")
      cc_show(terminal, true, config)
    elseif terminal.win == vim.api.nvim_get_current_win() then
      -- You're IN it -> hide it.
      logger.debug("terminal", "Focus toggle: hiding terminal (currently focused)")
      cc_hide(terminal)
    else
      -- Visible but not focused -> focus it.
      logger.debug("terminal", "Focus toggle: focusing terminal")
      vim.api.nvim_set_current_win(terminal.win)
      maybe_start_insert(terminal, config)
    end
  else
    logger.debug("terminal", "Focus toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
  end
end

---Legacy toggle function for backward compatibility (defaults to simple_toggle)
---@param cmd_string string
---@param env_table table
---@param config table
function M.toggle(cmd_string, env_table, config)
  M.simple_toggle(cmd_string, env_table, config)
end

---Get the active terminal buffer number
---@return number?
function M.get_active_bufnr()
  if terminal and terminal:buf_valid() and terminal.buf then
    if vim.api.nvim_buf_is_valid(terminal.buf) then
      return terminal.buf
    end
  end
  return nil
end

---Is the terminal provider available?
---@return boolean
function M.is_available()
  return is_available()
end

---For testing purposes
---@return table? terminal The terminal instance, or nil
function M._get_terminal_for_test()
  return terminal
end

-- ============================================================================
-- Multi-session support functions
-- ============================================================================

---Open a terminal for a specific session. An existing session instance is
---unparked; a new one is created with its own Snacks window. Either way the
---other visible session instances in this tabpage are parked first.
---@param session_id string The session ID
---@param cmd_string string The command to run
---@param env_table table Environment variables
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param focus boolean? Whether to focus the terminal
function M.open_session(session_id, cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")
  focus = utils.normalize_focus(focus)

  -- Check if this session already has a terminal
  local existing_term = terminals[session_id]
  if existing_term and existing_term:buf_valid() then
    park_others_in_current_tab(existing_term)
    cc_show(existing_term, focus, config)
    terminal = existing_term
    attach_tabbar(existing_term)
    logger.debug("terminal", "Unparked existing terminal for session: " .. session_id)
    return
  end

  -- Park whatever is on screen in this tab before the new window opens, so a
  -- new split takes the parked one's place instead of halving it.
  park_others_in_current_tab(nil)

  local term_instance = create_terminal_buffer(cmd_string, env_table, config, session_id, focus)
  if term_instance then
    terminals[session_id] = term_instance
    terminal = term_instance -- Also set as legacy terminal
    register_new_instance(session_id, term_instance, config)
    logger.debug("terminal", "Opened terminal for session: " .. session_id)
  else
    logger.error("terminal", "Failed to open terminal for session: " .. session_id)
  end
end

---Close a terminal for a specific session
---@param session_id string The session ID
function M.close_session(session_id)
  if not is_available() then
    return
  end

  local term_instance = terminals[session_id]
  if term_instance and term_instance:buf_valid() then
    -- Mark as intentional close to suppress error message
    closing_sessions[session_id] = true

    -- Stop the job first to ensure the process is terminated
    if term_instance.buf then
      local ok, job_id = pcall(vim.api.nvim_buf_get_var, term_instance.buf, "terminal_job_id")
      if ok and job_id then
        require("claudecode.terminal.process_cleanup").stop(job_id, default_config.cleanup_strategy)
      end
    end

    -- Cleanup OSC handler
    if term_instance.buf then
      osc_handler.cleanup_buffer_handler(term_instance.buf)
    end

    -- Close its own window (visible or parked), then delete the buffer
    close_instance_window(term_instance)
    if term_instance.buf and vim.api.nvim_buf_is_valid(term_instance.buf) then
      vim.api.nvim_buf_delete(term_instance.buf, { force = true })
    end

    terminals[session_id] = nil

    -- If this was the legacy terminal, clear it too
    if terminal == term_instance then
      terminal = nil
    end
  end
end

---Close a session's terminal and switch to another session. Each Snacks
---instance owns its window, so "keep window" means the panel stays on screen:
---the old instance's window is closed with it and the new session's instance
---is unparked in its place.
---@param old_session_id string The session ID to close
---@param new_session_id string The session ID to switch to
---@param effective_config ClaudeCodeTerminalConfig Terminal configuration
function M.close_session_keep_window(old_session_id, new_session_id, effective_config)
  if not is_available() then
    return
  end

  local logger = require("claudecode.logger")

  local old_term = terminals[old_session_id]
  local new_term = terminals[new_session_id]

  -- Try to find the new session's terminal if not in terminals table
  if not new_term or not new_term:buf_valid() then
    local session_data = session_manager.get_session(new_session_id)
    if session_data and session_data.terminal_bufnr then
      if terminal and terminal:buf_valid() and terminal.buf == session_data.terminal_bufnr then
        new_term = terminal
        terminals[new_session_id] = new_term
        logger.debug("terminal", "Recovered legacy terminal for new session: " .. new_session_id)
      end
    end
  end

  -- Try to find old_term from legacy terminal
  if not old_term then
    local old_session_data = session_manager.get_session(old_session_id)
    if old_session_data and old_session_data.terminal_bufnr then
      if terminal and terminal:buf_valid() and terminal.buf == old_session_data.terminal_bufnr then
        old_term = terminal
        logger.debug("terminal", "Using legacy terminal as old_term for: " .. old_session_id)
      end
    end
    if not old_term then
      logger.debug("terminal", "No terminal found for old session: " .. old_session_id)
      return
    end
  end

  -- Mark as intentional close
  closing_sessions[old_session_id] = true

  -- Close the old instance's own window first so the new one takes its place.
  close_instance_window(old_term)

  if new_term and new_term:buf_valid() then
    park_others_in_current_tab(new_term)
    cc_show(new_term, true, effective_config)

    -- Update legacy terminal reference
    terminal = new_term
    attach_tabbar(new_term)
  else
    logger.warn("terminal", "No valid terminal found for new session: " .. new_session_id)
  end

  -- Stop the old job first to ensure the process is terminated
  if old_term and old_term:buf_valid() and old_term.buf then
    local ok, job_id = pcall(vim.api.nvim_buf_get_var, old_term.buf, "terminal_job_id")
    if ok and job_id then
      local strategy = (effective_config and effective_config.cleanup_strategy) or default_config.cleanup_strategy
      require("claudecode.terminal.process_cleanup").stop(job_id, strategy)
    end
  end

  -- Clean up old terminal's buffer
  if old_term and old_term:buf_valid() then
    if old_term.buf then
      osc_handler.cleanup_buffer_handler(old_term.buf)
    end
    if old_term.buf and vim.api.nvim_buf_is_valid(old_term.buf) then
      vim.api.nvim_buf_delete(old_term.buf, { force = true })
    end
  end

  terminals[old_session_id] = nil
  if terminal == old_term then
    terminal = nil
  end
  -- NOTE: Don't clear closing_sessions here - let TermClose handler do it
  -- If we clear it before TermClose fires, the handler thinks it's a crash
  -- and incorrectly closes the window

  logger.debug("terminal", "Closed session " .. old_session_id .. " and switched to " .. new_session_id)
end

---Focus a terminal for a specific session: park the other visible instances
---in this tabpage and unpark (show + focus) the target.
---@param session_id string The session ID
---@param config ClaudeCodeTerminalConfig|nil Terminal configuration for showing hidden terminal
function M.focus_session(session_id, config)
  if not is_available() then
    return
  end

  local logger = require("claudecode.logger")

  local term_instance = terminals[session_id]

  -- If not found in terminals table, try fallback to legacy terminal
  if not term_instance or not term_instance:buf_valid() then
    local session = session_manager.get_session(session_id)
    if
      session
      and session.terminal_bufnr
      and terminal
      and terminal:buf_valid()
      and terminal.buf == session.terminal_bufnr
    then
      logger.debug("terminal", "Registering legacy terminal for session: " .. session_id)
      M.register_terminal_for_session(session_id, terminal.buf)
      term_instance = terminals[session_id]
    end

    if not term_instance or not term_instance:buf_valid() then
      logger.debug("terminal", "Cannot focus invalid session: " .. session_id)
      return
    end
  end

  park_others_in_current_tab(term_instance)
  cc_show(term_instance, true, config or (term_instance._cc and term_instance._cc.config))

  -- Update legacy terminal reference
  terminal = term_instance
  attach_tabbar(term_instance)

  logger.debug("terminal", "Focused session: " .. session_id)
end

---Visible window of a session's instance, or nil when it is parked/closed.
---Lets the session layer toggle a provider that owns its windows without
---going through window_manager.
---@param session_id string The session ID
---@return number|nil winid
function M.get_session_window(session_id)
  local term_instance = terminals[session_id]
  if term_instance and term_instance:buf_valid() and cc_is_visible(term_instance) then
    return term_instance.win
  end
  return nil
end

---Park a session's instance (float config-hidden, split closed); the buffer
---and Claude process stay alive.
---@param session_id string The session ID
function M.hide_session(session_id)
  local term_instance = terminals[session_id]
  if term_instance and term_instance:buf_valid() then
    cc_hide(term_instance)
  end
end

---Get the buffer number for a session's terminal
---@param session_id string The session ID
---@return number|nil bufnr The buffer number or nil
function M.get_session_bufnr(session_id)
  local term_instance = terminals[session_id]
  if term_instance and term_instance:buf_valid() and term_instance.buf then
    return term_instance.buf
  end
  return nil
end

---Get all session IDs with active terminals
---@return string[] session_ids Array of session IDs
function M.get_active_session_ids()
  local ids = {}
  for session_id, term_instance in pairs(terminals) do
    if term_instance and term_instance:buf_valid() then
      table.insert(ids, session_id)
    end
  end
  return ids
end

---Register an existing terminal (from legacy path) with a session ID
---@param session_id string The session ID
---@param term_bufnr number|nil The buffer number (uses legacy terminal's bufnr if nil)
function M.register_terminal_for_session(session_id, term_bufnr)
  local logger = require("claudecode.logger")

  if not term_bufnr and terminal and terminal:buf_valid() then
    term_bufnr = terminal.buf
  end

  if not term_bufnr then
    logger.debug("terminal", "Cannot register nil terminal for session: " .. session_id)
    return
  end

  -- Check if already registered to another session
  for sid, term_instance in pairs(terminals) do
    if term_instance and term_instance:buf_valid() and term_instance.buf == term_bufnr and sid ~= session_id then
      logger.debug(
        "terminal",
        "Terminal already registered to session " .. sid .. ", not registering to " .. session_id
      )
      return
    end
  end

  -- Check if this session already has a different terminal
  local existing_term = terminals[session_id]
  if existing_term and existing_term:buf_valid() and existing_term.buf ~= term_bufnr then
    logger.debug("terminal", "Session " .. session_id .. " already has a different terminal")
    return
  end

  -- Register the legacy terminal with the session
  if terminal and terminal:buf_valid() and terminal.buf == term_bufnr then
    terminals[session_id] = terminal
    logger.debug("terminal", "Registered terminal (bufnr=" .. term_bufnr .. ") for session: " .. session_id)
  else
    logger.debug("terminal", "Cannot register: terminal bufnr mismatch for session: " .. session_id)
  end
end

---@type ClaudeCodeTerminalProvider
return M
