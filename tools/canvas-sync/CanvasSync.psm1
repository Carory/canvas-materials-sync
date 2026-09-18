Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-SafePathSegment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $safe = $Name -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    $safe = $safe.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = '_' }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($safe)
    if ($stem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $safe = "_$safe"
    }
    return $safe
}

function Get-CanvasRelativeFolder {
    [CmdletBinding()]
    param([AllowNull()][string]$FullName)

    if ([string]::IsNullOrWhiteSpace($FullName)) { return '' }
    $parts = @($FullName -split '/' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -gt 0 -and $parts[0] -match '^(?i:course files)$') {
        $parts = @($parts | Select-Object -Skip 1)
    }
    if ($parts.Count -eq 0) { return '' }
    return [System.IO.Path]::Combine([string[]]@($parts | ForEach-Object { ConvertTo-SafePathSegment $_ }))
}

function Find-CanvasCourseCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Courses,
        [Parameter(Mandatory)][string]$Code
    )

    $pattern = "(?<!\d)$([regex]::Escape($Code))(?!\d)"
    return @($Courses | Where-Object {
        $course = $_
        $values = @('course_code', 'name', 'original_name', 'sis_course_id' | ForEach-Object {
            $property = $course.PSObject.Properties[$_]
            if ($null -ne $property) { $property.Value }
        })
        @($values | Where-Object { $_ -and (([string]$_) -match $pattern) }).Count -gt 0
    })
}

function Get-PlainTextFromSecureString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-CanvasToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TokenPath,
        [switch]$Reset
    )

    if ($Reset -and (Test-Path -LiteralPath $TokenPath)) {
        Remove-Item -LiteralPath $TokenPath -Force
    }

    if (-not (Test-Path -LiteralPath $TokenPath)) {
        Write-Host ''
        Write-Host '首次使用：请粘贴 Canvas Access Token。输入内容不会显示。' -ForegroundColor Cyan
        Write-Host '获取位置：Canvas → Account → Settings → New Access Token'
        $secure = Read-Host 'Access Token' -AsSecureString
        if ($secure.Length -eq 0) { throw '没有输入 Access Token。' }
        $parent = Split-Path -Parent $TokenPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $secure | ConvertFrom-SecureString | Set-Content -LiteralPath $TokenPath -Encoding UTF8
        Write-Host 'Token 已使用 Windows 用户加密保存。' -ForegroundColor Green
    }

    try {
        $encrypted = (Get-Content -LiteralPath $TokenPath -Raw).Trim()
        $secureToken = $encrypted | ConvertTo-SecureString
        return Get-PlainTextFromSecureString $secureToken
    }
    catch {
        throw "无法读取加密 Token。请使用 -ResetToken 重新设置。详细信息：$($_.Exception.Message)"
    }
}

function Get-NextLink {
    [CmdletBinding()]
    param([AllowNull()]$LinkHeader)
    if (-not $LinkHeader) { return $null }
    $text = if ($LinkHeader -is [array]) { $LinkHeader -join ',' } else { [string]$LinkHeader }
    foreach ($part in ($text -split ',')) {
        if ($part -match '<([^>]+)>\s*;\s*rel="next"') { return $Matches[1] }
    }
    return $null
}

function Invoke-CanvasPagedGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        try {
            $responseHeaders = $null
            $page = Invoke-RestMethod -Method Get -Uri $next -Headers $Headers -ResponseHeadersVariable responseHeaders
        }
        catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 401) { throw 'Canvas 拒绝了 Access Token（401）。请使用 -ResetToken 重新设置。' }
            if ($status -eq 403) { throw 'Canvas 拒绝访问该资源（403），可能是文件未开放或账号权限不足。' }
            throw "连接 Canvas 失败：$($_.Exception.Message)"
        }

        if ($null -ne $page) {
            if ($page -is [array]) { foreach ($item in $page) { $all.Add($item) } }
            else { $all.Add($page) }
        }
        $linkHeader = if ($null -ne $responseHeaders) { $responseHeaders['Link'] } else { $null }
        $next = Get-NextLink $linkHeader
    }
    return $all.ToArray()
}

function Read-JsonHashtable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Default)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable) }
    catch { throw "配置文件格式损坏：$Path`n$($_.Exception.Message)" }
}

function Write-JsonAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ('.canvas-json-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Resolve-CanvasCourseMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$CanvasCourses,
        [Parameter(Mandatory)][object[]]$CourseConfigs,
        [Parameter(Mandatory)][hashtable]$SavedMap,
        [switch]$DryRun
    )

    $resolved = @{}
    foreach ($config in $CourseConfigs) {
        $code = [string]$config.code
        $savedId = if ($SavedMap.ContainsKey($code)) { [string]$SavedMap[$code] } else { $null }
        $savedCourse = @($CanvasCourses | Where-Object { [string]$_.id -eq $savedId })
        if ($savedCourse.Count -eq 1) {
            $resolved[$code] = $savedCourse[0]
            continue
        }

        $candidates = @(Find-CanvasCourseCandidates -Courses $CanvasCourses -Code $code)
        if ($candidates.Count -eq 0) {
            Write-Warning "找不到课程 $code。该课程会被跳过。"
            continue
        }
        if ($candidates.Count -eq 1) {
            $resolved[$code] = $candidates[0]
            $SavedMap[$code] = [string]$candidates[0].id
            continue
        }

        Write-Host ''
        Write-Host "课程代码 $code 匹配到多个 Canvas 课程：" -ForegroundColor Yellow
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host "  [$($i + 1)] $($candidates[$i].course_code) — $($candidates[$i].name)"
        }
        do {
            $choice = Read-Host "请输入 1-$($candidates.Count)"
            $number = 0
            $valid = [int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count
        } until ($valid)
        $selected = $candidates[$number - 1]
        $resolved[$code] = $selected
        $SavedMap[$code] = [string]$selected.id
    }
    return $resolved
}

function Get-FileHashString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ConflictPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetPath, [Parameter(Mandatory)][string]$FileId)
    $directory = Split-Path -Parent $TargetPath
    $base = [System.IO.Path]::GetFileNameWithoutExtension($TargetPath)
    $extension = [System.IO.Path]::GetExtension($TargetPath)
    $candidate = Join-Path $directory "$base.canvas-conflict-$FileId$extension"
    $counter = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory "$base.canvas-conflict-$FileId-$counter$extension"
        $counter++
    }
    return $candidate
}

function Receive-CanvasFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$File,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Mode
    )

    $parent = Split-Path -Parent $TargetPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ('.canvas-part-' + [guid]::NewGuid().ToString('N'))
    try {
        Invoke-WebRequest -Method Get -Uri ([string]$File.url) -Headers $Headers -OutFile $temp
        if (-not (Test-Path -LiteralPath $temp)) { throw '下载结束后没有找到临时文件。' }
        if ($null -ne $File.size -and [long]$File.size -ge 0) {
            $actualSize = (Get-Item -LiteralPath $temp).Length
            if ($actualSize -ne [long]$File.size) {
                throw "文件大小校验失败：Canvas=$($File.size)，下载=$actualSize。"
            }
        }

        if ($Mode -eq 'ExistingUnmanaged') {
            if ((Get-FileHashString $temp) -eq (Get-FileHashString $TargetPath)) {
                return @{ Outcome = 'Adopted'; Path = $TargetPath; Hash = (Get-FileHashString $temp) }
            }
            $conflictPath = Get-ConflictPath -TargetPath $TargetPath -FileId ([string]$File.id)
            Move-Item -LiteralPath $temp -Destination $conflictPath
            return @{ Outcome = 'Conflict'; Path = $conflictPath; Hash = (Get-FileHashString $conflictPath) }
        }

        $hash = Get-FileHashString $temp
        Move-Item -LiteralPath $temp -Destination $TargetPath -Force
        return @{ Outcome = $Mode; Path = $TargetPath; Hash = $hash }
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Sync-CanvasCourse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)]$CanvasCourse,
        [Parameter(Mandatory)]$CourseConfig,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][hashtable]$Stats,
        [switch]$DryRun
    )

    $code = [string]$CourseConfig.code
    $materialsRoot = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot "$($CourseConfig.localDirectory)\materials"))
    $foldersUri = "$BaseUrl/api/v1/courses/$($CanvasCourse.id)/folders?per_page=100"
    $filesUri = "$BaseUrl/api/v1/courses/$($CanvasCourse.id)/files?per_page=100&sort=updated_at&order=asc"
    $folders = @(Invoke-CanvasPagedGet -Uri $foldersUri -Headers $Headers)
    $files = @(Invoke-CanvasPagedGet -Uri $filesUri -Headers $Headers)
    $folderMap = @{}
    foreach ($folder in $folders) { $folderMap[[string]$folder.id] = Get-CanvasRelativeFolder ([string]$folder.full_name) }

    Write-Host "`n[$code] $($CanvasCourse.name) — $($files.Count) 个文件" -ForegroundColor Cyan
    foreach ($file in $files) {
        try {
            if (($file.PSObject.Properties.Name -contains 'hidden_for_user' -and $file.hidden_for_user) -or
                ($file.PSObject.Properties.Name -contains 'locked_for_user' -and $file.locked_for_user)) {
                Write-Host "  跳过（未开放）：$($file.display_name)" -ForegroundColor DarkYellow
                $Stats.Skipped++
                continue
            }

            $relativeFolder = if ($folderMap.ContainsKey([string]$file.folder_id)) { $folderMap[[string]$file.folder_id] } else { '' }
            $safeName = ConvertTo-SafePathSegment ([string]$file.display_name)
            $targetDirectory = if ($relativeFolder) { Join-Path $materialsRoot $relativeFolder } else { $materialsRoot }
            $target = [System.IO.Path]::GetFullPath((Join-Path $targetDirectory $safeName))
            $rootPrefix = $materialsRoot.TrimEnd('\') + '\'
            if (-not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Canvas 路径超出 materials 目录：$target"
            }

            $key = "$code`:$($file.id)"
            $entry = if ($Manifest.files.ContainsKey($key)) { $Manifest.files[$key] } else { $null }
            $isManaged = $null -ne $entry -and (Test-Path -LiteralPath ([string]$entry.localPath))
            $targetIsManaged = $isManaged -and [System.IO.Path]::GetFullPath([string]$entry.localPath).Equals($target, [StringComparison]::OrdinalIgnoreCase)
            $unchanged = $targetIsManaged -and [string]$entry.updatedAt -eq [string]$file.updated_at -and [long]$entry.size -eq [long]$file.size

            if ($unchanged) {
                Write-Host "  未变化：$relativeFolder/$safeName" -ForegroundColor DarkGray
                $Stats.Skipped++
                continue
            }

            $mode = if ($targetIsManaged) { 'Updated' } elseif (Test-Path -LiteralPath $target) { 'ExistingUnmanaged' } elseif ($isManaged) { 'Updated' } else { 'Downloaded' }
            if ($DryRun) {
                $label = switch ($mode) { 'Updated' { '将更新' }; 'ExistingUnmanaged' { '将校验现有文件' }; default { '将下载' } }
                Write-Host "  $label：$relativeFolder/$safeName" -ForegroundColor Yellow
                continue
            }

            $result = Receive-CanvasFile -File $file -TargetPath $target -Headers $Headers -Mode $mode
            $Manifest.files[$key] = @{
                courseCode = $code
                canvasFileId = [string]$file.id
                updatedAt = [string]$file.updated_at
                size = [long]$file.size
                localPath = [string]$result.Path
                sha256 = [string]$result.Hash
            }
            switch ($result.Outcome) {
                'Downloaded' { $Stats.Downloaded++; Write-Host "  已下载：$relativeFolder/$safeName" -ForegroundColor Green }
                'Updated' { $Stats.Updated++; Write-Host "  已更新：$relativeFolder/$safeName" -ForegroundColor Green }
                'Adopted' { $Stats.Skipped++; Write-Host "  已有相同文件：$relativeFolder/$safeName" -ForegroundColor DarkGray }
                'Conflict' { $Stats.Conflicts++; Write-Host "  同名冲突，Canvas 版本保存为：$($result.Path)" -ForegroundColor Yellow }
            }
        }
        catch {
            $Stats.Failed++
            Write-Warning "文件 $($file.display_name) 处理失败：$($_.Exception.Message)"
        }
    }
}

function Start-CanvasSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string[]]$Course,
        [switch]$DryRun,
        [switch]$ResetToken,
        [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'DataScienceMaster\CanvasSync')
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) { throw '此同步工具需要 PowerShell 7（pwsh）。' }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $baseUrl = ([string]$config.canvasBaseUrl).TrimEnd('/')
    $selectedConfigs = @($config.courses)
    if ($Course -and $Course.Count -gt 0) {
        $selectedConfigs = @($selectedConfigs | Where-Object { $Course -contains [string]$_.code })
        $unknown = @($Course | Where-Object { $_ -notin @($config.courses.code) })
        if ($unknown.Count -gt 0) { throw "未知课程代码：$($unknown -join ', ')" }
    }

    $tokenPath = Join-Path $StateDirectory 'token.dpapi'
    $mapPath = Join-Path $StateDirectory 'course-map.json'
    $manifestPath = Join-Path $StateDirectory 'manifest.json'
    $token = Get-CanvasToken -TokenPath $tokenPath -Reset:$ResetToken
    $headers = @{ Authorization = "Bearer $token" }
    try {
        Write-Host "正在连接 $baseUrl ..." -ForegroundColor Cyan
        $courses = @(Invoke-CanvasPagedGet -Uri "$baseUrl/api/v1/courses?enrollment_state=active&per_page=100" -Headers $headers)
        $savedMap = Read-JsonHashtable -Path $mapPath -Default @{}
        $resolved = Resolve-CanvasCourseMap -CanvasCourses $courses -CourseConfigs $selectedConfigs -SavedMap $savedMap -DryRun:$DryRun
        if (-not $DryRun) { Write-JsonAtomic -Value $savedMap -Path $mapPath }

        $manifest = Read-JsonHashtable -Path $manifestPath -Default @{ version = 1; files = @{} }
        if (-not $manifest.ContainsKey('files')) { $manifest.files = @{} }
        $stats = @{ Downloaded = 0; Updated = 0; Skipped = 0; Conflicts = 0; Failed = 0 }

        foreach ($courseConfig in $selectedConfigs) {
            $code = [string]$courseConfig.code
            if (-not $resolved.ContainsKey($code)) { $stats.Failed++; continue }
            try {
                Sync-CanvasCourse -BaseUrl $baseUrl -CanvasCourse $resolved[$code] -CourseConfig $courseConfig `
                    -RepositoryRoot $RepositoryRoot -Headers $headers -Manifest $manifest -Stats $stats -DryRun:$DryRun
                if (-not $DryRun) { Write-JsonAtomic -Value $manifest -Path $manifestPath }
            }
            catch {
                $stats.Failed++
                Write-Warning "课程 $code 同步失败：$($_.Exception.Message)"
            }
        }

        Write-Host ''
        if ($DryRun) { Write-Host 'Dry Run 完成：没有写入课程资料或同步状态。' -ForegroundColor Cyan }
        Write-Host "结果：下载 $($stats.Downloaded)，更新 $($stats.Updated)，跳过 $($stats.Skipped)，冲突 $($stats.Conflicts)，失败 $($stats.Failed)"
        if ($stats.Failed -gt 0) { return 1 }
        return 0
    }
    finally {
        $token = $null
        $headers = $null
        [GC]::Collect()
    }
}

Export-ModuleMember -Function ConvertTo-SafePathSegment, Get-CanvasRelativeFolder, Find-CanvasCourseCandidates, Get-NextLink, Get-ConflictPath, Start-CanvasSync
