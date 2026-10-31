-- Pure automation controller. Adapter calls must not yield; Roblox lookups live in Hub.luau.
local Core = {}
Core.__index = Core
Core.ARRIVAL_RADIUS = 50
Core.ARRIVAL_SETTLE = 1.5
Core.ARRIVAL_CLEAR = 1.5
Core.ARRIVAL_RETRY = 3
Core.ARRIVAL_ATTEMPTS = 5

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
    if self.mode == "jobs" and self.adapter.stopDeliveryMovement then
        self.adapter.stopDeliveryMovement()
    end
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
        if statusKey == "jobs" then
            -- An unreadable sample is not evidence of continuous proximity/completion.
            self.jobs.withinSince = nil
            self.jobs.arrivalClearSince = nil
            self.jobs.clearSince = nil
        end
        local failures = (self.failures[key] or 0) + 1
        self.failures[key] = failures
        local retry = math.min(15, 2 ^ math.min(failures - 1, 4))
        self.due[key] = now + retry
        self:report(statusKey, tostring(delay) .. " · retry in " .. retry .. "s", true)
    end
end

function Core:stepJobs(now)
    local job = self.jobs
    local gamePhase = self.adapter.getJobPhase and self.adapter.getJobPhase()
    local drop
    if gamePhase == nil or gamePhase == "running" then drop = self.adapter.getDropPoint() end
    -- The game's DeliveryAutoLockController only uses GetDropPoint in "running".
    -- A claimed contract must leave its pad normally before teleporting to its target.
    if gamePhase == "claimed" then
        job.phase = "leavePad"
        job.leaveStarted = job.leaveStarted or now
        if now - job.leaveStarted >= 12 then
            if not job.leavePaused then self.adapter.stopDeliveryMovement(); job.leavePaused = true end
            self:report("jobs", "Job still claimed · step off the job pad manually to start running", true)
            return 1
        end
        if now >= (job.nextLeave or 0) then
            self.adapter.leaveJobPad()
            job.nextLeave = now + 4
        end
        self:report("jobs", "Job claimed · leaving pad normally; waiting for running phase")
        return 0.5
    end
    if job.phase == "leavePad" then
        self.adapter.stopDeliveryMovement()
        self.jobs = { phase = "idle" }
        job = self.jobs
    end
    if gamePhase ~= nil and gamePhase ~= "running" then drop = nil end
    if gamePhase == "running" and self.adapter.getPlayerState then
        local playerState = self.adapter.getPlayerState()
        if playerState ~= "RunWorld" then
            if not job.worldPaused then self.adapter.stopDeliveryMovement(); job.worldPaused = true end
            job.withinSince = nil
            job.arrivalClearSince = nil
            job.clearSince = nil
            self:report("jobs", "Waiting for running world before delivery movement")
            return 0.5
        end
        job.worldPaused = nil
    end
    if drop ~= nil then job.lastDrop = drop end

    if job.phase == "approach" or job.phase == "awaitArrival" then
        -- A game-side completion can move the player too. Once arrival was reported,
        -- observe a cleared destination before considering any position corrections.
        if job.phase == "awaitArrival" and drop == nil then
            job.arrivalClearSince = job.arrivalClearSince or now
            if now - job.arrivalClearSince >= Core.ARRIVAL_CLEAR then
                job.phase = "collect"
                self:report("jobs", "Destination cleared · ready to collect banked payout")
            else
                self:report("jobs", "Destination cleared · checking it stays cleared")
            end
            return 0.3
        end
        job.arrivalClearSince = nil
        local distance = self.adapter.getDropDistance(job.lastDrop)
        assert(type(distance) == "number" and distance >= 0 and distance < math.huge, "Delivery distance unavailable")
        local attempts = job.arrivalAttempts or 0
        local detail = string.format("%.1f / %d studs · arrival %d/%d", distance, Core.ARRIVAL_RADIUS, attempts, Core.ARRIVAL_ATTEMPTS)

        if distance > Core.ARRIVAL_RADIUS then
            job.withinSince = nil
            job.arrivalClearSince = nil
            local diagnostic, returned
            if self.adapter.getDeliveryDiagnostics then
                diagnostic, returned = self.adapter.getDeliveryDiagnostics(job.lastDrop)
            end
            if returned and job.travelMode ~= "walk" and self.adapter.walkToDrop then
                self.adapter.stopDeliveryMovement()
                job.travelMode = "walk"
                job.bestWalkDistance = distance
                job.lastWalkProgress = now
                job.nextWalk = 0
                self:report("jobs", "Teleport returned to starting area · switching to normal movement", true)
            end
            if job.travelMode == "walk" then
                if distance < job.bestWalkDistance - 2 then
                    job.bestWalkDistance = distance
                    job.lastWalkProgress = now
                end
                if not job.movementBlocked and now - job.lastWalkProgress >= 12 then
                    self.adapter.stopDeliveryMovement()
                    job.movementBlocked = true
                end
                if job.movementBlocked then
                    self:report("jobs", string.format("Normal movement stalled · %.0f studs away · use game controls to reach marker", distance), true)
                    return 1
                end
                if now >= job.nextWalk then
                    self.adapter.walkToDrop(job.lastDrop)
                    job.nextWalk = now + 4 -- Humanoid MoveTo times out after eight seconds.
                end
                self:report("jobs", string.format("Normal movement after teleport reset · %.0f studs to delivery", distance))
                return 0.5
            end
            if (job.repositions or 0) < 3 and now >= (job.nextReposition or 0) then
                local moved, message, problem = self.adapter.moveToDrop(job.lastDrop)
                if moved == false then
                    self:report("jobs", message, problem)
                    return 0.5
                end
                job.repositions = (job.repositions or 0) + 1
                job.nextReposition = now + 3
                self:report("jobs", "Repositioned · checking whether the move holds")
                return 0.3
            end
            if (job.repositions or 0) >= 3 and not job.movementBlocked then
                self.adapter.stopDeliveryMovement()
                job.movementBlocked = true
            end
            self:report("jobs", (job.movementBlocked and "Movement paused · " or "Checking move · ") .. (diagnostic or detail), true)
            return job.movementBlocked and 1 or 0.3
        end
        job.movementBlocked = nil
        job.withinSince = job.withinSince or now
        if now - job.withinSince < Core.ARRIVAL_SETTLE then
            self:report("jobs", "Letting position settle · " .. detail)
            return 0.3
        end

        if attempts >= Core.ARRIVAL_ATTEMPTS then
            self:report("jobs", "Arrival unconfirmed · " .. detail .. " · try walking to marker", true)
            return 0.5
        end
        if now >= (job.nextArrival or 0) then
            self.adapter.reportArrival()
            job.arrivalAttempts = attempts + 1
            job.nextArrival = now + Core.ARRIVAL_RETRY
            job.phase = "awaitArrival"
            self:report("jobs", string.format("Arrival sent · %.1f / %d studs · attempt %d/%d; awaiting game", distance, Core.ARRIVAL_RADIUS, job.arrivalAttempts, Core.ARRIVAL_ATTEMPTS))
        else
            self:report("jobs", "Awaiting arrival · " .. detail)
        end
        return 0.3
    elseif job.phase == "collect" then
        if drop ~= nil then
            job.phase = "awaitArrival"
            job.arrivalClearSince = nil
            self:report("jobs", "Destination active again · waiting for arrival acceptance")
            return 0.3
        end
        if (job.collections or 0) >= 3 then
            self:report("jobs", "Payout state keeps changing · holding delivery; restart Jobs to retry", true)
            return 1
        end
        self.adapter.collectJob()
        job.collections = (job.collections or 0) + 1
        job.phase = "confirm"
        job.clearSince = nil
        self:report("jobs", "Payout requested · confirming delivery cleared")
        return 0.3
    elseif job.phase == "confirm" then
        if drop == nil then
            job.clearSince = job.clearSince or now
            if now - job.clearSince >= 3 then
                self.adapter.stopDeliveryMovement()
                self.deliveries = self.deliveries + 1
                self.jobs = { phase = "idle" }
                self:report("jobs", "Delivery cleared · next job in 2s")
                return 2
            end
            self:report("jobs", "Confirming delivery cleared · staying at destination")
        else
            job.clearSince = nil
            job.arrivalClearSince = nil
            job.phase = "awaitArrival"
            self:report("jobs", "Destination active again · holding this delivery")
        end
        return 0.3
    end

    if drop ~= nil then
        local moved, message, problem = self.adapter.moveToDrop(drop)
        if moved == false then
            self:report("jobs", message, problem)
            return 0.5
        end
        job.phase = "approach"
        job.nextReposition = now + 3
        self:report("jobs", "Approaching delivery · waiting for position to settle")
        return 0.3
    end
    if job.phase == "waiting" then
        if now >= job.deadline then
            self:report("jobs", "Claim not confirmed · waiting; restart Jobs to retry", true)
        end
        -- A timeout is not a rejection. Never downgrade or send another claim blindly.
        return 0.3
    end
    if gamePhase ~= nil and gamePhase ~= "idle" then
        self:report("jobs", "Game job phase: " .. tostring(gamePhase) .. " · waiting before a new claim")
        return 0.5
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
