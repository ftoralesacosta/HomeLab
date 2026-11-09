# HomeLab Agent Instructions

- **Overview**: Read `README.md` and `docker-compose.yml` for the full service map.
- **Secrets (STRICT)**:
  - `~/HomeLab/.env`, `authelia/configuration.yml`, `authelia/users/auth_file.yml`, `signup/smtp.env`, and `/run/hermes-gateway.env` contain live production secrets.
  - **NEVER** read, print, or output their contents. Always inspect `.env.example` or `authelia/configuration.example.yml` instead.
- **Key Architecture**:
  - **Edge & Auth**: `reverse-proxy` (Nginx Proxy Manager on 80/443, admin UI on LAN `192.168.4.51:81`) + `authelia` (`4.39` pinned, SSO/OIDC).
  - **AI**: `open-webui` (host network port 3000), `searxng` (`127.0.0.1:8888` and `192.168.4.51:8888`), and host-level `hermes-gateway.service` (`127.0.0.1:8642`, isolated user `hermes`).
  - **Backups**: Nightly restic backup in `backup/` to local NVMe + Google Drive.
  - **Router**: OpenWrt 25.12 on Banana Pi BPI-R4 (`192.168.4.1`), docs in `OpenWRT-BPI_R4/`.
- **Operations**:
  - Apply compose changes for a single service with `docker compose up -d <service>` rather than restarting the entire stack.
  - Never run `docker compose down -v` or prune volumes.
