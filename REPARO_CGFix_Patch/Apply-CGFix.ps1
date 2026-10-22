param(
    [string]$GameDirectory,
    [switch]$CheckOnly,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$packageRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$patchId = 'REPARO-CGFix-20261021'
$lock = $null
$lockPath = $null
$backup = $null
$work = $null

function Child-Path([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or
        $Relative.Contains(':') -or $Relative -match '(^|[\\/])(\.\.?|Saved)([\\/]|$)') {
        throw "补丁内含无效路径：$Relative"
    }
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "路径超出所选目录：$Relative"
    }
    # Do not follow user-created junctions or symbolic links into another folder.
    $cursor = $full
    while ($cursor.Length -gt $prefix.Length) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "请使用普通文件夹，路径含链接：$cursor"
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function File-Hash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Matches([string]$Path, $Record) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne [long]$Record.bytes) { return $false }
    return (File-Hash $Path) -eq $Record.sha256
}

function Save-State($State, [string]$Backup) {
    $stateFile = Child-Path $Backup 'state.json'
    $temporary = Child-Path $Backup 'state.json.tmp'
    $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $stateFile -Force
}

function Restore-Backup([string]$Backup, [string]$GameRoot) {
    $state = Get-Content -LiteralPath (Child-Path $Backup 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.id -ne $patchId) { throw '备份标识不匹配。' }
    # Validate every original and destination before changing any file.
    foreach ($change in $state.changes) {
        $destination = Child-Path $GameRoot $change.path
        $original = Child-Path $Backup ('files/' + $change.path)
        if ($null -ne $change.base) {
            if (Test-Path -LiteralPath $original) {
                if (-not (Matches $original $change.base)) { throw "备份校验失败：$($change.path)" }
            } elseif (-not (Matches $destination $change.base)) {
                throw "原文件和备份均不可用：$($change.path)"
            }
        }
        if (Test-Path -LiteralPath $destination) {
            $isBase = $null -ne $change.base -and (Matches $destination $change.base)
            if (-not $isBase -and -not (Matches $destination $change.target)) {
                throw "文件在安装后被修改，请先另行备份：$($change.path)"
            }
        }
    }
    foreach ($change in $state.changes) {
        $destination = Child-Path $GameRoot $change.path
        $original = Child-Path $Backup ('files/' + $change.path)
        if ($null -ne $change.base -and (Test-Path -LiteralPath $original)) {
            if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination }
            Move-Item -LiteralPath $original -Destination $destination
        } elseif ($null -eq $change.base -and (Test-Path -LiteralPath $destination)) {
            Remove-Item -LiteralPath $destination
        }
    }
    $state.status = 'restored'
    Save-State $state $Backup
    Write-Host '已还原到安装补丁前的版本，存档保留。' -ForegroundColor Green
}

try {
    if ($manifest.schema -ne 1 -or $manifest.id -ne $patchId) { throw '补丁清单版本不支持。' }
    if (-not $GameDirectory) {
        $candidate = Split-Path -Parent $packageRoot
        if (Test-Path -LiteralPath (Join-Path $candidate 'mirrorC.exe')) {
            $GameDirectory = $candidate
        } else {
            $GameDirectory = (Read-Host '输入或粘贴旧游戏 Windows 文件夹的完整路径（内含 mirrorC.exe）').Trim('"')
        }
    }
    $gameRoot = (Resolve-Path -LiteralPath $GameDirectory).ProviderPath.TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Child-Path $gameRoot 'mirrorC.exe') -PathType Leaf)) {
        throw '所选目录中没有 mirrorC.exe，请选择旧游戏的 Windows 文件夹。'
    }
    foreach ($process in @(Get-Process -Name 'mirrorC','mirrorC-Win64-Shipping' -ErrorAction SilentlyContinue)) {
        if ($process.Path -and $process.Path.StartsWith($gameRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw '请先退出游戏，再安装或还原补丁。'
        }
    }
    $backup = Child-Path $gameRoot '_REPARO_CGFix_Backup'
    $work = Child-Path $gameRoot '_REPARO_CGFix_Work'
    if ($Restore) {
        if ($CheckOnly) { throw 'CheckOnly 和 Restore 不能同时使用。' }
        $lockPath = Child-Path $gameRoot '_REPARO_CGFix.lock'
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
        Restore-Backup $backup $gameRoot
        exit 0
    }

    Write-Host '检查是否已安装此修复……'
    $alreadyApplied = $true
    foreach ($file in $manifest.target_files) {
        if (-not (Matches (Child-Path $gameRoot $file.path) $file)) { $alreadyApplied = $false; break }
    }
    if ($alreadyApplied) {
        Write-Host '此目录已经是 CG 修复版，无需重复安装。' -ForegroundColor Green
        exit 0
    }
    if ((Test-Path -LiteralPath $backup) -or (Test-Path -LiteralPath $work)) {
        throw '检测到补丁备份或未完成的安装。请先运行 Restore-Original.cmd；已还原的备份和工作目录可手动移走后重试。'
    }
    Write-Host ('校验原版文件：' + $manifest.base_label)
    foreach ($file in $manifest.base_files) {
        if (-not (Matches (Child-Path $gameRoot $file.path) $file)) {
            throw "旧版本不匹配或文件已修改，未安装补丁：$($file.path)。仅支持 REPARO-Windows-Shipping-20261021 原包。"
        }
    }
    foreach ($change in $manifest.changes) {
        if ($null -eq $change.base -and (Test-Path -LiteralPath (Child-Path $gameRoot $change.path))) {
            throw "原包中不应存在此文件，请先移走另行保留：$($change.path)"
        }
    }
    $decoder = Child-Path $packageRoot 'tools/xdelta3.exe'
    if ((File-Hash $decoder) -ne $manifest.decoder_sha256) {
        throw '补丁工具校验失败，请重新下载并完整解压补丁。'
    }
    foreach ($change in $manifest.changes) {
        if ($change.method -notin @('copy','xdelta3')) { throw '补丁包含不支持的操作。' }
        if (-not (Matches (Child-Path $packageRoot $change.payload.path) $change.payload)) {
            throw "补丁数据校验失败，请重新下载：$($change.payload.path)"
        }
    }
    if ($CheckOnly) {
        Write-Host '旧版本和补丁数据校验通过；本次只检查，未修改文件。' -ForegroundColor Green
        exit 0
    }
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($gameRoot))
    if ($drive.AvailableFreeSpace -lt [long]$manifest.required_free_bytes) {
        throw '游戏所在磁盘空间不足，请至少留出 4 GB 空间。'
    }
    $lockPath = Child-Path $gameRoot '_REPARO_CGFix.lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
    New-Item -ItemType Directory -Path $work | Out-Null
    # Do not inherit optional xdelta arguments from the caller's environment.
    $env:XDELTA = $null
    $index = 0
    foreach ($change in $manifest.changes) {
        $index++
        Write-Host "[$index/$(@($manifest.changes).Count)] 生成并校验：$($change.path)"
        $output = Child-Path $work $change.path
        New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
        $payload = Child-Path $packageRoot $change.payload.path
        if ($change.method -eq 'xdelta3') {
            $source = Child-Path $gameRoot $change.path
            & $decoder -d -D -R -s $source $payload $output
            if ($LASTEXITCODE -ne 0) { throw "差分还原失败：$($change.path)" }
        } else {
            Copy-Item -LiteralPath $payload -Destination $output
        }
        if (-not (Matches $output $change.target)) { throw "生成文件校验失败：$($change.path)" }
    }

    New-Item -ItemType Directory -Path $backup | Out-Null
    $state = [ordered]@{ id = $patchId; status = 'installing'; changes = $manifest.changes }
    Save-State $state $backup
    try {
        Write-Host '所有新文件校验通过，备份原文件并安装……'
        foreach ($change in $manifest.changes) {
            $destination = Child-Path $gameRoot $change.path
            if ($null -ne $change.base) {
                $original = Child-Path $backup ('files/' + $change.path)
                New-Item -ItemType Directory -Path (Split-Path -Parent $original) -Force | Out-Null
                Move-Item -LiteralPath $destination -Destination $original
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Move-Item -LiteralPath (Child-Path $work $change.path) -Destination $destination
        }
        foreach ($file in $manifest.target_files) {
            if (-not (Matches (Child-Path $gameRoot $file.path) $file)) {
                throw "安装后校验失败：$($file.path)"
            }
        }
        $state.status = 'applied'
        Save-State $state $backup
    } catch {
        $installError = $_
        Write-Host '安装中断，正在还原原文件……' -ForegroundColor Yellow
        Restore-Backup $backup $gameRoot
        throw $installError
    }
    # Child-Path validates the exact generated directory before recursive cleanup.
    Remove-Item -LiteralPath (Child-Path $gameRoot '_REPARO_CGFix_Work') -Recurse
    Write-Host '补丁安装成功！全部发布文件 SHA-256 校验通过，存档保留。' -ForegroundColor Green
    Write-Host '运行 mirrorC.exe 开始游戏。需要还原时运行 Restore-Original.cmd。'
} catch {
    if ($null -ne $lock -and $work -and (Test-Path -LiteralPath $work) -and
        $backup -and -not (Test-Path -LiteralPath $backup)) {
        Remove-Item -LiteralPath (Child-Path $gameRoot '_REPARO_CGFix_Work') -Recurse
    }
    Write-Host ('失败：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($null -ne $lock) {
        $lock.Dispose()
        if ($lockPath -and (Test-Path -LiteralPath $lockPath)) { Remove-Item -LiteralPath $lockPath }
    }
}
