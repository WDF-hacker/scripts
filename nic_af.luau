--[[
nic_af.luau — "战斗中的新手" (Noobs in Combat, Place 5734383673)
Boot camp / Basic controls 自动刷钱常驻循环
  大厅 → 领邮箱奖励(每日登录) → 建房开局 → 教程通关 → 回大厅 → 循环

机制要点(已验证):
  * InLobby 属性区分 大厅/对局 (workspace:GetAttribute("InLobby"))
  * 邮箱: lobby.inbox_get:FireServer() → 服务器回推 lobby.inbox_update(邮件数组)
    领取 = lobby.inbox_update:FireServer(索引)
  * 建房: lobby.room_create:FireServer({{index="inviteOnly",value=false},{index="groupId",value="Campaign"}})
  * 选图: lobby.room_edit:InvokeServer("map", "Boot camp", 1)  (返回 0=成功, 强制 modeId=5)
  * 开局: lobby.room_start:FireServer()  → teleport 到对局服务器
  * 跳过教程对白: firesignal(Cutscene.Fade) 数次
  * 移动: inGame.actions.Move:FireServer(队id, {tile...})  每回合 1 次移动, MP=2
  * 结束回合: inGame.Voting:FireServer()  (敌回合约 9 秒)
  * 占领: 需新回合(未移动)且与建筑相邻(manhattan==1): inGame.actions.Capture:FireServer(队id, 建筑id)
  * 回大厅: inGame.ReturnBack:FireServer()
  * 结算: WinGui.MainFrame.Title 含 "VICTORY"/"DEFEAT ... turns"
]]

local NIC = _G.NIC_AF
if NIC and NIC.thread then
  local ok, st = pcall(coroutine.status, NIC.thread)
  if ok and st ~= "dead" then
    -- 已有常驻循环在运行(同域防重入)
    return
  end
  -- 旧实例已死(如跨 teleport 后): 重建
  NIC.thread = nil
end

_G.NIC_AF = NIC or {}
local AF = _G.NIC_AF

local CFG = {
  PLACE_ID = 5734383673,
  CAMPAIGN = "Boot camp",
  MAP_INDEX = 1,
  TICK = 0.5,
  TURN_CAP = 24,
  MATCH_IDLE_RESEND = 90,   -- 我方回合卡住超过此秒数 → 补发 Voting
  MATCH_STALL_ABORT = 420,  -- 对局整体无进展超过 → 放弃回大厅
  START_RETRY = 4,          -- room_start 重试次数
  MOVE_RETRY = 4,           -- 单步移动失败尝试其它方向次数
}

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local function log(...)
  local ok, err = pcall(print, "[NIC]", ...)
end

-- ---------------- 通用工具 ----------------

local function getLP()
  return Players.LocalPlayer
end

local function sessFp()
  local lp = getLP()
  if not lp then return nil end
  return tostring(lp) .. "|" .. tostring(game.JobId)
end

local Cache = {}
local Sess = ""

local function refreshSession()
  local fp = sessFp()
  if not fp then return false end
  if fp ~= Sess then
    Sess = fp
    for k in pairs(Cache) do Cache[k] = nil end
    Cache.fp = fp
    log("new session", fp)
  end
  return true
end

local function ws()
  return game:GetService("Workspace")
end

local function conn()
  return RS.Connection
end

local function Loader()
  return require(RS.Modules.Loader)
end

-- 会话级缓存取模块
local function pub(name)
  local ok, mod = pcall(function()
    return Loader():import("public", name)
  end)
  if ok and type(mod) == "table" then return mod end
  return nil
end

-- ---------------- 回合/对局常量 ----------------

local COST = { Road = 1, Plains = 1, Forest = 2 }

local function costOf(terrain)
  return COST[terrain] or 2
end

local function tileObj(x, y, cost, range, occ, terrain)
  return { x = x, y = y, z = 0, moveCost = cost, range = range, occupied = occ, terrain = terrain }
end

-- 实体工具
local function entLoc(e)
  local ok, x, y = pcall(function()
    local a, b = e:getLocation()
    return a, b
  end)
  if not ok then return nil, nil end
  return x, y
end

local function entGet(e, k)
  local ok, v = pcall(function() return e:get(k) end)
  if ok then return v end
  return nil
end

local function manDist(x1, y1, x2, y2)
  return math.abs(x1 - x2) + math.abs(y1 - y2)
end

-- 我方步兵列表(存活/未移动中)
local function myInfantry(Entity)
  local all = Entity:getAll()
  local list = {}
  for _, e in ipairs(all) do
    local ok, team, cls = pcall(function()
      return e:get("teamId"), e.baseStats.class
    end)
    -- teamId 可能为 number 0 或 string "0"
    if ok and tostring(team) == "0" and cls == "Infantry" then
      local hp = entGet(e, "health") or 0
      if hp > 0 then
        list[#list + 1] = e
      end
    end
  end
  return list
end

-- 目标建筑: 优先 NEUTRAL(Outpost) → 其次敌队建筑(补给站); 全我方 → nil
-- 返回: entity, hasNeutral(仍有中立建筑未占)
local function pickTarget(Entity)
  local all = Entity:getAll()
  local neutral, enemy
  local hasNeutral = false
  for _, e in ipairs(all) do
    local ok, cls, team = pcall(function()
      return e.baseStats.class, e:get("teamId")
    end)
    if ok and cls == "Building" then
      local ts = tostring(team)
      if ts ~= "0" then
        if ts == "NEUTRAL" then
          hasNeutral = true
          if not neutral then neutral = e end
        else
          if not enemy then enemy = e end
        end
      end
    end
  end
  return neutral or enemy, hasNeutral
end

-- ---------------- 邮箱(大厅) ----------------

local function lobbyClaimDaily()
  local lc = conn().lobby
  -- 挂接收(每会话重挂)
  if not Cache.inboxConn then
    local ev = lc.inbox_update
    Cache.inboxConn = ev.OnClientEvent:Connect(function(data)
      Cache.inboxData = data
      Cache.inboxGotAt = os.clock()
    end)
  end

  if not Cache.inboxReq then
    lc.inbox_get:FireServer()
    Cache.inboxReq = true
    log("inbox_get sent")
  end

  local data = Cache.inboxData
  if not data then return end

  for i, m in ipairs(data) do
    if not m.claimed and (m.tag == "daily" or m.name == 4 or m.body == 4) and (m.rewards and #m.rewards > 0) then
      local ok, err = pcall(function()
        lc.inbox_update:FireServer(i)
      end)
      log("claim daily idx", i, "ok=", ok)
    end
  end
end

-- ---------------- 大厅流程 ----------------

local function lobbyTick()
  local lp = getLP()
  local pg = lp:FindFirstChild("PlayerGui")
  if not pg then return end
  local lobbyUI = pg:FindFirstChild("LobbyUI")
  if not lobbyUI then
    -- 对局回大厅的加载期
    return
  end

  local st = Cache.lobbyState or "claim"
  local connL = conn().lobby

  if st == "claim" or st == "claim_wait" then
    lobbyClaimDaily()
    Cache.lobbyState = "claim_wait"
    if not Cache.claimAt then Cache.claimAt = os.clock() end
    -- 收到推送(或超时 2s)后进下一步
    if Cache.inboxData ~= nil or os.clock() - Cache.claimAt > 2 then
      Cache.lobbyState = "ensure_room"
      Cache.claimAt = nil
    end
    return
  end

  if st == "ensure_room" or st == "map" or st == "start" then
    local Room = pub("Room")
    if not Room then return end
    local name = lp.Name
    local roomId = Room.players[name]

    if st == "ensure_room" then
      if roomId and roomId ~= "???" then
        Cache.lobbyState = "map"
        return
      end
      -- 创建房间(幂等, 2s 节流; 回显通常 ~1s)
      if not Cache.createAt or os.clock() - Cache.createAt > 2 then
        Cache.createAt = os.clock()
        local ok, err = pcall(function()
          connL.room_create:FireServer({
            { index = "inviteOnly", value = false },
            { index = "groupId", value = "Campaign" },
          })
        end)
        log("room_create ok=", ok)
      end
      return
    end

    if st == "map" then
      if roomId and roomId ~= "???" then
        -- room_edit 是同步 InvokeServer: res==0 = 服务器已设图 → 立即转 start(不等 title 回显)
        if not Cache.mapSentAt or os.clock() - Cache.mapSentAt > 0.8 then
          Cache.mapSentAt = os.clock()
          Cache.mapTries = (Cache.mapTries or 0) + 1
          local ok, res = pcall(function()
            return connL.room_edit:InvokeServer("map", CFG.CAMPAIGN, CFG.MAP_INDEX)
          end)
          log("room_edit map ok=", ok, "res=", tostring(res))
          if ok and res == 0 then
            Cache.lobbyState = "start"
          elseif Cache.mapTries > 8 then
            -- 连续失败(非房主/房间异常): 弃房重来
            log("map select failed, recreate room")
            Cache.lobbyState = nil
            Cache.mapTries = nil
            pcall(function()
              connL.room_leave:InvokeServer()
            end)
          end
        end
      else
        -- 房间还没建立成功, 退回 ensure
        Cache.lobbyState = "ensure_room"
        Cache.mapTries = nil
      end
      return
    end

    if st == "start" then
      local tries = Cache.startTries or 0
      local now2 = os.clock()
      if tries == 0 then
        -- 立即发第一次(不等任何缓冲)
        Cache.startTries = 1
        Cache.startSentAt = now2
        local ok, err = pcall(function()
          connL.room_start:FireServer()
        end)
        log("room_start try 1 ok=", ok)
      elseif tries < CFG.START_RETRY and now2 - (Cache.startSentAt or 0) > 6 then
        Cache.startTries = tries + 1
        Cache.startSentAt = now2
        local ok, err = pcall(function()
          connL.room_start:FireServer()
        end)
        log("room_start try", tries + 1, "ok=", ok)
      elseif tries >= CFG.START_RETRY then
        -- 一直没切对局: 弃房重建
        log("room_start failed after retries, recreate")
        Cache.lobbyState = nil
        Cache.startTries = nil
        Cache.startSentAt = nil
        local ok = pcall(function()
          connL.room_leave:InvokeServer()
        end)
      end
      return
    end
  end
end

-- ---------------- 对局流程 ----------------

local MATCH = {}
local function matchInit()
  local ws = ws()
  local gs = ws:FindFirstChild("GameSettings")
  local lp = getLP()
  local pg = lp and lp:FindFirstChild("PlayerGui")
  local gg = pg and pg:FindFirstChild("GameGui")
  if not (gs and pg and gg) then return false end
  if not pg:FindFirstChild("WinGui") then return false end
  -- 等客户端 Entity 模块可用
  if not pub("Entity") then return false end

  MATCH.stage = "play"
  MATCH.turnNo = 0
  MATCH.lastCti = nil
  MATCH.lastAct = os.clock()
  MATCH.stallAt = os.clock()
  MATCH.voteAt = 0
  MATCH.actedThisTurn = false
  MATCH.endSent = false
  Cache.match = MATCH
  log("match init, stage=play")
  return true
end

-- 结算检测 → true 表示已结束处理
local function matchEnded()
  local lp = getLP()
  local pg = lp and lp:FindFirstChild("PlayerGui")
  local wm = pg and pg:FindFirstChild("WinGui")
  if not wm then return false end
  local mf = wm:FindFirstChild("MainFrame")
  if not mf then return false end
  local title = mf:FindFirstChild("Title")
  if not title then return false end
  local t = tostring(title.Text)

  local realEnd = string.find(t, "VICTORY") ~= nil
  if not realEnd then
    -- 预置文案是 "DEFEAT - 30 days"; 真实失败是 "... turns"
    realEnd = string.find(t, "DEFEAT") ~= nil and string.find(t, "turns") ~= nil
  end
  if not realEnd then return false end

  if not MATCH.endSent then
    MATCH.endSent = true
    log("match over: ", t)
    local ok, err = pcall(function()
      conn().inGame.ReturnBack:FireServer()
    end)
    log("ReturnBack ok=", ok)
  end
  return true
end

-- 通用教程对话秒跳: 任意时刻 Cutscene 显示中(开场/占点后阶段对话)就快速推进
-- 直接调用 CutsceneUI.procced()(共享 require 实例, 绕过 1s 点击 guard) → 秒级跳过
-- 返回 true = 对话仍显示(本 tick 不应做其它行动)
local function skipCutsceneIfAny()
  local lp = getLP()
  local pg = lp and lp:FindFirstChild("PlayerGui")
  if not pg then return false end
  local cs = pg:FindFirstChild("Cutscene")
  if not cs then return false end
  local fade = cs:FindFirstChild("Fade")
  if not fade then return false end
  local okv, vis = pcall(function() return fade.Visible end)
  if not (okv and vis) then return false end
  -- 对话可见 → 秒推进
  local mod = cs:FindFirstChild("CutsceneUI")
  local okM, ret = pcall(function()
    if not mod then return nil end
    return require(mod)
  end)
  if okM and type(ret) == "table" and type(ret.procced) == "function" then
    -- 冒号调用: 直接推进全部段(绕过 1s 点击 guard), 段耗尽后自动 hide
    for _ = 1, 8 do
      local okP = pcall(function() ret:procced() end)
      if not okP then break end
    end
  else
    -- fallback: 点击 Fade
    local ok1 = pcall(function() firesignal(fade.Activated) end)
  end
  log("dialog skip")
  return true
end

-- BFS 寻路: 从 (x,y) 出发, 在 maxCost 成本内找所有可达格,
-- 返回其中离目标 (gx,gy) 最近的格子的路径(tiles 序列, 不含起点)。找不到返回 nil
local function planPath(x, y, gx, gy, maxCost)
  local Grid = pub("Grid3d")
  if not Grid then return nil end
  local function key(nx, ny) return nx .. "," .. ny end
  local function terrAt(nx, ny)
    local at = Grid:getAt("terrain", nx, ny)
    if not at then return nil end
    return at.terrain
  end
  local function occAt(nx, ny)
    local g = Grid:getAt("ground", nx, ny)
    return g ~= nil and type(g) == "table"
  end
  local startK = key(x, y)
  local open = { { x, y, 0 } }
  local head = 1
  local parent = {}
  local costAt = { [startK] = 0 }
  while head <= #open do
    local cur = open[head]
    head = head + 1
    local cx, cy, ccost = cur[1], cur[2], cur[3]
    for _, d in ipairs({ { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } }) do
      local nx, ny = cx + d[1], cy + d[2]
      local k = key(nx, ny)
      if k ~= startK and not parent[k] then
        local terr = terrAt(nx, ny)
        if terr and terr ~= "Void" and not occAt(nx, ny) then
          local c = costOf(terr)
          local nc = ccost + c
          if nc <= maxCost and (costAt[k] == nil or nc < costAt[k]) then
            costAt[k] = nc
            parent[k] = { cx, cy }
            open[#open + 1] = { nx, ny, nc }
          end
        end
      end
    end
  end
  -- 排除被占格(起点之后遍历时可能已标记; 直接过滤一次)
  -- 选终点: 可达且未被占用的格中 manhattan 到目标最小(同距取成本更大的=走得更远)
  local bestK, bestEst, bestCost
  for k, c in pairs(costAt) do
    if k ~= startK then
      local a, b = k:match("^(-?%d+),(-?%d+)$")
      local ax, ay = tonumber(a), tonumber(b)
      if ax and ay and not occAt(ax, ay) then
        local est = math.abs(ax - gx) + math.abs(ay - gy)
        if not bestEst or est < bestEst or (est == bestEst and c > (bestCost or 0)) then
          bestK = k
          bestEst = est
          bestCost = c
        end
      end
    end
  end
  if not bestK then return nil end
  -- 回溯(倒序)再反转为正序
  local rev = {}
  local k = bestK
  local guard = 0
  while parent[k] and guard < 30 do
    local a, b = k:match("^(-?%d+),(-?%d+)$")
    rev[#rev + 1] = { tonumber(a), tonumber(b) }
    local p = parent[k]
    k = p[1] .. "," .. p[2]
    guard = guard + 1
  end
  local tiles = {}
  local acc = 0
  for i = #rev, 1, -1 do
    local g = rev[i]
    local terr = terrAt(g[1], g[2])
    acc = acc + costOf(terr)
    tiles[#tiles + 1] = { x = g[1], y = g[2], terr = terr }
  end
  return tiles, bestCost
end

-- 单步尝试移动: 从 (x,y) 朝 (tx,ty) 移动最多 maxCost, 返回实际终点或 nil(全失败)
local function stepMove(unit, x, y, tx, ty, maxCost)
  local tiles, totalCost = planPath(x, y, tx, ty, maxCost)
  if not tiles or #tiles == 0 then return nil end
  local path = { tileObj(x, y, 0, 0, true, tiles[1].terr and tiles[1].terr or "Plains") }
  -- 注意起点 terrain 应读起点格; 此处用首格 terr 兜底无碍(服务器忽略字段)
  local cost = 0
  for i, t in ipairs(tiles) do
    cost = cost + costOf(t.terr)
    path[#path + 1] = tileObj(t.x, t.y, cost, i, false, t.terr)
  end
  local ok, err = pcall(function()
    conn().inGame.actions.Move:FireServer(tostring(unit.uniqueID), path)
  end)
  if not ok then return nil end
  return tiles[#tiles].x, tiles[#tiles].y
end

-- ============ 固定路线表 (Basic controls 地图固定, 已验证最优) ============
-- key = 当前位置 "x,y", value = 本回合应走的格序列 {x, y, cost}
-- 阶段A: 初始兵 出生(-170,-106) → 西侧绕开敌步兵(-170,-109)/Tankette(-170,-111) → Outpost 北邻(-170,-113)
-- 阶段B: 走 -170 中轴大道(距两侧守卫≥2格, 不触发敌方行动) → 补给站北邻(-170,-119)
local ROUTES = {
  ["-170,-106"] = { { -170, -107, 1 }, { -170, -108, 1 } },
  ["-170,-107"] = { { -170, -108, 1 } },
  ["-170,-108"] = { { -171, -108, 1 }, { -171, -109, 1 } },
  ["-171,-108"] = { { -171, -109, 1 } },
  ["-171,-109"] = { { -171, -110, 1 }, { -171, -111, 1 } },
  ["-171,-110"] = { { -171, -111, 1 } },
  ["-171,-111"] = { { -171, -112, 1 }, { -171, -113, 1 } },
  ["-171,-112"] = { { -171, -113, 1 } },
  ["-171,-113"] = { { -170, -113, 1 } },
  -- 阶段B 新兵并入大道
  ["-171,-115"] = { { -170, -115, 2 } },
  ["-169,-115"] = { { -169, -116, 2 } },
  ["-169,-116"] = { { -170, -116, 1 }, { -170, -117, 1 } },
  ["-170,-115"] = { { -170, -116, 1 }, { -170, -117, 1 } },
  ["-170,-116"] = { { -170, -117, 1 }, { -170, -118, 1 } },
  ["-170,-117"] = { { -170, -118, 1 }, { -170, -119, 1 } },
  ["-170,-118"] = { { -170, -119, 1 } },
}

-- 对某个单位发送一次行动(固定路线/占领/BFS兜底)。返回 true=已发送
local function actOnUnit(u, target, tx, ty)
  local x, y = entLoc(u)
  if not x then return false end
  local uid = tostring(u.uniqueID)

  -- 1) 与目标相邻 → 占领
  if manDist(x, y, tx, ty) == 1 then
    local ok, err = pcall(function()
      conn().inGame.actions.Capture:FireServer(uid, tostring(target.uniqueID))
    end)
    log("capture unit", uid, "->", target.uniqueID, "ok=", ok)
    return true
  end

  -- 2) 固定路线(当前位置查表)
  local route = ROUTES[x .. "," .. y]
  if route then
    local path = { tileObj(x, y, 0, 0, true, "Road") }
    local cost = 0
    for i, r in ipairs(route) do
      cost = cost + r[3]
      path[#path + 1] = tileObj(r[1], r[2], cost, i, false, "Plains")
    end
    local ok, err = pcall(function()
      conn().inGame.actions.Move:FireServer(uid, path)
    end)
    log("route move", uid, "->", route[#route][1], route[#route][2], "ok=", ok)
    return ok
  end

  -- 3) BFS 兜底(异常位置/被堵): 朝目标推进最多 2 点
  local mp = entGet(u, "movePoints") or 0
  local tiles = planPath(x, y, tx, ty, math.min(mp, 2))
  if tiles and #tiles > 0 then
    local path = { tileObj(x, y, 0, 0, true, "Road") }
    local cost = 0
    for i, t in ipairs(tiles) do
      cost = cost + costOf(t.terr)
      path[#path + 1] = tileObj(t.x, t.y, cost, i, false, t.terr)
    end
    local ok, err = pcall(function()
      conn().inGame.actions.Move:FireServer(uid, path)
    end)
    log("bfs move", uid, "->", tiles[#tiles].x, tiles[#tiles].y, "ok=", ok)
    return ok
  end

  log("move unit", uid, "NO ROUTE")
  return false
end

-- 我方回合行动调度。返回 true=本回合行动已处理完毕
-- 阶段A(有中立建筑): 全部可行动队一起推进
-- 阶段B(中立已占): 只派 1 个"领队"(表内路线者优先/最近者兜底)沿中轴大道去占补给站, 其余队待命
local function matchTurnDrive(M)
  local Entity = pub("Entity")
  if not Entity then return true end
  local squads = myInfantry(Entity)
  local target, hasNeutral = pickTarget(Entity)

  if not target then
    -- 没有非我方建筑 → 等结算(不派发)
    return false
  end

  -- 阶段缓冲: Outpost 刚被占, 还没发新兵(我方仍只有 1 队) → 等 10s
  if not hasNeutral then
    if #squads == 1 then
      local now = os.clock()
      if not Cache.afterOutpostAt then Cache.afterOutpostAt = now end
      if now - Cache.afterOutpostAt < 10 then
        return false -- 还没真正派发
      end
    end
  else
    Cache.afterOutpostAt = nil
  end

  local tx, ty = entLoc(target)
  if not tx then return false end

  -- 可行动池: 未标记且 mp>0
  local pool = {}
  for _, u in ipairs(squads) do
    local uid = tostring(u.uniqueID)
    if not M.actedSet[uid] and (entGet(u, "movePoints") or 0) > 0 then
      pool[#pool + 1] = u
    end
  end
  if #pool == 0 then return false end

  local function distOf(u)
    local ux, uy = entLoc(u)
    if not ux then return 1e9 end
    return math.abs(ux - tx) + math.abs(uy - ty)
  end

  local leader -- 阶段B 只派这一个
  if not hasNeutral then
    -- 1) 已在占领位(与目标建筑相邻)的队 → 让它 capture
    for _, u in ipairs(pool) do
      local ux, uy = entLoc(u)
      if ux and math.abs(ux - tx) + math.abs(uy - ty) == 1 then
        leader = u
        break
      end
    end
    -- 2) 否则表内路线最近队
    if not leader then
      local leadD = 1e9
      for _, u in ipairs(pool) do
        local ux, uy = entLoc(u)
        if ux and ROUTES[ux .. "," .. uy] then
          local d = distOf(u)
          if d < leadD then
            leadD = d
            leader = u
          end
        end
      end
    end
    -- 3) 无表内路线队 → 最近队 BFS 自救
    if not leader then
      local d0 = 1e9
      for _, u in ipairs(pool) do
        local d = distOf(u)
        if d < d0 then
          d0 = d
          leader = u
        end
      end
    end
  end

  local actedAny = false
  for _, u in ipairs(squads) do
    local uid = tostring(u.uniqueID)
    if not M.actedSet[uid] and (entGet(u, "movePoints") or 0) > 0 then
      if leader and u ~= leader then
        -- 非领队: 待命(标记, 不动)
        M.actedSet[uid] = true
      else
        M.sentSet[uid] = true -- 真发过动作的(供验证)
        actOnUnit(u, target, tx, ty)
        M.actedSet[uid] = true
        actedAny = true
      end
    end
  end
  return actedAny
end

-- 对局 tick
local function matchTick()
  local ws = ws()
  local gs = ws:FindFirstChild("GameSettings")
  if not gs then return end
  local cti = gs:FindFirstChild("CurrentTeamId")
  if not cti then return end
  local lp = getLP()
  local pg = lp and lp:FindFirstChild("PlayerGui")
  if not pg then return end

  -- 初始化
  if not Cache.match then
    if not matchInit() then return end
  end
  local M = Cache.match

  -- 1) 结算检测(优先级最高)
  if matchEnded() then
    -- 等待 teleport; 期间不做别的
    return
  end

  -- 2) 教程对话(开场/占点后): 显示中则点击并等待, 不执行行动
  if skipCutsceneIfAny() then
    return
  end

  -- 3) 播放阶段(回合循环)
  local ctiVal = cti.Value

  -- 回合变化检测
  if M.lastCti ~= ctiVal then
    M.lastCti = ctiVal
    M.lastAct = os.clock()
    if ctiVal == 0 then
      M.turnNo = M.turnNo + 1
      M.actedSet = {} -- 新回合: 清空行动标记
      M.sentSet = {}
      M.dispatched = false
      M.verified = false
      M.voted = false
      M.votedAt = nil
      M.retryAt = nil
      M.turnAt = os.clock() -- 回合开始时刻(兜底计时代)
      log("my turn #", M.turnNo)
      -- 回合数保护
      if M.turnNo > CFG.TURN_CAP then
        log("turn cap reached, abandon")
        local ok = pcall(function()
          conn().inGame.ReturnBack:FireServer()
        end)
        M.endSent = true
        return
      end
    end
  end

  if ctiVal == 0 then
    -- 我方回合: 零等待流程
    --   turn 到 → 立即派发(mp>0 即就绪, 无缓冲)
    --   派发 → 0.7s 后验证(mp 已扣=接受) → 立即 Voting 结束回合
    local Entity = pub("Entity")
    if not Entity then return end

    if not M.dispatched then
      -- 无缓冲, 直接尝试派发; 单位 mp 未恢复则下 tick 重试(0.8s)
      M.actedSet = {}
      M.sentSet = {}
      local okD = matchTurnDrive(M)
      if okD then
        M.dispatched = true
        M.dispatchedAt = os.clock()
        M.verified = false
        M.voted = false
      end
      return
    end

    local el = os.clock() - (M.dispatchedAt or os.clock())

    if not M.voted then
      if el >= 0.7 and not M.verified then
        M.verified = true
        -- 验证: sentSet 中若有单位 mp 未消耗(被拒) → BFS 补发
        -- capture(邻接目标的单位)不判拒: 服务器结算可能慢于 mp 扣除
        local Entity2 = pub("Entity")
        local rejected = false
        if Entity2 and M.sentSet then
          local tCur = pickTarget(Entity2)
          local txCur, tyCur
          if tCur then txCur, tyCur = entLoc(tCur) end
          for uid, _ in pairs(M.sentSet) do
            local u = Entity2:get(uid)
            if u and (entGet(u, "movePoints") or 0) > 0 then
              local ux, uy = entLoc(u)
              local adjacent = txCur and ux and (math.abs(ux - txCur) + math.abs(uy - tyCur) == 1)
              if not adjacent then
                rejected = true
                local tiles2 = planPath(ux, uy, txCur or 0, tyCur or 0, math.min(entGet(u, "movePoints") or 0, 2))
                if txCur and tiles2 and #tiles2 > 0 then
                  local path2 = { tileObj(ux, uy, 0, 0, true, "Road") }
                  local c2 = 0
                  for i, t in ipairs(tiles2) do
                    c2 = c2 + costOf(t.terr)
                    path2[#path2 + 1] = tileObj(t.x, t.y, c2, i, false, t.terr)
                  end
                  pcall(function()
                    conn().inGame.actions.Move:FireServer(tostring(u.uniqueID), path2)
                  end)
                  log("rejected->bfs retry", uid)
                end
              end
            end
          end
        end
        if rejected then
          M.retryAt = os.clock()
        else
          M.retryAt = nil
        end
      end
      -- 正常: 0.7s 后投票; 有补发: 补发 1.1s 后再投
      local voteAtTime = (M.retryAt and (M.retryAt + 1.1)) or (M.dispatchedAt + 0.7)
      if os.clock() >= voteAtTime then
        M.voted = true
        M.votedAt = os.clock()
        log("endTurn fast")
        pcall(function()
          conn().inGame.Voting:FireServer()
        end)
      end
      return
    end

    -- 已投票: 等回合切换; 卡住则重发/放弃
    if os.clock() - (M.votedAt or 0) > 4 then
      if os.clock() - M.voteAt > 4 then
        M.voteAt = os.clock()
        log("re-vote stuck")
        pcall(function()
          conn().inGame.Voting:FireServer()
        end)
      end
      if os.clock() - (M.votedAt or 0) > 25 then
        log("vote stuck >25s, abandon")
        pcall(function()
          conn().inGame.ReturnBack:FireServer()
        end)
        M.endSent = true
      end
    end
  else
    -- 敌方回合: 只等待(走中轴路线时敌方不行动, 快速通过)
    M.myTurnAt = nil
  end

  -- 4) 全局停滞保护: 长时间无回合变化且非结算 → 放弃重开
  if os.clock() - M.lastAct > CFG.MATCH_STALL_ABORT and not M.endSent then
    log("match stall, abandon")
    local ok = pcall(function()
      conn().inGame.ReturnBack:FireServer()
    end)
    M.endSent = true
  end
end

-- ---------------- 主循环 ----------------

local function tick()
  local ok, err = pcall(function()
    if game.PlaceId ~= CFG.PLACE_ID then
      -- 不是目标游戏: 空转
      return
    end
    local lp = getLP()
    if not lp then return end

    if not refreshSession() then return end

    local ws = ws()
    local inLobby = ws:GetAttribute("InLobby")
    if inLobby == nil then
      -- 场景切换中
      return
    end

    if inLobby == true then
      Cache.match = nil
      lobbyTick()
    else
      matchTick()
    end
  end)
  if not ok then
    log("tick error: ", tostring(err))
  end
end

local loopThread = task.spawn(function()
  while true do
    local ok, err = pcall(tick)
    if not ok then
      log("loop error: ", tostring(err))
    end
    task.wait(CFG.TICK)
  end
end)
AF.thread = loopThread

log("started. place=", tostring(game.PlaceId), " job=", tostring(game.JobId))
