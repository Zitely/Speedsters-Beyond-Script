local Core = require("../src/Core")
local passed = 0
local function equal(actual, expected, message)
    assert(actual == expected, (message or "Mismatch") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function test(name, body)
    body()
    passed = passed + 1
    print("PASS " .. name)
end
local function fixture()
    local calls = {}
    local state = { phase = "idle", legCount = 0, banked = 0, index = 0, delivered = false, revision = 1, ascensions = 10, distance = 3, atBoard = true }
    local adapter = {}
    for _, name in ipairs({ "moveToTreadmill", "chargeStart", "chargeBurst", "moveToBoard", "claimJob", "appendJob", "returnToSpawn", "moveToDrop", "reportArrival", "collectJob", "stopDeliveryMovement", "recoverJobMovement", "resetRace", "ascend", "buyUpgrades" }) do
        adapter[name] = function(...) table.insert(calls, { name = name, args = { ... } }) end
    end
    adapter.getDropDistance = function() return state.distance end
    adapter.getAscensions = function() return state.ascensions end
    adapter.getJobState = function() return table.clone(state) end
    adapter.getPlayerState = function() return state.playerState or "RunWorld" end
    adapter.isAtBoard = function() return state.atBoard end
    adapter.sameDropPoint = function(first, second) return first == second end
    adapter.shouldReturnToSpawn = function() return state.spawnNeeded == true end
    adapter.hasReturnedToSpawn = function() return state.returned == true end
    adapter.refreshJobState = function()
        table.insert(calls, { name = "refreshJobState", args = {} })
        state.revision += 1
    end
    adapter.collectNearestOrb = function() table.insert(calls, { name = "orb" }); return state.orb end
    local engine = Core.new(adapter)
    local function count(name)
        local total = 0
        for _, call in ipairs(calls) do if call.name == name then total = total + 1 end end
        return total
    end
    return engine, state, calls, count, adapter
end

local function advance(engine, first, last)
    for time = first, last, 0.5 do engine:tick(time) end
end

test("defaults produce no remote requests", function()
    local e, _, calls = fixture()
    e:tick(100)
    equal(#calls, 0)
    equal(e.enabled.antiIdle, true)
end)
test("switching from farm to jobs never deadlocks", function()
    local e, _, _, count = fixture()
    e:setMode("farm"); e:tick(0)
    e:setMode("jobs"); e:tick(0.1); e:tick(1)
    equal(count("chargeStart"), 1)
    equal(count("chargeBurst"), 0)
    equal(count("claimJob"), 1)
    equal(e.mode, "jobs")
end)
test("orbs exclusively own movement after a switch", function()
    local e, state, _, count = fixture()
    state.orb = true
    e:setMode("farm"); e:tick(0)
    e:setMode("orbs"); e:tick(0.1); e:tick(1)
    equal(count("chargeBurst"), 0)
    equal(count("orb"), 2)
    equal(e.orbRequests, 2)
end)
test("charge and burst are spaced; disabled modes stop", function()
    local e, _, _, count = fixture()
    e:setMode("farm"); e:tick(0); e:tick(0.1)
    equal(count("chargeBurst"), 0)
    e:tick(0.5)
    equal(count("chargeBurst"), 1)
    e:setMode(nil); e:tick(100)
    equal(count("chargeStart"), 1)
end)
test("new treadmill choice reaches the adapter", function()
    local e, _, calls = fixture()
    e.treadmill = "x20"
    e:setMode("farm"); e:tick(0)
    equal(calls[1].args[1], "x20")
end)
test("highest reward is selected from eligible jobs at every unlock boundary", function()
    local cases = { {0, 1, 1}, {2, 1, 1}, {3, 5, 1}, {4, 2, 1}, {7, 2, 1},
        {8, 8, 2}, {9, 8, 2}, {10, 3, 1}, {12, 3, 1}, {24, 3, 1}, {25, 9, 2},
        {29, 9, 2}, {30, 7, 1}, {49, 7, 1}, {50, 10, 2}, {74, 10, 2}, {75, 4, 1} }
    for _, case in ipairs(cases) do
        local selected = Core.bestJob(case[1])
        equal(selected.tier, case[2], "Tier at " .. case[1] .. " ascensions")
        equal(selected.jobType, case[3])
    end
end)
test("failure backoff prevents repeated requests every frame", function()
    local e, _, _, _, adapter = fixture()
    local attempts = 0
    adapter.moveToTreadmill = function() attempts = attempts + 1; error("No character", 0) end
    e:setMode("farm")
    for t = 0, 14, 0.25 do e:tick(t) end
    equal(attempts, 4) -- 0, 1, 3, 7; next attempt at 15
    equal(e.status.farm.problem, true)
end)
test("one broken feature does not stop independent tools", function()
    local e, _, _, count, adapter = fixture()
    adapter.moveToTreadmill = function() error("Missing treadmill", 0) end
    e:setMode("farm"); e:setEnabled("buy", true); e:tick(0)
    equal(count("buyUpgrades"), 1)
end)
test("race and ascension pause during jobs, purchases continue", function()
    local e, _, _, count = fixture()
    for _, key in ipairs({ "race", "ascend", "buy" }) do e:setEnabled(key, true) end
    e:setMode("jobs"); e:tick(0)
    equal(count("resetRace"), 0)
    equal(count("ascend"), 0)
    equal(count("buyUpgrades"), 1)
    e:setMode(nil); e:tick(1)
    equal(count("resetRace"), 1)
    equal(count("ascend"), 1)
end)
test("background request intervals are enforced", function()
    local e, _, _, count = fixture()
    for _, key in ipairs({ "race", "ascend", "buy" }) do e:setEnabled(key, true) end
    for t = 0, 10, 0.25 do e:tick(t) end
    equal(count("resetRace"), 3)
    equal(count("ascend"), 2)
    equal(count("buyUpgrades"), 3)
end)
test("stop all clears every control and no later request fires", function()
    local e, _, calls = fixture()
    e:setMode("jobs")
    for _, key in ipairs({ "race", "ascend", "buy" }) do e:setEnabled(key, true) end
    e:tick(0); e:stopAll()
    local count = #calls
    e:tick(100)
    equal(#calls, count)
    equal(e.mode, nil)
    for _, enabled in pairs(e.enabled) do equal(enabled, false) end
end)
test("destroy is idempotent and cannot be restarted", function()
    local e, _, calls = fixture()
    e:setMode("farm"); e:tick(0); e:destroy(); e:destroy()
    local count = #calls
    e:setMode("jobs"); e:setEnabled("buy", true); e:tick(100)
    equal(#calls, count)
    equal(e.running, false)
    equal(e.mode, nil)
end)
local function running(state, count, index, banked, drop)
    state.phase, state.legCount, state.index, state.banked = "running", count or 1, index or 1, banked or 0
    state.drop, state.delivered = drop or "marker", false
    state.revision += 1
end

test("chain capacity follows all supplied ascension unlocks", function()
    equal(Core.chainCapacity(0), 2); equal(Core.chainCapacity(9), 2)
    equal(Core.chainCapacity(10), 3); equal(Core.chainCapacity(24), 3)
    equal(Core.chainCapacity(25), 4); equal(Core.chainCapacity(75), 4)
end)
test("four slots are filled one at a time with the highest-paying eligible job", function()
    local e, state, calls, count = fixture()
    state.ascensions = 75
    e:setMode("jobs"); e:tick(0); e:tick(1)
    equal(count("claimJob"), 1); equal(count("appendJob"), 0)
    advance(e, 1.5, 5)
    equal(count("claimJob"), 1)
    for slot = 1, 3 do
        state.phase, state.legCount, state.index = "claimed", slot, 1
        state.revision += 1
        advance(e, 6 + slot * 2, 7 + slot * 2)
        equal(count("appendJob"), slot)
    end
    for _, call in ipairs(calls) do
        if call.name == "claimJob" then equal(call.args[1], 4); equal(call.args[2], 1)
        elseif call.name == "appendJob" then equal(call.args[1], 4); equal(#call.args, 1) end
    end
    state.legCount = 4
    advance(e, 15, 18)
    equal(count("appendJob"), 3)
    equal(e.jobs.phase, "leavePad")
end)
test("each new slot rechecks eligibility without downgrading an existing claim", function()
    local e, state, calls, count = fixture()
    state.ascensions = 10
    e:setMode("jobs"); e:tick(0); e:tick(1)
    state.phase, state.legCount, state.index = "claimed", 1, 1
    state.ascensions = 25
    advance(e, 1.5, 3)
    equal(count("claimJob"), 1); equal(count("appendJob"), 1)
    for _, call in ipairs(calls) do
        if call.name == "claimJob" then equal(call.args[1], 3)
        elseif call.name == "appendJob" then equal(call.args[1], 9) end
    end
end)
test("delayed claims refresh authoritative state before automatically retrying", function()
    local e, state, _, count = fixture()
    e:setMode("jobs"); e:tick(0); e:tick(1)
    advance(e, 1.5, 12)
    equal(count("claimJob"), 1); equal(count("refreshJobState"), 0)
    advance(e, 12.5, 14)
    equal(count("refreshJobState"), 1); equal(count("claimJob"), 1)
    advance(e, 14.5, 17)
    equal(count("claimJob"), 2)
    state.phase, state.legCount, state.index = "claimed", 2, 1
    state.ascensions = 0
    advance(e, 17.5, 20)
    equal(count("claimJob"), 2); equal(count("appendJob"), 0)
end)
test("a missing destination never implies a banked job or authorizes Return to Spawn", function()
    local e, state, _, count = fixture()
    running(state, 4); state.distance = 10
    e:setMode("jobs"); advance(e, 0, 2)
    state.drop = nil
    advance(e, 2.5, 30)
    equal(count("collectJob"), 0); equal(count("returnToSpawn"), 0)
    equal(count("claimJob"), 0); equal(e.deliveries, 0)
end)
test("next legs including identical coordinates reset arrival tracking without returning", function()
    local e, state, _, count = fixture()
    running(state, 4)
    e:setMode("jobs"); advance(e, 0, 2)
    equal(count("reportArrival"), 1)
    running(state, 4, 2, 1) -- Same marker coordinates; the authoritative index changes.
    advance(e, 2.5, 4.5)
    equal(count("reportArrival"), 2)
    equal(count("returnToSpawn"), 0); equal(count("collectJob"), 0)
    equal(count("claimJob"), 0); equal(count("appendJob"), 0)
end)
test("full banked chain returns to spawn and reaches the NPC before collection", function()
    local e, state, _, count, adapter = fixture()
    state.phase, state.legCount, state.index, state.banked = "claimed", 4, 4, 4
    state.delivered, state.spawnNeeded, state.atBoard = true, true, false
    adapter.moveToBoard = function() return state.atBoard, 100 end
    e:setMode("jobs"); advance(e, 0, 4)
    equal(count("returnToSpawn"), 1); equal(count("collectJob"), 0)
    state.returned = true
    advance(e, 4.5, 6)
    equal(count("collectJob"), 0)
    state.atBoard = true; e:tick(6.5)
    equal(count("collectJob"), 1); equal(e.deliveries, 0)
    state.banked, state.legCount, state.index, state.phase = 0, 0, 0, "idle"
    state.revision += 1
    e:tick(7)
    equal(e.deliveries, 4)
    e:tick(7.5); equal(e.deliveries, 4)
end)
test("payout retries need a fresh snapshot and never count unacknowledged requests", function()
    local e, state, _, count = fixture()
    state.phase, state.legCount, state.index, state.banked = "claimed", 4, 4, 4
    e:setMode("jobs"); advance(e, 0, 9)
    equal(count("collectJob"), 1); equal(e.deliveries, 0)
    advance(e, 9.5, 11)
    equal(count("refreshJobState"), 1); equal(count("collectJob"), 2)
    equal(count("claimJob"), 0); equal(e.deliveries, 0)
end)
test("banked legs in a partial chain continue delivery rather than returning", function()
    local e, state, _, count = fixture()
    running(state, 4, 3, 2)
    e:setMode("jobs"); advance(e, 0, 3)
    equal(count("reportArrival"), 1); equal(count("returnToSpawn"), 0)
    equal(count("collectJob"), 0); equal(count("appendJob"), 0)
end)
test("stalled delivery retries automatically with backoff and Stop cancels further recovery", function()
    local e, state, _, count = fixture()
    running(state); state.distance = 50000
    e:setMode("jobs"); advance(e, 0, 14.5)
    equal(count("recoverJobMovement"), 0)
    e:tick(15); equal(count("recoverJobMovement"), 1)
    advance(e, 15.5, 32.5); equal(count("recoverJobMovement"), 1)
    e:tick(33); equal(count("recoverJobMovement"), 2)
    equal(count("reportArrival"), 0); equal(count("returnToSpawn"), 0)
    e:stopAll(); advance(e, 34, 100)
    equal(count("recoverJobMovement"), 2)
end)
test("arrival requests respect radius, settling and cooldown before a new retry cycle", function()
    local e, state, calls, count = fixture()
    running(state); state.distance = 100
    e:setMode("jobs"); advance(e, 0, 2)
    equal(count("reportArrival"), 0)
    state.distance = 10; advance(e, 2.5, 3.5)
    equal(count("reportArrival"), 0)
    state.distance = 80; e:tick(4)
    state.distance = 10; advance(e, 4.5, 5.5)
    equal(count("reportArrival"), 0)
    e:tick(6); equal(count("reportArrival"), 1)
    advance(e, 6.5, 19)
    equal(count("reportArrival"), 5)
    advance(e, 19.5, 28)
    equal(count("reportArrival"), 5)
    advance(e, 28.5, 31)
    equal(count("recoverJobMovement"), 1)
    assert(count("reportArrival") >= 6)
    equal(count("collectJob"), 0)
end)
test("invalid or unavailable state cannot claim, arrive or collect", function()
    local e, state, _, count = fixture()
    state.legCount = 0/0
    e:setMode("jobs"); e:tick(0)
    equal(e.status.jobs.problem, true)
    equal(count("claimJob"), 0); equal(count("collectJob"), 0)
    state.legCount = 0; state.ascensions = nil
    e:tick(1)
    equal(e.status.jobs.problem, true); equal(count("claimJob"), 0)
end)
test("banked rewards do not end a chain whose active index still has later legs", function()
    local e, state, _, count = fixture()
    running(state, 4, 2, 4)
    state.distance, state.spawnNeeded = 1000, true
    e:setMode("jobs"); advance(e, 0, 5)
    equal(count("returnToSpawn"), 0); equal(count("collectJob"), 0)
    assert(count("moveToDrop") > 0)
end)
test("a partial payout counts only cleared jobs and continues collecting the remainder", function()
    local e, state, _, count = fixture()
    state.phase, state.legCount, state.index, state.banked, state.delivered = "claimed", 4, 4, 4, true
    e:setMode("jobs"); e:tick(0)
    state.banked = 2; e:tick(0.5)
    equal(e.deliveries, 2)
    e:tick(1.5); equal(count("collectJob"), 2)
    state.banked, state.legCount, state.index, state.phase = 0, 0, 0, "idle"
    e:tick(2); equal(e.deliveries, 4)
end)
test("a new claimed phase gets a fresh departure window after a running leg", function()
    local e, state, _, count, adapter = fixture()
    local departures = 0
    adapter.leaveJobPad = function() departures += 1 end
    state.phase, state.legCount, state.index = "claimed", 3, 1
    e:setMode("jobs"); e:tick(0)
    equal(departures, 1)
    running(state, 3, 2, 1)
    state.distance = 1000
    advance(e, 1, 10)
    state.phase = "claimed"
    e:tick(20)
    equal(departures, 2, "A previous departure timer delayed the next leg")
    equal(count("recoverJobMovement"), 0)
    equal(e.jobs.leaveStarted, 20)
end)
print(string.format("%d controller tests passed", passed))
