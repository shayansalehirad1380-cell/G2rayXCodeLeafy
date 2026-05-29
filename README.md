<div align="center">

# G2rayXCodeLeafy

A sleek VLESS proxy manager for GitHub Codespaces.

[![Version](https://img.shields.io/badge/version-1.4.3-2DC94E?style=flat-square)](https://github.com/Code-Leafy/G2rayXCodeLeafy)
[![License](https://img.shields.io/badge/license-MIT-2DC94E?style=flat-square)](https://github.com/Code-Leafy/G2rayXCodeLeafy)
[![Status](https://img.shields.io/badge/status-stable-2DC94E?style=flat-square)]()

</div>

---

<div align="center">

<!-- 🎬 Quick Start Tutorial Video -->
https://github.com/user-attachments/assets/79174a4a-ef86-4c1d-9f1a-909d0b29a248

<br>

<!-- 📸 Panel Preview Image -->
<img src="assets/preview.png" alt="G2ray Panel Preview" width="720" style="border-radius: 12px; border: 1px solid rgba(0,0,0,0.05);">

</div>

<br>

## Overview

G2ray is a powerful, interactive Bash panel designed to instantly deploy and manage Xray VLESS XHTTP configurations. Built specifically for the GitHub Codespaces environment, it automates port management, traffic monitoring, and connection keep-alives natively.

> **Note:** The panel includes a best-effort anti-sleep engine using Tmux while the Codespace is running. It cannot bypass GitHub quota limits, manual stops, or automatic deletion of stopped Codespaces.

---

<details><summary><kbd>🔗</kbd> Community Donated Configs (SUB)</summary>

Want to use public nodes donated by other G2ray users? Import this raw newline-separated list into clients that support plain VLESS subscriptions:

```text
https://raw.githubusercontent.com/Code-Leafy/G2rayXCodeLeafy/main/configs.txt
```

</details>

---

### Core Features

#### ⚡ One-Click Deploy & Manage
Generate and start Xray engines in seconds. The beautiful menu-driven CLI interface makes managing nodes and viewing live config links effortless. 

#### 🔄 Smart Auto-Keepalive
Built-in background loops and Tmux keepalives reduce idle shutdowns while the Codespace is active. If GitHub stops, blocks, or deletes the Codespace, reopen it from GitHub Codespaces; the panel will auto-start and self-heal after the container starts again.

#### 📡 Live Analytics & Quota
Tracks real-time RX/TX traffic and resource usage (CPU/RAM). The quota panel is a local 2-core wall-clock estimate that resets by month; GitHub billing remains authoritative. GitHub's 15 GB-month allowance is storage quota, not traffic quota.

#### 📦 Community Config Network
Donate your generated config directly from the CLI to share access with the community. Donation shares the live VLESS link, including its UUID, Codespaces endpoint, and link label, so only donate configs you intentionally want public.

<div align="center">

| 🛠️ Configuration Optimizer |
| :--- |
| To finalize your setup, take the config received from the panel and visit **[NetLeafy](https://code-leafy.github.io/NetLeafy)**. Set the server mode to **G2ray** and paste your link to generate a fully optimized connection. |

</div>

---


## Getting Started

1. **Fork the Repository**  
   → Click **Fork** at the top-right of this page

2. **Create a Codespace**  
   → Open your fork → Click **Code** → **Codespaces** tab → **Create codespace on main**

3. **Wait for Environment**  
   → Allow 2-3 minutes for the container to build

4. **Launch Panel**  
   → The G2ray CLI panel auto-starts in the terminal!

<details>
<summary><kbd>⚙️</kbd> Environment Configuration</summary>

While G2ray is designed to be zero-config, advanced users can modify specific variables within the engine script:

- `XRAY_PORT` **(Optional)** — Binds Xray to a custom port. Default: `443`
- `CODESPACE_NAME` **(Optional)** — Overrides auto-detection of the app domain.
- `G2RAY_QR_MODE` **(Optional)** — Controls QR display in the config view: `recommended` (default), `all`, or `none`.
- `G2RAY_EXTRA_FALLBACK_IPS` **(Optional)** — Adds comma-, semicolon-, or space-separated IP fallback candidates before auto-detected ones.
- `G2RAY_DEFAULT_FALLBACK_IPS` **(Optional)** — Replaces the built-in fallback IP candidate list.
- `G2RAY_MAX_FALLBACK_LINKS` **(Optional)** — Caps exported IP fallback links. Default: `3`.
- `G2RAY_EDGE_RECONNECT_THRESHOLD` **(Optional)** — Number of consecutive unreachable edge checks before self-heal may run a full reconnect. Default: `3`.
- `G2RAY_RECONNECT_COOLDOWN_SEC` **(Optional)** — Minimum seconds between automatic full reconnects. Default: `300`.
- `G2RAY_GH_TIMEOUT_SEC` **(Optional)** — Maximum seconds for GitHub CLI control-plane calls. Default: `10`.
- `G2RAY_LOG_MAX_BYTES` **(Optional)** — Maximum bytes per runtime log before rotation. Default: `1048576`.
- `G2RAY_LOG_ROTATE_KEEP` **(Optional)** — Number of rotated log files to keep. Default: `3`.
- `G2RAY_QUOTA_SECONDS` **(Optional)** — Local monthly quota estimate in seconds. Default: `216000` (60 wall-clock hours on a 2-core Codespace).

Generated links include `allowInsecure=1` for compatibility with IP fallback links that still route through the Codespaces SNI/Host. This is a compatibility tradeoff: clients that honor the flag may relax TLS certificate verification.

</details>

---

## Usage

When launched, the panel provides a 1-to-14 numerical selection menu. Simply type the number corresponding to the action you want to take.

```bash
# If panel did not get shown:
bash ./g2ray.sh
```

### Safer Reproducible Settings

- Set `G2RAY_AUTO_UPDATE=1` only when you want the panel to replace `g2ray.sh` from upstream on startup. It is disabled by default.
- Override the devcontainer build argument `XRAY_VERSION` to change the pinned Xray-core version. Default: `v26.5.9`.

### Codespace Recovery

GitHub can still stop a Codespace for idle timeout, quota, billing, manual stop, rebuild, or retention policy. No process inside the Codespace can restart it after that because all Codespace processes are stopped. To reduce surprise stops, set your GitHub Codespaces **Default idle timeout** to **240 minutes** in GitHub account settings.

For quick manual recovery from Windows, this repo includes `scripts/reopen-codespace.ps1`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\reopen-codespace.ps1 -Repo OWNER/REPO
```

If GitHub CLI says the `codespace` scope is missing, run:

```powershell
gh auth refresh -h github.com -s codespace
```

The helper uses GitHub's Codespaces start API, waits until the Codespace is available, and opens it in VS Code. If GitHub returns `HTTP 402`, the Codespace is quota or billing blocked and must wait for quota reset or a billing setting change.

---

## Architecture

```mermaid
graph LR
    A[GitHub Codespace] -->|Executes| B[G2ray Bash Panel]
    B -->|Configures| C[Xray-core]
    C -->|Binds Port 443| D[Codespace App Domain]
    D -->|VLESS over xHTTP| E[End User Client]
```

<details>
<summary><kbd>📁</kbd> Project Structure</summary>

```text
G2rayXCodeLeafy/
├── data/                    # Dynamic storage for usage stats, UUIDs, & config
├── logs/                    # Xray engine error logs
├── assets/                  # Media resources (previews & videos)
├── configs.txt              # Community donated subscription configs
└── g2ray.sh                 # The main interactive panel script
```

</details>

---

<details>
<summary><kbd>❓</kbd> FAQ & Troubleshooting</summary>

**My Codespace keeps shutting down?**
Ensure you have activated Option `7` in the G2ray panel (Toggle Anti-Sleep Mode) to spawn a background Tmux session that simulates activity while the Codespace is running. This is best-effort: GitHub may still stop the Codespace when quota, budget, idle-timeout policy, or retention/deletion rules apply.

**Will it restart after my monthly quota resets?**
Not by itself while GitHub is blocking or stopping the Codespace, because no code runs inside a stopped Codespace. After the monthly included usage resets, reopen the Codespace from GitHub; `postStartCommand` runs `g2ray.sh --silent-start`, starts Xray, starts the supervisor, and refreshes exported configs.

**Is the 15 GB limit my VPN data limit?**
No. GitHub's 15 GB-month included allowance is Codespaces storage. The panel's RX/TX traffic counter measures tunnel traffic for your visibility, but it is not the same as the GitHub storage quota.

**Why are my speeds slow?**
For optimal routing, always try to ensure your GitHub Codespace region is set to `Europe West` in your GitHub account settings, as this places the server in NL/DE.

</details>

<br>

<div align="center">

> **⚠️ Educational Purpose Only:** This project is provided for educational and research purposes. Users are solely responsible for compliance with all local laws. The developer assumes no liability for misuse.

[MIT License](https://github.com/Code-Leafy/G2rayXCodeLeafy/blob/main/LICENSE) · Crafted by [Code-Leafy](https://github.com/Code-Leafy)
</div>
