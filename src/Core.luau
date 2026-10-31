-- Pure automation controller. Adapter calls must not yield; Roblox lookups live in Hub.luau.
local Core = {}
Core.__index = Core

-- Reward/eligibility data supplied from JobsConfig / JobRewards (2026-10-31).
Core.JOBS = {
    { tier = 4, jobType = 1, name = "Extreme", reward = 40000, ascensions = 75 },
    { tier = 10, jobType = 2, name = "Ancient Crystal", reward = 25000, ascensions = 50 },
    { tier = 7, jobType = 1, name = "Long-Haul Cargo", reward = 18000, ascensions = 30 },
    { tier = 9, jobType = 2, name = "Crystal Core", reward = 14000, ascensions = 25 },
    { tier = 3, jobType = 1, name = "Hard", reward = 10000, ascensions = 10 },
    { tier = 6, jobType = 1, name = "City Express", reward = 10000, ascensions = 12 },
    { tier = 8, jobType = 2, name = "Crystal Shards", reward = 6000, ascensions = 8 },
    { tier = 2, jobType = 1, name = "Medium", reward = 5000, ascensions = 4 },
    { tier = 5, jobType = 1, name = "Supply Rush", reward = 4000, ascensions = 3 },
    { tier = 1, jobType = 1, name = "Easy", reward = 1000, ascensions = 0 },
}

function Core.bestJob(ascensions)
    assert(type(ascensions) == "number" and ascensions >= 0 and ascensions < math.huge and ascensions % 1 == 0,
        "Ascension count unavailable · enter your current count on Jobs")
    local best
    for _, candidate in ipairs(Core.JOBS) do
        if ascensions >= candidate.ascensions and (not best or candidate.reward > best.reward
            or candidate.reward == best.reward and candidate.ascensions < best.ascensions) then
            best = candidate
        end
    end
    return best
end

function Core.new(adapter)
    return setmetatable({
        adapter = adapter,
        running = true,
        mode = nil,
        treadmill = "x10",
        enabled = { race = false, ascend = false, buy = false, antiIdle = true },
        status = {},
        due = {},
        failures = {},
        jobs = { phase = "idle" },
        farmPhase = "start",
        deliveries = 0,
        orbRequests = 0,
    }, Core)
end

function Core:report(key, text, problem)
    local old = self.status[key]
    if not old or old.text ~= text or old.problem ~= (problem == true) then
        self.status[key] = { text = text, problem = problem == true }
        if self.adapter.onStatus then
            self.adapter.onStatus(key, text, problem == true)
        end
    end
end

function Core:setMode(mode)
    assert(mode == nil or mode == "farm" or mode == "orbs" or mode == "jobs", "Unknown movement mode")
    if not self.running or self.mode == mode then return end
    if self.mode then self:report(self.mode, "Off") end
    self.mode = mode
    self.jobs = { phase = "idle" }
    self.farmPhase = "start"
    self.due.movement = 0
    self.failures.movement = 0
    if mode then self:report(mode, "Starting…") end
end

function Core:setEnabled(key, value)
    assert(self.enabled[key] ~= nil, "Unknown automation")
    if not self.running then return end
    self.enabled[key] = value == true
    self.due[key] = 0
    self.failures[key] = 0
    self:report(key, value and "Ready" or "Off")
end

function Core:stopAll()
    self:setMode(nil)
    for key in pairs(self.enabled) do self:setEnabled(key, false) end
end

function Core:destroy()
    if not self.running then return end
    self:stopAll()
    self.running = false
end

function Core:run(key, statusKey, now, callback)
    if now < (self.due[key] or 0) then return end
    local ok, delay = pcall(callback)
    if ok then
        self.failures[key] = 0
        self.due[key] = now + (delay or 1)
    else
        local failures = (self.failures[key] or 0) + 1
        self.failures[key] = failures
        local retry = math.min(15, 2 ^ math.min(failures - 1, 4))
        self.due[key] = now + retry
        self:report(statusKey, tostring(delay) .. " · retry in " .. retry .. "s", true)
    end
end

function Core:stepJobs(now)
    local job = self.jobs
    -- Keep ownership through arrival, payout and replicated destination flicker.
    local drop = self.adapter.getDropPoint()
    if drop ~= nil then job.lastDrop = drop end

    if job.phase == "arrival" then
        -- The native arrival controller may already have cleared GetDropPoint.
        self.adapter.moveToDrop(drop or job.lastDrop)
        self.adapter.reportArrival()
        job.phase = "collect"
        self:report("jobs", "Arrival reported · waiting to collect banked payout")
        return 0.8
    elseif job.phase == "collect" then
        -- A cleared destination must not skip CollectJob or send us back to the board.
        if drop ~= nil then self.adapter.moveToDrop(drop) end
        self.adapter.collectJob()
        job.phase = "confirm"
        job.deadline = now + 5
        job.clearSince = nil
        self:report("jobs", "Payout requested · confirming delivery cleared")
        return 0.3
    elseif job.phase == "confirm" then
        if drop == nil then
            job.clearSince = job.clearSince or now
            if now - job.clearSince >= 3 then
                self.deliveries = self.deliveries + 1
                self.jobs = { phase = "idle" }
                self:report("jobs", "Delivery cleared · next job in 2s")
                return 2
            end
            self:report("jobs", "Confirming delivery cleared · staying at destination")
        else
            job.clearSince = nil
            if now >= job.deadline then
                job.retries = (job.retries or 0) + 1
                if job.retries <= 2 then
                    self.adapter.moveToDrop(drop)
                    job.phase = "arrival"
                    self:report("jobs", "Delivery still active · retrying arrival")
                    return 0.8
                end
                self:report("jobs", "Delivery still active · holding position; restart Jobs to retry", true)
                return 1
            end
        end
        return 0.3
    end

    if drop ~= nil then
        self.adapter.moveToDrop(drop)
        job.phase = "arrival"
        self:report("jobs", "Delivery active · approaching destination")
        return 0.8
    end
    if job.phase == "waiting" then
        if now >= job.deadline then
            self:report("jobs", "Claim not confirmed · waiting; restart Jobs to retry", true)
        end
        -- A timeout is not a rejection. Never downgrade or send another claim blindly.
        return 0.3
    end

    local candidate = Core.bestJob(self.adapter.getAscensions())
    if job.phase ~= "claim" then
        self.adapter.moveToBoard()
        job.phase = "claim"
        self:report("jobs", "At board · selected " .. candidate.name .. " (" .. candidate.reward .. ")")
        return 0.8
    end
    -- Recheck eligibility immediately before the request; ascension may have changed.
    self.adapter.claimJob(candidate.tier, candidate.jobType)
    job.choice = candidate
    job.phase = "waiting"
    job.deadline = now + 12
    self:report("jobs", "Requested " .. candidate.name .. " · waiting for acceptance")
    return 0.3
end

function Core:tick(now)
    if not self.running then return end
    if self.mode then
        self:run("movement", self.mode, now, function()
            if self.mode == "jobs" then return self:stepJobs(now) end
            if self.mode == "farm" then
                self.adapter.moveToTreadmill(self.treadmill)
                if self.farmPhase == "start" then
                    self.adapter.chargeStart()
                    self.farmPhase = "burst"
                    self:report("farm", "Charging on " .. self.treadmill)
                    return 0.4
                end
                self.adapter.chargeBurst()
                self.farmPhase = "start"
                self:report("farm", "Training on " .. self.treadmill)
                return 0.8
            end
            local found = self.adapter.collectNearestOrb()
            if found then self.orbRequests = self.orbRequests + 1 end
            self:report("orbs", found and "Nearby orb requested" or "No collectible orbs within 80 studs")
            return 0.8
        end)
    end
    for _, key in ipairs({ "race", "ascend", "buy" }) do
        if self.enabled[key] then
            self:run(key, key, now, function()
                if self.mode == "jobs" and key ~= "buy" then
                    self:report(key, "Paused while jobs control movement")
                    return 1
                end
                if key == "race" then
                    self.adapter.resetRace()
                    self:report(key, "Race reset requested")
                    return 4
                elseif key == "ascend" then
                    self.adapter.ascend()
                    self:report(key, "Ascension requested")
                    return 10
                end
                self.adapter.buyUpgrades()
                self:report(key, "Speed / Jump purchase requests sent")
                return 5
            end)
        end
    end
end

return Core
