# Canvas Materials Sync

一个适用于 Windows 的 Canvas Files 增量同步工具。使用 PowerShell 7 和 Canvas Access Token，将课程文件下载到本地课程目录。

## 功能

- 同步多个 Canvas 课程的 Files 页面
- 保留 Canvas 文件夹结构
- 只下载新增或更新的文件
- 不删除本地资料
- 同名但内容不同的文件会保留为冲突副本
- Access Token 使用 Windows DPAPI 加密，不写入仓库

## 使用方法

1. 将本仓库内容放入 `Data-Science-Master` 项目根目录，使 `tools/canvas-sync/` 保持原有结构。
2. 根据自己的课程修改 `tools/canvas-sync/canvas-sync.config.json`。
3. 安装 PowerShell 7。
4. 双击 `Sync Canvas Materials.cmd`。
5. 首次运行时粘贴 Canvas Access Token；输入内容不会显示。

更详细的命令说明见 [`tools/canvas-sync/README.md`](tools/canvas-sync/README.md)。

## 安全说明

不要把 Access Token、`token.dpapi`、同步清单、日志或下载的课程资料提交到 GitHub。仓库中的 `.gitignore` 已排除这些内容。

## 测试

```powershell
Invoke-Pester .\tools\canvas-sync\tests\CanvasSync.Tests.ps1
```
