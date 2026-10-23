//go:build windows

package main

import (
	"fmt"
	"image"
	"os"
	"syscall"
	"unsafe"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	dbghelp  = syscall.NewLazyDLL("dbghelp.dll")

	pEnumWindows              = user32.NewProc("EnumWindows")
	pEnumChildWindows         = user32.NewProc("EnumChildWindows")
	pGetWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
	pIsWindowVisible          = user32.NewProc("IsWindowVisible")
	pGetClassNameW            = user32.NewProc("GetClassNameW")
	pInternalGetWindowText    = user32.NewProc("InternalGetWindowText")
	pSetWindowPos             = user32.NewProc("SetWindowPos")
	pGetClientRect            = user32.NewProc("GetClientRect")
	pGetWindowRect            = user32.NewProc("GetWindowRect")
	pClientToScreen           = user32.NewProc("ClientToScreen")
	pGetDC                    = user32.NewProc("GetDC")
	pReleaseDC                = user32.NewProc("ReleaseDC")
	pPrintWindow              = user32.NewProc("PrintWindow")
	pPostMessageW             = user32.NewProc("PostMessageW")

	pCreateCompatibleDC     = gdi32.NewProc("CreateCompatibleDC")
	pCreateCompatibleBitmap = gdi32.NewProc("CreateCompatibleBitmap")
	pSelectObject           = gdi32.NewProc("SelectObject")
	pDeleteObject           = gdi32.NewProc("DeleteObject")
	pDeleteDC               = gdi32.NewProc("DeleteDC")
	pBitBlt                 = gdi32.NewProc("BitBlt")
	pGetDIBits              = gdi32.NewProc("GetDIBits")

	pOpenProcess        = kernel32.NewProc("OpenProcess")
	pMiniDumpWriteDump  = dbghelp.NewProc("MiniDumpWriteDump")
)

type hwnd uintptr

type rect struct{ Left, Top, Right, Bottom int32 }

type window struct {
	H     hwnd
	Class string
	Title string
	Rect  rect
}

func windowsOf(pid int) []window {
	var out []window
	cb := syscall.NewCallback(func(h hwnd, _ uintptr) uintptr {
		var wpid uint32
		pGetWindowThreadProcessId.Call(uintptr(h), uintptr(unsafe.Pointer(&wpid)))
		if int(wpid) != pid {
			return 1
		}
		if v, _, _ := pIsWindowVisible.Call(uintptr(h)); v == 0 {
			return 1
		}
		w := window{H: h, Class: className(h), Title: windowText(h)}
		pGetWindowRect.Call(uintptr(h), uintptr(unsafe.Pointer(&w.Rect)))
		out = append(out, w)
		return 1
	})
	pEnumWindows.Call(cb, 0)
	return out
}

// mainWindow returns the CryENGINE render window of the process.
func mainWindow(pid int) (window, bool) {
	for _, w := range windowsOf(pid) {
		if w.Class == "CryENGINE" {
			return w, true
		}
	}
	return window{}, false
}

// dialogs returns standard dialog boxes (crash/error message boxes) of the process.
func dialogs(pid int) []window {
	var out []window
	for _, w := range windowsOf(pid) {
		if w.Class == "#32770" {
			out = append(out, w)
		}
	}
	return out
}

// dialogText collects the text of a dialog's child controls.
func dialogText(h hwnd) string {
	s := ""
	cb := syscall.NewCallback(func(c hwnd, _ uintptr) uintptr {
		if t := windowText(c); t != "" {
			s += "[" + className(c) + "] " + t + "\n"
		}
		return 1
	})
	pEnumChildWindows.Call(uintptr(h), cb, 0)
	return s
}

func className(h hwnd) string {
	buf := make([]uint16, 256)
	pGetClassNameW.Call(uintptr(h), uintptr(unsafe.Pointer(&buf[0])), 256)
	return syscall.UTF16ToString(buf)
}

func windowText(h hwnd) string {
	buf := make([]uint16, 1024)
	// InternalGetWindowText does not send WM_GETTEXT, so it cannot block on a hung game.
	pInternalGetWindowText.Call(uintptr(h), uintptr(unsafe.Pointer(&buf[0])), 1024)
	return syscall.UTF16ToString(buf)
}

func moveWindow(h hwnd, x, y int) {
	const swpNoSize, swpNoZOrder, swpNoActivate = 0x1, 0x4, 0x10
	pSetWindowPos.Call(uintptr(h), 0, uintptr(x), uintptr(y), 0, 0, swpNoSize|swpNoZOrder|swpNoActivate)
}

func closeWindow(h hwnd) {
	const wmClose = 0x10
	pPostMessageW.Call(uintptr(h), wmClose, 0, 0)
}

// capture grabs the client area. PrintWindow with PW_RENDERFULLCONTENT works for
// occluded D3D windows on Win8.1+; if it yields a black frame we fall back to the screen.
func capture(h hwnd) (*image.RGBA, error) {
	var rc rect
	pGetClientRect.Call(uintptr(h), uintptr(unsafe.Pointer(&rc)))
	w, ht := int(rc.Right-rc.Left), int(rc.Bottom-rc.Top)
	if w <= 0 || ht <= 0 {
		return nil, fmt.Errorf("empty client rect")
	}
	img, err := grab(h, w, ht, false)
	if err == nil && !isBlack(img) {
		return img, nil
	}
	return grab(h, w, ht, true)
}

func grab(h hwnd, w, ht int, fromScreen bool) (*image.RGBA, error) {
	srcWnd := uintptr(h)
	if fromScreen {
		srcWnd = 0
	}
	hdc, _, _ := pGetDC.Call(srcWnd)
	if hdc == 0 {
		return nil, fmt.Errorf("GetDC failed")
	}
	defer pReleaseDC.Call(srcWnd, hdc)
	mem, _, _ := pCreateCompatibleDC.Call(hdc)
	defer pDeleteDC.Call(mem)
	bmp, _, _ := pCreateCompatibleBitmap.Call(hdc, uintptr(w), uintptr(ht))
	defer pDeleteObject.Call(bmp)
	old, _, _ := pSelectObject.Call(mem, bmp)

	if fromScreen {
		var pt struct{ X, Y int32 }
		pClientToScreen.Call(uintptr(h), uintptr(unsafe.Pointer(&pt)))
		const srccopy = 0x00CC0020
		pBitBlt.Call(mem, 0, 0, uintptr(w), uintptr(ht), hdc, uintptr(pt.X), uintptr(pt.Y), srccopy)
	} else {
		const pwClientOnly, pwRenderFullContent = 1, 2
		pPrintWindow.Call(uintptr(h), mem, pwClientOnly|pwRenderFullContent)
	}
	pSelectObject.Call(mem, old)

	type bitmapInfoHeader struct {
		Size                         uint32
		Width, Height                int32
		Planes, BitCount             uint16
		Compression, SizeImage       uint32
		XPelsPerMeter, YPelsPerMeter int32
		ClrUsed, ClrImportant        uint32
	}
	bi := bitmapInfoHeader{Width: int32(w), Height: -int32(ht), Planes: 1, BitCount: 32}
	bi.Size = uint32(unsafe.Sizeof(bi))
	img := image.NewRGBA(image.Rect(0, 0, w, ht))
	r, _, _ := pGetDIBits.Call(mem, bmp, 0, uintptr(ht), uintptr(unsafe.Pointer(&img.Pix[0])), uintptr(unsafe.Pointer(&bi)), 0)
	if r == 0 {
		return nil, fmt.Errorf("GetDIBits failed")
	}
	for i := 0; i < len(img.Pix); i += 4 { // BGRA -> RGBA
		img.Pix[i], img.Pix[i+2] = img.Pix[i+2], img.Pix[i]
		img.Pix[i+3] = 255
	}
	return img, nil
}

func isBlack(img *image.RGBA) bool {
	for i := 0; i < len(img.Pix); i += 4 * 97 {
		if img.Pix[i] > 8 || img.Pix[i+1] > 8 || img.Pix[i+2] > 8 {
			return false
		}
	}
	return true
}

// writeMinidump dumps a (32-bit) game process. The harness is built for GOARCH=386
// so the dump has the native x86 view.
func writeMinidump(pid int, path string) error {
	const processAllAccess = 0x1F0FFF
	hp, _, err := pOpenProcess.Call(processAllAccess, 0, uintptr(pid))
	if hp == 0 {
		return fmt.Errorf("OpenProcess: %v", err)
	}
	defer syscall.CloseHandle(syscall.Handle(hp))
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	// MiniDumpWithDataSegs | MiniDumpWithHandleData | MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithThreadInfo
	const dumpType = 0x1 | 0x4 | 0x40 | 0x1000
	r, _, err := pMiniDumpWriteDump.Call(hp, uintptr(pid), f.Fd(), dumpType, 0, 0, 0)
	if r == 0 {
		return fmt.Errorf("MiniDumpWriteDump: %v", err)
	}
	return nil
}

var (
	ntdll                = syscall.NewLazyDLL("ntdll.dll")
	pVirtualAllocEx      = kernel32.NewProc("VirtualAllocEx")
	pWriteProcessMemory  = kernel32.NewProc("WriteProcessMemory")
	pCreateRemoteThread  = kernel32.NewProc("CreateRemoteThread")
	pWaitForSingleObject = kernel32.NewProc("WaitForSingleObject")
	pGetExitCodeThread   = kernel32.NewProc("GetExitCodeThread")
	pLoadLibraryA        = kernel32.NewProc("LoadLibraryA")
	pNtResumeProcess     = ntdll.NewProc("NtResumeProcess")
)

// injectDLL loads a DLL into a (suspended) 32-bit process with a remote LoadLibraryA.
// The harness is x86 too, so kernel32's LoadLibraryA has the same address there.
func injectDLL(pid int, path string) error {
	const processAllAccess, memCommitReserve, pageReadWrite = 0x1F0FFF, 0x3000, 0x04
	hp, _, err := pOpenProcess.Call(processAllAccess, 0, uintptr(pid))
	if hp == 0 {
		return fmt.Errorf("OpenProcess: %v", err)
	}
	defer syscall.CloseHandle(syscall.Handle(hp))
	b := append([]byte(path), 0)
	mem, _, err := pVirtualAllocEx.Call(hp, 0, uintptr(len(b)), memCommitReserve, pageReadWrite)
	if mem == 0 {
		return fmt.Errorf("VirtualAllocEx: %v", err)
	}
	if r, _, err := pWriteProcessMemory.Call(hp, mem, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)), 0); r == 0 {
		return fmt.Errorf("WriteProcessMemory: %v", err)
	}
	if err := pLoadLibraryA.Find(); err != nil {
		return err
	}
	th, _, err := pCreateRemoteThread.Call(hp, 0, 0, pLoadLibraryA.Addr(), mem, 0, 0)
	if th == 0 {
		return fmt.Errorf("CreateRemoteThread: %v", err)
	}
	defer syscall.CloseHandle(syscall.Handle(th))
	pWaitForSingleObject.Call(th, 15000)
	var mod uint32
	pGetExitCodeThread.Call(th, uintptr(unsafe.Pointer(&mod)))
	if mod == 0 {
		return fmt.Errorf("LoadLibraryA(%s) returned NULL", path)
	}
	return nil
}

func resumeProcess(pid int) error {
	const processSuspendResume = 0x0800
	hp, _, err := pOpenProcess.Call(processSuspendResume, 0, uintptr(pid))
	if hp == 0 {
		return fmt.Errorf("OpenProcess: %v", err)
	}
	defer syscall.CloseHandle(syscall.Handle(hp))
	if r, _, _ := pNtResumeProcess.Call(hp); r != 0 {
		return fmt.Errorf("NtResumeProcess: 0x%x", r)
	}
	return nil
}
