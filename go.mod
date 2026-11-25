module github.com/moosenet-io/constellation-desktop

go 1.24.7

replace fyne.io/systray => github.com/fyne-io/systray v1.11.0

require (
	fyne.io/systray v1.11.0
	golang.org/x/sys v0.15.0
)

require github.com/godbus/dbus/v5 v5.1.0 // indirect

replace golang.org/x/sys => github.com/golang/sys v0.15.0

replace github.com/godbus/dbus/v5 => github.com/godbus/dbus/v5 v5.1.0
