Attribute VB_Name = "modMain"
'==============================================================================
' KeyNub License Dongle - Visual Basic 6 sample
'
' Run it with F5 and watch the Immediate window (Ctrl+G). A VB6 sample that
' printed with MsgBox would need thirty clicks to get through, and one that
' needed a form would bury the part worth reading.
'
' Register the server once before running:
'
'     C:\Windows\SysWOW64\regsvr32.exe KeyNub.dll
'
' SysWOW64, not System32: VB6 is a 32-bit host, so it needs the 32-bit build and
' the 32-bit regsvr32. Elevation is not required -- the server registers for the
' current user when it cannot write machine-wide.
'
' LATE VS EARLY BINDING
'   This sample uses CreateObject, so it runs with no project configuration at
'   all. For production, add Project > References > "KeyNub License Dongle" and
'   declare the variable as its real type:
'
'       Dim dongle As KeyNub.Dongle
'       Set dongle = New KeyNub.Dongle
'
'   That gives IntelliSense, the object browser, compile-time checking of every
'   member name, and slightly faster calls. Nothing else in this file changes.
'
' READ FIRST: docs/integration-security.md. The gate below deliberately does
' NOT look like `If IsGenuine Then Unlock`, and the comment at ShowTheRealGate
' explains why that shape is worth avoiding.
'==============================================================================
Option Explicit

' Err.Number for a KeyNub failure is vbObjectError + 5000 + |status|, the same
' numbering the VBA binding raises. These are the few worth branching on.
Private Const KEYNUB_ERR_BASE      As Long = vbObjectError + 5000
Private Const KEYNUB_E_NO_DEVICE   As Long = 2
Private Const KEYNUB_E_NOT_GENUINE As Long = 7
Private Const KEYNUB_E_NOT_FOUND   As Long = 14

' Scope values for AppEncrypt. With a project reference these are already
' available as keynubScopeDevice / keynubScopeDeveloper.
Private Const SCOPE_DEVICE    As Long = 0
Private Const SCOPE_DEVELOPER As Long = 1


Public Sub Main()
    Debug.Print "KeyNub License Dongle - VB6 sample"
    Debug.Print "-----------------------------------"

    Dim dongle As Object
    On Error GoTo Failed

    Set dongle = CreateObject("KeyNub.Dongle")
    Debug.Print "SDK version: " & dongle.Version

    ' Enumerate before opening, so a helpful message is possible when there is
    ' nothing attached. DeviceCount takes the snapshot the indices refer to, so
    ' it has to be read before DeviceSerial.
    Dim attached As Long
    attached = dongle.DeviceCount
    Debug.Print "Dongles attached: " & attached

    If attached = 0 Then
        Debug.Print "Nothing to do -- plug in a dongle and run again."
        Exit Sub
    End If

    Dim i As Long
    For i = 0 To attached - 1
        Debug.Print "  [" & i & "] " & dongle.DeviceSerial(i)
    Next i

    dongle.Open                     ' omit the serial to take the first one
    Debug.Print "Opened:      " & dongle.Serial
    Debug.Print "Firmware:    " & dongle.FirmwareVersion
    Debug.Print "Protocol:    " & dongle.ProtocolVersion
    Debug.Print "Storage:     " & dongle.FreeBytes & " of " & dongle.Capacity & " bytes free"

    ' Proof of authenticity: a certificate chain to the KeyNub root plus a live
    ' challenge-response. This raises unless the dongle is genuine, so reaching
    ' the next line means it is.
    Debug.Print "Certificate: " & dongle.VerifyGenuine
    Debug.Print "Genuine:     yes"

    ' Records, counters and app-crypto all need the encrypted session.
    dongle.SessionOpen

    Call ShowTheRealGate(dongle)
    Call ShowRecords(dongle)
    Call ShowCounter(dongle)

    dongle.SessionClose
    dongle.Close
    Debug.Print "Done."
    Exit Sub

Failed:
    ' Err.Description carries the SDK's own diagnostic detail, which is what
    ' separates "no dongle attached" from "a dongle whose certificate did not
    ' validate". Print it; do not replace it with your own wording.
    Debug.Print "FAILED: " & Err.Description

    Select Case Err.Number
        Case KEYNUB_ERR_BASE + KEYNUB_E_NO_DEVICE
            Debug.Print "  -> No dongle found. Check it is plugged in."
        Case KEYNUB_ERR_BASE + KEYNUB_E_NOT_GENUINE
            Debug.Print "  -> That dongle is not a genuine KeyNub dongle."
        Case Else
            Debug.Print "  -> Err.Number = " & Err.Number
    End Select

    ' Close is safe when nothing is open and safe to call twice, which is why it
    ' belongs here. Dropping the reference would also close the dongle -- the
    ' object owns the handle -- but being explicit costs nothing.
    On Error Resume Next
    If Not dongle Is Nothing Then dongle.Close
End Sub


'------------------------------------------------------------------------------
' The gate that is actually worth building.
'
' The tempting version is one line:
'
'     If dongle.IsGenuine Then EnableFeatures
'
' and it is one line for somebody to delete. A compiled VB6 EXE is harder to
' patch than a VBA macro, but "harder" is not "hard": the jump is findable in an
' afternoon, and it only has to be found once before the patch is shared.
'
' What cannot be deleted is data the program needs and cannot compute. Encrypt
' that once, when you issue the licence, and decrypt it at run time. Remove the
' check and the program has no rate table, no coefficients, no reference data --
' there is nothing left to unlock.
'------------------------------------------------------------------------------
Private Sub ShowTheRealGate(ByVal dongle As Object)
    Debug.Print ""
    Debug.Print "The licence check:"

    ' Stand-in for something your program genuinely cannot work without. In a
    ' real product this is a rate table, a material database, the coefficients of
    ' your calculation -- and it is produced once, by your own tooling, with your
    ' developer dongle, not on the customer's machine.
    Dim theDataMyProgramNeeds() As Byte
    theDataMyProgramNeeds = StringToBytes("rate=17.4;factor=0.93;limit=2200")

    ' SCOPE_DEVELOPER: any dongle from your batch can decrypt it, so one
    ' encrypted blob ships to every customer. SCOPE_DEVICE locks it to one
    ' physical dongle, for per-customer data.
    Dim envelope() As Byte
    envelope = dongle.AppEncrypt(SCOPE_DEVELOPER, theDataMyProgramNeeds)
    Debug.Print "  envelope:  " & (UBound(envelope) - LBound(envelope) + 1) & _
                " bytes (ship this with your product)"

    ' At run time, on the customer's machine. No dongle -> this raises -> there
    ' is no rate table -> the program cannot pretend the check passed.
    Dim recovered() As Byte
    recovered = dongle.AppDecrypt(envelope)
    Debug.Print "  recovered: " & BytesToString(recovered)

    ' The envelope is authenticated, so a customer cannot edit the numbers
    ' either: a tampered envelope fails to decrypt rather than yielding
    ' different values.
    envelope(UBound(envelope)) = envelope(UBound(envelope)) Xor 1
    On Error Resume Next
    Err.Clear
    recovered = dongle.AppDecrypt(envelope)
    If Err.Number = 0 Then
        Debug.Print "  UNEXPECTED: a tampered envelope decrypted"
    Else
        Debug.Print "  tampering:  rejected (" & Err.Description & ")"
    End If
    On Error GoTo 0
End Sub


Private Sub ShowRecords(ByVal dongle As Object)
    Debug.Print ""
    Debug.Print "Records stored on the dongle: " & dongle.RecordCount

    Dim i As Long
    For i = 0 To dongle.RecordCount - 1
        Dim recordName As String
        recordName = dongle.RecordName(i)
        Debug.Print "  " & recordName & " (" & dongle.RecordSize(recordName) & " bytes)"
    Next i

    ' Reading a record that is not there has its own status, so it can be told
    ' apart from a communication failure.
    On Error Resume Next
    Err.Clear
    Dim ignored() As Byte
    ignored = dongle.RecordRead("no-such-record")
    If Err.Number = KEYNUB_ERR_BASE + KEYNUB_E_NOT_FOUND Then
        Debug.Print "  (a missing record reports NOT_FOUND, as it should)"
    End If
    On Error GoTo 0

    ' Writing needs the write role, which needs the developer master key --
    ' vendor tooling only. Never ship that key inside your application; anyone
    ' holding it can rewrite any dongle in your batch.
End Sub


Private Sub ShowCounter(ByVal dongle As Object)
    Debug.Print ""
    Debug.Print "Hardware counter 0: " & dongle.CounterRead(0)
    ' CounterIncrement is deliberately not called here. It is monotonic and
    ' cannot be wound back, so a sample should not consume one on every run.
End Sub


'--- Byte()/String helpers ----------------------------------------------------
' VB6 Strings are UTF-16 and the dongle stores bytes, so the conversion has to
' be explicit. StrConv with vbFromUnicode gives the ANSI bytes, which is right
' for ASCII payloads like these; for anything non-ASCII, choose an encoding
' deliberately rather than letting the locale choose one for you.

Private Function StringToBytes(ByVal text As String) As Byte()
    StringToBytes = StrConv(text, vbFromUnicode)
End Function

Private Function BytesToString(ByRef data() As Byte) As String
    BytesToString = StrConv(data, vbUnicode)
End Function
