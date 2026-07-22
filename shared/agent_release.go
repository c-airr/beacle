package shared

import "fmt"

// GitHub release that distributes VPS agent binaries (public repo).
const (
	AgentGitHubOwner = "c-airr"
	AgentGitHubRepo  = "beacle"
	AgentReleaseTag  = "agentbeta"
)

// AgentGitHubAssetName returns the release asset for a Go GOARCH value.
func AgentGitHubAssetName(goarch string) string {
	switch goarch {
	case "arm64", "arm":
		return "beacle-agent-arm64"
	default:
		return "beacle-agent-amd64"
	}
}

// AgentGitHubBinaryURL is the direct download URL for the agent binary.
func AgentGitHubBinaryURL(goarch string) string {
	return fmt.Sprintf(
		"https://github.com/%s/%s/releases/download/%s/%s",
		AgentGitHubOwner, AgentGitHubRepo, AgentReleaseTag, AgentGitHubAssetName(goarch),
	)
}

// AgentGitHubInstallURL is the install.sh on the same public release.
func AgentGitHubInstallURL() string {
	return fmt.Sprintf(
		"https://github.com/%s/%s/releases/download/%s/install.sh",
		AgentGitHubOwner, AgentGitHubRepo, AgentReleaseTag,
	)
}

// AgentGitHubReleaseAPI is the GitHub API endpoint for the agentbeta release metadata.
func AgentGitHubReleaseAPI() string {
	return fmt.Sprintf(
		"https://api.github.com/repos/%s/%s/releases/tags/%s",
		AgentGitHubOwner, AgentGitHubRepo, AgentReleaseTag,
	)
}
