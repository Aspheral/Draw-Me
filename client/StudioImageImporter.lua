-- Draw Me Studio Image Importer
-- For a Roblox Studio remake/owned copy of Draw Me.
-- Imports an external image URL through the Draw-Me Vercel prepare endpoint
-- and writes the processed pixels into the actual live DrawingCanvas3 layer EditableImage.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local AssetService = game:GetService("AssetService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
assert(player, "StudioImageImporter must run on the client while Play testing.")

local playerGui = player:WaitForChild("PlayerGui")

local ENDPOINT = "https://draw-me-iota.vercel.app/api/prepare"
local SOURCE_SIZE = 128
local CANVAS_SIZE = 512
local DEFAULT_COLORS = 24
local WHITE_THRESHOLD = 245

local function getDrawMeCanvas()
	local canvas = nil

	if type(shared) == "table" then
		canvas = rawget(shared, "DrawMeCanvas")
	end

	if canvas == nil and type(_G) == "table" then
		canvas = rawget(_G, "DrawMeCanvas")
	end

	if type(canvas) == "function" then
		canvas = canvas()
	end

	assert(
		type(canvas) == "table",
		"Draw Me's live Canvas object is not exposed. "
			.. "In the copied Draw Me controller, immediately after it creates/receives "
			.. "the live Canvas object, add: shared.DrawMeCanvas = Canvas"
	)

	return canvas
end

local DRAW_ME_CANVAS = getDrawMeCanvas()

local function getSingleLayerEditableImage(canvas)
	local layers = canvas.Layers
	assert(type(layers) == "table", "Canvas.Layers is missing.")

	local list = layers.List
	assert(type(list) == "table", "Canvas.Layers.List is missing.")

	local foundLayer = nil
	local foundImage = nil
	local count = 0

	for _, layer in pairs(list) do
		if type(layer) == "table" then
			local internal = layer.Internal
			local image = type(internal) == "table" and internal.EditableImage or nil

			if image ~= nil then
				local ok, isEditable = pcall(function()
					return image:IsA("EditableImage")
				end)

				if ok and isEditable then
					count += 1
					foundLayer = layer
					foundImage = image
				end
			end
		end
	end

	assert(count > 0, "No layer Internal.EditableImage was found.")
	assert(
		count == 1,
		"Studio importer is configured for exactly one Draw Me layer, but found "
			.. tostring(count) .. "."
	)

	return foundLayer, foundImage
end

local function getUrl(url)
	local query = ENDPOINT
		.. "?url=" .. HttpService:UrlEncode(url)
		.. "&width=" .. SOURCE_SIZE
		.. "&height=" .. SOURCE_SIZE
		.. "&colors=" .. DEFAULT_COLORS
		.. "&whiteThreshold=" .. WHITE_THRESHOLD
		.. "&skipWhite=true"

	local ok, body = pcall(function()
		return game:HttpGet(query)
	end)

	if not ok then
		ok, body = pcall(function()
			return HttpService:GetAsync(query, false)
		end)
	end

	if not ok then
		error(
			"Could not reach draw-me-iota.vercel.app. "
			.. "Enable HTTP Requests in Studio. Error: "
			.. tostring(body)
		)
	end

	local decodeOk, response = pcall(
		HttpService.JSONDecode,
		HttpService,
		body
	)

	if not decodeOk then
		error("Prepare endpoint returned invalid JSON: " .. tostring(response))
	end

	if response.ok ~= true then
		error("Prepare API error: " .. tostring(response.error or "unknown error"))
	end

	assert(type(response.drawing) == "table", "Response contained no drawing object.")
	return response.drawing, response.source
end

local function buildCanvasBuffer(drawing)
	local sourceW = assert(tonumber(drawing.width), "drawing.width missing")
	local sourceH = assert(tonumber(drawing.height), "drawing.height missing")
	local groups = assert(drawing.groups, "drawing.groups missing")

	local pixels = buffer.create(CANVAS_SIZE * CANVAS_SIZE * 4)

	-- White opaque canvas. The API omits near-white source pixels.
	buffer.fill(pixels, 0, 255)

	local scaleX = CANVAS_SIZE / sourceW
	local scaleY = CANVAS_SIZE / sourceH

	local function setPixel(x, y, r, g, b)
		if x < 0 or y < 0 or x >= CANVAS_SIZE or y >= CANVAS_SIZE then
			return
		end

		local offset = (y * CANVAS_SIZE + x) * 4
		buffer.writeu8(pixels, offset, r)
		buffer.writeu8(pixels, offset + 1, g)
		buffer.writeu8(pixels, offset + 2, b)
		buffer.writeu8(pixels, offset + 3, 255)
	end

	for _, group in ipairs(groups) do
		local rgb = group.rgb
		local r = math.clamp(math.round(tonumber(rgb[1]) or 0), 0, 255)
		local g = math.clamp(math.round(tonumber(rgb[2]) or 0), 0, 255)
		local b = math.clamp(math.round(tonumber(rgb[3]) or 0), 0, 255)

		for _, segment in ipairs(group.segments) do
			local sy = tonumber(segment[1]) or 0
			local sx0 = tonumber(segment[2]) or 0
			local sx1 = tonumber(segment[3]) or sx0

			local y0 = math.clamp(math.floor(sy * scaleY), 0, CANVAS_SIZE - 1)
			local y1 = math.clamp(math.ceil((sy + 1) * scaleY) - 1, 0, CANVAS_SIZE - 1)
			local x0 = math.clamp(math.floor(sx0 * scaleX), 0, CANVAS_SIZE - 1)
			local x1 = math.clamp(math.ceil((sx1 + 1) * scaleX) - 1, 0, CANVAS_SIZE - 1)

			for y = y0, y1 do
				for x = x0, x1 do
					setPixel(x, y, r, g, b)
				end
			end
		end
	end

	return pixels
end

local function applyDrawing(drawing)
	local pixels = buildCanvasBuffer(drawing)

	local _, layerImage =
		getSingleLayerEditableImage(DRAW_ME_CANVAS)

	local size = layerImage.Size

	assert(
		math.floor(size.X) == CANVAS_SIZE
			and math.floor(size.Y) == CANVAS_SIZE,
		"Draw Me layer image is "
			.. tostring(size)
			.. "; importer currently expects 512x512."
	)

	-- This is the actual EditableImage owned by Draw Me's live one-layer
	-- canvas model. We mutate it in place instead of replacing ImageLabels.
	layerImage:WritePixelsBuffer(
		Vector2.zero,
		size,
		pixels
	)

	-- Ask the real canvas implementation to rebuild its committed render
	-- surfaces from the layer state we just changed.
	local update = DRAW_ME_CANVAS.UpdateRenderImage

	assert(
		type(update) == "function",
		"Canvas.UpdateRenderImage is missing."
	)

	local ok, err = pcall(
		update,
		DRAW_ME_CANVAS
	)

	assert(
		ok,
		"Canvas:UpdateRenderImage() failed: "
			.. tostring(err)
	)
end

--============================================================
-- UI
--============================================================

local oldGui = playerGui:FindFirstChild("DrawMeStudioImporter")
if oldGui then
	oldGui:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.Name = "DrawMeStudioImporter"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 1000000
gui.Parent = playerGui

local window = Instance.new("Frame")
window.Size = UDim2.fromOffset(540, 188)
window.Position = UDim2.new(0.5, -270, 0.12, 0)
window.BackgroundColor3 = Color3.fromRGB(20, 23, 31)
window.BorderSizePixel = 0
window.Parent = gui
Instance.new("UICorner", window).CornerRadius = UDim.new(0, 12)

local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, 0, 0, 42)
bar.BackgroundColor3 = Color3.fromRGB(29, 33, 44)
bar.BorderSizePixel = 0
bar.Parent = window
Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 12)

local barFill = Instance.new("Frame")
barFill.Position = UDim2.new(0, 0, 1, -12)
barFill.Size = UDim2.new(1, 0, 0, 12)
barFill.BackgroundColor3 = bar.BackgroundColor3
barFill.BorderSizePixel = 0
barFill.Parent = bar

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(14, 0)
title.Size = UDim2.new(1, -60, 1, 0)
title.Font = Enum.Font.GothamBold
title.Text = "Draw Me • Studio Image Importer"
title.TextSize = 16
title.TextColor3 = Color3.new(1, 1, 1)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = bar

local close = Instance.new("TextButton")
close.AnchorPoint = Vector2.new(1, 0.5)
close.Position = UDim2.new(1, -8, 0.5, 0)
close.Size = UDim2.fromOffset(32, 32)
close.BackgroundColor3 = Color3.fromRGB(83, 47, 57)
close.BorderSizePixel = 0
close.Font = Enum.Font.GothamBold
close.Text = "×"
close.TextSize = 21
close.TextColor3 = Color3.fromRGB(255, 220, 225)
close.Parent = bar
Instance.new("UICorner", close).CornerRadius = UDim.new(0, 8)

local urlBox = Instance.new("TextBox")
urlBox.Position = UDim2.fromOffset(14, 56)
urlBox.Size = UDim2.new(1, -28, 0, 38)
urlBox.BackgroundColor3 = Color3.fromRGB(29, 34, 45)
urlBox.BorderSizePixel = 0
urlBox.ClearTextOnFocus = false
urlBox.PlaceholderText = "https://example.com/image.png"
urlBox.Text = ""
urlBox.Font = Enum.Font.Gotham
urlBox.TextSize = 12
urlBox.TextColor3 = Color3.new(1, 1, 1)
urlBox.PlaceholderColor3 = Color3.fromRGB(135, 142, 160)
urlBox.Parent = window
Instance.new("UICorner", urlBox).CornerRadius = UDim.new(0, 8)

local importButton = Instance.new("TextButton")
importButton.Position = UDim2.fromOffset(14, 106)
importButton.Size = UDim2.fromOffset(150, 36)
importButton.BackgroundColor3 = Color3.fromRGB(48, 143, 245)
importButton.BorderSizePixel = 0
importButton.Font = Enum.Font.GothamBold
importButton.Text = "IMPORT TO CANVAS"
importButton.TextSize = 11
importButton.TextColor3 = Color3.new(1, 1, 1)
importButton.Parent = window
Instance.new("UICorner", importButton).CornerRadius = UDim.new(0, 8)

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(176, 106)
status.Size = UDim2.new(1, -190, 0, 36)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Gotham
status.Text = "Ready"
status.TextSize = 12
status.TextColor3 = Color3.fromRGB(155, 220, 175)
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = window

local info = Instance.new("TextLabel")
info.Position = UDim2.fromOffset(14, 150)
info.Size = UDim2.new(1, -28, 0, 24)
info.BackgroundTransparency = 1
info.Font = Enum.Font.Code
info.Text = "512×512 live Draw Me layer • one layer • Vercel /api/prepare"
info.TextSize = 11
info.TextColor3 = Color3.fromRGB(150, 158, 178)
info.TextXAlignment = Enum.TextXAlignment.Left
info.Parent = window

local busy = false

local function importUrl()
	if busy then
		return
	end

	local url = urlBox.Text:match("^%s*(.-)%s*$")
	if url == "" then
		status.Text = "Paste an image URL first."
		status.TextColor3 = Color3.fromRGB(255, 190, 105)
		return
	end

	busy = true
	importButton.AutoButtonColor = false
	importButton.Text = "IMPORTING..."
	status.Text = "Preparing image..."
	status.TextColor3 = Color3.fromRGB(255, 195, 100)

	task.spawn(function()
		local ok, result = pcall(function()
			local drawing, source = getUrl(url)
			status.Text = "Writing EditableImage..."
			applyDrawing(drawing)
			return {
				drawing = drawing,
				source = source,
			}
		end)

		if ok then
			local drawing = result.drawing
			local stats = drawing.stats or {}
			status.Text = string.format(
				"Imported ✓  %dx%d • %s colors • %s segments",
				tonumber(drawing.width) or SOURCE_SIZE,
				tonumber(drawing.height) or SOURCE_SIZE,
				tostring(stats.colors or #drawing.groups),
				tostring(stats.segments or "?")
			)
			status.TextColor3 = Color3.fromRGB(135, 235, 160)
		else
			status.Text = "ERROR: " .. tostring(result)
			status.TextColor3 = Color3.fromRGB(255, 130, 135)
		end

		importButton.Text = "IMPORT TO CANVAS"
		importButton.AutoButtonColor = true
		busy = false
	end)
end

importButton.MouseButton1Click:Connect(importUrl)

urlBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		importUrl()
	end
end)

close.MouseButton1Click:Connect(function()
	gui:Destroy()
end)

-- Draggable title bar.
local dragging = false
local dragInput
local dragStart
local startPosition

bar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		dragging = true
		dragStart = input.Position
		startPosition = window.Position

		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)

bar.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
	then
		dragInput = input
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and input == dragInput then
		local delta = input.Position - dragStart
		window.Position = UDim2.new(
			startPosition.X.Scale,
			startPosition.X.Offset + delta.X,
			startPosition.Y.Scale,
			startPosition.Y.Offset + delta.Y
		)
	end
end)

print("[Draw Me Studio Importer] Ready.")
