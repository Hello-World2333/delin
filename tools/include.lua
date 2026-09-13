--[[ Delin 构建期的 `--#include` 拼接。

  为什么需要它: /bin 下每个工具在**目标机上**都必须是自包含的单文件 —— 进程环境是白名单
  (kernel/procenv.lua), 没有 require/dofile/loadfile, 工具之间不能互相"引用"。于是"两个工具
  共用同一份实现"只能靠**构建期拼接**: 源码里引用, 产物里是一整份。

  指令(整行, 前后可有空白):
      --#include <相对仓库根的路径>
  例: src/bin/sh 与 src/bin/desh 都写 `--#include src/lib/shcore.lua`。

  规则:
    - 路径相对**仓库根**(与 build.lua 里其它路径同一套写法), 嵌套 include 亦然;
    - 被 include 的文件里**不允许出现顶层 `return`**(拼接后它就是同一段 chunk, 一个 return
      会把整个产物截断) —— 这里在拼的时候就拦住, 而不是等运行期报一句看不懂的错;
    - 递归深度上限 + 环路检测, 出错一律 fail-fast, 报出"谁 include 的谁、第几行"。

  谁用它: tools/build.lua(minifyTo 之前)、tools/harness.lua(把 src/bin 铺进测试台 ROOT 时)。
  两边同一份实现, 于是"宿主测试台跑的工具"与"装到 CC 上的工具"是同一段源码。 ]]

local M = {}

local MAX_DEPTH = 8

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local c = f:read("*a")
    f:close()
    return c
end

--- 逐行遍历(不吞掉/不新增行)。
local function eachLine(src, fn)
    local pos, lineNo = 1, 0
    while pos <= #src do
        lineNo = lineNo + 1
        local nl = src:find("\n", pos, true)
        local line, nextPos
        if nl then
            line, nextPos = src:sub(pos, nl - 1), nl + 1
        else
            line, nextPos = src:sub(pos), #src + 1
        end
        fn(line, lineNo)
        pos = nextPos
    end
end

--- 该文件里有没有顶层 return(拼接会截断产物)。
--- 判据: 行首**第 0 列**就是 `return`(顶层 return 按约定不缩进; 函数体里的 return 都缩进,
--- 于是不会被误判 —— src/lib/shcore.lua 的 shellMain 里就有若干缩进的 return)。
local function topLevelReturn(sub)
    local hit = nil
    eachLine(sub, function(line, n)
        if not hit and line:match("^return%f[%W]") then hit = n end
    end)
    return hit
end

--- 展开一段源码里的 --#include 指令。
---@param src string 源码
---@param repo string 仓库根(绝对路径, 末尾无 /)
---@param origin string 报错用的来源名(相对路径)
---@param seen table|nil include 链(环路检测)
---@param depth number|nil 递归深度
---@return string
function M.expand(src, repo, origin, seen, depth)
    seen = seen or {}
    depth = depth or 0
    if depth > MAX_DEPTH then
        error(origin .. ": include 嵌套超过 " .. MAX_DEPTH .. " 层", 0)
    end

    local out = {}
    eachLine(src, function(line, lineNo)
        local rel = line:match("^%s*%-%-#include%s+(%S+)%s*$")
        if not rel then
            out[#out + 1] = line
            return
        end
        if seen[rel] then
            error(string.format("%s:%d: include 成环: %s(已在 include 链里)", origin, lineNo, rel), 0)
        end
        local sub, err = readFile(repo .. "/" .. rel)
        if not sub then
            error(string.format("%s:%d: include %s 读不到: %s", origin, lineNo, rel, tostring(err)), 0)
        end
        local bad = topLevelReturn(sub)
        if bad then
            error(string.format("%s:%d: 被 include 的 %s:%d 有顶层 return —— 拼接后是同一段 chunk, "
                .. "会把产物截断; 改成定义函数由入口调用", origin, lineNo, rel, bad), 0)
        end
        seen[rel] = true
        out[#out + 1] = M.expand(sub, repo, rel, seen, depth + 1)
        seen[rel] = nil
    end)
    return table.concat(out, "\n")
end

--- 读一个源文件并展开其中的 --#include。
---@param repo string 仓库根
---@param rel string 相对仓库根的路径
---@return string
function M.read(repo, rel)
    local src, err = readFile(repo .. "/" .. rel)
    if not src then error("读不到 " .. rel .. ": " .. tostring(err), 0) end
    return M.expand(src, repo, rel)
end

return M
