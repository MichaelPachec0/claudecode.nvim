---Integration tests for reloading file buffers after Claude's tool calls.
---Claude edits files on disk without MCP and then calls IDE tools; the server
---runs one debounced :checktime after such a burst so buffers are not stale.
---
---Under the plain busted + LuaJIT suite these are reported as pending. Run them
---inside Neovim with plenary.nvim on the runtimepath, from the repo root:
---  nvim --headless --clean -c "set rtp+=/path/to/plenary.nvim" -c "set rtp^=." \
---    -c "lua require('plenary.busted').run('tests/integration/buffer_refresh_spec.lua')"

---True only inside a real Neovim process (not the busted vim mocks).
local function running_in_neovim()
  return type(vim) == "table"
    and type(vim.api) == "table"
    and type(vim.api.nvim_get_chan_info) == "function"
    and pcall(vim.api.nvim_get_chan_info, 0)
end

describe("buffer refresh after tool calls", function()
  if not running_in_neovim() then
    it("requires a real Neovim process", function()
      pending("needs real buffers and :checktime; run inside Neovim with plenary (see file header)")
    end)
    return
  end

  local server = require("claudecode.server.init")
  local tools = require("claudecode.tools.init")
  local path, buf

  ---Calls the real tools/call handler the way a Claude client would.
  local function call_tool()
    server.state.handlers["tools/call"](nil, { name = "getWorkspaceFolders", arguments = {} })
  end

  ---Rewrites the file on disk with a later mtime, as Claude's Edit tool would.
  local function edit_on_disk(text)
    vim.fn.writefile({ text }, path)
    local later = os.time() + 5
    vim.loop.fs_utime(path, later, later)
  end

  before_each(function()
    tools.setup(server)
    server.register_handlers()
    path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "before" }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    vim.o.autoread = true
  end)

  after_each(function()
    vim.o.autoread = true
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    os.remove(path)
  end)

  it("reloads a buffer whose file Claude changed on disk", function()
    edit_on_disk("after")

    call_tool()

    assert.is_true(
      vim.wait(1000, function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "after"
      end, 20),
      "buffer still shows stale text"
    )
  end)

  it("leaves buffers alone when 'autoread' is off", function()
    vim.o.autoread = false
    edit_on_disk("after")

    call_tool()
    vim.wait(300)

    assert.are.equal("before", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1])
  end)

  it("runs one :checktime for a burst of tool calls", function()
    local count = 0
    local id = vim.api.nvim_create_autocmd("FileChangedShellPost", {
      callback = function()
        count = count + 1
      end,
    })
    local runs = 0
    local real_cmd = vim.cmd
    local cmd_stub = require("luassert.stub")(vim, "cmd", function(c, ...)
      if c == "checktime" then
        runs = runs + 1
      end
      return real_cmd(c, ...)
    end)

    edit_on_disk("after")
    for _ = 1, 5 do
      call_tool()
    end
    vim.wait(400)

    cmd_stub:revert()
    vim.api.nvim_del_autocmd(id)
    assert.are.equal(1, runs)
    assert.are.equal(1, count)
  end)
end)
