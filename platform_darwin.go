//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// macOS node: a Lima VM "moosenet-builder" running the same golden bootstrap + watcher as the Windows WSL node.
// Intel Macs run it natively (x86_64). Apple Silicon runs an x86_64 VM under emulation so build/test results match
// the door (slower, roughly 3-5x). The tray itself is the reconciler on macOS (no scheduled task needed);
// it is started at login by a LaunchAgent (see mac/install.sh).
type macPlatform struct{ root string }

const limaVM = "moosenet-builder"

func newPlatform() Platform {
	h, _ := os.UserHomeDir()
	return &macPlatform{root: filepath.Join(h, "Library", "Application Support", "MooseNet", "node")}
}

func (m *macPlatform) Root() string       { return m.root }
func (m *macPlatform) ControlDir() string { return filepath.Join(m.root, "control") }
func (m *macPlatform) LogDir() string     { return filepath.Join(m.root, "logs") }
func (m *macPlatform) HasOpsRunner() bool { return false }
func (m *macPlatform) AssetName() string {
	return "constellation-desktop_darwin_" + runtime.GOARCH + ".bin"
}
func (m *macPlatform) CapChoices() []string {
	n := runtime.NumCPU()
	mid, hi := n/2, n-2
	if mid < 2 {
		mid = 2
	}
	if hi < mid {
		hi = mid
	}
	return []string{strconv.Itoa(mid) + "/16", strconv.Itoa(hi) + "/32"}
}

func run(name string, args ...string) (string, error) {
	b, err := exec.Command(name, args...).CombinedOutput()
	return string(b), err
}

func limactl() string {
	for _, p := range []string{"/opt/homebrew/bin/limactl", "/usr/local/bin/limactl"} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return "limactl"
}

func (m *macPlatform) vmStatus() string {
	o, err := run(limactl(), "list", limaVM, "--format", "{{.Status}}")
	if err != nil {
		return "missing"
	}
	return strings.TrimSpace(o)
}

func (m *macPlatform) Status() state {
	var s state
	st := m.vmStatus()
	s.VMRunning = st == "Running"
	if s.VMRunning {
		o, _ := run(limactl(), "shell", limaVM, "pgrep", "-f", "moosenet-watcher.sh")
		s.WatcherRunning = strings.TrimSpace(o) != ""
	}
	if f, _ := filepath.Glob(filepath.Join(m.root, "exchange", "inbox", "*.taken")); len(f) > 0 {
		s.Job = strings.TrimSuffix(filepath.Base(f[0]), ".taken")
	}
	o, _ := run("pgrep", "-f", "Tdarr_Node")
	s.TdarrRunning = strings.TrimSpace(o) != ""
	s.Caps = m.readCaps()
	s.Net = macTailscale()
	if st == "missing" && has("BUILDER_ON") {
		s.Job = "builder VM not set up (run mac/install.sh)"
	}
	return s
}

// Reconcile makes the VM, watcher and Tdarr node match the control files (same rules as Windows Controller.ps1).
func (m *macPlatform) Reconcile() {
	game := has("GAME_MODE")
	wantBuild := has("BUILDER_ON") && !game
	wantTdarr := has("TDARR_ON") && !game
	s := m.Status()
	busy := s.Job != "" && !strings.Contains(s.Job, "not set up")

	if has("APPLY_VMCONFIG") && !busy && m.vmStatus() != "missing" {
		if s.VMRunning {
			m.stopBuilder("apply caps")
		}
		c := strings.SplitN(getSetting("caps", m.CapChoices()[0]).s, "/", 2)
		if has("FULL_MODE") {
			c = strings.SplitN(fullCaps(), "/", 2)
		}
		if out, err := run(limactl(), "edit", limaVM, "--cpus", c[0], "--memory", c[1]); err != nil {
			logLine("caps apply failed: " + out)
		}
		remove("APPLY_VMCONFIG")
		s.VMRunning, s.WatcherRunning = false, false
	}
	if !wantBuild && s.VMRunning {
		m.stopBuilder(map[bool]string{true: "GAME_MODE", false: "BUILDER_ON absent"}[game])
	}
	if wantBuild && !s.WatcherRunning && m.vmStatus() != "missing" {
		if !s.VMRunning {
			if out, err := run(limactl(), "start", limaVM); err != nil {
				logLine("vm start failed: " + out)
				return
			}
		}
		ex := filepath.Join(m.root, "exchange")
		_ = os.MkdirAll(filepath.Join(ex, "inbox"), 0o755)
		cmd := exec.Command(limactl(), "shell", limaVM, "sudo", "/opt/moosenet-watcher.sh", ex)
		lf, _ := os.OpenFile(filepath.Join(m.LogDir(), "builder-watcher.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		cmd.Stdout, cmd.Stderr = lf, lf
		if err := cmd.Start(); err == nil {
			logLine("builder started")
			go func() { _ = cmd.Wait(); lf.Close() }()
		}
	}
	tdarr := filepath.Join(m.root, "tdarr", "Tdarr_Node", "Tdarr_Node")
	if wantTdarr && !s.TdarrRunning {
		if _, err := os.Stat(tdarr); err == nil {
			c := exec.Command(tdarr)
			c.Dir = filepath.Dir(tdarr)
			_ = c.Start()
			logLine("tdarr node started")
		}
	}
	if !wantTdarr && s.TdarrRunning {
		_, _ = run("pkill", "-f", "Tdarr_Node")
		logLine("tdarr node stopped")
	}
}

func (m *macPlatform) stopBuilder(why string) {
	_, _ = run(limactl(), "shell", limaVM, "sudo", "sh", "-c",
		"touch /x/STOP 2>/dev/null; pkill -TERM -u builder; sleep 3; pkill -KILL -u builder; pkill -f moosenet-watcher; sync")
	_, _ = run(limactl(), "stop", limaVM)
	f, _ := filepath.Glob(filepath.Join(m.root, "exchange", "inbox", "*.taken"))
	for _, t := range f {
		_ = os.Rename(t, strings.TrimSuffix(t, ".taken")+".cancelled")
	}
	logLine("builder stopped (" + why + ")")
}

func (m *macPlatform) readCaps() string { return getSetting("caps", m.CapChoices()[0]).s }

// FullModeChanged: re-apply caps (Full Power or the saved choice) the next time no build runs.
func (m *macPlatform) FullModeChanged() { touch("APPLY_VMCONFIG") }

// fullCaps: every CPU and all RAM but 6 GB (min 8 GB), as "threads/GB".
func fullCaps() string {
	gb := 16
	if o, err := run("sysctl", "-n", "hw.memsize"); err == nil {
		if b, err := strconv.ParseInt(strings.TrimSpace(o), 10, 64); err == nil {
			gb = int(b>>30) - 6
		}
	}
	if gb < 8 {
		gb = 8
	}
	return strconv.Itoa(runtime.NumCPU()) + "/" + strconv.Itoa(gb)
}

func (m *macPlatform) SetCaps(c string) string {
	setSetting("caps", c)
	return "Resources set to " + capLabel(c) + "; applied when no build is running"
}

func (m *macPlatform) GameRunning(names, ignore []string) bool {
	o, _ := run("ps", "-axo", "comm=")
	for _, l := range strings.Split(strings.ToLower(o), "\n") {
		skip := false
		for _, i := range ignore {
			if strings.Contains(l, "/"+i) {
				skip = true
			}
		}
		if skip {
			continue
		}
		if strings.Contains(l, "/steamapps/common/") {
			return true
		}
		for _, n := range names {
			if filepath.Base(l) == n {
				return true
			}
		}
	}
	return false
}

func macTailscale() string {
	for _, p := range []string{"/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"} {
		if _, err := os.Stat(p); err == nil {
			o, _ := run(p, "status", "--peers=false")
			if strings.Contains(o, "stopped") {
				return "disconnected"
			}
			if f := strings.Fields(o); len(f) > 0 && strings.Count(f[0], ".") == 3 {
				return "connected (" + f[0] + ")"
			}
			return "installed"
		}
	}
	return "not installed"
}
func (m *macPlatform) Tailscale(verb string) string {
	if macTailscale() == "not installed" {
		return "Tailscale is not installed (Network > Get Tailscale)"
	}
	if o, err := run("/Applications/Tailscale.app/Contents/MacOS/Tailscale", verb); err != nil {
		return "Tailscale " + verb + " failed: " + strings.TrimSpace(o)
	}
	return "Tailscale " + verb + " done"
}
func (m *macPlatform) OpenWireGuard() {
	if _, err := os.Stat("/Applications/WireGuard.app"); err == nil {
		_, _ = run("open", "-a", "WireGuard")
		return
	}
	m.Open("https://apps.apple.com/app/wireguard/id1451685025")
}
func (m *macPlatform) SetJobServer(url string) string {
	setSetting("job_server", url)
	c := exec.Command(limactl(), "shell", limaVM, "sudo", "sh", "-c", "cat > /etc/moosenet-target5.conf; sync")
	c.Stdin = strings.NewReader(fmt.Sprintf("READY_BASE=%s\nPC_NAME=%s\n", url, getSetting("node_name", "mac-builder").s))
	if out, err := c.CombinedOutput(); err != nil {
		return "Could not set job server: " + strings.TrimSpace(string(out))
	}
	return "Job server set to " + url
}
func (m *macPlatform) Open(t string) { _, _ = run("open", t) }
func (m *macPlatform) Notify(title, msg string) {
	q := func(s string) string { return strings.ReplaceAll(s, `"`, `'`) }
	_, _ = run("osascript", "-e", `display notification "`+q(msg)+`" with title "`+q(title)+`"`)
}
func (m *macPlatform) ReplaceSelf(bin []byte) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	tmp := exe + ".new"
	if err := os.WriteFile(tmp, bin, 0o755); err != nil {
		return err
	}
	if err := os.Rename(tmp, exe); err != nil {
		return err
	}
	if err := exec.Command(exe).Start(); err != nil {
		return err
	}
	go func() { os.Exit(0) }()
	return nil
}
