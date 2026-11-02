-- scripts/test.py prefixes this file with the actual single-file bundle and the mock module.
local passed = 0
local function test(name, body)
    body()
    passed = passed + 1
    print("PASS " .. name)
end
local function activeConnections(mock)
    local count = 0
    for _, connection in ipairs(mock.connections) do if connection.Connected then count = count + 1 end end
    return count
end
local function advance(mock, first, last)
    for time = first, last, 0.5 do mock.tick(time) end
end

test("bundle creates four pages and responsive desktop/mobile navigation", function()
    local m = Mock.new()
    local session = m.load(BUNDLE)
    for _, page in ipairs({ "Home", "Training", "Jobs", "Tools" }) do m.find(page, "ScrollingFrame") end
    local window = m.find("Window")
    assert(window.Size.X.Offset == 860)
    m.workspace.CurrentCamera.ViewportSize = m.vector(390, 844)
    assert(window.Size.X.Offset == 374)
    m.find("Jobs", "TextButton").Activated:Fire()
    assert(m.find("Jobs", "ScrollingFrame").Visible)
    assert(not m.find("Home", "ScrollingFrame").Visible)
    session.destroy()
end)
test("UI mode switches and the same switch can turn a mode off", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.toggle("Treadmill training"); assert(s.engine.mode == "farm")
    m.tick(0); assert(m.calls[1].name == "ChargeStart")
    m.toggle("Auto job & deliver"); assert(s.engine.mode == "jobs")
    m.toggle("Auto job & deliver"); assert(s.engine.mode == nil)
    m.tick(100); assert(#m.calls == 1)
    s.destroy()
end)
test("selector discovers actual treadmill names and updates selection", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.find("x10   ·   Change").Activated:Fire()
    m.find("x20  ·  available").Activated:Fire()
    assert(s.engine.treadmill == "x20")
    local count = activeConnections(m)
    m.find("x20   ·   Change").Activated:Fire()
    assert(activeConnections(m) == count, "Unchanged selector created duplicate connections")
    s.destroy()
end)
test("stop all synchronizes controls, including idle prevention", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.toggle("Treadmill training"); m.toggle("Auto buy upgrades")
    m.find("Stop all").Activated:Fire()
    assert(s.engine.mode == nil and not s.engine.enabled.buy and not s.engine.enabled.antiIdle)
    m.tick(20); m.player.Idled:Fire()
    assert(#m.calls == 0 and m.idleCount == nil)
    s.destroy()
end)
test("minimize preserves automation and the floating button restores it", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.toggle("Treadmill training")
    m.find("−").Activated:Fire()
    assert(not m.find("Window").Visible and m.find("SB  /  Open").Visible)
    m.tick(0); assert(#m.calls == 1)
    m.find("SB  /  Open").Activated:Fire()
    assert(m.find("Window").Visible)
    s.destroy()
end)
test("close disconnects every listener and prevents all future requests", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.toggle("Treadmill training"); m.tick(0)
    m.find("×").Activated:Fire()
    assert(not s.alive and activeConnections(m) == 0)
    m.tick(100); m.player.Idled:Fire()
    assert(#m.calls == 1 and m.idleCount == nil)
end)
test("re-executing the bundle unloads the previous session", function()
    local m = Mock.new()
    local first = m.load(BUNDLE)
    m.toggle("Treadmill training")
    local expectedConnections = activeConnections(m)
    local second = m.load(BUNDLE)
    assert(not first.alive and second.alive)
    assert(activeConnections(m) == expectedConnections)
    assert(second.engine.mode == nil)
    m.player.Idled:Fire(); assert(m.idleCount == 1)
    m.tick(100); assert(#m.calls == 0)
    second.destroy(); assert(activeConnections(m) == 0)
end)
test("missing remotes surface in the UI and late remotes recover", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    local remotes = m.services.ReplicatedStorage:FindFirstChild("Remotes")
    remotes:FindFirstChild("ChargeStart"):Destroy()
    m.toggle("Treadmill training"); m.tick(0)
    assert(s.engine.status.farm.problem)
    assert(string.find(s.engine.status.farm.text, "ChargeStart"))
    m.instance("RemoteEvent", "ChargeStart", remotes)
    m.tick(1); assert(not s.engine.status.farm.problem)
    assert(m.calls[1].name == "ChargeStart")
    s.destroy()
end)
test("orbs use distance, cooldowns, and streamed additions/removals", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    local near = m.instance("Part", "SpeedOrb", m.workspace)
    near.CFrame = m.environment.CFrame.new(m.vector(20, 0, 0))
    local far = m.instance("Part", "BlueOrb", m.workspace)
    far.CFrame = m.environment.CFrame.new(m.vector(50, 0, 0))
    m.toggle("Nearby orb collection"); m.tick(0)
    assert(m.calls[1].args[1] == near)
    m.tick(1); assert(m.calls[2].args[1] == far)
    m.tick(2); assert(#m.calls == 2, "Orb cooldown was ignored")
    local streamed = m.instance("Part", "NewOrb", m.workspace)
    streamed.CFrame = m.environment.CFrame.new(m.vector(55, 0, 0))
    m.workspace.DescendantAdded:Fire(streamed)
    m.tick(3); assert(m.calls[3].args[1] == streamed)
    m.workspace.DescendantRemoving:Fire(streamed)
    streamed:Destroy()
    near:Destroy(); far:Destroy()
    m.tick(10); assert(#m.calls == 3)
    s.destroy()
end)
test("respawn recovers training and does not count a canceled delivery", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.toggle("Treadmill training"); m.tick(0)
    m.player.Character = nil
    m.tick(1); assert(s.engine.status.farm.problem)
    m.player.Character = m.instance("Model")
    m.instance("Part", "HumanoidRootPart", m.player.Character)
    m.instance("Humanoid", "Humanoid", m.player.Character)
    m.player.CharacterAdded:Fire()
    m.tick(2); assert(not s.engine.status.farm.problem)
    assert(m.calls[#m.calls].name == "ChargeStart")
    m.toggle("Auto job & deliver")
    s.engine.jobs = { phase = "confirm", index = 1 }
    m.player.CharacterAdded:Fire()
    m.tick(3); assert(s.engine.deliveries == 0)
    s.destroy()
end)
test("training never starts charging when the burst endpoint is missing", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.services.ReplicatedStorage:FindFirstChild("Remotes"):FindFirstChild("ChargeBurst"):Destroy()
    m.toggle("Treadmill training"); m.tick(0)
    assert(#m.calls == 0 and s.engine.status.farm.problem)
    s.destroy()
end)
test("minimized mouse drag moves the button without reopening the panel", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.find("−").Activated:Fire()
    local button = m.find("SB  /  Open")
    local input = { UserInputType = m.environment.Enum.UserInputType.MouseButton1, Position = m.vector(20, 20) }
    button.InputBegan:Fire(input)
    m.services.UserInputService.InputChanged:Fire({ UserInputType = m.environment.Enum.UserInputType.MouseMovement, Position = m.vector(120, 140) })
    assert(button.Position.X.Offset == 112 and button.Position.Y.Offset == 132)
    m.services.UserInputService.InputEnded:Fire(input)
    button.Activated:Fire(input)
    assert(not m.find("Window").Visible)
    button.InputBegan:Fire(input)
    m.services.UserInputService.InputEnded:Fire(input)
    button.Activated:Fire(input)
    assert(m.find("Window").Visible)
    s.destroy()
end)
test("minimized touch drag tracks one finger and clamps after rotation", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.find("−").Activated:Fire()
    local button = m.find("SB  /  Open")
    local input = { UserInputType = m.environment.Enum.UserInputType.Touch, Position = m.vector(20, 20) }
    local second = { UserInputType = m.environment.Enum.UserInputType.Touch, Position = m.vector(100, 100) }
    button.InputBegan:Fire(input)
    button.InputBegan:Fire(second)
    m.services.UserInputService.InputChanged:Fire(second)
    assert(button.Position.X.Offset == 12)
    input.Position = m.vector(2000, 2000)
    m.services.UserInputService.InputChanged:Fire(input)
    m.services.UserInputService.InputEnded:Fire(input)
    button.Activated:Fire(input)
    assert(not m.find("Window").Visible)
    assert(button.Position.X.Offset == 1072 and button.Position.Y.Offset == 750)
    m.workspace.CurrentCamera.ViewportSize = m.vector(390, 844)
    assert(button.Position.X.Offset == 262 and button.Position.Y.Offset == 750)
    s.destroy()
end)
test("manual ascension fallback picks Hard instead of guessing Easy", function()
    local m = Mock.new()
    m.player:SetAttribute("Ascensions", nil)
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver"); m.tick(0)
    assert(#m.calls == 0 and s.engine.status.jobs.problem)
    m.find("AscensionCount").Text = "10"
    m.find("Use count").Activated:Fire()
    m.tick(0.1); m.tick(1)
    assert(#m.calls == 1 and m.calls[1].name == "ClaimJob")
    assert(m.calls[1].args[1] == 3 and m.calls[1].args[2] == 1)
    s.destroy()
end)
test("automatic ascensions can come from a replicated stat ValueObject", function()
    local m = Mock.new()
    m.player:SetAttribute("Ascensions", nil)
    local stats = m.instance("Folder", "leaderstats", m.player)
    local count = m.instance("IntValue", "Ascensions", stats)
    count.Value = 25
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver"); m.tick(0); m.tick(1)
    assert(m.calls[1].args[1] == 9 and m.calls[1].args[2] == 2)
    s.destroy()
end)
test("conflicting ascension sources pause claiming until resolved", function()
    local m = Mock.new()
    m.player:SetAttribute("Ascensions", 10)
    local stats = m.instance("Folder", "Stats", m.player)
    local count = m.instance("IntValue", "Ascensions", stats)
    count.Value = 0
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver"); m.tick(0)
    assert(#m.calls == 0 and s.engine.status.jobs.problem)
    count.Value = 10
    m.tick(1); m.tick(2)
    assert(m.calls[1].args[1] == 3)
    s.destroy()
end)
test("automatic detection can replace a manual count before the next claim", function()
    local m = Mock.new()
    m.player:SetAttribute("Ascensions", 75)
    local s = m.load(BUNDLE)
    m.find("AscensionCount").Text = "10"
    m.find("Use count").Activated:Fire()
    assert(s.engine.adapter.getAscensions() == 10)
    m.find("Use automatic detection").Activated:Fire()
    m.toggle("Auto job & deliver"); m.tick(0); m.tick(1)
    assert(m.calls[1].args[1] == 4)
    s.destroy()
end)
local function root(m) return m.player.Character:FindFirstChild("HumanoidRootPart") end
local function humanoid(m) return m.player.Character:FindFirstChildOfClass("Humanoid") end
local function place(m, x, y, z) root(m).CFrame = m.environment.CFrame.new(m.vector(x, y or 0, z or 0)) end
local function drive(m, target)
    m.drop = target
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver"); m.tick(0)
    return s
end

test("a cleared marker without banked progress waits for the next destination", function()
    local m = Mock.new()
    local s = drive(m, m.vector(20, 0, 0))
    m.legCount, m.phase = 4, "running"
    advance(m, 0.5, 2)
    m.drop = nil
    advance(m, 2.5, 20)
    for _, call in ipairs(m.calls) do assert(call.name == "ReportJobArrival") end
    assert(s.engine.deliveries == 0 and m.controls.controlsEnabled)
    s.destroy()
end)
test("direction input precedes game movement regardless of default input tie order", function()
    for _, reversed in ipairs({ false, true }) do
        local m = Mock.new()
        m.reverseInputOrder = reversed
        local s = drive(m, m.vector(1000, 0, 0))
        assert(not m.controls.controlsEnabled and m.controls.disables == 1)
        assert(m.bindings.SpeedstersBeyondDeliveryInput.priority < m.bindings.SpeedstersMovement.priority)
        m.simulateMovement = true
        m.render(1/60)
        assert(humanoid(m).MoveDirection.X == 1 and root(m).Position.X > 0)
        assert(root(m).AssemblyLinearVelocity.X > 0)
        s.destroy()
    end
end)
test("job driver changes input without writing position, velocity, speed or player state", function()
    local m = Mock.new()
    root(m).AssemblyLinearVelocity = m.vector(100, -4, 15)
    local s = drive(m, m.vector(50000, 0, 0))
    advance(m, 0.5, 5)
    assert(root(m).Position.Magnitude == 0 and root(m).AssemblyLinearVelocity.X == 100)
    assert(root(m).AssemblyLinearVelocity.Y == -4 and root(m).AssemblyLinearVelocity.Z == 15)
    assert(humanoid(m).WalkSpeed == 5000 and m.player.Character:GetAttribute("PlayerState") == "RunWorld")
    assert(#m.pivots == 0 and #m.walks == 0 and #m.streamRequests == 0)
    assert(#m.calls == 0 and m.controls.disables == 1)
    s.destroy()
end)
test("simulated game momentum reaches a 50000-stud delivery and brakes inside the radius", function()
    for _, dt in ipairs({ 1/30, 1/60, 1/144 }) do
        local m = Mock.new()
        m.simulateMovement = true
        m.groundLoaded = false -- Steering does not depend on a separate ground raycast.
        local s = drive(m, m.vector(50000, 0, 0))
        local acceptedAt
        m.onRemote = function(name)
            if name == "ReportJobArrival" then
                assert((root(m).Position - m.drop).Magnitude <= 50)
                assert(root(m).AssemblyLinearVelocity.Magnitude == 0)
                acceptedAt = m.clock
                m.drop, m.banked, m.phase, m.delivered = nil, 1, "claimed", true
            elseif name == "ReturnToSpawn" then
                assert(m.banked == 1); place(m, 20)
                m.player.Character:SetAttribute("PlayerState", "Main")
            elseif name == "CollectJob" then
                assert(acceptedAt and m.clock >= acceptedAt)
                assert(root(m).Position.Magnitude <= 10)
                m.banked, m.legCount, m.phase, m.delivered = 0, 0, "idle", false
            else
                error("Unexpected new claim during delivery: " .. name)
            end
        end
        for _ = 1, math.ceil(35/dt) do
            m.frame(dt)
            if s.engine.deliveries == 1 then break end
        end
        assert(s.engine.deliveries == 1, s.engine.status.jobs.text)
        assert(m.controls.controlsEnabled and #m.pivots == 0 and #m.walks == 0)
        s.destroy()
    end
end)
test("blocked movement retries a route automatically without claiming again", function()
    local m = Mock.new()
    local s = drive(m, m.vector(50000, 0, 0))
    advance(m, 0.5, 13)
    assert(s.engine.jobs.travel.retryAt and m.controls.controlsEnabled)
    local warnings = #m.warnings
    place(m, -20); advance(m, 13.5, 14.5)
    assert(#m.warnings == warnings)
    assert(string.find(s.engine.status.jobs.text, "50020", 1, true))
    m.tick(15)
    assert(#m.pathRequests == 1 and not m.controls.controlsEnabled)
    assert((m.pathRequests[1].destination - m.pathRequests[1].origin).Magnitude <= 192.001)
    assert(#m.calls == 0)
    s.destroy()
end)
test("turning off, stop all, switching modes and close restore user controls", function()
    for _, action in ipairs({ "off", "stop", "switch", "close" }) do
        local m = Mock.new()
        local s = drive(m, m.vector(1000, 0, 0))
        if action == "off" then m.toggle("Auto job & deliver")
        elseif action == "stop" then m.find("Stop all").Activated:Fire()
        elseif action == "switch" then m.toggle("Treadmill training")
        else m.find("×").Activated:Fire() end
        assert(m.controls.controlsEnabled and m.controls.enables == 1)
        assert(humanoid(m).MoveDirection.Magnitude == 0)
        m.userDirection = m.vector(0, 0, 1); m.render(1/60)
        assert(humanoid(m).MoveDirection.Z == 1)
        s.destroy()
        assert(m.bindings.SpeedstersBeyondDeliveryInput == nil and m.bindings.SpeedstersMovement ~= nil)
    end
end)
test("reload and respawn release the previous character's input", function()
    local m = Mock.new()
    local first = drive(m, m.vector(1000, 0, 0))
    local second = m.load(BUNDLE)
    assert(not first.alive and m.controls.controlsEnabled and second.engine.mode == nil)
    m.toggle("Auto job & deliver"); m.tick(1)
    assert(not m.controls.controlsEnabled)
    local old = humanoid(m)
    m.player.Character = m.instance("Model")
    m.player.Character:SetAttribute("PlayerState", "RunWorld")
    m.instance("Part", "HumanoidRootPart", m.player.Character)
    m.instance("Humanoid", "Humanoid", m.player.Character)
    m.player.CharacterAdded:Fire()
    assert(m.controls.controlsEnabled and old.MoveDirection.Magnitude == 0)
    m.tick(2); assert(not m.controls.controlsEnabled)
    second.destroy(); assert(m.controls.controlsEnabled)
end)
test("game-disabled or missing controls pause without enabling them", function()
    for _, mode in ipairs({ "disabled", "missing" }) do
        local m = Mock.new()
        if mode == "disabled" then m.controls.controlsEnabled = false
        else m.player:FindFirstChild("PlayerScripts"):FindFirstChild("PlayerModule"):Destroy() end
        local s = drive(m, m.vector(1000, 0, 0))
        assert(s.engine.status.jobs.problem and #m.calls == 0)
        assert(m.controls.enables == 0 and m.controls.disables == 0)
        s.destroy(); assert(m.controls.enables == 0)
    end
end)
test("phase and world changes release steering immediately", function()
    for _, mode in ipairs({ "phase", "world", "death" }) do
        local m = Mock.new()
        local s = drive(m, m.vector(1000, 0, 0))
        if mode == "phase" then m.phase = "idle"
        elseif mode == "world" then m.player.Character:SetAttribute("PlayerState", "Race")
        else humanoid(m).Health = 0 end
        m.render(1/60)
        assert(m.controls.controlsEnabled and humanoid(m).MoveDirection.Magnitude == 0)
        assert(#m.calls == 0)
        s.destroy()
    end
end)
test("claimed phase leaves the pad using input and ignores stale drop points", function()
    local m = Mock.new()
    m.phase, m.legCount = "claimed", 3
    local s = drive(m, m.vector(12920, 0, 0))
    assert(humanoid(m).MoveDirection.Z == -1 and humanoid(m).MoveDirection.X == 0)
    assert(#m.pivots == 0 and #m.calls == 0)
    m.phase = "running"; m.tick(0.5)
    assert(humanoid(m).MoveDirection.X == 1 and humanoid(m).MoveDirection.Z == 0)
    advance(m, 1, 3); assert(#m.calls == 0)
    s.destroy()
end)
test("a job stuck in claimed automatically replans departure", function()
    local m = Mock.new()
    m.phase, m.legCount = "claimed", 3
    local s = drive(m, m.vector(12920, 0, 0))
    advance(m, 0.5, 13)
    assert(m.controls.controlsEnabled and #m.calls == 0)
    advance(m, 13.5, 20)
    assert(#m.pathRequests >= 1 and not m.controls.controlsEnabled)
    assert(m.pathRequests[1].destination.Z == -24 and #m.calls == 0)
    s.destroy()
end)
test("delivery waits for RunWorld before acquiring input", function()
    local m = Mock.new()
    m.player.Character:SetAttribute("PlayerState", "Lobby")
    local s = drive(m, m.vector(1000, 0, 0))
    advance(m, 0.5, 2)
    assert(m.controls.disables == 0 and #m.calls == 0)
    m.player.Character:SetAttribute("PlayerState", "RunWorld"); m.tick(2.5)
    assert(not m.controls.controlsEnabled and humanoid(m).MoveDirection.X == 1)
    s.destroy()
end)
test("idle ignores stale destinations and claiming waits for actual board proximity", function()
    local m = Mock.new()
    m.phase, m.legCount = "idle", 0
    place(m, 1000)
    local s = drive(m, m.vector(12920, 0, 0))
    advance(m, 0.5, 6)
    assert(humanoid(m).MoveDirection.X == -1 and #m.calls == 1)
    assert(m.calls[1].name == "ReturnToSpawn")
    place(m, 5); m.tick(6.5); m.tick(7.5)
    assert(#m.calls == 2 and m.calls[2].name == "ClaimJob")
    assert(m.calls[2].args[1] == 3 and m.controls.controlsEnabled)
    s.destroy()
end)
test("moving away from the board during the claim delay prevents a remote claim", function()
    local m = Mock.new()
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver"); m.tick(0)
    place(m, 500); advance(m, 1, 7)
    assert(m.calls[1].name == "ReturnToSpawn" and #m.calls == 1)
    assert(humanoid(m).MoveDirection.X == -1)
    s.destroy()
end)
test("new delivery waypoints reset arrival attempts and never start another claim", function()
    local m = Mock.new()
    local s = drive(m, m.vector(20, 0, 0))
    advance(m, 0.5, 2)
    assert(m.calls[1].name == "ReportJobArrival")
    m.drop = m.vector(-1000, 0, 0)
    m.tick(2.5)
    assert(humanoid(m).MoveDirection.X == -1 and s.engine.jobs.travel.attempts == 0)
    advance(m, 3, 6)
    assert(#m.calls == 1 and s.engine.deliveries == 0)
    s.destroy()
end)
test("unconfirmed arrival waits before retrying a closer approach automatically", function()
    local m = Mock.new()
    local s = drive(m, m.vector(20, 0, 0))
    advance(m, 0.5, 20)
    assert(#m.calls == 5 and m.controls.controlsEnabled)
    local disables = m.controls.disables
    place(m, -100); advance(m, 20.5, 23)
    assert(m.controls.disables == disables and #m.calls == 5)
    advance(m, 23.5, 25)
    assert(#m.pathRequests >= 1 and not m.controls.controlsEnabled and #m.calls == 5)
    s.destroy()
end)
test("two complete four-job chains fill, deliver, return, collect and repeat without manual input", function()
    local m = Mock.new()
    m.player:SetAttribute("Ascensions", 25)
    m.simulateMovement = true
    m.legCount, m.banked, m.phase = 0, 0, "idle"
    local claimCount, returns, payouts = 0, 0, 0
    local destinations = { m.vector(500, 0, 0), m.vector(800, 0, 100), m.vector(1200, 0, -100), m.vector(2000, 0, 0) }
    m.onRemote = function(name, args)
        if name == "ClaimJob" then
            assert(root(m).Position.Magnitude <= 10 and m.legCount < 4)
            assert(args[1] == 9, "Did not choose the highest-paying eligible tier")
            assert(#args == 2 and args[2] == 2)
            if m.legCount > 0 then assert(m.phase == "claimed") end
            claimCount += 1
            m.legCount += 1
            m.legIndex, m.phase, m.delivered = 1, "claimed", false
        elseif name == "ReportJobArrival" then
            assert(m.phase == "running" and (root(m).Position - m.drop).Magnitude <= 50)
            m.banked += 1
            if m.banked == 4 then
                m.drop, m.phase, m.delivered = nil, "claimed", true
            else
                m.legIndex += 1
                m.drop = destinations[m.legIndex]
            end
        elseif name == "ReturnToSpawn" then
            assert(m.banked == 4, "Returned before the chain was complete")
            returns += 1
            place(m, 20)
            m.player.Character:SetAttribute("PlayerState", "Main")
        elseif name == "CollectJob" then
            assert(m.banked == 4 and root(m).Position.Magnitude <= 10)
            payouts += 1
            m.legCount, m.banked, m.phase, m.delivered = 0, 0, "idle", false
        else
            error("Unexpected request: " .. name)
        end
    end
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver")
    for _ = 1, 90 * 60 do
        m.frame(1/60)
        if m.phase == "claimed" and m.legCount == 4 and m.banked == 0 and root(m).Position.Magnitude > 8 then
            m.phase, m.drop = "running", destinations[1]
            m.player.Character:SetAttribute("PlayerState", "RunWorld")
        end
        if s.engine.deliveries == 8 then break end
    end
    assert(s.engine.deliveries == 8, s.engine.status.jobs.text)
    assert(claimCount == 8 and returns == 2 and payouts == 2)
    assert(#m.pivots == 0 and #m.walks == 0)
    s.destroy()
end)
test("route recovery follows a detour and issues native jump input", function()
    local m = Mock.new()
    m.pathWaypoints = function(origin, destination)
        return {
            { Position = origin },
            { Position = origin + m.vector(0, 0, 10), Action = m.environment.Enum.PathWaypointAction.Jump },
            { Position = destination },
        }
    end
    local s = drive(m, m.vector(1000, 0, 0))
    advance(m, 0.5, 15)
    assert(#m.pathRequests == 1)
    assert(humanoid(m).MoveDirection.X == 0 and humanoid(m).MoveDirection.Z == 1)
    assert(humanoid(m).Jump == true)
    m.paths[1].Blocked:Fire(2)
    m.render(1/60)
    assert(m.paths[1].destroyed and #m.pathRequests == 2)
    s.destroy()
end)
test("a failed navigation query retries without manual input", function()
    local m = Mock.new()
    m.pathStatus = "PathStatus.NoPath"
    local s = drive(m, m.vector(1000, 0, 0))
    advance(m, 0.5, 15)
    assert(humanoid(m).MoveDirection.Magnitude == 0 and #m.pathRequests == 1)
    advance(m, 15.5, 17.5)
    assert(#m.pathRequests == 1)
    m.pathStatus = nil
    m.tick(18)
    assert(#m.pathRequests == 2 and humanoid(m).MoveDirection.X == 1)
    s.destroy()
end)
test("stopping and changing destinations cancel pending navigation computations", function()
    for _, action in ipairs({ "stop", "target", "close" }) do
        local m = Mock.new()
        m.pathYield = true
        local s = drive(m, m.vector(1000, 0, 0))
        advance(m, 0.5, 15)
        local pending, path = m.pathThread, m.paths[1]
        assert(coroutine.status(pending) == "suspended")
        if action == "stop" then m.find("Stop all").Activated:Fire()
        elseif action == "target" then m.drop = m.vector(0, 0, 1000); m.tick(15.5)
        else s.destroy() end
        assert(coroutine.status(pending) == "dead" and path.destroyed)
        assert(not coroutine.resume(pending))
        if action ~= "target" then assert(m.controls.controlsEnabled) end
        s.destroy()
    end
end)
test("new snapshot events cannot be overwritten by an older yielding snapshot request", function()
    local m = Mock.new()
    m.snapshotYield = true
    local s = drive(m, m.vector(1000, 0, 0))
    assert(s.engine.status.jobs.problem and #m.calls == 0)
    m.legCount, m.phase, m.drop = 4, "claimed", nil
    m.publishSnapshot()
    assert(coroutine.resume(m.snapshotThread))
    m.tick(1)
    assert(s.engine.jobState.legCount == 4 and not s.engine.status.jobs.problem)
    assert(#m.calls == 0)
    s.destroy()
end)
test("closing cancels snapshot loading and preserves manual controls", function()
    local m = Mock.new()
    m.snapshotYield = true
    local s = drive(m, m.vector(1000, 0, 0))
    local pending = m.snapshotThread
    s.destroy()
    assert(coroutine.status(pending) == "dead" and m.controls.controlsEnabled)
    assert(activeConnections(m) == 0)
end)
test("unacknowledged payout is never counted and uses fresh state before retry", function()
    local m = Mock.new()
    m.legCount, m.banked, m.legIndex, m.phase, m.delivered = 4, 4, 4, "claimed", true
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver"); advance(m, 0, 9)
    assert(#m.calls == 1 and m.calls[1].name == "CollectJob" and s.engine.deliveries == 0)
    local snapshots = m.snapshotRequests
    advance(m, 9.5, 11)
    assert(m.snapshotRequests > snapshots and #m.calls == 2)
    assert(s.engine.deliveries == 0 and m.calls[2].name == "CollectJob")
    s.destroy()
end)
test("a timed-out navigation computation is canceled before replanning", function()
    local m = Mock.new()
    m.pathYield = true
    local s = drive(m, m.vector(1000, 0, 0))
    advance(m, 0.5, 15)
    local first = m.pathThread
    advance(m, 15.5, 23)
    assert(coroutine.status(first) == "dead" and m.paths[1].destroyed)
    assert(#m.pathRequests == 2 and coroutine.status(m.pathThread) == "suspended")
    s.destroy()
    assert(coroutine.status(m.pathThread) == "dead")
end)
test("board recovery survives a Return to Spawn request that leaves the character in place", function()
    local m = Mock.new()
    place(m, 1000)
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver")
    advance(m, 0, 24.5)
    assert(#m.calls == 2 and m.calls[1].name == "ReturnToSpawn" and m.calls[2].name == "ReturnToSpawn")
    assert(#m.pathRequests == 0, "A route started before the return grace period ended")
    m.tick(25)
    assert(#m.pathRequests == 1, "Return to Spawn discarded the route recovery")
    assert(humanoid(m).MoveDirection.X == -1)
    s.destroy()
end)
test("board recovery plans from the position acknowledged by Return to Spawn", function()
    local m = Mock.new()
    place(m, 1000)
    local returns = 0
    m.onRemote = function(name)
        if name == "ReturnToSpawn" then
            returns += 1
            if returns == 2 then place(m, 300) end
        end
    end
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver"); advance(m, 0, 20.5)
    assert(returns == 2 and #m.pathRequests == 1)
    assert(m.pathRequests[1].origin.X == 300 and m.pathRequests[1].destination.X < 300)
    assert(humanoid(m).MoveDirection.X == -1)
    s.destroy()
end)
test("Stop all cancels route recovery deferred until after a spawn wait", function()
    local m = Mock.new()
    place(m, 1000)
    local s = m.load(BUNDLE)
    m.toggle("Auto job & deliver"); advance(m, 0, 21)
    assert(#m.calls == 2 and #m.pathRequests == 0)
    m.find("Stop all").Activated:Fire()
    advance(m, 21.5, 40)
    assert(#m.calls == 2 and #m.pathRequests == 0 and m.controls.controlsEnabled)
    s.destroy()
end)
test("all unlocked slots retain the job type required by the successful first claim", function()
    for _, case in ipairs({ { ascensions = 10, slots = 3, tier = 3, jobType = 1 },
        { ascensions = 25, slots = 4, tier = 9, jobType = 2 },
        { ascensions = 25, slots = 4, tier = 9, jobType = 2, accepted = 1 },
        { ascensions = 75, slots = 4, tier = 4, jobType = 1 } }) do
        local m = Mock.new()
        m.player:SetAttribute("Ascensions", case.ascensions)
        m.legCount, m.banked = case.accepted or 0, 0
        m.phase = m.legCount > 0 and "claimed" or "idle"
        m.onRemote = function(name, args)
            if name ~= "ClaimJob" then return end
            assert(root(m).Position.Magnitude <= 10)
            -- Model a server that accepts the first request but rejects missing jobType.
            if args[1] ~= case.tier or args[2] ~= case.jobType then return end
            assert(m.legCount < case.slots, "Claim exceeded the unlocked chain capacity")
            m.legCount += 1
            m.legIndex, m.phase, m.delivered = 1, "claimed", false
        end
        local s = m.load(BUNDLE)
        m.toggle("Auto job & deliver"); advance(m, 0, 8)
        assert(m.legCount == case.slots, string.format("Only %d/%d slots accepted: %s", m.legCount, case.slots, s.engine.status.jobs.text))
        assert(s.engine.jobState.legCount == case.slots)
        assert(#m.calls == case.slots - (case.accepted or 0), "Existing accepted jobs were claimed again")
        for _, call in ipairs(m.calls) do
            assert(call.name == "ClaimJob" and call.args[1] == case.tier and call.args[2] == case.jobType)
        end
        s.destroy()
    end
end)
print(string.format("%d UI/adapter tests passed (mock Roblox API)", passed))
