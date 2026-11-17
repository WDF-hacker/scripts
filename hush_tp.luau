--[[
    HUSH TP 测试工具 v3（仅小号，本地测试）
    - H：向相机朝向跳 15 studs（短距，落在 30 基础额度内）
    - J：TP 到最近的撤离点（远距，测试 snap_far）
    - _G.HUSH_TP_TO(x,y,z) 手动坐标 TP
    - 屏幕下方显示结果；hush_tp.log 记录
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")

local LOG = "hush_tp.log"
if not isfile(LOG) then writefile(LOG, "") end
local function log(s) pcall(function() appendfile(LOG, s .. "\n") end) end

local lp = Players.LocalPlayer
local DIST = 15
local COOLDOWN = 2.5
local lastAt = 0

local gui = Instance.new("ScreenGui")
gui.Name = "HushTpHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local label = Instance.new("TextLabel")
label.Size = UDim2.new(0, 520, 0, 30)
label.Position = UDim2.new(0.5, -260, 1, -80)
label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
label.BackgroundTransparency = 0.25
label.TextColor3 = Color3.fromRGB(255, 220, 120)
label.Font = Enum.Font.GothamBold
label.TextSize = 15
label.Text = "TP: H=15 studs  J=最近撤离点"
label.Parent = gui
local hideAt = os.clock() + 6

local function show(msg, color)
    label.Text = msg
    label.TextColor3 = color or Color3.fromRGB(255, 220, 120)
    label.Visible = true
    hideAt = os.clock() + 6
    log("UI " .. msg)
end

local function findGround(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local f = {}
    if lp.Character then f[#f + 1] = lp.Character end
    params.FilterDescendantsInstances = f
    local hit = workspace:Raycast(pos + Vector3.new(0, 80, 0), Vector3.new(0, -200, 0), params)
    return hit and hit.Position or nil
end

local function tpTo(pos, labelText)
    local ch = lp.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not hrp then return "no character" end
    local ground = findGround(pos)
    if not ground then return "no ground at target" end
    local from = hrp.Position
    local dest = ground + Vector3.new(0, 3.2, 0)
    hrp.CFrame = CFrame.new(dest)
    lastAt = os.clock()
    local moved = (dest - from).Magnitude
    log(string.format("%s TP %s dist=%.1f from=%.1f,%.1f,%.1f to=%.1f,%.1f,%.1f moved=%.1f",
        os.date("!%H:%M:%S"), tostring(labelText or "to"), (pos - from).Magnitude,
        from.X, from.Y, from.Z, dest.X, dest.Y, dest.Z, moved))
    return string.format("TP 成功 %.0f studs", moved)
end

local function hop(dist)
    dist = tonumber(dist) or DIST
    local ch = lp.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    local cam = workspace.CurrentCamera
    if not hrp or not cam then return "no character" end
    local now = os.clock()
    if now - lastAt < COOLDOWN then
        return string.format("冷却中 %.1fs", COOLDOWN - (now - lastAt))
    end
    local look = cam.CFrame.LookVector
    look = Vector3.new(look.X, 0, look.Z)
    if look.Magnitude < 0.01 then return "camera look invalid" end
    look = look.Unit
    local target = hrp.Position + look * dist
    local ground = findGround(target)
    if not ground then return "no ground under target" end
    local from = hrp.Position
    local dest = ground + Vector3.new(0, 3.2, 0)
    hrp.CFrame = CFrame.new(dest) * CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
    lastAt = now
    local moved = (dest - from).Magnitude
    log(string.format("%s HOP dist=%.1f from=%.1f,%.1f,%.1f to=%.1f,%.1f,%.1f moved=%.1f",
        os.date("!%H:%M:%S"), dist, from.X, from.Y, from.Z, dest.X, dest.Y, dest.Z, moved))
    return string.format("TP 成功 %.0f studs", moved)
end

local function nearestExtract()
    local raid = workspace:FindFirstChild("Raid")
    local ex = raid and raid:FindFirstChild("Extracts")
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not ex or not hrp then return nil end
    local best, bestD = nil, math.huge
    for _, c in ipairs(ex:GetChildren()) do
        local pos
        if c:IsA("Model") then
            local p = c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart", true)
            pos = p and p.Position
        elseif c:IsA("BasePart") then
            pos = c.Position
        end
        if pos then
            local d = (pos - hrp.Position).Magnitude
            if d < bestD then best, bestD = { name = c.Name, pos = pos }, d end
        end
    end
    return best
end

_G.HUSH_TP = hop
_G.HUSH_TP_TO = function(x, y, z) return tpTo(Vector3.new(x, y, z), "manual") end
_G.HUSH_TP_EXTRACT = function()
    local e = nearestExtract()
    if not e then return "no extract" end
    return tpTo(e.pos, e.name)
end

UIS.InputBegan:Connect(function(input, gp)
    if input.KeyCode == Enum.KeyCode.H then
        local ok, res = pcall(hop, DIST)
        if not ok then res = "error: " .. tostring(res) end
        show(tostring(res), tostring(res):find("成功") and Color3.fromRGB(120, 255, 140) or Color3.fromRGB(255, 120, 120))
    elseif input.KeyCode == Enum.KeyCode.J then
        local ok, res = pcall(_G.HUSH_TP_EXTRACT)
        if not ok then res = "error: " .. tostring(res) end
        show(tostring(res), tostring(res):find("成功") and Color3.fromRGB(255, 180, 60) or Color3.fromRGB(255, 120, 120))
    end
end)

task.spawn(function()
    while true do
        task.wait(0.5)
        if os.clock() > hideAt then label.Visible = false end
    end
end)

log(string.format("# SESSION %s user=%s key=H/J", os.date("!%Y-%m-%dT%H:%M:%S"), lp.Name))
print("[HUSH-TP] v3 loaded: H=15, J=extract")
