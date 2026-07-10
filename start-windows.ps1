# start-windows.ps1 - Single-run mitmdump local capture helper for ChatGPT and legacy Codex.

$ErrorActionPreference = "Stop"

if ($args.Count -gt 0) {
    Write-Error "This script accepts no arguments. Use config.json for local settings."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RewriteScript = Join-Path $ScriptDir "rewrite.py"
$ConfigFile = Join-Path $ScriptDir "config.json"

$script:TargetApp = "ChatGPT"
$script:CodexAppPath = ""
$script:CodexExecutable = ""
$script:CodexAliasExecutable = ""
$script:CodexAlternateAliasExecutable = ""
$script:CodexAumid = ""
$script:CodexPackageInstallLocation = ""
$script:MitmDumpCmd = ""
$MitmLocalSpec = "ChatGPT.exe,chatgpt.exe,ChatGPT,chatgpt,Codex.exe,codex.exe,Codex,codex"
$NoProxyList = "*"
$ProxyBypassList = "*"
$CaDir = Join-Path $env:USERPROFILE ".mitmproxy"
$CaCert = Join-Path $CaDir "mitmproxy-ca-cert.cer"
$LogDir = Join-Path $env:LOCALAPPDATA "CodexModelBridge\Logs"
$MitmOutLog = Join-Path $LogDir "mitmdump.out.log"
$MitmErrLog = Join-Path $LogDir "mitmdump.err.log"
$CodexOutLog = Join-Path $LogDir "codex.out.log"
$CodexErrLog = Join-Path $LogDir "codex.err.log"

function Info([string]$Message) {
    Write-Host $Message
}

function Die([string]$Message) {
    Write-Error $Message
    exit 1
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

    try {
        $manifest = Get-AppxPackageManifest $Package
    }
    catch {
        return ""
    }

    $applications = @($manifest.Package.Applications.Application)
    if ($applications.Count -eq 0) {
        return ""
    }

    $normalizedExecutable = Normalize-LocalPath $ExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($normalizedExecutable)) {
        foreach ($application in $applications) {
            $id = [string]$application.Id
            $executable = [string]$application.Executable
            if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($executable)) {
                continue
            }
            $candidate = Normalize-LocalPath (Join-Path $Package.InstallLocation $executable)
            if ($candidate -ieq $normalizedExecutable) {
                return "$($Package.PackageFamilyName)!$id"
            }
        }
    }

    foreach ($application in $applications) {
        $id = [string]$application.Id
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            return "$($Package.PackageFamilyName)!$id"
        }
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

function Set-CodexExecutable([string]$Path) {
    $script:CodexExecutable = (Resolve-Path -LiteralPath $Path).Path
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
    $script:CodexPackageInstallLocation = ""
    $script:CodexAumid = Resolve-CodexAumid $script:CodexExecutable
}

function Find-CodexExeUnder([string]$Root, [int]$Depth) {
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    foreach ($executableName in @("ChatGPT.exe", "Codex.exe")) {
        $direct = Join-Path $Root $executableName
        if (Test-Path -LiteralPath $direct -PathType Leaf) {
            return (Resolve-Path -LiteralPath $direct).Path
        }

        $match = Get-ChildItem -LiteralPath $Root -Filter $executableName -File -Recurse -Depth $Depth -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($match) {
            return $match.FullName
        }
    }

    return $null
}

function Get-StoreCodexCandidates {
    $candidates = @()

    foreach ($executableName in @("ChatGPT.exe", "Codex.exe")) {
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
        foreach ($packageName in @("*ChatGPT*", "*Codex*")) {
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
        foreach ($directoryName in @("*ChatGPT*", "*Codex*")) {
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
        Start-Process -FilePath $AliasName -ArgumentList $LaunchArgs -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Info "      alias launch fallback: $($_.Exception.Message)"
    }

    try {
        $cmdArgs = @("/d", "/c", "start", '""', $AliasName) + $LaunchArgs
        Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -WindowStyle Hidden -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Info "      alias shell fallback failed: $($_.Exception.Message)"
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
        return $true
    }
    catch {
        Info "      AUMID activation fallback: $($_.Exception.Message)"
    }

    try {
        Start-Process -FilePath "shell:AppsFolder\$Aumid" -ArgumentList $LaunchArgs -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Info "      shell:AppsFolder launch failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-CodexWithProxyBypass {
    $launchArgs = @("--no-proxy-server", "--proxy-bypass-list=$ProxyBypassList")

    if (Test-WindowsAppsPath $script:CodexExecutable) {
        if ((Start-CodexViaAlias $script:CodexAliasExecutable $launchArgs) -or
            (Start-CodexViaAumid $script:CodexAumid $launchArgs) -or
            (Start-CodexViaAlias $script:CodexAlternateAliasExecutable $launchArgs) -or
            (Start-CodexViaAlias (Split-Path -Leaf $script:CodexExecutable) $launchArgs)) {
            return
        }
        Die "could not launch $script:TargetApp Store app. Enable its app execution alias, or make sure Get-StartApps lists ChatGPT or Codex so the script can resolve an AUMID."
        return
    }

    try {
        Start-Process -FilePath $script:CodexExecutable `
            -ArgumentList $launchArgs `
            -RedirectStandardOutput $CodexOutLog `
            -RedirectStandardError $CodexErrLog `
            -ErrorAction Stop | Out-Null
    }
    catch {
        $message = $_.Exception.Message
        if ((Test-WindowsAppsPath $script:CodexExecutable) -or $message -match "Access is denied|拒绝访问") {
            if ((Start-CodexViaAlias $script:CodexAliasExecutable $launchArgs) -or
                (Start-CodexViaAumid $script:CodexAumid $launchArgs) -or
                (Start-CodexViaAlias $script:CodexAlternateAliasExecutable $launchArgs) -or
                (Start-CodexViaAlias (Split-Path -Leaf $script:CodexExecutable) $launchArgs)) {
                return
            }
            Die "could not launch $script:TargetApp after direct Start-Process failed. Enable its app execution alias, or make sure Get-StartApps lists ChatGPT or Codex so the script can resolve an AUMID."
            return
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

    $common = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\ChatGPT.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\ChatGPT\ChatGPT.exe"),
        (Join-Path $env:LOCALAPPDATA "ChatGPT\ChatGPT.exe"),
        (Join-Path $env:USERPROFILE "AppData\Local\Programs\ChatGPT\ChatGPT.exe"),
        (Join-Path $env:ProgramFiles "ChatGPT\ChatGPT.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\Codex.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Codex\Codex.exe"),
        (Join-Path $env:LOCALAPPDATA "Codex\Codex.exe"),
        (Join-Path $env:USERPROFILE "AppData\Local\Programs\Codex\Codex.exe"),
        (Join-Path $env:ProgramFiles "Codex\Codex.exe")
    )
    if (${env:ProgramFiles(x86)}) {
        $common += (Join-Path ${env:ProgramFiles(x86)} "ChatGPT\ChatGPT.exe")
        $common += (Join-Path ${env:ProgramFiles(x86)} "Codex\Codex.exe")
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
    foreach ($executableName in @("ChatGPT.exe", "Codex.exe")) {
        foreach ($root in $roots) {
            $match = Get-ChildItem -LiteralPath $root -Filter $executableName -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) {
                Set-CodexExecutable $match.FullName
                return
            }
        }
    }

    Die "could not find ChatGPT or legacy Codex desktop app. Set codex_app_path in $ConfigFile"
}

function Ensure-CodexNotRunning {
    Info "[1/5] Target app: $script:CodexAppPath"
    if (-not [string]::IsNullOrWhiteSpace($script:CodexAliasExecutable)) {
        Info "      alias: $script:CodexAliasExecutable"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CodexAlternateAliasExecutable)) {
        Info "      alternate alias: $script:CodexAlternateAliasExecutable"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CodexAumid)) {
        Info "      AUMID: $script:CodexAumid"
    }
    $normalizedTarget = Normalize-LocalPath $script:CodexExecutable
    $normalizedPackageRoot = Normalize-LocalPath $script:CodexPackageInstallLocation
    $running = Get-CimInstance Win32_Process |
        Where-Object {
            $processPath = Normalize-LocalPath $_.ExecutablePath
            -not [string]::IsNullOrWhiteSpace($processPath) -and
            (
                $processPath -ieq $normalizedTarget -or
                (
                    -not [string]::IsNullOrWhiteSpace($normalizedPackageRoot) -and
                    ($processPath -ieq $normalizedPackageRoot -or
                        $processPath.StartsWith($normalizedPackageRoot + "\", [StringComparison]::OrdinalIgnoreCase))
                )
            )
        }

    if ($running) {
        Write-Error "$script:TargetApp is already running. Quit ChatGPT/Codex first, then run this script again."
        $running | ForEach-Object {
            Write-Host ("      {0} {1}" -f $_.ProcessId, $_.ExecutablePath)
        }
        exit 1
    }

    Info "      not running"
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
        Info "[2/5] mitmdump: $script:MitmDumpCmd"
        return
    }

    Info "[2/5] mitmdump: installing mitmproxy"
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
    Info "[3/5] mitmproxy CA"
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

function Ensure-LocalRedirectorReady {
    Info "[4/5] local redirector"
    $out = Join-Path $env:TEMP "mitmdump-local-probe.out"
    $err = Join-Path $env:TEMP "mitmdump-local-probe.err"
    Remove-Item $out, $err -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath $script:MitmDumpCmd `
        -ArgumentList @("--mode", "local:codex-local-probe-never-match", "--flow-detail", "0", "--set", "termlog_verbosity=error") `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err

    Start-Sleep -Seconds 5
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Info "      ready"
        return
    }

    Write-Error "mitmproxy local redirector probe failed."
    if (Test-Path -LiteralPath $err) {
        Get-Content -LiteralPath $err | ForEach-Object { Write-Host "      $_" }
    }
    if (Test-Path -LiteralPath $out) {
        Get-Content -LiteralPath $out | ForEach-Object { Write-Host "      $_" }
    }
    exit 1
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

function Start-CaptureAndOpenCodex {
    Info "[5/5] starting capture"
    Info "      local spec: $MitmLocalSpec"
    Info "      config: $ConfigFile"
    Info "      logs: $LogDir"

    Stop-ExistingCapture
    Initialize-Logs
    [Environment]::SetEnvironmentVariable("MITM_REWRITE_CONFIG", $ConfigFile, "Process")

    $mitm = Start-Process -FilePath $script:MitmDumpCmd `
        -ArgumentList @("--mode", "local:$MitmLocalSpec", "-s", $RewriteScript, "--flow-detail", "0", "--set", "upstream_cert=false", "--set", "connection_strategy=lazy", "--set", "termlog_verbosity=error") `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $MitmOutLog -RedirectStandardError $MitmErrLog

    try {
        Start-Sleep -Seconds 2
        if ($mitm.HasExited) {
            exit $mitm.ExitCode
        }

        Info "      launching $script:TargetApp"
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

        Wait-Process -Id $mitm.Id
    }
    finally {
        Stop-Process -Id $mitm.Id -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $RewriteScript -PathType Leaf)) {
    Die "rewrite script not found at $RewriteScript"
}
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    Info "Warning: no rewrite config at $ConfigFile - running pass-through."
}

Resolve-CodexApp
Ensure-CodexNotRunning
Ensure-MitmDump
Ensure-Ca
Ensure-LocalRedirectorReady
Start-CaptureAndOpenCodex
