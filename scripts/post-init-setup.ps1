<#
    .SYNOPSIS
        Finalize the setup after the execution of the 'azd init' command or the fork of the GitHub repository.
    .DESCRIPTION
        - Get default environment name (from the 'config.json' file under the '.azure' folder)
        - Get the Azure subscription configured for the default environment (from the '.env' file)
        - Create an app registration to manage the solution deployment to the considered Azure subscription
        - Create an app registration to interact with the Dataverse environment
        - Create a Dataverse environment
        - Add the app registration as an application user to the Dataverse environment
        - Update the environment definition ('env' file under the '.azure' folder)
    .INPUTS
        None.
    .OUTPUTS
        None.
    .EXAMPLE
        PS> .\post-init-setup.ps1
    .LINK
        https://github.com/rpothin/servicebus-csharp-function-dataverse
    .NOTES
        This script:
        - need to be exectuded at the root level of the "Azure Developer CLI" compatible folder
        - will first run some validations then do the steps described in the "Description" section
#>

[CmdletBinding()] param ()

#region Variables initialization

$azureEnvironmentsFolderBasePath = "..\.azure\"
$azureEnvironmentsConfigurationFilePath = $azureEnvironmentsFolderBasePath + "config.json"
$environmentConfigurationFileName = "\.env"

$azureSubscriptionIdEnvironmentVariableName = "AZURE_SUBSCRIPTION_ID"

$rolesToAssignOnAzureSubscription = @("Contributor", "User Access Administrator")

$dataverseEnvironmentConfigurationFilePath = "..\.dataverse\environment-configuration.json"

#endregion Variables initialization

#region Validate that the required CLI are installed

# Azure CLI - https://learn.microsoft.com/en-us/cli/azure/
Write-Verbose "Checking if Azure CLI is installed..."
try {
    $azureCliVersion = az version
    Write-Verbose "👍🏼 Azure CLI is installed!"
} catch {
    Write-Error -Message "Error checking if Azure CLI is installed" -ErrorAction Stop
}

# Azure Developer CLI - https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/overview
Write-Verbose "Checking if Azure Developer CLI is installed..."
try {
    $azureDeveloperCliVersion = azd version
    Write-Verbose "👍🏼 Azure Developer CLI is installed!"
} catch {
    Write-Error -Message "Error checking if Azure Developer CLI is installed" -ErrorAction Stop
}

# Power Platform CLI -https://learn.microsoft.com/en-us/power-platform/developer/cli/introduction
Write-Verbose "Checking if Power Platform CLI is installed..."
try {
    $powerPlatformCliVersion = pac help
    Write-Verbose "👍🏼 Power Platform CLI is installed!"
} catch {
    Write-Error -Message "Error checking if Power Platform CLI is installed" -ErrorAction Stop
}

#endregion Validate that the required CLI are installed

#region Validate the connections

# Azure CLI
Write-Verbose "Checking Azure CLI connection status..."
$azureSignedInUserMail = ""
try {
    $azureSignedInUser = az ad signed-in-user show --query '[id, mail]' --output tsv
    $azureSignedInUserMail = $azureSignedInUser[1]
} catch {
    # Do nothing
}

if ([string]::IsNullOrEmpty($azureSignedInUserMail)) {
    Write-Verbose "No signed in user found for Azure CLI. Please login..."
    $azureCliLoginResult = az login --use-device-code
    $azureSignedInUser = az ad signed-in-user show --query '[id, mail]' --output tsv
    $azureSignedInUserMail = $azureSignedInUser[1]
}

Write-Verbose "👍🏼 Connected to Azure CLI!"

# Power Platform CLI
Write-Verbose "Checking Power Platform CLI connection status..."
$pacProfiles = pac auth list

if ($pacProfiles -eq "No profiles were found on this computer. Please run 'pac auth create' to create one.") {
    Write-Verbose "No profile found for Power Platform CLI. Please create a profile..."
    $powerPlatformCliAuthCreateResult = pac auth create
}

Write-Verbose "👍🏼 Connected to Power Platform CLI!"

#endregion Validate the connections

#region Get default environment name

# Validate there is a 'config.json' file under a '.azure' folder
Write-Verbose "Checking the presence of a 'config.json' file under a '.azure' folder..."
if (!(Test-Path $azureEnvironmentsConfigurationFilePath)) {
    Write-Verbose "No 'config.json' file found under a '.azure' folder. Please configure an environment..."
    azd env new
}

# Get default environment from 'config.json' file under '.azure' folder
Write-Verbose "Getting the default environment the 'config.json' file under the '.azure' folder..."
try {
    $azureEnvironmentsConfiguration = Get-Content $azureEnvironmentsConfigurationFilePath | ConvertFrom-Json
    $azureDefaultEnvironmentName = $azureEnvironmentsConfiguration.defaultEnvironment
} catch {
    Write-Error -Message "Error getting the default environment name from the 'config.json' file under the '.azure' folder" -ErrorAction Stop
}

Write-Host "Default environment: $azureDefaultEnvironmentName" -ForegroundColor Blue

$response = Read-Host "Do you want to use the above environment? (Y/N)"

if (!($response.ToLower() -eq "y")) {
    Write-Host "Use the 'azd env select' command to set the default environment you'd like to use and re-run this script."
    Exit
}

#endregion Get default environment name

#region Get default environment details

# Validate there is a '.env' file under the default environment configuration folder
Write-Verbose "Checking the presence of a '.env' file under the $azureDefaultEnvironmentName configuration folder..."
$azureDefaultEnvironmentConfigurationFilePath = $azureEnvironmentsFolderBasePath + $azureDefaultEnvironmentName + $environmentConfigurationFileName
if (!(Test-Path $azureDefaultEnvironmentConfigurationFilePath)) {
    Write-Error -Message "No '.env' file under the $azureDefaultEnvironmentName configuration folder" -ErrorAction Stop
}

# Get default environment details from '.env' file under the default environment configuration folder
Write-Verbose "Getting the default environment details from '.env' file under the default environment configuration folder..."
try {
    $azureDefaultEnvironmentDetails = Get-Content $azureDefaultEnvironmentConfigurationFilePath
    
    foreach ($azureDefaultEnvironmentDetail in $azureDefaultEnvironmentDetails) {
        $azureDefaultEnvironmentDetailSplitted = $azureDefaultEnvironmentDetail.Split('=')

        if ($azureDefaultEnvironmentDetailSplitted[0] -eq $azureSubscriptionIdEnvironmentVariableName) {
            $azureDefaultEnvironmentSubscriptionId = $azureDefaultEnvironmentDetailSplitted[1].replace("""", "")
        }
    }
} catch {
    Write-Error -Message "Error getting the default environment details from '.env' file under the default environment configuration folder" -ErrorAction Stop
}

#endregion Get default environment details

#region Validate the Azure subscription configured on the default environment

# Validate the account to use for the configuration of the considered Azure subscription
Write-Host "Account considered for the configuration of the considered Azure subscription: $azureSignedInUserMail" -ForegroundColor Blue
$response = Read-Host "Do you want to use this account for this operation? (Y/N)"

if (!($response.ToLower() -eq "y")) {
    Write-Host "Connection to Azure CLI with the account you want to use for this operation..."
    $azureCliLoginResult = az login --use-device-code
    $azureSignedInUser = az ad signed-in-user show --query '[id, mail]' --output tsv
    $azureSignedInUserMail = $azureSignedInUser[1]
}

# Get the name of the Azure subscription configured for the default environment
$azureDefaultEnvironmentSubscriptionDisplayName = az account subscription show --id $azureDefaultEnvironmentSubscriptionId --query 'displayName' --output tsv

Write-Host "Default environment Azure subscription ID: '$azureDefaultEnvironmentSubscriptionDisplayName' ($azureDefaultEnvironmentSubscriptionId)" -ForegroundColor Blue

$response = Read-Host "Do you want to use the above Azure subscription? (Y/N)"

if (!($response.ToLower() -eq "y")) {
    Write-Host "Use the 'azd env set' command to set the Azure subscription you'd like to use with the default environment and re-run this script."
    Exit
}

#endregion Validate the Azure subscription configured on the default environment

#region Create a service principal to manage the solution deployment to the considered Azure subscription

# Check if an app registration with the same name exists, if not create one
$azureDeploymentAppRegistrationName = "sp-$azureDefaultEnvironmentName-azure"

Write-Verbose "Checking if an '$azureDeploymentAppRegistrationName' app registration already exist..."
$azureDeploymentAppRegistrationListResult = az ad app list --filter "displayName eq '$azureDeploymentAppRegistrationName'" --query '[[].id, [].appId]' --output tsv
$azureDeploymentAppRegistrationObjectId = $azureDeploymentAppRegistrationListResult[0]
$azureDeploymentAppRegistrationId = $azureDeploymentAppRegistrationListResult[1]

if ([string]::IsNullOrEmpty($azureDeploymentAppRegistrationId)) {
    Write-Verbose "No '$azureDeploymentAppRegistrationName' app registration found. Creating app registration..."
    $azureDeploymentAppRegistrationCreationResult = az ad app create --display-name $azureDeploymentAppRegistrationName --query --query '[id, appId]' --output tsv
    $azureDeploymentAppRegistrationObjectId = $azureDeploymentAppRegistrationCreationResult[0]
    $azureDeploymentAppRegistrationId = $azureDeploymentAppRegistrationCreationResult[1]
    Write-Verbose "👍🏼 '$azureDeploymentAppRegistrationName' app registration created!"
} else {
    Write-Verbose "Existing '$azureDeploymentAppRegistrationName' app registration found."
}

# Check if a service principal with the same name exists, if not create one
Write-Verbose "Checking if a '$azureDeploymentAppRegistrationName' service principal already exist..."
$azureDeploymentServicePrincipalId = az ad sp list --filter "appId eq '$azureDeploymentAppRegistrationId'" --query [].id --output tsv

if ([string]::IsNullOrEmpty($azureDeploymentServicePrincipalId)) {
    Write-Verbose "No '$azureDeploymentAppRegistrationName' service principal found. Creating service principal..."
    $azureDeploymentServicePrincipalId = az ad sp create --id $azureDeploymentAppRegistrationId --query id --output tsv
    Write-Verbose "👍🏼 '$azureDeploymentAppRegistrationName' service principal created!"
} else {
    Write-Verbose "Existing '$azureDeploymentAppRegistrationName' service principal found."
}

# Create role assignments for the service principal on the considered Azure subscription
Write-Verbose "Role assignments creation for the '$azureDeploymentAppRegistrationName' service principal on the '$azureDefaultEnvironmentSubscriptionDisplayName' Azure subscription..."
foreach ($roleToAssignOnAzureSubscription in $rolesToAssignOnAzureSubscription) {
    Write-Verbose "Creation of an assignment for the role '$roleToAssignOnAzureSubscription'..."
    $roleAssignmentCreationResult = az role assignment create --subscription $azureDefaultEnvironmentSubscriptionId --role $roleToAssignOnAzureSubscription --assignee-object-id $azureDeploymentServicePrincipalId --assignee-principal-type ServicePrincipal
    Write-Verbose "👍🏼 '$roleToAssignOnAzureSubscription' role has been assigned!"
}

# Add service principal name as an environment variable to the default environment
Write-Verbose "Add service principal name to the '.env' file of the default environment..."
azd env set AZURE_SERVICE_PRINCIPAL_NAME $azureDeploymentAppRegistrationName
Write-Verbose "👍🏼 Service principal name added to the '.env' file of the default environment!"

#endregion Create a service principal to manage the solution deployment to the considered Azure subscription

#region Create a service principal to be assigned as an application user to the considered Dataverse environment

# Validate the account to use for the creation of the service principal to manage the integration with the Dataverse environment
Write-Host "Account considered for creation of the service principal to manage the integration with the Dataverse environment: $azureSignedInUserMail" -ForegroundColor Blue
$response = Read-Host "Do you want to use this account for this operation? (Y/N)"

if (!($response.ToLower() -eq "y")) {
    Write-Host "Connection to Azure CLI with the account you want to use for this operation..."
    $azureCliLoginResult = az login --use-device-code --allow-no-subscriptions
    $azureSignedInUser = az ad signed-in-user show --query '[id, mail]' --output tsv
    $azureSignedInUserMail = $azureSignedInUser[1]
}

# Check if an app registration with the same name exists, if not create one
$dataverseAppRegistrationName = "sp-$azureDefaultEnvironmentName-dataverse"

Write-Verbose "Checking if an '$dataverseAppRegistrationName' app registration already exist..."
$dataverseAppRegistrationId = az ad app list --filter "displayName eq '$dataverseAppRegistrationName'" --query [].appId --output tsv

if ([string]::IsNullOrEmpty($dataverseAppRegistrationId)) {
    Write-Verbose "No '$dataverseAppRegistrationName' app registration found. Creating app registration..."
    $dataverseAppRegistrationId = az ad app create --display-name $dataverseAppRegistrationName --query appId --output tsv
    Write-Verbose "👍🏼 '$dataverseAppRegistrationName' app registration created!"
} else {
    Write-Verbose "Existing '$dataverseAppRegistrationName' app registration found."
}

# Check if a service principal with the same name exists, if not create one
Write-Verbose "Checking if a '$dataverseAppRegistrationName' service principal already exist..."
$dataverseServicePrincipalId = az ad sp list --filter "appId eq '$dataverseAppRegistrationId'" --query [].id --output tsv

if ([string]::IsNullOrEmpty($dataverseServicePrincipalId)) {
    Write-Verbose "No '$dataverseAppRegistrationName' service principal found. Creating service principal..."
    $dataverseServicePrincipalId = az ad sp create --id $dataverseAppRegistrationId --query id --output tsv
    Write-Verbose "👍🏼 '$dataverseAppRegistrationName' service principal created!"
} else {
    Write-Verbose "Existing '$dataverseAppRegistrationName' service principal found."
}

# Reset credential on service principal
Write-Verbose "Reset credential on the '$dataverseAppRegistrationName' service principal..."
$dataverseServicePrincipalCredentialResetResult = az ad sp credential reset --id $dataverseAppRegistrationId --display-name "azd - dataverse - $azureDefaultEnvironmentName" | ConvertFrom-Json
$dataverseServicePrincipalPassword = $dataverseServicePrincipalCredentialResetResult.password

if (![string]::IsNullOrEmpty($dataverseServicePrincipalPassword)) {
    Write-Verbose "👍🏼 Credendial reset for the '$dataverseAppRegistrationName' service principal completed!"
} else {
    Write-Warning "Error during credendial reset for the '$dataverseAppRegistrationName' service principal."
}

# Add application registration name as an environment variable to the default environment
Write-Verbose "Add application registration name to the '.env' file of the default environment..."
azd env set DATAVERSE_SERVICE_PRINCIPAL_NAME $dataverseAppRegistrationName
Write-Verbose "👍🏼 Application registration name added to the '.env' file of the default environment!"

# Add application registration id as an environment variable to the default environment
Write-Verbose "Add application registration id to the '.env' file of the default environment..."
azd env set DATAVERSE_CLIENT_ID $dataverseAppRegistrationId
Write-Verbose "👍🏼 Application registration id added to the '.env' file of the default environment!"

# Add service principal password as an environment variable to the default environment
Write-Verbose "Add service principal password to the '.env' file of the default environment..."
azd env set DATAVERSE_CLIENT_SECRET $dataverseServicePrincipalPassword
Write-Verbose "👍🏼 Service principal password added to the '.env' file of the default environment!"

#endregion Create a service principal to be assigned as an application user to the considered Dataverse environment

#region Get Dataverse environment URL

$dataverseEnvironmentUrl = ""

# Ask for the URL of the Dataverse environment to consider
$response = Read-Host "Please, enter the URL of the Dataverse environment to consider or just press enter so an environment can be created"

if ([string]::IsNullOrEmpty($response)) {
    # Test the path provided to the file with the configurations
    Write-Verbose "Test the path provided to the file with the configuration: $dataverseEnvironmentConfigurationFilePath"
    $testPathResult = Test-Path $dataverseEnvironmentConfigurationFilePath
    if(!$testPathResult) {
        Write-Error -Message "Following path to configuration file not valid: $dataverseEnvironmentConfigurationFilePath" -ErrorAction Stop
    }
    
    # Extract configuration from the file
    Write-Verbose "Get content from file with the configurations in the following location: $dataverseEnvironmentConfigurationFilePath"
    try {
        $dataverseEnvironmentConfiguration = Get-Content $dataverseEnvironmentConfigurationFilePath -ErrorVariable getConfigurationError -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Write-Error -Message "Error in the extraction of the configuration from the considered file ($dataverseEnvironmentConfigurationFilePath): $getConfigurationError" -ErrorAction Stop
    }

    $dataverseEnvironmentConfiguration

    $response = Read-Host "Are you OK with this configuration? (Y/N)"

    if (!($response.ToLower() -eq "y")) {
        Write-Host "Please review and update the configuration in the following file: $dataverseEnvironmentConfigurationFilePath"
    } else {
        $dataverseEnvironmentName = $dataverseEnvironmentConfiguration.namePrefix + $azureDefaultEnvironmentName
        $dataverseEnvironmentDomain = $dataverseEnvironmentConfiguration.domainPrefix + $azureDefaultEnvironmentName.ToLower()
        Write-Verbose "Create '$dataverseEnvironmentName' ($dataverseEnvironmentDomain) Dataverse environment..."
        
        $dataverseEnvironmentType = $dataverseEnvironmentConfiguration.type
        $dataverseEnvironmentRegion = $dataverseEnvironmentConfiguration.region
        $dataverseEnvironmentLanguage = $dataverseEnvironmentConfiguration.language
        $dataverseEnvironmentCurrency = $dataverseEnvironmentConfiguration.currency
        
        $dataverseEnvironmentCreationResult = pac admin create --name "$dataverseEnvironmentName" --domain "$dataverseEnvironmentDomain" --type "$dataverseEnvironmentType" --region "$dataverseEnvironmentRegion" --language "$dataverseEnvironmentLanguage" --currency "$dataverseEnvironmentCurrency"

        $dataverseEnvironmentCreationResultLineWithUrlSplitted = $dataverseEnvironmentCreationResult[5].split(" ")
        $dataverseEnvironmentUrl = $dataverseEnvironmentCreationResultLineWithUrlSplitted[0]
    }
} else {
    $dataverseEnvironmentUrl = $response
}

# Add Dataverse environment URL as an environment variable to the default environment
Write-Verbose "Add Dataverse environment URL to the '.env' file of the default environment..."
azd env set DATAVERSE_ENV_URL $dataverseEnvironmentUrl
Write-Verbose "👍🏼 Dataverse environment URL added to the '.env' file of the default environment!"

#endregion Get Dataverse environment URL

#region Assign service principal as an application user to the considered Dataverse environment

# Todo
# Use pac admin assign-user command

#endregion Assign service principal as an application user to the considered Dataverse environment