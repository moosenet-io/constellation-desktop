//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Windows node: WSL2 distro "moosenet-builder2" + the per-minute Controller.ps1 scheduled task (the reconciler).
// The tray lives in the node folder (Documents\Codex\moosenet-builder) next to Controller.ps1.
type winPlatform struct{ root string }

const distro = "moosenet-builder2"

func newPlatform() Platform {
	root := exeDir()
	if _, err := os.Stat(filepath.Join(root, "Controller.ps1")); err != nil {
		if home, e := os.UserHomeDir(); e == nil {
			root = filepath.Join(home, "Documents", "Codex", "moosenet-builder")
		}
	}
	return &winPlatform{root: root}
}

func (w *winPlatform) Root() string         { return w.root }
func (w *winPlatform) ControlDir() string   { return filepath.Join(w.root, "ops", "control") }
func (w *winPlatform) LogDir() string       { return filepath.Join(w.root, "ops", "logs") }
func (w *winPlatform) HasOpsRunner() bool   { return true }
func (w *winPlatform) CapChoices() []string { return []string{"12/32", "16/48", "20/64"} }
func (w *winPlatform) AssetName() string    { return "constellation-desktop_windows_amd64.exe" }

func hidden(name string, args ...string) *exec.Cmd {
	c := exec.Command(name, args...)
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	return c
}
func out(name string, args ...string) string {
	b, _ := hidden(name, args...).Output()
	return strings.ReplaceAll(string(b), "\x00", "")
}

func (w *winPlatform) Reconcile() {
	// Controller.ps1 owns runner, builder, Tdarr and cap changes; run it now instead of waiting for its minute.
	_ = hidden("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(w.root, "Controller.ps1")).Start()
}

func (w *winPlatform) Status() state {
	var s state
	for _, l := range strings.Split(out("wsl.exe", "-l", "--running", "-q"), "\n") {
		if strings.TrimSpace(l) == distro {
			s.VMRunning = true
		}
	}
	if s.VMRunning {
		s.WatcherRunning = strings.TrimSpace(out("wsl.exe", "-d", distro, "-u", "root", "--", "pgrep", "-f", "moosenet-watcher.sh")) != ""
	}
	if m, _ := filepath.Glob(filepath.Join(w.root, "exchange", "inbox", "*.taken")); len(m) > 0 {
		s.Job = strings.TrimSuffix(filepath.Base(m[0]), ".taken")
	}
	s.TdarrRunning = processRunning("tdarr_node.exe")
	s.Caps = w.readCaps()
	s.Net = tailscaleState(tailscaleExe())
	return s
}

func (w *winPlatform) wslconfig() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".wslconfig")
}
func (w *winPlatform) readCaps() string {
	t, g := "?", "?"
	b, _ := os.ReadFile(w.wslconfig())
	for _, l := range strings.Split(string(b), "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "processors=") {
			t = strings.TrimPrefix(l, "processors=")
		}
		if strings.HasPrefix(l, "memory=") {
			g = strings.TrimSuffix(strings.TrimPrefix(l, "memory="), "GB")
		}
	}
	return t + "/" + g
}
func (w *winPlatform) SetCaps(c string) string {
	parts := strings.SplitN(c, "/", 2)
	if b, err := os.ReadFile(w.wslconfig()); err == nil {
		_ = os.WriteFile(w.wslconfig()+".bak", b, 0o644)
	}
	body := fmt.Sprintf("[wsl2]\r\nprocessors=%s\r\nmemory=%sGB\r\nswap=8GB\r\n", parts[0], parts[1])
	if err := os.WriteFile(w.wslconfig(), []byte(body), 0o644); err != nil {
		return "Could not write .wslconfig: " + err.Error()
	}
	touch("APPLY_WSLCONFIG")
	return "Resources set to " + capLabel(c) + "; applied when no build is running"
}

// GameRunning: any process whose image path is inside a Steam library (or named in game_names), minus ignores.
func (w *winPlatform) GameRunning(names, ignore []string) bool {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		name := strings.ToLower(windows.UTF16ToString(e.ExeFile[:]))
		path := strings.ToLower(imagePath(e.ProcessID))
		skip := false
		for _, i := range ignore {
			if name == i || strings.Contains(path, `\`+i+`\`) {
				skip = true
			}
		}
		if skip {
			continue
		}
		if strings.Contains(path, `\steamapps\common\`) {
			return true
		}
		for _, n := range names {
			if name == n {
				return true
			}
		}
	}
	return false
}

func imagePath(pid uint32) string {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, 1024)
	n := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &n); err != nil {
		return ""
	}
	return windows.UTF16ToString(buf[:n])
}

func processRunning(exe string) bool {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		if strings.EqualFold(windows.UTF16ToString(e.ExeFile[:]), exe) {
			return true
		}
	}
	return false
}

func tailscaleExe() string { return `C:\Program Files\Tailscale\tailscale.exe` }
func tailscaleState(exe string) string {
	if _, err := os.Stat(exe); err != nil {
		return "not installed"
	}
	o := out(exe, "status", "--peers=false")
	switch {
	case strings.Contains(o, "Logged out"), strings.Contains(o, "NeedsLogin"):
		return "logged out"
	case strings.Contains(o, "stopped"):
		return "disconnected"
	}
	if f := strings.Fields(o); len(f) > 0 {
		return "connected (" + f[0] + ")"
	}
	return "unknown"
}
func (w *winPlatform) Tailscale(verb string) string {
	if _, err := os.Stat(tailscaleExe()); err != nil {
		return "Tailscale is not installed (Network > Get Tailscale)"
	}
	if err := hidden(tailscaleExe(), verb).Run(); err != nil {
		return "Tailscale " + verb + " failed: " + err.Error()
	}
	return "Tailscale " + verb + " done"
}
func (w *winPlatform) OpenWireGuard() {
	exe := `C:\Program Files\WireGuard\wireguard.exe`
	if _, err := os.Stat(exe); err == nil {
		_ = exec.Command(exe).Start()
		return
	}
	w.Open("https://www.wireguard.com/install/")
}
func (w *winPlatform) SetJobServer(url string) string {
	setSetting("job_server", url)
	c := hidden("wsl.exe", "-d", distro, "-u", "root", "--", "sh", "-c", "cat > /etc/moosenet-target5.conf; sync")
	c.Stdin = strings.NewReader("READY_BASE=" + url + "\nPC_NAME=wsl-builder\n")
	if err := c.Run(); err != nil {
		return "Could not set job server: " + err.Error()
	}
	return "Job server set to " + url + " (used from the watcher's next start)"
}
func (w *winPlatform) Open(t string) { _ = exec.Command("explorer.exe", t).Start() }

// Notify: a Windows toast via PowerShell (no extra modules), falling back to the log only.
func (w *winPlatform) Notify(title, msg string) {
	esc := func(s string) string {
		return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "'", "''").Replace(s)
	}
	ps := `[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null;` +
		`$x = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]::new();` +
		`$x.LoadXml('<toast><visual><binding template="ToastGeneric"><text>` + esc(title) + `</text><text>` + esc(msg) + `</text></binding></visual></toast>');` +
		`[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new($x))`
	_ = hidden("powershell", "-NoProfile", "-Command", ps).Start()
}

func (w *winPlatform) ReplaceSelf(bin []byte) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	old := exe + ".old"
	_ = os.Remove(old)
	if err := os.Rename(exe, old); err != nil {
		return err
	}
	if err := os.WriteFile(exe, bin, 0o755); err != nil {
		_ = os.Rename(old, exe)
		return err
	}
	if err := exec.Command(exe).Start(); err != nil {
		return err
	}
	go func() { os.Exit(0) }()
	return nil
}
