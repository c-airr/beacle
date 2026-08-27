//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"beacle/shared"
)

// Creating a systemd unit from the panel.
//
// This writes into /etc/systemd/system, which is as consequential as anything
// Beacle does: a unit that fails to parse can stop a machine booting, and one
// that is enabled runs as root on every start forever. So the order is fixed —
// render, validate, only then install — and any failure after the file lands
// removes it again rather than leaving something half-installed behind.

const systemdUnitDir = "/etc/systemd/system"

func unitPath(name string) string {
	return filepath.Join(systemdUnitDir, name+".service")
}

func validateSpec(spec shared.SystemdUnitSpec) (string, error) {
	name, err := validateSpecFields(spec)
	if err != nil {
		return "", err
	}
	// Only reachable on a real host: a working directory has to exist there.
	if wd := strings.TrimSpace(spec.WorkingDir); wd != "" {
		if !filepath.IsAbs(wd) {
			return "", fmt.Errorf("working directory must be an absolute path")
		}
		if st, err := os.Stat(wd); err != nil || !st.IsDir() {
			return "", fmt.Errorf("working directory %q does not exist", wd)
		}
	}
	return name, nil
}

// PreviewSystemdUnit renders the unit and asks systemd whether it would accept
// it, without touching the real unit directory. Verification happens on a copy
// in a temp directory precisely so a bad file never exists at the real path.
func (c *linuxCollector) PreviewSystemdUnit(spec shared.SystemdUnitSpec) (shared.SystemdUnitPreview, error) {
	name, err := validateSpec(spec)
	if err != nil {
		return shared.SystemdUnitPreview{}, err
	}
	spec.Name = name
	unit := renderUnit(spec)

	out := shared.SystemdUnitPreview{Path: unitPath(name), Unit: unit}
	if _, err := os.Stat(out.Path); err == nil {
		out.Exists = true
	}
	out.Valid, out.Output = verifyUnitText(name, unit)
	return out, nil
}

// verifyUnitText runs systemd-analyze verify against a throwaway copy.
func verifyUnitText(name, unit string) (bool, string) {
	dir, err := os.MkdirTemp("", "beacle-unit-*")
	if err != nil {
		return false, err.Error()
	}
	defer os.RemoveAll(dir)

	path := filepath.Join(dir, name+".service")
	if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
		return false, err.Error()
	}

	cmd := exec.Command("systemd-analyze", "verify", path)
	raw, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(raw))

	if err != nil {
		// systemd-analyze may be absent on a minimal image. Refusing to install
		// because the checker is missing would be worse than installing without
		// it, so this is reported rather than treated as invalid.
		if _, lookErr := exec.LookPath("systemd-analyze"); lookErr != nil {
			return true, "systemd-analyze not installed — unit written without verification"
		}
		if text == "" {
			text = err.Error()
		}
		return false, text
	}
	// verify warns about things that are not fatal (a missing binary it cannot
	// resolve, for instance) and still exits zero; the text is passed through
	// so the reader decides.
	return true, text
}

// CreateSystemdUnit writes the unit, reloads systemd and optionally enables and
// starts it. Anything that fails after the file is written removes it again.
func (c *linuxCollector) CreateSystemdUnit(spec shared.SystemdUnitSpec) (shared.SystemdUnitPreview, error) {
	name, err := validateSpec(spec)
	if err != nil {
		return shared.SystemdUnitPreview{}, err
	}
	spec.Name = name
	path := unitPath(name)

	existed := false
	var previous []byte
	if b, err := os.ReadFile(path); err == nil {
		existed = true
		previous = b
		if !spec.Overwrite {
			return shared.SystemdUnitPreview{}, fmt.Errorf(
				"%s.service already exists — tick overwrite to replace it", name)
		}
	}

	unit := renderUnit(spec)
	if ok, output := verifyUnitText(name, unit); !ok {
		return shared.SystemdUnitPreview{}, fmt.Errorf("systemd rejected this unit: %s", output)
	}

	// Undo restores whatever was there before, so a failure part-way through
	// cannot leave a unit nobody asked for.
	undo := func() {
		if existed {
			_ = os.WriteFile(path, previous, 0o644)
		} else {
			_ = os.Remove(path)
		}
		_ = exec.Command("systemctl", "daemon-reload").Run()
	}

	if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
		return shared.SystemdUnitPreview{}, fmt.Errorf("write %s: %w", path, err)
	}
	// daemon-reload only here — after a unit file actually changed. It is not
	// something a status poll should ever do.
	if out, err := exec.Command("systemctl", "daemon-reload").CombinedOutput(); err != nil {
		undo()
		return shared.SystemdUnitPreview{}, fmt.Errorf("daemon-reload: %s", strings.TrimSpace(string(out)))
	}

	unitName := name + ".service"
	if spec.EnableAtBoot {
		if out, err := exec.Command("systemctl", "enable", unitName).CombinedOutput(); err != nil {
			undo()
			return shared.SystemdUnitPreview{}, fmt.Errorf("enable: %s", strings.TrimSpace(string(out)))
		}
	}
	if spec.StartNow {
		if out, err := exec.Command("systemctl", "start", unitName).CombinedOutput(); err != nil {
			// The unit is left in place: it parsed and installed correctly, and
			// the failure is the command inside it. Removing it now would throw
			// away the thing the user needs to look at the logs of.
			return shared.SystemdUnitPreview{Path: path, Unit: unit, Valid: true, Exists: true},
				fmt.Errorf("installed, but starting it failed: %s\n\nCheck the service logs.",
					strings.TrimSpace(string(out)))
		}
	}

	return shared.SystemdUnitPreview{Path: path, Unit: unit, Valid: true, Exists: true}, nil
}

// DeleteSystemdUnit stops, disables and removes a unit Beacle can see. Only
// files under /etc/systemd/system are touched — a distribution's own unit in
// /lib is not ours to delete.
func (c *linuxCollector) DeleteSystemdUnit(name string) error {
	clean, err := validUnitName(name)
	if err != nil {
		return err
	}
	path := unitPath(clean)
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("%s.service is not in %s — Beacle only removes units it can see there",
			clean, systemdUnitDir)
	}
	unitName := clean + ".service"
	_ = exec.Command("systemctl", "stop", unitName).Run()
	_ = exec.Command("systemctl", "disable", unitName).Run()
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove %s: %w", path, err)
	}
	if out, err := exec.Command("systemctl", "daemon-reload").CombinedOutput(); err != nil {
		return fmt.Errorf("daemon-reload: %s", strings.TrimSpace(string(out)))
	}
	systemd.InvalidateUnitFiles()
	return nil
}
