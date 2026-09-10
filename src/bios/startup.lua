--[[ Delin BIOS —— 装到电脑自身 FS 的 /startup.lua(CraftOS 开机执行的第一段程序)。
     引导契约: 扫描所有设备(drive 里的磁盘 + 电脑自身存储 "root")找 `/.boot`; `/.boot` 里
     写的是该设备上"内核入口"文件的路径(如 `/boot/delin.lua`), BIOS 就 loadfile 那个文件。
     没有 `/.boot` 的设备不会被选为引导设备。引导顺序由 settings 的 `bootOrder` 记住。
     控制: 启动前 0.1s 内按 DELETE 进设置 TUI(Q 关机 / S 存顺序并重启 / Enter 改引导设备 /
     C 进 CraftOS shell), 否则自动按顺序引导第一个可用设备。 ]]

term.setBackgroundColor(colors.blue)
print("Delin BIOS 0.0.2")
term.setBackgroundColor(colors.black)
print("Press DELETE to enter BIOS settings\n")

---@type number BIOS设置按钮
local BIOS_SETTING_BUTTON = keys.delete

---@type string[] 可以引导的设备(的名称)
local canBootDevices = {}

---@type table<string, string> 可引导设备映射表，键为设备名称，值为设备.boot文件里指向的路径
local bootMap = {}

local bootOrder = settings.get('bootOrder', nil)

-- ========== 扫描可引导设备 ==========
print("Scanning for boot devices...")

---@type string[]
---@description 所有外设名称
local phs = peripheral.getNames()

table.insert(phs, 'root')

for _, name in pairs(phs) do
    if disk.hasData(name) or name == 'root' then
        io.stdout:write(string.format('Scanning %s...', name))
        local ok, err = pcall(function()
            ---@type string|nil
            local mountPoint = name == 'root' and '' or disk.getMountPath(name) -- 下面会加"/"所以这里用空字符串
            if mountPoint then
                local f = io.open(mountPoint .. '/.boot', 'r')
                if f then
                    local line = f:read('*l')
                    if line then
                        local path = mountPoint .. line
                        local ok, data = pcall(function()
                            return fs.exists(path)
                        end)
                        if ok then
                            if data then
                                bootMap[name] = path
                                io.stdout:write('Found valid .boot file\n')
                                table.insert(canBootDevices, name)
                            else
                                error('Unable to find the executable file pointed to by the boot file', 0)
                            end
                        else
                            error('Failed to check if the executable file exists: ' .. data, 0)
                        end
                    end
                    f:close()
                else
                    error('Failed to open .boot file', 0)
                end
            else
                error('Failed to get mount path', 0)
            end
        end)
        if not ok then
            io.stderr:write(err .. '\n')
        end
    end
end

local function deepClone(tbl)
    return textutils.unserialiseJSON(textutils.serialiseJSON(tbl))
end

---@param entryIndex number 当前正在编辑的启动项序号
---@return string 用户选择的设备名称
local function showDevicePicker(entryIndex)
    local pickerIndex = 1
    local w, h = term.getSize()
    local boxW = math.min(40, w - 4)
    local boxH = math.min(#canBootDevices + 6, h - 4)
    local boxX = math.floor((w - boxW) / 2)
    local boxY = math.floor((h - boxH) / 2)
    local listStartY = boxY + 3
    local maxVisible = boxH - 6

    while true do
        -- 绘制覆盖层背景（黑色方块）
        for y = boxY, boxY + boxH - 1 do
            term.setCursorPos(boxX, y)
            term.setBackgroundColor(colors.black)
            term.clearLine()
        end

        -- 标题栏
        term.setCursorPos(boxX + 1, boxY + 1)
        term.setBackgroundColor(colors.blue)
        term.setTextColor(colors.white)
        term.clearLine()
        term.write(string.format('Select device for #%d:', entryIndex))

        -- 设备列表
        for i = 1, math.min(#canBootDevices, maxVisible) do
            local y = listStartY + i - 1
            term.setCursorPos(boxX + 1, y)
            if i == pickerIndex then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
            else
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.white)
            end
            term.clearLine()
            term.write(canBootDevices[i])
        end

        -- 底部提示
        term.setCursorPos(boxX + 1, boxY + boxH - 2)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clearLine()
        term.write('Enter=confirm')

        -- 处理输入
        local _, key = os.pullEvent('key')
        if key == keys.up then
            pickerIndex = math.max(1, pickerIndex - 1)
        elseif key == keys.down then
            pickerIndex = math.min(#canBootDevices, pickerIndex + 1)
        elseif key == keys.enter then
            return canBootDevices[pickerIndex]
        end
    end
end

local function biosTUI()
    local w, h = term.getSize()
    local selectedIndex = 1
    local scrollOffset = 0
    local maxVisible = h - 4 -- 从第4行到h-1行为列表区域，第h行为底部提示栏

    while true do
        -- 清屏
        term.setBackgroundColor(colors.gray)
        term.clear()

        -- 标题
        term.setBackgroundColor(colors.blue)
        term.setTextColor(colors.white)
        term.setCursorPos(1, 1)
        term.clearLine()
        term.write('Delin BIOS 0.0.2')

        -- 启动顺序
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.setCursorPos(1, 3)
        term.clearLine()
        term.write('Boot order:')

        -- 绘制可见的启动项
        local visibleCount = math.min(#bootOrder - scrollOffset, maxVisible)
        for i = 1, visibleCount do
            local idx = scrollOffset + i
            local name = bootOrder[idx]
            local y = i + 3
            if idx == selectedIndex then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
            else
                term.setBackgroundColor(colors.gray)
                term.setTextColor(colors.white)
            end
            term.setCursorPos(2, y)
            term.clearLine()
            term.write(string.format('#%d %s(%s)', idx, name, bootMap[name]))
        end

        -- 清除列表尾部残留内容（当列表滚动后下方可能有多余的旧绘制内容）
        for i = visibleCount + 1, maxVisible do
            term.setCursorPos(2, i + 3)
            term.setBackgroundColor(colors.gray)
            term.clearLine()
        end

        -- 滚动指示器
        if scrollOffset > 0 then
            term.setCursorPos(2, 3)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.lightGray)
            term.write('^ More')
        end
        if scrollOffset + maxVisible < #bootOrder then
            local indicatorY = math.min(visibleCount, maxVisible) + 3
            term.setCursorPos(2, indicatorY)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.lightGray)
            term.write('v More')
        end

        -- 底部提示栏
        term.setBackgroundColor(colors.white)
        term.setTextColor(colors.black)
        term.setCursorPos(1, h)
        term.clearLine()
        term.write('Q=shutdown,S=save&reboot,Enter=edit,C=shell')

        local _, key = os.pullEvent('key')
        if key == keys.up then
            if selectedIndex > 1 then
                selectedIndex = selectedIndex - 1
                if selectedIndex <= scrollOffset then
                    scrollOffset = math.max(0, scrollOffset - 1)
                end
            end
        elseif key == keys.down then
            if selectedIndex < #bootOrder then
                selectedIndex = selectedIndex + 1
                if selectedIndex > scrollOffset + maxVisible then
                    scrollOffset = scrollOffset + 1
                end
            end
        elseif key == keys.enter then
            local newDevice = showDevicePicker(selectedIndex)
            if newDevice then
                bootOrder[selectedIndex] = newDevice
            end
        end
        if key == keys.q then
            os.shutdown()
        end
        if key == keys.s then
            settings.set('bootOrder', bootOrder)
            settings.save()
            os.reboot()
        end
        if key == keys.c then
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            print('\n\nType "exit" to return to BIOS')
            os.run({
                shell = shell
            }, "/rom/programs/shell.lua")
        end
    end
end

if #canBootDevices == 0 then
    error('No valid boot device found', 0)
end

print(string.format('Found %d valid boot devices\n', #canBootDevices))

if bootOrder == nil then
    bootOrder = deepClone(canBootDevices)
end

-- 监听按下BIOS设置按钮事件
---@diagnostic disable undefined-field
local timerId = os.startTimer(0.1)
while true do
    local e, data = os.pullEvent()
    if e == 'timer' and data == timerId then
        print('Booting...')
        break
    elseif (e == 'key' or e == 'key_up') and data == BIOS_SETTING_BUTTON then
        print('BIOS setting button pressed')
        biosTUI()
        error('BIOS TUI closed') -- 不应该走到这里
    end
end

-- 开始引导

for i, name in ipairs(bootOrder) do
    local path = bootMap[name]
    if path then
        print(string.format('Boot %s from %s', name, path))
        local ok, err = pcall(function()
            local f = loadfile(path)
            f()
            os.shutdown()
        end)
        if not ok then
            print(string.format('Boot %s failed: %s', name, err))
        end
    end
end
