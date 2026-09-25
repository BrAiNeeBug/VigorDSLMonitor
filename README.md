(not-stable! this app is still in test dont use in production!!!!)

My quick solution integrate the DSL/VDSL Status of a Vigor Modem into HA...
Do a onetime connection with plink to your Device then you can start the monitor setup creds and go...

known issues: laggy interface/traymenue // sshserver-behavior(current test 25.09.2026)

tested: win11 only (should be run under Wine (Linux)

Connection:
INPUT: Modem (SSH)
OUTPUT: MQTT*

*Only use a private broker this is selfmade mqtt stuff!
