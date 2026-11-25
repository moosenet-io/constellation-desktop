package main

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"fyne.io/systray"
)

// Platform is everything that differs between Windows (WSL2 builder + Controller.ps1) and macOS (Lima VM).
type Platform interface {
	Root() string
	ControlDir() string
	LogDir() string
	HasOpsRunner() bool
	CapChoices() []string
	SetCaps(c string) string
	Status() state
	Reconcile()
	GameRunning(names, ignore []string) bool
	Tailscale(verb string) string
	OpenWireGuard()
	SetJobServer(url string) string
	Open(target string)
	Notify(title, msg string)
	AssetName() string
	ReplaceSelf(newBin []byte) error
}

//go:embed assets/terminus-32.png
var terminusPNG []byte

func setIcon(st string) {
	c := map[string]color.RGBA{
		"building": {46, 204, 113, 255}, "idle": {52, 152, 219, 255}, "game": {243, 156, 18, 255},
		"starting": {155, 89, 182, 255}, "off": {128, 128, 128, 255},
	}[st]
	base, err := png.Decode(bytes.NewReader(terminusPNG))
	img := image.NewRGBA(image.Rect(0, 0, 32, 32))
	if err == nil {
		draw.Draw(img, img.Bounds(), base, base.Bounds().Min, draw.Over)
	}
	disc(img, 24, 24, 7.5, color.RGBA{20, 20, 20, 255})
	disc(img, 24, 24, 5.5, c)
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	if runtime.GOOS == "windows" {
		systray.SetIcon(pngToICO(buf.Bytes()))
	} else {
		systray.SetIcon(buf.Bytes())
	}
}

func disc(img *image.RGBA, cx, cy, r float64, c color.RGBA) {
	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			dx, dy := float64(x)+0.5-cx, float64(y)+0.5-cy
			if dx*dx+dy*dy <= r*r {
				img.Set(x, y, c)
			}
		}
	}
}

// pngToICO wraps a 32x32 PNG in a single-image ICO container (Windows tray icons must be ICO).
func pngToICO(p []byte) []byte {
	var b bytes.Buffer
	_ = binary.Write(&b, binary.LittleEndian, []uint16{0, 1, 1})
	b.Write([]byte{32, 32, 0, 0})
	_ = binary.Write(&b, binary.LittleEndian, []uint16{1, 32})
	_ = binary.Write(&b, binary.LittleEndian, []uint32{uint32(len(p)), 22})
	b.Write(p)
	return b.Bytes()
}

func testURL(u string) string {
	c := http.Client{Timeout: 5 * time.Second}
	r, err := c.Get(u)
	if err != nil {
		return "Job server unreachable: " + err.Error()
	}
	r.Body.Close()
	return fmt.Sprintf("Job server: HTTP %d", r.StatusCode)
}

// ---------- self-update from GitHub Releases (public repo; no token on the client)
const repo = "moosenet-io/constellation-desktop"

type release struct {
	Tag    string `json:"tag_name"`
	Assets []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

func checkUpdate(manual bool) string {
	c := http.Client{Timeout: 30 * time.Second}
	r, err := c.Get("https://api.github.com/repos/" + repo + "/releases/latest")
	if err != nil {
		return ifManual(manual, "Update check failed: "+err.Error())
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return ifManual(manual, fmt.Sprintf("Update check: HTTP %d", r.StatusCode))
	}
	var rel release
	if err := json.NewDecoder(r.Body).Decode(&rel); err != nil {
		return ifManual(manual, "Update check: bad response")
	}
	if strings.TrimPrefix(rel.Tag, "v") == strings.TrimPrefix(version, "v") || version == "dev" && !manual {
		return ifManual(manual, "Up to date (v"+version+")")
	}
	var binURL, sumURL string
	for _, a := range rel.Assets {
		if a.Name == p.AssetName() {
			binURL = a.URL
		}
		if a.Name == "SHA256SUMS" {
			sumURL = a.URL
		}
	}
	if binURL == "" || sumURL == "" {
		return ifManual(manual, "Release "+rel.Tag+" has no build for this system")
	}
	sums, err := get(sumURL)
	if err != nil {
		return "Update failed: " + err.Error()
	}
	want := ""
	for _, l := range strings.Split(string(sums), "\n") {
		f := strings.Fields(l)
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == p.AssetName() {
			want = f[0]
		}
	}
	bin, err := get(binURL)
	if err != nil {
		return "Update failed: " + err.Error()
	}
	h := sha256.Sum256(bin)
	if want == "" || hex.EncodeToString(h[:]) != strings.ToLower(want) {
		return "Update refused: checksum mismatch for " + rel.Tag
	}
	if err := p.ReplaceSelf(bin); err != nil {
		return "Update failed: " + err.Error()
	}
	return "Updated to " + rel.Tag + " (restarting)"
}

func ifManual(manual bool, s string) string {
	if manual {
		return s
	}
	return ""
}

func get(u string) ([]byte, error) {
	c := http.Client{Timeout: 5 * time.Minute}
	r, err := c.Get(u)
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return nil, fmt.Errorf("HTTP %d", r.StatusCode)
	}
	return io.ReadAll(r.Body)
}

func exeDir() string {
	e, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(e)
}
