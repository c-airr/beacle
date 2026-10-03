package main

import (
	"strings"
	"testing"
)

func TestTempLoginPasswordStaysOutOfTheLog(t *testing.T) {
	got := tempLoginUser([]byte(`{"user":"beacle-a1b2c3","password":"s3cretPassw0rd","port":22}`))
	if got != "beacle-a1b2c3" || strings.Contains(got, "s3cret") {
		t.Fatalf("got %q", got)
	}
	if tempLoginUser([]byte(`{"error":"no sshd"}`)) != "" {
		t.Fatal("error body leaked into the detail")
	}
}
