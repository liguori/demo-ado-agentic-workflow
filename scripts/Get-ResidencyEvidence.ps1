#Requires -Version 7.0
<#
.SYNOPSIS
    Prova di data residency: quali host ha contattato davvero l'agente nelle esecuzioni? (dal riepilogo del firewall AWF nei log)

.DESCRIPTION
    Ogni job Agent e Detection esegue Copilot dentro il firewall AWF (rete isolata con elenco dei domini consentiti) e a fine
    esecuzione stampa «=== Firewall Summary ===», una tabella «Domain | Allowed | Denied» (richieste consentite e bloccate per dominio).
    Questo script legge dai log delle ultime esecuzioni lo step «Run copilot (AWF network isolated)», somma le richieste per
    dominio e classifica gli host:
      · tenant GHE.com        (<tenant>.ghe.com e *.<tenant>.ghe.com: API, autenticazione, copilot-api regionale)
      · pubblici GitHub/Copilot (github.com, *.githubcopilot.com, *.githubusercontent.com…)  → NON devono essere contattati
      · Azure DevOps / Microsoft
      · altri
    Un host pubblico con richieste «Allowed» è un contatto fuori dal tenant (esito 1); un host pubblico solo «Denied» è un
    tentativo BLOCCATO dal firewall: non è un problema, anzi dimostra che il firewall tiene (tipico con -StrictResidency).
    Se il riepilogo ha un altro formato (altre versioni di AWF) legge comunque gli host citati, senza distinguere consentiti e bloccati.
    Il traffico di installazione (Copilot CLI, AWF, immagini Docker) avviene fuori dalla sandbox e non è nel riepilogo.

    Esito 0 = solo endpoint del tenant; 1 = contatti verso endpoint pubblici (o nessun host del tenant); 2 = nessun riepilogo nei log.
    Nota: la Copilot CLI contatta sempre api.github.com all'avvio (chiamata non essenziale: negata, la CLI prosegue verso il tenant).
    Senza -StrictResidency compare quindi tra i contatti pubblici (esito 1, con messaggio dedicato); con -StrictResidency il firewall la
    nega e compare tra i tentativi bloccati (esito 0): è la modalità consigliata per la dimostrazione.
    Il riepilogo è la fonte primaria: con -ShowRaw lo stampa così com'è, per verificarlo a occhio.

.EXAMPLE
    ./Get-ResidencyEvidence.ps1
    ./Get-ResidencyEvidence.ps1 -Last 10 -ShowRaw
#>
[CmdletBinding()]
param(
    [int]$Last = 5,
    [int]$RunId,
    [string]$GitHubHost,
    [string]$Pat,
    [switch]$ShowRaw
)

. "$PSScriptRoot/PocCommon.ps1"
$state = Read-PocState
if (-not $state) { throw 'Stato della PoC non trovato (.poc-state.json): esegui prima Setup-Poc.ps1.' }
$tenant = if ($GitHubHost) { (Get-GitHubTarget $GitHubHost $null).Host } else { Get-StateValue $state 'githubHost' }
if (-not $tenant) { throw 'La PoC non è configurata per GHE.com (data residency): nulla da dimostrare. Rilancia Setup-Poc.ps1 con -GitHubHost <tenant>.ghe.com.' }

$headers = Get-AdoHeaders $Pat
$projBase = Get-ProjectBaseUrl $state.organizationUrl $state.project

function Get-HostClass([string]$HostName) {
    $h = $HostName.ToLowerInvariant().TrimStart('*').TrimStart('.')
    if ($h -eq $tenant -or $h.EndsWith(".$tenant")) { return 'tenant' }
    if ($h -match '(^|\.)ghe\.com$') { return 'altro-tenant' }
    if ($h -match '(^|\.)(github\.com|githubcopilot\.com|githubusercontent\.com|githubassets\.com)$') { return 'pubblico' }
    if ($h -match '(^|\.)(dev\.azure\.com|visualstudio\.com|vsassets\.io|windows\.net|microsoftonline\.com|live\.com|msauth\.net|msftauth\.net|azure\.com|microsoft\.com|skype\.com)$') { return 'msft' }
    return 'altro'
}

function Get-HostsFromLines([string[]]$Lines) {
    $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $notHosts = '^(log|json|txt|md|ya?ml|sh|js|ts|py|exe|zip|gz|tar|tgz|cs|ps1|lock|jsonl|html?)$'
    foreach ($line in $Lines) {
        foreach ($m in [regex]::Matches($line, '(?<![A-Za-z0-9\-\.])(?:\*\.)?[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+(?![A-Za-z0-9\-])')) {
            $h = $m.Value.TrimEnd('.')
            $tld = ($h -split '\.')[-1]
            if ($tld -match '^[A-Za-z]{2,10}$' -and $tld -notmatch $notHosts -and $h -notmatch '^\d+(\.\d+)+$') { [void]$found.Add($h.ToLowerInvariant()) }
        }
    }
    return @($found | Sort-Object)
}

function Read-FirewallEvidence([string]$LogText) {
    # Le righe dei log di Azure DevOps iniziano con un timestamp ISO: lo tolgo.
    $lines = @(($LogText -split "`r?`n") | ForEach-Object { $_ -replace '^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s?', '' })
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '=== Firewall Summary ===') { $start = $i; break } }
    $summary = @()
    if ($start -ge 0) {
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^(##\[|Finishing:|=== )') { break }
            $summary += $lines[$i]
        }
    }
    # Formato di «awf logs summary»: tabella Markdown «| dominio | consentite | bloccate |» (o l'elenco «dominio  N allowed, M denied»).
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $summary) {
        if ($line -match '^\s*\|\s*(?<h>[^|\s]+)\s*\|\s*(?<a>\d+)\s*\|\s*(?<d>\d+)\s*\|\s*$' -or $line -match '^\s+(?<h>\S+)\s+(?<a>\d+) allowed,\s*(?<d>\d+) denied') {
            $rows.Add([pscustomobject]@{ Host = $Matches.h.ToLowerInvariant(); Allowed = [int]$Matches.a; Denied = [int]$Matches.d })
        }
    }
    if ($rows.Count -eq 0) {
        foreach ($h in @(Get-HostsFromLines $summary)) { $rows.Add([pscustomobject]@{ Host = $h; Allowed = $null; Denied = $null }) }   # altro formato: host citati, senza conteggi
    }
    $allowedLine = $lines | Where-Object { $_ -match '^\s*Allowed domains:' } | Select-Object -First 1
    $allowed = @()
    if ($allowedLine) { $allowed = @(($allowedLine -replace '^\s*Allowed domains:\s*', '') -split '[,\s]+' | Where-Object { $_ }) }
    return [pscustomobject]@{ Found = ($start -ge 0); Summary = $summary; Rows = @($rows); Allowed = $allowed; AllowedSeen = [bool]$allowedLine }
}

# ------------------------------------------------------------------ esecuzioni da analizzare
Write-Step "Esecuzioni della pipeline '$($state.pipelineName)'"
if ($RunId) { $runIds = @($RunId) }
else {
    $runs = Invoke-Ado -Method GET -Url "$projBase/_apis/pipelines/$($state.pipelineId)/runs" -Headers $headers
    $runIds = @(@($runs.value) | Where-Object { $_.state -eq 'completed' } | Sort-Object { ConvertTo-UtcDateTime $_.createdDate } -Descending | Select-Object -First $Last | ForEach-Object { $_.id })
}
if (-not $runIds.Count) { throw 'Nessuna esecuzione completata: lancia prima New-DemoPullRequests.ps1 -Wait.' }
Write-Ok "Analizzo $($runIds.Count) esecuzioni: $($runIds -join ', ')"

$byHost = @{}
$allowedPublic = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$allowedSeen = $false
$stepsRead = 0
$auditRuns = 0
$raw = [System.Collections.Generic.List[string]]::new()

function Get-RunAuditRows([int]$RunNumber) {
    # Fonte principale: artefatto «agent_outputs_<run>», file logs/firewall/audit.jsonl = una riga JSON per ogni richiesta (HTTP/CONNECT)
    # vista dal firewall AWF nel job Agent, con host di destinazione e decisione (TCP_TUNNEL = consentita, TCP_DENIED = bloccata).
    # Restituisce $null se l'artefatto o il file non ci sono.
    try {
        $arts = Invoke-Ado -Method GET -Url "$projBase/_apis/build/builds/$RunNumber/artifacts?api-version=7.1" -Headers $headers
        $art = @($arts.value) | Where-Object { $_.name -like 'agent_outputs*' } | Select-Object -First 1
        if (-not $art) { return $null }
        $zipPath = Join-Path ([IO.Path]::GetTempPath()) ("aw-art-$RunNumber-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.zip')
        try {
            Invoke-WebRequest -Uri $art.resource.downloadUrl -Headers $headers -OutFile $zipPath -UseBasicParsing | Out-Null
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                $entry = $zip.Entries | Where-Object { $_.FullName -match '(^|/)logs/firewall/audit\.jsonl$' } | Select-Object -First 1
                if (-not $entry) { return $null }
                $reader = [IO.StreamReader]::new($entry.Open()); $text = $reader.ReadToEnd(); $reader.Close()
            } finally { $zip.Dispose() }
        } finally { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
    } catch { Write-Note "Run ${RunNumber}: artefatto del firewall non leggibile ($($_.Exception.Message.Split("`n")[0]))"; return $null }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($text -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        $target = [string](Get-Prop $e 'host')
        if (-not $target -or $target -eq '-') { continue }   # righe senza destinazione (sonde interne del proxy)
        $denied = ([string](Get-Prop $e 'decision')) -match 'DENIED'
        $rows.Add([pscustomobject]@{ Host = ($target -replace ':\d+$', '').ToLowerInvariant(); Allowed = $(if ($denied) { 0 } else { 1 }); Denied = $(if ($denied) { 1 } else { 0 }); Raw = $line })
    }
    return , $rows
}

function Add-HostRow($HostName, $Allowed, $Denied, [int]$RunNumber) {
    if (-not $byHost.ContainsKey($HostName)) {
        $byHost[$HostName] = [pscustomobject]@{ Host = $HostName; Class = (Get-HostClass $HostName); Allowed = 0; Denied = 0; Unknown = $false; Runs = [System.Collections.Generic.HashSet[int]]::new() }
    }
    $entry = $byHost[$HostName]
    if ($null -eq $Allowed) { $entry.Unknown = $true } else { $entry.Allowed += $Allowed; $entry.Denied += $Denied }
    [void]$entry.Runs.Add($RunNumber)
}

foreach ($id in $runIds) {
    $timeline = Invoke-Ado -Method GET -Url "$projBase/_apis/build/builds/$id/timeline" -Headers $headers
    $records = @(@($timeline.records) | Where-Object { $_.name -match 'AWF network isolated' -and (Get-Prop $_ 'log') })
    $auditRows = Get-RunAuditRows $id
    $hasAudit = $null -ne $auditRows
    if ($hasAudit) {
        $stepsRead++; $auditRuns++
        foreach ($row in $auditRows) { Add-HostRow $row.Host $row.Allowed $row.Denied $id }
        if ($ShowRaw) { $raw.Add("--- run $id · firewall AWF (audit.jsonl) ---"); foreach ($row in $auditRows) { $raw.Add($row.Raw) } }
    }
    foreach ($rec in $records) {
        $text = Invoke-Ado -Method GET -Url "$projBase/_apis/build/builds/$id/logs/$($rec.log.id)" -Headers $headers -Raw
        $evidence = Read-FirewallEvidence $text
        if (-not $evidence.Found) { if (-not $hasAudit) { Write-Note "Run $id · $($rec.name): riepilogo del firewall non presente nel log" }; continue }
        if (-not $hasAudit) {
            $stepsRead++
            foreach ($row in $evidence.Rows) { Add-HostRow $row.Host $row.Allowed $row.Denied $id }
            if ($ShowRaw) { $raw.Add("--- run $id · $($rec.name) ---"); foreach ($l in $evidence.Summary) { $raw.Add($l) } }
        }
        if ($evidence.AllowedSeen) { $allowedSeen = $true }
        foreach ($d in $evidence.Allowed) { if ((Get-HostClass $d) -eq 'pubblico') { [void]$allowedPublic.Add($d) } }
    }
}
if ($stepsRead -eq 0) {
    Write-Warn 'Nessun log del firewall trovato (né artefatto agent_outputs né riepilogo nel log): le esecuzioni potrebbero essere terminate prima del job Agent (controlla la pipeline).'
    exit 2
}

# ------------------------------------------------------------------ esito
function Format-HostList($Entries, [switch]$WithRequests) {
    if (-not $Entries) { return '(nessuno)' }
    return (@($Entries) | ForEach-Object {
        if ($WithRequests -and -not $_.Unknown) { "$($_.Host) ($($_.Allowed) richieste, $($_.Runs.Count) run)" } else { $_.Host }
    }) -join ', '
}
$contacted = { param($e) $e.Allowed -gt 0 -or $e.Unknown }
$tenantHosts = @($byHost.Values | Where-Object { $_.Class -eq 'tenant' -and (& $contacted $_) } | Sort-Object Host)
$publicUsed = @($byHost.Values | Where-Object { $_.Class -in 'pubblico', 'altro-tenant' -and (& $contacted $_) } | Sort-Object Host)
$publicBlocked = @($byHost.Values | Where-Object { $_.Class -in 'pubblico', 'altro-tenant' -and -not (& $contacted $_) -and $_.Denied -gt 0 } | Sort-Object Host)
$msft = @($byHost.Values | Where-Object { $_.Class -eq 'msft' -and (& $contacted $_) } | Sort-Object Host)
$other = @($byHost.Values | Where-Object { $_.Class -eq 'altro' -and (& $contacted $_) } | Sort-Object Host)

Write-Host "`n═══ Prova di data residency — host contattati dall'agente ═══" -ForegroundColor Cyan
Write-Host ("  Tenant GHE.com                   : {0}" -f $tenant)
Write-Host ("  Fonte                            : {0}" -f $(if ($auditRuns -gt 0) { "log del firewall AWF (audit.jsonl) di $auditRuns esecuzioni su $($runIds.Count)" } else { "riepilogo del firewall nei log di $($runIds.Count) esecuzioni" }))
Write-Host ("  Host del tenant                  : {0}" -f (Format-HostList $tenantHosts -WithRequests))
Write-Host ("  Azure DevOps / Microsoft         : {0}" -f (Format-HostList $msft))
if ($other) { Write-Host ("  Altri host                       : {0}" -f (Format-HostList $other)) -ForegroundColor DarkGray }
$allowedText = if (-not $allowedSeen) { 'non rilevabile dai log' } elseif ($allowedPublic.Count -eq 0) { '0  (modalità -StrictResidency: bloccati)' } else { "$($allowedPublic.Count)  (consentiti, ma l'agente non li ha usati se sotto non compaiono)" }
Write-Host ("  Domini pubblici consentiti dal firewall: {0}" -f $allowedText)
if ($publicBlocked) { Write-Host ("  Tentativi BLOCCATI dal firewall  : {0}  ✔ il firewall ha impedito l'uscita" -f (Format-HostList $publicBlocked)) -ForegroundColor DarkGray }
if ($publicUsed.Count -eq 0 -and $tenantHosts.Count -gt 0) {
    Write-Host '  Endpoint pubblici GitHub/Copilot : nessuno contattato  ✔' -ForegroundColor Green
    Write-Host "`n  Conclusione: nelle esecuzioni analizzate l'inferenza e l'autenticazione Copilot sono passate solo dal tenant $tenant." -ForegroundColor Green
    $code = 0
} elseif ($publicUsed.Count -gt 0) {
    Write-Host ("  Endpoint pubblici GitHub/Copilot : {0}  ✘" -f (Format-HostList $publicUsed -WithRequests)) -ForegroundColor Red
    if (@($publicUsed | Where-Object { $_.Host -ne 'api.github.com' }).Count -eq 0) {
        Write-Host "`n  L'unico host pubblico è api.github.com: chiamata d'avvio della Copilot CLI, non essenziale (se bloccata la CLI prosegue verso il tenant)." -ForegroundColor Yellow
        Write-Host "  Per dimostrare che non esce nulla dal tenant rilancia Setup-Poc.ps1 con -StrictResidency: il firewall la blocca e comparirà tra i tentativi bloccati." -ForegroundColor Yellow
    } else {
        Write-Host "`n  Attenzione: l'agente ha contattato host fuori dal tenant. Rilancia Setup-Poc.ps1 con -StrictResidency per bloccarli nel firewall e ripeti la demo." -ForegroundColor Yellow
    }
    $code = 1
} else {
    Write-Host '  Nessun host del tenant nel riepilogo: la Copilot CLI potrebbe non aver raggiunto il tenant. Controlla il log dello step.' -ForegroundColor Yellow
    $code = 1
}
if ($ShowRaw -and $raw.Count) { Write-Host "`n── Riepilogo grezzo del firewall ──" -ForegroundColor DarkGray; $raw | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
exit $code
