---Tests for lockfile.build_ide_name: the label the Claude CLI shows in /ide.
require("tests.busted_setup")

describe("lockfile.build_ide_name", function()
  local lockfile
  local saved_vim, getenv_stub
  local env, system_calls, system_result, shell_error

  before_each(function()
    saved_vim = _G.vim
    env, system_calls, system_result, shell_error = {}, {}, "", 0
    getenv_stub = require("luassert.stub")(os, "getenv", function(key)
      return env[key]
    end)
    _G.vim = {
      v = setmetatable({}, {
        __index = function(_, k)
          if k == "shell_error" then
            return shell_error
          end
        end,
      }),
      trim = function(s)
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
      end,
      list_extend = function(dst, src)
        for _, v in ipairs(src) do
          table.insert(dst, v)
        end
        return dst
      end,
      fn = {
        expand = function(p)
          return p
        end,
        getcwd = function()
          return "/home/u/code/proj"
        end,
        fnamemodify = function(p, mods)
          assert(mods == ":~")
          return (p:gsub("^/home/u", "~"))
        end,
        system = function(cmd)
          table.insert(system_calls, cmd)
          return system_result
        end,
      },
    }
    package.loaded["claudecode.lockfile"] = nil
    lockfile = require("claudecode.lockfile")
  end)

  after_each(function()
    _G.vim = saved_vim
    getenv_stub:revert()
    package.loaded["claudecode.lockfile"] = nil
  end)

  it("keeps the upstream label by default", function()
    env.TMUX = "/tmp/tmux-1000/default,1,0"
    assert.are.equal("Neovim", lockfile.build_ide_name(nil))
    assert.are.equal("Neovim", lockfile.build_ide_name({}))
    assert.are.equal(0, #system_calls, "no tmux call unless context is on")
  end)

  it("uses a non-empty override verbatim", function()
    assert.are.equal("Work box", lockfile.build_ide_name({ override = "Work box", context = true }))
    assert.are.equal("Neovim", lockfile.build_ide_name({ override = "" }))
  end)

  it("appends the working directory outside tmux", function()
    assert.are.equal("Neovim [~/code/proj]", lockfile.build_ide_name({ context = true }))
  end)

  it("asks tmux about Neovim's own pane, in one call", function()
    env.TMUX, env.TMUX_PANE = "/tmp/tmux-1000/default,1,0", "%7"
    system_result = "dev:editor\n"

    assert.are.equal("Neovim [tmux:dev:editor]", lockfile.build_ide_name({ context = true }))
    assert.are.same({ { "tmux", "display-message", "-p", "-t", "%7", "#S:#W" } }, system_calls)
  end)

  it("includes the pane index when asked", function()
    env.TMUX, env.TMUX_PANE = "/tmp/tmux-1000/default,1,0", "%7"
    system_result = "dev:editor:2\n"

    assert.are.equal(
      "Neovim [tmux:dev:editor:2]",
      lockfile.build_ide_name({ context = true, tmux_include_pane = true })
    )
    assert.are.equal("#S:#W:#P", system_calls[1][#system_calls[1]])
  end)

  it("falls back to the working directory when tmux fails", function()
    env.TMUX = "/tmp/tmux-1000/default,1,0"
    shell_error = 1
    system_result = "no server running"

    assert.are.equal("Neovim [~/code/proj]", lockfile.build_ide_name({ context = true }))
  end)
end)
