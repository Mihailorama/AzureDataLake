<#
.SYNOPSIS
Script used to add permissions for an ADLA job user

.DESCRIPTION
This script adds permissions for the specified user or group to submit and browse jobs in the specified ADLA account

.PARAMETER Account
The name of the ADLA account to add the user to.

.PARAMETER EntityToAdd
The ObjectID of the user or group to add.
The recommendation to ensure the right user is added is to run Get-AzureRMAdUser or Get-AzureRMAdGroup and pass in the ObjectID
returned by that cmdlet.

.PARAMETER EntityType
Indicates if the entity to be added is a user or a group

.PARAMETER FullReplication
If explicitly passed in we will do the full permissions replication
as a blocking call. This will take a very long time depending on the size of the job history.
The recommendation is to not pass this value in, and let the script submit an async job to perform this action.


.EXAMPLE
Add-AdlaJobUser.ps1 -Account myadlsaccount -EntityToAdd 546e153e-0ecf-417b-ab7f-aa01ce4a7bff -EntityType User
#>
param
(
	[Parameter(Mandatory=$true)]
	[string] $Account,
	[Parameter(Mandatory=$true)]
	[Guid] $EntityIdToAdd,
	[ValidateSet("User", "Group")]
	[Parameter(Mandatory=$true)]
	[string] $EntityType,
	[Parameter(Mandatory=$false)]
	[switch] $FullReplication = $false
)

function getclosestdatefolder
{
	param
	(
		[Parameter(Mandatory=$true)]
		[string] $Account,
		[Parameter(Mandatory=$true)]
		[string] $Path,
		[Parameter(Mandatory=$true)]
		[int] $folderAppendNumber
	)
	
	if(!([string]::IsNullOrEmpty($Path)) -and (Test-AzureRMDataLakeStoreItem -Account $Account -Path $Path))
	{
		$itemList = Get-AzureRMDataLakeStoreChildItem -Account $Account -Path $Path | Sort-Object PathSuffix -Descending
		for ($i = 0; $i -lt $itemList.Count; $i++)
		{
			if([int]::Parse($itemList[$i].PathSuffix) -le $folderAppendNumber)
			{
				$pathToSet = Join-Path -Path $Path -ChildPath $itemList[$i].PathSuffix
				$pathToSet = $pathToSet.Replace("\", "/")
				return $pathToSet
			}
		}
		
		throw "Could not find any subfolder of $path starting at number: $folderAppendNumber or lower"
	}
	else
	{
		return $null
	}
}

function getdatefolderlist
{
	param
	(
		[Parameter(Mandatory=$true)]
		[string] $Account,
		[Parameter(Mandatory=$true)]
		[string] $Path
	)
	
	$today = Get-Date
	$year = $today.Year
	$month = $today.Month
	$day = $today.Day
	$toReturn = @()
	
	$firstPath = getclosestdatefolder -Account $Account -Path $Path -folderAppendNumber $year
	if(!([string]::IsNullOrEmpty($firstPath)))
	{
		$secondPath = getclosestdatefolder -Account $Account -Path $firstPath -folderAppendNumber $month
		if(!([string]::IsNullOrEmpty($secondPath)))
		{
			$thirdPath = getclosestdatefolder -Account $Account -Path $secondPath -folderAppendNumber $day
			if(!([string]::IsNullOrEmpty($thirdPath)))
			{
				$fourthPath = getclosestdatefolder -Account $Account -Path $thirdPath -folderAppendNumber 24
				if(!([string]::IsNullOrEmpty($fourthPath)))
				{
					$fifthPath = getclosestdatefolder -Account $Account -Path $fourthPath -folderAppendNumber 59
				}
			}
		}
	}
	
	$toReturn += $firstPath
	$toReturn += $secondPath
	$toReturn += $thirdPath
	$toReturn += $fourthPath
	$toReturn += $fifthPath
	
	return $toReturn
}

function giveaccess
{
	param
	(
		[Parameter(Mandatory=$true)]
		[string] $Account,
		[Parameter(Mandatory=$true)]
		[string] $Path,
		[Parameter(Mandatory=$true)]
		[Guid] $IdToAdd,
		[Parameter(Mandatory=$true)]
		[string] $entityType,
		[Parameter(Mandatory=$true)]
		[string] $permissionToAdd,
		[Parameter(Mandatory=$false)]
		[switch] $isDefault = $false,
		[Parameter(Mandatory=$true)]
		[string] $loginProfilePath
	)
	
	# There is not an easy way to check if the user is part of an existing security group with permissions, so we are going to need to just add the ACE
	if($permissionToAdd -ieq "Execute")
	{
		$perm = "--x"
	}
	else
	{
		$perm = "rwx"
	}
	
	$aceToAdd = "$entityType`:$idToAdd`:$perm"
	if($isDefault)
	{
		$aceToAdd = "default:$aceToAdd,$aceToAdd"
	}
	
	return Start-Job -ScriptBlock {param ($loginProfilePath, $Account, $Path, $aceToAdd) Select-AzureRMProfile -Path $loginProfilePath | Out-Null; Set-AzureRmDataLakeStoreItemAclEntry -Account $Account -Path $Path -Acl "$aceToAdd"} -ArgumentList $loginProfilePath, $Account, $Path, $aceToAdd
}

function copyacls
{
	param
	(
		[Parameter(Mandatory=$true)]
		[string] $Account,
		[Parameter(Mandatory=$true)]
		[string] $Path,
		[Parameter(Mandatory=$true)]
		[Guid] $IdToAdd,
		[Parameter(Mandatory=$true)]
		[string] $entityType,
		[Parameter(Mandatory=$true)]
		[string] $loginProfilePath
	)
	
	$itemList = Get-AzureRMDataLakeStoreChildItem -Account $Account -Path $Path;
	foreach($item in $itemList)
	{
		$pathToSet = Join-Path -Path $Path -ChildPath $item.PathSuffix;
		$pathToSet = $pathToSet.Replace("\", "/");
		
		if ($item.Type -ieq "FILE")
		{
			# set the ACL without default using "All" permissions
			giveaccess -Account $Account -Path $Path -IdToAdd $IdToAdd -entityType $entityType -permissionToAdd "All" -loginProfilePath $loginProfilePath | Out-Null
		}
		elseif ($item.Type -ieq "DIRECTORY")
		{
			# set permission and recurse on the directory
			giveaccess -Account $Account -Path $Path -IdToAdd $IdToAdd -entityType $entityType -permissionToAdd "All" -isDefault -loginProfilePath $loginProfilePath  | Out-Null
			copyacls -Account $Account -Path $pathToSet -IdToAdd $IdToAdd -entityType $entityType -loginProfilePath $loginProfilePath  | Out-Null
		}
		else
		{
			throw "Invalid path type of: $($item.Type). Valid types are 'DIRECTORY' and 'FILE'"
		}
	}
}

# This script assumes the following:
# 1. The Azure PowerShell environment is installed
# 2. The current session has already run "Login-AzureRMAccount" with a user account that has permissions to the specified ADLS account
try
{	
	$executingDir = Split-Path -parent $MyInvocation.MyCommand.Definition
	$executingFile = Split-Path -Leaf $MyInvocation.MyCommand.Definition
	
	# get the datalake store account that this ADLA account uses
	$adlsAccount = $(Get-AzureRmDataLakeAnalyticsAccount -Name $Account).Properties.DefaultDataLakeStoreAccount
	$profilePath = Join-Path $env:TEMP "jobprofilesession.tmp"
	if(Test-Path $profilePath)
	{
		Remove-Item $profilePath -Force -Confirm:$false
	}
	
	Save-AzureRMProfile -path $profilePath | Out-Null
	
	if($FullReplication)
	{
		Write-Host "Request to add entity: $EntityIdToAdd successfully submitted and will propagate over time depending on the size of the folder."
		Write-Host "Please do not close this powershell window as the propagation will be cancelled"
		copyacls -Account $adlsAccount -Path /system -IdToAdd $EntityIdToAdd -entityType $EntityType -loginProfilePath $profilePath | Out-Null
	}
	else
	{
		# Now give and check access for the user on the following folders:
		# / (x)
		# /system (rwx)
		# /system/jobservice (rwx)
		# /system/jobservice/jobs (rwx)
		$allJobs = @()
		$pathList = @("/", "/system", "/system/jobservice", "/system/jobservice/jobs", "/system/jobservice/jobs/Usql", "/system/compilationService", "/system/compilationService/jobs", "/system/compilationService/jobs/USql")
		$pathList += (getdatefolderlist -Account $adlsAccount -Path /system/jobservice/jobs/Usql)
		foreach ($item in $pathList)
		{
			if (!([string]::IsNullOrEmpty($item)) -and (Test-AzureRMDataLakeStoreItem -Account $adlsAccount -Path $item))
			{
				$allJobs += giveaccess -Account $adlsAccount -Path $item -IdToAdd $EntityIdToAdd -entityType $entityType -permissionToAdd "All" -isDefault -loginProfilePath $profilePath
			}
		}
		
		$job = Start-Job -ScriptBlock {param ($Account, $EntityIdToAdd, $EntityType, $profilePath, $ScriptToRun) Select-AzureRMProfile -Path $profilePath | Out-Null; &$ScriptToRun -Account $Account -EntityIdToAdd $EntityIdToAdd -EntityType $EntityType -FullReplication} -ArgumentList $Account, $EntityIdToAdd, $EntityType, $profilePath, $MyInvocation.MyCommand.Definition
		
		Write-Host "Request to add entity: $entityIdToAdd successfully submitted and the user may begin submitting new jobs now. Full permissions will propagate over time depending on the size of the folder."
		Write-Host "Please leave this powershell window open and track the progress of the full propagation with the returned job: $($job.Id)"
		return $job
	}
}
catch
{
	Write-Error "ACL Propagation failed with the following error: $($error[0])"
}