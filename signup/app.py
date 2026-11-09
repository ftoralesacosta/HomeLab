import os
import re
import smtplib
import time
from email.message import EmailMessage

import argon2
import docker
from flask import Flask, request

AUTHDIR = "/home/fernando/HomeLab/authelia"
IMG = "ghcr.io/authelia/authelia:4.39"
ALPINE = "alpine:3"
SMTP_ENV = "/etc/signup/smtp.env"
DOMAIN = "ftoralesacosta.me"

USERNAME_RE = re.compile(r"^[a-z0-9._-]{3,32}$")
EMAIL_RE = re.compile(r"^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")

PH = argon2.PasswordHasher()
DK = docker.from_env()
app = Flask(__name__)

_rl = {}


def rate_limited(ip):
    now = time.time()
    w = [t for t in _rl.get(ip, []) if now - t < 3600]
    if len(w) >= 3:
        return True
    w.append(now)
    _rl[ip] = w
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


def root_check(pattern):
    try:
        DK.containers.run(
            ALPINE, ["sh", "-c", f"grep -qE -- '{pattern}' /a/auth_file.yml"],
            remove=True, volumes={AUTHDIR: {"bind": "/a", "mode": "ro"}},
        )
        return True
    except docker.errors.ContainerError:
        return False


def root_append(text):
    import base64
    b64 = base64.b64encode(text.encode()).decode()
    DK.containers.run(
        ALPINE, ["sh", "-c", "printf '%s' \"$B64\" | base64 -d >> /a/auth_file.yml"],
        environment={"B64": b64}, remove=True,
        volumes={AUTHDIR: {"bind": "/a", "mode": "rw"}},
    )


def validate_config():
    try:
        DK.containers.run(
            IMG,
            ["authelia", "validate-config", "--config", "/config/configuration.yml"],
            environment={"AUTHELIA_NOTIFIER_SMTP_PASSWORD": "x"},
            remove=True, volumes={AUTHDIR: {"bind": "/config", "mode": "ro"}},
        )
        return None
    except docker.errors.ContainerError as ex:
        return (getattr(ex, "stderr", None) or getattr(ex, "stdout", None) or b"validation failed").decode(errors="replace")


def restart_authelia():
    cont = DK.containers.get("authelia")
    cont.restart()
    for _ in range(30):
        cont.reload()
        if cont.status == "running":
            return True
        time.sleep(1)
    return False


def notify_admin(username, displayname, email):
    e = load_smtp()
    msg = EmailMessage()
    msg["From"] = e.get("MAIL_FROM") or e["SMTP_USER"]
    msg["To"] = e["NOTIFY_TO"]
    msg["Subject"] = f"Authelia signup request: {username}"
    msg.set_content(
        "New signup request (awaiting approval):\n\n"
        f"  Display name: {displayname}\n"
        f"  Username:     {username}\n"
        f"  Email:        {email}\n"
        f"  Time (UTC):   {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n"
        "The account exists with their chosen password and group [pending]:\n"
        f"  - they can already log in to https://auth.{DOMAIN} (portal only: set 2FA/passkey)\n"
        "  - they are denied everywhere else until you approve them\n\n"
        "Approve:\n"
        f"  ~/HomeLab/authelia/approve-user.sh {username}           # group: family\n"
        f"  ~/HomeLab/authelia/approve-user.sh {username} <group>   # other group, or '' for none\n\n"
        "If they need Open WebUI: WebUI -> Admin Panel -> Users -> role 'pending' -> 'user'."
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
 input{width:100%;box-sizing:border-box;padding:.55rem .6rem;border:1px solid #c9ced6;border-radius:6px;font-size:1rem}
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
  <label>Display name</label>
  <input name="displayname" required maxlength="60" value="__DISPLAYNAME__">
  <label>Username (lowercase, no spaces)</label>
  <input name="username" required pattern="[a-z0-9._-]{3,32}" value="__USERNAME__">
  <label>Email</label>
  <input name="email" type="email" required value="__EMAIL__">
  <label>Password (at least 8 characters)</label>
  <input name="password" type="password" required minlength="8">
  <label>Repeat password</label>
  <input name="password2" type="password" required minlength="8">
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
    from html import escape
    o = old or {}
    h = PAGE_TMPL.replace("__DOMAIN__", DOMAIN)
    h = h.replace(
        "__ERROR__",
        f'<div class="err">{escape(error)}</div>' if error else "",
    )
    h = h.replace("__DISPLAYNAME__", escape(o.get("displayname", "")))
    h = h.replace("__USERNAME__", escape(o.get("username", "")))
    h = h.replace("__EMAIL__", escape(o.get("email", "")))
    return h


def render_success(username):
    from html import escape
    return SUCCESS_TMPL.replace("__DOMAIN__", DOMAIN).replace(
        "__USERNAME__", escape(username))


@app.get("/")
def index():
    return render_page()


@app.post("/")
def submit():
    ip = request.headers.get("X-Real-IP") or request.remote_addr or "?"
    if rate_limited(ip):
        return render_page(error="Too many requests. Try again later."), 429
    f = request.form
    d = (f.get("displayname") or "").strip()
    u = (f.get("username") or "").strip()
    e = (f.get("email") or "").strip().lower()
    p1, p2 = f.get("password") or "", f.get("password2") or ""
    old = {"displayname": d, "username": u, "email": e}

    err = None
    if len(d) < 2 or len(d) > 60:
        err = "Display name: 2-60 characters."
    elif not USERNAME_RE.match(u):
        err = "Username: 3-32 characters, lowercase letters, digits, dot, underscore, dash."
    elif not EMAIL_RE.match(e):
        err = "Enter a valid email address."
    elif len(p1) < 8:
        err = "Password: at least 8 characters."
    elif p1 != p2:
        err = "Passwords do not match."
    if not err:
        ue, ee = re.escape(u), re.escape(e)
        if root_check(f"^    {ue}:$"):
            err = "That username is already taken."
        elif root_check(f'^ +email: "?{ee}"?\\s*$'):
            err = "That email is already in use."
    if err:
        return render_page(error=err, old=old)

    try:
        h = PH.hash(p1)
        de = d.replace("\\", "\\\\").replace('"', '\\"')
        entry = (
            f"    {u}:\n"
            f"        password: \"{h}\"\n"
            f"        displayname: \"{de}\"\n"
            f"        email: {e}\n"
            f"        groups: [pending]\n"
            f"        disabled: false\n"
        )
        root_append(entry)
        v = validate_config()
        if v:
            raise RuntimeError("config validation failed: " + v[-300:])
        if not restart_authelia():
            raise RuntimeError("authelia did not come back up")
        notify_admin(u, d, e)
    except Exception:
        return render_page(
            error="Something went wrong on our side; nothing was created. Try again later.",
            old=old), 500
    return render_success(u)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, threaded=True)