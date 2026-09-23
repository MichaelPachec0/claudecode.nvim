---Stops Claude terminal jobs and, optionally, their child processes.
---Shell wrappers such as fish do not forward SIGTERM to children, which is why
---the "pkill_children" strategy exists. vim.fn.system is never used here: it
---is synchronous and would stall Neovim while signals propagate. pkill is
---skipped entirely on Windows (vim.fn.has("win32") == 1), where it does not
---exist; jobstop is the only cleanup available there.
---
---Two entry points, with different ordering guarantees:
---  - M.stop (single job: M.close, close_session, close_session_keep_window,
---    BufUnload autocmds, external.lua M.close) runs the kill script as a
---    plain (non-detached) job and defers jobstop to that job's on_exit
---    callback. This guarantees the process group and children are signaled
---    BEFORE Neovim stops the shell job: if jobstop's TERM landed first, the
---    children would be reparented and "pkill -P <pid>" would find nothing,
---    orphaning exactly the processes pkill_children exists to catch. It
---    still never blocks Neovim's loop; only the eventual jobstop is delayed
---    until the async kill job reports it is done.
---  - M.stop_many (batch: cleanup_all / VimLeavePre / cleanup_orphaned_pids)
---    runs one DETACHED script for the whole batch and then jobstops every
---    job immediately, because on exit Neovim does not wait for callbacks:
---    the shell job needs to die together with the process, so there is no
---    "wait for on_exit" option there.
---@module 'claudecode.terminal.process_cleanup'
local M = {}

---@alias ClaudeCodeCleanupStrategy "jobstop_only"|"pkill_children"|"aggressive"|"none"

---True when `pid` is safe to interpolate into a shell command: a positive
---integer. Anything else (nil, a float, a string, zero, negative) is rejected
---so a malformed PID can never end up inside a string-concatenated command.
---@param pid any
---@return boolean
local function is_valid_pid(pid)
  return type(pid) == "number" and pid > 0 and pid == math.floor(pid)
end

---@return boolean
local function is_windows()
  local ok, result = pcall(vim.fn.has, "win32")
  return ok and result == 1
end

---Builds the shell script that terminates a batch of process trees for the
---given strategy. Only pre-validated positive-integer PIDs are ever
---interpolated. Used for both the single-job path (a one-PID list) and the
---batched exit path (many PIDs in one script).
---@param pids number[] Validated, positive-integer PIDs
---@param strategy "pkill_children"|"aggressive"
---@return string|nil script nil when there is nothing to run
local function build_kill_script(pids, strategy)
  if #pids == 0 then
    return nil
  end

  local cmds = {}
  if strategy == "pkill_children" then
    -- First pass: ask nicely (process group, direct children, the shell itself).
    for _, pid in ipairs(pids) do
      local p = string.format("%d", pid)
      table.insert(cmds, "kill -TERM -" .. p .. " 2>/dev/null")
      table.insert(cmds, "pkill -TERM -P " .. p .. " 2>/dev/null")
      table.insert(cmds, "kill -TERM " .. p .. " 2>/dev/null")
    end
    -- Give processes a moment to exit gracefully before the kill pass. The
    -- sleep runs inside the (possibly detached) shell job, not on Neovim's
    -- main loop.
    table.insert(cmds, "sleep 0.1")
    -- Second pass: guarantee termination of any survivors.
    for _, pid in ipairs(pids) do
      local p = string.format("%d", pid)
      table.insert(cmds, "kill -KILL -" .. p .. " 2>/dev/null")
      table.insert(cmds, "pkill -KILL -P " .. p .. " 2>/dev/null")
      table.insert(cmds, "kill -KILL " .. p .. " 2>/dev/null")
    end
  elseif strategy == "aggressive" then
    for _, pid in ipairs(pids) do
      local p = string.format("%d", pid)
      table.insert(cmds, "pkill -KILL -P " .. p .. " 2>/dev/null")
      table.insert(cmds, "kill -KILL " .. p .. " 2>/dev/null")
    end
  end

  if #cmds == 0 then
    return nil
  end
  return table.concat(cmds, "; ") .. "; true"
end

---Stops a single Claude terminal job and, depending on strategy, its child
---processes. Never blocks and never raises.
---@param job_id number|nil The Neovim job ID to stop
---@param strategy ClaudeCodeCleanupStrategy|nil Defaults to "pkill_children" (D3)
function M.stop(job_id, strategy)
  strategy = strategy or "pkill_children"
  if not job_id then
    return
  end
  if strategy == "none" then
    return
  end
  if strategy == "jobstop_only" or is_windows() then
    pcall(vim.fn.jobstop, job_id)
    return
  end

  -- strategy is "pkill_children" or "aggressive" and we are not on Windows.
  local jobpid_ok, pid = pcall(vim.fn.jobpid, job_id)
  local script = (jobpid_ok and is_valid_pid(pid)) and build_kill_script({ pid }, strategy) or nil

  if not script then
    -- No PID to signal (job already gone, jobpid failed, or nothing to
    -- run): fall back to the plain jobstop.
    pcall(vim.fn.jobstop, job_id)
    return
  end

  -- Run the kill script as a plain (non-detached) job and only jobstop the
  -- terminal job once it reports it is done, so the process group and
  -- children are always signaled before the shell itself is stopped.
  local start_ok, kill_job_id = pcall(vim.fn.jobstart, { "sh", "-c", script }, {
    on_exit = function()
      pcall(vim.fn.jobstop, job_id)
    end,
  })

  if not start_ok or not kill_job_id or kill_job_id <= 0 then
    -- jobstart failed outright: no on_exit will ever fire, so jobstop now.
    pcall(vim.fn.jobstop, job_id)
  end
end

---Stops many terminal jobs at once, e.g. on VimLeavePre / cleanup_all. Runs at
---most one detached shell job for the whole batch (never one per PID) so
---shutdown never blocks the UI, then jobstops each Neovim job individually.
---Unlike M.stop, this does not wait for the script to finish before
---jobstopping: on Neovim exit there is no event loop left to deliver an
---on_exit callback on, so the detached script and the jobstop race by
---design; it targets the process group and children directly (not just the
---shell's immediate children) so the outcome is the same either way.
---On Windows, or for strategies that do not use signals, only jobstop runs.
---@param entries { job_id: number, pid: number|nil }[]
---@param strategy ClaudeCodeCleanupStrategy|nil Defaults to "pkill_children" (D3)
function M.stop_many(entries, strategy)
  strategy = strategy or "pkill_children"
  entries = entries or {}

  if strategy == "none" then
    return
  end

  if (strategy == "pkill_children" or strategy == "aggressive") and not is_windows() then
    local pids = {}
    for _, entry in ipairs(entries) do
      if is_valid_pid(entry.pid) then
        table.insert(pids, entry.pid)
      end
    end
    local script = build_kill_script(pids, strategy)
    if script then
      pcall(vim.fn.jobstart, { "sh", "-c", script }, { detach = true })
    end
  end

  for _, entry in ipairs(entries) do
    pcall(vim.fn.jobstop, entry.job_id)
  end
end

return M
