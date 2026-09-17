param(
    [ValidateSet('bash', 'pwsh')][string]$Shell = 'pwsh',
    [string]$PluginRoot = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('project-map-e2e-' + [guid]::NewGuid())
$root = Join-Path $fixture 'workspace'
$git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$environmentNames = @('GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_COUNT', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR')
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}
function Write-File([string]$base, [string]$relative, [string]$content = 'fixture') {
    $path = Join-Path $base $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $content)
}
function Git-In([string]$directory, [string[]]$arguments) {
    $output = & $git -C $directory -c user.name=Fixture -c user.email=fixture@example.invalid -c core.autocrlf=false -c ('core.hooksPath=' + (Join-Path $fixture 'empty-hooks')) @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($arguments -join ' ') failed: $output" }
    return ($output -join "`n")
}
function Init-Repo([string]$directory) {
    [void][IO.Directory]::CreateDirectory($directory)
    $null = Git-In $directory @('-c', 'init.templateDir=', 'init', '-q')
}
function Commit-All([string]$directory) {
    $null = Git-In $directory @('add', '-f', '.')
    $null = Git-In $directory @('commit', '-qm', 'fixture')
}
function Assert-Map([string]$label, [string[]]$expected) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = if ($Shell -eq 'bash' -and -not $IsWindows) { '/bin/bash' } else { (Get-Command $Shell -CommandType Application | Select-Object -First 1).Source }
    if ($Shell -eq 'bash' -and $IsMacOS) { $start.Environment['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin' }
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($Shell -eq 'pwsh') {
        foreach ($arg in @('-NoLogo', '-NoProfile', '-File', (Join-Path $PluginRoot 'scripts/project_map.ps1'))) { $start.ArgumentList.Add($arg) }
    } else {
        $start.ArgumentList.Add((Join-Path $PluginRoot 'scripts/project_map.sh'))
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine((@{ cwd = $root; hook_event_name = 'SessionStart'; source = 'startup' } | ConvertTo-Json -Compress))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "$label exceeded the 15-second hook timeout"
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$label hook failed ($($process.ExitCode)): $errors" }
        if ($errors.Trim()) { throw "$label unexpected stderr: $errors" }
        if ($Shell -eq 'pwsh') {
            $json = $output | ConvertFrom-Json
            if ($json.hookSpecificOutput.hookEventName -cne 'SessionStart') { throw 'Invalid SessionStart response' }
            $context = $json.hookSpecificOutput.additionalContext
            $marker = 'Documentation paths (JSON-quoted):'
        } else {
            $context = $output
            $marker = 'Documentation paths (Bash-escaped):'
        }
        $lines = @($context.TrimEnd("`r", "`n") -split '\r?\n')
        $index = [Array]::IndexOf($lines, $marker)
        if ($index -lt 0) { throw "$label missing documentation marker: $output" }
        $actual = @($lines | Select-Object -Skip ($index + 1))
        if ($Shell -eq 'pwsh') { $actual = @($actual | ForEach-Object { $_ | ConvertFrom-Json }) }
        # Fixture paths use only shell-safe characters: Bash output is already literal.
        $sorted = [string[]]$expected.Clone()
        [Array]::Sort($sorted, [StringComparer]::Ordinal)
        if (($actual -join "`n") -cne ($sorted -join "`n")) {
            throw "$label complete map mismatch.`nExpected:`n$($sorted -join "`n")`nActual:`n$($actual -join "`n")"
        }
        Write-Host "PASS $Shell $label ($($actual.Count) exact paths, $([math]::Round($timer.Elapsed.TotalSeconds, 2)) seconds)"
    } finally { $process.Dispose() }
}
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'empty-hooks'))
    $env:GIT_CONFIG_GLOBAL = Join-Path $fixture 'global.gitconfig'
    $env:GIT_CONFIG_NOSYSTEM = '1'
    Write-File $fixture 'global.gitconfig' ''
    Init-Repo $root
    Write-File $root 'AGENTS.md'
    Write-File $root 'README.md'
    Write-File $root 'docs/README.md'
    Write-File $root '.gitignore' "apps/*`nnode_modules/`ngit-only/`n"
    Write-File $root '.ignore' "!apps/*`n!apps/**`nnode_modules/`n.ignore-only/`n"
    Commit-All $root

    $app = Join-Path $root 'apps/app'
    Init-Repo $app
    Write-File $app 'README.md'
    Write-File $app 'AGENTS.md'
    Write-File $app '.gitignore' "local-only/`nnode_modules/`n"
    Write-File $app 'local-only/README.md'
    Write-File $app '.hidden/rEaDmE.Md'
    Commit-All $app
    Write-File $app 'node_modules/dependency/README.md'
    Write-File $app '.ignore-only/AGENTS.md'
    Write-File $app '.git/README.md'
    $nested = Join-Path $app 'packages/deep'
    Init-Repo $nested
    Write-File $nested 'aGeNtS.mD'
    Write-File $nested 'docs/README.md'
    Commit-All $nested
    Write-File $nested 'node_modules/dependency/AGENTS.md'
    Write-File $nested '.git/AGENTS.md'

    $source = Join-Path $fixture 'source'
    Init-Repo $source
    Write-File $source 'README.md'
    Write-File $source 'docs/AGENTS.md'
    Write-File $source '.hidden/ReAdMe.md'
    Write-File $source '.gitignore' "local-only/`nnode_modules/`n"
    Write-File $source 'local-only/README.md'
    Commit-All $source
    $null = Git-In $root @('-c', 'protocol.file.allow=always', 'submodule', 'add', '--force', $source, 'apps/submodule')
    if (-not [IO.File]::Exists((Join-Path $root 'apps/submodule/.git'))) { throw 'Expected a real submodule .git file' }
    $gitlink = Git-In $root @('ls-files', '--stage', '--', 'apps/submodule')
    if ($gitlink -notmatch '^160000 ') { throw "Expected mode 160000 gitlink, got $gitlink" }
    Write-Host "Submodule evidence: $gitlink; .git is a file"
    $null = Git-In $root @('commit', '-qm', 'add submodule')
    $null = Git-In $root @('fetch', '--quiet', $source, 'HEAD')
    $null = Git-In $root @('read-tree', '--prefix=apps/subtree/', '-u', 'FETCH_HEAD')
    $null = Git-In $root @('commit', '-qm', 'import subtree')
    $subtree = Git-In $root @('ls-files', '--stage', '--', 'apps/subtree/README.md')
    if ($subtree -notmatch '^100644 ') { throw "Expected tracked subtree file, got $subtree" }
    Write-Host "Subtree evidence: $subtree"
    foreach ($directory in @('apps/submodule', 'apps/subtree')) {
        Write-File $root "$directory/node_modules/dependency/README.md"
        Write-File $root "$directory/.ignore-only/AGENTS.md"
    }
    Write-File $root 'git-only/README.md'
    Write-File $root '.ignore-only/README.md'
    Write-File $root 'node_modules/dependency/README.md'
    Write-File $root '.git/README.md'
    # Worktrees coexist with ordinary nested repositories and must never add paths.
    $checkouts = @(
        @{ Repository = $root; Path = (Join-Path $root 'custom-checkout') },
        @{ Repository = $app; Path = (Join-Path $app '.worktrees/session-a') },
        @{ Repository = $app; Path = (Join-Path $app '.worktrees/session-b') },
        @{ Repository = $root; Path = (Join-Path $fixture 'external-checkout') }
    )
    foreach ($checkout in $checkouts) {
        $null = Git-In $checkout.Repository @('worktree', 'add', '--quiet', '--detach', $checkout.Path)
        if (-not [IO.File]::Exists((Join-Path $checkout.Path '.git'))) { throw 'Expected a linked worktree .git file' }
        Write-File $checkout.Path 'worktree-only/README.md'
    }
    $base = @('AGENTS.md', 'README.md', 'docs/README.md')
    $custom = $base + @(
        'apps/app/AGENTS.md', 'apps/app/README.md', 'apps/app/.hidden/rEaDmE.Md',
        'apps/app/local-only/README.md', 'apps/app/packages/deep/aGeNtS.mD', 'apps/app/packages/deep/docs/README.md',
        'apps/submodule/README.md', 'apps/submodule/docs/AGENTS.md', 'apps/submodule/.hidden/ReAdMe.md', 'apps/submodule/local-only/README.md',
        'apps/subtree/README.md', 'apps/subtree/docs/AGENTS.md', 'apps/subtree/.hidden/ReAdMe.md', 'apps/subtree/local-only/README.md',
        'git-only/README.md'
    )
    Assert-Map '.ignore across nested repositories, submodule, subtree and worktrees' $custom
    Remove-Item -Force -LiteralPath (Join-Path $root '.ignore')
    # Git fallback prunes apps/* before encountering the submodule boundary.
    Assert-Map 'Git fallback after removing .ignore' ($base + @('.ignore-only/README.md'))
} finally {
    foreach ($name in $environmentNames) {
        if ($null -eq $savedEnvironment[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
