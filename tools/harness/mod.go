package main

import (
	"archive/zip"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"strings"
)

const modName = "FC1Coop"

// installMod builds Mods/FC1Coop in the game folder from the repo:
// scripts/game/** -> FC1Coop.pak as Scripts/** (mod files override the game per file,
// but only from a pak: sys_PakPriority=1 ignores loose mod files), plus ModDesc.txt.
func installMod(root, gameDir string) error {
	dst := filepath.Join(gameDir, "Mods", modName)
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	desc := "_Title_=\"FC1 Co-op (dev)\"\r\n_Author_=\"fc1-coop\"\r\n_Description_=\"Development build of the FC1 co-op mod.\"\r\n"
	if err := os.WriteFile(filepath.Join(dst, "ModDesc.txt"), []byte(desc), 0o644); err != nil {
		return err
	}
	tmp := filepath.Join(dst, modName+".pak.tmp")
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	zw := zip.NewWriter(f)
	src := filepath.Join(root, "scripts", "game")
	count := 0
	err = filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		// CryPak does not read entries written by zip.Writer.Create (data descriptor,
		// flag bit 3). Write stored entries with CRC and sizes in the local header.
		hdr := &zip.FileHeader{
			Name:               "Scripts/" + filepath.ToSlash(rel),
			Method:             zip.Store,
			CRC32:              crc32.ChecksumIEEE(data),
			CompressedSize64:   uint64(len(data)),
			UncompressedSize64: uint64(len(data)),
			Modified:           info.ModTime(),
		}
		w, err := zw.CreateRaw(hdr)
		if err != nil {
			return err
		}
		_, err = w.Write(data)
		count++
		return err
	})
	if cerr := zw.Close(); err == nil {
		err = cerr
	}
	f.Close()
	if err != nil {
		os.Remove(tmp)
		return err
	}
	pak := filepath.Join(dst, modName+".pak")
	os.Remove(pak)
	if err := os.Rename(tmp, pak); err != nil {
		return err
	}
	fmt.Printf("mod: %s (%d files)\n", pak, count)
	return nil
}

func isOurMod(name string) bool { return strings.EqualFold(name, modName) }
