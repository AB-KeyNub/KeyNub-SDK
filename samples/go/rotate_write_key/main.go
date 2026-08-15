// KeyNub SDK - Go sample: take ownership of a new dongle.
//
// A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
// that from the next session onward only your key can write records, erase them or
// increment counters. Run it once per dongle, when it arrives.
//
// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//
//	openssl ecparam -name prime256v1 -genkey -noout |
//	  openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//
//	CGO_LDFLAGS="-L../../../build" go run . ../../../keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It cannot be
// recovered from the dongle, and a unit rotated to a key you have lost has to come
// back to be re-provisioned.
package main

import (
	"fmt"
	"os"

	keynub "github.com/AB-KeyNub/KeyNub-SDK/bindings/go"
)

func rotate(current, replacement []byte) error {
	ctx, err := keynub.NewContext()
	if err != nil {
		return err
	}
	defer ctx.Close()

	devices, err := ctx.Enumerate()
	if err != nil {
		return err
	}
	if len(devices) == 0 {
		fmt.Println("Connect a KeyNub dongle and re-run.")
		return nil
	}

	dongle, err := ctx.Open("") // first dongle; pass a serial to pick a specific one
	if err != nil {
		return err
	}
	defer dongle.Close()

	serial, err := dongle.Serial()
	if err != nil {
		return err
	}
	fmt.Printf("dongle %s\n", serial)

	session, err := dongle.OpenSession()
	if err != nil {
		return err
	}
	if err := session.AuthorizeWrite(current); err != nil {
		session.Close()
		return err
	}
	if err := session.RotateWriteKey(replacement); err != nil {
		session.Close()
		return err
	}
	fmt.Println("rotated: this dongle now answers only to your key")
	session.Close()

	// A fresh session is the only place the change is observable: the session
	// above keeps the role it was already granted.
	session, err = dongle.OpenSession()
	if err != nil {
		return err
	}
	defer session.Close()
	if err := session.AuthorizeWrite(current); err == nil {
		return fmt.Errorf("the old key still works -- do not ship this unit")
	}
	fmt.Println("confirmed: the old key no longer elevates")
	if err := session.AuthorizeWrite(replacement); err != nil {
		return err
	}
	fmt.Println("confirmed: your key elevates")

	fmt.Println("\nKeep the replacement key safe. Every future write to this dongle needs it.")
	return nil
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "usage: %s <current-key.der> <new-key.der>\n", os.Args[0])
		os.Exit(2)
	}
	current, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	replacement, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if err := rotate(current, replacement); err != nil {
		fmt.Fprintf(os.Stderr, "KeyNub error: %v\n", err)
		os.Exit(1)
	}
}
