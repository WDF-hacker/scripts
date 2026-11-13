--[[
    HUSH 市场补货自动抢购 v3
    ────────────────────────────────────────────────
    优先级：GL-40 → GL-1 → 40mm High Explosive(拉满) → 40mm Breaching Slug
    黑名单：名字含 "Golden" 的一律跳过

    实测依据（2026-11-13，place 91445552037955 / Menu）
      · 大厅不跑反作弊：AcClient / AcBeat 存在但 getscriptthread = nil
      · 购买不发独立 remote，走 net.fire("menu.op", {...})，op 动态拼接
      · 因此不构造 remote，只点 UI —— 与真人操作同一代码路径
      · 同一个 BUY 按钮点两次：第 1 次 armed，第 2 次在窗口内才下单
        RS_TIME：confirmGuard 0.4s / confirmLife 6s / sendGap 1.1s
      · Buy / Minus / Plus / Min / Max 全挂 Activated，firesignal 可驱动

    面板：Instance GUI，拖标题栏移动；「测试购买」立即对首个已开售目标尝试下单
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")

local lp = Players.LocalPlayer

--============ 配置 ============
local CFG = {
    -- 顺序即优先级
    targets = {
        { name = "GL-40 Grenade Launcher", max = false, label = "GL-40 榴弹" },
        { name = "GL-1",                   max = false, label = "GL-1" },
        { name = "40mm High Explosive",    max = true,  label = "40mm 高爆(拉满)" },
        { name = "40mm Breaching Slug",    max = false, label = "40mm 破门弹" },
    },
    blacklist = { "golden" },
    autoOpen = true,
    maxRetry = 3,
    armWait = 0.45,     -- > confirmGuard(0.4)
    sendGap = 1.15,     -- > sendGap(1.1)
}

--============ 日志 ============
local LOG = "hush_restock.log"
if not isfile(LOG) then writefile(LOG, "") end
local function log(s)
    pcall(function() appendfile(LOG, os.date("!%H:%M:%S ") .. s .. "\n") end)
end

--============ 状态 ============
local state = {
    running = false,
    done = {},
    attempts = {},
    lastResult = {},
    inflight = {},
    retryAt = {},       -- [name] = 下次允许重试的时间
    lastOpenTry = 0,
}

--============ 读取 UI ============
local function playerGui() return lp:FindFirstChild("PlayerGui") end

local function listCards()
    local pg = playerGui()
    local out = {}
    if not pg then return out end
    for _, d in ipairs(pg:GetDescendants()) do
        if d.Name:match("^RsCard_%d+$") then out[#out + 1] = d end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.Name:match("%d+")) or 0) < (tonumber(b.Name:match("%d+")) or 0)
    end)
    return out
end

local function isBlacklisted(name)
    local low = string.lower(name)
    for _, b in ipairs(CFG.blacklist) do
        if string.find(low, b, 1, true) then return true end
    end
    return false
end

local function btnState(buy)
    if not buy then return nil end
    local ok, conns = pcall(getconnections, buy.Activated)
    if not ok or type(conns) ~= "table" then return nil end
    for _, c in ipairs(conns) do
        local ok2, uvs = pcall(function() return debug.getupvalues(c.Function) end)
        if ok2 and type(uvs) == "table" then
            for _, u in ipairs(uvs) do
                if type(u) == "table" and type(u.enabled) == "boolean" then return u end
            end
        end
    end
    return nil
end

local function click(btn)
    if not btn then return false end
    local ok = pcall(firesignal, btn.Activated)
    if ok then return true end
    local okc, conns = pcall(getconnections, btn.Activated)
    if not okc then return false end
    for _, c in ipairs(conns) do pcall(function() c.Function(btn) end) end
    return true
end

local function tryOpenRestock()
    local now = os.clock()
    if now - state.lastOpenTry < 2 then return false end
    state.lastOpenTry = now
    local pg = playerGui()
    if not pg then return false end
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("TextButton") then
            if string.find(string.upper(tostring(d.Text)), "VIEW RESTOCK", 1, true) then
                click(d)
                log("点击 VIEW RESTOCK")
                return true
            end
        end
    end
    return false
end

-- 从 Status 文本里解析 "Opens in 9:01" / "Opens in 01:09:00" 这类倒计时
local function parseCountdown(txt)
    if type(txt) ~= "string" then return nil end
    local a, b, c = string.match(txt, "(%d+):(%d+):(%d+)")
    if a then return tonumber(a) * 3600 + tonumber(b) * 60 + tonumber(c) end
    local m, sec = string.match(txt, "(%d+):(%d+)")
    if m then return tonumber(m) * 60 + tonumber(sec) end
    return nil
end

local function fmtCountdown(sec)
    if not sec then return "--:--" end
    if sec < 0 then sec = 0 end
    local m = math.floor(sec / 60)
    local s = math.floor(sec % 60)
    if m >= 60 then
        return string.format("%d:%02d:%02d", math.floor(m / 60), m % 60, s)
    end
    return string.format("%02d:%02d", m, s)
end

-- Left 文本两种形态：
--   "You can still buy N. Resets in ..."        -> 还能买 N 件
--   "You reached your limit of N per hour..."   -> 已经买满，返回 0
local function parseLeftCount(txt)
    if type(txt) ~= "string" then return nil end
    local n = string.match(txt, "still buy (%d+)")
    if n then return tonumber(n) end
    if string.find(string.lower(txt), "reached your limit", 1, true) then return 0 end
    return nil
end

local function snapshot()
    local cards = {}
    for _, c in ipairs(listCards()) do
        local buy = c:FindFirstChild("Buy")
        local st = buy and btnState(buy)
        local nl = c:FindFirstChild("Name")
        local statusLbl = c:FindFirstChild("Status")
        local leftLbl = c:FindFirstChild("Left")
        local raw = statusLbl and statusLbl.Text or nil
        cards[#cards + 1] = {
            obj = c,
            name = nl and nl.Text or c.Name,
            buy = buy,
            enabled = (st and st.enabled == true) or false,
            cd = parseCountdown(raw),                                  -- Opens in …  = 真正开售
            resetCd = leftLbl and parseCountdown(leftLbl.Text) or nil,  -- Resets in … = 限购重置
            stText = raw,
        }
    end
    return cards
end

--============ 购买 ============
local function buyOne(item, cards)
    local name = item.name
    if isBlacklisted(name) then return "跳过" end

    cards = cards or snapshot()
    local rec
    for _, c in ipairs(cards) do
        if c.name == name then rec = c break end
    end
    if not rec then return "无卡片" end

    local card, buy = rec.obj, rec.buy
    if not buy then return "无按钮" end

    -- 需要拉满的先点 MAX
    if item.max then
        local stepper = card:FindFirstChild("Stepper")
        local mx = stepper and stepper:FindFirstChild("Max")
        if mx then
            click(mx)
            task.wait(0.08)
        end
    end

    if not rec.enabled then return "未开售" end

    local leftLbl = card:FindFirstChild("Left")
    local statusLbl = card:FindFirstChild("Status")
    local before = parseLeftCount(leftLbl and leftLbl.Text)

    click(buy)                 -- 第 1 次：arm
    task.wait(CFG.armWait)
    click(buy)                 -- 第 2 次：确认下单

    -- 结算方式有两种，成功判据也不同：
    --   直接掉落：限购余量下降
    --   抽签（"The draw closes in 4 s" -> "Getting your share..."）：
    --     Status 变成 "Bought: N x ..."，可能延迟 5 秒以上才出结果
    -- Why=OK 只是客户端发出去，不能当成功；SOLD_OUT / HELD / CAP / CASH 都是失败。
    local deadline = os.clock() + 12
    while os.clock() < deadline do
        task.wait(0.25)

        local stTxt = tostring(statusLbl and statusLbl.Text or "")
        if string.find(stTxt, "Bought:", 1, true)
            or string.find(string.lower(stTxt), "reached your limit", 1, true) then
            return "已下单"
        end

        local nowN = parseLeftCount(leftLbl and leftLbl.Text)
        if before ~= nil and nowN ~= nil and nowN < before then return "已下单" end

        local why = tostring(buy:GetAttribute("Why") or "")
        if why == "CASH" then return "资金不足" end
        if why == "SOLD_OUT" then return "已售罄" end
        if why == "CAP" then return "已达上限" end
        if why == "COOLDOWN" or why == "GAP" then
            -- 正常节流，继续等结果，不算失败
        elseif why == "HELD" then
            return "保留中"
        end
    end
    return "超时"
end

--============ 面板 ============
local PANEL = { gui = nil, frame = nil, labels = {}, buttons = {}, visible = true }

local function buildUI()
    local ok = pcall(function()
        local g = Instance.new("ScreenGui")
        g.Name = "HushRestock"
        g.ResetOnSpawn = false
        g.IgnoreGuiInset = true
        g.DisplayOrder = 900
        g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        g.Parent = (gethui and gethui()) or game:GetService("CoreGui")

        local f = Instance.new("Frame")
        f.Size = UDim2.new(0, 408, 0, 252)
        f.Position = UDim2.new(0, 30, 0, 210)
        f.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
        f.BackgroundTransparency = 0.06
        f.BorderSizePixel = 0
        f.Active = true
        f.Parent = g
        local c1 = Instance.new("UICorner"); c1.CornerRadius = UDim.new(0, 8); c1.Parent = f
        local s1 = Instance.new("UIStroke"); s1.Color = Color3.fromRGB(60, 66, 78); s1.Thickness = 1; s1.Parent = f

        local head = Instance.new("TextButton")
        head.Size = UDim2.new(1, 0, 0, 30)
        head.BackgroundColor3 = Color3.fromRGB(30, 34, 41)
        head.BorderSizePixel = 0
        head.Text = "  补货抢购 v3   ·   拖动这里移动"
        head.TextColor3 = Color3.fromRGB(150, 220, 210)
        head.TextSize = 13
        head.Font = Enum.Font.GothamBold
        head.TextXAlignment = Enum.TextXAlignment.Left
        head.AutoButtonColor = false
        head.Active = true
        head.Parent = f
        local ch = Instance.new("UICorner"); ch.CornerRadius = UDim.new(0, 8); ch.Parent = head

        -- 拖动
        local dragging, dragStart, startPos = false, nil, nil
        head.InputBegan:Connect(function(input)
            local t = input.UserInputType
            if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
                dragging = true
                dragStart = input.Position
                startPos = f.Position
            end
        end)
        UIS.InputChanged:Connect(function(input)
            if not dragging then return end
            local t = input.UserInputType
            if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
                local d = input.Position - dragStart
                f.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + d.X,
                    startPos.Y.Scale, startPos.Y.Offset + d.Y
                )
            end
        end)
        UIS.InputEnded:Connect(function(input)
            local t = input.UserInputType
            if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
                dragging = false
            end
        end)

        local status = Instance.new("TextLabel")
        status.Name = "Status"
        status.Size = UDim2.new(1, -16, 0, 26)
        status.Position = UDim2.new(0, 8, 0, 34)
        status.BackgroundTransparency = 1
        status.TextXAlignment = Enum.TextXAlignment.Left
        status.TextYAlignment = Enum.TextYAlignment.Top
        status.Font = Enum.Font.Code
        status.TextSize = 12
        status.TextColor3 = Color3.fromRGB(200, 208, 220)
        status.Text = "初始化…"
        status.Parent = f

        for i, item in ipairs(CFG.targets) do
            local l = Instance.new("TextLabel")
            l.Size = UDim2.new(1, -16, 0, 18)
            l.Position = UDim2.new(0, 8, 0, 64 + (i - 1) * 18)
            l.BackgroundTransparency = 1
            l.TextXAlignment = Enum.TextXAlignment.Left
            l.Font = Enum.Font.Code
            l.TextSize = 11
            l.TextColor3 = Color3.fromRGB(150, 160, 175)
            l.Text = string.format("%d. %s", i, item.label)
            l.Parent = f
            PANEL.labels[i] = l
        end

        local function mkBtn(text, x, w, color, fn)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(0, w, 0, 28)
            b.Position = UDim2.new(0, x, 1, -38)
            b.BackgroundColor3 = color
            b.BorderSizePixel = 0
            b.Text = text
            b.TextColor3 = Color3.fromRGB(235, 240, 245)
            b.TextSize = 12
            b.Font = Enum.Font.GothamMedium
            b.Parent = f
            local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = b
            b.Activated:Connect(fn)
            return b
        end

        PANEL.buttons.run = mkBtn("开始", 8, 66, Color3.fromRGB(46, 120, 96), function()
            state.running = not state.running
            PANEL.buttons.run.Text = state.running and "暂停" or "开始"
            log("running=" .. tostring(state.running))
        end)

        PANEL.buttons.test = mkBtn("测试点一次", 80, 82, Color3.fromRGB(122, 84, 40), function()
            -- 只点一次 BUY，看按钮有没有反应（不进入确认，不会下单）
            local cards = snapshot()
            local pickItem, pickRec = nil, nil
            for _, item in ipairs(CFG.targets) do
                for _, c in ipairs(cards) do
                    if c.name == item.name then pickItem, pickRec = item, c break end
                end
                if pickItem then break end
            end
            if not pickItem then
                PANEL.buttons.test.Text = "无卡片"
                task.delay(1.3, function() PANEL.buttons.test.Text = "测试点一次" end)
                return
            end

            local btn = pickRec.buy
            local before = btn:GetAttribute("Armed")
            click(btn)
            task.wait(0.25)

            local after = btn:GetAttribute("Armed")
            local why = btn:GetAttribute("Why")
            local st2 = btnState(btn)
            local msg
            if after == true and before ~= true then
                msg = "✓ 已响应(Armed)"                 -- 说明点得动，进入确认态
            elseif why and why ~= "NOT_YET" then
                msg = "✓ " .. tostring(why)              -- 服务端已回应
            elseif st2 and st2.enabled then
                msg = "✓ 已点击(未见变化)"
            else
                msg = "未开售(" .. tostring(why or "disabled") .. ")"
            end
            log(string.format("TEST_CLICK %s -> %s", pickItem.name, msg))
            PANEL.buttons.test.Text = msg:sub(1, 12)
            task.delay(2.0, function() PANEL.buttons.test.Text = "测试点一次" end)
        end)

        PANEL.buttons.reset = mkBtn("重置", 168, 66, Color3.fromRGB(60, 64, 74), function()
            state.done = {}; state.attempts = {}; state.lastResult = {}
            state.inflight = {}; state.retryAt = {}
            log("重置")
        end)

        PANEL.buttons.hide = mkBtn("隐藏", 240, 80, Color3.fromRGB(60, 64, 74), function()
            PANEL.visible = not PANEL.visible
            f.Visible = PANEL.visible
        end)

        PANEL.gui, PANEL.frame = g, f
    end)
    if not ok then log("UI_BUILD_FAIL") end
end

local function setStatus(s)
    if PANEL.frame then
        local l = PANEL.frame:FindFirstChild("Status")
        if l and l.Text ~= s then l.Text = s end
    end
end

--============ 主循环 ============
local function step()
    local cards = snapshot()
    PANEL.cards = cards

    if #cards == 0 then
        if CFG.autoOpen then tryOpenRestock() end
        setStatus("等待卡片：请打开 Blackmarket → VIEW RESTOCK")
        return
    end

    local openN = 0
    for _, c in ipairs(cards) do if c.enabled then openN = openN + 1 end end

    -- 逐行渲染：已完成的标绿，其余显示实时倒计时
    local nearest = nil
    for i, item in ipairs(CFG.targets) do
        local l = PANEL.labels[i]
        if l then
            local rec
            for _, c in ipairs(cards) do
                if c.name == item.name then rec = c break end
            end

            local txt, col
            if state.done[item.name] then
                txt, col = string.format("%d. %s  ✓ 已下单", i, item.label), Color3.fromRGB(120, 220, 150)
            elseif rec and rec.enabled then
                txt, col = string.format("%d. %s  ● 已开售", i, item.label), Color3.fromRGB(255, 210, 120)
            elseif rec and rec.cd then
                if not nearest or rec.cd < nearest then nearest = rec.cd end
                txt = string.format("%d. %-12s ⏱%s  ↻%s", i, item.label,
                    fmtCountdown(rec.cd), fmtCountdown(rec.resetCd))
                col = (rec.cd <= 10) and Color3.fromRGB(255, 200, 90) or Color3.fromRGB(150, 160, 175)
            elseif not rec then
                txt, col = string.format("%d. %s  无卡片", i, item.label), Color3.fromRGB(150, 160, 175)
            else
                txt = string.format("%d. %s  %s", i, item.label,
                    (rec.stText or "等待"):gsub("Opens in ", ""):sub(1, 12))
                col = Color3.fromRGB(150, 160, 175)
            end
            if l.Text ~= txt then l.Text = txt end
            l.TextColor3 = col
        end
    end

    if not state.running then
        setStatus(string.format("已暂停 | 卡片 %d | 已开售 %d | 最近 %s",
            #cards, openN, nearest and fmtCountdown(nearest) or "--:--"))
        return
    end

    local pending = 0
    for _, item in ipairs(CFG.targets) do
        if not state.done[item.name] then pending = pending + 1 end
    end
    if pending == 0 then
        setStatus("全部完成 | 点重置可重抢")
        return
    end

    setStatus(string.format("运行中 | 已开售 %d | 待抢 %d | 最近 %s",
        openN, pending, nearest and fmtCountdown(nearest) or "--:--"))

    -- 严格按数组顺序执行：前一个没结束不会影响后面的优先级判定
    for _, item in ipairs(CFG.targets) do
        local name = item.name
        local ready = (state.retryAt[name] == nil) or (os.clock() >= state.retryAt[name])
        if not state.done[name] and not isBlacklisted(name) and not state.inflight[name] and ready then
            local rec
            for _, c in ipairs(cards) do
                if c.name == name then rec = c break end
            end
            if rec and rec.enabled then
                state.inflight[name] = true
                local res = buyOne(item, cards)
                state.inflight[name] = nil

                if res ~= "未开售" and res ~= "无卡片" then
                    state.attempts[name] = (state.attempts[name] or 0) + 1
                    log(string.format("BUY %s -> %s", name, tostring(res)))

                    if res == "已下单" then
                        state.done[name] = true
                        state.lastResult[name] = "✓ 已下单"
                    else
                        -- 只有「限购余量下降」才算成功，其余一律退避重试
                        local wait = 2
                        if res == "已售罄" then wait = 10
                        elseif res == "保留中" then wait = 6
                        elseif res == "冷却中" then wait = 4
                        elseif res == "资金不足" then wait = 30
                        elseif res == "已达上限" then wait = 60
                        end
                        state.retryAt[name] = os.clock() + wait
                        state.lastResult[name] = res
                        if (state.attempts[name] or 0) >= 12 then
                            state.retryAt[name] = os.clock() + 3600
                            state.lastResult[name] = "放弃 " .. res
                        end
                    end
                    task.wait(CFG.sendGap)
                end
            else
                state.lastResult[name] = "等待开售"
            end
        end
    end
end

--============ 启动 ============
buildUI()
_G.HUSH_RESTOCK = {
    state = state,
    cfg = CFG,
    panel = PANEL,
    start = function() state.running = true end,
    stop = function() state.running = false end,
    reset = function()
        state.done = {}; state.attempts = {}; state.lastResult = {}
        state.inflight = {}; state.retryAt = {}
    end,
    snapshot = snapshot,
    buyOne = buyOne,
}

log(string.format("# SESSION %s user=%s", os.date("!%Y-%m-%dT%H:%M:%S"), lp.Name))
print("[HUSH-RESTOCK] v3 loaded  面板可拖动  「测试购买」立即尝试首个已开售目标")

-- 临近开售时把轮询压到 50ms，尽量贴近开售瞬间；平时 150ms 省性能
local function pollDelay()
    if not state.running then return 0.25 end
    for _, c in ipairs(PANEL.cards or {}) do
        if c.enabled then return 0.08 end
        if c.cd and c.cd <= 3 then return 0.05 end
    end
    return 0.12
end

task.spawn(function()
    while true do
        local ok, err = pcall(step)
        if not ok then log("STEP_ERR " .. tostring(err)) end
        task.wait(pollDelay())
    end
end)
