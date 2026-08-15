Attribute VB_Name = "modRotate"
'==============================================================================
' KeyNub License Dongle - Visual Basic 6 sample: take ownership of a new dongle
'
' A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
' so that from the next session onward only your key can write records, erase
' them or increment counters. Run it once per dongle, when it arrives.
'
' Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
'   openssl ecparam -name prime256v1 -genkey -noout | ^
'     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
'
' Edit the two paths below, then run RotateWriteKey from the Immediate window
' (Ctrl+G). Register the server once first:
'
'     C:\Windows\SysWOW64\regsvr32.exe KeyNub.dll
'
' The replacement key is worth what your licence-signing key is worth. It cannot
' be recovered from the dongle, and a unit rotated to a key you have lost has to
' come back to be re-provisioned. Do not ship it inside the application.
'==============================================================================
Option Explicit

' Edit these two before running.
Private Const CURRENT_KEY_PATH As String = "C:\keys\keynub-shipping-writeauth.key.der"
Private Const NEW_KEY_PATH     As String = "C:\keys\my-key.der"


Public Sub RotateWriteKey()
    Dim dongle As Object
    Dim current() As Byte
    Dim replacement() As Byte

    On Error GoTo Failed

    current = ReadKeyFile(CURRENT_KEY_PATH)
    replacement = ReadKeyFile(NEW_KEY_PATH)

    Set dongle = CreateObject("KeyNub.Dongle")
    If dongle.DeviceCount = 0 Then
        Debug.Print "Connect a KeyNub dongle and re-run."
        Exit Sub
    End If

    dongle.Open ""                      ' first dongle found
    Debug.Print "dongle " & dongle.Serial

    dongle.SessionOpen
    dongle.AuthorizeWrite current
    dongle.RotateWriteKey replacement
    Debug.Print "rotated: this dongle now answers only to your key"
    dongle.SessionClose

    ' A fresh session is the only place the change is observable: the session
    ' above keeps the role it was already granted.
    dongle.SessionOpen

    Dim oldKeyStillWorks As Boolean
    oldKeyStillWorks = True
    On Error Resume Next
    dongle.AuthorizeWrite current
    If Err.Number <> 0 Then
        oldKeyStillWorks = False
        Err.Clear
    End If
    On Error GoTo Failed

    If oldKeyStillWorks Then
        Debug.Print "WARNING: the old key still works -- do not ship this unit"
        dongle.SessionClose
        dongle.Close
        Exit Sub
    End If
    Debug.Print "confirmed: the old key no longer elevates"

    dongle.AuthorizeWrite replacement
    Debug.Print "confirmed: your key elevates"
    dongle.SessionClose
    dongle.Close

    Debug.Print ""
    Debug.Print "Keep the replacement key safe. Every future write to this dongle needs it."
    Exit Sub

Failed:
    Debug.Print "KeyNub error: " & Err.Description
    If Not dongle Is Nothing Then dongle.Close
End Sub


' A DER file is binary, so it is read whole into a Byte array. The COM binding
' takes and returns Byte arrays everywhere, which is what VB6 can express.
Private Function ReadKeyFile(ByVal path As String) As Byte()
    Dim fileNumber As Integer
    Dim buffer() As Byte
    Dim length As Long

    fileNumber = FreeFile
    Open path For Binary Access Read As #fileNumber
    length = LOF(fileNumber)
    If length = 0 Then
        Close #fileNumber
        Err.Raise vbObjectError + 1, "modRotate", path & " is empty"
    End If
    ReDim buffer(0 To length - 1)
    Get #fileNumber, 1, buffer
    Close #fileNumber

    ReadKeyFile = buffer
End Function
