' KeyNub SDK - Visual Basic .NET sample: take ownership of a new dongle.
'
' A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
' that from the next session onward only your key can write records, erase them or
' increment counters. Run it once per dongle, when it arrives.
'
' Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
'
'   openssl ecparam -name prime256v1 -genkey -noout |
'     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
'
'   dotnet run --project samples/vbnet/rotate_write_key -- keys/keynub-shipping-writeauth.key.der my-key.der
'
' Targets real hardware: with no dongle attached it prints guidance and exits 0.
'
' The replacement key is worth what your licence-signing key is worth. It cannot be
' recovered from the dongle, and a unit rotated to a key you have lost has to come
' back to be re-provisioned.

Option Strict On
Option Explicit On

Imports System
Imports System.IO
Imports KeyNub.LicenseDongle

Module Program

    Function Main(args As String()) As Integer
        If args.Length <> 2 Then
            Console.Error.WriteLine("usage: rotate_write_key <current-key.der> <new-key.der>")
            Return 2
        End If

        Dim current As Byte() = File.ReadAllBytes(args(0))
        Dim replacement As Byte() = File.ReadAllBytes(args(1))

        Try
            Using ctx As LicenseDongleContext = LicenseDongleContext.Create()
                If ctx.Enumerate().Count = 0 Then
                    Console.WriteLine("Connect a KeyNub dongle and re-run.")
                    Return 0
                End If

                Using dongle As Dongle = ctx.Open()
                    Console.WriteLine($"dongle {dongle.GetSerial()}")

                    Using session As Session = dongle.OpenSession()
                        session.AuthorizeWrite(current)
                        session.RotateWriteKey(replacement)
                        Console.WriteLine("rotated: this dongle now answers only to your key")
                    End Using

                    ' A fresh session is the only place the change is observable: the
                    ' session above keeps the role it was already granted.
                    Using session As Session = dongle.OpenSession()
                        Try
                            session.AuthorizeWrite(current)
                            Console.Error.WriteLine("WARNING: the old key still works -- do not ship this unit")
                            Return 1
                        Catch ex As LicenseDongleException
                            Console.WriteLine("confirmed: the old key no longer elevates")
                        End Try
                        session.AuthorizeWrite(replacement)
                        Console.WriteLine("confirmed: your key elevates")
                    End Using
                End Using
            End Using
        Catch ex As LicenseDongleException
            Console.Error.WriteLine($"KeyNub error: {ex.Message}")
            Return 1
        End Try

        Console.WriteLine()
        Console.WriteLine("Keep the replacement key safe. Every future write to this dongle needs it.")
        Return 0
    End Function

End Module
