--[[ 真机验证: 用**注入按键事件**的方式驱动交互式安装器(tools/installer.lua 的向导)。

     CC 电脑读不了屏, 所以交互式向导只能在真机上这样验: 把本文件装成电脑自身 FS 的
     /startup.lua, 再放一个"交互计划" /installer-test.plan, 开机后由本文件:
       1. 从 http 拉安装器本体(wget run 的等价路径);
       2. 让安装器跑在一个协程里, 另开一个"喂按键"的协程(parallel);
       3. 喂按键的时机不靠"睡够久", 而是**盯着安装器的日志同步** —— 安装器的向导每进
          一步 / 每个文本输入都会往 /delin-install.log 落一行, 计划里 `wait <子串>` 就是
          等这一行出现再排下一个按键。原因: CC 里带过滤器的事件拉取(http.get/ sleep)
          会把队列里不匹配的事件**丢掉**, 提前把按键排好队, 中途一次 http 请求就能把
          后面的按键全吃掉(实测: 预先排队 + http.get -> key 消失)。

     用法(宿主机, 电脑先停机):
         cp scripts/installer_interactive_test.lua /mnt/computer/3/startup.lua
         cp <计划文件>                             /mnt/computer/3/installer-test.plan
         python3 docs/tools/rcon.py "computercraft turn-on #3"

     产物(电脑自身 FS, 供宿主机读回):
         /installer-test.log   驱动日志(同步到的标记、排出的按键、安装器返回值)
         /delin-install.log    安装器日志(向导走了哪些步 + 实际安装配置 + 结果)

     计划文件: 每行一个 token('#' 起为注释)
         url <install.lua 的 URL>      必须第一行
         wait <子串>                   等 /delin-install.log 里出现这一行
         key <键名>                    up down left right enter backspace escape q r 或单个字符
         text <字符串>                 展开成逐字符的 char 事件(等价于手打)
     计划里最后一个 key 若是 r, 安装成功后安装器会自己 os.reboot() —— 正好用来验证
     "装完重启能进 Delin"。 ]]

local LOG         = "/installer-test.log"
local PLAN        = "/installer-test.plan"
local CFG         = "/delin-install.cfg"
local INSTALL_LOG = "/delin-install.log"
local DEADLINE    = 300 -- 秒: 一轮最长等待, 超时就停手并留下日志(免得永远挂着)

--- 追加一行驱动日志(CC 电脑读不了屏, 一切结论都要落盘)。
local function log(s)
    local f = fs.open(LOG, "a")
    if f then f.writeLine(tostring(s)); f.close() end
end

local function readFile(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local d = f.readAll(); f.close()
    return d
end

--- 读计划文件 -> { url = ..., [i] = { kind = "wait"|"key"|"text", value = ... } }。
local function readPlan()
    local text = readFile(PLAN)
    if not text then return nil, "no plan file: " .. PLAN end
    local out = {}
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local kind, value = line:match("^(%S+)%s*(.*)$")
            if kind == "url" then
                out.url = value
            elseif kind == "wait" or kind == "key" or kind == "text" then
                if value == "" then return nil, "plan: empty " .. kind .. " step" end
                out[#out + 1] = { kind = kind, value = value }
            else
                return nil, "bad plan line: " .. line
            end
        end
    end
    if not out.url then return nil, "plan: missing first line 'url <install.lua URL>'" end
    if #out == 0 then return nil, "plan: no wait/key/text steps" end
    return out
end

--- 等安装器日志里出现 sub(同步注入时机)。安装器报 FAIL 或超时就返回 false。
local function waitFor(sub, deadline)
    while os.epoch("utc") / 1000 < deadline do
        local text = readFile(INSTALL_LOG)
        if text then
            if text:find(sub, 1, true) then return true end
            if text:find("FAIL", 1, true) then
                return false, "installer logged FAIL while waiting for: " .. sub
            end
        end
        sleep(0.25) -- sleep 只拉 timer 事件, 不会动安装器要的 http 事件(实测)
    end
    return false, "timeout waiting for: " .. sub
end

--- 喂按键的协程: 按计划同步标记后排队事件。
local function feeder(plan, deadline)
    for _, step in ipairs(plan) do
        if step.kind == "wait" then
            local ok, err = waitFor(step.value, deadline)
            if not ok then
                log("FAIL: " .. tostring(err))
                return
            end
            log("  sync: " .. step.value)
        elseif step.kind == "key" then
            local code = keys[step.value] or (#step.value == 1 and keys[step.value:lower()])
            if not code then
                log("FAIL: unknown key name: " .. step.value)
                return
            end
            os.queueEvent("key", code)
            log("  queue key " .. step.value)
            sleep(0.3) -- 给安装器一点时间把它吃掉, 再去等下一个标记
        else
            for i = 1, #step.value do
                os.queueEvent("char", step.value:sub(i, i))
            end
            log("  queue text " .. step.value)
            sleep(0.3)
        end
    end
    log("feeder done")
end

--- 安装器协程: load 之后直接在协程里跑(喂按键的协程与它并行)。
local function runInstaller(src)
    local fn, lerr = load(src, "install.lua")
    if not fn then
        log("FAIL: load: " .. tostring(lerr))
        return
    end
    local ok, err = pcall(fn)
    -- 正常路径下最后一条 key r 会让安装器 os.reboot(), 走不到这里
    log("installer returned: ok=" .. tostring(ok) .. " err=" .. tostring(err))
end

local function main()
    local f = fs.open(LOG, "w"); if f then f.close() end
    log("driver start")

    local plan, perr = readPlan()
    if not plan then log("FAIL: " .. tostring(perr)); return end
    log("installer url: " .. plan.url)
    log("free space: computer storage " .. tostring(fs.getFreeSpace("/")))
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" and disk.hasData(name) then
            local mp = disk.getMountPath(name)
            log("free space: drive " .. name .. " (" .. tostring(mp) .. ") " .. tostring(fs.getFreeSpace(mp)))
        end
    end

    -- 交互式路径: 先清掉可能存在的无人值守配置, 否则安装器会跳过整个向导。
    local old = readFile(CFG)
    if old then
        log("removing pre-existing " .. CFG .. ": " .. old:gsub("%s+$", ""))
        fs.delete(CFG)
    end
    fs.delete(INSTALL_LOG) -- 旧日志里的标记会把"同步"骗过去, 必须从干净状态开始

    local res = http.get({ url = plan.url, binary = true })
    if not res then log("FAIL: cannot fetch " .. plan.url); return end
    local src = res.readAll()
    res.close()
    log("fetched " .. #src .. " bytes")

    local deadline = os.epoch("utc") / 1000 + DEADLINE
    parallel.waitForAll(function() runInstaller(src) end, function() feeder(plan, deadline) end)
    log("driver done")
end

main()
