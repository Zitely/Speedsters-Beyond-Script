-- Pure automation controller. Adapter calls must not yield; Roblox lookups live in Hub.luau.
local Core = {}
Core.__index = Core
Core.ARRIVAL_RADIUS = 50
Core.ARRIVAL_SETTLE = 1.5
Core.ARRIVAL_RETRY = 3
Core.ARRIVAL_ATTEMPTS = 5
Core.RECOVERY_DELAY = 3
Core.ARRIVAL_RECOVERY_DELAY = 10

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

function Core:report(key, text, problem, issue)
    local old = self.status[key]
    if not old or old.text ~= text or old.problem ~= (problem == true) or old.issue ~= issue then
        self.status[key] = { text = text, problem = problem == true, issue = issue }
        if self.adapter.onStatus then
            self.adapter.onStatus(key, text, problem == true, issue)
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
            self.adapter.stopDeliveryMovement()
            -- An unreadable sample is not evidence of continuous proximity/completion.
            if self.jobs.travel then self.jobs.travel.withinSince = nil end
        end
        local failures = (self.failures[key] or 0) + 1
        self.failures[key] = failures
        local retry = math.min(15, 2 ^ math.min(failures - 1, 4))
        self.due[key] = now + retry
        self:report(statusKey, tostring(delay) .. " · retry in " .. retry .. "s", true)
    end
end

function Core:recoverMovement(phase, drop)
    if self.adapter.recoverJobMovement then
        self.adapter.recoverJobMovement(phase, drop)
    elseif phase == "running" then
        self.adapter.moveToDrop(drop)
    elseif phase == "claimed" then
        self.adapter.leaveJobPad()
    else
        self.adapter.moveToBoard()
    end
end

local function recoveryDelay(attempts)
    return math.min(30, Core.RECOVERY_DELAY * 2 ^ math.min(attempts or 0, 4))
end

function Core:travelToBoard(now, job, gamePhase)
    if job.boardPaused then
        if now < job.boardRetryAt then
            self:report("jobs", "Board travel stalled · retrying automatically", true, "board_stalled")
            return false
        end
        job.boardRecoveries = (job.boardRecoveries or 0) + 1
        job.boardPaused = nil
        job.bestBoardDistance = nil
        job.boardProgressAt = now
        job.spawnRequested = nil
        job.spawnFinished = nil
        job.boardNeedsRecovery = true
    end
    if self.adapter.shouldReturnToSpawn and self.adapter.shouldReturnToSpawn() and not job.spawnRequested then
        self.adapter.stopDeliveryMovement()
        self.adapter.returnToSpawn()
        job.spawnRequested = now
        self:report("jobs", "Return to Spawn requested · waiting for the game")
        return false
    end
    if job.spawnRequested and not job.spawnFinished then
        if not self.adapter.hasReturnedToSpawn() and now - job.spawnRequested < 5 then
            self:report("jobs", "Waiting for Return to Spawn")
            return false
        end
        -- A missing acknowledgement must not deadlock travel; approach normally after the grace period.
        job.spawnFinished = true
        job.boardProgressAt = now
        job.bestBoardDistance = nil
    end
    -- A spawn request stops steering. Start route recovery only after it settles,
    -- otherwise stopping for the request discards the new route before it runs.
    if job.boardNeedsRecovery then
        self:recoverMovement("idle")
        job.boardNeedsRecovery = nil
    end
    local reached, distance = self.adapter.moveToBoard(gamePhase)
    if reached ~= false then return true end
    job.bestBoardDistance = job.bestBoardDistance or distance
    job.boardProgressAt = job.boardProgressAt or now
    if distance < job.bestBoardDistance - 2 then
        job.bestBoardDistance = distance
        job.boardProgressAt = now
    end
    if now - job.boardProgressAt >= 12 then
        self.adapter.stopDeliveryMovement()
        job.boardPaused = true
        job.boardRetryAt = now + recoveryDelay(job.boardRecoveries)
    end
    self:report("jobs", string.format("Travelling to job board · %.0f studs remaining", distance))
    return false
end

function Core.chainCapacity(ascensions)
    Core.bestJob(ascensions) -- Reuse finite, whole-number validation.
    if ascensions >= 25 then return 4 end
    if ascensions >= 10 then return 3 end
    return 2
end

function Core:stepJobs(now)
    local job = self.jobs
    local state = self.adapter.getJobState()
    assert(type(state) == "table" and (state.phase == "idle" or state.phase == "claimed" or state.phase == "running"), "Waiting for a valid job phase")
    for _, key in ipairs({ "legCount", "banked", "index", "revision" }) do
        local value = state[key]
        assert(type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0, "Invalid job state: " .. key)
    end
    assert(state.legCount <= 4 and state.index <= state.legCount + 1, "Invalid job chain")
    assert(type(state.delivered) == "boolean", "Delivery acknowledgement unavailable")
    assert(state.phase ~= "running" or state.legCount > 0 and state.index >= 1, "Waiting for the active chain index")
    self.jobState = state
    if state.phase == "idle" then job.leavingPad = nil end
    if state.phase ~= "claimed" and not job.leavingPad then
        job.leaveStarted, job.nextLeave, job.leaveRetryAt, job.leaveRecoveries, job.departurePhase = nil, nil, nil, nil, nil
    end

    local pending = job.pendingClaim
    if pending and (state.legCount > pending.before or state.phase == "running") then
        job.pendingClaim = nil
        job.claimReadyAt = nil
    end
    if job.pendingCollect and state.banked < job.pendingCollect.before then
        self.deliveries = self.deliveries + job.pendingCollect.before - state.banked
        self.adapter.stopDeliveryMovement()
        self.jobs = { phase = "idle" }
        self:report("jobs", "Banked jobs collected · preparing the next chain")
        return 1
    end

    -- A missing marker is not completion. Only banked progress can authorize the return trip.
    local complete = state.banked > 0 and (state.legCount == 0 or state.index >= state.legCount
        and (state.delivered or state.banked >= state.legCount))
    if complete then
        if job.phase ~= "collect" then
            self.adapter.stopDeliveryMovement()
            self.jobs = { phase = "collect" }
            job = self.jobs
        end
        if job.pendingCollect then
            if now < job.pendingCollect.retryAt then
                self:report("jobs", "Payout requested · waiting for banked count to update")
                return 0.5
            end
            if not job.pendingCollect.refreshRevision then
                job.pendingCollect.refreshRevision = state.revision
                self.adapter.refreshJobState()
                self:report("jobs", "Refreshing payout state before retrying")
                return 0.5
            end
            if state.revision <= job.pendingCollect.refreshRevision then
                self.adapter.refreshJobState()
                return 1
            end
        end
        if not self:travelToBoard(now, job, state.phase) then return 0.3 end
        self.adapter.collectJob()
        self.adapter.stopDeliveryMovement()
        job.collections = (job.collections or 0) + 1
        job.pendingCollect = { before = state.banked, retryAt = now + math.max(10, recoveryDelay(job.collections)) }
        self:report("jobs", string.format("Collecting %d banked jobs at the NPC", state.banked))
        return 0.5
    end
    if job.pendingCollect then
        self.adapter.stopDeliveryMovement()
        self.adapter.refreshJobState()
        self:report("jobs", "Payout state changed · synchronizing the active chain")
        return 1
    end

    if state.phase == "idle" or state.phase == "claimed" and state.banked == 0 then
        local ascensions = self.adapter.getAscensions()
        local capacity = Core.chainCapacity(ascensions)
        self.jobCapacity = capacity
        if state.legCount < capacity then
            pending = job.pendingClaim
            if pending then
                if now < pending.deadline then
                    self:report("jobs", string.format("%d/%d jobs accepted · waiting for slot %d", state.legCount, capacity, pending.before + 1))
                    return 0.3
                end
                if not pending.refreshRevision then
                    pending.refreshRevision = state.revision
                    self.adapter.refreshJobState()
                    self:report("jobs", "Claim delayed · refreshing accepted slots before retrying")
                    return 0.5
                end
                if state.revision <= pending.refreshRevision then
                    self.adapter.refreshJobState()
                    return 1
                end
                job.pendingClaim = nil
                job.claimReadyAt = now + 3
                self:report("jobs", "Slot still empty · retrying the best eligible job in 3s")
                return 0.5
            end
            if not self:travelToBoard(now, job, state.phase) then return 0.3 end
            job.claimReadyAt = job.claimReadyAt or now + 0.8
            if now < job.claimReadyAt then
                self:report("jobs", string.format("At board · filling %d available slots", capacity))
                return 0.3
            end
            if not self.adapter.isAtBoard() then job.claimReadyAt = nil; return 0.3 end
            local candidate = Core.bestJob(self.adapter.getAscensions())
            if state.legCount == 0 and state.phase == "idle" then
                self.adapter.claimJob(candidate.tier, candidate.jobType)
            elseif state.phase == "claimed" then
                -- Preserve the same payload as the successful first claim.
                self.adapter.appendJob(candidate.tier, candidate.jobType)
            else
                self:report("jobs", "Waiting for the board to accept another leg")
                return 0.5
            end
            self.adapter.stopDeliveryMovement()
            job.phase = "filling"
            job.pendingClaim = { before = state.legCount, deadline = now + 12 }
            self:report("jobs", string.format("Requested %s · slot %d/%d", candidate.name, state.legCount + 1, capacity))
            return 0.3
        end
    end

    if state.phase == "claimed" then job.leavingPad = true end
    if job.leavingPad and state.phase == "running"
        and (not self.adapter.isClearOfPad or self.adapter.isClearOfPad()) then
        self.adapter.stopDeliveryMovement()
        job.leavingPad = nil
        job.leaveStarted, job.nextLeave, job.leaveRetryAt, job.leaveRecoveries, job.departurePhase = nil, nil, nil, nil, nil
    end
    if job.leavingPad then
        job.phase = "leavePad"
        job.leaveStarted = job.leaveStarted or now
        if now - job.leaveStarted >= 12 then
            if not job.leaveRetryAt then
                self.adapter.stopDeliveryMovement()
                job.leaveRetryAt = now + recoveryDelay(job.leaveRecoveries)
            end
            if now < job.leaveRetryAt then
                self:report("jobs", "Pad exit blocked · retrying another direction", true, "leave_recovery")
                return 0.5
            end
            self:recoverMovement("claimed")
            job.leaveRecoveries = (job.leaveRecoveries or 0) + 1
            job.leaveRetryAt = nil
            job.leaveStarted = now
            job.nextLeave = now + 12
            job.departurePhase = state.phase
        end
        if now >= (job.nextLeave or 0) or job.departurePhase ~= state.phase then
            self.adapter.leaveJobPad()
            job.nextLeave = now + 4
            job.departurePhase = state.phase
        end
        self:report("jobs", string.format("%d jobs accepted · stepping sideways off the pad", state.legCount))
        return 0.5
    end
    if state.phase ~= "running" then
        self.adapter.stopDeliveryMovement()
        self.adapter.refreshJobState()
        self:report("jobs", "Synchronizing job chain")
        return 1
    end
    if self.adapter.getPlayerState() ~= "RunWorld" then
        self.adapter.stopDeliveryMovement()
        if job.travel then job.travel.withinSince = nil end
        self:report("jobs", "Waiting for running world")
        return 0.5
    end
    if state.delivered or not state.drop then
        self.adapter.stopDeliveryMovement()
        job.travel = nil
        if now >= (job.nextRefresh or 0) then self.adapter.refreshJobState(); job.nextRefresh = now + 5 end
        self:report("jobs", string.format("%d jobs banked · waiting for the next destination", state.banked))
        return 0.5
    end
    job.phase = "delivery"
    local travel = job.travel
    if not travel or travel.index ~= state.index or not self.adapter.sameDropPoint(travel.drop, state.drop) then
        self.adapter.stopDeliveryMovement()
        travel = { index = state.index, drop = state.drop, lastProgress = now, attempts = 0 }
        job.travel = travel
        self.adapter.moveToDrop(state.drop)
    end
    local distance = self.adapter.getDropDistance(state.drop)
    assert(type(distance) == "number" and distance >= 0 and distance < math.huge, "Delivery distance unavailable")
    if travel.attempts >= Core.ARRIVAL_ATTEMPTS then
        if not travel.arrivalRetryAt then
            self.adapter.stopDeliveryMovement()
            travel.arrivalRetryAt = now + Core.ARRIVAL_RECOVERY_DELAY
        end
        if now < travel.arrivalRetryAt then
            self:report("jobs", "Arrival not acknowledged · retrying approach automatically", true, "arrival_recovery")
            return 0.5
        end
        self:recoverMovement("running", state.drop)
        travel.attempts, travel.arrivalRetryAt, travel.withinSince, travel.nextArrival = 0, nil, nil, nil
        travel.lastProgress, travel.bestDistance = now, distance
        self:report("jobs", "Approaching marker again before retrying arrival")
        return 0.3
    end
    if distance > Core.ARRIVAL_RADIUS then
        travel.withinSince = nil
        travel.bestDistance = travel.bestDistance or distance
        if distance < travel.bestDistance - 2 then
            travel.bestDistance, travel.lastProgress = distance, now
        end
        if not travel.retryAt and now - travel.lastProgress >= 12 then
            self.adapter.stopDeliveryMovement()
            travel.retryAt = now + recoveryDelay(travel.recoveries)
        end
        if travel.retryAt then
            if now < travel.retryAt then
                self:report("jobs", string.format("Travel stalled · %.0f studs away · automatic route retry pending", distance), true, "travel_stalled")
                return 0.5
            end
            self:recoverMovement("running", state.drop)
            travel.recoveries = (travel.recoveries or 0) + 1
            travel.retryAt, travel.bestDistance, travel.lastProgress = nil, distance, now
        else
            self.adapter.moveToDrop(state.drop)
        end
        local problem = self.adapter.getDeliveryMovementProblem and self.adapter.getDeliveryMovementProblem()
        self:report("jobs", problem or string.format("Leg %d/%d · %.0f studs to delivery", state.index, state.legCount, distance), problem ~= nil)
        return 0.3
    end
    travel.retryAt = nil
    travel.withinSince = travel.withinSince or now
    if now - travel.withinSince < Core.ARRIVAL_SETTLE then
        self:report("jobs", string.format("Leg %d/%d · settling inside delivery radius", state.index, state.legCount))
        return 0.3
    end
    if now >= (travel.nextArrival or 0) then
        self.adapter.reportArrival()
        travel.attempts = travel.attempts + 1
        travel.nextArrival = now + Core.ARRIVAL_RETRY
    end
    self:report("jobs", string.format("Leg %d/%d · arrival %d/%d sent; awaiting banked progress", state.index, state.legCount, travel.attempts, Core.ARRIVAL_ATTEMPTS))
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
