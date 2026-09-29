param(
    [Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Test-ServerRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path 'server.cfg') -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $Path 'resources') -PathType Container)
}

$candidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Add-Candidate {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return }
    if (Test-ServerRoot $full) {
        [void]$candidates.Add($full.TrimEnd('\'))
    }
}

# Scan local fixed and removable filesystem drives in drive-letter order.
$drives = @(Get-CimInstance Win32_LogicalDisk |
    Where-Object { $_.DriveType -in @(2,3) -and $_.DeviceID } |
    Sort-Object DeviceID |
    ForEach-Object { $_.DeviceID + '\' })

$skipNames = @(
    'Windows','Program Files','Program Files (x86)','$Recycle.Bin',
    'System Volume Information','node_modules','.git'
)
$maxDepth = 5
$maxDirectoriesPerDrive = 7000

foreach ($drive in $drives) {
    # Quick checks first for common FiveM / txAdmin layouts on this exact drive.
    foreach ($relative in @(
        '', 'txData', 'FXServer', 'FiveM', 'fivem', 'servers', 'server',
        'testserver', 'testserver\file', 'server-data', 'serverdata'
    )) {
        if ($relative) { Add-Candidate (Join-Path $drive $relative) }
        else { Add-Candidate $drive }
    }

    # Then breadth-first scan this drive with its own independent budget.
    $visited = 0
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([PSCustomObject]@{ Path = $drive; Depth = 0 })

    while ($queue.Count -gt 0 -and $visited -lt $maxDirectoriesPerDrive) {
        $node = $queue.Dequeue()
        $visited++

        if (Test-ServerRoot $node.Path) {
            Add-Candidate $node.Path
        }

        if ($node.Depth -ge $maxDepth) { continue }

        foreach ($dir in @(Get-ChildItem -LiteralPath $node.Path -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($skipNames -contains $dir.Name) { continue }
            if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $queue.Enqueue([PSCustomObject]@{ Path = $dir.FullName; Depth = ($node.Depth + 1) })
        }
    }
}

# Also check common user-profile locations in case a server is stored there.
foreach ($base in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)) {
    if (-not $base) { continue }
    foreach ($name in @('txData','FXServer','FiveM','fivem','servers','server','testserver','server-data','serverdata')) {
        Add-Candidate (Join-Path $base $name)
    }
}

# Prefer an existing v-phone install, then a txAdmin/server-style path, then the shortest valid path.
$best = @($candidates) |
    Sort-Object -Property @(
        @{ Expression = {
                $vp = Get-ChildItem -LiteralPath (Join-Path $_ 'resources') -Directory -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq 'v-phone' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'fxmanifest.lua')) } |
                    Select-Object -First 1
                if ($vp) { 0 } else { 1 }
            }; Ascending = $true },
        @{ Expression = { if ($_ -match '(?i)txData|server-data|serverdata|testserver|FXServer') { 0 } else { 1 } }; Ascending = $true },
        @{ Expression = { $_.Length }; Ascending = $true }
    ) |
    Select-Object -First 1

if ($best) {
    [System.IO.File]::WriteAllText($OutputPath, [string]$best, [System.Text.UTF8Encoding]::new($false))
    exit 0
}

[System.IO.File]::WriteAllText($OutputPath, '', [System.Text.UTF8Encoding]::new($false))
exit 2
