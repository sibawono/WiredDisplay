# Sesi uji perangkat keras gabungan (Phase 0/1)

Satu sesi untuk semua eksperimen yang ditunda (D-012). Ikuti berurutan; setiap
bagian menulis bukti ke `docs/evidence/` atau ke log host. Perkiraan waktu: 30–45 menit.

Perintah dijalankan dari folder proyek di Terminal Mac. Hasilnya dianalisis
oleh Claude sesudahnya; Anda cukup menjalankan langkah dan mencatat jawaban
"ya/tidak" di kolom **Hasil**.

## 0. Persiapan dan jalur pemulihan

- Mac ini tidak punya monitor fisik; layar satu-satunya adalah Sidecar di iPad.
  WiredDisplay **tidak pernah** mengubah display utama atau mirroring (D-015):
  ia hanya menambah satu display.
- Jika layar Mac hilang: tunggu ±10 detik. Kalau tidak kembali, jalankan dari
  mana pun yang masih bisa mengetik ke Mac (atau minta Claude):

```bash
pkill -x WiredDisplayHost
```

```bash
osascript -l JavaScript "/Applications/Sidecar Travel.app/Contents/Resources/ctl.js" connect "<your iPad name>"
```

  Display virtual hilang otomatis begitu proses host berhenti.
- Biarkan Wi-Fi Mac menyala sepanjang sesi.

## 1. Pasang (sekali)

```bash
scripts/build-host-app.sh
```

```bash
scripts/install-ipad-app.sh client
```

| Cek | Hasil |
|---|---|
| Keduanya selesai tanpa `error` | |

## 2. Jalankan host dan beri izin

```bash
open build/WiredDisplayHost.app
```

- Muncul ikon **WD** di menu bar Mac. Menu menampilkan status izin.
- Jika "Screen Recording: MISSING": System Settings › Privacy & Security ›
  Screen & System Audio Recording › aktifkan **WiredDisplayHost**, lalu keluar
  (menu WD › Quit) dan jalankan lagi perintah `open` di atas.

| Cek | Hasil |
|---|---|
| Menu WD tampil, Screen Recording: granted | |

## 3. E-03 + video ujung-ke-ujung

Buka app **WiredDisplay** di iPad (layar Sidecar akan tertutup olehnya; itu wajar).

| Cek | Hasil |
|---|---|
| Dalam ±5 detik iPad menampilkan desktop Mac (wallpaper, mungkin menu bar) | |
| Teks tajam, tidak buram/terdistorsi, tidak terbalik | |
| Menu ⋯ (kanan atas) › resolusi 2732×2048 px · 1366×1024 pt, frame shown bertambah | |

Kembali ke Sidecar (geser ke app lain), lalu:

| Cek | Hasil |
|---|---|
| Di Sidecar, System Settings › Displays menunjukkan display tambahan "WiredDisplay (…)" saat app iPad aktif | |
| Seret satu jendela ke display WiredDisplay, buka lagi app iPad: jendela terlihat dan bergerak lancar | |
| Susunan display utama (Sidecar) tidak berubah | |

## 4. E-07 input sentuh

Di Mac (lewat Sidecar): menu WD › **Allow touch input from iPad**. Pertama kali,
macOS meminta izin Accessibility: aktifkan WiredDisplayHost, lalu centang lagi.

Kembali ke app iPad:

| Cek | Hasil |
|---|---|
| Ketuk ikon/jendela: klik terjadi tepat di bawah jari | |
| Ketuk empat sudut layar: kursor tepat di sudut, tidak loncat ke display lain | |
| Seret jendela dengan satu jari | |
| Ketuk dua kali cepat pada file/folder: terbuka | |
| Tahan ±0,5 detik: menu klik kanan muncul | |
| Dua jari menggeser halaman: scroll mengikuti jari | |
| Trackpad Magic Keyboard (jika ada): kursor bergerak, klik, klik dua jari = klik kanan | |

## 5. Pemutusan dan pemulihan

| Langkah | Yang diharapkan | Hasil |
|---|---|---|
| Pindah ke Sidecar saat streaming | Host menutup sesi; display virtual hilang ±1 detik | |
| Buka lagi app iPad | Tersambung lagi sendiri dalam ±5 detik | |
| Saat menyeret jendela, pindah ke Sidecar | Tidak ada tombol mouse "tersangkut" | |
| Menu WD › Quit | Display virtual hilang, Sidecar tetap | |

## 6. E-05b ulang (opsional, ±5 menit)

Hanya bagian A dan C (B sudah lulus dan memutus Sidecar):

```bash
scripts/install-ipad-app.sh probe
```

```bash
scripts/e05b-monitor.sh 900 "$(swift build --show-bin-path)" "docs/evidence/e05b-run3-mac-monitor.txt"
```

Lalu buka **WD Probe** di iPad dan ikuti panduan di layar (A, C, Selesai).

## 7. Kumpulkan bukti

```bash
cp ~/Library/Logs/WiredDisplayHost.log docs/evidence/session1-host.log
```

Kirim tabel hasil di atas ke Claude ("analisis sesi uji").
