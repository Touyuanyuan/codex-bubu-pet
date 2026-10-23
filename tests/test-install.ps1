#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('Bubu installer tests 空格 ' + [guid]::NewGuid().ToString('N'))
$savedCodexHome = $env:CODEX_HOME
$savedUserProfile = $env:USERPROFILE
$passed = 0
$originalPetFiles = @()
if (-not [string]::IsNullOrWhiteSpace($savedCodexHome)) {
    $originalHome = $savedCodexHome
}
elseif (-not [string]::IsNullOrWhiteSpace($savedUserProfile)) {
    $originalHome = Join-Path $savedUserProfile '.codex'
}
else {
    $originalHome = $null
}
if ($null -ne $originalHome) {
    foreach ($name in @('pet.json', 'spritesheet.webp')) {
        $originalFile = Join-Path $originalHome ('pets\bubu-camera\' + $name)
        if (Test-Path -LiteralPath $originalFile -PathType Leaf) {
            $originalPetFiles += [pscustomobject] @{
                Path = $originalFile
                Hash = (Get-FileHash -LiteralPath $originalFile -Algorithm SHA256).Hash
                WriteTicks = (Get-Item -LiteralPath $originalFile).LastWriteTimeUtc.Ticks
            }
        }
    }
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-InTestRoot {
    param([string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $prefix = [System.IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
    Assert-True ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) "Unsafe test path: $full"
}

function New-TestPackage {
    param([string] $Name)
    $package = Join-Path $testRoot $Name
    Assert-InTestRoot $package
    [void] [System.IO.Directory]::CreateDirectory((Join-Path $package 'pet'))
    Copy-Item -LiteralPath (Join-Path $projectRoot 'install.ps1') -Destination $package
    Copy-Item -LiteralPath (Join-Path $projectRoot 'install.cmd') -Destination $package
    Copy-Item -LiteralPath (Join-Path $projectRoot 'pet\pet.json') -Destination (Join-Path $package 'pet')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'pet\spritesheet.webp') -Destination (Join-Path $package 'pet')
    return $package
}

function Invoke-TestInstaller {
    param([string] $Package, [string] $ExplicitHome, [string] $ExpectedHome)
    # Every call checks its destination is isolated. Never invoke against the real profile.
    Assert-InTestRoot $ExpectedHome
    if (-not [string]::IsNullOrEmpty($ExplicitHome)) {
        Assert-InTestRoot $ExplicitHome
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        Assert-InTestRoot $env:CODEX_HOME
    }
    else {
        Assert-InTestRoot $env:USERPROFILE
    }
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Package 'install.ps1'))
    if (-not [string]::IsNullOrEmpty($ExplicitHome)) {
        $arguments += @('-CodexHome', $ExplicitHome)
    }
    # Windows PowerShell turns redirected native stderr into ErrorRecord objects.
    # Continue here so failure cases can assert the process exit code explicitly.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $PowerShellExe @arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject] @{ Code = $code; Output = ($output | Out-String) }
}

function Assert-Exit {
    param($Result, [int] $Expected, [string] $Case)
    Assert-True ($Result.Code -eq $Expected) "$Case expected exit $Expected, received $($Result.Code): $($Result.Output)"
}

function Pass {
    param([string] $Message)
    $script:passed++
    Write-Host "PASS: $Message"
}

try {
    Assert-True (Test-Path -LiteralPath $PowerShellExe -PathType Leaf) "PowerShell executable missing: $PowerShellExe"
    [void] [System.IO.Directory]::CreateDirectory($testRoot)
    Write-Host "Test shell: $PowerShellExe"
    Write-Host "Isolated fixture directory: $testRoot"
    $package = New-TestPackage 'release 中文 with spaces'
    $fixtureHome = Join-Path $testRoot 'explicit home 测试'
    $env:CODEX_HOME = Join-Path $testRoot 'environment home should not be used'
    $env:USERPROFILE = Join-Path $testRoot 'fake user 用户'
    $target = Join-Path $fixtureHome 'pets\bubu-camera'

    $result = Invoke-TestInstaller $package $fixtureHome $fixtureHome
    Assert-Exit $result 0 'First install'
    foreach ($name in @('pet.json', 'spritesheet.webp')) {
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $package ('pet\' + $name)) -Algorithm SHA256).Hash
        $installedHash = (Get-FileHash -LiteralPath (Join-Path $target $name) -Algorithm SHA256).Hash
        Assert-True ($sourceHash -eq $installedHash) "Installed $name must match the source."
    }
    Assert-True (-not (Test-Path -LiteralPath $env:CODEX_HOME)) 'Explicit -CodexHome must win over CODEX_HOME.'
    Pass 'First install and explicit path priority; spaces and Chinese in package and target paths.'

    $manifestPath = Join-Path $target 'pet.json'
    $beforeTime = (Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc.Ticks
    $result = Invoke-TestInstaller $package $fixtureHome $fixtureHome
    Assert-Exit $result 0 'Repeat install'
    Assert-True ($result.Output -match 'already installed') 'Repeat install should report a no-op.'
    Assert-True ((Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc.Ticks -eq $beforeTime) 'No-op must not rewrite installed files.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $fixtureHome 'pets') -Force).Count -eq 1) 'No temporary installation directory may remain.'
    Pass 'Repeat installation is a no-op and leaves no staging directory.'

    [System.IO.File]::AppendAllText($manifestPath, "`r`n ")
    $sentinelPath = Join-Path $target 'my-original-notes.txt'
    [System.IO.File]::WriteAllText($sentinelPath, 'preserve me')
    $beforeConflictHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $result = Invoke-TestInstaller $package $fixtureHome $fixtureHome
    Assert-Exit $result 2 'Conflict'
    Assert-True ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $beforeConflictHash) 'Conflicting manifest must be preserved.'
    Assert-True ([System.IO.File]::ReadAllText($sentinelPath) -eq 'preserve me') 'Unknown user files must be preserved.'
    Pass 'Conflicting existing installation exits 2 without overwriting any user files.'

    $missingPackage = New-TestPackage 'missing input'
    Remove-Item -LiteralPath (Join-Path $missingPackage 'pet\spritesheet.webp')
    $missingHome = Join-Path $testRoot 'missing input home'
    $result = Invoke-TestInstaller $missingPackage $missingHome $missingHome
    Assert-Exit $result 1 'Missing sprite'
    Assert-True (-not (Test-Path -LiteralPath $missingHome)) 'Missing input must not create the installation directory.'
    Pass 'Missing input fails before writing the destination.'

    $corruptPackage = New-TestPackage 'corrupt image'
    [System.IO.File]::WriteAllBytes((Join-Path $corruptPackage 'pet\spritesheet.webp'), [byte[]] @(1, 2, 3, 4))
    $corruptHome = Join-Path $testRoot 'corrupt input home'
    $result = Invoke-TestInstaller $corruptPackage $corruptHome $corruptHome
    Assert-Exit $result 1 'Corrupt sprite'
    Assert-True ($result.Output -match 'SHA-256') 'Corrupt image should be rejected by integrity check.'
    Assert-True (-not (Test-Path -LiteralPath $corruptHome)) 'Corrupt input must not create the installation directory.'
    Pass 'Corrupt sprite fails SHA-256 validation before installation.'

    $badManifestPackage = New-TestPackage 'bad manifest'
    $badManifestPath = Join-Path $badManifestPackage 'pet\pet.json'
    $badManifest = Get-Content -LiteralPath $badManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $badManifest.spritesheetPath = '..\outside.webp'
    [System.IO.File]::WriteAllText($badManifestPath, ($badManifest | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    $badManifestHome = Join-Path $testRoot 'invalid manifest home'
    $result = Invoke-TestInstaller $badManifestPackage $badManifestHome $badManifestHome
    Assert-Exit $result 1 'Invalid manifest path'
    Assert-True (-not (Test-Path -LiteralPath $badManifestHome)) 'Manifest path traversal must be rejected before writing.'
    Pass 'Manifest with a different sprite path is rejected.'

    $invalidJsonPackage = New-TestPackage 'invalid json'
    [System.IO.File]::WriteAllText((Join-Path $invalidJsonPackage 'pet\pet.json'), '{ not json')
    $invalidJsonHome = Join-Path $testRoot 'invalid json home'
    $result = Invoke-TestInstaller $invalidJsonPackage $invalidJsonHome $invalidJsonHome
    Assert-Exit $result 1 'Malformed JSON'
    Assert-True (-not (Test-Path -LiteralPath $invalidJsonHome)) 'Malformed manifest must not create the destination.'
    Pass 'Malformed JSON is rejected.'

    $envHome = Join-Path $testRoot 'CODEX_HOME environment 中文'
    $env:CODEX_HOME = $envHome
    $result = Invoke-TestInstaller $package '' $envHome
    Assert-Exit $result 0 'Environment path'
    Assert-True (Test-Path -LiteralPath (Join-Path $envHome 'pets\bubu-camera\pet.json')) 'CODEX_HOME must be used when no explicit override is supplied.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex\pets\bubu-camera'))) 'CODEX_HOME must win over USERPROFILE.'
    Pass 'CODEX_HOME environment variable is respected.'

    $env:CODEX_HOME = $null
    $fallbackHome = Join-Path $env:USERPROFILE '.codex'
    $result = Invoke-TestInstaller $package '' $fallbackHome
    Assert-Exit $result 0 'Default profile path'
    Assert-True (Test-Path -LiteralPath (Join-Path $fallbackHome 'pets\bubu-camera\pet.json')) 'USERPROFILE\.codex must be the final fallback.'
    Pass 'USERPROFILE\.codex fallback is used in an isolated fake profile.'

    $junctionHome = Join-Path $testRoot 'junction destination'
    $junctionPets = Join-Path $junctionHome 'pets'
    $junctionDestination = Join-Path $testRoot 'junction would redirect here'
    Assert-InTestRoot $junctionPets
    Assert-InTestRoot $junctionDestination
    [void] [System.IO.Directory]::CreateDirectory($junctionPets)
    [void] [System.IO.Directory]::CreateDirectory($junctionDestination)
    $null = New-Item -ItemType Junction -Path (Join-Path $junctionPets 'bubu-camera') -Target $junctionDestination
    $result = Invoke-TestInstaller $package $junctionHome $junctionHome
    Assert-Exit $result 1 'Junction destination'
    Assert-True ($result.Output -match 'junction') 'Junction destination should explain its refusal.'
    Assert-True (@(Get-ChildItem -LiteralPath $junctionDestination -Force).Count -eq 0) 'Installer must not write through a junction.'
    Pass 'Junction destination is rejected without writing through it.'

    $cmdHome = Join-Path $testRoot 'double click launcher 中文'
    Assert-InTestRoot $cmdHome
    foreach ($expectedCode in @(0, 2)) {
        if ($expectedCode -eq 2) {
            [System.IO.File]::AppendAllText((Join-Path $cmdHome 'pets\bubu-camera\pet.json'), ' ')
        }
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo.FileName = "$env:SystemRoot\System32\cmd.exe"
        $process.StartInfo.Arguments = '/d /c ""' + (Join-Path $package 'install.cmd') + '" -CodexHome "' + $cmdHome + '""'
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        try {
            [void] $process.Start()
            $process.StandardInput.WriteLine()
            $process.StandardInput.Close()
            $cmdOutput = $process.StandardOutput.ReadToEnd()
            $cmdError = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            Assert-True ($process.ExitCode -eq $expectedCode) "CMD launcher should return $expectedCode; received $($process.ExitCode): $cmdOutput $cmdError"
        }
        finally {
            $process.Dispose()
        }
    }
    Pass 'CMD launcher handles quoted Chinese/space paths and preserves success/conflict exit codes after pause.'

    foreach ($originalFile in $originalPetFiles) {
        Assert-True (Test-Path -LiteralPath $originalFile.Path -PathType Leaf) 'Original user pet must still exist.'
        Assert-True ((Get-FileHash -LiteralPath $originalFile.Path -Algorithm SHA256).Hash -eq $originalFile.Hash) 'Original user pet bytes must remain unchanged.'
        Assert-True ((Get-Item -LiteralPath $originalFile.Path).LastWriteTimeUtc.Ticks -eq $originalFile.WriteTicks) 'Original user pet timestamps must remain unchanged.'
    }
    Pass "Actual user pet untouched (verified $($originalPetFiles.Count) pre-existing files)."

    # No recursive cleanup: retain the bounded fixture tree as evidence.
    Write-Host "All $passed test cases passed. Test fixtures retained at: $testRoot"
}
finally {
    $env:CODEX_HOME = $savedCodexHome
    $env:USERPROFILE = $savedUserProfile
}
