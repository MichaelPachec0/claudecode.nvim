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
    it("jobstop_only never spawns pkill", function()
      cleanup.stop(7, "jobstop_only")
      assert.spy(vim.fn.jobstop).was_called_with(7)
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.system).was_not_called()
    end)

    it("pkill_children spawns pkill asynchronously, never vim.fn.system", function()
      cleanup.stop(7, "pkill_children")
      assert.spy(vim.fn.jobstart).was_called_with({ "pkill", "-TERM", "-P", "4242" }, { detach = true })
      assert.spy(vim.fn.system).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("aggressive spawns pkill -KILL asynchronously", function()
      cleanup.stop(7, "aggressive")
      assert.spy(vim.fn.jobstart).was_called_with({ "pkill", "-KILL", "-P", "4242" }, { detach = true })
      assert.spy(vim.fn.system).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("skips pkill on Windows", function()
      _G.__win32 = true
      cleanup.stop(7, "pkill_children")
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("defaults to pkill_children when strategy is nil", function()
      cleanup.stop(7, nil)
      assert.spy(vim.fn.jobstart).was_called_with({ "pkill", "-TERM", "-P", "4242" }, { detach = true })
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

    it("does not spawn pkill when jobpid is invalid", function()
      vim.fn.jobpid = function()
        return 0
      end
      cleanup.stop(7, "pkill_children")
      assert.spy(vim.fn.jobstart).was_not_called()
      assert.spy(vim.fn.jobstop).was_called_with(7)
    end)

    it("never raises when jobpid errors", function()
      vim.fn.jobpid = function()
        error("no such job")
      end
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
