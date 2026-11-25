# Test automatici

## TST-001 — Ogni funzione pubblica nuova ha test

- **Severità**: Media
- **Ambito**: funzioni e metodi pubblici (senza prefisso `_`) aggiunti o modificati nella Pull Request
- **Regola**: ogni funzione pubblica nuova o con comportamento modificato deve essere coperta da almeno un test automatico nella stessa Pull Request, nella cartella `tests/`.
- **Come verificare**: per ogni `def` pubblica aggiunta in `src/`, cercare un test che la richiami in `tests/`. Se nel diff non compare alcun file di test che la copre, la regola è violata.
- **Conforme**: `src/orders/totals.py` accompagnato da `tests/test_totals.py`
- **Non conforme**: nuovo modulo in `src/` senza alcun file in `tests/`
