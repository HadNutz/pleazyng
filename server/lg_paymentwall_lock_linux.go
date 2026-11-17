//go:build linux

package main

import (
	"errors"
	"os"
	"syscall"
)

func lockLGPaymentwallFile(file *os.File) error {
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("Paymentwall state already has an active writer")
	}
	return nil
}

func unlockLGPaymentwallFile(file *os.File) error {
	return syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
}
