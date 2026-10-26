--[[
    HUSH 完全清除（panic）—— 清掉所有已知脚本实例、绘制、GUI、hook
    用法：在注入器里执行 loadstring(game:HttpGet(".../hush_purge.luau"))()
    注意：v7 之前加载的旧实例没有注册 cleanup，Lua 层拿不到引用；
          这个脚本能清掉"看得见的东西"（绘制/GUI）和 Net.fire 链，
          但要彻底清空 Lua 状态，最稳的仍是重进服务器或重载执行器。
]]

local report = {}

-- 1) 跑所有注册过的 cleanup
local n = 0
if _G.__HUSH_CLEANUPS then
    for _, f in ipairs(_G.__HUSH_CLEANUPS) do pcall(f); n = n + 1 end
    _G.__HUSH_CLEANUPS = {}
end
report.cleanups = n

-- 2) 清空所有 Drawing
pcall(function() if Drawing and Drawing.clear then Drawing.clear() end end)
pcall(function() if cleardrawcache then cleardrawcache() end end)
report.drawings = "cleared"

-- 3) 销毁 GUI
local destroyed = 0
local roots = {}
if gethui then table.insert(roots, gethui()) end
table.insert(roots, game:GetService("CoreGui"))
local lp = game:GetService("Players").LocalPlayer
if lp then
    local pg = lp:FindFirstChild("PlayerGui")
    if pg then table.insert(roots, pg) end
end
for _, root in ipairs(roots) do
    if root then
        for _, g in ipairs(root:GetDescendants()) do
            if g:IsA("ScreenGui") and (g.Name:find("Obsidian") or g.Name == "HushStatus") then
                pcall(function() g:Destroy() end)
                destroyed = destroyed + 1
            end
        end
    end
end
report.guis = destroyed

-- 4) 还原 Net.fire（如果保存过原始引用）
pcall(function()
    if _G.__HUSH_ORIG_FIRE then
        local RS = game:GetService("ReplicatedStorage")
        local hush = RS:FindFirstChild("Hush")
        local mod = hush and hush:FindFirstChild("Shared") and hush.Shared:FindFirstChild("Net")
        if mod then require(mod).fire = _G.__HUSH_ORIG_FIRE end
    end
end)
_G.__HUSH_ORIG_FIRE = nil
report.hook = "restored"

-- 5) 清全局
for _, k in ipairs({
    "HUSH_UI", "HUSH_UI_CFG", "HUSH_UI_CLEANUP", "HUSH_UI_VERSION", "HUSH_UI_DEBUG",
    "HUSH_Z", "HUSH_ESP", "HUSH_SILENT_TEST", "HUSH_CURSOR", "HUSH_AIM3", "HUSH_AIM4",
    "HUSH_AIM5", "HUSH_AIM6", "HUSH_AIM7", "HUSH_AIM8", "HUSH_AIM9"
}) do
    _G[k] = nil
end
report.globals = "cleared"

print("[HUSH-PURGE] " .. tostring(report.cleanups) .. " cleanups, " .. tostring(destroyed) .. " guis, drawings cleared, hook restored")
return report
