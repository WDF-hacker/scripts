--=====================================================================
-- HUSH Tank Radar · autoexec 入口（对局感知加载器）
-----------------------------------------------------------------------
-- 放到  %LOCALAPPDATA%\Potassium\autoexec\  下，进游戏自动执行。
-- 行为：
--   * 只在对局里加载雷达脚本；在大厅/加载界面不加载
--   * 对局结束（HushRuntime.Raid 消失）自动 dispose，清干净 Drawing
--   * 同一服务器开新局（RaidId 变化）自动重载，重置状态
--   * 脚本源码从 GitHub raw 拉，缓存 10 分钟，失败重试 4 次
--
-- 对局判定依据（全项目通用写法）：
--   ReplicatedStorage.HushRuntime.Raid 存在，且该 Folder 的 RaidId 属性非空
--   参考 HushClient 各控制器：HushRuntime:FindFirstChild("Raid")
--
-- 调试：getgenv().HUSH_TANK_LOADER.probe()  -> 当前判定输入
--       getgenv().HUSH_TANK_LOADER.stop()   -> 停掉监视循环
--=====================================================================
local URL = "https://raw.githubusercontent.com/WDF-hacker/scripts/main/hush_tank_radar.luau"
local NAME = "HUSH_TANK_LOADER"
local RADAR = "HUSH_TANK_RADAR"
local CACHE_TTL = 600
local POLL = 2

local genv = (getgenv and getgenv()) or _G

--------------------------------------------------------------------------
-- 单实例
--------------------------------------------------------------------------
do
    local old = genv[NAME]
    if type(old) == "table" and type(old.stop) == "function" then
        pcall(old.stop)
        task.wait(0.2)
    end
end

local RS = game:GetService("ReplicatedStorage")

local SRC = nil
local srcAt = 0
local loaded = false
local curRaid = nil
local running = true

--------------------------------------------------------------------------
-- 对局判定
--------------------------------------------------------------------------
local function raidFolder()
    local rt = RS:FindFirstChild("HushRuntime")
    if not rt then return nil end
    return rt:FindFirstChild("Raid")
end

local function raidId()
    local raid = raidFolder()
    if not raid then return "" end
    local rid = raid:GetAttribute("RaidId")
    if type(rid) ~= "string" or #rid == 0 then return "" end
    return rid
end

local function isRaid()
    return raidId() ~= ""
end

--------------------------------------------------------------------------
-- 下载 / 加载 / 卸载
--------------------------------------------------------------------------
local function fetch()
    if SRC and os.clock() - srcAt < CACHE_TTL then
        return SRC
    end
    for i = 1, 4 do
        local ok, res = pcall(function()
            return game:HttpGet(URL .. "?t=" .. tostring(os.time()))
        end)
        if ok and type(res) == "string" and #res > 3000 then
            SRC = res
            srcAt = os.clock()
            return SRC
        end
        warn("[TANK] 下载失败（第 " .. i .. " 次）：" .. tostring(res))
        task.wait(2)
    end
    return nil
end

local function loadRadar()
    if type(genv[RADAR]) == "table" then
        loaded = true
        return true
    end
    local src = fetch()
    if not src then
        warn("[TANK] 放弃加载：下载失败")
        return false
    end
    local fn, err = loadstring(src)
    if not fn then
        warn("[TANK] 编译失败：" .. tostring(err))
        return false
    end
    local ok, err2 = pcall(fn)
    if not ok then
        warn("[TANK] 运行出错：" .. tostring(err2))
        return false
    end
    loaded = true
    print("[TANK] 已在对局内加载雷达  raidId=" .. raidId())
    return true
end

local function unloadRadar()
    local a = genv[RADAR]
    if type(a) == "table" and type(a.dispose) == "function" then
        pcall(a.dispose)
    end
    loaded = false
    print("[TANK] 已卸载雷达（离开对局）")
end

--------------------------------------------------------------------------
-- 监视循环
--------------------------------------------------------------------------
task.spawn(function()
    if not game:IsLoaded() then
        pcall(function() game.Loaded:Wait() end)
    end
    task.wait(1.5)

    local announced = false
    while running do
        local rid = raidId()
        if rid ~= "" then
            if not loaded or type(genv[RADAR]) ~= "table" then
                loadRadar()
                curRaid = rid
            elseif curRaid ~= nil and curRaid ~= rid then
                -- 同服务器开新局：清掉旧状态重来
                unloadRadar()
                task.wait(0.2)
                loadRadar()
                curRaid = rid
            elseif curRaid == nil then
                curRaid = rid
            end
            announced = false
        else
            if loaded or type(genv[RADAR]) == "table" then
                unloadRadar()
            end
            if not announced then
                print("[TANK] 大厅/非对局，暂不加载（等待进入对局）")
                announced = true
            end
            curRaid = nil
        end
        task.wait(POLL)
    end
end)

--------------------------------------------------------------------------
-- 调试接口
--------------------------------------------------------------------------
genv[NAME] = {
    stop = function()
        running = false
        pcall(function() genv[NAME] = nil end)
    end,
    probe = function()
        local rt = RS:FindFirstChild("HushRuntime")
        return {
            inRaid = isRaid(),
            raidId = raidId(),
            loaded = type(genv[RADAR]) == "table",
            placeId = game.PlaceId,
            mapId = rt and tostring(rt:GetAttribute("MapId")) or nil,
        }
    end,
    reload = function()
        unloadRadar()
        return loadRadar()
    end,
}

print("[TANK] autoexec 监视已启动（每 " .. POLL .. " 秒检查一次对局状态）")
