$RESOURCE_GROUP = $env:RESOURCE_GROUP
$CONTAINER_NAME = $env:CONTAINER_NAME
$TIMEOUT = [int]$env:TIMEOUT
$BLOB_BATCH_SIZE = [int]$env:BLOB_BATCH_SIZE  
$BLOB_AMOUNT = [int]$env:BLOB_AMOUNT     # Configurable batch size

Write-Host "Using resource group: $RESOURCE_GROUP"
Write-Host "Using container name: $CONTAINER_NAME"
Write-Host "Number of Blobs to create [$BLOB_AMOUNT] in Batches of [$BLOB_BATCH_SIZE]"
Write-Host "Timeout for copy status check: $TIMEOUT"

if ($BLOB_BATCH_SIZE -eq 0 -or $BLOB_AMOUNT -eq 0) {
    Write-Host "Invalid BLOB_BATCH_SIZE or BLOB_AMOUNT. Exiting."
    exit 1
}

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

    Write-Host "Creating containers (if they don't exist)..."

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

    Write-Host "Starting blob creation process..."
    Write-Host "Creating blobs in batches of $BLOB_BATCH_SIZE..."

    0..([math]::Floor($BLOB_AMOUNT / $BLOB_BATCH_SIZE)) | ForEach-Object {
        $startBlobNum = ($_ * $BLOB_BATCH_SIZE) + 1
        $endBlobNum = [math]::Min(($startBlobNum + $BLOB_BATCH_SIZE - 1), $BLOB_AMOUNT)

        Write-Host "Starting batch: $startBlobNum to $endBlobNum"

        Start-Job -ScriptBlock {
            param($startBlobNum, $endBlobNum, $SOURCE_STORAGE_ACCOUNT, $CONTAINER_NAME, $SOURCE_KEY)

            Write-Host "Processing batch $startBlobNum to $endBlobNum"

            function Check-BlobExists {
                param($blob_name, $SOURCE_STORAGE_ACCOUNT, $CONTAINER_NAME, $SOURCE_KEY)
                
                $blobExists = az storage blob exists `
                    --account-name $SOURCE_STORAGE_ACCOUNT `
                    --account-key $SOURCE_KEY `
                    --container-name $CONTAINER_NAME `
                    --name $blob_name `
                    --query 'exists' `
                    --output tsv

                return $blobExists
            }

            function Create-BlobIfNotExist {
                param($startBlobNum, $endBlobNum, $SOURCE_STORAGE_ACCOUNT, $CONTAINER_NAME, $SOURCE_KEY)
                    
                $allBlobsExist = $true

                for ($blob_num = $startBlobNum; $blob_num -le $endBlobNum; $blob_num++) {
                    $blob_name = "blob-$blob_num.txt"
                    $content = "Hi! I'm blob $blob_num"

                    Write-Host "Checking if blob '$blob_name' exists..."
                    
                    $blobExists = Check-BlobExists -blob_name $blob_name `
                                                  -SOURCE_STORAGE_ACCOUNT $SOURCE_STORAGE_ACCOUNT `
                                                  -CONTAINER_NAME $CONTAINER_NAME `
                                                  -SOURCE_KEY $SOURCE_KEY

                    if ($blobExists -eq 'false') {
                        Write-Host "Blob '$blob_name' does not exist. Proceeding to upload..."
                        $uploadResult = az storage blob upload `
                        --account-name $SOURCE_STORAGE_ACCOUNT `
                        --account-key $SOURCE_KEY `
                        --container-name $CONTAINER_NAME `
                        --name $blob_name `
                        --type block `
                        --data $content `
                        --output json

                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "Successfully uploaded blob: $blob_name"
                        } else {
                            Write-Host "Failed to upload blob: $blob_name"
                            Write-Host "Error details: $uploadResult"
                        }

                        $allBlobsExist = $false 
                    } else {
                        Write-Host "Blob '$blob_name' already exists. Skipping upload."
                    }
                }

                return $allBlobsExist
            }

            $allBlobsExist = Create-BlobIfNotExist -startBlobNum $startBlobNum `
                                                   -endBlobNum $endBlobNum `
                                                   -SOURCE_STORAGE_ACCOUNT $SOURCE_STORAGE_ACCOUNT `
                                                   -CONTAINER_NAME $CONTAINER_NAME `
                                                   -SOURCE_KEY $SOURCE_KEY

            if ($allBlobsExist) {
                Write-Host "All blobs in the range $startBlobNum to $endBlobNum already exist. Skipping batch."
            } else {
                Write-Host "At least one blob in the range $startBlobNum to $endBlobNum was uploaded."
            }
        } -ArgumentList $startBlobNum, $endBlobNum, $SOURCE_STORAGE_ACCOUNT, $CONTAINER_NAME, $SOURCE_KEY
    }

    Write-Host "Waiting for all blob creation jobs to complete..."
    
    $jobs = Get-Job
    $jobs | Wait-Job

    foreach ($job in $jobs) {
        if ($job.State -eq 'Failed') {
            Write-Host "Job $($job.Id) failed with error: $($job.ChildJobs[0].Error)"
        } else {
            Write-Host "Job $($job.Id) completed successfully."
            Receive-Job -Job $job
        }
    }

    $jobs | Remove-Job

    Write-Host "Blob creation process completed."
    Write-Host "Storage management operations completed successfully"
}

try {
    Main
} catch {
    Write-Host "An error occurred: $_"
}
