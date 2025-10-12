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

function Get-FileHashCompat {
    param(
        [string]$Path,
        [string]$Algorithm = "SHA256"
    )
    
    # Check if Get-FileHash is available (PowerShell 4.0+)
    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        Write-Host "Using built-in Get-FileHash cmdlet for hash verification" -ForegroundColor Green
        return Get-FileHash -Path $Path -Algorithm $Algorithm
    }
    
    # Fallback for older PowerShell versions
    Write-Host "Get-FileHash not available, using .NET fallback for hash calculation" -ForegroundColor Yellow
    
    try {
        $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
        $fileStream = [System.IO.File]::OpenRead($Path)
        $hashBytes = $hasher.ComputeHash($fileStream)
        $fileStream.Close()
        $hasher.Dispose()
        
        $hashString = [System.BitConverter]::ToString($hashBytes).Replace("-", "")
        
        # Return object similar to Get-FileHash
        return [PSCustomObject]@{
            Algorithm = $Algorithm
            Hash = $hashString
            Path = $Path
        }
    } catch {
        Write-Error "Failed to calculate hash: $_"
        throw
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

 
function Test-AuthenticodeSignature {
    param(
        [string]$Path
    )
    Write-Output "Verifying Authenticode digital signature on file: '$Path'"
    
    if (-not (Test-Path $Path)) {
        Write-Warning "File not found at '$Path' for signature check."
        return $false
    }
    

    $ExpectedSignerCN = "CN=Orca Security Inc."
    $ExpectedIssuerCN = "CN=Sectigo Public Code Signing CA"

    
    try {
        $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        $signerSubject = $signature.SignerCertificate.Subject
        $signerIssuer = $signature.SignerCertificate.Issuer

        
        if ($signature.Status -eq "Valid") {
            # Check 1: Signer Subject (Owner)
            $isSubjectValid = $signerSubject -like "*$ExpectedSignerCN*"
            
            # Check 2: Signer Issuer (CA)
            # Use -like for flexibility, ensuring the expected CN is part of the full Issuer string
            $isIssuerValid = $signerIssuer -like "*$ExpectedIssuerCN*"
            
            if ($isSubjectValid -and $isIssuerValid) {
                # Changed Write-Output to Write-Host for colored text
                Write-Host "Authenticode Signature is VALID and verified to be signed by Orca Security Inc." -ForegroundColor Green
                Write-Host "Subject: $($signerSubject)" -ForegroundColor DarkGreen
                Write-Host "Issuer: $($signerIssuer)" -ForegroundColor DarkGreen
                return $true
            } else {
                Write-Warning "Authenticode Signature is VALID but verification FAILED (Owner or Issuer mismatch)."
                
                if (-not $isSubjectValid) {
                    Write-Warning "Owner Check Failed: Expected subject to contain '$ExpectedSignerCN', but found: $($signerSubject)"
                }
                if (-not $isIssuerValid) {
                    Write-Warning "Issuer Check Failed: Expected issuer to contain '$ExpectedIssuerCN', but found: $($signerIssuer)"
                }
                return $false
            }
        } else {
            Write-Warning "Authenticode Signature check FAILED: $($signature.Status). $($signature.StatusMessage)"
            return $false
        }
    } catch {
        Write-Error "An error occurred during signature check. Fallback to checksum is necessary. Error: $($_.Exception.Message)"
        return $false
    }
} 


 function Download-InstallOrcaCLI {
    param(
        [string]$tag,
        [string]$binDir
    )
    $arch = Get-Architecture
    $tempDirName = "orca-cli_temp_" + (Get-Random)
    $tempDir = New-Item -ItemType Directory -Path $env:TEMP -Name $tempDirName | Select-Object -ExpandProperty FullName
    Write-Output "Downloading files into $($tempDir)"

    $zipFileName = "orca-cli_windows.zip"
    $tarballFile = "$($tempDir)\$zipFileName"
    $binexe = "orca-cli.exe"
    # Path to the extracted executable file
    $extractedExePath = "$($tempDir)\$binexe"
    
    $success = $false

    # --- ATTEMPT 1: Signed Binary Download, Extraction, and Authenticode Verification ---
    $tarballUrlSigned = "https://github.com/orcasecurity/orca-cli/releases/download/$tag/orca-cli_$($tag)_windows_$($arch)_signed.zip"
    Write-Output "Attempt 1: Trying to download digitally signed binary from: $($tarballUrlSigned)"
    
    try {
        # 1. Download Signed File (ZIP)
        Invoke-WebRequestInsecure -Uri $tarballUrlSigned -OutFile $tarballFile
        Write-Output "Signed binary ZIP downloaded successfully."
        
        # 2. Extract the EXE
        Expand-Archive -Path $tarballFile -DestinationPath $tempDir -Force
        Write-Output "ZIP extracted successfully. Checking signature on the executable..."

        # 3. Verify Signature on the *extracted EXE*
        $signatureValid = Test-AuthenticodeSignature -Path $extractedExePath
        
        if ($signatureValid) {
            # Installation is only performed if the EXE signature is valid
            Write-Host "Digital signature is valid. Installing Orca CLI..." -ForegroundColor Green
            Copy-Item -Path $extractedExePath -Destination $binDir -Force
            Write-Host "Orca CLI (Signed) installed successfully to: $($binDir)\$binexe" -ForegroundColor Green
            $success = $true
        } else {
            Write-Warning "Signature verification failed for the extracted binary. Proceeding to fallback."
            # Clean up temporary files, specifically the contents of $tempDir
        }

    } catch {
        Write-Warning "Attempt 1 failed (Download or Extraction/Initial Signature Check). Error: $($_.Exception.Message). Proceeding to fallback."
    }
    
    # Ensure temporary files are clean before falling back, in case of partial success/failure
    if (-not $success) {
        Remove-Item -Path $tarballFile -Force -ErrorAction SilentlyContinue
        # This cleans up the extracted exe and any other files
        if (Test-Path $tempDir) {
            Get-ChildItem -Path $tempDir -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }


    # --- ATTEMPT 2: Fallback to Checksum Verification (Original Flow) ---
    if (-not $success) {
        Write-Output "Attempt 2: Initiating fallback to unsigned binary and SHA256 checksum verification."
        
        $tarballUrlUnsigned = "https://github.com/orcasecurity/orca-cli/releases/download/$tag/orca-cli_$($tag)_windows_$($arch).zip"
        $checksumUrl = "https://github.com/orcasecurity/orca-cli/releases/download/$tag/orca-cli_$($tag)_checksums.txt"
        $checksumFile = "$($tempDir)\orca-cli_windows_checksums.txt"

        Write-Output "Downloading binary from: $($tarballUrlUnsigned)"

        try {
            Invoke-WebRequestInsecure -Uri $tarballUrlUnsigned -OutFile $tarballFile
            $success = $true
        } catch {
            Write-Error "Failed to download the binary. Please check your internet connection and ensure that the version/tag is correct."
            $success = $false
            # Use 'break' logic by falling through to final cleanup
        }
        
        if ($success -ne $false) { # Only proceed if the download above was successful
            try {
                Invoke-WebRequestInsecure -Uri $checksumUrl -OutFile $checksumFile
            } catch {
                Write-Error "Failed to download the checksum file. Cannot verify integrity."
                $success = $false
                # Use 'break' logic by falling through to final cleanup
            }
            
            if ($success -ne $false) {
                # Use compatible hash function
                Write-Output "Verifying SHA256 checksum..."
                $hash = Get-FileHashCompat -Path $tarballFile -Algorithm SHA256
                Write-Output "File hash: $($hash.Hash)"
                
                # Check if the calculated hash exists in the checksum file
                if ((Get-Content $checksumFile) -match $hash.Hash) {
                    # Changed Write-Output to Write-Host for correct console coloring
                    Write-Host "SHA256 verification successful" -ForegroundColor Green
                    
                    # Extract and copy for the checksum flow
                    Expand-Archive -Path $tarballFile -DestinationPath $tempDir -Force
                    Copy-Item -Path $extractedExePath -Destination $binDir -Force
                    
                    # Changed Write-Output to Write-Host for correct console coloring
                    Write-Host "Orca CLI (Checksum Verified) installed successfully to: $($binDir)\$binexe" -ForegroundColor Green
                    $success = $true
                } else {
                    Write-Error "SHA256 verification FAILED for $($tarballFile). The downloaded file is corrupt or untrustworthy."
                    $success = $false
                }
            }
        }
    }
    
    # Final Cleanup
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Force -Recurse -ErrorAction SilentlyContinue
    }
    
    if (-not $success) {
        Write-Error "Installation failed after both signed and checksum attempts."
        exit 1
    }
} 


# Check PowerShell version and warn if too old
Write-Output "PowerShell Version: $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Warning "PowerShell version is quite old. Some features may not work properly."
}

if (-not $tag) {
    $tag = Get-LatestVersion
} elseif (-not (Validate-Tag -tag $tag)) {
    Write-Error "Invalid tag: $tag"
    exit
}

Download-InstallOrcaCLI -tag $tag -binDir $binDir
