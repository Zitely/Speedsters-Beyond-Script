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
    local state = { drop = nil, ascensions = 10 }
    local adapter = {}
    for _, name in ipairs({ "moveToTreadmill", "chargeStart", "chargeBurst", "moveToBoard", "claimJob", "moveToDrop", "reportArrival", "collectJob", "resetRace", "ascend", "buyUpgrades" }) do
        adapter[name] = function(...) table.insert(calls, { name = name, args = { ... } }) end
    end
    adapter.getAscensions = function() return state.ascensions end
    adapter.getDropPoint = function() return state.drop end
    adapter.collectNearestOrb = function() table.insert(calls, { name = "orb" }); return state.orb end
    local engine = Core.new(adapter)
    local function count(name)
        local total = 0
        for _, call in ipairs(calls) do if call.name == name then total = total + 1 end end
        return total
    end
    return engine, state, calls, count, adapter
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
test("job claim waits at the board then waits for server acceptance", function()
    local e, _, calls, count = fixture()
    e:setMode("jobs"); e:tick(0)
    equal(count("claimJob"), 0)
    e:tick(0.9)
    equal(count("claimJob"), 1)
    equal(calls[#calls].args[1], 3)
    equal(calls[#calls].args[2], 1)
    for t = 1, 5, 0.25 do e:tick(t) end
    equal(count("claimJob"), 1)
    equal(count("collectJob"), 0)
end)
test("a delayed claim never downgrades to Easy or sends another request", function()
    local e, state, calls, count = fixture()
    e:setMode("jobs"); e:tick(0); e:tick(1)
    for t = 2, 60 do e:tick(t) end
    equal(count("claimJob"), 1)
    equal(calls[#calls].args[1], 3)
    equal(calls[#calls].args[2], 1)
    equal(count("moveToBoard"), 1)
    state.drop = "late acceptance"
    e:tick(61); e:tick(62); e:tick(63)
    equal(count("collectJob"), 1)
end)
test("observed delivery prevents lower-tier claim bursts", function()
    local e, state, _, count = fixture()
    e:setMode("jobs"); e:tick(0); e:tick(1)
    state.drop = "destination"
    e:tick(1.5); e:tick(2.5); e:tick(3.5)
    equal(count("claimJob"), 1)
    equal(count("reportArrival"), 1)
    equal(count("collectJob"), 1)
    equal(e.deliveries, 0)
    state.drop = nil
    e:tick(4)
    equal(e.deliveries, 0)
    e:tick(7.1)
    equal(e.deliveries, 1)
end)
test("existing delivery is resumed without another claim", function()
    local e, state, _, count = fixture()
    state.drop = "destination"
    e:setMode("jobs"); e:tick(0); e:tick(1); e:tick(2)
    equal(count("claimJob"), 0)
    equal(count("collectJob"), 1)
end)
test("stopping before arrival does not count canceled work", function()
    local e, state = fixture()
    state.drop = "destination"
    e:setMode("jobs"); e:tick(0)
    state.drop = nil
    e:setMode(nil)
    e:tick(1)
    equal(e.deliveries, 0)
end)
test("native arrival can clear the destination before payout collection", function()
    local e, state, _, count = fixture()
    e:setMode("jobs"); e:tick(0); e:tick(1)
    state.drop = "destination"
    e:tick(2)
    state.drop = nil -- Native controller reports arrival as soon as we enter its radius.
    e:tick(3); e:tick(4); e:tick(5)
    equal(count("moveToBoard"), 1)
    equal(count("claimJob"), 1)
    equal(count("reportArrival"), 1)
    equal(count("collectJob"), 1)
    equal(e.deliveries, 0)
    e:tick(8.1)
    equal(e.deliveries, 1)
    equal(count("moveToBoard"), 1)
end)
test("completion needs consecutive clear readings and resets on a flicker", function()
    local e, state, _, count = fixture()
    state.drop = "destination"
    e:setMode("jobs"); e:tick(0); e:tick(1); e:tick(2)
    state.drop = nil
    e:tick(3); e:tick(4)
    state.drop = "destination"
    e:tick(4.5)
    state.drop = nil
    e:tick(5); e:tick(7)
    equal(e.deliveries, 0)
    equal(count("moveToBoard"), 0)
    e:tick(8.1)
    equal(e.deliveries, 1)
    equal(count("moveToBoard"), 0)
end)
test("collection is retried only after acknowledgement timeout", function()
    local e, state, _, count = fixture()
    state.drop = "destination"
    e:setMode("jobs"); e:tick(0); e:tick(1); e:tick(2)
    for t = 2.5, 4.5, 0.5 do e:tick(t) end
    equal(count("collectJob"), 1)
    e:tick(7.5); e:tick(8.5); e:tick(9.5)
    equal(count("collectJob"), 2)
end)
test("disabling a job during the arrival delay prevents collection", function()
    local e, state, _, count = fixture()
    state.drop = "destination"
    e:setMode("jobs"); e:tick(0)
    e:setMode(nil); e:tick(10)
    equal(count("reportArrival"), 0)
    equal(count("collectJob"), 0)
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
test("missing or invalid ascensions never silently claim Easy", function()
    local e, state, _, count = fixture()
    state.ascensions = nil
    e:setMode("jobs"); e:tick(0); e:tick(10)
    equal(count("claimJob"), 0)
    equal(count("moveToBoard"), 0)
    equal(e.status.jobs.problem, true)
    for _, invalid in ipairs({ -1, 1.5, math.huge, 0/0, "10" }) do
        equal(pcall(Core.bestJob, invalid), false)
    end
end)
test("eligibility is rechecked before claiming after a stat change", function()
    local e, state, calls = fixture()
    state.ascensions = 0
    e:setMode("jobs"); e:tick(0)
    state.ascensions = 10
    e:tick(1)
    equal(calls[#calls].args[1], 3)
end)
test("stalled delivery retries are bounded and never return to the board", function()
    local e, state, _, count = fixture()
    state.drop = "destination"
    e:setMode("jobs")
    for t = 0, 60 do e:tick(t) end
    equal(count("collectJob"), 3)
    equal(count("moveToBoard"), 0)
    equal(count("claimJob"), 0)
    equal(e.status.jobs.problem, true)
end)
test("missing controller prevents blind job claims and recovers", function()
    local e, _, _, count, adapter = fixture()
    adapter.getDropPoint = function() error("Waiting for controller", 0) end
    e:setMode("jobs"); e:tick(0)
    equal(count("claimJob"), 0)
    equal(e.status.jobs.problem, true)
    adapter.getDropPoint = function() return nil end
    e:tick(1); e:tick(2)
    equal(count("claimJob"), 1)
    equal(e.status.jobs.problem, false)
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
print(string.format("%d tests passed", passed))
