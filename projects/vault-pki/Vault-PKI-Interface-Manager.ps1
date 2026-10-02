#requires -Version 5.1

<#
.SYNOPSIS
    Vault PKI Interface Manager

.DESCRIPTION
    Starts/configures a local HashiCorp Vault development server,
    automatically obtains the Vault root token, configures the PKI
    engine and provides an interactive certificate-management menu.

    Developer usage:

        .\Vault-PKI-Interface-Manager.ps1

    Requirements:
        - Docker Desktop
        - OpenSSL

.NOTES
    VAULT_ADDR and VAULT_TOKEN are automatically configured
    for the current PowerShell session.

    Configuration (working directory, PKI role/domain, CA name) is
    stored in "vault-ca.config.json" next to this script. On first
    run you'll be prompted for values and they'll be saved for
    future runs, so the script no longer requires hardcoded paths.
#>

# ============================================================
# CONFIGURATION
# ============================================================

$VaultContainerName = "vault"
$VaultImage         = "hashicorp/vault:latest"
$VaultAddress       = "http://localhost:8200"
$VaultVolume        = "vault-data"

$ConfigFile = Join-Path $PSScriptRoot "vault-ca.config.json"

# The following are now loaded from $ConfigFile via Get-VaultCaConfig
# (called during Initialize-Application). Defaults below are used
# only the very first time, to seed the prompts.
$WorkingDirectory  = $null
$PkiPath           = "pki"
$RoleName          = "dev-role"
$RootCACommonName  = "example.com"
$RootCAIssuerName  = "root-ca"
$RootCATtl         = "87600h"
$RoleDomain        = "apps.dev.example.com"
$RoleMaxTtl        = "720h"

# Tracks the most recently signed certificate/key pair, so
# Export-Pfx and Install-RootCaTrust can offer sane defaults.
$script:LastSignedCertFile = $null
$script:LastSignedKeyFile  = $null
$script:RootCaFile         = $null


# ============================================================
# CONSOLE HELPERS
# ============================================================

function Write-Title {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Yellow
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[OK]   $Text" -ForegroundColor Green
}

function Write-ErrorMessage {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[ERROR] $Text" -ForegroundColor Red
}

function Write-WarningMessage {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[WARN] $Text" -ForegroundColor DarkYellow
}

# ============================================================
# CONFIG FILE (working directory, PKI/role/CA settings)
# ============================================================

function Get-VaultCaConfig {

    Write-Title "Loading configuration"

    if (Test-Path -LiteralPath $ConfigFile) {

        try {

            $cfg = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -ErrorAction Stop

            Write-Success "Configuration loaded from:"
            Write-Host "         $ConfigFile"

            return $cfg
        }
        catch {

            Write-WarningMessage "Existing config file could not be parsed. Recreating it."
        }
    }

    Write-Info "No configuration file found. Let's create one."
    Write-Host ""

    $defaultWorkingDir = Join-Path $PSScriptRoot "vault-ca-data"

    $inputWorkingDir = Read-Host "Working directory [$defaultWorkingDir]"
    if ([string]::IsNullOrWhiteSpace($inputWorkingDir)) { $inputWorkingDir = $defaultWorkingDir }

    $inputPkiPath = Read-Host "Vault PKI mount path [$PkiPath]"
    if ([string]::IsNullOrWhiteSpace($inputPkiPath)) { $inputPkiPath = $PkiPath }

    $inputRoleName = Read-Host "Signing role name [$RoleName]"
    if ([string]::IsNullOrWhiteSpace($inputRoleName)) { $inputRoleName = $RoleName }

    $inputRootCaCn = Read-Host "Root CA common name [$RootCACommonName]"
    if ([string]::IsNullOrWhiteSpace($inputRootCaCn)) { $inputRootCaCn = $RootCACommonName }

    $inputIssuerName = Read-Host "Root CA issuer name [$RootCAIssuerName]"
    if ([string]::IsNullOrWhiteSpace($inputIssuerName)) { $inputIssuerName = $RootCAIssuerName }

    $inputRootTtl = Read-Host "Root CA TTL [$RootCATtl]"
    if ([string]::IsNullOrWhiteSpace($inputRootTtl)) { $inputRootTtl = $RootCATtl }

    $inputRoleDomain = Read-Host "Allowed role domain [$RoleDomain]"
    if ([string]::IsNullOrWhiteSpace($inputRoleDomain)) { $inputRoleDomain = $RoleDomain }

    $inputRoleMaxTtl = Read-Host "Role max TTL [$RoleMaxTtl]"
    if ([string]::IsNullOrWhiteSpace($inputRoleMaxTtl)) { $inputRoleMaxTtl = $RoleMaxTtl }

    $cfg = [PSCustomObject]@{
        WorkingDirectory = $inputWorkingDir
        PkiPath          = $inputPkiPath
        RoleName         = $inputRoleName
        RootCACommonName = $inputRootCaCn
        RootCAIssuerName = $inputIssuerName
        RootCATtl        = $inputRootTtl
        RoleDomain       = $inputRoleDomain
        RoleMaxTtl       = $inputRoleMaxTtl
    }

    try {

        $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigFile -Encoding utf8 -ErrorAction Stop

        Write-Success "Configuration saved to:"
        Write-Host "         $ConfigFile"
        Write-Info "Edit this file directly, or delete it to be re-prompted."
    }
    catch {

        Write-WarningMessage "Could not save configuration file. Continuing without persistence."
        Write-Host $_.Exception.Message
    }

    return $cfg
}


# ============================================================
# COMMAND CHECK
# ============================================================

function Test-CommandExists {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    return $null -ne (Get-Command $CommandName -ErrorAction SilentlyContinue)
}

function Test-Requirements {

    Write-Title "Checking requirements"

    $missing = @()

    if (-not (Test-CommandExists "docker")) {
        $missing += "Docker"
    }

    if (-not (Test-CommandExists "openssl")) {
        $missing += "OpenSSL"
    }

    if ($missing.Count -gt 0) {

        Write-ErrorMessage "The following required tools are missing:"

        foreach ($tool in $missing) {
            Write-Host "  - $tool" -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "Install the missing requirements and run the script again."

        return $false
    }

    Write-Success "Docker found."
    Write-Success "OpenSSL found."

    return $true
}


# ============================================================
# WORKING DIRECTORY
# ============================================================

function Initialize-WorkingDirectory {

    Write-Title "Preparing working directory"

    if (-not (Test-Path -LiteralPath $WorkingDirectory)) {

        Write-Info "Directory does not exist."
        Write-Info "Creating: $WorkingDirectory"

        try {

            New-Item `
                -ItemType Directory `
                -Path $WorkingDirectory `
                -Force `
                -ErrorAction Stop | Out-Null

            Write-Success "Directory created."
        }
        catch {

            Write-ErrorMessage "Could not create working directory."
            Write-Host $_.Exception.Message

            return $false
        }
    }

    try {

        Set-Location -LiteralPath $WorkingDirectory -ErrorAction Stop

        Write-Success "Working directory:"
        Write-Host "         $((Get-Location).Path)"

        return $true
    }
    catch {

        Write-ErrorMessage "Could not change to working directory."
        Write-Host $_.Exception.Message

        return $false
    }
}


# ============================================================
# SET VAULT ADDRESS
# ============================================================

function Initialize-VaultAddress {

    Write-Title "Initializing Vault environment"

    $env:VAULT_ADDR = $VaultAddress

    Write-Success "VAULT_ADDR configured."

    Write-Host ""
    Write-Host "VAULT_ADDR = $env:VAULT_ADDR"
}


# ============================================================
# CHECK VAULT HTTP CONNECTION
# ============================================================

function Test-VaultConnection {

    try {

        $null = Invoke-RestMethod `
            -Uri "$env:VAULT_ADDR/v1/sys/health" `
            -Method GET `
            -ErrorAction Stop

        return $true
    }
    catch {

        return $false
    }
}


# ============================================================
# CHECK DOCKER CONTAINER
# ============================================================

function Get-VaultContainerStatus {

    $running = @(
        docker ps `
            --filter "name=^$VaultContainerName$" `
            --format "{{.Names}}" `
            2>$null
    )

    if ($running -contains $VaultContainerName) {
        return "running"
    }

    $exists = @(
        docker ps -a `
            --filter "name=^$VaultContainerName$" `
            --format "{{.Names}}" `
            2>$null
    )

    if ($exists -contains $VaultContainerName) {
        return "stopped"
    }

    return "missing"
}


# ============================================================
# START / CREATE VAULT
# ============================================================

function Start-Vault {

    Write-Title "Starting Vault"

    $status = Get-VaultContainerStatus

    switch ($status) {

        "running" {

            Write-Success "Vault container is already running."
        }

        "stopped" {

            Write-Info "Vault container already exists."
            Write-Info "Starting Vault container..."

            docker start $VaultContainerName

            if ($LASTEXITCODE -ne 0) {

                Write-ErrorMessage "Could not start Vault container."

                return $false
            }

            Write-Success "Vault container started."
        }

        "missing" {

            Write-Info "Vault container does not exist."
            Write-Info "Creating Vault container..."

            docker run -d `
                -e "VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200" `
                -p "8200:8200" `
                -v "${VaultVolume}:/vault/data" `
                --name $VaultContainerName `
                $VaultImage `
                server -dev

            if ($LASTEXITCODE -ne 0) {

                Write-ErrorMessage "Could not create Vault container."

                return $false
            }

            Write-Success "Vault container created."
        }

        default {

            Write-ErrorMessage "Unknown Vault container status: $status"

            return $false
        }
    }

    Write-Info "Waiting for Vault to become available..."

    $maxAttempts = 60

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

        if (Test-VaultConnection) {

            Write-Success "Vault is available."

            return $true
        }

        Write-Host "         Waiting... ($attempt/$maxAttempts)"

        Start-Sleep -Seconds 1
    }

    Write-ErrorMessage "Vault did not become available."

    Write-Host ""
    Write-Host "Vault Docker logs:" -ForegroundColor Yellow
    Write-Host ""

    docker logs $VaultContainerName

    return $false
}


# ============================================================
# GET ROOT TOKEN AUTOMATICALLY
# ============================================================

function Initialize-VaultToken {

    Write-Title "Obtaining Vault root token"

    Write-Info "Reading Vault Docker logs..."

    $maxAttempts = 30

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

        $logs = @(
            docker logs $VaultContainerName 2>&1
        )

        $tokenLine = $logs |
            Select-String -Pattern "Root Token:" |
            Select-Object -Last 1

        if ($null -ne $tokenLine) {

            $tokenText = $tokenLine.ToString()

            $rootToken = $tokenText -replace ".*Root Token:\s*", ""

            $rootToken = $rootToken.Trim()

            if (-not [string]::IsNullOrWhiteSpace($rootToken)) {

                $env:VAULT_TOKEN = $rootToken

                Write-Success "VAULT_TOKEN obtained automatically."

                Write-Info "Validating Vault token..."

                try {

                    $null = Invoke-RestMethod `
                        -Uri "$env:VAULT_ADDR/v1/auth/token/lookup-self" `
                        -Method GET `
                        -Headers @{
                            "X-Vault-Token" = $env:VAULT_TOKEN
                        } `
                        -ErrorAction Stop

                    Write-Success "Vault token validated."

                    return $true
                }
                catch {

                    Write-WarningMessage "Token was found but validation failed."
                    Write-Host $_.Exception.Message -ForegroundColor DarkYellow
                }
            }
        }

        Write-Host "         Waiting for root token... ($attempt/$maxAttempts)"

        Start-Sleep -Seconds 1
    }

    Write-ErrorMessage "Could not obtain the Vault root token."

    Write-Host ""
    Write-Host "You can inspect the logs with:"
    Write-Host ""
    Write-Host "docker logs $VaultContainerName" -ForegroundColor Gray

    return $false
}


# ============================================================
# VAULT API HELPER
# ============================================================

function Invoke-VaultApi {

    param(

        [Parameter(Mandatory)]
        [ValidateSet(
            "GET",
            "POST",
            "PUT",
            "DELETE"
        )]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [object]$Body = $null,

        [switch]$IgnoreErrors
    )

    if ([string]::IsNullOrWhiteSpace($env:VAULT_ADDR)) {
        throw "VAULT_ADDR is not configured."
    }

    if ([string]::IsNullOrWhiteSpace($env:VAULT_TOKEN)) {
        throw "VAULT_TOKEN is not configured."
    }

    $uri = "$env:VAULT_ADDR/v1/$Path"

    $headers = @{
        "X-Vault-Token" = $env:VAULT_TOKEN
    }

    try {

        if ($null -ne $Body) {

            $json = $Body | ConvertTo-Json -Depth 20

            return Invoke-RestMethod `
                -Uri $uri `
                -Method $Method `
                -Headers $headers `
                -ContentType "application/json" `
                -Body $json `
                -ErrorAction Stop
        }

        return Invoke-RestMethod `
            -Uri $uri `
            -Method $Method `
            -Headers $headers `
            -ErrorAction Stop
    }
    catch {

        if ($IgnoreErrors) {
            return $null
        }

        throw
    }
}


# ============================================================
# INITIALIZE PKI
# ============================================================

function Initialize-Pki {

    Write-Title "Configuring Vault PKI"

    Write-Info "Checking PKI engine..."

    try {

        $mounts = Invoke-VaultApi `
            -Method GET `
            -Path "sys/mounts"
    }
    catch {

        Write-ErrorMessage "Could not read Vault mounts."
        Write-Host $_.Exception.Message

        return $false
    }

    $pkiMountKey = "$PkiPath/"

    $pkiMount = $null

    if ($null -ne $mounts.data) {
        $pkiMount = $mounts.data.$pkiMountKey
    }

    if ($null -eq $pkiMount) {

        Write-Info "PKI engine is not enabled."
        Write-Info "Enabling PKI engine..."

        try {

            Invoke-VaultApi `
                -Method POST `
                -Path "sys/mounts/$PkiPath" `
                -Body @{
                    type = "pki"
                } | Out-Null

            Write-Success "PKI engine enabled."
        }
        catch {

            Write-ErrorMessage "Could not enable PKI engine."
            Write-Host $_.Exception.Message

            return $false
        }
    }
    else {

        Write-Success "PKI engine already enabled."
    }


    # --------------------------------------------------------
    # Configure PKI URLs
    # --------------------------------------------------------

    Write-Info "Configuring PKI URLs..."

    try {

        Invoke-VaultApi `
            -Method POST `
            -Path "$PkiPath/config/urls" `
            -Body @{

                crl_distribution_points = @(
                    "$env:VAULT_ADDR/v1/$PkiPath/crl"
                )

                issuing_certificates = @(
                    "$env:VAULT_ADDR/v1/$PkiPath/ca"
                )

                ocsp_servers = @(
                    "$env:VAULT_ADDR/v1/$PkiPath/ocsp"
                )

                enable_templating = $false

            } | Out-Null

        Write-Success "PKI URLs configured."
    }
    catch {

        Write-ErrorMessage "Could not configure PKI URLs."
        Write-Host $_.Exception.Message

        return $false
    }


    # --------------------------------------------------------
    # Check existing root CA
    # --------------------------------------------------------

    Write-Info "Checking root CA..."

    $issuerResult = Invoke-VaultApi `
        -Method GET `
        -Path "$PkiPath/issuers" `
        -IgnoreErrors

    $hasIssuer = $false

    if ($null -ne $issuerResult) {

        if ($null -ne $issuerResult.data) {

            if ($null -ne $issuerResult.data.key_info) {

                if ($issuerResult.data.key_info.Count -gt 0) {
                    $hasIssuer = $true
                }
            }

            if ($null -ne $issuerResult.data.keys) {

                if ($issuerResult.data.keys.Count -gt 0) {
                    $hasIssuer = $true
                }
            }
        }
    }

    $rootCaFile = Join-Path `
        $WorkingDirectory `
        "root-ca.crt"

    if (-not $hasIssuer) {

        Write-Info "No root CA detected."
        Write-Info "Generating root CA..."

        try {

            $rootResult = Invoke-VaultApi `
                -Method POST `
                -Path "$PkiPath/root/generate/internal" `
                -Body @{

                    common_name = $RootCACommonName
                    issuer_name = $RootCAIssuerName
                    ttl = $RootCATtl

                }

            Write-Success "Root CA generated."

            if ($null -ne $rootResult.data.certificate) {

                $rootResult.data.certificate |
                    Set-Content `
                        -Path $rootCaFile `
                        -Encoding ascii

                Write-Success "Root CA saved to:"
                Write-Host "         $rootCaFile"
            }
        }
        catch {

            Write-ErrorMessage "Could not generate root CA."
            Write-Host $_.Exception.Message

            return $false
        }
    }
    else {

        Write-Success "Root CA already exists."

        # Re-export the root CA to disk if it's missing locally
        # (e.g. fresh checkout, existing Vault volume).
        if (-not (Test-Path -LiteralPath $rootCaFile)) {

            try {

                $caResult = Invoke-RestMethod `
                    -Uri "$env:VAULT_ADDR/v1/$PkiPath/ca/pem" `
                    -Method GET `
                    -ErrorAction Stop

                $caResult | Set-Content -Path $rootCaFile -Encoding ascii

                Write-Success "Root CA re-exported to:"
                Write-Host "         $rootCaFile"
            }
            catch {

                Write-WarningMessage "Could not re-export existing root CA to disk."
            }
        }
    }

    $script:RootCaFile = $rootCaFile


    # --------------------------------------------------------
    # Check signing role
    # --------------------------------------------------------

    Write-Info "Checking signing role '$RoleName'..."

    $role = Invoke-VaultApi `
        -Method GET `
        -Path "$PkiPath/roles/$RoleName" `
        -IgnoreErrors

    if ($null -eq $role) {

        Write-Info "Role does not exist."
        Write-Info "Creating role '$RoleName'..."

        try {

            Invoke-VaultApi `
                -Method POST `
                -Path "$PkiPath/roles/$RoleName" `
                -Body @{

                    allowed_domains = @(
                        $RoleDomain
                    )

                    allow_subdomains = $true

                    max_ttl = $RoleMaxTtl

                } | Out-Null

            Write-Success "Role '$RoleName' created."
        }
        catch {

            Write-ErrorMessage "Could not create role '$RoleName'."
            Write-Host $_.Exception.Message

            return $false
        }
    }
    else {

        Write-Success "Role '$RoleName' already exists."
    }

    return $true
}


# ============================================================
# GENERATE PRIVATE KEY + CSR
# ============================================================

function New-Csr {

    Write-Title "Generate Private Key + CSR"

    $commonName = Read-Host "Enter Common Name (example: GR.eu)"

    if ([string]::IsNullOrWhiteSpace($commonName)) {

        Write-ErrorMessage "Common Name cannot be empty."

        return
    }

    $extraSansInput = Read-Host "Additional SANs, comma separated (optional, e.g. DNS names or IPs)"

    # Build the SAN list: the CN is always included, plus any
    # extra DNS names or IP addresses the caller supplied.
    $sanEntries = New-Object System.Collections.Generic.List[string]
    $sanEntries.Add("DNS:$commonName")

    if (-not [string]::IsNullOrWhiteSpace($extraSansInput)) {

        $extraValues = $extraSansInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

        foreach ($value in $extraValues) {

            $ipAddress = $null

            if ([System.Net.IPAddress]::TryParse($value, [ref]$ipAddress)) {
                $sanEntries.Add("IP:$value")
            }
            else {
                $sanEntries.Add("DNS:$value")
            }
        }
    }

    $sanString = ($sanEntries | Select-Object -Unique) -join ","

    $safeName = $commonName -replace '[^a-zA-Z0-9\.-]', '_'

    $keyFile = Join-Path `
        $WorkingDirectory `
        "$safeName.key"

    $csrFile = Join-Path `
        $WorkingDirectory `
        "$safeName.csr"

    if ((Test-Path -LiteralPath $keyFile) -or
        (Test-Path -LiteralPath $csrFile)) {

        Write-WarningMessage `
            "A key or CSR already exists for $commonName."

        $overwrite = Read-Host "Overwrite existing files? (y/n)"

        if ($overwrite.ToLower() -ne "y") {

            Write-Info "Operation cancelled."

            return
        }
    }

    Write-Info "Generating RSA 2048 private key..."
    Write-Info "SANs: $sanString"

    & openssl.exe req `
        -new `
        -newkey rsa:2048 `
        -nodes `
        -keyout $keyFile `
        -out $csrFile `
        -subj "/C=GR/O=MyOrg/OU=Engineering/CN=$commonName" `
        -addext "subjectAltName=$sanString"

    if ($LASTEXITCODE -ne 0) {

        Write-ErrorMessage `
            "OpenSSL failed to generate the CSR."

        return
    }

    Write-Success "Private key generated:"
    Write-Host "         $keyFile"

    Write-Success "CSR generated:"
    Write-Host "         $csrFile"

    Write-Host ""
    Write-Info "CSR information:"

    & openssl.exe req `
        -in $csrFile `
        -noout `
        -text
}


# ============================================================
# SIGN CSR
# ============================================================

function Sign-Csr {

    Write-Title "Sign CSR"

    $csrPath = Read-Host "Enter CSR file path"

    if (-not (Test-Path -LiteralPath $csrPath)) {

        Write-ErrorMessage "CSR file does not exist."

        return
    }

    try {

        $csr = Get-Content `
            -Path $csrPath `
            -Raw `
            -ErrorAction Stop
    }
    catch {

        Write-ErrorMessage "Could not read CSR file."
        Write-Host $_.Exception.Message

        return
    }

    try {

        Write-Info "Sending CSR to Vault..."

        $result = Invoke-VaultApi `
            -Method POST `
            -Path "$PkiPath/sign/$RoleName" `
            -Body @{

                csr = $csr
                format = "pem"

            }

        if ($null -eq $result.data.certificate) {
            throw "Vault did not return a certificate."
        }

        Write-Success "CSR signed successfully."

        $directory = Split-Path `
            $csrPath `
            -Parent

        if ([string]::IsNullOrWhiteSpace($directory)) {
            $directory = $WorkingDirectory
        }

        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($csrPath)

        $certificateFile = Join-Path `
            $directory `
            "$fileName.crt"

        $result.data.certificate |
            Set-Content `
                -Path $certificateFile `
                -Encoding ascii

        Write-Success "Certificate saved:"
        Write-Host "         $certificateFile"


        if ($null -ne $result.data.ca_chain) {

            $chainFile = Join-Path `
                $directory `
                "$fileName-chain.crt"

            ($result.data.ca_chain -join "`r`n") |
                Set-Content `
                    -Path $chainFile `
                    -Encoding ascii

            Write-Success "CA chain saved:"
            Write-Host "         $chainFile"
        }


        $serial = $result.data.serial_number

        if (-not [string]::IsNullOrWhiteSpace($serial)) {

            $env:CERT_SERIAL_ID = $serial

            Write-Host ""
            Write-Host "Certificate serial number:" -ForegroundColor Cyan
            Write-Host "$serial" -ForegroundColor Green
        }

        # Remember this cert/key pair so Export-Pfx can default to it.
        $matchingKeyFile = Join-Path $directory "$fileName.key"

        $script:LastSignedCertFile = $certificateFile

        if (Test-Path -LiteralPath $matchingKeyFile) {
            $script:LastSignedKeyFile = $matchingKeyFile
        }


        Write-Host ""
        Write-Info "Certificate details:"

        $result.data.certificate |
            & openssl.exe x509 `
                -noout `
                -text
    }
    catch {

        Write-ErrorMessage "Failed to sign CSR."
        Write-Host $_.Exception.Message
    }
}


# ============================================================
# EXPORT CERTIFICATE + KEY TO PFX (PKCS#12)
# ============================================================

function Export-Pfx {

    Write-Title "Export Certificate to PFX"

    $defaultCert = $script:LastSignedCertFile
    $certPrompt = "Enter certificate (.crt) file path"

    if (-not [string]::IsNullOrWhiteSpace($defaultCert)) {
        $certPrompt += " [$defaultCert]"
    }

    $certPath = Read-Host $certPrompt

    if ([string]::IsNullOrWhiteSpace($certPath)) {
        $certPath = $defaultCert
    }

    if ([string]::IsNullOrWhiteSpace($certPath) -or -not (Test-Path -LiteralPath $certPath)) {

        Write-ErrorMessage "Certificate file not found."

        return
    }

    $defaultKey = $script:LastSignedKeyFile
    $keyPrompt = "Enter private key (.key) file path"

    if (-not [string]::IsNullOrWhiteSpace($defaultKey)) {
        $keyPrompt += " [$defaultKey]"
    }

    $keyPath = Read-Host $keyPrompt

    if ([string]::IsNullOrWhiteSpace($keyPath)) {
        $keyPath = $defaultKey
    }

    if ([string]::IsNullOrWhiteSpace($keyPath) -or -not (Test-Path -LiteralPath $keyPath)) {

        Write-ErrorMessage "Private key file not found."

        return
    }

    $chainPath = $null
    $guessedChain = [System.IO.Path]::ChangeExtension($certPath, $null) -replace '\.$', ''
    $guessedChain = "$guessedChain-chain.crt"

    if (Test-Path -LiteralPath $guessedChain) {

        $includeChain = Read-Host "Found a matching CA chain file. Include it? (y/n)"

        if ($includeChain.ToLower() -eq "y") {
            $chainPath = $guessedChain
        }
    }

    $outputFile = [System.IO.Path]::ChangeExtension($certPath, "pfx")

    Write-Info "Enter an export password for the PFX (leave blank for none - not recommended)."

    $securePassword = Read-Host "PFX password" -AsSecureString

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    if ([string]::IsNullOrEmpty($plainPassword)) {
        $plainPassword = ""
    }

    $opensslArgs = @(
        "pkcs12", "-export",
        "-out", $outputFile,
        "-inkey", $keyPath,
        "-in", $certPath,
        "-passout", "pass:$plainPassword"
    )

    if (-not [string]::IsNullOrWhiteSpace($chainPath)) {
        $opensslArgs += @("-certfile", $chainPath)
    }

    Write-Info "Exporting PFX..."

    & openssl.exe @opensslArgs

    if ($LASTEXITCODE -ne 0) {

        Write-ErrorMessage "Failed to export PFX."

        return
    }

    Write-Success "PFX exported:"
    Write-Host "         $outputFile"
}


# ============================================================
# INSTALL ROOT CA INTO WINDOWS TRUST STORE
# ============================================================

function Install-RootCaTrust {

    Write-Title "Install Root CA into Windows Trust Store"

    $rootCaFile = $script:RootCaFile

    if ([string]::IsNullOrWhiteSpace($rootCaFile) -or -not (Test-Path -LiteralPath $rootCaFile)) {

        $rootCaFile = Join-Path $WorkingDirectory "root-ca.crt"
    }

    if (-not (Test-Path -LiteralPath $rootCaFile)) {

        Write-ErrorMessage "Root CA file not found:"
        Write-Host "         $rootCaFile"

        return
    }

    if (-not (Test-CommandExists "certutil")) {

        Write-ErrorMessage "certutil.exe was not found. This option requires Windows."

        return
    }

    Write-WarningMessage "This adds the local dev root CA to the machine's Trusted Root store."
    Write-WarningMessage "Only do this on a development machine you control."
    Write-Host ""
    Write-Host "Root CA file: $rootCaFile"
    Write-Host ""

    $confirmation = Read-Host "Continue? This may require an admin prompt. (y/n)"

    if ($confirmation.ToLower() -ne "y") {

        Write-Info "Operation cancelled."

        return
    }

    & certutil.exe -addstore -f "Root" $rootCaFile

    if ($LASTEXITCODE -ne 0) {

        Write-ErrorMessage "certutil failed to install the root CA."
        Write-Info "If you're not running as Administrator, re-run this from an elevated prompt."

        return
    }

    Write-Success "Root CA installed into the local machine trust store."
}


# ============================================================
# LIST CERTIFICATES (with expiry awareness)
# ============================================================

function Get-CertificateList {

    Write-Title "Certificates"

    try {

        $result = Invoke-VaultApi `
            -Method GET `
            -Path "$PkiPath/certs?list=true"

        if ($null -eq $result.data.keys -or $result.data.keys.Count -eq 0) {

            Write-Info "No certificates found."

            return
        }

        Write-Host "Certificates stored in Vault:"
        Write-Host ""

        $showExpiry = (Read-Host "Fetch expiry dates for each certificate? Slower, but flags soon-to-expire certs. (y/n)").ToLower() -eq "y"

        Write-Host ""

        foreach ($serial in $result.data.keys) {

            if (-not $showExpiry) {

                Write-Host "  $serial" -ForegroundColor Green

                continue
            }

            $certDetail = Invoke-VaultApi `
                -Method GET `
                -Path "$PkiPath/cert/$serial" `
                -IgnoreErrors

            if ($null -eq $certDetail -or [string]::IsNullOrWhiteSpace($certDetail.data.certificate)) {

                Write-Host "  $serial" -ForegroundColor Green
                Write-Host "      (could not read certificate details)" -ForegroundColor DarkYellow

                continue
            }

            $tempFile = [System.IO.Path]::GetTempFileName()

            try {

                $certDetail.data.certificate | Set-Content -LiteralPath $tempFile -Encoding ascii

                $enddateRaw = & openssl.exe x509 -in $tempFile -noout -enddate 2>$null
                $subjectRaw = & openssl.exe x509 -in $tempFile -noout -subject 2>$null

                $notAfterText = $enddateRaw -replace "^notAfter=", ""
                $subjectText  = $subjectRaw -replace "^subject=", ""

                $daysRemaining = $null

                try {

                    $notAfterDate = [datetime]::Parse($notAfterText)

                    $daysRemaining = ($notAfterDate - (Get-Date)).Days
                }
                catch {
                    # Leave $daysRemaining as $null if parsing fails.
                }

                $color = "Green"
                $flag  = ""

                if ($null -ne $daysRemaining) {

                    if ($daysRemaining -lt 0) {
                        $color = "Red"
                        $flag  = "  [EXPIRED]"
                    }
                    elseif ($daysRemaining -lt 7) {
                        $color = "Red"
                        $flag  = "  [EXPIRES IN $daysRemaining DAY(S)]"
                    }
                    elseif ($daysRemaining -lt 30) {
                        $color = "Yellow"
                        $flag  = "  [expires in $daysRemaining days]"
                    }
                }

                Write-Host "  $serial$flag" -ForegroundColor $color
                Write-Host "      Subject : $subjectText" -ForegroundColor Gray
                Write-Host "      Expires : $notAfterText" -ForegroundColor Gray
            }
            finally {

                Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
            }
        }
    }
    catch {

        Write-ErrorMessage "Could not retrieve certificates."
        Write-Host $_.Exception.Message
    }
}


# ============================================================
# READ CERTIFICATE
# ============================================================

function Read-Certificate {

    Write-Title "Read Certificate"

    $serial = Read-Host "Enter certificate serial number"

    if ([string]::IsNullOrWhiteSpace($serial)) {

        Write-ErrorMessage "Serial number cannot be empty."

        return
    }

    try {

        $result = Invoke-VaultApi `
            -Method GET `
            -Path "$PkiPath/cert/$serial"

        Write-Host ""
        Write-Host "Certificate:" -ForegroundColor Cyan
        Write-Host $result.data.certificate

        if ($result.data.ca_chain) {

            Write-Host ""
            Write-Host "CA Chain:" -ForegroundColor Cyan

            foreach ($certificate in $result.data.ca_chain) {

                Write-Host $certificate
            }
        }

        Write-Host ""
        Write-Host "Serial number:"
        Write-Host $result.data.serial_number -ForegroundColor Green
    }
    catch {

        Write-ErrorMessage "Certificate could not be found."
        Write-Host $_.Exception.Message
    }
}


# ============================================================
# REVOKE CERTIFICATE
# ============================================================

function Revoke-Certificate {

    Write-Title "Revoke Certificate"

    $serial = Read-Host "Enter certificate serial number"

    if ([string]::IsNullOrWhiteSpace($serial)) {

        Write-ErrorMessage "Serial number cannot be empty."

        return
    }

    Write-Host ""
    Write-Host "You are about to revoke:"
    Write-Host "$serial" -ForegroundColor Yellow

    Write-Host ""

    $confirmation = Read-Host "Continue? (y/n)"

    if ($confirmation.ToLower() -ne "y") {

        Write-Info "Operation cancelled."

        return
    }

    try {

        Invoke-VaultApi `
            -Method POST `
            -Path "$PkiPath/revoke" `
            -Body @{

                serial_number = $serial

            } | Out-Null

        Write-Success "Certificate revoked."
    }
    catch {

        Write-ErrorMessage "Failed to revoke certificate."
        Write-Host $_.Exception.Message
    }
}


# ============================================================
# SHOW CRL
# ============================================================

function Show-Crl {

    Write-Title "Certificate Revocation List"

    try {

        $crlFile = Join-Path `
            $WorkingDirectory `
            "vault-crl.pem"

        Write-Info "Downloading CRL..."

        $response = Invoke-WebRequest `
            -Uri "$env:VAULT_ADDR/v1/$PkiPath/crl" `
            -Headers @{
                "X-Vault-Token" = $env:VAULT_TOKEN
            } `
            -Method GET `
            -ErrorAction Stop

        $response.Content |
            Set-Content `
                -Path $crlFile `
                -Encoding ascii

        Write-Success "CRL saved:"
        Write-Host "         $crlFile"

        Write-Host ""
        Write-Info "CRL contents:"

        & openssl.exe crl `
            -in $crlFile `
            -text `
            -noout
    }
    catch {

        Write-ErrorMessage "Could not retrieve CRL."
        Write-Host $_.Exception.Message
    }
}


# ============================================================
# TIDY PKI
# ============================================================

function Invoke-Tidy {

    Write-Title "Tidy PKI"

    Write-WarningMessage `
        "This operation cleans certificate data from Vault."

    Write-Host ""

    $confirmation = Read-Host "Continue? (y/n)"

    if ($confirmation.ToLower() -ne "y") {

        Write-Info "Operation cancelled."

        return
    }

    try {

        Invoke-VaultApi `
            -Method POST `
            -Path "$PkiPath/tidy" `
            -Body @{

                tidy_cert_store = $true
                tidy_revoked_certs = $true
                tidy_expired_issuers = $true

            } | Out-Null

        Write-Success "Tidy operation started."

        Write-Info `
            "Check Docker logs if you want to monitor the operation."
    }
    catch {

        Write-ErrorMessage "Tidy operation failed."
        Write-Host $_.Exception.Message
    }
}


# ============================================================
# VAULT STATUS
# ============================================================

function Show-VaultStatus {

    Write-Title "Vault Status"

    try {

        $result = Invoke-RestMethod `
            -Uri "$env:VAULT_ADDR/v1/sys/health" `
            -Method GET `
            -ErrorAction Stop

        Write-Host "Vault address : $env:VAULT_ADDR"
        Write-Host "Initialized   : $($result.initialized)"
        Write-Host "Sealed        : $($result.sealed)"
        Write-Host "Version       : $($result.version)"
        Write-Host "Cluster name  : $($result.cluster_name)"
        Write-Host "Server time   : $($result.server_time_utc)"
    }
    catch {

        Write-ErrorMessage "Vault is not reachable."
        Write-Host $_.Exception.Message
    }
}


# ============================================================
# SHOW CONFIGURATION
# ============================================================

function Show-Configuration {

    Write-Title "Configuration"

    Write-Host "Vault address : $env:VAULT_ADDR"
    Write-Host "Container     : $VaultContainerName"
    Write-Host "Vault image   : $VaultImage"
    Write-Host "Volume        : $VaultVolume"
    Write-Host "PKI path      : $PkiPath"
    Write-Host "Role          : $RoleName"
    Write-Host "Role domain   : $RoleDomain"
    Write-Host "Root CA       : $RootCACommonName"
    Write-Host "Working dir   : $WorkingDirectory"
    Write-Host "Config file   : $ConfigFile"

    if ($env:CERT_SERIAL_ID) {

        Write-Host "Last serial   : $env:CERT_SERIAL_ID"
    }
    else {

        Write-Host "Last serial   : None"
    }

    Write-Host ""

    if ($env:VAULT_TOKEN) {

        Write-Host "Vault token   : Configured" -ForegroundColor Green
    }
    else {

        Write-Host "Vault token   : Not configured" -ForegroundColor Red
    }
}


# ============================================================
# OPEN VAULT UI
# ============================================================

function Open-VaultUi {

    Write-Info "Opening Vault UI..."

    Start-Process `
        "$env:VAULT_ADDR/ui/vault"
}


# ============================================================
# SHOW DOCKER LOGS
# ============================================================

function Show-VaultLogs {

    Write-Title "Vault Docker Logs"

    docker logs $VaultContainerName
}


# ============================================================
# STOP VAULT
# ============================================================

function Stop-Vault {

    Write-Title "Stop Vault"

    Write-WarningMessage `
        "This stops the Vault Docker container."

    Write-Info `
        "The '$VaultVolume' Docker volume will NOT be deleted."

    Write-Host ""

    $confirmation = Read-Host "Stop Vault? (y/n)"

    if ($confirmation.ToLower() -ne "y") {

        Write-Info "Operation cancelled."

        return
    }

    docker stop $VaultContainerName | Out-Null

    if ($LASTEXITCODE -eq 0) {

        Write-Success "Vault stopped."
    }
    else {

        Write-ErrorMessage "Could not stop Vault."
    }
}


# ============================================================
# MENU
# ============================================================

function Show-Menu {

    Clear-Host

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "                VAULT PKI INTERFACE MANAGER" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Write-Host ""

    Write-Host " Vault"
    Write-Host " -----------------------------------------------------------"

    Write-Host " Address : $env:VAULT_ADDR"
    Write-Host " PKI     : $PkiPath"
    Write-Host " CA      : $RootCACommonName"
    Write-Host " Role    : $RoleName"

    Write-Host ""

    Write-Host " Certificate Operations"
    Write-Host " -----------------------------------------------------------"

    Write-Host " [1] Generate private key + CSR"
    Write-Host " [2] Sign CSR"
    Write-Host " [3] List certificates"
    Write-Host " [4] Read certificate"
    Write-Host " [5] Revoke certificate"
    Write-Host " [6] Show CRL"
    Write-Host " [P] Export certificate + key to PFX"

    Write-Host ""

    Write-Host " Vault Operations"
    Write-Host " -----------------------------------------------------------"

    Write-Host " [7] Tidy certificates"
    Write-Host " [8] Vault status"
    Write-Host " [9] Open Vault UI"
    Write-Host " [T] Install root CA into Windows trust store"
    Write-Host " [L] Show Vault logs"
    Write-Host " [S] Stop Vault"

    Write-Host ""

    Write-Host " [C] Show configuration"
    Write-Host " [0] Exit"

    Write-Host ""
}


# ============================================================
# MAIN INITIALIZATION
# ============================================================

function Initialize-Application {

    Clear-Host

    Write-Title "LOCAL VAULT CA INITIALIZATION"

    # --------------------------------------------------------
    # Requirements
    # --------------------------------------------------------

    if (-not (Test-Requirements)) {

        return $false
    }

    # --------------------------------------------------------
    # Configuration (working dir, PKI/role/CA settings)
    # --------------------------------------------------------

    $cfg = Get-VaultCaConfig

    $script:WorkingDirectory = $cfg.WorkingDirectory
    $script:PkiPath          = $cfg.PkiPath
    $script:RoleName         = $cfg.RoleName
    $script:RootCACommonName = $cfg.RootCACommonName
    $script:RootCAIssuerName = $cfg.RootCAIssuerName
    $script:RootCATtl        = $cfg.RootCATtl
    $script:RoleDomain       = $cfg.RoleDomain
    $script:RoleMaxTtl       = $cfg.RoleMaxTtl

    # --------------------------------------------------------
    # Working directory
    # --------------------------------------------------------

    if (-not (Initialize-WorkingDirectory)) {

        return $false
    }

    # --------------------------------------------------------
    # VAULT_ADDR
    # --------------------------------------------------------

    Initialize-VaultAddress

    # --------------------------------------------------------
    # Docker / Vault
    # --------------------------------------------------------

    if (-not (Start-Vault)) {

        return $false
    }

    # --------------------------------------------------------
    # VAULT_TOKEN
    # --------------------------------------------------------

    $tokenInitialized = Initialize-VaultToken

    if (-not $tokenInitialized) {

        Write-ErrorMessage "Vault initialization failed."

        return $false
    }

    # --------------------------------------------------------
    # PKI
    # --------------------------------------------------------

    if (-not (Initialize-Pki)) {

        Write-ErrorMessage "PKI initialization failed."

        return $false
    }

    # --------------------------------------------------------
    # Initialization completed
    # --------------------------------------------------------

    Write-Host ""

    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "       VAULT CA INITIALIZATION COMPLETED" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green

    Write-Host ""

    Write-Success "Vault is ready."
    Write-Success "VAULT_ADDR is configured."
    Write-Success "VAULT_TOKEN is configured."
    Write-Success "PKI engine is ready."
    Write-Success "Root CA is ready."
    Write-Success "Signing role is ready."

    Write-Host ""

    Read-Host "Press ENTER to open the Vault PKI Interface Manager"

    return $true
}


# ============================================================
# APPLICATION START
# ============================================================

if (-not (Initialize-Application)) {

    Write-Host ""
    Write-ErrorMessage "Vault PKI Interface Manager could not be initialized."
    Write-Host ""

    return
}


# ============================================================
# MAIN MENU LOOP
# ============================================================

while ($true) {

    Show-Menu

    $choice = Read-Host "Select an option"

    switch ($choice.ToUpper()) {

        "1" {

            New-Csr

            Read-Host "`nPress ENTER to continue"
        }

        "2" {

            Sign-Csr

            Read-Host "`nPress ENTER to continue"
        }

        "3" {

            Get-CertificateList

            Read-Host "`nPress ENTER to continue"
        }

        "4" {

            Read-Certificate

            Read-Host "`nPress ENTER to continue"
        }

        "5" {

            Revoke-Certificate

            Read-Host "`nPress ENTER to continue"
        }

        "6" {

            Show-Crl

            Read-Host "`nPress ENTER to continue"
        }

        "P" {

            Export-Pfx

            Read-Host "`nPress ENTER to continue"
        }

        "7" {

            Invoke-Tidy

            Read-Host "`nPress ENTER to continue"
        }

        "8" {

            Show-VaultStatus

            Read-Host "`nPress ENTER to continue"
        }

        "9" {

            Open-VaultUi
        }

        "T" {

            Install-RootCaTrust

            Read-Host "`nPress ENTER to continue"
        }

        "L" {

            Show-VaultLogs

            Read-Host "`nPress ENTER to continue"
        }

        "S" {

            Stop-Vault

            Read-Host "`nPress ENTER to continue"
        }

        "C" {

            Show-Configuration

            Read-Host "`nPress ENTER to continue"
        }

        "0" {

            Write-Host ""
            Write-Host "Exiting Vault PKI Interface Manager..." -ForegroundColor Green

            break
        }

        default {

            Write-ErrorMessage "Invalid option."

            Start-Sleep -Seconds 1
        }
    }
}