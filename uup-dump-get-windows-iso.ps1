#!/usr/bin/pwsh
param(
    [string]$windowsTargetName,
    [string]$destinationDirectory='output'
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
trap {
    Write-Host "ERROR: $_"
    @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1') | Write-Host
    @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1') | Write-Host
    Exit 1
}

$TARGETS = @{
    # see https://en.wikipedia.org/wiki/Windows_11
    # see https://en.wikipedia.org/wiki/Windows_11_version_history
    "windows-11" = @{
        search = "windows 11 26200 amd64" # aka 25H2
        edition = "Professional"
        virtualEdition = "Enterprise"
    }
    # see https://en.wikipedia.org/wiki/Windows_Server_2022
    "windows-2022" = @{
        search = "feature update server operating system 20348 amd64" # aka 21H2. Mainstream EOL: October 13, 2026.
        edition = "ServerStandard"
        virtualEdition = $null
    }
}

$UUP_WEB_BASE_URL = 'https://uup-api-production.up.railway.app'
$UUP_JSON_API_BASE_URL = "$UUP_WEB_BASE_URL/json-api"

function New-QueryString([hashtable]$parameters) {
    @($parameters.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
    }) -join '&'
}

function Invoke-UupDumpApi([string]$name, [hashtable]$body) {
    # see https://git.uupdump.net/uup-dump/json-api
    for ($n = 0; $n -lt 15; ++$n) {
        if ($n) {
            Write-Host "Waiting a bit before retrying the uup-dump api ${name} request #$n"
            Start-Sleep -Seconds 10
            Write-Host "Retrying the uup-dump api ${name} request #$n"
        }
        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri "$UUP_JSON_API_BASE_URL/$name.php" `
                -Body $body
        } catch {
            Write-Host "WARN: failed the uup-dump api $name request: $_"
        }
    }
    throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpBuildRows($builds) {
    if ($null -eq $builds) {
        return @()
    }

    if ($builds -is [array]) {
        return @($builds)
    }

    if ($builds -is [hashtable]) {
        return @($builds.Values)
    }

    if ($builds.PSObject.Properties.Name -contains 'uuid') {
        return @($builds)
    }

    $values = @($builds.PSObject.Properties | ForEach-Object { $_.Value })
    if ($values.Count -gt 0 -and $values[0] -and $values[0].PSObject.Properties.Name -contains 'uuid') {
        return $values
    }

    return @()
}

function Get-UupDumpKeys($value) {
    if ($null -eq $value) {
        return @()
    }

    if ($value -is [hashtable]) {
        return @($value.Keys)
    }

    if ($value -is [array]) {
        if ($value.Count -eq 0) {
            return @()
        }

        if ($value[0] -is [string]) {
            return @($value)
        }

        if ($value[0].PSObject.Properties.Name -contains 'Name') {
            return @($value | ForEach-Object { $_.Name })
        }

        if ($value[0].PSObject.Properties.Name -contains 'Key') {
            return @($value | ForEach-Object { $_.Key })
        }

        return @()
    }

    $propertyNames = @($value.PSObject.Properties.Name)
    if ($propertyNames.Count -gt 0) {
        return $propertyNames
    }

    return @()
}

function Get-UupDumpIso($name, $target) {
    Write-Host "Getting the $name metadata"
    $result = Invoke-UupDumpApi listid @{
        search = $target.search
    }

    $buildRows = Get-UupDumpBuildRows $result.response.builds
    if ($buildRows.Count -eq 0) {
        throw "listid returned no builds for search '$($target.search)'"
    }

    $buildRows `
        | ForEach-Object {
            $id = $_.uuid
            $uupDumpUrl = "$UUP_WEB_BASE_URL/selectlang.php?" + (New-QueryString @{
                id = $id
            })
            Write-Host "Processing $name $id ($uupDumpUrl)"
            $_
        } `
        | Where-Object {
            # ignore previews when they are not explicitly requested.
            $result = $target.search -like '*preview*' -or $_.title -notlike '*preview*'
            if (!$result) {
                Write-Host "Skipping. Expected preview=false. Got preview=true."
            }
            $result
        } `
        | ForEach-Object {
            # get more information about the build. eg:
            #   "langs": {
            #     "en-us": "English (United States)",
            #     "pt-pt": "Portuguese (Portugal)",
            #     ...
            #   },
            #   "info": {
            #     "title": "Feature update to Microsoft server operating system, version 21H2 (20348.643)",
            #     "ring": "RETAIL",
            #     "flight": "Active",
            #     "arch": "amd64",
            #     "build": "20348.643",
            #     "checkBuild": "10.0.20348.1",
            #     "sku": 8,
            #     "created": 1649783041,
            #     "sha256ready": true
            #   }
            $id = $_.uuid
            Write-Host "Getting the $name $id langs metadata"
            $result = Invoke-UupDumpApi listlangs @{
                id = $id
            }
            if ($result.response.updateInfo.build -ne $_.build) {
                throw 'for some reason listlangs returned an unexpected build'
            }
            $langs = Get-UupDumpKeys $result.response.langFancyNames
            if ($langs.Count -eq 0 -and $result.response.PSObject.Properties.Name -contains 'langList') {
                $langs = @($result.response.langList)
            }
            $_ | Add-Member -NotePropertyMembers @{
                langs = $langs
                info = $result.response.updateInfo
            } -Force
            $editions = if ($langs -contains 'en-us') {
                Write-Host "Getting the $name $id editions metadata"
                $result = Invoke-UupDumpApi listeditions @{
                    id = $id
                    lang = 'en-us'
                }
                Get-UupDumpKeys $result.response.editionFancyNames
            } else {
                Write-Host "Skipping. Expected langs=en-us. Got langs=$($langs -join ',')."
                @()
            }
            $_ | Add-Member -NotePropertyMembers @{
                editions = $editions
            } -Force
            $_
        } `
        | Where-Object {
            # only return builds that:
            #   1. are from the expected ring/channel (default retail)
            #   2. have the english language
            #   3. match the requested edition
            $ring = $_.info.ring
            $langs = @($_.langs)
            $editions = @($_.editions)
            $result = $true
            $expectedRing = if ($target.PSObject.Properties.Name -contains 'ring') {
                $target.ring
            } else {
                'RETAIL'
            }
            if ($ring -ne $expectedRing) {
                Write-Host "Skipping. Expected ring=$expectedRing. Got ring=$ring."
                $result = $false
            }
            if ($langs -notcontains 'en-us') {
                Write-Host "Skipping. Expected langs=en-us. Got langs=$($langs -join ',')."
                $result = $false
            }
            if ($editions -notcontains $target.edition) {
                Write-Host "Skipping. Expected editions=$($target.edition). Got editions=$($editions -join ',')."
                $result = $false
            }
            $result
        } `
        | Select-Object -First 1 `
        | ForEach-Object {
            $id = $_.uuid
            [PSCustomObject]@{
                name = $name
                title = $_.title
                build = $_.build
                id = $id
                edition = $target.edition
                virtualEdition = $target.virtualEdition
                apiUrl = "$UUP_JSON_API_BASE_URL/get.php?" + (New-QueryString @{
                    id = $id
                    lang = 'en-us'
                    edition = $target.edition
                    #noLinks = '1' # do not return the files download urls.
                })
                downloadUrl = "$UUP_WEB_BASE_URL/download.php?" + (New-QueryString @{
                    id = $id
                    pack = 'en-us'
                    edition = $target.edition
                })
                # NB you must use the HTTP POST method to invoke this packageUrl
                #    AND in the body you must include:
                #           autodl=2 updates=1 cleanup=1
                #           OR
                #           autodl=3 updates=1 cleanup=1 virtualEditions[]=Enterprise
                downloadPackageUrl = "$UUP_WEB_BASE_URL/get.php?" + (New-QueryString @{
                    id = $id
                    pack = 'en-us'
                    edition = $target.edition
                })
            }
        }
}

function Get-IsoWindowsImages($isoPath) {
    $isoPath = Resolve-Path $isoPath
    Write-Host "Mounting $isoPath"
    $isoImage = Mount-DiskImage $isoPath -PassThru
    try {
        $isoVolume = $isoImage | Get-Volume
        $installPath = "$($isoVolume.DriveLetter):\sources\install.wim"
        Write-Host "Getting Windows images from $installPath"
        Get-WindowsImage -ImagePath $installPath `
            | ForEach-Object {
                $image = Get-WindowsImage `
                    -ImagePath $installPath `
                    -Index $_.ImageIndex
                $imageVersion = $image.Version
                [PSCustomObject]@{
                    index = $image.ImageIndex
                    name = $image.ImageName
                    version = $imageVersion
                }
            }
    } finally {
        Write-Host "Dismounting $isoPath"
        Dismount-DiskImage $isoPath | Out-Null
    }
}

function Get-WindowsIso($name, $destinationDirectory) {
    $iso = Get-UupDumpIso $name $TARGETS.$name

    # ensure the build is a version number.
    if ($iso.build -notmatch '^\d+\.\d+$') {
        throw "unexpected $name build: $($iso.build)"
    }

    $buildDirectory = "$destinationDirectory/$name"
    $destinationIsoPath = "$buildDirectory.iso"
    $destinationIsoMetadataPath = "$destinationIsoPath.json"
    $destinationIsoChecksumPath = "$destinationIsoPath.sha256.txt"

    # create the build directory.
    if (Test-Path $buildDirectory) {
        Remove-Item -Force -Recurse $buildDirectory | Out-Null
    }
    New-Item -ItemType Directory -Force $buildDirectory | Out-Null

    # define the iso title.
    $edition = if ($iso.virtualEdition) {
        $iso.virtualEdition
    } else {
        $iso.edition
    }
    $title = "$name $edition $($iso.build)"

    Write-Host "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
    $downloadPackageBody = if ($iso.virtualEdition) {
        @{
            autodl = 3
            updates = 1
            cleanup = 1
            'virtualEditions[]' = $iso.virtualEdition
        }
    } else {
        @{
            autodl = 2
            updates = 1
            cleanup = 1
        }
    }
    Invoke-WebRequest `
        -Method Post `
        -Uri $iso.downloadPackageUrl `
        -Body $downloadPackageBody `
        -OutFile "$buildDirectory.zip" `
        | Out-Null
    Expand-Archive "$buildDirectory.zip" $buildDirectory

    # patch the uup-converter configuration.
    # see the ConvertConfig $buildDirectory/ReadMe.html documentation.
    # see https://github.com/abbodi1406/BatUtil/tree/master/uup-converter-wimlib
    $convertConfig = (Get-Content $buildDirectory/ConvertConfig.ini) `
        -replace '^(AutoExit\s*)=.*','$1=1' `
        -replace '^(ResetBase\s*)=.*','$1=1' `
        -replace '^(SkipWinRE\s*)=.*','$1=1'
    if ($iso.virtualEdition) {
        $convertConfig = $convertConfig `
            -replace '^(StartVirtual\s*)=.*','$1=1' `
            -replace '^(vDeleteSource\s*)=.*','$1=1' `
            -replace '^(vAutoEditions\s*)=.*',"`$1=$($iso.virtualEdition)"
    }
    Set-Content `
        -Encoding ascii `
        -Path $buildDirectory/ConvertConfig.ini `
        -Value $convertConfig

    Write-Host "Creating the $title iso file inside the $buildDirectory directory"
    Push-Location $buildDirectory
    # NB we have to use powershell cmd to workaround:
    #       https://github.com/PowerShell/PowerShell/issues/6850
    #       https://github.com/PowerShell/PowerShell/pull/11057
    # NB we have to use | Out-String to ensure that this powershell instance
    #    waits until all the processes that are started by the .cmd are
    #    finished.
    powershell cmd /c uup_download_windows.cmd | Out-String -Stream
    if ($LASTEXITCODE) {
        throw "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
    }
    Pop-Location

    $sourceIsoPath = Resolve-Path $buildDirectory/*.iso

    Write-Host "Getting the $sourceIsoPath checksum"
    $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
    Set-Content -Encoding ascii -NoNewline `
        -Path $destinationIsoChecksumPath `
        -Value $isoChecksum

    $windowsImages = Get-IsoWindowsImages $sourceIsoPath

    # create the iso metadata file.
    Set-Content `
        -Path $destinationIsoMetadataPath `
        -Value (
            ([PSCustomObject]@{
                name = $name
                title = $iso.title
                build = $iso.build
                checksum = $isoChecksum
                images = @($windowsImages)
                uupDump = @{
                    id = $iso.id
                    apiUrl = $iso.apiUrl
                    downloadUrl = $iso.downloadUrl
                    downloadPackageUrl = $iso.downloadPackageUrl
                }
            } | ConvertTo-Json -Depth 99) -replace '\\u0026','&'
        )

    Write-Host "Moving the created $sourceIsoPath to $destinationIsoPath"
    Move-Item -Force $sourceIsoPath $destinationIsoPath

    Write-Host 'All Done.'
}

Get-WindowsIso $windowsTargetName $destinationDirectory
