-- 测试 DLUB 配置解析器
local dlubcfg = require("src.kernel.dlubcfg")

-- 测试用例
local tests = {
    {
        name = "bootdisk only",
        content = "bootdisk left",
        expected = { bootdisk = "left" },
    },
    {
        name = "rootfs only",
        content = "rootfs /parts/root.img",
        expected = { rootfs = "/parts/root.img" },
    },
    {
        name = "both bootdisk and rootfs",
        content = "bootdisk left\nrootfs /parts/root.img",
        expected = { bootdisk = "left", rootfs = "/parts/root.img" },
    },
    {
        name = "with comments",
        content = "# 这是注释\nbootdisk left\n# 另一个注释",
        expected = { bootdisk = "left" },
    },
    {
        name = "missing both",
        content = "# 只有注释",
        expected = nil,
        err = "missing key: bootdisk or rootfs",
    },
    {
        name = "unknown key",
        content = "unknown value",
        expected = nil,
        err = "unknown key: unknown",
    },
    {
        name = "duplicate key",
        content = "bootdisk left\nbootdisk right",
        expected = nil,
        err = "duplicate key: bootdisk",
    },
}

local passed = 0
local failed = 0

for _, test in ipairs(tests) do
    local cfg, err = dlubcfg.parse(test.content)
    if test.expected then
        if cfg and cfg.bootdisk == test.expected.bootdisk and cfg.rootfs == test.expected.rootfs then
            print("PASS: " .. test.name)
            passed = passed + 1
        else
            print("FAIL: " .. test.name)
            print("  expected: " .. tostring(test.expected.bootdisk) .. ", " .. tostring(test.expected.rootfs))
            print("  got: " .. tostring(cfg and cfg.bootdisk) .. ", " .. tostring(cfg and cfg.rootfs))
            failed = failed + 1
        end
    else
        if not cfg and err and err:find(test.err) then
            print("PASS: " .. test.name)
            passed = passed + 1
        else
            print("FAIL: " .. test.name)
            print("  expected error: " .. test.err)
            print("  got: " .. tostring(err))
            failed = failed + 1
        end
    end
end

print("\nResults: " .. passed .. " passed, " .. failed .. " failed")
if failed > 0 then
    os.exit(1)
end
