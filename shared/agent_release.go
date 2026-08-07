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
	return AgentGitHubBinaryURLTag(AgentReleaseTag, goarch)
}

// AgentGitHubBinaryURLTag points at the binary inside a specific release tag,
// for the version picker in Settings (installing a chosen release, not just
// the rolling default).
func AgentGitHubBinaryURLTag(tag, goarch string) string {
	return fmt.Sprintf(
		"https://github.com/%s/%s/releases/download/%s/%s",
		AgentGitHubOwner, AgentGitHubRepo, tag, AgentGitHubAssetName(goarch),
	)
}

// AgentGitHubLatestBinaryURL points at the binary on GitHub's Latest release
// (same place install_agent.sh pulls from).
func AgentGitHubLatestBinaryURL(goarch string) string {
	return fmt.Sprintf(
		"https://github.com/%s/%s/releases/latest/download/%s",
		AgentGitHubOwner, AgentGitHubRepo, AgentGitHubAssetName(goarch),
	)
}

// AgentGitHubInstallURL is the VPS one-liner script on the Latest release.
// /releases/latest/download/ follows GitHub's current non-prerelease Latest
// and keeps Add-VPS copy-paste current without baking a tag into every build.
func AgentGitHubInstallURL() string {
	return fmt.Sprintf(
		"https://github.com/%s/%s/releases/latest/download/install_agent.sh",
		AgentGitHubOwner, AgentGitHubRepo,
	)
}

// AgentGitHubReleaseAPI is the GitHub API endpoint for the agentbeta release metadata.
func AgentGitHubReleaseAPI() string {
	return fmt.Sprintf(
		"https://api.github.com/repos/%s/%s/releases/tags/%s",
		AgentGitHubOwner, AgentGitHubRepo, AgentReleaseTag,
	)
}
