#Requires -Version 5.1
<#
.SYNOPSIS
    filebox 新设备一键配置（Windows）。
.DESCRIPTION
    自动检查/安装 Git 与 GitHub CLI，登录 GitHub（设备码授权），clone 或更新文件投递仓库，并做冒烟测试。
    只有 GitHub 登录需要人工：脚本会打印一次性验证码和链接，在浏览器里点一下 Authorize 即可。
.PARAMETER Token
    可选。已有一个 classic GitHub token（含 repo/read:org 权限）时可直接登录，跳过设备码流程。
.PARAMETER RepoDir
    仓库位置，默认 $env:USERPROFILE\filebox。
.PARAMETER SkipAuth
    跳过登录检查（仅当本机已登录、或只想初始化仓库时使用）。
.PARAMETER Json
    结束时额外输出一行机器可读的 RESULT_JSON。
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1
.EXAMPLE
    .\bootstrap.ps1 -RepoDir D:\filebox -Json
#>
[CmdletBinding()]
param(
    [string]$Token = $env:GH_TOKEN,
    [string]$RepoDir = (Join-Path $env:USERPROFILE 'filebox'),
    [switch]$SkipAuth,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$PageUrl = 'https://lyz-wave.github.io/filebox-web/'
$RepoUrl = 'https://github.com/lyz-wave/filebox.git'
$ClientId = '178c6fc778ccc68e1d6a'
$Login = ''
$Warnings = @()

function Write-Status([string]$Tag, [string]$Message) {
    Write-Host ('[' + $Tag + '] ' + $Message)
}

function Get-ExePath {
    param([string]$Name, [string[]]$Candidates)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

Write-Host ''
Write-Host '=== filebox 配置脚本（Windows）===' -ForegroundColor Cyan
Write-Host ('仓库目标目录：' + $RepoDir)
Write-Host ''

try {
    # ---------- Git ----------
    $git = Get-ExePath -Name 'git' -Candidates @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
    )
    if (-not $git) {
        $winget = Get-ExePath -Name 'winget' -Candidates @()
        if (-not $winget) {
            throw '未找到 Git，也没有 winget。请先安装 Git：https://git-scm.com/download/win'
        }
        Write-Status '..' '未检测到 Git，正在用 winget 安装（可能弹出 UAC，请点「是」）'
        & $winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
        $git = Get-ExePath -Name 'git' -Candidates @(
            (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
        )
    }
    if (-not $git) {
        throw 'Git 安装后仍不可用。请手动安装 Git：https://git-scm.com/download/win'
    }
    $env:PATH = $env:PATH + ';' + (Split-Path $git -Parent)
    $gitVersion = (& $git --version 2>&1 | Out-String).Trim()
    Write-Status 'OK' ('Git 就绪：' + $gitVersion)

    # ---------- GitHub CLI ----------
    $gh = Get-ExePath -Name 'gh' -Candidates @(
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHubCLI\bin\gh.exe'),
        (Join-Path $env:ProgramFiles 'GitHub CLI\bin\gh.exe')
    )
    if (-not $gh) {
        Write-Status '..' '未检测到 GitHub CLI，正在下载便携版 ...'
        $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
        $latest = $null
        if ($curl) {
            $latest = (& curl.exe -sSL -o NUL -w '%{url_effective}' 'https://github.com/cli/cli/releases/latest' 2>&1 | Out-String).Trim()
        } else {
            $resp = Invoke-WebRequest -Uri 'https://github.com/cli/cli/releases/latest' -UseBasicParsing -ErrorAction Stop
            $latest = $resp.BaseResponse.ResponseUri.AbsoluteUri
        }
        if ($latest -notmatch 'v([0-9]+)\.([0-9]+)\.([0-9]+)$') {
            throw ('无法解析 GitHub CLI 最新版本（返回：' + $latest + '）')
        }
        $version = $matches[1] + '.' + $matches[2] + '.' + $matches[3]
        $asset = 'gh_' + $version + '_windows_amd64.zip'
        $url = 'https://github.com/cli/cli/releases/download/v' + $version + '/' + $asset
        $zip = Join-Path $env:TEMP $asset
        Write-Status '..' ('下载 GitHub CLI ' + $version + ' ...')
        if ($curl) {
            & curl.exe -sSL --retry 3 -o $zip $url 2>&1 | Out-Null
        } else {
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
        }
        $dest = Join-Path $env:LOCALAPPDATA 'Programs\GitHubCLI'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Expand-Archive -Path $zip -DestinationPath $dest -Force -ErrorAction Stop
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        $ghItem = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'gh.exe' | Select-Object -First 1
        if (-not $ghItem) { throw 'GitHub CLI 解压失败：找不到 gh.exe' }
        $gh = $ghItem.FullName
        $binDir = Split-Path $gh -Parent
        $env:PATH = $env:PATH + ';' + $binDir
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike ('*' + $binDir + '*')) {
            [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $binDir), 'User')
        }
    }
    $ghVersion = (& $gh --version 2>&1 | Out-String).Trim()
    $ghVersionFirst = ($ghVersion -split [Environment]::NewLine)[0]
    Write-Status 'OK' ('GitHub CLI 就绪：' + $ghVersionFirst)

    # ---------- 登录 ----------
    if (-not $SkipAuth) {
        $status = (& $gh auth status 2>&1 | Out-String)
        $loggedIn = ($LASTEXITCODE -eq 0) -and ($status -match 'Logged in to github.com')
        if ($loggedIn) {
            Write-Status 'OK' '本机已登录 GitHub，跳过授权'
        } elseif ($Token) {
            Write-Status '..' '使用提供的 token 登录 ...'
            $Token | & $gh auth login --with-token -h github.com 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Token 登录失败：gh 需要 repo 与 read:org 权限。请改为不传 -Token 的设备码登录，或提供 classic token。'
            }
        } else {
            $headers = @{ 'Accept' = 'application/json'; 'User-Agent' = 'filebox-bootstrap' }
            $dc = Invoke-RestMethod -Method Post -Uri 'https://github.com/login/device/code' -Headers $headers -Body @{ client_id = $ClientId; scope = 'repo read:org workflow gist' } -ErrorAction Stop
            Write-Host ''
            Write-Host '=== 需要 GitHub 授权（15 分钟内有效）===' -ForegroundColor Yellow
            Write-Host ('  1) 打开： ' + $dc.verification_uri)
            Write-Host ('  2) 输入验证码： ' + $dc.user_code) -ForegroundColor Cyan
            Write-Host ''
            try { Start-Process $dc.verification_uri | Out-Null } catch { }
            $interval = [int]$dc.interval
            if ($interval -lt 5) { $interval = 5 }
            $deviceToken = $null
            for ($i = 0; $i -lt 200; $i++) {
                Start-Sleep -Seconds $interval
                $body = @{ client_id = $ClientId; device_code = $dc.device_code; grant_type = 'urn:ietf:params:oauth:grant-type:device_code' }
                $resp = Invoke-RestMethod -Method Post -Uri 'https://github.com/login/oauth/access_token' -Headers $headers -Body $body -ErrorAction Stop
                if ($resp.access_token) { $deviceToken = $resp.access_token; break }
                if ($resp.error -eq 'authorization_pending') { continue }
                if ($resp.error -eq 'slow_down') { $interval = $interval + 5; continue }
                throw ('GitHub 授权失败：' + [string]$resp.error + ' ' + [string]$resp.error_description)
            }
            if (-not $deviceToken) { throw '等待 GitHub 授权超时（15 分钟）' }
            $deviceToken | & $gh auth login --with-token -h github.com 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'gh 登录失败' }
            Write-Status 'OK' 'GitHub 授权完成'
        }
    } else {
        Write-Status 'WARN' '已跳过登录步骤（-SkipAuth）'
    }

    & $gh auth setup-git 2>&1 | Out-Null

    $userInfo = $null
    try {
        $userInfo = (& $gh api user 2>&1 | Out-String) | ConvertFrom-Json
    } catch {
        throw '读取 GitHub 账号失败（可能尚未登录）。请重跑脚本或手动执行 gh auth login。'
    }
    $Login = [string]$userInfo.login
    if (-not $Login) {
        throw '无法确认 GitHub 账号，请重跑脚本或手动执行 gh auth login。'
    }
    if ($Login -ne 'lyz-wave') {
        $Warnings += ('当前登录账号是 ' + $Login + '，不是 lyz-wave；如果没有该私有仓库权限，clone / push 会失败。')
        Write-Status 'WARN' $Warnings[$Warnings.Count - 1]
    }
    Write-Status 'OK' ('GitHub 账号：' + $Login)

    # ---------- Git 身份 ----------
    $gitName = (& git config --global user.name 2>&1 | Out-String).Trim()
    $gitEmail = (& git config --global user.email 2>&1 | Out-String).Trim()
    if (-not $gitName) {
        & git config --global user.name $Login
    }
    if (-not $gitEmail) {
        $email = ([string]$userInfo.id) + '+' + $Login + '@users.noreply.github.com'
        & git config --global user.email $email
    }
    $gitName = (& git config --global user.name 2>&1 | Out-String).Trim()
    $gitEmail = (& git config --global user.email 2>&1 | Out-String).Trim()
    Write-Status 'OK' ('Git 身份：' + $gitName + ' <' + $gitEmail + '>')

    # ---------- 仓库 ----------
    if (Test-Path -LiteralPath $RepoDir) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoDir '.git'))) {
            throw ('目录已存在但不是 git 仓库：' + $RepoDir + '。请用 -RepoDir 指定其它位置。')
        }
        Write-Status '..' '更新已有仓库 ...'
        & git -C $RepoDir pull --rebase --autostash --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git pull 失败（网络或登录问题）' }
    } else {
        Write-Status '..' '克隆仓库 ...'
        & git clone $RepoUrl $RepoDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git clone 失败（网络或登录问题）' }
    }
    & git -C $RepoDir config core.autocrlf false 2>&1 | Out-Null
    & git -C $RepoDir config core.quotepath false 2>&1 | Out-Null
    & git -C $RepoDir config pull.rebase true 2>&1 | Out-Null
    Write-Status 'OK' ('仓库：' + $RepoDir)

    foreach ($f in @('send.ps1', 'recv.ps1', 'clean.ps1', 'send.sh', 'recv.sh', 'clean.sh')) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoDir $f))) {
            throw ('仓库缺少脚本：' + $f)
        }
    }
    Write-Status 'OK' '脚本文件齐全'

    $psExe = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue
    if ($psExe) {
        $smoke = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoDir 'recv.ps1') -Quiet 2>&1 | Out-String).Trim()
        $firstLine = ($smoke -split [Environment]::NewLine)[0]
        Write-Status 'OK' ('冒烟测试 recv.ps1：' + $firstLine)
    }

    Write-Host ''
    Write-Host '=== 配置完成 ===' -ForegroundColor Green
    Write-Host ('  仓库：' + $RepoDir)
    Write-Host ('  账号：' + $Login)
    Write-Host ('  发送：cd "' + $RepoDir + '"; .\send.ps1 文件名')
    Write-Host ('  接收：cd "' + $RepoDir + '"; .\recv.ps1')
    Write-Host ('  网页：' + $PageUrl)
    Write-Host ''
    Write-Host '下一步：'
    Write-Host ('  - 手机或临时电脑用网页版（第一次要填令牌）：' + $PageUrl)
    Write-Host '  - 想验证链路：发送一个小文件，再到网页的 inbox 里查看'
    Write-Host ''

    if ($Json) {
        $result = @{ ok = $true; repo_dir = $RepoDir; login = $Login; page = $PageUrl; warnings = $Warnings } | ConvertTo-Json -Compress
        Write-Output ('RESULT_JSON ' + $result)
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host ('[FAIL] ' + $_.Exception.Message) -ForegroundColor Red
    if ($Json) {
        $result = @{ ok = $false; error = $_.Exception.Message; repo_dir = $RepoDir; page = $PageUrl } | ConvertTo-Json -Compress
        Write-Output ('RESULT_JSON ' + $result)
    }
    exit 1
}
