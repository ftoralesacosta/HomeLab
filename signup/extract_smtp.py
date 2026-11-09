"""One-shot: build signup/smtp.env from the live config + .env.

Runs as root in a container (the files are root-owned 600). Prints nothing
sensitive: only a confirmation.
"""
import os
import re

import yaml


def load_env(p):
    d = {}
    for line in open(p):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.strip())
        if m:
            d[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return d


env = load_env("/ro/.env")
cfg = yaml.safe_load(open("/ro/authelia/configuration.yml"))
smtp = cfg["notifier"]["smtp"]
users = yaml.safe_load(open("/ro/authelia/auth_file.yml"))["users"]
me = next(v for k, v in users.items() if k.lower() == "fernando")

from urllib.parse import urlparse
p = urlparse(smtp["address"])  # e.g. submission://smtp.gmail.com:587
tls = {"smtps": "ssl", "submission": "starttls", "smtp": "starttls"}.get(p.scheme, "none")

out = (
    f"SMTP_HOST={p.hostname}\n"
    f"SMTP_PORT={p.port}\n"
    f"SMTP_TLS={tls}\n"
    f"SMTP_USER={smtp['username']}\n"
    f"SMTP_PASS={env['GMAIL_APP_PASSWORD']}\n"
    f"MAIL_FROM={smtp.get('sender') or smtp['username']}\n"
    f"NOTIFY_TO={me['email']}\n"
)
p = "/out/smtp.env"
open(p, "w").write(out)
os.chmod(p, 0o600)
os.chown(p, 1000, 1000)
print("smtp.env written (7 values, none printed)")