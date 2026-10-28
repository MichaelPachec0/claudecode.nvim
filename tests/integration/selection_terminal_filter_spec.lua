---Integration tests for which buffers selection tracking ignores: Claude's own
---terminals (b:claudecode_terminal, whatever terminal_cmd is called) and any
---terminal whose name matches terminal_filter_pattern.
---
---Under the plain busted + LuaJIT suite these are reported as pending. Run them
---inside Neovim with plenary.nvim on the runtimepath, from the repo root:
---  nvim --headless --clean -c "set rtp+=/path/to/plenary.nvim" -c "set rtp^=." \
---    -c "lua require('plenary.busted').run('tests/integration/selection_terminal_filter_spec.lua')"

---True only inside a real Neovim process (not the busted vim mocks).
local function running_in_neovim()
  return type(vim) == "table"
    and type(vim.api) == "table"
    and type(vim.api.nvim_get_chan_info) == "function"
    and pcall(vim.api.nvim_get_chan_info, 0)
end

describe("selection tracking terminal filter", function()
  if not running_in_neovim() then
    it("requires a real Neovim process", function()
      pending("needs real terminal buffers; run inside Neovim with plenary (see file header)")
    end)
    return
  end

  local selection = require("claudecode.selection")
  local sent, bufs

  local fake_server = {
    broadcast = function(method, params)
      table.insert(sent, { method = method, params = params })
    end,
  }

  ---Shows a terminal buffer named `name` (running `sh`) in the current window.
  local function open_terminal(name, claude_flag)
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    vim.fn.termopen({ "sh" })
    if name then
      vim.api.nvim_buf_set_name(buf, name)
    end
    if claude_flag then
      vim.b[buf].claudecode_terminal = true
    end
    table.insert(bufs, buf)
    return buf
  end

  local function start(pattern)
    selection.disable()
    selection.state.latest_selection = nil
    selection.enable(fake_server, 50, pattern)
  end

  before_each(function()
    sent, bufs = {}, {}
  end)

  after_each(function()
    selection.disable()
    for _, buf in ipairs(bufs) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end)

  it("ignores Claude's own terminal even when its name has no 'claude' in it", function()
    start("^term://.*claude")
    -- Explicit name: the default one embeds the cwd, which may itself contain "claude".
    open_terminal("term://~//4241:sh", true) -- as with terminal_cmd = "sh"

    selection.update_selection()

    assert.are.same({}, sent)
  end)

  it("ignores another plugin's terminal whose name matches the pattern", function()
    start("^term://.*claude")
    open_terminal("term://~//4242:claude --continue", false)

    selection.update_selection()

    assert.are.same({}, sent)
  end)

  it("honors a custom pattern and tracks terminals that do not match it", function()
    start("sidekick")
    open_terminal("term://~//4243:sidekick-agent", false)
    selection.update_selection()
    assert.are.same({}, sent)

    open_terminal("term://~//4244:htop", false)
    selection.update_selection()
    assert.are.equal(1, #sent)
    assert.are.equal("selection_changed", sent[1].method)
  end)
end)
