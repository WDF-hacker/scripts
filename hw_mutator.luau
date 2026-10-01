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

local VERSION = 63
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
-- 专属魔数：killOrphans 只认带这个键的表，绝不误伤别的脚本的状态表
local MAGIC = "hw_mutator.by.wdf.place.74729868188364"
_G[GLOBAL_KEY] = _G[GLOBAL_KEY] or {}
local R = _G[GLOBAL_KEY]

if R.version and R.version >= VERSION and R.alive then
    print(PREFIX .. " v" .. tostring(R.version) .. " already running (resurface)")
    if R.resurface then pcall(R.resurface) end
    return
end
if R.destroy then pcall(R.destroy) end

R.__HW_MAGIC = MAGIC
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
                -- ⚠ 只认专属魔数。以前靠"形状"猜测（version/destroy/threads/hotbar/candidates），
                --   理论上可能误伤别的脚本的状态表（人家的 hub 也可能有这些键），
                --   误调人家的 destroy() 就等于把别人的脚本关掉了。
                return rawget(obj, "__HW_MAGIC") == MAGIC
                    and type(rawget(obj, "destroy")) == "function"
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
    autoFish = false,               -- 自动钓鱼（点钓鱼按钮 + 开游戏内置自动捕鱼）
    autoFishTeleport = true,        -- 允许脚本在"游戏没自己传送"时补一次传送回钓点（兜底）
    pondMargin = 4,                 -- 传送落点距钓点边缘的留白
    pondUseAreaY = true,            -- 使用钓点区域的 Y（否则保持当前高度）
    pondYOffset = 4,                -- 相对钓点区域的 Y 偏移
    fishEnsureAuto = true,          -- 自动确保"内置自动捕鱼"处于开启状态
    fishStallSeconds = 45,          -- 多久没出现"有鱼上钩"就重按《点击开始钓鱼》(15~180)
    autoSave = true,                -- ★ 任何设置改动都自动写回配置文件
    autoSaveDelay = 1.5,            -- 停止改动多久后写盘（秒）—— 防抖，避免频繁写文件
    autoSaveHeartbeat = 120,        -- 兜底：最长多久无条件保存一次（秒）
    solarEnabled = true,            -- Solar 陨石雨模块
    solarTargets = { Mars = true, Angelic = true }, -- 想要的突变（Solar→Mars 6x / Heaven→Angelic 天使 6x）
    solarRarities = { Ancient = true, Celestial = true },   -- Solar 用哪些品质的角色去赌
    solarRequireCandidate = true,   -- ★ 没有可用的白板角色时完全不介入（不传送、不打断钓鱼）
    solarTeleport = true,           -- 陨石一生成就传送到它的落点
    solarMaxHold = 30,              -- 同一只手持多久没被砸中就换下一只
    solarPoll = 0.25,               -- Solar 期间主循环间隔（秒）—— 陨石只有 0.5~2 秒窗口，必须快
    holdBurst = true,               -- 手持前做「取消 -> 再拿出」循环，强制游戏刷新跟随角色
    holdBurstGap = 0.02,            -- 每步之间的间隔（秒）—— 要"超快"，默认 0.02
    holdBurstCycles = 2,            -- 循环轮数：2 轮 = 连点 4 下（实测无缝衔接）
    solarHoldEveryMeteor = true,    -- 每颗陨石都强制刷新一次手持（解决游戏"误触"导致角色不到身后）
    fallMinY = 110,                 -- 判定"高空掉落物"的 Y 阈值（Solar 陨石/Heaven 流星通用）
    -- ===== 去突变（Depolarizer）=====
    washEnabled = false,            -- ⚠ 默认关闭（操作不可撤销，必须你亲自打开）
    washTypes = {},                 -- 要洗掉的突变（默认空 = 什么都不洗）★ 由你勾选
    washRarities = {},              -- 参与的品质（默认空 = 什么都不洗）★ 由你勾选
    washAutoPreview = true,         -- 去突变页签里的预览列表每 2 秒自动刷新
    solarPauseFishing = true,       -- Solar 期间暂停并取消自动钓鱼（否则会被拉回钓点）
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

local function saveConfig(quiet)
    local ok, err = writeFileSafe(CONFIG_FILE, HttpService:JSONEncode(cfg))
    if ok then
        if not quiet then print(PREFIX .. " 配置已保存 -> " .. CONFIG_FILE) end
    else
        warn(PREFIX .. " 保存失败: " .. tostring(err))
    end
    return ok
end

loadConfig(true)
R.cfg = cfg

--============================================================== 配置自动保存
-- ⭐ 给 cfg 挂元表：任何一处 `cfg.x = y` 都会被自动捕获并排队保存。
--    为什么要用元表而不是逐个回调加保存：UI 有 40+ 个 OnChanged 回调 + 十来个 API，
--    手写必然漏（漏掉的那个设置下次加载就丢了）。
R._cfgDirty = false
R._cfgSaveCount = 0
R._lastAutoSave = "-"
local function markDirty()
    R._cfgDirty = true
    R._cfgChangedAt = os.clock()
end
R.cfgSig = function() return cfgSignature(cfg) end
R.markDirty = markDirty
do
    local mt = {
        __newindex = function(t, k, v)
            rawset(t, k, v)
            R._cfgDirty = true
            R._cfgChangedAt = os.clock()
        end,
    }
    local ok = pcall(setmetatable, cfg, mt)
    if not ok then
        warn(PREFIX .. " 自动保存：cfg 挂了元表失败（退化为定时保存）")
    end
end
-- ⚠ 重要经验：`__newindex` **只在"键不存在"时触发**！对已存在的键（cfg.maxLog=…）
--   是直接赋值，元表根本不会被调用。而 UI 回调改的恰恰全是已存在的键 -> 元表方案不可靠。
-- ✅ 真正可靠的做法：**签名差分** —— 每秒把整个 cfg 拍一个稳定签名，跟上次比，变了就算改动。
--    它能捕获一切（含嵌套表如 cfg.rarities），代价是每秒遍历一次小表（可忽略）。
local function cfgSignature(t)
    local parts = {}
    local function walk(tbl, pre)
        local keys = {}
        for k in pairs(tbl) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = tbl[k]
            local vt = type(v)
            if vt == "table" then
                walk(v, pre .. k .. ".")
            elseif vt == "number" or vt == "string" or vt == "boolean" then
                parts[#parts + 1] = pre .. k .. "=" .. tostring(v)
            end
        end
    end
    pcall(walk, t, "")
    return table.concat(parts, "|")
end
R._cfgSig = cfgSignature(cfg)

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
local function buildCandidates(summary, raritySet)
    local list = {}
    if type(summary) ~= "table" then return list end
    local filter = raritySet or cfg.rarities
    for key, v in pairs(summary) do
        if type(v) == "table" then
            local ty = tostring(v.ty or "")
            local ra = tostring(v.ra or "")
            if ty == "" and filter[ra] then
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

    -- 逐个尝试候选 upvalue，并用 GetSelected 验证后缓存。
    -- ⚠ u166 可能是 nil（没选中），也可能是**另一个 key**（你已经手动选了别的角色）
    --   -> 所以 nil 和 string 两种都要试，不能只试 nil（这是"命中后重新持有蓝框消失"的根因）
    for i = 1, 14 do
        local v = debug.getupvalue(visit, i)
        if v == nil or type(v) == "string" then
            pcall(debug.setupvalue, visit, i, key)
            if verify() then
                CLIENT_SEL.idx = i
                pcall(visit)
                clearOwnStroke()
                return true
            end
            pcall(debug.setupvalue, visit, i, v)
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

--============================================================== 手持强制刷新
-- 游戏自带 bug：包里有多只同品质角色、或相邻两颗陨石太近时，紧接着再手持会被判定成"误触"，
--   角色不走完整的"消失 -> 重新出现在身后"循环（表现为角色不消失、而是一路慢慢跑过来）。
-- 实测对策（用户发现）：**超快速地连点 4 下 = 做两轮「取消 -> 再拿出」** 可以无缝衔接、瞬间掏出角色。
--   单轮太快不够，游戏要看到"回到背包 + 再拿出"完整两次才会走完刷新。
-- 最终状态一定是"持有着"，否则落地判定收不到（循环以 doHold 结尾）。
local function doHoldRefresh(key)
    if cfg.holdBurst == false then
        doHold(key)
        return
    end
    local gap = tonumber(cfg.holdBurstGap) or 0.02
    local cycles = math.max(1, math.floor(tonumber(cfg.holdBurstCycles) or 2))
    for _ = 1, cycles do
        doRelease()                      -- 取消（让游戏看到角色回背包）
        if gap > 0 then task.wait(gap) end
        doHold(key)                      -- 再拿出来
        if gap > 0 then task.wait(gap) end
    end
end

--============================================================== 手持控制
local function applyHold(key, name, rarity)
    doHoldRefresh(key)
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
    -- ⭐ 放手确认窗口：服务器可能滞后几百毫秒，期间若角色还挂着，
    --    会被后面的"非事件分支"误判成"你手动持有的"从而不干预 -> 表现为"放手了但角色还在"。
    R.releaseConfirmUntil = os.clock() + 3
    clientClearSelection()
end

local function refreshCandidates(raritySet)
    local s = fetchSummary()
    if s then
        R.summary = s
        R.candidates = buildCandidates(s, raritySet)
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

-- 天降类活动（掉落物砸中手持角色 -> 突变）。两者机制相同，合并成一个模块：
--   Solar  ：陨石 Meteorite，FallSpeed=50，ImpactRadius=50，每 5 秒一颗
--   Heaven ：流星 Falling Star，**FallSpeed=190（快得多！）**，每 10 秒一颗
--           另有 Impact 机制（每 7.5 秒在玩家 35 格内生成、持续 7 秒）
-- 目标突变：Solar -> Mars(6x)；Heaven -> Angelic(天使, 用户实测 x6)
local FALL_EVENTS = { Solar = true, Heaven = true }
local function fallEventName()
    if not (R.event.active and R.event.name) then return nil end
    if not FALL_EVENTS[R.event.name] then return nil end
    if eventRemaining() <= 0 then return nil end
    return R.event.name
end

local function isSolar()
    -- ⚠ 强制测试时同样要让位于真实事件（绝不为测试把角色暴露在真实突变里）
    if R._force and os.clock() < (R._force.until_ or 0) then
        if R.event.active and R.event.name and not FALL_EVENTS[R.event.name] and eventRemaining() > 0 then
            return false
        end
        return R._force.name == "Solar" or R._force.name == "Heaven"
    end
    return fallEventName() ~= nil
end

local function isHalloween()
    if R._force then
        if os.clock() < (R._force.until_ or 0) then
            -- ⚠ 安全：真实事件正在运行且不是万圣节 -> 强制立即让位。
            --   绝不允许"为了测试"而把手持角色暴露在真实突变事件里。
            if R.event.active and R.event.name and R.event.name ~= EVENT_NAME and eventRemaining() > 0 then
                if not R._forceYielded then
                    R._forceYielded = true
                    log("⚠ 强制测试让位于真实事件 " .. tostring(R.event.name) .. " -> 取消强制并放手",
                        Color3.fromRGB(255, 120, 120))
                end
                R._force = nil
                return false
            end
            return R._force.name == EVENT_NAME
        end
        R._force = nil
        R._forceYielded = nil
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

-- 前向声明：这些函数的真实定义在后面的模块里（tick 比它们更早定义）。
-- ⚠ 漏掉任何一个都会让主循环每轮报 "attempt to call a nil value" 并**静默失效**
--   （踩过两次：fishTick 一次、solarStart/solarStop 一次）。
local fishTick
local solarTick
local solarStart
local solarStop
local washTick

local function tick()
    local now = os.clock()
    takeoverClientInsertHooks()
    local okFish, errFish = pcall(fishTick)   -- 自动钓鱼维护（不吞错误，便于排查）
    if not okFish and cfg.autoFish then
        if (os.clock() - (R._lastFishErrLog or 0)) > 10 then
            R._lastFishErrLog = os.clock()
            log("自动钓鱼出错: " .. tostring(errFish), Color3.fromRGB(255, 120, 120))
        end
    end

    if not R._lastEventPoll or now - R._lastEventPoll > 2 then
        R._lastEventPoll = now
        refreshEvent()
    end

    if not cfg.enabled then
        if R.hold.key then applyRelease("已停用") end
        if R.solar and R.solar.active then solarStop("已停用") end
        if not R._lastIdleScan or now - R._lastIdleScan > (tonumber(cfg.rescanIdle) or 10) then
            R._lastIdleScan = now
            refreshCandidates()
        end
        hotbarTick()
        return
    end

    -- 模式切换日志：让"现在是谁在接管"一目了然，避免看起来像两套逻辑在打架
    do
        local mode = "idle"
        if cfg.enabled then
            if cfg.solarEnabled and isSolar() then mode = "solar"
            elseif isHalloween() then mode = "halloween" end
        else
            mode = "disabled"
        end
        if R._mode ~= mode then
            R._mode = mode
            if mode == "halloween" then
                log("▶ 模式切换 -> 万圣节自动突变（Solar 逻辑已停）", Color3.fromRGB(255, 180, 90))
            elseif mode == "idle" then
                log("▶ 模式切换 -> 待机（当前不是目标事件，不手持）", Color3.fromRGB(160, 160, 180))
            end
        end
    end

    -- ===== Solar 活动最高优先级：陨石雨机制完全不同，接管一切 =====
    -- （Solar 与万圣节是互斥事件，不会同时存在，所以这里直接 return 是安全的）
    if cfg.solarEnabled and isSolar() then
        if not (R.solar and R.solar.active) then solarStart() end
        local okS, errS = pcall(solarTick)
        if not okS then
            log("Solar 出错: " .. tostring(errS), Color3.fromRGB(255, 120, 120))
        end
        hotbarTick()
        return
    elseif R.solar and R.solar.active then
        solarStop("事件结束")
    end

    -- ===== 去突变（Depolarizer）：天降 / 万圣节期间让路（陨石是时间敏感的）=====
    if cfg.washEnabled and not isHalloween() then
        local okW, errW = pcall(washTick)
        if not okW then
            if (now - (R._lastWashErr or 0)) > 10 then
                R._lastWashErr = now
                log("去突变出错: " .. tostring(errW), Color3.fromRGB(255, 120, 120))
            end
        end
    end

    local forced = R._force ~= nil and os.clock() < (R._force.until_ or 0)
    local halloween = isHalloween()
    local lead = tonumber(cfg.releaseLeadSeconds) or 0
    local ending = (not forced) and halloween and eventRemaining() <= lead
    local live = halloween and not ending

    if not live then
        -- ⓪ 放手确认窗口：刚调用过 applyRelease（万圣节/Solar 结束等），但服务器可能还没生效。
        --   期间反复补发放手，直到确实放掉 —— 否则残留会被下面误判成"你手动持有的"而不干预。
        if (R.releaseConfirmUntil or 0) > now then
            local cn = heldName()
            if cn then
                doRelease()
                if not R._relConfirmLogged then
                    R._relConfirmLogged = true
                    log("正在确认放手（服务器滞后补发）: " .. tostring(cn), Color3.fromRGB(160, 200, 255))
                end
                hotbarTick()
                return
            end
            R.releaseConfirmUntil, R._relConfirmLogged = nil, nil
        end
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
    -- ⚠ 硬性安全校验：只从"万圣节勾选品质"的候选里挑（逐个复核，不信任列表顺序）。
    --   突变不可逆 —— 宁可这一轮不持有，也绝不拿没勾选的品质去赌。
    local pick
    for _, c in ipairs(R.candidates) do
        if (cfg.rarities or {})[c.rarity] then pick = c break end
    end
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
            -- ⚠ 关键：Solar 期间必须用**快节奏**。以前这里只有"万圣节快 / 其它 3 秒"两档，
            --   而 Solar 不是万圣节 -> 整个陨石逻辑只有 0.33Hz，表现就是"手持不够快、不连贯"。
            local interval
            if R.solar and R.solar.active then
                interval = tonumber(cfg.solarPoll) or 0.25      -- 只有真正介入了才需要快节奏
            elseif isSolar() then
                interval = tonumber(cfg.pollIdle) or 3          -- 事件在但没介入（比如没角色）-> 保持待机节奏
            elseif isHalloween() then
                interval = tonumber(cfg.pollHold) or 0.5
            else
                interval = tonumber(cfg.pollIdle) or 3
            end
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

--============================================================== 自动钓鱼
-- 实测（本游戏）：
--   MainGui.FishAction.Fish      主钓鱼按钮（开始钓鱼）
--   MainGui.FishAction.AutoFish  「Auto Fish」游戏内置自动钓鱼 —— **免费**（无 Purchase/Robux 子项）
--   MainGui.FishAction.QuickFish 「Quick Fish」—— **有 Purchase/Robux 子项 = 付费**，本脚本绝不点它
--   三个按钮各有 1 个 MouseButton1Click / Activated 连接 -> firesignal 可用
--   开关状态 = AutoFish.Enabled(UIGradient).Enabled==true 且 Disabled.Enabled==false
--     （实测点击会精确翻转这两个值：true/false -> false/true）
--   捕获计数在 FishAction.TextLabel 里，形如 "Waiting for Catch... [N]"
local FISH = { lastCount = nil, lastChange = 0, clicks = 0, ensured = 0, lastEnsure = 0 }

local function fishActionGui()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    return mg and mg:FindFirstChild("FishAction")
end

local function fireClick(btn)
    if not btn then return false end
    local ok = false
    pcall(function()
        if type(firesignal) == "function" and btn.MouseButton1Click then
            -- ⚠ 只触发 MouseButton1Click：实测 Activated 那条路对 AutoFish 是空操作，
            --   同时触发两个信号有"处理器被执行两次"的风险（切换类按钮会互相抵消）。
            firesignal(btn.MouseButton1Click)
            ok = true
        end
    end)
    return ok
end

-- 是否正在钓鱼：CloseBTN（取消钓鱼按钮）只在钓鱼进行中可见
local function isFishing()
    local fa = fishActionGui()
    local cb = fa and fa:FindFirstChild("CloseBTN")
    if not cb then return nil end
    local v = nil
    pcall(function() v = cb.Visible end)
    return v
end

--============================================================== 钓点（PONDAREA）
-- 实测：钓鱼必须在钓点区域内才能开始（不在区域内点按钮毫无反应）。
--   Workspace.Scripted.PondAreas.PONDAREA<n>          -- 扁平的触发区域（Y 尺寸为 0，且有旋转！）
--   Workspace.Scripted.PondAreasTeleports.TPPONDAREA<n> -- 1x1 传送垫
-- 判定必须用 CFrame:PointToObjectSpace（不能用世界坐标直接比，区域是旋转过的）。
local function pondAreas()
    local t = {}
    local s = workspace:FindFirstChild("Scripted")
    local pa = s and s:FindFirstChild("PondAreas")
    if pa then
        for _, d in ipairs(pa:GetChildren()) do
            if d:IsA("BasePart") then t[#t + 1] = d end
        end
    end
    if #t == 0 then
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("BasePart") and d.Name:upper():find("PONDAREA") and not d.Name:upper():find("^TP") then
                t[#t + 1] = d
            end
        end
    end
    return t
end

local function rootPart()
    local ch = LocalPlayer.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

-- 返回当前所在的钓点名（nil = 不在钓点内）
local function inPond()
    local hrp = rootPart()
    if not hrp then return nil end
    for _, p in ipairs(pondAreas()) do
        local rel = p.CFrame:PointToObjectSpace(hrp.Position)
        if math.abs(rel.X) <= p.Size.X / 2 and math.abs(rel.Z) <= p.Size.Z / 2 then return p.Name end
    end
    return nil
end

-- 区域内的"离玩家最近"的落点（把玩家位置夹进区域，留边距）
local function nearestPondPoint()
    local hrp = rootPart()
    if not hrp then return nil end
    local areas = pondAreas()
    if #areas == 0 then return nil end
    local margin = tonumber(cfg.pondMargin) or 4
    local bestPos, bestD, bestName
    for _, p in ipairs(areas) do
        local hx = math.max(p.Size.X / 2 - margin, 0.5)
        local hz = math.max(p.Size.Z / 2 - margin, 0.5)
        local rel = p.CFrame:PointToObjectSpace(hrp.Position)
        local lp = Vector3.new(math.clamp(rel.X, -hx, hx), 0, math.clamp(rel.Z, -hz, hz))
        local world = p.CFrame * lp
        local flat = Vector3.new(world.X, hrp.Position.Y, world.Z)
        local d = (flat - hrp.Position).Magnitude
        if not bestD or d < bestD then
            bestD, bestPos, bestName = d, world, p.Name
        end
    end
    return bestPos, bestName, bestD
end

local function teleportToPond(pos)
    local hrp = rootPart()
    if not hrp or not pos then return false end
    local y = hrp.Position.Y
    if cfg.pondUseAreaY ~= false then
        y = pos.Y + (tonumber(cfg.pondYOffset) or 4)
    end
    local ok = pcall(function()
        hrp.CFrame = CFrame.new(Vector3.new(pos.X, y, pos.Z))
    end)
    -- 速度清零，避免惯性把角色带出区域
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)
    return ok
end

local function autoFishOn()
    local fa = fishActionGui()
    local b = fa and fa:FindFirstChild("AutoFish")
    if not b then return nil end
    local en, dis = b:FindFirstChild("Enabled"), b:FindFirstChild("Disabled")
    local e1, e2
    pcall(function() e1 = en.Enabled end)
    pcall(function() e2 = dis.Enabled end)
    if e1 == nil and e2 == nil then return nil end
    return (e1 == true and e2 ~= true)
end

local function setAutoFish(want)
    local cur = autoFishOn()
    if cur == nil then return false, "读不到状态" end
    if cur == want then return true, "已是目标状态" end
    local fa = fishActionGui()
    local ok = fireClick(fa and fa:FindFirstChild("AutoFish"))
    if ok then FISH.ensured = FISH.ensured + 1 end
    return ok, (want and "已开启" or "已关闭")
end

local function fishCatchCount()
    local fa = fishActionGui()
    local tl = fa and fa:FindFirstChild("TextLabel")
    if not tl then return nil end
    local txt = ""
    pcall(function() txt = tl.Text end)
    return tonumber(txt:match("%[(%d+)%]")), txt
end

local function clickFish()
    local fa = fishActionGui()
    local ok = fireClick(fa and fa:FindFirstChild("Fish"))
    if ok then FISH.clicks = FISH.clicks + 1 end
    return ok
end

-- ⭐ 钓鱼会话是否进行中。实测可靠的判据（不要用 [N] 计数，它会在 0/1 之间闪）：
--   ① 身边有 FishBall（鱼漂，浮标）—— 正常钓鱼时就在 20 格左右
--   ② 文本是两种钓鱼态之一："Waiting for Catch..." / "Click To Catch!"
-- ⭐ 判断钓鱼会话是否活着。
-- ⚠ 踩过的坑：鱼漂(FishBall)在钓鱼结束后**会留在水里**，所以"身边有鱼漂"不能当会话活着的判据，
--   否则离开河岸、会话已死时脚本会一直以为还在钓，永远不重新点按钮（用户实测踩到）。
--   文本 "Waiting for Catch..." 在"没开始钓鱼"和"正在等鱼咬钩"两种情况下都出现，也不能单独用。
--   ✅ 唯一能确定会话活着的强信号：文本出现 "Click To Catch!"（有鱼上钩了）。
--   （注意：本函数必须定义在 fishText 之后，否则捕获不到那个局部函数）

local function nearestFishBallDist()
    local hrp = rootPart()
    if not hrp then return -1 end
    local best = math.huge
    for _, d in ipairs(workspace:GetChildren()) do
        if d:IsA("BasePart") and d.Name == "FishBall" then
            local dist = (d.Position - hrp.Position).Magnitude
            if dist < best then best = dist end
        end
    end
    return best == math.huge and -1 or best
end

local function fishText()
    local fa = fishActionGui()
    local tl = fa and fa:FindFirstChild("TextLabel")
    local t = ""
    if tl then pcall(function() t = tl.Text end) end
    return t
end

-- ✅ 上钩信号。踩过的坑：主循环空闲时 3 秒才跑一次，而 "Click To Catch!" 只闪现几百毫秒
--   -> 低频采样几乎永远采不到，会误判成"很久没上钩"。所以改由 startFishWatcher() 用
--   0.15 秒的高速线程采样，这里只负责读时间戳。
local function fishHasBite()
    return (os.clock() - (FISH.lastBite or 0)) < 1.2, fishText()
end

-- 收获计数文本（leaderstats.Catches 是缩写字符串，变了就说明有收获）
local function catchText()
    local lp = LocalPlayer
    local ls = lp and lp:FindFirstChild("leaderstats")
    local c = ls and ls:FindFirstChild("Catches")
    if not c then return nil end
    local v = nil
    pcall(function() v = tostring(c.Value) end)
    return v
end

-- ⭐ 高速观察线程：0.15 秒采样一次，负责记录"最后一次上钩/收获"的时间
local function startFishWatcher()
    -- ⚠ 不能用 `if R._fishWatch then return end`：R 跨重载复用，旧线程已被 destroy 取消，
    --   新实例却以为"已经在跑"而跳过 -> 观察线程静默消失。用线程状态判断。
    if R._fishWatch then
        local ok, st = pcall(coroutine.status, R._fishWatch)
        if ok and st ~= "dead" then return end
    end
    R._fishWatch = task.spawn(function()
        while isCurrent() do
            if cfg.autoFish then
                pcall(function()
                    local t = fishText()
                    if t:find("Click To Catch") then
                        FISH.lastBite = os.clock()
                        FISH.bites = (FISH.bites or 0) + 1
                    end
                    local cs = catchText()
                    if cs ~= nil and cs ~= FISH.lastCatchText then
                        FISH.lastCatchText = cs
                        FISH.lastBite = os.clock()
                        FISH.catches = (FISH.catches or 0) + 1
                    end
                end)
                task.wait(0.15)
            else
                task.wait(0.5)
            end
        end
    end)
end

local function fishSessionActive()
    local d = nearestFishBallDist()
    if d >= 0 and d <= 60 then return true, ("鱼漂 " .. string.format("%.0f", d) .. " 格") end
    local t = fishText()
    if t:find("Waiting for Catch") or t:find("Click To Catch") then return true, t end
    return false, ("无会话（鱼漂=" .. string.format("%.0f", d) .. " 文本='" .. t .. "'）")
end

function fishTick()
    if not cfg.autoFish then return end
    -- ⭐ 只有"脚本真正介入了天降"才暂停钓鱼。如果因为没有可用角色而没介入，
    --    钓鱼必须照常跑（用户实测：没角色了还被打断钓鱼 = 白损失）。
    if cfg.solarPauseFishing ~= false and R.solar and R.solar.active then
        if not R._fishPausedBy then
            R._fishPausedBy = "Solar"
            log("⏸ Solar 活动开始 -> 自动钓鱼暂时停手（避免被拉回钓点）", Color3.fromRGB(255, 180, 90))
        end
        return
    elseif R._fishPausedBy == "Solar" then
        R._fishPausedBy = nil
        log("▶ Solar 结束 -> 自动钓鱼恢复", Color3.fromRGB(120, 255, 140))
    end
    -- 保证高速观察线程在跑（它负责记录"最后一次上钩"）
    startFishWatcher()
    local now = os.clock()
    if (now - (FISH.lastAct or 0)) < 2 then return end     -- 动作冷却

    -- 上钩时间戳由 startFishWatcher() 以 0.15 秒精度维护，这里只读
    if (FISH.lastBite or 0) == 0 then FISH.lastBite = now end
    local txt = fishText()

    local stall = tonumber(cfg.fishStallSeconds) or 45
    local idleFor = now - FISH.lastBite
    FISH.lastWhy = string.format("距上次上钩 %.0f 秒（文本='%s'）", idleFor, txt)

    -- ① 太久没鱼上钩 -> 会话已死（或从没开始）-> 点一次《点击开始钓鱼》。
    --    实测：不在钓鱼时点它是安全的；游戏通常会自己把你传送到钓点（已在岸边则不传送）。
    if idleFor > stall then
        FISH.lastBite = now            -- 重置计时，避免连续点
        FISH.lastAct = now
        FISH.missCount = (FISH.missCount or 0) + 1
        if clickFish() then
            FISH.starts = (FISH.starts or 0) + 1
            log("点了一次《点击开始钓鱼》（已 " .. string.format("%.0f", idleFor) .. " 秒没鱼上钩）",
                Color3.fromRGB(140, 220, 255))
        end
        -- 游戏有时不会传送（用户实测：离开河岸后点了也没回去）-> 连续两次没恢复就自己补一次传送
        if (FISH.missCount or 0) >= 2 and cfg.autoFishTeleport ~= false then
            local pos, pname, dist = nearestPondPoint()
            if pos and dist and dist > 5 then
                if teleportToPond(pos) then
                    FISH.tp = (FISH.tp or 0) + 1
                    FISH.missCount = 0
                    log("连续点了几次都没恢复钓鱼 -> 自己传送到钓点 " .. tostring(pname) ..
                        "（" .. string.format("%.0f", dist) .. " 格）", Color3.fromRGB(140, 220, 255))
                end
            end
        end
    else
        FISH.missCount = 0             -- 会话活着 -> 清零
    end
    -- ⚠ 注意：这里**不能 return**，否则下面的"补开内置自动捕鱼"永远执行不到
    --   （用户实测踩到：界面显示 AutoFish 已关闭、已补开 0 次）

    -- ② 无论如何都保证内置自动捕鱼开着。
    --    ⚠ 绝不能在这里点 Fish：实测点 Fish = 手动上鱼，而且会把内置自动捕鱼**关掉**！
    --    ⚠ 必须防抖：上鱼动画期间那两个渐变会瞬时闪成"关"，直接补开会导致来回横跳。
    local on = autoFishOn()
    if on == false then
        FISH.offStreak = (FISH.offStreak or 0) + 1
    else
        FISH.offStreak = 0
    end
    if (FISH.offStreak or 0) >= 3 and cfg.fishEnsureAuto ~= false
        and (now - (FISH.lastEnsure or 0)) > 4 then
        FISH.lastEnsure = now
        if setAutoFish(true) then
            FISH.ensured = FISH.ensured + 1
            FISH.offStreak = 0
            log("已补开游戏内置自动钓鱼（Auto Fish）", Color3.fromRGB(120, 255, 140))
        end
    end
end

--============================================================== Solar 活动（陨石雨）
-- 实测机制（本游戏，已用真实 Solar 活动抓包验证）：
--   * 陨石实体 = workspace 下名为 "Meteorite" 的 Model（含 Base/Neon 两个 MeshPart）
--     **Anchored = true** —— 服务端用 CFrame 驱动下落，所以"未锚定"不能当判据；
--     必须靠 workspace.ChildAdded 事件（零延迟）+ Y 变化来判断。
--   * 生成高度 Y≈182，**垂直下落 -> 落点就是生成时的 (X,Z)**；从生成到落地只有约 0.5~2 秒。
--   * Constants.TypeEvents.Events.Solar.Meteorites.ImpactRadius = 50（判定半径；
--     跟随模型在身侧约 10 格，所以站到落点就足够）。
--   * 目标突变倍数 Constants.TypeSystem.Multipliers：**Mars=6（最高）**、Lava=2、Gold=1.25。
--   * 判定对象：被砸到的**手持/已装备角色**（workspace.CarriedCharacters / EquippedFollowers）。
-- 流程：Solar 一开 -> 先手持好 -> 陨石一生成立刻传送到落点 -> 落地判定 -> 命中就换下一只。
local function solarState()
    if not R.solar then
        R.solar = { active = false, meteors = 0, tp = 0, hits = 0, targets = 0, lastMeteor = 0, lastHit = 0 }
    end
    return R.solar
end
solarState()

local function solarTargetSet()
    local set = {}
    if type(cfg.solarTargets) == "table" then
        for k, v in pairs(cfg.solarTargets) do if v then set[k] = true end end
    end
    if not next(set) then set.Mars = true end      -- 默认只要火星（倍数最高）
    return set
end

-- 主动取消当前的钓鱼会话（Solar 开始时必须做，否则游戏自己还会继续钓/把我们留在钓点）
local function cancelFishing()
    local fa = fishActionGui()
    local cb = fa and fa:FindFirstChild("CloseBTN")
    local done = false
    if cb then
        local vis = false
        pcall(function() vis = cb.Visible end)
        if vis then done = fireClick(cb) end
    end
    -- 兜底：直接发 FishingCancel
    local Rm = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
    local rc = Rm and Rm:FindFirstChild("FishingCancel")
    if rc then pcall(function() rc:FireServer() end) done = true end
    return done
end

-- ⭐ 有没有"可用的白板角色"（ty=="" 且品质在 Solar 勾选里）？
--    没有就**完全不介入**：不取消钓鱼、不传送、不手持 —— 免得白忙一场还打断钓鱼。
local function solarUsableCount()
    local allow = cfg.solarRarities or {}
    if type(R.summary) ~= "table" then return 0 end
    local n = 0
    for _, v in pairs(R.summary) do
        if type(v) == "table" and tostring(v.ty or "") == "" and allow[tostring(v.ra or "")] then
            n = n + 1
        end
    end
    return n
end

local function solarRarityNames()
    local n = {}
    for k, v in pairs(cfg.solarRarities or {}) do if v then n[#n + 1] = k end end
    table.sort(n, function(a, b) return (RARITY_RANK[a] or 0) > (RARITY_RANK[b] or 0) end)
    return #n > 0 and table.concat(n, "/") or "（未勾选）"
end

local function solarStart_impl()
    local S = solarState()
    if S.active then return end
    -- ⭐ 前置条件：必须有可用的白板角色（指定品质）。没有就完全不介入 —— 继续钓鱼。
    if cfg.solarRequireCandidate ~= false then
        refreshCandidates(cfg.solarRarities)
        local n = solarUsableCount()
        if n == 0 then
            if not S._noCandLogged or (os.clock() - S._noCandLogged) > 30 then
                S._noCandLogged = os.clock()
                log("☄ 天降事件来了，但你没有可用的白板角色（品质: " .. solarRarityNames() ..
                    "）-> 不介入，继续钓鱼", Color3.fromRGB(255, 200, 90))
            end
            return                       -- S.active 保持 false -> 钓鱼不会被暂停、也不会传送
        end
        S._noCandLogged = nil
    end
    S.active = true
    S.startedAt = os.clock()
    log("☄ Solar 活动开始 -> 进入陨石模式", Color3.fromRGB(255, 180, 90))
    -- ① 让路：暂停自动钓鱼 + **主动取消当前钓鱼会话**（只停手不够，游戏自己还会继续钓）
    if cfg.solarPauseFishing ~= false then
        R._fishPausedBy = "Solar"
        if cancelFishing() then
            log("⏸ 已取消当前钓鱼会话（Solar 期间自动钓鱼让路）", Color3.fromRGB(255, 180, 90))
        end
    end
    -- ② 用 Solar 专属的品质筛选刷新候选，并立刻先手持一只
    refreshCandidates(cfg.solarRarities)
    if not R.hold.key and R.candidates[1] then
        local pick = R.candidates[1]
        applyHold(pick.key, pick.name, pick.rarity)
        log("Solar 手持 " .. pick.name .. " [" .. pick.rarity .. "]")
    end
end

local function solarStop_impl(reason)
    local S = solarState()
    if not S.active then return end
    S.active = false
    if R.hold.key then applyRelease("Solar " .. tostring(reason or "结束")) end
    log("☄ Solar 结束（" .. tostring(reason or "") .. "）：陨石 " .. S.meteors ..
        " 颗 · 传送 " .. S.tp .. " 次 · 突变 " .. S.hits .. " 次（目标 " .. S.targets .. "）",
        Color3.fromRGB(160, 220, 255))
end

-- 快速"确保手持"：陨石一出现就立刻调用，**不等主循环**（落地窗口只有 0.5~2 秒）
-- 返回 true 表示"现在确实拿着候选角色"
local function solarEnsureHold()
    if not cfg.solarEnabled then return false end
    local allow = cfg.solarRarities or {}
    if R.hold.key then
        -- ⚠⚠ 硬性安全校验（绝不能被绕过）：当前手持的品质不在勾选里 -> 立刻放手，
        --     不拿它去赌。突变是不可逆的，宁可漏也不能错。
        local cr = R.hold.rarity
        if cr ~= nil and not allow[cr] then
            log("⚠ Solar 安全拦截：手持 " .. tostring(R.hold.name) .. " [" .. tostring(cr) ..
                "] 不在你勾选的品质里 -> 立刻放手", Color3.fromRGB(255, 120, 120))
            applyRelease("Solar 品质不符")
        elseif heldName() == R.hold.name then
            return true
        elseif (os.clock() - (R.hold.since or 0)) < 1.2 then
            return true
        end
    end
    -- 只从"勾选品质"的候选里挑（不信任 R.candidates 的顺序，逐个复核品质）
    local pick
    for _, c in ipairs(R.candidates) do
        if allow[c.rarity] then pick = c break end
    end
    if not pick then return false end
    applyHold(pick.key, pick.name, pick.rarity)
    return true, pick.name
end

-- 把实现接到前面的前向声明上（这样 tick 里调用的就是真函数，不会 nil）
solarStart = solarStart_impl
solarStop = solarStop_impl

-- 陨石生成回调：事件驱动、零延迟（轮询绝对来不及）
local function solarOnMeteor(d)
    if not cfg.solarEnabled then return end
    -- ⭐ 按高度识别掉落物：Solar 的叫 Meteorite，Heaven 的流星名字未知，
    --    统一规则 = "新出现的高空物体"（Threshold 可调 cfg.fallMinY，默认 110）。
    if d.Name ~= "Meteorite" then
        local q
        if d:IsA("BasePart") then q = d
        elseif d:IsA("Model") then pcall(function() q = d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart") end) end
        if not q then return end
        local okY, y = pcall(function() return q.Position.Y end)
        if not okY or type(y) ~= "number" then return end
        if y < (tonumber(cfg.fallMinY) or 110) then return end
        -- 玩家自己的角色不算
        if game:GetService("Players"):GetPlayerFromCharacter(d) then return end
    end
    -- 我们自己造的假陨石：无条件走传送路径（用于测试）。
    -- 它是本地造的假对象，不会触发服务端判定，所以没有"被别的突变烧掉"的风险。
    local isTest = (R._solarTestActive == true) or (R._testMeteor ~= nil and d == R._testMeteor)
    if not (isSolar() or isTest) then return end
    local S = solarState()
    if isSolar() and not S.active then solarStart() end
    -- ⭐ 没真正介入（例如没有可用的白板角色）-> 连传送都不做，避免白跑还打断钓鱼
    if not isTest and not S.active then return end
    local p
    if d:IsA("BasePart") then p = d else pcall(function() p = d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart") end) end
    if not p then return end
    local now = os.clock()
    -- 去重只看"是不是同一颗"（不能按时间窗去重：连发测试时 0.15 秒内会有多颗，
    -- 时间窗会把后面的陨石全吞掉 -> 表现为"连发时不动"）
    if S.lastMeteorObj == d then return end
    S.lastMeteorObj = d
    S.lastMeteor = now
    S.meteors = S.meteors + 1
    if cfg.solarTeleport == false then return end
    local hrp = rootPart()
    if not hrp then return end
    local pos = p.Position
    local ok = pcall(function()
        hrp.CFrame = CFrame.new(Vector3.new(pos.X, hrp.Position.Y, pos.Z))
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)
    if ok then
        S.tp = S.tp + 1
        S.lastTpAt = now
        log(string.format("☄ 陨石 #%d -> 传送到落点 (%.0f, %.0f)", S.meteors, pos.X, pos.Z),
            Color3.fromRGB(255, 180, 90))
        -- ⭐ 每颗陨石都做一次「取消 -> 再拿出」的手持刷新（绕开游戏的"误触"判定），
        --    保证落地那一刻角色确实完整地出现在身后。
        if isSolar() and cfg.solarHoldEveryMeteor ~= false then
            if R.hold.key then
                doHoldRefresh(R.hold.key)
                S.holds = (S.holds or 0) + 1
            else
                solarEnsureHold()
            end
        end
    end
end

function solarTick()
    local S = solarState()
    if not cfg.solarEnabled then
        if S.active then solarStop("已停用") end
        return
    end
    local now = os.clock()

    -- Solar 用专属品质筛选刷新候选
    if (not R._lastSummaryAt) or (now - R._lastSummaryAt >= (tonumber(cfg.pollSummary) or 1)) then
        refreshCandidates(cfg.solarRarities)
    end

    -- ⭐ 中途角色耗尽（全被突变完了）-> 退出模式，把钓鱼还给用户
    if cfg.solarRequireCandidate ~= false and type(R.summary) == "table" then
        if solarUsableCount() == 0 and not R.hold.key then
            solarStop("可用的白板角色已用完")
            return
        end
    end

    -- ① 命中检测（复用万圣节那套已验证的 diff：baseline 里同名 key 出现 ty~="" 且数量增加）
    if R.hold.key and R.hold.baseline and R.summary then
        local hits = detectMutation(R.hold.baseline, R.summary, R.hold.name)
        if #hits > 0 then
            local targets = solarTargetSet()
            local names, gotTarget = {}, false
            for _, h in ipairs(hits) do
                names[#names + 1] = h.ty
                S.hits = S.hits + 1
                if targets[h.ty] then gotTarget = true; S.targets = S.targets + 1 end
            end
            local who = R.hold.name
            if gotTarget then
                log("★★ Solar 命中目标！" .. who .. " -> " .. table.concat(names, ", "),
                    Color3.fromRGB(120, 255, 140))
            else
                log("Solar 突变 " .. who .. " -> " .. table.concat(names, ", ") .. "（非目标）",
                    Color3.fromRGB(255, 200, 90))
            end
            S.lastHit = now
            applyRelease("Solar 已突变")
            refreshCandidates()
            R._lastSummaryAt = now
            -- 立刻换下一只（陨石每 5 秒一颗，不能等）—— 同样复核品质
            local nxt
            local allow = cfg.solarRarities or {}
            for _, c in ipairs(R.candidates) do
                if allow[c.rarity] then nxt = c break end
            end
            if nxt then
                applyHold(nxt.key, nxt.name, nxt.rarity)
                log("Solar 换手持 " .. nxt.name .. " [" .. nxt.rarity .. "]")
            end
            return
        end
    end

    -- ② 手持超时保护：一直没被砸中就换一只，避免死守
    if R.hold.key then
        local limit = tonumber(cfg.solarMaxHold) or 30
        if (now - (R.hold.since or now)) > limit then
            log("Solar 手持 " .. tostring(R.hold.name) .. " 已 " .. limit .. " 秒没被砸中 -> 换下一只",
                Color3.fromRGB(255, 200, 90))
            applyRelease("Solar 超时")
        end
    end

    -- ③ 手持丢失检测：连续 3 次确认才放手（避免网络抖动导致 release/hold 抖动 = 手感"不连贯"）
    if R.hold.key then
        if heldName() == R.hold.name or (now - (R.hold.since or 0)) < 1.2 then
            R.hold.missRun = 0
        else
            R.hold.missRun = (R.hold.missRun or 0) + 1
            if R.hold.missRun >= 3 then
                R.hold.missRun = 0
                applyRelease("Solar 手持丢失")
            end
        end
    end

    -- ④ 保证一直持有着（陨石落地那一刻必须已经拿在手上）
    --    ⚠ 这里也必须复核品质：只挑勾选品质的候选（突变不可逆，宁可漏也不能错）
    if not R.hold.key then solarEnsureHold() end
    -- 额外一道保险：万一 R.hold 里躺着不在勾选范围的品质，立刻放手
    if R.hold.key and R.hold.rarity ~= nil and not (cfg.solarRarities or {})[R.hold.rarity] then
        log("⚠ Solar 安全拦截（tick）：" .. tostring(R.hold.name) .. " [" .. tostring(R.hold.rarity) ..
            "] 不在勾选品质 -> 放手", Color3.fromRGB(255, 120, 120))
        applyRelease("Solar 品质不符")
    end
end

-- 陨石监听：**每个实例都要新建**（R 跨重载复用，写 `if not R._solarConn` 会让新实例跳过创建，
-- 而旧连接已被上一个实例的 destroy 断开 -> 结果一个监听都没有）。
do
    local conn = workspace.ChildAdded:Connect(function(d)
        if not isCurrent() then return end
        pcall(solarOnMeteor, d)
    end)
    R.connections[#R.connections + 1] = conn
    R._solarConn = conn
end

--============================================================== 去突变（Depolarizer）
local function fmtCps(n)
    n = tonumber(n) or 0
    if n >= 1e18 then return string.format("%.2fQi", n / 1e18) end
    if n >= 1e15 then return string.format("%.2fQa", n / 1e15) end
    if n >= 1e12 then return string.format("%.2fT", n / 1e12) end
    if n >= 1e9 then return string.format("%.2fB", n / 1e9) end
    if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
    if n >= 1e3 then return string.format("%.2fK", n / 1e3) end
    return string.format("%.0f", n)
end
-- 实测机制（本游戏，已真机验证）：
--   * 机器 = workspace.PlayerPlots.Plot<N>.Purchases.Depolarizer（自己的地块靠 OwnerUserId 认）
--   * 交互 = CharacterInsert.PromptPart.ProximityPrompt，**ActionText 就是状态指示器**：
--       "Equip Character First! [With an Type]" -> 机器空闲
--       "Place"                                 -> 已手持带突变角色，可以放上去
--       "Skip (Robux)"                          -> **正在洗**（付费跳过，绝不点！）
--   * 操作 = 手持【带突变】的角色 -> fireproximityprompt(prompt) -> 角色被收进机器
--       服务器回传 DepolarizrUI{action="HotbarFrom"}（走 prompt 路径**不需要确认框**）
--   * 耗时 = **数小时**（实测一个 Ancient Gold = 11h25m），显示在 TimePart.StatsGui.Frame.TimeLeft
--   * 期间角色**不在背包**（背包总数 -1，机器内也看不到 Humanoid），
--     洗完自动以无突变状态回背包（游戏行为，脚本无需处理）
-- ⚠ 所以"自动洗" = **机器一空闲就自动补位**；一次只能洗一个，无法加速。
local function depoFolder()
    local plots = workspace:FindFirstChild("PlayerPlots")
    if not plots then return nil end
    local uid = LocalPlayer.UserId
    for _, p in ipairs(plots:GetChildren()) do
        if tonumber(p:GetAttribute("OwnerUserId") or -1) == uid then
            local pu = p:FindFirstChild("Purchases")
            local d = pu and pu:FindFirstChild("Depolarizer")
            if d then return d end
        end
    end
    return nil
end

local function depoPrompt()
    local d = depoFolder()
    if not d then return nil end
    return d:FindFirstChild("ProximityPrompt", true)
end

-- 机器状态："idle"（空闲）/ "ready"（手持了可放的）/ "busy"（正在洗）/ "none"（没这台机器）
local function depoState()
    local p = depoPrompt()
    if not p then return "none", "" end
    local a = ""
    pcall(function() a = p.ActionText end)
    if a:find("Skip") then return "busy", a end
    if a:find("Place") then return "ready", a end
    if a:find("Equip") then return "idle", a end
    return "unknown", a
end

local function depoTimeLeft()
    local d = depoFolder()
    if not d then return nil end
    local tp = d:FindFirstChild("TimePart", true)
    local g = tp and tp:FindFirstChild("StatsGui")
    local fr = g and g:FindFirstChild("Frame")
    local holder = fr and fr:FindFirstChild("TimeLeft")
    if not holder then return nil end
    local lbl = holder:IsA("TextLabel") and holder or holder:FindFirstChildWhichIsA("TextLabel")
    if not lbl then return nil end
    local t = nil
    pcall(function() t = lbl.Text end)
    return t
end

local function depoStandPos()
    local d = depoFolder()
    if not d then return nil end
    local pp = d:FindFirstChild("PromptPart", true)
    local pos = pp and pp.Position
    if not pos then return nil end
    return Vector3.new(pos.X, pos.Y + 4, pos.Z)
end

local function depoFire(prompt)
    if not prompt then return false end
    if type(fireproximityprompt) == "function" then
        local ok = pcall(fireproximityprompt, prompt)
        if ok then return true end
    end
    local ok = pcall(function()
        prompt:InputHoldBegin()
        task.wait(0.08)
        prompt:InputHoldEnd()
    end)
    return ok
end

-- 挑"该洗的角色"：品质 ∈ cfg.washRarities 且 突变 ∈ cfg.washTypes，按 CPS 从高到低
local function washTargets()
    local allowR, allowT = cfg.washRarities or {}, cfg.washTypes or {}
    local list = {}
    if type(R.summary) ~= "table" then return list end
    for key, v in pairs(R.summary) do
        if type(v) == "table" then
            local ty = tostring(v.ty or "")
            local ra = tostring(v.ra or "")
            if ty ~= "" and allowT[ty] and allowR[ra] then
                list[#list + 1] = { key = key, name = tostring(v.n or "?"), rarity = ra, ty = ty,
                                    cps = tonumber(v.bc) or 0 }
            end
        end
    end
    table.sort(list, function(a, b) return a.cps > b.cps end)
    return list
end

local WASH = { placed = 0, lastPlace = 0, lastKey = nil, lastErr = nil }

washTick = function()
    if not cfg.washEnabled then return end
    local now = os.clock()
    local state = depoState()
    local tl = depoTimeLeft()

    if state == "none" then
        if not WASH._noMachLog or now - WASH._noMachLog > 60 then
            WASH._noMachLog = now
            log("⚠ 去突变：你的地块上没有 Depolarizer 机器", Color3.fromRGB(255, 180, 80))
        end
        return
    end

    -- 机器在洗 -> 什么都不做（⚠ 绝不去点 Skip (Robux)，那是付费的）
    if state == "busy" then
        WASH.done = WASH.done or 0
        return
    end

    -- 刷新背包并挑目标
    if (not R._lastSummaryAt) or (now - R._lastSummaryAt >= (tonumber(cfg.pollSummary) or 1)) then
        refreshCandidates()
    end
    local targets = washTargets()
    if #targets == 0 then return end

    -- 限流：两次放置之间至少 3 秒（机器状态刷新有延迟）
    if now - (WASH.lastPlace or 0) < 3 then return end

    local pick = targets[1]
    if WASH.lastKey == pick.key and now - (WASH.lastPlace or 0) < 30 then return end

    -- ⭐ 安全校验（吸取教训）：必须是【带突变】的角色，且品质/突变都在勾选里，绝不越界
    if pick.ty == "" or not (cfg.washTypes or {})[pick.ty] or not (cfg.washRarities or {})[pick.rarity] then
        log("⚠ 去突变 安全拦截：跳过 " .. pick.name .. " [" .. pick.rarity .. "/" .. pick.ty .. "]",
            Color3.fromRGB(255, 120, 120))
        return
    end

    -- ① 手持它
    applyHold(pick.key, pick.name, pick.rarity)
    WASH.lastKey = pick.key
    WASH.lastPlace = now

    -- ② 传送到机器旁并放上去
    task.spawn(function()
        local hrp = rootPart()
        local pos = depoStandPos()
        if not hrp or not pos then return end
        pcall(function()
            hrp.CFrame = CFrame.new(pos)
            hrp.AssemblyLinearVelocity = Vector3.zero
        end)
        task.wait(0.35)
        local prompt = depoPrompt()
        if not prompt then return end
        local en = false
        pcall(function() en = prompt.Enabled end)
        if not en then
            log("⚠ 去突变：" .. pick.name .. " 的 prompt 未启用（可能没手持成功）", Color3.fromRGB(255, 180, 80))
            return
        end
        depoFire(prompt)
        WASH.placed = WASH.placed + 1
        WASH.lastPlacedName = pick.name
        log(string.format("🧼 已放入 Depolarizer：%s [%s] 突变=%s $%s/s  -> 开始清洗（预计 %s）",
            pick.name, pick.rarity, pick.ty, fmtCps(pick.cps), tostring(depoTimeLeft() or "数小时")),
            Color3.fromRGB(120, 255, 140))
        -- 角色已被机器收走 -> 清掉本地手持状态
        task.wait(1.2)
        if R.hold.key == pick.key then applyRelease("去突变：已交付机器") end
    end)
end

-- DepolarizrUI 事件（服务器 -> 客户端）：用于状态提示
do
    local Rm = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
    local ev = Rm and Rm:FindFirstChild("DepolarizrUI")
    if ev then
        local c = ev.OnClientEvent:Connect(function(p)
            if not isCurrent() then return end
            local a = type(p) == "table" and tostring(p.action) or tostring(p)
            if a == "HotbarFrom" then
                log("🧼 Depolarizer 已接收角色，开始清洗", Color3.fromRGB(120, 255, 140))
            elseif a == "HideConfirm" then
                -- 忽略
            end
        end)
        R.connections[#R.connections + 1] = c
    end
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
        if E.tAutoFish then E.tAutoFish:SetValue(cfg.autoFish == true) end
        if E.tFishEnsure then E.tFishEnsure:SetValue(cfg.fishEnsureAuto ~= false) end
        if E.sFishStall then E.sFishStall:SetValue(tonumber(cfg.fishStallSeconds) or 15) end
        if E.tFishTp then E.tFishTp:SetValue(cfg.autoFishTeleport ~= false) end
        if E.tSolar then E.tSolar:SetValue(cfg.solarEnabled ~= false) end
        if E.dSolarTargets then E.dSolarTargets:SetValue(cfg.solarTargets or { Mars = true }) end
        if E.dSolarRar then E.dSolarRar:SetValue(cfg.solarRarities or { Ancient = true, Celestial = true }) end
        if E.tSolarTp then E.tSolarTp:SetValue(cfg.solarTeleport ~= false) end
        if E.tSolarReq then E.tSolarReq:SetValue(cfg.solarRequireCandidate ~= false) end
        if E.sSolarHold then E.sSolarHold:SetValue(tonumber(cfg.solarMaxHold) or 30) end
        if E.sSolarPoll then E.sSolarPoll:SetValue(tonumber(cfg.solarPoll) or 0.25) end
        if E.tSolarPauseFish then E.tSolarPauseFish:SetValue(cfg.solarPauseFishing ~= false) end
        if E.tSolarBurst then E.tSolarBurst:SetValue(cfg.solarHoldEveryMeteor ~= false) end
        if E.tBurst then E.tBurst:SetValue(cfg.holdBurst ~= false) end
        if E.sBurstGap then E.sBurstGap:SetValue(tonumber(cfg.holdBurstGap) or 0.02) end
        if E.sBurstCycles then E.sBurstCycles:SetValue(tonumber(cfg.holdBurstCycles) or 2) end
        if E.tWash then E.tWash:SetValue(cfg.washEnabled == true) end
        if E.tAutoSave then E.tAutoSave:SetValue(cfg.autoSave ~= false) end
        if E.sAutoSaveDelay then E.sAutoSaveDelay:SetValue(tonumber(cfg.autoSaveDelay) or 1.5) end
        if E.dWashTypes then E.dWashTypes:SetValue(cfg.washTypes or {}) end
        if E.dWashRar then E.dWashRar:SetValue(cfg.washRarities or {}) end
        if E.tWashAuto then E.tWashAuto:SetValue(cfg.washAutoPreview ~= false) end
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
        if E.tAutoFish then cfg.autoFish = E.tAutoFish.Value == true end
        if E.tFishEnsure then cfg.fishEnsureAuto = E.tFishEnsure.Value == true end
        if E.sFishStall then cfg.fishStallSeconds = tonumber(E.sFishStall.Value) or 15 end
        if E.tFishTp then cfg.autoFishTeleport = E.tFishTp.Value == true end
        if E.tSolar then cfg.solarEnabled = E.tSolar.Value == true end
        if E.dSolarTargets then
            local v = E.dSolarTargets.Value
            cfg.solarTargets = (type(v) == "table") and v or {}
        end
        if E.dSolarRar then
            local v = E.dSolarRar.Value
            cfg.solarRarities = (type(v) == "table") and v or {}
        end
        if E.tSolarTp then cfg.solarTeleport = E.tSolarTp.Value == true end
        if E.tSolarReq then cfg.solarRequireCandidate = E.tSolarReq.Value == true end
        if E.sSolarHold then cfg.solarMaxHold = tonumber(E.sSolarHold.Value) or 30 end
        if E.sSolarPoll then cfg.solarPoll = tonumber(E.sSolarPoll.Value) or 0.25 end
        if E.tSolarPauseFish then cfg.solarPauseFishing = E.tSolarPauseFish.Value == true end
        if E.tSolarBurst then cfg.solarHoldEveryMeteor = E.tSolarBurst.Value == true end
        if E.tBurst then cfg.holdBurst = E.tBurst.Value == true end
        if E.sBurstGap then cfg.holdBurstGap = tonumber(E.sBurstGap.Value) or 0.02 end
        if E.sBurstCycles then cfg.holdBurstCycles = math.max(1, math.floor(tonumber(E.sBurstCycles.Value) or 2)) end
        if E.tWash then cfg.washEnabled = E.tWash.Value == true end
        if E.tAutoSave then cfg.autoSave = E.tAutoSave.Value == true end
        if E.sAutoSaveDelay then cfg.autoSaveDelay = tonumber(E.sAutoSaveDelay.Value) or 1.5 end
        if E.dWashTypes then
            local v = E.dWashTypes.Value
            cfg.washTypes = (type(v) == "table") and v or {}
        end
        if E.dWashRar then
            local v = E.dWashRar.Value
            cfg.washRarities = (type(v) == "table") and v or {}
        end
        if E.tWashAuto then cfg.washAutoPreview = E.tWashAuto.Value == true end
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

--============================================================== 只碰"我们自己的" UI
-- ⚠ 惨痛教训：以前这里按 `c.Name == "Obsidian"` 删除 ScreenGui，
--   结果把别人的 hub（例如 Ouroboros 也是 Obsidian 写的）的界面一起删了，
--   用户以为自己的挂机脚本"被顶掉了"。
--   现在改成：创建时给自己的 ScreenGui 打一个专属属性标记，清理时只删带标记的。
local UI_MARK = "HW_MutatorOwned"

local function uiContainers()
    local t = {}
    pcall(function()
        local h = gethui and gethui()
        if h then t[#t + 1] = h end
    end)
    pcall(function() t[#t + 1] = game:GetService("CoreGui") end)
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then t[#t + 1] = pg end
    return t
end

-- 记录当前已存在的所有 ScreenGui（用于"加载库之后找出新增的那个 = 我们的"）
local function snapshotGuiSet()
    local set = {}
    for _, cont in ipairs(uiContainers()) do
        for _, c in ipairs(cont:GetChildren()) do
            if c:IsA("ScreenGui") then set[c] = true end
        end
    end
    return set
end

-- 只清扫"我们自己"上次重载留下的残留（带 UI_MARK 的），绝不碰别人的 UI
local function cleanupStaleObsidianUI()
    local removed = 0
    for _, cont in ipairs(uiContainers()) do
        for _, c in ipairs(cont:GetChildren()) do
            if c:IsA("ScreenGui") then
                local marked = false
                pcall(function() marked = c:GetAttribute(UI_MARK) ~= nil end)
                if marked then
                    pcall(function() c:Destroy() end)
                    removed = removed + 1
                end
            end
        end
    end
    return removed
end
R.cleanupStaleUI = cleanupStaleObsidianUI

local function buildUI()
    R.uiError = nil          -- 清掉上一版遗留的错误串（R 跨重载复用，否则会一直显示旧错误）
    -- ⚠ 必须在加载 Obsidian 之前清扫：库在 loadstring 执行时就会创建自己的
    --   "Obsidian" ScreenGui，若在之后清扫会把新建的也一起删掉（导致 UI 消失）
    local stale = cleanupStaleObsidianUI()
    if stale > 0 then print(PREFIX .. " 清理自家残留 UI: " .. stale .. " 个") end
    local preGuiSet = snapshotGuiSet()          -- 加载前快照，用来认出"新增的那个"

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

    -- 给"我们自己的"那个 ScreenGui 打标记（加载前的快照里没有、现在新出现的）
    do
        local mine
        for _, cont in ipairs(uiContainers()) do
            for _, c in ipairs(cont:GetChildren()) do
                if c:IsA("ScreenGui") and not preGuiSet[c] and c.Name:find("Obsidian") then
                    mine = c
                end
            end
        end
        if mine then
            pcall(function() mine:SetAttribute(UI_MARK, tostring(VERSION)) end)
            R._uiGui = mine
        end
    end

    local Tabs = {
        Main = Window:AddTab("主控", "crosshair"),
        Hotbar = Window:AddTab("快捷栏", "layout-grid"),
        Fish = Window:AddTab("钓鱼", "fish"),
        Solar = Window:AddTab("Solar", "flame"),
        Wash = Window:AddTab("去突变", "sparkles"),
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

    --================ 配置自动保存
    do
        local as = Tabs.Config:AddLeftGroupbox("配置自动保存", "save")
        E.tAutoSave = as:AddToggle("autoSave", {
            Text = "自动保存我的一切更改 ★", Default = cfg.autoSave ~= false,
            Tooltip = "任何设置改动（界面上的每一个开关/滑块/多选、以及 API 调用）都会自动写回配置文件。"
                .. "重载脚本或载入新版本时不会再丢配置。",
        })
        E.lAutoSave = as:AddLabel("自动保存: —", true)
        E.sAutoSaveDelay = as:AddSlider("autoSaveDelay", {
            Text = "改动后多久写盘", Default = tonumber(cfg.autoSaveDelay) or 1.5,
            Min = 0.5, Max = 10, Rounding = 1, Suffix = " 秒",
            Tooltip = "防抖：连续拖动滑块只在停下来之后写一次文件，避免频繁读写",
        })
        as:AddDivider()
        as:AddButton({ Text = "立即保存一次", Icon = "save", Func = function()
            R._cfgDirty = false
            local ok = saveConfig()
            R._cfgSaveCount = (R._cfgSaveCount or 0) + 1
            R._lastAutoSave = os.date("%H:%M:%S")
            log("手动保存: " .. (ok and "成功 ✓" or "失败 ✗"), ok and Color3.fromRGB(120, 255, 140)
                or Color3.fromRGB(255, 120, 120))
        end })
        as:AddButton({ Text = "重新从文件加载配置", Icon = "rotate-ccw", Func = function()
            local ok = loadConfig()
            if ok then
                applyCfgToUI(); readUIIntoCfg(); refreshCandidates()
                log("已从文件重新加载配置 ✓", Color3.fromRGB(120, 255, 140))
            else
                log("加载失败（文件不存在或损坏）", Color3.fromRGB(255, 120, 120))
            end
        end })
        as:AddButton({ Text = "打开配置文件所在位置", Icon = "folder-open", Func = function()
            log("配置文件路径: " .. CONFIG_FILE)
            log("已保存次数: " .. tostring(R._cfgSaveCount or 0) .. " · 上次: " .. tostring(R._lastAutoSave or "-"))
            local d = tostring(R._cfgDirty)
            log("当前是否有未保存改动: " .. d)
        end })
    end

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

    --================ 钓鱼
    do
        local fg = Tabs.Fish:AddLeftGroupbox("自动钓鱼", "fish")
        E.tAutoFish = fg:AddToggle("autoFish", {
            Text = "启用自动钓鱼 ★", Default = cfg.autoFish == true,
            Tooltip = "自动点游戏的钓鱼按钮，并打开游戏内置的「Auto Fish」。"
                .. "注意：只会点免费的那个，绝不碰付费的 Quick Fish。",
        })
        E.lFish = fg:AddLabel("状态: —", true)
        fg:AddDivider()
        E.tFishEnsure = fg:AddToggle("fishEnsureAuto", {
            Text = "自动保持内置自动捕鱼开启", Default = cfg.fishEnsureAuto ~= false,
            Tooltip = "每 2 秒复查一次；发现被关掉了就自动点回去",
        })
        E.sFishStall = fg:AddSlider("fishStallSeconds", {
            Text = "多久没鱼上钩就重按钓鱼", Default = tonumber(cfg.fishStallSeconds) or 45,
            Min = 15, Max = 180, Rounding = 0, Suffix = " 秒",
            Tooltip = "钓鱼结束后鱼漂会留在水里，所以只能用「多久没出现 Click To Catch!」判断会话是否还活着。"
                .. "超过这个时间没鱼上钩，就重新点一次《点击开始钓鱼》（游戏会自己传送回钓点）。",
        })
        E.tFishTp = fg:AddToggle("autoFishTeleport", {
            Text = "游戏没传送时自己补一次 ★", Default = cfg.autoFishTeleport ~= false,
            Tooltip = "实测点《点击开始钓鱼》游戏通常会自己传送回钓点，但有时不会（尤其你离开河岸后）。"
                .. "开启后：连续点了几次都没恢复钓鱼，脚本就自己把你传回最近的钓点。",
        })
        E.lFishPond = fg:AddLabel("钓点: —", true)
        fg:AddDivider()
        fg:AddButton({ Text = "传送到最近钓点", Icon = "map-pin", Func = function()
            local pos, name, dist = nearestPondPoint()
            if not pos then log("找不到钓点区域", Color3.fromRGB(255, 120, 120)) return end
            teleportToPond(pos)
            log("已传送到钓点 " .. tostring(name) .. "（" .. string.format("%.0f", dist) .. " 格）")
        end })
        fg:AddButton({ Text = "查看钓点状态", Icon = "search", Func = function()
            local areas = pondAreas()
            local pos, name, dist = nearestPondPoint()
            log("钓点区域 " .. #areas .. " 个 · 当前在: " .. tostring(inPond()) ..
                " · 最近: " .. tostring(name) .. " " .. string.format("%.0f", dist or -1) .. " 格" ..
                " · 钓鱼中: " .. tostring(isFishing()))
        end })
        fg:AddDivider()
        fg:AddButton({ Text = "立刻开一次钓鱼", Icon = "play", Func = function()
            local ok = clickFish()
            setAutoFish(true)
            log("已点击钓鱼按钮 ok=" .. tostring(ok))
        end })
        fg:AddButton({ Text = "切换内置自动捕鱼", Icon = "repeat", Func = function()
            local cur = autoFishOn()
            if cur == nil then log("读不到自动捕鱼状态（UI 可能没加载）", Color3.fromRGB(255, 180, 80)) return end
            local ok, msg = setAutoFish(not cur)
            log("内置自动捕鱼 -> " .. tostring(msg) .. " ok=" .. tostring(ok))
        end })
        fg:AddButton({ Text = "读取当前钓鱼状态", Icon = "search", Func = function()
            local n, txt = fishCatchCount()
            log("自动捕鱼=" .. tostring(autoFishOn()) .. " · 计数=" .. tostring(n) .. " · 文本='" .. tostring(txt) .. "'")
        end })
    end

    --================ 去突变（Depolarizer）
    do
        local wg = Tabs.Wash:AddLeftGroupbox("Depolarizer 去突变", "sparkles")
        E.lWash = wg:AddLabel("去突变: —", true)
        wg:AddDivider()
        E.tWash = wg:AddToggle("washEnabled", {
            Text = "启用自动去突变", Default = cfg.washEnabled == true,
            Tooltip = "⚠ 洗突变【不可撤销】！机器一次只能洗一个、耗时数小时。"
                .. "开启后：机器一空闲就自动把符合下面条件的角色放上去洗。",
        })
        wg:AddDivider()
        E.dWashTypes = wg:AddDropdown("washTypes", {
            Text = "要洗掉的突变 ★（必须选）",
            Values = { Gold = "Gold 黄金", Lava = "Lava 岩浆", Honey = "Honey 蜂蜜", Blood = "Blood 血",
                       Diamond = "Diamond 钻石", Ghost = "Ghost 幽灵", Slime = "Slime 史莱姆",
                       Frozen = "Frozen 冰", Electric = "Electric 电", Zombie = "Zombie 僵尸",
                       Nightmare = "Nightmare 噩梦", Dracula = "Dracula 德古拉", Demonic = "Demonic 恶魔",
                       Angelic = "Angelic 天使", Mars = "Mars 火星", Solar = "Solar 太阳",
                       Lunar = "Lunar 月", Party = "Party", Complexity = "Complexity", Toxic = "Toxic" },
            Multi = true, Default = cfg.washTypes or {},
        })
        E.dWashRar = wg:AddDropdown("washRarities", {
            Text = "参与品质 ★（必须选）",
            Values = (function()
                local rarVals = {}
                for name in pairs(RARITY_RANK) do rarVals[#rarVals + 1] = name end
                table.sort(rarVals, function(a, b) return (RARITY_RANK[a] or 0) < (RARITY_RANK[b] or 0) end)
                return rarVals
            end)(),
            Multi = true, Default = cfg.washRarities or {},
            Tooltip = "只有【这两个选择都命中】的角色才会被放进机器（双重保险）",
        })
        wg:AddDivider()
        wg:AddButton({ Text = "预览：会洗哪些角色", Icon = "search", Func = function()
            R._washPreviewShown = true
            R.renderWashList()
        end })
        wg:AddButton({ Text = "查看机器状态", Icon = "search", Func = function()
            local st, act = depoState()
            local tl = depoTimeLeft()
            local names = { idle = "空闲（可以放）", ready = "已手持可放", busy = "正在洗", none = "没有这台机器",
                            unknown = "未知" }
            log("Depolarizer: " .. tostring(names[st] or st) .. " · prompt='" .. tostring(act) ..
                "' · 剩余=" .. tostring(tl or "-") .. " · 本次已放入=" .. tostring(WASH.placed) ..
                " 个 · 上一个=" .. tostring(WASH.lastPlacedName or "-"))
            R.renderWashList()
            if st == "busy" then
                log("⚠ 正在洗的时候提示会变成『Skip (Robux)』—— 那是付费跳过，脚本绝不会点它",
                    Color3.fromRGB(255, 180, 80))
            end
        end })
        wg:AddButton({ Text = "手动洗：当前手持的角色", Icon = "sparkles", Func = function()
            local st = depoState()
            if st == "busy" then log("机器正在洗，不能放第二个", Color3.fromRGB(255, 180, 80)) return end
            if not R.hold.key then log("你还没有手持角色", Color3.fromRGB(255, 180, 80)) return end
            local hrp = rootPart()
            local pos = depoStandPos()
            if hrp and pos then
                pcall(function() hrp.CFrame = CFrame.new(pos) end)
            end
            task.wait(0.4)
            local prompt = depoPrompt()
            local en = false
            pcall(function() en = prompt and prompt.Enabled end)
            if not en then log("prompt 未启用（角色可能没有突变）", Color3.fromRGB(255, 180, 80)) return end
            depoFire(prompt)
            log("已尝试把 " .. tostring(R.hold.name) .. " 放进 Depolarizer", Color3.fromRGB(120, 255, 140))
        end })
    end

    --================ 洗突变预览列表（放在「Depolarizer 去突变」下面）
    do
        local wl = Tabs.Wash:AddLeftGroupbox("洗突变预览", "list")
        E.lWashList = wl:AddLabel("点上面的「预览：会洗哪些角色」查看清单", true)

        function R.renderWashList()
            if not E.lWashList then return end
            local list = washTargets()
            local allow = cfg.washRarities or {}
            local allowT = cfg.washTypes or {}
            local nR, nT = 0, 0
            for _ in pairs(allow) do nR = nR + 1 end
            for _ in pairs(allowT) do nT = nT + 1 end
            if nR == 0 or nT == 0 then
                E.lWashList:SetText('<font color="rgb(255,180,80)">⚠ 还没有勾选条件</font>\n' ..
                    '<font color="rgb(150,150,170)">请先在「要洗掉的突变」和「参与品质」两个多选里勾选</font>')
                return
            end
            if #list == 0 then
                E.lWashList:SetText('<font color="rgb(200,180,120)">没有符合条件的角色</font>\n' ..
                    '<font color="rgb(150,150,170)">（当前背包里没有「选中的突变 + 选中的品质」的角色）</font>')
                return
            end
            local lines, total = {}, 0
            local cap = math.min(#list, 30)
            for i = 1, cap do
                local c = list[i]
                total = total + c.cps
                local rc = RARITY_COLORS[c.rarity] or Color3.fromRGB(220, 220, 220)
                lines[#lines + 1] = string.format(
                    '<font color="rgb(%d,%d,%d)">%2d. %s</font>  <font color="rgb(150,150,170)">[%s]</font>  '
                    .. '<font color="rgb(255,180,90)">%s</font>  <font color="rgb(120,255,140)">$%s/s</font>',
                    math.floor(rc.R * 255), math.floor(rc.G * 255), math.floor(rc.B * 255),
                    i, c.name, c.rarity, c.ty, fmtCps(c.cps))
            end
            if #list > cap then
                lines[#lines + 1] = string.format('<font color="rgb(150,150,170)">   … 还有 %d 个</font>', #list - cap)
            end
            lines[#lines + 1] = ""
            local st = depoState()
            local busy = (st == "busy")
            lines[#lines + 1] = string.format(
                '<font color="rgb(120,220,255)">共 %d 个 · 合计 $%s/s</font>   <font color="rgb(200,200,120)">约需 %.1f 天（按 11.4 小时/个）</font>',
                #list, fmtCps(total), #list * 11.42 / 24)
            lines[#lines + 1] = string.format('<font color="rgb(160,160,190)">机器: %s%s</font>',
                busy and "正在洗（占用中）" or "空闲（会自动放下一个）",
                busy and (" · 剩余 " .. tostring(depoTimeLeft() or "-")) or "")
            E.lWashList:SetText(table.concat(lines, "\n"))
        end

        E.tWashAuto = wl:AddToggle("washAutoPreview", {
            Text = "自动刷新这个列表", Default = cfg.washAutoPreview ~= false,
            Tooltip = "每 2 秒自动重扫背包并刷新上面的清单，不用手动点预览",
        })
        wl:AddButton({ Text = "刷新列表", Icon = "refresh-cw", Func = function()
            refreshCandidates()
            R.renderWashList()
        end })
    end

    --================ Solar
    do
        local sg = Tabs.Solar:AddLeftGroupbox("Solar 陨石雨", "flame")
        E.tSolar = sg:AddToggle("solarEnabled", {
            Text = "启用 Solar 模块 ★", Default = cfg.solarEnabled ~= false,
            Tooltip = "Solar 活动期间：陨石一生成立刻传送到落点，并保持手持候选角色（落地时判定突变）。"
                .. "活动期间自动钓鱼会自动让路，不会把你拉回钓点。",
        })
        E.lSolar = sg:AddLabel("Solar: —", true)
        sg:AddDivider()
        E.dSolarTargets = sg:AddDropdown("solarTargets", {
            Text = "想要的 Solar 突变",
            Values = { Mars = "Mars 火星（Solar，倍数 6）★", Angelic = "Angelic 天使（Heaven，倍数 6）★",
                       Lava = "Lava 岩浆（2）", Gold = "Gold 黄金（1.25）",
                       Solar = "Solar", Blood = "Blood", Honey = "Honey",
                       Nightmare = "Nightmare", Diamond = "Diamond", Ghost = "Ghost", Slime = "Slime" },
            Multi = true, Default = cfg.solarTargets or { Mars = true },
        })
        -- Solar 专属品质选择（与万圣节的品质勾选独立）
        do
            local rarVals = {}
            for name in pairs(RARITY_RANK) do rarVals[#rarVals + 1] = name end
            table.sort(rarVals, function(a, b) return (RARITY_RANK[a] or 0) < (RARITY_RANK[b] or 0) end)
            E.dSolarRar = sg:AddDropdown("solarRarities", {
                Text = "Solar 参与品质 ★",
                Values = rarVals, Multi = true,
                Default = cfg.solarRarities or { Ancient = true, Celestial = true },
                Tooltip = "只有这些品质的【干净】角色会被拿去赌 Solar 突变（与万圣节的品质勾选相互独立）",
            })
        end
        E.tSolarReq = sg:AddToggle("solarRequireCandidate", {
            Text = "没有可用角色就不介入 ★", Default = cfg.solarRequireCandidate ~= false,
            Tooltip = "勾选品质里的白板角色用完时：不传送、不手持、也不打断自动钓鱼（继续钓鱼）。"
                .. "中途角色被洗完/突变完也会自动退出陨石模式。",
        })
        E.tSolarTp = sg:AddToggle("solarTeleport", {            Text = "陨石生成就传送到落点", Default = cfg.solarTeleport ~= false,
            Tooltip = "实测：陨石垂直下落，落点就是生成时的 (X,Z)，生成到落地只有 0.5~2 秒",
        })
        E.sSolarHold = sg:AddSlider("solarMaxHold", {
            Text = "同一只最多手持", Default = tonumber(cfg.solarMaxHold) or 30,
            Min = 5, Max = 120, Rounding = 0, Suffix = " 秒",
            Tooltip = "一直没被砸中就换下一只候选",
        })
        E.sSolarPoll = sg:AddSlider("solarPoll", {
            Text = "Solar 反应间隔", Default = tonumber(cfg.solarPoll) or 0.25,
            Min = 0.05, Max = 1, Rounding = 2, Suffix = " 秒",
            Tooltip = "陨石从生成到落地只有 0.5~2 秒，这个值越小越灵敏（默认 0.25 秒 = 4Hz）",
        })
        E.tSolarPauseFish = sg:AddToggle("solarPauseFishing", {
            Text = "Solar 期间暂停自动钓鱼 ★", Default = cfg.solarPauseFishing ~= false,
            Tooltip = "必须开：否则自动钓鱼会把你拉回钓点，和陨石抢位置",
        })
        E.tSolarBurst = sg:AddToggle("solarHoldEveryMeteor", {
            Text = "每颗陨石刷新手持 ★", Default = cfg.solarHoldEveryMeteor ~= false,
            Tooltip = "游戏有个 bug：包里有多只同品质角色时，紧接着再手持会被判定成『误触』，"
                .. "角色不走完整的『消失→重新出现在身后』。开启后每颗陨石都做一次"
                .. "『先取消 → 再拿出』，强制它走完刷新。",
        })
        E.tBurst = sg:AddToggle("holdBurst", {
            Text = "所有手持都先取消再拿出（含万圣节）", Default = cfg.holdBurst ~= false,
            Tooltip = "对所有手持生效（Solar + 万圣节通用）。关闭则退化成单次手持。",
        })
        E.sBurstGap = sg:AddSlider("holdBurstGap", {
            Text = "每步间隔", Default = tonumber(cfg.holdBurstGap) or 0.02,
            Min = 0, Max = 0.3, Rounding = 2, Suffix = " 秒",
            Tooltip = "取消/拿出之间等多久。要『超快』就调小（默认 0.02）；被判定成误触就调大。",
        })
        E.sBurstCycles = sg:AddSlider("holdBurstCycles", {
            Text = "刷新手持轮数", Default = tonumber(cfg.holdBurstCycles) or 2,
            Min = 1, Max = 4, Rounding = 0, Suffix = " 轮",
            Tooltip = "1 轮 = 取消+拿出（2 次发包）；2 轮 = 连点 4 下，实测能无缝衔接快速掏出角色（默认 2）。",
        })
        sg:AddDivider()
        sg:AddButton({ Text = "★ 完整模拟测试（假陨石）", Icon = "flask-conical", Func = function()
            local ok, x, z = R.solarTest(25)
            if not ok then log("模拟测试启动失败: " .. tostring(x)) end
        end })
        sg:AddButton({ Text = "清理假陨石", Icon = "trash-2", Func = function()
            R.solarTestCleanup()
            log("已清理假陨石")
        end })
        sg:AddButton({ Text = "模拟 Solar（只切状态，30 秒）", Icon = "flask-conical", Func = function()
            R.debugForce("Solar", 30)
            log("已强制 Solar 30 秒（不会生成真实陨石）")
        end })
        sg:AddButton({ Text = "查看 Solar 状态", Icon = "search", Func = function()
            local S = solarState()
            log(string.format("Solar: 启用=%s 进行中=%s 事件=%s | 陨石 %d 颗 · 传送 %d 次 · 突变 %d 次（目标 %d）",
                tostring(cfg.solarEnabled), tostring(S.active), tostring(R.event.name),
                S.meteors, S.tp, S.hits, S.targets))
            log("空中陨石数=" .. tostring((function()
                local n = 0
                for _, d in ipairs(workspace:GetChildren()) do if d.Name == "Meteorite" then n = n + 1 end end
                return n
            end)()))
        end })
    end

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
    if E.tAutoFish then
        E.tAutoFish:OnChanged(function(v)
            cfg.autoFish = v == true
            if cfg.autoFish then
                log("自动钓鱼已开启：保持内置自动捕鱼开启 + 卡住自动重按")
                task.defer(function() pcall(fishTick) end)
            else
                log("自动钓鱼已关闭")
            end
        end)
    end
    if E.tFishEnsure then
        E.tFishEnsure:OnChanged(function(v) cfg.fishEnsureAuto = v == true end)
    end
    if E.sFishStall then
        E.sFishStall:OnChanged(function(v) cfg.fishStallSeconds = tonumber(v) or 15 end)
    end
    if E.tFishTp then
        E.tFishTp:OnChanged(function(v) cfg.autoFishTeleport = v == true end)
    end
    if E.tSolar then
        E.tSolar:OnChanged(function(v)
            cfg.solarEnabled = v == true
            if not cfg.solarEnabled and R.solar and R.solar.active then solarStop("已停用") end
            log("Solar 模块 = " .. tostring(cfg.solarEnabled))
        end)
    end
    if E.dSolarTargets then
        E.dSolarTargets:OnChanged(function(v)
            cfg.solarTargets = (type(v) == "table") and v or {}
            local names = {}
            for k, on in pairs(cfg.solarTargets) do if on then names[#names + 1] = k end end
            table.sort(names)
            log("Solar 目标突变 = " .. (#names > 0 and table.concat(names, ", ") or "（空，默认 Mars）"))
        end)
    end
    if E.dSolarRar then
        E.dSolarRar:OnChanged(function(v)
            cfg.solarRarities = (type(v) == "table") and v or {}
            local names = {}
            for k, on in pairs(cfg.solarRarities) do if on then names[#names + 1] = k end end
            table.sort(names, function(a, b) return (RARITY_RANK[a] or 0) > (RARITY_RANK[b] or 0) end)
            log("Solar 参与品质 = " .. (#names > 0 and table.concat(names, " > ") or "（空）"))
            if R.solar and R.solar.active then refreshCandidates(cfg.solarRarities) end
        end)
    end
    if E.tSolarTp then
        E.tSolarTp:OnChanged(function(v) cfg.solarTeleport = v == true end)
    end
    if E.tSolarReq then
        E.tSolarReq:OnChanged(function(v)
            cfg.solarRequireCandidate = v == true
            log("没有可用白板角色时不介入 = " .. tostring(cfg.solarRequireCandidate))
        end)
    end
    if E.sSolarHold then
        E.sSolarHold:OnChanged(function(v) cfg.solarMaxHold = tonumber(v) or 30 end)
    end
    if E.sSolarPoll then
        E.sSolarPoll:OnChanged(function(v) cfg.solarPoll = tonumber(v) or 0.25 end)
    end
    if E.tSolarPauseFish then
        E.tSolarPauseFish:OnChanged(function(v) cfg.solarPauseFishing = v == true end)
    end
    if E.tSolarBurst then
        E.tSolarBurst:OnChanged(function(v)
            cfg.solarHoldEveryMeteor = v == true
            log("每颗陨石强制刷新手持 = " .. tostring(cfg.solarHoldEveryMeteor))
        end)
    end
    if E.tBurst then
        E.tBurst:OnChanged(function(v)
            cfg.holdBurst = v == true
            log("手持『先取消再拿出』= " .. tostring(cfg.holdBurst) .. "（万圣节与 Solar 通用）")
        end)
    end
    if E.sBurstGap then
        E.sBurstGap:OnChanged(function(v) cfg.holdBurstGap = tonumber(v) or 0.02 end)
    end
    if E.sBurstCycles then
        E.sBurstCycles:OnChanged(function(v) cfg.holdBurstCycles = math.max(1, math.floor(tonumber(v) or 2)) end)
    end
    if E.tAutoSave then
        E.tAutoSave:OnChanged(function(v)
            cfg.autoSave = v == true
            log("配置自动保存 = " .. tostring(cfg.autoSave))
            if cfg.autoSave then saveConfig(true) end
        end)
    end
    if E.sAutoSaveDelay then
        E.sAutoSaveDelay:OnChanged(function(v) cfg.autoSaveDelay = tonumber(v) or 1.5 end)
    end
    if E.tWash then
        E.tWash:OnChanged(function(v)            cfg.washEnabled = v == true
            if cfg.washEnabled then
                local nt = 0
                for _ in pairs(cfg.washTypes or {}) do nt = nt + 1 end
                local nr = 0
                for _ in pairs(cfg.washRarities or {}) do nr = nr + 1 end
                log("去突变已开启（突变勾选 " .. nt .. " 项 · 品质勾选 " .. nr .. " 项）")
                if nt == 0 or nr == 0 then
                    log("⚠ 你还没勾选突变或品质 -> 脚本不会洗任何角色", Color3.fromRGB(255, 180, 80))
                end
            else
                log("去突变已关闭")
            end
        end)
    end
    if E.dWashTypes then
        E.dWashTypes:OnChanged(function(v)
            cfg.washTypes = (type(v) == "table") and v or {}
            local n = {}
            for k, on in pairs(cfg.washTypes) do if on then n[#n + 1] = k end end
            table.sort(n)
            log("要洗掉的突变 = " .. (#n > 0 and table.concat(n, ", ") or "（空 —— 不会洗任何角色）"))
            if R.renderWashList then pcall(R.renderWashList) end
        end)
    end
    if E.dWashRar then
        E.dWashRar:OnChanged(function(v)
            cfg.washRarities = (type(v) == "table") and v or {}
            local n = {}
            for k, on in pairs(cfg.washRarities) do if on then n[#n + 1] = k end end
            table.sort(n, function(a, b) return (RARITY_RANK[a] or 0) > (RARITY_RANK[b] or 0) end)
            log("去突变参与品质 = " .. (#n > 0 and table.concat(n, " > ") or "（空 —— 不会洗任何角色）"))
            if R.renderWashList then pcall(R.renderWashList) end
        end)
    end
    if E.tWashAuto then
        E.tWashAuto:OnChanged(function(v) cfg.washAutoPreview = v == true end)
    end
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
        -- 钓鱼状态
        if E.lFish then
            local on = autoFishOn()
            local bite = fishHasBite()
            local idle = os.clock() - (FISH.lastBite or os.clock())
            local state = (on == true) and '<font color="rgb(120,255,140)">已开启</font>'
                or (on == false) and '<font color="rgb(255,200,90)">已关闭</font>'
                or '<font color="rgb(160,160,180)">读不到</font>'
            E.lFish:SetText(string.format('自动钓鱼: %s · 内置AutoFish %s\n状态: %s · 距上次上钩 %.0f 秒（阈值 %d 秒）\n上钩累计 %d 次 · 收获计数 %s\n重按钓鱼 %d 次 · 补开自动捕鱼 %d 次 · 补传送 %d 次',
                cfg.autoFish and '<font color="rgb(120,255,140)">运行中</font>' or '<font color="rgb(160,160,180)">未启用</font>',
                state,
                bite and '<font color="rgb(120,255,140)">刚上钩</font>' or '<font color="rgb(255,200,90)">等待中</font>',
                idle, tonumber(cfg.fishStallSeconds) or 45,
                FISH.bites or 0, tostring(FISH.lastCatchText or "?"),
                FISH.starts or 0, FISH.ensured, FISH.tp or 0))
        end

        -- 钓点状态
        if E.lFishPond then
            local inside = inPond()
            local pos, name, dist = nearestPondPoint()
            E.lFishPond:SetText(string.format('钓点: %s · 最近 %s（%.0f 格）',
                inside and ('<font color="rgb(120,255,140)">在 ' .. inside .. ' 内</font>')
                    or '<font color="rgb(255,200,90)">不在钓点内</font>',
                tostring(name or "?"), tonumber(dist) or 0))
        end

        -- Solar 状态
        if E.lSolar then
            local S = solarState()
            local air = 0
            for _, d in ipairs(workspace:GetChildren()) do if d.Name == "Meteorite" then air = air + 1 end end
            E.lSolar:SetText(string.format('Solar: %s · 空中陨石 %d 颗\n陨石 %d · 传送 %d · 突变 %d（目标 %d）\n目标突变: %s',
                S.active and '<font color="rgb(120,255,140)">进行中</font>'
                    or (isSolar() and '<font color="rgb(255,200,90)">事件在但未激活</font>')
                    or '<font color="rgb(160,160,180)">未开始</font>',
                air, S.meteors, S.tp, S.hits, S.targets,
                (function()
                    local n = {}
                    for k, on in pairs(solarTargetSet()) do if on then n[#n + 1] = k end end
                    table.sort(n)
                    return table.concat(n, ", ")
                end)()))
        end

        -- 自动保存状态
        if E.lAutoSave then
            E.lAutoSave:SetText(string.format('自动保存: %s · 已保存 %d 次\n上次写盘 %s · 待保存改动 %s',
                (cfg.autoSave ~= false) and '<font color="rgb(120,255,140)">开启</font>'
                    or '<font color="rgb(255,200,90)">关闭</font>',
                R._cfgSaveCount or 0, tostring(R._lastAutoSave or "-"),
                R._cfgDirty and '<font color="rgb(255,200,90)">有</font>'
                    or '<font color="rgb(120,255,140)">无</font>'))
        end

        -- 去突变状态
        if E.lWash then
            local st, act = depoState()
            local tl = depoTimeLeft()
            local names = { idle = '<font color="rgb(120,255,140)">空闲</font>',
                            ready = '<font color="rgb(120,255,140)">已手持可放</font>',
                            busy = '<font color="rgb(255,200,90)">正在洗</font>',
                            none = '<font color="rgb(255,120,120)">没有机器</font>',
                            unknown = '<font color="rgb(160,160,180)">未知</font>' }
            local nt, nr = 0, 0
            for _ in pairs(cfg.washTypes or {}) do nt = nt + 1 end
            for _ in pairs(cfg.washRarities or {}) do nr = nr + 1 end
            E.lWash:SetText(string.format('去突变: %s · 剩余 %s\n本次已放入 %d 个 · 上一个: %s\n勾选: 突变 %d 项 · 品质 %d 项',
                names[st] or st, tostring(tl or "-"), WASH.placed, tostring(WASH.lastPlacedName or "-"), nt, nr))
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
    -- ⭐ 卸载 / 重载前立刻落盘一次：这样"重载脚本 / 载入新版本"绝不会丢配置
    if cfg.autoSave ~= false then
        local okSave = pcall(saveConfig, true)
        if okSave then print(PREFIX .. " 卸载前已自动保存配置") end
    end
    for _, c in ipairs(R.connections or {}) do pcall(function() c:Disconnect() end) end
    R.connections = {}
    for _, t in ipairs(R.threads or {}) do pcall(function() task.cancel(t) end) end
    R.threads = {}
    pcall(doRelease)
    if R.restoreClientInsertHooks then pcall(R.restoreClientInsertHooks) end
    if R.unhookHotbar then pcall(R.unhookHotbar) end
    -- 卸载时只销毁"我们标记过的"那个 ScreenGui（Library:Unload 本身也是只删自己那个，安全）
    if R._uiGui then
        local okMark = false
        pcall(function() okMark = R._uiGui:GetAttribute(UI_MARK) ~= nil end)
        if okMark then pcall(function() R._uiGui:Destroy() end) end
        R._uiGui = nil
    end
    if R._library then
        if R._library.Unload then pcall(function() R._library:Unload() end) end
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
-- 自动钓鱼 API
R.fishStatus = function()
    local bite, txt = fishHasBite()
    return { enabled = cfg.autoFish, autoFishOn = autoFishOn(), hasBite = bite, text = txt,
             ballDist = nearestFishBallDist(),
             idleSec = os.clock() - (FISH.lastBite or os.clock()),
             bites = FISH.bites or 0, catches = FISH.catches or 0, catchText = tostring(FISH.lastCatchText),
             watcher = R._fishWatch ~= nil,
             clicks = FISH.clicks, ensured = FISH.ensured, starts = FISH.starts or 0, tp = FISH.tp or 0 }
end
R.fishOn = function(v)
    cfg.autoFish = (v ~= false)
    if E.tAutoFish and E.tAutoFish.SetValue then pcall(function() E.tAutoFish:SetValue(cfg.autoFish) end) end
    log("自动钓鱼 = " .. tostring(cfg.autoFish))
    return cfg.autoFish
end
R.fishStart = function()
    local a = setAutoFish(true)
    local b = clickFish()
    return { auto = a, click = b }
end
R.fishToggleAuto = function()
    local cur = autoFishOn()
    if cur == nil then return false end
    return setAutoFish(not cur)
end
R.pondInfo = function()
    local areas = pondAreas()
    local pos, name, dist = nearestPondPoint()
    return { count = #areas, inside = inPond(), nearest = name, distance = dist,
             fishing = isFishing(), autoFishOn = autoFishOn() }
end
R.gotoPond = function()
    local pos, name, dist = nearestPondPoint()
    if not pos then return false end
    teleportToPond(pos)
    return true, name, dist
end

--============================================================== Solar 完整模拟测试
-- 自己造一颗"假陨石"（Name="Meteorite" 的 Model + 下落动画），走**真实的监听路径**，
-- 验证 监听 -> 传送 -> 手持 -> 记账 全链路是否工作。
R.solarTest = function(dur)
    local hrp = rootPart()
    if not hrp then return false, "没有角色" end
    local S = solarState()
    -- ① 强制 Solar 状态（仅当真实事件就是 Solar、或当前没有别的突变事件时才真正进入陨石模式）
    R._force = { name = "Solar", until_ = os.clock() + (tonumber(dur) or 25) }
    R._forceYielded = nil
    local realOther = R.event.active and R.event.name and R.event.name ~= "Solar" and eventRemaining() > 0
    if realOther then
        log("【测试】当前真实事件是 " .. tostring(R.event.name) ..
            " -> 安全守卫生效：只测试『监听+传送』路径，不手持角色（避免被真实突变烧掉）",
            Color3.fromRGB(255, 200, 90))
    elseif not S.active then
        solarStart()
    end
    -- ② 在离玩家 120 格处生成假陨石（高度用实测的生成高度 182）
    local ang = math.random() * math.pi * 2
    local dist = 120
    local x = hrp.Position.X + math.cos(ang) * dist
    local z = hrp.Position.Z + math.sin(ang) * dist
    R.solarTestCleanup()
    R._solarTestActive = true          -- ⭐ 必须先立标志：下面 Parent 赋值会**同步**触发 ChildAdded
    local model = Instance.new("Model")
    model.Name = "Meteorite"
    local part = Instance.new("Part")
    part.Name = "Base"
    part.Size = Vector3.new(5, 5, 5)
    part.Anchored = true
    part.CanCollide = false
    part.Material = Enum.Material.Neon
    part.Color = Color3.fromRGB(255, 120, 30)
    part.Position = Vector3.new(x, 182, z)
    part.Parent = model
    model.PrimaryPart = part
    R._testMeteor = model              -- ⭐ 同样必须在 Parent 之前设置
    model.Parent = workspace
    log(string.format("【测试】已在 (%.0f, 182, %.0f) 生成假陨石，距玩家 %.0f 格", x, z, dist),
        Color3.fromRGB(255, 180, 90))
    -- ③ 让它下落（Y 递减，模拟真实陨石）
    task.spawn(function()
        local y = 182
        while y > 66 and model.Parent do
            y = y - 7
            pcall(function() part.Position = Vector3.new(x, y, z) end)
            task.wait(0.05)
        end
        if model.Parent then
            log(string.format("【测试】假陨石已落地 Y=%.0f（落点 %.0f, %.0f）", y, x, z))
        end
    end)
    -- ④ 自动核对结果
    task.delay(1.5, function()
        local h = rootPart()
        if not h then return end
        local d = (Vector3.new(x, h.Position.Y, z) - h.Position).Magnitude
        log(string.format("【测试】生成后 1.5 秒：距假陨石落点 %.1f 格 -> %s",
            d, d < 10 and "✓ 传送成功" or "✗ 传送没生效（检查 solarTeleport / 监听）"),
            d < 10 and Color3.fromRGB(120, 255, 140) or Color3.fromRGB(255, 120, 120))
        log("【测试】当前手持=" .. tostring(R.hold.key) .. " · 候选=" .. #R.candidates ..
            " · 陨石计数=" .. S.meteors .. " · 传送计数=" .. S.tp)
        if R.hold.key then
            local tf = workspace:FindFirstChild("ToolFollowers")
            local held = "无"
            if tf then
                for _, c in ipairs(tf:GetChildren()) do
                    local n = c.Name:match("^ToolFollower_(.+)$")
                    if n then held = n end
                end
            end
            log("【测试】实际手持模型=" .. held .. (held ~= "无" and " ✓ 已出现在身侧" or " ✗ 没出现"))
        end
    end)
    return true, x, z
end

R.solarTestCleanup = function()
    R._solarTestActive = false
    if R._testMeteor then
        pcall(function() R._testMeteor:Destroy() end)
        R._testMeteor = nil
    end
end

--============================================================== 彻底清理
-- 一键清掉本脚本产生的一切残留：实例（按魔数识别）、UI（按标记识别）、
-- 以及所有后台观察器线程（用代号让旧循环全部失效）。
R.washStatus = function()
    local st, act = depoState()
    return { enabled = cfg.washEnabled, state = st, actionText = act, timeLeft = depoTimeLeft(),
             placed = WASH.placed, last = WASH.lastPlacedName,
             types = cfg.washTypes, rarities = cfg.washRarities, targets = #washTargets() }
end
R.washOn = function(v)
    cfg.washEnabled = v ~= false
    log("去突变 = " .. tostring(cfg.washEnabled))
end

R.panicCleanup = function()
    local n = 0
    -- ① 所有"我们的"状态实例
    if type(getgc) == "function" then
        local ok, list = pcall(getgc, true)
        if ok and type(list) == "table" then
            for _, obj in ipairs(list) do
                if type(obj) == "table" and obj ~= R then
                    local ours = false
                    pcall(function() ours = rawget(obj, "__HW_MAGIC") == MAGIC end)
                    if ours then
                        pcall(function()
                            local d = rawget(obj, "destroy")
                            if type(d) == "function" then d() end
                        end)
                        n = n + 1
                    end
                end
            end
        end
    end
    -- ② 观察器线程（代号 +1 让所有旧循环退出）
    _G.__METEOR_WATCH = false
    _G.__MW_GEN = (_G.__MW_GEN or 0) + 1
    pcall(function() if _G.__MW_CONN then _G.__MW_CONN:Disconnect() end end)
    _G.__MW_CONN = nil
    -- ③ 假陨石
    pcall(function() if _G.HW_MUTATOR and _G.HW_MUTATOR.solarTestCleanup then _G.HW_MUTATOR.solarTestCleanup() end end)
    -- ④ 我们标记过的 UI
    local ui = 0
    for _, cont in ipairs(uiContainers()) do
        for _, c in ipairs(cont:GetChildren()) do
            local marked = false
            pcall(function() marked = c:IsA("ScreenGui") and c:GetAttribute("HW_MutatorOwned") ~= nil end)
            if marked then pcall(function() c:Destroy() end) ui = ui + 1 end
        end
    end
    print(PREFIX .. " 彻底清理：实例 " .. n .. " 个 · UI " .. ui .. " 个 · 观察器已停")
    return n, ui
end
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
    R._forceYielded = nil
    log("debug: 强制事件 " .. R._force.name .. " " .. tostring(seconds or 15) .. "s（注意风险）", Color3.fromRGB(255, 200, 90))
end
R.debugClear = function() R._force = nil; R._forceYielded = nil; log("debug: 已清除强制事件") end

-- 测试：给当前手持的角色注入一个假的 Dracula 突变，走**真实代码路径**验证
--      "命中检测 -> 记账 -> 放手 -> 换下一只 -> 刷新快捷栏" 全链路
R.simulateHit = function(keepClean)
    if not R.hold.key then return false, "当前没有手持（先 debugForce 让它持一只）" end
    local s = {}
    for k, v in pairs(R.summary or {}) do s[k] = v end
    if (not keepClean) and type(s[R.hold.key]) == "table" then
        -- 真实情况：这一只突变后，干净的那条就没了（除非你还有第二只干净的同名，c>1）
        local c = tonumber(s[R.hold.key].c) or 1
        if c <= 1 then
            s[R.hold.key] = nil
        else
            local cp = {}
            for k, v in pairs(s[R.hold.key]) do cp[k] = v end
            cp.c = c - 1
            s[R.hold.key] = cp
        end
    end
    s[R.hold.key .. "Dracula|"] = { ty = "Dracula", c = 1, n = R.hold.name, ra = R.hold.rarity, bl = 1 }
    local hits = detectMutation(R.hold.baseline, s, R.hold.name)
    if #hits == 0 then return false, "注入的假突变未被识别（突变检测逻辑有问题！）" end
    R.summary = s
    R.stats.dracula = (R.stats.dracula or 0) + 1
    log("【测试】给 " .. tostring(R.hold.name) .. " 注入假 Dracula 突变（干净那只已消耗）-> 识别到 " .. #hits .. " 个命中",
        Color3.fromRGB(255, 180, 90))
    advanceAfterHit(s)
    return true, R.hold.name
end
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

-- ⭐ 配置自动保存线程：用"签名差分"检测一切改动（元表 __newindex 对已存在的键不触发，
--    所以不能只靠它）。检测到变化就防抖写盘，另加"心跳兜底"。
R.threads[#R.threads + 1] = task.spawn(function()
    local lastHeartbeat = os.clock()
    while isCurrent() do
        task.wait(0.5)
        if cfg.autoSave ~= false then
            local now = os.clock()
            -- ① 签名差分：任何改动（含嵌套表）都会被发现
            local sig = cfgSignature(cfg)
            if sig ~= R._cfgSig then
                R._cfgSig = sig
                R._cfgDirty = true
                R._cfgChangedAt = now
            end
            -- ② 防抖：停止改动 autoSaveDelay 秒后才写盘（拖滑块时不会狂写文件）
            local delay = tonumber(cfg.autoSaveDelay) or 1.5
            local hb = tonumber(cfg.autoSaveHeartbeat) or 120
            local due = R._cfgDirty and (now - (R._cfgChangedAt or 0)) >= delay
            local beat = hb > 0 and (now - lastHeartbeat) >= hb
            if due or beat then
                lastHeartbeat = now
                R._cfgDirty = false
                R._cfgSaveCount = (R._cfgSaveCount or 0) + 1
                R._lastAutoSave = os.date("%H:%M:%S")
                saveConfig(true)          -- 静默保存（避免刷屏），状态显示在面板上
            end
        end
    end
end)

-- 独立的界面刷新线程（5Hz）：主循环空闲时要 3 秒才跑一轮，
-- 倒计时/让路剩余/手持时长挂在它上面就会"一卡一卡"。这里解耦成固定 0.2 秒刷新。
R.threads[#R.threads + 1] = task.spawn(function()
    local lastWash = 0
    while isCurrent() do
        if R.renderStatus then pcall(R.renderStatus) end
        -- 去突变预览列表：每 2 秒自动刷新（背包一变就能看到）
        local now = os.clock()
        if cfg.washAutoPreview ~= false and R.renderWashList and (now - lastWash) >= 2 then
            lastWash = now
            if (not R._lastSummaryAt) or (now - R._lastSummaryAt >= 1) then pcall(refreshCandidates) end
            pcall(R.renderWashList)
        end
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
