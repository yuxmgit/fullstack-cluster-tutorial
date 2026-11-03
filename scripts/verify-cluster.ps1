# ============================================================
#  一键验证集群：登录 → 连打 N 次探针 → 统计副本分布 → 校验会话
#
#  用法：
#    .\scripts\verify-cluster.ps1
#    .\scripts\verify-cluster.ps1 -BaseUrl http://localhost:8080 -Rounds 20
# ============================================================

param(
    [string]$BaseUrl = "http://localhost:8080",
    [int]$Rounds = 12,
    [string]$Username = "alice",
    [string]$Password = "123456"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Fullstack cluster verification ===" -ForegroundColor Cyan
Write-Host "Base URL : $BaseUrl"
Write-Host "Rounds   : $Rounds"
Write-Host ""

# ---------- 0. 入口是否可达 ----------
try {
    $null = Invoke-RestMethod -Uri "$BaseUrl/api/system/health" -TimeoutSec 5
} catch {
    Write-Host "[FAIL] Cannot reach $BaseUrl/api/system/health" -ForegroundColor Red
    Write-Host "       Start the stack first:" -ForegroundColor Yellow
    Write-Host "       docker compose -f deploy/docker-compose.yml up -d --build" -ForegroundColor Yellow
    exit 1
}

# ---------- 1. 登录，保存 Cookie 会话 ----------
Write-Host "[1/4] Login as $Username ..." -ForegroundColor Cyan
$loginBody = @{ username = $Username; password = $Password } | ConvertTo-Json -Compress
try {
    $login = Invoke-RestMethod -Uri "$BaseUrl/api/auth/login" -Method Post `
        -ContentType "application/json" -Body $loginBody -SessionVariable webSession -TimeoutSec 10
} catch {
    Write-Host "[FAIL] Login failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host "      ok, handled by: $($login.handled_by)  session backend: $($login.session_backend)" -ForegroundColor Green
Write-Host "      session_id prefix: $($login.session_id_prefix)..."

# ---------- 2. 连打 N 次，记录每次的实例名 ----------
Write-Host ""
Write-Host "[2/4] Sending $Rounds requests to /api/system/info ..." -ForegroundColor Cyan

$hits = @{}
for ($i = 1; $i -le $Rounds; $i++) {
    $info = Invoke-RestMethod -Uri "$BaseUrl/api/system/info" -WebSession $webSession -TimeoutSec 10
    if ($hits.ContainsKey($info.instance_id)) {
        $hits[$info.instance_id] = $hits[$info.instance_id] + 1
    } else {
        $hits[$info.instance_id] = 1
    }
    Write-Host ("      [{0,2}] -> {1}" -f $i, $info.instance_id)
}

Write-Host ""
Write-Host "[3/4] Distribution:" -ForegroundColor Cyan
$hits.GetEnumerator() | Sort-Object Name | ForEach-Object {
    $bar = "#" * $_.Value
    Write-Host ("      {0,-12} {1,3}  {2}" -f $_.Key, $_.Value, $bar)
}

if ($hits.Count -le 1) {
    Write-Host "      [WARN] Only one instance answered." -ForegroundColor Yellow
    Write-Host "             Are you running the simple (single-backend) stack?" -ForegroundColor Yellow
} else {
    Write-Host "      [OK] Round-robin works across $($hits.Count) instances." -ForegroundColor Green
}

# ---------- 3. 会话是否跨副本保持 ----------
Write-Host ""
Write-Host "[4/4] Session check ..." -ForegroundColor Cyan
$me = Invoke-RestMethod -Uri "$BaseUrl/api/auth/me" -WebSession $webSession -TimeoutSec 10
Write-Host "      user        : $($me.user.username)" -ForegroundColor Green
Write-Host "      handled by  : $($me.handled_by)"
Write-Host "      hits        : $($me.session.hits)"
Write-Host "      ttl seconds : $($me.session.ttl_seconds)"
Write-Host "      backend     : $($me.session.backend)"

if ($me.session.backend -eq "redis") {
    Write-Host "      [OK] Session is centralized in Redis; any replica can serve you." -ForegroundColor Green
} else {
    Write-Host "      [WARN] Session backend is '$($me.session.backend)' (in-process memory)." -ForegroundColor Yellow
    Write-Host "             With multiple replicas you WILL be logged out randomly." -ForegroundColor Yellow
}

# ---------- 4. 收尾提示 ----------
$info = Invoke-RestMethod -Uri "$BaseUrl/api/system/info" -WebSession $webSession -TimeoutSec 10
Write-Host ""
Write-Host "--- System info ---" -ForegroundColor Cyan
Write-Host "  instance          : $($info.instance_id)"
Write-Host "  session_backend   : $($info.session_backend)"
Write-Host "  redis_ok          : $($info.redis_ok)"
Write-Host "  read_replica_ok   : $($info.read_replica_ok)"
Write-Host "  global_requests   : $($info.global_request_count)"
Write-Host "  init_status       : $($info.init_status)"
Write-Host ""
Write-Host "Done." -ForegroundColor Green
