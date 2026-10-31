-- Pure automation controller. Adapter calls must not yield; Roblox lookups live in Hub.luau.
local Core = {}
Core.__index = Core

-- These are the tier/slot pairs from the supplied script, not a live server reward table.
Core.JOBS = {
    { tier = 4, slot = 1, name = "Extreme", reward = 40000 },
    { tier = 10, slot = 2, name = "Ancient Crystal", reward = 25000 },
    { tier = 7, slot = 1, name = "Long-Haul Cargo", reward = 18000 },
    { tier = 3, slot = 1, name = "Hard", reward = 10000 },
    { tier = 2, slot = 1, name = "Medium", reward = 5000 },
}

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
        jobs = { phase = "idle", index = 1 },
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
    self.jobs = { phase = "idle", index = 1 }
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
    -- nil means no job. An unavailable controller must throw, so we never claim blindly.
    local drop = self.adapter.getDropPoint()
    if drop ~= nil then
        if job.phase == "arrival" then
            self.adapter.moveToDrop(drop)
            self.adapter.reportArrival()
            job.phase = "collect"
            self:report("jobs", "Arrival reported · waiting to collect")
            return 0.6
        elseif job.phase == "collect" then
            self.adapter.moveToDrop(drop)
            self.adapter.collectJob()
            job.phase = "confirm"
            job.deadline = now + 3
            self:report("jobs", "Collection requested · awaiting confirmation")
            return 0.3
        elseif job.phase == "confirm" and now < job.deadline then
            return 0.3
        end
        self.adapter.moveToDrop(drop)
        job.phase = "arrival"
        self:report("jobs", "Delivery active · approaching destination")
        return 0.8
    end

    if job.phase == "confirm" then
        self.deliveries = self.deliveries + 1
        self.jobs = { phase = "idle", index = 1 }
        self:report("jobs", "Delivery cleared · looking for the next job")
        return 1.5
    elseif job.phase == "arrival" or job.phase == "collect" then
        -- A server cancellation is not a successful delivery.
        self.jobs = { phase = "idle", index = 1 }
        self:report("jobs", "Delivery ended before collection · checking the board")
        return 1.5
    end

    if job.phase == "waiting" then
        if now < job.deadline then return 0.25 end
        job.index = job.index + 1
        job.phase = "idle"
    end
    if job.index > #Core.JOBS then
        self.jobs = { phase = "idle", index = 1 }
        self:report("jobs", "No listed job accepted · checking again in 8s")
        return 8
    end

    local candidate = Core.JOBS[job.index]
    self.adapter.moveToBoard()
    if job.phase ~= "claim" then
        job.phase = "claim"
        self:report("jobs", "At job board · preparing " .. candidate.name)
        return 0.8
    end
    self.adapter.claimJob(candidate.tier, candidate.slot)
    job.phase = "waiting"
    job.deadline = now + 5
    self:report("jobs", "Requested " .. candidate.name .. " · waiting for acceptance")
    return 0.25
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
