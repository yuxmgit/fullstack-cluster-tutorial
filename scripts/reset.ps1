# ============================================================
#  清空重来：停容器 + 删数据卷
#
#  用法：
#    .\scripts\reset.ps1                 # 清完整集群（含数据卷）
#    .\scripts\reset.ps1 -Mode simple    # 清单机版
#    .\scripts\reset.ps1 -KeepData       # 只停容器，保留数据
# ============================================================

param(
    [ValidateSet("simple", "cluster")]
    [string]$Mode = "cluster",
    [switch]$KeepData
)

$root = Split-Path -Parent $PSScriptRoot
$file = if ($Mode -eq "simple") { "deploy/docker-compose.simple.yml" } else { "deploy/docker-compose.yml" }

Push-Location $root
try {
    if ($KeepData) {
        Write-Host "[reset] docker compose -f $file down" -ForegroundColor Yellow
        docker compose -f $file down
    } else {
        Write-Host "[reset] docker compose -f $file down -v  (volumes will be deleted)" -ForegroundColor Yellow
        docker compose -f $file down -v
    }
} finally {
    Pop-Location
}

Write-Host "[reset] done." -ForegroundColor Green
