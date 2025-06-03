# Get the directory where the script is located.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Load settings from JSON file (in the same folder as the script)
$settingsFile = Join-Path $scriptDir "BrandsborgMCManagerSettings.json"
if (-Not (Test-Path $settingsFile)) {
    Write-Host "Settings file not found: $settingsFile" -ForegroundColor Red
    exit 1
}
try {
    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
} catch {
    Write-Host "Error reading settings file: ${_}" -ForegroundColor Red
    exit 1
}

# Directories and files
$uploadDir = Join-Path $scriptDir "Git"
if (-not (Test-Path $uploadDir)) {
    New-Item -Path $uploadDir -ItemType Directory | Out-Null
}
$logFile = Join-Path $scriptDir "Get-MCStats.log"
$outputFile = Join-Path $uploadDir "Get-MCStats.json"

# GitHub settings from the settings file.
$gitRepoOwner = $settings.gitRepoOwner
$gitRepoName  = $settings.gitRepoName
$gitUserToken = $settings.gitUserToken

# Minecraft server settings.
$rconHost     = $settings.minecraftServerHost
$rconPort     = $settings.minecraftRconPort
$rconPassword = $settings.minecraftRconPassword

# Determine world folder.
$serverFilesDirectory = $settings.minecraftDirectory
$worldFolder = Join-Path $serverFilesDirectory $settings.minecraftWorldFolder

# Logging function.
function Write-Log {
    param([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp - $message"
    Add-Content -Path $logFile -Value $logEntry
    Write-Host $logEntry
}
Write-Log "Script started."

# Convert ticks to in-game time (HH:mm).
function Convert-TicksToTime {
    param([int]$ticks)
    $adjustedTicks = ($ticks + 6000) % 24000
    $hours = [int]([math]::Floor($adjustedTicks / 1000))
    $minutes = [int]([math]::Floor((($adjustedTicks % 1000) / 1000.0) * 60))
    return "{0:D2}:{1:D2}" -f $hours, $minutes
}

# Calculate world folder size.
if (Test-Path $worldFolder) {
    $worldSizeBytes = (Get-ChildItem $worldFolder -Recurse -File | Measure-Object -Property Length -Sum).Sum
    $worldSizeGB = [math]::Round($worldSizeBytes / 1GB, 2)
    Write-Log "World folder size for '$worldFolder': $worldSizeGB GB."
} else {
    $worldSizeGB = "unknown"
    Write-Log "World folder not found at $worldFolder."
}

# Function to send an RCON command.
function Send-RconCommand {
    param(
        [string]$serverHost,
        [int]$serverPort,
        [string]$password,
        [string]$command
    )
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect($serverHost, $serverPort)
        $stream = $client.GetStream()
        Write-Log "Connected to RCON server at ${serverHost}:${serverPort}."

        function Send-RconPacket {
            param(
                [int]$requestId,
                [int]$packetType,
                [string]$payload
            )
            $payloadBytes = [System.Text.Encoding]::ASCII.GetBytes($payload)
            $packetData = New-Object System.Collections.Generic.List[Byte]
            $packetData.AddRange([System.BitConverter]::GetBytes($requestId))
            $packetData.AddRange([System.BitConverter]::GetBytes($packetType))
            $packetData.AddRange($payloadBytes)
            $packetData.Add(0)
            $packetData.Add(0)
            $packetBody = $packetData.ToArray()
            $packetLengthBytes = [System.BitConverter]::GetBytes($packetBody.Length)
            $packet = $packetLengthBytes + $packetBody
            $stream.Write($packet, 0, $packet.Length)
            $stream.Flush()
        }

        function Read-RconPacket {
            $lengthBytes = New-Object Byte[] 4
            $read = $stream.Read($lengthBytes, 0, 4)
            if ($read -ne 4) { return $null }
            $length = [System.BitConverter]::ToInt32($lengthBytes, 0)
            if ($length -le 0) { return $null }
            $packetBytes = New-Object Byte[] $length
            $offset = 0
            while ($offset -lt $length) {
                $read = $stream.Read($packetBytes, $offset, $length - $offset)
                if ($read -le 0) { break }
                $offset += $read
            }
            if ($offset -ne $length) { return $null }
            $requestId = [System.BitConverter]::ToInt32($packetBytes, 0)
            $packetType = [System.BitConverter]::ToInt32($packetBytes, 4)
            $payloadLength = $length - 8 - 2
            $payload = ""
            if ($payloadLength -gt 0) {
                $payload = [System.Text.Encoding]::ASCII.GetString($packetBytes, 8, $payloadLength)
            }
            return @{ RequestId = $requestId; Type = $packetType; Payload = $payload }
        }

        # Authenticate with RCON (packet type 3).
        $authRequestId = 1
        Send-RconPacket -requestId $authRequestId -packetType 3 -payload $password
        $authResponse = Read-RconPacket
        if ($authResponse.RequestId -eq -1) {
            throw "RCON authentication failed."
        }
        Write-Log "RCON authentication successful."

        # Send the command (packet type 2).
        $commandRequestId = 2
        Send-RconPacket -requestId $commandRequestId -packetType 2 -payload $command
        Write-Log "RCON command '$command' executed."

        $commandResponse = ""
        $packet = Read-RconPacket
        if ($packet -ne $null) {
            $commandResponse = $packet.Payload
        }
        while ($stream.DataAvailable) {
            $packet = Read-RconPacket
            if ($packet -ne $null) {
                $commandResponse += "`n" + $packet.Payload
            }
        }
        $client.Close()
        return $commandResponse
    }
    catch {
        Write-Log "Error during RCON communication: ${_}"
        throw $_
    }
}

# --- Retrieve daytime via RCON ---
try {
    $daytimeResponse = Send-RconCommand -serverHost $rconHost -serverPort $rconPort -password $rconPassword -command "time query daytime"
    Write-Log "RCON daytime response received: $daytimeResponse"
    $daytimeMatch = [regex]::Match($daytimeResponse, "\d+")
    if ($daytimeMatch.Success) {
        $daytimeTicks = [int]$daytimeMatch.Value
    }
    else {
        Write-Log "Unable to parse daytime from response: $daytimeResponse"
        $daytimeTicks = 0
    }
}
catch {
    Write-Log "Error retrieving daytime via RCON: ${_}"
    $daytimeTicks = 0
}

# --- Retrieve gametime via RCON ---
try {
    $gametimeResponse = Send-RconCommand -serverHost $rconHost -serverPort $rconPort -password $rconPassword -command "time query gametime"
    Write-Log "RCON gametime response received: $gametimeResponse"
    $gametimeMatch = [regex]::Match($gametimeResponse, "\d+")
    if ($gametimeMatch.Success) {
        $gametimeTicks = [int]$gametimeMatch.Value
    }
    else {
        Write-Log "Unable to parse gametime from response: $gametimeResponse"
        $gametimeTicks = 0
    }
}
catch {
    Write-Log "Error retrieving gametime via RCON: ${_}"
    $gametimeTicks = 0
}

$inGameDays = [math]::Floor($gametimeTicks / 24000)
$formattedTime = Convert-TicksToTime $daytimeTicks
Write-Log "In-game daytime: $daytimeTicks ticks ($formattedTime)."
Write-Log "Total gametime: $gametimeTicks ticks ($inGameDays in-game days)."

# --- Retrieve online players via RCON ---
try {
    $listResponse = Send-RconCommand -serverHost $rconHost -serverPort $rconPort -password $rconPassword -command "list"
    Write-Log "RCON list response received: $listResponse"
    if ($listResponse -match ":\s*(.*)$") {
        $playersPart = $Matches[1]
    }
    else {
        $playersPart = ""
    }
    if ($playersPart -ne "") {
        $onlinePlayers = $playersPart.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    }
    else {
        $onlinePlayers = @()
    }
}
catch {
    Write-Log "Error retrieving online players via RCON: ${_}"
    $onlinePlayers = @()
}
Write-Log "Online players: $(($onlinePlayers -join ', '))"

# --- Retrieve player stats from JSON files ---
# Now using the stats folder inside the world folder
$statsFolder = Join-Path $worldFolder "stats"
if (-Not (Test-Path $statsFolder)) {
    Write-Log "Stats folder not found at $statsFolder."
} else {
    Write-Log "Reading player stats from $statsFolder."
}
$ignoreFiles = @("BrandsborgMCManagerSettings", "Get-MCStats", "all_stats")
$playerStats = @()
Get-ChildItem -Path $statsFolder -Filter *.json | Where-Object { $ignoreFiles -notcontains $_.BaseName } | ForEach-Object {
    $filePath = $_.FullName
    $uuid = $_.BaseName
    try {
        $jsonData = Get-Content -Path $filePath -Raw | ConvertFrom-Json
        Write-Log "Successfully read JSON file: $filePath"
    } catch {
        Write-Log "Error reading file ${filePath}: ${_}"
        return
    }
    
    # Resolve player name from Mojang API.
    $resolvedName = $uuid
    try {
        $response = Invoke-RestMethod -Uri "https://sessionserver.mojang.com/session/minecraft/profile/$uuid" -UseBasicParsing -ErrorAction Stop
        if ($response -and $response.name) {
            $resolvedName = $response.name
            Write-Log "Resolved UUID ${uuid} to player name: ${resolvedName}"
        }
    } catch {
        Write-Log "Could not resolve UUID: ${uuid}"
    }
    
    # Add player name and uuid to the JSON object.
    $jsonData | Add-Member -MemberType NoteProperty -Name playerName -Value $resolvedName -Force
    $jsonData | Add-Member -MemberType NoteProperty -Name uuid -Value $uuid -Force

    # Include all statistics already in the JSON file.
    $playerStats += $jsonData
}

# --- Compile data and write output JSON ---
$finalObject = [PSCustomObject]@{
    inGameDays        = $inGameDays
    currentInGameTime = $formattedTime
    worldSizeGB       = $worldSizeGB
    onlinePlayers     = $onlinePlayers
    playerStats       = $playerStats
}

try {
    $jsonOutput = $finalObject | ConvertTo-Json -Depth 5
    $jsonOutput | Out-File -FilePath $outputFile -Encoding UTF8
    Write-Log "Output file created at $outputFile."
}
catch {
    Write-Log "Error writing output file: ${_}"
}

# --- Upload JSON file to GitHub via API ---
$repoPath = "repos/$gitRepoOwner/$gitRepoName/contents/Get-MCStats.json"
$uri = "https://api.github.com/$repoPath"
$commitMessage = "Update stats at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Read and encode file contents.
$fileContent = Get-Content $outputFile -Raw
$base64Content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fileContent))

# Prepare headers and body.
$headers = @{
    Authorization = "token $gitUserToken"
    "User-Agent"  = "$gitRepoOwner"
}
# Try to get existing file info (to obtain its SHA)
try {
    $existingFile = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    $sha = $existingFile.sha
} catch {
    $sha = $null
}
$body = @{
    message = $commitMessage
    content = $base64Content
}
if ($sha) { $body.sha = $sha }
$bodyJson = $body | ConvertTo-Json

try {
    $result = Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body $bodyJson -ContentType "application/json"
    Write-Log "JSON file uploaded to GitHub repository."
} catch {
    Write-Log "Error uploading JSON file to GitHub: ${_}"
}

# Return to the script directory.
Set-Location $scriptDir
Write-Log "Returned to script directory: $scriptDir."
Write-Log "Script finished."
