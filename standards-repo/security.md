# Sicurezza

## SEC-001 — Nessun segreto nel codice sorgente

- **Severità**: Alta
- **Ambito**: qualsiasi file versionato (codice, configurazioni, script)
- **Regola**: password, chiavi API, token e connection string con credenziali non devono essere scritti nel codice. I valori sensibili si leggono da variabili d'ambiente o da Azure Key Vault.
- **Come verificare**: valori letterali assegnati a nomi come `password`, `secret`, `token`, `api_key`, oppure connection string che contengono `Password=` o `pwd=`.
- **Conforme**: `password = os.environ["DB_PASSWORD"]`
- **Non conforme**: `password = "Rpt-Passw0rd-2024"`

## SEC-002 — Query parametrizzate

- **Severità**: Alta
- **Ambito**: codice che accede a un database
- **Regola**: le query SQL non si costruiscono concatenando o formattando stringhe con dati esterni. Si usano sempre parametri (`?`, `%s`, `@nome`) o un ORM.
- **Come verificare**: istruzioni SQL costruite con `+`, f-string, `.format()` o `%` che includono variabili.
- **Conforme**: `conn.execute("SELECT * FROM orders WHERE id = ?", (order_id,))`
- **Non conforme**: `conn.execute("SELECT * FROM orders WHERE name = '" + name + "'")`
