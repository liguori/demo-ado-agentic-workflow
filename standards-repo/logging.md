# Logging

## LOG-001 — Logging strutturato, non `print`

- **Severità**: Bassa
- **Ambito**: codice applicativo (esclusi script una tantum e test)
- **Regola**: i messaggi diagnostici passano dal modulo `logging` con un livello appropriato. `print()` non è ammesso nel codice applicativo.
- **Come verificare**: chiamate a `print(` fuori da `tests/` e da script dichiarati come tali.
- **Conforme**: `logger.info("order_created", extra={"order_id": order_id})`
- **Non conforme**: `print("ordine creato", order_id)`

## LOG-002 — Nessun dato personale nei log

- **Severità**: Alta
- **Ambito**: qualsiasi messaggio di log o `print`
- **Regola**: indirizzi e-mail, numeri di telefono, nomi e cognomi, indirizzi e codici fiscali non devono comparire nei log. Si registrano identificativi tecnici (es. `customer_id`).
- **Come verificare**: variabili o campi come `email`, `phone`, `name`, `address`, `tax_id` passati a `logger.*` o `print`.
- **Conforme**: `logger.info("conferma_inviata", extra={"customer_id": customer_id})`
- **Non conforme**: `logger.info(f"conferma inviata a {customer_email}")`
