# Validazione degli input

## VAL-001 — Validare gli input ai confini del sistema

- **Severità**: Media
- **Ambito**: funzioni pubbliche che ricevono dati da utenti, API, file o code
- **Regola**: i parametri provenienti dall'esterno vengono validati (tipo, intervallo, formato) prima dell'uso. Un valore non valido solleva un'eccezione specifica e non produce risultati silenziosamente errati.
- **Come verificare**: funzioni pubbliche che usano un parametro in calcoli o query senza alcun controllo, ad esempio percentuali fuori da 0–100, importi negativi, identificativi vuoti.
- **Conforme**: `if not 0 <= percent <= 100: raise ValueError("percent fuori intervallo")`
- **Non conforme**: `return total * (100 - percent) / 100` senza controllare `percent`
