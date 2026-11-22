--[[
    HUSH 弹药自动购买 v1  (Potassium / autoexec)
    ─────────────────────────────────────────────
    用途
      · 放在 autoexec，进大厅后自动就绪
      · 自动点掉过场 SKIP、自动关闭 SALE 广告（只点 LATER，绝不点 VIEW SALE）
      · 面板勾选口径 / 弹种 / 阈值，自动在 Gunner 处买满

    实测依据（2026-11-22，place 91445552037955 / Menu，Potassium v2.7.0）
      · 大厅不跑反作弊检测：AcRules 92 条里无 market/shop/trade/buy 规则；
        唯一相关是 remote.rate = 300 次 / 10 秒（w=2），UI 点击远低于此
      · 购买实现（MenuTraders:2678 buyNow）：
          u66.op({ op="buy", trader=<id>, offer=<key>, count=clamp(1,50) })
        count 是「包数」不是发数；没有二次确认；同一 offer 有 4 秒客户端冷却
      · 口径筛选芯片：FilterBox.Calibres.F_cal_{12ga,308,9mm,45,357,556,762,bolt}
      · 商品卡片：Body.Offers 下的 TextButton，含
          Name(全名) / Short(简称) / Count(x包量) / Price / Label(N / M LEFT)
      · 详情面板：Detail.Panel.Content.Foot → Qty(属性 Qty / QtyMax) / BuyButton
      · 同一个弹种可能有多个挂牌（不同价、不同包量），直接挑每发单价最低的有货项
      · 阈值是「至少买够」：最后一包超出阈值也照买

    注意
      · 阈值按「本次已购买发数」计，不是库存总量（游戏没暴露简单库存接口）
      · Potassium 的文件 API 会直接终止线程，所以配置不落盘，重载需重选
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")

local lp = Players.LocalPlayer

------------------------------------------------------------------
-- 配置
------------------------------------------------------------------
local CFG = {
    threshold = 1000,      -- 本次购买目标发数
    maxSpend = 0,          -- 0 = 不限制；>0 时超过该金额停止
    buyGap = 4.25,         -- 同一 offer 冷却 4s，留点余量
    chipWait = 0.35,       -- 切口径后等列表重建
    selectWait = 0.4,      -- 选中商品后等详情刷新
    tickGap = 0.35,
}

-- 口径 → 芯片名（顺序即面板顺序）
local CALIBERS = {
    { id = "12ga",  chip = "F_cal_12ga",  label = "12GA" },
    { id = "308",   chip = "F_cal_308",   label = ".308" },
    { id = "9mm",   chip = "F_cal_9mm",   label = "9MM" },
    { id = "45",    chip = "F_cal_45",    label = ".45" },
    { id = "357",   chip = "F_cal_357",   label = ".357" },
    { id = "556",   chip = "F_cal_556",   label = "5.56" },
    { id = "762",   chip = "F_cal_762",   label = "7.62" },
    { id = "bolt",  chip = "F_cal_bolt",  label = "BOLT" },
}

------------------------------------------------------------------
-- 状态
------------------------------------------------------------------
local S = {
    running = false,
    bought = 0,            -- 本次已买发数
    spent = 0,             -- 本次已花金额
    lastMsg = "空闲",
    products = {},         -- [calId] = { {name, short, key, count, price, stock, perRound} }
    selected = {},         -- [productName] = true
    lastBuyAt = {},        -- [offerKey] = os.clock()
    scanning = false,
    ready = false,
    waitingRestock = false,   -- 买空后等待补货
    restockText = "",         -- "Restock in 12:44"
    nextRescanAt = 0,
}

-- 面板句柄（提前声明，scanAll 会回调 P.rebuild）
local P = { gui = nil, frame = nil, rows = {}, visible = true, status = nil, boughtLbl = nil }

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
            -- 按钮自身文本
            if string.upper(textOf(d)) == want then return click(d), d end
            -- 子 TextLabel
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

    -- 过场动画的 SKIP（右下角）
    for _, guiName in ipairs({ "HushMenuFade", "HushTouch", "HushTransit" }) do
        local g = pg:FindFirstChild(guiName)
        if g and g.Enabled then
            local ok, btn = clickByText(g, "SKIP")
            if ok then log("已点 SKIP") end
        end
    end

    -- SALE / 礼包广告：只点 LATER，绝不点 VIEW SALE
    local modal = pg:FindFirstChild("HushModal")
    if modal then
        for _, d in ipairs(modal:GetDescendants()) do
            if d:IsA("TextButton") then
                local hit = false
                if string.upper(textOf(d)) == "LATER" then hit = true end
                if not hit then
                    for _, c in ipairs(d:GetDescendants()) do
                        if c:IsA("TextLabel") and string.upper(textOf(c)) == "LATER" then hit = true break end
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
-- 扫描商品
------------------------------------------------------------------
-- 读商人整体补货倒计时："Restock in 12:44" / "在 13:54 时间内重新补货"
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
            -- "3 / 3 LEFT" → 取左侧数字为剩余
            local stock = 0
            do
                local l = labels["label"] or ""
                local a, b = l:match("(%d+)%s*/%s*(%d+)")
                if a then stock = tonumber(a) elseif b then stock = tonumber(b) end
            end
            if full ~= "" and count > 0 then
                out[#out + 1] = {
                    key = o.Name,
                    name = full,
                    short = short,
                    count = count,
                    price = price,
                    stock = stock,
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
    for _, cal in ipairs(CALIBERS) do
        local ok, res = pcall(scanCaliber, cal)
        S.products[cal.id] = (ok and res) or {}
    end
    S.scanning = false
    S.ready = true
    if P.rebuild then pcall(P.rebuild) end
    local total = 0
    for _, v in pairs(S.products) do total = total + #v end
    log("扫描完成，共 " .. total .. " 个挂牌")
end

------------------------------------------------------------------
-- 购买
------------------------------------------------------------------
local function pickBestOffers(calId, productName)
    local list = S.products[calId] or {}
    local hits = {}
    for _, p in ipairs(list) do
        if p.name == productName and p.stock > 0 then hits[#hits + 1] = p end
    end
    table.sort(hits, function(a, b) return a.perRound < b.perRound end)
    return hits
end

-- 返回: ok, 已买发数
local function buyFromOffer(cal, offer, packsWanted)
    local body = tradersBody()
    if not body then return false, 0, "找不到交易面板" end

    -- 切口径
    local calBox = body.FilterBox:FindFirstChild("Calibres")
    local chip = calBox and calBox:FindFirstChild(cal.chip)
    if chip then click(chip) task.wait(CFG.chipWait) end

    -- 选中商品
    local card = body.Offers:FindFirstChild(offer.key)
    if not card then return false, 0, "卡片不存在" end
    click(card)
    task.wait(CFG.selectWait)

    local detail = body.Detail.Panel.Content
    local qtyFrame = detail.Foot:FindFirstChild("Qty")
    if not qtyFrame then return false, 0, "无数量控件" end

    local maxPacks = tonumber(get(qtyFrame, "QtyMax")) or 1
    local packs = math.min(packsWanted, maxPacks, 50)
    if packs < 1 then return false, 0, "数量为0" end

    -- 设数量：点 QtyMax 再减到目标值，比连点加号稳
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

    -- 购买
    local buyBtn = detail.Foot:FindFirstChild("BuyButton")
    if not buyBtn then return false, 0, "无购买按钮" end
    local label = textOf(buyBtn.Inner and buyBtn.Inner:FindFirstChild("Text"))
    if label and (label:lower():find("locked") or label:lower():find("sold") or label:lower():find("full")) then
        return false, 0, "按钮不可用:" .. label
    end

    click(buyBtn)
    S.lastBuyAt[offer.key] = os.clock()
    return true, packs * offer.count, "已下单"
end

------------------------------------------------------------------
-- 面板
------------------------------------------------------------------

local function mk(className, props, parent)
    local o = Instance.new(className)
    for k, v in pairs(props) do
        if k ~= "Parent" then pcall(function() o[k] = v end) end
    end
    o.Parent = parent
    return o
end

local function buildPanel()
P.rebuild = rebuildList
    local host = (gethui and gethui()) or game:GetService("CoreGui")
    local old = host:FindFirstChild("HushAmmo")
    if old then old:Destroy() end

    local g = mk("ScreenGui", {
        Name = "HushAmmo",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 880,
    }, (gethui and gethui()) or game:GetService("CoreGui"))

    local f = mk("Frame", {
        Size = UDim2.new(0, 360, 0, 430),
        Position = UDim2.new(0, 40, 0, 120),
        BackgroundColor3 = Color3.fromRGB(16, 18, 22),
        BackgroundTransparency = 0.05,
        BorderSizePixel = 0,
        Active = true,
    }, g)
    mk("UICorner", { CornerRadius = UDim.new(0, 8) }, f)
    mk("UIStroke", { Color = Color3.fromRGB(58, 64, 76), Thickness = 1 }, f)

    local head = mk("TextButton", {
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundColor3 = Color3.fromRGB(28, 32, 39),
        BorderSizePixel = 0,
        Text = "  弹药自动购买  ·  拖动移动",
        TextColor3 = Color3.fromRGB(150, 220, 210),
        TextSize = 13,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = false,
        Active = true,
    }, f)
    mk("UICorner", { CornerRadius = UDim.new(0, 8) }, head)

    local drag, dragStart, startPos = false, nil, nil
    head.InputBegan:Connect(function(i)
        local t = i.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
            drag, dragStart, startPos = true, i.Position, f.Position
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if not drag then return end
        local t = i.UserInputType
        if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
            local d = i.Position - dragStart
            f.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        local t = i.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then drag = false end
    end)

    P.status = mk("TextLabel", {
        Size = UDim2.new(1, -16, 0, 18),
        Position = UDim2.new(0, 8, 0, 32),
        BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(200, 208, 220),
        Text = "初始化…",
    }, f)

    P.boughtLbl = mk("TextLabel", {
        Size = UDim2.new(1, -16, 0, 16),
        Position = UDim2.new(0, 8, 0, 50),
        BackgroundTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.Code,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(140, 200, 160),
        Text = "已买 0 发 / 目标 " .. CFG.threshold,
    }, f)

    -- 阈值控件
    local thrRow = mk("Frame", {
        Size = UDim2.new(1, -16, 0, 24),
        Position = UDim2.new(0, 8, 0, 68),
        BackgroundTransparency = 1,
    }, f)
    mk("TextLabel", {
        Size = UDim2.new(0, 40, 1, 0), BackgroundTransparency = 1,
        Text = "阈值", Font = Enum.Font.Code, TextSize = 12,
        TextColor3 = Color3.fromRGB(170, 178, 192), TextXAlignment = Enum.TextXAlignment.Left,
    }, thrRow)
    local thrLbl = mk("TextLabel", {
        Size = UDim2.new(0, 64, 1, 0), Position = UDim2.new(0, 42, 0, 0),
        BackgroundTransparency = 1, Text = tostring(CFG.threshold),
        Font = Enum.Font.Code, TextSize = 13, TextColor3 = Color3.fromRGB(255, 210, 120),
        TextXAlignment = Enum.TextXAlignment.Center,
    }, thrRow)
    local function stepBtn(txt, x, delta)
        local b = mk("TextButton", {
            Size = UDim2.new(0, 30, 1, 0), Position = UDim2.new(0, x, 0, 0),
            BackgroundColor3 = Color3.fromRGB(52, 58, 70), BorderSizePixel = 0,
            Text = txt, TextSize = 13, TextColor3 = Color3.fromRGB(230, 235, 240),
            Font = Enum.Font.GothamBold,
        }, thrRow)
        mk("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
        b.Activated:Connect(function()
            CFG.threshold = math.max(10, CFG.threshold + delta)
            thrLbl.Text = tostring(CFG.threshold)
            P.boughtLbl.Text = string.format("已买 %d 发 / 目标 %d", S.bought, CFG.threshold)
        end)
    end
    stepBtn("-100", 112, -100)
    stepBtn("-10", 146, -10)
    stepBtn("+10", 180, 10)
    stepBtn("+100", 214, 100)

    -- 商品勾选区
    local scroll = mk("ScrollingFrame", {
        Size = UDim2.new(1, -16, 0, 236),
        Position = UDim2.new(0, 8, 0, 96),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, f)
    mk("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)

    -- 底部按钮
    local function footBtn(txt, x, w, col, fn)
        local b = mk("TextButton", {
            Size = UDim2.new(0, w, 0, 26), Position = UDim2.new(0, x, 1, -34),
            BackgroundColor3 = col, BorderSizePixel = 0, Text = txt,
            TextSize = 12, TextColor3 = Color3.fromRGB(235, 240, 245),
            Font = Enum.Font.GothamMedium,
        }, f)
        mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
        b.Activated:Connect(fn)
        return b
    end
    footBtn("开始", 8, 62, Color3.fromRGB(44, 116, 92), function()
        S.running = true
        log("开始")
    end)
    footBtn("停止", 74, 62, Color3.fromRGB(120, 68, 44), function()
        S.running = false
        log("已停止")
    end)
    footBtn("重置", 140, 62, Color3.fromRGB(56, 62, 74), function()
        S.bought, S.spent, S.lastBuyAt = 0, 0, {}
        log("已重置计数")
    end)
    footBtn("重扫", 206, 62, Color3.fromRGB(56, 62, 74), function()
        S.ready = false
        task.spawn(scanAll)
    end)
    footBtn("隐藏", 272, 74, Color3.fromRGB(56, 62, 74), function()
        P.visible = not P.visible
        f.Visible = P.visible
    end)

    P.gui, P.frame, P.scroll = g, f, scroll
end

local function rebuildList()
    if not P.scroll then return end
    for _, c in ipairs(P.scroll:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
    end
    P.rows = {}

    local order = 0
    for _, cal in ipairs(CALIBERS) do
        local list = S.products[cal.id] or {}
        if #list > 0 then
            order = order + 1
            local hdr = mk("TextLabel", {
                Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
                Text = "── " .. cal.label .. " ──", Font = Enum.Font.Code, TextSize = 11,
                TextColor3 = Color3.fromRGB(120, 200, 190), TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = order,
            }, P.scroll)

            -- 按商品名去重
            local seen, names = {}, {}
            for _, p in ipairs(list) do
                if not seen[p.name] then seen[p.name] = true; names[#names + 1] = p.name end
            end
            table.sort(names)

            for _, nm in ipairs(names) do
                order = order + 1
                local best = pickBestOffers(cal.id, nm)[1]
                local priceTxt = best and string.format("$%.0f/发", best.perRound) or "无货"
                local b = mk("TextButton", {
                    Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1,
                    Text = string.format("%s  %s  %s", S.selected[nm] and "[x]" or "[ ]", nm, priceTxt),
                    Font = Enum.Font.Code, TextSize = 11,
                    TextColor3 = S.selected[nm] and Color3.fromRGB(150, 230, 170) or Color3.fromRGB(165, 172, 186),
                    TextXAlignment = Enum.TextXAlignment.Left,
                    LayoutOrder = order,
                }, P.scroll)
                b.Activated:Connect(function()
                    S.selected[nm] = not S.selected[nm]
                    b.Text = string.format("%s  %s  %s", S.selected[nm] and "[x]" or "[ ]", nm, priceTxt)
                    b.TextColor3 = S.selected[nm] and Color3.fromRGB(150, 230, 170) or Color3.fromRGB(165, 172, 186)
                end)
                P.rows[#P.rows + 1] = b
            end
        end
    end
end

------------------------------------------------------------------
-- 主循环
------------------------------------------------------------------
local function updateStatus()
    if not P.status then return end
    local head = S.running and (S.waitingRestock and S.lastMsg or "运行中") or S.lastMsg
    P.status.Text = string.format("%s | 已买 %d 发 | 花 $%d", head, S.bought, math.floor(S.spent))
    if P.boughtLbl then
        P.boughtLbl.Text = string.format("已买 %d 发 / 目标 %d", S.bought, CFG.threshold)
    end
end

local function step()
    autoDismiss()

    if not isLobby() then
        S.lastMsg = "等待进入大厅"
        return
    end

    if not S.ready then
        S.lastMsg = "扫描商品中…"
        if not S.scanning then task.spawn(scanAll) end
        return
    end

    if not S.running then return end
    if S.bought >= CFG.threshold then
        S.running = false
        S.lastMsg = "已达阈值，停止"
        log(S.lastMsg)
        return
    end
    if CFG.maxSpend > 0 and S.spent >= CFG.maxSpend then
        S.running = false
        S.lastMsg = "已达花费上限，停止"
        log(S.lastMsg)
        return
    end

    -- 按口径顺序 × 商品顺序买，每次只成交一笔就退出，交给下一轮 tick
    for _, cal in ipairs(CALIBERS) do
        local list = S.products[cal.id] or {}
        local seen = {}
        for _, p in ipairs(list) do
            if S.selected[p.name] and not seen[p.name] then
                seen[p.name] = true
                local remain = CFG.threshold - S.bought
                if remain <= 0 then return end
                -- 简单粗暴：有货的里面挑每发最便宜的，超阈值不管
                local offer = pickBestOffers(cal.id, p.name)[1]
                if offer then
                    local cd = S.lastBuyAt[offer.key]
                    if not cd or (os.clock() - cd) >= CFG.buyGap then
                        local packsNeeded = math.ceil(remain / math.max(1, offer.count))
                        local ok, got, why = buyFromOffer(cal, offer, packsNeeded)
                        if ok then
                            S.waitingRestock = false
                            S.bought = S.bought + got
                            S.spent = S.spent + offer.perRound * got
                            offer.stock = math.max(0, offer.stock - math.max(1, math.floor(got / offer.count)))
                            log(string.format("买入 %s x%d包 = %d发 (%.1f/发) 累计 %d",
                                offer.name, math.max(1, math.floor(got / offer.count)), got, offer.perRound, S.bought))
                            return
                        else
                            S.lastMsg = "跳过 " .. offer.name .. "：" .. tostring(why)
                        end
                    end
                end
            end
        end
    end

    -- 一圈下来一笔都没成交 → 视为买空，等补货
    S.waitingRestock = true
    local txt, sec = readRestock()
    S.restockText = txt
    if txt ~= "" then
        S.lastMsg = "等待补货 " .. txt:gsub("Restock in ", ""):gsub("在 ", ""):gsub(" 时间内重新补货", "")
    else
        S.lastMsg = "等待补货"
    end

    -- 到点或兜底 25 秒重扫一次，补货一出现就能立刻继续买
    local now = os.clock()
    local due = (now >= S.nextRescanAt) or (sec ~= nil and sec <= 3)
    if due and not S.scanning then
        S.nextRescanAt = now + 25
        task.spawn(scanAll)
    end
end

------------------------------------------------------------------
-- 启动
------------------------------------------------------------------
buildPanel()

task.spawn(function()
    while true do
        local ok, err = pcall(step)
        if not ok then log("STEP_ERR " .. tostring(err)) end
        pcall(updateStatus)
        task.wait(CFG.tickGap)
    end
end)

-- 扫描完成后刷新列表
task.spawn(function()
    while true do
        task.wait(1)
        if S.ready and #(P.rows or {}) == 0 and P.scroll then
            pcall(rebuildList)
        end
    end
end)

_G.HUSH_AMMO = {
    state = S,
    cfg = CFG,
    panel = P,
    scan = scanAll,
    rebuild = rebuildList,
    readRestock = readRestock,
    start = function() S.running = true end,
    stop = function() S.running = false end,
}

log("v1 已加载，等待大厅就绪")
