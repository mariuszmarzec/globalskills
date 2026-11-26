from datetime import datetime, timezone


def register_user(data, database, mailer):
    name = data.get("name", "").strip()
    email = data.get("email", "").strip().lower()
    if not name:
        raise ValueError("name is required")
    if "@" not in email or email.startswith("@") or email.endswith("@"):
        raise ValueError("email is invalid")

    user = {
        "name": name,
        "email": email,
        "created_at": datetime.now(timezone.utc),
    }
    database.insert(user)
    mailer.send_welcome(email)
    return user
