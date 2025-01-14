$RESOURCE_GROUP = $env:RESOURCE_GROUP
$CONTAINER_NAME = $env:CONTAINER_NAME
$TIMEOUT = [int]$env:TIMEOUT
$BLOB_BATCH_SIZE = [int]$env:BLOB_BATCH_SIZE  
$BLOB_AMOUNT = [int]$env:BLOB_AMOUNT     # Configurable batch size

# Validate BLOB_BATCH_SIZE and BLOB_AMOUNT
if ($BLOB_BATCH_SIZE -eq 0 -or $BLOB_AMOUNT -eq 0) {
    Write-Host "Invalid BLOB_BATCH_SIZE or BLOB_AMOUNT. Exiting."
    exit 1
}

Write-Host "Using resource group: $RESOURCE_GROUP"
Write-Host "Using container name: $CONTAINER_NAME"
Write-Host "Number of Blobs to create [$BLOB_AMOUNT] in Batches of [$BLOB_BATCH_SIZE]"
Write-Host "Timeout for copy status check: $TIMEOUT"

# Function to get storage accounts by tags
function Get-StorageAccounts {
    param ($resource_group)

    Write-Host "Finding storage accounts in resource group $resource_group..."

    $storage_accounts = az storage account list `
        --resource-group $resource_group `
        --query "[?tags.project=='blobcopy'].{name:name, role:tags.role}" `
        --output json | ConvertFrom-Json

    # Grab the first match for source and destination
    $SOURCE_STORAGE_ACCOUNT = ($storage_accounts | Where-Object { $_.role -eq "source" } | Select-Object -First 1).name
    $DEST_STORAGE_ACCOUNT = ($storage_accounts | Where-Object { $_.role -eq "destination" } | Select-Object -First 1).name

    if (-not $SOURCE_STORAGE_ACCOUNT -or -not $DEST_STORAGE_ACCOUNT) {
        Write-Host "Error: One or both storage accounts not found"
        exit 1
    }

    Write-Host "Found storage accounts:"
    Write-Host "Source: $SOURCE_STORAGE_ACCOUNT"
    Write-Host "Destination: $DEST_STORAGE_ACCOUNT"

    # Get storage keys once and export them
    $SOURCE_KEY = $(az storage account keys list `
        --resource-group $resource_group `
        --account-name $SOURCE_STORAGE_ACCOUNT `
        --query '[0].value' `
        --output tsv)

    $DEST_KEY = $(az storage account keys list `
        --resource-group $resource_group `
        --account-name $DEST_STORAGE_ACCOUNT `
        --query '[0].value' `
        --output tsv)

    [System.Environment]::SetEnvironmentVariable('SOURCE_KEY', $SOURCE_KEY, 'Process')
    [System.Environment]::SetEnvironmentVariable('DEST_KEY', $DEST_KEY, 'Process')

    return $SOURCE_STORAGE_ACCOUNT, $DEST_STORAGE_ACCOUNT, $SOURCE_KEY, $DEST_KEY
}

# Function to check if Azure CLI is installed and user is logged in(incase not using local agent)
function Check-Prerequisites {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "Azure CLI is not installed. Installing..."
        Invoke-WebRequest -Uri "https://aka.ms/InstallAzureCLIDeb" -OutFile "azurecli_install.ps1"
        .\azurecli_install.ps1
    }

    $account = az account show --output json
    if (-not $account) {
        Write-Host "Not logged into Azure CLI. Pipeline should handle authentication."
        exit 1
    }
}

function Create-Containers {
    param ($SOURCE_STORAGE_ACCOUNT, $DEST_STORAGE_ACCOUNT, $SOURCE_KEY, $DEST_KEY)

    Write-Host "Creating containers[if they don't exist...]"

    az storage container create `
        --account-name $SOURCE_STORAGE_ACCOUNT `
        --account-key $SOURCE_KEY `
        --name $CONTAINER_NAME `
        --output none 2>$null

    az storage container create `
        --account-name $DEST_STORAGE_ACCOUNT `
        --account-key $DEST_KEY `
        --name $CONTAINER_NAME `
        --output none 2>$null
}

function Main {
    Write-Host "Starting storage management script..."

    Check-Prerequisites
    $storageInfo = Get-StorageAccounts $RESOURCE_GROUP
    $SOURCE_STORAGE_ACCOUNT = $storageInfo[0]
    $DEST_STORAGE_ACCOUNT = $storageInfo[1]
    $SOURCE_KEY = $storageInfo[2]
    $DEST_KEY = $storageInfo[3]
    
    Create-Containers $SOURCE_STORAGE_ACCOUNT $DEST_STORAGE_ACCOUNT $SOURCE_KEY $DEST_KEY

    Write-Host "Starting blob copy process..."
    Write-Host "Copying blobs in batches of $BLOB_BATCH_SIZE up to $BLOB_AMOUNT blobs..."

    0..([math]::Floor($BLOB_AMOUNT / $BLOB_BATCH_SIZE)) | ForEach-Object {
        $startBlobNum = ($_ * $BLOB_BATCH_SIZE) + 1
        $endBlobNum = [math]::Min(($startBlobNum + $BLOB_BATCH_SIZE - 1), $BLOB_AMOUNT)

        Write-Host "Starting copy batch: $startBlobNum to $endBlobNum"

        Start-Job -ScriptBlock {
            param(
                $startBlobNum,
                $endBlobNum,
                $SOURCE_STORAGE_ACCOUNT,
                $DEST_STORAGE_ACCOUNT,
                $SOURCE_KEY,
                $DEST_KEY,
                $CONTAINER_NAME
            )
            
            Write-Host "Processing copy batch $startBlobNum to $endBlobNum"
            
            function Copy-BlobsBetweenAccounts {
                param (
                    $SOURCE_STORAGE_ACCOUNT,
                    $DEST_STORAGE_ACCOUNT,
                    $SOURCE_KEY,
                    $DEST_KEY,
                    $CONTAINER_NAME,
                    $startBlobNum,
                    $endBlobNum
                )
            
                try {
                    Write-Host "Starting to copy blobs from $startBlobNum to $endBlobNum..."
            
                    for ($blob_num = $startBlobNum; $blob_num -le $endBlobNum; $blob_num++) {
                        $blob_name = "blob-$blob_num.txt"
            
                        $copyResult = az storage blob copy start `
                            --source-account-name $SOURCE_STORAGE_ACCOUNT `
                            --source-account-key $SOURCE_KEY `
                            --account-name $DEST_STORAGE_ACCOUNT `
                            --account-key $DEST_KEY `
                            --source-container $CONTAINER_NAME `
                            --destination-container $CONTAINER_NAME `
                            --source-blob $blob_name `
                            --destination-blob $blob_name `
                            --output json
                    }
            
                    Write-Host "Successfully initiated copy for blobs $startBlobNum to $endBlobNum."
                }
                catch {
                    Write-Host "Error in Copy-BlobsBetweenAccounts: $_"
                    Write-Host "Stack trace: $($_.ScriptStackTrace)"
                    throw
                }
            }

            Copy-BlobsBetweenAccounts `
                -SOURCE_STORAGE_ACCOUNT $SOURCE_STORAGE_ACCOUNT `
                -DEST_STORAGE_ACCOUNT $DEST_STORAGE_ACCOUNT `
                -SOURCE_KEY $SOURCE_KEY `
                -DEST_KEY $DEST_KEY `
                -CONTAINER_NAME $CONTAINER_NAME `
                -startBlobNum $startBlobNum `
                -endBlobNum $endBlobNum

        } -ArgumentList $startBlobNum, $endBlobNum, $SOURCE_STORAGE_ACCOUNT, $DEST_STORAGE_ACCOUNT, $SOURCE_KEY, $DEST_KEY, $CONTAINER_NAME
    }

    Write-Host "Waiting for all copy jobs to complete..."
    
    Get-Job | Wait-Job | ForEach-Object {
        $job = $_
        if ($job.State -eq 'Failed') {
            Write-Host "Job $($job.Id) failed with error: $($job.ChildJobs[0].Error)"
        }
        Receive-Job -Job $job
    }

    Get-Job | Remove-Job

    Write-Host "Blob copy process completed."
    Write-Host "Storage management operations completed successfully"
}

try {
    Main
} catch {
    Write-Host "An error occurred: $_"
}

