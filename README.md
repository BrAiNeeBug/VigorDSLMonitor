# Vigor-xDSL-Monitor

Small Windows tray tool (AutoIt3) for **DrayTek Vigor** xDSL modems. It reads DSL status via the modem CLI and publishes it to **Home Assistant via MQTT** with auto-discovery. A local status window provides graphs, logs and diagnostics.

Developed and tested with a **Vigor167**, firmware 5.2.9. Other Vigor models using the same CLI may work as well.

> **Read-only:** The monitor does not change modem settings. It reads `dslinfo`, `sysinfo`, 35b diagnostics and the DSL monitoring page (`show all`).

## Features

### DSL data
- Line status, mode, profile, annex and DSL version
- Downstream / upstream rate and SNR
- Attainable downstream / upstream rate
- Line uptime and monitor uptime
- VDSL2 35b enhance / target status
- Modem model, firmware and build information

The main source for line values is the JSON returned by `show all`. `dslinfo` is used as fallback and provides line uptime.

### Connection
- SSH via `plink.exe` or built-in Telnet
- `Auto` uses SSH on Windows and Telnet under Wine/Linux
- Persistent CLI session, avoiding repeated modem logins
- Configurable session recycle (1-48 h)
- `plink.exe` is searched in the configured path, program folder and `PATH`, then downloaded automatically if required

### Home Assistant / MQTT
- Built-in MQTT 3.1.1 client
- Retained state and availability
- Home Assistant MQTT auto-discovery
- `expire_after` for sensors
- Configurable broker, port, credentials, client ID, base topic and discovery prefix
- One HA device containing status, rates, attainable rates, SNR, uptimes, 35b diagnostics and firmware information

### Interface
The program runs in the **Windows system tray**. A **double-click on the tray icon opens the main window**.

The window contains:
- **Overview** and **Details**
- **History** with line-rate / SNR graphs
- **Log** and **Raw** CLI output
- **About** and **Settings**

The window remains responsive during polling. Optional start-hidden, close/minimize-to-tray and Windows startup are available.

### Alerts & logging
- Tray notification for line-status changes and resyncs
- Configurable low-SNR warning
- Log tab
- Optional CSV logging (`vigor_xdsl_monitor.csv`)

### Security
- Modem and MQTT passwords are encrypted with Windows DPAPI
- Credentials are tied to the Windows user/machine that stored them
- Only one instance can run at a time

## Requirements

- Windows, or Linux with Wine
- DrayTek Vigor xDSL modem with SSH or Telnet enabled
- MQTT broker and Home Assistant MQTT integration
- `plink.exe` only for SSH mode (downloaded automatically if missing)
- AutoIt3 when running from source

## Installation

1. Download the EXE from the releases page, or compile `vigor_xdsl_monitor.au3` with AutoIt3.
2. Start the program. On first run, enter modem and MQTT settings.
3. Use **Test modem** and **Test MQTT**, then save.
4. Home Assistant discovers the modem automatically.

## Settings

Settings are stored in `vigor_xdsl_monitor.ini` next to the program.

| Area | Options | Default |
|---|---|---|
| Modem | Host, user, password | `192.168.1.1`, `admin` |
| Modem | Connection, Telnet port | Auto, `23` |
| Modem | plink path, SSH recycle | Program folder, 6 h |
| MQTT | Broker, port, user, password | `homeassistant.local`, `1883` |
| MQTT | Client ID, base topic, discovery prefix | `vigor-xdsl-autoit`, `vigor/xdsl`, `homeassistant` |
| General | Poll interval | 60 s |
| General | History samples | 240 |
| General | Start with Windows / hidden / tray / CSV | configurable |
| Alerts | Notifications, SNR threshold | on, `0` = off |

Changing the MQTT base topic or discovery prefix sends discovery again. Existing old entities are not automatically removed from Home Assistant.

## Linux / Wine

- `plink.exe` does not communicate reliably under Wine, so `Auto` uses built-in Telnet.
- Telnet is unencrypted and should only be used on a trusted LAN.

## Known limitations

- Modem system uptime is not available through the CLI.
- MQTT currently uses QoS 0 and no TLS.

## Links

- Project: https://github.com/BrAiNeeBug/VigorDSLMonitor
