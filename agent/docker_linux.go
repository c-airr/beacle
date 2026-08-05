//go:build linux

package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
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

	// inspectCache avoids a full /containers/{id}/json round-trip for every
	// container on every poll when the container has not changed state.
	inspectMu    sync.Mutex
	inspectCache map[string]cachedInspect
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

const inspectCacheFor = 60 * time.Second

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

	var imgs []apiImage
	if err := c.docker.get("/images/json", &imgs); err == nil {
		for _, im := range imgs {
			st.Images = append(st.Images, shared.ImageInfo{
				ID: im.ID, Tags: im.RepoTags, SizeBytes: im.Size, CreatedAt: im.Created,
			})
		}
	}

	var vols struct {
		Volumes []struct {
			Name       string `json:"Name"`
			Driver     string `json:"Driver"`
			Mountpoint string `json:"Mountpoint"`
			Scope      string `json:"Scope"`
			CreatedAt  string `json:"CreatedAt"`
		} `json:"Volumes"`
	}
	if err := c.docker.get("/volumes", &vols); err == nil {
		for _, v := range vols.Volumes {
			st.Volumes = append(st.Volumes, shared.DockerVolume{
				Name: v.Name, Driver: v.Driver, Mountpoint: v.Mountpoint, Scope: v.Scope, CreatedAt: v.CreatedAt,
			})
		}
		sort.Slice(st.Volumes, func(i, j int) bool { return st.Volumes[i].Name < st.Volumes[j].Name })
	}

	var nets []struct {
		ID         string `json:"Id"`
		Name       string `json:"Name"`
		Driver     string `json:"Driver"`
		Scope      string `json:"Scope"`
		Containers map[string]any `json:"Containers"`
	}
	if err := c.docker.get("/networks", &nets); err == nil {
		for _, n := range nets {
			st.Networks = append(st.Networks, shared.DockerNetwork{
				ID: n.ID, Name: n.Name, Driver: n.Driver, Scope: n.Scope, Containers: len(n.Containers),
			})
		}
		sort.Slice(st.Networks, func(i, j int) bool { return st.Networks[i].Name < st.Networks[j].Name })
	}

	// live stats for running containers
	for _, ci := range st.Containers {
		if ci.State != "running" {
			continue
		}
		if stat, err := c.DockerStats(ci.ID); err == nil {
			st.Stats = append(st.Stats, stat)
		}
	}
	c.docker.pruneCaches(st.Containers)
	return st
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
	// TTY containers return a raw stream; multiplexed streams start with a
	// header whose byte 0 is 0/1/2 and bytes 1-3 are zero.
	if len(raw) < 8 || raw[0] > 2 || raw[1] != 0 || raw[2] != 0 || raw[3] != 0 {
		return string(raw), nil
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
	return sb.String(), nil
}
