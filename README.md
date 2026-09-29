My quick solution integrate the DSL/VDSL Status of a Vigor167 Modem into HA...

Do a onetime connection with plink to your Device then you can start the monitor setup creds and go...

known issues: laggy interface/traymenue // sshserver-behavior(current test 25.09.2026)

Tested: Windows (SSH Working), Linux Wine (Telnet Working) other Modes-Combinations are untested...

Connection:
INPUT: Modem (SSH/TELNET)
OUTPUT: GUI/MQTT*

*Only use a private broker this is selfmade mqtt stuff!

vigor_xdsl_monitor is stable/working

vigor_xdsl_monitor2 is only for testing but it have all the new features :)


Using:
run the exe file or compile your own runtime/exe

Just download autoit > load the .au3 file > press F7(Compile) > Done...

This tool is only fully working on Vigor167 other Devices should work but i have only 2 Devices for testing here 165/167 so the maximum support will be later on Vigor165 and Vigor167...
