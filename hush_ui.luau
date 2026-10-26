--[[
    HUSH AIM UI v1  (Obsidian)
    - 静默瞄准：读游戏僵尸注册表 -> 只打 FOV 圈内的活僵尸 -> 改 d/ay 打指定部位，**不改 sp**
    - FOV 圈：跟随鼠标绘制，只有圈内目标才会被锁
    - 透视：方框 / 四角框 两种样式，名字 / 类型 / 距离 / 连线 可单独开关
    快捷键：RightShift 开关面板
]]
local PREFIX = "[HUSH-UI]"
local VERSION = 1

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")

local lp
do
    local deadline = os.clock() + 120
    while not lp and os.clock() < deadline do
        lp = Players.LocalPlayer
        if not lp then task.wait(0.5) end
    end
end
if not lp then return end

-- 关掉 autoexec 里那份，避免重复 hook / 重复画
pcall(function()
    if _G.HUSH_Z then
        _G.HUSH_Z.cfg.esp = false
        _G.HUSH_Z.cfg.silent = false
    end
end)

--============ UI 库 ============
local LIB_FILE = "obsidian_Library.lua"
local Library
do
    local src
    if isfile and isfile(LIB_FILE) then src = readfile(LIB_FILE) end
    if (not src or #src < 1000) then
        local ok, fetched = pcall(function()
            return game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/Library.lua")
        end)
        if ok and type(fetched) == "string" and #fetched > 1000 then
            src = fetched
            pcall(function() writefile(LIB_FILE, src) end)
        end
    end
    if src and #src > 1000 then
        local fn = loadstring(src)
        if fn then
            local ok, res = pcall(fn)
            if ok then Library = res else warn(PREFIX .. " UI lib error: " .. tostring(res)) end
        end
    end
end

--============ 配置 ============
local cfg = {
    silent = true,
    fov = 350,
    showFov = true,
    fovColor = Color3.fromRGB(120, 200, 255),
    maxDist = 250,
    part = "head",
    los = true,
    predict = true,
    lead = 0.08,
    pauseWatched = false,
    onlyOnScreen = true,

    esp = true,
    style = "corner",
    espName = true,
    espKind = true,
    espDist = true,
    tracer = false,
    espMaxDist = 300,
    thickness = 1,
    textSize = 13,
    espColor = Color3.fromRGB(120, 255, 140)
}
_G.HUSH_UI_CFG = cfg

--============ 僵尸注册表 ============
local function scoreReg(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for k, v in pairs(t) do
        if type(k) == "number" and type(v) == "table" and v.dead ~= nil and v.x ~= nil then n = n + 1 end
    end
    return n
end

local registry, registryAt = nil, 0
local function findRegistry()
    if registry and os.clock() - registryAt < 3 then return registry end
    local ev
    pcall(function() ev = RS.HushNet["zombie.event"] end)
    if not ev then return nil end
    local best, bestScore = nil, 0
    local okc, conns = pcall(getconnections, ev.OnClientEvent)
    if not okc or type(conns) ~= "table" then return registry end
    for _, c in ipairs(conns) do
        local ok, uvs = pcall(function() return debug.getupvalues(c.Function) end)
        if ok and type(uvs) == "table" then
            for _, uv in ipairs(uvs) do
                local s = scoreReg(uv)
                if s > bestScore then best, bestScore = uv, s end
                if type(uv) == "function" then
                    local ok2, uvs2 = pcall(function() return debug.getupvalues(uv) end)
                    if ok2 and type(uvs2) == "table" then
                        for _, uv2 in ipairs(uvs2) do
                            local s2 = scoreReg(uv2)
                            if s2 > bestScore then best, bestScore = uv2, s2 end
                        end
                    end
                end
            end
        end
    end
    if best then registry, registryAt = best, os.clock() end
    return registry
end

local function listAlive()
    local reg = findRegistry()
    local out = {}
    if not reg then return out end
    for _, rec in pairs(reg) do
        if type(rec) == "table" and rec.dead ~= true then
            local rig = rec.rig
            local model = type(rig) == "table" and rig.model
            local root = type(rig) == "table" and rig.root
            if model and root and root.Parent and root.Position.Y > -100 then
                local scale = (type(rig) == "table" and tonumber(rig.scale)) or 1
                local headPos = root.Position + Vector3.new(0, 1.55 * scale, 0)
                local head = model:FindFirstChild("Head")
                if head and head:IsA("BasePart") and math.abs(head.Position.Y - root.Position.Y) < 4 then
                    headPos = head.Position
                end
                local chest = root.Position + Vector3.new(0, 0.35 * scale, 0)
                local neck = headPos - Vector3.new(0, 0.35 * scale, 0)
                out[#out + 1] = {
                    id = rec.id,
                    kind = tostring(rec.kind),
                    model = model,
                    root = root,
                    head = headPos,
                    neck = neck,
                    chest = chest,
                    pos = root.Position
                }
            end
        end
    end
    return out
end
_G.HUSH_UI = { cfg = cfg, listAlive = listAlive }

local function aimPointOf(z)
    if cfg.part == "neck" then return z.neck end
    if cfg.part == "chest" then return z.chest end
    return z.head
end

--============ 公用 ============
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true

local function los(from, to)
    local f = {}
    if lp.Character then f[1] = lp.Character end
    params.FilterDescendantsInstances = f
    local delta = to - from
    local hit = workspace:Raycast(from, delta, params)
    if not hit then return true end
    return hit.Distance >= delta.Magnitude - 0.5
end

local function mousePos()
    local p = UIS:GetMouseLocation()
    return Vector2.new(p.X, p.Y)
end

local function project(pos)
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    local sp, on = cam:WorldToViewportPoint(pos)
    if not on or sp.Z <= 0 then return nil end
    return Vector2.new(sp.X, sp.Y), sp.Z
end

local function pickTarget(o)
    local cam = workspace.CurrentCamera
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not cam or not hrp then return nil end
    local mp = mousePos()
    local best, bestD = nil, math.huge
    for _, z in ipairs(listAlive()) do
        local dist = (z.pos - hrp.Position).Magnitude
        if dist <= cfg.maxDist then
            local sp = project(aimPointOf(z))
            if sp then
                local dpx = (sp - mp).Magnitude
                if dpx <= cfg.fov and dpx < bestD then
                    if (not cfg.los) or los(o, aimPointOf(z)) then
                        best, bestD = { z = z, px = dpx, dist = dist }, dpx
                    end
                end
            end
        end
    end
    return best
end

--============ FOV 圈 ============
local fovCircle = Drawing.new("Circle")
fovCircle.Thickness = 1.5
fovCircle.Filled = false
fovCircle.Transparency = 0.9
fovCircle.NumSides = 64
fovCircle.Visible = false

--============ ESP ============
local POOL = 48
local pool = {}
for i = 1, POOL do
    local s = { lines = {}, text = Drawing.new("Text") }
    s.text.Size = cfg.textSize
    s.text.Center = true
    s.text.Outline = true
    s.text.Visible = false
    for j = 1, 8 do
        local ln = Drawing.new("Line")
        ln.Thickness = cfg.thickness
        ln.Visible = false
        s.lines[j] = ln
    end
    s.square = Drawing.new("Square")
    s.square.Filled = false
    s.square.Thickness = cfg.thickness
    s.square.Visible = false
    s.tracer = Drawing.new("Line")
    s.tracer.Thickness = 1
    s.tracer.Visible = false
    pool[i] = s
end

local function hideSlot(s)
    s.text.Visible = false
    s.square.Visible = false
    s.tracer.Visible = false
    for j = 1, 8 do s.lines[j].Visible = false end
end

local function drawCorner(s, x, y, w, h, c)
    local cx = math.min(12, w * 0.35)
    local cy = math.min(12, h * 0.35)
    local pts = {
        { x, y, x + cx, y }, { x, y, x, y + cy },
        { x + w, y, x + w - cx, y }, { x + w, y, x + w, y + cy },
        { x, y + h, x + cx, y + h }, { x, y + h, x, y + h - cy },
        { x + w, y + h, x + w - cx, y + h }, { x + w, y + h, x + w, y + h - cy }
    }
    for j = 1, 8 do
        local ln = s.lines[j]
        local p = pts[j]
        ln.From = Vector2.new(p[1], p[2])
        ln.To = Vector2.new(p[3], p[4])
        ln.Color = c
        ln.Visible = true
    end
end

--============ 静默瞄准 ============
local Net
do
    local hush = RS:FindFirstChild("Hush")
    local mod = hush and hush:FindFirstChild("Shared") and hush.Shared:FindFirstChild("Net")
    if mod then Net = require(mod) end
end

if Net then
    local oldFire = Net.fire
    Net.fire = function(name, payload)
        if cfg.silent and name == "combat.fire" and type(payload) == "table" and payload.o and payload.d then
            pcall(function()
                if cfg.pauseWatched and lp:GetAttribute("Watched") == true then return end
                local pick = pickTarget(payload.o)
                if not pick then return end
                local z = pick.z
                local ap = aimPointOf(z)
                if cfg.predict then
                    local vel = z.root.AssemblyLinearVelocity
                    ap = ap + vel * cfg.lead
                end
                local nd = (ap - payload.o).Unit
                payload.d = nd
                payload.ay = -math.atan2(nd.X, -nd.Z)
            end)
        end
        return oldFire(name, payload)
    end
end

--============ 渲染循环 ============
local lastTargetName = "-"

RunService.RenderStepped:Connect(function()
    -- FOV 圈
    if cfg.showFov and cfg.silent then
        fovCircle.Position = mousePos()
        fovCircle.Radius = cfg.fov
        fovCircle.Color = cfg.fovColor
        fovCircle.Visible = true
    else
        fovCircle.Visible = false
    end

    -- ESP
    if not cfg.esp then
        for _, s in ipairs(pool) do hideSlot(s) end
        return
    end
    pcall(function()
        local cam = workspace.CurrentCamera
        local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
        if not cam or not hrp then return end
        local used = 0
        for _, z in ipairs(listAlive()) do
            local dist = (z.pos - hrp.Position).Magnitude
            if dist <= cfg.espMaxDist then
                local sp, depth = project(z.head)
                if sp and used < POOL then
                    used = used + 1
                    local s = pool[used]
                    local h = math.clamp(1500 / math.max(depth, 1), 24, 200)
                    local w = h * 0.6
                    local x, y = sp.X - w / 2, sp.Y - h / 2
                    local c = cfg.espColor
                    if cfg.style == "corner" then
                        s.square.Visible = false
                        drawCorner(s, x, y, w, h, c)
                    else
                        for j = 1, 8 do s.lines[j].Visible = false end
                        s.square.Position = Vector2.new(x, y)
                        s.square.Size = Vector2.new(w, h)
                        s.square.Color = c
                        s.square.Thickness = cfg.thickness
                        s.square.Visible = true
                    end
                    local parts = {}
                    if cfg.espKind then parts[#parts + 1] = z.kind end
                    if cfg.espName then parts[#parts + 1] = "#" .. tostring(z.id) end
                    if cfg.espDist then parts[#parts + 1] = string.format("%.0fm", dist) end
                    s.text.Text = table.concat(parts, " ")
                    s.text.Position = Vector2.new(sp.X, y - 16)
                    s.text.Size = cfg.textSize
                    s.text.Color = c
                    s.text.Visible = true
                    if cfg.tracer then
                        s.tracer.From = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
                        s.tracer.To = Vector2.new(sp.X, sp.Y + h / 2)
                        s.tracer.Color = c
                        s.tracer.Visible = true
                    else
                        s.tracer.Visible = false
                    end
                end
            end
        end
        for i = used + 1, POOL do hideSlot(pool[i]) end
        local pick = pickTarget(hrp.Position + Vector3.new(0, 1.1, 0))
        lastTargetName = pick and (pick.z.kind .. " #" .. tostring(pick.z.id)) or "-"
    end)
end)

--============ UI ============
local Tabs, A = nil, {}
if Library then
    local Window = Library:CreateWindow({
        Title = "HUSH 辅助",
        Footer = "v" .. VERSION,
        ToggleKeybind = Enum.KeyCode.RightShift,
        Resizable = true,
        ShowCustomCursor = false
    })
    Tabs = {
        Aim = Window:AddTab("静默瞄准", "crosshair"),
        Esp = Window:AddTab("透视", "box"),
        Status = Window:AddTab("状态", "activity")
    }

    local gA = Tabs.Aim:AddLeftGroupbox("瞄准", "crosshair")
    A.silent = gA:AddToggle("silentOn", {
        Text = "启用静默瞄准", Default = cfg.silent,
        Tooltip = "只改写弹道方向；不改 sp、不改原点、不碰相机",
        Callback = function(v) cfg.silent = v end
    })
    A.fov = gA:AddSlider("fovRadius", {
        Text = "FOV 半径", Default = cfg.fov, Min = 50, Max = 900, Rounding = 0, Suffix = " px",
        Tooltip = "只有落在这个像素圈内的僵尸才会被锁定；圈会跟着鼠标画出来",
        Callback = function(v) cfg.fov = v end
    })
    A.showFov = gA:AddToggle("showFov", {
        Text = "显示 FOV 圈", Default = cfg.showFov,
        Tooltip = "在准星周围画一个圆，直观看到锁定范围",
        Callback = function(v) cfg.showFov = v end
    })
    A.part = gA:AddDropdown("aimPart", {
        Text = "瞄准部位", Values = { "head", "neck", "chest" }, Default = cfg.part,
        Tooltip = "head=头部(爆头)；neck=颈部更稳；chest=躯干最容易命中",
        Callback = function(v) cfg.part = v end
    })
    A.dist = gA:AddSlider("maxDist", {
        Text = "最大距离", Default = cfg.maxDist, Min = 20, Max = 400, Rounding = 0, Suffix = " studs",
        Tooltip = "超过这个距离的僵尸不锁定",
        Callback = function(v) cfg.maxDist = v end
    })
    A.los = gA:AddToggle("losCheck", {
        Text = "视线检测", Default = cfg.los,
        Tooltip = "从枪口到目标有遮挡就跳过（防止打墙）",
        Callback = function(v) cfg.los = v end
    })
    A.predict = gA:AddToggle("predict", {
        Text = "移动预判", Default = cfg.predict,
        Tooltip = "按目标速度提前量瞄准，打移动中的僵尸更准",
        Callback = function(v) cfg.predict = v end
    })
    A.lead = gA:AddSlider("leadTime", {
        Text = "预判提前量", Default = cfg.lead, Min = 0, Max = 0.3, Rounding = 3, Suffix = " s",
        Tooltip = "越大越往前打；配合高延迟可调大",
        Callback = function(v) cfg.lead = v end
    })
    A.pause = gA:AddToggle("pauseWatched", {
        Text = "被观察时暂停", Default = cfg.pauseWatched,
        Tooltip = "检测到 Watched=true（抽样录像）时停止改写",
        Callback = function(v) cfg.pauseWatched = v end
    })
    A.fovColorToggle = gA:AddToggle("fovColorOn", {
        Text = "FOV 圈颜色", Default = true,
        Tooltip = "点击右侧色块调整 FOV 圈颜色",
        Callback = function() end
    })
    A.fovColorToggle:AddColorPicker("fovColor", {
        Default = cfg.fovColor, Title = "FOV 圈颜色",
        Callback = function(c) cfg.fovColor = c end
    })

    local gE = Tabs.Esp:AddLeftGroupbox("透视", "box")
    A.esp = gE:AddToggle("espOn", {
        Text = "启用透视", Default = cfg.esp,
        Tooltip = "只画活僵尸（读游戏注册表，尸体自动排除）",
        Callback = function(v) cfg.esp = v end
    })
    A.style = gE:AddDropdown("espStyle", {
        Text = "方框样式", Values = { "corner", "box" }, Default = cfg.style,
        Tooltip = "corner=四角框（更简洁），box=完整方框",
        Callback = function(v) cfg.style = v end
    })
    A.kind = gE:AddToggle("espKind", {
        Text = "显示类型", Default = cfg.espKind,
        Tooltip = "walker / runner / brute 等",
        Callback = function(v) cfg.espKind = v end
    })
    A.name = gE:AddToggle("espName", {
        Text = "显示编号", Default = cfg.espName,
        Tooltip = "僵尸在服务器上的 id",
        Callback = function(v) cfg.espName = v end
    })
    A.espDist = gE:AddToggle("espDist", {
        Text = "显示距离", Default = cfg.espDist,
        Tooltip = "与你的距离",
        Callback = function(v) cfg.espDist = v end
    })
    A.tracer = gE:AddToggle("tracer", {
        Text = "显示连线", Default = cfg.tracer,
        Tooltip = "从屏幕底部中心到目标的线",
        Callback = function(v) cfg.tracer = v end
    })
    A.espMax = gE:AddSlider("espMaxDist", {
        Text = "最大绘制距离", Default = cfg.espMaxDist, Min = 30, Max = 600, Rounding = 0, Suffix = " studs",
        Tooltip = "超过就不画",
        Callback = function(v) cfg.espMaxDist = v end
    })
    A.thick = gE:AddSlider("espThickness", {
        Text = "线宽", Default = cfg.thickness, Min = 1, Max = 4, Rounding = 0,
        Tooltip = "方框/四角框的线条粗细",
        Callback = function(v)
            cfg.thickness = v
            for _, s in ipairs(pool) do
                s.square.Thickness = v
                for j = 1, 8 do s.lines[j].Thickness = v end
            end
        end
    })
    A.textSize = gE:AddSlider("espTextSize", {
        Text = "文字大小", Default = cfg.textSize, Min = 10, Max = 22, Rounding = 0,
        Tooltip = "名字/距离文字的字号",
        Callback = function(v) cfg.textSize = v end
    })
    A.espColorToggle = gE:AddToggle("espColorOn", {
        Text = "ESP 颜色", Default = true,
        Tooltip = "点击右侧色块调整方框/文字颜色",
        Callback = function() end
    })
    A.espColorToggle:AddColorPicker("espColorPick", {
        Default = cfg.espColor, Title = "ESP 颜色",
        Callback = function(c) cfg.espColor = c end
    })

    local gS = Tabs.Status:AddLeftGroupbox("运行状态", "activity")
    A.lblTrack = gS:AddLabel("追踪: -")
    A.lblTarget = gS:AddLabel("目标: -")
    A.lblWatched = gS:AddLabel("Watched: -")
    A.lblMode = gS:AddLabel("部位: head")

    task.spawn(function()
        while true do
            task.wait(0.4)
            pcall(function()
                A.lblTrack:SetText("追踪: " .. tostring(#listAlive()) .. " 只活僵尸")
                A.lblTarget:SetText("目标: " .. lastTargetName)
                A.lblWatched:SetText("Watched: " .. tostring(lp:GetAttribute("Watched")))
                A.lblMode:SetText(string.format("部位: %s  FOV: %dpx  距离: %d", cfg.part, cfg.fov, cfg.maxDist))
            end)
        end
    end)
end

print(PREFIX .. " v" .. VERSION .. " loaded (RightShift)")
