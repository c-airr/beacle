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

// WebhookMessage is one notification.
type WebhookMessage struct {
	Title    string `json:"title"`
	Body     string `json:"body"`
	Severity string `json:"severity"` // info | warning | critical
}

// WatchdogPeer is one fleet member a watcher keeps an eye on.
type WatchdogPeer struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Host string `json:"host"` // Tailscale IPv4
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
