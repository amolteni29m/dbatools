function New-DbaDbDataGeneratorConfig {
    <#
    .SYNOPSIS
        Generates a new data generation configuration file.

    .DESCRIPTION
        Generates a new data generation configuration file. This file is important to apply any data generation to a table in a database.

        Read more here:
        https://sachabarbs.wordpress.com/2018/06/11/bogus-simple-fake-data-tool/
        https://github.com/bchavez/Bogus

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Windows and SQL Authentication supported. Accepts credential objects (Get-Credential)

    .PARAMETER Database
        Databases to process through

    .PARAMETER Table
        Tables to process. By default all the tables will be processed

    .PARAMETER ResetIdentity
        Resets the identity column for a table to it's starting value. By default it will continue with the next identity.

    .PARAMETER TruncateTable
        Truncates the tabel befoe inserting the values

    .PARAMETER Rows
        Amount of rows that need to be generated. The default is 1000.

    .PARAMETER Path
        Path where to save the generated JSON files.
        The naming convention will be "servername.databasename.tables.json"

    .PARAMETER Force
        Forcefully execute commands when needed

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: DataGeneration, Database
        Author: Sander Stad (@sqlstad, sqlstad.nl)

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/New-DbaDbDataGeneratorConfig

    .EXAMPLE
        New-DbaDbDataGeneratorConfig -SqlInstance SQLDB1 -Database DB1 -Path C:\Temp\clone

        Process all tables and columns for database DB1 on instance SQLDB1

    .EXAMPLE
        New-DbaDbDataGeneratorConfig -SqlInstance SQLDB1 -Database DB1 -Table Customer -Path C:\Temp\clone

        Process only table Customer with all the columns

    #>
    [CmdLetBinding()]
    param (
        [parameter(Mandatory)]
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$SqlCredential,
        [string[]]$Database,
        [string[]]$Table,
        [switch]$ResetIdentity,
        [switch]$TruncateTable,
        [int]$Rows = 1000,
        [parameter(Mandatory)]
        [string]$Path,
        [switch]$Force,
        [switch]$EnableException
    )

    begin {

        # Get all the different column types
        try {
            $columnTypes = Get-Content -Path "$script:PSModuleRoot\bin\datamasking\columntypes.json" | ConvertFrom-Json
        } catch {
            Stop-Function -Message "Something went wrong importing the column types" -Continue
        }

        # Check if the Path is accessible
        if (-not (Test-Path -Path $Path)) {
            try {
                $null = New-Item -Path $Path -ItemType Directory -Force:$Force
            } catch {
                Stop-Function -Message "Could not create Path directory" -ErrorRecord $_ -Target $Path
            }
        } else {
            if ((Get-Item $path) -isnot [System.IO.DirectoryInfo]) {
                Stop-Function -Message "$Path is not a directory"
            }
        }
    }

    process {
        if (Test-FunctionInterrupt) {
            return
        }

        if ($SqlInstance) {
            $InputObject += Get-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database
        }

        $results = @()

        if ($InputObject.Count -lt 1) {
            Stop-Function -Message "No databases found" -Target $Database
            return
        }

        foreach ($db in $InputObject) {
            $server = $db.Parent
            $tables = @()

            # Get the tables
            if ($Table) {
                $tablecollection = $db.Tables | Where-Object Name -in $Table
            } else {
                $tablecollection = $db.Tables
            }

            if ($tablecollection.Count -lt 1) {
                Stop-Function -Message "The database does not contain any tables" -Target $db -Continue
            }

            # Loop through the tables
            foreach ($tableobject in $tablecollection) {
                Write-Message -Message "Processing table $($tableobject.Name)" -Level Verbose

                $hasUniqueIndex = $false

                if ($tableobject.Indexes.IsUnique) {
                    $hasUniqueIndex = $true
                }

                $columns = @()

                # Get the columns
                [array]$columncollection = $tableobject.Columns

                foreach ($columnobject in $columncollection) {
                    if ($columnobject.Computed) {
                        Write-Message -Level Verbose -Message "Skipping $columnobject because it is a computed column"
                        continue
                    }
                    if ($columnobject.DataType.Name -eq 'hierarchyid') {
                        Write-Message -Level Verbose -Message "Skipping $columnobject because it is a hierarchyid column"
                        continue
                    }
                    if ($columnobject.DataType.Name -eq 'geography') {
                        Write-Message -Level Verbose -Message "Skipping $columnobject because it is a geography column"
                        continue
                    }
                    if ($columnobject.DataType.Name -eq 'geometry') {
                        Write-Message -Level Verbose -Message "Skipping $columnobject because it is a geometry column"
                        continue
                    }
                    if ($columnobject.DataType.SqlDataType.ToString().ToLower() -eq 'xml') {
                        Write-Message -Level Verbose -Message "Skipping $columnobject because it is a xml column"
                        continue
                    }

                    $dataGenType = $min = $null
                    $columnLength = $columnobject.Datatype.MaximumLength
                    $columnType = $columnobject.DataType.SqlDataType.ToString().ToLower()

                    if ($columnobject.InPrimaryKey -and $columnobject.DataType.SqlDataType.ToString().ToLower() -notmatch 'date') {
                        $min = 2
                    }
                    if (-not $columnType) {
                        $columnType = $columnobject.DataType.Name.ToLower()
                    }

                    # Get the masking type with the synonym
                    $dataGenType = $columnTypes | Where-Object {
                        $columnobject.Name -in $_.Synonym
                    }

                    if ($dataGenType) {
                        # Make it easier to get the type name
                        $dataGenType = $dataGenType | Select-Object TypeName -ExpandProperty TypeName

                        switch ($dataGenType.ToLower()) {
                            "firstname" {
                                $columns += [PSCustomObject]@{
                                    Name            = $columnobject.Name
                                    ColumnType      = $columnType
                                    CharacterString = $null
                                    MinValue        = $min
                                    MaxValue        = $columnLength
                                    MaskingType     = "Name"
                                    SubType         = "Firstname"
                                    Identity        = $columnobject.Identity
                                    ForeignKey      = $columnobject.IsForeignKey
                                    Nullable        = $columnobject.Nullable
                                }
                            }
                            "lastname" {
                                $columns += [PSCustomObject]@{
                                    Name            = $columnobject.Name
                                    ColumnType      = $columnType
                                    CharacterString = $null
                                    MinValue        = $min
                                    MaxValue        = $columnLength
                                    MaskingType     = "Name"
                                    SubType         = "Lastname"
                                    Identity        = $columnobject.Identity
                                    ForeignKey      = $columnobject.IsForeignKey
                                    Nullable        = $columnobject.Nullable
                                }
                            }
                            "creditcard" {
                                $columns += [PSCustomObject]@{
                                    Name            = $columnobject.Name
                                    ColumnType      = $columnType
                                    CharacterString = $null
                                    MinValue        = $min
                                    MaxValue        = $columnLength
                                    MaskingType     = "Finance"
                                    SubType         = "CreditcardNumber"
                                    Identity        = $columnobject.Identity
                                    ForeignKey      = $columnobject.IsForeignKey
                                    Nullable        = $columnobject.Nullable
                                }
                            }
                            "address" {
                                $columns += [PSCustomObject]@{
                                    Name            = $columnobject.Name
                                    ColumnType      = $columnType
                                    CharacterString = $null
                                    MinValue        = $min
                                    MaxValue        = $columnLength
                                    MaskingType     = "Address"
                                    SubType         = "StreetAddress"
                                    Identity        = $columnobject.Identity
                                    ForeignKey      = $columnobject.IsForeignKey
                                    Nullable        = $columnobject.Nullable
                                }
                            }
                            "city" {
                                $columns += [PSCustomObject]@{
                                    Name            = $columnobject.Name
                                    ColumnType      = $columnType
                                    CharacterString = $null
                                    MinValue        = $min
                                    MaxValue        = $columnLength
                                    MaskingType     = "Address"
                                    SubType         = "City"
                                    Identity        = $columnobject.Identity
                                    ForeignKey      = $columnobject.IsForeignKey
                                    Nullable        = $columnobject.Nullable
                                }
                            }
                            "zipcode" {
                                $columns += [PSCustomObject]@{
                                    Name            = $columnobject.Name
                                    ColumnType      = $columnType
                                    CharacterString = $null
                                    MinValue        = $min
                                    MaxValue        = $columnLength
                                    MaskingType     = "Address"
                                    SubType         = "Zipcode"
                                    Identity        = $columnobject.Identity
                                    ForeignKey      = $columnobject.IsForeignKey
                                    Nullable        = $columnobject.Nullable
                                }
                            }
                        }
                    } else {
                        $type = "Random"

                        switch ($columnType) {
                            { $_ -in "bit", "bool" } {
                                $subType = "Bool"
                                $MaxValue = $null
                            }
                            "bigint" {
                                $subType = "Number"
                                $MaxValue = 9223372036854775807
                            }
                            "int" {
                                $subType = "Number"
                                $MaxValue = 2147483647
                            }
                            "date" {
                                $subType = "Date"
                                $MaxValue = $null
                            }
                            "datetime" {
                                $subType = "Date"
                                $MaxValue = $null
                            }
                            "datetime2" {
                                $subType = "Date"
                                $MaxValue = $null
                            }
                            "float" {
                                $subType = "Float"
                                $MaxValue = $null
                            }
                            "smallint" {
                                $subType = "Number"
                                $MaxValue = 32767
                            }
                            "smalldatetime" {
                                $subType = "Date"
                                $MaxValue = $null
                            }
                            "tinyint" {
                                $subType = "Number"
                                $MaxValue = 255
                            }
                            "varbinary" {
                                $subType = "Byte"
                                $MaxValue = $columnLength
                            }
                            "varbinary" {
                                $subType = "Byte"
                                $MaxValue = $columnLength
                            }
                            "userdefineddatatype" {
                                if ($columnLength -eq 1) {
                                    $subType = "Bool"
                                    $MaxValue = $columnLength
                                } else {
                                    $subType = "String"
                                    $MaxValue = $columnLength
                                }
                            }
                            default {
                                $subType = "String"
                                $MaxValue = $columnLength
                            }
                        }

                        $columns += [PSCustomObject]@{
                            Name            = $columnobject.Name
                            ColumnType      = $columnType
                            CharacterString = $null
                            MinValue        = $min
                            MaxValue        = $MaxValue
                            MaskingType     = $type
                            SubType         = $subType
                            Identity        = $columnobject.Identity
                            ForeignKey      = $columnobject.IsForeignKey
                            Nullable        = $columnobject.Nullable
                        }
                    }
                }


                # Check if something needs to be generated
                if ($columns) {
                    $tables += [PSCustomObject]@{
                        Name           = $tableobject.Name
                        Schema         = $tableobject.Schema
                        Columns        = $columns
                        ResetIdentity  = [bool]$ResetIdentity
                        TruncateTable  = [bool]$TruncateTable
                        HasUniqueIndex = [bool]$hasUniqueIndex
                        Rows           = $Rows
                    }
                } else {
                    Write-Message -Message "No columns match for data generation in table $($tableobject.Name)" -Level Verbose
                }
            }

            # Check if something needs to be generated
            if ($tables) {
                $results += [PSCustomObject]@{
                    Name   = $db.Name
                    Tables = $tables
                }
            } else {
                Write-Message -Message "No columns match for data generation in table $($tableobject.Name)" -Level Verbose
            }
        }

        # Write the data to the Path
        if ($results) {
            try {
                $temppath = "$Path\$($server.Name.Replace('\', '$')).$($db.Name).tables.json"
                if (-not $script:isWindows) {
                    $temppath = $temppath.Replace("\", "/")
                }

                Set-Content -Path $temppath -Value ($results | ConvertTo-Json -Depth 5)
                Get-ChildItem -Path $temppath
            } catch {
                Stop-Function -Message "Something went wrong writing the results to the Path" -Target $Path -Continue -ErrorRecord $_
            }
        } else {
            Write-Message -Message "No tables to save for database $($db.Name) on $($server.Name)" -Level Verbose
        }
    }
}