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

function Add-Candidate {
    param([System.Collections.Generic.List[string]]$List,[string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return }
    if ((Test-ServerRoot $full) -and -not $List.Contains($full)) {
        $List.Add($full)
    }
}

$candidates = [System.Collections.Generic.List[string]]::new()

# Fast checks for common FiveM / txAdmin layouts.
$common = @(
    'C:\\txData', 'C:\\FXServer', 'C:\\FiveM', 'C:\\fivem', 'C:\\servers', 'C:\\server',
    'D:\\txData', 'D:\\FXServer', 'D:\\FiveM', 'D:\\fivem', 'D:\\servers', 'D:\\server',
    'E:\\txData', 'E:\\FXServer', 'E:\\FiveM', 'E:\\fivem', 'E:\\servers', 'E:\\server', 'E:\\testserver', 'E:\\testserver\\file'
)
foreach ($path in $common) { Add-Candidate $candidates $path }

foreach ($base in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)) {
    if (-not $base) { continue }
    foreach ($name in @('txData','FXServer','FiveM','fivem','servers','server','testserver')) {
        Add-Candidate $candidates (Join-Path $base $name)
    }
}

# Breadth-first scan of fixed drives, deliberately depth-limited to stay fast.
$skipNames = @('Windows','Program Files','Program Files (x86)','$Recycle.Bin','System Volume Information','node_modules','.git')
$maxDepth = 5
$maxDirectories = 7000
$visited = 0

$drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object { $_.DeviceID + '\\' }
foreach ($drive in $drives) {
    if ($candidates.Count -gt 0) { break }

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([PSCustomObject]@{ Path = $drive; Depth = 0 })

    while ($queue.Count -gt 0 -and $visited -lt $maxDirectories -and $candidates.Count -eq 0) {
        $node = $queue.Dequeue()
        $visited++

        if (Test-ServerRoot $node.Path) {
            Add-Candidate $candidates $node.Path
            break
        }

        if ($node.Depth -ge $maxDepth) { continue }

        foreach ($dir in @(Get-ChildItem -LiteralPath $node.Path -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($skipNames -contains $dir.Name) { continue }
            if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $queue.Enqueue([PSCustomObject]@{ Path = $dir.FullName; Depth = ($node.Depth + 1) })
        }
    }
}

# Prefer a server already containing v-phone, then txData-style paths, then the shortest valid path.
$best = $candidates |
    Sort-Object -Property @(
        @{ Expression = { if (Test-Path -LiteralPath (Join-Path $_ 'resources') -PathType Container) {
                $vp = Get-ChildItem -LiteralPath (Join-Path $_ 'resources') -Directory -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq 'v-phone' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'fxmanifest.lua')) } |
                    Select-Object -First 1
                if ($vp) { 0 } else { 1 }
            } else { 1 } }; Ascending = $true },
        @{ Expression = { if ($_ -match '(?i)txData|server-data|testserver') { 0 } else { 1 } }; Ascending = $true },
        @{ Expression = { $_.Length }; Ascending = $true }
    ) |
    Select-Object -First 1

if ($best) {
    [System.IO.File]::WriteAllText($OutputPath, [string]$best, [System.Text.UTF8Encoding]::new($false))
    exit 0
}

[System.IO.File]::WriteAllText($OutputPath, '', [System.Text.UTF8Encoding]::new($false))
exit 2
