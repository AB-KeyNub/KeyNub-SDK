Attribute VB_Name = "KeyNubLicDongle"
'==============================================================================
' KeyNub License Dongle - Excel / VBA binding
'
' Import this module (File > Import File... in the VBA editor) and put
' keynub_licdongle_flat.dll next to your workbook or in a folder on PATH.
'
'   Dim h As Long
'   h = KeyNubOpen()                      ' raises if no dongle is attached
'   KeyNubVerifyGenuine h                 ' raises unless the dongle is genuine
'   KeyNubSessionOpen h
'   coefficients = KeyNubAppDecrypt(h, storedBlob)   ' <- the actual licence check
'   KeyNubSessionClose h
'   KeyNubClose h
'
' Requires VBA7 (Office 2010 or newer). The Declare statements use PtrSafe, which
' is mandatory in 64-bit Office and a syntax error in VBA6, so supporting Office
' 2007 would mean shipping a duplicate set of declarations for a version that has
' been out of support for over a decade.
'
' *** THE DLL MUST MATCH OFFICE'S BITNESS, NOT WINDOWS'. *** 64-bit Windows
' running 32-bit Excel needs the 32-bit DLL. Getting this wrong produces "file not
' found", which sends people looking for the wrong problem.
'
' Strings are marshalled by VBA as ANSI. Record names and serials are ASCII, so
' that is exactly right; do not use non-ASCII record names from VBA.
'
' READ FIRST: docs/integration-security.md. A macro that checks a Boolean and
' unlocks a worksheet is removed by deleting the check - and VBA is the easiest
' code in the world to read and edit. What cannot be removed is data your workbook
' needs that only the dongle can decrypt: put your model's constants, rates or
' reference tables through KeyNubAppEncrypt when you issue the licence, and
' KeyNubAppDecrypt at run time.
'==============================================================================
Option Explicit

' The library name is repeated in every Declare below rather than held in a
' constant, because VBA requires the Lib name to be a literal.

'--- status codes -------------------------------------------------------------
Public Const LICD_OK As Long = 0
Public Const LICD_E_INVALID_ARG As Long = -1
Public Const LICD_E_NO_DEVICE As Long = -2
Public Const LICD_E_ACCESS_DENIED As Long = -3
Public Const LICD_E_IO As Long = -4
Public Const LICD_E_TIMEOUT As Long = -5
Public Const LICD_E_PROTOCOL As Long = -6
Public Const LICD_E_NOT_GENUINE As Long = -7
Public Const LICD_E_CERT_INVALID As Long = -8
Public Const LICD_E_SESSION_EXPIRED As Long = -9
Public Const LICD_E_TAG_MISMATCH As Long = -10
Public Const LICD_E_RANGE As Long = -11
Public Const LICD_E_STORAGE_FULL As Long = -12
Public Const LICD_E_BUSY As Long = -13
Public Const LICD_E_NOT_FOUND As Long = -14
Public Const LICD_E_AUTH_REQUIRED As Long = -15
Public Const LICD_E_FW_INCOMPATIBLE As Long = -16
Public Const LICD_E_SDK_TOO_OLD As Long = -17
Public Const LICD_E_CANCELLED As Long = -18
Public Const LICD_E_NOT_IMPLEMENTED As Long = -19
Public Const LICD_E_INTERNAL As Long = -20

'--- flags in KeyNubGetInfo ----------------------------------------------------
Public Const LICDF_FLAG_SE_READY As Long = 1
Public Const LICDF_FLAG_PROVISIONED As Long = 2
Public Const LICDF_FLAG_WATCHDOG_REBOOT As Long = 4
Public Const LICDF_FLAG_ISOLATED As Long = 8
Public Const LICDF_FLAG_WRITEAUTH_ROTATED As Long = 16

'--- app-crypto scopes --------------------------------------------------------
Public Const KEYNUB_SCOPE_DEVICE As Long = 0    ' only this one physical dongle
Public Const KEYNUB_SCOPE_DEVELOPER As Long = 1 ' any dongle you have issued

'--- buffer sizes -------------------------------------------------------------
Private Const SERIAL_SIZE As Long = 15
Private Const ERROR_SIZE As Long = 256
Private Const NAME_SIZE As Long = 64

' Raised errors use vbObjectError + 5000 + |status| so they cannot collide with
' VBA's own error numbers. Err.Description carries the SDK's diagnostic detail.
Private Const ERR_BASE As Long = vbObjectError + 5000

Public Type KeyNubDeviceInfo
    ProtocolMajor As Long
    ProtocolMinor As Long
    FirmwareMajor As Long
    FirmwareMinor As Long
    FirmwarePatch As Long
    SeReady As Boolean
    Provisioned As Boolean
    WatchdogReboot As Boolean
    Isolated As Boolean
    ' False means the dongle still answers to the factory write-auth key, which is
    ' public. Anyone holding such a dongle can write to it. Rotate on receipt.
    WriteAuthRotated As Boolean
    DataCapacity As Long
    DataFree As Long
End Type

'==============================================================================
' Declarations (bindings/flat/licd_flat.h)
'==============================================================================
Private Declare PtrSafe Function licdf_version Lib "keynub_licdongle_flat.dll" ( _
    ByRef outMajor As Long, ByRef outMinor As Long, ByRef outPatch As Long) As Long
Private Declare PtrSafe Function licdf_strerror Lib "keynub_licdongle_flat.dll" ( _
    ByVal status As Long, ByVal outText As String, ByVal outSize As Long) As Long

Private Declare PtrSafe Function licdf_device_count Lib "keynub_licdongle_flat.dll" ( _
    ByRef outCount As Long) As Long
Private Declare PtrSafe Function licdf_device_serial Lib "keynub_licdongle_flat.dll" ( _
    ByVal index As Long, ByVal outText As String, ByVal outSize As Long) As Long
Private Declare PtrSafe Function licdf_device_path Lib "keynub_licdongle_flat.dll" ( _
    ByVal index As Long, ByVal outText As String, ByVal outSize As Long) As Long

Private Declare PtrSafe Function licdf_open Lib "keynub_licdongle_flat.dll" ( _
    ByVal serialOrEmpty As String) As Long
Private Declare PtrSafe Function licdf_open_path Lib "keynub_licdongle_flat.dll" ( _
    ByVal path As String) As Long
Private Declare PtrSafe Function licdf_close Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long) As Long
Private Declare PtrSafe Function licdf_set_trust_root Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByRef der As Byte, ByVal derLen As Long) As Long

Private Declare PtrSafe Function licdf_get_serial Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal outText As String, ByVal outSize As Long) As Long
Private Declare PtrSafe Function licdf_get_info Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByRef outProtoMajor As Long, ByRef outProtoMinor As Long, _
    ByRef outFwMajor As Long, ByRef outFwMinor As Long, ByRef outFwPatch As Long, _
    ByRef outFlags As Long, ByRef outCapacity As Long, ByRef outFree As Long) As Long
Private Declare PtrSafe Function licdf_verify_genuine Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByRef outGenuine As Long, ByVal outSerial As String, _
    ByVal serialSize As Long, ByVal outDate As String, ByVal dateSize As Long) As Long

Private Declare PtrSafe Function licdf_session_open Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long) As Long
Private Declare PtrSafe Function licdf_session_close Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long) As Long
Private Declare PtrSafe Function licdf_write_auth Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByRef der As Byte, ByVal derLen As Long) As Long
Private Declare PtrSafe Function licdf_write_auth_rotate Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByRef der As Byte, ByVal derLen As Long) As Long

Private Declare PtrSafe Function licdf_record_count Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByRef outCount As Long) As Long
Private Declare PtrSafe Function licdf_record_name Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal index As Long, ByVal outText As String, _
    ByVal outSize As Long, ByRef outRecordSize As Long) As Long
Private Declare PtrSafe Function licdf_record_size Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal name As String, ByRef outSize As Long) As Long
Private Declare PtrSafe Function licdf_record_read Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal name As String, ByRef outData As Byte, _
    ByVal outCap As Long, ByRef outLen As Long) As Long
Private Declare PtrSafe Function licdf_record_write Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal name As String, ByRef data As Byte, _
    ByVal dataLen As Long) As Long
Private Declare PtrSafe Function licdf_record_erase Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal name As String) As Long
Private Declare PtrSafe Function licdf_record_erase_all Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long) As Long

Private Declare PtrSafe Function licdf_counter_read Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal counterId As Long, ByRef outValue As Long) As Long
Private Declare PtrSafe Function licdf_counter_increment Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal counterId As Long, ByRef outValue As Long) As Long

Private Declare PtrSafe Function licdf_app_encrypt Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal scope As Long, ByRef plaintext As Byte, _
    ByVal plaintextLen As Long, ByRef outData As Byte, ByVal outCap As Long, _
    ByRef outLen As Long) As Long
Private Declare PtrSafe Function licdf_app_decrypt Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByRef packed As Byte, ByVal packedLen As Long, _
    ByRef outData As Byte, ByVal outCap As Long, ByRef outLen As Long) As Long

Private Declare PtrSafe Function licdf_last_error Lib "keynub_licdongle_flat.dll" ( _
    ByVal handle As Long, ByVal outText As String, ByVal outSize As Long) As Long

'==============================================================================
' Helpers
'==============================================================================

' VBA fills the whole buffer it handed to C, so the text ends at the first NUL.
Private Function TrimNull(ByVal s As String) As String
    Dim p As Long
    p = InStr(s, vbNullChar)
    If p > 0 Then
        TrimNull = Left$(s, p - 1)
    Else
        TrimNull = s
    End If
End Function

Private Function Buffer(ByVal size As Long) As String
    Buffer = Space$(size)
End Function

' Number of elements in a Byte(), tolerating an unallocated array.
Private Function ByteCount(arr() As Byte) As Long
    On Error GoTo Empty_
    ByteCount = UBound(arr) - LBound(arr) + 1
    Exit Function
Empty_:
    ByteCount = 0
End Function

' Every buffer handed to the DLL has at least one element, so that passing
' element 0 by reference is always legal even when the length is zero. The library
' does not read or write a buffer whose declared length is 0.
Private Function AsBuffer(arr() As Byte) As Byte()
    Dim out() As Byte
    Dim n As Long
    n = ByteCount(arr)
    If n = 0 Then
        ReDim out(0 To 0)
    Else
        out = arr
    End If
    AsBuffer = out
End Function

Private Sub Fail(ByVal status As Long, ByVal operation As String, ByVal handle As Long)
    Dim detail As String
    If handle > 0 Then
        detail = Buffer(ERROR_SIZE)
        If licdf_last_error(handle, detail, ERROR_SIZE) = LICD_OK Then
            detail = TrimNull(detail)
        Else
            detail = ""
        End If
    End If
    Dim message As String
    message = operation & ": " & KeyNubStatusText(status)
    If Len(detail) > 0 Then message = message & " (" & detail & ")"
    Err.Raise ERR_BASE - status, "KeyNubLicDongle", message
End Sub

Private Sub Check(ByVal status As Long, ByVal operation As String, ByVal handle As Long)
    If status <> LICD_OK Then Fail status, operation, handle
End Sub

'==============================================================================
' Public API
'==============================================================================

' "major.minor.patch" of the native core.
Public Function KeyNubLibraryVersion() As String
    Dim maj As Long, min As Long, pat As Long
    Check licdf_version(maj, min, pat), "licdf_version", 0
    KeyNubLibraryVersion = maj & "." & min & "." & pat
End Function

Public Function KeyNubStatusText(ByVal status As Long) As String
    Dim buf As String
    buf = Buffer(ERROR_SIZE)
    If licdf_strerror(status, buf, ERROR_SIZE) = LICD_OK Then
        KeyNubStatusText = TrimNull(buf)
    Else
        KeyNubStatusText = "status " & status
    End If
End Function

' How many dongles are attached. Call before KeyNubDeviceSerial, which indexes
' into the snapshot this call takes.
Public Function KeyNubDeviceCount() As Long
    Dim count As Long
    Check licdf_device_count(count), "licdf_device_count", 0
    KeyNubDeviceCount = count
End Function

Public Function KeyNubDeviceSerial(ByVal index As Long) As String
    Dim buf As String
    buf = Buffer(SERIAL_SIZE)
    Check licdf_device_serial(index, buf, SERIAL_SIZE), "licdf_device_serial", 0
    KeyNubDeviceSerial = TrimNull(buf)
End Function

' Opens the dongle with this serial, or the first one found. Raises if none is
' attached. Always pair with KeyNubClose - the library holds 32 handles at once.
Public Function KeyNubOpen(Optional ByVal serial As String = "") As Long
    Dim handle As Long
    handle = licdf_open(serial)
    If handle <= 0 Then Fail handle, "licdf_open", 0
    KeyNubOpen = handle
End Function

Public Sub KeyNubClose(ByVal handle As Long)
    If handle > 0 Then licdf_close handle
End Sub

Public Function KeyNubGetSerial(ByVal handle As Long) As String
    Dim buf As String
    buf = Buffer(SERIAL_SIZE)
    Check licdf_get_serial(handle, buf, SERIAL_SIZE), "licdf_get_serial", handle
    KeyNubGetSerial = TrimNull(buf)
End Function

Public Function KeyNubGetInfo(ByVal handle As Long) As KeyNubDeviceInfo
    Dim pMaj As Long, pMin As Long, fMaj As Long, fMin As Long, fPat As Long
    Dim flags As Long, capacity As Long, freeBytes As Long
    Check licdf_get_info(handle, pMaj, pMin, fMaj, fMin, fPat, flags, capacity, freeBytes), _
          "licdf_get_info", handle
    Dim info As KeyNubDeviceInfo
    info.ProtocolMajor = pMaj
    info.ProtocolMinor = pMin
    info.FirmwareMajor = fMaj
    info.FirmwareMinor = fMin
    info.FirmwarePatch = fPat
    info.SeReady = (flags And LICDF_FLAG_SE_READY) <> 0
    info.Provisioned = (flags And LICDF_FLAG_PROVISIONED) <> 0
    ' The dongle's PREVIOUS boot ended in a watchdog reset: the firmware hung. It
    ' is the only trace a field hang leaves, so it is worth reporting to support.
    info.WatchdogReboot = (flags And LICDF_FLAG_WATCHDOG_REBOOT) <> 0
    ' The dongle confirmed its USB/parsing code is fenced off from keys.
    info.Isolated = (flags And LICDF_FLAG_ISOLATED) <> 0
    ' False = still on the factory write-auth key, which is public.
    info.WriteAuthRotated = (flags And LICDF_FLAG_WRITEAUTH_ROTATED) <> 0
    info.DataCapacity = capacity
    info.DataFree = freeBytes
    KeyNubGetInfo = info
End Function

' Raises unless the dongle proves it is genuine (certificate chain plus a live
' challenge-response). Returns the serial from the certificate.
Public Function KeyNubVerifyGenuine(ByVal handle As Long) As String
    Dim genuine As Long
    Dim serial As String
    serial = Buffer(SERIAL_SIZE)
    Check licdf_verify_genuine(handle, genuine, serial, SERIAL_SIZE, vbNullString, 0), _
          "licdf_verify_genuine", handle
    If genuine = 0 Then Fail LICD_E_NOT_GENUINE, "licdf_verify_genuine", handle
    KeyNubVerifyGenuine = TrimNull(serial)
End Function

' Non-raising form for a licence gate. Fails closed: no dongle, an I/O error and
' an invalid certificate all report False.
Public Function KeyNubIsGenuine(ByVal handle As Long) As Boolean
    Dim genuine As Long
    If licdf_verify_genuine(handle, genuine, vbNullString, 0, vbNullString, 0) <> LICD_OK Then
        KeyNubIsGenuine = False
    Else
        KeyNubIsGenuine = (genuine <> 0)
    End If
End Function

Public Sub KeyNubSessionOpen(ByVal handle As Long)
    Check licdf_session_open(handle), "licdf_session_open", handle
End Sub

Public Sub KeyNubSessionClose(ByVal handle As Long)
    licdf_session_close handle
End Sub

' Elevates to the write role with the developer master key. This belongs in the
' workbook you issue licences from, never in one you hand to a customer.
Public Sub KeyNubAuthorizeWrite(ByVal handle As Long, der() As Byte)
    Dim buf() As Byte
    buf = AsBuffer(der)
    Check licdf_write_auth(handle, buf(LBound(buf)), ByteCount(der)), "licdf_write_auth", handle
End Sub

' Replaces the dongle's write-auth key with your own. Call KeyNubAuthorizeWrite
' with the current key first. From the next session on, only the new key
' elevates.
Public Sub KeyNubRotateWriteKey(ByVal handle As Long, newDer() As Byte)
    Dim buf() As Byte
    buf = AsBuffer(newDer)
    Check licdf_write_auth_rotate(handle, buf(LBound(buf)), ByteCount(newDer)), _
          "licdf_write_auth_rotate", handle
End Sub

Public Function KeyNubRecordCount(ByVal handle As Long) As Long
    Dim count As Long
    Check licdf_record_count(handle, count), "licdf_record_count", handle
    KeyNubRecordCount = count
End Function

Public Function KeyNubRecordName(ByVal handle As Long, ByVal index As Long) As String
    Dim buf As String
    Dim size As Long
    buf = Buffer(NAME_SIZE)
    Check licdf_record_name(handle, index, buf, NAME_SIZE, size), "licdf_record_name", handle
    KeyNubRecordName = TrimNull(buf)
End Function

Public Function KeyNubRecordRead(ByVal handle As Long, ByVal name As String) As Byte()
    ' Two calls: ask for the size, then read. Passing a zero capacity is the
    ' documented way to ask - the library does not touch the buffer.
    Dim needed As Long
    Dim probe(0 To 0) As Byte
    Dim status As Long
    status = licdf_record_read(handle, name, probe(0), 0, needed)
    If status <> LICD_OK And status <> LICD_E_RANGE Then
        Fail status, "licdf_record_read", handle
    End If
    If needed = 0 Then
        KeyNubRecordRead = EmptyBytes()
        Exit Function
    End If
    Dim data() As Byte
    ReDim data(0 To needed - 1)
    Dim got As Long
    Check licdf_record_read(handle, name, data(0), needed, got), "licdf_record_read", handle
    If got = 0 Then
        KeyNubRecordRead = EmptyBytes()
    ElseIf got < needed Then
        ReDim Preserve data(0 To got - 1)
        KeyNubRecordRead = data
    Else
        KeyNubRecordRead = data
    End If
End Function

Public Sub KeyNubRecordWrite(ByVal handle As Long, ByVal name As String, data() As Byte)
    Dim buf() As Byte
    buf = AsBuffer(data)
    Check licdf_record_write(handle, name, buf(LBound(buf)), ByteCount(data)), _
          "licdf_record_write", handle
End Sub

Public Sub KeyNubRecordErase(ByVal handle As Long, ByVal name As String)
    Check licdf_record_erase(handle, name), "licdf_record_erase", handle
End Sub

Public Sub KeyNubRecordEraseAll(ByVal handle As Long)
    Check licdf_record_erase_all(handle), "licdf_record_erase_all", handle
End Sub

Public Function KeyNubCounterRead(ByVal handle As Long, ByVal counterId As Long) As Long
    Dim value As Long
    Check licdf_counter_read(handle, counterId, value), "licdf_counter_read", handle
    KeyNubCounterRead = value
End Function

' Irreversible: the counter is monotonic in hardware.
Public Function KeyNubCounterIncrement(ByVal handle As Long, ByVal counterId As Long) As Long
    Dim value As Long
    Check licdf_counter_increment(handle, counterId, value), "licdf_counter_increment", handle
    KeyNubCounterIncrement = value
End Function

' Encrypts so that only a dongle of `scope` can decrypt it. Use this at
' licence-issue time on data your workbook needs, and KeyNubAppDecrypt at run
' time. That is the whole point of the dongle: a check you cannot delete.
Public Function KeyNubAppEncrypt(ByVal handle As Long, ByVal scope As Long, _
                                 plaintext() As Byte) As Byte()
    Dim src() As Byte
    src = AsBuffer(plaintext)
    Dim needed As Long
    Dim probe(0 To 0) As Byte
    Dim status As Long
    status = licdf_app_encrypt(handle, scope, src(LBound(src)), ByteCount(plaintext), _
                               probe(0), 0, needed)
    If status <> LICD_OK And status <> LICD_E_RANGE Then
        Fail status, "licdf_app_encrypt", handle
    End If
    If needed <= 0 Then Fail LICD_E_INTERNAL, "licdf_app_encrypt", handle
    Dim out() As Byte
    ReDim out(0 To needed - 1)
    Dim got As Long
    Check licdf_app_encrypt(handle, scope, src(LBound(src)), ByteCount(plaintext), _
                            out(0), needed, got), "licdf_app_encrypt", handle
    KeyNubAppEncrypt = out
End Function

Public Function KeyNubAppDecrypt(ByVal handle As Long, packed() As Byte) As Byte()
    Dim src() As Byte
    src = AsBuffer(packed)
    Dim needed As Long
    Dim probe(0 To 0) As Byte
    Dim status As Long
    status = licdf_app_decrypt(handle, src(LBound(src)), ByteCount(packed), probe(0), 0, needed)
    If status <> LICD_OK And status <> LICD_E_RANGE Then
        Fail status, "licdf_app_decrypt", handle
    End If
    If needed = 0 Then
        KeyNubAppDecrypt = EmptyBytes()
        Exit Function
    End If
    Dim out() As Byte
    ReDim out(0 To needed - 1)
    Dim got As Long
    Check licdf_app_decrypt(handle, src(LBound(src)), ByteCount(packed), out(0), needed, got), _
          "licdf_app_decrypt", handle
    If got = 0 Then
        KeyNubAppDecrypt = EmptyBytes()
    ElseIf got < needed Then
        ReDim Preserve out(0 To got - 1)
        KeyNubAppDecrypt = out
    Else
        KeyNubAppDecrypt = out
    End If
End Function

Private Function EmptyBytes() As Byte()
    Dim none() As Byte
    EmptyBytes = none
End Function
