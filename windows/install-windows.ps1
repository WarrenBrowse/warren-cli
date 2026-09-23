# Install the Warren headless daemon + CLI on Windows (x64).
#
# From an extracted bundle, in an elevated PowerShell:
#
#   Expand-Archive warren-headless-1.1.14-windows-x64.zip
#   cd warren-headless-1.1.14-windows-x64
#   .\install-windows.ps1
#
# Or straight from the distribution repo, which downloads the bundle first and
# installs it only once the release's signed SHA256SUMS vouches for it:
#
#   irm https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/windows/install-windows.ps1 | iex
#
# Checking that signature takes the OpenSSH client (ssh-keygen 8.1 or newer),
# which Windows 10 1809+ and Windows 11 carry as an optional feature. Without a
# usable one the download is refused.
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

# Proof of origin, the same contract as scripts/install.sh: SHA256SUMS comes
# from the same release as the bundle, so it is trusted only through its
# SSHSIG signature (namespace $SumsDomain) by the Warren release key pinned
# here, the Ed25519 key that also signs the desktop app's updates.
$SumsDomain = 'warren-cli-sha256sums/1'
$SigningKeySsh = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA9oS7JFrNWmhMRnzMm5K7XaoiUu8S6JpoWDuAbqJWCg'

# A known-good SSH signature by a throwaway key, used only to find out whether
# an ssh-keygen can verify at all. It must accept this and refuse the same
# signature over other bytes.
$ProbeMessage = 'probe'
$ProbeSigner = 'probe ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC9yeUi7m3qCdv8PiEIwVywU8wmhjzO9snhvVaLqqOme'
$ProbeSignature = @'
-----BEGIN SSH SIGNATURE-----
U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgL3J5SLubeoJ2/w+IQjBXLBTzCa
GPM72yeG9Vouqo6Z4AAAAFcHJvYmUAAAAAAAAABnNoYTUxMgAAAFMAAAALc3NoLWVkMjU1
MTkAAABApMou/YOQZm443mtsNwhc3KRTO0bLFqzrUNfiBrX4Jxl26TQpxOPA+XW/2MlDJ/
pyJqQynWwRZHTOSn30ZD4WDA==
-----END SSH SIGNATURE-----
'@

# Runs a native tool with its stdin fed from a file, byte for byte. A
# PowerShell pipeline would re-encode the bytes and add a line ending, and the
# signature covers the exact file.
function Invoke-NativeTool {
    param([string]$Path, [string]$Arguments, [string]$StdinPath)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Path
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { $process = [Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ ExitCode = -1; Error = "$_" } }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    try {
        if ($StdinPath) {
            $bytes = [IO.File]::ReadAllBytes($StdinPath)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        }
    }
    catch {
        # An unreadable input, or a tool that exits before reading it: the
        # exit code below is what counts.
        $null = $_
    }
    finally {
        # Always, or a tool waiting for the end of its input never exits.
        try { $process.StandardInput.Close() } catch { $null = $_ }
    }
    if (-not $process.WaitForExit(60000)) {
        try { $process.Kill() } catch { $null = $_ }
        return [pscustomobject]@{ ExitCode = -1; Error = "$Path did not finish" }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Error = $stderr.Result + $stdout.Result }
}

function Write-AsciiFile {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.Encoding]::ASCII)
}

# Every ssh-keygen this host might carry: PATH first, then the Windows
# optional feature (also through Sysnative, for a 32-bit shell on 64-bit
# Windows), the Win32-OpenSSH package and Git for Windows.
function Get-SshKeygenCandidate {
    $candidates = @(Get-Command ssh-keygen -CommandType Application -All -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Path })
    if ($env:SystemRoot) {
        $candidates += Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe'
        $candidates += Join-Path $env:SystemRoot 'Sysnative\OpenSSH\ssh-keygen.exe'
    }
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles 'OpenSSH\ssh-keygen.exe'
        $candidates += Join-Path $env:ProgramFiles 'Git\usr\bin\ssh-keygen.exe'
    }
    return @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Select-Object -Unique)
}

# True when <Path> verifies SSH signatures (OpenSSH 8.1 or newer): it accepts
# the probe signature and refuses it over other bytes, so a tool that says yes
# to everything never becomes the verifier.
function Test-SshSigVerifier {
    param([string]$Path, [string]$WorkDir)
    Write-AsciiFile (Join-Path $WorkDir 'probe.signers') "$ProbeSigner`n"
    Write-AsciiFile (Join-Path $WorkDir 'probe.sig') $ProbeSignature
    Write-AsciiFile (Join-Path $WorkDir 'probe.good') $ProbeMessage
    Write-AsciiFile (Join-Path $WorkDir 'probe.bad') "$ProbeMessage!"
    $arguments = "-Y verify -f `"$(Join-Path $WorkDir 'probe.signers')`" -I probe -n probe -s `"$(Join-Path $WorkDir 'probe.sig')`""
    $good = Invoke-NativeTool -Path $Path -Arguments $arguments -StdinPath (Join-Path $WorkDir 'probe.good')
    $bad = Invoke-NativeTool -Path $Path -Arguments $arguments -StdinPath (Join-Path $WorkDir 'probe.bad')
    return ($good.ExitCode -eq 0 -and $bad.ExitCode -ne 0)
}

# Throws unless <Dir>\SHA256SUMS carries a valid signature by the pinned key.
function Assert-SignedChecksumList {
    param([string]$Dir)
    $sums = Join-Path $Dir 'SHA256SUMS'
    $signature = Join-Path $Dir 'SHA256SUMS.sshsig'
    if (-not (Test-Path -LiteralPath $sums -PathType Leaf)) {
        throw 'The release carries no SHA256SUMS.'
    }
    if (-not (Test-Path -LiteralPath $signature -PathType Leaf)) {
        throw 'The release carries no SHA256SUMS.sshsig, so nothing proves Warren published it.'
    }
    $verifier = Get-SshKeygenCandidate | Where-Object { Test-SshSigVerifier -Path $_ -WorkDir $Dir } |
        Select-Object -First 1
    if (-not $verifier) {
        throw ('No ssh-keygen able to verify an SSH signature (OpenSSH 8.1 or newer) on this machine. ' +
            'Install the OpenSSH client: Settings > System > Optional features > OpenSSH Client, or ' +
            '"Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" from an elevated PowerShell, ' +
            'or Git for Windows; then run this again.')
    }
    $signers = Join-Path $Dir 'release.signers'
    Write-AsciiFile $signers "warren-release $SigningKeySsh`n"
    $result = Invoke-NativeTool -Path $verifier -StdinPath $sums `
        -Arguments "-Y verify -f `"$signers`" -I warren-release -n $SumsDomain -s `"$signature`""
    if ($result.ExitCode -ne 0) {
        throw "SHA256SUMS does not carry a valid signature by the Warren release key (checked with $verifier)."
    }
}

# The one lowercase sha256 the list gives for <Asset>. No entry, several, or a
# malformed one is a refusal: the signed list is the statement of what the
# release contains.
function Get-SumsEntry {
    param([string]$SumsPath, [string]$Asset)
    $hashes = @(foreach ($line in [IO.File]::ReadAllLines($SumsPath)) {
            $fields = $line.Trim() -split '\s+'
            if ($fields.Count -ge 2 -and ($fields[1] -ceq $Asset -or $fields[1] -ceq "*$Asset")) {
                $fields[0]
            }
        })
    if ($hashes.Count -ne 1 -or $hashes[0] -notmatch '^[0-9a-fA-F]{64}$') {
        throw "The signed SHA256SUMS does not list $Asset exactly once."
    }
    return $hashes[0].ToLowerInvariant()
}

# The whole proof for one downloaded file: <Dir> holds <Asset> and whatever of
# SHA256SUMS and SHA256SUMS.sshsig the release carried. Throws on any doubt.
function Assert-WarrenAsset {
    param([string]$Dir, [string]$Asset)
    Assert-SignedChecksumList -Dir $Dir
    $expected = Get-SumsEntry -SumsPath (Join-Path $Dir 'SHA256SUMS') -Asset $Asset
    $actual = (Get-FileHash -LiteralPath (Join-Path $Dir $Asset) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Checksum mismatch: $Asset is not the file the signed SHA256SUMS lists."
    }
}

# Newest tag of one series. Never the listing order and never a plain string
# sort: version tags sort lexicographically, where 1.9.1 lands after 1.11.0.
function Get-LatestTag {
    param([string]$Prefix)
    $releases = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases?per_page=100" `
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

    $base = "https://github.com/$Repo/releases/download/$tag"
    Write-Host "Downloading $asset ($tag) ..."
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $zip

    # A proof file the release does not carry stays absent, and
    # Assert-WarrenAsset names it when it refuses. Invoke-WebRequest raises
    # different exception types across PowerShell versions, so the catch
    # cannot be narrowed to one; it covers only the fetch.
    foreach ($proof in @('SHA256SUMS', 'SHA256SUMS.sshsig')) {
        try { Invoke-WebRequest -UseBasicParsing -Uri "$base/$proof" -OutFile (Join-Path $work $proof) }
        catch { Remove-Item -LiteralPath (Join-Path $work $proof) -Force -ErrorAction SilentlyContinue }
    }
    try { Assert-WarrenAsset -Dir $work -Asset $asset }
    catch { throw "Refusing to install $asset from ${tag}: $($_.Exception.Message)" }
    Write-Host 'Signature and checksum verified.'

    $bundleDir = Join-Path $work 'bundle'
    Expand-Archive -Path $zip -DestinationPath $bundleDir -Force
    $bundle = Get-ChildItem -Path $bundleDir -Directory | Select-Object -First 1
    if (-not $bundle) { throw "The archive does not contain a bundle directory." }
    return $bundle.FullName
}

# Sourced by windows/test-install-windows.ps1, which wants the functions and
# nothing else.
if ($env:WARREN_INSTALL_LIB -eq '1') { return }

Assert-Admin

if ($Uninstall) {
    Remove-WarrenInstall
    Write-Host "Warren headless uninstalled. Settings and logs under"
    Write-Host "$env:ProgramData\Warren VPN* are left in place."
    exit 0
}

# Run from inside an extracted bundle when there is one, otherwise fetch it.
# `irm | iex` leaves $PSScriptRoot empty, which is the remote-install case. A
# bundle extracted by hand is a download the operator checked themselves
# (docs/INSTALL-SERVER.md shows how); only a fetched one is verified here.
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
