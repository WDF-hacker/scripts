--[[
    HUSH Tank Radar v1.8  （方向标版）
    ==================================================================
    只读脚本：不碰 remote / 不改坐标 / 不改伤害 / 不装 hook / 不刷包。
    所有数据都是客户端已经同步给你的实例属性，等价于"把小地图读出来"。

    ── 坦克从哪来（已用代码验证）────────────────────────────────────
    全仓库所有载具生成标记的 types 字符串里，只有一处出现 Tank：
        ReplicatedStorage.HushCordonKit.CordonKitRareA:667
        arg40:mark("veh", 0, 0.1, -18,
                   { yaw = 0, kind = "yard", types = "Armored,Tank" })
    它位于 rare_motor_pool 站点构建函数 motorPool() 内部。
    其余全部是 Pickup / Sedan / Bus / Supercar / Kart。
    另一个带 veh 标记的稀有站点 rare_drive_in（CordonKitRareB:2451）
    用的是 types = "Sedan,Pickup"。
    => Tank / Armored 只可能来自 rare_motor_pool 这一个事件点。

    ── 事件怎么读（不需要看 UI）─────────────────────────────────────
    PlayerGui.HushHotspotIntel 是一个 ScreenGui，带属性：
        Title（如 "the base armory"）、X、Z、R（半径）、Rumour、RaidId
    PlayerGui.HushCordonSites 的 CordonSites 属性是稀有站点表，
        形如 "r,1121,172"（字母,x,z）。
    事件刷出时 Title 会变成 "a sealed army motor pool" 这类文案。

    ── 坦克怎么确认 ────────────────────────────────────────────────
    workspace.Raid.Vehicles 下每个载具 Model 带 VehType 属性，
    坦克 = VehType == "Tank"，装甲车 = "Armored"。

    ── 撤离点怎么读 ────────────────────────────────────────────────
    workspace.Raid.Extracts 下 IsA("BasePart") 的出口，属性：
        Kind（图标名：Road / Sewer / Gate / Boat / Heli / Vehicle）
        Name、ExtractId、State、Condition、Open
    公路检查点就是 Kind == "Road"（永远开放，开车撤离首选）。
    注意：客户端只持有已实例化的出口，未知出口没有坐标可读。

    热键：F7 坦克  F8 撤离点  F9 方向标  F10 状态面板
--]]

local NAME = "HUSH_TANK_RADAR"
local CFG_FILE = "hush_tank_cfg.txt"
local LOG_FILE = "hush_tank_radar.log"

local genv = (getgenv and getgenv()) or _G

--------------------------------------------------------------------------
-- 0. 单实例守卫
--------------------------------------------------------------------------
do
    local old = genv[NAME]
    if type(old) == "table" and type(old.dispose) == "function" then
        pcall(old.dispose)
        task.wait(0.1)
    end
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer

-- 实测：客户端实际流式半径只有 ~400-500 studs（StreamingTargetRadius=1024 是上限，
-- 不代表真的加载）。超出该范围的站点几何与载具都不会下发到客户端。
local STREAM_RANGE = 480

--------------------------------------------------------------------------
-- 1. 配置
--------------------------------------------------------------------------
local CFG = {
    render = true,   -- 总开关：关掉后本脚本不画任何东西（F2，方便截图）
    esp = true,      -- 坦克/装甲车透视
    exits = true,    -- 撤离点透视
    pointer = true,  -- 方向标
    site = true,     -- 事件点圈
    hud = true,      -- 状态面板
}

local CFG_KEYS = { "render", "esp", "exits", "pointer", "site", "hud" }

-- 数值配置（百分比，用于状态面板位置；0/0 也合法）
local NUM = { hudx = 1, hudy = 40 }
local NUM_KEYS = { "hudx", "hudy" }

local function readCfg()
    local ok, data = pcall(readfile, CFG_FILE)
    if not ok or type(data) ~= "string" then return end
    for line in string.gmatch(data, "[^\r\n]+") do
        if string.sub(line, 1, 1) ~= "#" then
            local k, v = string.match(line, "^(%w+)%s*=%s*([%d%.%-]+)$")
            if k then
                if CFG[k] ~= nil then
                    CFG[k] = (v == "1")
                elseif NUM[k] ~= nil then
                    local n = tonumber(v)
                    if n then NUM[k] = math.clamp(n, 0, 100) end
                end
            end
        end
    end
end

local function saveCfg()
    local L = { "# HUSH Tank Radar config (1=on 0=off; hudx/hudy = percent of screen)" }
    for _, k in ipairs(CFG_KEYS) do
        L[#L + 1] = string.format("%s=%d", k, CFG[k] and 1 or 0)
    end
    for _, k in ipairs(NUM_KEYS) do
        L[#L + 1] = string.format("%s=%d", k, math.floor(NUM[k] + 0.5))
    end
    pcall(writefile, CFG_FILE, table.concat(L, "\n"))
end

readCfg()

--------------------------------------------------------------------------
-- 2. 日志
--------------------------------------------------------------------------
local LOG = {}
local function log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    if not ok then s = tostring(fmt) end
    LOG[#LOG + 1] = "[" .. os.date("%H:%M:%S") .. "] " .. s
    while #LOG > 500 do table.remove(LOG, 1) end
end

local function flushLog()
    pcall(writefile, LOG_FILE, table.concat(LOG, "\n"))
end

--------------------------------------------------------------------------
-- 3. Drawing 池
--------------------------------------------------------------------------
local pool = {}
local drawOk = (type(Drawing) == "table" and type(Drawing.new) == "function")

local function mk(kind)
    if not drawOk then return nil end
    local ok, obj = pcall(Drawing.new, kind)
    if ok and obj then return obj end
    return nil
end

local function get(kind)
    local list = pool[kind]
    if not list then
        list = {}
        pool[kind] = list
    end
    for i = 1, #list do
        if not list[i].used then
            list[i].used = true
            return list[i].obj
        end
    end
    local obj = mk(kind)
    if not obj then return nil end
    list[#list + 1] = { obj = obj, used = true }
    return obj
end

local function releaseAll()
    for _, list in pairs(pool) do
        for i = 1, #list do
            list[i].used = false
            pcall(function() list[i].obj.Visible = false end)
        end
    end
end

local function removeAll()
    for _, list in pairs(pool) do
        for i = 1, #list do
            pcall(function() list[i].obj:Remove() end)
        end
    end
    pool = {}
end

local FONT = 2
if drawOk and type(Drawing.Fonts) == "table" and Drawing.Fonts.Monospace then
    FONT = Drawing.Fonts.Monospace
end

local C = {
    tank = Color3.fromRGB(255, 62, 62),
    armor = Color3.fromRGB(255, 165, 60),
    road = Color3.fromRGB(80, 255, 140),
    exit = Color3.fromRGB(120, 190, 255),
    site = Color3.fromRGB(255, 210, 60),
    panel = Color3.fromRGB(235, 240, 248),
    dim = Color3.fromRGB(150, 160, 175),
    shadow = Color3.fromRGB(0, 0, 0),
}

--------------------------------------------------------------------------
-- 4. 工具
--------------------------------------------------------------------------
local VW, VH = 0, 0

local function wrap180(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

-- 相机偏航：用 RightVector 求，RightVector 永远是水平的，
-- 所以 E/Q 把视角上下俯仰到接近垂直时也不会失效。
-- 约定：yaw 0 = 面向 -Z（北），顺时针为正。
local function camYaw(cam)
    local r = cam.CFrame.RightVector
    return math.deg(math.atan2(r.Z, r.X))
end

-- 目标相对玩家的方位角（与 camYaw 同一约定）
local function bearingTo(dx, dz)
    return math.deg(math.atan2(dx, -dz))
end

local function fmtDist(n)
    if not n then return "?" end
    if n >= 1000 then return string.format("%.2fkm", n / 1000) end
    return string.format("%dm", math.floor(n + 0.5))
end

local function cleanStr(s, max)
    s = tostring(s or "")
    s = s:gsub("[%z\1-\31\127-\255]", "?")
    if max and #s > max then s = string.sub(s, 1, max) end
    return s
end

local function w2s(cam, p)
    local ok, sp = pcall(function() return cam:WorldToViewportPoint(p) end)
    if not ok or not sp then return nil, false end
    if sp.Z <= 0 then return nil, false end
    return Vector2.new(sp.X, sp.Y), (sp.X >= 0 and sp.Y >= 0 and sp.X <= VW and sp.Y <= VH)
end

local function charPos()
    local ch = LP.Character
    if not ch then return nil end
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then return hrp.Position end
    return nil
end

--------------------------------------------------------------------------
-- 5. 扫描
--------------------------------------------------------------------------
local S = {
    tanks = {},
    armor = {},
    allVeh = 0,
    exits = {},
    site = nil,
    sites = {},
    knownIds = {},
    raid = nil,
    siteParts = nil,
    exitSize = nil,
    mapRaid = nil,
    mapHalf = nil,
    tTank = 0, tExit = 0, tIntel = 0, tBuilt = 0,
    seen = false,
    alert = nil,
    rendered = true,
}

local function raidRoot()
    return workspace:FindFirstChild("Raid")
end

local function vehRec(m)
    local okp, piv = pcall(function() return m:GetPivot() end)
    if not okp or not piv then return nil end
    return {
        model = m,
        kind = tostring(m:GetAttribute("VehType") or "?"),
        variant = cleanStr(m:GetAttribute("VehVariant"), 24),
        pos = piv.Position,
        hp = tonumber(m:GetAttribute("Hp")) or 0,
        hpMax = tonumber(m:GetAttribute("HpMax")) or 0,
        seats = tonumber(m:GetAttribute("SeatsTaken")) or 0,
        fuel = tonumber(m:GetAttribute("Fuel")) or 0,
        state = cleanStr(m:GetAttribute("State"), 16),
    }
end

local function scanVeh()
    local tanks, armor = {}, {}
    local n = 0
    local raid = raidRoot()
    local vh = raid and raid:FindFirstChild("Vehicles")
    if vh then
        for _, m in ipairs(vh:GetChildren()) do
            n = n + 1
            local vt = m:GetAttribute("VehType")
            if vt == "Tank" then
                local r = vehRec(m)
                if r then tanks[#tanks + 1] = r end
            elseif vt == "Armored" then
                local r = vehRec(m)
                if r then armor[#armor + 1] = r end
            end
        end
    end
    S.tanks = tanks
    S.armor = armor
    S.allVeh = n

    if #tanks > 0 and not S.seen then
        S.seen = true
        S.alert = { text = "TANK SPAWNED", at = os.clock() }
        local t0 = tanks[1]
        log("TANK 出现 variant=%s pos=%.0f,%.0f,%.0f hp=%d/%d fuel=%d%%",
            t0.variant, t0.pos.X, t0.pos.Y, t0.pos.Z, t0.hp, t0.hpMax,
            math.floor(t0.fuel * 100 + 0.5))
        flushLog()
    elseif #tanks == 0 and S.seen then
        S.seen = false
        log("TANK 消失")
        flushLog()
    end
end

local function decodeKnown()
    local set = {}
    local attr = LP:GetAttribute("CordonKnown")
    if type(attr) == "string" then
        for id in string.gmatch(attr, "[^;]+") do set[id] = true end
    end
    return set
end

-- 撤离点权威源：ReplicatedStorage.HushRuntime.Raid.Extracts 里有**全部**出口的坐标，
-- 不受流式影响；workspace.Raid.Extracts 只有已流式进来的那几个，作为补充。
local function extractFolders()
    local list = {}
    local rt = RS:FindFirstChild("HushRuntime")
    local rr = rt and rt:FindFirstChild("Raid")
    local a = rr and rr:FindFirstChild("Extracts")
    if a then list[#list + 1] = a end
    local raid = workspace:FindFirstChild("Raid")
    local b = raid and raid:FindFirstChild("Extracts")
    if b then list[#list + 1] = b end
    return list
end

local function scanExits()
    local byId = {}
    local known = decodeKnown()
    S.knownIds = known

    for _, folder in ipairs(extractFolders()) do
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("BasePart") and child:GetAttribute("Personal") ~= true then
                local id = tostring(child:GetAttribute("ExtractId") or child.Name)
                if byId[id] == nil then
                    byId[id] = {
                        id = id,
                        kind = cleanStr(child:GetAttribute("Kind"), 16),
                        name = cleanStr(child:GetAttribute("Name"), 40),
                        state = cleanStr(child:GetAttribute("State"), 16),
                        cond = cleanStr(child:GetAttribute("Condition"), 60),
                        open = child:GetAttribute("Open") == true,
                        known = known[id] == true,
                        seats = tonumber(child:GetAttribute("Seats")) or 0,
                        pos = child.Position,
                    }
                end
            end
        end
    end

    -- 个人撤离点
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    local pe = pg and pg:FindFirstChild("HushPersonalExtracts")
    if pe then
        for _, child in ipairs(pe:GetChildren()) do
            if child:IsA("BasePart") then
                local id = "P_" .. tostring(child.Name)
                byId[id] = {
                    id = id,
                    kind = cleanStr(child:GetAttribute("Kind"), 16),
                    name = "MY " .. cleanStr(child:GetAttribute("Name") or child.Name, 30),
                    state = cleanStr(child:GetAttribute("State"), 16),
                    cond = cleanStr(child:GetAttribute("Condition"), 60),
                    open = child:GetAttribute("Open") == true,
                    known = true,
                    seats = 0,
                    pos = child.Position,
                }
            end
        end
    end

    local out = {}
    for _, e in pairs(byId) do out[#out + 1] = e end
    table.sort(out, function(a, b)
        if (a.kind == "Road") ~= (b.kind == "Road") then return a.kind == "Road" end
        return a.name < b.name
    end)
    S.exits = out
end

-- 对局元信息：难度 / 阶段 / 剩余时间，以及 MapInfo 里的出口真实尺寸
local function scanRaidInfo()
    local rt = RS:FindFirstChild("HushRuntime")
    local rr = rt and rt:FindFirstChild("Raid")
    if not rr then
        S.raid = nil
        return
    end
    local endsAt = tonumber(rr:GetAttribute("EndsAt"))
    local remain = nil
    if endsAt then
        local ok, now = pcall(function() return workspace:GetServerTimeNow() end)
        if ok and type(now) == "number" then remain = endsAt - now end
    end
    S.raid = {
        map = cleanStr(rr:GetAttribute("Map"), 24),
        difficulty = cleanStr(rr:GetAttribute("Difficulty"), 16),
        phase = cleanStr(rr:GetAttribute("Phase"), 16),
        remains = remain,
    }

    -- MapInfo: 每局一个 JSON，含全部出口的 cf 与 size，比实例更稳
    local rid = cleanStr(rr:GetAttribute("RaidId"), 40)
    if rid ~= "" and rid ~= S.mapRaid then
        S.mapRaid = rid
        S.exitSize = {}
        local mi = rt and rt:FindFirstChild("MapInfo")
        if mi and type(mi.Value) == "string" and #mi.Value > 0 then
            local okj, tbl = pcall(function()
                return game:GetService("HttpService"):JSONDecode(mi.Value)
            end)
            if okj and type(tbl) == "table" then
                S.mapHalf = tonumber(tbl.half)
                for _, e in ipairs(tbl.extracts or {}) do
                    if type(e) == "table" and type(e.id) == "string" and type(e.size) == "table" then
                        S.exitSize[e.id] = Vector3.new(tonumber(e.size[1]) or 12,
                            tonumber(e.size[2]) or 8, tonumber(e.size[3]) or 12)
                    end
                end
                log("MapInfo 解析: 出口%d 半长%s", #(tbl.extracts or {}), tostring(S.mapHalf))
            else
                log("MapInfo 解析失败: %s", tostring(tbl))
            end
        end
    end
end

-- 只有"军械库车队"类文案算坦克事件；the base armory 这类普通站点不参与
local EVENT_WORDS = { "motor pool", "motorpool", "motor-pool", "tank" }

local function eventHit(title)
    if type(title) ~= "string" then return nil end
    local low = string.lower(title)
    for _, w in ipairs(EVENT_WORDS) do
        if string.find(low, w, 1, true) then return w end
    end
    return nil
end

local function scanIntel()
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    local site = nil
    local hs = pg and pg:FindFirstChild("HushHotspotIntel")
    if hs then
        local title = hs:GetAttribute("Title")
        local x, z = hs:GetAttribute("X"), hs:GetAttribute("Z")
        if type(title) == "string" and type(x) == "number" and type(z) == "number" then
            site = {
                title = cleanStr(title, 60),
                pos = Vector3.new(x, 0, z),
                r = tonumber(hs:GetAttribute("R")) or 20,
                rumour = hs:GetAttribute("Rumour") == true,
                hit = eventHit(title),
            }
        end
    end
    S.site = site

    local sites = {}
    local cs = pg and pg:FindFirstChild("HushCordonSites")
    if cs then
        local raw = cs:GetAttribute("CordonSites")
        if type(raw) == "string" and #raw > 0 then
            local flat = {}
            for tok in string.gmatch(raw, "[^,;%s]+") do flat[#flat + 1] = tok end
            local i = 1
            while i + 2 <= #flat do
                local code = tostring(flat[i])
                local x = tonumber(flat[i + 1])
                local z = tonumber(flat[i + 2])
                if #code == 1 and x and z then
                    sites[#sites + 1] = { code = code, pos = Vector3.new(x, 0, z) }
                    i = i + 3
                else
                    i = i + 1
                end
            end
        end
    end
    S.sites = sites
end

--------------------------------------------------------------------------
-- 6. 绘制
--------------------------------------------------------------------------
local function txt(s, size, col, x, y, center)
    local t = get("Text")
    if not t then return end
    t.Text = s
    t.Size = size
    t.Center = center ~= false
    t.Outline = true
    t.OutlineColor = C.shadow
    t.Color = col
    t.Font = FONT
    t.Position = Vector2.new(x, y)
    t.Visible = true
end

local function box3d(cam, center, sizev, color, label, sub, dist)
    local sp = w2s(cam, center)
    if not sp then return end
    local top = w2s(cam, center + Vector3.new(0, sizev.Y * 0.5, 0))
    local bot = w2s(cam, center - Vector3.new(0, sizev.Y * 0.5, 0))
    if not top or not bot then return end
    local h = math.abs(bot.Y - top.Y)
    if h < 5 then h = 5 end
    if h > VH then h = VH end
    local w = math.clamp(h * (sizev.X / math.max(sizev.Y, 0.5)), 12, 520)
    local y = (top.Y + bot.Y) * 0.5 - h * 0.5

    local sq = get("Square")
    if sq then
        sq.Size = Vector2.new(w, h)
        sq.Position = Vector2.new(sp.X - w * 0.5, y)
        sq.Color = color
        sq.Thickness = 1.6
        sq.Filled = false
        sq.Visible = true
    end

    if dist then txt(dist, 12, C.dim, sp.X, y - 32) end
    if label then txt(label, 13, color, sp.X, y - 17) end
    if sub then txt(sub, 12, C.panel, sp.X, y + h + 2) end
end

local RING_STEPS = 20
local function ring(cam, center, radius, color, label)
    local prev = nil
    for i = 0, RING_STEPS do
        local a = (i / RING_STEPS) * math.pi * 2
        local p = Vector3.new(center.X + math.cos(a) * radius, center.Y, center.Z + math.sin(a) * radius)
        local sp = w2s(cam, p)
        if prev and sp then
            local ln = get("Line")
            if ln then
                ln.From = prev
                ln.To = sp
                ln.Color = color
                ln.Thickness = 1
                ln.Transparency = 0.3
                ln.Visible = true
            end
        end
        prev = sp
    end
    local cp = w2s(cam, center)
    if cp then
        local sq = get("Square")
        if sq then
            sq.Size = Vector2.new(11, 11)
            sq.Position = Vector2.new(cp.X - 5, cp.Y - 5)
            sq.Color = color
            sq.Thickness = 2
            sq.Filled = false
            sq.Visible = true
        end
        if label then txt(label, 13, color, cp.X, cp.Y - 30) end
    end
end

-- 方向标：箭头绕准星一圈，指向目标方位；带名称与距离
local POINTER_R = 0.24      -- 基准半径 = min(视口) * 该系数
local POINTER_STEP = 26     -- 多个目标时向外错开的间距
local POINTER_MAX = 6       -- 坦克 + 2 公路 + 事件点 恒显，剩 2 个给其他出口

local function drawPointer(cam, pos, color, label, dist, radius)
    local mypos = charPos()
    if not mypos then return end
    local rel = wrap180(bearingTo(pos.X - mypos.X, pos.Z - mypos.Z) - camYaw(cam))
    local a = math.rad(rel)
    local dir = Vector2.new(math.sin(a), -math.cos(a))
    local nrm = Vector2.new(-dir.Y, dir.X)
    local p = Vector2.new(VW * 0.5 + dir.X * radius, VH * 0.5 + dir.Y * radius)

    local tri = get("Triangle")
    if tri then
        tri.PointA = p + dir * 14
        tri.PointB = p - dir * 9 + nrm * 9
        tri.PointC = p - dir * 9 - nrm * 9
        tri.Color = color
        tri.Filled = true
        tri.Visible = true
    end

    -- 一条短引线，帮助肉眼定位箭头
    local ln = get("Line")
    if ln then
        ln.From = p - dir * 20
        ln.To = p - dir * 11
        ln.Color = color
        ln.Thickness = 2
        ln.Transparency = 0.2
        ln.Visible = true
    end

    txt(label, 12, color, p.X, p.Y + 12)
    if dist then txt(dist, 11, C.panel, p.X, p.Y + 25) end
end

local PCOLOR = { "tank", "armor", "road", "site", "exit" }

local function drawPointers(cam, list)
    if not CFG.pointer then return end
    local base = math.min(VW, VH) * POINTER_R
    for i = 1, math.min(#list, POINTER_MAX) do
        local m = list[i]
        drawPointer(cam, m.pos, m.color, m.text, m.dist, base + (i - 1) * POINTER_STEP)
    end
end

local function hud(lines)
    local x = math.floor(VW * NUM.hudx / 100 + 0.5)
    local y = math.floor(VH * NUM.hudy / 100 + 0.5)
    for i, line in ipairs(lines) do
        txt(line.text, line.size or 13, line.color or C.panel, x, y + (i - 1) * 16, false)
    end
end

--------------------------------------------------------------------------
-- 7. 主循环
--------------------------------------------------------------------------
local disposed = false
local conns = {}

local function step()
    if disposed then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    local now = os.clock()
    if now - S.tTank > 0.2 then
        S.tTank = now
        local ok, err = pcall(scanVeh)
        if not ok then log("scanVeh: %s", tostring(err)) end
    end
    if now - S.tExit > 0.5 then
        S.tExit = now
        local ok, err = pcall(scanExits)
        if not ok then log("scanExits: %s", tostring(err)) end
    end
    if now - S.tIntel > 0.3 then
        S.tIntel = now
        local ok, err = pcall(scanIntel)
        if not ok then log("scanIntel: %s", tostring(err)) end
        local ok2, err2 = pcall(scanRaidInfo)
        if not ok2 then log("scanRaidInfo: %s", tostring(err2)) end
    end

    -- 站点结构确认：在流式范围内数一下站点周围零件。
    -- 有结构 = "没坦克"才是可信结论；没结构 = 只是还没加载，不能下结论。
    if now - S.tBuilt > 2 then
        S.tBuilt = now
        local st = S.site
        local mp = charPos()
        if st and mp and (st.pos - mp).Magnitude <= (STREAM_RANGE + 120) then
            local p = Vector3.new(st.pos.X, st.pos.Y + 30, st.pos.Z)
            local okb, parts = pcall(function()
                return workspace:GetPartBoundsInBox(CFrame.new(p), Vector3.new(220, 160, 220))
            end)
            S.siteParts = (okb and type(parts) == "table") and #parts or -1
        else
            S.siteParts = nil
        end
    end

    -- F2 总开关：关掉后一帧都不画（数据扫描仍在跑，随时开回来就是实时的）
    if not CFG.render then
        if S.rendered then
            releaseAll()
            S.rendered = false
        end
        return
    end
    releaseAll()
    S.rendered = true

    local vp = cam.ViewportSize
    VW, VH = vp.X, vp.Y

    local mypos = charPos()
    local site = S.site
    -- 方向标按优先级分桶，最后拼接：坦克 > 公路撤离点 > 事件点 > 其他撤离点
    local ptrTank, ptrRoad, ptrSite, ptrOther = {}, {}, {}, {}

    -- 测试假目标（只在内存里，不创建实例）
    local tanksDraw = S.tanks
    if S.fake and os.clock() < S.fake.expire and mypos then
        local lv = cam.CFrame.LookVector
        local fwd = Vector3.new(lv.X, 0, lv.Z)
        if fwd.Magnitude > 0.01 then fwd = fwd.Unit else fwd = Vector3.new(0, 0, -1) end
        tanksDraw = {
            { model = nil, kind = "Tank", variant = "TEST", pos = mypos + fwd * 55,
              hp = 3000, hpMax = 3150, seats = 0, fuel = 0.8, state = "ok" },
        }
    end

    -- 坦克
    for _, tk in ipairs(tanksDraw) do
        local okb, cf, sz = pcall(function() return tk.model:GetBoundingBox() end)
        local center = tk.pos
        local sizev = Vector3.new(9, 9, 9)
        if okb and cf and sz then
            center = cf.Position
            sizev = sz
        end
        local d = mypos and (center - mypos).Magnitude or nil
        local label = "TANK"
        if tk.variant ~= "" then label = label .. " " .. tk.variant end
        if CFG.esp then
            box3d(cam, center, sizev, C.tank, label,
                string.format("HP %d/%d  seats %d  fuel %d%%", tk.hp, tk.hpMax, tk.seats,
                    math.floor(tk.fuel * 100 + 0.5)), fmtDist(d))
        end
        ptrTank[#ptrTank + 1] = { pos = center, color = C.tank, text = "TANK", dist = fmtDist(d) }
    end

    -- 装甲车（只在事件点附近提示，避免满屏 PARKING 车噪音）
    for _, av in ipairs(S.armor) do
        local near = false
        if site and site.hit then
            near = (Vector3.new(site.pos.X, 0, site.pos.Z) - Vector3.new(av.pos.X, 0, av.pos.Z)).Magnitude
                <= (site.r + 80)
        end
        if near then
            local d = mypos and (av.pos - mypos).Magnitude or nil
            if CFG.esp then
                box3d(cam, av.pos + Vector3.new(0, 5, 0), Vector3.new(14, 12, 14), C.armor,
                    "ARMOR " .. av.variant, string.format("HP %d/%d", av.hp, av.hpMax), fmtDist(d))
            end
            ptrTank[#ptrTank + 1] = { pos = av.pos, color = C.armor, text = "ARMOR", dist = fmtDist(d) }
        end
    end

    -- 撤离点
    local roadPtr = {}
    if CFG.exits then
        for _, e in ipairs(S.exits) do
            local d = mypos and (e.pos - mypos).Magnitude or nil
            local isRoad = (e.kind == "Road")
            local color = isRoad and C.road or C.exit
            local openTxt = e.open and "OPEN" or "CLOSED"
            local sz = (S.exitSize and S.exitSize[e.id]) or nil
            if isRoad then
                ring(cam, Vector3.new(e.pos.X, e.pos.Y, e.pos.Z), 24, color, nil)
                local hs2 = sz and (sz.Y * 2.2) or 16
                local hs1 = sz and (math.max(sz.X, sz.Z) * 0.9) or 26
                box3d(cam, e.pos + Vector3.new(0, hs2 * 0.4, 0), Vector3.new(hs1, hs2, hs1), color,
                    "[ROAD] " .. e.name, openTxt .. " | " .. e.kind, fmtDist(d))
            else
                box3d(cam, e.pos + Vector3.new(0, 4, 0), Vector3.new(12, 10, 12), color,
                    e.name, openTxt .. " | " .. e.kind, fmtDist(d))
            end
            if not e.open and e.cond ~= "" then
                local sp = w2s(cam, e.pos + Vector3.new(0, 12, 0))
                if sp then txt("[" .. e.state .. "] " .. e.cond, 11, C.dim, sp.X, sp.Y + 16) end
            end
            local rec = {
                pos = e.pos, color = color,
                text = (isRoad and "ROAD" or e.kind),
                dist = fmtDist(d),
            }
            if isRoad then roadPtr[#roadPtr + 1] = rec else ptrOther[#ptrOther + 1] = rec end
        end
    end
    for _, r in ipairs(roadPtr) do ptrRoad[#ptrRoad + 1] = r end

    -- 事件点
    if CFG.site and site and mypos then
        local d = (site.pos - mypos).Magnitude
        local color = site.hit and C.tank or C.site
        ring(cam, Vector3.new(site.pos.X, 0, site.pos.Z), site.r, color,
            site.title .. (site.hit and "   << TANK EVENT" or ""))
        local sp = w2s(cam, site.pos + Vector3.new(0, 8, 0))
        if sp then
            txt(fmtDist(d) .. (site.rumour and " . rumour" or ""), 12, C.panel, sp.X, sp.Y + 44)
        end
        ptrSite[#ptrSite + 1] = { pos = site.pos, color = color, text = "EVENT", dist = fmtDist(d) }
    end

    local ptr = {}
    for _, list in ipairs({ ptrTank, ptrRoad, ptrSite, ptrOther }) do
        for _, m in ipairs(list) do ptr[#ptr + 1] = m end
    end

    drawPointers(cam, ptr)

    -- 状态面板
    if CFG.hud then
        local lines = {}
        lines[#lines + 1] = { text = "-- HUSH Tank Radar v1.8 --", color = C.dim }

        if #S.tanks > 0 then
            local t1 = S.tanks[1]
            local d = mypos and (t1.pos - mypos).Magnitude or nil
            lines[#lines + 1] = {
                text = string.format("TANK %d  %s  %s", #S.tanks, t1.variant, fmtDist(d)),
                color = C.tank, size = 14,
            }
            lines[#lines + 1] = {
                text = string.format("  HP %d/%d fuel %d%% %s", t1.hp, t1.hpMax,
                    math.floor(t1.fuel * 100 + 0.5), t1.state),
                color = C.panel,
            }
        else
            local hint = "no motor pool this raid"
            if site and site.hit and mypos then
                local d = (site.pos - mypos).Magnitude
                if d > STREAM_RANGE then
                    hint = string.format("site %s away, out of stream range", fmtDist(d))
                else
                    hint = "on site, none this raid"
                end
            end
            lines[#lines + 1] = { text = "TANK 0  (" .. hint .. ")", color = C.dim }
        end

        if site then
            local d = mypos and (site.pos - mypos).Magnitude or nil
            lines[#lines + 1] = {
                text = string.format("EVENT %s  r=%d  %s", site.title, math.floor(site.r + 0.5),
                    site.hit and "<< TANK EVENT" or ""),
                color = site.hit and C.tank or C.site,
            }
            if d then
                lines[#lines + 1] = {
                    text = string.format("  %s from you%s", fmtDist(d),
                        d > STREAM_RANGE and "  (beyond stream)" or ""),
                    color = d > STREAM_RANGE and C.dim or C.panel,
                }
            end
            local sp2 = S.siteParts
            if sp2 == nil then
                lines[#lines + 1] = { text = "  SITE not streamed - cannot confirm", color = C.dim }
            elseif sp2 > 50 then
                lines[#lines + 1] = {
                    text = string.format("  SITE built (%dp) - confirmed no tank", sp2),
                    color = C.panel,
                }
            else
                lines[#lines + 1] = {
                    text = string.format("  SITE empty (%dp) - site not spawned", sp2),
                    color = C.site,
                }
            end
        else
            lines[#lines + 1] = { text = "EVENT none", color = C.dim }
        end

        local roadN, openN, closedN, knownN = 0, 0, 0, 0
        for _, e in ipairs(S.exits) do
            if e.kind == "Road" then roadN = roadN + 1 end
            if e.open then openN = openN + 1 else closedN = closedN + 1 end
            if e.known then knownN = knownN + 1 end
        end
        lines[#lines + 1] = {
            text = string.format("EXIT %d  open %d  closed %d  road %d  known %d",
                #S.exits, openN, closedN, roadN, knownN),
            color = C.road,
        }

        -- 最近的可开车撤离点（开车撤离看这一行）
        if mypos then
            local best, bestD = nil, math.huge
            for _, e in ipairs(S.exits) do
                if e.kind == "Road" and e.open then
                    local dd = (e.pos - mypos).Magnitude
                    if dd < bestD then best, bestD = e, dd end
                end
            end
            if best then
                lines[#lines + 1] = {
                    text = string.format("DRIVE > %s  %s", best.name, fmtDist(bestD)),
                    color = C.road,
                }
            end
        end

        local ri = S.raid
        if ri then
            local clock = ""
            if ri.remains and ri.remains > 0 then
                local m = math.floor(ri.remains / 60)
                local s = math.floor(ri.remains % 60)
                clock = string.format("  %d:%02d", m, s)
            end
            lines[#lines + 1] = {
                text = ri.map .. "  " .. string.upper(ri.difficulty) .. "  " .. ri.phase .. clock,
                color = C.dim,
            }
        end

        lines[#lines + 1] = {
            text = string.format("veh %d  sites %d   F2 hide all | F5 F6 F7 F8", S.allVeh, #S.sites),
            color = C.dim,
        }

        if S.alert and os.clock() - S.alert.at < 12 then
            lines[#lines + 1] = { text = "!! " .. S.alert.text .. " !!", color = C.tank, size = 15 }
        end
        hud(lines)
    end
end

conns[#conns + 1] = RunService.RenderStepped:Connect(function()
    if disposed then return end
    local ok, err = pcall(step)
    if not ok then
        log("step: %s", tostring(err))
        flushLog()
    end
end)

--------------------------------------------------------------------------
-- 8. 热键
--------------------------------------------------------------------------
local function toggle(k)
    CFG[k] = not CFG[k]
    saveCfg()
    log("切换 %s=%s", k, tostring(CFG[k]))
    flushLog()
end

-- 键位：避开 Roblox 自己的 F9（开发者控制台）、F11（全屏）
--   F2 总开关（截图用）  F5 面板  F6 方向标  F7 坦克  F8 撤离点
conns[#conns + 1] = UIS.InputBegan:Connect(function(input, processed)
    if processed then return end
    local k = input.KeyCode
    if k == Enum.KeyCode.F2 then
        toggle("render")
    elseif k == Enum.KeyCode.F5 then
        toggle("hud")
    elseif k == Enum.KeyCode.F6 then
        toggle("pointer")
    elseif k == Enum.KeyCode.F7 then
        toggle("esp")
    elseif k == Enum.KeyCode.F8 then
        toggle("exits")
    end
end)

--------------------------------------------------------------------------
-- 9. API / dispose
--------------------------------------------------------------------------
local API

local function dispose()
    if disposed then return end
    disposed = true
    for i = 1, #conns do
        pcall(function() conns[i]:Disconnect() end)
    end
    conns = {}
    removeAll()
    flushLog()
    if genv[NAME] == API then
        genv[NAME] = nil
    end
end

API = {
    version = "1.8",
    dispose = dispose,
    cfg = CFG,
    num = NUM,
    state = S,
    saveCfg = saveCfg,
    -- 总开关（等价于按 F2）
    toggleRender = function(v)
        if type(v) == "boolean" then
            CFG.render = v
        else
            CFG.render = not CFG.render
        end
        saveCfg()
        log("render=%s", tostring(CFG.render))
        return CFG.render
    end,
    -- 当前可见的绘制对象数量（自检用；render 关闭后应为 0）
    visibleCount = function()
        local n = 0
        for _, list in pairs(pool) do
            for i = 1, #list do
                local ok, v = pcall(function() return list[i].obj.Visible end)
                if ok and v then n = n + 1 end
            end
        end
        return n
    end,
    rescan = function()
        pcall(scanVeh)
        pcall(scanExits)
        pcall(scanIntel)
        pcall(scanRaidInfo)
        local roadN = 0
        for _, e in ipairs(S.exits) do
            if e.kind == "Road" then roadN = roadN + 1 end
        end
        return {
            tanks = #S.tanks, armor = #S.armor, exits = #S.exits, road = roadN,
            site = S.site and S.site.title or nil,
            siteHit = S.site and S.site.hit or nil,
            sitePos = S.site and string.format("%.0f,%.0f", S.site.pos.X, S.site.pos.Z) or nil,
            veh = S.allVeh, sites = #S.sites,
            difficulty = S.raid and S.raid.difficulty or nil,
            remains = S.raid and S.raid.remains and math.floor(S.raid.remains + 0.5) or nil,
        }
    end,
    exitsList = function()
        local t = {}
        for _, e in ipairs(S.exits) do
            t[#t + 1] = {
                id = e.id, kind = e.kind, name = e.name,
                x = math.floor(e.pos.X + 0.5), y = math.floor(e.pos.Y + 0.5), z = math.floor(e.pos.Z + 0.5),
                open = e.open, known = e.known, seats = e.seats,
            }
        end
        return t
    end,
    flush = flushLog,
    logFile = LOG_FILE,
    -- 调试：内存里注入假坦克验证渲染，不创建/修改任何实例
    testTank = function(seconds)
        S.fake = { expire = os.clock() + (tonumber(seconds) or 15) }
        log("测试假目标 %s 秒", tostring(seconds or 15))
        return true
    end,
    clearTest = function()
        S.fake = nil
        return true
    end,
    -- 自检：分别朝"相机右侧 / 正前方 / 正后方"取方位，应当得到 +90 / 0 / ±180
    dirTest = function()
        local cam = workspace.CurrentCamera
        if not cam then return nil end
        local r = cam.CFrame.RightVector
        local lv = cam.CFrame.LookVector
        local y = camYaw(cam)
        local rightRel = wrap180(bearingTo(r.X, r.Z) - y)
        local fwdRel = wrap180(bearingTo(lv.X, lv.Z) - y)
        local backRel = wrap180(bearingTo(-lv.X, -lv.Z) - y)
        return {
            camYaw = y,
            right = rightRel,      -- 期望 +90
            forward = fwdRel,      -- 期望 0
            back = backRel,        -- 期望 ±180
            rightArrowX = math.sin(math.rad(rightRel)),  -- 期望 +1
            pitch = math.deg(math.asin(math.clamp(lv.Y, -1, 1))),
        }
    end,
}
genv[NAME] = API

pcall(scanVeh)
pcall(scanExits)
pcall(scanIntel)
log("加载完成 v1.8 坦克=%d 装甲=%d 出口=%d 事件=%s 命中=%s 载具=%d",
    #S.tanks, #S.armor, #S.exits, S.site and S.site.title or "无",
    tostring(S.site and S.site.hit), S.allVeh)
flushLog()

return API
