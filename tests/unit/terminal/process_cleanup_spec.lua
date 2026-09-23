describe("claudecode.terminal.process_cleanup", function()
  local cleanup
  local spy
  local original_vim

  before_each(function()
    original_vim = _G.vim
    spy = require("luassert.spy")

    _G.vim = {
      fn = {
        has = function(f)
          return (f == "win32" and _G.__win32) and 1 or 0
        end,
        jobpid = function()
          return 4242
        end,
        jobstop = spy.new(function() end),
        jobstart = spy.new(function()
          return 1
        end),
        system = spy.new(function() end),
      },
    }
    package.loaded["claudecode.terminal.process_cleanup"] = nil
    cleanup = require("claudecode.terminal.process_cleanup")
  end)

  after_each(function()
    _G.vim = original_vim
    _G.__win32 = nil
    package.loaded["claudecode.terminal.process_cleanup"] = nil
  end)

  describe("stop", function()
    ---Extracts the {cmd, opts} pair from the Nth jobstart call.
    local function jobstart_call(n)
      local call = vim.fn.jobstart.calls[n or 1]
      return call.vals[1], call.vals[2]
    end

    it("jobstop_only never spawns pkill", function()
      cleanup.stop(7, "jobstop_only")
      assert.spy(vim.fn.jobstop).was_called_with(7)
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.system).was_not_called()
    end)

    it("pkill_children runs the script as a plain job, deferring jobstop to on_exit", function()
      cleanup.stop(7, "pkill_children")

      assert.spy(vim.fn.jobstart).was_called(1)
      local cmd, opts = jobstart_call()
      assert.are.equal("sh", cmd[1])
      assert.are.equal("-c", cmd[2])
      local script = cmd[3]
      -- Process group, direct children, and the shell itself, all signaled
      -- before jobstop is ever called.
      assert.truthy(script:match("kill %-TERM %-4242"))
      assert.truthy(script:match("pkill %-TERM %-P 4242"))
      assert.truthy(script:match("kill %-TERM 4242"))
      assert.is_nil(opts.detach)
      assert.is_function(opts.on_exit)
      assert.spy(vim.fn.system).was_not_called()

      -- The ordering fix: jobstop must NOT have fired yet.
      assert.spy(vim.fn.jobstop).was_not_called()

      -- Once the kill script reports it is done, jobstop runs.
      opts.on_exit()
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("aggressive runs a KILL-only script and defers jobstop to on_exit", function()
      cleanup.stop(7, "aggressive")

      local cmd, opts = jobstart_call()
      local script = cmd[3]
      assert.truthy(script:match("pkill %-KILL %-P 4242"))
      assert.truthy(script:match("kill %-KILL 4242"))
      assert.is_nil(opts.detach)
      assert.spy(vim.fn.system).was_not_called()
      assert.spy(vim.fn.jobstop).was_not_called()

      opts.on_exit()
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("skips pkill on Windows and jobstops immediately", function()
      _G.__win32 = true
      cleanup.stop(7, "pkill_children")
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("defaults to pkill_children when strategy is nil", function()
      cleanup.stop(7, nil)
      local cmd = jobstart_call()
      assert.are.equal("sh", cmd[1])
      assert.truthy(cmd[3]:match("pkill %-TERM %-P 4242"))
      assert.spy(vim.fn.jobstop).was_not_called()
    end)

    it("none does nothing", function()
      cleanup.stop(7, "none")
      assert.spy(vim.fn.jobstop).was_not_called()
      assert.spy(vim.fn.jobstart).was_not_called()
    end)

    it("does nothing without a job_id", function()
      cleanup.stop(nil, "pkill_children")
      assert.spy(vim.fn.jobstop).was_not_called()
      assert.spy(vim.fn.jobstart).was_not_called()
    end)

    it("does not spawn pkill when jobpid is invalid, jobstops immediately", function()
      vim.fn.jobpid = function()
        return 0
      end
      cleanup.stop(7, "pkill_children")
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("never raises when jobpid errors, jobstops immediately", function()
      vim.fn.jobpid = function()
        error("no such job")
      end
      assert.has_no.errors(function()
        cleanup.stop(7, "pkill_children")
      end)
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("jobstart returning a non-positive job id falls back to an immediate jobstop", function()
      vim.fn.jobstart = spy.new(function()
        return 0
      end)
      cleanup.stop(7, "pkill_children")
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("jobstart raising an error falls back to an immediate jobstop", function()
      vim.fn.jobstart = spy.new(function()
        error("jobstart failed")
      end)
      assert.has_no.errors(function()
        cleanup.stop(7, "pkill_children")
      end)
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)
  end)

  describe("stop_many", function()
    it("runs exactly one detached script for a batch of pkill_children entries", function()
      cleanup.stop_many({
        { job_id = 1, pid = 100 },
        { job_id = 2, pid = 200 },
      }, "pkill_children")

      assert.spy(vim.fn.jobstart).was_called(1)
      local args = vim.fn.jobstart.calls[1].vals
      assert.are.equal("sh", args[1][1])
      assert.are.equal("-c", args[1][2])
      local script = args[1][3]
      assert.truthy(script:match("pkill %-TERM %-P 100"))
      assert.truthy(script:match("pkill %-TERM %-P 200"))
      assert.are.same({ detach = true }, args[2])
      assert.spy(vim.fn.system).was_not_called()

      assert.spy(vim.fn.jobstop).was_called_with(1)
      assert.spy(vim.fn.jobstop).was_called_with(2)
    end)

    it("uses SIGKILL only for the aggressive strategy", function()
      cleanup.stop_many({ { job_id = 1, pid = 100 } }, "aggressive")
      local script = vim.fn.jobstart.calls[1].vals[1][3]
      assert.truthy(script:match("KILL"))
      assert.falsy(script:match("TERM"))
    end)

    it("jobstop_only never spawns a script", function()
      cleanup.stop_many({ { job_id = 1, pid = 100 } }, "jobstop_only")
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(1)
    end)

    it("none does not jobstop or spawn a script", function()
      cleanup.stop_many({ { job_id = 1, pid = 100 } }, "none")
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.jobstop).was_not_called()
    end)

    it("skips the script on Windows but still jobstops", function()
      _G.__win32 = true
      cleanup.stop_many({ { job_id = 1, pid = 100 } }, "pkill_children")
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(1)
    end)

    it("rejects non-integer and non-positive PIDs from the script", function()
      cleanup.stop_many({
        { job_id = 1, pid = 100 },
        { job_id = 2, pid = -5 },
        { job_id = 3, pid = 1.5 },
        { job_id = 4, pid = "100" },
        { job_id = 5, pid = nil },
      }, "pkill_children")

      local script = vim.fn.jobstart.calls[1].vals[1][3]
      assert.truthy(script:match("%-P 100"))
      assert.falsy(script:match("%-P %-5"))
      assert.falsy(script:match("%-P 1%.5"))
      assert.spy(vim.fn.jobstop).was_called(5)
    end)

    it("spawns nothing when there are no valid PIDs, still jobstops", function()
      cleanup.stop_many({ { job_id = 1, pid = nil } }, "pkill_children")
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(1)
    end)

    it("defaults to pkill_children when strategy is nil", function()
      cleanup.stop_many({ { job_id = 1, pid = 100 } }, nil)
      assert.spy(vim.fn.jobstart).was_called(1)
    end)
  end)
end)
