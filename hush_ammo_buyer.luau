--[[
    HUSH 弹药自动购买 v4  (Potassium / autoexec)
    ─────────────────────────────────────────────
    用途
      · 放在 autoexec，进大厅后自动就绪
      · 自动点掉过场 SKIP、自动关闭 SALE 广告（只点 LATER，绝不点 VIEW SALE）
      · 每个弹种单独设目标发数；勾选后自动在 Gunner 处买满
      · 配置自动存盘，重进游戏自动恢复

    v4 变更（购买流程按口径分组重构）
      · 以「口径」为单位：切到某口径就把它下面所有勾选且有货的弹种买空，才进下一个口径
      · 买空的口径记入 dryCal，本轮不再切进去，避免反复切页空转（原来是每个 tick 把 8 个口径轮一遍）
      · 只扫「有勾选目标」的口径；未勾选的口径完全不碰，UI 不再频繁闪烁
      · 以补货倒计时为主：全部买空后一直等，只在倒计时剩 ≤2 秒时才重扫
      · 售空识别：卡片 Label 为 "SOLD OUT" 即标记，UI 显示「售罄」，不再重试
      · 配置升级为三列（口径 + 商品名 + 目标），即使该弹种当前不在售也能定位到口径
      · 有目标但当前不在售的弹种保持可见并标「未在售」，不会从 UI 上消失
      · 重载时自动停掉旧实例，避免两个循环同时下单

    实测依据（place 91445552037955 / Menu，Potassium v2.7.0）
      · 大厅不跑反作弊检测：AcRules 92 条里无 market/shop/trade/buy 规则；
        唯一相关是 remote.rate = 300 次 / 10 秒（w=2），UI 点击远低于此
      · 购买实现（MenuTraders buyNow）：
          op({ op="buy", trader=<id>, offer=<key>, count=clamp(1,50) })
        count 是「包数」不是发数；没有二次确认；同一 offer 有 4 秒客户端冷却
      · 口径筛选芯片：FilterBox.Calibres.F_cal_{12ga,308,9mm,45,357,556,762,bolt}
      · 商品卡片 Label 三种形态：
          "3 / 3 LEFT"  = 还有 3 件
          "SOLD OUT"    = 售空（价格仍显示，不能靠价格判断）
      · 详情面板：Detail.Panel.Content.Foot → Qty（属性 Qty / QtyMax）/ BuyButton
      · 补货：Body.Toolbar.Restock 文本形如 "Restock in 12:44" / "在09:12时间内重新补货"

    注意
      · 阈值按「本次已购买发数」累计，不是库存总量（游戏没暴露简单库存接口）
      · 最后一包可能超出目标：目标是「至少买够」
]]

local Players = game:GetService("Players")
local lp = Players.LocalPlayer

-- autoexec 场景下 LocalPlayer 可能还没就绪，后面所有函数都捕获这个变量
do
    local guard = 0
    while not lp and guard < 300 do
        task.wait(0.1)
        lp = Players.LocalPlayer
        guard = guard + 1
    end
end
if not lp then
    warn("[AMMO] LocalPlayer 未就绪，放弃加载")
    return
end

------------------------------------------------------------------
-- 旧实例清理：不清理会导致两个主循环同时下单
------------------------------------------------------------------
local prev = _G.HUSH_AMMO
if type(prev) == "table" then
    pcall(function() if prev.state then prev.state.running = false end end)
    pcall(function() if type(prev.dispose) == "function" then prev.dispose() end end)
end

------------------------------------------------------------------
-- 配置
------------------------------------------------------------------
local CONFIG_FILE = "hush_ammo_config.txt"
local BOUGHT_FILE = "hush_ammo_bought.txt"
local CARDS_FILE = "hush_ammo_cards.txt"   -- 已买数量，重连/重载后不丢
local LIB_FILE = "obsidian_Library.lua"

local CFG = {
    targets = {},          -- [商品名] = 目标发数；0 或 nil = 不买
    buyGap = 4.25,         -- 同一 offer 冷却 4s，留点余量
    chipWait = 0.35,       -- 切口径后等列表重建
    selectWait = 0.4,      -- 选中商品后等详情刷新
    tickGap = 0.35,
    restockPoll = 1.0,     -- 补货倒计时读取间隔
    rescanLead = 2,        -- 补货倒计时剩这么多秒时重扫
    fallbackRescan = 30,   -- 读不到倒计时时的兜底重扫间隔
    autoStart = false,     -- 加载后是否自动开始
}

local CALIBERS = {
    { id = "12ga", chip = "F_cal_12ga", label = "12GA" },
    { id = "308",  chip = "F_cal_308",  label = ".308" },
    { id = "9mm",  chip = "F_cal_9mm",  label = "9MM" },
    { id = "45",   chip = "F_cal_45",   label = ".45" },
    { id = "357",  chip = "F_cal_357",  label = ".357" },
    { id = "556",  chip = "F_cal_556",  label = "5.56" },
    { id = "762",  chip = "F_cal_762",  label = "7.62" },
    { id = "bolt", chip = "F_cal_bolt", label = "BOLT" },
}

------------------------------------------------------------------
-- 状态
------------------------------------------------------------------
local S = {
    running = false,
    dead = false,
    bought = 0,            -- 本次累计发数（所有弹种求和）
    spent = 0,
    boughtBy = {},         -- [商品名] = 已买发数（持久化）
    spentBy = {},          -- [商品名] = 已花金额（持久化）
    boughtDirty = false,   -- 有待落盘的已买记录
    products = {},         -- [calId] = { {name, short, key, count, price, stock, perRound, soldOut} }
    nameToCal = {},        -- [商品名] = calId，配置里保留，弹种下架后也能定位口径
    currentCal = nil,      -- 当前正在处理的口径
    dryCal = {},           -- [calId] = true 本轮已确认买空
    softFail = {},         -- [calId] = 连续未成交轮数
    lastBuyAt = {},        -- [offerKey] = os.clock()
    scanning = false,
    scanStartAt = 0,
    ready = false,
    lastMsg = "空闲",
    lastBuyErr = "",       -- 最近一次买失败的原因，便于诊断
    waitingRestock = false,
    restockText = "",
    restockSec = nil,
    restockAt = nil,
    nextRescanAt = 0,
    needRescan = false,
    lastNavAt = 0,         -- 上次尝试自动进入购买页的时间
    lastDismissAt = 0,     -- 上次扫描弹窗的时间
    ammoTried = false,     -- AMMO 分类整个 session 只点一次
    savePending = false,
    lastSaveAt = 0,
    loadedFromFile = false,
}

-- UI 句柄（提前声明：scanAll 完成后要通过 P.onScan 追建产品行）
local P = {
    library = nil,
    window = nil,
    rows = {},             -- [商品名] = { toggle, input, calId }
    groups = {},           -- [calId] = groupbox
    lblState = nil,
    lblRestock = nil,
    lblBought = nil,
    lblSpent = nil,
    lblConfig = nil,
    lblCal = nil,
    sumLabels = {},        -- [calId] = label
    toggleRun = nil,
    onScan = nil,
}

------------------------------------------------------------------
-- 工具
------------------------------------------------------------------
local function get(o, k)
    local v
    if o then pcall(function() v = o[k] end) end
    return v
end

local function textOf(o)
    local v
    if o then pcall(function() v = o.Text end) end
    return type(v) == "string" and v or ""
end

local function log(s)
    S.lastMsg = tostring(s)
    print("[AMMO] " .. tostring(s))
end

local function num(s)
    if type(s) ~= "string" then return nil end
    local d = s:gsub("[^%d%.]", "")
    return tonumber(d)
end

local function fmtTime(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    local m = math.floor(sec / 60)
    local s = sec % 60
    if m >= 60 then
        return string.format("%d:%02d:%02d", math.floor(m / 60), m % 60, s)
    end
    return string.format("%02d:%02d", m, s)
end

local function money(v)
    v = math.floor(tonumber(v) or 0)
    local out = tostring(v):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    out = out:gsub("^,", "")
    return "$" .. out
end

-- djb2：产品名含中文时不能用 [^%w]，否则全被替换成下划线导致 ID 撞车
local function hashId(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%x", h)
end

local function safeId(prefix, s)
    return prefix .. "_" .. hashId(tostring(s))
end

local function click(btn)
    if not btn then return false end
    if pcall(firesignal, btn.Activated) then return true end
    local ok, conns = pcall(getconnections, btn.Activated)
    if not ok then return false end
    for _, c in ipairs(conns) do pcall(function() c.Function(btn) end) end
    return true
end

-- 游戏 UI 的文案全部带字距动画（"S K I P" / "T R A D E R S"），
-- 直接比对永远不相等，必须先去掉所有非字母数字字符
local function normText(s)
    return (tostring(s or ""):upper():gsub("[^%w]", ""))
end

local function findClickable(want, root)
    local w = normText(want)
    if not root then return nil end
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("GuiButton") then
            if normText(textOf(d)) == w then return d end
            for _, c in ipairs(d:GetDescendants()) do
                if c:IsA("TextLabel") and normText(textOf(c)) == w then return d end
            end
        elseif d:IsA("TextLabel") and normText(textOf(d)) == w then
            -- 有些入口本身就是 TextLabel（例如开场动画的 Skip）
            local anc = d.Parent
            for _ = 1, 3 do
                if not anc then break end
                if anc:IsA("GuiButton") then return anc end
                anc = anc.Parent
            end
            return d
        end
    end
    return nil
end

local function clickByText(root, wantText)
    local t = findClickable(wantText, root)
    if not t then return false, nil end
    if t:IsA("GuiButton") then
        return click(t), t
    end
    return false, t      -- 纯 TextLabel，交给调用方处理
end

-- 商品名推断口径：AMMO 分类点不动时的兜底（ALL 列表里也能归类）
local CAL_PATTERNS = {
    { "^12ga", "12ga" }, { "^%.308", "308" },
    { "^9x19", "9mm" }, { "^9mm", "9mm" },
    { "^%.45", "45" }, { "^%.357", "357" },
    { "^5%.56", "556" }, { "^7%.62", "762" }, { "^bolt", "bolt" },
}

local function inferCal(name)
    local l = string.lower(tostring(name or ""))
    for _, e in ipairs(CAL_PATTERNS) do
        if string.find(l, e[1]) then return e[2] end
    end
    return nil
end


------------------------------------------------------------------
-- 口径归属
------------------------------------------------------------------
local function calLabel(calId)
    for _, c in ipairs(CALIBERS) do
        if c.id == calId then return c.label end
    end
    return tostring(calId)
end

-- 商品属于哪个口径：UI 行 → 扫描记录 → nil
local function nameCal(name)
    local row = P.rows[name]
    if row and row.calId then return row.calId end
    return S.nameToCal[name]
end

-- 某弹种还差多少发（caliberHasPending 会用到，必须放在它之前）
local function remainOf(name)
    local target = tonumber(CFG.targets[name]) or 0
    if target <= 0 then return 0 end
    return target - (S.boughtBy[name] or 0)
end

------------------------------------------------------------------
-- 配置持久化
------------------------------------------------------------------
-- 三列格式：口径<TAB>商品名<TAB>目标发数；旧的两列格式仍可读
local function saveConfig()
    local lines = { "# HUSH 弹药采购配置  " .. os.date("%Y-%m-%d %H:%M") }
    local rowsOut = {}
    for name, n in pairs(CFG.targets) do
        if (tonumber(n) or 0) > 0 then
            rowsOut[#rowsOut + 1] = {
                cal = nameCal(name) or "?",
                name = name,
                n = math.floor(tonumber(n) or 0),
            }
        end
    end
    table.sort(rowsOut, function(a, b)
        if a.cal ~= b.cal then return a.cal < b.cal end
        return a.name < b.name
    end)
    for _, r in ipairs(rowsOut) do
        lines[#lines + 1] = string.format("%s\t%s\t%d", r.cal, r.name, r.n)
    end
    local ok, err = pcall(writefile, CONFIG_FILE, table.concat(lines, "\n"))
    if ok then
        S.lastSaveAt = os.clock()
        S.savePending = false
        return true
    end
    log("配置保存失败：" .. tostring(err))
    return false
end

local function loadConfig()
    if not (isfile and isfile(CONFIG_FILE)) then return false, 0 end
    local ok, data = pcall(readfile, CONFIG_FILE)
    if not ok or type(data) ~= "string" then return false, 0 end
    local n = 0
    -- 注意：Luau 的 pattern 不支持 %t（Lua 5.2 才有），必须用 \t 字面量
    for line in data:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local cal, name, val = line:match("^([^\t]+)\t(.-)\t(%d+)$")
            if not cal then
                name, val = line:match("^([^\t]+)\t(%d+)$")
            end
            if name and name ~= "" and val then
                CFG.targets[name] = tonumber(val)
                if cal and cal ~= "?" then S.nameToCal[name] = cal end
                n = n + 1
            end
        end
    end
    S.loadedFromFile = (n > 0)
    return n > 0, n
end

local function queueSave()
    S.savePending = true
end

------------------------------------------------------------------
-- 已买数量持久化
-- 这一份是「跨重连」的账本：不看它的话，每次重进游戏都会把 1000 发重新买一遍
------------------------------------------------------------------
local function recomputeTotals()
    local b, s = 0, 0
    for _, v in pairs(S.boughtBy) do b = b + (tonumber(v) or 0) end
    for _, v in pairs(S.spentBy) do s = s + (tonumber(v) or 0) end
    S.bought = b
    S.spent = s
end

-- 格式：口径<TAB>商品名<TAB>已买发数<TAB>已花金额
local function saveBought()
    local lines = { "# HUSH 已购买记录  " .. os.date("%Y-%m-%d %H:%M") }
    local rows = {}
    for name, n in pairs(S.boughtBy) do
        n = tonumber(n) or 0
        if n > 0 then
            rows[#rows + 1] = {
                cal = nameCal(name) or "?",
                name = name,
                n = math.floor(n),
                spent = math.floor(tonumber(S.spentBy[name]) or 0),
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.cal ~= b.cal then return a.cal < b.cal end
        return a.name < b.name
    end)
    for _, r in ipairs(rows) do
        lines[#lines + 1] = string.format("%s\t%s\t%d\t%d", r.cal, r.name, r.n, r.spent)
    end
    local ok = pcall(writefile, BOUGHT_FILE, table.concat(lines, "\n"))
    if ok then S.boughtDirty = false end
    return ok
end

local function loadBought()
    if not (isfile and isfile(BOUGHT_FILE)) then return 0 end
    local ok, data = pcall(readfile, BOUGHT_FILE)
    if not ok or type(data) ~= "string" then return 0 end
    local n = 0
    -- 兼容只有三列（没有金额）的旧记录
    for line in data:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local cal, name, cnt, spent = line:match("^([^\t]+)\t(.-)\t(%d+)\t(%d+)$")
            if not cal then
                name, cnt, spent = line:match("^([^\t]+)\t(%d+)\t(%d+)$")
                if not name then
                    name, cnt = line:match("^([^\t]+)\t(%d+)$")
                end
            end
            if name and name ~= "" and cnt then
                S.boughtBy[name] = (S.boughtBy[name] or 0) + tonumber(cnt)
                if spent then
                    S.spentBy[name] = (S.spentBy[name] or 0) + tonumber(spent)
                end
                if cal and cal ~= "?" and not S.nameToCal[name] then
                    S.nameToCal[name] = cal
                end
                n = n + 1
            end
        end
    end
    recomputeTotals()
    return n
end

------------------------------------------------------------------
-- 定位菜单
------------------------------------------------------------------
local function menuRoot()
    local pg = lp:FindFirstChild("PlayerGui")
    local hm = pg and pg:FindFirstChild("HushMenu")
    return hm and hm:FindFirstChild("Root")
end

local function tradersBody()
    local root = menuRoot()
    local pages = root and root:FindFirstChild("Pages")
    local pt = pages and pages:FindFirstChild("Page_traders")
    local c = pt and pt:FindFirstChild("Traders")
    c = c and c:FindFirstChild("Content")
    local right = c and c:FindFirstChild("Right")
    return right and right:FindFirstChild("Body"), right
end

local function isLobby()
    local place = lp:GetAttribute("Place")
    return place == "Menu" or place == "Hideout"
end

------------------------------------------------------------------
-- 自动进入 Gunner 购买页
-- 关键：只有 Page_traders 的内容已经存在时才切页。
-- 内容还没生成就硬点 tab，会把页面变成永久空壳（实测踩过，只能重进恢复）
------------------------------------------------------------------
------------------------------------------------------------------
-- 切到 AMMO 分类：口径芯片 Calibres 只有选中 AMMO 后才会被创建
------------------------------------------------------------------
local function ensureAmmoTab(body)
    if not body then return false end
    local fb = body:FindFirstChild("FilterBox")
    if not fb then return false end
    if fb:FindFirstChild("Calibres") then return true end

    -- 这个按钮点不动（Activated / 模拟鼠标都试过，On 一直是 false），
    -- 而且反复点会让筛选栏反复重建，所以整个 session 只试一次
    if S.ammoTried then return false end
    S.ammoTried = true

    local filters = fb:FindFirstChild("Filters")
    if not filters then return false end
    local btn = filters:FindFirstChild("F_ammo") or findClickable("AMMO", filters)
    if btn and btn:IsA("GuiButton") then
        click(btn)
        local deadline = os.clock() + 2
        while os.clock() < deadline do
            if fb:FindFirstChild("Calibres") then return true end
            task.wait(0.1)
        end
    end
    return fb:FindFirstChild("Calibres") ~= nil
end

-- 当前商店是不是弹药（GUNNER）。DOC 的店卖医疗品，两者共用同一个 Body 结构，
-- 所以不能靠 tradersBody() 判断是否已就位
local function shopLooksAmmo(body)
    if not body then return false end
    local checked = 0
    for _, o in ipairs(body.Offers:GetChildren()) do
        if o:IsA("TextButton") then
            checked = checked + 1
            for _, d in ipairs(o:GetDescendants()) do
                if d:IsA("TextLabel") and string.lower(d.Name) == "name" then
                    local tx = d.Text or ""
                    -- 卡片里可能有多个 name 标签，空的不能当结论
                    if tx ~= "" and inferCal(tx) then return true end
                end
            end
            if checked >= 8 then break end
        end
    end
    return false
end

--============ 后台构建 traders 页 ============
-- 不走鼠标、不依赖窗口焦点：通过 Menu 内部的 pageFor/api 直接 new 出交易页
-- 适用：重进游戏后页面不存在 / 只存在空壳（desc=0）
local function findTradersBuilder()
    local root = menuRoot()
    local tabs = root and root:FindFirstChild("TopBar") and root.TopBar:FindFirstChild("Tabs")
    local tab = tabs and tabs:FindFirstChild("Tab_traders")
    if not tab then return nil end
    local ok, conns = pcall(getconnections, tab.Activated)
    if not ok or type(conns) ~= "table" or not conns[1] then return nil end
    local ok2, uv1 = pcall(function() return debug.getupvalues(conns[1].Function)[1] end)
    if not ok2 or type(uv1) ~= "table" or type(uv1.setTab) ~= "function" then return nil end
    local uvs = debug.getupvalues(uv1.setTab)
    local pageFor, cache
    for _, v in ipairs(uvs) do
        if type(v) == "function" then
            local ok3, inner = pcall(debug.getupvalues, v)
            if ok3 then
                for _, w in ipairs(inner) do
                    if type(w) == "table" and type(w["play"]) == "table" and w["play"].frame ~= nil then
                        pageFor, cache = v, w
                        break
                    end
                end
            end
        end
        if pageFor then break end
    end
    if not pageFor then return nil end
    local api
    local ok4, pfUvs = pcall(debug.getupvalues, pageFor)
    if ok4 then
        for _, w in ipairs(pfUvs) do
            if type(w) == "table" and type(w.back) == "function" and type(w.openStore) == "function" then
                api = w
                break
            end
        end
    end
    return { pageFor = pageFor, api = api, cache = cache }
end

local function buildTradersPage()
    local b = findTradersBuilder()
    if not b or not b.api then
        return false, "找不到菜单构建器（MenuTraders/api）"
    end
    local root = menuRoot()
    local pages = root and root:FindFirstChild("Pages")
    if not pages then return false, "无 Pages" end

    for _, p in ipairs(pages:GetChildren()) do
        if p.Name == "Page_traders" then pcall(function() p:Destroy() end) end
    end
    if b.cache then b.cache["traders"] = nil end

    local hc = lp.PlayerScripts:FindFirstChild("HushClient")
    local lib = hc and hc:FindFirstChild("Lib")
    local mt = lib and lib:FindFirstChild("MenuTraders")
    if not mt then return false, "无 MenuTraders" end
    local okReq, MT = pcall(require, mt)
    if not okReq or type(MT) ~= "table" or type(MT.new) ~= "function" then
        return false, "MenuTraders 加载失败"
    end

    local frame = Instance.new("Frame")
    frame.Name = "Page_traders"
    frame.Size = UDim2.fromScale(1, 1)
    frame.BackgroundTransparency = 1
    frame.Visible = true
    frame.Parent = pages

    local okNew, tabObj = pcall(MT.new, b.api, frame)
    if not okNew or type(tabObj) ~= "table" then
        pcall(function() frame:Destroy() end)
        return false, "构建失败: " .. tostring(tabObj)
    end

    pcall(function() if tabObj.show then tabObj.show() end end)
    pcall(function() if tabObj.showSub then tabObj.showSub("buy") end end)
    task.wait(0.25)
    pcall(function() if tabObj.gotoCard then tabObj.gotoCard("gunner") end end)
    pcall(function() if tabObj.draw then tabObj.draw() end end)
    task.wait(0.45)

    S.pageTab = tabObj
    S.pageFrame = frame
    return true, "已构建 traders 页"
end

local function ensureBuyPage()
    local root = menuRoot()
    local pages = root and root:FindFirstChild("Pages")
    local pt = pages and pages:FindFirstChild("Page_traders")

    if not root then return false, "菜单未打开" end

    -- 页面不存在或只有空壳：直接后台构建（不需要鼠标/焦点）
    if not pt or #pt:GetDescendants() < 40 then
        local okb, whyb = buildTradersPage()
        task.wait(0.4)
        pt = pages and pages:FindFirstChild("Page_traders")
        local body2 = tradersBody()
        if body2 then
            ensureAmmoTab(body2)
            return true, "已构建 Gunner 页（后台）"
        end
        if not okb then
            return false, "构建失败: " .. tostring(whyb)
        end
        return false, "构建后仍未找到交易面板"
    end

    -- 1) 切到交易页（内容已存在才点，安全）
    if not pt.Visible then
        local top = root:FindFirstChild("TopBar")
        local tab = findClickable("TRADERS", top)
        if tab and tab:IsA("GuiButton") then
            click(tab)
            task.wait(0.45)
        end
    end

    -- 2) 默认选中的是 DOC，每次进来都点一次 gunner（幂等，实测安全）
    local tr = pt:FindFirstChild("Traders")
    local content = tr and tr:FindFirstChild("Content")
    local left = content and content:FindFirstChild("Left")
    if left then
        local gunner = left:FindFirstChild("gunner") or findClickable("GUNNER", left)
        if gunner and gunner:IsA("GuiButton") then
            click(gunner)
            task.wait(0.7)
        end
    end

    local body = tradersBody()
    if body then
        ensureAmmoTab(body)
        return true, "已进入 Gunner"
    end
    return false, "未找到交易面板"
end

------------------------------------------------------------------
-- 自动关弹窗：SKIP / LATER
------------------------------------------------------------------
-- 开场动画（ReplicatedFirst.JoinIntro）的 Skip 是个纯 TextLabel，
-- 没有按钮可 firesignal，只能模拟鼠标点击它的中心
local function mouseClickAt(guiObj)
    if type(mousemoveabs) ~= "function" or type(mouse1click) ~= "function" then return false end
    local pos = guiObj.AbsolutePosition
    local size = guiObj.AbsoluteSize
    if size.X <= 0 or size.Y <= 0 then return false end
    local x = math.floor(pos.X + size.X / 2)
    local y = math.floor(pos.Y + size.Y / 2)
    pcall(mousemoveabs, x, y)
    task.wait(0.05)
    pcall(mouse1click)
    return true
end

local function autoDismiss()
    local pg = lp:FindFirstChild("PlayerGui")
    if not pg then return end

    -- 一秒一次就够，别每 tick 全量扫 GUI
    local now = os.clock()
    if now - (S.lastDismissAt or 0) < 1 then return end
    S.lastDismissAt = now

    -- 1) 过场 / 开场动画的 SKIP
    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("ScreenGui") and g.Enabled and g.Name ~= "HushMenu" then
            local skip = findClickable("SKIP", g)
            if skip then
                if skip:IsA("GuiButton") then
                    click(skip)
                    log("已点 SKIP（" .. g.Name .. "）")
                elseif mouseClickAt(skip) then
                    log("已模拟点击 SKIP（" .. g.Name .. "）")
                end
                return
            end
        end
    end

    -- 2) 礼包 / 广告弹窗：只关掉，绝不点购买类按钮
    local modal = pg:FindFirstChild("HushModal")
    if modal then
        for _, want in ipairs({ "LATER", "NOTHANKS", "CLOSE", "DISMISS" }) do
            local b = findClickable(want, modal)
            if b and b:IsA("GuiButton") then
                click(b)
                log("已关闭弹窗（" .. want .. "）")
                return
            end
        end
    end
end

------------------------------------------------------------------
-- 补货倒计时
------------------------------------------------------------------
local function readRestock()
    local body = tradersBody()
    if not body then return "", nil end
    local tb = body:FindFirstChild("Toolbar")
    local rf = tb and tb:FindFirstChild("Restock")
    local lbl = rf and rf:FindFirstChild("Text")
    local txt = textOf(lbl)
    if txt == "" then return "", nil end
    local m, sec = txt:match("(%d+):(%d+)")
    local seconds = m and (tonumber(m) * 60 + tonumber(sec)) or nil
    return txt, seconds
end

-- 本地插值：暂停或读不到面板时也不会冻在旧数字
local function restockRemain()
    if not S.restockSec or not S.restockAt then return nil end
    if os.clock() - S.restockAt > 3 then return nil end
    return math.max(0, S.restockSec - (os.clock() - S.restockAt))
end

task.spawn(function()
    while not S.dead do
        local ok, txt, sec = pcall(readRestock)
        if ok and type(txt) == "string" and txt ~= "" then
            S.restockText = txt
            S.restockSec = sec
            S.restockAt = os.clock()
        end
        task.wait(CFG.restockPoll)
    end
end)

------------------------------------------------------------------
-- 扫描商品
------------------------------------------------------------------
local function parseOffer(o, calId)
    local labels = {}
    for _, d in ipairs(o:GetDescendants()) do
        if d:IsA("TextLabel") then
            local t = textOf(d)
            if t ~= "" then labels[string.lower(d.Name)] = t end
        end
    end
    local full = labels["name"] or ""
    local short = labels["short"] or ""
    local count = num(labels["count"]) or 0
    local price = num(labels["price"]) or 0

    -- Label 三种形态："3 / 3 LEFT" / "SOLD OUT" / 空
    local lbl = labels["label"] or ""
    local upper = string.upper(lbl)
    local soldOut = string.find(upper, "SOLD", 1, true) ~= nil
        or string.find(lbl, "售罄", 1, true) ~= nil
    local stock = 0
    if not soldOut then
        local a, b = lbl:match("(%d+)%s*/%s*(%d+)")
        if a then
            stock = tonumber(a)
            if stock == 0 then soldOut = true end
        elseif b then
            stock = tonumber(b)
        end
    end

    if full == "" or count <= 0 then return nil end
    return {
        key = o.Name,
        name = full,
        short = short,
        count = count,
        price = price,
        stock = stock,
        soldOut = soldOut,
        perRound = price / count,
        calId = calId,
    }
end

--============ 卡片登记 ============
-- 每张挂牌卡片按 offer.key 记录：名字/口径/包数/单价/库存/状态
-- 状态：in_stock | sold_out | empty | fail:<原因> | bought | gone
local function recordCard(rec, state, note)
    if type(rec) ~= "table" or not rec.key then return end
    S.cards = S.cards or {}
    local c = S.cards[rec.key]
    if not c then
        c = { key = rec.key }
        S.cards[rec.key] = c
    end
    c.name = rec.name or c.name
    c.calId = rec.calId or c.calId
    c.count = rec.count or c.count
    c.price = rec.price or c.price
    c.perRound = rec.perRound or c.perRound
    c.stock = rec.stock or 0
    c.soldOut = rec.soldOut == true
    if state then c.state = state end
    if note then c.note = note end
    c.seen = S.scanEpoch or 0
    return c
end

local function saveCards()
    if not (writefile and S.cards) then return end
    local lines = { "# HUSH 卡片状态  " .. os.date("%Y-%m-%d %H:%M:%S") }
    local list = {}
    for _, c in pairs(S.cards) do list[#list + 1] = c end
    table.sort(list, function(a, b)
        if a.calId ~= b.calId then return tostring(a.calId) < tostring(b.calId) end
        if (a.perRound or 0) ~= (b.perRound or 0) then return (a.perRound or 0) < (b.perRound or 0) end
        return tostring(a.key) < tostring(b.key)
    end)
    for _, c in ipairs(list) do
        lines[#lines + 1] = string.format("%s\t%s\t%s\t%d\t%d\t%s\t%.2f\t%s\t%s",
            tostring(c.calId or "?"), tostring(c.key), tostring(c.name),
            math.floor(tonumber(c.count) or 0), math.floor(tonumber(c.stock) or 0),
            tostring(c.price or 0), tonumber(c.perRound) or 0,
            tostring(c.state or ""), tostring(c.note or ""))
    end
    pcall(writefile, CARDS_FILE, table.concat(lines, "\n"))
end

local function scanCaliber(cal)
    local body = tradersBody()
    if not body then return nil end
    ensureAmmoTab(body)          -- 没选 AMMO 时口径芯片还不存在
    local calBox = body.FilterBox:FindFirstChild("Calibres")
    local chip = calBox and calBox:FindFirstChild(cal.chip)
    if not chip then return nil end

    click(chip)
    S.currentCal = cal.id
    task.wait(CFG.chipWait)

    local out = {}
    for _, o in ipairs(body.Offers:GetChildren()) do
        if o:IsA("TextButton") and o.Name ~= "kit_starter" then
            local rec = parseOffer(o, cal.id)
            if rec then
                recordCard(rec, rec.soldOut and "sold_out" or ((rec.stock or 0) > 0 and "in_stock" or "empty"))
                out[#out + 1] = rec
            end
        end
    end
    return out
end

-- 不切口径，直接扫当前列表（ALL），按商品名归类
local function scanAllList()
    local body = tradersBody()
    if not body then return {} end
    local grouped = {}
    for _, o in ipairs(body.Offers:GetChildren()) do
        if o:IsA("TextButton") and o.Name ~= "kit_starter" then
            local rec = parseOffer(o, nil)
            if rec then
                local cal = inferCal(rec.name)
                if cal then
                    rec.calId = cal
                    recordCard(rec, rec.soldOut and "sold_out" or ((rec.stock or 0) > 0 and "in_stock" or "empty"))
                    grouped[cal] = grouped[cal] or {}
                    table.insert(grouped[cal], rec)
                end
            end
        end
    end
    return grouped
end


-- 当前扫描结果里是否存在该商品名（用于判断"目标是否还在售"）
local function productExists(name)
    local want = tostring(name or "")
    for _, list in pairs(S.products or {}) do
        for _, p in ipairs(list) do
            if p.name == want then return true end
        end
    end
    return false
end

local function caliberHasPending(calId)
    for name, target in pairs(CFG.targets) do
        if (tonumber(target) or 0) > 0 and remainOf(name) > 0 then
            if nameCal(name) == calId and productExists(name) then return true end
        end
    end
    return false
end

-- onlyTargeted = true 时只扫「有目标的口径」，其他口径完全不碰
local function scanAll(onlyTargeted)
    if S.scanning then return end
    S.scanning = true
    S.scanStartAt = os.clock()
    S.scanEpoch = (S.scanEpoch or 0) + 1

    local targets = {}
    if onlyTargeted then
        for _, cal in ipairs(CALIBERS) do
            if caliberHasPending(cal.id) then targets[#targets + 1] = cal end
        end
        if #targets == 0 then targets = CALIBERS end
    else
        targets = CALIBERS
    end

    local total, sold = 0, 0
    local calMapChanged = false
    local scannedCals = {}

    local body = tradersBody()
    local hasCalibres = body and body.FilterBox and body.FilterBox:FindFirstChild("Calibres")
    local scanned = false

    if hasCalibres then
        for _, cal in ipairs(targets) do
            scannedCals[cal.id] = true
            local ok, res = pcall(scanCaliber, cal)
            local list = (ok and res) or {}
            S.products[cal.id] = list
            for _, p in ipairs(list) do
                total = total + 1
                if p.soldOut then sold = sold + 1 end
                if not S.nameToCal[p.name] then calMapChanged = true end
                S.nameToCal[p.name] = cal.id
            end
        end
        scanned = total > 0
    end

    -- 兜底：AMMO 分类点不动时，从当前列表按名字归类
    if not scanned then
        local grouped = scanAllList()
        for calId, list in pairs(grouped) do
            scannedCals[calId] = true
            S.products[calId] = list
            for _, p in ipairs(list) do
                total = total + 1
                if p.soldOut then sold = sold + 1 end
                if not S.nameToCal[p.name] then calMapChanged = true end
                S.nameToCal[p.name] = calId
            end
        end
    end

    -- 之前配置里标成 "?" 的口径这次能认出来了，回写一次
    if calMapChanged then
        for _, v in pairs(CFG.targets) do
            if (tonumber(v) or 0) > 0 then
                pcall(saveConfig)
                break
            end
        end
    end

    -- 重扫后重新判断哪些口径还有货
    S.dryCal = {}
    S.softFail = {}
    S.currentCal = nil
    S.scanning = false
    S.scanStartAt = 0
    for key, c in pairs(S.cards or {}) do
        if scannedCals[c.calId or ""] and c.seen ~= S.scanEpoch then
            S.cards[key] = nil
        end
    end
    S.ready = true
    S.needRescan = false
    S.nextRescanAt = os.clock() + CFG.fallbackRescan
    if P.onScan then pcall(P.onScan) end

    pcall(saveCards)

    if total == 0 then
        S.needRescan = true          -- 没扫到东西，下一轮重新导航再试
        log("扫描为空，重试中…")
    else
        log(string.format("扫描 %d 个口径：%d 个挂牌，%d 个售罄", #targets, total, sold))
    end
end

------------------------------------------------------------------
-- 购买
------------------------------------------------------------------
local function pickBestOffers(calId, productName)
    local list = S.products[calId] or {}
    local hits = {}
    for _, p in ipairs(list) do
        if p.name == productName and p.stock > 0 and not p.soldOut then hits[#hits + 1] = p end
    end
    table.sort(hits, function(a, b) return a.perRound < b.perRound end)
    return hits
end

local function anyPending()
    for name, target in pairs(CFG.targets) do
        if (tonumber(target) or 0) > 0 and remainOf(name) > 0 and productExists(name) then
            return true
        end
    end
    return false
end

-- 有目标但商品已不在售的条数（名字变了 / 下架 / 换季）
local function staleCount()
    local n = 0
    for name, target in pairs(CFG.targets) do
        if (tonumber(target) or 0) > 0 and remainOf(name) > 0 and not productExists(name) then
            n = n + 1
        end
    end
    return n
end

local function hasAnyTarget()
    for _, target in pairs(CFG.targets) do
        if (tonumber(target) or 0) > 0 then return true end
    end
    return false
end

-- 返回: ok, 已买发数, 说明
-- 原则：只有「详情面板确实切到这件商品、且确实没货」才判售罄；
-- 其它失败一律只冷却、不写死缓存，否则一次抖动会让该商品永久被跳过
local function buyFromOffer(cal, offer, packsWanted, skipChip)
    local body = tradersBody()
    if not body then return false, 0, "找不到交易面板" end

    if not skipChip then
        local calBox = body.FilterBox:FindFirstChild("Calibres")
        local chip = calBox and calBox:FindFirstChild(cal.chip)
        if chip then
            click(chip)
            S.currentCal = cal.id
            task.wait(CFG.chipWait)
        end
    end

    local function card()
        return body.Offers:FindFirstChild(offer.key)
    end

    -- 切口径后列表是异步重建的，固定 wait 不够：轮询等目标卡片出现
    if not card() then
        local deadline = os.clock() + 2
        while os.clock() < deadline and not card() do
            task.wait(0.08)
        end
    end
    if not card() then return false, 0, "卡片未出现:" .. tostring(offer.key) end
    click(card())
    task.wait(CFG.selectWait)

    local detail = body.Detail.Panel.Content

    -- 先确认详情面板确实切到了这件商品（标题带字距动画，要去掉空白再比），
    -- 再判断有没有数量控件；顺序反了会把「面板还没切过来」误判成「限购满」
    local function norm(x)
        return (tostring(x or ""):lower():gsub("[^%w%.]", ""))
    end
    local function detailTitle()
        local top = detail:FindFirstChild("Top")
        local t = top and top:FindFirstChild("Title")
        return textOf(t)
    end
    local wantTitle = norm(offer.name)
    local title = detailTitle()
    if title ~= "" and norm(title) ~= wantTitle then
        for _ = 1, 6 do
            task.wait(0.15)
            title = detailTitle()
            if norm(title) == wantTitle then break end
            if card() then click(card()) end
        end
    end
    if title ~= "" and norm(title) ~= wantTitle then
        return false, 0, "详情未同步:[" .. title .. "]"        -- 不判售罄，下轮再试
    end

    local qtyFrame = detail.Foot:FindFirstChild("Qty")
    -- 买过之后该 listing 可能达到限购上限：游戏会直接把 Qty 控件移除，
    -- 只剩 Price / BuyButton。这不是异常，标成不可买然后跳过。
    if not qtyFrame then
        task.wait(0.3)
        qtyFrame = detail.Foot:FindFirstChild("Qty")
    end
    if not qtyFrame then
        local btn = detail.Foot:FindFirstChild("BuyButton")
        local lbl = textOf(btn and btn.Inner and btn.Inner:FindFirstChild("Text"))
        offer.stock = 0
        offer.soldOut = true
        return false, 0, "不可购买(限购/售罄):" .. tostring(lbl)
    end

    local maxPacks = tonumber(get(qtyFrame, "QtyMax")) or 1
    local packs = math.min(packsWanted, maxPacks, 50)
    if packs < 1 then
        -- 再确认一次，避免详情刚切过来时读到旧值
        task.wait(0.25)
        maxPacks = tonumber(get(qtyFrame, "QtyMax")) or 0
        packs = math.min(packsWanted, maxPacks, 50)
        if packs < 1 then
            offer.stock = 0
            offer.soldOut = true
            return false, 0, "已售罄"
        end
    end

    -- 点 QtyMax 再减到目标值，比连点加号稳
    click(qtyFrame:FindFirstChild("QtyMax"))
    task.wait(0.12)
    local cur = tonumber(get(qtyFrame, "Qty")) or 1
    local minus = qtyFrame:FindFirstChild("QtyMinus")
    local guard = 0
    while cur > packs and guard < 60 do
        click(minus)
        task.wait(0.06)
        cur = tonumber(get(qtyFrame, "Qty")) or cur
        guard = guard + 1
    end
    if cur ~= packs then return false, 0, "数量设定失败" end

    local buyBtn = detail.Foot:FindFirstChild("BuyButton")
    if not buyBtn then return false, 0, "无购买按钮" end
    local label = textOf(buyBtn.Inner and buyBtn.Inner:FindFirstChild("Text"))
    -- 按钮文案同样带字距空格（"S O L D  O U T"），先去空白再判
    local flat = string.lower(label):gsub("[^%w]", "")
    if flat:find("locked") or flat:find("full") then
        return false, 0, "按钮不可用:" .. label   -- 可能是限购，不是售罄
    end
    if flat:find("sold") or label:find("售罄", 1, true) then
        -- 标题已在上面校验过，这里可以确认是这件商品售罄
        offer.stock = 0
        offer.soldOut = true
        return false, 0, "已售罄"
    end

    click(buyBtn)
    S.lastBuyAt[offer.key] = os.clock()
    return true, packs * offer.count, "已下单"
end

------------------------------------------------------------------
-- 单个口径内买完
-- 返回 "bought"（成交一笔） | "wait"（有货但冷却中） | "dry"（无货可买）
------------------------------------------------------------------
local function buyInCaliber(cal)
    local body = tradersBody()
    if not body then return "wait", "无交易面板" end

    -- 有口径芯片才切；没有说明当前是 ALL 列表，卡片已经在列表里了
    local calBox = body.FilterBox:FindFirstChild("Calibres")
    if calBox and S.currentCal ~= cal.id then
        local chip = calBox:FindFirstChild(cal.chip)
        if chip then
            click(chip)
            S.currentCal = cal.id
            task.wait(CFG.chipWait)
        end
    end

    local list = S.products[cal.id] or {}
    local seen = {}
    local cooling = false
    local tried = 0

    for _, p in ipairs(list) do
        if not seen[p.name] then
            seen[p.name] = true
            local remain = remainOf(p.name)
            if remain > 0 then
                local offer = pickBestOffers(cal.id, p.name)[1]
                if offer then
                    local cd = S.lastBuyAt[offer.key]
                    if not cd or (os.clock() - cd) >= CFG.buyGap then
                        local packsNeeded = math.ceil(remain / math.max(1, offer.count))
                        local ok, got, why = buyFromOffer(cal, offer, packsNeeded, true)
                        if ok then
                            recordCard(offer, "bought", string.format("+%d发", got))
                            S.waitingRestock = false
                            S.boughtBy[p.name] = (S.boughtBy[p.name] or 0) + got
                            S.spentBy[p.name] = (S.spentBy[p.name] or 0) + offer.perRound * got
                            S.boughtDirty = true
                            recomputeTotals()
                            offer.stock = math.max(0, offer.stock - math.max(1, math.floor(got / offer.count)))
                            if offer.stock == 0 then offer.soldOut = true end
                            log(string.format("[%s] 买入 %s x%d包 = %d发（%s/发）｜本弹种 %d/%d",
                                cal.label, offer.name, math.max(1, math.floor(got / offer.count)), got,
                                money(offer.perRound),
                                S.boughtBy[p.name], tonumber(CFG.targets[p.name]) or 0))
                            return "bought"
                        else
                            -- 失败也进冷却：不然同一 tick 会反复点同一张卡，
                            -- 而且会被误判成「整个口径没货」
                            S.lastBuyAt[offer.key] = os.clock()
                            recordCard(offer, "fail", tostring(why))
                            S.lastBuyErr = tostring(why)
                            S.lastMsg = string.format("[%s] 跳过 %s：%s", cal.label, offer.name, tostring(why))
                            tried = tried + 1
                        end
                    else
                        cooling = true
                    end
                end
            end
        end
    end

    if tried > 0 then return "fail", "本轮未成交" end
    if cooling then return "cool", "冷却中" end
    return "dry"
end

------------------------------------------------------------------
-- Obsidian UI 库
------------------------------------------------------------------
local OBSIDIAN_URL = "https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/Library.lua"

local function loadObsidian()
    local src

    -- 1) 本地缓存
    if isfile and isfile(LIB_FILE) then
        local ok, d = pcall(readfile, LIB_FILE)
        if ok and type(d) == "string" and #d > 1000 then src = d end
    end

    -- 2) 本 session 内存缓存
    if not src then
        local mem = _G.HUSH_OBSIDIAN_SRC
        if type(mem) == "string" and #mem > 1000 then src = mem end
    end

    -- 3) 网络
    if not src then
        local ok, fetched = pcall(function() return game:HttpGet(OBSIDIAN_URL) end)
        if ok and type(fetched) == "string" and #fetched > 1000 then
            src = fetched
            _G.HUSH_OBSIDIAN_SRC = src
            pcall(writefile, LIB_FILE, src)
        end
    end

    if type(src) ~= "string" or #src < 1000 then return nil end

    local fn = loadstring(src)
    if not fn then return nil end
    local ok, res = pcall(fn)
    if ok and type(res) == "table" then return res end
    return nil
end

------------------------------------------------------------------
-- 面板
------------------------------------------------------------------
local lastText = {}
local function setLbl(lbl, key, text)
    if not lbl then return end
    if lastText[key] == text then return end
    lastText[key] = text
    pcall(function() lbl:SetText(text) end)
end

-- 某产品当前是否有货 / 是否全售罄 / 是否根本没扫到
local function stockState(calId, productName)
    local has, sold, any = false, false, false
    for _, q in ipairs(S.products[calId] or {}) do
        if q.name == productName then
            any = true
            if q.stock > 0 and not q.soldOut then has = true end
            if q.soldOut then sold = true end
        end
    end
    if not any then return false, false, true end     -- 不在售
    return has, (not has) and sold, false
end

local function buildUI()
    local Library = loadObsidian()
    if not Library then
        log("Obsidian 加载失败，仅保留后台购买")
        return false
    end
    P.library = Library

    local Window = Library:CreateWindow({
        Title = "HUSH 弹药采购",
        Footer = "v4",
        ToggleKeybind = Enum.KeyCode.RightControl,
        Resizable = true,
        ShowCustomCursor = false,
    })
    P.window = Window

    -- 改名：hush_ui 卸载时会销毁所有名字含 Obsidian 的 ScreenGui
    pcall(function()
        if Library.ScreenGui then
            Library.ScreenGui.Name = "HushAmmoWindow"
            Library.ScreenGui.DisplayOrder = 997
        end
    end)

    local tabBuy = Window:AddTab("采购", "box")
    local tabRun = Window:AddTab("运行", "activity")

    for i, cal in ipairs(CALIBERS) do
        if i <= 4 then
            P.groups[cal.id] = tabBuy:AddLeftGroupbox(cal.label, "box")
        else
            P.groups[cal.id] = tabBuy:AddRightGroupbox(cal.label, "box")
        end
    end

    --============ 控制 ============
    local gCtl = tabRun:AddLeftGroupbox("控制", "activity")
    P.lblState = gCtl:AddLabel("状态：空闲")
    P.lblCal = gCtl:AddLabel("当前口径：—")
    P.lblRestock = gCtl:AddLabel("补货：—")
    P.lblBought = gCtl:AddLabel("已买：0 发")
    P.lblSpent = gCtl:AddLabel("花费：$0")

    P.toggleRun = gCtl:AddToggle("ammoRun", {
        Text = "启用自动购买",
        Default = false,
        Tooltip = "按口径顺序：把当前口径下勾选且有货的弹种买空，再进下一个口径",
        Callback = function(v)
            S.running = v
            if v then
                S.nextRescanAt = 0
                S.dryCal = {}
                S.currentCal = nil
                S.needRescan = true
                log("已启用")
            else
                log("已暂停")
            end
        end
    })

    gCtl:AddButton({
        Text = "立即重扫（仅勾选的口径）",
        Func = function()
            S.nextRescanAt = 0
            S.needRescan = true
            log("准备重扫")
        end
    })
    gCtl:AddButton({
        Text = "清零已买记录（含文件）",
        Tooltip = "把已买数量归零并写入 " .. BOUGHT_FILE .. "，之后会重新按目标购买",
        Func = function()
            S.boughtBy = {}
            S.spentBy = {}
            S.lastBuyAt = {}
            S.dryCal = {}
            S.softFail = {}
            S.boughtDirty = true
            recomputeTotals()
            saveBought()
            log("已买记录已清零（文件同步）")
        end
    })

    --============ 配置 ============
    local gCfg = tabRun:AddRightGroupbox("配置", "settings")
    P.lblConfig = gCfg:AddLabel("配置文件：读取中…")

    gCfg:AddButton({
        Text = "保存配置",
        Tooltip = "写入 " .. CONFIG_FILE .. "，重进游戏自动恢复",
        Func = function()
            if saveConfig() then log("配置已保存") end
        end
    })
    gCfg:AddButton({
        Text = "重新载入配置",
        Tooltip = "从文件读取并覆盖当前目标",
        Func = function()
            local ok, n = loadConfig()
            if ok then
                for name, row in pairs(P.rows) do
                    local v = tonumber(CFG.targets[name]) or 0
                    pcall(function() row.input:SetValue(tostring(v)) end)
                    pcall(function() row.toggle:SetValue(v > 0) end)
                end
                S.dryCal = {}
                S.needRescan = true
                log(string.format("已载入 %d 条配置", n))
            else
                log("配置文件不存在或为空")
            end
        end
    })
    gCfg:AddButton({
        Text = "全部目标归零",
        Tooltip = "清空所有目标并保存",
        Func = function()
            for k in pairs(CFG.targets) do CFG.targets[k] = 0 end
            for _, row in pairs(P.rows) do
                pcall(function() row.toggle:SetValue(false) end)
                pcall(function() row.input:SetValue("0") end)
            end
            saveConfig()
            log("所有目标已归零")
        end
    })
    gCfg:AddButton({
        Text = "复制配置到剪贴板",
        Func = function()
            local lines = {}
            for name, n in pairs(CFG.targets) do
                if (tonumber(n) or 0) > 0 then
                    lines[#lines + 1] = string.format("%s\t%s\t%d",
                        nameCal(name) or "?", name, math.floor(tonumber(n)))
                end
            end
            table.sort(lines)
            local txt = table.concat(lines, "\n")
            if setclipboard then
                pcall(setclipboard, txt)
                log("已复制 " .. #lines .. " 条到剪贴板")
            else
                print("[AMMO-CFG]\n" .. txt)
                log("执行器无 setclipboard，已打印到控制台")
            end
        end
    })

    --============ 汇总 ============
    local gSum = tabRun:AddRightGroupbox("汇总", "box")
    for _, cal in ipairs(CALIBERS) do
        P.sumLabels[cal.id] = gSum:AddLabel(cal.label .. "：-")
    end
    P.cardLbl = gSum:AddLabel("卡片：-")

    --============ 扫描后追建产品行 ============
    P.onScan = function()
        for _, cal in ipairs(CALIBERS) do
            local gb = P.groups[cal.id]
            local list = S.products[cal.id] or {}
            local seen = {}
            for _, p in ipairs(list) do
                if not seen[p.name] then
                    seen[p.name] = true
                    local row = P.rows[p.name]
                    if row then
                        pcall(function() row.toggle:SetVisible(true) end)
                        pcall(function() row.input:SetVisible(true) end)
                    else
                        row = { calId = cal.id }
                        row.toggle = gb:AddToggle(safeId("sel", p.name), {
                            Text = p.name,
                            Default = (tonumber(CFG.targets[p.name]) or 0) > 0,
                            Callback = function(v)
                                if v then
                                    if (tonumber(CFG.targets[p.name]) or 0) <= 0 then
                                        CFG.targets[p.name] = 200
                                        pcall(function() row.input:SetValue("200") end)
                                    end
                                else
                                    CFG.targets[p.name] = 0
                                    pcall(function() row.input:SetValue("0") end)
                                end
                                S.nameToCal[p.name] = cal.id
                                S.dryCal = {}
                                queueSave()
                            end
                        })
                        row.input = gb:AddInput(safeId("qty", p.name), {
                            Text = "  ↳ 目标发数",
                            Default = tostring(tonumber(CFG.targets[p.name]) or 0),
                            Numeric = true,
                            Finished = true,
                            Placeholder = "0 = 不买",
                            Tooltip = "回车确认；填 0 等于不买。最后一包可能超出这个数",
                            Callback = function(v)
                                local n = math.max(0, math.floor(tonumber(v) or 0))
                                CFG.targets[p.name] = n
                                pcall(function() row.toggle:SetValue(n > 0) end)
                                S.nameToCal[p.name] = cal.id
                                S.dryCal = {}
                                queueSave()
                            end
                        })
                        P.rows[p.name] = row
                    end
                end
            end

            -- 本次没扫到的：有目标的保持可见并标「未在售」，没目标的隐藏
            for name, row in pairs(P.rows) do
                if row.calId == cal.id and not seen[name] then
                    if (tonumber(CFG.targets[name]) or 0) > 0 then
                        pcall(function() row.toggle:SetVisible(true) end)
                        pcall(function() row.input:SetVisible(true) end)
                        pcall(function() row.toggle:SetText(name .. "  · 未在售") end)
                    else
                        pcall(function() row.toggle:SetVisible(false) end)
                        pcall(function() row.input:SetVisible(false) end)
                    end
                end
            end
        end

        -- 刷一次文本（价格 / 售罄标记）
        for _, cal in ipairs(CALIBERS) do
            local done = {}
            for _, p in ipairs(S.products[cal.id] or {}) do
                if not done[p.name] then
                    done[p.name] = true
                    local row = P.rows[p.name]
                    if row then
                        local has, allSold = stockState(cal.id, p.name)
                        local tag = ""
                        if allSold then
                            tag = "  · 售罄"
                        elseif has then
                            tag = string.format("  %s/发", money(p.perRound))
                        end
                        pcall(function() row.toggle:SetText(p.name .. tag) end)
                    end
                end
            end
        end

        -- 卡片级汇总：按挂牌计数（同一商品可能有多张不同价/不同库存的卡）
        local cTotal, cIn, cSold = 0, 0, 0
        for _, cd in pairs(S.cards or {}) do
            cTotal = cTotal + 1
            if cd.state == "in_stock" then
                cIn = cIn + 1
            elseif cd.state == "sold_out" then
                cSold = cSold + 1
            end
        end
        if P.cardLbl then
            pcall(function()
                P.cardLbl:SetText(string.format("卡片 %d：在售 %d · 售罄 %d", cTotal, cIn, cSold))
            end)
        end
    end

    return true
end

local function refreshUI()
    local remain = restockRemain()
    local rText
    if remain then
        rText = fmtTime(remain)
        if remain <= 3 then rText = rText .. "  ← 即将补货" end
    elseif S.restockText ~= "" then
        rText = "—（面板未打开）"
    else
        rText = "—"
    end

    local stateText
    if not isLobby() then
        stateText = "等待进入大厅"
    elseif not S.ready then
        stateText = S.scanning and "扫描中…" or "待扫描（请打开 Gunner）"
    elseif S.running then
        stateText = S.waitingRestock and S.lastMsg or "运行中"
    else
        stateText = "已暂停 · " .. tostring(S.lastMsg)
    end

    setLbl(P.lblState, "state", "状态：" .. stateText)
    setLbl(P.lblCal, "cal", "当前口径：" .. (S.currentCal and calLabel(S.currentCal) or "—"))
    setLbl(P.lblRestock, "restock", "补货：" .. rText)
    setLbl(P.lblBought, "bought", string.format("已买：%d 发", S.bought))
    setLbl(P.lblSpent, "spent", "花费：" .. money(S.spent))

    if S.loadedFromFile then
        setLbl(P.lblConfig, "config", "配置文件：已载入（" .. CONFIG_FILE .. "）")
    else
        setLbl(P.lblConfig, "config", "配置文件：无（改目标后自动保存）")
    end

    for _, cal in ipairs(CALIBERS) do
        local got, want, soldN = 0, 0, 0
        local seen = {}
        for _, p in ipairs(S.products[cal.id] or {}) do
            if not seen[p.name] then
                seen[p.name] = true
                local t = tonumber(CFG.targets[p.name]) or 0
                if t > 0 then
                    want = want + t
                    got = got + math.min(S.boughtBy[p.name] or 0, t)
                end
                local _, allSold = stockState(cal.id, p.name)
                if allSold then soldN = soldN + 1 end
            end
        end
        -- 配置里有、但当前扫描不到的目标（游戏改名 / 下架）
        local staleN = 0
        for nm, tv in pairs(CFG.targets) do
            if (tonumber(tv) or 0) > 0 and nameCal(nm) == cal.id and not productExists(nm) then
                staleN = staleN + 1
            end
        end
        local txt
        if want == 0 and staleN == 0 then
            txt = string.format("%s：未设定", cal.label)
        else
            txt = string.format("%s：%d / %d", cal.label, got, want)
        end
        local tag = {}
        if S.dryCal[cal.id] then tag[#tag + 1] = "选中项已买空" end
        if soldN > 0 then tag[#tag + 1] = soldN .. " 售罄" end
        if staleN > 0 then tag[#tag + 1] = staleN .. " 失效" end
        if #tag > 0 then txt = txt .. "（" .. table.concat(tag, "，") .. "）" end
        setLbl(P.sumLabels[cal.id], "sum_" .. cal.id, txt)
    end
end

------------------------------------------------------------------
-- 主循环
------------------------------------------------------------------
local function step()
    autoDismiss()

    if not isLobby() then
        S.lastMsg = "等待进入大厅"
        return
    end

    -- 看门狗：扫描卡死（异常/等待）超过 15 秒就强制复位
    if S.scanning and S.scanStartAt and os.clock() - S.scanStartAt > 15 then
        S.scanning = false
        S.scanStartAt = 0
        S.needRescan = true
        log("扫描超时，已重置")
    end

    if S.needRescan or (not S.ready) then
        if not S.scanning then
            -- 先确保站在 Gunner 购买页；不在就自动切过去
            local navOK, navWhy = ensureBuyPage()
            if not navOK and not tradersBody() then
                S.lastMsg = navWhy
                return
            end
            S.lastMsg = "扫描商品中…"
            task.spawn(function() scanAll(S.ready) end)   -- 首次全量，之后只扫有目标的
        end
        return
    end

    if not S.running then return end

    if not hasAnyTarget() then
        S.lastMsg = "未设定任何目标"
        return
    end

    if not anyPending() then
        S.waitingRestock = false
        local stale = staleCount()
        if stale > 0 then
            S.lastMsg = string.format("%d 个目标已不在售（改名或下架），请重新勾选", stale)
        else
            S.lastMsg = "全部达标"
        end
        return
    end

    -- 1) 哪些口径还有未达标的目标
    local pending = {}
    for _, cal in ipairs(CALIBERS) do
        if caliberHasPending(cal.id) then pending[#pending + 1] = cal end
    end

    -- 2) 其中还没被判定买空的
    local buyable = {}
    for _, cal in ipairs(pending) do
        if not S.dryCal[cal.id] then buyable[#buyable + 1] = cal end
    end

    if #buyable == 0 then
        -- 全部买空 → 等补货，只在倒计时快归零时重扫
        S.waitingRestock = true
        S.currentCal = nil
        local remain = restockRemain()
        if remain then
            S.lastMsg = "等待补货 " .. fmtTime(remain)
            if remain <= CFG.rescanLead and not S.scanning then
                task.spawn(function() scanAll(true) end)
            end
        elseif S.restockText ~= "" then
            S.lastMsg = "等待补货（面板未打开）"
            if os.clock() >= S.nextRescanAt and not S.scanning then
                task.spawn(function() scanAll(true) end)
            end
        else
            S.lastMsg = "等待补货"
            if os.clock() >= S.nextRescanAt and not S.scanning then
                task.spawn(function() scanAll(true) end)
            end
        end
        return
    end

    -- 3) 优先继续当前口径，把它买完再换
    local target = nil
    for _, cal in ipairs(buyable) do
        if cal.id == S.currentCal then target = cal break end
    end
    target = target or buyable[1]

    local state, why = buyInCaliber(target)

    if state == "bought" then
        S.softFail[target.id] = 0
    elseif state == "dry" then
        S.dryCal[target.id] = true
        S.softFail[target.id] = 0
        if S.currentCal == target.id then S.currentCal = nil end
        S.lastMsg = string.format("%s 已买空%s", target.label, why and ("（" .. why .. "）") or "")
        log(S.lastMsg)
    elseif state == "fail" then
        -- 连续失败若干轮才认定买空，避免一次抖动就把整个口径判死
        local n = (S.softFail[target.id] or 0) + 1
        S.softFail[target.id] = n
        S.lastMsg = string.format("%s 未成交（%s）%d/3", target.label, tostring(why or ""), n)
        if n >= 3 then
            S.dryCal[target.id] = true
            S.softFail[target.id] = 0
            if S.currentCal == target.id then S.currentCal = nil end
            S.lastMsg = target.label .. " 连续 3 轮未成交，转等待补货"
            log(S.lastMsg)
        end
    elseif state == "cool" then
        S.lastMsg = string.format("%s %s", target.label, tostring(why or "冷却中"))
    end
end

------------------------------------------------------------------
-- 启动
------------------------------------------------------------------
-- 相机未就绪时 Obsidian 建窗会读到 nil ViewportSize
do
    local guard = 0
    while not workspace.CurrentCamera and guard < 100 do
        task.wait(0.1)
        guard = guard + 1
    end
end

-- 先加载配置，再建 UI，这样产品行的 Default 就是已保存的值
local cfgOK, cfgN = loadConfig()
if cfgOK then
    print("[AMMO] 已从 " .. CONFIG_FILE .. " 载入 " .. cfgN .. " 条目标")
end

-- 已买账本：必须在建 UI 之前载入，否则第一屏显示的是 0，也容易被误判成没买过
local bN = loadBought()
if bN and bN > 0 then
    print(string.format("[AMMO] 已从 %s 载入 %d 条已买记录，累计 %d 发", BOUGHT_FILE, bN, S.bought))
end

local uiOK = buildUI()
if not uiOK then
    log("UI 未就绪，后台购买仍可用（_G.HUSH_AMMO）")
end

-- 配置改动后 1.5 秒落盘，避免拖滑块时狂写文件；已买记录则尽快写，防意外断线
task.spawn(function()
    while not S.dead do
        if S.savePending and (os.clock() - S.lastSaveAt) > 1.5 then
            saveConfig()
        end
        if S.boughtDirty then
            saveBought()
        end
        task.wait(0.5)
    end
end)

task.spawn(function()
    while not S.dead do
        local ok, err = pcall(step)
        if not ok then log("STEP_ERR " .. tostring(err)) end
        task.wait(CFG.tickGap)
    end
end)

task.spawn(function()
    while not S.dead do
        pcall(refreshUI)
        task.wait(0.5)
    end
end)

task.spawn(function()
    task.wait(1.5)
    if isLobby() then pcall(function() scanAll(false) end) end
    if CFG.autoStart and hasAnyTarget() then
        S.running = true
        if P.toggleRun then pcall(function() P.toggleRun:SetValue(true) end) end
        log("自动开始（配置里有目标）")
    end
end)

_G.HUSH_AMMO = {
    state = S,
    cfg = CFG,
    panel = P,
    scan = function(onlyTargeted) return scanAll(onlyTargeted ~= false) end,
    scanAll = scanAll,
    readRestock = readRestock,
    restockRemain = restockRemain,
    saveConfig = saveConfig,
    loadConfig = loadConfig,
    saveBought = saveBought,
    loadBought = loadBought,
    buyInCaliber = buyInCaliber,
    ensureBuyPage = ensureBuyPage,
    cards = function()
        local list = {}
        for _, c in pairs(S.cards or {}) do list[#list + 1] = c end
        table.sort(list, function(a, b)
            if a.calId ~= b.calId then return tostring(a.calId) < tostring(b.calId) end
            return (a.perRound or 0) < (b.perRound or 0)
        end)
        return list
    end,
    saveCards = saveCards,
    start = function()
        S.running = true
        S.dryCal = {}
        S.needRescan = true
        if P.toggleRun then pcall(function() P.toggleRun:SetValue(true) end) end
    end,
    stop = function()
        S.running = false
        if P.toggleRun then pcall(function() P.toggleRun:SetValue(false) end) end
    end,
    setTarget = function(name, n)
        CFG.targets[name] = math.max(0, math.floor(tonumber(n) or 0))
        S.dryCal = {}
        S.needRescan = true
        local row = P.rows[name]
        if row then
            pcall(function() row.input:SetValue(tostring(CFG.targets[name])) end)
            pcall(function() row.toggle:SetValue(CFG.targets[name] > 0) end)
        end
        queueSave()
    end,
    dispose = function()
        S.dead = true
        S.running = false
        -- 只有确实有目标、或本来就载入过配置时才落盘；
        -- 否则空状态会把用户的配置文件覆盖掉
        pcall(function()
            if hasAnyTarget() or S.loadedFromFile then saveConfig() end
        end)
        pcall(saveBought)
        pcall(function()
            if P.library and P.library.ScreenGui then P.library.ScreenGui:Destroy() end
        end)
        pcall(function()
            local host = (gethui and gethui()) or game:GetService("CoreGui")
            local old = host:FindFirstChild("HushAmmo")
            if old then old:Destroy() end
        end)
    end,
}

log("v4 已加载 · RightCtrl 开关窗口")
