---Integration tests for the ClaudeCodeConnected/ClaudeCodeDisconnected User
---autocmds. Starts the real WebSocket server in Neovim, connects a raw TCP
---client with a valid authenticated upgrade request, then hangs up.
---
---Under the plain busted + LuaJIT suite these are reported as pending. Run them
---inside Neovim with plenary.nvim on the runtimepath, from the repo root:
---  nvim --headless --clean -c "set rtp+=/path/to/plenary.nvim" -c "set rtp^=." \
---    -c "lua require('plenary.busted').run('tests/integration/connection_events_spec.lua')"

---True only inside a real Neovim process (not the busted vim mocks).
local function running_in_neovim()
  return type(vim) == "table"
    and type(vim.api) == "table"
    and type(vim.api.nvim_get_chan_info) == "function"
    and pcall(vim.api.nvim_get_chan_info, 0)
end

describe("connection events", function()
  if not running_in_neovim() then
    it("requires a real Neovim process", function()
      pending("starts the real WebSocket server; run inside Neovim with plenary (see file header)")
    end)
    return
  end

  local claudecode = require("claudecode")
  local lockfile = require("claudecode.lockfile")
  local saved_lock_dir = lockfile.lock_dir
  local events, autocmd_ids, sock

  before_each(function()
    -- Keep the lock file out of the user's real ~/.claude/ide.
    lockfile.lock_dir = vim.fn.tempname()
    claudecode.setup({ auto_start = false, log_level = "error" })
    assert.is_true(claudecode.start(false))

    events, autocmd_ids = {}, {}
    for _, name in ipairs({ "ClaudeCodeConnected", "ClaudeCodeDisconnected" }) do
      table.insert(
        autocmd_ids,
        vim.api.nvim_create_autocmd("User", {
          pattern = name,
          callback = function(ev)
            table.insert(events, { name = name, data = ev.data })
          end,
        })
      )
    end
  end)

  after_each(function()
    -- Connected/Disconnected are scheduled; deliver any pending one to this
    -- test's listeners before removing them, so it cannot leak into the next.
    vim.wait(100)
    for _, id in ipairs(autocmd_ids) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
    if sock and not sock:is_closing() then
      sock:close()
    end
    pcall(claudecode.stop)
    vim.fn.delete(lockfile.lock_dir, "rf")
    lockfile.lock_dir = saved_lock_dir
  end)

  ---Opens a TCP connection and sends an authenticated WebSocket upgrade.
  local function connect(auth_token)
    local uv = vim.uv or vim.loop
    sock = uv.new_tcp()
    local response = ""
    sock:connect("127.0.0.1", claudecode.state.port, function(err)
      assert(not err, err)
      sock:read_start(function(_, chunk)
        if chunk then
          response = response .. chunk
        end
      end)
      sock:write(table.concat({
        "GET / HTTP/1.1",
        "Host: 127.0.0.1:" .. claudecode.state.port,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. auth_token,
        "",
        "",
      }, "\r\n"))
    end)
    return function()
      return response
    end
  end

  it("fires Connected after an authenticated handshake and Disconnected on hang-up", function()
    local get_response = connect(claudecode.state.auth_token)

    assert.is_true(
      vim.wait(2000, function()
        return #events >= 1
      end, 20),
      "no ClaudeCodeConnected"
    )
    assert.is_true(
      vim.wait(1000, function()
        return get_response():find("101", 1, true) ~= nil
      end, 20),
      "no 101 Switching Protocols: " .. get_response()
    )
    assert.are.equal("ClaudeCodeConnected", events[1].name)
    local client_id = events[1].data.client_id
    assert.is_string(client_id)

    sock:close()

    assert.is_true(
      vim.wait(2000, function()
        return #events >= 2
      end, 20),
      "no ClaudeCodeDisconnected"
    )
    assert.are.equal("ClaudeCodeDisconnected", events[2].name)
    assert.are.equal(client_id, events[2].data.client_id)
  end)

  it("binds a session only to the authenticated client", function()
    local session_manager = require("claudecode.session")
    session_manager.reset()
    local sid = session_manager.create_session()

    -- A local process that opens a socket but fails auth (port scanner,
    -- dev-server discovery daemon) must not claim the waiting session.
    connect(string.rep("0", 32))
    vim.wait(300)
    sock:close()
    assert.is_nil(session_manager.get_session(sid).client_id, "unauthenticated client was bound")

    connect(claudecode.state.auth_token)
    assert.is_true(
      vim.wait(2000, function()
        return session_manager.get_session(sid).client_id ~= nil
      end, 20),
      "authenticated client was not bound"
    )
    session_manager.reset()
  end)

  it("does not fire Connected for a rejected token", function()
    connect(string.rep("0", 32))

    vim.wait(300)

    for _, ev in ipairs(events) do
      assert.are_not.equal("ClaudeCodeConnected", ev.name)
    end
  end)
end)
