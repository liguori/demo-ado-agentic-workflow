#Requires -Version 7.0
<#
.SYNOPSIS
    Quanti AI Credits ha consumato una GitHub App in un periodo, letti via REST API dal report di utilizzo di GitHub.
    Script AUTONOMO: non legge né scrive file di stato e non dipende da lanci precedenti.

.DESCRIPTION
    Metodo principale (REST, a livello Enterprise):
      1. POST /enterprises/{ent}/settings/billing/reports   {report_type: ai_credit, start_date, end_date}  -> id del report
      2. GET  /enterprises/{ent}/settings/billing/reports/{id}   finché status = completed
      3. scarica il CSV da download_urls e somma SOLO le righe dell'App (colonna app_client_id; con -Username, dell'utente di servizio)
         dell'organizzazione indicata, nel periodo -From/-To. Le righe dell'App hanno username vuoto: nessun utente è addebitato.

    Identità usata per leggere la fatturazione (diversa da quella che esegue Copilot nella pipeline):
      - PAT *classic* di enterprise admin / billing manager:  -GitHubToken, oppure GH_TOKEN, oppure 'gh auth login'
      - oppure GitHub App dedicata, installata sull'Enterprise con lettura della fatturazione:
        -BillingAppId <id> -BillingPrivateKeyPath <pem>  (token di installazione generato e revocato dallo script)

    Se l'endpoint dei report non esiste (404: oggi non disponibile su alcuni tenant GHE.com) o l'Enterprise non è nota, lo script ripiega
    sul consumo AGGREGATO dell'organizzazione nello stesso periodo (API /ai_credit/usage, un giorno alla volta): non distingue l'App dagli
    utenti. -NoFallback si ferma. In alternativa -UsageCsv <file> analizza un CSV scaricato dal sito con gli stessi filtri.

    Opzionale: con -AdoOrganizationUrl, -AdoProject e -PipelineId conta anche le esecuzioni e i Task (tag ado-aw) creati nel periodo.

.PARAMETER From
    Primo giorno (UTC, incluso). Default: primo giorno del mese corrente. Il report ha granularità giornaliera.
.PARAMETER To
    Ultimo giorno (UTC, incluso). Default: oggi.

.EXAMPLE
    # GHE.com (data residency): l'Enterprise coincide con il sottodominio del tenant
    ./Get-AiCredits.ps1 -GitHubOrg contoso-org -GitHubHost contoso.ghe.com -AppClientId Iv23xxxx -From 2026-11-24
.EXAMPLE
    # github.com, con una GitHub App di sola lettura sulla fatturazione
    ./Get-AiCredits.ps1 -GitHubOrg contoso-org -GitHubEnterprise contoso -AppClientId Iv23xxxx -BillingAppId 123456 -BillingPrivateKeyPath ./billing.pem
.EXAMPLE
    ./Get-AiCredits.ps1 -GitHubOrg contoso-org -AppClientId Iv23xxxx -UsageCsv ~/Downloads/ai-usage-report.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GitHubOrg,
    [string]$GitHubHost,
    [string]$GitHubEnterprise,
    [string]$GitHubApiUrl,
    [string]$AppClientId,
    [string]$Username,
    [datetime]$From,
    [datetime]$To,
    [string]$GitHubToken,
    [string]$BillingAppId,
    [string]$BillingPrivateKeyPath,
    [string]$UsageCsv,
    [int]$ReportTimeoutMinutes = 10,
    [switch]$NoFallback,
    [string]$AdoOrganizationUrl,
    [string]$AdoProject,
    [int]$PipelineId,
    [string]$Pat
)

. "$PSScriptRoot/PocCommon.ps1"
$org = $GitHubOrg
$target = Get-GitHubTarget $GitHubHost $GitHubApiUrl
$api = $target.ApiUrl
# GHE.com (utenti EMU): la fatturazione è dell'Enterprise e lo slug coincide con il sottodominio del tenant. Su github.com serve -GitHubEnterprise.
$enterprise = if ($GitHubEnterprise) { $GitHubEnterprise } else { $target.Enterprise }
$svcUser = $Username
$clientId = $AppClientId
if (-not $svcUser -and -not $clientId) { Write-Warn "Nessun -AppClientId né -Username: verranno sommate le righe di TUTTE le GitHub App dell'organizzazione." }

$now = (Get-Date).ToUniversalTime()
$fromDay = if ($PSBoundParameters.ContainsKey('From')) { $From.Date } else { [datetime]::new($now.Year, $now.Month, 1) }
$toDay = if ($PSBoundParameters.ContainsKey('To')) { $To.Date } else { $now.Date }
if ($toDay -lt $fromDay) { throw "-To ($($toDay.ToString('yyyy-MM-dd'))) è precedente a -From ($($fromDay.ToString('yyyy-MM-dd')))." }
$windowLabel = "{0:yyyy-MM-dd} → {1:yyyy-MM-dd} (UTC, giorni inclusi)" -f $fromDay, $toDay

function Format-Credits([double]$Value) { return ('{0:N2}' -f $Value) }
function Format-Usd([double]$Credits) { return ('${0:N2}' -f ($Credits * 0.01)) }
function ConvertTo-Number($Value) {
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return 0.0 }
    return [double]::Parse($s, [Globalization.CultureInfo]::InvariantCulture)
}

# ------------------------------------------------------------------ identità per leggere la fatturazione
$script:billingInstallToken = $null
function Get-BillingToken {
    if ($BillingAppId) {
        if (-not $BillingPrivateKeyPath -or -not (Test-Path $BillingPrivateKeyPath)) { throw 'Con -BillingAppId serve -BillingPrivateKeyPath (file .pem della GitHub App di lettura).' }
        if (-not $enterprise) { throw "Con una GitHub App di fatturazione serve conoscere l'Enterprise: passa -GitHubEnterprise <slug> (o -GitHubHost)." }
        $jwt = New-GitHubAppJwt $BillingAppId ((Get-Content $BillingPrivateKeyPath -Raw).Trim())
        $install = $null
        for ($page = 1; $page -le 10 -and -not $install; $page++) {
            $batch = @(Invoke-GitHub -Url "$api/app/installations?per_page=100&page=$page" -Token $jwt)
            if (-not $batch.Count) { break }
            $install = $batch | Where-Object {
                $a = Get-Prop $_ 'account'
                ((Get-Prop $a 'login') -ieq $enterprise) -or ((Get-Prop $a 'slug') -ieq $enterprise)
            } | Select-Object -First 1
            if ($batch.Count -lt 100) { break }
        }
        if (-not $install) { throw "La GitHub App '$BillingAppId' non risulta installata sull'Enterprise '$enterprise' (serve un'installazione a livello Enterprise con lettura della fatturazione)." }
        $minted = New-AppInstallationToken $api $jwt $install.id $null
        $script:billingInstallToken = $minted.token
        Write-Ok "Token di installazione della GitHub App di fatturazione ($BillingAppId) sull'Enterprise '$enterprise'"
        return $minted.token
    }
    return Get-GitHubUserToken $GitHubToken $api
}

# ------------------------------------------------------------------ esecuzioni e Task lato Azure DevOps (facoltativo)
function Get-AdoCounts {
    if (-not $AdoOrganizationUrl -or -not $AdoProject -or -not $PipelineId) { return $null }
    try {
        $headers = Get-AdoHeaders $Pat
        $projBase = Get-ProjectBaseUrl $AdoOrganizationUrl.TrimEnd('/') $AdoProject
        $runs = Invoke-Ado -Method GET -Url "$projBase/_apis/pipelines/$PipelineId/runs" -Headers $headers
        $end = $toDay.AddDays(1)
        $mine = @(@($runs.value) | Where-Object { $c = ConvertTo-UtcDateTime $_.createdDate; $c -ge $fromDay -and $c -lt $end })
        $wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS 'ado-aw' AND [System.CreatedDate] >= '$($fromDay.ToString('yyyy-MM-dd'))' AND [System.CreatedDate] < '$($end.ToString('yyyy-MM-dd'))'" }
        $found = Invoke-Ado -Method POST -Url "$projBase/_apis/wit/wiql" -Headers $headers -Body $wiql
        return [pscustomobject]@{ Runs = $mine.Count; Done = @($mine | Where-Object { $_.state -eq 'completed' }).Count; Tasks = @($found.workItems).Count }
    } catch {
        Write-Warn "Conteggio esecuzioni/Task non disponibile: $($_.Exception.Message.Split("`n")[0])"
        return $null
    }
}

# ------------------------------------------------------------------ somma delle righe del report attribuite all'App (o all'utente di servizio)
function Show-AppUsage($Rows, [string]$Source) {
    $rows = @($Rows)
    if ($rows.Count -eq 0) { throw 'Il report è vuoto.' }
    $columns = $rows[0].PSObject.Properties.Name
    if ($svcUser) {
        if ($columns -notcontains 'username') { throw "Il report non ha la colonna 'username'." }
        $mine = $rows | Where-Object { $_.username -eq $svcUser }
    } else {
        if ($columns -notcontains 'app_client_id') { throw "Il report non ha la colonna 'app_client_id': usa il report «AI usage» (report_type ai_credit)." }
        $mine = $rows | Where-Object { $_.app_client_id -and (-not $clientId -or $_.app_client_id -eq $clientId) }
    }
    if ($columns -contains 'organization') { $mine = $mine | Where-Object { -not $_.organization -or $_.organization -ieq $org } }
    if ($columns -contains 'date') {
        $mine = $mine | Where-Object { $d = [datetime]::Parse($_.date, [Globalization.CultureInfo]::InvariantCulture).Date; $d -ge $fromDay -and $d -le $toDay }
    }
    $mine = @($mine)
    $credits = 0.0; foreach ($r in $mine) { $credits += (ConvertTo-Number $r.quantity) }
    $withUser = @($mine | Where-Object { $columns -contains 'username' -and $_.username }).Count
    $counts = Get-AdoCounts

    if ($svcUser) { Write-Host "`n═══ AI Credits dell'utente di servizio ($Source) ═══" -ForegroundColor Cyan }
    else { Write-Host "`n═══ AI Credits attribuiti alla GitHub App ($Source) ═══" -ForegroundColor Cyan }
    Write-Host ("  Organizzazione GitHub (fatturata) : {0}" -f $org)
    if ($enterprise -and $target.IsGhe) { Write-Host ("  Enterprise (GHE.com)              : {0}" -f $enterprise) }
    if ($svcUser) { Write-Host ("  Utente di servizio                : {0}" -f $svcUser) }
    else { Write-Host ("  App (client id)                   : {0}" -f $(if ($clientId) { $clientId } else { '(tutte le app)' })) }
    Write-Host ("  Periodo                           : {0}" -f $windowLabel)
    Write-Host ("  Righe attribuite                  : {0}" -f $mine.Count)
    if ($counts) { Write-Host ("  Esecuzioni ado-aw nel periodo     : {0} avviate, {1} completate · Task creati: {2}" -f $counts.Runs, $counts.Done, $counts.Tasks) }
    Write-Host ("  AI Credits consumati              : {0}  (≈ {1})" -f (Format-Credits $credits), (Format-Usd $credits)) -ForegroundColor Green
    if ($counts -and $counts.Runs -gt 0) { Write-Host ("  Media per esecuzione              : {0} AI Credits" -f (Format-Credits ($credits / $counts.Runs))) -ForegroundColor Green }
    if (-not $svcUser) {
        Write-Host ("  Righe con username                : {0}  {1}" -f $withUser, $(if ($withUser -eq 0) { '→ nessun utente addebitato' } else { '→ attenzione: verifica queste righe' }))
    } else {
        Write-Host "  Chi ha fatto il commit non compare: l'unico utente addebitato è l'utente di servizio (licenza Copilot dell'Enterprise)." -ForegroundColor DarkGray
    }
    $mine | Group-Object model | Sort-Object Name | ForEach-Object {
        $sum = 0.0; foreach ($r in $_.Group) { $sum += (ConvertTo-Number $r.quantity) }
        Write-Host ("     modello {0,-22} {1,10}" -f $(if ($_.Name) { $_.Name } else { '(non indicato)' }), (Format-Credits $sum))
    }
    if ($mine.Count -eq 0) { Write-Warn 'Nessuna riga nel periodo: il dato di fatturazione può comparire con ritardo (attendi qualche minuto e rilancia) oppure client id, organizzazione o periodo non coincidono.' }
    if ($target.IsGhe) { Write-Host "`n  Data residency: con la policy «Restrict Copilot to data residency compliant models» attiva i crediti includono +10%." -ForegroundColor DarkGray }
}

# ------------------------------------------------------------------ report di utilizzo via REST (crea -> attende -> scarica)
function Get-AiCreditReportRows([string]$Token) {
    $base = "$api/enterprises/$([uri]::EscapeDataString($enterprise))/settings/billing/reports"
    $body = @{ report_type = 'ai_credit'; start_date = $fromDay.ToString('yyyy-MM-dd'); end_date = $toDay.ToString('yyyy-MM-dd') }
    Write-Step "Report di utilizzo AI credits dal $($body.start_date) al $($body.end_date) (REST)"
    $report = Invoke-GitHub -Method POST -Url $base -Token $Token -Body $body -ApiVersion '2026-03-10'
    Write-Ok "Richiesta accettata (report $($report.id))"
    $deadline = (Get-Date).AddMinutes($ReportTimeoutMinutes)
    while ($report.status -eq 'processing') {
        if ((Get-Date) -gt $deadline) { throw "Il report non è pronto dopo $ReportTimeoutMinutes minuti (id $($report.id)): riprova più tardi con GET $base/$($report.id)." }
        Start-Sleep -Seconds 5
        $report = Invoke-GitHub -Url "$base/$($report.id)" -Token $Token -ApiVersion '2026-03-10'
    }
    if ($report.status -ne 'completed') { throw "Generazione del report non riuscita (stato '$($report.status)')." }
    $urls = @(Get-Prop $report 'download_urls')
    if (-not $urls.Count) { throw 'Il report è completato ma senza indirizzi di download.' }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($url in $urls) {
        # gli indirizzi sono di norma firmati: prima senza credenziali, poi (se rifiutati) con il token
        $response = Invoke-WebRequest -Uri $url -SkipHttpErrorCheck -UseBasicParsing
        if ([int]$response.StatusCode -in 400, 401, 403) {
            $response = Invoke-WebRequest -Uri $url -SkipHttpErrorCheck -UseBasicParsing -Headers @{ Authorization = "Bearer $Token"; 'User-Agent' = 'ado-aw-poc' }
        }
        if ([int]$response.StatusCode -ne 200) { throw "Download del report non riuscito (HTTP $([int]$response.StatusCode))." }
        $text = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        foreach ($r in @($text | ConvertFrom-Csv)) { $rows.Add($r) }
    }
    Write-Ok "Scaricate $($rows.Count) righe di utilizzo"
    return , $rows
}

# ------------------------------------------------------------------ riserva: consumo aggregato dell'organizzazione, un giorno alla volta (non distingue l'App)
function Show-AggregateUsage([string]$Token) {
    $days = [int]($toDay - $fromDay).TotalDays + 1
    if ($days -gt 62) { throw "Periodo troppo lungo per il ripiego ($days giorni, massimo 62): riduci -From/-To." }
    $orgEscaped = [uri]::EscapeDataString($org)
    $byModel = [ordered]@{}; $gross = 0.0; $discount = 0.0; $net = 0.0
    for ($d = $fromDay; $d -le $toDay; $d = $d.AddDays(1)) {
        $query = "year=$($d.Year)&month=$($d.Month)&day=$($d.Day)"
        $url = if ($enterprise) { "$api/enterprises/$([uri]::EscapeDataString($enterprise))/settings/billing/ai_credit/usage?$query&organization=$orgEscaped" }
               else { "$api/organizations/$orgEscaped/settings/billing/ai_credit/usage?$query" }
        try { $report = Invoke-GitHub -Url $url -Token $Token -ApiVersion '2026-03-10' }
        catch {
            if ($_.Exception.Message -match 'HTTP (401|403|404)') {
                throw "API dei consumi non accessibile ($($_.Exception.Message.Split("`n")[0])). Serve un enterprise admin / billing manager con un PAT CLASSIC (-GitHubToken, GH_TOKEN o 'gh auth login') oppure una GitHub App di fatturazione (-BillingAppId). In alternativa scarica il CSV «AI usage» e usa -UsageCsv."
            }
            throw
        }
        foreach ($item in @(Get-Prop $report 'usageItems') | Where-Object { $null -ne $_ }) {
            $m = [string](Get-Prop $item 'model'); if (-not $m) { $m = '(modello non indicato)' }
            $g = [double](Get-Prop $item 'grossQuantity'); $gross += $g; $discount += [double](Get-Prop $item 'discountQuantity'); $net += [double](Get-Prop $item 'netQuantity')
            $byModel[$m] = $(if ($byModel.Contains($m)) { $byModel[$m] } else { 0.0 }) + $g
        }
    }
    $counts = Get-AdoCounts
    Write-Host "`n═══ AI Credits dell'organizzazione — consumo AGGREGATO (non solo l'App) ═══" -ForegroundColor Cyan
    Write-Host ("  Organizzazione GitHub (fatturata) : {0}" -f $org)
    if ($enterprise -and $target.IsGhe) { Write-Host ("  Enterprise (GHE.com)              : {0}" -f $enterprise) }
    Write-Host ("  Periodo                           : {0}" -f $windowLabel)
    if ($counts) { Write-Host ("  Esecuzioni ado-aw nel periodo     : {0} avviate, {1} completate · Task creati: {2}" -f $counts.Runs, $counts.Done, $counts.Tasks) }
    Write-Host ("  AI Credits consumati (org)        : {0}  (≈ {1})" -f (Format-Credits $gross), (Format-Usd $gross)) -ForegroundColor Green
    Write-Host ("     coperti dal pool incluso       : {0}" -f (Format-Credits $discount))
    Write-Host ("     fatturati (a consumo)          : {0}" -f (Format-Credits $net))
    if ($counts -and $counts.Runs -gt 0) { Write-Host ("  Media per esecuzione              : {0} AI Credits" -f (Format-Credits ($gross / $counts.Runs))) -ForegroundColor Green }
    foreach ($m in $byModel.Keys) { Write-Host ("     modello {0,-22} {1,10}" -f $m, (Format-Credits $byModel[$m])) }
    if ($gross -le 0) { Write-Warn 'Nessun consumo nel periodo: il dato di fatturazione può comparire con ritardo. Attendi qualche minuto e rilancia.' }
    Write-Host "`n  Attenzione: è il consumo di TUTTA l'organizzazione nel periodo (tutti gli utenti e tutte le App), non solo della GitHub App." -ForegroundColor DarkGray
    Write-Host '  Per l''attribuzione esatta all''App serve il report (endpoint dei report) oppure il CSV «AI usage» con -UsageCsv.' -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ CSV scaricato a mano
if ($UsageCsv) {
    if (-not (Test-Path $UsageCsv)) { throw "CSV non trovato: $UsageCsv" }
    Show-AppUsage @(Import-Csv $UsageCsv) 'da CSV'
    return
}

# ------------------------------------------------------------------ report REST, con riserva sull'aggregato
$token = $null
try {
    $token = Get-BillingToken
    if (-not $enterprise) { throw 'ENTERPRISE_UNKNOWN' }
    Show-AppUsage (Get-AiCreditReportRows $token) 'report REST'
} catch {
    $message = $_.Exception.Message
    $unavailable = $message -match 'HTTP 404' -or $message -eq 'ENTERPRISE_UNKNOWN'
    if (-not $unavailable -or $NoFallback) { throw }
    if ($message -eq 'ENTERPRISE_UNKNOWN') { Write-Warn "Enterprise non nota (github.com senza -GitHubEnterprise): l'endpoint dei report è a livello Enterprise." }
    else { Write-Warn "L'endpoint dei report non è disponibile su questo tenant (HTTP 404): uso il consumo aggregato dell'organizzazione." }
    Show-AggregateUsage $(if ($token) { $token } else { Get-BillingToken })
} finally {
    if ($script:billingInstallToken) { Remove-AppInstallationToken $api $script:billingInstallToken }
}
