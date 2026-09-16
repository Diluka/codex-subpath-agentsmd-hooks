# Run with PowerShell 7; no test framework or third-party modules required.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '../scripts/project_map.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('project-map-test-' + [guid]::NewGuid())
function Assert($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Add-Document([string]$root, [string]$path) {
    $file = Join-Path $root $path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
    [IO.File]::WriteAllText($file, 'CONTENTS_MUST_NOT_APPEAR')
}
function Invoke-Map([string]$cwd, [string]$source = 'startup', [switch]$Fails, [switch]$Skip) {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($arg in @('-NoLogo', '-NoProfile', '-File', $script)) { $start.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.StandardInput.WriteLine((@{ cwd = $cwd; source = $source; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress))
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'Hook timed out' }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($Fails) {
            Assert ($process.ExitCode -ne 0 -and $errorText -match 'cwd') 'Invalid cwd must fail with a diagnostic'
            Assert ([string]::IsNullOrWhiteSpace($output)) 'Failed hook must not emit a map'
            return
        }
        Assert ($process.ExitCode -eq 0) "Hook failed: $errorText"
        if ($Skip) {
            Assert ([string]::IsNullOrWhiteSpace($output)) 'Non-git directory must emit nothing'
            return
        }
        $result = $output | ConvertFrom-Json
        Assert ($result.hookSpecificOutput.hookEventName -ceq 'SessionStart') 'Wrong hook event'
        $context = $result.hookSpecificOutput.additionalContext
        Assert ($context -is [string] -and $context -notmatch 'CONTENTS_MUST_NOT_APPEAR') 'Map must contain paths, not file contents'
        return $context
    } finally { $process.Dispose() }
}
try {
    [void][IO.Directory]::CreateDirectory($temp)
    $repo = Join-Path $temp '项目 with spaces'
    [void][IO.Directory]::CreateDirectory($repo)
    & git -C $repo init -q
    Assert ($LASTEXITCODE -eq 0) 'git init failed'
    foreach ($path in @('AGENTS.md', 'README.md', 'src/ReadMe.MD', '.hidden/agents.md', '中文 空格/README.md')) { Add-Document $repo $path }
    foreach ($dir in @('.git', '.hg', '.svn', 'node_modules', '.venv', 'venv', '__pycache__')) { Add-Document $repo "$dir/ignored/README.md" }
    [IO.File]::WriteAllLines((Join-Path $repo '.gitignore'), @('.hg/', '.svn/', 'node_modules/', '.venv/', 'venv/', '__pycache__/'))
    $context = Invoke-Map (Join-Path $repo 'src')
    Assert ($context.Contains('Project root: ' + (ConvertTo-Json -InputObject $repo -Compress))) 'Subdirectory must resolve to git root'
    $paths = @($context -split "`n" | Where-Object { $_.StartsWith('"') } | ForEach-Object { ConvertFrom-Json -InputObject $_ })
    $expected = @('.hidden/agents.md', 'AGENTS.md', 'README.md', 'src/ReadMe.MD', '中文 空格/README.md')
    Assert (($paths -join '|') -ceq ($expected -join '|')) 'Map must include hidden/case-insensitive names, sort paths, and exclude dependencies'
    Add-Document $repo 'new/AGENTS.md'
    Remove-Item -LiteralPath (Join-Path $repo 'README.md')
    $refreshed = Invoke-Map (Join-Path $repo 'src') 'compact'
    Assert (($refreshed -split "`n") -ccontains '"new/AGENTS.md"') 'Compact must discover new files'
    Assert (($refreshed -split "`n") -cnotcontains '"README.md"') 'Compact must discard removed files'

    $plain = Join-Path $temp 'plain'
    [void][IO.Directory]::CreateDirectory($plain)
    Invoke-Map $plain -Skip
    Add-Document $plain 'README.md'
    Invoke-Map $plain -Skip
    & git -C $plain init -q
    Assert ($LASTEXITCODE -eq 0) 'git init failed'
    Invoke-Map 'relative/path' -Fails
    Invoke-Map (Join-Path $temp 'missing') -Fails
    Invoke-Map (Join-Path $plain 'README.md') -Fails
    if (-not $IsWindows) {
        Add-Document $plain "line`nbreak/README.md"
        Assert (((Invoke-Map $plain) -split "`n") -ccontains '"line\nbreak/README.md"') 'Newline paths must remain JSON-quoted'
        foreach ($name in @("root`nname", "root`n")) {
            $unusual = Join-Path $temp $name
            Add-Document $unusual 'README.md'
            [void][IO.Directory]::CreateDirectory((Join-Path $unusual 'src'))
            & git -C $unusual init -q
            Assert ($LASTEXITCODE -eq 0) 'git init failed'
            & mkfifo (Join-Path $unusual 'src/AGENTS.md')
            Assert ($LASTEXITCODE -eq 0) 'mkfifo failed'
            $map = (Invoke-Map (Join-Path $unusual 'src')) -split "`n"
            Assert ($map -ccontains '"README.md"') 'Newline git root must resolve'
            Assert ($map -cnotcontains '"src/AGENTS.md"') 'Named pipes must not be included'
        }
    }

    $linksAvailable = $false
    try {
        [void](New-Item -ItemType SymbolicLink -Path (Join-Path $plain 'linked') -Target $repo)
        [void](New-Item -ItemType SymbolicLink -Path (Join-Path $plain 'AGENTS.md') -Target (Join-Path $repo 'AGENTS.md'))
        $linksAvailable = $true
    } catch { Write-Host "SKIP symbolic links: $($_.Exception.Message)" }
    if ($linksAvailable) {
        $linkedMap = Invoke-Map $plain
        Assert ($linkedMap -notmatch '"linked/') 'Directory symlinks must not be traversed'
        Assert (($linkedMap -split "`n") -cnotcontains '"AGENTS.md"') 'File symlinks must not be included'
    }
    # Git owns ignore matching, including nested, local, and configured excludes.
    $rules = Join-Path $temp 'rules'
    [void][IO.Directory]::CreateDirectory($rules)
    & git -C $rules init -q
    Assert ($LASTEXITCODE -eq 0) 'git init failed'
    $documents = @('tracked/README.md', 'node_modules/README.md', 'nested/README.md', 'top/README.md',
        'child/top/README.md', 'tree/deep/README.md', 'open/README.md', 'closed/README.md', '#hash/README.md', '#comment/README.md',
        'nested/hidden/README.md', 'local/README.md', 'global/README.md')
    foreach ($path in $documents) { Add-Document $rules $path }
    & git -C $rules add tracked/README.md
    Assert ($LASTEXITCODE -eq 0) 'git add failed'
    & git -C (Join-Path $rules 'nested') init -q
    Assert ($LASTEXITCODE -eq 0) 'nested git init failed'
    Add-Document $rules 'nested/.git/README.md'
    $gitignore = Join-Path $rules '.gitignore'
    [IO.File]::WriteAllLines($gitignore, @('tracked/', '#comment/', '/top/', 'tree/**', 'open/*', '!open/README.md',
        'closed/', '!closed/README.md', '\#hash/'))
    [IO.File]::WriteAllText((Join-Path $rules '.ignore'), "*`n")
    [IO.File]::WriteAllText((Join-Path $rules 'nested/.gitignore'), "hidden/`n")
    [IO.File]::WriteAllText((Join-Path $rules '.git/info/exclude'), "local/`n")
    $globalIgnore = Join-Path $temp 'global-ignore'
    [IO.File]::WriteAllText($globalIgnore, "global/`n")
    & git -C $rules config core.excludesFile $globalIgnore
    Assert ($LASTEXITCODE -eq 0) 'git config failed'
    $map = (Invoke-Map $rules) -split "`n"
    Assert ($map -cnotcontains '"nested/.git/README.md"') 'Nested Git metadata must be skipped'
    $excluded = @('tracked/README.md', 'top/README.md', 'tree/deep/README.md', 'closed/README.md', '#hash/README.md',
        'nested/hidden/README.md', 'local/README.md', 'global/README.md')
    foreach ($path in $documents) {
        $quoted = ConvertTo-Json -InputObject $path -Compress
        Assert (($map -ccontains $quoted) -eq ($excluded -cnotcontains $path)) "Wrong ignore result: $path"
    }
    [IO.File]::AppendAllText($gitignore, "node_modules/`n")
    if (-not $IsWindows) {
        $blocked = Join-Path $rules 'node_modules'
        & chmod 000 $blocked
        Assert ($LASTEXITCODE -eq 0) 'chmod failed'
        try {
            Assert (((Invoke-Map $rules) -split "`n") -ccontains '"open/README.md"') 'Excluded directories must be pruned before enumeration'
        } finally { & chmod 700 $blocked }
    }
    $sentinel = Join-Path $temp 'sentinel'
    [void][IO.Directory]::CreateDirectory($sentinel)
    $savedGitDir = $env:GIT_DIR
    try {
        $env:GIT_DIR = $sentinel
        Assert (((Invoke-Map (Join-Path $rules 'tracked')) -split "`n") -ccontains '"open/README.md"') 'Inherited GIT_DIR must not change project root'
        Assert (-not (Test-Path (Join-Path $sentinel 'config'))) 'Hook must not initialize inherited GIT_DIR'
        Assert (-not (Test-Path (Join-Path $sentinel 'HEAD'))) 'Hook must not write inherited GIT_DIR'
    } finally { $env:GIT_DIR = $savedGitDir }
    $cleanupRoot = Join-Path $temp 'cleanup'
    [void][IO.Directory]::CreateDirectory($cleanupRoot)
    $savedTemp = @{}
    try {
        foreach ($name in @('TMPDIR', 'TEMP', 'TMP')) {
            $savedTemp[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $cleanupRoot)
        }
        $null = Invoke-Map $rules
        $null = Invoke-Map (Join-Path $rules 'tracked')
        Assert (@(Get-ChildItem -LiteralPath $cleanupRoot -Force).Count -eq 0) 'Hook must not create temporary files'
    } finally {
        foreach ($name in $savedTemp.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTemp[$name]) }
    }
    Write-Host 'PASS PowerShell project map checks'
} finally {
    Write-Host "Test fixtures retained: $temp"
}
