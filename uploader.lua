--[[
    Obby Creator Model Importer
    Paste a Roblox model ID -> model ghosts on your mouse -> click to place ->
    builds it brick by brick (place -> color -> material) using Obby Creator remotes + uncap method.

    Standalone. Uses InsertService to load models.
]]

-- ============================================================
-- ERROR HANDLER
-- ============================================================
local _ok, _err = xpcall(function()

-- ============================================================
-- SERVICES
-- ============================================================
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local InsertService = game:GetService("InsertService")

local plr = Players.LocalPlayer
local mouse = plr:GetMouse()

-- ============================================================
-- COLOR THEME (dark cyan, matches glitched parts panel)
-- ============================================================
local C = {
    bg       = Color3.fromRGB(8, 12, 16),
    panel    = Color3.fromRGB(12, 18, 24),
    card     = Color3.fromRGB(18, 26, 34),
    cardHi   = Color3.fromRGB(26, 36, 48),
    border   = Color3.fromRGB(20, 30, 42),
    accent   = Color3.fromRGB(0, 229, 255),
    accentD  = Color3.fromRGB(0, 140, 160),
    success  = Color3.fromRGB(0, 255, 157),
    danger   = Color3.fromRGB(255, 61, 90),
    warn     = Color3.fromRGB(255, 180, 0),
    text     = Color3.fromRGB(224, 231, 236),
    textDim  = Color3.fromRGB(122, 136, 150),
}

-- ============================================================
-- BYPASS HELPERS (mini version — just what we need for color/material)
-- ============================================================
local propMap = {
    ["Material"]="Mtl",["Reflectance"]="Rf",["Transparency"]="Tr",
    ["Color"]="C",["BrickColor"]="BC",
}

local function findValueObjectDeep(parent, targetName)
    local result = nil
    pcall(function()
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("ValueBase") and child.Name == targetName then
                result = child
                return
            end
            local isContainer = false
            pcall(function()
                if child:IsA("Folder") or child:IsA("Configuration") or child:IsA("Model") then
                    isContainer = true
                end
            end)
            if isContainer and not result then
                result = findValueObjectDeep(child, targetName)
                if result then return end
            end
        end
    end)
    return result
end

-- ============================================================
-- LOG
-- ============================================================
local logLines = {}
local LogTextBox = nil
local function log(msg, col)
    local text = tostring(msg)
    table.insert(logLines, text)
    if #logLines > 100 then table.remove(logLines, 1) end
    pcall(function() print("[IMPORTER] " .. text) end)
    if LogTextBox and LogTextBox.Parent then
        pcall(function()
            LogTextBox.Text = table.concat(logLines, "\n")
            LogTextBox.CursorPosition = #LogTextBox.Text + 1
        end)
    end
end

-- ============================================================
-- STATE
-- ============================================================
local loadedModel = nil       -- the InsertService model (stored in workspace, hidden)
local loadedModelPivot = nil -- the model's ORIGINAL pivot (before hiding)
local origPartData = {}       -- snapshots each part's original properties before hiding
local ghostModel = nil        -- clone that follows mouse
local ghostConn = nil         -- RenderStepped conn for mouse follow
local placingMode = false     -- true while ghost is following mouse
local ghostRotation = CFrame.new()  -- accumulated rotation offset (R key rotates 90° on Y)
local building = false        -- true during build sequence
local cancelBuild = false     -- flag to cancel mid-build
local buildSpeed = 1.0         -- FIXED: always 1 second per brick (per user request)
local partType = "Part"       -- AddObject type (Part, Star, etc.)

-- ============================================================
-- UI HELPERS
-- ============================================================
local function corner(parent, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 4)
    c.Parent = parent
    return c
end

local function stroke(parent, col, thick)
    local s = Instance.new("UIStroke")
    s.Color = col or C.border
    s.Thickness = thick or 1
    s.Parent = parent
    return s
end

-- ============================================================
-- SCREENGUI + PANEL
-- ============================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ModelImporter"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 99997
gui.IgnoreGuiInset = true
pcall(function() gui.Parent = CoreGui end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end

local panel = Instance.new("Frame")
panel.Size = UDim2.new(0, 340, 0, 420)
panel.Position = UDim2.new(0, 20, 0.5, -210)
panel.BackgroundColor3 = C.bg
panel.BorderSizePixel = 0
panel.Parent = gui
corner(panel, 8)
stroke(panel, C.accentD, 1)

-- ===== HEADER =====
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 32)
header.BackgroundColor3 = C.panel
header.BorderSizePixel = 0
header.Parent = panel
corner(header, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -60, 1, 0)
title.Position = UDim2.new(0, 10, 0, 0)
title.BackgroundTransparency = 1
title.Text = "MODEL IMPORTER"
title.TextColor3 = C.accent
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 22, 0, 22)
closeBtn.Position = UDim2.new(1, -26, 0, 5)
closeBtn.BackgroundColor3 = C.danger
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 11
closeBtn.Parent = header
corner(closeBtn, 4)
closeBtn.MouseButton1Click:Connect(function()
    if ghostConn then ghostConn:Disconnect() end
    if ghostModel then ghostModel:Destroy() end
    if loadedModel then loadedModel:Destroy() end
    gui:Destroy()
end)

-- Drag
local dragging, dragStart, startPos
header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = panel.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

-- ===== CONTENT =====
local content = Instance.new("Frame")
content.Size = UDim2.new(1, -16, 1, -44)
content.Position = UDim2.new(0, 8, 0, 40)
content.BackgroundTransparency = 1
content.Parent = panel

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = content

-- Helper: section label
local function sectionLabel(text)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 16)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = C.accent
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 10
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = content
    return lbl
end

-- Helper: textbox
local function mkTextBox(parent, placeholder)
    local t = Instance.new("TextBox")
    t.Size = UDim2.new(1, 0, 0, 24)
    t.BackgroundColor3 = C.card
    t.TextColor3 = C.text
    t.PlaceholderText = placeholder or ""
    t.PlaceholderColor3 = C.textDim
    t.Text = ""
    t.Font = Enum.Font.Gotham
    t.TextSize = 10
    t.ClearTextOnFocus = false
    t.Parent = parent
    corner(t, 4)
    stroke(t, C.border, 1)
    return t
end

-- Helper: button
local function mkButton(parent, text, bgColor, textColor, height)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, height or 26)
    b.BackgroundColor3 = bgColor or C.card
    b.Text = text
    b.TextColor3 = textColor or C.text
    b.Font = Enum.Font.GothamBold
    b.TextSize = 10
    b.Parent = parent
    corner(b, 4)
    return b
end

-- ============================================================
-- SECTION 1: MODEL ID INPUT
-- ============================================================
sectionLabel("=== MODEL ID ===")

local idBox = mkTextBox(content, "Enter model ID (e.g. 1234567890)")

local loadBtnRow = Instance.new("Frame")
loadBtnRow.Size = UDim2.new(1, 0, 0, 28)
loadBtnRow.BackgroundTransparency = 1
loadBtnRow.Parent = content
local loadBtnRowLay = Instance.new("UIListLayout")
loadBtnRowLay.FillDirection = Enum.FillDirection.Horizontal
loadBtnRowLay.Padding = UDim.new(0, 4)
loadBtnRowLay.Parent = loadBtnRow

local loadBtn = mkButton(loadBtnRow, "LOAD MODEL", C.accent, C.bg, 28)
loadBtn.Size = UDim2.new(0.65, -2, 1, 0)
loadBtn.TextSize = 11

local forceLoadBtn = mkButton(loadBtnRow, "FORCE LOAD", C.warn, C.bg, 28)
forceLoadBtn.Size = UDim2.new(0.35, -2, 1, 0)
forceLoadBtn.TextSize = 9

local loadStatus = Instance.new("TextLabel")
loadStatus.Size = UDim2.new(1, 0, 0, 16)
loadStatus.BackgroundTransparency = 1
loadStatus.Text = "No model loaded"
loadStatus.TextColor3 = C.textDim
loadStatus.Font = Enum.Font.Gotham
loadStatus.TextSize = 9
loadStatus.TextXAlignment = Enum.TextXAlignment.Left
loadStatus.Parent = content

-- ============================================================
-- SECTION 2: PART TYPE + SPEED
-- ============================================================
sectionLabel("=== SETTINGS ===")

-- Part type dropdown (all Obby Creator part types)
local partTypes = {
    "Part", "Ball", "Wedge", "CornerWedge", "Cylinder", "Truss",
    "3 Point Pyramid", "Cone", "Half Ball", "Half Cylinder",
    "Half Hollow Cylinder", "Head", "Hole",
    -- Extra part types
    "Hollow Cylinder", "Pyramid", "Ramp",
}
local ptButtons = {}

-- Dropdown button (shows current selection)
local ptRow = Instance.new("Frame")
ptRow.Size = UDim2.new(1, 0, 0, 24)
ptRow.BackgroundTransparency = 1
ptRow.Parent = content

local ptLbl = Instance.new("TextLabel")
ptLbl.Size = UDim2.new(0, 80, 1, 0)
ptLbl.BackgroundTransparency = 1
ptLbl.Text = "Part Type:"
ptLbl.TextColor3 = C.text
ptLbl.Font = Enum.Font.Gotham
ptLbl.TextSize = 10
ptLbl.TextXAlignment = Enum.TextXAlignment.Left
ptLbl.Parent = ptRow

local ptDdBtn = Instance.new("TextButton")
ptDdBtn.Size = UDim2.new(1, -80, 0, 22)
ptDdBtn.Position = UDim2.new(0, 80, 0, 1)
ptDdBtn.BackgroundColor3 = C.card
ptDdBtn.Text = partType
ptDdBtn.TextColor3 = C.text
ptDdBtn.Font = Enum.Font.GothamBold
ptDdBtn.TextSize = 10
ptDdBtn.TextXAlignment = Enum.TextXAlignment.Left
ptDdBtn.Parent = ptRow
corner(ptDdBtn, 4)
stroke(ptDdBtn, C.border, 1)

-- Dropdown list (hidden by default)
local ptDdList = Instance.new("ScrollingFrame")
ptDdList.Size = UDim2.new(1, -80, 0, 0)
ptDdList.Position = UDim2.new(0, 80, 0, 25)
ptDdList.BackgroundColor3 = C.card
ptDdList.BorderSizePixel = 0
ptDdList.Visible = false
ptDdList.ZIndex = 20
ptDdList.ScrollBarThickness = 4
ptDdList.Parent = ptRow
corner(ptDdList, 4)
stroke(ptDdList, C.accentD, 1)
local ptDdLay = Instance.new("UIListLayout")
ptDdLay.Padding = UDim.new(0, 1)
ptDdLay.Parent = ptDdList

local ptDropdownOpen = false

local function rebuildPTDropdown()
    for _, ch in ipairs(ptDdList:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    for _, t in ipairs(partTypes) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, 0, 0, 20)
        b.BackgroundColor3 = (t == partType) and C.cardHi or C.card
        b.Text = t
        b.TextColor3 = (t == partType) and C.accent or C.text
        b.Font = Enum.Font.Gotham
        b.TextSize = 9
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.ZIndex = 21
        b.Parent = ptDdList
        b.MouseButton1Click:Connect(function()
            partType = t
            ptDdBtn.Text = t
            ptDropdownOpen = false
            ptDdList.Visible = false
            rebuildPTDropdown()
            log("Part type: " .. t, C.accent)
        end)
    end
    ptDdList.CanvasSize = UDim2.new(0, 0, 0, #partTypes * 21)
end

ptDdBtn.MouseButton1Click:Connect(function()
    ptDropdownOpen = not ptDropdownOpen
    ptDdList.Visible = ptDropdownOpen
    if ptDropdownOpen then
        ptDdList.Size = UDim2.new(1, -80, 0, math.min(#partTypes * 21, 140))
    end
end)
rebuildPTDropdown()

-- Build speed slider (simple +/- buttons + label)
local speedRow = Instance.new("Frame")
speedRow.Size = UDim2.new(1, 0, 0, 22)
speedRow.BackgroundTransparency = 1
speedRow.Parent = content
local speedLbl = Instance.new("TextLabel")
speedLbl.Size = UDim2.new(0, 80, 1, 0)
speedLbl.BackgroundTransparency = 1
speedLbl.Text = "Speed:"
speedLbl.TextColor3 = C.text
speedLbl.Font = Enum.Font.Gotham
speedLbl.TextSize = 10
speedLbl.TextXAlignment = Enum.TextXAlignment.Left
speedLbl.Parent = speedRow

local speedValLbl = Instance.new("TextLabel")
speedValLbl.Size = UDim2.new(1, -80, 1, 0)
speedValLbl.Position = UDim2.new(0, 80, 0, 0)
speedValLbl.BackgroundTransparency = 1
speedValLbl.Text = "1.00s/brick (fixed)"
speedValLbl.TextColor3 = C.accent
speedValLbl.Font = Enum.Font.GothamBold
speedValLbl.TextSize = 10
speedValLbl.TextXAlignment = Enum.TextXAlignment.Left
speedValLbl.Parent = speedRow

-- Speed is fixed at 1 second per brick — no +/- buttons needed.

-- ============================================================
-- SECTION 3: BUILD CONTROLS
-- ============================================================
sectionLabel("=== BUILD OPTIONS ===")

-- Color toggle
local colorToggleBtn = mkButton(content, "Colors: ON", C.accent, C.bg, 22)
local applyColors = true
colorToggleBtn.MouseButton1Click:Connect(function()
    applyColors = not applyColors
    if applyColors then
        colorToggleBtn.Text = "Colors: ON"
        colorToggleBtn.BackgroundColor3 = C.accent
        colorToggleBtn.TextColor3 = C.bg
    else
        colorToggleBtn.Text = "Colors: OFF"
        colorToggleBtn.BackgroundColor3 = C.card
        colorToggleBtn.TextColor3 = C.textDim
    end
end)

-- Material toggle
local materialToggleBtn = mkButton(content, "Materials: ON", C.accent, C.bg, 22)
local applyMaterials = true
materialToggleBtn.MouseButton1Click:Connect(function()
    applyMaterials = not applyMaterials
    if applyMaterials then
        materialToggleBtn.Text = "Materials: ON"
        materialToggleBtn.BackgroundColor3 = C.accent
        materialToggleBtn.TextColor3 = C.bg
    else
        materialToggleBtn.Text = "Materials: OFF"
        materialToggleBtn.BackgroundColor3 = C.card
        materialToggleBtn.TextColor3 = C.textDim
    end
end)

sectionLabel("=== BUILD ===")

local placeBtn = mkButton(content, "PLACE (click to set position)", C.warn, C.bg, 28)
placeBtn.TextSize = 11

local buildBtn = mkButton(content, "BUILD MODEL", C.success, C.bg, 30)
buildBtn.TextSize = 12
stroke(buildBtn, C.success, 2)

local cancelBtn = mkButton(content, "CANCEL BUILD", C.danger, Color3.new(1,1,1), 22)
cancelBtn.TextSize = 10

local progressLbl = Instance.new("TextLabel")
progressLbl.Size = UDim2.new(1, 0, 0, 16)
progressLbl.BackgroundTransparency = 1
progressLbl.Text = "Ready"
progressLbl.TextColor3 = C.textDim
progressLbl.Font = Enum.Font.Gotham
progressLbl.TextSize = 9
progressLbl.TextXAlignment = Enum.TextXAlignment.Left
progressLbl.Parent = content

-- Progress bar
local progressBg = Instance.new("Frame")
progressBg.Size = UDim2.new(1, 0, 0, 8)
progressBg.BackgroundColor3 = C.card
progressBg.Parent = content
corner(progressBg, 2)

local progressFill = Instance.new("Frame")
progressFill.Size = UDim2.new(0, 0, 1, 0)
progressFill.BackgroundColor3 = C.accent
progressFill.Parent = progressBg
corner(progressFill, 2)

local function setProgress(pct, text)
    progressFill.Size = UDim2.new(pct, 0, 1, 0)
    if text then progressLbl.Text = text end
end

-- ============================================================
-- SECTION 4: LOG
-- ============================================================
sectionLabel("=== LOG ===")

LogTextBox = Instance.new("TextBox")
LogTextBox.Size = UDim2.new(1, 0, 0, 70)
LogTextBox.BackgroundColor3 = C.card
LogTextBox.TextColor3 = C.text
LogTextBox.Text = ""
LogTextBox.Font = Enum.Font.RobotoMono
LogTextBox.TextSize = 7
LogTextBox.TextWrapped = true
LogTextBox.TextXAlignment = Enum.TextXAlignment.Left
LogTextBox.TextYAlignment = Enum.TextYAlignment.Top
LogTextBox.MultiLine = true
LogTextBox.ClearTextOnFocus = false
LogTextBox.TextEditable = false  -- can't type into it (read-only)
LogTextBox.Active = false         -- can't be focused at all
LogTextBox.Parent = content
corner(LogTextBox, 4)
stroke(LogTextBox, C.border, 1)

-- ============================================================
-- GHOST MODEL SYSTEM (follows mouse)
-- ============================================================
local function clearGhost()
    if ghostConn then ghostConn:Disconnect() ghostConn = nil end
    if ghostModel then ghostModel:Destroy() ghostModel = nil end
    placingMode = false
    placeBtn.Text = "PLACE (click to set position)"
    placeBtn.BackgroundColor3 = C.warn
    placeBtn.TextColor3 = C.bg
end

local function startGhost()
    if not loadedModel then
        log("Load a model first!", C.danger)
        return
    end
    clearGhost()
    ghostRotation = CFrame.new()  -- reset rotation
    ghostModel = loadedModel:Clone()
    -- Make all parts semi-transparent neon for ghost appearance
    for _, p in ipairs(ghostModel:GetDescendants()) do
        if p:IsA("BasePart") then
            p.Transparency = 0.5
            p.Material = Enum.Material.Neon
            p.CanCollide = false
            p.CanQuery = false
            p.CanTouch = false
            p.Anchored = true
        end
    end
    ghostModel.Parent = workspace
    placingMode = true
    placeBtn.Text = "CLICK IN WORLD TO PLACE... (R to rotate)"
    placeBtn.BackgroundColor3 = C.accent
    placeBtn.TextColor3 = C.bg

    ghostConn = RunService.RenderStepped:Connect(function()
        if not ghostModel or not ghostModel.Parent then
            clearGhost()
            return
        end
        -- Follow mouse hit position + apply accumulated rotation
        local mousePos = mouse.Hit.Position
        ghostModel:PivotTo(CFrame.new(mousePos) * ghostRotation)
    end)
    log("Ghost active — click in the world to place. Press R to rotate 90°.", C.accent)
end

placeBtn.MouseButton1Click:Connect(function()
    if building then
        log("Build in progress — cancel first", C.warn)
        return
    end
    if placingMode then
        -- Cancel placing
        clearGhost()
        log("Placing cancelled", C.warn)
    else
        startGhost()
    end
end)

-- Click in world to place + R key to rotate
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    -- ===== R KEY: rotate ghost model 90° on Y axis =====
    if input.KeyCode == Enum.KeyCode.R then
        -- Don't rotate if user is typing in a textbox (ID box, etc.)
        if UserInputService:GetFocusedTextBox() then return end
        if not placingMode then return end
        -- Rotate 90 degrees on the Y axis
        ghostRotation = ghostRotation * CFrame.Angles(0, math.rad(90), 0)
        log("Rotated 90° (Y axis)", C.accent)
        return
    end

    -- ===== MOUSE CLICK: place the ghost =====
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end
    if gameProcessed then return end
    if not placingMode then return end
    if building then return end

    -- Place the ghost at current mouse position (includes rotation)
    local placeCFrame = ghostModel:GetPivot()
    clearGhost()
    log("Placed at " .. tostring(placeCFrame.Position), C.success)
    -- Start building
    startBuild(placeCFrame)
end)

-- ============================================================
-- BUILD SEQUENCE
-- ============================================================
-- Collect all BaseParts from the loaded model with their relative CFrames
local function collectBricks()
    if not loadedModel then return {} end
    local bricks = {}
    -- Use the ORIGINAL pivot (captured before the model was hidden)
    local pivot = loadedModelPivot or loadedModel:GetPivot()
    local skipped = 0
    local totalParts = 0

    -- ===== AUTO-DETECT Obby Creator part type from Roblox part shape =====
    -- Uses STORED original data (the live parts are now hidden/modified)
    local function detectObbyType(p, data)
        -- WedgePart -> Wedge
        if p:IsA("WedgePart") then return "Wedge" end
        if p:IsA("CornerWedgePart") then return "CornerWedge" end
        if p:IsA("TrussPart") then return "Truss" end
        -- Part with Shape enum -> Ball / Cylinder / Part
        if p:IsA("Part") then
            if data.shape == Enum.PartType.Ball then return "Ball" end
            if data.shape == Enum.PartType.Cylinder then return "Cylinder" end
            return "Part"
        end
        -- MeshPart / UnionOperation -> check for SpecialMesh child
        if p:IsA("MeshPart") or p:IsA("UnionOperation") then
            for _, child in ipairs(p:GetChildren()) do
                if child:IsA("SpecialMesh") then
                    local mt = child.MeshType
                    if mt == Enum.MeshType.Sphere then return "Ball" end
                    if mt == Enum.MeshType.Cylinder then return "Cylinder" end
                    if mt == Enum.MeshType.FileMesh then return "Part" end
                end
            end
            return "Part"
        end
        return "Part"
    end

    for _, p in ipairs(loadedModel:GetDescendants()) do
        if p:IsA("BasePart") then
            totalParts = totalParts + 1
            -- Get STORED original data (the live parts are now invisible/moved)
            local data = origPartData[p]
            if not data then
                -- Fallback: read from live part (shouldn't happen, but just in case)
                data = {
                    transparency = p.Transparency,
                    canCollide = p.CanCollide,
                    size = p.Size,
                    color = p.Color,
                    material = p.Material,
                    reflectance = p.Reflectance,
                    cframe = p.CFrame,
                    name = p.Name,
                    className = p.ClassName,
                    shape = p:IsA("Part") and p.Shape or nil,
                }
            end
            local obbyType = detectObbyType(p, data)

                -- ===== SCAN FOR EFFECTS (Fire, SurfaceLight, Texture, Decal, Particles, etc.) =====
                -- Use GetDescendants to find effects at ANY depth (attachments, folders, etc.)
                local effects = {}
                for _, child in ipairs(p:GetDescendants()) do
                    if child:IsA("Fire") then
                        table.insert(effects, {
                            type = "fire",
                            props = {
                                {"Heat", child.Heat},
                                {"Size", child.Size},
                                {"Color", child.Color},
                                {"SecondaryColor", child.SecondaryColor},
                            },
                        })
                    elseif child:IsA("SurfaceLight") then
                        table.insert(effects, {
                            type = "surfacelight",
                            props = {
                                {"Face", tostring(child.Face.Name)},
                                {"Brightness", child.Brightness},
                                {"Range", child.Range},
                                {"Color", child.Color},
                                {"Angle", child.Angle},
                            },
                        })
                    elseif child:IsA("Texture") then
                        -- Extract numeric ID from "rbxassetid://12345" format
                        local texId = child.Texture
                        local numId = texId:match("%d+")
                        table.insert(effects, {
                            type = "texture",
                            props = {
                                {"Face", tostring(child.Face.Name)},  -- Face FIRST
                                {"Texture", numId or texId},  -- then texture ID
                                {"StudsPerTileU", child.StudsPerTileU},
                                {"StudsPerTileV", child.StudsPerTileV},
                                {"Transparency", child.Transparency},
                            },
                        })
                    elseif child:IsA("Decal") then
                        -- Decals use the same "texture" effect type in Obby Creator
                        local texId = child.Texture
                        local numId = texId:match("%d+")
                        table.insert(effects, {
                            type = "texture",
                            props = {
                                {"Face", tostring(child.Face.Name)},  -- Face FIRST
                                {"Texture", numId or texId},  -- then texture ID
                                {"Transparency", child.Transparency},
                            },
                        })
                    elseif child:IsA("ParticleEmitter") then
                        -- ParticleEmitter -> "particles" effect in Obby Creator
                        -- Extract numeric texture ID from "rbxassetid://12345" format
                        local pTexId = child.Texture
                        local pNumId = pTexId and tostring(pTexId):match("%d+") or nil
                        table.insert(effects, {
                            type = "particles",
                            props = {
                                {"Texture", pNumId or tostring(pTexId)},
                                {"Transparency", child.Transparency},
                                {"Speed", child.Speed},
                                {"SpreadAngle", child.SpreadAngle},
                                {"Rate", child.Rate},
                                {"Lifetime", child.Lifetime},
                                {"Size", child.Size},
                                {"LightEmission", child.LightEmission},
                                {"LightInfluence", child.LightInfluence},
                                {"Squash", child.Squash},
                                {"Acceleration", child.Acceleration},
                                {"Rotation", child.Rotation},
                                {"RotSpeed", child.RotSpeed},
                                {"EmissionDirection", tostring(child.EmissionDirection.Name)},
                                {"Color", child.Color},  -- ColorSequence for particles
                            },
                        })
                    elseif child:IsA("PointLight") then
                        -- PointLight -> "light" effect (NOT surfacelight)
                        table.insert(effects, {
                            type = "light",
                            props = {
                                {"Color", child.Color},
                                {"Range", child.Range},
                                {"Brightness", child.Brightness},
                                {"Shadows", child.Shadows},
                            },
                        })
                    elseif child:IsA("Smoke") then
                        table.insert(effects, {
                            type = "smoke",
                            props = {
                                {"Opacity", child.Opacity},
                                {"RiseVelocity", child.RiseVelocity},
                                {"Size", child.Size},
                                {"Color", child.Color},
                            },
                        })
                    elseif child:IsA("Sparkles") then
                        table.insert(effects, {
                            type = "sparkles",
                            props = {
                                {"SparkleColor", child.SparkleColor},
                            },
                        })
                    end
                end

                -- ===== CHECK PARENT MODEL FOR HIGHLIGHT (Outline) =====
                -- Highlights are usually on the Model, not the part itself.
                -- Walk up the ancestors looking for a Highlight.
                local ancestor = p.Parent
                while ancestor and ancestor ~= workspace do
                    for _, child in ipairs(ancestor:GetChildren()) do
                        if child:IsA("Highlight") then
                            table.insert(effects, {
                                type = "outline",
                                props = {
                                    {"Color3", child.FillColor},
                                    {"LineThickness", 0.03},  -- fixed reasonable thickness
                                },
                            })
                            break  -- only take the first Highlight found
                        end
                    end
                    if #effects > 0 and effects[#effects].type == "outline" then break end
                    ancestor = ancestor.Parent
                end

                -- Also check the part's own children for Highlight (less common)
                for _, child in ipairs(p:GetChildren()) do
                    if child:IsA("Highlight") then
                        table.insert(effects, {
                            type = "outline",
                            props = {
                                {"Color3", child.FillColor},
                                {"LineThickness", 0.03},
                            },
                        })
                        break
                    end
                end

                -- ===== DETECT SPIN PROPERTIES =====
                -- Obby Creator spin parts use specific attributes or child value objects.
                -- We check for common spin properties to determine if this is a spin part.
                local spinProps = nil
                -- Check for attributes (common in custom spin scripts)
                local hasSpinAttr = p:GetAttribute("SpinTime") or p:GetAttribute("sT") or
                                    p:GetAttribute("SpinSpeed") or p:GetAttribute("SpinOffset")
                -- Check for child ValueObjects named like spin properties
                local spinTimeVal = findValueObjectDeep(p, "SpinTime") or findValueObjectDeep(p, "sT")
                local spinOffsetVal = findValueObjectDeep(p, "SpinOffset") or findValueObjectDeep(p, "sO")
                local spinDistVal = findValueObjectDeep(p, "SpinDistance") or findValueObjectDeep(p, "sD")

                if hasSpinAttr or spinTimeVal or spinOffsetVal then
                    spinProps = {
                        sO = (spinOffsetVal and spinOffsetVal.Value) or p:GetAttribute("SpinOffset") or p:GetAttribute("sO") or 1,
                        sT = (spinTimeVal and spinTimeVal.Value) or p:GetAttribute("SpinTime") or p:GetAttribute("sT") or 2,
                        sd = (spinDistVal and spinDistVal.Value) or p:GetAttribute("SpinDistance") or p:GetAttribute("sD") or 0,
                        sA = p:GetAttribute("SpinAngle") or p:GetAttribute("sA") or 0,
                        A = p:GetAttribute("SpinAxis") or p:GetAttribute("A") or "Y",
                        E = p:GetAttribute("EasingStyle") or p:GetAttribute("E") or "Sine",
                        Ed = p:GetAttribute("EasingDirection") or p:GetAttribute("Ed") or "InOut",
                        mR = p:GetAttribute("Reverse") or p:GetAttribute("mR") or false,
                    }
                end

                -- ===== SPLIT PARTICLES AND TEXTURES FROM OTHER EFFECTS =====
                -- Multiple ParticleEmitters → clone part per particle
                -- Multiple Textures/Decals on different faces → clone part per face
                local particleEffects = {}
                local textureEffects = {}
                local otherEffects = {}
                for _, e in ipairs(effects) do
                    if e.type == "particles" then
                        table.insert(particleEffects, e)
                    elseif e.type == "texture" then
                        table.insert(textureEffects, e)
                    else
                        table.insert(otherEffects, e)
                    end
                end

                -- Helper: create a brick entry
                local function addBrick(effectsList)
                    table.insert(bricks, {
                        part = p,
                        relCFrame = pivot:ToObjectSpace(data.cframe),
                        size = data.size,
                        color = data.color,
                        material = data.material,
                        transparency = data.transparency,
                        reflectance = data.reflectance,
                        name = data.name,
                        className = data.className,
                        obbyType = obbyType,
                        effects = effectsList,
                        spinProps = spinProps,  -- spin properties (nil if not a spin part)
                    })
                end

                -- Determine if we need to clone (multiple particles OR multiple textures)
                local needClone = #particleEffects > 1 or #textureEffects > 1

                if not needClone then
                    -- Normal: single brick with all effects
                    addBrick(effects)
                else
                    -- Clone mode: first copy gets other effects + first texture + first particle
                    local firstEffects = {}
                    for _, e in ipairs(otherEffects) do
                        table.insert(firstEffects, e)
                    end
                    if #textureEffects > 0 then
                        table.insert(firstEffects, textureEffects[1])
                    end
                    if #particleEffects > 0 then
                        table.insert(firstEffects, particleEffects[1])
                    end
                    addBrick(firstEffects)

                    -- Additional texture copies (one per extra texture/decal face)
                    for i = 2, #textureEffects do
                        addBrick({textureEffects[i]})
                    end

                    -- Additional particle copies (one per extra particle emitter)
                    for i = 2, #particleEffects do
                        addBrick({particleEffects[i]})
                    end

                    local cloneReason = ""
                    if #textureEffects > 1 then cloneReason = cloneReason .. #textureEffects .. " textures " end
                    if #particleEffects > 1 then cloneReason = cloneReason .. #particleEffects .. " particles" end
                    log("Part '" .. (p.Name or "?") .. "' has " .. cloneReason ..
                        "— cloned into " .. (1 + math.max(0, #textureEffects - 1) + math.max(0, #particleEffects - 1)) .. " parts", C.warn)
                end
        end
    end

    -- Log a breakdown of detected types
    local typeCounts = {}
    for _, b in ipairs(bricks) do
        typeCounts[b.obbyType] = (typeCounts[b.obbyType] or 0) + 1
    end
    local breakdown = {}
    for t, c in pairs(typeCounts) do
        table.insert(breakdown, t .. "=" .. c)
    end
    table.sort(breakdown)
    log("Model scan: " .. totalParts .. " BaseParts, " .. skipped .. " filtered, " .. #bricks .. " to build", C.accent)
    log("Type breakdown: " .. table.concat(breakdown, ", "), C.text)
    -- Count effects found
    local effectCount = 0
    local effectTypes = {}
    for _, b in ipairs(bricks) do
        if b.effects then
            for _, e in ipairs(b.effects) do
                effectCount = effectCount + 1
                effectTypes[e.type] = (effectTypes[e.type] or 0) + 1
            end
        end
    end
    if effectCount > 0 then
        local eBreakdown = {}
        for t, c in pairs(effectTypes) do table.insert(eBreakdown, t .. "=" .. c) end
        table.sort(eBreakdown)
        log("Effects found: " .. effectCount .. " (" .. table.concat(eBreakdown, ", ") .. ")", C.success)
    else
        log("No effects found in model", C.textDim)
    end
    return bricks
end

-- Apply color to a part via PaintObject + uncap
local function applyColorToPart(part, color)
    local evts = ReplicatedStorage:FindFirstChild("Events")
    if not evts then return end
    spawn(function()
        pcall(function()
            if evts:FindFirstChild("PaintObject") then
                evts.PaintObject:InvokeServer({part}, "Color", color)
            end
            if evts:FindFirstChild("BehaviourObject") then
                evts.BehaviourObject:InvokeServer({part}, "C", color)
            end
        end)
    end)
end

-- Apply material to a part via multiple bypass methods (UNCAP)
local function applyMaterialToPart(part, material)
    local evts = ReplicatedStorage:FindFirstChild("Events")
    if not evts then return end
    local matName = material.Name  -- e.g. "Neon", "Plastic", "Metal", "Wood", etc.

    -- Method 1: BehaviourObject with various codes
    spawn(function()
        pcall(function()
            if evts:FindFirstChild("BehaviourObject") then
                evts.BehaviourObject:InvokeServer({part}, "Mtl", matName)
                evts.BehaviourObject:InvokeServer({part}, "Material", matName)
                evts.BehaviourObject:InvokeServer({part}, "MaterialName", matName)
                -- Also try with the material enum value (number)
                evts.BehaviourObject:InvokeServer({part}, "Mtl", material)
                evts.BehaviourObject:InvokeServer({part}, "Material", material)
            end
        end)
    end)

    -- Method 2: PaintObject (sometimes handles materials too)
    spawn(function()
        pcall(function()
            if evts:FindFirstChild("PaintObject") then
                evts.PaintObject:InvokeServer({part}, "Material", matName)
                evts.PaintObject:InvokeServer({part}, "Material", material)
            end
        end)
    end)

    -- Method 3: Find the Material ValueObject on the part and set it directly (uncap)
    spawn(function()
        pcall(function()
            local matValObj = findValueObjectDeep(part, "Material")
            if matValObj then
                if matValObj:IsA("StringValue") then
                    matValObj.Value = matName
                elseif matValObj:IsA("NumberValue") or matValObj:IsA("IntValue") then
                    matValObj.Value = material.Value  -- Enum.Material numeric value
                end
            end
            -- Also try "Mtl" value object
            local mtlValObj = findValueObjectDeep(part, "Mtl")
            if mtlValObj then
                if mtlValObj:IsA("StringValue") then
                    mtlValObj.Value = matName
                elseif mtlValObj:IsA("NumberValue") or mtlValObj:IsA("IntValue") then
                    mtlValObj.Value = material.Value
                end
            end
        end)
    end)
end

-- Apply reflectance via multiple bypass methods (UNCAP)
local function applyReflectanceToPart(part, reflectance)
    local evts = ReplicatedStorage:FindFirstChild("Events")
    if not evts then return end

    -- Method 1: BehaviourObject with multiple codes
    spawn(function()
        pcall(function()
            if evts:FindFirstChild("BehaviourObject") then
                evts.BehaviourObject:InvokeServer({part}, "Rf", reflectance)
                evts.BehaviourObject:InvokeServer({part}, "Reflectance", reflectance)
            end
        end)
    end)

    -- Method 2: PaintObject
    spawn(function()
        pcall(function()
            if evts:FindFirstChild("PaintObject") then
                evts.PaintObject:InvokeServer({part}, "Reflectance", reflectance)
            end
        end)
    end)

    -- Method 3: Direct ValueObject edit
    spawn(function()
        pcall(function()
            local valObj = findValueObjectDeep(part, "Reflectance") or findValueObjectDeep(part, "Rf")
            if valObj and (valObj:IsA("NumberValue") or valObj:IsA("IntValue") or valObj:IsA("FloatValue")) then
                valObj.Value = reflectance
            end
        end)
    end)
end

-- Apply transparency via multiple bypass methods (UNCAP)
local function applyTransparencyToPart(part, transparency)
    local evts = ReplicatedStorage:FindFirstChild("Events")
    if not evts then return end

    -- Method 1: BehaviourObject with multiple codes
    spawn(function()
        pcall(function()
            if evts:FindFirstChild("BehaviourObject") then
                evts.BehaviourObject:InvokeServer({part}, "Tr", transparency)
                evts.BehaviourObject:InvokeServer({part}, "Transparency", transparency)
            end
        end)
    end)

    -- Method 2: PaintObject
    spawn(function()
        pcall(function()
            if evts:FindFirstChild("PaintObject") then
                evts.PaintObject:InvokeServer({part}, "Transparency", transparency)
            end
        end)
    end)

    -- Method 3: Direct ValueObject edit
    spawn(function()
        pcall(function()
            local valObj = findValueObjectDeep(part, "Transparency") or findValueObjectDeep(part, "Tr")
            if valObj and (valObj:IsA("NumberValue") or valObj:IsA("IntValue") or valObj:IsA("FloatValue")) then
                valObj.Value = transparency
            end
        end)
    end)
end

function startBuild(originCFrame)
    if building then return end
    local bricks = collectBricks()
    if #bricks == 0 then
        log("No bricks found in model!", C.danger)
        return
    end

    building = true
    cancelBuild = false
    buildBtn.Text = "BUILDING..."
    buildBtn.BackgroundColor3 = C.cardHi
    log("Starting build: " .. #bricks .. " bricks", C.accent)

    spawn(function()
        local evts = ReplicatedStorage:FindFirstChild("Events")
        if not evts then
            log("No Events folder!", C.danger)
            building = false
            buildBtn.Text = "BUILD MODEL"
            buildBtn.BackgroundColor3 = C.success
            return
        end

        -- ===== PHASE 1: PLACE ALL BRICKS =====
        log("Phase 1: Placing bricks...", C.warn)
        setProgress(0, "Phase 1/4: Placing 0/" .. #bricks)
        local placedParts = {}  -- {brick = brick, part = createdPart}

        -- Helper: get the player's Obby.Items.Parts folder
        local function getPartsFolder()
            local obby = workspace:FindFirstChild("Obbies")
            if not obby then return nil end
            obby = obby:FindFirstChild(plr.Name)
            if not obby then return nil end
            if not obby:FindFirstChild("Items") then return nil end
            return obby.Items:FindFirstChild("Parts")
        end

        for i, brick in ipairs(bricks) do
            if cancelBuild then
                log("Build cancelled", C.danger)
                building = false
                buildBtn.Text = "BUILD MODEL"
                buildBtn.BackgroundColor3 = C.success
                return
            end

            -- Calculate world CFrame for this brick (includes rotation)
            local worldCFrame = originCFrame:ToWorldSpace(brick.relCFrame)

            -- Get the parts folder
            local partsFolder = getPartsFolder()
            if not partsFolder then
                log("Could not find Obby.Items.Parts folder!", C.danger)
                building = false
                buildBtn.Text = "BUILD MODEL"
                buildBtn.BackgroundColor3 = C.success
                return
            end

            -- ===== SNAPSHOT existing parts BEFORE AddObject =====
            -- This lets us reliably find the NEW part after AddObject fires.
            local existingParts = {}
            for _, ch in ipairs(partsFolder:GetChildren()) do
                existingParts[ch] = true
            end

            -- Set up ChildAdded listener BEFORE AddObject so we don't miss the event
            local newPartFound = nil
            local childAddedConn = partsFolder.ChildAdded:Connect(function(child)
                if not existingParts[child] then
                    newPartFound = child
                end
            end)

            -- 1) AddObject — create the part using the AUTO-DETECTED type for this brick
            local useType = brick.obbyType or partType  -- fallback to global if detection failed
            local ok, err = pcall(function()
                evts.AddObject:InvokeServer(useType, worldCFrame)
            end)
            if not ok then
                log("AddObject failed: " .. tostring(err), C.danger)
            end

            -- 2) Find the NEW part — check snapshot first, then wait for ChildAdded
            local newPart = nil
            -- Check snapshot immediately
            for _, ch in ipairs(partsFolder:GetChildren()) do
                if not existingParts[ch] then
                    newPart = ch
                    break
                end
            end
            -- If not found immediately, wait for ChildAdded (up to 3 seconds)
            if not newPart then
                local waited = 0
                while not newPartFound and not newPart and waited < 3 do
                    -- Also re-check snapshot in case we missed it
                    for _, ch in ipairs(partsFolder:GetChildren()) do
                        if not existingParts[ch] then
                            newPart = ch
                            break
                        end
                    end
                    if not newPart and not newPartFound then
                        wait(0.05)
                        waited = waited + 0.05
                    end
                end
                -- Use ChildAdded result if snapshot didn't find it
                if not newPart and newPartFound then
                    newPart = newPartFound
                end
            end
            childAddedConn:Disconnect()

            if newPart then
                -- 3) MoveObject — set size + CFrame (preserves rotation)
                pcall(function()
                    evts.MoveObject:InvokeServer({
                        {
                            [1] = newPart,
                            [2] = worldCFrame,
                            [3] = brick.size,
                        }
                    })
                end)
                table.insert(placedParts, {brick = brick, part = newPart})
                log("Placed " .. i .. "/" .. #bricks .. ": " .. (newPart.Name or "?") .. " [" .. useType .. "]", C.text)
            else
                log("Could not find new part after AddObject (brick " .. i .. ")", C.danger)
            end

            setProgress(i / #bricks * 0.25, "Phase 1/4: Placing " .. i .. "/" .. #bricks)
            wait(buildSpeed)
        end

        log("Phase 1 done: " .. #placedParts .. " parts placed", C.success)

        -- ===== PHASE 2: APPLY COLORS + TRANSPARENCY =====
        if applyColors then
            log("Phase 2: Applying colors + transparency...", C.warn)
            for i, entry in ipairs(placedParts) do
                if cancelBuild then
                    log("Build cancelled during coloring", C.danger)
                    building = false
                    buildBtn.Text = "BUILD MODEL"
                    buildBtn.BackgroundColor3 = C.success
                    return
                end
                if entry.part and entry.part.Parent then
                    applyColorToPart(entry.part, entry.brick.color)
                    -- ALWAYS apply transparency (even if 0, to reset any default)
                    applyTransparencyToPart(entry.part, entry.brick.transparency)
                    log("Color " .. i .. "/" .. #placedParts .. ": " .. (entry.brick.name or "?") ..
                        " -> " .. tostring(entry.brick.color) .. " (transparency=" .. entry.brick.transparency .. ")", C.text)
                end
                setProgress(0.25 + i / #placedParts * 0.25, "Phase 2/4: Coloring " .. i .. "/" .. #placedParts)
                wait(buildSpeed)
            end
            log("Phase 2 done: colors + transparency applied", C.success)
        else
            log("Phase 2 skipped (Colors toggle OFF)", C.textDim)
        end

        -- ===== PHASE 3: APPLY MATERIALS + REFLECTANCE =====
        if applyMaterials then
            log("Phase 3: Applying materials + reflectance...", C.warn)
            for i, entry in ipairs(placedParts) do
                if cancelBuild then
                    log("Build cancelled during materials", C.danger)
                    building = false
                    buildBtn.Text = "BUILD MODEL"
                    buildBtn.BackgroundColor3 = C.success
                    return
                end
                if entry.part and entry.part.Parent then
                    applyMaterialToPart(entry.part, entry.brick.material)
                    -- ALWAYS apply reflectance (even if 0, to reset any default)
                    applyReflectanceToPart(entry.part, entry.brick.reflectance)
                    log("Material " .. i .. "/" .. #placedParts .. ": " .. (entry.brick.name or "?") ..
                        " -> " .. entry.brick.material.Name .. " (reflectance=" .. entry.brick.reflectance .. ")", C.text)
                end
                setProgress(0.50 + i / #placedParts * 0.25, "Phase 3/4: Material " .. i .. "/" .. #placedParts)
                wait(buildSpeed)
            end
            log("Phase 3 done: materials + reflectance applied", C.success)
        else
            log("Phase 3 skipped (Materials toggle OFF)", C.textDim)
        end

        -- ===== PHASE 4: APPLY EFFECTS (Fire, SurfaceLight, Texture, Decal) =====
        local totalEffects = 0
        for _, entry in ipairs(placedParts) do
            if entry.brick.effects then
                totalEffects = totalEffects + #entry.brick.effects
            end
        end
        if totalEffects > 0 then
            log("Phase 4: Applying " .. totalEffects .. " effects...", C.warn)
            local effectIdx = 0
            for i, entry in ipairs(placedParts) do
                if cancelBuild then
                    log("Build cancelled during effects", C.danger)
                    building = false
                    buildBtn.Text = "BUILD MODEL"
                    buildBtn.BackgroundColor3 = C.success
                    return
                end
                if entry.part and entry.part.Parent and entry.brick.effects then
                    for _, effect in ipairs(entry.brick.effects) do
                        -- 1) Add the effect: EffectObject:InvokeServer({part}, type, "Default")
                        local addOk, addErr = pcall(function()
                            evts.EffectObject:InvokeServer({entry.part}, effect.type, "Default")
                        end)
                        if not addOk then
                            log("  Effect add FAILED: " .. tostring(addErr), C.danger)
                        end
                        wait(0.5)  -- wait longer for server to create the effect

                        -- 2) Set each property: EffectObject:InvokeServer({part}, type, property, value)
                        for _, propData in ipairs(effect.props) do
                            local propName, propValue = propData[1], propData[2]
                            local propOk, propErr = pcall(function()
                                evts.EffectObject:InvokeServer({entry.part}, effect.type, propName, propValue)
                            end)
                            if not propOk then
                                log("  Property '" .. propName .. "' FAILED: " .. tostring(propErr), C.danger)
                            end
                            wait(0.1)  -- small delay between each property
                        end

                        effectIdx = effectIdx + 1
                        -- Build a property summary for the log
                        local propSummary = {}
                        for _, pd in ipairs(effect.props) do
                            table.insert(propSummary, pd[1] .. "=" .. tostring(pd[2]))
                        end
                        log("Effect " .. effectIdx .. "/" .. totalEffects .. ": " ..
                            (entry.brick.name or "?") .. " + " .. effect.type ..
                            " (" .. table.concat(propSummary, ", ") .. ")", C.text)
                    end
                end
                setProgress(0.75 + i / #placedParts * 0.25, "Phase 4/5: Effects " .. i .. "/" .. #placedParts)
                wait(buildSpeed)
            end
            log("Phase 4 done: " .. totalEffects .. " effects applied", C.success)
        else
            log("Phase 4: No effects found in model, skipping", C.textDim)
        end

        -- ===== PHASE 5: CONVERT SPIN PARTS =====
        -- For any part that had spin properties detected, we create a "Spin Part"
        -- at the same position, transfer all properties, then delete the original.
        local spinCount = 0
        for _, entry in ipairs(placedParts) do
            if entry.brick.spinProps then spinCount = spinCount + 1 end
        end
        if spinCount > 0 then
            log("Phase 5: Converting " .. spinCount .. " spin parts...", C.warn)
            local spinIdx = 0
            for i, entry in ipairs(placedParts) do
                if cancelBuild then
                    log("Build cancelled during spin conversion", C.danger)
                    building = false
                    buildBtn.Text = "BUILD MODEL"
                    buildBtn.BackgroundColor3 = C.success
                    return
                end
                if entry.part and entry.part.Parent and entry.brick.spinProps then
                    local sp = entry.brick.spinProps
                    local origPart = entry.part
                    local origCFrame = origPart.CFrame
                    local origSize = origPart.Size
                    local origColor = origPart.Color
                    local origMaterial = origPart.Material
                    local origTransparency = origPart.Transparency
                    local origReflectance = origPart.Reflectance

                    -- Get the Spin Parts folder BEFORE creating
                    local obby = workspace:FindFirstChild("Obbies")
                    if obby then obby = obby:FindFirstChild(plr.Name) end
                    local spinFolder = obby and obby:FindFirstChild("Items") and obby.Items:FindFirstChild("Spin Parts")

                    if not spinFolder then
                        log("Could not find Spin Parts folder! Creating spin part anyway...", C.warn)
                    end

                    -- SNAPSHOT existing spin parts BEFORE AddObject
                    local existingSpinParts = {}
                    if spinFolder then
                        for _, ch in ipairs(spinFolder:GetChildren()) do
                            existingSpinParts[ch] = true
                        end
                    end

                    -- 1) Create the Spin Part
                    log("Creating Spin Part at " .. tostring(origCFrame.Position), C.accent)
                    local addOk, addErr = pcall(function()
                        evts.AddObject:InvokeServer("Spin Part", origCFrame)
                    end)
                    if not addOk then
                        log("Spin Part AddObject FAILED: " .. tostring(addErr), C.danger)
                    end
                    wait(0.5)

                    -- 2) Find the NEW Spin Part (the one not in our snapshot)
                    local newSpin = nil
                    if spinFolder then
                        local waited = 0
                        while not newSpin and waited < 3 do
                            for _, ch in ipairs(spinFolder:GetChildren()) do
                                if not existingSpinParts[ch] then
                                    newSpin = ch
                                    break
                                end
                            end
                            if not newSpin then
                                wait(0.1)
                                waited = waited + 0.1
                            end
                        end
                    end

                    if not newSpin then
                        log("Could not find new Spin Part! Skipping.", C.danger)
                    else
                        log("Found new Spin Part: " .. (newSpin.Name or "?"), C.accent)
                        -- 3) Set size + position via MoveObject
                        pcall(function()
                            evts.MoveObject:InvokeServer({
                                {
                                    [1] = newSpin,
                                    [2] = origCFrame,
                                    [3] = origSize,
                                }
                            })
                        end)
                        wait(0.1)

                        -- 4) Apply color + material to the spin part
                        if applyColors then
                            applyColorToPart(newSpin, origColor)
                            applyTransparencyToPart(newSpin, origTransparency)
                        end
                        if applyMaterials then
                            applyMaterialToPart(newSpin, origMaterial)
                            applyReflectanceToPart(newSpin, origReflectance)
                        end

                        -- 5) Apply spin properties via BehaviourObject
                        local bhvr = evts:FindFirstChild("BehaviourObject")
                        if bhvr then
                            pcall(function() bhvr:InvokeServer({newSpin}, "sO", sp.sO) end)
                            pcall(function() bhvr:InvokeServer({newSpin}, "sT", sp.sT) end)
                            pcall(function() bhvr:InvokeServer({newSpin}, "sd", sp.sd) end)
                            pcall(function() bhvr:InvokeServer({newSpin}, "sA", sp.sA) end)
                            pcall(function() bhvr:InvokeServer({newSpin}, "A", sp.A) end)
                            pcall(function() bhvr:InvokeServer({newSpin}, "mR", sp.mR) end)
                            pcall(function() bhvr:InvokeServer({newSpin}, "Ed", sp.Ed) end)
                            -- NEVER send "Line" as easing style — crashes the server
                            if sp.E ~= "Line" then
                                pcall(function() bhvr:InvokeServer({newSpin}, "E", sp.E) end)
                            else
                                pcall(function() bhvr:InvokeServer({newSpin}, "E", "Sine") end)
                            end
                        end

                        -- 6) Delete the original part
                        pcall(function()
                            evts.DeleteObject:InvokeServer({origPart})
                        end)

                        spinIdx = spinIdx + 1
                        log("Spin " .. spinIdx .. "/" .. spinCount .. ": " .. (entry.brick.name or "?") ..
                            " (axis=" .. sp.A .. ", time=" .. sp.sT .. ", offset=" .. sp.sO .. ")", C.text)
                    end
                end
                setProgress(0.80 + i / #placedParts * 0.20, "Phase 5/5: Spin Parts " .. i .. "/" .. #placedParts)
                wait(buildSpeed)
            end
            log("Phase 5 done: " .. spinCount .. " spin parts converted", C.success)
        else
            log("Phase 5: No spin parts found, skipping", C.textDim)
        end

        setProgress(1, "Build complete! " .. #placedParts .. " bricks")
        log("=== BUILD COMPLETE ===", C.success)
        building = false
        buildBtn.Text = "BUILD MODEL"
        buildBtn.BackgroundColor3 = C.success
    end)
end

buildBtn.MouseButton1Click:Connect(function()
    if building then
        log("Already building — cancel first", C.warn)
        return
    end
    if not loadedModel then
        log("Load a model first!", C.danger)
        return
    end
    if not placingMode and not ghostModel then
        -- Auto-start ghost mode
        startGhost()
        log("Click in world to place, then build starts", C.accent)
        return
    end
end)

cancelBtn.MouseButton1Click:Connect(function()
    if building then
        cancelBuild = true
        log("Cancelling...", C.warn)
    else
        clearGhost()
        log("Nothing to cancel", C.textDim)
    end
end)

-- ============================================================
-- LOAD MODEL
-- ============================================================
-- ===== LOAD MODEL FUNCTION (shared by LOAD and FORCE LOAD buttons) =====
local function loadModel(id, forceMode)
    loadStatus.Text = "Loading model " .. id .. (forceMode and " (FORCE)..." or "...")
    loadStatus.TextColor3 = C.warn
    log("Loading model ID " .. id .. (forceMode and " (FORCE MODE)" or ""), C.accent)

    -- Clean up previous model
    if loadedModel then loadedModel:Destroy() end
    clearGhost()

    spawn(function()
        local model = nil
        local loadErr = nil

        -- Timeout helper: runs a function and returns nil if it takes too long
        local function loadWithTimeout(func, timeoutSec)
            local result = nil
            local done = false
            local co = coroutine.create(function()
                local ok, res = pcall(func)
                result = {ok = ok, res = res}
                done = true
            end)
            coroutine.resume(co)
            local waited = 0
            while not done and waited < timeoutSec do
                wait(0.1)
                waited = waited + 0.1
            end
            if not done then
                log("Load method timed out after " .. timeoutSec .. "s", C.warn)
                return nil, "timeout"
            end
            if not result.ok then
                return nil, tostring(result.res)
            end
            return result.res, nil
        end

        -- Method 1: game:GetObjects (executor function — preferred) — 10s timeout
        local result, err = loadWithTimeout(function()
            return game:GetObjects("rbxassetid://" .. id)
        end, 10)
        if result then
            if type(result) == "table" then
                if #result > 0 then
                    model = result[1]
                    log("Loaded via game:GetObjects (table)", C.success)
                else
                    loadErr = "game:GetObjects returned empty"
                    log(loadErr, C.warn)
                end
            elseif typeof(result) == "Instance" then
                model = result
                log("Loaded via game:GetObjects (instance)", C.success)
            else
                loadErr = "game:GetObjects returned: " .. typeof(result)
                log(loadErr, C.warn)
            end
        else
            loadErr = err or "unknown error"
            log("game:GetObjects failed: " .. loadErr, C.warn)
        end

        -- Method 2: InsertService fallback — 10s timeout
        if not model then
            result, err = loadWithTimeout(function()
                return InsertService:LoadAsset(id)
            end, 10)
            if result then
                model = result
                if model:IsA("Model") then
                    local inner = model:FindFirstChildOfClass("Model")
                    if inner then model = inner end
                end
                log("Loaded via InsertService", C.success)
            else
                loadErr = err or "unknown error"
            end
        end

        -- Method 3 (FORCE MODE only): try alternatives with timeouts
        if not model and forceMode then
            log("FORCE MODE: trying alternative load methods...", C.warn)

            -- Try without rbxassetid prefix — 10s timeout
            result, err = loadWithTimeout(function()
                return game:GetObjects(id)
            end, 10)
            if result then
                if type(result) == "table" and #result > 0 then
                    model = result[1]
                    log("Loaded via game:GetObjects (raw ID)", C.success)
                elseif typeof(result) == "Instance" then
                    model = result
                    log("Loaded via game:GetObjects (raw ID, instance)", C.success)
                end
            end

            -- Try with https URL — 10s timeout
            if not model then
                result, err = loadWithTimeout(function()
                    return game:GetObjects("https://www.roblox.com/item?id=" .. id)
                end, 10)
                if result then
                    if type(result) == "table" and #result > 0 then
                        model = result[1]
                        log("Loaded via game:GetObjects (https URL)", C.success)
                    elseif typeof(result) == "Instance" then
                        model = result
                        log("Loaded via game:GetObjects (https URL, instance)", C.success)
                    end
                end
            end

            -- Try LoadAsset one more time — 10s timeout
            if not model then
                result, err = loadWithTimeout(function()
                    return InsertService:LoadAsset(id)
                end, 10)
                if result then
                    model = result
                    if model:IsA("Model") then
                        local inner = model:FindFirstChildOfClass("Model")
                        if inner then model = inner end
                    end
                    log("Loaded via InsertService (retry)", C.success)
                else
                    loadErr = err or "unknown error"
                end
            end
        end

        if not model then
            loadStatus.Text = "Failed to load"
            loadStatus.TextColor3 = C.danger
            log("Failed to load model: " .. tostring(loadErr), C.danger)
            if not forceMode then
                log("Try FORCE LOAD button — it tries alternative methods.", C.warn)
            else
                log("All load methods failed. This model may be a package or copylocked.", C.warn)
            end
            return
        end

        -- ===== FIND THE RICHEST MODEL (most BaseParts) =====
        local function countBaseParts(obj)
            local count = 0
            if obj:IsA("BasePart") then count = 1 end
            for _, d in ipairs(obj:GetDescendants()) do
                if d:IsA("BasePart") then count = count + 1 end
            end
            return count
        end

        local bestModel = model
        local bestCount = countBaseParts(model)
        log("Initial object: " .. model.ClassName .. " '" .. (model.Name or "?") .. "' with " .. bestCount .. " BaseParts", C.text)

        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("Model") or d:IsA("Folder") or d:IsA("Tool") or d:IsA("Accoutrement") then
                local c = countBaseParts(d)
                if c > bestCount then
                    bestCount = c
                    bestModel = d
                    log("Found richer model: " .. d.ClassName .. " '" .. (d.Name or "?") .. "' with " .. c .. " BaseParts", C.text)
                end
            end
        end

        model = bestModel
        local brickCount = bestCount

        if brickCount == 0 then
            loadStatus.Text = "No parts in model"
            loadStatus.TextColor3 = C.danger
            log("Model has no BaseParts", C.danger)
            return
        end

        -- Log model structure breakdown
        local meshParts = 0
        local regularParts = 0
        local unions = 0
        local other = 0
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then
                if d:IsA("MeshPart") then meshParts = meshParts + 1
                elseif d:IsA("UnionOperation") then unions = unions + 1
                elseif d:IsA("Part") then regularParts = regularParts + 1
                else other = other + 1 end
            end
        end
        log("Breakdown: " .. regularParts .. " Parts, " .. meshParts .. " MeshParts, " .. unions .. " Unions, " .. other .. " other", C.accent)

        -- Store the model (hide it — make all parts invisible + move far below)
        loadedModel = model
        -- Capture the ORIGINAL pivot BEFORE moving
        loadedModelPivot = model:GetPivot()

        -- ===== CAPTURE ORIGINAL PART DATA BEFORE HIDING =====
        -- collectBricks will use this snapshot instead of reading from the
        -- (now-modified) live parts. This prevents the "511 filtered, 0 to build" bug.
        origPartData = {}
        for _, p in ipairs(model:GetDescendants()) do
            if p:IsA("BasePart") then
                origPartData[p] = {
                    transparency = p.Transparency,
                    canCollide = p.CanCollide,
                    size = p.Size,
                    color = p.Color,
                    material = p.Material,
                    reflectance = p.Reflectance,
                    cframe = p.CFrame,
                    name = p.Name,
                    className = p.ClassName,
                    shape = p:IsA("Part") and p.Shape or nil,
                }
            end
        end
        log("Captured " .. #model:GetDescendants() .. " descendants (" .. brickCount .. " BaseParts) before hiding", C.text)

        model.Parent = workspace
        model:PivotTo(CFrame.new(0, -1000, 0))
        for _, p in ipairs(model:GetDescendants()) do
            if p:IsA("BasePart") then
                p.Transparency = 1
                p.CanCollide = false
                p.CanQuery = false
                p.CanTouch = false
            end
        end

        loadStatus.Text = "Loaded: " .. brickCount .. " bricks"
        loadStatus.TextColor3 = C.success
        log("Model loaded: " .. brickCount .. " bricks. Click PLACE to start.", C.success)
    end)
end

loadBtn.MouseButton1Click:Connect(function()
    local idText = idBox.Text
    local id = tonumber(idText:match("%d+"))
    if not id then
        loadStatus.Text = "Invalid ID"
        loadStatus.TextColor3 = C.danger
        log("Invalid model ID: " .. idText, C.danger)
        return
    end
    loadModel(id, false)
end)

forceLoadBtn.MouseButton1Click:Connect(function()
    local idText = idBox.Text
    local id = tonumber(idText:match("%d+"))
    if not id then
        loadStatus.Text = "Invalid ID"
        loadStatus.TextColor3 = C.danger
        log("Invalid model ID: " .. idText, C.danger)
        return
    end
    loadModel(id, true)
end)

-- ============================================================
-- INIT
-- ============================================================
log("=== Model Importer ===", C.accent)
log("1. Enter model ID -> click LOAD", C.text)
log("2. Click PLACE -> ghost follows mouse", C.text)
log("3. Click in world -> build starts", C.text)
log("Phases: place all -> color all -> material all", C.text)

end, function(err)
    local msg = tostring(err) .. "\n" .. debug.traceback()
    pcall(function() warn("[IMPORTER ERROR] " .. msg) end)
    pcall(function()
        local sg = Instance.new("ScreenGui")
        sg.Name = "ImporterError"
        sg.Parent = game:GetService("CoreGui")
        local tf = Instance.new("TextLabel")
        tf.Size = UDim2.new(0.6, 0, 0.6, 0)
        tf.Position = UDim2.new(0.2, 0, 0.2, 0)
        tf.BackgroundColor3 = Color3.fromRGB(20, 0, 0)
        tf.TextColor3 = Color3.new(1, 1, 1)
        tf.Text = "[IMPORTER ERROR]\n" .. msg
        tf.Font = Enum.Font.Gotham
        tf.TextSize = 12
        tf.TextWrapped = true
        tf.TextXAlignment = Enum.TextXAlignment.Left
        tf.TextYAlignment = Enum.TextYAlignment.Top
        tf.Parent = sg
    end)
    return msg
end)

if not _ok then
    pcall(function() print("[IMPORTER] Script failed: " .. tostring(_err)) end)
end
