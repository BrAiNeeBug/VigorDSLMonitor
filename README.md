My quick solution integrate the DSL/VDSL Status of a Vigor Modem into HA...
you only need one more extra file (plink.exe" from putty page and do a onetime connection.
thats all then you can start the monitor setup creds and go...

known issues:
laggy interface/traymenue

sshserver crash on modemside...

tested: win11 only (should be run under Wine (Linux)

Connection:
INPUT: Modem (SSH)
OUTPUT: MQTT*

*Only use a private broker this is selfmade mqtt stuff!
