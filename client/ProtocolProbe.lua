--[[
    Draw Me - Drawing Protocol Probe
    --------------------------------
    This DOES NOT move the mouse or auto-click anything.

    Purpose:
      Capture the internal RemoteEvent / RemoteFunction / Bindable calls
      that Draw Me makes while you perform ONE tiny manual test stroke.

    Usage:
      1. Execute this script in Draw Me.
      2. Press START CAPTURE.
      3. Pick a color manually, then draw ONE short line/squiggle.
      4. Press STOP + COPY REPORT.
      5. Paste the report back into ChatGPT.

    The final painter will use the discovered drawing protocol directly
    instead of mouse simulation.
]]

local ENV = (getgenv and getgenv()) or _G

if ENV.__DRAW_ME_PROTOCOL_PROBE and ENV.__DRAW_ME_PROTOCOL_PROBE.Destroy then
    pcall(ENV.__DRAW_ME_PROTOCOL_PROBE.Destroy)
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local MAX_RECORDS = 2500
local MAX_TABLE_DEPTH = 5
local MAX_TABLE_ITEMS = 40
local MAX_STRING = 240

local State = {
    capturing = false,
    destroyed = false,
    records = {},
    startedAt = 0,
    originalNamecall = nil,
    hookInstalled = false,
}

local function now()
    return os.clock()
end

local function safePath(instance)
    if typeof(instance) ~= "Instance" then
        return tostring(instance)
    end

    local parts = {}
    local current = instance

    while current and current ~= game do
        table.insert(parts, 1, current.Name)
        current = current.Parent

        if #parts > 20 then
            break
        end
    end

    return "game." .. table.concat(parts, ".")
end

local function shortString(value)
    value = tostring(value)

    if #value > MAX_STRING then
        return value:sub(1, MAX_STRING) .. "...<truncated>"
    end

    return value
end

local function serialize(value, depth, seen)
    depth = depth or 0
    seen = seen or {}

    local valueType = typeof(value)

    if valueType == "nil" then
        return { type = "nil" }
    elseif valueType == "boolean" or valueType == "number" then
        return {
            type = valueType,
            value = value,
        }
    elseif valueType == "string" then
        return {
            type = "string",
            value = shortString(value),
        }
    elseif valueType == "Vector2" then
        return {
            type = "Vector2",
            x = value.X,
            y = value.Y,
        }
    elseif valueType == "Vector3" then
        return {
            type = "Vector3",
            x = value.X,
            y = value.Y,
            z = value.Z,
        }
    elseif valueType == "Color3" then
        return {
            type = "Color3",
            r = value.R,
            g = value.G,
            b = value.B,
            r255 = math.floor(value.R * 255 + 0.5),
            g255 = math.floor(value.G * 255 + 0.5),
            b255 = math.floor(value.B * 255 + 0.5),
        }
    elseif valueType == "UDim" then
        return {
            type = "UDim",
            scale = value.Scale,
            offset = value.Offset,
        }
    elseif valueType == "UDim2" then
        return {
            type = "UDim2",
            xScale = value.X.Scale,
            xOffset = value.X.Offset,
            yScale = value.Y.Scale,
            yOffset = value.Y.Offset,
        }
    elseif valueType == "CFrame" then
        local components = { value:GetComponents() }
        return {
            type = "CFrame",
            components = components,
        }
    elseif valueType == "BrickColor" then
        return {
            type = "BrickColor",
            name = value.Name,
            number = value.Number,
            color = serialize(value.Color, depth + 1, seen),
        }
    elseif valueType == "EnumItem" then
        return {
            type = "EnumItem",
            value = tostring(value),
        }
    elseif valueType == "Instance" then
        return {
            type = "Instance",
            class = value.ClassName,
            name = value.Name,
            path = safePath(value),
        }
    elseif valueType == "table" then
        if depth >= MAX_TABLE_DEPTH then
            return {
                type = "table",
                truncated = "depth",
            }
        end

        if seen[value] then
            return {
                type = "table",
                circular = true,
            }
        end

        seen[value] = true

        local out = {
            type = "table",
            entries = {},
        }

        local count = 0

        for key, child in pairs(value) do
            count += 1

            if count > MAX_TABLE_ITEMS then
                out.truncated = "items"
                break
            end

            table.insert(out.entries, {
                key = serialize(key, depth + 1, seen),
                value = serialize(child, depth + 1, seen),
            })
        end

        seen[value] = nil
        return out
    end

    return {
        type = valueType,
        value = shortString(value),
    }
end

local function currentMouse()
    local ok, pos = pcall(function()
        return UserInputService:GetMouseLocation()
    end)

    if ok and pos then
        return {
            x = pos.X,
            y = pos.Y,
        }
    end

    return nil
end

local function recordCall(instance, method, args)
    if not State.capturing then
        return
    end

    if #State.records >= MAX_RECORDS then
        State.capturing = false
        return
    end

    local serializedArgs = {}

    for index = 1, args.n do
        serializedArgs[index] = serialize(args[index])
    end

    table.insert(State.records, {
        t = now() - State.startedAt,
        method = method,
        class = instance.ClassName,
        name = instance.Name,
        path = safePath(instance),
        mouse = currentMouse(),
        args = serializedArgs,
    })
end

local function shouldCapture(instance, method)
    if typeof(instance) ~= "Instance" then
        return false
    end

    if method == "FireServer" and instance:IsA("RemoteEvent") then
        return true
    end

    if method == "InvokeServer" and instance:IsA("RemoteFunction") then
        return true
    end

    -- Bindables are useful if the game routes strokes through a local
    -- controller before network replication.
    if method == "Fire" and instance:IsA("BindableEvent") then
        return true
    end

    if method == "Invoke" and instance:IsA("BindableFunction") then
        return true
    end

    return false
end

local function installHook()
    if State.hookInstalled then
        return true
    end

    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        return false, "Velocity does not expose hookmetamethod/getnamecallmethod in this environment."
    end

    local oldNamecall

    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()

        if State.capturing and shouldCapture(self, method) then
            local packed = table.pack(...)

            -- Capture outside of the game's own call path as lightly as possible.
            pcall(recordCall, self, method, packed)
        end

        return oldNamecall(self, ...)
    end)

    State.originalNamecall = oldNamecall
    State.hookInstalled = true
    return true
end

local function summarize()
    local groups = {}

    for _, record in ipairs(State.records) do
        local key = record.method .. " | " .. record.path

        local group = groups[key]

        if not group then
            group = {
                method = record.method,
                class = record.class,
                name = record.name,
                path = record.path,
                count = 0,
                first = record.t,
                last = record.t,
                samples = {},
            }

            groups[key] = group
        end

        group.count += 1
        group.last = record.t

        if #group.samples < 8 then
            table.insert(group.samples, record)
        end
    end

    local list = {}

    for _, group in pairs(groups) do
        table.insert(list, group)
    end

    table.sort(list, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end

        return a.path < b.path
    end)

    return list
end

local function buildReport()
    local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize

    local report = {
        probe = "DrawMeProtocolProbe",
        version = 1,
        placeId = game.PlaceId,
        gameId = game.GameId,
        userId = LocalPlayer and LocalPlayer.UserId or nil,
        viewport = viewport and {
            x = viewport.X,
            y = viewport.Y,
        } or nil,
        duration = State.startedAt > 0 and (now() - State.startedAt) or 0,
        totalRecords = #State.records,
        groups = summarize(),
    }

    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(report)
    end)

    if not ok then
        return "-- JSON encoding failed; raw summary follows\n" .. tostring(encoded)
    end

    return encoded
end

-- UI ------------------------------------------------------------------------

local parent

do
    local ok, result = pcall(function()
        if type(gethui) == "function" then
            return gethui()
        end
    end)

    parent = ok and result or CoreGui
end

local gui = Instance.new("ScreenGui")
gui.Name = "DrawMeProtocolProbe"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 2147483647
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parent

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(430, 238)
frame.Position = UDim2.new(0.5, -215, 0, 86)
frame.BackgroundColor3 = Color3.fromRGB(18, 21, 29)
frame.BorderSizePixel = 0
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = frame

local border = Instance.new("UIStroke")
border.Color = Color3.fromRGB(62, 152, 255)
border.Thickness = 1.5
border.Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(16, 10)
title.Size = UDim2.new(1, -56, 0, 28)
title.Font = Enum.Font.GothamBold
title.Text = "Draw Me • Protocol Probe"
title.TextColor3 = Color3.fromRGB(245, 248, 255)
title.TextSize = 19
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local close = Instance.new("TextButton")
close.BackgroundTransparency = 1
close.Position = UDim2.new(1, -42, 0, 5)
close.Size = UDim2.fromOffset(34, 34)
close.Font = Enum.Font.GothamBold
close.Text = "×"
close.TextColor3 = Color3.fromRGB(160, 170, 190)
close.TextSize = 25
close.Parent = frame

local instructions = Instance.new("TextLabel")
instructions.BackgroundTransparency = 1
instructions.Position = UDim2.fromOffset(16, 48)
instructions.Size = UDim2.new(1, -32, 0, 66)
instructions.Font = Enum.Font.Gotham
instructions.Text =
    "1. START CAPTURE\n" ..
    "2. Manually choose a color, then draw ONE short stroke\n" ..
    "3. STOP + COPY REPORT"
instructions.TextColor3 = Color3.fromRGB(186, 194, 211)
instructions.TextSize = 13
instructions.TextWrapped = true
instructions.TextXAlignment = Enum.TextXAlignment.Left
instructions.TextYAlignment = Enum.TextYAlignment.Top
instructions.Parent = frame

local startButton = Instance.new("TextButton")
startButton.Position = UDim2.fromOffset(16, 124)
startButton.Size = UDim2.fromOffset(190, 42)
startButton.BackgroundColor3 = Color3.fromRGB(45, 145, 255)
startButton.BorderSizePixel = 0
startButton.Font = Enum.Font.GothamBold
startButton.Text = "START CAPTURE"
startButton.TextColor3 = Color3.new(1, 1, 1)
startButton.TextSize = 14
startButton.Parent = frame

local startCorner = Instance.new("UICorner")
startCorner.CornerRadius = UDim.new(0, 9)
startCorner.Parent = startButton

local stopButton = Instance.new("TextButton")
stopButton.Position = UDim2.fromOffset(216, 124)
stopButton.Size = UDim2.new(1, -232, 0, 42)
stopButton.BackgroundColor3 = Color3.fromRGB(91, 98, 118)
stopButton.BorderSizePixel = 0
stopButton.Font = Enum.Font.GothamBold
stopButton.Text = "STOP + COPY REPORT"
stopButton.TextColor3 = Color3.new(1, 1, 1)
stopButton.TextSize = 13
stopButton.Parent = frame

local stopCorner = Instance.new("UICorner")
stopCorner.CornerRadius = UDim.new(0, 9)
stopCorner.Parent = stopButton

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.fromOffset(16, 178)
status.Size = UDim2.new(1, -32, 0, 46)
status.Font = Enum.Font.Gotham
status.Text = "Idle. No mouse automation is used."
status.TextColor3 = Color3.fromRGB(137, 147, 167)
status.TextSize = 12
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = frame

local function setStatus(text, color)
    status.Text = text
    status.TextColor3 = color or Color3.fromRGB(137, 147, 167)
end

local hookOk, hookError = installHook()

if not hookOk then
    setStatus(
        "Hook unavailable: " .. tostring(hookError),
        Color3.fromRGB(255, 105, 122)
    )
    startButton.Active = false
    startButton.AutoButtonColor = false
    startButton.BackgroundColor3 = Color3.fromRGB(75, 78, 90)
end

startButton.MouseButton1Click:Connect(function()
    if not hookOk then
        return
    end

    State.records = {}
    State.startedAt = now()
    State.capturing = true

    startButton.Text = "CAPTURING…"
    startButton.BackgroundColor3 = Color3.fromRGB(70, 197, 126)
    stopButton.BackgroundColor3 = Color3.fromRGB(237, 72, 92)

    setStatus(
        "Recording internal calls. Change color once and draw one short stroke now.",
        Color3.fromRGB(105, 218, 154)
    )
end)

local function copyReport()
    State.capturing = false

    startButton.Text = "START CAPTURE"
    startButton.BackgroundColor3 = Color3.fromRGB(45, 145, 255)
    stopButton.BackgroundColor3 = Color3.fromRGB(91, 98, 118)

    local report = buildReport()

    local copied = false

    if type(setclipboard) == "function" then
        local ok = pcall(setclipboard, report)
        copied = ok
    elseif type(toclipboard) == "function" then
        local ok = pcall(toclipboard, report)
        copied = ok
    end

    if type(writefile) == "function" then
        pcall(
            writefile,
            "draw_me_protocol_report.json",
            report
        )
    end

    print("\n========== DRAW ME PROTOCOL REPORT ==========")
    print(report)
    print("========== END DRAW ME PROTOCOL REPORT ======\n")

    if copied then
        setStatus(
            string.format(
                "Captured %d calls. Report copied to clipboard. Paste it into ChatGPT.",
                #State.records
            ),
            Color3.fromRGB(105, 218, 154)
        )
    else
        setStatus(
            string.format(
                "Captured %d calls. Clipboard API unavailable; copy the report from the console.",
                #State.records
            ),
            Color3.fromRGB(255, 190, 95)
        )
    end
end

stopButton.MouseButton1Click:Connect(copyReport)

local function destroy()
    State.capturing = false
    State.destroyed = true

    if gui then
        gui:Destroy()
    end

    if ENV.__DRAW_ME_PROTOCOL_PROBE == State then
        ENV.__DRAW_ME_PROTOCOL_PROBE = nil
    end
end

close.MouseButton1Click:Connect(destroy)

State.Stop = copyReport
State.Destroy = destroy
State.GetReport = buildReport
State.GetRecords = function()
    return State.records
end

ENV.__DRAW_ME_PROTOCOL_PROBE = State
ENV.DrawMeProtocolProbe = State

print("[Draw Me Protocol Probe] Loaded.")
print("[Draw Me Protocol Probe] This script does not move or click the mouse.")
