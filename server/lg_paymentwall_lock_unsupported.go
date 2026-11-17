//go:build !linux

package main

import (
	"errors"
	"os"
)

var errLGPaymentwallPlatformUnsupported = errors.New("Paymentwall billing is unavailable on this platform")

func lockLGPaymentwallFile(_ *os.File) error { return errLGPaymentwallPlatformUnsupported }

func unlockLGPaymentwallFile(_ *os.File) error { return errLGPaymentwallPlatformUnsupported }
