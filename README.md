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
- **Jobs:** fills up to four unlocked slots with the highest-paying eligible tier, confirms each accepted leg, delivers the chain, uses Return to Spawn, collects at the NPC, and repeats. Existing chains resume from server progress. Movement and request recovery run automatically.
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

Enable **Auto job & deliver** once to run the loop. Chain capacity follows the supplied `CHAIN_SLOT_ASCENSIONS`: two slots initially, three at 10 ascensions, and four at 25. Each slot requests the highest-paying eligible tier. The first request uses `ClaimJob(tierIndex, jobType)`; appending in `claimed` uses the supplied `ClaimJob(tierIndex)` call. The accepted leg count must increase before another slot is requested. A delayed claim triggers a fresh snapshot after 12 seconds; an unchanged count is retried after another three seconds, without switching to an easier tier.

The adapter reads the supplied public `GetLegCount`, `GetPhase`, `GetBankedCount`, `HasDeliveredCurrent`, and `GetDropPoint` methods. `GetJobsSnapshot` initializes or refreshes the current leg index, and `JobsStateChanged` keeps it current. Public counts must agree with the snapshot before acting. A late snapshot response cannot overwrite an event received while that request was pending. Missing or incompatible APIs produce an automatic retry status rather than guessed progress.

After filling the unlocked slots, the character leaves the board and follows the current running leg. Each new leg index resets arrival tracking, even if two legs share the same marker coordinates. A temporarily missing marker waits for the next server state; it does not trigger collection or a new claim. Arrival reports require 1.5 seconds inside the supplied 50-stud radius and are spaced three seconds apart. After five unacknowledged attempts, the hub waits ten seconds, approaches closer, and starts another attempt cycle automatically.

When the last leg is complete and rewards are banked, the hub calls the supplied `ReturnToSpawn` RemoteEvent if the board is more than 200 studs away. Accepted chains survive this action according to the supplied game implementation. The hub waits for displacement, then approaches within 10 studs of the board before calling `CollectJob`. If the return request shows no displacement within five seconds, board travel resumes. After a stalled trip, route recovery starts from the character’s current position once the return wait finishes, so a retry cannot cancel its own fallback route. Short trips approach the NPC directly. The banked count must decrease before deliveries are counted; an unchanged payout request is refreshed and retried with a delay of 10–30 seconds. The next chain starts automatically.

Travel uses `Humanoid:Move(direction, false)` at render priority `Input` (100), before the supplied `SpeedstersMovement` step at `Input + 1` (101). Default `PlayerModule` controls are temporarily disabled during steering. Zero direction input lets the game's world-movement logic brake near markers. Delivery travel requires `RunWorld`; board travel and departure also allow `Main`, so returning to spawn can lead back to the board. The driver leaves the game's movement binding, velocities, `PlayerState`, and race-only `SetSpeedHold` unchanged.

If travel makes no progress for 12 seconds, it retries automatically after a cooldown that grows from three to 30 seconds. Recovery uses Roblox pathfinding in local segments up to 192 studs, follows waypoints, and issues normal jump input when a waypoint calls for it. Blocked, failed, and timed-out routes are recomputed. Pathfinding still depends on the game's walkable geometry, streaming, and movement rules; it cannot guarantee a route through every map condition. Arrival recovery aims within eight studs rather than the normal 35-stud stopping margin.

**Stop all**, switching away from Jobs, closing, and reloading cancel steering and pending routes and restore player controls. Respawns re-read server progress. Controls already disabled by the game are not taken over. The Jobs page shows accepted slots and banked jobs; status messages show automatic retries. No manual restart is required for travel, claim, arrival, or payout retries with the supplied APIs available.

Requests alone do not prove acceptance or payment. The session counter records banked jobs cleared after a collection request, not a currency balance audit. The game API and configuration details above were supplied by the user; the full loop still needs live-game validation.

Race reset and ascension pause while jobs control movement. **Repeat race reset** only calls `ResetRace`; it does not finish a race. **Auto buy upgrades** requests both Speed and Jump purchases and can spend available currency. Orb detection uses BasePart names containing `orb`, matching the supplied script's convention. Streaming and game updates may change what is available. Idle input depends on runtime support.

## Development

- `src/Core.luau`: movement arbitration, cooldowns, retries, and the job state machine.
- `src/Movement.luau`: horizontal steering and predictive braking using normal movement input.
- `src/Hub.luau`: Roblox adapter, session cleanup, and responsive UI.
- `SpeedstersBeyond.lua`: generated, self-contained loader target. Commit the rebuilt file alongside source changes.

With Python 3 and the [Luau CLI](https://github.com/luau-lang/luau) on your path (validated with Luau 0.727):

```sh
python3 scripts/build.py
python3 scripts/test.py
luau-compile SpeedstersBeyond.lua > /dev/null
```

If Luau is installed elsewhere, run `LUAU_BIN=/path/to/luau python3 scripts/test.py`. The tests check controller behavior and run the actual bundle against a small Roblox API double. The tests include a simulated 50,000-stud trip at 30, 60, and 144 FPS and two complete four-job chains without manual movement. They verify slot limits, claim acknowledgements, successive legs, Return to Spawn, NPC collection, automatic retries, snapshot ordering, route cancellation, and control restoration. They do not render Roblox UI or validate the full movement controller, map collisions, or live server acceptance.

In-game checks still required: inspect desktop/mobile layout, train through a respawn, collect a real orb, verify a complete paid delivery, confirm upgrade purchases and ascension, and reload/close the hub while a mode is enabled. Check feature status and the Home activity feed when a game API is unavailable.
