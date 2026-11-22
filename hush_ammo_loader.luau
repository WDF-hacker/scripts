--==============================================================
-- HUSH 弹药采购 · autoexec 入口
-- 放到  Potassium/autoexec/  下，进游戏自动加载远程脚本
-- 远程本体：hush_ammo_buyer.luau（GitHub WDF-hacker/scripts）
--==============================================================
local URL = "https://raw.githubusercontent.com/WDF-hacker/scripts/main/hush_ammo_buyer.luau"

task.spawn(function()
    if not game:IsLoaded() then game.Loaded:Wait() end
    task.wait(1)

    -- HTTP 偶尔会失败，重试 4 次
    local src
    for attempt = 1, 4 do
        local ok, res = pcall(function()
            return game:HttpGet(URL .. "?t=" .. tostring(os.time()))
        end)
        if ok and type(res) == "string" and #res > 3000 then
            src = res
            break
        end
        warn(string.format("[AMMO] 下载失败（第 %d 次）：%s", attempt, tostring(res)))
        task.wait(2)
    end

    if not src then
        warn("[AMMO] 放弃加载：下载失败")
        return
    end

    local fn, err = loadstring(src)
    if not fn then
        warn("[AMMO] 编译失败：" .. tostring(err))
        return
    end

    local ok, err2 = pcall(fn)
    if not ok then
        warn("[AMMO] 运行出错：" .. tostring(err2))
        return
    end

    print("[AMMO] autoexec 加载完成")
end)
