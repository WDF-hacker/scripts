--[[
================================================================================
  HW Mutator  v10   --  万圣节 (Hallows' Eve) 自动手持突变 + 快捷栏管理
  Place 74729868188364  (钓一条动漫随机鱼)      UI: Obsidian (deividcomsono)
--------------------------------------------------------------------------------
  突变机制（实测验证）
    * 事件: Remotes.TypeEventState 每秒推 {kind, eventName="Halloween", remaining}
            Remotes.GetTypeEventState:InvokeServer() 取全量状态
            显示名 "Hallows' Eve"，内部名 "Halloween"（判定用后者）
    * 判定: 活动期间"手持(拿在手上)且无突变(clean)"的角色，每秒独立 roll
              Dracula 1/2000    Demonic 1/100000    （Halloween 仅此两种）
    * 手持: Remotes.BackpackHoldCharacter:FireServer("C|<名>|<突变>|L<等级>")
            放手: :FireServer("")        （服务器权威，与 UI 蓝框无关）
    * 背包: Remotes.BackpackCharSummaryGet:InvokeServer()
            key="C|<名>|<突变...>|L<等级>"  value={ra=品质, ty=突变, bl=等级, n=名, c=数量}
            BackpackCharSummaryDelta 会重推旧数据 -> 不可用作检测, 本脚本用轮询+diff
  快捷栏机制（实测验证）
    * 读: Remotes.BackpackGetHotbarLayout:InvokeServer()  -> { [1..10] = key }
    * 写: Remotes.BackpackSetHotbarLayout:FireServer(keys)  keys 为字符串数组, 最多 10 个
    * 药水从快捷栏"存入背包" = 把该 key 从布局数组里移除后重发
--------------------------------------------------------------------------------
  API:  _G.HW_MUTATOR.status() / .scan() / .on() / .off() / .save() / .reload()
        .holdKey("Kafka") / .release() / .hotbar() / .debugForce("Halloween",15)
        .debugClear() / .destroy()
================================================================================
]]

local VERSION = 27
local PLACE_ID = 74729868188364
local PREFIX = "[HW]"
local CONFIG_FILE = "hw_mutator_config.json"
local EVENT_NAME = "Halloween"
local GRACE_SECONDS = 2.5
local OBSIDIAN_REPO = "https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/"

--============================================================== 环境守卫
if game.PlaceId ~= PLACE_ID then
    print(PREFIX .. " not target place (" .. tostring(game.PlaceId) .. "), skip")
    return
end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local LocalPlayer
do
    local deadline = os.clock() + 60
    repeat
        LocalPlayer = Players.LocalPlayer
        if not LocalPlayer then task.wait(0.1) end
    until LocalPlayer or os.clock() > deadline
    if not LocalPlayer then
        warn(PREFIX .. " LocalPlayer timeout")
        return
    end
end

local function waitChild(parent, name, timeout)
    local deadline = os.clock() + (timeout or 20)
    local c = parent and parent:FindFirstChild(name)
    while not c and os.clock() < deadline do
        task.wait(0.1)
        c = parent and parent:FindFirstChild(name)
    end
    return c
end

local Remotes = waitChild(RS, "Remotes", 30)
if not Remotes then warn(PREFIX .. " no Remotes") return end

local Constants
do
    local ok, res = pcall(function() return require(RS:WaitForChild("Constants", 20)) end)
    if ok and type(res) == "table" then Constants = res end
end

--============================================================== 状态容器（_G 防重载孤儿）
local GLOBAL_KEY = "HW_MUTATOR"
_G[GLOBAL_KEY] = _G[GLOBAL_KEY] or {}
local R = _G[GLOBAL_KEY]

if R.version and R.version >= VERSION and R.alive then
    print(PREFIX .. " v" .. tostring(R.version) .. " already running (resurface)")
    if R.resurface then pcall(R.resurface) end
    return
end
if R.destroy then pcall(R.destroy) end

R.version = VERSION
R.alive = true
R.gen = (R.gen or 0) + 1
local GEN = R.gen
R.connections = {}
R.threads = {}
R.log = R.log or {}
R.logSeq = R.logSeq or 0
R.stats = { dracula = 0, demonic = 0, other = 0, attempts = 0 }

-- 清理历史孤儿实例：过去若 _G.HW_MUTATOR 被直接置 nil（而不是调用 destroy），
-- 旧实例的线程与 UI 会残留。这里通过 GC 找出所有"像我们 R"的表并调用其 destroy。
-- ⚠ getgc(true) 里混有带 __index 元方法的对象（如 GoodSignal 的 Connection），
--   直接 obj.version 会抛错 -> 必须用 rawget（不触发元方法）并逐个 pcall。
local function killOrphans()
    if type(getgc) ~= "function" then return 0 end
    local ok, list = pcall(getgc, true)
    if not ok or type(list) ~= "table" then return 0 end
    local n = 0
    for _, obj in ipairs(list) do
        if type(obj) == "table" and obj ~= R then
            local ok2, looksOurs = pcall(function()
                return type(rawget(obj, "version")) == "number"
                    and type(rawget(obj, "destroy")) == "function"
                    and type(rawget(obj, "threads")) == "table"
                    and type(rawget(obj, "hotbar")) == "table"
                    and type(rawget(obj, "candidates")) == "table"
                    and rawget(obj, "alive") ~= nil
            end)
            if ok2 and looksOurs then
                local ok3 = pcall(function()
                    local d = rawget(obj, "destroy")
                    if type(d) == "function" then d() end
                end)
                if ok3 then n = n + 1 end
            end
        end
    end
    if n > 0 then print(PREFIX .. " 清理历史孤儿实例: " .. n .. " 个") end
    return n
end
R.cleanupOrphans = killOrphans

local function isCurrent()
    -- 三个条件：自己没被 destroy、gen 没被覆盖、而且 _G 里仍然是"我"
    -- 第三条能防止历史上被 _G 覆盖而失去引用的旧实例继续跑（孤儿线程）
    return R.alive and R.gen == GEN and _G[GLOBAL_KEY] == R
end

--============================================================== 品质
local RARITY_FALLBACK = {
    "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Cosmic",
    "Secret", "Rainbow", "Ascended", "Divine", "Supreme", "Celestial", "Ancient",
    "God", "Omniscient", "Transcendent", "Exclusive",
}
local RARITY_LIST = RARITY_FALLBACK
if Constants and type(Constants.RarityOrder) == "table" and #Constants.RarityOrder > 0 then
    RARITY_LIST = Constants.RarityOrder
end
local RARITY_RANK = {}
for i, name in ipairs(RARITY_LIST) do RARITY_RANK[name] = i end

local RARITY_COLORS = {
    Common = Color3.fromRGB(200, 200, 200), Uncommon = Color3.fromRGB(120, 230, 120),
    Rare = Color3.fromRGB(90, 190, 255), Epic = Color3.fromRGB(205, 110, 255),
    Legendary = Color3.fromRGB(255, 220, 70), Mythical = Color3.fromRGB(255, 90, 90),
    Cosmic = Color3.fromRGB(175, 90, 255), Secret = Color3.fromRGB(170, 170, 180),
    Rainbow = Color3.fromRGB(255, 130, 200), Ascended = Color3.fromRGB(215, 190, 255),
    Divine = Color3.fromRGB(255, 170, 60), Supreme = Color3.fromRGB(120, 255, 150),
    Celestial = Color3.fromRGB(110, 240, 255), Ancient = Color3.fromRGB(255, 190, 80),
    God = Color3.fromRGB(200, 120, 255), Omniscient = Color3.fromRGB(230, 60, 60),
    Transcendent = Color3.fromRGB(240, 240, 255), Exclusive = Color3.fromRGB(130, 170, 255),
}

-- 富文本着色（标签闭合，避免颜色泄漏）
local function colored(text, color)
    text = tostring(text)
    if typeof(color) == "Color3" then
        return string.format('<font color="rgb(%d,%d,%d)">%s</font>',
            math.floor(color.R * 255), math.floor(color.G * 255), math.floor(color.B * 255), text)
    end
    return text
end

--============================================================== 配置
local DEFAULT_CONFIG = {
    enabled = true,
    rarities = { Ancient = true, Celestial = true },
    targets = { Dracula = true, Demonic = true },
    releaseOnEventEnd = true,
    releaseForeignHold = true,      -- 连你手动手持的角色也一起放手（非万圣节期间）
    nativeSelectionFrame = true,    -- 自动手持时显示和手动一样的原生蓝框
    releaseLeadSeconds = 1,
    -- 快捷栏管理
    autoStorePotions = true,
    autoFillCandidates = true,
    hotbarCandidatesFirst = true,   -- 候选角色排在最前，方便观察
    hotbarMaxItems = 0,             -- 0 = 不限（服务器无上限，游戏客户端自身也会加项）
    keepPotionNames = "",           -- 逗号分隔的白名单（想留在快捷栏的药水）
    priorityMode = "rarity",        -- 候选优先级：rarity(品质→同品质按CPS) / cps(纯赚钱速度) / rarityOnly(品质→名字)
    hotbarInterval = 2,             -- 纠正间隔（没有 namecall hook 后调密一点）
    guardCheck = true,              -- 自检：发现药水混进快捷栏就立刻纠正
    clientDriveUI = true,           -- 关键：把布局同步到游戏快捷栏 UI（否则服务器改了 UI 不动）
    blockPotionInsert = true,       -- 关键：禁用客户端的"药水插入快捷栏"处理器
    useNamecallHook = false,        -- ⚠ 默认关：实测它会破坏游戏自身的 FireServer（右键失效）
    pauseHotbar = false,            -- 暂停接管：完全交还控制权，方便手动整理快捷栏
    manualOverrideSeconds = 60,     -- 你一动快捷栏，脚本自动让路这么多秒
    hotbarExcludeChars = "",        -- 逗号分隔：这些角色不会被自动塞进快捷栏
    menuKeybind = "RightShift",     -- 菜单开关快捷键（可在 UI 里改）
    pollHold = 0.5,
    pollSummary = 1.0,
    pollIdle = 3,
    rescanIdle = 10,
    maxLog = 60,
}

local cfg = {}
do
    for k, v in pairs(DEFAULT_CONFIG) do
        if type(v) == "table" then
            cfg[k] = {}
            for k2, v2 in pairs(v) do cfg[k][k2] = v2 end
        else
            cfg[k] = v
        end
    end
end

local function readFileSafe(path)
    local ok, data = pcall(readfile, path)
    if ok and type(data) == "string" then return data end
    return nil
end

local function writeFileSafe(path, data)
    local ok, err = pcall(writefile, path, data)
    return ok, err
end

local function loadConfig(silent)
    local data = readFileSafe(CONFIG_FILE)
    if type(data) ~= "string" or #data < 2 then
        if not silent then print(PREFIX .. " 无配置文件，使用默认值") end
        return false
    end
    local ok, obj = pcall(function() return HttpService:JSONDecode(data) end)
    if not ok or type(obj) ~= "table" then
        warn(PREFIX .. " 配置解析失败: " .. tostring(obj))
        return false
    end
    for k, v in pairs(obj) do
        if type(v) == "table" and type(DEFAULT_CONFIG[k]) == "table" then
            cfg[k] = {}
            for k2, v2 in pairs(v) do cfg[k][k2] = v2 end
        elseif DEFAULT_CONFIG[k] ~= nil then
            cfg[k] = v
        end
    end
    if not silent then print(PREFIX .. " 配置已加载 (" .. CONFIG_FILE .. ")") end
    return true
end

local function saveConfig()
    local ok, err = writeFileSafe(CONFIG_FILE, HttpService:JSONEncode(cfg))
    if ok then print(PREFIX .. " 配置已保存 -> " .. CONFIG_FILE)
    else warn(PREFIX .. " 保存失败: " .. tostring(err)) end
    return ok
end

loadConfig(true)
R.cfg = cfg

--============================================================== 运行时状态
R.summary = nil
R.candidates = {}
R.event = { active = false, name = nil, title = nil, remaining = 0, duration = 0 }
R.hold = { key = nil, name = nil, rarity = nil, baseline = nil, since = 0, misses = 0 }
R.hotbar = { layout = {}, lastFire = 0, lastTarget = nil }

local function log(msg, color)
    R.logSeq = R.logSeq + 1
    local entry = { seq = R.logSeq, t = os.date("%H:%M:%S"), msg = tostring(msg), color = color }
    table.insert(R.log, entry)
    while #R.log > (tonumber(cfg.maxLog) or 60) do table.remove(R.log, 1) end
    print(PREFIX .. " " .. entry.t .. " " .. entry.msg)
    if R.renderLog then pcall(R.renderLog) end
end

--============================================================== 远程接口
local RF = {
    state = Remotes:FindFirstChild("GetTypeEventState"),
    summary = Remotes:FindFirstChild("BackpackCharSummaryGet"),
    hold = Remotes:FindFirstChild("BackpackHoldCharacter"),
    hbGet = Remotes:FindFirstChild("BackpackGetHotbarLayout"),
    hbSet = Remotes:FindFirstChild("BackpackSetHotbarLayout"),
    -- 下面两个是"真正驱动游戏快捷栏 UI"的关键（见 clientApplyLayout / disablePotionInsertHandler）
    layoutLate = Remotes:FindFirstChild("BackpackHotbarLayoutLate"),
    potionInsert = Remotes:FindFirstChild("PotionHotbarInsert"),
}

local function invokeState()
    if not RF.state then return nil end
    local ok, res = pcall(function() return RF.state:InvokeServer() end)
    if ok and type(res) == "table" then return res end
    return nil
end

local function fetchSummary()
    if not RF.summary then return nil end
    local ok, res = pcall(function() return RF.summary:InvokeServer() end)
    if ok and type(res) == "table" then return res end
    return nil
end

local function doHold(key)
    if not RF.hold then return false end
    local ok = pcall(function() RF.hold:FireServer(key) end)
    return ok
end

local function doRelease()
    if not RF.hold then return end
    pcall(function() RF.hold:FireServer("") end)
end

local function heldName()
    local tf = workspace:FindFirstChild("ToolFollowers")
    if tf then
        for _, c in ipairs(tf:GetChildren()) do
            local n = c.Name:match("^ToolFollower_(.+)$")
            if n then return n end
        end
    end
    local ch = LocalPlayer.Character
    if ch then
        for _, c in ipairs(ch:GetChildren()) do
            if c:IsA("Tool") and c:GetAttribute("IsFishingRod") ~= true then
                return c.Name
            end
        end
    end
    return nil
end

--============================================================== 候选 / 突变检测
local function buildCandidates(summary)
    local list = {}
    if type(summary) ~= "table" then return list end
    for key, v in pairs(summary) do
        if type(v) == "table" then
            local ty = tostring(v.ty or "")
            local ra = tostring(v.ra or "")
            if ty == "" and cfg.rarities[ra] then
                list[#list + 1] = {
                    key = key, name = tostring(v.n or "?"), rarity = ra,
                    rank = RARITY_RANK[ra] or 0, count = tonumber(v.c) or 1,
                    cps = tonumber(v.bc) or 0,        -- bc = 赚钱速度（Cash Per Second），与游戏 UI 显示完全一致
                    level = tonumber(v.bl) or 1,
                }
            end
        end
    end
    -- 优先级：默认"品质高→低，同品质内赚钱快→慢"
    local mode = tostring(cfg.priorityMode or "rarity")
    table.sort(list, function(a, b)
        if mode == "cps" then
            if a.cps ~= b.cps then return a.cps > b.cps end
            if a.rank ~= b.rank then return a.rank > b.rank end
        else
            if a.rank ~= b.rank then return a.rank > b.rank end
            if mode ~= "rarityOnly" and a.cps ~= b.cps then return a.cps > b.cps end
        end
        if a.name ~= b.name then return a.name < b.name end
        return a.key < b.key
    end)
    return list
end

-- CPS 显示（与游戏 UI 风格一致：$145M/s、$17.6M/s）
local function fmtCps(n)
    n = tonumber(n) or 0
    if n >= 1e12 then return string.format("$%gT/s", n / 1e12) end
    if n >= 1e9 then return string.format("$%gB/s", n / 1e9) end
    if n >= 1e6 then return string.format("$%gM/s", n / 1e6) end
    if n >= 1e3 then return string.format("$%gK/s", n / 1e3) end
    return string.format("$%g/s", n)
end

local function baselineFor(summary, name)
    local map = {}
    if type(summary) ~= "table" then return map end
    for key, v in pairs(summary) do
        if type(v) == "table" and tostring(v.n or "") == name then
            map[key] = { ty = tostring(v.ty or ""), c = tonumber(v.c) or 1 }
        end
    end
    return map
end

local function detectMutation(baseline, summary, name)
    local hits = {}
    if type(summary) ~= "table" or type(baseline) ~= "table" then return hits end
    for key, v in pairs(summary) do
        if type(v) == "table" and tostring(v.n or "") == name then
            local ty = tostring(v.ty or "")
            if ty ~= "" then
                local b = baseline[key]
                local before = b and b.c or 0
                local now = tonumber(v.c) or 1
                if now > before then
                    hits[#hits + 1] = { key = key, ty = ty, rarity = tostring(v.ra or ""), count = now }
                end
            end
        end
    end
    return hits
end

--============================================================== 客户端环境 / 原生蓝框
-- 实测：游戏客户端把它所有可编程入口挂在**它自己的 _G** 上（110 个 CF_/__BP_ 键，例如
--   CF_BackpackClearSelection / CF_BackpackGetSelected / __BP_ForceHotbarSlots）。
-- 执行器的 _G ≠ 客户端的 _G（实测 _G == getgenv() 为 false），往自己的 _G 写 __BP_* 客户端读不到。
-- 但**函数/表对象本身是共享的** -> 用 getgc 扫出那张表，就能直接调用客户端内部函数。
-- 蓝框机制（BackpackClientService:3758 applySelectionVisuals）：
--   u166 = 当前选中的 key；函数遍历 u172[key]->按钮，非 u166 的销毁 SelectionStroke，
--   给 u166 的按钮 applySelectionStroke()。u166 是 setSelected/applySelectionVisuals 的**共享 upvalue**
--   -> 用 debug.setupvalue 写入它 = 和手动点击一模一样的原生蓝框。
local CLIENT_G = nil
local CLIENT_SEL = { visit = nil, idx = nil, lastScan = 0, ok = false }

local function findClientG()
    if type(getgc) ~= "function" then return nil end
    local ok, objs = pcall(getgc, true)
    if not ok or type(objs) ~= "table" then return nil end
    for _, obj in ipairs(objs) do
        if type(obj) == "table" then
            local got = false
            pcall(function() got = type(rawget(obj, "CF_BackpackClearSelection")) == "function" end)
            if got then return obj end
        end
    end
    return nil
end

local function clientG()
    if CLIENT_G then
        local alive = false
        pcall(function() alive = type(rawget(CLIENT_G, "CF_BackpackClearSelection")) == "function" end)
        if alive then return CLIENT_G end
        CLIENT_G = nil
    end
    -- 复用上一个实例（重载时不重复扫 60 万对象）
    local shared = _G.__HW_CLIENT_G
    if type(shared) == "table" then
        local ok = false
        pcall(function() ok = type(rawget(shared, "CF_BackpackClearSelection")) == "function" end)
        if ok then CLIENT_G = shared return CLIENT_G end
    end
    local now = os.clock()
    if now - (CLIENT_SEL.lastScan or 0) < 30 then return nil end   -- 要扫 60 万+ 对象，别太勤
    CLIENT_SEL.lastScan = now
    CLIENT_G = findClientG()
    if CLIENT_G then
        _G.__HW_CLIENT_G = CLIENT_G
        if not CLIENT_SEL.announced then
            CLIENT_SEL.announced = true
            log("已定位客户端环境表（原生选中/蓝框已解锁）", Color3.fromRGB(120, 255, 140))
        end
    end
    return CLIENT_G
end

-- applySelectionVisuals = CF_BackpackClearSelection 的 upvalue 里那个 function
local function selectionVisuals()
    if CLIENT_SEL.visit then return CLIENT_SEL.visit end
    local g = clientG()
    if not g then return nil end
    local clearFn = rawget(g, "CF_BackpackClearSelection")
    if type(clearFn) ~= "function" then return nil end
    for i = 1, 6 do
        local v = debug.getupvalue(clearFn, i)
        if type(v) == "function" then
            CLIENT_SEL.visit = v
            return v
        end
    end
    return nil
end

-- 保底：原生不可用时，自己在对应槽位上画一个描边
local function drawOwnStroke(key)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    local bar = mg and mg:FindFirstChild("BackpackHotBar")
    if not bar then return false end
    local done = false
    for _, slot in ipairs(bar:GetChildren()) do
        if slot.Name:match("^Slot_%d+$") then
            local old = slot:FindFirstChild("HW_HeldStroke")
            if old then pcall(function() old:Destroy() end) end
            if key ~= nil and slot:GetAttribute("BoundKey") == key then
                local st = Instance.new("UIStroke")
                st.Name = "HW_HeldStroke"
                st.Color = Color3.fromRGB(90, 180, 255)
                st.Thickness = 2
                st.Transparency = 0.12
                st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
                st.Parent = slot
                done = true
            end
        end
    end
    return done
end

local function clearOwnStroke()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    local bar = mg and mg:FindFirstChild("BackpackHotBar")
    if not bar then return end
    for _, slot in ipairs(bar:GetChildren()) do
        local old = slot:FindFirstChild("HW_HeldStroke")
        if old then pcall(function() old:Destroy() end) end
    end
end

-- 让游戏把某个 key 显示为"选中"（原生蓝框）
local function clientSetSelected(key)
    if cfg.nativeSelectionFrame == false then return false end
    local g = clientG()
    if not g then return drawOwnStroke(key) end
    local visit = selectionVisuals()
    if not visit then return drawOwnStroke(key) end
    local getSel = rawget(g, "CF_BackpackGetSelected")

    local function verify()
        if type(getSel) ~= "function" then return true end
        local ok, sel = pcall(getSel)
        return ok and sel == key
    end

    -- 已缓存索引：直接写
    if CLIENT_SEL.idx then
        pcall(debug.setupvalue, visit, CLIENT_SEL.idx, key)
        if verify() then
            pcall(visit)
            clearOwnStroke()
            return true
        end
        CLIENT_SEL.idx = nil
    end

    -- 逐个尝试"值为 nil"的 upvalue，并用 GetSelected 验证（u166 当前必然为 nil）
    for i = 1, 14 do
        local v = debug.getupvalue(visit, i)
        if v == nil then
            pcall(debug.setupvalue, visit, i, key)
            if verify() then
                CLIENT_SEL.idx = i
                pcall(visit)
                clearOwnStroke()
                return true
            end
            pcall(debug.setupvalue, visit, i, nil)
        end
    end
    return drawOwnStroke(key)
end

local function clientClearSelection()
    clearOwnStroke()
    local g = clientG()
    if not g then return false end
    local clearFn = rawget(g, "CF_BackpackClearSelection")
    if type(clearFn) == "function" then
        return pcall(clearFn)
    end
    return false
end

--============================================================== 手持控制
local function applyHold(key, name, rarity)
    doHold(key)
    R.hold.key, R.hold.name, R.hold.rarity = key, name, rarity
    R.hold.since = os.clock()
    R.hold.misses = 0
    R.hold.baseline = baselineFor(R.summary, name)
    R.hold.adopted = false
    R.stats.attempts = R.stats.attempts + 1
    clientSetSelected(key)          -- 原生蓝框（和手动点击一样）
end

-- 你手动手持了某个候选角色 -> 直接接管，不重复发包、不跟你抢
local function adoptHold(key, name, rarity)
    R.hold.key, R.hold.name, R.hold.rarity = key, name, rarity
    R.hold.since = os.clock()
    R.hold.misses = 0
    R.hold.baseline = baselineFor(R.summary, name)
    R.hold.adopted = true
    clientSetSelected(key)
    log("接替你手动手持的 " .. name .. " [" .. tostring(rarity) .. "]", Color3.fromRGB(140, 220, 255))
end

local function applyRelease(reason)
    -- ⚠ 修复：以前只在 R.hold.key 存在时才 doRelease()，
    --   所以你手动手持时点界面上的"放手"按钮完全没有反应。
    --   现在无论是不是本脚本所持，都真发一次放手。
    local who = R.hold.name or R.hold.foreignName
    doRelease()
    if who then
        log("放手 " .. tostring(who) .. (reason and ("（" .. reason .. "）") or ""))
    elseif reason then
        log("放手（" .. reason .. "）")
    end
    R.hold.key, R.hold.name, R.hold.rarity, R.hold.baseline, R.hold.misses = nil, nil, nil, nil, 0
    R.hold.foreignName = nil
    R.hold.adopted = false
    clientClearSelection()
end

local function refreshCandidates()
    local s = fetchSummary()
    if s then
        R.summary = s
        R.candidates = buildCandidates(s)
        R._lastSummaryAt = os.clock()
        return true
    end
    return false
end

--============================================================== 快捷栏管理
-- 药水工具名（权威：Constants.Potions.Definitions[].ToolName）
local POTION_NAMES = {}
do
    local P = Constants and Constants.Potions and Constants.Potions.Definitions
    if type(P) == "table" then
        for _, v in pairs(P) do
            if type(v) == "table" and type(v.ToolName) == "string" then
                POTION_NAMES[v.ToolName] = true
            end
        end
    end
end

local function keepPotionSet()
    local set = {}
    local s = tostring(cfg.keepPotionNames or "")
    for piece in s:gmatch("[^,，]+") do
        local t = piece:match("^%s*(.-)%s*$")
        if t ~= "" then set[t] = true end
    end
    return set
end

local function isPotionKey(key)
    local name = key:match("^T|(.+)$")
    if not name then return false end
    if keepPotionSet()[name] then return false end
    if POTION_NAMES[name] then return true end
    return name:lower():find("potion", 1, true) ~= nil
end

-- "不想被自动塞进快捷栏"的角色名（逗号分隔）
local function excludeNameSet()
    local set = {}
    local s = tostring(cfg.hotbarExcludeChars or "")
    for piece in s:gmatch("[^,，]+") do
        local t = piece:match("^%s*(.-)%s*$")
        if t ~= "" then set[t] = true end
    end
    return set
end

local function getLayout()
    if not RF.hbGet then return nil end
    local ok, res = pcall(function() return RF.hbGet:InvokeServer() end)
    if not ok or type(res) ~= "table" then return nil end
    local list = {}
    for _, v in ipairs(res) do
        if type(v) == "string" and v ~= "" and not v:find("|E|", 1, true) then
            list[#list + 1] = v
        end
    end
    return list
end

local function setLayout(list)
    if not RF.hbSet then return false end
    local ok = pcall(function() RF.hbSet:FireServer(list) end)
    return ok
end

-- 目标布局（非破坏式）：
--   * 药水（开启自动收起时）从布局剔除 = 存入背包
--   * 其余条目（鱼竿、其他角色等）一律原样保留，不截断、不丢键
--   * 候选角色按优先级补入；hotbarCandidatesFirst 决定置顶还是追加
--   * hotbarMaxItems > 0 时才限制总数（默认 0 = 不限）
--   实测：服务器对布局数量没有 10 项上限；游戏客户端自己也会往快捷栏加新角色/药水，
--         所以本函数只做"减药水 + 补候选"，绝不主动删别的键
local function computeTargetLayout(cur, candidates, fill)
    local target, seen = {}, {}
    local maxItems = tonumber(cfg.hotbarMaxItems) or 0
    local function push(k)
        if type(k) ~= "string" or k == "" or seen[k] then return end
        if maxItems > 0 and #target >= maxItems then return end
        seen[k] = true
        target[#target + 1] = k
    end

    local kept = {}
    for _, k in ipairs(cur or {}) do
        if not (cfg.autoStorePotions and isPotionKey(k)) then
            kept[#kept + 1] = k
        end
    end

    local first = (cfg.hotbarCandidatesFirst ~= false)
    if fill and first then
        local ex = excludeNameSet()
        for _, c in ipairs(candidates or {}) do
            if not ex[c.name] then push(c.key) end
        end
    end
    for _, k in ipairs(kept) do push(k) end
    if fill and not first then
        local ex = excludeNameSet()
        for _, c in ipairs(candidates or {}) do
            if not ex[c.name] then push(c.key) end
        end
    end
    return target
end

local function layoutEq(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- 接管客户端快捷栏状态：清掉药水的"用户插入"标记 + 标记布局已应用，
-- 否则游戏的 BackpackClientService 会用旧布局把药水又塞回来
local function takeoverHotbarClientState()
    local ui = _G.__BP_UserInserted
    if type(ui) == "table" then
        for k in pairs(ui) do
            if isPotionKey(k) then ui[k] = nil end
        end
    end
    if _G.__BP_SavedLayoutApplied ~= true then
        _G.__BP_SavedLayoutApplied = true
    end
end

--============================================================== 快捷栏写入拦截（关键）
-- 实测：游戏客户端会因为"新钓到角色"而每秒重发 BackpackSetHotbarLayout，
--       频率远高于我们的轮询 -> 我们的布局会被瞬间覆盖（表现为"功能没生效"）。
-- 解法：hook __namecall（单层，状态放 _G），拦截对该 remote 的所有 FireServer，
--       先把参数归一化（减药水 + 补候选）再发出；游戏自身的写入同样被规范化。
--       你在手动整理时（manualActive）原样放行，不干预。

local function normalizeLayout(list)
    local cur = {}
    if type(list) == "table" then
        for _, k in ipairs(list) do
            if type(k) == "string" then cur[#cur + 1] = k end
        end
    end
    local fill = cfg.autoFillCandidates and (R.summary ~= nil)
    return computeTargetLayout(cur, R.candidates, fill)
end

-- 安装"单层" __namecall hook。
-- ⚠ 关键：hook 状态放 _G（__HW_NC_HOOK / __HW_NC_ORIG），保证**永远只有一层**。
--   之前每次重载都套一层，旧实例的 unhook 又覆盖新实例的 hook，
--   结果 orig 变成 nil -> 游戏自己 fire 布局时报 "attempt to call a nil value"。
local function installHotbarHook()
    if not RF.hbSet then return false end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        log("hookmetamethod 不可用 -> 快捷栏只能靠轮询（可能被游戏覆盖）", Color3.fromRGB(255, 180, 80))
        return false
    end

    -- 上一个实例已装过同一层：复用即可（卸载交给拥有者，这里不设置 unhook）
    if type(_G.__HW_NC_HOOK) == "function" and type(_G.__HW_NC_ORIG) == "function" then
        return true
    end

    local prev = nil          -- 真正的原始 __namecall（下面赋值后被闭包捕获）
    local hookFn
    hookFn = function(self, ...)
        if self == RF.hbSet and getnamecallmethod() == "FireServer" then
            if manualActive() or (not cfg.autoStorePotions and not cfg.autoFillCandidates) then
                return prev(self, ...)                    -- 让路 / 未启用：原样放行
            end
            local args = { ... }                          -- 必须在 vararg 层捕获
            local norm = normalizeLayout(args[1])
            R.hotbar.layout = norm
            R.hotbar.lastFire = os.clock()
            return prev(self, norm)                       -- 直接走原始调用，天然无递归
        end
        return prev(self, ...)
    end

    prev = hookmetamethod(game, "__namecall", hookFn)
    if type(prev) ~= "function" then
        log("安装快捷栏拦截失败（hookmetamethod 未返回原函数）", Color3.fromRGB(255, 120, 120))
        return false
    end

    _G.__HW_NC_HOOK = hookFn
    _G.__HW_NC_ORIG = prev
    R.unhookHotbar = function()
        if _G.__HW_NC_HOOK ~= hookFn then return end          -- 已被新实例接管，别乱还原
        pcall(function() hookmetamethod(game, "__namecall", prev) end)
        _G.__HW_NC_HOOK, _G.__HW_NC_ORIG = nil, nil
        R.unhookHotbar = nil
    end
    log("已安装快捷栏写入拦截（单层，游戏客户端的重写也会被规范化）")
    return true
end

--============================================================== 客户端插入函数接管
-- ⚠ 实测：执行器的 _G / getgenv() / getrenv() 都不是客户端脚本所在的 _G，
--   所以这里写的 wrapper 客户端根本读不到（这一段实际是 no-op，仅作兼容保留）。
--   真正有效的药水拦截在下面 disablePotionInsertHandler（用 getconnections 禁用客户端连接）。
local insertOrig, forceOrig = nil, nil
R.clientHooks = { insert = nil, force = nil }

local function makePotionBlocker(getOrig, tag)
    local wrapper
    wrapper = function(key, ...)
        if cfg.autoStorePotions and type(key) == "string" and isPotionKey(key) then
            R.hotbar.blocked = (R.hotbar.blocked or 0) + 1
            return false
        end
        local o = getOrig()
        if type(o) == "function" and o ~= wrapper then
            return o(key, ...)
        end
        return false
    end
    return wrapper
end

local function takeoverClientInsertHooks()
    if not cfg.autoStorePotions then return end

    -- ⚠ 注意：不能只写 `_G.X ~= ours`，因为两者都是 nil 时 nil ~= nil 为 false，
    --   会永远跳过安装。必须额外判断 ours == nil（尚未安装）。
    local curInsert = _G.__BP_InsertKeyIfHotbarSpace
    if curInsert ~= R.clientHooks.insert or R.clientHooks.insert == nil then
        if type(curInsert) == "function" then insertOrig = curInsert end
        R.clientHooks.insert = makePotionBlocker(function() return insertOrig end, "insert")
        _G.__BP_InsertKeyIfHotbarSpace = R.clientHooks.insert
    end

    local curForce = _G.__BP_ForceKeyIntoHotbar
    if curForce ~= R.clientHooks.force or R.clientHooks.force == nil then
        if type(curForce) == "function" then forceOrig = curForce end
        R.clientHooks.force = makePotionBlocker(function() return forceOrig end, "force")
        _G.__BP_ForceKeyIntoHotbar = R.clientHooks.force
    end
end

local function restoreClientInsertHooks()
    if R.clientHooks.insert and _G.__BP_InsertKeyIfHotbarSpace == R.clientHooks.insert then
        _G.__BP_InsertKeyIfHotbarSpace = insertOrig
    end
    if R.clientHooks.force and _G.__BP_ForceKeyIntoHotbar == R.clientHooks.force then
        _G.__BP_ForceKeyIntoHotbar = forceOrig
    end
    R.clientHooks = { insert = nil, force = nil }
end

R.restoreClientInsertHooks = restoreClientInsertHooks

--============================================================== 驱动游戏快捷栏 UI（真正的关键）
-- 实测结论（这一节是整个功能的成败点）：
--   * 游戏的快捷栏 UI 完全由客户端本地状态驱动。只 fire BackpackSetHotbarLayout
--     只能改服务器布局，UI 一动不动 -> 表现为"快捷栏整理没工作"。
--   * 客户端 BackpackClientService 里的 applyServerLayout 带"一次性守卫"
--     （一个布尔 upvalue，首次执行后置 true，之后直接 return）
--     -> 服务器布局一辈子只应用一次。必须把守卫重置回 false 再调用它。
--   * PotionHotbarInsert 的客户端处理器会把药水插回快捷栏，必须禁用该连接。
-- 两者都通过 getconnections 拿到客户端脚本的真实连接对象来操作。
local function boolUpvalueIndex(f)
    -- Luau 的 debug.getupvalue 只返回值；找第一个 boolean 就是那个一次性守卫
    for i = 1, 16 do
        local ok, v = pcall(debug.getupvalue, f, i)
        if not ok or v == nil then return nil end
        if type(v) == "boolean" then return i end
    end
    return nil
end

local function clientApplyLayout(list)
    if cfg.clientDriveUI == false then return false end
    if type(getconnections) ~= "function" or not RF.layoutLate then return false end
    local ok, conns = pcall(getconnections, RF.layoutLate.OnClientEvent)
    if not ok or type(conns) ~= "table" or #conns == 0 then return false end
    for _, c in ipairs(conns) do
        local f = c.Function
        if type(f) == "function" then
            local gi = boolUpvalueIndex(f)
            if gi then pcall(debug.setupvalue, f, gi, false) end   -- 重置一次性守卫
            local ok2 = pcall(f, list)
            if ok2 then
                R.hotbar.clientApplied = (R.hotbar.clientApplied or 0) + 1
                return true
            end
        end
    end
    return false
end

-- 前向声明：让下面的 disablePotionInsertHandler / installHotbarHook 都能引用到
local manualActive

local function disablePotionInsertHandler()
    if manualActive and manualActive() then return false end
    if cfg.blockPotionInsert == false then return false end
    if type(getconnections) ~= "function" or not RF.potionInsert then return false end
    local ok, conns = pcall(getconnections, RF.potionInsert.OnClientEvent)
    if not ok or type(conns) ~= "table" then return false end
    local changed = false
    for _, c in ipairs(conns) do
        if c.Enabled ~= false then
            local ok2 = pcall(function() c:Disable() end)
            if ok2 then
                changed = true
                R.hotbar.potionBlocked = (R.hotbar.potionBlocked or 0) + 1
            end
        end
        R.hotbar.potionConnEnabled = (c.Enabled ~= false)
    end
    return changed
end

-- 暂停接管：把客户端的药水插入连接恢复启用，完全交还控制权
local function pauseHotbarControl()
    if type(getconnections) ~= "function" or not RF.potionInsert then return end
    local ok, conns = pcall(getconnections, RF.potionInsert.OnClientEvent)
    if not ok or type(conns) ~= "table" then return end
    for _, c in ipairs(conns) do
        if c.Enabled == false then pcall(function() c:Enable() end) end
        R.hotbar.potionConnEnabled = (c.Enabled ~= false)
    end
end

--============================================================== 手动让路机制
-- 目标：功能照常自动跑，但你一动手就自动让路，绝不跟你抢。
-- 触发方式：
--   1) 点/右键 游戏快捷栏任意槽位（挂 MouseButton1Down/MouseButton2Down/InputBegan）
--   2) 点 UI 里的"给我 N 秒自由整理"按钮
--   3) 打开"⏸ 暂停接管"（永久让路）
-- 让路期间：不 fire 布局、不推客户端 UI、并且把客户端的药水插入连接恢复启用
--           -> 你可以随意增删角色/药水/物品，脚本完全不干涉。
function manualActive()
    if cfg.pauseHotbar then return true end
    return os.clock() < (R.hotbar.manualUntil or 0)
end

local function setPotionConnEnabled(wantEnabled)
    if type(getconnections) ~= "function" or not RF.potionInsert then return end
    local ok, conns = pcall(getconnections, RF.potionInsert.OnClientEvent)
    if not ok or type(conns) ~= "table" then return end
    for _, c in ipairs(conns) do
        if wantEnabled then
            if c.Enabled == false then pcall(function() c:Enable() end) end
        else
            if c.Enabled ~= false then pcall(function() c:Disable() end) end
        end
        R.hotbar.potionConnEnabled = (c.Enabled ~= false)
    end
end

local function extendManual(sec, why)
    local add = tonumber(sec) or tonumber(cfg.manualOverrideSeconds) or 60
    local was = R.hotbar.manualUntil or 0
    local now = os.clock()
    R.hotbar.manualUntil = math.max(was, now + add)
    if was <= now then
        setPotionConnEnabled(true)     -- 让路期间恢复游戏默认行为，方便你自由操作
        log(string.format("检测到你手动操作快捷栏（%s）-> 脚本让路 %.0f 秒", tostring(why or "操作"), add),
            Color3.fromRGB(255, 200, 90))
    end
end

-- 给游戏快捷栏的每个槽位挂上"你在动手"的监听
local function hookHotbarSlots()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    local bar = mg and mg:FindFirstChild("BackpackHotBar")
    if not bar then return end
    R.slotConns = R.slotConns or {}
    for _, c in ipairs(bar:GetChildren()) do
        if c.Name:match("^Slot_%d+$") and not R.slotConns[c] then
            local list = {}
            if c.MouseButton1Down then
                list[#list + 1] = c.MouseButton1Down:Connect(function() extendManual(nil, "左键") end)
            end
            if c.MouseButton2Down then
                list[#list + 1] = c.MouseButton2Down:Connect(function() extendManual(nil, "右键") end)
            end
            if c.InputBegan then
                list[#list + 1] = c.InputBegan:Connect(function(input)
                    if not input then return end
                    local ut = input.UserInputType
                    if ut == Enum.UserInputType.MouseButton1 or ut == Enum.UserInputType.MouseButton2
                        or ut == Enum.UserInputType.Touch then
                        extendManual(nil, "点击")
                    end
                end)
            end
            R.slotConns[c] = list
            R.connections[#R.connections + 1] = list[1]
        end
    end
end

local function manageHotbar(force)
    if manualActive() then
        setPotionConnEnabled(true)      -- 让路中，保持游戏默认行为
        return
    end
    local now = os.clock()
    if not force and (now - (R.hotbar.lastFire or 0)) < (tonumber(cfg.hotbarInterval) or 3) then return end
    if not cfg.autoStorePotions and not cfg.autoFillCandidates then return end

    takeoverClientInsertHooks()
    disablePotionInsertHandler()

    local cur = getLayout()
    if not cur then return end
    takeoverHotbarClientState()

    -- 只有拿到真实背包数据时才追加候选，避免误删用户已有布局
    local fill = cfg.autoFillCandidates and (R.summary ~= nil)

    local target = computeTargetLayout(cur, R.candidates, fill)

    R.hotbar.lastFire = now

    if not layoutEq(cur, target) then
        setLayout(target)
        if force then
            log("快捷栏整理: " .. #cur .. " -> " .. #target .. " 项")
        end
    end

    R.hotbar.layout = target
    R.hotbar.liveCount = #target

    -- 关键：把布局推给游戏客户端的 UI（否则服务器改了、界面不动）
    clientApplyLayout(target)
end

-- 自检：直接读服务器布局，确认没有药水混进来；发现就立刻纠正
local function hotbarSelfCheck()
    if not cfg.guardCheck then return true end
    if not cfg.autoStorePotions and not cfg.autoFillCandidates then return true end
    local live = getLayout()
    if not live then return true end
    local pot = 0
    for _, k in ipairs(live) do
        if isPotionKey(k) then pot = pot + 1 end
    end
    R.hotbar.liveCount = #live
    R.hotbar.livePotions = pot

    -- 顺带读游戏 UI 的实际槽位数（面板上可直接确认同步是否生效）
    do
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local mg = pg and pg:FindFirstChild("MainGui")
        local bar = mg and mg:FindFirstChild("BackpackHotBar")
        local n = 0
        if bar then
            for _, c in ipairs(bar:GetChildren()) do
                if c.Name:match("^Slot_%d+$") then n = n + 1 end
            end
        end
        R.hotbar.uiSlots = n
    end
    if pot > 0 then
        R.hotbar.guardHits = (R.hotbar.guardHits or 0) + 1
        if (R.hotbar.guardHits % 3) == 1 then
            log("⚠ 自检：快捷栏里有 " .. pot .. " 个药水 -> 立刻纠正", Color3.fromRGB(255, 180, 80))
        end
        manageHotbar(true)
        return false
    end
    return true
end

--============================================================== 事件状态
local function updateEventFromTable(t)
    if type(t) ~= "table" then return end
    local name = t.eventName and tostring(t.eventName) or nil
    local remaining = tonumber(t.remaining)
    local active = t.active
    if active == nil then
        if remaining ~= nil then active = remaining > 0
        else active = (name ~= nil and tostring(t.kind or "") ~= "End") end
    end
    R.event.active = (active == true) and (name ~= nil)
    R.event.name = name
    R.event.title = (t.eventTitle and tostring(t.eventTitle)) or (t.gradientName and tostring(t.gradientName)) or name
    if remaining then
        R.event.remaining = remaining
        R.event.at = os.clock()      -- 打锚点：显示时按本地时钟平滑推算，避免一跳一跳
    end
    if tonumber(t.duration) then R.event.duration = tonumber(t.duration) end
end

local function refreshEvent()
    local s = invokeState()
    if s then updateEventFromTable(s)
    else R.event.active, R.event.name, R.event.remaining = false, nil, 0 end
end

do
    local ev = Remotes:FindFirstChild("TypeEventState")
    if ev then
        R.connections[#R.connections + 1] = ev.OnClientEvent:Connect(function(p)
            if not isCurrent() then return end
            if type(p) ~= "table" then return end
            updateEventFromTable(p)
        end)
    end
end

-- 平滑剩余秒数：服务器每秒才推一次、我们又只 5 秒轮询一次，
-- 直接用原值会让界面倒计时"一卡一卡"。这里用"上次读数 + 本地时钟差"推算。
local function eventRemaining()
    local r = tonumber(R.event.remaining) or 0
    if R.event.active and R.event.at then
        r = r - (os.clock() - R.event.at)
    end
    return math.max(0, r)
end
R.eventRemaining = eventRemaining

local function isHalloween()
    if R._force then
        if os.clock() < (R._force.until_ or 0) then return R._force.name == EVENT_NAME end
        R._force = nil
    end
    return R.event.active and R.event.name == EVENT_NAME and eventRemaining() > 0
end

--============================================================== 主循环
local function checkMutation(s)
    if not (R.hold.key and R.hold.baseline) then return 0 end
    local hits = detectMutation(R.hold.baseline, s, R.hold.name)
    if #hits == 0 then return 0 end
    local doneName = R.hold.name
    for _, h in ipairs(hits) do
        local isTarget = cfg.targets[h.ty] == true
        if isTarget then
            if h.ty == "Dracula" then R.stats.dracula = R.stats.dracula + 1
            elseif h.ty == "Demonic" then R.stats.demonic = R.stats.demonic + 1 end
            log("★ 命中 " .. doneName .. " -> " .. h.ty .. " [" .. h.rarity .. "]", Color3.fromRGB(120, 255, 140))
            if R.notify then
                pcall(R.notify, { Title = "★ " .. h.ty .. "!", Description = doneName .. " [" .. h.rarity .. "]", Time = 10, Icon = "party-popper" })
            end
        else
            R.stats.other = R.stats.other + 1
            log("⚠ " .. doneName .. " 突变为 " .. h.ty .. "（非目标，已作废）", Color3.fromRGB(255, 130, 130))
        end
    end
    return #hits
end

local function advanceAfterHit(s)
    applyRelease("已突变")
    R.candidates = buildCandidates(s)
    local pick = R.candidates[1]
    if pick then
        applyHold(pick.key, pick.name, pick.rarity)
        log("手持 " .. pick.name .. " [" .. pick.rarity .. "]")
    end
    manageHotbar(true)
end

-- 快捷栏每 tick 的轻量维护：复查客户端全局接管 + 周期性自检
local function hotbarTick()
    if manualActive() then
        setPotionConnEnabled(true)
        return
    end
    takeoverClientInsertHooks()
    hookHotbarSlots()
    manageHotbar(false)
    local now = os.clock()
    if (now - (R.hotbar.lastGuard or 0)) > (tonumber(cfg.hotbarInterval) or 3) then
        R.hotbar.lastGuard = now
        hotbarSelfCheck()
    end
end

local function tick()
    local now = os.clock()
    takeoverClientInsertHooks()

    if not R._lastEventPoll or now - R._lastEventPoll > 2 then
        R._lastEventPoll = now
        refreshEvent()
    end

    if not cfg.enabled then
        if R.hold.key then applyRelease("已停用") end
        if not R._lastIdleScan or now - R._lastIdleScan > (tonumber(cfg.rescanIdle) or 10) then
            R._lastIdleScan = now
            refreshCandidates()
        end
        hotbarTick()
        return
    end

    local forced = R._force ~= nil and os.clock() < (R._force.until_ or 0)
    local halloween = isHalloween()
    local lead = tonumber(cfg.releaseLeadSeconds) or 0
    local ending = (not forced) and halloween and eventRemaining() <= lead
    local live = halloween and not ending

    if not live then
        -- 分级策略（既安全又不打扰）：
        --   * 有"别的突变事件"在跑  -> 你手动持的角色有被烧的风险 -> 按开关自动放手
        --   * 没有任何事件          -> 根本不会被烧 -> 脚本完全不干预，你可以自由看/用你的角色
        local curName = heldName()
        local holdingOurs = R.hold.key ~= nil
        local holdingForeign = (not holdingOurs) and curName ~= nil
        local evName = R.event.active and R.event.name or nil
        local evRunning = evName ~= nil and eventRemaining() > 0
        local releaseForeign = false

        if holdingForeign then
            R.hold.foreignName = curName
            if evRunning then
                releaseForeign = (cfg.releaseForeignHold ~= false)
                if releaseForeign and R._foreignLogged ~= curName then
                    R._foreignLogged = curName
                    log("事件 " .. tostring(R.event.title or evName) .. " 运行中，你手动手持的 "
                        .. tostring(curName) .. " 可能被突变 -> 自动放手", Color3.fromRGB(255, 200, 90))
                end
            elseif R._foreignLogged ~= curName then
                R._foreignLogged = curName
                log("你手动持有着 " .. tostring(curName) .. "（当前无事件，不会被烧）-> 脚本不干预，你随便看",
                    Color3.fromRGB(160, 200, 255))
            end
        else
            R._foreignLogged = nil
        end

        if (holdingOurs or releaseForeign) and cfg.releaseOnEventEnd then
            if R.hold.baseline then
                local s = fetchSummary()
                if s then R.summary = s; checkMutation(s) end
            end
            applyRelease(ending and "事件即将结束" or "非万圣节事件")
        end
        if not R._lastIdleScan or now - R._lastIdleScan > (tonumber(cfg.rescanIdle) or 10) then
            R._lastIdleScan = now
            refreshCandidates()
        end
        hotbarTick()
        return
    end

    -- === 万圣节进行中 ===
    if (not R._lastSummaryAt) or (now - R._lastSummaryAt >= (tonumber(cfg.pollSummary) or 1)) then
        refreshCandidates()
    end

    if R.hold.key and R.hold.baseline and R.summary then
        if checkMutation(R.summary) > 0 then
            advanceAfterHit(R.summary)
            return
        end
    end

    -- 你手动手持了某个候选角色 -> 直接接管它，不重复发包、不跟你抢
    if not R.hold.key then
        local curName0 = heldName()
        if curName0 then
            for _, c in ipairs(R.candidates) do
                if c.name == curName0 then
                    adoptHold(c.key, c.name, c.rarity)
                    return
                end
            end
        end
    end

    local curName = heldName()
    local inGrace = (R.hold.since or 0) + GRACE_SECONDS > now
    if R.hold.key and (curName == R.hold.name or inGrace) then
        return
    end

    if R.hold.key then
        R.hold.misses = (R.hold.misses or 0) + 1
        applyRelease("手持丢失")
    end

    if #R.candidates == 0 or (not R.summary) then refreshCandidates() end
    local pick = R.candidates[1]
    if pick then
        applyHold(pick.key, pick.name, pick.rarity)
        log("手持 " .. pick.name .. " [" .. pick.rarity .. "]")
    else
        log("没有可用的干净角色（检查品质勾选 / 是否都已突变）", Color3.fromRGB(255, 180, 80))
    end
end

local function mainLoop()
    return task.spawn(function()
        while isCurrent() do
            local interval = isHalloween() and (tonumber(cfg.pollHold) or 0.5) or (tonumber(cfg.pollIdle) or 3)
            local ok, err = pcall(tick)
            if not ok then
                log("loop error: " .. tostring(err), Color3.fromRGB(255, 120, 120))
                task.wait(1)
            end
            if R.renderStatus then pcall(R.renderStatus) end
            task.wait(interval)
        end
    end)
end

--============================================================== Obsidian 加载
local LIB_FILES = {
    Library = { file = "obsidian_Library.lua", url = OBSIDIAN_REPO .. "Library.lua" },
    SaveManager = { file = "obsidian_SaveManager.lua", url = OBSIDIAN_REPO .. "addons/SaveManager.lua" },
    ThemeManager = { file = "obsidian_ThemeManager.lua", url = OBSIDIAN_REPO .. "addons/ThemeManager.lua" },
}

local function loadObsidianLib(key, force)
    local info = LIB_FILES[key]
    if not info then return nil end
    local src
    if not force then src = readFileSafe(info.file) end
    if not src or #src < 1000 then
        local ok, fetched = pcall(function() return game:HttpGet(info.url) end)
        if ok and type(fetched) == "string" and #fetched > 1000 then
            src = fetched
            writeFileSafe(info.file, src)
        end
    end
    if not src or #src < 1000 then
        warn(PREFIX .. " 加载 " .. key .. " 失败（本地缓存与云端都不可用）")
        return nil
    end
    local fn, err = loadstring(src)
    if not fn then warn(PREFIX .. " loadstring " .. key .. ": " .. tostring(err)) return nil end
    local ok2, lib = pcall(fn)
    if not ok2 then warn(PREFIX .. " 运行 " .. key .. ": " .. tostring(lib)) return nil end
    return lib
end

R.reloadLibrary = function()
    log("重新下载 UI 库…")
    return loadObsidianLib("Library", true)
end

--============================================================== UI (Obsidian)
local E = {}          -- 元素引用
local uiBuilt = false

local function normMulti(sel)
    local out = {}
    if type(sel) == "table" then
        local hasBool = false
        for _, v in pairs(sel) do if type(v) == "boolean" then hasBool = true break end end
        if hasBool then
            for k, v in pairs(sel) do if v == true then out[tostring(k)] = true end end
        else
            for _, v in pairs(sel) do out[tostring(v)] = true end
        end
    elseif type(sel) == "string" and sel ~= "" then
        out[sel] = true
    end
    return out
end

local function applyCfgToUI()
    if not uiBuilt then return end
    pcall(function()
        E.tEnabled:SetValue(cfg.enabled == true)
        E.dRarities:SetValue(cfg.rarities)
        E.dTargets:SetValue(cfg.targets)
        E.dPriority:SetValue(tostring(cfg.priorityMode or "rarity"))
        E.tRelease:SetValue(cfg.releaseOnEventEnd ~= false)
        E.tForeign:SetValue(cfg.releaseForeignHold ~= false)
        E.tFrame:SetValue(cfg.nativeSelectionFrame ~= false)
        E.sLead:SetValue(tonumber(cfg.releaseLeadSeconds) or 1)
        E.tPotions:SetValue(cfg.autoStorePotions ~= false)
        E.tFill:SetValue(cfg.autoFillCandidates ~= false)
        E.iKeep:SetValue(tostring(cfg.keepPotionNames or ""))
        E.sInterval:SetValue(tonumber(cfg.hotbarInterval) or 3)
        E.tFirst:SetValue(cfg.hotbarCandidatesFirst ~= false)
        E.sMax:SetValue(tonumber(cfg.hotbarMaxItems) or 0)
        E.tGuard:SetValue(cfg.guardCheck ~= false)
        E.tPause:SetValue(cfg.pauseHotbar == true)
        if E.iExclude then E.iExclude:SetValue(tostring(cfg.hotbarExcludeChars or "")) end
        if E.sManual then E.sManual:SetValue(tonumber(cfg.manualOverrideSeconds) or 60) end
        E.tDriveUI:SetValue(cfg.clientDriveUI ~= false)
        E.tBlockPotion:SetValue(cfg.blockPotionInsert ~= false)
        if E.iKeybind then E.iKeybind:SetValue(tostring(cfg.menuKeybind or "RightShift")) end
        if R._library and R._library.Options and R._library.Options.MenuKeybind then
            pcall(function() R._library.Options.MenuKeybind:SetValue({ tostring(cfg.menuKeybind or "RightShift"), "Press" }) end)
        end
    end)
end

local function readUIIntoCfg()
    if not uiBuilt then return end
    pcall(function()
        cfg.enabled = E.tEnabled.Value == true
        cfg.rarities = normMulti(E.dRarities.Value)
        cfg.targets = normMulti(E.dTargets.Value)
        cfg.priorityMode = tostring(E.dPriority.Value or "rarity")
        cfg.releaseOnEventEnd = E.tRelease.Value == true
        cfg.releaseForeignHold = E.tForeign.Value == true
        cfg.nativeSelectionFrame = E.tFrame.Value == true
        cfg.releaseLeadSeconds = tonumber(E.sLead.Value) or 0
        cfg.autoStorePotions = E.tPotions.Value == true
        cfg.autoFillCandidates = E.tFill.Value == true
        cfg.keepPotionNames = tostring(E.iKeep.Value or "")
        cfg.hotbarInterval = tonumber(E.sInterval.Value) or 3
        cfg.hotbarCandidatesFirst = E.tFirst.Value == true
        cfg.hotbarMaxItems = tonumber(E.sMax.Value) or 0
        cfg.guardCheck = E.tGuard.Value == true
        cfg.pauseHotbar = E.tPause.Value == true
        if E.iExclude then cfg.hotbarExcludeChars = tostring(E.iExclude.Value or "") end
        if E.sManual then cfg.manualOverrideSeconds = tonumber(E.sManual.Value) or 60 end
        cfg.clientDriveUI = E.tDriveUI.Value == true
        cfg.blockPotionInsert = E.tBlockPotion.Value == true
        if E.iKeybind then cfg.menuKeybind = tostring(E.iKeybind.Value or cfg.menuKeybind) end
    end)
end

-- 清扫残留的 Obsidian ScreenGui（历史上 UI 堆积的遗留）
local function cleanupStaleObsidianUI()
    local containers = {}
    pcall(function()
        local h = gethui and gethui()
        if h then containers[#containers + 1] = h end
    end)
    pcall(function() containers[#containers + 1] = game:GetService("CoreGui") end)
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then containers[#containers + 1] = pg end

    local seen, removed = {}, 0
    for _, cont in ipairs(containers) do
        for _, c in ipairs(cont:GetChildren()) do
            if c:IsA("ScreenGui") and c.Name == "Obsidian" and not seen[c] then
                seen[c] = true
                pcall(function() c:Destroy() end)
                removed = removed + 1
            end
        end
    end
    return removed
end
R.cleanupStaleUI = cleanupStaleObsidianUI

local function buildUI()
    -- ⚠ 必须在加载 Obsidian 之前清扫：库在 loadstring 执行时就会创建自己的
    --   "Obsidian" ScreenGui，若在之后清扫会把新建的也一起删掉（导致 UI 消失）
    local stale = cleanupStaleObsidianUI()
    if stale > 0 then print(PREFIX .. " 清理残留 Obsidian UI: " .. stale .. " 个") end

    local Library = loadObsidianLib("Library")
    if not Library then
        warn(PREFIX .. " Obsidian 不可用，UI 跳过（核心逻辑继续运行）")
        return false
    end
    local ThemeManager = loadObsidianLib("ThemeManager")
    local SaveManager = loadObsidianLib("SaveManager")
    if not ThemeManager then warn(PREFIX .. " ThemeManager 不可用") end
    if not SaveManager then warn(PREFIX .. " SaveManager 不可用") end

    local Window = Library:CreateWindow({
        Title = "🎃 HW Mutator",
        Footer = "v" .. VERSION .. " · 万圣节自动突变",
        NotifySide = "Right",
        Resizable = true,
        ShowCustomCursor = false,
        ToggleKeybind = Enum.KeyCode.RightShift,
    })
    R._library = Library
    R.window = Window

    local Tabs = {
        Main = Window:AddTab("主控", "crosshair"),
        Hotbar = Window:AddTab("快捷栏", "layout-grid"),
        Log = Window:AddTab("记录", "scroll-text"),
        Config = Window:AddTab("配置", "settings"),
    }

    --================ 主控 / 状态
    local st = Tabs.Main:AddLeftGroupbox("运行状态", "activity")
    E.lEvent = st:AddLabel("事件: 初始化…", true)
    E.lHeld = st:AddLabel("手持: 无", true)
    E.lStats = st:AddLabel("—", true)
    st:AddDivider()
    st:AddLabel("候选角色（优先级 高 → 低，最多显示 10）", true)
    E.lCands = st:AddLabel("—", true)

    --================ 主控 / 设置
    local se = Tabs.Main:AddRightGroupbox("突变设置", "sliders-horizontal")
    E.tEnabled = se:AddToggle("enabled", {
        Text = "启用自动手持", Default = cfg.enabled == true,
        Tooltip = "仅在万圣节(Halloween)事件期间手持；其他事件一律放手，避免烧掉角色",
    })
    E.dRarities = se:AddDropdown("rarities", {
        Text = "目标品质（优先级自动按品质高低）",
        Values = RARITY_LIST, Multi = true, Searchable = true,
        Default = cfg.rarities,
        Tooltip = "只有选中的品质会被纳入候选。优先级自动：品质越高越优先（Ancient > Celestial）",
    })
    E.dTargets = se:AddDropdown("targets", {
        Text = "认可的突变", Values = { "Dracula", "Demonic" },
        Multi = true, Default = cfg.targets,
    })
    E.dPriority = se:AddDropdown("priorityMode", {
        Text = "候选优先级",
        Values = {
            rarity = "品质优先 → 同品质按赚钱速度",
            cps = "纯赚钱速度优先",
            rarityOnly = "品质优先 → 按名字",
        },
        Default = tostring(cfg.priorityMode or "rarity"), Multi = false,
        Tooltip = "同品质角色赚钱速度不同（就是游戏里显示的 $xx/s）。默认让 145M/s 排在 125M/s 前面",
    })
    se:AddDivider()
    E.tRelease = se:AddToggle("releaseOnEventEnd", {
        Text = "非万圣节立即放手", Default = cfg.releaseOnEventEnd ~= false,
        Tooltip = "关键安全项：事件一变成别的（或结束）就放手，防止角色被其他突变烧掉",
    })
    E.sLead = se:AddSlider("releaseLeadSeconds", {
        Text = "提前放手", Default = tonumber(cfg.releaseLeadSeconds) or 1,
        Min = 0, Max = 10, Rounding = 0, Suffix = " 秒",
    })
    E.tForeign = se:AddToggle("releaseForeignHold", {
        Text = "事件期间连你手动持的也放手 ★", Default = cfg.releaseForeignHold ~= false,
        Tooltip = "只在「别的突变事件正在运行」时才放手（那时你的角色会被烧）。没有任何事件时脚本完全不干涉，你可以自由持有查看，角色会正常出现在身边。",
    })
    E.tFrame = se:AddToggle("nativeSelectionFrame", {
        Text = "手持时显示原生蓝框 ★", Default = cfg.nativeSelectionFrame ~= false,
        Tooltip = "自动手持时，让游戏里对应的快捷栏槽位显示和手动点击一模一样的蓝色选中描边",
    })
    se:AddDivider()
    se:AddButton({ Text = "立刻扫描背包", Icon = "refresh-cw", Func = function()
        refreshCandidates(); log("扫描完成，候选 " .. #R.candidates); manageHotbar(true)
    end })
    se:AddButton({ Text = "手动手持最高优先级", Icon = "hand", Func = function()
        if #R.candidates > 0 then
            local c = R.candidates[1]
            applyHold(c.key, c.name, c.rarity); log("手动手持 " .. c.name)
        else log("无候选") end
    end })
    se:AddButton({ Text = "放手", Icon = "undo-2", Func = function() applyRelease("手动") end })
    se:AddButton({ Text = "保存配置到文件", Icon = "save", Func = function() saveConfig() end })

    --================ 快捷栏
    local hb1 = Tabs.Hotbar:AddLeftGroupbox("快捷栏管理", "layout-grid")
    E.tPause = hb1:AddToggle("pauseHotbar", {
        Text = "⏸ 暂停接管（手动整理时打开）★", Default = cfg.pauseHotbar == true,
        Tooltip = "打开后脚本完全放手：不再改布局、不再推送界面、并恢复游戏默认的药水插入，让你自由手动整理快捷栏",
    })
    hb1:AddLabel('<font color="rgb(170,170,190)">提示：只要你在游戏里点/右键快捷栏槽位，脚本会自动让路 '
        .. tostring(cfg.manualOverrideSeconds or 60) .. ' 秒，不跟你抢。</font>', true)
    hb1:AddButton({ Text = "给我 60 秒自由整理", Icon = "timer", Func = function()
        extendManual(60, "按钮")
        log("已让路 60 秒，期间可自由增删快捷栏")
    end })
    hb1:AddDivider()
    E.dExclude = hb1:AddDropdown("excludeCandidate", {
        Text = "把某个候选移出快捷栏", Values = {}, Multi = false, AllowNull = true,
        Tooltip = "选中某个候选 -> 加入排除名单，不再自动放进快捷栏（清空下面输入框即可恢复）",
    })
    E.sManual = hb1:AddSlider("manualOverrideSeconds", {
        Text = "手动操作后让路时长", Default = tonumber(cfg.manualOverrideSeconds) or 60,
        Min = 10, Max = 300, Rounding = 0, Suffix = " 秒",
        Tooltip = "你一碰快捷栏，脚本就让路这么久，不跟你抢",
    })
    E.tPotions = hb1:AddToggle("autoStorePotions", {
        Text = "药水自动存入背包", Default = cfg.autoStorePotions ~= false,
        Tooltip = "把药水类工具从快捷栏布局里移除（= 收进背包），鱼竿不受影响",
    })
    E.tFill = hb1:AddToggle("autoFillCandidates", {
        Text = "候选角色自动进快捷栏", Default = cfg.autoFillCandidates ~= false,
        Tooltip = "把当前候选的干净角色放进快捷栏，方便你随时观察",
    })
    E.iKeep = hb1:AddInput("keepPotionNames", {
        Text = "保留在快捷栏的药水名", Default = tostring(cfg.keepPotionNames or ""),
        Placeholder = "逗号分隔，例如: Honey Potion", Finished = true,
        Tooltip = "填在这里的药水不会被自动收起",
    })
    E.iExclude = hb1:AddInput("hotbarExcludeChars", {
        Text = "不塞进快捷栏的角色名", Default = tostring(cfg.hotbarExcludeChars or ""),
        Placeholder = "逗号分隔，例如: Elfaria, Miki", Finished = true,
        Tooltip = "这些角色不会被自动放进快捷栏（想手动取舍某个候选时用）",
    })
    E.sInterval = hb1:AddSlider("hotbarInterval", {
        Text = "整理间隔", Default = tonumber(cfg.hotbarInterval) or 3,
        Min = 1, Max = 30, Rounding = 0, Suffix = " 秒",
    })
    E.tFirst = hb1:AddToggle("hotbarCandidatesFirst", {
        Text = "候选角色排在快捷栏最前", Default = cfg.hotbarCandidatesFirst ~= false,
        Tooltip = "关闭则追加到末尾，完全保持你原来的顺序",
    })
    E.sMax = hb1:AddSlider("hotbarMaxItems", {
        Text = "快捷栏最大项数", Default = tonumber(cfg.hotbarMaxItems) or 0,
        Min = 0, Max = 80, Rounding = 0,
        Tooltip = "0 = 不限（默认，非破坏式）。游戏客户端会自己把新钓到的角色不断塞进快捷栏，"
            .. "如果觉得乱，设为 12 左右即可保持整洁（候选角色会优先占位）",
    })
    E.tGuard = hb1:AddToggle("guardCheck", {
        Text = "自检并自动纠正", Default = cfg.guardCheck ~= false,
        Tooltip = "周期性直接读服务器布局，一旦发现药水混进快捷栏就立刻纠正并写日志",
    })
    E.tDriveUI = hb1:AddToggle("clientDriveUI", {
        Text = "同步到游戏快捷栏界面 ★", Default = cfg.clientDriveUI ~= false,
        Tooltip = "关键项。游戏的快捷栏 UI 由客户端本地状态驱动；必须重置它的一次性守卫并调用其 applyServerLayout，界面才会显示候选角色",
    })
    E.tBlockPotion = hb1:AddToggle("blockPotionInsert", {
        Text = "拦截药水插入 ★", Default = cfg.blockPotionInsert ~= false,
        Tooltip = "禁用客户端 PotionHotbarInsert 处理器，从源头阻止药水进入快捷栏",
    })
    hb1:AddLabel('<font color="rgb(170,170,190)">提示：实测服务器对快捷栏数量没有上限，'
        .. '增长来自游戏客户端自动插入新角色。药水会被本脚本自动收起。</font>', true)
    hb1:AddDivider()
    hb1:AddButton({ Text = "立刻整理快捷栏", Icon = "wand-2", Func = function()
        manageHotbar(true); log("已整理快捷栏")
    end })
    hb1:AddButton({ Text = "清空快捷栏（只留鱼竿等非角色项）", Icon = "eraser", Func = function()
        local cur = getLayout() or {}
        local keep = {}
        for _, k in ipairs(cur) do
            if not isPotionKey(k) and k:sub(1, 2) ~= "C|" then keep[#keep + 1] = k end
        end
        setLayout(keep)
        clientApplyLayout(keep)
        R.hotbar.layout = keep
        log("已清空快捷栏，保留 " .. #keep .. " 项非角色项")
    end })
    hb1:AddButton({ Text = "读取当前布局", Icon = "refresh-cw", Func = function()
        local cur = getLayout()
        if cur then
            R.hotbar.layout = cur
            log("当前布局(" .. #cur .. "): " .. table.concat(cur, " , "))
        else log("读取布局失败") end
    end })

    local hb2 = Tabs.Hotbar:AddRightGroupbox("当前快捷栏", "list")
    E.lHotbar = hb2:AddLabel("—", true)
    hb2:AddDivider()
    E.lHotbarStatus = hb2:AddLabel("—", true)
    hb2:AddDivider()
    hb2:AddLabel("快捷键: 右 Shift 开/关窗口（可在“配置”页修改）", true)
    hb2:AddButton({ Text = "重新下载 UI 库（更新 Obsidian）", Icon = "download", Func = function()
        local lib = R.reloadLibrary()
        log(lib and "UI 库已更新（重进/重载脚本后生效）" or "UI 库更新失败")
    end })

    --================ 记录
    local lg = Tabs.Log:AddLeftGroupbox("日志", "scroll-text")
    E.lLog = lg:AddLabel("—", true)

    --================ 界面（自定义菜单快捷键）
    do
        local uiBox = Tabs.Config:AddLeftGroupbox("界面", "settings-2")
        uiBox:AddLabel("菜单开关快捷键：点下面按钮右侧的键位框，然后按下你想用的键", true)
        local kbBtn = uiBox:AddButton({
            Text = "菜单开关快捷键", Icon = "keyboard",
            Func = function() end,
        })
        if kbBtn and kbBtn.AddKeyPicker then
            local ok = pcall(function()
                kbBtn:AddKeyPicker("MenuKeybind", {
                    Text = "菜单开关",
                    Default = tostring(cfg.menuKeybind or "RightShift"),
                    NoUI = true,
                    Mode = "Press",            -- Button 上的 KeyPicker 只支持 Press
                    ChangedCallback = function(key)
                        local name = tostring(key):match("%.([%w_]+)$") or tostring(key)
                        cfg.menuKeybind = name
                        if E.iKeybind then E.iKeybind:SetValue(name) end
                        log("菜单快捷键 -> " .. name)
                    end,
                })
                if Library.Options and Library.Options.MenuKeybind then
                    Library.ToggleKeybind = Library.Options.MenuKeybind
                end
            end)
            if not ok then
                uiBox:AddLabel('<font color="rgb(255,180,80)">KeyPicker 不可用，请用下方输入框填写按键名</font>', true)
            end
        else
            uiBox:AddLabel('<font color="rgb(255,180,80)">本库不支持 KeyPicker，请用下方输入框填写按键名（如 RightShift）</font>', true)
        end
        E.iKeybind = uiBox:AddInput("menuKeybind", {
            Text = "按键名（备用）", Default = tostring(cfg.menuKeybind or "RightShift"),
            Placeholder = "RightShift / F1 / Q ...", Finished = true,
            Tooltip = "填好后按回车生效；需重新打开脚本或点保存配置",
        })
        uiBox:AddButton({ Text = "保存配置（含快捷键）", Icon = "save", Func = function() saveConfig() end })
    end

    --================ 配置
    if SaveManager then
        SaveManager:SetLibrary(Library)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
        SaveManager:SetFolder("HW_Mutator")
        SaveManager:BuildConfigSection(Tabs.Config)
    end
    if ThemeManager then
        ThemeManager:SetLibrary(Library)
        ThemeManager:SetFolder("HW_Mutator")
        ThemeManager:ApplyToTab(Tabs.Config)
    end

    --================ 回调（先建元素再挂回调）
    E.tEnabled:OnChanged(function(v) cfg.enabled = v == true end)
    E.dRarities:OnChanged(function(v) cfg.rarities = normMulti(v); refreshCandidates(); manageHotbar(true) end)
    E.dTargets:OnChanged(function(v) cfg.targets = normMulti(v) end)
    E.dPriority:OnChanged(function(v)
        cfg.priorityMode = tostring(v or "rarity")
        refreshCandidates()
        manageHotbar(true)
    end)
    E.tRelease:OnChanged(function(v) cfg.releaseOnEventEnd = v == true end)
    E.tForeign:OnChanged(function(v)
        cfg.releaseForeignHold = v == true
        log(cfg.releaseForeignHold and "已开启：有事件运行时，连你手动持的角色也一起放手"
            or "已关闭：完全不碰你手动持的角色")
    end)
    E.tFrame:OnChanged(function(v)
        cfg.nativeSelectionFrame = v == true
        if not cfg.nativeSelectionFrame then clientClearSelection() end
    end)
    E.sLead:OnChanged(function(v) cfg.releaseLeadSeconds = tonumber(v) or 0 end)
    E.tPotions:OnChanged(function(v) cfg.autoStorePotions = v == true; manageHotbar(true) end)
    E.tFill:OnChanged(function(v) cfg.autoFillCandidates = v == true; manageHotbar(true) end)
    E.iKeep:OnChanged(function(v) cfg.keepPotionNames = tostring(v or ""); manageHotbar(true) end)
    E.sInterval:OnChanged(function(v) cfg.hotbarInterval = tonumber(v) or 3 end)
    E.tFirst:OnChanged(function(v) cfg.hotbarCandidatesFirst = v == true; manageHotbar(true) end)
    E.sMax:OnChanged(function(v) cfg.hotbarMaxItems = tonumber(v) or 0; manageHotbar(true) end)
    E.tGuard:OnChanged(function(v) cfg.guardCheck = v == true end)
    E.tPause:OnChanged(function(v)
        cfg.pauseHotbar = v == true
        if cfg.pauseHotbar then
            pauseHotbarControl()
            log("⏸ 已暂停快捷栏接管（现在可以自由手动整理）", Color3.fromRGB(255, 200, 90))
        else
            log("▶ 已恢复快捷栏接管")
            manageHotbar(true)
        end
    end)
    if E.iExclude then
        E.iExclude:OnChanged(function(v)
            cfg.hotbarExcludeChars = tostring(v or "")
            manageHotbar(true)
        end)
    end
    if E.dExclude then
        E.dExclude:OnChanged(function(v)            if type(v) ~= "string" or v == "" then return end
            local set = {}
            for piece in tostring(cfg.hotbarExcludeChars or ""):gmatch("[^,，]+") do
                local t = piece:match("^%s*(.-)%s*$")
                if t ~= "" then set[t] = true end
            end
            set[v] = true
            local list = {}
            for k in pairs(set) do list[#list + 1] = k end
            table.sort(list)
            cfg.hotbarExcludeChars = table.concat(list, ", ")
            if E.iExclude then E.iExclude:SetValue(cfg.hotbarExcludeChars) end
            log("已把 " .. v .. " 移出快捷栏（加入排除名单）")
            manageHotbar(true)
        end)
    end
    if E.sManual then
        E.sManual:OnChanged(function(v) cfg.manualOverrideSeconds = tonumber(v) or 60 end)
    end
    E.tDriveUI:OnChanged(function(v) cfg.clientDriveUI = v == true; manageHotbar(true) end)
    E.tBlockPotion:OnChanged(function(v) cfg.blockPotionInsert = v == true; manageHotbar(true) end)
    if E.iKeybind then
        E.iKeybind:OnChanged(function(v)
            local name = tostring(v or ""):match("^%s*(.-)%s*$")
            if name == "" then return end
            cfg.menuKeybind = name
            local kc = Enum.KeyCode[name]
            if kc and R._library then
                -- 输入框模式：直接用 KeyCode（库同时支持 KeyCode 与 KeyPicker 对象）
                pcall(function() R._library.ToggleKeybind = kc end)
            end
            log("菜单快捷键 -> " .. name)
        end)
    end

    --================ 渲染函数
    function R.renderStatus()
        if not E.lEvent then return end
        local ev, h = R.event, R.hold
        local forcedNow = R._force ~= nil and os.clock() < (R._force.until_ or 0)
        if forcedNow then
            E.lEvent:SetText('<font color="rgb(255,200,90)">事件: [强制] ' .. tostring(R._force.name)
                .. string.format('  剩 %.0fs</font>', (R._force.until_ or 0) - os.clock()))
        elseif ev.active and ev.name then
            local secs = math.floor(eventRemaining())
            local hl = (ev.name == EVENT_NAME)
            E.lEvent:SetText(string.format('%s事件: %s (%s)  剩余 %d:%02d</font>',
                hl and '<font color="rgb(120,255,140)">' or '<font color="rgb(255,200,90)">',
                tostring(ev.title or ev.name), tostring(ev.name), math.floor(secs / 60), secs % 60))
        else
            E.lEvent:SetText('<font color="rgb(255,110,110)">事件: 无</font>')
        end

        if h.key then
            E.lHeld:SetText(string.format('<font color="rgb(120,255,140)">手持: %s [%s]</font>  (%.0fs)',
                tostring(h.name), tostring(h.rarity), os.clock() - (h.since or os.clock())))
        else
            E.lHeld:SetText('手持: <font color="rgb(160,160,180)">无</font>')
        end

        E.lStats:SetText(string.format('候选 %d 个  |  Dracula %d · Demonic %d · 其他 %d · 尝试 %d',
            #R.candidates, R.stats.dracula, R.stats.demonic, R.stats.other, R.stats.attempts))

        local lines = {}
        for i, c in ipairs(R.candidates) do
            if i > 10 then lines[#lines + 1] = "  …" break end
            local mark = (h.key == c.key) and "▶ " or "  "
            lines[#lines + 1] = string.format("%s%d. %s  %s", mark, i,
                colored(c.name .. "  [" .. c.rarity .. "]", RARITY_COLORS[c.rarity]),
                colored(fmtCps(c.cps), Color3.fromRGB(140, 230, 150)))
        end
        if #lines == 0 then lines[1] = "  （无可选干净角色 — 检查品质勾选 / 是否都已突变）" end
        E.lCands:SetText(table.concat(lines, "\n"))

        local hl = {}
        for i, k in ipairs(R.hotbar.layout or {}) do
            local tag = isPotionKey(k) and ' <font color="rgb(255,150,150)">[药水]</font>' or ""
            hl[#hl + 1] = string.format("%2d. %s%s", i, k, tag)
        end
        if #hl == 0 then hl[1] = "  （未读取，点“读取当前布局”）" end
        E.lHotbar:SetText(table.concat(hl, "\n"))

        if E.lHotbarStatus then
            local pot = tonumber(R.hotbar.livePotions) or 0
            local blocked = tonumber(R.hotbar.blocked) or 0
            local hits = tonumber(R.hotbar.guardHits) or 0
            local uiSync = tonumber(R.hotbar.clientApplied) or 0
            local uiSlots = tonumber(R.hotbar.uiSlots) or 0
            local health = (pot == 0) and '<font color="rgb(120,255,140)">正常</font>'
                or ('<font color="rgb(255,110,110)">异常 %d 个药水</font>'):format(pot)
            local potConn = R.hotbar.potionConnEnabled
            local potState
            if cfg.blockPotionInsert == false then
                potState = '<font color="rgb(255,200,90)">未启用</font>'
            elseif potConn == false then
                potState = '<font color="rgb(120,255,140)">已禁用</font>'
            elseif potConn == true then
                potState = '<font color="rgb(255,110,110)">仍启用</font>'
            else
                potState = '<font color="rgb(255,200,90)">未知</font>'
            end
            local drive = (cfg.clientDriveUI ~= false) and '<font color="rgb(120,255,140)">开</font>'
                or '<font color="rgb(255,200,90)">关</font>'
            local remain = (R.hotbar.manualUntil or 0) - os.clock()
            if cfg.pauseHotbar then
                E.lHotbarStatus:SetText('<font color="rgb(255,200,90)">⏸ 已暂停接管 —— 快捷栏完全由你手动控制</font>\n'
                    .. string.format('游戏UI %d 槽 · 药水 %d', uiSlots, pot))
            elseif remain > 0 then
                E.lHotbarStatus:SetText(string.format(
                    '<font color="rgb(255,200,90)">✋ 你在手动整理，脚本让路中（剩 %.0f 秒）</font>\n游戏UI %d 槽 · 药水 %d',
                    remain, uiSlots, pot))
            else
                E.lHotbarStatus:SetText(string.format(
                    '服务器布局 %d 项 · 药水 %d · 自检 %s\n游戏UI %d 槽 · 已同步 %d 次 · 界面驱动 %s\n药水插入处理器 %s · 自检纠正 %d 次',
                    tonumber(R.hotbar.liveCount) or 0, pot, health, uiSlots, uiSync, drive, potState, hits))
            end
        end
        -- 候选名字下拉（让"移出快捷栏"一键可用）
        if E.dExclude then
            local names = {}
            for _, c in ipairs(R.candidates) do names[#names + 1] = c.name end
            table.sort(names)
            local sig = table.concat(names, "|")
            if R._lastExcludeSig ~= sig then
                R._lastExcludeSig = sig
                if #names > 0 then pcall(function() E.dExclude:SetValues(names) end) end
            end
        end
    end

    function R.renderLog()
        if not E.lLog then return end
        local lines = {}
        local shown = 0
        for i = #R.log, 1, -1 do
            shown = shown + 1
            if shown > 25 then break end
            local e = R.log[i]
            lines[#lines + 1] = colored(string.format("[%s] %s", e.t, e.msg), e.color)
        end
        if #lines == 0 then lines[1] = "（暂无日志）" end
        E.lLog:SetText(table.concat(lines, "\n"))
    end

    function R.notify(info)
        pcall(function() Library:Notify(info) end)
    end

    uiBuilt = true
    -- 配置恢复顺序：我的 JSON -> SaveManager 自动配置（若已设置）
    applyCfgToUI()
    readUIIntoCfg()
    if SaveManager then
        pcall(function() SaveManager:LoadAutoloadConfig() end)
        task.delay(1, function()
            readUIIntoCfg()
            refreshCandidates()
            manageHotbar(true)
        end)
    end
    R.renderStatus()
    R.renderLog()
    return true
end

R.resurface = function()
    if R.window then pcall(function() R.window:Toggle(true) end) end
    if R.renderStatus then pcall(R.renderStatus) end
end

R.destroy = function()
    R.alive = false
    R.gen = (R.gen or 0) + 1
    for _, c in ipairs(R.connections or {}) do pcall(function() c:Disconnect() end) end
    R.connections = {}
    for _, t in ipairs(R.threads or {}) do pcall(function() task.cancel(t) end) end
    R.threads = {}
    pcall(doRelease)
    if R.restoreClientInsertHooks then pcall(R.restoreClientInsertHooks) end
    if R.unhookHotbar then pcall(R.unhookHotbar) end
    if R._library then
        if R._library.Unload then pcall(function() R._library:Unload() end) end
        local sg = R._library.ScreenGui
        if sg then pcall(function() sg:Destroy() end) end
    end
    R.renderStatus, R.renderLog, R.notify, R.resurface = nil, nil, nil, nil
    print(PREFIX .. " destroyed")
end

--============================================================== 公开 API
R.on = function() cfg.enabled = true; log("API: on") end
R.off = function() cfg.enabled = false; applyRelease("API off"); log("API: off") end
R.scan = function()
    if not refreshCandidates() then print(PREFIX .. " scan failed") return end
    print(PREFIX .. " candidates = " .. #R.candidates)
    for i, c in ipairs(R.candidates) do
        print(string.format("%s %2d. %-24s %-12s x%d", PREFIX, i, c.name, c.rarity, c.count))
    end
end
R.save = saveConfig
R.reload = function() loadConfig(); applyCfgToUI(); readUIIntoCfg(); refreshCandidates(); if R.renderLog then R.renderLog() end end
R.status = function()
    print(string.format("%s v%s event=%s active=%s rem=%s | held=%s | cands=%d | D=%d M=%d other=%d attempts=%d | hotbar=%d",
        PREFIX, tostring(VERSION), tostring(R.event.name), tostring(R.event.active), tostring(R.event.remaining),
        tostring(R.hold.name), #R.candidates, R.stats.dracula, R.stats.demonic, R.stats.other, R.stats.attempts,
        #(R.hotbar.layout or {})))
end
R.holdKey = function(key)
    refreshCandidates()
    for _, c in ipairs(R.candidates) do
        if c.key == key or c.name == key then
            applyHold(c.key, c.name, c.rarity); log("API: hold " .. c.name); return
        end
    end
    warn(PREFIX .. " 未在候选中找到: " .. tostring(key))
end
R.release = function() applyRelease("API") end

-- 正式诊断：注意不能用 `a == b` 判"是否已接管"，双方都是 nil 时会假阳性
R.diag = function()
    local potionNameCount = 0
    for _ in pairs(POTION_NAMES) do potionNameCount = potionNameCount + 1 end
    local d = {
        version = VERSION,
        alive = R.alive,
        enabled = cfg.enabled,
        autoStorePotions = cfg.autoStorePotions,
        autoFillCandidates = cfg.autoFillCandidates,
        guardCheck = cfg.guardCheck,
        clientDriveUI = cfg.clientDriveUI,
        blockPotionInsert = cfg.blockPotionInsert,
        pauseHotbar = cfg.pauseHotbar,
        manualRemainSec = math.max(0, math.floor((R.hotbar.manualUntil or 0) - os.clock())),
        manualOverrideSeconds = cfg.manualOverrideSeconds,
        hotbarExcludeChars = tostring(cfg.hotbarExcludeChars),
        menuKeybind = tostring(cfg.menuKeybind),
        priorityMode = tostring(cfg.priorityMode),
        nativeSelectionFrame = cfg.nativeSelectionFrame,
        releaseForeignHold = cfg.releaseForeignHold,
        clientEnvFound = (CLIENT_G ~= nil),
        selectionUpvalueIdx = (CLIENT_SEL.idx or 0),
        eventRemainSmooth = math.floor(eventRemaining()),
        topCandidate = (R.candidates[1] and (R.candidates[1].name .. "/" .. tostring(R.candidates[1].cps))) or "none",
        candidates = #R.candidates,
        potionNameTableSize = potionNameCount,
        namecallHook = (_G.__HW_NC_HOOK ~= nil),
        hasGetConnections = type(getconnections) == "function",
        hasLayoutLateRemote = RF.layoutLate ~= nil,
        hasPotionInsertRemote = RF.potionInsert ~= nil,
        uiSyncCount = R.hotbar.clientApplied or 0,      -- applyServerLayout 成功调用次数
        uiSlots = R.hotbar.uiSlots,                     -- 游戏快捷栏 UI 实际槽位数
        potionConnEnabled = R.hotbar.potionConnEnabled, -- false = 客户端药水插入处理器已禁用
        blocked = R.hotbar.blocked or 0,
        guardHits = R.hotbar.guardHits or 0,
        liveCount = R.hotbar.liveCount,
        livePotions = R.hotbar.livePotions,
    }
    local parts = {}
    for k, v in pairs(d) do parts[#parts + 1] = k .. "=" .. tostring(v) end
    table.sort(parts)
    print(PREFIX .. " DIAG " .. table.concat(parts, "  "))
    return d
end

-- 手动触发一次完整同步（UI + 服务器布局 + 药水拦截）
R.syncUI = function()
    manageHotbar(true)
    if R.renderStatus then pcall(R.renderStatus) end
    return R.hotbar.layout
end

-- 提前结束让路 / 恢复接管
R.resumeHotbar = function()    R.hotbar.manualUntil = 0
    cfg.pauseHotbar = false
    manageHotbar(true)
    log("▶ 已恢复快捷栏接管")
    if R.renderStatus then pcall(R.renderStatus) end
end
R.letGo = function(sec)
    extendManual(sec or 60, "API")
    return R.hotbar.manualUntil
end

-- 原生选中（蓝框）诊断与手动测试
R.selectKey = function(key)
    local k = key or R.hold.key
    if not k then return false, "没有 key" end
    return clientSetSelected(k)
end
R.clearSelection = function() return clientClearSelection() end
R.clientEnvDiag = function()
    local g = clientG()
    if not g then return "客户端环境表未找到（getgc 不可用？）" end
    local n = 0
    for k in pairs(g) do
        if type(k) == "string" and (k:sub(1, 3) == "CF_" or k:sub(1, 5) == "__BP_") then n = n + 1 end
    end
    local visit = selectionVisuals()
    local idx = CLIENT_SEL.idx
    local sel = "?"
    if type(rawget(g, "CF_BackpackGetSelected")) == "function" then
        local ok, v = pcall(g.CF_BackpackGetSelected)
        if ok then sel = tostring(v) end
    end
    -- 检查当前选中槽位是否真的带上了 SelectionStroke
    local strokes = {}
    local bar = LocalPlayer.PlayerGui.MainGui:FindFirstChild("BackpackHotBar")
    if bar then
        for _, s in ipairs(bar:GetChildren()) do
            if s.Name:match("^Slot_%d+$") and s:FindFirstChild("SelectionStroke") then
                strokes[#strokes + 1] = s.Name
            end
        end
    end
    return string.format("客户端表OK · BP/CF键=%d · 视觉函数=%s · 选中upvalue idx=%s · 当前选中=%s · 带描边槽位=%s",
        n, tostring(visit ~= nil), tostring(idx), sel,
        (#strokes > 0) and table.concat(strokes, ",") or "无")
end

-- 测试：触发服务器的 PotionHotbarInsert 事件，验证药水是否被拦下
R.testPotionBlock = function(potionName)
    local name = tostring(potionName or "Luck Potion Lvl. 1")
    if type(firesignal) ~= "function" or not RF.potionInsert then
        print(PREFIX .. " testPotionBlock: firesignal 不可用")
        return nil
    end
    local ok, err = pcall(function() firesignal(RF.potionInsert.OnClientEvent, name) end)
    log("测试：触发 PotionHotbarInsert(" .. name .. ") ok=" .. tostring(ok))
    task.delay(2.5, function()
        local live = getLayout() or {}
        local pot = 0
        for _, k in ipairs(live) do if isPotionKey(k) then pot = pot + 1 end end
        local good = (pot == 0)
        log(string.format("测试结果: 快捷栏药水=%d · 客户端处理器启用=%s -> %s",
            pot, tostring(R.hotbar.potionConnEnabled), good and "拦截成功" or "未拦住"),
            good and Color3.fromRGB(120, 255, 140) or Color3.fromRGB(255, 110, 110))
        if R.renderStatus then pcall(R.renderStatus) end
    end)
    return ok
end
R.tidyHotbar = function(force) manageHotbar(force ~= false); return R.hotbar.layout end
R.debugForce = function(name, seconds)
    R._force = { name = tostring(name or EVENT_NAME), until_ = os.clock() + (tonumber(seconds) or 15) }
    log("debug: 强制事件 " .. R._force.name .. " " .. tostring(seconds or 15) .. "s（注意风险）", Color3.fromRGB(255, 200, 90))
end
R.debugClear = function() R._force = nil; log("debug: 已清除强制事件") end
R.selftest = function()
    local b1 = { ["C|Test|"] = { ty = "", c = 1 } }
    local s1 = { ["C|Test|"] = { ty = "", c = 1, n = "Test", ra = "Ancient" },
                 ["C|Test|Dracula|"] = { ty = "Dracula", c = 1, n = "Test", ra = "Ancient" } }
    local h1 = detectMutation(b1, s1, "Test")
    local ok1 = (#h1 == 1 and h1[1].ty == "Dracula")
    local b2 = { ["C|Test|Demonic|"] = { ty = "Demonic", c = 1 } }
    local s2 = { ["C|Test|Demonic|"] = { ty = "Demonic", c = 2, n = "Test", ra = "Ancient" } }
    local h2 = detectMutation(b2, s2, "Test")
    local ok2 = (#h2 == 1 and h2[1].ty == "Demonic")
    local b3 = { ["C|Test|"] = { ty = "", c = 1 } }
    local s3 = { ["C|Test|"] = { ty = "", c = 3, n = "Test", ra = "Ancient" } }
    local ok3 = (#detectMutation(b3, s3, "Test") == 0)
    local b4 = { ["C|Test|"] = { ty = "", c = 3 } }
    local s4 = { ["C|Test|"] = { ty = "", c = 1, n = "Test", ra = "Ancient" } }
    local ok4 = (#detectMutation(b4, s4, "Test") == 0)
    local b5 = { ["C|Test|"] = { ty = "", c = 1 } }
    local s5 = { ["C|Test|"] = { ty = "", c = 1, n = "Test", ra = "Ancient" },
                 ["C|Other|Blood|"] = { ty = "Blood", c = 1, n = "Other", ra = "Ancient" } }
    local ok5 = (#detectMutation(b5, s5, "Test") == 0)
    -- 快捷栏布局（非破坏式：只减药水 + 补候选）
    local cur = { "T|Rod of the Heavens", "T|Luck Potion Lvl. 1", "C|Kafka|" }
    local tgt = computeTargetLayout(cur, { { key = "C|Elfaria|" } }, true)
    -- 预期: Elfaria(候选置顶) + 鱼竿 + Kafka(原样保留) = 3；药水被剔除
    local ok6 = (#tgt == 3 and tgt[1] == "C|Elfaria|" and tgt[2] == "T|Rod of the Heavens" and tgt[3] == "C|Kafka|")
    local ok7 = isPotionKey("T|Luck Potion Lvl. 1") and (not isPotionKey("T|Rod of the Heavens"))
    -- 不限数量：原有角色键全部保留，不截断
    local tgt2 = computeTargetLayout({ "C|A|", "C|B|", "C|C|", "T|Rod of the Heavens" }, { { key = "C|New|" } }, true)
    local ok8 = (#tgt2 == 5)
    -- 未开启自动填充时：只减药水，不追加候选、不动角色键
    local tgt3 = computeTargetLayout({ "C|Old|", "T|Luck Potion Lvl. 1" }, { { key = "C|New|" } }, false)
    local ok9 = (#tgt3 == 1 and tgt3[1] == "C|Old|")
    print(string.format("%s selftest: newKey=%s countGrowth=%s cleanGrow=%s cleanShrink=%s otherChar=%s hotbar=%s potion=%s dropMutated=%s keepNoFill=%s",
        PREFIX, tostring(ok1), tostring(ok2), tostring(ok3), tostring(ok4), tostring(ok5),
        tostring(ok6), tostring(ok7), tostring(ok8), tostring(ok9)))
    return ok1 and ok2 and ok3 and ok4 and ok5 and ok6 and ok7 and ok8 and ok9
end

--============================================================== 启动
killOrphans()
do
    local ok, err = pcall(buildUI)
    if not ok then
        R.uiError = tostring(err)
        warn(PREFIX .. " UI 构建失败: " .. tostring(err))
    end
end

refreshEvent()
refreshCandidates()
-- ⚠ 不安装 __namecall hook 了：实测它会破坏游戏自身的 FireServer
--   （对照实验：装 hook 时 setHB:FireServer 报 "attempt to call a nil value"；摘掉后正常）
--   这正是"右键快捷栏失效"的根因。服务器布局改由下面两条保证：
--     1) clientApplyLayout -> 客户端自己的 queueSaveLayout 会把我们的布局发给服务器
--     2) 周期性 setLayout(target) 兜底纠正
--   函数保留在文件里（config.useNamecallHook 可手动打开），默认不用。
-- 清掉历史版本（<=v22）留下的 __namecall hook，否则右键快捷栏依然会失效
if (not cfg.useNamecallHook) and type(_G.__HW_NC_ORIG) == "function" then
    pcall(function() hookmetamethod(game, "__namecall", _G.__HW_NC_ORIG) end)
    _G.__HW_NC_HOOK, _G.__HW_NC_ORIG = nil, nil
    print(PREFIX .. " 已移除历史 __namecall hook（恢复游戏原生 FireServer）")
end
if cfg.useNamecallHook then installHotbarHook() else R.unhookHotbar = nil end
hookHotbarSlots()
manageHotbar(true)
R.threads[#R.threads + 1] = mainLoop()

-- 独立的界面刷新线程（5Hz）：主循环空闲时要 3 秒才跑一轮，
-- 倒计时/让路剩余/手持时长挂在它上面就会"一卡一卡"。这里解耦成固定 0.2 秒刷新。
R.threads[#R.threads + 1] = task.spawn(function()
    while isCurrent() do
        if R.renderStatus then pcall(R.renderStatus) end
        task.wait(0.2)
    end
end)

-- 独立的快速接管线程：游戏脚本重载（复活/传送）会重新定义那两个全局函数，
-- 这里保证 0.4 秒内重新接管，不依赖主循环的空闲间隔
R.threads[#R.threads + 1] = task.spawn(function()
    while isCurrent() do
        if not manualActive() then
            pcall(takeoverClientInsertHooks)
            pcall(disablePotionInsertHandler)
            pcall(hookHotbarSlots)
        end
        task.wait(0.4)
    end
end)

log("启动 v" .. VERSION .. " · 事件=" .. tostring(R.event.name) .. " · 候选=" .. #R.candidates)

return R
