--[[
    Draw Me Auto Painter
    Client for https://draw-me-iota.vercel.app

    Designed around the fixed Draw Me UI shown in the calibration screenshots.
    Reference viewport: 1149 x 941
    Canvas interior: x=345..1129, y=42..826

    Controls:
      - Paste a direct raster image URL
      - DRAW starts processing + painting
      - STOP or RightShift cancels immediately

    The script paints using the game's actual brush/color picker.
]]

local ENV = (getgenv and getgenv()) or _G

-- Kill an older copy cleanly if this script is executed twice.
if ENV.__DRAW_ME_PAINTER and ENV.__DRAW_ME_PAINTER.Destroy then
    pcall(ENV.__DRAW_ME_PAINTER.Destroy)
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local CONFIG = {
    SERVER = "https://draw-me-iota.vercel.app",

    -- Calibration screenshot dimensions.
    REF_W = 1149,
    REF_H = 941,

    -- White drawing area, excluding the border.
    CANVAS_LEFT = 345,
    CANVAS_TOP = 42,
    CANVAS_RIGHT = 1129,
    CANVAS_BOTTOM = 826,

    -- Hue wheel.
    HUE_CX = 148,
    HUE_CY = 179,
    HUE_RADIUS = 105,

    -- Saturation/value square.
    -- This picker is reversed horizontally:
    -- left = full saturation, right = zero saturation.
    SV_LEFT = 94,
    SV_TOP = 124,
    SV_RIGHT = 202,
    SV_BOTTOM = 233,

    -- Drawing UI controls.
    COLOR_TAB_X = 82,
    COLOR_TAB_Y = 26,
    WHEEL_TAB_X = 48,
    WHEEL_TAB_Y = 330,

    BRUSH_MINUS_X = 32,
    BRUSH_MINUS_Y = 452,
    BRUSH_PLUS_X = 293,
    BRUSH_PLUS_Y = 452,

    OPACITY_PLUS_X = 293,
    OPACITY_PLUS_Y = 522,

    STABILIZER_MINUS_X = 32,
    STABILIZER_MINUS_Y = 593,

    -- Pencil tool (#1).
    PENCIL_X = 463,
    PENCIL_Y = 895,

    -- Fine calibration if an executor/window is offset slightly.
    NUDGE_X = 0,
    NUDGE_Y = 0,

    -- Input pacing.
    UI_CLICK_DELAY = 0.018,
    COLOR_SETTLE_DELAY = 0.035,
    STROKES_PER_FRAME = 6,

    DEFAULT_RESOLUTION = 128,
    DEFAULT_COLORS = 24,

    -- The server skips near-white pixels so the game's white canvas shows through.
    SKIP_WHITE = true,
    WHITE_THRESHOLD = 245,
}

local State = {
    cancelled = false,
    drawing = false,
    destroyed = false,
    mouseHeld = false,
    totalSegments = 0,
    finishedSegments = 0,
}

local function viewportSize()
    Camera = workspace.CurrentCamera or Camera
    return Camera and Camera.ViewportSize or Vector2.new(CONFIG.REF_W, CONFIG.REF_H)
end

local function scalePoint(x, y)
    local viewport = viewportSize()
    return
        x * (viewport.X / CONFIG.REF_W) + CONFIG.NUDGE_X,
        y * (viewport.Y / CONFIG.REF_H) + CONFIG.NUDGE_Y
end

local function scaledRect(left, top, right, bottom)
    local x0, y0 = scalePoint(left, top)
    local x1, y1 = scalePoint(right, bottom)
    return x0, y0, x1, y1
end

-- Executor input compatibility.
local mouseMoveAbs =
    ENV.mousemoveabs
    or ENV.mousemoveabsolute
    or rawget(_G, "mousemoveabs")
    or rawget(_G, "mousemoveabsolute")

local mouse1Press =
    ENV.mouse1press
    or rawget(_G, "mouse1press")

local mouse1Release =
    ENV.mouse1release
    or rawget(_G, "mouse1release")

local function moveMouse(x, y)
    x = math.floor(x + 0.5)
    y = math.floor(y + 0.5)

    if type(mouseMoveAbs) == "function" then
        mouseMoveAbs(x, y)
        return
    end

    local ok, err = pcall(function()
        VirtualInputManager:SendMouseMoveEvent(x, y, game)
    end)

    if not ok then
        error("No supported absolute mouse-move method. Velocity needs mousemoveabs or VirtualInputManager access. " .. tostring(err))
    end
end

local function mouseDown(x, y)
    x = math.floor(x + 0.5)
    y = math.floor(y + 0.5)

    if type(mouse1Press) == "function" then
        mouse1Press()
        State.mouseHeld = true
        return
    end

    local ok, err = pcall(function()
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
    end)

    if not ok then
        error("No supported mouse-down method. " .. tostring(err))
    end

    State.mouseHeld = true
end

local function mouseUp(x, y)
    x = math.floor(x + 0.5)
    y = math.floor(y + 0.5)

    if type(mouse1Release) == "function" then
        mouse1Release()
        State.mouseHeld = false
        return
    end

    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)

    State.mouseHeld = false
end

local function safeMouseUp()
    if not State.mouseHeld then
        return
    end

    local pos = UserInputService:GetMouseLocation()
    pcall(mouseUp, pos.X, pos.Y)
    State.mouseHeld = false
end

local function clickRef(x, y, delayAfter)
    if State.cancelled then
        return false
    end

    local sx, sy = scalePoint(x, y)
    moveMouse(sx, sy)
    mouseDown(sx, sy)
    task.wait(0.006)
    mouseUp(sx, sy)

    task.wait(delayAfter or CONFIG.UI_CLICK_DELAY)
    return not State.cancelled
end

local function dragAbsolute(x0, y0, x1, y1)
    if State.cancelled then
        return false
    end

    moveMouse(x0, y0)
    mouseDown(x0, y0)

    -- A tiny move is used for one-pixel runs because some brush handlers
    -- do not stamp until they see an InputChanged event.
    if math.abs(x1 - x0) < 0.8 and math.abs(y1 - y0) < 0.8 then
        moveMouse(x0 + 0.8, y0)
    else
        moveMouse(x1, y1)
    end

    mouseUp(x1, y1)
    return not State.cancelled
end

local function findRequestFunction()
    local candidates = {
        ENV.request,
        ENV.http_request,
        ENV.httprequest,
        rawget(_G, "request"),
        rawget(_G, "http_request"),
        rawget(_G, "httprequest"),
    }

    if ENV.syn and type(ENV.syn) == "table" then
        table.insert(candidates, ENV.syn.request)
    end

    for _, candidate in ipairs(candidates) do
        if type(candidate) == "function" then
            return candidate
        end
    end

    return nil
end

local requestFunction = findRequestFunction()

local function fetchPreparedImage(imageUrl, resolution, colors)
    local payload = {
        url = imageUrl,
        width = resolution,
        height = resolution,
        colors = colors,
        skipWhite = CONFIG.SKIP_WHITE,
        whiteThreshold = CONFIG.WHITE_THRESHOLD,
    }

    local bodyText

    if requestFunction then
        local response = requestFunction({
            Url = CONFIG.SERVER .. "/api/prepare",
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
            },
            Body = HttpService:JSONEncode(payload),
        })

        local statusCode =
            response.StatusCode
            or response.Status
            or response.status_code
            or 0

        bodyText =
            response.Body
            or response.body
            or response.ResponseBody

        if tonumber(statusCode) and tonumber(statusCode) >= 400 then
            error("Server returned HTTP " .. tostring(statusCode) .. ": " .. tostring(bodyText))
        end
    else
        local query =
            "?url=" .. HttpService:UrlEncode(imageUrl)
            .. "&width=" .. tostring(resolution)
            .. "&height=" .. tostring(resolution)
            .. "&colors=" .. tostring(colors)
            .. "&skipWhite=" .. tostring(CONFIG.SKIP_WHITE)
            .. "&whiteThreshold=" .. tostring(CONFIG.WHITE_THRESHOLD)

        bodyText = game:HttpGet(CONFIG.SERVER .. "/api/prepare" .. query)
    end

    if type(bodyText) ~= "string" or bodyText == "" then
        error("The processor returned an empty response.")
    end

    local decoded = HttpService:JSONDecode(bodyText)

    if not decoded.ok then
        error(decoded.error or "The image processor rejected the image.")
    end

    if not decoded.drawing then
        error("The processor response did not contain drawing data.")
    end

    return decoded.drawing
end

local function selectColor(rgb)
    if State.cancelled then
        return false
    end

    local r = tonumber(rgb[1]) or 0
    local g = tonumber(rgb[2]) or 0
    local b = tonumber(rgb[3]) or 0

    local h, s, v = Color3.fromRGB(r, g, b):ToHSV()

    -- Hue 0 = top of the ring, hue increases clockwise.
    local angle = h * math.pi * 2 - math.pi / 2
    local hueX = CONFIG.HUE_CX + math.cos(angle) * CONFIG.HUE_RADIUS
    local hueY = CONFIG.HUE_CY + math.sin(angle) * CONFIG.HUE_RADIUS

    if not clickRef(hueX, hueY, CONFIG.COLOR_SETTLE_DELAY) then
        return false
    end

    -- The game's SV box has full saturation on the LEFT and white on the RIGHT.
    -- Value runs bright at the top to black at the bottom.
    local margin = 1.5
    local usableLeft = CONFIG.SV_LEFT + margin
    local usableRight = CONFIG.SV_RIGHT - margin
    local usableTop = CONFIG.SV_TOP + margin
    local usableBottom = CONFIG.SV_BOTTOM - margin

    local svX = usableLeft + (1 - s) * (usableRight - usableLeft)
    local svY = usableTop + (1 - v) * (usableBottom - usableTop)

    return clickRef(svX, svY, CONFIG.COLOR_SETTLE_DELAY)
end

local function configureDrawMe(brushSize)
    -- Force the relevant drawing panels/tools into a known state.
    clickRef(CONFIG.COLOR_TAB_X, CONFIG.COLOR_TAB_Y)
    clickRef(CONFIG.WHEEL_TAB_X, CONFIG.WHEEL_TAB_Y)
    clickRef(CONFIG.PENCIL_X, CONFIG.PENCIL_Y)

    -- Brush size -> 1, then step up to our desired pixel diameter.
    -- Extra min clicks are harmless if already at size 1.
    for _ = 1, 32 do
        if not clickRef(CONFIG.BRUSH_MINUS_X, CONFIG.BRUSH_MINUS_Y, 0.004) then
            return false
        end
    end

    for _ = 2, brushSize do
        if not clickRef(CONFIG.BRUSH_PLUS_X, CONFIG.BRUSH_PLUS_Y, 0.006) then
            return false
        end
    end

    -- Force opacity to 100%.
    for _ = 1, 24 do
        if not clickRef(CONFIG.OPACITY_PLUS_X, CONFIG.OPACITY_PLUS_Y, 0.003) then
            return false
        end
    end

    -- Force stabilizer to 0%.
    for _ = 1, 24 do
        if not clickRef(CONFIG.STABILIZER_MINUS_X, CONFIG.STABILIZER_MINUS_Y, 0.003) then
            return false
        end
    end

    return not State.cancelled
end

-- GUI -----------------------------------------------------------------------

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
gui.Name = "DrawMeAutoPainter"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 2147483647
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parent

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(390, 218)
main.Position = UDim2.new(0.5, -195, 0, 72)
main.BackgroundColor3 = Color3.fromRGB(20, 23, 31)
main.BorderSizePixel = 0
main.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 14)
mainCorner.Parent = main

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(59, 148, 255)
stroke.Thickness = 1.5
stroke.Transparency = 0.1
stroke.Parent = main

local titleBar = Instance.new("Frame")
titleBar.BackgroundTransparency = 1
titleBar.Size = UDim2.new(1, 0, 0, 46)
titleBar.Parent = main

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(16, 8)
title.Size = UDim2.new(1, -64, 0, 30)
title.Font = Enum.Font.GothamBold
title.Text = "Draw Me Painter"
title.TextColor3 = Color3.fromRGB(245, 248, 255)
title.TextSize = 20
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

local close = Instance.new("TextButton")
close.BackgroundTransparency = 1
close.Position = UDim2.new(1, -42, 0, 7)
close.Size = UDim2.fromOffset(32, 32)
close.Font = Enum.Font.GothamBold
close.Text = "×"
close.TextColor3 = Color3.fromRGB(165, 174, 194)
close.TextSize = 26
close.Parent = titleBar

local urlBox = Instance.new("TextBox")
urlBox.Position = UDim2.fromOffset(16, 52)
urlBox.Size = UDim2.new(1, -32, 0, 43)
urlBox.BackgroundColor3 = Color3.fromRGB(31, 35, 47)
urlBox.BorderSizePixel = 0
urlBox.ClearTextOnFocus = false
urlBox.Font = Enum.Font.Code
urlBox.PlaceholderText = "Paste direct image URL…"
urlBox.PlaceholderColor3 = Color3.fromRGB(112, 121, 142)
urlBox.Text = ""
urlBox.TextColor3 = Color3.fromRGB(236, 240, 249)
urlBox.TextSize = 14
urlBox.TextXAlignment = Enum.TextXAlignment.Left
urlBox.Parent = main

local urlPadding = Instance.new("UIPadding")
urlPadding.PaddingLeft = UDim.new(0, 12)
urlPadding.PaddingRight = UDim.new(0, 12)
urlPadding.Parent = urlBox

local urlCorner = Instance.new("UICorner")
urlCorner.CornerRadius = UDim.new(0, 9)
urlCorner.Parent = urlBox

local resLabel = Instance.new("TextLabel")
resLabel.BackgroundTransparency = 1
resLabel.Position = UDim2.fromOffset(16, 105)
resLabel.Size = UDim2.fromOffset(80, 24)
resLabel.Font = Enum.Font.Gotham
resLabel.Text = "Resolution"
resLabel.TextColor3 = Color3.fromRGB(159, 169, 190)
resLabel.TextSize = 13
resLabel.TextXAlignment = Enum.TextXAlignment.Left
resLabel.Parent = main

local resBox = Instance.new("TextBox")
resBox.Position = UDim2.fromOffset(96, 102)
resBox.Size = UDim2.fromOffset(66, 30)
resBox.BackgroundColor3 = Color3.fromRGB(31, 35, 47)
resBox.BorderSizePixel = 0
resBox.ClearTextOnFocus = false
resBox.Font = Enum.Font.GothamBold
resBox.Text = tostring(CONFIG.DEFAULT_RESOLUTION)
resBox.TextColor3 = Color3.fromRGB(243, 246, 255)
resBox.TextSize = 14
resBox.Parent = main

local resCorner = Instance.new("UICorner")
resCorner.CornerRadius = UDim.new(0, 7)
resCorner.Parent = resBox

local colorsLabel = Instance.new("TextLabel")
colorsLabel.BackgroundTransparency = 1
colorsLabel.Position = UDim2.fromOffset(178, 105)
colorsLabel.Size = UDim2.fromOffset(54, 24)
colorsLabel.Font = Enum.Font.Gotham
colorsLabel.Text = "Colors"
colorsLabel.TextColor3 = Color3.fromRGB(159, 169, 190)
colorsLabel.TextSize = 13
colorsLabel.TextXAlignment = Enum.TextXAlignment.Left
colorsLabel.Parent = main

local colorsBox = Instance.new("TextBox")
colorsBox.Position = UDim2.fromOffset(232, 102)
colorsBox.Size = UDim2.fromOffset(56, 30)
colorsBox.BackgroundColor3 = Color3.fromRGB(31, 35, 47)
colorsBox.BorderSizePixel = 0
colorsBox.ClearTextOnFocus = false
colorsBox.Font = Enum.Font.GothamBold
colorsBox.Text = tostring(CONFIG.DEFAULT_COLORS)
colorsBox.TextColor3 = Color3.fromRGB(243, 246, 255)
colorsBox.TextSize = 14
colorsBox.Parent = main

local colorsCorner = Instance.new("UICorner")
colorsCorner.CornerRadius = UDim.new(0, 7)
colorsCorner.Parent = colorsBox

local zoomHint = Instance.new("TextLabel")
zoomHint.BackgroundTransparency = 1
zoomHint.Position = UDim2.fromOffset(297, 102)
zoomHint.Size = UDim2.fromOffset(80, 30)
zoomHint.Font = Enum.Font.Gotham
zoomHint.Text = "Zoom 100%"
zoomHint.TextColor3 = Color3.fromRGB(105, 203, 255)
zoomHint.TextSize = 12
zoomHint.Parent = main

local drawButton = Instance.new("TextButton")
drawButton.Position = UDim2.fromOffset(16, 144)
drawButton.Size = UDim2.new(1, -112, 0, 42)
drawButton.BackgroundColor3 = Color3.fromRGB(45, 145, 255)
drawButton.BorderSizePixel = 0
drawButton.Font = Enum.Font.GothamBold
drawButton.Text = "DRAW"
drawButton.TextColor3 = Color3.new(1, 1, 1)
drawButton.TextSize = 16
drawButton.Parent = main

local drawCorner = Instance.new("UICorner")
drawCorner.CornerRadius = UDim.new(0, 10)
drawCorner.Parent = drawButton

local stopButton = Instance.new("TextButton")
stopButton.Position = UDim2.new(1, -86, 0, 144)
stopButton.Size = UDim2.fromOffset(70, 42)
stopButton.BackgroundColor3 = Color3.fromRGB(239, 70, 91)
stopButton.BorderSizePixel = 0
stopButton.Font = Enum.Font.GothamBold
stopButton.Text = "STOP"
stopButton.TextColor3 = Color3.new(1, 1, 1)
stopButton.TextSize = 14
stopButton.Parent = main

local stopCorner = Instance.new("UICorner")
stopCorner.CornerRadius = UDim.new(0, 10)
stopCorner.Parent = stopButton

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.fromOffset(16, 190)
status.Size = UDim2.new(1, -32, 0, 20)
status.Font = Enum.Font.Gotham
status.Text = "Ready • RightShift is emergency stop"
status.TextColor3 = Color3.fromRGB(135, 145, 166)
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = main

local panic = Instance.new("TextButton")
panic.Visible = false
panic.AnchorPoint = Vector2.new(0.5, 0)
panic.Position = UDim2.new(0.5, 0, 0, 5)
panic.Size = UDim2.fromOffset(230, 31)
panic.BackgroundColor3 = Color3.fromRGB(218, 54, 75)
panic.BorderSizePixel = 0
panic.Font = Enum.Font.GothamBold
panic.Text = "STOP • RightShift"
panic.TextColor3 = Color3.new(1, 1, 1)
panic.TextSize = 13
panic.Parent = gui

local panicCorner = Instance.new("UICorner")
panicCorner.CornerRadius = UDim.new(0, 9)
panicCorner.Parent = panic

-- Draggable title bar.
do
    local dragging = false
    local dragStart
    local startPos

    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if
            dragging
            and input.UserInputType == Enum.UserInputType.MouseMovement
        then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
end

local function setStatus(text, color)
    status.Text = text
    status.TextColor3 = color or Color3.fromRGB(135, 145, 166)
end

local function requestCancel()
    if State.drawing then
        State.cancelled = true
        safeMouseUp()
        panic.Text = "Stopping…"
    end
end

stopButton.MouseButton1Click:Connect(requestCancel)
panic.MouseButton1Click:Connect(requestCancel)

local hotkeyConnection = UserInputService.InputBegan:Connect(function(input, processed)
    if input.KeyCode == Enum.KeyCode.RightShift then
        requestCancel()
    end
end)

local function showDrawingMode(enabled)
    main.Visible = not enabled
    panic.Visible = enabled
end

local function countSegments(drawing)
    local count = 0

    for _, group in ipairs(drawing.groups or {}) do
        count += #(group.segments or {})
    end

    return count
end

local function updatePanicProgress()
    if State.totalSegments <= 0 then
        panic.Text = "STOP • RightShift"
        return
    end

    local pct = math.floor(
        (State.finishedSegments / State.totalSegments) * 100 + 0.5
    )

    panic.Text = string.format("STOP • %d%% • RightShift", pct)
end

local function paintDrawing(drawing)
    local groups = drawing.groups or {}

    State.totalSegments = countSegments(drawing)
    State.finishedSegments = 0

    if State.totalSegments == 0 then
        error("The image contains no drawable pixels after white-background removal.")
    end

    local canvasLeft, canvasTop, canvasRight, canvasBottom =
        scaledRect(
            CONFIG.CANVAS_LEFT,
            CONFIG.CANVAS_TOP,
            CONFIG.CANVAS_RIGHT,
            CONFIG.CANVAS_BOTTOM
        )

    local canvasWidth = canvasRight - canvasLeft + 1
    local canvasHeight = canvasBottom - canvasTop + 1

    local cellX = canvasWidth / drawing.width
    local cellY = canvasHeight / drawing.height

    -- The brush is circular, so use the smaller cell dimension.
    -- Rounding down helps prevent neighboring color rows bleeding together.
    local brushSize = math.max(1, math.floor(math.min(cellX, cellY) + 0.15))

    if not configureDrawMe(brushSize) then
        return false
    end

    local strokesSinceYield = 0

    for groupIndex, group in ipairs(groups) do
        if State.cancelled then
            return false
        end

        updatePanicProgress()

        if not selectColor(group.rgb) then
            return false
        end

        for _, segment in ipairs(group.segments or {}) do
            if State.cancelled then
                return false
            end

            local y = tonumber(segment[1]) or 0
            local x0 = tonumber(segment[2]) or 0
            local x1 = tonumber(segment[3]) or x0

            local drawY = canvasTop + (y + 0.5) * cellY
            local drawX0 = canvasLeft + (x0 + 0.5) * cellX
            local drawX1 = canvasLeft + (x1 + 0.5) * cellX

            if not dragAbsolute(drawX0, drawY, drawX1, drawY) then
                return false
            end

            State.finishedSegments += 1
            strokesSinceYield += 1

            if strokesSinceYield >= CONFIG.STROKES_PER_FRAME then
                strokesSinceYield = 0
                updatePanicProgress()
                RunService.RenderStepped:Wait()
            end
        end
    end

    updatePanicProgress()
    return not State.cancelled
end

local function sanitizeSettings()
    local resolution = tonumber(resBox.Text) or CONFIG.DEFAULT_RESOLUTION
    resolution = math.clamp(math.floor(resolution + 0.5), 32, 128)

    -- Values that divide the ~785 px canvas reasonably well are friendlier.
    if resolution < 48 then
        resolution = 48
    end

    local colors = tonumber(colorsBox.Text) or CONFIG.DEFAULT_COLORS
    colors = math.clamp(math.floor(colors + 0.5), 2, 32)

    resBox.Text = tostring(resolution)
    colorsBox.Text = tostring(colors)

    return resolution, colors
end

local function runDraw()
    if State.drawing or State.destroyed then
        return
    end

    local imageUrl = urlBox.Text:match("^%s*(.-)%s*$")

    if imageUrl == "" then
        setStatus("Paste an image URL first.", Color3.fromRGB(255, 108, 124))
        return
    end

    if not imageUrl:match("^https?://") then
        setStatus("The URL must start with http:// or https://", Color3.fromRGB(255, 108, 124))
        return
    end

    local resolution, colors = sanitizeSettings()

    State.cancelled = false
    State.drawing = true
    State.totalSegments = 0
    State.finishedSegments = 0

    drawButton.Text = "LOADING…"
    setStatus("Sending image to processor…", Color3.fromRGB(105, 203, 255))

    local ok, resultOrError = xpcall(function()
        local drawing = fetchPreparedImage(
            imageUrl,
            resolution,
            colors
        )

        if State.cancelled then
            return false
        end

        setStatus(
            string.format(
                "Ready: %d colors, %d strokes",
                #(drawing.groups or {}),
                countSegments(drawing)
            ),
            Color3.fromRGB(112, 221, 155)
        )

        task.wait(0.35)

        -- Hide the control window so it cannot intercept our simulated clicks.
        showDrawingMode(true)

        task.wait(0.15)

        return paintDrawing(drawing)
    end, debug.traceback)

    safeMouseUp()
    State.drawing = false
    showDrawingMode(false)
    drawButton.Text = "DRAW"

    if not ok then
        setStatus(
            "Error: " .. tostring(resultOrError):gsub("\n.*", ""),
            Color3.fromRGB(255, 108, 124)
        )
        warn("[Draw Me Painter]\n" .. tostring(resultOrError))
        return
    end

    if State.cancelled or resultOrError == false then
        setStatus("Stopped.", Color3.fromRGB(255, 180, 89))
        State.cancelled = false
        return
    end

    setStatus(
        string.format(
            "Finished • %d strokes",
            State.finishedSegments
        ),
        Color3.fromRGB(112, 221, 155)
    )
end

drawButton.MouseButton1Click:Connect(function()
    task.spawn(runDraw)
end)

urlBox.FocusLost:Connect(function(enterPressed)
    if enterPressed and not State.drawing then
        task.spawn(runDraw)
    end
end)

local function destroy()
    if State.destroyed then
        return
    end

    State.destroyed = true
    State.cancelled = true
    safeMouseUp()

    if hotkeyConnection then
        hotkeyConnection:Disconnect()
    end

    if gui then
        gui:Destroy()
    end

    if ENV.__DRAW_ME_PAINTER == State then
        ENV.__DRAW_ME_PAINTER = nil
    end
end

close.MouseButton1Click:Connect(destroy)

State.Stop = requestCancel
State.Destroy = destroy
State.Draw = function(url, resolution, colors)
    if type(url) == "string" then
        urlBox.Text = url
    end

    if resolution then
        resBox.Text = tostring(resolution)
    end

    if colors then
        colorsBox.Text = tostring(colors)
    end

    task.spawn(runDraw)
end

ENV.__DRAW_ME_PAINTER = State
ENV.DrawMePainter = State

print("[Draw Me Painter] Loaded.")
print("[Draw Me Painter] Keep Draw Me zoom at 100%. RightShift cancels painting.")
