import unittest

from registration import register_user


class FakeDatabase:
    def __init__(self):
        self.users = []

    def insert(self, user):
        self.users.append(user)


class FakeMailer:
    def __init__(self):
        self.sent_to = []

    def send_welcome(self, email):
        self.sent_to.append(email)


class RegisterUserTests(unittest.TestCase):
    def test_normalizes_user_and_sends_welcome_message(self):
        database = FakeDatabase()
        mailer = FakeMailer()
        user = register_user(
            {"name": "  Ada Lovelace ", "email": " ADA@EXAMPLE.COM "},
            database,
            mailer,
        )
        self.assertEqual("Ada Lovelace", user["name"])
        self.assertEqual("ada@example.com", user["email"])
        self.assertEqual([user], database.users)
        self.assertEqual(["ada@example.com"], mailer.sent_to)

    def test_invalid_input_does_not_write_or_send(self):
        database = FakeDatabase()
        mailer = FakeMailer()
        with self.assertRaises(ValueError):
            register_user({"name": " ", "email": "bad"}, database, mailer)
        self.assertEqual([], database.users)
        self.assertEqual([], mailer.sent_to)


if __name__ == "__main__":
    unittest.main()
