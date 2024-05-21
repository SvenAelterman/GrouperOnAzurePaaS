<#
.SYNOPSIS
    Performs a deployment of the Azure resources that are prerequisites for the main.bicep file.

.DESCRIPTION
    Use this for manual deployments only.
    If using a CI/CD pipeline, specify the necessary parameters in the pipeline definition.

.PARAMETER TemplateParameterFile
    The path to the template parameter file in bicepparam format.

.PARAMETER TargetSubscriptionId
    The subscription ID to deploy the resources to. The subscription must already exist.

.PARAMETER Location
    The Azure region to deploy the resources to.

.EXAMPLE
    ./deploy.ps1 -TemplateParameterFile './bootstrap.bicepparam' -TargetSubscriptionId '00000000-0000-0000-0000-000000000000' -Location 'eastus' 

.EXAMPLE
    ./deploy.ps1 './bootstrap.bicepparam' '00000000-0000-0000-0000-000000000000' 'eastus' -BuildGrouperContainer $true -GenerateDatabasePassword $true -GenerateGrouperMorphStringEncryptKey $true
#>

# LATER: Be more specific about the required modules; it will speed up the initial call
#Requires -Modules "Az"
#Requires -PSEdition Core

[CmdletBinding()]
Param(
    [Parameter(Position = 1)]
    [string]$TemplateParameterFile = './bootstrap.bicepparam',
    [Parameter(Mandatory, Position = 2)]
    [string]$TargetSubscriptionId,
    [Parameter(Mandatory, Position = 3)]
    [string]$Location,
    [Parameter(Position = 4)]
    [string]$Environment = 'AzureCloud',
    [Parameter()]
    [bool]$BuildGrouperContainer = $false,
    [Parameter()]
    [bool]$GenerateDatabasePassword = $false,
    [Parameter()]
    [bool]$GenerateGrouperMorphStringEncryptKey = $false,
    [Parameter()]
    [bool]$GenerateGrouperSystemPassword = $false
)

# Process the template parameter file and read relevant values for use here
Write-Verbose "Using template parameter file '$TemplateParameterFile'"
[string]$TemplateParameterJsonFile = [System.IO.Path]::ChangeExtension($TemplateParameterFile, 'json')
bicep build-params $TemplateParameterFile --outfile $TemplateParameterJsonFile

# Define common parameters for the New-AzDeployment cmdlet
[hashtable]$CmdLetParameters = @{
    TemplateFile          = './bootstrap.bicep'
    TemplateParameterFile = $TemplateParameterJsonFile
    Location              = $Location
}

# Read the values from the parameters file, to use when generating the $DeploymentName value
$ParameterFileContents = (Get-Content $TemplateParameterJsonFile | ConvertFrom-Json)
$WorkloadName = $ParameterFileContents.parameters.workloadName.value

# Generate a unique name for the deployment
[string]$DeploymentName = "$WorkloadName-$(Get-Date -Format 'yyyyMMddThhmmssZ' -AsUTC)"
$CmdLetParameters.Add('Name', $DeploymentName)

# Import the Azure subscription management module
Import-Module .\scripts\PowerShell\Modules\AzSubscriptionManagement.psm1

# Determine if a cloud context switch is required
Set-AzContextWrapper -SubscriptionId $TargetSubscriptionId -Environment $Environment

# Remove the module from the session
Remove-Module AzSubscriptionManagement -WhatIf:$false

if ($GenerateDatabasePassword -or $GenerateGrouperMorphStringEncryptKey) {
    Import-Module .\scripts\PowerShell\Modules\Generate-Password.psm1
    
    if ($GenerateDatabasePassword) {
        [securestring]$NewDatabasePassword = New-RandomPassword -Length 32
        [securestring]$DatabaseLogin = ConvertTo-SecureString -String 'dbadmin' -AsPlainText -Force

        $CmdLetParameters.Add('databaseLogin', $DatabaseLogin)
        $CmdLetParameters.Add('databasePassword', $NewDatabasePassword)
    }

    if ($GenerateGrouperMorphStringEncryptKey) {
        [securestring]$NewGrouperMorphStringEncryptKey = New-RandomPassword -Length 15

        $CmdLetParameters.Add('grouperMorphStringEncryptKey', $NewGrouperMorphStringEncryptKey)
    }

    if ($GenerateGrouperSystemPassword) {
        [securestring]$NewGrouperSystemPassword = New-RandomPassword -Length 25

        $CmdLetParameters.Add('grouperSystemPassword', $NewGrouperSystemPassword)
    }

    Remove-Module Generate-Password -WhatIf:$false
}

# Execute the deployment
$DeploymentResult = New-AzDeployment @CmdLetParameters

Remove-Item $TemplateParameterJsonFile

# Evaluate the deployment results
if ($DeploymentResult.ProvisioningState -eq 'Succeeded') {
    Write-Host "🔥 Azure Deployment succeeded."

    if ($BuildGrouperContainer) {
        $ContainerRegistryName = $DeploymentResult.Outputs['containerRegistryName'].Value

        Write-Host "🛳️  Building Grouper custom container and push to $ContainerRegistryName..."

        # The following must be done with the AZ CLI, as the Azure PowerShell modules do not support ACR build
        az account set --subscription (Get-AzContext).Subscription.Id
        az acr build --image umb/grouper:latest --registry $ContainerRegistryName --file ./grouper/Dockerfile ./grouper/
    }

    $DeploymentResult.Outputs | Format-Table -Property Key, @{Name = 'Value'; Expression = { $_.Value.Value } }
}
else {
    $DeploymentResult
}
