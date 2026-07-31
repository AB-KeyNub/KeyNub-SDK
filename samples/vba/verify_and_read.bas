Attribute VB_Name = "VerifyAndRead"
' KeyNub dongle check from VBA: enumerate -> open -> verify -> session ->
' read a record -> app-crypto round trip.
'
' To run this:
'   1. Import bindings/vba/KeyNubLicDongle.bas into your VBA project
'      (Excel/Access/Word: Alt+F11, then File > Import File...)
'   2. Import this file the same way
'   3. Deploy keynub_licdongle_flat matching your Office bitness -- see
'      bindings/vba/README.md. 32-bit Office should use the COM interface
'      (bindings/com) instead; the flat API is cdecl and VBA's Declare emits
'      stdcall, which is harmless on x64 and a stack mismatch in a 32-bit process.
'   4. Run VerifyAndRead from the Immediate window or a button
'
' Output goes to the Immediate window (Ctrl+G) via Debug.Print.
'
' READ FIRST: docs/integration-security.md. This macro prints whether the dongle
' is genuine, which is the one thing a real licence check must not do -- anyone who
' can open the VBA editor can delete a MsgBox and an Exit Sub. ProtectSomething
' shows the shape that actually protects something: for a workbook that is usually
' the rate tables, pricing constants or thresholds the sheet needs to compute at
' all.

Option Explicit

Public Sub VerifyAndRead()
    Dim handle As Long
    Dim i As Long

    Debug.Print "KeyNub SDK " & KeyNubLibraryVersion()

    Dim count As Long
    count = KeyNubDeviceCount()
    Debug.Print "Found " & count & " KeyNub dongle(s)."
    For i = 0 To count - 1
        Debug.Print "  [" & i & "] serial " & KeyNubDeviceSerial(i)
    Next i
    If count = 0 Then
        Debug.Print "No dongle attached; nothing to do."
        Exit Sub
    End If

    ' The binding raises on failure, so one handler covers everything below.
    On Error GoTo Failed

    ' Empty serial = first dongle found; pass one to pick a specific dongle.
    handle = KeyNubOpen()

    ReportDongle handle

    KeyNubSessionOpen handle
    ReadRecords handle
    ProtectSomething handle
    KeyNubSessionClose handle

    KeyNubClose handle
    Exit Sub

Failed:
    ' Err.Description carries the SDK's own diagnostic text, which is what tells
    ' "no dongle" from "certificate rejected".
    Debug.Print "KeyNub error " & Err.Number & ": " & Err.Description
    If handle > 0 Then KeyNubClose handle
End Sub

Private Sub ReportDongle(ByVal handle As Long)
    Dim info As KeyNubDeviceInfo
    info = KeyNubGetInfo(handle)

    Debug.Print "Protocol v" & info.ProtocolMajor & "." & info.ProtocolMinor & _
                ", firmware v" & info.FirmwareMajor & "." & info.FirmwareMinor & _
                "." & info.FirmwarePatch & ", " & info.DataFree & " of " & _
                info.DataCapacity & " bytes free."

    If info.WatchdogReboot Then
        ' The only trace a firmware hang leaves behind. Worth reporting to support.
        Debug.Print "WARNING: this dongle's previous boot ended in a watchdog reset."
    End If

    ' KeyNubVerifyGenuine raises unless the dongle is genuine, and returns its
    ' serial. KeyNubIsGenuine is the non-raising form for a gate, and fails closed.
    Debug.Print "Genuine, serial " & KeyNubVerifyGenuine(handle)
End Sub

Private Sub ReadRecords(ByVal handle As Long)
    Dim count As Long, i As Long
    count = KeyNubRecordCount(handle)
    Debug.Print count & " record(s) on the dongle:"
    For i = 0 To count - 1
        Debug.Print "  " & KeyNubRecordName(handle, i)
    Next i

    ' A missing record raises, and a missing record is a normal state, so this one
    ' call gets its own handler rather than failing the whole run.
    On Error Resume Next
    Dim data() As Byte
    data = KeyNubRecordRead(handle, "license")
    If Err.Number = 0 Then
        Debug.Print "Read " & (UBound(data) - LBound(data) + 1) & _
                    " bytes from the license record."
    End If
    Err.Clear
    On Error GoTo 0
End Sub

' The part that actually protects something. At licence-issue time you would call
' KeyNubAppEncrypt once, with a developer dongle, and ship only the blob; the
' workbook then cannot compute without a dongle, because it holds no other copy of
' the data. KEYNUB_SCOPE_DEVELOPER lets any dongle from your batch decrypt it, so
' one file serves every customer; KEYNUB_SCOPE_DEVICE locks it to one dongle.
Private Sub ProtectSomething(ByVal handle As Long)
    Dim needed() As Byte
    Dim sealed() As Byte
    Dim recovered() As Byte
    Dim intact As Boolean
    Dim i As Long

    ' VBA strings are UTF-16, so a plain byte assignment would double every
    ' character. StrConv gives the bytes an ASCII payload actually occupies.
    needed = StrConv("the data this program cannot run without", vbFromUnicode)

    sealed = KeyNubAppEncrypt(handle, KEYNUB_SCOPE_DEVELOPER, needed)
    recovered = KeyNubAppDecrypt(handle, sealed)

    intact = (UBound(recovered) = UBound(needed))
    If intact Then
        For i = LBound(needed) To UBound(needed)
            If recovered(i) <> needed(i) Then
                intact = False
                Exit For
            End If
        Next i
    End If

    Debug.Print "App-crypto round trip: " & (UBound(needed) + 1) & " bytes -> " & _
                (UBound(sealed) + 1) & " sealed -> " & _
                IIf(intact, "recovered intact", "MISMATCH")
End Sub
