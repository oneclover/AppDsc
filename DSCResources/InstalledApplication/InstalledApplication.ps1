#
# InstalledApplication.ps1 - DSC v3 Command Resource Entry Point
#

Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot "../../AppDsc.psd1"
if (-not (Test-Path $modulePath)) {
    [Console]::Error.WriteLine("Error: Could not locate AppDsc module at '$modulePath'")
    exit 1
}

Import-Module -Name $modulePath -Force

$operation = $args[0]
if ([string]::IsNullOrEmpty($operation)) {
    [Console]::Error.WriteLine("Error: Operation argument (get|test|set|export) is required.")
    exit 1
}

# Define local Get-CurrentResourceState helper to map config to state
function Get-CurrentResourceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$InputConfig
    )

    $name = Get-PropertySafe $InputConfig "Name"
    $productCode = Get-PropertySafe $InputConfig "ProductCode"
    $displayNameRegex = Get-PropertySafe $InputConfig "DisplayNameRegex"
    $architecture = Get-PropertySafe $InputConfig "Architecture" "Any"
    $detectionMethod = Get-PropertySafe $InputConfig "DetectionMethod" "Registry"
    $customDetectionScript = Get-PropertySafe $InputConfig "CustomDetectionScript"

    $installedApp = $null
    $installed = $false

    if ($detectionMethod -eq "CustomScript") {
        if ([string]::IsNullOrWhiteSpace($customDetectionScript)) {
            throw "CustomDetectionScript must be supplied when DetectionMethod is CustomScript"
        }
        $script = [scriptblock]::Create($customDetectionScript)
        $installed = [bool](& $script)
        
        # Try to find registry details if they match, but it's optional
        $installedApp = Get-InstalledApplication -Name $name -ProductCode $productCode -DisplayNameRegex $displayNameRegex -Architecture $architecture
    }
    elseif ($detectionMethod -eq "ProductCode") {
        if ([string]::IsNullOrWhiteSpace($productCode)) {
            throw "ProductCode must be supplied when DetectionMethod is ProductCode"
        }
        $installedApp = Get-InstalledApplication -ProductCode $productCode -Architecture $architecture
        $installed = ($null -ne $installedApp)
    }
    else { # Registry
        $installedApp = Get-InstalledApplication -Name $name -ProductCode $productCode -DisplayNameRegex $displayNameRegex -Architecture $architecture
        $installed = ($null -ne $installedApp)
    }

    $result = [ordered]@{
        Name                 = $name
        Ensure               = if ($installed) { "Present" } else { "Absent" }
        Installed            = $installed
        DisplayName          = if ($installedApp) { $installedApp.DisplayName } else { $null }
        DisplayVersion       = if ($installedApp) { $installedApp.DisplayVersion } else { $null }
        Publisher            = if ($installedApp) { $installedApp.Publisher } else { $null }
        InstallLocation      = if ($installedApp) { $installedApp.InstallLocation } else { $null }
        UninstallString      = if ($installedApp) { $installedApp.UninstallString } else { $null }
        RegistryKeyPath      = if ($installedApp) { $installedApp.RegistryKeyPath } else { $null }
        DetectedArchitecture = if ($installedApp) { $installedApp.Architecture } else { $null }
    }

    return [PSCustomObject]$result
}

try {
    switch ($operation.ToLowerInvariant()) {
        "get" {
            $inputConfig = Read-DscInput
            if ($null -eq $inputConfig) {
                throw "Failed to read configuration input from stdin."
            }
            if ([string]::IsNullOrWhiteSpace($inputConfig.Name)) {
                throw "Missing required property: 'Name'"
            }
            $currentState = Get-CurrentResourceState -InputConfig $inputConfig
            Write-DscOutput -Payload $currentState
        }
        "test" {
            $inputConfig = Read-DscInput
            if ($null -eq $inputConfig) {
                throw "Failed to read configuration input from stdin."
            }
            if ([string]::IsNullOrWhiteSpace($inputConfig.Name)) {
                throw "Missing required property: 'Name'"
            }
            $currentState = Get-CurrentResourceState -InputConfig $inputConfig
            $inDesiredState = Test-InstalledApplicationState -InputConfig $inputConfig -CurrentState $currentState
            
            $result = [ordered]@{
                desiredState   = $inputConfig
                actualState    = $currentState
                inDesiredState = $inDesiredState
            }
            Write-DscOutput -Payload $result
        }
        "set" {
            $inputConfig = Read-DscInput
            if ($null -eq $inputConfig) {
                throw "Failed to read configuration input from stdin."
            }
            if ([string]::IsNullOrWhiteSpace($inputConfig.Name)) {
                throw "Missing required property: 'Name'"
            }

            $beforeState = Get-CurrentResourceState -InputConfig $inputConfig
            $inDesiredState = Test-InstalledApplicationState -InputConfig $inputConfig -CurrentState $beforeState
            
            $rebootRequired = $false

            if ($inDesiredState) {
                Write-ErrorLog "Application '$($inputConfig.Name)' is already in desired state. No changes required."
                $afterState = $beforeState
            }
            else {
                $desiredEnsure = if ($inputConfig.Ensure) { $inputConfig.Ensure } else { "Present" }
                
                if ($desiredEnsure -eq "Present") {
                    $installResult = Install-Application -InputConfig $inputConfig
                    $rebootRequired = $installResult.RebootRequired
                }
                else {
                    # Absent
                    $allowNonMsi = if ($null -ne $inputConfig.AllowNonMsiUninstall) { [bool]$inputConfig.AllowNonMsiUninstall } else { $false }
                    $installTimeout = if ($null -ne $inputConfig.InstallTimeoutSeconds) { $inputConfig.InstallTimeoutSeconds } else { 1800 }

                    # Try to locate the app again to retrieve its UninstallString or ProductCode
                    $detectionMethod = if ($inputConfig.DetectionMethod) { $inputConfig.DetectionMethod } else { "Registry" }
                    $installedApp = $null
                    if ($detectionMethod -eq "ProductCode") {
                        $installedApp = Get-InstalledApplication -ProductCode $inputConfig.ProductCode -Architecture $inputConfig.Architecture
                    }
                    else {
                        $installedApp = Get-InstalledApplication -Name $inputConfig.Name -ProductCode $inputConfig.ProductCode -DisplayNameRegex $inputConfig.DisplayNameRegex -Architecture $inputConfig.Architecture
                    }

                    if ($null -eq $installedApp) {
                        throw "Could not find registry details to perform uninstallation for '$($inputConfig.Name)'."
                    }

                    $uninstallResult = Uninstall-Application -InstalledApp $installedApp -AllowNonMsiUninstall $allowNonMsi -TimeoutSeconds $installTimeout
                    $rebootRequired = $uninstallResult.RebootRequired
                }

                # Get final state
                $afterState = Get-CurrentResourceState -InputConfig $inputConfig
            }

            $result = [ordered]@{
                beforeState    = $beforeState
                afterState     = $afterState
                rebootRequired = $rebootRequired
            }
            Write-DscOutput -Payload $result
        }
        "export" {
            Export-InstalledApplication
        }
        default {
            throw "Invalid operation: '$operation'. Supported operations are: get, test, set, export."
        }
    }
}
catch {
    [Console]::Error.WriteLine("Error: $_")
    exit 1
}
