# Vigor-xDSL-Monitor

A small Windows tray tool (AutoIt3) that reads the DSL status of a **DrayTek Vigor** xDSL modem through its CLI and publishes the data to **Home Assistant** via **MQTT** (with auto-discovery). It also provides a full status window with live values, extended line statistics, history graphs, an event log, raw CLI output and alerts.

Developed and tested on a **Vigor167** (firmware 5.2.9). Other Vigor xDSL modems with compatible CLI commands may work as well.

> **Read-only.** The monitor never changes any modem setting. It reads status information using `exec dslinfo`, `exec sysinfo`, `exec dsl_35b_enhance status`, `exec dsl_35b_target show` and the DSL monitoring page via `config Monitoring DSL_Status Monitoring_DSL_General` + `show all`.

**Data sources.** The normal poll reads the DSL status and line values from the modem. The JSON returned by the slow `show all` / configuration submenu provides extended information such as attainable rates, line features and error counters. The normal poll is configurable from **15 to 3600 seconds**. Extended data is queried separately because the extended query takes **10+ seconds** and can therefore run much less frequently.

## Features

### DSL data
- Line status, mode, profile, annex and DSL version
- Downstream / upstream line rate
- SNR margin downstream / upstream
- Attainable (maximum) line rate downstream / upstream
- Line uptime
- VDSL2 35b enhance and 35b target (read-only)
- Firmware / device information from `sysinfo`:
  - model
  - device name
  - firmware version
  - build time
  - branch
  - release mode
  - web / core / bootloader version
  - country code

### Extended line statistics
Extended data is collected at startup, after a reconnect / resync and then according to its own configurable interval.

The **Line stats** tab shows:
- Trellis
- Bitswap
- ReTx
- Attenuation
- CRC
- FECS
- ES / SES
- LOSS / UAS
- HEC Errors
- RS Corrections
- LOS / LOF / LPR / NCD / LCD failures
- NFEC / RFEC / LYSMB
- Path mode
- Interleave depth downstream / upstream
- Actual PSD downstream / upstream
- Power management mode
- Modem vendor ID
- DSLAM vendor ID
- Time of the last and next extended read

Error counters are highlighted in the GUI when applicable.

### Connection
- **SSH** via `plink.exe`
- **Built-in Telnet** via a plain TCP socket, no external program required
- `Auto` mode:
  - SSH on Windows
  - Telnet under Wine / Linux
- One **persistent modem session** is reused instead of logging in again for every poll
- The persistent SSH session is cleanly recycled after a configurable time (1-48 hours, default 6 hours)
- `plink.exe` is searched in the configured path, the program folder and `PATH`
- If `plink.exe` is missing, it can be downloaded automatically from the official PuTTY site, with the official chiark mirror as fallback

### Home Assistant / MQTT
- Built-in minimal MQTT 3.1.1 client, no additional MQTT software required
- Retained state and availability topics
- Home Assistant MQTT auto-discovery
- `expire_after` is configured for sensors
- HA device name and model are taken from the modem itself
- Configurable:
  - MQTT broker
  - port
  - username / password
  - client ID
  - base topic
  - discovery prefix
  - diagnostic sensor publishing

All entities are grouped under the modem device.

| Entity | Notes |
|---|---|
| DSL Status | attributes: mode, profile, annex, DSL version |
| DSL Downstream Rate / Upstream Rate | Mbit/s |
| DSL Attainable Downstream / Upstream Rate | Mbit/s |
| DSL SNR Downstream / Upstream | dB |
| DSL Line Uptime | seconds |
| DSL 35b Enhance / 35b Target | diagnostic |
| DSL Modem Firmware | diagnostic, firmware/device details as attributes |
| DSL Path Mode | diagnostic |
| DSL Interleave Depth Downstream / Upstream | diagnostic |
| Extended line features and counters | diagnostic sensors where applicable |

When diagnostic publishing is disabled, diagnostic entities are removed from Home Assistant through retained empty discovery payloads.

If the base topic or discovery prefix is changed, HA discovery is sent again. Old entities under the old topics remain in Home Assistant until they are deleted there.

### Window and tray
- **Tray icon with live tooltip** showing modem/status information, line rates and SNR
- **Double-click the tray icon to open/show the GUI**
- There is intentionally **no usable tray context menu**. The GUI contains the controls for settings and exiting the application.
- Main window tabs:
  - **Overview**
  - **Line stats**
  - **Details**
  - **History**
  - **Log**
  - **Raw**
  - **About**
- Overview shows current line rate, SNR, attainable rates, line information, connection state, MQTT state, poll counters and resync count
- Line stats shows the extended DSL information and error counters
- History tab provides GDI+ line-rate and SNR graphs
- Unreachable polls are represented as gaps in the history graphs
- Raw tab shows the exact CLI output of the last poll, including the last extended query when it was not part of the current poll
- Buttons:
  - **Update now**
  - **Pause / Resume**
  - **Settings...**
  - **Hide to tray**
  - **Exit**
- Window and tray remain responsive while the modem is being polled
- Optional:
  - start hidden
  - hide on close / minimize
  - start with Windows

### Alerts and logging
- Tray notification on line status changes
- Tray notification when a resync is detected because the line uptime was reset
- Configurable warning when downstream SNR falls below a chosen threshold
- Alerts are logged in the Log tab
- Poll successes and failures are logged
- MQTT errors are logged
- Optional CSV logging of every poll to `vigor_xdsl_monitor.csv`
- CSV contains timestamp, status, downstream/upstream rates, SNR values and line uptime

### Security and reliability
- Modem and MQTT passwords are stored **encrypted with Windows DPAPI** in the INI
- DPAPI credentials are bound to the Windows user / machine that saved them
- If an INI is copied to another Windows user or machine and the passwords cannot be decrypted, the application asks for the passwords again
- Only one instance of the monitor can run at a time
- A clean application exit publishes MQTT availability as `offline`
- When polling is paused, the modem session is released

## Requirements

- Windows, or Linux with Wine
- A DrayTek Vigor xDSL modem with **SSH or Telnet enabled**
- For Home Assistant: an MQTT broker and the MQTT integration
- SSH mode: `plink.exe` is used and can be downloaded automatically if missing
- To run from source: [AutoIt3](https://www.autoitscript.com/)

## Installation

1. Download the EXE from the releases page, or compile `vigor_xdsl_monitor.au3` with AutoIt3 / AutoIt3Wrapper.
2. Start the monitor.
3. On the first run, the **Settings** dialog opens automatically.
4. Enter the modem host, username and password.
5. Configure MQTT if Home Assistant publishing is required.
6. Use **Test modem** and **Test MQTT** to verify the connections.
7. Press **Save**.
8. The monitor starts polling the modem and Home Assistant discovery is created automatically when a successful modem read provides the device information.

The configuration is stored in `vigor_xdsl_monitor.ini` next to the program.

## Settings

Settings are stored in `vigor_xdsl_monitor.ini` next to the program.

| Tab | Option | Default / Range |
|---|---|---|
| Modem | Host / user / password | `192.168.1.1` / `admin` |
| Modem | `plink.exe` path | program folder |
| Modem | Connection | Auto / SSH / Telnet |
| Modem | Telnet port | `23` |
| Modem | SSH session recycle | `6` hours, 1-48 |
| MQTT | Enabled | on |
| MQTT | Host / port | `homeassistant.local` / `1883` |
| MQTT | User / password | empty by default |
| MQTT | Client ID | `vigor-xdsl-autoit` |
| MQTT | Base topic | `vigor/xdsl` |
| MQTT | Discovery prefix | `homeassistant` |
| MQTT | Publish diagnostic sensors | on |
| General | Normal poll interval | `60` s, 15-3600 |
| General | History samples | `240`, 10-2000 |
| General | Extended data interval | `900` s, minimum 5 × normal interval, maximum 86400 s |
| General | Start with Windows | off |
| General | Start hidden in tray | off |
| General | Close / minimize hides to tray | on |
| General | CSV logging | off |
| Alerts | Notifications | on |
| Alerts | Downstream SNR warning threshold | `0` = off |

### Normal vs. extended polling

The normal poll is intentionally separate from the slow extended query.

**Normal poll** provides the current status, rates, SNR, uptime, firmware information and other regular values.

**Extended poll** queries the slow configuration submenu and provides attainable rates, Trellis, Bitswap, ReTx, attenuation and the extended error counters. It runs automatically at startup and after a reconnect / resync, then according to the configured extended-data interval.

The extended interval can never be less than **5 × the normal poll interval**, which prevents the modem from being hammered by the slow query.

## Tray operation

The monitor is designed to live in the Windows notification area.

- **Double-click the tray icon** → opens the main GUI
- **Hide to tray** → hides the GUI
- **Close / minimize** → hides the GUI when that option is enabled
- **Start hidden** → starts directly in the tray
- **Exit** → use the **Exit** button in the GUI

There is deliberately no normal tray menu. This also avoids the tray-menu behaviour that caused problems under Wine.

## Linux / Wine

- `plink.exe` does not communicate reliably under Wine, so `Auto` mode selects the built-in Telnet client under Wine.
- Enable Telnet on the modem when using Telnet.
- Telnet is unencrypted. Use it only on a trusted LAN.
- The tray icon can be used under Wine; **double-click it to show the main window**.
- The application contains Wine-specific handling for spurious close/minimize events that can occur immediately after showing the GUI.

## Known limitations

- The modem's **system uptime** is not available through the currently used CLI commands. The modem's web UI can show it.
- MQTT uses **QoS 0**.
- MQTT does not currently use **TLS**.
- The extended `show all` query takes 10+ seconds, so it is deliberately not executed on every normal poll.
- Other Vigor models may expose different CLI fields. Missing fields are left empty rather than modifying the modem.

## Project structure / generated files

The monitor may create these files next to the EXE / script:

- `vigor_xdsl_monitor.ini` - configuration
- `vigor_xdsl_monitor.csv` - optional poll history
- `plink.exe` - SSH helper when SSH mode is used and it was downloaded automatically

## Links

- Project: <https://github.com/BrAiNeeBug/VigorDSLMonitor>
- AutoIt: <https://www.autoitscript.com/>

## License

See the project repository for the current license information.
