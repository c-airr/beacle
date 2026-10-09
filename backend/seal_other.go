//go:build !windows

package main

import "strings"

// seal keeps the secret as it is: outside Windows there is no per-account
// store every desktop has, so it is only as safe as ssh_hosts.json, which is
// written readable by its owner alone — like ~/.ssh.
func seal(plain string) (string, error) { return plain, nil }

func unseal(stored string) (string, error) {
	if strings.HasPrefix(stored, sealedPrefix) {
		return "", errSealed // sealed on Windows; cannot be read here
	}
	return stored, nil
}
