#!/usr/bin/pwsh
param(
    [string]$windowsTargetName,
    [string]$destinationDirectory='output',
    [string]$build,
    [string]$search,
    [string]$edition,
    [string]$virtualEdition,
    [string]$ring,
    [string]$arch='amd64'
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
        search = "windows 11 amd64"
        edition = "Professional"
        virtualEdition = "Enterprise"
    }
    "windows-10" = @{
        search = "windows 10 amd64"
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

function Resolve-UupDumpTarget($windowsTargetName, $build, $search, $edition, $virtualEdition, $ring, $arch) {
    $name = $windowsTargetName
    if ([string]::IsNullOrWhiteSpace($name)) {
        if (-not [string]::IsNullOrWhiteSpace($search)) {
            $name = 'custom'
        } else {
            $name = 'windows-11'
        }
    }

    $target = $null
    if ($TARGETS.ContainsKey($name)) {
        $target = @{}
        foreach ($k in $TARGETS[$name].Keys) {
            $target[$k] = $TARGETS[$name][$k]
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($search)) {
        $target = @{}
    } else {
        throw "Unknown target '$name'. Use windows-10, windows-11, windows-2022, or pass -search."
    }

    $targetSearch = if (-not [string]::IsNullOrWhiteSpace($search)) {
        $search
    } elseif (-not [string]::IsNullOrWhiteSpace($build) -and ($name -eq 'windows-10' -or $name -eq 'windows-11')) {
        "$($name -replace '-', ' ') $build $arch"
    } else {
        $target.search
    }

    if ([string]::IsNullOrWhiteSpace($targetSearch)) {
        throw 'A search query could not be determined. Provide -search or a known target.'
    }

    $targetEdition = if (-not [string]::IsNullOrWhiteSpace($edition)) {
        $edition
    } elseif ($target.ContainsKey('edition')) {
        $target.edition
    } else {
        'Professional'
    }

    $targetVirtualEdition = if ($PSBoundParameters.ContainsKey('virtualEdition')) {
        $virtualEdition
    } elseif ($target.ContainsKey('virtualEdition')) {
        $target.virtualEdition
    } elseif ($name -eq 'windows-10' -or $name -eq 'windows-11') {
        'Enterprise'
    } else {
        $null
    }

    $targetRing = if (-not [string]::IsNullOrWhiteSpace($ring)) {
        $ring
    } elseif ($target.ContainsKey('ring')) {
        $target.ring
    } else {
        'RETAIL'
    }

    return [PSCustomObject]@{
        name = $name
        target = @{
            search = $targetSearch
            edition = $targetEdition
            virtualEdition = $targetVirtualEdition
            ring = $targetRing
        }
    }
}

$UUP_WEB_BASE_URL = 'https://uup-api-production.up.railway.app'
$UUP_JSON_API_BASE_URL = "$UUP_WEB_BASE_URL/json-api"
$UUP_FALLBACK_WEB_BASE_URL = 'https://uupdump.net'
$UUP_JSON_API_FALLBACK_BASE_URL = 'https://uupdump.net/json-api'

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
            $errorText = "$_ $($_.Exception.Message) $($_.ErrorDetails.Message)"
            if ($errorText -match 'UNSUPPORTED_LANG|UNSUPPORTED_ID|INVALID_PARAM|MISSING_PARAM') {
                throw
            }
            Write-Host "WARN: failed the uup-dump api $name request: $_"
        }
    }
    throw "timeout making the uup-dump api $name request"
}

function Invoke-UupDumpApiFallback([string]$name, [hashtable]$body) {
    # Fallback to upstream when the Railway API has incomplete transient metadata.
    for ($n = 0; $n -lt 5; ++$n) {
        if ($n) {
            Write-Host "Waiting a bit before retrying the upstream uup-dump api ${name} request #$n"
            Start-Sleep -Seconds 10
            Write-Host "Retrying the upstream uup-dump api ${name} request #$n"
        }
        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri "$UUP_JSON_API_FALLBACK_BASE_URL/$name.php" `
                -Body $body
        } catch {
            $errorText = "$_ $($_.Exception.Message) $($_.ErrorDetails.Message)"
            if ($errorText -match 'UNSUPPORTED_LANG|UNSUPPORTED_ID|INVALID_PARAM|MISSING_PARAM') {
                throw
            }
            Write-Host "WARN: failed the upstream uup-dump api $name request: $_"
        }
    }
    throw "timeout making the upstream uup-dump api $name request"
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

    if ($value -is [string]) {
        return @($value)
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

function Resolve-UupDumpPrimaryPackSourceId([string]$updateId, $updateInfo) {
    if ($null -eq $updateInfo) {
        return $updateId
    }

    $build = if ($updateInfo.PSObject.Properties.Name -contains 'build') { $updateInfo.build } else { $null }
    if ([string]::IsNullOrWhiteSpace($build)) {
        return $updateId
    }

    try {
        $listIdResult = Invoke-UupDumpApi listid @{ search = $build }
    } catch {
        return $updateId
    }

    $buildRows = Get-UupDumpBuildRows $listIdResult.response.builds
    if ($buildRows.Count -eq 0) {
        return $updateId
    }

    $arch = if ($updateInfo.PSObject.Properties.Name -contains 'arch') { $updateInfo.arch } else { $null }
    $title = if ($updateInfo.PSObject.Properties.Name -contains 'title') { $updateInfo.title } else { '' }
    $sourceFamily = Get-UupDumpTitleFamily $title
    $sourceIsCU = Test-UupDumpIsCumulativeTitle $title

    $fallbackId = $updateId
    $preferredSibling = $null
    $secondarySibling = $null

    foreach ($row in $buildRows) {
        if ($null -eq $row -or $row.PSObject.Properties.Name -notcontains 'uuid' -or $row.PSObject.Properties.Name -notcontains 'title') {
            continue
        }

        if ($arch -and $row.PSObject.Properties.Name -contains 'arch' -and $row.arch -ne $arch) {
            continue
        }

        if ($row.uuid -eq $updateId) {
            $fallbackId = $row.uuid
            continue
        }

        $candidateFamily = Get-UupDumpTitleFamily $row.title
        $candidateIsCU = Test-UupDumpIsCumulativeTitle $row.title

        if ($sourceFamily -ne 'generic' -and $candidateFamily -ne $sourceFamily) {
            continue
        }

        if ($sourceIsCU -ne $candidateIsCU) {
            continue
        }

        if ($row.title -match 'Cumulative Update') {
            return $row.uuid
        }

        if ($row.title -match '^Update for Windows|^Security Update for|^Update for Microsoft server operating system') {
            $preferredSibling = $row.uuid
            continue
        }

        if ($row.title -match '^Feature update to') {
            $secondarySibling = $row.uuid
        }
    }

    if ($title -match 'version\s+\d{2}H\d|version\s+\d+\.\d+') {
        if ($preferredSibling) {
            return $preferredSibling
        }

        if ($secondarySibling) {
            return $secondarySibling
        }
    }

    return $fallbackId
}

function Test-UupDumpIsCumulativeTitle([string]$title) {
    return $title -match 'Cumulative Update'
}

function Get-UupDumpTitleFamily([string]$title) {
    $t = $title.ToLowerInvariant()

    if ($t.Contains('azure stack hci')) {
        return 'azure_stack_hci'
    }

    if ($t.Contains('windows server') -or $t.Contains('microsoft server operating system')) {
        return 'windows_server'
    }

    if ($t.Contains('windows 11')) {
        return 'windows_11'
    }

    if ($t.Contains('windows 10')) {
        return 'windows_10'
    }

    if ($t.Contains('cloud pc')) {
        return 'cloud_pc'
    }

    if ($t.Contains('.net framework')) {
        return 'dotnet'
    }

    return 'generic'
}

function Test-UupDumpPackageAvailability([string]$webBaseUrl, [string]$id, [string]$edition, [string]$virtualEdition) {
    $query = New-QueryString @{
        id = $id
        pack = 'en-us'
        edition = $edition
    }
    $uri = "$webBaseUrl/get.php?$query"

    $body = if ($virtualEdition) {
        @{
            autodl = 3
            updates = 1
            cleanup = 1
            'virtualEditions[]' = $virtualEdition
        }
    } else {
        @{
            autodl = 2
            updates = 1
            cleanup = 1
        }
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("uup-probe-" + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        Invoke-WebRequest -UseBasicParsing -Method Post -Uri $uri -Body $body -OutFile $tmp | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        if (Test-Path $tmp) {
            Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        }
    }
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
            $response = $null
            if ($result -and $result.PSObject.Properties.Name -contains 'response') {
                $response = $result.response
            }
            $updateInfo = $null
            if ($response) {
                if ($response.PSObject.Properties.Name -contains 'updateInfo') {
                    $updateInfo = $response.updateInfo
                }
            }

            if ($null -eq $updateInfo) {
                Write-Host "Skipping. listlangs returned no updateInfo."
                $updateInfo = [PSCustomObject]@{
                    title = $_.title
                    build = $_.build
                    ring = $null
                    flight = $null
                    arch = $null
                }
            } elseif ($updateInfo.PSObject.Properties.Name -notcontains 'build') {
                Write-Host "Skipping. listlangs updateInfo.build is missing."
                $updateInfo | Add-Member -NotePropertyMembers @{ build = $_.build } -Force
            }

            if ($updateInfo.build -ne $_.build) {
                Write-Host "Skipping. listlangs returned mismatched build=$($updateInfo.build). Expected build=$($_.build)."
            }
            $langFancyNames = $null
            if ($response -and $response.PSObject.Properties.Name -contains 'langFancyNames') {
                $langFancyNames = $response.langFancyNames
            }
            $langs = @(Get-UupDumpKeys $langFancyNames)
            if ($langs.Count -eq 0 -and $response -and $response.PSObject.Properties.Name -contains 'langList') {
                $langs = @($response.langList)
            }

            if ($langs.Count -eq 0) {
                $resolvedId = Resolve-UupDumpPrimaryPackSourceId $id $updateInfo
                if ($resolvedId -ne $id) {
                    Write-Host "Primary listlangs empty for $id. Trying sibling source id $resolvedId."
                    try {
                        $siblingResult = Invoke-UupDumpApi listlangs @{ id = $resolvedId }
                        $siblingResponse = if ($siblingResult -and $siblingResult.PSObject.Properties.Name -contains 'response') { $siblingResult.response } else { $null }
                        if ($siblingResponse -and $siblingResponse.PSObject.Properties.Name -contains 'updateInfo') {
                            $updateInfo = $siblingResponse.updateInfo
                        }
                        $siblingLangFancyNames = if ($siblingResponse -and $siblingResponse.PSObject.Properties.Name -contains 'langFancyNames') { $siblingResponse.langFancyNames } else { $null }
                        $siblingLangs = @(Get-UupDumpKeys $siblingLangFancyNames)
                        if ($siblingLangs.Count -eq 0 -and $siblingResponse -and $siblingResponse.PSObject.Properties.Name -contains 'langList') {
                            $siblingLangs = @($siblingResponse.langList)
                        }

                        if ($siblingLangs.Count -gt 0) {
                            $langs = $siblingLangs
                            $id = $resolvedId
                            $_ | Add-Member -NotePropertyMembers @{ uuid = $resolvedId } -Force
                        }
                    } catch {
                        Write-Host "WARN: primary sibling listlangs failed: $_"
                    }
                }
            }

            $validatedPrimaryCombo = $false
            if ($langs.Count -eq 0) {
                $validatedPrimaryCombo = Test-UupDumpPackageAvailability `
                    -webBaseUrl $UUP_WEB_BASE_URL `
                    -id $id `
                    -edition $target.edition `
                    -virtualEdition $target.virtualEdition
                if ($validatedPrimaryCombo) {
                    Write-Host "Primary metadata is incomplete but package probe succeeded on Railway for $id."
                    $langs = @('en-us')
                }
            }

            if ($langs.Count -eq 0) {
                Write-Host "Primary listlangs returned no languages. Retrying upstream."
                try {
                    $fallbackResult = Invoke-UupDumpApiFallback listlangs @{ id = $id }
                    $fallbackResponse = if ($fallbackResult.PSObject.Properties.Name -contains 'response') { $fallbackResult.response } else { $null }
                    if ($fallbackResponse -and $fallbackResponse.PSObject.Properties.Name -contains 'updateInfo') {
                        $updateInfo = $fallbackResponse.updateInfo
                    }
                    $fallbackLangFancyNames = if ($fallbackResponse -and $fallbackResponse.PSObject.Properties.Name -contains 'langFancyNames') { $fallbackResponse.langFancyNames } else { $null }
                    $langs = @(Get-UupDumpKeys $fallbackLangFancyNames)
                    if ($langs.Count -eq 0 -and $fallbackResponse -and $fallbackResponse.PSObject.Properties.Name -contains 'langList') {
                        $langs = @($fallbackResponse.langList)
                    }
                    if ($langs.Count -gt 0) {
                        $_ | Add-Member -NotePropertyMembers @{
                            sourceWebBaseUrl = $UUP_FALLBACK_WEB_BASE_URL
                            sourceJsonApiBaseUrl = $UUP_JSON_API_FALLBACK_BASE_URL
                        } -Force
                    }
                } catch {
                    Write-Host "WARN: upstream listlangs fallback failed: $_"
                }
            }

            $_ | Add-Member -NotePropertyMembers @{
                langs = $langs
                info = $updateInfo
            } -Force
            $editions = if ($langs -contains 'en-us') {
                if ($validatedPrimaryCombo) {
                    @($target.edition)
                } else {
                    Write-Host "Getting the $name $id editions metadata"
                    $editionKeys = @()
                    try {
                        $result = Invoke-UupDumpApi listeditions @{
                            id = $id
                            lang = 'en-us'
                        }
                        $editionResponse = if ($result -and $result.PSObject.Properties.Name -contains 'response') { $result.response } else { $null }
                        $editionFancyNames = if ($editionResponse -and $editionResponse.PSObject.Properties.Name -contains 'editionFancyNames') { $editionResponse.editionFancyNames } else { $null }
                        $editionKeys = @(Get-UupDumpKeys $editionFancyNames)
                    } catch {
                        Write-Host "WARN: primary listeditions failed: $_"
                    }

                    if ($editionKeys.Count -eq 0) {
                        Write-Host "Primary listeditions returned no editions. Retrying upstream."
                        try {
                            $fallbackResult = Invoke-UupDumpApiFallback listeditions @{
                                id = $id
                                lang = 'en-us'
                            }
                            $fallbackEditionResponse = if ($fallbackResult -and $fallbackResult.PSObject.Properties.Name -contains 'response') { $fallbackResult.response } else { $null }
                            $fallbackEditionFancyNames = if ($fallbackEditionResponse -and $fallbackEditionResponse.PSObject.Properties.Name -contains 'editionFancyNames') { $fallbackEditionResponse.editionFancyNames } else { $null }
                            $editionKeys = @(Get-UupDumpKeys $fallbackEditionFancyNames)
                            if ($editionKeys.Count -gt 0) {
                                $_ | Add-Member -NotePropertyMembers @{
                                    sourceWebBaseUrl = $UUP_FALLBACK_WEB_BASE_URL
                                    sourceJsonApiBaseUrl = $UUP_JSON_API_FALLBACK_BASE_URL
                                } -Force
                            }
                        } catch {
                            Write-Host "WARN: upstream listeditions fallback failed: $_"
                        }
                    }

                    $editionKeys
                }
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
            $webBaseUrl = if ($_.PSObject.Properties.Name -contains 'sourceWebBaseUrl') {
                $_.sourceWebBaseUrl
            } else {
                $UUP_WEB_BASE_URL
            }
            $jsonApiBaseUrl = if ($_.PSObject.Properties.Name -contains 'sourceJsonApiBaseUrl') {
                $_.sourceJsonApiBaseUrl
            } else {
                $UUP_JSON_API_BASE_URL
            }
            [PSCustomObject]@{
                name = $name
                title = $_.title
                build = $_.build
                id = $id
                edition = $target.edition
                virtualEdition = $target.virtualEdition
                apiUrl = "$jsonApiBaseUrl/get.php?" + (New-QueryString @{
                    id = $id
                    lang = 'en-us'
                    edition = $target.edition
                    #noLinks = '1' # do not return the files download urls.
                })
                downloadUrl = "$webBaseUrl/download.php?" + (New-QueryString @{
                    id = $id
                    pack = 'en-us'
                    edition = $target.edition
                })
                # NB you must use the HTTP POST method to invoke this packageUrl
                #    AND in the body you must include:
                #           autodl=2 updates=1 cleanup=1
                #           OR
                #           autodl=3 updates=1 cleanup=1 virtualEditions[]=Enterprise
                downloadPackageUrl = "$webBaseUrl/get.php?" + (New-QueryString @{
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
    $resolved = Resolve-UupDumpTarget $name $build $search $edition $virtualEdition $ring $arch
    $resolvedName = $resolved.name
    $resolvedTarget = $resolved.target
    $iso = Get-UupDumpIso $resolvedName $resolvedTarget

    if ($null -eq $iso) {
        throw "no matching build found for $name (ring/lang/edition filters)"
    }

    # ensure the build is a version number.
    if ($iso.build -notmatch '^\d+\.\d+$') {
        throw "unexpected $resolvedName build: $($iso.build)"
    }

    $buildDirectory = "$destinationDirectory/$resolvedName"
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
    $title = "$resolvedName $edition $($iso.build)"

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
                name = $resolvedName
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
