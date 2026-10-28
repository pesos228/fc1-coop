package main

import (
	"archive/zip"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"strings"
)



// modSource says where a known mod's files live in the repo.
// FarCryCoop (upstream of this fork, MIT): its mod folder already has Scripts/ and ModDesc.txt.
func modSource(root, name string) (src, prefix, desc string, ok bool) {
	switch strings.ToLower(name) {
	case "farcrycoop":
		dir := filepath.Join(root, "games", "far-cry", "mod", "FarCryCoop")
		return filepath.Join(dir, "Scripts"), "Scripts/", filepath.Join(dir, "ModDesc.txt"), true
	}
	return "", "", "", false
}

// installMod builds Mods/<name>/<name>.pak in the game folder. Mod files override the
// game per file, but only from a pak: sys_PakPriority=1 ignores loose mod files.
func installMod(root, gameDir, name string) error {
	src, prefix, descFile, ok := modSource(root, name)
	if !ok {
		return nil // a mod installed by other means
	}
	dst := filepath.Join(gameDir, "Mods", name)
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	desc := []byte("_Title_=\"FC1 Co-op (dev)\"\r\n_Author_=\"fc1-coop\"\r\n_Description_=\"Development build of the FC1 co-op mod.\"\r\n")
	if descFile != "" {
		b, err := os.ReadFile(descFile)
		if err != nil {
			return err
		}
		desc = b
	}
	if err := os.WriteFile(filepath.Join(dst, "ModDesc.txt"), desc, 0o644); err != nil {
		return err
	}
	tmp := filepath.Join(dst, name+".pak.tmp")
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	zw := zip.NewWriter(f)
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
			Name:               prefix + filepath.ToSlash(rel),
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
	pak := filepath.Join(dst, name+".pak")
	os.Remove(pak)
	if err := os.Rename(tmp, pak); err != nil {
		return err
	}
	fmt.Printf("mod: %s (%d files)\n", pak, count)
	return nil
}
