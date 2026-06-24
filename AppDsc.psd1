#
# Module manifest for AppDsc
#

@{
    ModuleToProcess   = 'AppDsc.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'bc25d7c5-555e-4c31-9f93-8fce972740a3'    
    Description       = 'PowerShell DSC v3 module for managing installed Windows applications.'
    PowerShellVersion = '5.1'
    
    # Functions to export from this module
    FunctionsToExport = @(
        'Get-InstalledApplication',
        'Test-InstalledApplicationState',
        'Install-Application',
        'Uninstall-Application',
        'Compare-Version',
        'Get-PropertySafe',
        'Read-DscInput',
        'Write-DscOutput',
        'Export-InstalledApplication'
    )
    
    # Cmdlets to export from this module
    CmdletsToExport = '*'
    
    # Variables to export from this module
    VariablesToExport = '*'
    
    # Aliases to export from this module
    AliasesToExport = '*'
    
    PrivateData = @{
        PSData = @{
            # Tags applied to this module
            Tags = @('DSC', 'DSCv3', 'Windows', 'AppManager')
        }
    }
}
