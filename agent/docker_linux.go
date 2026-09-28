//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

// dockerClient talks to the Docker Engine API over the unix socket, so the
// agent works even when the docker CLI is not installed.
type dockerClient struct {
	http *http.Client

	// prevStats keeps the last one-shot reading per container so CPU% can be
	// computed across polls. The Engine API's default (one-shot=false) waits
	// ~1s inside dockerd for a second sample on every call — with N running
	// containers that was N seconds of work every collection, which is what
	// selfstat measured as docker: 1129ms on a nearly idle host.
	statsMu   sync.Mutex
	prevStats map[string]dockerCPUSample
	lastStats []shared.ContainerStats
	statsAt   time.Time

	// inspectCache avoids a full /containers/{id}/json round-trip for every
	// container on every poll when the container has not changed state.
	inspectMu    sync.Mutex
	inspectCache map[string]cachedInspect

	// images/volumes/networks barely change; refreshing them on every docker
	// tick was pure dockerd CPU for no visible gain.
	invMu        sync.Mutex
	images       []shared.ImageInfo
	volumes      []shared.DockerVolume
	networks     []shared.DockerNetwork
	inventoryAt  time.Time
}

type dockerCPUSample struct {
	totalUsage  uint64
	systemUsage uint64
	at          time.Time
}

type cachedInspect struct {
	state        string
	restartCount int
	exitCode     int
	at           time.Time
}

const (
	inspectCacheFor   = 60 * time.Second
	dockerStatsEvery  = 45 * time.Second
	dockerInventoryFor = 3 * time.Minute
)

func newDockerClient() *dockerClient {
	return &dockerClient{
		http: &http.Client{
			// Collection must stay well under the sync interval. A hung dockerd
			// used to pin a collector for the full 20s and pile work behind it.
			Timeout: 10 * time.Second,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					var d net.Dialer
					return d.DialContext(ctx, "unix", "/var/run/docker.sock")
				},
			},
		},
		prevStats:    map[string]dockerCPUSample{},
		inspectCache: map[string]cachedInspect{},
	}
}

func (d *dockerClient) get(path string, out any) error {
	resp, err := d.http.Get("http://docker" + path)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("docker api %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (d *dockerClient) post(path string) error {
	resp, err := d.http.Post("http://docker"+path, "application/json", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("docker api %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

func (d *dockerClient) delete(path string) error {
	req, err := http.NewRequest(http.MethodDelete, "http://docker"+path, nil)
	if err != nil {
		return err
	}
	resp, err := d.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("docker api %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

// postJSON sends a JSON body and decodes a JSON answer. A nil in sends an
// empty body; a nil out skips decoding (status is still checked).
func (d *dockerClient) postJSON(path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	resp, err := d.http.Post("http://docker"+path, "application/json", body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("docker api %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// --- raw API shapes ----------------------------------------------------------

type apiContainer struct {
	ID      string            `json:"Id"`
	Names   []string          `json:"Names"`
	Image   string            `json:"Image"`
	State   string            `json:"State"`
	Status  string            `json:"Status"`
	Created int64             `json:"Created"`
	Labels  map[string]string `json:"Labels"`
	Ports   []struct {
		IP          string `json:"IP"`
		PrivatePort int    `json:"PrivatePort"`
		PublicPort  int    `json:"PublicPort"`
		Type        string `json:"Type"`
	} `json:"Ports"`
}

type apiInspect struct {
	RestartCount int `json:"RestartCount"`
	State        struct {
		ExitCode int `json:"ExitCode"`
	} `json:"State"`
}

type apiImage struct {
	ID       string   `json:"Id"`
	RepoTags []string `json:"RepoTags"`
	Size     uint64   `json:"Size"`
	Created  int64    `json:"Created"`
}

type apiStats struct {
	CPUStats struct {
		CPUUsage struct {
			TotalUsage uint64 `json:"total_usage"`
		} `json:"cpu_usage"`
		SystemUsage uint64 `json:"system_cpu_usage"`
		OnlineCPUs  int    `json:"online_cpus"`
	} `json:"cpu_stats"`
	PreCPUStats struct {
		CPUUsage struct {
			TotalUsage uint64 `json:"total_usage"`
		} `json:"cpu_usage"`
		SystemUsage uint64 `json:"system_cpu_usage"`
	} `json:"precpu_stats"`
	MemoryStats struct {
		Usage uint64            `json:"usage"`
		Limit uint64            `json:"limit"`
		Stats map[string]uint64 `json:"stats"`
	} `json:"memory_stats"`
	Networks map[string]struct {
		RxBytes uint64 `json:"rx_bytes"`
		TxBytes uint64 `json:"tx_bytes"`
	} `json:"networks"`
	BlkioStats struct {
		IOServiceBytesRecursive []struct {
			Op    string `json:"op"`
			Value uint64 `json:"value"`
		} `json:"io_service_bytes_recursive"`
	} `json:"blkio_stats"`
	PidsStats struct {
		Current int `json:"current"`
	} `json:"pids_stats"`
	Name string `json:"name"`
	ID   string `json:"id"`
}

// --- Collector implementation -------------------------------------------------

func (c *linuxCollector) Docker() shared.DockerState {
	st := shared.DockerState{}
	var ver struct {
		Version string `json:"Version"`
	}
	if err := c.docker.get("/version", &ver); err != nil {
		st.Available = false
		st.Error = err.Error()
		return st
	}
	st.Available = true
	st.Version = ver.Version

	var raw []apiContainer
	if err := c.docker.get("/containers/json?all=1", &raw); err != nil {
		st.Error = err.Error()
		return st
	}
	compose := map[string]*shared.ComposeProject{}
	for _, rc := range raw {
		name := ""
		if len(rc.Names) > 0 {
			name = strings.TrimPrefix(rc.Names[0], "/")
		}
		ci := shared.ContainerInfo{
			ID:             rc.ID,
			Name:           name,
			Image:          rc.Image,
			State:          rc.State,
			Status:         rc.Status,
			CreatedAt:      time.Unix(rc.Created, 0).UTC(),
			ComposeProject: rc.Labels["com.docker.compose.project"],
			ComposeService: rc.Labels["com.docker.compose.service"],
		}
		for _, p := range rc.Ports {
			ci.Ports = append(ci.Ports, shared.ContainerPort{
				PrivatePort: p.PrivatePort, PublicPort: p.PublicPort, Protocol: p.Type, IP: p.IP,
			})
		}
		ci.RestartCount, ci.ExitCode = c.docker.inspectExtras(rc.ID, rc.State)
		st.Containers = append(st.Containers, ci)

		if proj := ci.ComposeProject; proj != "" {
			cp, ok := compose[proj]
			if !ok {
				cp = &shared.ComposeProject{
					Name:       proj,
					WorkingDir: rc.Labels["com.docker.compose.project.working_dir"],
					ConfigFile: rc.Labels["com.docker.compose.project.config_files"],
				}
				compose[proj] = cp
			}
			cp.Total++
			if rc.State == "running" {
				cp.Running++
			}
			if ci.ComposeService != "" {
				cp.Services = append(cp.Services, ci.ComposeService)
			}
		}
	}
	for _, cp := range compose {
		sort.Strings(cp.Services)
		st.Compose = append(st.Compose, *cp)
	}
	sort.Slice(st.Compose, func(i, j int) bool { return st.Compose[i].Name < st.Compose[j].Name })

	c.docker.attachInventory(&st)
	c.docker.attachStats(c, &st)
	c.docker.pruneCaches(st.Containers)
	return st
}

func (d *dockerClient) attachInventory(st *shared.DockerState) {
	d.invMu.Lock()
	fresh := !d.inventoryAt.IsZero() && time.Since(d.inventoryAt) < dockerInventoryFor
	if fresh {
		st.Images = append([]shared.ImageInfo(nil), d.images...)
		st.Volumes = append([]shared.DockerVolume(nil), d.volumes...)
		st.Networks = append([]shared.DockerNetwork(nil), d.networks...)
		d.invMu.Unlock()
		return
	}
	d.invMu.Unlock()

	var images []shared.ImageInfo
	var imgs []apiImage
	if err := d.get("/images/json", &imgs); err == nil {
		for _, im := range imgs {
			images = append(images, shared.ImageInfo{
				ID: im.ID, Tags: im.RepoTags, SizeBytes: im.Size, CreatedAt: im.Created,
			})
		}
	}

	var volumes []shared.DockerVolume
	var vols struct {
		Volumes []struct {
			Name       string `json:"Name"`
			Driver     string `json:"Driver"`
			Mountpoint string `json:"Mountpoint"`
			Scope      string `json:"Scope"`
			CreatedAt  string `json:"CreatedAt"`
		} `json:"Volumes"`
	}
	if err := d.get("/volumes", &vols); err == nil {
		for _, v := range vols.Volumes {
			volumes = append(volumes, shared.DockerVolume{
				Name: v.Name, Driver: v.Driver, Mountpoint: v.Mountpoint, Scope: v.Scope, CreatedAt: v.CreatedAt,
			})
		}
		sort.Slice(volumes, func(i, j int) bool { return volumes[i].Name < volumes[j].Name })
	}

	var networks []shared.DockerNetwork
	var nets []struct {
		ID         string         `json:"Id"`
		Name       string         `json:"Name"`
		Driver     string         `json:"Driver"`
		Scope      string         `json:"Scope"`
		Containers map[string]any `json:"Containers"`
	}
	if err := d.get("/networks", &nets); err == nil {
		for _, n := range nets {
			networks = append(networks, shared.DockerNetwork{
				ID: n.ID, Name: n.Name, Driver: n.Driver, Scope: n.Scope, Containers: len(n.Containers),
			})
		}
		sort.Slice(networks, func(i, j int) bool { return networks[i].Name < networks[j].Name })
	}

	d.invMu.Lock()
	d.images, d.volumes, d.networks = images, volumes, networks
	d.inventoryAt = time.Now()
	d.invMu.Unlock()

	st.Images = images
	st.Volumes = volumes
	st.Networks = networks
}

// attachStats fills live container stats at most once per dockerStatsEvery.
// Doing it on every docker tick (and once per running container) was the main
// remaining cost after one-shot — dockerd still has to walk cgroups.
func (d *dockerClient) attachStats(c *linuxCollector, st *shared.DockerState) {
	d.statsMu.Lock()
	if !d.statsAt.IsZero() && time.Since(d.statsAt) < dockerStatsEvery && len(d.lastStats) > 0 {
		st.Stats = append([]shared.ContainerStats(nil), d.lastStats...)
		d.statsMu.Unlock()
		return
	}
	d.statsMu.Unlock()

	var stats []shared.ContainerStats
	for _, ci := range st.Containers {
		if ci.State != "running" {
			continue
		}
		if stat, err := c.DockerStats(ci.ID); err == nil {
			stats = append(stats, stat)
		}
	}

	d.statsMu.Lock()
	d.lastStats = stats
	d.statsAt = time.Now()
	d.statsMu.Unlock()
	st.Stats = stats
}

// pruneCaches drops readings for containers that are gone, so a recreate under
// a new id cannot compute CPU% against a stranger's counters.
func (d *dockerClient) pruneCaches(containers []shared.ContainerInfo) {
	live := make(map[string]bool, len(containers))
	for _, c := range containers {
		live[c.ID] = true
	}
	d.statsMu.Lock()
	for id := range d.prevStats {
		if !live[id] {
			delete(d.prevStats, id)
		}
	}
	d.statsMu.Unlock()
	d.inspectMu.Lock()
	for id := range d.inspectCache {
		if !live[id] {
			delete(d.inspectCache, id)
		}
	}
	d.inspectMu.Unlock()
}

func (c *linuxCollector) DockerAction(id, action string) error {
	switch action {
	case "start", "stop", "restart":
		return c.docker.post("/containers/" + id + "/" + action)
	case "remove", "rm":
		return c.docker.delete("/containers/" + id + "?force=true")
	}
	return fmt.Errorf("unknown docker action %q", action)
}

// inspectExtras returns RestartCount and ExitCode, reusing a short cache so a
// fleet of stopped containers does not mean a fleet of inspect round-trips.
func (d *dockerClient) inspectExtras(id, state string) (restartCount, exitCode int) {
	d.inspectMu.Lock()
	if c, ok := d.inspectCache[id]; ok && c.state == state && time.Since(c.at) < inspectCacheFor {
		d.inspectMu.Unlock()
		return c.restartCount, c.exitCode
	}
	d.inspectMu.Unlock()

	var ins apiInspect
	if err := d.get("/containers/"+id+"/json", &ins); err != nil {
		return 0, 0
	}
	d.inspectMu.Lock()
	d.inspectCache[id] = cachedInspect{
		state: state, restartCount: ins.RestartCount, exitCode: ins.State.ExitCode, at: time.Now(),
	}
	d.inspectMu.Unlock()
	return ins.RestartCount, ins.State.ExitCode
}

func (c *linuxCollector) DockerStats(id string) (shared.ContainerStats, error) {
	var s apiStats
	// one-shot=true: a single counter reading, returned immediately. CPU% is
	// derived from the previous reading we kept ourselves (see prevStats).
	if err := c.docker.get("/containers/"+id+"/stats?stream=false&one-shot=true", &s); err != nil {
		return shared.ContainerStats{}, err
	}
	out := shared.ContainerStats{
		ID:          id,
		Name:        strings.TrimPrefix(s.Name, "/"),
		MemUsage:    s.MemoryStats.Usage,
		MemLimit:    s.MemoryStats.Limit,
		PIDs:        s.PidsStats.Current,
		CollectedAt: time.Now().UTC().Format(time.RFC3339),
	}
	// subtract inactive file cache like `docker stats` does
	if cache, ok := s.MemoryStats.Stats["inactive_file"]; ok && cache < out.MemUsage {
		out.MemUsage -= cache
	}
	if out.MemLimit > 0 {
		out.MemPercent = float64(out.MemUsage) / float64(out.MemLimit) * 100
	}

	total := s.CPUStats.CPUUsage.TotalUsage
	system := s.CPUStats.SystemUsage
	c.docker.statsMu.Lock()
	prev, had := c.docker.prevStats[id]
	c.docker.prevStats[id] = dockerCPUSample{totalUsage: total, systemUsage: system, at: time.Now()}
	c.docker.statsMu.Unlock()

	if had && system > prev.systemUsage && total >= prev.totalUsage {
		cpuDelta := float64(total - prev.totalUsage)
		sysDelta := float64(system - prev.systemUsage)
		if sysDelta > 0 && cpuDelta > 0 {
			cpus := float64(s.CPUStats.OnlineCPUs)
			if cpus == 0 {
				cpus = 1
			}
			out.CPUPercent = cpuDelta / sysDelta * cpus * 100
		}
	}
	for _, n := range s.Networks {
		out.NetRxBytes += n.RxBytes
		out.NetTxBytes += n.TxBytes
	}
	for _, io := range s.BlkioStats.IOServiceBytesRecursive {
		switch strings.ToLower(io.Op) {
		case "read":
			out.BlockRead += io.Value
		case "write":
			out.BlockWrite += io.Value
		}
	}
	return out, nil
}

// DockerLogs reads the multiplexed log stream (8 byte header frames).
func (c *linuxCollector) DockerLogs(id string, tail int) (string, error) {
	if tail <= 0 {
		tail = 200
	}
	url := fmt.Sprintf("http://docker/containers/%s/logs?stdout=1&stderr=1&tail=%d&timestamps=1", id, tail)
	resp, err := c.docker.http.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("docker logs: %s", strings.TrimSpace(string(b)))
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return "", err
	}
	return demuxDockerStream(raw), nil
}

// demuxDockerStream decodes the 8-byte-header multiplexed stream dockerd
// returns for non-TTY output (logs, exec). TTY output is a raw stream and
// passes through untouched — see the header sniff below.
func demuxDockerStream(raw []byte) string {
	// TTY containers return a raw stream; multiplexed streams start with a
	// header whose byte 0 is 0/1/2 and bytes 1-3 are zero.
	if len(raw) < 8 || raw[0] > 2 || raw[1] != 0 || raw[2] != 0 || raw[3] != 0 {
		return string(raw)
	}
	var sb strings.Builder
	for len(raw) >= 8 {
		size := binary.BigEndian.Uint32(raw[4:8])
		raw = raw[8:]
		if uint32(len(raw)) < size {
			sb.Write(raw)
			break
		}
		sb.Write(raw[:size])
		raw = raw[size:]
	}
	return sb.String()
}

const (
	// dockerExecTimeout bounds one-shot exec. The default 10s client budget is
	// too tight for migrations; beyond 30s the user should open a shell.
	dockerExecTimeout = 30 * time.Second
	dockerExecMaxOut  = 256 << 10
	dockerExecMaxCmd  = 4 << 10
)

// DockerExec runs a one-shot shell command inside a container and returns its
// combined output. The command runs as `sh -c "<command>"` so pipes and
// redirects work the way they do in a terminal.
func (c *linuxCollector) DockerExec(id, command string) (shared.DockerExecResult, error) {
	var res shared.DockerExecResult
	command = strings.TrimSpace(command)
	if command == "" {
		return res, fmt.Errorf("command is required")
	}
	if len(command) > dockerExecMaxCmd {
		return res, fmt.Errorf("command too long (max %d bytes)", dockerExecMaxCmd)
	}

	var created struct {
		ID string `json:"Id"`
	}
	if err := c.docker.postJSON("/containers/"+id+"/exec", map[string]any{
		"AttachStdout": true,
		"AttachStderr": true,
		"Cmd":          []string{"sh", "-c", command},
	}, &created); err != nil {
		return res, err
	}
	if created.ID == "" {
		return res, fmt.Errorf("docker exec: no exec id returned")
	}

	// The start call streams until the command finishes, so it gets its own
	// client with an exec-sized budget instead of the 10s collection one.
	long := &http.Client{Timeout: dockerExecTimeout + 10*time.Second, Transport: c.docker.http.Transport}
	startBody, _ := json.Marshal(map[string]any{"Detach": false, "Tty": false})
	ctx, cancel := context.WithTimeout(context.Background(), dockerExecTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://docker/exec/"+created.ID+"/start", bytes.NewReader(startBody))
	if err != nil {
		return res, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := long.Do(req)
	if err != nil {
		return res, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return res, fmt.Errorf("docker exec start: %s", strings.TrimSpace(string(b)))
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, dockerExecMaxOut+1))
	if err != nil {
		return res, err
	}
	if len(raw) > dockerExecMaxOut {
		res.Truncated = true
		raw = raw[:dockerExecMaxOut]
	}
	res.Output = demuxDockerStream(raw)

	var inspect struct {
		ExitCode int `json:"ExitCode"`
	}
	if err := c.docker.get("/exec/"+created.ID+"/json", &inspect); err == nil {
		res.ExitCode = inspect.ExitCode
	}
	return res, nil
}

const composeTimeout = 5 * time.Minute

// ComposeAction runs a compose lifecycle command against a project the agent
// knows from container labels. Unlike containers, compose has no Engine API —
// this shells out to the docker CLI, which must be installed on the VPS.
func (c *linuxCollector) ComposeAction(project, action string) (shared.ComposeActionResult, error) {
	var res shared.ComposeActionResult
	switch action {
	case "restart", "up", "down", "pull":
	default:
		return res, fmt.Errorf("unknown compose action %q", action)
	}
	if strings.TrimSpace(project) == "" {
		return res, fmt.Errorf("project is required")
	}
	if _, err := exec.LookPath("docker"); err != nil {
		return res, fmt.Errorf("docker CLI not found on this host")
	}

	dir, cfg := c.composeProjectDir(project)
	if dir == "" {
		return res, fmt.Errorf("compose project %q not found (no containers carry its labels)", project)
	}

	// "up" means pull-then-up: separate invocations, one answer.
	steps := [][]string{}
	switch action {
	case "restart":
		steps = append(steps, []string{"restart"})
	case "pull":
		steps = append(steps, []string{"pull"})
	case "down":
		steps = append(steps, []string{"down"})
	case "up":
		steps = append(steps, []string{"pull"}, []string{"up", "-d"})
	}

	ctx, cancel := context.WithTimeout(context.Background(), composeTimeout)
	defer cancel()
	var sb strings.Builder
	for _, step := range steps {
		args := []string{"compose", "-p", project}
		for _, f := range strings.Split(cfg, ",") {
			if f = strings.TrimSpace(f); f != "" {
				args = append(args, "-f", f)
			}
		}
		args = append(args, step...)
		cmd := exec.CommandContext(ctx, "docker", args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		sb.Write(out)
		if len(sb.String()) > dockerExecMaxOut {
			break
		}
		if err != nil {
			if ctx.Err() == context.DeadlineExceeded {
				return res, fmt.Errorf("compose %s timed out after %s", strings.Join(step, " "), composeTimeout)
			}
			return res, fmt.Errorf("compose %s failed: %s", strings.Join(step, " "), strings.TrimSpace(string(out)))
		}
	}
	res.Output = sb.String()
	if len(res.Output) > dockerExecMaxOut {
		res.Output = res.Output[:dockerExecMaxOut] + "\n…(truncated)"
	}
	return res, nil
}

// composeProjectDir recovers a project's working dir and config files from the
// labels dockerd stamps on every compose-created container.
func (c *linuxCollector) composeProjectDir(project string) (dir, config string) {
	var raw []apiContainer
	if err := c.docker.get("/containers/json?all=1", &raw); err != nil {
		return "", ""
	}
	for _, rc := range raw {
		if rc.Labels["com.docker.compose.project"] == project {
			return rc.Labels["com.docker.compose.project.working_dir"],
				rc.Labels["com.docker.compose.project.config_files"]
		}
	}
	return "", ""
}

type apiDiskUsage struct {
	Images []struct {
		Size       int64 `json:"Size"`
		SharedSize int64 `json:"SharedSize"`
		UsageCount int   `json:"UsageCount"`
	} `json:"Images"`
	Volumes []struct {
		Size       int64 `json:"Size"`
		UsageCount int   `json:"UsageCount"`
	} `json:"Volumes"`
}

// PrunePreview estimates what a prune would reclaim, from dockerd's own disk
// usage report. Shared layers are subtracted so the number does not pretend
// every image owns its base.
func (c *linuxCollector) PrunePreview() (shared.DockerPrunePreview, error) {
	var res shared.DockerPrunePreview
	var du apiDiskUsage
	if err := c.docker.get("/system/df", &du); err != nil {
		return res, err
	}
	for _, im := range du.Images {
		if im.UsageCount <= 0 {
			res.DanglingImages++
			if own := im.Size - im.SharedSize; own > 0 {
				res.DanglingBytes += uint64(own)
			}
		}
	}
	for _, v := range du.Volumes {
		if v.UsageCount <= 0 {
			res.UnusedVolumes++
			if v.Size > 0 {
				res.UnusedVolumesBytes += uint64(v.Size)
			}
		}
	}
	return res, nil
}

// DockerPrune removes unused images, volumes and/or builder cache, exactly the
// scopes the panel asked for. The inventory cache is dropped so the next
// snapshot shows the freed space immediately.
func (c *linuxCollector) DockerPrune(req shared.DockerPruneRequest) (shared.DockerPruneResult, error) {
	var res shared.DockerPruneResult
	if !req.Images && !req.Volumes && !req.Builder {
		return res, fmt.Errorf("nothing selected")
	}
	var sb strings.Builder
	if req.Images {
		var out struct {
			ImagesDeleted []struct {
				Deleted  string `json:"Deleted"`
				Untagged string `json:"Untagged"`
			} `json:"ImagesDeleted"`
			SpaceReclaimed uint64 `json:"SpaceReclaimed"`
		}
		if err := c.docker.postJSON("/images/prune", map[string]any{}, &out); err != nil {
			return res, err
		}
		res.ImagesDeleted = len(out.ImagesDeleted)
		res.SpaceReclaimed += out.SpaceReclaimed
		fmt.Fprintf(&sb, "images: %d entries deleted\n", len(out.ImagesDeleted))
	}
	if req.Volumes {
		var out struct {
			VolumesDeleted []string `json:"VolumesDeleted"`
			SpaceReclaimed uint64   `json:"SpaceReclaimed"`
		}
		if err := c.docker.postJSON("/volumes/prune", map[string]any{}, &out); err != nil {
			return res, err
		}
		res.VolumesDeleted = len(out.VolumesDeleted)
		res.SpaceReclaimed += out.SpaceReclaimed
		fmt.Fprintf(&sb, "volumes: %d deleted\n", len(out.VolumesDeleted))
	}
	if req.Builder {
		var out struct {
			SpaceReclaimed uint64 `json:"SpaceReclaimed"`
		}
		if err := c.docker.postJSON("/build/prune", map[string]any{}, &out); err != nil {
			return res, err
		}
		res.SpaceReclaimed += out.SpaceReclaimed
		sb.WriteString("builder cache pruned\n")
	}
	c.docker.invMu.Lock()
	c.docker.inventoryAt = time.Time{}
	c.docker.invMu.Unlock()
	res.Output = sb.String()
	return res, nil
}
