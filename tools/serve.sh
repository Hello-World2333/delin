#!/bin/sh
# 开发期托管 Delin 发布树的静态 HTTP 服务。
#
# 安装器只支持 http 安装源(游戏服务器侧已放开本机/内网访问规则), 所以本地验证走这里:
#   sh tools/serve.sh            # 默认 10568(该端口已转发到游戏服务器), 托管 dist/release
#   sh tools/serve.sh 9000       # 换端口
# 之后在游戏内:
#   wget run http://<host>:10568/<版本>/install.lua
#
# 注意: 本仓库的 dist/ 是 .gitignore 的生成物, 先跑 `lua5.1 tools/build.lua --release`。
set -e
PORT="${1:-10568}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)/dist/release"
if [ ! -d "$ROOT" ]; then
    echo "serve: $ROOT 不存在; 先跑: lua5.1 tools/build.lua --release" >&2
    exit 1
fi
echo "serving $ROOT on port $PORT"
exec python3 -m http.server "$PORT" --directory "$ROOT"
