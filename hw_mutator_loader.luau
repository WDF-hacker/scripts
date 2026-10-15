-- HW Mutator Loader v2  (autoexec)
-- ---------------------------------------------------------------------------
-- 【它做什么】
--   每次进游戏 / teleport 后自动注入本加载器，然后：
--     ① 读本地脚本   readfile("hw_mutator.luau")      （执行器的 readfile 根目录）
--     ② 读云端脚本   game:HttpGet(下面的 URL)
--     ③ **比版本号**（文件里的 `local VERSION = N`），谁新加载谁
--     ④ 如果云端更新：加载云端那份，并顺手把本地文件也刷新成新版
--        （下次断网也能用新版；不用再手工传文件）
--     ⑤ 新的那份万一加载失败（解析错/运行时报错），自动退回另一份
--
-- 【给朋友用】
--   把两个文件都给他，缺一不可：
--     · 完整脚本 hw_mutator.luau（几百 KB） -> 执行器的 readfile 根目录（一般是 workspace）
--     · 本加载器   hw_mutator.luau（几 KB）  -> 执行器的 autoexec 目录
--   ⚠ 一定要先删掉他根目录里**旧的** hw_mutator.luau，否则旧文件会被当成"本地版本"。
--     （旧版加载器是"本地优先"，只要本地有文件就永远用本地 —— 这就是他卡在 v73 的原因）
--
-- 【配置说明（已更新）】
--   配置**不再**是 hw_mutator_config.json。脚本已改用 UI 库自己的配置面板：
--     「配置」页 -> Configuration -> 点 Overwrite config 保存（下次进游戏自动载入）
-- ---------------------------------------------------------------------------

local TAG = "[HW]"
local LOCAL_FILE = "hw_mutator.luau"
local URL = "https://raw.githubusercontent.com/WDF-hacker/scripts/refs/heads/main/hw_mutator.luau?ts="
    .. string.format("%.4f", os.clock())   -- ?ts= 破缓存

local function executorName()
    local ok, n = pcall(function() return identifyexecutor and identifyexecutor() end)
    return (ok and type(n) == "string") and n or "未知执行器"
end

-- 取版本号（读不到就返回 -1，代表"这份不可用"）
local function verOf(src)
    if type(src) ~= "string" or #src < 100 then return -1 end
    local v = src:match("local VERSION%s*=%s*(%d+)")
    return tonumber(v) or 0
end

-- 真正执行一份脚本；返回 成功?, 原因
local function tryExec(src)
    if type(src) ~= "string" or #src < 100 then
        return false, "内容为空或过小（" .. tostring(type(src)) .. "）"
    end
    local fn, err = loadstring(src)
    if not fn then
        return false, "loadstring 失败: " .. tostring(err)
    end
    local ok, err2 = pcall(fn)
    if not ok then
        return false, "运行时报错: " .. tostring(err2)
    end
    return true
end

print(TAG .. " loader v2 | 执行器: " .. executorName())

-- ① 本地 ------------------------------------------------------------------
local localSrc, localErr
do
    local ok, s = pcall(readfile, LOCAL_FILE)
    if ok then localSrc = s else localErr = tostring(s) end
end
local vLocal = verOf(localSrc)
if vLocal >= 0 then
    print(TAG .. " 本地: v" .. vLocal .. "（" .. #localSrc .. " 字节）")
else
    print(TAG .. " 本地: 没有可用文件（" .. tostring(localErr or "空/过小") .. "）")
end

-- ② 云端（带超时保护：HttpGet 卡住也不至于把注入线程一直吊着）------------------
local cloudSrc
do
    local done, res = false, nil
    task.spawn(function()
        local ok, s = pcall(function() return game:HttpGet(URL) end)
        if ok then res = s end
        done = true
    end)
    local t0 = os.clock()
    while not done and (os.clock() - t0) < 6 do task.wait(0.05) end
    cloudSrc = res
end
local vCloud = verOf(cloudSrc)
if vCloud >= 0 then
    print(TAG .. " 云端: v" .. vCloud .. "（" .. #cloudSrc .. " 字节）")
else
    print(TAG .. " 云端: 取不到（离线 / 被墙 / 仓库里没有这份）")
end

-- ③ 排优先级：新的在前，另一份兜底 ------------------------------------------
local order = {}
if vCloud >= 0 and vCloud >= vLocal then
    order[#order + 1] = { src = cloudSrc, tag = "云端 v" .. vCloud }
elseif vLocal >= 0 then
    order[#order + 1] = { src = localSrc, tag = "本地 v" .. vLocal }
end
-- 兜底：另一份（本地优先兜底，因为本地不依赖网络）
if vLocal >= 0 and not (order[1] and order[1].src == localSrc) then
    order[#order + 1] = { src = localSrc, tag = "本地 v" .. vLocal }
end
if vCloud >= 0 and not (order[1] and order[1].src == cloudSrc) then
    order[#order + 1] = { src = cloudSrc, tag = "云端 v" .. vCloud }
end

if #order == 0 then
    warn(TAG .. " ❌ 两份都没有：请把完整脚本放到 readfile 根目录（文件名必须是 " .. LOCAL_FILE .. "）")
    return
end

-- ④ 依次尝试 ---------------------------------------------------------------
for _, cand in ipairs(order) do
    local ok, why = tryExec(cand.src)
    if ok then
        print(TAG .. " ✅ 已加载 " .. cand.tag)
        -- 云端更新了 -> 顺手把本地也刷新，下次断网也是新版
        if cand.src == cloudSrc and vCloud > vLocal then
            local wok, werr = pcall(writefile, LOCAL_FILE, cloudSrc)
            if wok then
                print(TAG .. " ⬆ 本地文件已更新到 v" .. vCloud .. "（下次离线也能用新版）")
            else
                warn(TAG .. " 本地文件写入失败（不影响本次运行）: " .. tostring(werr))
            end
        end
        return
    else
        warn(TAG .. " ❌ 加载 " .. cand.tag .. " 失败: " .. tostring(why))
    end
end

warn(TAG .. " ❌ 两份都没能加载成功；请把上面的报错发给我")
