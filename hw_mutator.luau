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

local VERSION = 375
local PREFIX = "[HW]"
local CONFIG_FILE = "hw_mutator_config.json"
local EVENT_NAME = "Halloween"
local OBSIDIAN_REPO = "https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/"

--============================================================== 全局常量表
-- ⚠ 集中放常量：**Lua 每个 chunk 最多 200 个 local**，而这个文件的主 chunk 已经接近上限
--   （曾经报 "Out of local registers ... exceeded limit 200"，且报错位置在文件末尾，极难定位）。
--   所以零散的常量表统一挂到 HW_K 上，只占 1 个 local 名额。
local HW_K = {}
HW_K.SUFFIX_MUL = { ["K"] = 1e3, ["M"] = 1e6, ["B"] = 1e9, ["T"] = 1e12, ["Qa"] = 1e15,
    ["Qi"] = 1e18, ["Sx"] = 1e21, ["Sp"] = 1e24, ["Oc"] = 1e27, ["No"] = 1e30, ["Dc"] = 1e33 }
-- ★ 食物速率采样的两个参数（v167）。⚠⚠ **绝不能写成顶层 local** ——
--   v167 就是因为在顶层加了这两个 local 而撞上 200 个 local 上限，
--   报 "Out of local registers ... exceeded limit 200"（报错位置在文件末尾，极难定位）。
--   按本文件既定对策，零散常量一律挂到 HW_K 上，只占 1 个 local 名额。
HW_K.RATE_MIN_WINDOW = 8       -- 采样窗口下限（秒）：要横跨 2~4 次服务器推送才可信
HW_K.RATE_SANITY_MULT = 30     -- 读数不得超过花园属性的这个倍数（超出即判为假读数丢弃）

--============================================================== 环境守卫
if game.PlaceId ~= (74729868188364) then
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
-- ⚠ R 必须**先声明、后赋值**（不能写 `local R = _G[...]`）：
--   下面防双实例那段要把 R 重新指向"卸载后新建的干净表"，
--   若这里是 `local R = ...`，那在 do 块里 `R = ...` 只会**创建一个新的 local**，
--   外面的 R 仍然指向旧表 -> 整个脚本会操作一张已经被清空的表。
_G[GLOBAL_KEY] = _G[GLOBAL_KEY] or {}
local R
R = _G[GLOBAL_KEY]

-- ⚠ E（UI 元素引用表）必须在这里**提前声明**，不能等到 UI 段（原 7790 行）才 local：
--   Luau 的 local 只对声明之后的代码可见。角色筛选工厂（约 850 行）里的函数要用 E，
--   若 E 声明在 7790 行，工厂里的 E 会被解析成**全局变量**（恒为 nil）
--   -> 板块总预览那几行会静默不更新（不报错，最难查的那种）。
--   这里提前声明，原处的 `local E = {}` 已改为赋值（见 UI 段）。
local E = {}          -- UI 元素引用（实际填充在 buildUI）

--============================================================== 🛡 防双实例（v298）
-- ⚠⚠⚠ 用户实测的**游戏崩溃根因**：脚本被加载了**两个实例**。
--   日志实证（同一秒内两套启动日志）：
--     [HW] 18:10:55 Solar 目标突变 = Angelic, Mars     ← 实例 A
--     [HW] 18:10:56 Solar 目标突变 = Mars              ← 实例 B
--   两个实例 = 两套主循环 + 两套 UI + 抢同一个快捷栏/台子/喂食
--     ⇒ 负载翻倍、互相打架 ⇒ **进游戏一会儿就卡死/崩溃**。
--
--   ⚠⚠ 顺序很关键：这段必须在**下面那个"已运行就早退"检查之前**！
--     以前的写法把卸载代码放在早退检查**之后**，于是：
--       · 旧实例 version >= 新版 -> 走早退 `return` -> **卸载代码永远执行不到**
--         （而且只打印 "already running"，我不会收到 🛡 提示，白等）
--       · 旧实例 version <  新版 -> 才轮得到卸载
--     ⇒ 现在移到最前面：**无论版本高低，只要检测到已有实例就先完整卸载它**。
--
--   为什么用 hwUnload 而不是旧的 R.destroy：
--     · destroy 是半成品（只置 alive=false），旧实例卡在长操作里就停不下来；
--     · hwUnload 会断开连接、取消线程、销毁 UI、清 _G —— 真正停干净。
--
--   ⚠ 调用 hwUnload 之前**不要**先置 _G[GLOBAL_KEY]=nil，
--     否则旧实例的 isCurrent() 立刻为 false，我就拿不到它的线程表了。
do
    local old = _G[GLOBAL_KEY]
    if type(old) == "table" and rawget(old, "__HW_MAGIC") == MAGIC then
        local unloaded = false
        pcall(function()
            local u = rawget(old, "hwUnload")
            if type(u) == "function" then u() unloaded = true end
        end)
        if not unloaded then
            pcall(function()
                local d = rawget(old, "destroy")
                if type(d) == "function" then d() end
            end)
        end
        -- ⚠ 用 print 而不是 log：此处 log 还没定义（log 在 ~810 行才声明）。
        --   代价是这条消息**不会进持久日志**（持久日志只收 log()），
        --   只能在执行器控制台看到。所以下面另存一份到 R，供事后查询。
        print(PREFIX .. " 🛡 检测到已有实例 -> 已主动完整卸载（防双实例）")
        _G.__HW_LAST_DOUBLE = os.date("%H:%M:%S")
    end
    -- 卸载会清空状态表内容并把 _G 置 nil -> 必须**重新建立**干净的 R
    _G[GLOBAL_KEY] = nil
    R = nil
end
-- 重建全新状态表（hwUnload 已把旧的清干净/置 nil）
R = _G[GLOBAL_KEY] or {}
_G[GLOBAL_KEY] = R
R.__HW_MAGIC = MAGIC
_G.__HW_OWNER = MAGIC      -- 供卸载工具兜底识别本脚本的线程
R.version = VERSION
R.alive = true
R.gen = (R.gen or 0) + 1
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
    return R.alive and R.gen == (R.gen) and _G[GLOBAL_KEY] == R
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

HW_K.RARITY_COLORS = {
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
    releaseMaxTries = 3,            -- 🛡 同一个角色最多只发这么多次放手；达不到就停手+冷却60秒
    releaseMinGap = 2,              -- 🛡 两次放手之间最小间隔（秒）—— 防止一轮内狂发导致状态机错乱
    releaseTargetMax = 3,           -- 🛡 同一目标最多真发几次放手，超过就冷却 60 秒
                                    --   （实测：无限反复放手会让背包<->快捷栏状态机错乱、卡住最后一格）
    -- 🔵 手持时是否给快捷栏格子画蓝框（**默认关闭**，用户 2026-10 明确要求）
    -- ⚠⚠ 为什么关掉（实测数据，别再默认打开）：
    --   游戏自己的跟随/装备系统会**不断重画**原生选中框（实测抓到它在 Slot_1/Slot_2
    --   之间来回画），而脚本再怎么"定期重刷"也只能追着它跑 → 两边打架 → **蓝框闪烁**。
    --   实测 3.6 秒内状态变化 7 次：`Slot_1[我] → 无×7 → Slot_2[游] → Slot_1[游] → …`
    --   用户原话："只要能给服务器接受角色突变就行了，其他我不在意了"。
    --   ⇒ 默认 false。**突变与蓝框完全无关** —— 服务器判定只看
    --     `workspace.ToolFollowers` 里有没有那个角色的 ToolFollower（真持有）。
    --   想要框就把这项改回 true（会有闪烁，这是游戏机制决定的，不是脚本 bug）。
    nativeSelectionFrame = false,
    -- 🍬 万圣节糖果自动收集（v316）
    --   原理：`firetouchinterest(糖果, 角色HRP, 0/1)` 伪触碰 —— **完全不移动角色**，
    --   所以不影响钓鱼、Solar、喂食任何一个模块（也因此不需要抢 busy 锁）。
    --   ⚠ 默认关闭：先让你确认效果再开。
    --   ⚠ `firetouchinterest` 是执行器函数（不在 _G 里，但能直接调用）。
    --     如果哪天换了执行器不支持，会走"收不到"分支并在日志里提示。
    candyEnabled = false,
    candyScanSec = 1.5,            -- 扫描间隔（秒）；越小反应越快，但越费性能
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
    manualOverrideSeconds = 8,      -- 你一动快捷栏，脚本让路这么久（够你完成一次收放；太长会让功能失灵）
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
    solarCommitSeconds = 4.5,       -- ★ 锁定一颗陨石后站定等它落地的秒数（期间不理新陨石）
    solarPoll = 0.25,               -- Solar 期间主循环间隔（秒）—— 陨石只有 0.5~2 秒窗口，必须快
    holdBurst = true,               -- 手持前做「取消 -> 再拿出」循环，强制游戏刷新跟随角色
    holdBurstGap = 0.02,            -- 每步之间的间隔（秒）—— 要"超快"，默认 0.02
    holdBurstCycles = 2,            -- 循环轮数：2 轮 = 连点 4 下（实测无缝衔接）
    solarHoldEveryMeteor = true,    -- 每颗陨石都强制刷新一次手持（解决游戏"误触"导致角色不到身后）
    fallMinY = 110,                 -- 判定"高空掉落物"的 Y 阈值（Solar 陨石/Heaven 流星通用）
    -- ===== 🚪 自动关闭弹窗 =====
    autoBuyEnabled = false,         -- ★ v340 自动购买总开关（默认关：先看预演日志）
    autoBuyDryRun = true,           -- ★ v340 只预演不真买（默认开）
    autoBuyList = {},               -- ★ v340 允许自动购买的商品标题（多选，UI 动态填充）
    autoBuyMaxPerItem = 0,          -- ★ v340 单件价格上限（0=不限）
    autoBuyHourBudget = 0,          -- ★ v340 每小时总花费上限（0=不限）
    autoClaimQuests = true,         -- ★ v340 自动领任务奖励
    autoClaimPlaytime = true,       -- ★ v340 自动领游戏时长奖励
    autoClaimDaily = true,          -- ★ v340 自动领每日奖励
    autoSpin = true,                -- ★ v340 自动玩轮盘
    autoRebirth = false,            -- ★ v340 自动重生（⚠ 会重置进度，默认关）
    autoPoll = 2,                   -- ★ v340 轮询间隔（秒）
    autoDrinkEnabled = false,       -- ★ v345 自动喝药水（默认关：先看预演）
    autoDrinkDryRun = true,         -- ★ v345 只预演不真喝（默认开）
    autoDrinkList = {},             -- ★ v345 允许自动喝的药水名（多选，UI 动态填充）
    autoDrinkInterval = 30,         -- ★ v345 同一瓶药水最短间隔（秒）
    autoDrinkKeep = {},             -- ★ v369 保留清单（运行时派生；见下面两个真正的控件值）
    -- ★★★ v374：保留清单必须是**控件值**才能被库的配置系统保存！
    --   （原来只有纯 cfg 表 autoDrinkKeep ⇒ 「Overwrite config」存不下来 ⇒ 用户报的 bug）
    autoDrinkKeepList = {},         -- ★ v374 要保留哪些药水（多选下拉，库会保存）
    autoDrinkKeepNum = 3,           -- ★ v374 每瓶保留数量（滑块，库会保存）
    autoDrinkKeepRod = true,        -- ★ v345 喝完后把原来的手持（鱼竿）换回来（仅兜底路径用）
    autoDrinkMap = {},              -- ★ v350 自学习：药水名 -> 它对应的 Boosts 条目名（精确到期判定）
                                    --   ⚠ 这是**运行时学习**的、不落盘（配置系统已改成库的控件制，
                                    --     无控件的表不会被保存）⇒ 重进游戏后头一次喝某瓶药会重新学一遍；
                                    --     而"时长"每次自动从 Constants.Potions.Definitions 现读，不用学。
    autoDrinkDur = {},              -- ★ v350 药水名 -> 持续秒数（学习时顺便记下，作为到期判定兜底）
    autoCloseEnabled = true,        -- 自动关掉重进游戏时的弹窗（只点 Close，绝不碰付费按钮）
    autoCloseWelcome = true,        -- 离线收益弹窗（“欢迎回来~”）
    autoCloseDaily = true,          -- 每日签到弹窗
    autoCloseDelay = 1.5,           -- 弹窗出现后等多久再关（秒）—— 给游戏一点时间完成初始化
    -- ===== 🍖 自动喂食（Auto Feed）=====
    feedEnabled = false,            -- ⚠ 默认关闭（会消耗食物，必须你亲自打开）
    feedMode = "auto",              -- auto=攒够阈值才执行一批 / smart=随时喂最优的一口 / manual=只手动
    feedBatchFood = 3e9,            -- 攒批阈值（食物）：低于它不动手
    feedThresholdMaxMinutes = 0,    -- ⚠ 已废弃（v148）：旧版用它把阈值抬成"速率×分钟"，
                                    --   导致阈值随波动速率忽高忽低、永远追不上（用户实测踩到）。
                                    --   现在阈值只由 feedBatchFood 决定。这里保留键名仅为兼容。
    feedSitMinutes = 10,            -- ★ 诊断：食物达到阈值后放超过这么多分钟没喂就打日志提醒
    feedMinEfficiency = 0.02,       -- 性价比下限（每 1 食物换回的 CPS）
    feedMinCps = 1e6,               -- 低于这个 CPS 的台子不参与
    feedMinRelGain = 0.05,          -- ★ 相对收益门槛：单级绝对收益 < 全屋最高收益 x 这个比例 -> 不喂
                                    --   解决"效率陷阱"：低等级低 CPS 的角色虽然每食物收益更高，
                                    --   但绝对收益只有高产出角色的千分之一，喂它等于浪费食物。
    -- ===== 🎩 总经理（自动调参）=====
    mgrAutoTune = true,             -- 自动根据"食物盈余"调节相对收益门槛
    mgrTargetBufferMinutes = 12,    -- 目标：攒够一个阈值食物约需这么多分钟
    mgrMinRelGain = 0.02,           -- 自动调参下限（门槛最松 2%）
    mgrMaxRelGain = 0.30,           -- 自动调参上限（门槛最紧 30%）
    mgrAdjustCooldown = 10,         -- 两次自动调参之间至少间隔（分钟）
    -- ★ 迟滞：errPct 必须在死区外**连续这么多轮**（每轮 3 秒）才真的动门槛。
    --   食物速率被药水/加成带着在 8~20M/s 剧烈波动，单次读数不可信（见坑 C1）。
    mgrHoldTicks = 3,
    -- ===== 🖼 窗口尺寸/位置记忆（用户要求：「让自动保存跟config记住我的UI大小」）=====
    -- nil = 用 Obsidian 的默认值（720x600 居中）。你拉大窗口后会自动写进配置，
    -- 下次重载/重进游戏自动恢复成你调好的大小。想回到默认就点「重置窗口大小」。
    uiWin = nil,                    -- { w = 宽, h = 高, x = 左边距, y = 上边距 }（x/y 可缺省）
    -- ===== 🎯 自动配置角色（AutoStand）=====
    astEnabled = false,             -- 默认**只预览不动手**（放角色会动背包，先让用户确认）
    astFoodBudget = 20000000000,    -- 单次换人允许花的食物上限（默认 20B；0 = 不限）
    astIntervalMinutes = 60,        -- 每这么多分钟自动重算一次配置（0 = 不自动）
    astPlaceClean = true,           -- 无突变角色是否参与（true = 参与但降优先级）
    -- 🔗 配对：官方文档写的是 "Both characters receive a 3x buff"，
    --   但奖励文案写的是 "3x Cash"（未实测确证它是否也作用于 CPS）。
    --   所以这里做成可开关 + 倍率可调，默认开启按 ×3 计，并在结果里单列"配对额外收益"，
    --   方便用户对照游戏实际效果核实。
    astPairBonus = true,
    astPairMult = 3,
    -- 🛡 换人的安全上限（防止反解出一个天文数字的等级/成本）
    --   实测踩到的 bug：基础太低的候选永远达不到目标 CPS，旧代码一路累加到 2000 级，
    --   成本算成 1.16e+73，还被当成"划算"选进方案。
    astMaxLevel = 800,              -- 单台换人最多练到这个等级就放弃（视为不划算）
    astMaxCost = 1e15,              -- 单台换人食物成本上限（1e15 = 1000T）
    -- 🤖 全自动调度：食物门槛。只有食物 ≥ 这个值才允许自动换人。
    --   食物优先留给喂食（autoTick 排在 feedTick 之后），避免把食物吃光导致不喂食。
    astMinFood = 0,                 -- 0 = 不设门槛（只要食物够那几台的成本就动手）
    -- ★★ 上次自动执行的时间锚点（**必须持久化到配置文件**）★★
    --   用户点出的问题（原话）："这个1小时需要写在外置配置记录中，
    --   毕竟我不确定1小时内会不会掉线一次把脚本时间刷新"
    --   ⇒ 若只放在内存里（比如用 os.clock），一旦掉线重载脚本计时就归零，
    --     1 小时的间隔永远等不满，等于每次都从头开始。
    --   ⇒ 改用**墙钟时间** os.time() 存进 cfg，随 autoSave 一起写进
    --     hw_mutator_config.json，重载后从文件读回，计时跨会话连续。
    astLastAutoAt = 0,              -- 上次自动执行时的 os.time()（0 = 从未执行）
    -- 🎚 稀有度白名单（用户明确要求："指定放哪些品质，从这些品质上计算"）
    --   逗号分隔的品质名；**空字符串 = 不限制**（全部品质都参与）。
    --   例："Ancient,Celestial" 表示只用这两个品质的角色上台。
    --   ⚠ 它作用在**候选池**上：不在名单里的品质连被考虑的资格都没有。
    astRarities = "",
    -- 🚫🚫🚫 稀有度**黑名单**（用户明确要求，2026-10）
    --
    -- 用户原话："添加一个硬性限制功能，一劳永逸，品质黑名单，选择一个品质，
    --          不添加进计算，也不会放到台上，在台上就自动拿下来，
    --          先把现状修好，现在家里的配置已经烂到惨目忍睹了"
    --
    -- 与白名单的区别：
    --   · `astRarities`（白名单）= "我只想要这些"（可能漏掉没想到的）
    --   · `astBlockedRarities`（黑名单）= "这些永远不要"（硬性、一劳永逸）
    -- 两者是**且**关系：既要在白名单（若设了），又不能在黑名单。
    --
    -- ★ 黑名单是**硬性**的，有三重效果：
    --   ① **不进计算**：候选池直接剔除，`AST.rarityAllowed` 返回 false
    --   ② **不放上台**：任何换人方案都不会把它们放上去
    --   ③ **在台上就自动拿下来**：`AST.autoTick` 每轮检查，发现台上有黑名单品质
    --      就自动取回（见 `AST.enforceRarityBlock`）
    --   逗号分隔，例："Divine,Supreme,Ascended"
    astBlockedRarities = "",
    -- 是否自动把台上命中的黑名单角色拿下来（默认开；关掉则只"不放上去"，不动存量）
    astBlockAutoPickup = true,
    -- 🛡 初始CPS 不倒退守卫（用户明确要求，2026-10）
    --
    -- 用户原话："我要的是脚本能理解这个错误，而不是你来修正"
    -- 背景：脚本曾把 Yotso Naka（初始 1.494e6，但被喂到 Lv396 所以当前 2.315e8）
    --   放到台上，顶掉了初始 CPS 高得多的 Celestial —— 因为当时的比较用了
    --   **当前CPS**，而当前CPS 高只是"等级喂得高"，不代表角色更好。
    --   游戏公式 CPS(等级L) = 初始CPS × cpsCurve(L) × 突变倍率
    --   ⇒ 初始CPS 的比值在**任何等级都恒定**，它才是角色的真实价值。
    --
    -- 开启后：`AST.swapOne` 在换人前会检查
    --   "新角色的初始CPS 是否 < 台上角色的初始CPS × 0.9"
    --   是则**拒绝这次换人**，并在日志里说明原因。
    -- 这是所有规划路径（plan / planForce / optimizePairs）的**最后一道闸**，
    -- 无论哪条路漏判都拦得住。空台不受影响（台上没有可比较的对象）。
    astNoInitDowngrade = true,
    -- 🚫 无突变角色禁止上台（用户强调过多次）
    --
    -- 用户原话："我不是说过了没突变的角色不能上台吗"
    -- 突变是**乘数**：同角色带 Lava = 初始CPS ×2，无突变 = ×1。
    -- 台位是稀缺资源（每台都要单独喂食物），放无突变 = 永久浪费一个台位。
    -- 开启后 `AST.swapOne` 会拒绝任何 `toMut == ""` 的换人请求。
    --
    -- ⚠ 例外（用户选择 A）：如果这个无突变角色是**台上某角色的配对伙伴**，
    --   则允许上台（典型例子：`Teto` 无突变但和 `Summer Mika II` 是官方配对，
    --   放到中间能让左右两个 Summer Mika II 各吃 ×3）。
    astBlockNoMutation = true,
    -- 🚫 配对黑名单（用户明确要求）：指定哪些配对**绝对不要**使用
    --
    -- 用户原话："我点了立即配对，脚本又在配垃圾了，直接弄黑名单系统吧，指定哪些配对不要"
    --
    -- 格式：每条用 "+" 连接两个角色名，条目之间用 , / ; 分隔，顺序无关。例：
    --   "Reia II+Askira II,Remi+Rami"
    -- 生效范围：`AST.partnerNames()` 会过滤掉被拉黑的伙伴，
    --   因此 **所有** 配对相关逻辑（plan ③b / planForce / optimizePairs / planInitUpgrade）
    --   自动遵守，无需逐处修改。
    astBlockedPairs = "",
    -- ★★★ 单台食物预算（把弱台子练到远超当前水平所需的旋钮）★★★
    --   用户当场抓到的结构性缺陷："脚本还是没有把台上的 Ascended 跟 Divine
    --   垃圾角色拿下来放上 cele 或者 ancient"。
    --   根因：旧算法给每台的目标只是"顶平它**自己当前**的 CPS" ——
    --         一个只有 46M 的台子顶平后还是 46M，**根本没有提升空间**。
    --   ⇒ 每台给一份独立食物预算，目标 CPS 取"当前产出"与"这份预算能练到的产出"的较大者，
    --     弱台子才有机会被大幅提升。
    --   0 = 关闭（退回旧行为：只顶平当前产出，永不主动提升弱台）。
    astPerStandFood = 5e9,          -- 默认每台 5B 食物（约等于 5 个台子花掉 25B）
    feedMaxActionsPerCycle = 0,     -- 单批最多喂多少级（0 = 不限）
    feedPauseOnEvent = false,       -- ★ 活动期间是否暂停喂食（默认 false = 照样喂，食物不积压）
    feedMaxPasses = 6,              -- ★ 单批最多补喂几轮（每轮重算计划，直到食物花完或无目标）
    feedCooldown = 20,              -- 两批之间至少间隔（秒）
    feedExcludeStands = "",         -- 排除的台子/角色（逗号分隔）
    feedKeep = 0.225,               -- 升级折扣系数（会用面板价格自动校准）
    feedLogEach = true,             -- 每 10 级打一条进度日志
    feedNotify = true,              -- 每批结束弹通知
    feedDryRun = false,             -- 预览模式：只计算不执行
    -- 💞 配对加成纳入喂食规划（v271）
    --   游戏机制实测：配对生效时**现金产出 ×3**，但 CPS 属性不变。
    --   所以「喂谁」的价值其实是 3× —— 不乘的话会把食物喂给收益只有 1/3 的台子。
    --   配对判定 = 名字在配对表里 **且** 两台子地理相邻
    --   （游戏规则：同一行 |ΔY| ≤ 8 且水平距离 ≤ 12，与本脚本 AST 模块一致）。
    --   ⚠ 只影响「喂食优先级」，绝不改动你的台子布局。关掉即恢复旧行为。
    feedPairBonus = true,
    feedAutoPreview = true,         -- 喂食页签的清单自动刷新
    -- ===== 去突变（Depolarizer）=====
    washEnabled = false,            -- ⚠ 默认关闭（操作不可撤销，必须你亲自打开）
    washTypes = {},                 -- 要洗掉的突变（默认空 = 什么都不洗）★ 由你勾选
    washRarities = {},              -- 参与的品质（默认空 = 什么都不洗）★ 由你勾选
    washAutoPreview = true,         -- 去突变页签里的预览列表每 2 秒自动刷新
    -- ===== 🎯 角色级筛选（v238）：品质 → 指定哪些角色参与 =====
    -- 用户原话：「每种品质可以选择给指定初始CPS的角色参与突变…只要我勾选了 changlia
    --   她就会参与进 solar 自动陨石突变，而比较高的其他角色不参与，仍然去德古拉」
    -- 勾选语义：
    --   · 该品质一个都没勾 = 该品质的角色【全部参与】（默认，与旧版行为完全一致）
    --   · 勾了任意一个     = 【只有勾上的参与】，其余不参与
    --   · 品质本身没被选进该功能的品质名单 ⇒ 该品质角色永不参与（无论这里勾没勾）
    -- 三套名单互相独立：solar / halloween / wash
    -- ⚠ solar 与 halloween 只列【白板】角色（已突变的不会被二次突变，列出来是噪音）；
    --   wash 反而专列【有突变】的角色（洗突变机器吃的就是它们）。
    --
    -- ⚠⚠ 这里**故意不存品质名单**：品质就是上面那三份已存在的配置 ——
    --   solar 的 = cfg.solarRarities、halloween 的 = cfg.rarities、wash 的 = cfg.washRarities。
    --   早先版本在本表里各存了一份 allow={Ancient=true}，结果和那三份**互相不同步**：
    --   用户在界面把 Solar 品质改成别的，charPick.solar.allow 还停在旧值，
    --   于是"界面显示参与的品质"和"实际参与的品质"对不上（实测踩到）。
    --   现在统一用那三份，唯一数据源，不可能不一致。
    --   sel = [品质] = { [角色名] = true }；该品质一个都没勾 = 该品质角色全部参与。
    charPick = {
        solar     = { sel = {} },
        halloween = { sel = {} },
        wash      = { sel = {} },
    },
    charPickExcludeRelease = true,  -- 被排除的角色若正被手持 -> 立刻放手（突变不可逆，选安全档）
    -- ⚡ v296 性能：角色下拉列表的**重建节流**（秒）。
    --   标签里含 `×N`/`✗已全突变`/`❌没有`，这些随角色进出背包随时在变；
    --   不加节流就会每次变化都重建列表（库的 4 个重操作），把游戏拖垮（实测崩溃）。
    --   45 秒足够；数量/状态的实时信息在**预览框**里，那才是主来源。
    cfListRebuildSec = 45,
    -- 🔬 诊断开关：true = 完全关闭角色选择器的界面刷新（预览/对齐/重建全停）。
    --   用于单变量定位"崩溃是不是这里造成的"。日常请保持 false。
    cfDisablePickerUI = false,
    solarPauseFishing = true,       -- Solar 期间暂停并取消自动钓鱼（否则会被拉回钓点）
    hotbarKeepMutations = "",       -- 🛡 例外：这些突变名的角色允许留在快捷栏（默认空 = 已突变的一律移入背包）
    hotbarEvictMutated = true,      -- ★ 规则：候选角色（未突变）按优先级放快捷栏；已突变的一律移入背包
    hotbarEvictUncheckedRarity = true, -- ★ v338：品质没勾选的角色也一律移出快捷栏（与候选池同一套 cfg.rarities）
    hotbarExcludeChars = "",        -- 逗号分隔：这些角色不会被自动塞进快捷栏
    hotbarProtectSeconds = 90,      -- 🛡 保护时长：新出现在快捷栏的角色在这段时间内绝不被整理掉
    hotbarProtectLog = true,        -- 保护时打日志
    hotbarMaxRemovePerPass = 4,     -- 🛡 防呆：单轮最多允许删几项，超过就拒绝写入（保护你的快捷栏）
    hotbarProtectMaxBatch = 3,      -- 只有"一次新增 ≤ 这个数"才认定是你手动加的（游戏自动加是一次一大批）
    hotbarStuckLimit = 4,           -- 🛠 失效键连续这么多次清不掉就判定"快捷栏卡住"并强制重新同步
    hotbarProtectChecks = 3,        -- 🛡 稳定存在判定：一个角色要连续出现这么多次才算"你手动加的"
                                    --   钓上来就被自动售卖的角色只会闪现一次，永远不会被登记（防日志刷屏）
    hotbarKeepChars = "",           -- 🛡 手动固定名单（逗号分隔）：永远排在快捷栏最前、绝不被移除
    menuKeybind = "RightShift",     -- 菜单开关快捷键（可在 UI 里改）
    pollHold = 0.5,
    pollSummary = 1.0,
    pollIdle = 3,
    rescanIdle = 10,
    maxLog = 60,
    -- ===== 📝 持久化日志（掉线重连不丢）=====
    logToFile = true,               -- 把日志追加写到文件（掉线/重连后仍可回溯）
    logHalloweenOnly = true,        -- ★ 只记录【万圣节突变相关】的日志（不写全量，避免文件被噪音灌满）
    logFlushSeconds = 10,           -- 每这么多秒刷一次盘（写文件是阻塞 IO，间隔别太短）
    logFlushLines = 100,            -- 缓冲满这么多条才提前刷（配合缓冲上限 500）
    logMaxKB = 2048,                -- 超过这个大小就轮转（保留上一份 .1）
    -- ★ 界面上日志面板的显示预算。实测几何（改之前务必先看这段）：
    --   可视区只有约 530px 高、约 30 个汉字宽、字高约 38px ⇒ 总共约 13 个可视行。
    --   一条 105 字的日志要折 4 行，所以**必须按"总行数"预算，而不是"条数"** ——
    --   旧代码写"最多 25 条"，实际高度 960px+，远超 530px ⇒ 后半截被裁掉，
    --   切口正好落在 <font ...> 标签中间 ⇒ 界面上出现半截标签文字。
    logShowLines = 12,              -- 日志面板最多占多少个【可视行】（不是条数！）
    logMsgMaxChars = 48,            -- 单条日志最多显示多少个字，超出用 … 截断（全文仍在日志文件里）
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

--============================================================== 📁 按账号绑定配置文件（v328）
-- 需求（用户原话）：「指定某个账号加载哪个配置文件，然后自动保存也要跟进」
--
-- 设计（以及为什么这么设计）：
--   · 绑定表**单独存一个文件** `hw_mutator_accounts.json`，**绝不放进 cfg** ——
--     否则"该用哪个配置"这件事本身会被写进"那个配置"里，换个号就自相矛盾。
--   · 键 = **UserId**（稳定；改昵称/显示名都不影响绑定），值 = { file, name, at }。
--   · 启动时解析一次：有绑定**且文件确实存在** -> 用它；否则回默认 CONFIG_FILE。
--   · `loadConfig`/`saveConfig` 每次都调 `R.activeCfgFile()` ⇒ **自动保存自动跟进**：
--     全脚本没有任何"缓存的旧路径"，绑定一改，下一次写盘就写新文件。
--   · ⚠ 绑定文件不存在时**不静默新建**（否则用户会以为配置丢了、被重置成默认值）：
--     本次回默认并告警一行，但**保留绑定关系**（文件回来就自动生效）。
--   · ⚠ 全部逻辑挂在 R 表上：顶层 local 已经 197/200，一个都不能再加。
R.ACCT_FILE = "hw_mutator_accounts.json"
R.activeCfgFile = function() return R.configFile or CONFIG_FILE end

-- 当前账号：优先 UserId（权威），拿不到就退化成"只有名字"
R.acctId = function()
    local lp = LocalPlayer
    if not lp then return nil, nil end
    local uid, nm
    pcall(function() uid = lp.UserId end)
    pcall(function() nm = lp.Name end)
    if uid == nil then return nil, (nm and tostring(nm)) or nil end
    return tostring(uid), (nm and tostring(nm)) or "?"
end

R.acctFileExists = function(f)
    if type(f) ~= "string" or f == "" then return false end
    local ok, v = pcall(isfile, f)          -- pcall：不是所有执行器都有 isfile
    return (ok and v == true)
end

-- 读绑定表；任何损坏都退化成"空绑定"，绝不让它影响脚本启动
R.acctLoad = function()
    local map = {}
    local data = readFileSafe(R.ACCT_FILE)
    if type(data) == "string" and #data > 2 then
        local ok, obj = pcall(function() return HttpService:JSONDecode(data) end)
        if ok and type(obj) == "table" and type(obj.accounts) == "table" then
            for k, v in pairs(obj.accounts) do
                if type(v) == "table" and type(v.file) == "string" and v.file ~= "" then
                    map[tostring(k)] = {
                        file = v.file,
                        name = tostring(v.name or "?"),
                        at = tostring(v.at or ""),
                    }
                end
            end
        end
    end
    R.acctMap = map
    return map
end

R.acctSave = function()
    local acc = {}
    for k, v in pairs(R.acctMap or {}) do acc[k] = v end
    local ok, err = writeFileSafe(R.ACCT_FILE, HttpService:JSONEncode({ version = 1, accounts = acc }))
    if not ok then warn(PREFIX .. " 账号绑定表写入失败: " .. tostring(err)) end
    return ok
end

R.acctBind = function(uid, file, name)
    R.acctMap = R.acctMap or {}
    R.acctMap[tostring(uid)] = {
        file = tostring(file),
        name = tostring(name or "?"),
        at = os.date("%Y-%m-%d %H:%M:%S"),
    }
    return R.acctSave()
end

R.acctUnbind = function(uid)
    if R.acctMap then R.acctMap[tostring(uid)] = nil end
    return R.acctSave()
end

-- 可选配置文件列表：工作区里所有**名字含 "config"** 的 .json（排除绑定表自己）。
-- ⚠ 用 pcall 包住 listfiles：不是所有执行器都提供（本机实测有）。
R.acctListFiles = function()
    local out = {}
    local ok, files = pcall(function() return listfiles(".") end)
    if ok and type(files) == "table" then
        for _, f in ipairs(files) do
            local s = tostring(f)
            local base = s:match("([^\\/]+)$") or s
            if base:sub(-5) == ".json" and base ~= R.ACCT_FILE and base:find("config", 1, true) then
                out[#out + 1] = base
            end
        end
    end
    table.sort(out)
    return out
end

-- 文件名规范化：去掉路径、自动补 .json（用户可能只写 "小号"）
-- ⚠ 有这个函数，"绑定一个还不存在的文件名"才可能 —— 因为下拉只能列**已存在**的文件，
--   而点①时脚本会拿当前配置当模板把新文件建出来。
R.acctNormName = function(s)
    if type(s) ~= "string" then return nil end
    local t = (s:gsub("^%s+", "")):gsub("%s+$", "")
    if t == "" then return nil end
    t = t:match("([^\\/]+)$") or t
    if t:sub(-5) ~= ".json" then t = t .. ".json" end
    return t
end

-- 启动解析：**必须在下面的 loadConfig(true) 之前调用**。
-- ⚠ 这里不能调 log()：`log` 在文件后段才定义，此处引用会解析成**全局 nil**（踩过，
--   见文件里 AST 那条同样的教训）。所以把话存进 R._acctStartupMsg，
--   等 UI 建好（那时 log 已存在）再打出来。
R.acctStart = function()
    R.acctLoad()
    local uid, nm = R.acctId()
    local bound = (uid and R.acctMap[uid]) or nil
    local label = tostring(nm) .. " (" .. tostring(uid) .. ")"
    if bound and R.acctFileExists(bound.file) then
        R.configFile = bound.file
        R._acctStartupMsg = "📁 账号配置：本号 " .. label .. " 绑定 " .. bound.file
            .. "（读取与自动保存都走这个文件）"
    elseif bound then
        R.configFile = CONFIG_FILE
        R._acctStartupMsg = "⚠ 账号配置：本号 " .. label .. " 绑定的 " .. tostring(bound.file)
            .. " 不存在 -> 本次先用默认 " .. CONFIG_FILE .. "（绑定未清除，文件回来即生效）"
    else
        R.configFile = CONFIG_FILE
        R._acctStartupMsg = "📁 账号配置：本号 " .. label .. " 未绑定 -> 使用默认 " .. CONFIG_FILE
            .. "（在「配置」页 ->「账号配置」里可绑定）"
    end
    print(PREFIX .. " " .. R._acctStartupMsg)
    return R._acctStartupMsg
end
-- ⚠ v336：账号配置已停用（配置改由 UI 库管），这行不再需要；函数保留以备将来
--       把「账号 → 库的配置档位名」做回来。
-- R.acctStart()

-- 配置默认值快照 + 重置（切配置时用：先清成默认再合并，避免上一个配置的残留键混进来）
R.cfgDeepCopyInto = function(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            local d = dst[k]
            if type(d) ~= "table" then d = {}; dst[k] = d end
            R.cfgDeepCopyInto(d, v)
        else
            dst[k] = v
        end
    end
end
R.cfgDefaults = {}
R.cfgDeepCopyInto(R.cfgDefaults, DEFAULT_CONFIG)
R.cfgResetToDefaults = function()
    for k in pairs(cfg) do cfg[k] = nil end
    R.cfgDeepCopyInto(cfg, R.cfgDefaults)
    if R.markDirty then R.markDirty() end
    return true
end

local function loadConfig(silent)
    local data = readFileSafe(R.activeCfgFile())
    if type(data) ~= "string" or #data < 2 then
        if not silent then print(PREFIX .. " 无配置文件，使用默认值") end
        return false
    end
    local ok, obj = pcall(function() return HttpService:JSONDecode(data) end)
    if not ok or type(obj) ~= "table" then
        warn(PREFIX .. " 配置解析失败: " .. tostring(obj))
        return false
    end
    -- 🔬 v336 埋点：文件里到底存了什么 / 合并前(cfg=默认值) / 合并后
    if R.rarSnap then R.rarSnap("file", obj.rarities) end
    -- ⚠⚠ v280：原来只做**一层**浅拷贝，`charPick.solar.sel.Ancient = {...}`
    --   这种两层以上的嵌套会被整块丢掉（读回来变成空表）。
    --   改成递归合并：只覆盖文件里确实有的键，保留默认值的其余字段。
    --
    -- ⚠⚠⚠ v334 修复"**取消勾选永远回弹**"（用户实测 2026-10-11 报的）：
    --   症状：给德古拉/万圣节 + Solar 都取消了 Celestial 品质，重载后又自己勾上了。
    --   根因：这里是**纯合并** —— 而 cfg 在加载前已经被填成 DEFAULT_CONFIG 的深拷贝，
    --     于是文件里"**没写**"的键（= 用户取消勾选的）**不会删掉默认值**：
    --       默认 rarities = {Ancient, Celestial} ＋ 文件 {Ancient, God}
    --       ⇒ 合并结果 {Ancient, Celestial, God}  ← Celestial 复活，怎么取消都没用
    --     （实测复现：重载前 mem/disk 都是 Ancient,God；重载后变成 Ancient,Celestial,God，
    --       并且 saveCount+1 —— 重载当场把复活的值又写回了磁盘。）
    --   ⇒ 现在：**文件里有这个键时，先清空目标表再写入**（文件 = 权威）。
    --     注意是"清空顶层键"就够了：父表被清空后，子表自然重建，等于深拷贝文件的值。
    --     文件里**完全没有**的键才保留默认值（这样旧配置缺的新键仍能拿到默认）。
    local function mergeInto(dst, src, depth)
        if type(src) ~= "table" or depth > 6 then return end
        for k2, v2 in pairs(src) do
            if type(v2) == "table" then
                if type(dst[k2]) ~= "table" then dst[k2] = {} end
                mergeInto(dst[k2], v2, depth + 1)
            else
                dst[k2] = v2
            end
        end
    end
    for k, v in pairs(obj) do
        if type(v) == "table" and type(DEFAULT_CONFIG[k]) == "table" then
            if type(cfg[k]) ~= "table" then cfg[k] = {} end
            -- ⚠ v334：先清空（"取消勾选"能生效的关键一步，别再改回纯合并）
            for kk in pairs(cfg[k]) do cfg[k][kk] = nil end
            mergeInto(cfg[k], v, 0)
        elseif DEFAULT_CONFIG[k] ~= nil then
            cfg[k] = v
        end
    end
    if R.rarSnap then R.rarSnap("合并后") end
    if not silent then print(PREFIX .. " 配置已加载 (" .. R.activeCfgFile() .. ")") end
    return true
end

local function saveConfig(quiet)
    -- ⚠ v328：写盘目标**每次都现算**（R.activeCfgFile）—— 这样"自动保存跟进账号配置"
    --   是天然成立的：绑定/切换改了 R.configFile，下一次写盘就落到新文件，没有残留路径。
    local ok, err = writeFileSafe(R.activeCfgFile(), HttpService:JSONEncode(cfg))
    if ok then
        if not quiet then print(PREFIX .. " 配置已保存 -> " .. R.activeCfgFile()) end
    else
        warn(PREFIX .. " 保存失败: " .. tostring(err))
    end
    return ok
end

-- 🔬 v335 哨兵：把"品质勾选"在启动各步的取值记进 R._rarDbg，
--   用来定位"取消勾选后重载又自己勾上"到底是谁加回来的（用户 2026-10-11 报的）。
--   形如： loadCfg=[Ancient,God] apply=[Ancient,God] read=[Ancient,Celestial,God] ← 一眼看出是哪步
R.rarSnap = function(tag, t)
    t = t or cfg.rarities
    local o = {}
    for k, v in pairs(t or {}) do if v then o[#o + 1] = tostring(k) end end
    table.sort(o)
    R._rarDbg = (R._rarDbg or "") .. tostring(tag) .. "=[" .. table.concat(o, ",") .. "] "
end
R._rarDbg = ""
-- ⚠⚠ v336（用户拍板）：**不再自动加载我们自己的 JSON** —— 改用 UI 库自己的配置系统。
--   用户原话：「既然两个系统配置文件这么复杂，那自动保存配置就别弄了，去掉吧，
--             改用UI库自己的config系统，我自己保存设置」
--   现在：启动直接用库的自动配置恢复（见 buildUI 里的 LoadAutoloadConfig），
--         用户改完设置去「配置」页的 Configuration 面板点 Overwrite config 保存。
--   ⚠ 代价（已向用户说明）：库只存"有控件的键"（实测 88 条控件快照 / 65 个 cfg 键）；
--     没有控件的键（ast* 17 个、fallMinY、部分 feed 内部项、计时器）会回到默认值。
--   ⚠ `loadConfig` 函数**保留**（"从旧 JSON 迁移一次"按钮要用），只是启动时不再调用。
-- loadConfig(true)
R.rarSnap("启动")
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
-- ⚠⚠ R.cfgSig 必须在 cfgSignature **定义之后**才能赋值。
--   之前这里写的是 `R.cfgSig = function() return cfgSignature(cfg) end`，
--   而 cfgSignature 是 local、在下面十几行才定义 —— 那一刻它是 nil，
--   真去调用就报 "attempt to call a nil value"（实测踩到：面板状态查询直接崩）。
--   （注意：闭包体内引用 local 是合法的，但**赋值那一刻**不影响；
--     真正的问题是这行在定义之前就把闭包建好了，而下面的 R._cfgSig 才是权威。
--     统一挪到 L574 之后赋值，只有一处。）
R.markDirty = markDirty
--============================================================== 🎩 静默写入通道
-- ⚠⚠ 为什么需要它（用户实测报的"我明明没改动，它自己在自动保存"）：
--   脚本里有一处**机器自己改配置**的地方 —— 「总经理」自动调参会写
--     `cfg.feedMinRelGain = want`   （每轮按实际产率调 20%，如 0.10 ↔ 0.095）
--   而自动保存是**签名差分**：任何 cfg 值变化都算"改动"⇒ 每轮都写盘。
--   实测：4 秒内就多存了 1 次，界面上就成了"没动它却一直在保存"（用户会以为坏了）。
--
--   ⇒ 加一个**静默通道**：机器调参照常改内存里的值（逻辑不受影响），
--     但**不触发保存**；等用户真改了别的东西时，这个值会随那次保存一起落盘。
--
--   用法：`R.cfgSetQuiet("feedMinRelGain", want)`
--   ⚠ 只给"自动调参"用！用户操作请直接赋值（那本来就该触发保存）。
local cfgQuietWrite = false
R.cfgSetQuiet = function(key, value)
    cfgQuietWrite = true
    cfg[key] = value
    cfgQuietWrite = false
end
do
    local mt = {
        __newindex = function(t, k, v)
            rawset(t, k, v)
            if not cfgQuietWrite then
                R._cfgDirty = true
                R._cfgChangedAt = os.clock()
            end
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
--
-- ⚠⚠ 但签名**必须排除"由脚本自己调参的键"**（用户实测：没改动却一直在自动保存）：
--   脚本里有一处机器写配置 —— 「总经理」自动调参会写 `cfg.feedMinRelGain`
--   （每轮按实际产率调 20%，实测 0.10 ↔ 0.095 来回漂）。
--   若它进了签名，就是"每轮都算改动" ⇒ 每轮都写盘 ⇒ 界面上显示 保存次数 一直涨。
--   ⇒ 排除掉它：自动调参照常改内存值（逻辑不受影响），但**不触发保存**；
--     等用户真改了别的东西，它会随那次保存一起落盘（值本身不会丢）。
local CFG_SIG_SKIP = {
    feedMinRelGain = true,      -- 🎩 总经理自动调参的目标值
}
local function cfgSignature(t)
    local parts = {}
    local function walk(tbl, pre)
        local keys = {}
        for k in pairs(tbl) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            if not (pre == "" and CFG_SIG_SKIP[k]) then
                local v = tbl[k]
                local vt = type(v)
                if vt == "table" then
                    walk(v, pre .. k .. ".")
                elseif vt == "number" or vt == "string" or vt == "boolean" then
                    parts[#parts + 1] = pre .. k .. "=" .. tostring(v)
                end
            end
        end
    end
    pcall(walk, t, "")
    return table.concat(parts, "|")
end
R._cfgSig = cfgSignature(cfg)
-- 对外暴露签名函数（必须在 cfgSignature 定义之后）
R.cfgSig = function() return cfgSignature(cfg) end

--============================================================== 运行时状态
R.summary = nil
R.candidates = {}
R.event = { active = false, name = nil, title = nil, remaining = 0, duration = 0 }
R.hold = { key = nil, name = nil, rarity = nil, baseline = nil, since = 0, misses = 0 }
R.hotbar = { layout = {}, lastFire = 0, lastTarget = nil }

--============================================================== 🚦 模块让路（互斥）机制
-- 设计目的（实测发现的真实冲突）：
--   喂食 / 去突变 / Solar 三个模块都要**传送玩家**，而自动钓鱼的保活逻辑会在
--   "45 秒没有鱼上钩"时点《点击开始钓鱼》，并在连续失败后**自己补一次传送回钓点**
--   —— 于是喂食喂到一半（一批 20~200 级要 40 秒~6 分钟）就会被打断、人被抓回钓点。
-- 解法：谁要用玩家位置，就先 claim 一个名字，用完 release；
--   自动钓鱼看到有人占位就**完全停手**（不点击、不传送、也不重置计时）。
R.yield_ = R.yield_ or {}
R.yieldBusy = R.yieldBusy or {}
R.yieldNames = R.yieldNames or {}
function R.yieldClaim(who, label)
    who = tostring(who)
    R.yield_[who] = true
    R.yieldNames[who] = label
end
function R.yieldRelease(who)
    who = tostring(who)
    R.yield_[who] = nil
    R.yieldNames[who] = nil
end
function R.yieldWho()
    for k in pairs(R.yield_) do return k end
    return nil
end
function R.yieldAny()
    return next(R.yield_) ~= nil
end
function R.yieldLabel(who)
    return R.yieldNames[tostring(who or "")] or tostring(who or "?")
end
-- ===== 执行互斥（解决"喂食与去突变同时抢玩家位置"）=====
-- 背景：喂食和去突变都会【传送玩家 + 可能手持角色】。两者同时跑会互相打断：
--   喂食传到台子 -> 去突变把你传到机器 -> 喂食的 prompt 变远失效 -> 报"没站到位"。
--   实测过 washTick/feedTick 各自 task.spawn，彼此完全不知情。
-- 设计：谁要"独占执行"就先 suggest；已有别人在跑就返回 false 让路。
--   注意 busy 用**独立表**，这样 feedTick 可以用它做互斥，而 fishTick 用 yield_ 判断即可。
-- ⚠ 用法提醒（我自己就误用过一次）：suggest 会**同时**占用 busy 与 yield 两张表。
--   不要以为它只管 busy —— 它既做互斥，也自动让钓鱼让路，一步到位。
function R.busySuggest(who, label)
    who = tostring(who)
    if next(R.yieldBusy) ~= nil and not R.yieldBusy[who] then return false end
    R.yieldBusy[who] = true
    R.yield_[who] = true                       -- 同时让钓鱼让路（一步到位，不会漏）
    R.yieldNames[who] = label or R.yieldNames[who] or who
    return true
end
function R.busyClear(who)
    who = tostring(who)
    R.yieldBusy[who] = nil
    R.yield_[who] = nil
    R.yieldNames[who] = nil
end
function R.busyWho()
    for k in pairs(R.yieldBusy) do return k end
    return nil
end
-- 包一层：保证异常时也能释放（否则一旦出错，钓鱼会被永久卡住不让路）
function R.withYield(who, fn)
    R.yieldClaim(who)
    local ok, a, b, c, d = pcall(fn)
    R.yieldRelease(who)
    if not ok then return false, tostring(a) end
    return a, b, c, d
end


--============================================================== 📝 持久化日志
-- 需求（用户实测痛点）：**游戏掉线后其它工具会自动重连，重连会让脚本实例和
--   Potassium 的日志缓冲区全部清空** -> 掉线前后发生了什么完全看不到。
-- 方案：把每条日志 **追加写到文件**。文件是持久化的，掉线/重连/重载脚本都不受影响，
--   重连后新实例继续往同一个文件追加 -> 得到一份连续的完整历史。
-- 实现要点（实测过的执行器 API 行为）：
--   · appendfile 要求文件**已存在**，否则报 "file does not exist"
--     -> 启动时先 isfile 检查，不存在就 writefile 建一个
--   · 写文件是阻塞 I/O，所以做**缓冲 + 定时刷新**，避免每条日志都落盘
--   · 文件会无限增长 -> 超过大小上限时自动轮转（重命名成 .1 并重新开始）
R.pl = R.pl or { buf = {}, lastFlush = 0, wrote = 0, fails = 0, session = nil }
R.pl.file = R.pl.file or "hw_mutator_log.txt"
R.pl.old = R.pl.old or "hw_mutator_log.1.txt"

local function plInit()
    if type(writefile) ~= "function" then return false end
    local ok = true
    -- 文件不存在 -> 先创建一个（appendfile 不接受不存在的文件）
    if type(isfile) == "function" and not isfile(R.pl.file) then
        ok = pcall(writefile, R.pl.file, "")
    end
    if ok then
        -- 每次（重）连都写一条分隔，便于区分"哪一段是重连后的"
        R.pl.session = os.date("%Y-%m-%d %H:%M:%S")
        local head = string.format("\n===== 会话开始 %s（job=%s）=====\n",
            R.pl.session, tostring(game.JobId or "?"))
        pcall(appendfile, R.pl.file, head)
    end
    return ok
end

-- 轮转：文件太大就把当前内容挪到 .1（保留最近一份），然后重开
local function plRotateIfNeeded()
    local maxKB = tonumber(cfg.logMaxKB) or 2048          -- 默认 2MB
    if maxKB <= 0 then return end
    if type(isfile) ~= "function" or not isfile(R.pl.file) then return end
    local sz = nil
    -- 用 readfile 长度估算（没有专门的取大小 API）
    local ok, data = pcall(readfile, R.pl.file)
    if ok and type(data) == "string" then sz = #data end
    if sz and sz > maxKB * 1024 then
        if type(delfile) == "function" then pcall(delfile, R.pl.old) end
        -- 用 readfile + writefile 搬到 .1（没有 rename API）
        pcall(writefile, R.pl.old, data)
        pcall(writefile, R.pl.file, string.format("===== 日志已轮转（上一份在 %s）%s =====\n",
            R.pl.old, os.date("%Y-%m-%d %H:%M:%S")))
        R.pl.rotated = (R.pl.rotated or 0) + 1
    end
end

local function plFlush()
    if R.pl.busy then return end          -- 防重入：正在写就跳过本轮
    local b = R.pl.buf
    if #b == 0 then return end
    if type(appendfile) ~= "function" then R.pl.buf = {} return end
    local text = table.concat(b, "\n") .. "\n"
    R.pl.buf = {}
    R.pl.busy = true
    local ok = pcall(appendfile, R.pl.file, text)
    R.pl.busy = false
    if ok then
        R.pl.wrote = (R.pl.wrote or 0) + 1
        R.pl.lastFlush = os.time()
    else
        R.pl.fails = (R.pl.fails or 0) + 1
        -- 失败就丢弃这批（磁盘满/权限问题），不重试、不堆积
    end
end
R.plFlush = plFlush
R.plInit = plInit

-- ★ 万圣节突变相关的日志白名单（用户要求：文件只记这一类，不要全量噪音）
--   命中任一关键词就写入；加 "出错/错误" 是为了保留异常线索。
--   想临时看全量日志：把 cfg.logHalloweenOnly 设为 false。
local PL_KEEP = {
    "万圣节", "突变", "放手", "持有", "手持", "上钩", "命中",
    "Solar", "事件上报", "时段", "🔍",
    "出错", "错误", "失败",
    -- ⚠⚠ v326：必须加这两个关键词，否则**哨兵行会被这个白名单静默丢掉**。
    --   实测教训（2026-10-11，我踩了）：v325 加的三行哨兵
    --   （`⚙ 配置变化` / `⚠ UI→cfg 回写` / `🔄 库自动配置`）确实执行了
    --   —— 证据是 `R._cfgSnap` 被更新成 121、还原后又回到 120，说明代码跑到了那一步 ——
    --   但日志文件里**一行都搜不到**，因为它们不含任何白名单关键词。
    --   ⇒ 排查"配置被谁改的"时，看不见哨兵 = 白干。
    "配置", "回写",
    -- ⚠⚠ v341：自动购买/领取的日志也必须可见。
    --   用户实测报"自动领取没工作"，真因是**点了、但被这个白名单吃掉了**（一条都看不到）。
    --   这个坑 v326 已经踩过一次（哨兵行被吃），这次一并补上。
    "🛒", "领取", "已买", "预演", "跳过",
}

local function plShouldKeep(msg)
    if cfg.logHalloweenOnly == false then return true end
    for _, kw in ipairs(PL_KEEP) do
        if msg:find(kw, 1, true) then return true end
    end
    return false
end

-- 兼容旧调用（现在写入主要走 log() 里的内存入队）
local function plWrite(rawMsg)
    if cfg.logToFile == false then return end
    if cfg.logHalloweenOnly ~= false and not plShouldKeep(tostring(rawMsg)) then return end
    R.pl.buf[#R.pl.buf + 1] = string.format("[%s] %s", os.date("%Y-%m-%d %H:%M:%S"), tostring(rawMsg))
end

-- 持久日志读取/清空（给 UI 按钮和外部工具用）
R.logTail = function(n)
    n = math.max(1, math.floor(tonumber(n) or 100))
    if type(readfile) ~= "function" then return "" end
    local ok, data = pcall(readfile, R.pl.file)
    if not ok or type(data) ~= "string" then return "" end
    local lines = {}
    for l in data:gmatch("[^\n]+") do lines[#lines + 1] = l end
    local from = math.max(1, #lines - n + 1)
    local out = {}
    for i = from, #lines do out[#out + 1] = lines[i] end
    return table.concat(out, "\n")
end
R.logClear = function()
    if type(writefile) ~= "function" then return false end
    R.pl.buf = {}
    return pcall(writefile, R.pl.file, "===== 日志已手动清空 " .. os.date("%Y-%m-%d %H:%M:%S") .. " =====\n")
end
R.logPath = R.pl.file

local function log(msg, color)
    -- 🔇 v299：同一秒内的重复消息直接丢弃（诊断噪音治理）
    --   背景：排查"崩溃是否双实例"时，日志里出现成对的相同消息，我一度当成双实例铁证。
    --   实测原因是**启动路径里 manageHotbar(true) 被反复调用**（工厂/applyCfgToUI/
    --   buildUI/延时任务各自调一次），而它内部会 log 好几条 —— 单实例就会重复打印。
    --   ⇒ 加这个去重，日志才干净、才能分辨"真双实例"和"重复调用"。
    --   ⚠ 只丢**完全相同**的消息，且仅限 1.2 秒窗口，不会掩盖真实的连续事件。
    local key = tostring(msg)
    local nowL = os.clock()
    local ld = R._logDedup
    if ld and ld.key == key and (nowL - (ld.at or 0)) < 1.2 then
        return
    end
    R._logDedup = { key = key, at = nowL }
    R.logSeq = R.logSeq + 1
    local entry = { seq = R.logSeq, t = os.date("%H:%M:%S"), msg = tostring(msg), color = color }
    table.insert(R.log, entry)
    while #R.log > (tonumber(cfg.maxLog) or 60) do table.remove(R.log, 1) end
    print(PREFIX .. " " .. entry.t .. " " .. entry.msg)
    -- 📝 只往内存缓冲塞一行（**绝不在 log 里做文件 I/O**）
    --   ⚠ 实测教训：原先这里直接 pcall(plWrite,...) 会在每次日志时触发文件写入判断，
    --     而日志可能很密集（整理/让路/事件 Tick）-> 阻塞主线程 -> **游戏卡死重启**。
    --     现在改成：这里只做纯内存的字符串入队，真正的落盘交给 refresh 线程定时做。
    if cfg.logToFile ~= false then
        local buf = R.pl.buf
        local msg = entry.msg
        -- 过滤在这里做（纯字符串匹配，开销极小）
        if cfg.logHalloweenOnly == false or plShouldKeep(msg) then
            buf[#buf + 1] = string.format("[%s] %s", os.date("%Y-%m-%d %H:%M:%S"), msg)
            -- 缓冲上限保护：异常情况下不至于无限增长
            local cap = 500
            if #buf > cap then table.remove(buf, 1) end
        end
    end
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

-- ⚠⚠ 全局放手闸门（低层统一保护，覆盖所有调用点）
-- 血泪教训（用户实测）：`RF.hold:FireServer("")` 被反复发送时，
--   ① 服务器对连续空放手会产生状态竞争（人没放掉 -> 下轮又发 -> 无限循环）
--   ② 反复"放手/持有"会让游戏的【背包 <-> 快捷栏】状态机错乱，
--      表现为**快捷栏最后一格的物品被卡在背包里、进入死循环拿不出来**
-- 所以这里做两道闸门，任何调用点都绕不过去：
--   ① 最小间隔 releaseMinGap（默认 2 秒）—— 防止一轮内狂发
--   ② 同一目标最多 releaseTargetMax（默认 3 次）—— 达不到就在冷却期彻底停手
local _relTarget, _relCount, _relLast, _relCooldown = nil, 0, 0, 0
local function doRelease()
    if not RF.hold then return false end
    local nowR = os.clock()
    if nowR < _relCooldown then return false end
    local nm = heldName()
    -- 🛡 什么都没持有 -> 直接返回，不要白发一次放手
    --   （实测日志里出现过"放手 <空> 已发 3 次仍未生效"——纯属浪费且会干扰状态机）
    if nm == nil then
        _relTarget, _relCount = nil, 0
        return false
    end
    --====================================================== 🛡🛡 硬性手持闸门（v303）
    -- ⚠⚠⚠ 这是"角色反复消失又出现 / 不跟着走"的**根治点**（实测定位过程见文末说明）。
    --
    --   实测结论（三组对照，同一角色 Angelia）：
    --     · 纯 FireServer hold          -> ToolFollower_Angelia + 角色Tool 稳定 12 秒 ✅
    --     · heldName() 高频采样 60 次    -> Angelia=60 nil=0（检测完全稳定）✅
    --     · 走脚本 applyHold 路径        -> 3 秒后 R.hold=nil、TF=[] ❌
    --   ⇒ **hold 机制和检测都没问题，是脚本自己的某些分支把它放掉了**。
    --     日志实证：`手持 Angelia [God]` 每 3 秒重复 19 次 + 夹着"放手 Angelia（手持丢失）"。
    --
    --   ⇒ 对策：把"我要保持手持"变成一个**显式意图**，并让放手必须经过它：
    --     ① 意图生效期间，**拒绝放掉意图指定的那个角色**（其它角色照常可放，
    --        比如"事件期间放掉你手动拿的别的角色"这条策略不受影响）；
    --     ② 同一个角色被反复放掉又重持（>=3 次）-> 判定"有人在跟我们抢"，
    --        直接**冷却期禁放**，不再陪着抖动。
    --   ⚠ 这不是"永不放手"：applyRelease 会说清楚原因，切角色/关功能都能正常放。
    local intent = R._holdIntent
    if intent and intent.name == nm then
        -- ⚠⚠ 字段名必须是 `expires`，**不能用 `until`**：
        --   Luau 不允许关键字当表字段名，`{ until = 1 }` 会直接报
        --     "Expected identifier, got 'until'"
        --   整个脚本加载失败（实测踩到，别改回去）。
        if (intent.expires or 0) > nowR then
            -- 意图仍然有效 -> 谁都不许把它放掉（连"手持丢失"分支也不行）
            R._relVetoCount = (R._relVetoCount or 0) + 1
            return false
        end
    end
    -- 反复放掉同一个角色 = 有人在抢 -> 该角色进禁放窗口
    if R._relStrikeName ~= nm then
        R._relStrikeName, R._relStrike = nm, 0
    end
    if (R._relStrikeBlockUntil or 0) > nowR and R._relStrikeBlockName == nm then
        return false
    end
    R._relStrike = (R._relStrike or 0) + 1
    if R._relStrike >= 3 then
        R._relStrikeBlockName, R._relStrikeBlockUntil = nm, nowR + 30
        R._relStrike = 0
        if R._relStrikeLogName ~= nm then
            R._relStrikeLogName = nm
            log("🛡 " .. nm .. " 已被反复放掉/重持 3 次 -> 30 秒内不再放它（停止抖动）",
                Color3.fromRGB(140, 220, 255))
        end
        return false
    end
    if _relTarget ~= nm then _relTarget, _relCount = nm, 0 end
    if _relCount >= math.max(1, math.floor(tonumber(cfg.releaseTargetMax) or 3)) then
        -- 这个目标已经发够次数了 -> 停手冷却，绝不无限循环
        if not R._relGateLogged or R._relGateLogged ~= nm then
            R._relGateLogged = nm
            log("⚠ 放手 " .. tostring(nm) .. " 已发 " .. _relCount ..
                " 次仍未生效 -> 停手冷却 60 秒（反复放手会卡死快捷栏）", Color3.fromRGB(255, 120, 120))
        end
        _relCooldown = nowR + 60
        _relTarget, _relCount = nil, 0
        return false
    end
    if (nowR - _relLast) < math.max(0, tonumber(cfg.releaseMinGap) or 2) then return false end
    _relLast = nowR
    _relCount = _relCount + 1
    R._relGateCount = (R._relGateCount or 0) + 1
    pcall(function() RF.hold:FireServer("") end)
    return true
end


--============================================================== 候选 / 突变检测
--============================================================== 角色级筛选（v238）
-- ⚠ 为什么整块塞进一个工厂函数：
--   Luau 对**主 chunk** 和每个函数都有 200 个局部变量的硬上限。主 chunk 早就接近上限，
--   把这些新东西摊在模块级会直接编译失败：
--     "Out of local registers when trying to allocate ...: exceeded limit 200"
--   实测：超了 8 个（去掉 8 个 local 就能编译）。
--   所以这里用工厂函数把全部新增 local 关进**函数自己的寄存器帧**，
--   模块级只多出一个 pickAPI，一行代码都不用改逻辑。
local function cfFactory()
    -- ⚠ 这三个表必须声明在工厂内部最前面（cfAllows 会用到 CFC.rarity）：
    --   Luau 的 local 必须先声明后使用，否则会被当成全局变量（恒为 nil）
    --   -> 整套角色筛选会静默失效。
    --
    --============================================================== 🛡 统一静默开关
    -- ⚠⚠⚠ 这是"重启后角色勾选被清空"的**最终解法**（取证实测见下方说明）。
    --
    --   取证结果（在角色回调里记录每次收到的值）：
    --     `solar 进=0{} 前sel=4`   ← 空表被送进来，把 4 个勾选清掉
    --   即：**我们自己**在 cfRefreshUI 里用空值刷了下拉。
    --   机制（库源码 obsidian_Library.lua）：Dropdown:SetValue / SetValues 会触发
    --   RunChanged → 我们的 OnChanged；而 SetValues 在"旧值不在新列表里"时还会
    --   **主动删掉 Value 并触发一次**。启动阶段图鉴/背包还没就绪，Value 里那些角色名
    --   不在占位列表 `{"(等待选择品质…)"}` 中 → 库发 `RunChanged({})` → 清空 cfg。
    --
    --   之前用 `st._syncing` 逐处加守卫 —— **必然漏**（实测就漏了 SetValues 那一处，
    --   而且两个下拉都要各自加）。⇒ 改成一个**全工厂共用的静默开关**：
    --     · 所有"代码发起"的 SetValue / SetValues 都用 cfQuietDo(fn) 包起来
    --     · 两个下拉的 OnChanged 开头统一 `if cfQuiet then return end`
    --   这样不可能再漏，也不会出现"某处忘了加"的情况。
    local cfQuiet = false
    local function cfQuietDo(fn)
        local prev = cfQuiet
        cfQuiet = true
        local ok, err = pcall(fn)
        cfQuiet = prev
        if not ok then
            -- 静默写入失败不该影响主流程，但要留痕便于排查
            pcall(function() if R.log then R.log("⚠ 静默写入下拉失败: " .. tostring(err), Color3.fromRGB(255, 140, 140)) end end)
        end
    end
    R.cfQuietDo = cfQuietDo
    -- 供 OnChanged 判断（闭包直接读 cfQuiet 即可；这个函数给外部/调试用）
    R.cfIsQuiet = function() return cfQuiet end
    --============================================================== 角色级筛选（v238）
    -- 用户需求（原话）：「每种品质可以选择给指定初始CPS的角色参与突变，比如我勾选 ancient，
    --   下面多出来一个框，里面有这个品质的全部角色…我希望这个功能可以兼容游戏全品质、角色」
    --
    -- ⇒ 数据源必须是**全游戏图鉴**（Constants.Characters，实测 185 个角色 / 19 个品质），
    --   而不是背包摘要 —— 否则"等以后抽到了再配"就做不到，每次都要改代码。
    --
    -- 勾选语义（用户拍板 A 方案）：
    --   · 该品质**一个都没勾** = 这个品质的角色**全部参与**（= 保持 v237 原有行为，默认不变）
    --   · 该品质**勾了任意一个** = **只有勾上的参与**，其余一律不参与
    --   · 一个都没勾的品质 + 没进品质名单的品质 ⇒ 永不参与
    --
    -- 三套配置**互相独立**：Solar / 万圣节 / 去突变 各一份，互不影响。
    -- ⚠ 自动突变两处只列**白板**（ty==""）：已经突变过的角色不会被二次突变，列出来是纯噪音；
    --   去突变反而**专列有突变的**（洗突变机器吃的就是它们），口径相反，别搞混。

    -- ⚠⚠ CFC 只能声明一次，且必须在下面的 do 块**之前**：
    --   之前这里和文件下方各写了一次 `local CFC = {...}`，第二个（空表）把已经
    --   填好图鉴的那个覆盖掉 -> CFC.rarity 永远为空 -> cfAllows 对任何角色都返回 nil
    --   -> 整套角色筛选静默失效（实测踩到，表现为"预览 0 个候选"）。
    local CFC = { catalog = {}, rarity = {}, bag = {} }   -- 图鉴 / 名字->品质 / 背包索引

    -- 全游戏图鉴索引：[品质] = { {name=, cps=} ... }（按初始CPS从高到低）
    do
        local CC = Constants and Constants.Characters
        if type(CC) == "table" then
            for nm, d in pairs(CC) do
                if type(d) == "table" then
                    local ra = tostring(d.Rarity or "")
                    if ra ~= "" then
                        local bucket = CFC.catalog[ra]
                        if not bucket then bucket = {} CFC.catalog[ra] = bucket end
                        local inserted = false
                        local cps = tonumber(d.CPS) or 0
                        local item = { name = tostring(nm), cps = cps }
                        for i = 1, #bucket do
                            local b = bucket[i]
                            if cps > b.cps or (cps == b.cps and item.name < b.name) then
                                table.insert(bucket, i, item)
                                inserted = true
                                break
                            end
                        end
                        if not inserted then bucket[#bucket + 1] = item end
                    end
                end
            end
        end
    end

    -- 名字 -> 品质（全图鉴）。创建在 cfAllows 之前，否则 cfAllows 里的 CFC.rarity
    -- 会被当成全局变量读取（恒为 nil）⇒ 整套角色筛选静默失效。

    -- 背包摘要索引：名字 -> { blank = 白板数量, mut = 突变数量 }

    local function rebuildCharMap()
        local m = {}
        if type(R.summary) == "table" then
            for _, v in pairs(R.summary) do
                if type(v) == "table" then
                    local nm = tostring(v.n or "")
                    if nm ~= "" then
                        local e = m[nm]
                        if not e then e = { blank = 0, mut = 0, types = {}, tyN = {} } m[nm] = e end
                        local c = tonumber(v.c) or 1
                        local ty = tostring(v.ty or "")
                        if ty == "" then
                            e.blank = e.blank + c
                        else
                            e.mut = e.mut + c
                            -- ★ 记下突变的**种类与各自数量**（去突变的预览必须按
                            --   "勾选的突变类型"筛选，否则会出现"只勾了 Gold/Honey
                            --   却把 Lava 角色也列出来"的错（用户实测指出过））。
                            e.types[ty] = true
                            e.tyN[ty] = (e.tyN[ty] or 0) + c
                        end
                    end
                end
            end
        end
        CFC.bag = m
    end

    -- ⭐ 统一判定入口。三个功能**全部**通过它，绝不在业务逻辑里各写一遍。
    --   返回 nil = 该角色不在任何一份品质名单里 ⇒ 该功能根本不考虑它
    --   返回 true / false = 在名单里，且允许 / 不允许参与
    --
    -- ⚠ 品质名单只有**唯一一份**：直接用各功能原有的那份配置 ——
    --   solar -> cfg.solarRarities、halloween -> cfg.rarities、wash -> cfg.washRarities。
    --   这三份就是界面上那三个品质下拉绑定的表（下拉会原地改它），所以天然同步。
    --   早先版本在 charPick 里各存了一份 allow，结果与它们互相不同步（实测踩到）。
    local RAR_BY_MODE = {
        solar = function() return cfg.solarRarities end,
        halloween = function() return cfg.rarities end,
        wash = function() return cfg.washRarities end,
    }
    -- ===== 🚫 跨功能防冲突（**只针对 Solar ↔ 万圣节**）=====
    -- 用户要求：「如果我在 solar 选了 changlia 去参与，那么万圣节那边选择角色列表里
    --   changlia 就会提示出现已被 solar 选择，无法勾选」。
    --   语义：一个角色同一时间只能属于 Solar 或 万圣节 **其中之一**（这两个都是"拿去赌突变"，
    --   互相抢角色，必须互斥）。
    --
    -- ⚠⚠ 去突变(wash) **故意不参与互斥** —— 用户明确说明：
    --   「去极化不用写防冲突，因为需要清洗突变」。
    --   去突变是"把突变洗掉"，与"拿角色去赌突变"不是竞争关系：
    --   一个角色完全可以"在 Solar 等被砸" 同时 "允许被洗"。
    --   所以 wash 既不占用角色、也不会被别的功能挡住。
    local MODE_CN = { solar = "Solar", halloween = "万圣节", wash = "去突变" }

    -- 角色名 -> 占用了它的那个功能（只查 solar / halloween；wash 不占位）
    local function cfCharMode(nm)
        for _, md in ipairs({ "solar", "halloween" }) do
            local mm = cfg.charPick and cfg.charPick[md]
            local ss = mm and mm.sel
            if type(ss) == "table" then
                for _, bb in pairs(ss) do
                    if type(bb) == "table" and bb[nm] then return md end
                end
            end
        end
        return nil
    end
    local function cfOtherMode(nm, selfMode)
        local md = cfCharMode(nm)
        if md ~= nil and md ~= selfMode then return md end
        return nil
    end
    R.charFilterSlots = { charMode = cfCharMode, otherMode = cfOtherMode }

    local charMapSrc = nil      -- 上次重建索引时的摘要引用（变了才重建）
    -- ★ strict = true 时**只认"明确允许"**（== true），用于一切"真要把角色拿去赌"的地方。
    --   ⚠ 为什么必须有这个开关（2026-10-05 事故）：
    --     调用点原来写 `allows(...) ~= false`，而本函数在
    --       · 名字索引里没有这个角色（CFC.rarity[name] == nil）
    --       · 配置缺失 / 品质名单是空表
    --     这几种情况下返回的是 **nil**，`nil ~= false` 成立 ⇒ **误放行**。
    --     后果：用户明确排除的角色照样被拿去赌 Solar，不可逆地被突变。
    --   ⇒ 自动手持一律用 strict=true；UI 展示仍用宽松判定（好显示出 ❌没有 / 已全突变）。
    local function cfAllows(mode, name, strict)
        -- 自愈：保证背包索引最新。原来靠外部调用点显式重建，
        -- 现在整块关在工厂里、外部碰不到，就在这里顺手保证。
        if R.summary ~= charMapSrc then
            charMapSrc = R.summary
            rebuildCharMap()
        end
        -- strict 模式下的"空配置"语义：宁可什么都不做，也不能拿没确认的角色去赌
        local lc = cfg.charPick
        if type(lc) ~= "table" then return (not strict) and nil or false end
        local m = lc[mode]
        if type(m) ~= "table" then return (not strict) and nil or false end
        local getRar = RAR_BY_MODE[mode]
        local allow = getRar and getRar() or nil
        if type(allow) ~= "table" then return (not strict) and nil or false end
        local ra = CFC.rarity[name]
        if ra == nil then return (not strict) and nil or false end   -- 名字索引里没有 ⇒ strict 下不放行
        if not allow[ra] then return nil end                         -- 品质没被选中 ⇒ 不考虑
        -- 🚫 互斥（**只对 solar / halloween 生效**）：已被另一个"赌突变"功能选走的角色不再放行。
        --    去突变(wash) 是清洗突变，不参与互斥 —— 用户在 Solar 等被砸的角色照样可以允许被洗。
        if mode ~= "wash" and cfOtherMode(name, mode) ~= nil then return false end
        -- strict：只保证"明确允许"。**绝不给 solar / halloween 加"白板数>0"检查**。
        --   ⚠⚠ 实测踩到（v273 第一版就犯了这个错）：用户背包里 5 个 Ancient 全是带突变的
        --   （Kafka|Lava×3 等），白板组合数 = 0 ⇒ 加了那个检查会把 Solar 候选**全部否掉**，
        --   表现成"功能完全不工作"。原因：手持是**从背包取任意一个该名字的白板**，
        --   不需要该名字在摘要里有存量记录。
        --   只有 **wash** 真的需要"背包里有带该突变的角色"（机器要喂的就是它）。
        if strict and mode == "wash" then
            local e = CFC.bag[name]
            if e == nil or (e.mut or 0) <= 0 then return false end
        end
        local sel = m.sel
        if type(sel) ~= "table" then return (not strict) and true or false end
        local bucket = sel[ra]
        local n = 0
        if type(bucket) == "table" then for _ in pairs(bucket) do n = n + 1 end end
        if n == 0 then
            -- 一个都没勾 ⇒ 该品质全部参与。
            -- ⚠ 但这正是 2026-10-05 事故的放大器：勾选被丢空后这里会放行**整个品质**。
            --   strict 模式下仍然遵循这个语义（用户明确选择的行为），
            --   但上面那些"配置异常"的分支已经全部改成 fail-closed（返回 false），
            --   所以只有"用户真的一个都没勾"才会走到这里全放行。
            return true
        end
        return bucket[name] == true                          -- 勾了 ⇒ 只看勾上的
    end

    -- 名字 -> 品质（全图鉴）。模糊匹配兜底：游戏图鉴名与背包摘要名若有细微差异也能命中，
    --   并且把命中的别名记回 CFC.rarity，后续走精确路径不再重扫。
    local function buildNameIndex()
        for ra, list in pairs(CFC.catalog) do
            for _, it in ipairs(list) do CFC.rarity[it.name] = ra end
        end
        if type(R.summary) == "table" then
            for _, v in pairs(R.summary) do
                if type(v) == "table" then
                    local nm, ra = tostring(v.n or ""), tostring(v.ra or "")
                    if nm ~= "" and ra ~= "" and CFC.rarity[nm] == nil then CFC.rarity[nm] = ra end
                end
            end
        end
    end
    buildNameIndex()

    --============================================================== 角色级筛选选择器 UI（v238）
    -- ⚠ 必须放在模块级、**不能放进 buildUI**：Luau 的 200 局部变量上限是每函数的，
    --   buildUI 本身已经接近上限，塞进去会直接 "Out of local registers" 编译失败。
    --   这里引用的 CFC / cfAllows / cfg / R / E 全是模块级 upvalue，所以位置无所谓。
    --================ 🎯 角色级筛选选择器（v238）
    -- 用户需求：勾一个品质 -> 下面列出"这个品质的全部角色" -> 勾谁谁参与突变。
    -- 数据源是**全游戏图鉴**（185 个角色），不是你背包里现有的 —— 这样以后抽到新角色
    -- 直接就能勾，不用改代码。背包里没有的会标 ❌（配置照样存下来）。
    --
    -- UI 结构（每个功能一组，互相独立）：
    --   ① 品质下拉：决定"这个功能的品质名单"（= 已有逻辑的品质筛选，复用同一份 cfg）
    --   ② 角色下拉：跟着①动态换选项；一个都不勾 = 该品质角色全参与
    --   ③ 预览标签：实时显示最终会拿哪些角色去赌
    -- 下拉的选项是运行时动态生成的（角色名来自 Constants，不是写死的），
    --   所以只能建完控件后用 Values / RefreshPool / SetValues 换代。
    local pickUI = {}
    R.pickUI = pickUI

    -- 🏷 角色下拉的标签格式（用户指定）：
    --     [完整品质] 完整角色名  $初始CPS  状态/数量
    --   例：  [Ancient] Changlia  $125.0M/s  ×2
    --         [Celestial] Alucardia  $18.0M/s  ✗暂无突变
    --   状态放**最后**。默认下拉宽 212px 会被截断，用户说「我把UI框拉长一些就可以显示了」，
    --   所以这里给完整信息，把面板拉宽即可全部看到（下面的预览行也是全宽的）。

    local function cfFmtCps(n)
        n = tonumber(n) or 0
        if n >= 1e12 then return string.format("%.2fT/s", n / 1e12) end
        if n >= 1e9 then return string.format("%.2fB/s", n / 1e9) end
        if n >= 1e6 then return string.format("%.1fM/s", n / 1e6) end
        if n >= 1e3 then return string.format("%.1fK/s", n / 1e3) end
        return string.format("%d/s", n)
    end

    -- 🎨 统一的角色清单格式：纵向、对齐、品质着色、CPS 从高到低。
    --   万圣节候选列表就是这个观感（用户要求 Solar / 去突变 / 角色选择器 都用它）。
    --   返回 text（富文本）与 stat（合计/最高）。
    local function cfFormatList(list, opt)
        opt = opt or {}
        local cap = tonumber(opt.cap) or 15
        local body = {}
        local total, top, nUse, useSum, useTop = 0, 0, 0, 0, 0
        local n = math.min(#list, cap)
        for i = 1, n do
            local c = list[i]
            total = total + (tonumber(c.cps) or 0)
            if (tonumber(c.cps) or 0) > top then top = tonumber(c.cps) or 0 end
            -- participating = 本次真的会被用（既在角色白名单里，且突变类型也匹配）
            local participating = (c.part == nil or c.part == true) and not c.noMatch
            if participating then
                nUse = nUse + 1
                useSum = useSum + (tonumber(c.cps) or 0)
                if (tonumber(c.cps) or 0) > useTop then useTop = tonumber(c.cps) or 0 end
            end
            local rc = HW_K.RARITY_COLORS[c.rarity] or Color3.fromRGB(220, 220, 220)
            -- 名字列宽 21：够放下最长的 "Madoki Kaneme" 这类名字，超出不截断只是那行变长
            -- CPS 用绿色（140,230,150）—— 与主控"候选角色"列表同一套配色，用户点名要绿色
            -- ⚠ cfFmtCps 已经自带 /s，这里**绝不能**再写 /s（否则显示 $145.0M/s/s，实测踩到）
            -- 🚫 未勾选（白名单模式下被判不参与）的行标出来并压暗，
            --    否则"列了 8 个"会被误读成"8 个都会上场"（用户实测点出过这个歧义）。
            local tail, dimS, dimE = "", "", ""
            if not participating then
                dimS = '<font color="rgb(120,120,135)">'
                dimE = '</font>'
                tail = '  <font color="rgb(255,120,120)">🚫不参与</font>'
            end
            -- 突变类型不匹配（去突变专有）：这角色有突变，但没有一个是你勾选要洗的类型
            --   -> 明确标出来，否则用户会以为脚本漏了它（实测被问过"为什么 lava 会出现在候选名单"）
            if c.noMatch then
                dimS = '<font color="rgb(120,120,135)">'
                dimE = '</font>'
                tail = '  <font color="rgb(255,180,80)">✗突变类型未勾选</font>'
            end
            -- 数量（自动突变 = 白板数 / 去突变 = 可洗的突变数）
            local cntTxt = ""
            if (c.cnt or 0) > 0 then
                cntTxt = string.format(' <font color="rgb(200,200,120)">×%d</font>', c.cnt)
            end
            body[i] = string.format('  %2d. %s%-21s %s  <font color="rgb(140,230,150)">$%s</font>%s%s%s',
                i, dimS,
                string.format('<font color="rgb(%d,%d,%d)">%s</font>',
                    math.floor(rc.R * 255), math.floor(rc.G * 255), math.floor(rc.B * 255), c.name),
                string.format('<font color="rgb(150,150,170)">[%s]</font>', c.rarity),
                cfFmtCps(c.cps), cntTxt, tail, dimE)
        end
        if #list > cap then
            body[#body + 1] = string.format('<font color="rgb(150,150,170)">   … 还有 %d 个（只显示前 %d）</font>',
                #list - cap, cap)
        end
        return table.concat(body, "\n"),
               { total = total, top = top, use = nUse, useSum = useSum, useTop = useTop }
    end

    -- 当前模型下"可能参与"的角色（全图鉴 ∪ 背包，按初始CPS降序）
    --   mode == "wash" -> 只列【有突变，且突变类型 ∈ cfg.washTypes】的；其余两处只列【白板】
    --   品质名单取各功能唯一那份配置（见 cfAllows 上方的 RAR_BY_MODE）
    local function cfModelList(mode)
        local getRar = RAR_BY_MODE[mode]
        local allow = (getRar and getRar()) or {}
        -- 白名单：m.sel[品质][名字] = true。一个品质都没勾 = 该品质全参与。
        local mSel = (cfg.charPick and cfg.charPick[mode] and cfg.charPick[mode].sel) or {}
        -- ★ 去突变特有的第二道筛：**突变类型**必须 ∈ cfg.washTypes。
        --   漏了这道会出真错（用户实测指出）：「明明只选了 gold 跟 honey，
        --   为什么下面三个明明是 lava 却会出现在候选名单？」
        --   真实执行路径 washTargets() 一直是筛类型的，是我加的预览没筛 -> 两边不一致。
        local mTypes = cfg.washTypes or {}
        -- 该角色在去突变口径下的"可用数量"（只数勾选的类型）与"不匹配"标记
        local function washInfo(nm)
            local e = CFC.bag[nm]
            if e == nil then return 0, false end
            local n, matched, anyMut = 0, false, (e.mut or 0) > 0
            for ty, c in pairs(e.tyN or {}) do
                if mTypes[ty] then n = n + c matched = true end
            end
            -- matched=false 且 anyMut=true => 这角色有突变，但没有一个是你要洗的类型
            return n, (anyMut and not matched)
        end
        -- part = 这个角色本次到底会不会被用（用于在清单里区分"会参与/不参与"）
        local function isPart(ra, nm)
            local b = mSel[ra]
            if type(b) ~= "table" then return true end
            local n = 0
            for _ in pairs(b) do n = n + 1 end
            if n == 0 then return true end
            return b[nm] == true
        end
        local seen, out = {}, {}
        -- cnt = 白板数量（自动突变两处）/ 可洗的突变数量（去突变）
        local function add(nm, ra, cps, cnt, noMatch)
            if nm == "" or seen[nm] then return end
            seen[nm] = true
            out[#out + 1] = { name = nm, rarity = ra, cps = tonumber(cps) or 0,
                              cnt = tonumber(cnt) or 0, noMatch = noMatch == true,
                              part = isPart(ra, nm) }
        end
        for ra, list in pairs(CFC.catalog) do
            if allow[ra] then
                for _, it in ipairs(list) do
                    local e = CFC.bag[it.name]
                    local usable, cnt
                    if mode == "wash" then
                        -- 去突变：只数**勾选了类型**的那些突变；
                        -- 数量为 0 但确实有突变 = 类型不匹配，交给下面那段统一列出来标注
                        local n = washInfo(it.name)
                        cnt = n
                        usable = n > 0
                    else
                        cnt = (e ~= nil) and (e.blank or 0) or 0
                        usable = cnt > 0
                    end
                    if usable then add(it.name, ra, it.cps, cnt) end
                end
            end
        end
        if type(R.summary) == "table" then
            for _, v in pairs(R.summary) do
                if type(v) == "table" then
                    local nm, ra = tostring(v.n or ""), tostring(v.ra or "")
                    local e = CFC.bag[nm]
                    if allow[ra] and e then
                        local cnt
                        if mode == "wash" then
                            cnt = (washInfo(nm))
                        else
                            cnt = (e.blank or 0)
                        end
                        if cnt > 0 then add(nm, ra, (tonumber(v.bc) or 0), cnt) end
                    end
                end
            end
        end
        -- 去突变：把"有突变、但没有一个是你勾选的类型"的角色也列出来并标注，
        --   这样用户能立刻看出"为什么不洗它们"（否则会以为脚本漏了）。
        if mode == "wash" then
            for ra, list in pairs(CFC.catalog) do
                if allow[ra] then
                    for _, it in ipairs(list) do
                        local n, noMatch = washInfo(it.name)
                        if n == 0 and noMatch then add(it.name, ra, it.cps, 0, true) end
                    end
                end
            end
            if type(R.summary) == "table" then
                for _, v in pairs(R.summary) do
                    if type(v) == "table" then
                        local nm, ra = tostring(v.n or ""), tostring(v.ra or "")
                        if allow[ra] then
                            local n, noMatch = washInfo(nm)
                            if n == 0 and noMatch then add(nm, ra, (tonumber(v.bc) or 0), 0, true) end
                        end
                    end
                end
            end
        end
        table.sort(out, function(a, b)
            local ka, kb = RARITY_RANK[a.rarity] or 0, RARITY_RANK[b.rarity] or 0
            if ka ~= kb then return ka > kb end
            if a.cps ~= b.cps then return a.cps > b.cps end
            return a.name < b.name
        end)
        return out
    end

    -- 建一组选择器。默认品质 = 传进来的那份（就是现有逻辑用的 cfg，保证行为一致）
    local function cfBuildPicker(parent, pcfg)
        local mode = pcfg.mode
        local st = pickUI[mode] or {}
        pickUI[mode] = st
        st.rarsShown = false
        st.bindRarKey = pcfg.bindRarKey      -- ★ 有值时：这个品质下拉就是 cfg[该键] 的唯一界面
        parent:AddLabel(pcfg.title, true)
        if pcfg.tip then parent:AddLabel(pcfg.tip, true) end
        st.dRar = parent:AddDropdown("cf_" .. mode .. "_rar", {
            Text = pcfg.rarText or "① 选择品质",
            Values = RARITY_LIST, Multi = true,
            -- ★★ AllowNull = true 是**必须的** ★★
            --   Obsidian 库的点击处理里有这道硬闸（库源码原文）：
            --     if not (Dropdown:GetActiveValues(true) == 1 and not Try and not Info.AllowNull) then
            --   即：**只剩 1 个勾选、你要取消它、且 AllowNull 不为 true -> 直接拒绝**。
            --   而 AllowNull 不在库的 Dropdown 默认表里（= nil），所以默认就是"唯一项取消不掉"。
            --   这就是用户报的"选了一个就没法取消勾选"的真正根因（我先前误判成标签格式问题）。
            AllowNull = true,
            Default = pcfg.rarDefault or {},
            Tooltip = pcfg.rarTip or "",
        })
        -- ★ 品质一改就写回 cfg（bindRarKey 有值时，这个框就是那份配置的唯一入口）
        if pcfg.bindRarKey then
            st.dRar:OnChanged(function(v)
                -- 🛡 代码自己发起的写入一律屏蔽（统一开关，见 cfFactory 顶部说明）
                if cfQuiet then return end
                local nv = {}
                if type(v) == "table" then for k, on in pairs(v) do if on then nv[k] = true end end end
                -- 🛡 值没变就直接返回：cfRefreshUI 会用 SetValue 把 cfg 回灌到界面，
                --   那也会触发本回调。不加这个守卫就会每轮白跑一次 refreshCandidates。
                local cur = cfg[pcfg.bindRarKey] or {}
                local same = true
                for k in pairs(nv) do if not cur[k] then same = false break end end
                if same then for k in pairs(cur) do if not nv[k] then same = false break end end end
                if same then return end
                if pcfg.bindRarKey == "rarities" then
                    cfg.rarities = nv
                    if R.refreshCandidates then pcall(R.refreshCandidates) end
                    if R.manageHotbar then pcall(R.manageHotbar, true) end
                elseif pcfg.bindRarKey == "solarRarities" then
                    cfg.solarRarities = nv
                    if R.refreshCandidates then pcall(R.refreshCandidates, cfg.solarRarities) end
                elseif pcfg.bindRarKey == "washRarities" then
                    cfg.washRarities = nv
                    -- 原来挂在独立品质下拉上的日志与清单刷新，搬到这个唯一入口上
                    local nn = {}
                    for k, on in pairs(nv) do if on then nn[#nn + 1] = k end end
                    table.sort(nn, function(a, b) return (RARITY_RANK[a] or 0) > (RARITY_RANK[b] or 0) end)
                    log("去突变参与品质 = " .. (#nn > 0 and table.concat(nn, " > ") or "（空 —— 不会洗任何角色）"))
                    if R.renderWashList then pcall(R.renderWashList) end
                end
                st._forcedSig = nil            -- 让下一轮重新算签名
            end)
        end
        st.dChar = parent:AddDropdown("cf_" .. mode .. "_char", {
            Text = "② 勾选角色（不勾 = 该品质全部参与）",
            Values = { "(等待选择品质…)" }, Multi = true, Searchable = true,
            -- ★★ AllowNull = true 是必须的，理由同上面的品质下拉 ★★
            --   不开的话"只剩一个勾选时取消不掉"（库的硬闸，见上面的详细说明）。
            --   本功能的语义正是"一个都不勾 = 该品质全部参与"，所以**必须允许清空**。
            AllowNull = true,
            Default = {},
            -- ★★★ 值 = 索引（稳定），显示 = 标签（内容）★★★
            --   库源码事实（obsidian_Library.lua）—— **有两个**格式钩子，缺一不可：
            --     L8587  local FormattedValue = tostring(Info.FormatListValue and
            --                Info.FormatListValue(RawValue) or RawValue)
            --     L8689  Row.Button.Text = Entry.FormattedValue          -- 列表里每一项
            --     L8504  .. (Info.FormatDisplayValue and
            --                tostring(Info.FormatDisplayValue(RawValue)) or tostring(RawValue))
            --     L8519  if Str ~= "" and Info.FormatDisplayValue then Str = ...  -- 已选值(按钮上)
            --   ⚠ 只设 FormatListValue 的话：列表正常，但**勾选后按钮上显示数字**。
            --   为什么值必须用索引而不能用标签：
            --     · 值用标签 -> 标签里的 ×N / ✗已全突变 / 🚫 一变就查不到 -> 勾选被丢
            --       （2026-10-05 事故：用户排除的 Kafka/Miki/Rikki 全被拿去赌 Solar）
            --     · 值用纯索引但不渲染 -> 列表显示成 "1 2 3 4"，看不到角色名（v276 踩到）
            --   ⇒ 值 = 索引（稳定） + 两个 Format 钩子渲染标签（可读）。
            FormatListValue = function(raw)
                -- 值 = 角色名（跨会话稳定）；显示 = 完整标签
                local nm = tostring(raw)
                local lb = st.labelOf and st.labelOf[nm]
                return lb or nm
            end,
            FormatDisplayValue = function(raw)
                -- 按钮上空间有限：只显示 "[品质] 名字"，省掉 CPS 与状态
                local nm = tostring(raw)
                local ra = st.rarOf and st.rarOf[nm]
                if ra then return "[" .. ra .. "] " .. nm end
                return nm
            end,
            Tooltip = pcfg.charTip or "",
        })
        -- ★ 显示标签是 "[品质] 名字 $CPS ×数量"，但**存的是角色名**。
        --   这里做 显示标签 -> 角色名 的翻译后写进 m.sel[品质]（品质级白名单）。
        --   ⚠ 绝不能在这里动 st._charSig：那个签名决定"什么时候重建下拉选项"，
        --     重建时会 SetValue({}) 清空勾选。用户勾一下就被清空 = 功能不可用。
        st.dChar:OnChanged(function(v)
            -- 🛡 重建下拉期间**屏蔽**本回调（v280）
            --   库的 SetValues 会主动删掉"新列表里没有的旧值"并触发 RunChanged
            --   （obsidian_Library.lua L9090-9116），而我们是按标签重建选项的
            --   —— 那一刻 Value 可能已不含勾选，于是这里会拿**空表**覆盖 cfg，
            --   造成"白名单失效 -> 全体参与"（实测：勾了 4 个却存成空表）。
            --   重建只是换显示文字，绝不该改用户的勾选数据。
            if cfQuiet then return end
            local m = cfg.charPick and cfg.charPick[mode]
            if type(m) ~= "table" then return end
            -- ★★★ v292 决定性防线：**拒绝"来路不明的清空"** ★★★
            --   症状（取证实测）：`solar 进=0{} 前sel=4` —— 库送进一个空表，
            --   把我们 4 个勾选清掉了 ⇒ sel 空 ⇒ "该品质全部参与" ⇒ 烧角色。
            --
            --   为什么这必然是"库的内部事件"而不是用户操作：
            --     用户的清空只有一个入口（🧹 清空勾选按钮），而它走 cfQuietDo（已被上面挡掉）。
            --     用户**逐项取消**时，库送来的 v 里会**保留还没取消的那些角色名**，
            --     不会突然变成一个空表。
            --     ⇒ 所以"进=空 且 当前有勾选"只可能是库自己在 SetValues/Display
            --       内部删掉了它认为"已不存在"的值之后发的通知 —— 必须忽略。
            --
            --   ⚠ 注意不能"因为列表未就绪就不让用户清空"：真要清空请用清空按钮
            --     （或逐项取消），那两条路径都正常工作。
            local nIn = 0
            if type(v) == "table" then
                for _, on in pairs(v) do if on then nIn = nIn + 1 end end
            end
            if nIn == 0 then
                local nHave = 0
                for _, b in pairs(m.sel or {}) do
                    if type(b) == "table" then for _ in pairs(b) do nHave = nHave + 1 end end
                end
                if nHave > 0 then
                    -- 忽略这次"清空"，保持白名单不变（安全优先）
                    R._pickClearIgnored = (R._pickClearIgnored or 0) + 1
                    return
                end
            end
            -- 🔬 取证（排查完可删）：记录每次回调收到的值 + 调用前的条目数。
            --   目的：定位"重启后勾选被清空"到底是谁触发的、送进来的是什么。
            do
                local n0 = 0
                for _, b in pairs(m.sel or {}) do
                    if type(b) == "table" then for _ in pairs(b) do n0 = n0 + 1 end end
                end
                local nIn, inList = 0, {}
                if type(v) == "table" then
                    for k, on in pairs(v) do
                        if on then nIn = nIn + 1 if #inList < 6 then inList[#inList + 1] = tostring(k) end end
                    end
                else
                    inList[1] = "(" .. type(v) .. ")"
                end
                R._charCbLog = R._charCbLog or {}
                if #R._charCbLog < 16 then
                    R._charCbLog[#R._charCbLog + 1] = string.format("%s 进=%d{%s} 前sel=%d",
                        mode, nIn, table.concat(inList, ","), n0)
                end
            end
            -- ★★★ 绝不允许"先清空再重填"！★★★
            --   ⚠⚠⚠ 2026-10-05 第二次烧角色的真正根因（有实盘证据：sel 变空）：
            --     旧写法是 `for k in pairs(sel) do sel[k] = nil end` 先清空、再逐项填回。
            --     只要**中途任何一步出错**（下标越界、字段为 nil、库回调里抛错……），
            --     执行就中断 —— **sel 已被清空、却没填回来**。
            --     而 `sel` 空 = "该品质全部参与" ⇒ 用户明确排除的角色照旧被拿去赌 Solar。
            --     这也解释了"偶发、有时丢一两个有时全丢"的现象。
            --   ⇒ 现在改成：**先在临时表里建好，全部成功后再原子替换**。
            --     任何一步失败都保持原样（宁可这次点击不生效，也绝不能清空白名单）。
            local prev = m.sel
            if type(prev) ~= "table" then prev = {} end
            local built = {}
            local okBuild, berr = pcall(function()
                if type(v) ~= "table" then return end
                for raw, on in pairs(v) do
                    if on then
                        -- ⭐ v281：值**就是角色名**，不再需要任何翻译
                        --   （翻译层正是以前"查不到就静默丢弃勾选"的地方）
                        local nm = tostring(raw)
                        local raX = st.rarOf and st.rarOf[nm] or nil
                        local isLocked = st.lockedOf and st.lockedOf[nm] or false
                        if isLocked then
                            log("🚫 该角色已属于别的功能，不能同时勾选：" .. nm,
                                Color3.fromRGB(255, 140, 140))
                        elseif raX and nm ~= "" then
                            local b = built[raX]
                            if type(b) ~= "table" then b = {} built[raX] = b end
                            b[nm] = true
                        end
                    end
                end
                -- 🧹 清掉空桶（否则配置里会留下 "Celestial":[] 这种空表，
                --    读起来像是"勾了 Celestial 但列表为空"，实际含义是"没勾"）
                for k, b in pairs(built) do
                    if type(b) ~= "table" or next(b) == nil then built[k] = nil end
                end
            end)
            if okBuild then
                m.sel = built            -- ⭐ 原子替换：只有全部成功才生效
            else
                -- 保留原勾选，只报错。下次刷新会把界面重新对齐回 cfg 的值。
                m.sel = prev
                st._wantSig = nil
                log("⚠ 角色勾选解析出错，已保留原有勾选（不会清空白名单）：" .. tostring(berr),
                    Color3.fromRGB(255, 140, 140))
            end
        end)
        -- ⚠⚠ 为什么需要这个按钮（库的限制，不是我们的 bug）：
        --   Obsidian 库的点击处理里有这道硬闸（库源码原文）：
        --     if not (Dropdown:GetActiveValues(true) == 1 and not Try and not Info.AllowNull) then
        --   即：**只剩 1 个勾选时，你点它取消 —— 会被直接拒绝**。
        --   而 Info.AllowNull 不在库的 Templates.Dropdown 模板里，会被 Library:Validate 过滤掉，
        --   库也没提供公开的设置方法 ⇒ 从外面**无法**打开这个开关。
        --   ⇒ 用户实测反馈"唯一选项取消不掉"，这里给一个**明确的清空按钮**绕过它。
        --     清空 = 该品质一个都不勾 = 该品质全部参与（正是本功能的语义）。
        st.bClear = parent:AddButton({
            Text = pcfg.clearText or "🧹 清空勾选（一个都不勾 = 该品质全部参与）",
            Func = function()
                local mm = cfg.charPick and cfg.charPick[mode]
                if type(mm) ~= "table" then return end
                mm.sel = {}
                -- 同时清空品质名单与角色下拉，保持界面一致
                st._wantSig = ""       -- 让下一轮对齐时把"空勾选"写进界面
                -- 🛡 这是代码在清空（用户点了清空按钮），不是用户勾选 -> 静默
                cfQuietDo(function() st.dChar:SetValue({}) end)
                cfQuietDo(function() st.dRar:SetValue({}) end)
                if pcfg.bindRarKey then
                    if pcfg.bindRarKey == "rarities" then
                        cfg.rarities = {}
                        if R.refreshCandidates then pcall(R.refreshCandidates) end
                    elseif pcfg.bindRarKey == "solarRarities" then
                        cfg.solarRarities = {}
                        if R.refreshCandidates then pcall(R.refreshCandidates) end
                    elseif pcfg.bindRarKey == "washRarities" then
                        cfg.washRarities = {}
                    end
                end
                st._wantSig = nil
                st._rarSig = nil
                log("🧹 已清空【" .. tostring(mode) .. "】的勾选（品质与角色都空了 = 全部参与）",
                    Color3.fromRGB(140, 220, 255))
            end,
        })
        st.lPreview = parent:AddLabel(pcfg.initText or "预览: 等待扫描背包…", true)
        return st
    end

    -- 刷新所有选择器（预览 + 动态换角色选项）。挂到 renderStatus 里每轮调用一次。
    local _cfLastSig = {}
    -- ⚠ 必须是 local function：模块级的 `function R.xxx()` 也占主 chunk 的 local 额度
    local function cfRefreshUI()
        if type(pickUI) ~= "table" then return end
        -- 🔬 v297 诊断总开关：一键关掉选择器的全部界面刷新。
        --   背景：用户报"进游戏立刻崩溃"，怀疑是这里挂在 5Hz 上做重活。
        --   本开关用于**单变量实验**：关掉后若不再崩 -> 就是这里；若照样崩 -> 另有原因。
        --   用法：R.cfDisableUI = true（也可写进配置 cfDisablePickerUI = true 永久生效）
        if R.cfDisableUI or cfg.cfDisablePickerUI == true then return end
        for _, mode in ipairs({ "solar", "halloween", "wash" }) do
            local st = pickUI[mode]
            if st and st.dRar and st.dChar and st.lPreview then
                local m = cfg.charPick and cfg.charPick[mode]
                if type(m) == "table" then
                    -- ① 品质下拉
                    --   ⚠ cfg 是唯一真源，界面只是它的视图。
                    --   bindRarKey 有值 = 这个下拉就是 cfg[该键] 的界面入口：
                    --   用户点击 -> OnChanged 写回 cfg（见 cfBuildPicker），
                    --   这里只负责把 cfg **显示出来**，绝不反向改 cfg（避免两边打架）。
                    local rarSel
                    if st.bindRarKey then
                        rarSel = {}
                        for k, on in pairs(cfg[st.bindRarKey] or {}) do if on then rarSel[k] = true end end
                        -- ★ 每轮都按 cfg 对齐（不用签名缓存）：
                        --   Value 存的是键名、选项固定，但缓存签名会漏掉"用户取消勾选后
                        --   Value 与 cfg 不一致"的情况 -> 表现同样是"取消不掉"。
                        --   SetValue 内部只写表，重复调用无副作用。
                        --
                        -- 🛡🛡🛡 v288：这一行**必须**屏蔽 OnChanged！
                        --   这是"重启后勾选全丢"的**真正元凶**（打点实测：延read=0）：
                        --   本函数在背包/图鉴就绪前也会跑，那一刻 cfg[bindRarKey] 还是空表
                        --   -> rarSel = {} -> SetValue({}) -> 触发 Rarity 下拉的 OnChanged
                        --   -> 它执行 `sel[bucket] = nil`，把该品质**整桶角色勾选删掉**
                        --   -> charPick.solar.sel 变空 -> "全部参与" -> 又一次烧角色。
                        --   （角色下拉的同类问题 v280 已修，但**漏了品质下拉**。）
                        cfQuietDo(function() st.dRar:SetValue(rarSel) end)
                        st.rarsShown = true
                    else
                        local getRar = RAR_BY_MODE[mode]
                        rarSel = (getRar and getRar()) or {}
                        -- ⚠ 只有"界面确实有勾选"时才用界面值覆盖。
                        --   实测坑：多选下拉刚建好（或 Default 还没落到 Value）时
                        --   dRar.Value 可能是空的，若拿它当准就会把 cfg 里的选择清掉，
                        --   表现为"角色列表突然全空"（用户实测反馈过两次）。
                        local nV0 = 0
                        for _, on in pairs(v) do if on then nV0 = nV0 + 1 end end
                        if nV0 > 0 then
                            rarSel = {}
                            for k, on in pairs(v) do if on then rarSel[k] = true end end
                        end
                        -- ★ 同样每轮按 cfg 对齐（理由见上）
                        -- 🛡 v288：同样必须屏蔽（见上面 else 分支的详细说明）
                        cfQuietDo(function() st.dRar:SetValue(rarSel) end)
                        st.rarsShown = true
                    end
                    local rarSig = {}
                    for k, v in pairs(rarSel) do if v then rarSig[#rarSig + 1] = k end end
                    table.sort(rarSig)
                    -- ② 以"当前悬停/最近操作的品质"为准；没记录过就取名单里最高的那个
                    local ra = st.curRar
                    if ra == nil or not rarSel[ra] then
                        ra = nil
                        for _, k in ipairs(rarSig) do ra = k break end
                        st.curRar = ra
                    end
                    -- ⚠⚠ 必须保留 nil 防御：ra 可能是 nil（一个品质都没勾，或界面值还没落）。
                    --   下面 `ra .. "|"` 一旦拿到 nil 就抛 "attempt to concatenate nil"，
                    --   而 cfRefreshUI 是整段执行的 -> 后半段（预览、选项刷新）全部不执行，
                    --   表现就是"角色框里什么都没有"（用户实测反馈的正是这个现象）。
                    local sel = m.sel or {}
                    if type(sel) ~= "table" then sel = {} m.sel = sel end
                    -- ★ 勾了多个品质时，**每个品质的角色都要列出来**（早先只列了排名最高的那个，
                    --   导致勾了 Celestial+Ancient 却只看到 Celestial，Ancient 的角色根本没得勾）。
                    --   每条前面标 [品质]，并按"品质从高到低 → 同品质按 CPS 从高到低"排列，
                    --   这样不同品质之间天然是连续的块，不会挤成一团分不清。
                    local names, nameToRar, locked = {}, {}, {}
                    for _, raX in ipairs(rarSig) do
                        -- ⚠ 不能在这里凭空建桶（会在配置里留下 "品质":[] 的空表，
                        --   读起来像"勾了这个品质但列表是空的"）。用到时才建。
                        local bucketX = sel[raX]
                        local list = CFC.catalog[raX] or {}
                        for _, it in ipairs(list) do
                            local e = CFC.bag[it.name]
                            local usable, tag
                            if mode == "wash" then
                                -- 去突变：数量 = 带突变的个数（机器要洗的就是它们）
                                usable = (e ~= nil and (e.mut or 0) > 0)
                                if not usable then
                                    tag = "✗暂无突变"
                                else
                                    tag = "×" .. tostring(e.mut)
                                end
                            else
                                usable = (e ~= nil and (e.blank or 0) > 0)
                                if e == nil then
                                    tag = "❌没有"
                                elseif not usable then
                                    tag = "✗已全突变"
                                else
                                    tag = "×" .. tostring(e.blank)
                                end
                            end
                            local key = it.name
                            if nameToRar[key] ~= nil then key = it.name .. "@" .. raX end  -- 同名跨品质兜底
                            -- 🚫 被另一个"赌突变"功能选走 -> 标记并锁死（无法勾选）
                            --    ⚠ 去突变(wash) 不参与互斥（用户明确要求：清洗突变是另一回事），
                            --      所以 wash 列表里不显示 🚫，也不锁任何角色。
                            local other = (mode ~= "wash") and cfOtherMode(it.name, mode) or nil
                            -- 🏷 标签格式（用户指定）：[品质] 名字 $CPS 状态/数量
                            --   状态放**最后**，前面是完整品质名 + 完整角色名 + 初始CPS。
                            --   ⚠ 下拉框默认宽度只有 212px，长标签会被截断 —— 用户明确说
                            --     「我把UI框拉长一些就可以显示了」，所以这里给**完整信息**，
                            --     把面板拉宽即可全部看到（预览那一行也是全宽的，同样可见）。
                            local st0 = tag or ""
                            if other ~= nil then st0 = "🚫已给" .. (MODE_CN[other] or other) end
                            local lbl = "[" .. raX .. "] " .. it.name
                                .. "  $" .. cfFmtCps(it.cps)
                                .. (st0 ~= "" and ("  " .. st0) or "")
                            if other ~= nil then
                                locked[#locked + 1] = lbl
                            end
                            names[#names + 1] = { key = key, ra = raX, name = it.name, cps = it.cps,
                                                  locked = other, label = lbl }
                            nameToRar[key] = raX
                        end
                    end
                    if #names == 0 then
                        names[1] = { key = "(无)", ra = nil, name = "(无)", cps = 0,
                                     label = (ra == nil and "(还没勾选任何品质)" or "(该品质暂无可用角色)") }
                    end
                    -- 🛡🛡🛡 v292：列表"还没就绪"时**绝对不要碰下拉** ★关键修复★
                    --
                    --   取证实测（在角色回调里记录）：`solar 进=0{} 前sel=4`
                    --   —— 空表被送进来把 4 个勾选清掉了。
                    --
                    --   机制：本函数每轮都会跑；启动那一秒图鉴/背包还没就绪，
                    --   `names` 只有一个占位项 `(无)`。此时 SetValues 会把下拉的 Values
                    --   换成 `{"(无)"}`，而库发现 `Value` 里那些**角色名不在新列表里**，
                    --   于是**主动把它们从 Value 里删掉**并触发 RunChanged（空表）
                    --   -> 我们的 OnChanged 拿到空表 -> **清空 cfg 的勾选**。
                    --   而且这个通知是**延迟**发出的（cfQuietDo 的静默窗口已关闭），
                    --   所以靠"包住调用"的守卫挡不住它。
                    --
                    --   ⇒ 正确做法：**数据没就绪就不重建列表**（占位项不算就绪）。
                    --     这样库永远不会遇到"值不在列表里"的情况，也就不会删值/通知。
                    local listReady = (#names > 1) or (names[1] and names[1].name ~= "(无)")
                    if not listReady then
                        -- 数据没就绪：**整段下拉逻辑全部跳过**（不建列表、不对齐勾选）。
                        -- 这样库永远不会遇到"Value 里的角色名不在 Values 里"，
                        -- 也就不会删值/发 RunChanged(空) 把 cfg 清空。
                        -- 预览那部分在下面照常执行（它只读 cfg，不碰控件）。
                    else
                    -- ⭐⭐ 下拉选项的**值 = 角色名**（v281 定稿）。
                    local disp = {}
                    for i, it in ipairs(names) do disp[i] = it.name end
                    -- 渲染用的查表（按角色名 -> 标签/品质）
                    st.labelOf, st.rarOf, st.lockedOf = {}, {}, {}
                    for _, it in ipairs(names) do
                        st.labelOf[it.name] = it.label
                        st.rarOf[it.name] = it.ra
                        st.lockedOf[it.name] = (it.locked ~= nil)
                    end
                    -- ② 重建选项
                    --   ⚠⚠⚠ v296 性能修复（用户报"进游戏一会儿就崩溃"）：
                    --   标签 `lbl` 里含 `×N`（白板数）/`✗已全突变`/`❌没有`，而这些**随时在变**
                    --   （角色在背包↔台子之间进出、被突变、被消耗）。所以 csig 每几秒就变一次，
                    --   而本函数挂在 **5Hz 的 renderStatus** 上 ⇒ 下拉每秒重建好几次。
                    --   重建要调库的 4 个重操作（SetValues / SetDisabledValues /
                    --   RefreshPool / RecalculateListSize），每次都重建列表池、重算尺寸、
                    --   重算过滤 —— **这是本脚本最重的 UI 操作**，高频跑会把游戏拖垮。
                    --
                    --   ⇒ 加**节流**：两次重建之间至少间隔 cfg.cfListRebuildSec（默认 45 秒）。
                    --     标签内容稍微旧一点完全可接受（数量/状态在**预览框**里是实时的，那才是主信息来源）。
                    --     想立刻刷新列表可以点「🔍 立即预览最优分配」或重新勾选品质。
                    local csig = table.concat(disp, "\1")
                    local nowR = os.clock()
                    local rebuildGap = tonumber(cfg.cfListRebuildSec) or 45
                    if rebuildGap < 5 then rebuildGap = 5 end
                    local sinceRebuild = nowR - (tonumber(st._lastRebuildAt) or -1e9)
                    if st._charSig ~= csig and sinceRebuild >= rebuildGap then
                        st._charSig = csig
                        st._lastRebuildAt = nowR
                        st.charNames = nameToRar
                        st.charItems = names
                        st.dispToKey = {}
                        for _, it in ipairs(names) do st.dispToKey[it.label] = it.key end
                        -- 🛡 重建期间屏蔽 OnChanged：SetValues 会因"旧值不存在"
                        --    触发 RunChanged，那一刻用空表覆盖勾选（v280 修）
                        cfQuietDo(function()
                            st.dChar:SetValues(disp)
                            if st.dChar.SetDisabledValues then st.dChar:SetDisabledValues(locked) end
                            if st.dChar.RefreshPool then st.dChar:RefreshPool() end
                            if st.dChar.RecalculateListSize then st.dChar:RecalculateListSize() end
                        end)
                        st._wantSig = nil      -- 选项变了 -> 勾选状态需要重新对齐一次
                    end
                    -- ③ 勾选状态与 cfg 对齐（**每一轮都做**，不只在换选项时）
                    --   选项的值就是角色名，这里按 cfg 算出应该勾哪些。
                    --   用户点击时 OnChanged 已先把选择写进 cfg，所以这里只会把界面
                    --   同步成"你刚点的结果"，不会覆盖你的操作。
                    if st.labelOf then
                        local want, sig = {}, {}
                        local mSelW = (cfg.charPick and cfg.charPick[mode] and cfg.charPick[mode].sel) or {}
                        for _, it in ipairs(names) do
                            local bx = mSelW[it.ra]
                            if type(bx) == "table" and bx[it.name] then
                                want[it.name] = true               -- ⭐ 值就是角色名
                                sig[#sig + 1] = it.name
                            end
                        end
                        local wsig = table.concat(sig, ",")
                        -- ⚠⚠ v293：`_wantSig` 只能在**确认 Value 真的同步了**之后才记。
                        --   踩过的坑：启动那轮算出的 wsig 是对的、于是就把它记进 _wantSig，
                        --   但那次 SetValue **实际没生效**（Value 仍是空）。
                        --   下一轮 wsig 不变 -> 判断"签名没变" -> **永远跳过对齐**
                        --   -> 界面永久停空（手册对齐一次就成功，证明前端逻辑没问题）。
                        --   ⇒ 每轮都拿"Value 的实际内容"和 want 比一次，不一致就重推。
                        local curN, wantN = 0, 0
                        for _, on in pairs((type(st.dChar.Value) == "table") and st.dChar.Value or {}) do
                            if on then curN = curN + 1 end
                        end
                        for _, on in pairs(want) do if on then wantN = wantN + 1 end end
                        if st._wantSig ~= wsig or curN ~= wantN then
                            st._wantSig = wsig
                            cfQuietDo(function() st.dChar:SetValue(want) end)
                        end
                    end
                    end   -- ← 结束 "if not listReady then ... else ..." 的 else 分支
                    -- ③ 预览：最终会拿哪些角色去赌
                    local total = 0
                    for _, it in pairs(sel) do
                        if type(it) == "table" then for _ in pairs(it) do total = total + 1 end end
                    end
                    local list = cfModelList(mode)
                    local nR = 0
                    for _ in pairs(rarSel) do nR = nR + 1 end
                    -- ⚠⚠ v339：**没候选/没选品质时，必须同时清掉板块【总预览】**。
                    --   用户实测（2026-10-11）：「solar 我明明只选了 ancient，为什么预览还是出现 cele 品质？」
                    --   根因：这一段原来是 `if nR==0 / elseif #list==0 then <只更新①号框预览> else <更新总预览> end`
                    --     —— 前两个分支**从不碰**【总预览】那行 ⇒ 它一直挂着上一次的旧清单
                    --     （用户看到的是"5 个 Celestial"，而当时 R.solarPool 其实是 0 个）。
                    --   实测真行为是对的：`R.solarPool = 0`、`solarPool 里 Celestial = 0`
                    --     ⇒ Solar 一个角色都不会拿，只是**屏幕上的字没被清掉**。
                    local function setBoardPreview(head, sub)
                        local txt = head .. '  <font color="rgb(150,150,170)">' .. tostring(sub or "") .. '</font>'
                        if mode == "solar" and E.lSolarPick then
                            E.lSolarPick:SetText(txt)
                        elseif mode == "wash" and E.lWashPick then
                            E.lWashPick:SetText(txt)
                        end
                    end
                    if nR == 0 then
                        st.lPreview:SetText('<font color="rgb(255,180,80)">预览: 还没选任何品质 -> 该功能不会参与突变</font>')
                        setBoardPreview('<font color="rgb(255,180,80)">【总预览】还没选任何品质 -> 该功能不会参与突变</font>', "")
                    elseif #list == 0 then
                        st.lPreview:SetText('<font color="rgb(255,180,80)">预览: 0 个角色</font>  '
                            .. (mode == "wash" and "（这些品质下你没有带突变的角色）"
                                or "（这些品质下你没有白板角色，或都被排除了）"))
                        setBoardPreview('<font color="rgb(255,180,80)">【总预览】本次一个角色都不会拿</font>',
                            (mode == "wash" and "（这些品质下你没有带突变的角色，或都被排除了）"
                                or "（这些品质下你没有白板角色，或都被排除了）"))
                    else
                        local txt, stat = cfFormatList(list, { cap = 15 })
                        -- ⚠ cfFmtCps 的返回值**已经带 /s**（形如 "988.0M/s"），
                        --   这里不能再拼 "/s"，否则显示成 "$988.0M/s/s"（实测踩到）。
                        --
                        -- 表头用**实际可用数 stat.use**（已排除"未勾选"和"突变类型不匹配"的行），
                        -- 不能用 #list —— 否则会出现"表头说 3 个都会参与、下面三行却都标着不参与"
                        -- 的自相矛盾（用户实测踩到过，就是被问"为什么 lava 会出现在候选名单"那次）。
                        local useN = tonumber(stat.use) or 0
                        local headTxt
                        if useN == #list then
                            -- 全部都会参与（没做角色级勾选，且类型都匹配）
                            headTxt = string.format(
                                '<font color="rgb(120,255,140)">%s预览: 这 %d 个角色都会参与</font>  '
                                .. '<font color="rgb(150,150,170)">（该品质未做角色级勾选 = 全部参与）</font>',
                                (mode == "wash" and "可洗 " or "可赌 "), #list)
                        elseif useN == 0 then
                            -- 一个都用不上（最常见原因：去突变的突变类型没勾）
                            headTxt = string.format(
                                '<font color="rgb(255,180,80)">%s预览: 本次 0 个可用</font>  '
                                .. '<font color="rgb(150,150,170)">（列表里这 %d 个都被排除了，原因见每行末尾）</font>',
                                (mode == "wash" and "可洗 " or "可赌 "), #list)
                        else
                            headTxt = string.format(
                                '<font color="rgb(120,255,140)">%s预览: 本次实际只用 %d 个</font>  '
                                .. '<font color="rgb(255,180,80)">（列表里另有 %d 个被排除，原因见每行末尾）</font>',
                                (mode == "wash" and "可洗 " or "可赌 "), useN, #list - useN)
                        end
                        st.lPreview:SetText(headTxt .. string.format(
                            '\n<font color="rgb(150,150,170)">合计 $%s · 最高 $%s</font>\n%s',
                            cfFmtCps(stat.useSum), cfFmtCps(stat.useTop), txt))
                        -- ★ 板块级"总预览"（Solar / 去突变 页签自己那一块）
                        --   计数口径与上面一致：useN = 实际可用数（已排除未勾选 / 类型不匹配）
                        if mode == "solar" and E.lSolarPick then
                            E.lSolarPick:SetText(string.format(
                                '<font color="rgb(120,255,140)">【总预览】本次 Solar 实际会拿这 %d 个角色去赌</font>  '
                                .. '<font color="rgb(150,150,170)">（CPS 从高到低 · 品质内共 %d 个，排除 %d 个）</font>\n%s',
                                useN, #list, #list - useN, txt))
                        elseif mode == "wash" and E.lWashPick then
                            E.lWashPick:SetText(string.format(
                                '<font color="rgb(120,255,140)">【总预览】本次去突变实际会拿这 %d 个角色去洗</font>  '
                                .. '<font color="rgb(150,150,170)">（CPS 从高到低 · 品质内共 %d 个，排除 %d 个）</font>\n%s',
                                useN, #list, #list - useN, txt))
                        end
                    end
                end
            end
        end
    end

    return {
        allows = cfAllows,
        buildPicker = cfBuildPicker,
        refreshUI = cfRefreshUI,
        modelList = cfModelList,
        formatList = cfFormatList,     -- 供主控预览 / 去突变清单复用同一套观感
        catalog = CFC.catalog,         -- 全游戏图鉴（[品质] = {{name,cps},...}）
        nameRarity = CFC.rarity,       -- 名字 -> 品质
        bag = function() return CFC.bag end,
        rebuild = rebuildCharMap,
        rebuildNames = buildNameIndex,
    }
end
-- ★ 直接挂 R，不在主 chunk 建 local：
--   主 chunk 的 200 local 上限实测已经顶格（多 2 个就编译失败），
--   新增的每一个模块级 local 都要省。
R.charFilter = cfFactory()
local function buildCandidates(summary, raritySet, allows)
    local list = {}
    if type(summary) ~= "table" then return list end
    local filter = raritySet or cfg.rarities
    for key, v in pairs(summary) do
        if type(v) == "table" then
            local ty = tostring(v.ty or "")
            local ra = tostring(v.ra or "")
            -- ★ v238：角色级过滤。allows 为函数时按名字判定（nil 返回 = 放行）
            if ty == "" and filter[ra] and (allows == nil or allows(tostring(v.n or "")) ~= false) then
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
-- ⚠ 同样挂 R 上：主 chunk 的 local 已贴 200 上限（理由见下面 clearNativeStroke 的注释）
R.hotbarBar = function()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    return mg and mg:FindFirstChild("BackpackHotBar") or nil
end

-- 🧹 清掉游戏**原生选中蓝框**（v308）
-- ⚠⚠ 为什么需要它（用户实测：物品栏里挂着好几个蓝框，"强迫症犯了"）：
--   游戏的原生蓝框是画在快捷栏格子上的一个 **UIStroke**，特征是 **Thickness ≈ 2**
--   （实测 Slot_5/6 上的 `UIStroke(2.00)`）；槽位里那些 0.04~0.12 的是**装饰描边**，
--   绝对不能删。所以这里用"厚度 >= 1.5"来区分，只删粗的那一根。
--   根因：原选中状态是**服务端下发**的。脚本持有过 Miki/Rikki 时游戏给它们画了蓝框，
--   之后脚本换持有 Angelia，只改了客户端 upvalue + 跑了一次视觉刷新，
--   那几个旧蓝框**没人清** -> 越攒越多。
-- ⚠⚠⚠ v312 修正：这里原来删的是"所有 Thickness >= 1.5 的 UIStroke"，
--   结果**严重闪烁**（实测：蓝框 0.7s 有、1.4s 无、2.8s 又有…）。
--   根因：游戏的快捷栏会**自己**给别的格子画粗描边（实测抓到 `Slot_9=C|Ania|Zombie`），
--   我们把它删掉 -> 游戏又画回来 -> 我们再删 …… 拉锯起来肉眼就是"一闪一闪"。
--   ⇒ 现在**只删我们自己画的那一根**（带 HW_Own 属性标记），
--     游戏的原生框一根都不碰 —— 谁画的谁负责，不再互相打架。
-- ⚠ 挂 R 上而不是 local：主 chunk 的 local 已贴 200 上限，多一个就编译失败。
R.clearNativeStroke = function()
    local bar = R.hotbarBar()
    if not bar then return 0 end
    local n = 0
    for _, slot in ipairs(bar:GetChildren()) do
        if slot.Name:match("^Slot_%d+$") then
            for _, d in ipairs(slot:GetChildren()) do
                if d:IsA("UIStroke") and d:GetAttribute("HW_Own") == true then
                    if pcall(function() d:Destroy() end) then n = n + 1 end
                end
            end
        end
    end
    return n
end

local function drawOwnStroke(key)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    local bar = mg and mg:FindFirstChild("BackpackHotBar")
    if not bar then return false end
    local done = false
    for _, slot in ipairs(bar:GetChildren()) do
        if slot.Name:match("^Slot_%d+$") then
            -- 只清自己画的（属性标记），别碰游戏的原生框
            for _, d in ipairs(slot:GetChildren()) do
                if d:IsA("UIStroke") and d:GetAttribute("HW_Own") == true then
                    pcall(function() d:Destroy() end)
                end
            end
            if key ~= nil and slot:GetAttribute("BoundKey") == key then
                local st = Instance.new("UIStroke")
                st.Name = "HW_HeldStroke"
                st:SetAttribute("HW_Own", true)      -- ★ 标记：这根是我们画的
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

-- 让某个 key 的快捷栏格子显示"蓝框"
-- ⚠⚠⚠ v313：**默认关闭，整条路径直接短路**。
--   用户 2026-10 明确要求："只要能给服务器接受角色突变就行了，其他我不在意了"。
--
--   历史包袱（别再把默认值改回 true）：为了这个框试过三种做法，全都不行 ——
--     ① 走"原生选中"（改游戏客户端 upvalue 再跑它的视觉刷新）：框归游戏管，
--        它一刷新就没了（实测亮 1 秒即消失）；
--     ② 每秒重刷：追不上游戏的重画节奏 —— 实测 3.6 秒内状态变化 7 次 = 闪烁；
--     ③ 自己画描边：游戏仍会画它自己的那根（实测在 Slot_1/Slot_2 之间来回画），
--        仍然是两边打架。
--   ⇒ 结论：**这个框由游戏自己管，脚本插不进去。**
--     而它与突变**完全无关** —— 服务器判定只看 `workspace.ToolFollowers` 里
--     有没有 `ToolFollower_<角色名>`（真持有）。所以关掉它不影响任何功能。
--   想要框：把配置 `nativeSelectionFrame` 改成 true（会闪，但功能无影响）。
local function clientSetSelected(key)
    if cfg.nativeSelectionFrame ~= true then
        -- 关着时顺带清历史残留（老版本可能留下过自绘描边）
        pcall(R.clearNativeStroke)
        return false
    end
    if drawOwnStroke(key) then return true end
    -- 兜底：加不进 UI（极少见）才回去试原生选中
    local g = clientG()
    if not g then return false end
    local visit = selectionVisuals()
    if not visit then return false end
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
-- 导出：渲染循环要定期重刷蓝框（蓝框是客户端视觉，会被游戏 UI 刷新覆盖）
R.clientSetSelected = clientSetSelected

local function clientClearSelection()
    clearOwnStroke()
    -- 🧹 v308：连游戏的原生蓝框一起清掉。
    --   否则放手之后那个框还挂在格子上（用户实测：越攒越多）。
    pcall(R.clearNativeStroke)
    local g = clientG()
    if not g then return false end
    local fn = rawget(g, "CF_BackpackClearSelection")
    if type(fn) == "function" then
        return pcall(fn)
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
    -- 🛡🛡 声明"我要保持这个角色手持"（v303 硬性手持闸门）
    --   意图生效期间，doRelease 会**拒绝放掉这个名字**。
    --   有效期给足（15 分钟）：只要主循环还在维护手持，就会不断刷新它；
    --   切角色/关功能时 applyRelease 会清掉，所以不会卡住放不掉。
    --   ⚠ 为什么需要这个：实测发现脚本自己的某些分支会把刚 hold 上的角色放掉，
    --     导致"角色消失又出现、不跟着走"（详见 doRelease 里的实测数据）。
    -- ⚠ 字段名用 expires，**不能用 until**（Luau 禁止关键字作表字段名，会报 Expected identifier 导致脚本加载失败）
    R._holdIntent = { name = name, key = key, expires = os.clock() + 900 }
    clientSetSelected(key)          -- 原生蓝框（和手动点击一样）
end

-- 你手动手持了某个候选角色 -> 直接接管，不重复发包、不跟你抢
local function adoptHold(key, name, rarity)
    R.hold.key, R.hold.name, R.hold.rarity = key, name, rarity
    R.hold.since = os.clock()
    R.hold.misses = 0
    R.hold.baseline = baselineFor(R.summary, name)
    R.hold.adopted = true
    -- 接管也等于"要保持在手上"（否则下一轮又会被当成 foreign 放掉）
    -- ⚠ 字段名用 expires，**不能用 until**（Luau 禁止关键字作表字段名，会报 Expected identifier 导致脚本加载失败）
    R._holdIntent = { name = name, key = key, expires = os.clock() + 900 }
    clientSetSelected(key)
    log("接替你手动手持的 " .. name .. " [" .. tostring(rarity) .. "]", Color3.fromRGB(140, 220, 255))
end

local function applyRelease(reason)
    -- 🛡 v303：放手 = 撤销"保持手持"的意图。
    --   （否则 doRelease 会一直拒绝放掉它，功能就卡死了）
    --   用户手动点"放手"按钮、切角色、关功能、事件结束 —— 走的都是这里。
    R._holdIntent = nil
    -- 🔬 记录"最后一次放手是谁要求的、从哪一行调的"（排查抖动用）
    --   实测踩到：脚本启用后 hold 会在 2 秒内被放掉，而硬性闸门一次都没拦到
    --   -> 说明是 applyRelease 主动清的意图。这里把 reason + 调用位置留下来，
    --     下次直接读 R._relLastReason / R._relLastFrom 就知道是谁干的，不用再猜。
    R._relLastReason = tostring(reason)
    R._relLastFrom = (function()
        local ok, loc = pcall(function() return debug.info(2, "sl") end)
        if ok and type(loc) == "table" then
            return tostring(loc[1]) .. ":" .. tostring(loc[2])
        end
        return "?"
    end)()
    R._relLog = R._relLog or {}
    R._relLog[#R._relLog + 1] = string.format("%.1f %s @%s",
        os.clock(), tostring(reason), tostring(R._relLastFrom))
    if #R._relLog > 30 then table.remove(R._relLog, 1) end
    -- ⚠ 修复：以前只在 R.hold.key 存在时才 doRelease()，
    --   所以你手动手持时点界面上的"放手"按钮完全没有反应。
    --   现在无论是不是本脚本所持，都真发一次放手。
    local who = R.hold.name or R.hold.foreignName
    -- 🛡 防抖（用户实测踩到：日志被"放手 Goka（非万圣节事件）"每 3 秒刷屏一次）：
    --   实测机制：服务器对持有操作有延迟/拒绝，你手动持有的角色被"放手"后往往还挂在身上，
    --   于是下一 tick 又被判定成"foreign 持有"-> 再放手 -> 再打日志 -> 无限循环。
    --   而事件（如 Lunar）运行期间 eventRemaining() 全程 > 0，这个分支会一直触发。
    --   对策：① 同一个角色 10 秒内只真发一次放手；② 日志只在角色变化或超过 60 秒才打。
    local nowT = os.clock()
    local sameTarget = (who ~= nil) and (who == R._lastRelWho)
    local throttled  = sameTarget and (nowT - (R._lastRelAt or 0) < 10)
    local logQuiet   = sameTarget and (nowT - (R._lastRelLogAt or 0) < 60)
    if not throttled then
        R._lastRelAt = nowT
        doRelease()
    end
    if who then
        if not logQuiet then
            R._lastRelLogAt = nowT
            R._lastRelWho = who
            log("放手 " .. tostring(who) .. (reason and ("（" .. reason .. "）") or "")
                .. (throttled and "（已抑制重复放手）" or ""))
        end
    elseif reason and not logQuiet then
        R._lastRelLogAt = nowT
        R._lastRelWho = who
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
        -- ★ v238：事件专属候选池 —— 带各自的【品质 + 角色】双重过滤。
        --   理由：以前 Solar 只按品质挑，候选池按 CPS 降序，所以永远先拿最高 CPS 的
        --   （实测：勾 Ancient 时 7 个候选里前 4 个都是 145M，后 6 个白板永远轮不到）。
        --   现在按名字过滤，用户勾谁就只拿谁。
        --   （背包索引由 R.charFilter.allows 内部自愈，外部不再显式重建）
        local function poolFor(mode, rarSet)
            return buildCandidates(s, rarSet, function(nm) return R.charFilter.allows(mode, nm) end)
        end
        R.hwPool = poolFor("halloween", cfg.rarities)
        R.solarPool = poolFor("solar", cfg.solarRarities)
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

--============================================================== 🍬 万圣节糖果自动收集（v316）
-- 需求（用户原话）："新添加了candy，糖果，他会随机刷新在地图上，我希望你能帮我做个自动收集
--   并且你看看有没有什么办法能让脚本在不影响角色位置，也就是不tp到糖果拿他的情况下
--   获取到糖果，这样就可以保证原地钓鱼跟其他东西不受影响了"
--
-- ✅ **做到了：完全不移动角色、不传送、不打断钓鱼。**
--    核心 = `firetouchinterest(糖果, 角色HumanoidRootPart, 0)` 然后 `…, 1)`
--    （0 = 开始触碰，1 = 结束触碰；两次之间要留 ~0.03 秒，否则可能不生效）
--
-- ⚠⚠⚠ 排查踩坑记录（我在这里下过一个**错误结论**，别再走弯路）：
--   · 我第一次测 `firetouchinterest` 得到"无效"的结论，并据此告诉用户"只能传送"。
--     **那是错的** —— 真实原因是**两次调用之间没有 task.wait**，服务端来不及处理。
--     第二次加上等待后一次就成功。教训：**触摸事件要留时间窗口**。
--   · `Remotes.HalloweenPickup` **不是**收集入口 —— 它是**服务端→客户端**的单向通知，
--     只用来播收集音效（HalloweenClient: OnClientEvent + PlayLocalSound）。
--   · `Remotes.HalloweenAction` 也不是 —— 唯一调用方是 `requestAction("Horseman")`，
--     那是无头骑士 NPC 任务对话。
--   · 游戏自带的 `Gamepasses.Effects.AutoCollect`（Id=1713789806）**只管现金**，
--     与糖果无关（用户确认过）。
--   · 用户还提到"以前的脚本能在没买 AutoCollect 时自动收现金" —— 那很可能就是
--     同一个 `firetouchinterest` 原理（现金收集板也是触碰判定）。
--
-- 实测效果：糖果被服务端判定收走，**角色位置零变化**，一次调用约 0.1 秒。
-- 因为不动角色，所以：**不抢 busy 锁、不让钓鱼让路、不与 Solar/喂食/去突变冲突**。
-- 设计：① 默认关闭（cfg.candyEnabled = false），确认后再开；
--       ② 每 candyScanSec 秒扫一次；发现糖果就逐个伪触碰收掉；
--       ③ 每颗之间留间隔，避免触发服务端频率限制。
-- ⚠⚠ 这里**故意不写成 `local function`**：主 chunk 的 local 已经贴到 200 上限，
--   多一个就报 "Out of local registers ... exceeded limit 200" 让整个脚本加载失败
--   （实测踩到过）。挂 R 上既不占 register，也方便外面手动调 `R.candy.tick()`。
R.candyFactory = function()
    local C = { lastScan = 0, log = 0, collected = 0, runs = 0, failed = 0, lastCount = -1 }

    local function list()
        local f = workspace:FindFirstChild("HalloweenCandy")
        if not (f and f:IsA("Folder")) then return {} end
        local t = {}
        for _, c in ipairs(f:GetChildren()) do
            if c:IsA("BasePart") and c.Parent ~= nil then t[#t + 1] = c end
        end
        return t
    end

    function C.count()
        return #list()
    end

    function C.enable(on)
        cfg.candyEnabled = (on == true)
        log(cfg.candyEnabled
            and "🍬 糖果自动收集：已开启（伪触碰收集，**不传送、不影响钓鱼**）"
            or "🍬 糖果自动收集：已关闭")
    end

    -- 对一颗糖果伪触碰（不动角色）。
    -- ⚠⚠ 两个实测关键点：
    --   ① 两次调用之间**必须留 task.wait**（0.03），否则服务端来不及处理 -> 收不掉。
    --      我第一次就是漏了这个，误判"firetouchinterest 无效"并错误地告诉用户只能传送。
    --   ② 结束触碰（1）之后**糖果不会立刻消失** —— 服务端处理 + 复制回来有延迟。
    --      所以判定必须**轮询等一会儿**，不能调用完马上看 Parent。
    --      这就是"明明收上来了日志却说没收掉"的原因（旧代码 touchOne 后只 wait 0.06 就判）。
    local function touchOne(candy, hrp)
        local ok = pcall(function()
            firetouchinterest(candy, hrp, 0)      -- 开始触碰
            task.wait(0.03)                        -- ① 留窗口
            firetouchinterest(candy, hrp, 1)      -- 结束触碰
        end)
        return ok
    end

    -- 等这颗糖果被收走（轮询最多 timeout 秒）。返回 true = 收掉了
    local function waitCollected(candy, folder, timeout)
        local t0 = os.clock()
        local lim = tonumber(timeout) or 1.2
        while os.clock() - t0 < lim do
            if candy.Parent == nil then return true end
            if candy.Parent ~= folder then return true end   -- 被挪走也算收到
            task.wait(0.05)
        end
        return false
    end

    -- 收一轮（**协程里跑，绝不阻塞主循环**）
    local function collectRound()
        local ch = LocalPlayer.Character
        local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if not hrp then C.running = false return end
        local folder = workspace:FindFirstChild("HalloweenCandy")
        local got, tried = 0, 0
        -- 单轮最多收 25 颗，避免极端情况长时间占用
        for _ = 1, 25 do
            local cs = list()
            if #cs == 0 then break end
            local candy = cs[1]
            if not candy then break end
            tried = tried + 1
            touchOne(candy, hrp)
            local ok = waitCollected(candy, folder, 1.2)
            if ok then
                got = got + 1
            else
                -- 没收掉就跳过它，试下一颗（避免死磕同一颗）
                C.failed = (C.failed or 0) + 1
                task.wait(0.1)
                local cs2 = list()
                if #cs2 > 0 and cs2[1] == candy then
                    -- 还是它 -> 说明这颗收不了，本轮结束（防止无限循环）
                    break
                end
            end
            task.wait(0.04)      -- 颗与颗之间留间隔，防频率限制
        end
        C.collected = C.collected + got
        C.runs = C.runs + 1
        C.lastScan = os.clock()
        if got > 0 and (os.clock() - (C.log or 0)) > 3 then
            C.log = os.clock()
            log(string.format("🍬 收到 %d 颗糖果（累计 %d 颗，角色未移动）",
                got, C.collected), Color3.fromRGB(255, 190, 90))
        elseif got == 0 and tried > 0 and (os.clock() - (C.log or 0)) > 20 then
            C.log = os.clock()
            log(string.format("⚠ 收糖：试了 %d 颗都没收掉（可能是距离/频率限制），稍后重试", tried),
                Color3.fromRGB(255, 170, 80))
        end
        C.running = false
    end

    -- 每轮由主循环调用：**只做检查和起协程，立即返回**（不阻塞 UI）
    function C.tick()
        if cfg.candyEnabled ~= true then return end
        if C.running then return end
        local now = os.clock()
        if (now - (C.lastScan or 0)) < (tonumber(cfg.candyScanSec) or 1.5) then return end
        local n = #list()
        if n ~= C.lastCount then
            C.lastCount = n
            if n > 0 then
                log(string.format("🍬 发现 %d 颗糖果 -> 伪触碰收集（不移动角色）", n),
                    Color3.fromRGB(255, 190, 90))
            end
        end
        if n == 0 then C.lastScan = now return end
        -- 起协程去收：立刻返回，UI 和游戏都不受影响
        C.running = true
        task.spawn(function()
            local ok, err = pcall(collectRound)
            if not ok then
                log("⚠ 收糖出错: " .. tostring(err), Color3.fromRGB(255, 120, 120))
                C.running = false
            end
        end)
    end

    return C
end
R.candy = R.candyFactory()

-- 🛡 手动固定名单：永远排在最前且绝不被移除
local function keepCharSet()
    local set = {}
    for piece in tostring(cfg.hotbarKeepChars or ""):gmatch("[^,，]+") do
        local x = piece:match("^%s*(.-)%s*$")
        if x ~= "" then set[x] = true end
    end
    return set
end
local function keyName(k)
    if type(k) ~= "string" then return nil end
    return k:match("^C|([^|]+)|")
end

-- 从 key 里取【突变名】。key 实测格式：C|<名>|<突变>|L<等级>（无突变时写作 C|<名>|L<等级>）
--   ⚠ 必须先把 |L<数字> 去掉，否则 "L240" 会被误当成突变名。
local function keyMutation(k)
    if type(k) ~= "string" or k:sub(1, 2) ~= "C|" then return nil end
    local body = k:match("^C|(.+)$")
    if not body then return nil end
    body = body:gsub("|L%d+$", "")          -- 去掉等级后缀
    local mut = body:match("^[^|]+|(.+)$")  -- 剩下的就是突变
    if mut == nil or mut == "" then return nil end
    return mut
end
R.keyMutation = keyMutation

-- ★★ 失效键判定（v144）★★ —— 这次修的核心
-- 失效键 = 一个 C| 角色键，**它的完整 key 在背包摘要里根本不存在**。
--   含义：这个角色早就不在背包里了（被自动售卖/改名/合成掉了），
--   但游戏的快捷栏布局里还留着这条垃圾记录。
-- 为什么要专门判定它：实测踩到**死循环**——
--   · computeTargetLayout 的保护名单段会把 cur 里的 key 原样 push 回 target，
--     而 protectNewKeys 会把"任何新出现的 key"登记成保护（**失效键也被登记了**，
--     因为判定基准是脚本上次的布局，游戏加进来的失效键当然"不在里面"）；
--   · 于是失效键永远留在 target 里 -> removed 很小 -> 安全阀永远不触发也永远清不掉；
--   · 日志表现为反复"快捷栏清理：发现 N 个失效键" + "拦截了一次大批量删除"，无限重复。
-- 结论：**失效键必须被无条件丢弃**（没有任何可保护的对象），并且不参与"保护/保留"。
local function isDeadKey(k)
    if type(k) ~= "string" or k:sub(1, 2) ~= "C|" then return false end
    -- 背包数据还没就绪时不能判定（否则会把一切都当死的）
    if next(R.summary or {}) == nil then return false end
    return (R.summary or {})[k] == nil
end
R.isDeadKey = isDeadKey
R.keepCharSet = keepCharSet
R.keyName = keyName

-- 🛡 保护机制（一劳永逸解决"右键掏角色被脚本清掉"）
--   实测因果链：① 游戏客户端每钓到白板角色就自动塞进快捷栏（设成 2 项，2 秒后自己涨回 11 项）
--              ② 快捷栏 UI 槽位按布局动态创建 -> 排很后面的角色没槽位、完全看不见
--              ③ 脚本每 hotbarInterval 秒重写布局 -> 你右键塞的角色几秒内被当垃圾清掉
--   做法：新出现且不在脚本目标布局里的 C| key 进入保护名单，在 hotbarProtectSeconds 内
--         绝不移除，并优先占最前面的槽位（保证有槽位显示）。
local function protectNewKeys(cur)
    R.hotbar = R.hotbar or {}
    local prot = R.hotbar.protect
    if type(prot) ~= "table" then prot = {} R.hotbar.protect = prot end
    local mine = {}
    for _, k in ipairs(R.hotbar.layout or {}) do mine[k] = true end
    local now = os.time()
    local dur = tonumber(cfg.hotbarProtectSeconds) or 90
    local added = 0
    -- ⚠⚠ 实测踩到的关键坑（用户反馈："钓鱼钓上来的角色会在快捷栏闪一下（自动售卖会卖掉）"）：
    --   钓上来的角色会**瞬间出现在快捷栏、然后立刻被自动售卖卖掉**。
    --   旧逻辑把这种"闪现"当成"你手动加进来的角色" -> 每次都登记保护并打日志
    --   -> 日志被"检测到快捷栏新增 N 个角色"刷屏（用户截图里每 2~3 秒一条）。
    --   ✅ 对策：要求这个 key【连续出现 candidateChecks 次】才认定它"稳定存在"，
    --      闪现一次就消失的（自动售卖的）永远不会被登记。
    --   另外：游戏"每钓到白板角色就自动塞快捷栏"往往一次加一大批（实测见过 19 个），
    --      而你手动右键通常是一次一个 —— batch 上限仍然保留作为第二道判断。
    local candidateChecks = math.max(2, math.floor(tonumber(cfg.hotbarProtectChecks) or 3))
    R.hotbar._seenCnt = R.hotbar._seenCnt or {}
    local seenCnt = R.hotbar._seenCnt
    -- 先给本轮出现的每个新 key 累加计数
    -- ⚠ 失效键绝不参与（它根本不是有效角色；登记成保护 = 永远清不掉，实测踩到）
    for _, k in ipairs(cur or {}) do
        if type(k) == "string" and k:sub(1, 2) == "C|" and not mine[k] and not prot[k]
            and not isDeadKey(k) then
            seenCnt[k] = (seenCnt[k] or 0) + 1
        end
    end
    -- 清理：本轮没出现的 key 直接丢弃计数（这正是"闪现即消失"被过滤掉的地方）
    local nowSet = {}
    for _, k in ipairs(cur or {}) do nowSet[k] = true end
    for k in pairs(seenCnt) do
        if not nowSet[k] or isDeadKey(k) then seenCnt[k] = nil end
    end
    -- 达到"稳定存在"门槛的才登记保护
    local fresh = {}
    for k, n in pairs(seenCnt) do
        if n >= candidateChecks then fresh[#fresh + 1] = k end
    end
    local maxBatch = math.max(1, math.floor(tonumber(cfg.hotbarProtectMaxBatch) or 3))
    if #fresh > 0 and #fresh <= maxBatch then
        for _, k in ipairs(fresh) do
            prot[k] = now
            seenCnt[k] = nil                 -- 已登记，不必再数
            added = added + 1
        end
    elseif #fresh > maxBatch then
        -- 一大批 = 游戏自动加的（不是你的手动操作）-> 不保护，交给整理流程
        for _, k in ipairs(fresh) do seenCnt[k] = nil end
        R.hotbar.bulkSkipped = (R.hotbar.bulkSkipped or 0) + 1
    end
    for k, t0 in pairs(prot) do
        -- 过期 或 已失效（角色不在背包了）-> 从保护名单剔除
        if (now - (t0 or 0)) > dur or isDeadKey(k) then prot[k] = nil end
    end
    if added > 0 and cfg.hotbarProtectLog ~= false then
        log(string.format("🛡 检测到快捷栏新增 %d 个角色 -> 保护 %d 秒内不被整理掉", added, dur),
            Color3.fromRGB(140, 220, 255))
    end
    return added
end
local function protectedKeys(cur)
    local prot = R.hotbar and R.hotbar.protect
    if type(prot) ~= "table" then return {} end
    local now, dur = os.time(), tonumber(cfg.hotbarProtectSeconds) or 90
    local list = {}
    for _, k in ipairs(cur or {}) do
        if prot[k] and (now - prot[k]) <= dur then list[#list + 1] = { k = k, t = prot[k] } end
    end
    table.sort(list, function(a, b) return a.t > b.t end)
    local res = {}
    for _, e in ipairs(list) do res[#res + 1] = e.k end
    return res
end
R.protectNewKeys = protectNewKeys
R.protectedKeys = protectedKeys

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
    -- ⚠ 实测教训（v117）：以前这里用 hotbarMaxItems 截断，结果脚本每几毫秒
    --   把布局从 13 项删到 12 项、游戏客户端又立刻加回 13 项 ->
    --   形成高频"整理"死循环，把用户右键掏角色的操作全部冲掉。
    --   所以：**数量上限默认禁用（0）**；脚本只做"删该删的（药水/失效键）"，
    --   绝不因为"数量超了"而删任何角色。
    -- ★ 数量上限（v136 恢复为正常生效）★
    -- 历史：v117~v135 期间这里被强制设为 0（不生效），原因是当时"截断"和
    --   "游戏每钓到一条就往快捷栏加一条"会打成高频死循环（日志每秒刷几十条）。
    -- 现在情况变了：脚本剔的是【带突变的项】（确定性规则）而不是"超出数量的项"，
    --   所以恢复上限不会再打架；而无上限会让布局涨到 100+ 项（实测），
    --   既拖慢 UI 又容易让背包<->快捷栏状态机出问题。
    -- 语义：上限只约束"脚本主动补的候选"和"脚本保留的项"，不会因此去删你手动加的
    --   （保护名单与手动固定名单在 push 顺序上最优先，已先占位）。
    local maxItems = math.floor(tonumber(cfg.hotbarMaxItems) or 0)
    if maxItems < 2 then maxItems = 0 end
    local function push(k)
        if type(k) ~= "string" or k == "" or seen[k] then return end
        if maxItems > 0 and #target >= maxItems then return end
        seen[k] = true
        target[#target + 1] = k
    end

    -- ★★★ 关键修复（v119）：按【角色名】把快捷栏里的旧键"升级"成背包里的新键 ★★★
    -- 实测踩到的坑：角色的突变/后缀一变，键就变（例：C|Ria Gramera| -> C|Ria Gramera II|；
    --   C|Ania|Party -> C|Ania|）。旧逻辑用**键**做精确比较，于是把同名角色当成"失效条目"删掉，
    --   一次能删十几项——用户看到的就是"我手动加的角色全被脚本吃掉了"。
    -- 正确做法：同名就**更新键**（保留在快捷栏里），只有名字在背包里**完全找不到**时才算失效。
    -- ⚠ 注意：R.summary 是【字典】（键 = 角色完整 key），不是数组！不能用 ipairs 遍历
    --   （用 ipairs 会得到空表，导致同名键升级永远不生效、又退化成"误删"）。
    -- ⚠⚠ 规则（用户明确要求）：**快捷栏里带突变的角色一律移出去（= 存入背包）**。
    --   原因：实测游戏客户端"每钓到角色就自动塞进快捷栏"，其中带突变的会一直在里面；
    --   而脚本旧逻辑只"不主动添加"突变角色，**从不主动移除已在里面的** ——
    --   表现就是用户看到的"某个角色的岩浆/史莱姆突变一直在快捷栏和背包之间互切"。
    --   判定：key 里 C|<名>|<突变>|L<等级> 的 <突变> 非空，且该突变不在保留名单里 -> 移除。
    --   例外：hotbarKeepMutations 里显式保留的突变不移除（默认空）。
    local keepMut = {}
    for piece in tostring(cfg.hotbarKeepMutations or ""):gmatch("[^,，]+") do
        local x = piece:match("^%s*(.-)%s*$")
        if x ~= "" then keepMut[x] = true end
    end

    local keyByName = {}
    for k2, v2 in pairs(R.summary or {}) do
        if type(k2) == "string" and type(v2) == "table" then
            local nm2 = tostring(v2.n or "")
            -- 同一名字有多个（不同后缀）时，优先保留"干净"的那个（ty 为空）
            if nm2 ~= "" then
                local prev = keyByName[nm2]
                if prev == nil or tostring(v2.ty or "") == "" then
                    keyByName[nm2] = k2
                end
            end
        end
    end
    local potionSet = {}
    local kept = {}
    R.hotbar.mutRemoved = 0
    for _, k in ipairs(cur or {}) do
        -- ★ 带突变的角色 -> 移出快捷栏（存入背包），不满足条件的才继续保留
        local mut = keyMutation(k)
        -- ★★★ v338：**品质没勾选的角色也移出**（用户需求 2026-10-11）★★★
        --   用户原话：「我明明没有在任何功能勾选cele品质了，整理物品栏怎么还是把cele拿上来？」
        --   根因：原来的剔除规则只有三条 —— 带突变 / 药水 / 失效键；
        --     **一个干净、还在背包里的角色，哪怕品质根本没被勾选，也会被一直保留**。
        --     （实测：取消 Celestial 后，快捷栏里仍留着 5 个 Celestial：
        --       Blayra / Flara Scarlette / Rami Scarlette / Nazira II / Madoki Kaneme。）
        --   现在：角色的品质不在【候选池同一套】cfg.rarities 里 -> 移出快捷栏。
        --   ⚠ 用 cfg.rarities 而不是别的集合：快捷栏的填充源就是 refreshCandidates() 的
        --     候选池，两者必须同一套标准，否则"补上来又踢下去"会来回打架。
        --   ⚠ 查不到品质的角色（rar0 == nil）**不动**，避免误删。
        local nm0 = keyName(k)
        local rar0 = nm0 and R.charFilter and R.charFilter.nameRarity and R.charFilter.nameRarity[nm0] or nil
        local rarBad = (nm0 ~= nil) and (rar0 ~= nil) and ((cfg.rarities or {})[rar0] ~= true)
        if cfg.hotbarEvictMutated ~= false and mut ~= nil and not keepMut[mut] then
            R.hotbar.mutRemoved = (R.hotbar.mutRemoved or 0) + 1
            R.hotbar.lastMutOut = k
        elseif cfg.hotbarEvictUncheckedRarity ~= false and rarBad then
            R.hotbar.rarRemoved = (R.hotbar.rarRemoved or 0) + 1
            R.hotbar.lastRarOut = k
        elseif not (cfg.autoStorePotions and isPotionKey(k)) then
            local nm = keyName(k)
            local newKey = nm and keyByName[nm]
            if newKey and newKey ~= k then
                -- 同名但键变了（突变/后缀变化）-> 用新键替换，**保留在快捷栏**
                kept[#kept + 1] = newKey
                R.hotbar.keyUpgraded = (R.hotbar.keyUpgraded or 0) + 1
            elseif isDeadKey(k) then
                -- ★ 失效键：角色已不在背包 -> 丢弃（不要在快捷栏里留垃圾）
                R.hotbar.deadDropped = (R.hotbar.deadDropped or 0) + 1
            else
                kept[#kept + 1] = k
            end
        end
    end
    -- 兜底：背包数据没就绪时一律原样保留（绝不误删）
    --   ⚠ 注意用 isDeadKey 而不是"keyByName 为空"做判据：后者在
    --     "背包有数据但某个名字查不到"时不会触发，正是失效键漏网的原因之一。
    if next(R.summary or {}) == nil then
        kept = {}
        for _, k in ipairs(cur or {}) do kept[#kept + 1] = k end
        R.hotbar._noSummaryKeep = true
    else
        R.hotbar._noSummaryKeep = false
    end

    -- 🛡 保护期内的 key 最优先（你刚右键加进来的）
    -- ⚠ 必须过滤失效键：protectNewKeys 会把"游戏加进来但不在脚本上次布局里"的键
    --   也登记成保护，**失效键因此混进保护名单**，然后被 push 回 target -> 永远清不掉。
    for _, k in ipairs(protectedKeys(cur)) do
        if not isDeadKey(k) then push(k) end
    end
    -- 🛡 手动固定名单次优先
    local keepSet = keepCharSet()
    if next(keepSet) then
        for _, k in ipairs(cur or {}) do
            local nm = keyName(k)
            if nm and keepSet[nm] and not isDeadKey(k) then push(k) end
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

-- 接管客户端快捷栏状态：只清掉药水的"用户插入"标记
--
-- ⚠⚠⚠ 血泪教训（用户实测："右键掏角色只有偶尔两个能成功、其它全卡住"）：
--   **绝对不要设置 `_G.__BP_SavedLayoutApplied = true`！**
--   游戏 BackpackClientService 里两个函数这样配合：
--     queueSaveLayout()          -- 玩家改动布局时调用
--         if os.clock() < (_G.__BP_HotbarLayoutSaveReadyAt or 0) then
--             _G.__BP_HotbarLayoutSavePending = true; return    -- 只挂起，不发送！
--         end
--     applySavedLayoutIfNeeded() -- 唯一会把 ReadyAt 归零的地方
--         if _G.__BP_SavedLayoutApplied then return end   -- ← 我们设 true 就永远进不来
--         ...
--         if os.clock() > (_G.__BP_SavedLayoutDeadline or 0) then
--             _G.__BP_SavedLayoutApplied = true
--             _G.__BP_HotbarLayoutSaveReadyAt = 0        -- ← 唯一解锁保存的地方
--         end
--   一旦置 true，游戏再也不会把 SaveReadyAt 归零 →
--   **玩家自己的所有布局改动被静默挂起、永不发送**（偶尔撞上窗口期才成功一两个）。
-- ✅ 正确做法：不碰这两个全局，只清药水标记；并主动把可能存在的脏节流解锁。
local function takeoverHotbarClientState()
    local ui = _G.__BP_UserInserted
    if type(ui) == "table" then
        for k in pairs(ui) do
            if isPotionKey(k) then ui[k] = nil end
        end
    end
    -- 解锁可能被卡死的布局保存（我们的旧版本或别的脚本可能留下过脏标志）
    if _G.__BP_SavedLayoutApplied == true or (_G.__BP_HotbarLayoutSaveReadyAt or 0) > os.clock() then
        _G.__BP_SavedLayoutApplied = nil
        _G.__BP_HotbarLayoutSaveReadyAt = 0
        _G.__BP_SavedLayoutDeadline = 0
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

--============================================================== 客户端插入函数接管 —— 已废弃
-- ⚠⚠⚠ 严重历史 bug：**不要在这里装任何 wrapper！**
--   旧写法把 _G.__BP_InsertKeyIfHotbarSpace / __BP_ForceKeyIntoHotbar 包一层来拦药水，
--   但每次脚本重载都会再包一层，而"原始函数"其实是上个实例留下的 wrapper：
--     wrapper → wrapper → … 无限套娃 → stack overflow
--   而**角色插入正好走这两个函数** -> 右键从背包掏角色直接崩（游戏弹"已移动至快捷栏！"但角色进不去）。
--   这两个全局在游戏客户端里**根本不是它自己定义的**，清掉不破坏任何游戏逻辑。
-- ✅ 药水拦截改由本来就在生效的两条路完成：
--   ① disablePotionInsertHandler()（getconnections 禁用客户端 PotionHotbarInsert 连接）
--   ② hotbarSelfCheck()（周期性读服务器布局，发现药水立刻纠正）
local BLOCKER_REG = _G.__HW_POTION_BLOCKERS
if type(BLOCKER_REG) ~= "table" then BLOCKER_REG = {} _G.__HW_POTION_BLOCKERS = BLOCKER_REG end
R.clientHooks = { insert = nil, force = nil }

local function isOurBlocker(f)
    if type(f) ~= "function" then return false end
    local marked = false
    pcall(function() marked = rawget(f, "_HW_POTION_BLOCKER") == true end)
    if marked then return true end
    if BLOCKER_REG[f] then return true end
    local hit = false
    pcall(function()
        local ks = debug.getconstants and debug.getconstants(f)
        if type(ks) == "table" then
            local a, b = false, false
            for _, c in ipairs(ks) do
                if c == "autoStorePotions" then a = true end
                if c == "type" then b = true end
            end
            hit = a and b
        end
    end)
    return hit
end
R.isOurPotionBlocker = isOurBlocker

local function purgeLegacyBlockers()
    local purged = 0
    for _, name in ipairs({ "__BP_InsertKeyIfHotbarSpace", "__BP_ForceKeyIntoHotbar" }) do
        local f = _G[name]
        if type(f) == "function" and isOurBlocker(f) then
            _G[name] = nil
            BLOCKER_REG[f] = nil
            purged = purged + 1
        end
    end
    if purged > 0 then
        for k in pairs(BLOCKER_REG) do BLOCKER_REG[k] = nil end
        log("🧹 清掉了 " .. purged .. " 个历史遗留的插入钩子（套娃递归会让角色塞不进快捷栏）",
            Color3.fromRGB(255, 200, 90))
    end
    return purged
end
R.purgeLegacyBlockers = purgeLegacyBlockers
local function takeoverClientInsertHooks() end
local function restoreClientInsertHooks() R.clientHooks = { insert = nil, force = nil } end
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
        -- ★ 让路期间必须保证游戏的布局保存是通的，否则你手动整理快捷栏会全部无效
        _G.__BP_SavedLayoutApplied = nil
        _G.__BP_HotbarLayoutSaveReadyAt = 0
        _G.__BP_SavedLayoutDeadline = 0
        setPotionConnEnabled(true)      -- 让路中，保持游戏默认行为
        return
    end
    local now = os.clock()
    -- ⚠ force 不再绕过间隔控制：以前 buildUI 里的回调会连续触发 manageHotbar(true)，
    --   造成每秒几十次重写（日志里刷屏"快捷栏整理: 13 -> 12 项"）。
    --   现在强制的最小间隔 = 1 秒，保证任何情况下都不会高频写快捷栏。
    local minGap = 1
    if (now - (R.hotbar.lastFire or 0)) < minGap then return end
    if not force and (now - (R.hotbar.lastFire or 0)) < (tonumber(cfg.hotbarInterval) or 3) then return end
    if not cfg.autoStorePotions and not cfg.autoFillCandidates then return end

    takeoverClientInsertHooks()
    disablePotionInsertHandler()

    local cur = getLayout()
    if not cur then return end
    -- 🛡 先登记保护（你刚右键加进来的角色），否则下一步就会把它裁掉
    pcall(protectNewKeys, cur)
    -- 🛠 卡住自检：失效键反复清不掉就主动重新同步（修"最后一格卡在背包"）
    pcall(function()
        local tgt = computeTargetLayout(cur, R.candidates, false)
        hotbarRecoverStuck(cur, tgt)
    end)
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

    -- ★★★ 关键设计（v116，用户实测反馈后重构）★★★
    -- 历史教训：旧版这里**无条件**把整个快捷栏重写成脚本的候选表，
    -- 导致"右键从背包掏角色"刚塞进去就被下一次重写删掉（用户体感：随机偶尔只能成功一两个）。
    -- 用户实测确认：脚本完全不干预时右键收进拿出毫无问题。
    --
    -- ✅ 现在的策略 —— **外科手术式**，只在"确实有事要做"时才写，而且尽量只做减法：
    --   · 收回失效条目（角色被洗掉/换键后留在快捷栏的旧键 = 你说的"自动收回突变角色"）
    --   · 收走药水（autoStorePotions 开启时）
    --   · 补候选（autoFillCandidates 开启时）
    --   其余一切（你手动加的角色、鱼竿、脚本不认识的键）**原样保留**。
    --   若这一轮没有任何该删/该加的东西 -> **一个字节都不写**，你随便右键。
    local removed, added = 0, 0
    do
        local curSet, tgtSet = {}, {}
        for _, k in ipairs(cur) do curSet[k] = true end
        for _, k in ipairs(target) do tgtSet[k] = true end
        for _, k in ipairs(cur) do if not tgtSet[k] then removed = removed + 1 end end
        for _, k in ipairs(target) do if not curSet[k] then added = added + 1 end end
    end

    R.hotbar.lastTarget = target
    R.hotbar.liveCount = #cur
    R.hotbar.lastRemoved, R.hotbar.lastAdded = removed, added

    -- ★ 安全阀（防呆）：一次要删掉 5 项以上，几乎肯定是判定逻辑出问题（历史上真的发生过：
    --   因为突变改名导致同名角色被误判为失效，一次删掉 13 项）。
    --   这种情况**宁可不写**，并把详情记下来让你能看到，也不要清空你的快捷栏。
    -- ★ 安全阀改造：区分【确定性剔除】与【意外删除】
    --   · 确定性剔除（带突变的角色移出、药水收起）是**规则驱动、不会误判**的 —— 应当放行，
    --     否则用户实测的场景（布局里堆了 42 个突变角色）永远清不干净。
    --   · 其余"说不出原因"的删除才受 hotbarMaxRemovePerPass 限制（防误删用户手动加的）。
    -- ★ 安全阀自己直接判断"被删的是不是失效键"（不再依赖中间变量，避免时序对不上）
    --   失效键 = 该 C| 键的 key 在背包摘要里**完全不存在** -> 角色早就不在背包了，纯垃圾。
    --   这类删除是【确定性】的，必须放行，否则会陷入
    --   "清理发现失效键 -> 安全阀拦截 -> 下一轮又发现同样的失效键" 的死循环（实测踩到）。
    -- ⚠ 统计口径修正（v143）：以前只数"本轮被删且失效"的，但失效键是**常驻**的
    --   （它们不在背包摘要里，computeTargetLayout 又因保护名单把它们放回 target），
    --   所以每轮的 diff 只有 1~2 个 -> 安全阀一直卡在 4~6 的上限 -> 永远清不干净。
    --   改成：直接数【当前布局里所有失效的 C| 键】，把它们全部计入放行额度。
    -- 失效键放行额度 = 当前布局里所有失效的 C| 键数量（它们**必须**被删干净）
    local deadInRemoval = 0
    do
        for _, k in ipairs(cur) do
            if isDeadKey(k) then deadInRemoval = deadInRemoval + 1 end
        end
    end
    R.hotbar.deadInRemoval = deadInRemoval
    local detRemoved = (R.hotbar.mutRemoved or 0) + deadInRemoval + (R.hotbar.deadRemoved or 0)
    local maxRemovable = math.max(1, math.floor(tonumber(cfg.hotbarMaxRemovePerPass) or 4)) + detRemoved
    if removed > maxRemovable then
        R.hotbar.blockedBulk = (R.hotbar.blockedBulk or 0) + 1
        R.hotbar.blockedBulkInfo = string.format("本轮想删 %d 项（上限 %d）已拦截", removed, maxRemovable)
        if (R.hotbar.blockedBulk or 0) <= 3 then
            log(string.format("🛡 拦截了一次大批量删除（想删 %d 项，上限 %d）—— 为保护你的快捷栏，本轮不改动",
                removed, maxRemovable), Color3.fromRGB(255, 200, 90))
        end
        R.hotbar.layout = cur
        return
    end

    -- 没有任何该删/该加的 -> 完全不动（这是"你的右键能正常工作"的关键）
    if removed == 0 and added == 0 then
        R.hotbar.layout = cur          -- 以服务器真实布局为基准，避免下次误判
        return
    end

    R.hotbar.layout = target
    setLayout(target)
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
-- ⚠⚠⚠ 实测协议（从游戏客户端脚本 Events/EclipseCorruptionClient 等逆出）：
--   TypeEventState.OnClientEvent 的载荷字段是：
--     · kind      = "Started" | "Ended" | "Phase" | "PhaseFx"
--                   | "AdminCorrupt" | "AdminCorruptEnd" | "DreamEndWash"
--     · eventName = "Halloween" | "Eclipse" | "Solar" | ... （事件名）
--   ⚠ **没有** `active` 字段，也不一定有 `remaining`。
--   ❌ 旧代码写的是 `tostring(t.kind) ~= "End"` —— **游戏根本不用 "End" 这个值**（用的是 "Ended"），
--      所以这个不等式**永远为真** -> 事件结束后 active 仍被算成 true、name 保留旧值不重置。
--      后果：R.event.active 与 R.event.name 变成**永久粘住的陈旧状态**，
--      依赖它们的判断（isHalloween / 去突变让路 / 喂食让路）全部基于错误前提。
--   ✅ 现在：显式按 kind 白名单判定"事件进行中"。
-- 事件状态判定（按 kind）：返回 true=进行中 / false=已结束 / nil=未知
local function eventKindActive(kind)
    -- 进行中：Started/Phase/PhaseFx/AdminCorrupt，以及 **Tick**
    --   ⚠ Tick 是实测抓到的（诊断日志：`kind=Tick · eventName=Solar remaining=28
    --     timeText=Event Duration: 0:28`）—— 事件进行中每帧/每秒的周期推送。
    --     漏掉它会让 Solar 的首次激活依赖 remaining 兜底（虽然能work，但语义不明确）。
    if kind == "Started" or kind == "Tick" or kind == "Phase" or kind == "PhaseFx"
        or kind == "AdminCorrupt" then
        return true
    end
    if kind == "Ended" or kind == "AdminCorruptEnd" or kind == "DreamEndWash" then
        return false
    end
    return nil
end

local function updateEventFromTable(t)
    if type(t) ~= "table" then return end
    -- 🔍 诊断日志：把事件上报的原始载荷打出来（只在 kind 变化时打一次，不会刷屏）
    --    这样万圣节真来了就能从日志确认字段是否如预期。
    do
        local k = tostring(t.kind or "")
        if k ~= "" and k ~= R._lastEventKind then
            R._lastEventKind = k
            local parts = {}
            for kk, vv in pairs(t) do
                if type(vv) ~= "table" then parts[#parts + 1] = kk .. "=" .. tostring(vv) end
            end
            table.sort(parts)
            log("🔍 事件上报 kind=" .. k .. " · " .. table.concat(parts, " "):sub(1, 160),
                Color3.fromRGB(150, 200, 255))
        end
    end
    local name = t.eventName and tostring(t.eventName) or nil
    local kind = t.kind and tostring(t.kind) or nil
    local remaining = tonumber(t.remaining)
    local active = t.active
    if active == nil then
        if kind ~= nil then
            -- ★ 优先按 kind 判定（这是游戏的权威协议）
            local ka = eventKindActive(kind)
            if ka ~= nil then
                active = ka
            elseif remaining ~= nil then
                active = remaining > 0
            else
                active = false
            end
        elseif remaining ~= nil then
            active = remaining > 0
        else
            active = false
        end
    end
    -- 事件结束时必须把 name 一起清掉，否则会留下"陈旧事件名"粘住所有判断
    if active ~= true then name = nil end
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

-- 天降类活动（掉落物砸中手持角色 -> 突变）。
--   Solar：陨石 Meteorite，FallSpeed=50，ImpactRadius=50，每 5 秒一颗
--          目标突变：Mars(6x) / Lava(2x) / Honey / Gold(1.25x) / Solar
--
-- ⚠⚠⚠ v324 致命 bug 修复：**Heaven（天堂碰撞）已从这里移除**。
--   旧写法 `{ Solar = true, Heaven = true }` 把 Heaven 归进 Solar 家族，于是只要
--   `cfg.solarEnabled = true`，Heaven 一来整个 Solar 模块就启动：
--   手持角色 -> 传送到流星落点 -> 落地判定突变 —— **把角色拉进用户根本没选的活动**。
--   实盘证据（Heaven 进行中实测）：R.solar.meteors=2 / R.solar.tp=2（角色被传送 2 次）
--   / R.solar.hits=0（没烧成突变）；用户在 os.clock=989 手动关闭 Solar 才止住
--   （_relLog: "989.0 Solar 已停用"）。
--
--   为什么是"移除"而不是"合并"：**两者突变池不同**（实测 Constants.TypeEvents.Events）：
--     Solar  -> Blood/Mars/Lava/Honey/Gold/Solar（Boosts 逐类型指定）
--     Heaven -> Angelic(天使 6x) / Gold(1.25x)——Ui.EventDesc 原文：
--               "Falling Stars can turn Held Characters ANGELIC or GOLD"
--               外加**全 20 种突变类型 ×2 全局加成** + 宝石掉落
--   ⇒ 合并 = 拿 Solar 的判定表去判 Heaven 的落地，而用户没有任何 Heaven 开关可选。
--
--   现在行为：Heaven 期间 isSolar() = false -> Solar 模块不启动，主循环走
--   "非万圣节分支"按既有安全策略**主动放手**（不手持、不传送）。
--   ⚠ 代价（用户已知情并选择）：Heaven 期间**不会**自动突变。
--     以后若要支持，做法是给 Heaven 单开板块（SESSION_HANDOFF.md 十五章方案 B），
--     且**必须保持 Heaven 不在 FALL_EVENTS 里**，否则 isSolar() 又变 true，
--     且主循环的 Heaven 分支要排在 Solar 之前。
--   ⚠ Heaven 机制实测参数（做方案 B 直接用，别重测）：
--     Durations {1=300}（300 秒，比 Solar 的 90/120/180 长）
--     Stars   {FallSpeed=190, SpawnEverySeconds=10, SpawnHeight=150, SpawnRadius=200}
--     Impact  {SummonEverySeconds=7.5, SpawnRadius=35, ActiveSeconds=7,
--              CleanupBufferSeconds=10}  ← **Solar 没有这个机制**，照抄会漏掉
--     Gem     {SpawnEverySeconds=3, RewardGems=100, MaxAlive=100, LifetimeSeconds=420}
--     Summoned{LifetimeSeconds=60, MaxRarity=Mythical}
HW_K.FALL_EVENTS = { Solar = true }
local function fallEventName()
    if not (R.event.active and R.event.name) then return nil end
    if not HW_K.FALL_EVENTS[R.event.name] then return nil end
    if eventRemaining() <= 0 then return nil end
    return R.event.name
end

local function isSolar()
    -- ⚠ 强制测试时同样要让位于真实事件（绝不为测试把角色暴露在真实突变里）
    if R._force and os.clock() < (R._force.until_ or 0) then
        if R.event.active and R.event.name and not HW_K.FALL_EVENTS[R.event.name] and eventRemaining() > 0 then
            return false
        end
        -- ⚠ v324：Heaven 已不属于天降家族，强制测试也只认 Solar ——
        --   否则 debugForceEvent("Heaven") 会把 Solar 模块当 Heaven 跑，
        --   又变成"用 Solar 的判定表判 Heaven 的落地"。
        return R._force.name == "Solar"
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
-- 🛠 快捷栏"卡住"自动恢复（用户实测：反复放手的副作用会把最后一格物品卡在背包出不回来）
-- 判据：某个键连续 stuckLimit 次都还在服务器布局里，但**不在背包摘要里**（= 失效键）。
--   正常情况失效键下一轮就该被清掉（因为不在 target 里）；一直清不掉 = 状态机卡住了。
-- 对策：主动 setLayout(target) + clientApplyLayout(target) 强制重新同步一次。
--   ⚠ 只对"已经算出来的 target"做重推，不额外删任何东西 —— 是恢复，不是清理。
local function hotbarRecoverStuck(cur, target)
    if type(cur) ~= "table" or type(target) ~= "table" then return false end
    local inBag, inTarget = {}, {}
    for k in pairs(R.summary or {}) do inBag[k] = true end
    for _, k in ipairs(target) do inTarget[k] = true end
    -- ⚠ 改成按【失效键数量】判定（用户实测：布局 19 项里 15 个是失效键，
    --   UI 只显示 4 个槽位 —— 这些看不见的僵尸键既占位置又容易让状态机卡住）。
    --   原来按"某个特定 key 连续 N 次"判定，失效键一多就会互相顶掉计数，永远达不到门槛。
    local dead, bad = 0, nil
    local deadSet = {}
    for _, k in ipairs(cur) do
        if type(k) == "string" and k:sub(1, 2) == "C|" and not inBag[k] then
            dead = dead + 1
            deadSet[k] = true
            if bad == nil then bad = k end
        end
    end
    -- 从 target 里剔除失效键（必须在任何早返回之前做，保证下面的 setLayout 真的能删掉它们）
    if dead > 0 then
        local filtered = {}
        for _, k in ipairs(target) do
            if not deadSet[k] then filtered[#filtered + 1] = k end
        end
        target = filtered
        R.hotbar.deadRemoved = dead
    else
        R.hotbar.deadRemoved = 0
    end
    local deadLimit = math.max(1, math.floor(tonumber(cfg.hotbarStuckLimit) or 4))
    if dead == 0 then
        R.hotbar._stuckKey, R.hotbar._stuckCount = nil, nil
        return false
    end
    -- ★★ 关键修复（v141）★★
    -- 实测踩到的死循环：这些失效键**真的不在背包里**（名字都查不到），但一直清不掉：
    --   清理发现失效键 -> 重新同步 setLayout(target) —— 可 **target 里仍然包含它们**！
    --   因为 computeTargetLayout 的保护名单/固定名单段会把 cur 里的失效键照原样 push 回 target。
    --   于是"重新同步"实际什么都没删 -> 下一轮又发现同样的失效键 -> 无限重复
    --   （实测日志：`卡住恢复 3 次 · 被拦截 5 次`，布局一直停在 13 项、其中 10 项是死的）。
    -- 对策：**在恢复用的 target 里显式剔除所有失效的 C| 键**（它们不在背包 = 毫无用处），
    --   并把数量记到 R.hotbar.deadRemoved，供安全阀放行。
    if dead >= deadLimit then
        R.hotbar._lastDead = dead
    elseif R.hotbar._stuckKey == bad then
        R.hotbar._stuckCount = (R.hotbar._stuckCount or 0) + 1
    else
        R.hotbar._stuckKey, R.hotbar._stuckCount = bad, 1
    end
    local limit = math.max(2, math.floor(tonumber(cfg.hotbarStuckLimit) or 4))
    if R.hotbar._stuckCount >= limit or dead >= deadLimit then
        setLayout(target)
        clientApplyLayout(target)
        R.hotbar.stuckRecover = (R.hotbar.stuckRecover or 0) + 1
        R.hotbar._stuckKey, R.hotbar._stuckCount = nil, nil
        log(string.format("🛠 快捷栏清理：剔除 %d 个失效键（角色已不在背包，键留在快捷栏里是垃圾）",
            dead), Color3.fromRGB(255, 200, 90))
        return true
    end
    return false
end

local function hotbarTick()
    if manualActive() then
        setPotionConnEnabled(true)
        return
    end
    takeoverClientInsertHooks()
    hookHotbarSlots()
    -- 🛠 卡住/僵尸键清理：**必须放在 manageHotbar 之外**！
    --   实测踩到：manageHotbar 在 autoStorePotions 与 autoFillCandidates 都为 false 时会
    --   提前 return，导致里面的卡住自检**永远不执行** —— 布局里堆了 15 个失效键没人管。
    do
        local c0 = getLayout()
        if c0 ~= nil then
            local tgt0 = computeTargetLayout(c0, R.candidates, false)
            pcall(hotbarRecoverStuck, c0, tgt0)
        end
    end
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
local feedTick          -- 🍖 与 washTick 同一模式：local 前向声明 + 模块里后置赋值
local feedPreviewList   -- 🍖 同上（UI 与刷新线程使用）
local feedExecute       -- 🍖 批次执行函数

--============================================================== 🔬 主循环性能剖析（v319）
-- 用途：用户反馈"脚本会导致卡顿"，但把 R 上导出的函数逐个计时都**找不到热点**
--   （实测：candy.tick 0.1ms / charFilter.refreshUI 203ms 累计 / allows 0.4ms/秒）。
--   因为主循环里真正的大头是**模块内部的 local 函数**（washTick/feedTick/fishTick/
--   solarTick/hotbarTick/refreshCandidates），它们没挂在 R 上，外面测不到。
--   ⇒ 直接把计时器插到 tick() 里面，用 `R.perfReport()` 拿结果。
--   用法：玩一会儿（要包含卡顿的时候），然后调 R.perfReport() 看谁累计/最差最高。
R.perf = R.perf or {
    run = 0, since = 0,
    name = {}, sum = {}, worst = {}, cnt = {}, over = {},
}
-- ⚠⚠ 这里**不能写成 `local function perfWrap`**：顶层 local 已经贴到 200 上限，
--   多一个就报 "Out of local registers ... exceeded limit 200" 让整个脚本加载失败
--   （实测踩到过好几次）。挂进 R.perf 表里当字段，不占 local 额度。
R.perf.wrap = function(label, fn)
    if type(fn) ~= "function" then return fn end
    return function(...)
        local t0 = os.clock()
        local a, b, c, d = fn(...)
        local dt = os.clock() - t0
        local P = R.perf
        P.name[label] = true
        P.sum[label] = (P.sum[label] or 0) + dt
        P.cnt[label] = (P.cnt[label] or 0) + 1
        if dt > (P.worst[label] or 0) then P.worst[label] = dt end
        if dt >= 0.05 then P.over[label] = (P.over[label] or 0) + 1 end
        return a, b, c, d
    end
end
-- 报告：按累计耗时降序
R.perfReport = function(reset)
    local P = R.perf
    if not P or not P.name then return {} end
    local el = (os.clock() - (P.since or os.clock()))
    local rows = {}
    for k in pairs(P.name) do
        rows[#rows + 1] = {
            name = k,
            sum = P.sum[k] or 0,
            cnt = P.cnt[k] or 0,
            worst = P.worst[k] or 0,
            over = P.over[k] or 0,
        }
    end
    table.sort(rows, function(a, b) return a.sum > b.sum end)
    local txt = {}
    txt[#txt + 1] = string.format("=== 主循环性能剖析（%.0f 秒）===", el)
    txt[#txt + 1] = string.format("%-18s %10s %8s %10s %8s %8s", "模块", "累计ms", "次数", "平均ms", "最差ms", ">50ms")
    for _, r in ipairs(rows) do
        txt[#txt + 1] = string.format("%-18s %10.1f %8d %10.3f %8.1f %8d",
            r.name, r.sum * 1000, r.cnt,
            r.cnt > 0 and (r.sum / r.cnt * 1000) or 0, r.worst * 1000, r.over)
    end
    if reset then
        P.name, P.sum, P.worst, P.cnt, P.over = {}, {}, {}, {}, {}
        P.since = os.clock()
    end
    return table.concat(txt, "\n")
end
if not R.perf.since or R.perf.since == 0 then R.perf.since = os.clock() end

local function tick()
    local now = os.clock()
    -- 🔬 v319：给最可疑的两个模块计时（其余模块开销可忽略，不必占 local 额度）。
    --   这些是**模块内部的 local 函数**，没挂在 R 上，从外面根本测不到 ——
    --   这就是之前"逐个测 R 上的函数都找不到热点"的原因。
    --   ⚠⚠ 这里**只能包 2 个**：tick 的局部额度极紧，包 6 个会直接报
    --     "Out of local registers ... exceeded limit 200"（实测踩到）。
    local PW = R.perf and R.perf.wrap
    local washTick = PW and PW("washTick", washTick) or washTick
    local feedTick = PW and PW("feedTick", feedTick) or feedTick
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
                R.hw = R.hw or { events = 0, holdSeconds = 0, lastTick = 0 }
                R.hw.events = (R.hw.events or 0) + 1
                log(string.format("▶ 万圣节自动突变开始（第 %d 次）· 累计已判定 %d 次 · 概率上应命中 %.2f 个",
                    R.hw.events, R.hw.rolls or 0, R.hw.expected or 0), Color3.fromRGB(255, 180, 90))
            elseif mode == "idle" then
                log("▶ 模式切换 -> 待机（当前不是目标事件，不手持）", Color3.fromRGB(160, 160, 180))
            end
        end
    end

    -- ===== Solar 活动最高优先级：陨石雨机制完全不同，接管一切 =====
    -- （Solar 与万圣节是互斥事件，不会同时存在，所以这里直接 return 是安全的）
    if cfg.solarEnabled and isSolar() then
        -- 🚦 **原子占位**（v147）：Solar 要【手持角色 + 传送】，必须先抢到"角色位置占用权"。
        --   旧写法是无条件 solarStart() —— 如果这时喂食正在跑（v139 之后活动期间也会喂），
        --   Solar 会直接把角色手持槽位抢走，两边互相打断。
        --   现在：抢不到就这一轮不启动（喂食做完自然会让出来），并且不打断已在跑的喂食。
        if not (R.solar and R.solar.active) then
            local whoS = R.busyWho()
            if whoS == nil or whoS == "Solar" then
                if R.busySuggest("Solar", "Solar 陨石雨") then
                    solarStart()
                end
            elseif not R._solarWaitLogged then
                R._solarWaitLogged = true
                log("⏸ Solar 等待：" .. R.yieldLabel(whoS) .. " 正在使用角色位置，等它做完再进陨石模式",
                    Color3.fromRGB(255, 200, 90))
            end
        end
        local okS, errS = pcall(solarTick)
        if not okS then
            log("Solar 出错: " .. tostring(errS), Color3.fromRGB(255, 120, 120))
        end
        hotbarTick()
        return
    elseif R.solar and R.solar.active then
        solarStop("事件结束")
    end

    -- ===== 去突变（Depolarizer）：只在【没有任何活动】时工作 =====
    -- （有事件时必须让路：否则"事件放手策略"会和我们抢角色，且带突变角色可能被二次突变）
    -- 🛒 自动购买 / 领取 / 转盘 / 重生（v340）
    --   ⚠ 放在 wash 段之前：购买/领取是纯界面点击，不占角色位置，可以和其它模块并行
    if R.autoTick then pcall(R.autoTick) end

    if cfg.washEnabled and not (R.event.active and R.event.name and eventRemaining() > 0) then
        local okW, errW = pcall(washTick)
        if not okW then
            if (now - (R._lastWashErr or 0)) > 10 then
                R._lastWashErr = now
                log("去突变出错: " .. tostring(errW), Color3.fromRGB(255, 120, 120))
            end
        end
    end

    -- ===== 🎯 自动配置角色：按间隔重算 + 攒够食物就换人（用户最初的设想）=====
    --
    -- ★★★ 顺序：换人**排在喂食之前**（用户明确要求，2026-10 改）★★★
    --   用户原话："现在先换，攒食物之后再说"
    --   理由（很重要）：**换人提升的是"初始CPS"这个乘数因子** ——
    --     它把整个台子的长期天花板抬上去，后续喂食的每一级都受益；
    --     而喂食现有角色只是线性加等级，天花板没变。
    --   所以换人优先于喂食，收益是**乘法级**的。
    --   ⚠ 旧顺序是喂食优先（当时担心"换人吃光食物导致不喂食"），
    --     那个担忧现在由 `R.feedBudgetCap()` 的**食物预留**机制解决了：
    --     换人只花它自己预算内的那份，剩下的仍归喂食，两边都不饿死。
    --
    -- ⚠⚠ 必须通过 `R.astAutoTick` 调用，不能直接写 `AST.autoTick` —— `local AST`
    --   声明在文件后段，tick 闭包捕获不到，会解析成全局 nil（每轮刷屏报错）。
    do
        local fnAuto = R.astAutoTick
        if type(fnAuto) == "function" then
            local okA, errA = pcall(fnAuto)
            if not okA then
                if (now - (R._lastAstErr or 0)) > 20 then
                    R._lastAstErr = now
                    log("自动配置角色出错: " .. tostring(errA), Color3.fromRGB(255, 120, 120))
                end
            end
        end
    end

    -- ===== 🍖 自动喂食：攒够食物才动手（不打断钓鱼），事件期间让路 =====
    --   排在换人之后：换人优先（见上面的长注释）。
    --   喂食能花的额度由 `R.feedBudgetCap()` 限制 —— 它扣掉了留给换人的预留部分，
    --   所以"等食物换人期间喂食偷偷把食物吃掉、一直攒不到"这个死锁不会再发生。
    do
        local okF, errF = pcall(feedTick)
        if not okF then
            if (now - (R._lastFeedErr or 0)) > 10 then
                R._lastFeedErr = now
                log("自动喂食出错: " .. tostring(errF), Color3.fromRGB(255, 120, 120))
            end
        end
    end

    local forced = R._force ~= nil and os.clock() < (R._force.until_ or 0)
    local halloween = isHalloween()
    local lead = tonumber(cfg.releaseLeadSeconds) or 0
    local ending = (not forced) and halloween and eventRemaining() <= lead
    local live = halloween and not ending

    if not live then
        -- 万圣节结束：清掉"每秒 roll"的锚点，避免把非活动时间也算进判定次数
        if R.hw then R.hw.lastTick = 0 end
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

-- ⚡⚡ 防闪电"硬放手"状态（单一来源：tick 与 UI 共用，避免两处逻辑漂移）
--   规则（用户要求）：只要当前活动**不是我们故意要持有的那个**，就不许有任何角色留在手上。
--   "故意持有"只认两种：
--     ① 活动 = 万圣节（本脚本的主业：手持角色等 Dracula/Demonic）
--     ② 活动 = Solar **且** Solar 模块开着（Solar 模块的本职就是手持角色等 Mars）
--   ⇒ Thunder / Slime Rain / Blizzard / Blood / Party / Toxic Wasteland … 一律硬放手。
--   返回: 活动在跑?, 活动名, 是否故意持有
--   ⚠⚠ 位置很重要：必须定义在 `EVENT_NAME` / `eventRemaining` 声明**之后**。
--      v366 就是把它插到了文件前段（第 1193 行）⇒ 那两个 local 尚未声明、解析成全局 nil ⇒
--      运行时报 `:1202: attempt to call a nil value`。本文件早就记过同类坑（AST 那段长注释）。
R.hardReleaseState = function()
    local evName = R.event.active and R.event.name or nil
    local evLive = (evName ~= nil) and (eventRemaining() > 0)
    local holdIntent = false
    if evLive then
        if evName == EVENT_NAME then
            holdIntent = true
        elseif evName == "Solar" and cfg.solarEnabled and type(R.solarTick) == "function" then
            holdIntent = true
        end
    end
    return evLive, evName, holdIntent
end

        -- ⚡⚡ v364：**非目标活动 = 无条件硬放手**（用户要求，实测背景见文件头注释）
        --   Thunder（电力）活动会落闪电，打到手持/旁边的角色就变【电力】突变 ⇒
        --   只要当前活动不是"我们故意持有的那个"，就不许有任何角色留在手上。
        --   ⚠ 这里**故意不看** cfg.releaseOnEventEnd / cfg.releaseForeignHold 两个开关：
        --     安全优先（那两个开关仍然管"无活动间隙"的行为）。
        local evLiveH, evNameH, holdIntent = R.hardReleaseState()
        local hardRelease = evLiveH and (not holdIntent) and (holdingOurs or curName ~= nil)
        if hardRelease and R._hardRelLogged ~= tostring(evNameH) then
            R._hardRelLogged = tostring(evNameH)
            log("⚡ 活动 " .. tostring(evNameH) .. " 期间强制放手（非万圣节 / 防闪电突变）",
                Color3.fromRGB(255, 200, 90))
        end

        -- ⚠⚠ 严格限次（用户实测踩到严重副作用，必须这么写）：
        --   症状：日志被"放手 Goka（非万圣节事件）"每 3 秒刷屏，而且**有概率把快捷栏
        --         最后一格的物品卡在背包里、进入死循环拿不出来**。
        --   根因：这个分支只要"检测到持有"就发 `RF.hold:FireServer("")`。
        --     ① 服务器对反复空放手会产生状态竞争（人没放掉 -> 下轮又发 -> 无限循环）
        --     ② 反复放手/持有会让游戏的背包<->快捷栏状态机错乱，最后一格被卡住
        --   对策：① 只在"确实有目标"时才放手（没持有就什么都不做）
        --         ② 同一个角色最多只发 maxTries 次，达不到就**停手并告警**，绝不无限循环
        --         ③ 停手后进入冷却期，给服务器时间稳定（避免刚冷却完又开始刷）
        if hardRelease or ((holdingOurs or releaseForeign) and cfg.releaseOnEventEnd) then
          -- ★★★ 自动配置角色的"持有豁免窗口"（v196）★★★
          -- 用户实测抓到的冲突：非万圣节分支会**立即放手**。
          --   而"把角色放到台子上"必须**先手持** —— 我一手持，这个分支立刻把它放掉，
          --   于是 PlacePrompt 一直停在 "Equip an Character First"，放置永远失败。
          --   （现象很容易被误判成"时序问题"，其实是逻辑冲突。）
          -- ⇒ 自动配置在"手持 -> 放置"这段关键窗口内置位 `R._astHoldGrace`，
          --   放手逻辑见到它就整段跳过，等放置完成再恢复正常行为。
          local astGrace = (R._astHoldGrace or 0) > os.clock()
          if astGrace and hardRelease then
            -- ⚡ 活动期间连"自动配置的持有（手持->放置台子）"这几秒也不放过：
            --   放在台子上的角色同样会被闪电打到。明确告知用户，免得以为自动配置坏了。
            if R._astGraceOverridden ~= tostring(evNameH) then
              R._astGraceOverridden = tostring(evNameH)
              log("⚡ 活动 " .. tostring(evNameH) .. " 期间暂停自动配置的持有（防闪电）· 活动结束后再配置即可",
                  Color3.fromRGB(255, 200, 90))
            end
            astGrace = false
          end
          if not astGrace then
            local relTarget = R.hold.key and R.hold.name or R.hold.foreignName or curName
            local nowR = os.clock()
            -- 冷却期内不再碰放手
            if (R._relCooldownUntil or 0) > nowR then
                -- 静默等待服务器稳定
            elseif relTarget == nil then
                -- 什么都没持有 -> 什么都不做（旧逻辑在这里也会白发一次放手）
                R._relTryName, R._relTries = nil, 0
            else
                if R._relTryName ~= relTarget then
                    R._relTryName, R._relTries = relTarget, 0
                end
                local maxTries = math.max(1, math.floor(tonumber(cfg.releaseMaxTries) or 3))
                if R._relTries < maxTries then
                    R._relTries = R._relTries + 1
                    if R.hold.baseline then
                        local s = fetchSummary()
                        if s then R.summary = s; checkMutation(s) end
                    end
                    applyRelease(ending and "事件即将结束"
                        or ("非万圣节活动 " .. tostring(evNameH or "?")))
                elseif not R._relGaveUpLogged or R._relGaveUpLogged ~= relTarget then
                    -- 达到上限还放不掉 -> 停手告警 + 冷却，绝不无限循环
                    R._relGaveUpLogged = relTarget
                    R._relCooldownUntil = nowR + 60
                    R._relTryName, R._relTries = nil, 0
                    -- 顺手把卡住的快捷栏状态恢复一下（只读+重推，不动内容）
                    if R.hotbar then
                        R.hotbar.pauseSyncSig = nil      -- 强制下一次同步
                        R.hotbar.blockedBulk = nil
                    end
                    log("⚠ 放手 " .. tostring(relTarget) .. " 连续 " .. maxTries ..
                        " 次未生效 -> 已停手并冷却 60 秒（避免反复放手把快捷栏卡死）",
                        Color3.fromRGB(255, 120, 120))
                end
            end
          end   -- ← astGrace 跳过结束
        end
        if not R._lastIdleScan or now - R._lastIdleScan > (tonumber(cfg.rescanIdle) or 10) then
            R._lastIdleScan = now
            refreshCandidates()
        end
        hotbarTick()
        return
    end

    -- === 万圣节进行中 ===
    -- 📊 累计统计（让用户能验证"脚本是否真的在尝试"，而不是只看到"零成功"）
    --   游戏机制实测（Constants.TypeEvents.Events.Halloween）：
    --     RollEverySeconds = 1 · RollDenominator = 100000 -> 每秒 1/100000 的概率
    --     即：单次 5 分钟活动 ≈ 300 次判定 ≈ 0.3% 命中率（期望要 ~330 次活动 ≈ 36 天）
    --   所以"好几天零成功"是**正常概率结果**，不是失效。这里把尝试量显式记下来。
    do
        R.hw = R.hw or { events = 0, holdSeconds = 0, lastTick = 0 }
        local H = R.hw
        -- ⚠ 只在【真的手持着角色】时才累加 —— 没手持就不会发生突变，算进去会虚报尝试量
        if R.hold.key ~= nil then
            if H.lastTick > 0 then H.holdSeconds = H.holdSeconds + (now - H.lastTick) end
            H.lastTick = now
            if (now - (H._rollMark or 0)) >= 1 then
                H._rollMark = now
                H.rolls = (H.rolls or 0) + 1
                H.expected = (H.rolls or 0) / 100000     -- 概率上应命中次数
            end
        else
            H.lastTick = 0                                -- 没手持就断开计时
        end
    end
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
    local inGrace = (R.hold.since or 0) + (2.5) > now
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
    for _, c in ipairs(R.hwPool or R.candidates) do
        if (cfg.rarities or {})[c.rarity] and R.charFilter.allows("halloween", c.name, true) == true then pick = c break end
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

    -- 🚦 让路：喂食/去突变/Solar 正在用玩家位置 -> 自动钓鱼完全停手
    --    ⚠ 必须"完全不动作"：不点《点击开始钓鱼》、不补传送、也不重置 lastBite
    --      （重置了会掩盖真实的上钩间隔，等让路结束时误判成"会话死了"）
    if R.yieldAny() then
        local who = R.yieldWho()
        if R._fishYielding ~= who then
            R._fishYielding = who
            log("⏸ 自动钓鱼让路（" .. R.yieldLabel(who) .. " 正在使用角色位置）", Color3.fromRGB(200, 200, 140))
        end
        return
    elseif R._fishYielding then
        -- 让路结束：重置计时基准，避免把让路期间的空档误判成"会话已死"而狂点
        R._fishYielding = nil
        FISH.lastBite = os.clock()
        FISH.missCount = 0
        FISH.lastAct = 0
        log("▶ 自动钓鱼恢复", Color3.fromRGB(120, 255, 140))
    end
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
--   ⚠ v273：这里也必须 strict（只认明确允许）。
--     它是"要不要启动 Solar"的闸门，用宽松判定会让**被排除的角色**把 Solar 拉起来跑。
local function solarUsableCount()
    local allow = cfg.solarRarities or {}
    if type(R.summary) ~= "table" then return 0 end
    local n = 0
    for _, v in pairs(R.summary) do
        if type(v) == "table" and tostring(v.ty or "") == "" and allow[tostring(v.ra or "")]
            and R.charFilter.allows("solar", tostring(v.n or ""), true) == true then
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

-- 🚦 Solar 占位声明：Solar 会【传送 + 手持角色】，与喂食/去突变完全同类，
--   必须参与互斥，否则三方互相传送、谁都做不成（用户实测担心过"互相抢"）。
--   实现：用 busySuggest("Solar")。抢不到就不启动（下一轮再试）。
local function solarStart_impl()
    local S = solarState()
    if S.active then return end
    -- ⭐ 前置条件：必须有可用的白板角色（指定品质）。没有就完全不介入 —— 继续钓鱼。
    if cfg.solarRequireCandidate ~= false then
        refreshCandidates(cfg.solarRarities)   -- ★ v238：同时重建 R.solarPool（带角色过滤）
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
    do
        local pick
        for _, c in ipairs(R.solarPool or R.candidates) do
            if R.charFilter.allows("solar", c.name, true) == true then pick = c break end
        end
        if not R.hold.key and pick then
            applyHold(pick.key, pick.name, pick.rarity)
            log("Solar 手持 " .. pick.name .. " [" .. pick.rarity .. "]")
        end
    end
end

local function solarStop_impl(reason)
    R.busyClear("Solar")          -- 🚦 释放：让其它模块能用角色位置
    R._solarBusyLogged = nil
    local S = solarState()
    if not S.active then return end
    S.active = false
    S.commitUntil = 0
    S.targetXZ = nil
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
    -- ★ v238：被角色级名单排除的，立刻放手（用户选的安全档：连你手动拿的也放）
    if R.hold.key and R.hold.name and R.charFilter.allows("solar", R.hold.name, true) ~= true then
        log("⚠ Solar 安全拦截：" .. tostring(R.hold.name) .. " 被你排除在 Solar 名单外 -> 立刻放手",
            Color3.fromRGB(255, 120, 120))
        applyRelease("Solar 名单排除")
    end
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
    -- 只从"勾选品质 + 勾选角色"的候选里挑（不信任列表顺序，逐个复核品质与名字）
    local pick
    for _, c in ipairs(R.solarPool or R.candidates) do
        if allow[c.rarity] and R.charFilter.allows("solar", c.name, true) == true then pick = c break end
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
    if isSolar() and not S.active then
        -- 🚦 抢占用：被喂食/去突变占着就先不启动（它们做完下一轮再进）
        local who = R.busyWho()
        if who == nil or who == "Solar" then
            solarStart()
        elseif not R._solarBusyLogged then
            R._solarBusyLogged = true
            log("⏸ Solar 让路：" .. R.yieldLabel(who) .. " 正在使用角色位置，等它做完", Color3.fromRGB(255, 200, 90))
        end
    end
    -- ⭐ 没真正介入（例如没有可用的白板角色）-> 连传送都不做，避免白跑还打断钓鱼
    if not isTest and not S.active then return end
    local p
    if d:IsA("BasePart") then p = d else pcall(function() p = d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart") end) end
    if not p then return end
    local now = os.clock()
    -- ⭐⭐ 承诺期（commit）：已经锁定一颗陨石、正站在它的落点上等它落地时，
    --   **绝不能被后面新生成的陨石勾走** —— 否则人物被疯狂拉来拉去，
    --   永远不站在任何一个落点上，也就永远等不到被砸中（用户实测到的"疯狂切换"）。
    --   ⚠ 假陨石同样受约束（否则"连发测试"根本验证不到锁定）。
    if (S.commitUntil or 0) > now then
        S.skipped = (S.skipped or 0) + 1
        return
    end
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
        -- 锁定这颗：接下来 commitSeconds 秒内不再理会新陨石，站定等它落地
        S.commitUntil = now + (tonumber(cfg.solarCommitSeconds) or 4.5)
        S.targetXZ = string.format("%.0f, %.0f", pos.X, pos.Z)
        log(string.format("☄ 锁定陨石 #%d -> 传送到落点 (%.0f, %.0f)，站定 %.1f 秒等它落地",
            S.meteors, pos.X, pos.Z, tonumber(cfg.solarCommitSeconds) or 4.5),
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
        R.busyClear("Solar")
        return
    end
    -- 🚦 Solar 激活期间持续占位：让钓鱼停手、让喂食/去突变让路
    if S.active then pcall(R.busySuggest, "Solar", "Solar 陨石雨") end
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
            -- 命中后立刻解除锁定：这颗已经结算完了，下一颗可以马上追
            S.commitUntil = 0
            S.targetXZ = nil
            applyRelease("Solar 已突变")
            refreshCandidates()
            R._lastSummaryAt = now
            -- 立刻换下一只（陨石每 5 秒一颗，不能等）—— 必须同时复核【品质】与【角色名单】
            -- ⚠ 实测踩到的漏洞：这里原来只复核品质，于是"命中后换人"会把被你排除的角色
            --   （例如 145M 的 Astra）重新拿起来，白名单形同虚设。
            local nxt
            local allow = cfg.solarRarities or {}
            for _, c in ipairs(R.solarPool or R.candidates) do
                if allow[c.rarity] and R.charFilter.allows("solar", c.name, true) == true then
                    nxt = c
                    break
                end
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

-- ⚠⚠ 必须用【精确路径】取 prompt！机器上有 **两个** ProximityPrompt：
--   CharacterInsert.ButtonModel.Button.ProximityPrompt  = "Start (Hold F)"  ← 不是我们要的
--   CharacterInsert.PromptPart.ProximityPrompt          = "Equip / Place / Pick Up" ← 这个才是
-- 用 FindFirstChild("ProximityPrompt", true) 递归查找会**随机命中前者**（子对象顺序会变），
-- 表现就是用户实测的："人 TP 到机器上了，但角色没被放上去"（触发了 Start 提示，什么也没发生）。
local function depoPrompt()
    local d = depoFolder()
    if not d then return nil end
    local ci = d:FindFirstChild("CharacterInsert")
    local pp = ci and ci:FindFirstChild("PromptPart")
    if not pp then return nil end
    return pp:FindFirstChild("ProximityPrompt")
end

-- 机器是【两步】操作（实测）：
--   ① CharacterInsert.PromptPart.ProximityPrompt        "Place"  -> 把角色放上机器（之后变 "Pick Up"）
--   ② CharacterInsert.ButtonModel.Button.ProximityPrompt "Start" (Hold 0.5) -> **按住启动清洗**
-- 只做第①步的话角色会停在机器上不开始洗（提示停在 "Pick Up"，没有 TimeLeft 倒计时）。
local function depoStartPrompt()
    local d = depoFolder()
    if not d then return nil end
    local ci = d:FindFirstChild("CharacterInsert")
    local bm = ci and ci:FindFirstChild("ButtonModel")
    local btn = bm and bm:FindFirstChild("Button")
    if not btn then return nil end
    return btn:FindFirstChild("ProximityPrompt")
end

-- 机器状态：
--   "idle"（空闲，没手持）/"ready"（手持了可放）/"pickup"（机器上有角色可取回）
--   "busy"（正在洗）/"none"（没机器）/"unknown"
--   注：取 prompt 的 ActionText 作为状态（这是最可靠的信号）
-- 前向声明（depoState 要用它，但它的定义在后面 —— 顺序错了会报 "attempt to call a nil value"）
local depoTimeLeft

local function depoState()
    -- ⭐ 最可靠的判据是 TimeLeft 倒计时：**洗的时候 PromptPart 的 ProximityPrompt 会被移除**，
    --   此时 prompt 读不到（ActionText=''），只看 prompt 会误判成 unknown。
    local tl = depoTimeLeft()
    local washing = (tl ~= nil and tl ~= "" and tl ~= "?")
    local p = depoPrompt()
    if not p then
        if washing then return "busy", "(倒计时中)" end
        return depoFolder() and "unknown" or "none", ""
    end
    local a = ""
    pcall(function() a = p.ActionText end)
    if washing or a:find("Skip") then return "busy", a end
    if a:find("Place") then return "ready", a end
    if a:find("Pick Up") then return "pickup", a end
    if a:find("Equip") then return "idle", a end
    if a:find("Start") then return "idle", a end
    return "unknown", a
end

depoTimeLeft = function()
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
    -- ⭐ 武装"自动确认"：机器的某些操作（Pick Up / 启动清洗）服务器会回
    --   DepolarizrUI{action="ShowConfirm"} 弹确认框，必须回 DepolarizrConfirm(true) 才继续。
    --   这里给它一个 8 秒窗口，收到 ShowConfirm 就自动点『是的』。
    R._depoAutoConfirmUntil = os.clock() + 8
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

-- 自动点『是的』（仅限去突变流程自己触发的那次，绝不乱点别人的确认框）
local function depoAutoConfirm()
    if (R._depoAutoConfirmUntil or 0) <= os.clock() then return false end
    R._depoAutoConfirmUntil = 0
    local Rm = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
    local rc = Rm and Rm:FindFirstChild("DepolarizrConfirm")
    if not rc then return false end
    -- 优先点游戏自己的「是的」按钮（走它原本的逻辑，最安全）
    local lp = LocalPlayer
    local pg = lp and lp:FindFirstChild("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    local cg = mg and mg:FindFirstChild("ConfirmationGUI")
    local ui = cg and cg:FindFirstChild("UI")
    local yes = ui and ui:FindFirstChild("Yes")
    if yes then
        local ok = pcall(function() firesignal(yes.MouseButton1Click) end)
        if ok then return true end
    end
    local ok = pcall(function() rc:FireServer(true) end)
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
            -- ★ v238：再叠一层角色级过滤（去突变专列有突变的，口径与自动突变相反）
            if ty ~= "" and allowT[ty] and allowR[ra]
                and R.charFilter.allows("wash", tostring(v.n or ""), true) == true then
                -- ⚠⚠⚠ v300：排序必须用**初始 CPS**，不能用背包里那个值！
                --   用户实测报的 bug（有截图）：
                --     列表 1. Kafka   $290.00M/s  Lava
                --          2. Kaneko II $262.50M/s  Party
                --   但 Kaneko II 的初始 CPS(175M) **高于** Kafka(145M)，
                --   应该先洗 Kaneko II。之所以反了，是因为用 `bc` 排序，而 `bc`
                --   含**突变倍率**：Lava(×2) 让 Kafka 显得比 Party(×1.5) 的 Kaneko II 更值钱。
                --   但洗突变**不改变角色本体价值** —— 该先洗的是本体（初始 CPS）最高的。
                --
                --   ⇒ 从 `bc` 反解初始值。
                --   ★★ 实测确认（别再改错）★★：**背包的 `bc` 只含突变倍率，不含等级曲线**。
                --     证据（游戏内原始摘要）：
                --       C|Kafka|Lava       bc=290000000  bl=1  ty=Lava
                --       C|Kaneko II|Party  bc=262500000  bl=1  ty=Party
                --       C|Changlia|Lava    bc=250000000  bl=1  ty=Lava
                --     对照图鉴：Kafka 145M × Lava(2)      = 290M   ✅ 恰好相等
                --               Kaneko II 175M × Party(1.5) = 262.5M ✅ 恰好相等
                --               Changlia 125M × Lava(2)   = 250M   ✅ 恰好相等
                --     而且 `bl` **恒为 1**（角色在背包里没有等级），等级曲线根本不必乘。
                --     ⚠ 我第一版多除了一次 cpsCurve，算出的初始值偏大 2 倍 —— 被下面的
                --        "与图鉴常数对照"校验抓出来了，所以这段注释才写得这么详细。
                --   ⇒ 初始 CPS = bc ÷ 突变倍率（无突变时就是 bc 本身）
                local cur = tonumber(v.bc) or 0
                -- ⚠⚠ 这里**绝不可引用 AST.MUT_MULT**：那张表在 L5219 才定义，
                --   而本函数在工厂/UI 段就会被调用 -> 那一刻 `AST` 还是 nil
                --   -> 报 "attempt to index nil with 'MUT_MULT'"，整个洗突变预览直接失效
                --   （实测踩到）。所以内联一份**只读副本**。
                --   ⚠ 数值必须与 AST.MUT_MULT 保持一致（那边改动时记得同步这里）。
                local MUT_M = {
                    Gold = 1.25, Honey = 1.25,
                    Diamond = 1.5, Frozen = 1.5, Party = 1.5,
                    Lava = 2, Slime = 2, Blood = 2, Electric = 2, Zombie = 2,
                    Ghost = 2.5, Complexity = 2.5,
                    Solar = 4, Lunar = 4, Toxic = 4,
                    Sinister = 5,
                    Angelic = 6, Mars = 6, Void = 6,
                    Nightmare = 7, Dracula = 8, Demonic = 10,
                }
                local mm = (ty == "" and 1) or (MUT_M[ty] or 1)
                local base = nil
                if cur > 0 and mm > 0 then base = cur / mm end
                -- 倍率表里没有这个突变（或 bc 缺失）-> 退回图鉴常数
                if not base or base <= 0 then
                    local ch = Constants and Constants.Characters and Constants.Characters[tostring(v.n or "")]
                    base = ch and tonumber(ch.CPS) or cur
                end
                list[#list + 1] = { key = key, name = tostring(v.n or "?"), rarity = ra, ty = ty,
                                    cps = cur, base = base or cur, mult = mm }
            end
        end
    end
    -- ★ 按初始 CPS 降序（初始相同再按当前值，保证顺序稳定）
    table.sort(list, function(a, b)
        local ab, bb = tonumber(a.base) or 0, tonumber(b.base) or 0
        if ab ~= bb then return ab > bb end
        return (tonumber(a.cps) or 0) > (tonumber(b.cps) or 0)
    end)
    return list
end

local WASH = { placed = 0, lastPlace = 0, lastKey = nil, lastErr = nil }

washTick = function()
    if not cfg.washEnabled then return end
    -- ⭐ 只在【没有任何活动运行】时才洗。理由有两个，都很硬：
    --   ① 你的策略是"任何事件运行时连手动持有的角色都放手" -> 一持有就被释放，
    --      prompt 退回 "Equip Character First!"，fireproximityprompt 打空（用户实测的"只TP不放"）。
    --   ② 安全：洗的目标本身就是【带突变的角色】，手持期间若来了突变事件，
    --      它会被二次突变（不可逆）-> 必须避开所有事件。
    if R.event.active and R.event.name and eventRemaining() > 0 then
        if not WASH._pausedLogged then
            WASH._pausedLogged = true
            log("⏸ 去突变暂停：当前有活动（" .. tostring(R.event.name) .. "）在跑，等活动结束再洗",
                Color3.fromRGB(255, 200, 90))
        end
        return
    end
    WASH._pausedLogged = nil
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
        -- 冗余保险：忙时清掉"正在放"标记，避免状态错乱导致重复投放
        -- （实测出现过：机器在洗却每 20 秒重复"已放入 Depolarizer"同一个人）
        WASH.lastKey = nil
        return
    end

    -- ⭐ 机器上【已经坐着一个角色但还没开始洗】-> 按『启动』按钮，绝不再放第二个
    --   （这是实测漏掉的一步：只 Place 不 Start，角色会一直停在机器上不动）
    if state == "pickup" then
        local tl = depoTimeLeft()
        if not (tl and tl ~= "" and tl ~= "?") then
            if now - (WASH.lastStart or 0) > 5 then
                WASH.lastStart = now
                if depoFire(depoStartPrompt()) then
                    log("🧼 机器上已有角色 -> 已按『启动』开始清洗", Color3.fromRGB(120, 255, 140))
                    WASH.placed = WASH.placed + 1
                end
            end
        else
            WASH.placed = WASH.placed + 1
        end
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

    -- 🚦 互斥：自动喂食正在用玩家位置 -> 让路（否则两边互相传送、谁都做不成）
    local busyNow = R.busyWho()
    if busyNow and busyNow ~= "去突变" then
        if not WASH._busyLogged then
            WASH._busyLogged = true
            log("⏸ 去突变让路：自动喂食正在使用角色位置，等它做完", Color3.fromRGB(255, 200, 90))
        end
        return
    end
    WASH._busyLogged = nil

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

    -- ② 传送到机器旁并放上去（逐步等待 + 校验 + 失败重试）
    task.spawn(function()
        local key, nm, ra, ty = pick.key, pick.name, pick.rarity, pick.ty
        local cps = pick.cps
        -- 🚦 占位：去突变全程要用玩家位置（传送 + 手持），期间自动钓鱼必须停手
        R.busySuggest("去突变", "去突变（Depolarizer）")   -- 占位+让路一步到位
        local done = false
        -- 看门狗：无论这条协程怎么退出（提前 return / 报错），都保证释放
        task.spawn(function()
            local wd0 = os.clock()
            while isCurrent() and not done and (os.clock() - wd0) < 120 do task.wait(0.5) end
            R.busyClear("去突变")
        end)
        -- ⚠ 实测教训：只等 0.35 秒是不够的 —— 服务器还没确认"手持"这个动作，
        --   此时 prompt 仍是禁用状态（ActionText = "Equip Character First!"），
        --   fireproximityprompt 打上去等于空放。
        --   表现就是用户看到的："人 TP 到机器上了，但角色没被放上去"。
        -- 步骤 1：等服务器确认手持生效
        local t0 = os.clock()
        while isCurrent() and (os.clock() - t0) < 3 do
            if heldName() == nm then break end
            task.wait(0.15)
        end
        if heldName() ~= nm then
            log("⚠ 去突变：" .. nm .. " 手持未生效（服务器没确认）-> 本轮放弃，稍后重试",
                Color3.fromRGB(255, 180, 80))
            WASH.lastKey = nil
            return
        end
        -- 步骤 2：传送到机器
        local hrp, pos = rootPart(), depoStandPos()
        if hrp and pos then
            pcall(function()
                hrp.CFrame = CFrame.new(pos)
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        -- 步骤 3：等 prompt 就绪（ActionText 变成 "Place"）
        local ready = false
        t0 = os.clock()
        while isCurrent() and (os.clock() - t0) < 4 do
            local st, act = depoState()
            if act and act:find("Place") then ready = true break end
            if st == "busy" then ready = true break end          -- 已经被收走了
            if st == "pickup" then
                -- 角色已经在机器上但还没开始洗 -> 按【启动按钮】(第②步)
                if (os.clock() - t0) > 0.8 then
                    if depoFire(depoStartPrompt()) then
                        log("🧼 角色已上机器 -> 已按『启动』开始清洗", Color3.fromRGB(120, 255, 140))
                    end
                    task.wait(1.5)
                    t0 = os.clock()
                end
            end
            if (os.clock() - t0) > 1.5 and heldName() ~= nm then
                pcall(function() doHold(key) end)               -- 补一次手持
            end
            task.wait(0.2)
        end
        if not ready then
            local st, act = depoState()
            log("⚠ 去突变：" .. nm .. " 的 prompt 没就绪（状态=" .. tostring(st) ..
                " Action='" .. tostring(act) .. "'）-> 本轮放弃，稍后重试", Color3.fromRGB(255, 180, 80))
            WASH.lastKey = nil
            return
        end
        -- 步骤 4：触发
        local okFire = depoFire(depoPrompt())
        -- 步骤 5：验证真的开始洗了（TimeLeft 出现倒计时 / prompt 变 "Skip (Robux)"）
        local placed = false
        t0 = os.clock()
        while isCurrent() and (os.clock() - t0) < 6 do
            local st2 = depoState()
            local tl = depoTimeLeft()
            if st2 == "busy" or (tl and tl ~= "" and tl ~= "?") then placed = true break end
            -- 还停在 pickup -> 补按一次启动按钮（Hold 0.5 可能需要多次）
            if st2 == "pickup" and (os.clock() - t0) > 1.5 then
                depoFire(depoStartPrompt())
                t0 = os.clock()
            end
            task.wait(0.3)
        end
        if placed then
            WASH.placed = WASH.placed + 1
            WASH.lastPlacedName = nm
            log(string.format("🧼 已放入 Depolarizer：%s [%s] 突变=%s $%s/s  -> 开始清洗（预计 %s）",
                nm, ra, ty, fmtCps(cps), tostring(depoTimeLeft() or "数小时")),
                Color3.fromRGB(120, 255, 140))
            task.wait(1.2)
            if R.hold.key == key then applyRelease("去突变：已交付机器") end
        else
            log("⚠ 去突变：" .. nm .. " 放上机器了但没启动成功（fire=" .. tostring(okFire) ..
                "）-> 稍后重试", Color3.fromRGB(255, 180, 80))
            WASH.lastKey = nil
        end
        done = true
        R.busyClear("去突变")        -- 🚦 正常结束也要释放（看门狗仅兜底）
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
            elseif a == "ShowConfirm" then
                -- ⭐ 服务器要求确认（"确定要去掉这个突变吗？"）-> 只有在我们自己发起的流程里才自动点『是的』
                if (R._depoAutoConfirmUntil or 0) > os.clock() then
                    local cn = tostring((type(p) == "table" and p.charName) or "?")
                    local ct = tostring((type(p) == "table" and p.charType) or "?")
                    if depoAutoConfirm() then
                        log("🧼 已自动确认去突变：" .. cn .. " [" .. ct .. "]",
                            Color3.fromRGB(120, 255, 140))
                    else
                        log("⚠ 去突变确认框自动点击失败 —— 请手动点『是的』", Color3.fromRGB(255, 120, 120))
                    end
                end
            elseif a == "HideConfirm" then
                -- 忽略
            end
        end)
        R.connections[#R.connections + 1] = c
    end
end

--============================================================== 🚪 自动关闭弹窗
-- 实测机制（真机验证）：
--   * 重进游戏会弹出 MainGui.WelcomeGUI（“欢迎回来~ / 你离线赚了 $X，想翻三倍吗？”）
--     它内部有 UI.Yes（付费翻三倍）和 Close（右上角 X）
--   * ⚠ 关键：关闭按钮的处理器挂在 **Activated** 上，不是 MouseButton1Click！
--       实测 WelcomeGUI.Close: MouseButton1Click 连接数=0，Activated 连接数=2
--       -> 必须 firesignal(btn.Activated)
--   * ⚠⚠ 不能直接 btn.Parent.Visible = false 了事：点 Close 会走 resolveWelcomeClosed()，
--       它做三件重要的事：
--         ① FinalizeWelcomeOffline:InvokeServer("close")  -> 服务器结清离线收益
--         ② 恢复被隐藏的 UI（HoldPostIntroUiHidden=false）
--         ③ 触发 ClientSignals.WelcomeClosed 事件 -> 教程脚本（RodAbilityTutorialClient）在等它
--       绕过它会导致：离线收益没结清、UI 卡住、教程不推进。
--   实测验证：firesignal(Close.Activated) 后 WelcomeGUI.Visible=false、
--             WelcomeFlowResolved=true、HoldPostIntroUiHidden=false、Cash 到账 ✅
--   * DailyGUI 里除了 Close 还有 Robux（付费跳过）和 FUTURE 按钮 -> 只点 Close

-- ⚠ 安全规则：只点【按钮名字精确等于 Close】的 GuiButton，其余一概不碰。
--   这从根上排除了误点付费按钮的可能（用户对不可逆操作极其敏感）。
local POPUPS = {
    { key = "welcome", cfgKey = "autoCloseWelcome", label = "离线收益弹窗",
      path = { "MainGui", "WelcomeGUI" }, btn = "Close",
      desc = "“欢迎回来~ 你离线赚了 $X，想翻三倍吗？”" },
    { key = "daily",   cfgKey = "autoCloseDaily",   label = "每日签到弹窗",
      path = { "MainGui", "DailyGUI" },   btn = "Close",
      desc = "每日奖励 / 连续签到" },
}

-- 找出这个按钮上"真正挂了处理器"的信号名（不依赖 getconnections 也能退化工作）
local function signalNamesFor(btn)
    local names = {}
    local function add(n, conns)
        if type(conns) == "table" and #conns > 0 and conns[1].Enabled ~= false then
            names[#names + 1] = n
        end
    end
    for _, ev in ipairs({ "Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "TouchTap", "InputBegan" }) do
        if type(getconnections) == "function" then
            local ok, conns = pcall(getconnections, btn[ev])
            if ok then add(ev, conns) end
        end
    end
    -- 兜底：拿不到连接信息时按优先级硬试（Activated 优先，实测就是它）
    if #names == 0 then names = { "Activated", "MouseButton1Click" } end
    -- Activated 排最前（实测它就是正确入口）
    table.sort(names, function(a, b)
        if a == "Activated" then return true end
        if b == "Activated" then return false end
        return a < b
    end)
    return names
end

local function autoCloseTick()
    R.autoClose = R.autoClose or { count = 0 }
    local AC = R.autoClose
    if not cfg.autoCloseEnabled then return end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return end
    local now = os.time()      -- ⚠ 绝不能用 tick()：会调到本脚本自己的主循环造成无限递归
    local delay = tonumber(cfg.autoCloseDelay) or 1.5
    for _, p in ipairs(POPUPS) do
        if cfg[p.cfgKey] ~= false then
            local node = pg
            for _, seg in ipairs(p.path) do node = node and node:FindFirstChild(seg) end
            if node then
                local visible = false
                pcall(function() visible = node.Visible == true end)
                -- 还没到"出现够久"的时间就不动手（给游戏完成初始化）
                local seen = AC["seen_" .. p.key]
                if visible then
                    if not seen then
                        AC["seen_" .. p.key] = now
                    elseif (now - seen) >= delay then
                        local btn = node:FindFirstChild(p.btn)
                        local okBtn = false
                        pcall(function() okBtn = btn ~= nil and btn:IsA("GuiButton") and btn.Name == p.btn end)
                        if okBtn then
                            -- ⭐ 执行点复核：只点名为 Close 的按钮，其它一律不碰
                            if btn.Name == "Close" then
                                local fired = false
                                for _, ev in ipairs(signalNamesFor(btn)) do
                                    local ok = pcall(function() firesignal(btn[ev]) end)
                                    if ok then fired = true break end
                                end
                                task.wait(0.25)
                                local stillVis = false
                                pcall(function() stillVis = node.Visible == true end)
                                if fired and not stillVis then
                                    AC.count = (AC.count or 0) + 1
                                    AC.lastAt = os.date("%H:%M:%S")
                                    AC.lastWhat = p.label
                                    AC["seen_" .. p.key] = nil
                                    log("🚪 已自动关闭" .. p.label .. "（" .. p.desc .. "）",
                                        Color3.fromRGB(120, 255, 140))
                                elseif fired then
                                    log("⚠ 点了" .. p.label .. "的 Close 但没关掉（可能还有二次确认）",
                                        Color3.fromRGB(255, 180, 80))
                                    AC["seen_" .. p.key] = now      -- 稍后重试
                                else
                                    log("⚠ 自动关闭" .. p.label .. "失败：fire 信号没成功",
                                        Color3.fromRGB(255, 120, 120))
                                    AC["seen_" .. p.key] = now
                                end
                            end
                        end
                    end
                else
                    AC["seen_" .. p.key] = nil
                end
            end
        end
    end
end
R.autoCloseTick = autoCloseTick

-- 手动关一次（UI 按钮用）
R.autoCloseNow = function()
    local before = (R.autoClose and R.autoClose.count) or 0
    local ok, err = pcall(autoCloseTick)
    if not ok then return false, tostring(err) end
    -- 绕过 delay 立刻关：把 seen 时间戳提前
    if R.autoClose then
        for _, p in ipairs(POPUPS) do R.autoClose["seen_" .. p.key] = 0 end
    end
    task.wait(0.6)
    pcall(autoCloseTick)
    return true
end

-- 状态（给 UI / API 用）
R.autoCloseStatus = function()
    local AC = R.autoClose or {}
    local list = {}
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, p in ipairs(POPUPS) do
        local node = pg
        for _, seg in ipairs(p.path) do node = node and node:FindFirstChild(seg) end
        local vis = false
        if node then pcall(function() vis = node.Visible == true end) end
        list[#list + 1] = { key = p.key, label = p.label, visible = vis, on = cfg[p.cfgKey] ~= false,
                            exists = node ~= nil }
    end
    return { enabled = cfg.autoCloseEnabled ~= false, count = AC.count or 0,
             lastAt = AC.lastAt, lastWhat = AC.lastWhat, popups = list }
end

--============================================================== 🛒 自动购买 / 领取 / 转盘 / 重生（v340）
-- 需求（用户原话）：「先做自动买药水，自动买升级，自动重生，自动领取两项奖励，自动玩轮盘」
--                  「然后做加上做自动买商店」
--
-- 设计原则（沿用上面"自动关弹窗"那套安全哲学）：
--   · **只点游戏自己的 GuiButton**（firesignal），不伪造任何远程包 ⇒ 服务端自己做校验，
--     买不起/不满足条件时它自己拒绝，我们不会造成"非法购买"
--   · ⚠⚠ 硬规则（写在代码里，连配置开关都不给）：按钮名含 robux / studs / gift / owned / future
--     一律**永不点击** —— 从根上落实用户"绝不做付费功能"
--   · 每行"哪个非付费按钮可见"= 它支持的游戏内货币。实测（2026-10-11 Selena 店）：
--       Offer2 Luck Potion Lvl.3 -> Gems=可见 / Cash=隐藏
--       Offer4 Luck Potion Lvl.2 -> Cash=可见 / Gems=隐藏
--     ⇒ 只点【可见】的那个，天然区分现金店与宝石店
--   · 默认 **Dry-Run（只预演不点）**；自动重生默认**关闭**（会重置进度）
--   · 全部挂 R 表（顶层 local 已 197/200，一个都不能加）
;(function()
    local A = R.auto or {}
    R.auto = A
    A.deny = { robux = true, studs = true, gift = true, owned = true, future = true }
    A.count = A.count or 0
    A.spent = A.spent or 0
    A.last = A.last or {}
    A.at = 0
    A.items = A.items or {}

    -- ⭐ v341：商店注册表（key = 配置键；gui = MainGui 下的容器名；name = UI 里显示的名字）
    --   映射是实测出来的（2026-10-13）：
    --     SecretStoreGUI = Selene's Store! / SecretStore2GUI = Angelia's Store /
    --     SecretStore3GUI = Forgotten Traveler's Store（用户口中的 Yang Store）/
    --     SecretStore4GUI = Sasha's Store!
    A.stores = A.stores or {
        -- ⚠ rf = 该商店的**购买接口**（实测命名统一；参数 = (行名, 货币名)，货币名就是按钮名）
        { key = "gem",      gui = "GemStoreGUI",      name = "宝石商店 Gem Store",   rf = "GemStorePurchase" },
        { key = "selene",   gui = "SecretStoreGUI",   name = "Selene 商店",          rf = "SecretStorePurchase" },
        { key = "angelia",  gui = "SecretStore2GUI",  name = "Angelia 商店",         rf = "SecretStore2Purchase" },
        { key = "yang",     gui = "SecretStore3GUI",  name = "Yang 商店（游戏内：Forgotten Traveler）", rf = "SecretStore3Purchase" },
        { key = "sasha",    gui = "SecretStore4GUI",  name = "Sasha 商店",           rf = "SecretStore4Purchase" },
        { key = "boosts",   gui = "BoostsStoreGUI",   name = "加成药水店 Boosts",    rf = "BoostsStorePurchase" },
        { key = "upgrades", gui = "UpgradesStoreGUI", name = "升级商店 Upgrades",    rf = "UpgradesStorePurchase" },
        -- ⚠ v344：`DailyStoreGUI`（每日商店）**按用户要求移除**（"把每日商店去掉，不需要这个"）。
        --   要加回来：在下面补一行 { key = "daily", gui = "DailyStoreGUI", name = "每日商店" } 即可
        --   （发现逻辑只扫这张表，UI 面板也是按它循环生成的）。
        { key = "fishing",  gui = "FishingStoreGUI",  name = "钓鱼商店",             rf = "FishingStorePurchase" },
    }
    A.guiToKey = A.guiToKey or (function()
        local m = {}
        for _, s in ipairs(A.stores) do m[s.gui] = s.key end
        return m
    end)()
    A.byStore = A.byStore or {}
    A.uiList = A.uiList or {}
    A.uiAt = 0

    local function say(fmt, ...)
        local s = string.format(fmt, ...)
        A.lastSay = s
        log("🛒 " .. s, Color3.fromRGB(170, 220, 255))
    end
    A.say = say

    -- 价格字符串 -> 数字（"$7.5K" / "1,250,000" / "$44.86Qi"）
    A.money = function(s)
        if type(s) == "number" then return s end
        local t = tostring(s or ""):gsub("[%$,%s]", "")
        local num, suf = t:match("^([%d%.]+)(%a*)$")
        if not num then return nil end
        local n = tonumber(num)
        if not n then return nil end
        if suf ~= "" then
            local m = HW_K.SUFFIX_MUL[suf:sub(1, 2)] or HW_K.SUFFIX_MUL[suf:sub(1, 1)]
            if m then n = n * m end
        end
        return n
    end

    local function stats()
        local l = LocalPlayer:FindFirstChild("leaderstats")
        return l and l:FindFirstChild("Cash"), l and l:FindFirstChild("Gems")
    end
    A.cash = function()
        local c = stats()
        if not c then return nil end
        local ok, v = pcall(function() return c.Value end)
        return ok and A.money(v) or nil
    end
    A.gems = function()
        local _, g = stats()
        if not g then return nil end
        local ok, v = pcall(function() return g.Value end)
        return ok and tonumber(v) or nil
    end

    -- 库存文本 -> 数量（"x3 Left!" / "3 Left!" -> 3；"NO STOCK!" -> 0；看不懂就 nil）
    A.stockCount = function(s)
        if not s then return nil end
        local t = tostring(s)
        if t:upper():find("NO STOCK") then return 0 end
        local n = t:match("(%d+)%s*[Ll]eft")
        if n then return tonumber(n) end
        n = t:match("[Xx]%s*(%d+)")
        if n then return tonumber(n) end
        return nil
    end

    -- 该行里最像"价格"的文本
    --   ⚠⚠⚠ v358 修复：价格标签在**购买按钮内部**！
    --     实测 `BoostsStoreGUI.ScrollFrame.Offer1.Cash.TextLabel = "$7.5K"`，
    --     而旧代码只扫行的**直接子项** ⇒ 永远读到 nil（日志里那一串"价 nil"就是它）,
    --     更要命的是 price=nil 会把"买得起吗"的检查整段跳过。
    A.rowPrice = function(row, btn)
        local cands = {}
        local function scan(node)
            if not node then return end
            for _, c in ipairs(node:GetDescendants()) do
                if c:IsA("TextLabel") and c.Name ~= "Title" and c.Name ~= "Benefits" then
                    local t = tostring(c.Text):gsub("<[^>]+>", ""):gsub("\n", " ")
                    local v = A.money(t)
                    if v and v > 0 then cands[#cands + 1] = { v = v, t = t, inBtn = true } end
                end
            end
        end
        local n0 = #cands
        if btn then
            pcall(function()
                local own = tostring(btn.Text or ""):gsub("<[^>]+>", "")
                local v = A.money(own)
                if v and v > 0 then cands[#cands + 1] = { v = v, t = own, inBtn = true } end
            end)
            scan(btn)                       -- 购买按钮内部（最可信）
        end
        local btnN = #cands
        n0 = n0
        for _, c in ipairs(row:GetChildren()) do
            if c:IsA("TextLabel") and c.Name ~= "Title" and c.Name ~= "Benefits" then
                local t = tostring(c.Text):gsub("<[^>]+>", ""):gsub("\n", " ")
                local v = A.money(t)
                if v and v > 0 then cands[#cands + 1] = { v = v, t = t } end
            end
        end
        for i = 1, btnN do if cands[i].t:find("%$") then return cands[i].v end end
        if btnN > 0 then return cands[1].v end
        for _, c in ipairs(cands) do if c.t:find("%$") then return c.v end end
        local best
        for _, c in ipairs(cands) do if not best or c.v < best then best = c.v end end
        return best
    end

    -- 该行可点的"游戏内货币"按钮：可见 + 不在付费黑名单 + 名字在白名单里
    --   ⚠ v342：优先返回**可见**的（实测"哪个非付费按钮可见"= 当前可用货币）；
    --   若一个都不可见，退化成"第一个非付费按钮" —— 否则**买不起时按钮被游戏隐藏，
    --   商品会从面板里凭空消失**（用户会以为功能坏了）。价格检查在前、服务端也会自己拒绝，
    --   所以这个退化不会造成乱花钱。
    A.safeButton = function(row)
        local fallback
        for _, c in ipairs(row:GetChildren()) do
            if c:IsA("GuiButton") then
                local nm = tostring(c.Name):lower()
                if not A.deny[nm]
                    and (nm == "cash" or nm == "gems" or nm == "purchase" or nm == "purchase2") then
                    local vis = false
                    pcall(function() vis = c.Visible == true end)
                    if vis then return c, nm end
                    if not fallback then fallback = c end
                end
            end
        end
        if fallback then return fallback, tostring(fallback.Name):lower() end
        return nil
    end

    -- 点击：沿用本脚本既有做法（逐个信号 firesignal，直到有一个成功）
    -- ⚠ v341：实测教训（源码上面记着）「AutoFish 只认 MouseButton1Click、WelcomeGUI 只认 Activated」
    --   ⇒ 只点第一个信号**不可靠**。all=true 时把挂了的信号全点一遍（领取/转盘用，天然幂等：
    --     已领过的服务器会自己拒绝）；**买东西只用单次**，避免重复扣钱。
    A.click = function(btn, all)
        if not btn then return false end
        local fired = false
        for _, ev in ipairs(signalNamesFor(btn)) do
            local ok = pcall(function() firesignal(btn[ev]) end)
            if ok then
                fired = true
                if not all then return true end
                task.wait(0.05)
            end
        end
        return fired
    end

    -- ⚠ 用户明确要求：**不用游戏自带的自动购买**（Boosts 店那个 `AutoPurchase` 按钮，
    --   实测只有那一家商店有）。所以这里刻意**不提供**任何"替游戏开自动购买"的接口，
    --   购买全靠下面 discover() 扫出的每行购买按钮，由脚本自己点 + 扣款验证。
    --   （源码位置记录：BoostsStoreGUI.AutoPurchase / AutoPurchaseHandler / 远程 BoostsStoreSetAutoBuy）

    -- 扫描各商店行（动态：商店上新/轮换会自动跟上）
    -- ⚠⚠⚠ v344 重构：改成**按注册表精确查名字**。
    --   旧写法在 MainGui 里按 `sn:find("StoreGUI")` 模糊匹配 —— 结果
    --   `SecretStore2GUI`（Angelia）/`SecretStore3GUI`（Yang）/`SecretStore4GUI`（Sasha）
    --   因为 "Store" 与 "GUI" 之间夹着数字，**全被静默跳过**，那三个面板永远是空的
    --   （用户实测报的就是这个，而手工验证行本身完全正常）。
    --   ⇒ 现在只扫注册表里写明的容器名（要加商店 = 注册表加一行），
    --     顺带天然排除了不在表里的容器（比如用户要求去掉的每日商店）。
    A.discover = function()
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local mg = pg and pg:FindFirstChild("MainGui")
        local out = {}
        if not mg then return out end
        for _, s in ipairs(A.stores) do
            local store = mg:FindFirstChild(s.gui)
            if store then
                for _, d in ipairs(store:GetDescendants()) do
                    if d:IsA("GuiObject") then
                        local t = d:FindFirstChild("Title")
                        if t then
                            local btn, cur = A.safeButton(d)
                            if btn then
                                local title = tostring(t.Text):gsub("<[^>]+>", "")
                                title = title:gsub("^%s+", ""):gsub("%s+$", "")
                                if title ~= "" and not title:find("CHARACTERNAME") then
                                    -- ★ v361：库存文本可能在任意 TextLabel 里（"x1 Left!" / "NO STOCK!"）
                                    local stock
                                    for _, lab in ipairs(d:GetDescendants()) do
                                        if lab:IsA("TextLabel") then
                                            local st = tostring(lab.Text)
                                            if st:upper():find("NO STOCK") or st:lower():find("left") then
                                                stock = st:gsub("\n", " ")
                                                break
                                            end
                                        end
                                    end
                                    out[#out + 1] = { title = title, store = s.gui, storeKey = s.key,
                                                      row = d, rowName = tostring(d.Name),
                                                      rf = s.rf, btn = btn, cur = cur,
                                                      price = A.rowPrice(d, btn), stock = stock,
                                                      stockN = A.stockCount(stock) }
                                end
                            end
                        end
                    end
                end
            end
        end
        A.items = out
        -- ★ v341：按商店分组（UI 每个商店一个面板要用）
        A.byStore = {}
        for _, it in ipairs(out) do
            local k = A.guiToKey[it.store] or it.store
            local g = A.byStore[k]
            if not g then g = {}; A.byStore[k] = g end
            g[#g + 1] = it
        end
        A.itemsAt = os.clock()
        return out
    end

    -- ★ v341：把每个商店的"当前在售商品"同步到它自己的多选面板上。
    --   ⚠ 为什么必须异步做：商店内容是游戏**异步下发**的（*StoreUpdated 远程），
    --     脚本刚加载时那些面板往往是空的；而库的下拉"设值"有个已知陷阱：
    --     新列表里没有旧值时库会删值并触发回调 -> 把用户已勾的清空（§11.x 记录过）。
    --   ⇒ 所以：列表真变了才 SetValues，紧接着**把 cfg 里存的勾选重新推回去**。
    A.syncUI = function(force)
        if not R.autoUI then return end
        if (os.clock() - (A.uiAt or 0)) < 5 and not force then return end
        A.uiAt = os.clock()
        for _, s in ipairs(A.stores) do
            local w = R.autoUI[s.key]
            if w and w.drop then
                local names, seen = {}, {}
                for _, it in ipairs((A.byStore or {})[s.key] or {}) do
                    if not seen[it.title] then seen[it.title] = true; names[#names + 1] = it.title end
                end
                table.sort(names)
                local sig = table.concat(names, "|")
                if force or A.uiList[s.key] ~= sig then
                    A.uiList[s.key] = sig
                    pcall(function() w.drop:SetValues(names) end)
                end
                -- 幂等对齐：把 cfg 里存的勾选推回控件（库的 SetValues 可能把值清掉）
                local want = (cfg.autoStoreItems or {})[s.key]
                if type(want) == "table" then
                    pcall(function() w.drop:SetValue(want) end)
                end
            end
        end
    end

    A.itemNames = function()
        local seen, names = {}, {}
        for _, it in ipairs(A.items or {}) do
            if not seen[it.title] then seen[it.title] = true; names[#names + 1] = it.title end
        end
        table.sort(names)
        return names
    end

    -- 领取类：任务 / 游戏时长 / 每日
    --   ⚠ v341 改进（用户报"没工作"，实测是三个原因叠加）：
    --     ① 日志被白名单吃掉 -> 界面上看不到（已加 🛒/领取 关键词）
    --     ② 只点第一个信号不可靠 -> 改 all=true 全点
    --     ③ 会每 2 秒重复点同一个按钮 -> 同一按钮 30 秒内只点一次
    A.claimAt = A.claimAt or {}
    A.claimTick = function()
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local mg = pg and pg:FindFirstChild("MainGui")
        if not mg then return 0 end
        local n, now = 0, os.clock()
        local function claimIn(frame, kind, label, enabled)
            if not enabled then return end
            local f = mg:FindFirstChild(frame)
            if not f then return end
            for _, d in ipairs(f:GetDescendants()) do
                if d:IsA("GuiButton") then
                    local okName = (kind == "all" and d.Name == "ClaimAll")
                        or (kind == "reward" and d.Name:match("^Reward%d+$") ~= nil)
                        or (kind == "claimbtn" and d.Name:match("^ClaimBtn%d*$") ~= nil)
                        or (kind == "status" and d.Name == "Status")
                    if okName then
                        -- ⚠⚠⚠ v343 关键修复：**"Claimed!" 里也含 "CLAIM"**！
                        --   原来判定是 `upper():find("CLAIM")` ⇒ 把"**已领取**"误判成"可领取"，
                        --   于是脚本每 30 秒反复点那几个已经领过的按钮；而下面每个 poll 只点一个就
                        --   `return` ⇒ **真正可领的那个永远轮不到**。
                        --   用户实测现象：「还是没有完整工作，漏掉一个没有领取」，面板上仍挂着 Claim 1!
                        --   ⇒ 规则改成：含 "CLAIM" 且**不含 "CLAIMED"**
                        --     （实测两种状态：可领 = `CLAIM!`，已领 = `Claimed!`）
                        local can = false
                        for _, lab in ipairs(d:GetDescendants()) do
                            if lab:IsA("TextLabel") then
                                local u = tostring(lab.Text):upper()
                                if u:find("CLAIM") and not u:find("CLAIMED") then can = true end
                            end
                        end
                        local key = frame .. "/" .. d.Name
                        if can and (now - (A.claimAt[key] or 0)) > 30 then
                            A.claimAt[key] = now
                            if A.click(d, true) then
                                n = n + 1
                                say("已点领取：%s（%s）", label, d.Name)
                                -- ⚠ v343：**不能 return** —— 一帧里可能有多个真正可领的，
                                --   每个 poll 只领一个的话，后面的要等下一轮（最长 2 秒×N）。
                                --   这里一次最多领 4 个，既领得干净又不会突然爆点。
                                if n >= 4 then return end
                            end
                        end
                    end
                end
            end
        end
        claimIn("QuestGUI", "all", "任务奖励 ClaimAll", cfg.autoClaimQuests ~= false)
        if n == 0 then claimIn("QuestGUI", "status", "任务奖励（单个）", cfg.autoClaimQuests ~= false) end
        claimIn("PlaytimeRewardsGUI", "reward", "游戏时长奖励", cfg.autoClaimPlaytime ~= false)
        claimIn("DailyGUI", "claimbtn", "每日奖励", cfg.autoClaimDaily ~= false)
        return n
    end

    -- 转盘：优先点游戏自带的 AutoSpin（点一次它就一直自动转）
    A.spinTick = function()
        if cfg.autoSpin == false then return end
        if (os.clock() - (A.spinAt or 0)) < 20 then return end
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local mg = pg and pg:FindFirstChild("MainGui")
        local sp = mg and mg:FindFirstChild("Spin")
        if not sp then return end
        local auto = sp:FindFirstChild("AutoSpin", true)
        local one = sp:FindFirstChild("SpinButton", true)
        local target = (auto and auto:IsA("GuiButton")) and auto or one
        if target then
            A.spinAt = os.clock()
            if A.click(target, true) then say("已触发轮盘（%s）", tostring(target.Name)) end
        end
    end

    -- 重生（默认关：会重置进度）
    A.rebirthTick = function()
        if cfg.autoRebirth ~= true then return end
        if (os.clock() - (A.rebAt or 0)) < 90 then return end
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local mg = pg and pg:FindFirstChild("MainGui")
        local rg = mg and mg:FindFirstChild("RebirthGUI")
        local btn = rg and rg:FindFirstChild("Rebirth", true)
        if btn and btn:IsA("GuiButton") then
            A.rebAt = os.clock()
            if cfg.autoBuyDryRun ~= false then
                say("[预演] 会点「重生」")
            elseif A.click(btn) then
                say("已点「重生」")
            end
        end
    end

    --============================================================== 💊 自动喝药水（v345）
    -- 实测机制（2026-10-13，用户授权实测一瓶 Cash Potion Lvl. 1）：
    --   · `hum:EquipTool(tool)` 只把药水**拿到手上**，2 秒后仍在手上、**没被消耗**
    --   · **`tool:Activate()` 才是真正的"喝"** —— 实测 Boosts 面板立刻多出 `Potion_cash_2x` ✅
    --   · `firesignal(tool.Activated)` **完全没反应**（本地信号不同步到服务端）—— 工具不能用它
    --   · 喝完那瓶药水**还在背包里**（本次未消耗；所以"已经在生效"时要跳过，避免浪费）
    -- ⇒ 正确流程：装备 -> Activate() -> 换回原来的手持（视觉上几乎看不到被拿起，
    --    这就是"别的脚本不用拿在手上就能喝"的真相）
    A.boostNames = function()
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local mg = pg and pg:FindFirstChild("MainGui")
        local b = mg and mg:FindFirstChild("Boosts")
        local t = {}
        if b then
            for _, d in ipairs(b:GetChildren()) do
                local vis = false
                pcall(function() vis = d.Visible == true end)
                if vis and d.Name ~= "PotionTemplate" and not d:IsA("LocalScript") then
                    t[#t + 1] = tostring(d.Name)
                end
            end
        end
        return t
    end

    -- ★ v355：清单 = **背包里现有的** ∪ **Constants 里定义的全部药水种类**
    --   （用户要"显示所有药水种类"；原来只列背包现成的，种类不全）
    --   不在背包里的也能勾：真到喝的时候找不到就跳过（不会报错）
    -- ★★★ v372：**药水是堆叠的** —— 真实数量在游戏客户端的背包数据表里。
    --   实测定位：`Remotes.BackpackCharSummaryDelta.OnClientEvent` 处理器的 upvalue 中有一张表，
    --   键形如 `T|<药水名>`（T = Tool），每项含 `count` 字段
    --   （旁证：游戏自己的 ClanClient 就是 `math.max(1, p.item.count or 1)` 来显示 `x N`）。
    --   通过 getconnections + getupvalues 取出该表（只读；缓存，失效自动重建）。
    --   ⚠ 这是唯一能反映"堆叠数量"的来源：Tool 实例只有一个，属性里也没有数量。
    A.invTable = function()
        local cached = A._inv
        if type(cached) == "table" then
            local alive = false
            pcall(function()
                for k in pairs(cached) do
                    if type(k) == "string" and k:sub(1, 2) == "T|" then alive = true break end
                end
            end)
            if alive then return cached end
        end
        A._inv = nil
        if type(getconnections) ~= "function" or type(getupvalues) ~= "function" then return nil end
        local rem = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
        local ev = rem and rem:FindFirstChild("BackpackCharSummaryDelta")
        if not ev then return nil end
        local okc, conns = pcall(getconnections, ev.OnClientEvent)
        if not okc or type(conns) ~= "table" then return nil end
        for _, c in ipairs(conns) do
            local oku, ups = pcall(getupvalues, c.Function)
            if oku and type(ups) == "table" then
                for _, v in pairs(ups) do
                    if type(v) == "table" then
                        local hit = false
                        pcall(function()
                            for k in pairs(v) do
                                if type(k) == "string" and k:sub(1, 2) == "T|" then
                                    hit = true
                                    break
                                end
                            end
                        end)
                        if hit then
                            A._inv = v
                            return v
                        end
                    end
                end
            end
        end
        return nil
    end

    -- 数某瓶药水现在有几瓶（① 背包数据表 .count ② 背包卡片 Amount ③ 数实例）
    A.potionCount = function(name)
        -- ① 权威：客户端背包数据表（含堆叠）
        local inv = A.invTable()
        if inv then
            local item = inv["T|" .. tostring(name)]
            if type(item) == "table" then
                local c = tonumber(item.count)
                if c then return c end
            elseif type(item) == "number" then
                return item
            end
        end
        -- ② 背包卡片（只有背包面板打开时才存在）
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local mg = pg and pg:FindFirstChild("MainGui")
        local bg = mg and mg:FindFirstChild("BackpackGUI")
        local sf = bg and bg:FindFirstChild("ScrollFrame", true)
        if sf then
            for _, card in ipairs(sf:GetChildren()) do
                local ln = card:FindFirstChild("LabelName", true)
                local amt = card:FindFirstChild("Amount", true)
                if ln and amt and tostring(ln.Text) == name then
                    local n = tostring(amt.Text):match("(%d+)")
                    if n then return tonumber(n) end
                end
            end
        end
        -- ③ 兜底：数实例（未堆叠时正确）
        local cnt = 0
        local bp = LocalPlayer:FindFirstChild("Backpack")
        for _, t in ipairs((bp and bp:GetChildren()) or {}) do
            if t:IsA("Tool") and tostring(t.Name) == name then cnt = cnt + 1 end
        end
        local ch = LocalPlayer.Character
        for _, t in ipairs((ch and ch:GetChildren()) or {}) do
            if t:IsA("Tool") and tostring(t.Name) == name then cnt = cnt + 1 end
        end
        return cnt
    end

    -- ★ v374：某瓶药水要保留几瓶（由两个控件值派生，默认 0 = 不保留）
    A.keepCount = function(name)
        local set = cfg.autoDrinkKeepList
        if type(set) == "table" and set[name] == true then
            -- ⚠ v375：数量读不到时按 3 保守处理（宁可少喝，不可多喝掉人家留着的那几瓶）
            return math.max(0, math.floor(tonumber(cfg.autoDrinkKeepNum) or 3))
        end
        return 0
    end

    -- ★★★ v375：**启动宽限期** —— 脚本刚加载时库还没把配置恢复完（实测约 1~2 秒甚至更久），
    --   此时 cfg.autoDrinkKeep* / autoDrinkList / autoStoreOn* 都还是默认值 ⇒
    --   会"按默认配置"做出不可逆动作（实测：重载后 2 秒就喝掉了一瓶用户要留的药水 ✗）。
    --   ⇒ 加载后 20 秒内不自动喝药、不自动购买。
    A.graceUntil = os.clock() + 20
    A.graceSaid = false

    A.potionNames = function()
        local seen, names = {}, {}
        local function add(n)
            n = tostring(n or "")
            if n ~= "" and not seen[n] then seen[n] = true; names[#names + 1] = n end
        end
        local bp = LocalPlayer:FindFirstChild("Backpack")
        for _, t in ipairs((bp and bp:GetChildren()) or {}) do
            -- 优先用游戏自己的标记 `IsPotion == true`（比名字匹配可靠；名字匹配留作兜底）
            local isP = t:IsA("Tool") and (t:GetAttribute("IsPotion") == true
                or tostring(t.Name):lower():find("potion") ~= nil)
            if isP then add(t.Name) end
        end
        local ok, C = pcall(function()
            return require(game:GetService("ReplicatedStorage"):WaitForChild("Constants", 20))
        end)
        if ok and type(C) == "table" and C.Potions and type(C.Potions.Definitions) == "table" then
            for _, v in pairs(C.Potions.Definitions) do
                if type(v) == "table" and type(v.ToolName) == "string"
                    and v.ToolName:lower():find("potion") then
                    add(v.ToolName)
                end
            end
        end
        table.sort(names)
        return names
    end

    A.syncPotionUI = function(force)
        if not R.dDrinkList then return end
        if not force and (os.clock() - (A.potAt or 0)) < 10 then return end
        A.potAt = os.clock()
        local names = A.potionNames()
        local sig = table.concat(names, "|")
        if force or A.potSig ~= sig then
            A.potSig = sig
            pcall(function() R.dDrinkList:SetValues(names) end)
        end
        if type(cfg.autoDrinkList) == "table" then
            pcall(function() R.dDrinkList:SetValue(cfg.autoDrinkList) end)
        end
        -- ★ v369：保留清单的选择器 + 实时状态行（每 10 秒刷新一次）
        if R.dKeepList then pcall(function() R.dKeepList:SetValues(names) end) end
        if R.dKeepList and type(cfg.autoDrinkKeepList) == "table" then
            pcall(function() R.dKeepList:SetValue(cfg.autoDrinkKeepList) end)
        end
        if E.lKeep then
            local keepN = math.max(0, math.floor(tonumber(cfg.autoDrinkKeepNum) or 3))
            local parts, cnt = {}, 0
            for name, on in pairs(cfg.autoDrinkKeepList or {}) do
                if on then
                    cnt = cnt + 1
                    parts[#parts + 1] = string.format("%s 留%d（现有 %d）", tostring(name), keepN,
                        A.potionCount(name))
                end
            end
            table.sort(parts)
            pcall(function()
                E.lKeep:SetText("保留清单(" .. tostring(cnt) .. "): "
                    .. ((#parts > 0) and table.concat(parts, " | ") or "（空 — 选好药水后点「➕ 加入」）"))
            end)
        end
    end

    -- ⭐⭐ v349：**完全不用手持**的喝法（用户明确要求："我的另一个脚本全程不需要手持直接自动喝"）
    -- 正解 = `Remotes.PotionUse:InvokeServer(药水Tool)` —— RemoteFunction，直接把 Tool 实例发给服务器。
    -- 依据（游戏自己的客户端脚本，铁证）：
    --   PlayerScripts.Player.PotionToolClient 第 84 / 101 行：
    --     u9.Activated:Connect(function() ... return PotionUse:InvokeServer(u9) end)
    --   也就是说：工具被"激活"时，真正干活的是**这个 Invoke**；装备只是它的触发条件。
    -- ⇒ 我们直接 Invoke 就跳过了装备，**手持位一秒都不会被占**。
    -- 实测（2026-10-13）：InvokeServer 返回 true、Boosts 面板立刻多出对应增益、
    --   喝前喝后 `hand` 都是 Rod of the Heavens（全程零手持）。
    A.potionRemote = function()
        local rem = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
        return rem and rem:FindFirstChild("PotionUse")
    end

    A.drink = function(tool)
        local pu = A.potionRemote()
        if pu then
            -- ⚠ RemoteFunction 卡住会把主循环一起拖死 ⇒ 放独立线程 + 4 秒超时
            local done, ok = false, false
            task.spawn(function()
                local o, r = pcall(function() return pu:InvokeServer(tool) end)
                ok = (o and r == true)
                done = true
            end)
            local t0 = os.clock()
            while not done and (os.clock() - t0) < 4 do task.wait(0.1) end
            if not done then return false, "InvokeServer 超时" end
            if ok then return true, "invoke" end
            return false, "服务器拒绝"
        end
        -- 兜底：PotionUse 不存在时，退化成"装备 + Activate + 换回手持"（v346 那套）
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum then return false, "没有 Humanoid" end
        local prevTool = char:FindFirstChildWhichIsA("Tool")
        local prevName = prevTool and prevTool.Name or nil
        local ok1 = pcall(function() hum:EquipTool(tool) end)
        if not ok1 then return false, "装备失败" end
        task.wait(0.45)
        local ok2 = pcall(function() tool:Activate() end)
        task.wait(0.45)
        if cfg.autoDrinkKeepRod ~= false then
            pcall(function() hum:UnequipTools() end)
            task.wait(0.25)
            local bp = LocalPlayer:FindFirstChild("Backpack")
            local back
            if prevName and bp then
                for _, t in ipairs(bp:GetChildren()) do
                    if t:IsA("Tool") and tostring(t.Name) == prevName then back = t break end
                end
            end
            if back then pcall(function() hum:EquipTool(back) end) end
        end
        return ok2, "fallback"
    end

    --============================================================== 💊 药水：源码直读（v356）
    -- 用户质问「为什么要加学习功能，查源码没法直接弄全部都能喝吗？」—— 能，而且更准。
    --   ① `Constants.Potions.Definitions`：key / ToolName / Type / Multiplier / DurationSeconds
    --   ② `Remotes.PotionGetState:InvokeServer()`（**游戏自己的接口**，PotionBoostsClient 就在用）
    --        返回 { paused, potions = { {key, type, multiplier, endTime}, ... }, seq, serverTime }
    --        ⇒ **剩余秒数 = endTime - serverTime**（用服务器时间，不受本地时钟影响）
    --   ⇒ "还在生效" = potions 里有同 (type, multiplier) 或同 key、且剩余 > 0
    --     **一次都不用学**。tile 存在性 / 时长兜底只作为二、三道保险。
    A.potionDefs = function()
        if A._pdefs then return A._pdefs end
        local m = {}
        local ok, C = pcall(function()
            return require(game:GetService("ReplicatedStorage"):WaitForChild("Constants", 20))
        end)
        if ok and type(C) == "table" and C.Potions and type(C.Potions.Definitions) == "table" then
            for k, v in pairs(C.Potions.Definitions) do
                if type(v) == "table" and type(v.ToolName) == "string" then
                    m[v.ToolName] = {
                        key = tostring(k),
                        type = v.Type and tostring(v.Type) or nil,
                        mult = tonumber(v.Multiplier),
                        dur = tonumber(v.DurationSeconds),
                    }
                end
            end
        end
        A._pdefs = m
        return m
    end
    A.potionDur = function(name)
        local d = A.potionDefs()[name]
        return d and d.dur or nil
    end

    -- 生效状态（源码直读；带 3 秒超时，绝不拖死主循环）
    A.potionState = function()
        local out = { byKey = {}, byTypeMult = {}, n = 0 }
        local rem = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
        local pgs = rem and rem:FindFirstChild("PotionGetState")
        if not pgs then return out end
        local done, res = false, nil
        task.spawn(function()
            local ok, r = pcall(function() return pgs:InvokeServer() end)
            if ok then res = r end
            done = true
        end)
        local t0 = os.clock()
        while not done and (os.clock() - t0) < 3 do task.wait(0.05) end
        if type(res) ~= "table" then return out end
        local now = tonumber(res.serverTime) or os.time()
        for _, v in pairs(res.potions or {}) do
            if type(v) == "table" then
                local left = (tonumber(v.endTime) or 0) - now
                if left > 0 then
                    out.n = out.n + 1
                    if v.key then out.byKey[tostring(v.key):lower()] = left end
                    if v.type then
                        out.byTypeMult[tostring(v.type):lower() .. "|" ..
                            tostring(math.floor((tonumber(v.multiplier) or 0) * 100 + 0.5))] = left
                    end
                end
            end
        end
        return out
    end

    -- Boosts 面板里"存在即生效"的效果 tile 名集合（含药水 tile，如 potion_cash_2x）
    --   实测：面板关着时 tile `vis=false` 但实例仍在 ⇒ 判定用"存在"，不用"可见"。
    A.effectTiles = function()
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local mg = pg and pg:FindFirstChild("MainGui")
        local b = mg and mg:FindFirstChild("Boosts")
        local out = {}
        if not b then return out end
        for _, d in ipairs(b:GetChildren()) do
            local cls = d.ClassName
            if (cls == "ImageLabel" or cls == "Frame") and tostring(d.Name) ~= "PotionTemplate" then
                out[tostring(d.Name):lower()] = true
            end
        end
        return out
    end

    -- 「到期才续」判定（v356：源码直读优先，tile / 时长兜底）
    A.isPotionActive = function(toolName, st)
        st = st or A.potionState()
        local def = A.potionDefs()[toolName]
        if def then
            if def.type and def.mult then
                local k = def.type:lower() .. "|" .. tostring(math.floor(def.mult * 100 + 0.5))
                local left = st.byTypeMult[k]
                if left and left > 0 then
                    return true, def.type .. "×" .. tostring(def.mult) .. " 剩 " .. tostring(math.floor(left)) .. "s"
                end
            end
            if def.key then
                local left = st.byKey[def.key:lower()]
                if left and left > 0 then
                    return true, def.key .. " 剩 " .. tostring(math.floor(left)) .. "s"
                end
            end
        end
        -- 兜底 1：tile 存在（tile 名 = potion_<key 小写>，游戏自己就这么取 key）
        local tiles = A.effectTiles()
        if def and def.key and tiles["potion_" .. def.key:lower()] then
            return true, "tile potion_" .. def.key:lower()
        end
        -- 兜底 2：这瓶药的时长还没走完
        local d = def and def.dur or nil
        local lastAt = (A.drinkAt or {})[toolName] or 0
        if d and lastAt > 0 and (os.clock() - lastAt) < d then
            return true, "时长未走完（剩 " .. tostring(math.floor(d - (os.clock() - lastAt))) .. "s）"
        end
        return false, nil
    end

    A.drinkTick = function()
        if cfg.autoDrinkEnabled ~= true then return end
        -- ★ v375：启动宽限期内不喝（配置恢复完再动手）
        if os.clock() < (A.graceUntil or 0) then return end
        -- 🛡 安全闸门：免手持之后不再占位，所以只保留"脚本正在手持角色时不喝"
        if R.hold and R.hold.key then return end
        local list = cfg.autoDrinkList or {}
        local now = os.clock()
        local gap = tonumber(cfg.autoDrinkInterval) or 30
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if not bp then return end
        A.drinkAt = A.drinkAt or {}
        -- ★★★ v373：**必须拆成两个时间戳**！
        --   原来"跳过"和"真喝"共用 `A.drinkAt` ⇒ 每次跳过都把它刷新 ⇒
        --   `isPotionActive` 的"时长兜底"永远认为"时长没走完" ⇒ **再也喝不了** ✗✗
        --   （用户实测：Luck Lvl.3 明明还剩 3 瓶可喝，脚本却一直不喝）
        --   tryAt   = 上次"尝试/跳过"的时间（只用于间隔节流）
        --   drinkAt = 上次**真喝成功**的时间（只用于"到期才续"的时长兜底）
        A.tryAt = A.tryAt or {}
        local st = A.potionState()          -- ★ v356：源码直读的生效状态（type/key + 剩余秒）
        -- ★ v374：保留量改由 A.keepCount() 从**控件值**派生（纯 cfg 表存不下来）
        for _, tool in ipairs(bp:GetChildren()) do
            if tool:IsA("Tool") and list[tool.Name] and (now - (A.tryAt[tool.Name] or 0)) > gap then
                -- ★★★ v369「保留 N 瓶」：库存 <= 保留量 -> 一滴都不喝（留给 admin abuse 这类活动）
                --   只有**超出**保留量时才会喝（例：留 3 瓶，有几瓶就喝掉第 4、5… 瓶直到剩 3）
                local keepN = A.keepCount(tool.Name)
                local haveN = A.potionCount(tool.Name)
                if keepN > 0 and haveN <= keepN then
                    A.tryAt[tool.Name] = now
                    if not (A.keepSaid and A.keepSaid[tool.Name] == haveN) then
                        A.keepSaid = A.keepSaid or {}
                        A.keepSaid[tool.Name] = haveN
                        say("🧴 「%s」只剩 %d 瓶（保留 %d 瓶）-> 不喝，留着", tool.Name, haveN, keepN)
                    end
                else
                local isOn, why = A.isPotionActive(tool.Name, st)
                if isOn then
                    A.tryAt[tool.Name] = now        -- 还在生效 -> 只记"尝试"，不动 drinkAt（否则兜底自我维持）
                elseif cfg.autoDrinkDryRun ~= false then
                    A.tryAt[tool.Name] = now
                    local ks = {}
                    for k in pairs(st.byKey) do ks[#ks + 1] = k end
                    table.sort(ks)
                    say("[预演] 会喝「%s」（当前生效 %d 条: %s）", tool.Name, st.n,
                        (#ks > 0) and table.concat(ks, ",") or "无")
                else
                    if R.busySuggest then pcall(R.busySuggest, "AutoPotion", "自动喝药水") end
                    A.tryAt[tool.Name] = now
                    local ok, why2 = A.drink(tool)
                    if R.busyClear then pcall(R.busyClear, "AutoPotion") end
                    local def = A.potionDefs()[tool.Name]
                    local extra = def and ("，key=" .. tostring(def.key)
                        .. (def.dur and ("，时长 " .. tostring(def.dur) .. "s") or "")) or ""
                    if ok then
                        -- ★ v373：只有**真喝成功**才记 drinkAt（时长兜底只认它，避免自我维持）
                        A.drinkAt[tool.Name] = now
                        A.keepSaid = nil
                        say("已喝「%s」（免手持%s）", tool.Name, extra)
                    else
                        say("喝「%s」失败：%s", tool.Name, tostring(why2 or "?"))
                    end
                    task.wait(0.8)                  -- 一次只喝一瓶，喝完让服务器刷新状态
                end
                end                                  -- ← v369 保留判定的 else 收尾
            end
        end
    end

    -- 购买
    local function buyTick()
        if cfg.autoBuyEnabled ~= true then return end
        -- ★ v375：启动宽限期内不买（避免"默认配置"下花错钱）
        if os.clock() < (A.graceUntil or 0) then return end
        if not A.graceSaid then
            A.graceSaid = true
            say("启动宽限期结束（20 秒）-> 自动喝药 / 自动购买 开始按配置工作")
        end
        if (os.clock() - (A.itemsAt or 0)) > 8 then A.discover() end
        local want = cfg.autoBuyList or {}
        local cash, gems = A.cash(), A.gems()
        local dry = cfg.autoBuyDryRun ~= false
        local maxItem = tonumber(cfg.autoBuyMaxPerItem) or 0
        local hourCap = tonumber(cfg.autoBuyHourBudget) or 0
        if (os.clock() - (A.budgetAt or 0)) > 3600 then A.budgetAt = os.clock(); A.spent = 0 end
        local storeOn = cfg.autoStoreOn or {}
        local storeItems = cfg.autoStoreItems or {}
        -- ⚠ 用户明确要求：**不用游戏自带的自动购买**（Boosts 店那个 AutoPurchase 按钮）——
        --   一律由脚本自己实现：下面按店/按商品逐个点购买按钮，并用"钱有没有少"验证到账。
        for _, it in ipairs(A.items or {}) do
            local skey = A.guiToKey[it.store] or it.store
            -- ★ v341：三重放行 —— ①该商店自己的开关 ②该商店自己的商品清单 ③（兼容）旧的全局清单
            local allowed = (storeOn[skey] == true and (storeItems[skey] or {})[it.title] == true)
                          or want[it.title]
            if allowed and (os.clock() - (A.last[it.title] or 0)) > 4 then
                A.last[it.title] = os.clock()
                local isGem = (it.cur == "gems")
                local have = isGem and gems or cash
                local curName = isGem and "宝石" or "现金"
                local price = it.price
                -- ★ v359：**缺货判定**（实测行里有个 `Stock` 标签，缺货时写着 "NO STOCK!"）
                --   缺货还硬点 = 白点（日志里"累计 27 次"就是这么来的）⇒ 直接跳过 + 退避。
                local noStock = false
                if it.stock then
                    pcall(function() noStock = tostring(it.stock):upper():find("NO STOCK") ~= nil end)
                end
                if noStock then
                    A.last[it.title] = os.clock() + 240        -- 缺货退避 4 分钟
                    if not (A.stockSaid and A.stockSaid[it.title]) then
                        A.stockSaid = A.stockSaid or {}
                        A.stockSaid[it.title] = true
                        say("⏳ 「%s」缺货（%s），等补货 — 先不点它", it.title, tostring(it.stock))
                    end
                elseif price ~= nil and have ~= nil and have < price then
                    say("跳过「%s」：%s不够（价 %s / 你有 %s）", it.title, curName, tostring(price), tostring(have))
                elseif maxItem > 0 and price ~= nil and price > maxItem then
                    say("跳过「%s」：价格 %s 超过单件上限", it.title, tostring(price))
                elseif hourCap > 0 and price ~= nil and (A.spent + price) > hourCap then
                    say("跳过「%s」：会超出每小时预算", it.title)
                elseif dry then
                    say("[预演] 会买「%s」（%s，价 %s）", it.title, curName, tostring(price))
                else
                    -- ★★★ v362：**有货就一口气买完**（用户要求）
                    --   接口 = 商店自己的购买 RemoteFunction：
                    --     `<Store>Purchase:InvokeServer(行名, 货币名)`
                    --   （用户 Cobalt 抓包确认 BoostsStorePurchase("Offer3","Cash")，
                    --     调用点 = BoostsStoreClient 第 269 行）
                    --   ⚠ 这是**脚本自己调商店的购买接口**，不是游戏自带的自动购买功能。
                    A.fail = A.fail or {}
                    local rem = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
                    local rf = it.rf and rem and rem:FindFirstChild(it.rf)
                    local curArg = isGem and "Gems" or "Cash"
                    if it.cur == "purchase" or it.cur == "purchase2" then curArg = "Gems" end
                    -- 连买次数：有明确库存就按库存（上限 15 防手滑）；没标记的每次只买 1 个
                    local wantN = 1
                    if it.stockN and it.stockN > 0 then wantN = math.min(it.stockN, 15) end
                    local got, lastRes, lastErr = 0, nil, nil
                    if rf then
                        for _ = 1, wantN do
                            -- 每一次购买前都复核三条线（连买也不能越线）
                            local haveNow = isGem and A.gems() or A.cash()
                            if maxItem > 0 and price ~= nil and price > maxItem then break end
                            if hourCap > 0 and price ~= nil and (A.spent + price) > hourCap then break end
                            if price ~= nil and haveNow ~= nil and haveNow < price then break end
                            local done, res, callErr = false, nil, nil
                            task.spawn(function()
                                local ok2, r = pcall(function() return rf:InvokeServer(it.rowName, curArg) end)
                                if ok2 then res = r else callErr = tostring(r) end
                                done = true
                            end)
                            local t0 = os.clock()
                            while not done and (os.clock() - t0) < 4 do task.wait(0.05) end
                            lastRes, lastErr = res, callErr
                            if res == true then
                                got = got + 1
                                A.count = A.count + 1
                                A.spent = A.spent + (price or 0)
                                A.fail[it.title] = nil
                                task.wait(0.28)                 -- 连买节奏（别把服务器打炸）
                            else
                                break                           -- 买不到就停（多半缺货/买不起）
                            end
                        end
                    end
                    if got > 0 then
                        say("✅ 买到「%s」×%d（%s，单价 %s）· 累计 %d 次", it.title, got, curName,
                            tostring(price), A.count)
                        -- ★ v363：买到了但**库存文本没变**（角色/能力这类不按库存扣的条目）
                        --   ⇒ 给 120 秒冷却，别每 4 秒重复买同一个。
                        if it.rowName and it.row then
                            local nowTxt
                            pcall(function()
                                for _, lab in ipairs(it.row:GetDescendants()) do
                                    if lab:IsA("TextLabel") then
                                        local st = tostring(lab.Text)
                                        if st:lower():find("left") or st:upper():find("NO STOCK") then
                                            nowTxt = st
                                            break
                                        end
                                    end
                                end
                            end)
                            local nNow = A.stockCount(nowTxt)
                            if nNow ~= nil and it.stockN ~= nil and nNow >= it.stockN then
                                A.last[it.title] = os.clock() + 120
                            end
                        end
                    else
                        local nth = (A.fail[it.title] or 0) + 1
                        A.fail[it.title] = nth
                        local why
                        if lastRes == false then
                            why = "接口返回 false（缺货 / 买不起 / 该店不认这个货币）"
                        elseif lastErr then
                            why = "调用报错：" .. tostring(lastErr)
                        elseif rf then
                            why = "找不到购买接口 " .. tostring(it.rf)
                        end
                        say("⚠ 买「%s」没成功：%s（第 %d 次）", it.title, why, nth)
                        if nth >= 3 then
                            A.last[it.title] = os.clock() + 1800
                            say("⏸ 「%s」连续 3 次没成功，暂停 30 分钟", it.title)
                        end
                    end
                end
            end
        end
    end

    R.autoTick = function()
        local now = os.clock()
        if (now - (A.at or 0)) < (tonumber(cfg.autoPoll) or 2) then return end
        A.at = now
        local ok, err = pcall(function()
            if (os.clock() - (A.itemsAt or 0)) > 10 then A.discover() end   -- 10 秒扫一次（别每 2 秒全扫）
            A.syncUI()
            A.claimTick()
            A.spinTick()
            A.rebirthTick()
            A.drinkTick()
            A.syncPotionUI()
            buyTick()
        end)
        if not ok and (now - (A.errAt or 0)) > 30 then
            A.errAt = now
            log("🛒 Auto 模块出错: " .. tostring(err), Color3.fromRGB(255, 120, 120))
        end
    end

    R.autoStatus = function()
        A.discover()
        local names = A.itemNames()
        return { enabled = cfg.autoBuyEnabled == true, dry = cfg.autoBuyDryRun ~= false,
                 items = names, count = A.count, spent = A.spent, last = A.lastSay,
                 cash = A.cash(), gems = A.gems() }
    end
    R.autoDiscover = function() return A.discover() end
end)()

--============================================================== 🍖 自动喂食（Auto Feed）
-- 实测机制（真机验证，2026-10）：
--   * 角色放在【台子】上才会出现喂食按钮 —— 手持角色不行（用户实测确认）
--   * 台子路径：自己的地块 Plot<N> 下
--       根台子   = Plot<N>/<数字>            （1..3，游戏自带）
--       购买台子 = Plot<N>/Purchases/<名字>   （5PAID/10PAID/15PAID... 免费与付费混排）
--     台子属性（权威、实时更新）：
--       HasCharacter / CharacterName / Rarity / CharacterType(突变) / Level / CPS(已含突变与配对)
--   * 四个 ProximityPrompt 都在 <台>/PromptNode_Pickup 下，**ActionText 里直接带价格**：
--       LevelUpPrompt     "Level Up (1.2B Food)"        Hold=0      <- 我们要用的（一次一级）
--       LevelUp10Prompt   "Level Up 10 (12.3B Food)"    Hold=0
--       MaxLevelUpPrompt  "Max Level Up (22.9B Food)"   Hold=0.20   <- 吃光所有食物，无法控制分配
--       PickupOwnerPrompt "Pick Up"
--   * 触发条件：**人必须站到台子 6 格内**（实测 4.4 格 Enabled=true，6.3 格 false）
--       然后 fireproximityprompt(LevelUpPrompt) 即可，一次精确升 1 级、精确扣费
--       （实测 Teto L143→144 扣 147,765，与面板 "Level Up (147.8K Food)" 完全一致）
--   * 传送代价实测约 1.2 秒/次，所以执行时"在一个台子连续喂完再换下一个"
--
-- 成本公式（从 Constants 源码 + 面板双重反推，误差 <0.5%）：
--   花费(品质, 等级) = math.floor(LevelBaseCosts[品质] × GetLevelCurveMultiplier(等级) × 折扣 + 0.5)
--   折扣(keep) 默认 0.225 = 商店「升级折扣 -10%」× 通行证「-75%」（相乘而非相加）
--   ⚠ 该折扣因账号而异，所以脚本用【面板显示的真实价格】反解实际折扣并自适应
--
-- 优先级数学（本模块的大脑）：
--   单级性价比 = 单级CPS收益 / 单级食物成本
--              = 当前CPS × (GetCpsCurveMultiplier(L+1)/GetCpsCurveMultiplier(L) - 1) / 花费(品质,L)
--   · 同一等级段内"相对增益"对所有角色恒定 → 同品质之间只比当前 CPS
--   · 跨品质要再除以 LevelBaseCosts（Ancient 4000 vs Celestial 1250 vs Ascended 72）
--   · 成本曲线凸、收益曲线线性 → 连续喂同一只会让性价比单调下降
--     ⇒ **贪心**（每口都喂当前性价比最高的台子）在数学上就是本问题的最优解，
--       会自动"该集中就集中、该摊开就摊开"，不需要任何人工规则。
--       实测验证：300B 食物 → 7 台 584 级 → 全屋 CPS +23.6%
--
-- 未来通用性：品质顺序/成本表/收入曲线/角色表/突变倍数 全部运行时从 Constants 读取；
--             台子、等级、CPS、价格全部运行时从实例读 → 游戏更新或进度推进都不需要改代码。

-- 格式化钱（游戏同款短后缀）
-- 修约到 n 位小数（解决浮点误差导致滑块显示 3.5000000000000004 这种鬼数字）
local function rnd(v, n)
    local m = 10 ^ (n or 2)
    return math.floor((tonumber(v) or 0) * m + 0.5) / m
end
R.rnd = rnd

local function fmtShort(n)
    n = tonumber(n) or 0
    if n ~= n then return "?" end
    local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No",
                    "Dc", "Ud", "Dd", "Td", "Qad", "Qid", "Sxd", "Spd", "Ocd", "Nod" }
    local i = 1
    while n >= 1000 and i < #units do n = n / 1000; i = i + 1 end
    if i == 1 then return string.format("%d", math.floor(n + 0.5)) end
    if n >= 100 then return string.format("%.0f%s", n, units[i]) end
    return string.format("%.2f%s", n, units[i])
end
R.fmtShort = fmtShort

-- 品质基础升级成本（运行时权威表）
local function levelBaseCostOf(rarity)
    local t = Constants and Constants.LevelBaseCosts
    if type(t) == "table" and tonumber(t[rarity]) then return tonumber(t[rarity]) end
    return nil
end
local function levelCurve(L)
    if Constants and type(Constants.GetLevelCurveMultiplier) == "function" then
        local ok, v = pcall(Constants.GetLevelCurveMultiplier, L)
        if ok and tonumber(v) then return tonumber(v) end
    end
    return nil
end
local function cpsCurve(L)
    if Constants and type(Constants.GetCpsCurveMultiplier) == "function" then
        local ok, v = pcall(Constants.GetCpsCurveMultiplier, L)
        if ok and tonumber(v) then return tonumber(v) end
    end
    return nil
end

-- 等级 L 升到 L+1 的食物花费（基于当前生效的折扣系数）
local function feedCost(rarity, L)
    local base = levelBaseCostOf(rarity)
    if not base then return nil end
    local curve = levelCurve(L)
    if not curve then return nil end
    local keep = (R.feed and R.feed.keep) or tonumber(cfg.feedKeep) or 0.225
    return math.max(1, math.floor(base * curve * keep + 0.5))
end

-- 等级 L 升到 L+1 的 CPS 增益
local function feedGain(cps, L)
    local a, b = cpsCurve(L), cpsCurve(L + 1)
    if not (a and b) or a <= 0 then return nil end
    return cps * (b / a - 1)
end

--★ 从面板 ActionText 反解真实折扣（自适应账号配置，游戏改价也能跟上）
local function parseFoodText(txt)
    if type(txt) ~= "string" then return nil end
    local num, suf = txt:match("([%d%.]+)%s*([KMBTQASPO][a-zA-Z]?)%s*Food")
    if not num then
        local n2 = txt:match("([%d%.]+)%s*Food")
        return n2 and tonumber(n2) or nil
    end
    local v = tonumber(num)
    if not v then return nil end
    local m = HW_K.SUFFIX_MUL[suf] or HW_K.SUFFIX_MUL[suf:sub(1, 1)] or 1
    return v * m
end
R.parseFoodText = parseFoodText

-- 单个台子快照
local function feedSnapshot(stand)
    local a = {}
    pcall(function() a = stand:GetAttributes() end)
    local node = stand:FindFirstChild("PromptNode_Pickup")
    local pr = node and node:FindFirstChild("LevelUpPrompt")
    local act = nil
    if pr then pcall(function() act = pr.ActionText end) end
    -- 只认真正的"升级"提示：ActionText 必须同时出现 Level Up 与 Food。
    -- 机器的 "Skip (Robux)"、取回角色的 "Pick Up" 一律不算，
    -- 杜绝把付费按钮或别的家具提示当成喂食入口（用户实测踩到过）。
    if pr and not (type(act) == "string" and act:find("Level Up") and act:find("Food")) then
        pr = nil
        act = nil
    end
    local prMax = node and node:FindFirstChild("MaxLevelUpPrompt")
    local actMax = nil
    if prMax then pcall(function() actMax = prMax.ActionText end) end
    return {
        stand = stand,
        prompt = pr,
        promptMax = prMax,
        nodePos = node and node.Position or nil,
        has = a.HasCharacter == true,
        name = tostring(a.CharacterName or ""),
        uid = tostring(a.CharacterUid or ""),
        rarity = tostring(a.Rarity or ""),
        mut = tostring(a.CharacterType or ""),
        level = tonumber(a.Level) or 0,
        cps = tonumber(a.CPS) or 0,
        paid = a.PaidLocked == true,
        actionText = act,
        actionTextMax = actMax,
        shownCost = parseFoodText(act),
    }
end

-- 自己的地块
local function floorStand()
    local plots = workspace:FindFirstChild("PlayerPlots")
    if not plots then return nil end
    local uid = LocalPlayer.UserId
    for _, p in ipairs(plots:GetChildren()) do
        if tonumber(p:GetAttribute("OwnerUserId") or -1) == uid then return p end
    end
    return nil
end
R.feedFloorStand = floorStand

-- 收集自己地块上的所有台子（根台子 + Purchases 台子）
local function feedStands()
    local out = {}
    local plot = floorStand()
    if not plot then return out end
    local function scan(container, pre)
        if not container then return end
        for _, c in ipairs(container:GetChildren()) do
            -- 台子签名校验：真正的升级台子必须同时具备 PromptNode_Pickup + Amount
            -- （Amount 是顶上那块带 AmountSurfaceGui 的金额牌）。
            -- 这样才不会把 Depolarizer / Garden / Lemon Stand / Research Lab 之类
            -- 恰好也带提示节点的家具误当成台子（用户实测踩到过）。
            local isStand = c:FindFirstChild("PromptNode_Pickup") ~= nil
                and c:FindFirstChild("Amount") ~= nil
            local lnm = string.lower(c.Name)
            if lnm:find("depolar") or lnm:find("garden") or lnm:find("lemon")
                or lnm:find("dock") or lnm:find("research") or lnm:find("wall") then
                isStand = false
            end
            if isStand then
                out[#out + 1] = { label = pre .. c.Name, inst = c }
            end
        end
    end
    scan(plot, "")
    scan(plot:FindFirstChild("Purchases"), "P")
    return out
end
R.feedStands = feedStands

--============================================================== 🎯 自动配置角色（AutoStand）
-- 目标：把"背包里最优的角色"配置到 34 个可用台子上（一次性总替换），并可按小时重算。
--
-- ★ 关键机制（实测确认，详见 AUTOSTAND_MECHANICS.md，改代码前务必先读）：
--   · 放上：fireproximityprompt(台子.PromptPart.PlacePrompt)        手持角色 + 6 格内
--   · 取回：fireproximityprompt(台子.PromptNode_Pickup.PickupOwnerPrompt)  台上有角色 + 6 格内
--   · 台子属性 CPS = BaseCPS × GetCpsCurveMultiplier(Level)，**不含配对加成**
--   · 台子属性 _ComboMultiplier = 3 ⟺ 该角色的配对伙伴也在这块地上（可靠信号，实测验证过）
--   · 6 个 *PAID 金台 PaidLocked=true（要 Robux）→ **永远不碰**
--   · 🚫 绝对不能 fire PurchasePrompt（付费通道）
--
-- ⚠⚠ 用户明确的策略要求：
--   1. 只放**有突变**的角色；无突变**降优先级**（不是绝对排除）
--   2. **排除 Gold / Honey**（×1.25，全游戏最垃圾，连 ×2 都不到）
--   3. 优化指标 = **CPS**（各台 CPS 之和）
--   4. 一次性总替换 + 可按小时重算
--   5. **不把花园里的角色纳入计算**，只用背包里的
--
-- ⚠ 顶层 local 只剩几个名额，所以本模块的全部内容挂在 **一个** AST 表上，不新增顶层 local。
local AST = {}
AST.MUT_RATIO = {}      -- 运行时反推出来的"突变倍率"（见 AST.calibrateMutRatio）

-- 突变在"无法从台子属性反推"时的兜底倍率表（权威值来自 Constants.TypeSystem.Multipliers）
AST.MUT_MULT = {
    Gold = 1.25, Honey = 1.25,
    Diamond = 1.5, Frozen = 1.5, Party = 1.5,
    Lava = 2, Slime = 2, Blood = 2, Electric = 2, Zombie = 2,
    Ghost = 2.5, Complexity = 2.5,
    Solar = 4, Lunar = 4, Toxic = 4,
    Sinister = 5,
    Angelic = 6, Mars = 6, Void = 6,
    Nightmare = 7,
    Dracula = 8,
    Demonic = 10,
}
AST.MUT_CN = {
    Gold = "金", Honey = "蜜", Diamond = "钻", Frozen = "冰", Party = "派对",
    Lava = "岩浆", Slime = "史莱姆", Blood = "血", Electric = "电", Zombie = "丧尸",
    Ghost = "幽灵", Complexity = "复杂", Solar = "太阳", Lunar = "月", Toxic = "毒",
    Sinister = "邪恶", Angelic = "天使", Mars = "火星", Void = "虚空",
    Nightmare = "梦魇", Dracula = "德古拉", Demonic = "恶魔",
}

-- 🚫 垃圾突变（用户明确要求排除）：×1.25，连最低可用档 ×2 都不到
AST.JUNK_MUT = { Gold = true, Honey = true }

-- 配对名单（来源：用户提供的 fandom wiki 截图，已存档 PAIRS_DATA.md）
-- ⚠ wiki 原文："The pairs are not listed anywhere -- finding them is part of the game"
--   所以这张表随时可能不全，发现新的直接往这里加即可。名字必须与游戏内一致。
-- ⚠ 数据来源：wiki 的 Module:CharData/data.json `pairs` 字段（51 组 / 70 角色），
--   名字已**归一化到游戏命名**。wiki 与游戏有 9 个角色写法不同，例如：
--     Froza→Kafka · Kamisota Ayaki→Ayaki Kamisora · Tonbi Jouma→Tenki Izuma
--     Ramilia Scarlette→Rami Scarlette · Flandra Scarlette→Flara Scarlette
--     Lunar Oblivio→Lina Oblivion · Nagira→Nazira · Nagira II→Nazira II
--     Ai Hoshi→AI Hoshi
--   本表同时修正了上一版手工抄录的 2 个错名字：
--     "Girllyfang" → "Girlyfang"（游戏里没有 Girllyfang）
--     "Summer"     → "Summer Mika"（游戏里没有 Summer）
--   （核对依据：游戏 Constants.Characters 185 条，全部 70 个名字均存在）
AST.PAIR_LIST = {
    { "AI Hoshi", "Rubie Hoshi" }, { "Ada Smasher", "Rebekka" }, { "Alucardia", "Serah Victoire" },
    { "Angelia", "Selene" }, { "Aquella", "Megumia" }, { "Askira", "Reia" },
    { "Askira II", "Reia II" }, { "Ayaki Kamisora", "Furin" }, { "C.C", "Lella" },
    { "Chiya", "Yuura" }, { "Davida Martinez", "Lucia" }, { "Davida Martinez", "Rebekka" },
    { "Emeliara", "Subara" }, { "Ferna", "Kafka" }, { "Flara Scarlette", "Rami Scarlette" },
    { "Girlyfang", "Serah Victoire" }, { "Harla Quinne", "Toxic Ivy" }, { "Hatsuna Mika", "Teto" },
    { "Homara Akeni", "Madoki Kaneme" }, { "Ibukia", "Irohia" }, { "Ichi Naka", "Itsi Naka" },
    { "Ichi Naka", "Miku Naka" }, { "Ichi Naka", "Nina Naka" }, { "Ichi Naka", "Yotso Naka" },
    { "Itsi Naka", "Miku Naka" }, { "Itsi Naka", "Nina Naka" }, { "Itsi Naka", "Yotso Naka" },
    { "Izuma Miyamira", "Kyouka Hora" }, { "Kaneko", "Riza" }, { "Kaneko", "Riza II" },
    { "Kaneko", "Touki" }, { "Kaneko II", "Riza" }, { "Kaneko II", "Riza II" },
    { "Kaneko II", "Touki" }, { "Kinja Hikari", "Kira Ho" }, { "Linnete Yagami", "Misa Amara" },
    { "Lucia", "Rebekka" }, { "Makia", "Yuta Chan" }, { "Miku Naka", "Nina Naka" },
    { "Miku Naka", "Yotso Naka" }, { "Mimio", "Sheela" }, { "Nina Naka", "Yotso Naka" },
    { "Orihira", "Rukira" }, { "Rami", "Remi" }, { "Rena Yamashira", "Tenki Izuma" },
    { "Roxia", "Rudeus Chan" }, { "Roxia", "Sylphette" }, { "Rudeus Chan", "Sylphette" },
    { "Summer Mika", "Teto" }, { "Summer Mika II", "Teto" }, { "Yang", "Yin" },
}

-- 反向索引：角色名 -> { 伙伴1, 伙伴2, ... }
AST.PAIR_OF = {}
for _, pr in ipairs(AST.PAIR_LIST) do
    local a, b = pr[1], pr[2]
    AST.PAIR_OF[a] = AST.PAIR_OF[a] or {}
    table.insert(AST.PAIR_OF[a], b)
    AST.PAIR_OF[b] = AST.PAIR_OF[b] or {}
    table.insert(AST.PAIR_OF[b], a)
end

-- 兼容别名（游戏内名字可能是全名/API 名），避免因名字写法差异漏掉配对
AST.NAME_ALIAS = {
    ["Madoki Kaneme"] = { "Madoki Kaneme", "Madoki" },
    ["Homara Akeni"] = { "Homara Akeni", "Homara" },
}

-- 🚫🚫🚫 配对黑名单（用户明确要求，2026-10）
--
-- 用户原话："我点了立即配对，脚本又在配垃圾了，直接弄黑名单系统吧，指定哪些配对不要"
--
-- 背景（实测反复踩到）：
--   `Reia II ⇄ Askira II`（Ascended，初始 3.4e5 / 9.1e5）被摆到 P37/P38，
--   顶掉了原本给 `Summer Mika II`（1.4e10）当配对位的 Teto，
--   直接损失 5.5e10 的 ×3 收益。用户把这类"两个都是垃圾还占着好台位"的组合
--   称为**垃圾配对**。
--
-- 为什么必须做成黑名单而不是靠算法判断：
--   ① 配对价值随等级变化，算法很难稳定判断"现在值不值"；
--   ② 用户对某些配对有**明确的偏好/厌恶**，这是领域知识，算法猜不出来；
--   ③ 一劳永逸 —— 点"立即配对"不该再出现已经否掉的组合。
--
-- 配置格式（`cfg.astBlockedPairs`）：每条用 "+" 连接两个名字，条目之间用 , / ; 分隔。
--   顺序无关（内部会归一化）。例：
--     "Reia II+Askira II,Remi+Rami,Sheela+Mimio"
function AST.pairKey(a, b)
    local x, y = tostring(a or ""), tostring(b or "")
    if x > y then x, y = y, x end
    return x .. "\1" .. y
end

function AST.pairBlacklist()
    local t = {}
    local s = tostring(cfg.astBlockedPairs or "")
    if s == "" then return t end
    for chunk in string.gmatch(s, "[^/,;]+") do
        local c = string.gsub(chunk, "^%s*(.-)%s*$", "%1")
        if c ~= "" then
            local a, b = string.match(c, "^(.-)%s*[+&]%s*(.+)$")
            if a and b then
                a = string.gsub(a, "^%s*(.-)%s*$", "%1")
                b = string.gsub(b, "^%s*(.-)%s*$", "%1")
                t[AST.pairKey(a, b)] = true
            end
        end
    end
    return t
end

-- 判断某一对是否被用户拉黑（顺序无关，且会解析别名归一化）
function AST.pairBlocked(a, b)
    local bl = AST.pairBlacklist()
    if next(bl) == nil then return false end
    local na, nb = tostring(a or ""), tostring(b or "")
    if na == "" or nb == "" then return false end
    if bl[AST.pairKey(na, nb)] then return true end
    local function canon(n)
        if AST.PAIR_OF[n] then return n end
        for c, aliases in pairs(AST.NAME_ALIAS) do
            for _, al in ipairs(aliases) do
                if n == al then return c end
            end
        end
        return n
    end
    local ca, cb = canon(na), canon(nb)
    if ca ~= na or cb ~= nb then
        if bl[AST.pairKey(ca, cb)] then return true end
    end
    return false
end

-- 判断这个角色是否有已知配对伙伴（**已剔除用户拉黑的组合**）
function AST.partnerNames(name)
    local n = tostring(name or "")
    local function filt(list)
        if not list then return nil end
        local bl = AST.pairBlacklist()
        if next(bl) == nil then return list end
        local out = {}
        for _, p in ipairs(list) do
            if not bl[AST.pairKey(n, p)] then out[#out + 1] = p end
        end
        if #out == 0 then return nil end
        return out
    end
    if AST.PAIR_OF[n] then return filt(AST.PAIR_OF[n]) end
    for canon, aliases in pairs(AST.NAME_ALIAS) do
        for _, al in ipairs(aliases) do
            if n == al then return filt(AST.PAIR_OF[canon]) end
        end
    end
    return nil
end

-- 💞 判断某个角色名是否"正在台上当别人的配对伙伴"
--
-- 用户规则（明确选择 A，2026-10）：
--   "无突变角色默认不上台，**但如果它是台上某角色的配对伙伴，则允许**"
--
-- 背景：`Teto` 无突变、初始只有 375，但它和 `Summer Mika II` 是官方配对。
--   实测把它放到 P12（夹在 P11/P13 之间）能让两边各吃 ×3，合计 +1.578e10。
--   而用户背包里有 **1196 个 Teto**（摘要 `c` 字段），几乎是免费资源。
--
-- ⚠ 关键设计：**不信任调用方传来的 `pairWith` 字段**，而是脚本自己查
--   `AST.PAIR_OF` + 台上实际角色名。这样无论哪条规划路径都不可能绕过规则。
function AST.isPairSupportFor(name, standName)
    local n = tostring(name or "")
    local on = tostring(standName or "")
    if n == "" or on == "" then return false end
    local ps = AST.partnerNames(n)
    if not ps then return false end
    for _, p in ipairs(ps) do
        if p == on then return true end
    end
    return false
end

R.astInfo = {
    pairs = #AST.PAIR_LIST,
    note = "自动配置角色（预览）",
}
R.astPairList = AST.PAIR_LIST
R.astPairOf = AST.PAIR_OF
-- ⚠ 必须导出这些**函数本身**
--   踩过的坑：只导出 `astPairOf` 表，导致 `R.partnerNames` / `R.pairBlocked` /
--   `R.isPairSupportFor` 全是 nil，执行器里的守卫静默失效（只能走
--   `entry.pairWith` 那条不可靠的兜底路径）。
R.partnerNames = AST.partnerNames
R.pairKey = AST.pairKey
R.pairBlacklist = AST.pairBlacklist
R.pairBlocked = AST.pairBlocked
R.isPairSupportFor = AST.isPairSupportFor
R.astMutMult = AST.MUT_MULT
R.astMutCn = AST.MUT_CN
R.astJunkMut = AST.JUNK_MUT

-- 由 背包条目 得到"等级 1 时的有效 CPS"
--
-- ★★★ 实测结论（血泪，别再改回去）★★★
--   **背包的 `bc` 字段已经内含突变倍率，绝不能再乘一次！**
--
--   证据链（一次干净的三方对照）：
--     背包: C|Yotso Naka|Void|L396     bc = 231512287
--     台上: Yotso Naka（无突变）Lv1     BaseCPS = 248993   ← 无突变角色的纯常数基础值
--     推算: 231512287 ÷ 248993 = 929.8
--           再去掉等级曲线（L396 → 155）: 929.8 ÷ 155 = **6.0 = Void 的倍率** ✅
--     ⇒ bc = 纯常数基础 × 突变倍率（且**不含等级曲线**）。
--
--   我一开始又乘了一遍官方倍率，结果把 Lucia 的 2.4e9 放大成天文数字，
--   算出 "+3157% 提升" 这种荒谬结论（正常量级是 +70%）。
--
--   ⇒ 所以这里**直接返回 bc**。AST.MUT_MULT 只在"需要单独知道倍率数值"时使用
--     （例如界面显示、或者某些角色 bc 意外缺失时的兜底）。
function AST.baseCpsOf(entry)
    local bc = tonumber(entry and entry.bc) or 0
    return bc, true
end

-- 兜底：万一某个角色的 bc 缺失，才用"常数基础 × 突变倍率"补出来
function AST.baseCpsFallback(entry)
    local bc = tonumber(entry and entry.bc) or 0
    if bc > 0 then return bc end
    local name = tostring(entry and entry.n or "")
    local ty = tostring(entry and entry.ty or "")
    local ch = Constants and Constants.Characters and Constants.Characters[name]
    local c = ch and tonumber(ch.CPS) or 0
    if c <= 0 then return 0 end
    return c * (ty == "" and 1 or (AST.MUT_MULT[ty] or 1))
end

-- 每级 CPS 增益（用于评估"这个台子值不值得占坑"）
function AST.gainPerLevel(cps, level)
    local a, b = cpsCurve(level), cpsCurve(level + 1)
    if not (a and b) or a <= 0 then return 0 end
    return cps * (b / a - 1)
end

-- 🔢 在**食物预算**内，把这个角色练到能到的最高等级
--   返回 { level, cps, cost, reachedTarget }，或 nil（预算内完全没提升空间）
--
-- ★★★ 这是本功能最关键的一段（用户明确要求，别改成"硬追原等级"）★★★
--   用户原话："加个食物预算上限，换上去的新角色只练到『食物能承受』的等级，
--             而不是盲目追到台子原等级。不过最好是达到换之前的角色 CPS。"
--
--   为什么必须这样做：实测发现用户的台子是「高配低底」（Tako 基础 375、Lv676），
--   而背包里是「低配高底」（Davida 基础 2.9e9、Lv1）。
--   若要求"练到顶平原 CPS"，成本会高达 **17T 食物**（几百年才攒得出）；
--   若"完全不练"，换上去等级不足反而亏。
--   ⇒ 正确做法是**在预算内尽量练**，并如实报告"够不够顶平原 CPS"：
--        · 够 -> reachedTarget = true，这台换了不亏还有赚
--        · 不够 -> 也返回（让上层按 gain/cost 决定值不值得），但标记出来
--
-- ⚠ 起点不是 1 级！角色上台后继承**它自己的等级**（背包 `bl`），只对更高的部分计费。
--   实测踩到：Yotso Naka 背包是 `C|Yotso Naka|Void|L396`，按 1 级算得出
--   "零成本换人还能 +170 亿"的荒谬结论。
function AST.levelForCps(effBase, targetCps, rarity, startLevel, budget)
    if not (effBase and effBase > 0) then return nil end
    local start = math.max(1, math.floor(tonumber(startLevel) or 1))
    local startCps = effBase * (cpsCurve(start) or 1)
    -- 目标为 0（空台）或本来就够 -> 零成本
    if not (targetCps and targetCps > 0) or startCps >= targetCps then
        return { level = start, cps = startCps, cost = 0,
                 reachedTarget = (not (targetCps and targetCps > 0)) or startCps >= targetCps }
    end
    local MAX_LEVEL = math.max(start, math.floor(tonumber(cfg.astMaxLevel) or 800))
    local MAX_COST = tonumber(cfg.astMaxCost) or 1e15
    local cap = tonumber(budget)
    if cap and cap > 0 then
        MAX_COST = math.min(MAX_COST, cap)     -- ★ 预算上限（<=0 或 nil 表示不限）
    end
    local base = levelBaseCostOf(rarity)
    local keep = (R.feed and R.feed.keep) or tonumber(cfg.feedKeep) or 0.225
    local lv, cost, bestLv, bestCps = start, 0, nil, nil
    while lv <= MAX_LEVEL do
        local cur = cpsCurve(lv) or 1
        local cps = effBase * cur
        if cps > startCps then
            bestLv, bestCps = lv, cps          -- 记录"预算内达到过的最好等级"
        end
        if cps >= targetCps then
            return { level = lv, cps = cps, cost = cost, reachedTarget = true }
        end
        if base then
            local cv = levelCurve(lv)
            if cv then cost = cost + base * cv * keep end
        end
        if cost > MAX_COST then break end       -- 预算用尽 -> 停在最后一个够得着的等级
        lv = lv + 1
    end
    if not bestLv then return nil end           -- 预算内毫无提升
    return { level = bestLv, cps = bestCps, cost = cost, reachedTarget = false }
end

-- 单个"背包角色"的评分（含排序用的全部信息）
function AST.score(entry)
    local name = tostring(entry.n or "")
    local mut = tostring(entry.ty or "")
    local lvl = tonumber(entry.bl) or 1
    local raw, fromRatio = AST.baseCpsOf(entry)
    -- ★★★ 把"等级1的基础CPS"还原出来（实测抓到的严重 bug 的修复）★★★
    --   背包的 `bc` **已经含了该角色自己等级的曲线**：
    --        bc = 常数 × 突变倍率 × cpsCurve(它自己的等级)
    --   证据：Davida Lava 在台上 Lv373 实测 CPS = 2.906e9，而背包 bc 也正好 = 2.906e9。
    --   但 `AST.levelForCps(effBase, ...)` 的语义是"**等级1时**的CPS"，
    --   它内部会再乘一次 cpsCurve(目标等级) —— 于是曲线被**乘了两次**，
    --   算出 4.035e12 这种天文数字（正确量级应是 1.5e9），导致 +2636% 的假收益。
    --   ⇒ 必须除掉它自己等级的曲线，得到真正的"等级1价值"，再交给 levelForCps。
    local base = raw
    do
        local cv0 = cpsCurve(lvl)
        if cv0 and cv0 > 0 then base = raw / cv0 end
    end
    local junk = AST.JUNK_MUT[mut] == true
    local hasMut = (mut ~= "")
    local partners = AST.partnerNames(name)
    local bonus, why = 0, {}
    if junk then
        bonus = bonus - 1e18
        why[#why + 1] = "垃圾突变(" .. tostring(AST.MUT_CN[mut] or mut) .. ")"
    elseif not hasMut then
        bonus = bonus - 1e15
        why[#why + 1] = "无突变(降权)"
    end
    if partners then
        bonus = bonus + 1e12
        why[#why + 1] = "可配对:" .. table.concat(partners, "/")
    end
    return {
        key = entry.key,
        name = name,
        rarity = tostring(entry.ra or ""),
        mut = mut, mutCn = AST.MUT_CN[mut] or mut,
        level = lvl,
        -- ⚠ `effBase` 必须是"等级1价值"，`rawBase` 保留原始 bc 以便界面显示/排查
        base = base, effBase = base, rawBase = raw, hasMut = hasMut, junk = junk,
        partners = partners,
        score = base + bonus,
        why = table.concat(why, " · "),
        -- ⚠⚠ 放置时必须用**背包里的真实 key**，绝不能自己拼字符串！
        --   key 格式是 `C|<名>|<突变>|L<等级>`（无突变时 `C|<名>||L<等级>`），
        --   但游戏可能对某些角色用别名/特殊写法，拼错了就会 fire 一个无效键。
        holdKey = entry.key and tostring(entry.key) or nil,
    }
end

-- ⚠⚠ 不能用 feedSnapshot()！它要求 prompt 的 ActionText 里同时有 "Level Up" 和 "Food"，
--   而 prompt 只在**玩家站在 6 格内**时才会被服务端填好 ActionText。
--   自动配置需要一次读全部 34 个台子，所以这里直接读属性，不依赖 prompt。
function AST.slotSnap(inst)
    local a = {}
    pcall(function() a = inst:GetAttributes() end)
    local paid = false
    pcall(function() paid = inst:GetAttribute("PaidLocked") == true end)
    -- 位置：用于"相邻台子"判定（配对要求同一行相邻）
    local node = inst:FindFirstChild("PromptNode_Pickup")
    local pos = node and node.Position or nil
    if not pos then
        local pf = inst:FindFirstChild("PromptPart")
        pos = pf and pf.Position or nil
    end
    return {
        stand = inst,
        pos = pos,
        has = a.HasCharacter == true,
        name = tostring(a.CharacterName or ""),
        mut = tostring(a.CharacterType or ""),
        rarity = tostring(a.Rarity or ""),
        level = tonumber(a.Level) or 0,
        base = tonumber(a.BaseCPS) or 0,
        cps = tonumber(a.CPS) or 0,
        combo = tonumber(a._ComboMultiplier) or nil,
        paid = paid,
    }
end

-- ★ 动态建立"突变倍率反推表"：用台上真实角色的 BaseCPS ÷ 该角色的常数基础CPS。
--   这样得到的是**这个账号、这个游戏版本的真实倍率**，比硬编码官方表更可靠。
--   只在表还空的时候做一次；值是"同一突变多个样本的中位数"的近似（取众数即可）。
function AST.calibrateMutRatio()
    AST.MUT_RATIO = AST.MUT_RATIO or {}
    local sum, cnt = {}, {}
    for _, s in ipairs(feedStands()) do
        local snap = AST.slotSnap(s.inst)
        if snap.has and snap.mut ~= "" and snap.base > 0 then
            local ch = Constants and Constants.Characters and Constants.Characters[snap.name]
            local c = ch and tonumber(ch.CPS) or nil
            if c and c > 0 then
                local r = snap.base / c
                if r > 0.5 then      -- 过滤掉明显不对的样本
                    sum[snap.mut] = (sum[snap.mut] or 0) + r
                    cnt[snap.mut] = (cnt[snap.mut] or 0) + 1
                end
            end
        end
    end
    local n = 0
    for mut, s in pairs(sum) do
        AST.MUT_RATIO[mut] = s / cnt[mut]
        n = n + 1
    end
    return n
end

-- 枚举当前地块上"可放置角色的台子"（排除未解锁金台）
function AST.slots()
    local out = {}
    for _, s in ipairs(feedStands()) do
        local snap = AST.slotSnap(s.inst)
        if not snap.paid then
            snap.label = s.label
            out[#out + 1] = snap
        end
    end
    return out
end

-- 🔗 合并两个单台方案为一个"配对方案"
--   ⚠ 只在"两个方案要放的角色恰好互为配对伙伴"时才有意义（调用方负责判断）。
--   配对生效时两个人**各得 ×mult**（官方文案：Both characters receive a 3x buff），
--   所以额外收益 = 各自 toCps × (mult - 1)。
function AST.pairMerge(e1, e2, mult)
    mult = mult or 3
    local g1 = (e1.toCps or 0) * (mult - 1)
    local g2 = (e2.toCps or 0) * (mult - 1)
    local m = {}
    for k, v in pairs(e1) do m[k] = v end
    m.pairWith = e2.label
    m.pairName = e2.toName
    m.pairMult = mult
    m.pairSumCps = (e1.toCps or 0) + (e2.toCps or 0)
    m.pairBonus = g1 + g2
    m.gain = (e1.gain or 0) + g1
    m.cost = (e1.cost or 0) + (e2.cost or 0)
    m.eff = m.gain / math.max(m.cost, 1)
    m.why = tostring(e1.why or "") .. " · 🔗配对×" .. mult
    m.changed = true
    return m
end

-- 🔗 相邻判定（配对要求"neighbouring stands in the same row"）
--
-- 台子布局是**立体网格**：同一 (x,z) 上叠了 3 层（y 相差 17），水平方向相邻格距 10。
-- 实测坐标样本：
--   P11 (5755.1,  79.4, 1074.2)    P31 (5755.1, 113.4, 1074.2)  ← 同 x,z，不同层
--   P12 (5765.1,  79.4, 1074.2)                                   ← 同 y，x 差 10
-- 所以：
--   · **同一行** = y 接近（容差 8，足以区分 17 的层间距）
--   · **相邻**   = 水平距离 ≤ 12（覆盖 10 的格距 + 余量）
-- ⚠ 这个定义是**推断**的，游戏没公开"相邻"的精确算法。所以：
--   ① 配对收益做成可开关（cfg.astPairBonus），默认**开**但假设倍率写在配置里可改；
--   ② 实际是否生效，用户可以看游戏里收益有没有变粉色。
function AST.adjacent(a, b)
    local pa, pb = a.pos, b.pos
    if not (pa and pb) then return false end
    if math.abs(pa.Y - pb.Y) > 8 then return false end          -- 必须同一行
    local dx, dz = pa.X - pb.X, pa.Z - pb.Z
    return (dx * dx + dz * dz) <= 12 * 12                        -- 水平相邻
end

-- 为一组"台子"建邻接表
function AST.buildAdjacency(slots)
    local adj = {}
    for i = 1, #slots do adj[i] = {} end
    for i = 1, #slots do
        for j = i + 1, #slots do
            if AST.adjacent(slots[i], slots[j]) then
                adj[i][#adj[i] + 1] = j
                adj[j][#adj[j] + 1] = i
            end
        end
    end
    return adj
end

-- 🔗 配对优化：实现已**内联在 AST.plan 的步骤 ③b**里（因为要在预算裁剪之前跑，
--   而且需要能和"单台最优"互相释放/重新分配候选）。
--   这里只保留相邻判定用的 AST.adjacent / AST.buildAdjacency 两个工具函数。

-- 🎚 稀有度白名单（用户明确要求）
--   用户原话："干脆出一个功能，指定放哪些品质，从这些品质上计算，
--             我现在主要的都是ancient和celestial"
--   `cfg.astRarities` 是逗号分隔的品质名，空字符串 = 不限制（全部允许）。
--   在 UI 上是一组勾选框，比手打字符串友好。
function AST.rarityAllowed(rarity)
    local r = tostring(rarity or "")
    if r == "" then return false end
    -- ① 黑名单优先：命中就**永久否决**（硬性，与白名单无关）
    local blk = tostring(cfg.astBlockedRarities or "")
    if blk ~= "" then
        for piece in string.gmatch(blk, "[^,]+") do
            if tostring(piece):gsub("^%s+", ""):gsub("%s+$", "") == r then return false end
        end
    end
    -- ② 白名单：空 = 不限制
    local spec = tostring(cfg.astRarities or "")
    if spec == "" then return true end
    for piece in string.gmatch(spec, "[^,]+") do
        if tostring(piece):gsub("^%s+", ""):gsub("%s+$", "") == r then return true end
    end
    return false
end

-- 🚫 执行"品质黑名单"的第三重效果：把**已经在台上**的黑名单角色自动拿下来
--
-- 用户明确要求："在台上就自动拿下来"
-- 为什么需要它：`rarityAllowed` 只能阻止"往上放"，管不了存量 ——
--   而用户说"现在家里的配置已经烂到惨目忍睹了"，存量才是主要问题。
-- 返回：拿下来的台子数
function AST.enforceRarityBlock()
    if cfg.astEnabled ~= true then return 0 end
    if cfg.astBlockAutoPickup == false then return 0 end
    local blk = tostring(cfg.astBlockedRarities or "")
    if blk == "" then return 0 end
    if R._astRunning then return 0 end
    local hits = {}
    for _, sl in ipairs(AST.slots()) do
        if sl.has and sl.name ~= "" and not AST.rarityAllowed(sl.rarity) then
            hits[#hits + 1] = sl
        end
    end
    if #hits == 0 then return 0 end
    -- 占位 + 让路（和换人用同一把锁，避免和喂食/换人抢角色）
    if not R.busySuggest("配置角色", "拿下黑名单角色") then return 0 end
    local n = 0
    for _, sl in ipairs(hits) do
        if not isCurrent() then break end
        local node = sl.stand:FindFirstChild("PromptNode_Pickup")
        local pick = node and node:FindFirstChild("PickupOwnerPrompt")
        if pick then
            -- 复用取回逻辑：强制"离开 -> 回来"重新武装 prompt
            local hrp = rootPart()
            if hrp then
                pcall(function() hrp.CFrame = CFrame.new(node.Position + Vector3.new(0, 40, 0)) end)
                task.wait(0.35)
                pcall(function() hrp.CFrame = CFrame.new(node.Position + Vector3.new(0, 3, 3)) end)
                task.wait(0.6)
            end
            if pick.Enabled then
                pcall(fireproximityprompt, pick)
                local t0 = os.clock()
                while isCurrent() and (os.clock() - t0) < 5 do
                    task.wait(0.2)
                    if not AST.slotSnap(sl.stand).has then
                        n = n + 1
                        log(string.format("🚫 %s 的 %s[%s] 在黑名单里，已自动拿下",
                            sl.label, tostring(sl.name), tostring(sl.rarity)),
                            Color3.fromRGB(255, 200, 90))
                        break
                    end
                end
            end
        end
        task.wait(0.2)
    end
    R.busyClear("配置角色")
    return n
end
R.astEnforceRarityBlock = AST.enforceRarityBlock

-- 🎯🎯🎯 强力换人（按"初始CPS"排序，把最强的空闲角色塞进最弱的台子）
--
-- 用户明确要求（原话）："能不能让脚本或者你自己先把全基地的那些垃圾给替换成最好的角色"
--
-- 与 `AST.plan` 的关键区别：
--   · `AST.plan` 是**逐台**决策：给每台找"最省食物就能顶平它"的候选
--     -> 弱台子（比如只有 4.6e7 的 Lucia）永远只被换成刚好 4.6e7 的角色，
--        结果是"垃圾换垃圾"，天花板永远抬不上去。
--   · 本函数是**全局**决策：
--       ① 用 **Uid** 精确判断哪些角色"真正空闲"（不在任何台子上）
--       ② 空闲角色按**初始CPS**降序，台子按**当前CPS**升序
--       ③ 一对一配对：最强 -> 最弱
--     一次就把天花板抬到位，之后靠喂食慢慢吃满。
--
-- ⚠ 不检查食物（调用方决定）；条目 cost 固定 0（这些角色通常已练好或只需少量）。
function AST.planForce(opts)
    opts = opts or {}
    local limit = tonumber(opts.limit) or 6
    local slots = AST.slots()
    local standUids = {}
    local slotList = {}
    for _, sl in ipairs(slots) do
        local uid = ""
        pcall(function() uid = tostring(sl.stand:GetAttribute("CharacterUid") or "") end)
        if uid ~= "" then standUids[uid] = sl.label end
        if sl.has and sl.name ~= "" then slotList[#slotList + 1] = sl end
    end
    local sum = fetchSummary()
    if not sum then return nil, "读不到背包" end
    local idle = {}
    for k, v in pairs(sum) do
        local ty = tostring(v.ty or "")
        local bc = tonumber(v.bc) or 0
        local ra = tostring(v.ra or "")
        if ty ~= "" and ty ~= "Gold" and ty ~= "Honey" and bc > 0 and AST.rarityAllowed(ra) then
            local uid = tostring(v.uid or "")
            if uid ~= "" and not standUids[uid] then
                local lv = tonumber(v.bl) or 1
                local cv = cpsCurve(lv) or 1
                idle[#idle + 1] = {
                    key = tostring(k), name = tostring(v.n), ra = ra, mut = ty,
                    level = lv, cps = bc, init = bc / math.max(cv, 1e-9),
                }
            end
        end
    end
    if #idle == 0 then return nil, "没有空闲的可用角色" end
    -- ★★★ 配对保护：预计算"拿走这台的角色会亏多少" ★★★
    --   ⚠ 实测踩到：`planForce` 最初把 Lv1 的 Ancient（2.8e8）放到了 P32/P29/P12 的 Teto 台上，
    --     而那三台**正在吃 Teto⇄Summer Mika II 的 ×3 配对**，拆掉要亏 70~280 亿 ——
    --     远大于 2.8e8 的收益。全局换人同样必须尊重配对，否则就是"换了个更贵的垃圾"。
    local breakLoss = {}
    do
        local pairMult = tonumber(cfg.astPairMult) or 3
        if cfg.astPairBonus ~= false then
            local idx = {}
            for i, s in ipairs(slots) do idx[s.label] = i end
            local adj = AST.buildAdjacency(slots)
            for i, sa in ipairs(slots) do
                if sa.has and sa.name ~= "" and sa.combo and sa.combo > 1
                   and AST.partnerNames(sa.name) then
                    local loss = 0
                    for _, j in ipairs(adj[i] or {}) do
                        local sb = slots[j]
                        if sb.has and sb.name ~= "" and sb.combo and sb.combo > 1 then
                            for _, pn in ipairs(AST.partnerNames(sa.name) or {}) do
                                if pn == sb.name then
                                    loss = loss + (sb.cps or 0) * (pairMult - 1)
                                    break
                                end
                            end
                        end
                    end
                    if loss > 0 then
                        loss = loss + (sa.cps or 0) * (pairMult - 1)      -- 自己也失去 ×3
                        breakLoss[sa.label] = loss
                    end
                end
            end
        end
    end
    -- 空闲角色按"当前产出"降序（可直接用的实力），台子按当前 CPS 升序
    table.sort(idle, function(a, b)
        if a.cps ~= b.cps then return a.cps > b.cps end
        return a.init > b.init
    end)
    table.sort(slotList, function(a, b) return (a.cps or 0) < (b.cps or 0) end)
    local entries = {}
    local used = {}
    for _, c in ipairs(idle) do
        if #entries >= limit then break end
        -- 找一个"换了确实更赚"的台子（净收益 = 提升 - 配对损失 > 0）
        for _, sl in ipairs(slotList) do
            if not used[sl.label] then
                local lost = breakLoss[sl.label] or 0
                local gain = (c.cps or 0) - (sl.cps or 0)
                if (gain - lost) > 0 then
                    used[sl.label] = true
                    local slInit = (sl.cps or 0) / math.max(cpsCurve(sl.level or 1) or 1, 1e-9)
                    entries[#entries + 1] = {
                        label = sl.label, stand = sl.stand,
                        fromName = sl.name, fromMut = sl.mut, fromLv = sl.level, fromCps = sl.cps or 0,
                        toName = c.name, toMut = c.mut, toMutCn = (AST.MUT_CN[c.mut] or c.mut),
                        toRarity = c.ra, toLv = c.level, toCps = c.cps, toInit = c.init,
                        holdKey = c.key, cost = 0,
                        gain = gain, lostPair = lost,
                        reachedTarget = true, changed = true,
                        why = string.format("强力换人：初始CPS %.4g（原 %.4g）%s", c.init, slInit,
                            lost > 0 and ("· 已扣配对损失 " .. fmtShort(lost)) or ""),
                    }
                    break
                end
            end
        end
    end
    local before = 0
    for _, x in ipairs(slots) do before = before + (x.cps or 0) end
    return { entries = entries, idleCount = #idle, slotCount = #slotList, cpsBefore = before }
end
R.astPlanForce = AST.planForce

-- 💞💞💞 配对优先配置（用户明确要求）
--
-- 用户原话："celestial也可以配对，我之前不是跟你说了吗，把所有配对都写进去，
--          如果配对比纯放俩不配对的好那就放配对"
-- 用户当场给的账：P37 Davida = 8.199e9，与 Lucia 配对吃 ×3 → 额外 +2.557e10，
--   远胜于"旁边放一个 ×2 突变的 Celestial"。
--   ⇒ **一个高产出角色的 ×3，比再放一个普通高产出角色更值。**
--
-- 算法（对每一对**相邻**台子二选一）：
--   ① 不配对：两台各自最强的角色，合计 = a + b
--   ② 配对  ：找"互为伙伴"的一对放上去，合计 = (a' + b') × pairMult
--   取更大者；**优先处理当前产出最高的相邻台子**（×3 绝对值收益最大）。
--
-- ⚠ 与 `AST.plan` 里"③b 配对搜索"的区别：③b 是逐台最优后的微调；
--   本函数以配对为主目标重排，能发现 ③b 看不到的组合。
-- ⚠ `limit` 控制最多重排几对，因为换人会丢台子等级。
function AST.optimizePairs(opts)
    opts = opts or {}
    local limit = tonumber(opts.limit) or 4
    local pairMult = tonumber(cfg.astPairMult) or 3
    if cfg.astPairBonus == false then return nil, "配对加成已关闭" end
    local slots = AST.slots()
    local sum = fetchSummary()
    if not sum then return nil, "读不到背包" end
    local standUids = {}
    for _, sl in ipairs(slots) do
        local uid = ""
        pcall(function() uid = tostring(sl.stand:GetAttribute("CharacterUid") or "") end)
        if uid ~= "" then standUids[uid] = sl.label end
    end
    -- 名字 -> 该名字下最强的那只（含已在台上的，因为可能要它当配对伙伴）
    local byName = {}
    for k, v in pairs(sum) do
        local ty = tostring(v.ty or "")
        local ra = tostring(v.ra or "")
        local bc = tonumber(v.bc) or 0
        if bc > 0 and ty ~= "" and ty ~= "Gold" and ty ~= "Honey" and AST.rarityAllowed(ra) then
            local nm = tostring(v.n)
            local lv = tonumber(v.bl) or 1
            local cv = cpsCurve(lv) or 1
            local cand = { key = tostring(k), name = nm, ra = ra, mut = ty, level = lv,
                           cps = bc, init = bc / math.max(cv, 1e-9),
                           uid = tostring(v.uid or "") }
            local old = byName[nm]
            if not old or cand.cps > old.cps then byName[nm] = cand end
        end
    end
    -- idleSorted：所有可用角色按【初始CPS】降序（"单放基准"用；含已在台上的，
    --   因为 canUse() 会判断它是否被别的台子占用）
    --
    -- ⚠⚠⚠ 必须用 init（初始CPS），**不是**当前 CPS —— 用户实测抓到的根本错误：
    --   用户原话："这两个角色（Yotso Naka/Nina Naka）根本比不上放俩 X2 突变的
    --             celestial 升级后"
    --   数据：Yotso Naka[Void]        初始 1.494e6 · 当前 2.315e8
    --         Blayra[Celestial/Lava]  初始 4.8e7   · 当前 4.8e7
    --   ⇒ 只看"当前 CPS"会得出 "2.315e8 > 4.8e7，Yotso 更好" 的**短视结论**；
    --     但练到同等级后 Celestial Lava 是它的 **32 倍**（初始比值恒定）。
    --   游戏公式 CPS(等级L) = 初始CPS × cpsCurve(L) × 突变倍率
    --     ⇒ 初始CPS 的比值在**任何等级都不变**，它就是角色的真实价值。
    --   ⇒ 一切"谁更好"的比较都必须用 init。
    local idleSorted = {}
    for _, c in pairs(byName) do idleSorted[#idleSorted + 1] = c end
    table.sort(idleSorted, function(x, y) return (x.init or 0) > (y.init or 0) end)
    local adj = AST.buildAdjacency(slots)
    local pairsList = {}
    for i, sa in ipairs(slots) do
        for _, j in ipairs(adj[i] or {}) do
            local sb = slots[j]
            if j > i and sa.has and sb.has then
                pairsList[#pairsList + 1] = { a = sa, b = sb, sum = (sa.cps or 0) + (sb.cps or 0) }
            end
        end
    end
    table.sort(pairsList, function(x, y) return x.sum > y.sum end)
    local used, entries = {}, {}
    for _, pr in ipairs(pairsList) do
        if #entries >= limit * 2 then break end
        if not used[pr.a.label] and not used[pr.b.label] then
            local base = (pr.a.cps or 0) + (pr.b.cps or 0)
            -- ⚠⚠⚠ 关键修正（用户实测抓到的两个根本缺陷）：
            --
            -- 缺陷①：旧代码用 `pred(c, sl) = c.init * cpsCurve(sl.level)` 预测产出，
            --   前提是"台子等级会保留"。**实测证明这是错的** —— 等级跟着角色走，
            --   换人后台子用新角色自己的等级。所以旧预测严重高估，导致"换了反而降级"。
            --   ⇒ 现在一律用**角色自己的 CPS**（`c.cps`），它包含了角色当前等级，
            --     这是唯一可靠的数字，也是游戏里实际会显示的值。
            --
            -- 缺陷②：旧代码只比较"配对 vs 现状"，没有和"放两个最强的角色"比。
            --   用户原话（核心判据）：
            --     "Teto 虽然垃圾，但是配对之后一个米卡直接 ×3，从 4B/s 变成 12B/s，
            --      不比现在纯两个夏日米卡放在一起只有 8B/s 好多了吗？"
            --   ⇒ 正确比较：
            --       ① 配对  = (A + B) × pairMult
            --       ② 单放  = 两台各自能拿到的**最强空闲角色**之和（没那么多强者时自然落空）
            --     配对更大就配对。
            local function canUse(c)
                if c.uid == "" then return true end
                local owner = standUids[c.uid]
                return (owner == nil) or (owner == pr.a.label) or (owner == pr.b.label)
            end
            -- ② 单放基准：各台取一个"最强的可用角色"（互不重复）
            local s1, s2 = nil, nil
            for _, c in ipairs(idleSorted) do
                if canUse(c) and c ~= s1 then
                    s1 = c
                    break
                end
            end
            for _, c in ipairs(idleSorted) do
                if canUse(c) and c ~= s1 then
                    s2 = c
                    break
                end
            end
            local singleVal = (s1 and s1.cps or 0) + (s2 and s2.cps or 0)
            local bestVal = singleVal
            local bestPair = nil
            -- ① 配对方案
            for nm, ca in pairs(byName) do
                local ps = AST.partnerNames(nm)
                if ps then
                    for _, pn in ipairs(ps) do
                        local cb = byName[pn]
                        if cb and ca ~= cb and canUse(ca) and canUse(cb) then
                            local val = ((ca.cps or 0) + (cb.cps or 0)) * pairMult
                            if val > bestVal then
                                bestVal = val
                                bestPair = { ca = ca, cb = cb, pa = ca.cps, pb = cb.cps }
                            end
                        end
                    end
                end
            end
            if bestPair and bestVal > base then
                used[pr.a.label] = true
                used[pr.b.label] = true
                entries[#entries + 1] = {
                    label = pr.a.label, stand = pr.a.stand,
                    fromName = pr.a.name, fromLv = pr.a.level, fromCps = pr.a.cps or 0,
                    toName = bestPair.ca.name, toMut = bestPair.ca.mut,
                    toMutCn = (AST.MUT_CN[bestPair.ca.mut] or bestPair.ca.mut),
                    toRarity = bestPair.ca.ra, toLv = bestPair.ca.level, toCps = bestPair.pa,
                    holdKey = bestPair.ca.key, cost = 0, gain = bestVal - base,
                    reachedTarget = true, changed = true, pairWith = pr.b.label,
                    pairName = bestPair.cb.name, pairMult = pairMult,
                    why = string.format("💞配对×%d：与 %s 的 %s 组合，合计 %.4g -> %.4g",
                        pairMult, pr.b.label, bestPair.cb.name, base, bestVal),
                }
                entries[#entries + 1] = {
                    label = pr.b.label, stand = pr.b.stand,
                    fromName = pr.b.name, fromLv = pr.b.level, fromCps = pr.b.cps or 0,
                    toName = bestPair.cb.name, toMut = bestPair.cb.mut,
                    toMutCn = (AST.MUT_CN[bestPair.cb.mut] or bestPair.cb.mut),
                    toRarity = bestPair.cb.ra, toLv = bestPair.cb.level, toCps = bestPair.pb,
                    holdKey = bestPair.cb.key, cost = 0, gain = 0,
                    reachedTarget = true, changed = true, pairWith = pr.a.label,
                    pairName = bestPair.ca.name, pairMult = pairMult,
                    why = string.format("💞配对×%d：与 %s 的 %s 组合（收益记在 %s）",
                        pairMult, pr.a.label, bestPair.ca.name, pr.a.label),
                }
            end
        end
    end
    return { entries = entries, pairCount = math.floor(#entries / 2), pairMult = pairMult }
end
R.astOptimizePairs = AST.optimizePairs

-- 🎯 基于【初始CPS】的自动换人（用户明确要求："我要的是脚本能理解这个错误"）
--
-- 为什么需要它：用户点"立即切换"没反应，因为那条路径走的是 `AST.plan`
--   （保守模式：只执行 `cost<=0 且顶平` 的项），而 `planForce` / `optimizePairs`
--   算出来的建议**从来没有被执行过**。
--
-- ★ 核心判据（用户反复强调的真理）：
--     游戏公式 CPS(等级L) = 初始CPS × cpsCurve(L) × 突变倍率
--     ⇒ 初始CPS 的比值在**任何等级都恒定** ⇒ 它才是角色的真实价值。
--     "当前CPS 高"只是因为等级喂得高，不代表更好。
--     实例：Yotso Naka 初始 1.494e6（被喂到 Lv396 → 当前 2.315e8）
--           比 Celestial Lava 初始 4.8e7 差 **32 倍**。
--
-- ★ 安全设计：
--   ① 只换"新角色初始CPS 明显更高"的台子（默认 1.2 倍门槛，避免微小抖动）
--   ② **跳过正在吃 ×3 配对的台子** —— 那些台的伙伴依赖它，换了会让伙伴掉 ×3
--      （实测教训：P37/P38 的 Teto 初始只有 375，但它们是 P36/P39 的配对位，
--        动它们会让 1.4e10 的 Summer Mika II 失去 ×3）
--   ③ 用 `AST.swapOne` 执行 —— 它自带"初始CPS 不倒退"硬性守卫作为最后一道闸
function AST.planInitUpgrade(opts)
    opts = opts or {}
    local limit = tonumber(opts.limit) or 3
    local margin = tonumber(opts.margin) or 1.2      -- 新角色初始CPS 至少是旧的 1.2 倍
    local slots = AST.slots()
    local sum = fetchSummary()
    if not sum then return nil, "读不到背包" end
    -- 台上已占用 uid
    local standUids = {}
    for _, sl in ipairs(slots) do
        local uid = ""
        pcall(function() uid = tostring(sl.stand:GetAttribute("CharacterUid") or "") end)
        if uid ~= "" then standUids[uid] = sl.label end
    end
    -- ① 空闲角色，按【初始CPS】降序
    local pool = {}
    for k, v in pairs(sum) do
        local ty = tostring(v.ty or "")
        local ra = tostring(v.ra or "")
        local bc = tonumber(v.bc) or 0
        local uid = tostring(v.uid or "")
        -- 🚫 无突变角色**绝不能上台**（用户明确要求，已强调多次）
        --   用户原话："我不是说过了没突变的角色不能上台吗"
        --   ⇒ `ty == ""` 必须排除，和 Gold/Honey 同级对待。
        if bc > 0 and ty ~= "" and ty ~= "Gold" and ty ~= "Honey" and AST.rarityAllowed(ra) then
            if uid == "" or not standUids[uid] then
                local lv = tonumber(v.bl) or 1
                local cv = cpsCurve(lv) or 1
                pool[#pool + 1] = { key = tostring(k), name = tostring(v.n), ra = ra, mut = ty,
                    level = lv, cps = bc, init = bc / math.max(cv, 1e-9) }
            end
        end
    end
    table.sort(pool, function(a, b) return a.init > b.init end)
    -- ② 台子：算它自己的初始CPS；跳过吃配对的
    local list = {}
    for _, sl in ipairs(slots) do
        if sl.has and sl.name ~= "" then
            local cv = cpsCurve(sl.level or 1) or 1
            list[#list + 1] = {
                label = sl.label, stand = sl.stand, name = sl.name, mut = sl.mut,
                rarity = sl.rarity, level = sl.level, cps = sl.cps or 0,
                init = (sl.cps or 0) / math.max(cv, 1e-9),
                combo = tonumber(sl.combo) or 0,
            }
        end
    end
    table.sort(list, function(a, b) return a.init < b.init end)
    local used, entries = {}, {}
    for _, sl in ipairs(list) do
        if #entries >= limit then break end
        -- ⚠ 跳过正在吃 ×3 配对的台子（动它会让伙伴失去 ×3）
        if sl.combo < 2 then
            for _, c in ipairs(pool) do
                if not used[c.key] and c.init > sl.init * margin then
                    used[c.key] = true
                    entries[#entries + 1] = {
                        label = sl.label, stand = sl.stand,
                        fromName = sl.name, fromLv = sl.level, fromCps = sl.cps,
                        toName = c.name, toMut = c.mut,
                        toMutCn = (AST.MUT_CN[c.mut] or c.mut),
                        toRarity = c.ra, toLv = c.level, toCps = c.cps, toInit = c.init,
                        holdKey = c.key, cost = 0,
                        gain = c.cps - sl.cps,
                        reachedTarget = true, changed = true,
                        why = string.format("初始CPS 升级：%.4g → %.4g（%.1f 倍）",
                            sl.init, c.init, c.init / math.max(sl.init, 1e-9)),
                    }
                    break
                end
            end
        end
    end
    return { entries = entries, poolSize = #pool, margin = margin }
end
R.astPlanInitUpgrade = AST.planInitUpgrade

-- 🕳️➡️💞 空台自动补"配对位"（用户明确指出的缺失功能）
--
-- 用户原话："我把那两个垃圾配对去掉，想试试让脚本重新放 teto 上去给两个米卡配对，
--          脚本居然不会？？？"
--
-- 缺口分析：已有功能只会**换人**（台上有 A 换成 B），
--   从来不会"发现某个**空台**旁边有个**没配对的角色**，于是主动去背包找它的伙伴放上去"。
--   所以用户手动清空 P37/P38 后，脚本完全不知道该干什么。
--
-- 算法：
--   ① 找所有**空台**（has == false）
--   ② 对每个空台，看它**相邻**的台子上有没有"有角色但没在吃配对"的（`_ComboMultiplier` < mult）
--   ③ 有则去背包找那位邻居的**配对伙伴**（`AST.partnerNames`，已剔除用户拉黑的组合）
--   ④ 排序：优先让**当前CPS 最高**的邻居吃到配对（×3 的绝对值收益最大）
--   ⑤ 门槛：邻居当前CPS × (mult-1) 必须 > 伙伴自身价值，否则不值得占这个台位
--
-- ⚠ 只往**空台**放，绝不动已有角色的台（避免拆掉别的配对）。
function AST.planFillPairSlots(opts)
    opts = opts or {}
    local limit = tonumber(opts.limit) or 4
    local mult = tonumber(cfg.astPairMult) or 3
    if cfg.astPairBonus == false then return nil, "配对加成已关闭" end
    local slots = AST.slots()
    local sum = fetchSummary()
    if not sum then return nil, "读不到背包" end
    local standUids = {}
    for _, sl in ipairs(slots) do
        local uid = ""
        pcall(function() uid = tostring(sl.stand:GetAttribute("CharacterUid") or "") end)
        if uid ~= "" then standUids[uid] = sl.label end
    end
    local empties = {}
    for _, sl in ipairs(slots) do
        if not sl.has then empties[#empties + 1] = sl end
    end
    if #empties == 0 then return { entries = {}, emptyCount = 0, note = "没有空台" } end
    local adj = AST.buildAdjacency(slots)
    local idx = {}
    for i, s in ipairs(slots) do idx[s.label] = i end
    local jobs = {}
    for _, e in ipairs(empties) do
        local ei = idx[e.label]
        for _, j in ipairs(adj[ei] or {}) do
            local nb = slots[j]
            if nb.has and nb.name ~= "" then
                local nbm = tonumber(nb.combo) or 0
                if nbm < mult then
                    local gain = (nb.cps or 0) * (mult - 1)
                    if gain > 0 then
                        jobs[#jobs + 1] = { empty = e, nb = nb, gain = gain }
                    end
                end
            end
        end
    end
    table.sort(jobs, function(x, y) return x.gain > y.gain end)
    local used, entries = {}, {}
    for _, jb in ipairs(jobs) do
        if #entries >= limit then break end
        if not used[jb.empty.label] then
            local partners = AST.partnerNames(jb.nb.name)
            if partners then
                for _, pn in ipairs(partners) do
                    local best = nil
                    for k, v in pairs(sum) do
                        if tostring(v.n) == pn then
                            local ty = tostring(v.ty or "")
                            local ra = tostring(v.ra or "")
                            local bc = tonumber(v.bc) or 0
                            local uid = tostring(v.uid or "")
                            local busy = (uid ~= "" and standUids[uid] ~= nil)
                            if bc > 0 and not busy and AST.rarityAllowed(ra)
                               and ty ~= "Gold" and ty ~= "Honey" then
                                local lv = tonumber(v.bl) or 1
                                local cv = cpsCurve(lv) or 1
                                local rec = { key = tostring(k), name = pn, ra = ra, mut = ty,
                                              level = lv, cps = bc, init = bc / math.max(cv, 1e-9) }
                                if not best or rec.cps > best.cps then best = rec end
                            end
                        end
                    end
                    if best and jb.gain > best.cps then
                        used[jb.empty.label] = true
                        entries[#entries + 1] = {
                            label = jb.empty.label, stand = jb.empty.stand,
                            fromName = "", fromLv = 0, fromCps = 0,
                            toName = best.name, toMut = best.mut,
                            toMutCn = (AST.MUT_CN[best.mut] or best.mut),
                            toRarity = best.ra, toLv = best.level, toCps = best.cps,
                            toInit = best.init,
                            holdKey = best.key, cost = 0, gain = jb.gain,
                            reachedTarget = true, changed = true,
                            pairWith = jb.nb.label, pairName = jb.nb.name, pairMult = mult,
                            why = string.format("🕳️补配对位：让相邻 %s 的 %s（%.4g）吃 ×%d，+%.4g",
                                jb.nb.label, jb.nb.name, jb.nb.cps or 0, mult, jb.gain),
                        }
                        break
                    end
                end
            end
        end
    end
    return { entries = entries, emptyCount = #empties, mult = mult }
end
R.astPlanFillPairSlots = AST.planFillPairSlots



-- 🔍 计算一次完整的最优分配（纯计算，不动游戏）
--
-- ★★ 公平比较原则 + "练到刚好追平"（很重要，别改回去）★★
--   ① 不能拿"新角色的 1 级 CPS"去和"台上角色的高等级 CPS"比。实测教训：候选
--      Hestira 1 级只有 6.43B，而台上 Kafka 已 L508、245.9B —— 按 1 级比会得出
--      完全错误的结论。比较的是"有效基础CPS"（与等级无关的真实实力）。
--   ② 换上去之后**不盲目追平台子原等级**，而是用 AST.levelForCps 反解出
--      "刚好顶回原来那台 CPS"所需的等级 —— 整体 CPS 不下降，成本却低得多，
--      剩下的交给自动喂食慢慢升。（用户明确要求这样做）
--   ③ 受 `cfg.astFoodBudget` 预算约束：按"单位食物收益"从高到低排序，超预算就停。
--   ④ ★★★ **必须扣除"破坏现有配对"的损失**（用户实测抓到的严重缺陷）★★★
--      用户原话："拿掉 teto 之后旁边配对的夏日米卡II 少了 X3，真的可以吗？"
--      实测后果：方案里有 4 台会造成**净亏损**，合计 -876 亿 CPS，而算法却当成"提升"：
--        P32  Teto→Tatsa     +8.5e7   但破坏 Teto⇄Summer Mika II  -2.801e10  ❌
--        P36  Lucia→Mimio    +9.8e6   但破坏 Lucia⇄Davida Martinez -1.631e10 ❌
--        P38  Lucia→Blayra   +1.1e6   但破坏 Lucia⇄Davida Martinez -2.528e10 ❌
--        P12  Teto→Miku Naka  0       但破坏 Teto⇄Summer Mika II  -9.549e9  ❌
--      ⇒ 现在：先把"每台当前是否在吃配对、拿掉会损失多少"预计算好，
--        只有 `收益 > 损失` 才允许替换，并在结果里如实标出这笔损失。
function AST.plan(budget)
    budget = tonumber(budget) or tonumber(cfg.astFoodBudget) or 0
    if budget < 0 then budget = 0 end          -- 0 = 不限
    local slots = AST.slots()
    -- ① 背包评分（**每个个体一条**，绝不能按"角色名"去重！）
    --
    -- ⚠⚠⚠ 实测抓到的严重 bug（用户当场质疑："为什么不换这些好用的celestial上去"）：
    --   旧写法 `byName[sc.name]` 只保留"同名里 effBase 最高"的那一只。
    --   但**同名不同突变是完全独立的角色**！
    --   实测数据：
    --     C|Blayra|Solar|L340       CPS 1.272e10  -> 已在 P17
    --     C|Blayra|Electric|L357    CPS 6.67e9    -> **空闲，可用！**
    --     C|Blayra|Lava|L284        CPS 5.438e9   -> **空闲，可用！**
    --   去重后只留下 Solar 那只；而它已经在 P17 了，于是被"已在台上"规则排除，
    --   结果**两个空闲的强力 Blayra 全被丢掉**，算法只能去挑更弱的 Lv1 角色。
    --   ⇒ 现在按**角色 key**索引（同名多只各自独立），一个都不会丢。
    local poolAll = {}
    local sum = fetchSummary()
    if sum then
        for k, v in pairs(sum) do
            v.key = k
            local sc = AST.score(v)
            sc.uid = tostring(k)              -- 用背包 key 做唯一标识
            poolAll[#poolAll + 1] = sc
        end
    end
    -- ①b ★★★ 正式排除 Gold/Honey 与"无突变"角色（用户明确要求，实测确实漏过）★★★
    --   用户原话："我记得我说过忽略gold/honey还有无突变角色，但是还是放了"
    --   根因：旧写法只在 `AST.score` 里给它们一个**很大的负分**（-1e18 / -1e15），
    --         但**没有真排除** —— 别的候选都被占用/不可用时，它们依然会被选上来。
    --         实测漏上来的：`Rikki [Gold]`、`Miki [无突变]`、`Teto [无突变]`。
    --   ⇒ 现在是**硬排除**：直接从候选池删掉，任何台子都不会放它们。
    --     （Gold/Honey 只有 ×1.25，连最低档 ×2 都不到；无突变 = ×1。）
    do
        local kept, removed = {}, 0
        for _, sc in ipairs(poolAll) do
            if sc.junk or (not sc.hasMut) then
                removed = removed + 1
            else
                kept[#kept + 1] = sc
            end
        end
        poolAll = kept
        R._astExcluded = removed
    end
    -- ①c ★★★ 排除"已经在台子上"的角色（实测抓到的零和搬运 bug）★★★
    --   症状：计划里出现 "台子1 Kurumia Tokisora → Summer Mika II" + "台子2 Davida → Changlia"，
    --        而 Changlia 本来就在台子1 上 —— 等于把角色从 A 台搬到 B 台。
    --   后果：`cpsAfter` 用新角色在**目标台**的 CPS 累加，但 A 台失去的那部分**没人算**，
    --        于是"零和搬运"被当成纯收益，报出 +3662% 这种荒谬数字。
    --   （根因：角色上台后仍留在背包列表里，所以也进了 pool。）
    --   ⇒ 已经在台上的角色不进候选池。这同时符合用户原意："把背包里的角色放上台"。
    --   ⚠ 判定用"名字+突变"组合 —— 台上那个 Blayra 是 Solar，不该把背包里
    --     空闲的 Blayra|Electric / Blayra|Lava 也一起排除掉（同名不同突变是独立个体）。
    do
        local onStand = {}
        for _, s in ipairs(slots) do
            if s.has and s.name ~= "" then onStand[s.name .. "|" .. tostring(s.mut or "")] = true end
        end
        local kept = {}
        for _, sc in ipairs(poolAll) do
            if not onStand[sc.name .. "|" .. tostring(sc.mut or "")] then
                kept[#kept + 1] = sc
            end
        end
        poolAll = kept
    end
    -- ② 候选池按"有效基础CPS"降序
    local pool = poolAll
    table.sort(pool, function(a, b)
        if a.effBase ~= b.effBase then return a.effBase > b.effBase end
        return a.name < b.name
    end)
    -- ②b ★★★ 预计算"把某台的角色拿走会损失多少配对收益"（见函数头注释④）★★★
    --   配对生效时两个人**各得 ×3**，所以拿走 A 会让伙伴 B 从 (base×3) 掉回 base，
    --   净损失 = B当前CPS × (mult - 1)。一台可能同时与多个邻居配对，累加即可。
    --   用 `_ComboMultiplier`（= 该角色有配对伙伴在地块上）作为"这个角色参与配对"的信号。
    local breakLoss, pairNeighbor = {}, {}
    do
      local pairMult = tonumber(cfg.astPairMult) or 3
      local pairOn = cfg.astPairBonus ~= false
      local idxByLabel0 = {}
      for i, s in ipairs(slots) do idxByLabel0[s.label] = i end
      local adj0 = AST.buildAdjacency(slots)
      for i, sa in ipairs(slots) do
        if pairOn and sa.has and sa.name ~= "" and sa.combo and sa.combo > 1
           and AST.partnerNames(sa.name) then
          local loss = 0
          local nbs = {}
          for _, j in ipairs(adj0[i] or {}) do
            local sb = slots[j]
            -- 邻居必须**也是配对中的一方**，且两人真的互为伙伴
            local okPair = false
            if sb.has and sb.name ~= "" and sb.combo and sb.combo > 1 then
              for _, pn in ipairs(AST.partnerNames(sa.name) or {}) do
                if pn == sb.name then okPair = true break end
              end
            end
            if okPair then
              loss = loss + (sb.cps or 0) * (pairMult - 1)
              nbs[#nbs + 1] = sb.label .. "(" .. tostring(sb.name) .. ")"
            end
          end
          -- ⚠⚠ 别漏了"被拿走的角色**自己也**会失去 ×3"这一半！
          --   实测踩到：旧写法只算了伙伴的损失。对 Teto（CPS 375）这种
          --   "高配低底"角色影响很小，但对 Lucia / Summer Mika II 这类
          --   本身产出很高的角色就**差很多** —— 会低估拆配对的代价。
          --   配对生效时两人**各得 ×3**，所以自己这半同样是 cps × (mult-1)。
          if loss > 0 then
            loss = loss + (sa.cps or 0) * (pairMult - 1)
          end
          if loss > 0 then
            breakLoss[sa.label] = loss
            pairNeighbor[sa.label] = table.concat(nbs, ", ")
          end
        end
      end
    end
    -- ③ 逐步：先给每台独立取最优（保证下限），再回头做配对搜索（③b）
    local cands = {}
    local cpsBefore = 0
    for _, sl in ipairs(slots) do
        local curCps = sl.cps or 0
        cpsBefore = cpsBefore + curCps
        -- 台上角色"自己等级的初始CPS"：用台上 BaseCPS（原始常数）× 突变倍率 × 曲线？
        -- 不必这么麻烦 —— 台的 CPS 就是最终值，初始值 = CPS ÷ 曲线(自己等级)。
        -- ⚠ 这里只需要一个"是不是空台"的判据，`curEffBase` 仅用于显示/调试。
        local curEffBase = 0
        do
            local okc, cv = pcall(cpsCurve, sl.level or 1)
            if okc and type(cv) == "number" and cv > 0 then
                curEffBase = curCps / cv
            end
        end
        local best = nil
        -- ★★★ 单台食物预算（这个旋钮是**必需**的，实测踩到）★★★
        --   ⚠⚠⚠ 旧写法的结构性缺陷（用户当场抓到）：
        --     目标只是"顶平这个台子**自己当前**的 CPS"。
        --     于是一个只有 46M 的弱台子，顶平后还是 46M ——
        --     **算法根本没有"把它变得更好"的空间**，永远不认为值得换。
        --     用户原话："脚本还是没有把台上的Ascended跟Divine垃圾角色拿下来
        --     放上cele或者ancient，你自己看看现在家里的布局有多少垃圾角色"
        --
        --   ⇒ 每台给一份**独立食物预算**（`cfg.astPerStandFood`），
        --     目标 CPS = 在"当前产出"和"这份预算能练到的产出"之间取**更大者**。
        --     这样弱台子才有被大幅提升的可能。
        --   `cfg.astPerStandFood = 0` 时退回旧行为（只顶平当前产出）。
        local perStandFood = tonumber(cfg.astPerStandFood) or 0
        local targetCps = curCps
        if perStandFood > 0 then
            -- 用"最强的那个候选"估算这份预算能推到多高，作为共同的追赶目标
            local bestBase, bestRar = 0, nil
            for i = 1, #pool do
                local c = pool[i]
                if AST.rarityAllowed(c.rarity) and c.effBase > bestBase then
                    bestBase, bestRar = c.effBase, c.rarity
                end
            end
            if bestBase > 0 and bestRar then
                local probe = AST.levelForCps(bestBase, 1e300, bestRar, 1, perStandFood)
                if probe and (probe.cps or 0) > targetCps then
                    targetCps = probe.cps
                end
            end
        end
        -- ★ 单台成本上限（**不是**总预算）
        --   ⚠⚠ 以前这里直接把 `budget`（总预算 20B）当成单台上限传下去，
        --   结果所有"高潜力但需要练级"的候选都被判定为"超预算"而直接排除，
        --   最后只能挑那些**本来就高等级**的 Supreme。
        --   ⇒ 选人阶段只看**安全上限**，总预算留给后面的"预算裁剪"决定
        --     本批真正执行哪几台；其余的下批继续，符合"可以慢慢升级"。
        local perItemCap = tonumber(cfg.astMaxCost) or 1e15
        if perStandFood > 0 then
            perItemCap = math.min(perItemCap, perStandFood)
        end
        if budget > 0 then
            perItemCap = math.min(perItemCap, math.max(budget * 100, 1e12))
        end
        for i = 1, #pool do
            local c = pool[i]
            -- ★★★ 重写：不再用"基础值必须更强"当门槛（那是错的！）★★★
            --
            -- ⚠⚠⚠ 旧写法的严重缺陷（用户当场抓到）：
            --     `if c.effBase > curEffBase * 1.001 then` —— 要求候选的**基础值更强**。
            --     但**低品质角色天生基础值高、升级成本也高**：
            --         Ancient   常数 ~6e7，升级成本 4000
            --         Celestial 常数 ~2.4e7，升级成本 1250
            --     于是台上有 Ancient 时，Celestial 候选（2.4e7 > 6e7 为假）
            --     **连被考虑的机会都没有**。
            --     用户原话："脚本还是认为前两级的垃圾好用，
            --     他们明明升到200多级都不到1B/s，随便一个突变的celestial角色升升级就有1B/s了"
            --
            -- ⇒ 正确判据：**在"顶平当前产出"的前提下，谁花的食物更少**。
            --   这就是用户要的"性价比"，而且它天然偏好高品质：
            --     低品质 = 要练更多级 = 花更多食物；
            --     高品质 = 少数几级就到 = 花得少、且天花板高得多。
            --   比较用"每点食物的净产出" gain/cost；cost=0 时给一个极大值。
            if not c._used and c.effBase > 0 then
                -- ⑤ 稀有度白名单（用户明确要求："指定放哪些品质，从这些品质上计算"）
                if AST.rarityAllowed(c.rarity) then
                local need = AST.levelForCps(c.effBase, targetCps, c.rarity, c.level, perItemCap)
                if need then
                    local gain = need.cps - curCps
                    -- ★★★ 配对变化的净影响（方向性 bug 的修复，实测抓到）★★★
                    --
                    -- ⚠⚠⚠ 旧写法是 `netGain = gain - breakLoss`，把"拆掉配对"当成纯损失。
                    --   但它**完全没算**"换成更强的伙伴之后，伙伴的 ×3 会变得**更值钱**"！
                    --   实测症状（用户当场抓到）：
                    --     P36 Lucia 初始CPS 1.14e6 -> "保持（正在吃 ×3 配对，换掉会亏 16.44B）"
                    --     P38 Lucia 初始CPS 1.37e6 -> "保持（正在吃 ×3 配对，换掉会亏 41.88B）"
                    --   而实际上放个 5.6e7 的角色上去，邻居 Davida 的 ×3 会**更大**，
                    --   配对整体变强 —— 是"升级配对"，不是"破坏配对"。
                    --
                    --   ⇒ 正确算法：配对项 = 伙伴CPS × (mult-1)
                    --       变化量 = 新的配对价值 - 旧的配对价值
                    --              = (newCps - curCps) × (mult - 1)
                    --     而 `(newCps - curCps)` 恰好就是 `gain`（本台产出的提升量）！
                    --     所以配对带来的**额外**净收益 = gain × (mult - 1)。
                    --     ⇒ netGain = gain + gain × (mult-1) - lostSelfAndNonPair
                    --   这样：
                    --     · 换成更强的角色 -> 配对变大 -> 净收益更高（鼓励升级配对）
                    --     · 换成更弱的角色 -> 配对变小 -> 净收益被惩罚（阻止拆配对）
                    local lost = breakLoss[sl.label] or 0
                    local pairBoost = 0
                    if lost > 0 then
                        -- 这台确实在吃配对：gain 会同等放大到伙伴身上
                        pairBoost = gain * ((tonumber(cfg.astPairMult) or 3) - 1)
                    end
                    local netGain = gain + pairBoost - lost
                    if netGain > 0 then
                        -- ★★★ 排序依据：**性价比（净产出 ÷ 食物成本）** ★★★
                        --   用户原话："随便一个突变的celestial角色升升级就有1B/s了"
                        --   ⇒ 比较 `netGain / max(cost, 1)`：
                        --       · cost = 0（角色自己等级就够）-> 用极大值，无条件最优
                        --       · 否则 = 每点食物能换多少 CPS
                        --   这个指标天然偏好高品质：低品质要练更多级 -> 花更多食物；
                        --   高品质少数几级就到 -> 花得少，且天花板高得多。
                        --
                        -- ⚠⚠⚠ 三个千万别改回去的写法（都实测踩过）：
                        --   ① 门槛别用 `c.effBase > curEffBase` —— 低品质天生基础值高，
                        --      会让 Celestial 候选**连被考虑的资格都没有**。
                        --   ② 排序别用 `rawBase`（当前等级产出）—— 它奖励"品质成本低"，
                        --      把 Divine / Gold 严重高估，曾把 CPS 4.48e6 的角色放上台。
                        --   ③ 排序别用"单位食物收益(eff)"以外的旧字段名，容易和预算裁剪混淆。
                        local cost = need.cost or 0
                        local score
                        if cost <= 0 then
                            score = 1e30 + netGain      -- 零成本无条件优先（不花食物就赚）
                        else
                            score = netGain / cost
                        end
                        if not best or score > best.score
                           or (score == best.score and netGain > best.gain) then
                            best = { c = c, need = need, gain = netGain, rawGain = gain,
                                     lost = lost, score = score, eff = score }
                        end
                    end
                end
                end   -- ← rarityAllowed 判定结束
            end
        end
        if best then
            best.c._used = true
            cands[#cands + 1] = {
                label = sl.label, stand = sl.stand,
                fromName = sl.name, fromMut = sl.mut, fromLv = sl.level, fromCps = curCps,
                toName = best.c.name, toMut = best.c.mut, toMutCn = best.c.mutCn,
                toRarity = best.c.rarity, toBase = best.c.effBase,
                toLv = best.need.level, toCps = best.need.cps,
                reachedTarget = best.need.reachedTarget == true,
                holdKey = best.c.holdKey,
                cost = best.need.cost or 0, gain = best.gain, eff = best.eff,
                rawGain = best.rawGain, lostPair = best.lost,
                pairNeighbor = pairNeighbor[sl.label],
                partners = best.c.partners, why = best.c.why, changed = true,
                poolRef = best.c,
            }
        else
            local lost = breakLoss[sl.label] or 0
            cands[#cands + 1] = {
                label = sl.label, stand = sl.stand,
                fromName = sl.name, fromMut = sl.mut, fromLv = sl.level, fromCps = curCps,
                toName = nil, changed = false, toCps = curCps, gain = 0, cost = 0, eff = 0,
                lostPair = lost,
                why = (sl.name == "" and "空台（无更强候选）")
                    or (lost > 0 and ("保持（该台正在吃 ×" .. tostring(cfg.astPairMult or 3)
                        .. " 配对，换掉会亏 " .. fmtShort(lost) .. "）"))
                    or "预算内无更优候选",
            }
        end
    end

    -- ③b 🔗 配对搜索（**用户的核心诉求**）
    --   逐个台子独立取最优时，两个相邻台子恰好选中一对配对伙伴的概率极低 ——
    --   实测配对数是 0。所以必须**主动搜索**：
    --     对每一对相邻台子，比较
    --       ① 两人各自单放：gain1 + gain2
    --       ② 换成一对配对伙伴并吃 ×mult：gain1' + gain2' + (cps1' + cps2') × (mult-1)
    --     哪个合计高就用哪个。
    --   ⚠ 这里会**释放**单台最优占用的候选，重新分配给配对（所以放在③之后、预算裁剪之前）。
    local nPair, pairBonus = 0, 0
    -- ⚠⚠⚠ 独占登记（实测踩到的严重 bug 的修复）：
    --   旧写法用 `_reserved` 标记，但它从没被真正设置过，也没有互斥检查 ——
    --   结果**同一个 Lucia 被分配到两个台子**，她的 CPS 被重复计入两次，
    --   算出 "+3157% 提升"、单台 gain 1.265e12 这种荒谬数字（真实量级约 +70%）。
    --   ⇒ 用 `assignedBy`（候选对象 -> 台子 label）做独占登记：
    --        · 分配前用 freeFor() 检查它有没有被别的台子占着
    --        · 重新分配前用 claim() 先把它从原来那台释放
    local assignedBy = {}
    for _, e in ipairs(cands) do
        if e.poolRef then assignedBy[e.poolRef] = e.label end
    end
    local function freeFor(c, lbl)
        local owner = assignedBy[c]
        return (owner == nil) or (owner == lbl)
    end
    local function claim(c, lbl)
        local owner = assignedBy[c]
        if owner and owner ~= lbl then
            for _, e in ipairs(cands) do
                if e.label == owner and e.poolRef == c then
                    e.poolRef = nil          -- 从原来那台释放
                end
            end
        end
        assignedBy[c] = lbl
    end
    if cfg.astPairBonus ~= false then
        local mult = tonumber(cfg.astPairMult) or 3
        local idxByLabel = {}
        for i, e in ipairs(cands) do idxByLabel[e.label] = i end
        local adj = AST.buildAdjacency(slots)
        local done = {}
        for i, s in ipairs(slots) do
            for _, j in ipairs(adj[i] or {}) do
                local sa, sb = slots[i], slots[j]
                local ea, eb = cands[idxByLabel[sa.label]], cands[idxByLabel[sb.label]]
                if ea and eb and not done[sa.label] and not done[sb.label] then
                    local baseSum = (ea.gain or 0) + (eb.gain or 0)
                    -- 为这两台找一对"互为配对伙伴"且合计最划算的组合
                    local bestPair, bestVal = nil, baseSum
                    for _, ca in ipairs(pool) do
                        if ca.partners and freeFor(ca, sa.label) then
                            for _, cb in ipairs(pool) do
                                if ca ~= cb and freeFor(cb, sb.label) then
                                    local okp = false
                                    for _, pn in ipairs(ca.partners) do
                                        if pn == cb.name then okp = true break end
                                    end
                                    if okp then
                                        local na = AST.levelForCps(ca.effBase, sa.cps or 0, ca.rarity, ca.level, budget)
                                        local nb = AST.levelForCps(cb.effBase, sb.cps or 0, cb.rarity, cb.level, budget)
                                        -- 配对的两台合计也不能超预算
                                        local pairCost = (na and na.cost or 0) + (nb and nb.cost or 0)
                                        if na and nb and not (budget > 0 and pairCost > budget) then
                                            local g = (na.cps - (sa.cps or 0)) + (nb.cps - (sb.cps or 0))
                                                + (na.cps + nb.cps) * (mult - 1)
                                            if g > bestVal then
                                                bestVal = g
                                                bestPair = { ca = ca, cb = cb, na = na, nb = nb,
                                                             baseGain = g - (na.cps + nb.cps) * (mult - 1),
                                                             bonus = (na.cps + nb.cps) * (mult - 1) }
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if bestPair then
                        claim(bestPair.ca, sa.label)
                        claim(bestPair.cb, sb.label)
                        ea.toName, ea.toMut, ea.toMutCn = bestPair.ca.name, bestPair.ca.mut, bestPair.ca.mutCn
                        ea.toRarity, ea.toBase = bestPair.ca.rarity, bestPair.ca.effBase
                        ea.toLv, ea.toCps, ea.cost = bestPair.na.level, bestPair.na.cps, bestPair.na.cost or 0
                        ea.reachedTarget = bestPair.na.reachedTarget == true
                        ea.holdKey = bestPair.ca.holdKey
                        ea.poolRef, ea.changed = bestPair.ca, true
                        eb.toName, eb.toMut, eb.toMutCn = bestPair.cb.name, bestPair.cb.mut, bestPair.cb.mutCn
                        eb.toRarity, eb.toBase = bestPair.cb.rarity, bestPair.cb.effBase
                        eb.toLv, eb.toCps, eb.cost = bestPair.nb.level, bestPair.nb.cps, bestPair.nb.cost or 0
                        eb.reachedTarget = bestPair.nb.reachedTarget == true
                        eb.holdKey = bestPair.cb.holdKey
                        eb.poolRef, eb.changed = bestPair.cb, true
                        -- 收益记在 ea 上（避免重复计）
                        ea.gain = bestVal
                        ea.pairWith, ea.pairName, ea.pairMult = sb.label, bestPair.cb.name, mult
                        ea.pairBonus = bestPair.bonus
                        ea.why = tostring(bestPair.ca.why or "") .. " · 🔗与" .. sb.label .. "配对×" .. mult
                        eb.gain = 0
                        eb.pairWith, eb.pairName, eb.pairMult = sa.label, bestPair.ca.name, mult
                        eb.pairBonus = 0
                        eb.why = tostring(bestPair.cb.why or "") .. " · 🔗与" .. sa.label .. "配对×" .. mult .. "（收益记在 " .. sa.label .. "）"
                        done[sa.label] = true
                        done[sb.label] = true
                        nPair = nPair + 1
                        pairBonus = pairBonus + bestPair.bonus
                    end
                end
            end
        end
    end
    -- ④ 预算裁剪（背包式贪心）
    --   ① **零成本项无条件优先收**（不花食物就能赚，没有理由不要）
    --   ② 剩下的按 **净增幅**（gain）降序 —— **这是"总 CPS 最大化"的直接体现**
    --      （用户原话："优先选能让总CPS增加的配置"）
    --   ⚠ 不要改回"按单位食物收益(gain/cost)排序"：那追求的是"省食物"，
    --     会把"花得多但涨得多"的高潜力项挤掉，最终总 CPS 反而更低。
    --     零成本的仍然无条件优先收（不花食物就赚，没理由不要）。
    --   ⚠ 配对的两台是一体的：只要其中一台被跳过，另一台也必须跳过，
    --     否则会剩下一半配对（既拿不到 ×3 还白换了人）。
    local changes = {}
    for _, e in ipairs(cands) do if e.changed then changes[#changes + 1] = e end end
    table.sort(changes, function(a, b)
        local az = (a.cost or 0) <= 0
        local bz = (b.cost or 0) <= 0
        if az ~= bz then return az end                 -- 零成本优先
        return (a.gain or 0) > (b.gain or 0)           -- 然后按净增幅最大
    end)
    local byLabel = {}
    for _, e in ipairs(cands) do byLabel[e.label] = e end
    local spent, skipped, cpsAfter = 0, 0, 0
    local decided = {}
    local function tryBudget(e)
        if decided[e.label] then return end
        local partner = e.pairWith and byLabel[e.pairWith] or nil
        local need = e.cost or 0
        if partner then need = need + (partner.cost or 0) end
        if budget > 0 and (spent + need) > budget then
            -- 预算不够 -> 这一台（以及它的配对伙伴）本批都不改
            e.skipped = true
            skipped = skipped + 1
            decided[e.label] = true
            if partner then
                partner.skipped = true
                skipped = skipped + 1
                decided[partner.label] = true
            end
        else
            spent = spent + need
            decided[e.label] = true
            if partner then decided[partner.label] = true end
        end
    end
    for _, e in ipairs(changes) do tryBudget(e) end
    -- ④c 🧹 清掉"毫无收益却要花钱"的项（实测 P19 就是这种）
    --   用户实测抓到：`P19 Rena Yamashira → Madoki Kaneme` 增益 = 0 却要花 2.894e9。
    --   这种项纯属白花食物 + 白动一台，必须一律剔除。
    --   （配对的另一半 gain 记在伙伴身上，所以用 pairWith 排除在外，交给 ④b 处理。）
    for _, e in ipairs(cands) do
        if e.changed and not e.skipped and not e.pairWith
           and (e.gain or 0) <= 0 and (e.cost or 0) > 0 then
            e.changed = false
            e.toName = nil
            e.toCps = e.fromCps
            e.gain = 0
            e.why = "无实际收益却要花食物，本批不改"
        end
    end
    -- ④b 🧹 清掉"零收益的配对占位"
    --   配对里被记 0 收益的那一半（收益记在伙伴身上）如果：
    --     ① 伙伴最终没保留（被预算跳过），或
    --     ② 伙伴带来的配对额外收益连自己这次的置换成本都覆盖不了
    --   那这一半就是白换人 —— 撤销掉，少动一台就少一分风险。
    do
        local byLabel2 = {}
        for _, e in ipairs(cands) do byLabel2[e.label] = e end
        for _, e in ipairs(cands) do
            if e.changed and not e.skipped and e.pairWith and (e.pairBonus or 0) <= 0 then
                local partner = byLabel2[e.pairWith]
                local alive = partner and partner.changed and not partner.skipped
                -- ★ 净收益判定：伙伴的 gain 里已含配对额外收益，但要减去**两台合起来**的成本
                --   才是真正的净收益（e.cost 是占位这一半的成本）。
                --   ⚠ 实测踩到：只写 (partner.pairBonus > e.cost) 会漏掉
                --   "gain 7.639e9、成本 9.265e9" 这种**净亏**的组合。
                local netWorth = alive and ((partner.gain or 0) - (partner.cost or 0) - (e.cost or 0))
                local worth = netWorth and netWorth > 0
                if not worth then
                    e.changed = false
                    e.pairWith, e.pairName, e.pairBonus = nil, nil, 0
                    e.toName = nil
                    e.toCps = e.fromCps
                    e.gain = 0
                    e.why = "配对占位不划算（伙伴的配对收益盖不住这次的置换），本批不改"
                    if alive then
                        -- 伙伴失去配对 -> 一起收回它的配对额外收益
                        partner.changed = false
                        partner.pairWith, partner.pairName = nil, nil
                        partner.gain = (partner.gain or 0) - (partner.pairBonus or 0)
                        partner.pairBonus = 0
                        partner.toName = nil
                        partner.toCps = partner.fromCps
                        if (partner.gain or 0) <= 0 then
                            partner.gain = 0
                            partner.why = "配对伙伴被撤销，本批不改"
                        end
                    end
                end
            end
        end
    end
    -- ⑤ 组装最终方案
    --   ⚠ 注意：到这里才统计 `spent`。因为 ④b 会撤销一部分配对项，
    --     若沿用 ④ 阶段累计的 spent，会把已撤销项的成也算进去（实测显示脏数据 17.6B）。
    local plan = {}
    spent = 0
    for _, e in ipairs(cands) do
        if e.changed and e.skipped then
            e.why = "预算不足，本批不改（需 " .. fmtShort(e.cost or 0) .. "）"
            e.changed = false
            e.pairWith = nil
            e.pairName = nil
            e.pairBonus = 0
            e.toName = nil
            e.toCps = e.fromCps
            e.gain = 0
        end
        if e.changed and not e.reachedTarget and e.toLv then
            -- 如实标注：预算内没能练到"顶回原 CPS"
            e.why = tostring(e.why or "") .. " · ⚠预算内未顶平原CPS"
        end
        if e.changed then spent = spent + (e.cost or 0) end
        cpsAfter = cpsAfter + (e.changed and e.toCps or e.fromCps)
        plan[#plan + 1] = e
    end
    -- ⑥ 配对额外收益计入合计（只算最终真的保留下来的配对）
    local finalPairBonus, finalPairs = 0, 0
    for _, e in ipairs(plan) do
        if e.changed and e.pairWith and (e.pairBonus or 0) > 0 then
            finalPairBonus = finalPairBonus + e.pairBonus
            finalPairs = finalPairs + 1
        end
    end
    if finalPairBonus > 0 then cpsAfter = cpsAfter + finalPairBonus end
    nPair, pairBonus = finalPairs, finalPairBonus
    table.sort(plan, function(a, b) return (a.gain or 0) > (b.gain or 0) end)
    local nChanged = 0
    for _, e in ipairs(plan) do if e.changed then nChanged = nChanged + 1 end end
    return {
        plan = plan,
        slots = #slots,
        changes = nChanged,
        skipped = skipped,
        spent = spent,
        budget = budget,
        cpsBefore = cpsBefore,
        cpsAfter = cpsAfter,
        gain = cpsAfter - cpsBefore,
        poolSize = #pool,
        pairs = nPair,
        pairBonus = pairBonus,
    }
end

-- 🎯 执行一个台子的换人（取回旧角色 -> 手持新角色 -> 放置）
--
-- ★★ 安全设计（用户对不可逆操作极度敏感，这里是重点）★★
--   ① 每一步都在**执行点重新复核**，绝不信赖计划里的缓存值
--   ② 只用背包里的**真实 key**（entry.holdKey），绝不自己拼字符串
--   ③ 放上去之前再确认一次"台子还是空的"
--   ④ 🚫 全程只碰 PlacePrompt / PickupOwnerPrompt，**绝不 fire PurchasePrompt**（付费）
--   ⑤ 任何一步失败就**放弃这一台并把它恢复原状**，不动下一台
function AST.swapOne(entry)
    -- ★★★ 持有豁免窗口（v196）★★★
    -- "放置角色"必须先手持，而主循环在**非万圣节**时会立刻放手 —— 两者直接冲突
    -- （实测：我一手持，放手分支马上把它放掉，PlacePrompt 永远停在
    --   "Equip an Character First"，放置 100% 失败）。
    -- ⇒ 整个换人过程内置位 `R._astHoldGrace`，放手逻辑见到就跳过；
    --   用 pcall 包住以保证**任何异常路径都会释放**（否则豁免会永久生效，
    --   导致脚本再也不放手 —— 那比原来的问题更糟）。
    local _prevGrace = R._astHoldGrace
    R._astHoldGrace = os.clock() + 60          -- 60 秒上限，足够一次换人
    local function _releaseGrace()
        R._astHoldGrace = _prevGrace
    end
    local okBody, r1, r2 = pcall(function()
        return AST._swapOneBody(entry)
    end)
    _releaseGrace()
    if not okBody then
        return false, "换人过程抛错：" .. tostring(r1):sub(1, 200)
    end
    return r1, r2
end

function AST._swapOneBody(entry)
    local stand = entry.stand
    if not stand then return false, "台子实例丢失（可能已重载）" end
    local node = stand:FindFirstChild("PromptNode_Pickup")
    local part = stand:FindFirstChild("PromptPart")
    if not (node and part) then return false, "台子结构异常（找不到 PromptNode_Pickup / PromptPart）" end
    local hrp = rootPart()
    if not hrp then return false, "读不到角色" end
    -- 复核：台子上现在到底是谁？（绝不用计划里的缓存）
    local cur = AST.slotSnap(stand)
    if cur.has and cur.name ~= entry.fromName then
        return false, string.format("台子已变（计划上是 %s，实际是 %s），跳过",
            tostring(entry.fromName), tostring(cur.name))
    end
    -- 复核：新的 key 必须真实存在
    local key = entry.holdKey
    if not key then return false, "缺 holdKey（计划里没记录背包键），为安全起见跳过" end

    -- 🛡🛡🛡 初始CPS 不倒退守卫（用户明确要求："我要的是脚本能理解这个错误，
    --          而不是你来修正"）
    --
    -- 为什么必须放在**执行器**而不是各个 planner 里：
    --   规划逻辑有好几处（AST.plan / AST.planForce / AST.optimizePairs …），
    --   任何一处漏判就会放出弱角色。放在执行器 = **所有路径的最后一道闸**，
    --   无论如何都拦得住。
    --
    -- 判据（用户实测抓到的真实案例）：
    --   P17 上原本是 Yotso Naka[Void] 初始 1.494e6、当前 2.315e8
    --   却被换成了 Blayra[Celestial/Lava] 初始 4.8e7 —— 初始**更强**，这是升级 ✅
    --   反过来若把 Yotso(被喂到 Lv396、当前 2.315e8) 放上台、
    --   顶掉一个初始 5.6e7 的 Celestial —— 那就**必须在规划阶段被否掉**。
    --
    -- 依据：游戏公式 CPS(等级L) = 初始CPS × cpsCurve(L) × 突变倍率
    --   ⇒ 初始CPS 的比值在**任何等级都恒定**，它就是角色真实价值。
    --   ⇒ "当前CPS 高"只是因为等级喂得高，不代表这个角色更好。
    -- 🚫🚫🚫 无突变角色绝不能上台（用户强调过多次，本次又踩了）🚫🚫🚫
    --
    -- 用户原话（第三次强调）："为什么脚本又把没有突变的ancient换上去了，
    --                          我不是说过了没突变的角色不能上台吗"
    --
    -- 根因：之前只在"稀有度白名单"里过滤，而"无突变"是个**独立维度** ——
    --   `CharacterType` 为空字符串（不是 "Gold"/"Honey"），所以一路畅通无阻。
    --   结果 Rikki / Astra / Miki 三个**无突变 Ancient** 被放上了台。
    --
    -- 为什么无突变不能用（数据）：
    --   突变是**乘数**。同样是 Ancient 角色，带 Lava 突变 = 初始CPS ×2，
    --   无突变 = ×1。所以无突变角色的长期价值只有带突变版本的一半甚至更低。
    --   台上位置是稀缺资源（每台都要单独喂食物），放无突变 = 永久浪费一个台位。
    --
    -- ⇒ 与 Gold/Honey 同级硬性拦截，放在执行器 = 所有规划路径的最后一道闸。
    -- ⚠⚠ 例外：**配对位角色**不受无突变 / 初始CPS 两条守卫限制
    --   用户明确选择 A："无突变角色默认不上台，但如果它是台上某角色的配对伙伴，则允许"
    --   典型例子：`Teto` 无突变、初始 375，但和 `Summer Mika II` 是官方配对。
    --   实测放到 P12（夹在 P11/P13 之间）让两边各吃 ×3，合计 +1.578e10；
    --   而背包里有 1196 个 Teto（摘要 c 字段），几乎免费。
    --
    --   ⚠ 判断方式：**脚本自己查配对名单 + 台上实际角色名**，
    --     不信任调用方传来的 `pairWith`（否则任何 planner 漏判都能绕过去）。
    local isPairSlot = (entry.pairWith ~= nil and entry.pairWith ~= "")
    if not isPairSlot then
        pcall(function()
            isPairSlot = AST.isPairSupportFor(entry.toName, cur.name) == true
        end)
    end
    if cfg.astBlockNoMutation ~= false and not isPairSlot then
        local newMut = tostring(entry.toMut or "")
        if newMut == "" then
            return false, string.format(
                "🚫 拒绝：%s 是【无突变】角色，按规则不能上台（突变是乘数，无突变等于白占一个台位）",
                tostring(entry.toName))
        end
    end

    if cfg.astNoInitDowngrade ~= false and not isPairSlot then
        local curInit = 0
        local baseCps = tonumber(cur.base) or 0        -- 台子的 BaseCPS 属性 = 原始常数（不含突变）
        local curMutMult = 1
        do
            -- 用"台上当前 CPS ÷ 曲线(当前等级)"反推出它自己的初始CPS（含突变）
            local cv = cpsCurve(cur.level or 1) or 1
            if cv > 0 then curInit = (cur.cps or 0) / cv end
        end
        -- 新角色的初始CPS：优先用规划阶段的 toInit；没有就从背包条目现算
        local newInit = tonumber(entry.toInit) or 0
        if newInit <= 0 then
            local sum = fetchSummary()
            if sum and sum[key] then
                local v = sum[key]
                local lv = tonumber(v.bl) or 1
                local cv = cpsCurve(lv) or 1
                if cv > 0 then newInit = (tonumber(v.bc) or 0) / cv end
            end
        end
        -- 只在"两边都算得出来"且"新角色明显更弱"时拦（0.9 = 允许 10% 误差）
        if curInit > 0 and newInit > 0 and newInit < curInit * 0.9 then
            return false, string.format(
                "🛡 初始CPS 会倒退，已拦下：%s 初始 %.4g → %s 初始 %.4g（当前CPS 高只是因为等级喂得高，练到同级会差 %.1f 倍）",
                tostring(cur.name), curInit, tostring(entry.toName), newInit, curInit / newInit)
        end
    end

    -- ① 先传送到台子旁
    local function gotoStand()
        local h = rootPart()
        if h then
            pcall(function()
                h.CFrame = CFrame.new(node.Position + Vector3.new(0, 3, 3))
                h.AssemblyLinearVelocity = Vector3.zero
                h.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        task.wait(0.6)
    end
    gotoStand()

    -- ② 台上有角色 -> 先取回（这时角色回到背包）
    --
    -- ★★★ 必须"强制离开再回来"重新武装 prompt（实测踩到，和喂食是同一个坑）★★★
    --   症状：只传送一次就 fire -> 服务端**没把 PickupOwnerPrompt 武装起来**
    --         （客户端 Enabled 还是 false / 或 fire 被忽略），台子角色纹丝不动，
    --         报错"取回旧角色后台子仍显示有角色"。
    --   根因：服务端需要一次**新鲜的"进入范围"事件**才会填好 prompt 状态；
    --         单纯"已经在范围内"不算。
    --   对策：先传送到远处（脱离范围）→ 等 0.4s 让服务端收到离开 → 再传送回来
    --         → 等 prompt 变 Enabled，最多重试 3 轮。
    --   ⚠ 这段逻辑与 feedOne 里的取回完全同源，改动时两处要一起改。
    local returned = false
    if cur.has then
        local pick = node:FindFirstChild("PickupOwnerPrompt")
        local function farAway()
            local h = rootPart()
            if h then
                pcall(function()
                    h.CFrame = CFrame.new(node.Position + Vector3.new(0, 40, 0))
                    h.AssemblyLinearVelocity = Vector3.zero
                end)
            end
            task.wait(0.4)
        end
        local armed = false
        for _ = 1, 3 do
            farAway()
            gotoStand()
            if pick and pick.Enabled then armed = true break end
            task.wait(0.4)
        end
        if not armed then
            return false, "取回提示一直未启用（已尝试 3 轮强制重新靠近）"
        end
        local ok = pcall(fireproximityprompt, pick)
        if not ok then return false, "取回旧角色失败（fireproximityprompt 出错）" end
        local t0 = os.clock()
        while isCurrent() and (os.clock() - t0) < 6 do
            task.wait(0.2)
            if not AST.slotSnap(stand).has then returned = true break end
        end
        if not returned then return false, "取回旧角色后台子仍显示有角色，放弃" end
    end

    -- ③ 手持新角色
    local okHold = pcall(function() RF.hold:FireServer(key) end)
    if not okHold then return false, "手持请求发送失败" end
    task.wait(1.2)
    -- 复核：真的手持上了吗？
    local held = heldName()
    if held ~= entry.toName then
        -- 手持失败 -> 尽力把旧角色放回去，别让台子空着
        if returned and entry.fromName ~= "" then
            pcall(function() RF.hold:FireServer("") end)
        end
        return false, string.format("手持失败（期望 %s，实际 %s）", tostring(entry.toName), tostring(held))
    end

    -- ④ 传送到台子旁并放置
    --   ⚠⚠⚠ 两个必须同时满足的条件（都实测踩过）：
    --     ① `ActionText` 必须是 **"Place"** —— 手持还没在服务端生效时它是
    --        "Equip an Character First"，这时 fire 会被静默忽略。
    --     ② `Enabled` 必须是 **true** —— 服务端需要一次**新鲜的"进入范围"事件**
    --        才会武装 prompt。实测症状：空台上 `Enabled=false` 而 `ActionText` 已是 "Place"，
    --        结果连 3 台都失败（"放置提示未就绪"）。
    --   ⇒ 和取回一样，必须**强制"离开 → 回来"**重试，最多 4 轮。
    local pp = part:FindFirstChild("PlacePrompt")
    local armed = false
    local function stepAway()
        local h = rootPart()
        if h then
            pcall(function()
                h.CFrame = CFrame.new(node.Position + Vector3.new(0, 45, 0))
                h.AssemblyLinearVelocity = Vector3.zero
            end)
        end
        task.wait(0.4)
    end
    for _ = 1, 4 do
        stepAway()
        gotoStand()
        -- 靠近后给服务端一点时间武装 prompt
        local t0 = os.clock()
        while isCurrent() and (os.clock() - t0) < 1.2 do
            local en, txt = false, nil
            pcall(function() en = pp and pp.Enabled end)
            pcall(function() txt = pp and pp.ActionText end)
            if en and txt == "Place" then armed = true break end
            task.wait(0.15)
        end
        if armed then break end
    end
    if not armed then
        pcall(function() RF.hold:FireServer("") end)
        local ppTxt, ppEn = nil, false
        pcall(function() ppTxt = pp and pp.ActionText end)
        pcall(function() ppEn = pp and pp.Enabled end)
        return false, string.format('放置提示一直未就绪（Enabled=%s, ActionText=%q，已试 4 轮离开-回来）—— 已放手',
            tostring(ppEn), tostring(ppTxt))
    end
    pcall(fireproximityprompt, pp)
    -- ⑤ 复核：真的放上去了吗？
    local t0 = os.clock()
    local placed = false
    while isCurrent() and (os.clock() - t0) < 4 do
        task.wait(0.2)
        local now = AST.slotSnap(stand)
        if now.has and now.name == entry.toName then
            placed = true
            break
        end
    end
    if not placed then
        pcall(function() RF.hold:FireServer("") end)
        return false, "放置后未观察到角色上台（已放手）"
    end

    -- ⑥ ★★★ 练级到目标等级（用户明确要求，也是"放高初始CPS角色"能成立的前提）★★★
    --   为什么必须做：用户的核心洞察是"**初始CPS 决定一切**" ——
    --      背包里最强的角色初始 CPS 是 2.8e8，而台上最强的只有 1.6e7（差 17.5 倍）。
    --      但那些高初始角色大多是 Lv1，**直接换上去反而会降级**，
    --      所以旧执行器只能挑"本来就高等级"的角色，永远用不上它们。
    --   ⇒ 换上去之后必须把它练到计划里的目标等级，否则这个功能等于没用。
    --   复用 `feedOne`（逐级 fire LevelUpPrompt，实现见喂食系统），
    --   因为它已经解决了"prompt 需要新的进入范围事件"等多个实测坑。
    local wantLv = tonumber(entry.toLv) or 0
    local curLv = AST.slotSnap(stand).level or 0
    if wantLv > 0 and curLv < wantLv and type(R.feedOne) == "function" then
        local leveled, failed = 0, 0
        local guard = 0
        while isCurrent() and guard < 400 do
            local snap = AST.slotSnap(stand)
            if (snap.level or 0) >= wantLv then break end
            guard = guard + 1
            -- feedOne 需要一份"含 stand/name/level"的快照；每次重新取，避免等级复核失败
            local okF, errF = pcall(R.feedOne, {
                stand = stand, name = snap.name, level = snap.level,
            })
            if okF then
                leveled = leveled + 1
            else
                failed = failed + 1
                if failed >= 3 then
                    return true, string.format("已放置但练级中断（到 Lv%s / 目标 Lv%s）：%s",
                        tostring(snap.level), tostring(wantLv), tostring(errF):sub(1, 60))
                end
            end
            task.wait(0.15)
        end
        local finalLv = AST.slotSnap(stand).level or 0
        if finalLv < wantLv then
            return true, string.format("已放置，等级 Lv%s（未达目标 Lv%s）", tostring(finalLv), tostring(wantLv))
        end
    end
    return true, AST.slotSnap(stand)
end

-- 🎯 执行整批（按计划顺序，逐台做；任何一台失败只跳过它）
function AST.execute(plan)
    plan = plan or (R.astLastPlan and R.astLastPlan.plan)
    if type(plan) ~= "table" then return false, "没有可执行的计划（先点「算出最优配置」）" end
    if R._astRunning then return false, "上一批还在执行中" end
    R._astRunning = true
    local okBusy = R.busySuggest("配置角色", "自动配置角色")
    if not okBusy then
        R._astRunning = false
        return false, "其他模块正在使用角色位置（" .. tostring(R.yieldLabel(R.busyWho() or "")) .. "）"
    end
    local done, failed, skipped = 0, 0, 0
    local t0 = os.clock()
    log("🎯 开始执行台子配置（共 " .. #plan .. " 项）…", Color3.fromRGB(140, 220, 255))
    for i, e in ipairs(plan) do
        if not isCurrent() then break end
        if not e.changed then skipped = skipped + 1 else
            local ok, res = AST.swapOne(e)
            if ok then
                done = done + 1
                log(string.format("🎯 %s：%s → %s%s", e.label, tostring(e.fromName), tostring(e.toName),
                    e.pairWith and ("（🔗配 " .. tostring(e.pairWith) .. "）") or ""),
                    Color3.fromRGB(120, 255, 140))
            else
                failed = failed + 1
                log(string.format("⚠ %s 换人失败：%s", e.label, tostring(res)), Color3.fromRGB(255, 200, 90))
            end
            task.wait(0.3)
        end
    end
    R.busyClear("配置角色")
    R._astRunning = false
    R.astExecCount = (R.astExecCount or 0) + done
    local secs = os.clock() - t0
    log(string.format("🎯 台子配置执行完毕：成功 %d · 失败 %d · 跳过 %d · 耗时 %.1f 秒",
        done, failed, skipped, secs), Color3.fromRGB(120, 255, 140))
    return true, { done = done, failed = failed, skipped = skipped, seconds = secs }
end
R.astExecute = AST.execute
R.astSwapOne = AST.swapOne

-- 🤖 全自动调度（用户最初的设想：按一定时间重算 + 全自动配置）
--
-- 设计要点：
--   ① **周期重算**：默认每 60 分钟算一次（`cfg.astIntervalMinutes`），
--      因为"新的/更好的鱼上钩"会持续改变最优解，需要定期重新评估。
--   ② **食物门槛**：只有食物 ≥ `cfg.astMinFood` 才动手换人。
--      食物优先留给喂食（本 tick 排在 feedTick 之后），避免把食物吃光导致不喂食。
--   ③ **只做零成本+顶平的**：执行器目前**不会练级**，所以只执行
--      `cost <= 0 且 reachedTarget` 的项 —— 这类角色自己等级就够，换上去不会降级。
--      需要练级的项只记录、不执行（等练级功能实现）。
--   ④ **让路**：其他模块占用角色位置时（钓鱼/事件/Solar）直接跳过，下一轮再说。
--   ⑤ **失败不重试轰炸**：同一批失败后进入冷却，不反复刷。
function AST.autoTick()
    if cfg.astEnabled ~= true then return end
    -- 让路：其他模块在用角色位置
    if R._astRunning then return end
    -- ★ 让路给正在跑的喂食（用户实测报告："自动喂食在跟自动换人抢"）★
    --   两者都要传送操作 prompt，同时跑会互相打断；而且食物也要分开。
    --   喂食那边也有对称的让路判断（见 feedTick 顶部），所以是**双向互斥**。
    local bw = R.busyWho and R.busyWho()
    if bw and bw ~= "配置角色" then return end
    if R.feed and R.feed.running then return end
    -- 上一批喂食刚结束的 3 秒内也让路（等它彻底收尾，避免 prompt 状态未稳定）
    if (os.clock() - (tonumber(R.feed and R.feed.lastRunAt) or 0)) < 3 then return end
    if R.mode and R.mode ~= "idle" and R._mode ~= "idle" then return end
    local now = os.clock()
    -- ★★★ 两个独立节流：**重算周期** 与 **执行检查周期**（实测踩到的活锁）★★★
    --
    -- ⚠⚠⚠ 用户报告："我现在食物已经5B了，也不换"。
    --   根因：旧写法把"重算"和"执行"绑在同一个 1 小时闸门里 ——
    --     脚本重载时食物是 0 -> 算完发现没得换 -> 退出，然后**整整一小时不再看**。
    --     等食物攒够了也无人问津。
    --   ⇒ 拆开：
    --       · **重算**（astPlan，较慢）仍然每 `astIntervalMinutes` 一次 ——
    --         因为最优解取决于背包，不需要频繁算。
    --       · **执行检查**（看食物够不够、够就换）每 30 秒一次 ——
    --         这样"够一台就换一台"才真的成立，不用干等一小时。
    local RE_EXEC = 30
    local lastExec = tonumber(R._astLastExec or 0)
    if (now - lastExec) < RE_EXEC then return end
    R._astLastExec = now
    -- ★★★ 黑名单强制清场（用户要求"在台上就自动拿下来"）★★★
    --   放在最前面：先把不该在台上的拿下来，再谈换人。
    --   它自己会抢 busy 锁，抢不到就下一轮再说。
    do
        local okE, nE = pcall(AST.enforceRarityBlock)
        if okE and type(nE) == "number" and nE > 0 then
            log(string.format("🚫 黑名单清场：拿下了 %d 台不该在台上的角色", nE),
                Color3.fromRGB(255, 200, 90))
        end
    end
    -- 墙钟时间（os.time）用于**跨会话**的重算周期判断
    local period = (tonumber(cfg.astIntervalMinutes) or 60) * 60
    local wall = os.time()
    local lastWall = tonumber(cfg.astLastAutoAt) or 0
    local needReplan = true
    if period > 0 and wall > 0 and lastWall > 0 and (wall - lastWall) < period then
        needReplan = false       -- 还没到重算时间：复用上次的计划
    end
    if needReplan then
        R._astLastAuto = now
        -- 先落盘锚点：**在重算之前**写，避免重算中掉线导致"已经做过却又重做一遍"
        cfg.astLastAutoAt = (wall > 0) and wall or os.time()
        if cfg.autoSave ~= false and saveConfig then pcall(saveConfig, true) end
    else
        -- 没到重算时间：直接用上次算好的计划来决定"现在能不能换"
        local cached = R.astLastPlan
        if not (cached and type(cached.plan) == "table") then return end
    end
    -- 食物门槛
    local food = R.foodNow and R.foodNow() or 0
    local minFood = tonumber(cfg.astMinFood) or 0
    -- 到重算时间 -> 重新算一份；否则复用上次的计划（避免 30 秒跑一次 astPlan 拖慢游戏）
    local P = R.astLastPlan
    if needReplan or not (P and type(P.plan) == "table") then
        local okP, newP = pcall(AST.plan, tonumber(cfg.astFoodBudget) or 0)
        if not okP or type(newP) ~= "table" then
            log("🎯 自动配置：计算失败，跳过本轮（" .. tostring(newP):sub(1, 80) .. "）",
                Color3.fromRGB(255, 200, 90))
            return
        end
        P = newP
        R.astLastPlan = P
        R.astLastAt = os.date("%H:%M:%S")
    end
    -- ★★★ 挑出"现在就能做"的项 ★★★
    --
    -- ⚠⚠⚠ 旧写法要求 `e.reachedTarget == true`（必须能顶平原 CPS），
    --   但**高初始CPS的角色大多是 Lv1**（用户的核心洞察："初始CPS 决定一切"），
    --   在食物有限时它们**恰好顶不平**当前产出，于是永远被排除：
    --     ready = 0  ->  "暂无可零成本执行的项"  ->  什么都不做。
    --   这正是用户看到的"垃圾角色一直不换"。
    --   ⇒ 现在改成：**在预算内能提升多少就做多少**。
    --     即使一时顶不平（换上去 CPS 会短暂低于原来），
    --     只要它是"初始CPS 更高"的正确资产，长期靠喂食一定追回来。
    --     （这正是用户说的"升级后也可以，因为可以慢慢升级"）
    --   排序：先按"初始CPS 提升倍数"降序（资产质量），再按净增益。
    -- ★★★ 关键：预留的是"**下一台**要换的那台所需"，不是整个计划的总和！★★★
    --
    -- ⚠⚠⚠ 实测踩到的死锁（用户报告："我现在食物已经5B了，也不换"）：
    --   旧写法 `needMore = 所有不够的项相加` -> 预留 = 整个计划（6.70B）。
    --   而食物有 9.29B 时：
    --     ① 那些"够"的项本该被执行 —— 但它们**一台都没被选中**，
    --        因为 `food >= cost` 比较的是**单台成本**（0.5B），9.29B 明明够……
    --     ② 真正的问题是预留把所有食物锁死了：
    --        `feedBudgetCap() = 9.29B - 6.70B = 2.59B`（够喂食），
    --        但下一轮 autoTick 又要等 1 小时，而中途食物会被喂食花掉一部分，
    --        于是每轮都"刚好不够"，形成活锁。
    --   ⇒ 预留只保**下一台最便宜的那台**，够它就立刻能换；
    --     换完再预留下下一台。这样能持续推进，不会卡死。
    local ready, pending, minPending = {}, 0, math.huge
    for _, e in ipairs(P.plan) do
        if e.changed then
            local cost = e.cost or 0
            if cost <= 0 then
                ready[#ready + 1] = e              -- 零成本：无条件做
            elseif food >= cost then
                ready[#ready + 1] = e              -- 食物够这一台：立刻做
            else
                pending = pending + 1
                if cost < minPending then minPending = cost end
            end
        end
    end
    R.astFoodReserve = (minPending < math.huge) and minPending or 0
    if #ready == 0 then
        if pending > 0 then
            log(string.format("🎯 自动配置：%d 台待换，最近一台还需 %s 食物（已预留，喂食不会吃掉）",
                pending, fmtShort(minPending)), Color3.fromRGB(160, 200, 255))
        end
        return
    end
    table.sort(ready, function(a, b)
        -- 初始CPS 倍数高的优先（真正的资产质量），其次看净增益
        local ra = (a.toBase or 0) / math.max(a.fromCps or 1, 1)
        local rb = (b.toBase or 0) / math.max(b.fromCps or 1, 1)
        if ra ~= rb then return ra > rb end
        return (a.gain or 0) > (b.gain or 0)
    end)
    if food < minFood then
        log(string.format("🎯 自动配置：%d 台可换，但食物 %s < 门槛 %s，等攒够再动手",
            #ready, fmtShort(food), fmtShort(minFood)), Color3.fromRGB(160, 200, 255))
        return
    end
    log(string.format("🎯 自动配置：开始执行 %d 台换人（食物 %s · 还需 %s 已预留）",
        #ready, fmtShort(food), fmtShort(needMore)), Color3.fromRGB(140, 220, 255))
    local ok, res = pcall(AST.execute, ready)
    if ok and type(res) == "table" then
        log(string.format("🎯 自动配置完成：成功 %d · 失败 %d（耗时 %.0f 秒）",
            res.done or 0, res.failed or 0, res.seconds or 0), Color3.fromRGB(120, 255, 140))
    else
        log("🎯 自动配置执行出错：" .. tostring(res):sub(1, 120), Color3.fromRGB(255, 120, 120))
    end
end
R.astAutoTick = AST.autoTick
R.rarityAllowed = AST.rarityAllowed          -- 供 UI / 排查使用

-- 🍔 统一读食物（唯一权威入口）
--
-- ⚠⚠⚠ 实测踩到的严重 bug：`autoTick` 里写的是 `R.foodNow()`，
--   但**这个函数根本不存在**（`R.foodNow` 是 nil），于是
--       `local food = R.foodNow and R.foodNow() or 0`  ->  food = 0
--   结果明明有 9.29B 食物，算法却以为食物是 0，**一台都不换**。
--   用户当场报告："我现在食物已经5B了，也不换"。
--   ⇒ 统一走这个函数；它直接读 `LocalPlayer.FoodNumber`（与喂食系统同源）。
function R.foodNow()
    local plr = game:GetService("Players").LocalPlayer
    if not plr then return 0 end
    local ok, v = pcall(function() return plr:GetAttribute("FoodNumber") end)
    if ok then return tonumber(v) or 0 end
    return 0
end

-- 🍔 喂食可用的食物上限（扣掉给"换人"预留的部分）
--   用户点出的死锁："在等食物期间自动喂食自己又工作在10B就把食物喂了，一直攒不到"
--   ⇒ 喂食前先问这个函数：只有"超出预留"的那部分才允许喂。
--     这样换人能稳定攒到目标，不会被喂食一点点吃掉。
function R.feedBudgetCap()
    local food = R.foodNow()
    local reserve = tonumber(R.astFoodReserve) or 0
    if cfg.astEnabled ~= true then reserve = 0 end     -- 没开自动配置就不用预留
    return math.max(0, food - reserve)
end

-- 展示用状态
function AST.status()
    local P = R.astLastPlan
    local o = {
        available = #AST.slots(),
        pairsKnown = #AST.PAIR_LIST,
        poolSize = P and P.poolSize or nil,
        changes = P and P.changes or nil,
        cpsBefore = P and P.cpsBefore or nil,
        cpsAfter = P and P.cpsAfter or nil,
        gain = P and P.gain or nil,
        lastAt = R.astLastAt,
        executed = R.astExecCount or 0,
        pairs = P and P.pairs or nil,
        pairBonus = P and P.pairBonus or nil,
        running = R._astRunning == true,
    }
    return o
end
R.astStatus = AST.status
R.astPlan = AST.plan
R.astSlotSnap = AST.slotSnap


--============================================================== 💞 配对加成（v271）
-- 游戏机制（本脚本 AST 模块早已实测）：
--   · 配对生效时**两边各得 ×3**，体现为**现金产出**，`CPS` 属性**不变**。
--   · 生效条件：两个角色**在同一行相邻**（|ΔY| ≤ 8 且水平距离 ≤ 12）。
-- ⇒ 对喂食而言，"喂这个台子能多赚多少"要乘 3，否则会把食物喂给收益只有 1/3 的台子。
--
-- ⚠ 只改「喂食优先级」，**绝不碰台子布局**（用户硬规则）。
-- ⚠ 缓存 2 秒：88 个台子 × 每对判相邻，不做缓存等于每次预览都跑几千次距离计算。
R.feedPairMult = function()
    R.feed = R.feed or {}
    local now = os.clock()
    local c = R.feed._pm
    if c and (now - (c.at or 0)) < 2 then return c.map, c.count, c.byUid end

    local mult = cfg.feedPairBonus ~= false and (tonumber(cfg.astPairMult) or 3) or 1
    local map, byUid = {}, {}
    local count = 0
    if mult <= 1 then
        R.feed._pm = { at = now, map = map, count = 0, byUid = byUid }
        return map, 0, byUid
    end

    -- ① 读出所有"有角色的台子"（名字 + 位置 + uid）
    local list = {}
    for _, st in ipairs(feedStands()) do
        local a = {}
        pcall(function() a = st.inst:GetAttributes() end)
        if a.HasCharacter == true then
            local pos
            pcall(function()
                if st.inst:IsA("BasePart") then pos = st.inst.Position
                else
                    local b = st.inst:FindFirstChildWhichIsA("BasePart", true)
                    if b then pos = b.Position end
                end
            end)
            if pos then
                list[#list + 1] = {
                    name = tostring(a.CharacterName or ""),
                    uid = tostring(a.CharacterUid or ""),
                    pos = pos,
                }
            end
        end
    end

    -- ② 名字 -> 伙伴集合（用 AST 的配对表；已被用户黑名单过滤过的那份仍按原样用）
    local PO = nil
    if R.astPairList then
        PO = {}
        for _, pr in ipairs(R.astPairList) do
            local x, y = tostring(pr[1]), tostring(pr[2])
            PO[x] = PO[x] or {}; PO[x][y] = true
            PO[y] = PO[y] or {}; PO[y][x] = true
        end
        -- 额外别名（表里只对 Madoki/Homara 做了变体，这里一并吃进来）
        for canon, aliases in pairs(R.astPairOf or {}) do end
    end
    if not PO then
        R.feed._pm = { at = now, map = map, count = 0, byUid = byUid }
        return map, 0, byUid
    end

    -- ③ 逐个台子找"相邻的配对伙伴"
    for i, s1 in ipairs(list) do
        local ps = PO[s1.name]
        if ps then
            for j, s2 in ipairs(list) do
                if i ~= j and ps[s2.name] then
                    local dy = math.abs(s1.pos.Y - s2.pos.Y)
                    if dy <= 8 then
                        local dx, dz = s1.pos.X - s2.pos.X, s1.pos.Z - s2.pos.Z
                        if math.sqrt(dx * dx + dz * dz) <= 12 then
                            -- ① 用 uid 作键（同角色多台也能分别记）
                            if s1.uid ~= "" then byUid[s1.uid] = mult end
                            -- ② 兜底：同一角色名在台上可能出现多台，用 名字 作键
                            --    （只要有一台配上了，按名字判定的台子就算配上）
                            map[s1.name] = mult
                            count = count + 1
                            break
                        end
                    end
                end
            end
        end
    end
    R.feed._pm = { at = now, map = map, count = count, byUid = byUid }
    return map, count, byUid
end

-- 生成"可喂食候选"列表：有角色、有产出、有成本数据、没被排除
local function feedCandidates()
    local ex = {}
    for piece in tostring(cfg.feedExcludeStands or ""):gmatch("[^,，]+") do
        local t = piece:match("^%s*(.-)%s*$")
        if t ~= "" then ex[t] = true end
    end
    local minCps = tonumber(cfg.feedMinCps) or 0
    -- 💞 配对倍率（v271）：配对生效的台子每级实际多赚 ×3，喂它更值
    local pmap, pcount, pbyUid = R.feedPairMult()
    local list = {}
    for _, s in ipairs(feedStands()) do
        local snap = feedSnapshot(s.inst)
        snap.label = s.label
        local hasPrompt = false
        pcall(function() hasPrompt = snap.prompt ~= nil end)
        if snap.has and hasPrompt and snap.name ~= "" and not ex[s.label] and not ex[snap.name] then
            if snap.cps >= minCps and snap.level > 0 then
                snap.cost = feedCost(snap.rarity, snap.level)
                snap.rawGain = feedGain(snap.cps, snap.level)      -- 原始单级收益（门槛用）
                -- ★ 配对倍率：优先按 uid 精确匹配，退化到名字匹配
                local pm = 1
                if pbyUid and snap.uid ~= "" and pbyUid[snap.uid] then pm = pbyUid[snap.uid]
                elseif pmap and snap.name ~= "" and pmap[snap.name] then pm = pmap[snap.name] end
                snap.pairMult = pm
                snap.paired = pm > 1
                -- ★ 把配对加成乘进 gain / eff：
                --   喂食的贪心循环按 `gain / cost` 挑下一个喂谁，
                --   所以乘在这里 = **配对中的台子自然被优先喂**（它的每口食物真的多赚 3 倍）。
                snap.gain = snap.rawGain and (snap.rawGain * pm) or nil
                snap.baseCost = levelBaseCostOf(snap.rarity)
                if snap.cost and snap.gain and snap.baseCost then
                    snap.eff = snap.gain / snap.cost
                    list[#list + 1] = snap
                end
            end
        end
    end
    R.feed._pairCount = pcount
    table.sort(list, function(a, b) return a.eff > b.eff end)
    return list
end
R.feedCandidates = feedCandidates

-- ★ 计算"相对收益门槛"的基准：当前**买得起**的台子里最高的单级绝对收益。
--   ⚠ 按"买得起"算：若只按全屋最高，而最高收益者此刻买不起（如 Kafka 单级 1.05B 而食物只剩 0.5B），
--     门槛会被抬得过高 -> 谁都喂不了 -> 脚本饿死。
--   ⚠⚠ v271：这里必须用 **rawGain（未乘配对倍率）**。
--     该门槛的语义是"单级绝对收益够不够大"，而配对加成是**排序因素**不是**准入因素**；
--     若用乘过 3 倍的 gain 取最大值，门槛会被抬高到 3 倍，
--     结果把所有**没配对**的中等台子一次性判死（本该喂的被误杀）。
local function feedMaxGain(food)
    local best = 0
    for _, c in ipairs(feedCandidates()) do
        local g = c.rawGain or c.gain or 0
        if c.cost and c.cost <= (food or 0) and g > best then best = g end
    end
    return best
end
R.feedMaxGain = feedMaxGain

local function feedRelFloor(maxGain)
    local ratio = tonumber(cfg.feedMinRelGain) or 0
    if ratio <= 0 then return 0 end
    return (maxGain or 0) * ratio
end
R.feedRelFloor = feedRelFloor

--★ 贪心最优分配：每口都喂当前性价比最高的台子（并应用相对收益门槛）
local function feedPlan(budget)
    budget = tonumber(budget) or 0
    local list = feedCandidates()
    local minEff = tonumber(cfg.feedMinEfficiency) or 0
    local maxActions = math.floor(tonumber(cfg.feedMaxActionsPerCycle) or 0)
    -- ★ 相对收益门槛：单级绝对收益太小的台子直接出局（解决"低 CPS 却高性价比"的陷阱）
    --   ⚠ v271：门槛比较用 **rawGain**（未乘配对倍率），与 feedMaxGain 口径一致；
    --     否则配对台子的 3 倍收益会被拿去比"未配对的原始门槛"，语义就乱了。
    local floor = feedRelFloor(feedMaxGain(budget))
    local st = {}
    for i, c in ipairs(list) do
        if (c.rawGain or c.gain or 0) >= floor then
            st[#st + 1] = { snap = c, L = c.level, cps = c.cps, cost = c.cost, gain = c.gain,
                            n = 0, spent = 0, gainSum = 0, startLevel = c.level }
        end
    end
    local food = budget
    local actions = 0
    local stepCap = 400000
    while actions < stepCap do
        if maxActions > 0 and actions >= maxActions then break end
        local bi, be = nil, -1
        for i = 1, #st do
            local s = st[i]
            if s.cost and s.cost <= food then
                local e = s.gain / s.cost
                if e > be then bi, be = i, e end
            end
        end
        if not bi then break end
        if be < minEff then break end
        local s = st[bi]
        food = food - s.cost
        s.spent = s.spent + s.cost
        s.gainSum = s.gainSum + s.gain
        s.cps = s.cps + s.gain
        s.L = s.L + 1
        s.n = s.n + 1
        s.cost = feedCost(s.snap.rarity, s.L)
        s.gain = feedGain(s.cps, s.L)
        actions = actions + 1
    end
    local plan, totalSpent, totalGain = {}, 0, 0
    for i = 1, #st do
        local s = st[i]
        if s.n > 0 then
            plan[#plan + 1] = { snap = s.snap, label = s.snap.label, name = s.snap.name,
                                rarity = s.snap.rarity, mut = s.snap.mut,
                                from = s.startLevel, to = s.L, levels = s.n,
                                spent = s.spent, gain = s.gainSum,
                                eff = s.gainSum / s.spent }
            totalSpent = totalSpent + s.spent
            totalGain = totalGain + s.gainSum
        end
    end
    table.sort(plan, function(a, b) return a.spent > b.spent end)
    return plan, totalSpent, totalGain, actions
end
R.feedPlan = feedPlan

-- 全屋当前总 CPS
local function feedTotalCps()
    local t = 0
    for _, s in ipairs(feedStands()) do
        local a = {}
        pcall(function() a = s.inst:GetAttributes() end)
        if a.HasCharacter then t = t + (tonumber(a.CPS) or 0) end
    end
    return t
end
R.feedTotalCps = feedTotalCps

--★ 用面板真实价格校准折扣系数
local function feedCalibrate(verbose)
    local samples = {}
    for _, s in ipairs(feedStands()) do
        local snap = feedSnapshot(s.inst)
        if snap.has and snap.shownCost and snap.shownCost > 0 then
            local bc = levelBaseCostOf(snap.rarity)
            local cv = levelCurve(snap.level)
            if bc and cv and cv > 0 then
                local ratio = snap.shownCost / (bc * cv)
                if ratio > 0 and ratio < 5 then samples[#samples + 1] = ratio end
            end
        end
    end
    if #samples == 0 then return nil end
    local sum = 0
    for _, v in ipairs(samples) do sum = sum + v end
    local avg = sum / #samples
    local snapped = avg
    local shelves = { 1.0, 0.9, 0.5, 0.25, 0.225, 0.2, 0.125 }
    local best, bd = nil, math.huge
    for _, v in ipairs(shelves) do
        local d = math.abs(avg - v) / v
        if d < bd then best, bd = v, d end
    end
    if best and bd < 0.06 then snapped = best end
    R.feed = R.feed or {}
    R.feed.keep = snapped
    R.feed.keepRaw = avg
    R.feed.keepSamples = #samples
    if verbose then
        log(string.format("🍖 折扣校准：面板反解 %.4f（%d 个样本）→ 采用 %.4f", avg, #samples, snapped),
            Color3.fromRGB(140, 220, 255))
    end
    return snapped
end
R.feedCalibrate = feedCalibrate
R.feedKeepFactor = function() return (R.feed and R.feed.keep) or tonumber(cfg.feedKeep) or 0.225 end

-- 执行一口：把角色升 1 级（含执行点安全校验）
local function feedOne(snapExpected)
    local food0 = tonumber(LocalPlayer:GetAttribute("FoodNumber"))
    if not food0 then return false, "读不到食物数量" end
    -- 复核 1：台子内容必须与计划一致（防止台子被换过导致喂错角色）
    local snap = feedSnapshot(snapExpected.stand)
    if not snap.has then return false, "台子已空" end
    if snap.name ~= snapExpected.name then
        return false, "台子内容已变（计划 " .. tostring(snapExpected.name) .. "，实际 " .. tostring(snap.name) .. "）"
    end
    if snap.level ~= snapExpected.level then
        return false, string.format("等级已变（计划 L%d，实际 L%d）", snapExpected.level, snap.level)
    end
    -- 复核 2：面板价格必须付得起
    local need = snap.shownCost or feedCost(snap.rarity, snap.level)
    if not need then return false, "算不出价格" end
    if food0 < need then
        return false, string.format("食物不够（需要 %s，只有 %s）", fmtShort(need), fmtShort(food0))
    end
    -- ⚠⚠ 传送到台子旁并等 prompt 启用 —— 必须【多位置重试】（用户实测踩到）：
    --   症状："tp 到角色后喂食按钮会消失，而且喂一次就不喂了，整批结束"，
    --         结果 10B 食物只用了 2B，剩 8B 留在手里。
    --   根因：
    --     ① 传送后 prompt 需要时间重新启用（"按钮消失"就是它短暂禁用）；
    --        旧代码只等 2.5 秒，超时就 return false。
    --     ② feedExecute 把这种失败当致命错误 -> `break` 中止**整批**。
    --   对策：换几个更近/不同的落点各试一次（prompt 启用需要玩家在 6 格内且站位合适），
    --         总预算约 6 秒；仍然不行才返回失败（由上层决定跳过而不是中止）。
    local hrp = rootPart()
    local OFFS = {
        Vector3.new(0, 3, 4),        -- 斜前方（原方案）
        Vector3.new(0, 2, 2.5),      -- 更近
        Vector3.new(3, 2, 0),
        Vector3.new(-3, 2, 0),
        Vector3.new(0, 2, -2.5),
    }
    -- ★★★ v165 关键修复：每次喂食前必须重新"离开→靠近"一次 ★★★
    -- 实测（用户报告"按钮出现了但压根没喂上"）：
    --   · 从远处传送过来 -> 立即 fire  ==> **成功**（实测 Lv 3→4）
    --   · 人已经在范围内 -> 直接 fire  ==> **失败**
    --     （客户端读到的 prompt.Enabled 明明是 true，服务器却静默忽略这次 fire）
    --   根因：服务器要收到一次**新的"玩家进入范围"事件**（PromptShown）才会"武装"这个 prompt。
    --   一旦武装状态被上一次交互消耗掉，光靠 fireproximityprompt 是无效的 ——
    --   而客户端读到的 Enabled 是陈旧的，所以看起来"按钮在、点了没反应"。
    --   v160 那个"已在附近就跳过传送"的流畅性优化恰好跳掉了这个事件 -> 把台子喂废。
    --   ⇒ 结论：**宁可多一次位置跳变，也绝不复用旧的武装状态。**
    --   ⚠ 远落点只负责"离开"，不算候选落点，所以失败提示里的落点数仍然只数下面这些。
    --
    -- ★★★ 流畅性修复（用户实测报告，2026-10）★★★
    --   用户原话："我发现自动喂食一直在角色面前原地tp，明明喂食按键已经出来了，
    --             导致喂食特别慢"
    --
    --   根因：原来**无条件**先传送到 AWAY（远处）再回来，而且 AWAY 的等待只有 0.05 秒 ——
    --         服务端很可能还没收到"玩家离开范围"事件，于是"重新武装"根本没生效，
    --         接着就要试 5 个落点，每个落点又各等 1.2~1.5 秒 =>
    --         表现出来就是"在角色面前反复原地 TP，很慢"。
    --
    --   ⇒ 改成**先看再动**：
    --       ① 先读一次 prompt.Enabled —— 如果它**已经启用**（按键已出现），
    --          说明武装状态是新鲜的（服务端刚给过 PromptShown），直接 fire，
    --          **完全不做任何传送** —— 这是绝大多数情况，速度立刻正常。
    --       ② 只有确实没启用时才走"离开 -> 回来"重新武装，并且把 AWAY 的等待
    --          从 0.05 提到 0.4 秒（确保服务端记录到离开），回来后再等最多 2 秒。
    local AWAY = Vector3.new(0, 10, 30)
    local en = false
    -- ① 第一步：不做任何传送，直接读当前状态
    pcall(function() en = snap.prompt and snap.prompt.Enabled end)
    if not en and hrp and snap.nodePos then
        -- ② 只有没启用才"离开 -> 回来"重新武装（AWAY 等待提到 0.4 秒）
        pcall(function()
            hrp.CFrame = CFrame.new(snap.nodePos + AWAY)
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end)
        task.wait(0.4)      -- ⚠ 0.05 太短，服务端收不到"离开"-> 重新武装失效
        for oi, off in ipairs(OFFS) do
            if en then break end
            if not isCurrent() then break end
            local h = hrp or rootPart()
            if h and snap.nodePos then
                pcall(function()
                    h.CFrame = CFrame.new(snap.nodePos + off)
                    h.AssemblyLinearVelocity = Vector3.zero
                    h.AssemblyAngularVelocity = Vector3.zero
                end)
            end
            -- 单次最多等 2 秒（前两次等短一点，快速换位）
            local waitMax = (oi == 1) and 1.5 or 1.2
            local t0 = os.clock()
            while isCurrent() and (os.clock() - t0) < waitMax do
                pcall(function() en = snap.prompt and snap.prompt.Enabled end)
                if en then break end
                task.wait(0.1)
            end
            pcall(function() en = snap.prompt and snap.prompt.Enabled end)
        end
    end
    if not en then
        return false, "喂食提示未启用（试了 " .. #OFFS .. " 个落点都没等到，台子可能不可用）"
    end
    -- 触发
    local ok = pcall(fireproximityprompt, snap.prompt)
    if not ok then
        return false, "fireproximityprompt 失败"
    end
    -- 复核 3：必须观察到「等级提升 或 食物减少」
    --   ⚠ 实测教训（用户反馈"喂一次就不喂了"）：原来要求【等级+1 **且** 食物减少】同时成立，
    --     并且只等 2.5 秒。但服务器属性同步有延迟（尤其连续喂同一个台子时），
    --     经常出现"食物已经扣了、等级属性还没刷新" -> 被误判成失败。
    --   现在：① 等待放宽到 4 秒；② 只要【等级提升】或【食物减少】任一成立就算成功
    --        （食物被扣是服务器已接受的铁证；等级+1 是另一条独立证据）；
    --     ③ 成功后顺手把期望等级推进，供下一轮复核用。
    t0 = os.clock()
    local sawFoodDrop, sawLevelUp = false, false
    -- ★★★ v165：失败就"重新武装 + 再 fire" ★★★
    -- 服务器有时会把这次 fire 静默丢掉（武装状态被消耗）。实测"重新离开再靠近"
    -- 一定能让它重新武装，所以这里带重试，而不是等 4 秒就认输跳过这个台子 ——
    -- 用户看到的现象正是"跳到角色面前、按钮闪一下、然后跳过好几个角色"。
    local FIRE_WAIT = 1.2          -- 单次 fire 后等多久算"没反应"
    local tries = 0
    local deadline = os.clock() + 9
    while isCurrent() and os.clock() < deadline do
        local wt = os.clock() + FIRE_WAIT
        while isCurrent() and os.clock() < wt do
            task.wait(0.15)
            local lv = tonumber(snapExpected.stand:GetAttribute("Level")) or 0
            local f1 = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or food0
            if lv >= snapExpected.level + 1 then sawLevelUp = true end
            if f1 < food0 then sawFoodDrop = true end
            if sawFoodDrop or sawLevelUp then
                R.feed = R.feed or {}
                R.feed.sawFoodDrop = (R.feed.sawFoodDrop or 0) + (sawFoodDrop and 1 or 0)
                R.feed.sawLevelUp = (R.feed.sawLevelUp or 0) + (sawLevelUp and 1 or 0)
                -- fireRetries = 累计"服务器静默丢弃、需要重新武装重试"的次数。
                -- 这是个很有价值的健康度指标：一直很小说明交互稳定；
                -- 如果它持续变大，说明服务器/网络开始丢 prompt 事件了。
                R.feed.fireRetries = (R.feed.fireRetries or 0) + tries
                -- ★ v160：额外返回【新的等级】。调用方以前是在返回之后自己再读一次
                --   GetAttribute("Level")，可那时属性可能还没刷新 -> 拿到的还是旧等级 ->
                --   下一轮复核判定"不相等" -> 整个批次被误中止。现在直接用这里已经
                --   确认过的 lv，等待时间直接省掉。
                return true, nil, food0 - f1, math.max(lv, snapExpected.level + 1)
            end
        end
        tries = tries + 1
        if not isCurrent() then break end
        -- 重新武装：离开 -> 回到范围内 -> 等 Enabled -> 再 fire
        local h = rootPart()
        if h and snap.nodePos then
            pcall(function()
                h.CFrame = CFrame.new(snap.nodePos + AWAY)
                h.AssemblyLinearVelocity = Vector3.zero
                h.AssemblyAngularVelocity = Vector3.zero
            end)
            task.wait(0.05)
            pcall(function()
                h.CFrame = CFrame.new(snap.nodePos + OFFS[1])
                h.AssemblyLinearVelocity = Vector3.zero
                h.AssemblyAngularVelocity = Vector3.zero
            end)
            local t1 = os.clock()
            while isCurrent() and (os.clock() - t1) < 1.5 do
                local e2 = false
                pcall(function() e2 = snap.prompt and snap.prompt.Enabled end)
                if e2 then break end
                task.wait(0.1)
            end
        end
        pcall(fireproximityprompt, snap.prompt)
    end
    return false, string.format("喂食后未观察到等级提升或扣费（重试 %d 次共等 %.0f 秒；等级 %s，食物 %s）",
        tries, os.clock() - t0, tostring(snapExpected.stand:GetAttribute("Level")),
        fmtShort(tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0))
end
R.feedOne = feedOne

-- 执行一整批计划
feedExecute = function(budget)
    local F = R.feed
    -- 🚦 **原子占位**（v146）：必须"先抢再干"，抢不到就直接退出。
    --   旧写法是无条件 busySuggest（它会覆盖 busy 表！）——于是
    --   "去突变正在放角色"时喂食可以强行插进来，两边同时传送，谁都做不成。
    --   现在改成：抢不到就返回 false，由调用方下一轮再试。
    if not R.busySuggest("喂食", "自动喂食") then
        local who = R.busyWho()
        if not F._busyLogged then
            F._busyLogged = true
            log("⏸ 自动喂食让路：" .. R.yieldLabel(who or "") .. " 正在使用角色位置", Color3.fromRGB(255, 200, 90))
        end
        return (false)
    end
    F._busyLogged = nil
    F.running = true
    -- ⚠ 时基统一（v160）：feedTick 里判断冷却用的是 os.clock()，所以这里也必须用 os.clock()。
    --   以前是 os.time()（墙钟）——两个时基混用，冷却比较会得到一个巨大的差值，等于冷却失效。
    F.lastRunAt = os.clock()
    local batchT0 = os.clock()      -- ★ v160：批次的墙上耗时（喂食流畅度的直接指标）
    local totalSpent, totalGain, doneActions, failMsg = 0, 0, 0, nil
    local cpsBefore = feedTotalCps()
    local plan, pSpent, pGain, pActions = feedPlan(budget)
    if #plan == 0 then
        R.busyClear("喂食")       -- 🚦 别忘了释放
        F.running = false
        F.lastSummary = "本批没有值得喂的目标（性价比不足或食物不够）"
        log("🍖 没有可执行的喂食计划（性价比低于阈值 " .. tostring(cfg.feedMinEfficiency) ..
            "，或食物不够付任何一台的一级）", Color3.fromRGB(255, 200, 90))
        return (false)
    end
    log(string.format("🍖 开始执行喂食批次：%d 个台子 · %d 级 · 预算 %s",
        #plan, pActions, fmtShort(budget)), Color3.fromRGB(140, 220, 255))
    F.planned = plan
    for i, item in ipairs(plan) do
        if not isCurrent() then break end
        if not cfg.feedEnabled then
            failMsg = "喂食已被关闭，批次中止"
            break
        end
        local snapExp = feedSnapshot(item.snap.stand)
        snapExp.label = item.label
        local fed = 0
        while fed < item.levels do
            if not isCurrent() or not cfg.feedEnabled then break end
            local cur = feedSnapshot(item.snap.stand)
            if not cur.has or cur.name ~= item.name then
                failMsg = string.format("台子 %s 在执行中发生变化 -> 中止本批", item.label)
                break
            end
            -- ★ 等级漂移容忍（v160）：只允许"比计划高 1 级"，那说明**上一级其实已经成功**，
            --   只是服务器还没把等级属性刷到我们看到的那一刻（旧代码据此直接中止整批，
            --   剩下的食物这一批就没人接手了）。等半秒取到真实等级后再继续。
            --   差 2 级以上才是真的被换过 / 被别处改过，那种才中止。
            if cur.level ~= snapExp.level then
                local d = cur.level - snapExp.level
                if d == 1 then
                    task.wait(0.5)
                    local cur2 = feedSnapshot(item.snap.stand)
                    if cur2.has and cur2.name == item.name then
                        cur = cur2
                    end
                    if cur.level ~= snapExp.level then
                        F.levelsResynced = (F.levelsResynced or 0) + 1
                        snapExp.level = cur.level
                        snapExp.cps = cur.cps
                    end
                else
                    failMsg = string.format("台子 %s 在执行中发生变化（计划 L%d，实际 L%d）-> 中止本批",
                        item.label, snapExp.level, cur.level)
                    break
                end
            end
            local ok, err, spent, newLv = feedOne(cur)
            if not ok then
                -- ⚠ 用户实测痛点：单台失败就 break -> 整批结束 -> 攒的 10B 只用掉 2B。
                --   改成"跳过这台、继续喂下一台"，只记最后一次错误；连续失败太多才真中止。
                local em = tostring(err)
                F.lastSkip = string.format("%s: %s", item.name, em)
                log("⚠ 跳过 " .. item.name .. "（" .. em .. "），继续喂下一台", Color3.fromRGB(255, 200, 90))
                break        -- 只跳出这台的 while（换下一台），不是整批
            end
            fed = fed + 1
            doneActions = doneActions + 1
            totalSpent = totalSpent + (spent or 0)
            -- ★ v160：优先用 feedOne 已经确认过的等级；读不到才退回自己读属性
            --   （旧代码总是在这里重新读一次，属性没刷新时就会拿到旧等级 ->
            --    下一轮复核失配 -> 整批被误中止）
            local lv = tonumber(newLv) or (tonumber(item.snap.stand:GetAttribute("Level")) or 0)
            local cps = tonumber(item.snap.stand:GetAttribute("CPS")) or 0
            snapExp.level = lv
            snapExp.cps = cps
            totalGain = totalGain + (feedGain(cps, lv) or 0)
            if cfg.feedLogEach ~= false and (fed % 10 == 0) then
                log(string.format("🍖 %s %s L%d（本级已喂 %d 级）", item.label, item.name, lv, fed),
                    Color3.fromRGB(160, 220, 255))
            end
            -- 性价比被别的台子超过就提前换（贪心的在线版本；短路扫描，找到即停）
            if fed < item.levels then
                local myCost = feedCost(cur.rarity, lv)
                local myGain = feedGain(cps, lv)
                local myEff = (myCost and myGain) and (myGain / myCost) or 0
                local foodNow = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0
                local floorNow = feedRelFloor(feedMaxGain(foodNow))
                local beaten = false
                for _, other in ipairs(feedCandidates()) do
                    if other.label ~= item.label and other.eff > myEff and (other.gain or 0) >= floorNow then
                        beaten = true break
                    end
                end
                if not beaten and myGain and myGain < floorNow then beaten = true end
                if beaten then
                    if cfg.feedLogEach ~= false then
                        log(string.format("🍖 %s 的性价比(%.4f)已被别的台子超过 -> 本批提前切换",
                            item.label, myEff), Color3.fromRGB(200, 200, 140))
                    end
                    break
                end
            end
            task.wait(0.05)
        end
        if failMsg then break end
        if i == 1 then feedCalibrate(false) end
        task.wait(0.1)
    end
    -- ★★ 多轮补喂（v140）★★
    -- 实测问题（用户反馈"到 10B 又没喂完"）：
    --   计划 3 台 / 12 级，但执行中每个台子都可能因为
    --   "性价比已被别的台子超过 -> 本批提前切换" 而提前中断；
    --   而那个"超过它的台子"**并不在本批计划里** -> 于是 12 级只喂了 6 级，
    --   剩下的食物这一批就没人接手了（实测 10.83B 预算只花 6.37B）。
    -- 对策：一轮跑完后**重新规划**再跑一轮，直到"没钱可花 / 无值得喂的目标"。
    --   上限 feedMaxPasses 轮，防止任何意外情况下无限循环。
    local maxPasses = math.max(1, math.floor(tonumber(cfg.feedMaxPasses) or 6))
    local pass = 1
    while pass < maxPasses do
        if not isCurrent() or not cfg.feedEnabled then break end
        local foodLeft = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0
        if foodLeft <= 0 then break end
        local plan2, _, _, acts2 = feedPlan(foodLeft)
        if #plan2 == 0 or (acts2 or 0) <= 0 then break end
        -- 至少要能真的花掉一点食物才继续（避免"计划非空但一级都买不起"时空转）
        local cheapest = nil
        for _, c in ipairs(feedCandidates()) do
            if c.cost and (cheapest == nil or c.cost < cheapest) then cheapest = c.cost end
        end
        if cheapest == nil or foodLeft < cheapest then break end
        pass = pass + 1
        log(string.format("🍖 第 %d 轮补喂：重新规划出 %d 台 / %d 级（剩余食物 %s）",
            pass, #plan2, acts2 or 0, fmtShort(foodLeft)), Color3.fromRGB(160, 220, 255))
        for _, item in ipairs(plan2) do
            if not isCurrent() or not cfg.feedEnabled then break end
            local snapExp2 = feedSnapshot(item.snap.stand)
            snapExp2.label = item.label
            local fed2 = 0
            while fed2 < item.levels do
                if not isCurrent() or not cfg.feedEnabled then break end
                local cur2 = feedSnapshot(item.snap.stand)
                if not cur2.has or cur2.name ~= item.name then break end
                local ok2, err2, spent2, newLv2 = feedOne(cur2)
                if not ok2 then
                    F.lastSkip = string.format("%s: %s", item.name, tostring(err2))
                    break
                end
                fed2 = fed2 + 1
                doneActions = doneActions + 1
                totalSpent = totalSpent + (spent2 or 0)
                local lv2 = tonumber(newLv2) or (tonumber(item.snap.stand:GetAttribute("Level")) or 0)
                totalGain = totalGain + (feedGain(cur2.cps or 0, lv2) or 0)
                task.wait(0.05)
            end
            task.wait(0.1)
        end
        local fNow = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0
        if fNow >= foodLeft then break end      -- 这一轮一点都没花掉 -> 停
    end

    local cpsAfter = feedTotalCps()
    R.busyClear("喂食")           -- 🚦 释放：钓鱼可以恢复
    F.running = false
    F.actions = (F.actions or 0) + doneActions
    F.spent = (F.spent or 0) + totalSpent
    F.gain = (F.gain or 0) + totalGain
    F.batches = (F.batches or 0) + 1
    F.lastActions = doneActions
    F.lastSpent = totalSpent
    F.lastGain = totalGain
    F.lastAt = os.date("%H:%M:%S")
    F.cpsBefore = cpsBefore
    F.cpsAfter = cpsAfter
    F.lastFail = failMsg
    F.lastSeconds = os.clock() - (batchT0 or os.clock())
    F.lastSummary = string.format("%d 级 · 花 %s · 全屋 CPS %s -> %s",
        doneActions, fmtShort(totalSpent), fmtShort(cpsBefore), fmtShort(cpsAfter))
    -- 汇总：如果还有大量食物没花掉，明确告诉用户原因（便于定位"只喂了一点就结束"）
    do
        local left = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0
        -- ★ v160：把"剩下的食物为什么没花掉"的原因分成几档，写进状态里给 UI/日志看，
        --   不用再去猜（这是排查"喂食不流畅/只喂一点"最关键的一条线索）。
        local cands = feedCandidates()
        local nextCost = cands[1] and cands[1].cost or nil
        F.lastLeft = string.format("剩余 %s", fmtShort(left))
        F.lastStop = failMsg and "中止"
            or (doneActions == 0 and "一级都没喂成")
            or ((nextCost and left < nextCost) and "食物不够下一台的一级"
                or (left > 0 and "已无可喂目标（性价比/门槛/已喂满）" or "食物已花光"))
    end
    if failMsg then
        log("⚠ 喂食批次中止：" .. tostring(failMsg), Color3.fromRGB(255, 120, 120))
    else
        log(string.format("✅ 喂食批次完成：%d 级 · 耗时 %.1f 秒 · 花费 %s · 全屋 CPS %s -> %s (%+.2f%%) · %s",
            doneActions, F.lastSeconds or 0, fmtShort(totalSpent), fmtShort(cpsBefore), fmtShort(cpsAfter),
            cpsBefore > 0 and (100 * (cpsAfter - cpsBefore) / cpsBefore) or 0,
            tostring(F.lastLeft or "")),
            Color3.fromRGB(120, 255, 140))
    end
    if R.renderFeedList then pcall(R.renderFeedList) end
    if R.renderStatus then pcall(R.renderStatus) end
    if cfg.feedNotify ~= false and R.notify then
        pcall(R.notify, {
            Title = failMsg and "⚠ 喂食批次中止" or "🍖 喂食完成",
            Description = F.lastSummary .. (failMsg and ("\n" .. tostring(failMsg)) or ""),
            Time = 8, Icon = failMsg and "triangle-alert" or "beef",
        })
    end
    -- 只返回一个值：多返回值会让 pcall 摊成元组，调用方容易误用
    return (doneActions > 0)
end
R.feedThread = feedExecute

-- ★★★ 食物产出速率：**全脚本唯一权威来源** ★★★
-- 背景（实测踩到的坑）：以前喂食模块和总经理**各测各的**——
--   · 喂食 feedTick 用 os.time() 做 10 秒窗口差分；
--   · 总经理 managerTick 又自己做 15 秒窗口差分。
--   两个窗口不同 + 各自平滑，于是同一时刻 UI 上出现两个不同的"食物速率"：
--   实测同一瞬间「花园属性 5.27M/s」vs「总经理 7.38M/s」，差 1.4 倍。
--   后果：UI 显示一个数、总经理按另一个数决策，用户看到"数字对不上"。
-- ✅ 现在统一到 R.foodRate()：一次采样，喂食 / 总经理 / 界面全用它。
--
-- 设计要点（v167 按"服务器跳变式同步"重写）：
--   ⚠⚠ **最重要的前提（用户实测确认）**：`FoodNumber` 属性**不是每秒实时更新的**，
--      服务器每隔几秒才推一次，所以这个值是一段一段"跳"上去的，不是平滑曲线。
--      由此推出两条铁律：
--        ① **锚点只能在"食物值真正变化"时重新建立**，否则 df（真实产出）会被除以一个
--           不完整的窗口 dt，速率被算大好几倍 —— 实测出现过 30.88M/s 而花园属性
--           只有 3.8M/s（8 倍）的假读数，UI 的"攒够还要几分钟"和总经理的 ETA 一起失真。
--        ② 采样窗口要足够长（≥8 秒），才能横跨 2~4 次服务器推送，把 jitter 平均掉。
--   · **喂食批次执行期间不采样**：那时食物在被花掉，Δ 可能为负。
--     让"批前锚点"原地等，批次结束后第一个样本自动横跨整个批次，测出来仍是真实产出。
--   · 取 max(实测差分, 花园属性合计)：启动最初几秒差分还不可用，
--     先退回花园属性，UI 立刻有数而不是显示"测量中…"。
--   · 另加一道保守护栏：读数超过花园属性 30 倍直接判为不可信并丢弃
--     （正常真实速率约为属性的 1~2 倍；这个倍数留足了加成叠加的余地）。
-- ⚠⚠ 这里**故意不写成 `local function`**：顶层 local 已经贴着 200 的上限
--   （v167 一度报 "Out of local registers ... exceeded limit 200"）。
--   改成挂到 R 上的字段，省下一个顶层 local 名额。
R.foodRateSample = function()
    R.feed = R.feed or {}
    local F = R.feed
    -- 花园属性合计（立刻可读，但只是"基础产出"，不含加成/药水）
    local attrSum = 0
    local plot = floorStand()
    local pu = plot and plot:FindFirstChild("Purchases")
    if pu then
        for _, g in ipairs(pu:GetChildren()) do
            local v = g:GetAttribute("CurrentFoodPerSecond")
            if tonumber(v) then attrSum = attrSum + tonumber(v) end
        end
    end
    F.perSecondAttr = attrSum
    local food = tonumber(LocalPlayer:GetAttribute("FoodNumber"))
    if not food then return math.max(tonumber(F.measuredRate) or 0, attrSum), attrSum end
    F.food = food
    local now = os.clock()      -- ⚠ 绝不能写 tick()：会调到本脚本自己的主循环 -> 无限递归（坑 ①-b）
    if F._accF == nil then
        -- 第一个锚点
        F._accF, F._accT, F._lastFood = food, now, food
    elseif not F.running then
        if food ~= F._lastFood then
            -- 服务器刚推了一次新值 —— **这里才是可以测量的时刻**
            local df = food - F._accF
            local dt = now - (F._accT or now)
            if df >= 0 and dt >= HW_K.RATE_MIN_WINDOW then
                local r = df / dt
                if r > 0 and (attrSum <= 0 or r <= attrSum * HW_K.RATE_SANITY_MULT) then
                    local a = math.min(0.35, dt / 15)
                    F.measuredRate = F.measuredRate and (F.measuredRate * (1 - a) + r * a) or r
                    F.measuredRateRaw = r
                    F.measuredWindow = dt
                elseif r > 0 then
                    F.rateRejected = (F.rateRejected or 0) + 1     -- 离谱读数，丢弃（保留锚点）
                end
                F._accF, F._accT = food, now
            elseif dt > 120 then
                -- 太久没动静（换花园/长时间暂停产出），直接重新起锚，避免下次算出一个荒唐的值
                F._accF, F._accT = food, now
            end
            -- ⚠ 注意：窗口还不够长时**故意不动锚点**，让区间继续累积 —— 这是上面那条铁律①的落地
            F._lastFood = food
        end
    end
    return math.max(tonumber(F.measuredRate) or 0, attrSum), attrSum
end
-- 对外取值：无论何时调用都会顺带采样一次（廉价），并返回统一的速率
-- （同样挂 R 上，不新增顶层 local）
R.feedFoodRate = function()
    local rate, attrSum = R.foodRateSample()
    return rate, attrSum
end

-- ★★ 攒批阈值（v148 重写）★★
-- ⚠⚠ 用户实测踩到的严重问题："阈值一直在变动、忽高忽低，到了 10B 还是不去喂"
--   旧公式： threshold = max(fixed, rate * mins * 60)
--   而 rate 实测在 4M/s ~ 44M/s 之间剧烈波动（食物类加成/药水/花园换人），于是阈值在
--     max(10B, 4.8B)=10B  与  max(10B, 52.8B)=52.8B  之间来回跳。
--   后果：食物涨到 10B 时阈值可能正好是 52.8B -> 不喂；等你继续攒，速率掉下来阈值又变回 10B
--         -> 看起来"阈值忽高忽低、永远追不上"。
-- ✅ 现在：**阈值只由固定值决定，绝不随速率漂移**。
--    但仍要防止"食物产出暴涨时食物躺着不花"，所以把那个诉求改成独立的
--    【停留时间】规则（见 feedTick 里的 feedSitMinutes）：食物达到阈值后若久久没被喂掉，
--    就立刻喂一次。这样阈值稳定可预期，又不会让食物积压。
local function feedThreshold()
    return tonumber(cfg.feedBatchFood) or 3e9
end
R.feedThreshold = feedThreshold

-- 预览清单数据（含 1 秒缓存：界面 5Hz 刷新，而这里要读 40 个台子）
local function feedPreviewListRaw()
    local cands = feedCandidates()
    local food = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0
    local keep = R.feedKeepFactor()
    local rate, gardens = R.feedFoodRate()
    local plan, spent, gain, actions = feedPlan(math.max(food, 0))
    return { cands = cands, food = food, keep = keep, rate = rate, rateAttr = gardens,
             plan = plan, planSpent = spent, planGain = gain, planActions = actions,
             totalCps = feedTotalCps(), threshold = feedThreshold(),
             -- 💞 配对加成（v271）：命中的台子数 + 倍率
             pairCount = R.feed and R.feed._pairCount or 0,
             pairMult = tonumber(cfg.astPairMult) or 3 }
end
feedPreviewList = function(force)
    -- ⚠ 参数加固：UI 与状态刷新会用各种方式调用它（含 pcall 包装、旧版本残留的零参调用），
    --   所以 force 必须容忍 nil。
    --   ❌ 曾经的写法 `force = (force == true)` 是个**断言**而不是赋值转换：
    --      它在 force 为 nil 时会直接抛 "missing argument #1"，
    --      导致 UI 构建失败 -> renderStatus 中断 -> 去突变状态错乱
    --      （实测后果：脚本反复把同一个角色往正在运转的机器里塞）。
    --   ✅ 正确写法：普通局部变量转换，任何输入都不报错。
    local wantForce = (force == true)
    R.feed = R.feed or {}
    local now = os.clock()      -- ⚠ 绝不能用 tick()：会调到本脚本自己的主循环造成无限递归
    -- ★ v160：缓存窗口 1 秒 -> 2 秒。这个函数要遍历 40 个台子 + 每个读一遍
    --   GetAttributes()/FindFirstChild/ActionText，而界面刷新线程是 5Hz、
    --   还有 renderFeedList(3 秒) 和总经理一起调它 —— 实测等于每秒重扫一两次 40 个台子。
    --   喂食计划不是毫秒级敏感的信息，2 秒缓存对观感毫无影响，却把无谓扫描砍掉一半。
    --   （需要立刻反映状态的地方都显式传 true，例如执行完一批、点预览按钮。）
    local at = tonumber(R.feed._pvAt) or -1e9
    if not wantForce and type(R.feed._pv) == "table" and (now - at) < 2
        and type(R.feed._pv.plan) == "table" then
        return R.feed._pv
    end
    local pv = feedPreviewListRaw()
    R.feed._pv = pv
    R.feed._pvAt = now
    return pv
end

-- 主循环里的喂食维护（对外的 feedTick 是文件顶部的前向转发壳）
-- ⚠ 真实实现：直接赋给顶部的 `local feedTick`（照抄脚本原有 local washTick 模式）
feedTick = function()
    R.feed = R.feed or { actions = 0, spent = 0, gain = 0, batches = 0 }
    local F = R.feed
    local now = os.clock()      -- ⚠ 绝不能写 tick()：会调到本脚本自己的主循环 -> 无限递归（坑 ①-b）
    -- ★ 速率统一：不再自己测，交给全脚本唯一的 R.foodRateSample()（见其定义处的长注释）
    R.foodRateSample()
    -- ⚠⚠ v163 修：这里必须**自己读一次食物**！
    --   v160 把原来的"速率测量块"（那个块里顺带读了 food）换成 foodRateSample() 时，
    --   把 feedTick 作用域里的 `food` 一起删掉了 —— 而下面 smart 分支的
    --   `food >= c.cost`（没有 or 0 保护）会直接抛 "attempt to compare nil with number"，
    --   于是 pcall(feedTick) 每轮失败 -> **自动喂食彻底停摆**（用户实测：到 10B 不喂）。
    --   这是纯粹的遗漏，教训：删掉一段代码前，先查它定义的变量在别处还有没有引用。
    local food = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0
    -- ★★★ 食物预留：扣掉"自动配置角色"还需要的那部分 ★★★
    --   用户点出的死锁（原话）："在等食物期间自动喂食自己又工作在10B就把食物喂了，
    --   一直攒不到"
    --   机制：换人需要**一次性拿出一大笔**（比如一台 5B），
    --         而喂食每次只花一点点、但很频繁 —— 食物永远攒不到换人所需。
    --   ⇒ `R.feedBudgetCap()` 返回"超出预留的那部分"，喂食只能动这部分。
    --     达到阈值但可支配食物不足时，就继续等（并给出提示），绝不吃掉预留。
    local spendableFood = food
    if type(R.feedBudgetCap) == "function" then
        local okCap, cap = pcall(R.feedBudgetCap)
        if okCap and type(cap) == "number" then spendableFood = cap end
    end
    local reserved = math.max(0, (food or 0) - (spendableFood or 0))
    if not cfg.feedEnabled then return end
    -- ★★★ 让路给"自动配置角色"（用户实测报告："自动喂食在跟自动换人抢"）★★★
    --
    -- 两个层面的争抢，都要挡：
    --   ① **食物**：换人需要一次性拿出一大笔，喂食一点点吃掉就永远攒不够
    --      -> 由 `R.feedBudgetCap()` 的数字预留解决（上面已算）。
    --   ② **执行锁 / 台子**：两者都要传送到台子旁操作 prompt，同时跑会互相打断。
    --      -> 只要自动配置正在执行（`_astRunning`）或抢到了 busy 锁，喂食这一轮就整段让路。
    --   另外：自动配置开启时，如果它已经算出"还需要 X 食物"，喂食必须严格等
    --   可支配食物达到阈值才动手（下面 auto 分支已有该检查）。
    if R._astRunning then return end
    if cfg.astEnabled == true then
        local bw = R.busyWho and R.busyWho()
        if bw == "配置角色" then return end
    end
    if F.running then return end
    -- 活动期间是否让路（可配置；默认【不让路】）
    -- ⚠ 实测背景（用户反馈"到 10B 又不喂了"）：旧版**无条件**在活动期间暂停喂食，
    --   理由是"活动期间不碰角色"。但审视后确认喂食只做【传送到台子 + 触发升级 prompt】：
    --     · 不手持角色（不参与万圣节/Solar 的持有逻辑）
    --     · 不改突变（没有"被二次突变"的风险）
    --     · 有 busySuggest 互斥，不会和去突变/钓鱼抢位置
    --   所以对喂食并无必要避让，代价却是食物一直堆着不花
    --   （实测：SlimeRain 期间食物涨到 12.68B 仍未喂）。
    --   想恢复旧行为就把 feedPauseOnEvent 设为 true。
    if cfg.feedPauseOnEvent == true and R.event.active and R.event.name and eventRemaining() > 0 then
        if not F._pauseLogged then
            F._pauseLogged = true
            log("⏸ 自动喂食暂停：活动（" .. tostring(R.event.name) .. "）期间让路", Color3.fromRGB(255, 200, 90))
        end
        return
    end
    F._pauseLogged = nil
    local mode = tostring(cfg.feedMode or "auto")
    if mode == "manual" then return end
    local cooldown = tonumber(cfg.feedCooldown) or 20
    if (now - (tonumber(F.lastRunAt) or 0)) < cooldown then return end
    local threshold = feedThreshold()
    if mode == "auto" then
        if (food or 0) < threshold then
            F.waiting = true
            F._sitSince = nil          -- 没到阈值，重置"停留"计时
            return
        end
        F.waiting = false
        -- ★★ 食物预留检查：达到阈值，但"可支配"的部分不够 -> 继续等，绝不吃掉预留 ★★
        --   预留是留给"自动配置角色"换人用的（换人需要一次性拿出一大笔）。
        --   用户明确要求："现在先换，攒食物之后再说" —— 所以换人优先于喂食。
        if reserved > 0 and spendableFood < threshold then
            if not F._reserveLogged then
                F._reserveLogged = true
                log(string.format("🍖 喂食让路：食物 %s 里有 %s 是留给「换人」的（可支配 %s < 阈值 %s）",
                    fmtShort(food or 0), fmtShort(reserved), fmtShort(spendableFood or 0),
                    fmtShort(threshold)), Color3.fromRGB(160, 200, 255))
            end
            F.waiting = true
            return
        end
        F._reserveLogged = nil
        -- ★ 停留时间规则（替代原来"让阈值跟着速率涨"的做法）
        --   食物一旦达到阈值就开始计时；如果因为任何原因（活动/让路/去突变占用/冷却）
        --   久久没被喂掉，超过 feedSitMinutes 就把它标记出来 —— 现在到点即喂，
        --   所以这条主要用于【诊断】：日志会明确告诉你"食物已经在阈值上放了 N 分钟"。
        local sit = tonumber(cfg.feedSitMinutes) or 0
        if sit > 0 then
            F._sitSince = F._sitSince or now
            local waited = (now - F._sitSince) / 60
            if waited >= sit and not F._sitLogged then
                F._sitLogged = true
                log(string.format("🍖 食物已达阈值但放了 %.0f 分钟没喂（阈值 %s · 当前 %s）—— 检查是否有活动/让路在阻挡",
                    waited, fmtShort(threshold), fmtShort(food or 0)), Color3.fromRGB(255, 200, 90))
            end
        end
    else
        -- smart：随时喂最优的一口（至少要有一台付得起且达标）
        local cands = feedCandidates()
        if #cands == 0 then return end
        local minEff = tonumber(cfg.feedMinEfficiency) or 0
        local okAny = false
        for _, c in ipairs(cands) do
            if c.eff >= minEff and (food or 0) >= (c.cost or math.huge) then okAny = true break end
        end
        if not okAny then return end
    end
    feedCalibrate(false)
    if cfg.feedDryRun then
        local plan, spent, gain, actions = feedPlan(food or threshold)
        F.lastSummary = string.format("[预览模式] %d 个台子 · %d 级 · 需 %s · 全屋 +%s",
            #plan, actions, fmtShort(spent), fmtShort(gain))
        F.lastDryAt = now
        F.dryPlan = plan
        log("🧪 喂食预览模式：本可喂 " .. #plan .. " 个台子 / " .. actions .. " 级 · 花费 " ..
            fmtShort(spent) .. " · 全屋 CPS +" .. fmtShort(gain), Color3.fromRGB(200, 200, 140))
        if R.renderFeedList then pcall(R.renderFeedList) end
        return
    end
    -- 🚦 检查是否"去突变"正在用玩家位置 -> 让路（等它做完再喂）
    local busyWho = R.busyWho()
    if busyWho and busyWho ~= "喂食" then
        if not F._busyLogged then
            F._busyLogged = true
            log("⏸ 自动喂食让路：去突变正在使用角色位置，等它做完", Color3.fromRGB(255, 200, 90))
        end
        return
    end
    F._busyLogged = nil
    task.spawn(function() pcall(feedExecute, food or threshold) end)
end

--============================================================== 🎩 总经理（自动调参）
-- 设计思路（先讲清楚为什么这么做，避免以后误改）：
--
-- ① 实测结论：台子属性里的 `CPS` 是【不含任何加成的纯基础值】。
--    证据：用 Constants.Characters[名].CPS × GetCpsCurveMultiplier(等级) × 突变倍数
--          反推实际 CPS，34 个台子全部精确等于 1.000 倍 —— 说明连重生(114x)、现金升级(11x)、
--          VIP、药水、活动这些加成【都没有】进到属性里。
--    ⇒ 所以喂食的优先级判断天然不受加成波动影响：
--      我的"相对收益门槛"比的是"某台收益 ÷ 最高台收益"，全局倍率上下同时约掉。
--
-- ② 真正会被加成/药水/活动/花园影响的是【食物产出速率】。
--    实测：同一账号速率在 4.58M/秒 与 10.89M/秒 之间跳（+138%），猜测就是食物类加成。
--    食物速率一变，"攒多久才够喂一口"就变了 —— 这才是需要动态调的东西。
--
-- ③ 所以总经理**不去解析加成面板**（Boosts 里一堆 2x/倒计时，而且缺少重生/升级/VIP/研究
--    这些不在面板上的倍率，拼出来的总数既不准也不稳），
--    而是直接盯【食物盈余】这个可观测信号：
--        目标时间 = 攒到阈值食物需要多久（= 阈值 ÷ 食物速率）
--        比目标长  -> 食物不够花 -> 放宽门槛（让更多角色吃到，避免食物闲置）
--        比目标短  -> 食物在堆积 -> 收紧门槛（把资源集中到主力）
--    这样药水断供、活动倍率、换花园全都自动涵盖，也不会因为读错面板而调错。

-- 解析 Boosts 里某个加成当前的倍率（纯展示用，不参与决策）
local function boostMultiplier(name)
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    local b = mg and mg:FindFirstChild("Boosts")
    local node = b and b:FindFirstChild(name)
    if not node then return nil end
    local amt = node:FindFirstChild("Amount")
    if not amt then return nil end
    local t = ""
    pcall(function() t = amt.Text end)
    -- 形如 "2x" / "6.9x"；倒计时（00:00）则忽略
    local v = t:match("^([%d%.]+)x$")
    return v and tonumber(v) or nil
end

local function managerTick()
    R.mgr = R.mgr or { changes = 0 }
    local G = R.mgr
    if cfg.mgrAutoTune == false then return end
    -- ★ 速率统一（v160）：不再自己测 15 秒窗口，改用全脚本唯一的 R.foodRateSample()。
    --   旧实现自己做差分，和喂食模块的窗口不同 -> UI 上出现两个不同的"食物速率"
    --   （实测 5.27M/s vs 7.38M/s，差 1.4 倍），用户看到数字对不上。
    local now = os.clock()
    local rate = select(1, R.foodRateSample())
    if not rate or rate <= 0 then
        return      -- rate 为 0 时 etaMin 会变成 inf，干脆等下一次采样
    end
    G.rate = rate
    G.ticks = (G.ticks or 0) + 1

    local userTarget = math.max(1, tonumber(cfg.mgrTargetBufferMinutes) or 15)
    -- ★★ 边界解锁（v160）★★
    -- 实测死锁（用户报告"总经理是不是只调过 5%→3%"）：
    --   用户把攒批阈值【固定】在 10B，而食物只涨 5~8M/s -> 攒一批要 22~34 分钟，
    --   但目标时间是 14 分钟 -> errPct 长期 +60% 左右。
    --   总经理于是每 3 秒都判定"攒太慢 -> 放宽门槛"，可门槛已经被
    --   mgrMinRelGain(3%) 夹住 -> 永远返回 "已到边界（3.0%~25.0%），无法继续调"，
    --   changes 永远是 0 —— 它不是不想干，是**被自己够不着的目标卡死了**。
    -- ✅ 对策：卡在边界且误差仍很大时，不要一遍遍撞墙，而是把【目标时间】重设到
    --   当前食物速率真正能达到的水平（缓动 60%，夹在 1~180 分钟），然后继续正常控制。
    --   ⚠ 只动目标时间，绝不偷偷改用户的 feedMinRelGain（那会改变"喂哪些角色"）。
    local targetMin = math.max(1, tonumber(G.targetMin) or userTarget)
    local thr = feedThreshold()
    local etaMin = thr / rate / 60        -- 攒够一个阈值需要多少分钟
    G.etaMinutes = etaMin
    G.errPct = 100 * (etaMin - targetMin) / targetMin  -- 正 = 攒太慢，负 = 攒太快

    -- 死区：±25% 以内不动手，避免来回抖
    if math.abs(G.errPct) <= 25 then
        G.outCount = 0
        G.lastAction = "在死区内，不调"
        G.target = (tonumber(cfg.feedMinRelGain) or 0.08) * 100
        return
    end
    -- ★★ 迟滞（v173）：必须在死区外**连续若干轮**才动手 ★★
    -- 实测问题：食物速率因为药水/加成/花园换人在 8M/s ~ 20M/s 之间剧烈波动，
    --   而总经理只看**单次** errPct 就调门槛 -> 其实是在追噪声，
    --   一路把门槛推到 3% 下限（用户会看到 changes 涨、行为却很飘）。
    --   这与踩过的坑 C1「自适应参数只能是【不波动】的量」是同一个道理：
    --   单次读数不可信，先确认这是个**趋势**再动。
    --   ⚠ 迟滞只管"要不要动手"，"往哪个方向动"仍由当前 errPct 决定。
    G.outCount = (G.outCount or 0) + 1
    local needTicks = math.max(1, math.floor(tonumber(cfg.mgrHoldTicks) or 3))
    if G.outCount < needTicks then
        G.lastAction = string.format("误差 %+.0f%% 需连续 %d 轮确认（当前第 %d 轮），先观察",
            G.errPct, needTicks, G.outCount)
        return
    end
    -- ★★ 范围自愈（v172）★★
    -- 实测：用户把「相对收益门槛」滑块拖到上限 -> cfg.feedMinRelGain = 0.25，
    -- 而允许范围恰好是 mgrMinRelGain=0.03 ~ mgrMaxRelGain=0.25，
    -- 于是门槛**又顶死在边界**（这次是上限，之前是下限），总经理再次空转。
    -- 对策：以现存的范围为准，门槛一旦越界就把它拉回范围内（step 夹取），
    --   这样卡死状态会在下一个评估周期自动解除，而且会如实告诉用户发生了什么。
    local lo = (tonumber(cfg.mgrMinRelGain) or 0.02)
    local hi = (tonumber(cfg.mgrMaxRelGain) or 0.30)
    if hi < lo then hi = lo end        -- 防御：配置被写反时以 lo 为准，避免 clamp 报错
    local cur = math.clamp(tonumber(cfg.feedMinRelGain) or 0.08, lo, hi)
    local step = math.max(0.002, cur * 0.20)
    local want
    if G.errPct > 0 then
        -- 攒太慢（食物不够）-> 放宽门槛 -> 门槛值变小
        want = cur - step
    else
        -- 攒太快（食物堆积）-> 收紧门槛 -> 门槛值变大
        want = cur + step
    end
    -- 夹在允许范围内并吸附到 0.5% 的整数档，避免出现 7.37% 这种碎数字
    want = math.clamp(want, lo, hi)
    want = math.floor(want * 200 + 0.5) / 200
    local curRaw = tonumber(cfg.feedMinRelGain) or 0.08
    -- 两种"顶死"都要处理：
    --   ① curRaw 越界（滑块被拖出范围）    -> 必须真的写回纠正值
    --   ② curRaw 恰好等于上/下限、且想往那边继续走（已经被夹到没空间）-> 需要重设目标
    --   ⚠ 实测踩到的坑：只判①的话，"门槛=25%=上限、想收紧"这种恰好贴边的情况会被漏掉，
    --     而且因为 want 被夹回 25 与 cur 相等，还会被误判成"已到边界"直接 return，卡死无法解除。
    local outOfRange = (curRaw < lo - 1e-9) or (curRaw > hi + 1e-9)
    local stuckAtBound = (math.abs(curRaw - hi) < 0.002 and G.errPct < 0)
        or (math.abs(curRaw - lo) < 0.002 and G.errPct > 0)
    if (not outOfRange) and (stuckAtBound or math.abs(want - curRaw) < 0.002) then
        -- ★★ 卡在边界（v169 重写）★★
        -- 旧写法只在"目标还等于用户设定值"时重设一次，之后就永久放弃 ——
        -- 实测后果：目标被重设到 32 分钟后，真实速率上升使 eta 掉到 23 分钟，
        -- errPct 变成 -27%（刚好在死区外），它想收紧门槛却又被自己的目标挡住 =>
        -- 只能反复输出"维持现状"，又一次陷入空转。
        -- ✅ 现在允许**反复重设**，但带阻尼（只走 40%）+ 每次变化量上限（≤ 40%），
        --    所以不会来回猛摆，而是平滑地追着真实产率收敛。
        --    ⚠ 依然只动【目标时间】，绝不偷偷改用户的 feedMinRelGain。
        local nt = targetMin + (etaMin - targetMin) * 0.4
        nt = math.clamp(nt, 1, 180)
        nt = math.max(math.min(nt, targetMin * 1.4), targetMin * 0.6)   -- 单次最多变 40%
        nt = math.floor(nt * 2 + 0.5) / 2
        if math.abs(nt - targetMin) >= 0.5 then
            G.targetMin = nt
            G.reframes = (G.reframes or 0) + 1
            G.lastAction = string.format(
                "门槛已到 %s%% 边界，目标时间按实际产率重设为 %s 分钟（你设的是 %s）",
                tostring(rnd(cur * 100, 1)), tostring(rnd(nt, 1)), tostring(rnd(userTarget, 0)))
            log(string.format(
                "🎩 总经理：攒一批实际要 %.1f 分钟，门槛已顶到 %.1f%% 边界（允许 %s%% ~ %s%%）-> "
                    .. "把目标时间重设为 %.1f 分钟，按新目标继续调参",
                etaMin, cur * 100, tostring(rnd(lo * 100, 0)), tostring(rnd(hi * 100, 0)), nt),
                Color3.fromRGB(255, 200, 90))
        else
            G.lastAction = string.format("已到边界（%s%% ~ %s%%），目标时间 %s 分钟已基本吻合实际产率 %.1f 分钟",
                tostring(rnd(lo * 100, 0)), tostring(rnd(hi * 100, 0)),
                tostring(rnd(targetMin, 1)), etaMin)
        end
        return
    end
    -- ⚠⚠ 这行是**脚本自己调参**（不是用户改动），必须走静默通道：
    --   值照样写进 cfg、界面滑块照样同步，但**不触发自动保存**。
    --   若写成普通赋值 `cfg.feedMinRelGain = want`，就是"没改动却一直在自动保存"
    --   （用户实测报的现象，根因就在这一处：每轮调 20%，0.10 ↔ 0.095 来回漂）。
    if R.cfgSetQuiet then R.cfgSetQuiet("feedMinRelGain", want)
    else cfg.feedMinRelGain = want end
    if E.sFeedRelGain and E.sFeedRelGain.SetValue then
        pcall(function() E.sFeedRelGain:SetValue(rnd(want * 100, 1)) end)
    end
    G.changes = (G.changes or 0) + 1
    G.target = want * 100
    -- ★ v172：越界纠正要单独说清楚 —— 否则用户会以为脚本在乱改他的设置
    if outOfRange then
        G.corrections = (G.corrections or 0) + 1
        G.lastAction = string.format("门槛 %s%% 超出允许范围 -> 已拉回 %s%%",
            tostring(rnd(curRaw * 100, 1)), tostring(rnd(want * 100, 1)))
        log(string.format("🎩 总经理：相对收益门槛 %s%% 超出允许范围（%s%% ~ %s%%）—— 已拉回 %s%% 继续工作。"
                .. "（门槛可能是你在滑块上手动拖出去的）",
            tostring(rnd(curRaw * 100, 1)), tostring(rnd(lo * 100, 0)), tostring(rnd(hi * 100, 0)),
            tostring(rnd(want * 100, 1))), Color3.fromRGB(255, 200, 90))
        return
    end
    G.lastAction = string.format("%s门槛 %.1f%% → %.1f%%",
        want < cur and "放宽" or "收紧", cur * 100, want * 100)
    -- 只在日志里报告"方向变化"，避免刷屏（同一方向连续微调就静默）
    if G.lastDir ~= (want < cur and "loose" or "tight") then
        G.lastDir = want < cur and "loose" or "tight"
        G.lastReportAt = now
        log(string.format("🎩 总经理：食物攒到阈值约需 %.1f 分钟（当前目标 %.1f）-> %s，现门槛 %.1f%%",
            etaMin, targetMin, G.lastAction, want * 100), Color3.fromRGB(200, 200, 140))
    end
    -- ★ v160：这里以前是 feedPreviewList(true)，会在**每次总经理评估时强制重扫 40 个台子**。
    --   总经理本来就会按情况变化方向、连续调整，于是界面被反复强制重算 —— 属于无谓开销。
    --   改成不强制：统一速率已经由上面的 foodRateSample() 更新过一次，
    --   界面按自己的节奏刷新（R.renderFeedList 走 2 秒缓存的 feedPreviewList）就够了。
    if R.renderFeedList then pcall(R.renderFeedList) end
end
R.managerTick = managerTick

-- 展示用快照（加成倍率只做展示，不参与决策）
local function managerStatus()
    local G = R.mgr or {}
    local food = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0
    -- ★ 与决策同源：一样走统一的速率函数，UI 上再也不会出现两个不同的"食物速率"
    local rate = select(1, R.feedFoodRate()) or 0
    local thr = feedThreshold()
    local userTarget = math.max(1, tonumber(cfg.mgrTargetBufferMinutes) or 15)
    local effTarget = math.max(1, tonumber(G.targetMin) or userTarget)
    return {
        enabled = cfg.mgrAutoTune ~= false,
        rate = rate,
        food = food,
        threshold = thr,
        etaMinutes = rate > 0 and (thr / rate / 60) or nil,
        targetMinutes = effTarget,
        userTargetMinutes = userTarget,
        reframed = math.abs(effTarget - userTarget) >= 0.05,
        reframes = G.reframes or 0,
        measuredWindow = (R.feed and R.feed.measuredWindow) or nil,
        currentRelGain = (tonumber(cfg.feedMinRelGain) or 0.08) * 100,
        minRelGain = (tonumber(cfg.mgrMinRelGain) or 0.02) * 100,
        maxRelGain = (tonumber(cfg.mgrMaxRelGain) or 0.30) * 100,
        changes = G.changes or 0,
        lastAction = G.lastAction,
        -- ★ v169：errPct 必须**按当前速率和目标现算**，不能用 G.errPct（那是上一轮的缓存值）。
        --   实测踩到自相矛盾的显示：界面上写 errPct = -32.7%（显然在死区外），
        --   下面却跟一句"在死区内，不调" —— 因为速率在这两轮之间变了。
        --   现算之后，"误差"和"总经理的判断"永远是同一时刻的口径。
        errPct = (rate > 0 and thr) and (100 * (thr / rate / 60 - effTarget) / effTarget) or G.errPct,
        boostCash = boostMultiplier("2x Cash"),
        boostLuck = boostMultiplier("Total Luck"),
    }
end
R.managerStatus = managerStatus

--============================================================== Obsidian 加载
HW_K.LIB_FILES = {
    Library = { file = "obsidian_Library.lua", url = OBSIDIAN_REPO .. "Library.lua" },
    SaveManager = { file = "obsidian_SaveManager.lua", url = OBSIDIAN_REPO .. "addons/SaveManager.lua" },
    ThemeManager = { file = "obsidian_ThemeManager.lua", url = OBSIDIAN_REPO .. "addons/ThemeManager.lua" },
}

local function loadObsidianLib(key, force)
    local info = HW_K.LIB_FILES[key]
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
-- ⚠ `local E` 已提前到文件顶部声明（角色筛选工厂要用它，见那里的说明）。
--   这里只做重置，绝不能再写 local（会变成第二个 E，工厂看到的还是旧的那个）。
E = {}
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
        -- 万圣节品质不再有独立下拉：它由下方选择器的①号框（bindRarKey="rarities"）负责
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
        if E.tSolarTp then E.tSolarTp:SetValue(cfg.solarTeleport ~= false) end
        if E.tSolarReq then E.tSolarReq:SetValue(cfg.solarRequireCandidate ~= false) end
        if E.sSolarHold then E.sSolarHold:SetValue(tonumber(cfg.solarMaxHold) or 30) end
        if E.sSolarCommit then E.sSolarCommit:SetValue(tonumber(cfg.solarCommitSeconds) or 4.5) end
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
        -- 去突变品质不再有独立下拉：由选择器的①号框负责（bindRarKey="washRarities"）
        if E.tWashAuto then E.tWashAuto:SetValue(cfg.washAutoPreview ~= false) end
        if E.tAutoClose then E.tAutoClose:SetValue(cfg.autoCloseEnabled ~= false) end
        if E.tAutoCloseWelcome then E.tAutoCloseWelcome:SetValue(cfg.autoCloseWelcome ~= false) end
        if E.tAutoCloseDaily then E.tAutoCloseDaily:SetValue(cfg.autoCloseDaily ~= false) end
        if E.sAutoCloseDelay then E.sAutoCloseDelay:SetValue(tonumber(cfg.autoCloseDelay) or 1.5) end
        if E.tFeed then E.tFeed:SetValue(cfg.feedEnabled == true) end
        if E.dFeedMode then E.dFeedMode:SetValue(tostring(cfg.feedMode or "auto")) end
        if E.sFeedBatch then E.sFeedBatch:SetValue(rnd((tonumber(cfg.feedBatchFood) or 3e9) / 1e9, 1)) end
        if E.sFeedMins then E.sFeedMins:SetValue(tonumber(cfg.feedThresholdMaxMinutes) or 20) end
        if E.sFeedRelGain then E.sFeedRelGain:SetValue(rnd((tonumber(cfg.feedMinRelGain) or 0.05) * 100, 1)) end
        if E.tMgrAuto then E.tMgrAuto:SetValue(cfg.mgrAutoTune ~= false) end
        if E.sMgrTarget then E.sMgrTarget:SetValue(tonumber(cfg.mgrTargetBufferMinutes) or 12) end
        if E.sMgrCool then E.sMgrCool:SetValue(tonumber(cfg.mgrAdjustCooldown) or 10) end
        if E.sMgrMin then E.sMgrMin:SetValue(rnd((tonumber(cfg.mgrMinRelGain) or 0.02) * 100, 1)) end
        if E.sMgrMax then E.sMgrMax:SetValue(rnd((tonumber(cfg.mgrMaxRelGain) or 0.30) * 100, 1)) end
        if E.sFeedMinEff then E.sFeedMinEff:SetValue(rnd((tonumber(cfg.feedMinEfficiency) or 0.02) * 1000, 1)) end
        if E.sFeedMinCps then E.sFeedMinCps:SetValue(rnd((tonumber(cfg.feedMinCps) or 1e6) / 1e6, 0)) end
        if E.sFeedMaxActions then E.sFeedMaxActions:SetValue(tonumber(cfg.feedMaxActionsPerCycle) or 0) end
        if E.sFeedCooldown then E.sFeedCooldown:SetValue(tonumber(cfg.feedCooldown) or 20) end
        if E.iFeedExclude then E.iFeedExclude:SetValue(tostring(cfg.feedExcludeStands or "")) end
        if E.tFeedDry then E.tFeedDry:SetValue(cfg.feedDryRun == true) end
        if E.tFeedPair then E.tFeedPair:SetValue(cfg.feedPairBonus ~= false) end
        if E.tFeedNotify then E.tFeedNotify:SetValue(cfg.feedNotify ~= false) end
        if E.tFeedAutoPrev then E.tFeedAutoPrev:SetValue(cfg.feedAutoPreview ~= false) end
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
        --========================================================== 💞 角色勾选恢复
        -- ⚠⚠⚠ v287：这里曾经放过一段"把 cfg.charPick 推进下拉"的代码，
        --   结果**它自己成了元凶**（打点实测：`载入=4 apply=0`）。
        --   原因：本函数在 UI 刚构建、**背包还没扫描**时运行，那时 `st.charItems`
        --   还是空的，下拉的 Values 还是占位符 `{"(等待选择品质…)"}`。
        --   此时调用 `dChar:SetValue({角色名=true})` —— 库的 SetValues 发现
        --   "旧值不在新列表里" → 删值 + 触发 RunChanged → 我们的 OnChanged
        --   拿到**空表** → 把 cfg 里的勾选清空。等于自己把好数据抹了。
        --
        -- ✅ 正确做法：**恢复交给 pickRestore 保护 + cfRefreshUI 的幂等对齐**。
        --   对齐在背包/图鉴就绪后才跑，那时把 Value 设成角色名是有效的。
        --   ⇒ 这里**绝对不要**碰 dChar（碰了就是在数据未就绪时触发清空）。
    end)
end

local function readUIIntoCfg()
    if not uiBuilt then return end
    -- ⚠⚠ v325 哨兵①：把"控件值回写进 cfg"变成**可见的**
    --   为什么必须加（2026-10-11 实测事故）：这是全脚本**唯一**会"无日志改 cfg"的地方 ——
    --     `__newindex` 对已存在的键不触发（见上方说明），而签名差分只负责**写盘**、
    --     不记录是谁改的。实测：04:43:06 前后 cfg.solarEnabled 被从 false 改成 true
    --     并落盘，而同一时刻日志里**一条记录都没有**，完全无法归因。
    --   ⇒ 现在：任何一次回写只要有值真变了，就打一行 `UI→cfg 回写`（旧值 -> 新值）。
    --   ⚠ 只加日志，不改任何赋值行为。
    local snap = {}
    do
        for k, v in pairs(cfg) do
            local t = type(v)
            if t == "boolean" or t == "number" or t == "string" then snap[k] = v end
        end
    end
    pcall(function()
        cfg.enabled = E.tEnabled.Value == true
        -- cfg.rarities 由选择器的①号框负责（见 cfBuildPicker 的 bindRarKey 回调），这里不再读
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
        -- cfg.solarRarities 由选择器①号框负责（bindRarKey="solarRarities"），这里不再读
        if E.tSolarTp then cfg.solarTeleport = E.tSolarTp.Value == true end
        if E.tSolarReq then cfg.solarRequireCandidate = E.tSolarReq.Value == true end
        if E.sSolarHold then cfg.solarMaxHold = tonumber(E.sSolarHold.Value) or 30 end
        if E.sSolarCommit then cfg.solarCommitSeconds = tonumber(E.sSolarCommit.Value) or 4.5 end
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
        -- cfg.washRarities 由选择器的①号框负责（bindRarKey="washRarities"），这里不再读
        if E.tWashAuto then cfg.washAutoPreview = E.tWashAuto.Value == true end
        if E.tAutoClose then cfg.autoCloseEnabled = E.tAutoClose.Value == true end
        if E.tAutoCloseWelcome then cfg.autoCloseWelcome = E.tAutoCloseWelcome.Value == true end
        if E.tAutoCloseDaily then cfg.autoCloseDaily = E.tAutoCloseDaily.Value == true end
        if E.sAutoCloseDelay then cfg.autoCloseDelay = tonumber(E.sAutoCloseDelay.Value) or 1.5 end
        if E.tFeed then cfg.feedEnabled = E.tFeed.Value == true end
        if E.dFeedMode then cfg.feedMode = tostring(E.dFeedMode.Value or "auto") end
        if E.sFeedBatch then cfg.feedBatchFood = (tonumber(E.sFeedBatch.Value) or 3) * 1e9 end
        if E.sFeedMins then cfg.feedThresholdMaxMinutes = tonumber(E.sFeedMins.Value) or 20 end
        if E.sFeedRelGain then cfg.feedMinRelGain = (tonumber(E.sFeedRelGain.Value) or 5) / 100 end
        if E.tMgrAuto then cfg.mgrAutoTune = E.tMgrAuto.Value == true end
        if E.sMgrTarget then cfg.mgrTargetBufferMinutes = tonumber(E.sMgrTarget.Value) or 12 end
        if E.sMgrCool then cfg.mgrAdjustCooldown = tonumber(E.sMgrCool.Value) or 10 end
        if E.sMgrMin then cfg.mgrMinRelGain = (tonumber(E.sMgrMin.Value) or 2) / 100 end
        if E.sMgrMax then cfg.mgrMaxRelGain = (tonumber(E.sMgrMax.Value) or 30) / 100 end
        if E.sFeedMinEff then cfg.feedMinEfficiency = (tonumber(E.sFeedMinEff.Value) or 20) / 1000 end
        if E.sFeedMinCps then cfg.feedMinCps = (tonumber(E.sFeedMinCps.Value) or 1) * 1e6 end
        if E.sFeedMaxActions then cfg.feedMaxActionsPerCycle = tonumber(E.sFeedMaxActions.Value) or 0 end
        if E.sFeedCooldown then cfg.feedCooldown = tonumber(E.sFeedCooldown.Value) or 20 end
        if E.iFeedExclude then cfg.feedExcludeStands = tostring(E.iFeedExclude.Value or "") end
        if E.tFeedDry then cfg.feedDryRun = E.tFeedDry.Value == true end
        if E.tFeedPair then cfg.feedPairBonus = E.tFeedPair.Value == true end
        if E.tFeedNotify then cfg.feedNotify = E.tFeedNotify.Value == true end
        if E.tFeedAutoPrev then cfg.feedAutoPreview = E.tFeedAutoPrev.Value == true end
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
    -- ⚠ v325 哨兵①（收尾）：列出这次回写**真正改掉**的键
    --   这一行的存在意义：下次配置又被"自己"改掉时，日志里会明确写
    --   `UI→cfg 回写 N 项：xxx false -> true`，配合它前面的库自动配置日志即可归因。
    local changed, total = {}, 0
    for k, v in pairs(snap) do
        local nv = cfg[k]
        if nv ~= v then
            total = total + 1
            local ks = tostring(k)
            if #changed < 6 and ks:sub(1, 5) ~= "uiWin" then
                changed[#changed + 1] = ks .. " " .. tostring(v) .. " -> " .. tostring(nv)
            end
        end
    end
    if total > 0 then
        if total > #changed then changed[#changed + 1] = "…等共 " .. tostring(total) .. " 项" end
        log("⚠ UI→cfg 回写 " .. tostring(total) .. " 项：" .. table.concat(changed, " · "),
            Color3.fromRGB(255, 170, 90))
    end
end

--============================================================== 只碰"我们自己的" UI
-- ⚠ 惨痛教训：以前这里按 `c.Name == "Obsidian"` 删除 ScreenGui，
--   结果把别人的 hub（例如 Ouroboros 也是 Obsidian 写的）的界面一起删了，
--   用户以为自己的挂机脚本"被顶掉了"。
--   现在改成：创建时给自己的 ScreenGui 打一个专属属性标记，清理时只删带标记的。
local UI_MARK = "HW_MutatorOwned"

--============================================================== 🖼 窗口尺寸记忆
-- 用户要求：「我想让自动保存跟config记住我的UI大小（我现在已拉大）」
-- 实现：主循环里每秒比一次窗口尺寸，变了就写进 cfg.uiWin -> 交给既有的
--   签名差分自动保存（见文件上方"配置自动保存"）落盘；重载时从 cfg 恢复。
-- ⚠ 只在尺寸真的变了才写 cfg，否则每秒都会改动配置（自动保存会一直刷盘）。
--
--   · 尺寸/位置超出视口 -> 钳制，保证窗口**总是可见可拖**（换分辨率也不会跑丢）
R.uiClampWin = function(w, h, x, y)
    local vp
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then vp = cam.ViewportSize end
    end)
    local vx = (vp and vp.X) or 1920
    local vy = (vp and vp.Y) or 1080
    -- 尺寸：至少 320x240，最多刚好铺满视口
    w = math.max(320, math.min(tonumber(w) or 720, vx - 8))
    h = math.max(240, math.min(tonumber(h) or 600, vy - 8))
    -- 位置：缺省 = 居中
    local dx = math.floor((vx - w) / 2)
    local dy = math.floor((vy - h) / 2)
    x = tonumber(x) or dx
    y = tonumber(y) or dy
    -- 左边：至少露出 80px（不许整块跑到右边外面）
    x = math.max(-(w - 80), math.min(x, vx - 80))
    -- 顶边：★ 允许为负（窗口比屏幕高时居中最合理，页面本身可滚动），
    --   但不许把标题栏推得太远 -> 下限 -(h - 60)，
    --   即"至少还能看到标题栏那 60px"，保证永远拖得回来。
    y = math.max(-(h - 60), math.min(y, vy - 60))
    return w, h, x, y
end

R.uiTrackSize = function()
    local W = R.window
    local f = W and W.MainFrame
    if not f then return end
    local ok, sz = pcall(function() return f.AbsoluteSize end)
    if not ok or not sz then return end
    local w, h = math.floor(sz.X), math.floor(sz.Y)
    if w < 200 or h < 200 then return end          -- 折叠/异常状态不记
    local ok2, pos = pcall(function() return f.AbsolutePosition end)
    if not ok2 or not pos then return end
    local x, y = math.floor(pos.X), math.floor(pos.Y)
    local cur = cfg.uiWin
    local cw = type(cur) == "table" and tonumber(cur.w) or nil
    local ch = type(cur) == "table" and tonumber(cur.h) or nil
    local cx = type(cur) == "table" and tonumber(cur.x) or nil
    local cy = type(cur) == "table" and tonumber(cur.y) or nil
    -- ★ 尺寸**和位置**都要比：只比尺寸的话，光拖动窗口（不改大小）就不会被记住。
    --   容差 2px：库在拖拽/缩放过程中会把坐标取整，差 1px 不值得写盘。
    if cw == w and ch == h
        and cx ~= nil and math.abs(cx - x) <= 2
        and cy ~= nil and math.abs(cy - y) <= 2 then
        return
    end
    -- ★ 整体替换这张表（而不是改字段）：签名差分能稳定识别到变化
    cfg.uiWin = { w = w, h = h, x = x, y = y }
end

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

    -- 🖼 恢复上次的窗口尺寸/位置（用户要求：config 记住我拉的 UI 大小）
    --   没存过 -> 完全走库的默认值（720x600 居中），行为与以前一致。
    local winArgs = {
        Title = "🎃 HW Mutator",
        Footer = "v" .. VERSION .. " · 万圣节自动突变",
        NotifySide = "Right",
        Resizable = true,
        ShowCustomCursor = false,
        ToggleKeybind = Enum.KeyCode.RightShift,
    }
    do
        local uw = cfg.uiWin
        local w = type(uw) == "table" and tonumber(uw.w) or nil
        local h = type(uw) == "table" and tonumber(uw.h) or nil
        -- 合理性校验：太小/太大都不认（防止存档损坏导致窗口不可用）
        if w and h then
            local x = tonumber(uw.x)
            local y = tonumber(uw.y)
            -- 钳制到当前视口内：换分辨率/窗口大小的存档也不会让面板跑到屏幕外
            w, h, x, y = R.uiClampWin(w, h, x, y)
            winArgs.Size = UDim2.fromOffset(w, h)
            winArgs.Position = UDim2.fromOffset(x, y)
            winArgs.Center = false       -- 有存的坐标就不让它居中覆盖
        end
    end
    local Window = Library:CreateWindow(winArgs)
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
        Feed = Window:AddTab("喂食", "beef"),
        Solar = Window:AddTab("Solar", "flame"),
        Wash = Window:AddTab("去突变", "sparkles"),
        Log = Window:AddTab("记录", "scroll-text"),
        Config = Window:AddTab("配置", "settings"),
        Auto = Window:AddTab("自动购买", "shopping-cart"),   -- ★ v341：自动购买独立板块
    }


    --================ 主控 / 状态
    local st = Tabs.Main:AddLeftGroupbox("运行状态", "activity")
    E.lEvent = st:AddLabel("事件: 初始化…", true)
    E.lHeld = st:AddLabel("手持: 无", true)
    -- ⚡ v366：实时显示"防闪电硬放手"是否武装（Thunder/Slime/Blizzard 这类活动期间必须武装）
    E.lHardRel = st:AddLabel("防闪电硬放手: —", true)
    E.lStats = st:AddLabel("—", true)
    st:AddDivider()
    st:AddLabel("候选角色（优先级 高 → 低，最多显示 10）", true)
    E.lCands = st:AddLabel("—", true)

    --================ 主控 / 自动关弹窗
    do
        local ac = st
        ac:AddDivider()
        ac:AddLabel('🚪 自动关闭弹窗（重进游戏时的挡屏窗口）', true)
        E.tAutoClose = ac:AddToggle("autoCloseEnabled", {
            Text = "自动关掉弹窗 ★", Default = cfg.autoCloseEnabled ~= false,
            Tooltip = "重进游戏时会弹出挡屏幕的窗口，脚本自动帮你点右上角的 ✕ 关掉。\n"
                .. "目前支持：\n"
                .. "· 离线收益弹窗（“欢迎回来~ 你离线赚了 $X，想翻三倍吗？”）\n"
                .. "· 每日签到弹窗\n"
                .. "⚠ 安全保证：只点名字精确等于 Close 的按钮，"
                .. "翻三倍（Yes）、Robux 跳过、FUTURE 这类按钮一概不碰。\n"
                .. "⚠ 也绝不用“直接隐藏界面”的偷懒做法 —— 那种做法会跳过服务器结算，"
                .. "导致离线收益不到账、界面卡住、教程不推进。脚本走的是游戏自己的关闭逻辑。",
        })
        E.lAutoClose = ac:AddLabel("状态: —", true)
        ac:AddDivider()
        E.tAutoCloseWelcome = ac:AddToggle("autoCloseWelcome", {
            Text = "离线收益弹窗", Default = cfg.autoCloseWelcome ~= false,
            Tooltip = "就是那个“欢迎回来~ / 当你离线时赚取了 $X / 你想将你的现金翻三倍吗？”的窗口。\n"
                .. "翻三倍那步是要花钱的，脚本只关窗、不翻倍（你的离线收益会照常到账）。",
        })
        E.tAutoCloseDaily = ac:AddToggle("autoCloseDaily", {
            Text = "每日签到弹窗", Default = cfg.autoCloseDaily ~= false,
            Tooltip = "每日奖励/连续签到窗口。里面除了 Close 还有 Robux（付费跳过）和 FUTURE 按钮，"
                .. "脚本只点 Close。",
        })
        E.sAutoCloseDelay = ac:AddSlider("autoCloseDelay", {
            Text = "出现后等多久再关", Default = tonumber(cfg.autoCloseDelay) or 1.5,
            Min = 0, Max = 10, Rounding = 1, Suffix = " 秒",
            Tooltip = "弹窗出现后先等这么久再点关闭。\n"
                .. "留一点时间给游戏完成初始化（它关窗时会顺带恢复被隐藏的界面、结算离线收益），"
                .. "太急可能在游戏还没准备好时点了没用。",
        })
        ac:AddButton({
            Text = "🚪 立刻关一次弹窗", Icon = "x-circle",
            Func = function()
                R.autoCloseNow()
                if R.renderStatus then pcall(R.renderStatus) end
            end,
            Tooltip = "不等延迟，马上检查并关掉当前可见的弹窗。\n"
                .. "用途：偶尔有些弹窗在别的地方出现，你想立刻清掉时点它。",
        })
    end

    --================ 主控 / 设置
    local se = Tabs.Main:AddRightGroupbox("突变设置", "sliders-horizontal")
    E.tEnabled = se:AddToggle("enabled", {
        Text = "启用自动手持", Default = cfg.enabled == true,
        Tooltip = "仅在万圣节(Halloween)事件期间手持；其他事件一律放手，避免烧掉角色",
    })
    -- ⚠ 这里原本还有一个独立的「目标品质」下拉（与下面的选择器重复、且能选不同值）。
    --   已删除：品质只保留下面的那一个（它绑定 cfg.rarities）。
    E.dTargets = se:AddDropdown("targets", {
        Text = "认可的突变", Values = { "Dracula", "Demonic" },
        Multi = true, Default = cfg.targets,
    })
    -- 🎯 v238：哪个品质的哪些角色去赌德古拉（不勾 = 该品质全部参与）
    se:AddDivider()
    R.charFilter.buildPicker(se, {
        mode = "halloween",
        title = "🎯 哪些角色去赌万圣节（德古拉）",
        tip = "这里勾上的角色专门等德古拉；想让它们去 Solar 就别勾这、改去 Solar 页签勾。",
        rarText = "① 万圣节参与品质 ★",
        bindRarKey = "rarities",          -- ★ 它的品质选择就是 cfg.rarities（唯一一份）
        rarDefault = cfg.rarities,
        rarTip = "只有这些品质的角色会在万圣节期间被手持。这个框就是万圣节的品质名单（唯一一份）。",
        charTip = "只列【白板】角色（已突变过的没法二次突变，不列）。"
            .. "该品质一个都不勾 = 这个品质的角色全部参与；勾了任意一个 = 只参与勾上的。\n"
            .. "每条格式：[品质] 角色名 $初始CPS 状态\n"
            .. "状态含义：×N = 背包里有 N 个白板 / ❌没有 = 背包里没有（先勾上，以后抽到自动生效）"
            .. " / ✗已全突变 = 全部突变完了，不能再赌 / 🚫已给XXX = 已被别的功能选走，不能同时勾选\n"
            .. "标签较长，把窗口拉宽一些就能完整看到（下面的预览行也是全宽的）。\n"
            .. "⚠ 受UI库限制，单独点掉最后一个勾选会被拦 —— 想清空请用下面的「🧹 清空勾选」按钮。",
        initText = "预览: 等待扫描背包…",
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
        -- ⚠ 默认 false（用户明确要求关掉）。打开会**闪烁**，原因见 cfg 里的详细说明：
        --   游戏自己的跟随/装备系统会不断重画原生选中框，脚本只能追着它跑 -> 打架。
        Text = "手持时显示蓝框（会闪烁，默认关）", Default = cfg.nativeSelectionFrame == true,
        Tooltip = "给当前手持角色的快捷栏槽位画一个蓝框。\n\n"
            .. "⚠ 默认关闭：游戏的跟随/装备系统会不断重画它自己的原生选中框，\n"
            .. "脚本只能追着它重刷 -> 两边打架 -> 蓝框闪烁（实测 3.6 秒变化 7 次）。\n\n"
            .. "⭐ 这个框和突变**完全无关**：服务器判定突变只看\n"
            .. "workspace.ToolFollowers 里有没有那个角色的 ToolFollower（真持有）。\n"
            .. "所以关掉它不影响任何功能，只是物品栏少一个视觉标记。\n\n"
            .. "⚠⚠ 2026-10-11 新增实测结论：打开它还会**破坏持有** ——\n"
            .. "渲染循环会每秒重刷一次游戏客户端的「选中」状态（见代码里 clientSetSelected），\n"
            .. "表现为角色每一两秒消失又重新出现、持有无法连续保持到活动结束。\n"
            .. "（正因为这个，它曾被库的自动配置反复推回 true，导致老 bug 复发；v331 已停用库覆盖。）",
    })
    -- ⚠⚠ v332 启动自检：蓝框开着必须**显式告警**。
    --   实测教训（2026-10-11）：这个开关以前一行日志都不打 ⇒ 它被静默改成 true 后，
    --   排查"角色每 3 秒消失又出现"时完全无法归因（日志里一条记录都没有）。
    --   ⇒ 只要它是 true，启动就在日志里红字警告一次。
    if cfg.nativeSelectionFrame == true then
        task.defer(function()
            log("⚠⚠ 手持蓝框开着（nativeSelectionFrame = true）：实测它会每秒重刷游戏选中状态，"
                .. "导致持有反复丢失（角色每一两秒消失又重新出现）。强烈建议去「界面」页关掉它 —— "
                .. "蓝框与突变无关，服务器只看 ToolFollowers。", Color3.fromRGB(255, 120, 120))
        end)
    end
    se:AddDivider()
    -- 🍬 万圣节糖果自动收集（v316）
    E.tCandy = se:AddToggle("candyEnabled", {
        Text = "🍬 自动收集万圣节糖果（不传送）", Default = cfg.candyEnabled == true,
        Tooltip = "自动收走地图上刷新的万圣节糖果（HalloweenCandy）。\n\n"
            .. "⭐ 原理：用执行器的 firetouchinterest 伪造一次「触碰」，\n"
            .. "由服务器判定收走 —— **角色完全不移动、不传送**。\n\n"
            .. "✅ 所以它不会影响钓鱼、Solar 陨石、喂食、去突变中的任何一个，\n"
            .. "   也不需要和它们抢「角色位置」这把锁。\n\n"
            .. "⚠ 与「自动收集现金」GamePass 无关（那个只管现金）。\n"
            .. "   如果日志出现「试了 N 颗都没收掉」，说明执行器不支持该函数。",
    })
    E.tCandy:OnChanged(function(v)
        if R.candy then R.candy.enable(v == true) end
        cfg.candyEnabled = v == true
    end)
    E.bCandyNow = se:AddButton({ Text = "立刻收一次糖果", Icon = "candy", Func = function()
        if not R.candy then return end
        local n = R.candy.count()
        if n == 0 then log("🍬 地图上暂时没有糖果") return end
        cfg.candyEnabled = true
        if E.tCandy then pcall(function() E.tCandy:SetValue(true) end) end
        log(string.format("🍬 手动收糖：地图上有 %d 颗", n))
        R.candy.tick()
    end })
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
    -- ⚠ v336：原来这里有个「保存配置到文件」（写我们自己的 JSON）—— 已随配置系统切换移除。
    --   现在保存走「配置」页的 Configuration 面板（Overwrite config）；迁移按钮也在那一页。

    --================ 配置保存（v336：改用 UI 库自己的配置系统）
    -- 用户原话：「既然两个系统配置文件这么复杂，那自动保存配置就别弄了，去掉吧，
    --           改用UI库自己的config系统，我自己保存设置」
    -- ⇒ 我们的 JSON 自动保存**已停用**；配置由库的 Configuration 面板管。
    do
        local as = Tabs.Config:AddLeftGroupbox("配置保存（改用 UI 库自己的面板）", "save")
        as:AddLabel("v336 起：配置由界面库自己的 Configuration 面板管理。", true)
        as:AddLabel("改完设置后，去那个面板点「Overwrite config」保存；下次启动自动恢复。", true)
        as:AddLabel("（原来的 JSON 自动保存已停用；hw_mutator_config.json 原样留在工作区当备份）", true)
        as:AddDivider()
        as:AddButton({ Text = "① 从旧 JSON 迁移一次（只做一次）", Icon = "file-input",
            Tooltip = "把旧配置文件 hw_mutator_config.json 里的设置读进内存并推到界面。\n"
                .. "用途：换到库的配置系统后，把你原来的设置一次性搬过来。\n"
                .. "⚠ 读进来之后**必须**去 Configuration 面板点 Overwrite config，否则库那边还是旧值。",
            Func = function()
                local ok = loadConfig()
                if ok then
                    applyCfgToUI(); readUIIntoCfg(); refreshCandidates()
                    log("📥 已从旧 JSON 迁入设置 ✓ —— 现在请去「配置」页的 Configuration 面板点 Overwrite config 保存",
                        Color3.fromRGB(120, 255, 140))
                else
                    log("迁移失败：旧配置文件不存在或损坏", Color3.fromRGB(255, 120, 120))
                end
            end })
        as:AddButton({ Text = "查看配置来源/状态", Icon = "info", Func = function()
            log("配置由库的 Configuration 面板管理（自动配置名见下）")
            log("旧 JSON（仅备份，不再自动读写）: " .. tostring(R.activeCfgFile()))
            log("账号绑定表（已停用）: " .. R.ACCT_FILE)
            local ok, d = pcall(readfile, "hw_mutator_config.json")
            log("旧 JSON " .. (ok and ("存在，长度 " .. tostring(#d)) or "不存在"))
        end })
    end


    --================ 🛒 自动购买板块（v341：独立页签 + 每商店一个分组）
    -- 用户需求：「新开一个板块，把功能弄进去，并且像我截图的那样把每个商店买的东西按商店分开，
    --           每个商店都弄一个自己的开关跟选择商品面板」
    do
        local at = Tabs.Auto
        -- ---- 总控 ----
        local g0 = at:AddLeftGroupbox("总控", "sliders-horizontal")
        E.tAutoMaster = g0:AddToggle("autoBuyEnabled", {
            Text = "启用自动购买（总开关）★", Default = cfg.autoBuyEnabled == true,
            Tooltip = "总开关。关了它，下面每个商店的开关都不生效。\n"
                .. "只点游戏自己的购买按钮（和「点 AutoFish」同一套做法），不伪造远程包。",
        })
        E.tAutoDry = g0:AddToggle("autoBuyDryRun", {
            Text = "只预演不真买（建议先开着）", Default = cfg.autoBuyDryRun ~= false,
            Tooltip = "开着时只在日志写「会买哪一个 / 为什么跳过」，一次都不点。确认清单没问题再关。",
        })
        E.sAutoMax = g0:AddSlider("autoBuyMaxPerItem", {
            Text = "单件价格上限（0 = 不限）", Default = tonumber(cfg.autoBuyMaxPerItem) or 0,
            Min = 0, Max = 1e10, Rounding = 0,
            Tooltip = "价格高于这个数的商品不买（防手滑买天价货）。0 = 不限制。",
        })
        E.sAutoHour = g0:AddSlider("autoBuyHourBudget", {
            Text = "每小时花费上限（0 = 不限）", Default = tonumber(cfg.autoBuyHourBudget) or 0,
            Min = 0, Max = 1e10, Rounding = 0,
            Tooltip = "一小时内累计花掉超过这个数就不再买。0 = 不限制。",
        })
        g0:AddDivider()
        g0:AddButton({ Text = "🔄 刷新全部商店商品", Icon = "refresh-cw",
            Tooltip = "重新扫描所有商店在售商品，更新每个商店下面的多选面板（商店轮换后点一下）",
            Func = function()
                R.autoDiscover(); R.auto.syncUI(true)
                local n = 0
                for _, k in pairs(R.auto.byStore or {}) do n = n + #k end
                log("🛒 已刷新：共 " .. tostring(n) .. " 个可买项，分布在 " ..
                    tostring((function() local c = 0 for _ in pairs(R.auto.byStore or {}) do c = c + 1 end return c end)()) .. " 个商店")
            end })
        g0:AddButton({ Text = "列出各商店商品与价格（写日志）", Icon = "list",
            Tooltip = "按商店分组，把每个商品的标题 / 价格 / 用现金还是宝石 全打到日志里核对",
            Func = function()
                R.auto.discover()
                for _, s in ipairs(R.auto.stores) do
                    local items = (R.auto.byStore or {})[s.key] or {}
                    log(string.format("🛒 【%s】在售 %d 项", s.name, #items))
                    for _, it in ipairs(items) do
                        log(string.format("      %s · 价 %s · 货币 %s%s", it.title,
                            tostring(it.price), tostring(it.cur),
                            it.stock and (" · 库存=" .. tostring(it.stock)) or ""))
                    end
                end
            end })
        E.lAuto2 = g0:AddLabel("自动购买: —", true)

        -- ---- 领取 / 转盘 / 重生 ----
        local g1 = at:AddRightGroupbox("领取 / 转盘 / 重生", "gift")
        E.tClaimQ = g1:AddToggle("autoClaimQuests", {
            Text = "自动领任务奖励", Default = cfg.autoClaimQuests ~= false,
            Tooltip = "任务面板里标着 CLAIM! 的奖励；优先点「ClaimAll」（一键全领）",
        })
        E.tClaimP = g1:AddToggle("autoClaimPlaytime", {
            Text = "自动领游戏时长奖励", Default = cfg.autoClaimPlaytime ~= false,
            Tooltip = "按游玩时长解锁的奖励（Reward1..N），只点带 CLAIM 字样的",
        })
        E.tClaimD = g1:AddToggle("autoClaimDaily", {
            Text = "自动领每日奖励", Default = cfg.autoClaimDaily ~= false,
            Tooltip = "每日签到奖励（ClaimBtn），只点带 CLAIM 字样的",
        })
        g1:AddDivider()
        E.tSpin2 = g1:AddToggle("autoSpin", {
            Text = "自动玩轮盘", Default = cfg.autoSpin ~= false,
            Tooltip = "优先点游戏自带的「AutoSpin」（点一次它就一直自动转）；没有才点单次 SpinButton。\n"
                .. "⚠ 若游戏要求你人在轮盘旁边，服务器可能拒绝 —— 看日志就知道有没有成功。",
        })
        E.tReb2 = g1:AddToggle("autoRebirth", {
            Text = "自动重生（⚠ 会重置进度，默认关）", Default = cfg.autoRebirth == true,
            Tooltip = "⚠⚠ 重生通常会把等级/现金清零换永久倍率。默认关闭，你自己确认过再开。\n"
                .. "开启后每 90 秒最多点一次「Rebirth」；Dry-Run 开着时只写日志。",
        })

        -- ---- 自动喝药水（v345）----
        local g2 = at:AddRightGroupbox("自动喝药水", "flask-conical")
        E.tDrink = g2:AddToggle("autoDrinkEnabled", {
            Text = "启用自动喝药水 ★", Default = cfg.autoDrinkEnabled == true,
            Tooltip = "实测机制：装备药水 -> `Tool:Activate()` -> 立刻换回原来的手持。\n"
                .. "所以**不用一直拿在手上**（视觉上几乎看不到被拿起），也不影响钓鱼/手持角色。\n"
                .. "🛡 活动期间、或脚本正在手持角色等突变时，**绝不喝**（会让路给主业）。",
        })
        E.tDrinkDry = g2:AddToggle("autoDrinkDryRun", {
            Text = "只预演不真喝（建议先开着）", Default = cfg.autoDrinkDryRun ~= false,
            Tooltip = "开着时只在日志写「会喝哪一瓶」，一瓶都不喝。",
        })
        R.dDrinkList = g2:AddDropdown("autoDrinkList", {
            Text = "要自动喝的药水（多选，不勾=不喝）", Values = {}, Multi = true,
            Tooltip = "清单来自**你背包里现在有的药水**（每 10 秒自动刷新）。\n"
                .. "已经在生效的同名增益会自动跳过，省着用。",
        })
        E.sDrinkGap = g2:AddSlider("autoDrinkInterval", {
            Text = "同一瓶最短间隔", Default = tonumber(cfg.autoDrinkInterval) or 30,
            Min = 5, Max = 900, Rounding = 0, Suffix = " 秒",
            Tooltip = "同一瓶药水两次之间至少隔这么久（防止刷太快）",
        })
        E.tDrinkRod = g2:AddToggle("autoDrinkKeepRod", {
            Text = "喝完把手持换回来", Default = cfg.autoDrinkKeepRod ~= false,
            Tooltip = "喝完立刻把原来的手持（一般是鱼竿）换回去，避免手空着影响钓鱼",
        })
        -- ===== ★ v374 保留清单：留几瓶不喝（给 admin abuse 这类活动留着）=====
        --   ⚠⚠ 这两个控件就是"保留清单"的**唯一真源**：库的配置系统保存控件值，
        --      点「Overwrite config」后它们会被存下来并在下次启动恢复。
        --      （v369 那版用"按钮写入纯 cfg 表"的做法**存不下来** —— 用户实测踩到。）
        g2:AddDivider()
        R.dKeepList = g2:AddDropdown("autoDrinkKeepList", {
            Text = "要保留的药水（多选；选中的才会保留）", Values = {}, Multi = true,
            Tooltip = "勾选你想留着的药水（清单来自背包 + 游戏常量表，每 10 秒刷新）\n"
                .. "配合下面的「每瓶保留数量」一起生效",
        })
        E.sKeepNum = g2:AddSlider("autoDrinkKeepNum", {
            Text = "每瓶保留数量", Default = 3, Min = 1, Max = 50, Rounding = 0, Suffix = " 瓶",
            Tooltip = "选中的药水至少留这么多瓶不喝；只有**超过**这个数量时才会自动喝掉多出来的\n"
                .. "例：留 5 瓶 Luck Potion Lvl. 3 —— 剩 5 瓶时一滴不喝；有第 6 瓶才喝那第 6 瓶",
        })
        E.lKeep = g2:AddLabel("保留清单: （空）", true)
        E.lDrink = g2:AddLabel("当前生效增益: —", true)
        g2:AddButton({ Text = "💊 立即喝一瓶（手动测试）", Icon = "flask-round",
            Tooltip = "立刻喝一瓶勾选清单里最靠前的药水（忽略预演开关，真的喝）—— 用来验证机制",
            Func = function()
                local list = cfg.autoDrinkList or {}
                local bp = LocalPlayer:FindFirstChild("Backpack")
                local pick, blocked
                for _, t in ipairs((bp and bp:GetChildren()) or {}) do
                    if t:IsA("Tool") and list[t.Name] then
                        -- ★ v370：手动测试也**尊重保留量** —— 优先挑"库存超过保留量"的那瓶，
                        --   全都被保留挡住时才提示（免得手滑把留着的那瓶喝掉）
                        local keepN = R.auto.keepCount(t.Name)
                        if keepN <= 0 or R.auto.potionCount(t.Name) > keepN then
                            pick = t
                            break
                        else
                            blocked = blocked or {}
                            blocked[#blocked + 1] = string.format("%s（%d 瓶 = 保留量）", t.Name,
                                R.auto.potionCount(t.Name))
                        end
                    end
                end
                if not pick then
                    if blocked and #blocked > 0 then
                        log("🧴 勾选的药水都在保留量内，不喝：" .. table.concat(blocked, "、")
                            .. "（想强行喝就先在「保留清单」里清掉它）", Color3.fromRGB(255, 180, 80))
                    else
                        log("💊 没有可喝的：先在上面多选里勾一瓶药水", Color3.fromRGB(255, 180, 80))
                    end
                    return
                end
                log("💊 手动喝：" .. pick.Name, Color3.fromRGB(170, 220, 255))
                local ok = R.auto.drink(pick)
                if R.auto.syncPotionUI then pcall(R.auto.syncPotionUI, true) end
                log(ok and ("💊 已喝 " .. pick.Name .. "（看上面「当前生效增益」有没有多一条）")
                       or ("💊 喝 " .. pick.Name .. " 失败"), ok and Color3.fromRGB(120, 255, 140)
                       or Color3.fromRGB(255, 120, 120))
            end })
        g2:AddButton({ Text = "查看全部药水映射（源码直读）", Icon = "list",
            Tooltip = "直接从 Constants.Potions.Definitions 读出来的完整映射：\n"
                .. "药水名 → 定义键 / 类型 / 倍率 / 时长。到期判定就是靠这张表 + PotionGetState 接口，"
                .. "不需要任何「学习」步骤。",
            Func = function()
                local defs = R.auto.potionDefs()
                local names = {}
                for n in pairs(defs) do names[#names + 1] = n end
                table.sort(names)
                log("💊 药水映射（源码直读，共 " .. tostring(#names) .. " 种）：")
                for _, n in ipairs(names) do
                    local d = defs[n]
                    log(string.format("   %s → key=%s | 类型=%s | 倍率=%s | 时长=%s", tostring(n),
                        tostring(d.key), tostring(d.type), tostring(d.mult),
                        d.dur and (tostring(d.dur) .. "s") or "—"))
                end
            end })
        g2:AddButton({ Text = "刷新药水定义缓存", Icon = "refresh-cw",
            Tooltip = "游戏更新/改了药水定义后点一下，重新从 Constants 读一遍",
            Func = function()
                R.auto._pdefs = nil
                local defs = R.auto.potionDefs()
                local n = 0
                for _ in pairs(defs) do n = n + 1 end
                log("💊 已重新读取药水定义，共 " .. tostring(n) .. " 种")
            end })
        g2:AddButton({ Text = "列出生效药水状态（写日志）", Icon = "list",
            Tooltip = "调用游戏自己的 PotionGetState 接口，把生效中的药水（键/类型/倍率/剩余秒）打到日志",
            Func = function()
                local st = R.auto.potionState()
                log("💊 PotionGetState 生效中 " .. tostring(st.n) .. " 条：")
                local ks = {}
                for k in pairs(st.byKey) do ks[#ks + 1] = k end
                table.sort(ks)
                for _, k in ipairs(ks) do
                    log(string.format("   %s 剩 %d 秒", tostring(k), math.floor(st.byKey[k])))
                end
                if st.n == 0 then log("   （当前没有药水增益生效）") end
            end })

        -- ---- 每个商店一个分组：自己的开关 + 自己的商品面板 ----
        R.autoUI = {}
        for i, s in ipairs(R.auto.stores) do
            local box = (i % 2 == 1) and at:AddLeftGroupbox(s.name, "store") or at:AddRightGroupbox(s.name, "store")
            local tg = box:AddToggle("autoStoreOn_" .. s.key, {
                Text = "自动买这个商店", Default = (cfg.autoStoreOn or {})[s.key] == true,
                Tooltip = "只买下面面板里勾选的商品，而且**只用游戏内货币**（现金/宝石）。\n"
                    .. "⚠ Robux / Studs / GIFT / OWNED 这些付费或无效按钮永远不会被点（代码级硬规则）。",
            })
            local dp = box:AddDropdown("autoStoreItems_" .. s.key, {
                Text = "要买的商品（多选，不勾=不买）", Values = {}, Multi = true,
                Tooltip = "清单来自这个商店**当前在售**的商品（游戏异步下发，加载后几秒才会出现）。\n"
                    .. "点总控里的「🔄 刷新全部商店商品」可立即重扫。",
            })
            box:AddLabel("商店容器: " .. s.gui, true)
            R.autoUI[s.key] = { toggle = tg, drop = dp }
            tg:OnChanged(function(v)
                local m = cfg.autoStoreOn or {}
                m[s.key] = (v == true)
                cfg.autoStoreOn = m
                log("🛒 " .. s.name .. " 自动购买 = " .. ((v == true) and "开" or "关"))
            end)
            dp:OnChanged(function(v)
                local m = cfg.autoStoreItems or {}
                m[s.key] = normMulti(v)
                cfg.autoStoreItems = m
            end)
        end

        task.defer(function()
            if not isCurrent() then return end
            pcall(R.autoDiscover)
            pcall(function() R.auto.syncUI(true) end)
            log("🛒 自动购买板块就绪：已扫描各商店在售商品（每个商店面板里可见）")
        end)

        -- ⚠⚠ v341 必须补的一环：**每个控件都要注册 OnChanged**，否则库恢复出来的值
        --   只是把控件画成那个样子，**不会进 cfg** ⇒ 开关看着是开的、脚本却不买（v340 的漏洞）。
        local function bind(w, key)
            if not w then return end
            pcall(function()
                w:OnChanged(function(v)
                    cfg[key] = v
                    if key == "autoBuyEnabled" then
                        log("🛒 自动购买总开关 = " .. ((v == true) and "开" or "关"))
                    elseif key == "autoRebirth" then
                        log("🛒 自动重生 = " .. ((v == true) and "开（⚠ 会重置进度）" or "关"))
                    end
                end)
            end)
        end
        bind(E.tAutoMaster, "autoBuyEnabled")
        bind(E.tAutoDry, "autoBuyDryRun")
        bind(E.sAutoMax, "autoBuyMaxPerItem")
        bind(E.sAutoHour, "autoBuyHourBudget")
        bind(E.tClaimQ, "autoClaimQuests")
        bind(E.tClaimP, "autoClaimPlaytime")
        bind(E.tClaimD, "autoClaimDaily")
        bind(E.tSpin2, "autoSpin")
        bind(E.tReb2, "autoRebirth")
        bind(E.tDrink, "autoDrinkEnabled")
        bind(E.tDrinkDry, "autoDrinkDryRun")
        bind(E.sDrinkGap, "autoDrinkInterval")
        -- ★ v374：保留清单的两个控件 —— 它们才是被库保存的真源
        bind(E.sKeepNum, "autoDrinkKeepNum")
        if R.dKeepList then
            pcall(function()
                R.dKeepList:OnChanged(function(v)
                    cfg.autoDrinkKeepList = normMulti(v)
                    if type(R.auto.syncPotionUI) == "function" then pcall(R.auto.syncPotionUI, true) end
                end)
            end)
        end
        bind(E.tDrinkRod, "autoDrinkKeepRod")
        if R.dDrinkList then
            pcall(function()
                R.dDrinkList:OnChanged(function(v)
                    cfg.autoDrinkList = normMulti(v)
                end)
            end)
        end
    end

    --================ 快捷栏
    local hb1 = Tabs.Hotbar:AddLeftGroupbox("快捷栏管理", "layout-grid")
    E.tPause = hb1:AddToggle("pauseHotbar", {
        Text = "⏸ 暂停接管（手动整理时打开）★", Default = cfg.pauseHotbar == true,
        Tooltip = "打开后脚本完全放手：不再改布局、不再推送界面、并恢复游戏默认的药水插入，让你自由手动整理快捷栏",
    })
    hb1:AddLabel('提示：只要你在游戏里点/右键快捷栏槽位，脚本会自动让路 '
        .. tostring(cfg.manualOverrideSeconds or 60) .. ' 秒，不跟你抢。', true)
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
    hb1:AddLabel('提示：实测服务器对快捷栏数量没有上限，'
        .. '增长来自游戏客户端自动插入新角色。药水会被本脚本自动收起。', true)
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
        -- ⚠ 这里原本还有一个独立的「参与品质 ★（必须选）」下拉（E.dWashRar）。
        --   它和下面选择器里的「① 去突变参与品质」是**两个能选不同值的框**，
        --   与 Solar / 万圣节两处同样的问题（用户逐个指出："去极化也为什么有两个选择品质"）。
        --   已删除：品质只保留下面的那一个（它 bindRarKey = cfg.washRarities，是唯一一份）。
        -- 🎯 v238：哪些角色允许被洗（口径与自动突变相反：这里专列【有突变】的）
        wg:AddDivider()
        R.charFilter.buildPicker(wg, {
            mode = "wash",
            title = "🎯 哪些角色允许被洗突变",
            tip = "这里专列【已经带突变】的角色 —— 不勾它们就等于保护它们不被洗掉。",
            rarText = "① 去突变参与品质 ★",
            bindRarKey = "washRarities",      -- ★ 它的品质选择就是 cfg.washRarities（唯一一份）
            rarDefault = cfg.washRarities,
            rarTip = "只有这些品质的角色会被放进洗突变机器。这个框就是去突变的品质名单（唯一一份）。",
            charTip = "只列【已经带突变】的角色（机器洗的就是它们）。"
                .. "该品质一个都不勾 = 这个品质全部参与；勾了任意一个 = 只参与勾上的。\n"
                .. "每条格式：[品质] 角色名 $CPS 状态（×N = 带 N 个突变 / ✗暂无突变 = 没得洗）\n"
                .. "想保住某个角色的突变，就把它取消勾选。\n"
                .. "⚠ 受UI库限制，单独点掉最后一个勾选会被拦 —— 想清空请用下面的「🧹 清空勾选」按钮。",
            initText = "预览: 等待扫描背包…",
        })
        -- 📋 板块级总预览（用户要求：去突变也要有一个"会洗哪些角色"的整齐清单）
        wg:AddDivider()
        E.lWashPick = wg:AddLabel("【总预览】等待扫描背包…", true)
        wg:AddDivider()
        wg:AddButton({ Text = "预览：会洗哪些角色", Icon = "search", Func = function()
            R._washPreviewShown = true
            R.renderWashList()
        end })
        wg:AddButton({ Text = "查看机器状态", Icon = "search", Func = function()
            local st, act = depoState()
            local tl = depoTimeLeft()
            local names = { idle = "空闲（可以放）", ready = "已手持可放", busy = "正在洗",
                            pickup = "有待取回角色", none = "没有这台机器", unknown = "未知" }
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
            task.wait(0.6)
            -- 第①步：放上去
            local prompt = depoPrompt()
            local en = false
            pcall(function() en = prompt and prompt.Enabled end)
            if not en then log("Place 提示未启用（角色可能没有突变）", Color3.fromRGB(255, 180, 80)) return end
            depoFire(prompt)
            log("已放入 " .. tostring(R.hold.name) .. "，等待上机器…", Color3.fromRGB(120, 255, 140))
            -- 第②步：按启动按钮（角色上机器后 prompt 会变成 Pick Up）
            task.spawn(function()
                local t0 = os.clock()
                while isCurrent() and (os.clock() - t0) < 8 do
                    local st2 = depoState()
                    local tl = depoTimeLeft()
                    if st2 == "busy" or (tl and tl ~= "" and tl ~= "?") then
                        log("🧼 已开始清洗！剩余 " .. tostring(tl), Color3.fromRGB(120, 255, 140))
                        return
                    end
                    if st2 == "pickup" then
                        depoFire(depoStartPrompt())
                        task.wait(1.5)
                    else
                        task.wait(0.4)
                    end
                end
                log("⚠ 没检测到开始清洗（检查机器状态）", Color3.fromRGB(255, 180, 80))
            end)
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
                E.lWashList:SetText('⚠ 还没有勾选条件\n' ..
                    '请先在「要洗掉的突变」和「参与品质」两个多选里勾选')
                return
            end
            if #list == 0 then
                E.lWashList:SetText('没有符合条件的角色\n' ..
                    '（当前背包里没有「选中的突变 + 选中的品质」的角色）')
                return
            end
            -- 📋 与主控/Solar 用同一套格式；额外保留"突变名"（洗突变最关心的就是它）
            --   ⚠ v300：列表按**初始 CPS** 排序，所以把初始值显示出来
            --     （否则用户看到 262.5M 排在 290M 前面会以为是乱的）。
            --     显示成：初始 $175.0M/s  ×倍率 → 背包值 $262.5M/s
            local lines, total = {}, 0
            local cap = math.min(#list, 30)
            for i = 1, cap do
                local c = list[i]
                total = total + c.cps
                local rc = HW_K.RARITY_COLORS[c.rarity] or Color3.fromRGB(220, 220, 220)
                lines[#lines + 1] = string.format(
                    '  %2d. %-21s <font color="rgb(150,150,170)">[%s]</font>  '
                    .. '<font color="rgb(255,180,90)">%s</font>  '
                    .. '<font color="rgb(140,230,150)">$%s/s</font>'
                    .. '<font color="rgb(150,150,170)"> (×%s → $%s/s)</font>',
                    i,
                    string.format('<font color="rgb(%d,%d,%d)">%s</font>',
                        math.floor(rc.R * 255), math.floor(rc.G * 255), math.floor(rc.B * 255), c.name),
                    c.rarity, c.ty, fmtCps(c.base or c.cps),
                    (function()
                        local m = tonumber(c.mult) or 1
                        return (m == math.floor(m)) and string.format("%d", m) or string.format("%.2f", m)
                    end)(),
                    fmtCps(c.cps))
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

    --================ 🍖 喂食（Auto Feed）
    do
        local fg = Tabs.Feed:AddLeftGroupbox("自动喂食（升级台上角色）", "beef")
        E.tFeed = fg:AddToggle("feedEnabled", {
            Text = "启用自动喂食 ★", Default = cfg.feedEnabled == true,
            Tooltip = "自动把食物喂给台上的角色来升级。\n"
                .. "· 角色【必须放在台子上】才有喂食按钮（手持角色不行，实测确认）\n"
                .. "· 脚本会自动传送到台子旁、按下面板上的 Level Up 提示，一次精确升 1 级\n"
                .. "· 只用单级升级：因为「吃光所有食物」的批量按钮无法控制分配，会浪费食物\n"
                .. "· 每喂一口都会复核「台上的角色还是不是它、等级还对得上、扣费成功」，任一不符立刻停批\n"
                .. "⚠ 食物会被真实消耗且不可撤销 —— 请先用「预览模式」看一遍计划再开启",
        })
        E.lFeed = fg:AddLabel("喂食: —", true)
        fg:AddDivider()
        E.dFeedMode = fg:AddDropdown("feedMode", {
            Text = "喂食节奏",
            Values = {
                auto = "攒够一批再喂（推荐，不打断钓鱼）",
                smart = "有食物就随时喂最优的一口",
                manual = "只在我点按钮时喂",
            },
            Default = tostring(cfg.feedMode or "auto"), Multi = false,
            Tooltip = "【攒够一批再喂】食物没到阈值时脚本完全不动手，钓鱼一点都不受影响；"
                .. "攒够了就一次性把整批最优分配做完，然后重新攒。\n"
                .. "【随时喂】食物够一口就喂一口，推进最快，但每隔一两分钟就会传送一次、会轻微打断钓鱼。\n"
                .. "【只手动】脚本不自动动手，只在你点「立即喂一批」时执行。",
        })
        E.sFeedBatch = fg:AddSlider("feedBatchFood", {
            Text = "攒批阈值（食物）", Default = (tonumber(cfg.feedBatchFood) or 3e9) / 1e9,
            Min = 0.5, Max = 100, Rounding = 1, Suffix = "B",
            Tooltip = "食物低于这个数就完全不动手（钓鱼不受任何影响）。\n"
                .. "攒够后一次性执行整批最优分配。\n"
                .. "参考：食物产出 19B/小时时，3B 约等于攒 10 分钟。\n"
                .. "调大 = 传送更少、每批更厚；调小 = 推进更连续。",
        })
        E.sFeedMins = fg:AddSlider("feedThresholdMaxMinutes", {
            Text = "自适应下限（按速率换算）", Default = tonumber(cfg.feedThresholdMaxMinutes) or 20,
            Min = 0, Max = 120, Rounding = 0, Suffix = " 分钟",
            Tooltip = "阈值会自动取【上面那个固定值】和【当前食物速率 × 这个分钟数】里的较大者。\n"
                .. "意义：等你以后食物产出变快（换更好的花园），脚本会自动把阈值抬高，"
                .. "不会出现「食物早就够了还一直不喂」或「刚喂完马上又喂」的情况。\n"
                .. "填 0 = 关闭自适应，只用上面的固定值。",
        })
        E.sFeedRelGain = fg:AddSlider("feedMinRelGain", {
            Text = "★ 相对收益门槛", Default = rnd((tonumber(cfg.feedMinRelGain) or 0.05) * 100, 1),
            Min = 0, Max = 50, Rounding = 1, Suffix = " %",
            Tooltip = "只喂【单级收益 ≥ 全屋最高单级收益 × 这个比例】的角色。"
                .. "这是提升总 CPS 最关键的参数。" .. " "
                .. "为什么需要它：低等级低 CPS 的角色，每 1 食物换回的 CPS 反而更高（性价比看着漂亮），"
                .. "但绝对收益只有主力角色的千分之一 —— 喂它等于把食物扔进黑洞。" .. " "
                .. "实测对照（固定 30B 食物）：门槛 5% -> 喂 37 级共 +10.46B；8% -> 30 级 +10.40B；"
                .. "12% -> 只喂 25 级 +10.18B。因为主力角色在所有方案里都喂满，"
                .. "调高门槛只会让食物闲置。所以默认取 5%（转化率最高档）。" .. " "
                .. "调小 = 喂更多角色（转化率高但有碎料）；调大 = 只喂主力（食物容易堆积）。" .. " "
                .. "🎩 开着总经理时它会自动微调这个值。",
        })
        E.sFeedMinEff = fg:AddSlider("feedMinEfficiency", {
            Text = "性价比下限", Default = rnd((tonumber(cfg.feedMinEfficiency) or 0.02) * 1000, 1),
            Min = 0, Max = 200, Rounding = 1, Suffix = " ‰",
            Tooltip = "性价比 = 这一级带来的 CPS 增益 ÷ 这一级花掉的食物。\n"
                .. "低于这个下限就【停止喂食】，防止把食物扔进不值得的等级里。\n"
                .. "显示单位是千分之一：20 ‰ = 0.02，意思是「花 1B 食物至少要换回 20M CPS」。\n"
                .. "参考值：最好的台子约 0.85；中等的约 0.075；最差的约 0.016。\n"
                .. "想喂得更彻底就调小，想更省就调大。",
        })
        E.sFeedMinCps = fg:AddSlider("feedMinCps", {
            Text = "忽略低产出台子", Default = (tonumber(cfg.feedMinCps) or 1e6) / 1e6,
            Min = 0, Max = 1000, Rounding = 0, Suffix = "M CPS",
            Tooltip = "CPS 低于这个值的台子不参与计算。\n"
                .. "用途：有些 1 级角色放在台上（CPS 只有几千），它们的性价比数字看起来很高，"
                .. "但喂它们对全屋收入几乎没有帮助。\n"
                .. "默认 1M 就能把这些过滤掉。",
        })
        E.sFeedMaxActions = fg:AddSlider("feedMaxActionsPerCycle", {
            Text = "单批最多喂多少级", Default = tonumber(cfg.feedMaxActionsPerCycle) or 0,
            Min = 0, Max = 5000, Rounding = 0, Suffix = " 级",
            Tooltip = "限制一次批次最多喂多少级，防止食物太多时脚本长时间占着传送。\n"
                .. "0 = 不限（默认，一次把攒的食物花到最优）。\n"
                .. "参考速度：约 1.5~2 秒一级（含传送），所以 500 级大约 15 分钟。",
        })
        E.sFeedCooldown = fg:AddSlider("feedCooldown", {
            Text = "两批之间间隔", Default = tonumber(cfg.feedCooldown) or 20,
            Min = 5, Max = 300, Rounding = 0, Suffix = " 秒",
            Tooltip = "上一批结束后至少等这么久才会开始下一批，避免连续传送。",
        })
        E.iFeedExclude = fg:AddInput("feedExcludeStands", {
            Text = "排除的台子 / 角色", Default = tostring(cfg.feedExcludeStands or ""),
            Placeholder = "逗号分隔，例如: 5PAID, Teto", Finished = true,
            Tooltip = "填台子名（如 5PAID、P33）或角色名（如 Teto），这些台子永远不会被喂。\n"
                .. "用途：有些台子你想留着手动处理，或者想保底不喂某些角色。",
        })
        E.tFeedPair = fg:AddToggle("feedPairBonus", {
            Text = "💞 喂食优先喂配对中的台子 ★", Default = cfg.feedPairBonus ~= false,
            Tooltip = "游戏机制：配对生效时两边各得【现金产出 ×3】（但 CPS 属性不变）。\n"
                .. "所以喂一个配对中的台子，实际收益是它的 3 倍 —— 不乘的话会把食物\n"
                .. "喂给收益只有 1/3 的台子，等于系统性低估配对角色的价值。\n\n"
                .. "启用后：喂食计划按「真实收益」排序，配对台子优先被喂；\n"
                .. "喂食页签的清单里配对台子会标 💞×3。\n\n"
                .. "配对判定 = 角色名在配对表里【且】两个台子地理相邻\n"
                .. "（游戏规则：同一行 |ΔY| ≤ 8 且水平距离 ≤ 12）。\n\n"
                .. "⚠ 只改「喂食优先级」，**绝不改动你的台子布局**。\n"
                .. "关掉即完全恢复旧行为。倍率取「自动配置角色」页的配对倍率设置（默认 ×3）。",
        })
        E.tFeedDry = fg:AddToggle("feedDryRun", {
            Text = "🧪 预览模式（只算不喂）", Default = cfg.feedDryRun == true,
            Tooltip = "打开后脚本照常计算最优计划并写日志，但【绝不按下去】。\n"
                .. "建议第一次先开着它观察一两批，确认清单和预期一致，再关掉正式启用。",
        })
        E.tFeedNotify = fg:AddToggle("feedNotify", {
            Text = "每批结束弹通知", Default = cfg.feedNotify ~= false,
            Tooltip = "每批喂食结束后弹一个通知，显示喂了多少级、花了多少食物、全屋 CPS 涨了多少。",
        })
        fg:AddDivider()
        fg:AddButton({
            Text = "🔍 立即预览最优分配", Icon = "search",
            Func = function()
                feedCalibrate(true)
                R.feedPreviewShown = true
                feedPreviewList(true)
                if R.renderFeedList then pcall(R.renderFeedList) end
            end,
            Tooltip = "按当前食物和所有台子的状态，算出「这批食物应该怎么分配最划算」，显示在右边清单里。\n"
                .. "不会消耗任何食物 —— 纯计算。\n"
                .. "清单会显示：先喂哪个台子、从几级到几级、花多少食物、换来多少 CPS、性价比多少。",
        })
        fg:AddButton({
            Text = "▶ 立即喂一批", Icon = "zap",
            Func = function()
                if not cfg.feedEnabled then
                    log("⚠ 请先打开「启用自动喂食」再执行", Color3.fromRGB(255, 180, 80))
                    return
                end
                if R.feed and R.feed.running then
                    log("上一批还在执行中…", Color3.fromRGB(255, 180, 80))
                    return
                end
                feedCalibrate(true)
                local food = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0
                if cfg.feedDryRun then
                    log("🧪 预览模式已开启 —— 只计算不执行", Color3.fromRGB(200, 200, 140))
                    local plan, spent, gain, actions = feedPlan(food)
                    log(string.format("本可喂 %d 个台子 / %d 级 · 花费 %s · 全屋 CPS +%s",
                        #plan, actions, fmtShort(spent), fmtShort(gain)))
                    return
                end
                task.spawn(function() pcall(feedExecute, food) end)
            end,
            Tooltip = "立刻把当前【所有食物】按最优分配喂出去（不等攒批阈值）。\n"
                .. "⚠ 会真实消耗食物。执行中每喂一口都会复核，一旦发现异常立刻停止并报警。",
        })
        fg:AddButton({
            Text = "🎯 只喂 1 级（验证机制）", Icon = "target",
            Func = function()
                local cands = feedCandidates()
                if #cands == 0 then
                    log("没有可喂的台子", Color3.fromRGB(255, 180, 80))
                    return
                end
                local c = cands[1]
                log(string.format("当前最优先：%s %s [%s] L%d · CPS %s · 单级成本 %s · 性价比 %.4f",
                    c.label, c.name, c.rarity, c.level, fmtShort(c.cps), fmtShort(c.cost), c.eff))
                local snap = feedSnapshot(c.stand)
                local ok, err, spent = feedOne(snap)
                log(ok and ("✅ 已喂 1 级（花 " .. fmtShort(spent or 0) .. "）") or ("❌ " .. tostring(err)),
                    ok and Color3.fromRGB(120, 255, 140) or Color3.fromRGB(255, 120, 120))
                if R.renderFeedList then pcall(R.renderFeedList) end
            end,
            Tooltip = "只对【当前性价比最高的那一个台子】喂 1 级，用来验证机制是否正常。\n"
                .. "适合第一次试水：只花一级的食物，能立刻在日志和清单里看到结果。\n"
                .. "⚠ 不受「预览模式」保护，会真实扣费。",
        })
        fg:AddButton({
            Text = "🔧 重新校准折扣系数", Icon = "wrench",
            Func = function()
                local k = feedCalibrate(true)
                if k then
                    log(string.format("当前采用折扣系数 %.4f（越小越便宜）", k), Color3.fromRGB(140, 220, 255))
                else
                    log("校准失败：台子上没有可读的价格", Color3.fromRGB(255, 120, 120))
                end
            end,
            Tooltip = "脚本用【面板上显示的真实价格】反推你的升级折扣（商店折扣 × 通行证），"
                .. "反解后自动吸附到常见档位（1.0 / 0.9 / 0.5 / 0.25 / 0.225 / 0.2 / 0.125）。\n"
                .. "意义：脚本算出来的花费和游戏面板永远一致，游戏改价也会自动跟上。\n"
                .. "平时不需要点，脚本每批会自动校准一次。",
        })
    end

    --================ 🎩 总经理（自动调参）
    do
        local mg = Tabs.Feed:AddRightGroupbox("🎩 总经理（自动调参）", "briefcase")
        E.lMgr = mg:AddLabel("正在测量食物速率…（需要约 15 秒）", true)
        E.tMgrAuto = mg:AddToggle("mgrAutoTune", {
            Text = "自动调参", Default = cfg.mgrAutoTune ~= false,
            Tooltip = "让脚本根据【食物盈余】自动微调上面的「相对收益门槛」。" .. " "
                .. "原理：只盯一个可观测信号 —— 攒够一个阈值食物要多久。" .. " "
                .. "  比目标时间久  = 食物不够花 -> 放宽门槛（让更多角色吃到，避免食物闲置）" .. " "
                .. "  比目标时间短  = 食物在堆积 -> 收紧门槛（把资源集中到主力）" .. " "
                .. "为什么不直接读加成面板：Boosts 里只有一部分加成，重生/现金升级/VIP/研究"
                .. "这些倍率不在面板上，拼出来的总数既不准也不稳；而且喂食优先级本身不受"
                .. "全局倍率影响（上下同时约掉），真正会波动的只有食物产出速率。",
        })
        E.sMgrTarget = mg:AddSlider("mgrTargetBufferMinutes", {
            Text = "目标攒批时长", Default = tonumber(cfg.mgrTargetBufferMinutes) or 12,
            Min = 2, Max = 120, Rounding = 0, Suffix = " 分钟",
            Tooltip = "你希望【攒够一批食物】大约花多久。" .. " "
                .. "调小 = 喂得更勤（单批小、占传送少，但每次都要跑一遍台子）；"
                .. "调大 = 攒更久再一次喂完（批次大、传送效率高，但食物会先躺着不动）。" .. " "
                .. "建议 10~20 分钟：足够形成有意义的批次，又不会让食物积压太久。",
        })
        E.sMgrCool = mg:AddSlider("mgrAdjustCooldown", {
            Text = "调参最小间隔", Default = tonumber(cfg.mgrAdjustCooldown) or 10,
            Min = 1, Max = 120, Rounding = 0, Suffix = " 分钟",
            Tooltip = "两次自动调参之间至少隔这么久，防止刚开始测量就疯狂调整。" .. " "
                .. "食物速率本来就抖（药水断供、活动、换花园），给足观察时间才能看清趋势。" .. " "
                .. "建议 10~15 分钟。",
        })
        E.sMgrMin = mg:AddSlider("mgrMinRelGain", {
            Text = "门槛下限（最松）", Default = rnd((tonumber(cfg.mgrMinRelGain) or 0.02) * 100, 1),
            Min = 0, Max = 30, Rounding = 1, Suffix = " %",
            Tooltip = "自动调参允许把门槛放到多松。到这一步就是「食物实在花不完，"
                .. "连小角色也喂一点」。" .. " " .. "建议 2%~5%。",
        })
        E.sMgrMax = mg:AddSlider("mgrMaxRelGain", {
            Text = "门槛上限（最紧）", Default = rnd((tonumber(cfg.mgrMaxRelGain) or 0.30) * 100, 1),
            Min = 5, Max = 80, Rounding = 1, Suffix = " %",
            Tooltip = "自动调参允许把门槛收到多紧。到这一步就是「只喂最强的两三个」。"
                .. " " .. "建议 25%~40%：再紧食物就会明显堆积。",
        })
        mg:AddDivider()
        E.lMgrStat = mg:AddLabel("—", true)
        E.bMgrNow = mg:AddButton({
            Text = "🎩 立刻评估一次", Icon = "refresh-cw",
            Func = function()
                -- ★ v161：以前是无条件 pcall(managerTick) + 打一句"已手动触发"，
                --   但 managerTick 在"速率还没测出来 / R.mgr 还没建立"时会直接 return ——
                --   于是按钮看起来生效了，实际什么都没算，用户会以为总经理坏了。
                --   现在用 ticks 计数确认它真的跑到了决策段，否则如实说明原因。
                local before = (R.mgr and R.mgr.ticks) or 0
                local ok, err = pcall(managerTick)
                if R.renderMgr then pcall(R.renderMgr) end
                if not ok then
                    log("⚠ 总经理评估出错：" .. tostring(err):sub(1, 160), Color3.fromRGB(255, 120, 120))
                    return
                end
                local after = (R.mgr and R.mgr.ticks) or 0
                if after > before then
                    log("🎩 已手动触发一次总经理评估：" .. tostring(R.mgr and R.mgr.lastAction or "完成"))
                else
                    log("🎩 总经理本次未做决策：食物速率样本还不够（约需 8 秒），或食物数量暂时读不到。稍后再试即可。",
                        Color3.fromRGB(255, 200, 90))
                end
            end,
            Tooltip = "不等下一个 3 秒周期，立刻按当前食物速率评估一次并给出结论。"
                .. " 在死区（±25%）内它会明确告诉你「不调」，这是正常的。"
                .. " 若刚启动不到 8 秒，它会说明样本还不够而跳过 —— 这是为了保护读数准确。"
        })

        function R.renderMgr()
            if not E.lMgrStat then return end
            local ms = managerStatus()
            -- ⚠⚠ 实测坑：Obsidian 的 AddLabel **不渲染富文本标签**，
            --   写 <font color=...> / <b> 会原样显示成文字（用户截图反馈"很诡异"）。
            --   所以这里只用【纯文本 + 状态符号】，绝不写任何尖括号标签。
            local lines = {}
            lines[#lines + 1] = ms.enabled and "● 在岗（自动调参已开启）" or "○ 已下岗"
            if ms.rate and ms.rate > 0 then
                lines[#lines + 1] = string.format("食物速率: %s/秒 (%s/小时)",
                    fmtShort(ms.rate), fmtShort(ms.rate * 3600))
            else
                lines[#lines + 1] = "食物速率: 测量中…"
            end
            lines[#lines + 1] = string.format("当前门槛: %s%%  (允许 %s%% ~ %s%%)",
                tostring(rnd(ms.currentRelGain, 1)), tostring(rnd(ms.minRelGain, 0)),
                tostring(rnd(ms.maxRelGain, 0)))
            if ms.etaMinutes then
                local okStr = math.abs((ms.errPct or 0)) <= 25 and "✅ 在目标区间内"
                    or ((ms.errPct or 0) > 0 and "⚠ 攒得太慢(食物不够)" or "⚠ 攒得太快(食物堆积)")
                lines[#lines + 1] = string.format("攒批耗时: %s 分钟 · %s",
                    tostring(rnd(ms.etaMinutes, 1)), okStr)
                if ms.reframed then
                    -- 边界解锁（v160）：目标时间已被自动重设到真实可达水平
                    lines[#lines + 1] = string.format("目标时间: %s 分钟（你设的是 %s，够不着已自动重设 %d 次）",
                        tostring(rnd(ms.targetMinutes, 1)), tostring(rnd(ms.userTargetMinutes or 0, 0)),
                        ms.reframes or 0)
                else
                    lines[#lines + 1] = string.format("目标时间: %s 分钟",
                        tostring(rnd(ms.targetMinutes, 1)))
                end
            end
            if ms.measuredWindow then
                lines[#lines + 1] = string.format("速率采样窗口: 约 %.1f 秒（与喂食模块同源）",
                    tonumber(ms.measuredWindow) or 0)
            end
            if ms.lastAction then
                lines[#lines + 1] = "上次动作: " .. tostring(ms.lastAction)
            end
            lines[#lines + 1] = string.format("累计调整: %d 次", ms.changes or 0)
            local b = {}
            if ms.boostCash then b[#b + 1] = "2x Cash = " .. ms.boostCash end
            if ms.boostLuck then b[#b + 1] = "Total Luck = " .. ms.boostLuck end
            if #b > 0 then
                lines[#lines + 1] = "加成(仅供参考): " .. table.concat(b, " · ")
            end
            local txt = table.concat(lines, chr(10))
            pcall(function() E.lMgrStat:SetText(txt) end)
            pcall(function() E.lMgr:SetText(txt) end)
        end
        R.renderMgr = R.renderMgr or nil
    end

    --================ 喂食 / 最优分配清单
    do
        local fl = Tabs.Feed:AddRightGroupbox("最优分配清单", "list")
        E.lFeedList = fl:AddLabel("点左边「🔍 立即预览最优分配」查看清单", true)
        E.tFeedAutoPrev = fl:AddToggle("feedAutoPreview", {
            Text = "自动刷新这个清单", Default = cfg.feedAutoPreview ~= false,
            Tooltip = "每 3 秒自动重算一次清单，食物增长和喂食结果都能立刻看到。\n"
                .. "关闭可以省一点性能（台子多的时候每次扫描要读 40 个台子）。",
        })
        fl:AddDivider()
        E.lFeedStats = fl:AddLabel("—", true)

        function R.renderFeedList()
            if not E.lFeedList then return end
            local pv = feedPreviewList()
            local lines = {}
            local food = pv.food
            local thr = pv.threshold
            local F = R.feed or {}
            if not cfg.feedEnabled then
                lines[#lines + 1] = '喂食已关闭'
            elseif F.running then
                lines[#lines + 1] = '▶ 正在执行喂食批次…'
            elseif tostring(cfg.feedMode) == "auto" and food < thr then
                local rate = pv.rate or 0
                local eta = (rate > 0) and ((thr - food) / rate) or 0
                lines[#lines + 1] = string.format(
                    '<font color="rgb(255,200,90)">⏳ 攒食物中：%s / %s（还差 %s%s）</font>',
                    fmtShort(food), fmtShort(thr), fmtShort(thr - food),
                    eta > 0 and string.format("，约 %.0f 分钟后开喂", eta / 60) or "")
            else
                lines[#lines + 1] = '✅ 条件已满足，下次主循环就会动手'
            end
            if cfg.feedDryRun then
                lines[#lines + 1] = '🧪 预览模式：只算不喂'
            end
            lines[#lines + 1] = string.format(
                '<font color="rgb(150,150,170)">食物 %s · 速率 %s/秒 · 折扣 %.3f · 全屋 CPS %s</font>',
                fmtShort(food), fmtShort(pv.rate or 0), pv.keep or 0, fmtShort(pv.totalCps))
            -- 💞 配对加成状态（v271）
            if cfg.feedPairBonus ~= false then
                local pc = R.feed and R.feed._pairCount or 0
                if pc and pc > 0 then
                    lines[#lines + 1] = string.format(
                        '<font color="rgb(255,150,220)">💞 配对生效 %d 个台子 —— 它们的真实收益已按 ×%d 计入优先级</font>',
                        pc, tonumber(cfg.astPairMult) or 3)
                else
                    lines[#lines + 1] = '<font color="rgb(150,150,170)">💞 配对加成已开启，但当前没有台子满足"配对且相邻"</font>'
                end
            end
            lines[#lines + 1] = ""
            if pv.planActions > 0 then
                lines[#lines + 1] = string.format(
                    '<font color="rgb(140,220,255)">━━ 本批计划：%d 个台子 · %d 级 · 花 %s · 全屋 +%s ━━</font>',
                    #pv.plan, pv.planActions, fmtShort(pv.planSpent), fmtShort(pv.planGain))
                for i, it in ipairs(pv.plan) do
                    if i > 12 then
                        lines[#lines + 1] = string.format('<font color="rgb(150,150,170)">   … 还有 %d 个台子</font>', #pv.plan - 12)
                        break
                    end
                    local rc = HW_K.RARITY_COLORS[it.rarity] or Color3.fromRGB(220, 220, 220)
                    -- 💞 配对中的台子标出来（这一行标了 ×3 说明它每级多赚 3 倍）
                    local ptag = ""
                    if it.snap and it.snap.paired then
                        ptag = string.format('<font color="rgb(255,150,220)">💞×%d  </font>',
                            tonumber(it.snap.pairMult) or 3)
                    end
                    lines[#lines + 1] = string.format(
                        '<font color="rgb(%d,%d,%d)">%2d. %s</font> <font color="rgb(150,150,170)">[%s]</font> %s%s  '
                        .. '<font color="rgb(255,180,90)">L%d→%d</font> <font color="rgb(160,220,255)">+%d级</font>  '
                        .. '<font color="rgb(120,255,140)">+%s CPS</font>  <font color="rgb(200,200,140)">花 %s · %.3f</font>',
                        math.floor(rc.R * 255), math.floor(rc.G * 255), math.floor(rc.B * 255),
                        i, it.name, it.rarity, it.mut ~= "" and ("(" .. it.mut .. ")") or "", ptag,
                        it.from, it.to, it.levels, fmtShort(it.gain), fmtShort(it.spent), it.eff)
                end
            else
                lines[#lines + 1] = '当前没有值得喂的目标'
                lines[#lines + 1] = '（食物不够付任何一台的一级，或性价比都低于下限）'
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = '━━ 全部台子性价比排名（高→低）━━'
            local cap = math.min(#pv.cands, 14)
            for i = 1, cap do
                local c = pv.cands[i]
                local rc = HW_K.RARITY_COLORS[c.rarity] or Color3.fromRGB(220, 220, 220)
                local bar = c.eff >= 0.3 and "★★★" or (c.eff >= 0.1 and "★★" or (c.eff >= 0.03 and "★" or "·"))
                lines[#lines + 1] = string.format(
                    '%s<font color="rgb(%d,%d,%d)">%2d. %-14s</font> <font color="rgb(150,150,170)">[%s]</font> '
                    .. '<font color="rgb(200,200,200)">L%-4d</font> <font color="rgb(160,220,255)">%s</font> '
                    .. '<font color="rgb(120,255,140)">+%s</font> <font color="rgb(200,200,140)">%.4f</font>',
                    bar, math.floor(rc.R * 255), math.floor(rc.G * 255), math.floor(rc.B * 255),
                    i, c.name, c.rarity, c.level, fmtShort(c.cps), fmtShort(c.gain), c.eff)
            end
            if #pv.cands > cap then
                lines[#lines + 1] = string.format('<font color="rgb(150,150,170)">   … 还有 %d 个台子</font>', #pv.cands - cap)
            end
            E.lFeedList:SetText(table.concat(lines, "\n"))

            if E.lFeedStats then
                E.lFeedStats:SetText(string.format(
                    '累计：%d 批 · %d 级 · 花费 %s\n上次：%s\n上次结果：%s\n折扣校准：%.4f（原始 %.4f，%d 样本）',
                    F.batches or 0, F.actions or 0, fmtShort(F.spent or 0),
                    tostring(F.lastAt or "-"), tostring(F.lastSummary or "-"),
                    pv.keep or 0, (F.keepRaw or 0), (F.keepSamples or 0)))
            end
        end

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
        -- ⚠ 这里原本还有一个独立的「Solar 参与品质 ★」下拉。
        --   它和下面选择器里的「① Solar 参与品质」是**两个能选不同值的框**，
        --   用户实测指出这是冲突设计（原话：「这样弄两个品质选择都能选不同的品质，
        --   那不就冲突了吗」）。已删除，品质只保留下面的那一个。
        -- 🎯 v238：哪个品质的哪些角色去赌 Solar（不勾 = 该品质全部参与）
        sg:AddDivider()
        R.charFilter.buildPicker(sg, {
            mode = "solar",
            bindRarKey = "solarRarities",     -- ★ 它的品质选择就是 cfg.solarRarities（唯一一份）
            title = "🎯 哪些角色去赌 Solar 突变",
            tip = "想省着用的高价值角色不要勾 —— 它们会留在德古拉那边。",
            rarText = "① Solar 参与品质 ★",
            rarDefault = cfg.solarRarities or {},
            rarTip = "只有这些品质的角色会被拿去赌 Solar 突变（与 Solar 模块原有的品质选择是同一份）。"
                .. "下面的角色勾选是在这个品质名单之内再筛一层。",
            charTip = "只列【白板】角色（已突变过的没法二次突变，不列）。"
                .. "该品质一个都不勾 = 这个品质的角色全部参与；勾了任意一个 = 只参与勾上的。\n"
                .. "每条格式：[品质] 角色名 $初始CPS 状态\n"
                .. "状态含义：×N = 背包里有 N 个白板 / ❌没有 = 背包里没有（先勾上，以后抽到自动生效）"
                .. " / ✗已全突变 = 全部突变完了，不能再赌 / 🚫已给XXX = 已被别的功能选走，不能同时勾选\n"
                .. "标签较长，把窗口拉宽一些就能完整看到（下面的预览行也是全宽的）。\n"
                .. "⚠ 受UI库限制，单独点掉最后一个勾选会被拦 —— 想清空请用下面的「🧹 清空勾选」按钮。",
            initText = "预览: 等待扫描背包…",
        })
        -- 📋 板块级总预览（用户要求：Solar 也要有一个"会拿哪些角色去突变"的整齐清单）
        sg:AddDivider()
        E.lSolarPick = sg:AddLabel("【总预览】等待扫描背包…", true)
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
        E.sSolarCommit = sg:AddSlider("solarCommitSeconds", {
            Text = "锁定一颗陨石后站定等待 ★", Default = tonumber(cfg.solarCommitSeconds) or 4.5,
            Min = 1, Max = 12, Rounding = 1, Suffix = " 秒",
            Tooltip = "陨石从生成到落地约需 3 秒（Solar）。这段时间内脚本不再理会新陨石，"
                .. "站定在落点上等它砸下来 —— 否则会被后来的陨石一直勾走，永远等不到被砸中。"
                .. "Heaven 的流星很快（约 0.8 秒），可以调小。",
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
                uiBox:AddLabel('KeyPicker 不可用，请用下方输入框填写按键名', true)
            end
        else
            uiBox:AddLabel('本库不支持 KeyPicker，请用下方输入框填写按键名（如 RightShift）', true)
        end
        E.iKeybind = uiBox:AddInput("menuKeybind", {
            Text = "按键名（备用）", Default = tostring(cfg.menuKeybind or "RightShift"),
            Placeholder = "RightShift / F1 / Q ...", Finished = true,
            Tooltip = "填好后按回车生效；需重新打开脚本或点保存配置",
        })
        uiBox:AddButton({ Text = "保存配置（含快捷键）", Icon = "save", Func = function() saveConfig() end })
        -- 🖼 窗口尺寸记忆：拉大/缩小后会自动存进配置，这里给一个"回到默认"的出口
        uiBox:AddDivider()
        uiBox:AddLabel("🖼 窗口大小会被自动记住（拉大后下次打开还是这么大）", true)
        uiBox:AddButton({
            Text = "重置窗口大小到默认", Icon = "maximize-2",
            Func = function()
                cfg.uiWin = nil
                local W = R.window
                local f = W and W.MainFrame
                if f then
                    pcall(function()
                        -- 用同一个钳制函数算出"默认尺寸在当前视口里居中"的坐标
                        local w, h, x, y = R.uiClampWin(720, 600, nil, nil)
                        f.Size = UDim2.fromOffset(w, h)
                        f.Position = UDim2.fromOffset(x, y)
                    end)
                end
                log("🖼 窗口大小已重置为默认 720x600 并居中（配置里的记录也清了）",
                    Color3.fromRGB(140, 220, 255))
            end,
        })
    end

    --================ 配置
    if SaveManager then
        SaveManager:SetLibrary(Library)
        SaveManager:IgnoreThemeSettings()
        -- ⚠ v336：**不再忽略 MenuKeybind** —— 配置改由库管之后，若继续忽略它，
        --   用户自定义的菜单快捷键每次启动都会丢（库的存档是唯一持久层了）。
        -- SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
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
    -- 万圣节品质的改动由选择器①号框负责（bindRarKey="rarities"），
    -- 它的回调里已经做了 refreshCandidates + manageHotbar，这里不再重复挂。
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
        -- ⚠⚠ v336：这个开关**已废弃**（实测证明它会破坏持有：每秒重刷游戏客户端的
        --   "选中"状态 -> 角色每一两秒消失又重新出现，持有无法连续到活动结束）。
        --   所以"打开也无效"：立刻弹回关闭并告警。控件本身保留（applyCfgToUI /
        --   readUIIntoCfg 会引用 E.tFrame，删控件要同时改两处，保留更省事）。
        cfg.nativeSelectionFrame = false
        clientClearSelection()
        if v ~= false then
            pcall(function() E.tFrame:SetValue(false) end)
            log("⚠「手持蓝框」已废弃并强制关闭：实测它会破坏持有（角色反复消失又出现）。"
                .. "蓝框与突变无关，服务器判定只看 workspace.ToolFollowers。",
                Color3.fromRGB(255, 120, 120))
        end
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
    -- Solar 品质不再有独立下拉：由选择器①号框负责（bindRarKey="solarRarities"）
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
    if E.sSolarCommit then
        E.sSolarCommit:OnChanged(function(v) cfg.solarCommitSeconds = tonumber(v) or 4.5 end)
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
    -- 去突变品质不再有独立下拉：由选择器①号框负责（bindRarKey="washRarities"），
    --   它的回调里已经做了日志 + renderWashList，这里不再重复挂。
    if E.tWashAuto then
        E.tWashAuto:OnChanged(function(v) cfg.washAutoPreview = v == true end)
    end
    -- ===== 自动关弹窗回调 =====
    if E.tAutoClose then
        E.tAutoClose:OnChanged(function(v)
            cfg.autoCloseEnabled = v == true
            log(cfg.autoCloseEnabled and "🚪 自动关弹窗已开启" or "🚪 自动关弹窗已关闭")
        end)
    end
    if E.tAutoCloseWelcome then
        E.tAutoCloseWelcome:OnChanged(function(v) cfg.autoCloseWelcome = v == true end)
    end
    if E.tAutoCloseDaily then
        E.tAutoCloseDaily:OnChanged(function(v) cfg.autoCloseDaily = v == true end)
    end
    if E.sAutoCloseDelay then
        E.sAutoCloseDelay:OnChanged(function(v) cfg.autoCloseDelay = tonumber(v) or 1.5 end)
    end

    -- ===== 喂食回调 =====
    if E.tFeed then
        E.tFeed:OnChanged(function(v)
            cfg.feedEnabled = v == true
            if cfg.feedEnabled then
                feedCalibrate(true)
                local pv = feedPreviewList(true)
                log(string.format("🍖 自动喂食已开启（%s 模式）· 可喂台子 %d 个 · 食物 %s · 阈值 %s",
                    tostring(cfg.feedMode), #pv.cands, fmtShort(pv.food), fmtShort(pv.threshold)))
                log("提示：先用「🔍 立即预览最优分配」看一眼计划再放手让脚本跑")
            else
                log("🍖 自动喂食已关闭")
            end
        end)
    end
    if E.dFeedMode then
        E.dFeedMode:OnChanged(function(v)
            cfg.feedMode = tostring(v or "auto")
            local nm = { auto = "攒够一批再喂", smart = "随时喂最优的一口", manual = "只手动" }
            log("🍖 喂食节奏 = " .. tostring(nm[cfg.feedMode] or cfg.feedMode))
        end)
    end
    if E.sFeedBatch then E.sFeedBatch:OnChanged(function(v) cfg.feedBatchFood = (tonumber(v) or 3) * 1e9 end) end
    if E.sFeedMins then E.sFeedMins:OnChanged(function(v) cfg.feedThresholdMaxMinutes = tonumber(v) or 0 end) end
    if E.sFeedMinEff then
        E.sFeedMinEff:OnChanged(function(v)
            cfg.feedMinEfficiency = (tonumber(v) or 20) / 1000
            log(string.format("🍖 性价比下限 = %.4f", cfg.feedMinEfficiency))
        end)
    end
    if E.sFeedMinCps then E.sFeedMinCps:OnChanged(function(v) cfg.feedMinCps = (tonumber(v) or 1) * 1e6 end) end
    if E.sFeedRelGain then
        E.sFeedRelGain:OnChanged(function(v)
            cfg.feedMinRelGain = (tonumber(v) or 5) / 100
            log(string.format("🍖 相对收益门槛 = %.1f%%", cfg.feedMinRelGain * 100))
            feedPreviewList(true)
            if R.renderFeedList then pcall(R.renderFeedList) end
        end)
    end
    if E.tMgrAuto then
        E.tMgrAuto:OnChanged(function(v)
            cfg.mgrAutoTune = v == true
            log(cfg.mgrAutoTune and "🎩 总经理已上岗：自动按食物盈余调节门槛"
                or "🎩 总经理已下岗：门槛完全由你手动控制")
            if R.renderMgr then pcall(R.renderMgr) end
        end)
    end
    if E.sMgrTarget then E.sMgrTarget:OnChanged(function(v) cfg.mgrTargetBufferMinutes = tonumber(v) or 12 end) end
    if E.sMgrCool then E.sMgrCool:OnChanged(function(v) cfg.mgrAdjustCooldown = tonumber(v) or 10 end) end
    if E.sMgrMin then E.sMgrMin:OnChanged(function(v) cfg.mgrMinRelGain = (tonumber(v) or 2) / 100 end) end
    if E.sMgrMax then E.sMgrMax:OnChanged(function(v) cfg.mgrMaxRelGain = (tonumber(v) or 30) / 100 end) end
    if E.sFeedMaxActions then E.sFeedMaxActions:OnChanged(function(v) cfg.feedMaxActionsPerCycle = tonumber(v) or 0 end) end
    if E.sFeedCooldown then E.sFeedCooldown:OnChanged(function(v) cfg.feedCooldown = tonumber(v) or 20 end) end
    if E.iFeedExclude then
        E.iFeedExclude:OnChanged(function(v)
            cfg.feedExcludeStands = tostring(v or "")
            if R.renderFeedList then pcall(R.renderFeedList) end
        end)
    end
    if E.tFeedPair then
        E.tFeedPair:OnChanged(function(v)
            cfg.feedPairBonus = v == true
            R.feed = R.feed or {}
            R.feed._pm = nil          -- 清配对缓存，立刻生效
            R.feed._pv = nil
            log(cfg.feedPairBonus
                and "💞 已开启：喂食优先喂【配对中】的台子（实际收益 ×3）"
                or "💞 已关闭：喂食按原始 CPS 收益排序（配对加成不参与）")
        end)
    end
    if E.tFeedDry then
        E.tFeedDry:OnChanged(function(v)
            cfg.feedDryRun = v == true
            log(cfg.feedDryRun and "🧪 预览模式已开启：只算不喂" or "⚠ 预览模式已关闭：会真实消耗食物")
        end)
    end
    if E.tFeedNotify then E.tFeedNotify:OnChanged(function(v) cfg.feedNotify = v == true end) end
    if E.tFeedAutoPrev then E.tFeedAutoPrev:OnChanged(function(v) cfg.feedAutoPreview = v == true end) end
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
            -- ⚠ 原来这里写的是 `hl and '' or ''`（两个分支都是空串 = 永远不高亮），
            --   而且开标签被误删导致只剩 </font> —— 富文本解析直接报错、整个 UI 构建失败。
            --   现在补回开标签并让它真的起作用。
            E.lEvent:SetText(string.format('%s事件: %s (%s)  剩余 %d:%02d</font>',
                hl and '<font color="rgb(120,255,140)">' or '<font color="rgb(255,200,90)">',
                tostring(ev.title or ev.name), tostring(ev.name), math.floor(secs / 60), secs % 60))
        else
            E.lEvent:SetText('事件: 无')
        end

        -- ★★★ v365：显示"**真实**手上有什么"，并区分是谁持的
        --   原来只看 R.hold.key（脚本自己的持有）⇒ 你手动持着时也显示"手持: 无"，
        --   看起来像"判定坏了"，其实放手判定用的是 heldName()（查 ToolFollowers + 角色里的 Tool），
        --   它一直是好的（历史日志：「事件 Party 运行中，你手动手持的 Zera Two 可能被突变 -> 自动放手」）。
        do
            local realHeld = heldName()
            if h.key then
                E.lHeld:SetText(string.format('<font color="rgb(120,255,140)">手持: %s [%s]</font>  (%.0fs)',
                    tostring(h.name), tostring(h.rarity), os.clock() - (h.since or os.clock())))
            elseif realHeld then
                E.lHeld:SetText(string.format(
                    '<font color="rgb(255,200,90)">手持: %s（你手动持有 · 脚本未接管）</font>', tostring(realHeld)))
            else
                E.lHeld:SetText('手持: 无')
            end
            -- ⚡ 防闪电硬放手状态（Thunder/Slime/Blizzard… 期间应为「武装中」）
            if E.lHardRel and type(R.hardReleaseState) == "function" then
                local evLive2, evN, intent = R.hardReleaseState()
                if not evLive2 then
                    E.lHardRel:SetText('<font color="rgb(150,150,170)">防闪电硬放手: 待命（当前无活动）</font>')
                elseif intent then
                    E.lHardRel:SetText(string.format(
                        '<font color="rgb(255,200,90)">防闪电硬放手: 不适用（%s = 故意持有：万圣节/Solar模块）</font>',
                        tostring(evN)))
                else
                    E.lHardRel:SetText(string.format(
                        '<font color="rgb(120,255,140)">防闪电硬放手: 武装中（活动 %s 非目标 ⇒ 手上角色一律放掉）</font>',
                        tostring(evN)))
                end
            end
        end

        E.lStats:SetText(string.format('候选 %d 个  |  Dracula %d · Demonic %d · 其他 %d · 尝试 %d',
            #R.candidates, R.stats.dracula, R.stats.demonic, R.stats.other, R.stats.attempts))

        -- 📋 候选清单：与 Solar/去突变 用**同一套**格式（名字对齐、品质着色、CPS 绿色）
        if #R.candidates == 0 then
            E.lCands:SetText('  （无可选干净角色 — 检查品质勾选 / 是否都已突变）')
        else
            local fmted = R.charFilter and R.charFilter.formatList
            local sum, top = 0, 0
            for _, c in ipairs(R.candidates) do
                sum = sum + (tonumber(c.cps) or 0)
                if (tonumber(c.cps) or 0) > top then top = tonumber(c.cps) or 0 end
            end
            local head = string.format(
                '<font color="rgb(120,255,140)">共 %d 个可赌角色</font>  '
                .. '<font color="rgb(150,150,170)">合计 %s · 最高 %s</font>',
                #R.candidates, fmtCps(sum), fmtCps(top))
            local body
            if fmted then
                body = fmted(R.candidates, { cap = 10 })
            else
                local l2 = {}
                for i, c in ipairs(R.candidates) do
                    if i > 10 then break end
                    l2[#l2 + 1] = string.format("  %2d. %s  %s", i,
                        colored(c.name .. " [" .. c.rarity .. "]", HW_K.RARITY_COLORS[c.rarity]),
                        colored(fmtCps(c.cps), Color3.fromRGB(140, 230, 150)))
                end
                body = table.concat(l2, "\n")
            end
            E.lCands:SetText(head .. "\n" .. body)
        end

        local hl = {}
        for i, k in ipairs(R.hotbar.layout or {}) do
            local tag = isPotionKey(k) and ' [药水]' or ""
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
            local health = (pot == 0) and '正常'
                or ('<font color="rgb(255,110,110)">异常 %d 个药水</font>'):format(pot)
            local potConn = R.hotbar.potionConnEnabled
            local potState
            if cfg.blockPotionInsert == false then
                potState = '未启用'
            elseif potConn == false then
                potState = '已禁用'
            elseif potConn == true then
                potState = '仍启用'
            else
                potState = '未知'
            end
            local drive = (cfg.clientDriveUI ~= false) and '开'
                or '关'
            local remain = (R.hotbar.manualUntil or 0) - os.clock()
            if cfg.pauseHotbar then
                E.lHotbarStatus:SetText('⏸ 已暂停接管 —— 快捷栏完全由你手动控制\n'
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
            local state = (on == true) and '已开启'
                or (on == false) and '已关闭'
                or '读不到'
            E.lFish:SetText(string.format('自动钓鱼: %s · 内置AutoFish %s\n状态: %s · 距上次上钩 %.0f 秒（阈值 %d 秒）\n上钩累计 %d 次 · 收获计数 %s\n重按钓鱼 %d 次 · 补开自动捕鱼 %d 次 · 补传送 %d 次',
                cfg.autoFish and '运行中' or '未启用',
                state,
                bite and '刚上钩' or '等待中',
                idle, tonumber(cfg.fishStallSeconds) or 45,
                FISH.bites or 0, tostring(FISH.lastCatchText or "?"),
                FISH.starts or 0, FISH.ensured, FISH.tp or 0))
        end

        -- 钓点状态
        if E.lFishPond then
            local inside = inPond()
            local pos, name, dist = nearestPondPoint()
            E.lFishPond:SetText(string.format('钓点: %s · 最近 %s（%.0f 格）',
                inside and ('在 ' .. inside .. ' 内')
                    or '不在钓点内',
                tostring(name or "?"), tonumber(dist) or 0))
        end

        -- Solar 状态
        if E.lSolar then
            local S = solarState()
            -- ★ v160 卡顿修复：这里原来**每帧都遍历一遍 workspace 的所有子对象**数陨石，
            --   而这个函数被 5Hz 界面线程 + 主循环同时调用 -> 每秒十几次全量遍历。
            --   陨石数量变化远没那么快，缓存 0.5 秒完全够用（观感无差别，开销砍掉 90% 以上）。
            local clk = os.clock()
            if not R._airAt or (clk - R._airAt) >= 0.5 then
                R._airAt = clk
                local air = 0
                for _, d in ipairs(workspace:GetChildren()) do if d.Name == "Meteorite" then air = air + 1 end end
                R._airCache = air
            end
            local air = R._airCache or 0
            E.lSolar:SetText(string.format('Solar: %s · 空中陨石 %d 颗\n%s\n陨石 %d · 传送 %d · 突变 %d（目标 %d）· 跳过 %d\n目标突变: %s',
                S.active and '进行中'
                    or (isSolar() and '事件在但未激活')
                    or '未开始',
                air,
                (function()
                    local left = (S.commitUntil or 0) - os.clock()
                    if S.active and left > 0 then
                        return string.format('<font color="rgb(255,200,90)">☄ 已锁定陨石 (%.0f, %.0f)，站定等待中 %.1f 秒</font>',
                            tonumber((S.targetXZ or "0, 0"):match("^(%-?%d+)") or 0),
                            tonumber((S.targetXZ or "0, 0"):match("(%d+)$") or 0), left)
                    elseif S.active then
                        return '待命：等下一颗陨石'
                    end
                    return '-'
                end)(),
                S.meteors, S.tp, S.hits, S.targets, S.skipped or 0,
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
                (cfg.autoSave ~= false) and '开启'
                    or '关闭',
                R._cfgSaveCount or 0, tostring(R._lastAutoSave or "-"),
                R._cfgDirty and '有'
                    or '无'))
        end

        -- 自动关弹窗状态
        if E.lAutoClose then
            local acs = R.autoCloseStatus and R.autoCloseStatus() or nil
            if acs then
                local parts = {}
                for _, p in ipairs(acs.popups) do
                    parts[#parts + 1] = string.format("%s%s%s", p.label,
                        p.on and "" or "(关)",
                        p.visible and ' [可见]' or "")
                end
                E.lAutoClose:SetText(string.format('自动关窗: %s · 已关 %d 次%s\n监控: %s',
                    acs.enabled and '开启'
                        or '关闭',
                    acs.count,
                    acs.lastAt and ("（上次 " .. acs.lastAt .. " " .. tostring(acs.lastWhat) .. "）") or "",
                    table.concat(parts, " · ")))
            end
        end

        -- 喂食状态
        if E.lFeed then
            local pv = feedPreviewList()
            local F = R.feed or {}
            local st
            if not cfg.feedEnabled then
                st = '未启用'
            elseif F.running then
                st = '执行中'
            elseif tostring(cfg.feedMode) == "auto" and pv.food < pv.threshold then
                local eta = (pv.rate or 0) > 0 and ((pv.threshold - pv.food) / pv.rate / 60) or 0
                st = string.format('<font color="rgb(255,200,90)">攒食物中（约 %.0f 分钟）</font>', eta)
            else
                st = '就绪'
            end
            E.lFeed:SetText(string.format(
                '喂食: %s · %s 模式%s\n可喂 %d 台 · 本批计划 %d 级 · 花 %s\n食物 %s / 阈值 %s · 速率 %s/秒\n全屋 CPS %s · 累计 %d 批 %d 级',
                st, tostring(cfg.feedMode or "auto"), cfg.feedDryRun and " 🧪预览" or "",
                #pv.cands, pv.planActions, fmtShort(pv.planSpent),
                fmtShort(pv.food), fmtShort(pv.threshold), fmtShort(pv.rate or 0),
                fmtShort(pv.totalCps), F.batches or 0, F.actions or 0))
            -- ★ v160：把"上一批怎么结束的"直接写进界面 —— 排查"只喂一点就停"的第一线索
            if F.lastStop or F.lastSeconds then
                E.lFeed:SetText(E.lFeed.Text .. string.format('\n上批: %s%s · %s',
                    F.lastSeconds and string.format("%.1f 秒", F.lastSeconds) or "-",
                    F.lastStop and (" · " .. tostring(F.lastStop)) or "",
                    tostring(F.lastLeft or "")))
            end
            if F.lastSkip then
                E.lFeed:SetText(E.lFeed.Text .. "\n上次跳过: " .. tostring(F.lastSkip))
            end
        end

        -- 去突变状态
        if E.lWash then
            local st, act = depoState()
            local tl = depoTimeLeft()
            local names = { idle = '空闲',
                            ready = '已手持可放',
                            pickup = '有待取回角色',
                            busy = '正在洗',
                            none = '没有机器',
                            unknown = '未知' }
            local nt, nr = 0, 0
            for _ in pairs(cfg.washTypes or {}) do nt = nt + 1 end
            for _ in pairs(cfg.washRarities or {}) do nr = nr + 1 end
            E.lWash:SetText(string.format('去突变: %s · 剩余 %s\n本次已放入 %d 个 · 上一个: %s\n勾选: 突变 %d 项 · 品质 %d 项',
                names[st] or st, tostring(tl or "-"), WASH.placed, tostring(WASH.lastPlacedName or "-"), nt, nr))
        end

        -- 🎯 v238：角色级筛选选择器（预览 + 动态换角色选项），每轮刷一次
        if R.charFilter then pcall(R.charFilter.refreshUI) end

        -- 🖼 窗口尺寸记忆：拉大/缩小后自动写进配置（内部只在尺寸真变了才写）
        if R.uiTrackSize then pcall(R.uiTrackSize) end

        -- 🔵 蓝框重刷（默认**关闭**，用户 2026-10 明确要求）
        --   历史：这里曾经每秒重刷一次客户端"选中"状态来维持蓝框（v311）。
        --   但实测证明这条路走不通 —— 游戏自己的跟随/装备系统会不断重画它自己的
        --   原生选中框（实测在 Slot_1/Slot_2 之间来回画），脚本只能追着跑 ->
        --   3.6 秒内状态变化 7 次 -> 肉眼就是闪烁。
        --   用户原话："只要能给服务器接受角色突变就行了，其他我不在意了"。
        --   ⇒ 默认不画。**注意：蓝框与突变无关**，服务器只看 ToolFollowers（真持有）。
        --   想打开就把配置里 nativeSelectionFrame 改成 true（会闪，但功能无影响）。
        if cfg.nativeSelectionFrame == true then
            local hk = R.hold and R.hold.key
            if hk then
                local nowF = os.clock()
                if (nowF - (R._frameReapplyAt or 0)) >= 1 then
                    R._frameReapplyAt = nowF
                    if R.clientSetSelected then pcall(R.clientSetSelected, hk) end
                end
            end
        end

        -- 🍬 万圣节糖果自动收集（v316）：伪触碰，**不移动角色**
        --   因为不动角色，所以不需要 busySuggest，也不会和 Solar/喂食/钓鱼抢位置。
        if R.candy then pcall(R.candy.tick) end

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
        -- ★★★ v171 修复"日志出现半截 <font 标签" ★★★
        -- 实测根因（量出来的几何数据，别改回去）：
        --   · 日志 TextLabel 视口约 224 宽 × 可视高仅 **530px**（再外层 ScrollingFrame 242x530）
        --   · 标签自己的 ScrollingFrame canvas==viewport → **不产生滚动条**，滚不动
        --   · 字高约 38px，224px 宽 ≈ 30 个汉字/行
        --   ⇒ 一条 105 字的日志要折成 ~4 行 = 150px。旧的"最多 25 条"= 960px+
        --     远超 530px ⇒ **后半截被裁掉，切口正好落在 <font ...> 标签中间**，
        --     界面上就出现半截标签文字（用户反馈的"文字问题"）。
        --   ⇒ 对策：按**总可视行数**做预算（不是按条数），并对超长消息截断。
        --     这样任何一条都不会被裁在中间，最新的几条永远完整可见。
        --     ⚠ 完整内容不受影响：持久日志文件里是全文；想多看几行就调大 logShowLines。
        local totalLines = math.max(3, tonumber(cfg.logShowLines) or 12)
        local maxLen = math.max(20, tonumber(cfg.logMsgMaxChars) or 48)
        local lines, used, first = {}, 0, true
        local perLine = 30      -- 224px 宽大约放得下 30 个汉字
        for i = #R.log, 1, -1 do
            local e = R.log[i]
            -- ⚠ 单条消息里的换行会把一行撑成两行，破坏行数预算 -> 压成空格
            local msg = tostring(e.msg):gsub("[\r\n]+", " ")
            local limit = maxLen - (first and 7 or 0)     -- 首行还要放 "[HH:MM:SS] "
            if #msg > limit then
                msg = msg:sub(1, math.max(8, limit - 3)) .. "…"
            end
            local cost = math.max(1, math.ceil((#msg + 11) / perLine))
            if used + cost > totalLines and not first then break end
            lines[#lines + 1] = colored(string.format("[%s] %s", e.t, msg), e.color)
            used = used + cost
            first = false
        end
        if #lines == 0 then lines[1] = "（暂无日志）" end
        E.lLog:SetText(table.concat(lines, "\n"))
    end

    function R.notify(info)
        pcall(function() Library:Notify(info) end)
    end

    uiBuilt = true
    --========================================================== 💞 角色勾选的恢复原理
    -- ⚠⚠⚠ 这块踩了两个大坑，结论是"**什么都不用做**"，别再往这里加代码：
    --
    --   现状（正确）：`readUIIntoCfg()` **不读 charPick**，
    --     三个选择器的勾选**只由它们自己的 OnChanged 回调写入**。
    --     ⇒ 只要没有别的代码在"数据未就绪"时去写下拉，cfg 里的勾选就不可能被清空。
    --     ⇒ 界面由 cfRefreshUI 的**幂等对齐**在背包/图鉴就绪后同步过来。
    --
    --   ❌ 坑 1（v284）：在这里放过"把 cfg.charPick 推进下拉"的代码。
    --     本函数在 UI 刚构建、**背包还没扫描**时运行，那时下拉的 Values 还是占位符
    --     `{"(等待选择品质…)"}`。此时 `dChar:SetValue({角色名})` ——
    --     库的 SetValues 发现"旧值不在新列表里" → 删值 + 触发 RunChanged →
    --     OnChanged 拿到**空表** → 把 cfg 清空。**自己把好数据抹了**（打点实测 载入=4 apply=0）。
    --   ❌ 坑 2（v285）：加了"快照 + 还原"来兜它。
    --     第一次还原有效（还原=4），但 1 秒后的那轮仍然 read=0 还原=0
    --     —— 因为那一刻 charItems 可能还没就绪，反复打补丁只会互相打架。
    --
    --   ✅ 最终：删掉上面两坨，这里保持**干净**。恢复交给对齐循环。
    local pickRestore = nil   -- 保留变量名避免下方引用报错；不再需要它
    -- 配置恢复顺序：我的 JSON -> SaveManager 自动配置（若已设置）
    -- 🔬 打点：记录每步的勾选条目数（排查"重启后勾选被清空"用；稳定后可删）
    local function pickN(tag)
        local n = 0
        for _, b in pairs((cfg.charPick and cfg.charPick.solar and cfg.charPick.solar.sel) or {}) do
            if type(b) == "table" then for _ in pairs(b) do n = n + 1 end end
        end
        R._pickDbg = (R._pickDbg or "") .. tag .. "=" .. n .. " "
    end
    R._pickDbg = ""
    pickN("载入")
    R.rarSnap("前apply")
    applyCfgToUI()
    pickN("apply")
    R.rarSnap("apply后")
    readUIIntoCfg()
    pickN("read")
    R.rarSnap("read后")
    if SaveManager then
        -- ⚠⚠ v331（用户拍板）：**不再自动恢复库的存档** —— 我们的 JSON 是唯一权威。
        --   为什么改（2026-10-11 实测 + 用户选择）：
        --     · 库那套（`HW_Mutator/settings/<名>.json` + `settings/autoload.txt`）只存
        --       **"有控件"的 88 条快照**；我们的 JSON 存 **127 个键**，其中 **62 个键库根本没有**
        --       （ast* 全部 17 个、charPick、candy*、fallMinY、各种内部计时器…）⇒ 它替代不了我们。
        --     · 但它在启动时**后写**（applyCfgToUI -> readUIIntoCfg -> 库恢复 -> readUIIntoCfg），
        --       所以它能**盖掉**我们的值 —— 实证：`solarEnabled` 被改成 true、
        --       `Solar 目标突变` 被恢复成过期的 "Angelic, Mars"（我们 JSON 里只有 Mars）。
        --       库的 Toggle 恢复器（SaveManager.lua L103-117）必然触发我们的 OnChanged。
        --     · 它是**全局一份、不分账号** —— 与"按账号用不同配置"直接冲突（大小号互相污染）。
        --   ⇒ 现在：**跳过自动恢复**。库的 Configuration 面板**保留**（你仍可在「配置」页
        --     手动 Create / Overwrite / Load 它自己的档位），只是它不再自动插手你的配置。
        --   ⚠ 想退回旧行为：把下面那行 `pcall(... LoadAutoloadConfig ...)` 取消注释即可。
        -- ⚠⚠ v336（用户拍板）：方向反过来了 —— **改用库自己的配置系统**。
        --   原来这里是"跳过库恢复、以我们的 JSON 为权威"（v331），现在改成
        --   "启动就用库的自动配置恢复"；我们的 JSON 不再自动读/写。
        --   用户改完设置请去「配置」页的 Configuration 面板 → Overwrite config。
        local an, aok = nil, false
        pcall(function() an, aok = SaveManager:GetAutoloadConfig() end)
        if aok and an then
            pcall(function() SaveManager:LoadAutoloadConfig() end)
            log("🔄 已用库自动配置 " .. tostring(an) .. " 恢复界面设置（v336 起配置由库管；"
                .. "改完设置去 Configuration 面板点 Overwrite config 保存）", Color3.fromRGB(160, 200, 255))
        else
            log("ℹ 库还没设自动配置：去「配置」页的 Configuration 面板 → Create config + Set as autoload",
                Color3.fromRGB(255, 200, 120))
        end
        -- 🛡🛡🛡 持有保护（v336，硬保险）：**强制**关闭「手持蓝框」。
        --   实测（2026-10-11，用户报"老 bug 复发：手持一会就重新手持"）：
        --     · 库的存档 `HW_Mutator/settings/1.json` 里存着 `nativeSelectionFrame: true`，
        --       而 v331 之前它**每次启动都被恢复** ⇒ §14.2 早已决定关掉的蓝框被反复打开；
        --     · 打开后渲染循环**每秒**重刷一次游戏客户端的"选中"状态（见 clientSetSelected），
        --       §14.2 实测过它的后果：3.6 秒内状态变化 7 次 + `R.hold.name = nil`；
        --       本次实测同期症状：`_relLog` 里"手持丢失"每 3.2 秒一条、日志每 3 秒重复"手持 X"。
        --   ⇒ 不管存档里是什么，恢复之后一律置 false。**别再让它有机会被打开。**
        if cfg.nativeSelectionFrame then
            cfg.nativeSelectionFrame = false
            log("⚠ 已强制关闭「手持蓝框」（存档里是开的）：实测它会破坏持有（角色反复消失又出现）；"
                .. "蓝框与突变无关，服务器只看 ToolFollowers", Color3.fromRGB(255, 200, 120))
        end
        pickN("SM")
        task.delay(1, function()
            readUIIntoCfg()
            pickN("延read")
            R.rarSnap("延read后")
            refreshCandidates()
            R.rarSnap("候选后")
            manageHotbar(true)
            R.rarSnap("结束")
        end)
        -- ⚠⚠ v337：**延迟再恢复一次库配置**（修"取消勾选还是回弹"的最后一环）。
        --   为什么需要（v336 实测）：
        --     库在 buildUI 里第一次恢复时，我们的「①号框」选择器（cf_*_rar / cf_*_char）
        --     **还没被创建** —— 它们要等背包/图鉴扫描完，由 charFilter 才建出来。
        --     库的 Dropdown 恢复器是 `if not Element then return end`（找不到就跳过），
        --     所以那一次恢复**根本没碰到品质/角色勾选**。
        --   实测证据：库存档里 `cf_halloween_rar = {Ancient, God}`，但 v336 启动后
        --     `cfg.rarities` 还是默认值 `{Ancient, Celestial}`（= Celestial 又冒出来、God 丢了）。
        --   ⇒ 10 秒后再恢复一次，这时选择器已在，用户的勾选才能真正回到 cfg。
        --   ⚠ 副作用：这 10 秒内你自己改的开关会被库里的存档值覆盖 —— 这是"以库为权威"的代价。
        task.delay(10, function()
            if not isCurrent() then return end
            local an2, aok2 = nil, false
            pcall(function() an2, aok2 = SaveManager:GetAutoloadConfig() end)
            if aok2 and an2 then
                local ok2 = pcall(function() SaveManager:LoadAutoloadConfig() end)
                if ok2 then
                    readUIIntoCfg()
                    R.rarSnap("二次恢复后")
                    -- ⚠⚠ v338：**必须重算候选池 + 重推快捷栏布局**。
                    --   实测（2026-10-11）：启动时 cfg 还是默认品质（含 Celestial），
                    --   候选池与快捷栏布局都是按那个建的；10 秒后二次恢复把品质改对了，
                    --   但候选池/布局**没有跟着重算** ⇒ 快捷栏里留着 5 个 Celestial
                    --   （Blayra / Flara Scarlette / Rami Scarlette / Nazira II / Madoki Kaneme）。
                    --   配合 v338 新增的"品质没勾选就移出"规则（computeTargetLayout），
                    --   这次重算会把它们真正踢出快捷栏。
                    refreshCandidates()
                    manageHotbar(true)
                    R.rarSnap("重算后")
                    log("🔄 已二次恢复库配置（等①号框建好后）：品质/角色勾选这类设置现在才真正生效，"
                        .. "并已按新勾选重算候选池与快捷栏", Color3.fromRGB(160, 200, 255))
                end
            end
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

--============================================================== 🚪 自动关弹窗 API
R.autoCloseOn = function(v)
    cfg.autoCloseEnabled = (v ~= false)
    if E.tAutoClose and E.tAutoClose.SetValue then pcall(function() E.tAutoClose:SetValue(cfg.autoCloseEnabled) end) end
    log("🚪 自动关弹窗 = " .. tostring(cfg.autoCloseEnabled))
    return cfg.autoCloseEnabled
end
R.autoClosePush = function() return R.autoCloseStatus and R.autoCloseStatus() or nil end

--============================================================== 🍖 喂食 API
R.feedStatus = function()
    local pv = feedPreviewList()
    local F = R.feed or {}
    return {
        enabled = cfg.feedEnabled, mode = cfg.feedMode, running = F.running == true,
        food = pv.food, threshold = pv.threshold, rate = pv.rate, keep = pv.keep,
        candidates = #pv.cands, planStands = #pv.plan, planActions = pv.planActions,
        planSpent = pv.planSpent, planGain = pv.planGain,
        minEfficiency = cfg.feedMinEfficiency, dryRun = cfg.feedDryRun,
        totalCps = pv.totalCps,
        batches = F.batches or 0, actions = F.actions or 0, spent = F.spent or 0,
        lastAt = F.lastAt, lastSummary = F.lastSummary, lastFail = F.lastFail,
        lastSeconds = F.lastSeconds, lastLeft = F.lastLeft, lastStop = F.lastStop,
        lastSkip = F.lastSkip, rateWindow = (R.feed and R.feed.measuredWindow) or nil,
        rateAttr = (R.feed and R.feed.perSecondAttr) or nil,
        levelsResynced = F.levelsResynced or 0, fireRetries = F.fireRetries or 0,
    }
end
R.feedPreview = function()
    feedCalibrate(true)
    local pv = feedPreviewList(true)
    local plan = pv.plan
    print(PREFIX .. string.format(" 🍖 可喂 %d 台 · %d 级 · 花费 %s · 全屋 CPS +%s",
        #plan, pv.planActions, fmtShort(pv.planSpent), fmtShort(pv.planGain)))
    for i, it in ipairs(plan) do
        if i > 15 then break end
        print(string.format("%s  %2d. %-6s %-14s [%-10s] L%d->%d  +%d级  花 %s  得 %s CPS  (%.4f)",
            PREFIX, i, it.label, it.name, it.rarity, it.from, it.to, it.levels,
            fmtShort(it.spent), fmtShort(it.gain), it.eff))
    end
    if R.renderFeedList then pcall(R.renderFeedList) end
    return (plan)
end
R.feedOn = function(v)
    cfg.feedEnabled = (v ~= false)
    if E.tFeed and E.tFeed.SetValue then pcall(function() E.tFeed:SetValue(cfg.feedEnabled) end) end
    log("🍖 自动喂食 = " .. tostring(cfg.feedEnabled))
    return cfg.feedEnabled
end
R.feedNow = function()
    local food = tonumber(LocalPlayer:GetAttribute("FoodNumber")) or 0
    if R.feed and R.feed.running then return false, "已有批次在执行" end
    feedCalibrate(true)
    task.spawn(function() pcall(feedExecute, food) end)
    return true
end
R.feedDry = function(v)
    cfg.feedDryRun = (v ~= false)
    if E.tFeedDry and E.tFeedDry.SetValue then pcall(function() E.tFeedDry:SetValue(cfg.feedDryRun) end) end
    log("🧪 喂食预览模式 = " .. tostring(cfg.feedDryRun))
    return cfg.feedDryRun
end
R.feedTable = function()
    local rows = {}
    for _, s in ipairs(feedStands()) do
        local snap = feedSnapshot(s.inst)
        snap.label = s.label
        snap.cost = snap.has and feedCost(snap.rarity, snap.level) or nil
        snap.gain = (snap.has and snap.cost) and feedGain(snap.cps, snap.level) or nil
        snap.eff = (snap.gain and snap.cost and snap.cost > 0) and (snap.gain / snap.cost) or 0
        rows[#rows + 1] = snap
    end
    table.sort(rows, function(a, b) return a.eff > b.eff end)
    return rows
end
R.feedStandsInfo = R.feedTable

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

--============================================================== 🧹 完全卸载（Hard Unload）
-- 用途：测试新版本前先彻底清场，不需要重进游戏。
-- 为什么需要它（实测踩过的坑）：
--   普通热重载只做 destroy()，而 destroy() 依赖"当前实例自己知道该断哪些东西"。
--   一旦脚本被反复重载、或某个实例 destroy 到一半就出错，就会留下：
--     · 还在跑的旧线程（主循环 / 观察线程 / 自动关窗线程 …）
--     · 还没断的连接（事件监听、槽位监听）
--     · 旧的状态表（R）—— 里面有旧版本的函数闭包
--     · 没摘掉的全局钩子（__namecall / 客户端插入函数包装）
--     · 堆在 CoreGui 里的旧 UI
--   这些残留会让"新版本"表现出一堆莫名其妙的错误（实测见过：
--   fishTick/feedTick 报 stack overflow、renderStatus 报 missing argument、
--   "清理历史孤儿实例: 11 个"）。本函数就是从根上把它们铲干净。
--
-- ⭐ 关键设计：**先自保**。第一步就把 _G.HW_MUTATOR 清空，
--    这样后面靠魔数扫描找残留时就不会把自己也一起干掉（否则扫到自己就提前死了）。

local UNLOAD_MAGIC = "hw_mutator.by.wdf.place.74729868188364"

local function hwUnload()
    pcall(function() if R.plFlush then R.plFlush() end end)   -- 📝 退出前落盘，避免丢最后几条
    local report = { stateTables = 0, selfDestroyed = false, connections = 0,
                     threads = 0, gui = 0, hooks = 0, errors = 0 }
    local me = _G.HW_MUTATOR

    -- ① 先自保：把全局引用摘掉（后续魔数扫描就扫不到自己了）
    _G.HW_MUTATOR = nil

    -- ② 尽量礼貌地停掉自己（能停多少算多少，失败也无所谓，下面还有暴力清理）
    if me then
        pcall(function() me.alive = false end)
        pcall(function() me.gen = (me.gen or 0) + 1 end)
        if type(me.destroy) == "function" then
            local ok = pcall(me.destroy)
            report.selfDestroyed = ok
            if not ok then report.errors = report.errors + 1 end
        end
    end
    if type(getgc) ~= "function" then
        return report      -- 没有 getgc 就只能做到这一步
    end

    -- ③ 从 GC 里找出所有"我们的"状态表（带专属魔数），逐个停掉
    local okgc, list = pcall(getgc, true)
    if okgc and type(list) == "table" then
        for _, obj in ipairs(list) do
            if type(obj) == "table" then
                local isOurs = false
                pcall(function() isOurs = rawget(obj, "__HW_MAGIC") == UNLOAD_MAGIC end)
                if isOurs then
                    pcall(function() obj.alive = false end)
                    pcall(function() obj.gen = (obj.gen or 0) + 1 end)
                    if type(rawget(obj, "destroy")) == "function" then
                        local ok = pcall(rawget(obj, "destroy"))
                        if not ok then report.errors = report.errors + 1 end
                    end
                    -- 顺手把它的连接/线程登记表也断开（destroy 失败时的兜底）
                    local conns = rawget(obj, "connections")
                    if type(conns) == "table" then
                        for _, c in ipairs(conns) do
                            if type(c) == "table" and type(c.Disconnect) == "function" then
                                if pcall(function() c:Disconnect() end) then
                                    report.connections = report.connections + 1
                                end
                            end
                        end
                        pcall(function() obj.connections = {} end)
                    end
                    local ths = rawget(obj, "threads")
                    if type(ths) == "table" then
                        for _, th in ipairs(ths) do
                            if type(th) == "thread" and coroutine.status(th) ~= "dead" then
                                if pcall(task.cancel, th) then report.threads = report.threads + 1 end
                            end
                        end
                        pcall(function() obj.threads = {} end)
                    end
                    report.stateTables = report.stateTables + 1
                end
            end
        end

        -- ④ 暴力兜底：把所有【还在跑的】我们创建的线程停掉。
        --    识别依据：线程的创建脚本就是本脚本所在的 chunk（getfenv 里的 script 相同），
        --    且线程名/来源不可辨时，用"线程函数里引用了我们的魔数"来判定。
        --    这里采用更保守但有效的做法：凡是 getfenv(t).__HW_MAGIC == 魔数 的线程都停。
        if type(getfenv) == "function" then
            for _, obj in ipairs(list) do
                if type(obj) == "thread" and coroutine.status(obj) ~= "dead" then
                    local env = nil
                    pcall(function() env = getfenv(obj) end)
                    if type(env) == "table" then
                        local ours = false
                        pcall(function() ours = rawget(env, "__HW_MAGIC") == UNLOAD_MAGIC end)
                        if ours then
                            if pcall(task.cancel, obj) then report.threads = report.threads + 1 end
                        end
                    end
                end
            end
        end

        -- ⑤ 摘掉我们可能装过的全局钩子
        if type(_G.__HW_NC_ORIG) == "function" and type(hookmetamethod) == "function" then
            if pcall(function() hookmetamethod(game, "__namecall", _G.__HW_NC_ORIG) end) then
                report.hooks = report.hooks + 1
            end
        end
        _G.__HW_NC_HOOK, _G.__HW_NC_ORIG = nil, nil
        _G.__METEOR_WATCH = false
        _G.__MW_GEN = (_G.__MW_GEN or 0) + 1
        pcall(function() if _G.__MW_CONN then _G.__MW_CONN:Disconnect() end end)
        _G.__MW_CONN = nil
        _G.__HW_CALLS = nil
    end

    -- ⑥ 删掉我们标记过的 UI（只删带标记的，绝不碰别人的 hub）
    local function containers()
        local t = {}
        pcall(function() if gethui then t[#t + 1] = gethui() end end)
        pcall(function() t[#t + 1] = game:GetService("CoreGui") end)
        local lp = game:GetService("Players").LocalPlayer
        local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
        if pg then t[#t + 1] = pg end
        return t
    end
    for _, cont in ipairs(containers()) do
        for _, c in ipairs(cont:GetChildren()) do
            local marked = false
            pcall(function() marked = c:IsA("ScreenGui") and c:GetAttribute("HW_MutatorOwned") ~= nil end)
            if marked then
                if pcall(function() c:Destroy() end) then report.gui = report.gui + 1 end
            end
        end
    end

    -- ⑦ 清掉其它本脚本用过的全局缓存（下次加载会重建）
    _G.__HW_CLIENT_G = nil
    _G.__BP_SavedLayoutApplied = nil
    _G.__BP_UserInserted = nil
    _G.HW_MUTATOR = nil

    return report
end
R.hwUnload = hwUnload
R.hardUnload = hwUnload

-- 对外 API：一键完全卸载
R.unload = function()
    local r = R.hwUnload()
    print(PREFIX .. string.format(" 🧹 完全卸载完成：状态表 %d · 连接 %d · 线程 %d · UI %d · 钩子 %d%s",
        r.stateTables, r.connections, r.threads, r.gui, r.hooks,
        r.errors > 0 and ("（其中 " .. r.errors .. " 个 destroy 出错，已兜底清理）") or ""))
    return r
end

--============================================================== 启动
killOrphans()
-- 📝 初始化持久日志（建文件 + 写会话分隔行）
pcall(function() if R.plInit then R.plInit() end end)
-- ⚠⚠ 这里故意用 IIFE 而不是裸 do 块：
--   主块的 register 已经贴近上限（200），而**主块里的 local 会占主块 register**，
--   连 `local ok, err` 这两个都会让编译器报
--     "Out of local registers when trying to allocate ok: exceeded limit 200"
--   （实测踩到：整个脚本直接加载失败）。
--   放进独立函数作用域后，这两个变量用函数自己的 register，主块零开销。
;(function()
    -- ⚠⚠ v333：把 pcall 换成 xpcall + traceback。
    --   为什么（2026-10-11 实测踩到）：uiError 里只有一句
    --     "The current thread cannot access 'Instance' (lacking capability Plugin)"
    --   —— **没有行号、没有调用链**，完全不知道是谁抛的：我把 R 上导出的
    --   renderStatus/renderLog/acctAct/… 逐个单独调用都是 ok，等于白查一轮。
    --   ⇒ 现在完整栈存进 `R.uiErrorTrace`（面板仍旧只显示第一行，不破坏界面）。
    local ok, err = xpcall(buildUI, function(e)
        return tostring(e) .. "\n" .. tostring(debug.traceback("UI 构建栈：", 2))
    end)
    if not ok then
        R.uiError = tostring(err):match("^[^\n]*")     -- 面板只显示第一行
        R.uiErrorTrace = tostring(err)                 -- 完整栈留给排查
        warn(PREFIX .. " UI 构建失败: " .. tostring(err))
    end
end)()

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
    local lastWash = 0
    local lastFeed = 0
    local lastMgr = 0
    local lastAstAuto = 0
    while isCurrent() do
        -- ★ v160：界面线程也参与速率采样，但必须**限频** —— foodRateSample 内部要遍历
        --   花园的 Purchases 逐个读 CurrentFoodPerSecond，5Hz 无脑调用纯属浪费。
        --   0.5 秒一次足够让"速率 / 攒够还要几分钟"跟得上，开销只有原来的 1/2.5。
        local _rc = os.clock()
        if (_rc - (R._rateTickAt or 0)) >= 0.5 then
            R._rateTickAt = _rc
            pcall(R.foodRateSample)
        end
        if R.renderStatus then pcall(R.renderStatus) end
        -- 去突变预览列表：每 2 秒自动刷新（背包一变就能看到）
        local now = os.clock()
        if cfg.washAutoPreview ~= false and R.renderWashList and (now - lastWash) >= 2 then
            lastWash = now
            if (not R._lastSummaryAt) or (now - R._lastSummaryAt >= 1) then pcall(refreshCandidates) end
            pcall(R.renderWashList)
        end
        -- 🎩 总经理：每 3 秒评估食物盈余，必要时自动调门槛
        if (now - (lastMgr or 0)) >= 3 then
            lastMgr = now
            pcall(managerTick)
            if R.renderMgr then pcall(R.renderMgr) end
        end
        -- 🍖 喂食分配清单：每 3 秒自动刷新
        if cfg.feedAutoPreview ~= false and R.renderFeedList and (now - lastFeed) >= 3
            and (R.feedPreviewShown or cfg.feedEnabled) then
            lastFeed = now
            pcall(R.renderFeedList)
        end
        -- 📝 持久日志刷盘：**放在这个后台线程里定时做**（约 5 秒一次）
        --   绝不在 log() 里直接写文件 —— 日志可能很密集（整理/让路/事件 Tick），
        --   阻塞主线程会导致**游戏卡死重启**（实测踩到）。
        if (now - (R._plLastFlush or 0)) >= (tonumber(cfg.logFlushSeconds) or 10) then
            R._plLastFlush = now
            pcall(plFlush)
        end
        task.wait(0.2)
    end
end)

-- 🚪 自动关弹窗线程：独立 0.4 秒轮询（比主循环快，重进游戏时能第一时间抓到弹窗）
R.threads[#R.threads + 1] = task.spawn(function()
    while isCurrent() do
        pcall(autoCloseTick)
        task.wait(0.4)
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
