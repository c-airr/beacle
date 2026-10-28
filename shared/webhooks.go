package shared

// Outgoing notifications: Discord, ntfy and Telegram, sent either by the
// backend or — the normal case — by watcher agents on the two most stable
// VPSes, so alerts survive the panel being closed. Both sides share these
// builders so a message looks the same whoever sends it.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

const (
	WebhookDiscord  = "discord"
	WebhookNtfy     = "ntfy"
	WebhookTelegram = "telegram"
)

// WebhookTarget is one notification destination. URL holds the Discord
// webhook URL, the ntfy topic URL, or the Telegram bot token (with ChatID).
type WebhookTarget struct {
	ID     string `json:"id"`
	Kind   string `json:"kind"` // discord | ntfy | telegram
	URL    string `json:"url"`
	ChatID string `json:"chat_id,omitempty"` // telegram only
}

// WebhookMessage is one notification. VPSID and Alert name what it is about
// when it is an alert, so a watcher can check the claim from where it stands
// before passing it on (see agent/watchdog.go). Both are blank for anything
// else — tests, recoveries — which is sent as is.
type WebhookMessage struct {
	Title    string `json:"title"`
	Body     string `json:"body"`
	Severity string `json:"severity"` // info | warning | critical
	VPSID    string `json:"vps_id,omitempty"`
	VPSName  string `json:"vps_name,omitempty"`
	Alert    string `json:"alert,omitempty"` // AlertType
}

// WatchdogSendResult is a watcher's answer to a send request. Sent=false with
// a Reason means the watcher checked the alert and found it untrue from its
// side (the agent answers it), so nothing went out — on purpose.
type WatchdogSendResult struct {
	Sent   bool   `json:"sent"`
	Reason string `json:"reason,omitempty"`
}

// WatchdogPeer is one fleet member a watcher keeps an eye on.
type WatchdogPeer struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Host string `json:"host"` // Tailscale IPv4
	// AgentPort is where the peer's agent answers liveness probes from other
	// agents (see agent/liveness.go). Zero means DefaultAgentPort.
	AgentPort int `json:"agent_port,omitempty"`
}

// Reachability alert texts, shared so the panel and a watcher that rewrites
// the alert after checking it word it the same (the app translates them by
// matching this exact English).
const (
	MsgAgentDown    = "Agent is not responding — the VPS itself still answers"
	MsgAgentOffline = "VPS offline — no answer on its address"
)

// AgentLivenessPath is the one unauthenticated route an agent serves to the
// tailnet: proof that the process is up, so a watcher can tell a dead agent
// from a panel that merely lost its tunnel.
const AgentLivenessPath = "/beacle/alive"

// AgentLiveness is the body of AgentLivenessPath.
type AgentLiveness struct {
	ID      string `json:"id"`
	Version string `json:"version"`
	// Backend reports whether this agent's own tunnel to the panel is up.
	Backend bool `json:"backend"`
}

// WatchdogConfig is pushed by the backend to the elected watchers. Disabled
// agents keep the file but never act on it.
type WatchdogConfig struct {
	Enabled   bool            `json:"enabled"`
	Role      string          `json:"role"` // primary | secondary | ""
	SelfID    string          `json:"self_id"`
	PrimaryID string          `json:"primary_id"`
	Webhooks  []WebhookTarget `json:"webhooks"`
	Peers     []WatchdogPeer  `json:"peers"`
	// PanelQuietMin, when set, is how long the panel may be unreachable
	// before the watcher says so. Zero: never (the default — the panel is
	// a desktop app, and a closed lid is no news).
	PanelQuietMin int `json:"panel_quiet_min,omitempty"`
}

// WatchdogStatus is the panel-facing summary (counts, never secret URLs).
type WatchdogStatus struct {
	Enabled  bool   `json:"enabled"`
	Role     string `json:"role"`
	Peers    int    `json:"peers"`
	Webhooks int    `json:"webhooks"`
}

var webhookHTTP = &http.Client{Timeout: 10 * time.Second}

// ValidateWebhookTarget rejects kinds the sender does not know and targets
// with nowhere to send to.
func ValidateWebhookTarget(t WebhookTarget) error {
	switch t.Kind {
	case WebhookDiscord, WebhookNtfy:
		if strings.TrimSpace(t.URL) == "" {
			return fmt.Errorf("%s needs a URL", t.Kind)
		}
		if !strings.HasPrefix(t.URL, "https://") && !strings.HasPrefix(t.URL, "http://") {
			return fmt.Errorf("%s URL must start with http(s)://", t.Kind)
		}
	case WebhookTelegram:
		if strings.TrimSpace(t.URL) == "" || strings.TrimSpace(t.ChatID) == "" {
			return fmt.Errorf("telegram needs a bot token and a chat id")
		}
	default:
		return fmt.Errorf("unknown webhook kind %q", t.Kind)
	}
	return nil
}

// SendWebhook delivers one message to one target.
func SendWebhook(t WebhookTarget, msg WebhookMessage) error {
	switch t.Kind {
	case WebhookDiscord:
		return sendDiscord(t.URL, msg)
	case WebhookNtfy:
		return sendNtfy(t.URL, msg)
	case WebhookTelegram:
		return sendTelegram(t.URL, t.ChatID, msg)
	default:
		return fmt.Errorf("unknown webhook kind %q", t.Kind)
	}
}

func discordColor(sev string) int {
	switch sev {
	case "critical":
		return 0xF87171
	case "warning":
		return 0xFBBF24
	default:
		return 0x4ADE80
	}
}

func sendDiscord(url string, msg WebhookMessage) error {
	payload := map[string]any{
		"username": "Beacle",
		"embeds": []map[string]any{
			{"title": msg.Title, "description": msg.Body, "color": discordColor(msg.Severity)},
		},
	}
	return postJSON(url, payload, nil)
}

func sendNtfy(url string, msg WebhookMessage) error {
	prio := "default"
	tags := "white_check_mark"
	switch msg.Severity {
	case "critical":
		prio = "urgent"
		tags = "rotating_light"
	case "warning":
		prio = "high"
		tags = "warning"
	}
	req, err := http.NewRequest("POST", url, strings.NewReader(msg.Body))
	if err != nil {
		return err
	}
	req.Header.Set("Title", msg.Title)
	req.Header.Set("Priority", prio)
	req.Header.Set("Tags", tags)
	resp, err := webhookHTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("ntfy: http %d", resp.StatusCode)
	}
	return nil
}

func sendTelegram(token, chatID string, msg WebhookMessage) error {
	url := "https://api.telegram.org/bot" + token + "/sendMessage"
	payload := map[string]any{
		"chat_id":    chatID,
		"text":       msg.Title + "\n" + msg.Body,
		"parse_mode": "HTML",
	}
	return postJSON(url, payload, nil)
}

func postJSON(url string, payload any, headers map[string]string) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequest("POST", url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := webhookHTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("webhook: http %d", resp.StatusCode)
	}
	return nil
}
