function Test-DbaS3BackupCompatibility {
    <#
    .SYNOPSIS
        Tests database backups for S3 multipart upload compatibility by analyzing backup size, file count, and MAXTRANSFERSIZE settings.

    .DESCRIPTION
        Analyzes backup history from MSDB to determine if database backups will exceed AWS S3's 10,000 part limit for multipart uploads. S3 multipart uploads are limited to 10,000 parts, and the number of parts is calculated as: backup_size / MAXTRANSFERSIZE / number_of_backup_files.

        This function queries the most recent full backup for each database and calculates the part count based on the specified MAXTRANSFERSIZE (default 10MB). It identifies databases that are over the limit or approaching it (90% threshold = 9,000 parts).

        Use this before migrating backups to S3 to identify databases that need configuration changes such as increasing MAXTRANSFERSIZE, adding more backup files, or using backup compression.

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Accepts PowerShell credentials (Get-Credential).

        Windows Authentication, SQL Server Authentication, Active Directory - Password, and Active Directory - Integrated are all supported.

        For MFA support, please use Connect-DbaInstance.

    .PARAMETER Database
        Specifies one or more databases to test for S3 backup compatibility. Accepts wildcards for pattern matching.
        Use this when you need to check specific databases rather than all databases on the instance.

    .PARAMETER ExcludeDatabase
        Specifies one or more databases to exclude from S3 backup compatibility testing.
        Useful when you want to test most databases but need to skip system databases or specific user databases.

    .PARAMETER MaxTransferSize
        The MAXTRANSFERSIZE value in bytes to use for part count calculations. Default is 10MB (10485760 bytes).
        SQL Server supports values from 65536 (64KB) to 4194304 (4MB) for most versions, and up to 20MB for SQL Server 2016 SP1+.
        S3 backups typically use larger values like 10MB or 20MB for optimal performance.

    .PARAMETER Threshold
        The percentage of the 10,000 part limit at which to trigger warnings. Default is 90 (90% = 9,000 parts).
        Databases at or above this threshold will have Status set to "Warning" instead of "OK".
        Valid range is 1-100. Use lower values (e.g., 80) for earlier warnings, or higher values (e.g., 95) for fewer alerts.

    .PARAMETER Monitor
        When enabled, the function returns only databases that exceed or are within the threshold percentage of the S3 10,000 part limit, and throws an error if any are found.
        Use this switch in monitoring scripts or CI/CD pipelines to alert on databases that may fail S3 backup operations.
        When disabled (default), returns results for all databases without throwing errors.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Backup, S3, Cloud, AWS
        Author: the dbatools team + Claude

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/Test-DbaS3BackupCompatibility

    .OUTPUTS
        PSCustomObject

        Returns one object per database with backup history. Databases without backup history are excluded from results.

        Properties:
        - ComputerName: The computer name of the SQL Server instance
        - InstanceName: The SQL Server instance name
        - SqlInstance: The full SQL Server instance name (computer\instance)
        - Database: The name of the database being evaluated
        - LastFullBackup: DateTime of the most recent full backup
        - BackupSizeBytes: Total size of the backup in bytes
        - BackupSizeMB: Total size of the backup in megabytes
        - CompressedBackupSizeBytes: Compressed backup size in bytes (NULL if uncompressed)
        - CompressedBackupSizeMB: Compressed backup size in megabytes (NULL if uncompressed)
        - FileCount: Number of backup files in the backup set
        - MaxTransferSize: The MAXTRANSFERSIZE value used for calculations (in bytes)
        - CalculatedParts: Number of S3 multipart upload parts (backup_size / MAXTRANSFERSIZE / file_count)
        - PercentOfLimit: Percentage of the 10,000 part S3 limit (CalculatedParts / 10000 * 100)
        - IsCompatible: Boolean indicating if the backup is under the 10,000 part limit
        - Status: Status indicator - "OK", "Warning" (90-100% of limit), or "Exceeds Limit" (over 100%)
        - Recommendation: String with suggested configuration changes to get under the 10,000 part limit (NULL if compatible)
        - RecommendedMaxTransferSize: Suggested MAXTRANSFERSIZE in bytes to achieve compatibility (NULL if not applicable)
        - RecommendedFileCount: Suggested number of backup files to achieve compatibility (NULL if not applicable)

    .EXAMPLE
        PS C:\> Test-DbaS3BackupCompatibility -SqlInstance sql2019

        Tests all databases on sql2019 for S3 backup compatibility using the default 10MB MAXTRANSFERSIZE.

    .EXAMPLE
        PS C:\> Test-DbaS3BackupCompatibility -SqlInstance sql2019 -Database AdventureWorks -MaxTransferSize 20971520

        Tests the AdventureWorks database using a 20MB MAXTRANSFERSIZE value (20971520 bytes).

    .EXAMPLE
        PS C:\> Test-DbaS3BackupCompatibility -SqlInstance sql2019 -Monitor

        Tests all databases and returns only those that are at or above 90% of the S3 part limit, throwing an error if any are found.

    .EXAMPLE
        PS C:\> Test-DbaS3BackupCompatibility -SqlInstance sql2019 -Threshold 80

        Tests all databases and marks those at or above 80% of the S3 part limit (8,000 parts) as "Warning" status.

    .EXAMPLE
        PS C:\> Test-DbaS3BackupCompatibility -SqlInstance sql2019 -Threshold 95 -Monitor

        Tests all databases with a 95% threshold and returns only those at or above 9,500 parts, throwing an error if any are found.

    .EXAMPLE
        PS C:\> Get-DbaRegServer -SqlInstance sqlcms | Test-DbaS3BackupCompatibility -MaxTransferSize 10485760

        Tests all databases across all servers registered in the Central Management Server for S3 compatibility.

    .EXAMPLE
        PS C:\> Test-DbaS3BackupCompatibility -SqlInstance sql2019 | Where-Object PercentOfLimit -gt 80

        Tests all databases and filters to show only those using more than 80% of the S3 part limit.
    #>
    [CmdletBinding()]
    param (
        [parameter(Mandatory, ValueFromPipeline)]
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$SqlCredential,
        [object[]]$Database,
        [object[]]$ExcludeDatabase,
        [int64]$MaxTransferSize = 10485760,
        [ValidateRange(1, 100)]
        [int]$Threshold = 90,
        [switch]$Monitor,
        [switch]$EnableException
    )
    process {
        foreach ($instance in $SqlInstance) {
            try {
                $server = Connect-DbaInstance -SqlInstance $instance -SqlCredential $SqlCredential -MinimumVersion 9
            } catch {
                Stop-Function -Message "Failure" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
            }

            $databases = $server.Databases

            if ($Database) {
                $databases = $databases | Where-Object { $Database -contains $_.Name }
            }

            if ($ExcludeDatabase) {
                $databases = $databases | Where-Object Name -NotIn $ExcludeDatabase
            }

            $problemDatabases = @()

            foreach ($db in $databases) {
                Write-Message -Level Verbose -Message "Processing $($db.Name) on $instance."

                # Get the most recent full backup for this database
                $splatBackupHistory = @{
                    SqlInstance     = $server
                    Database        = $db.Name
                    LastFull        = $true
                    EnableException = $EnableException
                }
                $lastBackup = Get-DbaDbBackupHistory @splatBackupHistory

                if (-not $lastBackup) {
                    Write-Message -Level Verbose -Message "No backup history found for database $($db.Name)."
                    continue
                }

                # Get backup details
                $backupSizeBytes = $lastBackup.TotalSize
                $compressedSizeBytes = $lastBackup.CompressedBackupSize
                $fileCount = $lastBackup.Path.Count

                # Use compressed size if available, otherwise use uncompressed size
                $effectiveSize = if ($compressedSizeBytes -and $compressedSizeBytes -gt 0) {
                    $compressedSizeBytes
                } else {
                    $backupSizeBytes
                }

                # Calculate the number of parts for S3 multipart upload
                # Formula: backup_size / MAXTRANSFERSIZE / number_of_files
                if ($fileCount -gt 0 -and $MaxTransferSize -gt 0) {
                    $calculatedParts = [Math]::Ceiling($effectiveSize / $MaxTransferSize / $fileCount)
                } else {
                    $calculatedParts = 0
                }

                # Calculate percentage of the 10,000 part limit
                $percentOfLimit = if ($calculatedParts -gt 0) {
                    [Math]::Round(($calculatedParts / 10000) * 100, 2)
                } else {
                    0
                }

                # Determine status based on threshold
                $warningThreshold = [Math]::Ceiling(10000 * ($Threshold / 100))
                $isCompatible = $calculatedParts -lt 10000
                if ($calculatedParts -ge 10000) {
                    $status = "Exceeds Limit"
                } elseif ($calculatedParts -ge $warningThreshold) {
                    $status = "Warning"
                } else {
                    $status = "OK"
                }

                # Calculate recommendations for databases that exceed the limit
                $recommendation = $null
                $recommendedMaxTransferSize = $null
                $recommendedFileCount = $null
                $defaultMts = 10MB
                $maxFiles = 64

                if ($calculatedParts -ge 10000) {
                    # Priority order: 10MB (no compression) → 20MB → 5MB (last resort)
                    # For each MTS, try current files first, then increasing file count
                    $solutionFound = $false

                    # Priority 1: Try 10MB (default, no compression required)
                    if ($MaxTransferSize -lt $defaultMts) {
                        # Currently using less than 10MB, try upgrading to 10MB with current files
                        $testParts = [Math]::Ceiling($effectiveSize / $defaultMts / $fileCount)
                        if ($testParts -lt 10000) {
                            $recommendedMaxTransferSize = $defaultMts
                            $recommendation = "Increase MAXTRANSFERSIZE to 10MB"
                            $solutionFound = $true
                        }
                    }

                    # Priority 2: Try 10MB with more files (still no compression required)
                    if (-not $solutionFound -and $MaxTransferSize -le $defaultMts) {
                        $requiredFiles = [Math]::Ceiling($effectiveSize / (9999 * $defaultMts))
                        # Round up to nearest even number
                        if ($requiredFiles % 2 -ne 0) {
                            $requiredFiles++
                        }

                        if ($requiredFiles -le $maxFiles -and $requiredFiles -gt $fileCount) {
                            $recommendedFileCount = $requiredFiles
                            if ($MaxTransferSize -lt $defaultMts) {
                                $recommendedMaxTransferSize = $defaultMts
                                $recommendation = "Increase MAXTRANSFERSIZE to 10MB AND increase backup file count to $requiredFiles. Note: Multiple files increase network and storage I/O pressure."
                            } else {
                                $recommendation = "Increase backup file count to $requiredFiles. Note: Multiple files increase network and storage I/O pressure."
                            }
                            $solutionFound = $true
                        }
                    }

                    # Priority 3: Try 20MB with current files (requires compression)
                    if (-not $solutionFound) {
                        $testParts = [Math]::Ceiling($effectiveSize / 20MB / $fileCount)
                        if ($testParts -lt 10000) {
                            $recommendedMaxTransferSize = 20MB
                            $recommendation = "Increase MAXTRANSFERSIZE to 20MB (requires backup compression to be enabled, which will increase CPU usage on the SQL Server host)"
                            $solutionFound = $true
                        }
                    }

                    # Priority 4: Try 20MB with more files (requires compression)
                    if (-not $solutionFound) {
                        $requiredFiles = [Math]::Ceiling($effectiveSize / (9999 * 20MB))
                        # Round up to nearest even number
                        if ($requiredFiles % 2 -ne 0) {
                            $requiredFiles++
                        }

                        if ($requiredFiles -le $maxFiles) {
                            $recommendedMaxTransferSize = 20MB
                            $recommendedFileCount = $requiredFiles
                            $recommendation = "Increase MAXTRANSFERSIZE to 20MB AND increase backup file count to $requiredFiles (requires backup compression to be enabled, which will increase CPU usage on the SQL Server host). Note: Multiple files increase network and storage I/O pressure."
                            $solutionFound = $true
                        }
                    }

                    # Priority 5: Try 5MB with more files (last resort, requires compression)
                    if (-not $solutionFound) {
                        $requiredFiles = [Math]::Ceiling($effectiveSize / (9999 * 5MB))
                        # Round up to nearest even number
                        if ($requiredFiles % 2 -ne 0) {
                            $requiredFiles++
                        }

                        if ($requiredFiles -le $maxFiles) {
                            $recommendedMaxTransferSize = 5MB
                            $recommendedFileCount = $requiredFiles
                            $recommendation = "Increase MAXTRANSFERSIZE to 5MB AND increase backup file count to $requiredFiles (requires backup compression to be enabled, which will increase CPU usage on the SQL Server host). Note: Multiple files increase network and storage I/O pressure."
                            $solutionFound = $true
                        }
                    }

                    # If still no solution found
                    if (-not $solutionFound) {
                        $recommendation = "Backup too large for S3 multipart limits even with 20MB MAXTRANSFERSIZE and 64 files. Consider backup compression or splitting the database."
                    }
                } elseif ($MaxTransferSize -ne $defaultMts -and $status -eq "OK") {
                    # User is using non-default MTS but backup is compatible
                    # Remind them that compression is required
                    $recommendation = "Using non-default MAXTRANSFERSIZE ($([Math]::Round($MaxTransferSize / 1MB, 2))MB) requires backup compression to be enabled, which will increase CPU usage on the SQL Server host."
                }

                $result = [PSCustomObject]@{
                    ComputerName              = $server.ComputerName
                    InstanceName              = $server.ServiceName
                    SqlInstance               = $server.DomainInstanceName
                    Database                  = $db.Name
                    LastFullBackup            = $lastBackup.Start
                    BackupSizeBytes           = $backupSizeBytes
                    BackupSizeMB              = [Math]::Round($backupSizeBytes / 1MB, 2)
                    CompressedBackupSizeBytes = $compressedSizeBytes
                    CompressedBackupSizeMB    = if ($compressedSizeBytes) { [Math]::Round($compressedSizeBytes / 1MB, 2) } else { $null }
                    FileCount                 = $fileCount
                    MaxTransferSize           = $MaxTransferSize
                    CalculatedParts           = $calculatedParts
                    PercentOfLimit            = $percentOfLimit
                    IsCompatible              = $isCompatible
                    Status                    = $status
                    Recommendation            = $recommendation
                    RecommendedMaxTransferSize = $recommendedMaxTransferSize
                    RecommendedFileCount      = $recommendedFileCount
                }

                # If Monitor mode, only collect problem databases
                if ($Monitor) {
                    if ($status -eq "Warning" -or $status -eq "Exceeds Limit") {
                        $problemDatabases += $result
                        $result
                    }
                } else {
                    # Normal mode - output all results
                    $result
                }
            }

            # If Monitor mode and we found problems, throw an error
            if ($Monitor -and $problemDatabases.Count -gt 0) {
                $exceedsCount = ($problemDatabases | Where-Object Status -eq "Exceeds Limit").Count
                $warningCount = ($problemDatabases | Where-Object Status -eq "Warning").Count
                $message = "S3 backup compatibility issues found: $exceedsCount database(s) exceed the limit, $warningCount database(s) at warning threshold (90%+)."
                Stop-Function -Message $message -EnableException $EnableException -Category InvalidResult
            }
        }
    }
}

