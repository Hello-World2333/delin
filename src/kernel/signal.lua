--[[ Delin kernel signal definitions.
     POSIX-ish signal numbers (Linux x86-64), default actions and catchability.
     内核进程层只依赖本模块的常量/默认动作表; 投递逻辑在 process.lua。 ]]

local signal = {}

-- Signal numbers (commonly used subset)
signal.SIGHUP   = 1
signal.SIGINT   = 2
signal.SIGQUIT  = 3
signal.SIGKILL  = 9
signal.SIGUSR1  = 10
signal.SIGUSR2  = 12
signal.SIGPIPE  = 13
signal.SIGALRM  = 14
signal.SIGTERM  = 15
signal.SIGCHLD  = 17
signal.SIGCONT  = 18
signal.SIGSTOP  = 19
signal.SIGTSTP  = 20
signal.SIGTTIN  = 21
signal.SIGTTOU  = 22

-- name lookup (for display / kill -l)
local names = {
    [signal.SIGHUP]  = "HUP",
    [signal.SIGINT]  = "INT",
    [signal.SIGQUIT] = "QUIT",
    [signal.SIGKILL] = "KILL",
    [signal.SIGUSR1] = "USR1",
    [signal.SIGUSR2] = "USR2",
    [signal.SIGPIPE] = "PIPE",
    [signal.SIGALRM] = "ALRM",
    [signal.SIGTERM] = "TERM",
    [signal.SIGCHLD] = "CHLD",
    [signal.SIGCONT] = "CONT",
    [signal.SIGSTOP] = "STOP",
    [signal.SIGTSTP] = "TSTP",
    [signal.SIGTTIN] = "TTIN",
    [signal.SIGTTOU] = "TTOU",
}

-- cached name list (numeric order) for kill -l
local ordered = {}
local orderedNames = {}
for _, s in ipairs({ signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGKILL,
    signal.SIGUSR1, signal.SIGUSR2, signal.SIGPIPE, signal.SIGALRM, signal.SIGTERM,
    signal.SIGCHLD, signal.SIGCONT, signal.SIGSTOP, signal.SIGTSTP, signal.SIGTTIN,
    signal.SIGTTOU }) do
    ordered[#ordered + 1] = s
    orderedNames[#orderedNames + 1] = names[s]
end

-- default action
--   term: terminate the process
--   stop: stop (suspend) the process until SIGCONT
--   cont: continue a stopped process
--   ign : ignore (default, no scheduling effect)
local defaults = {
    [signal.SIGHUP]  = "term", [signal.SIGINT] = "term", [signal.SIGQUIT] = "term",
    [signal.SIGKILL] = "term", [signal.SIGUSR1] = "term", [signal.SIGUSR2] = "term",
    [signal.SIGPIPE] = "term", [signal.SIGALRM] = "term", [signal.SIGTERM] = "term",
    [signal.SIGCHLD] = "ign",
    [signal.SIGCONT] = "cont", [signal.SIGSTOP] = "stop", [signal.SIGTSTP] = "stop",
    [signal.SIGTTIN] = "stop", [signal.SIGTTOU] = "stop",
}

-- uncatchable & unblockable & cannot be ignored
local uncatchable = { [signal.SIGKILL] = true, [signal.SIGSTOP] = true }

function signal.name(sig)
    return names[sig] or ("SIG" .. tostring(sig))
end

function signal.number(name)
    local want = (name or ""):upper()
    want = want:gsub("^SIG", "")
    for s, n in pairs(names) do
        if n == want then return s end
    end
    return nil
end

function signal.defaultAction(sig)
    return defaults[sig] or "term"
end

function signal.catchable(sig)
    return not uncatchable[sig]
end

function signal.listNumbers()
    return ordered
end

function signal.listNames()
    return orderedNames
end

return signal
