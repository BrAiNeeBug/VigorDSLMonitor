#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_Icon=vigor_xdsl_monitor.ico
#AutoIt3Wrapper_Outfile_x64=vigor_xdsl_monitor.exe
#AutoIt3Wrapper_UseUpx=y
#AutoIt3Wrapper_Res_Fileversion=0.3.0.0
#AutoIt3Wrapper_Res_Fileversion_AutoIncrement=y
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
#include <AutoItConstants.au3>
#include <TrayConstants.au3>
#include <GUIConstantsEx.au3>
#include <EditConstants.au3>
#include <ButtonConstants.au3>
#include <ComboConstants.au3>
#include <StaticConstants.au3>
#include <WindowsConstants.au3>
#include <MsgBoxConstants.au3>
#include <Misc.au3>
#include <InetConstants.au3>
#include <GDIPlus.au3>
If _Singleton(@ScriptName, 1) = 0 Then Exit
Opt("TrayMenuMode", 3) ; no default items, no auto-check
Opt("GUICloseOnESC", 0) ; ESC must not hide/close the main window
Global Const $APP_NAME = "Vigor-xDSL-Monitor (0.3)"
Global Const $APP_URL = "https://github.com/BrAiNeeBug/VigorDSLMonitor"
Global Const $APP_VER = "0.3.0"
Global Const $INI_FILE = @ScriptDir & "\vigor_xdsl_monitor.ini"
Global Const $CSV_FILE = @ScriptDir & "\vigor_xdsl_monitor.csv"
Global Const $RUN_KEY = "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
Global Const $RUN_NAME = "VigorXdslMonitor"
Global Const $HIST_CAP = 2000 ; hard upper limit for the history buffer
; MQTT topics (built from the "base topic" setting in _LoadSettings)
Global $T_STATE, $T_AVAIL
; settings (loaded from INI)
Global $g_sModemHost, $g_sModemUser, $g_sModemPass, $g_sPlink
; connection method: "auto" (Telnet under Wine, SSH/plink on Windows), "ssh" or "telnet"
Global $g_sMethod = "auto", $g_bTelnet = False, $g_iTelnetPort = 23
Global $g_sMqttHost, $g_iMqttPort, $g_sMqttUser, $g_sMqttPass
Global $g_bMqttOn, $g_sClientId, $g_sTopicBase, $g_sDiscPrefix
Global $g_bPassErr = False ; True if a stored password could not be decrypted (e.g. INI copied from another PC/user)
Global $g_iInterval, $g_iSshMaxAge, $g_iHistLen
Global $g_bStartHidden, $g_bHideOnClose, $g_bNotify, $g_bCsv
Global $g_fSnrAlert ; 0 = off
; runtime state
Global $g_bDisc = False, $g_bPaused = False, $g_bRunning = False
Global $g_sLastRaw = "", $g_sMqttErr = "", $g_sModel = "" ; $g_sModel = model name read from the modem (for the HA device)
Global $g_idApp, $g_idShow, $g_idExit
Global $g_hPoll, $g_hTick
; persistent SSH session to the modem (PID of plink, 0 = no session)
Global $g_iSsh = 0, $g_sSshErr = ""
; age of the current persistent session; recycled with a clean logout before it
; wedges, so the modem never runs out of SSH/PTY slots over days of uptime
Global $g_hSshAge = 0
; where to auto-download plink.exe from if it can't be found anywhere else
; (official PuTTY site first, official chiark mirror as fallback)
Global Const $PLINK_URLS[2] = [ _
		"https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe", _
		"https://www.chiark.greenend.org.uk/~sgtatham/putty/latest/w64/plink.exe"]
; latest values from the modem (shown in the window)
Global $g_bPolled = False, $g_bOnline = False, $g_bUpdating = False
Global $g_sStatus = "", $g_sMode = "", $g_sProfile = "", $g_sAnnex = "", $g_sDslVer = "", $g_sEnhance = ""
Global $g_vDown = "", $g_vUp = "", $g_vSnrD = "", $g_vSnrU = "", $g_vTarget = ""
Global $g_vAttD = "", $g_vAttU = "" ; attainable (max) line rate
Global $g_bAttWarned = False
; the attainable rates take 10+ s to read ("show all"), so they are only queried every $g_iAttInterval seconds
Global $g_iAttInterval = 300, $g_hAtt = 0, $g_bAttRan = False
Global $g_iUptime = "", $g_hUptime = 0
Global $g_hStart = TimerInit() ; start of this program = monitor uptime
Global $g_sLastTime = "-", $g_sMqttState = "-", $g_sMqttPrevErr = ""
Global $g_iPollOk = 0, $g_iPollFail = 0, $g_iResyncs = 0
Global Const $FW_KEYS[10] = ["Model Name", "Device Name", "Firmware Version", "Build Time", "Branch", _
		"Release Mode", "Web Version", "Core Version", "Bootloader Version", "CountryCode"]
Global Const $FW_NAMES[10] = ["Model", "Device name", "Firmware version", "Build time", "Branch", _
		"Release mode", "Web version", "Core version", "Bootloader version", "Country code"]
Global $g_aFw[10]
; alert state
Global $g_bHavePrev = False, $g_sPrevStatus = "", $g_iPrevUptime = "", $g_bSnrAlerted = False
; history ring: [time, down, up, snr down, snr up]
Global $g_aHist[$HIST_CAP][5], $g_iHistN = 0
; event log
Global $g_sLog = ""
; window handles / control ids
Global $g_hMain = 0, $g_bWinVisible = False
Global $g_bBusy = False ; True while a poll runs: long waits keep window + tray alive via _Yield()
Global $g_iReq = 0 ; button pressed (queued), executed by the main loop and never inside a poll
Global $g_hShown = 0 ; timer: window was just shown (Wine fires bogus close/minimize events then)
Global $g_bWine = False
Global $g_idLnk = 0
Global $g_idHdr, $g_idSub, $g_idTab, $g_idTiRaw
Global $g_idDown, $g_idUp, $g_idSnrD, $g_idSnrU
Global $g_idAttD, $g_idAttU, $g_idMonUpt, $g_idUpt, $g_idMode, $g_idProf, $g_idAnnex, $g_idDslV, $g_idEnh, $g_idTgt
Global $g_idLast, $g_idNext, $g_idSsh, $g_idMqttS, $g_idPolls, $g_idResync
Global $g_aFwId[10]
Global $g_idGrRate, $g_idGrSnr
Global $g_idLog = 0, $g_idRawEdit, $g_sRawShown = "", $g_idBtnClear
Global $g_idBtnNow, $g_idBtnPause, $g_idBtnSet, $g_idBtnHide, $g_idBtnExit
; take over an INI from an older version once, this could be removed after some udpates!!!
If Not FileExists($INI_FILE) Then
	If FileExists(@ScriptDir & "\vigor_xdsl.ini") Then
		FileCopy(@ScriptDir & "\vigor_xdsl.ini", $INI_FILE)
	ElseIf FileExists(@ScriptDir & "\vigor167-dsl.ini") Then
		FileCopy(@ScriptDir & "\vigor167-dsl.ini", $INI_FILE)
	EndIf
EndIf
$g_bWine = _IsWine()
_LoadSettings()
TCPStartup()
_GDIPlus_Startup()
OnAutoItExitRegister("_Exit")
; first run: no INI yet -> ask for settings, quit if cancelled
If Not FileExists($INI_FILE) Then
	If Not _SettingsGui() Then Exit
EndIf
; INI copied from another PC/user/Wine prefix -> DPAPI can't decrypt, so don't even try to connect
If $g_bPassErr Then
	MsgBox($MB_ICONERROR, $APP_NAME, "The stored password(s) could not be decrypted." & @CRLF & _
			"They are bound to the Windows user/machine that saved them (DPAPI)." & @CRLF & @CRLF & _
			"Please re-enter the passwords in the settings.")
	If Not _SettingsGui() Then Exit
EndIf
; tray menu
$g_idApp = TrayCreateItem($APP_NAME)
TrayCreateItem("")
$g_idShow = TrayCreateItem("Show window")
TrayItemSetState($g_idShow, $TRAY_DEFAULT)
TrayCreateItem("")
$g_idExit = TrayCreateItem("Exit")
TraySetToolTip($APP_NAME)
$g_bRunning = True
_BuildMainGui()
_Log("Started " & $APP_NAME)
If Not $g_bStartHidden Then _WinShow()
_Update()
$g_hPoll = TimerInit()
$g_hTick = TimerInit()
Local $iReq
While True
	If Not _HandleEvents() Then ExitLoop
	; buttons queued by _HandleEvents run here, outside of any poll
	If $g_iReq <> 0 Then
		$iReq = $g_iReq
		$g_iReq = 0
		Switch $iReq
			Case $g_idBtnNow
				_PollNow()
			Case $g_idBtnPause
				_TogglePause()
			Case $g_idBtnSet
				_DoSettings()
		EndSwitch
	EndIf
	If Not $g_bPaused And TimerDiff($g_hPoll) >= $g_iInterval * 1000 Then
		_Update()
		$g_hPoll = TimerInit()
	EndIf
	If TimerDiff($g_hTick) >= 1000 Then
		_UiTick()
		$g_hTick = TimerInit()
	EndIf
	; idle: short sleep while the window is open, longer while it sits in the tray (saves CPU)
	If $g_bWinVisible Then
		Sleep(30)
	Else
		Sleep(150)
	EndIf
WEnd
Exit
Func _Exit()
	$g_bBusy = False ; no GUI pumping while shutting down
	; mark sensors unavailable on a clean exit (retained availability topic)
	If $g_bRunning Then _Publish(_Pkt($T_AVAIL, "offline"))
	_SshDrop()
	TCPShutdown()
	_GDIPlus_Shutdown()
EndFunc   ;==>_Exit
; ---------- events ----------
; Handles tray + window events. Returns False when the program should quit.
; Never runs anything slow itself (Update / Pause / Settings are only queued in $g_iReq),
; so it is safe to call from inside a running poll.
Func _HandleEvents()
	Local $iMsg = TrayGetMsg()
	Switch $iMsg
		Case $g_idShow, $TRAY_EVENT_PRIMARYDOUBLE
			_WinShow()
		Case $g_idExit
			Return False
	EndSwitch
	$iMsg = GUIGetMsg()
	Switch $iMsg
		Case 0
			; nothing
		Case $GUI_EVENT_CLOSE
			If Not _JustShown("close") Then
				If $g_bHideOnClose Then
					_WinHide("close button")
				Else
					Return False
				EndIf
			EndIf
		Case $GUI_EVENT_MINIMIZE
			; only react to a REAL minimize (Wine can send this right after showing the window)
			If $g_bHideOnClose And Not _JustShown("minimize") Then
				If BitAND(WinGetState($g_hMain), 16) Then _WinHide("minimize")
			EndIf
		Case $g_idBtnNow, $g_idBtnPause, $g_idBtnSet
			$g_iReq = $iMsg
		Case $g_idBtnHide
			_WinHide("Hide button")
		Case $g_idBtnClear
			$g_sLog = ""
			GUICtrlSetData($g_idLog, "")
		Case $g_idLnk
			ShellExecute($APP_URL)
		Case $g_idBtnExit
			Return False
	EndSwitch
	Return True
EndFunc   ;==>_HandleEvents
; True during the first 700 ms after the window was shown: close/minimize events in that time are bogus
Func _JustShown($sEvent)
	If $g_hShown = 0 Or TimerDiff($g_hShown) > 700 Then Return False
	If $g_bWine Then _Log("Ignored " & $sEvent & " event right after showing the window")
	Return True
EndFunc   ;==>_JustShown
; called from inside the long waits of a poll: keeps window and tray responsive
Func _Yield()
	If Not $g_bBusy Then Return
	If Not _HandleEvents() Then Exit ; _Exit cleans up
	If TimerDiff($g_hTick) >= 1000 Then
		_UiTick()
		$g_hTick = TimerInit()
	EndIf
EndFunc   ;==>_Yield
; Sleep that keeps the GUI alive while a poll is running
Func _Nap($iMs)
	If Not $g_bBusy Then
		Sleep($iMs)
		Return
	EndIf
	Local $h = TimerInit()
	Do
		_Yield()
		Sleep(20)
	Until TimerDiff($h) >= $iMs
EndFunc   ;==>_Nap
; like ProcessWaitClose, but keeps the GUI alive
Func _WaitClose($iPid, $iSec)
	Local $h = TimerInit()
	While ProcessExists($iPid) And TimerDiff($h) < $iSec * 1000
		_Nap(50)
	WEnd
EndFunc   ;==>_WaitClose
; ---------- settings ----------
Func _LoadSettings()
	$g_bPassErr = False
	$g_sModemHost = IniRead($INI_FILE, "modem", "host", "192.168.1.1")
	$g_sModemUser = IniRead($INI_FILE, "modem", "user", "admin")
	$g_sModemPass = _Unprotect(IniRead($INI_FILE, "modem", "pass", ""))
	If @error Then $g_bPassErr = True
	$g_sPlink = IniRead($INI_FILE, "modem", "plink", @ScriptDir & "\plink.exe")
	$g_sMethod = StringLower(StringStripWS(IniRead($INI_FILE, "modem", "method", "auto"), 3))
	If Not StringRegExp($g_sMethod, "^(auto|ssh|telnet)$") Then $g_sMethod = "auto"
	$g_bTelnet = _UseTelnet($g_sMethod)
	$g_iTelnetPort = Int(IniRead($INI_FILE, "modem", "telnet_port", "23"))
	If $g_iTelnetPort < 1 Or $g_iTelnetPort > 65535 Then $g_iTelnetPort = 23
	$g_bMqttOn = (Int(IniRead($INI_FILE, "mqtt", "enabled", "1")) <> 0)
	$g_sMqttHost = IniRead($INI_FILE, "mqtt", "host", "homeassistant.local")
	$g_iMqttPort = Int(IniRead($INI_FILE, "mqtt", "port", "1883"))
	If $g_iMqttPort < 1 Or $g_iMqttPort > 65535 Then $g_iMqttPort = 1883
	$g_sMqttUser = IniRead($INI_FILE, "mqtt", "user", "")
	$g_sMqttPass = _Unprotect(IniRead($INI_FILE, "mqtt", "pass", ""))
	If @error Then $g_bPassErr = True
	$g_sClientId = StringStripWS(IniRead($INI_FILE, "mqtt", "client_id", "vigor-xdsl-autoit"), 3)
	If $g_sClientId = "" Then $g_sClientId = "vigor-xdsl-autoit"
	$g_sTopicBase = _CleanTopic(IniRead($INI_FILE, "mqtt", "base_topic", "vigor/xdsl"), "vigor/xdsl")
	$g_sDiscPrefix = _CleanTopic(IniRead($INI_FILE, "mqtt", "discovery_prefix", "homeassistant"), "homeassistant")
	$T_STATE = $g_sTopicBase & "/state"
	$T_AVAIL = $g_sTopicBase & "/availability"
	$g_iInterval = Int(IniRead($INI_FILE, "general", "interval", "60"))
	If $g_iInterval < 15 Then $g_iInterval = 15 ; do not hammer the modem
	If $g_iInterval > 3600 Then $g_iInterval = 3600
	$g_iAttInterval = Int(IniRead($INI_FILE, "general", "attain_interval", "300"))
	If $g_iAttInterval < 30 Then $g_iAttInterval = 30
	If $g_iAttInterval > 3600 Then $g_iAttInterval = 3600
	Local $iHours = Int(IniRead($INI_FILE, "general", "ssh_max_hours", "6"))
	If $iHours < 1 Then $iHours = 1
	If $iHours > 48 Then $iHours = 48
	$g_iSshMaxAge = $iHours * 60 * 60 * 1000
	$g_iHistLen = Int(IniRead($INI_FILE, "general", "history_len", "240"))
	If $g_iHistLen < 10 Then $g_iHistLen = 10
	If $g_iHistLen > $HIST_CAP Then $g_iHistLen = $HIST_CAP
	$g_bStartHidden = (Int(IniRead($INI_FILE, "general", "start_hidden", "0")) <> 0)
	$g_bHideOnClose = (Int(IniRead($INI_FILE, "general", "hide_on_close", "1")) <> 0)
	$g_bNotify = (Int(IniRead($INI_FILE, "general", "notify", "1")) <> 0)
	$g_bCsv = (Int(IniRead($INI_FILE, "general", "csv_log", "0")) <> 0)
	$g_fSnrAlert = Number(IniRead($INI_FILE, "general", "snr_alert", "0"))
	If $g_fSnrAlert < 0 Then $g_fSnrAlert = 0
EndFunc   ;==>_LoadSettings
; True when running under Wine (ntdll exports wine_get_version there, real Windows does not)
Func _IsWine()
	DllCall("ntdll.dll", "str:cdecl", "wine_get_version")
	Return Not @error
EndFunc   ;==>_IsWine
Func _UseTelnet($sKey)
	If $sKey = "telnet" Then Return True
	If $sKey = "ssh" Then Return False
	Return $g_bWine
EndFunc   ;==>_UseTelnet
Func _MethodName($sKey)
	If $sKey = "ssh" Then Return "SSH (plink)"
	If $sKey = "telnet" Then Return "Telnet (built-in)"
	Return "Auto"
EndFunc   ;==>_MethodName
Func _MethodKey($sText)
	If StringLeft($sText, 3) = "SSH" Then Return "ssh"
	If StringLeft($sText, 6) = "Telnet" Then Return "telnet"
	Return "auto"
EndFunc   ;==>_MethodKey
; trims slashes/spaces, falls back to $sDefault if empty or containing MQTT wildcards
Func _CleanTopic($s, $sDefault)
	$s = StringRegExpReplace(StringStripWS($s, 3), "^/+|/+$", "")
	If $s = "" Or StringRegExp($s, "[+#]") Then Return $sDefault
	Return $s
EndFunc   ;==>_CleanTopic
; ---------- password protection (Windows DPAPI, bound to current user) ----------
Func _Protect($sPlain)
	If $sPlain = "" Then Return ""
	Local $bIn = StringToBinary($sPlain, 4)
	Local $tData = DllStructCreate("byte[" & BinaryLen($bIn) & "]")
	DllStructSetData($tData, 1, $bIn)
	Local $tIn = DllStructCreate("dword cb; ptr pb")
	$tIn.cb = BinaryLen($bIn)
	$tIn.pb = DllStructGetPtr($tData)
	Local $tOut = DllStructCreate("dword cb; ptr pb")
	Local $aRet = DllCall("crypt32.dll", "bool", "CryptProtectData", "struct*", $tIn, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "dword", 1, "struct*", $tOut)
	If @error Or Not $aRet[0] Then Return SetError(1, 0, $sPlain)
	Local $bOut = DllStructGetData(DllStructCreate("byte[" & $tOut.cb & "]", $tOut.pb), 1)
	DllCall("kernel32.dll", "ptr", "LocalFree", "ptr", $tOut.pb)
	Return "dpapi:" & Hex($bOut)
EndFunc   ;==>_Protect
Func _Unprotect($sStored)
	; legacy plaintext values still work and get encrypted on the next Save
	If StringLeft($sStored, 6) <> "dpapi:" Then Return $sStored
	Local $bIn = Binary("0x" & StringTrimLeft($sStored, 6))
	Local $tData = DllStructCreate("byte[" & BinaryLen($bIn) & "]")
	DllStructSetData($tData, 1, $bIn)
	Local $tIn = DllStructCreate("dword cb; ptr pb")
	$tIn.cb = BinaryLen($bIn)
	$tIn.pb = DllStructGetPtr($tData)
	Local $tOut = DllStructCreate("dword cb; ptr pb")
	Local $aRet = DllCall("crypt32.dll", "bool", "CryptUnprotectData", "struct*", $tIn, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "dword", 1, "struct*", $tOut)
	If @error Or Not $aRet[0] Then Return SetError(1, 0, "")
	Local $bOut = DllStructGetData(DllStructCreate("byte[" & $tOut.cb & "]", $tOut.pb), 1)
	DllCall("kernel32.dll", "ptr", "LocalFree", "ptr", $tOut.pb)
	Return BinaryToString($bOut, 4)
EndFunc   ;==>_Unprotect
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
; ---------- settings dialog ----------
; returns True if settings were saved
Func _SettingsGui()
	Local $bSaved = False, $bOk, $sRaw, $sStatus, $sHint, $iInterval, $sFile, $iHist, $iSsh, $iPort, $sId
	Local $bOldT, $iOldP, $iAtt
	Local $bDisableMain = ($g_hMain <> 0 And $g_bWinVisible)
	If $bDisableMain Then GUISetState(@SW_DISABLE, $g_hMain)
	Local $hGui = GUICreate($APP_NAME & " - Settings", 410, 432)
	GUICtrlCreateTab(8, 8, 394, 366)
	; --- modem
	GUICtrlCreateTabItem("Modem")
	GUICtrlCreateLabel("Host / IP", 22, 53, 110, 18)
	Local $iHost = GUICtrlCreateInput($g_sModemHost, 135, 50, 255, 22)
	GUICtrlCreateLabel("Username", 22, 83, 110, 18)
	Local $iUser = GUICtrlCreateInput($g_sModemUser, 135, 80, 255, 22)
	GUICtrlCreateLabel("Password", 22, 113, 110, 18)
	Local $iPass = GUICtrlCreateInput($g_sModemPass, 135, 110, 255, 22, $ES_PASSWORD)
	GUICtrlCreateLabel("plink.exe", 22, 143, 110, 18)
	Local $iPlink = GUICtrlCreateInput($g_sPlink, 135, 140, 185, 22)
	Local $iBrowse = GUICtrlCreateButton("Browse...", 325, 139, 65, 24)
	GUICtrlCreateLabel("SSH recycle (h)", 22, 183, 110, 18)
	Local $iSshH = GUICtrlCreateInput(Round($g_iSshMaxAge / 3600000), 135, 180, 55, 22, $ES_NUMBER)
	GUICtrlCreateLabel("The persistent SSH session is closed cleanly and re-opened after this many hours (1-48)." & _
			" Keeps the modem's SSH/PTY slots from filling up.", 22, 212, 368, 44)
	GUICtrlCreateLabel("Connection", 22, 273, 110, 18)
	Local $iConn = GUICtrlCreateCombo("", 135, 270, 255, 22, $CBS_DROPDOWNLIST)
	GUICtrlSetData($iConn, "Auto|SSH (plink)|Telnet (built-in)", _MethodName($g_sMethod))
	GUICtrlCreateLabel("Telnet port", 22, 303, 110, 18)
	Local $iTPort = GUICtrlCreateInput($g_iTelnetPort, 135, 300, 55, 22, $ES_NUMBER)
	GUICtrlCreateLabel("Auto = Telnet under Wine, SSH on Windows", 198, 303, 195, 18)
	; --- mqtt
	GUICtrlCreateTabItem("MQTT")
	Local $iMOn = GUICtrlCreateCheckbox("Publish to MQTT / Home Assistant", 22, 48, 360, 20)
	If $g_bMqttOn Then GUICtrlSetState($iMOn, $GUI_CHECKED)
	GUICtrlCreateLabel("Host", 22, 83, 110, 18)
	Local $iMHost = GUICtrlCreateInput($g_sMqttHost, 135, 80, 255, 22)
	GUICtrlCreateLabel("Port", 22, 113, 110, 18)
	Local $iMPort = GUICtrlCreateInput($g_iMqttPort, 135, 110, 70, 22, $ES_NUMBER)
	GUICtrlCreateLabel("Username", 22, 143, 110, 18)
	Local $iMUser = GUICtrlCreateInput($g_sMqttUser, 135, 140, 255, 22)
	GUICtrlCreateLabel("Password", 22, 173, 110, 18)
	Local $iMPass = GUICtrlCreateInput($g_sMqttPass, 135, 170, 255, 22, $ES_PASSWORD)
	GUICtrlCreateLabel("Client ID", 22, 203, 110, 18)
	Local $iMCid = GUICtrlCreateInput($g_sClientId, 135, 200, 255, 22)
	GUICtrlCreateLabel("Base topic", 22, 233, 110, 18)
	Local $iMBase = GUICtrlCreateInput($g_sTopicBase, 135, 230, 255, 22)
	GUICtrlCreateLabel("Discovery prefix", 22, 263, 110, 18)
	Local $iMDisc = GUICtrlCreateInput($g_sDiscPrefix, 135, 260, 255, 22)
	GUICtrlCreateLabel("Changing base topic or discovery prefix re-sends the HA discovery." & _
			" Entities under the old topics stay in HA until you delete them there.", 22, 294, 368, 44)
	; --- general
	GUICtrlCreateTabItem("General")
	GUICtrlCreateLabel("Interval (s)", 22, 53, 110, 18)
	Local $iInt = GUICtrlCreateInput($g_iInterval, 135, 50, 55, 22, $ES_NUMBER)
	GUICtrlCreateLabel("15 - 3600", 198, 53, 100, 18)
	GUICtrlCreateLabel("History (samples)", 22, 83, 110, 18)
	Local $iHistLen = GUICtrlCreateInput($g_iHistLen, 135, 80, 55, 22, $ES_NUMBER)
	GUICtrlCreateLabel("10 - " & $HIST_CAP & " (graphs in the History tab)", 198, 83, 190, 18)
	Local $iAuto = GUICtrlCreateCheckbox("Start with Windows", 22, 120, 360, 20)
	If _AutostartGet() Then GUICtrlSetState($iAuto, $GUI_CHECKED)
	Local $iHid = GUICtrlCreateCheckbox("Start hidden in the tray", 22, 146, 360, 20)
	If $g_bStartHidden Then GUICtrlSetState($iHid, $GUI_CHECKED)
	Local $iClose = GUICtrlCreateCheckbox("Close / minimize button hides the window to the tray", 22, 172, 360, 20)
	If $g_bHideOnClose Then GUICtrlSetState($iClose, $GUI_CHECKED)
	Local $iCsv = GUICtrlCreateCheckbox("Log every poll to a CSV file", 22, 198, 360, 20)
	If $g_bCsv Then GUICtrlSetState($iCsv, $GUI_CHECKED)
	GUICtrlCreateLabel("File: vigor_xdsl_monitor.csv (next to the script / exe)", 40, 222, 350, 18)
	GUICtrlCreateLabel("Max rates every (s)", 22, 263, 110, 18)
	Local $iAttInt = GUICtrlCreateInput($g_iAttInterval, 135, 260, 55, 22, $ES_NUMBER)
	GUICtrlCreateLabel("30 - 3600 (reading the attainable rates takes 10+ s)", 198, 263, 195, 32)
	; --- alerts
	GUICtrlCreateTabItem("Alerts")
	Local $iNotify = GUICtrlCreateCheckbox("Notify on line status change and resync", 22, 48, 360, 20)
	If $g_bNotify Then GUICtrlSetState($iNotify, $GUI_CHECKED)
	GUICtrlCreateLabel("Warn if SNR down is below", 22, 86, 190, 18)
	Local $iSnr = GUICtrlCreateInput($g_fSnrAlert, 215, 83, 55, 22)
	GUICtrlCreateLabel("dB  (0 = off)", 276, 86, 100, 18)
	GUICtrlCreateLabel("Alerts show up as tray balloons and are always written to the Log tab.", 22, 122, 368, 32)
	GUICtrlCreateTabItem("")
	Local $iTestModem = GUICtrlCreateButton("Test modem", 8, 388, 95, 28)
	Local $iTestMqtt = GUICtrlCreateButton("Test MQTT", 108, 388, 95, 28)
	Local $iSave = GUICtrlCreateButton("Save", 208, 388, 95, 28, $BS_DEFPUSHBUTTON)
	Local $iCancel = GUICtrlCreateButton("Cancel", 308, 388, 95, 28)
	GUISetState(@SW_SHOW, $hGui)
	While True
		Switch GUIGetMsg()
			Case $GUI_EVENT_CLOSE, $iCancel
				ExitLoop
			Case $iBrowse
				$sFile = FileOpenDialog("Select plink.exe", @ScriptDir, "plink (plink.exe)|All (*.*)", 1, "plink.exe", $hGui)
				If Not @error Then GUICtrlSetData($iPlink, $sFile)
			Case $iTestModem
				GUISetCursor(15, 1)
				$bOldT = $g_bTelnet
				$iOldP = $g_iTelnetPort
				$g_bTelnet = _UseTelnet(_MethodKey(GUICtrlRead($iConn)))
				$g_iTelnetPort = Int(GUICtrlRead($iTPort))
				If $g_iTelnetPort < 1 Or $g_iTelnetPort > 65535 Then $g_iTelnetPort = 23
				$sRaw = _FetchDslInfo(GUICtrlRead($iHost), GUICtrlRead($iUser), GUICtrlRead($iPass), GUICtrlRead($iPlink), True)
				$g_bTelnet = $bOldT
				$g_iTelnetPort = $iOldP
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
				If StringStripWS(GUICtrlRead($iHost), 3) = "" Then
					MsgBox($MB_ICONWARNING, "Settings", "Modem host is required.", 0, $hGui)
					ContinueLoop
				EndIf
				If _Chk($iMOn) And StringStripWS(GUICtrlRead($iMHost), 3) = "" Then
					MsgBox($MB_ICONWARNING, "Settings", "MQTT host is required while MQTT is enabled.", 0, $hGui)
					ContinueLoop
				EndIf
				If StringRegExp(GUICtrlRead($iMBase) & GUICtrlRead($iMDisc), "[+#]") Then
					MsgBox($MB_ICONWARNING, "Settings", "Topics must not contain the MQTT wildcards + or #.", 0, $hGui)
					ContinueLoop
				EndIf
				$iInterval = Int(GUICtrlRead($iInt))
				If $iInterval < 15 Then $iInterval = 15
				If $iInterval > 3600 Then $iInterval = 3600
				$iHist = Int(GUICtrlRead($iHistLen))
				If $iHist < 10 Then $iHist = 10
				If $iHist > $HIST_CAP Then $iHist = $HIST_CAP
				$iSsh = Int(GUICtrlRead($iSshH))
				If $iSsh < 1 Then $iSsh = 1
				If $iSsh > 48 Then $iSsh = 48
				$iPort = Int(GUICtrlRead($iMPort))
				If $iPort < 1 Or $iPort > 65535 Then $iPort = 1883
				$sId = StringStripWS(GUICtrlRead($iMCid), 3)
				If $sId = "" Then $sId = "vigor-xdsl-autoit"
				IniWrite($INI_FILE, "modem", "host", StringStripWS(GUICtrlRead($iHost), 3))
				IniWrite($INI_FILE, "modem", "user", GUICtrlRead($iUser))
				IniWrite($INI_FILE, "modem", "pass", _Protect(GUICtrlRead($iPass)))
				IniWrite($INI_FILE, "modem", "plink", GUICtrlRead($iPlink))
				IniWrite($INI_FILE, "modem", "method", _MethodKey(GUICtrlRead($iConn)))
				IniWrite($INI_FILE, "modem", "telnet_port", Int(GUICtrlRead($iTPort)))
				IniWrite($INI_FILE, "mqtt", "enabled", Int(_Chk($iMOn)))
				IniWrite($INI_FILE, "mqtt", "host", StringStripWS(GUICtrlRead($iMHost), 3))
				IniWrite($INI_FILE, "mqtt", "port", $iPort)
				IniWrite($INI_FILE, "mqtt", "user", GUICtrlRead($iMUser))
				IniWrite($INI_FILE, "mqtt", "pass", _Protect(GUICtrlRead($iMPass)))
				IniWrite($INI_FILE, "mqtt", "client_id", $sId)
				IniWrite($INI_FILE, "mqtt", "base_topic", _CleanTopic(GUICtrlRead($iMBase), "vigor/xdsl"))
				IniWrite($INI_FILE, "mqtt", "discovery_prefix", _CleanTopic(GUICtrlRead($iMDisc), "homeassistant"))
				IniWrite($INI_FILE, "general", "interval", $iInterval)
				IniWrite($INI_FILE, "general", "ssh_max_hours", $iSsh)
				IniWrite($INI_FILE, "general", "history_len", $iHist)
				$iAtt = Int(GUICtrlRead($iAttInt))
				If $iAtt < 30 Then $iAtt = 30
				If $iAtt > 3600 Then $iAtt = 3600
				IniWrite($INI_FILE, "general", "attain_interval", $iAtt)
				IniWrite($INI_FILE, "general", "start_hidden", Int(_Chk($iHid)))
				IniWrite($INI_FILE, "general", "hide_on_close", Int(_Chk($iClose)))
				IniWrite($INI_FILE, "general", "csv_log", Int(_Chk($iCsv)))
				IniWrite($INI_FILE, "general", "notify", Int(_Chk($iNotify)))
				IniWrite($INI_FILE, "general", "snr_alert", Number(GUICtrlRead($iSnr)))
				_AutostartSet(_Chk($iAuto))
				_LoadSettings()
				$bSaved = True
				ExitLoop
		EndSwitch
	WEnd
	GUIDelete($hGui)
	If $bDisableMain Then GUISetState(@SW_ENABLE, $g_hMain)
	If $g_hMain <> 0 Then
		GUISwitch($g_hMain)
		If $bDisableMain Then WinActivate($g_hMain)
	EndIf
	Return $bSaved
EndFunc   ;==>_SettingsGui
Func _Chk($id)
	Return BitAND(GUICtrlRead($id), $GUI_CHECKED) = $GUI_CHECKED
EndFunc   ;==>_Chk
Func _DoSettings()
	If _SettingsGui() Then
		_Log("Settings saved")
		$g_bDisc = False ; re-send discovery with the new settings
		_SshDrop() ; reconnect with the new settings
		_HistTrim($g_iHistLen)
		_Update()
		$g_hPoll = TimerInit()
	EndIf
EndFunc   ;==>_DoSettings
Func _PollNow()
	_Update()
	$g_hPoll = TimerInit()
EndFunc   ;==>_PollNow
Func _TogglePause()
	$g_bPaused = Not $g_bPaused
	If $g_bPaused Then
		GUICtrlSetData($g_idBtnPause, "Resume")
		TraySetToolTip($APP_NAME & " - paused")
		_SshDrop() ; free the modem's SSH slot while paused
		_Log("Polling paused")
		_UiRefresh()
	Else
		GUICtrlSetData($g_idBtnPause, "Pause")
		_Log("Polling resumed")
		_Update()
		$g_hPoll = TimerInit()
	EndIf
EndFunc   ;==>_TogglePause
; ---------- main window ----------
; label pair: fixed caption + value label, returns the id of the value label
Func _Row($sName, $iX, $iY, $iLW, $iVW)
	GUICtrlCreateLabel($sName, $iX, $iY, $iLW, 18)
	Return GUICtrlCreateLabel("-", $iX + $iLW + 4, $iY, $iVW, 18)
EndFunc   ;==>_Row
Func _BuildMainGui()
	$g_hMain = GUICreate($APP_NAME, 600, 490)
	GUISetFont(9, 400, 0, "Segoe UI")
	$g_idHdr = GUICtrlCreateLabel("Starting...", 16, 8, 568, 32)
	GUICtrlSetFont($g_idHdr, 18, 700, 0, "Segoe UI")
	GUICtrlSetColor($g_idHdr, 0x808080)
	$g_idSub = GUICtrlCreateLabel("", 18, 44, 566, 20)
	GUICtrlSetColor($g_idSub, 0x666666)
	$g_idTab = GUICtrlCreateTab(10, 72, 580, 366)
	; --- overview
	GUICtrlCreateTabItem("Overview")
	GUICtrlCreateGroup("Line rate", 20, 102, 275, 86)
	GUICtrlCreateLabel("Downstream", 32, 127, 80, 20)
	$g_idDown = GUICtrlCreateLabel("-", 118, 120, 168, 30)
	GUICtrlSetFont($g_idDown, 16, 700, 0, "Segoe UI")
	GUICtrlCreateLabel("Upstream", 32, 157, 80, 20)
	$g_idUp = GUICtrlCreateLabel("-", 118, 150, 168, 30)
	GUICtrlSetFont($g_idUp, 16, 700, 0, "Segoe UI")
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	GUICtrlCreateGroup("Signal-to-noise ratio", 305, 102, 275, 86)
	GUICtrlCreateLabel("Downstream", 317, 127, 80, 20)
	$g_idSnrD = GUICtrlCreateLabel("-", 403, 120, 168, 30)
	GUICtrlSetFont($g_idSnrD, 16, 700, 0, "Segoe UI")
	GUICtrlCreateLabel("Upstream", 317, 157, 80, 20)
	$g_idSnrU = GUICtrlCreateLabel("-", 403, 150, 168, 30)
	GUICtrlSetFont($g_idSnrU, 16, 700, 0, "Segoe UI")
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	GUICtrlCreateGroup("Line", 20, 196, 275, 232)
	$g_idUpt = _Row("Line uptime", 32, 222, 100, 150)
	$g_idAttD = _Row("Max down", 32, 244, 100, 150)
	$g_idAttU = _Row("Max up", 32, 266, 100, 150)
	$g_idMode = _Row("Mode", 32, 288, 100, 150)
	$g_idProf = _Row("Profile", 32, 310, 100, 150)
	$g_idAnnex = _Row("Annex", 32, 332, 100, 150)
	$g_idDslV = _Row("DSL version", 32, 354, 100, 150)
	$g_idEnh = _Row("35b enhance", 32, 376, 100, 150)
	$g_idTgt = _Row("35b target", 32, 398, 100, 150)
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	GUICtrlCreateGroup("Modem / monitor", 305, 196, 275, 232)
	$g_idMonUpt = _Row("Monitor uptime", 317, 224, 95, 155)
	$g_idLast = _Row("Last update", 317, 248, 95, 155)
	$g_idNext = _Row("Next update in", 317, 272, 95, 155)
	$g_idSsh = _Row("Connection", 317, 296, 95, 155)
	$g_idMqttS = _Row("MQTT", 317, 320, 95, 155)
	$g_idPolls = _Row("Polls ok / failed", 317, 344, 95, 155)
	$g_idResync = _Row("Resyncs seen", 317, 368, 95, 155)
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	; --- details (firmware / device info from sysinfo)
	GUICtrlCreateTabItem("Details")
	GUICtrlCreateGroup("Modem / firmware", 20, 102, 560, 326)
	For $i = 0 To 9
		$g_aFwId[$i] = _Row($FW_NAMES[$i], 32, 130 + 28 * $i, 140, 380)
	Next
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	; --- history graphs
	GUICtrlCreateTabItem("History")
	$g_idGrRate = GUICtrlCreatePic("", 20, 104, 556, 150)
	$g_idGrSnr = GUICtrlCreatePic("", 20, 268, 556, 150)
	; --- log
	GUICtrlCreateTabItem("Log")
	$g_idLog = GUICtrlCreateEdit("", 20, 102, 560, 296, BitOR($ES_READONLY, $WS_VSCROLL, $ES_AUTOVSCROLL))
	GUICtrlSetFont($g_idLog, 9, 400, 0, "Consolas")
	GUICtrlSetData($g_idLog, $g_sLog)
	$g_idBtnClear = GUICtrlCreateButton("Clear log", 20, 404, 90, 24)
	; --- raw output
	$g_idTiRaw = GUICtrlCreateTabItem("Raw")
	$g_idRawEdit = GUICtrlCreateEdit("", 20, 102, 560, 326, BitOR($ES_READONLY, $WS_VSCROLL, $ES_AUTOVSCROLL))
	GUICtrlSetFont($g_idRawEdit, 9, 400, 0, "Consolas")
	; --- about
	GUICtrlCreateTabItem("About")
	Local $idAbT = GUICtrlCreateLabel("Vigor-xDSL-Monitor", 32, 118, 540, 34)
	GUICtrlSetFont($idAbT, 18, 700, 0, "Segoe UI")
	GUICtrlCreateLabel("Reads the DSL status of DrayTek Vigor modems (SSH / Telnet) and publishes it to Home Assistant via MQTT.", 32, 158, 540, 36)
	Local $sVer = $APP_VER
	If @Compiled Then $sVer &= "  (build " & FileGetVersion(@ScriptFullPath) & ")"
	GUICtrlSetData(_Row("Version", 32, 212, 100, 440), $sVer)
	GUICtrlSetData(_Row("Author", 32, 236, 100, 440), "BrAiNee")
	GUICtrlCreateLabel("GitHub", 32, 260, 100, 18)
	$g_idLnk = GUICtrlCreateLabel($APP_URL, 136, 260, 440, 18)
	GUICtrlSetColor($g_idLnk, 0x0066CC)
	GUICtrlSetFont($g_idLnk, 9, 400, 4, "Segoe UI")
	GUICtrlSetCursor($g_idLnk, 0) ; hand
	GUICtrlSetData(_Row("System", 32, 284, 100, 440), _RuntimeInfo())
	GUICtrlSetData(_Row("AutoIt", 32, 308, 100, 440), @AutoItVersion)
	GUICtrlCreateTabItem("")
	$g_idBtnNow = GUICtrlCreateButton("Update now", 10, 448, 100, 30)
	$g_idBtnPause = GUICtrlCreateButton("Pause", 115, 448, 100, 30)
	$g_idBtnSet = GUICtrlCreateButton("Settings...", 220, 448, 100, 30)
	$g_idBtnHide = GUICtrlCreateButton("Hide to tray", 380, 448, 100, 30)
	$g_idBtnExit = GUICtrlCreateButton("Exit", 490, 448, 100, 30)
EndFunc   ;==>_BuildMainGui
; OS / Wine info for the About tab (handy for bug reports)
Func _RuntimeInfo()
	Local $s = @OSVersion & " " & @OSArch
	If $g_bWine Then
		Local $aW = DllCall("ntdll.dll", "str:cdecl", "wine_get_version")
		If Not @error Then $s &= "  (Wine " & $aW[0] & ")"
	EndIf
	Return $s
EndFunc   ;==>_RuntimeInfo
Func _WinShow()
	$g_hShown = TimerInit()
	GUISetState(@SW_SHOW, $g_hMain)
	If BitAND(WinGetState($g_hMain), 16) Then GUISetState(@SW_RESTORE, $g_hMain) ; only if really minimized
	WinActivate($g_hMain)
	$g_bWinVisible = True
	_UiRefresh()
EndFunc   ;==>_WinShow
Func _WinHide($sWhy = "")
	If $g_bWine And $sWhy <> "" Then _Log("Window hidden by: " & $sWhy)
	GUISetState(@SW_HIDE, $g_hMain)
	$g_bWinVisible = False
EndFunc   ;==>_WinHide
; only touches a label if its text really changed (avoids flicker)
Func _SetTxt($id, $s)
	If Not (GUICtrlRead($id) == $s) Then GUICtrlSetData($id, $s)
EndFunc   ;==>_SetTxt
; True if the value is not empty (0 counts as a value)
Func _Has($v)
	Return Not ($v == "")
EndFunc   ;==>_Has
Func _Dash($v)
	If Not _Has($v) Then Return "-"
	Return String($v)
EndFunc   ;==>_Dash
Func _FmtVal($v, $sUnit)
	If Not _Has($v) Then Return "-"
	Return $v & " " & $sUnit
EndFunc   ;==>_FmtVal
Func _FmtUptime($i)
	If Not _Has($i) Then Return "-"
	$i = Int($i)
	Local $d = Int($i / 86400)
	Local $sT = StringFormat("%02d:%02d:%02d", Int(Mod($i, 86400) / 3600), Int(Mod($i, 3600) / 60), Mod($i, 60))
	If $d > 0 Then Return $d & "d " & $sT
	Return $sT
EndFunc   ;==>_FmtUptime
Func _FmtAge($iMs)
	Local $iS = Int($iMs / 1000)
	If $iS >= 3600 Then Return Int($iS / 3600) & "h " & Int(Mod($iS, 3600) / 60) & "m"
	Return Int($iS / 60) & "m " & Mod($iS, 60) & "s"
EndFunc   ;==>_FmtAge
; big status line on top of the window
Func _UiHeader()
	If Not $g_bWinVisible Then Return
	Local $sT, $iC
	If $g_bPaused Then
		$sT = "Paused"
		$iC = 0x808080
	ElseIf $g_bUpdating Then
		$sT = "Updating..."
		$iC = 0x808080
	ElseIf Not $g_bPolled Then
		$sT = "Starting..."
		$iC = 0x808080
	ElseIf $g_bOnline Then
		$sT = $g_sStatus
		If StringInStr($g_sStatus, "showtime") Then
			$iC = 0x108A2A
		Else
			$iC = 0xD07800
		EndIf
	Else
		$sT = "Modem unreachable"
		$iC = 0xC02020
	EndIf
	_SetTxt($g_idHdr, ChrW(9679) & " " & $sT)
	GUICtrlSetColor($g_idHdr, $iC)
EndFunc   ;==>_UiHeader
; once per second: countdown, ticking uptime, SSH session age
Func _UiTick()
	If Not $g_bWinVisible Then Return
	Local $s
	If $g_bPaused Then
		$s = "paused"
	ElseIf $g_bBusy Then
		$s = "updating..."
	Else
		Local $iLeft = Round($g_iInterval - TimerDiff($g_hPoll) / 1000)
		If $iLeft < 0 Then $iLeft = 0
		$s = $iLeft & " s"
	EndIf
	_SetTxt($g_idNext, $s)
	If $g_bOnline And _Has($g_iUptime) Then _SetTxt($g_idUpt, _FmtUptime($g_iUptime + Int(TimerDiff($g_hUptime) / 1000)))
	_SetTxt($g_idMonUpt, _FmtUptime(Int(TimerDiff($g_hStart) / 1000)))
	If $g_iSsh <> 0 And $g_hSshAge <> 0 Then
		Local $sVia = "SSH"
		If $g_iSsh < 0 Then $sVia = "Telnet"
		_SetTxt($g_idSsh, $sVia & " open (" & _FmtAge(TimerDiff($g_hSshAge)) & ")")
	Else
		_SetTxt($g_idSsh, "closed")
	EndIf
EndFunc   ;==>_UiTick
; full redraw of everything in the window (after a poll, on show, ...)
Func _UiRefresh()
	If Not $g_bWinVisible Then Return
	_UiHeader()
	Local $sSub = $g_sModel
	If $sSub = "" Then $sSub = "Vigor modem"
	If _Has($g_aFw[2]) Then $sSub &= "   |   firmware " & $g_aFw[2]
	$sSub &= "   |   " & $g_sModemHost
	_SetTxt($g_idSub, $sSub)
	_SetTxt($g_idDown, _FmtVal($g_vDown, "Mbit/s"))
	_SetTxt($g_idUp, _FmtVal($g_vUp, "Mbit/s"))
	_SetTxt($g_idSnrD, _FmtVal($g_vSnrD, "dB"))
	_SetTxt($g_idSnrU, _FmtVal($g_vSnrU, "dB"))
	_SetTxt($g_idAttD, _FmtVal($g_vAttD, "Mbit/s"))
	_SetTxt($g_idAttU, _FmtVal($g_vAttU, "Mbit/s"))
	_SetTxt($g_idMode, _Dash($g_sMode))
	_SetTxt($g_idProf, _Dash($g_sProfile))
	_SetTxt($g_idAnnex, _Dash($g_sAnnex))
	_SetTxt($g_idDslV, _Dash($g_sDslVer))
	_SetTxt($g_idEnh, _Dash($g_sEnhance))
	_SetTxt($g_idTgt, _Dash($g_vTarget))
	For $i = 0 To 9
		_SetTxt($g_aFwId[$i], _Dash($g_aFw[$i]))
	Next
	_SetTxt($g_idLast, $g_sLastTime)
	_SetTxt($g_idMqttS, $g_sMqttState)
	_SetTxt($g_idPolls, $g_iPollOk & " / " & $g_iPollFail)
	_SetTxt($g_idResync, $g_iResyncs)
	If Not ($g_sRawShown == $g_sLastRaw) Then
		$g_sRawShown = $g_sLastRaw
		GUICtrlSetData($g_idRawEdit, StringReplace(StringStripCR($g_sLastRaw), @LF, @CRLF))
	EndIf
	_UiTick()
	_DrawGraph($g_idGrRate, "Line rate (Mbit/s)", 1, "Down", "Up")
	_DrawGraph($g_idGrSnr, "SNR (dB)", 3, "Down", "Up")
EndFunc   ;==>_UiRefresh
; ---------- event log ----------
Func _Log($s)
	$g_sLog &= StringFormat("%02d:%02d:%02d  ", @HOUR, @MIN, @SEC) & $s & @CRLF
	If StringLen($g_sLog) > 30000 Then
		$g_sLog = StringRight($g_sLog, 20000)
		Local $p = StringInStr($g_sLog, @CRLF)
		If $p Then $g_sLog = StringMid($g_sLog, $p + 2)
	EndIf
	If $g_idLog <> 0 Then
		GUICtrlSetData($g_idLog, $g_sLog)
		GUICtrlSendMsg($g_idLog, 0xB1, -1, -1) ; EM_SETSEL: caret to the end
		GUICtrlSendMsg($g_idLog, 0xB7, 0, 0) ; EM_SCROLLCARET: scroll to the newest line
	EndIf
EndFunc   ;==>_Log
; first line of a (multi line) error text, for the log
Func _FirstLine($s)
	$s = StringStripWS(StringStripCR($s), 3)
	Local $p = StringInStr($s, @LF)
	If $p Then $s = StringLeft($s, $p - 1)
	If $s = "" Then $s = "no response"
	Return StringLeft($s, 100)
EndFunc   ;==>_FirstLine
; ---------- history + CSV ----------
; drops the oldest samples so that at most $iKeep remain
Func _HistTrim($iKeep)
	Local $iDrop = $g_iHistN - $iKeep
	If $iDrop <= 0 Then Return
	For $i = $iDrop To $g_iHistN - 1
		For $j = 0 To 4
			$g_aHist[$i - $iDrop][$j] = $g_aHist[$i][$j]
		Next
	Next
	$g_iHistN -= $iDrop
EndFunc   ;==>_HistTrim
; "" values = no data (modem unreachable), drawn as a gap
Func _HistAdd($vDown, $vUp, $vSnrDown, $vSnrUp)
	_HistTrim($g_iHistLen - 1)
	$g_aHist[$g_iHistN][0] = @HOUR & ":" & @MIN
	$g_aHist[$g_iHistN][1] = $vDown
	$g_aHist[$g_iHistN][2] = $vUp
	$g_aHist[$g_iHistN][3] = $vSnrDown
	$g_aHist[$g_iHistN][4] = $vSnrUp
	$g_iHistN += 1
EndFunc   ;==>_HistAdd
Func _CsvLog($sStatus, $vDown, $vUp, $vSnrDown, $vSnrUp, $iUptime)
	If Not $g_bCsv Then Return
	Local $bNew = Not FileExists($CSV_FILE)
	Local $hFile = FileOpen($CSV_FILE, 1)
	If $hFile = -1 Then Return
	If $bNew Then FileWriteLine($hFile, "time;status;down_mbit;up_mbit;snr_down_db;snr_up_db;uptime_s")
	FileWriteLine($hFile, @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC & ";" & $sStatus & ";" & _
			$vDown & ";" & $vUp & ";" & $vSnrDown & ";" & $vSnrUp & ";" & $iUptime)
	FileClose($hFile)
EndFunc   ;==>_CsvLog
; ---------- graphs (GDI+ into a bitmap, shown in a picture control) ----------
Func _GfxText($hCtx, $sText, $nX, $nY, $hFont, $hFmt, $hBrush)
	Local $tLayout = _GDIPlus_RectFCreate($nX, $nY, 0, 0)
	_GDIPlus_GraphicsDrawStringEx($hCtx, $sText, $hFont, $tLayout, $hFmt, $hBrush)
EndFunc   ;==>_GfxText
; $iCol = history column of the first series, the second series is $iCol + 1
Func _DrawGraph($idPic, $sTitle, $iCol, $sNameA, $sNameB)
	Local Const $W = 556, $h = 150, $L = 44, $R = 10, $T = 24, $B = 20
	Local Const $CLR_A = 0xFF39FF88, $CLR_B = 0xFFFF4FD8 ; neon green / magenta
	Local $hBmp = _GDIPlus_BitmapCreateFromScan0($W, $h)
	Local $hCtx = _GDIPlus_ImageGetGraphicsContext($hBmp)
	_GDIPlus_GraphicsSetSmoothingMode($hCtx, 2)
	_GDIPlus_GraphicsClear($hCtx, 0xFF15181E)
	Local $hFam = _GDIPlus_FontFamilyCreate("Arial")
	Local $hFont = _GDIPlus_FontCreate($hFam, 8)
	Local $hFmt = _GDIPlus_StringFormatCreate()
	Local $hBrGray = _GDIPlus_BrushCreateSolid(0xFF8A94A3)
	Local $hBrA = _GDIPlus_BrushCreateSolid($CLR_A)
	Local $hBrB = _GDIPlus_BrushCreateSolid($CLR_B)
	Local $hPenGrid = _GDIPlus_PenCreate(0xFF2B303A, 1)
	Local $hPenA = _GDIPlus_PenCreate($CLR_A, 2)
	Local $hPenB = _GDIPlus_PenCreate($CLR_B, 2)
	_GfxText($hCtx, $sTitle, $L, 4, $hFont, $hFmt, $hBrGray)
	_GfxText($hCtx, $sNameA, $W - 130, 4, $hFont, $hFmt, $hBrA)
	_GfxText($hCtx, $sNameB, $W - 70, 4, $hFont, $hFmt, $hBrB)
	; value range over both series
	Local $v, $y, $x, $xPrev, $yPrev, $bPrev, $hPen
	Local $fMin = 1.0e9, $fMax = -1.0e9
	For $i = 0 To $g_iHistN - 1
		For $c = 0 To 1
			$v = $g_aHist[$i][$iCol + $c]
			If _Has($v) Then
				If $v < $fMin Then $fMin = $v
				If $v > $fMax Then $fMax = $v
			EndIf
		Next
	Next
	If $fMax < $fMin Then
		_GfxText($hCtx, "waiting for data...", $L + 10, $h / 2 - 6, $hFont, $hFmt, $hBrGray)
	Else
		Local $fPad = ($fMax - $fMin) * 0.1
		If $fPad < 0.5 Then $fPad = 0.5
		$fMin -= $fPad
		$fMax += $fPad
		If $fMin < 0 Then $fMin = 0
		Local $fRange = $fMax - $fMin
		; grid + y labels
		For $k = 0 To 3
			$y = $T + ($h - $T - $B) * $k / 3
			_GDIPlus_GraphicsDrawLine($hCtx, $L, $y, $W - $R, $y, $hPenGrid)
			_GfxText($hCtx, StringFormat("%.1f", $fMax - $fRange * $k / 3), 2, $y - 7, $hFont, $hFmt, $hBrGray)
		Next
		; time labels (first / last sample)
		_GfxText($hCtx, $g_aHist[0][0], $L, $h - $B + 4, $hFont, $hFmt, $hBrGray)
		_GfxText($hCtx, $g_aHist[$g_iHistN - 1][0], $W - $R - 32, $h - $B + 4, $hFont, $hFmt, $hBrGray)
		; the two series (gaps where the modem was unreachable)
		Local $fStep = 0
		If $g_iHistN > 1 Then $fStep = ($W - $L - $R) / ($g_iHistN - 1)
		For $c = 0 To 1
			If $c = 0 Then
				$hPen = $hPenA
			Else
				$hPen = $hPenB
			EndIf
			$bPrev = False
			For $i = 0 To $g_iHistN - 1
				$v = $g_aHist[$i][$iCol + $c]
				If _Has($v) Then
					$x = $L + $fStep * $i
					$y = $T + ($h - $T - $B) * ($fMax - $v) / $fRange
					If $bPrev Then
						_GDIPlus_GraphicsDrawLine($hCtx, $xPrev, $yPrev, $x, $y, $hPen)
					Else
						_GDIPlus_GraphicsDrawLine($hCtx, $x - 1, $y, $x + 1, $y, $hPen)
					EndIf
					$xPrev = $x
					$yPrev = $y
					$bPrev = True
				Else
					$bPrev = False
				EndIf
			Next
		Next
	EndIf
	; hand the bitmap to the picture control, free the previous one
	Local $hHBmp = _GDIPlus_BitmapCreateHBITMAPFromBitmap($hBmp)
	Local $hOld = GUICtrlSendMsg($idPic, 0x0172, 0, $hHBmp) ; STM_SETIMAGE, IMAGE_BITMAP
	If $hOld Then DllCall("gdi32.dll", "bool", "DeleteObject", "handle", $hOld)
	_GDIPlus_PenDispose($hPenGrid)
	_GDIPlus_PenDispose($hPenA)
	_GDIPlus_PenDispose($hPenB)
	_GDIPlus_BrushDispose($hBrGray)
	_GDIPlus_BrushDispose($hBrA)
	_GDIPlus_BrushDispose($hBrB)
	_GDIPlus_StringFormatDispose($hFmt)
	_GDIPlus_FontDispose($hFont)
	_GDIPlus_FontFamilyDispose($hFam)
	_GDIPlus_GraphicsDispose($hCtx)
	_GDIPlus_BitmapDispose($hBmp)
EndFunc   ;==>_DrawGraph
; ---------- alerts ----------
; $sStatus = "" if the modem was unreachable. Fires TrayTips (if enabled) and always logs.
Func _Alerts($sStatus, $iUptime, $vSnrDown)
	Local $sNew = $sStatus
	If $sNew = "" Then $sNew = "unreachable"
	If $g_bHavePrev Then
		If Not ($sNew == $g_sPrevStatus) Then
			_Log("Line status: " & $g_sPrevStatus & " -> " & $sNew)
			If $g_bNotify Then TrayTip($APP_NAME, "Line status: " & $g_sPrevStatus & " -> " & $sNew, 10, $TIP_ICONEXCLAMATION)
		EndIf
		If _Has($iUptime) And _Has($g_iPrevUptime) Then
			If $iUptime < $g_iPrevUptime Then
				$g_iResyncs += 1
				_Log("Resync detected (line uptime was reset)")
				If $g_bNotify Then TrayTip($APP_NAME, "Resync detected - the line uptime was reset.", 10, $TIP_ICONEXCLAMATION)
			EndIf
		EndIf
	EndIf
	If $g_fSnrAlert > 0 And _Has($vSnrDown) Then
		If $vSnrDown < $g_fSnrAlert Then
			If Not $g_bSnrAlerted Then
				$g_bSnrAlerted = True
				_Log("SNR down " & $vSnrDown & " dB is below " & $g_fSnrAlert & " dB")
				If $g_bNotify Then TrayTip($APP_NAME, "SNR down " & $vSnrDown & " dB is below " & $g_fSnrAlert & " dB", 10, $TIP_ICONEXCLAMATION)
			EndIf
		ElseIf $g_bSnrAlerted Then
			$g_bSnrAlerted = False
			_Log("SNR down is back above " & $g_fSnrAlert & " dB")
		EndIf
	EndIf
	$g_bHavePrev = True
	$g_sPrevStatus = $sNew
	If _Has($iUptime) Then $g_iPrevUptime = $iUptime
EndFunc   ;==>_Alerts
; forget the live values (keeps the firmware info)
Func _ClearLive()
	$g_sStatus = ""
	$g_sMode = ""
	$g_sProfile = ""
	$g_sAnnex = ""
	$g_sDslVer = ""
	$g_sEnhance = ""
	$g_vDown = ""
	$g_vUp = ""
	$g_vSnrD = ""
	$g_vSnrU = ""
	$g_vTarget = ""
	$g_vAttD = ""
	$g_vAttU = ""
	$g_hAtt = 0 ; query the attainable rates again on the next successful poll
	$g_iUptime = ""
EndFunc   ;==>_ClearLive
; ---------- update cycle ----------
Func _Update()
	$g_bUpdating = True
	$g_bBusy = True
	_UiHeader()
	TraySetToolTip($APP_NAME & " - updating...")
	Local $sRaw = _FetchDslInfo($g_sModemHost, $g_sModemUser, $g_sModemPass, $g_sPlink, True, True)
	$g_bUpdating = False
	$g_sLastRaw = $sRaw
	$g_bPolled = True
	$g_sLastTime = StringFormat("%02d:%02d:%02d", @HOUR, @MIN, @SEC)
	Local $sStatus = _Field($sRaw, "Status")
	Local $sPk, $sTip
	If $sStatus = "" Then
		$g_iPollFail += 1
		$g_bOnline = False
		_ClearLive()
		_Alerts("", "", "")
		_HistAdd("", "", "", "")
		_CsvLog("offline", "", "", "", "", "")
		_Log("Poll failed: " & _FirstLine($sRaw))
		$sPk = _Pkt($T_AVAIL, "offline")
		$sTip = _TipHead() & @CRLF & "Modem unreachable"
	Else
		Local $vDown = _ToNum(_Field($sRaw, "Downstream Line Rate"), 1000)
		Local $vUp = _ToNum(_Field($sRaw, "Upstream Line Rate"), 1000)
		Local $vSnrDown = _ToNum(_Field($sRaw, "SNR Downstream"), 1)
		Local $vSnrUp = _ToNum(_Field($sRaw, "SNR Upstream"), 1)
		Local $vAttD = _ToNum(_StreamCell($sRaw, "Attainable Rate", 1), 1000)
		Local $vAttU = _ToNum(_StreamCell($sRaw, "Attainable Rate", 2), 1000)
		If Not $g_bAttRan Then ; not queried this round -> keep the last values
			$vAttD = $g_vAttD
			$vAttU = $g_vAttU
			If Not _Has($vAttD) Then $g_hAtt = 0 ; nothing yet (e.g. after the Test button) -> query on the next poll
		EndIf
		Local $vUptime = _UptimeSec(_Field($sRaw, "Line Uptime"))
		Local $vMonUptime = Int(TimerDiff($g_hStart) / 1000)
		; 35b settings (read-only): enhance is 0/1, target is a raw number
		Local $sEnhance = _Field($sRaw, "35b_enhance status")
		If $sEnhance = "1" Then
			$sEnhance = "enabled"
		ElseIf $sEnhance = "0" Then
			$sEnhance = "disabled"
		Else
			$sEnhance = "unknown"
		EndIf
		Local $vTarget = _ToNum(_Field($sRaw, "35b_target"), 1)
		Local $sJson = '{"status":"' & _J($sStatus) & '"' & _
				',"mode":"' & _J(_Field($sRaw, "Mode")) & '"' & _
				',"profile":"' & _J(_Field($sRaw, "Profile")) & '"' & _
				',"annex":"' & _J(_Field($sRaw, "Annex")) & '"' & _
				',"dsl_version":"' & _J(_Field($sRaw, "DSL Version")) & '"' & _
				',"down":' & _JNum($vDown) & ',"up":' & _JNum($vUp) & _
				',"snr_down":' & _JNum($vSnrDown) & ',"snr_up":' & _JNum($vSnrUp) & _
				',"attain_down":' & _JNum($vAttD) & ',"attain_up":' & _JNum($vAttU) & _
				',"uptime":' & _JNum($vUptime) & _
				',"monitor_uptime":' & _JNum($vMonUptime) & _
				',"enhance":"' & $sEnhance & '"' & _
				',"target":' & _JNum($vTarget) & _
				',"fw":"' & _J(_Field($sRaw, "Firmware Version")) & '"' & _
				',"fw_model":"' & _J(_Field($sRaw, "Model Name")) & '"' & _
				',"fw_device":"' & _J(_Field($sRaw, "Device Name")) & '"' & _
				',"fw_build":"' & _J(_Field($sRaw, "Build Time")) & '"' & _
				',"fw_branch":"' & _J(_Field($sRaw, "Branch")) & '"' & _
				',"fw_release":"' & _J(_Field($sRaw, "Release Mode")) & '"' & _
				',"fw_web":"' & _J(_Field($sRaw, "Web Version")) & '"' & _
				',"fw_core":"' & _J(_Field($sRaw, "Core Version")) & '"' & _
				',"fw_boot":"' & _J(_Field($sRaw, "Bootloader Version")) & '"' & _
				',"fw_country":"' & _J(_Field($sRaw, "CountryCode")) & '"}'
		; keep the values for the window
		$g_iPollOk += 1
		$g_bOnline = True
		$g_sStatus = $sStatus
		$g_sMode = _Field($sRaw, "Mode")
		$g_sProfile = _Field($sRaw, "Profile")
		$g_sAnnex = _Field($sRaw, "Annex")
		$g_sDslVer = _Field($sRaw, "DSL Version")
		$g_sEnhance = $sEnhance
		$g_vDown = $vDown
		$g_vUp = $vUp
		$g_vSnrD = $vSnrDown
		$g_vSnrU = $vSnrUp
		$g_vAttD = $vAttD
		$g_vAttU = $vAttU
		If $g_bAttRan And Not _Has($vAttD) And Not $g_bAttWarned Then
			$g_bAttWarned = True
			_Log("Attainable rates: no 'Attainable Rate' found in the config submenu output - check the Raw tab (section '--- config submenu ---').")
		EndIf
		$g_vTarget = $vTarget
		$g_iUptime = $vUptime
		$g_hUptime = TimerInit()
		For $i = 0 To 9
			$g_aFw[$i] = _Field($sRaw, $FW_KEYS[$i])
		Next
		; model name comes from the modem itself; (re)send discovery on first success or when it changes
		Local $sModel = _Field($sRaw, "Model Name")
		If $sModel <> "" And $sModel <> $g_sModel Then
			$g_sModel = $sModel
			$g_bDisc = False
		EndIf
		If Not $g_bDisc Then $g_bDisc = _Publish(_DiscoveryPackets())
		$sPk = _Pkt($T_STATE, $sJson) & _Pkt($T_AVAIL, "online")
		$sTip = _TipHead() & " / " & $sStatus & @CRLF & "Down " & $vDown & " / Up " & $vUp & " Mbit/s" & @CRLF & "SNR Down " & $vSnrDown & " / Up " & $vSnrUp & " dB"
		_Alerts($sStatus, $vUptime, $vSnrDown)
		_HistAdd($vDown, $vUp, $vSnrDown, $vSnrUp)
		_CsvLog($sStatus, $vDown, $vUp, $vSnrDown, $vSnrUp, $vUptime)
		_Log("Poll OK - " & $sStatus & ", down " & $vDown & " / up " & $vUp & " Mbit/s, SNR " & $vSnrDown & " / " & $vSnrUp & " dB")
	EndIf
	If Not $g_bMqttOn Then
		$g_sMqttState = "disabled"
	ElseIf _Publish($sPk) Then
		$g_sMqttState = "OK"
		$g_sMqttPrevErr = ""
	Else
		$g_sMqttState = "error (see Log)"
		$sTip &= @CRLF & "(MQTT error)"
		If Not ($g_sMqttErr == $g_sMqttPrevErr) Then _Log("MQTT error: " & $g_sMqttErr)
		$g_sMqttPrevErr = $g_sMqttErr
	EndIf
	$g_bBusy = False
	TraySetToolTip(StringLeft($sTip, 127)) ; tray tooltips are limited to 127 chars
	_UiRefresh()
EndFunc   ;==>_Update
; first tooltip line: modem model (from sysinfo) or the app name until it is known
Func _TipHead()
	If $g_sModel <> "" Then Return $g_sModel
	Return $APP_NAME
EndFunc   ;==>_TipHead
; ---------- modem ----------
; Keeps ONE plink/SSH session open between polls (the modem only has a handful of PTYs,
; opening + killing a session every poll leaked them until the modem ran out).
; $bExtras  = also run the read-only sysinfo / 35b commands (slower, used by the update cycle)
; $bPersist = reuse/keep the global session (update cycle). False = one-shot session that is
;             closed cleanly afterwards (used by the "Test modem" button).
Func _FetchDslInfo($sHost, $sUser, $sPass, $sPlink, $bExtras = False, $bPersist = False)
	Local $iPid, $sRaw = "", $bReused
	For $iTry = 1 To 2
		$bReused = False
		; proactively recycle a long-lived session with a clean logout before it
		; wedges - a stuck-then-hard-killed session is what leaks the modem's slots
		If $bPersist And $g_iSsh <> 0 And $g_hSshAge <> 0 And TimerDiff($g_hSshAge) > $g_iSshMaxAge Then _SshDrop()
		If $bPersist And $g_iSsh > 0 And Not ProcessExists($g_iSsh) Then $g_iSsh = 0 ; plink session died on its own
		If $bPersist And $g_iSsh <> 0 Then
			$iPid = $g_iSsh
			$bReused = True
		Else
			$iPid = _SshOpen($sHost, $sUser, $sPass, $sPlink)
			If $iPid = 0 Then Return $g_sSshErr
			If $bPersist Then
				$g_iSsh = $iPid
				$g_hSshAge = TimerInit()
			EndIf
		EndIf
		$sRaw = _SshQuery($iPid, $bExtras)
		If Not $bPersist Then
			_SshClose($iPid)
			Return $sRaw
		EndIf
		If _Field($sRaw, "Status") <> "" Then Return $sRaw
		; no usable answer -> drop the session; retry once with a fresh one if the old one was reused
		_SshDrop()
		If Not $bReused Then ExitLoop ; a fresh session failed as well -> wait for the next poll
	Next
	Return $sRaw
EndFunc   ;==>_FetchDslInfo
; resolves a working plink.exe: configured path -> script folder -> system PATH ->
; last resort: auto-download the official binary into the script folder.
; Returns "" if nothing works.
Func _ResolvePlink($sConfigured)
	If $sConfigured <> "" And FileExists($sConfigured) Then Return $sConfigured
	Local $sLocal = @ScriptDir & "\plink.exe"
	If FileExists($sLocal) Then Return $sLocal
	Local $sInPath = _WhichExe("plink.exe")
	If $sInPath <> "" Then Return $sInPath
	If _DownloadPlink($sLocal) Then Return $sLocal
	Return ""
EndFunc   ;==>_ResolvePlink
; looks up an .exe name via the Windows system PATH ("where"); "" if not found
Func _WhichExe($sExeName)
	Local $iPid = Run(@ComSpec & " /c where " & $sExeName, "", @SW_HIDE, $STDOUT_CHILD)
	ProcessWaitClose($iPid, 3)
	Local $sOut = StringStripCR(StdoutRead($iPid))
	If @error Then Return ""
	Local $aLines = StringSplit($sOut, @LF, 1)
	For $i = 1 To $aLines[0]
		If FileExists($aLines[$i]) Then Return $aLines[$i]
	Next
	Return ""
EndFunc   ;==>_WhichExe
; downloads plink.exe from the official PuTTY site (with a mirror fallback) to $sDest
Func _DownloadPlink($sDest)
	TrayTip($APP_NAME, "plink.exe not found - downloading it from the official PuTTY site...", 5)
	For $i = 0 To UBound($PLINK_URLS) - 1
		Local $iBytes = InetGet($PLINK_URLS[$i], $sDest, $INET_FORCERELOAD)
		If Not @error And $iBytes > 100000 And FileExists($sDest) Then Return True
		If FileExists($sDest) Then FileDelete($sDest) ; partial/broken download
	Next
	Return False
EndFunc   ;==>_DownloadPlink
; opens plink, does the SSH + CLI login, returns the PID (0 on failure, reason in $g_sSshErr)
Func _SshOpen($sHost, $sUser, $sPass, $sPlink)
	$g_sSshErr = ""
	Local $iPid
	If $g_bTelnet Then
		; built-in Telnet: plain TCP socket, no external program (works under Wine). Handle is NEGATIVE = socket.
		$iPid = _TelnetConnect($sHost)
		If $iPid = 0 Then Return 0
	Else
		$sPlink = _ResolvePlink($sPlink)
		If $sPlink = "" Then
			$g_sSshErr = "ERROR: plink.exe not found (checked the configured path, PATH and the script folder) and the automatic download failed - check your internet connection or place plink.exe manually"
			Return 0
		EndIf
		Local $sCmd = '"' & $sPlink & '" -ssh -batch -l ' & $sUser & ' -pw "' & $sPass & '" ' & $sHost
		$iPid = Run($sCmd, @ScriptDir, @SW_HIDE, BitOR($STDIN_CHILD, $STDOUT_CHILD, $STDERR_MERGED))
		If @error Then
			$g_sSshErr = "ERROR: could not start plink"
			Return 0
		EndIf
	EndIf
	Local $sAll = "", $sNew, $aPrompt, $iWait
	For $i = 1 To 6
		$iWait = 4000
		If $i = 1 Then $iWait = 15000
		$sNew = _ReadUntilQuiet($iPid, 800, 15000, $iWait)
		$sAll &= $sNew
		If $sNew = "" Then
			_SshClose($iPid)
			$g_sSshErr = "ERROR: no data from plink (round " & $i & ")" & @CRLF & "---" & @CRLF & $sAll
			Return 0
		EndIf
		If StringInStr($sNew, "Access denied") Then
			_SshClose($iPid)
			$g_sSshErr = "ERROR: access denied" & @CRLF & "---" & @CRLF & $sAll
			Return 0
		EndIf
		; modem CLI has its own Username:/Password: prompts after the SSH login
		$aPrompt = StringRegExp(StringLower(StringStripWS($sNew, 2)), "(username|account|login|password):$", 1)
		If @error Then Return $iPid ; no more prompts -> logged in at the CLI
		If $aPrompt[0] = "password" Then
			_IoWrite($iPid, $sPass & @CR)
		Else
			_IoWrite($iPid, $sUser & @CR)
		EndIf
	Next
	_SshClose($iPid)
	$g_sSshErr = "ERROR: login loop did not finish" & @CRLF & "---" & @CRLF & $sAll
	Return 0
EndFunc   ;==>_SshOpen
; runs the read-only commands on an open session and returns the raw output
Func _SshQuery($iPid, $bExtras)
	Local $sAll = ""
	_ReadUntilQuiet($iPid, 100, 500, 100) ; throw away leftovers (prompt etc.) from the previous round
	_IoWrite($iPid, "exec dslinfo" & @CR)
	$sAll &= _ReadUntilQuiet($iPid, 1500, 10000, 4000)
	If $bExtras Then
		; read-only commands only - never send the setter variants (e.g. "exec dsl_35b_target 2048") from here
		Local $aExtra[3] = ["exec sysinfo", "exec dsl_35b_enhance status", "exec dsl_35b_target show"]
		For $c = 0 To UBound($aExtra) - 1
			If $aExtra[$c] = "" Then ContinueLoop
			_IoWrite($iPid, $aExtra[$c] & @CR)
			$sAll &= _ReadUntilQuiet($iPid, 700, 5000, 3000)
		Next
		; attainable rates are only in the config submenu: enter it, dump the JSON, leave it again.
		; Every step waits for the modem's PROMPT (typing ahead while the CLI switches menus gets swallowed),
		; and the whole dialogue goes into the raw output so the Raw tab shows exactly what happened.
		$g_bAttRan = ($g_hAtt = 0 Or TimerDiff($g_hAtt) >= $g_iAttInterval * 1000)
		If $g_bAttRan Then
			$g_hAtt = TimerInit()
			Local $sLast, $sCfgPrompt = "(?i)\(config[^)]*\)>$"
			_IoWrite($iPid, "config Monitoring DSL_Status Monitoring_DSL_General" & @CR)
			$sLast = _ReadUntilPrompt($iPid, $sCfgPrompt, 6000)
			$sAll &= @CRLF & "--- config submenu ---" & @CRLF & $sLast
			If StringRegExp(StringStripWS($sLast, 2), $sCfgPrompt) Then
				_IoWrite($iPid, "show all" & @CR)
				$sLast = _ReadUntilPrompt($iPid, $sCfgPrompt, 40000, True)
				$sAll &= $sLast
			EndIf
			; leave the submenu: "exit" only while the prompt still says (config...), at the top level it would log us out
			For $c = 1 To 4
				If Not StringRegExp(StringStripWS($sLast, 2), $sCfgPrompt) Then ExitLoop
				_IoWrite($iPid, "exit" & @CR)
				$sLast = _ReadUntilPrompt($iPid, ">$", 4000)
				$sAll &= $sLast
			Next
		EndIf
	EndIf
	Return $sAll
EndFunc   ;==>_SshQuery
; clean shutdown: CLI "exit" and wait for plink to quit by itself. If it doesn't, StdioClose()
; closes the pipes (plink sees EOF and disconnects properly). Kill is the last resort.
Func _SshClose($iPid)
	If $iPid = 0 Then Return
	If $iPid < 0 Then ; Telnet socket: CLI logout, then close the connection
		_IoWrite($iPid, "exit" & @CR)
		_Nap(300)
		TCPCloseSocket(-$iPid)
		Return
	EndIf
	If ProcessExists($iPid) Then
		; 1) ask the modem CLI to log out
		StdinWrite($iPid, "exit" & @CR)
		_Nap(300)
		; 2) close our stdin -> plink sees EOF and sends a proper SSH disconnect.
		;    This is what actually frees the modem's PTY/SSH slot; a hard kill
		;    leaves the slot occupied until the modem's own TCP timeout, and over
		;    days of polling that exhausts the daemon (SSH "dies" after 2-3 days).
		StdioClose($iPid)
		_WaitClose($iPid, 8) ; give the clean disconnect time to complete
	Else
		StdioClose($iPid)
	EndIf
	If ProcessExists($iPid) Then ProcessClose($iPid) ; last resort only
EndFunc   ;==>_SshClose
; closes the persistent session (if any)
Func _SshDrop()
	_SshClose($g_iSsh)
	$g_iSsh = 0
	$g_hSshAge = 0
EndFunc   ;==>_SshDrop
; ---------- transport helpers: plink pipes (handle > 0 = PID) or Telnet socket (handle < 0 = -socket) ----------
Func _TelnetConnect($sHost)
	Local $sIP = TCPNameToIP($sHost)
	If $sIP = "" Then
		$g_sSshErr = "ERROR: cannot resolve " & $sHost
		Return 0
	EndIf
	Local $iSock = TCPConnect($sIP, $g_iTelnetPort)
	If @error Or $iSock <= 0 Then
		$g_sSshErr = "ERROR: cannot connect to " & $sIP & ":" & $g_iTelnetPort & " (is Telnet enabled on the modem?)"
		Return 0
	EndIf
	Return -$iSock
EndFunc   ;==>_TelnetConnect
Func _IoWrite($h, $s)
	If $h > 0 Then
		StdinWrite($h, $s)
		Return
	EndIf
	; Telnet: line ends with CR NUL, text is UTF-8 (never contains 0xFF, so no IAC escaping needed)
	TCPSend(-$h, Binary("0x" & _HexRaw(StringReplace($s, @CR, "")) & "0D00"))
EndFunc   ;==>_IoWrite
; sends the text as is (no line ending), e.g. a single key for the pager
Func _IoWriteRaw($h, $s)
	If $h > 0 Then
		StdinWrite($h, $s)
	Else
		TCPSend(-$h, Binary("0x" & _HexRaw($s)))
	EndIf
EndFunc   ;==>_IoWriteRaw
Func _IoRead($h)
	Local $sData, $iErr
	If $h > 0 Then
		$sData = StdoutRead($h)
	Else
		$sData = _TelnetRead(-$h)
	EndIf
	$iErr = @error
	Return SetError($iErr, 0, $sData)
EndFunc   ;==>_IoRead
; reads what the modem sent, strips Telnet option negotiation (answers every DO with WONT, every WILL with DONT)
; @error is set when the connection is closed
Func _TelnetRead($iSock)
	Local $bRaw = TCPRecv($iSock, 4096, 1)
	Local $iErr = @error
	If $iErr Then Return SetError(1, 0, "")
	Local $n = BinaryLen($bRaw)
	If $n = 0 Then Return ""
	Local $sOut = "", $sReply = "", $i = 1, $c, $c2, $c3
	While $i <= $n
		$c = Int(BinaryMid($bRaw, $i, 1))
		If $c <> 255 Then
			If $c <> 0 Then $sOut &= Chr($c)
			$i += 1
			ContinueLoop
		EndIf
		If $i + 1 > $n Then ExitLoop
		$c2 = Int(BinaryMid($bRaw, $i + 1, 1))
		Switch $c2
			Case 253, 251 ; DO / WILL
				If $i + 2 > $n Then ExitLoop
				$c3 = Int(BinaryMid($bRaw, $i + 2, 1))
				If $c2 = 253 Then
					$sReply &= "FFFC" & Hex($c3, 2) ; WONT
				Else
					$sReply &= "FFFE" & Hex($c3, 2) ; DONT
				EndIf
				$i += 3
			Case 252, 254 ; WONT / DONT
				$i += 3
			Case 250 ; subnegotiation: skip until IAC SE
				$i += 2
				While $i < $n
					If Int(BinaryMid($bRaw, $i, 1)) = 255 And Int(BinaryMid($bRaw, $i + 1, 1)) = 240 Then
						$i += 2
						ExitLoop
					EndIf
					$i += 1
				WEnd
			Case 255 ; escaped data byte 255
				$sOut &= Chr(255)
				$i += 2
			Case Else
				$i += 2
		EndSwitch
	WEnd
	If $sReply <> "" Then TCPSend($iSock, Binary("0x" & $sReply))
	Return $sOut
EndFunc   ;==>_TelnetRead
; reads until the (right-trimmed) buffer ends with something matching the regex $sPattern (a prompt),
; or $iMaxMs have passed / the connection closed. Returns everything received.
; $bPager: the modem CLI pages long output with "--More--" and waits for a key -> answer it with a space
; and cut the marker (plus the erase characters after it) out of the returned text.
Func _ReadUntilPrompt($iPid, $sPattern, $iMaxMs, $bPager = False)
	Local $sBuf = "", $sChunk
	Local $hTotal = TimerInit()
	While TimerDiff($hTotal) < $iMaxMs
		$sChunk = _IoRead($iPid)
		If $sChunk <> "" Then
			$sBuf &= $sChunk
			If StringRegExp(StringStripWS($sBuf, 2), $sPattern) Then ExitLoop
			If $bPager And StringRegExp(StringStripWS($sBuf, 2), "(?i)--\s*more\s*--$") Then _IoWriteRaw($iPid, " ")
		ElseIf @error Then
			ExitLoop
		EndIf
		Sleep(30)
		_Yield()
	WEnd
	If $bPager Then $sBuf = StringRegExpReplace($sBuf, "(?i)--\s*more\s*--(?:[ \x08\r]|\x1b\[[0-9;]*[A-Za-z])*", "")
	Return $sBuf
EndFunc   ;==>_ReadUntilPrompt
; $iFirstMs = max wait for the first byte, afterwards $iQuietMs of silence ends the read
Func _ReadUntilQuiet($iPid, $iQuietMs, $iMaxMs, $iFirstMs)
	Local $sBuf = "", $sChunk
	Local $hTotal = TimerInit(), $hQuiet = TimerInit()
	While TimerDiff($hTotal) < $iMaxMs
		$sChunk = _IoRead($iPid)
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
		Sleep(30)
		_Yield()
	WEnd
	Return $sBuf
EndFunc   ;==>_ReadUntilQuiet
; ---------- parsing ----------
Func _Field($sText, $sKey)
	Local $a = StringRegExp($sText, "(?m)^\s*" & $sKey & "\s*:\s*(.*?)\s*$", 1)
	If @error Then Return ""
	Return $a[0]
EndFunc   ;==>_Field
; cell of the JSON "Stream_Table" row $sName: $iCol 1 = Downstream, 2 = Upstream ("" if not found)
Func _StreamCell($sRaw, $sName, $iCol)
	Local $a = StringRegExp($sRaw, '(?s)"Name":\s*"' & $sName & '",\s*"Downstream":\s*"([^"]*)",\s*"Upstream":\s*"([^"]*)"', 1)
	If @error Then Return ""
	Return $a[$iCol - 1]
EndFunc   ;==>_StreamCell
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
	$s &= _DiscPkt("status", "DSL Status", "status", "", "", "", "mdi:router-network", _
			"'mode':value_json.mode,'profile':value_json.profile,'annex':value_json.annex,'dsl_version':value_json.dsl_version")
	$s &= _DiscPkt("downstream_rate", "DSL Downstream Rate", "down", "Mbit/s", "data_rate", "measurement", "")
	$s &= _DiscPkt("upstream_rate", "DSL Upstream Rate", "up", "Mbit/s", "data_rate", "measurement", "")
	$s &= _DiscPkt("attainable_down", "DSL Attainable Downstream Rate", "attain_down", "Mbit/s", "data_rate", "measurement", "")
	$s &= _DiscPkt("attainable_up", "DSL Attainable Upstream Rate", "attain_up", "Mbit/s", "data_rate", "measurement", "")
	$s &= _DiscPkt("snr_downstream", "DSL SNR Downstream", "snr_down", "dB", "", "measurement", "mdi:sine-wave")
	$s &= _DiscPkt("snr_upstream", "DSL SNR Upstream", "snr_up", "dB", "", "measurement", "mdi:sine-wave")
	$s &= _DiscPkt("uptime", "DSL Line Uptime", "uptime", "s", "duration", "measurement", "")
	; diagnostic sensors (read-only)
	$s &= _DiscPkt("monitor_uptime", "DSL Monitor Uptime", "monitor_uptime", "s", "duration", "measurement", "mdi:timer-outline", "", True)
	$s &= _DiscPkt("35b_enhance", "DSL 35b Enhance", "enhance", "", "", "", "mdi:tune", "", True)
	$s &= _DiscPkt("35b_target", "DSL 35b Target", "target", "", "", "", "mdi:target", "", True)
	$s &= _DiscPkt("firmware", "DSL Modem Firmware", "fw", "", "", "", "mdi:chip", _
			"'model':value_json.fw_model,'device_name':value_json.fw_device,'build_time':value_json.fw_build," & _
			"'branch':value_json.fw_branch,'release_mode':value_json.fw_release,'web_version':value_json.fw_web," & _
			"'core_version':value_json.fw_core,'bootloader_version':value_json.fw_boot,'country_code':value_json.fw_country", True)
	Return $s
EndFunc   ;==>_DiscoveryPackets
; $sAttrs = body of a Jinja dict for the entity attributes (optional), $bDiag = show under "Diagnostic"
Func _DiscPkt($sObj, $sName, $sField, $sUnit, $sDevClass, $sStateClass, $sIcon, $sAttrs = "", $bDiag = False)
	Local $iExpire = $g_iInterval * 3
	If $iExpire < 180 Then $iExpire = 180
	Local $s = '{"name":"' & $sName & '","unique_id":"vigor_xdsl_' & $sObj & '"' & _
			',"state_topic":"' & $T_STATE & '"' & _
			',"value_template":"{{ value_json.' & $sField & ' }}"' & _
			',"availability_topic":"' & $T_AVAIL & '"' & _
			',"expire_after":' & $iExpire
	If $sUnit <> "" Then $s &= ',"unit_of_measurement":"' & $sUnit & '"'
	If $sDevClass <> "" Then $s &= ',"device_class":"' & $sDevClass & '"'
	If $sStateClass <> "" Then $s &= ',"state_class":"' & $sStateClass & '"'
	If $sIcon <> "" Then $s &= ',"icon":"' & $sIcon & '"'
	If $bDiag Then $s &= ',"entity_category":"diagnostic"'
	If $sAttrs <> "" Then
		$s &= ',"json_attributes_topic":"' & $T_STATE & '"' & _
				',"json_attributes_template":"{{ {' & $sAttrs & '} | tojson }}"'
	EndIf
	Local $sModel = $g_sModel
	If $sModel = "" Then $sModel = "Vigor"
	Local $sDevName = $sModel
	If Not StringInStr($sDevName, "DrayTek") Then $sDevName = "DrayTek " & $sDevName
	$s &= ',"device":{"identifiers":["vigor_xdsl"],"name":"' & _J($sDevName) & '","manufacturer":"DrayTek","model":"' & _J($sModel) & '"}}'
	Return _Pkt($g_sDiscPrefix & "/sensor/vigor_xdsl/" & $sObj & "/config", $s)
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
	Local $iLen = BinaryLen($bData), $iSent = 0, $R
	While $iSent < $iLen
		$R = TCPSend($iSock, BinaryMid($bData, $iSent + 1))
		If @error Then Return False
		$iSent += $R
	WEnd
	Return True
EndFunc   ;==>_SendHex
; publish with the configured broker
Func _Publish($sPackets)
	If Not $g_bMqttOn Then
		$g_sMqttErr = ""
		Return True
	EndIf
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
	Local $sPayload = _HexStr($g_sClientId)
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
		_Yield()
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
	_Nap(200)
	TCPCloseSocket($iSock)
	If Not $bOk Then $g_sMqttErr = "Sending PUBLISH failed"
	Return $bOk
EndFunc   ;==>_MqttSession
