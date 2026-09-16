# Run with PowerShell 7 and Codex CLI; the caller supplies an isolated CODEX_HOME.
$ErrorActionPreference = 'Stop'
function Assert($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
Assert (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) 'Set an isolated CODEX_HOME before running this test'
[void][IO.Directory]::CreateDirectory($env:CODEX_HOME)
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$marketplace = Get-Content -Raw (Join-Path $repo '.agents/plugins/marketplace.json') | ConvertFrom-Json
$pluginId = $marketplace.plugins[0].name + '@' + $marketplace.name
$added = & codex plugin marketplace add $repo --json
Assert ($LASTEXITCODE -eq 0) 'Marketplace registration failed'
Assert (($added | ConvertFrom-Json).marketplaceName -ceq $marketplace.name) 'Wrong marketplace registered'
$installed = & codex plugin add $pluginId --json
Assert ($LASTEXITCODE -eq 0) 'Plugin installation failed'
$installation = $installed | ConvertFrom-Json
Assert ($installation.pluginId -ceq $pluginId) 'Wrong plugin installed'
foreach ($path in @('.codex-plugin/plugin.json', 'hooks/hooks.json', 'scripts/project_map.sh', 'scripts/project_map.ps1')) {
    Assert (Test-Path -LiteralPath (Join-Path $installation.installedPath $path) -PathType Leaf) "Installed file missing: $path"
}
$sessionHook = (Get-Content -Raw (Join-Path $installation.installedPath 'hooks/hooks.json') | ConvertFrom-Json).hooks.SessionStart[0]
Assert ($sessionHook.matcher -ceq '^(startup|resume|clear|compact)$') 'Installed hook must cover startup, resume, clear, and compact'
Assert ($sessionHook.hooks[0].type -ceq 'command') 'Installed hook must use a command'
Assert ($sessionHook.hooks[0].command -ceq 'bash "${PLUGIN_ROOT}/scripts/project_map.sh"') 'Wrong installed Bash command'
Assert ($sessionHook.hooks[0].commandWindows -ceq 'pwsh -NoLogo -NoProfile -File "${PLUGIN_ROOT}/scripts/project_map.ps1"') 'Wrong installed PowerShell command'
$listed = & codex plugin list --json
Assert ($LASTEXITCODE -eq 0) 'Plugin listing failed'
$entry = @(($listed | ConvertFrom-Json).installed | Where-Object { $_.pluginId -ceq $pluginId })
Assert ($entry.Count -eq 1 -and $entry[0].installed -and $entry[0].enabled) 'Plugin must be installed and enabled'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('project-map-install-test-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($fixture)
& git -C $fixture init -q
Assert ($LASTEXITCODE -eq 0) 'Fixture git init failed'
[IO.File]::WriteAllText((Join-Path $fixture 'README.md'), 'Installation fixture')
$event = @{ cwd = $fixture; source = 'startup'; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress
$output = $event | & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File (Join-Path $installation.installedPath 'scripts/project_map.ps1')
Assert ($LASTEXITCODE -eq 0) 'Installed hook failed'
$hook = ($output | ConvertFrom-Json).hookSpecificOutput
Assert ($hook.hookEventName -ceq 'SessionStart') 'Wrong hook event'
Assert (($hook.additionalContext -split "`n") -ccontains '"README.md"') 'Installed hook must map README.md'
Write-Output "Plugin installation test passed; fixture retained at $fixture"
