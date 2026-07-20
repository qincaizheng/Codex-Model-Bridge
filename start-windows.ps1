# start-windows.ps1 - Single-run mitmdump local capture helper for ChatGPT and legacy Codex.

$ErrorActionPreference = "Stop"

if ($args.Count -gt 0) {
    throw "This script accepts no arguments. Use config.json for local settings."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RewriteScript = Join-Path $ScriptDir "rewrite.py"
$ConfigFile = Join-Path $ScriptDir "config.json"
$BundledCatalogTemplate = Join-Path $ScriptDir "models_catalog.template.json"

$script:TargetApp = "ChatGPT"
$script:CodexAppPath = ""
$script:CodexExecutable = ""
$script:CodexAliasExecutable = ""
$script:CodexAlternateAliasExecutable = ""
$script:CodexAumid = ""
$script:CodexPackageName = ""
$script:CodexPackageFamilyName = ""
$script:CodexPackageInstallLocation = ""
$script:CodexLaunchWorkingDirectory = ""
$script:CodexLaunchPrefixArguments = @()
$script:LaunchedProcessId = 0
$script:MitmDumpCmd = ""
$script:CodexCliPath = ""
$script:CodexCliSourcePath = ""
$script:CodexCliTemporaryCopy = ""
$script:CodexCliFingerprint = ""
$script:CodexHomePath = ""
$script:CodexConfigPath = ""
$script:BundledCatalogPath = ""
$script:RuntimeCatalogPath = ""
$script:RuntimeCatalogCachePath = ""
$script:RuntimeCatalogMetaPath = ""
$script:RuntimeGeneration = ""
$script:ConfigInjectionActive = $false
$CodexStorePackageNames = @("OpenAI.CodexBeta", "OpenAI.Codex")
$CodexStoreAumidPattern = "OpenAI.Codex*_*!App"
$script:MitmLocalSpec = "ChatGPT.exe,chatgpt.exe,ChatGPT,chatgpt,Codex.exe,codex.exe,Codex,codex"
$NoProxyList = "*"
$ProxyBypassList = "*"
$CaDir = Join-Path $env:USERPROFILE ".mitmproxy"
$CaCert = Join-Path $CaDir "mitmproxy-ca-cert.cer"
$LogDir = Join-Path $env:LOCALAPPDATA "CodexModelBridge\Logs"
$RuntimeDir = Join-Path $env:LOCALAPPDATA "CodexModelBridge\Runtime"
$ConfigRecoveryMarkerPath = Join-Path $RuntimeDir "catalog-config-recovery.json"
$ConfigRecoveryBackupPath = Join-Path $RuntimeDir "catalog-config-recovery.bak"
$MitmOutLog = Join-Path $LogDir "mitmdump.out.log"
$MitmErrLog = Join-Path $LogDir "mitmdump.err.log"
$CodexOutLog = Join-Path $LogDir "codex.out.log"
$CodexErrLog = Join-Path $LogDir "codex.err.log"

function Info([string]$Message) {
    Write-Host $Message
}

function Die([string]$Message) {
    throw $Message
}

function Initialize-Logs {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Set-Content -LiteralPath $MitmOutLog -Value "" -NoNewline
    Set-Content -LiteralPath $MitmErrLog -Value "" -NoNewline
    Set-Content -LiteralPath $CodexOutLog -Value "" -NoNewline
    Set-Content -LiteralPath $CodexErrLog -Value "" -NoNewline
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        return $null
    }
    return Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
}

$script:Config = Get-Config

function Get-ConfigValue([string]$Name) {
    if ($null -eq $script:Config) {
        return ""
    }
    $property = $script:Config.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ""
    }
    if ($property.Value -is [string]) {
        return $property.Value
    }
    return ""
}

function ConvertFrom-TomlStringValue([string]$RawValue) {
    $raw = $RawValue.Trim()
    if ($raw -match '^"(?<Value>(?:[^"\\]|\\.)*)"\s*(?:#.*)?$') {
        try {
            return ConvertFrom-Json ('"' + $Matches["Value"] + '"')
        }
        catch {
            return ""
        }
    }
    if ($raw -match "^'(?<Value>[^']*)'\s*(?:#.*)?$") {
        return $Matches["Value"]
    }
    return ($raw -split "\s+#", 2)[0].Trim()
}

function Get-TomlRootStringValue([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    $escapedName = [regex]::Escape($Name)
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or
            $trimmed.StartsWith("#")) {
            continue
        }
        if ($trimmed.StartsWith("[")) {
            break
        }
        if ($trimmed -notmatch "^$escapedName\s*=\s*(?<Value>.*)$") {
            continue
        }

        return ConvertFrom-TomlStringValue $Matches["Value"]
    }
    return ""
}

function Get-TomlLegacyProfileHeaderPattern([string]$Profile) {
    $profilesToken = '(?:profiles|"profiles"|''profiles'')'
    $profileTokens = @()
    if ($Profile -match '^[A-Za-z0-9_-]+$') {
        $profileTokens += [regex]::Escape($Profile)
    }

    $basic = $Profile | ConvertTo-Json -Compress
    $profileTokens += [regex]::Escape($basic)
    if (-not $Profile.Contains("'")) {
        $profileTokens += [regex]::Escape("'" + $Profile + "'")
    }

    $profileToken = '(?:' + (($profileTokens | Select-Object -Unique) -join '|') + ')'
    return '^\s*\[\s*' + $profilesToken + '\s*\.\s*' +
        $profileToken + '\s*\]\s*(?:#.*)?$'
}

function Get-TomlLegacyProfileStringValue(
    [string]$Path,
    [string]$Profile,
    [string]$Name
) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        [string]::IsNullOrWhiteSpace($Profile) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    $headerPattern = Get-TomlLegacyProfileHeaderPattern $Profile
    $escapedName = [regex]::Escape($Name)
    $insideProfile = $false
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("[")) {
            $insideProfile = $trimmed -match $headerPattern
            continue
        }
        if (-not $insideProfile -or
            [string]::IsNullOrWhiteSpace($trimmed) -or
            $trimmed.StartsWith("#") -or
            $trimmed -notmatch "^$escapedName\s*=\s*(?<Value>.*)$") {
            continue
        }
        return ConvertFrom-TomlStringValue $Matches["Value"]
    }
    return ""
}

function Resolve-CodexHomePath {
    $codexHome = [Environment]::GetEnvironmentVariable("CODEX_HOME", "Process")
    if ([string]::IsNullOrWhiteSpace($codexHome)) {
        $codexHome = Join-Path $env:USERPROFILE ".codex"
    }

    $codexHome = [Environment]::ExpandEnvironmentVariables($codexHome)
    if ($codexHome -eq "~") {
        $codexHome = $env:USERPROFILE
    }
    elseif ($codexHome.StartsWith("~\") -or $codexHome.StartsWith("~/")) {
        $codexHome = Join-Path $env:USERPROFILE $codexHome.Substring(2)
    }
    elseif (-not [IO.Path]::IsPathRooted($codexHome)) {
        $codexHome = Join-Path (Get-Location).Path $codexHome
    }
    return [IO.Path]::GetFullPath($codexHome)
}

function Initialize-CodexConfigPaths {
    if ([string]::IsNullOrWhiteSpace($script:CodexHomePath)) {
        $script:CodexHomePath = Resolve-CodexHomePath
        $script:CodexConfigPath = Join-Path $script:CodexHomePath "config.toml"
    }
}

function Expand-LocalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq "~") {
        return $env:USERPROFILE
    }
    if ($expanded.StartsWith("~\")) {
        return Join-Path $env:USERPROFILE $expanded.Substring(2)
    }
    if ($expanded.StartsWith("~/")) {
        return Join-Path $env:USERPROFILE $expanded.Substring(2)
    }
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        return Join-Path $ScriptDir $expanded
    }
    return $expanded
}

function Normalize-LocalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    return $Path.Replace('/', '\').TrimEnd('\')
}

function Get-FileSha256([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-Utf8Text([string]$Path, [string]$Label) {
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    try {
        return [IO.File]::ReadAllText($Path, $encoding)
    }
    catch [Text.DecoderFallbackException] {
        Die "$Label must be UTF-8 before Codex Model Bridge can update it"
    }
}

function New-TemporarySiblingPath([string]$Path) {
    $directory = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($directory)) {
        Die "cannot create a temporary file without a parent directory: $Path"
    }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $name = Split-Path -Leaf $Path
    return Join-Path $directory (
        ".{0}.codex-model-bridge-{1}-{2}.tmp" -f
            $name,
            $PID,
            ([Guid]::NewGuid().ToString("N"))
    )
}

function Move-StagedFileIntoPlace([string]$StagedPath, [string]$Path) {
    $replaceBackup = "$StagedPath.replace-backup"
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($StagedPath, $Path, $replaceBackup, $true)
            Remove-Item -LiteralPath $replaceBackup -Force `
                -ErrorAction SilentlyContinue
        }
        else {
            [IO.File]::Move($StagedPath, $Path)
        }
    }
    catch {
        Remove-Item -LiteralPath $StagedPath, $replaceBackup -Force `
            -ErrorAction SilentlyContinue
        throw
    }
}

function Copy-FileAtomically([string]$Source, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        Die "source file not found: $Source"
    }
    $temporary = New-TemporarySiblingPath $Path
    try {
        try {
            Copy-Item -LiteralPath $Source -Destination $temporary -Force
        }
        catch {
            Remove-Item -LiteralPath $temporary -Force `
                -ErrorAction SilentlyContinue
            [IO.File]::Copy($Source, $temporary, $true)
        }
        Move-StagedFileIntoPlace $temporary $Path
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
        throw
    }
}

function Write-Utf8TextAtomically([string]$Path, [string]$Text) {
    $temporary = New-TemporarySiblingPath $Path
    $encoding = New-Object Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temporary, $Text, $encoding)
        Move-StagedFileIntoPlace $temporary $Path
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force `
            -ErrorAction SilentlyContinue
        throw
    }
}

function Get-TextNewLine([string]$Text) {
    if ($Text.Contains("`r`n")) {
        return "`r`n"
    }
    if ($Text.Contains("`n")) {
        return "`n"
    }
    if ($Text.Contains("`r")) {
        return "`r"
    }
    return "`r`n"
}

function Insert-TomlAssignmentAt(
    [string]$Text,
    [int]$Index,
    [string]$Assignment,
    [string]$NewLine
) {
    $prefix = ""
    if ($Index -gt 0) {
        $previous = $Text[$Index - 1]
        if ($previous -ne "`r" -and $previous -ne "`n") {
            $prefix = $NewLine
        }
    }
    return $Text.Substring(0, $Index) + $prefix + $Assignment + $NewLine +
        $Text.Substring($Index)
}

function Replace-TomlRootAssignment(
    [string]$Text,
    [string]$Name,
    [string]$Assignment,
    [string]$NewLine
) {
    $firstTable = [regex]::Match($Text, '(?m)^[ \t]*\[')
    $rootEnd = if ($firstTable.Success) { $firstTable.Index } else { $Text.Length }
    $root = $Text.Substring(0, $rootEnd)
    $escapedName = [regex]::Escape($Name)
    $keyMatch = [regex]::Match(
        $root,
        "(?m)^(?<Indent>[ \t]*)$escapedName[ \t]*=.*$"
    )
    if ($keyMatch.Success) {
        $replacement = $keyMatch.Groups["Indent"].Value + $Assignment
        $root = $root.Substring(0, $keyMatch.Index) +
            $replacement +
            $root.Substring($keyMatch.Index + $keyMatch.Length)
        return $root + $Text.Substring($rootEnd)
    }

    return Insert-TomlAssignmentAt $Text $rootEnd $Assignment $NewLine
}

function Replace-TomlLegacyProfileAssignment(
    [string]$Text,
    [string]$Profile,
    [string]$Name,
    [string]$Assignment,
    [string]$NewLine
) {
    $headerPattern = Get-TomlLegacyProfileHeaderPattern $Profile
    $header = [regex]::Match($Text, "(?m)$headerPattern")
    if (-not $header.Success) {
        return [pscustomobject]@{
            Text = $Text
            Found = $false
        }
    }

    $sectionStart = $header.Index + $header.Length
    $tablePattern = [regex]'(?m)^[ \t]*\['
    $nextTable = $tablePattern.Match($Text, $sectionStart)
    $sectionEnd = if ($nextTable.Success) { $nextTable.Index } else { $Text.Length }
    $section = $Text.Substring($sectionStart, $sectionEnd - $sectionStart)
    $escapedName = [regex]::Escape($Name)
    $keyMatch = [regex]::Match(
        $section,
        "(?m)^(?<Indent>[ \t]*)$escapedName[ \t]*=.*$"
    )
    if ($keyMatch.Success) {
        $replacement = $keyMatch.Groups["Indent"].Value + $Assignment
        $section = $section.Substring(0, $keyMatch.Index) +
            $replacement +
            $section.Substring($keyMatch.Index + $keyMatch.Length)
        return [pscustomobject]@{
            Text = $Text.Substring(0, $sectionStart) +
                $section +
                $Text.Substring($sectionEnd)
            Found = $true
        }
    }

    return [pscustomobject]@{
        Text = Insert-TomlAssignmentAt `
            $Text `
            $sectionEnd `
            $Assignment `
            $NewLine
        Found = $true
    }
}

function New-CodexCatalogConfigText(
    [string]$OriginalText,
    [string]$CatalogPath,
    [string]$LegacyProfile
) {
    $newLine = Get-TextNewLine $OriginalText
    $tomlPath = $CatalogPath | ConvertTo-Json -Compress
    $assignment = (
        "model_catalog_json = {0} # temporary Codex Model Bridge startup override" -f
            $tomlPath
    )
    $modified = Replace-TomlRootAssignment `
        $OriginalText `
        "model_catalog_json" `
        $assignment `
        $newLine

    if (-not [string]::IsNullOrWhiteSpace($LegacyProfile)) {
        $profileResult = Replace-TomlLegacyProfileAssignment `
            $modified `
            $LegacyProfile `
            "model_catalog_json" `
            $assignment `
            $newLine
        if ($profileResult.Found) {
            $modified = $profileResult.Text
        }
    }
    return $modified
}

function Remove-TemporaryRuntimeCatalog([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $parent = [IO.Path]::GetFullPath((Split-Path -Parent $fullPath))
        $leaf = Split-Path -Leaf $fullPath
        if ($parent -ieq [IO.Path]::GetFullPath($script:ScriptDir) -and
            $leaf -like ".codex-model-bridge-runtime-*.json") {
            Remove-Item -LiteralPath $fullPath -Force `
                -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function Clear-CodexConfigRecoveryArtifacts(
    [object]$Marker,
    [bool]$PreserveRuntimeCatalog = $false
) {
    Remove-Item -LiteralPath $ConfigRecoveryMarkerPath -Force `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ConfigRecoveryBackupPath -Force `
        -ErrorAction SilentlyContinue
    if ($null -ne $Marker -and -not $PreserveRuntimeCatalog) {
        Remove-TemporaryRuntimeCatalog ([string]$Marker.runtime_catalog_path)
        $metaPath = [string]$Marker.runtime_meta_path
        if (-not [string]::IsNullOrWhiteSpace($metaPath)) {
            Remove-Item -LiteralPath $metaPath -ErrorAction SilentlyContinue
        }
    }
}

function Read-CodexConfigRecoveryMarker {
    if (-not (Test-Path -LiteralPath $ConfigRecoveryMarkerPath -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $ConfigRecoveryMarkerPath -Raw |
            ConvertFrom-Json
    }
    catch {
        Die "cannot read Codex config recovery marker at $ConfigRecoveryMarkerPath"
    }
}

function Restore-CodexConfigFromMarker(
    [bool]$FailOnConflict,
    [bool]$PreserveRuntimeCatalog = $false
) {
    $marker = Read-CodexConfigRecoveryMarker
    if ($null -eq $marker) {
        $script:ConfigInjectionActive = $false
        return $true
    }

    $configPath = [string]$marker.config_path
    $originalExisted = [bool]$marker.original_existed
    $originalHash = [string]$marker.original_sha256
    $injectedHash = [string]$marker.injected_sha256
    if ([string]::IsNullOrWhiteSpace($configPath) -or
        [string]::IsNullOrWhiteSpace($injectedHash)) {
        Die "Codex config recovery marker is incomplete: $ConfigRecoveryMarkerPath"
    }

    $currentExists = Test-Path -LiteralPath $configPath -PathType Leaf
    $currentHash = if ($currentExists) {
        Get-FileSha256 $configPath
    }
    else {
        ""
    }

    $alreadyOriginal = (
        ($originalExisted -and $currentHash -eq $originalHash) -or
        (-not $originalExisted -and -not $currentExists)
    )
    if ($alreadyOriginal) {
        Clear-CodexConfigRecoveryArtifacts $marker $PreserveRuntimeCatalog
        $script:ConfigInjectionActive = $false
        return $true
    }

    if ($currentHash -ne $injectedHash) {
        $message = (
            "Codex config changed after the temporary catalog was injected. " +
            "The bridge will not overwrite it. The original backup remains at " +
            "$ConfigRecoveryBackupPath and the temporary catalog remains at " +
            "$([string]$marker.runtime_catalog_path)."
        )
        $script:ConfigInjectionActive = $false
        if ($FailOnConflict) {
            Die $message
        }
        Info "Warning: $message"
        return $false
    }

    if ($originalExisted) {
        if (-not (Test-Path -LiteralPath $ConfigRecoveryBackupPath -PathType Leaf) -or
            (Get-FileSha256 $ConfigRecoveryBackupPath) -ne $originalHash) {
            Die "Codex config recovery backup is missing or damaged: $ConfigRecoveryBackupPath"
        }
        Copy-FileAtomically $ConfigRecoveryBackupPath $configPath
        if ((Get-FileSha256 $configPath) -ne $originalHash) {
            Die "restored Codex config verification failed: $configPath"
        }
        try {
            if ($null -ne $marker.original_attributes) {
                [IO.File]::SetAttributes(
                    $configPath,
                    [IO.FileAttributes][int]$marker.original_attributes
                )
            }
            if ($null -ne $marker.original_last_write_filetime_utc) {
                [IO.File]::SetLastWriteTimeUtc(
                    $configPath,
                    [DateTime]::FromFileTimeUtc(
                        [int64]$marker.original_last_write_filetime_utc
                    )
                )
            }
        }
        catch {
            Info "Warning: restored config but could not restore file metadata"
        }
    }
    else {
        Remove-Item -LiteralPath $configPath -ErrorAction Stop
    }

    Clear-CodexConfigRecoveryArtifacts $marker $PreserveRuntimeCatalog
    $script:ConfigInjectionActive = $false
    Info "      Codex config restored"
    return $true
}

function Remove-ActiveRuntimeCatalogIfSafe {
    if (Test-Path -LiteralPath $ConfigRecoveryMarkerPath -PathType Leaf) {
        return
    }
    Remove-TemporaryRuntimeCatalog $script:RuntimeCatalogPath
    if (-not [string]::IsNullOrWhiteSpace($script:RuntimeCatalogMetaPath)) {
        Remove-Item -LiteralPath $script:RuntimeCatalogMetaPath -Force `
            -ErrorAction SilentlyContinue
    }
}

function Recover-StaleCodexConfigInjection {
    if (Test-Path -LiteralPath $ConfigRecoveryMarkerPath -PathType Leaf) {
        Info "      recovering a previous temporary Codex config override"
        Restore-CodexConfigFromMarker $true | Out-Null
    }
    Get-ChildItem -LiteralPath $RuntimeDir `
        -Filter "catalog-config-injected-*.tmp" `
        -File `
        -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force `
                -ErrorAction SilentlyContinue
        }
}

function Remove-StaleProjectRuntimeCatalogs {
    Get-ChildItem -LiteralPath $ScriptDir `
        -Filter ".codex-model-bridge-runtime-*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force `
                -ErrorAction SilentlyContinue
        }
}

function Enable-CodexRuntimeCatalogConfig {
    Initialize-CodexConfigPaths
    if (Test-Path -LiteralPath $ConfigRecoveryMarkerPath -PathType Leaf) {
        Die "a Codex config recovery is still pending: $ConfigRecoveryMarkerPath"
    }

    $configExists = Test-Path -LiteralPath $script:CodexConfigPath -PathType Leaf
    if ($configExists) {
        $originalText = Read-Utf8Text `
            $script:CodexConfigPath `
            $script:CodexConfigPath
        $legacyProfile = Get-TomlRootStringValue `
            $script:CodexConfigPath `
            "profile"
        $configItem = Get-Item -LiteralPath $script:CodexConfigPath
        $originalAttributes = [int]$configItem.Attributes
        $originalLastWrite = $configItem.LastWriteTimeUtc.ToFileTimeUtc()
        $originalHash = Get-FileSha256 $script:CodexConfigPath
    }
    else {
        $originalText = ""
        $legacyProfile = ""
        $originalAttributes = $null
        $originalLastWrite = $null
        $originalHash = ""
    }

    $modifiedText = New-CodexCatalogConfigText `
        $originalText `
        $script:RuntimeCatalogPath `
        $legacyProfile

    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    $stagedConfigPath = Join-Path $RuntimeDir (
        "catalog-config-injected-{0}.tmp" -f $script:RuntimeGeneration
    )
    $markerWritten = $false
    try {
        Write-Utf8TextAtomically $stagedConfigPath $modifiedText
        $injectedHash = Get-FileSha256 $stagedConfigPath

        if ($configExists) {
            Copy-FileAtomically `
                $script:CodexConfigPath `
                $ConfigRecoveryBackupPath
            if ((Get-FileSha256 $ConfigRecoveryBackupPath) -ne $originalHash) {
                Die "Codex config backup verification failed"
            }
        }
        else {
            Remove-Item -LiteralPath $ConfigRecoveryBackupPath -Force `
                -ErrorAction SilentlyContinue
        }

        $marker = [ordered]@{
            version = 1
            config_path = $script:CodexConfigPath
            original_existed = $configExists
            original_sha256 = $originalHash
            injected_sha256 = $injectedHash
            original_attributes = $originalAttributes
            original_last_write_filetime_utc = $originalLastWrite
            runtime_catalog_path = $script:RuntimeCatalogPath
            runtime_meta_path = $script:RuntimeCatalogMetaPath
            created_at_utc = [DateTime]::UtcNow.ToString("o")
        }
        Write-Utf8TextAtomically `
            $ConfigRecoveryMarkerPath `
            ($marker | ConvertTo-Json -Depth 4)
        $markerWritten = $true

        Copy-FileAtomically $stagedConfigPath $script:CodexConfigPath
        if ((Get-FileSha256 $script:CodexConfigPath) -ne $injectedHash) {
            Die "temporary Codex config verification failed"
        }
    }
    catch {
        if ($markerWritten) {
            Restore-CodexConfigFromMarker $false | Out-Null
        }
        else {
            Remove-Item -LiteralPath $ConfigRecoveryBackupPath -Force `
                -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $stagedConfigPath -Force `
            -ErrorAction SilentlyContinue
    }

    $script:ConfigInjectionActive = $true
    Info "      temporary config: $script:CodexConfigPath"
}

function Test-ExecutableFile([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )
        try {
            if ($stream.Length -lt 2) {
                return $false
            }
            return $stream.ReadByte() -eq 0x4D -and $stream.ReadByte() -eq 0x5A
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Update-MitmLocalSpec {
    $resolvedName = Split-Path -Leaf $script:CodexExecutable
    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        return
    }

    $names = @(
        $resolvedName,
        $resolvedName.ToLowerInvariant(),
        "ChatGPT.exe",
        "chatgpt.exe",
        "ChatGPT",
        "chatgpt",
        "Codex.exe",
        "codex.exe",
        "Codex",
        "codex"
    )
    $uniqueNames = @()
    foreach ($name in $names) {
        if ($uniqueNames -cnotcontains $name) {
            $uniqueNames += $name
        }
    }
    $script:MitmLocalSpec = $uniqueNames -join ","
}

function Get-OpenAICodexPackage {
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        return $null
    }

    $packages = @()
    foreach ($packageName in $CodexStorePackageNames) {
        $packages += @(
            Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue |
                Where-Object { $_.InstallLocation -and -not $_.IsFramework }
        )
    }
    return $packages |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Get-CodexPackageApplication([object]$Package, [string]$ExecutablePath) {
    if (-not $Package -or [string]::IsNullOrWhiteSpace($Package.PackageFullName) -or
        -not (Get-Command Get-AppxPackageManifest -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $manifest = Get-AppxPackageManifest -Package ([string]$Package.PackageFullName) -ErrorAction Stop
    }
    catch {
        return $null
    }

    $applications = @($manifest.Package.Applications.Application)
    if ($applications.Count -eq 0) {
        return $null
    }

    $normalizedExecutable = Normalize-LocalPath $ExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($normalizedExecutable)) {
        foreach ($application in $applications) {
            $executable = [string]$application.Executable
            if ([string]::IsNullOrWhiteSpace($executable)) {
                continue
            }
            $candidate = Normalize-LocalPath (Join-Path $Package.InstallLocation $executable)
            if ($candidate -ieq $normalizedExecutable) {
                return $application
            }
        }
    }

    $protocolApplication = $applications |
        Where-Object {
            @($_.Extensions.Extension) |
                Where-Object {
                    $_.Category -eq "windows.protocol" -and $_.Protocol.Name -eq "codex"
                } |
                Select-Object -First 1
        } |
        Select-Object -First 1
    if ($protocolApplication) {
        return $protocolApplication
    }

    $defaultApplication = $applications |
        Where-Object { $_.Id -eq "App" } |
        Select-Object -First 1
    if ($defaultApplication) {
        return $defaultApplication
    }

    $namedApplication = $applications |
        Where-Object {
            [IO.Path]::GetFileName([string]$_.Executable) -match "^(?i:ChatGPT|Codex)\.exe$"
        } |
        Select-Object -First 1
    if ($namedApplication) {
        return $namedApplication
    }

    return $applications | Select-Object -First 1
}

function Get-CodexAliasExecutables([string]$ExecutablePath) {
    $resolvedName = Split-Path -Leaf $ExecutablePath
    $aliasNames = if ($resolvedName -ieq "Codex.exe") {
        @("Codex.exe", "ChatGPT.exe")
    }
    else {
        @("ChatGPT.exe", "Codex.exe")
    }

    $candidates = @()
    foreach ($aliasName in $aliasNames) {
        $alias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$aliasName"
        if (Test-Path -LiteralPath $alias -PathType Leaf) {
            $candidates += (Resolve-Path -LiteralPath $alias).Path
        }

        $command = Get-Command $aliasName -ErrorAction SilentlyContinue
        if ($command -and $command.Source -and $command.Source -like "*\Microsoft\WindowsApps\*") {
            $candidates += $command.Source
        }
    }

    return @($candidates | Where-Object { $_ } | Select-Object -Unique)
}

function Get-AumidFromPackage([object]$Package, [string]$ExecutablePath) {
    if (-not $Package -or [string]::IsNullOrWhiteSpace($Package.PackageFamilyName)) {
        return ""
    }

    $application = Get-CodexPackageApplication $Package $ExecutablePath
    if (-not $application) {
        return ""
    }

    $id = [string]$application.Id
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        return "$($Package.PackageFamilyName)!$id"
    }

    return ""
}

function Get-AumidFromPackagePath([string]$ExecutablePath) {
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) -or
        -not (Get-Command Get-AppxPackageManifest -ErrorAction SilentlyContinue)) {
        return ""
    }

    $normalizedExecutable = Normalize-LocalPath $ExecutablePath
    if ([string]::IsNullOrWhiteSpace($normalizedExecutable)) {
        return ""
    }

    $packages = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.InstallLocation }
    foreach ($package in $packages) {
        $root = Normalize-LocalPath $package.InstallLocation
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        if ($normalizedExecutable.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $normalizedExecutable.StartsWith($root + "\", [StringComparison]::OrdinalIgnoreCase)) {
            $script:CodexPackageName = [string]$package.Name
            $script:CodexPackageFamilyName = [string]$package.PackageFamilyName
            $script:CodexPackageInstallLocation = $root
            return Get-AumidFromPackage $package $normalizedExecutable
        }
    }

    return ""
}

function Set-CodexPackageInstallLocationFromAumid([string]$ExecutablePath, [string]$Aumid) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or
        -not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        return
    }

    $normalizedExecutable = Normalize-LocalPath $ExecutablePath
    $aliasRoot = Normalize-LocalPath (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps")
    if ([string]::IsNullOrWhiteSpace($normalizedExecutable) -or
        [IO.Path]::GetDirectoryName($normalizedExecutable) -ine $aliasRoot) {
        return
    }

    if ($Aumid -notmatch '^(?<PackageFamilyName>[^!\\/: \t\r\n]+)![^!\\/: \t\r\n]+$') {
        return
    }
    $packageFamilyName = $Matches["PackageFamilyName"]

    $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
        $_.InstallLocation -and $_.PackageFamilyName -ieq $packageFamilyName
    })
    if ($packages.Count -ne 1) {
        return
    }

    $root = Normalize-LocalPath $packages[0].InstallLocation
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $script:CodexPackageName = [string]$packages[0].Name
        $script:CodexPackageFamilyName = [string]$packages[0].PackageFamilyName
        $script:CodexPackageInstallLocation = $root
    }
}

function Get-CodexAumidFromStartApps([string]$ExecutablePath) {
    if (-not (Get-Command Get-StartApps -ErrorAction SilentlyContinue)) {
        return ""
    }

    $resolvedName = [IO.Path]::GetFileNameWithoutExtension($ExecutablePath)
    $targetNames = if ($resolvedName -ieq "Codex") {
        @("Codex", "ChatGPT")
    }
    else {
        @("ChatGPT", "Codex")
    }

    $apps = @(Get-StartApps -ErrorAction SilentlyContinue)
    $official = $apps |
        Where-Object { $_.AppID -like $CodexStoreAumidPattern } |
        Select-Object -First 1
    if ($official -and $official.AppID) {
        return $official.AppID
    }

    foreach ($targetName in $targetNames) {
        $exact = $apps | Where-Object {
            $_.Name -ieq $targetName -or $_.AppID -match "(?i)(^|[._!])$([regex]::Escape($targetName))([._!]|$)"
        } | Select-Object -First 1
        if ($exact -and $exact.AppID) {
            return $exact.AppID
        }
    }

    $fuzzy = $apps | Where-Object {
        $_.Name -match "(?i)(chatgpt|codex)" -or $_.AppID -match "(?i)(chatgpt|codex)"
    } | Select-Object -First 1
    if ($fuzzy -and $fuzzy.AppID) {
        return $fuzzy.AppID
    }

    return ""
}

function Get-CodexAumidFromAppsFolder([string]$ExecutablePath) {
    try {
        $apps = (New-Object -ComObject Shell.Application).NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}').Items()
    }
    catch {
        return ""
    }

    $resolvedName = [IO.Path]::GetFileNameWithoutExtension($ExecutablePath)
    $targetNames = if ($resolvedName -ieq "Codex") {
        @("Codex", "ChatGPT")
    }
    else {
        @("ChatGPT", "Codex")
    }

    $official = $apps |
        Where-Object { $_.Path -like $CodexStoreAumidPattern } |
        Select-Object -First 1
    if ($official -and $official.Path) {
        return $official.Path
    }

    foreach ($targetName in $targetNames) {
        $exact = $apps | Where-Object {
            $_.Name -ieq $targetName -or $_.Path -match "(?i)(^|[._!])$([regex]::Escape($targetName))([._!]|$)"
        } | Select-Object -First 1
        if ($exact -and $exact.Path) {
            return $exact.Path
        }
    }

    $fuzzy = $apps | Where-Object {
        $_.Name -match "(?i)(chatgpt|codex)" -or $_.Path -match "(?i)(chatgpt|codex)"
    } | Select-Object -First 1
    if ($fuzzy -and $fuzzy.Path) {
        return $fuzzy.Path
    }

    return ""
}

function Resolve-CodexAumid([string]$ExecutablePath) {
    $aumid = Get-AumidFromPackagePath $ExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($aumid)) {
        return $aumid
    }

    $aumid = Get-CodexAumidFromStartApps $ExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($aumid)) {
        Set-CodexPackageInstallLocationFromAumid $ExecutablePath $aumid
        return $aumid
    }

    $aumid = Get-CodexAumidFromAppsFolder $ExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($aumid)) {
        Set-CodexPackageInstallLocationFromAumid $ExecutablePath $aumid
    }
    return $aumid
}

function Set-CodexLaunchMetadata {
    $script:CodexLaunchWorkingDirectory = ""
    $script:CodexLaunchPrefixArguments = @()

    if (-not (Test-WindowsAppsPath $script:CodexExecutable)) {
        return
    }

    $appDir = Split-Path -Parent $script:CodexExecutable
    $appBundle = Join-Path $appDir "resources\app.asar"
    if (Test-Path -LiteralPath $appBundle -PathType Leaf) {
        $script:CodexLaunchWorkingDirectory = $appDir
        $script:CodexLaunchPrefixArguments = @("resources\app.asar")
    }
}

function Resolve-CodexDesktopExecutablePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $parent = Split-Path -Parent $resolved
    if ([IO.Path]::GetFileName($resolved) -ieq "codex.exe" -and
        [IO.Path]::GetFileName($parent) -ieq "resources") {
        $appDir = Split-Path -Parent $parent
        foreach ($desktopName in @("Codex.exe", "ChatGPT.exe")) {
            $desktop = Join-Path $appDir $desktopName
            if (Test-Path -LiteralPath $desktop -PathType Leaf) {
                return (Resolve-Path -LiteralPath $desktop).Path
            }
        }
    }

    return $resolved
}

function Set-CodexExecutable([string]$Path) {
    $script:CodexExecutable = Resolve-CodexDesktopExecutablePath $Path
    $script:CodexAppPath = $script:CodexExecutable
    $script:TargetApp = Split-Path -Leaf $script:CodexExecutable
    $resolvedName = Split-Path -Leaf $script:CodexExecutable
    $alternateName = if ($resolvedName -ieq "Codex.exe") { "ChatGPT.exe" } else { "Codex.exe" }
    $aliases = @(Get-CodexAliasExecutables $script:CodexExecutable)
    $script:CodexAliasExecutable = $aliases |
        Where-Object { (Split-Path -Leaf $_) -ieq $resolvedName } |
        Select-Object -First 1
    $script:CodexAlternateAliasExecutable = $aliases |
        Where-Object { (Split-Path -Leaf $_) -ieq $alternateName } |
        Select-Object -First 1
    $script:CodexPackageName = ""
    $script:CodexPackageFamilyName = ""
    $script:CodexPackageInstallLocation = ""
    $script:CodexAumid = Resolve-CodexAumid $script:CodexExecutable
    Set-CodexLaunchMetadata
    Update-MitmLocalSpec
}

function Set-OpenAICodexPackage([object]$Package) {
    $application = Get-CodexPackageApplication $Package ""
    if (-not $application -or [string]::IsNullOrWhiteSpace([string]$application.Executable)) {
        return $false
    }

    $manifestExecutable = Join-Path `
        $Package.InstallLocation `
        ([string]$application.Executable)
    $script:CodexExecutable = Resolve-CodexDesktopExecutablePath `
        $manifestExecutable
    if ([string]::IsNullOrWhiteSpace($script:CodexExecutable)) {
        return $false
    }
    $script:CodexAppPath = $script:CodexExecutable
    $script:TargetApp = Split-Path -Leaf $script:CodexExecutable
    $resolvedName = Split-Path -Leaf $script:CodexExecutable
    $alternateName = if ($resolvedName -ieq "Codex.exe") { "ChatGPT.exe" } else { "Codex.exe" }
    $aliases = @(Get-CodexAliasExecutables $script:CodexExecutable)
    $script:CodexAliasExecutable = $aliases |
        Where-Object { (Split-Path -Leaf $_) -ieq $resolvedName } |
        Select-Object -First 1
    $script:CodexAlternateAliasExecutable = $aliases |
        Where-Object { (Split-Path -Leaf $_) -ieq $alternateName } |
        Select-Object -First 1
    $script:CodexPackageName = [string]$Package.Name
    $script:CodexPackageFamilyName = [string]$Package.PackageFamilyName
    $script:CodexPackageInstallLocation = Normalize-LocalPath ([string]$Package.InstallLocation)
    $applicationId = [string]$application.Id
    if (-not [string]::IsNullOrWhiteSpace($Package.PackageFamilyName) -and
        -not [string]::IsNullOrWhiteSpace($applicationId)) {
        $script:CodexAumid = "$($Package.PackageFamilyName)!$applicationId"
    }
    else {
        $script:CodexAumid = Get-AumidFromPackage $Package $script:CodexExecutable
    }
    Set-CodexLaunchMetadata
    Update-MitmLocalSpec
    return $true
}

function Find-CodexExeUnder([string]$Root, [int]$Depth) {
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    foreach ($relative in @(
        "app\Codex.exe",
        "app\ChatGPT.exe",
        "Codex.exe",
        "ChatGPT.exe"
    )) {
        $knownDesktop = Join-Path $Root $relative
        if (Test-Path -LiteralPath $knownDesktop -PathType Leaf) {
            return (Resolve-Path -LiteralPath $knownDesktop).Path
        }
    }

    $matches = @()
    foreach ($executableName in @("Codex.exe", "ChatGPT.exe")) {
        $matches += @(
            Get-ChildItem -LiteralPath $Root `
                -Filter $executableName `
                -File `
                -Recurse `
                -Depth $Depth `
                -ErrorAction SilentlyContinue
        )
    }

    $match = $matches |
        Sort-Object `
            @{ Expression = {
                $normalized = Normalize-LocalPath $_.FullName
                if ($normalized -match '(?i)\\(?:resources|app\.asar\.unpacked)\\') {
                    1
                }
                else {
                    0
                }
            } }, `
            @{ Expression = { $_.FullName.Length } } |
        Select-Object -First 1
    if ($match) {
        return $match.FullName
    }

    return $null
}

function Get-StoreCodexCandidates {
    $candidates = @()

    $officialPackage = Get-OpenAICodexPackage
    if ($officialPackage) {
        $officialApplication = Get-CodexPackageApplication $officialPackage ""
        if ($officialApplication -and
            -not [string]::IsNullOrWhiteSpace([string]$officialApplication.Executable)) {
            $manifestExecutable = Join-Path `
                $officialPackage.InstallLocation `
                ([string]$officialApplication.Executable)
            $desktopExecutable = Resolve-CodexDesktopExecutablePath `
                $manifestExecutable
            if (-not [string]::IsNullOrWhiteSpace($desktopExecutable)) {
                $candidates += $desktopExecutable
            }
        }
    }

    foreach ($executableName in @("Codex.exe", "ChatGPT.exe")) {
        $alias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$executableName"
        if (Test-Path -LiteralPath $alias -PathType Leaf) {
            $candidates += (Resolve-Path -LiteralPath $alias).Path
        }

        $command = Get-Command $executableName -ErrorAction SilentlyContinue
        if ($command -and $command.Source -and $command.Source -like "*\Microsoft\WindowsApps\*") {
            $candidates += $command.Source
        }
    }

    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        foreach ($packageName in @("*Codex*", "*ChatGPT*")) {
            $packages = Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue |
                Where-Object { $_.InstallLocation }
            foreach ($package in $packages) {
                $exe = Find-CodexExeUnder $package.InstallLocation 4
                if ($exe) {
                    $candidates += $exe
                }
            }
        }
    }

    $windowsApps = Join-Path $env:ProgramFiles "WindowsApps"
    if (Test-Path -LiteralPath $windowsApps) {
        foreach ($directoryName in @(
            "OpenAI.CodexBeta_*",
            "OpenAI.Codex_*",
            "*Codex*",
            "*ChatGPT*"
        )) {
            $dirs = Get-ChildItem -LiteralPath $windowsApps -Directory -Filter $directoryName -ErrorAction SilentlyContinue
            foreach ($dir in $dirs) {
                $exe = Find-CodexExeUnder $dir.FullName 4
                if ($exe) {
                    $candidates += $exe
                }
            }
        }
    }

    $result = $candidates | Where-Object { $_ } | Select-Object -Unique
    return $result
}

function Test-WindowsAppsPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    $normalized = $Path.Replace('/', '\')
    return (
        $normalized -like "*\Microsoft\WindowsApps\*" -or
        $normalized -like "*\Program Files\WindowsApps\*"
    )
}

function Remove-TemporaryCodexCliCopy {
    if ([string]::IsNullOrWhiteSpace($script:CodexCliTemporaryCopy)) {
        return
    }
    $copyPath = $script:CodexCliTemporaryCopy
    foreach ($attempt in 1..5) {
        Remove-Item -LiteralPath $copyPath `
            -Force `
            -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $copyPath -PathType Leaf)) {
            $script:CodexCliTemporaryCopy = ""
            return
        }
        Start-Sleep -Milliseconds 100
    }
    Info "Warning: temporary Codex CLI copy could not be removed yet: $copyPath"
}

function Remove-StaleCodexCliCopies {
    Get-ChildItem -LiteralPath $RuntimeDir `
        -File `
        -Force `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like "codex-cli-*.exe" -or
            $_.Name -like ".codex-cli-*.exe.codex-model-bridge-*.tmp"
        } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName `
                -Force `
                -ErrorAction SilentlyContinue
        }
}

function New-RunnableCodexCliCopy(
    [string]$SourcePath,
    [string]$Fingerprint
) {
    if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
        Die "could not fingerprint protected Codex CLI: $SourcePath"
    }

    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    Remove-TemporaryCodexCliCopy
    $copyPath = Join-Path $RuntimeDir (
        "codex-cli-{0}-{1}-{2}.exe" -f
            $Fingerprint,
            $PID,
            ([Guid]::NewGuid().ToString("N"))
    )

    try {
        Copy-FileAtomically $SourcePath $copyPath
        $copyHash = Get-FileSha256 $copyPath
        if ($copyHash -ne $Fingerprint) {
            Die "temporary Codex CLI copy failed SHA-256 verification: $copyPath"
        }
        if (-not (Test-ExecutableFile $copyPath)) {
            Die "temporary Codex CLI copy is not executable: $copyPath"
        }
    }
    catch {
        Remove-Item -LiteralPath $copyPath `
            -Force `
            -ErrorAction SilentlyContinue
        throw
    }

    $script:CodexCliTemporaryCopy = $copyPath
    return $copyPath
}

function Get-CodexCliCandidates {
    $candidates = @()
    $userBinRoots = @()

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($script:CodexPackageFamilyName)) {
            $packageLocal = Join-Path $env:LOCALAPPDATA (
                "Packages\{0}\LocalCache\Local" -f
                    $script:CodexPackageFamilyName
            )
            foreach ($relative in @(
                "OpenAI\Codex\bin",
                "Codex\bin",
                "OpenAI\ChatGPT\bin"
            )) {
                $userBinRoots += Join-Path $packageLocal $relative
            }
        }

        $userBinRoots += Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
        $userBinRoots += Join-Path $env:LOCALAPPDATA "Codex\bin"
    }

    foreach ($binRoot in ($userBinRoots | Select-Object -Unique)) {
        $candidates += Join-Path $binRoot "codex.exe"
        if (-not (Test-Path -LiteralPath $binRoot -PathType Container)) {
            continue
        }
        $candidates += @(
            Get-ChildItem -LiteralPath $binRoot `
                -Filter "codex.exe" `
                -File `
                -Recurse `
                -Depth 4 `
                -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -ExpandProperty FullName
        )
    }

    $packageRoots = @(
        $script:CodexPackageInstallLocation,
        (Split-Path -Parent $script:CodexExecutable)
    ) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        (Test-Path -LiteralPath $_ -PathType Container)
    } | Select-Object -Unique

    foreach ($root in $packageRoots) {
        foreach ($relative in @(
            "app\resources\codex.exe",
            "app\resources\app.asar.unpacked\codex.exe",
            "resources\codex.exe",
            "resources\app.asar.unpacked\codex.exe",
            "app.asar.unpacked\codex.exe",
            "codex.exe"
        )) {
            $candidates += Join-Path $root $relative
        }
    }

    foreach ($root in $packageRoots) {
        if ([string]::IsNullOrWhiteSpace($root) -or
            -not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $candidates += @(
            Get-ChildItem -LiteralPath $root `
                -Filter "codex.exe" `
                -File `
                -Recurse `
                -Depth 5 `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $normalized = Normalize-LocalPath $_.FullName
                    $normalized -match (
                        '(?i)\\(?:resources|bin)(?:\\[^\\]+)*\\codex\.exe$'
                    )
                } |
                Select-Object -ExpandProperty FullName
        )
    }

    $targetExecutable = Normalize-LocalPath $script:CodexExecutable
    $ordered = @(
        $candidates |
            Where-Object {
                $_ -and
                (Normalize-LocalPath $_) -ine $targetExecutable
            } |
            Select-Object -Unique
    )
    if (-not [string]::IsNullOrWhiteSpace($script:CodexExecutable) -and
        (Split-Path -Leaf $script:CodexExecutable) -ieq "codex.exe") {
        $ordered += $script:CodexExecutable
    }
    return @($ordered | Select-Object -Unique)
}

function Invoke-CodexCliCapture(
    [string[]]$Arguments,
    [string]$OutFile,
    [string]$ErrFile,
    [int]$TimeoutMilliseconds = 15000
) {
    Remove-Item $OutFile, $ErrFile -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $script:CodexCliPath `
        -ArgumentList $Arguments `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $OutFile `
        -RedirectStandardError $ErrFile `
        -ErrorAction Stop
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Die "Codex CLI timed out after $TimeoutMilliseconds ms: $script:CodexCliPath"
    }
    $exitCode = $null
    try {
        $process.WaitForExit()
        $process.Refresh()
        $exitCode = $process.ExitCode
    }
    catch {
    }
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        Write-LogTail "Codex CLI stderr" $ErrFile
        Die "Codex CLI failed with code ${exitCode}: $script:CodexCliPath"
    }
}

function Resolve-CodexCli {
    Info "[2/6] Codex CLI display catalog"
    $failures = @()
    $catalog = $null

    foreach ($candidate in (Get-CodexCliCandidates)) {
        if (-not (Test-ExecutableFile $candidate)) {
            continue
        }

        $bundledTemp = ""
        try {
            $resolved = (Resolve-Path -LiteralPath $candidate).Path
            $fingerprint = Get-FileSha256 $resolved
            if ([string]::IsNullOrWhiteSpace($fingerprint)) {
                Die "could not fingerprint Codex CLI: $resolved"
            }

            $script:CodexCliSourcePath = $resolved
            $script:CodexCliFingerprint = $fingerprint
            $script:CodexCliPath = $resolved
            if (Test-WindowsAppsPath $resolved) {
                $script:CodexCliPath = New-RunnableCodexCliCopy `
                    $resolved `
                    $fingerprint
            }

            New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
            $script:BundledCatalogPath = Join-Path $RuntimeDir (
                "bundled-models-{0}.json" -f $script:CodexCliFingerprint
            )
            $bundledErr = Join-Path $LogDir "codex-cli-bundled.err.log"
            $bundledTemp = "$script:BundledCatalogPath.tmp-$PID"

            Info "      CLI source: $script:CodexCliSourcePath"
            if ($script:CodexCliPath -ine $script:CodexCliSourcePath) {
                Info "      runnable copy: $script:CodexCliPath"
            }

            Invoke-CodexCliCapture `
                -Arguments @("debug", "models", "--bundled") `
                -OutFile $bundledTemp `
                -ErrFile $bundledErr
            $catalog = Get-Content -LiteralPath $bundledTemp `
                -Raw |
                ConvertFrom-Json
            if ($null -eq $catalog.models -or @($catalog.models).Count -eq 0) {
                Die "bundled Codex catalog is empty: $script:CodexCliPath"
            }
            Move-Item -LiteralPath $bundledTemp `
                -Destination $script:BundledCatalogPath `
                -Force
            $bundledTemp = ""
            break
        }
        catch {
            $failures += "{0}: {1}" -f $candidate, $_.Exception.Message
            Info (
                "Warning: could not use Codex CLI candidate: {0} ({1})" -f
                    $candidate,
                    $_.Exception.Message
            )
            Remove-TemporaryCodexCliCopy
            $script:CodexCliPath = ""
            $script:CodexCliSourcePath = ""
            $script:CodexCliFingerprint = ""
            $catalog = $null
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace($bundledTemp)) {
                Remove-Item -LiteralPath $bundledTemp `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:CodexCliPath) -or
        $null -eq $catalog) {
        if (-not (Test-Path -LiteralPath $BundledCatalogTemplate -PathType Leaf)) {
            $detail = ($failures | Select-Object -First 3) -join "; "
            if ([string]::IsNullOrWhiteSpace($detail)) {
                Die "could not find a usable Codex CLI or bundled catalog template"
            }
            Die "could not run a Codex CLI candidate and no bundled catalog template is available. $detail"
        }

        try {
            $catalog = Get-Content -LiteralPath $BundledCatalogTemplate `
                -Raw |
                ConvertFrom-Json
            if ($null -eq $catalog.models -or @($catalog.models).Count -eq 0) {
                Die "bundled catalog template contains no models: $BundledCatalogTemplate"
            }
            $script:CodexCliPath = ""
            $script:CodexCliSourcePath = ""
            $script:CodexCliFingerprint = Get-FileSha256 `
                $BundledCatalogTemplate
            if ([string]::IsNullOrWhiteSpace($script:CodexCliFingerprint)) {
                Die "could not fingerprint bundled catalog template: $BundledCatalogTemplate"
            }
            $script:BundledCatalogPath = $BundledCatalogTemplate
            Info "Warning: Codex CLI catalog probe unavailable; using bundled catalog template"
            Info "      bundled catalog: $BundledCatalogTemplate"
        }
        catch {
            Die "could not load bundled catalog template: $($_.Exception.Message)"
        }
    }

    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    $script:RuntimeCatalogCachePath = Join-Path $RuntimeDir (
        "runtime-models-v2-{0}.json" -f $script:CodexCliFingerprint
    )
    $script:RuntimeGeneration = [Guid]::NewGuid().ToString("N")
    $script:RuntimeCatalogPath = Join-Path $ScriptDir (
        ".codex-model-bridge-runtime-{0}.json" -f
            $script:RuntimeGeneration
    )
    $script:RuntimeCatalogMetaPath = Join-Path $RuntimeDir (
        "runtime-models-{0}-{1}.meta.json" -f
            $script:CodexCliFingerprint,
            $script:RuntimeGeneration
    )

    Info "      metadata templates: $(@($catalog.models).Count)"

    if (Test-Path -LiteralPath $script:RuntimeCatalogCachePath -PathType Leaf) {
        Copy-FileAtomically `
            $script:RuntimeCatalogCachePath `
            $script:RuntimeCatalogPath
        Info "      previous runtime cache: loaded"
    }
    Info "      runtime catalog: $script:RuntimeCatalogPath"
}

function Join-LaunchArguments([string[]]$LaunchArgs) {
    $escaped = $LaunchArgs | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + $_.Replace('\', '\\').Replace('"', '\"') + '"'
        }
        else {
            $_
        }
    }
    return ($escaped -join " ")
}

function Ensure-ActivationManagerType {
    if ("CodexPatchAumid.AppActivator" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace CodexPatchAumid {
    [ComImport]
    [Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    public class ApplicationActivationManager {
    }

    [ComImport]
    [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IApplicationActivationManager {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            ActivateOptions options,
            out uint processId);
    }

    [Flags]
    public enum ActivateOptions {
        None = 0,
        DesignMode = 1,
        NoErrorUI = 2,
        NoSplashScreen = 4
    }

    public static class AppActivator {
        public static int Activate(string appUserModelId, string arguments, out uint processId) {
            IApplicationActivationManager manager =
                (IApplicationActivationManager)new ApplicationActivationManager();
            return manager.ActivateApplication(
                appUserModelId,
                arguments,
                ActivateOptions.None,
                out processId);
        }
    }
}
"@
}

function Start-CodexViaAlias([string]$AliasName, [string[]]$LaunchArgs) {
    if ([string]::IsNullOrWhiteSpace($AliasName)) {
        return $false
    }

    try {
        Info "      launching via app execution alias: $AliasName"
        $process = Start-Process -FilePath $AliasName -ArgumentList $LaunchArgs -PassThru -ErrorAction Stop
        $script:LaunchedProcessId = $process.Id
        return $true
    }
    catch {
        Info "      alias launch fallback: $($_.Exception.Message)"
    }

    try {
        $cmdArgs = @("/d", "/c", "start", '""', $AliasName) + $LaunchArgs
        Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -WindowStyle Hidden -ErrorAction Stop | Out-Null
        $script:LaunchedProcessId = 0
        return $true
    }
    catch {
        Info "      alias shell fallback failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-CodexViaPackageExecutable([string[]]$LaunchArgs) {
    if ([string]::IsNullOrWhiteSpace($script:CodexLaunchWorkingDirectory) -or
        $script:CodexLaunchPrefixArguments.Count -eq 0) {
        return $false
    }

    try {
        $arguments = @($script:CodexLaunchPrefixArguments) + @($LaunchArgs)
        Info "      launching package executable: $script:CodexExecutable"
        $process = Start-Process -FilePath $script:CodexExecutable `
            -WorkingDirectory $script:CodexLaunchWorkingDirectory `
            -ArgumentList $arguments `
            -PassThru `
            -ErrorAction Stop
        $script:LaunchedProcessId = $process.Id
        return $true
    }
    catch {
        Info "      package executable fallback: $($_.Exception.Message)"
        return $false
    }
}

function Start-CodexViaAumid([string]$Aumid, [string[]]$LaunchArgs) {
    if ([string]::IsNullOrWhiteSpace($Aumid)) {
        return $false
    }

    try {
        Info "      launching via AUMID: $Aumid"
        Ensure-ActivationManagerType
        [uint32]$processId = 0
        $argumentString = Join-LaunchArguments $LaunchArgs
        $result = [CodexPatchAumid.AppActivator]::Activate($Aumid, $argumentString, [ref]$processId)
        if ($result -ne 0) {
            throw ("ActivateApplication failed with HRESULT 0x{0:X8}" -f $result)
        }
        $script:LaunchedProcessId = $processId
        return $true
    }
    catch {
        Info "      AUMID activation fallback: $($_.Exception.Message)"
        return $false
    }
}

function Start-CodexViaAppsFolder([string]$Aumid) {
    if ([string]::IsNullOrWhiteSpace($Aumid)) {
        return $false
    }
    try {
        Info "      launching via AppsFolder; Chromium proxy flags cannot be forwarded in this fallback"
        Start-Process -FilePath "explorer.exe" -ArgumentList @("shell:AppsFolder\$Aumid") -ErrorAction Stop | Out-Null
        $script:LaunchedProcessId = 0
        return $true
    }
    catch {
        Info "      shell:AppsFolder launch failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-CodexWithProxyBypass {
    $launchArgs = @("--no-proxy-server", "--proxy-bypass-list=$ProxyBypassList")
    $script:LaunchedProcessId = 0

    if (Test-WindowsAppsPath $script:CodexExecutable) {
        if ((Start-CodexViaAumid $script:CodexAumid $launchArgs) -or
            (Start-CodexViaAlias $script:CodexAliasExecutable $launchArgs) -or
            (Start-CodexViaAlias $script:CodexAlternateAliasExecutable $launchArgs) -or
            (Start-CodexViaAlias (Split-Path -Leaf $script:CodexExecutable) $launchArgs) -or
            (Start-CodexViaPackageExecutable $launchArgs) -or
            (Start-CodexViaAppsFolder $script:CodexAumid)) {
            return
        }
        Die "could not launch the $script:CodexPackageName Store app. Make sure the OpenAI Codex stable or Beta package is installed and Get-StartApps lists its AUMID."
    }

    try {
        $process = Start-Process -FilePath $script:CodexExecutable `
            -ArgumentList $launchArgs `
            -RedirectStandardOutput $CodexOutLog `
            -RedirectStandardError $CodexErrLog `
            -PassThru `
            -ErrorAction Stop
        $script:LaunchedProcessId = $process.Id
    }
    catch {
        $message = $_.Exception.Message
        if ((Test-WindowsAppsPath $script:CodexExecutable) -or $message -match "Access is denied|拒绝访问") {
            if ((Start-CodexViaAumid $script:CodexAumid $launchArgs) -or
                (Start-CodexViaAlias $script:CodexAliasExecutable $launchArgs) -or
                (Start-CodexViaAlias $script:CodexAlternateAliasExecutable $launchArgs) -or
                (Start-CodexViaAlias (Split-Path -Leaf $script:CodexExecutable) $launchArgs) -or
                (Start-CodexViaPackageExecutable $launchArgs) -or
                (Start-CodexViaAppsFolder $script:CodexAumid)) {
                return
            }
            Die "could not launch $script:TargetApp after direct Start-Process failed. Enable its app execution alias, or make sure Get-StartApps lists ChatGPT or Codex so the script can resolve an AUMID."
        }
        throw
    }
}

function Resolve-CodexApp {
    $configured = Get-ConfigValue "codex_app_path"
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $candidate = Expand-LocalPath $configured
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Set-CodexExecutable $candidate
            return
        }
        Die "configured codex_app_path is not executable: $configured"
    }

    $officialPackage = Get-OpenAICodexPackage
    if ($officialPackage -and (Set-OpenAICodexPackage $officialPackage)) {
        return
    }

    $common = @(
        (Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\Codex.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\OpenAI\ChatGPT\ChatGPT.exe"),
        (Join-Path $env:ProgramFiles "OpenAI\Codex\Codex.exe"),
        (Join-Path $env:ProgramFiles "OpenAI\ChatGPT\ChatGPT.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\Codex.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Codex\Codex.exe"),
        (Join-Path $env:LOCALAPPDATA "Codex\Codex.exe"),
        (Join-Path $env:USERPROFILE "AppData\Local\Programs\Codex\Codex.exe"),
        (Join-Path $env:ProgramFiles "Codex\Codex.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\ChatGPT.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\ChatGPT\ChatGPT.exe"),
        (Join-Path $env:LOCALAPPDATA "ChatGPT\ChatGPT.exe"),
        (Join-Path $env:USERPROFILE "AppData\Local\Programs\ChatGPT\ChatGPT.exe"),
        (Join-Path $env:ProgramFiles "ChatGPT\ChatGPT.exe")
    )
    if (${env:ProgramFiles(x86)}) {
        $common += (Join-Path ${env:ProgramFiles(x86)} "OpenAI\Codex\Codex.exe")
        $common += (Join-Path ${env:ProgramFiles(x86)} "OpenAI\ChatGPT\ChatGPT.exe")
        $common += (Join-Path ${env:ProgramFiles(x86)} "Codex\Codex.exe")
        $common += (Join-Path ${env:ProgramFiles(x86)} "ChatGPT\ChatGPT.exe")
    }

    foreach ($candidate in $common) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            Set-CodexExecutable $candidate
            return
        }
    }

    foreach ($candidate in (Get-StoreCodexCandidates)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            Set-CodexExecutable $candidate
            return
        }
    }

    $roots = @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($executableName in @("Codex.exe", "ChatGPT.exe")) {
        foreach ($root in $roots) {
            $match = Get-ChildItem -LiteralPath $root -Filter $executableName -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) {
                Set-CodexExecutable $match.FullName
                return
            }
        }
    }

    Die "could not find the OpenAI Codex stable/Beta package, ChatGPT, or legacy Codex desktop app. Set codex_app_path in $ConfigFile"
}

function Test-CodexAppServerCommandLine([string]$CommandLine) {
    return (
        -not [string]::IsNullOrWhiteSpace($CommandLine) -and
        $CommandLine -match '(?i)\bapp-server\b'
    )
}

function Get-RunningCodexProcesses {
    $normalizedTarget = Normalize-LocalPath $script:CodexExecutable
    $normalizedPackageRoot = Normalize-LocalPath $script:CodexPackageInstallLocation

    try {
        $processes = Get-CimInstance Win32_Process -ErrorAction Stop
    }
    catch {
        Die "could not inspect Windows processes: $($_.Exception.Message)"
    }

    return @(
        $processes |
            Where-Object {
                $processPath = Normalize-LocalPath $_.ExecutablePath
                $commandLine = [string]$_.CommandLine
                -not [string]::IsNullOrWhiteSpace($processPath) -and
                -not (Test-CodexAppServerCommandLine $commandLine) -and
                (
                    $processPath -ieq $normalizedTarget -or
                    (
                        -not [string]::IsNullOrWhiteSpace($normalizedPackageRoot) -and
                        ($processPath -ieq $normalizedPackageRoot -or
                            $processPath.StartsWith($normalizedPackageRoot + "\", [StringComparison]::OrdinalIgnoreCase))
                    )
                )
            }
    )
}

function Ensure-CodexNotRunning {
    Info "[1/6] Target app: $script:CodexAppPath"
    if (-not [string]::IsNullOrWhiteSpace($script:CodexPackageName)) {
        Info "      package: $script:CodexPackageName"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CodexAliasExecutable)) {
        Info "      alias: $script:CodexAliasExecutable"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CodexAlternateAliasExecutable)) {
        Info "      alternate alias: $script:CodexAlternateAliasExecutable"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CodexAumid)) {
        Info "      AUMID: $script:CodexAumid"
    }
    $running = @(Get-RunningCodexProcesses)

    if ($running.Count -gt 0) {
        Write-Host "$script:TargetApp is already running. Quit ChatGPT/Codex first, then run this script again."
        $running | ForEach-Object {
            Write-Host ("      {0} {1}" -f $_.ProcessId, $_.ExecutablePath)
        }
        Die "target app is already running"
    }

    Info "      not running"
}

function Get-RunningCodexAppServerProcesses {
    try {
        $processes = Get-CimInstance Win32_Process -ErrorAction Stop
    }
    catch {
        Die "could not inspect Codex app-server processes: $($_.Exception.Message)"
    }

    return @(
        $processes |
            Where-Object {
                $processName = [string]$_.Name
                $commandLine = [string]$_.CommandLine
                (
                    $processName -match '(?i)^codex(?:-app-server)?\.exe$'
                ) -and
                (Test-CodexAppServerCommandLine $commandLine)
            }
    )
}

function Stop-StaleCodexAppServers {
    $running = @(Get-RunningCodexAppServerProcesses)
    if ($running.Count -eq 0) {
        Info "      background app-server: not running"
        return
    }

    Info "      stopping background app-server before catalog injection"
    $running | ForEach-Object {
        Info ("      {0} {1}" -f $_.ProcessId, $_.CommandLine)
    }

    if (-not [string]::IsNullOrWhiteSpace($script:CodexCliPath) -and
        (Test-Path -LiteralPath $script:CodexCliPath -PathType Leaf)) {
        $out = Join-Path $LogDir "codex-app-server-stop.out.log"
        $err = Join-Path $LogDir "codex-app-server-stop.err.log"
        Remove-Item $out, $err -ErrorAction SilentlyContinue
        try {
            $stopper = Start-Process -FilePath $script:CodexCliPath `
                -ArgumentList @("app-server", "daemon", "stop") `
                -PassThru `
                -WindowStyle Hidden `
                -RedirectStandardOutput $out `
                -RedirectStandardError $err `
                -ErrorAction Stop
            if (-not $stopper.WaitForExit(5000)) {
                Stop-Process -Id $stopper.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Info "      daemon stop command unavailable: $($_.Exception.Message)"
        }
    }

    foreach ($attempt in 1..20) {
        $remaining = @(Get-RunningCodexAppServerProcesses)
        if ($remaining.Count -eq 0) {
            Info "      background app-server: stopped"
            return
        }
        $remaining | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 250
    }

    $remaining = @(Get-RunningCodexAppServerProcesses)
    if ($remaining.Count -gt 0) {
        $ids = @($remaining | ForEach-Object { $_.ProcessId }) -join ", "
        Die "could not stop stale Codex app-server process(es): $ids"
    }
}

function Find-MitmDump {
    $cmd = Get-Command mitmdump -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidates = @()
    $candidates += (Join-Path $env:USERPROFILE ".local\bin\mitmdump.exe")
    if ($env:APPDATA -and (Test-Path -LiteralPath (Join-Path $env:APPDATA "Python"))) {
        $candidates += Get-ChildItem -LiteralPath (Join-Path $env:APPDATA "Python") -Filter "mitmdump.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

function Invoke-WithInstallProxy([scriptblock]$ScriptBlock) {
    $names = @("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy")
    $old = @{}
    foreach ($name in $names) {
        $old[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }

    $setProxy = [string]::IsNullOrWhiteSpace($old["HTTP_PROXY"]) -and [string]::IsNullOrWhiteSpace($old["http_proxy"])
    if ($setProxy) {
        [Environment]::SetEnvironmentVariable("HTTP_PROXY", "http://127.0.0.1:7890", "Process")
        [Environment]::SetEnvironmentVariable("HTTPS_PROXY", "http://127.0.0.1:7890", "Process")
    }

    try {
        & $ScriptBlock
    }
    finally {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $old[$name], "Process")
        }
    }
}

function Ensure-MitmDump {
    $script:MitmDumpCmd = Find-MitmDump
    if ($script:MitmDumpCmd) {
        Info "[3/6] mitmdump: $script:MitmDumpCmd"
        return
    }

    Info "[3/6] mitmdump: installing mitmproxy"
    $installed = $false

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info "      using winget"
        Invoke-WithInstallProxy {
            & winget install --id mitmproxy.mitmproxy -e --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -eq 0) {
                $script:installedByWinget = $true
            }
        }
        $installed = $script:installedByWinget -eq $true
    }

    if (-not $installed -and (Get-Command uv -ErrorAction SilentlyContinue)) {
        Info "      using uv"
        Invoke-WithInstallProxy {
            & uv tool install mitmproxy
            if ($LASTEXITCODE -eq 0) {
                $script:installedByUv = $true
            }
        }
        $installed = $script:installedByUv -eq $true
    }

    if (-not $installed -and (Get-Command pipx -ErrorAction SilentlyContinue)) {
        Info "      using pipx"
        Invoke-WithInstallProxy {
            & pipx install mitmproxy
            if ($LASTEXITCODE -eq 0) {
                $script:installedByPipx = $true
            }
        }
        $installed = $script:installedByPipx -eq $true
    }

    if (-not $installed) {
        $python = Get-Command py -ErrorAction SilentlyContinue
        if (-not $python) {
            $python = Get-Command python -ErrorAction SilentlyContinue
        }
        if ($python) {
            Info "      using python -m pip"
            Invoke-WithInstallProxy {
                & $python.Source -m pip install --user mitmproxy
                if ($LASTEXITCODE -eq 0) {
                    $script:installedByPip = $true
                }
            }
            $installed = $script:installedByPip -eq $true
        }
    }

    if (-not $installed) {
        Die "could not install mitmproxy. Install winget, uv, pipx, or Python first."
    }

    $script:MitmDumpCmd = Find-MitmDump
    if (-not $script:MitmDumpCmd) {
        Die "mitmdump still not found after installation. Check PATH."
    }

    Info "      installed: $script:MitmDumpCmd"
}

function Generate-CaIfNeeded {
    if (Test-Path -LiteralPath $CaCert -PathType Leaf) {
        Info "      exists: $CaCert"
        return
    }

    Info "      generating CA"
    New-Item -ItemType Directory -Force -Path $CaDir | Out-Null
    $out = Join-Path $env:TEMP "mitmdump-ca.out"
    $err = Join-Path $env:TEMP "mitmdump-ca.err"
    Remove-Item $out, $err -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath $script:MitmDumpCmd `
        -ArgumentList @("--listen-port", "22339", "--set", "block_global=false", "--flow-detail", "0", "--set", "termlog_verbosity=error") `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err

    $deadline = (Get-Date).AddSeconds(10)
    while ((-not (Test-Path -LiteralPath $CaCert -PathType Leaf)) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
    }

    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $CaCert -PathType Leaf)) {
        Die "CA generation timed out: $CaCert"
    }

    Info "      generated: $CaCert"
}

function Ensure-Ca {
    Info "[4/6] mitmproxy CA"
    Generate-CaIfNeeded

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CaCert)
    $existing = Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Thumbprint -eq $cert.Thumbprint } | Select-Object -First 1
    if ($existing) {
        Info "      current-user root trust: ok"
        return
    }

    Import-Certificate -FilePath $CaCert -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    Info "      current-user root trust: added"
}

function Write-LogTail([string]$Label, [string]$Path, [int]$Lines = 60) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    try {
        $content = @(Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop)
    }
    catch {
        Info "      could not read $Label at ${Path}: $($_.Exception.Message)"
        return
    }

    if ($content.Count -eq 0) {
        return
    }

    Info "      $Label ($Path)"
    $content | ForEach-Object { Write-Host "      $_" }
}

function Throw-MitmProcessFailure(
    [System.Diagnostics.Process]$Process,
    [string]$Phase,
    [string]$OutLog,
    [string]$ErrLog
) {
    try {
        $Process.WaitForExit()
        $Process.Refresh()
        $exitCode = $Process.ExitCode
        if ($null -eq $exitCode) {
            $exitCode = "unknown"
        }
    }
    catch {
        $exitCode = "unknown"
    }

    Write-LogTail "mitmdump stderr" $ErrLog
    Write-LogTail "mitmdump stdout" $OutLog
    Die "mitmdump exited during $Phase with code $exitCode. Logs: $ErrLog and $OutLog"
}

function Ensure-LocalRedirectorReady {
    Info "[5/6] local redirector"
    $out = Join-Path $env:TEMP "mitmdump-local-probe.out"
    $err = Join-Path $env:TEMP "mitmdump-local-probe.err"
    Remove-Item $out, $err -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath $script:MitmDumpCmd `
        -ArgumentList @("--mode", "local:codex-local-probe-never-match", "--flow-detail", "0", "--set", "termlog_verbosity=error") `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err

    if (-not $process.WaitForExit(5000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Info "      ready"
        return
    }

    Write-LogTail "local redirector stderr" $err
    Write-LogTail "local redirector stdout" $out
    try {
        $process.Refresh()
        $exitCode = $process.ExitCode
        if ($null -eq $exitCode) {
            $exitCode = "unknown"
        }
    }
    catch {
        $exitCode = "unknown"
    }
    Die "mitmproxy local redirector probe failed with code $exitCode"
}

function Stop-ExistingCapture {
    $existing = Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.Contains("mitmdump") -and
            $_.CommandLine.Contains($RewriteScript) -and
            $_.ProcessId -ne $PID
        }

    if ($existing) {
        Info "      stopping previous mitmdump capture"
        $existing | ForEach-Object {
            Info ("      {0}" -f $_.ProcessId)
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1

        $failed = @()
        $existing | ForEach-Object {
            $process = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
            if ($process) {
                $failed += $_.ProcessId
            }
        }
        if ($failed.Count -gt 0) {
            Die ("could not stop previous mitmdump capture: {0}" -f ($failed -join ", "))
        }
    }
}

function Set-MitmdumpCatalogEnvironment {
    [Environment]::SetEnvironmentVariable(
        "CODEX_MODEL_BRIDGE_BUNDLED_CATALOG",
        $script:BundledCatalogPath,
        "Process"
    )
    [Environment]::SetEnvironmentVariable(
        "CODEX_MODEL_BRIDGE_RUNTIME_CATALOG",
        $script:RuntimeCatalogPath,
        "Process"
    )
    [Environment]::SetEnvironmentVariable(
        "CODEX_MODEL_BRIDGE_RUNTIME_META",
        $script:RuntimeCatalogMetaPath,
        "Process"
    )
    [Environment]::SetEnvironmentVariable(
        "CODEX_MODEL_BRIDGE_RUNTIME_GENERATION",
        $script:RuntimeGeneration,
        "Process"
    )
}

function Wait-ForRuntimeCatalog([System.Diagnostics.Process]$MitmProcess) {
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if ($MitmProcess.WaitForExit(100)) {
            Throw-MitmProcessFailure `
                $MitmProcess `
                "catalog generation" `
                $MitmOutLog `
                $MitmErrLog
        }

        if (Test-Path -LiteralPath $script:RuntimeCatalogMetaPath -PathType Leaf) {
            try {
                $meta = Get-Content -LiteralPath $script:RuntimeCatalogMetaPath `
                    -Raw |
                    ConvertFrom-Json
                if ([string]$meta.generation -eq $script:RuntimeGeneration -and
                    (Test-Path -LiteralPath $script:RuntimeCatalogPath -PathType Leaf)) {
                    $catalog = Get-Content -LiteralPath $script:RuntimeCatalogPath `
                        -Raw |
                        ConvertFrom-Json
                    $models = @($catalog.models)
                    if ($models.Count -eq 0) {
                        Die "runtime display catalog contains no models"
                    }
                    $runtimeSlugs = @(
                        $models |
                            ForEach-Object { [string]$_.slug } |
                            Where-Object {
                                -not [string]::IsNullOrWhiteSpace($_)
                            }
                    )
                    $apiModelIds = @(
                        @($meta.api_model_ids) |
                            ForEach-Object { [string]$_ } |
                            Where-Object {
                                -not [string]::IsNullOrWhiteSpace($_)
                            }
                    )
                    $missingApiModelIds = @(
                        $apiModelIds |
                            Where-Object { $runtimeSlugs -notcontains $_ }
                    )
                    Info "      display models: $($models.Count)"
                    Info "      API catalog fresh: $($meta.api_models_fetch_succeeded)"
                    if ($apiModelIds.Count -gt 0) {
                        Info (
                            "      API models in runtime: {0}/{1}" -f
                                ($apiModelIds.Count - $missingApiModelIds.Count),
                                $apiModelIds.Count
                        )
                    }
                    if ($missingApiModelIds.Count -gt 0) {
                        Die (
                            "API models missing from runtime display catalog: {0}" -f
                                (($missingApiModelIds | Select-Object -First 8) -join ", ")
                        )
                    }
                    return
                }
            }
            catch {
                if ($_.Exception.Message -like
                    "API models missing from runtime display catalog:*") {
                    throw
                }
            }
        }
    }

    Write-LogTail "mitmdump stderr" $MitmErrLog
    Write-LogTail "mitmdump stdout" $MitmOutLog
    Die "timed out waiting for runtime display catalog: $script:RuntimeCatalogPath"
}

function Save-RuntimeCatalogCache {
    if (-not (Test-Path -LiteralPath $script:RuntimeCatalogPath -PathType Leaf)) {
        Die "runtime catalog disappeared before it could be cached"
    }
    Copy-FileAtomically `
        $script:RuntimeCatalogPath `
        $script:RuntimeCatalogCachePath
    Info "      runtime catalog cache: $script:RuntimeCatalogCachePath"
}

function Test-RuntimeCatalogWithCodexConfig {
    if ([string]::IsNullOrWhiteSpace($script:CodexCliPath)) {
        Info "      Codex config catalog: deferred to desktop (CLI unavailable)"
        return
    }

    $out = Join-Path $LogDir "codex-cli-runtime.out.log"
    $err = Join-Path $LogDir "codex-cli-runtime.err.log"

    try {
        Invoke-CodexCliCapture `
            -Arguments @("debug", "models") `
            -OutFile $out `
            -ErrFile $err
        $expectedCatalog = Get-Content -LiteralPath $script:RuntimeCatalogPath `
            -Raw |
            ConvertFrom-Json
        $actualCatalog = Get-Content -LiteralPath $out -Raw |
            ConvertFrom-Json
        $expectedSlugs = @(
            @($expectedCatalog.models) |
                ForEach-Object { [string]$_.slug } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $actualSlugs = @(
            @($actualCatalog.models) |
                ForEach-Object { [string]$_.slug } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $missing = @($expectedSlugs | Where-Object { $actualSlugs -notcontains $_ })
        if ($expectedSlugs.Count -eq 0 -or $missing.Count -gt 0) {
            $sample = ($missing | Select-Object -First 5) -join ", "
            Die "Codex config did not load the runtime catalog; missing: $sample"
        }
        Info (
            "      Codex config catalog: ok ({0} expected present; {1} total)" -f
                $expectedSlugs.Count,
                $actualSlugs.Count
        )
    }
    catch {
        Write-LogTail "Codex CLI stderr" $err
        Info (
            "Warning: Codex CLI could not verify the temporary catalog; " +
            "desktop startup will perform the final load check"
        )
    }
}

function Get-NewCodexAppServerProcess([DateTime]$NotBefore) {
    $threshold = $NotBefore.AddSeconds(-2)
    $normalizedCli = Normalize-LocalPath $script:CodexCliPath
    try {
        $processes = Get-CimInstance Win32_Process -ErrorAction Stop
    }
    catch {
        return $null
    }

    return $processes |
        Where-Object {
            $commandLine = [string]$_.CommandLine
            $matchesAppServer = (
                (Test-CodexAppServerCommandLine $commandLine) -and
                $commandLine -notmatch '(?i)\bapp-server\s+daemon\b'
            )
            if ($matchesAppServer) {
                try {
                    $created = [DateTime]$_.CreationDate
                    $matchesAppServer = $created -ge $threshold
                }
                catch {
                }
            }

            $processPath = Normalize-LocalPath ([string]$_.ExecutablePath)
            $processName = [string]$_.Name
            $matchesAppServer -and (
                $processPath -ieq $normalizedCli -or
                $processName -ieq "codex.exe" -or
                $processName -ieq "wsl.exe"
            )
        } |
        Sort-Object CreationDate |
        Select-Object -First 1
}

function Wait-ForCodexStartupCatalogLoad(
    [System.Diagnostics.Process]$MitmProcess,
    [DateTime]$LaunchStarted
) {
    $deadline = $LaunchStarted.AddSeconds(45)
    $observedPid = 0
    $observedAt = $null

    while ((Get-Date) -lt $deadline) {
        if ($MitmProcess.WaitForExit(100)) {
            Throw-MitmProcessFailure `
                $MitmProcess `
                "desktop launch" `
                $MitmOutLog `
                $MitmErrLog
        }

        $appServer = Get-NewCodexAppServerProcess $LaunchStarted
        if ($null -ne $appServer) {
            $candidatePid = [int]$appServer.ProcessId
            if ($candidatePid -ne $observedPid) {
                $observedPid = $candidatePid
                $observedAt = Get-Date
                Info "      app-server process: $observedPid"
            }

            $alive = Get-Process -Id $observedPid -ErrorAction SilentlyContinue
            if ($alive -and
                $null -ne $observedAt -and
                ((Get-Date) - $observedAt).TotalMilliseconds -ge 2500) {
                Info "      startup catalog loaded"
                return
            }
            if (-not $alive) {
                $observedPid = 0
                $observedAt = $null
            }
        }

        if (((Get-Date) - $LaunchStarted).TotalSeconds -ge 15) {
            $running = @(Get-RunningCodexProcesses)
            if ($running.Count -gt 0) {
                Info "      app-server process was not observable; startup wait completed"
                return
            }
        }
        Start-Sleep -Milliseconds 150
    }

    Die "Codex desktop did not finish startup while the temporary catalog config was active"
}

function Start-CaptureAndOpenCodex {
    Info "[6/6] starting capture"
    Info "      local spec: $script:MitmLocalSpec"
    Info "      config: $ConfigFile"
    Info "      logs: $LogDir"

    Stop-ExistingCapture
    Initialize-Logs
    [Environment]::SetEnvironmentVariable("MITM_REWRITE_CONFIG", $ConfigFile, "Process")
    Set-MitmdumpCatalogEnvironment

    $mitm = $null
    try {
        $localModeArgument = '"local:{0}"' -f (
            $script:MitmLocalSpec.Replace('"', '\"')
        )
        $rewriteScriptArgument = '"{0}"' -f (
            $RewriteScript.Replace('"', '\"')
        )
        $mitmArguments = @(
            "--mode", $localModeArgument,
            "-s", $rewriteScriptArgument,
            "--flow-detail", "0",
            "--set", "upstream_cert=false",
            "--set", "connection_strategy=lazy",
            "--set", "termlog_verbosity=warn"
        )
        $mitm = Start-Process -FilePath $script:MitmDumpCmd `
            -ArgumentList $mitmArguments `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $MitmOutLog -RedirectStandardError $MitmErrLog `
            -ErrorAction Stop

        Wait-ForRuntimeCatalog $mitm
        Save-RuntimeCatalogCache
        Enable-CodexRuntimeCatalogConfig
        Test-RuntimeCatalogWithCodexConfig
        Remove-TemporaryCodexCliCopy

        Info "      launching $script:TargetApp"
        $launchStarted = Get-Date
        $proxyNames = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "NO_PROXY", "no_proxy")
        $saved = @{}
        foreach ($name in $proxyNames) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }

        try {
            foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")) {
                [Environment]::SetEnvironmentVariable($name, $null, "Process")
            }
            [Environment]::SetEnvironmentVariable("NO_PROXY", $NoProxyList, "Process")
            [Environment]::SetEnvironmentVariable("no_proxy", $NoProxyList, "Process")

            Start-CodexWithProxyBypass
        }
        finally {
            foreach ($name in $proxyNames) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
            }
        }

        if ($script:LaunchedProcessId -gt 0) {
            Info "      launched process id: $script:LaunchedProcessId"
        }
        Wait-ForCodexStartupCatalogLoad $mitm $launchStarted
        # The app-server can retain this path and open the catalog lazily when
        # model/list is first requested. Restore config but keep the file alive.
        Restore-CodexConfigFromMarker $false $true | Out-Null
        Info "      runtime catalog retained for active app-server"
        Info "      capture active; press Ctrl+C to stop"

        while (-not $mitm.WaitForExit(500)) {
        }
        Throw-MitmProcessFailure $mitm "capture" $MitmOutLog $MitmErrLog
    }
    finally {
        if ($script:ConfigInjectionActive) {
            try {
                Restore-CodexConfigFromMarker $false | Out-Null
            }
            catch {
                Info "Warning: could not restore temporary Codex config: $($_.Exception.Message)"
            }
        }
        if ($null -ne $mitm) {
            try {
                if (-not $mitm.HasExited) {
                    Stop-Process -Id $mitm.Id -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
            }
        }
        Remove-TemporaryCodexCliCopy
        Remove-ActiveRuntimeCatalogIfSafe
    }
}

if (-not (Test-Path -LiteralPath $RewriteScript -PathType Leaf)) {
    Die "rewrite script not found at $RewriteScript"
}
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    Info "Warning: no rewrite config at $ConfigFile - running pass-through."
}

Recover-StaleCodexConfigInjection
Remove-StaleProjectRuntimeCatalogs
Remove-StaleCodexCliCopies
Resolve-CodexApp
Ensure-CodexNotRunning
Initialize-Logs
Resolve-CodexCli
Stop-StaleCodexAppServers
try {
    Ensure-MitmDump
    Ensure-Ca
    Ensure-LocalRedirectorReady
    Start-CaptureAndOpenCodex
}
finally {
    Remove-TemporaryCodexCliCopy
}
