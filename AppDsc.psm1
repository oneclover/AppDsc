#
# AppDsc.psm1 - Module code
#

Set-StrictMode -Version Latest

# Helper: Get property safely under strict mode
function Get-PropertySafe {
    param(
        $Object,
        [string]$Name,
        $DefaultValue = $null
    )
    if ($null -eq $Object) {
        return $DefaultValue
    }
    try {
        if ($Object.PSObject.Properties[$Name]) {
            return $Object.$Name
        }
    }
    catch {}
    return $DefaultValue
}

# Helper: Log message to stderr so it does not interfere with DSC JSON stdout
function Write-ErrorLog {
    param(
        [string]$Message
    )
    [Console]::Error.WriteLine("[AppDsc] $Message")
}

# Helper: Parse version string to integer array for comparison
function Parse-VersionString {
    param(
        [string]$VersionStr
    )
    if ([string]::IsNullOrWhiteSpace($VersionStr)) {
        return $null
    }
    
    # Check for prefix 'v' or 'V' and then extract dot-separated numbers
    if ($VersionStr -match '^[vV]?(\d+(\.\d+)+)') {
        $clean = $Matches[1]
        return $clean.Split('.') | ForEach-Object { [int]$_ }
    }
    
    # Fallback to scanning for any dot-separated numbers
    if ($VersionStr -match '(\d+(\.\d+)*)') {
        $clean = $Matches[1]
        return $clean.Split('.') | ForEach-Object { [int]$_ }
    }
    
    return $null
}

# Compare Version strings: returns -1 if A < B, 0 if A == B, 1 if A > B
function Compare-Version {
    [CmdletBinding()]
    param(
        [string]$VersionA,
        [string]$VersionB
    )

    if ([string]::IsNullOrEmpty($VersionA) -and [string]::IsNullOrEmpty($VersionB)) {
        return 0
    }
    if ([string]::IsNullOrEmpty($VersionA)) {
        return -1
    }
    if ([string]::IsNullOrEmpty($VersionB)) {
        return 1
    }

    # Try standard [System.Version] parsing first
    try {
        $vA = [System.Version]::new($VersionA)
        $vB = [System.Version]::new($VersionB)
        return $vA.CompareTo($vB)
    }
    catch {
        # Fallback to parsing digits and comparing component by component
        $partsA = Parse-VersionString $VersionA
        $partsB = Parse-VersionString $VersionB

        if ($null -eq $partsA -and $null -eq $partsB) {
            # Fallback to alphabetical if parsing fails completely
            return [System.String]::Compare($VersionA, $VersionB, [System.StringComparison]::OrdinalIgnoreCase)
        }
        if ($null -eq $partsA) { return -1 }
        if ($null -eq $partsB) { return 1 }

        $maxLen = [System.Math]::Max($partsA.Count, $partsB.Count)
        for ($i = 0; $i -lt $maxLen; $i++) {
            $valA = if ($i -lt $partsA.Count) { $partsA[$i] } else { 0 }
            $valB = if ($i -lt $partsB.Count) { $partsB[$i] } else { 0 }

            if ($valA -lt $valB) { return -1 }
            if ($valA -gt $valB) { return 1 }
        }
        return 0
    }
}

# Read JSON input from standard input (stdin)
function Read-DscInput {
    [CmdletBinding()]
    param()

    $rawInput = $null
    try {
        if ([System.Console]::IsInputRedirected) {
            $rawInput = [System.Console]::In.ReadToEnd()
        }
        else {
            $rawInput = $Input | Out-String
        }

        if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
            return ConvertFrom-Json -InputObject $rawInput
        }
    }
    catch {
        Write-ErrorLog "Warning: Failed to read stdin input: $_"
    }
    return $null
}

# Write JSON output to stdout
function Write-DscOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $Payload
    )
    # Depth 5 allows nested structures like desiredState and actualState to serialize correctly
    $json = ConvertTo-Json -InputObject $Payload -Depth 5 -Compress
    [Console]::Out.WriteLine($json)
}

# Scan registry hives for installed applications
function Get-InstalledApplication {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$ProductCode,
        [string]$DisplayNameRegex,
        [string]$Architecture = "Any"
    )

    $uninstallPaths = @(
        [PSCustomObject]@{ Path = "Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "x64" },
        [PSCustomObject]@{ Path = "Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "x86" },
        [PSCustomObject]@{ Path = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "Any" }
    )

    $apps = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($entry in $uninstallPaths) {
        $regPath = $entry.Path
        $psPath = $regPath
        if ($regPath.StartsWith("Registry::HKEY_LOCAL_MACHINE")) {
            $psPath = $regPath.Replace("Registry::HKEY_LOCAL_MACHINE", "HKLM:")
        }
        elseif ($regPath.StartsWith("Registry::HKEY_CURRENT_USER")) {
            $psPath = $regPath.Replace("Registry::HKEY_CURRENT_USER", "HKCU:")
        }

        if (-not (Test-Path -Path $psPath)) {
            continue
        }

        try {
            $subKeys = Get-ChildItem -Path $psPath -ErrorAction SilentlyContinue
            foreach ($subKey in $subKeys) {
                try {
                    $keyName = $subKey.PSChildName
                    $registryKeyPath = "$psPath\$keyName"
                    # Query without using fully-qualified path to allow Pester mocking
                    $properties = Get-ItemProperty -Path $registryKeyPath -ErrorAction SilentlyContinue
                    if ($null -eq $properties) { continue }

                    $displayName = Get-PropertySafe $properties "DisplayName"
                    if ([string]::IsNullOrWhiteSpace($displayName)) {
                        continue
                    }

                    # Determine ProductCode
                    $uninstallString = Get-PropertySafe $properties "UninstallString" ""
                    $detectedProductCode = $null
                    if ($keyName -match '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') {
                        $detectedProductCode = $keyName
                    }
                    elseif ($uninstallString -match '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}') {
                        $detectedProductCode = $Matches[0]
                    }

                    $app = [PSCustomObject]@{
                        DisplayName       = $displayName
                        DisplayVersion    = Get-PropertySafe $properties "DisplayVersion"
                        Publisher         = Get-PropertySafe $properties "Publisher"
                        InstallLocation   = Get-PropertySafe $properties "InstallLocation"
                        UninstallString   = $uninstallString
                        RegistryKeyPath   = $registryKeyPath
                        ProductCode       = $detectedProductCode
                        Architecture      = $entry.Arch
                    }

                    $apps.Add($app)
                }
                catch {}
            }
        }
        catch {}
    }

    # Filter by architecture if specified
    $filteredApps = $apps
    if ($Architecture -and $Architecture -ne "Any") {
        $filteredApps = $apps | Where-Object { $_.Architecture -eq $Architecture -or $_.Architecture -eq "Any" }
    }

    # Match by ProductCode if supplied
    if (-not [string]::IsNullOrEmpty($ProductCode)) {
        $matched = $filteredApps | Where-Object { 
            $_.ProductCode -eq $ProductCode -or 
            $_.RegistryKeyPath.EndsWith($ProductCode, [System.StringComparison]::OrdinalIgnoreCase) 
        }
        if ($matched) { return $matched[0] }
    }

    # Match by DisplayNameRegex if supplied
    if (-not [string]::IsNullOrEmpty($DisplayNameRegex)) {
        $matched = $filteredApps | Where-Object { $_.DisplayName -match $DisplayNameRegex }
        if ($matched) { return $matched[0] }
    }

    # Match by Name if supplied
    if (-not [string]::IsNullOrEmpty($Name)) {
        # Exact match first
        $matched = $filteredApps | Where-Object { $_.DisplayName -eq $Name }
        if ($matched) { return $matched[0] }

        # Contains match second
        $matched = $filteredApps | Where-Object { $_.DisplayName -like "*$Name*" }
        if ($matched) { return $matched[0] }
    }

    return $null
}

# Resolve local path, UNC path, or download installer from URL
function Resolve-InstallerPath {
    [CmdletBinding()]
    param(
        [string]$InstallerPath
    )

    if ($InstallerPath -match "^https?://") {
        Write-ErrorLog "InstallerPath is a URL, downloading: $InstallerPath"
        $tempDir = Join-Path $env:TEMP "AppDsc"
        if (-not (Test-Path $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        }

        try {
            $uri = [System.Uri]::new($InstallerPath)
            $filename = [System.IO.Path]::GetFileName($uri.LocalPath)
            if ([string]::IsNullOrEmpty($filename) -or -not ($filename -contains ".")) {
                $filename = "installer_" + (Get-Random) + ".exe"
            }
        }
        catch {
            $filename = "installer_" + (Get-Random) + ".exe"
        }

        $localPath = Join-Path $tempDir $filename
        Write-ErrorLog "Downloading installer to: $localPath"

        try {
            Invoke-WebRequest -Uri $InstallerPath -OutFile $localPath -TimeoutSec 300 -ErrorAction Stop
        }
        catch {
            throw "Failed to download installer from '$InstallerPath'. Error: $_"
        }

        if (-not (Test-Path $localPath)) {
            throw "Downloaded installer not found at path '$localPath'."
        }

        return $localPath
    }
    else {
        # Resolve local or UNC path
        if (-not (Test-Path -Path $InstallerPath)) {
            throw "Installer path '$InstallerPath' does not exist."
        }
        $resolved = Resolve-Path -Path $InstallerPath -ErrorAction SilentlyContinue
        if ($resolved) {
            return $resolved.Path
        }
        return $InstallerPath
    }
}

# Run external installer using Start-Process -Wait and timeout tracking
function Invoke-InstallerProcess {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Arguments,
        [int]$TimeoutSeconds = 1800
    )

    Write-ErrorLog "Executing process: $Path with args: $Arguments"
    
    $proc = $null
    try {
        if ($Path -eq "msiexec.exe") {
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $Arguments -PassThru -NoNewWindow
        }
        else {
            if (-not (Test-Path $Path)) {
                throw "Installer executable not found at '$Path'"
            }
            $proc = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru -NoNewWindow
        }

        $timeoutMs = $TimeoutSeconds * 1000
        $finished = $proc.WaitForExit($timeoutMs)

        if (-not $finished) {
            try {
                $proc.Kill()
            }
            catch {}
            throw "Process execution timed out after $TimeoutSeconds seconds."
        }

        $exitCode = $proc.ExitCode
        Write-ErrorLog "Process exited with code: $exitCode"
        return $exitCode
    }
    catch {
        throw "Failed to launch installer process: $_"
    }
}

# Perform installation
function Install-Application {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$InputConfig
    )

    $installerPath = Get-PropertySafe $InputConfig "InstallerPath"
    if ([string]::IsNullOrWhiteSpace($installerPath)) {
        throw "InstallerPath must be specified when Ensure is Present and application is missing."
    }

    $installerArguments = Get-PropertySafe $InputConfig "InstallerArguments"
    $rebootBehavior = Get-PropertySafe $InputConfig "RebootBehavior" "Ignore"
    $installTimeout = Get-PropertySafe $InputConfig "InstallTimeoutSeconds" 1800

    Write-ErrorLog "Installing application '$(Get-PropertySafe $InputConfig "Name")' from '$installerPath'..."
    
    $resolvedPath = Resolve-InstallerPath -InstallerPath $installerPath
    $extension = [System.IO.Path]::GetExtension($resolvedPath)

    $exePath = ""
    $args = ""

    if ($extension -eq ".msi") {
        $exePath = "msiexec.exe"
        $args = "/i `"$resolvedPath`""
        if (-not [string]::IsNullOrWhiteSpace($installerArguments)) {
            $args += " $installerArguments"
        }
    }
    elseif ($extension -eq ".exe") {
        $exePath = $resolvedPath
        $args = $installerArguments
    }
    else {
        throw "Unsupported installer file extension '$extension'. Only .msi and .exe are supported."
    }

    $exitCode = Invoke-InstallerProcess -Path $exePath -Arguments $args -TimeoutSeconds $installTimeout

    if ($exitCode -eq 0) {
        return @{ Success = $true; RebootRequired = $false; ExitCode = $exitCode }
    }
    elseif ($exitCode -eq 3010) {
        $rebootRequired = ($rebootBehavior -eq "RequireIfInstallerRequests")
        return @{ Success = $true; RebootRequired = $rebootRequired; ExitCode = $exitCode }
    }
    else {
        throw "Installer failed with exit code $exitCode"
    }
}

# Perform uninstallation
function Uninstall-Application {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$InstalledApp,
        [boolean]$AllowNonMsiUninstall = $false,
        [int]$TimeoutSeconds = 1800
    )

    $productCode = Get-PropertySafe $InstalledApp "ProductCode"
    $uninstallString = Get-PropertySafe $InstalledApp "UninstallString"

    if (-not [string]::IsNullOrEmpty($productCode)) {
        # MSI Uninstall
        Write-ErrorLog "Uninstalling MSI via ProductCode $productCode"
        $exe = "msiexec.exe"
        $args = "/x $productCode /qn /norestart"
        
        $exitCode = Invoke-InstallerProcess -Path $exe -Arguments $args -TimeoutSeconds $TimeoutSeconds
        if ($exitCode -ne 0 -and $exitCode -ne 3010) {
            throw "MSI Uninstallation failed with exit code $exitCode"
        }
        
        return @{ Success = $true; RebootRequired = ($exitCode -eq 3010); ExitCode = $exitCode }
    }
    else {
        # Non-MSI Uninstall
        if (-not $AllowNonMsiUninstall) {
            throw "Non-MSI uninstallation is requested for '$(Get-PropertySafe $InstalledApp "DisplayName")', but AllowNonMsiUninstall is false."
        }

        if ([string]::IsNullOrWhiteSpace($uninstallString)) {
            throw "No UninstallString found in registry for '$(Get-PropertySafe $InstalledApp "DisplayName")'."
        }

        $uninstallString = $uninstallString.Trim()
        $exePath = ""
        $args = ""

        # Parse command line safely
        if ($uninstallString.StartsWith('"')) {
            $closeQuoteIndex = $uninstallString.IndexOf('"', 1)
            if ($closeQuoteIndex -gt 0) {
                $exePath = $uninstallString.Substring(1, $closeQuoteIndex - 1)
                $args = $uninstallString.Substring($closeQuoteIndex + 1).Trim()
            }
            else {
                $exePath = $uninstallString.Replace('"', '')
            }
        }
        else {
            $firstSpace = $uninstallString.IndexOf(' ')
            if ($firstSpace -gt 0) {
                $exePath = $uninstallString.Substring(0, $firstSpace)
                $args = $uninstallString.Substring($firstSpace + 1).Trim()
            }
            else {
                $exePath = $uninstallString
            }
        }

        # Resolve exe path or fall back to cmd.exe /c
        $exe = $exePath
        if (-not (Test-Path $exePath)) {
            Write-ErrorLog "Warning: Uninstall path '$exePath' was not found. Executing raw string via cmd.exe."
            $exe = "cmd.exe"
            $args = "/c `"$uninstallString`""
        }

        $exitCode = Invoke-InstallerProcess -Path $exe -Arguments $args -TimeoutSeconds $TimeoutSeconds
        if ($exitCode -ne 0 -and $exitCode -ne 3010) {
            throw "Uninstallation failed with exit code $exitCode"
        }

        return @{ Success = $true; RebootRequired = ($exitCode -eq 3010); ExitCode = $exitCode }
    }
}

# Determine compliance state
function Test-InstalledApplicationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$InputConfig,
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$CurrentState
    )

    $desiredEnsure = Get-PropertySafe $InputConfig "Ensure" "Present"
    $minVersion = Get-PropertySafe $InputConfig "MinimumVersion"

    if ($desiredEnsure -eq "Present") {
        if (-not (Get-PropertySafe $CurrentState "Installed" $false)) {
            return $false
        }

        if (-not [string]::IsNullOrEmpty($minVersion)) {
            $currentVer = Get-PropertySafe $CurrentState "DisplayVersion"
            $cmp = Compare-Version -VersionA $currentVer -VersionB $minVersion
            if ($cmp -lt 0) {
                Write-ErrorLog "Version mismatch: installed version '$currentVer' is less than minimum version '$minVersion'"
                return $false
            }
        }
        return $true
    }
    else {
        return (-not (Get-PropertySafe $CurrentState "Installed" $false))
    }
}

# Export all installed applications from system
function Export-InstalledApplication {
    [CmdletBinding()]
    param()

    Write-ErrorLog "Gathering registry data for export..."

    $uninstallPaths = @(
        [PSCustomObject]@{ Path = "Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "x64" },
        [PSCustomObject]@{ Path = "Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "x86" },
        [PSCustomObject]@{ Path = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "Any" }
    )

    $apps = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($entry in $uninstallPaths) {
        $regPath = $entry.Path
        $psPath = $regPath
        if ($regPath.StartsWith("Registry::HKEY_LOCAL_MACHINE")) {
            $psPath = $regPath.Replace("Registry::HKEY_LOCAL_MACHINE", "HKLM:")
        }
        elseif ($regPath.StartsWith("Registry::HKEY_CURRENT_USER")) {
            $psPath = $regPath.Replace("Registry::HKEY_CURRENT_USER", "HKCU:")
        }

        if (-not (Test-Path -Path $psPath)) {
            continue
        }

        try {
            $subKeys = Get-ChildItem -Path $psPath -ErrorAction SilentlyContinue
            foreach ($subKey in $subKeys) {
                try {
                    $keyName = $subKey.PSChildName
                    $registryKeyPath = "$psPath\$keyName"
                    # Query without using fully-qualified path to allow Pester mocking
                    $properties = Get-ItemProperty -Path $registryKeyPath -ErrorAction SilentlyContinue
                    if ($null -eq $properties) { continue }

                    $displayName = Get-PropertySafe $properties "DisplayName"
                    if ([string]::IsNullOrWhiteSpace($displayName)) {
                        continue
                    }

                    $uninstallString = Get-PropertySafe $properties "UninstallString" ""
                    $detectedProductCode = $null
                    if ($keyName -match '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') {
                        $detectedProductCode = $keyName
                    }
                    elseif ($uninstallString -match '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}') {
                        $detectedProductCode = $Matches[0]
                    }

                    $instance = [ordered]@{
                        Name                 = $displayName
                        Ensure               = "Present"
                        Installed            = $true
                        DisplayName          = $displayName
                        DisplayVersion       = Get-PropertySafe $properties "DisplayVersion"
                        Publisher            = Get-PropertySafe $properties "Publisher"
                        InstallLocation      = Get-PropertySafe $properties "InstallLocation"
                        UninstallString      = $uninstallString
                        RegistryKeyPath      = $registryKeyPath
                        DetectedArchitecture = $entry.Arch
                    }
                    if ($detectedProductCode) {
                        $instance["ProductCode"] = $detectedProductCode
                    }

                    $apps.Add([PSCustomObject]$instance)
                }
                catch {}
            }
        }
        catch {}
    }

    foreach ($app in $apps) {
        $json = ConvertTo-Json -InputObject $app -Compress -Depth 5
        [Console]::Out.WriteLine($json)
    }
}
