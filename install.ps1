param (
    [string]$tag,
    [string]$binDir = "."
)

$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

function Get-LatestVersion {
    $url = "https://api.github.com/repos/orcasecurity/orca-cli/releases/latest"
    $latestRelease = Invoke-RestMethod -Uri $url
    return $latestRelease.tag_name
}

function Validate-Tag {
    param (
        [string]$tag
    )

    $url = "https://api.github.com/repos/orcasecurity/orca-cli/releases/tags/$tag"
    try {
        $response = Invoke-RestMethod -Uri $url -Method Head -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Detect architecture
function Get-Architecture {
    # Check if the OS is 64-bit
    $is64bit = [Environment]::Is64BitOperatingSystem

    # Determine the processor architecture
    if ($is64bit) {
        if ([System.Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") -eq "AMD64") {
			      return "amd64"
        } else {
            return "arm64"
        }
    } else {
        Write-Output "At this moment 32-bit Architecture is not supported."
		    exit 1
    }
}

function Download-InstallOrcaCLI {
    param(
        [string]$tag,
        [string]$binDir
    )

    $arch = Get-Architecture
    $tarballUrl = "https://github.com/orcasecurity/orca-cli/releases/download/$tag/orca-cli_$($tag)_windows_$arch.zip"
    $checksumUrl = "https://github.com/orcasecurity/orca-cli/releases/download/$tag/orca-cli_$($tag)_checksums.txt"
    Write-Output "Downloading orca-cli.exe, version: $($tag)"
    
    $tempDirName = "orca-cli_temp_" + (Get-Random)
    $tempDir = New-Item -ItemType Directory -Path $env:TEMP -Name $tempDirName | Select-Object -ExpandProperty FullName
    Write-Output "Downloading files into $($tempDir)"
    try {
        Invoke-WebRequest -Uri $tarballUrl -OutFile "$($tempDir)\orca-cli_windows.zip" -ErrorAction Stop
    } catch {
        Write-Error "Failed to download the binary. Please check your internet connection and ensure that the version/tag is correct."
        return
    }
    
    try {
        Invoke-WebRequest -Uri $checksumUrl -OutFile "$($tempDir)\orca-cli_windows_checksums.txt" -ErrorAction Stop
    } catch {
        Write-Error "Failed to download the checksum file. Please check your internet connection and ensure that the version/tag is correct."
        return
    }

    $hash = Get-FileHash -Path "$($tempDir)\orca-cli_windows.zip" -Algorithm SHA256
    if ((Get-Content "$($tempDir)\orca-cli_windows_checksums.txt") -match $hash.Hash) {
        Expand-Archive -Path "$($tempDir)\orca-cli_windows.zip" -DestinationPath $tempDir
        $binexe = "orca-cli.exe"
        Copy-Item -Path "$($tempDir)\$binexe" -Destination $binDir -Force
        Write-Output "Orca CLI installed successfully - $($binDir)\$binexe"
    } else {
        Write-Error "SHA256 verification failed for $($tempDir)\orca-cli_windows.zip"
    }
    Remove-Item -Path $tempDir -Force -Recurse
}

if (-not $tag) {
    $tag = Get-LatestVersion
} elseif (-not (Validate-Tag -tag $tag)) {
    Write-Error "Invalid tag: $tag"
    exit
}

Download-InstallOrcaCLI -tag $tag -binDir $binDir
