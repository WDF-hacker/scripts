--[[
    HUSH AIM UI v1  (Obsidian)
    - 静默瞄准：读游戏僵尸注册表 -> 只打 FOV 圈内的活僵尸 -> 改 d/ay 打指定部位，**不改 sp**
    - FOV 圈：跟随鼠标绘制，只有圈内目标才会被锁
    - 透视：方框 / 四角框 两种样式，名字 / 类型 / 距离 / 连线 可单独开关
    快捷键：RightShift 开关面板
]]
local PREFIX = "[HUSH-UI]"
local VERSION = 19
_G.HUSH_UI_VERSION = 19

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local ZT = nil
pcall(function() ZT = require(RS.Hush.Shared.ZombieTypes) end)

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

--============ 单实例守卫：清掉上一个实例 ============
if _G.__HUSH_CLEANUPS then
    for _, f in ipairs(_G.__HUSH_CLEANUPS) do pcall(f) end
end
_G.__HUSH_CLEANUPS = {}
do
    local roots = {}
    if gethui then table.insert(roots, gethui()) end
    table.insert(roots, game:GetService("CoreGui"))
    local pg = lp:FindFirstChild("PlayerGui")
    if pg then table.insert(roots, pg) end
    for _, root in ipairs(roots) do
        if root then
            for _, g in ipairs(root:GetDescendants()) do
                if g:IsA("ScreenGui") and (g.Name:find("Obsidian") or g.Name == "HushStatus") then
                    pcall(function() g:Destroy() end)
                end
            end
        end
    end
end

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

    -- 隐蔽设置
    chance = 85,
    maxAngle = 20,
    jitter = 0.5,
    rateLimit = 0,
    switchPenalty = 0.25,
    maxPerRaid = 60,
    debug = false,
    streamproof = true,
    warnWatched = true,
    bossBias = 0,
    bossAim = true,
    bossAutoCal = true,
    bossFallbackTorso = false,

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

-- Boss 命中箱自校准数据: id -> { head = {relY...}, torso = {...}, h, t }
local BOSS_HEAD_Y = {
    boss_conductor = 6.35,
    boss_colonel = 6.3,
    boss_foreman = 6.5,
    boss_witness = 6.2,
    boss_surgeon = 7.5,
    boss_hale = 6.85,
    boss_mayor = 6.3,
    boss_chief = 6.5,
    boss_major = 6.3,
}
_G.HUSH_BOSS_HEAD_Y = BOSS_HEAD_Y

-- 这些 boss 的爆头判定就是视觉头部模型（不套 headY 表）
local BOSS_HEAD_MODEL = {
    boss_surgeon = true,
    boss_hale = true,
}
_G.HUSH_BOSS_HEAD_MODEL = BOSS_HEAD_MODEL

local bossCalib = {}
local aimTargetId, aimTargetAt, aimTargetRootY = nil, 0, 0

--============ 配置持久化 ============
local HttpService = game:GetService("HttpService")
local CFG_FILE = "hush_ui_config.json"

local function cfgToTable()
    local t = {}
    for k, v in pairs(cfg) do
        if typeof(v) == "Color3" then
            t[k] = { math.floor(v.R * 255 + 0.5), math.floor(v.G * 255 + 0.5), math.floor(v.B * 255 + 0.5) }
        elseif type(v) == "boolean" or type(v) == "number" or type(v) == "string" then
            t[k] = v
        end
    end
    return t
end

local function applyTable(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        local cur = cfg[k]
        if cur ~= nil then
            if typeof(cur) == "Color3" then
                if type(v) == "table" and #v == 3 then
                    cfg[k] = Color3.fromRGB(v[1], v[2], v[3])
                end
            elseif type(v) == type(cur) then
                cfg[k] = v
            end
        end
    end
end

local function saveCfg()
    pcall(function()
        writefile(CFG_FILE, HttpService:JSONEncode(cfgToTable()))
    end)
end

local function loadCfg()
    if not (isfile and isfile(CFG_FILE)) then return false end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CFG_FILE)) end)
    if ok then applyTable(data) end
    return ok
end

loadCfg()

--============ 射击日志 ============
local LOG = "hush_shots.log"
if not isfile(LOG) then writefile(LOG, "") end
local function logLine(s)
    pcall(function() appendfile(LOG, s .. "\n") end)
end
logLine(string.format("# SESSION %s user=%s uid=%d job=%s place=%s watched=%s cfg(chance=%d,maxAngle=%.1f,jitter=%.2f,rate=%d,cap=%d,fov=%d)",
    os.date("!%Y-%m-%dT%H:%M:%S"), lp.Name, lp.UserId, game.JobId,
    tostring(lp:GetAttribute("Place")), tostring(lp:GetAttribute("Watched")),
    cfg.chance, cfg.maxAngle, cfg.jitter, cfg.rateLimit, cfg.maxPerRaid, cfg.fov))

pcall(function()
    local hn = RS:WaitForChild("HushNet", 10)
    local r = hn and hn:FindFirstChild("combat.hit")
    if r then
        hitConn = r.OnClientEvent:Connect(function(d)
            pcall(function()
                if type(d) ~= "table" then return end
                local posTxt = ""
                if typeof(d.pos) == "Vector3" then
                    posTxt = string.format(" pos=%.1f,%.1f,%.1f", d.pos.X, d.pos.Y, d.pos.Z)
                end
                logLine(string.format("HIT %s part=%s dmg=%s kind=%s watched=%s%s",
                    os.date("!%H:%M:%S"), tostring(d.part), tostring(d.dmg),
                    tostring(d.kind), tostring(lp:GetAttribute("Watched")), posTxt))
                -- Boss 命中箱采样（只采样最近 1.5s 内锁定的目标）
                if cfg.bossAutoCal and aimTargetId ~= nil and (os.clock() - aimTargetAt) < 1.5 and typeof(d.pos) == "Vector3" then
                    local c = bossCalib[aimTargetId] or { head = {}, torso = {}, h = 0, t = 0 }
                    local rel = d.pos.Y - (aimTargetRootY or 0)
                    if tostring(d.part) == "head" then
                        table.insert(c.head, rel); c.h = c.h + 1
                        if #c.head > 40 then table.remove(c.head, 1) end
                    elseif tostring(d.part) == "torso" then
                        table.insert(c.torso, rel); c.t = c.t + 1
                        if #c.torso > 40 then table.remove(c.torso, 1) end
                    end
                    bossCalib[aimTargetId] = c
                end
            end)
        end)
    end
end)

--============ Watched 警告 ============
local warnGui, warnFrame
pcall(function()
    warnGui = Instance.new("ScreenGui")
    warnGui.Name = "HushStatus"
    warnGui.ResetOnSpawn = false
    warnGui.IgnoreGuiInset = true
    warnGui.DisplayOrder = 999
    warnGui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

    warnFrame = Instance.new("Frame")
    warnFrame.Size = UDim2.new(0, 400, 0, 54)
    warnFrame.Position = UDim2.new(0, 16, 0, 124)
    warnFrame.BackgroundColor3 = Color3.fromRGB(165, 25, 25)
    warnFrame.BackgroundTransparency = 0.1
    warnFrame.BorderSizePixel = 0
    warnFrame.Visible = false
    warnFrame.Parent = warnGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = warnFrame

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -16, 1, 0)
    label.Position = UDim2.new(0, 8, 0, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 15
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = "⚠ WATCHED — 本局正在被录像，建议撤离换一局"
    label.Parent = warnFrame
end)

local hitConn = nil
local warnOn = false
local function setWarn(on)
    warnOn = on and (cfg.warnWatched ~= false)
    if warnFrame then
        warnFrame.Visible = warnOn
    end
end

pcall(function()
    setWarn(lp:GetAttribute("Watched") == true)
    lp:GetAttributeChangedSignal("Watched"):Connect(function()
        setWarn(lp:GetAttribute("Watched") == true)
    end)
end)

task.spawn(function()
    while true do
        task.wait(0.55)
        if warnOn and warnFrame and warnFrame.Visible then
            warnFrame.BackgroundTransparency = (warnFrame.BackgroundTransparency > 0.3) and 0.06 or 0.35
        end
    end
end)

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
                local isBoss = string.find(string.lower(tostring(rec.kind)), "boss") ~= nil
                local headPos = root.Position + Vector3.new(0, 1.55 * scale, 0)
                local hp = nil
                local parts = type(rig) == "table" and rig.parts
                -- 只有 boss 才用游戏给的 parts[rec.head]（boss_conductor 指向 LowerTorso）
                -- 普通僵尸的 parts[rec.head] 指向 UpperTorso，会打到胸口，必须用视觉头部
                if isBoss and cfg.bossAim ~= false and type(parts) == "table" and type(rec.head) == "number" then
                    local cand = parts[rec.head]
                    if typeof(cand) == "Instance" and cand:IsA("BasePart") then hp = cand end
                end
                if not hp then
                    local mh = model:FindFirstChild("Head")
                    if mh and mh:IsA("BasePart") and math.abs(mh.Position.Y - root.Position.Y) < 8 then hp = mh end
                end
                if not hp then
                    local face = model:FindFirstChild("FaceCenterAttachment", true)
                    if face then headPos = face.WorldPosition end
                else
                    headPos = hp.Position
                end
                local defHeadY = nil
                if ZT and ZT.get then
                    local okD, d = pcall(ZT.get, rec.kind)
                    if okD and type(d) == "table" then defHeadY = tonumber(d.headY) end
                end
                if not isBoss and defHeadY then
                    headPos = Vector3.new(headPos.X, defHeadY, headPos.Z)
                end
                if isBoss then
                    local cal = cfg.bossAutoCal and bossCalib[rec.id]
                    local used = false
                    if cal and (cal.h + cal.t) >= 6 then
                        local src = cal.head
                        if cfg.bossFallbackTorso and cal.t > cal.h and #cal.torso > 0 then
                            src = cal.torso
                        end
                        if #src > 0 then
                            local s = {}
                            for i = 1, #src do s[i] = src[i] end
                            table.sort(s)
                            local med = s[math.floor((#s + 1) / 2)]
                            headPos = Vector3.new(headPos.X, root.Position.Y + med, headPos.Z)
                            used = true
                        end
                    end
                    if not used and BOSS_HEAD_MODEL[string.lower(tostring(rec.kind))] then
                        local mh = model:FindFirstChild("Head", true)
                        if mh and mh:IsA("BasePart") then
                            headPos = mh.Position + Vector3.new(0, cfg.bossBias or 0, 0)
                            used = true
                        end
                    end
                    if not used then
                        local ky = BOSS_HEAD_Y[string.lower(tostring(rec.kind))]
                        if ky and cfg.bossAim ~= false then
                            headPos = Vector3.new(headPos.X, ky + (cfg.bossBias or 0), headPos.Z)
                            used = true
                        end
                    end
                    if not used and defHeadY then
                        headPos = Vector3.new(headPos.X, defHeadY + (cfg.bossBias or 0), headPos.Z)
                        used = true
                    end
                    if not used and cfg.bossBias and cfg.bossBias ~= 0 then
                        headPos = headPos + Vector3.new(0, cfg.bossBias, 0)
                    end
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
                    pos = root.Position,
                    isBoss = isBoss,
                    center = root.Position + Vector3.new(0, 1.15 * scale, 0),
                    scale = scale
                }
            end
        end
    end
    return out
end
_G.HUSH_UI = { cfg = cfg, listAlive = listAlive, calib = bossCalib }

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
                local eff = dpx
                if currentTargetId ~= nil and z.id == currentTargetId then
                    eff = dpx * (1 - (cfg.switchPenalty or 0))
                end
                if dpx <= cfg.fov and eff < bestD then
                    if (not cfg.los) or los(o, aimPointOf(z)) then
                        best, bestD = { z = z, px = dpx, dist = dist }, dpx
                    end
                end
            end
        end
    end
    if best then currentTargetId = best.z.id end
    return best
end

--============ FOV 圈 ============
local function protect(d)
    pcall(function() d.Streamproof = true end)
end

local fovCircle = Drawing.new("Circle")
protect(fovCircle)
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
    protect(s.text); protect(s.square); protect(s.tracer)
    for j = 1, 8 do protect(s.lines[j]) end
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
local currentTargetId = nil
local raidKey = ""
local corrections = 0
local restoreFire = nil
local renderConn = nil

local Net
do
    local hush = RS:FindFirstChild("Hush")
    local mod = hush and hush:FindFirstChild("Shared") and hush.Shared:FindFirstChild("Net")
    if mod then Net = require(mod) end
end

if Net then
    if _G.__HUSH_ORIG_FIRE then
        pcall(function() Net.fire = _G.__HUSH_ORIG_FIRE end)
    end
    local oldFire = Net.fire
    _G.__HUSH_ORIG_FIRE = oldFire
    restoreFire = function() Net.fire = oldFire end
    Net.fire = function(name, payload)
        if cfg.silent and name == "combat.fire" and type(payload) == "table" and payload.o and payload.d then
            pcall(function()
                if cfg.pauseWatched and lp:GetAttribute("Watched") == true then logLine("SKIP watched"); return end
                local pick = pickTarget(payload.o)
                if not pick then logLine("SKIP no_target"); return end
                local z = pick.z
                local ap = aimPointOf(z)
                if cfg.predict then
                    local vel = z.root.AssemblyLinearVelocity
                    ap = ap + vel * cfg.lead
                end

                -- 隐蔽判定开始
                local rate = cfg.rateLimit or 0
                if rate > 0 then
                    shotTimes = shotTimes or {}
                    local nowT = os.clock()
                    local cnt = 0
                    for i = #shotTimes, 1, -1 do
                        if nowT - shotTimes[i] > 1 then table.remove(shotTimes, i) else cnt = cnt + 1 end
                    end
                    if cnt >= rate then logLine("SKIP rate"); return end
                    table.insert(shotTimes, nowT)
                end
                local rk = tostring(lp:GetAttribute("Place")) .. "|" .. game.JobId
                if rk ~= raidKey then
                    raidKey = rk
                    corrections = 0
                end
                if cfg.maxPerRaid and cfg.maxPerRaid > 0 and corrections >= cfg.maxPerRaid then
                    logLine("SKIP cap")
                    return
                end
                local nd = (ap - payload.o).Unit
                local ang = math.deg(math.acos(math.clamp(nd:Dot(payload.d), -1, 1)))
                if ang > (cfg.maxAngle or 90) then
                    logLine(string.format("SKIP angle=%.1f target=%s#%s", ang, tostring(z.kind), tostring(z.id)))
                    return
                end
                if (cfg.chance or 100) < 100 and (math.random() * 100 > cfg.chance) then
                    logLine(string.format("SKIP chance target=%s#%s ang=%.1f", tostring(z.kind), tostring(z.id), ang))
                    return
                end
                local jit = cfg.jitter or 0
                if jit > 0 then
                    local rx = math.rad((math.random() - 0.5) * 2 * jit)
                    local ry = math.rad((math.random() - 0.5) * 2 * jit)
                    local cf = CFrame.new(Vector3.zero, nd)
                    nd = (cf * CFrame.Angles(rx, ry, 0)).LookVector
                end
                -- 隐蔽判定结束

                corrections = (corrections or 0) + 1
                aimTargetId = z.id
                aimTargetAt = os.clock()
                aimTargetRootY = z.root.Position.Y
                payload.d = nd
                payload.ay = -math.atan2(nd.X, -nd.Z)
                logLine(string.format("FIRE %s#%s px=%.0f dist=%.0f ang=%.1f sp=%.2f watched=%s n=%d",
                    tostring(z.kind), tostring(z.id), pick.px, pick.dist, ang,
                    tonumber(payload.sp) or -1, tostring(lp:GetAttribute("Watched")), corrections))
            end)
        end
        return oldFire(name, payload)
    end
end

--============ 渲染循环 ============
local lastTargetName = "-"

renderConn = RunService.RenderStepped:Connect(function()
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
                local sp, depth = project(z.center or z.head)
                if sp and used < POOL then
                    used = used + 1
                    local s = pool[used]
                    -- 槽位换目标时重置平滑，避免把上一个目标的坐标带过来
                    if s.model ~= z.model then
                        s.model = z.model
                        s.lx, s.ly = nil, nil
                    end
                    local tx, ty = sp.X, sp.Y
                    if s.lx and math.abs(tx - s.lx) + math.abs(ty - s.ly) < 260 then
                        tx = s.lx + (tx - s.lx) * 0.45
                        ty = s.ly + (ty - s.ly) * 0.45
                    end
                    s.lx, s.ly = tx, ty
                    local h = math.clamp(1500 * (z.scale or 1) / math.max(depth, 1), 24, 220)
                    local w = h * 0.6
                    local x, y = tx - w / 2, ty - h / 2
                    local isAimTarget = aimTargetId ~= nil and z.id == aimTargetId and (os.clock() - aimTargetAt) < 1.2
                    local baseColor = z.isBoss and Color3.fromRGB(255, 165, 60) or cfg.espColor
                    local c = isAimTarget and Color3.fromRGB(255, 55, 55) or baseColor
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
                    if cfg.espKind then parts[#parts + 1] = (z.isBoss and "BOSS " or "") .. z.kind end
                    if cfg.espName then parts[#parts + 1] = "#" .. tostring(z.id) end
                    if cfg.espDist then parts[#parts + 1] = string.format("%.0fm", dist) end
                    s.text.Text = table.concat(parts, " ")
                    s.text.Position = Vector2.new(tx, y - 16)
                    s.text.Size = cfg.textSize
                    s.text.Color = c
                    s.text.Visible = true
                    if cfg.tracer then
                        s.tracer.From = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
                        s.tracer.To = Vector2.new(tx, ty + h / 2)
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

--============ 卸载 / 紧急停止 ============
local function cleanup()
    pcall(function() if renderConn then renderConn:Disconnect() end end)
    pcall(function() if restoreFire then restoreFire() end end)
    pcall(function() fovCircle:Remove() end)
    for _, s in ipairs(pool) do
        pcall(function() s.text:Remove() end)
        pcall(function() s.square:Remove() end)
        pcall(function() s.tracer:Remove() end)
        for j = 1, 8 do pcall(function() s.lines[j]:Remove() end) end
    end
    pool = {}
    pcall(function()
        if _G.HUSH_UI and _G.HUSH_UI.uiGui then _G.HUSH_UI.uiGui:Destroy() end
    end)
    pcall(function() if warnGui then warnGui:Destroy() end end)
    pcall(function() if hitConn then hitConn:Disconnect() end end)
end
_G.HUSH_UI_CLEANUP = cleanup
table.insert(_G.__HUSH_CLEANUPS, cleanup)

local function fullPurge()
    pcall(cleanup)
    pcall(function() if Drawing and Drawing.clear then Drawing.clear() end end)
    pcall(function() if cleardrawcache then cleardrawcache() end end)
    pcall(function()
        if Net and _G.__HUSH_ORIG_FIRE then Net.fire = _G.__HUSH_ORIG_FIRE end
    end)
    _G.__HUSH_ORIG_FIRE = nil
    for _, k in ipairs({ "HUSH_UI", "HUSH_UI_CFG", "HUSH_UI_CLEANUP", "HUSH_UI_VERSION", "HUSH_Z", "HUSH_ESP", "HUSH_SILENT_TEST", "HUSH_CURSOR" }) do
        _G[k] = nil
    end
end
_G.HUSH_UI_PURGE = fullPurge

pcall(function()
    UIS.InputBegan:Connect(function(input, gp)
        if gp then return end
        if input.KeyCode == Enum.KeyCode.End then
            cleanup()
        end
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
    do
        local roots = {}
        if gethui then table.insert(roots, gethui()) end
        table.insert(roots, game:GetService("CoreGui"))
        table.insert(roots, lp:FindFirstChild("PlayerGui"))
        for _, root in ipairs(roots) do
            if root then
                for _, g in ipairs(root:GetDescendants()) do
                    if g:IsA("ScreenGui") and g.Name:find("Obsidian") then
                        _G.HUSH_UI.uiGui = g
                    end
                end
            end
        end
    end

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

    local gK = Tabs.Aim:AddLeftGroupbox("隐蔽设置", "shield")
    A.chance = gK:AddSlider("chancePct", {
        Text = "修正概率", Default = cfg.chance, Min = 0, Max = 100, Rounding = 0, Suffix = " %",
        Tooltip = "只按这个概率修正弹道。65% 会把爆头率压回接近真人水平，100% 就是每发都修",
        Callback = function(v) cfg.chance = v end
    })
    A.maxAngle = gK:AddSlider("angleCap", {
        Text = "角度上限", Default = cfg.maxAngle, Min = 1, Max = 45, Rounding = 1, Suffix = "°",
        Tooltip = "原弹道与目标夹角超过这个值就放弃修正。3° 以内基本看不出来",
        Callback = function(v) cfg.maxAngle = v end
    })
    A.jitter = gK:AddSlider("jitterDeg", {
        Text = "瞄准抖动", Default = cfg.jitter, Min = 0, Max = 2, Rounding = 2, Suffix = "°",
        Tooltip = "修正后加一点随机偏移，避免每发都像素级完美",
        Callback = function(v) cfg.jitter = v end
    })
    A.rate = gK:AddSlider("rateCap", {
        Text = "每秒最多修正", Default = cfg.rateLimit, Min = 0, Max = 10, Rounding = 0, Suffix = " 次",
        Tooltip = "0 = 不限制；限制后更像真人的开枪节奏",
        Callback = function(v) cfg.rateLimit = v end
    })
    gK:AddButton({
        Text = "套用低姿态预设（主号推荐）",
        Tooltip = "一键设置：65% 概率 / ≤3° / 抖动0.2° / 每秒2次 / FOV140 / 80studs / 被观察时暂停",
        Func = function()
            cfg.chance = 65
            cfg.maxAngle = 3
            cfg.jitter = 0.2
            cfg.rateLimit = 2
            cfg.fov = 140
            cfg.maxDist = 80
            cfg.pauseWatched = true
            saveCfg()
            if Library and Library.Notify then Library:Notify("已套用低姿态预设，配置已保存", 5) end
        end
    })
    A.bossAim = gA:AddToggle("bossAim", {
        Text = "Boss 专用瞄准点", Default = cfg.bossAim,
        Tooltip = "开启后，名字含 boss 的目标瞄准游戏给定的 parts[head]（LowerTorso）；普通僵尸始终瞄视觉头部",
        Callback = function(v) cfg.bossAim = v end
    })
    A.bossAutoCal = gA:AddToggle("bossAutoCal", {
        Text = "Boss 命中箱自校准", Default = cfg.bossAutoCal,
        Tooltip = "用 combat.hit 的落点自动学习头部判定区高度，至少 6 次命中后生效；比手动偏移更准",
        Callback = function(v) cfg.bossAutoCal = v end
    })
    A.bossFallback = gA:AddToggle("bossFallbackTorso", {
        Text = "小箱回退躯干", Default = cfg.bossFallbackTorso,
        Tooltip = "如果一个 boss 的躯干命中数多于头部，就自动改打躯干（保证伤害下限）",
        Callback = function(v) cfg.bossFallbackTorso = v end
    })
    A.bossBias = gA:AddSlider("bossBias", {
        Text = "Boss 瞄准偏移", Default = cfg.bossBias, Min = -4, Max = 4, Rounding = 1, Suffix = " studs",
        Tooltip = "只对名字含 boss 的目标生效。游戏给 boss_conductor 定的 head 在 LowerTorso(y≈5.7)，比视觉头部低约 3.6 studs；打不中时用这个上下微调",
        Callback = function(v) cfg.bossBias = v end
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
    A.warnToggle = gS:AddToggle("warnWatched", {
        Text = "Watched 警告弹窗", Default = cfg.warnWatched,
        Tooltip = "检测到本局被抽样录像时，在左上角弹出红色警告",
        Callback = function(v)
            cfg.warnWatched = v
            setWarn(lp:GetAttribute("Watched") == true)
        end
    })

    local gC = Tabs.Status:AddLeftGroupbox("配置", "save")
    gC:AddButton({
        Text = "立即保存配置", Tooltip = "写入 hush_ui_config.json",
        Func = function() saveCfg(); if Library and Library.Notify then Library:Notify("配置已保存", 3) end end
    })
    gC:AddButton({
        Text = "重载配置", Tooltip = "从文件读取（部分控件需重开面板才刷新显示）",
        Func = function() loadCfg(); if Library and Library.Notify then Library:Notify("已重载配置", 3) end end
    })
    gC:AddButton({
        Text = "完全卸载（清绘制 + hook）",
        Tooltip = "清空所有 Drawing、销毁面板、还原 Net.fire、清全局；v7 之前的旧实例仍需重进才能彻底清除",
        Func = function()
            fullPurge()
        end
    })

    task.spawn(function()
        local saveAcc = 0
        while true do
            task.wait(0.4)
            saveAcc = saveAcc + 0.4
            if saveAcc >= 5 then
                saveAcc = 0
                saveCfg()
            end
            pcall(function()
                A.lblTrack:SetText("追踪: " .. tostring(#listAlive()) .. " 只活僵尸")
                A.lblTarget:SetText("目标: " .. lastTargetName)
                A.lblWatched:SetText("Watched: " .. tostring(lp:GetAttribute("Watched")))
                A.lblMode:SetText(string.format("部位: %s  FOV: %dpx  距离: %d", cfg.part, cfg.fov, cfg.maxDist))
            end)
        end
    end)
end

if _G.HUSH_UI_CFG and _G.HUSH_UI_CFG.debug then print(PREFIX .. " loaded") end
