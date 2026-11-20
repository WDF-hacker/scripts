--[[
    hx_scp_lynx.luau  —  SCP: Breach  ESP + Aimbot (Lynx / UNC)

    与 Matcha 版的关键差异：
      · Drawing 池 + RenderStepped 渲染（保留对象，按目标复用，不每帧 new）
      · 自瞄用 BindToRenderStep(Camera+1) 写相机 —— 排在游戏相机脚本之后执行，不会被覆盖
        （Matcha 版只能推鼠标，因为它的 lookAt 每帧被游戏抢回去，这是抽搐的根因）
      · UI 是自建 ScreenGui（gethui），可拖动，参数实时生效

    数据（2026-11-17 实测）：
      Character.Hitboxes 里有 Head/Chest/Stomach/...
      Character 直接子级：HumanoidRootPart / Humanoid / Health / Animate / Hitboxes
      头心到脚底 ≈ 4.57 studs；视口 1920x1017；FOV 59
      Player.Team 为 nil，阵营在 Player:GetAttribute("Team") / ("Role")
]]

if _G.HX_UNLOAD then pcall(_G.HX_UNLOAD) end

-- 世代 token：新实例一加载，旧实例的循环自动退出
_G.__HX_TOKEN = (_G.__HX_TOKEN or 0) + 1
local TOKEN = _G.__HX_TOKEN

-- 断开上一代脚本注册在 RenderStepped 上的回调（来源名 "[string \"\"]" 只会是 loadstring 的脚本）
_G.HX_HARD_RESET = function()
    local RS = game:GetService("RunService")
    local n = 0
    pcall(function()
        for _, c in ipairs(getconnections(RS.RenderStepped)) do
            local src = ""
            pcall(function() src = debug.info(c.Function, "s") end)
            if src == '[string ""]' then
                pcall(function() c:Disconnect() end)
                n = n + 1
            end
        end
    end)
    return n
end
pcall(_G.HX_HARD_RESET)

-- 上一代遗留的 Drawing 对象无法通过闭包引用，单独登记清理
if _G.__HX_DRAW then
    for i = 1, #_G.__HX_DRAW do
        pcall(function() _G.__HX_DRAW[i]:Remove() end)
    end
end
_G.__HX_DRAW = {}

-- 清掉上一次留下的 Obsidian 面板（旧版卸载函数拿不到窗口引用时留下的）
do
    local roots = {}
    if gethui then table.insert(roots, gethui()) end
    table.insert(roots, game:GetService("CoreGui"))
    for _, r in ipairs(roots) do
        if r then
            for _, d in ipairs(r:GetChildren()) do
                if d:IsA("ScreenGui") and string.find(d.Name, "Obsidian") then
                    pcall(function() d:Destroy() end)
                end
            end
        end
    end
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local lp = Players.LocalPlayer

local CFG = {
    esp = {
        on = true,
        box = true,
        name = true,
        hp = true,            -- 血量数字
        hpBar = false,        -- 旧的血条（默认关）
        useVisual = false,    -- CharacterVisuals 是蒙皮模板，取到的位置不对，默认关
        tracer = false,
        teamColor = true,
        teamTag = true,
        enemiesOnly = false,
        maxDist = 600,
        refreshHz = 45,
        allyColor = Color3.fromRGB(90, 255, 150),
        enemyColor = Color3.fromRGB(255, 75, 75),
    },
    aim = {
        on = false,
        mode = "hold",        -- hold / toggle / always
        key = Enum.KeyCode.Q,
        part = "Auto",        -- Auto: 人类打头；SCP 用 scpPart 指定的部位
        scpPart = "Head",     -- 其它 SCP 一律打头（999 单独走下面的特殊分支）
        useVisual = false,    -- 同上，关闭
        scpOffsetY = -0.35,   -- 命中盒中心比视觉头顶高，往下压这么多
        scp999OffsetY = 0.20, -- SCP-999：以腿部命中盒为基准再往上抬一点，贴住果冻
        fov = 12,             -- 角度制默认：近距离也不会被"像素圈"挡掉
        fovUnit = "deg",     -- deg / px
        smooth = 10,
        maxDist = 500,
        teamCheck = true,
        visCheck = true,
        sticky = true,
        snapDeg = 1.2,        -- 角度误差小于这个值就直接贴合（解决"永远差一点"）
        headOffset = 0.0,     -- 头部命中点上下微调（studs）
        headOffsetY = -0.35,  -- 命中盒中心相对视觉头顶的固定偏差
        showFov = true,
        mouseAim = true,      -- 真正的瞄准：推鼠标（游戏开火读的是相机 LookVector，而它由鼠标驱动）
        pxGain = 0.35,        -- 每帧吃掉屏幕误差的比例（0.2 稳、0.6 快）
        cameraWrite = false,  -- 只写相机不改鼠标 = 只在渲染那一帧有效，开火时已被覆盖
        invertX = false,
        invertY = false,
        visColor = false,
    },
    silent = {
        on = false,
        fov = 25,             -- 独立 FOV（度）
        part = "Auto",
        scpPart = "Stomach",
        scpOffsetY = -1.5,
        headOffset = 0.0,
        teamCheck = true,
        visCheck = true,      -- 默认要求可见：穿墙改写最容易被判无效
        headChance = 60,      -- Random 模式下的爆头率（%）
        rewrite = true,       -- 按 pellet[1] 精确改写方向（结构不符则跳过）
        maxAngle = 6,         -- 需要转超过这个角度就不改写（角度越大越容易被服务器判异常）
        maxDist = 500,
        sticky = true,
    },
    vis = { tracers = false, beams = true },
    spread = {
        on = false,
    },
    stamina = {
        on = false,
    },
    recoil = {
        on = false,
        punch = true,
    },
    nav = {
        on = false,
        model = "br_s_nav_ultimate",
        charge = 100,
    },
    phase = {
        on = false,
        radius = 12,
    },
    ammo = {
        on = true,
        x = 0,      -- 相对屏幕底部中线的偏移
        y = -45,
    },
    traps = {
        on = true,
        maxDist = 400,
    },
    move = {
        speedMul = 1.0,     -- 1.0 = 原速；写入 runSpeed / walkSpeed 属性
        passDoors = false,  -- 写 PassDoors，让 MovementTrace 忽略门
    },
}
_G.HXCFG = CFG

-- 默认值副本，用于 Reset
local CFG_DEFAULTS = {}
for sect, tbl in pairs(CFG) do
    local c = {}
    for k, v in pairs(tbl) do c[k] = v end
    CFG_DEFAULTS[sect] = c
end

-- =====================  阵营  =====================
local TEAM_ALIAS = { MTF = "GUARD", CI = "CHAOS", CLASS_D = "CLASSD", DCLASS = "CLASSD" }
local ALLIES = {
    CLASSD   = { CHAOS = true },
    CHAOS    = { CLASSD = true },
    SECURITY = { SCI = true, SPECIAL = true, GUARD = true, NTF = true, QRT = true },
    SCI      = { SECURITY = true, SPECIAL = true, GUARD = true, NTF = true, QRT = true },
    SPECIAL  = { SECURITY = true, SCI = true, GUARD = true, NTF = true, QRT = true },
    GUARD    = { SCI = true, SPECIAL = true, SECURITY = true, NTF = true, QRT = true },
    NTF      = { SCI = true, SPECIAL = true, SECURITY = true, GUARD = true, QRT = true },
    QRT      = { SCI = true, SPECIAL = true, SECURITY = true, GUARD = true, NTF = true },
    SCP      = { SH = true },
    SH       = { SCP = true },
    GOC      = {}, COTSK = {}, UIU = {}, SPEC = {},
}
local TEAM_COLOR = {
    SECURITY = Color3.fromRGB(80, 160, 255),
    GUARD    = Color3.fromRGB(70, 120, 230),
    NTF      = Color3.fromRGB(255, 190, 60),
    QRT      = Color3.fromRGB(120, 160, 255),
    SCI      = Color3.fromRGB(120, 230, 235),
    SPECIAL  = Color3.fromRGB(255, 120, 200),
    CLASSD   = Color3.fromRGB(255, 150, 60),
    CHAOS    = Color3.fromRGB(180, 60, 220),
    SCP      = Color3.fromRGB(255, 60, 60),
    SH       = Color3.fromRGB(110, 200, 120),
    GOC      = Color3.fromRGB(200, 200, 200),
    COTSK    = Color3.fromRGB(210, 60, 90),
    UIU      = Color3.fromRGB(120, 140, 90),
    DZ       = Color3.fromRGB(190, 120, 255),
    SPEC     = Color3.fromRGB(150, 150, 150),
}

local function normTeam(t) return TEAM_ALIAS[t] or t end
local function isAlly(myT, t)
    local a, b = normTeam(myT), normTeam(t)
    if a == b then return true end
    local set = ALLIES[a]
    if not set then return false end
    return set[b] == true
end

local myTeam, myRole = "?", "?"
local function refreshSelf()
    myTeam = tostring(lp:GetAttribute("Team") or "?")
    myRole = tostring(lp:GetAttribute("Role") or "?")
end
refreshSelf()

local function teamCol(team, ally)
    if ally then return CFG.esp.allyColor end
    return TEAM_COLOR[normTeam(team)] or CFG.esp.enemyColor
end

-- =====================  配置持久化  =====================
local HttpService = game:GetService("HttpService")
local CFG_FILE = "hx_scp_cfg.json"
local CFG_VER = 2
_G.HX_CFG_PATH = CFG_FILE

local cfgDirty = true
local saveTimer = 0
local lastErr = ""

local function encVal(v)
    if typeof(v) == "Color3" then return { __c = { v.R, v.G, v.B } } end
    if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then return v end
    return nil
end

local function snapshot()
    local o = { __ver = CFG_VER }
    for sect, tbl in pairs(CFG) do
        if type(tbl) == "table" then
            local st = {}
            for k, v in pairs(tbl) do
                local e = encVal(v)
                if e ~= nil then st[k] = e end
            end
            o[sect] = st
        end
    end
    return o
end

-- 只覆盖已知键，缺的保持默认（旧配置加新字段不会炸）
local function applyTable(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for sect, tbl in pairs(t) do
        if type(tbl) == "table" and type(CFG[sect]) == "table" then
            for k, v in pairs(tbl) do
                if CFG[sect][k] ~= nil then
                    if type(v) == "table" and v.__c then
                        CFG[sect][k] = Color3.new(v.__c[1], v.__c[2], v.__c[3])
                        n = n + 1
                    elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                        -- 类型要匹配，避免把数字塞进字符串字段
                        if type(CFG[sect][k]) == type(v) then
                            CFG[sect][k] = v
                            n = n + 1
                        end
                    end
                end
            end
        end
    end
    return n
end

local function saveCfg()
    local okEnc, js = pcall(function() return HttpService:JSONEncode(snapshot()) end)
    if not okEnc then lastErr = "encode: " .. tostring(js) return false end
    local okW, errW = pcall(writefile, CFG_FILE, js)
    if not okW then lastErr = "write: " .. tostring(errW) return false end
    cfgDirty = false
    lastErr = ""
    return true
end

local function loadCfg()
    if not isfile or not isfile(CFG_FILE) then return false, "no file" end
    local okR, raw = pcall(readfile, CFG_FILE)
    if not okR or type(raw) ~= "string" or #raw < 5 then return false, "read fail" end
    local okD, res = pcall(function() return HttpService:JSONDecode(raw) end)
    if not okD then return false, "decode fail" end
    local n = applyTable(res)
    return true, "keys=" .. n
end

local function resetCfg()
    for sect, tbl in pairs(CFG) do
        if type(tbl) == "table" and CFG_DEFAULTS[sect] then
            for k, v in pairs(CFG_DEFAULTS[sect]) do
                CFG[sect][k] = v
            end
        end
    end
    cfgDirty = true
end

-- 启动时读一次
local loaded, loadMsg = loadCfg()
_G.HX_CFG_STATUS = "load: " .. tostring(loaded) .. " (" .. tostring(loadMsg) .. ")"

-- 自动保存：每 0.5s 检查一次是否有改动（比较序列化结果）
task.spawn(function()
    local last = ""
    while true do
        task.wait(0.5)
        local ok, js = pcall(function() return HttpService:JSONEncode(snapshot()) end)
        if ok and js ~= last then
            last = js
            saveCfg()
        end
    end
end)

-- =====================  UI（Obsidian，与 Hush 同款）  =====================
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
            if ok then Library = res else warn("[HX] UI lib error: " .. tostring(res)) end
        end
    end
end

local Tabs, UIW, UIGUI
if Library then
    UIW = Library:CreateWindow({
        Title = "HX  |  SCP: Breach",
        Footer = "v1",
        ToggleKeybind = Enum.KeyCode.Insert,
        Resizable = true,
        ShowCustomCursor = false,
    })
    Tabs = {
        Aim = UIW:AddTab("Aimbot", "crosshair"),
        Esp = UIW:AddTab("ESP", "box"),
        Info = UIW:AddTab("Info", "activity"),
    }
    UIGUI = nil
    do
        local roots = {}
        if gethui then table.insert(roots, gethui()) end
        table.insert(roots, game:GetService("CoreGui"))
        for _, r in ipairs(roots) do
            if r then
                for _, d in ipairs(r:GetChildren()) do
                    if d:IsA("ScreenGui") and string.find(d.Name, "Obsidian") then UIGUI = d end
                end
            end
        end
    end
end

-- =====================  ESP 绘制池  =====================
local POOL = 48
local slots = {}
for i = 1, POOL do
    local box = Drawing.new("Square")
    box.Thickness = 1
    box.Filled = false
    box.Visible = false
    local txt = Drawing.new("Text")
    txt.Size = 13
    txt.Center = true
    txt.Outline = true
    txt.Visible = false
    local hpbg = Drawing.new("Square")
    hpbg.Filled = true
    hpbg.Visible = false
    local hpfill = Drawing.new("Square")
    hpfill.Filled = true
    hpfill.Visible = false
    local hptxt = Drawing.new("Text")
    hptxt.Size = 12
    hptxt.Center = true
    hptxt.Outline = true
    hptxt.Visible = false
    local tr = Drawing.new("Line")
    tr.Thickness = 1
    tr.Visible = false
    slots[i] = { box = box, txt = txt, hpbg = hpbg, hpfill = hpfill, hptxt = hptxt, tr = tr }
    _G.__HX_DRAW[#_G.__HX_DRAW + 1] = box
    _G.__HX_DRAW[#_G.__HX_DRAW + 1] = txt
    _G.__HX_DRAW[#_G.__HX_DRAW + 1] = hpbg
    _G.__HX_DRAW[#_G.__HX_DRAW + 1] = hpfill
    _G.__HX_DRAW[#_G.__HX_DRAW + 1] = hptxt
    _G.__HX_DRAW[#_G.__HX_DRAW + 1] = tr
end

local fovCircle = Drawing.new("Circle")
fovCircle.Thickness = 1
fovCircle.NumSides = 48
fovCircle.Color = Color3.fromRGB(255, 255, 255)
fovCircle.Transparency = 0.45
fovCircle.Filled = false
fovCircle.Visible = false

local fovText = Drawing.new("Text")
fovText.Size = 12
fovText.Center = true
fovText.Outline = true
fovText.Color = Color3.fromRGB(255, 255, 255)
fovText.Visible = false

local dbgName, dbgErr = "", 0
local SHOTS = {}

local tracerPool = {}
for i = 1, 14 do
    local ln = Drawing.new("Line")
    ln.Thickness = 1
    ln.Visible = false
    tracerPool[i] = ln
    _G.__HX_DRAW[#_G.__HX_DRAW + 1] = ln
end

-- ===== 3D 弹道光束（从枪口位置射出的半透明模型线）=====
for _, o in ipairs(workspace:GetChildren()) do
    if o.Name == "HX_BEAM" then pcall(function() o:Destroy() end) end
end
local BEAM_POOL = 4
local beamSlots = {}
for i = 1, BEAM_POOL do
    local host = Instance.new("Part")
    host.Name = "HX_BEAM"
    host.Anchored = true
    host.CanCollide = false
    host.CanQuery = false
    host.CastShadow = false
    host.Transparency = 1
    host.Size = Vector3.new(0.2, 0.2, 0.2)
    host.Parent = workspace
    local a0 = Instance.new("Attachment", host)
    local a1 = Instance.new("Attachment", host)
    local beam = Instance.new("Beam")
    beam.Attachment0 = a0
    beam.Attachment1 = a1
    beam.Width0 = 0.10
    beam.Width1 = 0.03
    beam.FaceCamera = true
    beam.LightEmission = 1
    beam.Segments = 1
    beam.Enabled = false
    beam.Parent = host
    beamSlots[i] = { host = host, a0 = a0, a1 = a1, beam = beam, until_ = 0, col = Color3.new(1, 1, 1) }
end
local beamIdx = 0

-- 枪口近似位置：相机右下前方（枪的骨骼是客户端蒙皮，取不到真件）
local function muzzlePos(cam)
    local cf = cam.CFrame
    return cf.Position + cf.RightVector * 0.42 - cf.UpVector * 0.28 + cf.LookVector * 1.1
end

local function spawnBeam(from, to, cyan)
    if not CFG.vis.beams then return end
    beamIdx = beamIdx % BEAM_POOL + 1
    local b = beamSlots[beamIdx]
    b.host.CFrame = CFrame.new(from)
    b.a0.Position = Vector3.new(0, 0, 0)
    b.a1.Position = to - from
    b.col = cyan and Color3.fromRGB(0, 255, 255) or Color3.fromRGB(255, 240, 180)
    b.beam.Color = ColorSequence.new(b.col)
    b.beam.Transparency = NumberSequence.new(0.35)
    b.beam.Enabled = true
    b.until_ = os.clock() + 0.45
end

local function updateBeams()
    local now = os.clock()
    for i = 1, BEAM_POOL do
        local b = beamSlots[i]
        if b.beam.Enabled then
            local left = b.until_ - now
            if left <= 0 then
                b.beam.Enabled = false
            else
                local a = 0.35 + 0.6 * (1 - left / 0.45)
                b.beam.Transparency = NumberSequence.new(a)
            end
        end
    end
end

local function drawTracers()
    local now = os.clock()
    local n = 0
    for i = 1, #SHOTS do
        local sh = SHOTS[i]
        local age = now - sh.t
        if age < 0.8 and n < #tracerPool then
            n = n + 1
            local ln = tracerPool[n]
            local cam = workspace.CurrentCamera
            local from = cam:WorldToViewportPoint(sh.o)
            local p2, on2 = cam:WorldToViewportPoint(sh.to)
            -- 起点通常在相机上（Z≈0），不能因此丢掉整条线；终点在身后才跳过
            if p2.Z > 0 then
                local fx, fy = from.X, from.Y
                if from.Z <= 0 then
                    local vp = cam.ViewportSize
                    fx, fy = vp.X / 2, vp.Y / 2
                end
                ln.From = Vector2.new(fx, fy)
                ln.To = Vector2.new(p2.X, p2.Y)
                ln.Color = sh.s and Color3.fromRGB(0, 255, 255) or Color3.fromRGB(255, 255, 255)
                ln.Transparency = math.clamp(1 - age / 0.8, 0, 1)
                ln.Visible = true
            else
                ln.Visible = false
            end
        end
    end
    for i = n + 1, #tracerPool do tracerPool[i].Visible = false end
end

local cache = {}
local targets = {}
local VISLIST = {}

-- 可视模型在 workspace.CharacterVisuals 里（名字是模型路径，不是玩家名），按位置和角色配
local function collectVisuals()
    local out = {}
    local cv = workspace:FindFirstChild("CharacterVisuals")
    if not cv then return out end
    for _, m in ipairs(cv:GetChildren()) do
        local ok, cf, sz = pcall(function() return m:GetBoundingBox() end)
        if ok and cf and sz then
            local top = cf.Position.Y + sz.Y / 2
            local bottom = cf.Position.Y - sz.Y / 2
            local headPart, headY = nil, -math.huge
            for _, d in ipairs(m:GetDescendants()) do
                if d:IsA("BasePart") then
                    local nm = string.lower(d.Name)
                    if string.find(nm, "head", 1, true) and d.Position.Y > headY then
                        headPart, headY = d, d.Position.Y
                    end
                end
            end
            local headPos = headPart and headPart.Position
                or Vector3.new(cf.Position.X, top - 0.35, cf.Position.Z)
            out[#out + 1] = { c = cf.Position, top = top, bottom = bottom, head = headPos, size = sz }
        end
    end
    return out
end

local function collect()
    VISLIST = collectVisuals()
    local out = {}
    local cam = workspace.CurrentCamera
    local camPos = cam.CFrame.Position
    local plist = Players:GetPlayers()
    for i = 1, #plist do
        local plr = plist[i]
        if plr ~= lp then
            local ch = plr.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                local root2 = ch:FindFirstChild("HumanoidRootPart")
                local hb = ch:FindFirstChild("Hitboxes")
                local head = hb and hb:FindFirstChild("Head")
                if root2 and head then
                    local team = tostring(plr:GetAttribute("Team") or "?")
                    if team ~= "SPEC" then
                        local hp = head.Position
                        local ally = isAlly(myTeam, team)
                        if not (CFG.esp.enemiesOnly and ally) then
                            local e = cache[plr] or {}
                            e.plr = plr
                            e.name = plr.Name
                            e.team = team
                            e.role = tostring(plr:GetAttribute("Role") or "")
                            e.ally = ally
                            e.head = head
                            e.root = root2
                            e.hum = hum
                            e.hp = hum.Health
                            e.mhp = hum.MaxHealth
                            e.pos = hp
                            e.dist = (hp - camPos).Magnitude
                            -- 配可视模型：取最近的（同一位置半径内）
                            local bv, bd = nil, 7
                            local rp0 = root2.Position
                            for vi = 1, #VISLIST do
                                local v = VISLIST[vi]
                                local dd = (v.c - rp0).Magnitude
                                if dd < bd then bv, bd = v, dd end
                            end
                            if bv then
                                -- 存相对偏移而不是绝对坐标：命中盒每帧都在动，绝对坐标一采集就过期
                                e.vTopOff = bv.top - hp.Y
                                e.vBotOff = bv.bottom - hp.Y
                                e.vOff = bv.head - hp
                            else
                                e.vTopOff, e.vBotOff, e.vOff = nil, nil, nil
                            end
                            cache[plr] = e
                            out[#out + 1] = e
                        end
                    end
                end
            end
        end
    end
    targets = out
end

-- 注意：自瞄不能用 onScreen 过滤，否则只能瞄已经在屏幕里的目标（远处/边缘的永远瞄不到）
local function project(pos, needOnScreen)
    local cam = workspace.CurrentCamera
    local sp, on = cam:WorldToViewportPoint(pos)
    if sp.Z <= 0 then return nil, false end
    if needOnScreen and not on then return nil, false end
    return Vector2.new(sp.X, sp.Y), true
end

local locks = { aim = nil, silent = nil }

local function fovRadiusPx(cfg)
    local cam = workspace.CurrentCamera
    if cfg.fovUnit == "px" then return cfg.fov end
    local vp = cam.ViewportSize
    local half = math.rad(cam.FieldOfView / 2)
    return (math.tan(math.rad(cfg.fov)) / math.tan(half)) * (vp.Y / 2)
end

local function partOf(t, cfg)
    if cfg.useVisual and t.vOff then
        return t.head.Position + t.vOff
    end
    local hb = t.head.Parent

    --[[
        SCP-999 单独一档

        实测它的命中盒是完整人形骨架（Head +1.56 / Chest +0.50 / Stomach -0.21 /
        腿 -1.78，相对 root），但视觉模型是贴在地面的一坨果冻。
        瞄 Stomach 仍然在它头顶上方（实测差 1.5 studs 以上），必须用腿的命中盒
        当基准 —— 腿盒子中心已经接近地面，正好落在果冻身体里。
    ]]
    if cfg.part == "Auto" and string.find(tostring(t.role or ""), "999", 1, true) then
        local ll = hb:FindFirstChild("LeftLeg")
        local rl = hb:FindFirstChild("RightLeg")
        local base
        if ll and rl then
            base = (ll.Position + rl.Position) * 0.5
        elseif ll or rl then
            base = (ll or rl).Position
        else
            base = (hb:FindFirstChild("Stomach") or t.head).Position
        end
        return base + Vector3.new(0, cfg.scp999OffsetY or 0, 0)
    end

    local mode = cfg.part
    if mode == "Random" then
        -- 按爆头率掷一次：命中就用 Head，否则 Chest
        local chance = cfg.headChance or 60
        mode = (math.random(1, 100) <= chance) and "Head" or "Chest"
    elseif mode == "Auto" then
        mode = (normTeam(t.team) == "SCP") and (cfg.scpPart or "Stomach") or "Head"
    end
    local part = hb:FindFirstChild(mode)
    local pos
    if part then
        pos = part.Position
    elseif mode == "Head" then
        pos = t.head.Position
    else
        local fb = hb:FindFirstChild("Chest") or hb:FindFirstChild("Stomach") or t.head
        pos = fb.Position
    end

    local offY = cfg.headOffset or 0
    -- 命中盒中心比视觉头顶高约 0.35 studs，距离越远看起来偏得越多，这里拉回来
    if mode == "Head" then
        offY = offY + (cfg.headOffsetY or 0)
    end
    -- 只有 Auto 模式才给 SCP 下压；显式选 Head 不该被压到胃部
    if cfg.part == "Auto" and normTeam(t.team) == "SCP" then
        offY = offY + (cfg.scpOffsetY or 0)
    end
    return pos + Vector3.new(0, offY, 0)
end

local function pickTarget(cfg, key)
    local cam = workspace.CurrentCamera
    local camPos = cam.CFrame.Position
    local vp = cam.ViewportSize
    local cx, cy = vp.X / 2, vp.Y / 2
    local look = cam.CFrame.LookVector

    -- 到准星的像素距离：FOV 圈画多大，就只在这个圈里挑
    local function metric(t)
        local pos = partOf(t, cfg)
        local dir = pos - camPos
        if dir.Magnitude < 0.4 then return nil end
        if dir.Unit:Dot(look) <= 0 then return nil end          -- 背后不参与
        local sp, vis = project(pos, false)
        if not vis then return nil end
        return (sp - Vector2.new(cx, cy)).Magnitude, pos
    end

    -- 第一遍：严格按"到准星（鼠标）的像素距离"取最小
    local best, bestD, bestPos = nil, fovRadiusPx(cfg), nil
    for i = 1, #targets do
        local t = targets[i]
        if t.dist <= cfg.maxDist then
            local okTeam = (not cfg.teamCheck) or (not t.ally)
            if okTeam then
                local d, pos = metric(t)
                if d and d < bestD then
                    local blocked = false
                    if cfg.visCheck then
                        local rp = RaycastParams.new()
                        rp.FilterType = Enum.RaycastFilterType.Exclude
                        rp.FilterDescendantsInstances = { lp.Character, t.plr.Character }
                        local hit = workspace:Raycast(camPos, pos - camPos, rp)
                        if hit then
                            local inst = hit.Instance
                            -- 只把"实体"当遮挡：半透明、无碰撞、以及特效类都忽略
                            blocked = (inst.Transparency < 0.75) and inst.CanCollide
                        end
                    end
                    if not blocked then
                        best, bestD, bestPos = t, d, pos
                    end
                end
            end
        end
    end

    -- 第二遍：sticky 只作为平手时的优先，绝不会压过更近的目标
    if best and cfg.sticky and locks[key] and locks[key] ~= best.plr then
        for i = 1, #targets do
            local t = targets[i]
            if t.plr == locks[key] then
                local d, pos = metric(t)
                if d and d <= bestD * 1.1 + 6 and t.dist <= cfg.maxDist * 1.5 then
                    if (not cfg.teamCheck) or (not t.ally) then
                        return t, pos
                    end
                end
                break
            end
        end
    end

    if best then locks[key] = best.plr end
    return best, bestPos
end

-- =====================  自瞄（相机写入，排在相机脚本之后）  =====================
local aimHeld = false
local toggleOn = false
local curLook = nil

local function triggerHeld()
    if CFG.aim.mode == "always" then return true end
    if CFG.aim.mode == "toggle" then return toggleOn end
    return aimHeld
end

local function aimActive()
    return CFG.aim.on and triggerHeld()
end

local function silentActive()
    return CFG.silent.on and triggerHeld()
end

local silentHits = 0

-- 记录一发弹道（含是否被 silent 改写），供可视化用
local function recordShot(origin, tbl, rewritten)
    local dir
    for _, v in pairs(tbl) do
        if typeof(v) == "Vector3" then dir = v break end
        if type(v) == "table" then
            for _, vv in pairs(v) do
                if typeof(vv) == "Vector3" then dir = vv break end
            end
        end
        if dir then break end
    end
    if not dir then return end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = { lp.Character }
    local hit = workspace:Raycast(origin, dir * 500, rp)
    local to = hit and hit.Position or (origin + dir * 500)
    SHOTS[#SHOTS + 1] = { o = origin, to = to, t = os.clock(), s = rewritten }
    if CFG.vis.beams then
        local cam = workspace.CurrentCamera
        pcall(spawnBeam, muzzlePos(cam), to, rewritten)
    end
    if #SHOTS > 14 then table.remove(SHOTS, 1) end
end

-- silent aim：GunAction:FireServer(gunId, origin, ?, {方向表})
-- 方向是客户端提供的，直接改表里的向量即可，视角完全不动
local function silentDir(origin)
    if not silentActive() then return nil, nil end
    local t, pos = pickTarget(CFG.silent, "silent")
    if not t or not pos then return nil, nil end
    local d = pos - origin
    if d.Magnitude < 1 then return nil, nil end
    local unit = d.Unit
    -- 需要转的角度太大就不改：服务器对离谱方向通常会判无效（表现为打不出伤害）
    local look = workspace.CurrentCamera.CFrame.LookVector
    local ang = math.deg(math.acos(math.clamp(unit:Dot(look), -1, 1)))
    if ang > (CFG.silent.maxAngle or 6) then
        _G.HX_SILENT_SKIP = string.format("angle %.1f > %.1f", ang, CFG.silent.maxAngle or 6)
        return nil, nil
    end
    return unit, t
end

-- 只改 pellet[1]，保持表结构与长度不变；结构不符就整发放弃
local function rewritePelletDirs(tbl, dir)
    local count = #tbl
    if count == 0 or count > 64 then return 0 end
    for i = 1, count do
        local pellet = tbl[i]
        if type(pellet) ~= "table" or typeof(pellet[1]) ~= "Vector3" then return 0 end
    end
    for i = 1, count do tbl[i][1] = dir end
    return count
end

local function rewriteDirs(tbl, dir)
    local n = 0
    for k, v in pairs(tbl) do
        if typeof(v) == "Vector3" then
            tbl[k] = dir
            n = n + 1
        elseif type(v) == "table" then
            n = n + rewriteDirs(v, dir)
        end
    end
    return n
end

_G.HX_HOOK_GUN = 0

-- 每次加载只更新"当前处理函数"，hook 本身在整个 VM 里只装一层
local function hookBody(self, ...)
    local okM, method = pcall(getnamecallmethod)
    if not okM or method ~= "FireServer" then return end
    local okN, nm = pcall(function() return self.Name end)
    if not okN then return end
    -- GunFire 才是带弹道方向的射击远程；GunAction 只用于换弹/切换模式
    if nm ~= "GunFire" and nm ~= "GunShot" then return end
    _G.HX_HOOK_GUN = _G.HX_HOOK_GUN + 1

    local a1, a2, a3, a4 = ...
    -- 详细 dump：只做一次，看清每个参数到底是什么
    if not _G.HX_GUN_DUMP then
        local function desc(v)
            local t = typeof(v)
            if t == "table" then
                local first = v[1]
                return string.format("table#%d[1]=%s/%s", #v, typeof(first), tostring(first):sub(1, 40))
            end
            return t .. ":" .. tostring(v):sub(1, 30)
        end
        local extra = ""
        if typeof(a4) == "table" and typeof(a4[1]) == "table" then
            local inner = a4[1]
            local parts = {}
            for k, v in pairs(inner) do
                parts[#parts + 1] = tostring(k) .. "=" .. typeof(v)
            end
            extra = " | a4[1]{" .. table.concat(parts, ",") .. "}"
        end
        _G.HX_GUN_DUMP = string.format("n=%d a1=%s a2=%s a3=%s a4=%s%s",
            select("#", ...), desc(a1), desc(a2), desc(a3), desc(a4), extra)
    end

    local origin = (typeof(a2) == "Vector3") and a2 or nil
    if not origin then return end

    -- 只读模式：只记录不修改，保证游戏行为不变
    local dirTable
    for _, cand in ipairs({ a3, a4 }) do
        if typeof(cand) == "table" then dirTable = cand break end
    end

    local d = (CFG.silent.rewrite and dirTable) and silentDir(origin) or nil
    local rewritten = false
    if d then
        local n = rewritePelletDirs(dirTable, d)
        if n > 0 then
            silentHits = silentHits + 1
            rewritten = true
        end
    end
    if (CFG.vis.tracers or CFG.vis.beams) and dirTable then
        pcall(recordShot, origin, dirTable, rewritten)
    end
end

_G.HX_HOOK_FN = hookBody

local function ensureHook()
    if _G.HX_SILENT_HOOK then return true end
    local okH, errH = pcall(function()
        local orig
        orig = hookmetamethod(game, "__namecall", function(self, ...)
            local f = _G.HX_HOOK_FN
            if f ~= nil then f(self, ...) end
            return orig(self, ...)
        end)
    end)
    _G.HX_SILENT_HOOK = okH and true or nil
    _G.HX_HOOK_ERR = okH and "" or tostring(errH)
    return _G.HX_SILENT_HOOK == true
end
_G.HX_ENSURE_HOOK = ensureHook

-- 只有开启 silent 时才挂 namecall（平时不挂，避免每秒百万次额外调用）
if CFG.silent.on then pcall(ensureHook) end

local aimWrites = 0
local mAccX, mAccY = 0, 0

local function __aimTick(dt)
    if _G.__HX_TOKEN ~= TOKEN then return end
    if CFG.aim.mode == "hold" and aimHeld and not UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
        aimHeld = false
    end
    if not aimActive() then
        curLook = nil
        return
    end
    local t, aimPos = pickTarget(CFG.aim, "aim")
    if not t or not aimPos then
        curLook = nil
        locks.aim = nil
        mAccX, mAccY = 0, 0
        dbgName, dbgErr = "", -1
        return
    end
    local cam = workspace.CurrentCamera

    if CFG.aim.mouseAim then
        -- 直接用屏幕像素误差闭环：目标投到屏幕后，把它推到准星（屏幕中心）
        -- 不依赖"角度 -> 灵敏度"的换算，游戏相机有任何偏移都能自纠
        local vp = cam.ViewportSize
        local sp, vis = cam:WorldToViewportPoint(aimPos)
        if not vis or sp.Z <= 0 then return end
        local dx = sp.X - vp.X / 2
        local dy = sp.Y - vp.Y / 2

        dbgName = t.name
        dbgErr = math.sqrt(dx * dx + dy * dy)      -- 单位是像素

        -- 开火瞬间强制对齐：按住左键期间用满增益、解除单帧位移上限
        local firing = UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)

        if (not firing) and dbgErr < 1.5 then return end

        local k = firing and 1.0 or (CFG.aim.pxGain or 0.35)
        local mx = dx * k
        local my = dy * k
        local lim = firing and 800 or 40
        if mx > lim then mx = lim elseif mx < -lim then mx = -lim end
        if my > lim then my = lim elseif my < -lim then my = -lim end

        if CFG.aim.invertX then mx = -mx end
        if CFG.aim.invertY then my = -my end

        mAccX = mAccX + mx
        mAccY = mAccY + my
        local ix = math.floor(mAccX + 0.5)
        local iy = math.floor(mAccY + 0.5)
        if ix ~= 0 or iy ~= 0 then
            mousemoverel(ix, iy)
            mAccX = mAccX - ix
            mAccY = mAccY - iy
            aimWrites = aimWrites + 1
        end
    else
        local camPos = cam.CFrame.Position
        local want = (aimPos - camPos).Unit
        local alpha = 1 - math.exp(-CFG.aim.smooth * math.max(dt, 1 / 240))
        curLook = curLook and curLook:Lerp(want, alpha).Unit or want
        local cosA = math.clamp(curLook:Dot(want), -1, 1)
        dbgName, dbgErr = t.name, math.deg(math.acos(cosA))
        if dbgErr < CFG.aim.snapDeg then curLook = want dbgErr = 0 end
        if CFG.aim.cameraWrite then
            cam.CFrame = CFrame.lookAt(camPos, camPos + curLook)
        end
    end
end

RunService:BindToRenderStep("HX_AIM", Enum.RenderPriority.Camera.Value + 1, function(dt)
    local okT, eT = pcall(__aimTick, dt)
    if not okT then _G.HX_AIM_ERR = tostring(eT) end
end)

-- =====================  渲染  =====================
local lastRender = 0
local frames = 0
local lastFps = 0
local fpsAt = os.clock()

--[[
    零散布（聚点）

    散布参数是客户端数据：ReplicatedStorage.Shared.Data.GunData.guns[武器id]。
    开火时客户端拿它算每颗弹丸的随机偏移：
        v90 = (math.random() * 2 - 1) * spread
        LookVector = CFrame.fromOrientation(pitch + v90, yaw + v91, 0).LookVector
    把这些字段清零，弹丸就严格沿准星飞 —— 等同于 100% 精度。

    服务器看到的只是"每一发都打得非常准"，方向本身完全合法，
    不像静默瞄准那样改了不该改的东西。
]]
local SPREAD_FIELDS = { "hipSpread", "aimSpread", "maxSpreadInc", "spreadPerShot", "clumpSpread" }
local spreadModule = nil
local spreadOrig = nil
local spreadNext = 0

local function applyZeroSpread()
    local now = os.clock()
    if now < spreadNext then return end
    spreadNext = now + 0.5

    if not CFG.spread.on then
        if spreadModule and spreadOrig then
            for id, fields in pairs(spreadOrig) do
                local gun = spreadModule.guns[id]
                if type(gun) == "table" then
                    for f, v in pairs(fields) do
                        pcall(function() gun[f] = v end)
                    end
                end
            end
            spreadModule, spreadOrig = nil, nil
        end
        return
    end
    if spreadModule then return end

    local data = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
    data = data and data:FindFirstChild("Data")
    local mod = data and data:FindFirstChild("GunData")
    if not mod then return end
    local ok, GD = pcall(require, mod)
    if not ok or type(GD) ~= "table" or type(GD.guns) ~= "table" then return end

    spreadModule = GD
    spreadOrig = {}
    for id, gun in pairs(GD.guns) do
        if type(gun) == "table" then
            local saved = {}
            for _, f in ipairs(SPREAD_FIELDS) do
                if type(gun[f]) == "number" then
                    saved[f] = gun[f]
                    pcall(function() gun[f] = 0 end)
                end
            end
            spreadOrig[id] = saved
        end
    end
end

--[[
    无限体力

    Client.Core.Stamina 暴露 tick / value / exhausted，全是本地计算：
    体力条和"能不能冲刺"都由它决定，服务器不参与。
    把 tick 换成空函数（不再扣），value 永远返回上限，exhausted 永远 false。
]]
local staminaModule = nil
local staminaOrig = nil
local staminaNext = 0

local function applyStamina()
    local now = os.clock()
    if now < staminaNext then return end
    staminaNext = now + 0.5

    if not CFG.stamina.on then
        if staminaModule and staminaOrig then
            pcall(function() staminaModule.tick = staminaOrig.tick end)
            pcall(function() staminaModule.value = staminaOrig.value end)
            pcall(function() staminaModule.exhausted = staminaOrig.exhausted end)
            staminaModule, staminaOrig = nil, nil
        end
        return
    end
    if staminaModule then return end

    local core = lp.PlayerScripts:FindFirstChild("Client")
    core = core and core:FindFirstChild("Core")
    local mod = core and core:FindFirstChild("Stamina")
    if not mod then return end
    local ok, S = pcall(require, mod)
    if not ok or type(S) ~= "table" then return end

    staminaModule = S
    staminaOrig = { tick = S.tick, value = S.value, exhausted = S.exhausted }
    pcall(function() S.tick = function() end end)
    pcall(function() S.value = function() return (S.max and S.max()) or 100 end end)
    pcall(function() S.exhausted = function() return false end end)
end

--[[
    无后坐力

    开火后游戏会调 Controller.kickView / viewPunch 往视角里加偏移。
    这两个是模块表字段，直接换掉即可 —— 不动元表、可逆、不碰发包。
]]
local recoilModule = nil
local recoilOrig = nil
local recoilNext = 0

local function applyNoRecoil()
    local now = os.clock()
    if now < recoilNext then return end
    recoilNext = now + 0.5

    if not CFG.recoil.on then
        if recoilModule and recoilOrig then
            pcall(function() recoilModule.kickView = recoilOrig.kick end)
            pcall(function() recoilModule.viewPunch = recoilOrig.punch end)
            recoilModule, recoilOrig = nil, nil
        end
        return
    end
    if recoilModule then return end

    local core = lp.PlayerScripts:FindFirstChild("Client")
    core = core and core:FindFirstChild("Core")
    local mod = core and core:FindFirstChild("Controller")
    if not mod then return end
    local ok, C = pcall(require, mod)
    if not ok or type(C) ~= "table" or type(C.kickView) ~= "function" then return end

    recoilModule = C
    recoilOrig = { kick = C.kickView, punch = C.viewPunch }
    pcall(function() C.kickView = function() end end)
    if CFG.recoil.punch then
        pcall(function() C.viewPunch = function() end end)
    end
end

--[[
    召唤导航仪

    游戏自己的 SNav 模块读两个玩家属性：
        LocalPlayer:GetAttribute("SNavCarried")  -> 背包里有没有导航仪（不用装备）
        LocalPlayer:GetAttribute("SNavCharge")   -> 电量
    这两个是纯本地属性（客户端写，不同步到服务器），填上就会把设备变出来。
    地图能不能显示取决于世界供电状态，那是服务器的事，这里只负责"设备在手上 + 电量不耗"。
]]
local navOrig = nil
local navNext = 0

local function applyNav()
    local now = os.clock()
    if now < navNext then return end
    navNext = now + 0.25

    local want = CFG.nav.on and CFG.nav.model or nil
    local cur = lp:GetAttribute("SNavCarried")

    if want then
        if navOrig == nil and cur ~= want then
            navOrig = cur
        end
        if cur ~= want then
            pcall(function() lp:SetAttribute("SNavCarried", want) end)
        end
        local c = lp:GetAttribute("SNavCharge")
        local target = tonumber(CFG.nav.charge) or 100
        if type(c) ~= "number" or c < target - 1 then
            pcall(function() lp:SetAttribute("SNavCharge", target) end)
        end
    elseif navOrig ~= nil then
        pcall(function() lp:SetAttribute("SNavCarried", navOrig) end)
        navOrig = nil
    end
end

--[[
    本地去碰撞穿门

    服务器只决定"门开不开"，根本不管你能不能走过去 —— Roblox 的碰撞是
    客户端算的。把门 part 在本地 CanCollide = false，碰撞就不存在了。

    只影响你自己这台机器：别人看到的门照样是关的，服务器也不会收到任何包。
]]
local phaseCache = nil
local phaseNext = 0

local function restorePhase()
    if not phaseCache then return end
    for i = 1, #phaseCache do
        local e = phaseCache[i]
        if e.p.Parent then
            pcall(function() e.p.CanCollide = e.cc end)
        end
    end
    phaseCache = nil
end

local function applyPhase()
    local now = os.clock()
    if now < phaseNext then return end
    phaseNext = now + 0.15

    if not CFG.phase.on then
        restorePhase()
        return
    end

    if not phaseCache then
        local list = {}
        local root = workspace:FindFirstChild("Map") or workspace
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("BasePart") then
                local n = string.lower(d.Name)
                if string.find(n, "door", 1, true) or string.find(n, "gate", 1, true) or string.find(n, "keycard", 1, true) then
                    list[#list + 1] = { p = d, cc = d.CanCollide }
                end
            end
        end
        phaseCache = list
    end

    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local pos = hrp.Position
    local r = tonumber(CFG.phase.radius) or 12

    for i = 1, #phaseCache do
        local e = phaseCache[i]
        if e.p.Parent then
            local near = (e.p.Position - pos).Magnitude <= r
            local want = (not near) and e.cc or false
            if e.p.CanCollide ~= want then
                pcall(function() e.p.CanCollide = want end)
            end
        end
    end
end

--[[
    弹药 HUD（枪内 / 备弹）

    弹匣计数在 Guns 模块的闭包里，外部拿不到；但游戏自己的 HUD 有一个
    「150 / 150」这样的 TextLabel，直接镜像它的文本最省事，而且永远不会和
    游戏对不上。

    找不到那个 label 时，退回属性方案：备弹是 Ammo_<弹药类型>（实测
    Ammo_SMG1=94 这类），枪内数量显示成 --。
]]
local ammoLabel = nil
local ammoDraw = nil
local ammoFindAt = 0
local gunDataCache = nil
local ammoMagText = nil     -- 弹匣数字，等射击信号接入后填

--[[
    弹匣数来源：GunState 远程

    实测服务器会推 GunState(weaponId, mag, firemode, flag)：
        GunState("cw_kk_ins2_cstm_famas", 26, "auto", 0)
    第二个参数就是弹匣剩余，正好和"开过几枪"对得上。挂个 OnClientEvent
     passively 读它即可，不需要 hook、不需要发包。
]]
local gunMag = nil
local gunMagItem = nil
do
	local R = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
	local gs = R and R:FindFirstChild("GunState")
	if gs and gs:IsA("RemoteEvent") then
		pcall(function()
			gs.OnClientEvent:Connect(function(id, mag)
				if type(mag) == "number" then
					gunMag = mag
					gunMagItem = id
				end
			end)
		end)
	end
end

local function getGunData()
	if gunDataCache then return gunDataCache end
	local rt = game:GetService("ReplicatedStorage")
	local data = rt:FindFirstChild("Shared")
	data = data and data:FindFirstChild("Data")
	local gd = data and data:FindFirstChild("GunData")
	if not gd then return nil end
	local ok, GD = pcall(require, gd)
	if ok and type(GD) == "table" then
		gunDataCache = GD
	end
	return gunDataCache
end

local function findAmmoLabel()
	local gui = lp:FindFirstChild("PlayerGui")
	if not gui then return nil end
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("TextLabel") then
			local t = tostring(d.Text)
			if string.match(t, "^%s*%d+%s*/%s*%d+%s*$") then
				return d
			end
		end
	end
	return nil
end

-- 清掉上一个实例遗留的弹药文字，否则新旧两行会叠在同一个位置
if _G.__HX_AMMO_DRAW then
	pcall(function() _G.__HX_AMMO_DRAW:Remove() end)
	_G.__HX_AMMO_DRAW = nil
end

local function ensureAmmoDraw()
	if ammoDraw then return ammoDraw end
	local ok, d = pcall(function() return Drawing.new("Text") end)
	if not ok or not d then return nil end
	d.Size = 22
	d.Center = true
	d.Outline = true
	d.OutlineColor = Color3.fromRGB(0, 0, 0)
	d.Color = Color3.fromRGB(255, 255, 255)
	d.Visible = false
	ammoDraw = d
	_G.__HX_AMMO_DRAW = d
	return d
end

local function updateAmmoHud()
	local cv = ensureAmmoDraw()
	if not cv then return end

	if not CFG.ammo.on then
		cv.Visible = false
		return
	end

	-- 只在真正持枪时显示：Armed 为真，且当前物品确实是 GunData 里的武器
	local curItem = lp:GetAttribute("ActiveItem")
	local isGun = false
	if lp:GetAttribute("Armed") == true and type(curItem) == "string" then
		local GD = getGunData()
		isGun = GD ~= nil and GD.guns ~= nil and GD.guns[curItem] ~= nil
	end
	if not isGun then
		cv.Visible = false
		return
	end

	local now = os.clock()
	if now >= ammoFindAt then
		ammoFindAt = now + 3
		if not ammoLabel or not ammoLabel.Parent then
			ammoLabel = findAmmoLabel()
		end
	end

	local text = nil
	-- 注意：MainHud 里那个 "150 / 150" 是**血量**，不是弹药。
	-- 弹匣数字在 Guns 模块闭包里，外部读不到；这里先只显示备弹，弹匣等信号确认后再补。
	local GD = getGunData()
	local ammoType = nil
	if GD and GD.guns and GD.guns[curItem] then
		ammoType = GD.guns[curItem].ammo
	end
	if type(ammoType) == "string" then
		local reserve = lp:GetAttribute("Ammo_" .. ammoType)
		if type(reserve) == "number" then
			local magStr = "?"
			if type(gunMag) == "number" and (gunMagItem == nil or gunMagItem == curItem) then
				magStr = tostring(gunMag)
			end
			text = string.format("%s / %d", magStr, reserve)
		end
	end

	if not text then
		cv.Visible = false
		return
	end

	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	cv.Text = text
	cv.Position = Vector2.new(vp.X / 2 + (tonumber(CFG.ammo.x) or 0), vp.Y + (tonumber(CFG.ammo.y) or -45))
	cv.Visible = true
end

--[[
    诡雷 / 陷阱高亮

    实测 RoundObjects 里放的就是地面上的可交互物：
        claymore_mine   ← 诡雷（踩上去炸的那种）
        tesla_new       ← 特斯拉线圈（靠近就电）
    它们在放进地图时是普通 Part，名字固定，直接按名字扫即可。

    每 2 秒重扫一次：诡雷是玩家中途布置/引爆的，静态列表会过期。
]]
local TRAP_NAMES = {
    claymore_mine = { label = "MINE", color = Color3.fromRGB(255, 60, 60) },
}

local trapPool = {}
local trapCache = {}
local trapScanAt = 0

-- 上一代遗留的陷阱框必须清掉，否则重载一次就多留一层残影
if _G.__HX_TRAP_DRAW then
    for i = 1, #_G.__HX_TRAP_DRAW do
        pcall(function() _G.__HX_TRAP_DRAW[i]:Remove() end)
    end
end
_G.__HX_TRAP_DRAW = {}

local function scanTraps()
    local list = {}
    local root = workspace:FindFirstChild("RoundObjects")
    if root then
        for _, d in ipairs(root:GetChildren()) do
            local info = TRAP_NAMES[d.Name]
            if info and d:IsA("BasePart") then
                list[#list + 1] = { part = d, label = info.label, color = info.color }
            end
        end
    end
    trapCache = list
end

local function trapSlot(i)
    local s = trapPool[i]
    if s then return s end
    local o = {}
    pcall(function()
        o.box = Drawing.new("Square")
        o.box.Thickness = 1.5
        o.box.Filled = false
        o.box.Transparency = 1
        o.box.Visible = false

        o.txt = Drawing.new("Text")
        o.txt.Size = 13
        o.txt.Center = true
        o.txt.Outline = true
        o.txt.OutlineColor = Color3.fromRGB(0, 0, 0)
        o.txt.Visible = false
    end)
    pcall(function() o.box.Streamproof = true end)
    pcall(function() o.txt.Streamproof = true end)
    if _G.__HX_TRAP_DRAW then
        _G.__HX_TRAP_DRAW[#_G.__HX_TRAP_DRAW + 1] = o.box
        _G.__HX_TRAP_DRAW[#_G.__HX_TRAP_DRAW + 1] = o.txt
    end
    trapPool[i] = o
    return o
end

local function drawTraps()
    if not CFG.traps.on then
        for i = 1, #trapPool do
            pcall(function() trapPool[i].box.Visible = false end)
            pcall(function() trapPool[i].txt.Visible = false end)
        end
        return
    end

    local now = os.clock()
    if now - trapScanAt > 2 then
        trapScanAt = now
        scanTraps()
    end

    local cam = workspace.CurrentCamera
    local camPos = cam.CFrame.Position
    local n = 0

    for i = 1, #trapCache do
        local t = trapCache[i]
        if t.part.Parent then
            local dist = (t.part.Position - camPos).Magnitude
            if dist <= CFG.traps.maxDist then
                local sp, vis = project(t.part.Position + Vector3.new(0, 0.4, 0))
                if sp and vis then
                    n = n + 1
                    local s = trapSlot(n)
                    local half = math.clamp(1400 / math.max(dist, 4), 8, 46)
                    pcall(function()
                        s.box.Position = Vector2.new(sp.X - half, sp.Y - half)
                        s.box.Size = Vector2.new(half * 2, half * 2)
                        s.box.Color = t.color
                        s.box.Visible = true

                        s.txt.Text = string.format("%s %dm", t.label, math.floor(dist / 3.2))
                        s.txt.Color = t.color
                        s.txt.Position = Vector2.new(sp.X, sp.Y + half + 2)
                        s.txt.Visible = true
                    end)
                end
            end
        end
    end

    for i = n + 1, #trapPool do
        pcall(function() trapPool[i].box.Visible = false end)
        pcall(function() trapPool[i].txt.Visible = false end)
    end
end

--[[
    移动参数

    Controller 里有这一句：
        LocalPlayer.AttributeChanged:Connect(syncParams)
    而 syncParams 会把 runSpeed / walkSpeed 等属性重新读进移动配置。
    所以直接写属性就能改速度，不需要重生、不需要 hook。

    PassDoors 更直接：
        MovementTrace.setPassDoors(LocalPlayer:GetAttribute("PassDoors") == true)
    本地置 true，移动射线就跳过门。

    两者都只写在本地玩家实例上，不会同步到服务器。
]]
local moveBase = nil
local moveNext = 0

local function applyMove()
    local now = os.clock()
    if now < moveNext then return end
    moveNext = now + 0.2

    local mul = tonumber(CFG.move.speedMul) or 1
    local wantDoors = CFG.move.passDoors

    -- 首次启用时记住原始值，关掉时好还原
    if (mul ~= 1 or wantDoors) and not moveBase then
        moveBase = {
            run = lp:GetAttribute("runSpeed"),
            walk = lp:GetAttribute("walkSpeed"),
            doors = lp:GetAttribute("PassDoors"),
        }
    end

    if mul ~= 1 and moveBase then
        if type(moveBase.run) == "number" then
            local target = math.floor(moveBase.run * mul + 0.5)
            if lp:GetAttribute("runSpeed") ~= target then
                pcall(function() lp:SetAttribute("runSpeed", target) end)
            end
        end
        if type(moveBase.walk) == "number" then
            local target = math.floor(moveBase.walk * mul + 0.5)
            if lp:GetAttribute("walkSpeed") ~= target then
                pcall(function() lp:SetAttribute("walkSpeed", target) end)
            end
        end
    elseif mul == 1 and moveBase and type(moveBase.run) == "number" then
        if lp:GetAttribute("runSpeed") ~= moveBase.run then
            pcall(function() lp:SetAttribute("runSpeed", moveBase.run) end)
        end
        if lp:GetAttribute("walkSpeed") ~= moveBase.walk then
            pcall(function() lp:SetAttribute("walkSpeed", moveBase.walk) end)
        end
    end

    if wantDoors then
        if lp:GetAttribute("PassDoors") ~= true then
            pcall(function() lp:SetAttribute("PassDoors", true) end)
        end
    elseif moveBase and moveBase.doors ~= nil then
        if lp:GetAttribute("PassDoors") ~= moveBase.doors then
            pcall(function() lp:SetAttribute("PassDoors", moveBase.doors) end)
        end
    end

    -- 全部关掉后释放基准值，让下次重新采样
    if mul == 1 and not wantDoors and moveBase and type(moveBase.run) ~= "number" then
        moveBase = nil
    end
end

local function render()
    if _G.__HX_TOKEN ~= TOKEN then return end
    local now = os.clock()
    local hz = math.max(CFG.esp.refreshHz, 20)
    if now - lastRender < 1 / hz then return end
    lastRender = now
    frames = frames + 1
    if now - fpsAt >= 1 then
        lastFps = frames
        frames = 0
        fpsAt = now
    end

    local n = 0
    local cam = workspace.CurrentCamera
    local camPos = cam.CFrame.Position
    local vp = cam.ViewportSize
    local cx, cy = vp.X / 2, vp.Y
    local look = cam.CFrame.LookVector

    if CFG.vis.beams then updateBeams() end
    applyZeroSpread()
    applyStamina()
    applyNoRecoil()
    applyNav()
    applyMove()
    applyPhase()
    updateAmmoHud()
    drawTraps()
    if CFG.vis.tracers then drawTracers() end

    if CFG.aim.showFov and CFG.aim.on then
        local ccx, ccy = vp.X / 2, vp.Y / 2
        fovCircle.Position = Vector2.new(ccx, ccy)
        fovCircle.Radius = fovRadiusPx(CFG.aim)
        fovCircle.Visible = true
        fovText.Text = string.format("FOV %d%s | %s | err %s | %s",
            CFG.aim.fov, (CFG.aim.fovUnit == "deg" and "deg" or "px"),
            (dbgName ~= "" and dbgName or "no target"),
            (dbgErr >= 0 and string.format("%.1f", dbgErr) or "--"), CFG.aim.part)
        fovText.Position = Vector2.new(ccx, ccy + CFG.aim.fov + 8)
        fovText.Visible = true
    else
        fovCircle.Visible = false
        fovText.Visible = false
    end

    if CFG.esp.on then
        for i = 1, #targets do
            if n >= POOL then break end
            local t = targets[i]
            if (t.pos - camPos):Dot(look) > 0 and t.dist <= CFG.esp.maxDist then
                local hp = t.head.Position
                local topPos = (CFG.esp.useVisual and t.vTopOff) and (hp + Vector3.new(0, t.vTopOff, 0))
                    or (hp + Vector3.new(0, 0.5, 0))
                local botPos = (CFG.esp.useVisual and t.vBotOff) and (hp + Vector3.new(0, t.vBotOff, 0))
                    or (hp - Vector3.new(0, 4.57, 0))
                local top, v1 = project(topPos, true)
                if v1 then
                    local bot, v2 = project(botPos, true)
                    if v2 then
                        local h = bot.Y - top.Y
                        if h > 8 and h < 4000 then
                            n = n + 1
                            local s = slots[n]
                            local w = h * 0.45
                            local left = top.X - w / 2
                            local col = teamCol(t.team, t.ally)

                            s.box.Color = col
                            s.box.Position = Vector2.new(left, top.Y)
                            s.box.Size = Vector2.new(w, h)
                            s.box.Visible = CFG.esp.box

                            if CFG.esp.name then
                                local tag = ""
                                if CFG.esp.teamTag then
                                    tag = (t.ally and "[A " or "[E ") .. t.team .. "] "
                                end
                                s.txt.Text = tag .. t.name .. " " .. tostring(math.floor(t.dist)) .. "st"
                                s.txt.Color = col
                                s.txt.Position = Vector2.new(top.X, top.Y - 15)
                                s.txt.Visible = true
                            else
                                s.txt.Visible = false
                            end

                            if CFG.esp.hp then
                                s.hptxt.Text = tostring(math.floor(t.hp))
                                s.hptxt.Color = Color3.fromRGB(120, 255, 150)
                                s.hptxt.Position = Vector2.new(top.X, bot.Y + 2)
                                s.hptxt.Visible = true
                            else
                                s.hptxt.Visible = false
                            end

                            if CFG.esp.hpBar then
                                local pct = t.hp / math.max(t.mhp, 1)
                                if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
                                local bx = left + w + 3
                                s.hpbg.Color = Color3.fromRGB(20, 20, 20)
                                s.hpbg.Position = Vector2.new(bx, top.Y)
                                s.hpbg.Size = Vector2.new(3, h)
                                s.hpbg.Visible = true
                                s.hpfill.Color = Color3.fromRGB(80, 230, 120)
                                s.hpfill.Position = Vector2.new(bx, top.Y + h * (1 - pct))
                                s.hpfill.Size = Vector2.new(3, h * pct)
                                s.hpfill.Visible = true
                            else
                                s.hpbg.Visible = false
                                s.hpfill.Visible = false
                            end

                            if CFG.esp.tracer then
                                s.tr.Color = col
                                s.tr.From = Vector2.new(cx, cy)
                                s.tr.To = Vector2.new(bot.X, bot.Y)
                                s.tr.Visible = true
                            else
                                s.tr.Visible = false
                            end
                        end
                    end
                end
            end
        end
    end

    for i = n + 1, POOL do
        local s = slots[i]
        s.box.Visible = false
        s.txt.Visible = false
        s.hpbg.Visible = false
        s.hpfill.Visible = false
        s.hptxt.Visible = false
        s.tr.Visible = false
    end
end

-- 包一层 pcall：render 里任何一处报错都不该让整条渲染循环断掉
-- （上一版就是因为一个未定义函数直接抛错，连接被引擎断开，全部功能消失）
local renderConn = RunService.RenderStepped:Connect(function()
    pcall(render)
end)
local collectConn = task.spawn(function()
    while _G.__HX_TOKEN == TOKEN do
        local ok, err = pcall(collect)
        if not ok then _G.HX_ERR = tostring(err) end
        task.wait(0.6)
    end
end)

local statusConn = task.spawn(function()
    while true do
        pcall(refreshSelf)
        _G.HX_STATUS_TEXT = string.format("fps %d | tgt %d | team %s | %s", lastFps, #targets, myTeam, myRole)
        task.wait(0.5)
    end
end)

-- =====================  输入  =====================
UIS.InputBegan:Connect(function(i, gp)
    if gp then return end
end)
UIS.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.UserInputType == Enum.UserInputType.MouseButton2 and CFG.aim.mode == "hold" then
        aimHeld = true
    end
end)
UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton2 then aimHeld = false end
end)

-- =====================  UI 控件  =====================
if Library then
    local gA = Tabs.Aim:AddLeftGroupbox("Aimbot", "crosshair")
    gA:AddToggle("aimOn", {
        Text = "Enable", Default = CFG.aim.on,
        Callback = function(v) CFG.aim.on = v end,
    })
    gA:AddDropdown("aimMode", {
        Text = "Trigger", Values = { "Hold", "Toggle", "Always" }, Default = "Hold",
        Callback = function(v)
            local m = string.lower(tostring(v))
            if m == "hold" then CFG.aim.mode = "hold"
            elseif m == "toggle" then CFG.aim.mode = "toggle"
            else CFG.aim.mode = "always" end
        end,
    })
    gA:AddDropdown("aimPart", {
        Text = "Hit part", Values = { "Auto", "Head", "Chest", "Stomach", "Legs" }, Default = "Auto",
        Tooltip = "Auto = Head for humans, SCP part below for SCPs",
        Callback = function(v) CFG.aim.part = tostring(v) end,
    })
    gA:AddDropdown("aimScpPart", {
        Text = "SCP part", Values = { "Stomach", "Chest", "Head", "LeftLeg" }, Default = "Stomach",
        Tooltip = "SCP models are much smaller than their hitbox rig; stomach tracks the visible body",
        Callback = function(v) CFG.aim.scpPart = tostring(v) end,
    })
    gA:AddDropdown("aimFovUnit", {
        Text = "FOV unit", Values = { "deg", "px" }, Default = "deg",
        Tooltip = "deg = angle around crosshair (works at any range); px = pixel circle",
        Callback = function(v) CFG.aim.fovUnit = string.lower(tostring(v)) end,
    })
    gA:AddSlider("aimFov", {
        Text = "FOV", Default = CFG.aim.fov, Min = 1, Max = 90, Rounding = 1,
        Tooltip = "In deg mode this is degrees (1-90). Switch unit to px for 20-900 pixels",
        Callback = function(v) CFG.aim.fov = v end,
    })
    gA:AddSlider("aimSmooth", {
        Text = "Smooth", Default = CFG.aim.smooth, Min = 1, Max = 30, Rounding = 0,
        Callback = function(v) CFG.aim.smooth = v end,
    })
    gA:AddSlider("aimDist", {
        Text = "Max distance", Default = CFG.aim.maxDist, Min = 50, Max = 1500, Rounding = 0, Suffix = " studs",
        Callback = function(v) CFG.aim.maxDist = v end,
    })
    gA:AddToggle("aimTeam", {
        Text = "Team check", Default = CFG.aim.teamCheck,
        Callback = function(v) CFG.aim.teamCheck = v end,
    })
    gA:AddToggle("aimVis", {
        Text = "Visible check", Default = CFG.aim.visCheck,
        Callback = function(v) CFG.aim.visCheck = v end,
    })
    gA:AddToggle("aimVisual", {
        Text = "Use visual model", Default = CFG.aim.useVisual,
        Tooltip = "Aim at the rendered model's head instead of the hitbox rig (SCP rigs are oversized)",
        Callback = function(v) CFG.aim.useVisual = v end,
    })
    gA:AddToggle("aimSticky", {
        Text = "Sticky aim", Default = CFG.aim.sticky,
        Tooltip = "Keep the same target instead of re-picking every frame",
        Callback = function(v) CFG.aim.sticky = v end,
    })
    gA:AddSlider("aimSnap", {
        Text = "Snap angle", Default = CFG.aim.snapDeg, Min = 0, Max = 5, Rounding = 1, Suffix = " deg",
        Tooltip = "Below this error the camera locks exactly on the head",
        Callback = function(v) CFG.aim.snapDeg = v end,
    })
    gA:AddSlider("aimScpOff", {
        Text = "SCP aim offset", Default = CFG.aim.scpOffsetY, Min = -4, Max = 1, Rounding = 2, Suffix = " studs",
        Tooltip = "SCP hitbox rig is taller than the model; negative pulls the aim down onto the visible body",
        Callback = function(v) CFG.aim.scpOffsetY = v end,
    })
    gA:AddSlider("aim999Off", {
        Text = "SCP-999 offset", Default = CFG.aim.scp999OffsetY, Min = -1.5, Max = 2, Rounding = 2, Suffix = " studs",
        Tooltip = "999 aims at its leg hitboxes (ground level) by default; raise this if it sits too low",
        Callback = function(v) CFG.aim.scp999OffsetY = v end,
    })
    gA:AddSlider("aimOffY", {
        Text = "Head offset", Default = CFG.aim.headOffset, Min = -1, Max = 1, Rounding = 2, Suffix = " studs",
        Tooltip = "Raise/lower the aim point if hitbox center is off",
        Callback = function(v) CFG.aim.headOffset = v end,
    })
    gA:AddToggle("aimMouse", {
        Text = "Mouse aim", Default = CFG.aim.mouseAim,
        Tooltip = "Drive the mouse (what the game actually reads when firing). Turn off only for debugging",
        Callback = function(v) CFG.aim.mouseAim = v end,
    })
    gA:AddSlider("aimPxGain", {
        Text = "Snap power", Default = CFG.aim.pxGain, Min = 0.1, Max = 1, Rounding = 2,
        Tooltip = "Fraction of the screen error eaten per frame. Lower = smoother",
        Callback = function(v) CFG.aim.pxGain = v end,
    })
    gA:AddToggle("aimCamWrite", {
        Text = "Camera write", Default = CFG.aim.cameraWrite,
        Tooltip = "Cosmetic only: the game recomputes the camera every frame",
        Callback = function(v) CFG.aim.cameraWrite = v end,
    })
    gA:AddToggle("aimFovShow", {
        Text = "Show FOV", Default = CFG.aim.showFov,
        Callback = function(v) CFG.aim.showFov = v end,
    })

    local gS = Tabs.Aim:AddRightGroupbox("Silent aim", "crosshair")
    gS:AddToggle("silOn", { Text = "Enable", Default = CFG.silent.on, Tooltip = "Rewrites GunAction direction, crosshair stays where you look", Callback = function(v) CFG.silent.on = v; if v and _G.HX_ENSURE_HOOK then pcall(_G.HX_ENSURE_HOOK) end end })
    gS:AddDropdown("silPart", { Text = "Hit part", Values = { "Auto", "Random", "Head", "Chest", "Stomach" }, Default = "Auto", Tooltip = "Random = roll Head/Chest by the head chance below", Callback = function(v) CFG.silent.part = tostring(v) end })
    gS:AddSlider("silHeadChance", { Text = "Head chance", Default = CFG.silent.headChance, Min = 0, Max = 100, Rounding = 0, Suffix = " %", Tooltip = "Only used when Hit part = Random", Callback = function(v) CFG.silent.headChance = v end })
    gS:AddDropdown("silScpPart", { Text = "SCP part", Values = { "Stomach", "Chest", "Head", "LeftLeg" }, Default = "Stomach", Callback = function(v) CFG.silent.scpPart = tostring(v) end })
    gS:AddSlider("silMaxAngle", { Text = "Max angle", Default = CFG.silent.maxAngle, Min = 1, Max = 45, Rounding = 1, Suffix = " deg", Tooltip = "Skip rewriting when the required turn is bigger than this", Callback = function(v) CFG.silent.maxAngle = v end })
    gS:AddSlider("silFov", { Text = "FOV", Default = CFG.silent.fov, Min = 1, Max = 90, Rounding = 1, Suffix = " deg", Callback = function(v) CFG.silent.fov = v end })
    gS:AddSlider("silScpOff", { Text = "SCP offset", Default = CFG.silent.scpOffsetY, Min = -4, Max = 1, Rounding = 2, Callback = function(v) CFG.silent.scpOffsetY = v end })
    gS:AddSlider("silDist", { Text = "Max distance", Default = CFG.silent.maxDist, Min = 50, Max = 1500, Rounding = 0, Suffix = " studs", Callback = function(v) CFG.silent.maxDist = v end })
    gS:AddToggle("silTeam", { Text = "Team check", Default = CFG.silent.teamCheck, Callback = function(v) CFG.silent.teamCheck = v end })
    gS:AddToggle("silVis", { Text = "Visible check", Default = CFG.silent.visCheck, Callback = function(v) CFG.silent.visCheck = v end })
    gS:AddToggle("silRewrite", { Text = "Rewrite shots", Default = CFG.silent.rewrite, Tooltip = "Off = read only (tracers still draw)", Callback = function(v) CFG.silent.rewrite = v end })
    gS:AddToggle("silBeams", { Text = "3D beam", Default = CFG.vis.beams, Tooltip = "Semi-transparent beam from the muzzle. Cyan = rewritten, warm white = original", Callback = function(v) CFG.vis.beams = v end })
    gS:AddToggle("silTracers", { Text = "2D line", Default = CFG.vis.tracers, Tooltip = "Flat screen-space line instead of a 3D beam", Callback = function(v) CFG.vis.tracers = v end })

    local gP = Tabs.Aim:AddRightGroupbox("Weapon", "crosshair")
    gP:AddToggle("spreadOn", {
        Text = "Zero spread", Default = CFG.spread.on,
        Tooltip = "Zeroes hipSpread / aimSpread / spreadPerShot in GunData so every bullet flies exactly on the crosshair",
        Callback = function(v) CFG.spread.on = v end,
    })
    gP:AddToggle("stamOn", {
        Text = "Infinite stamina", Default = CFG.stamina.on,
        Tooltip = "Stops the local stamina module from draining; sprint never runs out",
        Callback = function(v) CFG.stamina.on = v end,
    })
    gP:AddToggle("recOn", {
        Text = "No recoil", Default = CFG.recoil.on,
        Tooltip = "Replaces Controller.kickView with a no-op so the camera stops climbing",
        Callback = function(v) CFG.recoil.on = v end,
    })
    gP:AddSlider("aimHeadY", {
        Text = "Head Y offset", Default = CFG.aim.headOffsetY, Min = -1.5, Max = 0.5, Rounding = 2, Suffix = " studs",
        Tooltip = "Hitbox centre sits above the visible head; negative pulls the aim down. Calibrate at range.",
        Callback = function(v) CFG.aim.headOffsetY = v end,
    })
    gP:AddToggle("navOn", {
        Text = "Summon S-NAV", Default = CFG.nav.on,
        Tooltip = "Fills SNavCarried locally so the navigator opens without carrying the item",
        Callback = function(v) CFG.nav.on = v end,
    })
    gP:AddDropdown("navModel", {
        Text = "S-NAV model", Values = { "br_s_nav_ultimate", "br_s_nav_310", "br_s_nav_300" }, Default = CFG.nav.model,
        Callback = function(v) CFG.nav.model = tostring(v) end,
    })
    gP:AddToggle("phaseOn", {
        Text = "Phase doors", Default = CFG.phase.on,
        Tooltip = "Locally clears CanCollide on door parts nearby so you can walk through. Server sees nothing.",
        Callback = function(v) CFG.phase.on = v end,
    })
    gP:AddSlider("phaseR", {
        Text = "Phase radius", Default = CFG.phase.radius, Min = 4, Max = 30, Rounding = 0, Suffix = " studs",
        Callback = function(v) CFG.phase.radius = v end,
    })
    gP:AddToggle("ammoOn", {
        Text = "Ammo HUD", Default = CFG.ammo.on,
        Tooltip = "Mirrors the game's ammo readout as magazine / reserve above the crosshair",
        Callback = function(v) CFG.ammo.on = v end,
    })
    gP:AddToggle("trapOn", {
        Text = "Trap ESP", Default = CFG.traps.on,
        Tooltip = "Highlights claymore mines and tesla coils in RoundObjects with a box, label and distance",
        Callback = function(v) CFG.traps.on = v end,
    })
    gP:AddSlider("moveMul", {
        Text = "Speed multiplier", Default = CFG.move.speedMul, Min = 1, Max = 3, Rounding = 1, Suffix = "x",
        Tooltip = "Writes runSpeed / walkSpeed attributes; Controller re-syncs on AttributeChanged, so it applies instantly",
        Callback = function(v) CFG.move.speedMul = v end,
    })
    gP:AddToggle("moveDoors", {
        Text = "Pass doors", Default = CFG.move.passDoors,
        Tooltip = "Sets the PassDoors attribute locally so MovementTrace ignores locked doors",
        Callback = function(v) CFG.move.passDoors = v end,
    })
    gP:AddSlider("trapDist", {
        Text = "Trap range", Default = CFG.traps.maxDist, Min = 50, Max = 800, Rounding = 0, Suffix = " studs",
        Callback = function(v) CFG.traps.maxDist = v end,
    })
    gP:AddSlider("ammoX", {
        Text = "Ammo X", Default = CFG.ammo.x, Min = -600, Max = 600, Rounding = 0, Suffix = " px",
        Tooltip = "Horizontal offset from the bottom centre",
        Callback = function(v) CFG.ammo.x = v end,
    })
    gP:AddSlider("ammoY", {
        Text = "Ammo Y", Default = CFG.ammo.y, Min = -400, Max = 0, Rounding = 0, Suffix = " px",
        Tooltip = "Vertical offset from the bottom edge (negative = higher)",
        Callback = function(v) CFG.ammo.y = v end,
    })

    local gE = Tabs.Esp:AddLeftGroupbox("ESP", "box")
    gE:AddToggle("espOn", { Text = "Enable", Default = CFG.esp.on, Callback = function(v) CFG.esp.on = v end })
    gE:AddToggle("espBox", { Text = "Box", Default = CFG.esp.box, Callback = function(v) CFG.esp.box = v end })
    gE:AddToggle("espName", { Text = "Name", Default = CFG.esp.name, Callback = function(v) CFG.esp.name = v end })
    gE:AddToggle("espHp", { Text = "Health text", Default = CFG.esp.hp, Callback = function(v) CFG.esp.hp = v end })
    gE:AddToggle("espHpBar", { Text = "Health bar", Default = CFG.esp.hpBar, Callback = function(v) CFG.esp.hpBar = v end })
    gE:AddToggle("espVisual", { Text = "Visual box", Default = CFG.esp.useVisual, Tooltip = "Box follows the rendered model instead of the hitbox rig", Callback = function(v) CFG.esp.useVisual = v end })
    gE:AddToggle("espTr", { Text = "Tracer", Default = CFG.esp.tracer, Callback = function(v) CFG.esp.tracer = v end })
    gE:AddToggle("espTc", { Text = "Team colors", Default = CFG.esp.teamColor, Callback = function(v) CFG.esp.teamColor = v end })
    gE:AddToggle("espTt", { Text = "Team tag", Default = CFG.esp.teamTag, Callback = function(v) CFG.esp.teamTag = v end })
    gE:AddToggle("espEo", { Text = "Enemies only", Default = CFG.esp.enemiesOnly, Callback = function(v) CFG.esp.enemiesOnly = v end })
    gE:AddSlider("espDist", {
        Text = "Max distance", Default = CFG.esp.maxDist, Min = 50, Max = 2000, Rounding = 0, Suffix = " studs",
        Callback = function(v) CFG.esp.maxDist = v end,
    })
    gE:AddSlider("espHz", {
        Text = "Refresh", Default = CFG.esp.refreshHz, Min = 30, Max = 144, Rounding = 0, Suffix = " Hz",
        Callback = function(v) CFG.esp.refreshHz = v end,
    })

    local gI = Tabs.Info:AddLeftGroupbox("Status", "activity")
    gI:AddButton({
        Text = "Read my faction",
        Func = function()
            refreshSelf()
            if Library.Notify then
                Library:Notify("Team: " .. myTeam .. " / Role: " .. myRole, 4)
            end
        end,
    })
    gI:AddButton({
        Text = "Save config",
        Func = function()
            local ok = saveCfg()
            if Library.Notify then
                Library:Notify(ok and ("Saved to " .. CFG_FILE) or ("Save failed: " .. lastErr), 4)
            end
        end,
    })
    gI:AddButton({
        Text = "Reload config",
        Func = function()
            local ok, msg = loadCfg()
            if Library.Notify then Library:Notify(ok and ("Reloaded (" .. msg .. ")") or ("Reload failed: " .. msg), 4) end
        end,
    })
    gI:AddButton({
        Text = "Reset defaults",
        Func = function()
            resetCfg()
            saveCfg()
            if Library.Notify then Library:Notify("Defaults applied, reload the script to refresh the panel", 5) end
        end,
    })
    gI:AddButton({
        Text = "Unload",
        Func = function()
            if _G.HX_UNLOAD then _G.HX_UNLOAD() end
        end,
    })
end

-- =====================  卸载  =====================
_G.HX_UNLOAD = function()
    pcall(function() RunService:UnbindFromRenderStep("HX_AIM") end)
    pcall(function() renderConn:Disconnect() end)
    for i = 1, POOL do
        local s = slots[i]
        pcall(function() s.box:Remove() end)
        pcall(function() s.txt:Remove() end)
        pcall(function() s.hpbg:Remove() end)
        pcall(function() s.hpfill:Remove() end)
        pcall(function() s.hptxt:Remove() end)
        pcall(function() s.tr:Remove() end)
    end
    pcall(function() if UIGUI then UIGUI:Destroy() end end)
    pcall(function() fovCircle:Remove() end)
    pcall(function() fovText:Remove() end)
    if _G.__HX_AMMO_DRAW then
        pcall(function() _G.__HX_AMMO_DRAW:Remove() end)
        _G.__HX_AMMO_DRAW = nil
    end
    if _G.__HX_TRAP_DRAW then
        for i = 1, #_G.__HX_TRAP_DRAW do
            pcall(function() _G.__HX_TRAP_DRAW[i]:Remove() end)
        end
        _G.__HX_TRAP_DRAW = nil
    end
    _G.HX_UNLOAD = nil
    print("[HX] unloaded")
end

-- 自检：不动视角、不发包，只验证"取目标 -> 算方向 -> 改写方向表"这条链路
_G.HX_SILENT_TEST = function()
    local cam = workspace.CurrentCamera
    local origin = cam.CFrame.Position
    local before = Vector3.new(0, 0, -1)
    local tbl = { { before } }
    local d, t = silentDir(origin)
    if not d then
        return false, "no target (fov/team/trigger)", tostring(CFG.silent.on)
    end
    rewriteDirs(tbl, d)
    local after = tbl[1][1]
    return true, string.format("target=%s before=(%.2f,%.2f,%.2f) after=(%.2f,%.2f,%.2f)",
        t and t.name or "?", before.X, before.Y, before.Z, after.X, after.Y, after.Z)
end

_G.HX_SILENT_STAT = function()
    return silentHits, (SHOTS[#SHOTS] and SHOTS[#SHOTS].s) or false, #SHOTS
end

_G.HX_AIMPICK = function()
    local t, pos = pickTarget(CFG.aim, "aim")
    return (t and t.name or ""), (pos and 1 or 0), #targets
end

_G.HX_VIS = function()
    local n, withVis, sample = #VISLIST, 0, ""
    for i = 1, #targets do
        local t = targets[i]
        if t.vOff then
            withVis = withVis + 1
            if sample == "" then
                sample = string.format("%s dy=%.2f", t.name, t.vOff.Y)
            end
        end
    end
    return n, withVis, sample
end

_G.HX_DEBUG = function()
    return #targets, myTeam, myRole, lastFps
end

print("[HX] loaded | cfg=" .. CFG_FILE .. " | pool=" .. POOL .. " | Insert = panel | RMB = aim")
