<#
 .SYNOPSIS
  Exports tags/values from Azure Resources to a CSV.

 .DESCRIPTION
  Exports the tags/values for either one resource or all resources of a certain resource type to a CSV. The resourceTypes are listed as input variables and can be expanded with your additional resource types

 .PARAMETER subscriptionId
  [optional] The Object ID of an Azure Subcription

.PARAMETER tenantId
  [optional] The tenant ID of the Azure tenant (for non-interactive authentication towards Azure)

.PARAMETER clientId
  [optional] The client ID of the service principal (for non-interactive authentication towards Azure)

.PARAMETER clientSecret
  [optional] The client secret of the service principal (for non-interactive authentication towards Azure)      

.PARAMETER resourceGroup
  [optional] The name of the resource group where the resource exists (when exporting tags/values for a single resource)

.PARAMETER resourceName
  [optional] The name of the resource in Azure (when exporting tags/values for a single resource)

.PARAMETER resourceType
  [required] The name of the predefined resource types in Azure    

.EXAMPLE
    # Export tags for all resource types - Interactive sign-in. WARNING: THIS IS SLOW DUE TO THE AMOUNT OF RESOURCE TYPES!
   Export-AzureTags -allResourceTypes

.EXAMPLE
    # Export tags for 1 resource type - Interactive sign-in.
   Export-AzureTags -resourceType Microsoft.Compute/virtualMachines   

.EXAMPLE
   # Export tags for a particular resource - Interactive sign-in
   Export-AzureTags -subscriptionId '00000000-0000-0000-0000-000000000000' -resourceGroup 'rg-vm-mgt-prd-001' -resourceName 'vmmgt01' -resourceType Microsoft.Compute/virtualMachines

.EXAMPLE
   # Export tags for a particular resource - Non-Interactive sign-in
   Export-AzureTags -subscriptionId '00000000-0000-0000-0000-000000000000' -resourceGroup 'rg-vm-mgt-prd-001' -resourceName 'vmmgt01' -resourceType Microsoft.Compute/virtualMachines -tenantId "00000000-0000-0000-0000-000000000000" -clientId "00000000-0000-0000-0000-000000000000" -clientSecret "00000000-0000-0000-0000-000000000000"  

.OUTPUTS
    One or more CSV files (per Resource Type).

.NOTES
    Author: Armand Hatting
    Date:   March 20, 2025

#>

param(
    [Parameter(Mandatory=$false)][string]$subscriptionId,
    [Parameter(Mandatory=$false)][string]$resourceName,
    [Parameter(Mandatory=$false)][string]$resourceGroupName,
    [Parameter(Mandatory=$false)][string]$tenantId,
    [Parameter(Mandatory=$false)][string]$clientId,
    [Parameter(Mandatory=$false)][string]$clientSecret,
    [Parameter(Mandatory=$false)][switch]$allResourceTypes,
    [Parameter(Mandatory=$false)][string]$resourceType
)

# variables
$exportFileNamePrefix = "$($resourceType.Replace('/','.')).Tags-"


#region connect to Azure
try {
    # Get the current context
    $context = Get-AzContext  
    # if no context is found, try to connect
    if (!$context)   
    {  
        if ($clientId -and $clientSecret) {
            # non-interactive
            Write-Verbose "Using non-interactive sign-in to Azure"
            $securePassword = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
            $tenantId = $tenantId
            $applicationId = $clientId
            $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $ApplicationId, $SecurePassword
            Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $Credential -ErrorAction Stop
        } else {
            # interactive
            Write-Verbose "Using interactive sign-in to Azure"
            Connect-AzAccount -ErrorAction Stop
        }
    }   
    else   
    {  
        # already connected
        Write-Verbose "Skipping authentication, already connected"  
    } 
} catch {
    Write-Error "Failed to connect to Azure: $($_.Exception.Message)"
    exit 1
}
#endregion

#region function(s)
function exportTags {
    param(
        [Parameter(Mandatory=$true)][string]$inputResourceType
    )

    try{
        if($subscriptionId){

            # Get 1 subscription
            $subs = Get-AzSubscription -SubscriptionId $subscriptionId
        }
        else{

            # Get All Subscriptions
            $subs = Get-AzSubscription

        }
    }
    catch{
        Write-Error "Failed to get subscriptions: $($_.Exception.Message)"
        exit 1
    }

    # New Empty Array to store resource configuration details
    $ResourceDetails = @()
    $allTagKeys = @()

    # Loop through subscription
    foreach ($sub in $subs) {
        # Display the current processing subscription
        Write-Verbose "Processing subscription $($sub.Name)"

        try {
            # Select the subscription
            # Add conditions here if you want to skip a particular subscription
            Select-AzSubscription -SubscriptionId $sub.SubscriptionId -ErrorAction Continue | Out-Null

            switch ($resourceType) {        
                "$($resourceType)" {
                    if($resourceName){
                        # Get 1 resource of this type
                        $resources = Get-AzResource -Name $resourceName -ResourceGroupName $resourceGroupName
                    }
                    else{
                        # Get all resources of this type
                        $resources = Get-AzResource -ResourceType $resourceType
                    }
                }            
                                                            
            }

            foreach ($resource in $resources) {                    
                    Write-Host "Processing $resourceType $($resource.Name)" -ForegroundColor Cyan
                    $ResourceDetail = [ordered]@{
                        'ResourceName' = $resource.Name
                
                }


                #  Do if tagS are not null
                if($resource.Tags){
                
            
                    # Collect all unique tag keys
                    $resource.Tags.GetEnumerator() | ForEach-Object {
                        # Continue (skip) if tag name starts with hidden-link
                        if($_.Key -like "hidden-link*"){
                            continue
                        }
                        elseif (-not $allTagKeys.Contains($_.Key)) {
                            $allTagKeys += $_.Key
                        }
                    }

                    # Add tags to the ResourceDetail object
                    $resource.Tags.GetEnumerator() | ForEach-Object {
                        $ResourceDetail[$_.Key] = $_.Value
                    }
            
                }
                # Update the output array, adding the PSCustomObject we have created for the resource details.
                $ResourceDetails += [PSCustomObject]$ResourceDetail
            }
        }
        catch [System.Exception]{
            if($_.Exception.Message -like "*The argument is null or empty.*"){
                Write-Warning "Skipping, No resources found for resource type: $($inputResourceType)"
            }
            else{
                Write-Error "Error processing resourceType: $($inputResourceType): $($_.Exception.Message)"
            }
        }
        catch {
            Write-Error "Error processing resourceType: $($inputResourceType): $($_.Exception.Message)"
        }
    }

    # Ensure all ResourceDetail objects have the same keys
    $ResourceDetails | ForEach-Object {
        foreach ($key in $allTagKeys) {
            if (-not $_.PSObject.Properties[$key]) {
                $_ | Add-Member -Name $key -MemberType NoteProperty -Value $null
            }
        }
    }

    # set the date for the export file
    $date = (get-date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

    # Export the results to CSV, skipping empty results
    if($ResourceDetails){
    $ResourceDetails | Export-Csv "$($exportFileNamePrefix)$($date).csv" -NoClobber -NoTypeInformation -Encoding UTF8 -Force
    }
}
#endregion

#region main script
if($allResourceTypes){
    try{
        Write-Verbose "Fetching all registered Azure resource types."
        $types = Get-AzResourceProvider -ListAvailable | Where-Object RegistrationState -eq "Registered" | Select-Object ProviderNamespace, ResourceTypes | Sort-Object ProviderNamespace
        $date = (get-date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
        $allTypes = @()
        foreach($type in $types){

            foreach($subtype in $type.ResourceTypes){
                $allTypes += [PSCustomObject]@{
                    'registeredResourceType' = $type.ProviderNamespace + "/" + $subtype.ResourceTypeName
                }
            }
        }
        write-verbose "Finished fetching registered Azure resource types."
        write-verbose ($allTypes | Out-String)
        $counter=1
        $total = ($allTypes).count
        foreach($resType in $allTypes){
            Write-Progress -PercentComplete ($counter/($total*100)) -Status "Processing ResourceType: $($resType.registeredResourceType)" -Activity "ResourceType $($counter) of $($total)"
            if($null -ne $resType.registeredResourceType){
            write-verbose "processing $($resType.registeredResourceType)"
            exportTags -inputResourceType $resType.registeredResourceType
            
            }
            $counter++
        }

    }
    catch{
        Write-Error "Failed to get all resource types: $($_.Exception.Message)"
        exit 1
    }
}
else{
    write-verbose "processing $($resourceType)"
    exportTags -inputResourceType $resourceType
}


