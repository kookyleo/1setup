# 1setup

## 一键执行（IEX）

默认方式（不带参数）：

```powershell
irm https://raw.githubusercontent.com/kookyleo/1setup/main/bootstrap.ps1 | iex
```

带参数方式（推荐，便于传参）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $(irm https://raw.githubusercontent.com/kookyleo/1setup/main/bootstrap.ps1) } -MaxDownloadJobs 4"
```

说明：
- 需要用管理员权限运行（`win11.ps1` 有 `#Requires -RunAsAdministrator`）。
