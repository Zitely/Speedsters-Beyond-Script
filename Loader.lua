local url = "https://raw.githubusercontent.com/Zitely/Speedsters-Beyond-Script/main/SpeedstersBeyond.lua"

if type(loadstring) ~= "function" then
    error("Speedsters Beyond: this runtime does not provide loadstring. In Studio, use the full SpeedstersBeyond.lua source in a LocalScript under StarterPlayerScripts, then Play.", 0)
end

local downloaded, source = pcall(function()
    return game:HttpGet(url)
end)
if not downloaded then
    error("Speedsters Beyond: download failed. Publish SpeedstersBeyond.lua to GitHub main before using this loader. Details: " .. tostring(source), 0)
end
if type(source) ~= "string" or not string.find(source, "%S") then
    error("Speedsters Beyond: the download returned no script text.", 0)
end
if string.match(source, "^%s*404") or string.match(source, "^%s*<[!%a]") then
    error("Speedsters Beyond: the URL returned an error page instead of Lua. Publish SpeedstersBeyond.lua to GitHub main, or run the full script directly.", 0)
end

local compiled, chunk, compileError = pcall(loadstring, source, "SpeedstersBeyond")
if not compiled then
    error("Speedsters Beyond: the runtime could not compile the download. Details: " .. tostring(chunk), 0)
end
if type(chunk) ~= "function" then
    error("Speedsters Beyond: the downloaded script did not compile. Details: " .. tostring(compileError), 0)
end
return chunk()
