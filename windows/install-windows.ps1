# Install the Warren headless daemon + CLI on Windows (x64).
#
# From an extracted bundle, in an elevated PowerShell:
#
#   Expand-Archive warren-headless-1.1.14-windows-x64.zip
#   cd warren-headless-1.1.14-windows-x64
#   .\install-windows.ps1
#
# Or straight from the distribution repo, which downloads the bundle first:
#
#   irm https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/windows/install-windows.ps1 | iex
#
# With arguments, through the same one-liner:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/windows/install-windows.ps1))) -Uninstall
#
# Windows on ARM runs these x64 binaries under emulation: Warren ships x64
# only, and the WFP and wintun pieces the daemon drives are user-mode.

param(
    [switch]$Uninstall,
    # prod or beta. Beta is the default because it is the only channel that
    # exists: the whole live Warren stack is the beta one, and the production
    # API host answers 410 until the production stack opens.
    [ValidateSet('prod', 'beta')]
    [string]$Channel = 'beta',
    # Pin a version instead of taking the newest of the channel.
    [string]$Version = '',
    [string]$Repo = 'WarrenBrowse/warren-cli'
)

$ErrorActionPreference = 'Stop'

$InstallDir = "$env:ProgramFiles\Warren"

# The daemon registers itself under the service name compiled into it, one per
# product environment (warren_product_env::windows_service_name). Registering
# it by hand under another name is how you get a service the daemon itself
# cannot find, and an orphaned kill switch nothing answers for.
$ServiceNames = @{ prod = 'WarrenVPN'; beta = 'WarrenVPNBeta'; staging = 'WarrenVPNStaging' }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw "Run this script from an elevated (Administrator) PowerShell."
    }
}

# The environment a bundle was compiled for, which decides the service name.
function Get-BundleEnvironment {
    param([string]$BundleDir)
    $info = Join-Path $BundleDir 'BUNDLE-INFO'
    if (Test-Path $info) {
        $line = Select-String -Path $info -Pattern '^product_env=(.+)$' | Select-Object -First 1
        if ($line) { return $line.Matches[0].Groups[1].Value.Trim() }
    }
    return $Channel
}

function Remove-WarrenInstall {
    foreach ($name in $ServiceNames.Values) {
        $svc = Get-Service $name -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service $name -Force -ErrorAction SilentlyContinue
            sc.exe delete $name | Out-Null
        }
    }
    # The pre-1.1.14 installer registered its own service under this name.
    $legacy = Get-Service 'warren-daemon' -ErrorAction SilentlyContinue
    if ($legacy) {
        Stop-Service 'warren-daemon' -Force -ErrorAction SilentlyContinue
        sc.exe delete 'warren-daemon' | Out-Null
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($machinePath) {
        $kept = ($machinePath -split ';' | Where-Object { $_ -and $_ -ne $InstallDir -and $_ -ne "$InstallDir\bin" }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $kept, "Machine")
    }
    [Environment]::SetEnvironmentVariable("WARREN_RESOURCE_DIR", $null, "Machine")
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
}

# Newest tag of one series. Never the listing order and never a plain string
# sort: version tags sort lexicographically, where 1.9.1 lands after 1.11.0.
function Get-LatestTag {
    param([string]$Prefix)
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=100" `
        -Headers @{ 'User-Agent' = 'warren-cli-installer' }
    $tags = $releases.tag_name | Where-Object { $_ -match "^$([regex]::Escape($Prefix))\d+(\.\d+)*$" }
    $newest = $tags |
        Sort-Object -Property @{ Expression = { [version]($_ -replace "^$Prefix", '') } } |
        Select-Object -Last 1
    return $newest
}

function Get-WarrenBundle {
    $prefix = if ($Channel -eq 'prod') { 'daemon-v' } else { 'daemon-beta-v' }
    $envTag = if ($Channel -eq 'prod') { '' } else { '-beta' }

    if ($Version) {
        $tag = "$prefix$($Version -replace '^v', '')"
    }
    else {
        Write-Host "Resolving the latest $Channel headless release ..."
        $tag = Get-LatestTag -Prefix $prefix
    }
    if (-not $tag) { throw "No published $Channel headless release found on $Repo." }

    $ver = $tag -replace "^$prefix", ''
    $asset = "warren-headless$envTag-$ver-windows-x64.zip"
    $work = Join-Path ([IO.Path]::GetTempPath()) ("warren-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $zip = Join-Path $work $asset

    Write-Host "Downloading $asset ($tag) ..."
    Invoke-WebRequest -Uri "https://github.com/$Repo/releases/download/$tag/$asset" -OutFile $zip

    # Catches a truncated download, which otherwise expands into a bundle
    # missing whichever file the transfer stopped on.
    # A missing SHA256SUMS is a warning, a mismatching one is fatal. The catch
    # covers only the fetch, so a real mismatch below is never swallowed by it:
    # Invoke-WebRequest raises different exception types across PowerShell
    # versions, so it cannot be narrowed to one.
    $sums = Join-Path $work 'SHA256SUMS'
    $haveSums = $true
    try {
        Invoke-WebRequest -Uri "https://github.com/$Repo/releases/download/$tag/SHA256SUMS" -OutFile $sums
    }
    catch {
        $haveSums = $false
        Write-Warning "No SHA256SUMS in $tag; skipping the checksum check."
    }
    if ($haveSums) {
        $line = Select-String -Path $sums -Pattern ([regex]::Escape($asset)) | Select-Object -First 1
        if ($line) {
            $expected = ($line.Line -split '\s+')[0]
            $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $expected.ToLower()) {
                throw "Checksum mismatch for $asset (expected $expected, got $actual)."
            }
            Write-Host "Checksum verified."
        }
        else {
            Write-Warning "$asset is not listed in SHA256SUMS; skipping the checksum check."
        }
    }

    Expand-Archive -Path $zip -DestinationPath $work -Force
    $bundle = Get-ChildItem -Path $work -Directory | Select-Object -First 1
    if (-not $bundle) { throw "The archive does not contain a bundle directory." }
    return $bundle.FullName
}

Assert-Admin

if ($Uninstall) {
    Remove-WarrenInstall
    Write-Host "Warren headless uninstalled. Settings and logs under"
    Write-Host "$env:ProgramData\Warren VPN* are left in place."
    exit 0
}

# Run from inside an extracted bundle when there is one, otherwise fetch it.
# `irm | iex` leaves $PSScriptRoot empty, which is the remote-install case.
$src = $PSScriptRoot
if (-not $src -or -not (Test-Path (Join-Path $src 'warren-daemon.exe'))) {
    $src = Get-WarrenBundle
}

$bundleEnv = Get-BundleEnvironment -BundleDir $src
$serviceName = $ServiceNames[$bundleEnv]
if (-not $serviceName) { throw "Unknown product environment in the bundle: $bundleEnv" }

if (Test-Path (Join-Path $src 'BUNDLE-INFO')) {
    Get-Content (Join-Path $src 'BUNDLE-INFO') | Write-Host
}

# Replacing the binaries under a live daemon leaves a process whose firewall
# state no longer matches anything on disk.
Remove-WarrenInstall

Write-Host "Installing to $InstallDir ..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
# One flat directory, the way the GUI installs: winfw.dll is a link-time
# import the loader resolves next to warren-daemon.exe, while wintun.dll and
# the split-tunnel driver are opened from the resource directory. Splitting
# them across two directories means one of the two is always wrong.
Copy-Item "$src\*" $InstallDir -Recurse -Force -Exclude 'install-windows.ps1'

foreach ($required in @('warren.exe', 'warren-daemon.exe', 'winfw.dll', 'wintun.dll')) {
    if (-not (Test-Path (Join-Path $InstallDir $required))) {
        throw "$required is missing from the bundle; refusing to register a daemon that cannot run."
    }
}

$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($machinePath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$InstallDir", "Machine")
}
[Environment]::SetEnvironmentVariable("WARREN_RESOURCE_DIR", $InstallDir, "Machine")
$env:WARREN_RESOURCE_DIR = $InstallDir

# The daemon registers itself: it knows its own service name, the launch
# arguments the SCM has to use (--run-as-service), the BFE and NSI
# dependencies the firewall and the tunnel need, the restart-forever failure
# actions, and the unrestricted service SID WireGuard requires. None of that
# survives a hand-rolled `sc.exe create`.
Write-Host "Registering the $serviceName service ..."
& "$InstallDir\warren-daemon.exe" --register-service
if ($LASTEXITCODE -ne 0) { throw "warren-daemon.exe --register-service failed ($LASTEXITCODE)." }

Start-Service $serviceName
Write-Host "Done. Open a new terminal and try:  warren account create; warren status"
