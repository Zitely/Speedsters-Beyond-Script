-- A deliberately small Roblox API double for wiring/lifecycle tests, not a game simulator.
local Mock = {}
function Mock.new()
    local mock = { shared = {}, clock = 0, calls = {}, connections = {}, warnings = {} }
    local function signal()
        local result = { listeners = {} }
        function result:Connect(callback)
            local connection = { Connected = true, callback = callback }
            function connection:Disconnect() self.Connected = false end
            table.insert(self.listeners, connection)
            table.insert(mock.connections, connection)
            return connection
        end
        function result:Fire(...)
            local snapshot = table.clone(self.listeners)
            for _, connection in ipairs(snapshot) do
                if connection.Connected then connection.callback(...) end
            end
        end
        return result
    end
    local vector = {}
    local function v(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, kind = z == nil and "Vector2" or "Vector3" }, vector) end
    vector.__add = function(a, b) return v(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
    vector.__sub = function(a, b) return v(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
    vector.__div = function(a, b) return v(a.X / b, a.Y / b, a.Z / b) end
    vector.__index = function(a, key) if key == "Magnitude" then return math.sqrt(a.X ^ 2 + a.Y ^ 2 + a.Z ^ 2) end end
    local cf = {}
    cf.__add = function(a, b) return setmetatable({ Position = a.Position + b, kind = "CFrame" }, cf) end
    local function cframe(value) return setmetatable({ Position = value or v(0, 0, 0), kind = "CFrame" }, cf) end
    local function udim(scale, offset) return { Scale = scale, Offset = offset } end
    local function size(xs, xo, ys, yo) return { X = udim(xs, xo), Y = udim(ys, yo) } end
    local eventNames = { Activated = true, MouseEnter = true, MouseLeave = true, InputBegan = true, InputChanged = true, InputEnded = true, Idled = true, CharacterAdded = true, DescendantAdded = true, DescendantRemoving = true, Heartbeat = true, Destroying = true, Event = true }
    local methods = {}
    local instanceMt = {}
    instanceMt.__index = function(self, key)
        if methods[key] then return methods[key] end
        if key == "Position" and self:IsA("BasePart") then return self.CFrame.Position end
        if key == "AbsolutePosition" then return v(500, 0) end
        if eventNames[key] then
            self._signals[key] = self._signals[key] or signal()
            return self._signals[key]
        end
        return self._props[key]
    end
    instanceMt.__newindex = function(self, key, value)
        if key == "Parent" then
            local old = self._props.Parent
            if old then
                local index = table.find(old._children, self)
                if index then table.remove(old._children, index) end
            end
            if value then table.insert(value._children, self) end
        end
        self._props[key] = value
        if self._signals[key .. "Changed"] then self._signals[key .. "Changed"]:Fire() end
    end
    function methods:IsA(class)
        return self.ClassName == class or class == "BasePart" and self.ClassName == "Part"
    end
    function methods:GetChildren() return table.clone(self._children) end
    function methods:GetDescendants()
        local result = {}
        for _, child in ipairs(self._children) do
            table.insert(result, child)
            for _, nested in ipairs(child:GetDescendants()) do table.insert(result, nested) end
        end
        return result
    end
    function methods:FindFirstChild(name)
        for _, child in ipairs(self._children) do if child.Name == name then return child end end
    end
    methods.WaitForChild = methods.FindFirstChild
    function methods:FindFirstChildOfClass(class)
        for _, child in ipairs(self._children) do if child:IsA(class) then return child end end
    end
    function methods:FindFirstChildWhichIsA(class, recursive)
        for _, child in ipairs(recursive and self:GetDescendants() or self._children) do if child:IsA(class) then return child end end
    end
    function methods:GetPropertyChangedSignal(key)
        self._signals[key .. "Changed"] = self._signals[key .. "Changed"] or signal()
        return self._signals[key .. "Changed"]
    end
    function methods:IsDescendantOf(parent)
        local node = self.Parent
        while node do if node == parent then return true end; node = node.Parent end
        return false
    end
    function methods:Destroy()
        if self._props.destroyed then return end
        self._props.destroyed = true
        self.Destroying:Fire()
        for _, child in ipairs(self:GetChildren()) do child:Destroy() end
        for _, event in pairs(self._signals) do
            for _, connection in ipairs(event.listeners) do connection:Disconnect() end
        end
        self.Parent = nil
    end
    function methods:Fire(...) self.Event:Fire(...) end
    function methods:FireServer(...)
        table.insert(mock.calls, { name = self.Name, args = { ... } })
    end
    function methods:GetPivot() return self:FindFirstChildWhichIsA("BasePart", true).CFrame end
    local function instance(class, name, parent)
        local item = setmetatable({ _props = { ClassName = class, Name = name or class, Visible = true, Position = size(0, 0, 0, 0), CFrame = cframe(), Health = 100 }, _children = {}, _signals = {} }, instanceMt)
        item.Parent = parent
        return item
    end
    local workspace = instance("Workspace")
    workspace.CurrentCamera = instance("Camera")
    workspace.CurrentCamera.ViewportSize = v(1200, 800)
    local player = instance("Player")
    local playerGui = instance("PlayerGui", "PlayerGui", player)
    player.Character = instance("Model")
    instance("Part", "HumanoidRootPart", player.Character)
    instance("Humanoid", "Humanoid", player.Character)
    local scripts = instance("Folder", "PlayerScripts", player)
    local controllers = instance("Folder", "Controllers", scripts)
    local module = instance("ModuleScript", "JobsController", controllers)
    module.value = { GetDropPoint = function() return mock.drop end }
    local replicated = instance("ReplicatedStorage")
    local remotes = instance("Folder", "Remotes", replicated)
    for _, name in ipairs({ "ChargeStart", "ChargeBurst", "ClaimJob", "ReportJobArrival", "CollectJob", "OrbCollect", "ResetRace", "AscendRequest", "BuyUpgrade" }) do instance("RemoteEvent", name, remotes) end
    local treadmills = instance("Folder", "Treadmills", workspace)
    instance("Part", "x10", treadmills)
    instance("Model", "x20", treadmills)
    instance("Part", "JobsPart", workspace)
    local services = {
        Players = { LocalPlayer = player }, ReplicatedStorage = replicated,
        CoreGui = instance("CoreGui"), UserInputService = instance("Input"), RunService = instance("RunService"),
        VirtualUser = { CaptureController = function() end, ClickButton2 = function() mock.idleCount = (mock.idleCount or 0) + 1 end },
        TweenService = { Create = function(_, object, _, props)
            return { Cancel = function() end, Play = function() for k, value in pairs(props) do object[k] = value end end }
        end },
    }
    function services.UserInputService:GetFocusedTextBox() return nil end
    local enum = setmetatable({}, { __index = function(self, key)
        local group = setmetatable({}, { __index = function(_, member) return key .. "." .. member end })
        rawset(self, key, group)
        return group
    end })
    local env = setmetatable({
        game = { GetService = function(_, name) assert(services[name], name); return services[name] end },
        workspace = workspace, Instance = { new = instance }, Enum = enum,
        Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end },
        ColorSequence = { new = function(...) return { ... } end },
        TweenInfo = { new = function(...) return { ... } end },
        UDim = { new = udim }, UDim2 = { new = size, fromOffset = function(x, y) return size(0, x, 0, y) end, fromScale = function(x, y) return size(x, 0, y, 0) end },
        Vector2 = { new = v, zero = v(0, 0) }, Vector3 = { new = v, zero = v(0, 0, 0) }, CFrame = { new = cframe },
        typeof = function(value) return type(value) == "table" and (value.kind or (value._props and "Instance")) or type(value) end,
        getgenv = function() return mock.shared end,
        os = { clock = function() return mock.clock end },
        require = function(target) return target.value end,
        warn = function(message) table.insert(mock.warnings, message) end,
        task = { spawn = function(callback)
            local thread = coroutine.create(callback)
            local success, err = coroutine.resume(thread)
            assert(success, err)
            return thread
        end, cancel = coroutine.close },
    }, { __index = getfenv() })
    mock.environment, mock.services, mock.workspace, mock.player = env, services, workspace, player
    mock.instance, mock.vector = instance, v
    function mock.load(source)
        local chunk, err = loadstring(source, "SpeedstersBeyond.lua")
        assert(chunk, err)
        setfenv(chunk, env)
        return chunk()
    end
    function mock.find(text, class)
        for _, object in ipairs(services.CoreGui:GetDescendants()) do
            if (object.Text == text or object.Name == text) and (not class or object:IsA(class)) then return object end
        end
        error("UI object not found: " .. text)
    end
    function mock.toggle(title)
        local titleLabel = mock.find(title, "TextLabel")
        titleLabel.Parent:FindFirstChildOfClass("TextButton").Activated:Fire()
    end
    function mock.tick(now)
        mock.clock = now
        services.RunService.Heartbeat:Fire(0.2)
    end
    return mock
end
return Mock
