# Unit tests for the proof-of-origin checks of windows/install-windows.ps1.
#
# The installer runs elevated and registers a SYSTEM service, and SHA256SUMS
# comes from the same release as the bundle, so only the signature over that
# list separates "GitHub served these files" from "Warren published them".
# Every way it can be missing, wrong or unverifiable must stop the install.
#
#   powershell -NoProfile -File windows/test-install-windows.ps1   (Windows PowerShell 5.1)
#   pwsh -NoProfile -File windows/test-install-windows.ps1         (PowerShell 7, any OS)
#
# Plain assertions rather than Pester: the Pester that ships with Windows (3.4)
# and the current one (5.x) accept different syntax, and this has to run on
# both a stock Windows and CI. It needs an ssh-keygen from OpenSSH 8.1 or newer.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:WARREN_INSTALL_LIB = '1'
. (Join-Path $PSScriptRoot 'install-windows.ps1')

$script:checks = 0
$script:failures = 0

function Test-Success {
    param([string]$Description, [scriptblock]$Action)
    $script:checks++
    try {
        & $Action
        Write-Host "  ok   $Description"
    }
    catch {
        $script:failures++
        Write-Host "  FAIL $Description`n       $($_.Exception.Message)"
    }
}

function Test-Refusal {
    param([string]$Description, [scriptblock]$Action, [string]$Reason)
    $script:checks++
    try {
        & $Action
        $script:failures++
        Write-Host "  FAIL $Description (it succeeded)"
    }
    catch {
        $message = $_.Exception.Message
        if ($message.Contains($Reason)) {
            Write-Host "  ok   $Description"
        }
        else {
            $script:failures++
            Write-Host "  FAIL $Description`n       expected a refusal containing: $Reason`n       actual: $message"
        }
    }
}

function Test-Equal {
    param([string]$Description, [string]$Expected, [string]$Actual)
    $script:checks++
    if ($Expected -ceq $Actual) {
        Write-Host "  ok   $Description"
    }
    else {
        $script:failures++
        Write-Host "  FAIL $Description`n       expected: $Expected`n       actual:   $Actual"
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('warren-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

try {
    Write-Host 'the pinned key'
    # Its one canonical form is the hex line of warren-app's
    # mullvad-update/warren-trusted-metadata-signing-pubkeys, which
    # scripts/test-install.sh checks the Unix pins against too.
    $releaseKeyHex = '0f684bb245acd5a684c467ccc9b92bb5daa2252ef12e89a68583b806ea2560a0'
    $blob = [Convert]::FromBase64String(($SigningKeySsh -split ' ')[1])
    $raw = -join ($blob[($blob.Length - 32)..($blob.Length - 1)] | ForEach-Object { $_.ToString('x2') })
    Test-Equal 'the SSH pin is the Warren release key' $releaseKeyHex $raw
    Test-Equal 'named as an ed25519 key' 'ssh-ed25519' ($SigningKeySsh -split ' ')[0]
    Test-Equal 'signatures are bound to the checksum list of a warren-cli release' `
        'warren-cli-sha256sums/1' $SumsDomain

    $keygen = Get-SshKeygenCandidate | Where-Object { Test-SshSigVerifier -Path $_ -WorkDir $root } |
        Select-Object -First 1
    if (-not $keygen) {
        # Say what each candidate answered, so a runner without a usable one
        # can be told apart from a probe that misreads a good one.
        foreach ($candidate in Get-SshKeygenCandidate) {
            $answer = Invoke-NativeTool -Path $candidate -StdinPath (Join-Path $root 'probe.good') `
                -Arguments "-Y verify -f `"$(Join-Path $root 'probe.signers')`" -I probe -n probe -s `"$(Join-Path $root 'probe.sig')`""
            Write-Host "  $candidate -> $($answer.ExitCode): $($answer.Error)"
        }
        throw 'these tests need an ssh-keygen from OpenSSH 8.1 or newer'
    }

    function New-Key {
        param([string]$Name)
        $path = Join-Path $root $Name
        $result = Invoke-NativeTool -Path $keygen -Arguments "-q -t ed25519 -N `"`" -C $Name -f `"$path`""
        if ($result.ExitCode -ne 0) { throw "ssh-keygen could not make a key: $($result.Error)" }
        return $path
    }

    function Invoke-Sign {
        param([string]$Key, [string]$File, [string]$Out, [string]$Namespace = $SumsDomain)
        $copy = Join-Path $root 'to-sign'
        Copy-Item -LiteralPath $File -Destination $copy -Force
        Remove-Item -LiteralPath "$copy.sig" -Force -ErrorAction SilentlyContinue
        $result = Invoke-NativeTool -Path $keygen -Arguments "-q -Y sign -f `"$Key`" -n $Namespace `"$copy`""
        if ($result.ExitCode -ne 0) { throw "ssh-keygen could not sign: $($result.Error)" }
        Move-Item -LiteralPath "$copy.sig" -Destination $Out -Force
    }

    function Get-Sha256 {
        param([string]$Path)
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    function Set-Pin {
        param([string]$Key)
        $fields = ([IO.File]::ReadAllText("$Key.pub").Trim() -split ' ')
        $script:SigningKeySsh = "$($fields[0]) $($fields[1])"
    }

    $key = New-Key 'release.key'
    $otherKey = New-Key 'other.key'
    $asset = 'warren-headless-beta-1.2.3-windows-x64.zip'
    $release = Join-Path $root 'release'

    # A release as the pipeline publishes it, rebuilt for every case so a case
    # can break it without leaking into the next one.
    function New-Release {
        if (Test-Path -LiteralPath $release) { Remove-Item -LiteralPath $release -Recurse -Force }
        New-Item -ItemType Directory -Path $release | Out-Null
        Write-AsciiFile (Join-Path $release $asset) "the bundle`n"
        Write-AsciiFile (Join-Path $release 'warren-headless-beta-1.2.3-macos-universal.tar.gz') "another platform`n"
        Write-AsciiFile (Join-Path $release 'SHA256SUMS') (
            "$(Get-Sha256 (Join-Path $release $asset))  $asset`n" +
            "$(Get-Sha256 (Join-Path $release 'warren-headless-beta-1.2.3-macos-universal.tar.gz'))  warren-headless-beta-1.2.3-macos-universal.tar.gz`n")
        Update-ReleaseSignature
    }

    function Update-ReleaseSignature {
        Invoke-Sign -Key $key -File (Join-Path $release 'SHA256SUMS') -Out (Join-Path $release 'SHA256SUMS.sshsig')
    }

    Set-Pin $key

    Write-Host 'proof of origin'
    New-Release
    Test-Success 'a release signed by the pinned key is accepted' { Assert-WarrenAsset -Dir $release -Asset $asset }

    New-Release
    Write-AsciiFile (Join-Path $release $asset) "a bundle from somewhere else`n"
    $sums = Join-Path $release 'SHA256SUMS'
    $rewritten = [IO.File]::ReadAllText($sums) -replace '(?m)^[0-9a-f]{64}(?=  warren-headless-beta-1\.2\.3-windows-x64\.zip)', (Get-Sha256 (Join-Path $release $asset))
    Write-AsciiFile $sums $rewritten
    Test-Refusal 'a checksum list rewritten to match another bundle is refused' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } 'does not carry a valid signature by the Warren release key'

    New-Release
    Remove-Item -LiteralPath (Join-Path $release 'SHA256SUMS.sshsig')
    Test-Refusal 'a release without its signature is refused' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } 'no SHA256SUMS.sshsig'

    New-Release
    Remove-Item -LiteralPath (Join-Path $release 'SHA256SUMS')
    Test-Refusal 'a release without SHA256SUMS is refused' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } 'no SHA256SUMS.'

    New-Release
    $sums = Join-Path $release 'SHA256SUMS'
    Write-AsciiFile $sums ((Get-Content -LiteralPath $sums | Where-Object { $_ -notlike "*$asset" }) -join "`n")
    Update-ReleaseSignature
    Test-Refusal 'a bundle the signed list does not name is refused' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } "does not list $asset exactly once"

    New-Release
    $sums = Join-Path $release 'SHA256SUMS'
    Write-AsciiFile $sums ([IO.File]::ReadAllText($sums) + "$(Get-Sha256 $sums)  $asset`n")
    Update-ReleaseSignature
    Test-Refusal 'and so is one it names twice' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } "does not list $asset exactly once"

    New-Release
    Write-AsciiFile (Join-Path $release $asset) 'truncated'
    Test-Refusal 'a bundle that does not match its signed checksum is refused' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } 'Checksum mismatch'

    New-Release
    Set-Pin $otherKey
    Test-Refusal 'a release signed by another key is refused' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } 'does not carry a valid signature by the Warren release key'
    Set-Pin $key

    New-Release
    Invoke-Sign -Key $key -File (Join-Path $release 'SHA256SUMS') -Out (Join-Path $release 'SHA256SUMS.sshsig') -Namespace 'file'
    Test-Refusal 'the right key signing for another purpose is not a release signature' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } 'does not carry a valid signature by the Warren release key'

    # What this host offers is the one system boundary replaced here.
    $realCandidates = ${function:Get-SshKeygenCandidate}
    New-Release
    ${function:Get-SshKeygenCandidate} = { @() }
    Test-Refusal 'a machine without ssh-keygen refuses to install' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } '(OpenSSH 8.1 or newer) on this machine'

    # A tool that does everything right except refuse a bad signature: a
    # verifier must prove it can say no.
    if ($env:OS -eq 'Windows_NT') {
        $yes = Join-Path $root 'yes.cmd'
        Write-AsciiFile $yes "@exit /b 0`r`n"
    }
    else {
        $yes = Join-Path $root 'yes'
        Write-AsciiFile $yes "#!/bin/sh`nexit 0`n"
        & chmod +x $yes
    }
    ${function:Get-SshKeygenCandidate} = [scriptblock]::Create("@('$yes')")
    Write-AsciiFile (Join-Path $release $asset) 'tampered'
    Test-Refusal 'a tool that accepts any signature is not a verifier' `
    { Assert-WarrenAsset -Dir $release -Asset $asset } '(OpenSSH 8.1 or newer) on this machine'
    ${function:Get-SshKeygenCandidate} = $realCandidates
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WARREN_INSTALL_LIB -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "$script:checks checks, $script:failures failure(s)"
if ($script:failures -ne 0) { exit 1 }
