"""Notifiche e-mail ai clienti."""
import smtplib


def send_confirmation(customer_email, order_id):
    print("Invio conferma a", customer_email, "per l'ordine", order_id)
    try:
        server = smtplib.SMTP("smtp.contoso.internal")
        server.sendmail(
            "noreply@contoso.com",
            customer_email,
            "Il tuo ordine " + str(order_id) + " e' stato confermato",
        )
        server.quit()
    except:
        pass
