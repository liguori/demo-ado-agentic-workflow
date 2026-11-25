#Requires -Version 7.0
<#
.SYNOPSIS
    Smoke test di due minuti, senza Azure DevOps: la Copilot CLI funziona con il token della GitHub App su questo tenant?

.DESCRIPTION
    Riproduce in locale ciò che farà la pipeline: conia il token di installazione dell'App (permesso "Copilot Requests"),
    lo passa alla Copilot CLI 1.0.114 come GITHUB_TOKEN (con COPILOT_GH_HOST se il tenant è su GHE.com) e chiede una risposta di
    una parola al modello scelto. Verifica quindi, in una volta sola, le tre ipotesi che dipendono dal tenant:
      1. la preview "Copilot da GitHub App" è abilitata (altrimenti: 403 "not enabled");
      2. la CLI accetta il token di installazione e lo instrada sul tenant (copilot-api.<tenant>.ghe.com);
      3. il modello è disponibile nella regione (con la policy "Restrict Copilot to data residency compliant models").
    Con -NegativeModel prova anche un modello FUORI regione: deve essere rifiutato (prova che la policy è applicata).
    Su GHE.com elenca inoltre gli host contattati dalla CLI (dal suo log di debug): deve esserci il tenant; api.github.com compare sempre
    (chiamata d'avvio non essenziale, segnalata come nota); qualunque altro endpoint pubblico GitHub/Copilot è un errore.

    Costo: una richiesta da pochi token (frazione di AI Credit, attribuita all'organizzazione via App). La prova negativa e
    -SkipModelCall non consumano crediti. Non serve Azure DevOps.

    Piano B (-AuthMode Pat): stesso test con il PAT dell'utente di servizio (fine-grained, "Copilot Requests", licenza Copilot).

.EXAMPLE
    ./Test-CopilotAccess.ps1 -GitHubHost contoso.ghe.com -GitHubOrg contoso-org -GitHubAppId 1234567 -PrivateKeyPath ./app.pem -NegativeModel grok-4.6
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GitHubOrg,
    [string]$GitHubHost,
    [string]$GitHubApiUrl,
    [ValidateSet('App', 'Pat')][string]$AuthMode = 'App',
    [string]$GitHubAppId,
    [string]$PrivateKeyPath,
    [string]$GitHubPat,
    [string]$Model,
    [string]$NegativeModel,
    [string]$CopilotVersion = '1.0.114',
    [string]$CopilotPath,
    [int]$TimeoutSeconds = 150,
    [switch]$NoModelSearch,
    [switch]$SkipModelCall
)

. "$PSScriptRoot/PocCommon.ps1"

$target = Get-GitHubTarget $GitHubHost $GitHubApiUrl
$api = $target.ApiUrl
if (-not $Model) { $Model = Get-DefaultModel $target.IsGhe }
$workingModel = $null
# Se il modello richiesto non è disponibile si provano questi (presenti sia nella regione US sia in quella UE); i non disponibili non costano nulla.
$candidateModels = @('gpt-4.1', 'gpt-4o-mini', 'gpt-5.2', 'claude-haiku-4.5', 'claude-sonnet-5', 'gpt-5.3-codex', 'auto')
$knownStartupHosts = @('api.github.com')   # la CLI lo contatta sempre all'avvio, prima dell'autenticazione; negato dal firewall, la CLI prosegue
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, $Ok, [string]$Detail) { $script:results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail }) }

function Get-CopilotFailureHint([string]$Text) {
    switch -Regex ($Text) {
        'not enabled|installation access token'       { return 'La preview "Copilot da GitHub App" non è abilitata per questa organizzazione/tenant: chiedi l''abilitazione all''account team GitHub, oppure usa il Piano B (-AuthMode Pat).' }
        'Model .* (is )?not available|not available'   { return "Il modello '$Model' non è disponibile per l'organizzazione: controlla la policy dei modelli e l'elenco della regione (US/UE)." }
        'ENOTFOUND|dns error|No such host'             { return "Il tenant non è raggiungibile (DNS): controlla -GitHubHost e la rete." }
        '403'                                           { return 'Accesso negato: l''installazione non ha il permesso "Copilot Requests" (organizzazione) oppure l''IP allow list dell''Enterprise blocca questa postazione.' }
        'Authentication failed|401|Not authenticated|No authentication' { return 'Token rifiutato: scaduto, non valido o tipo non accettato dalla CLI. Rilancia; se persiste prova una CLI più recente (-CopilotVersion).' }
        default                                         { return $null }
    }
}

function Invoke-CopilotProbe {
    param([string]$Exe, [string]$Token, [string]$ProbeModel, [string]$Prompt)
    $work = Join-Path ([IO.Path]::GetTempPath()) ('copilot-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $logDir = Join-Path $work 'logs'; $homeDir = Join-Path $work 'home'; $cwd = Join-Path $work 'cwd'
    New-Item -ItemType Directory -Force -Path $logDir, $homeDir, $cwd | Out-Null
    $copilotArgs = @('-p', $Prompt, '--model', $ProbeModel, '--no-ask-user', '--disable-builtin-mcps', '--silent', '--log-level', 'debug', '--log-dir', $logDir)
    $psi = if ($Exe.EndsWith('.ps1')) {
        $p = [System.Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        foreach ($a in @('-NoProfile', '-File', $Exe) + $copilotArgs) { [void]$p.ArgumentList.Add($a) }
        $p
    } else {
        $p = [System.Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($a in $copilotArgs) { [void]$p.ArgumentList.Add($a) }
        $p
    }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $cwd   # cartella vuota e senza repository: nessun contatto non voluto con github.com
    # Come in pipeline: solo GITHUB_TOKEN (+ host). Nessun altro token o credenziale salvata deve interferire.
    foreach ($k in 'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN', 'GH_HOST', 'COPILOT_GH_HOST', 'GITHUB_ENTERPRISE_TOKEN') { [void]$psi.Environment.Remove($k) }
    $psi.Environment['GITHUB_TOKEN'] = $Token
    if ($target.IsGhe) { $psi.Environment['COPILOT_GH_HOST'] = $target.Host }
    $psi.Environment['COPILOT_HOME'] = $homeDir
    $psi.Environment['COPILOT_AUTO_UPDATE'] = 'false'
    $psi.Environment['NO_COLOR'] = '1'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync(); $stderr = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { try { $proc.Kill($true) } catch { } }
    $clock.Stop()
    $text = (([string]$stdout.Result) + "`n" + ([string]$stderr.Result)).Trim()
    $hosts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($log in @(Get-ChildItem $logDir -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue)) {
        $content = [IO.File]::ReadAllText($log.FullName)
        foreach ($m in [regex]::Matches($content, "starting new connection 'Some\(""([^""]+)""\)'")) { [void]$hosts.Add($m.Groups[1].Value) }
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $proc.ExitCode }); TimedOut = $timedOut; Output = $text; Seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1); Hosts = @($hosts | Sort-Object) }
}

# ------------------------------------------------------------------ destinazione
Write-Step 'Destinazione GitHub'
if ($target.IsGhe) { Write-Ok "GHE.com (data residency, utenti EMU): tenant $($target.Host) · API $api" }
else { Write-Ok "github.com · API $api" }

# ------------------------------------------------------------------ credenziale GitHub
$token = $null
$installationToken = $null
if ($AuthMode -eq 'App') {
    Write-Step "Token della GitHub App per l'organizzazione '$GitHubOrg'"
    if (-not $GitHubAppId -or -not $PrivateKeyPath) { throw 'Con -AuthMode App servono -GitHubAppId e -PrivateKeyPath.' }
    if (-not (Test-Path $PrivateKeyPath)) { throw "File della chiave privata non trovato: $PrivateKeyPath" }
    $pem = (Get-Content $PrivateKeyPath -Raw).Trim()
    $found = Get-AppInstallation $api $GitHubAppId $pem $GitHubOrg
    if (-not $found) { throw "La GitHub App '$GitHubAppId' non risulta installata sull'organizzazione '$GitHubOrg' (o l'App ID è errato)." }
    Write-Ok "App '$(Get-Prop $found.Installation 'app_slug')' installata sull'organizzazione (installation $($found.Installation.id))"
    try {
        $minted = New-AppInstallationToken $api $found.Jwt $found.Installation.id @{ organization_copilot_requests = 'read' }
        $installationToken = $minted.token
        $token = $minted.token
        Write-Ok "Token di installazione con 'Copilot Requests' (read) emesso da $(([uri]$api).Host), valido 1 ora"
        Add-Result 'GitHub App installata e con permesso "Copilot Requests"' $true "installation $($found.Installation.id)"
    } catch {
        $message = $_.Exception.Message.Split("`n")[0]
        Write-Warn "Token con 'Copilot Requests' non emesso: $message"
        Write-Warn 'L''installazione non ha il permesso (aggiungilo all''App e riapprova), oppure il tenant non espone ancora il permesso (preview).'
        Add-Result 'GitHub App installata e con permesso "Copilot Requests"' $false $message
    }
} else {
    Write-Step 'Credenziale dell''utente di servizio (PAT)'
    $token = if ($GitHubPat) { $GitHubPat } else { $env:POC_GITHUB_PAT }
    if (-not $token) { throw "Con -AuthMode Pat serve -GitHubPat oppure la variabile d'ambiente POC_GITHUB_PAT." }
    $me = Invoke-GitHub -Url "$api/user" -Token $token
    Write-Ok "PAT valido per l'utente '$(Get-Prop $me 'login')'"
    Add-Result 'PAT dell''utente di servizio valido' $true (Get-Prop $me 'login')
}

# ------------------------------------------------------------------ richiesta a Copilot
if ($SkipModelCall) {
    Write-Warn 'Richiesta a Copilot saltata (-SkipModelCall): verificato solo il token.'
} elseif (-not $token) {
    Write-Warn 'Nessun token disponibile: salto la richiesta a Copilot.'
} else {
    try {
        Write-Step "Copilot CLI $CopilotVersion"
        $exe = if ($CopilotPath) { $CopilotPath } else { Get-CopilotCli $CopilotVersion }
        Write-Ok "Uso $exe"

        Write-Step "Richiesta di prova a Copilot (modello $Model)"
        $probe = Invoke-CopilotProbe -Exe $exe -Token $token -ProbeModel $Model -Prompt 'Reply with exactly the single word OK and nothing else.'
        if ($probe.ExitCode -eq 0 -and $probe.Output -match '\bOK\b') {
            Write-Ok "Risposta ricevuta in $($probe.Seconds) s: «$(($probe.Output -split "`n" | Select-Object -First 1).Trim())»"
            Add-Result "Copilot accetta il token e il modello '$Model'" $true "$($probe.Seconds) s"
            Save-VerifiedModel $Model $target $GitHubOrg
        } else {
            $firstLines = ($probe.Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' | '
            Write-Warn "Richiesta non riuscita (exit $($probe.ExitCode)$(if ($probe.TimedOut) { ', timeout' })): $firstLines"
            $hint = Get-CopilotFailureHint $probe.Output
            if ($hint) { Write-Warn $hint }
            $alt = $null
            if ($probe.Output -match 'not available' -and -not $NoModelSearch) {
                Write-Step "Cerco un modello utilizzabile (i modelli non disponibili non costano nulla)"
                foreach ($cand in @($candidateModels | Where-Object { $_ -ne $Model })) {
                    $try = Invoke-CopilotProbe -Exe $exe -Token $token -ProbeModel $cand -Prompt 'Reply with exactly the single word OK and nothing else.'
                    if ($try.ExitCode -eq 0 -and $try.Output -match '\bOK\b') { $alt = $cand; $probe = $try; Write-Ok "'$cand': funziona ($($try.Seconds) s)"; break }
                    Write-Note "'$cand': non disponibile"
                }
            }
            if ($alt) {
                $workingModel = $alt
                Save-VerifiedModel $alt $target $GitHubOrg
                Write-Warn "'$Model' non è utilizzabile con questa organizzazione, '$alt' sì: lo userà in automatico Setup-Poc.ps1 (salvato in .poc-state.json). Per usare '$Model' abilitalo nelle policy Copilot dell'organizzazione/Enterprise (i modelli di alcuni fornitori, come Anthropic, hanno una policy dedicata) e rilancia questo test."
                if ($alt -eq 'auto') { Write-Warn "'auto' lascia scegliere il modello a Copilot: il costo per esecuzione è meno prevedibile." }
                Add-Result "Copilot accetta il token e un modello della regione ('$alt'; '$Model' non disponibile)" $true "$($probe.Seconds) s"
            } else {
                if ($probe.Output -match 'not available' -and -not $NoModelSearch) {
                    Write-Warn "Nessuno dei modelli provati è disponibile: nelle policy Copilot dell'organizzazione/Enterprise abilita almeno un modello della regione (es. GPT-4.1 o Claude Haiku 5.5) e rilancia."
                }
                Add-Result "Copilot accetta il token e il modello '$Model'" $false $firstLines
            }
        }
        if ($probe.Hosts.Count) {
            Write-Note "Host contattati dalla CLI: $($probe.Hosts -join ', ')"
            if ($target.IsGhe -and $probe.ExitCode -eq 0) {
                $outside = @($probe.Hosts | Where-Object { $_ -match '(^|\.)(github\.com|githubcopilot\.com|githubusercontent\.com|githubassets\.com)$' -and $_ -ne $target.Host -and -not $_.EndsWith(".$($target.Host)") })
                $startup = @($outside | Where-Object { $_ -in $knownStartupHosts })
                $public = @($outside | Where-Object { $_ -notin $knownStartupHosts })
                if ($public.Count -eq 0) {
                    Write-Ok "Inferenza e autenticazione solo sul tenant ($($target.Host)): nessun altro endpoint pubblico GitHub/Copilot"
                    if ($startup) { Write-Note "$($startup -join ', '): chiamata d'avvio della CLI, non essenziale (provato: se bloccata la CLI prosegue verso il tenant). Nella pipeline, con -StrictResidency, il firewall la blocca." }
                    Add-Result 'Traffico Copilot solo verso il tenant GHE.com' $true ($probe.Hosts -join ', ')
                } else { Write-Warn "Contatti verso endpoint pubblici: $($public -join ', ')"; Add-Result 'Traffico Copilot solo verso il tenant GHE.com' $false ($public -join ', ') }
            }
        }

        if ($NegativeModel) {
            Write-Step "Prova negativa: modello FUORI regione ($NegativeModel) — deve essere rifiutato"
            $neg = Invoke-CopilotProbe -Exe $exe -Token $token -ProbeModel $NegativeModel -Prompt 'Reply with exactly the single word OK and nothing else.'
            if ($neg.ExitCode -ne 0 -and $neg.Output -match 'not available') {
                Write-Ok "Rifiutato come atteso: la policy di data residency limita i modelli alla regione ($(($neg.Output -split "`n" | Select-Object -First 1).Trim()))"
                Add-Result "Modello fuori regione '$NegativeModel' rifiutato" $true 'policy applicata'
            } elseif ($neg.ExitCode -eq 0) {
                Write-Warn "ATTENZIONE: '$NegativeModel' è stato ACCETTATO: la policy «Restrict Copilot to data residency compliant models» non è attiva (o il modello è disponibile nella regione). È stata consumata una richiesta."
                Add-Result "Modello fuori regione '$NegativeModel' rifiutato" $false 'accettato'
            } else {
                $firstLines = ($neg.Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' | '
                Write-Warn "Esito non chiaro: $firstLines"
                Add-Result "Modello fuori regione '$NegativeModel' rifiutato" $false $firstLines
            }
        }
    } finally {
        if ($installationToken) { Remove-AppInstallationToken $api $installationToken }
    }
}
if ($installationToken -and $SkipModelCall) { Remove-AppInstallationToken $api $installationToken }

# ------------------------------------------------------------------ esito
Write-Host "`n═══ Esito smoke test ═══" -ForegroundColor Cyan
foreach ($r in $results) {
    $mark = if ($r.Ok) { '✔' } else { '✘' }
    Write-Host ("  {0} {1}" -f $mark, $r.Name) -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Red' })
}
$failed = @($results | Where-Object { -not $_.Ok })
if ($failed.Count -eq 0 -and $results.Count -gt 0) {
    if ($SkipModelCall) { Write-Host "`n  Token verificato. Manca la prova con la Copilot CLI: rilancia senza -SkipModelCall." -ForegroundColor Yellow; exit 0 }
    Write-Host "`n  Via libera: puoi eseguire Setup-Poc.ps1$(if ($target.IsGhe) { " -GitHubHost $($target.Host)" })$(if ($workingModel) { " (userà in automatico il modello '$workingModel')" })." -ForegroundColor Green
    exit 0
}
Write-Host "`n  Non procedere con Azure DevOps finché i punti ✘ non sono risolti (vedi RIFERIMENTO-POC.md, sezione «Risoluzione dei problemi»)." -ForegroundColor Yellow
exit 1
