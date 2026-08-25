-- Tesla AutoFarm FINAL: full loop (lobby -> match farm -> auto upgrade -> back to lobby -> repeat)
-- Usage: put in Potassium autoexec, runs automatically each game join
-- Features: auto detect lobby/match, auto join (Shrine Extreme), client platform + big circle move, Tesla 8x instant attack,
--       auto upgrade pick (money>dmg>xp), auto teleportback on match end, Freecam (V key)
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")

-- duplicate-load guard + zombie check (old UI gone but _G leftover => zombie, rebuild)
if _G.AutoFarmFinal then
	local zombie = false
	pcall(function()
		local ui = game.Players.LocalPlayer
			and game.Players.LocalPlayer:FindFirstChild("PlayerGui")
			and game.Players.LocalPlayer.PlayerGui:FindFirstChild("AutoFarmUI")
		if not ui then
			zombie = true
		end
	end)
	if zombie then
		-- zombie state: cleanup leftovers then rebuild
		pcall(function() _G.AutoFarmFinal.Cleanup() end)
		_G.AutoFarmFinal = nil
		print("[AF] zombie detected, rebuild")
	else
		print("[AF] already running, skip")
		return
	end
end
_G.AutoFarmFinal = { Cleanup = function() end }

-- wait for LocalPlayer (autoexec may run very early during load)
local LocalPlayer = Players.LocalPlayer
local lpWaitT0 = os.clock()
while not LocalPlayer and os.clock() - lpWaitT0 < 60 do
	task.wait(0.5)
	LocalPlayer = Players.LocalPlayer
end
if not LocalPlayer then
	warn("[AF] LocalPlayer timeout, exit")
	_G.AutoFarmFinal = nil
	return
end
print("[AF] LocalPlayer ready: " .. LocalPlayer.Name)

-- Config
local PLATFORM_Y = 201.3
local PLATFORM_SIZE = Vector3.new(20, 2, 20)
local MAP = "The Shrine"
local MODE = "Extreme"
local CIRCLE_RADIUS = 50
local CIRCLE_Y = 204.3
local CIRCLE_PERIOD = 20
local CIRCLE_POINTS = 72

-- ========== Upgrade priority ==========
local UPGRADE_PRIORITY = {
	["Treasure Chest"] = 100, ["Bloxy Cola"] = 95,
	["Glass Cannon"] = 90, ["Red Stratobloxxer"] = 85, ["Subspace Mine"] = 80,
	["Spectral Sword"] = 75, ["Epic Sauce"] = 70, ["Leprechaun Potion"] = 70,
	["Precise Bow"] = 65, ["Roblox Card"] = 60, ["Pinata"] = 55,
	["RedBLOX"] = 82,
	["Crimson Staff"] = 50, ["Woodland Staff"] = 50, ["Azure Staff"] = 50,
	["Dark Age Sunfire Scroll"] = 45, ["Rocket"] = 45, ["Gravitron"] = 45, ["Celestial Staff"] = 45,
	["Ghostfire Sword"] = 40, ["Elemental Sword"] = 40, ["Zombie Staff"] = 40,
	["Vampire Cloak"] = 40, ["Mostly Ghostly Potion"] = 40,
	["Noobcaik"] = 35, ["Instant Campfire"] = 35, ["Phoenix"] = 35,
	["Battle Armor"] = 30, ["Decoy Deploy"] = 30,
	["Forbidden Box"] = 25, ["Quantum Entangler"] = 25, ["Healing Potion"] = 25,
	["Regen Coil"] = 25, ["Battle Shield"] = 25, ["Wind Staff"] = 20,
	["Speed Coil"] = 20, ["Slateskin Potion"] = 15, ["Super Speedy Purple Potion"] = 15,
	["Bloxiade"] = 15, ["Starblox Latte"] = 15, ["Rainbow Magic Carpet"] = 10,
	["Ninja Blink Potion"] = 10, ["Gravity Coil"] = 10, ["Trowel"] = 10,
	["Frost Potion"] = 5, ["Fire Extinguisher"] = 5, ["Superhero Potion"] = 5,
	["Antidote"] = 5, ["C4"] = 5,
}

-- ========== State ==========
local running = true
local shootCount = 0
local phase = "boot"
local lastAfkInput = os.clock()

local function isInLobby()
	local gv = ReplicatedStorage:FindFirstChild("GameValues")
	return gv and gv:FindFirstChild("Lobby") and gv.Lobby.Value == true
end

-- ========== Utils ==========
local function getWeapon()
	local char = LocalPlayer.Character
	if char then
		for _, t in ipairs(char:GetChildren()) do
			if t:IsA("Tool") and t.Name == "Tesla Gun" then return t end
		end
	end
	local bp = LocalPlayer:FindFirstChild("Backpack")
	if bp then
		for _, t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") and t.Name == "Tesla Gun" then return t end
		end
	end
	return nil
end

local function ensureEquipped()
	local w = getWeapon()
	if not w then return nil end
	if w.Parent ~= LocalPlayer.Character and LocalPlayer.Character then
		pcall(function()
			local hum = LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if hum then hum:EquipTool(w) end
		end)
		task.wait(0.3)
	end
	return getWeapon()
end

local function getNearestHead(origin)
	local allNoobs = Workspace:FindFirstChild("Allnoobs")
	if not allNoobs then return nil, nil end
	local nearestPart, nearestPos, nearestDist = nil, nil, math.huge
	local healerPart, healerPos, healerDist = nil, nil, math.huge
	for _, noob in ipairs(allNoobs:GetChildren()) do
		if noob:IsA("Model") then
			local hum = noob:FindFirstChild("Humanoid")
			if hum and hum.Health > 0 then
				local head = noob:FindFirstChild("Head") or noob:FindFirstChild("HumanoidRootPart")
				if head and head:IsA("BasePart") then
					local dist = (head.Position - origin).Magnitude
					-- healer (HealerNoob) highest priority: track separately
					if noob.Name == "HealerNoob" then
						if dist < healerDist then
							healerDist = dist
							healerPart = head
							healerPos = head.Position
						end
					end
					if dist < nearestDist then
						nearestDist = dist
						nearestPart = head
						nearestPos = head.Position
					end
				end
			end
		end
	end
	-- healer beats nearest target
	if healerPart then
		return healerPart, healerPos
	end
	return nearestPart, nearestPos
end

-- ========== Platform ==========
local function getStatuePlatform()
	return Workspace:FindFirstChild("Map")
		and Workspace.Map:FindFirstChild("Terrain")
		and Workspace.Map.Terrain:FindFirstChild("StatueBase")
		and Workspace.Map.Terrain.StatueBase:FindFirstChild("Stand")
		and Workspace.Map.Terrain.StatueBase.Stand:FindFirstChild("platform")
end

local function ensurePlatform()
	if _G.FarmPlatform and _G.FarmPlatform.Parent then return _G.FarmPlatform end
	local base = getStatuePlatform()
	if not base then return nil end
	local floor = Instance.new("Part")
	floor.Name = "FarmPlatform"
	floor.Size = PLATFORM_SIZE
	floor.Position = Vector3.new(base.Position.X, PLATFORM_Y, base.Position.Z)
	floor.Anchored = true
	floor.CanCollide = true
	floor.CanTouch = true
	floor.Transparency = 0.5
	floor.Material = Enum.Material.Neon
	floor.Color = Color3.fromRGB(0, 200, 255)
	floor.Parent = Workspace
	_G.FarmPlatform = floor
	return floor
end

-- ========== Big circle move (RenderStepped smooth interpolation, no jitter) ==========
local circleCenterX = 0
local circleCenterZ = 0
local circleAngle = 0
local circleRunning = false
local circleTickConn = nil
local circleBodyPos = nil

local function startCircleMove(hrp, hum, cx, cz)
	if circleRunning then return end
	circleCenterX = cx
	circleCenterZ = cz
	circleRunning = true
	-- initial angle: align to char current position
	local relX = hrp.Position.X - cx
	local relZ = hrp.Position.Z - cz
	circleAngle = math.atan2(relZ, relX)
	if hum then pcall(function() hum.PlatformStand = true end) end
	-- BodyPosition locks Y (physics-level, prevents gravity drop)
	local bp = Instance.new("BodyPosition")
	bp.MaxForce = Vector3.new(0, 1e6, 0)  -- lock vertical only
	bp.P = 5000
	bp.D = 1000
	bp.Position = Vector3.new(hrp.Position.X, CIRCLE_Y, hrp.Position.Z)
	bp.Parent = hrp
	circleBodyPos = bp

	local tickConn = nil
	tickConn = RunService.RenderStepped:Connect(function(dt)
		if not circleRunning then
			if tickConn then pcall(tickConn.Disconnect, tickConn) end
			return
		end
		if not hrp or not hrp.Parent then return end
		-- angle advance: one lap per CIRCLE_PERIOD seconds
		circleAngle = circleAngle + (2 * math.pi / CIRCLE_PERIOD) * (dt or 0.016)
		-- circle target position (Y fixed at CIRCLE_Y)
		local target = Vector3.new(
			circleCenterX + math.cos(circleAngle) * CIRCLE_RADIUS,
			CIRCLE_Y,
			circleCenterZ + math.sin(circleAngle) * CIRCLE_RADIUS
		)
		-- clear inertia before CFrame (avoid gravity accumulation)
		pcall(function() hrp.AssemblyLinearVelocity = Vector3.zero end)
		hrp.CFrame = CFrame.new(target)
		-- sync BodyPosition target (lock Y)
		if circleBodyPos then
			pcall(function() circleBodyPos.Position = target end)
		end
	end)
	circleTickConn = tickConn
end

local function stopCircleMove(hrp, hum)
	circleRunning = false
	if circleTickConn then pcall(circleTickConn.Disconnect, circleTickConn) end
	circleTickConn = nil
	if circleBodyPos then pcall(function() circleBodyPos:Destroy() end) end
	circleBodyPos = nil
	_G.AF_circleHrp = nil
	if hum then pcall(function() hum.PlatformStand = false end) end
end

-- ========== Freecam ==========
local freecam = {
	enabled = false, camera = nil, origType = nil,
	yaw = 0, pitch = 0, pos = Vector3.new(),
	conns = {}, renderConn = nil,
}

local function setFreecam(on)
	if on == freecam.enabled then return end
	if on then
		freecam.camera = Workspace.CurrentCamera
		freecam.origType = freecam.camera.CameraType
		local char = LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		freecam.pos = hrp and hrp.Position or freecam.camera.CFrame.Position
		freecam.yaw = 0
		freecam.pitch = 0
		freecam.camera.CameraType = Enum.CameraType.Scriptable
		freecam.camera.CameraSubject = nil
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		freecam.enabled = true
		table.insert(freecam.conns, UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				freecam.yaw = freecam.yaw - input.Delta.X * 0.002
				freecam.pitch = math.clamp(freecam.pitch - input.Delta.Y * 0.002, -1.5, 1.5)
			end
		end))
		freecam.renderConn = RunService.RenderStepped:Connect(function(dt)
			local move = Vector3.new()
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then move += Vector3.new(0, 0, -1) end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then move += Vector3.new(0, 0, 1) end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then move += Vector3.new(-1, 0, 0) end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then move += Vector3.new(1, 0, 0) end
			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then move += Vector3.new(0, 1, 0) end
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then move += Vector3.new(0, -1, 0) end
			local speed = 60
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then speed = 250 end
			local cf = CFrame.fromOrientation(freecam.pitch, freecam.yaw, 0)
			freecam.pos = freecam.pos + (cf * move * speed * (dt or 0.016))
			freecam.camera.CFrame = CFrame.lookAt(freecam.pos, freecam.pos + cf.LookVector)
		end)
	else
		freecam.enabled = false
		for _, c in ipairs(freecam.conns) do pcall(c.Disconnect, c) end
		freecam.conns = {}
		if freecam.renderConn then pcall(freecam.renderConn.Disconnect, freecam.renderConn) end
		freecam.renderConn = nil
		if freecam.camera then
			freecam.camera.CameraType = freecam.origType or Enum.CameraType.Custom
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

table.insert(freecam.conns, UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.V then
		setFreecam(not freecam.enabled)
	end
end))

-- ========== Button click (Potassium Signal Library) ==========
-- firesignal triggers signal handlers directly (VERIFIED on Potassium:
-- Start button, upgrade buttons all work with firesignal alone.
-- mouse1click was removed: it interfered with upgrade selection.)
local function clickButton(btn)
	if not btn then return false end
	if firesignal then
		pcall(firesignal, btn.MouseButton1Down)
		pcall(firesignal, btn.MouseButton1Click)
		pcall(firesignal, btn.MouseButton1Up)
		pcall(firesignal, btn.Activated)
	end
	return true
end

-- ========== Lobby UI ops ==========
local function closePanel(name)
	local ev = LocalPlayer.PlayerGui:FindFirstChild("Everything")
	if ev then
		local p = ev:FindFirstChild(name)
		if p and p.Visible then
			local exit = p:FindFirstChild("ExitButton")
			if exit then
				clickButton(exit)
				task.wait(0.8)
				if p.Visible then
					pcall(function() p.Visible = false end)
				end
				return true
			end
			-- no ExitButton: hide directly
			pcall(function() p.Visible = false end)
			return true
		end
	end
	return false
end

local function clickPlay()
	local sg2 = LocalPlayer.PlayerGui:FindFirstChild("ScreenGui")
	if sg2 then
		local pb = sg2:FindFirstChild("PlayButton")
		if pb and pb.Visible then
			clickButton(pb)
			return true
		end
	end
	return false
end

-- real mouse click alias
local function realClick(btn)
	return clickButton(btn)
end

-- ========== Match end detect + return ==========
local function detectAndReturn()
	local mec = LocalPlayer.PlayerGui:FindFirstChild("MatchEndCinematicGui")
	local ev = LocalPlayer.PlayerGui:FindFirstChild("Everything")
	local stats = ev and ev:FindFirstChild("ArenaStats")
	if mec and stats and stats.Visible then
		phase = "ending"
		print("[AF] match ended, returning lobby")
		task.wait(2)
		local special = ReplicatedStorage.Remotes:FindFirstChild("special")
		if special then
			pcall(function() special:FireServer("teleportback") end)
			print("[AF] teleportback requested")
		end
		return true
	end
	return false
end

-- ========== Title screen (real click first; else hide, never destroy, avoid game crash) ==========
local function handleTitleScreen()
	-- quick check: only wait 6s (no PlayButton in match)
	local quickCheck = true
	-- already in match (Lobby=false): skip title entirely
	local gv0 = ReplicatedStorage:FindFirstChild("GameValues")
	if gv0 and gv0:FindFirstChild("Lobby") and gv0.Lobby.Value == false then
		print("[AF] already in match, skip title")
		return false
	end
	print("[AF] checking title screen...")
	local tPlay = os.clock()
	while running and os.clock() - tPlay < 6 do
		local pb = nil
		local pbSg = nil
		for _, sg2 in ipairs(LocalPlayer.PlayerGui:GetChildren()) do
			if sg2:IsA("ScreenGui") then
				local found = sg2:FindFirstChild("PlayButton")
				if found and found.Visible then
					pb = found
					pbSg = sg2
					break
				end
			end
		end
		if pb then
			print("[AF] found title PlayButton")
			local clicked = false
			-- click via firesignal + real mouse (Potassium Signal/Input Library)
			clickButton(pb)
			task.wait(1)
			-- check click success (button gone = game handled it)
			local pbGone = true
			for _, sg2 in ipairs(LocalPlayer.PlayerGui:GetChildren()) do
				if sg2:IsA("ScreenGui") then
					local f = sg2:FindFirstChild("PlayButton")
					if f and f.Visible then
						pbGone = false
						break
					end
				end
			end
			if pbGone then
				clicked = true
				print("[AF] PlayButton clicked")
			else
				-- method 3: hide ScreenGui (keep button; game Wait() harmless)
				print("[AF] click failed, hide title (keep button)")
				if pbSg then
					pcall(function() pbSg.Enabled = false end)
				end
			end
			-- either way, apply post effects
			local cam = Workspace.CurrentCamera
			pcall(function()
				cam.CameraType = Enum.CameraType.Custom
				local char = LocalPlayer.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if hum then cam.CameraSubject = hum end
			end)
			local ev = LocalPlayer.PlayerGui:FindFirstChild("Everything")
			if ev then
				pcall(function() ev.Enabled = true end)
			end
			local special = ReplicatedStorage.Remotes:FindFirstChild("special")
			if special then
				pcall(function() special:FireServer("intro") end)
			end
			pcall(function()
				local intro = LocalPlayer.PlayerGui:FindFirstChild("CleanIntroTransitionOverlay")
				if intro then intro.Enabled = false end
			end)
			pcall(function()
				local introStuff = Workspace:FindFirstChild("IntroStuff")
				if introStuff then
					for _, c in ipairs(introStuff:GetChildren()) do
						if c.Name ~= "Grass" and c.Name ~= "cameralast" then
							pcall(function() c:Destroy() end)
						end
					end
				end
			end)
			print("[AF] title skipped")
			return true
		end
		task.wait(1)
	end
	print("[AF] title not found (maybe in match)")
	return false
end

-- ========== Main loop ==========
local mainThread = task.spawn(function()
	-- startup wait: ensure basics loaded (char, GameValues, Remotes)
	print("[AF] waiting for game load...")
	local t0 = os.clock()
	while running and os.clock() - t0 < 60 do
		local ok = LocalPlayer.Character
			and ReplicatedStorage:FindFirstChild("GameValues")
			and ReplicatedStorage:FindFirstChild("Remotes")
		if ok then break end
		task.wait(1)
	end
	print("[AF] game loaded, starting main loop")
	-- handle title first unconditionally (Lobby may not be ready)
	handleTitleScreen()
	-- wait for Lobby flag (may be missing during title/load)
	local lobbyWaitT0 = os.clock()
	while running and os.clock() - lobbyWaitT0 < 20 do
		local gv = ReplicatedStorage:FindFirstChild("GameValues")
		if gv and gv:FindFirstChild("Lobby") then break end
		task.wait(1)
	end
	print("[AF] Lobby status: " .. tostring(isInLobby()))
	while running do
		-- anti-AFK: prevent Roblox ~20min idle kick (micro mouse move every 4 min)
		if os.clock() - lastAfkInput > 240 then
			lastAfkInput = os.clock()
			pcall(function()
				if mousemoverel then
					mousemoverel(0, 3)
				elseif keypress then
					keypress(Enum.KeyCode.LeftShift)
					task.wait(0.1)
					keyrelease(Enum.KeyCode.LeftShift)
				end
			end)
			print("[AF] anti-AFK ping")
		end
		if isInLobby() then
			-- ===== Lobby phase =====
			phase = "lobby"
			print("[AF] lobby: starting match flow")
			closePanel("Rewards")
			task.wait(1)
			-- retry title screen if first attempt incomplete
			handleTitleScreen()
			-- wait lobby UI ready (Everything panel exists)
			local tUi = os.clock()
			while running and os.clock() - tUi < 15 do
				local evReady = LocalPlayer.PlayerGui:FindFirstChild("Everything")
				if evReady then break end
				task.wait(0.5)
			end
			-- after lobby UI ready, send map select request
			local mapselection = ReplicatedStorage.Remotes:FindFirstChild("mapselection")
			local lobby = Workspace:FindFirstChild("Lobby")
			local portals = lobby and lobby:FindFirstChild("portals")
			local portal = portals and portals:GetChildren()[4]
			-- wait for server "select" event (records u222), short wait
			local serverU222 = nil
			local selConn = nil
			if mapselection then
				selConn = mapselection.OnClientEvent:Connect(function(evType, arg2)
					pcall(function()
						if evType == "select" then
							serverU222 = arg2
							print("[AF] server select: " .. tostring(serverU222))
						end
					end)
				end)
				task.wait(2)
				pcall(selConn.Disconnect, selConn)
			end
			if mapselection then
				pcall(function()
					-- portal may be nil (lobby structure varies); prefer server u222, else nil or portal
					mapselection:FireServer("select", serverU222 or portal, {
						map = MAP, sandbox = "Grass", mode = MODE, rank = 1, partysize = 1
					})
				end)
				print("[AF] map request: " .. MAP .. " " .. MODE .. " (u222=" .. tostring(serverU222 ~= nil) .. " portal=" .. tostring(portal ~= nil) .. ")")
			end
			-- wait for party + start (Start button click or "start" Remote)
			local t0 = os.clock()
			local started = false
			local partyData = nil
			-- listen mapselection: record server party data (u225 equivalent)
			local msEvt = ReplicatedStorage.Remotes:FindFirstChild("mapselection")
			local msConn = nil
			if msEvt then
				msConn = msEvt.OnClientEvent:Connect(function(evType, ...)
					local args = table.pack(...)
					pcall(function()
						if evType == "room" then
							local info = args[1]
							-- only record table-typed party data (avoid portal model misread)
							if typeof(info) == "table" then
								partyData = info
								local mapName = "?"
								pcall(function()
									if info.map and typeof(info.map) == "table" and info.map.Value then
										mapName = tostring(info.map.Value)
									end
								end)
								print("[AF] party data: " .. mapName)
							end
						end
					end)
				end)
			end
			while running and isInLobby() and os.clock() - t0 < 40 do
				local ev = LocalPlayer.PlayerGui:FindFirstChild("Everything")
				if ev then
					local party = ev:FindFirstChild("Party")
					if party and party.Visible then
						local start = party:FindFirstChild("HostButtons") and party.HostButtons:FindFirstChild("CreateButton")
						if start then
							-- method 1: click button via firesignal + real mouse
							-- (firesignal verified working; real click runs full game flow)
							clickButton(start)
							print("[AF] Start: clicked")
							task.wait(1)
							-- method 2 (remote-spy proven): FireServer("start", portal)
							if isInLobby() and msEvt and portal then
								print("[AF] Start: FireServer(start, portal)")
								pcall(function() msEvt:FireServer("start", portal) end)
								task.wait(1)
							end
							-- stop retrying: outer loop retries whole flow if still in lobby
							started = true
							break
						end
					end
				end
				task.wait(1)
			end
			if msConn then pcall(msConn.Disconnect, msConn) end
			if started or not isInLobby() then
				print("[AF] starting match, waiting teleport")
				local tw = os.clock()
				while running and isInLobby() and os.clock() - tw < 30 do
					task.wait(1)
				end
			end
			task.wait(2)
		else
			-- ===== Match phase =====
			phase = "ingame"
			print("[AF] match: farming start")
			-- wait char ready (spawn/respawn load)
			local charWait = os.clock()
			while running and os.clock() - charWait < 30 do
				local ch = LocalPlayer.Character
				local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
				local hum = ch and ch:FindFirstChildOfClass("Humanoid")
				if hrp and hum and hum.Health > 0 then break end
				task.wait(1)
			end
			-- build platform + teleport
			local floor = ensurePlatform()
			task.wait(1)
			local char = LocalPlayer.Character
			if char then
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if hrp then
					hrp.Anchored = false
					if floor then
						hrp.CFrame = CFrame.new(floor.Position + Vector3.new(0, 3, 0))
					end
				end
			end
			ensureEquipped()

			-- load attack protocol
			local packets = nil
			pcall(function()
				packets = require(ReplicatedStorage.Modules:WaitForChild("packets", 10))
			end)
			local sendInstant = packets and packets.packets and packets.packets.gunSendInstantClient and packets.packets.gunSendInstantClient.send
			local currentSend = sendInstant or (packets and packets.packets and packets.packets.gunSendDefaultClient and packets.packets.gunSendDefaultClient.send)

			-- in-match loop
			local lastMaintain = 0
			local lastUpgradeCheck = 0
			local upgradeChoosing = false
			local t0 = os.clock()
			while running and not isInLobby() do
				local now = os.clock()
				-- 1) attack (8x per target; getNearestHead is Healer-first)
				local w = getWeapon()
				if w and currentSend then
					local handle = w:FindFirstChild("Handle")
					local fp = handle and handle:FindFirstChild("GunFirePoint")
					if fp then
						local origin = fp.WorldPosition
						local targetPart, targetPos = getNearestHead(origin)
						if targetPart and targetPos then
							local data = { position = origin, target = targetPart, hitposition = targetPos, weapon = w }
							for i = 1, 8 do
								pcall(function() currentSend(data) end)
								shootCount = shootCount + 1
							end
						end
					end
				end

				-- 2) platform + circle maintenance
				if now - lastMaintain > 0.5 then
					lastMaintain = now
					local floor = ensurePlatform()
					local char = LocalPlayer.Character
					if char and floor then
						local hrp = char:FindFirstChild("HumanoidRootPart")
						local hum = char:FindFirstChildOfClass("Humanoid")
						if hrp then
							hrp.Anchored = false
							-- respawn check: if circle hrp is not current char, restart circle + reteleport
							if circleRunning then
								local okRef = false
								pcall(function()
									if _G.AF_circleHrp and _G.AF_circleHrp.Parent == char then
										okRef = true
									end
								end)
								if not okRef then
									stopCircleMove(hrp, hum)
									-- reteleport above platform after respawn
									hrp.CFrame = CFrame.new(floor.Position + Vector3.new(0, 3, 0))
								end
							end
							if not circleRunning then
								startCircleMove(hrp, hum, floor.Position.X, floor.Position.Z)
								_G.AF_circleHrp = hrp
							end
							if (hrp.Position - Vector3.new(floor.Position.X, CIRCLE_Y, floor.Position.Z)).Magnitude > CIRCLE_RADIUS + 30 then
								stopCircleMove(hrp, hum)
								startCircleMove(hrp, hum, floor.Position.X, floor.Position.Z)
								_G.AF_circleHrp = hrp
							end
						end
					end
					ensureEquipped()
				end

				-- 3) upgrade check (every 1s; skip while choosing)
				if now - lastUpgradeCheck > 1 and not upgradeChoosing then
					lastUpgradeCheck = now
					task.spawn(function()
						if upgradeChoosing then return end
						upgradeChoosing = true
						local ev = LocalPlayer.PlayerGui:FindFirstChild("Everything")
						if ev then
							local up = ev:FindFirstChild("Upgrades")
							if up and up.Visible then
								local frame = up:FindFirstChild("Frame")
								if frame then
									local available = {}
									for _, c in ipairs(frame:GetChildren()) do
										if c:IsA("ImageButton") and c.Visible then
											local tl = c:FindFirstChildOfClass("TextLabel")
											if tl and tl.Text ~= "" and tl.Text ~= "template" then
												table.insert(available, { name = tl.Text, btn = c })
											end
										end
									end
									if #available > 0 then
										local best, bestScore = nil, -1
										for _, a in ipairs(available) do
											local score = UPGRADE_PRIORITY[a.name] or 0
											if score > bestScore then best, bestScore = a, score end
										end
										if not best then best = available[1] end
										print("[AF] picking upgrade: " .. best.name)
										task.wait(1.2)
										-- method 1: firesignal (VERIFIED: triggers game callback -> FireServer + card display)
										clickButton(best.btn)
										task.wait(1)
										-- method 2: only if panel still open (callback missed), FireServer direct
										if up.Visible then
											print("[AF] upgrade callback missed, FireServer fallback")
											local upgradesRemote = ReplicatedStorage.Remotes:FindFirstChild("upgrades")
											if upgradesRemote then
												pcall(function() upgradesRemote:FireServer(best.name) end)
											end
										end
										task.wait(0.3)
										pcall(function()
											up.Visible = false
											local blur = Lighting:FindFirstChild("EverythingUIBlur")
											if blur then blur.Enabled = false end
										end)
									end
								end
							end
						end
						upgradeChoosing = false
					end)
				end

				-- 4) match end detect
				if detectAndReturn() then
					local tb = os.clock()
					while running and not isInLobby() and os.clock() - tb < 40 do
						task.wait(2)
					end
					break
				end

				task.wait(0.016)
			end
		end
		task.wait(1)
	end
end)

-- ========== UI ==========
-- safe wait for PlayerGui
local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
local pgWaitT0 = os.clock()
while not playerGui and os.clock() - pgWaitT0 < 30 do
	task.wait(0.5)
	playerGui = LocalPlayer:FindFirstChild("PlayerGui")
end
if not playerGui then
	warn("[AF] PlayerGui not ready, UI skip")
	playerGui = Instance.new("ScreenGui") -- placeholder to avoid nil later
end

local sg = Instance.new("ScreenGui")
sg.Name = "AutoFarmUI"
sg.ResetOnSpawn = false
sg.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 280, 0, 130)
frame.Position = UDim2.new(0.5, -140, 0.1, 0)
frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
frame.BackgroundTransparency = 0.15
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = sg

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 24)
title.BackgroundTransparency = 1
title.Text = "[AF] AutoFarm FINAL"
title.TextColor3 = Color3.fromRGB(100, 220, 255)
title.TextSize = 15
title.Font = Enum.Font.GothamBold
title.Parent = frame

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 20)
status.Position = UDim2.new(0, 8, 0, 26)
status.BackgroundTransparency = 1
status.Text = "Phase: " .. phase
status.TextColor3 = Color3.fromRGB(150, 255, 150)
status.TextSize = 12
status.Font = Enum.Font.Gotham
status.Parent = frame

local countLabel = Instance.new("TextLabel")
countLabel.Size = UDim2.new(1, -16, 0, 20)
countLabel.Position = UDim2.new(0, 8, 0, 46)
countLabel.BackgroundTransparency = 1
countLabel.Text = "Shots: 0"
countLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
countLabel.TextSize = 12
countLabel.Font = Enum.Font.Gotham
countLabel.Parent = frame

local camBtn = Instance.new("TextButton")
camBtn.Size = UDim2.new(1, -16, 0, 26)
camBtn.Position = UDim2.new(0, 8, 0, 68)
camBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 200)
camBtn.BorderSizePixel = 0
camBtn.Text = "[CAM] Freecam: OFF (V)"
camBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
camBtn.TextSize = 12
camBtn.Font = Enum.Font.GothamBold
camBtn.Parent = frame

camBtn.MouseButton1Click:Connect(function()
	setFreecam(not freecam.enabled)
	camBtn.Text = freecam.enabled and "[CAM] Freecam: ON (V)" or "[CAM] Freecam: OFF (V)"
	camBtn.BackgroundColor3 = freecam.enabled and Color3.fromRGB(50, 180, 80) or Color3.fromRGB(60, 120, 200)
end)

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(1, -16, 0, 26)
btn.Position = UDim2.new(0, 8, 0, 98)
btn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
btn.BorderSizePixel = 0
btn.Text = "[X] Stop and Cleanup"
btn.TextColor3 = Color3.fromRGB(255, 255, 255)
btn.TextSize = 12
btn.Font = Enum.Font.GothamBold
btn.Parent = frame

btn.MouseButton1Click:Connect(function()
	pcall(function() _G.AutoFarmFinal.Cleanup() end)
end)

local uiConn = RunService.Heartbeat:Connect(function()
	if status and status.Parent then status.Text = "Phase: " .. phase end
	if countLabel and countLabel.Parent then countLabel.Text = "Shots: " .. shootCount end
end)

-- ========== Cleanup ==========
_G.AutoFarmFinal = {
	Cleanup = function()
		running = false
		local char = LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		stopCircleMove(hrp, hum)
		setFreecam(false)
		pcall(task.cancel, mainThread)
		pcall(uiConn.Disconnect, uiConn)
		for _, c in ipairs(freecam.conns) do pcall(c.Disconnect, c) end
		freecam.conns = {}
		if sg then pcall(function() sg:Destroy() end) end
		sg = nil
		if _G.FarmPlatform then pcall(function() _G.FarmPlatform:Destroy() end) end
		_G.FarmPlatform = nil
		_G.AutoFarmFinal = nil
	end,
}

print("[AF] FINAL loaded. Now: " .. (isInLobby() and "lobby" or "in match"))
