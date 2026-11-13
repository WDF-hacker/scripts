--[[
    HUSH AIM UI v1  (Obsidian)
    - 静默瞄准：读游戏僵尸注册表 -> 只打 FOV 圈内的活僵尸 -> 改 d/ay 打指定部位，**不改 sp**
    - FOV 圈：跟随鼠标绘制，只有圈内目标才会被锁
    - 透视：方框 / 四角框 两种样式，名字 / 类型 / 距离 / 连线 可单独开关
    快捷键：RightShift 开关面板
]]
local PREFIX = "[HUSH-UI]"
local VERSION = 29
_G.HUSH_UI_VERSION = 29

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
    espColor = Color3.fromRGB(120, 255, 140),

    -- MSESP（mstudio45's ESP Library）渲染后端
    espLib = true,
    espPreset = "高亮 + 方框",
    skeleton = false
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
    boss_chief = true,
}
_G.HUSH_BOSS_HEAD_MODEL = BOSS_HEAD_MODEL

local bossCalib = {}
local headCache = setmetatable({}, { __mode = "k" })
local faceCache = setmetatable({}, { __mode = "k" })
local kindCache = {}
local bossKindCache = {}     -- kind 字符串 -> 是否 boss，避免每帧 tostring+lower+find
local kindLowerCache = {}    -- kind 字符串 -> 小写，供 BOSS_HEAD_Y / BOSS_HEAD_MODEL 查表
local aimTargetId, aimTargetAt, aimTargetRootY = nil, 0, 0
local currentTargetId = nil      -- 当前锁定目标 id，供 ESP 染红与切换惩罚共用

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
-- 数据源优先级：
--   1) HushClient.Controllers.ZombieRender 的注册表数组（真实来源，稳定）
--   2) 老的 upvalue 扫描（回落，形状变了就会失效）
-- 记录字段由游戏侧维护：.id .kind .dead .state .x .z .rig{model,root,scale,parts}
local ZR_NODES = { "PlayerScripts", "HushClient", "Controllers", "ZombieRender" }

local registry, registryAt = nil, 0
local regLost = false
local regMode = "none"        -- "module" | "scan" | "none"
local regFailAt, regBackoff = 0, 1
local REG_BACKOFF_MAX = 10
local REG_TTL = 30            -- 只用来周期性确认控制器还在，不做全量重扫

-- 回落扫描用的打分：字段小改也要能认出来
local function scoreReg(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for k, v in pairs(t) do
        if type(k) == "number" and type(v) == "table" then
            if v.rig ~= nil or (v.dead ~= nil and v.kind ~= nil) then n = n + 1 end
        end
    end
    return n
end

local function scanRegistry()
    local ev
    pcall(function() ev = RS.HushNet["zombie.event"] end)
    if not ev then return nil end
    local best, bestScore = nil, 0
    local okc, conns = pcall(getconnections, ev.OnClientEvent)
    if not okc or type(conns) ~= "table" then return nil end
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
    if best and bestScore > 0 then return best end
    return nil
end

local function resolveZR()
    local node = lp
    for i = 1, #ZR_NODES do
        if not node then return nil end
        node = node:FindFirstChild(ZR_NODES[i])
    end
    return node
end

-- 控制器闭包的第 1 个 upvalue 就是注册表数组本身。
-- 空数组也是合法状态（附近没僵尸），不能当成失配。
local function attachZR()
    local scr = resolveZR()
    if not scr then return false end
    local ok, mod = pcall(require, scr)
    if not ok or type(mod) ~= "table" or type(mod.targets) ~= "function" then return false end
    local ok2, uvs = pcall(function() return debug.getupvalues(mod.targets) end)
    if not ok2 or type(uvs) ~= "table" then return false end
    local arr = uvs[1]
    if type(arr) ~= "table" then return false end
    registry, registryAt = arr, os.clock()
    regMode = "module"
    regLost = false
    regBackoff = 1
    return true
end

local findRegistry
function findRegistry(force)
    local now = os.clock()

    if registry and not force then
        if now - registryAt > REG_TTL then
            registryAt = now
            if not resolveZR() then      -- 控制器没了才丢弃引用
                registry = nil
                regMode = "none"
            end
        end
        if registry then return registry end
    end

    if force then registry = nil end
    if not force and now < regFailAt then return nil end

    if attachZR() then return registry end

    local found = scanRegistry()
    if found then
        registry, registryAt = found, now
        regMode = "scan"
        regLost = false
        regBackoff = 1
        return registry
    end

    regLost = true
    regMode = "none"
    regFailAt = now + regBackoff
    regBackoff = math.min(regBackoff * 2, REG_BACKOFF_MAX)
    return nil
end

local function regCount()
    if type(registry) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(registry) do n = n + 1 end
    return n
end

_G.HUSH_REG_STATUS = function()
    return { lost = regLost, mode = regMode, count = regCount(), backoff = regBackoff, has = registry ~= nil }
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
                local kindStr = tostring(rec.kind)
                local kindLower = kindLowerCache[kindStr]
                if kindLower == nil then
                    kindLower = string.lower(kindStr)
                    kindLowerCache[kindStr] = kindLower
                end
                local isBoss = bossKindCache[kindStr]
                if isBoss == nil then
                    isBoss = string.find(kindLower, "boss") ~= nil
                    bossKindCache[kindStr] = isBoss
                end                local headPos = root.Position + Vector3.new(0, 1.55 * scale, 0)
                local hp = nil
                local parts = type(rig) == "table" and rig.parts
                -- 只有 boss 才用游戏给的 parts[rec.head]（boss_conductor 指向 LowerTorso）
                -- 普通僵尸的 parts[rec.head] 指向 UpperTorso，会打到胸口，必须用视觉头部
                if isBoss and cfg.bossAim ~= false and type(parts) == "table" and type(rec.head) == "number" then
                    local cand = parts[rec.head]
                    if typeof(cand) == "Instance" and cand:IsA("BasePart") then hp = cand end
                end
                if not hp then
                    local mh = headCache[model]
                    if mh == nil then
                        mh = model:FindFirstChild("Head", true) or false
                        headCache[model] = mh
                    end
                    if mh and mh ~= false and mh:IsA("BasePart") and math.abs(mh.Position.Y - root.Position.Y) < 8 then hp = mh end
                end
                if not hp then
                    local face = faceCache[model]
                    if face == nil then
                        face = model:FindFirstChild("FaceCenterAttachment", true) or false
                        faceCache[model] = face
                    end
                    if face and face ~= false then headPos = face.WorldPosition end
                else
                    headPos = hp.Position
                end
                local defHeadY = nil
                local kk = kindStr
                local cached = kindCache[kk]
                if cached == nil then
                    cached = false
                    if ZT and ZT.get then
                        local okD, d = pcall(ZT.get, kk)
                        if okD and type(d) == "table" then cached = tonumber(d.headY) or false end
                    end
                    kindCache[kk] = cached
                end
                if cached then defHeadY = cached end
                if not isBoss and not hp and defHeadY then
                    headPos = Vector3.new(headPos.X, defHeadY, headPos.Z)
                end
                if isBoss then
                    local used = false
                    if BOSS_HEAD_MODEL[kindLower] then
                        local mh = headCache[model]
                        if mh == nil then
                            mh = model:FindFirstChild("Head", true) or false
                            headCache[model] = mh
                        end
                        if mh and mh ~= false and mh:IsA("BasePart") then
                            headPos = mh.Position + Vector3.new(0, cfg.bossBias or 0, 0)
                            used = true
                        end
                    end
                    if not used and defHeadY then
                        local mh = model:FindFirstChild("Head", true)
                        if mh and mh:IsA("BasePart") and math.abs(mh.Position.Y - defHeadY) <= 1.5 then
                            headPos = mh.Position + Vector3.new(0, cfg.bossBias or 0, 0)
                            used = true
                        end
                    end
                    local cal = cfg.bossAutoCal and bossCalib[rec.id]
                    if not used and cal and (cal.h + cal.t) >= 6 then
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
                    if not used then
                        local ky = BOSS_HEAD_Y[kindLower]
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
                    kind = kindStr,
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
_G.HUSH_UI = { cfg = cfg, listAlive = listAlive, calib = bossCalib, targetId = function() return currentTargetId end }

local function aimPointOf(z)
    if cfg.part == "neck" then return z.neck end
    if cfg.part == "chest" then return z.chest end
    return z.head
end

--============ 公用 ============
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true

-- 过滤表只在角色变化时重建一次；目标模型不排除，
-- 改成「射线命中目标模型本身 = 通视」，避免每次 raycast 重建过滤器
local losChar = nil
local function los(from, to, targetModel)
    local char = lp.Character
    if char ~= losChar then
        losChar = char
        params.FilterDescendantsInstances = char and { char } or {}
    end
    local delta = to - from
    local hit = workspace:Raycast(from, delta, params)
    if not hit then return true end
    if targetModel and hit.Instance and hit.Instance:IsDescendantOf(targetModel) then return true end
    return hit.Distance >= delta.Magnitude - 0.5
end

local function mousePos()
    local p = UIS:GetMouseLocation()
    return Vector2.new(p.X, p.Y)
end

-- CurrentCamera 缓存：这是跨边界的属性读，每帧每目标读一次不划算
local camRef = workspace.CurrentCamera
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    camRef = workspace.CurrentCamera
end)

local function project(pos)
    local cam = camRef
    if not cam then return nil end
    local sp, on = cam:WorldToViewportPoint(pos)
    if not on or sp.Z <= 0 then return nil end
    return Vector2.new(sp.X, sp.Y), sp.Z
end

local function pickTarget(o, list, mp)
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not camRef or not hrp then return nil end
    mp = mp or mousePos()
    list = list or listAlive()

    local maxD2 = cfg.maxDist * cfg.maxDist
    local pen = 1 - (cfg.switchPenalty or 0)
    local hrpPos = hrp.Position
    local best, bestD = nil, math.huge

    for _, z in ipairs(list) do
        local dx, dy, dz = z.pos.X - hrpPos.X, z.pos.Y - hrpPos.Y, z.pos.Z - hrpPos.Z
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 <= maxD2 then
            local ap = aimPointOf(z)          -- 只算一次，别再调第二遍
            local sp = project(ap)
            if sp then
                local dpx = (sp - mp).Magnitude
                local eff = dpx
                if currentTargetId ~= nil and z.id == currentTargetId then
                    eff = dpx * pen
                end
                if dpx <= cfg.fov and eff < bestD then
                    if (not cfg.los) or los(o, ap, z.model) then
                        best = { z = z, px = dpx, dist = math.sqrt(d2) }
                        bestD = eff               -- 存 eff，与比较口径一致
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
local pool = nil

-- 旧版 Drawing ESP 的池子改成按需创建：MSESP 生效时一个 Drawing 都不建
local function ensurePool()
    if pool then return pool end
    pool = {}
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
    return pool
end

--============ MSESP 桥接 ============
-- 把僵尸 ESP 交给 mstudio45's ESP Library 渲染：库自带 RenderStepped 循环，
-- 我们只做低频成员对账，主循环不再产生任何绘制调用。
local MSESP_URL = "https://raw.githubusercontent.com/mstudio45/MSESP/refs/heads/main/source.luau"
local MSESP_CACHE = "hush_msesp_source.luau"

local ESPB = {
    lib = nil,
    tracked = {},      -- [model] = { esp, boss, type, z }
    byId = {},         -- [zombieId] = rec，供染红快速定位
    markedId = nil,
    lastSync = 0,
    interval = 0.2,
    failed = false,
}

function ESPB.load()
    if ESPB.lib then return true end
    if ESPB.failed then return false end
    if _G.mstudio45_ESP then
        ESPB.lib = _G.mstudio45_ESP
        return true
    end
    local src
    if isfile and isfile(MSESP_CACHE) then
        local ok, s = pcall(readfile, MSESP_CACHE)
        if ok and type(s) == "string" and #s > 20000 then src = s end
    end
    if not src then
        local ok, s = pcall(function() return game:HttpGet(MSESP_URL) end)
        if ok and type(s) == "string" and #s > 20000 then
            src = s
            pcall(writefile, MSESP_CACHE, s)
        end
    end
    if not src then ESPB.failed = true; return false end
    local fn = loadstring(src)
    if not fn then ESPB.failed = true; return false end
    local ok, res = pcall(fn)
    if not ok or type(res) ~= "table" then ESPB.failed = true; return false end
    ESPB.lib = res
    pcall(function()
        local g = res.GlobalConfig
        g.Billboards = true; g.Distance = true; g.Highlighters = true
        g.Tracers = true; g.Boxes2D = true; g.Boxes3D = true
        g.Rainbow = false; g.IgnoreCharacter = false
    end)
    return true
end

-- 显示风格预设：把「本体样式 + 方框组合」压成一个选择，避免多个控件互相打架
-- hideBody = 把 Highlight 的填充与描边都设为全透明，只留方框
local ESP_PRESETS = {
    ["高亮 + 方框"]  = { type = "Highlight",    box2d = true,  box3d = false, hideBody = false },
    ["仅高亮"]       = { type = "Highlight",    box2d = false, box3d = false, hideBody = false },
    ["仅方框"]       = { type = "Highlight",    box2d = true,  box3d = false, hideBody = true  },
    ["线框 + 方框"]  = { type = "SelectionBox", box2d = true,  box3d = false, hideBody = false },
    ["仅 3D 框"]     = { type = "Highlight",    box2d = false, box3d = true,  hideBody = true  },
}
local ESP_PRESET_NAMES = { "高亮 + 方框", "仅高亮", "仅方框", "线框 + 方框", "仅 3D 框" }

local function curPreset()
    return ESP_PRESETS[cfg.espPreset] or ESP_PRESETS["高亮 + 方框"]
end

local VALID_ESP_TYPE = {
    highlight = "Highlight",
    selectionbox = "SelectionBox",
    adornment = "Adornment",
    text = "Text",
    sphereadornment = "SphereAdornment",
    cylinderadornment = "CylinderAdornment",
}

local function normESPType(v)
    return VALID_ESP_TYPE[string.lower(tostring(v or "Highlight"))] or "Highlight"
end

local function espB_label(z)
    local parts = {}
    if z.isBoss then parts[#parts + 1] = "BOSS" end
    if cfg.espKind ~= false then parts[#parts + 1] = z.kind end
    if cfg.espName ~= false then parts[#parts + 1] = "#" .. tostring(z.id) end
    return #parts > 0 and table.concat(parts, " ") or tostring(z.kind)
end

local COL_TARGET = Color3.fromRGB(255, 55, 55)
local COL_BOSS = Color3.fromRGB(255, 165, 60)

local function espB_color(z)
    -- 被静默瞄准锁定 / 刚开过火的目标染红
    if z.id ~= nil then
        if z.id == currentTargetId then return COL_TARGET end
        if aimTargetId ~= nil and z.id == aimTargetId and (os.clock() - aimTargetAt) < 1.2 then
            return COL_TARGET
        end
    end
    return z.isBoss and COL_BOSS or cfg.espColor
end

local function espB_settings(z)
    local color = espB_color(z)
    local p = curPreset()
    local bodyT = p.hideBody and 1 or 0.6
    local edgeT = p.hideBody and 1 or 0
    return {
        Model = z.model,
        Name = espB_label(z),
        ESPType = normESPType(p.type),
        Color = color,
        MaxDistance = cfg.espMaxDist or 300,
        TextSize = cfg.textSize or 13,
        StudsOffset = Vector3.new(0, 0.6, 0),
        FillColor = color,
        OutlineColor = color,
        FillTransparency = bodyT,
        OutlineTransparency = edgeT,
        Transparency = p.hideBody and 1 or 0.35,
        Thickness = cfg.thickness or 1,
        Box2D = { Enabled = p.box2d, Color = color, Thickness = cfg.thickness or 1, Transparency = 0 },
        Box3D = { Enabled = p.box3d, Color = color, Thickness = cfg.thickness or 1, Transparency = 0 },
        Tracer = { Enabled = cfg.tracer == true, Color = color, Thickness = 1, Transparency = 0, From = "Bottom" },
        Skeleton = { Enabled = cfg.skeleton == true, Color = color, Thickness = 1, Transparency = 0 },
    }
end

-- 组件开关、颜色、名字、距离、字号都走 CurrentSettings 实时写；
-- 只有 ESPType 是库内只读，必须销毁重建。
-- 只改可以实时生效的字段。
-- 组件（Box2D/Box3D/Tracer/Skeleton）在库内只有创建时 Enabled=true 才会被实例化，
-- 事后写 Enabled 不会创建组件，所以开关类改动统一走「重建」。
local function espB_apply(rec, z)
    local color = espB_color(z)
    local th = cfg.thickness or 1
    local cs = rec.esp.CurrentSettings
    cs.Name = espB_label(z)
    cs.Color = color
    cs.FillColor = color
    cs.OutlineColor = color
    cs.MaxDistance = cfg.espMaxDist or 300
    cs.TextSize = cfg.textSize or 13
    if cs.Box2D then cs.Box2D.Color = color; cs.Box2D.Thickness = th end
    if cs.Box3D then cs.Box3D.Color = color; cs.Box3D.Thickness = th end
    if cs.Tracer then cs.Tracer.Color = color end
    if cs.Skeleton then cs.Skeleton.Color = color end
end

function ESPB.sync(alive)
    if not ESPB.lib then return end
    local now = os.clock()
    if (now - ESPB.lastSync) < ESPB.interval then return end
    ESPB.lastSync = now

    local wantType = normESPType(curPreset().type)
    local sig = cfg.espPreset
        .. "|" .. tostring(cfg.tracer == true)
        .. "|" .. tostring(cfg.skeleton == true)
        .. "|" .. tostring(cfg.thickness or 1)
    local seen = {}
    for i = 1, #alive do
        local z = alive[i]
        local m = z.model
        if m and m.Parent then
            seen[m] = true
            local rec = ESPB.tracked[m]

            -- 预设变了要重建：类型只读，且组件只在创建时按 Enabled 实例化
            if rec and rec.sig ~= sig then
                pcall(function() rec.esp:Destroy() end)
                ESPB.tracked[m] = nil
                rec = nil
            end

            if not rec then
                local ok, esp = pcall(function() return ESPB.lib:Add(espB_settings(z)) end)
                if ok and esp then
                    ESPB.tracked[m] = { esp = esp, boss = z.isBoss, type = wantType, sig = sig, z = z }
                    ESPB.lastErr = nil
                else
                    ESPB.lastErr = tostring(esp)
                end
            else
                rec.boss = z.isBoss
                rec.z = z
                local ok, err = pcall(espB_apply, rec, z)
                if not ok then ESPB.lastErr = tostring(err) end
            end
        end
    end

    for m, rec in pairs(ESPB.tracked) do
        if not seen[m] or not m.Parent then
            pcall(function() rec.esp:Destroy() end)
            ESPB.tracked[m] = nil
        end
    end

    -- id -> 记录，供染红快速定位
    ESPB.byId = {}
    for _, rec in pairs(ESPB.tracked) do
        if rec.z and rec.z.id ~= nil then ESPB.byId[rec.z.id] = rec end
    end
end

-- 目标变化时立刻只刷这两条的颜色，不等 sync 周期
function ESPB.markTarget(id)
    if id == ESPB.markedId then return end
    local prev = ESPB.markedId
    ESPB.markedId = id
    local function refresh(i)
        if i == nil then return end
        local rec = ESPB.byId and ESPB.byId[i]
        if rec and rec.z then pcall(espB_apply, rec, rec.z) end
    end
    refresh(prev)
    refresh(id)
end

function ESPB.clear()
    for m, rec in pairs(ESPB.tracked) do
        pcall(function() rec.esp:Destroy() end)
        ESPB.tracked[m] = nil
    end
    if ESPB.lib then pcall(function() ESPB.lib:Clear() end) end
end

function ESPB.destroy()
    ESPB.clear()
    if ESPB.lib then pcall(function() ESPB.lib:Destroy() end) end
    ESPB.lib = nil
    pcall(function() getgenv().mstudio45_ESP = nil end)
end

function ESPB.setColor(c)
    if not ESPB.lib then return end
    for _, rec in pairs(ESPB.tracked) do
        pcall(function()
            local cs = rec.esp.CurrentSettings
            if cs.Box2D then cs.Box2D.Color = c end
            if cs.Box3D then cs.Box3D.Color = c end
            if cs.Tracer then cs.Tracer.Color = c end
            if not rec.boss then cs.Color = c; cs.FillColor = c; cs.OutlineColor = c end
        end)
    end
end

local espLibActive = false
if cfg.espLib ~= false then
    espLibActive = ESPB.load()
end
_G.HUSH_ESP_BRIDGE = ESPB
_G.HUSH_ESP_ACTIVE = espLibActive


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
-- currentTargetId 已在 ESP 段之前声明
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
            local okAim, errAim = pcall(function()
                if cfg.pauseWatched and lp:GetAttribute("Watched") == true then logLine("SKIP watched"); return end
                local mpNow = mousePos()
                local pick = nil
                if preTarget and (os.clock() - preTargetAt) < 0.25 then
                    local spNow = project(aimPointOf(preTarget.z))
                    if spNow and (spNow - mpNow).Magnitude <= cfg.fov then
                        pick = preTarget
                    end
                end
                if not pick then
                    pick = pickTarget(payload.o, frameList, mpNow)
                end
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
            if not okAim then
                _G.HUSH_AIM_ERR = tostring(errAim)
                logLine("AIM_ERR " .. tostring(errAim))
            end
        end
        return oldFire(name, payload)
    end
end

--============ 渲染循环 ============
local lastTargetName = "-"
local frameList = {}
local preTarget, preTargetAt = nil, 0

renderConn = RunService.RenderStepped:Connect(function()
    -- 每帧只算一次僵尸列表，同时预锁定（这样开枪时直接复用，不再现算）
    local hrpNow = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if hrpNow then
        frameList = listAlive()
        local mpNow = mousePos()
        preTarget = pickTarget(hrpNow.Position + Vector3.new(0, 1.1, 0), frameList, mpNow)
        preTargetAt = os.clock()
        if espLibActive then ESPB.markTarget(currentTargetId) end
        lastTargetName = preTarget and (preTarget.z.kind .. " #" .. tostring(preTarget.z.id)) or "-"
    end

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
        if espLibActive then
            if next(ESPB.tracked) ~= nil then ESPB.clear() end
        elseif pool then
            for _, s in ipairs(pool) do hideSlot(s) end
        end
        return
    end

    -- MSESP 后端：库自己渲染，这里只做对账，不产生绘制调用
    if espLibActive then
        ESPB.sync(frameList)
        return
    end

    ensurePool()
    pcall(function()
        local cam = workspace.CurrentCamera
        local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
        if not cam or not hrp then return end
        local used = 0
        for _, z in ipairs(frameList) do
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
                    local isAimTarget = (preTarget ~= nil and z.id == preTarget.z.id)
                        or (aimTargetId ~= nil and z.id == aimTargetId and (os.clock() - aimTargetAt) < 1.2)
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
    end)
end)

--============ 卸载 / 紧急停止 ============
local function cleanup()
    pcall(function() if renderConn then renderConn:Disconnect() end end)
    pcall(function() if restoreFire then restoreFire() end end)
    pcall(function() fovCircle:Remove() end)
    pcall(function() ESPB.destroy() end)
    if pool then
        for _, s in ipairs(pool) do
            pcall(function() s.text:Remove() end)
            pcall(function() s.square:Remove() end)
            pcall(function() s.tracer:Remove() end)
            for j = 1, 8 do pcall(function() s.lines[j]:Remove() end) end
        end
    end
    pool = nil
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
    for _, k in ipairs({ "HUSH_UI", "HUSH_UI_CFG", "HUSH_UI_CLEANUP", "HUSH_UI_VERSION", "HUSH_Z", "HUSH_ESP", "HUSH_SILENT_TEST", "HUSH_CURSOR", "HUSH_ESP_BRIDGE", "HUSH_ESP_ACTIVE", "mstudio45_ESP" }) do
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
    A.preset = gE:AddDropdown("espPreset", {
        Text = "显示风格", Values = ESP_PRESET_NAMES, Default = cfg.espPreset,
        Tooltip = "高亮=全身透墙发光；方框=屏幕贴合包围盒。选带方框的组合即两者同时开。切换约 0.2 秒生效",
        Callback = function(v)
            cfg.espPreset = v
            -- 本体类型变了要重建，交给 sync 处理；这里立刻把开关类改动推下去
            for _, rec in pairs(ESPB.tracked) do
                if rec.z then pcall(espB_apply, rec, rec.z) end
            end
        end
    })
    A.skeleton = gE:AddToggle("espSkeleton", {
        Text = "骨骼线", Default = cfg.skeleton,
        Tooltip = "按 R15 关节连线，开销最大，僵尸多时建议关",
        Callback = function(v) cfg.skeleton = v end
    })
    A.espLibOn = gE:AddToggle("espLibOn", {
        Text = "使用 MSESP 渲染", Default = cfg.espLib,
        Tooltip = "关掉则退回内置 Drawing 绘制（会明显掉帧）。切换后需重载脚本才完全生效",
        Callback = function(v) cfg.espLib = v end
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
            if pool then
                for _, s in ipairs(pool) do
                    s.square.Thickness = v
                    for j = 1, 8 do s.lines[j].Thickness = v end
                end
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
        Callback = function(c)
            cfg.espColor = c
            ESPB.setColor(c)
        end
    })

    local gS = Tabs.Status:AddLeftGroupbox("运行状态", "activity")
    A.lblTrack = gS:AddLabel("追踪: -")
    A.lblTarget = gS:AddLabel("目标: -")
    A.lblWatched = gS:AddLabel("Watched: -")
    A.lblMode = gS:AddLabel("部位: head")
    A.lblReg = gS:AddLabel("注册表: -")
    gS:AddButton({
        Text = "重新扫描僵尸注册表",
        Tooltip = "注册表失配（追踪数为 0 但场上明明有僵尸）时手动重扫一次",
        Func = function()
            findRegistry(true)
            local st = _G.HUSH_REG_STATUS and _G.HUSH_REG_STATUS() or {}
            if Library and Library.Notify then
                Library:Notify(st.has and string.format("注册表已接入（%s / %d 条）",
                    tostring(st.mode), st.count or 0) or "仍未找到注册表，稍后再试", 4)
            end
        end
    })
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
                local st = _G.HUSH_REG_STATUS and _G.HUSH_REG_STATUS() or nil
                if st then
                    local modeTxt = st.mode == "module" and "控制器" or (st.mode == "scan" and "扫描(回落)" or "未接入")
                    A.lblReg:SetText(string.format("注册表: %s / %s / %d 条", modeTxt,
                        st.has and "正常" or "失联", st.count or 0))
                end
                A.lblTarget:SetText("目标: " .. lastTargetName)
                A.lblWatched:SetText("Watched: " .. tostring(lp:GetAttribute("Watched")))
                A.lblMode:SetText(string.format("部位: %s  FOV: %dpx  距离: %d", cfg.part, cfg.fov, cfg.maxDist))
            end)
        end
    end)
end

if _G.HUSH_UI_CFG and _G.HUSH_UI_CFG.debug then print(PREFIX .. " loaded") end
