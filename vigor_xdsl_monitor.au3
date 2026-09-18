#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_Icon=vigor_xdsl_monitor.ico
#AutoIt3Wrapper_Outfile_x64=vigor_xdsl_monitor.exe
#AutoIt3Wrapper_UseUpx=y
#AutoIt3Wrapper_Res_Language=1033
#AutoIt3Wrapper_Res_requestedExecutionLevel=None
#AutoIt3Wrapper_AU3Check_Stop_OnWarning=y
#AutoIt3Wrapper_AU3Check_Parameters=-d -w 1 -w 2 -w 3 -w 5 -w 6
#AutoIt3Wrapper_Run_Stop_OnError=y
#AutoIt3Wrapper_Run_After=del /f /q %scriptdir%\%scriptfile%_stripped.au3
#AutoIt3Wrapper_Run_Tidy=y
#Tidy_Parameters=/rel
#AutoIt3Wrapper_Run_Au3Stripper=y
#Au3Stripper_Parameters=/so /rm
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****
#include-once
; Vigor167 DSL Monitor
; Reads the DSL line status of a DrayTek Vigor167 via SSH (plink.exe) and publishes it
; to Home Assistant via MQTT discovery. Settings are edited from the tray menu and
; stored in vigor167-dsl.ini next to the script (plain text - do not commit it!).
;
; Requirements: plink.exe (PuTTY), an MQTT broker, the Home Assistant MQTT integration.
; First use: run "plink.exe -ssh <user>@<modem-ip>" once by hand and accept the host key.
#include <AutoItConstants.au3>
#include <TrayConstants.au3>
#include <GUIConstantsEx.au3>
#include <EditConstants.au3>
#include <ButtonConstants.au3>
#include <StaticConstants.au3>
#include <WindowsConstants.au3>
#include <MsgBoxConstants.au3>
Opt("TrayMenuMode", 3) ; no default items, no auto-check
Global Const $APP_NAME = "Vigor xDSL Monitor"
Global Const $INI_FILE = @ScriptDir & "\vigor167-dsl.ini"
Global Const $RUN_KEY = "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
Global Const $RUN_NAME = "Vigor167DslMonitor"
Global Const $MQTT_CLIENT_ID = "vigor167-autoit"
Global Const $T_STATE = "vigor167/dsl/state"
Global Const $T_AVAIL = "vigor167/dsl/availability"
; settings (loaded from INI)
Global $g_sModemHost, $g_sModemUser, $g_sModemPass, $g_sPlink
Global $g_sMqttHost, $g_iMqttPort, $g_sMqttUser, $g_sMqttPass
Global $g_iInterval
; runtime state
Global $g_bDisc = False, $g_bPaused = False, $g_bRunning = False
Global $g_sLastRaw = "", $g_sMqttErr = ""
Global $g_idStatus, $g_idNow, $g_idPause, $g_idRaw, $g_idSettings, $g_idExit
Global $g_hPoll
_LoadSettings()
TCPStartup()
OnAutoItExitRegister("_Exit")
; first run: no INI yet -> ask for settings, quit if cancelled
If Not FileExists($INI_FILE) Then
	If Not _SettingsGui() Then Exit
EndIf
; tray menu
$g_idStatus = TrayCreateItem("Starting...")
TrayItemSetState($g_idStatus, $TRAY_DISABLE)
TrayCreateItem("")
$g_idNow = TrayCreateItem("Update now")
$g_idPause = TrayCreateItem("Pause polling")
$g_idRaw = TrayCreateItem("Show last raw output")
TrayCreateItem("")
$g_idSettings = TrayCreateItem("Settings...")
$g_idExit = TrayCreateItem("Exit")
TraySetToolTip($APP_NAME)
$g_bRunning = True
_Update()
$g_hPoll = TimerInit()
While True
	Switch TrayGetMsg()
		Case $g_idNow
			_Update()
			$g_hPoll = TimerInit()
		Case $g_idPause
			$g_bPaused = Not $g_bPaused
			If $g_bPaused Then
				TrayItemSetText($g_idPause, "Resume polling")
				TrayItemSetText($g_idStatus, "Paused")
			Else
				TrayItemSetText($g_idPause, "Pause polling")
				_Update()
				$g_hPoll = TimerInit()
			EndIf
		Case $g_idRaw
			Local $sShow = StringLeft($g_sLastRaw, 1500)
			If $sShow = "" Then $sShow = "(nothing yet)"
			MsgBox($MB_ICONINFORMATION, $APP_NAME, $sShow)
		Case $g_idSettings
			If _SettingsGui() Then
				$g_bDisc = False ; re-send discovery with the new settings
				_Update()
				$g_hPoll = TimerInit()
			EndIf
		Case $g_idExit
			ExitLoop
	EndSwitch
	If Not $g_bPaused And TimerDiff($g_hPoll) >= $g_iInterval * 1000 Then
		_Update()
		$g_hPoll = TimerInit()
	EndIf
	Sleep(100)
WEnd
Exit
Func _Exit()
	; mark sensors unavailable on a clean exit (retained availability topic)
	If $g_bRunning Then _Publish(_Pkt($T_AVAIL, "offline"))
	TCPShutdown()
EndFunc   ;==>_Exit
; ---------- settings ----------
Func _LoadSettings()
	$g_sModemHost = IniRead($INI_FILE, "modem", "host", "192.168.167.1")
	$g_sModemUser = IniRead($INI_FILE, "modem", "user", "admin")
	$g_sModemPass = IniRead($INI_FILE, "modem", "pass", "")
	$g_sPlink = IniRead($INI_FILE, "modem", "plink", @ScriptDir & "\plink.exe")
	$g_sMqttHost = IniRead($INI_FILE, "mqtt", "host", "homeassistant.local")
	$g_iMqttPort = Int(IniRead($INI_FILE, "mqtt", "port", "1883"))
	$g_sMqttUser = IniRead($INI_FILE, "mqtt", "user", "")
	$g_sMqttPass = IniRead($INI_FILE, "mqtt", "pass", "")
	$g_iInterval = Max(15, Int(IniRead($INI_FILE, "general", "interval", "60")))
EndFunc   ;==>_LoadSettings
Func _AutostartGet()
	Return RegRead($RUN_KEY, $RUN_NAME) <> ""
EndFunc   ;==>_AutostartGet
Func _AutostartSet($bOn)
	If $bOn Then
		Local $sCmd = '"' & @ScriptFullPath & '"'
		If Not @Compiled Then $sCmd = '"' & @AutoItExe & '" "' & @ScriptFullPath & '"'
		RegWrite($RUN_KEY, $RUN_NAME, "REG_SZ", $sCmd)
	Else
		RegDelete($RUN_KEY, $RUN_NAME)
	EndIf
EndFunc   ;==>_AutostartSet
; returns True if settings were saved
Func _SettingsGui()
	Local $bSaved = False, $bOk, $sRaw, $sStatus, $sHint, $iInterval
	Local $hGui = GUICreate($APP_NAME & " - Settings", 400, 420)
	GUICtrlCreateGroup("Modem (SSH)", 10, 8, 380, 146)
	GUICtrlCreateLabel("Host / IP", 22, 33, 90, 18)
	Local $iHost = GUICtrlCreateInput($g_sModemHost, 115, 30, 265, 22)
	GUICtrlCreateLabel("Username", 22, 61, 90, 18)
	Local $iUser = GUICtrlCreateInput($g_sModemUser, 115, 58, 265, 22)
	GUICtrlCreateLabel("Password", 22, 89, 90, 18)
	Local $iPass = GUICtrlCreateInput($g_sModemPass, 115, 86, 265, 22, $ES_PASSWORD)
	GUICtrlCreateLabel("plink.exe", 22, 117, 90, 18)
	Local $iPlink = GUICtrlCreateInput($g_sPlink, 115, 114, 195, 22)
	Local $iBrowse = GUICtrlCreateButton("Browse...", 315, 113, 65, 24)
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	GUICtrlCreateGroup("MQTT broker", 10, 162, 380, 140)
	GUICtrlCreateLabel("Host", 22, 187, 90, 18)
	Local $iMHost = GUICtrlCreateInput($g_sMqttHost, 115, 184, 265, 22)
	GUICtrlCreateLabel("Port", 22, 215, 90, 18)
	Local $iMPort = GUICtrlCreateInput($g_iMqttPort, 115, 212, 70, 22, $ES_NUMBER)
	GUICtrlCreateLabel("Username", 22, 243, 90, 18)
	Local $iMUser = GUICtrlCreateInput($g_sMqttUser, 115, 240, 265, 22)
	GUICtrlCreateLabel("Password", 22, 271, 90, 18)
	Local $iMPass = GUICtrlCreateInput($g_sMqttPass, 115, 268, 265, 22, $ES_PASSWORD)
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	GUICtrlCreateGroup("General", 10, 310, 380, 55)
	GUICtrlCreateLabel("Interval (s)", 22, 334, 70, 18)
	Local $iInt = GUICtrlCreateInput($g_iInterval, 95, 331, 55, 22, $ES_NUMBER)
	Local $iAuto = GUICtrlCreateCheckbox("Start with Windows", 215, 332, 165, 22)
	If _AutostartGet() Then GUICtrlSetState($iAuto, $GUI_CHECKED)
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	Local $iTestModem = GUICtrlCreateButton("Test modem", 10, 380, 90, 28)
	Local $iTestMqtt = GUICtrlCreateButton("Test MQTT", 105, 380, 90, 28)
	Local $iSave = GUICtrlCreateButton("Save", 205, 380, 90, 28, $BS_DEFPUSHBUTTON)
	Local $iCancel = GUICtrlCreateButton("Cancel", 300, 380, 90, 28)
	GUISetState(@SW_SHOW, $hGui)
	While True
		Switch GUIGetMsg()
			Case $GUI_EVENT_CLOSE, $iCancel
				ExitLoop
			Case $iBrowse
				Local $sFile = FileOpenDialog("Select plink.exe", @ScriptDir, "plink (plink.exe)|All (*.*)", 1, "plink.exe", $hGui)
				If Not @error Then GUICtrlSetData($iPlink, $sFile)
			Case $iTestModem
				GUISetCursor(15, 1)
				$sRaw = _FetchDslInfo(GUICtrlRead($iHost), GUICtrlRead($iUser), GUICtrlRead($iPass), GUICtrlRead($iPlink))
				GUISetCursor(2, 0)
				$sStatus = _Field($sRaw, "Status")
				If $sStatus <> "" Then
					MsgBox($MB_ICONINFORMATION, "Modem test", "OK - line status: " & $sStatus & @CRLF & _
							"Down: " & _Field($sRaw, "Downstream Line Rate") & @CRLF & _
							"Up: " & _Field($sRaw, "Upstream Line Rate"), 0, $hGui)
				Else
					$sHint = ""
					If StringInStr($sRaw, "host key") Then $sHint = @CRLF & @CRLF & "Run plink.exe -ssh <user>@<host> once by hand and accept the host key."
					MsgBox($MB_ICONERROR, "Modem test failed", StringLeft($sRaw, 600) & $sHint, 0, $hGui)
				EndIf
			Case $iTestMqtt
				GUISetCursor(15, 1)
				$bOk = _MqttSession("", GUICtrlRead($iMHost), Int(GUICtrlRead($iMPort)), GUICtrlRead($iMUser), GUICtrlRead($iMPass))
				GUISetCursor(2, 0)
				If $bOk Then
					MsgBox($MB_ICONINFORMATION, "MQTT test", "Connected to the broker.", 0, $hGui)
				Else
					MsgBox($MB_ICONERROR, "MQTT test failed", $g_sMqttErr, 0, $hGui)
				EndIf
			Case $iSave
				If StringStripWS(GUICtrlRead($iHost), 3) = "" Or StringStripWS(GUICtrlRead($iMHost), 3) = "" Then
					MsgBox($MB_ICONWARNING, "Settings", "Modem host and MQTT host are required.", 0, $hGui)
					ContinueLoop
				EndIf
				$iInterval = Max(15, Int(GUICtrlRead($iInt)))
				IniWrite($INI_FILE, "modem", "host", StringStripWS(GUICtrlRead($iHost), 3))
				IniWrite($INI_FILE, "modem", "user", GUICtrlRead($iUser))
				IniWrite($INI_FILE, "modem", "pass", GUICtrlRead($iPass))
				IniWrite($INI_FILE, "modem", "plink", GUICtrlRead($iPlink))
				IniWrite($INI_FILE, "mqtt", "host", StringStripWS(GUICtrlRead($iMHost), 3))
				IniWrite($INI_FILE, "mqtt", "port", Int(GUICtrlRead($iMPort)))
				IniWrite($INI_FILE, "mqtt", "user", GUICtrlRead($iMUser))
				IniWrite($INI_FILE, "mqtt", "pass", GUICtrlRead($iMPass))
				IniWrite($INI_FILE, "general", "interval", $iInterval)
				_AutostartSet(BitAND(GUICtrlRead($iAuto), $GUI_CHECKED) = $GUI_CHECKED)
				_LoadSettings()
				$bSaved = True
				ExitLoop
		EndSwitch
	WEnd
	GUIDelete($hGui)
	Return $bSaved
EndFunc   ;==>_SettingsGui
; ---------- update cycle ----------
Func _Update()
	TraySetToolTip($APP_NAME & " - updating...")
	If Not $g_bDisc Then $g_bDisc = _Publish(_DiscoveryPackets())
	Local $sRaw = _FetchDslInfo($g_sModemHost, $g_sModemUser, $g_sModemPass, $g_sPlink)
	$g_sLastRaw = $sRaw
	Local $sStatus = _Field($sRaw, "Status")
	Local $sPk, $sInfo
	If $sStatus = "" Then
		$sPk = _Pkt($T_AVAIL, "offline")
		$sInfo = "Modem unreachable"
	Else
		Local $vDown = _ToNum(_Field($sRaw, "Downstream Line Rate"), 1000)
		Local $vUp = _ToNum(_Field($sRaw, "Upstream Line Rate"), 1000)
		Local $vSnrDown = _ToNum(_Field($sRaw, "SNR Downstream"), 1)
		Local $vSnrUp = _ToNum(_Field($sRaw, "SNR Upstream"), 1)
		Local $vUptime = _UptimeSec(_Field($sRaw, "Line Uptime"))
		Local $sJson = '{"status":"' & _J($sStatus) & '"' & _
				',"mode":"' & _J(_Field($sRaw, "Mode")) & '"' & _
				',"profile":"' & _J(_Field($sRaw, "Profile")) & '"' & _
				',"annex":"' & _J(_Field($sRaw, "Annex")) & '"' & _
				',"dsl_version":"' & _J(_Field($sRaw, "DSL Version")) & '"' & _
				',"down":' & _JNum($vDown) & ',"up":' & _JNum($vUp) & _
				',"snr_down":' & _JNum($vSnrDown) & ',"snr_up":' & _JNum($vSnrUp) & _
				',"uptime":' & _JNum($vUptime) & '}'
		$sPk = _Pkt($T_STATE, $sJson) & _Pkt($T_AVAIL, "online")
		$sInfo = $sStatus & " | " & $vDown & "/" & $vUp & " Mbit/s | SNR " & $vSnrDown & "/" & $vSnrUp & " dB"
	EndIf
	If Not _Publish($sPk) Then $sInfo &= " (MQTT error)"
	TrayItemSetText($g_idStatus, $sInfo)
	TraySetToolTip(StringLeft($APP_NAME & ": " & $sInfo, 120))
EndFunc   ;==>_Update
; ---------- modem ----------
Func _FetchDslInfo($sHost, $sUser, $sPass, $sPlink)
	If Not FileExists($sPlink) Then Return "ERROR: plink.exe not found at " & $sPlink
	Local $sCmd = '"' & $sPlink & '" -ssh -batch -l ' & $sUser & ' -pw "' & $sPass & '" ' & $sHost
	Local $iPid = Run($sCmd, @ScriptDir, @SW_HIDE, BitOR($STDIN_CHILD, $STDOUT_CHILD, $STDERR_MERGED))
	If @error Then Return "ERROR: could not start plink"
	Local $sAll = "", $sNew, $aPrompt, $bLoggedIn = False, $iWait
	For $i = 1 To 6
		$iWait = 4000
		If $i = 1 Then $iWait = 15000
		$sNew = _ReadUntilQuiet($iPid, 800, 15000, $iWait)
		$sAll &= $sNew
		If $sNew = "" Then
			ProcessClose($iPid)
			Return "ERROR: no data from plink (round " & $i & ")" & @CRLF & "---" & @CRLF & $sAll
		EndIf
		If StringInStr($sNew, "Access denied") Then
			ProcessClose($iPid)
			Return "ERROR: access denied" & @CRLF & "---" & @CRLF & $sAll
		EndIf
		; modem CLI has its own Username:/Password: prompts after the SSH login
		$aPrompt = StringRegExp(StringLower(StringStripWS($sNew, 2)), "(username|password):$", 1)
		If @error Then
			$bLoggedIn = True
			ExitLoop
		EndIf
		If $aPrompt[0] = "username" Then
			StdinWrite($iPid, $sUser & @CR)
		Else
			StdinWrite($iPid, $sPass & @CR)
		EndIf
	Next
	If Not $bLoggedIn Then
		ProcessClose($iPid)
		Return "ERROR: login loop did not finish" & @CRLF & "---" & @CRLF & $sAll
	EndIf
	StdinWrite($iPid, "exec dslinfo" & @CR)
	$sAll &= _ReadUntilQuiet($iPid, 1500, 10000, 4000)
	StdinWrite($iPid, "exit" & @CR)
	Sleep(300)
	ProcessClose($iPid)
	Return $sAll
EndFunc   ;==>_FetchDslInfo
; $iFirstMs = max wait for the first byte, afterwards $iQuietMs of silence ends the read
Func _ReadUntilQuiet($iPid, $iQuietMs, $iMaxMs, $iFirstMs)
	Local $sBuf = "", $sChunk
	Local $hTotal = TimerInit(), $hQuiet = TimerInit()
	While TimerDiff($hTotal) < $iMaxMs
		$sChunk = StdoutRead($iPid)
		If $sChunk <> "" Then
			$sBuf &= $sChunk
			$hQuiet = TimerInit()
		ElseIf @error Then
			ExitLoop
		ElseIf $sBuf = "" Then
			If TimerDiff($hTotal) > $iFirstMs Then ExitLoop
		ElseIf TimerDiff($hQuiet) > $iQuietMs Then
			ExitLoop
		EndIf
		Sleep(50)
	WEnd
	Return $sBuf
EndFunc   ;==>_ReadUntilQuiet
; ---------- parsing ----------
Func _Field($sText, $sKey)
	Local $a = StringRegExp($sText, "(?m)^\s*" & $sKey & "\s*:\s*(.*?)\s*$", 1)
	If @error Then Return ""
	Return $a[0]
EndFunc   ;==>_Field
Func _ToNum($s, $iDiv)
	If $s = "" Then Return ""
	Local $sNum = StringRegExpReplace($s, "[^\d.]", "")
	If $sNum = "" Then Return ""
	Return Round(Number($sNum) / $iDiv, 1)
EndFunc   ;==>_ToNum
Func _UptimeSec($s)
	If $s = "" Then Return ""
	Return _Unit($s, "d") * 86400 + _Unit($s, "h") * 3600 + _Unit($s, "m") * 60 + _Unit($s, "s")
EndFunc   ;==>_UptimeSec
Func _Unit($s, $u)
	Local $a = StringRegExp($s, "(\d+)\s*" & $u & "(?![a-z])", 1)
	If @error Then Return 0
	Return Number($a[0])
EndFunc   ;==>_Unit
Func _J($s)
	$s = StringReplace($s, "\", "\\")
	$s = StringReplace($s, '"', '\"')
	Return $s
EndFunc   ;==>_J
Func _JNum($v)
	If $v == "" Then Return "null"
	Return String($v)
EndFunc   ;==>_JNum
; ---------- home assistant discovery ----------
Func _DiscoveryPackets()
	Local $s = ""
	$s &= _DiscPkt("status", "DSL Status", "status", "", "", "", "mdi:router-network", True)
	$s &= _DiscPkt("downstream_rate", "DSL Downstream Rate", "down", "Mbit/s", "data_rate", "measurement", "", False)
	$s &= _DiscPkt("upstream_rate", "DSL Upstream Rate", "up", "Mbit/s", "data_rate", "measurement", "", False)
	$s &= _DiscPkt("snr_downstream", "DSL SNR Downstream", "snr_down", "dB", "", "measurement", "mdi:sine-wave", False)
	$s &= _DiscPkt("snr_upstream", "DSL SNR Upstream", "snr_up", "dB", "", "measurement", "mdi:sine-wave", False)
	$s &= _DiscPkt("uptime", "DSL Line Uptime", "uptime", "s", "duration", "measurement", "", False)
	Return $s
EndFunc   ;==>_DiscoveryPackets
Func _DiscPkt($sObj, $sName, $sField, $sUnit, $sDevClass, $sStateClass, $sIcon, $bAttrs)
	Local $s = '{"name":"' & $sName & '","unique_id":"vigor167_dsl_' & $sObj & '"' & _
			',"state_topic":"' & $T_STATE & '"' & _
			',"value_template":"{{ value_json.' & $sField & ' }}"' & _
			',"availability_topic":"' & $T_AVAIL & '"' & _
			',"expire_after":' & Max(180, $g_iInterval * 3)
	If $sUnit <> "" Then $s &= ',"unit_of_measurement":"' & $sUnit & '"'
	If $sDevClass <> "" Then $s &= ',"device_class":"' & $sDevClass & '"'
	If $sStateClass <> "" Then $s &= ',"state_class":"' & $sStateClass & '"'
	If $sIcon <> "" Then $s &= ',"icon":"' & $sIcon & '"'
	If $bAttrs Then
		$s &= ',"json_attributes_topic":"' & $T_STATE & '"' & _
				',"json_attributes_template":"{{ {' & _
				"'mode':value_json.mode,'profile':value_json.profile,'annex':value_json.annex,'dsl_version':value_json.dsl_version" & _
				'} | tojson }}"'
	EndIf
	$s &= ',"device":{"identifiers":["vigor167"],"name":"DrayTek Vigor167","manufacturer":"DrayTek","model":"Vigor167"}}'
	Return _Pkt("homeassistant/sensor/vigor167_dsl/" & $sObj & "/config", $s)
EndFunc   ;==>_DiscPkt
; ---------- minimal MQTT 3.1.1 client (QoS 0, retained publish) ----------
; builds one retained PUBLISH packet as hex string
Func _Pkt($sTopic, $sPayload)
	Local $sBody = _HexStr($sTopic) & _HexRaw($sPayload)
	Return "31" & _RemLen(Int(StringLen($sBody) / 2)) & $sBody
EndFunc   ;==>_Pkt
Func _HexRaw($s)
	Return StringTrimLeft(StringToBinary($s, 4), 2)
EndFunc   ;==>_HexRaw
; 2-byte length prefix + UTF-8 bytes
Func _HexStr($s)
	Local $h = _HexRaw($s)
	Return Hex(Int(StringLen($h) / 2), 4) & $h
EndFunc   ;==>_HexStr
; MQTT variable-length "remaining length"
Func _RemLen($n)
	Local $sOut = "", $d
	Do
		$d = Mod($n, 128)
		$n = Int($n / 128)
		If $n > 0 Then $d = BitOR($d, 128)
		$sOut &= Hex($d, 2)
	Until $n = 0
	Return $sOut
EndFunc   ;==>_RemLen
Func _SendHex($iSock, $sHex)
	Local $bData = Binary("0x" & $sHex)
	Local $iLen = BinaryLen($bData), $iSent = 0, $r
	While $iSent < $iLen
		$r = TCPSend($iSock, BinaryMid($bData, $iSent + 1))
		If @error Then Return False
		$iSent += $r
	WEnd
	Return True
EndFunc   ;==>_SendHex
; publish with the configured broker
Func _Publish($sPackets)
	Return _MqttSession($sPackets, $g_sMqttHost, $g_iMqttPort, $g_sMqttUser, $g_sMqttPass)
EndFunc   ;==>_Publish
; connect -> send packets -> disconnect. Returns True on success, reason in $g_sMqttErr otherwise.
; An empty $sPackets just tests the connection.
Func _MqttSession($sPackets, $sHost, $iPort, $sUser, $sPass)
	$g_sMqttErr = ""
	Local $sIP = TCPNameToIP($sHost)
	If $sIP = "" Then
		$g_sMqttErr = "Cannot resolve " & $sHost
		Return False
	EndIf
	Local $iSock = TCPConnect($sIP, $iPort)
	If @error Then
		$g_sMqttErr = "Cannot connect to " & $sIP & ":" & $iPort
		Return False
	EndIf
	; CONNECT
	Local $iFlags = 2 ; clean session
	Local $sPayload = _HexStr($MQTT_CLIENT_ID)
	If $sUser <> "" Then
		$iFlags = BitOR($iFlags, 0x80)
		$sPayload &= _HexStr($sUser)
		If $sPass <> "" Then
			$iFlags = BitOR($iFlags, 0x40)
			$sPayload &= _HexStr($sPass)
		EndIf
	EndIf
	Local $sBody = "00044D515454" & "04" & Hex($iFlags, 2) & "003C" & $sPayload
	If Not _SendHex($iSock, "10" & _RemLen(Int(StringLen($sBody) / 2)) & $sBody) Then
		TCPCloseSocket($iSock)
		$g_sMqttErr = "Sending CONNECT failed"
		Return False
	EndIf
	; CONNACK (4 bytes: 20 02 00 <rc>)
	Local $sAck = "", $hT = TimerInit()
	While StringLen($sAck) < 8 And TimerDiff($hT) < 5000
		$sAck &= StringTrimLeft(TCPRecv($iSock, 4, 1), 2)
		If @error Then ExitLoop
		Sleep(20)
	WEnd
	If $sAck <> "20020000" Then
		If $sAck = "20020005" Or $sAck = "20020004" Then
			$g_sMqttErr = "Broker refused the login (wrong MQTT user/password?)"
		Else
			$g_sMqttErr = "Unexpected CONNACK: " & $sAck
		EndIf
		TCPCloseSocket($iSock)
		Return False
	EndIf
	; PUBLISH + clean DISCONNECT
	Local $bOk = _SendHex($iSock, $sPackets & "E000")
	Sleep(200)
	TCPCloseSocket($iSock)
	If Not $bOk Then $g_sMqttErr = "Sending PUBLISH failed"
	Return $bOk
EndFunc   ;==>_MqttSession
Func Max($a, $b)
	If $a > $b Then Return $a
	Return $b
EndFunc   ;==>Max
