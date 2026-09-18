# Canvas 资料同步工具

双击项目根目录的 `Sync Canvas Materials.cmd`，即可同步七门课程的 Canvas Files。

## 第一次使用

1. 在 Canvas 打开 `Account → Settings → New Access Token`，创建 Token。
2. 双击 `Sync Canvas Materials.cmd`。
3. 在窗口中粘贴 Token 并按 Enter。输入时不会显示字符。

Token 使用 Windows DPAPI 加密，保存在当前用户的 `%LOCALAPPDATA%\DataScienceMaster\CanvasSync`，不会以明文写入本项目。

## 可选命令

在项目根目录打开 PowerShell 7：

```powershell
# 只预览 5002，不下载
pwsh -File .\tools\canvas-sync\Sync-Canvas.ps1 -DryRun -Course 5002

# 只同步 5002
pwsh -File .\tools\canvas-sync\Sync-Canvas.ps1 -Course 5002

# Token 失效后重新输入
pwsh -File .\tools\canvas-sync\Sync-Canvas.ps1 -ResetToken
```

同步器保留 Canvas 的目录结构。Canvas 上删除文件时，本地文件不会被删除。
