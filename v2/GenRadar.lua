--声明:当前脚本由我和ai共同制作，请勿用于非法用途。
-- ============================================
-- Internal Radar全图通用版 v2.0
-- 全地图通用 NPC/玩家检测 运行微优化 
-- ============================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

-- ============================================
-- 配置中心（所有可调参数集中管理）
-- ============================================
local RadarConfig = {
    -- 核心开关
    Enabled = true,
    ShowNPC = true,
    ShowPlayers = true,

    -- 扫描范围
    Range = 500,
    MaxRange = 10000,
    ZoomLevel = 1,

    -- 雷达外观
    Size = 200,
    MinSize = 80,
    MaxSize = 400,
    Position = UDim2.new(0.02, 0, 0.15, 0),
    ShowHeightDiff = true,
    MinHeightDiff = 3,
    MiniMode = false,

    -- 通用扫描模式（全图通用核心）
    UniversalScan = true,       -- 开启后扫描 workspace 下所有带 Humanoid 的非玩家模型
    ScanByTag = false,          -- 通过 Tag 检测实体（需游戏使用 CollectionService 标签）
    TagName = "Enemy",          -- 要扫描的 Tag 名称
    ScanByAttribute = false,    -- 通过 Attribute 检测实体
    AttributeName = "NPC",      -- 要扫描的 Attribute 名称

    -- 文件夹名白名单（按优先级排列，匹配到即停止向下扫描）
    EntityFolders = {
        -- 僵尸/生存类
        "Zombies", "Zombie", "Infected", "Undead", "Ghouls", "Ghoul",
        -- 通用敌人
        "Enemies", "Enemy", "NPCs", "NPC", "Mobs", "Mob",
        "Monsters", "Monster", "Creatures", "Creature",
        "Bots", "Bot", "AI", "Drones", "Drone",
        --  spawned/动态生成
        "Spawned", "Entities", "Entity", "Projectiles",
        "Hostiles", "Hostile", "Foes", "Foe",
        -- 常见游戏命名
        "MonstersNPC", "BadGuys", "Villains", "Pirates",
        "Soldiers", "Soldier", "Guards", "Guard",
        "Animals", "Animal", "Beasts", "Beast",
        -- 特殊类型
        "Bosses", "Boss", "Elite", "Elites",
        "Minions", "Minion", "Summons", "Summon",
    },

    -- 名称关键词匹配（兜底，当文件夹名不匹配时通过名称判断）
    NameKeywords = {
        "zombie", "npc", "enemy", "mob", "monster",
        "creature", "bot", "ai", "ghost", "skeleton",
        "zombie", "infected", "undead", "ghoul", "demon",
        "devil", "orc", "goblin", "troll", "giant",
        "dragon", "snake", "spider", "wolf", "bear",
        "boss", "elite", "minion", "summon", "drone",
        "soldier", "guard", "pirate", "villain",
    },
}

-- ============================================
-- 配置持久化
-- ============================================
local function loadConfig()
    pcall(function()
        local json = readfile("delta_radar_config.json")
        if json then
            local loaded = HttpService:JSONDecode(json)
            for k, v in pairs(loaded) do
                if RadarConfig[k] ~= nil then RadarConfig[k] = v end
            end
        end
    end)
end

local function saveConfig()
    pcall(function() writefile("delta_radar_config.json", HttpService:JSONEncode(RadarConfig)) end)
end

loadConfig()

-- ============================================
-- 工具函数
-- ============================================
local function getRootPart(model)
    if not model or not model:IsA("Model") then return nil end
    -- 优先级：HumanoidRootPart > PrimaryPart > Torso > UpperTorso > Head > 任意BasePart
    return model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
        or model:FindFirstChild("Torso")
        or model:FindFirstChild("UpperTorso")
        or model:FindFirstChild("Head")
        or model:FindFirstChildWhichIsA("BasePart")
end

local function getHealth(model)
    -- 1. Humanoid（最常见）
    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum then
        return hum.Health, hum.MaxHealth or 100
    end
    -- 2. Attribute（部分游戏用属性存储血量）
    local hp = model:GetAttribute("Health") or model:GetAttribute("HP") or model:GetAttribute("health")
    local maxHp = model:GetAttribute("MaxHealth") or model:GetAttribute("MaxHP") or model:GetAttribute("maxHealth")
    if hp then
        return hp, maxHp or 100
    end
    -- 3. 子对象查找（部分游戏把HumanoidHealth放在子对象中）
    local healthObj = model:FindFirstChild("Health") or model:FindFirstChild("HP")
    if healthObj and healthObj:IsA("NumberValue") then
        local maxObj = model:FindFirstChild("MaxHealth") or model:FindFirstChild("MaxHP")
        return healthObj.Value, maxObj and maxObj.Value or 100
    end
    return 100, 100
end

-- 判断是否为玩家角色
local playerCharSet = {}
local function updatePlayerChars()
    playerCharSet = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then playerCharSet[p.Character] = true end
    end
end

-- 判断模型是否可能是 NPC/敌人
local function isLikelyNPC(model, myChar)
    if not model:IsA("Model") or model == myChar then return false end
    if playerCharSet[model] then return false end

    -- 方法1：在已知实体文件夹中
    local parent = model.Parent
    if parent then
        local parentName = parent.Name
        for _, folderName in ipairs(RadarConfig.EntityFolders) do
            if parentName == folderName then return true end
        end
    end

    -- 方法2：名称关键词匹配
    local modelName = model.Name:lower()
    for _, keyword in ipairs(RadarConfig.NameKeywords) do
        if modelName:find(keyword, 1, true) then return true end
    end

    -- 方法3：Attribute 检测
    if RadarConfig.ScanByAttribute then
        local attrName = RadarConfig.AttributeName
        if model:GetAttribute(attrName) ~= nil then return true end
        -- 也检查常见的 attribute 名
        if model:GetAttribute("NPC") or model:GetAttribute("enemy") or model:GetAttribute("Hostile") then
            return true
        end
    end

    -- 方法4：Tag 检测
    if RadarConfig.ScanByTag then
        local tagName = RadarConfig.TagName
        local collectionService = game:GetService("CollectionService")
        if collectionService:HasTag(model, tagName) then return true end
        -- 也检查常见的 tag 名
        if collectionService:HasTag(model, "Enemy") or collectionService:HasTag(model, "NPC") then
            return true
        end
    end

    -- 方法5：通用启发式检测（最后手段，性能开销较大）
    local hasHumanoid = model:FindFirstChildOfClass("Humanoid") ~= nil
    local hasAnimCtrl = model:FindFirstChildOfClass("AnimationController") ~= nil
        or model:FindFirstChildOfClass("Animator") ~= nil
    local root = getRootPart(model)
    local partCount = 0
    for _, c in ipairs(model:GetDescendants()) do
        if c:IsA("BasePart") then
            partCount = partCount + 1
            if partCount > 3 then break end
        end
    end

    -- 有 Humanoid 或有动画控制器 + 有根部件 + 部件数>2 => 可能是 NPC
    if hasHumanoid and root and partCount > 2 then return true end
    if hasAnimCtrl and root and partCount > 2 then return true end

    return false
end

-- 分类实体类型
local function classifyEntity(model)
    local name = model.Name:lower()
    if name:find("boss", 1, true) then return "boss"
    elseif name:find("elite", 1, true) then return "elite"
    elseif name:find("minion", 1, true) or name:find("summon", 1, true) then return "minion"
    elseif name:find("zombie", 1, true) or name:find("infected", 1, true) or name:find("undead", 1, true) then return "zombie"
    elseif name:find("npc", 1, true) or name:find("enemy", 1, true) or name:find("mob", 1, true) then return "npc"
    else return "npc"
    end
end

-- ============================================
-- GUI 构建
-- ============================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DeltaRadarV2"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() ScreenGui.Parent = game:GetService("CoreGui") end)
if not ScreenGui.Parent then
    pcall(function() ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end)
end

-- 主雷达框架
local RadarFrame = Instance.new("Frame")
RadarFrame.Name = "RadarFrame"
RadarFrame.Size = UDim2.new(0, RadarConfig.Size, 0, RadarConfig.Size)
RadarFrame.Position = RadarConfig.Position
RadarFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
RadarFrame.BackgroundTransparency = 0.7
RadarFrame.BorderSizePixel = 0
RadarFrame.Active = true
RadarFrame.Draggable = true
RadarFrame.Parent = ScreenGui

Instance.new("UICorner", RadarFrame).CornerRadius = UDim.new(1, 0)

local Border = Instance.new("UIStroke", RadarFrame)
Border.Color = Color3.fromRGB(0, 255, 0)
Border.Thickness = 2

-- 按钮
local function createButton(parent, name, size, pos, bg, text, textColor, textTransparency)
    local btn = Instance.new("TextButton")
    btn.Name = name
    btn.Size = size
    btn.Position = pos
    btn.BackgroundColor3 = bg
    btn.Text = text
    btn.TextColor3 = textColor
    btn.TextSize = 14
    btn.Font = Enum.Font.SourceSansBold
    btn.Parent = parent
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    return btn
end

-- 设置按钮
local SettingsBtn = createButton(RadarFrame, "SettingsBtn",
    UDim2.new(0, 28, 0, 28), UDim2.new(1, -30, 0, 2),
    Color3.fromRGB(50, 50, 50), "⚙", Color3.fromRGB(0, 255, 0))

-- 迷你模式按钮
local MiniBtn = createButton(RadarFrame, "MiniBtn",
    UDim2.new(0, 24, 0, 24), UDim2.new(0, 2, 0, 2),
    Color3.fromRGB(100, 100, 100), "−", Color3.fromRGB(255, 255, 255))

-- 缩放拖拽手柄
local ResizeHandle = createButton(RadarFrame, "ResizeHandle",
    UDim2.new(0, 20, 0, 20), UDim2.new(1, -22, 1, -22),
    Color3.fromRGB(0, 200, 0), "↔", Color3.fromRGB(255, 255, 255))

-- 信息标签
local function createLabel(parent, name, size, pos, text, color)
    local l = Instance.new("TextLabel")
    l.Name = name
    l.Size = size
    l.Position = pos
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = color
    l.TextSize = 11
    l.Font = Enum.Font.SourceSans
    l.Parent = parent
    return l
end

local ZoomLabel = createLabel(RadarFrame, "ZoomLabel",
    UDim2.new(0, 50, 0, 18), UDim2.new(0.5, -25, 0, 2), "1.0x", Color3.fromRGB(0, 255, 0))

local RangeLabel = createLabel(RadarFrame, "RangeLabel",
    UDim2.new(1, 0, 0, 18), UDim2.new(0, 0, 1, -18), "R:500m", Color3.fromRGB(0, 255, 0))

local CountLabel = createLabel(RadarFrame, "CountLabel",
    UDim2.new(1, 0, 0, 18), UDim2.new(0, 0, 0, 22), "P:0 N:0", Color3.fromRGB(0, 255, 0))

-- 十字线
local CrossH = Instance.new("Frame", RadarFrame)
CrossH.Size = UDim2.new(0.6, 0, 0, 1)
CrossH.Position = UDim2.new(0.2, 0, 0.5, 0)
CrossH.BackgroundColor3 = Color3.fromRGB(0, 255, 0)
CrossH.BackgroundTransparency = 0.3
CrossH.BorderSizePixel = 0

local CrossV = Instance.new("Frame", RadarFrame)
CrossV.Size = UDim2.new(0, 1, 0.6, 0)
CrossV.Position = UDim2.new(0.5, 0, 0.2, 0)
CrossV.BackgroundColor3 = Color3.fromRGB(0, 255, 0)
CrossV.BackgroundTransparency = 0.3
CrossV.BorderSizePixel = 0

-- 中心点
local CenterDot = Instance.new("Frame", RadarFrame)
CenterDot.Size = UDim2.new(0, 6, 0, 6)
CenterDot.Position = UDim2.new(0.5, -3, 0.5, -3)
CenterDot.BackgroundColor3 = Color3.fromRGB(0, 255, 255)
CenterDot.BorderSizePixel = 0
Instance.new("UICorner", CenterDot).CornerRadius = UDim.new(1, 0)

-- 方向标记
for _, dirInfo in ipairs({
    {name = "N", pos = UDim2.new(0.5, -10, 0, 2)},
    {name = "S", pos = UDim2.new(0.5, -10, 1, -22)},
    {name = "W", pos = UDim2.new(0, 2, 0.5, -10)},
    {name = "E", pos = UDim2.new(1, -22, 0.5, -10)},
}) do
    local l = Instance.new("TextLabel", RadarFrame)
    l.Size = UDim2.new(0, 20, 0, 20)
    l.Position = dirInfo.pos
    l.BackgroundTransparency = 1
    l.Text = dirInfo.name
    l.TextColor3 = Color3.fromRGB(0, 255, 0)
    l.TextSize = 14
    l.Font = Enum.Font.SourceSansBold
end

-- ============================================
-- 迷你模式
-- ============================================
local NormalSize = RadarConfig.Size
local NormalPos = RadarConfig.Position

local function setMiniMode(mini)
    RadarConfig.MiniMode = mini
    if mini then
        NormalSize = RadarConfig.Size
        NormalPos = RadarFrame.Position
        RadarConfig.Size = 40
        RadarFrame.Size = UDim2.new(0, 40, 0, 40)
        RadarFrame.BackgroundTransparency = 0.9
        Border.Thickness = 1
        CrossH.Visible = false
        CrossV.Visible = false
        CenterDot.Visible = false
        CountLabel.Visible = false
        RangeLabel.Visible = false
        ZoomLabel.Visible = false
        ResizeHandle.Visible = false
        SettingsBtn.Visible = false
        MiniBtn.Text = "+"
        MiniBtn.Size = UDim2.new(1, -4, 1, -4)
        MiniBtn.Position = UDim2.new(0, 2, 0, 2)
        for _, d in pairs(TargetDots) do d.Visible = false end
    else
        RadarConfig.Size = NormalSize
        RadarFrame.Size = UDim2.new(0, RadarConfig.Size, 0, RadarConfig.Size)
        RadarFrame.Position = NormalPos
        RadarFrame.BackgroundTransparency = 0.7
        Border.Thickness = 2
        CrossH.Visible = true
        CrossV.Visible = true
        CenterDot.Visible = true
        CountLabel.Visible = true
        RangeLabel.Visible = true
        ZoomLabel.Visible = true
        ResizeHandle.Visible = true
        SettingsBtn.Visible = true
        MiniBtn.Text = "−"
        MiniBtn.Size = UDim2.new(0, 24, 0, 24)
        MiniBtn.Position = UDim2.new(0, 2, 0, 2)
    end
    saveConfig()
end

MiniBtn.MouseButton1Click:Connect(function()
    setMiniMode(not RadarConfig.MiniMode)
end)

-- ============================================
-- UI 缩放（拖拽右下角）
-- ============================================
local resizing = false
local startSize, startPos

ResizeHandle.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        resizing = true
        startSize = RadarFrame.AbsoluteSize
        startPos = input.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - startPos
        local newSize = math.clamp(startSize.X + delta.X, RadarConfig.MinSize, RadarConfig.MaxSize)
        RadarConfig.Size = newSize
        RadarFrame.Size = UDim2.new(0, newSize, 0, newSize)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if resizing then
            resizing = false
            saveConfig()
        end
    end
end)

-- ============================================
-- 范围缩放（滚轮）
-- ============================================
UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseWheel then
        local radarPos = RadarFrame.AbsolutePosition
        local radarSize = RadarFrame.AbsoluteSize
        local mousePos = UserInputService:GetMouseLocation()

        if mousePos.X >= radarPos.X and mousePos.X <= radarPos.X + radarSize.X and
           mousePos.Y >= radarPos.Y and mousePos.Y <= radarPos.Y + radarSize.Y then

            local delta = input.Position.Z > 0 and 0.1 or -0.1
            RadarConfig.ZoomLevel = math.clamp(RadarConfig.ZoomLevel + delta, 0.1, 5)
            ZoomLabel.Text = string.format("%.1fx", RadarConfig.ZoomLevel)
            saveConfig()
        end
    end
end)

-- ============================================
-- 目标点池（对象池模式，减少 GC）
-- ============================================
local TargetDots = {}
local TargetData = {}

local function createDot()
    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 8, 0, 8)
    dot.BorderSizePixel = 0
    dot.Visible = false
    dot.Parent = RadarFrame
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    local h = Instance.new("TextLabel", dot)
    h.Name = "Height"
    h.Size = UDim2.new(0, 30, 0, 14)
    h.Position = UDim2.new(0.5, -15, 0, -16)
    h.BackgroundTransparency = 1
    h.Text = ""
    h.TextColor3 = Color3.fromRGB(255, 255, 0)
    h.TextSize = 10
    h.Font = Enum.Font.SourceSansBold

    -- 点击事件
    dot.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            local data = TargetData[dot]
            if data then
                showSettings(data)
            end
        end
    end)

    return dot
end

local function getDot(i)
    if not TargetDots[i] then TargetDots[i] = createDot() end
    return TargetDots[i]
end

-- ============================================
-- 核心扫描逻辑（全图通用）
-- ============================================
local function scanAllTargets()
    local targets = {}
    if RadarConfig.MiniMode then return targets end

    local myChar = LocalPlayer.Character
    if not myChar then return targets end

    local myRoot = getRootPart(myChar)
    if not myRoot then return targets end

    local myPos = myRoot.Position
    local myLook = myRoot.CFrame.LookVector
    local myTeam = tostring(LocalPlayer.Team)
    local displayRange = RadarConfig.Range * RadarConfig.ZoomLevel

    updatePlayerChars()

    -- ========== 玩家扫描 ==========
    if RadarConfig.ShowPlayers then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                local char = player.Character
                local root = char and getRootPart(char)
                if root then
                    local pos = root.Position
                    local rel = pos - myPos
                    local dist = rel.Magnitude

                    if dist <= displayRange then
                        local angle = math.atan2(
                            rel.X * myLook.Z - rel.Z * myLook.X,
                            rel.X * myLook.X + rel.Z * myLook.Z
                        )
                        local hp, maxHp = getHealth(char)

                        table.insert(targets, {
                            type = "player",
                            name = player.Name,
                            distance = dist,
                            health = hp,
                            maxHealth = maxHp,
                            isEnemy = tostring(player.Team) ~= myTeam,
                            radarX = math.sin(angle) * (dist / displayRange),
                            radarY = -math.cos(angle) * (dist / displayRange),
                            heightDiff = pos.Y - myPos.Y,
                        })
                    end
                end
            end
        end
    end

    -- ========== NPC/实体扫描 ==========
    if RadarConfig.ShowNPC then
        local scanned = {}

        -- 策略1：扫描已知文件夹
        for _, folderName in ipairs(RadarConfig.EntityFolders) do
            local folder = workspace:FindFirstChild(folderName)
            if folder then
                for _, obj in ipairs(folder:GetChildren()) do
                    if obj:IsA("Model") and not scanned[obj] and not playerCharSet[obj] then
                        if isLikelyNPC(obj, myChar) then
                            scanned[obj] = true
                            local root = getRootPart(obj)
                            if root then
                                local pos = root.Position
                                local rel = pos - myPos
                                local dist = rel.Magnitude

                                if dist <= displayRange then
                                    local angle = math.atan2(
                                        rel.X * myLook.Z - rel.Z * myLook.X,
                                        rel.X * myLook.X + rel.Z * myLook.Z
                                    )
                                    local hp, maxHp = getHealth(obj)
                                    local npcType = classifyEntity(obj)

                                    table.insert(targets, {
                                        type = npcType,
                                        name = obj.Name,
                                        distance = dist,
                                        health = hp,
                                        maxHealth = maxHp,
                                        isEnemy = true,
                                        radarX = math.sin(angle) * (dist / displayRange),
                                        radarY = -math.cos(angle) * (dist / displayRange),
                                        heightDiff = pos.Y - myPos.Y,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end

        -- 策略2：通用扫描（UniversalScan）- 扫描 workspace 下所有符合条件的模型
        if RadarConfig.UniversalScan then
            for _, obj in ipairs(workspace:GetChildren()) do
                if obj:IsA("Model") and not scanned[obj] and not playerCharSet[obj] and obj ~= myChar then
                    if isLikelyNPC(obj, myChar) then
                        scanned[obj] = true
                        local root = getRootPart(obj)
                        if root then
                            local pos = root.Position
                            local rel = pos - myPos
                            local dist = rel.Magnitude

                            if dist <= displayRange then
                                local angle = math.atan2(
                                    rel.X * myLook.Z - rel.Z * myLook.X,
                                    rel.X * myLook.X + rel.Z * myLook.Z
                                )
                                local hp, maxHp = getHealth(obj)
                                local npcType = classifyEntity(obj)

                                table.insert(targets, {
                                    type = npcType,
                                    name = obj.Name,
                                    distance = dist,
                                    health = hp,
                                    maxHealth = maxHp,
                                    isEnemy = true,
                                    radarX = math.sin(angle) * (dist / displayRange),
                                    radarY = -math.cos(angle) * (dist / displayRange),
                                    heightDiff = pos.Y - myPos.Y,
                                })
                            end
                        end
                    end
                end
            end
        end

        -- 策略3：递归扫描子文件夹（处理嵌套结构）
        for _, obj in ipairs(workspace:GetChildren()) do
            if obj:IsA("Folder") or obj:IsA("Model") then
                for _, child in ipairs(obj:GetDescendants()) do
                    if child:IsA("Model") and not scanned[child] and not playerCharSet[child] and child ~= myChar then
                        if isLikelyNPC(child, myChar) then
                            scanned[child] = true
                            local root = getRootPart(child)
                            if root then
                                local pos = root.Position
                                local rel = pos - myPos
                                local dist = rel.Magnitude

                                if dist <= displayRange then
                                    local angle = math.atan2(
                                        rel.X * myLook.Z - rel.Z * myLook.X,
                                        rel.X * myLook.X + rel.Z * myLook.Z
                                    )
                                    local hp, maxHp = getHealth(child)
                                    local npcType = classifyEntity(child)

                                    table.insert(targets, {
                                        type = npcType,
                                        name = child.Name,
                                        distance = dist,
                                        health = hp,
                                        maxHealth = maxHp,
                                        isEnemy = true,
                                        radarX = math.sin(angle) * (dist / displayRange),
                                        radarY = -math.cos(angle) * (dist / displayRange),
                                        heightDiff = pos.Y - myPos.Y,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 按距离排序
    table.sort(targets, function(a, b) return a.distance < b.distance end)
    return targets
end

-- ============================================
-- 更新显示
-- ============================================
local function updateRadar()
    if not RadarConfig.Enabled then
        for _, d in pairs(TargetDots) do d.Visible = false end
        return
    end

    local targets = scanAllTargets()
    local displayRange = RadarConfig.Range * RadarConfig.ZoomLevel

    -- 统计
    local pCount = 0
    local nCount = 0
    local zCount = 0
    for _, t in ipairs(targets) do
        if t.type == "player" then pCount = pCount + 1
        elseif t.type == "zombie" then zCount = zCount + 1
        else nCount = nCount + 1 end
    end
    CountLabel.Text = string.format("P:%d Z:%d N:%d", pCount, zCount, nCount)
    RangeLabel.Text = "R:" .. math.floor(displayRange) .. "m"
    ZoomLabel.Text = string.format("%.1fx", RadarConfig.ZoomLevel)

    -- 更新点
    for i, target in ipairs(targets) do
        local dot = getDot(i)
        local sx = 0.5 + target.radarX * 0.5
        local sy = 0.5 + target.radarY * 0.5

        local dx, dy = sx - 0.5, sy - 0.5
        if math.sqrt(dx*dx + dy*dy) <= 0.5 then
            dot.Visible = true
            dot.Position = UDim2.new(0, sx * RadarConfig.Size - 4, 0, sy * RadarConfig.Size - 4)

            -- 根据类型设置颜色
            if target.type == "player" then
                dot.BackgroundColor3 = target.isEnemy and Color3.fromRGB(255, 0, 0) or Color3.fromRGB(0, 150, 255)
            elseif target.type == "zombie" then
                dot.BackgroundColor3 = Color3.fromRGB(255, 255, 0)
            elseif target.type == "boss" then
                dot.BackgroundColor3 = Color3.fromRGB(255, 0, 255)
            elseif target.type == "elite" then
                dot.BackgroundColor3 = Color3.fromRGB(255, 100, 0)
            else
                dot.BackgroundColor3 = Color3.fromRGB(255, 165, 0)
            end

            -- 高度差标签
            local hLabel = dot:FindFirstChild("Height")
            if hLabel and RadarConfig.ShowHeightDiff then
                local h = target.heightDiff
                if math.abs(h) >= RadarConfig.MinHeightDiff then
                    hLabel.Text = h > 0 and ("+"..math.floor(h)) or tostring(math.floor(h))
                    hLabel.TextColor3 = h > 0 and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 100, 100)
                else
                    hLabel.Text = ""
                end
            end

            TargetData[dot] = target
        else
            dot.Visible = false
        end
    end

    -- 隐藏多余点
    for i = #targets + 1, #TargetDots do
        TargetDots[i].Visible = false
    end
end

-- ============================================
-- 设置面板
-- ============================================
local SettingsFrame = nil

local function closeSettings()
    if SettingsFrame then
        SettingsFrame:Destroy()
        SettingsFrame = nil
    end
end

local function showSettings(target)
    closeSettings()

    local frame = Instance.new("Frame")
    frame.Name = "SettingsFrame"
    frame.Size = UDim2.new(0, 300, 0, 400)
    frame.Position = UDim2.new(0.5, -150, 0.5, -200)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
    frame.BackgroundTransparency = 0.05
    frame.BorderSizePixel = 0
    frame.ZIndex = 100
    frame.Parent = ScreenGui

    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

    local stroke = Instance.new("UIStroke", frame)
    stroke.Color = Color3.fromRGB(0, 255, 0)
    stroke.Thickness = 2

    -- 标题
    local title = Instance.new("TextLabel", frame)
    title.Size = UDim2.new(1, 0, 0, 32)
    title.Position = UDim2.new(0, 0, 0, 5)
    title.BackgroundTransparency = 1
    title.Text = target and ("🔍 " .. target.name) or "⚙ Radar Settings"
    title.TextColor3 = Color3.fromRGB(0, 255, 0)
    title.TextSize = 16
    title.Font = Enum.Font.SourceSansBold

    -- 关闭按钮
    local closeBtn = Instance.new("TextButton", frame)
    closeBtn.Size = UDim2.new(0, 28, 0, 28)
    closeBtn.Position = UDim2.new(1, -32, 0, 4)
    closeBtn.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.TextSize = 14
    closeBtn.Font = Enum.Font.SourceSansBold
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
    closeBtn.MouseButton1Click:Connect(closeSettings)

    local y = 42
    if target then
        local infos = {
            { "Type", target.type == "npc" and "🟡 NPC" or (target.isEnemy and "🔴 Enemy" or "🔵 Ally") },
            { "Distance", string.format("%.1f m", target.distance) },
            { "Health", string.format("%.0f / %.0f", target.health, target.maxHealth) },
            { "Height", string.format("%.1f m", target.heightDiff) },
        }
        for _, info in ipairs(infos) do
            local l = Instance.new("TextLabel", frame)
            l.Size = UDim2.new(1, -20, 0, 22)
            l.Position = UDim2.new(0, 10, 0, y)
            l.BackgroundTransparency = 1
            l.Text = info[1] .. ": " .. info[2]
            l.TextColor3 = Color3.fromRGB(220, 220, 220)
            l.TextSize = 14
            l.Font = Enum.Font.SourceSans
            l.TextXAlignment = Enum.TextXAlignment.Left
            y = y + 24
        end
        y = y + 8
    end

    -- 开关函数
    local function toggle(name, key, yPos)
        local l = Instance.new("TextLabel", frame)
        l.Size = UDim2.new(0, 150, 0, 26)
        l.Position = UDim2.new(0, 10, 0, yPos)
        l.BackgroundTransparency = 1
        l.Text = name
        l.TextColor3 = Color3.fromRGB(200, 200, 200)
        l.TextSize = 14
        l.Font = Enum.Font.SourceSans
        l.TextXAlignment = Enum.TextXAlignment.Left

        local btn = Instance.new("TextButton", frame)
        btn.Size = UDim2.new(0, 55, 0, 24)
        btn.Position = UDim2.new(0, 170, 0, yPos + 1)
        btn.BackgroundColor3 = RadarConfig[key] and Color3.fromRGB(0, 180, 0) or Color3.fromRGB(180, 0, 0)
        btn.Text = RadarConfig[key] and "ON" or "OFF"
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.TextSize = 12
        btn.Font = Enum.Font.SourceSansBold
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

        btn.MouseButton1Click:Connect(function()
            RadarConfig[key] = not RadarConfig[key]
            btn.BackgroundColor3 = RadarConfig[key] and Color3.fromRGB(0, 180, 0) or Color3.fromRGB(180, 0, 0)
            btn.Text = RadarConfig[key] and "ON" or "OFF"
            saveConfig()
        end)

        return yPos + 32
    end

    y = toggle("Show Players", "ShowPlayers", y)
    y = toggle("Show NPCs", "ShowNPC", y)
    y = toggle("Universal Scan", "UniversalScan", y)
    y = toggle("Show Height", "ShowHeightDiff", y)

    -- 范围
    local rangeLabel = Instance.new("TextLabel", frame)
    rangeLabel.Size = UDim2.new(1, -20, 0, 26)
    rangeLabel.Position = UDim2.new(0, 10, 0, y)
    rangeLabel.BackgroundTransparency = 1
    rangeLabel.Text = "📏 Range: " .. RadarConfig.Range .. "m"
    rangeLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    rangeLabel.TextSize = 14
    rangeLabel.Font = Enum.Font.SourceSans
    rangeLabel.TextXAlignment = Enum.TextXAlignment.Left

    local rMinus = Instance.new("TextButton", frame)
    rMinus.Size = UDim2.new(0, 32, 0, 24)
    rMinus.Position = UDim2.new(0, 10, 0, y + 26)
    rMinus.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    rMinus.Text = "−"
    rMinus.TextColor3 = Color3.fromRGB(255, 255, 255)
    rMinus.TextSize = 16
    rMinus.Font = Enum.Font.SourceSansBold

    local rPlus = Instance.new("TextButton", frame)
    rPlus.Size = UDim2.new(0, 32, 0, 24)
    rPlus.Position = UDim2.new(0, 50, 0, y + 26)
    rPlus.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    rPlus.Text = "+"
    rPlus.TextColor3 = Color3.fromRGB(255, 255, 255)
    rPlus.TextSize = 16
    rPlus.Font = Enum.Font.SourceSansBold

    local rStep = math.max(50, math.floor(RadarConfig.Range / 5))

    rMinus.MouseButton1Click:Connect(function()
        RadarConfig.Range = math.max(50, RadarConfig.Range - rStep)
        rangeLabel.Text = "📏 Range: " .. RadarConfig.Range .. "m"
        saveConfig()
    end)
    rPlus.MouseButton1Click:Connect(function()
        RadarConfig.Range = math.min(RadarConfig.MaxRange, RadarConfig.Range + rStep)
        rangeLabel.Text = "📏 Range: " .. RadarConfig.Range .. "m"
        saveConfig()
    end)

    y = y + 58

    -- 缩放级别
    local zoomLabel = Instance.new("TextLabel", frame)
    zoomLabel.Size = UDim2.new(1, -20, 0, 26)
    zoomLabel.Position = UDim2.new(0, 10, 0, y)
    zoomLabel.BackgroundTransparency = 1
    zoomLabel.Text = "🔍 Zoom: " .. string.format("%.1fx", RadarConfig.ZoomLevel)
    zoomLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    zoomLabel.TextSize = 14
    zoomLabel.Font = Enum.Font.SourceSans
    zoomLabel.TextXAlignment = Enum.TextXAlignment.Left

    local zMinus = Instance.new("TextButton", frame)
    zMinus.Size = UDim2.new(0, 32, 0, 24)
    zMinus.Position = UDim2.new(0, 10, 0, y + 26)
    zMinus.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    zMinus.Text = "−"
    zMinus.TextColor3 = Color3.fromRGB(255, 255, 255)
    zMinus.TextSize = 16
    zMinus.Font = Enum.Font.SourceSansBold

    local zPlus = Instance.new("TextButton", frame)
    zPlus.Size = UDim2.new(0, 32, 0, 24)
    zPlus.Position = UDim2.new(0, 50, 0, y + 26)
    zPlus.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    zPlus.Text = "+"
    zPlus.TextColor3 = Color3.fromRGB(255, 255, 255)
    zPlus.TextSize = 16
    zPlus.Font = Enum.Font.SourceSansBold

    zMinus.MouseButton1Click:Connect(function()
        RadarConfig.ZoomLevel = math.clamp(RadarConfig.ZoomLevel - 0.1, 0.1, 5)
        zoomLabel.Text = "🔍 Zoom: " .. string.format("%.1fx", RadarConfig.ZoomLevel)
        saveConfig()
    end)
    zPlus.MouseButton1Click:Connect(function()
        RadarConfig.ZoomLevel = math.clamp(RadarConfig.ZoomLevel + 0.1, 0.1, 5)
        zoomLabel.Text = "🔍 Zoom: " .. string.format("%.1fx", RadarConfig.ZoomLevel)
        saveConfig()
    end)

    SettingsFrame = frame
    print("设置面板已创建")
end

-- 设置按钮点击
SettingsBtn.MouseButton1Click:Connect(function()
    print("⚙ 设置按钮点击")
    showSettings(nil)
end)

-- ============================================
-- 主循环
-- ============================================
local runConn = RunService.RenderStepped:Connect(function()
    if RadarConfig.Enabled then updateRadar() end
end)

-- ============================================
-- 全局控制
-- ============================================
_G.ToggleDeltaRadar = function()
    RadarConfig.Enabled = not RadarConfig.Enabled
    RadarFrame.Visible = RadarConfig.Enabled
    print("[雷达] " .. (RadarConfig.Enabled and "ON" or "OFF"))
end

_G.DisableDeltaRadar = function()
    RadarConfig.Enabled = false
    runConn:Disconnect()
    closeSettings()
    for _, d in pairs(TargetDots) do d:Destroy() end
    RadarFrame:Destroy()
    ScreenGui:Destroy()
    print("[雷达] v2.0 已卸载")
end