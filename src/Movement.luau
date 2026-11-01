-- Direction input for the game's RunWorld momentum controller; no position/velocity writes.
local Movement = {}
Movement.STOP_RADIUS = 35 -- Leave margin inside the game's 50-stud arrival radius.

function Movement.steer(dx, dy, dz, vx, vz, dt, stopRadius)
    stopRadius = stopRadius or Movement.STOP_RADIUS
    for _, value in ipairs({ dx, dy, dz, vx, vz, dt, stopRadius }) do
        assert(type(value) == "number" and value == value and math.abs(value) < math.huge, "Invalid movement sample")
    end
    local horizontal = math.sqrt(dx * dx + dz * dz)
    local distance = math.sqrt(horizontal * horizontal + dy * dy)
    if distance <= stopRadius then return 0, 0, "holding" end
    if horizontal < 1 then return 0, 0, "vertical" end
    local speed = math.sqrt(vx * vx + vz * vz)
    local horizontalStop = math.sqrt(math.max(0, stopRadius ^ 2 - dy * dy))
    local remaining = horizontal - horizontalStop
    -- The supplied worldMomentumStep clears its ramp when MoveDirection is zero.
    -- Brake before a high-speed frame can skip the entire arrival area.
    if speed > 1 and speed * math.max(dt, 1 / 240) + 8 >= remaining then
        return 0, 0, "braking"
    end
    return dx / horizontal, dz / horizontal, "moving"
end

return Movement
