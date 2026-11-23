# Audit kompatibilitas Android (dari rilis v0.5.0)

Tanggal: 2026-11-23. Basis: commit `ab59766` (WiredDisplay 0.5.0, build 9).
Status: **audit dan rencana, belum ada kode Android**. Tidak ada eksperimen yang dijalankan pada perangkat Android.

Label bukti mengikuti `FEASIBILITY.md`:
- **KODE**: dibaca langsung dari kode di repo ini (keyakinan tinggi).
- **RISET**: dari dokumentasi resmi atau sumber pihak ketiga, belum dijalankan.
- **HIPOTESIS**: inferensi saya, harus diuji.

---

## 1. Ringkasan

**Pertanyaan keputusan:** apa yang harus berubah agar pemilik HP atau tablet Android bisa memakainya sebagai monitor kabel untuk Mac, dengan standar yang sama: kabel saja, 60 Hz, latensi rendah, gambar terbaik.

**Jawaban singkat:**
1. **Rilis v0.5.0 tidak kompatibel dengan Android sama sekali.** Penghalangnya bukan video atau protokol, melainkan **transport**. Semua byte lewat `usbmuxd`, dan `usbmuxd` hanya berbicara dengan perangkat Apple. (KODE)
2. **Lapisan protokol sesi sudah hampir netral platform.** Framing, kriptografi, pesan input, audio dan video memakai format standar yang bisa ditiru di Android dengan pustaka umum. Ada 3 celah protokol yang harus ditutup (bagian 4). (KODE)
3. **Format video harus dibatasi untuk Android.** Preset Balanced, Ultra dan High Color memakai HEVC 4:4:4. Decoder hardware Android hampir pasti tidak mendukungnya, dan gagalnya bisa diam-diam (gambar rusak tanpa error), sehingga mekanisme step-down D-031 tidak bisa diandalkan. (KODE + HIPOTESIS)
4. **Tablet Android layak, HP kurang layak.** Dengan logika mode HiDPI sekarang, HP 6 inci menjadi layar 1200×540 pt. Itu terlalu pendek untuk kebanyakan jendela macOS. Tablet 11 inci menjadi 1280×800 pt, setara iPad. (KODE, dihitung dari `VirtualDisplayController.modeSizes`)

**Rekomendasi:** lanjut **secara bersyarat**. Jalankan dulu 3 eksperimen murah (bagian 8) yang menjawab pertanyaan paling berisiko: apakah transport USB Android cukup cepat dan bisa dipakai tanpa Developer Options. Jangan menulis klien Android sebelum E-A1 lulus.

---

## 2. Peta ketergantungan Apple-only

| Komponen | Status untuk Android | Bukti |
|---|---|---|
| `Shared/Usbmux/*` (UsbmuxConnection, UsbmuxCodec) | **Penghalang.** Hanya perangkat Apple. | `UsbmuxConnection` membuka `/var/run/usbmuxd` (KODE) |
| `Shared/Usbmux/Lockdown.swift` (nama dan model) | Tidak berlaku. Android tidak punya lockdownd. | `Lockdown.readIdentity` port 62078 (KODE) |
| `HostFleet.watchDevices`, `HostController.runLoop/waitForWiredDevices/runSession` | **Terikat ke usbmuxd.** Penemuan perangkat, pemilihan, dan koneksi semuanya memanggil `UsbmuxConnection`. | KODE |
| `UsbRegistry.appleMobileDevices` | Diagnostik khusus Apple (vendor 1452). | KODE |
| `Shared/Transport/FramedSocket` | **Netral.** Menerima file descriptor stream apa pun (non-blocking, SO_NOSIGPIPE). | `init(descriptor:)` (KODE) |
| `Shared/Protocol/*`, `Shared/Session/Messages.swift`, `Wire.swift` | **Netral.** Biner big-endian, didefinisikan lengkap. | KODE |
| `Shared/Session/SecureChannel.swift` | **Netral secara algoritma** (Ed25519, X25519, HKDF-SHA256, AES-256-GCM). Implementasi Swift memakai CryptoKit. | KODE |
| `TrustStore` (Keychain) | Konsep netral, penyimpanan per platform. | KODE |
| `KeyMap` (HID usage ke kode tombol Mac) | **Netral di wire.** Android harus memetakan kode tombol Linux ke HID usage. | KODE |
| `TouchInterpreter`, pengenal gerakan | Logika di `Shared` bisa diport. Pengenal UIKit harus ditulis ulang. | KODE |
| `AudioPacket` 48 kHz, int16 | **Netral.** | KODE |
| Klien iPad (`iPadOSClient/*`, UIKit, Metal, VideoToolbox) | Ditulis ulang total untuk Android. | KODE |
| Host: tampilan virtual, ScreenCaptureKit, VideoToolbox, injeksi input, driver audio | **Tidak berubah.** Semuanya sisi Mac. | KODE |

Konsekuensi: sekitar 80 persen nilai produk (sisi Mac) dipakai ulang apa adanya. Pekerjaan baru ada di tiga tempat: transport host, perluasan protokol, dan aplikasi Android.

---

## 3. Transport: masalah inti

### 3.1 Kenapa model sekarang tidak bisa dipindah begitu saja
Model sekarang (D-002, D-004): aplikasi iPad mendengarkan di `127.0.0.1:9100`, Mac menelepon lewat `usbmuxd`. Android tidak punya `usbmuxd`. Ada empat jalur kabel ke aplikasi Android.

### 3.2 Opsi

**A. Android Open Accessory (AOA).** Mac menjadi USB host, mengirim control request vendor (51 get protocol, 52 kirim string identitas, 53 start). HP lalu enumerasi ulang dengan vendor Google `0x18D1`, produk `0x2D00` (atau `0x2D01` jika ADB aktif), dengan satu interface berisi dua bulk endpoint. Aplikasi Android membuka `UsbAccessory` dan membaca/menulis seperti file. (RISET: dokumentasi AOA AOSP)
- Plus: **tidak butuh Developer Options.** Android menampilkan dialog izin bawaan. Sesuai "kabel saja" secara struktural. Arah koneksi tetap Mac yang memulai (D-004 tetap berlaku). Android Auto versi kabel memakai mekanisme yang sama, jadi dukungan pabrikan kemungkinan luas (HIPOTESIS).
- Minus: dokumentasi AOSP menyebut tidak semua perangkat mendukung mode accessory. Throughput tidak terdokumentasi; saya tidak menemukan angka terukur. Selama mode accessory aktif, HP kehilangan mode transfer file sampai kabel dicabut. Di Mac, butuh akses USB user-space (IOKit `IOUSBHost` atau libusb, LGPL-2.1, cocok dengan GPL-3.0).

**B. ADB (`adb forward` atau protokol server ADB).** Aplikasi Android mendengarkan di `127.0.0.1:9100` seperti iPad. Mac membuka stream `host:transport:<serial>` lalu `tcp:9100` lewat server ADB. Ini pola scrcpy. (RISET)
- Plus: paling cepat diprototipe, model aplikasi identik dengan iPad, terbukti dipakai scrcpy untuk video real-time.
- Minus: **pengguna wajib mengaktifkan Developer Options dan USB debugging.** Itu menurunkan keamanan HP dan sering diblokir di perangkat kantor. Butuh biner `adb` (dibundel atau diinstal pengguna) atau implementasi protokol ADB sendiri. ADB juga mendukung debugging nirkabel, jadi host wajib menolak transport non-USB, setara D-003.

**C. USB tethering (RNDIS/NCM) + TCP.** Ditolak. macOS tidak punya driver RNDIS. Tethering bisa diblokir operator, dan Mac akan merutekan internet lewat HP. Itu efek samping yang tidak diminta pengguna. (RISET umum, keyakinan sedang)

**D. Mac sebagai USB device.** Tidak mungkin. Mac tidak bisa berperan sebagai USB gadget untuk aplikasi.

### 3.3 Rekomendasi transport
**AOA sebagai jalur produk, ADB sebagai jalur pengembang dan cadangan**, dengan syarat E-A1 lulus. Alasan:
1. Target pengguna bukan developer. Developer Options adalah hambatan adopsi dan risiko keamanan.
2. AOA mempertahankan dua invarian keamanan proyek: kabel saja, dan Mac tidak membuka port.
3. ADB tetap berguna untuk iterasi cepat saat membangun klien.

Jika E-A1 menunjukkan throughput AOA di bawah kebutuhan (bagian 3.5), ADB menjadi jalur produk dan harus diberi label jelas "butuh USB debugging".

### 3.4 Desain host dengan perubahan minimal
`FramedSocket` hanya butuh file descriptor. Jadi:
1. Buat protokol `DeviceLink` di host: `discover() -> [LinkDevice]` dan `open(device) -> Int32` (descriptor). Implementasi pertama membungkus usbmuxd yang sudah ada.
2. Implementasi AOA membuat `socketpair(AF_UNIX, SOCK_STREAM)`. Satu thread pompa menyalin antara bulk endpoint dan satu ujung socketpair. Ujung lain diserahkan ke `FramedSocket` tanpa perubahan.
3. `HostFleet` dan `HostController` memakai kunci perangkat generik (serial USB atau ID AOA), bukan `UsbmuxDevice`.
4. `Lockdown.readIdentity` hanya untuk perangkat Apple. Untuk Android, nama dan model datang dari Hello (lihat 4.2).

### 3.5 Kebutuhan bandwidth (dari kode)
`HostController.Options.bitrateMbps = 80`, dengan `DataRateLimits` 1,5 kali per detik. Jadi kebutuhan rata-rata 80 Mbit/s dan puncak 120 Mbit/s, ditambah audio (sekitar 1,5 Mbit/s) dan overhead. iPad di USB 2 terukur 119 Mbit/s sebagai batas bawah satu arah (E-05). **Kriteria lulus transport Android: minimal 150 Mbit/s satu arah berkelanjutan, RTT kontrol p50 di bawah 2 ms.** Di bawah itu, host harus menurunkan bitrate untuk Android, yang mengorbankan kualitas gambar.

### 3.6 Blind spot transport yang wajib ditangani
1. **Membajak HP yang tidak dimaksud.** Jika host otomatis mengalihkan setiap perangkat Android ke mode accessory, HP yang hanya dicolok untuk mengisi daya, transfer file, atau debugging akan kehilangan fungsinya. **Aturan:** host hanya mengalihkan perangkat yang sudah dipasangkan, atau setelah pengguna menekan "Hubungkan" di panel. Perangkat yang sudah muncul sebagai `18D1:2D00/2D01` dengan string pabrikan WiredDisplay boleh langsung dipakai.
2. **Mengirim request vendor ke perangkat USB sembarang.** Keyboard, audio interface dan disk bisa bereaksi aneh terhadap request 51. **Aturan:** hanya kirim ke perangkat yang terlihat seperti Android: punya interface ADB (class 0xFF, subclass 0x42, protocol 0x01), MTP, atau PTP.
3. **Proses lain memegang perangkat.** Android File Transfer, OpenMTP, Image Capture (mode PTP) atau server `adb` milik pengguna bisa memegang interface secara eksklusif. Perilaku control request saat itu belum diketahui (HIPOTESIS, uji di E-A1).
4. **Mode default "Tanpa transfer data".** Belum terbukti apakah AOA berjalan saat HP di mode pengisian daya saja. Laporan pengguna Android Auto beragam. Uji di E-A1.
5. **Ukuran buffer baca.** Pembacaan `UsbAccessory` dengan buffer kecil dilaporkan kehilangan data. Pakai buffer minimal 16 KiB, lebih baik 64 KiB atau lebih. (RISET komunitas, keyakinan sedang)
6. **Putus dan sambung ulang.** Setelah aplikasi menutup accessory, HP bisa tetap di mode accessory sampai kabel dicabut. Sambung ulang tanpa cabut kabel harus diuji, karena host sekarang mengandalkan sambung ulang otomatis dengan backoff.

---

## 4. Protokol: apa yang sudah netral, apa yang kurang

### 4.1 Sudah netral (bisa ditiru persis)
Semua di bawah ini KODE dan sudah dicakup unit test di sisi Swift.
- Header 36 byte big-endian `WDSP`, versi frame 1, batas payload per stream (video 8 MiB, kontrol 64 KiB, input 4 KiB, audio 64 KiB).
- Handshake D-023, nonce AES-GCM, AAD = header.
- Pesan kontrol dan input dengan validasi rentang yang jelas.
- Video: satu access unit per frame, Annex B dengan start code 4 byte. Keyframe membawa VPS/SPS/PPS di depan (`SampleBuffers.accessUnit`). Format ini cocok langsung dengan `MediaCodec` Android.
- Koordinat input dinormalisasi 0...1 terhadap gambar yang dialirkan. Tombol keyboard berupa HID usage. Klien tidak pernah tahu koordinat Mac.

### 4.2 Celah yang harus ditutup (protokol v7)
`SessionConstants.protocolVersion` diperiksa dengan kesetaraan persis di kedua sisi. Jadi perubahan apa pun memaksa host dan iPad diperbarui bersamaan. Itu sudah menjadi praktik proyek, tetapi harus disebut di catatan rilis.

1. **Kemampuan decode eksplisit di Hello.** Sekarang host hanya tahu "H.264" dan "HEVC". Ia tidak tahu apakah klien bisa 4:4:4 atau 10-bit sampai klien gagal tiga kali dalam 10 detik (D-031). Usulan: field `decodeCaps` (bit: `hevc444`, `hevc10bit`, `h264High444`), dan host tidak pernah mengirim format di luar itu. Ini juga memperbaiki iPad lama.
   - Alternatif tanpa ubah protokol (klien Android mengirim `decodeFailed` di awal) **ditolak**. Efeknya bergantung pada preset host. Di preset Pro, pesan itu justru membuang 10-bit, bukan 4:4:4 (`DecodeLimits.next`, KODE).
2. **Platform dan model.** Host mengambil nama dan model iPad dari lockdownd. Android tidak punya itu. Usulan: field `platform` (iOS/Android) dan `model` (string terbatas). Nama perangkat Android bisa dibaca aplikasi (`Settings.Global.DEVICE_NAME`), jadi `displayName` di host harus mempercayai Hello untuk Android.
3. **Skala tidak bulat.** `Hello.scale` adalah u8 dan host hanya memakai `scale >= 2` untuk HiDPI. Kepadatan Android berupa bilangan pecahan (2,625; 3,5). Usulan: field `pointsPerInchHint` atau langsung "ukuran point yang disarankan", agar host bisa membuat mode yang wajar untuk HP (bagian 6).

Perubahan v7 sebaiknya sekalian menambahkan negosiasi rentang versi (`minVersion...maxVersion`), supaya perubahan berikutnya tidak lagi memaksa pembaruan serentak semua perangkat.

### 4.3 Jebakan implementasi ulang di Kotlin
Ini daftar yang paling mungkin membuat klien Android gagal handshake atau diputus host:

| # | Jebakan | Aturan yang benar (KODE) |
|---|---|---|
| 1 | Bilangan unsigned | `sessionID`, `sequence`, `timestampNanos`, nilai ping adalah u64. Kotlin harus memakai `ULong` atau operasi unsigned. |
| 2 | Kode pairing | 8 byte HKDF (label `pairing code`) dibaca big-endian sebagai u64, lalu **modulo 1.000.000 secara unsigned** (`java.lang.Long.remainderUnsigned`). Modulo signed biasa memberi kode berbeda di sekitar setengah kasus, sehingga kode di dua layar tidak cocok. Format: `"123 456"`. |
| 3 | Endianness campuran | Semua big-endian, **kecuali sampel audio: little-endian** (`AudioPacket.encoded`). |
| 4 | Float | `f32` dikirim sebagai bit pattern IEEE-754 big-endian. |
| 5 | Transcript | `SHA256("WiredDisplay auth v2" ‖ encode(authHello host) ‖ encode(authHello klien))`, host selalu duluan. `encode` termasuk byte tag 9. |
| 6 | Kunci arah | HKDF-SHA256, IKM = rahasia X25519, salt = transcript, info = `host->client` atau `client->host`, panjang 32. |
| 7 | Bukti | Ed25519 atas `"WiredDisplay proof v2" ‖ byte peran ‖ transcript`. Peran: host 1, klien 2. Tanda tangan 64 byte. |
| 8 | Nonce | 12 byte: `stream, 0, 0, 0, sequence (u64 BE)`. Tag 16 byte di belakang ciphertext (sama dengan keluaran `AES/GCM/NoPadding` Java). |
| 9 | AAD | Header 36 byte **dengan** flag `authenticated` dan `payloadLength` = plaintext + 16. |
| 10 | AuthHello sendiri | Selalu dikirim tanpa enkripsi, sebagai frame kontrol sequence 0, walau authHello lawan sudah tiba lebih dulu. |
| 11 | Sebelum terverifikasi | Hanya ping, pong, bye yang diterima. Pesan lain menutup koneksi. |
| 12 | Kunci lemah | Tolak rahasia X25519 yang semuanya nol, dan tolak ephemeral lawan yang sama dengan milik sendiri. |
| 13 | Sequence | Per stream, mulai 0, naik ketat. Celah boleh, mundur atau sama menutup koneksi. |
| 14 | Watchdog | Host ping setiap 2 s dan menutup koneksi setelah 6 s tanpa trafik. |
| 15 | Validasi Hello | Nama maksimal 64 byte UTF-8, dipotong di batas karakter. Skala 1...4, refresh 1...240, ppi 0 atau 100...1000, panel 1...16384. |

Ed25519 dan X25519 baru tersedia di API Java Android mulai API 33 (RISET). **Rekomendasi:** pakai Google Tink atau BouncyCastle agar bisa mendukung Android lama. Simpan seed Ed25519 terenkripsi dengan kunci AES dari Android Keystore. Dukungan Ed25519 di Keystore hardware tidak bisa diandalkan di semua perangkat.

**Mitigasi utama: vektor uji emas** (P1-050). `scripts/gen-protocol-vectors.py` menghitung vektor secara independen dari spesifikasi dan menulis `Tests/Vectors/protocol-v6.json`: handshake dengan kunci tetap, kode pairing, frame terenkripsi ke dua arah, setiap pesan kontrol dan input, dan paket audio. `ProtocolVectorTests` menguji kode Swift asli terhadap file itu. Klien Kotlin nanti wajib lulus terhadap file yang sama. Vektor dipilih agar jebakan nomor 1 dan 2 langsung ketahuan: session ID dengan bit atas menyala, dan kode pairing yang hasilnya salah jika dihitung dengan modulo signed.

---

## 5. Video di Android

| Topik | Temuan | Label |
|---|---|---|
| Codec | HEVC Main wajib hardware di hampir semua perangkat modern. H.264 selalu ada (host mewajibkan H.264 di Hello). | RISET |
| 10-bit (preset Pro) | HEVC Main10 umum di SoC yang mendukung HDR. Harus dicek per perangkat lewat `MediaCodecInfo.CodecCapabilities.profileLevels`. | RISET |
| 4:4:4 (Balanced lane diam, Ultra, High Color) | Android tidak punya konstanta profil HEVC RExt publik. Saya tidak menemukan bukti decoder hardware Android yang mendukung 4:4:4. Anggap tidak didukung. | HIPOTESIS kuat |
| Perilaku saat format tidak didukung | Bisa error, bisa keluar gambar rusak tanpa error. Yang kedua tidak memicu `decodeFailed`. Inilah alasan `decodeCaps` wajib. | HIPOTESIS, uji di E-A3 |
| Ganti format di tengah stream | Balanced berganti lane (4:2:0 dan 4:4:4) dengan keyframe dan SPS baru. Di Android, perubahan profil atau chroma di tengah stream sebaiknya ditangani dengan membuat ulang decoder saat SPS berubah (pola yang sama dengan `HEVCSPSInfo` di renderer Metal). | KODE + RISET |
| Latensi decode | Pakai `KEY_LOW_LATENCY` (API 30+) bila didukung, `KEY_PRIORITY = 0`, keluaran langsung ke `SurfaceView` (bukan `TextureView`) agar bisa naik ke overlay hardware. Beberapa decoder menahan frame tanpa mode low-latency vendor. | RISET |
| Warna | Host menandai BT.709, sRGB, video range. Decoder Android umumnya membaca VUI. Uji visual tetap perlu (BUG-033 menunjukkan warna gampang salah). | HIPOTESIS |
| Ukuran | Decoder HP umumnya sampai 4K. Panel tablet terbesar (sekitar 2960×1848) masih di bawahnya. | RISET umum |

**Konsekuensi preset untuk Android:** Pro (4:2:0, 10-bit) atau 4:2:0 8-bit. Balanced, Ultra dan High Color diturunkan otomatis lewat `decodeCaps`. Kualitas teks berwarna di Android akan setara Pro, bukan Balanced. Itu harus jujur disebut di panduan.

---

## 6. Layar: tablet layak, HP terbatas

Host membuat mode HiDPI dengan pembagi 2 dan faktor ruang 1; 1,125; 1,25 (`modeSizes`). Dihitung untuk dua perangkat contoh (landscape):

| Perangkat (panel) | Default | More Space | Most Space |
|---|---|---|---|
| Tablet 11 inci, 2560×1600 | 1280×800 pt | 1440×900 pt | 1600×1000 pt |
| HP 6,2 inci, 2400×1080 | 1200×540 pt | 1350×608 pt | 1500×676 pt |
| (pembanding) iPad Air 13, 2732×2048 | 1366×1024 pt | 1536×1152 pt | 1708×1280 pt |

- **Tablet:** setara iPad. Layak sebagai monitor utama atau kedua.
- **HP:** tinggi 540 sampai 676 pt. Banyak jendela macOS (Pengaturan Sistem, dialog) lebih tinggi dari itu. Pada skala 2x, teks juga sangat kecil secara fisik. **Implikasi produk:** HP cocok sebagai layar tambahan untuk widget, chat, monitor sistem, atau dalam mode potret. HP tidak cocok sebagai layar satu-satunya Mac headless. Jangan janjikan "HP sebagai monitor" setara iPad.
- Faktor ruang lebih besar (misalnya 1,5) secara teknis tersedia lewat jalur downscale area-filter yang sudah ada. Ini bukan solusi untuk ukuran fisik teks.
- **Spesifik HP:** lubang kamera dan sudut membulat memotong konten Mac (menu bar, Dock). Klien harus memilih: memakai area aman saja (melaporkan ukuran panel tanpa cutout), atau seluruh panel. Rekomendasi: area aman sebagai default.
- **Gestur navigasi Android** (usap tepi untuk kembali) bertabrakan dengan sentuhan di tepi layar Mac. Pakai mode imersif dan `setSystemGestureExclusionRects` (dibatasi sistem 200 dp per tepi).
- **Refresh 90/120/144 Hz:** host mengikuti refresh klien sampai 120. Di atas 60 Hz, lane 4:2:0 memakai rate control standar (D-036). Untuk HP 90 Hz ini jalur yang belum diukur. Rekomendasi awal untuk Android: 60 Hz default, sesuai prioritas pemilik.

---

## 7. Input, audio, dan fitur lain

| Fitur | Android | Catatan |
|---|---|---|
| Sentuh (D-026) | Bisa. `MotionEvent` multi-touch, port `TouchInterpreter`, `EditGesture`, `PinchZoomStepper`. | Pengenal gerakan UIKit ditulis ulang. Pakai vektor uji yang sama. |
| Pinch dan rotate (D-029) | Bisa (`ScaleGestureDetector`, rotasi dihitung sendiri). | Host tidak berubah. |
| Keyboard fisik | Bisa. `KeyEvent.getScanCode()` (kode Linux) ke HID usage butuh tabel baru. | Android juga menahan beberapa pintasan sistem; daftar per OEM berbeda. |
| Trackpad dan mouse | Sebagian. `SOURCE_MOUSE`, `ACTION_SCROLL`, pointer capture. | Fase scroll dan momentum harus dibuat di klien, seperti di iPad. |
| Kursor lokal (D-038) | Bisa. PNG didekode `BitmapFactory`, digambar di overlay. | |
| Audio speaker | Bisa. AAudio atau Oboe, 48 kHz stereo int16. | Port `AudioJitterBuffer` dengan drift correction. |
| Mikrofon | Bisa. `AudioRecord` dengan sumber `VOICE_COMMUNICATION` dan AEC. | Izin `RECORD_AUDIO`. Mati secara default. |
| Kecerahan (D-033) | Bisa untuk jendela aplikasi (`screenBrightness`), tanpa izin khusus. | Membaca kecerahan sistem tidak seragam antar OEM. |
| Latar belakang dengan audio (D-018) | Bisa dengan foreground service `connectedDevice` (Android 14+ mensyaratkan izin USB). | RISET |
| Layar tetap menyala | `FLAG_KEEP_SCREEN_ON`. | |
| Distribusi | **Lebih mudah dari iPad.** APK bisa dipasang langsung, tidak kedaluwarsa 7 hari. | |
| Stylus (S Pen) | Belum. Sama statusnya dengan Apple Pencil (R-INP-03). | |

---

## 8. Eksperimen sebelum membangun

Urutan dari yang paling mengurangi ketidakpastian per biaya.

| ID | Eksperimen | Biaya | Lulus jika |
|---|---|---|---|
| **E-A1** | AOA di Mac: skrip kecil (pyusb atau Swift + IOKit) mengalihkan HP ke mode accessory, lalu echo byte seperti E-05 dengan aplikasi echo Android minimal. Uji di mode USB default, saat Android File Transfer berjalan, dan sambung ulang tanpa cabut kabel. | 1 hari | Throughput satu arah minimal 150 Mbit/s, RTT 4 KiB p50 di bawah 2 ms, 0 byte salah, bekerja di mode USB default. |
| **E-A2** | ADB sebagai pembanding: `adb forward` + echo yang sama. | 2 jam | Angka pembanding untuk keputusan transport. |
| **E-A3** | Decode di Android: rekam stream host ke file Annex B (Pro 10-bit, 4:2:0 8-bit, dan Ultra 4:4:4), putar dengan `MediaCodec` ke `SurfaceView`. Catat latensi decode, profil yang didukung, dan **bagaimana 4:4:4 gagal**. | 1 hari | Pro dan 4:2:0 terdekode real-time 60 fps. Perilaku 4:4:4 diketahui pasti. |
| E-A4 | Kelayakan ukuran HP tanpa Android: buat layar virtual 1350×608 pt di Mac (BetterDisplay) dan pakai sehari. | 0 kode | Pemilik memutuskan apakah HP masuk target atau hanya tablet. |

Perangkat yang dibutuhkan: minimal satu tablet Android dan satu HP Android dengan SoC berbeda (misalnya Qualcomm dan MediaTek). Hasil satu perangkat tidak bisa digeneralisasi.

---

## 9. Opsi strategi dan rekomendasi

| Opsi | Dampak | Usaha | Risiko | Catatan |
|---|---|---|---|---|
| 1. Tidak mendukung Android | Nol | Nol | Nol | Fokus tetap di prioritas pemilik (60 Hz, latensi, gambar) dan item terbuka (soak 2 jam, seri sleep/lock). |
| 2. Prototipe ADB cepat | Sedang, hanya untuk pengguna teknis | Rendah (klien + jembatan ADB) | Rendah | Belajar cepat. Bukan produk konsumen karena butuh USB debugging. |
| 3. **Bertahap: eksperimen, lalu AOA + protokol v7, tablet dulu** | Tinggi | Sedang ke tinggi | Sedang | Mempertahankan invarian keamanan. Butuh perangkat uji. |
| 4. Klien Android memakai Swift SDK for Android + swift-crypto agar `Shared/` dipakai bersama | Tinggi, satu sumber protokol | Tinggi | Tinggi (toolchain masih baru, jembatan JNI, ukuran APK) | Menarik jangka panjang. Tidak untuk iterasi pertama. Keyakinan rendah tentang kematangannya. |

**Rekomendasi saya: opsi 3, dimulai dari E-A1 sampai E-A3**, karena:
1. Penghalangnya terlokalisasi di transport. Satu eksperimen satu hari menjawab apakah jalur konsumen (AOA) layak.
2. Hampir semua sisi Mac dipakai ulang tanpa perubahan, termasuk `FramedSocket`.
3. Protokol v7 (`decodeCaps`, platform, model) juga memperbaiki kelemahan iPad: step-down format sekarang bergantung pada kegagalan, bukan pada kemampuan yang dideklarasikan.

Klien ditulis dalam **Kotlin**, dengan vektor uji emas dari Swift sebagai kontrak. Target pertama: **tablet Android, 60 Hz, preset Pro.**

**Biaya peluang:** ini menunda soak 2 jam, seri sleep/lock 20 siklus, dan PLW-06. Saran saya: selesaikan soak 2 jam dulu (tidak butuh kode), karena perubahan transport di host akan menyentuh jalur yang sama.

### Perkiraan ukuran pekerjaan (HIPOTESIS, dari ukuran kode sekarang)
- Klien iPad sekitar 3.000 baris Swift, ditambah logika bersama sekitar 2.200 baris. Klien Android kira-kira 5.000 sampai 6.000 baris Kotlin.
- Host: abstraksi `DeviceLink` + driver AOA + v7, sekitar 1.000 sampai 1.500 baris Swift plus tes.

---

## 10. Risiko terbesar

1. **Throughput AOA tidak cukup** atau tidak stabil di sebagian OEM. Mitigasi: E-A1 di dua perangkat sebelum komitmen. Cadangan: ADB.
2. **Dua implementasi protokol menyimpang.** Mitigasi: vektor uji emas wajib di CI kedua sisi.
3. **Fragmentasi decoder Android** (latensi, warna, Main10). Mitigasi: daftar quirk per SoC, mulai dari dua SoC.
4. **Host mengganggu perangkat USB lain.** Mitigasi: aturan di 3.6 (opt-in per perangkat, filter kelas interface).
5. **Ekspektasi HP.** Mitigasi: posisikan tablet sebagai target utama, HP sebagai layar tambahan.

## 11. Ukuran keberhasilan

| Metrik | Baseline (iPad Air 13, terukur) | Target Android (tablet) | Kapan |
|---|---|---|---|
| Frame di layar | sekitar 60 fps (D-042) | minimal 59 fps p50 | Akhir prototipe |
| Encode host | p50 12,2 ms di 2732×2048 | sama (sisi Mac) | Akhir prototipe |
| Transfer Mac ke perangkat | sekitar 1 ms | p50 di bawah 3 ms | E-A1 |
| Enqueue sampai tampil | p50 sekitar 30 ms | p50 di bawah 40 ms | E-A3 dan prototipe |
| Stabilitas | soak 2 jam belum dijalankan | 0 putus dalam 2 jam | Sebelum rilis |
| Pairing | kode cocok di dua layar | 10 dari 10 percobaan cocok | Sebelum rilis |

---

## Sumber
- [Android Open Accessory 1.0, AOSP](https://source.android.com/docs/core/interaction/accessories/aoa)
- [Android Open Accessory 2.0, AOSP](https://source.android.com/docs/core/interaction/accessories/aoa2)
- [Accessory protocol, AOSP](https://source.android.com/docs/core/interaction/accessories/protocol)
- [Laporan pengguna Android Auto pada mode tanpa transfer data, forum GrapheneOS](https://discuss.grapheneos.org/d/10460-android-auto-not-being-detected-by-car)
- [Kabel khusus pengisian daya dan Android Auto, Plugable](https://kb.plugable.com/en_US/can-a-charge-only-cable-be-used-for-apple-carplay-or-android-auto)
- [Perubahan API 33 `java.security.interfaces` (EdECKey, XECKey)](https://developer.android.com/sdk/api_diff/33/changes/pkg_java.security.interfaces)
- [Tipe foreground service, Android Developers](https://developer.android.com/guide/components/fg-service-types)
- [Format media yang didukung, Android Developers](https://developer.android.com/media/platform/supported-formats)
- [scrcpy: dokumentasi pengembang (tunnel adb reverse/forward)](https://github.com/Genymobile/scrcpy/blob/master/doc/develop.md)
