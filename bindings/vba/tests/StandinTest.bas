Attribute VB_Name = "StandinTest"
'==============================================================================
' Every public function of KeyNubLicDongle.bas against a stand-in for the flat C
' API: bindings/flat/licd_flat.c over bindings/julia/test/stub/licd_stub.c, one
' imaginary dongle held in memory, compiled as keynub_licdongle_flat.dll.
'
' run_standin_test.ps1 in this folder builds the stand-in, imports this module and
' KeyNubLicDongle.bas into a new workbook and calls StandinRun. By hand: import
' both modules, then in the Immediate window
'
'   ? StandinRun("C:\path\to\keynub_licdongle_flat.dll")
'==============================================================================
Option Explicit

Private Declare PtrSafe Function LoadLibraryW Lib "kernel32" (ByVal path As LongPtr) As LongPtr

Private Const SERIAL As String = "04A1B2C3D4E5F6"

Private failures As Long
Private report As String

Private Sub Check(ByVal ok As Boolean, ByVal what As String)
    If Not ok Then
        failures = failures + 1
        report = report & "  FAIL  " & what & vbLf
    End If
End Sub

' The error a call raised must be the one for `status`, with a description.
Private Sub ExpectRaised(ByVal number As Long, ByVal description As String, _
                         ByVal status As Long, ByVal what As String)
    If number <> vbObjectError + 5000 - status Then
        Check False, what & ": raised " & number & ", expected " & (vbObjectError + 5000 - status)
    Else
        Check Len(description) > 0, what & ": no description"
    End If
End Sub

Private Function Bytes(ParamArray values() As Variant) As Byte()
    Dim out() As Byte
    ReDim out(0 To UBound(values))
    Dim i As Long
    For i = 0 To UBound(values)
        out(i) = CByte(values(i))
    Next i
    Bytes = out
End Function

Private Function ByteLen(arr() As Byte) As Long
    On Error GoTo Unallocated
    ByteLen = UBound(arr) - LBound(arr) + 1
    Exit Function
Unallocated:
    ByteLen = 0
End Function

Private Function Same(a() As Byte, b() As Byte) As Boolean
    Dim n As Long
    n = ByteLen(a)
    If n <> ByteLen(b) Then Exit Function
    Dim i As Long
    For i = 0 To n - 1
        If a(LBound(a) + i) <> b(LBound(b) + i) Then Exit Function
    Next i
    Same = True
End Function

' Loads the stand-in by its full path; the Declare statements, which name the
' library without a folder, then bind to the module already loaded.
Public Function StandinRun(ByVal libraryPath As String) As String
    failures = 0
    report = ""
    If LoadLibraryW(StrPtr(libraryPath)) = 0 Then
        StandinRun = "cannot load " & libraryPath
        Exit Function
    End If
    On Error GoTo Unexpected

    Dim h As Long, h2 As Long, n As Long, i As Long
    Dim text As String
    Dim info As KeyNubDeviceInfo
    Dim data() As Byte, back() As Byte

    Check KeyNubLibraryVersion() = "9.8.7", "library version"
    Check KeyNubStatusText(LICD_E_NO_DEVICE) = "no device", "status text"
    Check KeyNubDeviceCount() = 1, "one device"
    Check KeyNubDeviceSerial(0) = SERIAL, "device serial"

    On Error Resume Next
    text = KeyNubDeviceSerial(1)
    ExpectRaised Err.Number, Err.Description, LICD_E_RANGE, "device index out of range"
    Err.Clear
    h2 = KeyNubOpen("nope")
    ExpectRaised Err.Number, Err.Description, LICD_E_NO_DEVICE, "open by unknown serial"
    Err.Clear
    On Error GoTo Unexpected

    h = KeyNubOpen()
    Check h > 0, "open"
    Check KeyNubGetSerial(h) = SERIAL, "serial"
    info = KeyNubGetInfo(h)
    Check info.ProtocolMajor = 1 And info.ProtocolMinor = 0, "protocol version"
    Check info.FirmwareMajor = 2 And info.FirmwareMinor = 3 And info.FirmwarePatch = 4, "firmware version"
    Check info.SeReady And info.Provisioned And info.Isolated, "flags set"
    Check Not info.WatchdogReboot And Not info.WriteAuthRotated, "flags clear"
    Check info.DataCapacity = 1048576 And info.DataFree = 1000000, "capacity"
    Check KeyNubVerifyGenuine(h) = SERIAL, "genuine"
    Check KeyNubIsGenuine(h), "IsGenuine"

    On Error Resume Next
    n = KeyNubRecordCount(h)
    ExpectRaised Err.Number, Err.Description, LICD_E_SESSION_EXPIRED, "records without a session"
    Err.Clear
    On Error GoTo Unexpected

    KeyNubSessionOpen h
    data = StrConv("license-blob-0123456789", vbFromUnicode)
    On Error Resume Next
    KeyNubRecordWrite h, "lic", data
    ExpectRaised Err.Number, Err.Description, LICD_E_AUTH_REQUIRED, "write before the write role"
    Err.Clear
    back = Bytes(&H30, 0)
    KeyNubAuthorizeWrite h, back
    ExpectRaised Err.Number, Err.Description, LICD_E_NOT_GENUINE, "write role with a bad key"
    Err.Clear
    On Error GoTo Unexpected

    Dim factory() As Byte, replacement() As Byte
    factory = Bytes(&H30, &H10, 1, 2, 3)
    replacement = Bytes(&H30, &H11, 9, 8, 7, 6)
    KeyNubAuthorizeWrite h, factory
    KeyNubRecordWrite h, "lic", data
    back = KeyNubRecordRead(h, "lic")
    Check Same(back, data), "read back"
    Dim cfg() As Byte
    cfg = StrConv("cfgdata", vbFromUnicode)
    KeyNubRecordWrite h, "cfg", cfg
    n = KeyNubRecordCount(h)
    Check n = 2, "two records"
    Dim names As String
    For i = 0 To n - 1
        names = names & "|" & KeyNubRecordName(h, i)
    Next i
    Check InStr(names, "|lic") > 0 And InStr(names, "|cfg") > 0, "record names"

    On Error Resume Next
    back = KeyNubRecordRead(h, "nope")
    text = Err.Description
    ExpectRaised Err.Number, text, LICD_E_NOT_FOUND, "read a missing record"
    Check InStr(text, "no such record") > 0, "the description carries the detail"
    Err.Clear
    KeyNubRecordErase h, ""
    ExpectRaised Err.Number, Err.Description, LICD_E_INVALID_ARG, "erase with an empty name"
    Err.Clear
    On Error GoTo Unexpected

    KeyNubRecordErase h, "cfg"
    Check KeyNubRecordCount(h) = 1, "one record left"
    Dim none() As Byte
    KeyNubRecordWrite h, "empty", none
    back = KeyNubRecordRead(h, "empty")
    Check ByteLen(back) = 0, "an empty record reads as an empty array"

    Dim before As Long
    before = KeyNubCounterRead(h, 0)
    Check KeyNubCounterIncrement(h, 0) = before + 1, "increment"
    Check KeyNubCounterRead(h, 1) = 0, "counters"
    On Error Resume Next
    n = KeyNubCounterRead(h, 7)
    ExpectRaised Err.Number, Err.Description, LICD_E_RANGE, "counter out of range"
    Err.Clear
    On Error GoTo Unexpected

    Dim secret() As Byte, sealed() As Byte, opened() As Byte
    ReDim secret(0 To 99)
    For i = 0 To 99
        secret(i) = (3 * i + 7) Mod 256
    Next i
    Dim scope As Long
    For scope = KEYNUB_SCOPE_DEVICE To KEYNUB_SCOPE_DEVELOPER
        sealed = KeyNubAppEncrypt(h, scope, secret)
        Check ByteLen(sealed) > 100 And sealed(0) = scope, "sealed data and scope byte"
        opened = KeyNubAppDecrypt(h, sealed)
        Check Same(opened, secret), "round trip"
        sealed(UBound(sealed)) = sealed(UBound(sealed)) Xor 1
        On Error Resume Next
        opened = KeyNubAppDecrypt(h, sealed)
        ExpectRaised Err.Number, Err.Description, LICD_E_TAG_MISMATCH, "tampered envelope"
        Err.Clear
        On Error GoTo Unexpected
    Next scope
    On Error Resume Next
    sealed = KeyNubAppEncrypt(h, 7, secret)
    ExpectRaised Err.Number, Err.Description, LICD_E_INVALID_ARG, "unknown scope"
    Err.Clear
    On Error GoTo Unexpected

    KeyNubRecordEraseAll h
    Check KeyNubRecordCount(h) = 0, "erase all"

    KeyNubRotateWriteKey h, replacement
    data = StrConv("still-writable", vbFromUnicode)
    KeyNubRecordWrite h, "lic", data
    KeyNubSessionClose h
    info = KeyNubGetInfo(h)
    Check info.WriteAuthRotated, "rotated flag"
    KeyNubSessionOpen h
    On Error Resume Next
    KeyNubAuthorizeWrite h, factory
    ExpectRaised Err.Number, Err.Description, LICD_E_NOT_GENUINE, "factory key after rotation"
    Err.Clear
    On Error GoTo Unexpected
    KeyNubAuthorizeWrite h, replacement
    data = StrConv("new-key-writes", vbFromUnicode)
    KeyNubRecordWrite h, "lic", data
    back = KeyNubRecordRead(h, "lic")
    Check Same(back, data), "new key content"
    KeyNubSessionClose h

    KeyNubClose h
    On Error Resume Next
    text = KeyNubGetSerial(h)
    ExpectRaised Err.Number, Err.Description, LICD_E_INVALID_ARG, "serial after close"
    Err.Clear
    On Error GoTo Unexpected
    Check Not KeyNubIsGenuine(h), "IsGenuine fails closed after close"
    KeyNubClose h

    ' The library holds 32 handles at once; the 33rd open raises.
    Dim handles(1 To 40) As Long
    Dim opened32 As Long
    On Error Resume Next
    For i = 1 To 40
        handles(i) = 0
        handles(i) = KeyNubOpen(SERIAL)
        If Err.Number = 0 And handles(i) > 0 Then opened32 = opened32 + 1
        Err.Clear
    Next i
    On Error GoTo Unexpected
    Check opened32 = 32, "32 handles at a time"
    For i = 1 To 40
        KeyNubClose handles(i)
    Next i

    GoTo Done
Unexpected:
    Check False, "unexpected error " & Err.Number & ": " & Err.Description
Done:
    If failures = 0 Then
        StandinRun = report & "KeyNubLicDongle.bas: every call passed against the ABI stand-in"
    Else
        StandinRun = report & failures & " check(s) failed"
    End If
End Function
