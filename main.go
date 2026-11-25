// Constellation Desktop -- system-tray control for a MooseNet build/transcode node (Windows + macOS).
//
// The tray is a thin UI over "switch files" in a control directory. A reconciler (the Windows scheduled
// task Controller.ps1, or the tray's own loop on macOS) makes reality match them:
//
//	BUILDER_ON   build watcher should run          GAME_MODE   stop builds + transcodes now
//	TDARR_ON     Tdarr node should run             RUNNER_OFF  Claude ops runner stopped (Windows)
//	APPLY_VMCONFIG  apply new CPU/RAM caps when idle  CANCEL      cancel the running ops script
//
// Claude/Chord flip the same files remotely, so the tray, the operator and the fleet never disagree.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"fyne.io/systray"
)

var version = "dev" // set by -ldflags at release time

type state struct {
	Game, Builder, Tdarr, RunnerOff, AutoGame bool
	VMRunning, WatcherRunning, TdarrRunning   bool
	Job, Caps, Net, Pending                   string
}

var (
	p        Platform
	mStatus  *systray.MenuItem
	mJob     *systray.MenuItem
	mGame    *systray.MenuItem
	mAuto    *systray.MenuItem
	mBuild   *systray.MenuItem
	mTdarr   *systray.MenuItem
	mRunner  *systray.MenuItem
	mCaps    = map[string]*systray.MenuItem{}
	mNetStat *systray.MenuItem
	mUpdate  *systray.MenuItem
	lastIcon string
	autoSet  bool
)

func main() {
	p = newPlatform()
	if err := os.MkdirAll(p.ControlDir(), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	systray.Run(onReady, func() {})
}

func onReady() {
	systray.SetTooltip("MooseNet Constellation Desktop")
	setIcon("starting")
	mStatus = systray.AddMenuItem("Status: ...", "")
	mStatus.Disable()
	mJob = systray.AddMenuItem("Job: none", "")
	mJob.Disable()
	systray.AddSeparator()

	mGame = systray.AddMenuItemCheckbox("Game Mode (pause builds + transcodes)", "", false)
	mAuto = systray.AddMenuItemCheckbox("Auto Game Mode when a game is running", "", true)
	mBuild = systray.AddMenuItemCheckbox("Builder enabled", "", false)
	mTdarr = systray.AddMenuItemCheckbox("Tdarr transcoding enabled", "", false)
	if p.HasOpsRunner() {
		mRunner = systray.AddMenuItemCheckbox("Claude ops runner enabled", "", true)
	}
	mCancel := systray.AddMenuItem("Cancel the running ops script", "")
	if !p.HasOpsRunner() {
		mCancel.Hide()
	}
	systray.AddSeparator()

	mRes := systray.AddMenuItem("Build resources", "")
	for _, c := range p.CapChoices() {
		mCaps[c] = mRes.AddSubMenuItemCheckbox(capLabel(c), "", false)
	}
	mNet := systray.AddMenuItem("Network", "")
	mNetStat = mNet.AddSubMenuItem("Tailscale: ...", "")
	mNetStat.Disable()
	mTsUp := mNet.AddSubMenuItem("Tailscale: connect", "")
	mTsDown := mNet.AddSubMenuItem("Tailscale: disconnect", "")
	mTsGet := mNet.AddSubMenuItem("Get Tailscale...", "")
	mWg := mNet.AddSubMenuItem("Open WireGuard", "")
	mJobLan := mNet.AddSubMenuItem("Job server: reset to install default", "")
	mJobTest := mNet.AddSubMenuItem("Test job server connection", "")
	systray.AddSeparator()

	mLogs := systray.AddMenuItem("Open logs folder", "")
	mFolder := systray.AddMenuItem("Open node folder", "")
	mUpdate = systray.AddMenuItem("Check for updates (v"+version+")", "")
	mQuit := systray.AddMenuItem("Exit tray (node keeps its state)", "")

	go func() {
		for {
			select {
			case <-mGame.ClickedCh:
				toggle("GAME_MODE")
				autoSet = false
			case <-mAuto.ClickedCh:
				setSetting("auto_game", boolStr(!getSetting("auto_game", "1").is1()))
			case <-mBuild.ClickedCh:
				toggle("BUILDER_ON")
			case <-mTdarr.ClickedCh:
				toggle("TDARR_ON")
			case <-runnerCh():
				toggle("RUNNER_OFF")
			case <-mCancel.ClickedCh:
				touch("CANCEL")
				notify("Cancel requested")
			case <-mTsUp.ClickedCh:
				notify(p.Tailscale("up"))
			case <-mTsDown.ClickedCh:
				notify(p.Tailscale("down"))
			case <-mTsGet.ClickedCh:
				p.Open("https://tailscale.com/download")
			case <-mWg.ClickedCh:
				p.OpenWireGuard()
			case <-mJobLan.ClickedCh:
				if d := getSetting("job_server_default", "").s; d != "" {
					notify(p.SetJobServer(d))
				} else {
					notify("No install default job server is set")
				}
			case <-mJobTest.ClickedCh:
				notify(testURL(getSetting("job_server", getSetting("job_server_default", "").s).s))
			case <-mLogs.ClickedCh:
				p.Open(p.LogDir())
			case <-mFolder.ClickedCh:
				p.Open(p.Root())
			case <-mUpdate.ClickedCh:
				go func() { notify(checkUpdate(true)) }()
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
			refresh()
		}
	}()
	for c, mi := range mCaps {
		c, mi := c, mi
		go func() {
			for range mi.ClickedCh {
				notify(p.SetCaps(c))
				touch("APPLY_VMCONFIG")
				p.Reconcile()
				refresh()
			}
		}()
	}
	go func() {
		t := time.NewTicker(10 * time.Second)
		for ; ; <-t.C {
			autoGame()
			if !p.HasOpsRunner() { // macOS: the tray is the reconciler; Windows has the per-minute controller task
				p.Reconcile()
			}
			refresh()
		}
	}()
	go func() {
		for {
			if getSetting("auto_update", "1").is1() {
				if msg := checkUpdate(false); msg != "" {
					notify(msg)
				}
			}
			time.Sleep(6 * time.Hour)
		}
	}()
}

func runnerCh() <-chan struct{} {
	if mRunner == nil {
		return nil
	}
	return mRunner.ClickedCh
}

func autoGame() {
	if !getSetting("auto_game", "1").is1() {
		return
	}
	playing := p.GameRunning(splitList(getSetting("game_names", "").s), splitList(getSetting("game_ignore", defaultIgnore).s))
	game := has("GAME_MODE")
	if playing && !game {
		touch("GAME_MODE")
		autoSet = true
		p.Reconcile()
		notify("Game detected: builds and transcodes paused")
	} else if !playing && game && autoSet {
		remove("GAME_MODE")
		autoSet = false
		p.Reconcile()
		notify("Game closed: work may resume")
	}
}

const defaultIgnore = "wallpaper_engine,wallpaper32.exe,wallpaper64.exe,webwallpaper32.exe,steamwebhelper.exe,steamvr"

func refresh() {
	s := p.Status()
	s.Game, s.Builder, s.Tdarr, s.RunnerOff = has("GAME_MODE"), has("BUILDER_ON"), has("TDARR_ON"), has("RUNNER_OFF")
	st, label := "off", "Builder off"
	switch {
	case s.Game:
		st, label = "game", "Game Mode (paused)"
	case s.Job != "":
		st, label = "building", "Building"
	case s.TdarrRunning:
		st, label = "building", "Transcoding"
	case s.Builder && s.WatcherRunning:
		st, label = "idle", "Idle, waiting for jobs"
	case s.Builder || s.Tdarr:
		st, label = "starting", "Starting..."
	}
	mStatus.SetTitle("Status: " + label)
	job := s.Job
	if job == "" {
		job = "none"
	}
	extra := ""
	if p.HasOpsRunner() {
		extra = "   |   Runner: " + onOff(!s.RunnerOff)
	}
	mJob.SetTitle("Job: " + job + "   |   Tdarr: " + onOff(s.TdarrRunning) + extra)
	check(mGame, s.Game)
	check(mAuto, getSetting("auto_game", "1").is1())
	check(mBuild, s.Builder)
	check(mTdarr, s.Tdarr)
	if mRunner != nil {
		check(mRunner, !s.RunnerOff)
	}
	for c, mi := range mCaps {
		check(mi, c == s.Caps)
	}
	mNetStat.SetTitle("Tailscale: " + s.Net)
	if st != lastIcon {
		setIcon(st)
		lastIcon = st
	}
	systray.SetTooltip("MooseNet node: " + label)
}

// ---------- control files
func ctl(f string) string { return filepath.Join(p.ControlDir(), f) }
func has(f string) bool   { _, err := os.Stat(ctl(f)); return err == nil }
func touch(f string)      { _ = os.WriteFile(ctl(f), []byte(time.Now().Format(time.RFC3339)), 0o644) }
func remove(f string)     { _ = os.Remove(ctl(f)) }
func toggle(f string) {
	if has(f) {
		remove(f)
	} else {
		touch(f)
	}
	p.Reconcile()
}

type setting struct{ s string }

func (v setting) is1() bool { return v.s == "1" }

func settingsPath() string { return ctl("tray-settings.ini") }
func getSetting(k, d string) setting {
	b, err := os.ReadFile(settingsPath())
	if err != nil {
		return setting{d}
	}
	for _, l := range strings.Split(string(b), "\n") {
		l = strings.TrimRight(l, "\r")
		if strings.HasPrefix(l, k+"=") {
			return setting{strings.TrimPrefix(l, k+"=")}
		}
	}
	return setting{d}
}
func setSetting(k, v string) {
	b, _ := os.ReadFile(settingsPath())
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		l = strings.TrimRight(l, "\r")
		if l != "" && !strings.HasPrefix(l, k+"=") {
			out = append(out, l)
		}
	}
	out = append(out, k+"="+v)
	_ = os.WriteFile(settingsPath(), []byte(strings.Join(out, "\n")+"\n"), 0o644)
}

// ---------- small helpers
func check(m *systray.MenuItem, on bool) {
	if on {
		m.Check()
	} else {
		m.Uncheck()
	}
}
func onOff(b bool) string {
	if b {
		return "on"
	}
	return "off"
}
func boolStr(b bool) string {
	if b {
		return "1"
	}
	return "0"
}
func capLabel(c string) string {
	parts := strings.SplitN(c, "/", 2)
	return parts[0] + " threads / " + parts[1] + " GB"
}
func splitList(s string) []string {
	var out []string
	for _, x := range strings.Split(s, ",") {
		if x = strings.ToLower(strings.TrimSpace(x)); x != "" {
			out = append(out, x)
		}
	}
	return out
}
func notify(msg string) {
	if msg == "" {
		return
	}
	logLine("notify: " + msg)
	p.Notify("MooseNet node", msg)
}
func logLine(s string) {
	_ = os.MkdirAll(p.LogDir(), 0o755)
	f, err := os.OpenFile(filepath.Join(p.LogDir(), "tray.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err == nil {
		fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339), s)
		f.Close()
	}
}
