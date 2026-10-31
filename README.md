# Speedsters Beyond

```lua
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
```

Use the whole loader block above; it reports missing runtime functions, download errors, and compilation errors separately.

The loader requires `SpeedstersBeyond.lua` to be published on this repository's `main` branch and a Roblox client runtime with `loadstring` and `game:HttpGet`. The download is not available until that file is pushed to `main`.

To run before publishing, copy the full `SpeedstersBeyond.lua` file into your client script runner. For UI testing in your own Studio place, paste the full file into a `LocalScript` under `StarterPlayer > StarterPlayerScripts` and start Play. The game-specific automation needs the actual game objects and remotes. Enabling server-side `LoadStringEnabled` does not enable `loadstring` for LocalScripts.

A dark, mint-accented control center with desktop sidebar navigation, compact mobile tabs, touch dragging, live feature status, and a session activity feed. No external UI libraries or asset downloads.

- **Training:** choose a discovered treadmill; charge and burst are spaced. Nearby orb collection selects the closest detected orb within 80 studs and avoids immediately retrying the same object.
- **Jobs:** selects the highest-reward tier unlocked by your ascensions, waits for acceptance, then separates travel, arrival, banked payout collection, and confirmation. Existing deliveries resume without another claim. A missing destination after arrival no longer skips collection or immediately returns you to the board.
- **Tools:** repeat race reset, auto ascend, Speed / Jump purchases, and idle prevention.
- **Reliability:** one movement mode at a time; missing characters, remotes, and targets show retry messages with backoff. Respawns reacquire targets. Reloading replaces the previous session and closes its connections.

Use **Right Shift** or **−** to hide the panel; the floating **SB / Open** button restores it. Drag that minimized button with mouse or touch to reposition it; releasing a drag keeps the panel minimized. Its position is clamped to the screen, including after rotation. Automation continues while hidden. **Stop all** disables every toggle, including idle prevention. **×** unloads the UI and its automation. Movement, purchasing, race resets, and ascension start off; idle prevention starts on.

## Behavior and limits

Selection uses the following reward and eligibility details supplied from the game's `JobsConfig` and `JobRewards`. Equal rewards prefer the tier with the lower ascension requirement (Hard over City Express). This is a supplied configuration snapshot, not live server introspection.

| Job | Tier | Type | Reward | Ascensions required |
| --- | ---: | ---: | ---: | ---: |
| Extreme | 4 | 1 | 40,000 | 75 |
| Ancient Crystal | 10 | 2 | 25,000 | 50 |
| Long-Haul Cargo | 7 | 1 | 18,000 | 30 |
| Crystal Core | 9 | 2 | 14,000 | 25 |
| Hard | 3 | 1 | 10,000 | 10 |
| City Express | 6 | 1 | 10,000 | 12 |
| Crystal Shards | 8 | 2 | 6,000 | 8 |
| Medium | 2 | 1 | 5,000 | 4 |
| Supply Rush | 5 | 1 | 4,000 | 3 |
| Easy | 1 | 1 | 1,000 | 0 |

The Jobs page shows the ascension count and selected tier. Automatic detection reads player attributes or numeric stat ValueObjects named `Ascensions` / `Ascension`. Unknown or conflicting counts pause claims instead of assuming zero and choosing Easy. If your version of the game stores this elsewhere, enter your actual count and press **Use count**; **Use automatic detection** clears that override. Keep manual counts current. Overrides reset when the hub reloads.

Only one claim is sent. If acceptance is not observed within 12 seconds, the controller keeps waiting and never silently downgrades; toggle Auto Jobs off/on to retry. During delivery, the destination is retained through arrival so native arrival handling can clear it without skipping payout collection. After collection, the destination must remain absent for three seconds before returning to the board. Arrival/collection retries are limited to two extra attempts if the destination remains active.

Requests are not proof of server acceptance or payment. The delivery counter records a stable cleared destination after a collection request. Game updates may change the configuration or remote behavior; live in-game validation is still required.

Race reset and ascension pause while jobs control movement. **Repeat race reset** only calls `ResetRace`; it does not finish a race. **Auto buy upgrades** requests both Speed and Jump purchases and can spend available currency. Orb detection uses BasePart names containing `orb`, matching the supplied script's convention. Streaming and game updates may change what is available. Idle input depends on runtime support.

## Development

- `src/Core.luau`: movement arbitration, cooldowns, retries, and the job state machine.
- `src/Hub.luau`: Roblox adapter, session cleanup, and responsive UI.
- `SpeedstersBeyond.lua`: generated, self-contained loader target. Commit the rebuilt file alongside source changes.

With Python 3 and the [Luau CLI](https://github.com/luau-lang/luau) on your path (validated with Luau 0.727):

```sh
python3 scripts/build.py
python3 scripts/test.py
luau-compile SpeedstersBeyond.lua > /dev/null
```

If Luau is installed elsewhere, run `LUAU_BIN=/path/to/luau python3 scripts/test.py`. The tests check controller behavior and run the actual bundle against a small Roblox API double. They do not render Roblox UI or validate the live game's server behavior.

In-game checks still required: inspect desktop/mobile layout, train through a respawn, collect a real orb, verify a complete paid delivery, confirm upgrade purchases and ascension, and reload/close the hub while a mode is enabled. Check feature status and the Home activity feed when a game API is unavailable.
