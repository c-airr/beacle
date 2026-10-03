//go:build !linux

package main

import (
	"errors"

	"beacle/shared"
)

// Temporary SSH logins create Linux accounts; there is nothing to do elsewhere.

func createTempLogin(shared.TempLoginRequest) (shared.TempLogin, error) {
	return shared.TempLogin{}, errors.New("temporary SSH logins need a Linux server")
}

func listTempLogins() []shared.TempLogin { return []shared.TempLogin{} }

func deleteTempLogin(string) error {
	return errors.New("temporary SSH logins need a Linux server")
}

func tempLoginReaper() {}
