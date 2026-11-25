#Requires -Version 7.0
# Funzioni comuni agli script della PoC ado-aw (dot-source: . "$PSScriptRoot/PocCommon.ps1")
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$script:AdoResourceId = '499b84ac-1321-427f-aa17-267ca6975798'   # audience dei token Azure DevOps
$script:AdoApiVersion = '7.1'
$script:BuildPolicyTypeId = '0609b952-1397-4640-95ec-e00a01b2c241' # tipo "Build validation"
$script:ZeroSha = '0000000000000000000000000000000000000000'
$script:PipelineName = 'ado-aw Standards Compliance Review'
$script:StatePath = Join-Path (Split-Path $PSScriptRoot -Parent) '.poc-state.json'

function Write-Step([string]$Message) { Write-Host "`n▶ $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "  ✔ $Message" -ForegroundColor Green }
function Write-Note([string]$Message) { Write-Host "  · $Message" -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "  ⚠ $Message" -ForegroundColor Yellow }

# ---------------------------------------------------------------- Azure DevOps

function Get-AdoHeaders([string]$Pat) {
    if ($Pat) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        return @{ Authorization = "Basic $b64" }
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI non trovata. Installala (winget install Microsoft.AzureCLI) ed esegui 'az login', oppure passa -Pat."
    }
    $token = (az account get-access-token --resource $script:AdoResourceId --query accessToken -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "Token Azure DevOps non disponibile. Esegui 'az login' con un utente dell'organizzazione, oppure passa -Pat."
    }
    return @{ Authorization = "Bearer $($token.Trim())" }
}

function Invoke-Ado {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][hashtable]$Headers,
        $Body,
        [switch]$AllowNotFound,
        [switch]$Raw
    )
    $sep = if ($Url.Contains('?')) { '&' } else { '?' }
    $requestHeaders = $Headers
    if ($Raw) { $requestHeaders = @{} + $Headers; $requestHeaders['Accept'] = 'text/plain' }   # i log di build sono testo, non JSON
    $request = @{
        Method = $Method; Uri = "$Url${sep}api-version=$script:AdoApiVersion"; Headers = $requestHeaders
        SkipHttpErrorCheck = $true; ContentType = 'application/json; charset=utf-8'
    }
    if ($null -ne $Body) { $request.Body = (ConvertTo-Json -InputObject $Body -Depth 50 -Compress) }
    $response = Invoke-WebRequest @request
    $status = [int]$response.StatusCode
    $content = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }   # senza charset PowerShell restituisce byte[]
    if ($status -eq 404 -and $AllowNotFound) { return $null }
    if ($status -eq 203 -or (-not $Raw -and $content.TrimStart().StartsWith('<'))) {
        throw "Azure DevOps ha risposto con una pagina di login (HTTP $status): token non valido o senza accesso all'organizzazione."
    }
    if ($status -lt 200 -or $status -ge 300) {
        $message = $content
        try { $message = ($content | ConvertFrom-Json).message } catch { }
        $hint = switch ($status) {
            401 { ' (non autenticato: rifai az login o verifica il PAT)' }
            403 { ' (permessi insufficienti: serve Project Administrator o permessi equivalenti)' }
            default { '' }
        }
        throw "$Method $Url -> HTTP $status$hint`n$message"
    }
    if ($Raw) { return $content }
    if ([string]::IsNullOrWhiteSpace($content)) { return $null }
    return $content | ConvertFrom-Json -Depth 50
}

function ConvertTo-AdoPath([string]$RelativePath) {
    return '/' + ($RelativePath -replace '\\', '/').TrimStart('/')
}

function Get-ProjectBaseUrl([string]$OrganizationUrl, [string]$Project) {
    return "$($OrganizationUrl.TrimEnd('/'))/$([uri]::EscapeDataString($Project))"
}

function Get-AdoRepository($Context, [string]$Name, [string]$Project = $Context.Project) {
    $url = "$(Get-ProjectBaseUrl $Context.OrganizationUrl $Project)/_apis/git/repositories/$([uri]::EscapeDataString($Name))"
    return Invoke-Ado -Method GET -Url $url -Headers $Context.Headers -AllowNotFound
}

function Get-BranchHead($Context, [string]$RepoId, [string]$Branch = 'main') {
    $url = "$(Get-ProjectBaseUrl $Context.OrganizationUrl $Context.Project)/_apis/git/repositories/$RepoId/refs?filter=heads/$Branch"
    $refs = Invoke-Ado -Method GET -Url $url -Headers $Context.Headers
    $match = @($refs.value) | Where-Object { $_.name -eq "refs/heads/$Branch" } | Select-Object -First 1
    if ($match) { return [string]$match.objectId }
    return $null
}

function Get-RepoFiles($Context, [string]$RepoId, [string]$Branch = 'main', [switch]$WithContent) {
    # Mappa percorso -> contenuto dei file del ramo (vuota se il ramo non esiste).
    # L'elenco degli item di Azure DevOps non restituisce mai il contenuto: con -WithContent lo leggo file per file, altrimenti il valore è $null.
    $itemsUrl = "$(Get-ProjectBaseUrl $Context.OrganizationUrl $Context.Project)/_apis/git/repositories/$RepoId/items"
    $version = "versionDescriptor.version=$Branch&versionDescriptor.versionType=branch"
    $items = Invoke-Ado -Method GET -Url "${itemsUrl}?recursionLevel=Full&scopePath=/&$version" -Headers $Context.Headers -AllowNotFound
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($items) {
        foreach ($i in @($items.value)) {
            if (Get-Prop $i 'isFolder') { continue }
            $content = Get-Prop $i 'content'
            if ($null -eq $content -and $WithContent) {
                $file = Invoke-Ado -Method GET -Url "${itemsUrl}?path=$([uri]::EscapeDataString([string]$i.path))&includeContent=true&`$format=json&$version" -Headers $Context.Headers
                $content = Get-Prop $file 'content'
            }
            $map[[string]$i.path] = $content
        }
    }
    return , $map
}

function Get-LocalFiles([string]$Root) {
    # Restituisce @{ Path = '/src/x.py'; Content = '...' } per ogni file sotto $Root
    $rootFull = (Resolve-Path $Root).Path
    Get-ChildItem -Path $rootFull -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and $_.Extension -ne '.pyc' } |
        ForEach-Object {
            [pscustomobject]@{
                Path    = ConvertTo-AdoPath ([IO.Path]::GetRelativePath($rootFull, $_.FullName))
                Content = [IO.File]::ReadAllText($_.FullName, [Text.UTF8Encoding]::new($false))
            }
        }
}

function Send-AdoPush {
    # Crea un commit con i file indicati (salta quelli invariati). Se il ramo non esiste lo crea
    # (a partire da $FromSha, oppure come primo commit di un repository vuoto). Restituisce $null se non c'è nulla da pushare.
    param($Context, [string]$RepoId, [string]$Branch, [string]$Message, $Files, $Existing, [string]$FromSha)
    $branchRef = "refs/heads/$Branch"
    $changes = @()
    foreach ($f in $Files) {
        $exists = ($null -ne $Existing) -and $Existing.ContainsKey($f.Path)
        if ($exists) {
            $old = $Existing[$f.Path]
            if ($null -ne $old -and ($old -replace "`r`n", "`n") -eq ($f.Content -replace "`r`n", "`n")) { continue }
        }
        $changes += [ordered]@{
            changeType = $(if ($exists) { 'edit' } else { 'add' })
            item       = @{ path = $f.Path }
            newContent = @{ content = $f.Content; contentType = 'rawtext' }
        }
    }
    if ($changes.Count -eq 0) { return $null }
    $current = Get-BranchHead $Context $RepoId $Branch
    if (-not $current -and $FromSha) {
        $refUrl = "$(Get-ProjectBaseUrl $Context.OrganizationUrl $Context.Project)/_apis/git/repositories/$RepoId/refs"
        $refResult = Invoke-Ado -Method POST -Url $refUrl -Headers $Context.Headers -Body @(@{ name = $branchRef; oldObjectId = $script:ZeroSha; newObjectId = $FromSha })
        $refFailed = @(@(Get-Prop $refResult 'value') | Where-Object { $null -ne $_ -and (Get-Prop $_ 'success') -eq $false }) | Select-Object -First 1
        if ($refFailed) { throw "Creazione del ramo '$Branch' non riuscita: $(Get-Prop $refFailed 'customMessage') ($(Get-Prop $refFailed 'updateStatus'))" }
        $current = $FromSha
    }
    $body = @{
        refUpdates = @(@{ name = $branchRef; oldObjectId = $(if ($current) { $current } else { $script:ZeroSha }) })
        commits    = @(@{ comment = $Message; changes = $changes })
    }
    $pushUrl = "$(Get-ProjectBaseUrl $Context.OrganizationUrl $Context.Project)/_apis/git/repositories/$RepoId/pushes"
    return Invoke-Ado -Method POST -Url $pushUrl -Headers $Context.Headers -Body $body
}

# ---------------------------------------------------------------- stato condiviso fra gli script

function Save-PocState($State) {
    # Un solo file di stato per tutta la PoC. La scrittura UNISCE i campi nuovi a quelli già presenti, così ogni script aggiorna
    # la propria parte (es. Test-CopilotAccess scrive 'verifiedModel', Setup-Poc le risorse create) senza cancellare quella degli altri.
    $merged = [ordered]@{}
    $current = Read-PocState
    if ($current) { foreach ($p in $current.PSObject.Properties) { $merged[$p.Name] = $p.Value } }
    $incoming = if ($State -is [System.Collections.IDictionary]) { $State } else { $State.PSObject.Properties | ForEach-Object -Begin { $h = [ordered]@{} } -Process { $h[$_.Name] = $_.Value } -End { $h } }
    foreach ($key in $incoming.Keys) { $merged[$key] = $incoming[$key] }
    ConvertTo-Json -InputObject $merged -Depth 10 | Set-Content -Path $script:StatePath -Encoding utf8
}

function Read-PocState {
    if (Test-Path $script:StatePath) { return Get-Content $script:StatePath -Raw | ConvertFrom-Json }
    return $null
}

function Get-StateValue($State, [string]$Name) {
    if ($State -and ($State.PSObject.Properties.Name -contains $Name)) { return $State.$Name }
    return $null
}

function Get-Prop($Object, [string]$Name) {
    # Lettura sicura di una proprietà (StrictMode): $null se manca, anche su oggetti vuoti ({})
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-UtcDateTime($Value) {
    # ConvertFrom-Json trasforma le date ISO 8601 in [datetime] (le stringhe 'Z' diventano Kind=Utc):
    # [DateTimeOffset]::Parse($Value) passerebbe dalla cultura corrente (it-IT: errore o giorno/mese invertiti) e perderebbe il fuso.
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

# ---------------------------------------------------------------- GitHub App / API GitHub

function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GitHubAppJwt([string]$AppId, [string]$PrivateKeyPem) {
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($PrivateKeyPem)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((@{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress)))
    $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((@{ iat = $now - 60; exp = $now + 540; iss = $AppId } | ConvertTo-Json -Compress)))
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes("$header.$payload"),
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    return "$header.$payload.$(ConvertTo-Base64Url $signature)"
}

function Invoke-GitHub {
    [CmdletBinding()]
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Token,
        $Body,
        [string]$ApiVersion = '2022-11-28',
        [switch]$AllowNotFound
    )
    $request = @{
        Method = $Method; Uri = $Url; SkipHttpErrorCheck = $true
        Headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = $ApiVersion; 'User-Agent' = 'ado-aw-poc' }
    }
    if ($null -ne $Body) { $request.Body = (ConvertTo-Json -InputObject $Body -Depth 10 -Compress); $request.ContentType = 'application/json' }
    $response = Invoke-WebRequest @request
    $status = [int]$response.StatusCode
    $content = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
    if ($status -eq 404 -and $AllowNotFound) { return $null }
    if ($status -lt 200 -or $status -ge 300) {
        $message = $content
        try { $message = ($message | ConvertFrom-Json).message } catch { }
        throw "GitHub $Method $Url -> HTTP $status`n$message"
    }
    if ([string]::IsNullOrWhiteSpace($content)) { return $null }
    return $content | ConvertFrom-Json -Depth 20
}

function Get-GitHubUserToken([string]$ExplicitToken, [string]$ApiUrl) {
    if ($ExplicitToken) { return $ExplicitToken }
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    $hostName = ([uri]$ApiUrl).Host
    $hostName = if ($hostName -eq 'api.github.com') { 'github.com' } else { $hostName -replace '^api\.', '' }
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $t = (gh auth token --hostname $hostName 2>$null)
        if ($LASTEXITCODE -eq 0 -and $t) { return $t.Trim() }
    }
    throw "Token GitHub non trovato. Passa -GitHubToken oppure esegui 'gh auth login --hostname $hostName' con un owner/billing manager (organizzazione o Enterprise)."
}

# ---------------------------------------------------------------- GitHub.com oppure GHE.com (data residency, EMU)

function Get-GitHubTarget([string]$GitHubHost, [string]$GitHubApiUrl) {
    # Risolve dove si trova GitHub: github.com (default) oppure un tenant GHE.com con data residency (https://<tenant>.ghe.com,
    # API su https://api.<tenant>.ghe.com, enterprise EMU con slug = sottodominio).
    $hostName = $null
    if ($GitHubHost) {
        $hostName = ($GitHubHost.Trim() -replace '^https?://', '').TrimEnd('/').ToLowerInvariant()
        if ($hostName -notmatch '^[a-z0-9][a-z0-9-]*\.ghe\.com$') {
            throw "-GitHubHost deve essere il dominio del tenant GHE.com (es. contoso.ghe.com), non '$GitHubHost'."
        }
    } elseif ($GitHubApiUrl -and ([uri]$GitHubApiUrl).Host -match '^api\.(?<t>[a-z0-9][a-z0-9-]*\.ghe\.com)$') {
        $hostName = $Matches.t
    }
    $api = if ($GitHubApiUrl) { $GitHubApiUrl.TrimEnd('/') } elseif ($hostName) { "https://api.$hostName" } else { 'https://api.github.com' }
    return [pscustomobject]@{
        IsGhe      = [bool]$hostName
        Host       = $hostName
        ApiUrl     = $api
        Enterprise = $(if ($hostName) { $hostName -replace '\.ghe\.com$', '' } else { $null })
        WebUrl     = $(if ($hostName) { "https://$hostName" } else { 'https://github.com' })
    }
}

function Get-DefaultModel([bool]$IsGhe) {
    # github.com: modello Lightweight di default. GHE.com con data residency: solo i modelli della regione (US o UE) sono consentiti
    # e gpt-5.6-luna è disponibile solo nella UE; claude-haiku-5.5 (Lightweight) è disponibile sia in US sia in UE.
    if ($IsGhe) { return 'claude-haiku-5.5' }
    return 'gpt-5.6-luna'
}

# Modello verificato da Test-CopilotAccess.ps1 (valido per quel tenant e quella organizzazione): Setup-Poc.ps1 lo usa da solo.
# Vive nello stesso file di stato (campo 'verifiedModel').
function Save-VerifiedModel([string]$Model, $Target, [string]$Org) {
    $hostName = if ($Target.Host) { $Target.Host } else { 'github.com' }
    Save-PocState @{ verifiedModel = [ordered]@{ model = $Model; host = $hostName; org = $Org; verifiedUtc = (Get-Date).ToUniversalTime().ToString('o') } }
}

function Get-VerifiedModel($Target, [string]$Org) {
    $saved = Get-StateValue (Read-PocState) 'verifiedModel'
    if (-not $saved) { return $null }
    $hostName = if ($Target.Host) { $Target.Host } else { 'github.com' }
    if ((Get-Prop $saved 'host') -eq $hostName -and "$(Get-Prop $saved 'org')" -ieq $Org -and (Get-Prop $saved 'model')) { return [string]$saved.model }
    return $null
}

function Get-AppInstallation {
    # Firma il JWT dell'App e cerca l'installazione sull'organizzazione. Restituisce $null se l'App non è installata.
    param([string]$ApiUrl, [string]$AppId, [string]$PrivateKeyPem, [string]$Org)
    $jwt = New-GitHubAppJwt $AppId $PrivateKeyPem
    $installation = Invoke-GitHub -Url "$ApiUrl/orgs/$Org/installation" -Token $jwt -AllowNotFound
    if (-not $installation) { return $null }
    return [pscustomobject]@{ Jwt = $jwt; Installation = $installation }
}

function New-AppInstallationToken {
    # Token di installazione (validità 1 ora). Con -Permissions chiede esplicitamente quei permessi (422 se l'installazione non li ha).
    param([string]$ApiUrl, [string]$Jwt, $InstallationId, [hashtable]$Permissions)
    $body = $(if ($Permissions) { @{ permissions = $Permissions } } else { $null })
    return Invoke-GitHub -Method POST -Url "$ApiUrl/app/installations/$InstallationId/access_tokens" -Token $Jwt -Body $body
}

function Remove-AppInstallationToken([string]$ApiUrl, [string]$Token) {
    try { [void](Invoke-GitHub -Method DELETE -Url "$ApiUrl/installation/token" -Token $Token) } catch { }
}

# ---------------------------------------------------------------- template del workflow (marcatori condizionali)

function Resolve-TemplateMarkers([string]$Text, [hashtable]$Flags) {
    # Nel template i blocchi opzionali sono commenti YAML:
    #   "# >>nome" ... "# <<nome"   blocco tenuto solo se il flag 'nome' è vero
    #   "#@nome contenuto"          riga attivata (stessa indentazione) solo se il flag 'nome' è vero
    $Text = $Text -replace "`r`n", "`n"
    $isOn = {
        param([string]$Name)
        if (-not $Flags.ContainsKey($Name)) { throw "Marcatore sconosciuto nel template: '$Name'" }
        return [bool]$Flags[$Name]
    }
    $Text = [regex]::Replace($Text, '(?ms)^[ \t]*# >>(?<name>[a-z-]+)[ \t]*\n(?<body>.*?)^[ \t]*# <<\k<name>[ \t]*\n',
        [Text.RegularExpressions.MatchEvaluator] { param($m) if (& $isOn $m.Groups['name'].Value) { $m.Groups['body'].Value } else { '' } })
    $Text = [regex]::Replace($Text, '(?m)^(?<indent>[ \t]*)#@(?<name>[a-z-]+) (?<content>[^\n]*)\n',
        [Text.RegularExpressions.MatchEvaluator] { param($m) if (& $isOn $m.Groups['name'].Value) { $m.Groups['indent'].Value + $m.Groups['content'].Value + "`n" } else { '' } })
    if ($Text -match '(?m)^[ \t]*(# [<>]{2}[a-z-]+|#@[a-z-]+ )') { throw 'Marcatori del template non risolti: controlla la sintassi (# >>nome ... # <<nome).' }
    return $Text
}

# ---------------------------------------------------------------- Copilot CLI (solo per lo smoke test locale)

function Get-CopilotCli([string]$Version) {
    # Restituisce un eseguibile 'copilot' della versione indicata: quello nel PATH se coincide, altrimenti la release ufficiale
    # (github/copilot-cli) scaricata e verificata con SHA256SUMS.txt.
    $savedUpdate = $env:COPILOT_AUTO_UPDATE
    $env:COPILOT_AUTO_UPDATE = 'false'   # senza questo la CLI si aggiorna da sola e riporta un'altra versione
    try {
        $onPath = Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onPath) {
            $found = try { (& $onPath.Source --version 2>$null) -join ' ' } catch { '' }
            if ($found -match "Copilot CLI $([regex]::Escape($Version))\b") { return $onPath.Source }
            Write-Note "copilot nel PATH è '$found': uso la $Version, la stessa della pipeline"
        }
        $asset = if ($IsWindows) { if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'copilot-win32-arm64.zip' } else { 'copilot-win32-x64.zip' } }
                 elseif ($IsMacOS) { if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'copilot-darwin-arm64.tar.gz' } else { 'copilot-darwin-x64.tar.gz' } }
                 else { if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'copilot-linux-arm64.tar.gz' } else { 'copilot-linux-x64.tar.gz' } }
        $dir = Join-Path ([IO.Path]::GetTempPath()) "copilot-cli-poc/v$Version"
        $exeName = if ($IsWindows) { 'copilot.exe' } else { 'copilot' }
        $existing = if (Test-Path $dir) { Get-ChildItem $dir -Recurse -File -Filter $exeName | Select-Object -First 1 } else { $null }
        if ($existing) {
            $cached = try { (& $existing.FullName --version 2>$null) -join ' ' } catch { '' }
            if ($cached -match "Copilot CLI $([regex]::Escape($Version))\b") { return $existing.FullName }
            Remove-Item $dir -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $base = "https://github.com/github/copilot-cli/releases/download/v$Version"
        $archive = Join-Path $dir $asset
        Write-Note "Scarico la Copilot CLI $Version ($asset, circa 140 MB, una tantum)"
        $progress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest "$base/$asset" -OutFile $archive
            $sumsRaw = (Invoke-WebRequest "$base/SHA256SUMS.txt").Content
        } finally { $ProgressPreference = $progress }
        $sums = $(if ($sumsRaw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($sumsRaw) } else { [string]$sumsRaw }) -split "`n"
        $line = $sums | Where-Object { $_ -match "\s\*?$([regex]::Escape($asset))\s*$" } | Select-Object -First 1
        if (-not $line) { throw "Checksum di $asset non trovato in SHA256SUMS.txt" }
        $expected = ($line.Trim() -split '\s+')[0].ToLowerInvariant()
        if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
            Remove-Item $dir -Recurse -Force
            throw "Checksum SHA-256 di $asset non valido: download scartato."
        }
        if ($asset.EndsWith('.zip')) { Expand-Archive -Path $archive -DestinationPath $dir -Force } else { tar -xzf $archive -C $dir }
        Remove-Item $archive -Force
        $exe = Get-ChildItem $dir -Recurse -File -Filter $exeName | Select-Object -First 1
        if (-not $exe) { throw "Eseguibile $exeName non trovato in $asset" }
        if (-not $IsWindows) { chmod +x $exe.FullName }
        return $exe.FullName
    } finally { $env:COPILOT_AUTO_UPDATE = $savedUpdate }
}
