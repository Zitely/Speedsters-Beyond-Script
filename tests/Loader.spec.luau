-- scripts/test.py injects LOADER so tests execute the exact README loader.
local passed = 0
local function run(options)
    local compile = options.compile
    if compile == nil then compile = loadstring end
    local env = setmetatable({
        loadstring = compile,
        game = { HttpGet = function(_, url)
            assert(url == "https://raw.githubusercontent.com/Zitely/Speedsters-Beyond-Script/main/SpeedstersBeyond.lua")
            if options.downloadError then error(options.downloadError) end
            return options.source
        end },
    }, { __index = getfenv() })
    local chunk = assert(loadstring(LOADER, "Loader"))
    setfenv(chunk, env)
    return pcall(chunk)
end
local function rejects(name, options, expected)
    local ok, message = run(options)
    assert(not ok and string.find(tostring(message), expected, 1, true), tostring(message))
    assert(not string.find(tostring(message), "attempt to call a nil value", 1, true))
    passed = passed + 1
    print("PASS " .. name)
end
rejects("missing loadstring explains the runtime requirement", { compile = false }, "does not provide loadstring")
rejects("HTTP errors identify the unpublished file", { downloadError = "HTTP 404 (Not Found)" }, "download failed")
rejects("plain 404 response is not compiled", { source = "404: Not Found" }, "error page instead of Lua")
rejects("HTML response is not compiled", { source = "<!doctype html><html>404</html>" }, "error page instead of Lua")
rejects("blank response is rejected", { source = " \n  " }, "no script text")
rejects("non-string response is rejected", { source = {} }, "no script text")
rejects("compilation failure preserves its error", { source = "local = invalid" }, "did not compile")
rejects("runtime compilation exceptions are explained", { source = "return true", compile = function() error("compilation disabled") end }, "could not compile")
local ok, result = run({ source = "return 42" })
assert(ok and result == 42, tostring(result))
passed = passed + 1
print("PASS valid download compiles and executes")
rejects("hub startup error is preserved", { source = "error('game-specific startup failed')" }, "game-specific startup failed")
print(string.format("%d loader tests passed", passed))
