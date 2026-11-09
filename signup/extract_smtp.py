"""Build signup/smtp.env from the live Authelia config + .env.

Re-run after changing GMAIL_APP_PASSWORD in .env, then: docker compose up -d signup
    python3 ~/HomeLab/signup/extract_smtp.py
Prints nothing sensitive: only a confirmation.
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


HL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = load_env(f"{HL}/.env")
cfg = yaml.safe_load(open(f"{HL}/authelia/configuration.yml"))
smtp = cfg["notifier"]["smtp"]
users = yaml.safe_load(open(f"{HL}/authelia/users/auth_file.yml"))["users"]
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
p = f"{HL}/signup/smtp.env"
open(p, "w").write(out)
os.chmod(p, 0o600)
print("smtp.env written (7 values, none printed)")