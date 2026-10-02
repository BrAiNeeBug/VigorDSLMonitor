#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_Icon=vigor_xdsl_monitor.ico
#AutoIt3Wrapper_Outfile_x64=vigor_xdsl_monitor.exe
#AutoIt3Wrapper_UseUpx=y
#AutoIt3Wrapper_Res_Fileversion=0.4.2.0
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
Global Const $APP_NAME = "Vigor-xDSL-Monitor"
Global Const $APP_URL = "https://github.com/BrAiNeeBug/VigorDSLMonitor"
Global Const $APP_VER = "0.4"
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
Global $g_bMqttDiag = True ; publish the diagnostic sensors (error counters, trellis, ...) to MQTT / HA
Global $g_fSnrAlert ; 0 = off
; runtime state
Global $g_bDisc = False, $g_bPaused = False, $g_bRunning = False
Global $g_sLastRaw = "", $g_sMqttErr = "", $g_sModel = "" ; $g_sModel = model name read from the modem (for the HA device)
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
; Extended line data (attainable rates, trellis, bitswap, error counters, ...) only exists in the slow config-submenu
; "show all" (10+ s). It is read at program start, after every (re)connect / resync / line-up and otherwise only every
; $g_iExtInterval seconds (never less than $EXT_MIN_FACTOR x the normal poll interval).
Global Const $EXT_MIN_FACTOR = 5
Global $g_iExtInterval = 900, $g_hExt = 0, $g_bExtRan = False, $g_bExtHave = False, $g_hExtOk = 0, $g_iExtFail = 0
; rows of the End_Table in the "show all" JSON. Kind of each row:
; T = feature (text "near / far"), A = attenuation (dB), E = error counter (HA sensor, red in the GUI when > 0),
; N = normal counter (HA sensor), H = like E but no HA sensor, O = only GUI + MQTT state JSON
Global Const $EXT_NAMES[20] = ["Trellis", "Bitswap", "ReTx", "Attenuation", "CRC", "FECS", "ES", "SES", "LOSS", "UAS", _
		"HEC Errors", "RS Corrections", "LOS Failure", "LOF Failure", "LPR Failure", "NCD Failure", "LCD Failure", "NFEC", "RFEC", "LYSMB"]
Global Const $EXT_KIND = "TTTAEOEEHNEOEEEHEONO"
Global Const $STR_NAMES[3] = ["Path Mode", "Interleave Depth", "Actual PSD"] ; rows of the Stream_Table (down / up)
Global $g_aEnd[20][2], $g_aStr[3][2] ; [row][0] = near end / downstream, [row][1] = far end / upstream
Global $g_sPwrMode = "", $g_sVidR = "", $g_sVidC = "" ; power management mode, modem (ATU-R) and DSLAM (ATU-C) vendor ID
Global $g_sExtRaw = "", $g_sExtRawTime = "" ; last extended output, kept for the Raw tab
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
Global $g_hGfxFam = 0, $g_hGfxFont = 0, $g_bGfxGeneric = False, $g_bGfxWarned = False ; graph font (created once)
Global $g_idHdr, $g_idSub, $g_idTab, $g_idTiRaw
Global $g_idDown, $g_idUp, $g_idSnrD, $g_idSnrU
Global $g_idAttD, $g_idAttU, $g_idMonUpt, $g_idUpt, $g_idMode, $g_idProf, $g_idAnnex, $g_idDslV, $g_idEnh, $g_idTgt
Global $g_idLast, $g_idNext, $g_idSsh, $g_idMqttS, $g_idPolls, $g_idResync
Global $g_aFwId[10]
Global $g_aFeatId[4], $g_aExtId[20][2], $g_aStrId[3], $g_idPwr, $g_idVidR, $g_idVidC, $g_idExtLast, $g_idExtNext
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
; no tray menu (breaks the double-click on the icon under Wine): double-click the icon to show the window, Exit is in the window
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
	If $g_hGfxFont <> 0 Then _GDIPlus_FontDispose($g_hGfxFont)
	If $g_hGfxFam <> 0 And Not $g_bGfxGeneric Then _GDIPlus_FontFamilyDispose($g_hGfxFam)
	_GDIPlus_Shutdown()
EndFunc   ;==>_Exit
; ---------- events ----------
; Handles tray + window events. Returns False when the program should quit.
; Never runs anything slow itself (Update / Pause / Settings are only queued in $g_iReq),
; so it is safe to call from inside a running poll.
Func _HandleEvents()
	Local $iMsg = TrayGetMsg()
	Switch $iMsg
		Case $TRAY_EVENT_PRIMARYDOUBLE
			_WinShow()
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
	$g_bMqttDiag = (Int(IniRead($INI_FILE, "mqtt", "diag_sensors", "1")) <> 0)
	$T_STATE = $g_sTopicBase & "/state"
	$T_AVAIL = $g_sTopicBase & "/availability"
	$g_iInterval = Int(IniRead($INI_FILE, "general", "interval", "60"))
	If $g_iInterval < 15 Then $g_iInterval = 15 ; do not hammer the modem
	If $g_iInterval > 3600 Then $g_iInterval = 3600
	; "ext_interval" replaces the old "attain_interval" key (still read as a fallback)
	$g_iExtInterval = Int(IniRead($INI_FILE, "general", "ext_interval", IniRead($INI_FILE, "general", "attain_interval", "900")))
	If $g_iExtInterval < $EXT_MIN_FACTOR * $g_iInterval Then $g_iExtInterval = $EXT_MIN_FACTOR * $g_iInterval
	If $g_iExtInterval > 86400 Then $g_iExtInterval = 86400
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
	Local $bOldT, $iOldP, $iExt
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
	Local $iMDiag = GUICtrlCreateCheckbox("Publish diagnostic sensors (error counters, trellis, ...)", 22, 344, 368, 20)
	If $g_bMqttDiag Then GUICtrlSetState($iMDiag, $GUI_CHECKED)
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
	GUICtrlCreateLabel("Extended data (s)", 22, 263, 110, 18)
	Local $iExtInt = GUICtrlCreateInput($g_iExtInterval, 135, 260, 55, 22, $ES_NUMBER)
	GUICtrlCreateLabel("min. " & $EXT_MIN_FACTOR & " x interval, max 86400", 198, 263, 195, 18)
	GUICtrlCreateLabel("Slow query (10+ s): attainable rates, trellis, bitswap, error counters. " & _
			"It always runs once at start and after a reconnect / resync, otherwise only this often.", 22, 290, 368, 48)
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
				IniWrite($INI_FILE, "mqtt", "diag_sensors", Int(_Chk($iMDiag)))
				IniWrite($INI_FILE, "general", "interval", $iInterval)
				IniWrite($INI_FILE, "general", "ssh_max_hours", $iSsh)
				IniWrite($INI_FILE, "general", "history_len", $iHist)
				$iExt = Int(GUICtrlRead($iExtInt))
				If $iExt < $EXT_MIN_FACTOR * $iInterval Then $iExt = $EXT_MIN_FACTOR * $iInterval
				If $iExt > 86400 Then $iExt = 86400
				IniWrite($INI_FILE, "general", "ext_interval", $iExt)
				IniDelete($INI_FILE, "general", "attain_interval")
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
	; --- line stats (extended data from the slow "show all": features, error counters)
	GUICtrlCreateTabItem("Line stats")
	GUICtrlCreateGroup("Line features", 20, 102, 275, 326)
	Local $aFeat[4] = ["Trellis", "Bitswap", "ReTx", "Attenuation"]
	For $i = 0 To 3
		$g_aFeatId[$i] = _Row($aFeat[$i] & " (N/F)", 32, 122 + 22 * $i, 135, 115)
	Next
	Local $aStrCap[3] = ["Path mode (D/U)", "Interleave depth (D/U)", "Actual PSD (D/U)"]
	For $i = 0 To 2
		$g_aStrId[$i] = _Row($aStrCap[$i], 32, 216 + 22 * $i, 135, 115)
	Next
	$g_idPwr = _Row("Power mgmt mode", 32, 288, 135, 115)
	$g_idVidR = _Row("Modem vendor ID", 32, 310, 135, 115)
	$g_idVidC = _Row("DSLAM vendor ID", 32, 332, 135, 115)
	$g_idExtLast = _Row("Last extended read", 32, 360, 135, 115)
	$g_idExtNext = _Row("Next extended read", 32, 382, 135, 115)
	GUICtrlSetColor(GUICtrlCreateLabel("N = near end, F = far end, D = down, U = up", 32, 406, 250, 16), 0x666666)
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	GUICtrlCreateGroup("Error counters", 305, 102, 275, 326)
	GUICtrlSetColor(GUICtrlCreateLabel("Counter", 317, 122, 105, 17), 0x666666)
	GUICtrlSetColor(GUICtrlCreateLabel("Near end", 430, 122, 70, 17), 0x666666)
	GUICtrlSetColor(GUICtrlCreateLabel("Far end", 505, 122, 70, 17), 0x666666)
	For $i = 4 To 19
		GUICtrlCreateLabel($EXT_NAMES[$i], 317, 142 + 17 * ($i - 4), 110, 17)
		$g_aExtId[$i][0] = GUICtrlCreateLabel("-", 430, 142 + 17 * ($i - 4), 70, 17)
		$g_aExtId[$i][1] = GUICtrlCreateLabel("-", 505, 142 + 17 * ($i - 4), 70, 17)
	Next
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
	Local $d = Int($i / 86400), $h = Int(Mod($i, 86400) / 3600), $m = Int(Mod($i, 3600) / 60), $sec = Mod($i, 60)
	; human readable, starts at the largest non-zero unit: "3d 4h 12m 5s", "12m 5s", "5s"
	If $d > 0 Then Return $d & "d " & $h & "h " & $m & "m " & $sec & "s"
	If $h > 0 Then Return $h & "h " & $m & "m " & $sec & "s"
	If $m > 0 Then Return $m & "m " & $sec & "s"
	Return $sec & "s"
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
	If $g_bExtHave And $g_hExtOk <> 0 Then
		_SetTxt($g_idExtLast, _FmtAge(TimerDiff($g_hExtOk)) & " ago")
	Else
		_SetTxt($g_idExtLast, "-")
	EndIf
	If $g_hExt = 0 Then
		_SetTxt($g_idExtNext, "with next poll")
	Else
		Local $iNextMs = $g_iExtInterval * 1000 - TimerDiff($g_hExt)
		If $iNextMs < 0 Then $iNextMs = 0
		_SetTxt($g_idExtNext, "in " & _FmtAge($iNextMs))
	EndIf
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
	_UiExt()
	_UiTick()
	_DrawGraph($g_idGrRate, "Line rate (Mbit/s)", 1, "Down", "Up")
	_DrawGraph($g_idGrSnr, "SNR (dB)", 3, "Down", "Up")
EndFunc   ;==>_UiRefresh
; "near / far" style pair ("-" if both are empty)
Func _NF($a, $b)
	If Not _Has($a) And Not _Has($b) Then Return "-"
	Return _Dash($a) & " / " & _Dash($b)
EndFunc   ;==>_NF
; error counter cell: only touched when the text changes, red if it is a failure counter (kind E / H) and > 0
Func _SetErr($id, $s, $i)
	If $s == "" Then $s = "-"
	If GUICtrlRead($id) == $s Then Return
	GUICtrlSetData($id, $s)
	Local $iClr = 0x000000
	If StringInStr("EH", StringMid($EXT_KIND, $i + 1, 1)) And Number(StringRegExpReplace($s, "[^\d]", "")) > 0 Then $iClr = 0xC02020
	GUICtrlSetColor($id, $iClr)
EndFunc   ;==>_SetErr
; "Line stats" tab
Func _UiExt()
	For $i = 0 To 3
		_SetTxt($g_aFeatId[$i], _NF($g_aEnd[$i][0], $g_aEnd[$i][1]))
	Next
	For $i = 4 To 19
		_SetErr($g_aExtId[$i][0], $g_aEnd[$i][0], $i)
		_SetErr($g_aExtId[$i][1], $g_aEnd[$i][1], $i)
	Next
	For $i = 0 To 2
		_SetTxt($g_aStrId[$i], _NF($g_aStr[$i][0], $g_aStr[$i][1]))
	Next
	_SetTxt($g_idPwr, _Dash($g_sPwrMode))
	_SetTxt($g_idVidR, _Dash($g_sVidR))
	_SetTxt($g_idVidC, _Dash($g_sVidC))
EndFunc   ;==>_UiExt
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
; creates the graph font once. Tries Arial first (identical look on Windows), then fonts that exist
; in a typical Wine prefix, finally the generic sans-serif family. Returns False if nothing works.
Func _GfxFontInit()
	If $g_hGfxFont <> 0 Then Return True
	If $g_hGfxFam = 0 Then
		Local $aNames[6] = ["Arial", "Liberation Sans", "DejaVu Sans", "Tahoma", "Microsoft Sans Serif", "Segoe UI"]
		Local $h
		For $i = 0 To UBound($aNames) - 1
			$h = _GDIPlus_FontFamilyCreate($aNames[$i])
			If Not @error And $h <> 0 Then
				$g_hGfxFam = $h
				ExitLoop
			EndIf
		Next
		If $g_hGfxFam = 0 Then
			Local $aR = DllCall("gdiplus.dll", "int", "GdipGetGenericFontFamilySansSerif", "ptr*", 0)
			If Not @error And $aR[0] = 0 And $aR[1] <> 0 Then
				$g_hGfxFam = $aR[1]
				$g_bGfxGeneric = True
			EndIf
		EndIf
	EndIf
	If $g_hGfxFam <> 0 Then $g_hGfxFont = _GDIPlus_FontCreate($g_hGfxFam, 8)
	If $g_hGfxFont = 0 And Not $g_bGfxWarned Then
		$g_bGfxWarned = True
		_Log("Graph text: no usable font found, the graphs are drawn without labels")
	EndIf
	Return ($g_hGfxFont <> 0)
EndFunc   ;==>_GfxFontInit
Func _GfxText($hCtx, $sText, $nX, $nY, $hFont, $hFmt, $hBrush)
	If $hFont = 0 Then Return
	; real layout size: a 0 x 0 rect gets clipped away completely under Wine
	Local $tLayout = _GDIPlus_RectFCreate($nX, $nY, 150, 18)
	If Not _GDIPlus_GraphicsDrawStringEx($hCtx, $sText, $hFont, $tLayout, $hFmt, $hBrush) And Not $g_bGfxWarned Then
		$g_bGfxWarned = True
		_Log("Graph text: GDI+ DrawString failed (error " & @error & " / " & @extended & ")")
	EndIf
EndFunc   ;==>_GfxText
; $iCol = history column of the first series, the second series is $iCol + 1
Func _DrawGraph($idPic, $sTitle, $iCol, $sNameA, $sNameB)
	Local Const $W = 556, $h = 150, $L = 44, $R = 10, $T = 24, $b = 20
	Local Const $CLR_A = 0xFF39FF88, $CLR_B = 0xFFFF4FD8 ; neon green / magenta
	Local $hBmp = _GDIPlus_BitmapCreateFromScan0($W, $h)
	Local $hCtx = _GDIPlus_ImageGetGraphicsContext($hBmp)
	_GDIPlus_GraphicsSetSmoothingMode($hCtx, 2)
	_GDIPlus_GraphicsClear($hCtx, 0xFF15181E)
	_GfxFontInit()
	Local $hFont = $g_hGfxFont
	If $g_bWine Then _GDIPlus_GraphicsSetTextRenderingHint($hCtx, 3) ; AntiAliasGridFit: ClearType on an ARGB bitmap is unreliable in Wine
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
			$y = $T + ($h - $T - $b) * $k / 3
			_GDIPlus_GraphicsDrawLine($hCtx, $L, $y, $W - $R, $y, $hPenGrid)
			_GfxText($hCtx, StringFormat("%.1f", $fMax - $fRange * $k / 3), 2, $y - 7, $hFont, $hFmt, $hBrGray)
		Next
		; time labels (first / last sample)
		_GfxText($hCtx, $g_aHist[0][0], $L, $h - $b + 4, $hFont, $hFmt, $hBrGray)
		_GfxText($hCtx, $g_aHist[$g_iHistN - 1][0], $W - $R - 32, $h - $b + 4, $hFont, $hFmt, $hBrGray)
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
					$y = $T + ($h - $T - $b) * ($fMax - $v) / $fRange
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
			If StringInStr($sNew, "showtime") Then $g_hExt = 0 ; line came up -> read the extended data again
		EndIf
		If _Has($iUptime) And _Has($g_iPrevUptime) Then
			If $iUptime < $g_iPrevUptime Then
				$g_iResyncs += 1
				_Log("Resync detected (line uptime was reset)")
				$g_hExt = 0 ; new sync -> read the extended data again
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
	$g_hExt = 0 ; read the extended data again on the next successful poll (= after a reconnect)
	_ExtClear()
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
	If $g_bExtRan Then
		Local $iCfg = StringInStr($sRaw, "--- config submenu ---")
		If $iCfg Then
			$g_sExtRaw = StringMid($sRaw, $iCfg)
			$g_sExtRawTime = StringFormat("%02d:%02d:%02d", @HOUR, @MIN, @SEC)
		EndIf
	ElseIf $g_sExtRaw <> "" Then
		$g_sLastRaw &= @CRLF & @CRLF & "--- extended data of the read at " & $g_sExtRawTime & " (not queried in this poll) ---" & @CRLF & $g_sExtRaw
	EndIf
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
		If Not $g_bExtRan Then ; not queried this round -> keep the last values
			$vAttD = $g_vAttD
			$vAttU = $g_vAttU
		ElseIf _ParseExt($sRaw) Then
			$g_hExtOk = TimerInit()
			$g_iExtFail = 0
			_Log("Extended line data read (features, error counters, attainable rates)")
		Else
			$g_iExtFail += 1
		EndIf
		; nothing yet (e.g. after the Test button, or the read failed) -> try again with the next poll,
		; but after 3 failed reads wait for the normal extended interval (e.g. a modem without this submenu)
		If Not $g_bExtHave And $g_iExtFail < 3 Then $g_hExt = 0
		Local $vUptime = _UptimeSec(_Field($sRaw, "Line Uptime"))
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
				',"uptime_text":"' & _J(_FmtUptime($vUptime)) & '"' & _
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
				',"fw_country":"' & _J(_Field($sRaw, "CountryCode")) & '"' & _
				_ExtJson() & '}'
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
		If $g_bExtRan And Not _Has($vAttD) And Not $g_bAttWarned Then
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
	$g_bExtRan = False ; set again by _SshQuery if the extended data is read in this round
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
				$g_hExt = 0 ; fresh session (start / reconnect / recycle) -> read the extended data now
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
		; the extended data (attainable rates, features, error counters) is only in the config submenu: enter it, dump the JSON, leave it again.
		; Every step waits for the modem's PROMPT (typing ahead while the CLI switches menus gets swallowed),
		; and the whole dialogue goes into the raw output so the Raw tab shows exactly what happened.
		$g_bExtRan = ($g_hExt = 0 Or TimerDiff($g_hExt) >= $g_iExtInterval * 1000)
		If $g_bExtRan Then
			$g_hExt = TimerInit()
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
; cell of the JSON "End_Table" row $sName: $iCol 1 = Near_End, 2 = Far_End ("" if not found)
Func _EndCell($sRaw, $sName, $iCol)
	Local $a = StringRegExp($sRaw, '(?s)"Name":\s*"' & $sName & '",\s*"Near_End":\s*"([^"]*)",\s*"Far_End":\s*"([^"]*)"', 1)
	If @error Then Return ""
	Return $a[$iCol - 1]
EndFunc   ;==>_EndCell
; top level string value of the JSON, e.g. "ATU_R_Vendor_ID" ("" if not found)
Func _JStr($sRaw, $sKey)
	Local $a = StringRegExp($sRaw, '"' & $sKey & '":\s*"([^"]*)"', 1)
	If @error Then Return ""
	Return $a[0]
EndFunc   ;==>_JStr
; leading (signed) number of a text like "4.9 dB" or "0 s"; "" for "-" / empty
Func _ToNumS($s)
	Local $a = StringRegExp($s, "^\s*(-?\d+(?:\.\d+)?)", 1)
	If @error Then Return ""
	Return Number($a[0])
EndFunc   ;==>_ToNumS
; reads End_Table / Stream_Table / vendor IDs out of the "show all" output. False if the JSON is not in there.
Func _ParseExt($sRaw)
	If Not StringInStr($sRaw, '"End_Table"') Then Return False
	For $i = 0 To 19
		$g_aEnd[$i][0] = _EndCell($sRaw, $EXT_NAMES[$i], 1)
		$g_aEnd[$i][1] = _EndCell($sRaw, $EXT_NAMES[$i], 2)
	Next
	For $i = 0 To 2
		$g_aStr[$i][0] = _StreamCell($sRaw, $STR_NAMES[$i], 1)
		$g_aStr[$i][1] = _StreamCell($sRaw, $STR_NAMES[$i], 2)
	Next
	$g_sPwrMode = _JStr($sRaw, "Power_Management_Mode")
	$g_sVidR = _JStr($sRaw, "ATU_R_Vendor_ID")
	$g_sVidC = _JStr($sRaw, "ATU_C_Vendor_ID")
	$g_bExtHave = True
	Return True
EndFunc   ;==>_ParseExt
; forget the extended data (line is down / reconnecting)
Func _ExtClear()
	For $i = 0 To 19
		$g_aEnd[$i][0] = ""
		$g_aEnd[$i][1] = ""
	Next
	For $i = 0 To 2
		$g_aStr[$i][0] = ""
		$g_aStr[$i][1] = ""
	Next
	$g_sPwrMode = ""
	$g_sVidR = ""
	$g_sVidC = ""
	$g_bExtHave = False
	$g_iExtFail = 0
EndFunc   ;==>_ExtClear
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
; "HEC Errors" -> "hec_errors"
Func _ExtKey($sName)
	Return StringLower(StringReplace($sName, " ", "_"))
EndFunc   ;==>_ExtKey
; extended data as extra JSON members (leading comma), the last known values are sent with every poll
Func _ExtJson()
	Local $s = "", $sKey
	For $i = 0 To 19
		$sKey = _ExtKey($EXT_NAMES[$i])
		If Not $g_bMqttDiag And StringMid($EXT_KIND, $i + 1, 1) <> "A" Then ContinueLoop
		If StringMid($EXT_KIND, $i + 1, 1) = "T" Then
			If _Has($g_aEnd[$i][0]) Or _Has($g_aEnd[$i][1]) Then
				$s &= ',"' & $sKey & '":"' & _J(_NF($g_aEnd[$i][0], $g_aEnd[$i][1])) & '"'
			Else
				$s &= ',"' & $sKey & '":null'
			EndIf
		Else
			$s &= ',"' & $sKey & '_near":' & _JNum(_ToNumS($g_aEnd[$i][0])) & ',"' & $sKey & '_far":' & _JNum(_ToNumS($g_aEnd[$i][1]))
		EndIf
	Next
	If Not $g_bMqttDiag Then Return $s
	If _Has($g_aStr[0][0]) Or _Has($g_aStr[0][1]) Then
		$s &= ',"path_mode":"' & _J(_NF($g_aStr[0][0], $g_aStr[0][1])) & '"'
	Else
		$s &= ',"path_mode":null'
	EndIf
	$s &= ',"interleave_depth_down":' & _JNum(_ToNumS($g_aStr[1][0])) & ',"interleave_depth_up":' & _JNum(_ToNumS($g_aStr[1][1]))
	$s &= ',"psd_down":' & _JNum(_ToNumS($g_aStr[2][0])) & ',"psd_up":' & _JNum(_ToNumS($g_aStr[2][1]))
	$s &= ',"power_mgmt":"' & _J($g_sPwrMode) & '","vendor_modem":"' & _J($g_sVidR) & '","vendor_dslam":"' & _J($g_sVidC) & '"'
	Return $s
EndFunc   ;==>_ExtJson
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
	$s &= _DiscPkt("uptime_text", "DSL Line Uptime (text)", "uptime_text", "", "", "", "mdi:timer-outline")
	; clean-up: empty retained payload removes the old "DSL Modem Uptime" entity (feature was dropped) from HA
	$s &= _Pkt($g_sDiscPrefix & "/sensor/vigor_xdsl/modem_uptime/config", "")
	; monitor uptime is GUI only now: remove the old entity from HA
	$s &= _Pkt($g_sDiscPrefix & "/sensor/vigor_xdsl/monitor_uptime/config", "")
	$s &= _DiscPkt("35b_enhance", "DSL 35b Enhance", "enhance", "", "", "", "mdi:tune", "", True)
	$s &= _DiscPkt("35b_target", "DSL 35b Target", "target", "", "", "", "mdi:target", "", True)
	$s &= _DiscPkt("firmware", "DSL Modem Firmware", "fw", "", "", "", "mdi:chip", _
			"'model':value_json.fw_model,'device_name':value_json.fw_device,'build_time':value_json.fw_build," & _
			"'branch':value_json.fw_branch,'release_mode':value_json.fw_release,'web_version':value_json.fw_web," & _
			"'core_version':value_json.fw_core,'bootloader_version':value_json.fw_boot,'country_code':value_json.fw_country")
	; extended line data (diagnostic sensors): read only at start / reconnect / every "extended" interval,
	; the last values are re-sent with every poll. Rows of kind H / O ($EXT_KIND) are only in the state JSON.
	$s &= _DiscPkt("path_mode", "DSL Path Mode", "path_mode", "", "", "", "mdi:swap-horizontal", "", True)
	$s &= _DiscPkt("interleave_depth_down", "DSL Interleave Depth Downstream", "interleave_depth_down", "", "", "measurement", "mdi:layers-outline", "", True)
	$s &= _DiscPkt("interleave_depth_up", "DSL Interleave Depth Upstream", "interleave_depth_up", "", "", "measurement", "mdi:layers-outline", "", True)
	Local $sKey, $sKind, $sUnit, $sClass, $sStateClass, $sIcon
	For $i = 0 To 19
		$sKey = _ExtKey($EXT_NAMES[$i])
		$sKind = StringMid($EXT_KIND, $i + 1, 1)
		Switch $sKind
			Case "T"
				$s &= _DiscPkt($sKey, "DSL " & $EXT_NAMES[$i], $sKey, "", "", "", "mdi:toggle-switch-outline", "", True)
			Case "A", "E", "N"
				$sUnit = ""
				$sClass = ""
				$sStateClass = "total_increasing"
				$sIcon = "mdi:alert-circle-outline"
				If $sKind = "A" Then
					$sUnit = "dB"
					$sStateClass = "measurement"
					$sIcon = "mdi:signal-variant"
				ElseIf StringRegExp($EXT_NAMES[$i], "^(ES|SES|UAS)$") Then
					$sUnit = "s"
					$sClass = "duration"
				EndIf
				$s &= _DiscPkt($sKey & "_near", "DSL " & $EXT_NAMES[$i] & " Near End", $sKey & "_near", $sUnit, $sClass, $sStateClass, $sIcon, "", ($sKind <> "A"))
				$s &= _DiscPkt($sKey & "_far", "DSL " & $EXT_NAMES[$i] & " Far End", $sKey & "_far", $sUnit, $sClass, $sStateClass, $sIcon, "", ($sKind <> "A"))
		EndSwitch
	Next
	Return $s
EndFunc   ;==>_DiscoveryPackets
; $sAttrs = body of a Jinja dict for the entity attributes (optional), $bDiag = show under "Diagnostic"
Func _DiscPkt($sObj, $sName, $sField, $sUnit, $sDevClass, $sStateClass, $sIcon, $sAttrs = "", $bDiag = False)
	; diagnostic sensors switched off: empty retained payload removes the entity from HA
	If $bDiag And Not $g_bMqttDiag Then Return _Pkt($g_sDiscPrefix & "/sensor/vigor_xdsl/" & $sObj & "/config", "")
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
