# Script that copies the history of an entire Team Foundation Server repository to a Git repository.
# Original author: Wilbert van Dolleweerd (wilbert@arentheym.com)
#
# Contributions from:
# - Patrick Slagmeulen
# - Tim Kellogg (timothy.kellogg@gmail.com)
#
# Assumptions:
# - MSysgit is installed and in the PATH 
# - Team Foundation commandline tooling is installed and in the PATH (tf.exe)

Param
(
	[Parameter(Mandatory = $True)]
	[string]$TFSRepository,
	[string]$GitRepository = "ConvertedFromTFS",
	[string]$WorkspaceName = "TFS2GIT",
	[int]$StartingCommit,
	[int]$EndingCommit,
	[string]$UserMappingFile,
    [string]$CommitMessageFormat = "{1}`n`nTFS Changeset ID: {0}`nCommitter: {2}`nDate: {4:G}`nItems:`n{5}`n`nWork Items:`n{6}`n`nCheck-in Notes:`n{7}`n`nPolicy Override: {8}`n{9}", #0=Changeset ID, 1=Comment, 2=Committer, 3=Owner, 4=Creation Date, 5=Changes, 6=Work Items, 7=Checkin Note, 8=Policy Override Comment, 9=Policies Overridden
    [string]$ChangeFormat = "{0,-10} {1}`n", #0=Change Type, 1=Server Item Path
    [string]$WorkItemFormat = "{0,-10} {1}`n", #0=Work Item Id, 1=Work Item Title
    [string]$CheckInNotesFormat = "  {0}: {1}`n", #0=Name, 1=Value
    [string]$PolicyFailuresFormat = "{0}`n" #0=Policy Name, 1=Comment
)

if ((Get-PSSnapin -Name 'Microsoft.TeamFoundation.PowerShell' -ErrorAction SilentlyContinue) -eq $null)
{
    Add-PsSnapin Microsoft.TeamFoundation.PowerShell
}

function CheckPath([string]$program) 
{
	$count = (gcm -CommandType Application $program -ea 0 | Measure-Object).Count
	if($count -le 0)
	{
		Write-Host "$program must be found in the PATH!"
		Write-Host "Aborting..."
		exit
	}
}

# Do some sanity checks on specific parameters.
function CheckParameters
{
	# If Starting and Ending commit are not used, simply ignore them.
	if (!$StartingCommit -and !$EndingCommit)
	{
		return;
	}

	if (!$StartingCommit -or !$EndingCommit)
	{
		Write-Host "You must supply values for both parameters StartingCommit and EndingCommit"
		Write-Host "Aborting..."
		exit
	}

	if ($EndingCommit -le $StartingCommit)
	{
		if ($EndingCommit -eq $StartingCommit)
		{
			Write-Host "Parameter StartingCommit" $StartingCommit "cannot have the same value as the parameter EndingCommit" $EndingCommit
			Write-Host "Aborting..."
			exit
		}

		Write-Host "Parameter EndingCommit" $EndingCommit "cannot have a lower value than parameter StartingCommit" $StartingCommit
		Write-Host "Aborting..."
		exit
	}
}

# When doing a partial import, check if specified commits are actually present in the history
function AreSpecifiedCommitsPresent([array]$ChangeSets)
{
	[bool]$StartingCommitFound = $false
	[bool]$EndingCommitFound = $false
	foreach ($ChangeSet in $ChangeSets)
	{
		if ($ChangeSet -eq $StartingCommit)
		{
			$StartingCommitFound = $true
		}
		if ($ChangeSet -eq $EndingCommit)
		{
			$EndingCommitFound = $true
		}
	}

	if (!$StartingCommitFound -or !$EndingCommitFound)
	{
		if (!$StartingCommitFound)
		{
			Write-Host "Specified starting commit" $StartingCommit "was not found in the history of" $TFSRepository
			Write-Host "Please check your starting commit parameter."
		}
		if (!$EndingCommitFound)
		{
			Write-Host "Specified ending commit" $EndingCommit "was not found in the history of" $TFSRepository
			Write-Host "Please check your ending commit parameter."			
		}

		Write-Host "Aborting..."		
		exit
	}
}

# Build an array of changesets that are between the starting and the ending commit.
function GetSpecifiedRangeFromHistory
{
	$ChangeSets = GetAllChangeSetsFromHistory

	# Create an array
	$FilteredChangeSets = @()

	foreach ($ChangeSet in $ChangeSets)
	{
		if (($ChangeSet -ge $StartingCommit) -and ($ChangeSet -le $EndingCommit))
		{
			$FilteredChangeSets = $FilteredChangeSets + $ChangeSet
		}
	}

	return $FilteredChangeSets
}


function GetTemporaryDirectory
{
	return $env:temp + "\workspace"
}

# Creates a hashtable with the user account name as key and the name/email address as value
function GetUserMapping
{
	if (!(Test-Path $UserMappingFile))
	{
		Write-Host "Could not read user mapping file" $UserMappingFile
		Write-Host "Aborting..."
		exit
	}	

	$UserMapping = @{}

	Write-Host "Reading user mapping file" $UserMappingFile
	Get-Content $UserMappingFile | foreach { [regex]::Matches($_, "^([^=#]+)=(.*)$") } | foreach { $userMapping[$_.Groups[1].Value] = $_.Groups[2].Value }
	foreach ($key in $userMapping.Keys) 
	{
		Write-Host $key "=>" $userMapping[$key]
	}

	return $UserMapping
}

function PrepareWorkspace
{
	$TempDir = GetTemporaryDirectory

	# Remove the temporary directory if it already exists.
	if (Test-Path $TempDir)
	{
		remove-item -path $TempDir -force -recurse		
	}
	
	md $TempDir | Out-null

	# Create the workspace and map it to the temporary directory we just created.
	tf workspace /delete $WorkspaceName /noprompt
	tf workspace /new /noprompt /comment:"Temporary workspace for converting a TFS repository to Git" $WorkspaceName
	tf workfold /unmap /workspace:$WorkspaceName $/
	tf workfold /map /workspace:$WorkspaceName $TFSRepository $TempDir
}


# Retrieve the history from Team Foundation Server, parse it line by line, 
# and use a regular expression to retrieve the individual changeset numbers.
function GetAllChangesetsFromHistory 
{
	$ChangeSets = Get-TfsItemHistory $TFSRepository -Recurse
    
    # Sort them from low to high.
	return $ChangeSets | Sort-Object ChangesetId
}

# Actual converting takes place here.
function Convert ([array]$ChangeSets)
{
	$TemporaryDirectory = GetTemporaryDirectory

	# Initialize a new git repository.
	Write-Host "Creating empty Git repository at", $TemporaryDirectory
	git init $TemporaryDirectory

	# Let git disregard casesensitivity for this repository (make it act like Windows).
	# Prevents problems when someones only changes case on a file or directory.
	git config core.ignorecase true

	# If we use this option, read the usermapping file.
	if ($UserMappingFile)
	{
		$UserMapping = GetUserMapping
	}

	Write-Host "Retrieving sources from", $TFSRepository, "in", $TemporaryDirectory

	[bool]$RetrieveAll = $true
	foreach ($ChangeSet in $ChangeSets)
	{
		# Retrieve sources from TFS
		Write-Host "Retrieving changeset", $ChangeSet.ChangesetId

		if ($RetrieveAll)
		{
			# For the first changeset, we have to get everything.
			tf get $TemporaryDirectory /force /recursive /noprompt /version:C$ChangeSet.ChangesetId | Out-Null
			$RetrieveAll = $false
		}
		else
		{
			# Now, only get the changed files.
			tf get $TemporaryDirectory /recursive /noprompt /version:C$ChangeSet.ChangesetId | Out-Null
		}


		# Add sources to Git
		Write-Host "Adding commit to Git repository"
		pushd $TemporaryDirectory
		git add --all | Out-Null
		$CommitMessageFileName = "commitmessage.txt"
		GetCommitMessage $ChangeSet.ChangesetId $CommitMessageFileName

		# We don't want the commit message to be included, so we remove it from the index.
		# Not from the working directory, because we need it in the commit command.
		git rm $CommitMessageFileName --cached --force		

		$CommitMsg = Get-Content $CommitMessageFileName		
		$Match = ([regex]'User: (\w+)').Match($commitMsg)
		if ($UserMapping.Count -gt 0 -and $Match.Success -and $UserMapping.ContainsKey($Match.Groups[1].Value)) 
		{	
			$Author = $userMapping[$Match.Groups[1].Value]
			Write-Host "Found user" $Author "in user mapping file."
			git commit --file $CommitMessageFileName --author $Author | Out-Null									
		}
		else 
		{	
			if ($UserMappingFile)
			{
				$GitUserName = git config user.name
				$GitUserEmail = git config user.email				
				Write-Host "Could not find user" $Match.Groups[1].Value "in user mapping file. The default configured user" $GitUserName $GitUserEmail "will be used for this commit."
			}
			git commit --file $CommitMessageFileName | Out-Null
		}
		popd 
	}
}

# Retrieve the commit message for a specific changeset
function GetCommitMessage ([int]$ChangesetId, [string]$CommitMessageFileName)
{	
    $ChangeSet = Get-TfsChangeset $ChangesetId
    
    $Changes = ""
    foreach ($Change in $ChangeSet.Changes)
    {
        $Changes += $ChangeFormat -F $Change.ChangeType, $Change.ServerItem
    }
    
    $WorkItems = ""
    foreach ($WorkItem in $ChangeSet.WorkItems)
    {
        $WorkItems += $WorkItemFormat -F $WorkItem.Id, $WorkItem.Title
    }
    
    $CheckinNote = ""
    foreach ($NoteField in $ChangeSet.CheckinNote.Values)
    {
        $CheckinNote += $CheckInNotesFormat -F $NoteField.Name, $NoteField.Value
    }
    
    $PolicyFailures = ""
    foreach ($Failure in $ChangeSet.PolicyOverride.PolicyFailures)
    {
        $PolicyFailures += $PolicyFailuresFormat -F $Failure.PolicyName, $Failure.Message
    }
    
    $CommitMessageFormat -F $ChangeSet.ChangesetId, $ChangeSet.Comment, $ChangeSet.Committer, $ChangeSet.Owner, $ChangeSet.CreationDate, $Changes, $WorkItems, $CheckinNote, $ChangeSet.PolicyOverride.Comment, $PolicyFailures | Out-File $CommitMessageFileName -encoding utf8
}

# Clone the repository to the directory where you started the script.
function CloneToLocalBareRepository
{
	$TemporaryDirectory = GetTemporaryDirectory

	# If for some reason, old clone already exists, we remove it.
	if (Test-Path $GitRepository)
	{
		remove-item -path $GitRepository -force -recurse		
	}
	git clone --bare $TemporaryDirectory $GitRepository
	$(Get-Item -force $GitRepository).Attributes = "Normal"
	Write-Host "Your converted (bare) repository can be found in the" $GitRepository "directory."
}

# Clean up leftover directories and files.
function CleanUp
{
	$TempDir = GetTemporaryDirectory

	Write-Host "Removing workspace from TFS"
	tf workspace /delete $WorkspaceName /noprompt

	Write-Host "Removing working directories in" $TempDir
	Remove-Item -path $TempDir -force -recurse

	# Remove history file
	Remove-Item "history.txt"
}

# This is where all the fun starts...
function Main
{
	CheckPath("git.cmd")
	CheckPath("tf.exe")
	CheckParameters
	PrepareWorkspace

	if ($StartingCommit -and $EndingCommit)
	{
		Write-Host "Filtering history..."
		AreSpecifiedCommitsPresent(GetAllChangeSetsFromHistory)
		Convert(GetSpecifiedRangeFromHistory)
	}
	else
	{
		Convert(GetAllChangeSetsFromHistory)
	}

	CloneToLocalBareRepository
	CleanUp

	Write-Host "Done!"
}

Main
