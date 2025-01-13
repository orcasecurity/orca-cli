param (
    [string]$tag,
    [string]$binDir = ".",
    [switch]$insecure
)

$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

function Invoke-WebRequestInsecure {
    param(
        [string]$Uri,
        [string]$OutFile = $null,
        [string]$Method = "GET"
    )
    
    if ($insecure) {
        # For older PowerShell versions, we need to use this callback
        add-type @"
            using System.Net;
            using System.Security.Cryptography.X509Certificates;
            public class TrustAllCertsPolicy : ICertificatePolicy {
                public bool CheckValidationResult(
                    ServicePoint srvPoint, X509Certificate certificate,
                    WebRequest request, int certificateProblem) {
                    return true;
                }
            }
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }

    if ($OutFile) {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Method $Method -UseBasicParsing
    } else {
        Invoke-RestMethod -Uri $Uri -Method $Method -UseBasicParsing
    }
}

function Get-LatestVersion {
    $url = "https://api.github.com/repos/orcasecurity/orca-cli/releases/latest"
    $latestRelease = Invoke-WebRequestInsecure -Uri $url
    return $latestRelease.tag_name
}

function Validate-Tag {
    param (
        [string]$tag
    )
    $url = "https://api.github.com/repos/orcasecurity/orca-cli/releases/tags/$tag"
    try {
        Invoke-WebRequestInsecure -Uri $url -Method "HEAD"
        return $true
    } catch {
        return $false
    }
}

function Get-Architecture {
    $is64bit = [Environment]::Is64BitOperatingSystem
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
        Invoke-WebRequestInsecure -Uri $tarballUrl -OutFile "$($tempDir)\orca-cli_windows.zip"
    } catch {
        Write-Error "Failed to download the binary. Please check your internet connection and ensure that the version/tag is correct."
        return
    }
    
    try {
        Invoke-WebRequestInsecure -Uri $checksumUrl -OutFile "$($tempDir)\orca-cli_windows_checksums.txt"
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
