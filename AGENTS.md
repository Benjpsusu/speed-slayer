# 仓库修改约定

- 每次修改功能、修复问题或调整文档，都必须在根目录 `README.md` 的“修改记录（溯源）”中记录日期、改动目的、涉及文件、验证结果和未验证项。
- 涉及 Lite 的改动，同时更新 `speed-slayer-lite/README.md` 的用法和修改记录。不要把尚未运行的检查写成通过，也不要覆盖已有历史条目。
- 本地命令统一通过 PowerShell 7（`pwsh`）执行，脚本首行设置 `$ErrorActionPreference = 'Stop'`，文件读写显式使用 `-Encoding UTF8`。Linux Bash 脚本保持 UTF-8、LF；通过 PowerShell 调用 Bash 做语法或隔离测试。
