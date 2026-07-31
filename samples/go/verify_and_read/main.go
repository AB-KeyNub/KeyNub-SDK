// KeyNub dongle check from Go: enumerate -> open -> verify -> session ->
// read a record -> app-crypto round trip.
//
//	CGO_LDFLAGS="-L../../../build" go run .
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// READ FIRST: docs/integration-security.md. This sample prints whether the dongle
// is genuine, which is the one thing a real licence check must not do — a printed
// boolean is a deleted line away from nothing. protectSomething shows the shape
// that actually protects something.
//
// The binding returns ordinary errors with sentinels, so the usual Go handling
// applies: errors.Is for the cases you branch on, and defer Close for the cleanup.
// Note that a dongle is not safe for concurrent use — one goroutine at a time.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"

	keynub "github.com/AB-KeyNub/KeyNub-bindings/go"
)

func report(d *keynub.Dongle) error {
	info, err := d.Info()
	if err != nil {
		return err
	}
	fmt.Printf("Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.\n",
		info.ProtocolMajor, info.ProtocolMinor,
		info.FirmwareMajor, info.FirmwareMinor, info.FirmwarePatch,
		info.DataFree, info.DataCapacity)

	if info.WatchdogReboot {
		// The only trace a firmware hang leaves behind. Worth reporting to support.
		fmt.Println("WARNING: this dongle's previous boot ended in a watchdog reset.")
	}

	result, err := d.VerifyGenuine()
	if err != nil {
		return err
	}
	fmt.Printf("Genuine: %t (serial %s, batch %s, provisioned %s)\n",
		result.Genuine, result.Serial, result.Batch, result.ProvisionedDate)
	return nil
}

func readRecords(s *keynub.Session) error {
	records, err := s.ListRecords()
	if err != nil {
		return err
	}
	fmt.Printf("%d record(s) on the dongle:\n", len(records))
	for _, r := range records {
		fmt.Printf("  %-16s %6d bytes\n", r.Name, r.Size)
	}

	for _, r := range records {
		if r.Name == "license" {
			data, err := s.ReadRecord("license")
			if err != nil {
				return err
			}
			fmt.Printf("Read %d bytes from the license record.\n", len(data))
			break
		}
	}
	return nil
}

// The part that actually protects something. At licence-issue time you would call
// AppEncrypt once, with a developer dongle, and ship only the blob; the application
// then cannot proceed without a dongle, because it holds no other copy of the data.
// ScopeDeveloper lets any dongle from your batch decrypt it, so one file serves
// every customer; ScopeDevice locks it to one dongle.
func protectSomething(s *keynub.Session) error {
	needed := []byte("the data this program cannot run without")

	sealed, err := s.AppEncrypt(keynub.ScopeDeveloper, needed)
	if err != nil {
		return err
	}
	recovered, err := s.AppDecrypt(sealed)
	if err != nil {
		return err
	}

	outcome := "MISMATCH"
	if bytes.Equal(recovered, needed) {
		outcome = "recovered intact"
	}
	fmt.Printf("App-crypto round trip: %d bytes -> %d sealed -> %s\n",
		len(needed), len(sealed), outcome)
	return nil
}

func run() error {
	ctx, err := keynub.NewContext()
	if err != nil {
		return err
	}
	defer ctx.Close()

	devices, err := ctx.Enumerate()
	if err != nil {
		return err
	}
	fmt.Printf("Found %d KeyNub dongle(s).\n", len(devices))
	for i, d := range devices {
		fmt.Printf("  [%d] serial %s (VID %04X PID %04X)\n", i, d.Serial, d.VendorID, d.ProductID)
	}
	if len(devices) == 0 {
		fmt.Println("No dongle attached; nothing to do.")
		return nil
	}

	// Empty serial = first dongle found; pass one to pick a specific dongle.
	dongle, err := ctx.Open("")
	if err != nil {
		return err
	}
	defer dongle.Close()

	if err := report(dongle); err != nil {
		return err
	}

	session, err := dongle.OpenSession()
	if err != nil {
		return err
	}
	defer session.Close()

	if err := readRecords(session); err != nil {
		return err
	}
	return protectSomething(session)
}

func main() {
	major, minor, patch := keynub.LibraryVersion()
	fmt.Printf("KeyNub SDK %d.%d.%d\n", major, minor, patch)

	if err := run(); err != nil {
		// A dongle unplugged mid-conversation is not a failure of the program.
		if errors.Is(err, keynub.ErrNoDevice) {
			fmt.Println("The dongle was disconnected while we were talking to it.")
			return
		}
		fmt.Fprintf(os.Stderr, "KeyNub error: %v\n", err)
		os.Exit(1)
	}
}
