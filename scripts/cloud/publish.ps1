# ============================================================
#  Windows 本地一键发布到腾讯云服务器
#
#  前置条件：
#    1. 服务器已跑过 scripts/cloud/init-server.sh
#    2. 服务器上已配置好 deploy/cloud/.env
#    3. Windows 自带 OpenSSH（Win10 1809+ 默认有 ssh / scp / tar）
#    4. 已能用密钥免密登录：ssh -i 你的密钥 deploy@服务器IP
#
#  用法：
#    .\scripts\cloud\publish.ps1 -ServerHost 1.2.3.4
#    .\scripts\cloud\publish.ps1 -ServerHost 1.2.3.4 -KeyPath "$HOME\.ssh\tc.pem"
#    .\scripts\cloud\publish.ps1 -ServerHost 1.2.3.4 -SkipDeploy   # 只上传不部署
# ============================================================

param(
    [Parameter(Mandatory = $true)][string]$ServerHost,
    [string]$User = "deploy",
    [string]$KeyPath = "$HOME\.ssh\id_ed25519",
    [string]$AppDir = "/opt/fullstack-cluster-tutorial",
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ✔ $msg" -ForegroundColor Green }
function Die($msg)  { Write-Host "[失败] $msg" -ForegroundColor Red; exit 1 }

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path (Join-Path $root "deploy\cloud\docker-compose.prod.yml"))) {
    Die "项目根目录识别错误：$root"
}
if (-not (Test-Path $KeyPath)) {
    Die "找不到密钥文件：$KeyPath（用 -KeyPath 指定腾讯云下载的 .pem）"
}

$pkg = Join-Path $env:TEMP "fullstack-deploy.tgz"
Info "打包项目（排除 node_modules / .git / .env 等）"

Push-Location $root
try {
    # 注意：服务器上的 deploy/cloud/.env、runtime、certs 不能被覆盖，
    # 所以这里显式排除。
    tar --exclude='./.git' --exclude='./.git/*' `
        --exclude='*/node_modules' --exclude='*/node_modules/*' `
        --exclude='*/dist' --exclude='*/dist/*' `
        --exclude='*/.venv' --exclude='*/.venv/*' `
        --exclude='*/__pycache__' --exclude='*/__pycache__/*' `
        --exclude='./deploy/cloud/.env' `
        --exclude='./deploy/cloud/runtime' --exclude='./deploy/cloud/runtime/*' `
        --exclude='./deploy/cloud/certs' --exclude='./deploy/cloud/certs/*' `
        --exclude='./deploy/cloud/certbot-webroot' --exclude='./deploy/cloud/certbot-webroot/*' `
        --exclude='./backups' --exclude='./backups/*' `
        -czf $pkg .
    if ($LASTEXITCODE -ne 0) { Die "打包失败" }
} finally {
    Pop-Location
}

$size = [math]::Round((Get-Item $pkg).Length / 1MB, 2)
Ok "打包完成：$pkg（$size MB）"

Info "上传到 ${User}@${ServerHost}:/tmp/"
scp -i $KeyPath -o StrictHostKeyChecking=accept-new $pkg "${User}@${ServerHost}:/tmp/fullstack-deploy.tgz"
if ($LASTEXITCODE -ne 0) { Die "上传失败，请检查网络、密钥与安全组 22 端口" }
Ok "上传完成"

if ($SkipDeploy) {
    Ok "已跳过部署（-SkipDeploy）"
    exit 0
}

Info "在服务器上解包并执行部署脚本"

# 单引号 here-string：PowerShell 不做变量展开，避免 $ 被本地吃掉；
# 之后再把占位符替换成实际路径。
$remoteTemplate = @'
set -e
mkdir -p "__APPDIR__"
tar -xzf /tmp/fullstack-deploy.tgz -C "__APPDIR__"
# Windows 打包可能带 CRLF，Linux 上 bash 会报 $'\r': command not found
find "__APPDIR__/scripts" -name "*.sh" -exec sed -i 's/\r$//' {} \;
chmod +x "__APPDIR__"/scripts/cloud/*.sh
bash "__APPDIR__/scripts/cloud/deploy.sh"
'@

$remote = $remoteTemplate.Replace('__APPDIR__', $AppDir)

$remote | ssh -i $KeyPath -o StrictHostKeyChecking=accept-new "${User}@${ServerHost}" "bash -s"
if ($LASTEXITCODE -ne 0) {
    Die "远程部署失败，请到服务器查看日志：docker compose logs --tail=100 backend-1"
}

Ok "发布完成，打开 https://你的域名 验证（域名见服务器上的 deploy/cloud/.env）"
