' KeyNub dongle check from Visual Basic .NET: enumerate -> open -> verify ->
' session -> read a record -> app-crypto round trip.
'
'   dotnet run --project samples/vbnet/verify_and_read
'
' There is no separate VB binding: KeyNub.LicenseDongle is a .NET assembly, so VB,
' C# and F# all consume the same package. This sample exists because the VB call
' style differs enough to be worth showing — Using blocks, no `var`, and Option
' Strict On, which is what you want for interop.
'
' Targets real hardware: with no dongle attached it prints guidance and exits 0.
'
' READ FIRST: docs/integration-security.md. This sample prints whether the
' dongle is genuine, which is the one thing a real licence check must not do — a
' printed Boolean is a deleted line away from nothing. The last section shows the
' shape that actually protects something.

Option Strict On
Option Explicit On

Imports System
Imports System.Text
Imports KeyNub.LicenseDongle

Module Program

    Function Main() As Integer
        Dim version As Version = LicenseDongleContext.LibraryVersion
        Console.WriteLine($"KeyNub SDK {version}")

        Try
            Using ctx As LicenseDongleContext = LicenseDongleContext.Create()
                Dim devices = ctx.Enumerate()
                Console.WriteLine($"Found {devices.Count} KeyNub dongle(s).")
                For i As Integer = 0 To devices.Count - 1
                    Dim d As DeviceInfo = devices(i)
                    Console.WriteLine($"  [{i}] serial {d.Serial} (VID {d.VendorId:X4} PID {d.ProductId:X4})")
                Next
                If devices.Count = 0 Then
                    Console.WriteLine("No dongle attached; nothing to do.")
                    Return 0
                End If

                ' First dongle; pass a serial to Open() to pick a specific one.
                Using dongle As Dongle = ctx.Open()
                    Report(dongle)
                    Using session As Session = dongle.OpenSession()
                        ReadRecords(session)
                        ProtectSomething(session)
                    End Using
                End Using
            End Using

        Catch ex As DeviceNotFoundException
            Console.WriteLine("The dongle was disconnected while we were talking to it.")
            Return 0
        Catch ex As LicenseDongleException
            ' Status distinguishes the cases; Detail carries the SDK's diagnostic
            ' text, which is what tells "no dongle" from "certificate rejected".
            Console.Error.WriteLine($"KeyNub error ({ex.Status}): {ex.Message}")
            If Not String.IsNullOrEmpty(ex.Detail) Then
                Console.Error.WriteLine($"  detail: {ex.Detail}")
            End If
            Return 1
        End Try

        Return 0
    End Function

    Private Sub Report(dongle As Dongle)
        Dim info As DongleInfo = dongle.GetInfo()
        Console.WriteLine($"Protocol v{info.ProtocolVersion}, firmware v{info.FirmwareVersion}, " &
                          $"{info.DataFree} of {info.DataCapacity} bytes free.")
        If info.WatchdogReboot Then
            ' The only trace a firmware hang leaves behind. Worth reporting to support.
            Console.WriteLine("WARNING: this dongle's previous boot ended in a watchdog reset.")
        End If

        Dim result As GenuineResult = dongle.VerifyGenuine()
        Console.WriteLine($"Genuine: {result.IsGenuine} (serial {result.Serial}, " &
                          $"provisioned {result.ProvisionedDate})")
    End Sub

    Private Sub ReadRecords(session As Session)
        Dim records = session.ListRecords()
        Console.WriteLine($"{records.Count} record(s) on the dongle:")
        For Each record As RecordInfo In records
            Console.WriteLine($"  {record.Name,-16} {record.Size,6} bytes")
        Next

        For Each record As RecordInfo In records
            If record.Name = "license" Then
                Dim data As Byte() = session.ReadRecord("license")
                Console.WriteLine($"Read {data.Length} bytes from the license record.")
                Exit For
            End If
        Next
    End Sub

    ' The part that actually protects something. At licence-issue time you would
    ' call AppEncrypt once, with a developer dongle, and ship only the blob; the
    ' application then cannot proceed without a dongle, because it holds no other
    ' copy of the data. Scope.Developer lets any dongle you have issued decrypt it,
    ' so one file serves every customer; Scope.Device locks it to one dongle.
    Private Sub ProtectSomething(session As Session)
        Dim needed As Byte() = Encoding.UTF8.GetBytes("the data this program cannot run without")

        Dim sealedBlob As Byte() = session.AppEncrypt(Scope.Developer, needed)
        Dim recovered As Byte() = session.AppDecrypt(sealedBlob)

        Dim intact As Boolean = (recovered.Length = needed.Length)
        If intact Then
            For i As Integer = 0 To needed.Length - 1
                If recovered(i) <> needed(i) Then
                    intact = False
                    Exit For
                End If
            Next
        End If

        Console.WriteLine($"App-crypto round trip: {needed.Length} bytes -> " &
                          $"{sealedBlob.Length} sealed -> " &
                          If(intact, "recovered intact", "MISMATCH"))
    End Sub

End Module
