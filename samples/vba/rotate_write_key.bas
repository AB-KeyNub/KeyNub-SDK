Attribute VB_Name = "RotateWriteKey"
' KeyNub SDK - VBA sample: take ownership of a new dongle.
'
' A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
' that from the next session onward only your key can write records, erase them or
' increment counters. Run it once per dongle, when it arrives.
'
' Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
'   openssl ecparam -name prime256v1 -genkey -noout | ^
'     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
'
' To run this:
'   1. Import bindings/vba/KeyNubLicDongle.bas into your VBA project
'      (Excel/Access/Word: Alt+F11, then File > Import File...)
'   2. Import this file the same way
'   3. Deploy keynub_licdongle_flat matching your Office bitness -- see
'      bindings/vba/README.md. 32-bit Office should use the COM interface
'      (bindings/com) instead.
'   4. Edit the two paths in RotateWriteKey and run it
'
' Output goes to the Immediate window (Ctrl+G) via Debug.Print.
'
' The replacement key is worth what your licence-signing key is worth. It cannot be
' recovered from the dongle, and a unit rotated to a key you have lost has to come
' back to be re-provisioned. Do not leave it in the workbook.

Option Explicit

' Edit these two before running.
Private Const CURRENT_KEY_PATH As String = "C:\keys\keynub-shipping-writeauth.key.der"
Private Const NEW_KEY_PATH As String = "C:\keys\my-key.der"

Public Sub RotateWriteKey()
    Dim handle As Long
    Dim current() As Byte
    Dim replacement() As Byte

    current = ReadKeyFile(CURRENT_KEY_PATH)
    replacement = ReadKeyFile(NEW_KEY_PATH)

    If KeyNubDeviceCount() = 0 Then
        Debug.Print "Connect a KeyNub dongle and re-run."
        Exit Sub
    End If

    ' The binding raises on failure, so one handler covers everything below.
    On Error GoTo Failed

    ' Empty serial = first dongle found; pass one to pick a specific dongle.
    handle = KeyNubOpen()
    Debug.Print "dongle " & KeyNubGetSerial(handle)

    KeyNubSessionOpen handle
    KeyNubAuthorizeWrite handle, current
    KeyNubRotateWriteKey handle, replacement
    Debug.Print "rotated: this dongle now answers only to your key"
    KeyNubSessionClose handle

    ' A fresh session is the only place the change is observable: the session
    ' above keeps the role it was already granted.
    KeyNubSessionOpen handle
    Dim oldKeyStillWorks As Boolean
    oldKeyStillWorks = True
    On Error Resume Next
    KeyNubAuthorizeWrite handle, current
    If Err.Number <> 0 Then
        oldKeyStillWorks = False
        Err.Clear
    End If
    On Error GoTo Failed

    If oldKeyStillWorks Then
        Debug.Print "WARNING: the old key still works -- do not ship this unit"
        KeyNubSessionClose handle
        KeyNubClose handle
        Exit Sub
    End If
    Debug.Print "confirmed: the old key no longer elevates"

    KeyNubAuthorizeWrite handle, replacement
    Debug.Print "confirmed: your key elevates"
    KeyNubSessionClose handle
    KeyNubClose handle

    Debug.Print ""
    Debug.Print "Keep the replacement key safe. Every future write to this dongle needs it."
    Exit Sub

Failed:
    Debug.Print "KeyNub error: " & Err.Description
    If handle <> 0 Then KeyNubClose handle
End Sub

' A DER file is binary, so it is read whole into a Byte array rather than as text.
Private Function ReadKeyFile(ByVal path As String) As Byte()
    Dim fileNumber As Integer
    Dim buffer() As Byte
    Dim length As Long

    fileNumber = FreeFile
    Open path For Binary Access Read As #fileNumber
    length = LOF(fileNumber)
    If length = 0 Then
        Close #fileNumber
        Err.Raise vbObjectError + 1, "RotateWriteKey", path & " is empty"
    End If
    ReDim buffer(0 To length - 1)
    Get #fileNumber, 1, buffer
    Close #fileNumber

    ReadKeyFile = buffer
End Function
