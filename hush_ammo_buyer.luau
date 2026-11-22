--[[
    HUSH 弹药自动购买 v3  (Potassium / autoexec)
    ─────────────────────────────────────────────
    用途
      · 放在 autoexec，进大厅后自动就绪
      · 自动点掉过场 SKIP、自动关闭 SALE 广告（只点 LATER，绝不点 VIEW SALE）
      · 每个弹种单独设目标发数；勾选后自动在 Gunner 处买满
      · 配置自动存盘，重进游戏自动恢复

    v3 变更
      · 售空自动识别：卡片 Label 为 "SOLD OUT" 即标记，UI 显示「售罄」，不再重试
      · 配置持久化：hush_ammo_config.txt（writefile 已验证可用），启动自动加载
      · Obsidian 库本地缓存到 obsidian_Library.lua，重载不再每次下载 483KB
      · 修控件 ID：产品名含中文时 [^%w] 会全部替换成下划线导致 ID 撞车，改用 djb2 哈希
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
local LIB_FILE = "obsidian_Library.lua"

local CFG = {
    targets = {},          -- [商品名] = 目标发数；0 或 nil = 不买
    buyGap = 4.25,         -- 同一 offer 冷却 4s，留点余量
    chipWait = 0.35,       -- 切口径后等列表重建
    selectWait = 0.4,      -- 选中商品后等详情刷新
    tickGap = 0.35,
    restockPoll = 1.0,     -- 补货倒计时读取间隔
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
    boughtBy = {},         -- [商品名] = 本次已买发数
    products = {},         -- [calId] = { {name, short, key, count, price, stock, perRound, soldOut} }
    lastBuyAt = {},        -- [offerKey] = os.clock()
    scanning = false,
    ready = false,
    lastMsg = "空闲",
    waitingRestock = false,
    restockText = "",
    restockSec = nil,
    restockAt = nil,
    nextRescanAt = 0,
    needRescan = false,
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

local function clickByText(root, wantText)
    local want = string.upper(wantText)
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("TextButton") then
            if string.upper(textOf(d)) == want then return click(d), d end
            for _, c in ipairs(d:GetDescendants()) do
                if c:IsA("TextLabel") and string.upper(textOf(c)) == want then
                    return click(d), d
                end
            end
        end
    end
    return false, nil
end

------------------------------------------------------------------
-- 配置持久化
------------------------------------------------------------------
-- 格式：每行 "商品名<TAB>目标发数"，# 开头为注释
local function saveConfig()
    local lines = { "# HUSH 弹药采购配置  " .. os.date("%Y-%m-%d %H:%M") }
    local keys = {}
    for name, n in pairs(CFG.targets) do
        if (tonumber(n) or 0) > 0 then keys[#keys + 1] = name end
    end
    table.sort(keys)
    for _, name in ipairs(keys) do
        lines[#lines + 1] = name .. "\t" .. tostring(math.floor(tonumber(CFG.targets[name]) or 0))
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
    for line in data:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local name, val = line:match("^(.-)\t(%d+)$")
            if name and name ~= "" and val then
                CFG.targets[name] = tonumber(val)
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
-- 自动关弹窗：SKIP / LATER
------------------------------------------------------------------
local function autoDismiss()
    local pg = lp:FindFirstChild("PlayerGui")
    if not pg then return end

    for _, guiName in ipairs({ "HushMenuFade", "HushTouch", "HushTransit" }) do
        local g = pg:FindFirstChild(guiName)
        if g and g.Enabled then
            local ok = clickByText(g, "SKIP")
            if ok then log("已点 SKIP") end
        end
    end

    -- 只点 LATER，绝不点 VIEW SALE
    local modal = pg:FindFirstChild("HushModal")
    if modal then
        for _, d in ipairs(modal:GetDescendants()) do
            if d:IsA("TextButton") then
                local hit = string.upper(textOf(d)) == "LATER"
                if not hit then
                    for _, c in ipairs(d:GetDescendants()) do
                        if c:IsA("TextLabel") and string.upper(textOf(c)) == "LATER" then
                            hit = true
                            break
                        end
                    end
                end
                if hit then
                    click(d)
                    log("已关闭 SALE 弹窗（LATER）")
                    return
                end
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
local function scanCaliber(cal)
    local body = tradersBody()
    if not body then return nil end
    local calBox = body.FilterBox:FindFirstChild("Calibres")
    local chip = calBox and calBox:FindFirstChild(cal.chip)
    if not chip then return nil end

    click(chip)
    task.wait(CFG.chipWait)

    local offers = body.Offers
    local out = {}
    for _, o in ipairs(offers:GetChildren()) do
        if o:IsA("TextButton") and o.Name ~= "kit_starter" then
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

            if full ~= "" and count > 0 then
                out[#out + 1] = {
                    key = o.Name,
                    name = full,
                    short = short,
                    count = count,
                    price = price,
                    stock = stock,
                    soldOut = soldOut,
                    perRound = price / count,
                }
            end
        end
    end
    return out
end

local function scanAll()
    if S.scanning then return end
    S.scanning = true
    S.products = {}
    local total, sold = 0, 0
    for _, cal in ipairs(CALIBERS) do
        local ok, res = pcall(scanCaliber, cal)
        local list = (ok and res) or {}
        S.products[cal.id] = list
        for _, p in ipairs(list) do
            total = total + 1
            if p.soldOut then sold = sold + 1 end
        end
    end
    S.scanning = false
    S.ready = true
    S.needRescan = false
    S.nextRescanAt = os.clock() + 25
    if P.onScan then pcall(P.onScan) end
    if total == 0 then
        log("扫描为空：请打开 Blackmarket → Traders → Gunner")
    else
        log(string.format("扫描完成：%d 个挂牌，其中 %d 个售罄", total, sold))
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

local function remainOf(name)
    local target = tonumber(CFG.targets[name]) or 0
    if target <= 0 then return 0 end
    return target - (S.boughtBy[name] or 0)
end

local function anyPending()
    for name, target in pairs(CFG.targets) do
        if (tonumber(target) or 0) > 0 and remainOf(name) > 0 then return true end
    end
    return false
end

local function hasAnyTarget()
    for _, target in pairs(CFG.targets) do
        if (tonumber(target) or 0) > 0 then return true end
    end
    return false
end

-- 返回: ok, 已买发数, 说明
local function buyFromOffer(cal, offer, packsWanted)
    local body = tradersBody()
    if not body then return false, 0, "找不到交易面板" end

    local calBox = body.FilterBox:FindFirstChild("Calibres")
    local chip = calBox and calBox:FindFirstChild(cal.chip)
    if chip then
        click(chip)
        task.wait(CFG.chipWait)
    end

    local card = body.Offers:FindFirstChild(offer.key)
    if not card then return false, 0, "卡片不存在" end
    click(card)
    task.wait(CFG.selectWait)

    local detail = body.Detail.Panel.Content
    local qtyFrame = detail.Foot:FindFirstChild("Qty")
    if not qtyFrame then return false, 0, "无数量控件" end

    local maxPacks = tonumber(get(qtyFrame, "QtyMax")) or 1
    local packs = math.min(packsWanted, maxPacks, 50)
    if packs < 1 then
        offer.stock = 0
        offer.soldOut = true
        return false, 0, "已售罄"
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
    local low = string.lower(label)
    if low:find("locked") or low:find("sold") or low:find("full") or label:find("售罄", 1, true) then
        offer.stock = 0
        offer.soldOut = true
        return false, 0, "按钮不可用:" .. label
    end

    click(buyBtn)
    S.lastBuyAt[offer.key] = os.clock()
    return true, packs * offer.count, "已下单"
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

-- 某产品当前是否有货 / 是否全售罄
local function stockState(calId, productName)
    local has, sold, any = false, false, false
    for _, q in ipairs(S.products[calId] or {}) do
        if q.name == productName then
            any = true
            if q.stock > 0 and not q.soldOut then has = true end
            if q.soldOut then sold = true end
        end
    end
    if not any then return false, true end        -- 扫描里没有 = 不在售
    return has, (not has) and sold
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
        Footer = "v3",
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
    P.lblRestock = gCtl:AddLabel("补货：—")
    P.lblBought = gCtl:AddLabel("已买：0 发")
    P.lblSpent = gCtl:AddLabel("花费：$0")

    P.toggleRun = gCtl:AddToggle("ammoRun", {
        Text = "启用自动购买",
        Default = false,
        Tooltip = "按各弹种设定的目标发数购买；每包可能超出目标",
        Callback = function(v)
            S.running = v
            if v then
                S.nextRescanAt = 0
                log("已启用")
            else
                log("已暂停")
            end
        end
    })

    gCtl:AddButton({
        Text = "立即重扫商品",
        Func = function()
            S.nextRescanAt = 0
            S.needRescan = true
            log("准备重扫")
        end
    })
    gCtl:AddButton({
        Text = "清零本次计数",
        Func = function()
            S.bought = 0
            S.spent = 0
            S.boughtBy = {}
            S.lastBuyAt = {}
            log("计数已清零")
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
                    lines[#lines + 1] = name .. "\t" .. tostring(math.floor(tonumber(n)))
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
                                queueSave()
                            end
                        })
                        P.rows[p.name] = row
                    end
                end
            end
            -- 本次没扫到的产品先隐藏，保留已填目标
            for name, row in pairs(P.rows) do
                if row.calId == cal.id and not seen[name] then
                    pcall(function() row.toggle:SetVisible(false) end)
                    pcall(function() row.input:SetVisible(false) end)
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
        local txt
        if want == 0 then
            txt = string.format("%s：未设定", cal.label)
        else
            txt = string.format("%s：%d / %d", cal.label, got, want)
        end
        if soldN > 0 then txt = txt .. string.format("（%d 售罄）", soldN) end
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

    if S.needRescan or (not S.ready) then
        if not S.scanning then
            S.lastMsg = "扫描商品中…"
            task.spawn(scanAll)
        end
        return
    end

    if not S.running then return end

    if not hasAnyTarget() then
        S.lastMsg = "未设定任何目标"
        return
    end

    if not anyPending() then
        S.lastMsg = "全部达标"
        S.waitingRestock = false
        return
    end

    for _, cal in ipairs(CALIBERS) do
        local list = S.products[cal.id] or {}
        local seen = {}
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
                            local ok, got, why = buyFromOffer(cal, offer, packsNeeded)
                            if ok then
                                S.waitingRestock = false
                                S.bought = S.bought + got
                                S.boughtBy[p.name] = (S.boughtBy[p.name] or 0) + got
                                S.spent = S.spent + offer.perRound * got
                                offer.stock = math.max(0, offer.stock - math.max(1, math.floor(got / offer.count)))
                                if offer.stock == 0 then offer.soldOut = true end
                                log(string.format("买入 %s x%d包 = %d发（%s/发）｜本弹种 %d/%d",
                                    offer.name, math.max(1, math.floor(got / offer.count)), got,
                                    money(offer.perRound),
                                    S.boughtBy[p.name], tonumber(CFG.targets[p.name]) or 0))
                                return
                            else
                                S.lastMsg = "跳过 " .. offer.name .. "：" .. tostring(why)
                            end
                        end
                    end
                end
            end
        end
    end

    -- 一圈没成交 → 等补货
    S.waitingRestock = true
    local remain = restockRemain()
    if remain then
        S.lastMsg = "等待补货 " .. fmtTime(remain)
    elseif S.restockText ~= "" then
        S.lastMsg = "等待补货（面板未打开）"
    else
        S.lastMsg = "等待补货"
    end

    local now = os.clock()
    local due = (now >= S.nextRescanAt) or (remain ~= nil and remain <= 3)
    if due and not S.scanning then
        S.nextRescanAt = now + 25
        task.spawn(scanAll)
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

local uiOK = buildUI()
if not uiOK then
    log("UI 未就绪，后台购买仍可用（_G.HUSH_AMMO）")
end

-- 配置改动后 1.5 秒落盘，避免拖滑块时狂写文件
task.spawn(function()
    while not S.dead do
        if S.savePending and (os.clock() - S.lastSaveAt) > 1.5 then
            saveConfig()
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
    if isLobby() then pcall(scanAll) end
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
    scan = scanAll,
    readRestock = readRestock,
    restockRemain = restockRemain,
    saveConfig = saveConfig,
    loadConfig = loadConfig,
    start = function()
        S.running = true
        if P.toggleRun then pcall(function() P.toggleRun:SetValue(true) end) end
    end,
    stop = function()
        S.running = false
        if P.toggleRun then pcall(function() P.toggleRun:SetValue(false) end) end
    end,
    setTarget = function(name, n)
        CFG.targets[name] = math.max(0, math.floor(tonumber(n) or 0))
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
        pcall(saveConfig)
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

log("v3 已加载 · RightCtrl 开关窗口")
