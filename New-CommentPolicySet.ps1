
<#PSScriptInfo

.VERSION 1.0.0

.GUID cc328e30-304f-426d-83c3-2ef20b68b97d

.AUTHOR PaulHCode

.COMPANYNAME

.COPYRIGHT

.TAGS

.LICENSEURI

.PROJECTURI https://github.com/PaulHCode/CommentPolicySet/blob/main/New-CommentPolicySet.ps1

.ICONURI

.EXTERNALMODULEDEPENDENCIES Az.Resources Az.Accounts

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES


.PRIVATEDATA

#>

<#
    .SYNOPSIS
        This script will create a policy set definition for each control in a policy set which applies to each subscription.
    .DESCRIPTION
        You must be logged into the Azure account which has access to the subscriptions you wish to create the policy and sets in before running this script.
        This script will create a policy set definition for each group in the file or URL specified.
        It will then create a policy for each group in each subscription selected.
        It will then create a policy set definition for each subscription selected.
        It will then assign the policy set definition to each subscription selected.
    .EXAMPLE
        .\New-CommentPolicySet.ps1 -PolicyNamePrefix "800-53Comments" -RegulatoryComplianceSetDefinitionURL 'https://raw.githubusercontent.com/Azure/azure-policy/master/built-in-policies/policySetDefinitions/Regulatory%20Compliance/NIST_SP_800-53_R4.json'

        This gets the policy set definition from the URL specified and creates a policy definition for each group in the policy set, then creates a policy set definition containing every policy just created.
    .EXAMPLE
        .\New-CommentPolicySet.ps1 -PolicyNamePrefix "800-53Comments" -RegulatoryComplianceSetDefinitionFile .\groups.clixml

        This gets the policy set definition from the file specified and creates a policy definition for each group in the policy set, then creates a policy set definition containing every policy just created.
    .NOTES
        This script is provided as is and is not supported by Microsoft.
        For more fun code check out https://github.com/PaulHCode/azurehelper
#>

#Requires -Version 7.0
#Requires -Module Az.Resources
#Requires -Module Az.Accounts

param(
    [Parameter(Mandatory = $true, ParameterSetName = 'URL')]
    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [string]$PolicyNamePrefix = '800-53Comments',
    [Parameter(Mandatory = $false, ParameterSetName = 'URL')]
    [Parameter(Mandatory = $false, ParameterSetName = 'File')]
    [string]$SubscriptionId,
    [Parameter(Mandatory = $true, ParameterSetName = 'URL')]
    [ValidateScript({ (Invoke-WebRequest -Uri $_ -UseBasicParsing -Method head).StatusCode -eq 200})]
    [string]$RegulatoryComplianceSetDefinitionURL = 'https://raw.githubusercontent.com/Azure/azure-policy/master/built-in-policies/policySetDefinitions/Regulatory%20Compliance/NIST_SP_800-53_R4.json',
    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$RegulatoryComplianceSetDefinitionFile
)

If($Null -eq (Get-AzContext)){
    throw "You must be logged into Azure to run this script"
    Exit
}

#$RegulatoryComplianceSetDefinitionURL = 'https://github.com/Azure/azure-policy/blob/master/built-in-policies/policySetDefinitions/Regulatory%20Compliance/NIST_SP_800-53_R4.json'
If($RegulatoryComplianceSetDefinitionURL){
    $RegulatoryComplianceSetDefinition = Invoke-RestMethod -Uri $RegulatoryComplianceSetDefinitionURL -UseBasicParsing
    $groups = $RegulatoryComplianceSetDefinition.properties.policyDefinitionGroups
    write-verbose "Loaded $($groups.count) groups from $RegulatoryComplianceSetDefinitionURL"
}Else{
    $groups = Import-Clixml $RegulatoryComplianceSetDefinitionFile
    write-verbose "Loaded $($groups.count) groups from $RegulatoryComplianceSetDefinitionFile"
}

If($SubscriptionId){
    $SubscriptionsToApplyTo = [array](Get-AzSubscription -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue)
}else{
    Write-host "Select Subscriptions to apply to. There is a pop-under window which may be hidden behind this window"
    $SubscriptionsToApplyTo = [array](Get-AzSubscription -WarningAction SilentlyContinue | Out-GridView -Title "Select Subscriptions to apply to" -OutputMode Multiple)
}
#$SubscriptionsToApplyTo = $SubscriptionsToApplyTo.SubscriptionId
#$SubscriptionsToApplyTo = [array](Get-AzSubscription | Out-GridView -Title "Select Subscriptions to apply to" -OutputMode Multiple)
#$groups = Import-Clixml .\groups.clixml
#$PolicyNamePrefix = '800-53Comments'
#$SubscriptionId = '6a63eec2-cc9d-48ac-a0b7-ac7de8a7c23f'

ForEach ($sub in $SubscriptionsToApplyTo) {
    Write-Host "Working on $($sub.Name)"
    #Create Policies
    $count = 0
    $max = $groups.Count
    $createdPolicies = ForEach ($group in $groups) {
        write-verbose "Working on $($group.Name)"
        Write-Progress -Activity "Creating Policies" -Status "Creating Policy $count of $max" -PercentComplete (($count / $max) * 100) -CurrentOperation "$($group.Name)"

        $policy = @'
{
"if": {
    "field": "type",
    "equals": "Microsoft.Resources/subscriptions"
    },
    "then": {
        "effect": "Manual",
        "details": {
            "defaultState": "Unknown"
        }
    }
}
'@

        $metadata = @"
{
"version": "1.1.0",
"category": "Custom Regulatory Compliance",
"additionalMetadataId": "$($group.additionalMetadataId)"
}
"@

        $PolicyDefinitionSplat = @{
            Name           = "$PolicyNamePrefix-$($group.Name)"
            DisplayName    = "$PolicyNamePrefix-$($group.Name)"
            Description    = "$PolicyNamePrefix-$($group.Name)"
            Policy         = $policy
            Mode           = 'All'
            SubscriptionId = $($sub.Id)
            Metadata       = $metadata
        }

        New-AzPolicyDefinition @PolicyDefinitionSplat
        $count++
    }


    #build PolicySetDefinition
    $PolicySetDefinition = "[`n"
    $count = 0
    $max = $createdPolicies.Count
    ForEach ($policy in $createdPolicies) {
        $PolicySetDefinition += @"

        {
            "policyDefinitionId": "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyDefinitions/$($policy.Name)"
        }
"@
        If ($count -lt ($max - 1)) { $PolicySetDefinition += "," }
        $count++
    }
    $PolicySetDefinition += "`n]"
    #export PolicySetDefinition
    $tempFileName = ".\PolicyDefinition-$($sub.Name).json"
    $PolicySetDefinition | Out-File $tempFileName -Force
    #Create PolicySetDefinition
    New-AzPolicySetDefinition -Name $PolicyNamePrefix -DisplayName $PolicyNamePrefix -Description $PolicyNamePrefix -PolicyDefinition $tempFileName -SubscriptionId $sub.Id
    Remove-Item $tempFileName -Force
}





#cleanup - works probably, but commented out for safety
#Get-AzPolicySetDefinition | Where-Object { $_.Properties.DisplayName -like "$PolicyNamePrefix*" } | Remove-AzPolicySetDefinition -Force
#Get-AzPolicyDefinition | Where-Object { $_.Properties.DisplayName -like "$PolicyNamePrefix*" } | Remove-AzPolicyDefinition -Force
