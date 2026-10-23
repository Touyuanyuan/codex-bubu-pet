#requires -Version 5.1
[CmdletBinding()]
param(
    # Optional override. Otherwise CODEX_HOME, then USERPROFILE\.codex is used.
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$petId = 'bubu-camera'
$petName = '相机布布'
$expectedImageHash = '4C86CC31E3CCC9BE7628CA6DB8F8BDE45C34B2B74FB14E94AA874306EAF80A91'
$payloadNames = @('pet.json', 'spritesheet.webp')
$stagingPath = $null
$petsRoot = $null
$exitCode = 1

function Get-FullFileSystemPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'The installation path must not be blank.'
    }
    # Resolve relative paths using PowerShell's current filesystem location.
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref] $provider, [ref] $drive)
    if ($provider.Name -ne 'FileSystem') {
        throw 'The installation location must be a filesystem path.'
    }
    return [System.IO.Path]::GetFullPath($resolved)
}

function Assert-NoReparsePoint {
    param([Parameter(Mandatory = $true)][string] $Path)

    # Do not install through junctions/symlinks, including ancestor directories.
    $cursor = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a symbolic link or junction in this path: $cursor"
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cursor)
        if ([string]::Equals($cursor, $parent, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $cursor = $parent
    }
}

function Assert-DirectChild {
    param(
        [Parameter(Mandatory = $true)][string] $Child,
        [Parameter(Mandatory = $true)][string] $Parent
    )

    $childFull = [System.IO.Path]::GetFullPath($Child)
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $actualParent = [System.IO.Path]::GetDirectoryName($childFull).TrimEnd('\', '/')
    if (-not [string]::Equals($actualParent, $parentFull,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path safety check failed: $childFull is not a direct child of $parentFull"
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-Payload {
    param([Parameter(Mandatory = $true)][string] $Directory)

    Assert-NoReparsePoint $Directory
    foreach ($name in $payloadNames) {
        $file = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Missing required package file: $file. Extract the complete ZIP before installing."
        }
        Assert-NoReparsePoint $file
    }

    $manifestPath = Join-Path $Directory 'pet.json'
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Cannot read pet.json as valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $manifest -or $manifest -is [System.Array]) {
        throw 'pet.json must contain one JSON object.'
    }
    $propertyNames = @($manifest.PSObject.Properties.Name)
    foreach ($required in @('id', 'displayName', 'description', 'spriteVersionNumber', 'spritesheetPath')) {
        if ($propertyNames -notcontains $required) {
            throw "pet.json is missing required field: $required"
        }
    }
    if ($manifest.id -isnot [string] -or $manifest.id -cne $petId -or
        $manifest.displayName -isnot [string] -or $manifest.displayName -cne $petName -or
        $manifest.spritesheetPath -isnot [string] -or $manifest.spritesheetPath -cne 'spritesheet.webp' -or
        $manifest.spriteVersionNumber -is [string] -or $manifest.spriteVersionNumber -ne 2 -or
        $manifest.description -isnot [string] -or [string]::IsNullOrWhiteSpace($manifest.description)) {
        throw 'pet.json does not match this Bubu v2 package (identity, name, version or sprite path).'
    }

    $imagePath = Join-Path $Directory 'spritesheet.webp'
    if ((Get-Sha256 $imagePath) -ne $expectedImageHash) {
        throw 'Sprite SHA-256 verification failed. Re-extract a complete, unmodified release ZIP.'
    }

    # This pinned release is lossless WebP (VP8L). Read its native image header;
    # no external image libraries, network connection or administrator is needed.
    $bytes = [System.IO.File]::ReadAllBytes($imagePath)
    if ($bytes.Length -lt 25 -or
        [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'RIFF' -or
        [System.Text.Encoding]::ASCII.GetString($bytes, 8, 4) -cne 'WEBP' -or
        [System.Text.Encoding]::ASCII.GetString($bytes, 12, 4) -cne 'VP8L' -or
        $bytes[20] -ne 0x2F) {
        throw 'The sprite file is not the expected lossless WebP image.'
    }
    $width = 1 + [int] $bytes[21] + (([int] $bytes[22] -band 0x3F) -shl 8)
    $height = 1 + (([int] $bytes[22] -band 0xC0) -shr 6) +
        ([int] $bytes[23] -shl 2) + (([int] $bytes[24] -band 0x0F) -shl 10)
    if ($width -ne 1536 -or $height -ne 2288) {
        throw "Sprite dimensions must be 1536 x 2288; found $width x $height."
    }
    return @{
        'pet.json' = Get-Sha256 $manifestPath
        'spritesheet.webp' = $expectedImageHash
    }
}

function Write-SelectionInstructions {
    param([Parameter(Mandatory = $true)][string] $InstalledPath)
    Write-Host ''
    Write-Host "Installed location: $InstalledPath"
    Write-Host 'Next in Codex: Settings > Mini and Pets > small Refresh icon > select Camera Bubu.'
    Write-Host '接下来：Codex 设置 > Mini 与虚拟宠物 > 点击「创建虚拟宠物」左侧的小刷新图标 ↻ > 选择「相机布布」。'
    Write-Host 'The current pet selection and Codex settings have not been changed.'
    Write-Host '安装后需要手动刷新并选中；无需点击「创建虚拟宠物」。'
}

try {
    $sourcePath = Join-Path $PSScriptRoot 'pet'
    $expectedHashes = Assert-Payload $sourcePath

    if ($PSBoundParameters.ContainsKey('CodexHome')) {
        if ([string]::IsNullOrWhiteSpace($CodexHome)) {
            throw '-CodexHome must not be blank when supplied.'
        }
        $chosenHome = $CodexHome
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $chosenHome = $env:CODEX_HOME
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $chosenHome = Join-Path $env:USERPROFILE '.codex'
    }
    else {
        throw 'Neither CODEX_HOME nor USERPROFILE is set. Supply -CodexHome explicitly.'
    }

    $resolvedHome = Get-FullFileSystemPath $chosenHome
    $petsRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedHome 'pets'))
    $targetPath = [System.IO.Path]::GetFullPath((Join-Path $petsRoot $petId))
    Assert-DirectChild $petsRoot $resolvedHome
    Assert-DirectChild $targetPath $petsRoot
    Assert-NoReparsePoint $targetPath

    if (Test-Path -LiteralPath $targetPath) {
        $identical = Test-Path -LiteralPath $targetPath -PathType Container
        foreach ($name in $payloadNames) {
            $existingFile = Join-Path $targetPath $name
            if (-not (Test-Path -LiteralPath $existingFile -PathType Leaf)) {
                $identical = $false
                break
            }
            Assert-NoReparsePoint $existingFile
            if ((Get-Sha256 $existingFile) -ne $expectedHashes[$name]) {
                $identical = $false
                break
            }
        }
        if (-not $identical) {
            $exitCode = 2
            throw "An existing, different pet already occupies $targetPath. Nothing was overwritten. Back up that folder, move it out of the pets directory yourself, then run this installer again."
        }
        Write-Host 'Camera Bubu is already installed with identical files. Nothing was changed.'
        Write-SelectionInstructions $targetPath
        $exitCode = 0
    }
    else {
        [void] [System.IO.Directory]::CreateDirectory($petsRoot)
        Assert-NoReparsePoint $petsRoot
        $stagingPath = Join-Path $petsRoot ('.bubu-camera-install-' + [guid]::NewGuid().ToString('N'))
        Assert-DirectChild $stagingPath $petsRoot
        [void] [System.IO.Directory]::CreateDirectory($stagingPath)

        foreach ($name in $payloadNames) {
            [System.IO.File]::Copy((Join-Path $sourcePath $name), (Join-Path $stagingPath $name), $false)
        }
        $stagedHashes = Assert-Payload $stagingPath
        foreach ($name in $payloadNames) {
            if ($stagedHashes[$name] -ne $expectedHashes[$name]) {
                throw "Copied file failed integrity validation: $name"
            }
        }

        # Check both absolute paths before moving this newly created directory.
        # Directory.Move fails if a target appeared meanwhile; it never overwrites.
        Assert-DirectChild $stagingPath $petsRoot
        Assert-DirectChild $targetPath $petsRoot
        Assert-NoReparsePoint $petsRoot
        Assert-NoReparsePoint $stagingPath
        [System.IO.Directory]::Move($stagingPath, $targetPath)
        $stagingPath = $null
        Write-Host 'Camera Bubu installed successfully.'
        Write-SelectionInstructions $targetPath
        $exitCode = 0
    }
}
catch {
    [Console]::Error.WriteLine('Installation failed: ' + $_.Exception.Message)
}
finally {
    if ($null -ne $stagingPath -and (Test-Path -LiteralPath $stagingPath -PathType Container)) {
        try {
            # Clean only our own two temporary files, never recursively delete.
            Assert-DirectChild $stagingPath $petsRoot
            Assert-NoReparsePoint $stagingPath
            foreach ($name in $payloadNames) {
                $temporaryFile = Join-Path $stagingPath $name
                if (Test-Path -LiteralPath $temporaryFile -PathType Leaf) {
                    Assert-NoReparsePoint $temporaryFile
                    Remove-Item -LiteralPath $temporaryFile -Force
                }
            }
            [System.IO.Directory]::Delete($stagingPath, $false)
        }
        catch {
            [Console]::Error.WriteLine('Temporary folder retained for inspection: ' + $stagingPath)
        }
    }
}

exit $exitCode
