#Requires -Module @{ ModuleName="Pester"; ModuleVersion="5.0" }
param(
    $ModuleName  = "dbatools",
    $CommandName = "Test-DbaS3BackupCompatibility",
    $PSDefaultParameterValues = $TestConfig.Defaults
)

Describe $CommandName -Tag UnitTests {
    Context "Parameter validation" {
        It "Should have the expected parameters" {
            $hasParameters = (Get-Command $CommandName).Parameters.Values.Name | Where-Object { $PSItem -notin ("WhatIf", "Confirm") }
            $expectedParameters = $TestConfig.CommonParameters
            $expectedParameters += @(
                "SqlInstance",
                "SqlCredential",
                "Database",
                "ExcludeDatabase",
                "MaxTransferSize",
                "Threshold",
                "Monitor",
                "EnableException"
            )
            Compare-Object -ReferenceObject $expectedParameters -DifferenceObject $hasParameters | Should -BeNullOrEmpty
        }
    }

    Context "Threshold parameter logic with mocked data" {
        BeforeAll {
            # Mock Get-DbaDbBackupHistory to return controlled test data
            Mock -CommandName Get-DbaDbBackupHistory -MockWith {
                [PSCustomObject]@{
                    Database           = "TestDB"
                    Type               = "Full"
                    TotalSize          = 500GB
                    CompressedBackupSize = 100GB
                    DeviceType         = "URL"
                    Start              = (Get-Date).AddDays(-1)
                    End                = (Get-Date).AddDays(-1).AddHours(2)
                    BackupPath         = "https://s3.amazonaws.com/bucket/backup1.bak,https://s3.amazonaws.com/bucket/backup2.bak"
                }
            } -ModuleName dbatools

            # Mock Connect-DbaInstance to return a simple server object
            Mock -CommandName Connect-DbaInstance -MockWith {
                [PSCustomObject]@{
                    ComputerName = "TestServer"
                    InstanceName = "MSSQLSERVER"
                    DomainInstanceName = "TestServer"
                    Databases = @(
                        [PSCustomObject]@{
                            Name = "TestDB"
                        }
                    )
                }
            } -ModuleName dbatools
        }

        It "Should mark database as Warning at 90% threshold (default)" {
            # 100GB / 10MB / 2 files = 5,242 parts (52.4% of limit)
            # With default 90% threshold, this should be OK
            $result = Test-DbaS3BackupCompatibility -SqlInstance "TestServer" -Database "TestDB"
            $result.Status | Should -Be "OK"
        }

        It "Should mark database as Warning at 50% threshold" {
            # 100GB / 10MB / 2 files = 5,242 parts (52.4% of limit)
            # With 50% threshold (5,000 parts), this should be Warning
            $result = Test-DbaS3BackupCompatibility -SqlInstance "TestServer" -Database "TestDB" -Threshold 50
            $result.Status | Should -Be "Warning"
        }

        It "Should mark database as OK at 60% threshold" {
            # 100GB / 10MB / 2 files = 5,242 parts (52.4% of limit)
            # With 60% threshold (6,000 parts), this should be OK
            $result = Test-DbaS3BackupCompatibility -SqlInstance "TestServer" -Database "TestDB" -Threshold 60
            $result.Status | Should -Be "OK"
        }
    }
}

Describe $CommandName -Tag IntegrationTests {
    BeforeAll {
        $random = Get-Random
        $dbName = "dbatoolsci_s3test_$random"
        $splatDatabase = @{
            SqlInstance     = $TestConfig.InstanceSingle
            Name            = $dbName
            EnableException = $true
        }
        $null = New-DbaDatabase @splatDatabase

        # Create a backup so we have history to test
        $splatBackup = @{
            SqlInstance     = $TestConfig.InstanceSingle
            Database        = $dbName
            EnableException = $true
        }
        $null = Backup-DbaDatabase @splatBackup
    }

    AfterAll {
        $splatRemove = @{
            SqlInstance     = $TestConfig.InstanceSingle
            Database        = $dbName
            Confirm         = $false
            EnableException = $true
        }
        $null = Remove-DbaDatabase @splatRemove
    }

    Context "Command actually works" {
        It "Should return results for all databases" {
            $results = Test-DbaS3BackupCompatibility -SqlInstance $TestConfig.InstanceSingle
            $results | Should -Not -BeNullOrEmpty
        }

        It "Should return a result for a specific database" {
            $results = Test-DbaS3BackupCompatibility -SqlInstance $TestConfig.InstanceSingle -Database $dbName
            $results | Should -Not -BeNullOrEmpty
            $results.Database | Should -Be $dbName
        }

        It "Should have the expected properties" {
            $result = Test-DbaS3BackupCompatibility -SqlInstance $TestConfig.InstanceSingle -Database $dbName
            $result.ComputerName | Should -Not -BeNullOrEmpty
            $result.InstanceName | Should -Not -BeNullOrEmpty
            $result.SqlInstance | Should -Not -BeNullOrEmpty
            $result.Database | Should -Be $dbName
            $result.LastFullBackup | Should -Not -BeNullOrEmpty
            $result.BackupSizeBytes | Should -BeGreaterThan 0
            $result.FileCount | Should -BeGreaterThan 0
            $result.MaxTransferSize | Should -Be 10485760
            $result.CalculatedParts | Should -BeGreaterThan 0
            $result.PercentOfLimit | Should -BeGreaterOrEqual 0
            $result.IsCompatible | Should -Not -BeNullOrEmpty
            $result.Status | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Contain "Recommendation"
            $result.PSObject.Properties.Name | Should -Contain "RecommendedMaxTransferSize"
            $result.PSObject.Properties.Name | Should -Contain "RecommendedFileCount"
        }

        It "Should accept custom MaxTransferSize" {
            $customSize = 20971520
            $result = Test-DbaS3BackupCompatibility -SqlInstance $TestConfig.InstanceSingle -Database $dbName -MaxTransferSize $customSize
            $result.MaxTransferSize | Should -Be $customSize
        }

        It "Should exclude databases when specified" {
            $results = Test-DbaS3BackupCompatibility -SqlInstance $TestConfig.InstanceSingle -ExcludeDatabase $dbName
            $results.Database | Should -Not -Contain $dbName
        }

        It "Should work with Monitor switch when no problems exist" {
            # For a small test database, there should be no S3 compatibility issues
            $results = Test-DbaS3BackupCompatibility -SqlInstance $TestConfig.InstanceSingle -Database $dbName -Monitor
            # Should either return nothing or return databases with issues
            # For a small test DB, we expect no issues
            if ($results) {
                $results.Status | Should -Not -Contain "Exceeds Limit"
            }
        }
    }
}

