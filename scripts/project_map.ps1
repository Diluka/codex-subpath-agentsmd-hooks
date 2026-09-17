# PowerShell 7: emit documentation paths through the Codex SessionStart contract.
$ErrorActionPreference = 'Stop'
foreach ($name in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR')) {
    Set-Item -LiteralPath "Env:$name" -Value $null
}

try {
    $event = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    if ($event -isnot [System.Collections.IDictionary] -or
        $event.cwd -isnot [string] -or
        -not [IO.Path]::IsPathFullyQualified($event.cwd) -or
        -not [IO.Directory]::Exists($event.cwd)) {
        throw 'Hook cwd must be an existing absolute directory'
    }
    $root = [IO.Path]::GetFullPath($event.cwd)
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) { throw 'Git is required to interpret ignore rules' }
    try {
        $gitRoot = (& $git.Source -C $root rev-parse --show-toplevel 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { exit 0 }
        $root = [IO.Path]::GetFullPath($gitRoot)
    } catch {
        exit 0
    }

    $ignoreFile = Get-Item -LiteralPath (Join-Path $root '.ignore') -Force -ErrorAction SilentlyContinue
    $useIgnoreFile = $ignoreFile -and -not $ignoreFile.PSIsContainer -and
        -not ($ignoreFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        ($IsWindows -or $ignoreFile.UnixStat.ItemType -eq 'File')
    $ignoreRoot = $null
    if ($useIgnoreFile) {
        $ignoreRoot = Join-Path ([IO.Path]::GetTempPath()) ('project-map-ignore-' + [guid]::NewGuid())
        [void][IO.Directory]::CreateDirectory($ignoreRoot)
        & $git.Source -C $ignoreRoot -c init.templateDir= init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize ignore matcher' }
    }
    # ponytail: one Git process per directory/document; batch if large trees hit the hook timeout.
    function Is-Ignored([string]$relative, [bool]$directory = $false) {
        if ($useIgnoreFile) {
            $mirror = Join-Path $ignoreRoot $relative
            $parent = if ($directory) { $mirror } else { [IO.Path]::GetDirectoryName($mirror) }
            [void][IO.Directory]::CreateDirectory($parent)
            & $git.Source -C $ignoreRoot -c ('core.excludesFile=' + $ignoreFile.FullName) check-ignore --no-index --quiet -- $relative
            if ($LASTEXITCODE -eq 0) { return $true }
            if ($LASTEXITCODE -eq 1) { return $false }
            throw "Git ignore processing failed for: $relative"
        }
        & $git.Source -C $root check-ignore --no-index --quiet -- $relative
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($LASTEXITCODE -eq 1) { return $false }
        throw "Git ignore processing failed for: $relative"
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $paths = [Collections.Generic.List[string]]::new()
    $pending.Push($root)
    while ($pending.Count) {
        foreach ($entry in Get-ChildItem -LiteralPath ($pending.Pop()) -Force -ErrorAction Stop) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry.Name -eq '.git') { continue }
            $relative = [IO.Path]::GetRelativePath($root, $entry.FullName).Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
            if ($entry.PSIsContainer) {
                if (-not (Is-Ignored $relative $true)) { $pending.Push($entry.FullName) }
            } elseif (($IsWindows -or $entry.UnixStat.ItemType -eq 'File') -and
                ($entry.Name -ieq 'AGENTS.md' -or $entry.Name -ieq 'README.md') -and
                -not (Is-Ignored $relative)) {
                $paths.Add($relative)
            }
        }
    }
    $paths.Sort([StringComparer]::Ordinal)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('Project documentation map')
    $lines.Add('Project root: ' + (ConvertTo-Json -InputObject $root -Compress))
    $lines.Add('Before working in a directory, read the applicable AGENTS.md files from the root down')
    $lines.Add('and relevant README.md files. Nested instructions apply within their directory scope.')
    $lines.Add('Documentation paths (JSON-quoted):')
    foreach ($path in $paths) { $lines.Add((ConvertTo-Json -InputObject $path -Compress)) }
    if (-not $paths.Count) { $lines.Add('No matching documentation files found.') }
    @{
        hookSpecificOutput = @{
            hookEventName = 'SessionStart'
            additionalContext = $lines -join "`n"
        }
    } | ConvertTo-Json -Depth 3 -Compress
} catch {
    [Console]::Error.WriteLine("Project documentation map failed (map is incomplete): $_")
    exit 1
} finally {
    if ($ignoreRoot -and [IO.Directory]::Exists($ignoreRoot)) {
        Remove-Item -LiteralPath $ignoreRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
