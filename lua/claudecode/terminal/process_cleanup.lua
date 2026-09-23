---Stops Claude terminal jobs and, optionally, their child processes.
---Shell wrappers such as fish do not forward SIGTERM to children, which is why
---the "pkill_children" strategy exists; it runs pkill detached (via
---vim.fn.jobstart with detach = true) so the UI never blocks on process
---cleanup. vim.fn.system is never used here: it is synchronous and would
---stall Neovim while signals propagate. pkill is skipped entirely on Windows
---(vim.fn.has("win32") == 1), where it does not exist; jobstop is the only
---cleanup available there.
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

---Stops a single Claude terminal job and, depending on strategy, its child
---processes. Never blocks and never raises.
---@param job_id number|nil The Neovim job ID to stop
---@param strategy ClaudeCodeCleanupStrategy|nil Defaults to "pkill_children" (D3)
function M.stop(job_id, strategy)
  strategy = strategy or "pkill_children"
  if not job_id or strategy == "none" then
    return
  end
  if (strategy == "pkill_children" or strategy == "aggressive") and not is_windows() then
    local ok, pid = pcall(vim.fn.jobpid, job_id)
    if ok and is_valid_pid(pid) then
      local signal = strategy == "aggressive" and "-KILL" or "-TERM"
      pcall(vim.fn.jobstart, { "pkill", signal, "-P", string.format("%d", pid) }, { detach = true })
    end
  end
  pcall(vim.fn.jobstop, job_id)
end

---Builds the detached shell script that terminates a batch of process trees.
---Only pre-validated positive-integer PIDs are ever interpolated.
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
    -- sleep runs inside the detached shell job, not on Neovim's main loop.
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

---Stops many terminal jobs at once, e.g. on VimLeavePre / cleanup_all. Runs at
---most one detached shell job for the whole batch (never one per PID) so
---shutdown never blocks the UI, then jobstops each Neovim job individually.
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
