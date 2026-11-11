"""Self-service signup for Authelia (file backend).

The public front door (NOT behind the Authelia gate). A newcomer picks their
own username/email/password -> appended to the Authelia users file with group
[pending] -> Authelia picks it up by itself (authentication_backend.file.watch)
-> approval email to the admin. Pending users can only log in to the portal;
access_control (default deny) and the OIDC "approved" policy keep them out of
every app until ~/HomeLab/authelia/approve-user.sh moves them to a real group.

Deliberately small attack surface: no Docker socket, runs as uid 1000 with a
read-only root fs; the only writable thing is the users directory
(./authelia/users mounted at /data).
"""
import fcntl
import ipaddress
import os
import re
import smtplib
import tempfile
import time
from email.message import EmailMessage
from html import escape

import argon2
import yaml
from flask import Flask, request

USERS_FILE = "/data/auth_file.yml"
LOCK_FILE = "/data/.signup.lock"
SMTP_ENV = "/etc/signup/smtp.env"
DOMAIN = "ftoralesacosta.me"

USERNAME_RE = re.compile(r"^[a-z0-9._-]{3,32}$")
EMAIL_RE = re.compile(r"^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")

PER_IP_PER_HOUR = 3        # per real client IP
GLOBAL_PER_HOUR = 10       # all clients together (rotating-IP spam cap)
MAX_PENDING = 15           # stop accepting while this many await approval

# Cloudflare edge ranges (https://www.cloudflare.com/ips/). Only when the TCP
# peer that NPM saw (X-Real-IP) is one of these do we trust CF-Connecting-IP;
# a direct-to-origin request could otherwise forge it.
CF_NETS = [ipaddress.ip_network(n) for n in (
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
    "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32",
    "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32",
)]

# Same parameters Authelia 4.39 uses by default for argon2id.
PH = argon2.PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4,
                           hash_len=32, salt_len=16)
app = Flask(__name__)

_hits = {}      # ip -> [timestamps]
_global = []    # timestamps


def client_ip():
    peer = request.headers.get("X-Real-IP") or request.remote_addr or "?"
    try:
        if any(ipaddress.ip_address(peer) in n for n in CF_NETS):
            return request.headers.get("CF-Connecting-IP") or peer
    except ValueError:
        pass
    return peer


def rate_limited(ip):
    now = time.time()
    _global[:] = [t for t in _global if now - t < 3600]
    w = [t for t in _hits.get(ip, []) if now - t < 3600]
    if len(w) >= PER_IP_PER_HOUR or len(_global) >= GLOBAL_PER_HOUR:
        return True
    w.append(now)
    _hits[ip] = w
    _global.append(now)
    return False


def load_smtp():
    env = {}
    with open(SMTP_ENV) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


class SignupError(Exception):
    """Message is safe to show to the user."""


def add_user(username, email, password_hash):
    """Append a [pending] user under an exclusive lock, atomically."""
    with open(LOCK_FILE, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(USERS_FILE) as f:
            text = f.read()
        users = (yaml.safe_load(text) or {}).get("users") or {}
        if username in {k.lower() for k in users}:
            raise SignupError("That username is already taken.")
        if email in {str(v.get("email", "")).lower() for v in users.values()}:
            raise SignupError("That email is already in use.")
        pending = sum(1 for v in users.values() if "pending" in (v.get("groups") or []))
        if pending >= MAX_PENDING:
            raise SignupError("Signups are paused right now. Try again later.")

        entry = (
            f"    {username}:\n"
            f"        password: \"{password_hash}\"\n"
            f"        displayname: \"{username}\"\n"   # required by Authelia's schema
            f"        email: {email}\n"
            f"        groups: [pending]\n"
            f"        disabled: false\n"
        )
        new = text if text.endswith("\n") else text + "\n"
        new += entry
        check = yaml.safe_load(new)["users"][username]
        if check.get("groups") != ["pending"] or check.get("email") != email:
            raise RuntimeError("generated entry did not round-trip")

        st = os.stat(USERS_FILE)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(USERS_FILE), prefix=".auth_file.")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(new)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, st.st_mode & 0o777)
            os.replace(tmp, USERS_FILE)   # Authelia's file watcher reloads it
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise


def notify_admin(username, email):
    e = load_smtp()
    msg = EmailMessage()
    msg["From"] = e.get("MAIL_FROM") or e["SMTP_USER"]
    msg["To"] = e["NOTIFY_TO"]
    msg["Subject"] = f"Authelia signup request: {username}"
    msg.set_content(
        "New signup request (awaiting approval):\n\n"
        f"  Username: {username}\n"
        f"  Email:    {email} (NOT verified - anyone can type any address)\n"
        f"  Time (UTC):   {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime())}\n\n"
        "The account exists with their chosen password and group [pending]:\n"
        f"  - they can already log in to https://auth.{DOMAIN} (portal only: set 2FA/passkey)\n"
        "  - they are denied everywhere else (apps and OIDC) until you approve them\n\n"
        "Approve:\n"
        f"  ~/HomeLab/authelia/approve-user.sh {username}            # group: family\n"
        f"  ~/HomeLab/authelia/approve-user.sh {username} friends    # Open WebUI only\n"
    )
    tls = e.get("SMTP_TLS", "starttls")
    port = int(e["SMTP_PORT"])
    if tls == "ssl":
        s = smtplib.SMTP_SSL(e["SMTP_HOST"], port, timeout=30)
    else:
        s = smtplib.SMTP(e["SMTP_HOST"], port, timeout=30)
        if tls == "starttls":
            s.starttls()
    try:
        s.login(e["SMTP_USER"], e["SMTP_PASS"])
        s.send_message(msg)
    finally:
        s.quit()


PAGE_TMPL = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Request access - __DOMAIN__</title>
<style>
 body{font-family:system-ui,sans-serif;background:#f5f6f8;color:#222;margin:0;padding:2rem 1rem}
 .card{max-width:26rem;margin:0 auto;background:#fff;border:1px solid #e2e4e9;border-radius:10px;padding:1.8rem;box-shadow:0 1px 3px rgba(0,0,0,.06)}
 h1{font-size:1.25rem;margin:0 0 .3rem} p.sub{color:#5a6270;font-size:.9rem;margin:0 0 1.2rem}
 label{display:block;font-size:.85rem;font-weight:600;margin:.8rem 0 .2rem}
 input{width:100%;box-sizing:border-box;padding:.55rem .65rem;border:1px solid #cdd1d6;border-radius:6px;font-size:1rem}
 button{width:100%;margin-top:1.2rem;padding:.65rem;background:#2f6fed;color:#fff;border:0;border-radius:6px;font-size:1rem;font-weight:600;cursor:pointer}
 button:hover{background:#255cd0}
 .err{background:#fdecec;color:#a1252b;border:1px solid #f3c1c3;border-radius:6px;padding:.6rem .8rem;font-size:.9rem;margin-bottom:.4rem}
 .note{font-size:.8rem;color:#5a6270;margin-top:1rem}
</style></head><body>
<div class="card">
 <h1>Request access</h1>
 <p class="sub">Fill this in once. You will get access after it is approved.</p>
 __ERROR__
 <form method="post">
  <label>Username (lowercase, no spaces)</label>
  <input name="username" required pattern="[a-z0-9._-]{3,32}" value="__USERNAME__">
  <label>Email</label>
  <input name="email" type="email" required value="__EMAIL__">
  <label>Password (at least 10 characters)</label>
  <input name="password" type="password" required minlength="10">
  <label>Repeat password</label>
  <input name="password2" type="password" required minlength="10">
  <button type="submit">Request access</button>
 </form>
 <p class="note">You will be able to log in at <b>auth.__DOMAIN__</b> right away (profile and
 2FA setup); the rest unlocks after approval.</p>
</div></body></html>
"""

SUCCESS_TMPL = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Request sent - __DOMAIN__</title>
<style>
 body{font-family:system-ui,sans-serif;background:#f5f6f8;color:#222;margin:0;padding:2rem 1rem}
 .card{max-width:26rem;margin:0 auto;background:#fff;border:1px solid #e2e4e9;border-radius:10px;padding:1.8rem;text-align:center;box-shadow:0 1px 3px rgba(0,0,0,.06)}
 .big{font-size:2.6rem;margin:.4rem 0} h1{font-size:1.25rem} p{color:#5a6270;font-size:.92rem}
 b{color:#222}
</style></head><body>
<div class="card"><div class="big">&#9989;</div>
 <h1>Request sent</h1>
 <p>Your account <b>__USERNAME__</b> was created. As soon as it is approved you can log in at
 <b>auth.__DOMAIN__</b> with the password you just chose. You can already set up two-factor
 authentication there if you like.</p>
</div></body></html>
"""


def render_page(error=None, old=None):
    o = old or {}
    h = PAGE_TMPL.replace("__DOMAIN__", DOMAIN)
    h = h.replace("__ERROR__", f'<div class="err">{escape(error)}</div>' if error else "")
    h = h.replace("__USERNAME__", escape(o.get("username", "")))
    h = h.replace("__EMAIL__", escape(o.get("email", "")))
    return h


def render_success(username):
    return SUCCESS_TMPL.replace("__DOMAIN__", DOMAIN).replace("__USERNAME__", escape(username))


@app.after_request
def headers(resp):
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'"
    resp.headers["Referrer-Policy"] = "no-referrer"
    return resp


@app.get("/healthz")
def healthz():
    return "ok"


@app.get("/")
def index():
    return render_page()


@app.post("/")
def submit():
    f = request.form
    u = (f.get("username") or "").strip().lower()
    e = (f.get("email") or "").strip().lower()
    p1, p2 = f.get("password") or "", f.get("password2") or ""
    old = {"username": u, "email": e}

    err = None
    if not USERNAME_RE.match(u):
        err = "Username: 3-32 characters, lowercase letters, digits, dot, underscore, dash."
    elif not EMAIL_RE.match(e):
        err = "Enter a valid email address."
    elif len(p1) < 10:
        err = "Password: at least 10 characters."
    elif len(p1) > 256:
        err = "Password: at most 256 characters."
    elif p1 != p2:
        err = "Passwords do not match."
    if err:
        return render_page(error=err, old=old)

    if rate_limited(client_ip()):
        return render_page(error="Too many requests. Try again later.", old=old), 429

    try:
        add_user(u, e, PH.hash(p1))
    except SignupError as ex:
        return render_page(error=str(ex), old=old)
    except Exception:
        app.logger.exception("signup failed")
        return render_page(
            error="Something went wrong on our side; nothing was created. Try again later.",
            old=old), 500

    try:
        notify_admin(u, e)
    except Exception:
        app.logger.exception("approval email failed (account was created)")
    return render_success(u)
