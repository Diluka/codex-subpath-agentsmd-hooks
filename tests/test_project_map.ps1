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
function Invoke-Map([string]$cwd, [string]$source = 'startup', [switch]$Fails) {
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
    Assert ((Invoke-Map $plain).Contains('No matching documentation files found.')) 'Empty project must be explicit'
    Add-Document $plain 'README.md'
    Assert (((Invoke-Map $plain) -split "`n") -ccontains '"README.md"') 'Non-git project must scan cwd'
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
    Write-Host 'PASS PowerShell project map checks'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
