// Package shared contains DTOs and protocol types used by both the Beacle
// backend and the VPS agent. The Flutter app mirrors these shapes in Dart
// (app/lib/models). Field names are the wire contract - do not rename JSON
// tags without bumping ProtocolVersion.
package shared

import (
	"encoding/json"
	"time"
)

const ProtocolVersion = 1

// ---------------------------------------------------------------------------
// System metrics
// ---------------------------------------------------------------------------

type DiskUsage struct {
	Mount       string  `json:"mount"`
	Filesystem  string  `json:"filesystem"`
	TotalBytes  uint64  `json:"total_bytes"`
	UsedBytes   uint64  `json:"used_bytes"`
	UsedPercent float64 `json:"used_percent"`
}

type NetworkStats struct {
	Interface string `json:"interface"`
	RxBytes   uint64 `json:"rx_bytes"`
	TxBytes   uint64 `json:"tx_bytes"`
	RxPerSec  uint64 `json:"rx_per_sec"`
	TxPerSec  uint64 `json:"tx_per_sec"`
}

type SystemMetrics struct {
	Hostname      string         `json:"hostname"`
	OS            string         `json:"os"`
	Kernel        string         `json:"kernel"`
	Arch          string         `json:"arch"`
	CPUPercent    float64        `json:"cpu_percent"`
	CPUCores      int            `json:"cpu_cores"`
	CPUModel      string         `json:"cpu_model"`
	// CPUPerCore is per-logical-CPU usage (0–100), same order as /proc/stat cpuN.
	CPUPerCore []float64 `json:"cpu_per_core,omitempty"`
	// MemUsedBytes / MemPercent: app usage (MemTotal − MemAvailable). Cache is reclaimable.
	MemTotalBytes uint64  `json:"mem_total_bytes"`
	MemUsedBytes  uint64  `json:"mem_used_bytes"`
	MemPercent    float64 `json:"mem_percent"`
	// MemCachedBytes: Buffers + Cached from /proc/meminfo.
	MemCachedBytes uint64 `json:"mem_cached_bytes"`
	// MemUsedCachedBytes / MemPercentCached: MemTotal − MemFree (includes buffers/cache).
	MemUsedCachedBytes uint64  `json:"mem_used_cached_bytes"`
	MemPercentCached   float64 `json:"mem_percent_cached"`
	SwapTotal          uint64  `json:"swap_total_bytes"`
	SwapUsed           uint64  `json:"swap_used_bytes"`
	Disks              []DiskUsage    `json:"disks"`
	UptimeSeconds      uint64         `json:"uptime_seconds"`
	Load1              float64        `json:"load1"`
	Load5              float64        `json:"load5"`
	Load15             float64        `json:"load15"`
	Network            []NetworkStats `json:"network"`
	CollectedAt        time.Time      `json:"collected_at"`
}

type ProcessInfo struct {
	PID        int     `json:"pid"`
	Name       string  `json:"name"`
	User       string  `json:"user"`
	CPUPercent float64 `json:"cpu_percent"`
	MemPercent float64 `json:"mem_percent"`
	MemBytes   uint64  `json:"mem_bytes"`
	Command    string  `json:"command"`
	State      string  `json:"state"`
}

// PortInfo answers "who is using this port".
type PortInfo struct {
	Port        int    `json:"port"`
	Protocol    string `json:"protocol"` // tcp | udp
	ListenAddr  string `json:"listen_addr"`
	PID         int    `json:"pid"`
	ProcessName string `json:"process_name"`
	CommandLine string `json:"command_line"`
	// Healthy is true when an HTTP/TCP probe of the port succeeds.
	Healthy      bool   `json:"healthy"`
	HealthDetail string `json:"health_detail"`
}

// ---------------------------------------------------------------------------
// Docker
// ---------------------------------------------------------------------------

type ContainerPort struct {
	PrivatePort int    `json:"private_port"`
	PublicPort  int    `json:"public_port"`
	Protocol    string `json:"protocol"`
	IP          string `json:"ip"`
}

type ContainerInfo struct {
	ID             string          `json:"id"`
	Name           string          `json:"name"`
	Image          string          `json:"image"`
	State          string          `json:"state"`  // running | exited | restarting | paused | dead | created
	Status         string          `json:"status"` // human readable, e.g. "Up 3 hours"
	CreatedAt      time.Time       `json:"created_at"`
	Ports          []ContainerPort `json:"ports"`
	ComposeProject string          `json:"compose_project"`
	ComposeService string          `json:"compose_service"`
	RestartCount   int             `json:"restart_count"`
	ExitCode       int             `json:"exit_code"`
}

type ContainerStats struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	CPUPercent  float64 `json:"cpu_percent"`
	MemUsage    uint64  `json:"mem_usage_bytes"`
	MemLimit    uint64  `json:"mem_limit_bytes"`
	MemPercent  float64 `json:"mem_percent"`
	NetRxBytes  uint64  `json:"net_rx_bytes"`
	NetTxBytes  uint64  `json:"net_tx_bytes"`
	BlockRead   uint64  `json:"block_read_bytes"`
	BlockWrite  uint64  `json:"block_write_bytes"`
	PIDs        int     `json:"pids"`
	CollectedAt string  `json:"collected_at"`
}

type ImageInfo struct {
	ID        string   `json:"id"`
	Tags      []string `json:"tags"`
	SizeBytes uint64   `json:"size_bytes"`
	CreatedAt int64    `json:"created_at"`
}

type ComposeProject struct {
	Name       string   `json:"name"`
	WorkingDir string   `json:"working_dir"`
	ConfigFile string   `json:"config_file"`
	Services   []string `json:"services"`
	Running    int      `json:"running"`
	Total      int      `json:"total"`
}

type DockerState struct {
	Available  bool             `json:"available"`
	Error      string           `json:"error,omitempty"`
	Version    string           `json:"version"`
	Containers []ContainerInfo  `json:"containers"`
	Stats      []ContainerStats `json:"stats"`
	Images     []ImageInfo      `json:"images"`
	Compose    []ComposeProject `json:"compose"`
}

// ---------------------------------------------------------------------------
// Services (systemd + screen)
// ---------------------------------------------------------------------------

type SystemdUnit struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	LoadState   string `json:"load_state"`
	ActiveState string `json:"active_state"` // active | inactive | failed | activating
	SubState    string `json:"sub_state"`    // running | dead | exited | ...
	Enabled     string `json:"enabled"`
}

type ScreenSession struct {
	PID      int    `json:"pid"`
	Name     string `json:"name"`
	Attached bool   `json:"attached"`
	Created  string `json:"created"`
}

type ServicesState struct {
	Systemd []SystemdUnit   `json:"systemd"`
	Screen  []ScreenSession `json:"screen"`
}

// ---------------------------------------------------------------------------
// Reverse proxy
// ---------------------------------------------------------------------------

type ProxyProviderKind string

const (
	ProxyProviderCaddy ProxyProviderKind = "caddy"
	ProxyProviderNPM   ProxyProviderKind = "npm" // Nginx Proxy Manager
	ProxyProviderNone  ProxyProviderKind = "none"
)

type SSLStatus string

const (
	SSLActive   SSLStatus = "active"
	SSLPending  SSLStatus = "pending"
	SSLError    SSLStatus = "error"
	SSLDisabled SSLStatus = "disabled"
)

type ProxySite struct {
	ID       string    `json:"id"`
	Domain   string    `json:"domain"`
	Upstream string    `json:"upstream"` // e.g. localhost:3000
	SSL      SSLStatus `json:"ssl"`
	Enabled  bool      `json:"enabled"`
	Provider ProxyProviderKind `json:"provider"`
	// Extra carries provider specific settings (websocket support, block
	// exploits for NPM, etc).
	Extra map[string]string `json:"extra,omitempty"`
}

type ProxyState struct {
	Provider  ProxyProviderKind `json:"provider"`
	Running   bool              `json:"running"`
	Version   string            `json:"version"`
	Sites     []ProxySite       `json:"sites"`
	LastError string            `json:"last_error,omitempty"`
}

type ProxySiteRequest struct {
	Domain    string            `json:"domain"`
	Upstream  string            `json:"upstream"`
	EnableSSL bool              `json:"enable_ssl"`
	Extra     map[string]string `json:"extra,omitempty"`
}

type ProxyValidateResult struct {
	Valid  bool   `json:"valid"`
	Output string `json:"output"`
}

// ---------------------------------------------------------------------------
// Agent <-> Backend protocol
// ---------------------------------------------------------------------------

// RegisterRequest is sent by the agent on every startup. First-time agents
// send it without credentials; the backend then auto-creates the VPS entry
// and returns the assigned ID + token. Returning agents authenticate with
// their token (Authorization: Bearer).
type RegisterRequest struct {
	VPSID         string `json:"vps_id,omitempty"`
	Hostname      string `json:"hostname"`
	TailscaleName string `json:"tailscale_name"`
	TailscaleIP   string `json:"tailscale_ip"`
	// PublicIP is the VPS egress address (e.g. from ipify) used for map geolocation.
	PublicIP     string `json:"public_ip,omitempty"`
	AgentVersion string `json:"agent_version"`
	AgentPort    int    `json:"agent_port"`
	OS           string `json:"os"`
}

type RegisterResponse struct {
	OK        string    `json:"ok"`
	VPSID     string    `json:"vps_id"`
	Token     string    `json:"token,omitempty"` // set on first registration
	PowerMode PowerMode `json:"power_mode,omitempty"`
}

type PingResult struct {
	Target     string  `json:"target"`
	LatencyMs  float64 `json:"latency_ms"`
	PacketLoss float64 `json:"packet_loss"` // 0..100
	Reachable  bool    `json:"reachable"`
}

// ---------------------------------------------------------------------------
// Agent ↔ Backend WebSocket tunnel (outbound from agent, CGNAT-safe)
// ---------------------------------------------------------------------------

// PowerMode is set by the backend; the agent owns all sync intervals per mode.
type PowerMode string

const (
	PowerModeActive PowerMode = "active"
	PowerModeEco    PowerMode = "eco"
	PowerModeSleep  PowerMode = "sleep"
)

type AgentWSMessageType string

const (
	AgentWSRegister        AgentWSMessageType = "register"
	AgentWSRegisterAck     AgentWSMessageType = "register_ack"
	AgentWSHeartbeat       AgentWSMessageType = "heartbeat"
	AgentWSMetrics         AgentWSMessageType = "metrics"
	AgentWSDockerSnapshot  AgentWSMessageType = "docker_snapshot"
	AgentWSSystemdSnapshot AgentWSMessageType = "systemd_snapshot"
	AgentWSPortsSnapshot   AgentWSMessageType = "ports_snapshot"
	AgentWSProxySnapshot   AgentWSMessageType = "proxy_snapshot"
	AgentWSAlert           AgentWSMessageType = "alert"
	AgentWSCommand         AgentWSMessageType = "command"
	AgentWSCommandResult   AgentWSMessageType = "command_result"
	AgentWSPowerMode       AgentWSMessageType = "power_mode"
	AgentWSRefresh         AgentWSMessageType = "refresh"
	AgentWSLogStream       AgentWSMessageType = "log_stream"
	AgentWSFileTransfer    AgentWSMessageType = "file_transfer"
	AgentWSError           AgentWSMessageType = "error"
)

// AgentWSMessage is the envelope on GET /agent/ws. The agent maintains an
// outbound WebSocket; the backend pushes commands and receives snapshots/results
// on that single connection — no inbound connections to the agent.
type AgentWSMessage struct {
	Type     AgentWSMessageType `json:"type"`
	Mode     PowerMode          `json:"mode,omitempty"`
	VPSID    string             `json:"vps_id,omitempty"`
	AgentVer string             `json:"agent_version,omitempty"`

	Register    *RegisterRequest    `json:"register,omitempty"`
	RegisterAck *RegisterResponse   `json:"register_ack,omitempty"`
	Command     *AgentCommand       `json:"command,omitempty"`
	Result      *AgentCommandResult `json:"result,omitempty"`

	Metrics  *SystemMetrics  `json:"metrics,omitempty"`
	Docker   *DockerState    `json:"docker,omitempty"`
	Services *ServicesState  `json:"services,omitempty"`
	Ports    []PortInfo      `json:"ports,omitempty"`
	Proxy    *ProxyState     `json:"proxy,omitempty"`

	Error string `json:"error,omitempty"`
}

// AgentCommand is sent backend→agent over the existing WS connection.
type AgentCommand struct {
	RequestID string          `json:"request_id"`
	Method    string          `json:"method"`
	Path      string          `json:"path"` // e.g. /api/system/processes?lines=200
	Body      json.RawMessage `json:"body,omitempty"`
}

// AgentCommandResult is the agent's HTTP-equivalent response to a command.
type AgentCommandResult struct {
	RequestID  string          `json:"request_id"`
	StatusCode int             `json:"status_code"`
	Body       json.RawMessage `json:"body"`
}

// ---------------------------------------------------------------------------
// VPS registry (backend)
// ---------------------------------------------------------------------------

type VPSStatus string

const (
	VPSOnline   VPSStatus = "online"
	VPSOffline  VPSStatus = "offline"
	VPSHighLoad VPSStatus = "high_load"
	VPSPending  VPSStatus = "pending" // created, agent never connected
)

type VPS struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	Host          string    `json:"host"` // Tailscale IPv4
	TailscaleName string    `json:"tailscale_name"`
	PublicIP      string    `json:"public_ip,omitempty"`
	Latitude      float64   `json:"latitude"`
	Longitude     float64   `json:"longitude"`
	Location      string    `json:"location"`
	Weight        int       `json:"weight"`
	Status        VPSStatus `json:"status"`
	AgentPort     int       `json:"agent_port"`
	AgentVer      string    `json:"agent_version"`
	CreatedAt     time.Time `json:"created_at"`
	LastSeen      time.Time `json:"last_seen"`
}

// CreateVPSRequest adds a server from the Tailscale device list (onboarding).
type CreateVPSRequest struct {
	Name          string `json:"name"`
	TailscaleName string `json:"tailscale_name"`
	TailscaleIP   string `json:"tailscale_ip"`
}

// UpdateVPSRequest edits metadata of an auto-registered VPS (display name,
// map position, weight). VPS entries themselves are only ever created by
// agents registering - never manually from the UI.
type UpdateVPSRequest struct {
	Name      string  `json:"name"`
	Host      string  `json:"host"`
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	Location  string  `json:"location"`
	Weight    int     `json:"weight"`
}

// VPSLink is a user created connection between two VPSes shown on the map.
type VPSLink struct {
	ID         string    `json:"id"`
	FromVPSID  string    `json:"from_vps_id"`
	ToVPSID    string    `json:"to_vps_id"`
	LatencyMs  float64   `json:"latency_ms"`
	PacketLoss float64   `json:"packet_loss"`
	Status     string    `json:"status"` // ok | degraded | down | unknown
	CheckedAt  time.Time `json:"checked_at"`
}

// ---------------------------------------------------------------------------
// Alerts
// ---------------------------------------------------------------------------

type AlertSeverity string

const (
	SeverityInfo     AlertSeverity = "info"
	SeverityWarning  AlertSeverity = "warning"
	SeverityCritical AlertSeverity = "critical"
)

type AlertType string

const (
	AlertCPUHigh      AlertType = "cpu_high"
	AlertMemHigh      AlertType = "mem_high"
	AlertDiskHigh     AlertType = "disk_high"
	AlertServiceDown  AlertType = "service_down"
	AlertDockerCrash  AlertType = "docker_crash"
	AlertProxyError   AlertType = "proxy_error"
	AlertAgentOffline AlertType = "agent_offline"
)

type Alert struct {
	ID        string        `json:"id"`
	VPSID     string        `json:"vps_id"`
	VPSName   string        `json:"vps_name"`
	Type      AlertType     `json:"type"`
	Severity  AlertSeverity `json:"severity"`
	Message   string        `json:"message"`
	CreatedAt time.Time     `json:"created_at"`
	Resolved  bool          `json:"resolved"`
}

// ---------------------------------------------------------------------------
// Action log
// ---------------------------------------------------------------------------

type ActionLog struct {
	ID        string    `json:"id"`
	VPSID     string    `json:"vps_id"`
	VPSName   string    `json:"vps_name"`
	Action    string    `json:"action"`
	Detail    string    `json:"detail"`
	OK        bool      `json:"ok"`
	CreatedAt time.Time `json:"created_at"`
}

// ---------------------------------------------------------------------------
// WebSocket envelope (backend -> UI)
// ---------------------------------------------------------------------------

type WSMessageType string

const (
	WSVPSUpdate   WSMessageType = "vps_update"   // payload: VPSSnapshot
	WSVPSList     WSMessageType = "vps_list"     // payload: []VPS
	WSAlert       WSMessageType = "alert"        // payload: Alert
	WSLinkUpdate  WSMessageType = "link_update"  // payload: VPSLink
	WSActionLog   WSMessageType = "action"       // payload: ActionLog
)

type WSMessage struct {
	Type    WSMessageType `json:"type"`
	Payload any           `json:"payload"`
}

// VPSSnapshot is the aggregated live view of one VPS kept by the backend and
// streamed to the UI.
type VPSSnapshot struct {
	VPS      VPS           `json:"vps"`
	Metrics  SystemMetrics `json:"metrics"`
	Docker   DockerState   `json:"docker"`
	Services ServicesState `json:"services"`
	Proxy    ProxyState    `json:"proxy"`
	Ports    []PortInfo    `json:"ports,omitempty"`
	Updated  time.Time     `json:"updated"`
}

type APIError struct {
	Error string `json:"error"`
}
