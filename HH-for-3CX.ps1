<#
.SYNOPSIS
    Holiday Helper for 3CX: a menu-driven tool for managing 3CX department holidays
    (weather closures, holidays, and special events).

.PARAMETER Test
    Read from 3CX but do not write anything. Summaries show what would have been changed.

.NOTES
    Settings are stored in Helper-for-3CX-Settings.json in the same folder as this script.
    If the file is missing, a template with instructions is created when the script starts.

    The 3CX API credentials are read from Azure Key Vault only when a 3CX access token is
    needed (at startup and about once an hour), and are cleared from memory right after.
    Only the access token is kept between requests.

.EXAMPLE
    & ".\HH-for-3CX.ps1"
    & ".\HH-for-3CX.ps1" -Test
#>
param(
    [switch]$Test
)

# ============================================================
# Configuration
# ============================================================
# All settings are read from Helper-for-3CX-Settings.json in the same folder as this script.
# If that file doesn't exist, a template with instructions is created on first run.
#
# To add a setting, add an entry to $SettingsDefinition. It is then written to new
# settings files (with its Help note), loaded from the file, and validated automatically.
#   Var      = script variable name          Path    = location in the JSON file
#   Default  = value used in new files       Help    = short note written into the file
#   Required = must not be blank             Pattern = regex the value must match (if set)
#   Allowed  = list of permitted values      Holiday = only used by Holiday Helper for 3CX
$ScriptFolder = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$SettingsFile = Join-Path $ScriptFolder "Helper-for-3CX-Settings.json"
$DebugLogFile = Join-Path $ScriptFolder "$([IO.Path]::GetFileNameWithoutExtension($PSCommandPath))-Debug.log"

$SettingsDefinition = @(
    @{ Var = 'PbxUrl'; Path = 'PhoneSystem.PbxUrl'; Default = ''; Required = $true; Pattern = '^https://\S+$'
       Help = 'Your 3CX web address, starting with https:// (e.g. https://yourcompany.3cx.us).' }

    @{ Var = 'KeyVaultName'; Path = 'KeyVault.VaultName'; Default = ''; Required = $true
       Help = 'Name of the Azure Key Vault that holds the 3CX API credentials.' }
    @{ Var = 'ClientIdSecretName'; Path = 'KeyVault.ClientIdSecretName'; Default = ''; Required = $true
       Help = 'Name of the Key Vault secret containing the 3CX API client ID.' }
    @{ Var = 'ClientSecretSecretName'; Path = 'KeyVault.ClientSecretSecretName'; Default = ''; Required = $true
       Help = 'Name of the Key Vault secret containing the 3CX API key (client secret).' }
    @{ Var = 'TenantId'; Path = 'KeyVault.TenantId'; Default = ''
       Pattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
       Help = 'Optional. Entra tenant (Directory) ID containing the Key Vault. Leave blank to use your default tenant.' }

    @{ Var = 'ExcludedDepartments'; Path = 'ExcludedDepartments'; Default = @('DEFAULT')
       Help = 'Department names, exactly as shown in 3CX, to hide from department lists.' }

    @{ Var = 'WeatherHolidayName'; Path = 'WeatherClosure.HolidayName'; Default = 'Weather Closure'; Required = $true
       Help = 'Name given to weather closure holidays in 3CX.' }
    @{ Var = 'WeatherGreeting'; Path = 'WeatherClosure.GreetingFileName'; Default = ''; Required = $true
       Help = 'Greeting played during a weather closure, exactly as named in 3CX (e.g. Weather Closure.wav).' }

    @{ Var = 'HolidayGreeting'; Path = 'HolidaysAndEvents.GreetingFileName'; Default = ''; Required = $true; Holiday = $true
       Help = 'Greeting played on holidays and special events, exactly as named in 3CX.' }
    @{ Var = 'HolidayList'; Path = 'HolidaysAndEvents.Holidays'; Holiday = $true
       Default = @(
           [ordered]@{ Name = 'New Years Day';    Type = 'Fixed'; Month = 1;  Day = 1 }
           [ordered]@{ Name = 'Presidents Day';   Type = 'Nth';   Month = 2;  DayOfWeek = 'Monday';   Nth = 3 }
           [ordered]@{ Name = 'Independence Day'; Type = 'Fixed'; Month = 7;  Day = 4 }
           [ordered]@{ Name = 'Labor Day';        Type = 'Nth';   Month = 9;  DayOfWeek = 'Monday';   Nth = 1 }
           [ordered]@{ Name = 'Thanksgiving Day'; Type = 'Nth';   Month = 11; DayOfWeek = 'Thursday'; Nth = 4 }
           [ordered]@{ Name = 'Christmas Day';    Type = 'Fixed'; Month = 12; Day = 25 }
       )
       Help = 'Holidays offered by Add a Holiday. Type Fixed uses Month and Day. Type Nth uses Month, DayOfWeek, and Nth (1-4, or -1 for the last one in the month).' }
    @{ Var = 'SaturdayHolidayMoveTo'; Path = 'HolidaysAndEvents.WeekendObservance.SaturdayMoveTo'; Default = 'FridayBefore'
       Required = $true; Holiday = $true; Allowed = @('FridayBefore', 'MondayAfter', 'DontMove')
       Help = 'Where a holiday that falls on Saturday is moved: FridayBefore, MondayAfter, or DontMove.' }
    @{ Var = 'SundayHolidayMoveTo'; Path = 'HolidaysAndEvents.WeekendObservance.SundayMoveTo'; Default = 'MondayAfter'
       Required = $true; Holiday = $true; Allowed = @('FridayBefore', 'MondayAfter', 'DontMove')
       Help = 'Where a holiday that falls on Sunday is moved: FridayBefore, MondayAfter, or DontMove.' }
    @{ Var = 'ObservedLabel'; Path = 'HolidaysAndEvents.WeekendObservance.ObservedLabel'; Default = 'Observed'
       Required = $true; Holiday = $true; Pattern = '^[^()]+$'
       Help = 'Word added in parentheses to moved holidays, e.g. Observed gives "Christmas Day (Observed) 2027".' }

    @{ Var = 'UseMockData'; Path = 'Testing.UseMockData'; Default = $false; Allowed = @($true, $false)
       Help = 'true = use built-in sample data instead of 3CX; nothing is changed. Normally false.' }
    @{ Var = 'DebugMode'; Path = 'Testing.DebugMode'; Default = 'off'; Required = $true; Allowed = @('on', 'off')
       Help = 'on = log every API call to <script name>-Debug.log in the script folder. Normally off.' }
)

# Load built-in defaults (values from the settings file replace these at startup)
foreach ($s in $SettingsDefinition) { Set-Variable -Name $s.Var -Value $s.Default -Scope Script }

$UsesHolidaySettings = $true    # Holiday Helper for 3CX uses the Holiday settings

# ============================================================
# Setup
# ============================================================
# Windows PowerShell 5.1 may default to older TLS versions
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:AccessToken  = $null
$script:ClientId     = $null
$script:ClientSecret = $null
$script:TokenExpires = [datetime]::MinValue

# Navigation signals returned by input functions
$NavBack = '__BACK__'
$NavMenu = '__MENU__'
$script:MenuName = "Main Menu"   # Shown for the M option in navigation prompts

# ============================================================
# Settings file
# ============================================================
function Format-SettingValue($Value) {
    if ("$Value".Trim()) { "$Value" } else { "not set" }
}

function Set-TreeValue($Tree, [string]$Path, $Value) {
    $parts = $Path -split '\.'
    $node = $Tree
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if (-not $node.Contains($parts[$i])) { $node[$parts[$i]] = [ordered]@{} }
        $node = $node[$parts[$i]]
    }
    $node[$parts[-1]] = $Value
}

function ConvertTo-PrettyJson($Value, [int]$Level = 0, [switch]$Inline) {
    # Readable JSON writer (Windows PowerShell 5.1's ConvertTo-Json output is hard to read and edit)
    $pad = '  ' * ($Level + 1)
    $end = '  ' * $Level
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return ([string]$Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $pairs = foreach ($k in $Value.Keys) { "$(ConvertTo-PrettyJson ([string]$k)): $(ConvertTo-PrettyJson $Value[$k] ($Level + 1))" }
        if ($Inline) { return "{ " + ($pairs -join ", ") + " }" }
        return "{`n" + (($pairs | ForEach-Object { "$pad$_" }) -join ",`n") + "`n$end}"
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $list = @($Value)
        if ($list.Count -eq 0) { return '[]' }
        $items = foreach ($v in $list) { "$pad$(ConvertTo-PrettyJson $v ($Level + 1) -Inline)" }
        return "[`n" + ($items -join ",`n") + "`n$end]"
    }
    $text = ([string]$Value).Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $text + '"'
}

function New-SettingsFile {
    # Writes a template settings file with instructions and a short note for each setting
    $mustFill    = @($SettingsDefinition | Where-Object { $_.Required -and -not $_.Holiday -and -not "$($_.Default)".Trim() } | ForEach-Object { $_.Path })
    $holidayFill = @($SettingsDefinition | Where-Object { $_.Required -and $_.Holiday -and -not "$($_.Default)".Trim() } | ForEach-Object { $_.Path })

    $tree = [ordered]@{
        _Instructions = @(
            "FIRST-TIME SETUP: fill in the settings below, save this file, then run the script again."
            "Names that start with an underscore (_) are notes. The scripts ignore them."
            "Must be filled in: $($mustFill -join ', ')."
            "Also required by Holiday Helper for 3CX: $($holidayFill -join ', ')."
            "Keep the JSON format: text goes in double quotes; true, false, and numbers do not; items are separated by commas."
            "This file is shared by Holiday Helper for 3CX and Closure Helper for 3CX and must stay in the same folder as them."
        )
    }
    foreach ($s in $SettingsDefinition) {
        $parts = $s.Path -split '\.'
        $notePath = if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join '.') + "._$($parts[-1])" } else { "_$($parts[0])" }
        Set-TreeValue $tree $notePath $s.Help
        Set-TreeValue $tree $s.Path $s.Default
    }

    try {
        Set-Content -Path $SettingsFile -Value (ConvertTo-PrettyJson $tree) -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "Could not create settings file '$SettingsFile': $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Import-Settings {
    # Loads values from the settings file over the built-in defaults
    try {
        $cfg = Get-Content -Path $SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Host "Could not read settings file '$SettingsFile': $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Check the file for formatting mistakes, such as a missing comma or quotation mark." -ForegroundColor Yellow
        return $false
    }

    foreach ($s in $SettingsDefinition) {
        $value = $cfg
        foreach ($part in ($s.Path -split '\.')) {
            if ($null -eq $value) { break }
            $value = $value.$part
        }
        if ($null -eq $value) { continue }   # missing from the file: keep the default
        if ($s.Default -is [array]) { $value = @($value) }
        Set-Variable -Name $s.Var -Value $value -Scope Script
    }
    return $true
}

function Test-Settings {
    # Returns a list of problems with the loaded settings; nothing = valid
    $problems = @()
    foreach ($s in $SettingsDefinition) {
        if ($s.Holiday -and -not $UsesHolidaySettings) { continue }
        $value = Get-Variable -Name $s.Var -ValueOnly -Scope Script
        if ($null -eq $value -or ($value -is [string] -and -not $value.Trim())) {
            if ($s.Required) { $problems += "$($s.Path) must be filled in. $($s.Help)" }
            continue
        }
        if ($s.Pattern -and "$value" -notmatch $s.Pattern) {
            $problems += "$($s.Path) is not valid. $($s.Help)"
        }
        if ($s.Allowed) {
            $ok = @($s.Allowed | Where-Object { $_.GetType() -eq $value.GetType() -and $_ -eq $value }).Count -gt 0
            if (-not $ok) {
                $choices = @($s.Allowed | ForEach-Object { if ($_ -is [bool]) { "$_".ToLower() } else { $_ } }) -join ', '
                $problems += "$($s.Path) must be one of: $choices"
            }
        }
    }

    if ($UsesHolidaySettings) {
        $i = 0
        foreach ($h in @($HolidayList)) {
            $i++
            $label = "HolidaysAndEvents.Holidays item $i ($($h.Name))"
            if (-not "$($h.Name)".Trim()) { $problems += "$label needs a Name." }
            if (-not ([int]$h.Month -ge 1 -and [int]$h.Month -le 12)) { $problems += "$label needs a Month from 1 to 12."; continue }
            if ($h.Type -eq 'Fixed') {
                if (-not ([int]$h.Day -ge 1 -and [int]$h.Day -le [datetime]::DaysInMonth(2024, [int]$h.Month))) { $problems += "$label has an invalid Day." }   # leap year, so Feb 29 is allowed
            }
            elseif ($h.Type -eq 'Nth') {
                if (@('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday') -notcontains $h.DayOfWeek) { $problems += "$label needs a DayOfWeek (e.g. Monday)." }
                if (@(1, 2, 3, 4, -1) -notcontains [int]$h.Nth) { $problems += "$label needs Nth set to 1, 2, 3, 4, or -1." }
            }
            else { $problems += "$label needs Type set to Fixed or Nth." }
        }
    }
    return $problems
}

# ============================================================
# 3CX API
# ============================================================
function Write-DebugLog([string]$Message) {
    # Appends a timestamped line to the debug log when $DebugMode is "on"
    if ("$DebugMode" -ne 'on') { return }
    $line = "{0:yyyy-MM-dd HH:mm:ss.fff}  {1}" -f (Get-Date), $Message
    try { Add-Content -Path $DebugLogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

function Format-DebugText($Object, [int]$MaxLength = 4000) {
    # Compact JSON for the log, truncated so large responses don't flood it
    if ($null -eq $Object) { return "(none)" }
    $text = if ($Object -is [string]) { $Object } else { ConvertTo-Json -InputObject $Object -Depth 10 -Compress }
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) + "... [truncated, $($text.Length) characters total]" }
    return $text
}

function Get-ErrorDetail($ErrorRecord) {
    $status = 0
    if ($ErrorRecord.Exception.Response) { $status = [int]$ErrorRecord.Exception.Response.StatusCode }
    $detail = if ($ErrorRecord.ErrorDetails.Message) { $ErrorRecord.ErrorDetails.Message } else { $ErrorRecord.Exception.Message }
    if ($status) { "HTTP $status - $detail" } else { $detail }
}

function Get-3CXCredentials {
    # Reads the 3CX client ID and secret from Azure Key Vault (signs in to Azure if needed)
    foreach ($m in 'Az.Accounts', 'Az.KeyVault') {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Write-Host "Required PowerShell module '$m' is not installed." -ForegroundColor Red
            Write-Host "Install it with: Install-Module $m -Scope CurrentUser" -ForegroundColor Yellow
            return $false
        }
    }

    $connect = @{ ErrorAction = 'Stop' }
    if ($TenantId) { $connect.TenantId = $TenantId }

    $read = {
        Write-DebugLog "Key Vault: reading secrets '$ClientIdSecretName' and '$ClientSecretSecretName' from vault '$KeyVaultName' (values not logged)"
        $script:ClientId     = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $ClientIdSecretName -AsPlainText -ErrorAction Stop
        $script:ClientSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $ClientSecretSecretName -AsPlainText -ErrorAction Stop
        Write-DebugLog "  Key Vault: secrets retrieved"
    }

    try {
        Import-Module Az.Accounts, Az.KeyVault -ErrorAction Stop
        if (-not (Get-AzContext)) {
            Write-Host "Sign in with your work account to retrieve the 3CX API credentials..." -ForegroundColor Cyan
            Write-DebugLog "Azure: no saved sign-in, calling Connect-AzAccount (tenant: $(Format-SettingValue $TenantId))"
            Connect-AzAccount @connect | Out-Null
        }
        try {
            & $read
        }
        catch {
            # Saved sign-in may be expired or for a different account; sign in again and retry once
            Write-DebugLog "  Key Vault: FAILED - $(Get-ErrorDetail $_). Signing in again and retrying."
            Write-Host "Sign in with your work account to retrieve the 3CX API credentials..." -ForegroundColor Cyan
            Connect-AzAccount @connect | Out-Null
            & $read
        }
        if (-not $script:ClientId -or -not $script:ClientSecret) { throw "One or both secrets are empty." }
        return $true
    }
    catch {
        Write-DebugLog "  Key Vault: FAILED - $(Get-ErrorDetail $_)"
        Write-Host "Could not retrieve 3CX credentials from Key Vault '$KeyVaultName': $($_.Exception.Message)" -ForegroundColor Red
        $script:ClientId     = $null
        $script:ClientSecret = $null
        return $false
    }
}

function Connect-3CX {
    # Reads the API credentials from Key Vault, requests a 3CX access token, then clears the
    # credentials from memory. Only the token is kept; it is renewed the same way when it expires.
    if (-not (Get-3CXCredentials)) { return $false }

    Write-DebugLog "POST $PbxUrl/connect/token (client_id: $script:ClientId, client secret not logged)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Method Post -Uri "$PbxUrl/connect/token" `
            -ContentType "application/x-www-form-urlencoded" `
            -Body @{ client_id = $script:ClientId; client_secret = $script:ClientSecret; grant_type = "client_credentials" }
        $script:AccessToken  = $response.access_token
        $script:TokenExpires = (Get-Date).AddSeconds($response.expires_in - 60)
        Write-DebugLog "  Success ($($sw.ElapsedMilliseconds) ms) - token expires in $($response.expires_in) seconds (token not logged)"
        return $true
    }
    catch {
        Write-DebugLog "  FAILED ($($sw.ElapsedMilliseconds) ms): $(Get-ErrorDetail $_)"
        Write-Host "Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    finally {
        $script:ClientId     = $null
        $script:ClientSecret = $null
        Write-DebugLog "  API credentials cleared from memory"
    }
}

function Invoke-3CXApi {
    param([string]$Method = "Get", [string]$Path, $Body)

    $uri = "$PbxUrl/xapi/v1/$Path"
    if ($Test -and $Method -ne 'Get') {
        Write-Host "  [TEST] $($Method.ToUpper()) /xapi/v1/$Path (not sent)" -ForegroundColor DarkGray
        if ($Body) { Write-Host ($Body | ConvertTo-Json -Depth 10) -ForegroundColor DarkGray }
        Write-DebugLog "$($Method.ToUpper()) $uri [TEST MODE - not sent]"
        if ($Body) { Write-DebugLog "  Request body: $(Format-DebugText $Body)" }
        return
    }

    $params = @{ Method = $Method; Uri = $uri }
    if ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = "application/json"
    }

    # Up to two attempts: if 3CX rejects the token (401), get a new one and retry once
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        # Renew the token if there isn't one or it's within a minute of expiring
        if (-not $script:AccessToken -or (Get-Date) -ge $script:TokenExpires) {
            if ($script:AccessToken) { Write-DebugLog "Access token expired; requesting a new one" }
            if (-not (Connect-3CX)) { throw "Unable to authenticate to 3CX." }
        }
        $params.Headers = @{ Authorization = "Bearer $script:AccessToken" }

        Write-DebugLog "$($Method.ToUpper()) $uri"
        if ($Body) { Write-DebugLog "  Request body: $(Format-DebugText $Body)" }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $result = Invoke-RestMethod @params
            Write-DebugLog "  Success ($($sw.ElapsedMilliseconds) ms)"
            if ($null -ne $result) { Write-DebugLog "  Response: $(Format-DebugText $result)" }
            return $result
        }
        catch {
            Write-DebugLog "  FAILED ($($sw.ElapsedMilliseconds) ms): $(Get-ErrorDetail $_)"
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 401 -and $attempt -eq 1) {
                Write-DebugLog "  Token was rejected; requesting a new token and retrying"
                $script:AccessToken = $null
                continue
            }
            throw
        }
    }
}

# ============================================================
# Data retrieval
# ============================================================
function Get-Departments {
    if ($UseMockData) {
        $groups = @(
            @{ Id = 28; Name = "DEFAULT";       Number = "GRP0000"; OfficeHolidays = @() }
            @{ Id = 35; Name = "Front Office";  Number = "GRP0001"; OfficeHolidays = @(@{ Id = 1; Name = "Weather Closure"; Day = 15; Month = 1;  Year = 2026 }) }
            @{ Id = 36; Name = "Sales";         Number = "GRP0002"; OfficeHolidays = @(@{ Id = 2; Name = "Weather Closure"; Day = 20; Month = 12; Year = 2026 }) }
            @{ Id = 37; Name = "Support";       Number = "GRP0003"; OfficeHolidays = @() }
        )
    }
    else {
        $groups = (Invoke-3CXApi -Path 'Groups?$select=Id,Name,Number&$expand=OfficeHolidays($select=Id,Name,Day,Month,Year)').value
    }

    $groups | ForEach-Object {
        [PSCustomObject]@{
            Id       = $_.Id
            Name     = $_.Name
            Number   = $_.Number
            Holidays = @($_.OfficeHolidays | Where-Object { $_ } | ForEach-Object { [PSCustomObject]$_ })
        }
    }
}

function Get-CustomPrompts {
    if ($UseMockData) {
        return @(
            [PSCustomObject]@{ Filename = "Weather Closure.wav" }
            [PSCustomObject]@{ Filename = "Holiday Greeting.wav" }
            [PSCustomObject]@{ Filename = "Christmas Holiday Greeting.wav" }
        )
    }
    (Invoke-3CXApi -Path 'CustomPrompts?$select=Filename').value
}

# ============================================================
# Verification (skipped in test mode)
# ============================================================
function Confirm-HolidayCreated($Response, [hashtable]$Body) {
    # Returns a list of problems; empty list = verified
    if ($Test) { return @() }

    try {
        if ($Response.Id) {
            $actual = Invoke-3CXApi -Path "Holidays($($Response.Id))"
        }
        else {
            $n = $Body.Name  -replace "'", "''"
            $g = $Body.Group -replace "'", "''"
            $actual = (Invoke-3CXApi -Path "Holidays?`$filter=Name eq '$n' and Group eq '$g'").value | Select-Object -First 1
        }
    }
    catch {
        return @("not found ($($_.Exception.Message))")
    }
    if (-not $actual) { return @("not found") }

    $fields = 'Name', 'Group', 'Day', 'Month', 'Year', 'DayEnd', 'MonthEnd', 'YearEnd', 'IsRecurrent', 'HolidayPrompt', 'TimeOfStartDate', 'TimeOfEndDate'
    @($fields | Where-Object { "$($actual.$_)" -ne "$($Body[$_])" } | ForEach-Object { "$_ mismatch" })
}

function Confirm-HolidayDeleted($Id) {
    if ($Test) { return $true }
    try {
        Invoke-3CXApi -Path "Holidays($Id)" | Out-Null
        return $false   # still exists
    }
    catch {
        return ([int]$_.Exception.Response.StatusCode -eq 404)
    }
}

# ============================================================
# Input helpers
# ============================================================
function Test-Back($Value) { ($Value -is [string]) -and ($Value -eq $NavBack) }
function Test-Menu($Value) { ($Value -is [string]) -and ($Value -eq $NavMenu) }
function Test-Nav($Value)  { (Test-Back $Value) -or (Test-Menu $Value) }

function Write-NavOptions([switch]$AllowBack) {
    Write-Host ""
    if ($AllowBack) { Write-Host "B. Back" }
    Write-Host "M. $script:MenuName"
}

function Read-Input([string]$Prompt, [switch]$AllowBack, [switch]$NoHint) {
    # Returns $NavBack / $NavMenu for B / M, otherwise the trimmed text
    if (-not $NoHint) {
        $hint = if ($AllowBack) { " (B = Back, M = $script:MenuName)" } else { " (M = $script:MenuName)" }
        $Prompt = $Prompt + $hint
    }
    $text = "$(Read-Host $Prompt)".Trim()
    if ($text -match '^[Mm]$') { return $NavMenu }
    if ($AllowBack -and $text -match '^[Bb]$') { return $NavBack }
    return $text
}

function Read-NumberSelection([int]$Count, [string]$Prompt, [switch]$AllowBack) {
    while ($true) {
        $text = Read-Input $Prompt -AllowBack:$AllowBack -NoHint
        if (Test-Nav $text) { return $text }
        $entries = $text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $nums = foreach ($e in $entries) {
            $n = 0
            if ([int]::TryParse($e, [ref]$n) -and $n -ge 1 -and $n -le $Count) { $n } else { -1 }
        }
        if ($nums -and $nums -notcontains -1) { return @($nums | Sort-Object -Unique) }
        Write-Host "Invalid selection. Try again." -ForegroundColor Red
    }
}

function Read-ClosureDate([string]$Prompt = "Enter the closure date (MM/DD/YYYY)", [switch]$AllowBack) {
    while ($true) {
        $text = Read-Input $Prompt -AllowBack:$AllowBack
        if (Test-Nav $text) { return $text }
        $date = [datetime]::MinValue
        if ([datetime]::TryParseExact($text, 'MM/dd/yyyy',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
            if ($date -lt (Get-Date).Date) {
                Write-Host "Date cannot be in the past." -ForegroundColor Red
                continue
            }
            return $date
        }
        Write-Host "Invalid date. Use MM/DD/YYYY (e.g. 10/29/2026)." -ForegroundColor Red
    }
}

function Read-HolidayYears([switch]$AllowBack) {
    $thisYear = (Get-Date).Year
    while ($true) {
        $text = Read-Input "Enter year(s) (YYYY), separated by spaces or commas (e.g. 2026 2027, 2028)" -AllowBack:$AllowBack
        if (Test-Nav $text) { return $text }
        $entries = $text -split '[,\s]+' | Where-Object { $_ }
        $years = foreach ($e in $entries) {
            $y = 0
            if ([int]::TryParse($e, [ref]$y) -and $y -ge $thisYear -and $y -le $thisYear + 10) { $y } else { -1 }
        }
        if ($years -and $years -notcontains -1) { return @($years | Sort-Object -Unique) }
        Write-Host "Enter years from $thisYear to $($thisYear + 10)." -ForegroundColor Red
    }
}

function Read-YesNo([string]$Prompt, [switch]$AllowBack) {
    while ($true) {
        $text = Read-Input $Prompt -AllowBack:$AllowBack
        if (Test-Nav $text) { return $text }
        if ($text -match '^[Yy]') { return $true }
        if ($text -match '^[Nn]') { return $false }
        Write-Host "Enter Y or N." -ForegroundColor Red
    }
}

function Read-Time([string]$Prompt, [switch]$AllowBack) {
    [string[]]$formats = @('h\:mm', 'hh\:mm')
    while ($true) {
        $text = Read-Input $Prompt -AllowBack:$AllowBack
        if (Test-Nav $text) { return $text }
        $t = [timespan]::Zero
        if ([timespan]::TryParseExact($text, $formats,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$t) -and $t.TotalHours -lt 24) {
            return $t
        }
        Write-Host "Invalid time. Use 24-hour format HH:MM (e.g. 15:00)." -ForegroundColor Red
    }
}

function Read-NextAction {
    $answer = Read-Host "Press M for main menu or Q to quit [M]"
    return ($answer.Trim() -eq 'q')
}

# ============================================================
# Shared helpers
# ============================================================
function Format-Action([string]$Done, [string]$Planned) {
    if ($Test) { "Would $Planned" } else { $Done }
}

function Select-Departments([object[]]$Departments, [switch]$AllowBack) {
    # Uses the supplied list if given, otherwise all non-excluded departments
    if (-not $Departments) {
        try {
            $Departments = @(Get-Departments | Where-Object { $ExcludedDepartments -notcontains $_.Name })
        }
        catch {
            Write-Host "Could not retrieve departments: $($_.Exception.Message)" -ForegroundColor Red
            return $null
        }
    }
    $departments = @($Departments | Sort-Object Name)

    if (-not $departments) {
        Write-Host "No departments available." -ForegroundColor Red
        return $null
    }

    Write-Host ""
    Write-Host "Select department(s):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $departments.Count; $i++) {
        Write-Host "$($i + 1). $($departments[$i].Name)"
    }
    # "Select All" is only offered when there is more than one department
    $maxNum = $departments.Count
    $selectAllNum = 0
    if ($departments.Count -gt 1) {
        $selectAllNum = $departments.Count + 1
        $maxNum = $selectAllNum
        Write-Host "$selectAllNum. Select All"
    }
    Write-NavOptions -AllowBack:$AllowBack

    $picked = Read-NumberSelection -Count $maxNum -Prompt "Enter number(s), separated by commas (e.g. 1,3)" -AllowBack:$AllowBack
    if (Test-Nav $picked) { return $picked }
    if ($selectAllNum -and $picked -contains $selectAllNum) { return $departments }
    return @($picked | ForEach-Object { $departments[$_ - 1] })
}

function Get-HolidayDate($Holiday) {
    if (-not $Holiday.Year) { return $null }   # Year 0 = recurring
    return [datetime]::new([int]$Holiday.Year, [int]$Holiday.Month, [int]$Holiday.Day)
}

function Get-RemovableClosures($Department, [datetime]$Today) {
    # Current/future (non-recurring) Weather Closures on a department
    @($Department.Holidays | Where-Object {
        $d = Get-HolidayDate $_
        $_.Name -like "*$WeatherHolidayName*" -and $d -and $d -ge $Today
    })
}

function Get-NthWeekday([int]$Year, [int]$Month, [DayOfWeek]$DayOfWeek, [int]$Nth) {
    if ($Nth -gt 0) {
        $d = [datetime]::new($Year, $Month, 1)
        while ($d.DayOfWeek -ne $DayOfWeek) { $d = $d.AddDays(1) }
        return $d.AddDays(7 * ($Nth - 1))
    }
    $d = [datetime]::new($Year, $Month, 1).AddMonths(1).AddDays(-1)   # last day of month
    while ($d.DayOfWeek -ne $DayOfWeek) { $d = $d.AddDays(-1) }
    return $d
}

function Get-HolidayEvent($Holiday, [int]$Year) {
    # Returns $null for February 29 in a non-leap year
    if ($Holiday.Type -eq 'Fixed' -and [int]$Holiday.Month -eq 2 -and [int]$Holiday.Day -eq 29 -and -not [datetime]::IsLeapYear($Year)) {
        return $null
    }
    $date = if ($Holiday.Type -eq 'Fixed') {
        [datetime]::new($Year, $Holiday.Month, $Holiday.Day)
    }
    else {
        Get-NthWeekday -Year $Year -Month $Holiday.Month -DayOfWeek $Holiday.DayOfWeek -Nth $Holiday.Nth
    }

    $name = $Holiday.Name
    $move = switch ($date.DayOfWeek) {
        'Saturday' { $SaturdayHolidayMoveTo }
        'Sunday'   { $SundayHolidayMoveTo }
        default    { 'DontMove' }
    }
    switch ($move) {
        'FridayBefore' {
            $date = $date.AddDays(-(([int]$date.DayOfWeek - 5 + 7) % 7))   # Sat -1, Sun -2
            $name += " ($ObservedLabel)"
        }
        'MondayAfter' {
            $date = $date.AddDays((1 - [int]$date.DayOfWeek + 7) % 7)      # Sat +2, Sun +1
            $name += " ($ObservedLabel)"
        }
    }
    [PSCustomObject]@{ Name = $name; Date = $date }
}

function New-HolidayBody($Name, [datetime]$Date, $GroupNumber, $Prompt, $Start = $null, $End = $null) {
    # Matches the format 3CX stores (e.g. PT9H, PT17H30M); all day = PT0S to P1D
    $startText = if ($null -ne $Start) { [System.Xml.XmlConvert]::ToString([timespan]$Start) } else { "PT0S" }
    $endText   = if ($null -ne $End)   { [System.Xml.XmlConvert]::ToString([timespan]$End) }   else { "P1D" }
    @{
        Id              = 0
        Name            = $Name
        Group           = $GroupNumber
        Day             = $Date.Day;  Month    = $Date.Month;  Year    = $Date.Year
        DayEnd          = $Date.Day;  MonthEnd = $Date.Month;  YearEnd = $Date.Year
        TimeOfStartDate = $startText
        TimeOfEndDate   = $endText
        IsRecurrent     = $false
        HolidayPrompt   = $Prompt
    }
}

function Resolve-HolidayPrompt([switch]$AllowBack) {
    try {
        $prompts = @(Get-CustomPrompts)
    }
    catch {
        Write-Host "Could not retrieve prompts: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    if ($prompts.Filename -contains $HolidayGreeting) { return $HolidayGreeting }

    Write-Host ""
    Write-Host "Prompt '$HolidayGreeting' was not found." -ForegroundColor Yellow
    $options = @($prompts.Filename | Where-Object { $_ -like "*Holiday*" } | Sort-Object)
    if (-not $options) {
        Write-Host "No prompts containing 'Holiday' were found." -ForegroundColor Red
        return $null
    }

    Write-Host "Select a prompt to use:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $options.Count; $i++) { Write-Host "$($i + 1). $($options[$i])" }
    Write-NavOptions -AllowBack:$AllowBack
    while ($true) {
        $text = Read-Input "Enter a number (1-$($options.Count))" -AllowBack:$AllowBack -NoHint
        if (Test-Nav $text) { return $text }
        $n = 0
        if ([int]::TryParse($text, [ref]$n) -and $n -ge 1 -and $n -le $options.Count) { return $options[$n - 1] }
        Write-Host "Invalid selection. Try again." -ForegroundColor Red
    }
}

function Show-ClosureSummary($Items, [string]$Action = "added", [string]$Label = "Weather Closures") {
    Write-Host ""
    if ($Test) {
        Write-Host "=== Summary (TEST MODE - no changes made) ===" -ForegroundColor Yellow
        $phrase = "would have been $Action"
    }
    else {
        Write-Host "=== Summary ===" -ForegroundColor Cyan
        $phrase = "were $Action"
    }
    if (-not $Items) {
        Write-Host "No $Label $phrase." -ForegroundColor Yellow
        return
    }
    Write-Host "$Label $($phrase):"
    Write-Host ($Items | Format-Table Department, Holiday, Date -AutoSize | Out-String -Width 200).TrimEnd()
    Write-Host ""
}

# ============================================================
# Menu actions (return $true to quit, $false for main menu)
# ============================================================
function Add-WeatherClosure {
    # Step 1: departments (M) -> Step 2: date (B/M)
    $step = 1
    while ($step -le 2) {
        if ($step -eq 1) {
            $r = Select-Departments
            if (Test-Menu $r) { return $false }
            if (-not $r) { Pause; return $false }
            $selectedDepartments = $r
            $step = 2
        }
        else {
            $r = Read-ClosureDate -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 1; continue }
            $closureDate = $r
            $step = 3
        }
    }

    $today = (Get-Date).Date
    $added = @()

    foreach ($dept in $selectedDepartments) {
        Write-Host ""
        Write-Host "$($dept.Name):" -ForegroundColor Cyan
        $holidayName = $WeatherHolidayName

        try {
            $existing = $dept.Holidays | Where-Object { $_.Name -eq $WeatherHolidayName } | Select-Object -First 1

            if ($existing) {
                $existingDate = Get-HolidayDate $existing

                if ($existingDate -and ($existingDate -lt $today -or $existingDate -eq $closureDate)) {
                    Write-Host "  $(Format-Action 'Removing' 'remove') existing '$WeatherHolidayName' ($($existingDate.ToString('MM/dd/yyyy')))"
                    Invoke-3CXApi -Method Delete -Path "Holidays($($existing.Id))" | Out-Null
                    if (-not (Confirm-HolidayDeleted $existing.Id)) {
                        throw "Existing '$WeatherHolidayName' could not be verified as removed. New holiday not added."
                    }
                }
                else {
                    $holidayName = "$WeatherHolidayName - $($closureDate.ToString('MM-dd-yyyy'))"
                    if ($dept.Holidays.Name -contains $holidayName) {
                        Write-Host "  '$holidayName' already exists. Skipped." -ForegroundColor Yellow
                        continue
                    }
                }
            }

            $body = New-HolidayBody -Name $holidayName -Date $closureDate -GroupNumber $dept.Number -Prompt $WeatherGreeting
            $response = Invoke-3CXApi -Method Post -Path "Holidays" -Body $body
            $problems = Confirm-HolidayCreated $response $body
            if ($problems) { throw "Verification failed: $($problems -join ', ')" }

            Write-Host "  $(Format-Action 'Added' 'add') '$holidayName'" -ForegroundColor Green
            $added += [PSCustomObject]@{
                Department = $dept.Name
                Holiday    = $holidayName
                Date       = $closureDate.ToString('MM/dd/yyyy')
            }
        }
        catch {
            Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Show-ClosureSummary $added
    return (Read-NextAction)
}

function Remove-WeatherClosure {
    $today = (Get-Date).Date
    try {
        $withClosures = @(Get-Departments |
            Where-Object { $ExcludedDepartments -notcontains $_.Name } |
            Where-Object { @(Get-RemovableClosures $_ $today).Count -gt 0 })
    }
    catch {
        Write-Host "Could not retrieve departments: $($_.Exception.Message)" -ForegroundColor Red
        return (Read-NextAction)
    }

    if (-not $withClosures) {
        Write-Host ""
        Write-Host "No departments currently have a Weather Closure." -ForegroundColor Yellow
        return (Read-NextAction)
    }

    # Step 1: departments (M) -> Step 2: closures (B/M) -> Step 3: confirm (B/M)
    $step = 1
    while ($step -le 3) {
        if ($step -eq 1) {
            $r = Select-Departments -Departments $withClosures
            if (Test-Menu $r) { return $false }
            if (-not $r) { Pause; return $false }
            $selectedDepartments = $r

            $closures = @(foreach ($dept in $selectedDepartments) {
                foreach ($h in @(Get-RemovableClosures $dept $today)) {
                    [PSCustomObject]@{ Department = $dept.Name; Id = $h.Id; Holiday = $h.Name; Date = Get-HolidayDate $h }
                }
            })
            $names = @($closures.Holiday | Sort-Object -Unique)
            $step = 2
        }
        elseif ($step -eq 2) {
            Write-Host ""
            Write-Host "Select Weather Closure(s) to remove:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $names.Count; $i++) { Write-Host "$($i + 1). $($names[$i])" }
            Write-NavOptions -AllowBack

            $r = Read-NumberSelection -Count $names.Count -Prompt "Enter number(s), separated by commas (e.g. 1,3)" -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 1; continue }
            $chosenNames = @($r | ForEach-Object { $names[$_ - 1] })
            $toRemove    = @($closures | Where-Object { $chosenNames -contains $_.Holiday })
            $step = 3
        }
        else {
            Write-Host ""
            Write-Host "The following will be removed:" -ForegroundColor Yellow
            $toRemove | ForEach-Object { Write-Host "  $($_.Department): $($_.Holiday)" }

            $r = Read-YesNo "Continue? (Y/N)" -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 2; continue }
            if (-not $r) {
                Write-Host "Cancelled."
                return (Read-NextAction)
            }
            $step = 4
        }
    }

    $removed = @()
    foreach ($item in $toRemove) {
        try {
            Invoke-3CXApi -Method Delete -Path "Holidays($($item.Id))" | Out-Null
            if (-not (Confirm-HolidayDeleted $item.Id)) { throw "Holiday still exists after delete." }

            Write-Host "  $(Format-Action 'Removed' 'remove') '$($item.Holiday)' from $($item.Department)" -ForegroundColor Green
            $removed += [PSCustomObject]@{
                Department = $item.Department
                Holiday    = $item.Holiday
                Date       = $item.Date.ToString('MM/dd/yyyy')
            }
        }
        catch {
            Write-Host "  Failed to remove '$($item.Holiday)' from $($item.Department): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Show-ClosureSummary $removed -Action "removed"
    return (Read-NextAction)
}

function Add-Holiday {
    if (-not @($HolidayList).Count) {
        Write-Host "The holiday list is empty. Add holidays with Manage Holiday List." -ForegroundColor Yellow
        return (Read-NextAction)
    }

    # Step 1: holidays (M) -> 2: departments (B/M) -> 3: years (B/M) -> 4: prompt (B/M)
    $step = 1
    while ($step -le 4) {
        if ($step -eq 1) {
            Write-Host ""
            Write-Host "Select holiday(s):" -ForegroundColor Cyan
            for ($i = 0; $i -lt $HolidayList.Count; $i++) { Write-Host "$($i + 1). $($HolidayList[$i].Name)" }
            Write-NavOptions

            $r = Read-NumberSelection -Count $HolidayList.Count -Prompt "Enter number(s), separated by commas (e.g. 1,3)"
            if (Test-Menu $r) { return $false }
            $holidays = @($r | ForEach-Object { $HolidayList[$_ - 1] })
            $step = 2
        }
        elseif ($step -eq 2) {
            $r = Select-Departments -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 1; continue }
            if (-not $r) { Pause; return $false }
            $selectedDepartments = $r
            $step = 3
        }
        elseif ($step -eq 3) {
            $r = Read-HolidayYears -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 2; continue }
            $years = $r
            $step = 4
        }
        else {
            $today = (Get-Date).Date

            # Build events: "<Name>[ (Observed)] <Year>"
            $events = @(foreach ($year in $years) {
                foreach ($h in $holidays) {
                    $e = Get-HolidayEvent $h $year
                    if (-not $e) {
                        Write-Host "Skipping '$($h.Name)' - February 29 doesn't occur in $year." -ForegroundColor Yellow
                        continue
                    }
                    [PSCustomObject]@{ Name = "$($e.Name) $year"; Date = $e.Date }
                }
            })

            # Skip dates already past
            $events | Where-Object { $_.Date -lt $today } | ForEach-Object {
                Write-Host "Skipping '$($_.Name)' - $($_.Date.ToString('MM/dd/yyyy')) is in the past." -ForegroundColor Yellow
            }
            $events = @($events | Where-Object { $_.Date -ge $today } | Sort-Object Date)
            if (-not $events) {
                Write-Host "No holidays to add." -ForegroundColor Yellow
                return (Read-NextAction)
            }

            $r = Resolve-HolidayPrompt -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 3; continue }
            if (-not $r) { return (Read-NextAction) }
            $prompt = $r
            $step = 5
        }
    }

    $added = @()
    foreach ($dept in $selectedDepartments) {
        Write-Host ""
        Write-Host "$($dept.Name):" -ForegroundColor Cyan
        foreach ($e in $events) {
            if ($dept.Holidays.Name -contains $e.Name) {
                Write-Host "  '$($e.Name)' already exists. Skipped." -ForegroundColor Yellow
                continue
            }
            try {
                $body = New-HolidayBody -Name $e.Name -Date $e.Date -GroupNumber $dept.Number -Prompt $prompt
                $response = Invoke-3CXApi -Method Post -Path "Holidays" -Body $body
                $problems = Confirm-HolidayCreated $response $body
                if ($problems) { throw "Verification failed: $($problems -join ', ')" }

                Write-Host "  $(Format-Action 'Added' 'add') '$($e.Name)' ($($e.Date.ToString('MM/dd/yyyy')))" -ForegroundColor Green
                $added += [PSCustomObject]@{ Department = $dept.Name; Holiday = $e.Name; Date = $e.Date.ToString('MM/dd/yyyy') }
            }
            catch {
                Write-Host "  Failed to add '$($e.Name)': $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    Show-ClosureSummary $added -Label "Holidays"
    return (Read-NextAction)
}

function Add-SpecialEvent {
    # Step 1: name (M) -> 2: departments -> 3: date -> 4: all day? -> 5: start -> 6: end -> 7: prompt (all B/M)
    $step = 1
    while ($step -le 7) {
        if ($step -eq 1) {
            $r = Read-Input "Enter the event name"
            if (Test-Menu $r) { return $false }
            if (-not $r) { continue }
            $eventName = $r
            $step = 2
        }
        elseif ($step -eq 2) {
            $r = Select-Departments -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 1; continue }
            if (-not $r) { Pause; return $false }
            $selectedDepartments = $r
            $step = 3
        }
        elseif ($step -eq 3) {
            $r = Read-ClosureDate -Prompt "Enter the event date (MM/DD/YYYY)" -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 2; continue }
            $date = $r
            $step = 4
        }
        elseif ($step -eq 4) {
            $r = Read-YesNo "Is this an all day event? (Y/N)" -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 3; continue }
            $allDay = $r
            if ($allDay) { $start = $null; $end = $null; $step = 7 } else { $step = 5 }
        }
        elseif ($step -eq 5) {
            $r = Read-Time "Enter the start time (24-hour, e.g. 15:00 for 3:00 PM)" -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 4; continue }
            $start = $r
            $step = 6
        }
        elseif ($step -eq 6) {
            $r = Read-Time "Enter the end time (24-hour, e.g. 17:30 for 5:30 PM)" -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = 5; continue }
            if ($r -le $start) {
                Write-Host "End time must be after the start time." -ForegroundColor Red
                continue
            }
            $end = $r
            $step = 7
        }
        else {
            $r = Resolve-HolidayPrompt -AllowBack
            if (Test-Menu $r) { return $false }
            if (Test-Back $r) { $step = $(if ($allDay) { 4 } else { 6 }); continue }
            if (-not $r) { return (Read-NextAction) }
            $prompt = $r
            $step = 8
        }
    }

    $fullName = "$eventName $($date.Year)"
    $timeText = if ($allDay) { "All day" } else { "$($start.ToString('hh\:mm'))-$($end.ToString('hh\:mm'))" }

    $added = @()
    foreach ($dept in $selectedDepartments) {
        Write-Host ""
        Write-Host "$($dept.Name):" -ForegroundColor Cyan
        if ($dept.Holidays.Name -contains $fullName) {
            Write-Host "  '$fullName' already exists. Skipped." -ForegroundColor Yellow
            continue
        }
        try {
            $body = New-HolidayBody -Name $fullName -Date $date -GroupNumber $dept.Number -Prompt $prompt -Start $start -End $end
            $response = Invoke-3CXApi -Method Post -Path "Holidays" -Body $body
            $problems = Confirm-HolidayCreated $response $body
            if ($problems) { throw "Verification failed: $($problems -join ', ')" }

            Write-Host "  $(Format-Action 'Added' 'add') '$fullName' ($($date.ToString('MM/dd/yyyy')) $timeText)" -ForegroundColor Green
            $added += [PSCustomObject]@{ Department = $dept.Name; Holiday = $fullName; Date = "$($date.ToString('MM/dd/yyyy')) $timeText" }
        }
        catch {
            Write-Host "  Failed to add '$fullName': $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Show-ClosureSummary $added -Label "Special Events"
    return (Read-NextAction)
}

# ============================================================
# Holiday list manager (edits the Holidays section of the settings file)
# ============================================================
$script:MonthNames   = @('January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December')
$script:WeekdayNames = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

function Get-Ordinal([int]$Nth) {
    switch ($Nth) { -1 { 'Last' } 1 { '1st' } 2 { '2nd' } 3 { '3rd' } default { "$($Nth)th" } }
}

function Get-HolidayRuleText($Holiday) {
    $month = $script:MonthNames[[int]$Holiday.Month - 1]
    if ($Holiday.Type -eq 'Fixed') { "$month $($Holiday.Day)" }
    else { "$(Get-Ordinal $Holiday.Nth) $($Holiday.DayOfWeek) of $month" }
}

function ConvertTo-HolidayRecord($Holiday) {
    $r = [ordered]@{ Name = "$($Holiday.Name)"; Type = "$($Holiday.Type)"; Month = [int]$Holiday.Month }
    if ($r.Type -eq 'Fixed') { $r.Day = [int]$Holiday.Day }
    else { $r.DayOfWeek = "$($Holiday.DayOfWeek)"; $r.Nth = [int]$Holiday.Nth }
    return $r
}

function ConvertTo-OrderedTree($Object) {
    # Converts ConvertFrom-Json output into ordered dictionaries so the file can be rewritten in the same order
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-OrderedTree $p.Value }
        return $h
    }
    if ($Object -is [array]) { return , @($Object | ForEach-Object { ConvertTo-OrderedTree $_ }) }
    return $Object
}

function Save-HolidayList($List) {
    # Rewrites only the Holidays section; notes and all other settings in the file are kept
    $path = ($SettingsDefinition | Where-Object { $_.Var -eq 'HolidayList' }).Path
    try {
        $tree = ConvertTo-OrderedTree (Get-Content -Path $SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        $records = @($List | ForEach-Object { ConvertTo-HolidayRecord $_ })
        Set-TreeValue $tree $path $records
        Set-Content -Path $SettingsFile -Value (ConvertTo-PrettyJson $tree) -Encoding UTF8 -ErrorAction Stop
        $script:HolidayList = $records
        Write-Host "Saved to $SettingsFile" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Could not save the holiday list: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Read-MenuChoice([string]$Title, [string[]]$Options) {
    # Numbered list with Back/Main Menu; returns the 1-based choice, $NavBack, or $NavMenu
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host "$($i + 1). $($Options[$i])" }
    Write-NavOptions -AllowBack
    while ($true) {
        $text = Read-Input "Select an option" -AllowBack -NoHint
        if (Test-Nav $text) { return $text }
        $n = 0
        if ([int]::TryParse($text, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n }
        Write-Host "Invalid selection. Try again." -ForegroundColor Red
    }
}

function Read-HolidayName($List, [string]$Current) {
    while ($true) {
        $prompt = if ($Current) { "Enter the new name for '$Current'" } else { "Enter the holiday name" }
        $name = Read-Input $prompt -AllowBack
        if (Test-Nav $name) { return $name }
        if (-not $name) { Write-Host "A name is required." -ForegroundColor Red; continue }
        $taken = @($List | Where-Object { $_.Name -ne $Current } | ForEach-Object { $_.Name }) -contains $name
        if ($taken) { Write-Host "A holiday named '$name' already exists." -ForegroundColor Red; continue }
        return $name
    }
}

function Read-HolidayRule([string]$HolidayName) {
    # Step-by-step date rule entry. Returns the rule fields, $NavBack (from the first step), or $NavMenu.
    $step = 1
    while ($true) {
        switch ($step) {
            1 {
                $r = Read-MenuChoice "How is the date for '$HolidayName' set?" @('Same date every year (e.g. July 4)', 'Nth weekday of a month (e.g. 4th Thursday of November)')
                if (Test-Nav $r) { return $r }
                $type = if ($r -eq 1) { 'Fixed' } else { 'Nth' }
                $step = 2
            }
            2 {
                $r = Read-MenuChoice "Month" $script:MonthNames
                if (Test-Menu $r) { return $r }
                if (Test-Back $r) { $step = 1 } else { $month = $r; $step = 3 }
            }
            3 {
                if ($type -eq 'Fixed') {
                    $max = [datetime]::DaysInMonth(2024, $month)   # leap year, so Feb 29 is allowed
                    $r = Read-Input "Enter the day of the month (1-$max)" -AllowBack
                    if (Test-Menu $r) { return $r }
                    if (Test-Back $r) { $step = 2 }
                    else {
                        $d = 0
                        if ([int]::TryParse($r, [ref]$d) -and $d -ge 1 -and $d -le $max) {
                            return [ordered]@{ Type = 'Fixed'; Month = $month; Day = $d }
                        }
                        Write-Host "Enter a day from 1 to $max." -ForegroundColor Red
                    }
                }
                else {
                    $r = Read-MenuChoice "Weekday" $script:WeekdayNames
                    if (Test-Menu $r) { return $r }
                    if (Test-Back $r) { $step = 2 } else { $weekday = $script:WeekdayNames[$r - 1]; $step = 4 }
                }
            }
            4 {
                $r = Read-MenuChoice "Which $weekday of $($script:MonthNames[$month - 1])?" @('1st', '2nd', '3rd', '4th', 'Last')
                if (Test-Menu $r) { return $r }
                if (Test-Back $r) { $step = 3 }
                else {
                    $nth = if ($r -eq 5) { -1 } else { $r }
                    return [ordered]@{ Type = 'Nth'; Month = $month; DayOfWeek = $weekday; Nth = $nth }
                }
            }
        }
    }
}

function New-HolidayFromRule([string]$Name, $Rule) {
    $h = [ordered]@{ Name = $Name }
    foreach ($k in $Rule.Keys) { $h[$k] = $Rule[$k] }
    return $h
}

function Add-HolidayToList($List) {
    # Returns $NavMenu, or $null to go back to the holiday list
    $step = 1
    while ($true) {
        if ($step -eq 1) {
            $name = Read-HolidayName -List $List
            if (Test-Menu $name) { return $NavMenu }
            if (Test-Back $name) { return $null }
            $step = 2
        }
        else {
            $rule = Read-HolidayRule $name
            if (Test-Menu $rule) { return $NavMenu }
            if (Test-Back $rule) { $step = 1; continue }

            $h = New-HolidayFromRule $name $rule
            $c = Read-YesNo "Add '$name' ($(Get-HolidayRuleText $h))? (Y/N)" -AllowBack
            if (Test-Menu $c) { return $NavMenu }
            if (Test-Back $c) { continue }
            if ($c) { [void]$List.Add($h); Save-HolidayList $List | Out-Null }
            else { Write-Host "No change made." }
            return $null
        }
    }
}

function Edit-HolidayInList($List, [int]$Index) {
    # Returns $NavMenu, or $null to go back to the holiday list
    while ($true) {
        $h = $List[$Index]
        Write-Host ""
        Write-Host "$($h.Name):" -ForegroundColor Cyan
        Write-Host "1. Name ($($h.Name))"
        Write-Host "2. Date ($(Get-HolidayRuleText $h))"
        Write-Host ""
        Write-Host "R. Remove This Holiday"
        Write-Host "B. Back"
        Write-Host "M. Main Menu"

        $text = Read-Input "Select an option" -AllowBack -NoHint
        if (Test-Back $text) { return $null }
        if (Test-Menu $text) { return $NavMenu }

        if ($text -eq '1') {
            $new = Read-HolidayName -List $List -Current $h.Name
            if (Test-Menu $new) { return $NavMenu }
            if (Test-Back $new) { continue }
            $c = Read-YesNo "Rename '$($h.Name)' to '$new'? (Y/N)" -AllowBack
            if (Test-Menu $c) { return $NavMenu }
            if (Test-Back $c) { continue }
            if (-not $c) { Write-Host "No change made."; continue }
            $h.Name = $new
            if (-not (Save-HolidayList $List)) { return $null }
        }
        elseif ($text -eq '2') {
            $rule = Read-HolidayRule $h.Name
            if (Test-Menu $rule) { return $NavMenu }
            if (Test-Back $rule) { continue }
            $new = New-HolidayFromRule $h.Name $rule
            $c = Read-YesNo "Change '$($h.Name)' to $(Get-HolidayRuleText $new)? (Y/N)" -AllowBack
            if (Test-Menu $c) { return $NavMenu }
            if (Test-Back $c) { continue }
            if (-not $c) { Write-Host "No change made."; continue }
            $List[$Index] = $new
            if (-not (Save-HolidayList $List)) { return $null }
        }
        elseif ($text -match '^[Rr]$') {
            $c = Read-YesNo "Remove '$($h.Name)' from the holiday list? (Y/N)" -AllowBack
            if (Test-Menu $c) { return $NavMenu }
            if (Test-Back $c) { continue }
            if (-not $c) { Write-Host "No change made."; continue }
            $List.RemoveAt($Index)
            Save-HolidayList $List | Out-Null
            return $null
        }
        else {
            Write-Host "Invalid selection. Try again." -ForegroundColor Red
        }
    }
}

function Invoke-HolidayListManager {
    # Main menu option: view, add, edit, and remove holidays. Returns $false (back to main menu).
    while ($true) {
        $list = New-Object System.Collections.ArrayList
        foreach ($h in @($HolidayList)) { if ($h) { [void]$list.Add((ConvertTo-HolidayRecord $h)) } }

        Write-Host ""
        Write-Host "Holiday List:" -ForegroundColor Cyan
        if ($list.Count) {
            for ($i = 0; $i -lt $list.Count; $i++) { Write-Host "$($i + 1). $($list[$i].Name) ($(Get-HolidayRuleText $list[$i]))" }
        }
        else {
            Write-Host "(no holidays)" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "A. Add a Holiday"
        Write-Host "M. Main Menu"

        $text = Read-Input "Select a holiday to edit, or A to add" -NoHint
        if (Test-Menu $text) { return $false }

        $result = $null
        $n = 0
        if ($text -match '^[Aa]$') {
            $result = Add-HolidayToList $list
        }
        elseif ([int]::TryParse($text, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
            $result = Edit-HolidayInList $list ($n - 1)
        }
        else {
            Write-Host "Invalid selection. Try again." -ForegroundColor Red
        }
        if (Test-Menu $result) { return $false }
    }
}

# ============================================================
# Main menu
# ============================================================
function Show-MainMenu {
    Clear-Host
    Write-Host "=== Holiday Helper for 3CX ===" -ForegroundColor Cyan
    if ($Test) { Write-Host "*** TEST MODE - no changes will be made ***" -ForegroundColor Yellow }
    if ($DebugMode -eq 'on') { Write-Host "*** DEBUG LOGGING ON: $DebugLogFile ***" -ForegroundColor Yellow }
    Write-Host "1. Add a Weather Closure"
    Write-Host "2. View or Remove Weather Closures"
    Write-Host "3. Add a Holiday"
    Write-Host "4. Add a Special Event"
    Write-Host "5. Manage Holiday List"
    Write-Host "6. Exit"
    Write-Host ""
}

# ============================================================
# Startup
# ============================================================
if (-not (Test-Path $SettingsFile)) {
    if (New-SettingsFile) {
        Write-Host ""
        Write-Host "A new settings file was created:" -ForegroundColor Yellow
        Write-Host "  $SettingsFile" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Open it in a text editor, fill in your settings (instructions are at the top of the file),"
        Write-Host "save it, and then run this script again."
    }
    Pause
    exit 1
}

if (-not (Import-Settings)) { Pause; exit 1 }

$problems = @(Test-Settings)
if ($problems) {
    Write-Host ""
    Write-Host "Some settings in $SettingsFile need attention:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Update the file and run the script again. Instructions are at the top of the file."
    Pause
    exit 1
}

# Mock data must never be written to the real PBX
if ($UseMockData) { $Test = $true }

$DebugMode = "$DebugMode".Trim().ToLower()
Write-DebugLog "===== Session started: $([IO.Path]::GetFileName($PSCommandPath)) | Test mode: $([bool]$Test) | Mock data: $([bool]$UseMockData) | PowerShell $($PSVersionTable.PSVersion) ====="

# Connect to 3CX before showing the menu (credentials are read from Key Vault, used to get a token, then cleared)
if (-not $UseMockData) {
    Write-Host "Connecting to 3CX..." -ForegroundColor Cyan
    if (-not (Connect-3CX)) {
        Write-Host "The script cannot continue without connecting to 3CX." -ForegroundColor Red
        Pause
        exit 1
    }
}

do {
    Show-MainMenu
    $choice = Read-Host "Select an option (1-6)"

    switch ($choice) {
        '1' { if (Add-WeatherClosure)        { $choice = '6'; Write-Host "Exiting..." } }
        '2' { if (Remove-WeatherClosure)     { $choice = '6'; Write-Host "Exiting..." } }
        '3' { if (Add-Holiday)               { $choice = '6'; Write-Host "Exiting..." } }
        '4' { if (Add-SpecialEvent)          { $choice = '6'; Write-Host "Exiting..." } }
        '5' { if (Invoke-HolidayListManager) { $choice = '6'; Write-Host "Exiting..." } }
        '6' { Write-Host "Exiting..." }
        default { Write-Host "Invalid selection. Enter 1-6." -ForegroundColor Red; Pause }
    }
} while ($choice -ne '6')
