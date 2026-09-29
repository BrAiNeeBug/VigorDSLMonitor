# Vigor-xDSL-Monitor

A small Windows tray tool (AutoIt3) that reads the DSL status of a **DrayTek Vigor** xDSL modem through its CLI and publishes everything to **Home Assistant** via **MQTT** (with auto-discovery). It also has a full status window with graphs, an event log and alerts.

Developed and tested on a **Vigor167** (firmware 5.2.9). Other Vigor xDSL modems with the same CLI commands may work as well.

> **Read-only.** The monitor never changes any modem setting. It only sends `exec dslinfo`, `exec sysinfo`, `exec dsl_35b_enhance status`, `exec dsl_35b_target show` and reads the DSL monitoring page via `config Monitoring DSL_Status Monitoring_DSL_General` + `show all`.

## Features

### Data
- Line status, mode, profile, annex, DSL version
- Downstream / upstream line rate
- SNR margin downstream / upstream
- Attainable (max) line rate down / up (read every few minutes, because `show all` takes 10+ seconds)
- Line uptime and monitor uptime
- VDSL2 35b enhance and 35b target (read-only)
- Firmware / device info from `sysinfo` (model, device name, firmware version, build time, branch, release mode, web / core / bootloader version, country code)

### Connection
- **SSH** (via `plink.exe`) or **built-in Telnet** (plain TCP socket, no external program)
- `Auto` mode: Telnet under Wine / Linux, SSH on Windows
- **One persistent session** instead of a new login on every poll. The modem only has a handful of SSH/PTY slots, so opening and killing a session every minute can exhaust them.
- The session is closed cleanly and reopened after a configurable time (1-48 h, default 6 h)
- `plink.exe` is looked up in the configured path, the script folder and `PATH`; if it is not found, it is downloaded from the official PuTTY site (chiark mirror as fallback)

### Home Assistant / MQTT
- Built-in minimal MQTT 3.1.1 client, no extra software needed
- Retained state and availability topics, HA MQTT discovery, `expire_after` on all sensors
- HA device name and model come from the modem itself
- Configurable broker, port, user, password, client ID, base topic and discovery prefix
- Entities (all under one device):

  | Entity | Notes |
  |---|---|
  | DSL Status | attributes: mode, profile, annex, DSL version |
  | DSL Downstream Rate / Upstream Rate | Mbit/s |
  | DSL Attainable Downstream / Upstream Rate | Mbit/s |
  | DSL SNR Downstream / Upstream | dB |
  | DSL Line Uptime | s |
  | DSL Monitor Uptime | diagnostic |
  | DSL 35b Enhance / 35b Target | diagnostic |
  | DSL Modem Firmware | diagnostic, firmware details as attributes |

### Window and tray
- Tray icon with tooltip (model / status, rates, SNR), double-click opens the window
- Main window with tabs: **Overview**, **Details**, **History**, **Log**, **Raw**, **About**
- History tab: neon-style line-rate and SNR graphs (GDI+), gaps where the modem was unreachable
- Raw tab: the exact CLI output of the last poll, handy for debugging
- Buttons: Update now, Pause / Resume, Settings, Hide to tray, Exit
- Window and tray stay responsive while a poll is running
- Optional: start hidden, close / minimize hides to tray, start with Windows

### Alerts and logging
- Tray notification on line status change and on resync (line uptime was reset)
- Warning when SNR down falls below a threshold you set
- Everything is also written to the Log tab
- Optional CSV log of every poll (`vigor_xdsl_monitor.csv`)

### Security
- Modem and MQTT passwords are stored **encrypted with Windows DPAPI** in the INI. They only work for the Windows user / machine that saved them. If you copy the INI elsewhere, the tool asks you to re-enter the passwords.
- Only one instance can run at a time

## Requirements
- Windows, or Linux with Wine
- A DrayTek Vigor xDSL modem with **SSH or Telnet enabled** (enable it in the modem's management settings)
- For Home Assistant: an MQTT broker (e.g. Mosquitto) and the MQTT integration
- SSH mode only: `plink.exe` (downloaded automatically if missing)
- To run from source: [AutoIt3](https://www.autoitscript.com/)

## Installation
1. Download the exe from the releases page, or compile `vigor_xdsl_monitor2.au3` with AutoIt3Wrapper (the compile directives are in the script header).
2. Start it. On first run the Settings dialog opens: enter the modem host, user and password and the MQTT broker.
3. Press **Test modem** and **Test MQTT**, then **Save**.
4. The sensors appear in Home Assistant under the device named after your modem.

## Settings

Settings are stored in `vigor_xdsl_monitor.ini` next to the program.

| Tab | Option | Default |
|---|---|---|
| Modem | Host / user / password | `192.168.1.1` / `admin` |
| Modem | plink.exe path | script folder |
| Modem | SSH recycle (h) | 6 (1-48) |
| Modem | Connection (Auto / SSH / Telnet), Telnet port | Auto, 23 |
| MQTT | Enabled, host, port, user, password | on, `homeassistant.local`, 1883 |
| MQTT | Client ID, base topic, discovery prefix | `vigor-xdsl-autoit`, `vigor/xdsl`, `homeassistant` |
| General | Poll interval (s) | 60 (15-3600) |
| General | Max rates every (s) | 300 (30-3600) |
| General | History samples | 240 (10-2000) |
| General | Start with Windows, start hidden, close hides to tray, CSV log | off, off, on, off |
| Alerts | Notifications, SNR warning threshold (dB) | on, 0 (= off) |

If you change the base topic or discovery prefix, the HA discovery is sent again. Old entities stay in HA until you delete them there.

## Linux / Wine
- `plink.exe` does not communicate under Wine, so `Auto` mode uses the built-in Telnet client. Enable Telnet on the modem for this.
- Telnet is unencrypted. Use it only inside your LAN.
- The first tray menu entry (the app name) does nothing on purpose. It works around a tray menu bug under Wine.

## Known limitations
- The modem's system uptime is not available (no CLI command found so far). It is only shown in the modem's web UI.
- MQTT: QoS 0, no TLS.

## Links
- Project: <https://github.com/BrAiNeeBug/VigorDSLMonitor>
