--[[
    HUSH TP 测试工具 v2（仅小号）
    - 按键 **H**：向相机朝向跳 15 studs（T 被手电筒占用）
    - 冷却 2.5 秒
    - 屏幕下方显示结果（成功/失败原因），另有 hush_tp.log
    - _G.HUSH_TP(距离) 可手动调用
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

-- 屏幕提示
local gui = Instance.new("ScreenGui")
gui.Name = "HushTpHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local label = Instance.new("TextLabel")
label.Size = UDim2.new(0, 420, 0, 30)
label.Position = UDim2.new(0.5, -210, 1, -80)
label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
label.BackgroundTransparency = 0.25
label.TextColor3 = Color3.fromRGB(255, 220, 120)
label.Font = Enum.Font.GothamBold
label.TextSize = 15
label.Text = "TP 工具已加载：按 H 跳 15 studs"
label.Parent = gui
local hideAt = os.clock() + 6

local function show(msg, color)
    label.Text = msg
    label.TextColor3 = color or Color3.fromRGB(255, 220, 120)
    label.Visible = true
    hideAt = os.clock() + 5
    log("UI " .. msg)
end

local function findGround(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local f = {}
    if lp.Character then f[#f + 1] = lp.Character end
    params.FilterDescendantsInstances = f
    local hit = workspace:Raycast(pos + Vector3.new(0, 60, 0), Vector3.new(0, -160, 0), params)
    if hit then return hit.Position end
    return nil
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
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { ch }
    for i = 0, 4 do
        local try = dest + Vector3.new(0, i * 2, 0)
        local blocked = workspace:GetPartBoundsInBox(CFrame.new(try), Vector3.new(2, 4, 2), params)
        if #blocked == 0 then
            dest = try
            break
        end
        if i == 4 then return "landing blocked" end
    end
    hrp.CFrame = CFrame.new(dest) * CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
    lastAt = now
    local moved = (dest - from).Magnitude
    log(string.format("%s HOP dist=%.1f from=%.1f,%.1f,%.1f to=%.1f,%.1f,%.1f moved=%.1f",
        os.date("!%H:%M:%S"), dist, from.X, from.Y, from.Z, dest.X, dest.Y, dest.Z, moved))
    return string.format("TP 成功 %.0f studs", moved)
end

_G.HUSH_TP = hop

UIS.InputBegan:Connect(function(input, gp)
    if input.KeyCode == Enum.KeyCode.H then
        local ok, res = pcall(hop, DIST)
        if not ok then res = "error: " .. tostring(res) end
        if tostring(res):find("TP 成功") then
            show(tostring(res), Color3.fromRGB(120, 255, 140))
        else
            show("TP 失败：" .. tostring(res), Color3.fromRGB(255, 120, 120))
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(0.5)
        if os.clock() > hideAt then label.Visible = false end
    end
end)

log(string.format("# SESSION %s user=%s dist=%d key=H", os.date("!%Y-%m-%dT%H:%M:%S"), lp.Name, DIST))
print("[HUSH-TP] v2 loaded: press H")
