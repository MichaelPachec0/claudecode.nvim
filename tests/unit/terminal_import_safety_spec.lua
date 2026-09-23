require("tests.busted_setup")

describe("terminal layer import safety", function()
  local saved
  local saved_loaded

  before_each(function()
    saved = _G.vim
    saved_loaded = {}
    for name, mod in pairs(package.loaded) do
      saved_loaded[name] = mod
    end
    -- Deliberately minimal: requiring a module must not touch vim.api/vim.loop.
    _G.vim = { log = { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } } }
    for _, m in ipairs({ "claudecode.terminal", "claudecode.session", "claudecode.tab_registry" }) do
      package.loaded[m] = nil
    end
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }
  end)

  after_each(function()
    _G.vim = saved
    -- Drop every module loaded against the stub vim so later specs do not
    -- inherit module-level state captured from it, then restore the originals.
    for name in pairs(package.loaded) do
      if saved_loaded[name] == nil then
        package.loaded[name] = nil
      end
    end
    for name, mod in pairs(saved_loaded) do
      package.loaded[name] = mod
    end
  end)

  for _, m in ipairs({ "claudecode.session", "claudecode.tab_registry", "claudecode.terminal" }) do
    it("requires " .. m .. " without touching vim.api or vim.loop", function()
      assert.has_no.errors(function()
        require(m)
      end)
    end)
  end
end)
